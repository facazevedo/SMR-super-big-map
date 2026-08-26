#!/usr/bin/env python3
"""Exact, compact shadow oracle for protected-resource spatial indexing.

A probe-enabled real run records only ordered protected circles and the maximum
visited circle for each terrain pass.  Triangle inequality then proves all possible
pixel decisions without serializing or replaying millions of grid cells.  Sampled
integer queries and mutation tests independently guard the proof implementation, and
the same corpus supplies a fast isolated microbenchmark.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator


OBSERVATION_SCHEMA = "smr.ralph.protected_guard_observation.v1"
CORPUS_SCHEMA = "smr.ralph.protected_guard_corpus.v1"
REPORT_SCHEMA = "smr.ralph.protected_guard_shadow_oracle.v2"
REQUIRED_IDENTITY = (
    "coordinate",
    "preset",
    "source_commit",
    "terrain_source_sha256",
    "scenario_input_sha256",
    "task_sha256",
)


@dataclass(frozen=True)
class Guard:
    identity: str
    cx: float
    cy: float
    radius: float


@dataclass(frozen=True)
class PatchPass:
    identity: str
    cx: float
    cy: float
    visit_radius: float
    width: int
    height: int


@dataclass(frozen=True)
class Observation:
    identity: str
    guards: tuple[Guard, ...]
    passes: tuple[PatchPass, ...]


def canonical_json(payload: object) -> bytes:
    return json.dumps(
        payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")


def canonical_sha256(payload: object) -> str:
    return hashlib.sha256(canonical_json(payload)).hexdigest().upper()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def finite(value: object, label: str, *, nonnegative: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{label} must be numeric")
    result = float(value)
    if not math.isfinite(result) or (nonnegative and result < 0):
        qualifier = "finite nonnegative" if nonnegative else "finite"
        raise ValueError(f"{label} must be {qualifier}")
    return result


def positive_int(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ValueError(f"{label} must be a positive integer")
    return value


def text(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or any(c in value for c in "\t\r\n"):
        raise ValueError(f"{label} must be a nonempty single-line string")
    return value


def validate_identity(identity: object) -> dict[str, str]:
    if not isinstance(identity, dict):
        raise ValueError("identity must be an object")
    result = {key: text(identity.get(key), f"identity.{key}") for key in REQUIRED_IDENTITY}
    if result["coordinate"] != "14N134W" or result["preset"] != "RoughTerrain":
        raise ValueError("corpus must be pinned to 14N134W RoughTerrain")
    for key in ("terrain_source_sha256", "scenario_input_sha256", "task_sha256"):
        if len(result[key]) != 64 or any(c not in "0123456789abcdefABCDEF" for c in result[key]):
            raise ValueError(f"identity.{key} must be a SHA-256")
        result[key] = result[key].upper()
    return result


def parse_observation(path: Path) -> dict:
    schema = None
    identity: dict[str, str] = {}
    calls: dict[int, dict] = {}
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        fields = raw.split("\t")
        kind = fields[0] if fields else ""
        try:
            if kind == "SCHEMA" and len(fields) == 2:
                schema = fields[1]
            elif kind == "IDENTITY" and len(fields) == 3:
                identity[fields[1]] = fields[2]
            elif kind == "CALL" and len(fields) == 7:
                call = int(fields[1])
                if call in calls:
                    raise ValueError(f"duplicate call {call}")
                calls[call] = {
                    "id": f"call-{call:02d}",
                    "map_width": int(fields[2]),
                    "map_height": int(fields[3]),
                    "height_tile": float(fields[4]),
                    "cells_per_hex": float(fields[5]),
                    "ring_sectors": int(fields[6]),
                    "guards": [],
                    "passes": [],
                }
            elif kind == "GUARD" and len(fields) == 7:
                call = int(fields[1])
                row = calls[call]
                if int(fields[2]) != len(row["guards"]) + 1:
                    raise ValueError("guard order is not contiguous")
                row["guards"].append(
                    {"id": fields[3], "cx": float(fields[4]), "cy": float(fields[5]),
                     "radius": float(fields[6])}
                )
            elif kind == "PASS" and len(fields) == 9:
                call = int(fields[1])
                row = calls[call]
                if int(fields[2]) != len(row["passes"]) + 1:
                    raise ValueError("pass order is not contiguous")
                row["passes"].append(
                    {"id": fields[3], "cx": float(fields[4]), "cy": float(fields[5]),
                     "visit_radius": float(fields[6]), "width": int(fields[7]),
                     "height": int(fields[8])}
                )
            else:
                raise ValueError(f"unrecognized row shape {kind!r}")
        except (KeyError, ValueError) as exc:
            raise ValueError(f"{path}:{line_number}: {exc}") from exc
    if schema != OBSERVATION_SCHEMA:
        raise ValueError(f"observation schema must be {OBSERVATION_SCHEMA}")
    validated_identity = validate_identity(identity)
    if not calls or sorted(calls) != list(range(1, len(calls) + 1)):
        raise ValueError("observation calls must be contiguous and nonempty")
    observations = []
    for call in sorted(calls):
        row = calls[call]
        if not row["guards"] or not row["passes"]:
            raise ValueError(f"call {call} has no guards or passes")
        observations.append(row)
    payload = {
        "schema": CORPUS_SCHEMA,
        "identity": validated_identity,
        "observation_sha256": file_sha256(path),
        "observations": observations,
    }
    payload["corpus_sha256"] = canonical_sha256(payload)
    return payload


def load_corpus(path: Path) -> tuple[dict, tuple[Observation, ...]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or payload.get("schema") != CORPUS_SCHEMA:
        raise ValueError(f"corpus schema must be {CORPUS_SCHEMA}")
    validate_identity(payload.get("identity"))
    stored = payload.get("corpus_sha256")
    unsigned = dict(payload)
    unsigned.pop("corpus_sha256", None)
    if stored != canonical_sha256(unsigned):
        raise ValueError("corpus_sha256 does not match canonical corpus content")
    raw_observations = payload.get("observations")
    if not isinstance(raw_observations, list) or not raw_observations:
        raise ValueError("observations must be a nonempty array")
    observations = []
    for oi, raw in enumerate(raw_observations):
        if not isinstance(raw, dict):
            raise ValueError(f"observations[{oi}] must be an object")
        guards = tuple(
            Guard(
                text(row.get("id"), f"observations[{oi}].guards[{gi}].id"),
                finite(row.get("cx"), "guard.cx"), finite(row.get("cy"), "guard.cy"),
                finite(row.get("radius"), "guard.radius", nonnegative=True),
            )
            for gi, row in enumerate(raw.get("guards", [])) if isinstance(row, dict)
        )
        passes = tuple(
            PatchPass(
                text(row.get("id"), f"observations[{oi}].passes[{pi}].id"),
                finite(row.get("cx"), "pass.cx"), finite(row.get("cy"), "pass.cy"),
                finite(row.get("visit_radius"), "pass.visit_radius", nonnegative=True),
                positive_int(row.get("width"), "pass.width"),
                positive_int(row.get("height"), "pass.height"),
            )
            for pi, row in enumerate(raw.get("passes", [])) if isinstance(row, dict)
        )
        if len(guards) != len(raw.get("guards", [])) or len(passes) != len(raw.get("passes", [])):
            raise ValueError(f"observation {oi} contains non-object rows")
        if not guards or not passes:
            raise ValueError(f"observation {oi} must contain guards and passes")
        if len({g.identity for g in guards}) != len(guards):
            raise ValueError(f"observation {oi} guard identities are not unique")
        if len({p.identity for p in passes}) != len(passes):
            raise ValueError(f"observation {oi} pass identities are not unique")
        observations.append(Observation(text(raw.get("id"), "observation.id"), guards, passes))
    return payload, tuple(observations)


def nearby_guards(patch: PatchPass, guards: tuple[Guard, ...]) -> tuple[Guard, ...]:
    retained = []
    for guard in guards:
        dx, dy = guard.cx - patch.cx, guard.cy - patch.cy
        reach = patch.visit_radius + guard.radius
        if dx * dx + dy * dy <= reach * reach:
            retained.append(guard)
    return tuple(retained)


def first_match(
    x: int, y: int, guards: tuple[Guard, ...], *, strict_circle: bool = False
) -> str | None:
    for guard in guards:
        dx, dy = x - guard.cx, y - guard.cy
        lhs, rhs = dx * dx + dy * dy, guard.radius * guard.radius
        matched = lhs < rhs if strict_circle else lhs <= rhs
        if matched:
            return guard.identity
    return None


def analytic_certificate(patch: PatchPass, guards: tuple[Guard, ...]) -> dict:
    retained = nearby_guards(patch, guards)
    retained_ids = tuple(g.identity for g in retained)
    retained_set = set(retained_ids)
    pruned = tuple(g for g in guards if g.identity not in retained_set)
    margins = tuple(
        math.hypot(g.cx - patch.cx, g.cy - patch.cy)
        - (patch.visit_radius + g.radius) for g in pruned
    )
    expected_ids = tuple(
        g.identity for g in guards
        if math.hypot(g.cx - patch.cx, g.cy - patch.cy) <= patch.visit_radius + g.radius
    )
    order_exact = retained_ids == expected_ids
    disjoint = all(margin > 0 for margin in margins)
    return {
        "pass_id": patch.identity,
        "retained_count": len(retained),
        "pruned_count": len(pruned),
        "retained_order_sha256": canonical_sha256(retained_ids),
        "minimum_pruned_margin": min(margins) if margins else None,
        "retained_order_exact": order_exact,
        "pruned_strictly_disjoint": disjoint,
        "all_possible_queries_equivalent": order_exact and disjoint,
    }


def sampled_queries(patch: PatchPass, limit: int) -> Iterator[tuple[int, int]]:
    x0 = max(0, math.floor(patch.cx - patch.visit_radius))
    y0 = max(0, math.floor(patch.cy - patch.visit_radius))
    x1 = min(patch.width - 1, math.ceil(patch.cx + patch.visit_radius))
    y1 = min(patch.height - 1, math.ceil(patch.cy + patch.visit_radius))
    area = max(1, (x1 - x0 + 1) * (y1 - y0 + 1))
    stride = max(1, math.ceil(math.sqrt(area / max(1, limit))))
    radius_sq = patch.visit_radius * patch.visit_radius
    emitted = 0
    for y in range(y0, y1 + 1, stride):
        for x in range(x0, x1 + 1, stride):
            if (x - patch.cx) ** 2 + (y - patch.cy) ** 2 <= radius_sq:
                yield x, y
                emitted += 1
                if emitted >= limit:
                    return


def sample_shadow(observations: tuple[Observation, ...], limit: int) -> dict:
    digest = hashlib.sha256()
    checked = 0
    first_mismatch = None
    for observation in observations:
        for patch in observation.passes:
            retained = nearby_guards(patch, observation.guards)
            for x, y in sampled_queries(patch, limit):
                accepted = first_match(x, y, observation.guards)
                candidate = first_match(x, y, retained)
                checked += 1
                digest.update(
                    f"{observation.identity}\0{patch.identity}\0{x}\0{y}\0{accepted or ''}\n".encode()
                )
                if accepted != candidate:
                    first_mismatch = {
                        "observation_id": observation.identity, "pass_id": patch.identity,
                        "x": x, "y": y, "accepted_first_guard": accepted,
                        "candidate_first_guard": candidate,
                    }
                    break
            if first_mismatch:
                break
        if first_mismatch:
            break
    return {
        "sample_count": checked,
        "accepted_decision_sha256": digest.hexdigest().upper(),
        "first_mismatch": first_mismatch,
        "ok": first_mismatch is None,
    }


def benchmark(observations: tuple[Observation, ...], limit: int, rounds: int) -> dict:
    samples = tuple(
        (observation.guards, patch, tuple(sampled_queries(patch, limit)))
        for observation in observations for patch in observation.passes
    )
    full_times, indexed_times = [], []
    full_digest = indexed_digest = 0
    for _ in range(rounds):
        started = time.perf_counter_ns()
        hits = 0
        for guards, _, queries in samples:
            for x, y in queries:
                hits += first_match(x, y, guards) is not None
        full_times.append(time.perf_counter_ns() - started)
        full_digest = hits
        started = time.perf_counter_ns()
        hits = 0
        for guards, patch, queries in samples:
            retained = nearby_guards(patch, guards)
            for x, y in queries:
                hits += first_match(x, y, retained) is not None
        indexed_times.append(time.perf_counter_ns() - started)
        indexed_digest = hits
    full_median = statistics.median(full_times)
    indexed_median = statistics.median(indexed_times)
    return {
        "rounds": rounds,
        "query_count_per_round": sum(len(q) for _, _, q in samples),
        "full_scan_hit_count": full_digest,
        "indexed_hit_count": indexed_digest,
        "full_scan_median_ms": full_median / 1_000_000,
        "indexed_median_ms": indexed_median / 1_000_000,
        "speedup_ratio": full_median / indexed_median if indexed_median else None,
        "same_hit_count": full_digest == indexed_digest,
    }


def synthetic_payload() -> dict:
    unsigned = {
        "schema": CORPUS_SCHEMA,
        "identity": {
            "coordinate": "14N134W", "preset": "RoughTerrain",
            "source_commit": "synthetic-self-test", "terrain_source_sha256": "0" * 64,
            "scenario_input_sha256": "1" * 64, "task_sha256": "2" * 64,
        },
        "observation_sha256": "3" * 64,
        "observations": [{
            "id": "call-01", "map_width": 128, "map_height": 128,
            "height_tile": 100.0, "cells_per_hex": 10.0, "ring_sectors": 2,
            "guards": [
                {"id": "first", "cx": 10.0, "cy": 10.0, "radius": 3.0},
                {"id": "overlap", "cx": 11.0, "cy": 10.0, "radius": 3.0},
                {"id": "tangent", "cx": 27.0, "cy": 10.0, "radius": 2.0},
                {"id": "far", "cx": 80.0, "cy": 90.0, "radius": 4.0},
            ],
            "passes": [
                {"id": "shape", "cx": 20.0, "cy": 10.0, "visit_radius": 5.0,
                 "width": 128, "height": 128},
                {"id": "overlap-check", "cx": 10.0, "cy": 10.0, "visit_radius": 2.0,
                 "width": 128, "height": 128},
            ],
        }],
    }
    unsigned["corpus_sha256"] = canonical_sha256(unsigned)
    return unsigned


def mutation_tests() -> dict:
    payload = synthetic_payload()
    raw = payload["observations"][0]
    guards = tuple(Guard(g["id"], g["cx"], g["cy"], g["radius"]) for g in raw["guards"])
    shape = PatchPass("shape", 20.0, 10.0, 5.0, 128, 128)
    overlap = PatchPass("overlap-check", 10.0, 10.0, 2.0, 128, 128)
    correct = nearby_guards(shape, guards)
    strict_retained = tuple(
        g for g in guards
        if (g.cx - shape.cx) ** 2 + (g.cy - shape.cy) ** 2
        < (shape.visit_radius + g.radius) ** 2
    )
    overlap_retained = nearby_guards(overlap, guards)
    reversed_retained = tuple(reversed(overlap_retained))
    checks = {
        "strict_intersection_drops_tangent": (
            first_match(25, 10, guards) != first_match(25, 10, strict_retained)
        ),
        "retained_order_change_alters_first_match": (
            first_match(10, 10, overlap_retained) != first_match(10, 10, reversed_retained)
        ),
        "strict_circle_drops_boundary": (
            first_match(13, 10, guards) != first_match(13, 10, guards, strict_circle=True)
        ),
        "correct_tangent_is_retained": any(g.identity == "tangent" for g in correct),
    }
    return {"checks": checks, "detected": sum(checks.values()), "total": len(checks),
            "ok": all(checks.values())}


def run_report(payload: dict, observations: tuple[Observation, ...], limit: int, rounds: int) -> dict:
    certificates = []
    for observation in observations:
        for patch in observation.passes:
            row = analytic_certificate(patch, observation.guards)
            row["observation_id"] = observation.identity
            certificates.append(row)
    shadow = sample_shadow(observations, limit)
    timing = benchmark(observations, limit, rounds)
    mutations = mutation_tests()
    report = {
        "schema": REPORT_SCHEMA,
        "corpus_schema": payload["schema"],
        "corpus_sha256": payload["corpus_sha256"],
        "identity": payload["identity"],
        "observation_count": len(observations),
        "guard_count": sum(len(o.guards) for o in observations),
        "pass_count": sum(len(o.passes) for o in observations),
        "analytic_certificates": certificates,
        "analytic_passed": sum(c["all_possible_queries_equivalent"] for c in certificates),
        "analytic_total": len(certificates),
        "sample_shadow": shadow,
        "microbenchmark": timing,
        "mutation_tests": mutations,
    }
    report["ok"] = (
        report["analytic_passed"] == report["analytic_total"]
        and shadow["ok"] and timing["same_hit_count"] and mutations["ok"]
    )
    return report


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def command_convert(args: argparse.Namespace) -> int:
    payload = parse_observation(args.observation.resolve())
    write_json(args.out.resolve(), payload)
    print(json.dumps({"ok": True, "corpus": str(args.out.resolve()),
                      "corpus_sha256": payload["corpus_sha256"],
                      "observations": len(payload["observations"])}, indent=2))
    return 0


def command_run(args: argparse.Namespace) -> int:
    payload, observations = load_corpus(args.corpus.resolve())
    report = run_report(payload, observations, args.sample_limit, args.benchmark_rounds)
    if args.out:
        write_json(args.out.resolve(), report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["ok"] else 1


def command_self_test(args: argparse.Namespace) -> int:
    payload = synthetic_payload()
    temporary = args.work.resolve()
    write_json(temporary, payload)
    try:
        loaded, observations = load_corpus(temporary)
        report = run_report(loaded, observations, args.sample_limit, args.benchmark_rounds)
    finally:
        temporary.unlink(missing_ok=True)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["ok"] else 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    convert = sub.add_parser("convert", help="convert one real probe observation to a corpus")
    convert.add_argument("--observation", type=Path, required=True)
    convert.add_argument("--out", type=Path, required=True)
    convert.set_defaults(func=command_convert)
    run = sub.add_parser("run", help="prove and benchmark a compact corpus")
    run.add_argument("--corpus", type=Path, required=True)
    run.add_argument("--sample-limit", type=int, default=50_000)
    run.add_argument("--benchmark-rounds", type=int, default=5)
    run.add_argument("--out", type=Path)
    run.set_defaults(func=command_run)
    test = sub.add_parser("self-test")
    test.add_argument("--sample-limit", type=int, default=20_000)
    test.add_argument("--benchmark-rounds", type=int, default=3)
    test.add_argument("--work", type=Path, default=Path("_ralph/tmp/.guard-oracle-self-test.json"))
    test.set_defaults(func=command_self_test)
    args = parser.parse_args()
    if hasattr(args, "sample_limit") and (args.sample_limit <= 0 or args.benchmark_rounds <= 0):
        parser.error("sample limits and benchmark rounds must be positive")
    return args


if __name__ == "__main__":
    try:
        parsed = parse_args()
        raise SystemExit(parsed.func(parsed))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"guard shadow oracle error: {exc}", file=sys.stderr)
        raise SystemExit(2)

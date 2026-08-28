#!/usr/bin/env python3
"""Detached exactness corpus and cost oracle for the v961 surface spacing audit.

This intentionally models both the literal lexicographic pair walk and the proposed
two-index candidate walk.  It compares every pair-derived report field, including
the first-detail strings whose result depends on visitation order.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import math
import random
import statistics
import time


OBSERVED_AUDIT_MS = 982.0
OBSERVED_MARKERS = 615
OBSERVED_TOPUPS = 265
MIN_ENRICHMENT = 3
MIN_OUTER_ANOMALY = 10
MIN_QUOTA = 3


@dataclass(frozen=True)
class Profile:
    layer: str
    resource: str
    same: int
    layer_radius: int
    all_radius: int


@dataclass(frozen=True)
class Entry:
    ident: int
    klass: str
    topup: bool
    outer: bool
    inner: bool
    quota: bool
    anomaly: bool
    surface: bool
    x: int
    y: int
    q: int | None
    r: int | None
    profile: Profile | None
    placed: bool = True

    @property
    def hex_key(self) -> str | None:
        if self.q is None or self.r is None:
            return None
        return f"{self.q}:{self.r}"


def pair_radius(a: Profile | None, b: Profile | None) -> int | None:
    if a is None or b is None:
        return None
    if a.layer != b.layer:
        return a.all_radius + b.all_radius
    if a.resource != b.resource:
        return a.layer_radius + b.layer_radius
    return a.same + b.same


def hex_distance(a: Entry, b: Entry) -> int | None:
    if a.q is None or a.r is None or b.q is None or b.r is None:
        return None
    dq, dr = a.q - b.q, a.r - b.r
    return max(abs(dq), abs(dr), abs(dq + dr))


def empty_report(entries: list[Entry]) -> dict[str, object]:
    return {
        "markers": len(entries),
        "topups": sum(e.topup for e in entries),
        "checked_pairs": 0,
        "native_pairs_skipped": 0,
        "duplicate_hex_pairs": 0,
        "first_duplicate_hex_pair": "",
        "enrichment_spacing_violations": 0,
        "first_enrichment_spacing_violation": "",
        "surface_quota_topups": sum(e.quota for e in entries),
        "surface_quota_spacing_violations": 0,
        "first_surface_quota_spacing_violation": "",
        "outer_ring_spacing_violations": 0,
        "repulsion_violations": 0,
        "first_repulsion_violation": "",
        "density_fallback_pairs_skipped": 0,
    }


def marker_pair_text(a: Entry, b: Entry) -> str:
    return "|".join(
        [
            a.klass,
            "topup" if a.topup else "native",
            "placed" if a.placed else "unplaced",
            b.klass,
            "topup" if b.topup else "native",
            "placed" if b.placed else "unplaced",
            str(a.hex_key),
        ]
    )


def audit_pair(report: dict[str, object], a: Entry, b: Entry) -> None:
    duplicate = a.hex_key is not None and a.hex_key == b.hex_key
    if duplicate:
        report["duplicate_hex_pairs"] += 1
        if report["first_duplicate_hex_pair"] == "":
            report["first_duplicate_hex_pair"] = marker_pair_text(a, b)

    hd = hex_distance(a, b)
    if hd is not None:
        neighbours = hd > 0 and a.surface and b.surface
        if not neighbours and hd < MIN_ENRICHMENT:
            report["enrichment_spacing_violations"] += 1
            if report["first_enrichment_spacing_violation"] == "":
                report["first_enrichment_spacing_violation"] = "|".join(
                    [
                        a.klass,
                        str(a.hex_key),
                        b.klass,
                        str(b.hex_key),
                        f"required={MIN_ENRICHMENT}",
                        f"actual={hd}",
                    ]
                )
        if a.quota and b.quota and hd < MIN_QUOTA:
            report["surface_quota_spacing_violations"] += 1
            if report["first_surface_quota_spacing_violation"] == "":
                report["first_surface_quota_spacing_violation"] = "|".join(
                    [
                        str(a.hex_key),
                        str(b.hex_key),
                        f"required={MIN_QUOTA}",
                        f"actual={hd}",
                    ]
                )
        if (a.outer or b.outer) and ((a.outer and b.anomaly) or (b.outer and a.anomaly)):
            if hd < MIN_OUTER_ANOMALY:
                report["outer_ring_spacing_violations"] += 1

    has_outer = a.outer or b.outer
    has_quota = a.quota or b.quota
    if not has_quota and (not has_outer or a.inner or b.inner):
        required = pair_radius(a.profile, b.profile)
        dx, dy = a.x - b.x, a.y - b.y
        distance_sq = dx * dx + dy * dy
        if required is not None and distance_sq <= required * required:
            report["repulsion_violations"] += 1
            if report["first_repulsion_violation"] == "":
                report["first_repulsion_violation"] = "|".join(
                    [
                        a.klass,
                        "topup" if a.topup else "native",
                        str(a.hex_key),
                        b.klass,
                        "topup" if b.topup else "native",
                        str(b.hex_key),
                        f"required={required}",
                        f"actual={math.floor(math.sqrt(distance_sq) + 0.5)}",
                    ]
                )


def legacy(entries: list[Entry]) -> tuple[dict[str, object], int]:
    report = empty_report(entries)
    visited = 0
    for i, a in enumerate(entries[:-1]):
        for b in entries[i + 1 :]:
            if not a.topup and not b.topup:
                report["native_pairs_skipped"] += 1
                continue
            report["checked_pairs"] += 1
            visited += 1
            audit_pair(report, a, b)
    return report, visited


def bucket_key(value: int, size: int) -> int:
    return math.floor((value + 0.0) / size)


def add_bucket(buckets: dict[tuple[int, int], list[int]], key: tuple[int, int], idx: int) -> None:
    buckets.setdefault(key, []).append(idx)


def indexed(entries: list[Entry]) -> tuple[dict[str, object], int]:
    report = empty_report(entries)
    native = sum(not e.topup for e in entries)
    total = len(entries) * (len(entries) - 1) // 2
    skipped = native * (native - 1) // 2
    report["native_pairs_skipped"] = skipped
    report["checked_pairs"] = total - skipped

    max_component = 0
    for entry in entries:
        p = entry.profile
        if p is not None:
            max_component = max(max_component, p.same, p.layer_radius, p.all_radius)
    world_size = max(1, math.ceil(2 * max_component))
    hex_size = max(MIN_ENRICHMENT, MIN_OUTER_ANOMALY, MIN_QUOTA)
    world: dict[tuple[int, int], list[int]] = {}
    hexb: dict[tuple[int, int], list[int]] = {}
    for idx, e in enumerate(entries):
        add_bucket(world, (bucket_key(e.x, world_size), bucket_key(e.y, world_size)), idx)
        if e.q is not None and e.r is not None:
            add_bucket(hexb, (bucket_key(e.q, hex_size), bucket_key(e.r, hex_size)), idx)

    marks = [0] * len(entries)
    serial = 0
    visited = 0
    for i, a in enumerate(entries[:-1]):
        serial += 1
        nearby: list[int] = []
        keys: list[tuple[dict[tuple[int, int], list[int]], int, int]] = [
            (world, bucket_key(a.x, world_size), bucket_key(a.y, world_size))
        ]
        if a.q is not None and a.r is not None:
            keys.append((hexb, bucket_key(a.q, hex_size), bucket_key(a.r, hex_size)))
        for buckets, bx, by in keys:
            for ox in (-1, 0, 1):
                for oy in (-1, 0, 1):
                    for j in buckets.get((bx + ox, by + oy), ()):
                        if j <= i or marks[j] == serial:
                            continue
                        marks[j] = serial
                        nearby.append(j)
        nearby.sort()
        for j in nearby:
            b = entries[j]
            if not a.topup and not b.topup:
                continue
            visited += 1
            audit_pair(report, a, b)
    return report, visited


PROFILES = (
    Profile("surf", "Metals", 6400, 6400, 12800),
    Profile("surf", "Concrete", 20000, 6400, 12800),
    Profile("subs", "Water", 25600, 6400, 12800),
    Profile("subs", "PreciousMetals", 20000, 4800, 12800),
    Profile("subs", "Anomaly", 3200, 6400, 7200),
    Profile("surf", "Effects", 12000, 6400, 7200),
)


def world_from_hex(q: int, r: int) -> tuple[int, int]:
    # Only spatial density matters to the candidate index; exact rule decisions are
    # still made from q/r and integer world coordinates by both implementations.
    return q * 1000 + r * 500, r * 866


def random_corpus(seed: int, n: int = OBSERVED_MARKERS, topups: int = OBSERVED_TOPUPS) -> list[Entry]:
    rng = random.Random(seed)
    result: list[Entry] = []
    topup_ids = set(rng.sample(range(n), topups))
    quota_ids = set(rng.sample(sorted(topup_ids), 21))
    outer_ids = set(rng.sample(sorted(topup_ids - quota_ids), 20))
    for i in range(n):
        q, r = rng.randrange(-20, 841), rng.randrange(-20, 967)
        x, y = world_from_hex(q, r)
        profile = PROFILES[rng.randrange(len(PROFILES))]
        anomaly = profile.resource == "Anomaly"
        result.append(
            Entry(
                ident=i,
                klass="SurfaceDepositMarker" if profile.layer == "surf" else "SubsurfaceDepositMarker",
                topup=i in topup_ids,
                outer=i in outer_ids and anomaly,
                inner=False,
                quota=i in quota_ids,
                anomaly=anomaly,
                surface=profile.layer == "surf" and profile.resource not in ("Effects",),
                x=x,
                y=y,
                q=q,
                r=r,
                profile=profile,
                placed=(i % 11) != 0,
            )
        )
    return result


def adversarial_corpus() -> list[Entry]:
    result = random_corpus(961, 96, 44)
    boundary = [
        # Negative buckets, duplicate hex, enrichment 2/3 boundary, outer 9/10,
        # quota 2/3, and world-distance radius-1/radius/radius+1 cases.
        (-13, -17, True, False, False, PROFILES[0]),
        (-13, -17, False, False, False, PROFILES[1]),
        (-11, -17, True, False, False, PROFILES[2]),
        (-10, -17, True, False, False, PROFILES[3]),
        (20, 20, True, True, False, PROFILES[4]),
        (29, 20, False, False, False, PROFILES[4]),
        (30, 20, True, False, False, PROFILES[4]),
        (40, 40, True, False, True, PROFILES[0]),
        (42, 40, True, False, True, PROFILES[1]),
        (43, 40, True, False, True, PROFILES[2]),
    ]
    for offset, (q, r, topup, outer, quota, profile) in enumerate(boundary):
        x, y = world_from_hex(q, r)
        result.append(
            Entry(
                ident=1000 + offset,
                klass="SurfaceDepositMarker" if profile.layer == "surf" else "SubsurfaceDepositMarker",
                topup=topup,
                outer=outer,
                inner=offset == 6,
                quota=quota,
                anomaly=profile.resource == "Anomaly",
                surface=profile.layer == "surf" and profile.resource != "Effects",
                x=x,
                y=y,
                q=q,
                r=r,
                profile=profile,
                placed=offset % 2 == 0,
            )
        )
    # Invalid hex conversion must still participate in world repulsion.
    base = result[-1]
    result.append(
        Entry(2000, "SubsurfaceDepositMarker", True, False, False, False, False, False,
              base.x + 12799, base.y, None, None, PROFILES[3])
    )
    return result


def assert_equal(entries: list[Entry], label: str) -> tuple[int, int]:
    expected, legacy_visited = legacy(entries)
    actual, indexed_visited = indexed(entries)
    if actual != expected:
        keys = sorted(k for k in expected if expected[k] != actual[k])
        raise AssertionError(
            f"{label}: report mismatch "
            + json.dumps({k: {"legacy": expected[k], "indexed": actual[k]} for k in keys}, sort_keys=True)
        )
    return legacy_visited, indexed_visited


def benchmark(entries: list[Entry], rounds: int = 7) -> tuple[float, float]:
    legacy_times: list[float] = []
    indexed_times: list[float] = []
    for _ in range(rounds):
        start = time.perf_counter()
        legacy(entries)
        legacy_times.append((time.perf_counter() - start) * 1000)
        start = time.perf_counter()
        indexed(entries)
        indexed_times.append((time.perf_counter() - start) * 1000)
    return statistics.median(legacy_times), statistics.median(indexed_times)


def main() -> int:
    corpora = [("adversarial", adversarial_corpus())]
    for seed in range(64):
        size = 128 + (seed % 8) * 16
        topups = max(41, round(size * OBSERVED_TOPUPS / OBSERVED_MARKERS))
        corpora.append((f"random-{seed}", random_corpus(seed, size, topups)))
    total_legacy = total_indexed = 0
    for label, corpus in corpora:
        legacy_visited, indexed_visited = assert_equal(corpus, label)
        total_legacy += legacy_visited
        total_indexed += indexed_visited

    representative = random_corpus(20260828)
    legacy_visited, indexed_visited = assert_equal(representative, "representative")
    legacy_ms, indexed_ms = benchmark(representative)
    projected_ms = OBSERVED_AUDIT_MS * (1.0 - indexed_ms / legacy_ms)
    result = {
        "schema": "smr.ralph.v961.hard-spacing-spatial-oracle.v1",
        "corpora": len(corpora) + 1,
        "reports_exact": True,
        "representative_markers": len(representative),
        "representative_checked_pairs": legacy_visited,
        "representative_candidate_pairs": indexed_visited,
        "representative_pruned_pairs": legacy_visited - indexed_visited,
        "candidate_ratio": indexed_visited / legacy_visited,
        "python_legacy_median_ms": legacy_ms,
        "python_indexed_median_ms": indexed_ms,
        "projected_engine_saving_ms": projected_ms,
        "minimum_required_saving_ms": 500.0,
        "aggregate_legacy_pairs": total_legacy,
        "aggregate_indexed_pairs": total_indexed,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    if projected_ms < 500.0:
        raise SystemExit("NO-GO: projected saving is below 500 ms")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

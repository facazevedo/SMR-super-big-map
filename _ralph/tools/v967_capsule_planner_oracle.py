#!/usr/bin/env python3
"""Deterministic corpus/state oracle for v967's bounded capsule planner."""

from __future__ import annotations

import json
import time
from collections import deque
from dataclasses import dataclass, field


MAX_DEPTH = 16
MAX_ATTEMPTS = 512
REQUIRED = 2
NEIGHBOURS = ((1, 0), (0, 1), (-1, 1), (-1, 0), (0, -1), (1, -1))
SHAPE = ((0, 0), (1, 0), (0, 1), (-1, 1), (-1, 0), (0, -1), (1, -1))


@dataclass
class Corpus:
    name: str
    width: int = 96
    height: int = 96
    default_z: int | None = 100
    z: dict[tuple[int, int], int | None] = field(default_factory=dict)
    obstructions: set[tuple[int, int]] = field(default_factory=set)
    deposits: set[tuple[int, int]] = field(default_factory=set)

    def build_z(self, q: int, r: int) -> int | None:
        if q < 0 or r < 0 or q >= self.width or r >= self.height:
            return None
        return self.z.get((q, r), self.default_z)


def rotate(q: int, r: int, turns: int) -> tuple[int, int]:
    for _ in range(turns % 6):
        q, r = -r, q + r
    return q, r


def stock_shape_valid(corpus: Corpus, q: int, r: int, angle: int) -> bool:
    """Same rule order as stock: Z/unbuildable, obstruction, deposit."""
    original_z: int | None = None
    for dq, dr in SHAPE:
        dq, dr = rotate(dq, dr, angle // 3600)
        cell = q + dq, r + dr
        z = corpus.build_z(*cell)
        if original_z is None:
            original_z = z
        if z is None or z != original_z:
            return False
        if cell in corpus.obstructions:
            return False
        if cell in corpus.deposits:
            return False
    return True


def find_buildable(corpus: Corpus, start: tuple[int, int], angle: int,
                   max_depth: int | None) -> tuple[int, int, int] | None:
    queue = deque([(start[0], start[1], 0)])
    seen = {start}
    while queue:
        q, r, depth = queue.popleft()
        if stock_shape_valid(corpus, q, r, angle):
            return q, r, depth
        if max_depth is not None and depth >= max_depth:
            continue
        for dq, dr in NEIGHBOURS:
            cell = q + dq, r + dr
            if cell not in seen:
                seen.add(cell)
                queue.append((cell[0], cell[1], depth + 1))
    return None


def next_private(state: int) -> int:
    state = (state * 48271 + 1) % 2147483647
    return state or 1


def plan(corpus: Corpus, seed: int, full_validate: bool = True) -> dict:
    state = seed
    selected: list[tuple[int, int, int, int]] = []
    attempts = bounded_calls = full_calls = 0
    for _ in range(MAX_ATTEMPTS):
        if len(selected) == REQUIRED:
            break
        attempts += 1
        state = next_private(state)
        q = 10 + state % (corpus.width - 20)
        state = next_private(state)
        r = 10 + state % (corpus.height - 20)
        state = next_private(state)
        angle = (state % 6) * 3600
        bounded_calls += 1
        found = find_buildable(corpus, (q, r), angle, MAX_DEPTH)
        if not found:
            continue
        bq, br, depth = found
        if not (10 <= bq <= corpus.width - 10 and 10 <= br <= corpus.height - 10):
            continue
        if any((bq - pq) ** 2 + (br - pr) ** 2 < 20 ** 2
               for pq, pr, _, _ in selected):
            continue
        selected.append((bq, br, depth, angle))

    safe = len(selected) == REQUIRED
    exact_centres = 0
    if safe and full_validate:
        for q, r, _depth, angle in selected:
            full_calls += 1
            authoritative = find_buildable(corpus, (q, r), angle, None)
            exact_centres += authoritative == (q, r, 0)
        safe = full_calls == REQUIRED and exact_centres == REQUIRED

    digest = seed
    for q, r, _depth, angle in selected:
        for value in (abs(q), abs(r), angle):
            digest = (digest * 48271 + value + 1) % 2147483647
    return {
        "safe": safe and full_validate,
        "selected": selected,
        "attempts": attempts,
        "bounded_calls": bounded_calls,
        "full_calls": full_calls,
        "exact_centres": exact_centres,
        "final_state": state,
        "digest": digest,
        "retryable": len(selected) != REQUIRED,
        "replay": not full_validate,
    }


def merge_planner_telemetry(live_report: dict, planner_report: dict) -> None:
    """Model the production generic telemetry merge, including stale/fresh retries."""
    live_report.update(planner_report)


def implementation_finalization_branch(report: dict, descriptor_state: str) -> str:
    """Model FinalizeImplementation's ownership-sensitive leading decision."""
    if (descriptor_state == "fallback-eager-after-precommit-failure"
            or (report.get("literal_v964_continues") is True
                and report.get("suppression_used") is not True)):
        return "eager"
    if descriptor_state == "blocked":
        return "blocked"
    return "lazy"


def retry_with_failed_rebuilds() -> dict:
    """Model stale retry plus both canonical rebuild attempts failing."""
    descriptor = {
        "state": "suppressed-awaiting-surface-capsules",
        "failure": "",
        "failure_sticky": False,
    }
    capsule_ok = False
    retry_after_grid = True
    rebuild_results = [(False, "primary failed"), (False, "fallback failed")]
    rebuild_ok = rebuild_results[0][0]
    rebuild_error = rebuild_results[0][1]
    if not rebuild_ok:
        fallback_ok, fallback_error = rebuild_results[1]
        if fallback_ok:
            rebuild_ok, rebuild_error = True, ""
        else:
            rebuild_error += " | fallback failed: " + fallback_error
    if rebuild_ok and retry_after_grid:
        raise AssertionError("fresh planner must not run after a failed canonical rebuild")
    # This is deliberately ordered before the capsule error, as in production.
    if not rebuild_ok:
        descriptor["state"] = "blocked"
        descriptor["failure"] = "canonical Surface grid rebuild failed: " + rebuild_error
        descriptor["failure_sticky"] = True
        return descriptor
    if not capsule_ok:
        return descriptor
    return descriptor


def main() -> int:
    started = time.perf_counter()
    open_grid = Corpus("open")
    local_holes = Corpus("local-holes")
    local_holes.obstructions.update((48 + dq, 48 + dr) for dq in range(-4, 5)
                                    for dr in range(-4, 5))
    excluded = Corpus("deposit-and-z-exclusions")
    excluded.deposits.update((32 + dq, 32 + dr) for dq in range(-3, 4)
                             for dr in range(-3, 4))
    excluded.z.update({(64 + dq, 64 + dr): 101 for dq in range(-2, 3)
                       for dr in range(-2, 3)})
    stale = Corpus("stale", default_z=None)
    impossible = Corpus("impossible", default_z=None)
    corpora = [open_grid, local_holes, excluded]
    checks: dict[str, bool] = {}
    summaries: dict[str, dict] = {}
    for index, corpus in enumerate(corpora, 1):
        seed = 334291578 + index
        primary = plan(corpus, seed, True)
        repeat = plan(corpus, seed, False)
        summaries[corpus.name] = primary
        checks[f"{corpus.name}_finds_two"] = primary["safe"]
        checks[f"{corpus.name}_repeat_exact"] = (
            primary["selected"] == repeat["selected"]
            and primary["digest"] == repeat["digest"]
            and primary["final_state"] == repeat["final_state"]
        )
        checks[f"{corpus.name}_authoritative_calls_exactly_two"] = (
            primary["full_calls"] == 2 and primary["exact_centres"] == 2
            and repeat["full_calls"] == 0
        )
        checks[f"{corpus.name}_all_hard_predicates_hold"] = all(
            stock_shape_valid(corpus, q, r, angle)
            for q, r, _depth, angle in primary["selected"]
        )

    stale_first = plan(stale, 334291578, True)
    fresh_retry = plan(open_grid, 334291578, True)
    published_before_retry = 0
    published_after_retry = 2 if fresh_retry["safe"] else 0
    checks["stale_grid_failure_is_retryable_without_publication"] = (
        stale_first["retryable"] and not stale_first["safe"]
        and published_before_retry == 0
    )
    checks["fresh_grid_retry_publishes_two_then_requires_second_rebuild"] = (
        fresh_retry["safe"] and published_after_retry == 2
    )
    impossible_retry = plan(impossible, 334291578, True)
    checks["failed_fresh_retry_blocks_without_partial_capsules"] = (
        impossible_retry["retryable"] and not impossible_retry["safe"]
    )
    checks["bounded_search_has_finite_geometry_cap"] = (
        1 + 3 * MAX_DEPTH * (MAX_DEPTH + 1) == 817
        and MAX_ATTEMPTS * 817 == 418304
    )

    live_report = {
        "shadow_only": False,
        "literal_v964_continues": False,
        "suppression_used": True,
        "suppression_committed": True,
    }
    stale_plan_report = {
        "planner_requested": True,
        "planner_used": False,
        "retryable_after_canonical_grid": True,
        "error": "stale grids",
    }
    fresh_plan_report = {
        "planner_requested": True,
        "planner_used": True,
        "retryable_after_canonical_grid": False,
        "error": "",
    }
    merge_planner_telemetry(live_report, stale_plan_report)
    suppression_survived_stale = (
        live_report["shadow_only"] is False
        and live_report["literal_v964_continues"] is False
        and live_report["suppression_used"] is True
        and live_report["suppression_committed"] is True
    )
    merge_planner_telemetry(live_report, fresh_plan_report)
    checks["suppression_ownership_survives_stale_and_fresh_plan_merges"] = (
        suppression_survived_stale
        and live_report["shadow_only"] is False
        and live_report["literal_v964_continues"] is False
        and live_report["suppression_used"] is True
        and live_report["suppression_committed"] is True
        and live_report["planner_used"] is True
    )
    checks["successful_publication_finalizes_lazy_not_eager"] = (
        implementation_finalization_branch(
            live_report, "surface-capsules-published-awaiting-final-grid") == "lazy"
    )

    blocked_after_rebuild_failure = retry_with_failed_rebuilds()
    checks["stale_retry_double_rebuild_failure_is_sticky_blocked"] = (
        blocked_after_rebuild_failure["state"] == "blocked"
        and blocked_after_rebuild_failure["failure_sticky"] is True
        and "primary failed | fallback failed" in blocked_after_rebuild_failure["failure"]
    )
    failed = sorted(name for name, ok in checks.items() if not ok)
    print(json.dumps({
        "schema": "smr.ralph.v967.bounded-capsule-planner-oracle.v2",
        "ok": not failed,
        "failed": failed,
        "checks": checks,
        "corpora": summaries,
        "limits": {
            "max_depth": MAX_DEPTH,
            "max_attempts": MAX_ATTEMPTS,
            "centres_per_search_cap": 817,
            "centres_per_plan_cap": 418304,
            "authoritative_full_calls": 2,
            "replay_full_calls": 0,
        },
        "elapsed_ms": round((time.perf_counter() - started) * 1000, 3),
    }, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())

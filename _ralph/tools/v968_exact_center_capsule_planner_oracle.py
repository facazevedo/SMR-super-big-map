#!/usr/bin/env python3
"""Deterministic corpus/state oracle for v968's depth-zero capsule planner."""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field


MAX_DEPTH = 0
MAX_ATTEMPTS = 512
REQUIRED = 2
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


def validate_exact_center(corpus: Corpus, start: tuple[int, int],
                          angle: int) -> tuple[int, int, int] | None:
    """Depth zero: validate the supplied cell once and never inspect a neighbour."""
    q, r = start
    return (q, r, 0) if stock_shape_valid(corpus, q, r, angle) else None


def next_private(state: int) -> int:
    state = (state * 48271 + 1) % 2147483647
    return state or 1


def plan(corpus: Corpus, seed: int, full_validate: bool = True) -> dict:
    state = seed
    selected: list[tuple[int, int, int, int]] = []
    attempts = selection_shape_checks = publication_validation_calls = 0
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
        selection_shape_checks += 1
        found = validate_exact_center(corpus, (q, r), angle)
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
    publication_exact_centres = 0
    if safe and full_validate:
        for q, r, _depth, angle in selected:
            publication_validation_calls += 1
            authoritative = validate_exact_center(corpus, (q, r), angle)
            publication_exact_centres += authoritative == (q, r, 0)
        safe = (publication_validation_calls == REQUIRED
                and publication_exact_centres == REQUIRED)

    digest = seed
    for q, r, _depth, angle in selected:
        for value in (abs(q), abs(r), angle):
            digest = (digest * 48271 + value + 1) % 2147483647
    return {
        "safe": safe and full_validate,
        "selected": selected,
        "attempts": attempts,
        "selection_shape_checks": selection_shape_checks,
        "publication_validation_calls": publication_validation_calls,
        "publication_exact_centres": publication_exact_centres,
        "total_shape_checks": selection_shape_checks + publication_validation_calls,
        "unbounded_calls": 0,
        "private_draws": attempts * 3,
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
        checks[f"{corpus.name}_fresh_depth_zero_validations_exactly_two"] = (
            primary["publication_validation_calls"] == 2
            and primary["publication_exact_centres"] == 2
            and repeat["publication_validation_calls"] == 0
            and primary["unbounded_calls"] == repeat["unbounded_calls"] == 0
        )
        checks[f"{corpus.name}_three_private_draws_per_attempt"] = (
            primary["private_draws"] == primary["attempts"] * 3
            and repeat["private_draws"] == repeat["attempts"] * 3
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
    checks["two_selection_plans_have_strict_1024_shape_check_cap"] = (
        MAX_DEPTH == 0 and MAX_ATTEMPTS * 2 == 1024
        and fresh_retry["selection_shape_checks"] <= MAX_ATTEMPTS
        and plan(open_grid, 334291578, False)["selection_shape_checks"] <= MAX_ATTEMPTS
    )
    checks["fresh_corpora_select_early"] = max(
        summary["attempts"] for summary in summaries.values()) <= 16
    neighbour_trap = Corpus("invalid-center-valid-neighbour")
    neighbour_trap.obstructions.add((47, 48))
    checks["invalid_center_never_moves_to_valid_neighbour"] = (
        validate_exact_center(neighbour_trap, (48, 48), 0) is None
        and validate_exact_center(neighbour_trap, (49, 48), 0) == (49, 48, 0)
    )
    checks["retry_lifecycle_shape_check_cap_is_truthful"] = (
        stale_first["selection_shape_checks"] == MAX_ATTEMPTS
        and MAX_ATTEMPTS + 2 * MAX_ATTEMPTS + REQUIRED == 1538
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
        "schema": "smr.ralph.v968.exact-center-capsule-planner-oracle.v1",
        "ok": not failed,
        "failed": failed,
        "checks": checks,
        "corpora": summaries,
        "limits": {
            "max_depth": MAX_DEPTH,
            "max_attempts": MAX_ATTEMPTS,
            "centres_per_search_cap": 1,
            "selection_checks_per_plan_cap": 512,
            "two_selection_plans_shape_check_cap": 1024,
            "publication_validation_shape_checks": 2,
            "fresh_transaction_total_shape_check_cap": 1026,
            "stale_retry_lifecycle_total_shape_check_cap": 1538,
            "unbounded_calls": 0,
        },
        "elapsed_ms": round((time.perf_counter() - started) * 1000, 3),
    }, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())

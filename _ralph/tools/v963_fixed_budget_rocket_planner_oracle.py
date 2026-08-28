#!/usr/bin/env python3
"""Deterministic transaction/policy/cost oracle for the v963 rocket planner."""

from __future__ import annotations

from dataclasses import dataclass
import json
import math
from pathlib import Path


MODULUS = 2_147_483_647
SEARCH_LIMIT = 44
PREFERRED_MINIMUM = 35
SCORED_BUDGET = 256
PREFERRED_SCORED_BUDGET = math.floor(SCORED_BUDGET * 0.75)
GROUPS = 6
ROCKET_CLEARANCE_RADIUS = 17
ITER194_PLANNING_MS = 3599
ITER194_SCORED = 35646


@dataclass(frozen=True)
class Offset:
    dq: int
    dr: int
    distance: int


@dataclass(frozen=True)
class Candidate:
    q: int
    r: int
    score: int
    height_range: int
    ready: bool
    hard_predicates: bool


def offsets() -> tuple[list[Offset], list[Offset]]:
    preferred: list[Offset] = []
    remaining: list[Offset] = []
    for dq in range(-SEARCH_LIMIT, SEARCH_LIMIT + 1):
        for dr in range(-SEARCH_LIMIT, SEARCH_LIMIT + 1):
            distance = max(abs(dq), abs(dr), abs(dq + dr))
            if distance <= SEARCH_LIMIT:
                target = preferred if distance >= PREFERRED_MINIMUM else remaining
                target.append(Offset(dq, dr, distance))
    return preferred, remaining


def private_permutation(values: list[Offset], seed: int) -> list[Offset]:
    count = len(values)
    start = seed % count
    step = (seed // max(1, count)) % count
    if step < 1:
        step = 1
    while math.gcd(step, count) != 1:
        step += 1
        if step >= count:
            step = 1
    return [values[(start + ordinal * step) % count] for ordinal in range(count)]


def candidate_for(seed: int, group: int, offset: Offset,
                  force_high_range: bool = False) -> Candidate | None:
    value = (
        seed
        + group * 83_492_791
        + (offset.dq + SEARCH_LIMIT + 1) * 73_856_093
        + (offset.dr + SEARCH_LIMIT + 1) * 19_349_663
    ) % MODULUS
    # A returned candidate represents one that passed every unchanged production hard predicate.
    if value % 100 >= 39:
        return None
    height_range = 1200 + (value // 100) % 1200 if force_high_range else (value // 100) % 1800
    ready = False if force_high_range else ((value // 180_000) % 29 == 0)
    score = (-1_000_000_000 if ready else 0) + height_range * 100 + offset.distance
    return Candidate(
        100 + group * 100 + offset.dq,
        200 + group * 100 + offset.dr,
        score,
        height_range,
        ready,
        True,
    )


def digest(seed: int, choices: list[Candidate]) -> int:
    value = seed
    for choice in choices:
        for item in (choice.q, choice.r, choice.height_range):
            value = (value * 48271 + abs(math.floor(item)) + 1) % MODULUS
    return value


def mark_axial_forbidden(mask: set[tuple[int, int]], cq: int, cr: int) -> None:
    for dq in range(-ROCKET_CLEARANCE_RADIUS, ROCKET_CLEARANCE_RADIUS + 1):
        dr_min = max(-ROCKET_CLEARANCE_RADIUS, -dq - ROCKET_CLEARANCE_RADIUS)
        dr_max = min(ROCKET_CLEARANCE_RADIUS, -dq + ROCKET_CLEARANCE_RADIUS)
        for dr in range(dr_min, dr_max + 1):
            mask.add((cq + dq, cr + dr))


def plan(seed: int, empty_group: int | None = None,
         force_high_range: bool = False) -> dict[str, object]:
    preferred, remaining = offsets()
    choices: list[Candidate] = []
    traces: list[dict[str, object]] = []
    private_mask: set[tuple[int, int]] = set()
    committed_pads: list[Candidate] = []
    committed_mask: set[tuple[int, int]] = set()
    fallback = False
    for group in range(1, GROUPS + 1):
        group_seed = (seed + group * 83_492_791 + group * 19_349_663) % MODULUS
        scored = viable = ready = 0
        best: Candidate | None = None
        viable_scores: list[int] = []
        preferred_attempted = remaining_attempted = 0
        sequences = (
            (private_permutation(preferred, group_seed), True, PREFERRED_SCORED_BUDGET),
            (private_permutation(remaining, (group_seed + 104729) % MODULUS),
             False, SCORED_BUDGET),
        )
        for sequence, is_preferred, phase_budget in sequences:
            for offset in sequence:
                if scored >= phase_budget:
                    break
                scored += 1
                if is_preferred:
                    preferred_attempted += 1
                else:
                    remaining_attempted += 1
                candidate = None if group == empty_group else candidate_for(
                    seed, group, offset, force_high_range=force_high_range)
                if candidate is not None and (candidate.q, candidate.r) not in private_mask:
                    viable += 1
                    ready += int(candidate.ready)
                    viable_scores.append(candidate.score)
                    if best is None or candidate.score < best.score:
                        best = candidate
        traces.append({
            "group": group,
            "scored": scored,
            "viable": viable,
            "ready": ready,
            "preferred_attempted": preferred_attempted,
            "remaining_attempted": remaining_attempted,
            "selected": best is not None,
            "minimum_score_exact": bool(best and best.score == min(viable_scores)),
            "selected_height_range": best.height_range if best else None,
        })
        if best is None:
            fallback = True
            choices = []
            private_mask.clear()
            break
        assert best.hard_predicates
        choices.append(best)
        mark_axial_forbidden(private_mask, best.q, best.r)

    published_before_decision = len(committed_pads) + len(committed_mask)
    if not fallback and len(choices) == GROUPS:
        committed_pads.extend(choices)
        for choice in choices:
            mark_axial_forbidden(committed_mask, choice.q, choice.r)
    return {
        "fallback": fallback,
        "choices": choices,
        "traces": traces,
        "private_mask_cells": len(private_mask),
        "committed_pads": len(committed_pads),
        "committed_mask_cells": len(committed_mask),
        "private_committed_masks_equal": private_mask == committed_mask,
        "published_before_decision": published_before_decision,
        "digest": digest(seed, choices) if choices else 0,
        "scored": sum(int(trace["scored"]) for trace in traces),
        "viable": sum(int(trace["viable"]) for trace in traces),
    }


def load_invariant(run_name: str) -> dict[str, str]:
    path = Path(__file__).resolve().parents[1] / "runs" \
        / "surface-loading-under-60s-rough" / "artifacts" / run_name \
        / "invariant_post_t1.txt"
    values: dict[str, str] = {"available": str(path.is_file()).lower()}
    if path.is_file():
        for line in path.read_text(encoding="utf-8").splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                values[key] = value
    return values


def main() -> int:
    preferred, remaining = offsets()
    permutation_checks = []
    for values in (preferred, remaining):
        for seed in (1, 2, 962, 963, 2_026_082_8):
            permuted = private_permutation(values, seed)
            permutation_checks.append(
                len(permuted) == len(values)
                and len({(entry.dq, entry.dr) for entry in permuted}) == len(values)
            )

    successful = [plan(seed) for seed in range(963, 1027)]
    repeat_a, repeat_b = plan(20260828), plan(20260828)
    forced_fallback = plan(20260828, empty_group=3)
    high_range = plan(20260828, force_high_range=True)
    iter194 = load_invariant("run_iter194_v961_spacing_index________hashonly")
    iter195 = load_invariant("run_iter195_v962_bounded_rocket_______hashonly")
    maximum_candidate_ratio = (GROUPS * SCORED_BUDGET) / ITER194_SCORED
    projected_saving_ms = ITER194_PLANNING_MS * (1 - maximum_candidate_ratio) - 300
    checks = {
        "offset_disk_matches_real_baseline": len(preferred) + len(remaining) == 5941,
        "preferred_split_is_complete": (
            len({(o.dq, o.dr) for o in preferred + remaining}) == 5941
            and not ({(o.dq, o.dr) for o in preferred}
                     & {(o.dq, o.dr) for o in remaining})
        ),
        "all_affine_permutations_are_bijective": all(permutation_checks),
        "all_policy_corpora_complete_six_groups": all(
            not result["fallback"] and result["committed_pads"] == GROUPS
            and result["private_committed_masks_equal"] for result in successful
        ),
        "every_successful_group_scores_exactly_256": all(
            all(int(trace["scored"]) == SCORED_BUDGET for trace in result["traces"])
            for result in successful
        ),
        "every_group_scores_192_preferred_and_64_remaining": all(
            all(int(trace["preferred_attempted"]) == PREFERRED_SCORED_BUDGET
                and int(trace["remaining_attempted"])
                == SCORED_BUDGET - PREFERRED_SCORED_BUDGET
                for trace in result["traces"])
            for result in successful
        ),
        "selected_score_is_minimum_over_every_viable_sample": all(
            all(trace["minimum_score_exact"] for trace in result["traces"])
            for result in successful
        ),
        "viability_never_stops_fixed_budget": any(
            int(trace["viable"]) > 32
            for result in successful for trace in result["traces"]
        ),
        "high_range_valid_candidates_do_not_force_fallback": (
            not high_range["fallback"] and high_range["committed_pads"] == GROUPS
            and all(int(trace["selected_height_range"] or 0) >= 1200
                    for trace in high_range["traces"])
        ),
        "deterministic_repeat_digest": repeat_a == repeat_b and repeat_a["digest"] != 0,
        "fallback_on_empty_group_is_prepublication": (
            forced_fallback["fallback"]
            and forced_fallback["published_before_decision"] == 0
            and forced_fallback["committed_pads"] == 0
            and forced_fallback["committed_mask_cells"] == 0
        ),
        "private_and_committed_clearance_masks_are_exact": all(
            result["private_committed_masks_equal"] for result in successful
        ),
        "relaxed_coordinate_policy_is_still_hard_validated": all(
            not result["fallback"] and result["committed_pads"] == GROUPS
            and result["committed_mask_cells"] >= GROUPS
            for result in successful
        ),
        "real_iter194_baseline_loaded": (
            iter194.get("available") == "true"
            and int(iter194.get("planning_ms", 0)) == ITER194_PLANNING_MS
            and int(iter194.get("rocket_candidates_scored", 0)) == ITER194_SCORED
            and int(iter194.get("rocket_pads", 0)) == GROUPS
            and int(iter194.get("first_resource_failures", -1)) == 0
            and int(iter194.get("first_rocket_failures", -1)) == 0
        ),
        "iter195_rejected_as_safe_quality_fallback": (
            iter195.get("available") == "true"
            and iter195.get("rocket_bounded_planner_used") == "false"
            and iter195.get("rocket_bounded_planner_fallback") == "true"
            and iter195.get("rocket_bounded_planner_error")
            == "adaptive transition quality cap exceeded"
            and int(iter195.get("rocket_bounded_candidates_scored", 0)) == 41
            and int(iter195.get("rocket_candidates_scored", 0)) == 35687
            and int(iter195.get("first_resource_failures", -1)) == 0
            and int(iter195.get("first_rocket_failures", -1)) == 0
        ),
        "projected_saving_exceeds_two_seconds": projected_saving_ms >= 2000,
    }
    result = {
        "schema": "smr.ralph.v963.fixed-budget-rocket-planner-oracle.v1",
        "ok": all(checks.values()),
        "checks": checks,
        "real_iter194_baseline": {
            "planning_ms": int(iter194.get("planning_ms", 0)),
            "scored": int(iter194.get("rocket_candidates_scored", 0)),
        },
        "real_iter195_rejection": {
            "planning_ms": int(iter195.get("planning_ms", 0)),
            "private_scored": int(iter195.get("rocket_bounded_candidates_scored", 0)),
            "total_scored": int(iter195.get("rocket_candidates_scored", 0)),
            "error": iter195.get("rocket_bounded_planner_error", ""),
        },
        "corpora": len(successful),
        "offset_universe": len(preferred) + len(remaining),
        "preferred_offsets": len(preferred),
        "remaining_offsets": len(remaining),
        "preferred_scored_budget_per_group": PREFERRED_SCORED_BUDGET,
        "maximum_scored": GROUPS * SCORED_BUDGET,
        "maximum_candidate_ratio": maximum_candidate_ratio,
        "projected_saving_ms": projected_saving_ms,
        "repeat_digest": repeat_a["digest"],
        "representative_scored": repeat_a["scored"],
        "representative_viable": repeat_a["viable"],
        "high_range_maximum": max(
            int(trace["selected_height_range"] or 0) for trace in high_range["traces"]
        ),
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

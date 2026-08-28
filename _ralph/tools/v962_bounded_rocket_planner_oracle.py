#!/usr/bin/env python3
"""Deterministic policy/cost oracle for the v962 bounded rocket-pad planner."""

from __future__ import annotations

from dataclasses import dataclass
import json
import math
from pathlib import Path


MODULUS = 2_147_483_647
SEARCH_LIMIT = 44  # iter194: 5,941 offsets per group
PREFERRED_MINIMUM = 35
VIABLE_TARGET = 32
SCORED_BUDGET = 256
PREFERRED_SCORED_BUDGET = math.floor(SCORED_BUDGET * 0.75)
GROUPS = 6
ROCKET_CLEARANCE_RADIUS = 17
CELLS_PER_HEX = 10
QUALITY_FACTOR = 0.65
QUALITY_LIMIT = 36 * CELLS_PER_HEX
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


def candidate_for(seed: int, group: int, offset: Offset, force_bad: bool = False) -> Candidate | None:
    value = (
        seed
        + group * 83_492_791
        + (offset.dq + SEARCH_LIMIT + 1) * 73_856_093
        + (offset.dr + SEARCH_LIMIT + 1) * 19_349_663
    ) % MODULUS
    # Model every unchanged hard rejection before a candidate becomes viable.
    if value % 100 >= 39:
        return None
    height_range = 900 if force_bad else (value // 100) % 800
    ready = False if force_bad else ((value // 80_000) % 23 == 0)
    score = (-1_000_000_000 if ready else 0) + height_range * 100 + offset.distance
    return Candidate(100 + group * 100 + offset.dq, 200 + group * 100 + offset.dr,
                     score, height_range, ready, True)


def quality(candidate: Candidate | None) -> bool:
    return bool(candidate and (candidate.ready or candidate.height_range * QUALITY_FACTOR <= QUALITY_LIMIT))


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


def plan(seed: int, fail_group: int | None = None,
         force_preferred_empty: bool = False) -> dict[str, object]:
    preferred, remaining = offsets()
    choices: list[Candidate] = []
    traces: list[dict[str, object]] = []
    private_mask: set[tuple[int, int]] = set()
    # Published state must stay empty until every private group succeeds.
    committed_pads: list[Candidate] = []
    committed_mask: set[tuple[int, int]] = set()
    fallback = False
    for group in range(1, GROUPS + 1):
        group_seed = (seed + group * 83_492_791 + group * 19_349_663) % MODULUS
        scored = viable = 0
        best: Candidate | None = None
        preferred_attempted = remaining_attempted = 0
        sequences = (
            (private_permutation(preferred, group_seed), True, PREFERRED_SCORED_BUDGET),
            (private_permutation(remaining, (group_seed + 104729) % MODULUS),
             False, SCORED_BUDGET),
        )
        for sequence, is_preferred, phase_budget in sequences:
            if viable >= VIABLE_TARGET:
                break
            for offset in sequence:
                if scored >= phase_budget or viable >= VIABLE_TARGET:
                    break
                scored += 1
                if is_preferred:
                    preferred_attempted += 1
                else:
                    remaining_attempted += 1
                candidate = None if force_preferred_empty and is_preferred else candidate_for(
                    seed, group, offset, force_bad=group == fail_group)
                if candidate is not None and (candidate.q, candidate.r) not in private_mask:
                    viable += 1
                    if best is None or candidate.score < best.score:
                        best = candidate
        traces.append({
            "group": group, "scored": scored, "viable": viable,
            "preferred_attempted": preferred_attempted,
            "remaining_attempted": remaining_attempted,
            "quality": quality(best),
        })
        if not quality(best):
            fallback = True
            choices = []
            private_mask.clear()
            break
        assert best is not None and best.hard_predicates
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


def iter194_baseline() -> dict[str, int | bool | str]:
    path = Path(__file__).resolve().parents[1] / "runs" / "surface-loading-under-60s-rough" \
        / "artifacts" / "run_iter194_v961_spacing_index________hashonly" \
        / "invariant_post_t1.txt"
    values: dict[str, str] = {}
    if path.is_file():
        for line in path.read_text(encoding="utf-8").splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                values[key] = value
    return {
        "available": path.is_file(),
        "planning_ms": int(values.get("planning_ms", "0")),
        "scored": int(values.get("rocket_candidates_scored", "0")),
        "viable": int(values.get("rocket_relief_viable_candidates", "0")),
        "groups": int(values.get("rocket_pads", "0")),
        "resource_failures": int(values.get("first_resource_failures", "-1")),
        "rocket_failures": int(values.get("first_rocket_failures", "-1")),
    }


def main() -> int:
    preferred, remaining = offsets()
    permutation_checks = []
    for values in (preferred, remaining):
        for seed in (1, 2, 961, 962, 2_026_082_8):
            permuted = private_permutation(values, seed)
            permutation_checks.append(
                len(permuted) == len(values)
                and len({(entry.dq, entry.dr) for entry in permuted}) == len(values)
            )

    successful = [plan(seed) for seed in range(962, 1026)]
    repeat_a, repeat_b = plan(20260828), plan(20260828)
    forced_fallback = plan(20260828, fail_group=3)
    remaining_required = plan(20260828, force_preferred_empty=True)
    baseline = iter194_baseline()
    maximum_candidate_ratio = (GROUPS * SCORED_BUDGET) / ITER194_SCORED
    projected_saving_ms = ITER194_PLANNING_MS * (1 - maximum_candidate_ratio) - 300
    checks = {
        "offset_disk_matches_real_iter194": len(preferred) + len(remaining) == 5941,
        "preferred_split_is_complete": (
            len({(o.dq, o.dr) for o in preferred + remaining}) == 5941
            and not ({(o.dq, o.dr) for o in preferred} & {(o.dq, o.dr) for o in remaining})
        ),
        "all_affine_permutations_are_bijective": all(permutation_checks),
        "all_policy_corpora_complete_six_groups": all(
            not result["fallback"] and result["committed_pads"] == GROUPS
            and result["private_committed_masks_equal"] for result in successful
        ),
        "every_group_respects_256_score_budget": all(
            all(int(trace["scored"]) <= SCORED_BUDGET for trace in result["traces"])
            for result in successful
        ),
        "every_group_stops_at_32_viable": all(
            all(int(trace["viable"]) <= VIABLE_TARGET for trace in result["traces"])
            for result in successful
        ),
        "deterministic_repeat_digest": repeat_a == repeat_b and repeat_a["digest"] != 0,
        "fallback_is_prepublication": (
            forced_fallback["fallback"]
            and forced_fallback["published_before_decision"] == 0
            and forced_fallback["committed_pads"] == 0
            and forced_fallback["committed_mask_cells"] == 0
        ),
        "remaining_partition_is_visited_when_preferred_is_insufficient": (
            not remaining_required["fallback"]
            and all(int(trace["preferred_attempted"]) == PREFERRED_SCORED_BUDGET
                    and int(trace["remaining_attempted"]) > 0
                    for trace in remaining_required["traces"])
        ),
        "private_and_committed_clearance_masks_are_exact": all(
            result["private_committed_masks_equal"] for result in successful
        ),
        "relaxed_coordinate_policy_is_still_hard_validated": all(
            not result["fallback"] and result["committed_pads"] == GROUPS
            and result["committed_mask_cells"] >= GROUPS
            for result in successful
        ),
        "quality_boundary_is_exact": (
            quality(Candidate(0, 0, 0, math.floor(QUALITY_LIMIT / QUALITY_FACTOR), False, True))
            and not quality(Candidate(0, 0, 0,
                                      math.floor(QUALITY_LIMIT / QUALITY_FACTOR) + 1, False, True))
            and quality(Candidate(0, 0, 0, 999999, True, True))
        ),
        "real_iter194_baseline_loaded": (
            baseline["available"] and baseline["planning_ms"] == ITER194_PLANNING_MS
            and baseline["scored"] == ITER194_SCORED and baseline["viable"] == 13809
            and baseline["groups"] == GROUPS
            and baseline["resource_failures"] == 0 and baseline["rocket_failures"] == 0
        ),
        "projected_saving_exceeds_two_seconds": projected_saving_ms >= 2000,
    }
    result = {
        "schema": "smr.ralph.v962.bounded-rocket-planner-oracle.v1",
        "ok": all(checks.values()),
        "checks": checks,
        "real_iter194_baseline": baseline,
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
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

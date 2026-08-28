#!/usr/bin/env python3
"""Static, transaction, policy, and cost gate for the v963 rocket planner."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
TERRAIN_PATH = ROOT / "Code" / "sbm_terrain_copy.lua"
CONFIG_PATH = ROOT / "Code" / "sbm_config.lua"
DEPOSITS_PATH = ROOT / "Code" / "sbm_deposits.lua"
METADATA_PATH = ROOT / "metadata.lua"
ORACLE_PATH = ROOT / "_ralph" / "tools" \
    / "v963_fixed_budget_rocket_planner_oracle.py"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    terrain = TERRAIN_PATH.read_text(encoding="utf-8")
    config = CONFIG_PATH.read_text(encoding="utf-8")
    deposits = DEPOSITS_PATH.read_text(encoding="utf-8")
    metadata = METADATA_PATH.read_text(encoding="utf-8")
    start = terrain.index("local rocket_bounded = {")
    end = terrain.index("-- If a required new core actually intersects", start)
    planner = terrain[start:end]
    audit_start = terrain.index("local function AuditOuterResourceTerrain")
    audit_end = terrain.index("local function ZDumpHeightGrid", audit_start)
    policy_audit = terrain[audit_start:audit_end]

    oracle_process = subprocess.run(
        [sys.executable, str(ORACLE_PATH)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    oracle = json.loads(oracle_process.stdout) if oracle_process.returncode == 0 else {}

    commit_call = "commit_rocket_site(choice.context, choice.best)"
    bounded_publish_gate = "if rocket_bounded.used then\n\t\t-- Only now publish"
    fallback_marker = "-- Literal exhaustive fallback: retain the accepted disk order"
    checks = {
        "metadata_v963": "'version', 963," in metadata,
        "default_on_and_compiled_fixed_budget": all(token in config for token in (
            "config.OptimizeOuterResourceRocketBoundedPlanner = true",
            "C.OPTIMIZE_OUTER_RESOURCE_ROCKET_BOUNDED_PLANNER",
            "C.OUTER_RESOURCE_ROCKET_BOUNDED_SCORED_BUDGET_PER_GROUP = 256",
        )) and "OUTER_RESOURCE_ROCKET_BOUNDED_VIABLE_CANDIDATES" not in config,
        "private_seed_is_domain_separated": all(token in planner for token in (
            '"|v963-fixed-budget-rocket-pad-planner"',
            "generator.GenerationHash",
            "generator.Seed",
            "map.mapdata.RandomMapPreset",
            "rocket_bounded.private_seed",
        )),
        "planner_has_no_shared_rng": not any(token in planner for token in (
            "AsyncRand", "InteractionRand", "BraidRandom", "RandInt(",
            "table.shuffle", "Shuffle",
        )),
        "every_group_uses_full_fixed_budget": all(token in planner for token in (
            "rocket_bounded.scored_budget_per_group = 256",
            "rocket_bounded.preferred_scored_budget_per_group",
            "if scored >= rocket_bounded.scored_budget_per_group then return true end",
            "if scored < rocket_bounded.scored_budget_per_group then",
            "if scored == rocket_bounded.scored_budget_per_group then",
            "rocket_bounded.full_budget_groups = rocket_bounded.full_budget_groups + 1",
        )) and "viable >= rocket_bounded" not in planner,
        "best_is_minimum_unchanged_score_over_full_sample": all(token in planner for token in (
            "if not best or candidate.score < best.score then best = candidate end",
            "Score the full fixed budget",
            "retain the unchanged scorer's minimum",
        )),
        "disproven_height_quality_proxy_is_removed": all(token not in planner for token in (
            "quality_limit", "quality_factor", "quality_failures",
            "adaptive transition quality cap exceeded", "private_unsaturated_choices",
        )),
        "private_and_committed_masks_are_distinct": all(token in planner for token in (
            "local private_rocket_mask = {}",
            "context.cr + offset.dr, context.cq, context.cr, private_rocket_mask)",
            "mark_axial_forbidden(private_rocket_mask, best.q, best.r,",
            "mark_axial_forbidden(rocket_clearance_mask, best.q, best.r,",
        )) and all(token in terrain for token in (
            "rocket_bounded_private_mask_cells",
            "rocket_bounded_committed_mask_cells",
            "rocket_bounded_committed_mask_matches_private",
        )),
        "fallback_is_before_any_private_publish": (
            "bounded_choices = {}" in planner
            and "rocket_bounded.precommit_published_pads = #rocket_sites" in planner
            and "rocket_bounded.precommit_committed_mask_cells = rocket_clearance_mask_cells"
            in planner
            and "private planner observed pre-publication state mutation" in planner
            and planner.index("rocket_bounded.precommit_published_pads = #rocket_sites")
            < planner.index(bounded_publish_gate) < planner.index(commit_call)
            and planner.index(commit_call) < planner.index(fallback_marker)
        ),
        "no_candidate_is_the_only_sample_failure": (
            'if not best then' in planner
            and 'rocket_bounded.error = "bounded permutation found no viable candidate"' in planner
            and "break" in planner
        ),
        "all_groups_are_private_before_commit": all(token in planner for token in (
            "local expected_groups = math.min(#cluster_contexts, maximum_rocket_pads)",
            "rocket_bounded.groups_completed == expected_groups",
            "#bounded_choices == expected_groups",
            "-- Only now publish pad patches and mutate the committed clearance mask",
        )),
        "preferred_and_remaining_fixed_samples_are_both_visited": all(
            token in planner for token in (
                "local preferred_offsets, remaining_offsets = {}, {}",
                "distance >= preferred_minimum_distance",
                "and preferred_offsets or remaining_offsets",
                "math.floor(rocket_bounded.scored_budget_per_group * 0.75)",
                "visit_private_permutation(preferred_offsets, group_seed, visit_preferred)",
                "visit_private_permutation(remaining_offsets,",
            )
        ),
        "affine_walk_is_a_full_permutation": all(token in planner for token in (
            "greatest_common_divisor(step, count) ~= 1",
            "for ordinal = 0, count - 1 do",
            "(start + ordinal * step) % count + 1",
        )),
        "unchanged_hard_predicates_feed_private_and_fallback": all(
            token in planner for token in (
                "local function candidate_score(q, r, cq, cr, clearance_mask)",
                "resource_clearance(q, r)",
                "separated_from_rocket_pads(q, r, clearance_mask)",
                "not in_outer_band(x, y)",
                "inner_clearance <= rocket_required_core * hex_size",
                "x < edge_world or y < edge_world",
                "for _, offset in ipairs(rocket_offsets) do",
                "local ready = rocket_shape_ready(q, r)",
            )
        ),
        "literal_exhaustive_fallback_retained": all(token in planner for token in (
            fallback_marker,
            "for dq = -search_limit, search_limit do",
            "for dr = -search_limit, search_limit do",
            "local candidate = candidate_score(",
            "candidate.score < best.score",
            "if best then commit_rocket_site(context, best) end",
        )),
        "authoritative_terrain_quality_gates_are_retained": all(
            token in policy_audit for token in (
                "ready_offsets(site.q, site.r, rocket_offsets, true)",
                "rocket_failures = rocket_failures + 1",
                "cluster_shortfall",
                "cluster_excess",
                "resource_failures",
                "verified_modified_mountain_rocket_pads",
            )
        ),
        "telemetry_is_transactional_and_distinguishes_work": all(
            token in terrain for token in (
                "rocket_bounded_full_budget_groups",
                "rocket_bounded_offsets_attempted",
                "rocket_bounded_preferred_attempted",
                "rocket_bounded_remaining_attempted",
                "rocket_bounded_candidates_scored",
                "rocket_bounded_viable_candidates",
                "rocket_bounded_ready_candidates",
                "rocket_bounded_group_trace",
                "rocket_bounded_precommit_published_pads",
                "rocket_bounded_precommit_committed_mask_cells",
            )
        ),
        "deterministic_plan_digest_is_reported": all(
            token in planner + terrain for token in (
                "local digest = rocket_bounded.private_seed",
                "rocket_bounded.plan_digest = digest",
                "rocket_bounded_plan_digest",
                "rocket_bounded_private_rng_draws",
            )
        ),
        "resource_marker_planner_is_not_replaced": (
            "surface_streaming_clusters_used" in deposits
            and 'NewTopUpRepulsionTracker(map, "resource streaming plans")' in deposits
        ),
        "oracle_green": oracle_process.returncode == 0 and oracle.get("ok") is True,
        "oracle_proves_fixed_budget_minimum_and_transaction": all(
            oracle.get("checks", {}).get(name) is True for name in (
                "every_successful_group_scores_exactly_256",
                "every_group_scores_192_preferred_and_64_remaining",
                "selected_score_is_minimum_over_every_viable_sample",
                "high_range_valid_candidates_do_not_force_fallback",
                "fallback_on_empty_group_is_prepublication",
                "private_and_committed_clearance_masks_are_exact",
            )
        ),
        "oracle_classifies_iter195_rejected": (
            oracle.get("checks", {}).get("iter195_rejected_as_safe_quality_fallback") is True
        ),
        "oracle_projects_over_two_seconds": oracle.get("projected_saving_ms", 0) >= 2000,
    }
    result = {
        "schema": "smr.ralph.v963.fixed-budget-rocket-planner-check.v1",
        "ok": all(checks.values()),
        "checks": checks,
        "oracle": oracle,
        "oracle_stderr": oracle_process.stderr,
        "hashes": {
            str(path.relative_to(ROOT)): sha256(path)
            for path in (TERRAIN_PATH, CONFIG_PATH, METADATA_PATH, ORACLE_PATH)
        },
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

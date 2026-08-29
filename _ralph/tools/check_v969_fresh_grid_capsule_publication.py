#!/usr/bin/env python3
"""Static/executable gate for v969 fresh-grid-first lazy-UG capsules."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "Code" / "sbm_config.lua"
GENERATION = ROOT / "Code" / "sbm_map_generation.lua"
VERSION = ROOT / "Code" / "sbm_version.lua"
METADATA = ROOT / "metadata.lua"
ORACLE = ROOT / "_ralph" / "tools" / "v969_fresh_grid_capsule_publication_oracle.py"
DEPTH0_ORACLE = ROOT / "_ralph" / "tools" / "v968_exact_center_capsule_planner_oracle.py"
ENGINE_PROBE = ROOT / "_ralph" / "tools" / "v968_exact_center_engine_probe.lua"
LUA53 = (ROOT / "_ralph" / "tmp" / ".tmp_surface_loading_rough_iter109_lua53"
         / "lua-5.3.6" / "src" / "luac.exe")


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ordered(text: str, *tokens: str) -> bool:
    cursor = -1
    for token in tokens:
        cursor = text.find(token, cursor + 1)
        if cursor < 0:
            return False
    return True


def run_json(path: Path) -> tuple[subprocess.CompletedProcess[str], dict]:
    result = subprocess.run([sys.executable, str(path)], cwd=ROOT, capture_output=True,
                            text=True, timeout=30, check=False)
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        payload = {"ok": False, "error": result.stderr or result.stdout}
    return result, payload


def main() -> int:
    config = CONFIG.read_text(encoding="utf-8")
    generation = GENERATION.read_text(encoding="utf-8")
    version = VERSION.read_text(encoding="utf-8")
    metadata = METADATA.read_text(encoding="utf-8")
    if "'version', 970," in metadata or "'version', 971," in metadata:
        successor = ROOT / "_ralph" / "tools" / (
            "check_v971_outer_passage_pad_architecture.py"
            if "'version', 971," in metadata else "check_v970_capped_stock_capsule_search.py")
        forwarded = subprocess.run([sys.executable, str(successor)], cwd=ROOT,
                                   capture_output=True, text=True, timeout=30, check=False)
        try:
            payload = json.loads(forwarded.stdout)
        except json.JSONDecodeError:
            payload = {"ok": False, "error": forwarded.stderr or forwarded.stdout}
        ok = forwarded.returncode == 0 and payload.get("ok") is True
        print(json.dumps({
            "schema": "smr.ralph.v969.fresh-grid-forward-gate.v1",
            "ok": ok,
            "successor": "v971 outer passage-pad architecture"
                if "'version', 971," in metadata
                else "v970 capped post-canonical stock capsule search",
            "successor_result": payload,
        }, indent=2, sort_keys=True))
        return 0 if ok else 1
    planner_start = generation.index("function Lazy.BuildCapsulePlanMode")
    planner_end = generation.index("function Lazy.StateSurface", planner_start)
    planner = generation[planner_start:planner_end]
    flag_off_start = planner.index("elseif #concrete_markers > 0 or #geyser_markers > 0 then")
    flag_off_end = planner.index("\n\tend\n\n\tlocal private_seed", flag_off_start)
    flag_off = planner[flag_off_start:flag_off_end]
    literal_body_start = flag_off.index("\t\tdeposit_filter = function(q, r)")
    literal_body = flag_off[literal_body_start:]
    expected_literal_body = """\t\tdeposit_filter = function(q, r)
\t\t\tlocal wx, wy = hex_to_world(q, r)
\t\t\tlocal position = point_fn(wx, wy)
\t\t\tfor _, marker in ipairs(concrete_markers) do
\t\t\t\tif type(marker.GetObstructionRadius) == "function"
\t\t\t\t\tand position:Dist2D(marker) <= marker:GetObstructionRadius() then
\t\t\t\t\treturn false
\t\t\t\tend
\t\t\tend
\t\t\tfor _, marker in ipairs(geyser_markers) do
\t\t\t\tif type(marker.FeatureRadius) == "number"
\t\t\t\t\tand position:Dist2D(marker) <= marker.FeatureRadius then
\t\t\t\t\treturn false
\t\t\t\tend
\t\t\tend
\t\t\treturn true
\t\tend"""
    prepare_start = generation.index("function Lazy.PrepareImplementationCapsules(")
    prepare_end = generation.index("function Lazy.ValidatePublishedCapsules", prepare_start)
    prepare = generation[prepare_start:prepare_end]
    orchestration_start = prepare.index("function Lazy.PrepareImplementationCapsulesAroundRebuild")
    orchestration = prepare[orchestration_start:]
    fresh_start = orchestration.index("if fresh_grid_architecture then")
    fresh_end = orchestration.index("-- Literal v968 ordering", fresh_start)
    fresh = orchestration[fresh_start:fresh_end]
    oracle_run, oracle = run_json(ORACLE)
    depth0_run, depth0 = run_json(DEPTH0_ORACLE)

    compile_results: dict[str, bool] = {}
    for path in (CONFIG, GENERATION, VERSION, METADATA, ENGINE_PROBE):
        result = subprocess.run([str(LUA53), "-p", str(path)], cwd=ROOT,
                                capture_output=True, text=True, timeout=30, check=False)
        compile_results[path.relative_to(ROOT).as_posix()] = result.returncode == 0

    checks = {
        "metadata_v969_and_truthful": (
            "'version', 969," in metadata
            and "Publish fresh Surface grids before lazy-underground capsule planning" in metadata
            and "certify exact marker exclusions" in metadata
            and "close the two capsules with one canonical final rebuild" in metadata),
        "generator_patch_identity_retained_v275": "SuperBigMap.GENERATOR_PATCH_VERSION = 275" in version,
        "implementation_default_off_fresh_architecture_default_on": all(token in config for token in (
            "config.LazyUndergroundSourceGeneration = false",
            "config.LazyUndergroundBoundedCapsulePlanner = true",
            "config.LazyUndergroundFreshGridCapsulePlanning = true",
            "C.LAZY_UNDERGROUND_FRESH_GRID_CAPSULE_PLANNING")),
        "pinned_lua_5_3_6_compiles": all(compile_results.values()),
        "prior_depth_zero_oracle_remains_green": (
            depth0_run.returncode == 0 and depth0.get("ok") is True
            and depth0.get("limits", {}).get("max_depth") == 0
            and depth0.get("limits", {}).get("unbounded_calls") == 0),
        "v969_lifecycle_and_index_oracle_green": oracle_run.returncode == 0 and oracle.get("ok") is True,
        "oracle_covers_flag_off_and_unsafe_numeric_fallbacks": all(
            oracle.get("checks", {}).get(name) is True for name in (
                "flag_off_is_literal_v968_and_constructs_no_index",
                "nan_inf_and_huge_values_fallback_before_bucket_loops",
                "negative_or_pathological_radius_forces_literal_fallback")),
        "planner_version_and_flag_are_compiled": (
            "CAPSULE_PLANNER_VERSION = 4" in generation
            and '"LAZY_UNDERGROUND_FRESH_GRID_CAPSULE_PLANNING", true' in generation),
        "fresh_common_path_never_invokes_stale_plan": (
            "PrepareImplementationCapsulesSafe(surface, false)" not in fresh
            and "pre_final_attempts = 0" in fresh
            and "pre_final_bounded_search_calls = 0" in fresh
            and "stale_plan_skipped = true" in fresh),
        "fresh_common_path_order_is_canonical_plan_publish_close": ordered(
            fresh,
            'reason .. " before fresh-grid capsule planning"',
            "Lazy.PrepareImplementationCapsulesSafe(surface, true)",
            'reason .. " after fresh-grid capsule publication"'),
        "first_rebuild_failure_blocks_before_planner": ordered(
            fresh,
            "if first_ok ~= true then",
            '"first canonical Surface grid rebuild failed: "',
            "local plan_started = Lazy.Now()"),
        "fresh_plan_failure_blocks_before_closing_rebuild": ordered(
            fresh,
            "if capsule_ok ~= true then",
            '"lazy underground fresh-grid capsule publication failed: "',
            "local closing_rebuild_started = Lazy.Now()"),
        "closing_failure_is_sticky_and_two_rebuild_shape_is_certified": all(token in fresh for token in (
            "fresh_grid_closing_rebuild_complete",
            "rebuild_count == 2 and fallback_count == 0",
            '"closing canonical Surface grid rebuild failed: "',
            "Lazy.MarkBlocked(surface,")),
        "fresh_plan_is_not_mislabeled_as_stale_retry": (
            "report.capsule_plan_retry_used = after_canonical_grid" in prepare
            and "and report.fresh_grid_architecture_used ~= true" in prepare
            and "report.fresh_grid_plan_used = after_canonical_grid" in prepare),
        "phase_timing_is_complete": all(token in prepare for token in (
            "fresh_grid_first_rebuild_ms", "fresh_grid_main_plan_ms",
            "fresh_grid_replay_ms", "fresh_grid_publication_ms",
            "fresh_grid_plan_replay_publication_ms", "fresh_grid_closing_rebuild_ms",
            "fresh_grid_orchestration_total_ms")),
        "main_and_replay_invocation_counts_are_incremented_only_at_real_calls": ordered(
            prepare,
            "report.fresh_grid_main_plan_invocations =",
            "Lazy.BuildCapsulePlan(surface, pending, next_map)",
            "report.fresh_grid_replay_invocations =",
            "Lazy.ReplayCapsulePlan(surface, pending, next_map)"),
        "marker_index_is_conservative_and_literal_predicates_remain": all(token in planner for token in (
            "marker_index_bucket_size = 4096",
            "math.floor((marker_x - radius - 1) / bucket_size)",
            "math.floor((marker_x + radius + 1) / bucket_size)",
            "marker_entries > 4096",
            "marker_index_entries + marker_entries > 65536",
            "marker_index_fallback = not marker_index_ok",
            "local x_bucket = index[bx]",
            "local concrete_x = marker_index.concrete[bx]",
            "local geyser_x = marker_index.geyser[bx]",
            "position:Dist2D(marker) <= marker:GetObstructionRadius()",
            "position:Dist2D(marker) <= marker.FeatureRadius")),
        "marker_index_construction_and_query_are_v969_flag_gated": (
            ordered(planner,
                    "local deposit_filter",
                    "if Lazy.FRESH_GRID_CAPSULE_PLANNING == true then",
                    "local marker_index = { concrete = {}, geyser = {} }",
                    "elseif #concrete_markers > 0 or #geyser_markers > 0 then")
            and "local marker_index" not in flag_off
            and "first_rejecting_marker" not in flag_off
            and "marker_index_" not in flag_off),
        "flag_off_literal_v968_filter_body_is_byte_exact": literal_body == expected_literal_body,
        "flag_off_report_uses_literal_exactness_without_index_claim": (
            "marker_index_requested = Lazy.FRESH_GRID_CAPSULE_PLANNING == true" in planner
            and ordered(planner,
                        "if report.marker_index_requested == true then",
                        "else",
                        "report.marker_exclusion_exact = true")),
        "unsafe_numbers_are_rejected_before_floor_or_bucket_loops": (
            ordered(planner,
                    "local function finite_safe(value, limit)",
                    "if not finite_safe(radius, safe_world_number)",
                    "if not xy_ok or not finite_safe(marker_x, safe_world_number)",
                    "local min_bx = math.floor(",
                    "if not finite_safe(min_bx, safe_bucket_bound)",
                    "local span_x, span_y =",
                    '"marker index bounds are not safely incrementable"',
                    "for bx = min_bx, max_bx do")
            and all(token in planner for token in (
                "value == value", "value >= -limit and value <= limit",
                "span_x > 1 and min_bx + 1 == min_bx",
                "span_y > 1 and min_by + 1 == min_by",
                '"query position is unsafe"'))),
        "marker_index_preserves_concrete_before_geyser_order": ordered(
            planner, "for _, marker in ipairs(concrete_candidates) do",
            "for _, marker in ipairs(geyser_candidates) do"),
        "marker_index_has_truthful_usage_fallback_and_cost_telemetry": all(token in planner for token in (
            "marker_index_requested", "marker_index_used", "marker_index_fallback",
            "marker_index_fallback_reason", "marker_index_markers",
            "marker_index_bucket_entries", "marker_index_queries",
            "marker_index_candidate_checks", "marker_index_literal_checks",
            "marker_index_position_equivalence_checks",
            "marker_index_position_equivalence_mismatches",
            "marker_index_stream_comparisons", "marker_index_stream_mismatches",
            "marker_index_stream_complete", "marker_index_selection_equivalent",
            "marker_exclusion_exact",
            "marker_index_build_ms")),
        "marker_index_runtime_certificate_compares_every_visited_hex_and_falls_back": all(
            token in planner for token in (
                "marker_position.Dist2D", "center_distance ~= 0",
                "local indexed_rejection = first_rejecting_marker(",
                "local literal_rejection = first_rejecting_marker(",
                "if indexed_rejection ~= literal_rejection then",
                '"indexed/literal ordered marker stream mismatch"',
                "return literal_rejection == nil",
                "report.marker_index_stream_comparisons == report.marker_index_queries",
                "report.marker_index_selection_equivalent",
            )),
        "depth_zero_rules_replay_and_publication_checks_retained": all(token in prepare + planner for token in (
            "bounded_max_depth = 0", "report.private_draws = report.attempts * 3",
            "local max_attempts = 512", "publication_validation_calls == 2",
            "publication_validation_exact_centers == 2", "twin_report.replay_only == true",
            "twin_report.publication_validation_calls == 0", "plan_report.full_search_calls == 0")),
        "publication_contract_requires_exact_marker_exclusion_for_main_and_replay": (
            "and plan_report.marker_exclusion_exact == true" in prepare
            and "and twin_report.marker_exclusion_exact == true" in prepare),
        "literal_v968_path_exists_only_outside_fresh_common_branch": (
            "-- Literal v968 ordering remains available" in orchestration
            and "PrepareImplementationCapsulesSafe(surface, false)" in orchestration[fresh_end:]),
    }
    failed = sorted(name for name, ok in checks.items() if not ok)
    print(json.dumps({
        "schema": "smr.ralph.v969.fresh-grid-capsule-publication-check.v1",
        "ok": not failed,
        "failed": failed,
        "checks": checks,
        "compile": compile_results,
        "oracle": oracle,
        "depth_zero_oracle": depth0,
        "hashes": {path.relative_to(ROOT).as_posix(): sha(path) for path in (
            CONFIG, GENERATION, VERSION, METADATA, ORACLE, DEPTH0_ORACLE, ENGINE_PROBE)},
    }, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Static and executable fail-closed gate for v970 capped stock capsule search."""

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
ORACLE = ROOT / "_ralph" / "tools" / "v970_capped_stock_capsule_search_oracle.py"
V969_ORACLE = ROOT / "_ralph" / "tools" / "v969_fresh_grid_capsule_publication_oracle.py"
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
    planner_start = generation.index("function Lazy.BuildCapsulePlanMode")
    planner_end = generation.index("function Lazy.StateSurface", planner_start)
    planner = generation[planner_start:planner_end]
    stock_start = planner.index("if report.stock_search_requested == true then")
    stock_end = planner.index("elseif Lazy.BOUNDED_CAPSULE_PLANNER == true then", stock_start)
    stock = planner[stock_start:stock_end]
    prepare_start = generation.index("function Lazy.PrepareImplementationCapsules(")
    prepare_end = generation.index("function Lazy.ValidatePublishedCapsules", prepare_start)
    prepare = generation[prepare_start:prepare_end]
    orchestration_start = prepare.index("function Lazy.PrepareImplementationCapsulesAroundRebuild")
    fresh = prepare[orchestration_start:prepare.index("-- Literal v968 ordering", orchestration_start)]

    oracle_run, oracle = run_json(ORACLE)
    predecessor_run, predecessor = run_json(V969_ORACLE)
    compile_results: dict[str, bool] = {}
    for path in (CONFIG, GENERATION, VERSION, METADATA, ENGINE_PROBE):
        result = subprocess.run([str(LUA53), "-p", str(path)], cwd=ROOT,
                                capture_output=True, text=True, timeout=30, check=False)
        compile_results[path.relative_to(ROOT).as_posix()] = result.returncode == 0

    checks = {
        "metadata_v970_is_truthful": (
            "'version', 970," in metadata and "at most eight deterministic stock" in metadata
            and "replay exactly" in metadata and "one final rebuild" in metadata),
        "generator_patch_identity_bumped": "SuperBigMap.GENERATOR_PATCH_VERSION = 276" in version,
        "implementation_off_new_subflag_on_and_compiled": all(token in config for token in (
            "config.LazyUndergroundSourceGeneration = false",
            "config.LazyUndergroundFreshGridCapsulePlanning = true",
            "config.LazyUndergroundPostCanonicalStockCapsuleSearch = true",
            "C.LAZY_UNDERGROUND_POST_CANONICAL_STOCK_CAPSULE_SEARCH")),
        "pinned_lua_5_3_6_compiles": all(compile_results.values()),
        "v970_state_and_budget_oracle_green": oracle_run.returncode == 0 and oracle.get("ok") is True,
        "v969_two_rebuild_lifecycle_oracle_stays_green": (
            predecessor_run.returncode == 0 and predecessor.get("ok") is True),
        "planner_version_and_compiled_flag_are_v970": (
            "CAPSULE_PLANNER_VERSION = 5" in generation
            and '"LAZY_UNDERGROUND_POST_CANONICAL_STOCK_CAPSULE_SEARCH", true' in generation),
        "stock_search_is_strictly_capped_at_eight": all(token in stock for token in (
            "local stock_search_cap = 8", "report.full_search_cap = stock_search_cap",
            "report.attempts < stock_search_cap", "report.full_search_calls =",
            "report.stock_search_start_attempts = report.attempts")),
        "each_start_consumes_three_private_draws_before_one_stock_call": ordered(
            stock, "local candidate_x =", "local candidate_y =", "local angle =",
            "local center = snap_world", "report.full_search_calls =",
            "pcall(find_buildable, object_grid, buildable,"),
        "unchanged_stock_shape_and_literal_deposit_filter_are_supplied": (
            "center, angle, shape, deposit_filter" in stock
            and "local shape = get_shape(\"Elevator\")" in planner
            and "position:Dist2D(marker) <= marker:GetObstructionRadius()" in planner
            and "position:Dist2D(marker) <= marker.FeatureRadius" in planner),
        "hard_margin_spacing_and_world_hex_rules_remain": all(token in stock for token in (
            "x >= margin_x and x <= world_width - margin_x",
            "y >= margin_y and y <= world_height - margin_y",
            "dx * dx + dy * dy < minimum_distance2",
            "pcall(world_to_hex, point_fn(x, y))")),
        "stock_raise_cap_miss_malformed_and_worldhex_fail_before_publication": all(
            token in stock for token in (
                'error("stock-call-raised: "', 'error("stock-call-returned-malformed-position")',
                'error("stock-call-returned-world-hex-mismatch")',
                'return fail("capped stock capsule search did not find exactly two valid inner sites")')),
        "successful_stock_z_is_finite_required_and_never_normalized": (
            'and type(z) == "number" and z == z' in stock
            and 'and z > -2147483648 and z < 2147483648' in stock
            and "trace.result_z = z" in stock and "x = x, y = y, z = z," in stock
            and "z == nil or type(z)" not in stock
            and 'type(z) == "number" and z or 0' not in stock),
        "oracle_rejects_nil_vs_zero_z_and_preserves_finite_z": all(
            oracle.get("checks", {}).get(name) is True for name in (
                "nil_z_main_vs_zero_z_replay_is_rejected",
                "finite_z_is_preserved_and_replayed_exactly")),
        "v970_common_path_bypasses_marker_index": (
            "marker_index_requested = Lazy.FRESH_GRID_CAPSULE_PLANNING == true" in planner
            and "and Lazy.POST_CANONICAL_STOCK_CAPSULE_SEARCH ~= true" in planner
            and "if report.marker_index_requested == true then" in planner
            and "marker_index" not in stock),
        "stock_path_uses_literal_marker_order_without_shared_rng": (
            "elseif #concrete_markers > 0 or #geyser_markers > 0 then" in planner
            and "AsyncRand" not in stock and "InteractionRand" not in stock),
        "stock_path_is_refused_before_canonical_grid": ordered(
            prepare, "local stock_search_active =", "if stock_search_active and not after_canonical_grid then",
            '"v970 stock capsule search was invoked before canonical Surface grids"',
            "Lazy.BuildCapsulePlan(surface, pending, next_map)"),
        "fresh_orchestration_has_zero_prefinal_calls_and_exact_order": (
            "pre_final_attempts = 0" in fresh and "pre_final_bounded_search_calls = 0" in fresh
            and "PrepareImplementationCapsulesSafe(surface, false)" not in fresh
            and ordered(fresh, 'reason .. " before fresh-grid capsule planning"',
                        "Lazy.PrepareImplementationCapsulesSafe(surface, true)",
                        'reason .. " after fresh-grid capsule publication"')),
        "main_and_replay_require_same_cap_calls_trace_state_sites_and_digest": all(
            token in generation for token in (
            "plan_report.full_search_cap == 8", "plan_report.full_search_calls == plan_report.attempts",
            "twin_report.full_search_cap == 8", "twin_report.full_search_calls == twin_report.attempts",
            "plan_report.plan_digest == twin_report.plan_digest", "capsule.x ~= twin.x",
            "capsule.y ~= twin.y", "capsule.z ~= twin.z", "capsule.angle ~= twin.angle",
            "plan_report.private_final_state == twin_report.private_final_state",
            "plan_report.stock_search_trace", "twin_report.stock_search_trace",
            "trace[field] ~= twin_trace[field]",
            "report.stock_search_replay_exact = stock_search_active and repeat_exact == true")),
        "main_gets_two_depth_zero_publication_validations_replay_gets_none": (
            "hex_find_buildable(capsule.q, capsule.r," in stock
            and "unbuildable_z, continue_check, 0" in stock
            and "report.publication_validation_calls = report.publication_validation_calls + 1" in stock
            and "plan_report.publication_validation_calls == 2" in prepare
            and "plan_report.publication_validation_exact_centers == 2" in prepare
            and "twin_report.publication_validation_calls == 0" in prepare),
        "infinite_loop_pause_resume_is_required_and_balanced_around_each_pass": ordered(
            stock, "report.stock_search_pause_requested = true",
            'pcall(pause_ild, "SBMV970CappedStockCapsuleSearch")',
            "local search_ok, search_error = pcall(function()",
            "local resume_ok, resume_error = pcall(",
            'resume_ild, "SBMV970CappedStockCapsuleSearch")',
            "if not resume_ok then return fail(", "if not search_ok then return fail("),
        "validation_requires_literal_exclusion_and_no_index_for_both_runs": all(token in prepare for token in (
            "plan_report.marker_index_requested == false", "plan_report.marker_index_used == false",
            "plan_report.marker_exclusion_exact == true", "twin_report.marker_index_requested == false",
            "twin_report.marker_index_used == false", "twin_report.marker_exclusion_exact == true")),
        "truthful_call_timing_and_replay_telemetry_present": all(token in planner + prepare for token in (
            "stock_search_requested", "stock_search_used", "stock_search_start_attempts",
            "stock_search_selected", "stock_search_after_canonical_grid", "full_search_calls",
            "full_search_ms", "unbounded_search_calls", "repeat_full_search_calls",
            "repeat_full_search_ms", "repeat_full_search_cap", "stock_search_replay_exact",
            "stock_search_trace", "stock_search_trace_exact", "publication_validation_ms",
            "stock_search_pause_used", "stock_search_resume_ok")),
        "publication_rollback_baselines_and_verifies_zero_new_passages_markers_signs": all(
            token in generation for token in (
                "local baseline = { UndergroundPassage = {}, UndergroundTunnelMarker = {},",
                "SurfaceUndergroundTunnelSign = {}", "if not baseline[class_name][object]",
                "new_objects.SurfaceUndergroundTunnelSign",
                "new_objects.UndergroundTunnelMarker", "new_objects.UndergroundPassage",
                "local valid_ok, valid = pcall(is_valid, object)",
                "if not original[object] then count = count + 1 end",
                "capsule object rollback could not prove zero passages/markers/signs")),
        "failure_after_suppression_is_sticky_and_no_fallback_publication": (
            'return Lazy.MarkBlocked(surface,\n\t\t\t"capsule plan failed: "' in prepare
            and "fallback-eager" not in stock),
    }
    failed = sorted(name for name, ok in checks.items() if not ok)
    print(json.dumps({
        "schema": "smr.ralph.v970.capped-stock-capsule-search-check.v1",
        "ok": not failed,
        "failed": failed,
        "checks": checks,
        "compile": compile_results,
        "oracle": oracle,
        "v969_oracle": predecessor,
        "hashes": {path.relative_to(ROOT).as_posix(): sha(path) for path in (
            CONFIG, GENERATION, VERSION, METADATA, ORACLE, V969_ORACLE, ENGINE_PROBE)},
    }, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Static/executable fail-closed gate for v971 outer passage-pad architecture."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "Code" / "sbm_config.lua"
GENERATION = ROOT / "Code" / "sbm_map_generation.lua"
TERRAIN = ROOT / "Code" / "sbm_terrain_copy.lua"
DEPOSITS = ROOT / "Code" / "sbm_deposits.lua"
VERSION = ROOT / "Code" / "sbm_version.lua"
METADATA = ROOT / "metadata.lua"
ORACLE = ROOT / "_ralph" / "tools" / "v971_outer_passage_pad_oracle.py"
V970_ORACLE = ROOT / "_ralph" / "tools" / "v970_capped_stock_capsule_search_oracle.py"
ENGINE_PROBE = ROOT / "_ralph" / "tools" / "v971_outer_passage_pad_engine_probe.lua"
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
    terrain = TERRAIN.read_text(encoding="utf-8")
    deposits = DEPOSITS.read_text(encoding="utf-8")
    version = VERSION.read_text(encoding="utf-8")
    metadata = METADATA.read_text(encoding="utf-8")
    engine_probe = ENGINE_PROBE.read_text(encoding="utf-8")
    oracle_run, oracle = run_json(ORACLE)
    predecessor_run, predecessor = run_json(V970_ORACLE)
    compile_results = {}
    for path in (CONFIG, GENERATION, TERRAIN, DEPOSITS, VERSION, METADATA, ENGINE_PROBE):
        result = subprocess.run([str(LUA53), "-p", str(path)], cwd=ROOT,
                                capture_output=True, text=True, timeout=30, check=False)
        compile_results[path.relative_to(ROOT).as_posix()] = result.returncode == 0

    plan_start = terrain.index("-- v972 lazy-underground pad reservation")
    plan_end = terrain.index("-- If a required new core", plan_start)
    plan = terrain[plan_start:plan_end]
    capsule_start = generation.index("if report.outer_passage_pad_requested == true then")
    capsule_end = generation.index("elseif report.stock_search_requested == true then", capsule_start)
    capsule = generation[capsule_start:capsule_end]
    pipeline_start = generation.index("-- v972 lazy-underground implementation only")
    pipeline_end = generation.index("if type(deposits.ClearTopUpPlacementPool)", pipeline_start)
    pipeline = generation[pipeline_start:pipeline_end]
    checks = {
        "metadata_v971_architecture_retained_forward": "'version', 981," in metadata
            and "exact owned 100 lazy readiness-wait phase" in metadata
            and "111 canonical rebuild phases" in metadata,
        "generator_identity_v287": "SuperBigMap.GENERATOR_PATCH_VERSION = 287" in version,
        "implementation_default_off_subflag_default_on_compiled": all(token in config for token in (
            "config.LazyUndergroundSourceGeneration = false",
            "config.LazyUndergroundOuterPassagePads = true",
            "C.LAZY_UNDERGROUND_OUTER_PASSAGE_PADS")),
        "pinned_lua53_compiles_all_touched_production": all(compile_results.values()),
        "v971_oracle_green": oracle_run.returncode == 0 and oracle.get("ok") is True,
        "setter_return_error_fault_regressions_green": all(
            oracle.get("checks", {}).get(name) is True for name in (
                "mutate_then_throw_restore_is_verified_before_block",
                "mutate_then_return_error_enters_verified_rollback",
                "restore_returned_error_is_not_completed_or_verified",
                "restore_throw_is_not_completed_or_verified",
                "numeric_zero_return_is_a_lua_truthy_error")),
        "v970_fault_oracle_retained": predecessor_run.returncode == 0
            and predecessor.get("ok") is True,
        "detached_engine_probe_is_flat_read_only_and_fail_closed": (
            "assert(" not in engine_probe and "error(" not in engine_probe
            and "rawset(" not in engine_probe and "AsyncStringToFile" not in engine_probe
            and "StringToFile" not in engine_probe and "io.open" not in engine_probe
            and 'schema = "smr.ralph.v971.outer-passage-pad-engine-probe.v1"'
                in engine_probe
            and "return {" in engine_probe
            and all(token in engine_probe for token in (
                "passage_pad_conservative_visit_radius_world",
                "HexGridFindBuildable", "continue_check, 0)",
                "depth0_calls == 2", "depth0_accepts == 2",
                "enrichment_spacing_failures", "rocket_spacing_failures",
                "unbounded_search_calls = 0"))),
        "late_pipeline_order_after_all_enrichments_before_canonical": ordered(
            generation,
            'TimedSafeCall("surface top-up effect deposits"',
            'deposits.AuditTopUpVanillaRepulsion(map, "surface final after density suite")',
            "deposits.CensusFinalOuterResourceTopUps(map,",
            '"surface final before placement-pool cleanup"',
            "-- v972 lazy-underground implementation only",
            "TerrainCopy.PrepareOuterPassageTerrain, map",
            "deposits.ClearTopUpPlacementPool(map)"),
        "resource_path_has_no_default_off_passage_table_allocation": (
            "passage_plan = passage_only and {" in terrain
            and "for _, entry in ipairs(passage_only and {} or resources)" in terrain
            and "local maximum_rocket_pads = passage_only and 0 or math.max" in terrain),
        "private_bounded_two_site_plan_and_replay": all(token in plan for token in (
            '"|v972-direct-outer-passage-pad-reservation"', "attempt_cap_per_site = 32",
            "viable_target_per_site = 4", "local side = side_draw % 4",
            "for site_index = 1, passage_plan.required do",
            "local selected, final_state, attempts, viable = select_private_sites(false)",
            "local replay, replay_state, replay_attempts, replay_viable = select_private_sites(true)",
            "passage_plan.private_draws = attempts * 3", "passage_plan.replay_exact =")),
        "no_shared_rng_and_no_buildable_search_in_terrain_plan": all(token not in plan for token in (
            "AsyncRand", "InteractionRand", "FindBuildableAreaAround", "HexGridFindBuildable")),
        "physical_ring_map_inner_and_full_visit_guards": all(token in plan for token in (
            "if ring_sectors ~= 2 then", "in_outer_band(x, y)", "x >= conservative_visit_world",
            "inner_distance > conservative_visit_world",
            "passage_plan.inner_no_write = passage_plan.used == true"))
            and all(token in terrain for token in (
                "passage_pad_inner_no_write", "passage_pad_all_changed_cells_outer")),
        "all_live_enrichments_six_rockets_and_existing_patches_excluded": all(
            token in plan for token in (
                'map.MapForEach, map, "map", "DepositMarker"', "#existing_rockets ~= 6",
                "passage_required_core + 3", "passage_required_core + rocket_radius + 4",
                "existing_resource_sites", "conservative_visit_world + radius_cells * height_tile")),
        "exact_obstructions_and_conservative_marker_clearance": all(
            token in plan for token in (
                'pcall(get_shape, "Elevator")', "validate_shape(passage_shape",
                "GetBuildObstructions", 'marker.resource == "Concrete"',
                '"PrefabFeatureMarker"', '"PrefabFeatureCharPreset_Geyser"',
                "passage_world_radius * hex_size + entry.radius")),
        "native_organic_patch_journal_has_passage_order_and_site_telemetry": all(
            token in terrain for token in (
                'add_patch("passage"', "passage_site = site",
                "passage = 4", "patch.passage_site", "native_raster_used",
                "native_inner_restored_patch_cells")),
        "passage_only_transaction_does_not_replace_resource_tables": ordered(
            terrain, "if passage_only then",
            "map.SuperBigMapOuterPassagePads = set_ok and passage_sites or nil",
            "else", "map.SuperBigMapOuterResourceTerrainSites = resource_sites",
            "map.SuperBigMapOuterResourceRocketPads = rocket_sites"),
        "mutate_then_throw_install_rolls_back_and_verifies_immutable_preimage": all(
            token in terrain for token in (
                "immutable passage height preimage unavailable",
                "if set_ok and set_error then set_ok = false end",
                "passage_plan.transaction.rollback_attempted = true",
                "terrain_api.SetHeightGrid, map, payload",
                "if restore_ok and restore_error then restore_ok = false end",
                "passage_plan.transaction.verify()",
                "native_count(difference, 0, 2147483647)",
                "passage_install_rollback_verified")),
        "native_failure_never_enters_literal_passage_fallback_or_installs": all(
            token in terrain for token in (
                "The dedicated passage transaction has no literal fallback after planning",
                "ok_apply, apply_error = false, native_raster_error",
                'and native_raster_error or "native grid APIs unavailable"')),
        "main_uses_only_two_depth0_checks_replay_uses_zero": all(token in capsule for token in (
            "hex_find_buildable(capsule.q, capsule.r,",
            "unbuildable_z, continue_check, 0",
            "if not replay_only then", "report.publication_validation_calls =",
            "report.publication_validation_calls == 2"))
            and all(token not in capsule for token in (
                "FindBuildableAreaAround", "full_search_calls = report.full_search_calls + 1")),
        "capsule_gate_requires_exact_native_report_and_no_inner_write": all(
            token in capsule for token in (
                "terrain_report.passage_pad_replay_exact ~= true",
                "terrain_report.passage_pad_inner_no_write ~= true",
                "terrain_report.passage_pad_all_changed_cells_outer ~= true",
                "terrain_report.native_raster_used ~= true",
                "terrain_report.native_raster_fallback == true")),
        "publication_is_after_first_canonical_and_before_closing_rebuild": ordered(
            generation, 'reason .. " before fresh-grid capsule planning"',
            "Lazy.PrepareImplementationCapsulesSafe(surface, true)",
            'reason .. " after fresh-grid capsule publication"'),
        "hard_spacing_and_census_include_passage_pads": all(token in deposits for token in (
            "outer_passage_pad_pairs_checked", "outer_passage_pad_failures",
            "first_outer_passage_pad_failure", "outer_passage_pad_ring_failures",
            "outer_passage_pad_primitive_failures", "stats.outer_passage_pads == 2")),
        "late_pipeline_fails_closed_on_plan_spacing_and_census": all(token in pipeline for token in (
            'error("outer passage terrain reservation failed:',
            'error("outer passage-pad hard spacing audit failed:',
            'error("outer passage-pad census failed")')),
        "literal_stock_branch_retained_but_excluded_from_v971_common_path": (
            "elseif report.stock_search_requested == true then" in generation
            and "and Lazy.OUTER_PASSAGE_PADS ~= true" in generation
            and "local stock_search_cap = 8" in generation),
        "sticky_no_partial_capsule_rollback_retained": all(token in generation for token in (
            "capsule object rollback could not prove zero passages/markers/signs",
            'return Lazy.MarkBlocked(surface, "capsule plan did not repeat exactly")',
            "descriptor.failure_sticky = true")),
    }
    failed = sorted(name for name, ok in checks.items() if not ok)
    print(json.dumps({
        "schema": "smr.ralph.v971.outer-passage-pad-architecture-check.v1",
        "ok": not failed,
        "failed": failed,
        "checks": checks,
        "compile": compile_results,
        "oracle": oracle,
        "v970_oracle": predecessor,
        "hashes": {path.relative_to(ROOT).as_posix(): sha(path) for path in (
            CONFIG, GENERATION, TERRAIN, DEPOSITS, VERSION, METADATA, ORACLE, ENGINE_PROBE)},
    }, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())

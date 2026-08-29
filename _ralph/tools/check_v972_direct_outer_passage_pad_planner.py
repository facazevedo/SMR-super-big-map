#!/usr/bin/env python3
"""Fail-closed static/executable gate for v972 direct-ring passage planning."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "Code" / "sbm_config.lua"
TERRAIN = ROOT / "Code" / "sbm_terrain_copy.lua"
GENERATION = ROOT / "Code" / "sbm_map_generation.lua"
DEPOSITS = ROOT / "Code" / "sbm_deposits.lua"
VERSION = ROOT / "Code" / "sbm_version.lua"
METADATA = ROOT / "metadata.lua"
ORACLE = ROOT / "_ralph" / "tools" / "v972_direct_outer_passage_pad_oracle.py"
ENGINE_PROBE = ROOT / "_ralph" / "tools" / "v972_direct_outer_passage_pad_engine_probe.lua"
FALSE_GLOBAL_ORACLE = (ROOT / "_ralph" / "tools"
                       / "lazy_engine_global_false_transaction_oracle.lua")
LUA53 = (ROOT / "_ralph" / "tmp" / ".tmp_surface_loading_rough_iter109_lua53"
         / "lua-5.3.6" / "src" / "luac.exe")
LUA53_RUN = LUA53.with_name("lua.exe")


def ordered(text: str, *tokens: str) -> bool:
    cursor = -1
    for token in tokens:
        cursor = text.find(token, cursor + 1)
        if cursor < 0:
            return False
    return True


def main() -> int:
    config = CONFIG.read_text(encoding="utf-8")
    terrain = TERRAIN.read_text(encoding="utf-8")
    generation = GENERATION.read_text(encoding="utf-8")
    deposits = DEPOSITS.read_text(encoding="utf-8")
    version = VERSION.read_text(encoding="utf-8")
    metadata = METADATA.read_text(encoding="utf-8")
    start = terrain.index("-- v972 lazy-underground pad reservation")
    end = terrain.index("-- If a required new core", start)
    plan = terrain[start:end]
    oracle_run = subprocess.run([sys.executable, str(ORACLE)], cwd=ROOT,
                                capture_output=True, text=True, timeout=30, check=False)
    false_global_run = subprocess.run([str(LUA53_RUN), str(FALSE_GLOBAL_ORACLE)], cwd=ROOT,
                                      capture_output=True, text=True, timeout=30, check=False)
    try:
        oracle = json.loads(oracle_run.stdout)
    except json.JSONDecodeError:
        oracle = {"ok": False, "error": oracle_run.stderr or oracle_run.stdout}
    compile_results = {}
    engine_probe = ENGINE_PROBE.read_text(encoding="utf-8")
    for path in (CONFIG, TERRAIN, GENERATION, DEPOSITS, VERSION, METADATA, ENGINE_PROBE,
                 FALSE_GLOBAL_ORACLE):
        result = subprocess.run([str(LUA53), "-p", str(path)], cwd=ROOT,
                                capture_output=True, text=True, timeout=30, check=False)
        compile_results[path.relative_to(ROOT).as_posix()] = result.returncode == 0
    checks = {
        "metadata_v973_truthfully_retains_v972": "'version', 973," in metadata
            and "literal false engine-global values" in metadata
            and "bounded direct-pad plan and replay" in metadata,
        "generator_identity_v279": "SuperBigMap.GENERATOR_PATCH_VERSION = 279" in version,
        "lazy_architecture_default_off_direct_pad_subflag_on": all(token in config for token in (
            "config.LazyUndergroundSourceGeneration = false",
            "config.LazyUndergroundOuterPassagePads = true")),
        "pinned_lua53_compiles_production": all(compile_results.values()),
        "v972_oracle_green": oracle_run.returncode == 0 and oracle.get("ok") is True,
        "literal_false_engine_global_transaction_round_trips": (
            false_global_run.returncode == 0 and false_global_run.stdout.strip() == "ok=true"
            and "return read_ok and value or nil" not in generation[
                generation.index("local function add_environment_bridge"):
                generation.index("local function parent_environment")]
            and "if read_ok then return value end" in generation[
                generation.index("local function add_environment_bridge"):
                generation.index("local function parent_environment")]),
        "flat_read_only_engine_probe_gates_v972_budget_and_exact_geometry": all(
            token in engine_probe for token in (
                'schema = "smr.ralph.v972.direct-outer-passage-pad-engine-probe.v1"',
                "passage_pad_direct_outer_sampling ~= true",
                "passage_pad_attempt_cap_per_site) ~= 32",
                "passage_pad_viable_target_per_site) ~= 4",
                "passage_pad_plan_ms) or 2001) > 2000",
                "depth0_calls == 2", "depth0_accepts == 2",
                "enrichment_spacing_failures", "rocket_spacing_failures"))
            and all(token not in engine_probe for token in (
                "rawset(", "AsyncStringToFile", "StringToFile", "io.open", "assert(", "error(")),
        "direct_four_strip_sampling_not_whole_map": all(token in plan for token in (
            "attempt_cap_per_site = 32", "viable_target_per_site = 4",
            "local side = side_draw % 4", "local depth = safe_edge +",
            "sample_x = map_w - 1 - depth", "sample_y = map_h - 1 - depth"))
            and "next_private() % math.max(1, math.floor(map_w))" not in plan,
        "still_rechecks_physical_ring_and_complete_visit_guard": all(token in plan for token in (
            "in_outer_band(x, y)", "x >= conservative_visit_world",
            "inner_distance > conservative_visit_world")),
        "bounded_four_viable_quality_sample_per_site": all(token in plan for token in (
            "local best, site_viable = nil, 0", "site_viable = site_viable + 1",
            "site_viable >= passage_plan.viable_target_per_site", "candidate.height_range")),
        "marker_filter_is_candidate_level_conservative": all(token in plan for token in (
            "for _, entry in ipairs(concrete_markers) do",
            "for _, entry in ipairs(geyser_markers) do",
            "passage_world_radius * hex_size + entry.radius",
            "dx * dx + dy * dy <= clearance * clearance"))
            and "position.Dist2D" not in plan,
        "exact_shape_walk_only_queries_obstructions": all(token in plan for token in (
            "validate_shape(passage_shape", "pcall(get_obstructions, object_grid, hq, hr)",
            'return ok and type(obstructions) == "table" and #obstructions == 0')),
        "all_resource_rocket_patch_and_pair_rules_retained": all(token in plan for token in (
            "passage_required_core + 3", "passage_required_core + rocket_radius + 4",
            "existing_resource_sites", "minimum_distance2")),
        "private_rng_and_full_replay_retained": all(token in plan for token in (
            '"|v972-direct-outer-passage-pad-reservation"',
            "local selected, final_state, attempts, viable = select_private_sites(false)",
            "local replay, replay_state, replay_attempts, replay_viable = select_private_sites(true)",
            "passage_plan.private_draws = attempts * 3", "passage_plan.replay_exact ="))
            and all(token not in plan for token in ("AsyncRand", "InteractionRand")),
        "runtime_telemetry_exposes_new_bound": all(token in terrain for token in (
            "passage_pad_viable_target_per_site", "passage_pad_direct_outer_sampling",
            "passage_pad_plan_ms")),
        "both_publication_gates_enforce_runtime_budget_and_exact_replay": (
            generation.count("passage_pad_attempt_cap_per_site) ~= 32") == 2
            and generation.count("passage_pad_viable_target_per_site) ~= 4") == 2
            and generation.count("passage_pad_attempts) or 65) > 64") == 2
            and generation.count("passage_pad_replay_viable) ~= 8") == 2
            and generation.count("passage_pad_plan_ms) or 2001) > 2000") == 2),
        "capsule_gate_matches_bounded_direct_pad_journal": all(
            token in generation for token in (
                "candidate.outer_passage_pad_direct_sampling == true",
                "candidate.outer_passage_pad_attempt_cap_per_site == 32",
                "candidate.outer_passage_pad_viable_target_per_site == 4",
                "candidate.attempts >= 8 and candidate.attempts <= 64",
                "candidate.outer_passage_pad_viable == 8",
                "candidate.outer_passage_pad_replay_attempts == candidate.attempts",
                "candidate.outer_passage_pad_replay_viable == 8",
                "candidate.outer_passage_pad_replay_exact == true",
                "candidate.outer_passage_pad_shape_checks >= 8",
                "candidate.outer_passage_pad_shape_checks <= candidate.attempts",
                "candidate.outer_passage_pad_plan_ms <= 2000",
                "candidate.outer_passage_pad_private_draws == candidate.attempts * 3",
                "outer_plan_contract(plan_report, 2)", "outer_plan_contract(twin_report, 0)",
                "candidate.bounded_max_depth == 0",
                "candidate.publication_validation_calls == publication_calls",
                "candidate.full_search_calls == 0", "candidate.full_search_mismatches == 0"))
            and "plan_report.attempts == 512" not in generation,
        "planner_telemetry_carries_direct_pad_contract": all(
            token in generation for token in (
                "outer_passage_pad_direct_sampling = false",
                "outer_passage_pad_attempt_cap_per_site = 0",
                "outer_passage_pad_viable_target_per_site = 0",
                "outer_passage_pad_attempts = 0",
                "outer_passage_pad_viable = 0",
                "outer_passage_pad_replay_attempts = 0",
                "outer_passage_pad_replay_viable = 0",
                "outer_passage_pad_replay_exact = false",
                "outer_passage_pad_shape_checks = 0",
                "outer_passage_pad_plan_ms = 0",
                "outer_passage_pad_private_draws = 0")),
        "two_exact_depth_zero_publication_validations_retained": all(
            token in generation for token in (
                "report.publication_validation_calls == 2",
                "unbuildable_z, continue_check, 0")),
        "late_after_enrichment_before_canonical_order_retained": ordered(
            generation, 'TimedSafeCall("surface top-up effect deposits"',
            "-- v972 lazy-underground implementation only",
            "TerrainCopy.PrepareOuterPassageTerrain, map",
            "deposits.ClearTopUpPlacementPool(map)"),
        "hard_spacing_and_census_still_fail_closed": all(token in deposits for token in (
            "outer_passage_pad_failures", "outer_passage_pad_ring_failures",
            "outer_passage_pad_primitive_failures")),
    }
    failed = sorted(name for name, ok in checks.items() if not ok)
    print(json.dumps({
        "schema": "smr.ralph.v972.direct-outer-passage-pad-check.v1",
        "ok": not failed,
        "failed": failed,
        "checks": checks,
        "compile": compile_results,
        "oracle": oracle,
    }, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())

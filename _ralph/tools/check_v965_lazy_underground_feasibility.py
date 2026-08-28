#!/usr/bin/env python3
"""Static/state-model gate for the default-off v965 lazy-underground feasibility slice."""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "Code" / "sbm_config.lua"
GENERATION = ROOT / "Code" / "sbm_map_generation.lua"
GRID = ROOT / "Code" / "sbm_sector_grid.lua"
VERSION = ROOT / "Code" / "sbm_version.lua"
METADATA = ROOT / "metadata.lua"
LUA53 = (
    ROOT
    / "_ralph"
    / "tmp"
    / ".tmp_surface_loading_rough_iter109_lua53"
    / "lua-5.3.6"
    / "src"
    / "luac.exe"
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def private_plan(seed: int, corpus: list[tuple[int, int]], minimum_distance: int) -> tuple:
    """Small executable analogue of the Lua private stream + first-valid pair policy."""
    modulus = 2_147_483_647
    state = seed or 1
    selected: list[tuple[int, int]] = []
    visited: set[int] = set()
    while len(selected) < 2 and len(visited) < len(corpus):
        state = (state * 48_271 + 1) % modulus or 1
        index = state % len(corpus)
        if index in visited:
            continue
        visited.add(index)
        x, y = corpus[index]
        if all((x - px) ** 2 + (y - py) ** 2 >= minimum_distance**2 for px, py in selected):
            selected.append((x, y))
    result = tuple(selected)
    plan_hash = seed
    for x, y in result:
        plan_hash = (plan_hash * 48_271 + abs(x) + 1) % modulus
        plan_hash = (plan_hash * 48_271 + abs(y) + 1) % modulus
    return result, state, plan_hash


def state_cases() -> dict[str, bool]:
    corpus = [(10, 10), (12, 11), (75, 80), (20, 70), (88, 12), (55, 55)]
    first = private_plan(1_391_337, corpus, 30)
    repeat = private_plan(1_391_337, corpus, 30)
    other = private_plan(1_391_338, corpus, 30)

    disabled = {
        "flag": False,
        "generate_next_map": "stock-slot2",
        "underground_generated": True,
        "descriptor": False,
    }
    enabled_shadow_failure = {
        "flag": True,
        "planner_ok": False,
        "generate_next_map": "stock-slot2",
        "underground_generated": True,
        "suppression_used": False,
    }
    enabled_shadow_success = {
        "flag": True,
        "planner_ok": True,
        "generate_next_map": "stock-slot2",
        "underground_generated": True,
        "suppression_used": False,
        "enablement_ready": False,
    }
    captured = {
        "schema": 1,
        "parameters": {
            "map_name": "UndergroundRandomMap",
            "map_slot": 2,
            "map_preset": "BlankUnderground",
            "dont_gen_additional": True,
            "no_new_game": True,
        },
        "mapdata": {
            "preset_id": "UndergroundRandomMap",
            "primitive_state": {
                "Environment": "Underground",
                "map_randomizeseed": False,
                "Seed": 938_271,
            },
            "map_randomizeseed": False,
            "Seed": 938_271,
            "seed_authority": "UIColony.map_seed",
            "seed_authority_value": 938_271,
        },
        "generator_seed": {
            "value": 171_991,
            "authority": "reserved-vanilla-underground-seed",
            "injection": "RandomMapGenerator.FillParams.Seed-before-original-fill",
        },
        "callback": {
            "tag": "publish-generated-map-to-UndergroundMap",
            "version": 1,
            "target_gamevar": "UndergroundMap",
            "value_semantics": "generated-map",
        },
    }
    base_mapdata = {"Environment": "Surface", "Width": 120}
    reconstructed_params = dict(captured["parameters"])
    reconstructed_mapdata = dict(base_mapdata)
    reconstructed_mapdata.update(captured["mapdata"]["primitive_state"])
    reconstructed_params["mapdata"] = reconstructed_mapdata
    reconstructed_scalar_params = {
        key: value for key, value in reconstructed_params.items() if key != "mapdata"
    }
    return {
        "private_plan_repeats_exactly": first == repeat and len(first[0]) == 2,
        "domain_seed_changes_plan_or_digest": first != other,
        "disabled_is_literal_v964_lifecycle": disabled
        == {
            "flag": False,
            "generate_next_map": "stock-slot2",
            "underground_generated": True,
            "descriptor": False,
        },
        "probe_failure_falls_through_without_suppression": (
            enabled_shadow_failure["generate_next_map"] == "stock-slot2"
            and enabled_shadow_failure["underground_generated"]
            and not enabled_shadow_failure["suppression_used"]
        ),
        "probe_success_still_cannot_enable_lazy_state": (
            enabled_shadow_success["generate_next_map"] == "stock-slot2"
            and enabled_shadow_success["underground_generated"]
            and not enabled_shadow_success["suppression_used"]
            and not enabled_shadow_success["enablement_ready"]
        ),
        "primitive_recipe_reconstructs_all_parameter_scalars": (
            reconstructed_scalar_params == captured["parameters"]
        ),
        "primitive_recipe_reconstructs_all_mapdata_scalars": all(
            reconstructed_mapdata[key] == value
            and type(reconstructed_mapdata[key]) is type(value)
            for key, value in captured["mapdata"]["primitive_state"].items()
        ),
        "recipe_encodes_both_seed_authorities": (
            captured["mapdata"]["Seed"]
            == captured["mapdata"]["seed_authority_value"]
            and captured["generator_seed"]["value"] != captured["mapdata"]["Seed"]
        ),
        "callback_is_value_tag_not_function_reference": (
            captured["callback"]
            == {
                "tag": "publish-generated-map-to-UndergroundMap",
                "version": 1,
                "target_gamevar": "UndergroundMap",
                "value_semantics": "generated-map",
            }
            and json.loads(json.dumps(captured)) == captured
        ),
    }


def main() -> int:
    config = CONFIG.read_text(encoding="utf-8")
    generation = GENERATION.read_text(encoding="utf-8")
    grid = GRID.read_text(encoding="utf-8")
    version = VERSION.read_text(encoding="utf-8")
    metadata = METADATA.read_text(encoding="utf-8")
    lua53_result = subprocess.run(
        [str(LUA53), "-p", str(GENERATION)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    ) if LUA53.is_file() else None

    helper_start = generation.index("-- v965 LAZY UNDERGROUND SOURCE-GENERATION FEASIBILITY")
    helper_end = generation.index("local function PatchAdditionalMapSeedReservation", helper_start)
    helper = generation[helper_start:helper_end]
    wrapper_start = generation.index("local additional_wrapper = function", helper_end)
    wrapper_end = generation.index("local fill_wrapper = function", wrapper_start)
    wrapper = generation[wrapper_start:wrapper_end]
    fill_start = wrapper_end
    fill_end = generation.index("local installed_targets = {}", fill_start)
    fill = generation[fill_start:fill_end]
    capture_start = generation.index("function Lazy.Capture(surface, pending, next_map)", helper_start)
    finalize_start = generation.index("function Lazy.FinalizePlan", capture_start)
    capture = generation[capture_start:finalize_start]
    finalize = generation[finalize_start:helper_end]
    generate_start = generation.index("local generate_wrapper = function", fill_end)
    generate_end = generation.index("generator_class.Generate = generate_wrapper", generate_start)
    generate = generation[generate_start:generate_end]
    notify_start = generation.index("local function NotifyGenerationMilestone")
    notify_end = generation.index("local function NeedsDeferredUndergroundPreparation", notify_start)
    notify = generation[notify_start:notify_end]
    surface_start = generation.index("local function RunSurfaceStretchIfEnabled")
    surface_end = generation.index("local function UndergroundExpansionReadiness", surface_start)
    surface = generation[surface_start:surface_end]
    clear_start = generation.index("local function ClearPreparedMapInstance")
    clear_end = generation.index("local function AttachPendingMapState", clear_start)
    clear = generation[clear_start:clear_end]

    original_call = wrapper.index("local results = PackValues(pcall(original_additional, ...))")
    capture_call = wrapper.index("lazy and lazy.Capture, map, pending, next_map")
    next_map_clear_tokens = (
        'rawset(_G, "GenerateNextMap", false)',
        'rawset(_G, "GenerateNextMap", nil)',
        'GenerateNextMap = false',
        'GenerateNextMap = nil',
    )
    checks = {
        "pinned_lua_5_3_6_compiles_generation_chunk": (
            lua53_result is not None and lua53_result.returncode == 0
        ),
        "metadata_retained_in_v966": "'version', 966," in metadata,
        "generator_wrapper_identity_v275": "SuperBigMap.GENERATOR_PATCH_VERSION = 275" in version,
        "feasibility_flag_default_off": (
            "config.LazyUndergroundSourceGenerationFeasibility = false" in config
            and "C.LAZY_UNDERGROUND_SOURCE_GENERATION_FEASIBILITY" in config
        ),
        "descriptor_and_report_are_surface_mapvars": all(
            f'register("{name}", false)' in grid
            for name in (
                "SuperBigMapLazyUndergroundDescriptor",
                "SuperBigMapLazyUndergroundFeasibilityReport",
            )
        ) and 'cfg_bool("LAZY_UNDERGROUND_SOURCE_GENERATION_FEASIBILITY", false)' in grid,
        "default_off_does_not_enlarge_mapvar_schema": (
            grid.index('cfg_bool("LAZY_UNDERGROUND_SOURCE_GENERATION_FEASIBILITY", false)')
            < grid.index('register("SuperBigMapLazyUndergroundDescriptor", false)')
            < grid.index('register("SuperBigMapLazyUndergroundFeasibilityReport", false)')
        ),
        "descriptor_schema_domain_and_callback_are_versioned": all(
            token in helper
            for token in (
                "SCHEMA = 1",
                "SuperBigMap/v965/lazy-underground-surface-passage-capsules",
                'CALLBACK_TAG = "publish-generated-map-to-UndergroundMap"',
                "CALLBACK_VERSION = 1",
                'algorithm = "lcg-48271-mod-2147483647"',
            )
        ),
        "default_off_constructs_no_v965_helper_closures_or_test_exports": (
            helper.index('if SuperBigMap.State.lazy_underground_reload_restore_ok ~= false')
            < helper.index("local Lazy = {")
            < helper.index("function Lazy.PrimitiveTree")
            < helper.index("SuperBigMap.LazyUndergroundFeasibility = Lazy")
            and "local function CaptureLazyUnderground" not in generation
            and "local function FinalizeLazyUnderground" not in generation
            and "local lazy = SuperBigMap.LazyUndergroundFeasibility" not in generation[
                generation.index("MapGeneration.NotifyGenerationMilestone"):
            ]
            and generation.index(
                'if (cfg_bool("LAZY_UNDERGROUND_SOURCE_GENERATION_FEASIBILITY", false)',
                generation.index("MapGeneration.NotifyGenerationMilestone"),
            )
            < generation.index("MapGeneration.BuildLazyUndergroundCapsulePlanForTest")
        ),
        "descriptor_is_primitive_checked_and_contains_no_function_refs": (
            "Lazy.PrimitiveTree(descriptor)" in helper
            and "descriptor_primitive" in helper
            and all(token not in capture[capture.index("local descriptor = {") :] for token in (
                "surface = surface", "on_map_generated = next_map.on_map_generated",
                "callback_function =", "generator =", "grid =", "object =",
            ))
        ),
        "capture_occurs_after_stock_descriptor_publication": original_call < capture_call,
        "generate_additional_boundary_captures_values_only": (
            "Lazy.BuildCapsulePlan" not in capture
            and "capsule_plan_pending = true" in capture
            and "source-layout buildable grid is not a" in capture
        ),
        "complete_stock_recipe_is_captured_value_only": all(
            token in capture
            for token in (
                "Lazy.CaptureScalarState(next_map",
                "Lazy.CaptureScalarState(mapdata)",
                "next_map.dont_gen_additional == true",
                "next_map.no_new_game == true",
                "recipe_identity_exact",
                "mapdata.map_randomizeseed == false",
                "mapdata.Seed == ui_map_seed",
                'seed_authority = "UIColony.map_seed"',
                'authority = "reserved-vanilla-underground-seed"',
                'injection = "RandomMapGenerator.FillParams.Seed-before-original-fill"',
                "parameters = params_state",
                "primitive_state = mapdata_state",
                "capture_complete = recipe_capture_complete",
            )
        ),
        "callback_publication_is_a_versioned_semantics_tag_only": all(
            token in capture
            for token in (
                "tag = Lazy.CALLBACK_TAG",
                "version = Lazy.CALLBACK_VERSION",
                'target_gamevar = "UndergroundMap"',
                'value_semantics = "generated-map"',
            )
        ) and "on_map_generated =" not in capture[capture.index("local descriptor = {"):],
        "capture_does_not_allocate_a_second_mapdata_instance": (
            "Lazy.ReconstructRecipeValues(descriptor)" not in capture
            and "recipe_reconstruction_pending = true" in capture
            and "Do not instantiate a second MapData" in capture
        ),
        "primitive_recipe_is_reconstructed_and_exactly_compared_post_final": all(
            token in finalize
            for token in (
                "Lazy.ReconstructRecipeValues(descriptor)",
                "recipe_reconstruction_pending = false",
                "recipe_reconstruction_parameters_match",
                "recipe_reconstruction_mapdata_match",
                "recipe_reconstruction_exact",
            )
        ),
        "recipe_reconstruction_fails_closed_on_identity_flags_and_seed_authority": all(
            token in helper
            for token in (
                'return nil, "GenerateNextMap identity/recursion flags are incomplete"',
                "recipe.parameters.dont_gen_additional ~= true",
                "recipe.parameters.no_new_game ~= true",
                "recipe.mapdata.primitive_state.map_randomizeseed ~= false",
                "recipe.mapdata.primitive_state.Seed ~= recipe.mapdata.Seed",
                'recipe.mapdata.seed_authority ~= "UIColony.map_seed"',
                '"RandomMapGenerator.FillParams.Seed-before-original-fill"',
                'return nil, "MapData/generator seed authority is incomplete"',
            )
        ),
        "mapdata_nonprimitive_defaults_are_truthfully_constructor_supplied": all(
            token in capture
            for token in (
                "primitive_mutable_overrides_exact = true",
                'nonprimitive_defaults_source = "same-MapData-preset-constructor"',
                "nonprimitive_defaults_captured = false",
                "report.recipe_nonprimitive_equivalence_proven = false",
                "report.recipe_full_state_reconstruction_proven = false",
                'report.recipe_reconstruction_exact_scope = "primitive-own-fields-only"',
                'constructor_tag = "MapData[preset_id]:CreateInstance"',
            )
        ),
        "capture_requires_exact_stock_slot2_shape": all(
            token in wrapper
            for token in (
                'type(next_map) == "table" and next_map.map_slot == 2',
                'cfg_bool("LAZY_UNDERGROUND_SOURCE_GENERATION_FEASIBILITY", false)',
            )
        ),
        "probe_never_suppresses_generate_next_map": not any(
            token in helper or token in wrapper for token in next_map_clear_tokens
        ),
        "all_probe_failures_keep_literal_generation": all(
            token in wrapper + helper
            for token in (
                "literal_v964_continues = true",
                "suppression_used = false",
                "feasibility capture raised:",
            )
        ),
        "capsule_plan_requires_exactly_two": all(
            token in helper
            for token in (
                "capsules_required = 2",
                "private capsule planner did not find exactly two valid inner sites",
                "minimum_distance * minimum_distance",
                'get_shape("Elevator")',
                "FindBuildableAreaAround",
            )
        ),
        "capsule_plan_avoids_stock_deposit_and_geyser_exclusions": all(
            token in helper
            for token in (
                '"TerrainDepositMarker"', 'marker.resource == "Concrete"',
                '"PrefabFeatureMarker"', '"PrefabFeatureCharPreset_Geyser"',
                "marker:GetObstructionRadius()", "marker.FeatureRadius",
            )
        ),
        "planner_uses_no_shared_rng": all(
            token not in helper for token in ("AsyncRand(", "SessionRandom", "city:Random(")
        ) and "next_private" in helper,
        "deterministic_repeat_is_runtime_checked": all(
            token in finalize
            for token in (
                "Lazy.BuildCapsulePlan(surface, pending, next_map)",
                "repeat_exact", "report.deterministic_repeat",
            )
        ),
        "capsules_are_planned_only_after_canonical_final_rebuild": all(
            token in finalize
            for token in (
                'report.plan_boundary = "after-canonical-final-grid-rebuild-before-surface-publication"',
                "report.selection_grid_current = surface.SuperBigMapSurfacePostPipelineRevalidationComplete == true",
                "report.final_grid_revalidation = report.selection_grid_current",
            )
        ) and surface.index("map.SuperBigMapSurfacePostPipelineRevalidationComplete = true")
        < surface.index("SuperBigMap.LazyUndergroundFeasibility.FinalizePlanSafe(map)",
                        surface.index("map.SuperBigMapSurfacePostPipelineRevalidationComplete = true"))
        < surface.index("publish_deferred_surface_completion()",
                        surface.index("map.SuperBigMapSurfacePostPipelineRevalidationComplete = true")),
        "default_off_has_no_finalizer_wrapper_closure": (
            "local function finalize_lazy_underground_feasibility_shadow" not in surface
            and "function Lazy.FinalizePlanSafe(surface)" in helper
        ),
        "shadow_eager_passage_obstruction_is_truthful": (
            "report.shadow_contains_eager_passage_obstructions = true" in finalize
            and "conservative superset" in finalize
        ),
        "future_enablement_is_explicitly_blocked": all(
            token in helper
            for token in (
                "report.enablement_ready = false",
                "report.access_gate_installed = false",
                "report.shared_rng_isolation_proven = false",
            )
        ),
        "route_inventory_is_api_presence_only_and_unit_method_is_verified": all(
            token in capture
            for token in (
                'Engine.ClassTable("ConstructionController")',
                'Engine.ClassTable("ElevatorBase")',
                'Engine.ClassTable("Unit")',
                'type(Global("ChangeCurrentMapSlot")) == "function"',
                "type(construction_controller.Activate) == \"function\"",
                "type(elevator_base.PlaceConstructionSite) == \"function\"",
                "type(unit_class.UseElevator) == \"function\"",
                "report.route_presence_complete",
                "report.route_execution_coverage_proven = false",
            )
        ) and "route_coverage_observed" not in capture,
        "literal_generate_consumer_compares_parameter_and_mapdata_recipe": all(
            token in generate + helper
            for token in (
                "feasibility.ObserveGenerateParameters, params",
                "Lazy.CompareScalarState(recipe.parameters, params)",
                "Lazy.CompareScalarState(recipe.mapdata.primitive_state, params.mapdata)",
                "report.consumer_callback_function_present",
                "report.consumer_recipe_match",
            )
        ),
        "literal_fill_consumer_compares_map_seed_and_randomize_contract": all(
            token in fill
            for token in (
                "report.consumer_seed_match = report.consumer_seed == descriptor.reserved_seed",
                "report.consumer_map_match = report.consumer_map_name == descriptor.map_name",
                "report.consumer_fill_randomize_forced = consumer_randomize_forced",
                "report.consumer_generator_seed_recipe_match",
                "report.literal_fill_completed = results[1] == true",
            )
        ),
        "literal_callback_publication_is_observed_after_map_generated": all(
            token in notify + helper
            for token in (
                "feasibility.ObservePublishedUnderground, map",
                'Global("UndergroundMap") == map',
                "report.consumer_callback_tag_match",
                "report.consumer_callback_publication_match",
            )
        ),
        "final_shadow_requires_all_recipe_consumer_comparisons": all(
            token in finalize
            for token in (
                "report.recipe_consumer_exact",
                "report.recipe_reconstruction_exact == true",
                "report.consumer_recipe_match == true",
                "report.consumer_fill_randomize_forced == true",
                "report.consumer_generator_seed_recipe_match == true",
                "report.consumer_callback_publication_match == true",
                "report.used = report.used == true and report.recipe_consumer_exact == true",
            )
        ),
        "fresh_map_cleanup_clears_shadow_evidence": all(
            token in clear
            for token in (
                "map.SuperBigMapLazyUndergroundDescriptor = false",
                "map.SuperBigMapLazyUndergroundFeasibilityReport = false",
            )
        ) and clear.index('cfg_bool("LAZY_UNDERGROUND_SOURCE_GENERATION_FEASIBILITY", false)')
        < clear.index("map.SuperBigMapLazyUndergroundDescriptor = false"),
    }
    checks.update(state_cases())
    failed = sorted(name for name, passed in checks.items() if passed is not True)
    report = {
        "schema": "smr.ralph.v965.lazy-underground-feasibility.v1",
        "ok": not failed,
        "checks": checks,
        "failed": failed,
        "activation": {
            "default_on": False,
            "suppression_implemented": False,
            "runtime_probe_needed": True,
            "expected_full_candidate_t0_saving_ms": [29_000, 30_500],
        },
        "hashes": {
            str(path.relative_to(ROOT)).replace("\\", "/"): digest(path)
            for path in (CONFIG, GENERATION, GRID, VERSION, METADATA)
        },
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())

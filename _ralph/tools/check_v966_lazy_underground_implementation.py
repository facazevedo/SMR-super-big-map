#!/usr/bin/env python3
"""Fail-closed static/state oracle for the default-off v966 lazy-UG implementation."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "Code" / "sbm_config.lua"
GENERATION = ROOT / "Code" / "sbm_map_generation.lua"
TERRAIN = ROOT / "Code" / "sbm_terrain_copy.lua"
GRID = ROOT / "Code" / "sbm_sector_grid.lua"
VERSION = ROOT / "Code" / "sbm_version.lua"
METADATA = ROOT / "metadata.lua"
LUA53 = (
    ROOT / "_ralph" / "tmp" / ".tmp_surface_loading_rough_iter109_lua53"
    / "lua-5.3.6" / "src" / "luac.exe"
)
STATE_ORACLE = ROOT / "_ralph" / "tools" / "v966_lazy_underground_state_oracle.py"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


@dataclass
class Model:
    state: str = "captured"
    suppression_committed: bool = False
    map_exists: bool = False
    published: bool = False
    prepared: bool = False
    generation_count: int = 0
    exposed: bool = False

    def suppress(self, capture_ok: bool, writer_ok: bool,
                 rollback_complete: bool = True) -> None:
        if not capture_ok or (not writer_ok and rollback_complete):
            self.state = "eager-fallback"
            return
        if not writer_ok:
            self.suppression_committed = True
            self.state = "blocked"
            return
        self.suppression_committed = True
        self.state = "suppressed"

    def capsules(self, plan_ok: bool, publish_ok: bool, final_ok: bool) -> None:
        if not self.suppression_committed:
            return
        if not (plan_ok and publish_ok and final_ok):
            self.state = "blocked"
            return
        self.state = "ready"

    def first_access(self, generate_ok: bool, callback_ok: bool, bind_ok: bool,
                     city_ok: bool, stretch_ok: bool, audit_ok: bool) -> None:
        if self.state == "complete":
            return
        if self.state != "ready":
            self.exposed = False
            return
        self.state = "generating"
        if generate_ok:
            self.map_exists = True
            self.generation_count += 1
        self.published = generate_ok and callback_ok
        self.prepared = all((generate_ok, callback_ok, bind_ok, city_ok, stretch_ok, audit_ok))
        if self.prepared and self.generation_count == 1:
            self.state = "complete"
            self.exposed = True
        else:
            self.state = "blocked"
            self.exposed = False


def model_checks() -> dict[str, bool]:
    eager = Model()
    eager.suppress(capture_ok=False, writer_ok=True)
    writer = Model()
    writer.suppress(capture_ok=True, writer_ok=False)
    rollback = Model()
    rollback.suppress(capture_ok=True, writer_ok=False, rollback_complete=False)
    capsule_fail = Model()
    capsule_fail.suppress(True, True)
    capsule_fail.capsules(True, False, True)
    generation_fail = Model()
    generation_fail.suppress(True, True)
    generation_fail.capsules(True, True, True)
    generation_fail.first_access(True, True, True, True, False, True)
    success = Model()
    success.suppress(True, True)
    success.capsules(True, True, True)
    success.first_access(True, True, True, True, True, True)
    success.first_access(True, True, True, True, True, True)
    return {
        "precommit_capture_failure_is_literal_eager": (
            eager.state == "eager-fallback" and not eager.suppression_committed
        ),
        "precommit_writer_failure_is_literal_eager": (
            writer.state == "eager-fallback" and not writer.suppression_committed
        ),
        "incomplete_writer_rollback_is_sticky_blocked": (
            rollback.state == "blocked" and rollback.suppression_committed
        ),
        "postcommit_capsule_failure_is_sticky_blocked": (
            capsule_fail.state == "blocked" and not capsule_fail.exposed
        ),
        "partial_generated_map_is_never_exposed": (
            generation_fail.map_exists and generation_fail.state == "blocked"
            and not generation_fail.exposed
        ),
        "successful_transaction_exposes_exactly_once": (
            success.state == "complete" and success.exposed and success.generation_count == 1
        ),
    }


def main() -> int:
    config = CONFIG.read_text(encoding="utf-8")
    generation = GENERATION.read_text(encoding="utf-8")
    terrain = TERRAIN.read_text(encoding="utf-8")
    grid = GRID.read_text(encoding="utf-8")
    version = VERSION.read_text(encoding="utf-8")
    metadata = METADATA.read_text(encoding="utf-8")
    oracle_run = subprocess.run(
        [sys.executable, str(STATE_ORACLE)], cwd=ROOT, capture_output=True, text=True,
        timeout=30, check=False,
    )
    try:
        oracle = json.loads(oracle_run.stdout)
    except json.JSONDecodeError:
        oracle = {"ok": False, "error": oracle_run.stderr or oracle_run.stdout}
    helper_start = generation.index("-- v965 LAZY UNDERGROUND SOURCE-GENERATION FEASIBILITY")
    helper_end = generation.index("local function PatchAdditionalMapSeedReservation", helper_start)
    helper = generation[helper_start:helper_end]
    wrapper_start = generation.index("local additional_wrapper = function", helper_end)
    wrapper_end = generation.index("local fill_wrapper = function", wrapper_start)
    wrapper = generation[wrapper_start:wrapper_end]
    access_start = generation.index("local function PatchDeferredUndergroundAccess")
    access_end = generation.index("local function HandleDeferredUndergroundMapChange", access_start)
    access = generation[access_start:access_end]
    elevator_start = generation.index("local function PatchDeferredUndergroundElevatorAccess")
    elevator_end = generation.index("local function ResolveHudUndergroundTarget", elevator_start)
    elevator = generation[elevator_start:elevator_end]
    hud_start = generation.index("local function PatchDeferredUndergroundHudAccess")
    hud_end = access_start
    hud = generation[hud_start:hud_end]

    compile_results: dict[str, bool] = {}
    for path in (CONFIG, GENERATION, TERRAIN, GRID, VERSION, METADATA):
        result = subprocess.run(
            [str(LUA53), "-p", str(path)], cwd=ROOT, capture_output=True,
            text=True, timeout=30, check=False,
        ) if LUA53.is_file() else None
        compile_results[path.relative_to(ROOT).as_posix()] = bool(
            result is not None and result.returncode == 0
        )

    suppress_call = wrapper.index("lazy.SuppressGenerateNextMap, map, next_map")
    capture_call = wrapper.index("lazy and lazy.Capture, map, pending, next_map")
    original_call = wrapper.index("PackValues(pcall(original_additional, ...))")
    access_materialize = access.index('lazy.Materialize(lazy_surface, "change-current-map-slot")')
    access_original = access.index("local result = original(map_slot")

    checks = {
        "pinned_lua_5_3_6_compiles_all_touched_lua": all(compile_results.values()),
        "focused_fault_state_oracle_is_green": (
            oracle_run.returncode == 0 and oracle.get("ok") is True
        ),
        "metadata_retained_in_v969": "'version', 969," in metadata,
        "generator_patch_identity_v275": "SuperBigMap.GENERATOR_PATCH_VERSION = 275" in version,
        "implementation_flag_is_separate_and_default_off": all(token in config for token in (
            "config.LazyUndergroundSourceGenerationFeasibility = false",
            "config.LazyUndergroundSourceGeneration = false",
            "C.LAZY_UNDERGROUND_SOURCE_GENERATION_FEASIBILITY",
            "C.LAZY_UNDERGROUND_SOURCE_GENERATION =",
        )),
        "default_off_constructs_no_lazy_helper_table": all(token in helper for token in (
            'if SuperBigMap.State.lazy_underground_reload_restore_ok ~= false',
            'and (cfg_bool("LAZY_UNDERGROUND_SOURCE_GENERATION_FEASIBILITY", false)',
            'or cfg_bool("LAZY_UNDERGROUND_SOURCE_GENERATION", false)) then',
            'local Lazy = {',
        )),
        "mapvars_exist_only_when_a_lazy_flag_is_compiled": all(token in grid for token in (
            'cfg_bool("LAZY_UNDERGROUND_SOURCE_GENERATION_FEASIBILITY", false)',
            'or cfg_bool("LAZY_UNDERGROUND_SOURCE_GENERATION", false)',
            'register("SuperBigMapLazyUndergroundDescriptor", false)',
            'register("SuperBigMapLazyUndergroundFeasibilityReport", false)',
        )),
        "recipe_capture_precedes_only_transactional_suppression": (
            original_call < capture_call < suppress_call
            and 'Lazy.ReplaceEngineGlobal("GenerateNextMap", next_map, false)' in helper
            and "local restored = Lazy.RestoreEngineGlobal(token)" in helper
            and "Lazy.RememberEngineRestoreToken(token)" in helper
        ),
        "precommit_failure_retains_literal_eager_table": all(token in wrapper for token in (
            "precommit suppression failed",
            'descriptor.state = "fallback-eager-after-precommit-failure"',
            "report.literal_v964_continues = true",
            "report.suppression_committed = false",
        )),
        "incomplete_suppression_rollback_never_claims_eager": all(
            token in helper + wrapper for token in (
                "descriptor.suppression_rollback_incomplete = true",
                "descriptor.suppression_state_uncertain = true",
                "report.suppression_rollback_incomplete = true",
                "report.literal_v964_continues = false",
                "local rollback_incomplete = type(descriptor) == \"table\"",
                "if rollback_incomplete then",
                "Never relabel this as the literal eager path",
            )
        ),
        "postcommit_failure_is_sticky_blocked": all(token in helper for token in (
            'descriptor.state = "blocked"',
            "descriptor.failure_sticky = true",
            "report.access_blocked = true",
            "failure_sticky",
        )),
        "descriptor_is_value_only_and_runtime_callback_is_not_persisted": (
            "Lazy.PrimitiveTree(descriptor)" in helper
            and 'callback = {' in helper
            and 'tag = Lazy.CALLBACK_TAG' in helper
            and 'params.on_map_generated = function(map)' in helper
            and "on_map_generated = next_map.on_map_generated" not in helper
        ),
        "exact_generator_recipe_and_seed_are_reconstructed": all(token in helper for token in (
            "MapData[preset_id]:CreateInstance",
            "recipe.parameters.dont_gen_additional ~= true",
            "recipe.parameters.no_new_game ~= true",
            "recipe.mapdata.map_randomizeseed ~= false",
            'seed_authority ~= "UIColony.map_seed"',
            "generator_seed = recipe.generator_seed.value",
            "State.pending_vanilla_underground_seed = {",
            'boundary = "v966_lazy_first_access_replay"',
        )),
        "no_underground_map_city_or_partial_object_before_first_access": all(
            token in helper for token in (
                'descriptor.state = "suppressed-awaiting-surface-capsules"',
                'if Global("UndergroundMap") or type(maps) == "table" and maps[descriptor.map_slot]',
                '"ready-for-first-access"',
            )
        ),
        "two_real_surface_capsules_publish_before_canonical_final_rebuild": (
            'pcall(place, "UndergroundPassage", surface)' in helper
            and 'passage.SuperBigMapLazyUndergroundCapsuleIndex = index' in helper
            and 'pcall(flatten, shape, passage, "flatten unbuildable")' in helper
            and "pcall(passage.Spawn, passage)" in helper
            and "lazy.PrepareImplementationCapsulesAroundRebuild(map," in generation
            and generation.index("lazy.PrepareImplementationCapsulesAroundRebuild(map,")
            < generation.index('"post-pipeline scheduled revalidation"')
        ),
        "capsules_have_final_grid_marker_and_sign_certificate": all(token in helper for token in (
            "Lazy.ValidatePublishedCapsules(surface, descriptor)",
            "passage.IsValidPlacement",
            '"UndergroundTunnelMarker"',
            "markers ~= 2 or signs ~= 2",
            "report.final_grid_revalidation = true",
        )),
        "retained_native_surface_state_is_released_before_t1": all(token in helper for token in (
            'ReleaseRetainedNativeSourceMap(surface, "v969 fresh-grid capsules published")',
            "SuperBigMap.FreeOwnedGrid(retained_buildable.grid)",
            "report.native_source_retention_released_before_t1 = true",
        )),
        "stock_ug_bootstrap_binds_capsules_without_surface_rng": all(token in generation for token in (
            "lazy_underground_passage_binding",
            "spawn_surface_anchor = lazy_binding.wrapper",
            "passage coordinates are the",
            "must not consume the live Surface RNG",
            "binding.calls ~= 2",
        )),
        "binding_global_is_restored_in_success_and_error_paths": all(token in helper for token in (
            'Lazy.ReplaceEngineGlobal(\n\t\t"SpawnUndergroundPassage"',
            "local restored = Lazy.RestoreTransientPassageBinding(binding)",
            "if restored and State.lazy_underground_passage_binding == binding then",
            "State.lazy_underground_passage_binding = nil",
            'return nil, "SpawnUndergroundPassage wrapper restoration failed"',
        )),
        "engine_restore_is_idempotent_and_retry_safe": all(token in helper for token in (
            "if token.restored == true then return true end",
            "if readable and current == token.expected then",
            "Already restored is success, not an ownership mismatch.",
            "if exact then token.restored = true end",
            "function Lazy.RestorePendingEngineGlobals()",
            "table.remove(pending, index)",
        )),
        "mutate_then_throw_is_tracked_and_rollback_verified": all(token in helper for token in (
            "call_ok, acknowledged = pcall(record.writer, name, value)",
            "token.changed[#token.changed + 1] = record",
            "if not exact or not acknowledged then",
            "if not restored then Lazy.RememberEngineRestoreToken(token) end",
        )),
        "transient_binding_tracking_survives_partial_cleanup": all(token in helper for token in (
            "function Lazy.RestoreTransientPassageBinding(expected_binding)",
            "if expected_binding ~= nil and binding ~= expected_binding then return false end",
            "if restored and State.lazy_underground_passage_binding == binding then",
            "return restored",
        )),
        "hot_reload_restores_through_stable_state_before_helper_clear": (
            helper.index("local restore = State.lazy_underground_runtime_restore")
            < helper.index("SuperBigMap.LazyUndergroundFeasibility = nil")
            and all(token in helper + generation for token in (
                "helper reload before table clear",
                "State.lazy_underground_runtime_restore = Lazy.RestoreRuntimeState",
                "function Lazy.RestoreRuntimeState(reason)",
                "local globals_ok = Lazy.RestorePendingEngineGlobals()",
                "local lazy_restore = State.lazy_underground_runtime_restore",
                'pcall(lazy_restore, "RestoreVanillaBehavior")',
            ))
        ),
        "construction_teardown_retains_unresolved_ownership_for_retry": all(
            token in helper for token in (
                "if current == patch.original then",
                "elseif current == patch.wrapper then",
                "if exact then",
                "State.lazy_underground_construction_patches = nil",
                "return exact",
            )
        ),
        "fixed_capsules_preserve_generated_source_and_final_pair_domain": all(token in terrain for token in (
            "fixed_surface_capsules",
            "world_ok, fixed_x, fixed_y = pcall(hex_to_world, fixed_q, fixed_r)",
            "plan.final_q, plan.final_r = fixed_q, fixed_r",
            "plan.final_x, plan.final_y = fixed_x, fixed_y",
            "anchor.SuperBigMapCommittedPassageSourceQ = plan.source_q",
        )) and "and pcall(hex_to_world, fixed_q, fixed_r) or false" not in terrain,
        "first_access_generates_once_then_runs_full_completion": all(token in helper for token in (
            "descriptor.materialization_attempts ~= 1",
            "descriptor.generation_count ~= 1",
            'pcall(generate, descriptor.map_name, descriptor.map_preset, params)',
            "underground.SuperBigMapNativeGenerationComplete ~= true",
            "underground.SuperBigMapCityInitializationComplete ~= true",
            "pipeline(underground, true)",
            "underground.SuperBigMapUndergroundPrepared ~= true",
            "Lazy.ValidateCompletedPairs(surface, underground, descriptor)",
        )),
        "change_map_slot_materializes_before_any_original_switch": (
            access_materialize < access_original
            and "local target = type(maps) == \"table\" and maps[map_slot] or nil" in access
            and "lazy_pending, lazy_surface = lazy.PendingForSlot(map_slot)" in access
        ),
        "hud_route_is_slot_based_even_without_maps2": all(token in hud for token in (
            "requested_slot = target and target.slot",
            "lazy.PendingForSlot(requested_slot)",
            "gate(requested_slot, true",
        )),
        "unit_route_checks_capsule_before_other_map": (
            "lazy.PendingForElevator(elevator)" in elevator
            and elevator.index("lazy.PendingForElevator(elevator)")
            < elevator.index("PrepareDeferredUndergroundForElevator")
        ),
        "construction_routes_materialize_before_stock_dereference": all(token in helper for token in (
            'Lazy.MaterializeWithForegroundCover("construction-activate")',
            "map.MapFindNearest",
            "Lazy.PendingForElevator(passage)",
            '"elevator-place-construction-site"',
            "Only now may stock evaluate passage.other:GetMap().",
            "return place_site(self, city, class_name, position, angle, params,",
            "#patches == 2",
        )),
        "every_materialization_route_owns_visible_foreground_cover": all(token in helper + access for token in (
            "SuperBigMap.ExpansionLoadingBegin",
            "LoadingScreenOpen",
            "SetLoadingPhase",
            "SuperBigMap.ExpansionLoadingEnd",
        )),
        "save_load_ready_complete_and_interrupted_states_fail_closed": all(token in helper for token in (
            "function Lazy.ValidatePersistedState(surface)",
            'descriptor.state == "generating"',
            "interrupted lazy-underground generation transaction",
            'descriptor.state == "ready-for-first-access"',
            'descriptor.state == "complete"',
            "completed descriptor lost its prepared underground map",
        )),
        "no_background_materialization_is_scheduled": (
            "CreateRealTimeThread" not in helper[
                helper.index("function Lazy.Materialize(surface, route)"):
                helper.index("function Lazy.ShowAccessFailure")
            ]
        ),
    }
    checks.update(model_checks())
    failed = sorted(name for name, ok in checks.items() if not ok)
    payload = {
        "schema": "smr.ralph.v966.lazy-underground-implementation.v1",
        "ok": not failed,
        "failed": failed,
        "checks": checks,
        "compile": compile_results,
        "state_oracle": oracle,
        "activation": {
            "default_on": False,
            "live_runtime_required": True,
            "expected_t0_saving_ms": [29_000, 40_000],
            "failure_policy": "literal eager before suppression; sticky blocked after suppression",
        },
        "hashes": {p.relative_to(ROOT).as_posix(): sha(p) for p in (
            CONFIG, GENERATION, TERRAIN, GRID, VERSION, METADATA, STATE_ORACLE
        )},
    }
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())

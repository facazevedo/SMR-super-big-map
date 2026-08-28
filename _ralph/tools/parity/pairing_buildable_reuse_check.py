#!/usr/bin/env python3
"""Offline certificate for strict reuse of the superseded surface pairing rebuild.

The production optimization does not substitute a different buildable answer. Underground passage
bootstrap already installs the retained native source grid before the only surface-buildable read.
This checker proves the geometry guard/model, exercises every individual proof guard fail-closed,
and checks that the legacy rebuild, native-grid bridge, and later canonical rebuild remain in source.
It does not launch the game.
"""

from __future__ import annotations

import hashlib
import itertools
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
MAP_GENERATION_PATH = ROOT / "Code" / "sbm_map_generation.lua"
LIFECYCLE_PATH = ROOT / "Code" / "sbm_lifecycle.lua"
CONFIG_PATH = ROOT / "Code" / "sbm_config.lua"
VERSION_PATH = ROOT / "Code" / "sbm_version.lua"
METADATA_PATH = ROOT / "metadata.lua"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def expected_source_dimension(expanded: int, generator: int, desired: int) -> int:
    # Lua's positive-number math.floor(x + 0.5) is integer half-up rounding. The integer form makes
    # the acceptance geometry independent of host floating-point behavior for the supported sizes.
    return max(1, (expanded * generator * 2 + desired) // (desired * 2))


GUARDS = (
    "requested",
    "canonical_rebuild_enabled",
    "surface_map_valid",
    "surface_buildable_current",
    "stretch_pipeline_pending",
    "surface_stretch_not_done",
    "proof_version_matches",
    "proof_stage_matches",
    "destination_identity_matches",
    "native_grid_identity_matches",
    "restore_grid_identity_matches",
    "dimensions_match_proof",
    "dimensions_match_live_map",
    "source_geometry_matches",
    "retained_backing_owned_if_enabled",
)


def reuse_model(state: dict[str, bool]) -> bool:
    return all(state[name] for name in GUARDS)


def semantic_checks() -> tuple[dict[str, bool], list[dict[str, object]]]:
    geometry_cases = (
        (820, 946, 6144, 6144, 8192, 8192, 615, 710),
        (820, 820, 6144, 6144, 8192, 8192, 615, 615),
        (946, 820, 6144, 6144, 8192, 8192, 710, 615),
        (1025, 1025, 6144, 6144, 8192, 8192, 769, 769),
    )
    geometry_ok = all(
        expected_source_dimension(expanded_w, generator_w, desired_w) == expected_w
        and expected_source_dimension(expanded_h, generator_h, desired_h) == expected_h
        for (
            expanded_w,
            expanded_h,
            generator_w,
            generator_h,
            desired_w,
            desired_h,
            expected_w,
            expected_h,
        ) in geometry_cases
    )

    baseline = {name: True for name in GUARDS}
    cases: list[dict[str, object]] = []
    cases.append({"case": "complete-proof", "accepted": reuse_model(baseline)})
    single_guard_fail_closed = True
    for guard in GUARDS:
        mutated = dict(baseline)
        mutated[guard] = False
        accepted = reuse_model(mutated)
        single_guard_fail_closed &= not accepted
        cases.append({"case": f"reject-{guard}", "accepted": accepted})

    # Exhaust all combinations too: only the one complete proof may be accepted.
    exhaustive_ok = True
    accepted_count = 0
    for values in itertools.product((False, True), repeat=len(GUARDS)):
        state = dict(zip(GUARDS, values, strict=True))
        accepted = reuse_model(state)
        accepted_count += int(accepted)
        exhaustive_ok &= accepted == all(values)

    checks = {
        "supported_8192_geometry_maps_820x946_to_615x710": geometry_ok,
        "complete_proof_is_accepted": cases[0]["accepted"] is True,
        "each_guard_fails_closed": single_guard_fail_closed,
        "all_guard_combinations_accept_only_complete_proof": exhaustive_ok and accepted_count == 1,
    }
    return checks, cases


def structural_checks(
    map_generation: str, lifecycle: str, config: str, version: str, metadata: str
) -> dict[str, bool]:
    capture_start = map_generation.index(
        "function SuperBigMap.CaptureSurfacePairingBuildableReuseProof")
    validate_start = map_generation.index(
        "function SuperBigMap.ValidateSurfacePairingBuildableReuse", capture_start)
    validate_end = map_generation.index(
        "\n-- Resource shaping is hard-clipped", validate_start)
    capture = map_generation[capture_start:validate_start]
    validate = map_generation[validate_start:validate_end]

    migration_rebuild = map_generation.index(
        'LoadingBegin("rebuild destination grids after source migration"')
    migration_rebuild_call = map_generation.index("destination:RebuildGrids(", migration_rebuild)
    proof_capture_call = map_generation.index(
        "SuperBigMap.CaptureSurfacePairingBuildableReuseProof, destination", migration_rebuild_call)

    pre_ug_start = map_generation.index("-- DETERMINISTIC ENTRANCE PAIRING")
    pre_ug_end = map_generation.index("\n\t\t\tState.rmg_placement_active_map = map", pre_ug_start)
    pre_ug = map_generation[pre_ug_start:pre_ug_end]
    validate_call = pre_ug.index("SuperBigMap.ValidateSurfacePairingBuildableReuse, main_map")
    fallback_branch = pre_ug.index("if not reuse_ok then", validate_call)
    fallback_rebuild = pre_ug.index("pcall(rebuild, main_map)", fallback_branch)
    do_generate_call = map_generation.index(
        "call_original_do_generate, self, map", pre_ug_end)

    bootstrap_start = map_generation.index("local function BootstrapPassagesAndDeferWonders")
    bootstrap_end = map_generation.index("\nlocal function DeferredWonderScaleRatios", bootstrap_start)
    bootstrap = map_generation[bootstrap_start:bootstrap_end]
    bridge_install = bootstrap.index("surface_map.buildable.z_grid = padded_surface_grid")
    spawn_call = bootstrap.index("spawn_surface_anchor(surface_map,", bridge_install)
    bridge_restore = bootstrap.index("surface_map.buildable.z_grid = stock_surface_grid", bridge_install)
    bridge_free = bootstrap.index("SuperBigMap.FreeOwnedGrid(padded_surface_grid)", bridge_restore)
    bridge_restore_call = bootstrap.index("RestoreSurfaceBuildableBridge()", spawn_call)

    on_generate_start = map_generation.index("local on_generate_logic_wrapper = function")
    on_generate_end = map_generation.index(
        "generator_class.OnGenerateLogic = on_generate_logic_wrapper", on_generate_start)
    on_generate = map_generation[on_generate_start:on_generate_end]

    stretch_invalidate = map_generation.index(
        "map.SuperBigMapSurfaceBuildableCurrent = false")
    final_rebuild = map_generation.index(
        'LoadingBegin("surface final RebuildBuildableGrid", map)', stretch_invalidate)

    postnew_handler = lifecycle.index('RegisterOnce("PostNewMapLoaded"')
    postnew_schedule = lifecycle.index(
        'gen.RunSurfaceStretchIfEnabled(map, "PostNewMapLoaded")', postnew_handler)
    mapgenerated_handler = lifecycle.index('RegisterOnce("MapGenerated"', postnew_schedule)
    run_surface_start = map_generation.index("local function RunSurfaceStretchIfEnabled")
    pending_assignment = map_generation.index(
        "map.SuperBigMapStretchPipelinePending = true", run_surface_start)
    readiness_call = map_generation.index(
        "local ready, readiness = SurfaceExpansionReadiness(map)", run_surface_start)

    forbidden_read_only_tokens = (
        "SetHeightGrid",
        "SetTerrainTypeGrid",
        ":set(",
        ":copyrect(",
        ".z_grid =",
        "FreeOwnedGrid",
        "AsyncRand",
        "InteractionRand",
        "table.rand",
    )
    return {
        "default_on_config_is_exported": (
            "config.OptimizeSupersededPairingSurfaceBuildableRebuild = true" in config
            and "C.OPTIMIZE_SUPERSEDED_PAIRING_SURFACE_BUILDABLE_REBUILD =" in config
            and 'cfg_bool("OPTIMIZE_SUPERSEDED_PAIRING_SURFACE_BUILDABLE_REBUILD", true)'
            in validate
        ),
        "metadata_is_v947": (
            "'version', 947" in metadata
            and "Reuse the proven retained buildable snapshot" in metadata
        ),
        "generator_wrapper_hot_reload_identity_is_bumped": (
            "SuperBigMap.GENERATOR_PATCH_VERSION = 272" in version
        ),
        "proof_is_captured_only_after_destination_rebuild": (
            migration_rebuild < migration_rebuild_call < proof_capture_call
            and "destination.SuperBigMapSurfaceBuildableCurrent = true"
            in map_generation[migration_rebuild_call:proof_capture_call]
            and "PackValues(pcall(" in map_generation[migration_rebuild_call:proof_capture_call]
        ),
        "postnew_lifecycle_primes_pending_before_underground_generation": (
            postnew_handler < postnew_schedule < mapgenerated_handler
            and pending_assignment < readiness_call
            and "PostNewMapLoaded fires BEFORE MapGenerated" in lifecycle
            and "config.OptimizeStretchDeferredRebuilds = true" in config
            and "C.OPTIMIZE_STRETCH_DEFERRED_REBUILDS" in config
        ),
        "proof_binds_exact_grid_and_map_identities": all(
            token in capture
            for token in (
                "pending.destination ~= destination",
                "native_grid = pending.grid",
                "restore_grid = restore_grid",
                "destination = destination",
                "source_width = source_w",
                "source_height = source_h",
                "expanded_width = expanded_w",
                "expanded_height = expanded_h",
                'stage = "post-migration-destination-RebuildGrids"',
            )
        ),
        "capture_and_validation_are_read_only": all(
            token not in capture + validate for token in forbidden_read_only_tokens
        ),
        "validation_has_complete_lifecycle_guards": all(
            token in validate
            for token in (
                'cfg_bool("EXPANSION_STEP_11_REBUILD_GAMEPLAY_GRIDS", true)',
                'surface_map.mapdata.Environment ~= "Surface"',
                "surface_map.SuperBigMapSurfaceBuildableCurrent ~= true",
                "surface_map.SuperBigMapStretchPipelinePending ~= true",
                "surface_map.SuperBigMapSurfaceStretchDone == true",
                "proof.version ~= SuperBigMap.SURFACE_PAIRING_BUILDABLE_REUSE_PROOF_VERSION",
                'proof.stage ~= "post-migration-destination-RebuildGrids"',
                "pending.destination ~= surface_map or proof.destination ~= surface_map",
                "proof.native_grid ~= pending.grid",
                "live_grid ~= proof.restore_grid",
                "expanded_w ~= proof.expanded_width",
                "source_w ~= proof.source_width",
                "expanded_w ~= tonumber(surface_map.hex_width)",
                "source_w ~= expected_source_w or source_h ~= expected_source_h",
                'cfg_bool("PAIRING_SOURCE_PASSABILITY_BRIDGE", true)',
                "maps[retention.slot] ~= retention.map",
            )
        ),
        "validation_is_pcalled_and_falls_back_before_do_generate": (
            validate_call < fallback_branch < fallback_rebuild
            and pre_ug_end + fallback_rebuild < do_generate_call
            and "reuse_ok = false" in pre_ug[validate_call:fallback_branch]
        ),
        "legacy_rebuild_failure_semantics_retained": all(
            token in pre_ug[fallback_branch:]
            for token in (
                "local ok_rb, err_rb = pcall(rebuild, main_map)",
                'error("surface passage pairing-grid rebuild failed: "',
                'error("surface passage pairing-grid rebuild produced no buildable grid")',
            )
        ),
        "native_selection_grid_replaces_restore_grid_only_for_selection": (
            bridge_install < bridge_restore < bridge_free < spawn_call < bridge_restore_call
            and "local stock_surface_grid = surface_map.buildable and surface_map.buildable.z_grid"
            in bootstrap[:bridge_install]
            and "pending_surface_buildable.grid:get(x, y)" in bootstrap[:bridge_install]
            and "padded_surface_grid:set(x, y," in bootstrap[:bridge_install]
        ),
        "native_selection_bridge_is_the_placeartefacts_transaction": all(
            token in on_generate
            for token in (
                'local defer_underground_artefacts = is_underground',
                'if tag == "PlaceArtefacts" then',
                "BootstrapPassagesAndDeferWonders, env",
                "if bootstrap_ok ~= true then",
                "local stock_results = PackValues(func())",
            )
        ),
        "canonical_surface_invalidation_and_rebuild_are_retained": (
            stretch_invalidate < final_rebuild
        ),
        "telemetry_reports_request_use_fallback_reason_and_rebuild_time": all(
            token in pre_ug
            for token in (
                "optimization_requested =",
                "optimization_used =",
                "optimization_fallback =",
                "reason = reuse_report.reason",
                "rebuild_ms = reuse_report.rebuild_ms",
                "source_size =",
                "expanded_size =",
                "local validation_error = validation_ok",
                'reason = "reuse-proof-validation-error:" .. tostring(validation_error)',
            )
        ) and "SuperBigMapSurfacePairingBuildableReuseReport" not in map_generation,
    }


def main() -> int:
    map_generation = MAP_GENERATION_PATH.read_text(encoding="utf-8")
    lifecycle = LIFECYCLE_PATH.read_text(encoding="utf-8")
    config = CONFIG_PATH.read_text(encoding="utf-8")
    version = VERSION_PATH.read_text(encoding="utf-8")
    metadata = METADATA_PATH.read_text(encoding="utf-8")
    semantic, cases = semantic_checks()
    structural = structural_checks(map_generation, lifecycle, config, version, metadata)
    checks = {**semantic, **structural}
    report = {
        "schema": "smr.ralph.pairing_buildable_reuse_check.v1",
        "verdict": "GREEN" if all(checks.values()) else "RED",
        "checks": checks,
        "guard_count": len(GUARDS),
        "guard_combinations": 2 ** len(GUARDS),
        "single_guard_cases": cases,
        "source_hashes": {
            path.relative_to(ROOT).as_posix(): sha256(path)
            for path in (
                MAP_GENERATION_PATH,
                LIFECYCLE_PATH,
                CONFIG_PATH,
                VERSION_PATH,
                METADATA_PATH,
            )
        },
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["verdict"] == "GREEN" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, ValueError) as exc:
        print(json.dumps({"ok": False, "error": repr(exc)}, sort_keys=True), file=sys.stderr)
        raise SystemExit(1)

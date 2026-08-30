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
PERSISTED_REENTRY_ORACLE = (ROOT / "_ralph" / "tools"
                            / "lazy_persisted_state_reentry_oracle.lua")
CAPSULE_RELEASE_REENTRY_ORACLE = (ROOT / "_ralph" / "tools"
                                  / "lazy_capsule_release_reentry_oracle.lua")
PUBLISHED_CAPSULE_CERTIFICATE_ORACLE = (ROOT / "_ralph" / "tools"
                                        / "lazy_published_capsule_certificate_oracle.lua")
VALIDATION_Z_CLONE_ORACLE = (ROOT / "_ralph" / "tools"
                             / "v985_validation_z_clone_oracle.lua")
MATERIALIZATION_REENTRY_ORACLE = (ROOT / "_ralph" / "tools"
                                  / "lazy_materialization_reentry_oracle.lua")
OPTIMIZATION_TRACE_CHECK = (ROOT / "_ralph" / "tools"
                            / "check_v975_optimization_trace.py")
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
    owned_start = generation.index(
        "function Lazy.OwnedSurfaceGenerationInFlight(surface, descriptor, report)")
    owned_end = generation.index("-- Ralph-only, process-local optimization trace.", owned_start)
    owned_guard = generation[owned_start:owned_end]
    phase_start = owned_guard.index(
        'if descriptor.state == "suppressed-awaiting-surface-capsules" then')
    common_guard = owned_guard[:phase_start]
    start = terrain.index("-- v972 lazy-underground pad reservation")
    end = terrain.index("-- If a required new core", start)
    plan = terrain[start:end]
    oracle_run = subprocess.run([sys.executable, str(ORACLE)], cwd=ROOT,
                                capture_output=True, text=True, timeout=30, check=False)
    false_global_run = subprocess.run([str(LUA53_RUN), str(FALSE_GLOBAL_ORACLE)], cwd=ROOT,
                                      capture_output=True, text=True, timeout=30, check=False)
    persisted_reentry_run = subprocess.run(
        [str(LUA53_RUN), str(PERSISTED_REENTRY_ORACLE)], cwd=ROOT,
        capture_output=True, text=True, timeout=30, check=False)
    capsule_release_reentry_run = subprocess.run(
        [str(LUA53_RUN), str(CAPSULE_RELEASE_REENTRY_ORACLE)], cwd=ROOT,
        capture_output=True, text=True, timeout=30, check=False)
    published_capsule_certificate_run = subprocess.run(
        [str(LUA53_RUN), str(PUBLISHED_CAPSULE_CERTIFICATE_ORACLE)], cwd=ROOT,
        capture_output=True, text=True, timeout=30, check=False)
    validation_z_clone_run = subprocess.run(
        [str(LUA53_RUN), str(VALIDATION_Z_CLONE_ORACLE)], cwd=ROOT,
        capture_output=True, text=True, timeout=30, check=False)
    materialization_reentry_run = subprocess.run(
        [str(LUA53_RUN), str(MATERIALIZATION_REENTRY_ORACLE)], cwd=ROOT,
        capture_output=True, text=True, timeout=30, check=False)
    optimization_trace_run = subprocess.run(
        [sys.executable, str(OPTIMIZATION_TRACE_CHECK)], cwd=ROOT,
        capture_output=True, text=True, timeout=30, check=False)
    try:
        oracle = json.loads(oracle_run.stdout)
    except json.JSONDecodeError:
        oracle = {"ok": False, "error": oracle_run.stderr or oracle_run.stdout}
    compile_results = {}
    engine_probe = ENGINE_PROBE.read_text(encoding="utf-8")
    for path in (CONFIG, TERRAIN, GENERATION, DEPOSITS, VERSION, METADATA, ENGINE_PROBE,
                 FALSE_GLOBAL_ORACLE, PERSISTED_REENTRY_ORACLE,
                 CAPSULE_RELEASE_REENTRY_ORACLE, PUBLISHED_CAPSULE_CERTIFICATE_ORACLE,
                 VALIDATION_Z_CLONE_ORACLE, MATERIALIZATION_REENTRY_ORACLE):
        result = subprocess.run([str(LUA53), "-p", str(path)], cwd=ROOT,
                                capture_output=True, text=True, timeout=30, check=False)
        compile_results[path.relative_to(ROOT).as_posix()] = result.returncode == 0
    checks = {
        "metadata_v990_truthfully_retains_v972": "'version', 990," in metadata
            and "materialization capability" in metadata
            and "target-domain passage-pad certification" in metadata,
        "generator_identity_v296": "SuperBigMap.GENERATOR_PATCH_VERSION = 296" in version,
        "v987_default_off_safe_optimization_trace_gate_green": (
            optimization_trace_run.returncode == 0
            and '"ok": true' in optimization_trace_run.stdout),
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
        "owned_live_rebuild_reentry_is_distinct_from_loaded_incomplete_state": (
            persisted_reentry_run.returncode == 0
            and "ok=true" in persisted_reentry_run.stdout
            and "pre_pipeline_reentry_exact=true" in persisted_reentry_run.stdout
            and "first_reentry_exact=true" in persisted_reentry_run.stdout
            and "closing_reentry_exact=true" in persisted_reentry_run.stdout
            and "nil_sentinels_all_phases_accepted=true" in persisted_reentry_run.stdout
            and "false_sentinels_all_phases_accepted=true" in persisted_reentry_run.stdout
            and "real_underground_map_rejected=true" in persisted_reentry_run.stdout
            and "occupied_maps_slot_rejected=true" in persisted_reentry_run.stdout
            and "pre_nil_and_false_cover_accepted=true" in persisted_reentry_run.stdout
            and "pre_visibility_not_gated=true" in persisted_reentry_run.stdout
            and "pre_true_cover_rejected=true" in persisted_reentry_run.stdout
            and "pre_without_awaiting_rejected=true" in persisted_reentry_run.stdout
            and "zero_tuple_rejected=true" in persisted_reentry_run.stdout
            and "canonical_coverless_all_phases_rejected=true" in persisted_reentry_run.stdout
            and "canonical_hidden_all_phases_rejected=true" in persisted_reentry_run.stdout
            and "loaded_incomplete_rejected=true" in persisted_reentry_run.stdout
            and "ownerless_rejected=true" in persisted_reentry_run.stdout
            and "invalid_suppressed_phase_mixtures_rejected=true" in persisted_reentry_run.stdout
            and "invalid_suppressed_phase_mixture_cases=6" in persisted_reentry_run.stdout
            and "invalid_closing_phase_mixtures_rejected=true" in persisted_reentry_run.stdout
            and "invalid_closing_phase_mixture_cases=7" in persisted_reentry_run.stdout
            and "pre_done_or_error_rejected=true" in persisted_reentry_run.stdout
            and "exact_observed_phase_sequence=true" in persisted_reentry_run.stdout
            and ("observed_phase_sequence=pre-surface-pipeline>"
                 "closing-canonical-rebuild") in persisted_reentry_run.stdout
            and "observed_phase_count=2" in persisted_reentry_run.stdout
            and "failed_guard_does_not_append_sequence=true" in persisted_reentry_run.stdout
            and all(token in generation for token in (
                "LIVE_SURFACE_GENERATION_TRANSACTIONS = setmetatable({}, { __mode = \"k\" })",
                "function Lazy.OwnedSurfaceGenerationInFlight(surface, descriptor, report)",
                'local function failed(invariant, actual)',
                'owner.descriptor ~= descriptor',
                'owner.report ~= report',
                "surface_loading_ref_maps[surface] ~= true",
                'if Global("UndergroundMap") then return failed("underground_map_absent", false) end',
                'type(maps) == "table" and maps[descriptor.map_slot] then',
                "lazy_underground_engine_restore_tokens",
                'descriptor.state == "suppressed-awaiting-surface-capsules"',
                'if pipeline_pending and not stretch_scheduled and not post_scheduled then',
                'surface.SuperBigMapSurfaceStretchAwaitingReadiness ~= true',
                'return failed("pre_surface_awaiting_readiness",',
                'if pipeline_pending and stretch_scheduled and post_scheduled then',
                'surface_loading_ref_maps[surface] == true',
                'return failed("pre_surface_loading_cover", true)',
                'canonical_loading_cover("first-canonical-rebuild")',
                '"pre-surface-pipeline"',
                '"first-canonical-rebuild"',
                '"suppressed_phase_markers"',
                'descriptor.state == "surface-capsules-published-awaiting-final-grid"',
                '"closing_phase_markers"',
                '"closing-canonical-rebuild"',
                'canonical_loading_cover("closing-canonical-rebuild")',
                "Lazy.OwnedSurfaceGenerationInFlight(surface, descriptor, report)",
                "report.persisted_state_live_reentry_allowed = true",
                "report.persisted_state_live_reentry_count =",
                'report.persisted_state_live_reentry_phase_sequence = ""',
                'phase_sequence .. ">" .. live_phase',
                '"lazy persisted-state guard failed: "',
                '"persisted incomplete lazy state: "'))
            and generation.count("Lazy.LIVE_SURFACE_GENERATION_TRANSACTIONS[surface] = {") == 1
            and generation.count("Lazy.LIVE_SURFACE_GENERATION_TRANSACTIONS[surface] = nil") >= 2),
        "owned_live_materialization_reentry_is_distinct_and_monotonic": (
            materialization_reentry_run.returncode == 0
            and all(token in materialization_reentry_run.stdout for token in (
                "ok=true", "exact_phase_history=true",
                "pre_phase=materialization-pre-publication",
                "map_load_phase=materialization-native-map-load",
                "callback_phase=materialization-native-callback",
                "pipeline_phase=materialization-deferred-pipeline",
                "loaded_ownerless=true", "owner_mismatch=true", "pending_restore=true",
                "wrong_map_identity=true", "invalid_generation=true",
                "invalid_validation_z=true", "callback_block_never_overwritten=true",
                "success_commits_and_clears_owner=true"))
            and all(token in generation for token in (
                'LIVE_MATERIALIZATION_TRANSACTIONS = setmetatable({}, { __mode = "k" })',
                "function Lazy.OwnedMaterializationInFlight(surface, descriptor, report)",
                "report.persisted_state_materialization_reentry_allowed = true",
                'descriptor.state == "generating"',
                'descriptor.state ~= "blocked"',
                'materialization ownership lost before publication'))),
        "capsule_contract_published_before_reentrant_release_and_failure_is_monotonic": (
            capsule_release_reentry_run.returncode == 0
            and "ok=true" in capsule_release_reentry_run.stdout
            and "closing_reentry_before_release_passed=true" in capsule_release_reentry_run.stdout
            and "retention_certified_only_after_success=true" in capsule_release_reentry_run.stdout
            and "release_failure_blocked=true" in capsule_release_reentry_run.stdout
            and "release_failure_not_certified=true" in capsule_release_reentry_run.stdout
            and "callback_block_preserved=true" in capsule_release_reentry_run.stdout
            and "callback_block_not_overwritten=true" in capsule_release_reentry_run.stdout
            and "blocked_reason_preserved=true" in capsule_release_reentry_run.stdout
            and "publication_never_regressed=true" in capsule_release_reentry_run.stdout
            and "legacy_release_before_publication_rejected=true"
                in capsule_release_reentry_run.stdout
            and ordered(generation,
                'if not created or #created ~= 2 then return Lazy.MarkBlocked',
                'descriptor.state = "surface-capsules-published-awaiting-final-grid"',
                'report.capsules_published = #created',
                'report.deterministic_repeat = true',
                'report.final_grid_revalidation = false',
                'report.native_source_retention_released_before_t1 = false',
                'local release_ok = ReleaseRetainedNativeSourceMap(surface',
                'if descriptor.state == "blocked" or descriptor.failure_sticky == true then',
                'if not release_ok then',
                'report.native_source_retention_released_before_t1 = true')
            and generation[
                generation.index('local release_ok = ReleaseRetainedNativeSourceMap(surface'):
                generation.index('function Lazy.PrepareImplementationCapsulesSafe')
            ].count('descriptor.state = "surface-capsules-published-awaiting-final-grid"') == 0
            and generation.count(
                'report.native_source_retention_released_before_t1 = true') == 1),
        "published_capsule_certificate_rejects_drift_without_self_obstruction_false_block": (
            published_capsule_certificate_run.returncode == 0
            and "ok=true" in published_capsule_certificate_run.stdout
            and "healthy_exact_certificate_accepted=true"
                in published_capsule_certificate_run.stdout
            and "self_obstructed_is_valid_placement_not_called=true"
                in published_capsule_certificate_run.stdout
            and "moved_passage_rejected=true" in published_capsule_certificate_run.stdout
            and "duplicate_passage_rejected=true" in published_capsule_certificate_run.stdout
            and "linked_passage_rejected=true" in published_capsule_certificate_run.stdout
            and "invalid_passage_rejected=true" in published_capsule_certificate_run.stdout
            and "missing_marker_rejected=true" in published_capsule_certificate_run.stdout
            and "duplicate_marker_rejected=true" in published_capsule_certificate_run.stdout
            and "missing_sign_rejected=true" in published_capsule_certificate_run.stdout
            and "duplicate_sign_rejected=true" in published_capsule_certificate_run.stdout
            and "missing_planner_certificate_rejected=true"
                in published_capsule_certificate_run.stdout
            and "missing_closing_rebuild_certificate_rejected=true"
                in published_capsule_certificate_run.stdout
            and "missing_validation_z_rejected=true"
                in published_capsule_certificate_run.stdout
            and "missing_validation_z_count_rejected=true"
                in published_capsule_certificate_run.stdout
            and "wrong_validation_z_digest_rejected=true"
                in published_capsule_certificate_run.stdout
            and "invalid_validation_z_range_rejected=true"
                in published_capsule_certificate_run.stdout
            and "old_planner_schema_rejected=true"
                in published_capsule_certificate_run.stdout
            and all(token in generation for token in (
                "function Lazy.ValidatePublishedCapsuleCertificate(surface, descriptor, report)",
                "report.main_depth_zero_validation_exact == true",
                "report.replay_depth_zero_validation_exact == true",
                "report.fresh_grid_closing_rebuild_complete == true",
                "report.canonical_rebuilds_during_capsule_prepare) == 2",
                "capsule.validation_z = z",
                "report.validation_z_certificates = report.validation_z_certificates + 1",
                "CAPSULE_PLANNER_VERSION = 7",
                "descriptor.validation_z_digest = plan_report.validation_z_digest",
                "validation_z ~= math.floor(validation_z)",
                'return false, "published capsule validation-Z digest is invalid"',
                'type(capsule.validation_z) ~= "number"',
                "tonumber(report.validation_z_certificates) == 2",
                "counts[index] = (counts[index] or 0) + 1",
                "if counts[index] ~= 1 or not object then",
                'return nil, "surface capsule " .. tostring(index) .. " angle changed"',
                'local is_valid = Global("IsValid")',
                '"UndergroundTunnelMarker", function(marker)',
                '"SurfaceUndergroundTunnelSign", function(sign)',
                "if #markers ~= 1 then", "if #signs ~= 1 then",
                "marker.tunnel_sign ~= sign or sign.tunnel_marker ~= marker"))
            and "IsValidPlacement" not in generation[
                generation.index("function Lazy.ValidatePublishedCapsules(surface, descriptor)"):
                generation.index("function Lazy.Capture(surface, pending, next_map)")
            ]),
        "validation_z_private_clone_contract_oracle_green": (
            validation_z_clone_run.returncode == 0
            and "ok=true" in validation_z_clone_run.stdout
            and "live_final_grid_rejects_self_occupancy=true"
                in validation_z_clone_run.stdout
            and "clone_accepts_exact_certified_pad=true" in validation_z_clone_run.stdout
            and "only_own_family_ignored=true" in validation_z_clone_run.stdout
            and "unrelated_blocker_rejected=true" in validation_z_clone_run.stdout
            and "wrong_validation_z_rejected=true" in validation_z_clone_run.stdout
            and "live_grid_unchanged=true" in validation_z_clone_run.stdout
            and "only_exact_footprint_restored=true" in validation_z_clone_run.stdout
            and "private_clone_freed=true" in validation_z_clone_run.stdout),
        "pipeline_markers_are_phase_specific_not_common_guards": (
            "SuperBigMapStretchPipelinePending" not in common_guard
            and "SuperBigMapSurfaceStretchScheduled" not in common_guard
            and "SuperBigMapSurfacePostPipelineRevalidationScheduled" not in common_guard
            and owned_guard.count("if pipeline_pending and not stretch_scheduled"
                                  " and not post_scheduled then") == 1
            and owned_guard.count("if pipeline_pending and stretch_scheduled"
                                  " and post_scheduled then") == 1
            and owned_guard.count('failed("suppressed_phase_markers"') == 1
            and owned_guard.count('failed("closing_phase_markers"') == 1),
        "false_engine_map_sentinels_are_absent_but_real_maps_fail_closed": (
            'Global("UndergroundMap") ~= nil' not in common_guard
            and 'maps[descriptor.map_slot] ~= nil' not in common_guard
            and owned_guard.count(
                'if Global("UndergroundMap") then return failed("underground_map_absent", false) end') == 1
            and owned_guard.count(
                'if type(maps) == "table" and maps[descriptor.map_slot] then') == 1),
        "surface_loading_cover_is_phase_specific": (
            'return failed("loading_cover", false)' not in owned_guard
            and owned_guard.count('local function canonical_loading_cover(phase)') == 1
            and owned_guard.count('return failed("canonical_loading_cover", false)') == 1
            and owned_guard.count('return failed("canonical_loading_visible", visible_now)') == 1
            and owned_guard.count('return failed("pre_surface_loading_cover", true)') == 1
            and owned_guard.count('return failed("pre_surface_awaiting_readiness",') == 1
            and owned_guard.count('canonical_loading_cover("first-canonical-rebuild")') == 1
            and owned_guard.count('canonical_loading_cover("closing-canonical-rebuild")') == 1
            and 'ExpansionLoadingVisible' not in owned_guard[
                owned_guard.index('if pipeline_pending and not stretch_scheduled'):
                owned_guard.index('if pipeline_pending and stretch_scheduled')]),
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
                "candidate.validation_z_certificates == publication_calls",
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
        "persisted_state_reentry_oracle": persisted_reentry_run.stdout.strip(),
        "capsule_release_reentry_oracle": capsule_release_reentry_run.stdout.strip(),
        "published_capsule_certificate_oracle":
            published_capsule_certificate_run.stdout.strip(),
        "optimization_trace_check_returncode": optimization_trace_run.returncode,
    }, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())

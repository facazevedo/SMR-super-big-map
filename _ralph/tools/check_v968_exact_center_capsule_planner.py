#!/usr/bin/env python3
"""Static and executable gate for v968's depth-zero lazy-UG capsule planner."""

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
ORACLE = ROOT / "_ralph" / "tools" / "v968_exact_center_capsule_planner_oracle.py"
ENGINE_PROBE = ROOT / "_ralph" / "tools" / "v968_exact_center_engine_probe.lua"
LUA53 = (
    ROOT / "_ralph" / "tmp" / ".tmp_surface_loading_rough_iter109_lua53"
    / "lua-5.3.6" / "src" / "luac.exe"
)


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ordered(text: str, *tokens: str) -> bool:
    cursor = -1
    for token in tokens:
        cursor = text.find(token, cursor + 1)
        if cursor < 0:
            return False
    return True


def model_probe_verdict(*, surface_ready: bool = True, apis_ready: bool = True,
                        pair_found: bool = True, contrary_tuples: int = 0,
                        native_failures: int = 0, output_mismatches: int = 0,
                        invalid_center_rejections: int = 1,
                        valid_neighbour_accepts: int = 1) -> dict[str, object]:
    """Independent acceptance model for every detached-probe fail-closed input."""
    failures: list[str] = []
    if not surface_ready:
        failures.append("surface")
    if not apis_ready:
        failures.append("apis")
    if not pair_found:
        failures.append("pair")
    if contrary_tuples:
        failures.append("contrary")
    if native_failures:
        failures.append("native")
    if output_mismatches:
        failures.append("mismatch")
    if invalid_center_rejections != 1:
        failures.append("invalid-center")
    if valid_neighbour_accepts != 1:
        failures.append("valid-neighbour")
    return {"ok": not failures, "failures": failures}


def main() -> int:
    config = CONFIG.read_text(encoding="utf-8")
    generation = GENERATION.read_text(encoding="utf-8")
    version = VERSION.read_text(encoding="utf-8")
    metadata = METADATA.read_text(encoding="utf-8")
    if "'version', 969," in metadata or "'version', 970," in metadata:
        successor = ROOT / "_ralph" / "tools" / "check_v969_fresh_grid_capsule_publication.py"
        forwarded = subprocess.run(
            [sys.executable, str(successor)], cwd=ROOT, capture_output=True, text=True,
            timeout=30, check=False,
        )
        try:
            payload = json.loads(forwarded.stdout)
        except json.JSONDecodeError:
            payload = {"ok": False, "error": forwarded.stderr or forwarded.stdout}
        ok = forwarded.returncode == 0 and payload.get("ok") is True
        print(json.dumps({
            "schema": "smr.ralph.v968.exact-center-forward-gate.v1",
            "ok": ok,
            "successor": "v969+ fresh-grid capsule publication",
            "successor_result": payload,
        }, indent=2, sort_keys=True))
        return 0 if ok else 1
    engine_probe = ENGINE_PROBE.read_text(encoding="utf-8")
    planner_start = generation.index("function Lazy.BuildCapsulePlanMode")
    planner_end = generation.index("function Lazy.StateSurface", planner_start)
    planner = generation[planner_start:planner_end]
    enabled_start = planner.index("if Lazy.BOUNDED_CAPSULE_PLANNER == true then")
    enabled_end = planner.index("\n\telse\n", enabled_start)
    enabled = planner[enabled_start:enabled_end]
    prepare_start = generation.index("function Lazy.PrepareImplementationCapsules(")
    prepare_end = generation.index("function Lazy.ValidatePublishedCapsules", prepare_start)
    prepare = generation[prepare_start:prepare_end]
    finalize_start = generation.index("function Lazy.FinalizeImplementation")
    finalize_end = generation.index("function Lazy.FinalizePlan", finalize_start)
    finalize = generation[finalize_start:finalize_end]
    schedule_start = generation.index("SuperBigMapSurfacePostPipelineRevalidationScheduled")
    schedule_end = generation.index("local function SyncMapDataToGrids", schedule_start)
    schedule = generation[schedule_start:schedule_end]

    oracle_run = subprocess.run(
        [sys.executable, str(ORACLE)], cwd=ROOT, capture_output=True, text=True,
        timeout=30, check=False,
    )
    try:
        oracle = json.loads(oracle_run.stdout)
    except json.JSONDecodeError:
        oracle = {"ok": False, "error": oracle_run.stderr or oracle_run.stdout}

    probe_model = {
        "happy": model_probe_verdict(),
        "surface_unavailable": model_probe_verdict(surface_ready=False),
        "api_unavailable": model_probe_verdict(apis_ready=False),
        "no_pair": model_probe_verdict(pair_found=False),
        "contrary_tuple": model_probe_verdict(contrary_tuples=1),
        "native_call_failure": model_probe_verdict(native_failures=1),
        "output_mismatch": model_probe_verdict(output_mismatches=1),
        "invalid_start_accepted": model_probe_verdict(
            output_mismatches=1, invalid_center_rejections=0),
        "valid_neighbour_rejected": model_probe_verdict(
            output_mismatches=1, valid_neighbour_accepts=0),
    }
    probe_model_green = probe_model["happy"]["ok"] is True and all(
        case["ok"] is False for name, case in probe_model.items() if name != "happy"
    )
    result_start = engine_probe.index("local result = {")
    result_end = engine_probe.index("\n}\n\nreturn result", result_start) + 2
    result_block = engine_probe[result_start:result_end]
    flat_result_fields = (
        result_block.count("{") == 1 and result_block.count("}") == 1
        and all(token in result_block for token in (
            'schema = "smr.ralph.v968.exact-center-engine-probe.v3"',
            "ok = ok",
            "acceptance_failure_count = #acceptance_failures",
            'acceptance_failures = table.concat(acceptance_failures, "|")',
            "surface_map_count = counts.surface_maps",
            "exact_center_call_count = counts.exact_center_calls",
            "native_call_failure_count = counts.native_call_failures",
            "contrary_tuple_count = contrary_tuple_count",
            "output_mismatch_count = counts.output_mismatches",
            "controlled_start_rejection_count = counts.controlled_start_rejections",
            "controlled_neighbour_accept_count = counts.controlled_neighbour_accepts",
            "pair_found = pair ~= nil",
            "probe_radius_cap = 8",
        ))
    )

    compile_results: dict[str, bool] = {}
    for path in (CONFIG, GENERATION, VERSION, METADATA, ENGINE_PROBE):
        result = subprocess.run(
            [str(LUA53), "-p", str(path)], cwd=ROOT, capture_output=True,
            text=True, timeout=30, check=False,
        ) if LUA53.is_file() else None
        compile_results[path.relative_to(ROOT).as_posix()] = bool(
            result is not None and result.returncode == 0
        )

    checks = {
        "metadata_v968": "'version', 968," in metadata,
        "metadata_describes_depth_zero_selection_and_fresh_publication_checks": all(
            token in metadata for token in (
                "depth-0 exact-center validation per lazy-underground capsule candidate",
                "freshly validate both selected centers before publication",
            )
        ) and "two authoritative stock searches" not in metadata,
        "generator_patch_identity_retained_v275": (
            "SuperBigMap.GENERATOR_PATCH_VERSION = 275" in version
        ),
        "implementation_remains_default_off_and_bounded_subflag_default_on": all(
            token in config for token in (
                "config.LazyUndergroundSourceGeneration = false",
                "config.LazyUndergroundBoundedCapsulePlanner = true",
                "C.LAZY_UNDERGROUND_BOUNDED_CAPSULE_PLANNER",
            )
        ),
        "pinned_lua_5_3_6_compiles": all(compile_results.values()),
        "detached_real_engine_probe_returns_only_flat_fail_closed_scalars": (
            "assert(" not in engine_probe and "error(" not in engine_probe
            and "g_SmrV968" not in engine_probe and "rawset(" not in engine_probe
            and "AsyncStringToFile" not in engine_probe and "StringToFile" not in engine_probe
            and "io.open" not in engine_probe and "io.write" not in engine_probe
            and ordered(engine_probe,
                "local acceptance_failures = {}",
                "local counts = {",
                "local contrary_tuple_count = 0",
                "local function compute_ok()",
                "local ok = compute_ok()",
                "local result = {",
                "return result",
            )
            and flat_result_fields
            and all(token in engine_probe for token in (
                "initialized Surface grids unavailable",
                "return validate_shape(shape, point_fn(x, y), angle, shape_pos_filter) ~= true",
                "controlled_continue, 0)",
                "acceptance_failure(\"no adjacent valid/invalid probe pair in radius 8\")",
                "acceptance_failure(\"contrary native tuple observed\")",
                "acceptance_failure(\"controlled native output mismatch\")",
                "probe_radius_cap = 8",
            ))
        ),
        "detached_probe_fail_closed_semantic_model_is_green": probe_model_green,
        "offline_corpus_oracle_green": (
            oracle_run.returncode == 0 and oracle.get("ok") is True
            and oracle.get("limits", {}).get("max_depth") == 0
            and oracle.get("limits", {}).get("two_selection_plans_shape_check_cap") == 1024
            and oracle.get("limits", {}).get("publication_validation_shape_checks") == 2
            and oracle.get("limits", {}).get("unbounded_calls") == 0
            and oracle.get("checks", {}).get(
                "invalid_center_never_moves_to_valid_neighbour") is True
            and oracle.get("checks", {}).get("fresh_corpora_select_early") is True
            and oracle.get("checks", {}).get(
                "suppression_ownership_survives_stale_and_fresh_plan_merges") is True
            and oracle.get("checks", {}).get(
                "successful_publication_finalizes_lazy_not_eager") is True
            and oracle.get("checks", {}).get(
                "stale_retry_double_rebuild_failure_is_sticky_blocked") is True
        ),
        "planner_telemetry_cannot_overwrite_lifecycle_ownership": (
            "planner_requested = true" in planner
            and "planner_used = false" in planner
            and "report.planner_used = true" in planner
            and all(token not in planner for token in (
                "\n\t\trequested = true,", "\n\t\tused = false,", "\n\t\tshadow_only = true,",
                "\n\t\tliteral_v964_continues = true,", "\n\t\tsuppression_used = false,",
                "report.used = true",
            ))
            and "report.used = plan_report.planner_used == true" in generation
        ),
        "implementation_finalizer_keeps_suppressed_publication_on_lazy_branch": ordered(
            finalize,
            'report.literal_v964_continues == true and report.suppression_used ~= true',
            'if descriptor.state == "blocked" then',
            "report.enablement_ready = report.route_presence_complete == true",
        ),
        "stock_native_abi_is_strict_depth_zero_exact_center": (
            "CAPSULE_PLANNER_VERSION = 3" in generation
            and all(token in enabled for token in (
            'local hex_find_buildable = Global("HexGridFindBuildable")',
            "hex_find_buildable(q, r, object_grid, buildable.z_grid,",
            "unbuildable_z, continue_check, report.bounded_max_depth)",
            "if bq == nil and br == nil and depth == nil then return nil end",
            "depth ~= 0",
            "or bq ~= q or br ~= r",
            'error("depth-zero HexGridFindBuildable returned a contrary ABI tuple")',
            ))
            and "bounded_max_depth = 0" in planner
        ),
        "stock_shape_predicate_order_is_literal": ordered(
            planner,
            "original_z = original_z or z",
            "if z == unbuildable_z or z ~= original_z then return false end",
            "local obstructions = object_grid:GetBuildObstructions(q, r)",
            "if #obstructions > 0 then return false end",
            "if deposit_filter and not deposit_filter(q, r) then return false end",
            "local validated = validate_shape(shape, point_fn(x, y), angle, shape_pos_filter)",
            "return validated ~= true",
        ),
        "candidate_stream_and_attempt_budget_are_retained": ordered(
            planner,
            "local max_attempts = 512",
            "candidate_x = margin_x + (next_private() % span_x)",
            "candidate_y = margin_y + (next_private() % span_y)",
            "angle = (next_private() % 6) * 3600",
        ) and "report.private_draws = report.attempts * 3" in planner,
        "margin_spacing_and_marker_exclusions_remain": all(token in planner for token in (
            '"TerrainDepositMarker"',
            '"PrefabFeatureMarker"',
            "position:Dist2D(marker) <= marker:GetObstructionRadius()",
            "position:Dist2D(marker) <= marker.FeatureRadius",
            "x < margin_x or x > world_width - margin_x",
            "dx * dx + dy * dy < minimum_distance2",
        )),
        "publication_plan_gets_two_fresh_depth_zero_same_center_checks": all(
            token in planner + prepare for token in (
                "publication_validation_calls = 0",
                "report.publication_validation_calls + 1",
                "pcall(validate_exact_center,",
                "x ~= capsule.x or y ~= capsule.y or depth ~= 0",
                "or q ~= capsule.q or r ~= capsule.r",
                "plan_report.publication_validation_calls == 2",
                "plan_report.publication_validation_exact_centers == 2",
                "report.full_search_mismatches = report.full_search_mismatches + 1",
                "report.plan_safe_for_publication = report.full_validation_complete",
            )
        ),
        "enabled_path_never_calls_unbounded_search": (
            "pcall(find_buildable" not in enabled
            and "full_search_cap = 0" in planner
            and "plan_report.full_search_calls == 0" in prepare
        ),
        "deterministic_replay_has_selection_only": (
            "function Lazy.ReplayCapsulePlan" in planner
            and "return Lazy.BuildCapsulePlanMode(surface, pending, next_map, true)" in planner
            and all(token in prepare for token in (
                "local twins, twin_report = Lazy.ReplayCapsulePlan",
                "twin_report.replay_only == true",
                "twin_report.exact_center_shape_checks == twin_report.attempts",
                "twin_report.publication_validation_calls == 0",
                "twin_report.full_search_calls == 0",
                "plan_report.plan_safe_for_publication == true",
            ))
        ),
        "saveable_descriptor_records_bounded_planner_identity": all(
            token in prepare for token in (
                "descriptor.capsule_planner_version = Lazy.CAPSULE_PLANNER_VERSION",
                "descriptor.capsule_planner_bounded = Lazy.BOUNDED_CAPSULE_PLANNER == true",
                "descriptor.capsule_planner_max_depth = plan_report.bounded_max_depth",
                "report.descriptor_primitive = Lazy.PrimitiveTree(descriptor)",
            )
        ),
        "bounded_exhaustion_is_only_retryable_before_canonical_grid": ordered(
            prepare,
            "if not capsules then",
            "plan_report.retryable_after_canonical_grid == true",
            "and not after_canonical_grid",
            'return false, "retry-after-canonical-grid", true',
            "return Lazy.MarkBlocked(surface,",
        ),
        "retry_publishes_nothing_before_first_rebuild": ordered(
            prepare,
            'return false, "retry-after-canonical-grid", true',
            "descriptor.capsules = capsules",
            "Lazy.PublishSurfaceCapsules(surface, descriptor)",
        ),
        "fresh_grid_retry_is_transactional_and_closed_by_second_rebuild": ordered(
            prepare,
            "Lazy.PrepareImplementationCapsulesSafe(surface, false)",
            "local rebuild_ok, rebuild_err = canonical_rebuild(reason)",
            "if rebuild_ok and retry_after_grid then",
            "Lazy.PrepareImplementationCapsulesSafe(surface, true)",
            'reason .. " after fresh-grid capsule publication"',
        ),
        "failed_fresh_retry_or_rebuild_is_sticky_blocked": (
            '"bounded capsule plan failed: " .. tostring(plan_report and plan_report.error)'
            in prepare
            and ordered(
                prepare,
                "if rebuild_ok ~= true then",
                'Lazy.MarkBlocked(surface, "canonical Surface grid rebuild failed:',
                "if capsule_ok ~= true then",
            )
        ),
        "both_scheduled_and_synchronous_paths_use_orchestrator": (
            schedule.count("lazy.PrepareImplementationCapsulesAroundRebuild(map,") == 2
            and "post-pipeline scheduled revalidation" in schedule
            and "post-pipeline scheduling failure fallback" in schedule
        ),
        "telemetry_has_depth_calls_substeps_retry_and_rebuild_counts": all(
            token in planner + prepare for token in (
                "bounded_search_calls",
                "bounded_search_successes",
                "bounded_search_max_returned_depth",
                "bounded_search_ms",
                "exact_center_shape_checks",
                "publication_validation_calls",
                "publication_validation_exact_centers",
                "publication_validation_depth",
                "unbounded_search_calls",
                "private_draws",
                "full_search_calls",
                "full_search_ms",
                "marker_scan_ms",
                "total_ms",
                "pre_final_attempts",
                "capsule_plan_retry_used",
                "canonical_rebuilds_during_capsule_prepare",
            )
        ),
        "literal_v966_branch_requires_explicit_subflag_disable": (
            "if Lazy.BOUNDED_CAPSULE_PLANNER == true then" in planner
            and "Literal v966 diagnostic branch" in planner
        ),
    }
    failed = sorted(name for name, ok in checks.items() if not ok)
    print(json.dumps({
        "schema": "smr.ralph.v968.exact-center-capsule-planner-check.v1",
        "ok": not failed,
        "failed": failed,
        "checks": checks,
        "compile": compile_results,
        "probe_fail_closed_model": probe_model,
        "oracle": oracle,
        "limits": {
            "private_attempts": 512,
            "native_max_depth": 0,
            "selection_checks_per_plan": 512,
            "two_selection_plans_shape_check_cap": 1024,
            "publication_validation_shape_checks": 2,
            "unbounded_calls": 0,
            "failure_policy": "retry once after canonical grids before publication; then sticky block",
        },
        "hashes": {str(path.relative_to(ROOT)).replace("\\", "/"): sha(path)
                   for path in (CONFIG, GENERATION, VERSION, METADATA, ORACLE, ENGINE_PROBE)},
    }, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())

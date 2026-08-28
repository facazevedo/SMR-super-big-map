#!/usr/bin/env python3
"""Static and executable gate for v967's bounded lazy-UG capsule planner."""

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
ORACLE = ROOT / "_ralph" / "tools" / "v967_capsule_planner_oracle.py"
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


def main() -> int:
    config = CONFIG.read_text(encoding="utf-8")
    generation = GENERATION.read_text(encoding="utf-8")
    version = VERSION.read_text(encoding="utf-8")
    metadata = METADATA.read_text(encoding="utf-8")
    planner_start = generation.index("function Lazy.BuildCapsulePlanMode")
    planner_end = generation.index("function Lazy.StateSurface", planner_start)
    planner = generation[planner_start:planner_end]
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

    compile_results: dict[str, bool] = {}
    for path in (CONFIG, GENERATION, VERSION, METADATA):
        result = subprocess.run(
            [str(LUA53), "-p", str(path)], cwd=ROOT, capture_output=True,
            text=True, timeout=30, check=False,
        ) if LUA53.is_file() else None
        compile_results[path.relative_to(ROOT).as_posix()] = bool(
            result is not None and result.returncode == 0
        )

    checks = {
        "metadata_v967": "'version', 967," in metadata,
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
        "offline_corpus_oracle_green": (
            oracle_run.returncode == 0 and oracle.get("ok") is True
            and oracle.get("limits", {}).get("max_depth") == 16
            and oracle.get("limits", {}).get("authoritative_full_calls") == 2
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
        "stock_native_abi_has_explicit_depth_cap": (
            "CAPSULE_PLANNER_VERSION = 2" in generation
            and all(token in planner for token in (
            'local hex_find_buildable = Global("HexGridFindBuildable")',
            "bounded_max_depth = 16",
            "hex_find_buildable(q, r, object_grid, buildable.z_grid,",
            "unbuildable_z, continue_check, report.bounded_max_depth)",
            ))
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
        ),
        "margin_spacing_and_marker_exclusions_remain": all(token in planner for token in (
            '"TerrainDepositMarker"',
            '"PrefabFeatureMarker"',
            "position:Dist2D(marker) <= marker:GetObstructionRadius()",
            "position:Dist2D(marker) <= marker.FeatureRadius",
            "x < margin_x or x > world_width - margin_x",
            "dx * dx + dy * dy < minimum_distance2",
        )),
        "publication_plan_gets_exactly_two_authoritative_same_center_checks": all(
            token in planner for token in (
                "full_search_cap = 2",
                "report.full_search_calls = report.full_search_calls + 1",
                "x ~= capsule.x or y ~= capsule.y",
                "report.full_search_mismatches = report.full_search_mismatches + 1",
                "report.plan_safe_for_publication = report.full_validation_complete",
            )
        ),
        "deterministic_replay_never_runs_full_search": (
            "function Lazy.ReplayCapsulePlan" in planner
            and "return Lazy.BuildCapsulePlanMode(surface, pending, next_map, true)" in planner
            and all(token in prepare for token in (
                "local twins, twin_report = Lazy.ReplayCapsulePlan",
                "twin_report.replay_only == true and twin_report.full_search_calls == 0",
                "plan_report.plan_safe_for_publication == true",
                "plan_report.full_search_calls == 2",
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
        "schema": "smr.ralph.v967.bounded-capsule-planner-check.v1",
        "ok": not failed,
        "failed": failed,
        "checks": checks,
        "compile": compile_results,
        "oracle": oracle,
        "limits": {
            "private_attempts": 512,
            "native_max_depth": 16,
            "authoritative_full_search_calls": 2,
            "replay_full_search_calls": 0,
            "failure_policy": "retry once after canonical grids before publication; then sticky block",
        },
        "hashes": {str(path.relative_to(ROOT)).replace("\\", "/"): sha(path)
                   for path in (CONFIG, GENERATION, VERSION, METADATA, ORACLE)},
    }, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())

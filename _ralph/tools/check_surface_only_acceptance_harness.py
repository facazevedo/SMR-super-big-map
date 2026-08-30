"""Offline fail-closed adversaries for the reusable Surface-only acceptance mode."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

from surface_loading_reference import (
    DEFAULT_LUAC,
    PARITY,
    REFERENCE_PROBE_SHA256,
    compile_lua,
    render_generation,
    sha256_file,
    static_verdict,
)


ROOT = Path(__file__).resolve().parents[2]
EXECUTOR = ROOT / "_ralph" / "tools" / "execute_surface_only_acceptance.ps1"
LOOP = ROOT / "_ralph" / "tools" / "invoke_surface_only_loop.ps1"
FORBIDDEN = (
    "ChangeCurrentMapSlot",
    "find_underground",
    "entering_underground",
    "no underground map was generated",
    "perform_tracked_underground_first_access.lua",
    "release_post_t1_abi_gate.lua",
)


def scalar_tuple(fields: dict[str, str]) -> str:
    """Offline mirror of the executor's fail-closed scalar tuple gate."""
    main = (
        "surface_single_flush_requested", "surface_single_flush_used", "surface_single_flush_fallback",
        "surface_single_flush_fallback_reason", "surface_single_flush_local_passability_calls",
        "surface_single_flush_buildable_calls", "surface_single_flush_height_snapshots",
        "surface_single_flush_height_mismatches", "surface_single_flush_object_family_count",
        "surface_single_flush_object_association_failures", "surface_single_flush_provenance_exact",
        "surface_single_flush_dirty_digest", "surface_single_flush_dirty_regions", "surface_single_flush_coverage_permille",
        "surface_single_flush_closing_complete", "surface_single_flush_cleanup_complete",
        "outer_passage_pad_finalization_dirty_digest", "canonical_rebuilds_during_capsule_prepare",
        "canonical_rebuild_fallbacks_during_capsule_prepare", "fresh_grid_first_rebuild_ms", "fresh_grid_main_plan_ms",
        "fresh_grid_replay_ms", "fresh_grid_publication_ms", "fresh_grid_plan_replay_publication_ms",
        "fresh_grid_closing_rebuild_ms", "fresh_grid_orchestration_total_ms", "fresh_grid_phase_order",
        "fresh_grid_expected_rebuilds", "fresh_grid_rebuild_shape_exact", "fresh_grid_first_rebuild_complete",
        "fresh_grid_closing_rebuild_complete",
    )
    helper = (
        "helper_schema", "helper_requested", "helper_used", "helper_phase", "helper_error", "helper_fallback",
        "helper_provenance_exact", "helper_dirty_digest", "helper_regions", "helper_terrain_cells",
        "helper_coverage_permille", "helper_dependency_margin", "helper_height_snapshots", "helper_height_mismatches",
        "helper_object_family_count", "helper_object_association_failures", "helper_object_containment_failures",
        "helper_passability_calls", "helper_buildable_calls", "helper_preplan_complete", "helper_closing_complete",
        "helper_cleanup_complete",
    )
    header = (
        "schema", "surface_stable_published", "post_t1_only", "pre_t1_capture_bytes", "capture_status",
        "async_rand_draw_count", "async_rand_dispatcher_restored", "tuple", "caller_fallback_reason",
        "comparison_ms", "proof_ms",
    )
    allowed = set(main + helper + header)
    if set(fields) != allowed:
        raise ValueError("missing or unknown scalar field")
    if fields["schema"] != "smr.ralph.surface_only_single_flush_scalar.v1":
        raise ValueError("scalar schema")
    if fields["helper_schema"] != "1" or fields["helper_phase"] not in {"preplan", "closing"}:
        raise ValueError("scalar helper schema/phase")
    if any(fields[name] not in {"true", "false"} for name in (
        "surface_stable_published", "post_t1_only", "async_rand_dispatcher_restored",
        "surface_single_flush_requested", "surface_single_flush_used", "surface_single_flush_fallback",
        "surface_single_flush_provenance_exact", "surface_single_flush_closing_complete",
        "surface_single_flush_cleanup_complete", "fresh_grid_rebuild_shape_exact",
        "fresh_grid_first_rebuild_complete", "fresh_grid_closing_rebuild_complete", "helper_requested",
        "helper_used", "helper_fallback", "helper_provenance_exact", "helper_preplan_complete",
        "helper_closing_complete", "helper_cleanup_complete",
    )):
        raise ValueError("scalar boolean")
    try:
        number = {name: int(fields[name]) for name in allowed if name not in {
            "schema", "capture_status", "tuple", "caller_fallback_reason", "surface_single_flush_fallback_reason",
            "fresh_grid_phase_order", "helper_phase", "helper_error"
        } and fields[name] not in {"true", "false"}}
    except ValueError as exc:
        raise ValueError("scalar integer") from exc
    if any(value < 0 for value in number.values()):
        raise ValueError("scalar negative")
    if (fields["surface_stable_published"], fields["post_t1_only"], fields["capture_status"],
            number["pre_t1_capture_bytes"], fields["async_rand_dispatcher_restored"], number["async_rand_draw_count"]) != (
            "true", "true", "surface-only-none", 0, "true", number["async_rand_draw_count"]):
        raise ValueError("scalar post-T1 header")
    if number["async_rand_draw_count"] <= 0:
        raise ValueError("scalar RNG")
    optimized = (
        fields["surface_single_flush_requested"] == fields["surface_single_flush_used"] == "true"
        and fields["surface_single_flush_fallback"] == "false"
        and fields["surface_single_flush_provenance_exact"] == "true"
        and (number["surface_single_flush_local_passability_calls"], number["surface_single_flush_buildable_calls"],
             number["surface_single_flush_height_snapshots"], number["surface_single_flush_height_mismatches"],
             number["surface_single_flush_object_family_count"], number["surface_single_flush_object_association_failures"],
             number["helper_object_containment_failures"], number["surface_single_flush_dirty_regions"],
             number["canonical_rebuilds_during_capsule_prepare"], number["canonical_rebuild_fallbacks_during_capsule_prepare"],
             number["fresh_grid_expected_rebuilds"]) == (4, 2, 2, 0, 6, 0, 0, 2, 0, 0, 0)
        and number["surface_single_flush_dirty_digest"] == number["outer_passage_pad_finalization_dirty_digest"]
        and 1 <= number["surface_single_flush_coverage_permille"] <= 150
        and fields["surface_single_flush_closing_complete"] == fields["surface_single_flush_cleanup_complete"] == "true"
        and fields["fresh_grid_rebuild_shape_exact"] == fields["fresh_grid_first_rebuild_complete"] == fields["fresh_grid_closing_rebuild_complete"] == "true"
        and fields["fresh_grid_phase_order"] == "local-dirty-grid-publication>fresh-plan-replay>capsule-publication>local-dirty-closing"
    )
    canonical = (
        fields["surface_single_flush_requested"] == fields["surface_single_flush_fallback"] == "true"
        and fields["surface_single_flush_used"] == "false" and bool(fields["surface_single_flush_fallback_reason"])
        and 1 <= number["canonical_rebuilds_during_capsule_prepare"] <= 2
        and number["canonical_rebuild_fallbacks_during_capsule_prepare"] == 0
        and number["fresh_grid_expected_rebuilds"] == number["canonical_rebuilds_during_capsule_prepare"]
        and fields["fresh_grid_rebuild_shape_exact"] == fields["fresh_grid_first_rebuild_complete"] == fields["fresh_grid_closing_rebuild_complete"] == "true"
        and fields["fresh_grid_phase_order"] == "canonical-grid-publication>fresh-plan-replay>capsule-publication>closing-rebuild"
    )
    if optimized == canonical:
        raise ValueError("scalar exact tuple")
    result = "optimized" if optimized else "canonical-fallback"
    if fields["tuple"] != result or fields["caller_fallback_reason"] != fields["surface_single_flush_fallback_reason"]:
        raise ValueError("scalar tuple alias")
    if number["comparison_ms"] != number["fresh_grid_plan_replay_publication_ms"] or number["proof_ms"] != number["fresh_grid_orchestration_total_ms"]:
        raise ValueError("scalar timing aliases")
    return result


def scalar_fixture(canonical: bool = False) -> dict[str, str]:
    """Small complete scalar receipt fixture; no game I/O or run is involved."""
    fields = {
        "schema": "smr.ralph.surface_only_single_flush_scalar.v1", "surface_stable_published": "true",
        "post_t1_only": "true", "pre_t1_capture_bytes": "0", "capture_status": "surface-only-none",
        "async_rand_draw_count": "3", "async_rand_dispatcher_restored": "true", "tuple": "optimized",
        "caller_fallback_reason": "", "comparison_ms": "17", "proof_ms": "23",
        "surface_single_flush_requested": "true", "surface_single_flush_used": "true", "surface_single_flush_fallback": "false",
        "surface_single_flush_fallback_reason": "", "surface_single_flush_local_passability_calls": "4",
        "surface_single_flush_buildable_calls": "2", "surface_single_flush_height_snapshots": "2",
        "surface_single_flush_height_mismatches": "0", "surface_single_flush_object_family_count": "6",
        "surface_single_flush_object_association_failures": "0", "surface_single_flush_provenance_exact": "true",
        "surface_single_flush_dirty_digest": "77", "surface_single_flush_dirty_regions": "2",
        "surface_single_flush_coverage_permille": "1", "surface_single_flush_closing_complete": "true",
        "surface_single_flush_cleanup_complete": "true", "outer_passage_pad_finalization_dirty_digest": "77",
        "canonical_rebuilds_during_capsule_prepare": "0", "canonical_rebuild_fallbacks_during_capsule_prepare": "0",
        "fresh_grid_first_rebuild_ms": "0", "fresh_grid_main_plan_ms": "0", "fresh_grid_replay_ms": "0",
        "fresh_grid_publication_ms": "0", "fresh_grid_plan_replay_publication_ms": "17", "fresh_grid_closing_rebuild_ms": "0",
        "fresh_grid_orchestration_total_ms": "23", "fresh_grid_phase_order": "local-dirty-grid-publication>fresh-plan-replay>capsule-publication>local-dirty-closing",
        "fresh_grid_expected_rebuilds": "0", "fresh_grid_rebuild_shape_exact": "true", "fresh_grid_first_rebuild_complete": "true",
        "fresh_grid_closing_rebuild_complete": "true", "helper_schema": "1", "helper_requested": "true", "helper_used": "true",
        "helper_phase": "closing", "helper_error": "", "helper_fallback": "false", "helper_provenance_exact": "true",
        "helper_dirty_digest": "77", "helper_regions": "2", "helper_terrain_cells": "1", "helper_coverage_permille": "1",
        "helper_dependency_margin": "1", "helper_height_snapshots": "2", "helper_height_mismatches": "0",
        "helper_object_family_count": "6", "helper_object_association_failures": "0", "helper_object_containment_failures": "0",
        "helper_passability_calls": "2", "helper_buildable_calls": "1", "helper_preplan_complete": "true",
        "helper_closing_complete": "true", "helper_cleanup_complete": "true",
    }
    if canonical:
        fields.update({
            "tuple": "canonical-fallback", "caller_fallback_reason": "closing certificate rejected",
            "surface_single_flush_used": "false", "surface_single_flush_fallback": "true",
            "surface_single_flush_fallback_reason": "closing certificate rejected",
            "canonical_rebuilds_during_capsule_prepare": "2", "fresh_grid_expected_rebuilds": "2",
            "fresh_grid_phase_order": "canonical-grid-publication>fresh-plan-replay>capsule-publication>closing-rebuild",
        })
    return fields


def strict_timing_ok(elapsed_ms: float) -> bool:
    """Mirror the acceptance boundary: equality at 100s is a rejection."""
    return elapsed_ms < 100000.0


def loop_material_ok(text: str) -> bool:
    return (
        "_ralph/tools/parity" in text
        and "$parityFiles.Count -eq 0" in text
        and "head_commit" in text and "head_tree" in text
        and "source_payload_manifest" in text and "deployed_payload_manifest" in text
        and "stage_manifest" in text and "game_executable" in text
        and "interpreter" in text and "live_executor_command" in text
    )


def main() -> int:
    executor = EXECUTOR.read_text(encoding="utf-8")
    loop = LOOP.read_text(encoding="utf-8")
    probe_hash = sha256_file(PARITY / "determinism_capture_probe.lua")
    with tempfile.TemporaryDirectory(prefix="surface_only_acceptance_static_") as raw:
        root = Path(raw)
        generated = render_generation(
            root / "capture",
            root / "surface_t1_stable.txt",
            root / "capture_final.txt",
            scheduler_census_path=root / "surface_scheduler_census.txt",
            surface_only=True,
        )
        script = root / "generate_14N134W_rough_reference.lua"
        script.write_text(generated, encoding="utf-8")
        compile_lua(DEFAULT_LUAC, script)
        generated_verdict = static_verdict(generated, surface_only=True)
        injected = static_verdict(
            generated + "\nChangeCurrentMapSlot(2, true)\n", surface_only=True
        )

    optimized = scalar_fixture()
    canonical = scalar_fixture(canonical=True)
    missing = dict(optimized)
    del missing["helper_object_containment_failures"]
    bad_height = dict(optimized)
    bad_height["surface_single_flush_height_mismatches"] = "1"
    bad_fallback = dict(canonical)
    bad_fallback["canonical_rebuilds_during_capsule_prepare"] = "3"
    extra = dict(optimized)
    extra["unmapped_runtime_field"] = "1"
    old_parity_loop = loop.replace("_ralph/tools/parity", "_ralph/parity", 1)
    stale_baseline_executor = executor + "\nplanner_canonical_rebuilds=2\n"
    utc_timing_executor = executor.replace(
        "[Diagnostics.Stopwatch]::GetTimestamp()", "[DateTime]::UtcNow.Ticks"
    )
    def rejected(fields: dict[str, str]) -> bool:
        try:
            scalar_tuple(fields)
        except ValueError:
            return True
        return False

    checks = {
        "executor_has_only_daemon_and_generator_harness_calls": executor.count(
            "Invoke-Harness @("
        ) == 2,
        "executor_has_no_ug_route_token": not any(token in executor for token in FORBIDDEN),
        "loop_has_no_ug_route_token": not any(token in loop for token in FORBIDDEN),
        "generated_surface_only_static_green": generated_verdict["ok"],
        "generated_surface_only_has_no_ug_route": not any(
            token in generated for token in FORBIDDEN[:4]
        ),
        "generated_surface_only_census_is_forward_observer_only": (
            "mechanism=Engine.ChainOnMsg" in generated
            and 'census_chain("MapGenerated"' in generated
            and 'census_chain("CityInitialized"' in generated
            and "CurrentThread" not in generated
            and "surface_thread_rng_mode" not in generated
            and "dofile(" not in generated
        ),
        "generated_scalar_receipt_is_post_t1_only": (
            "smr.ralph.surface_only_single_flush_scalar.v1" in generated
            and "state.surface_at_t1 = surface" in generated
            and "pre_t1_capture_bytes=0" in generated
            and generated.index("state.surface_at_t1 = surface") < generated.index("surface_only_single_flush_scalar.v1")
        ),
        "executor_waits_for_sentinels_by_filesystem_event": (
            "FileSystemWatcher" in executor
            and "WaitForChanged" in executor
            and "Start-Sleep -Milliseconds 20" not in executor
        ),
        "executor_has_no_stale_canonical2_t1_baseline": (
            "planner_canonical_rebuilds=2" not in executor
            and "planner_fresh_grid_expected_rebuilds=2" not in executor
            and "planner_fresh_grid_phase_order=canonical-grid-publication" not in executor
        ),
        "executor_uses_strict_stopwatch_less_than_100s": (
            "[Diagnostics.Stopwatch]::GetTimestamp()" in executor
            and "[Diagnostics.Stopwatch]::Frequency" in executor
            and "$elapsedMs -ge 100000.0" in executor
            and "$elapsedMs -gt [double]$script:Contract.maximum_t0_to_t1_ms" not in executor
        ),
        "loop_has_one_live_executor_and_content_addressed_cache": (
            loop.count("-File $executor") == 1
            and "surface-loop-static-cache.v1" in loop
            and "cache_key" in loop
            and "-Launch" in loop
        ),
        "loop_uses_nonempty_tools_parity_and_full_content_key": loop_material_ok(loop),
        "old_parity_path_adversary_rejected": not loop_material_ok(old_parity_loop),
        "stale_canonical2_baseline_adversary_rejected": "planner_canonical_rebuilds=2" in stale_baseline_executor
            and "planner_canonical_rebuilds=2" not in executor,
        "utc_clock_timing_adversary_rejected": "[Diagnostics.Stopwatch]::GetTimestamp()" not in utc_timing_executor,
        "strict_timing_boundary_adversaries": strict_timing_ok(99999.999) and not strict_timing_ok(100000.0),
        "reference_probe_hash_is_intentionally_current": (
            probe_hash == REFERENCE_PROBE_SHA256
            and REFERENCE_PROBE_SHA256 != "6D991C11C58CFD1D803D44A2B7DA269C77DD42E9E46B8BDAC71C5EFE13AA0A07"
        ),
        "optimized_scalar_tuple_accepted": scalar_tuple(optimized) == "optimized",
        "canonical_fallback_scalar_tuple_accepted": scalar_tuple(canonical) == "canonical-fallback",
        "missing_scalar_field_rejected": rejected(missing),
        "height_mismatch_scalar_rejected": rejected(bad_height),
        "out_of_range_canonical_fallback_rejected": rejected(bad_fallback),
        "unknown_scalar_field_rejected": rejected(extra),
        "injected_ug_route_rejected": not injected["ok"],
    }
    failed = sorted(name for name, ok in checks.items() if not ok)
    report = {
        "schema": "smr.ralph.surface-only-acceptance-static.v1",
        "ok": not failed,
        "checks": checks,
        "failed": failed,
        "generator_bytes": len(generated.encode("utf-8")),
        "generator_lua_parse": True,
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

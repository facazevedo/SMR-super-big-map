#!/usr/bin/env python3
"""Fail-closed static gate for the diagnostic guard-input wrapper lifecycle."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path


SCHEMA = "smr.ralph.guard_wrapper_design_audit.v1"
DEFAULT_LUAC = Path(r"C:\Users\fazevedo\.claude\tools\lua-5.4.8\bin\luac.exe")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def line_of(text: str, needle: str, *, start: int = 0) -> int:
    offset = text.find(needle, start)
    if offset < 0:
        return 0
    return text.count("\n", 0, offset) + 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--generation", type=Path, default=Path("Code/sbm_map_generation.lua"))
    parser.add_argument("--terrain", type=Path, default=Path("Code/sbm_terrain_copy.lua"))
    parser.add_argument(
        "--capture-probe",
        type=Path,
        default=Path("_ralph/tools/parity/determinism_capture_probe.lua"),
    )
    parser.add_argument(
        "--wrapper-probe",
        type=Path,
        default=Path("_ralph/tools/guard_preparation_input_probe.lua"),
    )
    parser.add_argument("--luac", type=Path, default=DEFAULT_LUAC)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    paths = [args.generation, args.terrain, args.capture_probe, args.wrapper_probe]
    for path in paths:
        if not path.is_file():
            raise SystemExit(f"missing required source: {path}")
    generation = args.generation.read_text(encoding="utf-8")
    terrain = args.terrain.read_text(encoding="utf-8")
    capture_probe = args.capture_probe.read_text(encoding="utf-8")
    wrapper = args.wrapper_probe.read_text(encoding="utf-8")

    post = line_of(
        generation,
        'SuperBigMap.NotifyDeterminismCaptureForTest("post_object_transform"',
    )
    topup = line_of(generation, "deposits.TopUpDeposits, map", start=generation.find("post_object_transform"))
    first_prepare = line_of(
        generation,
        "TerrainCopy.PrepareOuterResourceTerrain, map",
        start=generation.find("deposits.TopUpDeposits, map"),
    )
    repair_loop_offset = generation.find("while resource_terrain_ok ~= true")
    repair_prepare = line_of(
        generation,
        "TerrainCopy.PrepareOuterResourceTerrain, map",
        start=repair_loop_offset,
    )

    checks: dict[str, bool] = {
        "accepted_callback_precedes_topup_and_all_prepare_calls": (
            0 < post < topup < first_prepare < repair_prepare
        ),
        "both_calls_use_fresh_table_field_lookup": (
            generation.count("TerrainCopy.PrepareOuterResourceTerrain, map") == 2
        ),
        "repair_bound_is_exactly_two": "terrain_repair_attempt < 2" in generation,
        "terrain_function_is_table_exported": (
            "PrepareOuterResourceTerrain = PrepareOuterResourceTerrain" in terrain
        ),
        "ordinary_probe_arms_accepted_callback": (
            "generation.SetDeterminismCaptureHookForTest(" in capture_probe
            and 'elseif stage == "post_object_transform" then' in capture_probe
        ),
        "decorator_requires_pristine_armed_capture": (
            "ordinary determinism capture must be armed" in wrapper
            and "next(capture.counts) ~= nil" in wrapper
        ),
        "ordinary_callback_runs_before_wrapper_install": (
            0
            < line_of(wrapper, "original_capture_hook(stage, map, details)")
            < line_of(wrapper, "terrain_copy.PrepareOuterResourceTerrain = wrapped_prepare")
        ),
        "decorator_restores_ordinary_callback_at_boundary": (
            "capture.hook = original_capture_hook" in wrapper
            and 'if stage == "post_object_transform" then' in wrapper
        ),
        "wrapper_snapshots_before_untouched_original": (
            0
            < line_of(wrapper, "snapshot(call_count, map)")
            < line_of(wrapper, "pcall(original_prepare, map)")
        ),
        "wrapper_captures_complete_height_passability_buildable_inputs": all(
            token in wrapper
            for token in (
                'grid_blob(height_grid, "height")',
                "passability_blob(map)",
                'grid_blob(buildable_grid, "buildable")',
            )
        ),
        "wrapper_captures_order_identity_and_resource_planning": all(
            token in wrapper
            for token in (
                '"RESOURCE"',
                "traversal_index",
                "sorted_index",
                "marker_identity",
                "cluster_plan",
                "extractor_offsets",
            )
        ),
        "wrapper_captures_readiness_and_prior_failure": all(
            token in wrapper
            for token in (
                '"PRIOR"',
                "retry_failed_sites",
                "grid_ready",
                "force_retry",
                "guard_radius_cells",
            )
        ),
        "wrapper_is_pinned_to_correct_rough_scenario": (
            'identity.coordinate ~= "14N134W"' in wrapper
            and 'identity.preset ~= "RoughTerrain"' in wrapper
        ),
        "wrapper_is_bounded_to_initial_plus_two_repairs": (
            "if call_count > 3 then" in wrapper
            and 'if call_count == 3 then restore_prepare("maximum legal call completed") end'
            in wrapper
        ),
        "wrapper_restores_original_on_finalize_abort_and_failure": all(
            token in wrapper
            for token in (
                'restore_prepare("finalize")',
                'restore_prepare("abort")',
                'pcall(restore_prepare, "snapshot failure")',
                'pcall(restore_prepare, "original failure")',
            )
        ),
        "publication_is_manifest_last": (
            line_of(wrapper, 'write(out_base .. "-manifest.tsv"')
            > line_of(wrapper, "snapshot(call_count, map)")
        ),
        "probe_does_not_edit_production_source": (
            "SetOuterResourceGuardCorpusHookForTest" not in wrapper
            and "debug.getupvalue" not in wrapper
            and "debug.setupvalue" not in wrapper
            and "AsyncRand" not in wrapper
        ),
    }

    lua_parse_error = None
    if not args.luac.is_file():
        checks["wrapper_lua_parses"] = False
        lua_parse_error = f"missing Lua compiler: {args.luac}"
    else:
        proc = subprocess.run(
            [str(args.luac), "-p", str(args.wrapper_probe)],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        checks["wrapper_lua_parses"] = proc.returncode == 0
        if proc.returncode:
            lua_parse_error = (proc.stderr or proc.stdout).strip()

    failed = [name for name, ok in checks.items() if not ok]
    report = {
        "schema": SCHEMA,
        "ok": not failed,
        "scope": (
            "accepted post_object_transform callback through temporary table-level "
            "PrepareOuterResourceTerrain pre-call input capture and restoration"
        ),
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "lua_parse_error": lua_parse_error,
        "source_order": {
            "post_object_transform": post,
            "topup_deposits": topup,
            "initial_prepare": first_prepare,
            "repair_prepare": repair_prepare,
        },
        "sources": [
            {"path": str(path.resolve()).replace("\\", "/"), "sha256": sha256(path)}
            for path in paths
        ],
        "conclusion": (
            "Static design gate passed: the already-accepted callback can install a bounded, "
            "fail-closed table wrapper after post-object capture and before both dynamic prepare "
            "lookups; the diagnostic snapshots height, passability, buildability, resource order, "
            "stable identity, readiness, and prior failures before calling the untouched original."
            if not failed
            else "Static design gate failed; do not launch the diagnostic capture."
        ),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())

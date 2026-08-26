#!/usr/bin/env python3
"""Fail-closed static lifecycle gate for post-checkpoint lazy guard capture."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path


SCHEMA = "smr.ralph.staged_guard_capture_design_audit.v1"
DEFAULT_LUAC = Path(r"C:\Users\fazevedo\.claude\tools\lua-5.4.8\bin\luac.exe")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def position(text: str, needle: str, start: int = 0) -> int:
    return text.find(needle, start)


def parse_lua(path: Path, luac: Path) -> tuple[bool, str | None]:
    proc = subprocess.run(
        [str(luac), "-p", str(path)],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    error = (proc.stderr or proc.stdout).strip() or None
    return proc.returncode == 0, error


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--generation", type=Path, default=Path("Code/sbm_map_generation.lua"))
    parser.add_argument("--terrain", type=Path, default=Path("Code/sbm_terrain_copy.lua"))
    parser.add_argument(
        "--ordinary",
        type=Path,
        default=Path("_ralph/tools/parity/determinism_capture_probe.lua"),
    )
    parser.add_argument(
        "--loader",
        type=Path,
        default=Path("_ralph/tools/staged_guard_preparation_loader.lua"),
    )
    parser.add_argument(
        "--guard", type=Path, default=Path("_ralph/tools/guard_preparation_input_probe.lua")
    )
    parser.add_argument("--luac", type=Path, default=DEFAULT_LUAC)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    paths = [args.generation, args.terrain, args.ordinary, args.loader, args.guard]
    for path in paths:
        if not path.is_file():
            raise SystemExit(f"missing required source: {path}")
    if not args.luac.is_file():
        raise SystemExit(f"missing Lua compiler: {args.luac}")

    generation, terrain, ordinary, loader, guard = (
        path.read_text(encoding="utf-8") for path in paths
    )
    post = position(generation, 'NotifyDeterminismCaptureForTest("post_object_transform"')
    topup = position(generation, "deposits.TopUpDeposits, map", post)
    first_prepare = position(generation, "TerrainCopy.PrepareOuterResourceTerrain, map", topup)
    repair_prepare = position(
        generation,
        "TerrainCopy.PrepareOuterResourceTerrain, map",
        position(generation, "while resource_terrain_ok ~= true"),
    )

    ordinary_branch = ordinary[ordinary.find('elseif stage == "post_object_transform" then') :]
    ordinary_save_object = position(ordinary_branch, "save_objects(artifacts[stage].object_census")
    ordinary_save_collision = position(
        ordinary_branch, "save_objects(artifacts[stage].collision_census"
    )
    ordinary_mark = position(ordinary_branch, "stage_seen[stage] = true")
    ordinary_resolve = position(
        ordinary_branch, 'rawget(_G, "g_FzpDeterminismCapturePostObjectLoader")'
    )
    ordinary_invoke = position(ordinary_branch, "post_object_loader(stage, map, details, capture_hook)")
    loader_function = position(loader, "function(stage, map, details, capture_hook)")
    loader_context = position(loader, 'rawset(_G, "g_SbmGuardInputCaptureStagedContext", {')
    loader_dofile = position(loader, "dofile(probe_path)")
    staged_branch = guard[guard.find("if staged_mode then", guard.find("local decorated_hook")) :]
    staged_install = position(
        staged_branch, "terrain_copy.PrepareOuterResourceTerrain = wrapped_prepare"
    )
    legacy_branch = position(staged_branch, "else")
    staged_hook_write = position(staged_branch[:legacy_branch], "capture.hook =")

    checks: dict[str, bool] = {
        "production_boundary_precedes_topup_and_dynamic_prepare_calls": (
            0 <= post < topup < first_prepare < repair_prepare
            and generation.count("TerrainCopy.PrepareOuterResourceTerrain, map") == 2
        ),
        "terrain_prepare_remains_table_exported": (
            "PrepareOuterResourceTerrain = PrepareOuterResourceTerrain" in terrain
        ),
        "ordinary_loader_is_optional_and_type_checked": all(
            token in ordinary
            for token in (
                'rawget(_G, "g_FzpDeterminismCapturePostObjectLoader")',
                'type(post_object_loader) ~= "function"',
            )
        ),
        "ordinary_checkpoint_is_written_before_lazy_load": (
            0
            <= ordinary_save_object
            < ordinary_save_collision
            < ordinary_mark
            < ordinary_resolve
            < ordinary_invoke
        ),
        "ordinary_loader_is_post_object_only_and_single_use": (
            ordinary.count("post_object_loader(stage, map, details, capture_hook)") == 1
            and "if post_object_loader_ran then error" in ordinary_branch
            and 'rawset(_G, "g_FzpDeterminismCapturePostObjectLoader", false)' in ordinary_branch
        ),
        "ordinary_loader_failure_is_fail_closed": (
            "if loader_result ~= true then" in ordinary_branch
            and "post-object loader did not return true" in ordinary_branch
        ),
        "staging_loader_does_not_load_guard_before_callback": (
            loader.count("dofile(probe_path)") == 1
            and 0 <= loader_function < loader_context < loader_dofile
            and "dofile" not in loader[:loader_function]
        ),
        "staging_loader_context_is_complete": all(
            token in loader
            for token in (
                "stage = stage",
                "map = map",
                "capture_hook = capture_hook",
                "ordinary_checkpoint_written = true",
            )
        ),
        "staging_loader_requires_exact_success_and_cleanup": all(
            token in loader
            for token in (
                'result ~= "smr_guard_preparation_input_probe_armed"',
                'rawget(_G, "g_SbmGuardInputCaptureStagedContext") ~= false',
                'rawget(_G, "g_SbmGuardInputCaptureStatus") ~= "armed"',
            )
        ),
        "guard_requires_exact_staged_callback_identity": all(
            token in guard
            for token in (
                'staged_context.stage ~= "post_object_transform"',
                "staged_context.capture_hook ~= capture.hook",
                "staged_context.ordinary_checkpoint_written ~= true",
            )
        ),
        "guard_requires_all_prior_counts_inside_first_post_callback": all(
            token in guard
            for token in (
                "pre_stock_generation = 1, stock_surface_output = 1",
                "pre_z_transform = 2, post_z_transform = 2",
                "capture.counts.post_object_transform ~= nil",
            )
        ),
        "staged_guard_installs_directly_without_hook_mutation": (
            staged_install >= 0 and staged_hook_write < 0
        ),
        "staged_guard_clears_one_call_context": (
            'rawset(_G, "g_SbmGuardInputCaptureStagedContext", false)' in staged_branch
        ),
        "guard_snapshots_before_untouched_original": (
            0 <= position(guard, "snapshot(call_count, map)")
            < position(guard, "pcall(original_prepare, map)")
        ),
        "guard_captures_complete_inputs": all(
            token in guard
            for token in (
                'grid_blob(height_grid, "height")',
                "passability_blob(map)",
                'grid_blob(buildable_grid, "buildable")',
                '"RESOURCE"',
                '"PRIOR"',
                "guard_radius_cells",
                "extractor_offsets",
            )
        ),
        "guard_is_scenario_pinned_and_call_bounded": all(
            token in guard
            for token in (
                'identity.coordinate ~= "14N134W"',
                'identity.preset ~= "RoughTerrain"',
                "if call_count > 3 then",
                'if call_count == 3 then restore_prepare("maximum legal call completed") end',
            )
        ),
        "guard_restores_on_every_terminal_path": all(
            token in guard
            for token in (
                'restore_prepare("finalize")',
                'restore_prepare("abort")',
                'pcall(restore_prepare, "snapshot failure")',
                'pcall(restore_prepare, "original failure")',
            )
        ),
        "diagnostic_path_avoids_rng_and_upvalue_interposition": all(
            token not in ordinary + loader + guard
            for token in ("AsyncRand", "debug.getupvalue", "debug.setupvalue")
        ),
    }

    parse_errors: dict[str, str] = {}
    for label, path in (("ordinary", args.ordinary), ("loader", args.loader), ("guard", args.guard)):
        ok, error = parse_lua(path, args.luac)
        checks[f"{label}_lua_parses"] = ok
        if error:
            parse_errors[label] = error

    failed = [name for name, ok in checks.items() if not ok]
    report = {
        "schema": SCHEMA,
        "ok": not failed,
        "scope": "ordinary checkpoint write then lazy direct guard-wrapper installation",
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "lua_parse_errors": parse_errors,
        "source_positions": {
            "production_post_object": post,
            "production_topup": topup,
            "production_initial_prepare": first_prepare,
            "production_repair_prepare": repair_prepare,
            "ordinary_object_write": ordinary_save_object,
            "ordinary_collision_write": ordinary_save_collision,
            "ordinary_checkpoint_mark": ordinary_mark,
            "ordinary_loader_resolve": ordinary_resolve,
            "ordinary_lazy_load": ordinary_invoke,
            "loader_function": loader_function,
            "loader_context": loader_context,
            "loader_dofile": loader_dofile,
            "staged_direct_install": staged_install,
        },
        "sources": [
            {"path": str(path.resolve()).replace("\\", "/"), "sha256": sha256(path)}
            for path in paths
        ],
        "conclusion": (
            "Static lifecycle gate passed: the ordinary probe durably writes checkpoint 13 before "
            "the one-shot loader executes any guard-probe code, and staged mode directly installs "
            "the bounded, fully restoring pre-call wrapper before both dynamic prepare lookups."
            if not failed
            else "Static lifecycle gate failed; do not build or launch a staged diagnostic input."
        ),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())

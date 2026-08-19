#!/usr/bin/env python3
"""Static, fail-closed validation for the staged determinism capture producer."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
MAP_GENERATION = ROOT / "Code" / "sbm_map_generation.lua"
TERRAIN_COPY = ROOT / "Code" / "sbm_terrain_copy.lua"
METADATA = ROOT / "metadata.lua"
PRODUCER = Path(__file__).with_name("determinism_capture_probe.lua")

CHECKPOINTS = {
    "pre_stock_generation": ("rng_state", "prefab_order", "generation_inputs"),
    "stock_surface_output": ("surface_height", "surface_terrain", "object_census"),
    "pre_z_transform": ("surface_height", "surface_terrain", "object_census"),
    "post_z_transform": ("surface_height", "surface_terrain", "zone_stamp"),
    "post_object_transform": ("object_census", "collision_census"),
    "pre_init_buildable": (
        "surface_height", "surface_terrain", "passability", "buildable", "collision_census"
    ),
    "post_init_buildable": (
        "surface_height", "surface_terrain", "passability", "buildable", "collision_census"
    ),
    "post_process_buildable": (
        "surface_height", "surface_terrain", "passability", "buildable", "collision_census"
    ),
    "final_stable": (
        "surface_height", "underground_height", "surface_passability", "surface_buildable",
        "underground_passability", "underground_buildable", "object_census"
    ),
}


def lua_parses(source: str) -> tuple[bool, str | None]:
    try:
        from lupa import LuaRuntime

        runtime = LuaRuntime(unpack_returned_tuples=True)
        loader = runtime.eval("function(s) local f,e=load(s); return f ~= nil,e end")
        ok, error = loader(source)
        return bool(ok), None if ok else str(error)
    except Exception as exc:  # pragma: no cover - environment failure is reported
        return False, str(exc)


def analyze(
    map_generation: str,
    terrain_copy: str,
    metadata: str,
    producer: str,
) -> dict[str, object]:
    checks: dict[str, bool] = {}

    checks["map_generation_hook_defined_once"] = (
        map_generation.count("local function NotifyDeterminismCaptureForTest") == 1
    )
    checks["map_generation_setter_defined_once"] = (
        map_generation.count("function MapGeneration.SetDeterminismCaptureHookForTest") == 1
    )
    checks["map_generation_export_defined_once"] = (
        map_generation.count("function MapGeneration.NotifyDeterminismCaptureForTest") == 1
    )
    checks["pre_stock_notification_once"] = (
        map_generation.count('NotifyDeterminismCaptureForTest("pre_stock_generation"') == 1
    )
    checks["stock_output_notification_once"] = (
        map_generation.count('NotifyDeterminismCaptureForTest("stock_surface_output"') == 1
    )
    checks["post_object_notification_once"] = (
        map_generation.count('NotifyDeterminismCaptureForTest("post_object_transform"') == 1
    )
    checks["hook_is_transient_state"] = (
        "SuperBigMap.State.test_determinism_capture = {" in map_generation
        and "authority_tag" in map_generation
        and "counts = {}" in map_generation
    )
    checks["hook_is_dormant_without_arm"] = (
        'if type(capture) ~= "table" then return false end' in map_generation
    )
    checks["hook_is_fail_closed"] = (
        "if not ok or result ~= true then" in map_generation
        and "determinism capture failed at" in map_generation
    )

    pre_notice = map_generation.find('NotifyDeterminismCaptureForTest("pre_stock_generation"')
    stock_call = map_generation.find("CallWithClutterCapture", pre_notice)
    stock_notice = map_generation.find(
        'NotifyDeterminismCaptureForTest("stock_surface_output"', stock_call
    )
    source_probe = map_generation.find(
        'ProbeNativeClutterAccess(source, "temporary source after DoGenerate")', stock_notice
    )
    checks["stock_boundaries_ordered"] = (
        min(pre_notice, stock_call, stock_notice, source_probe) >= 0
        and pre_notice < stock_call < stock_notice < source_probe
    )

    post_object = map_generation.find('NotifyDeterminismCaptureForTest("post_object_transform"')
    scale_markers = map_generation.rfind("ScaleMarkersToFull(map", 0, post_object)
    resume_pass = map_generation.find("ResumeCombinedPassEdits", post_object)
    checks["object_boundary_ordered"] = (
        min(scale_markers, post_object, resume_pass) >= 0
        and scale_markers < post_object < resume_pass
    )

    checks["terrain_bridge_defined_once"] = (
        terrain_copy.count("local function NotifyDeterminismCaptureForTest") == 1
    )
    checks["pre_z_notification_once"] = (
        terrain_copy.count('NotifyDeterminismCaptureForTest("pre_z_transform"') == 1
    )
    checks["post_z_notification_once"] = (
        terrain_copy.count('NotifyDeterminismCaptureForTest("post_z_transform"') == 1
    )
    checks["z_capture_distinguishes_grid_kind"] = (
        terrain_copy.count('grid_kind = scale_values and "surface_height" or "surface_terrain"')
        == 2
    )
    resample = terrain_copy.find("local stretched = GridResample")
    pre_z = terrain_copy.find('NotifyDeterminismCaptureForTest("pre_z_transform"', resample)
    transform = terrain_copy.find("if scale_values and cfg_bool(\"STRETCH_SCALE_HEIGHTS\"", pre_z)
    post_z = terrain_copy.find('NotifyDeterminismCaptureForTest("post_z_transform"', transform)
    set_grid = terrain_copy.find("local ok_set = pcall(set_fn, map, stretched)", post_z)
    checks["z_boundaries_ordered"] = (
        min(resample, pre_z, transform, post_z, set_grid) >= 0
        and resample < pre_z < transform < post_z < set_grid
    )

    checks["metadata_version_822"] = bool(re.search(r"'version',\s*822\s*,", metadata))
    checks["metadata_describes_diagnostic"] = (
        "fail-closed staged determinism capture diagnostics" in metadata
    )

    parsed, parse_error = lua_parses(producer)
    checks["producer_lua_parses"] = parsed
    forbidden = ("taskkill", "MarsDebug.exe", "run_parity.py", "subprocess", "ChangeDisplaySettings")
    checks["producer_has_no_forbidden_control_surface"] = not any(
        token.lower() in producer.lower() for token in forbidden
    )
    checks["producer_requires_fresh_output_base"] = (
        "g_FzpDeterminismCaptureOutBase" in producer
        and "must be a non-empty fresh per-run path" in producer
    )
    checks["producer_arms_only_test_setter"] = (
        "SetDeterminismCaptureHookForTest" in producer
        and "full_z_parity_42S85E_cohort" in producer
    )
    checks["producer_sorts_object_census"] = (
        'table.sort(rows)' in producer and 'tostring(obj.handle)' not in producer
    )
    checks["producer_sorts_canonical_keys"] = (
        "table.sort(keys" in producer and "<cycle>" in producer and "<depth>" in producer
    )
    checks["producer_uses_raw_grid_capture"] = producer.count("GridSaveRaw") >= 3
    checks["producer_serializes_pass_and_build_grids"] = (
        "terrain.GetPassGrid" in producer and producer.count("GridWriteStr") >= 3
    )
    checks["producer_freshly_evaluates_build_phases"] = all(
        token in producer
        for token in ("InitBuildableGrid(map", "ProcessBuildableGrid({", "NewGrid(width, height")
    )
    checks["producer_requires_completed_maps"] = (
        "SuperBigMapSurfaceStretchDone" in producer
        and "SuperBigMapUndergroundPrepared" in producer
    )
    checks["producer_finalizer_is_single_use"] = (
        "determinism capture finalizer already ran" in producer
        and 'g_FzpDeterminismCaptureFinalized", true' in producer
    )
    checks["producer_balances_loop_detector"] = (
        'PauseInfiniteLoopDetection("fzp_determinism_capture")' in producer
        and producer.count('ResumeInfiniteLoopDetection("fzp_determinism_capture")') >= 2
    )
    checks["producer_fails_on_missing_early_capture"] = (
        "missing early capture" in producer and "stage_seen[key]" in producer
    )

    for stage, names in CHECKPOINTS.items():
        checks[f"checkpoint_{stage}_declared"] = producer.count(stage) >= 2
        for name in names:
            checks[f"artifact_{stage}_{name}_declared"] = (
                re.search(
                    rf"{re.escape(stage)}\s*=\s*\{{[^}}]*\"{re.escape(name)}\"",
                    producer,
                    re.DOTALL,
                )
                is not None
            )

    failed = sorted(name for name, value in checks.items() if not value)
    return {
        "schema": "smr.ralph.determinism_capture_producer_static.v1",
        "ok": not failed,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "lua_parse_error": parse_error,
    }


def self_test(sources: tuple[str, str, str, str]) -> dict[str, object]:
    base = analyze(*sources)
    mutations = {
        "missing_stock_hook_red": (0, 'NotifyDeterminismCaptureForTest("stock_surface_output"', "removed"),
        "non_fail_closed_hook_red": (0, "if not ok or result ~= true then", "if false then"),
        "missing_type_capture_red": (1, 'NotifyDeterminismCaptureForTest("post_z_transform"', "removed"),
        "stale_version_red": (2, "'version', 822,", "'version', 821,"),
        "forbidden_launcher_red": (3, "return \"fzp_determinism_capture_armed\"", "taskkill MarsDebug.exe"),
        "missing_final_artifact_red": (3, '"underground_buildable",', ""),
    }
    controls: dict[str, bool] = {}
    for name, (index, old, new) in mutations.items():
        changed = list(sources)
        if old not in changed[index]:
            controls[name] = False
            continue
        changed[index] = changed[index].replace(old, new, 1)
        controls[name] = not analyze(*changed)["ok"]
    return {
        "schema": "smr.ralph.determinism_capture_producer_self_test.v1",
        "ok": bool(base["ok"]) and all(controls.values()),
        "static": base,
        "controls": controls,
        "passed_controls": sum(controls.values()),
        "total_controls": len(controls),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    sources = tuple(
        path.read_text(encoding="utf-8")
        for path in (MAP_GENERATION, TERRAIN_COPY, METADATA, PRODUCER)
    )
    report = self_test(sources) if args.self_test else analyze(*sources)
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

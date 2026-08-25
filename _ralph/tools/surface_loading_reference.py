#!/usr/bin/env python3
"""Render fail-closed 14N134W Rough Terrain reference-capture inputs.

This tool does not launch or control the game.  It reuses the established parity
generator and its exact Rough Terrain activation block, adds task-specific proof of
the selected random-map preset and stable surface boundary, and stages generated Lua
only under the shared Ralph temporary root.  Live orchestration remains the exclusive
responsibility of ``smr.cmd``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import py_compile
import subprocess
import sys
import tempfile
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[2]
PARITY = Path(__file__).resolve().parent / "parity"
sys.path.insert(0, str(PARITY))

import run_parity  # noqa: E402


TMP_ROOT = PROJECT / "_ralph" / "tmp"
DEFAULT_LUAC = Path(r"C:\Users\fazevedo\.claude\tools\lua-5.4.8\bin\luac.exe")
COORDINATE = "14N134W"
LAT = -840
LON = -8040
EXPECTED_PRESET = "RoughTerrain"
REFERENCE_UNDERGROUND_SEED = run_parity.REFERENCE_UNDERGROUND_SEED
PLACEHOLDER_PREFIX = "__"


class ReferenceError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def lua_path(path: Path) -> str:
    return str(path.resolve()).replace("\\", "/")


def unresolved(text: str) -> list[str]:
    tokens: set[str] = set()
    start = 0
    while True:
        left = text.find(PLACEHOLDER_PREFIX, start)
        if left < 0:
            break
        right = text.find(PLACEHOLDER_PREFIX, left + 2)
        if right < 0:
            break
        body = text[left + 2 : right]
        if body and all(ch == "_" or ch.isdigit() or "A" <= ch <= "Z" for ch in body):
            tokens.add(text[left : right + 2])
        start = right + 2
    return sorted(tokens)


def benchmark_block(capture_base: Path, stable_sentinel: Path) -> str:
    probe = PARITY / "determinism_capture_probe.lua"
    return f'''\t\tdo
\t\t\tlocal state = {{
\t\t\t\tschema = "smr.ralph.surface_loading_reference_state.v1",
\t\t\t\tcoordinate = "{COORDINATE}", latitude = {LAT}, longitude = {LON},
\t\t\t\texpected_preset = "{EXPECTED_PRESET}", selected_preset = false,
\t\t\t}}
\t\t\tlocal function active_rule_ids()
\t\t\t\tlocal ids = {{}}
\t\t\t\tfor id, active in pairs((Game and Game.game_rules) or empty_table) do
\t\t\t\t\tif active == true then ids[#ids + 1] = tostring(id) end
\t\t\t\tend
\t\t\t\ttable.sort(ids)
\t\t\t\treturn ids
\t\t\tend
\t\t\tstate.rough_terrain_at_generation_start = IsGameRuleActive("RoughTerrain") == true
\t\t\tstate.active_rule_ids_at_generation_start = active_rule_ids()
\t\t\tif state.rough_terrain_at_generation_start ~= true then
\t\t\t\terror("Rough Terrain inactive at generation start")
\t\t\tend
\t\t\tlocal original_generate_random_map = GenerateRandomMap
\t\t\tif type(original_generate_random_map) ~= "function" then
\t\t\t\terror("GenerateRandomMap unavailable for preset proof")
\t\t\tend
\t\t\tGenerateRandomMap = function(map_name, preset_name, params)
\t\t\t\tlocal map_data = type(MapData) == "table" and MapData[map_name] or nil
\t\t\t\tif map_data and map_data.Environment == "Surface" then
\t\t\t\t\tif state.selected_preset then error("surface preset selected more than once") end
\t\t\t\t\tstate.selected_preset = tostring(preset_name)
\t\t\t\t\tif state.selected_preset ~= state.expected_preset then
\t\t\t\t\t\terror("selected surface preset " .. state.selected_preset
\t\t\t\t\t\t\t.. " ~= " .. state.expected_preset)
\t\t\t\t\tend
\t\t\t\tend
\t\t\t\treturn original_generate_random_map(map_name, preset_name, params)
\t\t\tend
\t\t\trawset(_G, "g_SmrRalphSurfaceReferenceState", state)
\t\t\trawset(_G, "g_FzpDeterminismCaptureOutBase", "{lua_path(capture_base)}")
\t\t\tlocal probe_result = dofile("{lua_path(probe)}")
\t\t\tif probe_result ~= "fzp_determinism_capture_armed" then
\t\t\t\terror("determinism capture producer did not arm: " .. tostring(probe_result))
\t\t\tend
\t\t\trawset(_G, "g_SmrRalphPublishSurfaceStable", function(surface)
\t\t\t\tif type(surface) ~= "table" or surface.SuperBigMapSurfaceStretchDone ~= true then
\t\t\t\t\terror("surface stable publisher requires completed stretch")
\t\t\t\tend
\t\t\t\tlocal waited = 0
\t\t\t\twhile surface.SuperBigMapSurfacePostPipelineRevalidationScheduled ~= true
\t\t\t\t\tand not surface.SuperBigMapSurfacePostPipelineRevalidationError
\t\t\t\t\tand waited < 600000 do
\t\t\t\t\tSleep(10)
\t\t\t\t\twaited = waited + 10
\t\t\t\tend
\t\t\t\tif surface.SuperBigMapSurfacePostPipelineRevalidationScheduled ~= true then
\t\t\t\t\terror("surface post-pipeline revalidation was not scheduled")
\t\t\t\tend
\t\t\t\twhile surface.SuperBigMapSurfacePostPipelineRevalidationComplete ~= true
\t\t\t\t\tand not surface.SuperBigMapSurfacePostPipelineRevalidationError
\t\t\t\t\tand waited < 600000 do
\t\t\t\t\tSleep(10)
\t\t\t\t\twaited = waited + 10
\t\t\t\tend
\t\t\t\tif surface.SuperBigMapSurfacePostPipelineRevalidationComplete ~= true then
\t\t\t\t\terror("surface post-pipeline revalidation incomplete: "
\t\t\t\t\t\t.. tostring(surface.SuperBigMapSurfacePostPipelineRevalidationError))
\t\t\t\tend
\t\t\t\tstate.rough_terrain_at_t1 = IsGameRuleActive("RoughTerrain") == true
\t\t\t\tstate.active_rule_ids_at_t1 = active_rule_ids()
\t\t\t\tstate.surface_stretch_done = surface.SuperBigMapSurfaceStretchDone == true
\t\t\t\tstate.surface_expansion_pending = surface.SuperBigMapExpansionPending == true
\t\t\t\tstate.stretch_pipeline_pending = surface.SuperBigMapStretchPipelinePending == true
\t\t\t\tstate.post_pipeline_revalidation_complete =
\t\t\t\t\tsurface.SuperBigMapSurfacePostPipelineRevalidationComplete == true
\t\t\t\tlocal loading_visible = type(SBM.ExpansionLoadingVisible) == "function"
\t\t\t\t\tand SBM.ExpansionLoadingVisible() == true
\t\t\t\tstate.expansion_loading_visible = loading_visible
\t\t\t\tif state.rough_terrain_at_t1 ~= true
\t\t\t\t\tor state.selected_preset ~= state.expected_preset
\t\t\t\t\tor state.surface_expansion_pending
\t\t\t\t\tor state.stretch_pipeline_pending
\t\t\t\t\tor not state.post_pipeline_revalidation_complete
\t\t\t\t\tor loading_visible then
\t\t\t\t\terror("surface stable predicate failed")
\t\t\t\tend
\t\t\t\tlocal text = table.concat({{
\t\t\t\t\t"schema=" .. state.schema,
\t\t\t\t\t"coordinate=" .. state.coordinate,
\t\t\t\t\t"latitude=" .. tostring(state.latitude),
\t\t\t\t\t"longitude=" .. tostring(state.longitude),
\t\t\t\t\t"rough_terrain_at_generation_start=" .. tostring(state.rough_terrain_at_generation_start),
\t\t\t\t\t"rough_terrain_at_t1=" .. tostring(state.rough_terrain_at_t1),
\t\t\t\t\t"active_rule_ids_at_generation_start=" .. table.concat(state.active_rule_ids_at_generation_start, ","),
\t\t\t\t\t"active_rule_ids_at_t1=" .. table.concat(state.active_rule_ids_at_t1, ","),
\t\t\t\t\t"selected_random_map_preset=" .. tostring(state.selected_preset),
\t\t\t\t\t"surface_stretch_done=" .. tostring(state.surface_stretch_done),
\t\t\t\t\t"surface_expansion_pending=" .. tostring(state.surface_expansion_pending),
\t\t\t\t\t"stretch_pipeline_pending=" .. tostring(state.stretch_pipeline_pending),
\t\t\t\t\t"post_pipeline_revalidation_complete=" .. tostring(state.post_pipeline_revalidation_complete),
\t\t\t\t\t"expansion_loading_visible=" .. tostring(state.expansion_loading_visible),
\t\t\t\t}}, "\\n") .. "\\n"
\t\t\t\tlocal write_error = AsyncStringToFile("{lua_path(stable_sentinel)}", text)
\t\t\t\tif write_error then error("stable sentinel write failed: " .. tostring(write_error)) end
\t\t\t\treturn true
\t\t\tend)
\t\tend'''


def render_generation(capture_base: Path, stable_sentinel: Path) -> str:
    text = run_parity.GEN_TEMPLATE.read_text(encoding="utf-8")
    text = text.replace(
        "__FLIGHT_SANITATION__",
        run_parity.FLIGHT_SANITATION.read_text(encoding="utf-8").rstrip(),
    )
    text = text.replace("__EXPAND__", "true")
    text = text.replace("__LAT__", str(LAT)).replace("__LON__", str(LON))
    text = text.replace(
        "__TWIN_SEED_BLOCK__",
        run_parity.TWIN_SEED_BLOCK.format(seed=REFERENCE_UNDERGROUND_SEED),
    )
    text = text.replace("__UNDERGROUND_PIN_BLOCK__", "")
    extra = run_parity.ROUGH_TERRAIN_BLOCK + "\n\n" + benchmark_block(
        capture_base, stable_sentinel
    )
    text = text.replace("__EXTRA_SETUP__", extra)
    publish_marker = '''\t\tif __EXPAND__ then
\t\t\tg_ParityStatus = "waiting_surface_stretch"'''.replace("__EXPAND__", "true")
    if publish_marker not in text:
        raise ReferenceError("surface-stretch wait marker changed")
    final_wait = '''\t\tend

\t\t-- Capture the generator holders BEFORE any game time is allowed to advance:'''
    if final_wait not in text:
        raise ReferenceError("surface stable insertion marker changed")
    text = text.replace(
        final_wait,
        '''\t\tend

\t\tlocal publish_surface_stable = rawget(_G, "g_SmrRalphPublishSurfaceStable")
\t\tif type(publish_surface_stable) ~= "function" then
\t\t\terror("surface stable publisher is unavailable")
\t\tend
\t\tpublish_surface_stable(surface)

\t\t-- Capture the generator holders BEFORE any game time is allowed to advance:''',
        1,
    )
    missing = unresolved(text)
    if missing:
        raise ReferenceError(f"generation script has unresolved placeholders: {missing}")
    return text


def compile_lua(luac: Path, path: Path) -> None:
    if not luac.is_file():
        raise ReferenceError(f"Lua compiler missing: {luac}")
    proc = subprocess.run(
        [str(luac), "-p", str(path)], capture_output=True, text=True, timeout=60
    )
    if proc.returncode:
        raise ReferenceError(proc.stderr.strip() or proc.stdout.strip() or "Lua parse failed")


def static_verdict(text: str) -> dict[str, object]:
    positions = {
        "new_game": text.find('NewGame({ seed_text = "LOZL3FQr" })'),
        "rough_rule": text.find('Game:AddGameRule("RoughTerrain")'),
        "preset_wrapper": text.find("GenerateRandomMap = function(map_name, preset_name, params)"),
        "generation": text.find("pcall(GenerateCurrentRandomMap)"),
        "stable_publish": text.find("publish_surface_stable(surface)"),
        "underground_visit": text.find('g_ParityStatus = "entering_underground"'),
    }
    checks = {
        "coordinate_is_14N134W": f"latitude = {LAT}, longitude = {LON}" in text,
        "expanded_generation": "g_CurrentMapParams.SuperBigMapExpandMap = true or nil" in text,
        "rough_block_reused_once": text.count(run_parity.ROUGH_TERRAIN_BLOCK) == 1,
        "rough_activation_precedes_preset_and_generation": (
            0 <= positions["new_game"] < positions["rough_rule"]
            < positions["preset_wrapper"] < positions["generation"]
        ),
        "preset_fail_closed": 'state.selected_preset ~= state.expected_preset' in text,
        "preset_required_roughterrain": f'expected_preset = "{EXPECTED_PRESET}"' in text,
        "rule_checked_at_start_and_t1": (
            'state.rough_terrain_at_generation_start = IsGameRuleActive("RoughTerrain") == true'
            in text
            and 'state.rough_terrain_at_t1 = IsGameRuleActive("RoughTerrain") == true' in text
        ),
        "active_rule_ids_recorded_twice": (
            "active_rule_ids_at_generation_start" in text
            and "active_rule_ids_at_t1" in text
        ),
        "stable_waits_for_post_pipeline_revalidation": (
            "SuperBigMapSurfacePostPipelineRevalidationScheduled ~= true" in text
            and "SuperBigMapSurfacePostPipelineRevalidationComplete ~= true" in text
        ),
        "stable_rejects_pending_work_and_loading_ui": (
            "state.surface_expansion_pending" in text
            and "state.stretch_pipeline_pending" in text
            and "state.expansion_loading_visible" in text
        ),
        "stable_published_before_underground_visit": (
            0 <= positions["generation"] < positions["stable_publish"]
            < positions["underground_visit"]
        ),
        "determinism_capture_armed_before_generation": (
            text.find("g_FzpDeterminismCaptureOutBase") < positions["generation"]
        ),
        "no_unresolved_placeholders": not unresolved(text),
        "no_direct_game_launcher": "MarsDebug.exe" not in text and "taskkill" not in text.lower(),
    }
    failed = sorted(name for name, passed in checks.items() if not passed)
    return {
        "schema": "smr.ralph.surface_loading_reference_static.v1",
        "ok": not failed,
        "coordinate": COORDINATE,
        "latitude": LAT,
        "longitude": LON,
        "expected_preset": EXPECTED_PRESET,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "positions": positions,
    }


def require_tmp_path(path: Path) -> Path:
    resolved = path.resolve()
    try:
        resolved.relative_to(TMP_ROOT.resolve())
    except ValueError as exc:
        raise ReferenceError(f"generated Lua must stay under {TMP_ROOT}: {resolved}") from exc
    if not resolved.name.startswith(".tmp"):
        raise ReferenceError("generated staging directory name must begin .tmp")
    return resolved


def command_prepare(args: argparse.Namespace) -> int:
    staging = require_tmp_path(args.staging)
    if staging.exists():
        raise ReferenceError(f"fresh staging directory already exists: {staging}")
    staging.mkdir(parents=True)
    generation = staging / "generate_14N134W_rough_reference.lua"
    capture_base = args.capture_base.resolve()
    stable_sentinel = args.stable_sentinel.resolve()
    text = render_generation(capture_base, stable_sentinel)
    generation.write_text(text, encoding="utf-8")
    compile_lua(args.luac.resolve(), generation)
    verdict = static_verdict(text)
    if not verdict["ok"]:
        raise ReferenceError(f"rendered generation failed static checks: {verdict['failed']}")
    manifest = {
        "schema": "smr.ralph.surface_loading_reference_manifest.v1",
        "source_head": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=PROJECT, text=True, timeout=30
        ).strip(),
        "coordinate": COORDINATE,
        "latitude": LAT,
        "longitude": LON,
        "expanded": True,
        "rough_terrain_required": True,
        "selected_random_map_preset_required": EXPECTED_PRESET,
        "reference_underground_seed": REFERENCE_UNDERGROUND_SEED,
        "generation_script": str(generation),
        "generation_script_bytes": generation.stat().st_size,
        "generation_script_sha256": sha256_file(generation),
        "capture_base": str(capture_base),
        "stable_sentinel": str(stable_sentinel),
        "static_verdict": verdict,
        "luac": str(args.luac.resolve()),
    }
    write_json(args.out.resolve(), manifest)
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


def command_self_test(args: argparse.Namespace) -> int:
    py_compile.compile(str(Path(__file__).resolve()), doraise=True)
    TMP_ROOT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".tmp_surface_reference_selftest_", dir=TMP_ROOT) as raw:
        root = Path(raw)
        generation = root / "generation.lua"
        text = render_generation(root / "capture", root / "stable.sentinel")
        generation.write_text(text, encoding="utf-8")
        compile_lua(args.luac.resolve(), generation)
        verdict = static_verdict(text)
        mutation = text.replace('expected_preset = "RoughTerrain"', 'expected_preset = "MAIN"', 1)
        mutation_red = static_verdict(mutation)["ok"] is False
        verdict["lua_parse"] = True
        verdict["python_compile"] = True
        verdict["wrong_preset_mutation_red"] = mutation_red
        verdict["ok"] = verdict["ok"] and mutation_red
    if args.out:
        write_json(args.out.resolve(), verdict)
    print(json.dumps(verdict, indent=2, sort_keys=True))
    return 0 if verdict["ok"] else 1


def parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="command", required=True)
    prepare = sub.add_parser("prepare")
    prepare.add_argument("--staging", type=Path, required=True)
    prepare.add_argument("--capture-base", type=Path, required=True)
    prepare.add_argument("--stable-sentinel", type=Path, required=True)
    prepare.add_argument("--out", type=Path, required=True)
    prepare.add_argument("--luac", type=Path, default=DEFAULT_LUAC)
    prepare.set_defaults(func=command_prepare)
    self_test = sub.add_parser("self-test")
    self_test.add_argument("--out", type=Path)
    self_test.add_argument("--luac", type=Path, default=DEFAULT_LUAC)
    self_test.set_defaults(func=command_self_test)
    return ap


def main() -> int:
    args = parser().parse_args()
    try:
        return args.func(args)
    except (OSError, ReferenceError, subprocess.SubprocessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

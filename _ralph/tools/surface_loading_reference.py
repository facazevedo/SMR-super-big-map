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
DEFAULT_ASYNC_RAND_SEED = 301460103
REFERENCE_GENERATION_SHA256 = "FB201DC57591DF2F97A1B512C391D3EF65F7CDF1928CCA800F7F84770DE58D58"
REFERENCE_PROBE_SHA256 = "6D991C11C58CFD1D803D44A2B7DA269C77DD42E9E46B8BDAC71C5EFE13AA0A07"
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


def benchmark_block(
    capture_base: Path,
    stable_sentinel: Path,
    final_sentinel: Path,
    async_rand_seed: int,
) -> str:
    probe = PARITY / "determinism_capture_probe.lua"
    return f'''\t\tdo
\t\t\tlocal state = {{
\t\t\t\tschema = "smr.ralph.surface_loading_reference_state.v4",
\t\t\t\tcoordinate = "{COORDINATE}", latitude = {LAT}, longitude = {LON},
\t\t\t\texpected_preset = "{EXPECTED_PRESET}", selected_preset = false,
\t\t\t\tasync_rand_scope = "mod_owned_engine_rand_int",
\t\t\t\tasync_rand_initial_seed = {async_rand_seed},
\t\t\t\tasync_rand_final_seed = {async_rand_seed},
\t\t\t\tasync_rand_draw_count = 0,
\t\t\t\tforeign_async_rand_draw_count = 0,
\t\t\t}}
\t\t\tif type(BraidRandom) ~= "function" then
\t\t\t\terror("BraidRandom unavailable; cannot create private mod RNG stream")
\t\t\tend
\t\t\tlocal original_async_rand = rawget(_G, "AsyncRand")
\t\t\tif type(original_async_rand) ~= "function" then
\t\t\t\terror("AsyncRand unavailable; cannot forward foreign RNG consumers")
\t\t\tend
\t\t\tlocal mod_rand_int = type(SBM) == "table" and type(SBM.Engine) == "table"
\t\t\t\tand SBM.Engine.RandInt or nil
\t\t\tif type(mod_rand_int) ~= "function" then
\t\t\t\terror("SuperBigMap.Engine.RandInt unavailable for private capture stream")
\t\t\tend
\t\t\tif type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
\t\t\t\terror("debug.getinfo unavailable for mod RNG caller identity")
\t\t\tend
\t\t\tlocal async_rand_seed = state.async_rand_initial_seed
\t\t\tlocal function called_by_mod_rand_int()
\t\t\t\tfor level = 2, 8 do
\t\t\t\t\tlocal ok, info = pcall(debug.getinfo, level, "f")
\t\t\t\t\tif not ok or type(info) ~= "table" then break end
\t\t\t\t\tif info.func == mod_rand_int then return true end
\t\t\t\tend
\t\t\t\treturn false
\t\t\tend
\t\t\tlocal function scoped_async_rand(...)
\t\t\t\tif called_by_mod_rand_int() then
\t\t\t\t\tlocal value
\t\t\t\t\tvalue, async_rand_seed = BraidRandom(async_rand_seed, ...)
\t\t\t\t\tstate.async_rand_draw_count = state.async_rand_draw_count + 1
\t\t\t\t\tstate.async_rand_final_seed = async_rand_seed
\t\t\t\t\treturn value
\t\t\t\tend
\t\t\t\tstate.foreign_async_rand_draw_count = state.foreign_async_rand_draw_count + 1
\t\t\t\treturn original_async_rand(...)
\t\t\tend
\t\t\trawset(_G, "AsyncRand", scoped_async_rand)
\t\t\tif rawget(_G, "AsyncRand") ~= scoped_async_rand then
\t\t\t\terror("scoped AsyncRand capture dispatcher did not install")
\t\t\tend
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
\t\t\t\tif rawget(_G, "AsyncRand") ~= scoped_async_rand then
\t\t\t\t\terror("scoped AsyncRand capture dispatcher was replaced before T1")
\t\t\t\tend
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
\t\t\t\t\t"async_rand_scope=" .. state.async_rand_scope,
\t\t\t\t\t"async_rand_initial_seed=" .. tostring(state.async_rand_initial_seed),
\t\t\t\t\t"async_rand_final_seed=" .. tostring(state.async_rand_final_seed),
\t\t\t\t\t"async_rand_draw_count=" .. tostring(state.async_rand_draw_count),
\t\t\t\t\t"foreign_async_rand_draw_count=" .. tostring(state.foreign_async_rand_draw_count),
\t\t\t\t\t"surface_stretch_done=" .. tostring(state.surface_stretch_done),
\t\t\t\t\t"surface_expansion_pending=" .. tostring(state.surface_expansion_pending),
\t\t\t\t\t"stretch_pipeline_pending=" .. tostring(state.stretch_pipeline_pending),
\t\t\t\t\t"post_pipeline_revalidation_complete=" .. tostring(state.post_pipeline_revalidation_complete),
\t\t\t\t\t"expansion_loading_visible=" .. tostring(state.expansion_loading_visible),
\t\t\t\t}}, "\\n") .. "\\n"
\t\t\t\tlocal write_error = AsyncStringToFile("{lua_path(stable_sentinel)}", text)
\t\t\t\tif write_error then error("stable sentinel write failed: " .. tostring(write_error)) end
\t\t\t\tstate.surface_stable_published = true
\t\t\t\treturn true
\t\t\tend)
\t\t\trawset(_G, "g_SmrRalphFinalizeReferenceCapture", function()
\t\t\t\tif state.surface_stable_published ~= true then
\t\t\t\t\terror("determinism finalizer cannot precede stable T1 publication")
\t\t\t\tend
\t\t\t\tlocal finalizer = rawget(_G, "g_FzpDeterminismCaptureFinalize")
\t\t\t\tif type(finalizer) ~= "function" then
\t\t\t\t\terror("determinism capture finalizer is unavailable")
\t\t\t\tend
\t\t\t\tlocal result = finalizer()
\t\t\t\tlocal finalized = rawget(_G, "g_FzpDeterminismCaptureFinalized") == true
\t\t\t\tlocal status = tostring(rawget(_G, "g_FzpDeterminismCaptureStatus"))
\t\t\t\tlocal capture_error = rawget(_G, "g_FzpDeterminismCaptureError")
\t\t\t\tif result ~= true or not finalized or status ~= "complete" or capture_error then
\t\t\t\t\terror("determinism capture finalization failed: result=" .. tostring(result)
\t\t\t\t\t\t.. " finalized=" .. tostring(finalized)
\t\t\t\t\t\t.. " status=" .. status
\t\t\t\t\t\t.. " error=" .. tostring(capture_error))
\t\t\t\tend
\t\t\t\tif rawget(_G, "AsyncRand") ~= scoped_async_rand then
\t\t\t\t\terror("scoped AsyncRand capture dispatcher was replaced before finalization")
\t\t\t\tend
\t\t\t\tif state.async_rand_draw_count <= 0 then
\t\t\t\t\terror("private mod RNG stream consumed no draws")
\t\t\t\tend
\t\t\t\trawset(_G, "AsyncRand", original_async_rand)
\t\t\t\tstate.async_rand_dispatcher_restored = rawget(_G, "AsyncRand") == original_async_rand
\t\t\t\tif not state.async_rand_dispatcher_restored then
\t\t\t\t\terror("original AsyncRand was not restored after capture")
\t\t\t\tend
\t\t\t\tlocal text = table.concat({{
\t\t\t\t\t"schema=smr.ralph.surface_loading_reference_final.v2",
\t\t\t\t\t"coordinate=" .. state.coordinate,
\t\t\t\t\t"surface_stable_published=" .. tostring(state.surface_stable_published),
\t\t\t\t\t"finalization_after_surface_stable=true",
\t\t\t\t\t"capture_finalized=" .. tostring(finalized),
\t\t\t\t\t"capture_status=" .. status,
\t\t\t\t\t"async_rand_scope=" .. state.async_rand_scope,
\t\t\t\t\t"async_rand_initial_seed=" .. tostring(state.async_rand_initial_seed),
\t\t\t\t\t"async_rand_final_seed=" .. tostring(state.async_rand_final_seed),
\t\t\t\t\t"async_rand_draw_count=" .. tostring(state.async_rand_draw_count),
\t\t\t\t\t"foreign_async_rand_draw_count=" .. tostring(state.foreign_async_rand_draw_count),
\t\t\t\t\t"async_rand_dispatcher_restored=" .. tostring(state.async_rand_dispatcher_restored),
\t\t\t\t}}, "\\n") .. "\\n"
\t\t\t\tlocal write_error = AsyncStringToFile("{lua_path(final_sentinel)}", text)
\t\t\t\tif write_error then error("final sentinel write failed: " .. tostring(write_error)) end
\t\t\t\tstate.capture_finalized = true
\t\t\t\treturn true
\t\t\tend)
\t\tend'''


def render_generation(
    capture_base: Path,
    stable_sentinel: Path,
    final_sentinel: Path,
    async_rand_seed: int = DEFAULT_ASYNC_RAND_SEED,
) -> str:
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
        capture_base, stable_sentinel, final_sentinel, async_rand_seed
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
    parity_complete = '''\t\tg_ParityStatus = "complete"
\tend, debug.traceback)'''
    if text.count(parity_complete) != 1:
        raise ReferenceError("parity completion marker changed")
    text = text.replace(
        parity_complete,
        '''\t\tlocal finalize_reference_capture = rawget(_G, "g_SmrRalphFinalizeReferenceCapture")
\t\tif type(finalize_reference_capture) ~= "function" then
\t\t\terror("reference capture finalizer is unavailable")
\t\tend
\t\tfinalize_reference_capture()

\t\tg_ParityStatus = "complete"
\tend, debug.traceback)''',
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


def exercise_scoped_dispatch(lua: Path) -> dict[str, object]:
    if not lua.is_file():
        raise ReferenceError(f"Lua interpreter missing: {lua}")
    script = r'''
local foreign_draws, private_draws, private_seed = 0, 0, 3
local function original_async_rand(n)
  foreign_draws = foreign_draws + 1
  return n - 1
end
rawset(_G, "AsyncRand", original_async_rand)
local Engine = {}
function Engine.RandInt(n)
  local async_rand = rawget(_G, "AsyncRand")
  local ok, value = pcall(async_rand, n)
  if ok and type(value) == "number" and value >= 0 and value < n then return value end
  error("invalid draw")
end
local mod_rand_int = Engine.RandInt
local function called_by_mod_rand_int()
  for level = 2, 8 do
    local ok, info = pcall(debug.getinfo, level, "f")
    if not ok or type(info) ~= "table" then break end
    if info.func == mod_rand_int then return true end
  end
  return false
end
local function scoped_async_rand(n)
  if called_by_mod_rand_int() then
    local value = private_seed % n
    private_seed = private_seed + 7
    private_draws = private_draws + 1
    return value
  end
  return original_async_rand(n)
end
rawset(_G, "AsyncRand", scoped_async_rand)
assert(Engine.RandInt(10) == 3)
assert(rawget(_G, "AsyncRand")(10) == 9)
assert(Engine.RandInt(10) == 0)
assert(private_draws == 2 and foreign_draws == 1 and private_seed == 17)
rawset(_G, "AsyncRand", original_async_rand)
assert(rawget(_G, "AsyncRand") == original_async_rand)
io.write("scoped_dispatch_ok")
'''
    proc = subprocess.run(
        [str(lua), "-"], input=script, capture_output=True, text=True, timeout=60
    )
    ok = proc.returncode == 0 and proc.stdout == "scoped_dispatch_ok" and not proc.stderr
    return {
        "ok": ok,
        "interpreter": str(lua),
        "stdout": proc.stdout,
        "stderr": proc.stderr,
        "returncode": proc.returncode,
        "private_draws": 2 if ok else None,
        "foreign_draws": 1 if ok else None,
        "dispatcher_restored": ok,
    }


def static_verdict(text: str) -> dict[str, object]:
    positions = {
        "new_game": text.find('NewGame({ seed_text = "LOZL3FQr" })'),
        "rough_rule": text.find('Game:AddGameRule("RoughTerrain")'),
        "preset_wrapper": text.find("GenerateRandomMap = function(map_name, preset_name, params)"),
        "async_rand_dispatcher": text.find('rawset(_G, "AsyncRand", scoped_async_rand)'),
        "generation": text.find("pcall(GenerateCurrentRandomMap)"),
        "stable_publish": text.find("publish_surface_stable(surface)"),
        "underground_visit": text.find('g_ParityStatus = "entering_underground"'),
        "finalizer_invoke": text.find("\n\t\tfinalize_reference_capture()"),
        "parity_complete": text.find('\n\t\tg_ParityStatus = "complete"'),
    }
    checks = {
        "coordinate_is_14N134W": f"latitude = {LAT}, longitude = {LON}" in text,
        "expanded_generation": "g_CurrentMapParams.SuperBigMapExpandMap = true or nil" in text,
        "rough_block_reused_once": text.count(run_parity.ROUGH_TERRAIN_BLOCK) == 1,
        "rough_activation_precedes_preset_and_generation": (
            0 <= positions["new_game"] < positions["rough_rule"]
            < positions["preset_wrapper"] < positions["generation"]
        ),
        "private_mod_stream_precedes_generation": (
            0 <= positions["new_game"] < positions["async_rand_dispatcher"]
            < positions["generation"]
            and text.count('rawset(_G, "AsyncRand", scoped_async_rand)') == 1
        ),
        "private_mod_stream_fail_closed": (
            'type(BraidRandom) ~= "function"' in text
            and 'type(original_async_rand) ~= "function"' in text
            and 'type(mod_rand_int) ~= "function"' in text
            and 'type(debug.getinfo) ~= "function"' in text
            and 'rawget(_G, "AsyncRand") ~= scoped_async_rand' in text
        ),
        "private_mod_stream_scoped_by_function_identity": (
            'info.func == mod_rand_int' in text
            and 'if called_by_mod_rand_int() then' in text
            and 'return original_async_rand(...)' in text
            and 'foreign_async_rand_draw_count' in text
            and "pinned_async_rand" not in text
        ),
        "private_mod_stream_state_recorded_twice": (
            text.count('"async_rand_scope="') == 2
            and text.count('"async_rand_initial_seed="') == 2
            and text.count('"async_rand_final_seed="') == 2
            and text.count('"async_rand_draw_count="') == 2
            and text.count('"foreign_async_rand_draw_count="') == 2
        ),
        "dispatcher_restored_after_verified_finalization": (
            'rawset(_G, "AsyncRand", original_async_rand)' in text
            and 'state.async_rand_dispatcher_restored = rawget(_G, "AsyncRand") == original_async_rand'
            in text
            and 'if state.async_rand_draw_count <= 0 then' in text
            and '"async_rand_dispatcher_restored="' in text
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
        "target_state_probe_absent": "g_FzpTargetObjectStateProbe" not in text,
        "finalizer_follows_stable_t1_and_underground": (
            0 <= positions["stable_publish"] < positions["underground_visit"]
            < positions["finalizer_invoke"] < positions["parity_complete"]
        ),
        "finalizer_fail_closed_and_single_invocation": (
            text.count("\n\t\tfinalize_reference_capture()") == 1
            and 'type(finalize_reference_capture) ~= "function"' in text
            and 'g_FzpDeterminismCaptureFinalized") == true' in text
            and 'status ~= "complete"' in text
        ),
        "distinct_final_sentinel_after_verified_finalization": (
            "smr.ralph.surface_loading_reference_final.v2" in text
            and "finalization_after_surface_stable=true" in text
            and "final sentinel write failed" in text
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
    final_sentinel = args.final_sentinel.resolve()
    text = render_generation(
        capture_base, stable_sentinel, final_sentinel, args.async_rand_seed
    )
    generation.write_text(text, encoding="utf-8")
    compile_lua(args.luac.resolve(), generation)
    verdict = static_verdict(text)
    if not verdict["ok"]:
        raise ReferenceError(f"rendered generation failed static checks: {verdict['failed']}")
    source_head = subprocess.check_output(
        ["git", "rev-parse", f"{args.source_head}^{{commit}}"],
        cwd=PROJECT,
        text=True,
        timeout=30,
    ).strip()
    manifest = {
        "schema": "smr.ralph.surface_loading_reference_manifest.v4",
        "source_head": source_head,
        "coordinate": COORDINATE,
        "latitude": LAT,
        "longitude": LON,
        "expanded": True,
        "rough_terrain_required": True,
        "selected_random_map_preset_required": EXPECTED_PRESET,
        "reference_underground_seed": REFERENCE_UNDERGROUND_SEED,
        "async_rand_scope": "mod_owned_engine_rand_int",
        "async_rand_seed": args.async_rand_seed,
        "generation_script": str(generation),
        "generation_script_bytes": generation.stat().st_size,
        "generation_script_sha256": sha256_file(generation),
        "capture_base": str(capture_base),
        "stable_sentinel": str(stable_sentinel),
        "final_sentinel": str(final_sentinel),
        "static_verdict": verdict,
        "luac": str(args.luac.resolve()),
    }
    write_json(args.out.resolve(), manifest)
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


def command_self_test(args: argparse.Namespace) -> int:
    py_compile.compile(str(Path(__file__).resolve()), doraise=True)
    probe = PARITY / "determinism_capture_probe.lua"
    compile_lua(args.luac.resolve(), probe)
    probe_sha256 = sha256_file(probe)
    dispatch_test = exercise_scoped_dispatch(args.luac.resolve().with_name("lua.exe"))
    TMP_ROOT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".tmp_surface_reference_selftest_", dir=TMP_ROOT) as raw:
        root = Path(raw)
        generation = root / "generation.lua"
        text = render_generation(
            root / "capture", root / "stable.sentinel", root / "final.sentinel"
        )
        generation.write_text(text, encoding="utf-8")
        compile_lua(args.luac.resolve(), generation)
        verdict = static_verdict(text)
        mutation = text.replace('expected_preset = "RoughTerrain"', 'expected_preset = "MAIN"', 1)
        mutation_red = static_verdict(mutation)["ok"] is False
        missing_finalizer = text.replace("\n\t\tfinalize_reference_capture()", "", 1)
        missing_finalizer_red = static_verdict(missing_finalizer)["ok"] is False
        missing_dispatcher = text.replace(
            '\n\t\t\trawset(_G, "AsyncRand", scoped_async_rand)', "", 1
        )
        missing_dispatcher_red = static_verdict(missing_dispatcher)["ok"] is False
        unscoped_dispatcher = text.replace(
            "if info.func == mod_rand_int then return true end",
            "if false then return true end",
            1,
        )
        unscoped_dispatcher_red = static_verdict(unscoped_dispatcher)["ok"] is False
        missing_foreign_forward = text.replace("return original_async_rand(...)", "return 0", 1)
        missing_foreign_forward_red = static_verdict(missing_foreign_forward)["ok"] is False
        verdict["lua_parse"] = True
        verdict["reference_probe_lua_parse"] = True
        verdict["reference_probe_sha256"] = probe_sha256
        verdict["reference_probe_sha256_expected"] = REFERENCE_PROBE_SHA256
        verdict["reference_probe_exact"] = probe_sha256 == REFERENCE_PROBE_SHA256
        verdict["python_compile"] = True
        verdict["wrong_preset_mutation_red"] = mutation_red
        verdict["missing_finalizer_mutation_red"] = missing_finalizer_red
        verdict["scoped_dispatch_runtime"] = dispatch_test
        verdict["missing_scoped_dispatcher_mutation_red"] = missing_dispatcher_red
        verdict["unscoped_dispatcher_mutation_red"] = unscoped_dispatcher_red
        verdict["missing_foreign_forward_mutation_red"] = missing_foreign_forward_red
        verdict["ok"] = (
            verdict["ok"]
            and mutation_red
            and missing_finalizer_red
            and dispatch_test["ok"]
            and missing_dispatcher_red
            and unscoped_dispatcher_red
            and missing_foreign_forward_red
            and verdict["reference_probe_exact"]
        )
    if args.out:
        write_json(args.out.resolve(), verdict)
    print(json.dumps(verdict, indent=2, sort_keys=True))
    return 0 if verdict["ok"] else 1


def load_capture_manifest(path: Path) -> tuple[dict[str, object], Path, str]:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ReferenceError(f"capture manifest must contain one object: {path}")
    script_value = manifest.get("generation_script")
    declared_sha256 = manifest.get("generation_script_sha256")
    if not isinstance(script_value, str) or not script_value:
        raise ReferenceError(f"capture manifest has no generation_script: {path}")
    if not isinstance(declared_sha256, str) or not declared_sha256:
        raise ReferenceError(f"capture manifest has no generation_script_sha256: {path}")
    script = Path(script_value).resolve()
    if not script.is_file():
        raise ReferenceError(f"generation script is missing: {script}")
    actual_sha256 = sha256_file(script)
    if actual_sha256 != declared_sha256.upper():
        raise ReferenceError(
            f"generation script hash mismatch for {script}: "
            f"{actual_sha256} != {declared_sha256}"
        )
    return manifest, script, actual_sha256


def normalize_output_identity(text: str, manifest: dict[str, object]) -> tuple[str, dict[str, int]]:
    counts: dict[str, int] = {}
    for field in ("capture_base", "stable_sentinel", "final_sentinel"):
        value = manifest.get(field)
        if not isinstance(value, str) or not value:
            raise ReferenceError(f"capture manifest has no {field}")
        rendered = lua_path(Path(value))
        counts[field] = text.count(rendered)
        text = text.replace(rendered, f"__OUTPUT_IDENTITY_{field.upper()}__")
    return text, counts


def command_verify_reference_equivalence(args: argparse.Namespace) -> int:
    reference, reference_script, reference_sha256 = load_capture_manifest(
        args.reference_manifest.resolve()
    )
    candidate, candidate_script, candidate_sha256 = load_capture_manifest(
        args.candidate_manifest.resolve()
    )
    reference_text = reference_script.read_text(encoding="utf-8")
    candidate_text = candidate_script.read_text(encoding="utf-8")
    normalized_reference, reference_counts = normalize_output_identity(
        reference_text, reference
    )
    normalized_candidate, candidate_counts = normalize_output_identity(
        candidate_text, candidate
    )
    probe = PARITY / "determinism_capture_probe.lua"
    probe_text = probe.read_text(encoding="utf-8")
    probe_sha256 = sha256_file(probe)
    checks = {
        "reference_generation_is_pinned_iteration_4": (
            reference_sha256 == REFERENCE_GENERATION_SHA256
        ),
        "raw_generation_scripts_are_distinct": reference_sha256 != candidate_sha256,
        "reference_output_identities_occur_once": all(
            count == 1 for count in reference_counts.values()
        ),
        "candidate_output_identities_occur_once": all(
            count == 1 for count in candidate_counts.values()
        ),
        "normalized_generation_scripts_are_exact": (
            normalized_reference == normalized_candidate
        ),
        "candidate_has_no_target_state_probe": (
            "g_FzpTargetObjectStateProbe" not in candidate_text
        ),
        "probe_is_exact_reference_era_source": probe_sha256 == REFERENCE_PROBE_SHA256,
        "probe_has_no_target_state_probe": "g_FzpTargetObjectStateProbe" not in probe_text,
    }
    failed = sorted(name for name, passed in checks.items() if not passed)
    report = {
        "schema": "smr.ralph.observer_free_capture_equivalence.v1",
        "ok": not failed,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "allowed_differences": ["capture_base", "stable_sentinel", "final_sentinel"],
        "reference": {
            "manifest": str(args.reference_manifest.resolve()),
            "generation_script": str(reference_script),
            "generation_script_bytes": reference_script.stat().st_size,
            "generation_script_sha256": reference_sha256,
            "output_identity_occurrences": reference_counts,
        },
        "candidate": {
            "manifest": str(args.candidate_manifest.resolve()),
            "generation_script": str(candidate_script),
            "generation_script_bytes": candidate_script.stat().st_size,
            "generation_script_sha256": candidate_sha256,
            "output_identity_occurrences": candidate_counts,
        },
        "probe": {
            "path": str(probe),
            "sha256": probe_sha256,
            "expected_reference_sha256": REFERENCE_PROBE_SHA256,
        },
    }
    write_json(args.out.resolve(), report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["ok"] else 1


def command_verify_paired_inputs(args: argparse.Namespace) -> int:
    first, first_script, first_sha256 = load_capture_manifest(args.first.resolve())
    second, second_script, second_sha256 = load_capture_manifest(args.second.resolve())
    first_text = first_script.read_text(encoding="utf-8")
    second_text = second_script.read_text(encoding="utf-8")
    normalized_first, first_counts = normalize_output_identity(first_text, first)
    normalized_second, second_counts = normalize_output_identity(second_text, second)
    expected_source_head = subprocess.check_output(
        ["git", "rev-parse", f"{args.expected_source_head}^{{commit}}"],
        cwd=PROJECT,
        text=True,
        timeout=30,
    ).strip()
    checks = {
        "manifest_schema_v4": (
            first.get("schema") == "smr.ralph.surface_loading_reference_manifest.v4"
            and second.get("schema") == "smr.ralph.surface_loading_reference_manifest.v4"
        ),
        "source_head_exact": (
            first.get("source_head") == expected_source_head
            and second.get("source_head") == expected_source_head
        ),
        "async_rand_seed_exact": (
            first.get("async_rand_seed") == args.expected_async_rand_seed
            and second.get("async_rand_seed") == args.expected_async_rand_seed
        ),
        "async_rand_scope_is_private_mod_stream": (
            first.get("async_rand_scope") == "mod_owned_engine_rand_int"
            and second.get("async_rand_scope") == "mod_owned_engine_rand_int"
        ),
        "raw_generation_scripts_are_distinct": first_sha256 != second_sha256,
        "first_output_identities_occur_once": all(
            count == 1 for count in first_counts.values()
        ),
        "second_output_identities_occur_once": all(
            count == 1 for count in second_counts.values()
        ),
        "normalized_generation_scripts_are_exact": (
            normalized_first == normalized_second
        ),
        "static_verdicts_green": (
            isinstance(first.get("static_verdict"), dict)
            and first["static_verdict"].get("ok") is True
            and isinstance(second.get("static_verdict"), dict)
            and second["static_verdict"].get("ok") is True
        ),
        "target_state_probe_absent": (
            "g_FzpTargetObjectStateProbe" not in first_text
            and "g_FzpTargetObjectStateProbe" not in second_text
        ),
    }
    failed = sorted(name for name, passed in checks.items() if not passed)
    report = {
        "schema": "smr.ralph.paired_capture_inputs.v1",
        "ok": not failed,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "expected_source_head": expected_source_head,
        "expected_async_rand_seed": args.expected_async_rand_seed,
        "allowed_differences": ["capture_base", "stable_sentinel", "final_sentinel"],
        "first": {
            "manifest": str(args.first.resolve()),
            "generation_script": str(first_script),
            "generation_script_sha256": first_sha256,
            "output_identity_occurrences": first_counts,
        },
        "second": {
            "manifest": str(args.second.resolve()),
            "generation_script": str(second_script),
            "generation_script_sha256": second_sha256,
            "output_identity_occurrences": second_counts,
        },
    }
    write_json(args.out.resolve(), report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["ok"] else 1


def parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="command", required=True)
    prepare = sub.add_parser("prepare")
    prepare.add_argument("--staging", type=Path, required=True)
    prepare.add_argument("--capture-base", type=Path, required=True)
    prepare.add_argument("--stable-sentinel", type=Path, required=True)
    prepare.add_argument("--final-sentinel", type=Path, required=True)
    prepare.add_argument("--async-rand-seed", type=int, required=True)
    prepare.add_argument("--source-head", required=True)
    prepare.add_argument("--out", type=Path, required=True)
    prepare.add_argument("--luac", type=Path, default=DEFAULT_LUAC)
    prepare.set_defaults(func=command_prepare)
    self_test = sub.add_parser("self-test")
    self_test.add_argument("--out", type=Path)
    self_test.add_argument("--luac", type=Path, default=DEFAULT_LUAC)
    self_test.set_defaults(func=command_self_test)
    verify = sub.add_parser("verify-reference-equivalence")
    verify.add_argument("--reference-manifest", type=Path, required=True)
    verify.add_argument("--candidate-manifest", type=Path, required=True)
    verify.add_argument("--out", type=Path, required=True)
    verify.set_defaults(func=command_verify_reference_equivalence)
    paired = sub.add_parser("verify-paired-inputs")
    paired.add_argument("--first", type=Path, required=True)
    paired.add_argument("--second", type=Path, required=True)
    paired.add_argument("--expected-source-head", required=True)
    paired.add_argument("--expected-async-rand-seed", type=int, required=True)
    paired.add_argument("--out", type=Path, required=True)
    paired.set_defaults(func=command_verify_paired_inputs)
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

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
# 59d108a deliberately added the post-checkpoint guard-loader seam to the
# observer-free probe.  Pin the resulting source rather than bypassing this
# self-test when the probe evolves.
REFERENCE_PROBE_SHA256 = "66E911640EE16503738D09A7D2329F2D4C6F88F3655BC817ADE61008552D0C7A"
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


def load_surface_thread_trace(path: Path) -> list[tuple[list[int], int]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "schema=smr.ralph.surface_thread_async_rand_trace.v1":
        raise ReferenceError(f"invalid surface-thread RNG trace header: {path}")
    calls: list[tuple[list[int], int]] = []
    for line_no, line in enumerate(lines[1:], 2):
        fields = line.split("\t")
        if len(fields) < 3 or fields[0] != "draw":
            raise ReferenceError(f"invalid surface-thread RNG trace row {line_no}: {path}")
        try:
            argc = int(fields[1])
            values = [int(value) for value in fields[2:]]
        except ValueError as exc:
            raise ReferenceError(
                f"non-integer surface-thread RNG trace row {line_no}: {path}"
            ) from exc
        if argc < 0 or len(values) != argc + 1:
            raise ReferenceError(f"wrong surface-thread RNG arity at row {line_no}: {path}")
        calls.append((values[:-1], values[-1]))
    if not calls:
        raise ReferenceError(f"surface-thread RNG trace contains no draws: {path}")
    return calls


def surface_thread_rng_lua(mode: str, trace_path: Path | None) -> tuple[str, str, str]:
    if mode == "forward":
        if trace_path is not None:
            raise ReferenceError("surface-thread RNG trace is invalid in forward mode")
        return "", "", ""
    if mode not in {"record", "replay"} or trace_path is None:
        raise ReferenceError("surface-thread RNG mode record/replay requires a trace path")
    replay_calls = load_surface_thread_trace(trace_path) if mode == "replay" else []
    replay_rows = ",\n".join(
        "\t\t\t\t{ args = { "
        + ", ".join(str(value) for value in args)
        + " }, value = "
        + str(value)
        + " }"
        for args, value in replay_calls
    )
    if not replay_rows:
        replay_rows = "\t\t\t\t"
    census_path = trace_path.with_suffix(".scheduler_census.txt")
    census_nonce = hashlib.sha256(str(census_path).encode("utf-8")).hexdigest()[:16]
    setup = f'''
\t\t\tlocal surface_thread_rng_mode = "{mode}"
\t\t\tlocal surface_thread_rng_trace = {{
{replay_rows}
\t\t\t}}
\t\t\tlocal surface_thread_rng_index = 0
\t\t\tlocal surface_generation_thread = false
\t\t\tlocal current_thread = rawget(_G, "CurrentThread")
\t\t\tlocal original_create_real_time_thread = rawget(_G, "CreateRealTimeThread")
\t\t\tlocal original_global = rawget(_G, "Global")
\t\t\tlocal surface_scheduler = type(SBM) == "table" and type(SBM.Generation) == "table"
\t\t\t\tand SBM.Generation.RunSurfaceStretchIfEnabled or nil
\t\t\tif type(current_thread) ~= "function" then
\t\t\t\terror("CurrentThread unavailable for surface-generation RNG scope")
\t\t\tend
\t\t\tif type(original_create_real_time_thread) ~= "function" then
\t\t\t\terror("CreateRealTimeThread unavailable for surface-generation RNG scope")
\t\t\tend
\t\t\tif type(original_global) ~= "function" then
\t\t\t\terror("Global unavailable for surface scheduler census")
\t\t\tend
\t\t\tif type(surface_scheduler) ~= "function" then
\t\t\t\terror("RunSurfaceStretchIfEnabled unavailable for surface-generation RNG scope")
\t\t\tend
\t\t\tlocal scheduler_census_nonce = "{census_nonce}"
\t\t\tlocal scheduler_census_rows = {{
\t\t\t\t"schema=smr.ralph.surface_scheduler_census.v1",
\t\t\t\t"nonce=" .. scheduler_census_nonce,
\t\t\t\t"setup_executed=true",
\t\t\t}}
\t\t\tlocal scheduler_lookup_count = 0
\t\t\tlocal function write_scheduler_census(stage)
\t\t\t\tscheduler_census_rows[#scheduler_census_rows + 1] = "stage=" .. tostring(stage)
\t\t\t\tscheduler_census_rows[#scheduler_census_rows + 1] =
\t\t\t\t\t"lookup_count=" .. tostring(scheduler_lookup_count)
\t\t\t\tlocal census_error = AsyncStringToFile("{lua_path(census_path)}",
\t\t\t\t\ttable.concat(scheduler_census_rows, "\\n") .. "\\n")
\t\t\t\tif census_error then
\t\t\t\t\terror("surface scheduler census write failed: " .. tostring(census_error))
\t\t\t\tend
\t\t\tend
\t\t\tlocal function append_scheduler_stack(event_index)
\t\t\t\tfor level = 2, 16 do
\t\t\t\t\tlocal ok, info = pcall(debug.getinfo, level, "nSfl")
\t\t\t\t\tif not ok or type(info) ~= "table" then break end
\t\t\t\t\tscheduler_census_rows[#scheduler_census_rows + 1] = table.concat({{
\t\t\t\t\t\t"frame", tostring(event_index), tostring(level),
\t\t\t\t\t\ttostring(info.name), tostring(info.short_src),
\t\t\t\t\t\ttostring(info.linedefined), tostring(info.currentline),
\t\t\t\t\t\ttostring(info.func == surface_scheduler),
\t\t\t\t\t}}, "\\t")
\t\t\t\tend
\t\t\tend
\t\t\tlocal function called_by_surface_scheduler()
\t\t\t\tfor level = 2, 12 do
\t\t\t\t\tlocal ok, info = pcall(debug.getinfo, level, "f")
\t\t\t\t\tif not ok or type(info) ~= "table" then break end
\t\t\t\t\tif info.func == surface_scheduler then return true end
\t\t\t\tend
\t\t\t\treturn false
\t\t\tend
\t\t\tlocal scoped_create_real_time_thread
\t\t\tlocal scoped_global
\t\t\tscoped_global = function(name, ...)
\t\t\t\tlocal value = original_global(name, ...)
\t\t\t\tif name == "CreateRealTimeThread" then
\t\t\t\t\tscheduler_lookup_count = scheduler_lookup_count + 1
\t\t\t\t\tstate.surface_scheduler_global_lookup_count = scheduler_lookup_count
\t\t\t\t\tscheduler_census_rows[#scheduler_census_rows + 1] = table.concat({{
\t\t\t\t\t\t"lookup", tostring(scheduler_lookup_count),
\t\t\t\t\t\t"returned_scoped=" .. tostring(value == scoped_create_real_time_thread),
\t\t\t\t\t\t"returned_original=" .. tostring(value == original_create_real_time_thread),
\t\t\t\t\t\t"raw_scoped=" .. tostring(rawget(_G, "CreateRealTimeThread") == scoped_create_real_time_thread),
\t\t\t\t\t}}, "\\t")
\t\t\t\t\tappend_scheduler_stack(scheduler_lookup_count)
\t\t\t\t\twrite_scheduler_census("global_lookup")
\t\t\t\tend
\t\t\t\treturn value
\t\t\tend
\t\t\tscoped_create_real_time_thread = function(fn, ...)
\t\t\t\tif not called_by_surface_scheduler() then
\t\t\t\t\treturn original_create_real_time_thread(fn, ...)
\t\t\t\tend
\t\t\t\tif state.surface_generation_thread_scheduled then
\t\t\t\t\terror("surface-generation thread scheduled more than once")
\t\t\t\tend
\t\t\t\tstate.surface_generation_thread_scheduled = true
\t\t\t\trawset(_G, "CreateRealTimeThread", original_create_real_time_thread)
\t\t\t\tif rawget(_G, "Global") == scoped_global then
\t\t\t\t\trawset(_G, "Global", original_global)
\t\t\t\tend
\t\t\t\tstate.create_thread_dispatcher_restored =
\t\t\t\t\trawget(_G, "CreateRealTimeThread") == original_create_real_time_thread
\t\t\t\tstate.global_dispatcher_restored = rawget(_G, "Global") == original_global
\t\t\t\tif not state.create_thread_dispatcher_restored then
\t\t\t\t\terror("CreateRealTimeThread dispatcher did not restore")
\t\t\t\tend
\t\t\t\twrite_scheduler_census("scheduler_intercepted")
\t\t\t\treturn original_create_real_time_thread(function(...)
\t\t\t\t\tsurface_generation_thread = current_thread()
\t\t\t\t\tstate.surface_generation_thread_identified =
\t\t\t\t\t\tsurface_generation_thread ~= nil and surface_generation_thread ~= false
\t\t\t\t\tif not state.surface_generation_thread_identified then
\t\t\t\t\t\terror("CurrentThread returned no surface-generation identity")
\t\t\t\t\tend
\t\t\t\t\treturn fn(...)
\t\t\t\tend, ...)
\t\t\tend
\t\t\trawset(_G, "Global", scoped_global)
\t\t\tif rawget(_G, "Global") ~= scoped_global then
\t\t\t\terror("Global scheduler census dispatcher did not install")
\t\t\tend
\t\t\trawset(_G, "CreateRealTimeThread", scoped_create_real_time_thread)
\t\t\tif rawget(_G, "CreateRealTimeThread") ~= scoped_create_real_time_thread then
\t\t\t\terror("CreateRealTimeThread capture dispatcher did not install")
\t\t\tend
\t\t\tstate.surface_scheduler_census_nonce = scheduler_census_nonce
\t\t\tstate.global_dispatcher_installed = true
\t\t\twrite_scheduler_census("setup")'''
    dispatch = '''
\t\t\t\tif surface_generation_thread and current_thread() == surface_generation_thread then
\t\t\t\t\tsurface_thread_rng_index = surface_thread_rng_index + 1
\t\t\t\t\tstate.surface_thread_async_rand_draw_count = surface_thread_rng_index
\t\t\t\t\tlocal args = { ... }
\t\t\t\t\tif surface_thread_rng_mode == "record" then
\t\t\t\t\t\tlocal value = original_async_rand(...)
\t\t\t\t\t\tsurface_thread_rng_trace[surface_thread_rng_index] = { args = args, value = value }
\t\t\t\t\t\treturn value
\t\t\t\t\tend
\t\t\t\t\tlocal expected = surface_thread_rng_trace[surface_thread_rng_index]
\t\t\t\t\tif type(expected) ~= "table" or type(expected.args) ~= "table"
\t\t\t\t\t\tor #expected.args ~= #args then
\t\t\t\t\t\terror("surface-thread AsyncRand replay exhausted or arity changed at draw "
\t\t\t\t\t\t\t.. tostring(surface_thread_rng_index))
\t\t\t\t\tend
\t\t\t\t\tfor i = 1, #args do
\t\t\t\t\t\tif expected.args[i] ~= args[i] then
\t\t\t\t\t\t\terror("surface-thread AsyncRand replay argument changed at draw "
\t\t\t\t\t\t\t\t.. tostring(surface_thread_rng_index) .. " argument " .. tostring(i))
\t\t\t\t\t\tend
\t\t\t\t\tend
\t\t\t\t\treturn expected.value
\t\t\t\tend'''
    finalize = f'''
\t\t\t\twrite_scheduler_census("finalizer_entry")
\t\t\t\tif state.surface_generation_thread_scheduled ~= true
\t\t\t\t\tor state.surface_generation_thread_identified ~= true
\t\t\t\t\tor state.create_thread_dispatcher_restored ~= true then
\t\t\t\t\terror("surface-generation thread discriminator did not complete")
\t\t\t\tend
\t\t\t\tif surface_thread_rng_index <= 0 then
\t\t\t\t\terror("surface-generation thread consumed no direct AsyncRand draws")
\t\t\t\tend
\t\t\t\tif surface_thread_rng_mode == "replay"
\t\t\t\t\tand surface_thread_rng_index ~= #surface_thread_rng_trace then
\t\t\t\t\terror("surface-thread AsyncRand replay left unused draws: consumed="
\t\t\t\t\t\t.. tostring(surface_thread_rng_index) .. " expected="
\t\t\t\t\t\t.. tostring(#surface_thread_rng_trace))
\t\t\t\tend
\t\t\t\tif surface_thread_rng_mode == "record" then
\t\t\t\t\tlocal rows = {{ "schema=smr.ralph.surface_thread_async_rand_trace.v1" }}
\t\t\t\t\tfor i = 1, #surface_thread_rng_trace do
\t\t\t\t\t\tlocal record = surface_thread_rng_trace[i]
\t\t\t\t\t\tlocal fields = {{ "draw", tostring(#record.args) }}
\t\t\t\t\t\tfor j = 1, #record.args do fields[#fields + 1] = tostring(record.args[j]) end
\t\t\t\t\t\tfields[#fields + 1] = tostring(record.value)
\t\t\t\t\t\trows[#rows + 1] = table.concat(fields, "\\t")
\t\t\t\t\tend
\t\t\t\t\tlocal trace_error = AsyncStringToFile("{lua_path(trace_path)}",
\t\t\t\t\t\ttable.concat(rows, "\\n") .. "\\n")
\t\t\t\t\tif trace_error then error("surface-thread RNG trace write failed: "
\t\t\t\t\t\t.. tostring(trace_error)) end
\t\t\t\tend'''
    return setup, dispatch, finalize


def scheduler_census_lua(census_path: Path | None) -> tuple[str, str]:
    """Return forward-safe scheduler census instrumentation.

    This is deliberately independent of the RNG trace modes: surface-only
    acceptance needs a scheduler receipt while keeping trace collection off.
    It chains the production-proven MapGenerated/CityInitialized callbacks,
    observes only their delivery, and never changes dispatchers or RNG.
    """
    if census_path is None:
        return "", ""
    nonce = hashlib.sha256(str(census_path.resolve()).encode("utf-8")).hexdigest()[:16]
    setup = f'''
\t\t\tlocal surface_scheduler_census_path = "{lua_path(census_path)}"
\t\t\tlocal surface_scheduler_census_nonce = "{nonce}"
\t\t\tlocal census_chain = type(SBM) == "table" and type(SBM.Engine) == "table"
\t\t\t\tand SBM.Engine.ChainOnMsg or nil
\t\t\tif type(census_chain) ~= "function" or type(rawget(_G, "OnMsg")) ~= "table" then
\t\t\t\terror("surface scheduler census callback capabilities unavailable")
\t\t\tend
\t\t\tlocal census_rows = {{
\t\t\t\t"schema=smr.ralph.surface_scheduler_census.v1",
\t\t\t\t"nonce=" .. surface_scheduler_census_nonce,
\t\t\t\t"setup_executed=true",
\t\t\t\t"mechanism=Engine.ChainOnMsg",
\t\t\t}}
\t\t\tlocal function write_scheduler_census(stage)
\t\t\t\tcensus_rows[#census_rows + 1] = "stage=" .. tostring(stage)
\t\t\t\tcensus_rows[#census_rows + 1] = "map_generated_callbacks=" .. tostring(state.surface_scheduler_census_map_generated or 0)
\t\t\t\tcensus_rows[#census_rows + 1] = "city_initialized_callbacks=" .. tostring(state.surface_scheduler_census_city_initialized or 0)
\t\t\t\tlocal err = AsyncStringToFile(surface_scheduler_census_path, table.concat(census_rows, "\\n") .. "\\n")
\t\t\t\tif err then error("surface scheduler census write failed: " .. tostring(err)) end
\t\t\tend
\t\t\tcensus_chain("MapGenerated", function()
\t\t\t\tstate.surface_scheduler_census_map_generated = (state.surface_scheduler_census_map_generated or 0) + 1
\t\t\t\tif state.surface_scheduler_census_map_generated > 1 then error("surface scheduler census duplicate MapGenerated") end
\t\t\tend)
\t\t\tcensus_chain("CityInitialized", function()
\t\t\t\tstate.surface_scheduler_census_city_initialized = (state.surface_scheduler_census_city_initialized or 0) + 1
\t\t\t\tif state.surface_scheduler_census_city_initialized > 1 then error("surface scheduler census duplicate CityInitialized") end
\t\t\tend)
\t\t\tstate.surface_scheduler_census_nonce = surface_scheduler_census_nonce
\t\t\tstate.surface_scheduler_census_setup = true'''
    finalize = '''
\t\t\twrite_scheduler_census("post_t1_finalizer")
\t\t\tif state.surface_scheduler_census_map_generated ~= 1
\t\t\t\tor state.surface_scheduler_census_city_initialized ~= 1 then
\t\t\t\terror("surface scheduler census did not complete")
\t\t\tend'''
    return setup, finalize


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
    surface_thread_rng_mode: str = "forward",
    surface_thread_rng_trace: Path | None = None,
    scheduler_census_path: Path | None = None,
    surface_only: bool = False,
) -> str:
    probe = PARITY / "determinism_capture_probe.lua"
    thread_setup, thread_dispatch, thread_finalize = surface_thread_rng_lua(
        surface_thread_rng_mode, surface_thread_rng_trace
    )
    census_setup, census_finalize = scheduler_census_lua(scheduler_census_path)
    capture_arm = "" if surface_only else f'''
\t\t\trawset(_G, "g_FzpDeterminismCaptureOutBase", "{lua_path(capture_base)}")
\t\t\tlocal probe_result = dofile("{lua_path(probe)}")
\t\t\tif probe_result ~= "fzp_determinism_capture_armed" then
\t\t\t\terror("determinism capture producer did not arm: " .. tostring(probe_result))
\t\t\tend'''
    surface_only_finalize = "" if not surface_only else f'''
\t\t\t\tif true then
\t\t\t\tif rawget(_G, "AsyncRand") ~= scoped_async_rand then error("AsyncRand changed before surface-only finalizer") end
\t\t\t\tif state.async_rand_draw_count <= 0 then error("private mod RNG stream consumed no draws") end{thread_finalize}{census_finalize}
\t\t\t\trawset(_G, "AsyncRand", original_async_rand)
\t\t\t\tstate.async_rand_dispatcher_restored = rawget(_G, "AsyncRand") == original_async_rand
\t\t\t\tif state.async_rand_dispatcher_restored ~= true then error("AsyncRand restore failed") end
\t\t\t\t-- Scalar-only and deliberately post-T1: no capture, tracing, or scan can
\t\t\t\t-- perturb the acceptance timing window.
\t\t\t\tlocal surface = state.surface_at_t1
\t\t\t\tlocal report = type(surface) == "table" and surface.SuperBigMapLazyUndergroundFeasibilityReport or nil
\t\t\t\tlocal helper = type(surface) == "table" and surface.SuperBigMapSurfaceSingleFlushReport or nil
\t\t\t\tif type(report) ~= "table" or type(helper) ~= "table" then
\t\t\t\t\terror("surface-only single-flush report/helper unavailable after T1")
\t\t\t\tend
\t\t\t\tlocal function scalar(rows, name, value)
\t\t\t\t\tlocal kind = type(value)
\t\t\t\t\tif value == nil or (kind ~= "string" and kind ~= "number" and kind ~= "boolean") then
\t\t\t\t\t\terror("surface-only scalar missing/unknown field: " .. tostring(name))
\t\t\t\t\tend
\t\t\t\t\tlocal text_value = tostring(value)
\t\t\t\t\tif string.find(text_value, "[\\r\\n]") then
\t\t\t\t\t\terror("surface-only scalar field contains newline: " .. tostring(name))
\t\t\t\t\tend
\t\t\t\t\trows[#rows + 1] = tostring(name) .. "=" .. text_value
\t\t\t\t\treturn value
\t\t\t\tend
\t\t\t\tlocal rows = {{
\t\t\t\t\t"schema=smr.ralph.surface_only_single_flush_scalar.v1",
\t\t\t\t\t"surface_stable_published=true", "post_t1_only=true",
\t\t\t\t\t"pre_t1_capture_bytes=0", "capture_status=surface-only-none",
\t\t\t\t\t"async_rand_draw_count=" .. tostring(state.async_rand_draw_count),
\t\t\t\t\t"async_rand_dispatcher_restored=true",
\t\t\t\t}}
\t\t\t\tlocal main_fields = {{
\t\t\t\t\t"surface_single_flush_requested", "surface_single_flush_used", "surface_single_flush_fallback", "surface_single_flush_fallback_reason",
\t\t\t\t\t"surface_single_flush_local_passability_calls", "surface_single_flush_buildable_calls", "surface_single_flush_height_snapshots", "surface_single_flush_height_mismatches",
\t\t\t\t\t"surface_single_flush_object_family_count", "surface_single_flush_object_association_failures", "surface_single_flush_provenance_exact", "surface_single_flush_dirty_digest",
\t\t\t\t\t"surface_single_flush_dirty_regions", "surface_single_flush_coverage_permille", "surface_single_flush_closing_complete", "surface_single_flush_cleanup_complete",
\t\t\t\t\t"outer_passage_pad_finalization_dirty_digest", "canonical_rebuilds_during_capsule_prepare", "canonical_rebuild_fallbacks_during_capsule_prepare",
\t\t\t\t\t"fresh_grid_first_rebuild_ms", "fresh_grid_main_plan_ms", "fresh_grid_replay_ms", "fresh_grid_publication_ms", "fresh_grid_plan_replay_publication_ms",
\t\t\t\t\t"fresh_grid_closing_rebuild_ms", "fresh_grid_orchestration_total_ms", "fresh_grid_phase_order", "fresh_grid_expected_rebuilds",
\t\t\t\t\t"fresh_grid_rebuild_shape_exact", "fresh_grid_first_rebuild_complete", "fresh_grid_closing_rebuild_complete",
\t\t\t\t}}
\t\t\t\tfor i = 1, #main_fields do
\t\t\t\t\tlocal name = main_fields[i]
\t\t\t\t\tscalar(rows, name, report[name])
\t\t\t\tend
\t\t\t\tlocal helper_fields = {{
\t\t\t\t\t"schema", "requested", "used", "phase", "error", "fallback", "provenance_exact", "dirty_digest", "regions", "terrain_cells",
\t\t\t\t\t"coverage_permille", "dependency_margin", "height_snapshots", "height_mismatches", "object_family_count", "object_association_failures",
\t\t\t\t\t"object_containment_failures", "passability_calls", "buildable_calls", "preplan_complete", "closing_complete", "cleanup_complete",
\t\t\t\t}}
\t\t\t\tfor i = 1, #helper_fields do
\t\t\t\t\tlocal name = helper_fields[i]
\t\t\t\t\tscalar(rows, "helper_" .. name, helper[name])
\t\t\t\tend
\t\t\t\tif tonumber(helper.schema) ~= 1
\t\t\t\t\tor (helper.phase ~= "preplan" and helper.phase ~= "closing") then
\t\t\t\t\terror("surface-only helper schema/phase is unknown")
\t\t\t\tend
\t\t\t\tlocal optimized = report.surface_single_flush_requested == true
\t\t\t\t\tand report.surface_single_flush_used == true and report.surface_single_flush_fallback ~= true
\t\t\t\t\tand report.surface_single_flush_provenance_exact == true
\t\t\t\t\tand tonumber(report.surface_single_flush_local_passability_calls) == 4
\t\t\t\t\tand tonumber(report.surface_single_flush_buildable_calls) == 2
\t\t\t\t\tand tonumber(report.surface_single_flush_height_snapshots) == 2
\t\t\t\t\tand tonumber(report.surface_single_flush_height_mismatches) == 0
\t\t\t\t\tand tonumber(report.surface_single_flush_object_family_count) == 6
\t\t\t\t\tand tonumber(report.surface_single_flush_object_association_failures) == 0
\t\t\t\t\tand tonumber(helper.object_containment_failures) == 0
\t\t\t\t\tand tonumber(report.surface_single_flush_dirty_digest) == tonumber(report.outer_passage_pad_finalization_dirty_digest)
\t\t\t\t\tand tonumber(report.surface_single_flush_dirty_regions) == 2
\t\t\t\t\tand (tonumber(report.surface_single_flush_coverage_permille) or 0) > 0
\t\t\t\t\tand (tonumber(report.surface_single_flush_coverage_permille) or 151) <= 150
\t\t\t\t\tand report.surface_single_flush_closing_complete == true and report.surface_single_flush_cleanup_complete == true
\t\t\t\t\tand tonumber(report.canonical_rebuilds_during_capsule_prepare) == 0
\t\t\t\t\tand tonumber(report.canonical_rebuild_fallbacks_during_capsule_prepare) == 0
\t\t\t\t\tand tonumber(report.fresh_grid_expected_rebuilds) == 0 and report.fresh_grid_rebuild_shape_exact == true
\t\t\t\t\tand report.fresh_grid_first_rebuild_complete == true and report.fresh_grid_closing_rebuild_complete == true
\t\t\t\t\tand report.fresh_grid_phase_order == "local-dirty-grid-publication>fresh-plan-replay>capsule-publication>local-dirty-closing"
\t\t\t\tlocal canonical = report.surface_single_flush_requested == true
\t\t\t\t\tand report.surface_single_flush_used ~= true and report.surface_single_flush_fallback == true
\t\t\t\t\tand tostring(report.surface_single_flush_fallback_reason or "") ~= ""
\t\t\t\t\tand tonumber(report.canonical_rebuilds_during_capsule_prepare) >= 1
\t\t\t\t\tand tonumber(report.canonical_rebuilds_during_capsule_prepare) <= 2
\t\t\t\t\tand tonumber(report.canonical_rebuild_fallbacks_during_capsule_prepare) == 0
\t\t\t\t\tand tonumber(report.fresh_grid_expected_rebuilds) == tonumber(report.canonical_rebuilds_during_capsule_prepare)
\t\t\t\t\tand report.fresh_grid_rebuild_shape_exact == true and report.fresh_grid_first_rebuild_complete == true
\t\t\t\t\tand report.fresh_grid_closing_rebuild_complete == true
\t\t\t\t\tand report.fresh_grid_phase_order == "canonical-grid-publication>fresh-plan-replay>capsule-publication>closing-rebuild"
\t\t\t\tif not optimized and not canonical then
\t\t\t\t\terror("surface-only single-flush tuple is neither exact optimized nor canonical fallback")
\t\t\t\tend
\t\t\t\tscalar(rows, "tuple", optimized and "optimized" or "canonical-fallback")
\t\t\t\tscalar(rows, "caller_fallback_reason", report.surface_single_flush_fallback_reason)
\t\t\t\tscalar(rows, "comparison_ms", report.fresh_grid_plan_replay_publication_ms)
\t\t\t\tscalar(rows, "proof_ms", report.fresh_grid_orchestration_total_ms)
\t\t\t\tlocal text = table.concat(rows, "\\n") .. "\\n"
\t\t\t\tlocal write_error = AsyncStringToFile("{lua_path(final_sentinel)}", text)
\t\t\t\tif write_error then error("surface-only scalar write failed: " .. tostring(write_error)) end
\t\t\t\treturn true
\t\t\t\telse'''
    surface_only_finalize_close = "" if not surface_only else '''
\t\t\t\tend'''
    thread_state = "" if surface_thread_rng_mode == "forward" else f'''
\t\t\t\tsurface_thread_rng_mode = "{surface_thread_rng_mode}",
\t\t\t\tsurface_thread_async_rand_draw_count = 0,'''
    thread_sentinel = "" if surface_thread_rng_mode == "forward" else '''
\t\t\t\t\t"surface_thread_rng_mode=" .. state.surface_thread_rng_mode,
\t\t\t\t\t"surface_thread_async_rand_draw_count=" .. tostring(state.surface_thread_async_rand_draw_count),'''
    return f'''\t\tdo
\t\t\tlocal state = {{
\t\t\t\tschema = "smr.ralph.surface_loading_reference_state.v4",
\t\t\t\tcoordinate = "{COORDINATE}", latitude = {LAT}, longitude = {LON},
\t\t\t\texpected_preset = "{EXPECTED_PRESET}", selected_preset = false,
\t\t\t\tasync_rand_scope = "mod_owned_engine_rand_int",
\t\t\t\tasync_rand_initial_seed = {async_rand_seed},
\t\t\t\tasync_rand_final_seed = {async_rand_seed},
\t\t\t\tasync_rand_draw_count = 0,
\t\t\t\tforeign_async_rand_draw_count = 0,{thread_state}
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
\t\t\tend{thread_setup}{census_setup}
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
\t\t\t\tend{thread_dispatch}
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
{capture_arm}
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
\t\t\t\tstate.surface_at_t1 = surface
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
\t\t\t\t\t"foreign_async_rand_draw_count=" .. tostring(state.foreign_async_rand_draw_count),{thread_sentinel}
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
{surface_only_finalize}
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
\t\t\t\tend{thread_finalize}{census_finalize}
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
\t\t\t\t\t"foreign_async_rand_draw_count=" .. tostring(state.foreign_async_rand_draw_count),{thread_sentinel}
\t\t\t\t\t"async_rand_dispatcher_restored=" .. tostring(state.async_rand_dispatcher_restored),
\t\t\t\t}}, "\\n") .. "\\n"
\t\t\t\tlocal write_error = AsyncStringToFile("{lua_path(final_sentinel)}", text)
\t\t\t\tif write_error then error("final sentinel write failed: " .. tostring(write_error)) end
\t\t\t\tstate.capture_finalized = true
\t\t\t\treturn true
{surface_only_finalize_close}
\t\t\tend)
\t\tend'''


def render_generation(
    capture_base: Path,
    stable_sentinel: Path,
    final_sentinel: Path,
    async_rand_seed: int = DEFAULT_ASYNC_RAND_SEED,
    surface_thread_rng_mode: str = "forward",
    surface_thread_rng_trace: Path | None = None,
    scheduler_census_path: Path | None = None,
    surface_only: bool = False,
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
        capture_base, stable_sentinel, final_sentinel, async_rand_seed,
        surface_thread_rng_mode, surface_thread_rng_trace, scheduler_census_path, surface_only,
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
    if surface_only:
        # The reference template normally settles and enters the underground after
        # Surface T1.  A surface-only acceptance must retain the same Surface
        # publisher/finalizer but remove the entire inherited post-T1 tail,
        # including even dormant lookup/switch helpers.
        find_start = '''\t\tlocal function find_underground()
'''
        find_end = '''\t\tlocal surface = Maps and Maps[1]
'''
        if find_start not in text or find_end not in text:
            raise ReferenceError("underground helper boundaries changed")
        find_at = text.index(find_start)
        find_end_at = text.index(find_end, find_at)
        text = (text[:find_at]
                + '''\t\t-- Surface-only contract: no underground lookup helper is installed.

'''
                + text[find_end_at:])
        tail_start = '''\t\t-- Capture the generator holders BEFORE any game time is allowed to advance:'''
        parity_complete = '''\t\tg_ParityStatus = "complete"
\tend, debug.traceback)'''
        if tail_start not in text or parity_complete not in text:
            raise ReferenceError("surface-only tail boundaries changed")
        start = text.index(tail_start)
        end = text.index(parity_complete, start)
        text = text[:start] + text[end:]
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


def static_verdict(text: str, surface_only: bool = False) -> dict[str, object]:
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
            if not surface_only else True
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
            if not surface_only
            else 0 <= positions["generation"] < positions["stable_publish"]
        ),
        "determinism_capture_armed_before_generation": (
            text.find("g_FzpDeterminismCaptureOutBase") < positions["generation"]
        ),
        "target_state_probe_absent": "g_FzpTargetObjectStateProbe" not in text,
        "finalizer_follows_stable_t1_and_underground": (
            0 <= positions["stable_publish"] < positions["underground_visit"]
            < positions["finalizer_invoke"] < positions["parity_complete"]
            if not surface_only
            else 0 <= positions["stable_publish"] < positions["finalizer_invoke"]
            < positions["parity_complete"]
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
        "surface_only_has_no_underground_route": (
            "ChangeCurrentMapSlot" not in text
            and "find_underground" not in text
            and "entering_underground" not in text
            and "no underground map was generated" not in text
            if surface_only else True
        ),
    }
    failed = sorted(name for name, passed in checks.items() if not passed)
    return {
        "schema": "smr.ralph.surface_loading_reference_static.v1",
        "ok": not failed,
        "coordinate": COORDINATE,
        "latitude": LAT,
        "longitude": LON,
        "expected_preset": EXPECTED_PRESET,
        "surface_only": surface_only,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "positions": positions,
    }


def surface_thread_rng_static_verdict(text: str, mode: str) -> dict[str, object]:
    checks = {
        "mode_is_record_or_replay": mode in {"record", "replay"},
        "scheduler_scoped_by_function_identity": (
            "info.func == surface_scheduler" in text
            and "called_by_surface_scheduler()" in text
            and "SBM.Generation.RunSurfaceStretchIfEnabled" in text
        ),
        "scheduler_census_has_executed_nonce_and_immediate_write": (
            "schema=smr.ralph.surface_scheduler_census.v1" in text
            and "setup_executed=true" in text
            and 'write_scheduler_census("setup")' in text
            and "state.surface_scheduler_census_nonce" in text
        ),
        "scheduler_census_wraps_global_lookup_without_changing_return": (
            'rawset(_G, "Global", scoped_global)' in text
            and 'if name == "CreateRealTimeThread" then' in text
            and "returned_scoped=" in text
            and "returned_original=" in text
            and "return value" in text
        ),
        "scheduler_census_records_function_identity_stack": (
            'pcall(debug.getinfo, level, "nSfl")' in text
            and "tostring(info.func == surface_scheduler)" in text
            and 'write_scheduler_census("global_lookup")' in text
        ),
        "thread_identified_inside_scheduled_callback": (
            "surface_generation_thread = current_thread()" in text
            and "state.surface_generation_thread_identified" in text
        ),
        "create_dispatcher_is_one_shot_and_restored": (
            text.count('rawset(_G, "CreateRealTimeThread", scoped_create_real_time_thread)') == 1
            and 'rawset(_G, "CreateRealTimeThread", original_create_real_time_thread)' in text
            and "state.create_thread_dispatcher_restored" in text
        ),
        "mod_private_stream_has_priority": (
            text.find("if called_by_mod_rand_int() then")
            < text.find("current_thread() == surface_generation_thread")
        ),
        "surface_direct_calls_scoped_by_current_thread": (
            "surface_generation_thread and current_thread() == surface_generation_thread" in text
            and "state.surface_thread_async_rand_draw_count" in text
        ),
        "unrelated_consumers_forwarded": (
            "state.foreign_async_rand_draw_count = state.foreign_async_rand_draw_count + 1\n"
            "\t\t\t\treturn original_async_rand(...)" in text
        ),
        "replay_checks_arity_arguments_and_exhaustion": (
            "surface-thread AsyncRand replay exhausted or arity changed" in text
            and "surface-thread AsyncRand replay argument changed" in text
            and "surface-thread AsyncRand replay left unused draws" in text
        ),
        "record_writes_versioned_trace": (
            "schema=smr.ralph.surface_thread_async_rand_trace.v1" in text
            and "surface-thread RNG trace write failed" in text
        ),
        "finalizer_requires_identified_thread_and_draws": (
            "surface-generation thread discriminator did not complete" in text
            and "surface-generation thread consumed no direct AsyncRand draws" in text
        ),
    }
    failed = sorted(name for name, passed in checks.items() if not passed)
    return {
        "schema": "smr.ralph.surface_thread_rng_static.v1",
        "ok": not failed,
        "mode": mode,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
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
    thread_trace = (
        args.surface_thread_rng_trace.resolve()
        if args.surface_thread_rng_trace is not None
        else None
    )
    scheduler_census = (
        args.scheduler_census.resolve()
        if args.scheduler_census is not None
        else None
    )
    text = render_generation(
        capture_base, stable_sentinel, final_sentinel, args.async_rand_seed,
        args.surface_thread_rng_mode, thread_trace, scheduler_census, args.surface_only,
    )
    generation.write_text(text, encoding="utf-8")
    compile_lua(args.luac.resolve(), generation)
    verdict = static_verdict(text, args.surface_only)
    thread_verdict = None
    if args.surface_thread_rng_mode != "forward":
        thread_verdict = surface_thread_rng_static_verdict(
            text, args.surface_thread_rng_mode
        )
        verdict["surface_thread_rng"] = thread_verdict
        verdict["ok"] = verdict["ok"] and thread_verdict["ok"]
    if not verdict["ok"]:
        raise ReferenceError(f"rendered generation failed static checks: {verdict['failed']}")
    source_head = subprocess.check_output(
        ["git", "rev-parse", f"{args.source_head}^{{commit}}"],
        cwd=PROJECT,
        text=True,
        timeout=30,
    ).strip()
    manifest = {
        "schema": (
            "smr.ralph.surface_loading_reference_manifest.v4"
            if args.surface_thread_rng_mode == "forward"
            else "smr.ralph.surface_loading_reference_manifest.v5"
        ),
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
        "surface_thread_rng_mode": args.surface_thread_rng_mode,
        "surface_thread_rng_trace": str(thread_trace) if thread_trace else None,
        "surface_thread_rng_trace_sha256": (
            sha256_file(thread_trace)
            if args.surface_thread_rng_mode == "replay" and thread_trace
            else None
        ),
        "surface_only": args.surface_only,
        "scheduler_census": str(scheduler_census) if scheduler_census else None,
        "scheduler_census_nonce": (
            hashlib.sha256(str(scheduler_census).encode("utf-8")).hexdigest()[:16]
            if scheduler_census else None
        ),
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
        trace = root / "surface_thread_rng.trace"
        trace.write_text(
            "schema=smr.ralph.surface_thread_async_rand_trace.v1\n"
            "draw\t0\t17\n"
            "draw\t2\t41\t99\t7\n",
            encoding="utf-8",
        )
        record_text = render_generation(
            root / "record_capture", root / "record.stable", root / "record.final",
            surface_thread_rng_mode="record", surface_thread_rng_trace=trace,
        )
        replay_text = render_generation(
            root / "replay_capture", root / "replay.stable", root / "replay.final",
            surface_thread_rng_mode="replay", surface_thread_rng_trace=trace,
        )
        record_generation = root / "record_generation.lua"
        replay_generation = root / "replay_generation.lua"
        record_generation.write_text(record_text, encoding="utf-8")
        replay_generation.write_text(replay_text, encoding="utf-8")
        compile_lua(args.luac.resolve(), record_generation)
        compile_lua(args.luac.resolve(), replay_generation)
        record_verdict = surface_thread_rng_static_verdict(record_text, "record")
        replay_verdict = surface_thread_rng_static_verdict(replay_text, "replay")
        trace_calls = load_surface_thread_trace(trace)
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
        verdict["surface_thread_record_static"] = record_verdict
        verdict["surface_thread_replay_static"] = replay_verdict
        verdict["surface_thread_trace_round_trip"] = trace_calls == [([], 17), ([41, 99], 7)]
        verdict["surface_thread_record_lua_parse"] = True
        verdict["surface_thread_replay_lua_parse"] = True
        verdict["ok"] = (
            verdict["ok"]
            and mutation_red
            and missing_finalizer_red
            and dispatch_test["ok"]
            and missing_dispatcher_red
            and unscoped_dispatcher_red
            and missing_foreign_forward_red
            and verdict["reference_probe_exact"]
            and record_verdict["ok"]
            and replay_verdict["ok"]
            and verdict["surface_thread_trace_round_trip"]
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
    prepare.add_argument(
        "--surface-thread-rng-mode",
        choices=("forward", "record", "replay"),
        default="forward",
    )
    prepare.add_argument("--surface-thread-rng-trace", type=Path)
    prepare.add_argument("--scheduler-census", type=Path)
    prepare.add_argument("--surface-only", action="store_true")
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

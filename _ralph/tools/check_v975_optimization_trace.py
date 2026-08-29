#!/usr/bin/env python3
"""Fail-closed static/executable gate for the v984 default-off-safe optimization trace."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GENERATION = ROOT / "Code" / "sbm_map_generation.lua"
TERRAIN = ROOT / "Code" / "sbm_terrain_copy.lua"
DIAGNOSTICS = ROOT / "Code" / "sbm_diagnostics.lua"
VERSION = ROOT / "Code" / "sbm_version.lua"
METADATA = ROOT / "metadata.lua"
DEFAULT_OFF_ORACLE = ROOT / "_ralph" / "tools" / "optimization_trace_default_off_oracle.lua"
YIELD_WRITER_ORACLE = ROOT / "_ralph" / "tools" / "optimization_trace_yield_writer_oracle.lua"
LUA53 = (ROOT / "_ralph" / "tmp" / ".tmp_surface_loading_rough_iter109_lua53"
         / "lua-5.3.6" / "src" / "luac.exe")
LUA53_RUN = LUA53.with_name("lua.exe")

REQUIRED_PAIRED_PHASES = (
    "temporary source migration rollback cleanup",
    "surface annotate decoration relief",
    "surface StretchSourceToFull",
    "surface scale decorations",
    "surface restore prefab feature game logic",
    "surface recreate staged native enrichments",
    "surface finalize deferred breakthrough anomalies",
    "surface audit mountain-base buildable aprons",
    "surface clear top-up placement pool after terrain rebuild",
    "surface audit outer resource terrain",
    "surface clear top-up placement pool after terrain repair",
    "surface audit repaired outer resource terrain",
    "surface census final outer resource top-ups",
    "surface schedule post-deferred resource census",
    "surface audit outer passage-pad spacing",
    "surface census outer passage pads",
    "surface final top-up placement-pool cleanup",
    "surface align passage pair to shared hex",
    "surface move entrance visuals",
    "surface resnap rockets",
    "surface initialize entrance visuals",
    "surface pass-edit rollback cleanup",
    "surface decor-relief cleanup",
    "surface completion publication",
    "lazy capsule publication rollback cleanup",
    "lazy capsule main plan",
    "lazy capsule deterministic replay",
    "lazy capsule object publication",
    "lazy release retained native source",
    "lazy free retained native buildable grid",
    "lazy canonical RebuildFinal",
    "lazy canonical RebuildFinal fallback",
    "lazy validate published capsules",
    "lazy capsule finalization",
    "lazy persisted-state live re-entry validation",
    "terrain map-grid temporary free",
    "terrain clutter extraction and compute copy",
    "terrain clutter resample",
    "terrain clutter destination write",
    "terrain clutter temporary free",
    "terrain height source crease detection and repair",
    "terrain height destination crease repair",
    "terrain height similarity transform",
    "terrain height apron native-raster shaping",
    "StretchSourceToFull complete grid suite",
    "terrain height-range scaling",
    "terrain expanded-grid revalidation",
)

LOADING_PHASES = (
    "stretch temporary source terrain directly to destination",
    "copy native terrain to destination",
    "copy generated map state",
    "transfer generated non-enrichment objects",
    "surface scale marker objects",
    "surface verify native enrichment transform",
    "surface resume combined pass edits",
    "surface select stretched vanilla initial reveal",
    "surface final RebuildBuildableGrid",
    "surface hard top-up spacing audit",
    "diagnostic surface enrichment audit",
    " final RebuildPassability (",
    "surface final RebuildBuildableGrid",
)

TIMED_SAFE_PHASES = (
    "surface enforce scan gate",
    "surface top-up resources",
    "surface prepare outer resource terrain",
    "surface repair failed outer resource terrain",
    "surface top-up anomalies",
    "surface top-up effect deposits",
    "surface register top-up markers",
    "surface resolve marker overlaps",
    "surface top-up placement audit",
    "surface prepare outer passage terrain",
)


def literal_phases(text: str, method: str) -> Counter[str]:
    pattern = (r"(?:SuperBigMap\.OptimizationTrace\." + method
               + r"|Trace" + method + r")\(\s*\"([^\"]+)\"")
    return Counter(re.findall(pattern, text))


def main() -> int:
    generation = GENERATION.read_text(encoding="utf-8")
    terrain = TERRAIN.read_text(encoding="utf-8")
    diagnostics = DIAGNOSTICS.read_text(encoding="utf-8")
    version = VERSION.read_text(encoding="utf-8")
    metadata = METADATA.read_text(encoding="utf-8")
    combined = generation + "\n" + terrain
    before = literal_phases(combined, "Before")
    after = literal_phases(combined, "After")
    pair_counts = {
        phase: {"before": before[phase], "after": after[phase]}
        for phase in REQUIRED_PAIRED_PHASES
    }
    trace_start = generation.index("-- Ralph-only, process-local optimization trace.")
    trace_end = generation.index("function Lazy.ValidatePersistedState(surface)", trace_start)
    trace = generation[trace_start:trace_end]
    noop_start = generation.index("-- Default-off optimization-trace API.")
    noop_end = generation.index("local function PointXY", noop_start)
    noop = generation[noop_start:noop_end]
    lazy_gate = generation.index(
        "if SuperBigMap.State.lazy_underground_reload_restore_ok ~= false")
    first_ordinary_call = generation.index("SuperBigMap.OptimizationTrace.Start(destination,")
    code_text = "\n".join(
        path.read_text(encoding="utf-8") for path in (GENERATION, TERRAIN, DIAGNOSTICS))
    path_token = "g_SmrRalphOptimizationTracePath"

    compile_results: dict[str, bool] = {}
    for path in (GENERATION, TERRAIN, DIAGNOSTICS, VERSION, METADATA, DEFAULT_OFF_ORACLE,
                 YIELD_WRITER_ORACLE):
        result = subprocess.run([str(LUA53), "-p", str(path)], cwd=ROOT,
                                capture_output=True, text=True, timeout=30, check=False)
        compile_results[path.relative_to(ROOT).as_posix()] = result.returncode == 0
    default_off_run = subprocess.run(
        [str(LUA53_RUN), str(DEFAULT_OFF_ORACLE)], cwd=ROOT,
        capture_output=True, text=True, timeout=30, check=False)
    yield_writer_run = subprocess.run(
        [str(LUA53_RUN), str(YIELD_WRITER_ORACLE)], cwd=ROOT,
        capture_output=True, text=True, timeout=30, check=False)

    checks = {
        "metadata_and_generator_identity_v984_v290": (
            "'version', 984," in metadata
            and "exact successful same-session lazy-state re-entry phase sequence" in metadata
            and "fail-closed lifecycle validation" in metadata
            and "SuperBigMap.GENERATOR_PATCH_VERSION = 290" in version
        ),
        "pinned_lua53_compiles_touched_production": all(compile_results.values()),
        "default_off_api_is_outside_lazy_gate_and_precedes_ordinary_calls": (
            noop_start < noop_end < first_ordinary_call < lazy_gate < trace_start
            and "SuperBigMap.OptimizationTrace = { NOOP_DEFAULT_OFF = true }" in noop
            and "function SuperBigMap.OptimizationTrace.Noop()" in noop
            and all(f"{method} = SuperBigMap.OptimizationTrace.Noop" in noop for method in (
                "ConfiguredPath", "IsActive", "Start", "Before", "After", "Step",
                "Error", "EarlyReturn", "Finish", "Emit", "Publish"))
            and all(token not in noop for token in (
                "GetPreciseTicks", "RealTime", "AsyncStringToFile", "AsyncRand",
                "InteractionRand", "g_SmrRalphOptimizationTracePath", "tostring(",
                "string.format", "pcall("))
        ),
        "default_off_load_and_representative_call_oracle_green": (
            default_off_run.returncode == 0
            and all(token in default_off_run.stdout for token in (
                "ok=true", "map_calls_safe=true", "terrain_calls_safe=true",
                "diagnostic_calls_safe=true", "clock_calls=0", "format_calls=0",
                "file_calls=0", "console_calls=0", "rng_calls=0"))
        ),
        "production_never_assigns_or_arms_trace_path": (
            code_text.count(path_token) == 1
            and f'rawget(_G, "{path_token}")' in trace
            and f'rawset(_G, "{path_token}"' not in code_text
            and not re.search(rf"\b{re.escape(path_token)}\s*=", code_text)
        ),
        "active_error_console_phase_includes_bounded_reason_after_default_off_guard": (
            all(token in generation for token in (
                'function SuperBigMap.OptimizationTrace.Error(phase, map, reason, data)',
                'if not trace.IsActive() then return false end',
                'local bounded_reason = tostring(reason or "unknown"):sub(1, 112)',
                'local visible_phase = tostring(phase or "error") .. ": " .. bounded_reason',
                'return trace.Emit("ERROR", visible_phase, map, fields)'))
            and generation.index('if not trace.IsActive() then return false end',
                generation.index('function SuperBigMap.OptimizationTrace.Error'))
                < generation.index('local bounded_reason = tostring(reason or "unknown")',
                    generation.index('function SuperBigMap.OptimizationTrace.Error'))
        ),
        "trace_start_requires_nonempty_bounded_explicit_path": all(token in trace for token in (
            "local path = trace.ConfiguredPath()",
            "if not path then return false end",
            'type(path) == "string" and path ~= "" and #path <= 1024',
        )),
        "disabled_emit_returns_before_clock_format_console_or_write": (
            trace.index("if not trace.IsActive() then return false end",
                        trace.index("function SuperBigMap.OptimizationTrace.Emit("))
            < trace.index("pcall(trace.EmitActive",
                          trace.index("function SuperBigMap.OptimizationTrace.Emit("))
            and "AsyncRand" not in trace and "InteractionRand" not in trace
        ),
        "publication_is_bounded_fail_open_and_measured": all(token in trace for token in (
            "MAX_RECORDS = 1024", "MAX_BYTES = 524288",
            "runtime.write_disabled == true then return false",
            'local write = Global("AsyncStringToFile")',
            'local protected_write = Global("sprocall") or pcall',
            "local call_ok, write_error = protected_write(write, runtime.path, payload)",
            "runtime.write_ms = (runtime.write_ms or 0) + elapsed",
            "if runtime.write_failures >= 3 then runtime.write_disabled = true end",
            "pcall(print_fn,", "runtime.console_ms = (runtime.console_ms or 0)",
            "pcall(trace.EmitActive", "runtime.emit_failures = math.min(3,",
            "runtime.emit_ms = (runtime.emit_ms or 0) + emit_elapsed",
            "SuperBigMapOptimizationTraceComputeMs",
            "SuperBigMapOptimizationTraceOverheadMs",
        )) and yield_writer_run.returncode == 0
            and all(token in yield_writer_run.stdout for token in (
                "ok=true", "uses_sprocall=true", "success_write=true",
                "error_return_fail_open=true", "thrown_write_fail_open=true")),
        "trace_schema_has_sequence_raw_net_delta_map_and_counters": all(
            token in trace for token in (
                'SCHEMA = "smr.sbm.optimization-trace.v1"',
                "elapsed_ms_raw", "elapsed_ms_net", "delta_ms_raw", "delta_ms_net",
                "map_slot", "environment", "counters", "diagnostic_write_ms_before",
                "diagnostic_console_ms_before", "diagnostic_emit_ms_before", "write_failures",
            )
        ),
        "loading_boundary_bridge_is_paired_even_when_normal_debug_is_off": all(
            token in diagnostics for token in (
                'trace.Before(tostring(name), map, data)',
                'trace.After(token.name, token.map, data)',
                'trace.Error(token.name, token.map,',
                'return traced and { name = tostring(name), map = map, optimization_trace = true }',
            )
        ),
        "timed_safe_calls_activate_for_trace_without_debug_logging": all(
            token in generation for token in (
                "local optimization_active =", "and not optimization_active then",
                "return SafeCall(func, ...)",
            )
        ),
        "all_required_literal_material_boundaries_are_paired": all(
            before[phase] > 0
            and (
                before[phase] == after[phase]
                or (
                    phase == "StretchSourceToFull complete grid suite"
                    and before[phase] == 1 and after[phase] == 2
                    and "if terrain_only == true then" in terrain
                )
            )
            for phase in REQUIRED_PAIRED_PHASES
        ),
        "dynamic_height_type_copy_resample_write_free_boundaries_are_paired": all(
            token in terrain for token in (
                'TraceBefore("terrain " .. tostring(label) .. " grid source read", map)',
                'TraceAfter("terrain " .. tostring(label) .. " grid source read", map)',
                'TraceBefore("terrain " .. tostring(label) .. " grid source extraction", map)',
                'TraceAfter("terrain " .. tostring(label) .. " grid source extraction", map)',
                'TraceBefore("terrain " .. tostring(label) .. " grid resample", map)',
                'TraceAfter("terrain " .. tostring(label) .. " grid resample", map)',
                'TraceBefore("terrain " .. tostring(label) .. " grid destination write", map)',
                'TraceAfter("terrain " .. tostring(label) .. " grid destination write", map)',
                'TraceBefore("terrain " .. tostring(label) .. " grid temporary free", map)',
                'TraceAfter("terrain " .. tostring(label) .. " grid temporary free", map)',
            )
        ),
        "existing_material_loading_boundaries_feed_trace_bridge": all(
            phase in generation or phase in terrain for phase in LOADING_PHASES
        ),
        "every_topup_resource_anomaly_effect_phase_is_trace_timed": all(
            phase in generation for phase in TIMED_SAFE_PHASES
        ),
        "errors_early_returns_and_rollback_cleanup_are_traced": all(
            token in generation for token in (
                "OptimizationTrace.Error", "OptimizationTrace.EarlyReturn",
                '"temporary source migration rollback cleanup"',
                '"surface pass-edit rollback cleanup"',
                '"lazy capsule publication rollback cleanup"',
                '"surface expansion thread"',
            )
        ),
        "trace_starts_before_direct_stretch_and_finishes_at_completion_publication": (
            generation.index("OptimizationTrace.Start(destination,")
            < generation.index("StretchSourceToFull, destination, source, true")
            and generation.index('"surface completion publication"')
            < generation.index('"deferred surface completion published"')
        ),
        "both_canonical_rebuilds_live_reentry_plan_replay_publication_finalize_present": all(
            token in generation for token in (
                '"lazy canonical RebuildFinal"', '"lazy persisted-state live re-entry validation"',
                '"lazy capsule main plan"', '"lazy capsule deterministic replay"',
                '"lazy capsule object publication"', '"lazy capsule finalization"',
                'report.fresh_grid_expected_rebuilds = 2',
            )
        ),
    }
    failed = sorted(name for name, ok in checks.items() if not ok)
    output = {
        "schema": "smr.ralph.v984.optimization-trace-check.v1",
        "ok": not failed,
        "failed": failed,
        "checks": checks,
        "pair_counts": pair_counts,
        "compile": compile_results,
        "default_off_oracle": default_off_run.stdout.strip(),
        "yield_writer_oracle": yield_writer_run.stdout.strip(),
        "required_literal_phases": len(REQUIRED_PAIRED_PHASES),
    }
    print(json.dumps(output, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())

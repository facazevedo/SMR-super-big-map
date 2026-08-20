#!/usr/bin/env python3
"""Render and validate a pre-menu direct-DAP P1 acquisition worker.

The delayed direct-DAP worker proved that a real-time thread can survive a
``smr run-file`` return. This probe puts the protected P1 generator and its
existing acquisition tail in that proven lifetime, rather than inside a
HARNESS scenario callback. It has no artificial post-loader sleep: ``smr
daemon start --startup-file`` evaluates it before the normal menu-ready gate.
Its artifact directory is deliberately created by the host before the one
permitted game-side invocation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
GENERATOR = ROOT / "_ralph/tools/parity/out/gen-u80a.lua"
INLINE = ROOT / "_ralph/tmp/full_z_parity_iter874_p1_inline_acquisition/p1_inline_acquisition.lua"
GENERATOR_SHA256 = "fcdd02994b2ff444274d79e76e16c8c0389fff83dc5f19609c44ee4607d66a9f"
INLINE_SHA256 = "cf4d5a1d7e0121cb667772f9459751dd230a42ad76ecb4a428a9d4dba87a8b86"

# MarsDebug reports the first ordinary write to an unknown global as an error.
# Predeclare every g_Parity* value assigned by the startup wrapper, protected
# generator, or acquisition tail before the worker is scheduled.  The static
# checker independently derives the assigned names from the rendered source so
# a future copied-body assignment cannot silently escape this list.
PREDECLARED_GLOBALS = (
    "g_ParityStatus",
    "g_ParityError",
    "g_ParitySurfaceSeed",
    "g_ParityUndergroundSeed",
    "g_ParityUndergroundPin",
    "g_ParityUndergroundPinApplied",
    "g_ParityRasterTables",
    "g_ParityRasterDivBefore",
    "g_ParityRasterDivAfter",
    "g_ParityPassagePin",
    "g_ParityPassagePinAround",
    "g_ParityPassagePinPassable",
    "g_ParityPassagePinCalls",
    "g_ParityP1ReadinessStatus",
    "g_ParityP1ReadinessError",
    "g_ParityP1ReadinessResult",
    "g_ParityDumpStatus",
    "g_ParityDumpError",
    "g_ParityDumpRows",
    "g_ParityHexStatus",
    "g_ParityHexError",
    "g_ParityHexBuckets",
    "g_ParityDapP1Status",
    "g_ParityDapP1Result",
    "g_ParityDapP1CreateType",
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def generator_body(source: str) -> str:
    opener = "CreateRealTimeThread(function()\n"
    closer = 'end)\nreturn "parity_thread_started"'
    outer = source.find(opener)
    if outer < 0 or source.count(closer) != 1:
        raise ValueError("unexpected protected generator wrapper")
    return source[outer + len(opener) : source.index(closer, outer)]


def acquisition_tail(source: str, artifact_root: str) -> str:
    start = source.index('if g_ParityStatus ~= "complete" then')
    end = source.rindex("\nend)\n")
    tail = source[start:end]
    tail = tail.replace("ctx:fail(", "error(")
    tail = tail.replace("ctx:expect_eq(", "expect_eq(")
    tail = tail.replace("ctx:record(", "record(")
    old_root = "D:/PROJS/SMR/super-big-map/_ralph/runs/full-z-parity/artifacts/iter874_p1_inline_acquisition"
    if old_root not in tail:
        raise ValueError("expected inline output root is absent")
    return tail.replace(old_root, artifact_root)


def render(body: str, tail: str, artifact_root: str) -> str:
    declarations = "\n".join(
        f'rawset(_G, "{name}", false)' for name in PREDECLARED_GLOBALS
    )
    return f'''-- Rendered for the full-z-parity pre-menu direct-DAP P1 acquisition probe.
-- Run only through smr-harness daemon start --startup-file after the host creates this output root.
-- Protected iter780 generator SHA256: {GENERATOR_SHA256}
-- Inline acquisition SHA256: {INLINE_SHA256}
local START = "{artifact_root}/worker_started.json"
local START_DONE = "{artifact_root}/worker_started.done"
local DATA = "{artifact_root}/producer.json"
local DONE = "{artifact_root}/producer.done"

{declarations}
g_ParityDapP1Status = "loader_before_schedule"
local created = CreateRealTimeThread(function()
    local ok, err = sprocall(function()
        g_ParityDapP1Status = "worker_entered_pre_menu"
        local start = '{{"schema":"smr.ralph.full-z-parity.dap-p1-startup-acquisition.v1","status":"worker_started"}}'
        local write_err = AsyncStringToFile(START, start)
        if write_err then
            g_ParityDapP1Status = "start_write_error:" .. tostring(write_err)
            return
        end
        write_err = AsyncStringToFile(START_DONE, tostring(#start))
        if write_err then
            g_ParityDapP1Status = "start_done_error:" .. tostring(write_err)
            return
        end
        local result = {{
            schema = "smr.ralph.full-z-parity.dap-p1-startup-acquisition.v1",
            protocol = "direct_dap_worker_pre_menu_without_post_loader_delay",
            protected_generator_sha256 = "{GENERATOR_SHA256}",
            inline_source_sha256 = "{INLINE_SHA256}",
            ok = false,
            records = {{}},
        }}
        local function record(key, value) result.records[tostring(key)] = value end
        local function expect_eq(actual, expected, label)
            if actual ~= expected then
                error(tostring(label) .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
            end
        end
        local generated, generation_error = xpcall(function()
            -- BEGIN EXACT ITER780 GENERATOR BODY (wrapper and terminal return removed only)
{body}            -- END EXACT ITER780 GENERATOR BODY
        end, debug.traceback)
        if not generated then
            result.status = "generation_error"
            result.error = tostring(generation_error)
        else
            local observed, observer_error = xpcall(function()
{tail}                result.ok = true
                result.status = "complete"
            end, debug.traceback)
            if not observed then
                result.status = "acquisition_error"
                result.error = tostring(observer_error)
            end
        end
        g_ParityDapP1Result = result
        local marshal_result = HARNESS.marshal(DATA, DONE, result)
        g_ParityDapP1Status = marshal_result == "SMR_MARSHAL_OK"
            and result.status or "result_marshal_error:" .. tostring(marshal_result)
    end)
    if not ok then
        g_ParityDapP1Status = "worker_vm_error:" .. tostring(err)
    end
end)
g_ParityDapP1CreateType = type(created)
g_ParityDapP1Status = "loader_returned"
return "dap_p1_startup_acquisition_scheduled"
'''


def lua_parses(source: str) -> tuple[bool, str | None]:
    try:
        from lupa import LuaRuntime

        loader = LuaRuntime(unpack_returned_tuples=True).eval(
            "function(s) local f,e=load(s); return f ~= nil,e end"
        )
        ok, error = loader(source)
        return bool(ok), None if ok else str(error)
    except Exception as exc:
        return False, str(exc)


def parity_global_declaration_facts(
    executable: str,
) -> tuple[set[str], set[str], bool]:
    worker_start = executable.find("CreateRealTimeThread(function()")
    assignment_matches = list(
        re.finditer(r"\b(g_Parity[A-Za-z0-9_]*)\s*=(?!=)", executable)
    )
    worker_rawset_matches = list(
        re.finditer(
            r'rawset\(_G,\s*"(g_Parity[A-Za-z0-9_]*)"\s*,',
            executable[worker_start:] if worker_start >= 0 else "",
        )
    )
    declaration_matches = list(
        re.finditer(
            r'rawset\(_G, "(g_Parity[A-Za-z0-9_]*)", false\)',
            executable[:worker_start] if worker_start >= 0 else "",
        )
    )
    assigned = {match.group(1) for match in assignment_matches} | {
        match.group(1) for match in worker_rawset_matches
    }
    declared = {match.group(1) for match in declaration_matches}
    assignment_offsets = [match.start() for match in assignment_matches]
    assignment_offsets.extend(
        worker_start + match.start() for match in worker_rawset_matches
    )
    first_assignment = min(assignment_offsets, default=-1)
    declarations_end = max((match.end() for match in declaration_matches), default=-1)
    exact_and_early = (
        assigned == declared == set(PREDECLARED_GLOBALS)
        and declarations_end >= 0
        and first_assignment > declarations_end
        and worker_start > declarations_end
        and len(declaration_matches) == len(PREDECLARED_GLOBALS)
    )
    return assigned, declared, exact_and_early


def check(source: str, artifact_root: str) -> dict[str, object]:
    parsed, parse_error = lua_parses(source)
    executable = "\n".join(
        line for line in source.splitlines() if not line.lstrip().startswith("--")
    )
    assigned_globals, declared_globals, declaration_contract = (
        parity_global_declaration_facts(executable)
    )
    _, _, unexpected_assignment_contract = parity_global_declaration_facts(
        executable + "\ng_ParityStaticNegativeControl = true\n"
    )
    missing_declaration = executable.replace(
        f'rawset(_G, "{PREDECLARED_GLOBALS[0]}", false)\n', "", 1
    )
    _, _, missing_declaration_contract = parity_global_declaration_facts(
        missing_declaration
    )
    checks = {
        "lua_load_parse_green": parsed,
        "not_a_harness_scenario": "HARNESS.scenario" not in executable,
        "one_direct_realtime_worker": executable.count("CreateRealTimeThread(function()") >= 1,
        "startup_protocol_is_named": "direct_dap_worker_pre_menu_without_post_loader_delay" in executable,
        "no_post_loader_artificial_delay": "Sleep(" not in executable[: executable.find("local generated, generation_error")],
        "host_unique_output_root_only": artifact_root in executable and "iter874_p1_inline_acquisition" not in executable,
        "start_sentinel_precedes_generation": executable.find("AsyncStringToFile(START_DONE") < executable.find("local generated, generation_error"),
        "result_is_length_guarded": "HARNESS.marshal(DATA, DONE, result)" in executable,
        "protected_generator_is_marked": "BEGIN EXACT ITER780 GENERATOR BODY" in source and "END EXACT ITER780 GENERATOR BODY" in source,
        "worker_errors_are_caught": "sprocall(function()" in executable and "worker_vm_error:" in executable,
        "generation_and_acquisition_errors_are_reported": "generation_error" in executable and "acquisition_error" in executable,
        "all_assigned_parity_globals_predeclared_exactly_before_worker": declaration_contract,
        "checker_rejects_unexpected_parity_assignment": not unexpected_assignment_contract,
        "checker_rejects_missing_parity_predeclaration": not missing_declaration_contract,
        "no_forbidden_control_surface": not any(
            token in executable.lower()
            for token in ("taskkill", "marsdebug.exe", "subprocess", "os.execute", "io.popen")
        ),
    }
    failed = sorted(name for name, ok in checks.items() if not ok)
    return {
        "schema": "smr.ralph.full-z-parity.dap-p1-startup-acquisition-static.v1",
        "ok": not failed,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "rendered_sha256": hashlib.sha256(source.encode("utf-8")).hexdigest(),
        "protected_generator_sha256": GENERATOR_SHA256,
        "inline_source_sha256": INLINE_SHA256,
        "assigned_parity_globals": sorted(assigned_globals),
        "predeclared_parity_globals": sorted(declared_globals),
        "lua_parse_error": parse_error,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--staging", type=Path, required=True)
    parser.add_argument("--artifact-root", type=Path, required=True)
    args = parser.parse_args()
    if sha256(GENERATOR).lower() != GENERATOR_SHA256:
        raise SystemExit(f"protected generator hash changed: {GENERATOR}")
    if sha256(INLINE).lower() != INLINE_SHA256:
        raise SystemExit(f"inline source hash changed: {INLINE}")
    artifact_root = args.artifact_root.resolve()
    artifact_root.mkdir(parents=True, exist_ok=False)
    source = render(
        generator_body(GENERATOR.read_text(encoding="utf-8")),
        acquisition_tail(INLINE.read_text(encoding="utf-8"), artifact_root.as_posix()),
        artifact_root.as_posix(),
    )
    output = args.staging / "dap_p1_startup_acquisition.lua"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(source, encoding="utf-8")
    result = check(source, artifact_root.as_posix())
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

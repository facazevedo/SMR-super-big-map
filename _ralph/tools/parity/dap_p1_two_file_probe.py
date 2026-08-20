#!/usr/bin/env python3
"""Render and fail-closed validate the P1 generator-exit / host-follow-up probe.

The startup Lua owns only the protected generator and writes a length-checked
terminal sentinel after its real-time worker exits.  The harness then loads the
separate acquisition Lua over that same still-open startup DAP socket.  This
deliberately avoids both the old inline acquisition lifetime and the rejected
HARNESS child-callback shape.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

from dap_p1_acquisition_probe import (
    GENERATOR,
    GENERATOR_SHA256,
    INLINE,
    INLINE_SHA256,
    PREDECLARED_GLOBALS,
    acquisition_tail,
    generator_body,
    lua_parses,
    sha256,
)


def declarations() -> str:
    return "\n".join(f'rawset(_G, "{name}", false)' for name in PREDECLARED_GLOBALS)


def render_generator(body: str, artifact_root: str) -> str:
    return f'''-- Two-file P1 generator stage.  Load only through smr daemon start --startup-file.
-- The host must inject the separate acquisition stage only after GENERATOR_DONE is verified.
-- Protected iter780 generator SHA256: {GENERATOR_SHA256}
local GENERATOR_DATA = "{artifact_root}/generator.json"
local GENERATOR_DONE = "{artifact_root}/generator.done"

{declarations()}
g_ParityDapP1Status = "generator_loader_before_schedule"
local created = CreateRealTimeThread(function()
    local ok, err = sprocall(function()
        g_ParityDapP1Status = "generator_worker_entered_pre_menu"
        local result = {{
            schema = "smr.ralph.full-z-parity.dap-p1-two-file.v1",
            stage = "generator",
            protocol = "generator_exits_then_host_injects_acquisition_on_same_startup_dap",
            protected_generator_sha256 = "{GENERATOR_SHA256}",
            ok = false,
        }}
        local generated, generation_error = xpcall(function()
            -- BEGIN EXACT ITER780 GENERATOR BODY (wrapper and terminal return removed only)
{body}            -- END EXACT ITER780 GENERATOR BODY
        end, debug.traceback)
        if generated then
            result.ok = true
            result.status = "generator_exited"
        else
            result.status = "generation_error"
            result.error = tostring(generation_error)
        end
        g_ParityDapP1Result = result
        local marshal_result = HARNESS.marshal(GENERATOR_DATA, GENERATOR_DONE, result)
        g_ParityDapP1Status = marshal_result == "SMR_MARSHAL_OK"
            and result.status or "generator_result_marshal_error:" .. tostring(marshal_result)
    end)
    if not ok then
        g_ParityDapP1Status = "generator_worker_vm_error:" .. tostring(err)
    end
end)
g_ParityDapP1CreateType = type(created)
g_ParityDapP1Status = "generator_loader_returned"
return "dap_p1_two_file_generator_scheduled"
'''


def render_followup(tail: str, artifact_root: str) -> str:
    return f'''-- Two-file P1 acquisition stage.  The host loads this only after generator.json/done is valid.
-- It must use the identical retained startup DAP socket, never a HARNESS child callback.
-- Source inline acquisition SHA256: {INLINE_SHA256}
local PRODUCER_DATA = "{artifact_root}/producer.json"
local PRODUCER_DONE = "{artifact_root}/producer.done"

local created = CreateRealTimeThread(function()
    local ok, err = sprocall(function()
        g_ParityDapP1Status = "followup_worker_entered_after_generator_exit"
        local result = {{
            schema = "smr.ralph.full-z-parity.dap-p1-two-file.v1",
            stage = "acquisition",
            protocol = "host_injected_acquisition_after_generator_exit_on_same_startup_dap",
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
        local observed, observer_error = xpcall(function()
{tail}            result.ok = true
            result.status = "complete"
        end, debug.traceback)
        if not observed then
            result.status = "acquisition_error"
            result.error = tostring(observer_error)
        end
        g_ParityDapP1Result = result
        local marshal_result = HARNESS.marshal(PRODUCER_DATA, PRODUCER_DONE, result)
        g_ParityDapP1Status = marshal_result == "SMR_MARSHAL_OK"
            and result.status or "followup_result_marshal_error:" .. tostring(marshal_result)
    end)
    if not ok then
        g_ParityDapP1Status = "followup_worker_vm_error:" .. tostring(err)
    end
end)
g_ParityDapP1CreateType = type(created)
return "dap_p1_two_file_followup_scheduled"
'''


def assigned_globals(source: str) -> set[str]:
    return set(re.findall(r"\b(g_Parity[A-Za-z0-9_]*)\s*=(?!=)", source))


def predeclared_globals(source: str) -> set[str]:
    return set(re.findall(r'rawset\(_G, "(g_Parity[A-Za-z0-9_]*)", false\)', source))


def check(generator: str, followup: str, body: str, tail: str, root: str) -> dict[str, object]:
    generator_executable = "\n".join(
        line for line in generator.splitlines() if not line.lstrip().startswith("--")
    )
    followup_executable = "\n".join(
        line for line in followup.splitlines() if not line.lstrip().startswith("--")
    )
    generator_parses, generator_error = lua_parses(generator)
    followup_parses, followup_error = lua_parses(followup)
    embedded_start = generator.index("-- BEGIN EXACT ITER780 GENERATOR BODY")
    embedded_end = generator.index("-- END EXACT ITER780 GENERATOR BODY")
    embedded_body = generator[generator.index("\n", embedded_start) + 1 : embedded_end]
    declared = predeclared_globals(generator_executable)
    assigned = assigned_globals(generator_executable + "\n" + followup_executable)
    checks = {
        "generator_lua_load_parse_green": generator_parses,
        "followup_lua_load_parse_green": followup_parses,
        "protected_generator_hash_exact": sha256(GENERATOR).lower() == GENERATOR_SHA256,
        "inline_acquisition_hash_exact": sha256(INLINE).lower() == INLINE_SHA256,
        "protected_generator_body_exact": embedded_body.rstrip() + "\n" == body,
        "generator_has_only_generator_stage": "object dump" not in generator_executable and "hex-grid census" not in generator_executable,
        "followup_has_only_acquisition_stage": "BEGIN EXACT ITER780 GENERATOR BODY" not in followup,
        "same_protocol_named_in_both_files": "same_startup_dap" in generator_executable and "same_startup_dap" in followup_executable,
        "generator_sentinel_after_generator_return": generator_executable.find("local generated, generation_error") < generator_executable.find("HARNESS.marshal(GENERATOR_DATA, GENERATOR_DONE, result)"),
        "generator_terminal_status_is_explicit": 'result.status = "generator_exited"' in generator_executable,
        "followup_result_is_length_guarded": "HARNESS.marshal(PRODUCER_DATA, PRODUCER_DONE, result)" in followup_executable,
        "acquisition_tail_exact": tail in followup,
        "all_assigned_globals_predeclared_by_generator": assigned <= declared == set(PREDECLARED_GLOBALS),
        "followup_does_not_reset_generator_terrain_state": not any(
            f'rawset(_G, "{name}", false)' in followup_executable
            for name in (
                "g_ParityStatus", "g_ParityError", "g_ParitySurfaceSeed",
                "g_ParityUndergroundSeed", "g_ParityUndergroundPin",
                "g_ParityUndergroundPinApplied",
            )
        ),
        "no_harness_callback_or_control_surface": not any(token in (generator_executable + followup_executable).lower() for token in ("harness.scenario", "ctx:", "taskkill", "marsdebug.exe", "subprocess", "os.execute", "io.popen")),
        "host_unique_output_root_only": root in generator_executable and root in followup_executable and "iter874_p1_inline_acquisition" not in (generator_executable + followup_executable),
    }
    failed = sorted(name for name, ok in checks.items() if not ok)
    return {
        "schema": "smr.ralph.full-z-parity.dap-p1-two-file-static.v1",
        "ok": not failed,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "generator_sha256": hashlib.sha256(generator.encode("utf-8")).hexdigest(),
        "followup_sha256": hashlib.sha256(followup.encode("utf-8")).hexdigest(),
        "protected_generator_sha256": GENERATOR_SHA256,
        "inline_source_sha256": INLINE_SHA256,
        "assigned_parity_globals": sorted(assigned),
        "predeclared_parity_globals": sorted(declared),
        "generator_lua_parse_error": generator_error,
        "followup_lua_parse_error": followup_error,
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
    body = generator_body(GENERATOR.read_text(encoding="utf-8"))
    tail = acquisition_tail(INLINE.read_text(encoding="utf-8"), artifact_root.as_posix())
    generator = render_generator(body, artifact_root.as_posix())
    followup = render_followup(tail, artifact_root.as_posix())
    args.staging.mkdir(parents=True, exist_ok=True)
    (args.staging / "p1_generator.lua").write_text(generator, encoding="utf-8")
    (args.staging / "p1_acquisition.lua").write_text(followup, encoding="utf-8")
    result = check(generator, followup, body, tail, artifact_root.as_posix())
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

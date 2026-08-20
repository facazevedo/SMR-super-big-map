#!/usr/bin/env python3
"""Render and statically validate the delayed direct-DAP worker discriminator.

This follows the iter886 direct-worker red baseline without repeating it:
the worker yields past the DAP evaluation return, uses only plain global
assignment, and first publishes a minimal AsyncStringToFile sentinel before
calling HARNESS.marshal.  Thus its three observable boundaries are distinct:
loader return, worker entry/file I/O, and harness marshal.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_STAGING = ROOT / "_ralph/tmp/full_z_parity_iter887_dap_delayed_thread"
DEFAULT_ARTIFACT_ROOT = (
    "D:/PROJS/SMR/super-big-map/_ralph/runs/full-z-parity/artifacts/"
    "iter887_dap_delayed_thread"
)


def render(artifact_root: str) -> str:
    return f'''-- Rendered for Ralph iteration 887. Run only through smr-harness run-file.
-- It differs from iter886 by yielding beyond the DAP evaluation, avoiding rawset,
-- and writing an independent entry sentinel before HARNESS.marshal.
local ENTRY = "{artifact_root}/worker_entry.json"
local ENTRY_DONE = "{artifact_root}/worker_entry.done"
local DATA = "{artifact_root}/worker_result.json"
local DONE = "{artifact_root}/worker_result.done"

g_ParityDapDelayedThreadStatus = "loader_before_schedule"
local created = CreateRealTimeThread(function()
    local ok, err = sprocall(function()
        Sleep(250)
        g_ParityDapDelayedThreadStatus = "worker_entered_after_dap_return"
        local entry = '{{"schema":"smr.ralph.full-z-parity.dap-delayed-thread.v1","status":"worker_entered"}}'
        local write_err = AsyncStringToFile(ENTRY, entry)
        if write_err then
            g_ParityDapDelayedThreadStatus = "entry_write_error:" .. tostring(write_err)
            return
        end
        write_err = AsyncStringToFile(ENTRY_DONE, tostring(#entry))
        if write_err then
            g_ParityDapDelayedThreadStatus = "entry_done_error:" .. tostring(write_err)
            return
        end
        g_ParityDapDelayedThreadStatus = "entry_marshaled"
        local marshal_result = HARNESS.marshal(DATA, DONE, {{
            schema = "smr.ralph.full-z-parity.dap-delayed-thread.v1",
            status = "worker_entered_after_dap_return",
            created_type = type(created),
        }})
        g_ParityDapDelayedThreadStatus = marshal_result == "SMR_MARSHAL_OK"
            and "result_marshaled" or "result_marshal_error:" .. tostring(marshal_result)
    end)
    if not ok then
        g_ParityDapDelayedThreadStatus = "worker_vm_error:" .. tostring(err)
    end
end)
g_ParityDapDelayedThreadCreateType = type(created)
g_ParityDapDelayedThreadStatus = "loader_returned"
return "dap_delayed_thread_scheduled"
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


def check(source: str) -> dict[str, object]:
    parsed, parse_error = lua_parses(source)
    executable = "\n".join(
        line for line in source.splitlines() if not line.lstrip().startswith("--")
    )
    checks = {
        "not_a_harness_scenario": "HARNESS.scenario" not in executable,
        "one_direct_realtime_worker": executable.count("CreateRealTimeThread(function()") == 1,
        "yield_after_dap_return": "Sleep(250)" in executable,
        "no_rawset_proxy_write": "rawset(" not in executable,
        "plain_global_statuses": executable.count("g_ParityDapDelayedThreadStatus =") >= 6,
        "entry_sentinel_precedes_harness_marshal": (
            executable.find("AsyncStringToFile(ENTRY_DONE")
            < executable.find("HARNESS.marshal(DATA, DONE")
        ),
        "worker_errors_are_caught": "sprocall(function()" in executable,
        "length_guarded_entry_and_result": (
            "AsyncStringToFile(ENTRY_DONE, tostring(#entry))" in executable
            and "HARNESS.marshal(DATA, DONE" in executable
        ),
        "no_forbidden_control_surface": not any(
            token in executable.lower()
            for token in ("taskkill", "marsdebug.exe", "subprocess", "os.execute", "io.popen")
        ),
        "lua_load_parse_green": parsed,
    }
    failed = sorted(name for name, ok in checks.items() if not ok)
    return {
        "schema": "smr.ralph.full-z-parity.dap-delayed-thread-static.v1",
        "ok": not failed,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "rendered_sha256": hashlib.sha256(source.encode("utf-8")).hexdigest(),
        "lua_parse_error": parse_error,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--staging", type=Path, default=DEFAULT_STAGING)
    parser.add_argument("--artifact-root", type=Path, default=Path(DEFAULT_ARTIFACT_ROOT))
    args = parser.parse_args()
    artifact_root = args.artifact_root.resolve()
    # The game-side worker cannot create this directory.  Host setup is part of
    # the probe contract and deliberately occurs before its sole invocation.
    artifact_root.mkdir(parents=True, exist_ok=False)
    source = render(artifact_root.as_posix())
    output = args.staging / "dap_delayed_thread.lua"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(source, encoding="utf-8")
    result = check(source)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

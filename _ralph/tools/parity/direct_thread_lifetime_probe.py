#!/usr/bin/env python3
"""Render and statically validate a direct-DAP real-time-thread lifetime probe."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
STAGING = ROOT / "_ralph/tmp/full_z_parity_iter885_direct_thread_lifetime"
OUTPUT = STAGING / "direct_thread_lifetime.lua"
ARTIFACT_ROOT = (
    "D:/PROJS/SMR/super-big-map/_ralph/runs/full-z-parity/artifacts/"
    "iter885_direct_thread_lifetime"
)


def render() -> str:
    return f'''-- Rendered for Ralph iteration 885. Run only through smr-harness run-file.
-- This is deliberately not a HARNESS.scenario: it distinguishes a direct DAP-created
-- real-time worker from a child spawned by HARNESS.run's scenario thread.
local DATA = "{ARTIFACT_ROOT}/direct_worker.json"
local DONE = "{ARTIFACT_ROOT}/direct_worker.done"

rawset(_G, "g_ParityDirectThreadStatus", "loader_before_schedule")
local created = CreateRealTimeThread(function()
    local parent_status = rawget(_G, "g_ParityDirectThreadStatus")
    rawset(_G, "g_ParityDirectThreadStatus", "worker_entered")
    local marshal_result = HARNESS.marshal(DATA, DONE, {{
        schema = "smr.ralph.full-z-parity.direct-thread-lifetime.v1",
        status = "worker_entered",
        parent_status_at_entry = parent_status,
    }})
    rawset(_G, "g_ParityDirectThreadStatus", marshal_result == "SMR_MARSHAL_OK"
        and "worker_marshaled" or "worker_marshal_error")
end)
rawset(_G, "g_ParityDirectThreadCreateType", type(created))
rawset(_G, "g_ParityDirectThreadStatus", "loader_returned")
return "direct_thread_lifetime_scheduled"
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
    checks = {
        "direct_chunk_not_harness_scenario": "HARNESS.scenario" not in source,
        "exactly_one_direct_realtime_worker": source.count("CreateRealTimeThread(function()") == 1,
        "worker_writes_length_guarded_sentinel": "HARNESS.marshal(DATA, DONE" in source,
        "worker_records_parent_status": "parent_status_at_entry = parent_status" in source,
        "loader_marks_return_after_schedule": '"loader_returned"' in source,
        "no_forbidden_control_surface": not any(
            token in source.lower()
            for token in ("taskkill", "marsdebug.exe", "subprocess", "os.execute", "io.popen")
        ),
        "lua_load_parse_green": parsed,
    }
    failed = sorted(name for name, ok in checks.items() if not ok)
    return {
        "schema": "smr.ralph.full-z-parity.direct-thread-lifetime-static.v1",
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
    args = parser.parse_args()
    source = render()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(source, encoding="utf-8")
    result = check(source)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Render a non-gating P1 worker for the sentinel-held DAP probe.

The HARNESS scenario returns as soon as the worker is scheduled.  The host's
``--hold-dap-until-sentinel`` option then retains that same DAP socket while it
polls the worker's length-checked result.  This avoids both the early-release
protocol from iteration 896 and the outer-wait worker starvation from 897.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
GENERATOR = ROOT / "_ralph/tools/parity/out/gen-u80a.lua"
INLINE = ROOT / "_ralph/tmp/full_z_parity_iter874_p1_inline_acquisition/p1_inline_acquisition.lua"
GENERATOR_SHA256 = "fcdd02994b2ff444274d79e76e16c8c0389fff83dc5f19609c44ee4607d66a9f"
INLINE_SHA256 = "cf4d5a1d7e0121cb667772f9459751dd230a42ad76ecb4a428a9d4dba87a8b86"

PREDECLARED_GLOBALS = (
    "g_ParityStatus", "g_ParityError", "g_ParitySurfaceSeed",
    "g_ParityUndergroundSeed", "g_ParityUndergroundPin",
    "g_ParityUndergroundPinApplied", "g_ParityRasterTables",
    "g_ParityRasterDivBefore", "g_ParityRasterDivAfter",
    "g_ParityPassagePin", "g_ParityPassagePinAround",
    "g_ParityPassagePinPassable", "g_ParityPassagePinCalls",
    "g_ParityP1ReadinessStatus", "g_ParityP1ReadinessError",
    "g_ParityP1ReadinessResult", "g_ParityDumpStatus", "g_ParityDumpError",
    "g_ParityDumpRows", "g_ParityHexStatus", "g_ParityHexError",
    "g_ParityHexBuckets",
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def generator_body(source: str) -> str:
    opener, closer = "CreateRealTimeThread(function()\n", 'end)\nreturn "parity_thread_started"'
    start = source.find(opener)
    if start < 0 or source.count(closer) != 1:
        raise ValueError("unexpected protected generator wrapper")
    return source[start + len(opener) : source.index(closer, start)]


def acquisition_tail(source: str, artifact_root: str) -> str:
    start = source.index('if g_ParityStatus ~= "complete" then')
    end = source.rindex("\nend)\n")
    tail = source[start:end]
    for old, new in (("ctx:fail(", "error("), ("ctx:expect_eq(", "expect_eq("), ("ctx:record(", "record(")):
        tail = tail.replace(old, new)
    old_root = "D:/PROJS/SMR/super-big-map/_ralph/runs/full-z-parity/artifacts/iter874_p1_inline_acquisition"
    if old_root not in tail:
        raise ValueError("expected inline output root is absent")
    return tail.replace(old_root, artifact_root)


def render(body: str, tail: str, artifact_root: str) -> str:
    declarations = "\n".join(f'\trawset(_G, "{name}", false)' for name in PREDECLARED_GLOBALS)
    return f'''-- Rendered offline for the full-z-parity sentinel-held P1 probe.
-- The outer report returns immediately; the host retains DAP through producer.done.
-- Protected iter780 generator SHA256: {GENERATOR_SHA256}
-- Source inline acquisition SHA256: {INLINE_SHA256}
HARNESS.scenario("p1_sentinel_persistent_dap", function(ctx)
\tctx:record("protocol", "non_gating_worker_host_holds_dap_through_producer_sentinel")
\tctx:record("producer_data", "{artifact_root}/producer.json")
\tctx:record("producer_done", "{artifact_root}/producer.done")
\trawset(_G, "g_ParitySentinelP1Status", "scheduled")
{declarations}
\tCreateRealTimeThread(function()
\t\tlocal DATA, DONE = "{artifact_root}/producer.json", "{artifact_root}/producer.done"
\t\tlocal result = {{schema = "smr.ralph.full-z-parity.p1-sentinel-persistent-dap.v1", protocol = "non_gating_worker_host_holds_dap_through_producer_sentinel", protected_generator_sha256 = "{GENERATOR_SHA256}", inline_source_sha256 = "{INLINE_SHA256}", ok = false, records = {{}}}}
\t\tlocal function record(key, value) result.records[tostring(key)] = value end
\t\tlocal function expect_eq(actual, expected, label)
\t\t\tif actual ~= expected then error(tostring(label) .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual)) end
\t\tend
\t\trawset(_G, "g_ParitySentinelP1Status", "worker_running")
\t\tlocal generated, generation_error = xpcall(function()
\t\t\t-- BEGIN EXACT ITER780 GENERATOR BODY (wrapper and terminal return removed only)
{body}\t\t\t-- END EXACT ITER780 GENERATOR BODY
\t\tend, debug.traceback)
\t\tif not generated then
\t\t\tresult.status, result.error = "generation_error", tostring(generation_error)
\t\telse
\t\t\tlocal observed, observer_error = xpcall(function()
{tail}\t\t\t\tresult.ok, result.status = true, "complete"
\t\t\tend, debug.traceback)
\t\t\tif not observed then result.status, result.error = "acquisition_error", tostring(observer_error) end
\t\tend
\t\trawset(_G, "g_ParitySentinelP1Result", result)
\t\trawset(_G, "g_ParitySentinelP1Status", result.status)
\t\tlocal marshaled = HARNESS.marshal(DATA, DONE, result)
\t\tif marshaled ~= "SMR_MARSHAL_OK" then rawset(_G, "g_ParitySentinelP1Status", "result_marshal_error:" .. tostring(marshaled)) end
\tend)
\treturn "p1_sentinel_persistent_dap_scheduled"
end)
'''


def lua_parses(source: str) -> tuple[bool, str | None]:
    try:
        from lupa import LuaRuntime
        ok, error = LuaRuntime(unpack_returned_tuples=True).eval(
            "function(s) local f,e=load(s); return f ~= nil,e end"
        )(source)
        return bool(ok), None if ok else str(error)
    except Exception as exc:
        return False, str(exc)


def check(source: str, generator: str, artifact_root: str) -> dict[str, object]:
    begin, end = "-- BEGIN EXACT ITER780 GENERATOR BODY (wrapper and terminal return removed only)\n", "\t\t\t-- END EXACT ITER780 GENERATOR BODY"
    start, finish = source.find(begin), source.find(end)
    embedded = source[start + len(begin) : finish] if start >= 0 and finish >= 0 else ""
    worker_start = source.find("\tCreateRealTimeThread(function()")
    worker_end = source.find("\n\tend)\n\treturn", worker_start)
    worker = source[worker_start:worker_end] if worker_start >= 0 and worker_end >= 0 else ""
    outer = source[:worker_start] + source[worker_end:]
    parsed, parse_error = lua_parses(source)
    checks = {
        "protected_generator_hash_exact": sha256(GENERATOR).lower() == GENERATOR_SHA256,
        "protected_generator_body_exact": embedded == generator_body(generator),
        "scenario_name_exact": 'HARNESS.scenario("p1_sentinel_persistent_dap", function(ctx)' in source,
        "outer_returns_without_worker_wait": "ctx:wait_for(" not in outer and 'return "p1_sentinel_persistent_dap_scheduled"' in outer,
        "worker_owns_generator_acquisition_and_result_sentinel": all(token in worker for token in ("P1 readiness", "object dump", "hex-grid census", "HARNESS.marshal(DATA, DONE, result)")),
        "all_worker_parity_globals_predeclared": all(f'rawset(_G, "{name}", false)' in source for name in PREDECLARED_GLOBALS),
        "no_harness_context_inside_worker": "ctx:" not in worker,
        "outputs_are_unique": artifact_root in source and "iter874_p1_inline_acquisition" not in source,
        "no_forbidden_control_surface": not any(token in source.lower() for token in ("taskkill", "marsdebug.exe", "subprocess", "os.execute", "io.popen")),
        "lua_load_parse_green": parsed,
    }
    failed = sorted(name for name, ok in checks.items() if not ok)
    return {"schema": "smr.ralph.full-z-parity.p1-sentinel-persistent-dap-static.v1", "ok": not failed, "checks": checks, "passed": sum(checks.values()), "total": len(checks), "failed": failed, "rendered_sha256": hashlib.sha256(source.encode("utf-8")).hexdigest(), "lua_parse_error": parse_error}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--staging", type=Path, required=True)
    parser.add_argument("--artifact-root", type=Path, required=True)
    args = parser.parse_args()
    if sha256(GENERATOR).lower() != GENERATOR_SHA256 or sha256(INLINE).lower() != INLINE_SHA256:
        raise SystemExit("protected source hash changed")
    artifact_root = args.artifact_root.resolve()
    artifact_root.mkdir(parents=True, exist_ok=False)
    source = render(generator_body(GENERATOR.read_text(encoding="utf-8")), acquisition_tail(INLINE.read_text(encoding="utf-8"), artifact_root.as_posix()), artifact_root.as_posix())
    args.staging.mkdir(parents=True, exist_ok=True)
    (args.staging / "p1_sentinel_persistent_dap.lua").write_text(source, encoding="utf-8")
    report = check(source, GENERATOR.read_text(encoding="utf-8"), artifact_root.as_posix())
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

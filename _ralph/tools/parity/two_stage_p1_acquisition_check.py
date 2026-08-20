#!/usr/bin/env python3
"""Fail-closed static validation for the iteration-881 two-stage P1 probe."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
GENERATOR = ROOT / "_ralph/tools/parity/out/gen-u80a.lua"
RENDERED = ROOT / "_ralph/tmp/full_z_parity_iter881_p1_two_stage_acquisition/p1_two_stage_acquisition.lua"
GENERATOR_SHA256 = "fcdd02994b2ff444274d79e76e16c8c0389fff83dc5f19609c44ee4607d66a9f"
ARTIFACT_ROOT = "D:/PROJS/SMR/super-big-map/_ralph/runs/full-z-parity/artifacts/iter881_p1_two_stage_acquisition"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def protected_body(source: str) -> str:
    opener = "CreateRealTimeThread(function()\n"
    closer = 'end)\nreturn "parity_thread_started"'
    outer = source.index(opener)
    return source[outer + len(opener) : source.index(closer, outer)]


def lua_parses(source: str) -> tuple[bool, str | None]:
    try:
        from lupa import LuaRuntime

        runtime = LuaRuntime(unpack_returned_tuples=True)
        loader = runtime.eval("function(s) local f,e=load(s); return f ~= nil,e end")
        ok, error = loader(source)
        return bool(ok), None if ok else str(error)
    except Exception as exc:
        return False, str(exc)


def analyze(rendered: str, generator: str) -> dict[str, object]:
    checks: dict[str, bool] = {}
    begin = "-- BEGIN EXACT ITER780 GENERATOR BODY (wrapper and terminal return removed only)\n"
    end = "\t\t\t-- END EXACT ITER780 GENERATOR BODY"
    start = rendered.find(begin)
    finish = rendered.find(end)
    embedded = rendered[start + len(begin) : finish] if start >= 0 and finish >= 0 else ""
    outer = rendered[: rendered.find("\tCreateRealTimeThread(function()")] 
    stage1 = rendered[rendered.find("\tCreateRealTimeThread(function()"): rendered.find("\n\tctx:record(\"stage1\"")]
    observer_start = stage1.find("\t\tCreateRealTimeThread(function()")
    observer = stage1[observer_start:] if observer_start >= 0 else ""
    checks["protected_generator_hash_exact"] = sha256(GENERATOR).lower() == GENERATOR_SHA256
    checks["protected_generator_body_exact"] = embedded == protected_body(generator)
    checks["two_stage_scenario_name_exact"] = 'HARNESS.scenario("p1_two_stage_acquisition", function(ctx)' in rendered
    checks["outer_only_schedules_stage1"] = all(token not in outer for token in ("GenerateCurrentRandomMap", "await_status", "MapGet"))
    checks["stage1_emits_start_sentinel"] = "HARNESS.marshal(STAGE1_STARTED_DATA, STAGE1_STARTED_DONE" in stage1
    checks["stage1_schedules_observer_after_exact_generation"] = (
        observer_start > finish - rendered.find("\tCreateRealTimeThread(function()")
        and "CreateRealTimeThread(function()" in observer
        and "P1 readiness" in observer
    )
    checks["stage1_returns_after_observer_schedule"] = (
        'rawset(_G, "g_ParityTwoStageStatus", "generator_returned_observer_scheduled")' in stage1
        and stage1.rfind('rawset(_G, "g_ParityTwoStageStatus", "generator_returned_observer_scheduled")') > observer_start
    )
    checks["observer_owns_acquisition_and_final_sentinel"] = all(
        token in observer
        for token in ("await_status(\"P1 readiness\"", "object dump", "hex-grid census", "HARNESS.marshal(PRODUCER_DATA, PRODUCER_DONE, result)")
    )
    checks["payload_outputs_are_unique"] = rendered.count(ARTIFACT_ROOT) >= 12 and "iter874_p1_inline_acquisition" not in rendered
    checks["no_harness_context_inside_workers"] = "ctx:" not in stage1
    checks["no_forbidden_control_surface"] = not any(
        token.lower() in rendered.lower()
        for token in ("taskkill", "marsdebug.exe", "subprocess", "os.execute", "io.popen")
    )
    parsed, parse_error = lua_parses(rendered)
    checks["lua_load_parse_green"] = parsed
    failed = sorted(name for name, ok in checks.items() if not ok)
    return {
        "schema": "smr.ralph.full-z-parity.p1-two-stage-static.v1",
        "ok": not failed,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "rendered_sha256": hashlib.sha256(rendered.encode("utf-8")).hexdigest(),
        "lua_parse_error": parse_error,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    rendered = RENDERED.read_text(encoding="utf-8")
    generator = GENERATOR.read_text(encoding="utf-8")
    report = analyze(rendered, generator)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

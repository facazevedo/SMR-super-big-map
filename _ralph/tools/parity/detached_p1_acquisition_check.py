#!/usr/bin/env python3
"""Fail-closed static validation for the iteration-879 detached P1 producer."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
GENERATOR = ROOT / "_ralph/tools/parity/out/gen-u80a.lua"
RENDERED = ROOT / "_ralph/tmp/full_z_parity_iter879_p1_detached_acquisition/p1_detached_acquisition.lua"
GENERATOR_SHA256 = "fcdd02994b2ff444274d79e76e16c8c0389fff83dc5f19609c44ee4607d66a9f"
ARTIFACT_ROOT = "D:/PROJS/SMR/super-big-map/_ralph/runs/full-z-parity/artifacts/iter879_p1_detached_acquisition"


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
    checks["protected_generator_hash_exact"] = sha256(GENERATOR).lower() == GENERATOR_SHA256
    checks["protected_generator_body_exact"] = embedded == protected_body(generator)
    checks["detached_scenario_name_exact"] = 'HARNESS.scenario("p1_detached_acquisition", function(ctx)' in rendered
    checks["outer_schedules_producer"] = rendered.count("CreateRealTimeThread(function()") >= 1
    outer_prefix = rendered[: rendered.find("CreateRealTimeThread(function()")]
    checks["outer_does_no_generation_or_acquisition"] = all(
        token not in outer_prefix for token in ("GenerateCurrentRandomMap", "await_status", "MapGet")
    )
    outer_tail = rendered[rendered.rfind("\tctx:record(\"producer\"") :]
    checks["outer_returns_immediately_after_schedule"] = (
        'ctx:record("producer", "scheduled")' in outer_tail
        and 'return "p1_detached_producer_scheduled"' in outer_tail
        and "GenerateCurrentRandomMap" not in outer_tail
        and "await_status" not in outer_tail
    )
    producer_start = rendered.find("\tCreateRealTimeThread(function()")
    producer_end = rendered.find("\n\tend)\n\n\tctx:record", producer_start)
    producer = rendered[producer_start:producer_end] if producer_start >= 0 and producer_end >= 0 else ""
    checks["producer_owns_generation_readiness_dump_and_census"] = all(
        token in producer
        for token in ("GenerateCurrentRandomMap", "await_status(\"P1 readiness\"", "object dump", "hex-grid census")
    )
    checks["producer_does_not_use_harness_context"] = "ctx:" not in producer
    checks["producer_uses_separate_length_checked_sentinel"] = (
        f'local PRODUCER_DATA = "{ARTIFACT_ROOT}/producer.json"' in producer
        and f'local PRODUCER_DONE = "{ARTIFACT_ROOT}/producer.done"' in producer
        and "HARNESS.marshal(PRODUCER_DATA, PRODUCER_DONE, result)" in producer
    )
    checks["all_payload_outputs_have_unique_root"] = (
        rendered.count(ARTIFACT_ROOT) == 6
        and "iter874_p1_inline_acquisition" not in rendered
    )
    checks["producer_reports_protected_values"] = all(
        token in producer
        for token in (
            "protected surface seed", "protected underground seed", "serial raster active",
            "passage pin seed", "two exact stable readiness samples",
        )
    )
    checks["producer_reports_terminal_status"] = all(
        token in producer
        for token in ('result.status = "complete"', 'result.status = "error"', "g_ParityDetachedProducerStatus")
    )
    checks["no_forbidden_control_surface"] = not any(
        token.lower() in rendered.lower()
        for token in ("taskkill", "marsdebug.exe", "subprocess", "os.execute", "io.popen")
    )
    parsed, parse_error = lua_parses(rendered)
    checks["lua_load_parse_green"] = parsed
    failed = sorted(name for name, ok in checks.items() if not ok)
    return {
        "schema": "smr.ralph.full-z-parity.p1-detached-static.v1",
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

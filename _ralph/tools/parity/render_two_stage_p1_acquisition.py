#!/usr/bin/env python3
"""Render a P1 acquisition probe whose generator and observer have separate lifetimes."""

from __future__ import annotations

import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
GENERATOR = ROOT / "_ralph/tools/parity/out/gen-u80a.lua"
INLINE = ROOT / "_ralph/tmp/full_z_parity_iter874_p1_inline_acquisition/p1_inline_acquisition.lua"
OUTPUT = ROOT / "_ralph/tmp/full_z_parity_iter881_p1_two_stage_acquisition/p1_two_stage_acquisition.lua"

GENERATOR_SHA256 = "fcdd02994b2ff444274d79e76e16c8c0389fff83dc5f19609c44ee4607d66a9f"
INLINE_SHA256 = "cf4d5a1d7e0121cb667772f9459751dd230a42ad76ecb4a428a9d4dba87a8b86"
ARTIFACT_ROOT = "D:/PROJS/SMR/super-big-map/_ralph/runs/full-z-parity/artifacts/iter881_p1_two_stage_acquisition"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def generator_body(source: str) -> str:
    opener = "CreateRealTimeThread(function()\n"
    closer = 'end)\nreturn "parity_thread_started"'
    outer = source.find(opener)
    if outer < 0 or source.count(closer) != 1:
        raise ValueError("unexpected protected generator wrapper")
    return source[outer + len(opener) : source.index(closer, outer)]


def acquisition_tail(source: str) -> str:
    start = source.index('if g_ParityStatus ~= "complete" then')
    end = source.rindex("\nend)\n")
    tail = source[start:end]
    tail = tail.replace("ctx:fail(", "error(")
    tail = tail.replace("ctx:expect_eq(", "expect_eq(")
    tail = tail.replace("ctx:record(", "record(")
    old_root = "D:/PROJS/SMR/super-big-map/_ralph/runs/full-z-parity/artifacts/iter874_p1_inline_acquisition"
    if old_root not in tail:
        raise ValueError("expected inline output root is absent")
    return tail.replace(old_root, ARTIFACT_ROOT)


def render(body: str, tail: str) -> str:
    return f'''-- Rendered offline for Ralph iteration 881. Do not run outside smr-harness.
-- Two-stage protocol: generator returns before the observer starts final-state acquisition.
-- Protected iter780 generator SHA256: {GENERATOR_SHA256}
-- Source inline acquisition SHA256: {INLINE_SHA256}
HARNESS.scenario("p1_two_stage_acquisition", function(ctx)
\tctx:record("protocol", "generator_returns_before_observer_acquisition")
\tctx:record("stage1_done", "{ARTIFACT_ROOT}/stage1_returned.done")
\tctx:record("observer_done", "{ARTIFACT_ROOT}/producer.done")
\trawset(_G, "g_ParityTwoStageStatus", "scheduled")

\tCreateRealTimeThread(function()
\t\tlocal STAGE1_STARTED_DATA = "{ARTIFACT_ROOT}/stage1_started.json"
\t\tlocal STAGE1_STARTED_DONE = "{ARTIFACT_ROOT}/stage1_started.done"
\t\tlocal STAGE1_RETURNED_DATA = "{ARTIFACT_ROOT}/stage1_returned.json"
\t\tlocal STAGE1_RETURNED_DONE = "{ARTIFACT_ROOT}/stage1_returned.done"
\t\tlocal PRODUCER_DATA = "{ARTIFACT_ROOT}/producer.json"
\t\tlocal PRODUCER_DONE = "{ARTIFACT_ROOT}/producer.done"
\t\tlocal result = {{
\t\t\tschema = "smr.ralph.full-z-parity.p1-two-stage-producer.v1",
\t\t\tprotocol = "generator_returns_before_observer_acquisition",
\t\t\tprotected_generator_sha256 = "{GENERATOR_SHA256}",
\t\t\tinline_source_sha256 = "{INLINE_SHA256}",
\t\t\tok = false,
\t\t\trecords = {{}},
\t\t}}
\t\tlocal function record(key, value) result.records[tostring(key)] = value end
\t\tlocal function expect_eq(actual, expected, label)
\t\t\tif actual ~= expected then
\t\t\t\terror(tostring(label) .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
\t\t\tend
\t\tend
\t\tHARNESS.marshal(STAGE1_STARTED_DATA, STAGE1_STARTED_DONE, {{ status = "stage1_started" }})

\t\tlocal generated, generation_error = xpcall(function()
\t\t\t-- BEGIN EXACT ITER780 GENERATOR BODY (wrapper and terminal return removed only)
{body}\t\t\t-- END EXACT ITER780 GENERATOR BODY
\t\tend, debug.traceback)
\t\tif not generated then
\t\t\tresult.status = "generation_error"
\t\t\tresult.error = tostring(generation_error)
\t\t\trawset(_G, "g_ParityTwoStageStatus", result.status)
\t\t\tHARNESS.marshal(PRODUCER_DATA, PRODUCER_DONE, result)
\t\t\treturn
\t\tend

\t\tCreateRealTimeThread(function()
\t\t\tHARNESS.marshal(STAGE1_RETURNED_DATA, STAGE1_RETURNED_DONE, {{ status = "observer_started" }})
\t\t\tlocal observed, observer_error = xpcall(function()
{tail}
\t\t\t\tresult.ok = true
\t\t\t\tresult.status = "complete"
\t\t\tend, debug.traceback)
\t\t\tif not observed then
\t\t\t\tresult.status = "observer_error"
\t\t\t\tresult.error = tostring(observer_error)
\t\t\tend
\t\t\trawset(_G, "g_ParityTwoStageStatus", result.status)
\t\t\trawset(_G, "g_ParityTwoStageResult", result)
\t\t\tHARNESS.marshal(PRODUCER_DATA, PRODUCER_DONE, result)
\t\tend)

\t\trawset(_G, "g_ParityTwoStageStatus", "generator_returned_observer_scheduled")
\t\t-- Returning here is the specific previously-unmatched transaction boundary.
\tend)

\tctx:record("stage1", "scheduled")
\treturn "p1_two_stage_acquisition_scheduled"
end)
'''


def main() -> int:
    if sha256(GENERATOR).lower() != GENERATOR_SHA256:
        raise SystemExit(f"protected generator hash changed: {GENERATOR}")
    if sha256(INLINE).lower() != INLINE_SHA256:
        raise SystemExit(f"inline source hash changed: {INLINE}")
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(render(generator_body(GENERATOR.read_text(encoding="utf-8")), acquisition_tail(INLINE.read_text(encoding="utf-8"))), encoding="utf-8")
    print(OUTPUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

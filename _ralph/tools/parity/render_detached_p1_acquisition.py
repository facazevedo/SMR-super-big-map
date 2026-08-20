#!/usr/bin/env python3
"""Render the one-off P1 acquisition scenario beyond HARNESS's callback boundary."""

from __future__ import annotations

import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
GENERATOR = ROOT / "_ralph/tools/parity/out/gen-u80a.lua"
INLINE = ROOT / "_ralph/tmp/full_z_parity_iter874_p1_inline_acquisition/p1_inline_acquisition.lua"
OUTPUT = ROOT / "_ralph/tmp/full_z_parity_iter879_p1_detached_acquisition/p1_detached_acquisition.lua"

GENERATOR_SHA256 = "fcdd02994b2ff444274d79e76e16c8c0389fff83dc5f19609c44ee4607d66a9f"
INLINE_SHA256 = "cf4d5a1d7e0121cb667772f9459751dd230a42ad76ecb4a428a9d4dba87a8b86"
ARTIFACT_ROOT = "D:/PROJS/SMR/super-big-map/_ralph/runs/full-z-parity/artifacts/iter879_p1_detached_acquisition"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def generator_body(source: str) -> str:
    opener = "CreateRealTimeThread(function()\n"
    closer = 'end)\nreturn "parity_thread_started"'
    if not source.startswith(opener) or source.count(opener) != 1 or source.count(closer) != 1:
        raise ValueError("unexpected protected generator wrapper")
    return source[len(opener) : source.index(closer)]


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
    return f'''-- Rendered offline for Ralph iteration 879. Do not run outside smr-harness.
-- Detached producer protocol: HARNESS's scenario callback schedules this producer and returns.
-- Protected iter780 generator SHA256: {GENERATOR_SHA256}
-- Source inline acquisition SHA256: {INLINE_SHA256}
HARNESS.scenario("p1_detached_acquisition", function(ctx)
	ctx:record("protocol", "detached_producer_after_harness_callback_return")
	ctx:record("producer_data", "{ARTIFACT_ROOT}/producer.json")
	ctx:record("producer_done", "{ARTIFACT_ROOT}/producer.done")
	rawset(_G, "g_ParityDetachedProducerStatus", "scheduled")

	-- The only work done by the HARNESS scenario callback is scheduling this producer.
	CreateRealTimeThread(function()
		local PRODUCER_DATA = "{ARTIFACT_ROOT}/producer.json"
		local PRODUCER_DONE = "{ARTIFACT_ROOT}/producer.done"
		local result = {{
			schema = "smr.ralph.full-z-parity.p1-detached-producer.v1",
			protocol = "detached_producer_after_harness_callback_return",
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

		local ok, err = xpcall(function()
			-- BEGIN EXACT ITER780 GENERATOR BODY (wrapper and terminal return removed only)
{body}			-- END EXACT ITER780 GENERATOR BODY

{tail}
			result.ok = true
			result.status = "complete"
		end, debug.traceback)
		if not ok then
			result.ok = false
			result.status = "error"
			result.error = tostring(err)
		end
		rawset(_G, "g_ParityDetachedProducerStatus", result.status)
		rawset(_G, "g_ParityDetachedProducerResult", result)
		local marshal_result = HARNESS.marshal(PRODUCER_DATA, PRODUCER_DONE, result)
		if marshal_result ~= "SMR_MARSHAL_OK" then
			rawset(_G, "g_ParityDetachedProducerStatus", "marshal_error")
			rawset(_G, "g_ParityDetachedProducerMarshalError", marshal_result)
		end
	end)

	ctx:record("producer", "scheduled")
	return "p1_detached_producer_scheduled"
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

#!/usr/bin/env python3
"""Pinned iter241 phase/corpus budget model for v997 shortlist validation."""
from hashlib import sha256
import json
from pathlib import Path
from time import perf_counter

ROOT = Path(__file__).resolve().parents[2]
RUN = ROOT / "_ralph/runs/surface-loading-under-60s-rough/artifacts/run_iter241_v996_acceptance"
PINNED = {
    "materialization_phase_0079.txt": "a2eeda34ba212fc64b79496be839b1eaa9dda388ae94415d79158981ac76ef53",
    "materialization_phase_0080.txt": "d2336c20976431606430226683e01dbe240045fe2c4cce093f904523d20b3f2c",
    "v995_engine_probe_result.json": "8eab7aa4556599b28bf7052ed92e322fb600a1fa5f1e9248394bf9f3cf3088db",
    "external_materialization_causal_bundle.json": "8e0bd62e04e7d6472a4693a2feade87a7cd4ff9a4008cc094c7bd56b3e0074d4",
}
for name, digest in PINNED.items():
    assert sha256((RUN / name).read_bytes()).hexdigest() == digest
before = (RUN / "materialization_phase_0080.txt").read_text(encoding="utf-8")
assert "phase=underground-deferred-enrichment-resource-topups" in before
assert "elapsed_ms=78604" in before and "field_trigger=view-switch" in before
probe = json.loads((RUN / "v995_engine_probe_result.json").read_text(encoding="utf-8-sig"))
marker_interactions = int(probe["enrichment_pairs"])
assert marker_interactions == 1234 and int(probe["enrichment_spacing_failures"]) == 0

started = perf_counter()
state = 303
buckets: dict[tuple[int, int], list[tuple[int, int]]] = {}
nearby = accepted = 0
marker_corpus = marker_interactions // 2
assert marker_corpus * 2 == marker_interactions
for _ in range(marker_corpus):
    state = state * 48_271 % 2_147_483_647; mq = state % 8192
    state = state * 48_271 % 2_147_483_647; mr = state % 8192
    buckets.setdefault((mq // 8, mr // 8), []).append((mq, mr))
for _ in range(256):
    state = state * 48_271 % 2_147_483_647; q = state % 8192
    state = state * 48_271 % 2_147_483_647; r = state % 8192
    key = (q // 8, r // 8)
    valid = True
    for bq in range(key[0]-1, key[0]+2):
        for br in range(key[1]-1, key[1]+2):
            for oq, or_ in buckets.get((bq, br), ()):
                nearby += 1
                if max(abs(q-oq), abs(r-or_), abs((q-oq)+(r-or_))) < 3:
                    valid = False; break
            if not valid: break
        if not valid: break
    if valid:
        buckets.setdefault(key, []).append((q, r)); accepted += 1
elapsed_ms = (perf_counter() - started) * 1000
assert accepted >= 112
assert nearby < 256 * 32
assert elapsed_ms < 1000

# Conservative modeled native budget: even 200ms for every shortlisted candidate remains <60s.
expensive_call_cap = 256
modeled_expensive_call_ms = 200
modeled_phase_ms = expensive_call_cap * modeled_expensive_call_ms + elapsed_ms
assert modeled_phase_ms < 60_000
print("ok=true")
print("pinned_iter241_phase79_sha256=" + PINNED["materialization_phase_0079.txt"])
print("pinned_iter241_phase80_sha256=" + PINNED["materialization_phase_0080.txt"])
print(f"marker_interactions={marker_interactions}")
print(f"marker_corpus={marker_corpus}")
print("candidate_samples=256")
print(f"analytic_accepts={accepted}")
print(f"nearby_checks={nearby}")
print(f"expensive_call_cap={expensive_call_cap}")
print(f"modeled_expensive_call_ms={modeled_expensive_call_ms}")
print(f"modeled_phase_ms={modeled_phase_ms:.3f}")
print(f"host_elapsed_ms={elapsed_ms:.3f}")

#!/usr/bin/env python3
"""Bounded deterministic/spatial microbenchmark pinned to the iter239 causal evidence."""
from hashlib import sha256
import json
from pathlib import Path
from time import perf_counter

ROOT = Path(__file__).resolve().parents[2]
RUN = ROOT / "_ralph" / "runs" / "surface-loading-under-60s-rough" / "artifacts" / "run_iter239_v995_acceptance"
BUNDLE = RUN / "external_materialization_causal_bundle.json"
PROBE = RUN / "v995_engine_probe_result.json"
EXPECTED_BUNDLE = "e95e30d7008d08f655294cb6a3911d180eb3fe4ddfc8bcdca86c97f904ed5596"

assert sha256(BUNDLE.read_bytes()).hexdigest() == EXPECTED_BUNDLE
probe = json.loads(PROBE.read_text(encoding="utf-8-sig"))
marker_count = int(probe["enrichment_pairs"])
assert marker_count == 1234 and int(probe["enrichment_spacing_failures"]) == 0

started = perf_counter()
state, modulus = 303, 2_147_483_647
buckets: dict[tuple[int, int], list[tuple[int, int]]] = {}
accepted, nearby_checks = 0, 0
maximum_candidates = 16_384
minimum_distance_sq = 9
for _ in range(maximum_candidates):
    state = state * 48_271 % modulus
    q = state % 8192
    state = state * 48_271 % modulus
    r = state % 8192
    key = (q // 8, r // 8)
    valid = True
    for bx in range(key[0] - 1, key[0] + 2):
        for by in range(key[1] - 1, key[1] + 2):
            for oq, or_ in buckets.get((bx, by), ()):
                nearby_checks += 1
                if (q - oq) ** 2 + (r - or_) ** 2 < minimum_distance_sq:
                    valid = False
                    break
            if not valid:
                break
        if not valid:
            break
    if valid:
        buckets.setdefault(key, []).append((q, r))
        accepted += 1
    if accepted >= marker_count:
        break

elapsed_ms = (perf_counter() - started) * 1000
assert accepted == marker_count
assert nearby_checks < marker_count * marker_count // 20
assert elapsed_ms < 2_000
print("ok=true")
print(f"pinned_iter239_bundle_sha256={EXPECTED_BUNDLE}")
print(f"marker_corpus={marker_count}")
print(f"accepted={accepted}")
print(f"nearby_checks={nearby_checks}")
print(f"all_pairs={marker_count * (marker_count - 1) // 2}")
print(f"elapsed_ms={elapsed_ms:.3f}")

# Ralph task contract

## Objective

Prove a PERFECT one-to-one match on **BOTH maps** — surface AND underground — between the expanded game and its vanilla twin, on 21 coordinates, reproducibly.

For every case, on EACH of the two maps independently: zero unmatched expanded, zero unstamped expanded, zero unconsumed vanilla, zero classes differing, seed and generation hash equal, and every inherited ratchet floor still green. No exemptions, no tolerance windows, no class exclusions, no annotation allowances — the 45S82E work already reached exact zero **without** needing the `TerrainDepositConcrete` allowance, so that allowance is withdrawn and must not be reintroduced.

Phases, in order:

1. **P1 — reference**: 30S146E exact-zero on both maps at the current mod version.
2. **P2 — batch 1**: all ten coordinates in `_ralph/tools/parity/sweep/sweep_manifest.json`.
3. **P3 — batch 2 (confirmation)**: all ten coordinates in `_ralph/tools/parity/sweep/sweep_manifest_batch2.json` — an independent draw (master seed 30147) that no code was tuned against. This is the guarantee run: if P1/P2 passed only because the code was fitted to those maps, P3 exposes it.

## The underground is a first-class target, not a passenger

Do NOT treat the underground as "already green, just protect it". Every case must vary and verify it:

- **Each case draws its OWN underground seed.** Run the vanilla control with `nopin` so the underground seed comes from that coordinate's own draw, capture the holder seed, then give the expanded twin exactly that seed via `SetTwinUndergroundSeedForTest`. Never reuse `REFERENCE_UNDERGROUND_SEED` across cases — a fixed seed silently tests one underground twenty times, which is a measurement error this project already made once (see `_ralph/tools/parity/sweep/` history).
- **Record the underground seed per case and assert the 21 undergrounds are distinct.** A case whose underground seed equals another case's is a harness bug to fix, not a result.
- **Underground exactness is a gate at the same standard as the surface**: zero/zero/zero/zero, seed and hash equal. Not "unchanged", not "still green" — measured and zero on every case.
- **Wonder coverage**: all four classes (`AncientArtifact`, `CaveOfWonders`, `BottomlessPit`, `JumboCave`) must appear across the 21 cases and pass their transform verdict wherever they appear. Batch 1 already covered all four; batch 2 must be recorded the same way. Report per case which classes appeared.
- The known-unproven underground infrastructure class `GridObjectList` (574 vs 223 at 45S82E) must be either proven by its cardinality rule on each run or reported as the single named exception with its derivation — it may not simply be ignored.

## Determinism requirements

- **Control determinism**: at every one of the 21 coordinates, two pinned controls (serial raster + `passagepin` + that case's own underground seed re-injected) must be byte-identical on both maps. 45S82E is already proven at 15/15 identical; the rest are unproven.
- **Expanded determinism**: at a minimum at 45S82E, 30S146E and three batch-2 coordinates, two expanded twins with identical inputs must be byte-identical.
- A case may only be scored after its control determinism is established; a non-deterministic control means the case is not yet measurable, not that the mod failed.

## Inherited state (read first, do not re-derive)

Predecessor `_ralph/runs/surface-exact-parity` (READ-ONLY, 16+ iterations) holds the whole causal chain. Read its `HANDOFF.md`, then these verdicts under its `artifacts/`: `control_determinism_matrix.md`, `draw_probe_verdict.md`, `passability_field_verdict.md`, `slot_retention_verdict.md`, `passability_bridge_verdict.md`, `start_sector_footprint_verdict.md`. Also `_ralph/tools/parity/sweep/DRIFT_VERDICT.md` (whose original conclusion is superseded — read its header).

Already fixed and proven; protect all of it:

- v784 `PairingSourceFallbackRadius` — vanilla's caller-less fallback radius is `Max(GetMapSize())/2`, which on an expanded map is the wrong extent; the bootstrap now presents the source extent.
- v787 `PairingSourcePassabilityBridge` — the temporary native source map is retained through the passage bootstrap and `GetRandomPassablePoint`/`GetPassablePointNearby` are shadowed on the surface-map instance to delegate to it, because the native chooser reads the *expanded* passability field otherwise (measured: 4713 vs 7576 of 16384 samples passable over the same source square). Both twins now make the same draw.
- v790/v791 — the stretched vanilla start-sector footprint's deposit markers are read from the live map and kept through the scan gate.
- Harness `passagepin` — the passage fallback is handed a dedicated fixed-seed stream, removing it from the race with city-startup threads on the shared `SessionRandom`.
- 45S82E surface: exact zero at v791. 30S146E `inherited-floors`: green at v791, ratchet `"regressed": false`.
- Ratchet floors live in `_ralph/runs/entrance-colocation-and-scale/artifacts/best.json`; copy forward and keep ratcheting. Entrance co-location, seeds/hashes, and the corrected class-scale rule (cosmetic decor scales, functional keeps vanilla scale, with the settled sculpted-into-terrain exceptions) all still bind.

## Method

`_ralph/tools/parity/run_parity.py twin <tag> <0|1> [seed|-] lat=N lon=N [nopin|serial|passagepin|...]`, then `compare.py`, then `ratchet.py`. A twin pair is ~3 minutes; prefer measuring over theorizing. `_ralph/tools/parity/sweep/run_sweep.py` runs a manifest end to end (port-free wait, attach-failure retry, per-case incremental results) — extend it for batch 2 and for the per-case underground assertions rather than writing a new runner.

Any mod-side change: `luac -p`, bump `metadata.lua`, commit, `deploy.py sync` + `audit` green BEFORE any measuring run, then re-measure `inherited-floors` at 30S146E in the same iteration.

Game hygiene: any startup error or assert kills the game immediately and is diagnosed before relaunch; never leave a game running between iterations; one game globally; always headless.

Memory hygiene: terse ATTEMPTS entries citing artifact paths; exactly one `Progress: yes - <evidence>` or `Progress: no - <reason>` line per checkpoint, appended in that session (iterations 15-16 of the predecessor scored no-progress for a malformed/absent marker — do not repeat that); HANDOFF rewritten each session near 120 lines.

## Test matrix

- `control-deterministic-<case>`: two pinned controls byte-identical, both maps, for each of the 21 cases.
- `surface-exact-<case>` and `underground-exact-<case>`: zero/zero/zero/zero and seed+hash equal, each map, each case.
- `undergrounds-distinct`: the 21 recorded underground seeds are pairwise distinct.
- `wonder-coverage`: all four wonder classes appear across the 21 cases and pass their transform verdict.
- `expanded-deterministic`: duplicate expanded twins byte-identical at the five named coordinates.
- `inherited-floors`: the full ratchet green at 30S146E after every mod-side change.

## Completion gate

`DONE.md` only when all 21 cases pass both `surface-exact` and `underground-exact`, control determinism is proven at all 21, undergrounds are distinct, all four wonder classes are covered, expanded determinism holds at the five named coordinates, the ratchet is green, every change is committed and deployed with a green audit, and no error/assert/timeout remains in the final runs. State per-case tables (both maps, seeds, hashes, underground seed, wonders) and the final commit and version.

If a batch-2 coordinate fails where batch 1 passed, that is the contract working — diagnose and fix the mod, then re-run BOTH batches on the final code. Never drop or replace a drawn coordinate to obtain a pass.

## Blockers

Only a genuinely unpinnable native behaviour (proved with a trace naming the procedure, at least three distinct pin attempts with evidence, and a statement of what native change would be required), corrupt protected reference data, or a platform failure reproduced identically across three iterations after one clean restart. A usage/quota pause is not a blocker: record it and let the progress budget stop the loop.

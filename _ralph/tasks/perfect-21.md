# Ralph task contract

## Objective

PERFECT one-to-one equivalence between the vanilla twin and the expanded map, on BOTH maps, at ALL 21 coordinates. Zero unmatched, zero unstamped, zero unconsumed, zero class-count differences, seeds and generation hashes equal. A near miss is not a pass: one object out of ten thousand fails the case.

The 21 coordinates: P1 = 30S146E (lat 1800, lon 8760); the ten in `_ralph/tools/parity/sweep/sweep_manifest.json`; the ten in `_ralph/tools/parity/sweep/sweep_manifest_batch2.json`. Never redraw, drop, or substitute a coordinate to obtain a pass.

Every expanded object must be the vanilla object stretched: position = the affine image of its immutable source coordinate (hex-snapped only where that class's placement rule is a hex snap), scale per the class rule (cosmetic decoration scales with the terrain; functional objects keep vanilla scale; the settled sculpted-into-terrain exceptions — PrefabFeatureMarker, CaveInRubble, TunnelBlockerRubble, BottomlessPit, JumboCave — scale), angle equal, Z per class-appropriate terrain-relative semantics.

## The only two exemptions, both explicit and bounded

1. **Entrance/passage family** — `UndergroundPassage`, `SurfacePassage`, `SurfaceUndergroundTunnelSign`, `Surface/UndergroundTunnelMarker`, `ElevatorBuildIndicator_*`. Expanded deliberately co-locates a passage pair on one hex, which vanilla does not do (vanilla drifts and can fall back to a random passable point). Their positions may differ; their COUNTS must still match exactly, and co-location must hold (0 hex delta) on every case.
2. **Commander-profile bonus deposit** — the vanilla start tail places a profile-gated deposit (hydroengineer water, astrogeologist precious metals). Tag it by provenance, never by class name, and only where vanilla placed one too.

Nothing else is exempt. Enumerated engine infrastructure (MapSector, sector decals, GridObjectList, CameraObj, RandomMapGeneratorHolder) must PROVE its cardinality rule per run, exactly as `compare.py` already requires — an unproven infrastructure class is a failure, not an exclusion.

## Control determinism is a prerequisite, and it is achievable

A case can only be scored against a control that reproduces itself. Two pinned vanilla runs at the same coordinate must be byte-identical on both maps before that case counts.

Proven pins: `serial` rasterization, `passagepin` (a dedicated fixed-seed stream for the passage fallback, which removed it from the race with city-startup threads on the shared `SessionRandom`), and re-injecting that case's own drawn underground seed.

KNOWN GAP — b2-01 (51S13W, lat 3060 lon -780). MEASURED 2026-08-14, mod v797, harness 0ebd543:

- Two controls with `serial` + `passagepin` + the same injected underground seed produced 8366 vs
  8038 surface objects with only ~200 rows in common.
- Their generation INPUTS are identical: preset `BlankBigTerraceCMix_11`, `gen_seed`
  5434768309385999931, `gen_hash` 6358497127468097730, underground seed 6897190323242569227.
- Prefab rasterization IS serialized and verified through the generator's own environment
  (`raster div before: 8`, `raster div seen by generator: 1`, one const table). So the
  rasterization race is RULED OUT as the cause.
- `passage_pin_calls` is empty on these runs, so the passage fallback race is RULED OUT too.

Therefore something inside generation reads a value that varies between processes while seed,
hash and preset stay equal. FIND IT AND NAME IT — this is the task, not an accepted limit. The
divergence is near-total (~2.5% of rows survive), which is the signature of a SHARED RANDOM
STREAM SHIFTING EARLY rather than a local placement race: one extra or missing draw near the
start re-rolls everything downstream. Precedent: at 45S82E the flip was exactly this, the passage
fallback drawing at stream position 11 versus 738 (`surface-exact-parity/artifacts/draw_probe_verdict.md`).

Leads, cheapest first:
1. The mod's procedure trace (`sbm_map_generation.lua` ~L923-1976, config `TraceUndergroundRockParity`)
   brackets every generator procedure by ordinal and captures sorted object manifests. Run it on two
   vanilla controls at 51S13W that land on different variants and diff per-ordinal: the FIRST
   procedure whose manifest differs names the consumer.
2. `run_parity.py`'s `drawprobe` wraps the shared `SessionRandom` and logs every draw with its
   consumer. It is a biased observer (its tracebacks changed which variant won at 45S82E), so use it
   to identify the CONSUMER and the draw ordinal, not to decide the outcome.
3. Suspect any generator input not derived from `gen.Seed`: `AsyncRand()` calls during generation,
   anything seeded from time or process state, and iteration over a hash/handle-keyed container
   whose order depends on object-handle allocation (which async asset load timing can perturb).
4. Once named, pin it in the CONTROL harness the same way `passagepin` pinned the passage fallback
   (a dedicated fixed-seed stream), and re-prove ten consecutive byte-identical controls.

### The required approach: REPLICATE the varying input, do not merely pin it

The expanded run generates its vanilla source IN THE SAME PROCESS as the expanded map, so
whatever varying input a vanilla generation reads, the expanded run's source generation reads
its own instance of it. That is why the expanded source is always A valid vanilla map, and why
only a SEPARATE vanilla process disagrees.

So the fix is the same shape as the underground seed, which is already solved this way: the
control DRAWS its underground seed, the harness CAPTURES it, and
`SuperBigMap.MapGeneration.SetTwinUndergroundSeedForTest` INJECTS it into the expanded run so
both generate the same underground. Do exactly that for whatever varying input is found:

1. NAME the input (which call, which consumer, which draw ordinal).
2. CAPTURE its value in the vanilla control run and report it in that run's result.
3. INJECT the captured value into the expanded twin's SOURCE generation, through a
   scenario-agnostic test seam beside `SetTwinUndergroundSeedForTest` (production gameplay must
   keep drawing normally; the seam exists only for the twin harness).
4. Re-measure: both twins then generate the identical map and the case must be exact zero.

Pinning the control to a fixed value is acceptable ONLY where the same value can also be
injected into the expanded twin, so the two remain genuinely comparable. A pin that makes the
control reproducible but leaves the expanded twin drawing its own value is NOT a solution - it
just moves the mismatch.

A coordinate whose control cannot be pinned is NOT a pass and NOT a silent exclusion: it is a `BLOCKED.md` with the trace naming the exact procedure, at least three distinct pin attempts with evidence, and a statement of what would be required. Every other coordinate must still be proven green.

## Method (do not redesign the harness)

`run_parity.py twin <tag> <0|1> <seed|-> lat=N lon=N [serial|passagepin|nopin|placeprobe|hexgrid|...]` — about 3 minutes per twin. Per case: vanilla control with `nopin` to draw that coordinate's own underground seed, capture it, re-run the control pinned to it for the determinism proof, then the expanded twin with that exact seed injected, `serial` and `passagepin` on BOTH sides. Then `compare.py`, then `ratchet.py`. `sweep/run_sweep.py` runs a manifest end to end (port-free wait, attach retry, incremental per-case results) — extend it rather than writing another runner.

Each case's underground must be its own: the 21 underground seeds must be pairwise distinct, and all four wonder classes must appear across the set and pass their transform verdicts.

## Current state (inherited; protect it, do not re-derive)

- **CONTENT-EXACT on both maps at v797**: P1 (30S146E) and 45S82E. These are the floors — re-measure both after EVERY mod change; a regression is fixed or reverted in the same session.
- **Underground content is exact on every coordinate measured so far.**
- Fixed and holding: fallback radius (v784), passability bridge (v787), start-footprint deposits (v790/791), subsurface-anomaly start spawns (v794), full-winner capture (v797).
- **Three known single-object residues**, each one object per coordinate, all in the start-reveal spawn set:
  - b2-04 (4S107E): `TerrainDepositConcrete 1->0`. It is `revealed[2]` content (vanilla's auxiliary nearest-concrete sector, which vanilla SCANS) and its spawn needs the relocated terrain imprint painted first (`MoveConcreteImprints`).
  - b2-07 (55S164E): `ParSystem 5->4` — the rare anomaly's "Revealed" FX carrier. Direct `PlayFX` and a `DelayedCall`-deferred replay both measurably fail; probe where vanilla's carrier is actually created rather than guessing timing.
  - b2-10 (51S110W): `SubsurfaceDepositWater 0->1` — an unidentified placer acts AFTER the reveal despawn sweep (marker source (272000,476300), native-stamped, `is_placed=1`). The `placeprobe` in `run_parity.py` exists but its per-call `debug.traceback` CRASHES the game; lighten it (ordinal + phase + CurrentMap, no traceback) before using.
- **v796/v797 proved the fix direction**: membership rules re-derived on the destination cannot reproduce vanilla's spawn OUTCOMES, because vanilla evaluated `CanPlaceDeposit` on NATIVE terrain (v797 overshot: +4 SurfaceDepositMetals, +1 SubsurfaceDepositMetals, +1 ParSystem at b2-04). `VanillaStartPick` already re-runs vanilla's `InitialReveal` on the native source and receives its exact `spawn_positions` and revealed sector set. STAGE that spawn set by source identity (per revealed sector, per depth list — block/surface/subsurface, exactly `MapSector:Scan`'s unexplored branch) with native spawn positions, then on the destination spawn exactly the staged set (marker resolved by source stamp; spawn position = stretch of the native position; imprint painted first where the deposit needs terrain paint) and suppress every destination-side re-derivation. The staged set is the single source of truth.
- Read-only predecessors: `full-object-parity`, `entrance-colocation-and-scale`, `entrance-colocation-v2`, `surface-exact-parity`, `exact-parity-both-maps`, `start-spawn-parity`. Ratchet semantics and floors: `entrance-colocation-and-scale/artifacts/best.json` (includes the `entrance` family). Verdicts worth reading before theorizing: `surface-exact-parity/artifacts/{control_determinism_matrix,draw_probe_verdict,passability_field_verdict,passability_bridge_verdict,start_sector_footprint_verdict}.md` and `_ralph/tools/parity/sweep/DRIFT_VERDICT.md` (whose original conclusion is superseded — read its header).

## Order of work

1. Land the staged-spawn replay and take b2-04, b2-07, b2-10 to exact zero, with P1 and 45S82E floors re-proven.
2. Prove control determinism at every remaining coordinate; pin b2-01's race.
3. Measure all 21 to exact zero on both maps.
4. `save-roundtrip` (never yet tested): save the expanded P1 game under prefix `ralph_sbm_parity_`, clean stop, cold restart, load, recount both maps green.

## Non-negotiables

Zero means zero — no tolerances, no widened gates, no new class exemptions, no hand-edited `best.json`. Weakening `compare.py` or the dump to move a number is a contract violation. Every mod change: `luac -p`, version bump, commit, `deploy.py sync` + `audit` green BEFORE any measuring run. Any startup error or assert kills the game immediately and is diagnosed before relaunch; never leave a game running between iterations; one game globally; always headless. Terse ATTEMPTS entries citing artifact paths, exactly one `Progress:` line per checkpoint appended in that session; HANDOFF rewritten near 120 lines; consolidate past ~1000 lines.

## Completion gate

`DONE.md` only when all 21 coordinates pass on BOTH maps with per-case tables (seeds, hashes, underground seed, wonder classes, zero-diff columns), control determinism is proven at all 21, the 21 undergrounds are distinct, all four wonder classes are covered, the ratchet is green, `save-roundtrip` passes, everything is committed and deployed with a green audit, and no error, assert, crash, timeout or teardown failure remains in the final runs. State the final commit and version, and document the staged-spawn design and the b2-01 pin in HANDOFF.

## Blockers

Only: a genuinely unpinnable native race (trace naming the procedure + three evidenced pin attempts + what native change would be needed), corrupt protected reference data, or a platform failure reproduced identically across three iterations after one clean restart. A usage/quota pause is NOT a blocker and does not consume the progress budget — record it and continue when it clears.

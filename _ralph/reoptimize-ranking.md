# Re-applying the `61d4ad6..ee56197` optimizations one at a time — risk ranking

Written 2026-09-07 for branch `reoptimize` (v924 `74922e1`, all ten rules-parity gates green at
14N134W and 15S67E). Source of the changes: the optimization loop that ended at `69b4cac` /
`ee56197` (276 commits, +13,683 lines over `sbm_map_generation.lua`, `sbm_terrain_copy.lua`,
`sbm_deposits.lua`). Companion to the closed record `_ralph/optimizations-since-61d4ad6.md`.

## How the ranking was made

Each unit is one config flag (or one unflagged commit) from that line. Risk is judged on five
things, all read off the history rather than guessed:

1. **Blast radius** — lines and files the unit needs, and whether it touches functions the
   `reoptimize` loop already changed (`AlignPassagePairsToSharedHex`, `PrepareOuterResourceTerrain`,
   `AuditOuterResourceTerrain`, `RunSurfaceStretchIfEnabled`, `TopUpDeposits`,
   `RelocateUnreachableUndergroundEnrichments`).
2. **Output-preserving or behaviour-changing** — whether the enrichment/decor/height digests the
   rules probe already records must stay identical (cheap, exact acceptance) or are allowed to move
   (needs the full gate table plus a visual check).
3. **Fallback in `ee56197`** — listed for information only. **Owner ruling 2026-09-07: no silent
   fallbacks in the port.** When the optimized path cannot run or its own check fails, it must fail
   loudly (see "Failure policy"), never quietly rerun the v887 path.
4. **Defect history** — fixes, reverts and re-lands in that area during the campaign
   (lazy underground 41 commits / 0 reverts = patched forward, 6 "Fix" commits; crease 26 / 9 reverts,
   the border wall; aprons 20 / 7; rockets 10 / 3; top-ups 23 / 4; ring rebuild 0).
5. **Dependencies** — what it needs from other units, and whether it still makes sense on
   `reoptimize` (entrances are now glued to their twins; ring passage pads are gone).

Porting note: the flags' code is **not** in clean single commits. Several flags first appear in
mixed Aug-31 commits (`fa80dee`, `85e7ba0`, `6b79f77`), and the series was rewritten in place
many times, so cherry-picking onto v887-era code will not apply. Port **per unit**: copy the
optimized functions from `ee56197`, **replace** the v887 code they supersede (do not keep it as a
runtime fallback), and strip the `ee56197` fallback branches. A/B is done between commits
(previous version's digests vs the new one), not with a runtime switch.

## Failure policy (no fallbacks)

Every ported unit fails loudly at the point where `ee56197` would have fallen back:

- `error()` with a message naming the unit and the failed check. In this engine an error inside
  generation is logged as `[LUA ERROR]` and execution continues, so the error alone is not enough
  to stop a half-written map from reaching the player; therefore also:
- record the failure on the map (`SuperBigMap.State.optimization_failures[#+1] = {unit, reason}`)
  and surface it: the rules probe reads the list (gate 8 turns red), and the in-game restart
  notice shows "map generation failed: <unit>" so a manual run is unmistakable too;
- never continue past a failed *terrain write* check: leave the grid as it is and mark the map
  failed rather than repairing it with the legacy raster.

What counts as a failure is exactly what the `ee56197` guards already test — missing native API,
allocation failure, enumeration/count mismatch, certificate mismatch, transaction-order mismatch —
so the guards stay, only their `else` branch changes from "rerun legacy" to "fail".

Already on `reoptimize`, do not re-port: seed-derived placement RNG (`5bce450` ≈ `a2ba28b`),
single start-sector reveal, badges pre-reveal, one loading display on first access (loop commits).
The entrance oracle (`04a103f`) is unnecessary while the underground is generated eagerly.

## Step 0 (recommended before any port)

One profiled cold run at v924 with `config.DebugLoadingTimings = true` (the engine's own loading
timings) to see where the ~315 s Start-boundary time goes. The biggest drop of the campaign
(about 330 s to 145 s at the New-Game boundary, v887 to v963, Aug 24–28) was never attributed per
unit, so the value column below is only known for units landed after the ledger started.

## Ranking — least risky first

| # | Unit (flag / commit) | Size | Output | Fallback in `ee56197` (remove; fail loudly) | History | Depends on | Measured value | Gate |
|---|---|---|---|---|---|---|---|---|
| 1 | Numeric hex keys — `4fe9889` | 12/4 lines, `sbm_deposits` | preserving (digest `486921541` unchanged) | n/a | 0 fixes | — | top-up step 23.6 → 19.4 s together with #2 | digests identical to v924 floor |
| 2 | Verdict cache before min-distance scan, negatives cached — `ca28e66` | 13/5 lines | preserving | n/a | 0 | #1 | (with #1) | digests identical |
| 3 | Apron raster math primitives bound once — `b617030` | 31/26 lines, Lua locals | preserving | n/a | 0 | — | 78.2 → 75.8 s (New-Game) | digests identical |
| 4 | Spacing-audit spatial index — `OptimizeTopUpHardSpacingSpatialIndex` (`eb614c6`) | ~870 lines but audit-only | preserving (order, counters, first violation kept) | quadratic audit | 0 | — | unmeasured; audit is O(n²) over ~700 markers | identical audit counters, digests identical |
| 5 | Ring-only passability rebuild — `OptimizeOuterResourceTerrainRingRebuild` (`80a0452`, rectangles in iterations 246–247) | 306 lines | preserving (later whole-map rebuilds unchanged) | whole-map rebuild | 0 | ring writer confined to the outer two sectors (true at v887) | 85.8 → 80.9 s | digests identical; passability spot-check at the ring boundary |
| 6 | Buildable snap for resource draws — `OptimizeSurfaceResourceBuildableSnap` | in `template_option`, `sbm_deposits` | **changing** (positions move, still seed-deterministic) | v887 draw | 0 | — | 90.2 → 85.8 s | full gate table; new digests stable across the seed pair |
| 7 | Rocket relief-score deferral — `OptimizeOuterResourceRocketReliefDeferral` (`7e55f2b`) | 357 lines | preserving (same predicate, winners only) | eager sampling | reverted once, re-landed | — | unmeasured | pad positions identical |
| 8 | Cache pad terrain samples / index clearance cells — `785fdd8`, `1690332` | 130 + 193 lines | preserving | n/a | 0 | — | unmeasured | pad positions identical |
| 9 | Height-step rolling window — `OptimizeHeightStepRefineRollingWindow` (`70d1c33`) | 347 lines | preserving (read pattern only) | scalar | 0 | — | unmeasured | height-grid digest identical flag on/off |
| 10 | Native crease discovery indexes — `OptimizeHeightStepNativeDiscoveryIndex` (`cfe5751`), `OptimizeHeightStepNativeSourceDiscoveryIndex` (`fd3b7dd`) | 530 + 604 lines | preserving (read-only, sorted back to legacy order) | scalar scan | 0 on the discovery side | — | unmeasured | height-grid digest identical |
| 11 | Defer pipeline-end rebuild — `OptimizeDeferImmediateSurfaceFinalGridRebuild` (`06de4ac`) | 177/37 lines, `RunSurfaceStretchIfEnabled` | preserving if the first real-time boundary rebuild runs | immediate rebuild | 0 | the pause-hold window from `0163944` (loop fix); re-verify gate 8 | unmeasured (one whole-map rebuild) | gate 8 no asserts, digests identical |
| 12 | Coarsen outer terrain mask sampling — `0b4d357` | 31/13 lines | **changing** (coarser feather mask) | n/a | 0 | native raster (#13) | unmeasured | visual check of ring feathers |
| 13 | Native raster, outer resource terrain — `OptimizeOuterResourceTerrainNativeRaster` (`adabf65`, `217275b`, `caf42f4`, `71b4948`) | ~640 lines | claims formula-preserving; float path | legacy Lua raster from the untouched source grid | 3 reverts in the area | — | unmeasured individually; part of the 185 s early drop ("millions of height blends") | height-grid A/B flag on/off: identical or bounded ±1 |
| 14 | Settle high-relief components once — `OptimizeOuterResourceTerrainNativePrecondition` (`4f737b8`, `67277d5`, `477a035`, `d9434a0`) | ~250 lines | **changing** (removes the repair cycle) | broad feather + repair | 1 fix | #13 | unmeasured | ring and apron census as in gate 4; visual |
| 15 | Native raster, mountain aprons — `OptimizeMountainBaseApronNativeRaster` (`88bd7f3`, `445c466`, `8ea47d4`) | ~1,000 lines | claims formula-preserving | legacy raster after snapshot restore | **7 reverts/restores**, 4 rejected follow-ups | — | unmeasured; up to 288 aprons × 20-hex feather in Lua is a large v887 cost | height-grid A/B; apron census identical |
| 16 | Bounded rocket-pad planner — `OptimizeOuterResourceRocketBoundedPlanner` (`efdd09d`, rewritten next day in `2c2f398`) | ~1,200 lines changed | **changing** (pad positions) | exhaustive scorer from the journal | rewritten once | #7, #8 | unmeasured | gate 4 (pads == clusters, no failures), seed pair stable |
| 17 | Candidate-first perimeter — `OptimizeSurfaceResourceCandidateFirst` (`77eba56`, `f732e89`) | 431 lines | **changing** (cluster candidates) | precomputed quota | rejected then restored twice | — | unmeasured | gate 4 + digests stable |
| 18 | Streaming clusters — `OptimizeSurfaceResourceStreamingClusters` (`a5da1c7`, `2e8a88c`, `879f571`) | ~400 lines | **changing** | #17 as the fail-closed fallback | 0 | #17 | unmeasured | gate 4 + digests stable |
| 19 | Native crease translation / feather / refinement index — `OptimizeHeightStepNativeDestinationTranslation`, `OptimizeHeightStepNativeDestinationFeather`, `OptimizeHeightStepNativeRefinementIndex` | large, mixed commits | claims preserving; **the feather produced the border wall** (sign error + unsigned wrap) | scalar before the one-shot write | fixes `95e71ab`, `48e9a75`, clamp `f6e6863` | #9, #10 | translation 92.4 → 90.2 s; feather unmeasured | height-grid A/B **and** a border-profile check; port only with the three fixes |
| 20 | In-place source generation — `GenerateVanillaSourceOnTemporaryBacking = false` | architecture switch | preserving in principle | temporary backing | **intermittent native crash `c0000409` in `MaskBuildableGrid` (about half of first generations), two padding fixes wrong, unresolved** | — | −8.1 s, CI [6.6, 9.6] | 20 cold runs without a crash before flipping the default |
| 21 | Coalesced outer-ring publication — `OptimizeSurfaceCoalescedOuterRingPublication`; single-flush finalization — `OptimizeSurfaceSingleFlushFinalization` (`333dac0`) | 854+ lines | preserving | whole-map rebuild | 0 | **lazy capsules and the retired ring passage pads** | unmeasured | not portable as-is; needs a redesign against the glue rule |
| 22 | Lazy underground generation + sub-flags — `LazyUndergroundSourceGeneration`, `LazyUndergroundBoundedCapsulePlanner`, `LazyUndergroundFreshGridCapsulePlanning`, `LazyUndergroundPostCanonicalStockCapsuleSearch`, `LazyUndergroundOuterPassagePads`, `f9d3967` | ~7,000 lines, 41 commits | changes when the underground exists | none once `GenerateNextMap` is suppressed (sticky failure) | **0 reverts, 6 fixes, ~25-field certificate; first access still blocked at `a0bf4ed`** | conflicts with the working eager path and the glue in `AlignPassagePairsToSharedHex` | ~14 s underground generation + deferred enrichment | do last, or redesign minimal; gate 10 must stay green |

Skip: rank-then-filter (`86767a7`, no measured gain); everything in the record's §8 "tried and not kept".

## Suggested order

1. #1–#5 in one or two steps (all output-preserving; the digests already in the rules probe are
   the whole acceptance test). #1–#3 have no guard at all (pure rewrites), so "no fallback" costs
   nothing there; #4 and #5 lose their quadratic-audit / whole-map-rebuild rescue branches.
2. #6 buildable snap — first behaviour-changing step; re-prove the seed pair.
3. #7–#11 (rocket deferral and caches, crease discovery side, deferred end rebuild).
4. Native rasters #13 → #14 → #15, each A/B'd on the height grid with the flag on and off.
5. #16–#18 ring content planners.
6. #19 crease translation/feather with the wall fixes, border profile checked.
7. #20 in-place generation only after a crash-free soak; #21/#22 only with a new design.

## Step log

### Step 1 — #13 native raster, outer resource terrain (v925 `c2ab491` → v926 `9fcdef0`, 2026-09-07)

Measured at 14N134W with `t0t1_snapshot_14N134W.lua` (3 cold runs per side, Start-boundary clock):

| | before v924 | after v926 |
|---|---|---|
| T0→T1 | 406.9 / 408.9 / 400.9 s, **median 406.9 s** | 213.1 / 220.4 / 218.3 s, **median 218.3 s** (**−188.6 s, −46%**) |
| run-to-run terrain | 0 of 65,536 lattice samples vary | 0 of 65,536 vary |
| Lua errors / OptimizationFailure | 0 | 0 |
| audit | 7 extractor failures → 0 after one repair pass | same (7 → 0), 24/24 extractors buildable, 39 surface passable |
| resource sites (63) | — | identical kind/resource/hex/modified/verified |
| rocket pads (12) | — | 9 identical, **3 moved by one hex** (pads 6, 11, 12) |
| entrances | ring 13 / ring 0 | identical |
| height lattice, outer ring | — | 4.6% of samples differ; median 8 cm, p90 3.6 m, max 19 m (around the moved pads) |
| height lattice, interior | — | 0.2% differ, max 6.4 m (ring-boundary feathers, written by both versions) |

Why pads move: the repair pass re-plans every landing footprint from the height field the first pass
produced; the native feather (one mask sample per four cells, fixed-point blend) differs slightly from
the pixel loop, so 3 of 12 candidate scores flipped to an adjacent hex. Clusters and deposits are
untouched.

Lesson recorded in v926: the optimization line's per-patch restore of the central 16×16-sector
rectangle is **not** part of this unit. With it, an extractor 19 cells outside the rectangle lost half
its flattened core every pass and the audit failed loudly (`resource_failures=2`, v925). The pixel
loop never had that rule; the ring-only placement companions (`046f0aa`, `1a57f4e`) belong with it.

Rules-probe verification of v926 (`_ralph/tmp/rules_v926_*`), two double-pinned runs per site with
the floor runs' pins, zero `LUA ERROR` in every log:

| gate | 14N134W | 15S67E |
|---|---|---|
| 1 seed parity | digests identical across the pair: enrichment `527100097`/701, decor `917959587`, ug `1609697062` / `5381` | identical across the pair: enrichment `1037565385`/592, decor `464485535`, ug `1158028783` / `5381` |
| 2–3 entrances | ring 13 / ring 0, same hexes as the floor, none in the ring | ring 17 / ring 29, same hexes as the floor |
| 4 ring content | 12 clusters = 12 pads, 0 failures | 9 = 9, 0 failures |
| 5 single reveal | `>13` only | `D10` only |
| 6 badges | 2 signs @550 in unexplored sectors, 0 deposits visible in unexplored | same; scan test `scanned` |
| 7 decor | 40/40, 0 in ring; ug 0/0 | 99/99, 0 in ring; ug 0/0 |
| 8 no errors | 0 | 0 |
| 9 process | v926 `9fcdef0`, deployed, audit 37/37 | same payload |
| 10 first access | player route, 1 display | same |
| T0→T1 (probe) | 224.9 / 218.8 s (floor 400.1) | 201.0 / 198.7 s (floor 297.4) |

Only two generation fields differ from the floors at either site: the surface enrichment digest
(anomaly and effect top-ups run after the raster and read its terrain, so a few of them move; counts
unchanged) and `ring_modified_cells` (the native repair pass touches fewer cells). Bonus scenario:
an accidental run at 15N67E (`BlankBigTerraceCMix_04`, 8 clusters) was also clean (0 errors,
entrances ring 8 / 7, 8 = 8 pads), with a pre-existing decor shortfall there (143/155; the decor pass
runs before the raster, so it is not this step's).

## Acceptance per step (same for every unit)

- `rules_probe` at 14N134W: all ten gates green; for preserving units the three digests equal the
  v924 floor (`enrichment 1108181949/701`, `decor 917959587/1292`, `ug_enrichment 1609697062/251`).
- T0→T1 with the Start-boundary stopwatch, n ≥ 3, recorded next to the step.
- 15S67E regression run whenever generation code changed.
- Version bump, commit, `deploy.py sync` + `audit`, short hash recorded.
- `SuperBigMap.State.optimization_failures` empty in every run; any entry is a red result for the
  step, not something to be rescued.

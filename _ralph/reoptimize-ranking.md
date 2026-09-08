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

### Current implementation plan — owner priorities, 2026-09-08

This replaces the original least-risk-first execution order. The numbered historical
catalog above remains a reference. These are candidates to investigate and implement
when evidence supports them; no future speedup or all-rules verdict is implied.
After the owner's top-up priority, measured remaining cost and dependencies can
change the order. Compare with the full tree at `6afbcd9`, not only that commit's
diagnostic patch. Its ancestors contain the historical sub-70 techniques; the last
recorded START figure is 60.4 s at `ca28e66`. The later entrance-oracle estimate is
not a measurement of `6afbcd9`.

Current accepted timing reference: v936, 14N **187.549 s median** from
187.549 / 189.107 / 186.260 s; pinned 15S **158.890 s**. The individual accepted
steps and their evidence are below. Final all-scenario sign-off remains pending.

| Priority | Optimization to try | Concrete change | Status / acceptance condition |
|---|---|---|---|
| 1 | Direct seeded top-up sampling and streaming clusters (#17/#18) | Draw candidates on demand around eligible terrain opportunities; accept enough valid members for each required cluster and stop at its count. Remove the 4,096-entry perimeter pool, full-pool sorting, and repeated anchor/neighbour scans. | **Rejected at v943 `ec70d99`; rollback `113e3fc`.** 14N improved, but mandatory 15S deterministically exhausted outer cluster 5 and failed cluster/pad rules. |
| 2 | Reuse candidate terrain validation | Validate only sampled candidate locations. Cache a static result for the exact coordinate/footprint while its terrain/buildable/protection state is unchanged; reuse existing trustworthy candidate records. | Rejected with #1. Its lazy exact-coordinate/band cache passed focused tests, but cannot be retained without the rejected planner. |
| 3 | Demand-driven selection for remaining top-up phases | Profile ordinary resources, anomalies and effects for remaining pool rescans; consume valid entries or generate the next candidate only until the remaining target is satisfied. | Planned audit; keep existing demand-driven paths and numeric/cache-first optimizations. Change only work still measured as redundant. |
| 4 | Native buildable-hex snap (#6) | Guide a sampled candidate to a nearby valid buildable hex using a bounded native query, before expensive placement checks. | Try if rejection counts remain high. Candidate-only work; preserve geometry restrictions and deterministic placement. |
| 5 | Defer rocket relief scoring (#7) | Evaluate expensive surrounding-relief samples only for candidates whose score can still win. | Planned. Preserve the selected pad and every footprint rule. |
| 6 | Reuse rocket terrain samples and clearance index (#8) | Cache repeated terrain reads and query nearby obstacles instead of rescanning them for each pad candidate. | Planned. Reuse only while terrain and obstacle state remain valid. |
| 7 | Bounded seeded rocket-pad search (#16) | Sample a finite set near each cluster and stop once a rule-valid landing pad is selected. | Planned after #5/#6; pad positions may change, but every cluster still needs a valid pad. |
| 8 | Native mountain-apron raster (#15) | Move the expensive Lua per-cell apron blend into native grid operations using the current terrain formula. | Profile, then adapt. Preserve terrain detail, seamless transitions and actual buildability; historical raster cannot be copied blindly. |
| 9 | Settle resource terrain once (#14) | Plan interacting resource/extractor/pad edits together so fewer repair passes are necessary. | Planned. Preserve overlapping protected cores and smooth deformation; keep final audits authoritative. |
| 10 | Faster crease discovery and neighbourhood reads (#9/#10) | Reuse rolling neighbourhoods and native discovery indexes while retaining the current processing order. | Planned. Exact height output, including terminal-wall and spike fixes, must match. |
| 11 | Native crease translation and feather (#19) | Batch the current bounded, slope-limited calculations in native grid operations. | Conditional on profiling and #10. Preserve the corrected formula; no overshoot or unsigned wrap. |
| 12 | Coalesce terrain publication and rebuild work (#21) | Combine compatible edits and rebuild their actual affected regions at a proven lifecycle boundary. | Requires a fresh design. Retain both currently required closing rebuilds unless new native-state evidence proves an equivalent replacement. |
| 13 | Generate the native source in place (#20) | Avoid the temporary source-map load and terrain/object migration. | Architecture experiment. Must resolve the historical `MaskBuildableGrid` crash and preserve vanilla generation, RNG and passage behavior before adoption. |
| 14 | Minimal lazy underground generation (#22) | Defer eligible underground generation until first access, with deterministic entrance information available at surface generation. | Architecture experiment. Preserve glued entrances, all underground rules and one working first-access cover; report first-access time separately. |

Execution details for priorities 1–3: stop at the requested accepted count, discard
rejected draws, and retain only the small pending cluster plus required placement
records. Validate a reused coordinate once only while its guarantees remain valid;
do not pre-validate the whole map to build a certified reserve. Track attempted,
rejected, statically validated, cache-reused and accepted counts. A bounded search
that cannot satisfy the rules fails visibly and requires redesign; it must not
silently use the eager planner or reduce required quantities.

Already implemented: native outer-resource raster (#13), numeric hex keys and
cache-first verdicts (#1/#2), apron math bindings (#3), spacing-audit index (#4),
and actual-dirty-region intermediate passability rebuilds (#5). Preserve these.

Rejected: immediate final-rebuild deferral (#11, candidate `35c33c6`/`7e9bdd4`).
It measured 184.677 / 184.429 s but changed native surface passability output;
`2d9ea57` restored the exact v936 payload. Reconsider only with materially new
evidence, not unchanged retries. Coarser terrain masks (#12) are deferred because
their fidelity risk directly touches the no-visible-marks requirement. Historical
rank-then-filter (`86767a7`) has no demonstrated saving and stays deprioritized.

Rejected: direct seeded top-up sampling/streaming (#17/#18 plus candidate
validation companion #2), final candidate v943 `ec70d99`, rollback `113e3fc`.
Correction: 14N samples were 153.960 s on v940 and 151.329 / 151.672 s on v941.
They mix behavior versions, so they are NOT a three-sample final-build median
and do not establish an accepted per-unit saving. The mandatory pinned15S run
remained rule-red through v943: outer cluster5 exhausted its bounded search,
published0 clusters/pads, and produced shortfall8. Candidate timings from failed
15S runs are invalid. Evidence:
`artifacts/iter048_v941_14n_timing_review/timing_review.md`,
`artifacts/iter048_v943_15s_regression/`, and
`artifacts/iter048_strategy_rejection_rollback/`. Next strategy: priority3,
demand-driven selection for remaining top-up phases.

For every successful unit: separate implementation commit, before/after cold
START-to-T1 samples (at least three at 14N), median/range/saving, rule and visual
verdicts, and a Step log entry here. Reuse matching accepted baseline samples.
Placement/terrain/lifecycle changes require the full scenario sweep specified in
the current task contract; passing only 14N and 15S is not final all-scenario proof.

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

### Step 2 - #1 + #2 numeric top-up keys and cache-first verdicts (v928 `3819c29`, 2026-09-07)

`NewTopUpRepulsionTracker` now packs `(q, r)` into collision-free integer keys for its hot
neighbourhood table, checks the existing candidate/profile verdict cache before the 5x5
minimum-distance scan, and caches minimum-distance rejections because occupancy only grows during
the pass. This is the same output-preserving pair as `4fe9889` + `ca28e66`, adapted to the current
rules-parity tracker without bringing over unrelated optimized-line code.

Measured by the full rules probe at 14N134W with identical double pins and the START-boundary clock:

| | v927 before | v928 after |
|---|---|---|
| T0->T1 | 228.283 / 220.803 / 222.379 s, **median 222.379 s** | 198.251 / 195.802 / 196.482 s, **median 196.482 s** (**-25.897 s, -11.6%**) |
| surface enrichment | `527100097` / 701 in all runs | identical |
| surface decor | `917959587` / 1292 in all runs | identical |
| underground enrichment | `1609697062` / 251 in all runs | identical |
| rules/logs | all gates green; zero Lua/optimization failures | same |

The required 15S67E regression was also green and output-identical to v927: surface enrichment
`1037565385`/592, decor `464485535`/2749, underground enrichment `1158028783`/265, one initial
sector, 9 clusters = 9 pads, decor 99/99, and successful player-route first access. Its T0->T1 was
189.353 s versus the preceding v927 run's 206.937 s. Evidence is under
`_ralph/tmp/verification_v928_14n134w_run1|run2|run3` and
`_ralph/tmp/verification_v928_15s67e`; deployment audited 37/37.

### Step 3 - #3 bind apron raster math primitives (v934 `fb890e1`, restored at `c2d117c`, 2026-09-08)

`CreateNaturalMountainBaseBuildableAprons` now binds `math.floor`, `ceil`, `min`,
`max`, and `sqrt` once before its candidate-discovery and scalar raster hot paths.
This is the output-preserving unit from `b617030`, adapted without changing the
current scalar apron algorithm or adopting the optimized line's native raster.

Measured by the full rules probe at 14N134W with identical double pins and the
START-boundary clock (all samples retain full grids and incident-matched logs):

| | v933 before | v934 after |
|---|---|---|
| T0->T1 | 200.065 / 199.590 / 199.916 s, **median 199.916 s**, range 0.475 s | 194.171 / 196.363 / 197.156 s, **median 196.363 s**, range 2.985 s (**-3.553 s, -1.78%**) |
| first access | 41.396 / 41.156 / 40.977 s | 41.376 / 41.100 / 41.108 s |
| surface enrichment | `857148281` / 701 in every run | identical |
| surface decor | `917959587` / 1292 in every run | identical |
| underground enrichment | `1609697062` / 251 in every run | identical |
| terrain/pass grids | surface height `-897814779083946979`, UG height `8297061474709185495`, surface pass `-5282798222489378698`; exact pair judgments report zero differences | identical; exact pair judgments report zero differences |
| rules/logs | all directly judged gates green; zero Lua/optimization/native failures | same |

The required pinned 15S67E regression is also green: T0->T1 161.370 s, surface
enrichment `666958567`/592, decor `464485535`/2749, underground enrichment
`1158028783`/265, underground decor `5381`, one initial sector, 9 clusters = 9
pads, successful player-route first access, zero final terrain/optimization/log
failures. Against corrected v932's natural-seed 15S report, all compared surface,
placement, entrance, apron, reveal and census fields match; only the expected
game/underground-seed fields differ.

Visual verdict: output-preserving. The production-function regression proves exact
complete output and ordered-write equivalence on nine fixtures, including edited
rasters with 209620 and 252488 writes; all 14N full terrain/pass hashes are exact
before/after. Therefore the accepted corrected terrain pixels are unchanged, and
no replacement visual capture was required for this pure math unit.

Evidence: `_ralph/runs/reoptimize-under-70s/artifacts/iter011_apron_math_red/`,
`iter012_apron_math_green/`, `iter009_uninstrumented_cold/`,
`iter016_v933_14n_before2/`, `iter017_v933_14n_before3/`,
`iter013_v934_14n_after1/`, `iter014_v934_14n_after2/`,
`iter015_v934_14n_after3/`, and `iter018_v934_15s_regression/`.

### Step 4 - #4 surface hard-spacing audit spatial index (v935 `dd0504f`, 2026-09-08)

`AuditTopUpVanillaRepulsion` now builds conservative world and axial bucket
indexes for the final surface top-up audit, unions their candidate pairs, and
sorts each row back into literal pair order before evaluating the unchanged
predicates. The established underground density-fallback audit remains literal.
An unavailable, disabled, malformed, or non-finite surface certificate records
one shared `OptimizationFailure`, raises with the concrete cause, and never runs
the quadratic audit as a fallback.

Measured by the full rules probe at 14N134W with identical double pins and the
START-boundary clock (all samples retain full grids and incident-matched logs):

| | v934 before | v935 after |
|---|---|---|
| T0->T1 | 194.171 / 196.363 / 197.156 s, **median 196.363 s**, range 2.985 s | 194.119 / 194.941 / 198.799 s, **median 194.941 s**, range 4.680 s (**-1.422 s, -0.724%**) |
| first access | 41.376 / 41.100 / 41.108 s | 41.251 / 41.457 / 41.433 s |
| surface enrichment | `857148281` / 701 in every run | identical |
| surface decor | `917959587` / 1292 in every run | identical |
| underground enrichment | `1609697062` / 251 in every run | identical |
| terrain/sites/pads/audits | surface height `-897814779083946979`, UG height `8297061474709185495`, UG pass `3500460399427711453`, 65 sites and 12 pads; detailed audits identical | identical across all six samples |
| rules/logs | all directly judged gates green; zero Lua/optimization/native failures | same |

The required pinned 15S67E regression is also green and exact: v934
T0->T1 **161.370 s**, v935 **160.655 s** (0.715 s / 0.443% faster), with
surface enrichment `666958567`/592, decor `464485535`/2749, underground
enrichment `1158028783`/265, underground decor `5381`, one initial sector,
9 clusters == 9 pads, and successful player-route first access. Canonical
comparison of the complete native snapshot is equal, including surface/UG height
and pass grids, all 39 sites, all 9 pads, detailed terrain audit, apron census,
and empty optimization failures. The preliminary judge's retained planned-10 /
actual-9 complaint is unchanged corrected-baseline behavior; the current rule
judges the actual 9 clusters in the allowed 8..12 range with one pad each.

Full serialized surface pass content was compared, not replaced by historical
`HashPassability`. It varies within unchanged v934 and around the required
Elevator placement/`Complete` lifecycle; exact stage captures isolate those
native occupancy mutations. Unit #4 adds no RNG or grid-write path, while
surface/UG heights, UG pass, sites, pads, audits, and all placement/rule digests
remain exact across the complete 14N set. The deterministic production-function
fixture preserves every v934 counter, verdict, pair budget, and first-detail
field while reducing actual pair predicates from **125891 to 3541**; an injected
non-finite certificate proves the fail-loud, no-fallback path.

Visual verdict: output-preserving. Exact height grids, resource/pad records, and
the complete pinned-15S native snapshot show that accepted terrain pixels and
placements are unchanged. This audit-only unit cannot alter rendering, so no
replacement visual capture was required.

Evidence: `_ralph/runs/reoptimize-under-70s/artifacts/iter019_spacing_audit_red/`,
`iter020_spacing_audit_green/`, `iter021_v935_14n_after1/`,
`iter022_v935_14n_after2/`, `iter024_pass_stage_boundary/`,
`iter025_pass_stage_split/`, `iter026_v935_14n_after3/`, and
`iter027_v935_15s_regression/`.

### Step 5 - #5 bounded outer-resource passability rebuilds (v936 `ed288e9`, 2026-09-08)

The outer-resource terrain writer now certificates every aligned native patch
and terminal strip it writes. The two intermediate passability rebuilds consume
those half-open regions expanded by two pass tiles instead of rebuilding all
819,200 squares. The one full buildable rebuild and the later authoritative
whole-map closing rebuilds remain unchanged. An invalid or missing certificate
records one shared `OptimizationFailure`, raises with the concrete cause, and
makes zero engine calls; there is no whole-map fallback.

Measured by the full rules probe at 14N134W with identical double pins and the
START-boundary clock (all samples retain full grids and incident-matched logs):

| | v935 before | v936 after |
|---|---|---|
| T0->T1 | 194.119 / 194.941 / 198.799 s, **median 194.941 s**, range 4.680 s | 187.549 / 189.107 / 186.260 s, **median 187.549 s**, range 2.847 s (**-7.392 s, -3.79%**) |
| first access | 41.251 / 41.457 / 41.433 s | 41.380 / 41.209 / 41.087 s |
| surface enrichment | `857148281` / 701 in every run | identical |
| surface decor | `917959587` / 1292 in every run | identical |
| underground enrichment | `1609697062` / 251 in every run | identical |
| terrain/sites/pads/audits | surface height `-897814779083946979`, UG height `8297061474709185495`, 65 sites and 12 pads; detailed audits exact | identical across all six samples |
| rules/logs | all directly judged gates green; zero Lua/optimization/native failures | same |

All four recursively key-sorted complete 14N snapshots are exactly equal at
7,884 characters, SHA256
`075790F59F64311B9C85ABD3A932E197C46F8897D636A2C37585FF16A4C51FA1`.
This includes both native height/pass grids, all 65 resource sites, all 12 pads,
detailed terrain audit, apron census, and empty optimization failures.

The required pinned 15S67E regression is also green and exact: v935 T0->T1
**160.655 s**, v936 **158.890 s** (1.765 s / 1.10% faster). Complete canonical
snapshots are equal at 5,473 characters, SHA256
`07d1f302341401436cfb23ed37cb3aa5d370d74b5fb1acc8183afc69fe2e9b28`,
including both native height/pass grids, all 39 sites, all 9 pads, detailed
terrain audit, apron census, and empty optimization failures. Enrichment/decor
digests and counts, one initial sector, two signs, unexplored visibility, one SBM
cover, two underground passages, Elevator build/link, underground stretch, and
nil revalidation error all match. The preliminary helper's planned-10/actual-9
complaint is unchanged accepted-baseline behavior; the current gate is 8..12
actual clusters with one pad each, and v936 has 9 == 9 with every audit failure zero.

The focused production fixture proves the historical ring rectangles are unsafe
for the current adaptive terrain: its largest patch reaches x=134300 while the
old `80a0452` bound stops at x=82120. The accepted implementation derives bounds
from the actual aligned writes, expands by two pass tiles, preserves prepare ->
scoped rebuild -> audit -> anomaly -> effect ordering, and passes the complete
offline matrix: Lua 31/31, crease 8/8, blend 14/14, terminal 10/10, focused dirty
rebuild, Python 7/7, and policy static 101/101 plus all 28 dynamic/synthetic cases.

Visual verdict: output-preserving. Exact native height grids, every serialized
site/pad, both pass grids in the complete pinned snapshots, and the detailed
terrain/apron audits prove the accepted pixels and placements are unchanged.
This rebuild-scope-only unit cannot alter rendering, so no replacement visual
capture was required.

Evidence: `_ralph/runs/reoptimize-under-70s/artifacts/iter029_dirty_rebuild_red/`,
`iter030_dirty_rebuild_green/`, `iter032_v936_static_gate/`,
`iter033_v936_14n_after1/`, `iter034_v936_14n_after2/`,
`iter035_v936_14n_after3/`, and `iter036_v936_15s_regression/`.

## Acceptance per step (same for every unit)

- `rules_probe` at 14N134W: all ten gates green; preserving units must match the immediately
  preceding accepted, corrected baseline, not the superseded v924 terrain/enrichment floor.
  The v932 terrain fixes intentionally changed surface terrain and some enrichment positions.
- T0→T1 with the Start-boundary stopwatch, n ≥ 3, recorded next to the step.
- 15S67E regression run whenever generation code changed.
- Version bump, commit, `deploy.py sync` + `audit`, short hash recorded.
- `SuperBigMap.State.optimization_failures` empty in every run; any entry is a red result for the
  step, not something to be rescued.

### Owner update - unattended continuation (2026-09-08 UTC)

Continue the remaining worthwhile ports one at a time, then new profiling-guided optimizations
until START-to-T1 is below 70 seconds without breaking any rule or prior optimization. Use the
project-local Ralph loop, not Pursuing Goal. Normal model Sol High; plateau escalation Sol Extra
High then Astra High. The immutable current contract is
`_ralph/tasks/reoptimize-under-70s.md`, workspace `_ralph/runs/reoptimize-under-70s`.

Every successful optimization MUST receive its own factual local commit and an entry here with
version/short hash, before/after individual cold START-to-T1 samples (n>=3), medians, savings,
rule/digest/visual verdicts and evidence paths. Checkpoint commits made before testing are
candidates, not successes. Report failures and rejected units honestly; never weaken gates.

### Session workflow - owner update (2026-09-08 UTC)

Use one continuous agent session per optimization strategy. Keep implementation, offline
tests, cold measurements, regression review, and the final acceptance/rejection verdict in
that session, with durable checkpoints after each step. Do not end a session merely because
one test, sample, or candidate commit completed. Ralph starts the next strategy after the
current strategy's verdict and required commit/ranking update. An unavoidable interruption,
context limit, or evidenced escalation resumes the unfinished strategy before advancing.

The project-local `_ralph/tools/strategy_sessions.py` adapter changes only the generated
session contract; the shared harness, immutable task, rules, START-to-T1 definition, and
Sol High -> Sol xhigh -> Astra High model ladder are unchanged. The detached launcher uses
this adapter. Its `--migrate-only` mode safely updates the existing pinned workspace without
launching a second runner or stopping the current worker; the running runner's next agent
session reads the new contract. Candidate builds are still committed/deployed before cold
tests and are not labeled successful until their required gates pass.

Starting corrected terrain checkpoint: v932 `fde100f`. Full rules baseline is **not yet green**:
first pinned14N cold run START-to-T1 204.256s and final resource audits clean; the second failed
the native-enrichment migration verification before T1. Two diagnostic retries passed but do
not establish a fix. No additional optimization has been accepted since Step2 above. Root-cause
that intermittent baseline failure before claiming a safe performance improvement.

### Manual direct-seeded repair - owner update (2026-09-08)

Ralph is stopped; the owner now commands each strategy manually. No automatic
transition to another optimization and no Pursuing Goal mechanism.

Current candidate: v950 `b738d30` (direct planner v949 `8222858`). Shared direct-seeded placement now streams
finite buildable guide leaves, visits the full469 local axial offsets on demand,
and continues into the inner band when the outer band cannot fill every requested
specification. It keeps the hard8..12 complete-cluster rule, composition, static
terrain checks, live spacing/obstruction checks, and all earlier terrain changes.
The old32/128/384 cutoffs and repeated-leaf starvation have executable red/green
regressions. All45 offline checks pass; cold verification is in progress.

v949 resource results:15S158.280s(9clusters/pads),24S177.884s(8),45S157.194s(8),
61N159.344s(11). These are single provisional samples, not accepted savings.
17S failed one extractor after both repairs;176.980s is INVALID. Pre-changev937
17S passes at145.849s. The failed site is an undersized34-cell buildable island
(native minimum50), despite all12 exact extractor offsets being flat and passable.

v950 fixes a generic building-feather arithmetic defect exposed by those changed
placements: the prior fitted-plane term had a negative partial-weight coefficient
and could excavate a moat or raise a rim outside the core. Building feathers now
blend only between original and level-target heights; surface-resource grading,
C2 masks, protection, native raster, footprint sizes and physical-edge repair stay
intact. Executable production-plane/blend regressions fail onv949 and pass onv950;
all45offline checks pass. Checkpoint committed/deployed37/37exact; cold17S first,
then15S and the remaining scenario matrix. No scenario/sector/coordinate checks
were added to production. This is a candidate repair, not all-rules sign-off.

This is NOT an accepted optimization yet. Earlier manualv94715S runs completed
at151.678s and152.819s with8clusters/8pads, but24S failed, so those are provisional
samples only. Baselinev937/`158da2b`24S completes8clusters/8pads at179.344s but
already fails the start-sector gate (D8 anchor versus D7 revealed) and decor
count (144/171). Those pre-existing failures remain red; they are not waived.
The baseline15S visual comparison also shows the previously noted thin edge ridge.

Evidence and current checkpoint log:
`_ralph/runs/reoptimize-under-70s/artifacts/manual_direct_seeded_20260908/STATUS.md`.

### Five-scenario all-rules repair - latest owner scope

The owner accepts five scenarios, provided ALL rules are green. Keep the first
five manifest sites; do not replace red cases with green ones. Ralph remains off.
v950 `b738d30` completed these fresh cold samples, each with full native snapshot,
flushed incident-matched logs and clean teardown:

| Scenario | START-to-T1 | Clusters/pads | Remaining preliminary numeric reds |
|---|---:|---:|---|
| 15S67E | 158.518s | 9/9 | None; pairs/control still pending |
| 24S74W | 156.775s | 8/8 | Start anchor; decor 144/171 |
| 45S120W | 135.829s | 8/8 | None; pairs/control still pending |
| 61N136W | 183.494s | 11/11 | Start anchor; decor 100/190 |
| 17S11W | 145.706s | 8/8 | Forbidden decor classes |

All five resource/pad gates pass. These are individual samples, NOT accepted
savings or an all-rules verdict. Visuals show the old tall resource-platform cut
in 24S disappears at identical cameras/positions with v950; the pre-existing thin
15S bottom edge wall remains, and angular tonal regions need attribution.
Already-in-flight extras were retained (24S73E137.675s,23S19W155.051s), not added
to the reduced acceptance set. No further scenarios launch automatically.

Candidate v951 corrects the start-anchor rule generically: the single reveal uses
the half-open sector containing the transformed native start center. The original
full-candidate InitialReveal call, spawn positions and random draws are preserved.
Source review caught non-throwing engine error handling; an explicit early return
now prevents reveal mutation after a failed lookup. Production selection tests
are red on v950 and green on v951 (110 cases); 46 offline commands pass before
the version bump. Cold verification is pending. This is a correctness checkpoint,
not an accepted optimization. Decor and edge-wall work remains required.

v951 `acae71e` cold24S confirms the corrected sole D8 anchor at157.203s, resources
still valid8/8. Full snapshot/logs and clean teardown; decor144/171 remains red.

Candidate v952 addresses general decor correctness, not a new performance strategy:
explicit cosmetic creation whitelist (separate from existing-object scaling),
no marker-only density credit, final rounded-coordinate band checks, and finite
seeded interior candidate coverage after the random local search runs out.
Terrain, matcher, template radius, occupancy and no-terrain-write rules stay intact.
Underfill now records an optimization failure and displays an invalid-map notice.
Review found and regressed both upper-bound rounding and loading-notice waiting.
All49offline commands pass, including production stamp/loop/failure-tail tests
and a230-template fully blocked finite-exhaustion fixture. Cold results pending.
The native worst-case cost of exhausting millions of cells remains a runtime risk;
finite coverage does not prove that every map has sufficient legal decor capacity.

v952 `2356f0f` cold checks (single provisional samples, not accepted savings):

| Scenario | START-to-T1 | Resources/pads | Decor | Result |
|---|---:|---:|---:|---|
| 15S67E | 160.272s | 9/9 | 99/99 | Available numeric gates pass; pairs/control/visual pending |
| 24S74W | 187.069s | 8/8 | 171/171 | Correct sole D8 anchor; available numeric gates pass |
| 45S120W | 139.146s | 8/8 | 53/53 | Available numeric gates pass |
| 61N136W | No completed T1 | Unknown | Unknown | Stopped after >10 minutes; DAP quit timed out |
| 17S11W | Not run | — | — | Finite phase stopped at 61N; no substitute scenario |

The completed three retain canonical snapshots, raw height grids, original images,
flushed logs and clean teardown. Two earlier 15S diagnostic-export failures remain
separate invalid evidence. 61N partial logs and exact test identity were preserved
before forced termination; it has neither a full report nor a clean-teardown claim.
The finite decor candidate phase needs runtime diagnosis, not an all-green label.

Candidate v953 fixes the remaining narrow edge-join defect: a preferred guard
limit could end the bounded crease join inside the detected resampling ramp,
leaving one untouched low sample beside the translated edge. Two symmetric
endpoint clamps ensure the join reaches that translated endpoint. Detection,
translation, bounded quintic formula, resource footprints and three-cell terminal
repair are unchanged; there is no broad taper or scenario/sector special case.
Read-only source review found no further issue. The full production helper now
passes all-four-edge/corner/boundedness and unchanged-safe-join regressions;
the old endpoints reproduce the defect. All50offline commands pass. Native visual
confirmation and the unresolved61N/17S plus pair/control gates remain required.

Owner permits temporary debug logging. Next is a separate instrumented61N
diagnostic for stage time, matcher/circle cost and live candidate/placement/reject
counts. Its logging/yields invalidate performance acceptance; no permanent debug
switch, weakened rule, automatic new strategy or Ralph restart is authorized here.

Temporary v953 61N diagnosis completed (not an optimization acceptance): flushed
`v953_61_stage_debug/daemon_flushed.log` shows decor190/190 in512.940s and eventual
START-to-T1=675.427s. At509.776s into decor,710358 native matching calls consumed
444.109s (~87%); circle checks consumed53.227s. Of727247 synthetic attempts,
652582+60756 were rejected for obstruction/existing decor (~98%). Live log output
was delayed; the apparent earlier underground-cleanup stall was not the hotspot.
Exact test75508 quit cleanly, but diagnostic yields/overhead, timed-out report and
missing full snapshot make this run ineligible for acceptance. All rules remain
pending. No new production code, accepted savings or changed deployment.

Next narrow candidate identified by source review: lazy ordered matching-result
cache private to each decor Run and keyed by marker; retain no_match precedence,
dynamic weights/occupancy and every RNG draw. Do not cache globally (vanilla
mutates returned arrays), and do not merely reorder filters (rejection reasons
drive reach escalation). Refined temporary logging removes all yields and adds
repeat-input/filter counters; offline wrapper tests pass, native repeat pending.

Owner-authorized fix v954: implemented the run-local ordered matching cache with
no other placement changes. Mixed production-stamp regression gives identical
outcomes, object placements, dynamic repeat weights and RNG traces while reducing
3009 matcher calls to7 (including a separate-run invalidation check). Empty lists
keep no_match precedence; errors/non-table returns remain retryable, and newly
placed occupancy still rejects subsequent candidates. Source review found no
actionable issue. All51offline commands pass in `v954_offline`.
Native verification now covers the fixed five15S/24S/45S/61N/17S: expanded runs,
seed replays and same-site controls, with START-boundary T0 and completed surface
pipeline T1. Fix any failures and finish incomplete checks; no waivers or scenario
substitution. Temporary diagnostic wrappers are not loaded in timing runs.

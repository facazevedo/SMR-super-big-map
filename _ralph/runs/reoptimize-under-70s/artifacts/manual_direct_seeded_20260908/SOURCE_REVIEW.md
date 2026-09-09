# Direct-seeded source review

## Final evidence interpretation

Expanded A uses the production underground reservation; B uses the existing test
seam to consume A's reserved seed. The final evidence audit requires exactly one
RESERVATION, CONSUMER and HOLDER trace per expanded process, with matching seeds,
successful native generation and the expected production/test boundary. This is
separate from the Lua source audit and exact same-seed native grid comparisons.

The finite driver also requests the seed pin for unexpanded controls, but the
native unexpanded path does not consume the mod's reservation seam. Its actual
underground seed remains native AsyncRand and is explicitly retained in the final
audit. Controls are evidence for same-site authored underground reveal/imprint
visibility on the same blank map, not seed-identical generated content. Their
blank map names must match A, and their actual reveal/imprint states must match.
Expanded A/B, not these controls, prove generated-content determinism. No rule
requires altering native control RNG for the authored-state comparison.

## v955 26f691c source / RNG review

Root and existing Astra reviewer inspected the scoped provisional-clearance fix.
PrepareProvisionalSurfacePassageBuildable preserves the native mark, shape,
bbox/prime accumulation, FixBuildable arguments and Finish. It omits native-object
and prefab-collection deletion at discarded source poses. Authored underground
clearance and final surface candidate validation remain unchanged. Native cloned
pre-state diagnostic v955_clear_equivalence proves both observed nontrivial
bridge outputs byte-identical to stock, without changing object/query counts.

Failure handling was regressed with nil globals and nonthrowing error(): required
names cannot vanish from preflight, missing/nonfinite guim is refused, failed
transactions finish/restore and stop before alignment/publication, and the outer
wrapper records failure without stock-clearance fallback. Review found no other
actionable delta issue. No scenario names, coordinate constants or seeds added.

Reachable seeded Lua RNG audit for158da2b..26f691c:

- deposits281..325 private Lehmer stream; specs4603..4643, permutations4224,
  guides4131..4144, region5221 and callbacks5143/5205 use supplied RandInt.
- decor116..135 private BraidRandom stream seeded301. Finite cells use stream.rand;
  weighted selection486 uses stream.seed. Native matcher50..88 has no RNG, so
  the ordered-list cache removes no random draws or changes live weights.
- map_generation5360..5388 provisional helper and inspected native landscape Lua
  wrappers add no random call. Existing UG AsyncRand reservation4908 or mutually
  guarded compatibility8757 is unchanged; native artefact shuffles5727/5811 remain.
  Native passage fallback uses SessionRandom (Pathfinding167..169), or city:Random
  at4, through unchanged source radius/passability bridges.
- sector_exploration1843..1847 preserves Exploration and full InitialReveal
  candidate/draw sequence; the corrected geometric anchor adds no random draw.

Qualification: inherited deposits320 EngineRandInt fallback is reachable if
SeedDeterministicPlacement fails (unchecked4560). Normal tested maps have recorded
map/generator seeds and take the private path; this review does not certify an
unseeded map. No new shared fallback was introduced. Native constructor internals
are not fully visible; final native same-seed A/B outputs are separate required
evidence. Do not describe this source audit alone as universal determinism.

## Current v954 cache / RNG review

Commit 60a9578 implements only a run-local lazy ordered matching-list cache in
the production decor pass. The earlier diagnosis section below describes the
pre-cache checkpoint and is historical. Main-agent source inspection and the
existing Astra review found no actionable issue in this delta.

Native `RandomMapGeneratorOp.lua:50-88` reads fixed DecorStyle/Type/Op/Radius/Tags,
revision/version/type_tile and the ordered PrefabMarkers catalog. It does not
draw RNG or inspect mutable XY, height, occupancy or DecorTestPrefab. These
matching inputs remain fixed within the non-yielding pass. Returned lists are
not mutated by try_stamp; native weighted selection consumes them read-only.
The cache is instantiated inside each Run, not attached to markers or global
state. Empty lists preserve no_match priority; failed/non-table calls retry.

No placement/filter reordering, new random draw, cached weighted choice, cached
occupancy decision, geometry edit or scenario-specific branch was introduced.
All 3,009 mixed attempts in `decor_matching_cache_test.lua` execute production
stamping, live circle checks and repeat-weight calculation. Cache-removed versus
cached forms produce identical outcomes, placements, weight evolution and RNG
traces; matcher calls fall to 7 including the extra new-pass invalidation check.
`v954_offline/results.json` has all 51 commands at exit 0.

Earlier direct-seeded private-stream, start-anchor, decor filtering and bounded
terrain audits below remain applicable; v954 does not change those paths. Native
same-seed A/B evidence is still required separately and is recorded in v954_matrix.

Read-only Astra review of19d07c1/v948 against158da2b, followed by8222858/v949 delta
review. The reviewer made no edits or game calls. This is source-level evidence,
not runtime-pair, universal-scenario, performance, or visual acceptance.

- All added source/offset/guide/region draws use the existing private RandInt
  stream, seeded before TopUpDeposits. Count/spec draws are unchanged. No added
  engine/shared RNG call or scenario-coordinate special case. The pre-existing
  missing-seed fallback remains unchanged and is not certified by this unit review.
- Guide leaves are visited once; source iterators persist across requested specs.
  Bounds derive from finite geometry. Full469offset local coverage stops at exact
  demanded membership. Only complete plans are reserved/published; partial trials
  are discarded. Unknown guide results stay eligible. Reviewer caught an unknown
  parent with both child queriesfalse being pruned; that was fixed and regressed.
- Static verdicts cache exact axial hex plus physical band. Source-specific
  apron-radius rejection precedes caching. Final predicates still require correct
  ring/band, unscanned sector, ten-hex footprint margin, buildability, passability,
  flatness, and exact hex round-trip.
- Obstruction, unique occupancy, and universal spacing remain live. Clone-boundary
  selection repeats dynamic checks; successful clones commit to the tracker.
  Deliberate members keep the established nil-profile path, not the ordinary
  independent-deposit repulsion profile. Inter-cluster and intra-cluster distances
  remain unchanged.
- v949 restores baseline continuation into inner specs when outer sources exhaust
  before the last outer spec. Hard minimum8, complete plans, composition and source
  spec IDs remain intact. Noncontiguous IDs are safe: dense plan arrays and terrain
  ID-keyed grouping do not assume consecutive IDs.
- v949 geometry ceiling uses floor((size+1)/2), retaining odd cells under the
  engine's integer division. Regression covers odd rectangles and the former
  mid-band false failure with3outer plus5inner complete clusters.
- No production diff against158da2b in engine, map-generation, terrain-copy,
  object-clone, or the independent surface-effects implementation. Shared terrain
  validator changes add diagnostic return reasons only. Prior terrain protections
  and temporary buttons remain unchanged.

Review verdict: no additional confirmed correctness regression after the fixes.
Offline:45commands pass atv949_final_offline. Actual preceding helper versions
prove late-ring, repeated-leaf and cross-band continuation tests red before fixes
(`_ralph/tmp/v948_regression_red.lua`).

## v950 b738d30: bounded building-plane correction

17S exposed an inherited partial-weight arithmetic defect when the direct planner
selected different terrain. Read-only review confirmed the old building blend
gave the fitted plane a negative coefficient; production-block regression shows
that it can lower even old==target terrain to negative heights. Separate native
diagnostics identify a34-cell raw-buildable island below the engine50-cell limit.

v950 makes the non-surface plane constant and removes the differently-weighted
correction branch. The resulting old*(1-w^3)+target*w^3 blend is bounded. Surface
plane construction/blending, harmonization, radii, C2/protection masks, final
rounding and repacking are unchanged. Constant U16 targets scaled by256 are
exactly representable in float32; the change removes large-plane cancellation.
No scenario/sector IDs, fixed coordinates or RNG changes in production.

Reviewer found no confirmed issue in the delta;16focusedblend checks and45offline
commands pass. New checks execute production plane construction and blend and
fail on exact8222858 source. Scalar tests do not prove native2-D masks or final
buildable-zone classification: fresh17S/15S/full matrix still required.

## Five-scenario all-rules follow-up (latest owner scope)

v951 `acae71e`: source-review of generic half-open start-anchor selection found
one non-throwing-engine-error path; the helper now explicitly returns nil and
the caller returns0 before resetting reveals. Production regression covers this.
Full candidate ordering, InitialReveal call/draws and spawn_positions stay intact;
staged replay uses original native records independently of the selected sector.
Commander bonus lookup follows the corrected InitialSector as intended.
Cold24S subsequently confirms soleD8 scanned and resources valid at157.203s.

v952 `2356f0f`: decor reviewer confirmed that the old scaling predicate admitted
functional geysers and all230/254 sources retired after random misses, before
their attempt budgets expired. Production tests reproduced both failures.
Creation now has explicit cosmetic prefixes, still subordinate to gameplay-kind
denials. Empty marker-only stamps restore no cosmetic density and are removed.
The global scaling policy for pre-existing/vanilla objects remains unchanged.

Finite lazy private-seeded candidate cells supplement the existing random local
search; same template matcher, terrain types, radius and live occupancy checks.
No shipped legacy alternative or changed terrain write. Each source visits each
finite cell once and stops on exact demand or candidate-cell exhaustion; this is
not a proof that every legal continuous coordinate/rotation was considered.

Reviewer caught two further issues, both regressed/fixed before commit: final XY
must be rounded before band tests, and the loading-notice wait must assign both
pcall returns explicitly (and-expression collapsed the second return). Removal
API absence is rejected before creation; underfill logs/stores an optimization
failure and displays an invalid-map message after loading.

All49offline commands pass, including24stamp filter cases,5failure-tail cases,
actual finite-loop cases and230-source fully blocked finite exhaustion. Native
worst-case cost of millions of attempts remains unproven; cold selected-five
coverage, paired outputs, controls and visual/edge sign-off still required.

## Temporary 61N diagnostic — 2026-09-08

Flushed v953_61_stage_debug logs establish repeated native template matching as
the dominant measured cost: at509776ms,710358 calls/444109ms, versus771114 circle
calls/53227ms. The surface decor pass eventually completed190/190 in512940ms.
The last live HOLDER line was stale/buffered, not proof of a cleanup stall.

Native RandomMapGeneratorOp.lua:50-88 matcher scans ordered PrefabMarkers, reads
DecorStyle/Type/Op/Radius/Tags, revision/version and type_tile, without RNG or XY,
terrain/occupancy reads. Mod try_stamp currently calls it before both circle tests.
Run-local lazy per-marker ordered-result caching is the narrow candidate. Cache
successful tables (including empty); do not cache errors/non-table returns, weights,
random choices or circle verdicts. Do not globally replace the native matcher:
RandomMapGenerator.lua:2445 removes entries from its returned list in vanilla.

Reordering circles before matching is NOT equivalent: simultaneous no-match and
overlap would change rejection reasons; only overlap counts toward synthetic
reach escalation/retirement, affecting candidate order and RNG. Required tests
for a future cache patch: identical outcomes/placements/RNG, empty-list precedence,
live occupancy and repeat weights, retryable errors and fresh per-run inputs.
No production optimization implemented during this logging-only step.

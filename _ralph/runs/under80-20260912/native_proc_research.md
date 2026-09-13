# Native procedure census before OnGenerateLogic

Fresh Astra extra-high read-only review identified a concrete timing gap.
The accepted-v987 sparse reference source-view span15020ms has a7400ms direct
OnGenerateLogic child, leaving7620ms outside; slow61N remainder7064ms. WALL
remainders include waits/uninstrumented work and are not CPU or saved-time claims.

Local primary engine source RandomMap/RandomMapGenerator.lua:2850-2864 invokes
FindPrefabPos, PlacePrefabs, PlaceDecors, ApplyTerrainMarkOnly, overlap removal
(tag ApplyTerrain), actual ApplyTerrain, FixPadTerrain and AdjustObjects BEFORE
OnGenerateLogic:2866. Existing detailed ProcInvoke timing starts inside that
later hook, so misses these procedures. FindPrefabPos itself contains six nested
procedures. Occurrence and parent IDs are necessary; duplicate tags cannot be
merged and nested durations cannot be added to their parents.

## Diagnostic design

native_proc_profile.lua wraps the existing public
SuperBigMap.CallDoGenerateWithRockParityTrace seam. This supplies the actual
native map and generator without replacing Generate/DoGenerate/OnGenerateLogic
(which would interfere with lifecycle patch identity checks). Only during each
call it composes ProcStart/ProcEnd wrappers with their CURRENT identities,
including the existing mark-grid projection wrappers, and restores them before
return. Original call order, full nil-preserving tuples, errors, private cells,
random draws, serial raster setting and mark-grid projection stay unchanged.

Timers start after original ProcStart returns and finish before original ProcEnd;
the original methods still execute once with identical arguments. Per-coroutine
generation contexts prevent nested calls being attributed to the outer map.
Records contain scalar identities/timing/census only. Caps32 generations/4096
procedures and explicit failure latches guard incomplete/misnested work. Two
persistent hooks restore at required scheduled surface revalidation. Native/final
error paths also restore and propagate errors (with explicit return if the engine
error logger returns). Debug Config, class-generation methods, profiler settings,
RNG and all normal work are unchanged. One summary log follows restoration.

Offline native_proc_offline PASSES four commands: Lua syntax,151 fixture checks,
exact Code/metadata/items comparison to56fbf44/v987 and38-file deployment audit.
Fixtures cover nil tuples/arguments, repeated tags, nested children, native calls,
projection wrapper composition, nested/coroutine map identity, seven failure
paths (including logging-only error), missing prerequisites and restoration.
They do NOT substitute for full real-engine parity checks.

Run one fresh reference and one61N with profile.py and query
SBM_NATIVE_PROC_DIAGNOSTIC. native_proc_audit.py inherits full predecessor,
private-four-field, rock, incident, version and flushed-shutdown checks from the
sparse audit, replacing only the probe contract. Require all eight pre-logic
procedures in exact order including both ApplyTerrain occurrences, one native
underground call, accounting and restored hooks/class methods/config.

## Decision gates

If identical immutable preparation/inputs dominate, investigate bounded exact
reuse with ownership/initialization proof. If native raster dominates, savings
may be limited under existing correctness rules; do not alter required serial
raster or narrow mark-grid projection. No speedup or production promotion yet.

Other fresh review alternatives: fuse decor rejection dispatch without changing
cursor/circle/index/RNG/matcher/precedence (distinct from rejected caches), and
qualify repeated object observations within one relief-capture callback. Those
remain unimplemented and must first prove exact outputs and measurable benefit.
No revival of unchanged v988-v991 or radius-expanded-bucket candidates.

Accepted reference86.606s/worst92.125s remain authoritative. Full<80 objective and
user's relaxed<85 target both unmet; all eager bootstrap and immediate/scheduled
preT1 rebuilds remain required. Diagnostic durations are not cold-start samples.

## First native reference retained as FAILED diagnostic

Frozen dc519d7, v987_native_proc_reference exec23715/PID52376 CLOSED exit1 after
normal game shutdown. Full predecessor/rock pair and all four private fields
PASS,95 completed procedures in two generations, zero open. Probe status FAIL:
setup-time Generate/DoGenerate/OnGenerateLogic identities differed at scheduled
restoration. The two owned persistent hooks and all per-call ProcStart/ProcEnd
hooks were restored; failure was the overly broad generation identity guard.

Source inspection shows normal Lifecycle ClassesPostprocess/DataLoaded and other
events reverify/reinstall these methods through PatchRandomMapGenerator. The
probe never assigns those methods. Revised guard checks each actual method
against the CURRENT registered SuperBigMap.State wrapper at native entry and
scheduled restoration, and exact within-call stability independently. It does
not overwrite unrelated methods or relax ownership checks for probe hooks.

New native_proc_offline_2 four-command PASS,203 fixture checks, including legitimate
registered lifecycle replacement between calls and unregistered replacement
before/during/after a call rejected. Original151 checks retained. First native
diagnostic and its failed audit remain unchanged; no timing is promoted from it.
The inherited audit's normal_shutdown=false aggregates ANY issue and therefore
does not contradict raw flushed logs proving that PID52376 shut down normally.
Run new v987_native_proc_reference_2 and61N at the corrected frozen checkpoint.

## Corrected native reference and61N CLOSED PASS

Frozen cf1af4d. Reference_2 exec40144/PID49800 identity
134337684310912733;61N exec57157/PID45044 identity134337686170425370. Both CLOSED
exit0 with normal flushed shutdown. native_proc_audit PASS issues[], exact full
predecessor/rock outputs and four private fields, no engine errors.95/94 completed
procedure spans respectively, two native generation calls each (surface and UG),
no open procedures or generations, all per-call boundary identities restored,
registered generation methods stable within each call, persistent hooks restored,
Config unchanged. No production edits or cold timing claims.

| Underground procedure | Reference ms | 61N136W ms |
| --- | ---: | ---: |
| FindPrefabPos (parent) | 5348 | 4647 |
| - Playable (child) | 2149 | 1062 |
| - Filler (child) | 2116 | 2479 |
| - Base (child) | 921 | 857 |
| - Unfilled (child) | 153 | 241 |
| - Slope (child) | 9 | 8 |
| - Border (child) | 0 | 0 |
| PlacePrefabs | 913 | 991 |
| ApplyTerrainMarkOnly | 573 | 589 |
| ApplyTerrain #1 (overlap removal) | 25 | 24 |
| ApplyTerrain #2 (raster) | 597 | 584 |
| FixPadTerrain | 81 | 81 |
| AdjustObjects | 96 | 104 |
| ResolveBuildable | 937 | 913 |
| PlaceArtefacts | 3540 | 1663 |

Native surface calls4579/6287ms; native UG12223/9729ms. Outside all recorded
top-level procedures only8/10ms surface and10/11ms UG. Those remainders differ
in scope from earlier sparse parent-minus-OnGenerateLogic values; do not subtract
different runs to infer savings. The nested FindPrefabPos children exactly sum
to the parent on UG. No sum of parent plus children is meaningful.

Full comparison in artifacts/v987_native_proc_comparison_2, including surface
FindPrefabPos1463/1572 and stock surface PlaceDecors113/1881ms. This stock decor
stage is NOT the later expanded DecorTopUp419/9617ms from prior sparse profiles.
Do not confuse them. Surface and UG generation calls are sequential, but neither
their totals nor old phase values are a demonstrated optimization budget.

Comparison script's initial artifact write completed, then console printing a
Unicode child arrow failed under Windows cp1252. Original comparison retained;
changed only terminal escaping/output-name option and reran into comparison_2
exit0, same audited inputs. JSON and Markdown from both attempts are preserved.

## Next decisive investigation: native prefab-selection primitive census

The large common cost is placement selection, NOT raster preload/copy. Inspect
actual live calls in FindPrefabPos_Playable/Filler/Base, with temporary identity-
restored primitive wrappers, original calls/arguments/tuples untouched:

- GridDistanceMars, GridMask, GridAnd/GridOr/GridNot, GridMulDivAdd and
  GridMulAddScaled: separate repeated whole-grid computation from allocation.
- GridDest/NewComputeGrid/GridMinMax/GridEquals: count allocations/reductions
  and their cost, not assumed from visible source TODOs.
- GridStableRandomPosSimple/GridStableRandomPos: measure existing seeded grid
  selection calls without drawing, replaying, inspecting or replacing RNG state.
- Include a coarse uninstrumented parent timing and bounded call counts; no
  per-cell timers, table dumps, function-profiler changes or cached conclusions.

Engine source Playable:1639-1746 repeatedly builds dist_grid/remaining_zone/
bounds_zone and computes distance transforms. Filler:1771-1833 retains one
distance_grid but rebuilds masked remaining_zone per selected prefab. Base:1991-
2037 repeatedly invokes grand(place_grid,random_params) and marks accepted cells.
CreateRandHelpers:163-205 uses native seeded grid selection; no custom PRNG or
altered selection algorithm is justified. similar_apply:1390 mutates each
candidate grid using current similarity grids; those inputs are NOT immutable
across successful placements. Do not cache grid answers by dimensions/prefab
alone. Scratch reuse would require full-overwrite/format/ownership proof and native
parity; avoiding recomputation needs a separate exact input-mutation certificate.

Keep scope to these measured stages. Discover the correct SHIPPED global owner
for wrappers (not a sandbox-only shadow); verify original identities and fixture
failure cleanup before native use. No module reload or class-generation-method
replacement. Preserve full private streams, seeded selection order, every
prefab/object/rock and native raster/projection/resume/rebuild transaction.

This turn is PROGRESS: the unknown common remainder is now localized to actual
procedures and a smaller falsifiable experiment. Acceptedv987 cold results remain
86.606s reference/worst92.125s; full goal not achieved and not blocked.

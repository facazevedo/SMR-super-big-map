# Next shared lead: callback-local observation census

Production remains56fbf44/v987. The private fused decor prefix now passed exact
native decisions and four whole-pass audits, but measured only204/264ms diagnostic
differences on61N and has no finite-loop workload on reference. It is retained
privately, not deployed or cold-promoted. See decor_rejection_research.md.

## Evidence and actual source

Fresh sparse surface transferred-relief spans2203/2859ms on reference/61N include
more than object getters. The accepted full snapshots attribute surface rock
capture537/1212ms,eligible14447/12189,probes69640/138844,rays29309/97361,
contacts6342/18847. Those counts/spans overlap; neither the enclosing phase nor
all rock work can be advertised as removable metadata overhead. The separate
UG capture216/211ms comes from after first access, not an established pre-T1 cost.

Code/sbm_terrain_copy.lua:5868 AnnotateDecorRelief is publicly exported on
SuperBigMap.TerrainCopy at9042. Its primary MapForEach callback first reads
ObjectPosition and optional scale/angle for native source stamps, classifies the
object, calls grounding.Capture, then may re-read position/scale for cave records,
position/parent/entity for audits, and parent/position/Z for relief. A second
out-of-box callback has distinct stamping-only semantics and must not be merged.

Code/sbm_engine.lua:105 Engine.ObjectPos first tries GetPos via SafeCall, then
visual-position fallbacks. Its result is NOT proof that a native GetPos succeeded.
Do not replace live reads with stale SuperBigMapNativeSource* fields, cache failed
reads permanently, or conflate GetPos with a fallback-returned position.

Code/sbm_rock_grounding.lua:53 Capture reads parent/entity eligibility, position,
visual position, valid-Z, bounding box, then bounds extents and visual coordinates
repeatedly in sampling loops. Its public table holds the actual capture closure
over the private captures registry. Current Capture writes only private records/
counters; it does not SetPos/SetScale or otherwise intentionally mutate the object.
Nevertheless custom/rebound methods and any intervening yield need qualification.

## Cheapest decisive experiment, not an optimization yet

Create diagnostic-only source clones of AnnotateDecorRelief/Capture with every
original private upvalue cell joined. Use their public seams, no module reload,
class/native getter rebindings, source-grid mutation or repeated actual getter.
Count actual getter occurrences and compare repeated same-callback returned values
and method identities. Keep only callback-local observations plus aggregate
counters, not unbounded object histories; separate initial/out-of-box callbacks
and object methods from captured point/box-value methods. No per-call timers.

Use whole callback/helper spans only to bound the investigation. Keep all
original function calls/arguments/return tuples, failed-read retries, traversal
order, height probes, segment rays and individual contact/sample records intact.
Value subtype and position fallback differences matter. Native logs/error latches
must be audited because game error/assert functions can log without throwing or
returning standard Lua values. Restore owned seams on normal/error/rebound paths.

Run reference and61N with full predecessor/private/individual-rock/process
audits before selecting reuse. If duplicate observations are a small share, rule
the lead down rather than claiming its entire2-3second parent is an optimization
budget. A qualified future reuse candidate must preserve every output and receive
independent actual-source/native/whole-pass/cold gates. No new implementation or
performance estimate is established by this note. Full goal remains ACTIVE.

## Astra review follow-through: bounded rock-value census implemented

The latest explicit Astra/xhigh review supplied two new native-selection leads
(mutation-maintained Filler eligibility; exact-composed Playable distances) and
confirmed rock-local scalarization as the cheapest narrow experiment. It also
identified a critical annotation hook issue: map_generation captures the public
AnnotateDecorRelief export in a local at2084. Rebinding that export alone does
not intercept its generation calls. The initial experiment therefore instruments
only the dynamically called RockGrounding.Capture, not all annotation getters.

rock_geometry_census.lua clones the actual Capture body, replacing exactly15
source occurrences of nine bounds/visual coordinate roles. All original private
upvalue cells are joined, including the capture registry and Eligible function.
No original method, object/class/global getter, native function, config flag or
production file is rebound. The public Capture and final-restoration seams are
temporarily owned; original getters execute once with unchanged receiver/tuple.

Keep only the first returned tuple/method/receiver per role within a Capture,
plus aggregate counters. At most9 roles/context,16 simultaneous contexts,
4 environment rows and32 retained failure messages. Contexts are coroutine-local
and discarded after each Capture, including errors. No additional getter calls,
per-read clocks, cached answers, stored object histories or skipped sample work.
Count repeated reads, differing values/numeric subtypes, methods and receivers;
unchanged observations do NOT establish immutability or absence of yields.
Normal scheduled surface completion and thrown/false Capture/final paths restore
owned seams, never overwriting unrelated replacements; failures stay latched.

170 actual-source fixture checks PASS: complete ordered original method/point/
terrain/ray calls, exact private contact records and capture counters across14
modes, including early exits, invalidZ, no hits, changed values/subtypes/methods,
nil-bearing return tuples, getter/final errors, false final, and rebound owners.
Two missing-source/anchor preflights leave seams untouched. An initial fixture
incorrectly gave sizey a multi-return nil tail: the unchanged source forwarded it
into math.max and correctly failed. Moved that tuple case to miny, an arithmetic
single-value context; this was a fixture correction, not a production change.
rock_geometry_census_offline retains all6 prerequisite commands PASS, including
exact accepted56fbf44 Code/metadata/items and38-file deployment audit.

Next finite native experiment: one reference and one61N through profile.py,
querySBM_ROCK_GEOMETRY_CENSUS, declared v987 predecessors and normal owned
shutdown. rock_geometry_census_audit.py requires full exact predecessor/grid/
individual-rock/four-private-field/process parity and bounded valid census.
Native runs are still pending here. No speed claim or production optimization.

## Native rock-value census CLOSED PASS

Frozen e0ab40cc6edae2fa24e32821f0d212ccfd5b91f8:

| Scope | Capture invocations | Actual geometry reads | Repeated within Capture |
| --- | ---: | ---: | ---: |
| Reference surface | 16579 | 278817 | 228939 |
| 61N136W surface | 16249 | 643240 | 599615 |

Reference v987_rock_geometry_reference: exec16739/PID53784,
creation134337795488268409 CLOSED exit0. Slow61N v987_rock_geometry_61n:
exec30712/PID46212,creation134337797436179045 CLOSED exit0. Both normally
flushed/quit, full rock_geometry_census_audit PASS issues[]. All predecessor
grids/individual-rock results/four private-stream fields exact; no native errors.
All5 original private cells joined,15 source occurrences instrumented, peak9
roles and1 simultaneous Capture, both owned seams restored, config unchanged.

Every observed repeated value (including numeric subtype), method and receiver
remained unchanged; zero nonscalar returns. Combined828554 repeats out of922057
reads. Dominant repeated roles reference/61N: bounds.sizey69640/138844,
bounds.miny64873/135397, bounds.minz20252/95326, bounds.maxz21791/99073.
The reference capture executes21414 segment rays; its final stats29309 also
include later Apply rays (rock_grounding.lua159..161). Do not use the combined
counter as if every ray were inside Capture.61N capture has97361 rays.

Decision: proceed to a PRIVATE Capture-local scalar-reuse candidate, not broader
object-getter caching or production integration. Native docs describe point
coordinates and box extents as integer reads, but census equality alone does not
prove custom-method purity, immutability, or no yields. Qualify actual native
value/method identities through supported mod APIs, retain unchanged fallback
for custom/rebound values, and retain first-use laziness and numeric subtypes.
No source stamp substitution, removed ray/probe/contact, changed Apply, or eager
new reads. Validate original/candidate actual source with complete ordered native
terrain/ray/sample arguments and exact private records, then measure the whole
Capture/annotation work with preparation included before any cold gate.

The observed stable repeats justify testing this lead; they do not estimate its
speed benefit. Prior enclosing capture537/1212ms still caps its plausible scale,
not the whole2203/2859ms annotation parent. No instrumented timing is a cold
sample. This cannot by itself establish the remaining7.125s slow-site sub85 gap.

Retain the higher-upside distinct Astra alternative if geometry reuse yields
too little: maintain Filler radius eligibility masks through EVERY monotone
place_grid circle clearing, avoiding repeated GridAnd as well as GridMask.
Unlike rejectedv992, update all admitted owned masks; keep similar_apply on a
separate copied trial destination and preserve every original seeded selection.
The diagnostic mask+And parent1481/1731ms is not a saving: initial construction,
all maintained-grid updates, copies, guards and cleanup must be charged. First
shadow every trial grid before unchanged similarity/selection; reject if update
cost consumes the gain. Playable distance min-composition is a separate cheap
falsification lead, but native discrete/saturation/empty-source exactness is not
proven. Do not revive unchanged rejected candidates or weaken any rebuild rule.

For a genuinely new candidate, prospectively declare finite interleaved accepted/
candidate samples and all six sites before timing. Historical unchanged-v983
confirmation varied90.244vs86.718s (v984_source_review.md68..78); that supports
contemporaneous controls, not retroactive rescue of rejectedv984/v992 results.
Current accepted production remains56fbf44/v987. Neither all-site<80 nor<85 is
achieved. This turn PROGRESS: implemented/tested a new diagnostic and obtained
two complete native censuses that qualify the next candidate's actual workload.

## Private guarded scalar candidate and exact Capture replay ready

rock_geometry_candidate.py creates nine reversible source edits/15 read sites;
production stays acceptedv987. candidate_2 retains evaluation order, including
math.floor lookup before extent evaluation, IntersectSegment method lookup
before point arguments, hit Z before visual Z, and record-table lookup before
record getters. Initial generator artefact retained; candidate_2 corrects floor
lookup ordering before any native experiment. All arithmetic remains literal.

Each native point/box role retains its first successful native scalar, lazily.
Every later read resolves the CURRENT method once; only the canonical native
method may reuse the saved value. Custom/rebound methods execute normally and
do not poison the native slot. Reinstating the native method may reuse the fixed
native value again. The count's variadic math.max expression stays literal for
custom size methods so nil-bearing/multiple returns retain original semantics.
No cross-Capture cache and no object observation reuse. All terrain probes,
segment rays, point arguments, sample order, contacts, counters and Apply remain.

rock_geometry_native.lua qualifies native box/point constructors, predicates
and nine coordinate methods using supported string.dump with Lua/C controls.
No debug API enters the candidate helper. Unavailable/custom protocol disables
reuse. Qualify checks actual native value kinds plus live predicate/Engine.Global
identities. Native value docs describe coordinate reads and operations returning
new values; per-read method guards avoid assuming intervening calls cannot
yield or rebound methods. Native game behavior still needs verification.

Offline:560 actual-source candidate checks across five extents (sample counts
3/4/6/9), including complete ordered external calls, exact private contact records,
unchanged counters, custom fallback call counts and mid-ray rebound/restoration.
13 native-protocol/fallback checks,114 actual-source shadow/lifecycle checks,
and170 retained original census checks PASS. All10 prerequisite commands in
rock_geometry_candidate_offline PASS, including syntax, exactproduction and
38-file deployment audit. Model-native fixture identities are controlled doubles,
not proof of actual engine types or a performance result.

rock_geometry_shadow.lua lets the actual candidate drive the game. An independent
accepted-source Capture replays every eligibility/object/terrain/point/ray/clock
call against a copied private context/stats and its own current-object record.
Native external calls execute once; oracle point/box getters read the same fixed
native values again. All15 candidate getter sites are checked for canonical
method identity; unexpected custom geometry refuses oracle execution rather than
executing potentially impure getters twice. Compare complete event order/argument
identities/numeric subtypes/return tuples, every sample record and all counters.
Limit1024 transient events/currentCapture and4 aggregate environment rows; reject
overlapping captures, clean contexts after every result, preserve rebound owners.

Next frozen native61N thenreference through profile.py and full
rock_geometry_shadow_audit.py, querySBM_ROCK_GEOMETRY_SHADOW. These are correctness
proofs only. Whole-work old/new/new/old timing including qualification/setup/guards
is required before any integration; the guarded candidate may cost more than the
native reads it avoids. No native speed evidence or START-to-T1 improvement yet.

## Guarded scalar candidate native proofs CLOSED PASS

Frozen b58331524b767e0717d686fff866a3c5928cbcd4, same private candidate_2
SHA256a996db9fe0b56686b975b83b5c6d5d4ae5ad9c540d3d175cfe22f217a7edd24f:

| Scope | Captures | Native geometry qualified | Ordered external events | Exact contact records |
| --- | ---: | ---: | ---: | ---: |
| 61N surface | 16249 | 12189 | 681209 | 1712 |
| Reference surface | 16579 | 14447 | 325930 | 377 |

61N v987_rock_scalar_shadow_61n: exec54644/PID57640,
creation134337810416399458 CLOSED exit0. Reference
v987_rock_scalar_shadow_reference: exec54691/PID47028,
creation134337812328195326 CLOSED exit0. Both normally flushed/quit;
rock_geometry_shadow_audit PASS issues[] on full predecessor/grids/individual
rocks/fourprivatefields/native logs/process identity. Candidate drives actual
external calls once; accepted replay matches1007139 ordered event records and
every contact/sample/counter/return tuple. No noncanonical read or mismatch.
Peak415 transient events per Capture, below1024 cap; all scratch/owned hooks
cleared andconfig unchanged. Candidate joins3 original cells, oracle2; the other
cells are the explicitly instrumented Global/Eligible and isolated oracle capture
registry. Native qualification uses the actual supported mod environment.

After both frozen runs, strengthened only the fixture: a qualified native box
with custom sizey returning a nil-bearing tuple must retain the literal variadic
math.max error, not silently scalarize it.595 actual-source candidate checks
now PASS across five extents, plus13 qualifier/114 shadow/170 census checks =892.
New rock_geometry_candidate_offline_2 all10 commands PASS; initial batch retained.
Private candidate/helper/shadow sources and production did not change after the
native checkpoint. Standard38-file deployment audit PASS; fresh game check clear.

NEXT ACTION is the finite coarse performance test, not another alternatives or
census turn. Measure the WHOLE AnnotateDecorRelief call through its actual shared
upvalue in MapGeneration.RunSurfaceStretchIfEnabled (export13803, caller10691),
not just the public TerrainCopy export. That captured cell also reaches the
nested pipeline. Two coarse clocks per annotation, no per-object/replay counters.
Original variant calls accepted Capture directly; candidate variant installs the
proven private Capture with every original private cell joined and only its own
NativeGeometry helper injected. Charge helper qualification/initialization once
inside the first measured annotation; preserve the original annotation and every
Capture invocation. Do not hide setup cost outside the measured work.

Declare and freeze old/new/new/old61N, four fresh owned processes with full audits
and unchanged payload throughout. If both orders fail to improve whole-work cost,
reject this guarded implementation and prioritize mutation-maintained Filler
eligibility; do not promote from eliminated-read counts. If promising, measure
reference before production/cold consideration. All-source RNG review and eventual
reference/five-site START-to-T1 gates remain separate. This turn PROGRESS: actual
candidate,892 fixture checks andtwo complete native private-record proofs; not
performance acceptance. Acceptedv98786.606/worst92.125,all<80/<85stillunmet.

## Whole-cost follow-through: guarded scalar implementation REJECTED

171 coarse actual-Capture/scope/lifecycle/tuple/init-placement checks and all7
rock_geometry_coarse_offline prerequisites PASS. The observer hooks the actual
shared AnnotateDecorRelief cell, clocks the full annotation only twice, initializes
the helper inside that interval, and installs/restores candidate Capture only
around the annotation. No per-object clocks, getter counters or replay.

Frozen b057cea72881e67ebc0feae8ee87001d31749979, old/new/new/old61N:

| Run | Whole annotation ms | Existing capture counter ms | PID | Creation |
| --- | ---: | ---: | ---: | --- |
| old_a | 2942 | 1322 | 54644 | 134337817971155011 |
| new_a | 3100 | 1447 | 54460 | 134337819750285462 |
| new_b | 3123 | 1406 | 55724 | 134337821541224375 |
| old_b | 2971 | 1279 | 49344 | 134337823520129741 |

Candidate whole-work differences are158ms and152ms SLOWER. All four full
rock_geometry_coarse_audit checks PASS exact predecessor/grids/individualrocks/
fourprivatefields/normalflushedlogs/ownedhooks/config. Candidate5 privatecells
joined; helper initialized exactlyonce within measured work. Existing capture_ms
is a nested counter, not additional time to add to whole annotation.

Driver80524 CLOSED exit1 AFTER three successful samples: fresh-game guard briefly
still listed normally-closedPID55724 before startingold_b. Authoritative process
recheck found no PID/no game;HEAD andevery frozen hash matched;old_bdirectory
absent. Only unstartedold_b resumed in45216 and CLOSED exit0. No replacement,
repeat, reused game or forced close. rock_geometry_coarse_complete validates all
four original checkpoints/audits/identities/frozenhashes, retains the three-row
results.json andwrites comparison.json with the interruption explanation.

Decision: reject THIS guarded scalar implementation before reference timing or
production/cold integration. Removed-read counts and exact native proofs did not
translate into lower whole-work cost in either order. These four observations
are not a significance/causal proof about every possible geometry optimization;
they do satisfy the predeclared rejection gate for this candidate. No unchanged
retry, removal of method guards, or claim of startup gain. All code/evidence kept.

Production/deployment remain exact56fbf44/v987,38-file auditPASS and no live game.
Next distinct larger lead: mutation-maintained Filler eligibility; see
filler_eligibility_research.md. Current accepted86.606/worst92.125 and full<80/<85
remain unmet. This turn PROGRESS: completed finite both-order measurement,
established no gain for the proven candidate, and ruled it out without deployment.

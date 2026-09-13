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

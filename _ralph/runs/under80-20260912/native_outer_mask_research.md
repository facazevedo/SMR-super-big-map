# Native outer mask: pre-implementation research

No production candidate, native certificate or speed claim. Accepted v983 remains
frozen while its declared five-site confirmation runs. No CPU-heavy study is run
concurrently with those cold games.

## Evidence changing the experiment

The existing reference coarse-mask capture covers 56 patches / 948,237 samples.
Grouping its actual patch records by protected-site count gives:

| Guards | Patches | Samples | Instrumented scalar-loop ms |
| --- | ---: | ---: | ---: |
| 0 | 13 | 107170 | 216 |
| 1 | 12 | 114949 | 265 |
| 2 | 12 | 214883 | 547 |
| 3 | 11 | 269027 | 792 |
| 4 | 5 | 151380 | 485 |
| 7 | 2 | 60552 | 244 |
| 8 | 1 | 30276 | 126 |

Therefore an unprotected-only replacement addresses just 216 of 2675 measured ms.
It is not a sufficient implementation of the recommended whole-mask alternative.
The source of these counts is artifacts/outer_coarse_profile_reference/
diagnostic_state.json, not an extrapolation from the latest profiler snapshot.

Actual core/radius ratios range from 0.0581395348837209 to 0.209205020920502.
The accepted apron proof assumes different geometry and core fractions >=0.2;
copying that proof or its numerical allowance is invalid for these masks.

## Prepared diagnostic and numerical study

`_ralph/tmp/under80_20260912/outer_geometry_capture.lua` recompiles only the actual
PrepareOuterResourceTerrain closure and joins every original private upvalue.
One injected call per patch records cx/cy/core/phase/relief, base transition,
irregularity, original coarse bounds/step, and every protection blend in order.
It also retains the original cached zero-angle harmonic after mask construction,
so the numerical study need not recompute it with a different platform math library.
It adds no per-cell hooks or random draws. Original mask generation, writes,
reports and rebuilds remain unchanged. Final sample counts must match the report.
The source parses; native execution and exact whole-map parity are still required.

`outer_mask_error_study.py` replays those captured patches using both the original
missing-atan2 formula and an exploratory normalized-coordinate f32 expression.
It reports raw U12 differences, observed weight errors, and hypothetical ambiguity
counts for several error budgets. It deliberately does NOT implement an optimized
native path or claim that a tested budget is a bound. Native power operations,
coordinate storage, arbitrary supported numeric domains and errors/ownership are
not certified by this study.

## Required next gates

1. Finish the cold matrix without modifying checkpoint/payload. Run the geometry
   capture in one separate fresh diagnostic and require complete predecessor parity.
2. Use the recorded full guard cases for the empirical study. If correction density
   or native operation count is unattractive, reject before a production candidate.
3. Derive a new conservative bound, including coordinate and coefficient encoding,
   root/reciprocal residual checks, directional width, quintic arithmetic, and every
   ordered protection product. Zero-width guards require a separate discontinuity
   certificate or exact scalar confirmation; a smooth Lipschitz bound is insufficient.
   A patch-wide sum of all guard error bounds may be too pessimistic: most guards
   return exact one over most of a patch. Investigate certified constant regions
   and per-cell transition/error masks, while retaining the original ordered product.
4. Build a private native shadow with explicit allocation/cleanup/failure checks.
   Compare every coarse U12 cell and all final terrain cells, in both execution orders.
5. Only then consider a genuinely new frozen candidate and all reference/control/
   five-site performance and correctness gates. No skipped samples, RNG changes,
   work cuts, altered reconstruction, or omitted scheduled revalidation.

## Captured real geometry and numerical screening completed

Geometry session92873, owned PID40532, CLOSED normally at fd5f4e9; diagnosticPASS,
all56 patches/948237 samples captured, complete predecessor/full-snapshot/
individual-rock parityPASS. Evidence: artifacts/outer_geometry_capture_reference.

Normalized-coordinate study58560 CLOSED, augmented replay96518 CLOSED. Both report
312 raw U12 differences and observed maximum weight error4.806765651910183e-5.
The largest error is patch12 at(1428,692), a guard centered(1410,692), radius17.31,
transition1.4493775937428666. Reference weight0.45472693792247565 versus proposed
0.45477500557899475. Small normalized-coordinate errors amplify across that narrow
transition. Budgets1/65536 and2/65536 were exceeded on9 and2 samples respectively,
despite zero observed false rounding certificates. Therefore absence of a failed
rounded result cannot validate either budget. Budget4/65536 observed205016 ambiguous
samples(21.621%);8/65536 requires935218(98.627%), illustrating a correction-cost cliff.

The complete capture has integer patch centers56/56 and integer guard centers111/111.
Minimum positive guard transition is0.380000000000003. This suggests a better input
representation: keep integer grid-space coordinate differences/squared sums exact
instead of normalizing first. A second numerical variant asserts integer offsets
and every squared sum<=2^24 on all captured samples, then carries f32 operations in
grid units. These domain checks pass for the entire capture. Any eventual native
implementation still needs explicit numeric qualification and positive-storage/
signed-decode checks, not assumptions about other maps or custom inputs.

World-coordinate study8400 CLOSED:209 raw U12 differences, maximum observed error
1.3764691164652731e-6 (about35x smaller than the normalized variant). Hypothetical
budget1/65536 observes51449 ambiguous cells(5.426%) and zero bound exceedances or
false certificates. This is screening evidence, NOT a mathematical or engine proof
of that budget and NOT a speedup. All five budget summaries remain in results.json.

Actual-source scalar oracle passes ALL948237 U12 values across all56 patches for
both augmented normalized and world-coordinate studies. The oracle extracts the
production scalar mask and protection function directly, cross-checking the Python
reference and captured geometry against actual Lua. It does not validate the f32
candidate, native root behavior or any untested inputs. Artifacts preserve the first
study, augmented study and world-coordinate study separately, plus literal scalar
binary outputs and oracle results.

### Next experiment

Prioritize a private integer-grid-coordinate NativeOuterMask prototype over the
normalized-coordinate variant. Preserve full mask dimensions/resampling and guard
order. Generate exact coordinate fields with positive integer storage plus native
signed decode; qualify square/add bounds explicitly. Encode scalar coefficients
using legal integer-ratio native arguments. Establish new checked root/reciprocal
bounds, protection transition/discontinuity handling, polynomial/product error
propagation and U12 ambiguity correction before trusting any cells. Compare the
native kernel against every captured scalar U12 cell and both-order full terrain
shadows, then evaluate allocation/correction cost. No production change is justified
by this numerical study alone.

## Private native prototype and failure-path counterexample

Research only; production remains accepted f4d1da6/v983. The prototype preserves
integer coordinate fields and guard order, handles zero-width guards with exact
integer squared-distance thresholds, and corrects ambiguous U12 cells using the
literal production scalar formula. No full-map shadow or cold candidate was run.

Preserved successive experiments (all owned engines shut down normally):

| Artifact | Result | Corrections | Kernel-only time |
| --- | --- | ---: | ---: |
| native_outer_mask_scratch | Refused patch 3, unsupported hard guard | — | — |
| native_outer_mask_scratch_2 | All 948237 cells exact; unproved fixed budget | 51444 | 416 ms |
| native_outer_mask_checked_scratch | All cells exact; subsequently found allowance integer-division and residual-range defects | 108649 | 877 ms |
| native_outer_mask_bound_scratch | All cells exact with corrected conservative allowance, N=2..4 | 128803 | 996 ms |
| native_outer_mask_residual_faults | FAIL: corrupted root did not produce rejection | — | — |

The corrected allowance is ceil((324 + sum_soft(82 + 6*r/T))/256.0).
The explicit floating divisor matters in the engine. Amplified residuals are
clamped before counting so a large error cannot escape the upper census bound.
The exact-rational bound script passes conditional arithmetic propagation, but
native primitive/source-double/underflow premises remain audit obligations.
It is not a production certificate. The private offline Lua suite passes 6365
checks, including all 26 allocation-failure positions and several arithmetic,
callback and cleanup failures; it uses ordinary Lua error semantics.

Crucial native counterexample: PID 41000 logged `[LUA ERROR] native outer root
residual` after GridPow's root was multiplied by 1000, yet the prototype returned
a mask instead of rejecting it. The engine error() used by require_value logs
and returns in this context. Thus its pcall-based rejection assumption is invalid,
even though the numerical residual detected the fault. The first case stopped
the probe; the remaining three planned perturbations were NOT exercised.
Preserve the failing logs. Do not describe the prototype as fail-closed or deploy it.

Next gate: explicit, engine-verified failure propagation and cleanup that does
not depend on global error()/assert() throwing, including callback failures.
Then repeat every native fault case, audit arithmetic premises/domain boundaries,
and run both-order complete-map shadows before considering production/cold timing.
996 ms is an isolated kernel measurement, not demonstrated end-to-end savings.

### Explicit rejection correction

Replaced logging-dependent require_value with a first-failure latch and explicit
returns through allocation, coefficient, distance, reciprocal, polynomial and
correction paths. Callback failures stop subsequent correction writes; failure
discards the result and runs owned-grid cleanup. No native globals are replaced.

Session27562/PID37824 CLOSED: all four original native root/reciprocal perturbations
rejected, with no LUA ERROR. Session70042/PID47028 CLOSED: native proxy-tracked
ownership tests pass normal return (only result survives), every one of 26
allocation-failure positions, missing/duplicate/invalid-coordinate callbacks and
invalid scalar results; all owned grids released once. Offline suite now passes
6370 checks. Earlier failing evidence remains unchanged.

Prepared private full-map shadow in both execution orders. It recompiles only
PrepareOuterResourceTerrain and joins original private cells, compares every
candidate/scalar U12 coarse cell before resampling, then feeds matching candidate
masks through the unchanged terrain pipeline. The normal rules runner will check
complete predecessor parity. This still does not establish arithmetic premises
or a cold performance improvement. Production remains unchanged.

### Both-order full reference shadows

Both ran the identical 8a5a90e kernel and original private function cells; no
production/deployment change or checkpoint change occurred between orders.

| Artifact | Owned PID | Compared coarse cells | Native kernel | Scalar loop | Full predecessor parity |
| --- | ---: | ---: | ---: | ---: | --- |
| native_outer_mask_shadow_native_first | 32516 | 948237 / 56 patches | 967 ms | 2417 ms | PASS |
| native_outer_mask_shadow_scalar_first | 38620 | 948237 / 56 patches | 930 ms | 2445 ms | PASS |

Sessions58141/46745 CLOSED normally. Every compared candidate mask was used in
the unchanged resampling/terrain pipeline. Full runtime comparison reports no
rule differences, no full-snapshot differences and no rock-grounding differences.
Runtime RNG comparisons do not replace the independent source audit. Diagnostic
elapsed times include both kernels and exhaustive reads, not cold candidate time.
The paired kernel difference is 1450/1515 ms, not a demonstrated START-to-T1 gain.

After both runs, the proof-domain audit found huge coordinates could lose scalar
step increments while native coordinates retain them. A new offline regression
reproduced acceptance of that unsupported domain. Fixed by explicit finite bounds
on grid origins and every center. Also require the original radius expression,
finite phase, matching literal harmonic cache, and manual allowance at least the
derived value. All refusals precede allocation. The ordinary-Lua suite now passes
6382 checks, including a logging-only error() regression. Conditional rational
bounds still pass; source-double, interval and primitive premises remain open.

Qualified native replay18057/PID22068 CLOSED normally: all948237 captured scalar
cells exact,128803 corrections,1033ms kernel-only; no Lua errors. Artifact:
native_outer_mask_qualified_scratch. The qualified revision is newer than the
both-order full-map checkpoint, so those full-map results are not mislabeled as
tests of its new refusal guards. No engine remains; production/deployment unchanged.

### Slower-site shadow and arithmetic-model checks

At81e63ed, qualified61N shadow60209/PID8660 CLOSED normally:50 patches/740771 cells
exact,104476 corrections, native849ms/scalar2006ms, full predecessor/snapshot/rock
parityPASS. This predates the following explicit-float allowance correction.

Changed guard allowance6*r/T to6.0*r/T to avoid engine integer division. Native
domain86990/PID49924 CLOSED PASS: r213,T12 gives derivedN3 at the512.5-unit boundary;
nine unsupported cases refuse before allocation. Conditional rational audit now
covers source-double, interval, allowance arithmetic and encoded-constant margins.

Primitive99602/PID49824 CLOSED with15 exported1024-cell f32 grids. Exact rational
audit checks12288 results: half-up modelFAIL2 rounding ties; nearest-even modelPASS
all. This changes the documented rounding premise, not the native algorithm.
Strict interval margins force exact half-way cases into correction. Native actual-
tail injection39227/PID49196 CLOSED PASS all4096 ties,2048 changed by correction.
Both passing and failing model evidence are retained in native_outer_primitives.

Next freeze the new revision for a sequential reference-plus-five shadow batch.
Full final parity and exhaustive coarse-mask comparisons remain required on each
site before a production/cold decision. No end-to-end improvement is claimed.

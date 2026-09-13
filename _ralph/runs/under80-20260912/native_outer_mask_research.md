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

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

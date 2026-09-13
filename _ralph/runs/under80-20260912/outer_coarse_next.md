# Next independent lead: exact outer coarse masks

Research lead only; no implementation or gain claim. Accepted production remains
v983/f4d1da6. Fresh confirmation reference median90.244s, not the historical86.718s.
Do not rerun unchanged rejectedv984 as a rescue. Its exact decor work reductions
are preserved research, not accepted startup gains.

Existing outer_coarse_profile_reference records56 patches,948237 coarse samples,
422144 transition samples,513213 final zeros and111 total protection guards (up
to8 per patch). Core/maximum-radius ranges0.0581395..0.2092050. Instrumented coarse
time2675ms of3363ms patch total/3771ms whole preparation. Counter instrumentation
adds overhead; these are not clean cold timings. Kinds are surface/extractor/rocket.

Current scalar loop in TerrainCopy.PrepareOuterResourceTerrain still evaluates
and writes every coarse cell. Missing atan2 deliberately gives angle0 and the
literal harmonic is already cached by v978. Directional along_relief terms remain,
as do every protected-site factor, exact core restoration and later native blend.
Do not restore atan2, substitute math.atan(y,x), remove guards or change U12 masks.

Two avenues need actual proof/testing, not assumptions:

1. Exact work removal: initialize the coarse field to zero, evaluate only a
   conservative row-wise enclosure of the existing maximum-radius disk, and keep
   the literal scalar calculation inside it. The radius already bounds all width
   lobes via the unchanged1.35 clamp. Outward rounding and generous cell padding
   must prove no potentially nonzero sample is excluded. Preserve complete coarse
   dimensions/resampling, sample accounting and failure behavior. The private,
   densely built protection_blends array may also support numeric iteration and
   avoiding iteration entirely at exact zero. No production code exists yet.

2. Native coarse mask with exact U12 rounding correction: adapt the proven positive
   Q22 coordinate technique, certify native roots/reciprocals and polynomial error,
   then correct EVERY ambiguous U12 cell with the exact predecessor expression.
   Normalize distance by base_transition; width is clamped to[0.5,1.35]. The
   direction-dependent term and protected factors must be included in the bound.
   Small core ratios and zero/narrow protection transitions prevent blindly
   reusing the apron certificate. Discontinuous protection membership requires
   exact treatment. No approximate mask may reach native resampling unchecked.

Any candidate must preserve native plane, U12 resampling, support/core circles,
all protected footprints and final blending/rounding. Native allocation/power/
enumeration failure and ownership tests, complete scalar/coarse/native oracles,
full-map shadow and frozen cold reference/control/five-site validation remain
required. A current wall-stage diagnostic may refine the opportunity estimate;
do not extrapolate the full old instrumented2675ms as available savings.

# v959 native apron source review (runtime acceptance still required)

Only the shaping raster is replaced. Existing full-resolution apron selection,
eligibility, deterministic ordering, zero-edit opportunities, dimensions and
quintic/lobed blend policy remain. The old tree's coarse mask, restored central
rectangle and unsafe crease feather are not copied. No resource or rock code,
RNG, placement rule, native-control path, UI or temporary button is changed.

Native F32 arithmetic uses integer-centered elevation offsets and the original
full-resolution mask. Nonnegative biased plane seeds avoid ComputeGrid:set's
unsigned conversion; the bias is removed natively before interpolation. Exact
integer seed encoding is bounded at2^24. U16 rounding is bracketed with a
conservative F32 error allowance (height/plane magnitude divided by2^19 plus
four scaled units). Cells whose endpoints round differently receive the literal
pre-port scalar expression before copyback. This is normal exact rounding
correction, not a fallback after failure. The shared integer-center formulation
avoids large absolute-elevation cancellation. Patch overlap remains sequential.

The bracket includes endpoint quantization (at most half a scaled unit), mask
quantization, interpolation and subsequent F32 multiplication/addition errors.
The coefficient is32 float unit roundoffs, with an additional4/256 height-unit
floor. Every copied result is bounded to U16. Counts come from exact integer
differences, not approximate mask areas; profiling is separate from the existing
semantic report. Required APIs and allocation results are checked explicitly.
Rounding callback count and coordinates must match the native nonzero census.

Scratch resources are owned per patch and freed in reverse order on both paths.
Any error records OptimizationFailure; the caller releases its private terrain
result and returns without publishing it. No non-throwing engine assert/error
is used as control flow, and no scalar retry can hide a failed native operation.

Live scratch-grid comparison covers20 rotated/overlapping cases with low, high,
ramped and noisy terrain. First prototype failed because native setters wrap
negative inputs even in F32 grids. The corrected biased encoding matches every
cell and both semantic counts in all20 cases; evidence is native_apron_probe2.json.
The failed diagnostic output is retained separately, not accepted or deployed.

The offline test double was corrected to model unsigned setters. Production-helper
tests cover15,414 assertions including missing API, allocation and callback
failure with no terrain publication. The existing9-fixture whole-apron regression
now compares the complete canonical final grid, selection and semantic reports:
native bulk copyback intentionally has different read/write traces. Source-policy
checks follow the extracted helper and still check the same blend and no-edit
properties. The old scalar raster remains test-only and fixed at1159341.

Acceptance requires fresh cold14N A/B/C plus native control, and five fixed-site
exact twins of v958: full Surface/UG heights/pass grids, sites/pads, grounded rocks,
ordinary/private streams and all standing rule gates. No new visual acceptance
can be inherited if any actual output differs. Timing uses the unchanged START
body through post-pipeline revalidation; scratch speed is not a T0->T1 result.

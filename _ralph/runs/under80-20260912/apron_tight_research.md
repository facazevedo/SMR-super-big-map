# Tighter unchanged-operation Q22 apron bounds (private)

Accepted production remains56fbf44/v987. Reference records396398 exact scalar
corrections over5039674 native apron cells. This investigates a stronger bound,
not fewer native checks or changed terrain arithmetic. No crease/decor combination.

The inherited Q22/residual proof computes radial error1.555552e-6, then rounds it
up to2e-6; direction terms are then rounded to2e-6+4e-6/c and normalized radius to
7e-6+3e-6/c. An additional16e-6 covers polynomial/core/U24 rounding. The candidate
uses the SAME domains, root and reciprocal residual checks and lobe lemma, but
propagates less loosely: radial<1.6e-6, direction<1.1e-6+2.5e-6/c, normalized
radius<5.6e-6+1.8e-6/c. All constants round UP and the exact-rational test verifies
every inequality. No measured native error supplies an accuracy assumption.

For fixed native normalized radius, the clamped affine core ramp differs from
the exact scalar ramp by at most q/(.25-q)+(1+u)^3-1, q=u/2+2u64. Dyadic scaling
by2^24 is exact, the subtraction and up to two divide/reciprocal-product roundings
are covered. Piecewise affine extrema occur at the combined segment endpoints;
clamping is nonexpansive. The quintic derivative is bounded by15/8.

Explicit polynomial error propagation uses |(6t-15)t|<=9, polynomial intermediate
in[1,10], and quintic output in[0,1]. Cover two cube multiplies, complement, U24
rounding<=.5u,512u64 for scalar arithmetic (bounded intermediate magnitudes<=15)
and u64 for negligible underflow/FTZ terms. Total polynomial/core allowance is
<71.876u; round UP to76u. Here u=2^-24 and u64=2^-53. These are conditional on
the same regular f32/scalar-f64 arithmetic premises as the accepted certificate,
not an unconditional engine implementation proof. Native boundary checks remain.

The final envelope is1.875*(5.6e-6+1.8e-6/c)/(1-c)+76u. Positive reciprocal terms
are convex, so exact and actual binary endpoint checks prove3/65536 for cores
[.20,.60] and5/65536 for[.60,.75]. Endpoint maxima44.842453e-6 and64.529953e-6.
The candidate changes ONLY the existing numerator5/7 to3/5 and its comment. The
local cubic sensitivity, native mask/plane/blend operations, four-H rounding
reserve, scalar correction formula, callback census, failure/cleanup behavior,
patch order and every other production operation remain literalv987.

No native/cold gain claimed yet. Full native differential evidence is mandatory;
the smaller allowance must preserve every resulting U16 cell and full report.

Private offline raster:58905 exact three-way old/candidate/literal-scalar cells,
39 cases with fewer corrections, including actual binary core endpoints and1/3.
221 inherited allocation/domain/corrupt-power/census/ownership checks pass with
zero final allocations. Exact-span/rounded-corner/radius guards pass. An independent
scalar polynomial oracle uses the ACTUAL extracted native polynomial block across
74016 positive-encoded normalized values/core rounding boundaries; offline maximum
13.000000015 U24 units is below76. This observed error is not used to prove the bound.

New native shadow runs that same polynomial oracle first, with explicit failure
latches and full cleanup; only then installs a complete-raster comparison. Both
algorithms receive identical input, but the original raster ALWAYS supplies game
output. Compare all full U16 grid cells with independent difference extrema/census,
full reports and reduced corrections; restore both wrapper and scheduled rebuild
hook after the existing scheduled surface revalidation. No debug flags are changed.

Native forward73986/PID23024 and reverse72052/PID9080 atfc8b748 CLOSED PASS. Native
polynomial74016 checks each, max13.029877663 U24units<76. Full67108864 U16 cells
exact each; modified1910302/shaped50/raster5039674 unchanged. Actual core=.2, not
an assumed1/3. Corrections396398->298392 (98006 fewer). Timingold1903/new1377ms
forward and1895/1330ms reverse.526..565ms diagnostic savings are not cold gains.
Both private_process_audit.json PASS, complete predecessor/private/rock parity,
scratch cleanup and wrapper restoration, unique normally closed owned processes.

v990 stages ONLY this exact bound/comment change plus metadata990/generator302.
Source reconstruction verifies every other byte of TerrainCopy equalsv987. Full87
actual-production regression is required; deployed mod remains acceptedv987. The
proof additionally checks the generous512u64 scalar reserve explicitly. See
v990_source_review.md for acceptance gates and full scope qualifications.

Cold v990 at88ff956 CLOSED: reference81751 median85.048s versus86.606s; five29557
15S89.314 (+0.661slower),24S90.117 (+1.406slower),45S82.044 (-0.009),61N91.773
(-0.352),17S86.390 (-0.156). All87 replay/nine-process/exact/private/rock/source
reviews PASS. Every site reduced correction counts, but two startup regressions
remain. Candidate NOT promoted; no rescue reruns/causal attribution/baseline relabel.
Production and deployed payload restored to exact56fbf44/v987,38/38 auditPASS,
no game live. Keep the valid conditional proof and work-reduction evidence, not
an assertion of broad startup improvement. Full samples/censuses in v990_source_review.md.

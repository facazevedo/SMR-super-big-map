# Higher-precision apron coordinate research (nondeployed)

Initial direct signed-set version REJECTED: signed_coordinate_native15853/PID41204
closed normally with statusfail, first value-16777216 read4278190080; the unsigned
setter is also explicitly modeled in native_grid_double.lua. Its offline raster
failed the unchanged final-census comparison. Preserve those artifacts in
precision_coordinate_research and signed_coordinate_native; no production change.

Replacement precision_coordinate_research_2 uses an adaptive POSITIVE integer
encoding: for each axis round to Q22 integers, compute the minimum, store
encoded-minus-minimum, copy the positive row/column, add the signed minimum using
native arithmetic, then divide by Q. Require axis encoded span<=2^24 and combined
quantized corner sums within signed24-bit magnitude. All stored/intermediate
integers are exactly representable, and the dyadic division is exact. Numeric
domain rejection retains the existing scalar mask, not a partial approximation.
The old root/reciprocal checks and scalar correction expression are unchanged.

Native prerequisite62037/PID28588 closed normally PASS646 checks, including
negative decoded magnitudes, dyadic roundtrip and positive doubling copies.
Offline38115 three-way exact U16 comparisons pass (21 cases reduce corrections),
plus exact-span/rounded-corner guards and221 inherited allocation/clone/corrupt-
power/census/ownership checks. Rational propagation passes as recorded below.
Next: larger real-engine scratch raster comparison and complete-map shadow.
No cold gain or production promotion yet.

Native scratch5657/PID32976 (variant2) CLOSED PASS523776 exact cells,33 cases,
zero differences between literal scalar, accepted v979 and Q22 candidate. Cases
cover flat/rough/capped terrain, multiple patches and certified core endpoints.
Summed exact corrections41470->31891; these small-grid times are not a cold gain.

Variant3 adds ONLY radius>=2^-20 qualification to bound double-association and
subnormal amplification explicitly; smaller radii keep the existing scalar path.
This does not change any qualified arithmetic from variant2. Existing production
radii and all33 native fixture radii are above this threshold. Offline endpoint
and below-endpoint checks verify the new boundary. Use variant3 for full shadow.

## Bound derivation

Let u=2^-24 and coordinate error E=2^-21. Each rounded contribution is within
1/(2*2^22); two contributions plus the inherited double-association reserve fit E.
The adaptive encoding requires all positive spans and decoded signed sums to fit
24-bit integer magnitude, so native addition and dyadic scaling add no error.

For scalar radial r in[.85c,1.2], native coordinate norm differs by at most1.5E.
The two rounded square/add operations place sqrt(q) between norm*(1-u) and
norm*(1+u). Conservatively relaxing the UNCHANGED checked root residual, including
its arithmetic roundoff, gives |R^2-q|<=(2^-20+4u)*q+2u. Across this domain the
relative allowance is below1-.99^2, so R>=.99*sqrt(q). Thus root error is at most
(A*sqrt(q)+B/sqrt(q))/1.99, a convex function bounded at the two interval endpoints.
Together with coordinate/square error this is<1.556e-6, below the chosen2e-6.

The inherited reciprocal check bounds relative product error by
rho=(16/2^24+u)/(1-u); include final multiplication via eta=(1+rho)*(1+u)-1.
Normalized-axis error is then<4e-6/c+2e-6. This is strictly smaller than the old
axis domain, so its .47 lobe derivative coefficient plus1e-6 arithmetic/second-
order reserve remains applicable. Both lobe boundaries exceed.90. Propagating
radial, lobe and reciprocal errors gives normalized-radius error less than
6.597e-6+2.786e-6/c, rounded UP to7e-6+3e-6/c.

Keep the inherited16e-6 allowance for polynomial evaluation, core quantization
and U24 weight rounding. Result:1.875*(7e-6+3e-6/c)/(1-c)+16e-6. Since
(7+3/c)/(1-c)=3/c+10/(1-c) is convex, interval endpoint maxima prove5/65536 for
c in[.20,.60] and7/65536 for c in[.60,.75], including actual binary endpoints.
U24 allowances1280/1792 and cubic coefficients15/21 over65536 are integral.
The existing local cubic sensitivity and four-H rounding reserve remain intact.

## Original hypothesis (superseded by positive encoding above)

Do not treat this note as a proved certificate or promoted candidate. Accepted
v979 remains unchanged. v980's smaller old-coordinate bracket was rejected after
its slower cold median; this idea requires NEW coordinate arithmetic and proof.

Current NativeApronMask stores floor(value*2^20+0.5)+4*2^20, then subtracts bias
and divides. The bias wastes signed f32 integer range. A possible replacement is
signed floor(value*2^22+0.5), directly stored and divided by2^22. First verify that
native f32 grid:set preserves negative integers exactly. All per-axis encoded
integers and combined corner sums must fit[-2^24,2^24], including rounding at
domain edges; otherwise retain the old-coordinate certificate or scalar domain
path. Preserve the original root/reciprocal residual checks, failure handling,
mask polynomial, scalar correction formula and four-H rounding reserve.

Draft propagation to check rigorously: new coordinate error<=2^-21 (fourfold
improvement, including the old generous double-association reserve). With the
UNCHANGED native root residual, aim to prove radial error<2e-6 on r in[.85c,1.2].
Axis error4e-6/c+2e-6, boundary error.47*axis+1e-6, and normalized-radius error
7e-6+3e-6/c appear conservative. Together with the inherited16e-6 polynomial/core/
U24 allowance, candidate envelope is1.875*(7e-6+3e-6/c)/(1-c)+16e-6.
Convex endpoint checks would fit5/65536 for c in[.20,.60] and7/65536 above through
.75. These values must NOT be used until a full exact-rational derivation and
native signed-grid/domain/original-raster comparisons validate every premise.
Only then measure actual correction counts and cold end-to-end performance.

# Unimplemented higher-precision apron coordinate hypothesis

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

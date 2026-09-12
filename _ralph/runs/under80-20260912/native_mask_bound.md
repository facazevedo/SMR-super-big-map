# Native mask error certificate

Candidate only; cold acceptance remains separate. The old exact scalar weight and
final rounding correction are retained. Numeric-domain rejection selects that same
scalar mask, not a coarser mask. Allocation/API/residual failures return an error,
never silently select a different implementation.

## Coordinate construction

Require core c in[0.20,0.75], finite coordinates/parameters bounded by2^20,
positive radii, dimensions2..16384, separate x/y normalized contributions in[-4,4]
and combined corner values in[-4,4]. Affine extrema occur at the corners.

Each x/y contribution is computed in ordinary Lua arithmetic and rounded to a
multiple of2^-20. Add bias4*2^20: encoded values0..8*2^20 are exact f32 integers.
Write only one row/column, expand through disjoint doubling copies, subtract bias
and divide by2^20. No interpolation or approximate transcendental is involved.
Adding the two fields is also exact in f32 because their integer numerators fit
inside24bits. Each normalized coordinate differs from its scalar counterpart by
at most2^-19, including a generous reserve for double arithmetic association.

## Native nonlinear arithmetic is checked, not assumed

For q=fl(u*u+v*v), compute r=GridPow(q,1,2), then verify over every grid cell:

    |fl(r*r)-q| <= q*2^-20 +2^-24

The implementation subtracts the relative allowance, scales by2^24 and counts
values above1. Either possible inclusive lower-bound convention is conservative.
Regular f32 arithmetic's rounding is included in the bounds below. The square-root
API's documented nonnegative-root semantics are retained; no precision guarantee
for GridPow is assumed.

For each reciprocal of a positive field a, similarly verify every cell:

    |fl(a*inverse)-1| <=2^-20

This is checked for the clamped radius and the lobe boundary separately. The
radius is clamped to1/8 before inversion. This lies strictly inside the minimum
constant-one core, so it cannot change the intended mask in that region.

## Propagated weight error

Only r in[0.85*c,1.2] can affect a transition: below it both implementations are
in the constant-one core; above it both are zero. Let E=2^-19 be coordinate error.
The coordinate error, checked root residual and ordinary f32 rounding give a
conservative radial error below5.5e-6 on this interval. Normalized-axis error is
bounded by8.8e-6/c +2e-6 (denominator >=0.85*c-5.5e-6).

For near-unit axes the lobe3 and lobe2 first-derivative L1 bounds are6 and4;
second-order terms at the above errors and native arithmetic fit the reserved
1e-6 boundary allowance. Thus boundary error is below0.47*axis_error +1e-6.
Boundary stays above0.90. Include its checked reciprocal residual: normalized
radius error is below12e-6 +7e-6/c. These allowances intentionally round upward.

The quintic derivative is at most1.875, and its argument divides by1-c. Native
polynomial evaluation, the quantized core fraction and final U24 mask rounding
receive another16e-6 absolute allowance. Therefore:

    weight_error <= 1.875*(12e-6 +7e-6/c)/(1-c) +16e-6

The positive reciprocal terms are convex on[0.20,0.75], so the maximum is at an
endpoint:126.157e-6 at0.20,176e-6 at0.75. Both are below1/4096=244.140625e-6.
Tests must exercise domain edges, root/reciprocal rejection, exact constant regions,
and deliberate allocation failures. Full native differential tests remain required.

## Exact final terrain

For approximate weight w and d=1/4096, cubic sensitivity is bounded by
3*min(1,w+d)^2*d. Multiply by local absolute terrain-to-plane displacement.
Add the already accepted native plane/blend rounding bracket, including its
four-H-unit reserve (which also dominates f32 rounding in the extra allowance).
If lower and upper possible heights round differently, evaluate the original
scalar expression for that cell. A matching pair of rounded bounds certifies the
same final U16 height without evaluating the scalar mask. No input cells, joins,
patch order, RNG, gameplay targets, rebuild dependencies or T1 semantics change.

# v963 exact apron-mask construction review

Predecessor: v962/691f900; candidate changes only mask weight evaluation and the
cells visited while filling the existing full-resolution native mask. No resource
mask, apron selection/order, plane/blend/rounding, native crease code, terminal
wall/spike repair, grounding, placements, RNG, temporary button or rebuild changes.

The row bound completes the square of ru^2+rv^2. Its positive leading coefficient
is mx^2/short^2+my^2/long^2; the stable perpendicular term is determinant/leading
coefficient. Radius1.14 encloses the original unconditional zero guard at1.12,
and two additional whole grid cells protect either endpoint against roundoff.
The native mask is still allocated at the original dimensions and initialized to
zero. Only provably zero row prefixes/suffixes are omitted. Every retained cell
is evaluated at its original integer coordinate, not by incremental approximation.

For nonzero radius the normalized direction has lobe2/lobe3 within[-1,1], making
the boundary lie in[0.91,1.09]. Squared radius>=1.10^2 certifies weight0, and
radius<=0.90*core_fraction certifies weight1. The large margins exceed F64 error
for these finite normalized coordinates. The tiny-radius fixed direction also
satisfies that boundary bound. All transition expressions retain original order.
The original native blending and ambiguous-cell exact scalar rounding are unchanged.
These shortcuts consume no RNG and introduce no new optional backend/fallback.

New regression was red before implementation. 845,617 checks pass, including
rotations, threshold-adjacent points, core fractions and row bounds up to400-cell
radii. Existing15,414 full scalar-raster checks and all prior regressions pass.
Real engine:20 full360x340 scratch-grid comparisons (2,448,000 cells), zero changed
cells, and matching modified/shaped counts. Aggregate native raster1202ms ->1087ms
in the scratch probe; this is not a START-to-T1 measurement or cold sign-off.

All60 offline commands/checks pass. Cold reference/five-scenario acceptance pending.

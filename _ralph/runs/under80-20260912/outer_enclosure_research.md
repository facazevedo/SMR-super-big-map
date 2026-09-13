# Exact coarse enclosure research (not deployed)

Accepted production remains v983. This is a genuinely new research candidate,
not a rerun of rejected v984. No startup speedup is established.

The candidate fills the complete f32 coarse grid with integer zero, evaluates a
conservative row enclosure, and retains the exact cell expression and U12 write
inside it. Private dense protection arrays use numeric iteration in the same
order. Full dimensions, sample counts, resampling, support/core restoration,
protected footprints, final blending, placement and RNG remain unchanged.

Qualification requires nonnegative core <= radius <= 65536, patch coordinates
and grid endpoints within [-65536,65536], and sample step 1 or 4. Valid existing
ordered nonempty grid bounds imply every sampled coordinate lies in that range.
Nonqualifying geometry evaluates the full original rectangle. This is domain
selection, not recovery after a native failure. GridFill is a required primitive.

Enclosure rationale for standard binary64 arithmetic: coordinate differences
are at most 131072; squared distance sum is at most 2^35. Integer arithmetic is
exact in these bounds; binary64 coordinate/product/sum errors are much smaller
than 1/16384 in squared distance. Even the conservative absolute square-root
error bound sqrt(1/16384) is 1/128. Radius is inflated by one whole cell, providing
far more clearance than that distance error. For included rows, using this
inflated radius in the row square root encloses the original disk; the additional
two sample steps absorb cancellation/root and endpoint rounding. Outward floor
and ceil widen again. Thus an omitted sample cannot satisfy the predecessor's
distance <= core or distance < radius. It never invokes sine or a guard and
writes exactly zero. The cache's first nonzero evaluation/order is unchanged.
Native arithmetic behavior still requires actual-engine shadow validation.

Offline actual-source whole-block oracle: 800 complete masks, 1,963,334 exact
U12 cells, 264,193 omitted scalar evaluations; zero mismatches. Includes 0/tiny/
large radii, core ratios, absent/present atan2, 0..8 protection factors, zero
protection transitions, negative and out-of-domain coordinates, and unsupported
sample step. This does not establish a real-map gain or replace native tests.

Native shadow clones only PrepareOuterResourceTerrain, joins all original
private upvalue cells, and compares both complete native coarse grids before
resampling. Only the accepted grid reaches actual terrain. Both allocations
are registered with existing patch ownership for cleanup. Timings include the
candidate's required fill, but exclude the per-cell comparison. Running old
then new is diagnostic only, not randomized or a cold acceptance benchmark.
Production promotion still requires native failure/ownership coverage, all
inherited regressions, and frozen reference/control/five-site timing gates.

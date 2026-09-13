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

Reference native shadow CLOSED normally at 824d5a1, session84712/PID7844.
All56 complete coarse grids (948237 U12 cells) match exactly, zero mismatches.
Diagnostic scalar-block totals old2904ms/new2432ms, observed reduction472ms.
Full predecessor snapshots, private streams and individual rock grounding pass;
flushed logs and normal quit captured in artifacts/outer_enclosure_reference_shadow.
This stage timing is not an established end-to-end gain, and by itself is too
small to close the current5.244s reference gap to85.

Full actual apply_native_patch double:51551 checks pass over20 complete patch
outputs, accounting, clipping/alignment, ownership and failure cases. Injected
coarse allocation failure and GridFill errors before/after fill free all owned
grids and publish no terrain/dirty region. Actual required-API list explicitly
rejects missing GridFill. The unchanged subsequent native pipeline is compared
through complete U16 outputs; double circle semantics are only an offline
differential fixture, not a substitute for native full-mask/full-map evidence.

61N136W native shadow CLOSED normally at ec4ca93, session87418/PID40372.
All50 patches/740771 complete U12 cells match exactly. Mask block2402ms->1973ms,
observed429ms reduction. Full predecessor/private-stream/individual-rock parity
passes, flushed logs and normal shutdown captured in artifacts/outer_enclosure_61n_shadow.
Across both native shadows106 masks/1689008 cells are exact. Production has not
changed; no cold performance claim follows from these diagnostic reductions.

Next declared implementation: v985 with this enclosure change alone, generation
guard299/runtime985 and unchanged sector76. Do not silently fold rejectedv984
decor changes into this experiment. Adapt both new actual-source oracles to
compare f4d1da6 with production, retain all80 inherited tests (82 total), preserve
the existing sine-rebinding and source-binding tests, then freeze code/version/
HEAD/deployment before reference3/control. Use v983_confirmation_reference
(90.244s median) as declared comparator. A positive reference result permits
the five-site matrix against v983_matrix; every timing must remain visible.
The experiment is an incremental step toward the full under85 scope, not a
replacement target. Source review and review_v974.py need a v985 entry before
freeze; no v985 production candidate exists yet.

Subsequent production candidate b54df8f/v985 passed all82 offline commands but
FAILED its declared cold gate:91.231/89.371/90.542, median90.542 vs90.244;
control29.317 vs28.532. Exact reference/private/rock evidence PASS, audit issues
empty, all four owned processes closed normally. Production restored to v983;
candidate and tests recoverable in b54df8f. Do not rerun unchanged v985 as a rescue.
The single-function shadow's _ENV-based operand context adds lookup overhead
relative to production's lexical locals; its absolute stage savings were never
an acceptance benchmark. Preserve its exact complete-mask evidence separately
from this negative cold result. Larger bottleneck reductions are still needed.

# Private mask source/domain audit (not a production certificate)

Both full-map execution orders completed at frozen checkpoint 8a5a90e. The
qualification corrections below were implemented afterward; their offline tests
pass. A subsequent captured-cell native replay tests the stricter revision.

## Required qualification corrections

1. `integer()` alone accepts huge floating coordinates. For example x0=cx=1e20
   can lose sample-step increments before subtraction in the scalar source, while
   the native field keeps them. Bound x0/y0 and all patch/guard centers explicitly
   (the existing finite helper's absolute 1048576 limit is ample for current maps).
   With width/height<=4096 and step<=4, all coordinate additions/subtractions then
   remain exact integers. Keep the squared-sum<=2^24 gate.
2. Require finite row.radius and exact equality to
   patch.core_cells + base_transition * 1.35, using the original Lua expression.
   Otherwise the scalar exterior early-out can truncate a nonzero native lobe.
   The generator computes this expression directly; injected/custom callers must
   not bypass the assumption. A conservative refusal must preserve scalar fallback.
3. Optional manual epsilon overrides are research-only and may undercut the derived
   bound. Remove them or reject values below the derived numerator before promotion.

Implemented all three qualifications, plus finite phase and verification of any
supplied harmonic cache against the literal zero-angle expression. Offline huge-
coordinate regression failed before the fix and passes afterward. Remaining
source/primitive proof obligations below are not discharged by these guards.

## Source correspondence to conditional rational bounds

- The scalar angular fallback is exactly zero when atan2 is absent. A cached
  harmonic must come from the same math.sin function and phase; captured/current
  immutable engine math qualifies, but arbitrary supplied cache values do not.
- Scalar base denominator is fl(fl(C+B*w)-C), not simply B*w. C/B<=1 and w>=.5
  bound cancellation amplification: ignoring tiny second-order terms, <=5*u64
  relative deviation. A formal source-double reserve is still needed.
- The scalar branch distance<=C and the clamp-based native formulation coincide
  mathematically. Clamping squared distance to at least one is safe only with
  C>=1 and every guard radius>=1; zero-distance guard interiors remain zero.
- Soft guard source divides by transition+0.0 after its interior/exterior tests.
  The CPU reciprocal, dyadic coefficient encoding and multiplication must be
  bounded against that scalar division (including f64 source rounding and the
  rounded radius+transition exterior threshold).
- Native lower/upper interval construction adds f32 rounding. The unused base4u
  and per-soft-guard1u reserves must be explicitly allocated to this and source
  double/subnormal errors, not merely assumed sufficient from sample agreement.
- Hard-guard integer threshold adjustment uses the actual scalar sqrt predicate.
  Its monotonicity and exact integer coordinate/square premises must hold. Even
  doubled squared sums above 2^24 remain representable (even integers<=2^25).

Native residual perturbation/cleanup tests now pass, but they do not alone prove
all native arithmetic primitives conform to the model used by the rational bounds.

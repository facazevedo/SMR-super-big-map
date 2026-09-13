# Unproven next hypothesis: local quintic sensitivity, not another constant shrink

Current accepted baseline is56fbf44/v987. v990's global tighter bound is exact on
tested inputs and reduces corrections on all sites, but its mixed cold result is
NOT promoted. Do not cold-repeat unchangedv990 or combine rejected variants merely
to hide regressions. This note is an unimplemented hypothesis, not a certificate.

The remaining bound still charges the maximum quintic derivative15/8 everywhere.
For w(t)=1-t^3*(t*(6t-15)+10), |w'(t)|=30*[t*(1-t)]^2 on[0,1]. NativeApronMask
still owns the clamped t grid (radius) after creating the final weight. The consumed
cube grid could potentially hold a conservatively rounded LOCAL mask-error field,
with no extra grid allocation. It would require additional native sweeps/copying;
their cost must be measured against avoided Lua callbacks.

Possible proof route, NOT YET VALIDATED:
- Bound normalized-radius argument variation using the established conditional
  5.6e-6+1.8e-6/c propagation, divided by1-c. Round UP to integer U24 units with
  explicit CPU-f64 allowance; do not accidentally use integer division in engine Lua.
- Account for core quantization/affine arithmetic and q=t*(1-t) computation error
  before enclosing max q over the possible argument interval. q is1-Lipschitz on
  [0,1] and never exceeds1/4. Derive conservative padding, not empirical constants.
- Native q scaling/clamping can use exact U24 integer arguments. Prove outward
  roundoff at EACH operation; include the polynomial/core/U24 reserve separately.
- Propagate the resulting per-cell d through the existing3*min(1,w+d)^2*d cubic
  sensitivity. Explicitly cover new floating operations in the final height
  bracket; do not assume the old four-H reserve has unallocated slack.
- Retain literal mask generation, scalar fallback, patch order, every existing
  numeric/residual/failure/census guard and cleanup. A returned error grid must
  remain owned until use, with no extra ownership or partial-publication hazard.

Potential reuse: cube is no longer needed after polynomial*=cube. Copying the
still-live t field into it would be fractional f32-to-f32 copyrect, whose storage
semantics were natively verified previously. Inspect that evidence and the actual
current source. A full native local-error oracle, both-order complete raster
shadows, all boundary/failure tests and actual cold gates would still be required.

First derive a rigorous local envelope and estimate correction reduction versus
the required extra sweeps in private tests. Reject the idea if added native cost
outweighs its benefit. The full startup goal remains across all six maps; this
cannot be advertised as a complete solution from narrow helper measurements.

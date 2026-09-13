# Private per-cell apron sensitivity certificate

Accepted production remains exact56fbf44/v987. Rejected v990 is not promoted or
repeated. This is a genuinely new per-cell derivative field, reusing the consumed
native cube scratch; no new allocation or weight-generation operation is added.
Seven grid passes (copy, complement, product, padded scale, clamp, square, final
scale) are added. Their cost versus avoided callbacks requires native measurement.

## Conditional derivation

Use the SAME qualified Q22 coordinate, root/reciprocal residual, regular-f32 and
scalar-f64 contracts as v987. The rational v990 propagation is retained as a
lemma: normalized-radius error <5.6e-6+1.8e-6/c. Core quantization and the native
affine ramp add <6 U24 units to t. The scalar polynomial arithmetic is separately
included in the remainder. No measured error is used as an accuracy guarantee.

With W=2^24 and c in[.2,.75], compute
d=floor(((5.6e-6+1.8e-6/c)/(1-c))*W+6)+2. CPU division is explicitly floating.
Convex endpoint bounds and generous CPU-f64 rounding reserve prove d<600 and
that d/W encloses total t variation, including the affine/core error.

For P(t)=t^3*(t*(6t-15)+10), |P'(t)|=30*q(t)^2, q=t*(1-t). On[0,1], q is
1-Lipschitz and <=1/4. Native qhat uses two regular operations with absolute error
<1 U24 unit. Q=clamp(fl(qhat*W+d+2),0,W/4) encloses every possible q in the t
interval: padding2 exceeds q-computation plus addition error. Clipping is safe
because exact q never exceeds1/4. Scaling/dividing by W is exact dyadic arithmetic.

Compute E3=fl(fl(Q*Q/W)*(90*d)/W+240). This represents THREE times the per-cell
weight allowance. All API arguments are exact f32 integers. Two product roundings
and final addition cost <.001 U24 unit. Native polynomial/complement/U24 and
scalar arithmetic need <64 units (rational result62.500017). Reserving80 units
leaves >15 units after field rounding for downstream arithmetic.

Upper weight uses GridAddMulDiv(mask,E3,1,3), allowing both reciprocal/product
roundings plus addition. Its downward error <2 U24 units is covered explicitly.
Thus its clamped value encloses min(1,w+analytic_error). The sensitivity square
and two displacement/coefficient products lose at most three relative-f32 units;
the >15-unit coefficient padding dominates that loss throughout error<=1206 units.
Tiny underflow/FTZ terms get ONE NEW H-unit final margin. The inherited four-H
plane/blend reserve is not silently repurposed. Mask, plane, blend, scalar
correction, callback census, publication order and cleanup remain unchanged.

The new field allowance is <1206 U24 units, below the smallest old global1280.
Original bracket-application magnitudes therefore do not grow. Domain-rejected
scalar masks retain their exact old coefficient operations and old +4 margin.
Missing local field fails explicitly; the third return remains owned by the
existing scratch owner until final cleanup. No partial scratch is published.

## Initial offline evidence

apron_local_offline: five initial checks PASS. apron_local_checks: eight complete
pre-native checks PASS, including a widened reciprocal/product allowance in the
proof. 58905 three-way U16 cells exactly match acceptedv987 and literalv958 scalar;
39 cases reduce callbacks, none increase, totals7884->6979 including the new +1 H.
All modified/shaped/raster/native/scalar patch censuses match; scalar fallback
correction counts match. 221 inherited allocation/clone/corrupt-power/census/
ownership checks PASS, plus exact-span/corner/radius boundary checks.

An independent scalar oracle extracts the ACTUAL polynomial plus local-field
block. It checks both monotone scalar interval endpoints for74016 normalized
values across12 cores (148032 endpoints), with floor-positive allowance readback
so no fractional native getter assumption enters. Offline minimum slack67 U24,
max observed difference1008.507849, max allowance1100. These observations are
tests, NOT the mathematical proof. Native confirmation is still required.

The candidate manifest records six exact replacements; reversing them reconstructs
the entire accepted source byte-for-byte. Production Code/metadata/items are
unchanged. New setup scripts preserve the audited shadow ownership/restoration
workflow: accepted raster always supplies actual game terrain, candidate runs
only on a scratch clone, complete67108864 U16 cells compared in both orders.
The new oracle runs before wrapper installation with explicit failure latches.
No cold startup gain, production acceptance or target completion is claimed.

The additional injected-failure fixture passes126 ownership/abort checks over
all seven new copy/arithmetic operations. apron_local_checks_2 is the final
nine-command replay including this fixture; older five/eight-command artifacts
are preserved, not overwritten or relabeled.

## Real-engine forward/reverse CLOSED PASS

Frozen86fff28, production still56fbf44/v987,38-file deployment auditPASS before
both launches. Forward exec60912/PID39000 and reverse exec48075/PID49524 CLOSED
normally; full logs flushed and fresh-game check clear. Both private_process_audit
files PASS: four private-stream fields, predecessor/full-grid/rock parity, loaded
v987/incident identity, normal engine+daemon shutdown, no error signatures, scratch
cleanup and original wrapper/scheduled-rebuild hook restored. No live process.

Each ACTUAL native local block passes148032 scalar interval endpoint checks over
74016 weight cells. Minimum observed slack66.779437492 U24 units; max difference
1008.507849012, max allowance1100. This confirms sampled native behavior under the
conditional proof; it does not replace the proof or establish a universal domain
claim from samples.

Each complete raster comparison covers67108864 U16 cells, with difference
minimum/maximum/count all0. Actual reference core=.2. Coverage5039674, modified
1910302, shaped50, native patches50 and scalar patches0 are unchanged. Scalar
corrections396398->256451,139947 fewer, in BOTH execution orders. The extra seven
native passes and separate +1 H reserve are included in the measured candidate.

Forward old1879/new1238ms (641ms saving); reverse old1893/new1228ms (665ms saving).
These are isolated instrumented helper timings, NOT cold START-to-T1 results and
not evidence that the full all-site target is reached. No production promotion.

Next: stage only this exact native-shadowed candidate plus version identifiers,
adapt legacy coefficient-specific fixtures without dropping any original cases,
and replay the complete actual-production suite plus all new local proof/oracle/
source/failure checks. Source review must cover the six declared replacements,
conditional premises, unchanged scalar fallback and every preserved terrain/RNG/
rock/bootstrap/rebuild/T1 requirement. Then commit/freeze/deploy and run the
reference3/control gate againstv987_reference, followed only on full correctness
and a strictly improved reference median by five declaredv987_matrix comparisons.
Preserve all samples and failures. Do not treat helper gains as cold acceptance,
repeat unchanged rejected variants, combine them to conceal regressions, or relabel
the accepted baseline. Accepted reference86.606s/worst61N92.125s remain authoritative.

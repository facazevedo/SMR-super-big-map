# Unimplemented: tighten only the already-proved rounding bracket

The accepted native mask proof gives

    E(c) = 1.875*(12e-6 + 7e-6/c)/(1-c) + 16e-6.

v977/v978 currently use1/4096 for every qualified core fraction. The documented
bound is convex. On the smaller interval c in[0.25,0.55], its endpoint values
are116e-6 and approximately119.030304e-6, both below1/8192=122.0703125e-6.
Thus an optional narrower bracket on ONLY that subdomain follows from the existing
proof, without changing coordinate construction, powers, residual checks, native
mask, scalar oracle or final blend. The ordinary4/12 core fraction lies inside it.
All other fractions would retain1/4096. This does not establish any timing gain.

If measured useful, choose an integer power-of-two denominator per patch, then
use the SAME denominator for both the upper-weight delta and cubic sensitivity
term. The current native API arguments require integers: do not pass a fractional
epsilon. The existing four-H-unit native arithmetic reserve stays unchanged.
Exact final U16 comparison, endpoint/domain tests and fresh full predecessor
outputs remain mandatory. Do not substitute observed small sample errors for the
proof or merely shrink a safety margin until tests pass.

No code or test has been changed for this idea. Prioritize the prepared whole-
pipeline function profile after v978 acceptance; it may identify a larger saving.
Read-only engine source inspection also found GridTypeFmtItems/ToFmt expose only
float32, uint16 and uint8 (CommonLua/Classes/PerlinNoise.lua:6-17). There is no
established float64 compute-grid API here; GPU double support alone proves nothing
about this CPU/native grid interface. No float64 probe or binary edit was made.

After v979 acceptance, a NONDEPLOYED generator and exact-rational bound test ran.
Artifacts/apron_bracket_research holds the fingerprinted candidate: same mask and
scalar oracle, error divisor8192/4096 and exact U24 allowance2048/4096 selected
consistently. The proof also checks the exact binary representation of0.55.
apron_bracket_native.lua adds33 native three-way fixtures around both narrowed
domain endpoints; apron_bracket_shadow.lua compares the complete fresh height
grid. Both parse but have NOT executed. No timing saving or native parity yet.

## Native scratch follow-up

First apron_bracket_native_reference FAILED:523776 comparisons,4647 mismatches;
PID8600 closed normally. Preserve that red result. Its boundary fixtures used
2^-30 and1/3 as if the runtime were ordinary float-first Lua. The corrected probe
explicitly measured this engine's integer semantics:2^-30==1 and1/3==0, while
1.0/3.0==0.3333333333333333. Thus several first-run cores were not near the intended
boundaries at all (e.g.0.25+1, not0.25+2^-30).

apron_bracket_native_float_reference uses an explicit exact floating epsilon and
floating division, records every actual core, and distinguishes old-vs-scalar,
new-vs-scalar and new-vs-old mismatches. All523776 comparisons PASS across33 cases,
all three mismatch categories zero; PID47608 normally closed. No production code
was changed to fix this fixture. Ordinary policy core1/3 must be represented using
floating operands in game probes. A full native shadow run is still required
before any performance conclusion or promotion.

## Full shadow: exact, but no demonstrated work reduction

apron_bracket_shadow_reference completed at f8d0c50 / accepted v979. PID45896
normally closed; full8192x8192 height comparison and full predecessor/rocks/private
outputs PASS. Candidate2781ms versus accepted3313ms is NOT evidence of a useful
change: BOTH execute808696 exact correction callbacks with identical counters,
5039674 native mask cells,50 shaped patches and1910302 modified cells.

The earlier assumption of an ordinary4/12 core is WITHDRAWN. That is only the
terrain helper's fallback. sbm_config.lua defaults core4 and feather20, hence0.20,
outside the narrower[0.25,0.55] branch. The shadow did not record its actual policy
value; do not fabricate one, but the source default and identical counters mean
there is no demonstrated exercised optimization. Do not promote this candidate
or credit its532ms order/timing difference. Future shadow setups MUST record the
actual policy and branch constants, alongside corrections and full exact output.

An alternative arithmetic proposal, NOT implemented: on the already qualified
core domain[0.20,0.75], the existing envelope is below3/16384 everywhere (maximum
176e-6 versus183.10546875e-6). On[0.20,0.60], endpoint maxima are126.157e-6 and
126.938e-6, both below9/65536=137.3291015625e-6. Convexity is unchanged. Thus choose
error numerator9 up to0.60 and12 above it, denominator65536: U24 upper-weight
allowance2304/3072 and cubic sensitivity numerator27/36 over65536. Both native
arguments stay integral, no Lua negative powers/division ambiguity, and the4H
reserve remains. This covers the source default without changing the mask/oracle.
Require exact-rational checks, revised endpoint native fixtures, actual-policy
full shadow evidence and measured useful work reduction before any promotion.

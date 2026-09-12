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

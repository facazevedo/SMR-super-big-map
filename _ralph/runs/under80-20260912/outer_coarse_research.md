# Outer coarse-mask census

Accepted production remains v979/c4d3e67 after rejecting v981's slower cold
median. New diagnostic outer_coarse_profile_reference runs at restore1c14803,
with only one recompiled PrepareOuterResourceTerrain function and all original
upvalue cells joined. No module reload, terrain algorithm change, new RNG call,
quota cut, removal of rebuilds or work moved after T1.

Native diagnostic97735/PID7060 closed normally and passes full predecessor
surface/underground terrain/pass grids/placements/private-stream/individual-rock
parity. All56 patch sample censuses match the production report:

* helper3771ms; sum patch totals3363ms, including coarse loops2675ms and
  pre-coarse289ms. Timings include instrumentation and are not cold results.
* 948237 coarse samples produce15007032 full-resolution raster cells.
* 508958 samples have exact zero weight before protection;513213 afterward.
* 223421 lie outside the existing maximum-radius disk;12880 finish at exact one,
  and422144 retain a transition weight.

This identifies a larger Lua cost than native patch arithmetic. About54% of the
coarse samples are already provably zero in the existing calculation, but the
current loop still visits and sets them individually. A future exact-zero bound
may avoid some visits after explicit native initialization, without changing
grid dimensions/resampling, gameplay cores/protection, scalar nonzero weights or
quantization. Mere observed zeros are not a certificate: bounds must follow the
actual arithmetic, cover floating-point/domain limits and custom-function guards,
and retain every possible nonzero cell. No such candidate is implemented yet.

An alternative is a separately proved native coarse-mask kernel with exact
integer-weight correction at rounding boundaries. Existing apron certificates
cannot simply be reused: this mask has a different directional-width formula
and multiplicative protected-site blends. Require a fresh proof/native oracle,
not empirical shrinking of margins. No candidate or claimed speed gain exists.

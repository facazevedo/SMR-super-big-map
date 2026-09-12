# Next independent hypothesis: exact coarse outer masks

Pending v977 acceptance. Production/HEAD/deployment must remain unchanged during
its live cold batch. Do not launch a second game. This is research, not acceptance.

The old function profile counted2134236 sine calls in the outer raster and1228244
ProtectedTerrainBlendWeight calls. v975 removed surrounding global lookups; it did
not remove these evaluations. The original coarse mask uses sample_step4 and
rounds to4096 before native resampling. Any future port must preserve those exact
coarse integer cells, not merely similar final terrain.

Possible native approximation: for unit direction z=ux+i*uy, form z^2,z^3,z^5,z^7
with small complex multiplications. Then sin(n*atan2(dy,dx)+phase) equals the
imaginary part of z^n times the phase rotation. Compute the six phase sine/cosine
coefficients once per patch, rather than three sines at every transition cell.
`outer_harmonic_research.lua` is an untested native-grid prototype. It does not
touch production. It deliberately does NOT rely on native GridSin approximation.

Requirements before use: compare with actual engine math.atan2/math.sin including
axis/quadrant boundaries and all bounded phases; certify coordinate/root/reciprocal
and complex-power error, then correct every ambiguous final U12 rounded mask cell
with the literal predecessor expression. Preserve term/sign order in the oracle.
The engine's integer division may make patch.phase integral: preserve actual
inputs rather than recreating phase with host-language division. If math.atan2
is absent, the old code uses angle0; this must retain its exact scalar path.

Protection factors remain essential. Their product has absolute error bounded by
the sum of factor errors because each factor is in[0,1]. Zero-width transitions
have discontinuous membership and require exact classification/correction, not
a smooth derivative bound. Small positive gaps also need a conservative bracket.
Do not drop protection loops, alter exact cores, enlarge patches or change native
resampling/final height blending. First test harmonic error and cost, then select
a bounded port based on evidence; do not assume this will save enough to reach80s.

## Disconfirming engine evidence: angle fallback is active

`outer_harmonic_probe_1` failed before comparisons because global math.atan2 is nil;
the captured engine log and normal shutdown are preserved. Do NOT paper over
this by changing the oracle to use math.atan(y,x): that would test a different map.

`math_library_probe` confirms the mod sees the SAME math table: both global and
mod math.atan2 are nil; math.atan exists; math.sin is the same native C function.
Therefore the shipped scalar outer raster uses angle0 on this engine. Its three
sine terms are constant for each patch, even though they are reevaluated at every
transition sample. The proposed geometric complex-power field would NOT preserve
this behavior unless disabled on this engine, making it useless for the current
benchmark. Do not implement that hypothesis as a production speedup.

Next exact candidate: cache the literal three-term harmonic for angle0 within one
patch, keyed by the current sine function, retaining the unchanged literal path
for nonzero angles or changed function bindings. No replacement of missing atan2,
no new angle calculation, no shape redesign. First compare literal masked output
and library-rebinding behavior offline, then measure in a fresh diagnostic after
v977 acceptance closes. A later fully native outer mask can specialize the
actually constant angular term, but must still preserve exact U12 masks and
protected-site factors. v977 itself is unchanged; five-site validation is running.

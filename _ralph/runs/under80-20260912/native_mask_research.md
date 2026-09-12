# Native apron-mask research (not deployed)

Continuation after restoring v975. The previous goal turn made progress: two
validated optimizations and evidence rejecting a marginal third. Current
production remains exactly accepted v975 (`1f67811`), HEAD `c33ab73` at research
start, clean worktree and no game process. Goal remains under80s on reference and
all five scenarios; current97.914s is not completion.

## New evidence

- `grid_math_probe_1`: deliberately tested fractional native arguments; the engine
  logged Expected integer. Captured normal shutdown. Do not treat its returned
  Lua `status=pass` as success; the driver correctly failed on the flushed log.
- `grid_math_probe_2`: integer fixed-point inputs and scaled readback pass. f32
  `GridPow(g,-1,1)` produces reciprocal; `(1,2)` produces square root. Native
  `GridMulDivAdd` rejects fractional arguments, and ordinary get/min/max truncate
  fractional outputs. Multiply a clone by1,000,000 before measurement. Trig was
  also probed but is NOT needed by the current polynomial mask prototype.
- `native_mask_probe_1`: 211848 full native mask samples at24 rotations/radii/core
  fractions. Max absolute U24 mask-code difference67, about0.000004. This is an
  empirical observation, not a universal bound or permission to publish the mask.
- `native_apron_probe_1`: 317440 complete U16 cells across20 cases, comparing the
  literal v958 scalar raster, accepted v975 native blend and new research blend.
  Zero cell/census mismatches. Includes near-zero/cap, slopes, noisy full-height
  range, overlapping patches and no-edit candidates. Low-relief cases often2–4ms
  versus accepted9–11ms; worst high-relief cases11–12ms versus12–13ms. These tiny
  scratch measurements are NOT end-to-end cold acceptance.

## Prototype

`native_apron_mask.lua` generates rotated coordinate planes from fixed-point corner
seeds, computes radius and normalized axes, then the original lobe polynomial and
quintic using f32 grid operations. It does not replace the exact scalar formula
used for ambiguous final-height corrections. The non-deployed generator is
`apron_mask_candidate.py`; artifact `native_mask_research/terrain_candidate.lua`.

An exploratory |weight error| <=1/4096 bracket uses local cubic sensitivity:
`3 * min(1, approximate_weight + 1/4096)^2 /4096`. Multiply by the local absolute
height displacement, add the accepted native blend/plane rounding bracket, then
compare rounded lower/upper grids. Any ambiguous cell uses the literal scalar
formula. **The mask error bound is not yet proved for the complete permitted
input/native arithmetic domain. Do not promote this code on samples alone.**

Required next: derive a conservative bound with explicit coordinate/core/norm
domain checks (or retain exact scalar calculation outside that domain), test
native square-root/reciprocal error over the needed range, allocation/enumeration
failure paths and offline regression. Remove unnecessary temporary mask allocation
only after correctness is fixed. Production API needs GridPow explicitly supplied.
The generator currently changes only an extracted raster for diagnostics; it is
not ready for deployment or a version bump.

`native_mask_shadow.lua` installs one fresh-process diagnostic wrapper at the
captured RasterNaturalMountainBaseAprons upvalue. Runs candidate and predecessor
on identical grids, compares every full-grid U16 cell through exact native
subtraction/count, and returns predecessor reports. On mismatch it restores the
accepted grid and marks the diagnostic failed. Full START-to-T1 includes duplicate
work and must NEVER enter benchmark rankings. Separate stage timings are useful.

## Reference shadow result

`native_mask_shadow_reference` passed: native candidate2663ms versus accepted7591ms
(4928ms less in this diagnostic stage). Exactly zero differing cells over the full
8192x8192 height grid; modified1910302/shaped50 censuses match. Candidate performs
808649 scalar corrections versus accepted147549, out of5039674 patch cells. The
extra correction cost is still much smaller than3650626 scalar mask evaluations.
Full predecessor snapshots/private streams/individual rocks match, and the fresh
owned process closed normally. This is NOT a cold median; do not subtract4928ms
from accepted97.914s and claim a measured total. Need full candidate acceptance.

`apron_mask_offline.lua` runs the unchanged native apron regression against this
candidate with a research-only GridPow extension to the existing f32 double:
15414 checks pass, including missing API/allocation/lost-callback handling. The
new helper's own additional allocation paths still need explicit failure guards
before production. Mask sample/skipped statistics currently describe scalar work,
not total native work; make these counters unambiguous before shipping.

Next turn: establish a defensible error bound and input-domain certificate; verify
the native reciprocal/sqrt accuracy assumptions and boundary cases. Then integrate
an isolated production unit with new guard292/runtime977, complete all offline
regressions, commit/deploy/audit, and run fresh three-reference/control plus five
scenario acceptance. Keep any hypotheses about total runtime separate from proof.

# v964 outer-resource mask source/RNG and process review

Production delta only reorders the existing coarse-mask arithmetic around exact
constant regions. The support radius is computed by the same expression as the
maximum possible angular outer radius (same clamped upper bound1.35). At distance
<=core the original weight is exactly1; at distance>=radius it is exactly0.
All transition expressions, their order, native mask dimensions, grid resampling,
integer rounding, protection/core enforcement and patch order remain unchanged.
Protection multiplication can stop at exact zero; all configured inputs are finite.
No terrain/placement decision, RNG call, gameplay gate, rock or rebuild is changed.
Temporary buttons unchanged. New regression fails its work-reduction assertion on
8342ab2, then passes387829 comparisons with1163484->556308 sine calls. All61 offline
checks pass. Full game acceptance now passes: three reference pairs/repeats and
all five scenario predecessor snapshots, all eight automated gates, unchanged
ordinary/private RNG streams and unchanged rock grounding. No new randomness or
scenario logic exists in this delta. Nine accepted processes used the committed,
audited candidate and exited normally. Separate source/process review completes
the two manual gates; raw judge pending fields remain untouched.

Reference114.512/115.056/112.249s gives median114.512s against114.612s. This observed
0.100s difference lies within run variation: no substantial or statistically robust
speedup is claimed. Fifteen-south and24S/17S single samples were slower;45S/61N were
faster. Actual scalar work reduction is independently exact and measured, but its
contribution to end-to-end loading is small. Fresh native control29.451s.
The first15S shutdown timeout is preserved and excluded. A complete fresh five-site
retry passed normal shutdown and all preservation gates. Accepted visuals are
inherited only through exact full outputs; no new screenshot claim.

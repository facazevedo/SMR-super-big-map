# v964 outer-resource mask review - candidate, cold acceptance pending

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
checks pass. Full game acceptance and source/process sign-off are pending.

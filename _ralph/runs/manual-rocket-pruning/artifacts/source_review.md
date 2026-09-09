# v961 exact rocket score pruning — source review

Baseline production: 2e2676c (v960). Scope: only candidate scoring and its incumbent
argument in PrepareOuterResourceTerrain, plus diagnostic counters/version metadata.
No source/RNG/seed, placement quota, terrain write, entrance, decoration, apron,
crease repair, native control or temporary-button implementation is changed.

## Proof of selection equivalence

Original score is `bias + range * 100 + distance`, where bias is -1000000000 for a
ready footprint and 0 otherwise. Distance and range are nonnegative. Before live
readiness is known, `-1000000000 + distance` is a lower bound. After the original
readiness predicate, `bias + distance` is a stronger lower bound. During the
ordered footprint walk, each partial range is a lower bound on the full range.
The progressive bound uses the original expression's arithmetic order.

Reject only when the bound is >= the incumbent score. The original strict `<`
replacement cannot select such a candidate, including equality/ties. First
candidates (no incumbent) use the full original path. The exhaustive disk and
lexicographic dq/dr traversal, group order, live inter-pad clearance, resource
clearance and footprint predicates are unchanged. Each new group resets its best.
The passed distance is the exact dq/dr expression used by the original axial
distance helper; integer group centers make them identical, including negatives.

Readiness is moved before footprint height completion only when an incumbent
exists. It is NOT cached or approximated: `rocket_shape_ready` calls the unchanged
`exact_offsets_ready`, with native passability and BuildableGrid:GetZ reads. The
shipped BuildableGrid.lua:98 getter is only a grid lookup. These reads neither
yield nor mutate terrain, objects or random streams. Planning accumulates patch
descriptors; terrain writes occur only after all groups are selected. Height
cache lifetime and fail-closed winning-center certificate remain unchanged.
Skipping a missing-height candidate before discovering the missing sample is safe:
it already cannot beat the incumbent; every returned candidate completes the
original height/eligibility checks. Nil and zero are distinguished as before.

There is no candidate limit, search reordering, tolerance, approximate score,
scenario-specific case, deferred required work, fallback or removed validation.
Counters are diagnostic only; completed candidates and pruned candidates are now
counted separately. No new gameplay dependency or engine API is introduced.

## Regression evidence

New test executes the actual production block against immutable v960 and compares
the best candidate after EVERY traversal prefix, then every winning metadata field
after the unchanged relief finalizer. Ten map fixtures/four groups cover negative
hexes, rounded world coordinates, map-edge exclusion, nil coordinates and
heights, zero/max-U16 heights, all-ready/all-unready/mixed readiness, ties, live pad
exclusions, no-incumbent compatibility and progressive early stopping.

The old code fails the explicit equal-bound pruning test (pruning_before.json).
New code passes 655,454 assertions. The preexisting v958 sampling regression also
passes all 81,267 assertions, including stale-cache rejection and fresh epochs.
Full offline and five-site runtime acceptance are recorded separately; this source
review alone does not certify performance or runtime rules.

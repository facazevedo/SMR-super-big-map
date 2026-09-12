# v974 decor index source/RNG review

Checkpoint 2c68ff3 changes only the local circle query and DecorTopUp.VERSION in
production code, plus metadata version/release notes. The map-generation guard
remains 288: no generator closures changed. All other production modules are
literal accepted v972 content.

The two indexed arrays are created inside DecorTopUp.Run. Their circle coordinates
and radii are populated before queries, then new circles are appended after a
successful stamp. No existing circle is moved, resized, removed or reordered.
All consumers use numeric indexes, array length or ipairs; the new spatial_index
field cannot enter a census or ordered traversal. Indexes die with this Run.

Circle bounding boxes populate spatial buckets. Queries cover the candidate's
bounding box, deduplicate encountered circle references, and evaluate the same
strict squared-distance comparison. A query returns only a boolean: the identity
or order of intersecting obstacles is not externally observed. Newly appended
circles are indexed before the next query, including additions after early hits.

Matcher/no-match precedence and obstruct-before-decorated precedence are unchanged.
The complete try_stamp body, candidate generation, finite coverage, template
widening, weighted selection, stream implementation and all random call sites are
unchanged. There are no shared engine-RNG draws in the new helper. The extended
stamping oracle compares exact outcomes, placements, weights and RNG traces against
the literal old exhaustive circle predicate. The focused oracle covers 48,171
queries with tangencies, bucket boundaries, negative/fractional coordinates, varied
radii and live appends. All 71 retained/focused regression commands pass.

Terrain shaping, resource/pad planning, grounding, entrance placement and visuals,
rebuild timing and T1 readiness are unchanged. Temporary buttons remain. Full
runtime parity must still be established separately on each validation map; source
review is not a performance sign-off. Accepted visuals may be inherited only where
complete terrain/placement/rock outputs match, with no claim of new screenshots.

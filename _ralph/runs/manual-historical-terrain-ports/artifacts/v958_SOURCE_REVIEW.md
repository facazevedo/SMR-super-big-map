# v958 rocket sampling source review

Reviewed production delta `9982d4b..1159341`. This review covers the code; it is not
by itself the five-scenario runtime sign-off.

- Only rocket planning in `PrepareOuterResourceTerrain`, metadata958 and the
  generator reload guard274 change. No resource-placement, object-grounding,
  terrain-raster, apron, crease, entrance, passability, UI or temporary-button
  implementation changes.
- The original exhaustive cluster and candidate traversal, exact footprint,
  clearance/spacing tests, live readiness test, ready preference, score formula
  and strict `<` winner update are retained. No bounded planner or historical
  central no-write rectangle was copied.
- `add_patch` gathers descriptors and height samples; it performs no grid write.
  All grid rasterization/publication follows completion of rocket selection.
  Thus height reads and HexToWorld conversions are static throughout this cache's
  lifetime. The cache belongs to one function invocation, not a map/save/global;
  each bounded terrain-repair retry starts with an empty cache. Completed pad
  records retain no cache closure. False sentinels preserve missing samples and
  numeric zero remains valid.
- No dynamic obstruction, clearance, separation or buildable verdict is cached.
  New pads still affect the next candidate's live separation test immediately.
- The original relief loop contributes only `mountain`, `maximum_rise` and
  `higher_samples`; none enters eligibility or the score. The same eight ordered
  coordinates, rounding/clamping and rise threshold are applied to each final
  winner before its descriptor is published. A direct winner-center read must
  equal the cached center. A mismatch records `OptimizationFailure`, releases the
  private grid when owned, and returns before any new terrain raster/write. There
  is no silent eager fallback and no reliance on engine `assert()` throwing.
- No RNG call, seed derivation, reservation, source lifecycle or native-mod patch
  changes. No new candidate enumeration based on hash-table iteration. Existing
  height bounds, wall/spike joins, top-up blending and selective rock lowering
  remain byte-for-byte unchanged.

The new production-block regression compares every candidate and final winner
with the exact v957 scorer across missing/zero samples, rounded oblique world
coordinates, ties, live pad exclusion and multiple cache epochs. A changed center
must be rejected. It demonstrated missing deferral before the port and now passes
81,267 assertions; read/conversion counts must fall by more than80% in the fixtures.
All54 previously accepted offline commands also pass.

Fresh 14N A/B/C match the predecessor's complete Surface/Underground serialized
height/pass grids, sites/pads and corrected-rock transforms, and ordinary/private
stream outputs. This permits inheriting the accepted terrain/rock visual review
for that exact output, rather than claiming an uninspected image is green. The
five fixed scenarios must meet the same strict predecessor comparison before
their prior visual acceptance can be inherited.

Verification uses new cold counterparts pinned to each accepted v957 run's actual
underground seed. The unchanged unexpanded path's five accepted native controls
are reused, with a new 14N native control for this payload. These controls compare
authored reveal/imprint behavior, not generated underground content (native does
not consume the mod's seed pin). The benchmark stopwatch remains after NewGame,
immediately before START action body, ending only after both surface completion
and post-pipeline revalidation. All counters/snapshots are captured afterward.

# v957 selective rock grounding: source review

Reviewed production delta 26f691c..9982d4b. This is a correctness repair, not
another optimization strategy. Ralph remains stopped. No delegated review was used.

## Scope and geometry

- The new module uses the existing skip/important-object/scale predicates, then
  requires StonesRocksCliffs entity metadata with Rock material and no parent.
  Buildings, units, deposits, anomalies, mystery and underground-access content
  remain excluded. There are no scenario names, sector IDs, coordinates or seed
  exceptions in production.
- Capture occurs inside the existing pre-transform object census. The direct
  transfer path reads ground height from its untouched temporary source, while
  mesh-local offsets use the transferred object's visual origin. This distinction
  preserves terrain-glued objects as well as explicit-Z objects.
- Only originally supported uphill mesh-bottom samples are retained. Both native
  and expanded terrain queries are clipped to their physical domains. A mesh
  growing proportionally with terrain Z, scale quantization alone, an already
  supported rock, or a gap no larger than one height tile does not trigger a move.
- After the existing XY/relief/scale transform, a proven support loss triggers
  downward seating. Additional underside seating is bounded by that rock's
  native top-above-pivot times the mesh/terrain Z-factor difference. The native
  support requirement is still mandatory, and the extra cap is not a fixed drop.
- The only geometry setter added is SetPos with identical XY and decreased Z.
  Actual position is checked and rolled back on disagreement. Scale, angle and
  axis are not changed by this module. Capture records are consumed once and
  released with the existing per-map relief cleanup; they are not a saved-map
  re-grounding loop.

## Prior behavior and failure handling

The existing private RNG streams, top-up planner and validators, scale rules,
crease/edge repair, relief offset, temporary buttons, object caching and batched
passability rebuild are unchanged. No random call or terrain-grid write was
added. Per-object ray intersection reads that object, not a world-object search,
so the grounding calculation does not depend on neighboring iteration order.
Grounding runs inside the existing pass-edit batch before the authoritative
rebuild; moving collidable rocks can legitimately change passability and the
inputs to later native entrance/buildable processing.

Capture/apply errors feed explicit grounding failure counters and the existing
OptimizationFailure state/UI/log. They cannot silently count as successful rule
evidence. BeginCapture uses normal engine map/const APIs; the live five-map
workflow tests those prerequisites separately from the mocked offline fixtures.

This is ordinary Lua mod code loaded through metadata.lua and items.lua. No DLL,
native executable patch, altered height limit, or Planet Dawn helper is installed.
Live testing uses MarsDebug through the established harness; it is not a separate
retail-executable compatibility certification.

## Verification boundaries

All 54 offline commands pass on v957, including 30 new production-module grounding
assertions: exclusions, unchanged transform/terrain, proportional-Z no-op,
sub-tile no-op, per-rock scale, native overhang, missing mesh hit, changed pose,
direct-source terrain-glued origin, geometric extra cap, clipped bounds, repeated
application, cleanup and disabled mode.

Final runtime requirements remain exact A/B geometry and full grids, the ten
standing rules, fresh-process/deployment/log provenance, unexpanded controls,
sampled visual comparisons, and the final G3 reproduction. Source review alone
does not certify those requirements or every future scenario. The inherited
missing-seed RNG fallback qualification in the v955 source review still applies.

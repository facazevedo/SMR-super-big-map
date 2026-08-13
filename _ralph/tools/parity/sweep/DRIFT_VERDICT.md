# Surface "decoration drift" — verdict: NOT a mod defect

The ten-map sweep showed 6–31 unmatched surface decorations on cases 01/02/05/07/09
(e.g. `StonesRedSmall_01 1306->1316`, `RocksSlate_04 156->157`) while 03/08 were clean.
Investigated 2026-08-13 at the worst case, sweep-07 (45S82E, lat=2700 lon=4920).

## Experiments (all headless, fresh process each, dumps in `../out/`)

| run | what | outcome |
|-----|------|---------|
| `sw07v` vs `d7v2` | stock vanilla, twice, identical inputs | **differ by 34 rows** — vanilla is non-deterministic on this map |
| `d7v3` (serial raster) vs `sw07v` | serialized vanilla vs parallel run 1 | **byte-identical** — serialization pins one of the same outcomes |
| `sw07e` vs `d7e2` | expanded twin, twice, same injected seed | **byte-identical** — the mod's pipeline is deterministic |
| `sw03v` vs `d3v2` | vanilla twice on a CLEAN map (33S163E) | **byte-identical** — clean maps have no race |

## Composition proof

The vanilla-vs-vanilla wobble at 45S82E is the same population as the sweep's
"drift": slate stones clustered at ~(211056,169078) (drift cluster: ~(210625,168717)),
plus the downstream cascade — ParSystem carriers, SurfaceDepositMetals, SafariSight and
even the passage pair move, because the contested stones change obstruction queries for
every later placement. Vanilla run 2 drew exactly the variant the expanded map carries.

## Cause

Stock parallel prefab rasterization shares the placement-mark grid used by
`Proc_RemoveOverlappedObjects`; on maps with contested prefab sites, task completion
order picks the overlap winner (the race documented in `sbm_map_generation.lua`'s
serialization comment). Each vanilla run samples one of a small set of valid outcomes.
The expanded pipeline serializes rasterization for its source capture, so it always
produces the same valid draw. An independent vanilla control may draw another.

## Consequences for measurement

- A bijection gate against an independent vanilla control CANNOT be exactly green on a
  contested map, for any mod behavior whatsoever. The gate is measuring vanilla's own
  race, not the mod.
- Verdict rule for sweeps: when expanded-vs-control shows unmatched content, run the
  vanilla control twice; the case passes if the expanded diff composition and magnitude
  is within the control's own run-to-run wobble (same contested clusters, same cascade
  classes). Cases 03/08 need no such allowance (zero wobble, zero content diff besides
  the intentional `TerrainDepositConcrete` imprint relocation).
- The mod is strictly MORE deterministic than vanilla: same seed -> same expanded map,
  byte-for-byte, even where vanilla wobbles.

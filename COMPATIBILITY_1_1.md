# Surviving Mars Relaunched 1.1 compatibility investigation

Status: **Lua-only compatibility solution implemented and runtime-validated**
on 1.1.0.403908 for new expanded games and saves created with this candidate.
Both surface and underground retain full 8192 x 8192 terrain with zero artificial
pass border. No native helper, executable patch, reduced terrain, or changed
rock-grounding rules are required. The under-85-second target is paused.

Validation used the installed, unmodified debug executable. The retail allocator
was also inspected read-only, but a retail end-to-end run, long-running colony
soak, every landing site, and migration of pre-update expanded saves have not been
verified. Start a new expanded game for this compatibility version. Passing these
tests is not a guarantee against every possible gameplay or third-party-mod bug.

## Implemented in the working candidate

- Read map environments through `MapDataPreset:GetEnvironment()`, retaining the
  legacy field fallback for older/custom map data.
- Replace removed wonder-footprint calls with the updated vanilla generator's
  `ShrinkShape(GetEntityOutlineShape(entity), 2)` and its flattening radius.
- Supply the explicit map owner to the updated landscape API.
- Bridge source-sized terrain writes to the physical backing, preserving source
  cell pitch, surrounding type cells, and zero padding for the impassability mask.
- Use the documented varargs overload of `IsKindOfClasses`. The table overload
  triggered a Lua stack assertion during decor classification. The scalar-control
  and varargs-candidate runs both completed without that assertion. A fixture
  checks the 64-entry bound and scalar fallback; the classification parity suite
  passes 667,222 comparisons.

Temporary `[Super Big Map][Compatibility]` breadcrumbs cover allocation geometry,
generator terrain writes, and sampled decor classification/grounding stages.
`DebugCompatibility`, `DebugLoggingEnabled`, and `DebugLoadingTimings` default to
false. Diagnostic scripts enable them only in their owned test process.

The initial-discovery candidate's fresh reference START-to-T1 runs measured
**82.100 and 82.250 seconds**, at 819200 x 819200 world units / 8192 x 8192 height tiles.
The repeat removes the old overview visibility sweep; the subsequent UI-only
cleanup also removes its redundant delayed follow-up thread.
Earlier compatibility runs measured 83.578 seconds (new game after loading an
expanded save) and 82.747 seconds (fresh process). These are
diagnostic measurements, not an accepted performance average.

## Discovery initialized at placement

Staged vanilla start deposits used to retain a blanket discovery exemption,
even when their proportionally transformed position lay outside the one scanned
destination sector. The object must be preserved, but that does not mean its
badge is already discovered.

The destination-sector decision now happens inside the existing start-placement
loops, before deferred GameInit and reveal FX. It covers staged replay,
already-placed entries, the footprint fallback and commander bonus placement.
It does not move, remove, duplicate or change the amount of a starting resource.
Ordinary maps and underground discovery retain their existing behavior.

Only the small set of start objects awaiting a real sector scan is persisted.
MapSector:Scan processes this set synchronously, including while paused;
SectorScanned is an idempotent notification fallback. LoadGame restores its saved discovery state
(including TerrainDeposit's otherwise default-true revealed flag). There are no
new whole-map visibility sweeps, overview hooks or map-switch hooks. The former
whole-map badge-hiding pass and the older overview-time workaround (including
its delayed follow-up thread) are removed. The fixture explicitly rejects any
whole-map enumeration by the new discovery functions.

This prevents the problem in newly generated games. It deliberately does not
sweep and retroactively repair already-incorrect saves from an older version.

Live 14N134W checks on 1.1.0.403908:

- Zero discovered/visible deposit or anomaly badges in unexplored surface
  sectors, both after generation and after a fresh-process save reload.
- The anomaly at (475500, 392298), handle 2000000298, remains physically present
  but hidden until sector 12:10 is scanned. A real scan reveals that same object,
  with its position and 50000 amount unchanged. Scanned-sector concrete retains
  its position and 404000 amount.
- The repeat's real scan reveals the pending anomaly synchronously while
  paused: GameTime remains 75 before and after, with position/amount preserved.
- After the final UI cleanup, a further cold load passes native overview
  scaling up/down/up (550/100/550) with the undiscovered badge hidden throughout.
  A subsequent paused scan reveals it immediately without advancing GameTime
  (14457 before/after). Successful generation, save/load and scan logs contain
  no Lua errors or native assertions.
- Surface resource, anomaly and effect top-ups complete with zero count
  shortfall: 206, 24 and 10 additions respectively. Decoration top-up places
  all 40 requested groups (1635 objects).
- All 322 captured native enrichment records are recreated; the final eligible
  enrichment audit checks 318 markers with zero XY/Z mismatches. A separate
  post-T1 audit checks 16606 in-bounds native decorative objects with zero XY
  mismatches against their recorded source coordinates times the scale factor.
  Out-of-map prefab metadata and the movable SectorRadius UI are not decoration.
- First underground access after cold load completes in 43.198 seconds.
  Underground resource/anomaly/effect top-ups add 63/8/3, with zero count
  shortfall. All 120 native enrichment records and 5532 eligible decoration
  positions pass. The underground decor pass correctly requests zero groups:
  this preset's vanilla decor pass placed none. Baked-in cave decoration is
  retained/stretched; the top-up pass does not replenish every baked-in rock.

A second fresh site, 15S67E with its naturally selected underground seed, also
reaches T1 (84.939 seconds), with zero badge leaks. Surface top-ups add 173
resource, 23 anomaly and 9 effect markers, and all 99 requested decoration groups
(3797 objects). All 273 eligible native enrichment markers and 18862 in-bounds
decorative positions checked have zero mismatches.

These post-T1 audits are diagnostic scripts, not shipped startup work.
Equivalent positions mean proportional XY scaling (4/3 on this source map),
with the existing hex snapping, terrain reseating and grounding rules.
This is not a new exhaustive vanilla-twin comparison of every object or site.
Evidence: `_ralph/runs/badge-scan-visibility/initial-placement-*`.

## Engine regression and Lua-only alternative

The installed debug engine reports:

```text
geConnectivity.cpp(869): ASSERT(m_nLayerSize <= MAX_PATCHES) failed
geConnectivity.cpp(1438): ASSERT(m_mPatchToBorderIndex.find(patch_address) == m_mPatchToBorderIndex.end()) failed
```

A fresh owned process reproduced both assertions with **zero mods loaded**.
The test only created an 8192 x 8192 blank map with zero scalar pass border; it
did not call the random-map generator or any SBM terrain/object transformation.
`ChangeMapInSlot` returned nil despite the native assertions, so a successful
Lua return or reaching T1 is not sufficient evidence of compatibility.

Live constants are HeightTileSize=100, PassTileSize=50,
ConnectivityPatchSize=64, and ConnectivityPatchDist=3200. The full backing
requires 256 x 256 = 65,536 connectivity patches per layer. Read-only inspection
of both the installed debug and retail binaries finds a 16,384 capacity guard.
The debug implementation also masks patch indices to 14 bits. Raising only the
guard would not fix duplicate addresses.

The exposed Lua functions include query, clear, suspend/resume, recalculation,
and diagnostic APIs. No capacity or packed-index-width setter was found. These
failures occur during native map allocation/loading, before SBM generation.
Changing the Lua constant alone cannot change the literal native shifts/masks.

A read-only comparison with the preserved pre-update engine establishes that
the old executable did not export this connectivity subsystem. It still used
the `pf` pathfinder, which remains available in 1.1. `compare_engine.py` verifies
the old executable against its original hash in memory; neither executable is
changed or launched by that comparison.

The new `sbm_legacy_pathfinder.lua` candidate passes a private `GameLogic=false`
mapdata copy only to native allocation for SBM-expanded maps. Actual Lua mapdata
retains `GameLogic=true`; terrain size, passability grids, city simulation and
unit movement remain enabled. A read-only native call-site audit found that
this native flag controls connectivity allocation and its save/load flag.
Map-scoped wrappers answer gameplay connectivity queries using actual
`pf.PosPathLen` paths. Unreachable destinations remain unreachable; there is no
always-true reachability shortcut. Ordinary maps delegate to vanilla.

Verified in live tests:

- Flat 8192 terrain: full corner-to-corner paths; a cross-map wall blocks the
  route and removing it restores the route; a native movable walks at the edge.
- Reference 14N134W generation: both maps at 8192, zero pass border, Lua game
  logic enabled, no connectivity assertions. First underground preparation
  completed in 41.909 seconds, including resource-reachability validation.
- Completed surface/underground save and fresh-process reload: both full-size
  maps retain the legacy-pathfinder flag and zero mapdata pass border. Drone,
  RCTransport and ExplorerRover each completed actual movement on both maps,
  including the surface edge near (811200, 811200).
- Save BEFORE first underground access, cold restart, then first access:
  both maps remain full-sized; the exact seed 5083534300309579687, two deferred
  wonder records and 750,565-byte obstruction mask survive. Underground
  preparation completes in 43.197 seconds. Both passage seeds are passable;
  query results match actual native paths. All six unit-movement tests pass
  again. The save, load and first-access logs have no native assertions or Lua
  errors. The earlier paused-at-game-time-zero save test also passed.
- Ordinary-map control alongside expanded maps: a separate 4096 fixture keeps
  `SuperBigMapLegacyPathfinder=false` and native connectivity. Its native global
  and map-method results agree (788800), distinct from the exact retained-path
  length (554371), confirming that this path does not intercept ordinary maps.

Further compatibility fixes uncovered by these tests:

- The new generator's forced-impassability raster must be captured and stretched
  with the cave terrain. Its setter only ADDS blocked bits, so the old source
  mask must first be cleared before applying the transformed raster. Object
  obstacles and slope passability remain intact. A compact persisted source
  raster now survives saving before first access.
- Connectivity now returns a distance, not literal `true`; underground deposit
  eligibility must accept numeric success, including zero.
- Pending game-time callbacks must resolve modules from the permanent mod
  environment instead of capturing transient tables containing native functions
  and UI state. This fixes the observed paused-save serialization failure.
- Deferred underground wonder records and the original generator seed now
  survive a cold load. All loaded-map presets have their physical dimensions
  and full-map bounds restored, including the offscreen surface when loading
  an underground save.

## Reproduction and evidence

Diagnostic scripts are under `_ralph/tools/compatibility/` and are not shipped
as mod code. `vanilla_capacity.lua` temporarily selects an empty load queue,
reloads Lua, verifies `#ModsLoaded == 0`, and loads the blank map. It does not save
the user's mod selection or modify the installed game. Run only in a disposable,
owned debug-game process, not a player's active game.

- Full generation: `_ralph/runs/compatibility-403908-varargs/`
- Scalar classification control: `_ralph/runs/compatibility-403908-scalar-trace/`
- Zero-mod reproduction: `_ralph/runs/compatibility-403908-no-mods/`
- Native inspection: `inspect_native_limit.py`, `inspect_retail_limit.py`,
  `inspect_pe.py`, and `audit_connectivity.py` (read-only).
- Maintained protocol fixtures: `tests/compatibility/` (six passing files).
- Complete generation and save: `_ralph/runs/compatibility-403908-legacy-complete/`.
- Completed-save cold load and movement:
  `_ralph/runs/compatibility-403908-legacy-complete-cold-load/`.
- Save-before-first-access, cold load, underground completion and six real unit
  movements: `_ralph/runs/compatibility-403908-legacy-pending-save/`.

Diagnostic game processes are explicitly tracked and closed normally between
tests. One launch (PID 10924) crashed before the debug handshake, before any test
script ran, with Windows exception c0000374 in ntdll.dll. The crash report and
startup log are retained in `_ralph/runs/compatibility-403908-boot-heap-crash/`;
its cause is not established. A fresh restart completed the pending-save tests
without changing the candidate. It is not counted as a successful run.
The candidate is delivered through the repository and local Mods deployment;
no Steam/Paradox workshop upload is performed by these tests.

Additional evidence: `_ralph/runs/compatibility-403908-legacy-fixture/`,
`compatibility-403908-legacy-first/`, `compatibility-403908-legacy-mask-save/`,
and `compatibility-403908-legacy-cold-load/`. Failed first-access attempts are
retained; successful allocation/save results do not conceal those failures.

## Rule-changing border experiment

After the user asked whether relaxing rules could help, a separate zero-mod
probe retained the 8192 x 8192 terrain and used PassBorder=204800 world units
(2048 height tiles on each edge). In a fresh process this removed both native
connectivity assertions during blank-map loading. `ConnectivityStats` returned
32768 patches across two layers, consistent with 16384 per layer. No executable
or production-mod setting was changed.

This strategy was REJECTED and is not part of the solution. It was only an
allocation-level result, not a full playable-colony test. The
remaining central play rectangle is 4096 x 4096 tiles: only 25% of the terrain
area. The sampled blank-map points were not passable, and reachability queries
returned nil; generation and actual unit movement still require validation.
Evidence: `_ralph/runs/compatibility-403908-border-2048/`.

Reproduce by setting `CAPACITY_PROBE_BORDER = 204800` in the owned diagnostic
process before running `vanilla_capacity.lua`. Omitting it uses the original
zero-border reproduction. An earlier attempted parameter-setting command lost
its quotes and therefore ran another zero-border control (PID 35884); that run
is not evidence for the bordered result. The bordered result came from a fresh
process (PID 196), with the parameter explicitly verified before map creation.

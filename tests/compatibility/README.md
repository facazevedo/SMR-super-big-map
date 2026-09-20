# 1.1 compatibility regression fixtures

Run each fixture in a separate Lua 5.3+ process from the repository root:

```powershell
Get-ChildItem tests/compatibility -Filter '*_test.lua' | ForEach-Object {
    lua $_.FullName
    if ($LASTEXITCODE -ne 0) { throw $_.Name }
}
```

These tests exercise the production implementation with protocol doubles. They
cover allocation isolation, native delegation, real-path query semantics,
environment and footprint API changes, terrain write ownership/padding, forced
mask replacement, bounded class-query varargs, and discovery at initial placement
(including a prohibition on whole-map discovery sweeps, save-state defaults,
pending-only scans, and underground/vanilla isolation), plus the EXPAND MAP
controller action's selection/arming, repeat filtering and dialog lifecycle.
Wonder fixtures cover native surface finalization for all four classes, preserving
source-cleared terrain, flag restoration, current-map/vanilla gates, and completion
without an Elevator. Lifecycle registration is checked against both module-only
reloads and replacement of the engine's message registry.
Decoration fixtures cover preserving elevated rock stacks, retaining native
terrain-support correction, excluding the known unskinned airborne cave-in submesh
while retaining its animated rubble and gameplay state (including fresh placement,
load/map activation and newly spawned cave-ins),
and anchoring underground height scaling to the original floor without changing
surface normalization or silently exceeding the height budget.
The controller fixture uses platform protocol doubles, not console hardware.
Passage safety fixtures exercise the complete bootstrap/final-surface/deferred
planner, ordered nearest-valid hex rings (including a 17-ring case), immutable
underground coordinates, pre-flatten validation, persisted entrance commitments,
and surface-failure/readiness gates. A surface offset is allowed only when closer
hexes cannot fit the Elevator footprint; it is not an automatic alignment failure.
The surface uses the native construction shape, not the generator's extra three
clearance rings; an invalid padding-only hex must not reject a valid building site.
They do not replace live
engine generation, movement, obstacle, save/load, or first-underground-access
tests. Live evidence and limitations are recorded in `COMPATIBILITY_1_1.md`.

The fixtures are not mod payload and do not alter the installed game.

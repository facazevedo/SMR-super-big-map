# 1.1 compatibility regression fixtures

The candidate now has 44 host fixture files. The new native-composition fixtures
keep physical support status separate from source-equivalence evidence: complete
geometry identity, every fragment frame and a preserved rooted contact path are
required. Alternative contacts are tested against the captured source triangles,
not inferred from current support alone. Missing source transforms, changed mesh
content, moved native bone frames, unrooted cycles and source-side gaps fail.

Surface-performance fixtures also check one-time nomination geometry reuse with
fresh post-movement proof, one classification per overlapping neighbour (including
negative decisions), and 200 randomized union queries with unchanged selection
order. Positive zero-offset
proofs and fused clearance calculations agree with the full reference planner in
500 placement cases, alongside 1000 cached/uncached contact comparisons.

Particle-attachment coverage verifies the game's assigned FX object, active recipe,
compiled particle identity, exact parent/spot/offset/orientation/scale and absence
of a rendering override or physical flags. It does not exempt arbitrary empty
entities or claim to decode every rendered particle. Rubble-height coverage tests
the affine source-height transform at arbitrary scale/datum, without seed-specific
coordinates and without resampling the expanded terrain beneath the pivot.

Frame comparison bounds the full affine displacement over every component's box,
using the existing two-world-unit contact tolerance. This covers all enclosed
vertices and triangles, including long inverse-bind lever arms. Tests reject
actual displacement, missing bounds and non-finite matrices; coefficient noise
alone is not treated as a moved fragment.

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

Surface optimization fixtures compare exact placement/rejection results against
the previous full-vertex formula, bound invariant-matrix reads, prove one-time
nomination-geometry reuse and mandatory post-movement reconstruction, and check
monotone contact caching against 1000 uncached queries. An already-rejected stamp
can short-circuit only when a component has no possible remaining rooted path;
deferred support chains and legitimate stacks must still pass. Native timings and
pose comparisons remain separate requirements.

`decor_topup_transform_test.lua` checks the candidate's common XYZ similarity
around a native prefab centre, preserving explicit vertical offsets and relative
positions while retaining vanilla terrain-relative scatter semantics.
`decor_support_island_test.lua` checks common seating of rooted formations,
visibility preservation, multiple roots and rejection of missing evidence.
Live whole-map acceptance is separate from these host fixtures.

## Active five-scenario follow-up

`decoration_followup.json` selects five cases from `decoration_seeds.json`:
14N134W, 15S67E, 60S120W, 20S45E, and **30S146E from Test2.savegame.sav**.
The first two retain the four-wonder coverage; the next two retain known
surface-fragment regression cases. Test2 is one of the five, not a sixth case.
The original twenty catalog entries remain unchanged for historical comparisons.

Work on **15S67E first** (the hardest observed case: Bottomless Pit, Crystal Cave,
cave-in findings and a post-load map-identity failure). Do not advance to the other
four until this primary case is release-ready. Earlier partial checks of 14N134W
are retained as evidence, not a completed campaign gate.

Test2's full recovered generation identity is recorded, not just its terrain:
game seed text `jJRXM7pE`, surface seed `-8259618194048590238`, underground
**generator** seed `8351877768356166168`, templates `BlankBigTerraceCMix_19` /
`BlankUnderground_03`, regular mode, IMM, Rocket Scientist and Rough Terrain.
Its underground mapdata seed is the surface seed; that is not the underground
generator seed. Keep numeric seeds as decimal strings until Lua integer parsing.
The save's revision is 396349; tests on revision 403908 must report any version
differences rather than promise byte-identical geometry. The source save was
inspected read-only and must not be overwritten.

Adding a scenario is not a passing result: fresh generation, same-input vanilla
comparison, lifecycle and fragment checks remain required. Record START to T1
and underground preparation separately, using averages. The release configuration
must prepare the underground in less than 60 seconds. The user subsequently
authorized disabling exhaustive diagnostics on both layers for primary-case
release timing and lifecycle checks before the remaining four cases. This is
recorded in `decoration_followup.json`; it is not a five-case passing result.
Scoped correction safety and rollback remain active.

Guard 324 passed the primary release-mode save/load, map-switch, entrance,
movement, new-cave-in and all-17-blocker clearing tests. Performance work remains:
the guard-325 cold single measured 108.436 s START to T1 and 60.104 s underground.
These are not final-candidate averages. The scalar SAT regression fixture compares
12,000 decisions against the original vector implementation. Support-vertex
deduplication is exact-only; contact caching rejects uncertain scale/tolerance
cases and falls back to the original world-space proof.

The map-identity fixture reproduces stale sandbox MainMap/MainCity shadows after
load, and verifies resolution through the live registry without overriding a live
temporary native source. Diagnostic-off support fixtures cover both layers,
preserved corrective placement, legitimate stacks, unknown-neighbour vetoes, and
retention of full-map diagnostic reports rather than replacing them with a partial
correction-only pass.

The seating fixture also covers partly buried top-up foundations: visible-height
requirements are measured once before candidate searching, and every component
must retain its own minimum. A counterexample rejects burying an already-small
visible tip. The separation fixture covers disjoint triangles with overlapping
boxes, conservative unknown-neighbour vetoes, exact transformed bounds, and
positive terrain contact inside a triangle face rather than only at vertices.

Sector-cleanup coverage reproduces orphan scan-notification workers surviving
their deleted native object. Only discarded owners' workers are cancelled, kept
sectors remain untouched, and failed/self cancellation defers destruction.

`decoration_terrain_interval_test.lua` proves whole-triangle separation over
sloping terrain and rejects interior terrain peaks, missing data and exhausted
proof budgets. Native-group correction coverage retains visible components and
vetoes attachments; candidate-placement coverage rejects volume containment as
well as intersecting triangles. `decor_topup_cleanup_test.lua` verifies complete,
idempotent owned-object cleanup with injected exceptions and ignored deletions.
Known-pose fixtures additionally verify translated references without moving
the game camera. There are now 30 host fixture files; their passing result does
not substitute for the primary live campaign gate.

Known-pose cleanup also rejects ignored native deletions, retains owned reference
objects across ClearCache, avoids allocating another batch while cleanup fails,
and recovers after deletion becomes available. The native fault-injection repeat
left the object census unchanged. The guard-318 primary lifecycle repeat passed
save/load, switching, entrances and six player-command rover moves, then restored
its checkpoint. New cave-in geometry remains a separate failing gate. The three
measured original-rubble gap points are impassable for both drone and rover path
classes; this does not certify every possible route through or around the rubble.

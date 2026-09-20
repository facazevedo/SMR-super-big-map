# Underground wonder fidelity

## Shared fix

The fix applies through the `UndergroundWonder` class query, not a seed, coordinate,
or Bottomless Pit special case. It remains Lua-only and uses the original assets.

- Re-register lifecycle callbacks when the engine replaces its message registry.
  Re-executing only the mod module still does not stack callbacks.
- Complete the already-current underground lifecycle even without an Elevator.
- Publish transformed native TerrainHole/Height surfaces after map activation and
  resource readiness. This refreshes native registration without changing model
  position, scale, terrain heights, other flags, or adding a full-map rebuild.
- Preserve vanilla's source-domain flattening/clearance, already copied with the
  stretched height field. Re-flattening a rounded expanded hex footprint changes
  neighbouring cliffs and is no longer applied to source-cleared maps.
- Keep the older footprint migration for legacy maps without source clearance.
  Already-correct object positions do not open a pass-edit transaction.

The reported pit shelf persisted after a full height/passability rebuild but
disappeared after a synchronous native surface-registration refresh at unchanged
geometry. The first candidate fixed the hole but exposed the redundant flattening
issue; its terrain comparison was rejected before accepting the revised path.

## Original wonder-fix verification scope

PC debug game 1.1.0.403908. Same-site/same-seed vanilla controls were generated with
all mods unloaded in memory, without changing the user's saved mod selection or
game installation. Expanded maps retain 8192 x 8192 tiles on both levels.

| Site | Underground seed | Wonders |
| --- | --- | --- |
| 24S97W | 6074387974731471656 | Bottomless Pit, Jumbo Cave |
| 65S11W | 5928430118478359930 | Cave of Wonders, Ancient Artifact |

Checks capture original entity, orientation, exact affine world anchor, floor,
every native TerrainHole/Height/Collision/Walk triangle, an 81 x 81 surrounding
height/passability lattice, and four rendered viewing directions per wonder.
Diagnostic lighting/reveal changes never move wonders or toggle native grid flags.

Investigation scripts and raw evidence are under `_ralph/tools/compatibility/`:
`wonder_geometry_probe.lua`, `wonder_capture.lua`, `compare_wonders.py`,
`wonders_a_vanilla.json`, `wonders_b_vanilla.json`, and tagged expanded captures.
They are not shipped mod payload. Maintained protocol regressions are
`tests/compatibility/wonder_surfaces_test.lua` and `lifecycle_registry_test.lua`.

Fresh generation passed for all four classes, with no Lua errors/native assertions
in the two revised-generation logs. All entity/orientation checks and rounded
affine anchors/floors match. Native triangle counts are unchanged; transformed
vertices differ by at most 1.13 world units from the integer-scale expectation.

The surrounding terrain samples are not an exact continuous affine surface:
mean absolute height differences are 9.592/12.744/10.194/11.787 world units for
Pit/Jumbo/Cave/Artifact respectively, with maxima 1634/1546/1125/2130 at sampled
cliff transitions. Passability differs at 37/16/22/21 of 6561 sampled locations,
respectively. Discrete grid/hex resampling remains observable and is not concealed
as exact equality. For the pit and Jumbo, all 13,122 height/passability sample
records exactly match the pre-reflatten source-copy baseline: the new native-hole
finalization adds no terrain or passability changes to those records.

Four-angle vanilla and revised expanded screenshots were inspected for every
wonder. The pit's obstructing brown shelf is absent; the cave opening and the
other wonder models retain their vanilla shapes. Generation measurements (single
runs, not a reference average): 24S97W start-to-T1 83.414 s, first underground
48.550 s; 65S11W 76.391 s and 47.181 s.

Both expanded test saves were cold-loaded in separate game processes using the
final deployed payload. All four wonders retained exactly the same recorded
pose, entity, orientation, native triangles and surrounding height/passability
samples as their fresh-generation snapshots (26,244 sample records total).
The pit/Jumbo case also passed a surface-to-underground round trip with the same
exact checks. Rendered reload/round-trip checks retained the clear pit/cave
openings; no preparation failure, Lua error or native assertion was recorded.

At that checkpoint all nine compatibility test files passed, both changed production Lua files parsed,
and the local Mods deployment audit matches all 39 payload files. The final
24S97W inspection session is paused underground at the Bottomless Pit. These
changes are deployed locally but are not yet committed or pushed.

## Decoration and lighting follow-up (2026-09-19)

The reported broken column was composed of native rock pieces. The terrain-only
unsupported-pivot fallback had lowered 24 explicitly elevated pieces independently
of their supporting rocks. It now applies only to terrain-level source pivots;
the existing proven-native-terrain-contact correction is retained. This preserves
authored stacks without a full-map repair sweep.

The high four-rock cluster was isolated to `CaveInRubble`, not particles or scatter
rocks. An initial claim that re-publishing its `idle` pose removed the fragments
was disproved by fixed-camera, full-resolution pixel checks. The ineffective
helper, activation hooks and protocol fixture were removed.

Resource inspection then found the cause: the native `CaveIn_Buildings` asset has
an unskinned 144-vertex submesh at Z493.443..498.931 metres. Its main rubble mesh is
skinned; both idle and falling reference the same two parts. Unscaled plain-object
controls reproduce the high fragments. A per-object Lua rendering descriptor now
retains only the original skinned rubble/material, conditional on the exact
defective mesh signature. Changed/fixed native assets are left alone. No global
resource, game installation, object entity, pose, animation, collision, footprint
or clearing work is edited. One cached descriptor is applied at initial placement,
load/map activation and newly spawned cave-ins on expanded underground maps.
The first fixed-view live check reduced the fragment ROI from 283 pixels to zero
while preserving the ground rubble. Cold-load and fresh-generation results follow.

Cold-load verification with the deployed code passed in a new process: zero
fragment pixels before any manual renderer call. Restoring the complete native
mesh descriptor reproduced 341 pixels; invoking the production mod function
removed them again (zero). All 27 objects retained identical position, scale,
angle, entity, animation state/phase/speed, clearing work, grid registration and
hex footprint. Switching to the final falling pose and back to idle still gave
zero stray-fragment pixels. A surface/underground round trip also remained clear.
Pit/Jumbo pose, native surfaces and all 13,122 surrounding height/passability
samples exactly match the earlier fresh-generation record across cold load and
round trip. One prematurely issued investigation probe logged an undefined tag
during loading; this was not a mod preparation failure. Raw evidence is
`rubble_accept_*.png` and `decor_roundtrip_a_final_bright.png`.

Fresh 24S97W generation with the final renderer code passed in that clean process:
82.979 s start-to-T1 and 47.311 s first underground preparation (single runs).
Both levels are 8192 x 8192; preparation succeeded and the reported entrance
validation popup did not recur. Pit/Jumbo recorded geometry and all surrounding
height/passability samples exactly match the preceding corrected generation.
The final bright fixed-view capture also has zero fragment pixels, and the normal
inspection lightmodel was restored afterward. Three optional clutter-source
unavailable diagnostics were recorded, but both preparation sessions ended
successfully. The earlier entrance failure's original trigger remains unconfirmed.

Underground uniform height scaling now keeps the original floor datum rather than
normalizing it down to the surface's low datum. In the tested maps the floor stays
at 10000 world units instead of 1000; surface height/headroom rules are unchanged.
The blue background was caused by the temporary `ArtPreview` inspection lightmodel.
Inspection helpers now restore the native `Underground_Always` lightmodel.

Fresh A in a clean process passed: both maps 8192 x 8192, preparation successful,
82.587 s start-to-T1 (one run, not an average). The bright low-angle screenshot
shows a connected column; that framing does not reliably expose the airborne
fragment cluster, so it is not a rubble acceptance test. All 24 formerly
lowered pieces now exactly match their intended base Z plus the 9000-unit datum
difference. Pit/Jumbo anchors, triangle counts and surrounding terrain errors
remain equivalent to the original wonder comparison. Pit passability differences
are now 38/6561 samples versus vanilla; Jumbo remains 16/6561.

One earlier test after a timed-out full Lua reload was rejected: its final surface
entrance commitment was missing and subsequent underground preparation failed
surface flatness validation. The original failure before that skipped commitment
was not retained with diagnostics disabled. A clean process with the same code
passed both preparation pipelines; this is not evidence that arbitrary hot-reload
states are safe. Two optional clutter-source-unavailable diagnostics remain; they
do not fail the preparation pipeline. No Lua error/native assertion was logged in
the clean A generation.

Three additional maintained fixtures cover rock support/stack preservation,
guarded cave-in rendering and the underground height datum (12 fixture files
total). Raw follow-up evidence uses `fresh_a_corrected` tags under the ignored
compatibility investigation directory. Save/load and second-case follow-up are
recorded below when complete.

Fresh B also passed after starting a second new game in the clean process, without
reloading Lua: 77.690 s start-to-T1 and 53.047 s underground preparation. Both
maps remain 8192 x 8192 and both wonder floors remain at 10000. Cave of Wonders
and Ancient Artifact have exact rounded-affine anchors, unchanged entity/pose and
native triangle counts, and the same terrain height errors as the prior comparison.
Their passability differences versus vanilla are 26/6561 and 21/6561 respectively.

## Precision and limits

The engine exposes integer-percent object scale: 100 becomes 133, not exactly
133 1/3. Terrain uses the full 8192/6144 ratio; its discrete grid is resampled.
The goal is faithful vanilla geometry without added shelves or occlusion, not
mathematically continuous or pixel-identical scaling. Finite seed tests cannot
prove every possible generated map or other-mod interaction. Console hardware
was not used in this verification.

This change does not reconstruct terrain already modified by older versions in
existing saves. Fresh generation is the authoritative vanilla-terrain comparison.
Entrance alignment is a separate issue; one previously measured pair was displaced
by the existing surface placement rules and is not fixed by this wonder change.
See [ENTRANCE_SAFETY.md](ENTRANCE_SAFETY.md) for the subsequent entrance work:
the user clarified that nearest-valid-ring surface offsets are permitted, and the
unsafe provisional-plan/failed-surface preparation paths are now guarded and tested.

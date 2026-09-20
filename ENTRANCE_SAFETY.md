# Entrance placement and preparation

The underground entrance's transformed vanilla coordinate is authoritative.
The surface entrance uses that hex if the complete Elevator footprint fits;
otherwise it searches concentric hex rings in order, starting at radius 1.
Only the surface entrance relocates. No slope/top-up rule or underground
candidate veto is used to push it farther away.

The surface now uses `BuildingTemplates.Elevator:GetBuildShape()` (37 hexes on
1.1.0.403908), as the native construction controller does, together with the
passage's native flatness check. The previous search used
`GetExtendedSpawnShape("Elevator")` (127 hexes): the generator adds **three extra
clearance rings**, which are not a construction requirement. The selected surface
pad is now validated and reserved **without rewriting its terrain**; actual
Elevator construction retains ownership of native flattening. Underground native
spawn/clearance geometry is unchanged.

## Preparation correction

A bootstrap lock is provisional: the final surface terrain does not yet exist.
Previously, deferred underground preparation accepted that lock as final and
could call native `FlattenTerrainInBuildShape(..., "flatten unbuildable")` on
an unvalidated surface footprint. The recorded failure had an unbuildable
65535 height and lacked a final surface commitment.

Additionally, the protected surface pipeline unconditionally marked the surface
done/expanded even when its central branch failed. That could release dependent
underground work and publish a false T1 milestone. The earlier error was not
retained when diagnostics were disabled.

The corrected code:

- requires each linked surface endpoint to have a prepared, committed pad before
  any deferred passage mutation; these object fields also support existing saves;
- never re-prepares or relocates the surface entrance during underground access;
- validates the complete Elevator footprint immediately before native flattening;
- verifies the settled surface footprints after the last native grid rebuild,
  and keeps underground readiness waiting until that verification completes;
- records and persists the original surface error, without reporting completion
  or automatically replaying a partially applied stretch;
- stops dependent preparation on a terminal surface failure instead of waiting
  indefinitely or accepting a provisional plan.

No per-frame scan, whole-map repair pass, terrain lowering, engine binary patch,
or coordinate-specific exception is introduced. The checks inspect the linked
entrances and their small Elevator footprints.

## Verification (2026-09-19 local time)

The maintained `tests/compatibility/passage_safety_test.lua` reproduced the unsafe
flatten call before the correction. It now checks the complete production planner,
nearest rings 0/1/2/17, missing-final-plan rejection before mutation, multiple pairs,
save-style transient-field loss, pad validation, and failure/readiness reporting.

The initial safety-only 24S97W / underground seed 6074387974731471656 test passed both preparation
pipelines: 83.548 s START-to-T1 and 48.413 s underground preparation (single run).
Both maps were 8192 x 8192. The original offset pair remained at ring 17 when
testing the old 127-hex buffer; all 817 closer hexes failed that oversized check.
That result does NOT prove closest actual Elevator placement. A second case
exposed the distinction: the real 37-hex footprint remained valid while a hex in
the extra clearance buffer was unbuildable. The final construction-shape change
above supersedes those placement results; its live results follow below.

Temporarily removing a final-pad marker in the disposable live test made deferred
alignment reject the plan before changing either position or the sampled terrain;
the marker was restored immediately afterward.

A one-shot VM fault injected into the final surface rebuild also passed: surface
done=false, expanded=false, T1=false, no pending transaction, and underground
preparation rejected with the original injected error. The injection restored the
original function immediately and was discarded with that disposable process.

The precise initiating error in the historical timed-out Lua-reload session is
not recoverable from its logs. These corrections address the independently
reproduced unsafe state transition and preserve the initiating error in future.
They do not reconstruct terrain already damaged in an old save.

Raw live evidence is under the ignored `_ralph/tools/compatibility/entrance_fix_*`
files. Further cold-load and fault-injection results are recorded below.

Final construction-shape build, fresh A: START-to-T1 82.292 s. The formerly
17-ring surface fallback is now at ring **13** (q188/r360), with all 469 nearer
hexes rejected by the independent actual-footprint audit. The other pair still
matches exactly. Both committed surface footprints pass after the final grid
rebuild, both maps retain 8192 x 8192 terrain, and the underground is still
unprepared/source-layout. Saving at that deferred boundary succeeded. The first
save attempt in the preceding B investigation had been blocked by the ordinary
introductory notification, not by the mod; the inspection helper dismisses that
notification before asking the game to save, without bypassing save safeguards.

Cold process load of that surface-only save passed first underground preparation:
prepared=true, failed=false, and both reciprocal passage links intact. The surface
positions exactly match the pre-save coordinates; the underground anchors are at
q201/r347 and q295/r446, their unchanged authoritative destinations. The independent
audit again finds rings 13/0 and no valid closer tiles. Both maps remain 8192 x 8192.
The initial probe sampled immediately after the map switch, before asynchronous
preparation completed; its early reading is retained in the raw evidence and is
not a preparation failure or valid timing measurement. Final state and coordinate
audits were collected after completion. The probe now waits on the actual prepared
or failed milestone. No Lua error, native assertion or entrance popup occurred in
this cold-load run.

The first 37-hex candidate was subsequently **rejected on B**, despite reaching
T1 in 75.775 s and completing underground preparation. Its surface re-flattening
left 4 and 2 footprint hexes unbuildable after the last native rebuild; immediate
preparation validation had seen the old grid. This is why generation now reserves
the naturally valid surface site without flattening it again, and performs the
settled-grid check before publishing T1. The final terrain-preserving candidate's
fresh/cold-load results follow below; the earlier A numbers are intermediate-build
evidence, not a final-build benchmark.

Final terrain-preserving B surface generation passed in a clean process:
**78.236 s START-to-T1**. Both surface entrances are now on ring 6 (previously
11 and 17 with the oversized spawn buffer). The independent settled-grid audit
checks all 91 closer hexes for each and finds none valid. Both actual footprints
remain valid after the final native rebuild, with the original terrain preserved.
Both maps are 8192 x 8192, and a new save was made before underground preparation.

Cold-load B then completed first underground preparation in **48.540 s**, with
prepared=false before access and prepared=true / failed=false afterward. Both
reciprocal pairs retain their fixed surface coordinates and authoritative
underground destinations. The independent audit still finds rings 6/6, valid
surface footprints, no valid closer candidates, and 8192 x 8192 on both maps.
This is load/first-access evidence, not an additional START-to-T1 sample.

Final terrain-preserving A (24S97W) also passed fresh generation:
**82.302 s START-to-T1**, followed by **47.612 s** first underground preparation.
The surface fallbacks are rings 13/0; all 469 candidates closer than the first
entrance were independently rejected (468 native flatness, one passability).
The underground anchors remain at their authoritative q201/r347 and q295/r446
coordinates. Both actual Elevator footprints are valid, links are reciprocal,
and both maps retain 8192 x 8192 terrain.

Both final cases passed a surface-to-underground round trip and a repeated
independent footprint/coordinate audit. A repeated missing-pad-marker probe
rejected the provisional plan before changing either endpoint or terrain and
restored the marker. The visible A inspection session is left paused underground
with its native light model. These two START-to-T1 values are single runs on
different seeds, not a reference-scenario average or a performance-target claim.

Final local checks: all 13 compatibility test files pass, every production Lua
file parses, and `git diff --check` passes. The local Mods payload matches all
39 source payload files exactly. These checks were completed before committing
and publishing the fixes.

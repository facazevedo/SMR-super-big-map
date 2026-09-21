# Decoration support diagnostics (candidate, not release-certified)

The validator reports geometry/support evidence; it does not move, resize, delete,
reveal, or repair decorations. `DecorationValidation` in `sbm_config.lua` controls
the diagnostic pass. It is disabled on both layers in the current release-mode
timing candidate, at the user's explicit request. Production placement rules,
narrow correction safeguards and rollback remain enabled.

## Release logging cleanup - 2026-09-21

Guard **344**, based on `dbf61dc`, keeps all production placement, repair,
passability, compatibility and rollback checks. Release configuration disables
all debug/trace channels, exhaustive decoration audits, native manifests, test
controls, reveal cheats and terrain dumps. Errors that invalidate a map are still
reported; they must never be silently hidden.

The remaining normal terrain/census summaries now require opt-in diagnostics.
Release generation omits report-only duplicate wonder terrain/obstruction and
entrance-connectivity queries, verbose entrance-footprint descriptions, per-object
disabled validator dispatch, and the deferred surface census that only recorded
statistics. The authoritative census/terrain checks that drive placement failure
or repair remain. Diagnostic code is retained for explicit troubleshooting and
does not count an unmeasured result as a pass.

All **45** host fixture files pass. The new release-quiet fixture is red against
`dbf61dc` and green against this candidate; it compares placement acceptance,
rejections, nearest-valid repair and RNG consumption with observation on/off,
checks print gates and verifies that release mode schedules no report-only
deferred census. Live generation and lifecycle results are recorded separately.

The final 15S67E run measured **97.468 s START -> T1** and **60.037 s underground
preparation**, at unchanged 3840 x 2160 and 8192 x 8192 on both layers. These are
single measurements, not an average or proof of a speedup; the underground result
is still 0.037 s over 60 s. Exact final-build save/load, both map switches, both
entrance pairs, seven commanded rover moves, new cave-in settling and all 17
blockers' five native clearing phases pass. Decoration/rubble snapshots match
dbf61dc: surface 19290 / `7048055723638285559`, underground 644 /
`-2892925381871930933`. No report-only deferred census or wonder ledger appears
after load/switch. Local payload audit is 43/43 exact. These measurements preceded
the commit/push handoff; they do not imply a public Workshop release.

This remains scoped to 15S67E, not all scenarios/hardware. The debug executable's
vanilla initial-sector/performance messages were investigated, not suppressed:
the final map has 395 surface and 132 underground resource markers, and all 13
recorded starting deposits were placed. Two later Invalid Area Lua errors came
from a malformed inline diagnostic query (Windows stripped its string quotes),
not the mod. Its corrected file-based probe and final lifecycle driver pass.
Evidence: `_ralph/tools/compatibility/release_344_cleanup.md` and associated JSON.

## Surface-only optimization measurements — 2026-09-21

The active scope is now **surface only**. Two cold-process runs of the unmodified
`4c22d2a` payload, with the same 15S67E seed/START driver and actual 3840×2160
display, measured **90.356 s and 90.637 s**, average **90.4965 s**. The old
87.857 s result is historical, not the fresh controlled baseline. The baseline
retained its original diagnostic flags; the current candidate has release
diagnostics off. The current payload has been restored after the comparison.

The fixed final candidate (guard **342**) measured **97.486 s and 96.282 s** in
two cold processes: **96.884 s average START → T1**, **6.3875 s / 7.06% slower**
than that baseline. It improves on the earlier 108.407 s candidate run, but does
**not** establish timing equivalence to 4c22d2a. Both repeats retain 99 top-up
groups/3349 objects, 11 support rejections and the same three corrections, with
8192 × 8192 surface terrain and unchanged 3840 × 2160 display. Mean top-up support
planning is 7.1025 s; mean whole surface correction transaction is 5.6725 s.
Both final surface snapshots contain exactly 19,290 identical pose records,
hash `7048055723638285559`, matching the earlier corrected reference. All 44 host
fixtures, Lua syntax and diff whitespace checks pass. Local deployment audit is
43/43 exact files; the owned test games were stopped normally. These timings were
recorded before the candidate's commit/push handoff; that handoff preserves the
tested runtime payload without further implementation changes.

Different optimization candidates, single runs (do not average these together):

| Guard | START → T1 | Top-up support planning |
| --- | ---: | ---: |
| 328 | 108.407 s | 15.124 s |
| 329 | 101.704 s | 8.975 s |
| 330 | 102.049 s | 9.067 s |
| 331 | 101.864 s | 9.331 s |
| 332 | 100.920 s | 9.254 s |
| 333, discarded experiment | 101.081 s | 9.010 s |
| 335 | 100.966 s | 8.064 s |
| 336 | 99.789 s | 7.898 s |
| 337 | 99.185 s | 7.088 s |
| 338 | 96.269 s | 7.078 s |
| 339 | 99.168 s | 6.975 s |
| 340 | 96.459 s | 7.430 s |
| 341, discarded extra caches | 97.530 s | 7.383 s |

Retained changes fuse exact vertex-clearance accumulation, use the verified
native integer-XY height query, calculate certified-flat upright extrema directly,
reuse nomination geometry once before any movement, and reuse compatible proven
same-frame contacts. Guard 335 additionally short-circuits already-rejected new
stamps and hoists invariant matrix coefficients/running extrema out of the
per-vertex loop. Guards 337–339 add positive zero-adjustment proofs for independent
complete rigid placements and one-time neighbour selection/classification over
overlapping correction regions. Failed proofs retain the full vertex planner.
Necessary support, visibility, placement and rollback gates remain.
A more complex bounded vertex hierarchy
passed host equivalence tests but did not improve measured time and was removed.

Guards 329–332 and 336–340 retain the exact 19,290-entry corrected surface decoration snapshot,
99 top-up groups/3349 objects, 11 support rejections and three surface corrections.
Guards 333/335 have the previously observed alternative snapshot with 23 extra stones;
its source remains unconfirmed, and it is not evidence that all fresh surface
objects are byte-identical. The candidate has 44 passing host fixture files,
including 500 actual-placement equivalence cases with up to 650 vertices and
1000 uncached/cached contact comparisons. No new underground preparation measurement,
final-candidate lifecycle certification, release commit or push is implied.

Guard 338 reduced the whole surface correction transaction from about 8.1 s to
5.6 s; its inner evidence/proof timers alone do not represent the complete cost.
Extra source-terrain/world-BVH caches (340/341) passed equivalence tests but did
not demonstrate a native timing gain; they were removed. Guard 342 retains the
simpler 339 implementation. Only the two unchanged 342 runs above are averaged;
individual optimization trials are not pooled. Necessary placement checks remain
enabled; exhaustive diagnostics are off on both layers. This surface-only timing
work does not certify a final release lifecycle or the other four scenarios.

## Latest release-mode evidence — 2026-09-20

The primary 15S67E lifecycle run on guard 324 passed: save/load, both map
switches, unchanged decoration/rubble snapshots, full 8192 × 8192 terrain,
both entrance commitments, six player-command rover movements, a newly spawned
cave-in, all five clearing phases of all 17 tunnel blockers, and a rover entering
a cleared blocker's former footprint. The owned test checkpoint was restored.
Evidence: `_ralph/tools/compatibility/primary_324_release_lifecycle.json`.

Cold-process single runs (different candidates, **not an average**):

| Guard | START → T1 | Underground preparation |
| --- | ---: | ---: |
| 322 | 105.391 s | 68.206 s |
| 323 | 104.793 s | 64.653 s |
| 324 | 104.554 s | 61.757 s |
| 325 | 108.436 s | 60.104 s |
| 326 | 110.129 s | 60.653 s |

Guard 325 omits redundant initial negative-gap classification for strictly
guarded tunnel-blocker correction proposals. It still requires complete native
asset/placement eligibility, a positive post-correction support proof and
transactional rollback. Surface corrections still require confirmed negative
separation before moving any original object. All 40 current host fixture files
pass, including the scalar triangle-SAT optimization's 12,000 reference
comparisons. Guard 326 completed fresh generation with the same 99 decoration
top-up groups / 3349 objects and all three surface / 17 blocker corrections.
Its single timing does not demonstrate an end-to-end speedup; final-candidate
repeats and lifecycle checks remain pending.

The earlier back-to-back guard-322 run had a native Render-thread crash during
map teardown. Its cause remains unconfirmed; cold-process timings do not resolve
that issue. The other four scenarios and a final-candidate timing average remain
pending. The under-60-second underground target has not yet passed. No release
commit or push has been made. Older sections below are historical evidence, not
the current configuration or latest timings.

## Current issue status — 2026-09-20

**Underground flickering: solved, user-confirmed.** The user explicitly accepted
the fix and requested closing this issue. It is no longer an open investigation.
Retain the native cave-in mesh descriptors and the narrowly guarded settled-fragment
correction; earlier observations below remain historical evidence.

This closes the reported flickering issue, not the separate tunnel-blocker gaps,
unresolved support/geometry findings or the pending five-scenario verification.
No new timing run was performed for this status update. The last completed
reference average remains 87.248 s START to T1 and 56.329 s underground preparation,
measured separately.

## Active release follow-up (not yet complete)

### Latest primary-case evidence

Guard 319 found and corrected a real native-rubble placement regression: the
expanded terrain was resampled beneath each cave-in pivot, shifting two authored
formations upward. Generation now captures the source visual Z from the native
source map and applies the same affine height transform as the terrain. This
uses no seed, handle, location, or hard-coded floor. The fresh 15S67E check removed
the extra unsupported fragments on the previously failing cave-in. Original
meshes, composition, XY and gameplay shapes remain unchanged; no support stones
were added.

Physical-support status and vanilla-composition verification are now separate
reported facts. Complete decoded mesh content, all rigid fragment/bone frames,
component membership and rooted native/current support relationships are checked.
An inherited vanilla gap stays in the physical findings even when its unchanged
authored composition is verified. Missing source data cannot pass this comparison.
All 26 surface findings passed the fresh guard-319 composition comparison.

Guard 320 additionally reconstructs captured source component transforms to test
alternative support contacts against the actual source triangles. The fast
capture's first witness is not an exhaustive native contact list. Only edges
proved in both source and expanded geometry enter the rooted comparison graph;
unknown geometry and unsupported cycles remain rejected.

Native attached particle effects use a separate positive verification: compiled
particle identity, exact native FX assignment, active recipe, parent, attachment
spot, offset, orientation and scale, with no mesh override or physical flags.
The three Bottomless Pit fog emitters pass this read-only native ownership and
placement check. This verifies effect placement, not opaque rock support or a
complete particle-shader decoder. Unowned or altered effects are not exempted.

The fresh guard-320 primary repeat completed. All 26 surface findings, both
underground wonders and all 38 cave-ins pass the composition comparison; all
three post-generation fog attachments pass their native recipe check. The old
physical-support findings remain visible as inherited vanilla features, not
newly invented support proofs. No expansion-comparison finding remains in this
fresh primary run. This does not certify the other scenarios or every lifecycle.

START to T1 was 118.093 s, underground preparation 233.433 s, and separate pose
preflight 2.142 s. Guard 319 measured 117.230 s START to T1, 231.512 s underground
preparation and 1.810 s separate pose preflight. These are diagnostics-enabled
single runs, not release averages or an under-60-second pass. All 35 current
host fixture files passed for guard 320. The 43 deployed payload files match byte-for-byte;
the other four scenarios remain held and diagnostics are not disabled yet.

The post-generation recheck exposed a diagnostic-only coefficient precision
problem in guard 320: all 38 cave-ins were falsely reflagged once live native
bone matrices replaced preparation-time matrices. Direct comparison of every
rendered vertex measured at most 0.137979 world units displacement; the complete
affine box bound was at most 0.140108. Guard 321 compares that full world-space
bound using the unchanged two-world-unit contact tolerance. It cannot approve
a distant fragment simply because the matrix coefficients differ only slightly.
The new precision fixture was red before implementation; all 36 host fixtures
and production syntax now pass. The full guard-321 post-reload lifecycle census
completed with 625 valid physical/effect entries and all 40 remaining native
formations composition-verified: **zero unresolved expansion comparisons**.
Physical counts (37 confirmed gaps, three inconclusive support relationships)
remain intact as inherited native evidence, not hidden or relabelled support.
The three fog entries are now valid through the normal validator path. Recheck
cost was 82.387 s plus 1.840 s pose preflight; these are diagnostic lifecycle
costs, not START-to-T1 or fresh preparation measurements. No fresh guard-321
timing series or five-scenario release certification is implied.

Earlier primary evidence below is retained with its original guard and scope.

The user explicitly requires preserving vanilla composition; additional support
stones are permitted only for top-ups, not beneath original cave-in rubble. The
105-position native-rubble support plan is therefore not applied. The earlier
three-stone trial was removed. A read-only passability check at its three measured
fragment-bottom positions finds all three impassable for both ground drones
(pathfinding class 2) and rovers (class 1). This is point-passability evidence,
not exhaustive traversal proof around every fragment.

The current guard-318 primary lifecycle repeat completed and restored its own
checkpoint: save/load, both map switches, entrance commitments, six actual
rover moves (three types on each layer), and newly spawned cave-in settling.
Both layers remain 8192 by 8192. The new cave-in kept its native two-part mesh
descriptor and 53-cell gameplay footprint. Its geometry check still reports
defects: lifecycle success is not a geometry or release pass.

Diagnostic pose-reference cleanup now verifies native deletion, retains ownership
of surviving references across cache resets, and refuses a verified cache while
cleanup is incomplete. Native fault injection rejected two ignored-deletion
attempts without accumulating references, then recovered with all references
removed and the map object census unchanged. The 43-file deployed payload matches.

The primary-first order remains enforced operationally: only **15S67E** is being
advanced. The other four cases remain held, including Test2 / 30S146E.
The guard-318 post-switch snapshot initially lost the transient top-up flags on
the inactive surface, but a read-only exact-pose ledger audit recovered all
3,145 cosmetic top-ups, with no missing or ambiguous identities. A second
snapshot also checked current-pose uniqueness before using that saved evidence;
it changed no object fields. The corrected comparison has zero unattributed
cosmetics and retains all 16,085 surface and 644 underground vanilla counterparts,
with no missing objects or XY/scale/orientation/render-transform mismatches.
Sixty additional source-stamped surface keys and 142 underground vertical
residuals remain explicitly reported. These comparisons do not resolve support.

Read-only topology inspection confirms genuinely open authored meshes around
the unresolved wonder fragments, not simply inconsistent triangle winding.
Distance trials found several surface-to-surface separations of tens of world
units. They did not change the two-world-unit acceptance tolerance. Whether a
fragment is enclosed by an open surrounding formation remains unverified;
lack of triangle contact alone is not a new confirmed floating-object defect.
The compiled game also returns no Lua authoring preset for its live fog effects.
The three Bottomless Pit fog carriers have native attachments and no mesh
override, but this is not full rendered-particle coverage. No particle exemption
or artificial closure has been added to make the report pass.

Guard 318 tightens negative terrain proof using complete triangle intervals,
not sampled misses. It confirmed two of guard 317's unresolved native surface
fragments. Their rigid corrections lower only the affected object by 117 and
64 world units; native XY, scale, orientation and meshes stay unchanged and
each component retains at least half its previously visible extent. A native
forced-failure test restored both exact poses and repair records. Independent
checks then accepted both corrections, leaving zero confirmed surface defects
and **26 unresolved findings**. This is not a primary-case release pass.

The candidate-placement guard now shares the complete triangle BVH and also
rejects complete containment inside another closed rock. Its red/green fixture
exposed the old surface-crossing-only gap. The two-object live correction took
0.754 s, versus 24.216 s for the old pairwise triangle loop. Release-mode scoped
construction/correction produced identical poses in 9.790 s and passed a
separate full verification. Neither number is a START-to-T1 benchmark.

Native cave-in pose references can be translated beneath the current view;
the live preflight passed in 1.714 s with exactly unchanged camera positions
and all 34 references cleaned up. No animated mesh is rewritten. New-stamp
cleanup now attempts and verifies all owned removals even after one failure,
cleans up partial returned prefab results, and delays publication until flags
and placements succeed. Fault injection covers failed, ignored and repeated
removal. Guard-318 underground preparation completed in **222.170 s**, with an
additional **1.770 s** separately measured diagnostic pose preflight. This was
continued from guard 317's fresh surface (113.129 s START to T1), not a fresh
guard-318 end-to-end timing pair. The underground remains 8192 square, all
17 blockers corrected, and the initial report has 622 valid, 38 confirmed
cave-in findings, and two inconclusive wonders. Post-generation effects still
require their later lifecycle census; their absence from this initial report
is not a pass. The release <60 s gate remains unmet/unmeasured in release mode.
All 43 payload files match after retrying a transient read-lock failure during
the first post-copy audit. All 30 host fixtures and production syntax pass.

An additional reversible primary-surface experiment identified a lost authored
contact in `Decor.Slate.CliffMedium_05`: the small slate stone at (392801, 256062)
was originally supported by the neighbouring slate rock at (389245, 258708).
The top-up path discarded each native placed Z. Restoring scaled ground offsets
alone did not restore that edge. Applying a common XYZ similarity did: the
stone and all three support-rock LODs passed, with the original source contact
preserved. Exact original placements were restored afterward. This proves that
pair, not a universal placement correction. Guard 315 was rejected: it also
lifted native terrain-relative scatter. Its long-running owned test was explicitly
stopped after the separate regression was reproduced; it produced no T1 result.
The exact cause of its long runtime was not established and it was not a crash.

A smaller native prefab comparison isolated the problem. All 183 native objects
passed. The broad transform produced 42 confirmed defects and 38 inconclusive
objects; retaining terrain-relative placement reduced this to four and five.
Neither candidate was accepted. A support-island construction planner now keeps
connected objects together and seats their verified terrain roots with one common
vertical shift, while retaining every component's visible extent. Both the
prototype and production planner passed all 183 objects with zero findings and
all original contacts preserved. Every temporary prefab object was removed.

Diagnostics-on and diagnostics-off returned identical production plans. The
latter took 0.631 s for this prefab, wrote no baseline/report/progress record and
moved no objects. Independent verification still passed all 183. This is scoped
construction work required for correct placement, not the exhaustive post-map
audit that will be disabled after the five-case campaign. Guard 317 integrates
it after cosmetic/boundary filtering and rejects/cleans up an unplaceable new
stamp rather than leaving unsupported additions. Fresh **15S67E surface-only**
generation completed in **113.129 s START to T1**, diagnostics enabled. All
99 target groups were placed (63 authored, 36 synthetic); 11 unsafe candidate
stamps were discarded and replaced through the existing search. Construction
support planning took 14.407 s, separately from exhaustive final diagnostics.
All 39 prior top-up findings are gone. After one verified native stone correction,
the surface reports 19,561 valid, zero confirmed defects, and **28 unresolved
native dark-rock groups**. These are not a pass. The fresh native comparison
retained all 16,085 counterparts, with no missing objects or XY, scale,
orientation, or render-transform mismatch. No underground timing exists for
guard 317 yet. All 28 host fixtures pass; full-map/lifecycle acceptance is pending.

The newest guard-314 / sector-80 fresh **15S67E** run measured **101.339 s START
to T1** and **222.535 s underground preparation**, with exhaustive diagnostics
enabled. It automatically verified all six surface corrections (3.613 s for that
correction pass, no rejection), leaving 19,970 valid surface instances, zero
confirmed defects and 67 inconclusive before later gameplay markers. Seventeen
blockers were corrected again. The native comparison retained all 16,085 surface
and 644 underground counterparts without XY/scale/orientation/render-transform
mismatches. The same 142 underground vertical residuals remain to investigate.
These results do not certify the unresolved geometry or the release timing.
All 43 payload files are locally synchronized; no commit or push has occurred.
The guard-314 lifecycle repeat subsequently completed save/load, both switches,
all six rover-command movements, entrance checks and restoration. The previous
sector-notification error did not recur at the previously failing surface-switch
step. The newly spawned cave-in remained a confirmed geometry defect, so this is
not a full primary-scenario release pass. Its restored test save is
`SBM Five Release 15S67E 102759499.savegame.sav`.

The guard-313 fresh **15S67E** diagnostic run measured **104.746 s START to T1**
and **165.135 s underground preparation**. This is not a diagnostics-off release
benchmark and does not meet the release preparation target. Both layers are
8192-square. The subsequent lifecycle repeat passed save/load, both switches,
six actual player-command rover movements, and both entrance commitments after
loading, switching and restoration.

All 17 tunnel blockers passed the current candidate's independent geometry check.
One representative passed all five native clearing states and final removal;
restoring a new disposable save restored all 17 in their verified initial state.
Host rollback fixtures cover refused records, native mutation failures, failed
verification and failed rollback. These results close the **primary-case** blocker
clearing/save-load gate, not the other four scenarios' gates.

The last confirmed surface cluster defect was a partly buried top-up foundation
plus a detached small stone. Its old planner required half of the entire authored
foundation to be exposed, even though less than half was visible before repair.
The candidate now snapshots each top-up component's original visible height and
retains at least half of that height (capped by the mesh's full extent), with a
positive minimum for every component. This does not allow burying an exposed tip
or reducing a candidate's own visibility requirement during searching. Native
objects keep their previous placement policy. Red/green fixtures exercise both
the partly buried foundation and the forbidden exposed-tip counterexample.

The live cluster moved only from Z 7999 to 7924 (0.75 m); XY, scale and geometry
were unchanged. Independent verification passed in the 0.455 s targeted correction
run, and its exact placement, top-up role and correction evidence survived
save/load. The current surface report is **20,011 valid, zero confirmed defects,
67 inconclusive**. Inconclusive does not mean defect-free.

The underground still has **38 confirmed cave-in findings and five inconclusive
instances** (two wonders and three fog-effect carriers). A newly spawned cave-in
retained its native descriptor and footprint, but its fragment verification did
not pass. No release completion is claimed. The blanket 0.70 m cave-in lowering
experiment was restored and rejected: it would bury small previously visible
tips in six of the 38 native formations. Native animated meshes remain untouched.

The clean same-seed native control matched 16,085 surface and 644 underground
counterparts with no missing object or XY/scale/orientation/render-transform
mismatch. Vertical residuals and support findings still require investigation.
The loaded Bottomless Pit fog authoring source matches the inspected sprite-only
source, but that alone has not been promoted into a compiled-effect certificate.

All 26 current host fixtures and production Lua syntax checks pass. The new
terrain-face witness test detects face-interior contact, but the live primary
recheck resolved no findings and took 68.289 s underground; that diagnostic cost
must not be presented as release timing.

The primary lifecycle log's sector-notification invalid-object error has a native
red/green reproduction: MapObject-created notification workers outlive a deleted
sector. The candidate now cancels only a discarded sector's worker before deleting
it, retains active sectors' workers, and defers destruction if cancellation fails
or the worker is the current caller. The live fixture reproduced the old orphan
worker and verified its cancellation with the new cleanup. The guard-314 fresh
lifecycle repeat then passed its functional checks without the previous error at
the previously failing surface-switch step.

A reversible trial added three small native slate stones beneath one cave-in's
detached fragments. All 110 cave-in components and all three support stones passed
current physical-support checks. No native animated descriptor, cave-in position,
terrain or gameplay state was changed. Removing the stones restored the original
defect. This remains an experiment, **not production code**: adding support stones
changes vanilla composition, and the user's preference is pending. It is not a
completed correction, visual sign-off or a source-preservation pass.

The other four cases remain held. No release commit or push has occurred.

### Sequencing and release policy

Latest sequencing: solve **15S67E first**, the hardest case observed so far, and
make it release-ready before testing the other four. This case covers Bottomless
Pit, Crystal Cave, cave-in fragments, and the reproduced post-load entrance
validation failure. The remaining four are 14N134W, 60S120W, 20S45E and Test2's
30S146E. Existing partial results are retained, not counted as completed gates.

Release policy clarified by the user: run exhaustive diagnostic checks for the
five selected scenarios first, on both surface and underground. After that
campaign passes, disable those checks on both layers in the release configuration
and benchmark that configuration. Underground
preparation must be below **60 seconds**; `4c22d2a` is the comparison baseline.
Do not report diagnostic-build timings as release timings, or disable diagnostics
before the campaign passes. Disabling the reporter must not disable the actual
placement corrections or their transactional rollback.

The candidate now has a correction-only evidence scope independent of the
exhaustive diagnostic switch. It retains candidate and nearby support checks,
unknown-object bounds, and independent post-move verification. It neither
replaces the full diagnostic report with a partial pass nor invents source
baselines. Host fixtures exercise this for both layers, including legitimate
stacks and unknown-neighbour vetoes. Live release-configuration verification and
timing are still required; diagnostics remain enabled in the configuration.

15S67E's completed diagnostic-enabled run measured START to T1 **94.433 s** and
underground preparation **163.131 s**. Both layers remain 8192-square. Save/load,
both switches and six real rover-command moves passed. Its 43 underground
geometry findings and newly spawned cave-in pose coverage are not passes.

The independent post-load entrance audit reproduced a stale sandbox `MainMap`
shadow: actual pairs were reciprocal, both underground anchors retained their
truth hexes, and surface sites were the nearest valid rings (6 and 9), but the
commitment validator compared their map to a destroyed pre-load map object.
The new engine resolver retains live temporary source maps and resolves released
ones through the live registry. A host red/green test and read-only invocation
against this live save changed the same production commitment check from failure
to success for both pairs, including terrain validation. The guard-311 and
guard-313 fresh lifecycle repeats subsequently passed the same checks.

The 144.840 s 14N134W diagnostic run includes 45.533 s source-support capture,
27.148 s final validation, and 20.598 s post-correction validation (93.279 s total).
The remaining 51.561 s is an arithmetic breakdown, not a measured diagnostics-off
run or proof that the below-60-second requirement has been met.

The current candidate adds a separate native tunnel-blocker transaction. It
verifies the static asset and original rendering descriptor, preserves the
native footprint and clearing work, seats the building by 0.44 m at 133% scale,
and keeps its unmodified native LOD0. A failed mutation or independent geometry
check restores position, LOD, annotation and grid membership. A failed rollback
is an explicit preparation failure, not a successful correction.

The 17-blocker live trial passed. A new disposable save preserved all 17 through
save/load and both map switches. One blocker passed all five real native clearing
states, final removal, and restoration from that test save. Fresh-process repeat
and the complete five-scenario release campaign remain outstanding.

The earlier 24 host compatibility fixtures and all production Lua syntax checks passed.
New coverage includes refused evidence records and injected failures in removal,
positioning, LOD changes, grid restoration, validation and rollback. Triangle
contacts now include exact edge-to-edge distance; attached wonder architecture
is inspected rather than counted as unknown bounding-box support.

The first clean-process candidate generation, 14N134W, retained both 8192-square
layers: START to T1 **90.898 s**, underground preparation **144.840 s**. Its final
underground check had 642 valid, zero confirmed defects and 44 inconclusive
instances. These unresolved findings, plus source-support preservation findings
on the surface, are not a release pass. An earlier post-reload attempt failed the
outer-effect placement census before T1 at 83.643 s; that failure is retained and
is not included as a successful timing run. The cause is not yet established.

The earlier guard-311 candidate was locally deployed (43 matching payload files),
not committed or pushed. Experimental enclosure proofs are diagnostic scripts only and are not
part of the mod. Historical completed campaigns below do not certify these newer
changes.

Native reference pose verification now covers all integer idle phases and the
terminal non-looping falling state (the engine returns eDontLoop as signed
-32768). Unknown flag combinations still fail closed. An owned 15S67E trial
verified 4,290 component transforms including a newly spawned settled cave-in;
the reference preparation took 1.842 s. Camera visibility affects the native
pose API, so a deliberate reference view is required for this diagnostic
preflight. This proves pose availability, not support of the remaining fragments.

## Correction follow-up: measured results and remaining limits

The separate `sbm_decoration_seating.lua` service now plans narrow corrections for
confirmed, fully inspectable, unsupported surface cosmetic rocks. Native stones
retain XY, scale, rotation and mesh; only their vertical placement can change.
An extra top-up cluster may move to nearby terrain of the same type inside its
original allowed band. Every connected component and LOD must touch terrain and
retain independently bounded visible height, including already buried foundations
as described above. A spatial index plus triangle separation checks rejects
overlap with nearby objects. Attachments, dependent stacks, animated geometry,
unknown coverage and functional underground blockers are not moved.

The read-only validator independently checks each actual correction. Failure or
missing evidence restores the original position and correction annotation.
Source support records are never rewritten: a verified correction is reported
separately from preservation of native support, and survives exact save/load
ledger rebinding. Corrections run before the authoritative final grid rebuild.

Read-only rigid, single-bone skin inspection now uses validated native weights,
inverse bind matrices and current visual bone transforms. Connected components
cannot be welded across different bones. Missing poses, non-rigid weights,
moving animation and unsupported transforms remain inconclusive. Decoded meshes
and triangle trees stay shared; no GPU mesh/resource is modified or uploaded.

The follow-up passes 22 host compatibility tests and syntax checks for every
changed Lua file. The final-candidate campaign has repeated all four known
problem maps and independently verified 11 narrow corrections, with no rejected
or rolled-back correction and zero remaining confirmed surface defects there:

| Map | Verified corrections | START to T1 |
| --- | ---: | ---: |
| 10N20E | Five native stones; XY unchanged | 89.867 s |
| 60S120W | One native tiny stone; XY unchanged | 88.816 s |
| 5S170W | Four top-up stones; XY unchanged | 94.880 s |
| 20S45E | One top-up cluster moved to safe nearby ground | 82.568 s |

The previously inconclusive tiny stone is now confirmed and corrected using a
bounded transform/terrain error test. The cluster retains its complete mesh,
scale and orientation; every component and LOD contacts ground and retains
visible height. A cold save/load and both map switches preserve its verified
correction. Cold load plus validation took 38.171 s (not START to T1); the initial
underground recheck took 11.818 s, followed by 1.814 s surface and 5.846 s
underground switch rechecks. A newly spawned cave-in retained its native
53-cell footprint and original descriptor, remained unclipped while falling,
and received the narrow high-fragment clip only after settling.

The normal-window rendering exercise covered 18 views, six zoom distances and
three centers, holding each view for 12 seconds at 1920 by 1080. All 38 rubble
instances retained the original two-part descriptor. Sampled normal-window
views showed no giant triangles; this is not continuous video certification.
DLSS/TAA stayed enabled. Resolution, darkness, camera and speed were restored.

Paired targeted views of all four wonder types match their native formations,
with small terrain-resampling differences. Static tunnel-blocker fragment gaps
are reported separately: many are also confirmed in native source capture;
others had inconclusive native support. No confirmed gap examined so far had
proven native support that expansion broke. Functional blockers are not moved.
Unavailable poses, unsupported shader transforms and unresolved support remain
inconclusive, never silently passed.

The final follow-up campaign completed all 20 varied expanded seeds and nine
repeated reference runs (three per seed), on game revision 403908. Both layers
retain 8192 by 8192 terrain. The current reference arithmetic averages are:

| Reference seed | Baseline START to T1 | Current START to T1 | Additional cost |
| --- | ---: | ---: | ---: |
| 14N134W | 79.177 s | 86.410 s | 7.233 s |
| 24S97W | 79.374 s | 94.142 s | 14.768 s |
| 65S11W | 73.384 s | 81.192 s | 7.807 s |
| All nine runs | 77.312 s | **87.248 s** | **9.936 s** |

Underground preparation averages **56.329 s**, separately, versus 47.970 s
baseline. The provisional additional-one-second START-to-T1 target is **not met**.
The previous diagnostic candidate averaged 85.938 s START to T1 and 60.531 s
underground preparation: this follow-up did not improve the measured START-to-T1
average, although underground preparation was faster. The slow 99.895 s third
24S97W run is retained in the arithmetic mean, not discarded. No checks were
disabled or postponed beyond T1. The varied 20-seed average is 88.176 s START to
T1 and 57.203 s underground preparation, not a replacement for the reference mean.

The 20-seed diagnostic census records 359,111 valid surface instances, zero
confirmed surface defects and 33,326 inconclusive instances. The 11 reproduced
surface defects were independently corrected. Underground: 9,089 valid, 89
confirmed tunnel-blocker instances with small separated fragments, and 2,710
inconclusive. Of those 89, all reported defective components of 74 instances
were also confirmed defective in native source capture; the other 15 include
inconclusive native support. No confirmed gap had a proven native support contact
that expansion broke. These additional functional-blocker findings remain
unfixed; their gameplay geometry is not guessed or silently moved.

Nineteen surface cases match the full vanilla sequence: 302,141 counterparts,
no missing instances or unexpected XY/scale/orientation/render-transform changes.
All 20 underground cases similarly match 11,888 counterparts. The final 70N10E
surface instead matches the independently repeated 12,121-object vanilla layout
exactly (three retained controls), not the distinct 12,510-object vanilla sequence
layout. Both layouts also occur without expansion; the native trigger remains
unconfirmed. The full-sequence mismatch and every control are retained explicitly.
All four wonder types were covered; inspected native terrain-cut/shape triangles
retain their scaled counterpart within 1.13 world units of rounding error.

No validator failure occurred during the final campaign. Three native
`SetRenderMode("scene") invalid while no map is loaded` messages occurred between
reference scenarios; this had also occurred in baseline testing. A separate
one-time harness undefined-global warning used its successful saved-report
fallback; its helper was corrected without changing production behavior.

The final reload-guard/changelog update was followed by a fresh-process 20S45E
smoke test: START to T1 **85.365 s**, underground preparation **56.473 s**.
Both layers remained 8192 by 8192, the cluster correction independently passed,
surface confirmed-defect count was zero, and all 38 cave-ins retained their
native two-part mesh identities and settled fragment clips. The 22 host tests
and changed-file Lua syntax checks also pass. The internal closure guard is 309;
the local mod payload contains 42 files and was audited byte-for-byte.
The clean pre-injection inspection save was reloaded and left paused on the
underground map, with darkness 90 and both terrain dimensions rechecked. The
computer-use window check showed no giant triangles in that sampled frame;
it is not additional continuous flicker evidence. No user save was overwritten.

Placement corrections run only during fresh generation, before the final grid
rebuild. Existing saves receive read-only lifecycle checks, not automatic object
movement. Missing source evidence remains inconclusive. Console hardware,
unseen seeds, unsupported shader geometry and continuous temporal stability
are not universally certified. The known surface corrections and finite tests
must not be described as an all-decoration/all-seed guarantee.

Full local evidence is in `repair_acceptance_summary_repair_checked.json`,
`decoration_twin_comparison_repair_checked_vs_sequence.json`,
`native_layout_variation_70n_repair_checked.json`, the lifecycle reports and
`repair_checked_visual_review.md` under `_ralph/tools/compatibility/`.
The section below preserves the earlier diagnostic campaign for comparison;
its unresolved surface findings and timings are historical, not current results.

## What is checked

- Capture native support before the existing expansion transformation, including
  native prefab top-up groups before their offsets/scales change.
- Inspect the actual per-instance render descriptor and every available LOD. Cache
  decoded shared mesh resources, connected components and triangle-search trees.
- Check each instance's transformed placement. Terrain contact requires an actual
  rendered vertex; native terrain-cut triangles exclude hidden height-field support.
- Spatial buckets restrict object/ceiling contact searches to nearby geometry.
  Stacks need a path to terrain or an attachment, not an unsupported cycle.
- Compare native and expanded terrain/object/attachment/ceiling support identities.

Results are **valid**, **confirmed defect**, or **inconclusive**. Sparse sample
misses are not proof of a defect. A disconnected component is confirmed unsupported
only with a native terrain-height bound and complete absence of nearby support;
broken native attachments are also confirmed defects. Missing meshes, unknown
instance overrides, unavailable animated bone poses and unsupported rendering transforms never
count as valid. Invisible editor authoring markers are not gameplay decorations.
Projected decal volumes (including unexplored-sector overlays) are not physical
supports or floating rendered triangles. Materials with alpha cutouts, projection,
vertex deformation or unavailable metadata remain inconclusive. Mesh/material
identity is part of the per-instance cache key; lifecycle checks retry failed
resource reads while retaining successfully decoded shared geometry.

Positive contact tolerance is at most two world units (1/50 terrain tile). Negative
terrain-separation proof pads its query rectangle by a height-grid tile and uses a
full-tile conservative vertical margin, refined for small meshes only when a
smaller bound covers native transform rounding and decoded mesh quantization.
A lazy census excludes uncaptured late
supports before confirming separation. These tolerances and
per-instance findings are included in each report.

## Lifecycle and persistence

Fresh checks run inside the existing generation pipeline, before surface T1 and
separately before underground preparation completes. Generation checks do not yield
inside suspended native pass-edit transactions. Lifecycle work uses bounded yielding.

On load, relevant geometry is reconstructed; on map switching, unchanged positive
witnesses can be reused while changed/unverifiable instances, nearby supports and
dependents are checked. New cave-ins are captured after native initialization and
checked again on settling. No gameplay animation state, damage or footprint is changed.

A saved, value-only map ledger preserves source evidence for permanent objects whose
custom Lua fields the engine does not serialize. Restoration requires an exact,
unique placement key. Missing or ambiguous matches remain inconclusive. Old saves
without source evidence cannot establish native-support preservation retroactively.

Reports are available as `map.SuperBigMapDecorationValidation` and per-instance
`object.SuperBigMapSupportValidation`; summary lines include source-capture and final
validation milliseconds. Errors are explicitly reported as inconclusive.

## Narrow cave-in rendering correction

The investigated game asset has an unskinned fragment approximately 493–499 metres
above its pivot, alongside animated ground rubble. Removing its mesh slot was
associated with the reported intermittent giant triangles. The candidate retains
the original two-part native descriptor and clips only the proven high fragment in
the settled pose. An exact mesh signature guards this correction; changed assets
and foreign clip planes are left alone. Native falling animation is not clipped.

The validator still marks unresolved animated rubble support **inconclusive**:
availability of current bone transforms does not establish missing native source
evidence or prove every fragment has a support contact.

## Earlier diagnostic campaign (before the active correction follow-up)

The 20 host compatibility tests pass, including stacked rocks, overhangs,
attachments, split columns, isolated floating geometry, unknown geometry, exact
terrain cuts, saved-ledger restoration and transient surface-readiness handling.
Live fault injection, load/switch and native cave-in lifecycle tests are recorded
under `_ralph/tools/compatibility/` (local diagnostic artifacts, not mod payload).

Twenty fixed vanilla/expanded discovery pairs and twenty final expanded cases
have been generated. Both layers retain 8192 by 8192 terrain. All twenty final
underground and surface comparisons match the repeated full vanilla sequence:
314,651 surface and 11,888 underground counterparts, with no missing native
objects or XY/scale/orientation/render-transform mismatches. Extra source-stamped
surface objects and top-ups are reported separately rather than discarded.

70N10E reproduces two layouts in vanilla despite the same recorded seed and
generator parameters. Fresh controls and a same-process expanded pair match the
12,121-object layout; the repeated full vanilla sequence and final expanded batch
match the 12,510-object layout. Earlier mismatches are preserved in the evidence.
This establishes that the layout variation also occurs without expansion; its
precise native cause is not established.

The final validator confirms four native small-stone gaps in 10N20E, three
top-up stone gaps in 5S170W, and a lower-detail top-up mesh fragment in 20S45E.
Targeted inspection also identified a small native
stone gap in 60S120W; the final conservative terrain bound leaves this ninth
finding **inconclusive**, not valid. Same-seed vanilla controls contain the five
native stones. These findings have not caused automatic placement changes.
The 20S45E cluster was reproduced separately and inspected from three angles:
some components intersect terrain while a disconnected stone is visibly above
it. Its vertices have at least 570 world units of clearance in both available
LODs. The conservative test confirms separation for the lower-detail component
and leaves the higher-detail component inconclusive. This is a per-fragment
finding, not a claim that the whole cluster is unsupported. Reproduction
START to T1 was 81.492 s.

The final deployed code passes a live elevated-rock fault injection: all three
render LODs report a confirmed defect, and restoring the original placement
returns the object to valid. The fixture is an identity control, not a substitute
for the independent vanilla comparisons. Warm save/load, both map switches and
native cave-in spawning/settling also pass. Native animation remains unclipped
while falling, keeps its original two-part descriptor and 53-cell footprint,
and receives the narrow fragment clip only on settling. Unknown animated pose
support remains inconclusive. A fresh-process repeat passes the same load,
switch and cave-in checks. Cold load plus its validation took 43.188 s, with
14.862 s spent in the initial underground recheck; subsequent surface and
underground rechecks took 3.776 s and 4.268 s respectively. These are not
START-to-T1 measurements.

The repeated timing series is complete (three runs per seed, arithmetic means,
same reference driver and game revision 403908):

| Reference seed | Baseline START → T1 | Candidate START → T1 | Additional cost |
| --- | ---: | ---: | ---: |
| 14N134W | 79.177 s | 86.940 s | 7.763 s |
| 24S97W | 79.374 s | 90.118 s | 10.743 s |
| 65S11W | 73.384 s | 80.756 s | 7.372 s |
| All nine runs | 77.312 s | 85.938 s | 8.626 s |

Underground preparation is separate: 47.970 s baseline versus 60.531 s candidate
on average. The provisional **≤1 s additional average START → T1 target is not
met**. No checks were disabled to improve these numbers. Two native
`SetRenderMode("scene") invalid while no map is loaded` messages occurred between
automated scenarios; this also occurred in baseline testing. No validator failure
occurred in the timing series.

The twenty-seed final batch averaged 89.248 s START to T1 and 55.919 s underground
preparation; this varied-seed average is not the repeated reference comparison
above. The normal-window 1920 by 1080 rendering exercise completed eighteen
views at six zoom distances across three centers, holding each for twelve
seconds without engine screenshot calls. All 27 cave-in instances retained
their original two-part descriptors and settled clips throughout. The sampled
normal-window view showed no giant triangles. This is not continuous video
verification or a reliable fresh-process red/green reproduction of the original
intermittent flicker. The earlier user-observed live isolation test was stable
when the original descriptors were restored.

The temporary display mode, darkness, camera and speed were restored. DLSS and
TAA remained enabled. The clean pre-injection test save was reloaded and left
paused, removing test reveals and spawned diagnostic objects. No user save was
overwritten. The local mod payload matches the 41 source files exactly; this
candidate has not been committed or pushed (base commit `18db76d`).

The requested diagnostic implementation and finite test campaign are complete,
not a release certification. The recorded decoration defects remain report-only;
animated bone poses and other unavailable rendering information remain
inconclusive. The loading-overhead target was missed. No universal seed or
console-hardware guarantee is claimed, and absence of a visible artifact in a
screenshot does not prove temporal render stability.

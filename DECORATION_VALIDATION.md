# Decoration support diagnostics (candidate, not release-certified)

The validator reports geometry/support evidence; it does not move, resize, delete,
reveal, or repair decorations. `DecorationValidation` in `sbm_config.lua` controls
the diagnostic pass. It is enabled in the current investigation build.

## Correction follow-up: measured results and remaining limits

The separate `sbm_decoration_seating.lua` service now plans narrow corrections for
confirmed, fully inspectable, unsupported surface cosmetic rocks. Native stones
retain XY, scale, rotation and mesh; only their vertical placement can change.
An extra top-up cluster may move to nearby terrain of the same type inside its
original allowed band. Every connected component and LOD must touch terrain and
retain visible height. A spatial index plus triangle separation checks rejects
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

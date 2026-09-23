# Full-rules verification — 2026-09-23

Current build: **460 / metadata1091: runtime and lifecycle PASS**.
The owner authorized the local checkpoint and recoverable archive on2026-09-23.
This checkpoint contains the tested build, regression tests and this report;
no game-code change, new game launch or push is part of the administrative follow-up.
Historical artifacts are archived outside the workspace with a checksum manifest;
the current matrix, lifecycle evidence and scripts remain in place, and `_ralph`
is below2GB. See the archive and checkpoint provenance section below.
No `DONE.md` asserting retroactive compliance with the old contract is created.
All five current-candidate A/B/control cases pass captured runtime gates and
both timing limits. Full paired terrain/pass-grid/site/pad/corrected-rock state
equality pass. All five save/in-process reload/fresh-process load cases also pass:
exact deferred-mask persistence and consumption, committed entrance links/poses,
all corrected rock poses, fresh positive support censuses on both maps, and all
three temporary buttons. All25 accepted sessions have clean owned shutdowns,
unchanged43-file payloads and unchanged authorized displays during each run.
`five_runtime_audit.json` and `runtime_lifecycle_audit.json` have passing runtime
booleans and no failures. Their original `accepted=false` process-review snapshots
are preserved; `checkpoint_followup_audit.json` records the later checkpoint,
payload identity, deployment, archive inventory and size checks separately.
Source RNG review passed for the tested build: `_ralph/tmp/seed_source_audit_460.md`.

## Archive and checkpoint provenance

The recoverable archive is
`D:\PROJS\SMR\super-big-map-test-archive\checkpoint-460-20260923`.
Its `manifest.csv` preserves each original workspace-relative path, byte count
and SHA-256 digest.8002 historical files (14,273,130,340 bytes) were moved,
not deleted; hashes are checked before and after the move. Tracked source-review
files were retained in the workspace. The archived groups are old untracked
files from `reoptimize-under-70s`, `manual-rocket-crease-transactions` and
`manual-rock-grounding`, historical compatibility PNG/JSON outputs, and temporary
raw terrain dumps. To find an older referenced artifact, prepend the archive
directory to its original workspace-relative path. Restore only that specific
file after checking that its original destination does not already exist.

The25 native sessions preceded this checkpoint; their original recorded HEAD
`d753556` is not rewritten. The later audit proves that all43 measured payload
files are byte-identical and correspond to committed content (allowing Git's
normal line-ending normalization). This closes the newly authorized checkpoint
and artifact-size follow-up; it does not pretend the historical launches were
made after a commit. The latest user scope is five scenarios and both loading
limits, not the old contract's ten-site/no-performance scope.

Recheck with `python _ralph/tools/rules/audit_checkpoint_460.py`; the result lives
beside the current runtime evidence. The local checkpoint hash is also recorded
in `_ralph/runs/rules-parity/ATTEMPTS.md`. No published version or remote is changed.

## Lifecycle verifier notes

17S11W's save/in-process reload passed at74.058/56.036s with exact mask bytes
and unchanged entrances. The first fresh-load verifier falsely rejected a
native angle normalization (-18548 to3052, same axis/XYZ, exactly21600 units).
Its native callback swallowed the first assertion and later reported the rock
as missing; a read-only reload confirmed all81 exact positions. The verifier
now compares exact whole-turn equivalence and reports callback findings after
enumeration.4114 focused angle/axis checks and the fresh-load retry pass.
No production change or relaxed support/position tolerance was made. Failed
verifier/diagnostic artifacts remain preserved; the diagnostic's separate
assert-return-value assumption was corrected before any further use.

| Site | Surface A / B seconds | Underground A / B seconds |
| --- | ---: | ---: |
|15S67E|67.232 /67.356|48.134 /48.303|
|24S74W|68.900 /70.060|51.082 /51.138|
|45S120W|67.321 /68.303|44.910 /45.058|
|61N136W|73.055 /71.868|49.245 /47.866|
|17S11W|74.776 /74.687|57.391 /56.886|

| Site | Save-run surface seconds | Post-reload underground seconds | Corrected rocks retained on fresh load |
| --- | ---: | ---: | ---: |
|15S67E|66.332|46.885|16|
|24S74W|69.890|50.349|7|
|45S120W|68.674|44.351|86|
|61N136W|71.888|46.849|6|
|17S11W|74.058|56.036|81|

Worst across all15 expanded generations: **74.776s surface /57.391s underground**.
All rock seating and independent readiness verification finish beforeT1.
No authored-floating exemption remains.17S11W's fresh load verifies29,677
surface rocks and507 underground rocks positively supported before/after the
reveal-button sequence, with all81 repaired poses retained.

460 projects both contact BVHs onto the same native-neighbour unit axes for
tighter conservative pruning. World-space triangle/contact predicates are
unchanged; floating-point slack only retains extra candidates.460 closed-game
61N136W passes at **73.055s surface /49.245s underground**, including support
and the other captured runtime gates.17S11W passes its first closed-game run
at **74.776/57.391s**, with81 successful pre-T1 repairs, all captured support
and runtime gates passing. Its fresh B run passes at **74.687/56.886s**;
the matching unexpanded control also completes cleanly. A/B runtime parity
and full terrain/pass-grid/site/pad/rock-state equality pass across all five sites.
Evidence: `_ralph/runs/rules-parity/strict-460-20260923/failed_sites`.
15S67E expanded A/B surface times are67.232/67.356s. Its first control
startup was excluded: the display guard observed Windows change from3840x2160
to1024x768 before scenario generation and closed the owned process cleanly.
Windowed mode remains configured; the cause is not established. Evidence is
preserved as `15s67e_control_startup_display_failed` (nothing deleted).
Under the owner's later current-resolution authorization, subsequent launches
explicitly guard the now-current1024x768; no Windows setting API was called.
79 compatibility
fixtures, all Code Lua syntax and18 judge tests pass; the contact fixture adds
320 changing-neighbour-frame checks against fresh independent reference poses.
## Historical459 and earlier diagnostics (not current acceptance)

459 full closed-game17S11W: **76.494s surface (FAIL),57.077s underground
(PASS)**; both-layer support, entrances, ring/reveal/decor, first access and
all three buttons pass. Same-payload single-run diagnostics also pass those
runtime gates and both limits at15S67E **68.191/48.075s**,24S74W
**70.928/52.414s**,45S120W **68.977/45.816s** (surface/underground).
61N136W **77.012/48.441s** fails the surface limit; other captured runtime
gates pass. These are NOT A/B/control or lifecycle acceptance.
Evidence: `_ralph/runs/rules-parity/strict-459-20260923`.
459 reuses the initial read-only nomination bounds/hole census; its permission
is explicitly discarded before the correction callback can mutate anything.
Focused fixtures prove changed bounds are freshly acquired after that boundary.
458's normal-hook diagnostic was76.911s, with clean shutdown and all81 repairs.
Normal-hook 17S11W diagnostics:454 77.733s,455 77.517s,456 76.951s,
457 77.241s. All retain81 successful corrections and29,677 positive surface
rocks beforeT1; logs are clean through owned shutdown. These surface-only
profiles do not replace full five-site A/B/control and lifecycle acceptance.
455 avoids unnecessary normalization of overlapping triangle projections;
456 preserves exact depth-first BVH traversal with an explicit stack;
457 tries the previous rejecting component first at each fresh candidate pose.
458 removes unused local-pose capture for unselected world-bounds-only records.
All79 compatibility fixtures, Code Lua syntax and18 judge tests pass458;
454's first diagnostic setup failed before
generation because its nested loader was unavailable; literal setup retry
completed normally. Diagnostic failure artifacts are retained and excluded.
Previous full closed-game run:45317S11W, surface **77.169s (FAIL)**,
underground **57.810s (PASS)**. Both-layer positive rock coverage, entrances,
ring content, initial reveal, decoration rules, first access and all three
temporary buttons pass. Same-candidate A/B/control and five-site/lifecycle
acceptance remain outstanding; no all-rules acceptance is claimed.
Evidence: `_ralph/runs/strict-453-20260923/17s11w_full_retry`.
AtT1:29,677 positive surface rocks; after elevator placement:29,670 surface
and507 underground, zero incomplete/inconclusive/defect findings. All81
targeted surface repairs finish beforeT1.452 delegates the old speculative
surface grounding pass to strict current-geometry seating: the prior285
sample-based lowerings are removed; only two additional strict repairs are
needed. Underground/in-place/missing-service legacy fallbacks remain.
453 fixes fast nomination over terrain-cut holes.78 compatibility fixtures,
Code Lua syntax and18 judge tests pass.454 adds fail-fast rejection of new
prefabs with isolated unsupported components; focused support/fused-placement
fixtures pass; native results are listed above. Windows returned to3840x2160 externally;
tests now explicitly preserve that current resolution, still windowed1024x768.
One452 startup crashed before scenario setup (native c0000374); retry closed
cleanly at76.722s. The first453 launch had a missing fixture path and quit
cleanly without generation; its evidence is excluded. Nothing was deleted.
The historical `_ralph` tree is14.432GiB, over the old2GB limit. Permission to
archive old artifacts outside the working tree has been requested, not assumed.

## Historical443 status (not current acceptance)

Normal-hook 17S11W surface diagnostics:439 80.383s,440 78.361s,
441 78.592s,442 78.327s,443 77.691s. All79 corrections succeed;
29,677 surface rocks have positive support, without native-gap exemptions.
All runs quit cleanly, retain identical deployed bytes during the run, and
preserve the authorized1024x768 display. Timing still FAILS; current five-site
A/B/control and save/load lifecycle acceptance remain outstanding.
438 uninstrumented A/B/control:83.548/83.485s surface (FAIL),
57.723/58.083s underground (PASS), all other runtime gates and paired fields
pass; all29,677 surface and507 underground rocks have positive support.
The earlier435-438 deadline diagnostics replaced an external debugger hook.
Their timings are NOT comparable to normal native acceptance. Production
never changes debugger hooks;439 onward profilers retain the native hook.
440 adds conservative convex-hull interior witnesses and immutable-pose
triangle caches;441 binds access primitives, not live engine values;
442 proves complete affine-box separation before mesh traversal;443 avoids
full native gameplay classification for assets that cannot contain assemblies.
77 compatibility fixtures and18 judge tests pass (18 judge tests last run441).
All five underground seeds are pinned to their recorded strict-support cases.

## Historical438 investigation (not current acceptance)

Current native diagnostic:17S11W, `_ralph/runs/strict-438-20260923`.
17S11W diagnostic stack traces isolate an exhaustive search beside
CliffDark_01_33: approximately1,700 proposals and19.6s on that pair alone by
the25s diagnostic seating deadline.436 tries in-place tilts before tilted XY
searches;437 caches complete separating half-spaces for immutable geometry.
Neither solved this particular blocked formation. Captured native geometry
shows a same-orientation valid proposal10m away, outside the old8m search but
inside the already-selected16m neighbour region.438 searches that full region
on a one-tile lattice before tilting, retaining all terrain-type/visibility/
collision/actual-pose support gates. Native acceptance is pending.
43817S11W instrumented surface diagnostic now completes and quits cleanly:
76.741s START-to-T1,8.886s seating (1.254s nomination,2.391s evidence,5.241s
application),79 corrected,0 rejected,all29,677 eligible rocks positively
supported. The troublesome pair fell from19.6s to0.731s. Its group translated
10m in each XY axis without tilting; meshes/scale and strict gates are unchanged.
This instrumented diagnostic does NOT establish timing acceptance or underground
correctness. The uninstrumented A/B/control case is next.
435 preserves independent terrain-face roots beside partially unsupported
assemblies; a regression fixture fails with434 and passes with435. All74 Lua
compatibility fixtures and18 Python judge tests pass. No five-site acceptance.
434's17S11W run stopped responding to DAP beforeT1 for over eight minutes.
Graceful quit failed; only its exact tracked process was terminated through
the ownership-checking harness. This is a failed test, not clean-quit evidence.
Temporary435 diagnostics use a seating deadline/stack trace to locate the stall.
43361N136W A/B/control completed: surface75.203/75.694s (FAIL), A underground
48.761s. All other runtime gates and paired rule fields pass. All17,690 surface
and416 underground rocks have positive support; five corrections include the
previously floating top-up. Evidence: `_ralph/runs/five-rules-433-20260923`.
433 rejects a no-op correction for an already proven floating rock, allowing
exact terrain-face refinement/local search to proceed. It also omits unused
uphill-contact capture only when completed direct terrain stretching proves
the same no-compression condition that Apply already uses. Final floating-rock
seating and all-rock readiness coverage are unchanged. All74 compatibility
fixtures pass; native verification is still pending.

Latest closed failures (not acceptance):
- 43024S74W A/B surface73.201/77.781s, underground52.359/52.283s.
  B fails surface timing; all other runtime gates and full paired states pass.
- 43145S120W A/B/control surface80.051/74.436s, underground48.063/46.623s.
  A fails surface timing; other runtime gates and paired rule fields pass.
  All86 corrections succeed, and all surface/underground support checks pass.
- 43261N136W A blocks T1 correctly: one confirmed unsupported
  StonesRedSmall_04 at666649,200900,20466 received a zero-movement proposal.
  Four other corrections succeed;17,689 of17,690 rocks have positive support.
  This is a real correctness failure, not an accepted timing result.
- The431 broad diagnostic profiler recursively rewrote its own wrapper and
  stalled. Graceful quit failed; exact tracked PID/creation/incident were
  verified and the harness's exact-handle stop terminated only that test game.
  Its failed evidence is preserved; it is not a release crash or acceptance.
  A shared-upvalue regression fixture now guards the profiler. The corrected
  432 diagnostic completed and quit cleanly; diagnostic timings are not acceptance.

Historical430 matrix: `_ralph/runs/five-rules-430-20260923`.
15S67E hardest reference A/B/control: all13 runtime gates PASS; surface
73.679/73.638s, underground48.445/48.173s. Paired rule fields, full height/pass
grids, sites, pads and corrected rigid poses are identical. Positive support:
19,290 surface rocks /587 underground rocks, no native-gap exemptions.
430 sizes the initial underground relocation pool to current demand (64 here),
retaining strict placement checks and the existing bounded refill search. Hardest
relocation private draw count falls from11,520 to2,138; these counters are NOT
milliseconds. Measured total underground loading drops fromabout60.2s to48.4s.
Missing private-placement seeds now throw
rather than consume the engine RNG. Full five-site acceptance remains pending; source
review and final checkpoint/process review remain separate from runtime parity.
Optional local-checkpoint authority has been requested from the owner; no commit
or push has been made. A candidate payload must remain frozen during its matrix.
Historical429 A/B: surface73.271/73.430s, underground60.223/60.233s (FAIL).
Its control launch was refused before starting because the workspace had already
advanced to430; both completed429 games closed cleanly with unchanged payloads.
Latest42845S120W: **75.926s surface /46.723s underground**, so surface timing
still FAILS. All28,564 eligible surface rocks and527 eligible underground rocks
have positive support, with no native-gap exemptions or unresolved cases.
All86 surface corrections precedeT1; all three temporary buttons pass. Closed-game
log is clean. Seating itself fell from13.939s in426 to11.310s in428. Guard429 tests
an outside-vertex containment shortcut; it is not yet a verified checkpoint.
Evidence: `_ralph/runs/strict-428-20260923/45s120w_a`.
Latest complete native run (426, 45S120W): **78.827s START-to-T1 /
46.605s underground**. All 28,564 eligible surface rocks have positive support
at T1; zero defects, incomplete cases, inconclusive cases or native-gap exemptions.
86 rigid corrections precede T1, including one bounded tilt whose actual native
transform and rendered support are independently verified. All three temporary
buttons work; closed-game log is clean. Surface timing still FAILS. The five-site
matrix, repeatability/source audit and lifecycle checks remain outstanding.
427 tests a certified-flat terrain fast path; its45S surface timing was76.926s.
Evidence: `_ralph/runs/strict-426-20260923/45s120w_a`.
Owner clarified on 2026-09-23: no floating rocks, including native vanilla gaps.
Native-composition exemptions are therefore removed from readiness and the judge.
Required five-site matrix: 15S67E (hardest reference), 24S74W, 45S120W,
61N136W, 17S11W. Both strict timing limits, buttons, support, entrance/resource
rules, repeatability and lifecycle verification are required; no current acceptance.
Historical 413/414 closed-game 45S diagnostics seat 75 groups (including the previously
disputed single rock), but reject 11 remaining groups and correctly block T1.
415 removes redundant negative source-gap proofs, retaining native positive
contact/geometry history. Investigation continues; failed runs are preserved.

Historical checkpoint before the stricter native-gap ruling: **412 / metadata1043**.
Latest41224S74W: **74.356s START-to-T1 /53.040s underground**. All15967 eligible
rocks are accounted for atT1 before player actions:14761 positive terrain witnesses,
1206 graph proofs, zero incomplete/unknown/defective cases. Six corrections precedeT1.
All11 machine-checkable gates pass; seeded gameplay fields match407B exactly. RNG
source audit and process/checkpoint review remain pending. Closed-game log is clean.
All three temporary buttons pass (400/400 surface sectors,110/110 underground
objects, Elevator construction mode). Final host check:71 compatibility fixtures,
16 judge tests and Lua syntax checks pass; deployed43/43 files match. No game
process remains running;1039 display samples have zero resolution violations.
412 removes411's unsuccessful exhaustive hull-vertex retry and tries the cheaper
correlated terrain-face proof before repeated integer-region queries. No contact
tolerance change. Display remains at the user-authorized1024x768.
The last45S rock is already separated from terrain in untouched vanilla: native
vertex clearance7 units (floating transform6.228), scale71; expanded9 units
(floating transform9.221), scale95. Withguim100 these are centimetres, approximately
proportional to the native scaling. Complete terrain-face separation is proved in
both poses; its relation to the open cliff remains inconclusive. The user has been
asked whether existing vanilla floating placements should be preserved or seated.
No exemption or forced move has been made.45S readiness remains blocked on this
case. Evidence:411 `45s120w_last_rock` and412 `24s74w_a`.

Historical408-411 checkpoint follows.
408 adds an all-eligible-rock production readiness gate; unknowns can no longer
hide behind zero rejected corrections. Complete convex-projection exclusion of
open cliff meshes resolves two of the six45S unknowns as preserved native pieces.
409 adds exact triangle/terrain-face clipping with guarded native floating rigid
transforms, resolving three more (including preserving the tiny authored gap).
The native terrain interpolation oracle matches2000/2000 queries;500 randomized
slope/error-bound fixtures pass. Contact tolerances and native geometry are unchanged.
One `StonesDarkSmall_03` at383099,154735,8345 remains inconclusive.409/410/411
correctly block T1 on it; these are retained failed runs, NOT accepted timings.
411's exhaustive later-vertex hull check did not resolve it and adds work; it will
be removed. Native-source inspection and close-up diagnostic capture are in progress.
71 compatibility fixtures now exist; the latest added focused tests pass. Broader
timing repetitions, seed/source audit, matrix sweep and lifecycle remain outstanding.
Evidence: `_ralph/runs/correctness-408-20260923` through411.

Historical407 checkpoint follows.
Latest407 ordinary24S repeat:72.825s surface /52.901s underground, clean finalized
log and buttons. A new pre-player-action T1 census adapter initially failed on its
own local-variable scope; that failed diagnostic is retained. The corrected run
measured75.852s /53.339s (surface FAIL), clean finalized log, unchanged1024x768.
Its stricter census exposed an uncaptured affine-extrema witness in the verifier;
the helper now explicitly reconstructs that positive proof rather than treating
absence from the correction list as proof. This refinement awaits a fresh run.
The45S process-local4096 terrain-query budget experiment leaves the same six
inconclusive cases; no production tolerance or placement change was made.
Evidence: `_ralph/runs/correctness-407-20260922`.
Latest finalized ordinary24S74W (406): **74.215s surface /52.879s underground**,
all six corrected poses and paired gameplay fields unchanged versus405; clean log.
Latest paired45S120W (405 A/B): **72.321/72.863s surface**, **46.821/47.060s UG**;
all16 corrections beforeT1, exact seeded gameplay parity, clean closed-game logs.
Temporary buttons pass on45S120W B (400 surface sectors,109 underground objects,
Elevator placement mode). However its census finds **six inconclusive rocks**:
28564 eligible =28327 direct-terrain +167 graph-supported +64 native compositions
+6 inconclusive; zero confirmed defects/incomplete. These six are not accepted.
The judge now has an explicit rock-support gate (13 gates total,16 unit tests).

405 caches exact integer-terrain block maxima (12000 exhaustive oracle comparisons).
406 avoids treating alternative LODs as simultaneous pieces during native assembly
capture; final support still covers all LODs.407 skips an unused bounds index on
native maps without multi-piece assemblies. All67 host fixtures pass. The first
407 native repeat/census is in progress. Targeted45S diagnostics distinguish larger
authored gaps from smaller unresolved contacts; no threshold has been relaxed.
The first diagnostic failed on its own duplicate-vertex indexing, was fixed, and
the failed run is retained. Broader sweep, source RNG audit and lifecycle remain open.
Evidence: `_ralph/runs/correctness-405-20260922/verification_status.md` and406 runs.

Historical404 notes follow (superseded above).
The finalized guard403 45S120W run measures **76.075s surface /46.481s underground**.
All16 corrections precedeT1; zero rejections, clean flushed log,814 unchanged
1024x768 display samples. Source composition capture9.190s; final seating5.936s.
Its surface gameplay fields match402; underground seeds were natural/unpinned,
so that cross-version comparison is NOT a seeded underground parity test.
Evidence: `_ralph/runs/correctness-403-20260922/45s120w_a`.
Guard404 additionally reuses conservative terrain bounds when they already prove
triangle separation before issuing exhaustive integer-height queries. All66 host
fixtures pass; native timing is in progress. No below75 or all-rules claim yet.

Guard402 45S120W completed at82.411s/47.726s with16 verified corrections and zero
rejections. Exact small-region terrain bounds and preservation of already-proven
native/current intersections resolve the earlier401 group failures. Guard401's
24S74W retry completed at76.610s/52.467s with six corrections; its first1024x768
launch crashed before generation (ntdll heap-corruption event), retained separately.
The remaining gates include paired seed repeatability/source audit, broader-site
A/B/control runs, current all-rock census, and current save/load/button lifecycle.

Historical401 notes follow (superseded by the results above).
Display authorization update: after the401 integer-bound diagnostic quit at
3840x2160 with526 clean samples, Windows later reported1024x768 with no game
running. The next launch was blocked before starting a game. The user then
explicitly authorized further testing at the current display resolution. Runs
using `--expected-display 1024x768` preserve that exact resolution throughout;
the harness still never changes Windows display settings and rejects changes.

The underground rule now requires strictly less than60000ms from the first-access
phase through prepared state, consumed deferred mask, and both loading covers
closed. The judge has separate strict surface/underground fail-closed gates;
15 unit tests pass. Current live results use that full underground boundary.

Guard401 captures native rock support before transfer and preserves authored
fragment gaps only with complete geometry, exact composition/frame evidence,
proven native separation and retained native rooted support. Physical support
status is not rewritten as grounded. The45S120W live run preserves two formerly
rejected groups but still fails four; eight expansion-induced loose stones are
corrected. Readiness remains blocked. Evidence:
`_ralph/runs/correctness-401-20260922/45s120w_a`.
All468 display samples were3840x2160; the owned process quit cleanly, with the
expected unresolved-seating error retained. The63 host compatibility fixtures
and37 Lua syntax checks pass; new native-composition regression also passes.

Earlier correctness follow-up: **NOT all-green.** The guard399 coverage run reproduced
the earlier398A resource-placement variant:35 class/hex rows changed, with identical
requested seeds, and surface height/pass snapshots differed. It passed the eight
runtime gates, but fails paired repeatability. Evidence:
`_ralph/runs/correctness-399-20260922/24s74w_coverage`.
Its post-T1 support census accounts for15989 eligible rocks:14783 direct-terrain
witnesses,1206 support-graph passes, zero reported defects/incomplete/inconclusive
cases. The census uses the production geometric evidence service; it is not a
second independently implemented geometric oracle. Diagnostic timing76.491s is
retained, not accepted as sub75. The same mismatch as398A means unused probe-body
compilation has not been established as the root cause.

Guard400 / metadata1031 fixes an independently reproduced error-propagation defect:
failed MapGrid clear/conversion/resampling/repacking/writing now return explicit
failure reasons. Surface and underground pipeline readiness both propagate failed
terrain stretching even when native error() only logs. Successful grid operations
are unchanged. All63 compatibility fixtures,37 syntax checks and13 judge tests
passed before the additional outer readiness guards; those guards have a focused
passing regression and remain under live verification. Uncommitted/unpublished.

Historical scoped guard399 timing/runtime result: three consecutive ordinary fresh hidden/windowed 24S74W RoughTerrain runs A/B/C measured **74.682 /73.444 /73.640s**, mean **73.922s**, maximum **74.682s**. All are strictly below75 and pass all eight runtime gates, every paired gameplay field and exact full surface/underground height/pass-grid/site/pad/lowered-rock comparisons against corrected384. All six verified rock corrections finish beforeT1, with zero rejected corrections. C passes the actual temporary-button handlers (400/400 surface sectors,110/110 underground explorable objects, Elevator construction). Every flushed log is clean through owned shutdown; every display sample remains3840x2160. Machine verdict: `_ralph/runs/full-rules-399-20260922/release_abc_verdict.json`. This is not a blanket completion of the broader audits listed below.

Guard398's ordinary B/C/D measured73.709/73.390/75.017s (mean74.039s); its17ms overrun is retained, not rounded into a sub75 result.399 removes repeated library min/max calls while constructing rock-contact tree bounds, preserving every exact bound, median partition and triangle order. All63 compatibility fixtures,37 Lua syntax checks and13 rule-judge tests pass. No production entrance-planning or rock-contact predicate changes.

Guard398's regional terrain-type write uses exact U8 repacking and the native unscaled corner write instead of a full padded-grid copy. The native oracle confirms full serialized-grid equality, including padding, at163ms conversion/write versus the prior~900ms copy. Evidence: `full-rules-397-20260922/24s74w_type_oracle_u8`. The initial packed-grid oracle was rejected by the native API and is retained as failed diagnostic evidence. Two earlier oracle attempts failed before generation because game assert does not return standard-Lua values. No diagnostic timing is release acceptance.

Retained failures:397A/B/C measured74.128/73.776/75.768s; C logged two PinButton zero-rectangle errors during the extra post-timing button test. The no-screenshot test omitted the three native layout frames already present in screenshot mode; restoring that wait yields clean button checks in the U8 oracle and398D.398A measured73.813s but failed surface enrichment/grid parity with an additional unused save/load probe body compiled into the rules script. Compiling that body only for its diagnostic case restores exact parity in398B/C/D. This instrumentation sensitivity is recorded, not treated as a completed RNG-source audit. All display samples remain3840x2160.

Deferred-mask save/load: **PASS in a fresh process**, evidence `full-rules-399-20260922/loaded_deferred_buttons`. The checkpoint retains exact mask bytes (hash249497277068506782), pending state and committed linked entrances. All six corrected rock poses are present before and after access. All three temporary buttons pass, including Reveal Underground before any Elevator placement; final preparation consumes the saved mask before access and leaves the committed surface positions unchanged. The flushed log is clean and all554 display samples remain3840x2160. Retained checkpoint: `SBM Deferred Mask 399 20260922 138033072.savegame.sav`.

Earlier lifecycle-probe failures remain recorded:398 never saved (startup popup and nil terrain-following Z in diagnostic formatting);399's first save/load reached underground successfully but its adapter misread serialized `true` as a boolean failure; the next reached underground and captured final grids but optional photography assumed a transient seating report survived loading. The report is deliberately not persistent; corrected poses are. The helper now performs photography only when requested, and the independent fresh-process verification above completes the targeted lifecycle checks. The earlier generated save `SBM Deferred Mask 398 20260922 137087789.savegame.sav` is also retained.

Guard396 captures/persists the source underground forced-impassability bytes without installing the temporary source mask. Its final scaled mask is still applied before underground access; capture/write failures remain blocked. Its release run measured76.577s. Guard397 additionally omits only the native source-layout passability rebuild after mask capture; earlier rebuilds and final expanded gameplay-grid rebuilds remain unchanged. Runtime confirms one captured mask, zero eager mask writes, one skipped final-source rebuild, and no pending mask after successful access. Surface entrance selection never reads the deferred underground raster: the transformed vanilla underground endpoint is authoritative, the surface uses the nearest valid full Elevator footprint, and its committed position is immutable afterT1. Production entrance planning was not changed.

Historical display incident: during guard390's run, Windows changed from3840x2160 to1024x768. The guard aborted; the owned game quit cleanly with no flushed engine errors. That incomplete run has no accepted timing. At that point WmiMonitorID reported no active monitor, and testing stopped. A read-only check after the user's next `continue` confirmed3840x2160 again, allowing the392 tests. The harness made no display-setting calls and the saved game configuration remains windowed. Cause is not established. Evidence: `_ralph/runs/full-rules-390-20260922/24s74w_a/display_guard.json`.

Workspace/deployed candidate is guard **399 / metadata1030**, deployment43/43 matched. Guard394's quiet repeat measured81.836s; its89.684s run remains recorded as contaminated by a concurrent source search. Guard395 measured81.843s; the native U16 buildability-copy oracle confirms exact equality including padding (9ms native versus302ms scalar). All399 release A/B/C full surface/underground height/pass grids, sites, pads and lowered-rock records match corrected384 exactly. HEAD remains `d753556`, uncommitted/unpublished. Broader site sweep, additional references, all-rock coverage census and historical process/RNG-source audits remain outstanding.

Guard 384 / metadata1015 fixed the original 24S74W failures and passed expanded A/B/control at 87.500 / 87.215 s, including six independently verified corrections. The small stone regains native cliff support with a nine-unit lowering, preserving XY/shape/scale. Historical pinned-reference guard382 results below75 do not certify this harder case or newer candidates.

## Historical pinned reference (guard 382)

15S67E, RoughTerrain, the same surface/game/underground seeds listed below: three consecutive fresh hidden/windowed release runs are **74.592 / 74.461 / 74.713 s** (mean **74.589 s**, maximum **74.713 s**). The timer includes the full START body, all rock seating, source cleanup and final revalidation.

All selected runs pass the eight runtime gameplay/error gates and every runtime parity field against the corrected guard-376 reference and same-site unexpanded control. Surface and underground height/pass grids, resource sites, landing pads and lowered-rock records match exactly. The native U16 flattening oracle additionally confirms exact passability-cell equivalence to the pre-coalescing path. Production diagnostics are off. Every flushed log is clean through owned-process shutdown; all display samples remain 3840 x 2160.

The third run verifies the actual temporary-button handlers: Elevator construction opens with template `Elevator`; Reveal Surface deep-scans **400/400** sectors; Reveal Underground reveals **111/111** explorable objects and removes darkness. The full rules probe separately places and links a real elevator through the player construction controller. Three fixed-camera images of corrected rocks have been inspected. Clean surface and underground UI images from `full-rules-382-20260922/15s67e_a` were subsequently captured and inspected; the requested buttons are visible and unobstructed.

Machine verdict: `_ralph/runs/seed-fix-under75-20260922/primary_382_abc_verdict.json`.
Outstanding: ten-site A/B/control sweep and 14N134W additional reference; historical commit-order violation cannot be repaired retroactively.

The broader sweep's 15S67E A/B/control checks pass every runtime gameplay gate and paired field. Its alternate game-seed A/B timings are 73.244 / 75.308 s; the latter exceeds the target and is retained, not excluded. At 24S74W, two `Rocks_03_66` objects require a seven-unit downward adjustment but the placement collision guard refuses their neighbors. The surface correctly fails readiness rather than reaching T1. The sweep stopped there for correction. Evidence: `full-rules-382-20260922/24s74w_a` and follow-up `seed-fix-under75-20260922/collision_382_24s_diag`.

Guard 383 strengthens open-mesh separation: after a complete triangle-pair search excludes crossings, inspect all vertices for an outside-bounds witness rather than relying only on the first vertex. Both original rocks now move down seven units and pass independent support verification. All 56 compatibility fixtures pass. The stronger negative proof also identifies another `StonesRedSmall_01`; its terrain-only proposal would collide with cliffs. That run remains failed, not waived. Original-versus-expanded support contacts are under investigation in `collision_383_24s_native_diag` and `collision_383_24s_native_contacts_b`. The user clarified that authored vanilla intersections/stacks must stay intact, and floating introduced by expansion must be corrected before T1.

## Correction follow-up

- Guard 375 canonically orders seeded top-up donor lists by their captured native record index. That alone did not fix repeatability.
- Guard 376 fixes the current game's native breakthrough initializer: it sorts by object handle before its seeded shuffle. The old mod replayed query order but recreated handles defeated that replay. The mod now captures source handles and scopes the native sort to those original identities for the exact returned marker list. Live handles and native random draws are unchanged; temporary hooks restore on success/error.
- Two full guard-376 runs (`native_sort_376_a/b`) pass every runtime parity field, with all primary gameplay/error gates passing against the same-site unexpanded control. Strict START-to-T1: **75.306 / 75.070 s**, with all rock seating completed before T1. Timing target is still unmet.
- Guard 377 filters wrong-direction crease candidates before Lua enumeration. Its full run is **75.130 s**; final surface/underground height and passability grids, resources and pads match guard 376 exactly. This small optimization is not enough by itself.
- Guard 378 measured 73.979 s, but its bounding-box coalescing changed actual passability cells. It is **not accepted**. Guards 381/382 restrict coalescing to exact rectangular unions, without overscanning any extra cells. Guard 382 matches the old passability cells exactly; 48 source boxes become 24 calls, about 0.65 s versus 1.21 s for the old pass.
- Guards 379/380 optimize mesh decoding with first-extremum witnesses and certified exact packed-coordinate keys. The new decoder matches the old decoder across 300 packed/skinned/large-offset fixtures (54,000 vertices). Clean guard-380 full run: 75.605 s, so timing remains unmet. Slower and failed diagnostic runs are retained in the evidence directory.
- Guard 381's slab-conversion/fused-crease experiment passed offline checks but one runtime sample changed the height grid and took 78.323 s. A diagnostic repeat matched the old grids at 74.387 s; that does not establish reliability. The crease experiment is **removed** in guard 382. Only exact-union coalescing and the certified integer zero-grid clear are retained from this candidate. Biome processing falls from about 0.916 s to 0.140 s, with the same final grid.
- The obsolete v996 whole-file/version freeze in `startup_bundle_source_test.py` has been superseded, while its exact unchanged distance-cache oracle, ownership order and write guards remain enforced. Python discovery now passes (7 tests plus the import-time contract checks).
- All **55 compatibility fixtures** pass. New focused tests cover canonical donors, source-handle replay, unchanged handles/RNG, hook cleanup, full decoder parity and zero-grid ownership/notifications. Crease discovery passes 344406 checks; track-order parity passes 655391 checks; dirty-region tests cover exact unions and forbid bounding-box overscan.

Evidence: `_ralph/runs/seed-fix-under75-20260922`. The below-75 claim is scoped to the three named guard-382 runs, not older experiments or every possible seed/hardware combination. The broader sweep is at `_ralph/runs/full-rules-382-20260922` and is not yet complete.

## Original guard-374 verification

## Corrected timing boundary

The new timer starts before the mod's START arming/session entry and the complete native START body: skipped-mod warning, loading-screen open, settings save, telemetry restart, rocket-name bookkeeping, planet-camera wait, generation, and loading-screen close. T1 still requires completed rock seating and post-pipeline revalidation. Bootstrap/NewGame is outside this user-action interval.

| Run | Strict START → T1 | Scope |
| --- | ---: | --- |
| `strict_15s_a` | 74.358 s | Surface/seating/buttons; START prefix 215 ms |
| `rules_15s_b` | 74.401 s | Full surface and player-route underground rules, grid capture, clean teardown |
| `rules_15s_c` | 74.318 s | Full repeated rules run and grid capture, clean teardown |
| `manifest_15s_d` | **75.678 s** | Strict surface repeat; marker manifest captured after T1; clean log/teardown |
| `manifest_15s_e` | **76.053 s** | Second manifest repeat; same pinned inputs; clean log/teardown |

The first three are below 75 seconds, but both later repeats exceed the target. **Consistently below 75 seconds is not proven; the latest measured value is 76.053 s.** Adding a marker-manifest output after T1 does not exclude these slower samples. The earlier 74.056/74.651-second numbers excluded the START prefix and must not substitute for these strict measurements.

`rules_15s_a` also measured 74.452 s, but its underground phase was invalidated by a stale test adapter reading the removed `mapdata.Environment` field. The adapter now calls `GetEnvironment()`. This was a probe defect, not evidence of missing game content.

## Primary reference rules

The full B/C runs use 15S67E, RoughTerrain, surface seed `-515742201377381600`, underground seed `411683085576098543`, and game-seed text `sbm_entrance_bottomless_24s97w_v999`.

- **FAIL — seed-parity:** B/C surface enrichment digests are `1806203099` / `1456742448`, both with 563 census entries. Private placement phase counts differ: `deposits:5556,anomalies:4918,effects:264` versus `deposits:5225,anomalies:4918,effects:364`. The mismatch is not being waived under practical equivalence.
- **Confirmed with exact manifests:** D/E produce digests `975376688` / `994563224` under identical surface, underground and numeric game seeds. Their sorted class/hex multisets have 119 unmatched entries on each side, covering surface/subsurface/concrete deposits, anomalies and effects. This is real placement variation, not JSON key ordering or a hash-only discrepancy. Some census classes overlap, so entry counts are not asserted to be distinct-object counts. See `marker_pair_diff.json` for the exact difference.
- **PASS at this reference —** entrance glue/nearest-valid placement; all entrances outside the ring; ring resources/pads; exactly one start-sector reveal; badge visibility and scan behavior; cosmetic decoration counts/band rules; player-controller elevator placement and first underground access; one SBM underground cover with zero final references; no Lua/assert/native-error signatures through clean teardown.
- **PASS at this reference — control comparison:** `rules_15s_control` is an EXPAND MAP-off same-site control, and underground reveal/imprint visibility matches B/C.
- Full serialized surface/underground height grids and pass grids match between B/C. Resource site/pad records also match as structured data. JSON object key order is not a content mismatch.
- Numeric `GameSeed` equals `xxhash` of the requested seed text (`7002472064015218891`). The current game clears `Game.seed_text` later, so the old report's text-only pin check is false; actual numeric equality was checked in the live process and recorded explicitly in C. RoughTerrain is active and the live generator preset is `RoughTerrain`.

## Other outstanding verification

- **FAIL — historical process requirement:** per-optimization commits/version increments/ranking entries were not made before the original tests. A later checkpoint cannot retroactively repair that history. Changes are still uncommitted; no push has occurred.
- **NOT COMPLETED —** complete ten-site expanded A/B/control sweep, additional 14N reference samples, and fixed-camera terrain visual review. The acceptance sweep is stopped at the reproducible primary seed-parity failure rather than claiming an all-green result. No production fix was applied during this verification-only request.
- **Qualified equivalence —** foothill blending allows one stored height quantum per patch, not bit-for-bit scalar parity. This follows the user's later practical-equivalence permission. Existing 145512-cell bounded/strict fixture and 55296-cell native comparison pass; it does not waive seed repeatability.
- **PASS —** all 51 compatibility fixtures; all 37 Lua syntax checks (35 Code files plus metadata/items); 8 crease-join, 16 resource-protection and 9 terminal-strip synthetic checks; outer-ring policy 101/101 static checks plus all dynamic/synthetic checks.
- **NOT all-green — Python discovery:** seven tests pass and `startup_bundle_source_test.py` fails at import because it requires exact source-file identity with historical commit `1c75b81`. This historical source-freeze assertion was not removed or weakened. No claim that the whole discovered suite passes.
- **PASS —** deployed payload audit: 43/43 files match. Primary monitor guards report no observed deviation from 3840 × 2160. The game remains windowed.

Evidence: [_ralph/runs/all-rules-verification-20260922](_ralph/runs/all-rules-verification-20260922). Full runs include incident-matched flushed engine logs, process identity, deployment audit, display guard, rules report, and final grid snapshot. The scripts remain outside the mod payload.

Machine-readable final verdict: `verification_verdict.json` (`accepted: false`). All owned verification games were cleanly closed. No commit or push was made.

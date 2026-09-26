# Surface START-to-T1 — runtime acceptance and local checkpoint

## Metadata 1120 / build 469 (`c972f94`): vanilla rock compositions, five-site pass

Owner ruling 2026-09-25 (reverses the 2026-09-23 "no floating rocks, including vanilla's own"):
rocks keep vanilla's authored compositions, scaled with the rock. Only floats or open rims that
the expansion creates or widens are corrected, and only back to the vanilla relationship. Mod
top-up rocks and the underground keep the strict rule. A cause census of build 465 found about
three quarters of its seating moves were "fixing" vanilla compositions, for example 17S11W
StonesDarkGroup_03, whose long stone was buried
(`_ralph/runs/allrules-1120/screens/17s11w_cluster_vanilla_1116_1120.jpg`).

How it works: the surface stretch keeps a copy of the untouched native height grid, checked
against the source terrain and re-checked when seating starts. Validation measures each native rock
at its recorded vanilla pose (source position, scale, angle) against that grid and stores
the per-component clearance and open-rim gap on the object (`SuperBigMapNativeGround`, version
3), so later validations and reloaded saves use the same evidence without the grid. A component
that floated in vanilla and stands no higher than that clearance x scale ratio + 4 units is
accepted; one the expansion lifted further is lowered to its vanilla clearance. The planner
always gets the vanilla rim allowance. The surface census reports accepted rocks as
`native_composition_preserved`, which the judge accepts on the surface only.

| Site | START-to-T1 A / B / save | Underground A / B / save | Seating | Corrected (1115) | Vanilla compositions kept |
|---|---|---|---|---|---|
| 61N136W | 71.041 / 70.664 / 73.414 s | 45.651 / 45.525 / 44.145 s | 7.6 s | 21 (56) | 39 |
| 17S11W | 63.880 / 64.043 / 64.257 s | 55.590 / 54.974 / 53.526 s | 9.2 s | 45 (125) | 88 |
| 24S74W | 63.863 / 64.695 / 66.145 s | 49.195 / 49.289 / 48.393 s | 7.4 s | 11 (51) | 34 |
| 45S120W | 62.115 / 62.036 / 61.219 s | 44.071 / 43.536 / 42.255 s | 7.0 s | 39 (99) | 91 |
| 15S67E | 58.107 / 57.955 / 58.096 s | 45.403 / 45.986 / 44.499 s | 3.4 s | 16 (27) | 16 |

All gates pass at all five sites (A/B/unexpanded control), and every save / fresh-process load
keeps all corrected rocks with positive support. Decor is placed in full at every site. 45S120W's first A run rolled
`MirrorSphereMystery`, which stamps its building prefab into the terrain; its height and pass
grids differed from B. That run is kept (`45s120w_a`, 60.462 s); the accepted pair uses a re-run
A (`45s120w_a_rerun`, LightsMystery), recorded via `audit_five_candidate.py --use`.

Per-rock check of every rock build 1116 corrected, against the vanilla twin census
(`_ralph/runs/allrules-1116/seating_causes/*_vanilla`): every open vanilla rim equals the vanilla
map's rim to within 0.5 units. A few fully covered (negative) rims differ from the census by up to
about 220 units; any negative rim gives the same 2-unit allowance, so this has no effect. None of
these rocks is left above its vanilla allowance, and no authored rim is closed. The two-stone
groups' stored clearances match the census (17S11W #106: -395.2 / +115.8 against -397 / +117). Examples at 61N136W: a
Rocks_03_33 that 1115 lowered 19 m now drops 0.84 m, to its vanilla gap (1545 = 1158.8 x 1.331 +
4). A Rocks_03_66 that only lost a vanilla touch drops 5 units, not 45. The remaining large moves
are real expansion damage: cliffs at 17S11W and 15S67E whose base was covered in vanilla and opened
by 4-7.7 m in the expansion close to about +1 unit.

Three defects in the first implementation, found by these checks:
- 1117: `GridRepack` without its copy flag returned the stretch's own source grid, which the
  stretch then freed. Every vanilla lookup read 0, so every rock looked vanilla-authored (fixed
  in `3489e9b`, plus the start-of-seating re-check).
- 1118: a rock seated for another reason (a lost vanilla touch) had its authored rim fully
  closed (`bfbd7e0`).
- 1119: rocks without a valid Z take their vanilla Z from the interpolated vanilla ground. The
  engine divides int/int as integer, so integer source positions read the cell corner, up to about
  160 units off on slopes. This was the StonesDarkGroup_03 case (`c972f94`).

Timing note: a 1119 61N136W probe run measured **75.303 s** (`_ralph/runs/allrules-1119/seating/61n136w_rim`):
the extra 3.8 s is entirely in vanilla map generation (`generate_returned_ms` 45.7 s vs 41-42 s),
not in any sub-timer the mod records. It rolled MirrorSphereMystery, but two runs with the mystery
pinned (new `VERIFY_MYSTERY` harness option) measured 71.415 and 71.556 s. It is recorded as a
generation-time outlier; the margin at 61N136W is about 2-4 s.

Evidence: `_ralph/runs/allrules-1120/harness` (`five_audit_1120.json`),
`_ralph/runs/allrules-1120/lifecycle`, per-rock probes in `_ralph/runs/allrules-111[7-9]` and
`allrules-1120/seating`. 86 compatibility tests and 18 judge tests pass.

### Release Mars.exe timings (what players get), build 469 code

Measured 2026-09-26 in the real release game with the owner present (one UAC approval). A
temporary, owner-approved build (1123, `a02fbea`, reverted in 1124 `684df24`, code identical to
1120) ran all fifteen cases in one process: the same pinned seeds, Super Big Map as the only mod.
Only the first case (61N136W A) is a fresh process; later cases reuse the warm process.

| Site | START-to-T1 A / B | Underground A / B | Unexpanded vanilla: surface / underground | Harness A / B |
|---|---|---|---|---|
| 61N136W | 53.078 / 50.920 s | 39.757 / 39.351 s | 21.247 / 4.197 s | 71.041 / 70.664 s |
| 24S74W | 50.295 / 46.312 s | 42.999 / 42.715 s | 20.074 / 4.198 s | 63.863 / 64.695 s |
| 17S11W | 47.640 / 46.840 s | 47.326 / 47.240 s | 19.677 / 4.200 s | 63.880 / 64.043 s |
| 45S120W | 46.298 / 46.809 s | 37.590 / 37.427 s | 19.828 / 4.197 s | 62.115 / 62.036 s |
| 15S67E | 45.166 / 44.820 s | 39.216 / 39.143 s | 20.880 / 1.003 s | 58.107 / 57.955 s |

Every case finished with 0 rejected and 0 unresolved rocks, the underground ready, 0 Lua errors,
0 reported mods, 0 optimization failures, a clean log and an unchanged payload. (The runner's
`accepted` flag is false only because it still expects the old case-file build to empty
`case.txt`.) Release is about 0.72-0.78 of the harness time. Rock corrections and decor top-up
match the harness exactly at four sites. At 45S120W release placed 2704 top-up objects (3999
attempts) against 2935 (4089) in the harness, so 28,844 rocks were eligible against 29,082, with 37
corrections against 39. The harness gave 2935 under three different mysteries, so this is a
remaining harness/release decor difference at that site, not a player-facing defect.

Release builds refused file I/O from the autostart: the 1121/1122 case-file variants never
started a case. They also do not route a mod environment's `print` to the log. The working build
logs through the engine's global `print`. Evidence: `_ralph/runs/release-1123/batch`.

## Metadata 1115 / build 465 (`c523d3b`): five-site full-rules pass

Every standing rule gate passes at all five pinned RoughTerrain sites in fresh A/B runs with
same-site unexpanded controls, and every save / fresh-process load check passes. Timings use
the release-equivalent harness (release debug hook, and since this round release prefab names:
see below). All times are strictly below 75 s surface and 60 s underground.

| Site | START-to-T1 A / B / save | Underground A / B / save | Seating | Rocks corrected | Decor |
|---|---|---|---|---|---|
| 61N136W | 72.176 / 70.642 / 73.695 s | 46.071 / 45.749 / 44.331 s | 8.0 s | 56 | 190/190 |
| 17S11W | 67.873 / 69.642 / 67.876 s | 54.341 / 53.846 / 53.450 s | 13.4 s | 125 | 72/72 |
| 24S74W | 65.619 / 64.846 / 65.113 s | 49.310 / 49.371 / 47.822 s | 8.7 s | 51 | 171/171 |
| 45S120W | 61.306 / 60.924 / 61.604 s | 43.223 / 43.225 / 42.270 s | 8.0 s | 99 | 53/53 |
| 15S67E | 58.357 / 58.252 / 58.679 s | 45.512 / 45.607 / 44.269 s | 3.4 s | 27 | 99/99 |

- **Release prefab names in the harness.** Debug `PrefabMarkers` keys carry a POI prefix
  (`Decor.Red.CraterS_06`) while placed markers compose `Red.CraterS_06`, so the harness decor
  top-up resolved ~190 markers against 1927 in release Mars.exe and tested a different layout.
  `run_primary_headless.py --prefab-names release` (default) adds a fallback to the unique
  POI-prefixed entry (`_ralph/tmp/release_prefab_names.lua`). At 61N136W (build 1111) the
  harness then matched release exactly: 190/9/181 groups, 727,247 attempts, 5,456 objects, 80
  corrections. Earlier harness decor results are not release-equivalent.
- **Two top-up defects that release players would have hit, both fixed.** 24S74W failed with a
  top-up `Rocks_03_33` whose open base stood ~12 m above a slope: the stamp planner now applies
  the final seating's rim rule (`40a30a5`). 61N136W then failed with a top-up
  `StonesRedSmall_05` 49 units above flat ground: the planner took the origin of invalid-Z
  scatter from its visual Z, 81 units above its transform origin while pass edits were
  suspended; it now plans from the transform origin and seats it on the destination terrain
  (`c523d3b`). Vanilla objects are unaffected.
- **17S11W paired state.** The first B run differed from A in height/pass grids (+23 rocks).
  Its log shows vanilla picked `MirrorSphereMystery` for the "random" mystery; that mystery adds
  map content. The mystery is re-rolled every run (about ten different mysteries in 21 runs);
  20 of 21 runs, including a re-run of B (`DreamMystery`), are bit-identical. The failing B run
  is retained (`17s11w_b`), the accepted pair uses `17s11w_b_rerun`. Future A/B pairs should pin
  `Game.idMystery`.
- Earlier this round, 61N136W B measured 77.893 s while a review agent ran the test suite on the
  same machine; the quiet repeat was 73.653 s. Both are retained (build 1111 evidence).
- Windows changed from 3840x2160 to 1024x768 during test launches; the tooling never calls a
  display API and the runs guard the current 1024x768.

Evidence: `_ralph/runs/allrules-1115/harness` (`five_audit_1115.json`, lifecycle verdicts),
diagnostics in `_ralph/runs/allrules-1113` and `allrules-1115`. Source review since build 462:
no new engine RNG draws, no scenario exceptions, seating before T1 enforced; 85 compatibility
tests pass.

Metadata 1116 (`9ff0082`) only removes the temporary release timing autostart that 1115 still
carried (inert in the debug harness; release-only and gated on a case file); its generation is
unchanged, confirmed by a fresh 61N136W run (`_ralph/runs/allrules-1116`).

(Superseded 2026-09-26: release Mars.exe timings for build 469 are in the metadata 1120 section.)
Release Mars.exe timings are still pending: on this machine every Mars.exe launch needs a UAC
elevation approval (the owner's per-user RUNASADMIN compatibility flag; a non-elevated launch
hangs at `Debug::Init()`), and the unattended prompts were cancelled. The one clean release
measurement (build 1111, identical placement to the harness) was 61N136W 57.4 s against 74.6 s in
the harness, a ratio of 0.77; applied to the table above that suggests roughly 45-57 s surface
for players. This is an estimate, not a measurement; underground was not measured in release.

## Metadata 1100 (`a152b05`), release-equivalent measurement

Owner rulings 2026-09-24: rock seating must finish before T1 (a same-day post-T1
waiver was reverted), START-to-T1 must stay below 75 s, rocks must stay as close to
vanilla as possible, and the measurement must reflect what the published mod offers.
The harness keeps a DAP socket open, so the engine gives every Lua thread the
debugger's call/return/line hook, which players never have (about 8 s at 61N136W).
The runner therefore defaults to `--debug-hooks release`: `_ralph/tmp/release_hooks.lua`
makes `ResolveThreadDebugHook` skip only the debugger branch (release resolves to
`SetInfiniteLoopDetectionHook`), a watchdog restores it after the engine's new-game
Lua reload, and a run is rejected unless the hook is verified at the end with no
reinstall after START. Only SuperBigMap is loaded; release diagnostics stay off.

All eight cases below are accepted fresh processes with 0 unresolved rocks, seating
completed before T1, clean flushed logs and the release hook verified:

| Case | START-to-T1 | Seating | Rocks corrected | Notes |
|---|---:|---:|---:|---|
| 61N136W | 73.790 s | 15.122 s | 122 | save/in-process reload exact; underground 44.676 s; 0 census defects |
| 24S74W | 71.528 s | 14.745 s | 106 | |
| 17S11W | 71.258 s | 14.495 s | 127 | |
| 30S146E / `x9pLZCNl` | 70.957 s | 11.870 s | 122 | owner's failing map, fixed in `2021166` |
| 45S120W | 62.131 s | 8.060 s | 98 | |
| 14S36W / `JXhzkS0O` | 60.459 s | 6.237 s | 56 | owner's J5/K5 floating-cliff map |
| 14S36W / `nBJAgUn3` | 60.141 s | 6.199 s | 56 | |
| 15S67E | 59.930 s | 4.044 s | 28 | |

Evidence: `_ralph/runs/welcome-handoff-20260924/matrix_v1100`. Not yet repeated on
this build: A/B/control pairs, fresh-process load, and underground runs for the
faster cases. The narrowest margin (61N136W) is about 1.2 s on this machine; these
are measurements, not a guarantee on slower hardware. Earlier sections use the
debugger-hook harness and are historical.

## Build 462 (historical, debugger-hook harness)

Current build 462 / metadata 1093 (code checkpoint `494f7af`) passes six pinned
RoughTerrain cases, including 14S36W / `nBJAgUn3`, across 30 fresh headless sessions.
Worst of 18 expanded generations: **74.955s START-to-T1**, including completed
rock seating and positive support proof; **57.364s underground loading** through
prepared state and closed covers. A/B/control, both-layer all-rock support,
entrances, passability, buttons and save/reload checks pass with clean flushed logs.

The general fix inspects actual terrain-cutting structures as physical support
neighbours. Exact projected cut faces allow already-grounded nearby rocks to avoid
redundant support graphs; hidden terrain and missing cut geometry remain vetoes.
No scenario-specific exception, changed tolerance or post-T1 seating deferral.
The slowest cases run first, retaining the known difficult seeds.

Evidence: `_ralph/runs/rules-parity/fix-14s36w-20260923/complete_audit462.json`;
`accepted=true`, no failures/pending checks. See ALL_RULES_VERIFICATION.md.
80 compatibility fixtures, 18 judge tests and Lua syntax pass. All 43 local mod
payload files match. Windows 3840x2160 was preserved during windowed testing.
The smallest surface margin is 45ms, so these measurements do not guarantee the
same timing under arbitrary system load. The new fix has not been pushed.

## Historical build460 checkpoint (superseded by462)

Build460/metadata1091 passes all five pinned RoughTerrain scenarios in fresh
A/B/control runs and save/in-process reload/fresh-process load checks.
Worst of15 expanded generations: **74.776s surface START-to-T1** and
**57.391s underground first access through prepared state and covers closed**.
All seating and positive rock-support readiness checks finish beforeT1;
authored vanilla floats receive correction rather than an exemption. Entrances,
ring content, reveal/badge/deposit rules, decoration rules, private-stream
repeatability and all three temporary buttons pass the captured checks.

Evidence: `_ralph/runs/rules-parity/strict-460-20260923`.
`runtime_and_lifecycle_pass=true`, no failures. See ALL_RULES_VERIFICATION.md
for all timings and excluded harness incidents.79 compatibility fixtures,
18 judge tests, Lua syntax and4114 checkpoint-angle predicate cases pass.
The narrowest measured surface margin is224ms; these are measurements on this
machine and these pinned cases, not a guarantee under arbitrary system load.
The owner authorized the local checkpoint and historical-artifact archive.
The checkpoint contains this unchanged tested build; `_ralph` is below2GB and
the recoverable external archive has a before/after checksum manifest.
`checkpoint_followup_audit.json` records the checkpoint and exact measured-payload
identity separately from the preserved pre-checkpoint runtime verdicts.
No new loading work, game launch, push or deletion is part of this follow-up.
See ALL_RULES_VERIFICATION.md for the archive path and historical process caveat.
Early460 completed runs preserved3840x2160; tests remain windowed.
Update:460's first15S67E control startup observed a change to1024x768 and was
closed/excluded before generation. Its evidence is preserved. The cause is
unknown; game settings still specify windowed mode. Further tests use the
owner-authorized current1024x768 and keep the read-only display guard enabled.
Historical459 failed17S11W at76.494s and61N136W at77.012s.460's projected
contact bounds reduce the mesh pairs needing full collision tests; the actual
world-space triangle/contact checks and final physical support gates remain.

## Historical443 status (not current acceptance)

Current workspace candidate: guard **443 / metadata1074**, unpublished and **not accepted overall**. Latest normal-hook17S11W surface diagnostic: **77.691s**, with all79 corrections beforeT1 and all29,677 surface rocks positively supported. Surface timing still FAILS. Latest full17S11W A/B/control was438:83.548/83.485s surface and57.723/58.083s underground; all other runtime gates passed. The required current five-site A/B/control matrix, source/process audit and lifecycle checks remain outstanding. Evidence: `_ralph/runs/strict-443-20260923/17s11w_native_profile`. Historical results below are not current all-rules acceptance. Deadline diagnostics that replaced the external native debugger hook are excluded from timing comparisons.

Both strict limits are required: surface START-to-T1 **<75 seconds**, including seating; underground first-access phase through prepared state and both loading covers closed **<60 seconds**, including deferred impassability. Missing timing/readiness evidence is pending, never a pass. The user subsequently authorized testing at the current Windows resolution; each hidden/windowed run records and preserves its explicitly authorized resolution without changing display settings.

Historical scoped guard399 result: three consecutive fresh 24S74W RoughTerrain release runs measured **74.682 /73.444 /73.640s**; mean **73.922s**, maximum **74.682s**. Their then-existing runtime gates, paired fields and full final map comparisons passed. All six verified rock corrections completed beforeT1, with zero rejected corrections. C passed all three temporary-button handlers. All display samples remained3840x2160; flushed logs were clean through shutdown. Historical verdict: `_ralph/runs/full-rules-399-20260922/release_abc_verdict.json`. These results do not close the later failures; see ALL_RULES_VERIFICATION.md.

The optimized pipeline preserves entrance placement beforeT1 and locks it afterward. Only the temporary source underground forced-mask write/rebuild is deferred; final scaled impassability and authoritative gameplay grids are mandatory before underground access. A fresh-process checkpoint load additionally verifies exact mask persistence, all six corrected poses, both entrance links/positions and all three temporary buttons, including direct underground reveal before placing an Elevator. Native regional U8 terrain-type writing removes a padded-grid copy with full-grid byte-equivalence evidence. Exact contact-tree bound aggregation removes repeated min/max calls without changing bounds, topology or triangle order. Prior398's75.017s overrun and all rejected/instrumented runs remain recorded.

Evidence: `_ralph/runs/seed-fix-under75-20260922/primary_382_abc_verdict.json`. Temporary reveal/elevator button actions also pass. See [ALL_RULES_VERIFICATION.md](ALL_RULES_VERIFICATION.md) for the current results, rejected candidates and broader sweep still in progress.

## Historical guard-374 record — superseded, not current acceptance

The following retains the original narrower record for traceability. Its generation-call timer excluded the full START prefix, and later seed-parity verification failed. Its accepted labels must not be used as current full-rules acceptance.
**Verification correction:** the broader rules audit is not accepted: a same-seed surface enrichment mismatch was found. Corrected full-START measurements span **74.318–76.053 s**, so the time target is not consistently met; the original timings below excluded the START prefix. See [ALL_RULES_VERIFICATION.md](ALL_RULES_VERIFICATION.md) for the current verdict and outstanding checks.
The hardest reference scenario, **15S67E with RoughTerrain**, completes surface preparation below 75 seconds in fresh hidden/windowed game processes.

## Measurement contract

- START is immediately before `GenerateCurrentRandomMap()`, not process launch or pregame setup.
- T1 requires `SuperBigMapSurfacePostPipelineRevalidationComplete` and completed, independently verified rock seating. Seating is not deferred until after T1.
- Surface and underground dimensions remain 819200 × 819200 world units.
- Surface seed: `-515742201377381600`; pinned underground seed: `411683085576098543`; Lua revision: 403908.
- Only SuperBigMap is enabled in each fresh process. Release diagnostics stay disabled.
- The game starts explicitly windowed. The runner reads the primary Windows display mode every 0.2 seconds and refuses startup unless it is 3840 × 2160. No Windows display-setting API is called.
- Acceptance requires successful probe completion, no `[LUA ERROR]` log entries, and no observed display-mode violations.

## Clean completed runs

| Guard / run | START → T1 | Extended checks |
| --- | ---: | --- |
| 373 / `windowed_373_full_a` | 74.283 s | Underground, resources, reveals, linked elevator pair |
| 374 / `windowed_374_full_a` | 74.056 s | Same full checks |
| 374 / `windowed_374_repeat_b` | 74.651 s | Fresh surface repeat, seating and button presence |

The two final-code (guard 374) runs average **74.354 s**, with a range of **74.056–74.651 s**. Both are accepted, have no Lua errors, and recorded no display-mode violations. The latest accepted time is **74.651 s**.

Evidence lives under [_ralph/runs/surface-under75-20260922](_ralph/runs/surface-under75-20260922): each run contains `measurement.json`, `game_log_tail.txt`, and `display_guard.json`.
The earlier guard-371/372 sub-75 measurements are **not clean acceptance results**: subsequent log review found an unbalanced temporary-source processing reason. Guard 373 fixed teardown through the engine's cancellation API; guard 374 additionally rejects foreign processing owners and blocks T1 on failed cleanup.

## Retained behavior and checked invariants

- 99 decorative groups / 3349 top-up objects are retained. Terrain-dependent formations use their full support-island placement planner; the final seating transaction still runs before T1.
- Native grounding retains 275 corrections, with zero capture/apply failures. The final independent seating pass performs three further native corrections, with zero rejected corrections.
- Real first underground access completes; paired-passage validation passes.
- Outer resource/landing audits pass for 38 resources and 10 rocket pads, with zero resource or rocket failures.
- Reveal Surface deep-scans all 400 sectors. Reveal Underground exposes all 111 tested explorable objects.
- The Place Elevator button opens construction, snaps to a real passage, and quick-builds both elevator halves with reciprocal links.
- Live native classification agrees with the full original predicate path on 23586 surface objects.
- Native compute-grid comparison against the literal scalar foothill raster checks 55296 cells; maximum height difference is one stored height unit.

## Removed redundant work

- Reuse immutable signed terrain-edge offers during refinement; retain scalar rechecks whenever earlier writes intersect the query region.
- Reuse shared mesh triangle trees and pose-local transformed bounds/vertices, with exact contact decisions and conservative unknown-geometry vetoes.
- Prove ordinary rocks exclude the union of gameplay/mystery/access classes in one native query instead of several overlapping queries. Dynamic names and parent ownership remain checked; custom/rebound APIs retain the original path.
- Seat terrain-dependent top-up formations during placement so loose pieces do not need a second late relocation transaction.
- Avoid scalar rounding repairs when the full-resolution foothill blend is already bounded within one U16 height quantum. Wider uncertainty still uses the literal scalar calculation; strict test callers default to zero tolerance. No grid-resolution reduction is used.
- Cancel only the exclusively owned temporary source's deferred processing after its final passage query, using `CancelProcessing` before map teardown. The ordinary flush remains the fallback; foreign owners are not discarded.
- Keep the authoritative surface passability commit and both necessary buildability rebuilds. Do not rebuild the entire map redundantly at the final seating barrier.

## Verification

- 51 compatibility test files, including seating-before-T1, source teardown ownership/fallbacks, geometry, support/rollback, and bounded rounding.
- Lua syntax checks for every `Code/*.lua` payload file.
- Terrain-edge tests: 268134 discovery checks, 655391 full track-order checks, and 3097 sampling checks.
- Class predicate comparison: 667222 return/query-order checks, including custom and rebound APIs.
- Strict apron tests: 15414 raster checks, 16170 domain checks, 221 native-mask failure/ownership checks.
- Bounded apron test: 145512 cells. Full production opportunity selection: nine scenarios retain the same selected sites and semantic reports, with the explicit one-height-unit blend allowance.
- Deployment audit: 43/43 payload files match the workspace.

These are local-machine timings and focused runtime checks for the requested scenario, not a guarantee for every seed or hardware configuration.

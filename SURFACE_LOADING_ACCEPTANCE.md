# Surface START-to-T1 — runtime acceptance and local checkpoint

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

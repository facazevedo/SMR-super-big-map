# v955 direct-seeded repair: five-scenario sign-off

Completed 2026-09-09 UTC. Tested production commit:
`26f691c25aca6bdc3994fb499093b64b53f46155` (`26f691c`), metadata955.
All ten standing rules are GREEN in the five owner-selected scenarios below,
on both maps wherever applicable. This is the final manual assessment combining
automated checks, source/RNG review, exact process provenance and visual QA.
It does not change the automated judge's deliberately review-only pending fields.

Ralph remains stopped. This completes the requested repair/verification step;
no next optimization or sub70 unattended loop was started.

## Timings and coverage

| Scenario | Expanded A | Expanded B | Two-run median | Native unexpanded control | Clusters/pads | Surface decor |
|---|---:|---:|---:|---:|---:|---:|
| 15S67E | 155.534s | 154.908s | 155.221s | 31.182s | 9/9 | 99/99 |
| 24S74W | 146.152s | 146.551s | 146.352s | 29.722s | 8/8 | 171/171 |
| 45S120W | 135.493s | 136.460s | 135.977s | 28.552s | 8/8 | 53/53 |
| 61N136W | 219.141s | 220.816s | 219.979s | 30.728s | 11/11 | 190/190 |
| 17S11W | 146.514s | 143.798s | 145.156s | 29.724s | 8/8 | 72/72 |

T0 is immediately before the START action body, after NewGame setup. Expanded
T1 requires both surface-stretch and post-pipeline-revalidation completion.
Player-controller underground first access follows T1. Native controls use their
normal generation-complete boundary. All15 processes were fresh, hidden, audited
before launch and normally closed; no test game remains.

These are two-run correctness samples, not a matched three-run before/after
performance experiment. None reaches70s. The decor matcher cache is retained,
but the512.940s instrumented old decor diagnostic is not a clean timing baseline.
Do not attribute the aggregate final times to an isolated optimization saving.

## Ten-rule assessment

| Rule | Final verdict in all five | Evidence |
|---|---|---|
| seed-parity | GREEN | Zero ordinary A/B parity differences; complete native Surface/Underground height/pass-grid/site/pad equality; private stream seeds/counts and decor attempts equal. One matching reservation/consumer/holder trace per expanded process. Source/RNG audit in SOURCE_REVIEW.md. |
| entrances-glued | GREEN | Both final surface endpoints reject the twin image with recorded native validity reasons and use the unchanged nearest-fitting outward hex-ring walk. Both underground endpoints are linked authored stretched images at ring0. |
| entrances-not-in-ring | GREEN | Both endpoints on both maps report ring_band=false in every expanded case. |
| ring-content | GREEN |8..12 complete seeded clusters, exactly one pad per cluster; all11 detailed resource/rocket/composition/extractor/anchor audit failure counters zero; full-map playability and aprons complete. |
| single-start-reveal | GREEN | Exactly the start sector revealed:15S D10,24S D8,45S D6,61N @14,17S D14. Full index/status records remain in rules_report.json. |
| badges-pre-reveal | GREEN | Two visible entrance signs at overview scale550; zero visible deposits in unexplored sectors and zero hidden deposits in scanned sectors; scan-then-visible proof passes. Underground has zero revealed sectors and two native imprints with control-matching visibility/scale. |
| decor-rules | GREEN | Surface placed=target as above; no mod decor in either outer band; cosmetic-only output and dropped-non-cosmetic counts recorded. Underground pass remains enabled: these authored maps have zero decor sites and zero native decoration passes, hence no invented density credit or disabled rule. |
| no-errors | GREEN | All15 final reports complete; empty optimization-failure states; no Lua/assert/native/crash signatures through incident-matched flushed logs and normal Debug::Done teardown. |
| process | GREEN | Exact tested commit/version955 for all15 distinct PID+creation-FILETIME identities; payload audited before every launch;37/37 deployed files, no missing/stale/mismatched files; production committed and unchanged throughout the matrix. |
| underground-first-access | GREEN | Normal ConstructionController:Place elevator then switch, linked passages, expanded820x946 underground, exactly one SBM loading cover and zero remaining references, no error. |

The native unexpanded controls do not consume the mod underground reservation
test seam, although the driver requests a pin. Their actual native AsyncRand seeds
are explicitly recorded in v955_acceptance_audit.json. They compare authored
reveal/imprint behavior on the same blank map, not generated-content determinism.
Expanded A/B use the same actual underground seed and prove the latter.

Source qualification: the inherited missing-map-seed EngineRandInt fallback is
unchanged. All tested maps have valid recorded seeds and take the private path.
This is not certification of arbitrary unseeded inputs or every possible map.

## Repairs and regression preservation

The direct planner uses finite buildable guide traversal and demand-driven local
candidates, continues into inner specifications when outer sources exhaust, and
retains exact static terrain plus live spacing/obstruction checks. No scenario
names, hardcoded map coordinates or seed exceptions were added.

Related failures exposed by the five-site run were repaired, not waived: bounded
building feathers (v950), transformed start reveal (v951), cosmetic finite decor
coverage (v952), clipped crease endpoints (v953), run-local native matching cache
(v954), and nondeterministic native-object deletion at provisional entrance poses
(v955). Temporary UI buttons and preceding numeric/cache/raster/rebuild optimizations
remain. All52 required offline commands pass on the exact v955 code.

The decisive v954 defect had1615 native pass cells different and21 native objects
different near discarded provisional entrance poses. v955 preserves those objects
while retaining native buildable-bridge repair. A native same-prestate cloned-grid
diagnostic proves both nontrivial helper outputs identical to stock repair. The
final five pairs now have exact full native pass-grid equality, without masking
cells or weakening the judge.

Compared with v954, all five top-up sites, rocket pads and decor outputs are
unchanged. Entire surface heights match in24S/45S/61N. In15S entrance1 moves
ring17->21 and in17S entrance2 moves ring14->22 because retained native obstacles
exclude earlier candidates. All30628/22183 changed height cells are confined to
the respective old/new entrance pads. Both new placements reproduce exactly.

## Visual assessment and excluded diagnostic attempts

All128 v954 base resource/edge views had already been reviewed with matched shadow
comparisons. For v955, all24 fresh24S base views and six shadow comparisons were
reviewed. Four specified fresh resource/edge views per other scenario were reviewed;
full raw height equality outside the identified entrance pads supports the previous
coverage. All eight new B entrance images for15S/45S/61N/17S were reviewed.
Per-scenario REVIEW.md files specify exactly what was inspected.

No new deposit-centered raised rim/moat or thin continuous artificial edge wall
was found in that coverage. Native craters, mountains, rocks and stock passage
imprints remain. Original raw8192 height captures and narrow-strip scans supplement
the screenshots. This is sampled regression QA, not universal future-map pixel
coverage. No images or terrain were edited for inspection.

Two15S B attempts failed only in optional post-canonical camera setup. The first
used a map switch outside a real-time thread; the second did not publish its ready
status. Both were normally closed, logged and preserved in the suffixed failed
directories. The helper was fixed to reuse the proven run-file visual setup; a
new fresh B completed the full capture/teardown. Neither failed attempt contributes
to accepted timings or the15-process sign-off. They were not unexplained retries
of a production failure.

## Evidence index

- `v955_acceptance_audit.json`: strict completed5/5, unique15-process audit,
  reservation traces, native/ordinary parity, automated gate verdicts and timings.
- `SOURCE_REVIEW.md`: main-agent and existing Astra source/RNG review and scope.
- `v955_offline_final/results.json`: all52 commands with exit0; adjacent text files
  contain parser/regression outputs.
- `v955_final_deployment.json`: final37/37 exact local-mod payload audit.
- `v955_matrix/manifest.json`: fixed five-site selection, exact seeds, boundaries
  and excluded test-only attempts.
- `v955_matrix/<site>_{a,b,control}/`: reports, final snapshots, identities,
  checkpoints and both flushed logs; `<site>_judgment.json` contains pair/control
  verdicts. A `visuals/REVIEW.md` and applicable B `entrance_visuals/REVIEW.md`
  contain the manual visual assessments.
- `v955_surface_preservation.json`, `v955_15s67e_height_difference.json`,
  `v955_17s11w_height_difference.json`: exact baseline geometry comparisons.
- `v955_clear_equivalence/diagnostic_state.json`: native cloned buildable-grid
  equivalence; a diagnostic, not an accepted timing run.

The small final assessment, source review, audit and manifest are versioned with
the ranking update. Large native raw grids, original screenshots and detailed run
logs remain in the local artifact directories and are not added to Git.

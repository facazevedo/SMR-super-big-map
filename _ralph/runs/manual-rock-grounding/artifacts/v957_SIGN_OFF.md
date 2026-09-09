# v957 selective rock grounding: five-scenario sign-off

Tested production commit `9982d4b77af76e781f17200091dafb2b24a5606f` (`9982d4b`),
metadata957. The final five-scenario matrix passes all ten standing rules after
combining the automated evidence with source, process and sampled visual review.
The automated judge's two deliberately manual-review fields remain pending in
its raw output; this assessment does not alter or weaken that judge.

## What changed

Decorative rocks that lose sampled native ground support because mesh Z grows
more than height-capped terrain Z receive an individually calculated downward
correction. Extra underside seating is limited by each mesh's surplus height.
Already supported rocks and fully proportional XYZ cases remain unchanged.
No new resizing, rotation, XY movement, terrain-writing pass, DLL or executable
patch is introduced. Functional objects and resources remain excluded. This
runs during new expanded-map generation, not retroactively across existing saves.

The previous source-to-destination relief offset, temporary buttons, top-up
strategy, terrain repairs and loading optimizations are retained. Source review:
SOURCE_REVIEW.md. This is a correctness repair, not a new performance strategy.
Ralph remains stopped and no under70s loop was restarted.

## START-to-T1 measurements

| Scenario | Expanded A | Expanded B | Two-run median | Native control | Rocks lowered |
|---|---:|---:|---:|---:|---:|
| 15S67E |154.529s|156.335s|155.432s|30.091s|271|
| 24S74W |149.682s|149.418s|149.550s|29.304s|0|
| 45S120W |139.319s|138.407s|138.863s|26.697s|0|
| 61N136W |224.104s|223.361s|223.733s|30.363s|0|
| 17S11W |149.806s|146.395s|148.101s|28.155s|278|

T0 is immediately before the START action body, after NewGame setup. T1 requires
surface stretch and post-pipeline revalidation to finish. Normal player-route
underground first access follows T1. Screenshots, exact grids and per-rock census
are post-stopwatch. These are two-run correctness samples, not a matched
three-run performance experiment or an isolated optimization saving. None is
under70s. Grounding capture counters include eligibility work, unlike the early
instrumented diagnostic's partial counters.

## Ten-rule final assessment

| Rule | All five | Evidence |
|---|---|---|
| seed-parity | GREEN | Exact ordinary/private-stream parity, complete Surface/Underground height/pass-grid/site/pad equality, and identical corrected-rock geometry in A/B. Single matching reservation/consumer/holder trace per expanded run; no new RNG call in the source delta. |
| entrances-glued | GREEN | Both surface endpoints use unchanged native validity tests and nearest-fitting outward ring walk where required; both underground endpoints retain linked authored stretched images. |
| entrances-not-in-ring | GREEN | Both endpoints on both maps report ring_band=false. |
| ring-content | GREEN |8..12 complete seeded clusters with one pad each; all11 detailed terrain/composition/extractor/anchor failure counters zero; full-map playability and aprons complete. |
| single-start-reveal | GREEN | Exactly the start sector revealed in each expanded run. |
| badges-pre-reveal | GREEN | Entrance signs visible at overview scale550; unexplored deposits hidden and scan-then-visible proof passes; underground authored reveal/imprint behavior matches native controls. |
| decor-rules | GREEN | Cosmetic-only target coverage, no mod decor in the outer bands; underground decor path remains enabled with the documented native zero-site case. Only metadata-qualified native rocks receive grounding. |
| no-errors | GREEN | All15 final reports complete, no optimization failures, no Lua/assert/crash signatures in both incident-matched flushed logs, and normal shutdown. Grounding failures zero on both maps in every expanded case. |
| process | GREEN |15 distinct PID+creation identities, exact957 checkpoint and payload audited before each fresh launch, unchanged committed production during the matrix,38/38 deployed files. |
| underground-first-access | GREEN | ConstructionController:Place elevator and normal switch succeed; linked expanded820x946 underground, exactly one SBM cover, zero remaining cover references. |

54 offline commands pass, including30 new grounding assertions. All corrected
objects retain native-derived XY, scale, angle and axis; their final Z equals
base Z minus the recorded calculated drop. Unexpanded controls have no grounding
stats or corrected rocks. Native controls do not consume the mod's requested
underground seed pin: they compare authored reveal/imprint behavior on the same
blank map, while expanded A/B prove generated-content determinism. Actual native
control seeds are recorded. The inherited missing-map-seed fallback qualification
from v955 remains; this is not certification of arbitrary unseeded inputs.

## Terrain and visual preservation

All five resource sites and pads are exactly unchanged versus v955. Complete
surface heights are also identical in15S/24S/45S/61N. In17S, all67,108,864 native
height cells were compared: exactly13,496 cells around the unchanged second
entrance are one U16 unit lower; all other cells are identical. The entrance's
native/buildable plane is Z7586 rather than7587. Its XY and nearest-ring result
are unchanged, and the entire output repeats exactly in A/B. Moving collidable
rocks changes inputs to existing buildability processing; the new grounding
module itself contains no terrain write. No map-wide terrain change is hidden.

Both affected scenarios' three largest class-distinct rock corrections were
reviewed in all12 before/after images. Ten fresh resource/edge views and all ten
B entrance views were inspected, supported by the exact baseline terrain
comparisons and previous v955 visual coverage. No new resource-centered rim/moat
or thin artificial edge wall was found in that coverage. Native overhangs,
craters, mountain faces and passage imprints remain. Exact filenames and limits
are recorded in VISUAL_REVIEW.md; this is sampled QA, not universal pixel proof.

## G3 reproduction and evidence

The exact final v957 G3 reproduction completed successfully in fresh visible
PID12104. The production path automatically lowers CliffDark_03 from Z28391 to
26264 (2127wu), close to the owner-approved2000wu manual trial. XY552079,141411,
scale249, angle19228 and axis(-1241,-2853,2663) are unchanged. Ground30038 is
unchanged through the later generation pipeline; all12 sampled native support
points remain supported.160 of14447 eligible rocks were corrected, with no
grounding or optimization failure. The original overview and closer screenshots
were inspected; the corrected paused G3 scene remains open. No manual lowering
override was used and the correction was not restored to the floating pose.

This instrumented reproduction measured153.679s START-to-T1 (capture2466ms,
apply88ms), not one of the accepted cold timing samples. One debugger query timed
out during busy generation; the exact process remained alive and the subsequent
query/capture completed. No production Lua/assert error was recorded. Live logs
are intentionally not described as flushed teardown logs while this scene is open.

The earlier bounded v956 diagnostic's logs/timing are excluded from acceptance
because temporary diagnostic helpers emitted strict-global errors; those helpers
are fixed. The support-only263wu draft was not accepted as the visual solution.
The initial v956 matrix and hot-reload attempt are also preserved but excluded.

- v957_acceptance_audit.json: strict5/5,15-process,54-offline audit, no issues.
- v957_matrix/manifest.json: fixed selection, checkpoint and timing boundaries.
- v957_matrix/<site>_{a,b,control}/: canonical reports/snapshots, exact identities,
  checkpoints, flushed logs and original images; five adjacent judgments.
- v957_offline/results.json: all54 commands and exit status.
- v957_17s11w_height_difference.json: complete raw-height difference localization.
- SOURCE_REVIEW.md and VISUAL_REVIEW.md: the separate manual review evidence.
- v957_g3_final/report.json and original grounded*.png: final automatic G3 proof.
- v957_final_deployment.json: final exact local-mod payload audit.

Large original images, native raw grids and detailed logs stay local. Small final
assessment/audit/manifest files are versioned with the ranking update.

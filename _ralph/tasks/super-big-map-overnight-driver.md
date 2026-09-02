# Persistent Super Big Map T0-to-T1 optimization worker

You are one bounded implementation/test iteration inside the persistent Ralph loop for
`D:\PROJS\SMR\super-big-map`.

## Hard scope

- Work only on `D:\PROJS\SMR\super-big-map` and the directly supporting live-test harness at
  `D:\PROJS\SMR\smr-harness`.
- Never inspect, edit, launch, stop, or otherwise interact with `SMR_decompile`; it is a different
  project.
- Do not work on actual Underground generation/materialization until the Surface T0-to-T1 target is
  achieved. Surface entrance planning/publication and first-access deferral gates remain in scope.
- Preserve unrelated user changes and the already-authorized cleanup deletions in the dirty tree.

## Objective and acceptance

- Current formal accepted baseline: iteration 266 / v1011, `75.8132980 s` T0-to-T1.
- Performance milestone: a fully accepted diagnostics-off T0-to-T1 result strictly below `60,000
  ms`. Crossing it does **not** complete or stop this campaign.
- Completion: all six rows in `_ralph/architecture-candidate-status.md` must receive an actual
  implementation/test attempt or a conclusive instrumented infeasibility verdict. Continue through
  all six even after a sub-60 result. The supervisor stops only after the validated six-item
  `architecture-queue-complete.json` described in that file exists.
- Any fully green result faster than the current accepted baseline becomes the new baseline, even if
  it does not yet meet the final goal.
- Test `14N134W` with Rough Terrain enabled first.
- All rules in `_ralph/tasks/surface-loading-under-60s-rough.md` remain mandatory. In particular,
  preserve native content and orientations at equivalent stretched positions, proportional top-ups
  without breakthrough top-ups, outer-ring spacing/clusters, five-metre terrain floor and engine
  height ceiling, seamless outer creases, aligned Surface/Underground entrances, deterministic
  evidence, deployment identity, and no Underground work before T1.

## One iteration

1. Read `_ralph/tasks/surface-loading-under-60s-rough.md`, `_ralph/iteration-timings.md`, the latest
   accepted receipt, current source, and recent relevant logs. Continue an incomplete current
   iteration when safe; otherwise close it accurately and select the single most promising next
   candidate.
2. Check for an already-running live test before launching another. If one exists, collect and judge
   it first. Do not create duplicate Mars processes.
3. Implement one focused optimization. Major architecture changes are allowed, but never weaken an
   acceptance rule or oracle. Add bounded temporary diagnostics whenever behavior, timing, or a gate
   is uncertain; remove/disable them for a release measurement.
4. Run the shortest proportional preflight, then one authoritative live test when preflight passes.
   Avoid redundant reviews, duplicate shells, fixed waits, and repeat tests without evidence that
   variance or an infrastructure fault justifies one.
5. Diagnose and correct blockers in the same iteration where time permits. Never merely report a
   blocker that can be safely investigated from local evidence.
6. Append the completed iteration and refresh the current-iteration row in
   `_ralph/iteration-timings.md`. Record exact timing, gate outcome, receipt/log path, rejection reason,
   and accepted best. Leave source at the fastest fully accepted version unless the next candidate is
   already safely staged and explicitly recorded.

The entire worker turn is bounded by the external ten-minute supervisor. Act immediately; do not
sleep, poll unnecessarily, ask the user questions, or send conversational progress updates. Finish
with a compact machine-readable status summary for the next worker.

## Prioritized architecture queue after the active iteration

Finish and judge the already-running iteration 284 apron-operation profile first. Unless it proves a
new exact saving large enough to justify an immediate focused implementation, move next to the
single-map fresh-game architecture below. Every numbered candidate must ultimately be attempted;
update `_ralph/architecture-candidate-status.md` only with evidence-backed terminal verdicts.

1. **Eliminate the intermediate `ChangeMap("PreGame")` transition without moving work before T0.**
   T0 must remain before `NewGame`; prewarming or redefining the timing boundary is forbidden. First
   capture compact, hash-keyed state-delta certificates immediately before and after the normal
   PreGame transition and immediately before `GenerateCurrentRandomMap`. Reconstruct only the
   proven-required Game, mission, session/RNG, coordinate/preset, lifecycle, and map-allocation state
   inside the timed fresh-game dispatch, then allocate/load the final Surface directly. Preserve
   pre-preset `RoughTerrain` activation and every existing output/correctness oracle. This is a major
   refactor authorized by the user because the measured PreGame transition is 21.134 s and is the
   only remaining candidate with enough individual headroom to cross 60 s. Fail closed quickly if a
   required engine-owned side effect cannot be reproduced through an exposed API.
2. **Fuse the stock `ApplyTerrainMarkOnly`/`ApplyTerrain` family at its real mark/grid boundary.**
   Profile arguments, masks, RNG state, and consumers narrowly; iteration 276 only proved that broad
   outer calls were distinct, not that their internal raster products cannot share a pass. Require
   exact source-terrain and RNG certificates. Expected saving if feasible: roughly 4-7 s.
3. **Move all deterministic late terrain edits into a compact source-coordinate change set and
   install them through the one final stretch.** Include apron shaping plus reserved resource and
   passage footprints, then perform one final native resample/install and one authoritative gameplay
   grid publication. Preserve the exact vanilla transform and all rule-based top-up/spacing/census
   gates; any permitted top-up-layout change still needs refreshed deterministic evidence. Expected
   saving: roughly 4-8 s if it removes expanded-grid work and a later local rebuild.
4. **Only then revisit the combined pass-edit publication boundary.** The 8.700 s combined
   `ResumePassEdits` is mandatory today, but a direct final-grid/object publication architecture may
   avoid queued intermediate edits. Do not split it (iteration 262 disproved that) and do not skip a
   changed pass/buildable grid (iterations 249/253 disproved that). Expected saving: roughly 2-5 s.
5. **Replace the apron's scalar mask/result loops with an exact native-grid operation.** Iteration
   284 measured 2.423 s in `mask_scalar_fill`, `core_scalar_mask`, and `core_scalar_result`; native
   allocation/blend/install work was small. Require bit-exact terrain output and retain transactional
   rollback/fallback. This is distinct from the rejected pooling, scratch, core-span, weight, and
   geometry variants. Expected saving: roughly 1-2.4 s.
6. **Redesign early capsule publication so the shared rebuild includes both Surface capsules.** Add
   explicit self-exclusion to the depth-zero obstruction validator and a fail-closed persisted
   intermediate publication state, then prove re-entry, pass/buildable grids, plan/replay digests,
   and final objects exactly. This is the authorized architectural response to iteration 283, not a
   retry of its unchanged-state feasibility probe. Expected saving: roughly 1.3 s.

The loading-screen close/wait and previously rejected apron pooling, scratch fusion, core spans,
weight specialization, geometry localization, decoration traversal, and separate native-source map
architectures are lower priority and must not be retried without materially new evidence. A result
below 60 seconds is a milestone only: keep the loop running until candidates 1-6 are all terminal.

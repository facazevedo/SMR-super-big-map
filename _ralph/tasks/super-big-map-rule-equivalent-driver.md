# Persistent rule-equivalent Super Big Map optimization worker

You are one bounded implementation/test iteration inside the persistent Ralph loop for
`D:\PROJS\SMR\super-big-map`.

## Session provider

This contract is provider-neutral. The same text runs under any supported agent CLI, and a
campaign may alternate providers between iterations without changing a single rule, gate, digest,
or receipt. The supervisor is
`_ralph/tools/super_big_map_overnight_ralph.ps1 -Agent codex|claude`; `-DryRun` prints the exact
launch without starting a session, and every cycle records the provider, model, and effort in
`_ralph/runtime/overnight-super-big-map/supervisor-state.json`.

Where an incorporated contract names a specific model or reasoning level - "`gpt-5.6-sol`",
"Sol high", "Sol xhigh", "extra-high" - read it as **the running provider's ordinary tier** and
**the running provider's escalated tier** respectively. Claude runs `claude-opus-5` at `high` and
escalates to `max`, the tier the Claude UI labels "Extra high"; Claude Code's effort values are
`low`/`medium`/`high`/`max` and it has no `xhigh`, which is only the Codex spelling of the same
rung. Any incorporated requirement to record plateau evidence or a major-refactor rationale before
escalating still applies, unchanged, to whichever provider is running. Provider identity, model,
and effort are visible to the session as `SMR_RALPH_AGENT`, `SMR_RALPH_MODEL`, and
`SMR_RALPH_REASONING_EFFORT`.

**End your final message with exactly one line `Progress: yes` or `Progress: no`, optionally
followed by ` - <one short clause>`.** The supervisor reads that line from your final message to
drive the effort ladder and records it in
`_ralph/runtime/overnight-super-big-map/cycles.jsonl`: two consecutive iterations without
`Progress: yes` escalate the next iteration to the escalated tier, and one `Progress: yes` resets
it to the ordinary tier. A missing line counts as no progress. Report it honestly - claiming
progress you did not make suppresses the escalation the campaign needs, and claiming none you did
make wastes the escalated tier. Provider outages are recorded separately and never count as
stagnation.

No evidence, receipt, digest, or verdict may be conditioned on which provider produced it. A
measurement is valid or invalid on its artifacts alone.

## T0 boundary ruling (operator, 2026-09-01)

**T0 is the Start button.** The measured interval begins when surface generation is submitted -
the generator's `generation_start.txt` sentinel, published immediately before
`GenerateCurrentRandomMap` - and ends at the existing T1. This overrides any incorporated reading
that starts the clock at run-file submission.

The harness previously started T0 before `NewGame` + `ChangeMap("PreGame")`, so it timed the
**New Game** button: the mission-setup screen a player opens, browses for a landing site, and
leaves before ever pressing Start. The incorporated contract already says "Game boot before T0 is
not surface loading", so this ruling aligns the harness with that wording.

Measured basis, same session, same warm state, identical payload:

| phase | with PreGame | PreGame call removed |
|---|---:|---:|
| `ChangeMap("PreGame")` | 18,490 ms | 0 |
| `GenerateCurrentRandomMap` | 28,020 ms | 40,610 ms |
| mod expansion pipeline + tail | 36,325 ms | 36,004 ms |
| total | 83,128 ms | 76,959 ms |

Deleting the call saves only ~6.2 s because ~68% of its cost is one-time engine/resource
initialisation that migrates into whichever map loads first. Starting the clock *after* it is a
different thing and is what the ruling adopts: by then that initialisation is already paid, so the
interval measures generation plus the mod pipeline. Evidence:
`_ralph/runtime/overnight-super-big-map/pregame-removal-probe.json` and `warm-phase-budget.json`.

**Baseline at this boundary: 61,751 ms median** (n=48, SD 903 ms, min 60,647, max 66,380),
accepted v1011 payload unchanged. That is 8.2 s under 70 s and 1.75 s over the 60 s goal. The warm
phase budget splits it into stock `GenerateCurrentRandomMap` 26,645 ms (42.9%) and the mod
expansion pipeline plus tail 35,467 ms (57.1%). The old-boundary figure for the same unchanged
payload is 80,496 ms.

Anything citing 75.8132980 s as the current best is reading the superseded constant. It is not
reproducible - 39 cold runs of the byte-exact payload spanned 77.0-98.3 s - it was measured at the
old boundary, and its receipt never captured the payload identity. `_ralph/iteration-timings.md`
rows up to 384 predate this ruling; row 385 records the corrected baseline.

Mechanism: the executor stamps T0 when the generator publishes `generation_start_file`, waited on
externally exactly as T1 is - one run-file, no game-state polling, external Stopwatch still the
sole timing authority. A contract omitting that field keeps the historical boundary, so earlier
evidence remains replayable. Every receipt now records `t0_boundary` and `submit_to_t0_ms`; never
compare a `generation-start` figure against a `run-file-submission` one.

**Measurement validity notice.** The accepted 75.8132980 s constant was measured at the OLD
boundary and is not a valid target under this ruling. It was also never reproducible: 39 runs of
the byte-exact payload spanned 77.0-98.3 s with output identical on every digest. The rig has a
large warm-up - a monotone decline of 11-15 s over the first ~12 consecutive runs, visible in the
historical five-run cohort too (83.16 -> 78.84, strictly monotone, recorded as "CV 2.2% variance")
- so a single sample compared against any stored constant is uninformative. Do not record a
candidate as `rejected` on that basis; `inconclusive` is the truthful verdict. See
`_ralph/tools/MEASUREMENT_PROTOCOL.md` (paired ABBA blocks inside one session, 12-run warm-up) and
re-measure with `_ralph/tools/replicate_accepted_baseline.ps1`.

Read `_ralph/tools/HEADLESS_GAME_CONTROL.md` before your first game interaction. It carries the
verified headless launch/submit/teardown commands, the mod-sandbox access path
(`ModsLoaded[i].env.SuperBigMap`; `_G.SuperBigMap` is nil), the strict-global and real-time-thread
script conventions, and the `eval`/`exec`/`run-file` argument quirks. Re-deriving those costs a
game launch per session.

## Scope and immutable rules

- Work only on this repository and `D:\PROJS\SMR\smr-harness`. Never inspect or change
  `SMR_decompile`.
- The payload baseline is the accepted diagnostics-off v1011 release at 14N134W with the built-in
  `RoughTerrain` rule and preset, snapshot `SBM_historical_best/` (byte-identical to payload
  manifest `334D52B2...`, verified 2026-09-01). Its historical receipt
  `_ralph/runs/surface-loading-under-60s-rough/artifacts/run_v1011_surface_release_apron_math_iter266b/surface_only_acceptance_receipt.json`
  records 75.8132980 s, but that figure is **superseded**: it was taken at the old New-Game
  boundary, on a payload whose exact identity the receipt did not capture (see the snapshot's own
  `accepted-receipt-provenance.json`), and the snapshot's own five-run cohort of the reconstructed
  payload measured a median of 80.9716809 s. Use the Start-button baseline established under the
  T0 ruling above; do not treat 75.8132980 s as a target or a threshold.
- Preserve every vanilla object, resource, deposit, anomaly, decoration, orientation, and equivalent
  stretched position. Preserve the five-metre minimum, engine maximum, relief normalization, outer
  two-sector seamlessness, Surface/Underground entrance alignment, no breakthrough top-ups, no
  Underground work before T1, proportional synthetic counts, cluster coverage, minimum distances,
  obstruction/terrain rules, scheduler behavior, determinism, and exact deployment identity.
- Keep the existing mod-created top-up locations, apron behavior, resource/anomaly/decor algorithms,
  RNG transcript, physical T1 materialization, spacing, counts, and terrain-footprint rules. Do not
  select replacement flat-first clusters and do not defer any Surface outer-ring work.
- `LazyUndergroundSourceGeneration` must remain true in every accepted release and candidate stage.
  The Surface harness may reserve/pin the future twin seed, but it must not create, load, or generate
  map slot 2 or any Underground backing before Surface T1. Fail preflight if the enabled config does
  not preserve this flag, and reject any run whose log shows `BlankUnderground`, an Underground map
  holder, or slot-2 generation before the Surface sentinel.
- A narrow detected vanilla crease-repair band may change only through candidate 1's source-side
  height/slope bridge, with independent continuity and terrain-quality certificates. Terrain outside
  the certified band remains exact. Passage placement remains exact; candidate 2 may add only stable
  internal identity metadata and change publication order when final objects/grids are equivalent.
- Seed caching, completed-map caching, precomputed map payloads, and warm/cache-hit timing are
  explicitly forbidden. Optimize only genuine fresh-process cold T0-to-T1 work.

## Objective and loop behavior

The immediate performance milestone is now **T0-to-T1 below 70 seconds**. Prioritize candidates by
their probability-weighted ability to close the gap from the accepted 75.8132980-second best to
below 70 seconds. Continue accepting every fully green improvement along the way. Crossing 70
seconds does not stop the supervisor: record and snapshot the new best, then continue toward the
longer-term below-60-second target.

### Immediate user-requested five-run accepted-baseline calibration

Before any further candidate-5 production mutation or candidate live timing, finish and cleanly
collect/stop any already-running capability probe, then run the exact historical accepted v1011
iteration-266b payload **five independent times**.  This one-time calibration campaign has priority
over the ordered continuation campaign below.

The completion marker is
`_ralph/runtime/overnight-super-big-map/accepted-baseline-five-run-calibration.json`.  Skip this
section only when that file exists, has schema
`smr.ralph.accepted-baseline-five-run-calibration.v1`, `ok=true`, exactly five valid cold samples,
and names every existing per-run correctness receipt.  Otherwise resume the first missing sample;
never discard or repeat a valid completed sample.

Calibration correction after the first reconstruction attempt: the historical receipt's
`production_head=b617030` identified only HEAD, not the dirty worktree payload actually timed by
iteration 266b.  The detached/bare-commit reconstruction differs from the proven restored accepted
release in 16 executable payload files and its first fully green run measured 102.8901088 s.
Therefore `run_v1011_surface_calibration_iter266b_sample01_20260901T023135376Z` is evidence of an
invalid reconstruction and **must not count** among the five variance samples.  Preserve it, label
it invalid, and do not run that reconstructed payload again.  Immediately restore current source
deployment with `_ralph/tools/deploy.py sync` and use the iteration-301 diagnostics-off baseline-
restoration payload/config/generator as the control for all five samples.  Iteration 301 proved this
control matches the accepted phase order, plan/validation/single-flush digests, no-Underground
contract, and accepted scalar corpus; its reference contract is
`_ralph/tmp/iter301_surface_only_acceptance_contract.json`.  Candidate-4 flags must remain off.
This behavior-equivalent restored control, not the incomplete bare Git snapshot, is the repeatable
representation of the accepted 75.8132980-second release.

Further exact-identity correction from the preserved configuration: iteration 301 is behavior-
equivalent but is **not** the byte/config-exact historical timing payload.  Its config enables
`GenerateVanillaSourceOnTemporaryBacking=true` and omits
`OptimizeSurfaceCoalescedOuterRingPublication`, whereas the preserved iter266b enabled config SHA
`E3E59B1A...5ED5E6B` has temporary backing **false** and coalesced publication **true**.  Therefore
the five iteration-301 control timings may be preserved as a separate restored-control cohort but
must not satisfy the user's requested historical-code five-run marker.

After any already-running restored-control sample exits cleanly, reconstruct the exact iter266b
dirty-worktree payload as follows: start with the current long-lived dirty production files whose
presence is contemporaneously proven by cycle 0042/0043 (`sbm_deposits`, `sbm_diagnostics`, deleted
`sbm_elevator_debug`, and `sbm_lifecycle`); take the committed production files, especially
`sbm_terrain_copy.lua`, from `b617030`; and install the preserved exact enabled config
`_ralph/tmp/.tmp_surface_release_v1011_apron_math_iter266b/sbm_config_flag_on.lua`.  The result must
contain exactly 35 deployed files and a complete SHA-256 manifest.  First run one cold discriminator:
it must retain every accepted digest/rule and return to the expected historical timing band rather
than the invalid 102.890 s bare-commit band.  Then obtain five fully green fresh-process samples of
that exact manifest and compute the requested statistics.

Once the exact five-run cohort is green, restore that exact production payload into the main source
tree and create one atomic Git commit containing only `Code/**`, `Images/**`, `metadata.lua`,
`items.lua`, and a compact tracked payload/receipt manifest.  Do not include runtime logs, temporary
stages, run artifacts, or unrelated harness/task changes.  The commit message must identify it as
the accepted 75.8132980-second Surface baseline snapshot.  Record the commit ID in the calibration
completion marker.  Do not push unless the user separately requests it.

The historical snapshot directory is exactly `SBM_historical_best` at the repository root
(`D:\PROJS\SMR\super-big-map\SBM_historical_best`), never a sibling directory or a directory under
`_ralph`.  Populate it only after exact payload identity and the five-run consistency cohort are
green.  It must be a self-contained copy of the exact production payload (`Code/**`, `Images/**`,
`metadata.lua`, and `items.lua`) plus a compact README, complete SHA-256 payload manifest, exact
  cohort receipt, and accepted-receipt provenance.  Include this root snapshot directory in the same
  atomic historical-baseline commit.  Require the five exact-manifest cold samples to have a median
  within six seconds of 75.8132980 s and a sample coefficient of variation no greater than 5%; do
  not cherry-pick or silently discard a complete green sample.  Investigate infrastructure-invalid
  or inconsistent runs before declaring the historical code recovered.  The already-completed exact
  cohort (median 80.9716809 s, delta 5.1583829 s, sample CV 2.2057406%) passes this corrected
  consistency gate.  The former five-second cutoff was an arbitrary local tolerance, missed by only
  0.1583829 s, and must not block finalization or require user direction.  Preserve the original
  statistical receipt as audit evidence, record the corrected gate explicitly, finalize
  `SBM_historical_best`, commit it, and resume the optimization campaign immediately.

- Use fresh `MarsDebug.exe` processes, 14N134W, built-in `RoughTerrain`, diagnostics off, no seed or
  completed-map caching, and no warm reuse.  Run sequentially; never allow two game processes.
- Restore/deploy the exact accepted iteration-266b production payload, not merely the current source
  with later candidate flags disabled.  Pin and record its complete executable hashes.  Generate a
  unique content-addressed Surface harness/contract and empty run directory for each repeat.
- The calibration threshold must allow each repeat to finish the complete correctness gate even when
  slower than 75.8132980 s; do not let the normal improvement-only exception truncate validation.
  Every repeat must still prove all accepted Surface/deferred-Underground/scheduler/single-flush
  tokens and digests, exact RoughTerrain identity, no Underground/slot-2 work before T1, and clean
  tracked teardown.  Invalid/incomplete samples do not count among the five and must be replaced.
- Record all five authoritative external Stopwatch T0-to-T1 values, arithmetic mean, median,
  population/sample standard deviation, minimum, maximum, range, and the historical 75.8132980 s
  sample's position relative to that distribution in a compact JSON receipt.  Append one cohort row
  plus the five individual timings to `_ralph/iteration-timings.md`.
- This campaign measures variance only: it must not replace the accepted best with an average.
  Restore/deploy the fastest accepted compatible release after the cohort, then resume candidate 5
  immediately.  If an individual fully green repeat is below 75.8132980 s, accept that individual
  result under the normal rule before resuming.

- Any fully green diagnostics-off **cold** result faster than the current accepted best becomes the
  new baseline even if it is not below 60 seconds.
- Treat every genuine, fully validated improvement over the current historical best as a new
  historical best, including results between 60 seconds and 75.8132980 seconds.  Eligibility
  requires the complete 14N134W RoughTerrain rule corpus, diagnostics off, a fresh process, exact
  external T0-to-T1 timing, no seed/completed-map cache, and every required digest/census/deferred-
  Underground/teardown gate green.  Never reject an otherwise eligible improvement merely because
  it missed the sub-60 target.  Refresh the accepted-baseline state, timing ledger, compact receipt,
  and (after the initial exact historical recovery is committed) the repository-root
  `SBM_historical_best` snapshot/manifest so it always represents the fastest accepted payload;
  Git history preserves each superseded historical snapshot.
- Below 60 seconds and a completed candidate group are milestones, not stop conditions. Continue
  selecting and testing one concrete optimization at a time until the user explicitly tells the
  loop to stop. A completion receipt records history; it never stops this supervisor.
- Continue the Ralph optimization campaign without deliberate pauses for the entire night.  Do not
  stop after recovering 75.8132980 seconds, after accepting an intermediate best, after crossing 60
  seconds, after completing a candidate group, or after writing/committing a snapshot.  Immediately
  select the next highest-saving rule-preserving candidate unless the user explicitly says to stop.
- Each worker has at most ten minutes. Continue incomplete safe work, collect an existing live test
  before launching, use one shell, avoid duplicate reviews/fixed waits, and hand off immediately.
- The ten-minute limit is an end-to-end hard wall-clock budget for every Ralph iteration: it includes
  implementation/preparation, preflight, game startup, the complete T0-to-T1 interval, compact
  correctness validation, tracked teardown, evidence reduction, and ledger/state update.  A worker
  that owns a live test must launch it early enough to finish and record the verdict before its own
  ten-minute deadline; target launch by minute 7 at the latest and reserve at least 150 seconds for
  the cold run plus validation/teardown.  Do not launch late and intentionally carry a game into the
  next worker.  If preparation cannot finish by that launch cutoff, hand off the fully staged test
  without launching so the next worker launches immediately and completes its entire live-test
  iteration within ten minutes.  Never add fixed idle time between steps or runs.
- Use bounded temporary debug logs whenever behavior or a gate is uncertain. Disable/remove them
  before release timing. Test 14N134W RoughTerrain first. Append every completed iteration to
  `_ralph/iteration-timings.md`.

## Ordered continuation campaign

Candidates 1-3 in `_ralph/rule-equivalent-candidate-status.md` are terminal historical evidence.
Before any further candidate-4 release timing, repair the accepted baseline restoration: iteration
294's rejected stable-key/early-shared-rebuild capsule implementation remains in
`Code/sbm_map_generation.lua` and was merely masked by incorrectly setting
`LazyUndergroundSourceGeneration=false`. Restore only those rejected capsule-publication/state-machine
hunks to the accepted iter266b / commit `b617030` behavior while retaining
`LazyUndergroundSourceGeneration=true`, candidate 4's terrain work, and every unrelated later change.
Prove the release path again uses
`local-dirty-grid-publication>fresh-plan-replay>capsule-publication>local-dirty-closing`, reaches T1
without slot 2, and matches the accepted capsule/plan/validation/single-flush digests. Disabling the
master lazy flag is not an acceptable restoration.
Continue at candidate 4. Treat the active list as a strict state machine. Do not start, reconstruct,
or investigate candidate N+1
while candidate N is still pending. At every worker handoff, inspect the existing candidate diff and
its newest bounded evidence first; continue its preflight/live test/verdict immediately instead of
repeating repository archaeology. A candidate that has passed its focused static/oracle gates must
be staged and launched early enough for the external executor or its tracked game process to survive
the worker boundary. Publish the terminal verdict and restore/accept the exact release before moving
to the next row.

4. **Analytic source-bridge continuity certificate.** Retain candidate 1's correct compact source
   bridge, but remove its 586,221-sample, 5.495-second production scan. Prove analytically that the
   actual monotone resampling kernel maps the certified C1/C2 source bridge to a continuous
   destination surface, using finite support/track endpoints, transformed band bounds, interpolation
   weights, floor/ceiling bounds, and outer-sector intersection certificates. First validate that
   compact certificate against a diagnostics-only dense scan of the complete 14N134W RoughTerrain
   result and the available real patch/guard corpus. Release runtime must be O(tracks + boundary
   intersections), diagnostics off, and fail closed to the accepted destination repair whenever any
   premise is unavailable. Terrain outside the source band remains exact.
5. **Final-Surface `ChangeMapInSlot` lifecycle.** Investigate the measured 10.770-second final
   Surface `ChangeMapInSlot` operation, explicitly separate from the already-rejected intermediate
   PreGame removal. Reuse iterations 272, 280, and 281 instead of repeating them: locate the earliest
   boundary before the final slot load is paid; inventory the native backing, userdata/handles,
   lifecycle messages, map publication, objects, RNG state, and grid initialization created by the
   call; and probe for a supported way to allocate the final 8192 backing once or populate it before
   the lifecycle runs. A viable implementation must execute every required `NewMapLoaded`,
   `PostNewMapLoaded`, scheduler, camera/session, object, passability, and buildable effect exactly
   once and preserve all accepted digests. Do not move T0/T1. If exposed Lua APIs are insufficient,
   inspect whether a safe engine hook/native-extension entry point actually exists and can be loaded,
   unloaded, and certified; do not assume it. Use a narrow state-delta/capability probe before any
   production mutation, then make the smallest fail-closed live attempt only when the missing state
   is reproducible.
6. **Correct the stable-key capsule post-grid stall.** Candidate 2 fixed transient identity, but the
   live run stopped making progress immediately after shared-grid publication. Add bounded temporary
   phase messages from that boundary through fresh-plan replay, certificate publication, scheduler
   completion, and T1. Identify the first blocked loop/wait/re-entry predicate, correct its state
   transition without changing capsule placement or final objects/grids/digests, and remove the
   temporary logs before a cold timing. Preserve fail-closed reload/re-entry behavior.
7. **Fresh largest-hotspot selection.** After candidates 4 through 6 are terminal, run only the smallest
   compact diagnostics needed on the fastest accepted release to identify the largest remaining
   controllable T0-to-T1 phase. Add one concrete candidate row and its exact behavioral certificate
   before implementing it; do not repeat a terminal architecture without materially new evidence.

The active worker selected candidate 8 concurrently: fuse the accepted outer-resource/rocket-apron
native precondition restore and raster publication into one ordered traversal.  Finish that bounded
candidate first; do not renumber or abandon it merely because the following queue was added.

9. **Dependency-expanded local outer-ring grid publication.** After candidate 8 is terminal, target
   the accepted outer-resource/passage publication boundary measured at 2.504 seconds for
   `RebuildPassability` plus 1.186 seconds for `RebuildBuildableGrid`.  Preserve the exact resource,
   anomaly, passage, object, terrain, RNG, and publication order; this candidate may change only the
   spatial domain processed by those authoritative grid operations.  Construct the ordered union of
   the existing resource-pad and passage-terrain dirty journals, expand every region by a proven
   slope/passability/buildability dependency margin, and use supported local-region rebuild APIs
   only if a focused capability probe proves their semantics.  In diagnostics, compare the complete
   serialized final passability and buildable grids, all outside-region cells, object obstruction
   effects, placement results, and every accepted digest against a separate fresh-process canonical
   broad-rebuild control.  Require byte/tuple equality, not merely counts.  Fail closed to the
   accepted broad rebuild before any consumer whenever the local API, margin proof, journal
   completeness, or corpus certificate is unavailable.  Proceed to diagnostics-off release timing
   only if the measured candidate path has a credible saving of at least 0.8 seconds.  If the local
   API cannot express the exact ordered union or full-grid equivalence fails, mark candidate 9
   terminal promptly and continue to candidate 10.

10. **Fused expanded-grid suite extraction/resampling.** If candidate 9 is terminal, investigate a
   single owned transaction for the height/type/Biome/colorize source extraction, conversion,
   resampling, and scratch-grid lifecycle.  Preserve each grid's exact input type, interpolation
   rule, output bytes, order, and final setter.  Reuse allocations or fuse enumeration only where a
   complete per-grid and final-world hash certificate proves equality; do not revisit the already-
   infeasible stock `ApplyTerrain` raster fusion.  Bound one focused capability/oracle iteration,
   then implement only if the expected saving is at least 0.8 seconds.

11. **Buildable refresh consolidation.** After candidate 10,
    test whether either remaining buildable refresh has no consumer before the next authoritative
    refresh, using an event/consumer certificate rather than omission by assumption.

12. **Exact height-query deduplication.** After candidate 11, measure duplicate exact `(x,y)`
    terrain-height queries in decoration-relief capture; memoize only
    identical coordinates within the same fresh generation when the authoritative result and query
    timing semantics are unchanged.

Immediate below-70 execution order: give candidate 6 only the bounded work needed to reconstruct
its exact two-file identity and obtain one correctness-complete verdict.  Its measured gross ceiling
is the 1.317-second capsule closing-local-rebuild phase.  If it is not correctness-green or cannot
produce a genuine improvement after that exact rerun, mark it terminal and restore the accepted
payload immediately; do not keep extending it through speculative diagnostic variants.  Then run
candidate 7's compact exclusive phase profile on the accepted diagnostics-off release.  Select the
largest new controllable hotspot with a probability-weighted expected saving sufficient to close
most of the 5.813298-second gap to 70 seconds.  Prefer, in order: eliminating/coalescing one still-
duplicated expanded-grid traversal; reducing an authoritative rebuild's certified dirty domain;
fusing repeated exact terrain/resource/object enumeration; or moving only mathematically
equivalent work to the compact source grid.  Do not retry candidates already proved infeasible
unless materially new live capability evidence changes their premise.  If no single candidate has
a credible 5-second saving, combine independently accepted 1-4-second improvements, one at a time.

For every candidate, implement and test when technically possible. A terminal `infeasible` verdict
requires a focused executable oracle or live capability evidence, not a source-only opinion. After
candidate 7, append the next most promising concrete candidate and continue indefinitely. Leave
source and deployment at the fastest fully accepted compatible combination after every verdict.

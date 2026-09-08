# Ralph contract: remaining optimizations, START-to-T1 below 70 seconds

## Objective and user authority (2026-09-08 UTC)

Continue the `reoptimize` line's selective reimplementation of `61d4ad6..ee56197`.
Apply and verify remaining worthwhile optimizations independently, preserving every
standing rule and all previously accepted optimizations/terrain fixes. If those
ports leave START-to-T1 at or above 70 seconds, continue profiling and optimizing
until it is strictly below 70 seconds. The user explicitly requested this unattended
Ralph loop throughout the night, with no iteration/time cap and no routine chat
updates. Do NOT use Pursuing Goal, create_goal, or another goal mechanism.

Use Sol High normally. The runner escalates after two no-progress sessions to Sol
Extra High, after two more to Astra High, and audits a plateau before choosing a
materially new hypothesis. Verified progress resets to Sol High. Save tokens:
one focused evidence-producing step per session, terse durable memory, targeted
source reads, no repeated giant logs, no unbounded repeated identical experiment.

The user additionally requires BOTH:

1. Commit each successful optimization separately (no push or AI attribution).
2. ALWAYS update `_ralph/reoptimize-ranking.md` for each successful optimization,
   including its code/version/short hash, all before/after START-to-T1 samples,
   medians, absolute/percentage savings, rule/digest/visual results, evidence paths.
   A candidate is not "successful" merely because it was committed for testing.

## Project facts and protected state

- Project `D:\PROJS\SMR\super-big-map`, branch `reoptimize`.
- Starting checkpoint **v932 `fde100f`**, preceding optimization record `0ac3288`.
- Mod id `SuperBigMap`; authoritative external deployment:
  `C:\Users\fazevedo\AppData\Roaming\Surviving Mars Relaunched\Mods\super-big-map`.
- Only deploy with `python _ralph/tools/deploy.py sync`, then `audit` (37 payload
  files initially). Never use harness deploy/undeploy or copy whole project.
- Game `C:\Games\Surviving Mars Relaunched\MarsDebug.exe`; game tree read-only.
- CLI `python D:\PROJS\SMR\smr-harness\cli.py`. One game globally; fresh hidden
  daemon per cold run. Never reuse or terminate a user-owned/untracked session.
- Authorized edits: scoped mod production code, metadata/version, focused tests
  and probes, ranking log, this NEW Ralph run's memory and artifacts. Correct
  baseline defects needed for the gates before accepting performance changes.
- Preserve unrelated user changes. Initial `Code/sbm_deposits.lua` Git dirt is
  line-ending-only (text diff empty), not permission to discard it. Untracked
  `_ralph/tools/probes/vanilla_edge_snapshot_14N134W.lua` is user-owned.
- Do not modify `_ralph/optimizations-since-61d4ad6.md` or old `_ralph/runs/*`.
  This NEW `_ralph/runs/reoptimize-under-70s` is writable. Keep runner-owned
  RESUME.json, ITERATIONS.jsonl, LOOP.md and metadata out of agent edits.
- No game binary patches, other mods, saves, global graphics settings, global
  Codex settings, deleting caches to manufacture numbers, or persistent debug hacks.
- Keep the temporary elevator/debug UI buttons. They were explicitly requested.

## Initial issue: baseline is NOT yet all green

Read `_ralph/tmp/verification_v932_all_rules/STATUS.md` (latest dated update first)
and `artifacts/inherited-baseline.md` in this workspace. No new optimization has
been applied since `fde100f`. The first fresh pinned 14N134W run passed generation,
resource audits and first access: **204256 ms**, all 65 resources valid, 12 clusters
and 12 pads. A second identical cold run FAILED before T1:

`temporary vanilla source migration failed: native enrichment records did not survive source unload`

The later `pending_surface_buildable` nil access is a cascade, not the first cause.
The engine's `error()` may log and continue; do not assume it aborts a transaction.
Two instrumented retries completed with identical surface capture/verification
counts 354 and signature `5127262807174329434`, zero observed field changes.
That is NOT a diagnosis or an all-green verdict. Surface signature inputs are
only nil/string/number/bool (table-address serialization is NOT evidenced as the
surface failure cause). Both broad traces held extra strong map references;
the next minimal verifier-only observer avoids doing that before verification.
Find the actual cause, preserve the red evidence, fix it narrowly, and prove it
with cold tests. Do not bypass verification, hide failures, or call a lucky retry
a fix. The prepared ten-site sweep has not started.

Useful tools (inspect before use):

- `_ralph/tools/rules/run_rules.py` and `rules_probe.lua`: START-boundary stopwatch,
  all surface/UG censuses, actual player-route elevator placement/switch. Driver
  `status=complete` alone is NOT a rule verdict. `--setup-probe` runs diagnostics;
  diagnostic runs are not timing acceptance. New driver stops waiting on logged
  Lua/optimization errors, preserving failure status.
- `capture_rules_session.py --out DIR --pid EXACT_PID`: read-only full height and
  exposed native pass-grid hashes, final detailed terrain audit, sites/pads,
  optimization failures; closes the identified test game and copies its exact
  incident-matched engine log AFTER clean quit. `--failed` preserves failure logs
  without inventing T1; `--diagnostic-query MIGRATION_TRACE` captures observers.
- `judge_cold_matrix.py`: preliminary evidence judge, NOT complete sign-off.
  It leaves missing inputs, source-RNG review and provenance pending. Add tests
  and close its coverage gaps; never mistake a report-only helper for a gate.
- `run_cold_matrix.py`: sequential expanded A/B plus unexpanded controls from a
  manifest; refuses existing games and incomplete evidence dirs. It is new and
  requires review/testing. It has no live baseline judgment/fail-fast of its own
  beyond generation errors. Failed sessions need immediate scoped teardown.
- `_ralph/tmp/verification_v932_all_rules/migration_verify_trace.lua`: minimal
  next diagnostic, no extra map/record refs before the production verifier.
- `_ralph/tmp/apron_math_candidate_test.lua`: uncommitted candidate regression
  against production function from `fde100f`. Intentionally red for lookup-count
  reduction on v932; not an existing rule failure. Adopt with first math port.

## Standing rules (all ten gates, never weakened)

The current later owner rulings are in `_ralph/tasks/rules-parity-14n134w-v2.md`,
with accepted interpretations in `_ralph/runs/rules-parity-14n134w-v2/DONE.md`
and `_ralph/runs/rules-parity-15s67e/DONE.md`. Read the rules sections, not every
historic transcript. Old 6..10 cluster limits and old v924 terrain hashes are
superseded. The current corrected v932 output is the baseline for preserving ports.

1. **seed-parity**: no extra shared engine RNG draws. Private map-seeded streams
   for mod placement/decor. Vanilla-equivalent single UG seed reservation; pin
   that reserved seed in the repeat. Same inputs -> identical enrichments,
   decor, endpoints, cluster/pad/census outputs on BOTH maps. Audit source RNG
   calls, not only digests. Never skip random draws to win timing.
2. **entrances-glued**: authored UG markers stay at their stretched images.
   Surface takes twin image if valid; otherwise nearest fitting outward hex-ring
   walk, fresh original_z for EACH candidate. No random fallback/teleport.
3. **entrances-not-in-ring**: both endpoints of both pairs inside central 16x16
   of the 20x20 sectors (cols/rows 3..18).
4. **ring-content**: seeded 8..12 clusters, pads==clusters, valid buildable landing
   and extractor footprints, passable surface resources, all composition/quantity
   audits zero, enrichments in band, full map playable, mountain aprons retained.
5. **single-start-reveal**: exactly the start-anchor sector revealed before scans.
6. **badges-pre-reveal**: two entrance signs visible at overview scale550 even
   unexplored; no other deposit/badge visuals in unexplored sectors. A start-sector
   concrete deposit is valid by census; otherwise prove hidden->scanned->visible.
   UG imprint visibility/scale and reveal must match SAME-SITE EXPAND MAP-off control.
7. **decor-rules**: placed==target, seeded stable, only cosmetic allowed classes,
   zero mod-generated decor in ring on both maps. UG pass enabled. Zero authored
   UG marker sites/decoration passes can prove zero output; legacy nil counter
   fields are not alone proof. Distinguish vanilla prefab-baked ring cosmetics.
8. **no-errors**: zero Lua/assert/native/crash/optimization failure through clean
   teardown, every final cold run. Intermittent errors require root cause, not
   a lucky clean retry. Preserve diagnostics before stopping the exact test PID.
9. **process**: version bump per behavior change, factual local commit, authoritative
   deploy/audit before each launch, no unintended test hooks in shipped payload.
10. **underground-first-access**: actual ConstructionController Place Elevator then
    switch, linked expanded 820x946 UG, ONE SBM cover (`ug_cover_displays=1`, refs0),
    no failure. Additional vanilla profile-save windows do not fail the cover rule.

UG wonder `disconnected=1` alone is NOT a defect: vanilla collapsed tunnels divide
chambers. Current validity requires terrain, local distance and no overlap. Do not
move valid wonders merely to clear an entrance-connectivity diagnostic.

## Terrain/optimization invariants

- v929 terminal-wall correction is lower-only, narrow (last3 physical edge samples),
  generic across sectors/scenarios, not A0-hardcoded. No broad rim taper/slope.
  Recorded A0 fixture repairs exactly968 cells right:180-506, max drop847.
- v930/931 resource protection uses C2 smooth DEFORMATION blend outside preserved
  buildable cores; overlap cores share a plane. No hard second restoration stamp.
  No visible circular OR non-circular top-up rim/mark. Resources remain buildable.
- v932 bounded slope-limited crease joins cannot create new peaks/troughs/spikes.
  Do not reintroduce the old native extrapolation feather or unsigned-wrap bugs.
- Preserve v926 native resource raster and v928 numeric/cache-first top-up pair.
- Ring-resource feathers can extend INTO central sectors. Blind four-ring-only
  rebuild or central-rectangle restoration is NOT valid; derive actual dirty bounds.
- Every optimized failure must be loud, recorded in State.optimization_failures
  and surfaced to the player. No silent scalar/legacy retry or unverified partial
  terrain write. A/B is between commits, not a shipped fallback switch.

## Work sequence and history

Read `_ralph/reoptimize-ranking.md`. Resolve baseline failure/full rules first;
checkpoint separately. Then implement one unit at a time, measuring each. #1/#2
and #13 already landed. Suggested next #3 math bindings (`b617030`) adapts to the
CURRENT scalar apron, without copying the native raster. Then spacing-audit index,
dirty-bounds rebuild, rocket score/cache/planner work, crease read-side/native work,
native aprons and other remaining units as justified by measured profiles.

Reference `ee56197` itself weakened a certificate and was reverted by `736543c`.
Never merge/cherry-pick its entire architecture. In-place generation had intermittent
MaskBuildableGrid c0000409 crashes; lazy UG/capsule/passage-pad designs conflicted
with entrance rules. These require new proven designs, not blind import. Consider
every remaining ranked unit: implement a valid worthwhile form, or record concrete
evidence why rejected/superseded; never force an unsafe or slower unit merely to
claim all ports. Continue with new profiling-guided strategies until the time gate.

## Finite test matrix and timing definition

All tests: RoughTerrain, EXPAND MAP on except controls, fresh process, no user save.
T0 is immediately AFTER the START action begins, before its loading-screen work;
NOT DoneGame/NewGame/map-selection/bootstrap. T1 requires BOTH surface stretch done
and post-pipeline revalidation complete. Do not move required work after T1 just
to make the number smaller. First access must remain correct and its time reported.

Timing reference **14N134W** lat=-840 lon=-8040, Game.seed_text
`ralph_seed_parity_14n134w`, UG seed **5083534300309579687**. At least THREE clean
unmodified cold samples before and after EACH accepted optimization at this case;
record every sample (including failures/outliers with explanations), median/range,
savings. Reuse prior accepted baseline samples when inputs/payload/method match.
Never present diagnostic-hook times or New-Game timings as acceptance.

Each generation change also requires 15S67E regression; output-changing or grid/
placement-lifecycle changes require the full sweep before acceptance. Pure math/
read-only/cache changes may use exact offline equivalence plus pinned 14N/15S
pairs per step, then the entire final matrix. Do not relabel pending full sign-off.

Preselected sweep: Python Random(14134), two uniform draws rounded to whole degrees
per site, NOT randint. Manifest already at
`_ralph/tmp/verification_v932_all_rules/sweep_manifest.json`. Stable cases:

| id | site | lat minutes | lon minutes |
|---|---|---:|---:|
| S01 | 15S67E | 900 | 4020 |
| S02 | 24S74W | 1440 | -4440 |
| S03 | 45S120W | 2700 | -7200 |
| S04 | 61N136W | -3660 | -8160 |
| S05 | 17S11W | 1020 | -660 |
| S06 | 24S73E | 1440 | 4380 |
| S07 | 23S19W | 1380 | -1140 |
| S08 | 69N91W | -4140 | -5460 |
| S09 | 60S26W | 3600 | -1560 |
| S10 | 36S9W | 2160 | -540 |

For each site: expanded A fixed Game.seed_text, natural reserved UG seed; expanded
B identical game seed plus A's UG seed; same-site unexpanded control for UG reveal/
imprints. Fresh baseline needed if inputs change. Also three final double-pinned
14N runs and an extra third final15S sample. Every final expanded sample must be
**<70000 ms** and every rule must pass. Do not select only a fast site/run or average
a slow failing case away. Controls are correctness evidence, not performance targets.

## Offline and visual evidence

- `luac -p` all Code Lua + metadata/items; `git diff --check`.
- `lua _ralph/tools/parity/crease_join_test.lua` (8),
  `resource_protection_blend_test.lua` (9),
  `terminal_height_strip_test.lua _ralph/tmp/a0_wall_baseline.raw` (10).
- `python -m unittest discover -s _ralph/tools/parity -p '*_test.py'` (7 initially).
- Add focused regressions that exercise production functions and prove the red case.
- `outer_ring_policy_check.py` starts at98/101 static +28/28 dynamic/synthetic.
  Three old static checks inspect obsolete scalar strings or hardcode version887:
  resource_terrain_preserves_native_transition_detail,
  surface_resource_repairs_retain_a_safe_local_grade, version_is_887.
  Do not hide them. Replace stale mechanism tests only with reviewed production-
  behavior coverage proving the SAME policy, or explicitly leave suite not-all-green.
  Never relax a gameplay rule/test to get a pass. Do not blindly run historical
  one-off probes which mutate game/flags or deliberately test retired v821 policies.
- Preserving ports require identical full serialized terrain hashes, site/pad
  positions and rule digests against corrected baseline; pass grids compared by
  serialized native content, not HashPassability history. Explain any intended
  output change and re-prove seed parity/full terrain behavior instead.
- For terrain/placement changes, actual original-resolution screenshots at fixed
  edge/deposit cameras at 14N and15S, all affected resource pairs/cores and mapedges
  across the full sweep. `ui settle --json` must pass before capture. Inspect actual
  images, no imagegen or fabricated screenshots. No marks, spikes, broad tapers,
  false ridges, loss of terrain detail, unbuildable resources, displaced entrances.
- Hot reload does not reconstruct generation state; cold generation is authoritative
  for generation changes. Do not label a hot code reload a successful terrain retest.
- Representative new iteration frame for visual iterations; pure code/timing steps
  may record an honest absent-with-reason figure instead of reusing old images.

## Completion gate

Create DONE.md ONLY when all ranked units have an evidence-backed disposition,
all successful optimizations have separate commits and ranking-log entries, the
full final matrix and offline/visual rules are green, ALL final expanded timings
are below70s, deployment matches final commit, no source/test hook left accidental,
and no game remains running. Include per-optimization timing table and short hashes.
Being near70s, all ports attempted, end of night, or few tokens is NOT completion.

## Real blockers only

Do not stop merely for slowness, difficulty, a code bug, a plateau or a failed run.
Checkpoint each useful evidence step; change strategy/escalate per runner. Concrete
external blockers: user-owned game occupies the sole engine; missing credentials,
unsupported requested models or exhausted account quota after safe verification;
repeated infrastructure failure that cannot be repaired within scope; a needed
destructive action/other-system change not authorized here. Preserve evidence and
create BLOCKED.md only for a genuine external blocker. Never kill user sessions,
change accounts, install paid services or silently substitute another model.

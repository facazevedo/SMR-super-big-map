# Ralph task contract: outer-ring deposit scar visual elimination

## Objective

On a fresh expanded Super Big Map game at **14N134W**, reveal every surface sector and prove
visually that every resource/deposit cluster whose anchor lies in the two most external sector
bands blends into the surrounding terrain without an artificial round, elliptical, lobed, or
terraced scar. If any required frame fails or is uncertain, diagnose the height-field mechanism,
implement one evidence-driven terrain strategy, regenerate the same deterministic scenario, and
repeat. Stop only when the complete hot and cold visual matrices are explicitly clean and all
functional gates remain green.

The adaptive Codex ladder is part of this task: normal sessions use `gpt-5.6-terra` at `high`;
after the runner's plateau threshold they escalate to `gpt-5.6-sol` at `high`, then
`gpt-5.6-sol` at `xhigh` (extra high). Do not disable adaptive reasoning.

## Project facts

- Project: `D:\PROJS\SMR\super-big-map`
- Mod id: `SuperBigMap`
- Starting release: v885 (`32cbc68` plus the seamless-pad commit `493c450`).
- Expected deployment folder:
  `C:\Users\fazevedo\AppData\Roaming\Surviving Mars Relaunched\Mods\super-big-map`
- Required game executable: `C:\Games\Surviving Mars Relaunched\MarsDebug.exe`; never use
  retail `Mars.exe`.
- Bootstrap: a fresh new game, not a save, with EXPAND MAP enabled at 14N134W. In harness
  arc-minute coordinates this is `lat=-840`, `lon=-8040` (north/west are negative).
- Pin the underground/test seed to `6074387974731471656` wherever the bootstrap requires a twin
  seed. Surface generation is the deterministic 14N134W result.
- The expanded surface has a 20x20 sector grid. The physical two-sector perimeter ring contains
  exactly 144 sectors: sector x or y in `{0,1,18,19}`. Terrain preparation and this visual census
  use that same authoritative world-space band.
- The repository's authoritative deployment is `_ralph/tools/deploy.py sync` followed by
  `_ralph/tools/deploy.py audit`. The harness must not deploy or undeploy this externally owned
  target.
- Use only `smr.cmd`/the existing DAP parity machinery for live-game automation and image capture.
  Do not drive the game with guessed mouse coordinates. One tracked game/loop globally.

## Authorization and protected state

The agent may edit and commit `Code/**`, `metadata.lua`, `items.lua`, `.gitignore`, and
`_ralph/tools/**`; task-specific scenarios, manifests, screenshots, ledgers, and reports belong
only below this run workspace's `artifacts/` (temporary `.tmp-*` data belongs under
`_ralph/tmp`). Every gameplay behavior change bumps `metadata.lua`, uses a commit without AI
attribution, then runs deployment sync and audit before a game launch. Never push.

Do not modify the smr-harness repository, game binaries, ModTools sources, engine settings, other
mods, protected saves, or any predecessor `_ralph/runs/*` workspace. Do not weaken placement,
spacing, ring, passability, buildability, resource-count, cluster-count, or anomaly gates to obtain
a visual pass. The three-hex enrichment spacing policy and its sole neighboring-surface-deposit
exception remain unchanged. Terrain preparation around resources/deposits remains restricted to
the physical outer two-sector ring. Extractor footprints must remain actually usable.

Never kill an untracked `MarsDebug.exe`. A tracked process is stopped through `smr daemon stop` or
the parity runner's normal teardown. A Lua error, native assertion, crash, timeout, or startup error
fails the iteration and is diagnosed before relaunch.

## Reproduction contract

1. Confirm the worktree is clean, GitHub is current, no conflicting game/loop exists, the intended
   commit is deployed, and the authoritative deployment audit is green.
2. Start one fresh expanded 14N134W game. Do not reuse a prior generated map after a generation-path
   change.
3. Wait for final surface stretch, final passability/buildable rebuilds, deferred marker placement,
   and underground preparation to finish. Any fail-closed generation audit must pass.
4. Reveal/scan **all 400 surface sectors**, not only the outer ring. Resolve every resource,
   deposit, and anomaly marker to its final placed surface object before taking the census.
5. Census every final surface object in the physical outer two-sector band:
   `SurfaceDepositMarker`/placed surface pile, `SubsurfaceDepositMarker`, `TerrainDepositMarker`,
   extractor resource icons, and anomaly markers/placed anomalies. Preserve class/resource, final
   q/r and world x/y, sector, cluster-plan id when present, and placed-object identity.
6. Build a deterministic finite cluster list. Group explicit `SuperBigMapResourceClusterPlan`
   members by plan. Group remaining resource/deposit objects by connected axial distance no greater
   than the shipped cluster radius. Every ungrouped object becomes a singleton cluster. Sort by
   minimum q, then r, then class/resource and assign stable ids `cluster-001...`. Anomalies close
   enough to appear in the context are recorded, but never cause a resource/deposit to disappear
   from coverage.
7. Freeze `artifacts/cluster_census.json` and `artifacts/capture_manifest.json` for this deterministic
   scenario before judging the baseline. The manifest must prove that every census object appears
   in at least one cluster capture and that no object outside the outer two-sector band entered the
   gate. A later code strategy may move an object; remap it by stable generation/cluster provenance
   and record the coordinate delta without silently dropping or adding a case. If the authoritative
   resource plan legitimately changes after a behavior fix, create a versioned manifest and an
   explicit old-to-new coverage mapping; both complete matrices remain required.
8. Capture the current deployed version as the red baseline. Failure to reproduce is **not** a pass:
   expand the required camera framing/angles while preserving the finite census until every terrain
   transition is visible and a concrete verdict can be made.

## Test matrix

For every stable cluster id capture the following at original game-window resolution after the
scene is settled. The camera target is the bounding-box center of all resource/deposit members.
Zoom must include the entire prepared/altered terrain area plus at least 12 untouched hexes of
context on every side; calculate zoom from the cluster bounding radius rather than using one crop
that clips large clusters.

- `<cluster-id>-context-oblique`: normal resource/anomaly badges visible, fixed diagnostic oblique
  pitch and deterministic yaw, with every cluster member visibly identifiable.
- `<cluster-id>-terrain-oblique`: identical pose with only inspection-obscuring badges/selection UI
  temporarily hidden; do not hide physical deposits or change terrain/lighting.
- `<cluster-id>-terrain-nadir`: clean near-nadir terrain view at the same framing, used to detect
  circular/elliptical smoothing and texture rings that oblique light can conceal.

Use a fixed lightmodel/time-of-day across baseline, hot, and cold captures. If a transition remains
ambiguous because its relief is aligned with the light, add one deterministic opposite-yaw oblique
case for that cluster and retain it in every later phase. Immediately before **every** screenshot,
run `smr.cmd ui settle --json` and require exit 0, then `smr.cmd ui inspect --json`; preserve both
results with the capture. An unknown modal, non-quiet frame, clipped terrain transition, unreadable
capture, or uncertain verdict fails the case.

The visual manifest has `baseline`, `hot`, and `cold` phases for every frozen matrix id. Generate an
explicit verdict template with `smr.cmd visual template`; review each PNG at original resolution;
record `pass`, `fail`, or `uncertain`, confidence, and concrete observed features; then run
`smr.cmd visual check`. `uncertain` is failing. No contact sheet may replace individual full-
resolution review, though contact sheets may be supplemental navigation artifacts.

## Iteration review figure

Each iteration preserves exactly one new representative PNG at
`SMR_RALPH_FIGURE_PREFIX` plus a snake_case suffix. Prefer the clearest currently failing cluster,
or after repair the same stable case demonstrating the improvement. It must be a current iteration
capture, not a renamed older frame. If no valid new frame exists, record the reason and leave the
figure absent.

## Visual failure rubric

A case fails if any of these is visible around or between resource/deposit members:

- a closed or partial circular, elliptical, hexagonal, or lobed ridge/ditch;
- a bright or dark arc concentric with a deposit pad or cluster;
- a flat/smoothed plateau with a readable perimeter against native relief;
- a cut wall, fill berm, moat, ring shadow, or slope break caused by the preparation mask;
- a texture/detail-density boundary that traces the edited footprint;
- straight, scalloped, or repeated harmonic edges that reveal the algorithm;
- an isolated surface pile sitting on a visibly stamped patch; or
- clipping, floating, inaccessible, overlapping, or misplaced resources introduced by a repair.

The transition passes only when the usable inner terrain reads as part of the same continuous
landform from every required angle and no viewer can locate the edit boundary from geometry,
lighting, or detail density. A natural crater/ridge may pass only when evidence shows its contour
continues independently of the resource location and does not match an edit mask. If causality is
uncertain, the case is `uncertain` and fails.

Do not satisfy this rubric by hiding badges alone, reducing screenshot resolution, zooming out,
changing lighting to flatten shadows, clipping the transition outside the frame, or moving the
camera away from the resource. Do not substitute “mathematically C2” for an actual visual verdict.

## Strategy iteration contract

When any case fails:

1. Record the exact failing stable ids and preserve their images before editing.
2. Attribute the scar to a named stage (preliminary mountain apron, resource footprint core,
   overlapping-core harmonization, surface-pile passability repair, rocket-pad preparation, final
   rebuild, or another measured stage). Add temporary config-gated diagnostics only when needed.
3. Form one falsifiable strategy and predict which visible feature and runtime metric will change.
4. Prefer a materially different mechanism after a strategy plateaus: examples include native-flat
   relocation, live-footprint rather than radial distance, topology/contour-aware interpolation,
   bounded slope-energy relaxation, or eliminating unnecessary surface edits. Repeating radius or
   harmonic parameter tweaks without new evidence is not a new strategy.
5. Implement, parse, test, bump version, commit, deploy, audit, regenerate the fresh scenario, and
   recapture the full required matrix. A focused hot check may run first, but it never replaces the
   complete hot and cold gates.

A visually cleaner frame counts as progress only when preserved and explicitly reviewed. An
unverified code change, another launch, or a green nonvisual audit is not visual progress.

## Required runtime evidence

Each iteration stores under `artifacts/run_iterNNN_<strategy>/`:

- generation command/config, commit/version, surface and pinned seeds, and flushed relevant logs;
- `cluster_census.json`, marker-to-cluster coverage report, and ring-boundary audit;
- camera pose/framing metadata and `ui settle`/`ui inspect` JSON per capture;
- original-resolution PNGs and SHA-256 pins for every required case/phase;
- visual manifest, explicit per-image verdicts, and `smr visual check` result;
- outer-ring reveal summary: placed resources, anomalies, cluster counts/composition, spacing,
  terrain resource/rocket failures, outside-ring violations, and first failure details;
- changed-cell/patch telemetry including kind, core/transition dimensions, measured cut/fill delta,
  and whether preliminary apron/resource/surface/rocket stages touched each failing cluster; and
- Lua/native/assert/timeout diagnostics when present.

On CLI exit 3/4 or a native dialog, preserve `data.diagnostics` or run
`smr.cmd diagnostics capture --json` before stopping/restarting the tracked daemon. Read
`artifacts/LATEST_INCIDENT.json` first in the next session.

## Offline verification

After every code change and before launch:

- run `luac -p` on every changed Lua file;
- run `git diff --check`;
- run `_ralph/tools/parity/outer_ring_policy_check.py` and all focused checks named by the change;
- verify truthful metadata version/`last_changes` and a coherent local commit;
- run `_ralph/tools/deploy.py sync` and `_ralph/tools/deploy.py audit`, requiring zero missing,
  stale, or mismatched payload files; and
- confirm no unrelated worktree changes were overwritten.

The game's loaded-mod log must prove the deployed version before runtime evidence is accepted.

## Hot verification

After deploying a changed strategy, regenerate a fresh deterministic 14N134W game (hot reload alone
cannot validate generation-path terrain). First recapture the focused failing ids to reject a bad
strategy quickly. If they pass, capture and review the **entire** hot matrix and run the visual and
functional gates. No missing/uncertain case may advance to cold verification.

## Cold verification

Cleanly stop the tracked game and prove no `MarsDebug.exe` remains. Start a cold process, confirm
the intended mod version loaded, generate another fresh deterministic expanded 14N134W game,
reveal all 400 sectors, repeat the frozen census/coverage checks, and capture/review the complete
cold matrix. Flush logs and stop cleanly afterward. Cold evidence from a save or a map generated by
older code is invalid.

## Completion gate

Create `DONE.md` only when all of the following are true:

- a preserved current-code red baseline exists with at least one concrete artificial scar;
- every baseline failure id passes both hot and cold at required confidence;
- every resource/deposit object in all 144 outer-ring sectors is covered by the frozen cluster
  matrix; all context/terrain/angle captures exist and are individually reviewed;
- every hot and cold case is `pass`; there are zero `fail`, `uncertain`, missing, reused, clipped,
  or out-of-root images; `smr visual check` is green;
- a human-readable cluster table links each member coordinate/type to its capture ids and verdicts;
- the final outer-ring reveal gate has zero resource/rocket terrain failures, zero spacing/ring
  violations, valid 6-10 cluster count/composition, and every anomaly/resource placed;
- the three-hex spacing rule and sole surface-surface neighbor exception are unchanged;
- terrain/resource modifications remain limited to the two-sector perimeter policy;
- offline checks, version/commit, authoritative deployment sync/audit, loaded-version proof, cold
  restart, flushed logs, and clean teardown all pass;
- the project worktree is clean and HANDOFF/ATTEMPTS cite the exact final artifacts and commits; and
- no Lua error, assertion, crash, timeout, or teardown failure remains.

Do not create `DONE.md` because a numeric terrain audit is green, because one representative image
looks improved, or because no scar was noticed at a subset of clusters. The complete visual matrix
is the stopping condition.

## Blockers

A visible scar, uncertainty, slow generation, a failed strategy, or a plateau is never a blocker;
the adaptive ladder and strategy audit must continue. Failure to reproduce is `not reproduced`, not
success, and requires better deterministic evidence.

Human input is required only for a genuine scope decision or an external platform failure that
persists identically across three clean infrastructure restarts with diagnostics preserved and no
safe automated alternative. Usage/quota exhaustion pauses the runner and is not a blocker. Never
create `BLOCKED.md` merely because the task is difficult or time-consuming.

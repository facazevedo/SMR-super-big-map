# Ralph task contract — rules parity on the `reoptimize` line

## Objective

Make the deployed Super Big Map build on branch **`reoptimize`** (v887 + engine decor pass; `da7b1a4`, mod version 905 at task creation) follow every standing rule below **exactly**, with each rule proven by a stable-id gate in cold runs. The loop stops only when every gate is green (`DONE.md`).

**Explicitly out of scope for this task: performance.** T0→T1 under 70 s is a later step of the owner's step-by-step reimplementation; it is *measured and recorded* every run (probe below) but is **not** a gate here. Do not spend iterations on speed. Do not, however, let T0→T1 regress far beyond the current 293–382 s spread; a run over 450 s must be explained in `ATTEMPTS.md`.

The owner is rebuilding optimizations one at a time from v887, so **`main` is a reference, not a source to merge.** Port individual behaviours from the commits named below by hand, adapted to this line's architecture (eager underground, temporary-source generation). Never merge or cherry-pick `main` wholesale, and never port the lazy-underground architecture (`LazyUndergroundSourceGeneration`, capsule certificates, outer passage pads) — it is the subsystem this line deliberately does not have.

## The rules (each is a gate; ids are stable)

1. **`seed-parity`** — *"The seed system in the expanded map works exactly like vanilla. Top-ups and clusters may have their own seed, but every vanilla seed must behave the same."* Mod code makes **no engine-RNG draw** (`AsyncRand`, `Random`, generator `rand` helpers) during generation that vanilla would not make at that point; every mod-added placement (resource/anomaly/effect top-ups, outer-ring clusters, rocket pads, decor) draws from a **private stream derived from the map seed**. Evidence: two cold runs at the same site produce an identical enrichment marker set (digest over class + hex of every `DepositMarker`, `SubsurfaceAnomalyMarker`, `EffectDepositMarker`, top-up clones included), identical passage endpoints, and an identical decor-group set. At v887 `Engine.RandInt` prefers `AsyncRand` (`Code/sbm_engine.lua:184-191`), which is why identical seeds place markers differently every run; the reference fix is `main` commit `a2ba28b` ("Derive top-up placement randomness from the map seed"). Its commit body records the measured effect: run-to-run spread 31 s → 683 ms, marker digest `486921541` stable.

2. **`entrances-glued`** — *"The surface entrance stays glued to its underground twin unless the surface terrain there is uneven, unbuildable or blocked; then move to the nearest available tile around the original tile."* For each linked pair: the surface `UndergroundPassage` sits on the hex of the stretched image of its underground twin's position; if that hex cannot take the Elevator footprint at depth zero (whole shape on one buildable Z, no build obstructions, deposit/geyser clearance), the surface endpoint is the **nearest fitting hex found by an outward hex-ring walk**, and the record states the ring distance. **Never** vanilla's `FindPassageSpawnPos` fallback to `GetRandomPassableAroundOnMap` / `GetRandomPassable` (v887 still uses it: `Code/sbm_map_generation.lua:5914-5915`; measured in vanilla at 14N134W it put one surface entrance 170,000 wu from its twin). Do not use `FindBuildableAreaAround` for the search either: it creates `original_z` once for the whole search (`Lua/Pathfinding.lua:30`), so every later candidate must match the first probed hex's absolute height, and it returns nil on rough ground. Reference implementation of the ring walk with a fresh `original_z` per candidate: `main` commit `a0bf4ed`, `Code/sbm_map_generation.lua`, `nearest_fitting_hex`. Underground endpoints stay where vanilla puts them (on the authored `SurfacePassageMarker`, stretched). Report both endpoints' hexes, the validity verdict, and the ring distance per pair.

3. **`entrances-not-in-ring`** — *"Underground entrances are never in the outer ring."* Both entrances, on both maps, lie strictly inside the central 16×16 of the 20×20 sectors (outside the outer 10 % band on every axis). Facts: the entrance positions are **authored content** of the blank underground map, not generator output — every `BlankUnderground_0X` map ships exactly two `SurfacePassageMarker` objects, identical for every seed (BlankUnderground_04: (430500,243346)@14400 and (240000,348132)@3600 in 6144-space); vanilla picks the map with `table.rand({BlankUnderground_01..04}, surface_gen.Seed)`. They are always interior. If a pair is ever found in the ring, that is a placement defect, not a policy question. Reference: `main` `Code/sbm_underground_oracle.lua` (`04a103f`) reads them with a bare `ChangeMapInSlot` and no generation; on this line the underground is generated eagerly, so the markers are simply present.

4. **`ring-content`** — *"Rocket landing areas in the clusters in the outer ring, as well as resources, anomalies and deposits."* The outer two-sector band keeps its v887 behaviour: `PrepareOuterResourceTerrain` produces at least `OuterResourceClusterMinimumCount` (6) clusters and up to `OuterResourceRocketPadMaximumCount` (10) landing pads, deposits and anomalies may be placed there, the ring is playable (`SuperBigMapFullMapPlayable`), mountain-base aprons and pads are still flattened. Evidence: a census per run of clusters, pads, and enrichment markers in the band. This gate exists to prove the other rules did not break it.

5. **`single-start-reveal`** — *"Only one sector is revealed at the start — the anchor."* Immediately after generation, before any player scan, exactly **one** `MapSector` has a status other than unexplored, and it is the sector containing the start position. At v887 a second target (`winner2`) is revealed unconditionally (`Code/sbm_sector_exploration.lua:1844-1847`); reference fix: `main` commit `c32b08e`.

6. **`badges-pre-reveal`** — *"Elevator (entrance) badges appear even when their sectors are not revealed; they are the only badges that may appear in unrevealed sectors. Regolith/concrete deposits appear only after their sector is revealed."* Immediately after generation: a `SurfaceUndergroundTunnelSign` exists for each surface entrance, is visible, and carries the overview scale (`const.SignsOverviewCameraScaleUp`, 550) when the overview camera is active — including when its sector is unexplored. Every `TerrainDeposit` (concrete/regolith) in an unexplored sector is hidden; after that sector is scanned it becomes visible; no other badge or deposit visual is shown in an unexplored sector. Reference fixes on `main`: `6f9ee0a` (sign gating and concrete reveal gate), `efc3a26` (overview scale applied at sign creation — the badges existed but at scale 100). The visual-state probe used there is `main:Code/sbm_problem_dump.lua` (temporary module; use it as a reference for what to read, do not ship it).

7. **`decor-rules`** (regression gate; currently green) — the engine decor pass keeps: `placed == target`, `ring_objects == 0`, `dropped_non_cosmetic` reported, census limited to `Cliff*`, `Dec*`, `Rocks*`, `Stones*` plus the stamp's `PrefabMarker`, same seed → same decor set. Probe: `_ralph/tools/probes/decor_check.lua` (globals `DECOR`, `DECOR_STATS1..3`, `DECOR_CLASSES`). Reference: `da7b1a4`.

8. **`no-errors`** — no Lua error, assert, native error, or crash during generation, stretch, first-access preparation, or teardown, in every cold run of the final matrix.

9. **`process`** — every behaviour change bumps `metadata.lua` version, is committed with a factual message and **no AI attribution or co-author trailer**, is deployed with `python _ralph/tools/deploy.py sync` and proven by `audit` (`ok: true`, zero missing/stale/mismatch), and its short hash is recorded in `ATTEMPTS.md`. Commit and deploy **before** every game launch.

## Project facts

- Mod id `super-big-map`; project `D:\PROJS\SMR\super-big-map`; branch **`reoptimize`** (checked out; `main` is reference only). Mod version 905 at task creation; keep bumping from there.
- Deployment target is **external**: `C:\Users\fazevedo\AppData\Roaming\Surviving Mars Relaunched\Mods\super-big-map`. Only `_ralph/tools/deploy.py` (`sync` | `audit`; payload = `Code/**`, `Images/**`, `metadata.lua`, `items.lua`, stale files deleted) may deploy. Harness deploy/undeploy is forbidden.
- Game: `C:\Games\Surviving Mars Relaunched\MarsDebug.exe`, launched only through `python D:\PROJS\SMR\smr-harness\cli.py daemon start --hidden --timeout 300`; scripts via `cli.py run-file`, state via `cli.py eval`/`state`, logs via `cli.py logs`, always `cli.py quit` at the end. Never `Mars.exe`. Never kill an untracked game process; one game at a time.
- Site and bootstrap: **14N134W, RoughTerrain, EXPAND MAP**, on a real-time thread: `DoneGame(); NewGame(); InitNewGameMissionParams(); LoadLastNewGameSettings("regular", {RoughTerrain=true}); ChangeMap("PreGame"); params.map=""; GetOverlayValues(-14*60, -134*60); params.rocket_name, params.rocket_name_base = GenerateRocketName(true); params.SuperBigMapExpandMap = true;` then the START action body verbatim (`WaitWarnAboutSkippedMods; LoadingScreenOpen("idLoadingScreen","StartGame"); SaveNewGameSettings; TelemetryRestartSession; MarkNameAsUsed("Rocket", ...); WaitPlanetCamera("PlanetMars","close"); GenerateCurrentRandomMap(); LoadingScreenClose(...)`). Coordinates are arc-minutes with the internal sign convention: north and west negative. The second site for the final matrix is **30S146E** = `GetOverlayValues(1800, 8760)`.
- Map facts: 6144 → 8192 tiles (×4/3), 615×710 → 820×946 hexes, 20×20 sectors; outer band = outer 10 % per axis. Vanilla surface seed at 14N134W: `-8909488827485014858`, map `BlankBigTerraceCMix_02`, underground `BlankUnderground_04`.
- T1 = `SuperBigMapSurfaceStretchDone` **and** `SuperBigMapSurfacePostPipelineRevalidationComplete` both true on any loaded map slot; they are set from real-time threads, but the post-generation pipeline runs as one non-yielding Lua block for ~190–220 s, so a poller only observes them when it yields — allow a 900 s window. Probe: `_ralph/tools/probes/t0t1_stopwatch.lua` (global `T0T1`), cold-sample driver `_ralph/tools/probes/t0t1_samples.sh N`. v887 baseline at the Start boundary: 315.7 s median (292.6–321.0, n=4); v905 with decor: 305–382 s.
- Mod globals are **not** in `_G` from a `run-file` chunk: reach them through `ModsLoaded[i].env.SuperBigMap`. `Global(...)`/`GetMapSectorXY` are not reachable from harness chunks; use the mod's own `SuperBigMap.SectorGrid.ForEachSector` for sector state. This engine's Lua divides two integers as an integer: promote with `+ 0.0`.
- Underground marker read without generation (if ever needed): `_ralph/tools/probes/ug_blank_markers.lua`.

## Authorization and protected state

The agent may edit and commit `Code/**`, `metadata.lua`, `items.lua`, `Images/**`, `.gitignore`, `_ralph/tools/**`, and create evidence only under `_ralph/runs/rules-parity` and temporary data only under `_ralph/tmp`. Never modify this task file, `_ralph/optimizations-since-61d4ad6.md` (read-only record on disk), the smr-harness repo, game binaries, ModTools sources, other mods, or any save not prefixed `ralph_sbm_rules_`. Never push. Never switch branches away from `reoptimize`; never merge `main`. Config keys that encode the rules above (`StretchDecorEnginePass*`, `PrepareOuterResourceTerrain`, `SuperBigMapFullMapPlayable`, `OuterResource*`) may not be turned off to make a gate pass.

## Reproduction contract

1. Confirm no `MarsDebug.exe` is running and no harness daemon record is live (`cli.py quit` is harmless when nothing runs). Commit + deploy (verified audit) every intentional source change BEFORE any launch.
2. Cold run: fresh process, hidden daemon, the bootstrap above, wait for T1 (900 s window), then read every gate's evidence in the same session **before** any player action, then the reveal/badge follow-ups (scan one sector containing a concrete deposit; re-read), then `cli.py quit`.
3. Any Lua error, assertion, or native error fails the iteration immediately: capture `cli.py diagnostics` evidence, quit the tracked game, diagnose, fix before relaunch. Never leave a hung game running.
4. One focused rule per iteration; regenerate after every generation-path change; add config-gated `[SuperBigMap]` debug output as needed (errors are never gated); remove temporary instrumentation before `DONE.md`.

## Test matrix

Every case runs at 14N134W unless stated; ids are stable and every verdict is recorded in the iteration's artifacts.

- `seed-parity`: two consecutive cold runs, same site — enrichment digest equal, passage endpoints equal, decor set equal; plus a code audit listing every engine-RNG call site reachable from mod placement code with its justification (vanilla-mirroring reservations only).
- `entrances-glued`: per pair — underground hex, stretched-image hex, surface hex, validity verdict at the stretched hex, ring distance (0 when glued), search method (must be the ring walk).
- `entrances-not-in-ring`: per endpoint — sector column/row; all strictly inside 3..18 of 20.
- `ring-content`: clusters ≥ 6, pads ≤ 10 and ≥ 1, enrichment markers in band counted, `SuperBigMapFullMapPlayable` true, aprons produced (report `MountainBaseApron*` census as in v887).
- `single-start-reveal`: sectors with status ≠ unexplored == 1, id reported, equals the start sector.
- `badges-pre-reveal`: signs == number of surface entrances; each visible; overview scale == `SignsOverviewCameraScaleUp` with overview active; each sign's sector status reported (unexplored expected); `TerrainDeposit` visibility per sector status: hidden in unexplored, visible after scan — proven by scanning one sector programmatically and re-reading.
- `decor-rules`: probe stats as listed under rule 7.
- `no-errors`: log scan for `LUA ERROR`, asserts, native errors; clean teardown.
- `t0-to-t1` (informational, not a gate): Start-boundary value recorded per run.
- Final matrix: three consecutive clean cold runs at 14N134W, all gates green each time, plus one cold run at 30S146E with every gate except `seed-parity` green (seed-parity is proven by the 14N134W pair).

## Iteration review figure

Headless generation work: a figure is optional. If one is captured (after `cli.py ui settle --json` exits 0), it goes under `SMR_RALPH_FIGURE_DIR` with the `SMR_RALPH_FIGURE_PREFIX` and a snake_case suffix naming the rule worked on. Absent-with-reason is acceptable; never reuse an older frame.

## Visual failure rubric

Fail if a surface entrance is visibly away from its underground twin without a recorded validity reason, if any badge other than the two entrance signs is visible in an unexplored sector, if a concrete/regolith patch is visible in an unexplored sector, if more than one sector is revealed at start, or if any decor object sits in the outer band. `uncertain` fails.

## Required runtime evidence

Per iteration under `_ralph/runs/rules-parity/artifacts/<iterNNN_topic>/`: the gate table with verdicts, the raw probe outputs, the enrichment digest(s), the entrance records, the sector census, the sign/deposit visibility census, the decor stats, the T0→T1 value, and `[SuperBigMap]`/`LUA ERROR` log excerpts. Keep `ATTEMPTS.md` entries terse with paths; keep `HANDOFF.md` a rolling summary near 120 lines. Keep `_ralph` under 2 GB.

## Offline verification

`luac -p` on every changed Lua file; `git diff --check`; clean worktree after each iteration's final commit; truthful `metadata.lua` version; `python _ralph/tools/deploy.py audit` → `ok: true` with identical file counts and zero mismatches.

## Hot and cold verification

Hot reload is not trusted for generation behaviour (mid-game redeploy fakes defects). Every verdict comes from a cold run: fresh process, deploy audited before launch. A gate is green only when it passed in the final matrix on the final committed code.

## Completion gate

Create `DONE.md` only when: gates 1–9 are green in three consecutive clean cold runs at 14N134W on the final committed and deployed code; the 30S146E run passes every gate except `seed-parity`; temporary instrumentation is removed and the payload contains only intended modules; the worktree is clean, the deployment audit is green, and the final short hash, mod version, gate table, entrance table, sector/sign/deposit census, decor stats and T0→T1 values are restated in `DONE.md`. **T0→T1 < 70 s is not required.**

## Blockers

Human input is required only for a scope change to the rules above, a game/engine limitation proven to make a rule unsatisfiable (with the exact evidence), or a persistent external platform failure reproduced identically across three iterations after one clean infrastructure restart with preserved diagnostics. Quota exhaustion is an infrastructure pause, not a blocker. Failure to reproduce a defect is `not reproduced`, not success.

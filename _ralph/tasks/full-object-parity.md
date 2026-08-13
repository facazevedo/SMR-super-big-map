# Ralph task contract

## Objective

Make Super Big Map produce freshly generated expanded games in which the expanded surface is a 100% one-to-one object match of its vanilla-twin surface and the expanded underground is a 100% one-to-one object match of its vanilla-twin underground. Every eligible vanilla object must have exactly one expanded counterpart at the equivalent position under the mod's XY stretch transform (full/source, currently 8192/6144 = 4/3), with class-appropriate Z, scale, and angle, and the expanded map must contain zero mod-created extras. The surface twins must share the same generator seed and hash; the underground twins must share the same generator seed and hash.

Phase 1: prove all gates at 30S146E. Phase 2 (only after phase 1 is green): remove legacy and unused code, keeping the matrix green. Phase 3 (only after phase 2 is green): prove the bijection gates on 50 additional randomly chosen coordinates.

## Project facts

- Mod id: `SuperBigMap`
- Project: `D:\PROJS\SMR\super-big-map`
- Expected deployment folder: `C:\Users\fazevedo\AppData\Roaming\Surviving Mars Relaunched\Mods\SuperBigMap` (external deployment: copy payload manually, never harness deploy/undeploy)
- Required game executable: `C:\Games\Surviving Mars Relaunched\MarsDebug.exe` (never Mars.exe), always headless: `-nointro -no_interactive_asserts -stdout -hidden`
- Harness: `D:\PROJS\SMR\smr-harness`; all live-game operations go through `python D:\PROJS\SMR\smr-harness\cli.py ...` (`smr.cmd`) or the DAP client (`dap.py`/`cli.py` as libraries).
- Authoritative twin tooling (tracked in this repo, maintained by this task): `_ralph/tools/parity/run_parity.py` (spawns one fresh hidden game process per twin, generates, dumps every map object to CSV game-side), `compare.py` (census, provenance bijection, stretch proportionality, stamp-independent geometric match). Extend these rather than replacing them; commit tool changes.
- 30S146E bootstrap (already encoded in `gen_template.lua`): `GetOverlayValues(1800, 8760, ...)` — in this game POSITIVE latitude is SOUTH and POSITIVE longitude is EAST (`PlanetUI.lua` `PlanetFormatCoordsToPrompt`). The overlay call derives `g_CurrentMapParams.Seed = xxhash(lat, long)`, so the surface seed needs no injection: identical coordinates give identical surface seeds on both twins.
- 30S146E surface constants (verified 2026-08-13 on a33f5d0): seed `-8259618194048590238`, generation hash `-4285936173006453476`, map preset `BlankBigTerraceCMix_19`, vanilla 6144 tiles, expanded 8192 tiles.
- The vanilla UNDERGROUND seed is drawn from `AsyncRand()` and is NOT reproducible across runs (three identical vanilla runs produced three different underground seeds). Twin comparison therefore always pairs one vanilla run with one expanded run: capture the vanilla twin's underground holder seed, then inject it into the expanded twin with `SuperBigMap.MapGeneration.SetTwinUndergroundSeedForTest(seed, tag)` before `GenerateCurrentRandomMap()`. `run_parity.py` already does this. The underground gate compares expanded holder seed/hash against the paired vanilla twin's values, never against a fixed constant.
- Vanilla surface generation is deterministic: three independent vanilla runs at 30S146E produced byte-identical surface object sets (21894 objects, 100% identical class+x+y). A vanilla twin is therefore a trustworthy control.
- Starting commit: `a33f5d0` (v770). Baseline red state measured there (artifacts preserved in the previous session): surface 21675/21894 vanilla objects matched (99.00%, 219 unmatched); underground 5980/6504 matched (91.94%, 524 unmatched), expanded underground carried 6963 objects vs vanilla 6504 (extras/unstamped to classify or eliminate). 98.5% of stamped objects sit within 1 wu of `source * 4/3`; deposit-marker classes sit ~334-578 wu off due to the documented hex snap.
- Known-poison commit: `c65292f` (reverted; preserved on branch `backup/pre-a33f5d0-revert`). It stamped `SuperBigMapSourceWidthTiles`/`GeneratorWidthTiles`/`DesiredWidthTiles` onto the temporary vanilla backing; `HasExpandedSectorSource` (`sbm_sector_grid.lua`) reads exactly those fields, so `IsModMap(temporary_source)` became true, per-map mod behavior (PassBorder = 0) switched on mid-generation, and the generator's play zone diverged the RNG stream (surface parity fell to 0.01%). Any reuse of that commit's underground work must keep the temporary backing reporting as a pure vanilla map for the whole native generation transaction.
- A suggested (non-binding) architecture if in-place repair keeps failing: let vanilla generate every object on the native backing, capture the complete population as records, delete the objects, stretch the terrain, then re-place every record at `source * (full/source)` with class-appropriate Z/scale/angle. Partial forms of this (capture/recreate for enrichments) already exist in `sbm_deposits.lua`.

## Authorization and protected state

The agent may edit and commit this repository's `Code/**`, `metadata.lua`, `items.lua`, `Images/**`, `.gitignore`, and `_ralph/tools/**`. It may create Ralph artifacts only under `D:\PROJS\SMR\super-big-map\_ralph`. After each committed source change it must copy the payload (`Code/**`, `Images/**`, `metadata.lua`, `items.lua`) to the deployment folder and verify identical relative paths, sizes, and SHA-256 with zero stale files. Bump `metadata.lua` version on every behavior change. Commit messages must contain no AI/assistant attribution lines.

Do not modify game binaries, ModTools sources, engine/account settings, other mods, or any save not owned by the prefix `ralph_sbm_parity_`. Never overwrite, rename, delete, or resave `not_expanded_30S146E.savegame.sav`, `expanded_30S146E.savegame.sav`, or `expanded_fix_30S146E.savegame.sav` under `C:\Users\fazevedo\Saved Games\Surviving Mars Relaunched\76561197960271872\`. Do not push Git commits. Do not modify the smr-harness repository. Never kill an untracked game process; run only one game/loop globally (`smr.cmd daemon status` first; a stray tracked MarsDebug must be stopped through the harness, never taskkill on unknown PIDs).

## Reproduction contract

1. Confirm no game-process conflict through the harness, and commit + deploy (verified audit) every intentional source change BEFORE any game launch — a game booted over uncommitted or undeployed source proves nothing.
2. Run the twin pair headlessly: `python _ralph/tools/parity/run_parity.py` (full vanilla+expanded pair at 30S146E) or `... run_parity.py twin <tag> <0|1> [seed|-] [serial] [lat=N] [lon=N]` for a single side. A fresh process per twin is mandatory: the vanilla control must never run in a process that has already executed expanded generation.
3. Wait for real completion: the tool polls `g_ParityStatus` through surface stretch and underground first-access preparation; a merely allocated/deferred underground is not complete. Zero tolerance for `[SuperBigMap]` session errors in the daemon log (`grep` for `SESSION_END ... ok=false`, `could not be prepared`, `materialization failed`, Lua errors, asserts).
4. Game hygiene is mandatory: any Lua error, assertion, or native error during game startup, map generation, or map switch fails the iteration on the spot — capture the log/diagnostics, terminate the loop-owned game process immediately, diagnose, and fix before any relaunch. Never wait on a hung or error-state game beyond the tool's bounded polls, never leave MarsDebug running between iterations, and never park a broken game while working on something else: kill it, then solve the problem.
5. Compare with `python _ralph/tools/parity/compare.py <out_dir>` and read `parity_report.txt` / `parity_summary.json`.
6. Diagnose the first stable mismatch class; work one focused hypothesis per iteration; regenerate after every generation-path change. New config-gated `[SuperBigMap]` debug channels may be added per iteration to localize divergence (`sbm_diagnostics.lua` pattern); errors are never gated. Comparing paired savegames (save both twins under the owned prefix, diff the serialized object sets) is an allowed investigation technique.

## Test matrix

Phase 1 (30S146E), stable ids:

- `surface-seed-hash`: expanded surface holder seed and generation hash equal the vanilla twin's.
- `underground-seed-hash`: expanded underground holder seed and generation hash equal the paired vanilla twin's captured values.
- `surface-bijection-100`: every eligible vanilla surface object maps to exactly one expanded surface object and vice versa; zero unmatched, zero duplicates.
- `underground-bijection-100`: same for the underground pair.
- `surface-transform-exact`: every matched pair's expanded XY equals the mod's documented per-class transform of the immutable source coordinate (exact affine `round(src * full/source)` by default; hex-snapped affine only for classes whose placement rule is hex snap; exact world affine for buried wonders). Scale follows the class rule (cosmetic decor scales by the ratio; functional markers keep vanilla scale); angle is equal; Z follows class-appropriate terrain-relative semantics.
- `underground-transform-exact`: same for the underground pair.
- `no-mod-extras`: zero top-up/density/clone additions on both maps (all `SuperBigMap*TopUp`/`EnrichmentClone` flags absent) and zero unexplained unstamped objects.
- `sector-integrity`: exactly 400 live unique MapSector objects per expanded map referenced by the 20x20 grid, zero orphans; vanilla twins keep exactly 100.
- `infrastructure-enumerated`: every class exempted from the bijection (engine/mod infrastructure such as MapSector, SectorUnexplored decals, RandomMapGeneratorHolder, CameraObj) is enumerated with its expected cardinality and the reason it is infrastructure, not content. Nothing else may be exempted; PrefabMarker and every decoration class are content.
- `save-roundtrip`: after saving the expanded 30S146E twin under the owned prefix, a clean stop, cold restart, and direct load, the bijection and transform gates recount green on both maps.

Phase 2: `legacy-code-cleanup` — modules never loaded (`sbm_elevator_debug.lua` is absent from `metadata.lua`'s code list), call sites referencing absent modules, retired config slots, and branches unreachable under the shipped configuration are removed in separate commits; `luac -p` stays green on every file; the full phase-1 matrix is re-proven after the final cleanup commit.

Phase 3: `sweep-01` .. `sweep-50` — 50 coordinates drawn once by a seeded generator (master seed `30146`, lat uniform in [-4200, 4200], lon uniform in [-10800, 10800] arc-minutes, rounded to whole degrees like `GenerateRandomLandingLocation`), recorded in `artifacts/sweep_manifest.json` before the first sweep run. Each case runs one twin pair headlessly at those coordinates and must pass seed/hash equality, bijection-100, transform-exact, and no-mod-extras on both maps. A sweep failure returns the task to phase-1-style diagnosis on that coordinate; the sweep restarts only the failed cases after the fix, but the final DONE state requires all 50 green on the final committed code.

## Iteration review figure

For every iteration, preserve exactly one new PNG at `SMR_RALPH_FIGURE_PREFIX` plus a snake_case suffix naming the focused objective. Prefer a capture of the currently-diagnosed divergence region (surface or underground). Run `smr.cmd ui settle --json` (exit 0) before any evidence capture. If the game cannot reach a valid frame (headless generation-only iteration), record why and leave the figure absent rather than reusing older evidence.

## Visual failure rubric

Fail if a vanilla object (decoration, marker, feature product, wonder, passage/access object) is missing, duplicated, or visibly misplaced relative to the stretched terrain; if a mod-created extra exists; if terrain regions visibly lack or duplicate decoration density relative to the vanilla twin. `uncertain` is a failing verdict.

## Required runtime evidence

Preserve per iteration under `artifacts/`: the twin CSV dumps and `parity_report.txt`/`parity_summary.json`, both holder seeds/hashes, map sizes, unmatched/extra/duplicate record files with counts, the exact `[SuperBigMap]` log excerpts for any session error, and (phase 3) the sweep manifest with per-case verdicts. On any CLI exit 3/4 or native dialog, capture structured diagnostics before teardown and read `artifacts/LATEST_INCIDENT.json` next iteration. A timeout is not a pass.

Hygiene: workspace memory follows the session contract's summarization rules — terse ATTEMPTS entries pointing at artifact paths (never pasted logs or object listings), HANDOFF.md rewritten as a rolling summary of roughly 120 lines, and archive consolidation once ATTEMPTS.md passes ~1000 lines/100 KB. Bulk artifacts rotate: keep the newest five twin outputs plus any run still referenced by ATTEMPTS/HANDOFF or a phase verdict, delete older CSV dumps and multi-MB game logs, and keep `_ralph` under ~2 GB total.

## Offline verification

- `luac -p` every changed Lua file (ModTools ships luac; any Lua 5.3+ luac works).
- `git diff --check`; clean `git status` after the final commit of each iteration (untracked `_ralph/runs`/`_ralph/tmp` are ignored by .gitignore and do not count).
- Metadata version and `last_changes` truthfully describe behavior after every bump.
- Deployment audit after every deploy: identical relative-path sets, sizes, SHA-256, zero stale payload files.

## Hot verification

After each committed and deployed change, rerun the focused failing matrix case plus `no-mod-extras` on a fresh twin pair. A pre-change map proves nothing.

## Cold verification

Phase 1 completion requires the `save-roundtrip` case: stop the tracked daemon cleanly, confirm no process remains, restart, cold-load the owned expanded save, recount both maps, flush logs, stop cleanly.

## Completion gate

Create `DONE.md` only when: all phase-1 cases pass with machine-readable evidence (zero missing, extra, or duplicate eligible objects on both maps; both seed/hash pairs equal; transforms exact; infrastructure exemptions enumerated with proven cardinality); phase-2 cleanup commits are landed with the matrix re-proven; all 50 sweep cases pass on the final code; every intentional change is committed and deployed with a green audit; no new Lua error, assert, native crash, timeout, or teardown failure remains in the final runs' logs; the worktree is clean. `DONE.md` states the final commit hash, mod version, per-map record totals and zero-diff results for 30S146E, the sweep manifest digest and per-case results, and the deployment audit result.

Class-count equality alone never satisfies a bijection gate; matching must be record-level with duplicate-provenance rejection.

Ratchet: maintain `artifacts/best.json` with the best-yet score per gate (matched/unmatched counts per map, seed/hash equality, extras). Every twin run compares against it; a result worse than best on ANY gate is a regression — the iteration records `Progress: no`, and the regressing change is fixed or reverted before new work. Improvements update the file in the same checkpoint. Measurement-tool changes never relax a gate: widening tolerances, adding class exemptions, or skipping records requires the infrastructure-enumeration justification in DONE.md, and silently weakening `compare.py` or the dump to make a gate pass is a contract violation.

## Blockers

Human input is required only for scope changes, corrupt/inaccessible protected reference data that a freshly generated deterministic control cannot replace, or a persistent external platform failure reproduced identically across three iterations after one clean infrastructure restart with preserved diagnostics. Slow generation, a hard mismatch, or the need for new diagnostics is never a blocker.

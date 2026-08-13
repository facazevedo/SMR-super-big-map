# Ralph task contract

## Objective

Deliver entrance co-location on expanded maps, then complete the phased objective.

**Entrance co-location (deliberately better than vanilla).** On an expanded map, a linked Surface/Underground passage pair must occupy the **exact same hex** on both maps. Vanilla only *aspires* to this and drifts: `SpawnUndergroundPassage` (`ModTools/Src/Lua/Buildings/SurfacePassage.lua:126`) snaps the surface position to hex, then `FindPassageSpawnPos` runs `FindBuildableAreaAround`, may reject a candidate on `min_dist`, and after 12 attempts falls back to `GetRandomPassableAroundOnMap` / `GetRandomPassable` — a random position anywhere on the map. We deliberately do better: the pair is co-located by construction. When the natural (stretched) hex is not valid for both endpoints, search outward for the nearest hex valid on BOTH maps and move BOTH endpoints there together, preferring to relocate the SURFACE endpoint to the closest valid terrain. Co-location takes precedence over exact-affine placement for these classes; the relocation must be the minimum distance that satisfies validity, must be reported, and must never sculpt terrain to force a fit.

Then complete: the remaining per-class transform gates, `sector-integrity`, `save-roundtrip`, phase 2 legacy-code cleanup, and the phase 3 50-coordinate sweep.

**SETTLED BY EXPLICIT DECISION — do not "fix" and do not spend an iteration on it.** Uniform scaling of the stretched classes is ACCEPTED as correct behavior. `PrefabFeatureMarker` (geysers and every other prefab feature), `CaveInRubble`, `TunnelBlockerRubble`, `BottomlessPit`, and `JumboCave` scale 100 -> 133 with the stretch, and that is intended: the expansion is a similarity transform, so a feature that grew with the terrain it sits on is consistent. The predecessor's "functional-class scale-133" open question (`run_iter009_hexgrid/`) is hereby CLOSED as accepted, including its consequence that the gridded footprints and the derived `GridObjectList` bucket count scale with it. Deposit markers keep their vanilla scale (110/128/64) because they already do; do not change them either. Report scales in the per-class census for information, but no scale gate exists in this task.

## Inherited state (authoritative, read before acting)

The predecessor run is at `D:\PROJS\SMR\super-big-map\_ralph\runs\full-object-parity` and is READ-ONLY history. Session 1 must read, in this order:

- `HANDOFF.md` — the rolling summary: proven facts, dead ends/cautions, artifact map. Every "Dead ends / cautions" entry still applies.
- `artifacts/attempts_archive_1.md` (iterations 001-032) and the tail of `ATTEMPTS.md` (033-039).
- `artifacts/best.json` — the ratchet. **Copy it into this workspace's `artifacts/best.json` unchanged as the starting baseline** before the first scored run, then continue ratcheting here. Its gate semantics (content_* / infrastructure_* / unexplained_* / neg_partition_anomalies, plus the informational family and its justification) carry over verbatim and may not be relaxed.

Already GREEN at v782 and must never regress (this is the ratchet's floor):

- `surface-seed-hash`, `underground-seed-hash` — equal seed AND generation hash on both maps.
- **Full object bijection on BOTH maps**: surface 21693/21693, underground 5867/5867, with zero unmatched, zero unstamped, zero unclaimed, zero object-count delta, zero classes differing, infrastructure proven (ok on every class), zero partition anomalies.

Do not re-derive these; protect them. Any change that moves a green gate off zero is a regression to fix or revert in the same session.

## Project facts

- Mod id `SuperBigMap`; project `D:\PROJS\SMR\super-big-map`; mod version 782 at task creation.
- Deployment target is **external**: `C:\Users\fazevedo\AppData\Roaming\Surviving Mars Relaunched\Mods\SuperBigMap`. Harness deploy/undeploy is forbidden. The authoritative procedure is `_ralph/tools/deploy.py` (`audit` | `sync`) over `Code/**`, `Images/**`, `metadata.lua`, `items.lua` with stale-file detection.
- Game: `C:\Games\Surviving Mars Relaunched\MarsDebug.exe`, always headless (`-nointro -no_interactive_asserts -stdout -hidden`). Never `Mars.exe`.
- Twin tooling: `_ralph/tools/parity/run_parity.py` (pair, or `twin <tag> <0|1> [seed|-] [probe|cameraprobe|hexgrid|entranceaudit]`), `compare.py`, `ratchet.py <parity_summary.json> <best.json> [--update]` (POSITIONAL args). Pair + compare runs under 4 minutes. Vanilla control pinned to `REFERENCE_UNDERGROUND_SEED = 6074387974731471656`; both twins reproduce byte-for-byte.
- 30S146E = `GetOverlayValues(1800, 8760, ...)`; positive latitude is SOUTH, positive longitude is EAST. Surface seed derives from the coordinate; the underground seed is `AsyncRand` and must be injected via `SetTwinUndergroundSeedForTest`.

## Authorization and protected state

Same as the predecessor task. The agent may edit and commit `Code/**`, `metadata.lua`, `items.lua`, `Images/**`, `.gitignore`, `_ralph/tools/**`, and create artifacts only under `_ralph`. Bump `metadata.lua` version on every behavior change; commit messages carry no AI attribution; never push. Never modify the smr-harness repo, game binaries, ModTools sources, other mods, or protected saves (`not_expanded_30S146E`, `expanded_30S146E`, `expanded_fix_30S146E`); loop-owned saves use the prefix `ralph_sbm_parity_`. Never kill an untracked game process; one game/loop globally. **The predecessor workspace `_ralph/runs/full-object-parity` is read-only evidence: never edit or delete it.**

## Reproduction contract

1. Confirm no game-process conflict, and commit + deploy (verified audit) every intentional source change BEFORE any game launch.
2. Run the twin pair headlessly with `run_parity.py`; wait for genuine completion of surface stretch and underground first-access preparation.
3. Any Lua error, assertion, or native error during startup, generation, or map switch fails the iteration immediately: capture diagnostics, terminate the loop-owned game at once, diagnose, fix before relaunch. Never leave a hung or error-state game running.
4. Compare with `compare.py`, score with `ratchet.py`, and preserve the artifacts.
5. One focused hypothesis per iteration; regenerate after every generation-path change; add config-gated `[SuperBigMap]` debug channels as needed (errors are never gated).

## Test matrix

Carried over and still required: `surface-seed-hash`, `underground-seed-hash`, `surface-bijection-100`, `underground-bijection-100`, `no-mod-extras`, `infrastructure-enumerated`, `sector-integrity`, `save-roundtrip`.

New and changed:

- `entrance-colocation`: every linked passage pair on the expanded map occupies the identical hex on surface and underground — proven by comparing the two endpoints' hex coordinates directly, for every pair, not by sampling. Zero pairs may differ.
- `entrance-validity`: each co-located hex is valid for both endpoints (buildable/flat per the engine's own `IsTerrainFlatForPlacement` over the `Elevator` extended spawn shape on the surface, and the underground equivalent), with no terrain sculpted to force validity. Where the natural stretched hex was rejected, the record states the rejection reason, the search radius used, and proves the chosen hex is the NEAREST valid one — an unnecessarily distant relocation fails the gate.
- `entrance-minimal-drift`: report per pair the distance from the exact stretched image of the vanilla surface coordinate to the final co-located hex. Zero where the natural hex is valid. This is a measured, reported quantity, not a pass/fail threshold — but a pair whose drift grows without a stated validity reason fails.
- `transform-exact-per-class`: the remaining per-class XY/Z/scale/angle verdict tables in `compare.py`, with entrances judged by `entrance-colocation` rather than exact affine.
- `wonder-coverage`: there are FOUR underground wonder classes — `AncientArtifact`, `CaveOfWonders`, `BottomlessPit`, `JumboCave` — and all four must be stretched with the terrain (scale ratio applied, position on the stretched image, footprint scaled through the shape patch). 30S146E spawns only `BottomlessPit` and `JumboCave`, both measured correct at 100 -> 133, so the other two are handled by the same code path but UNPROVEN by any twin so far. The phase-3 sweep must record, per case, which wonder classes appeared on each map and assert that across the 50 coordinates every one of the four has been exercised at least once and passed its transform verdict. If the 50 drawn coordinates do not cover all four, draw additional coordinates from the same seeded generator until they do, and record the extension in the sweep manifest. A wonder class that never appears is not evidence of correctness.

Phase 2 `legacy-code-cleanup` and phase 3 `sweep-01..50` (seeded manifest, master seed `30146`) are unchanged from the predecessor contract and run only after phase 1 is green.

## Iteration review figure

One new PNG per iteration at `SMR_RALPH_FIGURE_PREFIX` + snake_case suffix, captured this iteration after `smr.cmd ui settle --json` exits 0. Prefer a rendered comparison of a co-located entrance pair (the surface endpoint and, via the underground recipe in the predecessor's `run_iter037_markgridscale/figure_site.lua`, its underground twin at the same hex). Absent-with-reason is permitted for a headless generation-only iteration; never reuse older evidence.

## Visual failure rubric

Fail if a passage pair is visibly offset between maps, if an entrance sits on a slope or carved pad, if terrain was sculpted to seat an entrance, or if any previously green bijection object is missing, duplicated, or misplaced. `uncertain` fails.

## Required runtime evidence

Per iteration under `artifacts/`: twin dumps, `parity_report.txt`/`parity_summary.json`, the ratchet result, per-pair entrance records (both endpoint hexes, validity verdict, rejection reason, search radius, drift), the per-class scale census (informational), `[SuperBigMap]` log excerpts for any error, and the phase-3 sweep manifest when it runs. Memory hygiene per session contract: terse ATTEMPTS entries referencing paths, HANDOFF a rewritten rolling summary near 120 lines, archive consolidation past ~1000 lines/100 KB. Rotate bulk artifacts; keep `_ralph` under ~2 GB (the predecessor workspace's 171 MB counts and must be preserved).

## Offline verification

`luac -p` every changed Lua file; `git diff --check`; clean worktree after each iteration's final commit; truthful metadata version and `last_changes`; deployment audit with identical relative paths, sizes, SHA-256 and zero stale files.

## Hot / cold verification

After each committed and deployed change, rerun the focused failing case plus both bijection gates on a fresh pair. Phase 1 completion additionally requires `save-roundtrip`: clean daemon stop, restart, cold load of the loop-owned save, recount both maps green.

## Completion gate

Create `DONE.md` only when: every carried-over gate is still green; `entrance-colocation` is exact for every pair with `entrance-validity` proven and drift reported; the per-class transform tables pass; `sector-integrity` and `save-roundtrip` pass; phase 2 cleanup is landed with the matrix re-proven; all 50 sweep cases pass on the final code with `wonder-coverage` proving all four underground wonder classes exercised and correct; everything is committed and deployed with a green audit; and no Lua error, assert, crash, timeout, or teardown failure remains. `DONE.md` restates the anti-relaxation proofs inherited from the predecessor (iter 008's four checks and iter 010's five) plus any added here, and states the final commit, version, per-map totals, entrance table, scale census, sweep digest, and audit result.

Ratchet rules are inherited verbatim: `artifacts/best.json` decides regression; never hand-edit it; never add a class to `compare.py`'s INFRASTRUCTURE registry or widen a tolerance to move a number. A class must earn its exemption per run.

## Blockers

Human input is required only for a scope change, corrupt/inaccessible protected reference data a fresh deterministic control cannot replace, or a persistent external platform failure reproduced identically across three iterations after one clean infrastructure restart with preserved diagnostics. A usage/quota exhaustion is an infrastructure pause, not a blocker: record it and let the runner's progress budget stop the loop.

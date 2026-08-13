# Ralph task contract

## Objective

Deliver a PERFECT surface 1:1: for 30S146E and every coordinate in the pinned ten-map sweep manifest, the expanded surface content population equals the vanilla control's surface content population with ZERO unmatched, ZERO unstamped, ZERO unconsumed rows and ZERO class differences (the only permitted note is the intentional `TerrainDepositConcrete` imprint relocation, which must be explicitly tagged, not silently excluded) — **reproducibly, on every run**.

The obstacle is measured and specific: stock vanilla generation is BISTABLE on maps with contested prefab sites. At 45S82E (lat=2700 lon=4920), two identical vanilla runs differ by 34 rows — one slate-stone cluster at source ~(211056,169078) plus its downstream cascade (ParSystem carriers, SurfaceDepositMetals, SafariSight, even the passage pair move, because the contested stones change later obstruction queries). `const.PrefabRasterParallelDiv = 1` does NOT pin it: serial vanilla runs flip between the same two variants (runs d7v3=variant A, d7v4=variant B). The mod's temporary-backing source generation IS deterministic — expanded twins sw07e and d7e2 are byte-identical — and always draws variant B. So something the temporary-backing transaction does removes a scheduling race that in-place vanilla retains even when rasterization is serialized. FIND IT, then PIN IT in the vanilla control harness (and/or align both sides), so control and expanded deterministically produce the same draw and the diff is exactly zero.

## What is already proven (do not re-derive)

- Evidence dumps in `_ralph/tools/parity/out/`: `objects-sw07v.csv` (parallel run 1, variant A), `objects-d7v2.csv` (parallel run 2, variant B), `objects-d7v3.csv` (serial, variant A), `objects-d7v4.csv` (serial, variant B), `objects-sw07e.csv` + `objects-d7e2.csv` (expanded, byte-identical, variant B). Clean-map control: `objects-sw03v.csv` == `objects-d3v2.csv` (33S163E, zero wobble).
- Variant B minus variant A (content): StonesSlateSmall_01 x5, StonesSlate_02 x3, StonesSlateSmall_05 x3, StonesSlateSmall_03 x3, StonesSlateSmall_02 x3, StonesSlateSmall_04 x2, RocksSlate_04 x1 (+1 StonesSlateSmall_01 A-only), clustered at source ~(211056,169078); cascade differences in ParSystem/SurfaceDepositMetals/SafariSight/passage-pair placement follow from it.
- Full verdict and methodology: `_ralph/tools/parity/sweep/DRIFT_VERDICT.md` (commit d6a5201), sweep results in `_ralph/tools/parity/sweep/`.
- The ten-map sweep, corrected scale rule, and all inherited 30S146E gates: see `_ralph/tasks/parity-sweep-first.md` and the three predecessor workspaces (`full-object-parity`, `entrance-colocation-and-scale`, `entrance-colocation-v2` — all READ-ONLY). The current ratchet is `_ralph/runs/entrance-colocation-and-scale/artifacts/best.json`; every floor in it still binds. Mod v783+, HEAD at or after d6a5201.

## Investigation leads (ordered)

1. **Trace the divergence to a procedure.** The mod ships a generator-procedure trace (`TraceUndergroundRockParity` / `CallDoGenerateWithRockParityTrace`, `sbm_map_generation.lua` ~L923-1976): it brackets every `RandomMapGenerator` procedure by ordinal, captures sorted object manifests, and can proxy the `Proc_RemoveOverlappedObjects` callback and its `GridGetMark`/`GetCollectionIndex` predicates. It was built for the underground twin war; verify it arms on a plain vanilla surface run (the generator class is the same), enable it via the config constant in two back-to-back vanilla runs at 45S82E, and diff the per-ordinal manifests to find the FIRST procedure whose output differs between variant A and variant B runs.
2. **Find what the temporary backing pins.** The mod's source capture runs the same DoGenerate on a temporary native-sized map and is deterministic. Candidate determinizers to test one at a time in the in-place control: the clutter-capture wrapper (`CallWithClutterCapture` serializes SetClutterGrid), suspended pass edits during generation, `PrefabRasterParallelDiv=1` PLUS single real-time-thread scheduling (the backing generation runs inside one real-time thread transaction), MainMap/slot arrangement. Each candidate is testable by adding the equivalent pin to the control gen script (`_ralph/tools/parity/gen_template.lua` via `__EXTRA_SETUP__`, like SERIAL_RASTER_BLOCK) and running duplicate controls until one pin makes ten consecutive control runs byte-identical at 45S82E.
3. **Align the draw.** Once the control is deterministic, it may still draw the OTHER variant than the mod (A vs B). Preferred resolution: pin the control harder until it matches the mod's draw (the mod's draw is a proven-valid vanilla outcome, byte-stable, and already green on every other gate). Changing the mod's draw instead is allowed only if it keeps every inherited gate green on 30S146E AND the full sweep.
4. Suspected mechanism if leads stall: iteration order of a hash/handle-keyed container in `Proc_RemoveOverlappedObjects` or prefab raster task list — object handle allocation order can depend on async load timing. A probe that logs the callback's visit order at the contested site across two runs will confirm or kill this in one iteration.

## Non-negotiables

- The measurement tools never relax: zero means zero. No new exemptions, no tolerance windows, no class exclusions. The `TerrainDepositConcrete` relocation is tagged by provenance (the mod's own imprint-move records), not by class name.
- Control-side pins live in the test harness gen scripts only. Mod-side changes must keep every inherited ratchet floor green (30S146E bijection 21693/5867 all-zero residue, entrance co-location, seeds/hashes) and be committed+deployed (verified audit) before any measuring run.
- Game hygiene: any startup error/assert kills the game immediately, diagnose before relaunch; never leave a game running between iterations; one game globally; headless always.
- Terse ATTEMPTS entries with artifact paths; HANDOFF rewritten each session near 120 lines; consolidate past ~1000 lines/100 KB.

## Test matrix

- `control-deterministic`: ten consecutive vanilla control runs at 45S82E byte-identical on the surface (the pin proven), and duplicate controls at every sweep coordinate identical too.
- `surface-exact-30s146e`: expanded vs pinned control at 30S146E — zero everything.
- `surface-exact-sweep-01..10`: expanded vs pinned control at each manifest coordinate (`_ralph/tools/parity/sweep/sweep_manifest.json`, unchanged) — zero everything, with the concrete-imprint tag the only annotation.
- `underground-still-green`: the underground bijection stays exact on all cases (it already is; protect it).
- `inherited-floors`: the full ratchet from `entrance-colocation-and-scale/artifacts/best.json` stays green on 30S146E.

## Iteration figure, evidence, verification

Per predecessor contracts: one new PNG per iteration (or absent-with-reason for headless generation iterations), per-iteration artifacts under this workspace, `luac -p`, clean worktree after each iteration's final commit, deployment audit green after every mod change, cold-verification unchanged. Roughly 2.5 minutes per twin run; duplicate-control experiments are cheap — prefer measuring over theorizing.

## Completion gate

`DONE.md` only when every matrix case above is green with machine-readable evidence, the pin mechanism is documented (what the race was, what pins it, why the pin is a valid vanilla configuration), all commits are landed and deployed with green audits, and no error/assert/timeout remains in the final runs. State the final commit, mod version, the pin, and the per-case zero-diff tables.

## Blockers

If the race source is genuinely unpinnable from Lua (native thread scheduling with no exposed knob), prove it: the trace identifying the exact native procedure, at least three distinct pin attempts with evidence, and a written statement of what native change would be required. That is a BLOCKED.md with a human decision attached, not a relaxed gate.

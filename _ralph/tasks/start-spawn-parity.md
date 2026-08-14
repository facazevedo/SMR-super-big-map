# Ralph task contract

## Objective

Make the expanded map's start-reveal spawn set EQUAL vanilla's, by staging and replaying the native source's own spawn decisions — then prove zero content residue (both maps, excluding only the entrance/passage family, which is exempt by explicit user decision because expanded co-locates pairs deliberately better than vanilla) on: 30S146E (P1), 45S82E, b2-04 (4S107E, lat=240 lon=6420, ug seed 8736761973933965003), b2-07 (55S164E, lat=3300 lon=9840, ug seed 3500499737872786970), b2-10 (51S110W, lat=3060 lon=-6600, ug seed 8384283635741179153).

## The architectural statement (follow it, do not re-derive)

Generation runs on the temporary native backing, but City initialization — the initial reveal and every spawn it makes — runs on the expanded destination. Replaying it there re-derives vanilla's decisions through stretched geometry, and v796/v797 measured exactly how that fails:

- vanilla gates surface spawns with `CanPlaceDeposit` evaluated on NATIVE terrain: at b2-04, four metals markers fail natively but succeed at stretched positions (+4 SurfaceDepositMetals, +1 SubsurfaceDepositMetals, +1 ParSystem after the auxiliary sector scan landed);
- `TerrainDepositConcrete` requires its terrain imprint: the mod relocates the imprint (`MoveConcreteImprints`, paint-at-scan idiom) and the deposit spawn at the stretched position finds no paint, so it silently fails (b2-04, still 1->0);
- something places a deposit AFTER the reveal despawn sweep (b2-10: SubsurfaceDepositWater, marker source (272000,476300) just outside the winner corner, native-stamped, is_placed=1; vanilla=0). The placer is unidentified — the placeprobe exists in `run_parity.py` (`placeprobe`) but its per-call `debug.traceback` CRASHES the game mid-generation; lighten it (no traceback: record SetLoadingPhase-style phase, CurrentMap, call ordinal) before using;
- the rare anomaly's "Revealed" ParSystem FX does not materialize for footprint-remainder spawns even when deferred with DelayedCall (b2-07, 5->4).

THE FIX DIRECTION: `VanillaStartPick` (sbm_sector_exploration.lua) already re-runs vanilla's `InitialReveal` on the native source and receives vanilla's exact `spawn_positions` (native `CanPlaceDeposit` results) and the revealed sector set. Stage, per revealed sector and per depth list (block/surface/subsurface, exactly `MapSector:Scan`'s unexplored branch), the SOURCE-coordinate identity of every marker vanilla would spawn, with its native spawn position. On the destination: spawn EXACTLY the staged set (marker resolved by source stamp, spawn position = stretch of the native spawn position, imprint painted first where the deposit needs terrain paint), and suppress or despawn-to-staged-set everything the destination-side sector scans spawn beyond it. The staged set is the single source of truth; membership rects, CanPlaceDeposit re-evaluation, and destination bookkeeping are not.

## Inherited state (READ-ONLY; do not re-derive)

- Fixed and holding: subsurface anomaly spawns (v794), the auxiliary winner capture (v797 staging works; its SCAN overshoots — that scan approach is superseded by the staged-set replay above). P1 (30S146E) and 45S82E are CONTENT-EXACT on both maps at v797; every inherited ratchet floor is green. Underground content is exact on every measured map.
- Vanilla controls for the five coordinates exist as dumps: `_ralph/tools/parity/out/objects-{p1a,d04a,d07a,d10a}.csv` (+ k-series at 45S82E), all proven deterministic with duplicate runs.
- Workspaces `full-object-parity`, `entrance-colocation-and-scale`, `entrance-colocation-v2`, `surface-exact-parity`, `exact-parity-both-maps` are read-only history. The ratchet is `entrance-colocation-and-scale/artifacts/best.json` semantics with the `entrance` family; carry it forward.
- Tools: `run_parity.py twin <tag> <0|1> <seed|-> lat=N lon=N [serial|passagepin|placeprobe|...]` (~3 min/twin), `compare.py`, `deploy.py audit|sync`. The commander-bonus tail places profile-gated deposits legitimately (hydroengineer/astrogeologist); tag such placements exempt rather than despawning them.

## Non-negotiables

Zero content residue means zero: no tolerances, no new exemptions beyond the entrance family and tagged commander-bonus placements. Every mod change: `luac -p`, version bump, commit, deploy + audit green BEFORE measuring; re-measure P1 and 45S82E floors after every mod change (regression = fix or revert in-session). Game hygiene and memory hygiene per session contract v7. One focused hypothesis per iteration; measure over theorize.

## Test matrix

- `start-spawn-staged`: the staged native spawn set exists per revealed sector/depth with source identities and native positions (dump-visible).
- `spawn-exact-<case>`: for each of the five coordinates, content class counts AND positions equal the deterministic vanilla control on both maps (entrance family exempt; bonus-tagged exempt). This includes b2-04's concrete (imprint painted before spawn), b2-10's water (placer found with the lightened probe, then eliminated or source-staged), b2-07's ParSystem (FX carrier present — find where vanilla's carrier really comes from with a probe on ParSystem creation rather than assuming PlayFX timing).
- `floors`: P1 + 45S82E exact and full ratchet green after every change.
- `save-roundtrip`: after the five cases are green — save the expanded P1 game under prefix `ralph_sbm_parity_`, clean stop, cold restart, load, recount both maps green. (Still never tested; part of this task's completion.)

## Completion gate

`DONE.md` only with: all five `spawn-exact` cases green with per-case tables, floors green, save-roundtrip green, every change committed+deployed with audit green, no error/assert/crash/timeout in the final runs, and the staged-spawn design documented in HANDOFF (what is staged, where, and why destination re-derivation is forbidden).

## Blockers

Per predecessor contracts. A quota pause is not a blocker; launch failures do not consume budget (runner handles this).

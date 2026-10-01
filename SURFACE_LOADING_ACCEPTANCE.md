# Surface START-to-T1 — runtime acceptance and local checkpoint

## Metadata 1168: seat unrooted pairs of leaning stones

Sweep case 59N61W (`71wdbFzlVZuJ`, RoughTerrain): two decor top-up stones (StonesSlate_02 and
StonesSlateSmall_01 near (328247,478802)) leaned only on each other, floating 42-70 units above
terrain. Contact with an unrooted piece blocked the negative proof, and each stone's edge to the
other vetoed moving it alone. A post-propagation pass now measures any unsupported piece whose
contacts are all unrooted and proposes a rollback-guarded seating attempt; a mutually proposed
unrooted pair (neither a vanilla float) no longer vetoes itself. 59N61W: complete, 19 corrected /
0 rejected, 61.9 s; 67N138E and 38S111W unchanged.

## Metadata 1167: restore vanilla terrain contact lost in the stretch

Sweep case 67N138E (`UigYAOgrDE7J`, RoughTerrain): vanilla RocksLightSmall_06 at (256031,214031).
Its LOD1 piece 2 rested on vanilla terrain (native clearance -0.79) but floats 10-25 units after
the stretch, touching only LOD1 piece 5, an accepted vanilla float (183.6 native, allowed 248).
Touching an unrooted fragment blocked the negative proof, so the piece stayed inconclusive.
MarkNativeAuthored already offered a rollback-guarded seating move to native floats lifted beyond
their allowance; it now does the same for the mirror case, a piece that touched vanilla terrain
but floats now. 67N138E: complete, 1 corrected / 0 rejected, 59.8 s; 38S111W still complete (89 s).

## Metadata 1166: rollback-guarded seating for a measured gap on steep slopes

Sweep case 38S111W (`64Yw9AQ35FI2`, RoughTerrain) failed "1 surface rocks have unresolved support";
the published 1158 build fails identically. Vanilla StonesDarkGroup_02 at (340451,423107): piece 2
(20 vertices) floats 4.95 units above the interpolated terrain (vanilla native ground 0.15). Its
proof margins (coarse 3, precise 1) are multiplied by 1+|gx|+|gy| with gradient sum 5, so the gap
could not be proved, the piece stayed inconclusive and no seating was proposed. Owner ruling
2026-10-01 (after vanilla/expanded photos, `_ralph/runs/photo-38S111W-rock-20261001`): a measured
positive gap (every triangle above the interpolated terrain at zero margin) authorizes a seating
attempt only; the correction service still verifies independently and rolls back unless the
piece is positively rooted. 38S111W: complete, 32 corrected / 0 rejected; the rock moved 12 units
straight down, XY, angle and axis unchanged. START-to-T1 88.7 s in that diagnostic run.

## Metadata 1165: oasis fills respect cluster ownership

Sweep case 23S112W (`8ZVp2hNCzjNI`, RoughTerrain, MetatronMystery) failed the outer resource
top-up census with `anomaly_cluster_overflow=1 cluster_total_overflow=1`; 1163 fails identically,
so it predates 1164. Clusters 1 and 6 are 15 hexes apart, so their 12-hex areas overlap.
FillOasisClusterAnomalies placed cluster 1's anomaly at (278,908): 12 hexes from cluster 1 and 6
from cluster 6, which has no anomaly slot; the census assigns each anomaly to its nearest cluster
(lowest index on a tie). The anomaly fill and the oasis dome bonus now accept only spots their own
cluster owns under that rule (`DepositRules.NearestClusterPadIndex`). 23S112W: complete in 66.3 s;
24S74W clusters identical. Unlike 1161-1164, this can move a fill on a map that passed before
(a spot nearer a neighbour with a free slot), so carried sweep results are not bit-identical.

## Metadata 1164: on-demand anomaly sampling on crowded surfaces

Sweep case 55S11E (`UTzZpVL2RBMB`, RoughTerrain, MetatronMystery) failed "surface top-up spacing
audit failed: density_failures=1": the anomaly top-up placed 21 of 26 (unlock 32/36, sequence
11/12). The map holds 348 metals after top-up and 220 of 400 sectors are unbuildable, and the
planned 8-samples-per-sector pool (3192 samples, 424 valid) ran out. The surface now samples
further whole-map spots on demand, within one more planned round, only after every existing
selector is exhausted (the underground path already did this). 55S11E: complete in 69.2 s with
`surface_on_demand_added=5`, shortfall 0. 24S74W: `surface_on_demand_added=0`, clusters identical.

## Metadata 1163: More Deposits compatibility, landing pads beside steep slopes

Owner report 2026-10-01: "кластери=2 / екстрактори=1/2" appears whenever Super Big Map and More
Deposits (Neoness, Steam 3604709443, mod id `uxduyx7`) are both enabled. That mod rewrites the live
`ResourcePresets` on every ChangeMap; its default "grade fix" sets Concrete (TerrWeightGrade) and
Metals, PreciousMetals and Water (Subs1/Subs2 weights) to 100% Very High, and doubles their counts.
Every extractor template was then premium, so strong clusters had no non-premium second extractor.
`DepositRules.SingleGradeResources` reads the Mars surface presets (`<resource>_VeryLow..VeryHigh`;
asteroid and Below & Beyond `_Underground` presets excluded) and treats a resource whose presets
allow one grade as non-premium. No vanilla Mars preset is single-grade, so vanilla maps are
unchanged. With More Deposits loaded (`compat-G-moredeposits-1163-20261001`), 24S74W and 61N136W
(no game rules) completed with every cluster at its planned composition, `settled=0`, premium 0;
24S74W without it is identical to 1160. Test runs reach the debug game through a temporary local
copy of the mod (the debug build does not scan Steam workshop folders) and the runner's new
`--extra-mod` option.

Sweep case 5N92W (`5kauyCa7cHva`, RoughTerrain, MetatronMystery) failed `rocket_failures=1` at
pad 539:48 beside a 25-57 m rise: the level core reaches the centres of the first ring outside the
pad shape but not their outer halves, that ring stayed steep, and the engine eroded the two shape
edge hexes with two unbuildable neighbours (`g_NCF_MinUnbuildableNeighbours`); both repairs re-made
the same patch. A pad that failed the previous audit now levels one more hex per repair (capped at
the required core). 5N92W then passed on the first repair (71.0 s); pads that pass the first audit
are untouched.

## Metadata 1161: outer resource clusters settle instead of failing

Player report 2026-10-01: new maps failed almost everywhere with "weighted composition failed:
cluster=2 ... extractors=1/2"; only 1N166E worked. Not reproduced with SBM alone: six sites
without any game rule (standard `MAIN` preset; every earlier acceptance run used RoughTerrain)
were clean (`_ralph/runs/feedback-rules-off-1160-20261001`). Each cluster plans exactly `target`
candidates, and every extractor after the anchor must be non-premium, so anything that raises
deposit grades or narrows the deposit kinds (most likely another mod) leaves no recovery.

Owner ruling 2026-10-01: the oasis rule stays the default; only a cluster that cannot meet it
takes extractors of any grade, then keeps what it placed (at least one extractor and the resource
minimum). Settled markers carry the settled targets and premium allowance
(`SuperBigMapResourceClusterPremiumLimit`), which the final terrain audit honours. A cluster that
met the rule never reaches the fallback, so its placement and RNG draws are unchanged.

24S74W (`v932_sweep_14134_24s74w`), no game rules, `_ralph/runs/feedback-settle-*-20261001`:

| Run | Code | Stress | Result |
|---|---|---|---|
| A plain | 1160 | none | clean, 11 clusters |
| A stress | 1160 | all 68 vanilla extractor templates "High" | fails: cluster 1 extractors 1/2 |
| C plain | 1161 | none | clean, cluster results identical to A plain |
| C stress | 1161 | grades | clean; 6 clusters took premium extractors at full targets |
| C kinds | 1161 | grades + every subsurface kind turned into Metals | clean; cluster 3 extractors 2/3, cluster 10 resources 4/5 |

All 100 compatibility fixtures pass. Not timed for acceptance and not checked with save/reload.

Metadata 1162 consistency pass: a settled cluster also gives up the reward budget of the resources
it could not place (otherwise the anomaly/dome-effect passes read the gap as a free cluster slot),
and planned candidates a cluster did not use lose their cluster stamps before the ordinary top-up
passes can reuse them (a stamped leftover reused that way always failed the audit, so passing
clusters are unaffected). Top-up errors are caught by `SafeCall` and only surface at the final
audit, which is how this morning's sweep failure at 51S17W (`sdVUfShepin6`, RoughTerrain, "plan=8
members=4 target=5") presented: the same shortfall. Results (`feedback-settle-D-*-1162-20261001`):
51S17W RoughTerrain clean with cluster 8 settled at resources 4/5; 24S74W plain identical to 1160;
24S74W kinds clean with the same six settled clusters as 1161 (cluster 10 reward budget 5 to 4).
The one remaining composition failure is a cluster that cannot place even one extractor of any
grade; it cannot form a rocket pad, so it still stops generation.

## Metadata 1137 / build 474 (`c430156`): complete underground darkness on expanded maps

Owner report 2026-09-26: on the expanded underground the unexplored cave passages were faintly
readable through the darkness. Vanilla behaves the same (measured: unexplored floor ~3/255,
solid rock 0/255, in both a vanilla and an expanded 49N28E game), because vanilla paints its
darkness at strength 90 (`hr.EnableDarknessReveal`), letting 10% of the lit cave through. Owner
ruling 2026-09-27: on expanded maps every unexplored pixel must be 100% black and explored pixels
must stay exactly as they are, reflections included; "darkness 100 only" was rejected because at
strength 100 the screen-space reflection composite, which runs after the darkness pass, still adds
the environment glint of the cave walls (brightest 8/255 on ~7% of the dark area).

The composite cannot tell covered pixels apart (the reveal spheres are bound to the darkness pass
alone; depth/stencil cannot be written by that pass, which reads the depth buffer as a texture;
the composite's own blend is plain additive into an unsigned target). The one per-pixel channel
written after the darkness pass is the reflection map, and rough surfaces sample its top mip (the
screen average), so any change to the dark pixels' entries changes explored pixels (measured
-2.4/255 uniform dimming with zeroed entries). The shipped solution (Shaders/, mounted over the
game's shader path by `Code/sbm_underground_darkness.lua`):
- `Reflections.fx` stores a fully covered pixel's vanilla reflection scaled by 2^14 when its scene
  color is exactly black; the scale is exact in r11g11b10 for values in [2^-8, 3.9];
- `ReflectionDenoising.fx` and `ReflectionConvolution.fx` undo the scale before blending, so
  every mip an explored pixel samples is the vanilla value bit for bit, and re-encode a marked
  pixel's own entry (the convolution replaces its corner-centred linear samples by a decoded 2x2
  average);
- `ApplyReflections.fx` discards a pixel whose own unblurred entry is marked and decodes the four
  texels of any sampling that touches level 0.
The compiled-shader cache is keyed by shader name and defines, never by source, so
`ShaderCache/` ships zero-byte files under the 47 cache entries those 81 variants resolve to;
mounted seethrough over the pack they make exactly those entries fail to load and the engine
compiles the mounted sources (`hr.EnableShaderCompilation = 1` in the shipped config;
`dxcompiler.dll` ships with the game). All other shaders stay cached; nothing in the game install
is modified. The mod sandbox blacklists `MountFolder`; the owner ruled the mod may reach it through
the engine's exposed `FuncResolver(name)` helper (module header documents this).

Measured through the deployed mod at 49N28E (`_ralph/runs/ug_darkness/mod1137`): unexplored
0/255 in every channel at both zoom levels; explored pixels differ from the same run forced to
strength 90 by 0.055-0.059/255 on average (the unmodified game's own 90->100 difference is 0.04);
exactly the 81 reflection-chain variants compiled, 1.56 s real in parallel on first use, no other
compiles, no errors. A vanilla-mode control (`vanilla1137`) keeps strength 90 and the vanilla look.
Dead ends kept as evidence: `override_zero2` (zeroed entries: dark exact, explored -2.4/255),
`depthmark`/`depthmark2` (depth marking: no effect), `variants`/`ssr`/`levels` (render settings).

Defects found on the way: `hr.ForceShaderCacheReload` with the whole cache hidden recompiles all
3,446 cached shaders and hits a fatal assert on a `D3DCopyDSV` variant that already fails to load
from the cache on this GPU (targeted bypass avoids it); build 1136 could not mount inside the
sandbox and fell back to vanilla strength (1137 fixes it).

Tests: `underground_darkness_test.lua` (23 checks, stub engine: mounts, fallbacks, resolver),
`underground_darkness_payload_test.lua` (35 checks: shipped sources carry every stage, LF endings,
all trace stores marked, 47 zero-byte entries, darkness shader entry untouched). 92 compatibility
tests pass.

Distribution (2026-09-27): the mod manager delivers a packed archive, so the payload was packed
with the game's own packer (`AsyncPack`, 101 entries; `Shaders/`, `ShaderCache/` and all 47
zero-byte bypass entries survive) and installed as a packed mod beside the folder install with a
higher version. The game loaded it (`v0.00-1138 packed`), the module mounted its subfolders from
inside the pack, and the underground check matched the folder install (unexplored 0/255, explored
within 0.07-0.11/255 of strength 90, 81 compiles). Build 1138 adds a game-build guard: the bypass
entries name the compiled cache of LuaRevision 405907 / AssetsRevision 33225; on any other build
the module stays off and the underground keeps vanilla's strength (unit-tested).
Release Mars.exe confirmed by the owner on 2026-09-27: an expanded game's underground
showed only the revealed area, with no cave distinguishable elsewhere (had the sandboxed mount
failed, the module would have fallen back to strength 90 and the floors would show). The
five-site matrix on 1137 is pending: 61N136W A passed at 73.858 s; B measured 76.416 s, with the
whole excess inside vanilla generation (45.967 s against 43.5-43.9 s) and the 81 shader compiles
at 0:15 in the main menu, before START; it is to be re-run on an idle machine.

## Metadata 1135 / build 474 (`789da09`): near-edge seam repair, five-site pass

Owner report 2026-09-26: at 49N28E, sector A0, a straight raised ridge ran along the map edge.
Owner ruling: the fix must be general, not scenario-specific. Cause: vanilla's near-edge border
(the outer ~30 source cells, hidden behind vanilla's unplayable 1,024-cell border) is built from
offset, sometimes tilted blocks. It carries grid-aligned seams parallel to the edge at fixed depths
(source depth 7, 14 and 22 on the maps seen so far) and short block-end steps perpendicular to it.
The expanded map is playable to its edge. The destination crease pass only translates long seams
whose low side faces the edge; the 49N28E ridge was a 52-row piece standing ~300 units proud at
depth 7, on the line of a 1,650-row lowered seam.

`RepairNearEdgeSourceSeams` (sbm_terrain_copy.lua) runs on every expanded surface map, on the
vanilla grid before resampling, with thresholds from each map's relief and no scenario data:
- Seam pieces: one-cell steps on an exactly grid-aligned line that also carries a long seam. Seams
  the destination pass repairs are left to it. Only the edge-side strip moves: height and slope
  continue the inner surface, the slope change fades out by the physical edge, and inner cells
  stay vanilla. Offsets and bends use running medians along the edge (per-row values roughened
  the strip threefold in 1132, because vanilla heights are 8-unit quantised).
- Block ends (1134-1135): a perpendicular step that starts at the edge, ends inside the band and
  lies along a repaired seam stretch is split between its two sides and blended out over 12 cells.

What it repaired: 49N28E 5 pieces (including the A0 ridge); 15S67E 4 pieces and 3 block ends;
17S11W 2 pieces and 1 block end; 24S74W, 45S120W and 61N136W nothing. Cost 76-161 ms.
Before/after images: `_ralph/runs/ridge49n28e/edge_zoom_1135.png`,
`_ralph/runs/seam15s67e/bottom_edge_1131_1135.png`. Remaining, both faint: block ends below the
contrast threshold (~80 source units, against 350-920 before), and 49N28E's lowered seam where it
crosses steep slopes, where it reads as a slope change rather than a step.

| Site | START-to-T1 A / B / save | Underground A / B / save | Corrected | Seam repair |
|---|---|---|---|---|
| 61N136W | 73.226 / 73.473 / 71.647 s | 46.063 / 46.666 / 44.705 s | 21 | none |
| 24S74W | 71.337 / 65.561 / 65.981 s | 49.669 / 49.693 / 47.898 s | 11 | none |
| 45S120W | 63.343 / 62.992* / 62.369 s | 44.128 / 44.068 / 42.644 s | 39 | none |
| 17S11W | 65.368 / 65.617 / 65.519 s | 55.219 / 54.919 / 54.695 s | 45 | 2 pieces, 1 end |
| 15S67E | 59.590 / 59.449 / 59.634 s | 45.670 / 45.774 / 44.714 s | 16 | 4 pieces, 3 ends |

\* Re-run pinned to A's mystery. The original B (65.783 s) rolled MirrorSphereMystery, which stamps
terrain; it is kept as `45s120w_b`. `45s120w_b_startup_death` died at engine init, before any mod
code, and is kept too.

All gates pass at all five sites, every save / fresh-process load passes, and
`complete_audit1135.json` records accepted = true (RNG source audit: no RNG or seed calls added, no
scenario data in code; checkpoint review: 27 sessions on one payload, clean quits, no display
violations). The build 1133 matrix (`_ralph/runs/allrules-1133`) also passed on an idle machine.
Its first 61N136W runs (83.0 s, 75.3 s) overlapped a Codex session, and one (`_a_rerun2`) took an
external mid-run Lua reload; those are set aside as invalid measurements.

Evidence: `_ralph/runs/allrules-1135` (harness, lifecycle, `five_audit_1135.json`,
`complete_audit1135.json`), `allrules-1133`, `ridge49n28e`, `seam15s67e`. 88 compatibility tests,
18 judge tests and 9 crease parity tests pass, including `crease_near_edge_seam_test.lua` and
`crease_near_edge_block_end_test.lua`.

## Metadata 1131 / build 474 (`60e5b0f`): oasis clusters, five-site pass

Owner request 2026-09-26: top-up anomalies were bunched together in the outer clusters. All anomaly
top-ups were confined to the two-sector perimeter (10 hexes apart, up to 3 per cluster), so they
formed anomaly-only clumps of 3-4. Deposit top-ups were ~80% interior, and cluster badges
repeated (typically surface metals x3). Owner ruling: each outer cluster is an "oasis". It holds
distinct resource kinds, usually one anomaly, and in about a third of clusters one dome bonus
(vista or research site) to draw a dome there. No badge repeats inside a cluster, and clusters
differ. Anomaly top-ups outside clusters use the same whole-map, sector-balanced placement (with
vanilla repulsion) as the deposit top-ups, and keep out of cluster areas.

| Site | START-to-T1 A / B / save | Underground A / B / save | Corrected | Oasis anomalies | Dome bonuses |
|---|---|---|---|---|---|
| 61N136W | 72.283 / 71.520* / 73.412 s | 46.321 / 46.610 / 45.542 s | 21 | 7/7 | 2 of 11 |
| 24S74W | 69.508 / 65.727* / 65.474 s | 51.239 / 50.180 / 48.026 s | 11 | 9/9 | 2 of 11 |
| 17S11W | 65.317 / 65.818 / 65.427 s | 55.303 / 54.827 / 54.324 s | 45 | 9/9 | 4 of 12 |
| 45S120W | 61.608* / 61.614 / 62.241 s | 44.058 / 44.325 / 43.383 s | 39 | 10/10 | 2 of 12 |
| 15S67E | 58.758* / 59.081 / 59.325 s | 45.903 / 46.260 / 44.903 s | 16 | 9/9 | 2 of 10 |

\* Re-run slots. Four original runs rolled MirrorSphereMystery, whose building prefab stamps the
terrain (and, at 24S74W, shifted top-up placement). All four are kept (`24s74w_b_mirrorsphere`,
`61n136w_b`, `45s120w_a`, `15s67e_a`). The 24S74W B re-run (TheMarsBug) and three re-runs pinned
to the twin's mystery (`VERIFY_MYSTERY`) match their twins exactly, including terrain grids. So
pinning does not disturb generation. MirrorSphere comes up often because vanilla's "random"
mystery prefers mysteries not yet played on the account.

All gates pass at all five sites, including the new rule: `ring-content` requires
`ring_cluster_badge_repeats == 0`. Every save / fresh-process load passes, and
`complete_audit1131.json` records accepted = true with no pending checks. Top-up anomalies at
61N136W are now a median 82.5 hexes apart (18 before; vanilla anomalies 46.6), and no other top-up
lands inside a cluster area. Totals of every anomaly kind, deposit type and dome bonus are
unchanged; only placement changed. Map: `_ralph/runs/oasis1128/61n136w_before_after.png`.

Defects found on the way, each with a regression test:
- 1125: `DepositRules.ClusterBadgeKey` was defined above the module table, so the deposits module
  failed to load.
- 1126: the old rocket-pad dome-effect exception filled clusters' anomaly slots with 5 unplanned
  effects. It is now off; the planned dome bonus replaces it.
- 1128: whole-map anomaly placement sampled 64 candidates per sector (2.4 s). It now samples 8
  (0.4 s).
- 1128: the whole-map path built its mountain-base candidates in `pairs()` order over string keys,
  which differs between processes. Identical seeds then gave different anomaly spots. It now visits
  sectors in sorted order. This latent bug dates from before the 2026-08-23 ring rule.
- 1129 (owner report): switching back to the surface after play raised the game's "mod problem
  detected" popup. The map-switch terrain audit "repaired" footprints blocked by the player's
  buildings with `terrain.SetPassability(map, box, value)`, which the engine rejects. The audit is
  now read-only and runs only before T1.

Release Mars.exe timings (below, 2026-09-26) were measured on build 1120 code. The oasis change adds
about 1 s after generation in the harness; release was not re-measured.

Evidence: `_ralph/runs/allrules-1131` (harness, lifecycle, `five_audit_1131.json`,
`complete_audit1131.json`), `oasis1125`-`oasis1128`, `determinism1129`/`1130`, `timing1131`.
88 compatibility tests and 18 judge tests pass.

## Metadata 1120 / build 469 (`c972f94`): vanilla rock compositions, five-site pass

Owner ruling 2026-09-25 (reverses the 2026-09-23 "no floating rocks, including vanilla's own"):
rocks keep vanilla's authored compositions, scaled with the rock. Only floats or open rims that
the expansion creates or widens are corrected, and only back to the vanilla relationship. Mod
top-up rocks and the underground keep the strict rule. A cause census of build 465 found about
three quarters of its seating moves were "fixing" vanilla compositions, for example 17S11W
StonesDarkGroup_03, whose long stone was buried
(`_ralph/runs/allrules-1120/screens/17s11w_cluster_vanilla_1116_1120.jpg`).

How it works: the surface stretch keeps a copy of the untouched native height grid, checked
against the source terrain and re-checked when seating starts. Validation measures each native rock
at its recorded vanilla pose (source position, scale, angle) against that grid and stores
the per-component clearance and open-rim gap on the object (`SuperBigMapNativeGround`, version
3), so later validations and reloaded saves use the same evidence without the grid. A component
that floated in vanilla and stands no higher than that clearance x scale ratio + 4 units is
accepted; one the expansion lifted further is lowered to its vanilla clearance. The planner
always gets the vanilla rim allowance. The surface census reports accepted rocks as
`native_composition_preserved`, which the judge accepts on the surface only.

| Site | START-to-T1 A / B / save | Underground A / B / save | Seating | Corrected (1115) | Vanilla compositions kept |
|---|---|---|---|---|---|
| 61N136W | 71.041 / 70.664 / 73.414 s | 45.651 / 45.525 / 44.145 s | 7.6 s | 21 (56) | 39 |
| 17S11W | 63.880 / 64.043 / 64.257 s | 55.590 / 54.974 / 53.526 s | 9.2 s | 45 (125) | 88 |
| 24S74W | 63.863 / 64.695 / 66.145 s | 49.195 / 49.289 / 48.393 s | 7.4 s | 11 (51) | 34 |
| 45S120W | 62.115 / 62.036 / 61.219 s | 44.071 / 43.536 / 42.255 s | 7.0 s | 39 (99) | 91 |
| 15S67E | 58.107 / 57.955 / 58.096 s | 45.403 / 45.986 / 44.499 s | 3.4 s | 16 (27) | 16 |

All gates pass at all five sites (A/B/unexpanded control), and every save / fresh-process load
keeps all corrected rocks with positive support. Decor is placed in full at every site. 45S120W's first A run rolled
`MirrorSphereMystery`, which stamps its building prefab into the terrain; its height and pass
grids differed from B. That run is kept (`45s120w_a`, 60.462 s); the accepted pair uses a re-run
A (`45s120w_a_rerun`, LightsMystery), recorded via `audit_five_candidate.py --use`.

Per-rock check of every rock build 1116 corrected, against the vanilla twin census
(`_ralph/runs/allrules-1116/seating_causes/*_vanilla`): every open vanilla rim equals the vanilla
map's rim to within 0.5 units. A few fully covered (negative) rims differ from the census by up to
about 220 units; any negative rim gives the same 2-unit allowance, so this has no effect. None of
these rocks is left above its vanilla allowance, and no authored rim is closed. The two-stone
groups' stored clearances match the census (17S11W #106: -395.2 / +115.8 against -397 / +117). Examples at 61N136W: a
Rocks_03_33 that 1115 lowered 19 m now drops 0.84 m, to its vanilla gap (1545 = 1158.8 x 1.331 +
4). A Rocks_03_66 that only lost a vanilla touch drops 5 units, not 45. The remaining large moves
are real expansion damage: cliffs at 17S11W and 15S67E whose base was covered in vanilla and opened
by 4-7.7 m in the expansion close to about +1 unit.

Three defects in the first implementation, found by these checks:
- 1117: `GridRepack` without its copy flag returned the stretch's own source grid, which the
  stretch then freed. Every vanilla lookup read 0, so every rock looked vanilla-authored (fixed
  in `3489e9b`, plus the start-of-seating re-check).
- 1118: a rock seated for another reason (a lost vanilla touch) had its authored rim fully
  closed (`bfbd7e0`).
- 1119: rocks without a valid Z take their vanilla Z from the interpolated vanilla ground. The
  engine divides int/int as integer, so integer source positions read the cell corner, up to about
  160 units off on slopes. This was the StonesDarkGroup_03 case (`c972f94`).

Timing note: a 1119 61N136W probe run measured **75.303 s** (`_ralph/runs/allrules-1119/seating/61n136w_rim`):
the extra 3.8 s is entirely in vanilla map generation (`generate_returned_ms` 45.7 s vs 41-42 s),
not in any sub-timer the mod records. It rolled MirrorSphereMystery, but two runs with the mystery
pinned (new `VERIFY_MYSTERY` harness option) measured 71.415 and 71.556 s. It is recorded as a
generation-time outlier; the margin at 61N136W is about 2-4 s.

Evidence: `_ralph/runs/allrules-1120/harness` (`five_audit_1120.json`),
`_ralph/runs/allrules-1120/lifecycle`, per-rock probes in `_ralph/runs/allrules-111[7-9]` and
`allrules-1120/seating`. 86 compatibility tests and 18 judge tests pass.

### Release Mars.exe timings (what players get), build 469 code

Measured 2026-09-26 in the real release game with the owner present (one UAC approval). A
temporary, owner-approved build (1123, `a02fbea`, reverted in 1124 `684df24`, code identical to
1120) ran all fifteen cases in one process: the same pinned seeds, Super Big Map as the only mod.
Only the first case (61N136W A) is a fresh process; later cases reuse the warm process.

| Site | START-to-T1 A / B | Underground A / B | Unexpanded vanilla: surface / underground | Harness A / B |
|---|---|---|---|---|
| 61N136W | 53.078 / 50.920 s | 39.757 / 39.351 s | 21.247 / 4.197 s | 71.041 / 70.664 s |
| 24S74W | 50.295 / 46.312 s | 42.999 / 42.715 s | 20.074 / 4.198 s | 63.863 / 64.695 s |
| 17S11W | 47.640 / 46.840 s | 47.326 / 47.240 s | 19.677 / 4.200 s | 63.880 / 64.043 s |
| 45S120W | 46.298 / 46.809 s | 37.590 / 37.427 s | 19.828 / 4.197 s | 62.115 / 62.036 s |
| 15S67E | 45.166 / 44.820 s | 39.216 / 39.143 s | 20.880 / 1.003 s | 58.107 / 57.955 s |

Every case finished with 0 rejected and 0 unresolved rocks, the underground ready, 0 Lua errors,
0 reported mods, 0 optimization failures, a clean log and an unchanged payload. (The runner's
`accepted` flag is false only because it still expects the old case-file build to empty
`case.txt`.) Release is about 0.72-0.78 of the harness time. Rock corrections and decor top-up
match the harness exactly at four sites. At 45S120W release placed 2704 top-up objects (3999
attempts) against 2935 (4089) in the harness, so 28,844 rocks were eligible against 29,082, with 37
corrections against 39. The harness gave 2935 under three different mysteries, so this is a
remaining harness/release decor difference at that site, not a player-facing defect.

Release builds refused file I/O from the autostart: the 1121/1122 case-file variants never
started a case. They also do not route a mod environment's `print` to the log. The working build
logs through the engine's global `print`. Evidence: `_ralph/runs/release-1123/batch`.

## Metadata 1115 / build 465 (`c523d3b`): five-site full-rules pass

Every standing rule gate passes at all five pinned RoughTerrain sites in fresh A/B runs with
same-site unexpanded controls, and every save / fresh-process load check passes. Timings use
the release-equivalent harness (release debug hook, and since this round release prefab names:
see below). All times are strictly below 75 s surface and 60 s underground.

| Site | START-to-T1 A / B / save | Underground A / B / save | Seating | Rocks corrected | Decor |
|---|---|---|---|---|---|
| 61N136W | 72.176 / 70.642 / 73.695 s | 46.071 / 45.749 / 44.331 s | 8.0 s | 56 | 190/190 |
| 17S11W | 67.873 / 69.642 / 67.876 s | 54.341 / 53.846 / 53.450 s | 13.4 s | 125 | 72/72 |
| 24S74W | 65.619 / 64.846 / 65.113 s | 49.310 / 49.371 / 47.822 s | 8.7 s | 51 | 171/171 |
| 45S120W | 61.306 / 60.924 / 61.604 s | 43.223 / 43.225 / 42.270 s | 8.0 s | 99 | 53/53 |
| 15S67E | 58.357 / 58.252 / 58.679 s | 45.512 / 45.607 / 44.269 s | 3.4 s | 27 | 99/99 |

- **Release prefab names in the harness.** Debug `PrefabMarkers` keys carry a POI prefix
  (`Decor.Red.CraterS_06`) while placed markers compose `Red.CraterS_06`, so the harness decor
  top-up resolved ~190 markers against 1927 in release Mars.exe and tested a different layout.
  `run_primary_headless.py --prefab-names release` (default) adds a fallback to the unique
  POI-prefixed entry (`_ralph/tmp/release_prefab_names.lua`). At 61N136W (build 1111) the
  harness then matched release exactly: 190/9/181 groups, 727,247 attempts, 5,456 objects, 80
  corrections. Earlier harness decor results are not release-equivalent.
- **Two top-up defects that release players would have hit, both fixed.** 24S74W failed with a
  top-up `Rocks_03_33` whose open base stood ~12 m above a slope: the stamp planner now applies
  the final seating's rim rule (`40a30a5`). 61N136W then failed with a top-up
  `StonesRedSmall_05` 49 units above flat ground: the planner took the origin of invalid-Z
  scatter from its visual Z, 81 units above its transform origin while pass edits were
  suspended; it now plans from the transform origin and seats it on the destination terrain
  (`c523d3b`). Vanilla objects are unaffected.
- **17S11W paired state.** The first B run differed from A in height/pass grids (+23 rocks).
  Its log shows vanilla picked `MirrorSphereMystery` for the "random" mystery; that mystery adds
  map content. The mystery is re-rolled every run (about ten different mysteries in 21 runs);
  20 of 21 runs, including a re-run of B (`DreamMystery`), are bit-identical. The failing B run
  is retained (`17s11w_b`), the accepted pair uses `17s11w_b_rerun`. Future A/B pairs should pin
  `Game.idMystery`.
- Earlier this round, 61N136W B measured 77.893 s while a review agent ran the test suite on the
  same machine; the quiet repeat was 73.653 s. Both are retained (build 1111 evidence).
- Windows changed from 3840x2160 to 1024x768 during test launches; the tooling never calls a
  display API and the runs guard the current 1024x768.

Evidence: `_ralph/runs/allrules-1115/harness` (`five_audit_1115.json`, lifecycle verdicts),
diagnostics in `_ralph/runs/allrules-1113` and `allrules-1115`. Source review since build 462:
no new engine RNG draws, no scenario exceptions, seating before T1 enforced; 85 compatibility
tests pass.

Metadata 1116 (`9ff0082`) only removes the temporary release timing autostart that 1115 still
carried (inert in the debug harness; release-only and gated on a case file); its generation is
unchanged, confirmed by a fresh 61N136W run (`_ralph/runs/allrules-1116`).

(Superseded 2026-09-26: release Mars.exe timings for build 469 are in the metadata 1120 section.)
Release Mars.exe timings are still pending: on this machine every Mars.exe launch needs a UAC
elevation approval (the owner's per-user RUNASADMIN compatibility flag; a non-elevated launch
hangs at `Debug::Init()`), and the unattended prompts were cancelled. The one clean release
measurement (build 1111, identical placement to the harness) was 61N136W 57.4 s against 74.6 s in
the harness, a ratio of 0.77; applied to the table above that suggests roughly 45-57 s surface
for players. This is an estimate, not a measurement; underground was not measured in release.

## Metadata 1100 (`a152b05`), release-equivalent measurement

Owner rulings 2026-09-24: rock seating must finish before T1 (a same-day post-T1
waiver was reverted), START-to-T1 must stay below 75 s, rocks must stay as close to
vanilla as possible, and the measurement must reflect what the published mod offers.
The harness keeps a DAP socket open, so the engine gives every Lua thread the
debugger's call/return/line hook, which players never have (about 8 s at 61N136W).
The runner therefore defaults to `--debug-hooks release`: `_ralph/tmp/release_hooks.lua`
makes `ResolveThreadDebugHook` skip only the debugger branch (release resolves to
`SetInfiniteLoopDetectionHook`), a watchdog restores it after the engine's new-game
Lua reload, and a run is rejected unless the hook is verified at the end with no
reinstall after START. Only SuperBigMap is loaded; release diagnostics stay off.

All eight cases below are accepted fresh processes with 0 unresolved rocks, seating
completed before T1, clean flushed logs and the release hook verified:

| Case | START-to-T1 | Seating | Rocks corrected | Notes |
|---|---:|---:|---:|---|
| 61N136W | 73.790 s | 15.122 s | 122 | save/in-process reload exact; underground 44.676 s; 0 census defects |
| 24S74W | 71.528 s | 14.745 s | 106 | |
| 17S11W | 71.258 s | 14.495 s | 127 | |
| 30S146E / `x9pLZCNl` | 70.957 s | 11.870 s | 122 | owner's failing map, fixed in `2021166` |
| 45S120W | 62.131 s | 8.060 s | 98 | |
| 14S36W / `JXhzkS0O` | 60.459 s | 6.237 s | 56 | owner's J5/K5 floating-cliff map |
| 14S36W / `nBJAgUn3` | 60.141 s | 6.199 s | 56 | |
| 15S67E | 59.930 s | 4.044 s | 28 | |

Evidence: `_ralph/runs/welcome-handoff-20260924/matrix_v1100`. Not yet repeated on
this build: A/B/control pairs, fresh-process load, and underground runs for the
faster cases. The narrowest margin (61N136W) is about 1.2 s on this machine; these
are measurements, not a guarantee on slower hardware. Earlier sections use the
debugger-hook harness and are historical.

## Build 462 (historical, debugger-hook harness)

Current build 462 / metadata 1093 (code checkpoint `494f7af`) passes six pinned
RoughTerrain cases, including 14S36W / `nBJAgUn3`, across 30 fresh headless sessions.
Worst of 18 expanded generations: **74.955s START-to-T1**, including completed
rock seating and positive support proof; **57.364s underground loading** through
prepared state and closed covers. A/B/control, both-layer all-rock support,
entrances, passability, buttons and save/reload checks pass with clean flushed logs.

The general fix inspects actual terrain-cutting structures as physical support
neighbours. Exact projected cut faces allow already-grounded nearby rocks to avoid
redundant support graphs; hidden terrain and missing cut geometry remain vetoes.
No scenario-specific exception, changed tolerance or post-T1 seating deferral.
The slowest cases run first, retaining the known difficult seeds.

Evidence: `_ralph/runs/rules-parity/fix-14s36w-20260923/complete_audit462.json`;
`accepted=true`, no failures/pending checks. See ALL_RULES_VERIFICATION.md.
80 compatibility fixtures, 18 judge tests and Lua syntax pass. All 43 local mod
payload files match. Windows 3840x2160 was preserved during windowed testing.
The smallest surface margin is 45ms, so these measurements do not guarantee the
same timing under arbitrary system load. The new fix has not been pushed.

## Historical build460 checkpoint (superseded by462)

Build460/metadata1091 passes all five pinned RoughTerrain scenarios in fresh
A/B/control runs and save/in-process reload/fresh-process load checks.
Worst of15 expanded generations: **74.776s surface START-to-T1** and
**57.391s underground first access through prepared state and covers closed**.
All seating and positive rock-support readiness checks finish beforeT1;
authored vanilla floats receive correction rather than an exemption. Entrances,
ring content, reveal/badge/deposit rules, decoration rules, private-stream
repeatability and all three temporary buttons pass the captured checks.

Evidence: `_ralph/runs/rules-parity/strict-460-20260923`.
`runtime_and_lifecycle_pass=true`, no failures. See ALL_RULES_VERIFICATION.md
for all timings and excluded harness incidents.79 compatibility fixtures,
18 judge tests, Lua syntax and4114 checkpoint-angle predicate cases pass.
The narrowest measured surface margin is224ms; these are measurements on this
machine and these pinned cases, not a guarantee under arbitrary system load.
The owner authorized the local checkpoint and historical-artifact archive.
The checkpoint contains this unchanged tested build; `_ralph` is below2GB and
the recoverable external archive has a before/after checksum manifest.
`checkpoint_followup_audit.json` records the checkpoint and exact measured-payload
identity separately from the preserved pre-checkpoint runtime verdicts.
No new loading work, game launch, push or deletion is part of this follow-up.
See ALL_RULES_VERIFICATION.md for the archive path and historical process caveat.
Early460 completed runs preserved3840x2160; tests remain windowed.
Update:460's first15S67E control startup observed a change to1024x768 and was
closed/excluded before generation. Its evidence is preserved. The cause is
unknown; game settings still specify windowed mode. Further tests use the
owner-authorized current1024x768 and keep the read-only display guard enabled.
Historical459 failed17S11W at76.494s and61N136W at77.012s.460's projected
contact bounds reduce the mesh pairs needing full collision tests; the actual
world-space triangle/contact checks and final physical support gates remain.

## Historical443 status (not current acceptance)

Current workspace candidate: guard **443 / metadata1074**, unpublished and **not accepted overall**. Latest normal-hook17S11W surface diagnostic: **77.691s**, with all79 corrections beforeT1 and all29,677 surface rocks positively supported. Surface timing still FAILS. Latest full17S11W A/B/control was438:83.548/83.485s surface and57.723/58.083s underground; all other runtime gates passed. The required current five-site A/B/control matrix, source/process audit and lifecycle checks remain outstanding. Evidence: `_ralph/runs/strict-443-20260923/17s11w_native_profile`. Historical results below are not current all-rules acceptance. Deadline diagnostics that replaced the external native debugger hook are excluded from timing comparisons.

Both strict limits are required: surface START-to-T1 **<75 seconds**, including seating; underground first-access phase through prepared state and both loading covers closed **<60 seconds**, including deferred impassability. Missing timing/readiness evidence is pending, never a pass. The user subsequently authorized testing at the current Windows resolution; each hidden/windowed run records and preserves its explicitly authorized resolution without changing display settings.

Historical scoped guard399 result: three consecutive fresh 24S74W RoughTerrain release runs measured **74.682 /73.444 /73.640s**; mean **73.922s**, maximum **74.682s**. Their then-existing runtime gates, paired fields and full final map comparisons passed. All six verified rock corrections completed beforeT1, with zero rejected corrections. C passed all three temporary-button handlers. All display samples remained3840x2160; flushed logs were clean through shutdown. Historical verdict: `_ralph/runs/full-rules-399-20260922/release_abc_verdict.json`. These results do not close the later failures; see ALL_RULES_VERIFICATION.md.

The optimized pipeline preserves entrance placement beforeT1 and locks it afterward. Only the temporary source underground forced-mask write/rebuild is deferred; final scaled impassability and authoritative gameplay grids are mandatory before underground access. A fresh-process checkpoint load additionally verifies exact mask persistence, all six corrected poses, both entrance links/positions and all three temporary buttons, including direct underground reveal before placing an Elevator. Native regional U8 terrain-type writing removes a padded-grid copy with full-grid byte-equivalence evidence. Exact contact-tree bound aggregation removes repeated min/max calls without changing bounds, topology or triangle order. Prior398's75.017s overrun and all rejected/instrumented runs remain recorded.

Evidence: `_ralph/runs/seed-fix-under75-20260922/primary_382_abc_verdict.json`. Temporary reveal/elevator button actions also pass. See [ALL_RULES_VERIFICATION.md](ALL_RULES_VERIFICATION.md) for the current results, rejected candidates and broader sweep still in progress.

## Historical guard-374 record — superseded, not current acceptance

The following retains the original narrower record for traceability. Its generation-call timer excluded the full START prefix, and later seed-parity verification failed. Its accepted labels must not be used as current full-rules acceptance.
**Verification correction:** the broader rules audit is not accepted: a same-seed surface enrichment mismatch was found. Corrected full-START measurements span **74.318–76.053 s**, so the time target is not consistently met; the original timings below excluded the START prefix. See [ALL_RULES_VERIFICATION.md](ALL_RULES_VERIFICATION.md) for the current verdict and outstanding checks.
The hardest reference scenario, **15S67E with RoughTerrain**, completes surface preparation below 75 seconds in fresh hidden/windowed game processes.

## Measurement contract

- START is immediately before `GenerateCurrentRandomMap()`, not process launch or pregame setup.
- T1 requires `SuperBigMapSurfacePostPipelineRevalidationComplete` and completed, independently verified rock seating. Seating is not deferred until after T1.
- Surface and underground dimensions remain 819200 × 819200 world units.
- Surface seed: `-515742201377381600`; pinned underground seed: `411683085576098543`; Lua revision: 403908.
- Only SuperBigMap is enabled in each fresh process. Release diagnostics stay disabled.
- The game starts explicitly windowed. The runner reads the primary Windows display mode every 0.2 seconds and refuses startup unless it is 3840 × 2160. No Windows display-setting API is called.
- Acceptance requires successful probe completion, no `[LUA ERROR]` log entries, and no observed display-mode violations.

## Clean completed runs

| Guard / run | START → T1 | Extended checks |
| --- | ---: | --- |
| 373 / `windowed_373_full_a` | 74.283 s | Underground, resources, reveals, linked elevator pair |
| 374 / `windowed_374_full_a` | 74.056 s | Same full checks |
| 374 / `windowed_374_repeat_b` | 74.651 s | Fresh surface repeat, seating and button presence |

The two final-code (guard 374) runs average **74.354 s**, with a range of **74.056–74.651 s**. Both are accepted, have no Lua errors, and recorded no display-mode violations. The latest accepted time is **74.651 s**.

Evidence lives under [_ralph/runs/surface-under75-20260922](_ralph/runs/surface-under75-20260922): each run contains `measurement.json`, `game_log_tail.txt`, and `display_guard.json`.
The earlier guard-371/372 sub-75 measurements are **not clean acceptance results**: subsequent log review found an unbalanced temporary-source processing reason. Guard 373 fixed teardown through the engine's cancellation API; guard 374 additionally rejects foreign processing owners and blocks T1 on failed cleanup.

## Retained behavior and checked invariants

- 99 decorative groups / 3349 top-up objects are retained. Terrain-dependent formations use their full support-island placement planner; the final seating transaction still runs before T1.
- Native grounding retains 275 corrections, with zero capture/apply failures. The final independent seating pass performs three further native corrections, with zero rejected corrections.
- Real first underground access completes; paired-passage validation passes.
- Outer resource/landing audits pass for 38 resources and 10 rocket pads, with zero resource or rocket failures.
- Reveal Surface deep-scans all 400 sectors. Reveal Underground exposes all 111 tested explorable objects.
- The Place Elevator button opens construction, snaps to a real passage, and quick-builds both elevator halves with reciprocal links.
- Live native classification agrees with the full original predicate path on 23586 surface objects.
- Native compute-grid comparison against the literal scalar foothill raster checks 55296 cells; maximum height difference is one stored height unit.

## Removed redundant work

- Reuse immutable signed terrain-edge offers during refinement; retain scalar rechecks whenever earlier writes intersect the query region.
- Reuse shared mesh triangle trees and pose-local transformed bounds/vertices, with exact contact decisions and conservative unknown-geometry vetoes.
- Prove ordinary rocks exclude the union of gameplay/mystery/access classes in one native query instead of several overlapping queries. Dynamic names and parent ownership remain checked; custom/rebound APIs retain the original path.
- Seat terrain-dependent top-up formations during placement so loose pieces do not need a second late relocation transaction.
- Avoid scalar rounding repairs when the full-resolution foothill blend is already bounded within one U16 height quantum. Wider uncertainty still uses the literal scalar calculation; strict test callers default to zero tolerance. No grid-resolution reduction is used.
- Cancel only the exclusively owned temporary source's deferred processing after its final passage query, using `CancelProcessing` before map teardown. The ordinary flush remains the fallback; foreign owners are not discarded.
- Keep the authoritative surface passability commit and both necessary buildability rebuilds. Do not rebuild the entire map redundantly at the final seating barrier.

## Verification

- 51 compatibility test files, including seating-before-T1, source teardown ownership/fallbacks, geometry, support/rollback, and bounded rounding.
- Lua syntax checks for every `Code/*.lua` payload file.
- Terrain-edge tests: 268134 discovery checks, 655391 full track-order checks, and 3097 sampling checks.
- Class predicate comparison: 667222 return/query-order checks, including custom and rebound APIs.
- Strict apron tests: 15414 raster checks, 16170 domain checks, 221 native-mask failure/ownership checks.
- Bounded apron test: 145512 cells. Full production opportunity selection: nine scenarios retain the same selected sites and semantic reports, with the explicit one-height-unit blend allowance.
- Deployment audit: 43/43 payload files match the workspace.

These are local-machine timings and focused runtime checks for the requested scenario, not a guarantee for every seed or hardware configuration.

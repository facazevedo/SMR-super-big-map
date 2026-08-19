# Ralph task contract

## Objective

Make the expanded SURFACE height transform a true 4/3 similarity everywhere except inside a small set of per-mountain compression zones, so that:

1. **Slopes are EXACT outside the zones, and passability/buildability reflect the real final expanded map.** The surface must scale XY and Z by 4/3 outside the zones. Per the authoritative 2026-08-19 ruling, the stock engine's fixed native property lattice is authoritative: cross-twin verdict differences caused solely by its fixed sampling pitch are accepted, but the expanded verdicts must be freshly rebuilt from the final terrain and must never be copied, forced, or stale.
2. **Only mountains that would pierce the engine ceiling are compressed, individually,** each normalized so its own peak lands EXACTLY on the ceiling, with a smooth join at its base (no crease along any isoline — a global piecewise transform is explicitly rejected).
3. **Passability and buildability everywhere reflect the REAL final terrain** (2026-08-19 user ruling): both outside and inside zones they must be exactly what the stock engine immediately recomputes from the final expanded ground and relevant stock inputs — never faked toward vanilla, never copied, and never left stale. Vanilla-to-expanded property differences are diagnostic rather than failures; outside-zone height similarity remains exact.

## The algorithm (user-designed; measured parameters at 42S28W)

Surface only — the underground never overflows (measured interior span 12,767; full 4/3 needs 17,022 of 65,535; keep the existing hard error as a backstop).

1. **Full 4/3 on Z** with a floor shift computed on the INTERIOR of the source grid: exclude one cell of border on every side, then `shift = min(0, FLOOR - floor(interior_min * 4/3))` with **FLOOR = 5000** — exactly 5 in-game meters (guim = 1000 world units per meter; user decision after weighing the units). A named config constant. **The shift may only push terrain DOWN, never lift it** (user rule): if the scaled interior minimum already sits at or below FLOOR, the shift is ZERO and the terrain stays where vanilla's transform puts it — heights are unsigned, so nothing can fall out of range, and a vanilla map whose lowlands are that low keeps them that low. The border exclusion is mandatory: the resampled rim holds artifact values (measured: border min 0 vs true interior min 4,078). Do NOT use GridFrame-then-MinMax to measure the interior — GridFrame writes zeros INTO the grid and poisons the min (measured mistake). Crop-copy the interior (raw new_instance + copyrect, the pattern `stretch_one` already uses) or read min/max over a sub-box.
2. **Overflow zones**: cells whose source height exceeds `src_cap = floor((65535 - shift) * 3/4)`. At 42S28W with the old FLOOR=1000 the survey measured 127,305 cells = 0.34% of the map in 26 connected zones; the original survey ran at FLOOR=1000; at FLOOR=5000 the shift on the surveyed map is -437 (still down-only) and src_cap drops to 49,479, so the zone set grows somewhat, so expect slightly fewer/shallower zones — re-derive the zone set with zonefit.py at FLOOR=5000 (the 26-zone/0.34% survey was measured at FLOOR=1000 and is a lower bound), largest 215x169 cells, tallest peak 13,708 over the ceiling. Zone discovery may be done in Lua on cropped sub-grids (zones are small); do not fight GridEnumZones/GridMask semantics blind — their argument conventions differ from the doc guesses (measured failure), and an offline-python-verified reference for this exact map exists (see Evidence).
3. **Per-zone base by topological persistence** (user's choice): descend the threshold from the peak in steps of ~(src_cap - src_min)/40; the zone's area grows slowly on its own flanks (x1.1-1.2 per step measured) and JUMPS when it floods past its saddle; base = last level before growth exceeds x3. Measured for the largest zone: gentle growth 52,479 -> 45,219, local summit-merge blip x2.64 at 44,009, true flood x4.21 at 33,119; base ~44,000-45,000.
4. **In-zone smooth remap**, applied only to the mountain's cells above its base, on a cropped sub-grid: monotone curve with value base_img and slope exactly 4/3 AT the base (seamless join, no crease) tightening with height so the zone's own peak maps EXACTLY to 65,535. A normalized exponential f(t) = H*(1-e^(-kt))/(1-e^(-kT)) with k solved per zone so f'(0) = 4/3 satisfies all three constraints and is monotone; any curve meeting value/slope/peak/monotone is acceptable. Per-cell Lua cost is bounded: zones total ~1% of cells even after the 4/3 area growth.
5. **Height ranges from measurement**: `ScaleHeightRanges` must take the map's final `to` from the measured post-compression maximum, not the pure affine (the affine over-predicts above zones). The from/floor side keeps the affine. Ordering stays: ranges BEFORE RebuildBuildableGrid (v423 lesson).
6. **Rebuild passability and buildable from the final grid** (existing pipeline order already does this) — that is what makes in-zone passability "reflect the reality of the shrunk mountains".
7. **Objects inside zones seat by SetTerrainZ**, not by the stamped affine (which is invalid there). Measured exposure: 2 objects at 42S28W, both PrefabMarker scaffolding. Stamp the zone set on the map (packed bboxes + base levels, e.g. `SuperBigMapZCompressionZones`) so seating code and the gates know where the affine does not hold. The relief-aware decor path (`sbm_terrain_copy.lua:2137`) and the wonder Z consumers (`sbm_map_generation.lua:6795/7538/8833`) must consult it.
8. The current surface adaptive-Z reduction (`STRETCH_ADAPTIVE_Z_SCALE` behavior in `stretch_one`, `sbm_terrain_copy.lua:~940`) is REPLACED by this. The underground's uniform path is untouched.

## Gates

- `floors`: the entire 21-coordinate object-parity result (task `perfect-21`, all-green DONE) must stay green. Re-measure P1 (30S146E) and 45S82E after EVERY mod change; full sweep re-measure before DONE. The ratchet (`entrance-colocation-and-scale/artifacts/best.json` semantics) binds; a regression is fixed or reverted in-session. NOTE: this change ALTERS every surface Z — object-Z verdicts must follow the new transform (exact affine outside zones, SetTerrainZ inside), and that update must be justified in the gate code, never a silent tolerance.
- `height-similarity-outside-zones`: dump both twins' surface height grids raw (`GridSaveRaw`, probe exists: `height_dump_probe.lua` via `run_parity.py twin ... zonesprobe`); offline, every cell OUTSIDE the zone masks must satisfy expanded == floor(vanilla*4/3) + shift exactly; every zone peak must equal exactly 65,535. numpy/scipy are available (2.5.0/1.18.0).
- `properties-real-final-terrain`: on at least 30S146E, 45S82E, 42S28W and two more batch-2 coordinates, expanded passability and buildability must match an immediate stock-engine rebuild/recalculation from the same final terrain and relevant stock inputs. Cover every required property site, including footprint-aware normalized-zone sites. Preserve vanilla-to-expanded differences as diagnostics, but do not fail them solely for fixed-native-lattice sampling differences.
- `pass-real-inside-zones`: inside zones, sampled passability must match a fresh engine recompute of the final terrain (no stale pass data), and the zone masks + per-zone bases/peaks must be reported per map.
- `underground-unchanged`: underground grids byte-identical to the pre-change pipeline on the same seeds.
- `no-crease`: the in-zone remap's join is slope-continuous at the base by construction; verify numerically on the dumped grids (finite-difference slope across the base contour has no step discontinuity).
- Hygiene as always: luac -p, version bump, commit, deploy + audit green BEFORE measuring; game killed on any assert; one game; headless; terse ATTEMPTS with exactly one Progress: line; HANDOFF near 120 lines.

## Started work (continue it, do not redo it)

The first session of the previous workspace built `_ralph/tools/parity/zonefit.py` — the
offline reference implementation of this exact algorithm (interior shift, zone discovery,
persistence bases with a `--rules-report` comparing base rules, the normalized-exponential
in-zone remap with the per-zone k solve, and the gate checks), running on the dumped raw
grids in seconds instead of 3-minute game runs. UPDATE ITS SHIFT FORMULA to the clamped
never-lift rule above (FLOOR=5000), validate the transform offline against `out/height-zq04-surface.raw`,
and only then port the validated algorithm into the mod's Lua.

## Evidence (all measured 2026-08-14, do not re-derive)

- Slope factor today: surface z_ratio 64535/58824 = 1.0971 vs xy 1.3333 (slope factor 0.823); underground 1.3333/1.3333 = 1.000. From `#meta` rows of `out/objects-px02.csv`.
- Passability diffs at 42S28W: surface 289 self-cell (223 false->true one-way), underground 69 bidirectional. Tools: `pass_probe.lua`, joined dumps `out/pass-pv02.csv`/`out/pass-px02.csv`.
- Ring survey that started this: vanilla blocks a contiguous 0-130 degree wedge at every radius around the Bottomless Pit at 42S28W; expanded blocks none of it (`out/rings-wv03.csv`/`out/rings-wx03.csv`). Same object, height profile EXACT (0 error all rings) — pure slope-threshold effect.
- Overflow survey at 42S28W (raw grid `out/height-zq04-surface.raw`, U16 6144^2): interior span 4,078..62,760; shift -4,437; overflow 13,708; src_cap 52,479; 0.3375% of cells; 26 zones; largest zone 27,639 cells, persistence descent table in session log. Objects inside zones: 2 (PrefabMarker x2). Underground raw: `out/height-zq04-underground.raw`, span 10,000..22,767.
- The floor shift alone can NEVER fit full 4/3 on this map: needs source span <= 48,401 (margin 1000); the map has 58,682. Going margin 1000 -> 0 buys only 1,000 of the 12,897 shortfall.
- Engine grid ops: `GridSaveRaw(path, grid)` works (U16); `GridEnumZones(grid, min_area)` returns zones with labels (NOT height levels); GridMask argument conventions are unverified — treat with care. `GridRemap` is linear-only; there is no LUT/curve op, hence per-zone Lua on crops.
- 21/21 object parity is DONE and protected (`_ralph/runs/perfect-21/DONE.md`, cases in `artifacts/cases.json`, mod v804, payload commit 25a73ab). All predecessor workspaces are READ-ONLY.

## Completion gate

DONE.md only when: all gates above are green with per-coordinate tables (zone count, bases, peaks-at-cap, outside-zone height equality, fresh final-terrain passability/buildability consistency, and diagnostic cross-twin property differences); the 21-case object parity is re-proven green on the final code; save-roundtrip is re-run green at P1; every change is committed and deployed with a green audit; and no error/assert/crash/timeout occurs in the final runs. Document the transform (formula, per-zone solve, zone stamps) and the accepted fixed-lattice property policy in HANDOFF.

## Blockers

Per predecessors. Quota pauses are not blockers and do not consume budget. If a map is found whose INTERIOR span exceeds what even per-mountain compression can absorb while keeping bases joined at slope 4/3 (i.e., zones would cover a non-trivial fraction of the map), stop and present the numbers rather than silently widening zones: that is a design decision for the user.

The fixed 50-world-unit native passability lattice established in iteration 787
is explicitly accepted by `USER_RULING_2026-08-19.md` and is not a blocker.

# Ralph task contract

## Objective

Make the expanded SURFACE height transform a true 4/3 similarity everywhere except inside a small set of per-mountain compression zones, so that:

1. **Slopes — and therefore passability — are EXACT outside the zones.** Today the surface scales XY by 4/3 but Z by only ~1.097 (adaptive reduction to fit the 16-bit ceiling), flattening every slope to ~82% of vanilla. Measured consequence at 42S28W: 289 of 4,692 surface objects stand on ground whose own-cell passability differs from vanilla, 223 of them one-way false->true (vanilla-impassable became walkable). The underground already scales Z by exactly 4/3 and shows only bidirectional noise (69, both ways) — that is the proof the similarity transform fixes it.
2. **Only mountains that would pierce the engine ceiling are compressed, individually,** each normalized so its own peak lands EXACTLY on the ceiling, with a smooth join at its base (no crease along any isoline — a global piecewise transform is explicitly rejected).
3. **Passability everywhere reflects the REAL final terrain** (user ruling): outside zones it must equal vanilla exactly; inside zones it must be exactly what the engine recomputes from the compressed ground — never faked toward vanilla, never left stale.

## The algorithm (user-designed; measured parameters at 42S28W)

Surface only — the underground never overflows (measured interior span 12,767; full 4/3 needs 17,022 of 65,535; keep the existing hard error as a backstop).

1. **Full 4/3 on Z** with a floor shift computed on the INTERIOR of the source grid: exclude one cell of border on every side, then `shift = min(0, FLOOR - floor(interior_min * 4/3))` with **FLOOR = 200** (a named config constant; it was 1,000 in the old code purely as a round 1-meter convention — 200 clears rounding noise and the resample edge effect by an order of magnitude while buying 800 more units of headroom). **The shift may only push terrain DOWN, never lift it** (user rule): if the scaled interior minimum already sits at or below FLOOR, the shift is ZERO and the terrain stays where vanilla's transform puts it — heights are unsigned, so nothing can fall out of range, and a vanilla map whose lowlands are that low keeps them that low. The border exclusion is mandatory: the resampled rim holds artifact values (measured: border min 0 vs true interior min 4,078). Do NOT use GridFrame-then-MinMax to measure the interior — GridFrame writes zeros INTO the grid and poisons the min (measured mistake). Crop-copy the interior (raw new_instance + copyrect, the pattern `stretch_one` already uses) or read min/max over a sub-box.
2. **Overflow zones**: cells whose source height exceeds `src_cap = floor((65535 - shift) * 3/4)`. At 42S28W with the old FLOOR=1000 the survey measured 127,305 cells = 0.34% of the map in 26 connected zones; FLOOR=200 shifts 800 further down, so expect slightly fewer/shallower zones — re-derive the exact set with zonefit.py, largest 215x169 cells, tallest peak 13,708 over the ceiling. Zone discovery may be done in Lua on cropped sub-grids (zones are small); do not fight GridEnumZones/GridMask semantics blind — their argument conventions differ from the doc guesses (measured failure), and an offline-python-verified reference for this exact map exists (see Evidence).
3. **Per-zone base by topological persistence** (user's choice): descend the threshold from the peak in steps of ~(src_cap - src_min)/40; the zone's area grows slowly on its own flanks (x1.1-1.2 per step measured) and JUMPS when it floods past its saddle; base = last level before growth exceeds x3. Measured for the largest zone: gentle growth 52,479 -> 45,219, local summit-merge blip x2.64 at 44,009, true flood x4.21 at 33,119; base ~44,000-45,000.
4. **In-zone smooth remap**, applied only to the mountain's cells above its base, on a cropped sub-grid: monotone curve with value base_img and slope exactly 4/3 AT the base (seamless join, no crease) tightening with height so the zone's own peak maps EXACTLY to 65,535. A normalized exponential f(t) = H*(1-e^(-kt))/(1-e^(-kT)) with k solved per zone so f'(0) = 4/3 satisfies all three constraints and is monotone; any curve meeting value/slope/peak/monotone is acceptable. Per-cell Lua cost is bounded: zones total ~1% of cells even after the 4/3 area growth.
5. **Height ranges from measurement**: `ScaleHeightRanges` must take the map's final `to` from the measured post-compression maximum, not the pure affine (the affine over-predicts above zones). The from/floor side keeps the affine. Ordering stays: ranges BEFORE RebuildBuildableGrid (v423 lesson).
6. **Rebuild passability and buildable from the final grid** (existing pipeline order already does this) — that is what makes in-zone passability "reflect the reality of the shrunk mountains".
7. **Objects inside zones seat by SetTerrainZ**, not by the stamped affine (which is invalid there). Measured exposure: 2 objects at 42S28W, both PrefabMarker scaffolding. Stamp the zone set on the map (packed bboxes + base levels, e.g. `SuperBigMapZCompressionZones`) so seating code and the gates know where the affine does not hold. The relief-aware decor path (`sbm_terrain_copy.lua:2137`) and the wonder Z consumers (`sbm_map_generation.lua:6795/7538/8833`) must consult it.
8. The current surface adaptive-Z reduction (`STRETCH_ADAPTIVE_Z_SCALE` behavior in `stretch_one`, `sbm_terrain_copy.lua:~940`) is REPLACED by this. The underground's uniform path is untouched.

## Gates

- `floors`: the entire 21-coordinate object-parity result (task `perfect-21`, all-green DONE) must stay green. Re-measure P1 (30S146E) and 45S82E after EVERY mod change; full sweep re-measure before DONE. The ratchet (`entrance-colocation-and-scale/artifacts/best.json` semantics) binds; a regression is fixed or reverted in-session. NOTE: this change ALTERS every surface Z — object-Z verdicts must follow the new transform (exact affine outside zones, SetTerrainZ inside), and that update must be justified in the gate code, never a silent tolerance.
- `height-similarity-outside-zones`: dump both twins' surface height grids raw (`GridSaveRaw`, probe exists: `height_dump_probe.lua` via `run_parity.py twin ... zonesprobe`); offline, every cell OUTSIDE the zone masks must satisfy expanded == floor(vanilla*4/3) + shift exactly; every zone peak must equal exactly 65,535. numpy/scipy are available (2.5.0/1.18.0).
- `pass-exact-outside-zones`: the per-object self-cell passability comparison (`pass_probe.lua` via `passall`) must show ZERO differences for objects outside zones, on at least 30S146E, 45S82E, 42S28W and two more batch-2 coordinates. (Ring counts are diagnostic only — ring geometry legitimately differs under the stretch; the gate is the self cell.)
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
never-lift rule above, validate the transform offline against `out/height-zq04-surface.raw`,
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

DONE.md only when: all gates above green with per-coordinate tables (zone count, bases, peaks-at-cap, outside-zone height equality, self-cell passability zeros, in-zone recompute consistency); the 21-case object parity re-proven green on the final code; save-roundtrip re-run green at P1; every change committed and deployed with a green audit; no error/assert/crash/timeout in the final runs. Document the transform (formula, per-zone solve, zone stamps) in HANDOFF.

## Blockers

Per predecessors. Quota pauses are not blockers and do not consume budget. If a map is found whose INTERIOR span exceeds what even per-mountain compression can absorb while keeping bases joined at slope 4/3 (i.e., zones would cover a non-trivial fraction of the map), stop and present the numbers rather than silently widening zones: that is a design decision for the user.

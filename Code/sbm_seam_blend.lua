-- Super Big Map -- seam blend (junction terrain re-synthesis).
--
-- PROBLEM: the 2x2 expansion mirror-copies the source quadrant (an EVEN reflection about the
-- seam line), so the terrain is SYMMETRIC across the E/F (vertical) and 14/15 (horizontal)
-- junctions. The reflection keeps heights continuous (no cliff), but the symmetry itself looks
-- unnatural: a ridge near the seam appears mirrored as TWO parallel ridges, and a slope running
-- toward the seam mirrors into a symmetric V-valley (a "trench"). Plus the boundary cell is
-- duplicated.
--
-- FIX: for a band of HalfWidth tiles on each side of each seam, RECOMPUTE the height grid as
--   base   = cubic Hermite across the band between the STABLE terrain at the two band edges
--            (matches height AND slope at both ends -> C1 continuous, no cliff, no flat-ramp edge)
--   detail = fractal value-noise scaled to the LOCAL relief, multiplied by a window that is 0 at
--            the band edges and peaks mid-band (so detail fades into the real terrain at both
--            boundaries -> continuity preserved) and BREAKS the mirror symmetry.
--   height = base + detail
-- Run for the vertical seam (per row), the horizontal seam (per column), and a 2D patch at the
-- crossing. The result is continuous with both sides yet naturally rough and non-symmetric.
--
-- Noise is a deterministic sin-hash value noise keyed on GLOBAL height-grid cell coordinates, so
-- the vertical pass, horizontal pass and intersection patch all agree on overlapping cells.
-- Mechanical grid access (editor.GetGrid/SetGrid, refresh, pause) mirrors the prior seam module.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall

local floor = math.floor
local ceil = math.ceil
local max = math.max
local min = math.min
local sin = math.sin
local pi = math.pi
local abs = math.abs

local function cfg() return SuperBigMap.Config or {} end
local function num(key, default)
	local v = cfg()[key]
	return (type(v) == "number") and v or default
end
local function Enabled() return cfg().SEAM_BLEND_ENABLED == true end

local function Log(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then DebugLog.Info("Seam", message, data) end
end

-- ---------------------------------------------------------------------------------------
-- Math
-- ---------------------------------------------------------------------------------------
local function Clamp01(t)
	if t < 0 then return 0 elseif t > 1 then return 1 end
	return t
end
local function SmoothStep(t) t = Clamp01(t); return t * t * (3 - 2 * t) end

-- Cubic Hermite at t in [0,1] between (h0, slope m0) and (h1, slope m1); slopes are per unit t
-- (i.e. already multiplied by the span). C1-continuous at both ends.
local function Hermite(h0, m0, h1, m1, t)
	local t2 = t * t
	local t3 = t2 * t
	return (2 * t3 - 3 * t2 + 1) * h0
		+ (t3 - 2 * t2 + t) * m0
		+ (-2 * t3 + 3 * t2) * h1
		+ (t3 - t2) * m1
end

-- Window: 0 at t=0 and t=1, 1 at t=0.5. Smooth (so the detail fades in/out at the band edges).
local function Window(t) return sin(pi * Clamp01(t)) end

-- ---------------------------------------------------------------------------------------
-- Deterministic value noise (sin-hash; no engine RNG, no bitops -> version-safe).
-- ---------------------------------------------------------------------------------------
local function Hash2(ix, iy, seed)
	local s = sin(ix * 127.1 + iy * 311.7 + seed * 0.137) * 43758.5453
	return s - floor(s) -- [0,1)
end

local function ValueNoise(fx, fy, seed)
	local x0, y0 = floor(fx), floor(fy)
	local u = SmoothStep(fx - x0)
	local v = SmoothStep(fy - y0)
	local a = Hash2(x0, y0, seed)
	local b = Hash2(x0 + 1, y0, seed)
	local c = Hash2(x0, y0 + 1, seed)
	local d = Hash2(x0 + 1, y0 + 1, seed)
	return (a * (1 - u) + b * u) * (1 - v) + (c * (1 - u) + d * u) * v -- [0,1]
end

-- Fractal Brownian motion in [-1,1]. fx/fy are in noise-wavelength units.
local function Fbm(fx, fy, octaves, seed)
	local sum, amp, freq, norm = 0, 1, 1, 0
	for i = 1, octaves do
		sum = sum + amp * ValueNoise(fx * freq, fy * freq, seed + i * 101)
		norm = norm + amp
		amp = amp * 0.5
		freq = freq * 2
	end
	if norm <= 0 then return 0 end
	return (sum / norm) * 2 - 1
end

-- ---------------------------------------------------------------------------------------
-- Engine / grid helpers (same access path as the prior seam module).
-- ---------------------------------------------------------------------------------------
local function GridApi()
	local editor_api = Global("editor")
	local box_fn = Global("box")
	if type(editor_api) ~= "table" or type(editor_api.GetGrid) ~= "function"
		or type(editor_api.SetGrid) ~= "function" or type(box_fn) ~= "function" then
		return nil
	end
	return { editor = editor_api, box = box_fn }
end

local function FreeGrid(g)
	if g and type(g.free) == "function" then pcall(g.free, g) end
end

local function NumAt(grid, x, y)
	local v = grid:get(x, y)
	return (type(v) == "number") and v or 0
end

-- NOTE: distinct from Engine.MapWorldSize -- the THIRD return here is mapdata.Width in
-- TILES (used to derive grid cells-per-tile for the seam band), not the tile size. Kept
-- local on purpose; do not replace with Engine.MapWorldSize.
local function MapWorldSize(map)
	local mapdata = map and map.mapdata
	local const_tbl = Global("const")
	local tile = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number"
		and const_tbl.HeightTileSize > 0) and const_tbl.HeightTileSize or nil
	if type(mapdata) == "table" and type(mapdata.Width) == "number" and type(mapdata.Height) == "number"
		and type(tile) == "number" then
		return mapdata.Width * tile, mapdata.Height * tile, mapdata.Width
	end
	return nil
end

local function RefreshTerrainAfterEdit(map, box)
	local terrain_api = Global("terrain")
	if type(terrain_api) ~= "table" then return end
	if type(terrain_api.InvalidateHeight) == "function" then SafeCall(terrain_api.InvalidateHeight, map, box) end
	if type(terrain_api.InvalidateType) == "function" then SafeCall(terrain_api.InvalidateType, map, box) end
	if type(map.RebuildGrids) == "function" then SafeCall(map.RebuildGrids, map, box) end
	if type(terrain_api.RebuildPassability) == "function" then SafeCall(terrain_api.RebuildPassability, map, box) end
	if type(terrain_api.HashGrids) == "function" then SafeCall(terrain_api.HashGrids, map) end
end

local function RunPaused(reason, fn)
	local pause = Global("PauseInfiniteLoopDetection")
	local resume = Global("ResumeInfiniteLoopDetection")
	if type(pause) == "function" then SafeCall(pause, reason) end
	local ok, err = pcall(fn)
	if type(resume) == "function" then SafeCall(resume, reason) end
	if not ok then Log("pass error", { error = tostring(err) }) end
end

-- Snapshot/restore so Apply is RE-RUNNABLE (the live tuner re-applies with new params): the
-- blend reads the current heights and overwrites them, so without this a second Apply would
-- compound on the first. The FIRST Apply (during expansion, before any blend) clones the whole
-- height grid = the raw mirrored terrain; every later Apply restores that clone first, so it
-- always blends from the original. Uses the same editor.GetGrid/SetGrid path as the blend, so
-- the restored data is coherent with what the blend then reads. Returns the action taken.
local function EnsureRawHeightsRestored(api, map, map_w, map_h)
	local fb = api.box(0, 0, floor(map_w), floor(map_h))
	SuperBigMap.State = SuperBigMap.State or {}
	local snap = SuperBigMap.State.seam_blend_snapshot
	if snap and snap.map == map and snap.grid and type(snap.grid.clone) == "function" then
		local ok, copy = pcall(snap.grid.clone, snap.grid) -- write a copy; keep the master intact
		if ok and copy then
			pcall(api.editor.SetGrid, map, "height", copy, fb)
			FreeGrid(copy)
		end
		return "restored"
	end
	-- different map (or none): drop the stale snapshot, then capture the current raw heights.
	if snap and snap.grid and type(snap.grid.free) == "function" then pcall(snap.grid.free, snap.grid) end
	SuperBigMap.State.seam_blend_snapshot = nil
	local ok, g = pcall(api.editor.GetGrid, map, "height", fb)
	if ok and g and type(g.clone) == "function" then
		local ok2, c = pcall(g.clone, g)
		FreeGrid(g)
		if ok2 and c then
			SuperBigMap.State.seam_blend_snapshot = { map = map, grid = c }
			return "snapshotted"
		end
	elseif ok then
		FreeGrid(g)
	end
	return "nosnap"
end

-- ---------------------------------------------------------------------------------------
-- Core: blend one corridor. `data` is a fetched band grid; the seam is at local perpendicular
-- index `lb`. vertical=true -> perpendicular axis is X (process per row); false -> per column.
-- perp_global0 is the global cell index of local perp 0 (for noise continuity). skip_lo/hi (in
-- global along-coords) is the intersection range to leave for the 2D patch.
-- ---------------------------------------------------------------------------------------
local function BlendCorridor(data, vertical, lb, W, stable, perp_global0, wave, octaves, amp_scale, seed, skip_lo, skip_hi)
	local bw, bh = data:size()
	local perp_n = vertical and bw or bh
	local along_n = vertical and bh or bw
	local pL = lb - W
	local pR = lb + W
	if pL - stable < 0 or pR + stable > perp_n - 1 then
		return 0 -- band doesn't fit with stable margin
	end
	local span = pR - pL
	if span < 2 then return 0 end

	local function get(p, a)
		if vertical then return NumAt(data, p, a) else return NumAt(data, a, p) end
	end
	local function set(p, a, v)
		if vertical then data:set(p, a, v) else data:set(a, p, v) end
	end

	local iters = max(1, floor(num("SEAM_BLEND_SMOOTH_ITERATIONS", 8)))
	local sleep = Global("Sleep")
	-- Perpendicular smoothing window: a smooth bump, 1 at the seam and 0 with ZERO slope at the
	-- band edges, so the smoothing fades in gently and leaves no crease/ridge where the band meets
	-- untouched terrain (the old sin(pi*t) window has a non-zero edge slope -> faint edge lines).
	local function Wp(p)
		local t = (p - pL) / span
		return SmoothStep(1 - abs(2 * t - 1))
	end

	-- Load the band (+1-cell perpendicular border) into a flat buffer for fast 2D access.
	local p0 = pL - 1
	local pwid = (pR + 1) - p0 + 1
	local function bi(a, p) return a * pwid + (p - p0) + 1 end
	local buf = {}
	for a = 0, along_n - 1 do
		for p = p0, pR + 1 do buf[bi(a, p)] = get(p, a) end
		if sleep and a > 0 and (a % 256 == 0) then sleep(0) end
	end

	-- 2D windowed diffusion -- ACROSS the seam AND ALONG it. Smoothing along the seam (not each
	-- row independently) is what removes the vertical raised/sunken streaks: per-row smoothing
	-- rounded each row to a slightly different level, leaving those bump/crease lines. Diffusing
	-- in both axes makes the junction one coherent, naturally-eroded surface. pL/pR stay pinned.
	for _ = 1, iters do
		for a = 0, along_n - 1 do
			local am = (a > 0) and (a - 1) or a
			local ap = (a < along_n - 1) and (a + 1) or a
			for p = pL + 1, pR - 1 do
				local w = Wp(p)
				local c = buf[bi(a, p)]
				local avg = (buf[bi(a, p - 1)] + buf[bi(a, p + 1)] + buf[bi(am, p)] + buf[bi(ap, p)]) * 0.25
				buf[bi(a, p)] = c + w * (avg - c)
			end
			if sleep and a > 0 and (a % 256 == 0) then sleep(0) end
		end
	end

	-- Write back + only SUBTLE windowed noise (keep amplitude low; the diffusion does the work).
	local modified = 0
	for a = 0, along_n - 1 do
		if not (skip_lo and a >= skip_lo and a <= skip_hi) then
			local lo, hi = buf[bi(a, pL)], buf[bi(a, pL)]
			for p = pL, pR do local h = buf[bi(a, p)]; if h < lo then lo = h end; if h > hi then hi = h end end
			local relief = hi - lo
			for p = pL + 1, pR - 1 do
				local detail = (amp_scale > 0)
					and (Fbm((perp_global0 + p) / wave, a / wave, octaves, seed) * relief * amp_scale * Wp(p)) or 0
				set(p, a, floor(buf[bi(a, p)] + detail + 0.5))
				modified = modified + 1
			end
		end
		if sleep and a > 0 and (a % 256 == 0) then sleep(0) end
	end
	return modified
end

-- Fetch a full-height band around the vertical seam, blend it, write back, refresh.
local function BlendVerticalSeam(api, map, seam_x, gw, gh, map_w, map_h, W, stable, wave, octaves, amp_scale, seed, sy_cell, sq_half)
	local wpc_x = map_w / gw
	local bx = floor(seam_x / wpc_x + 0.5)
	local pad = W + stable + 2
	local col_lo = max(0, bx - pad)
	local col_hi = min(gw - 1, bx + pad)
	local box = api.box(floor(col_lo * wpc_x), 0, ceil((col_hi + 1) * wpc_x), floor(map_h))
	local ok, data = pcall(api.editor.GetGrid, map, "height", box)
	if not ok or not data or type(data.get) ~= "function" then Log("vertical GetGrid failed"); return end
	local lb = bx - col_lo
	local skip_lo, skip_hi
	if sy_cell and sq_half then skip_lo, skip_hi = sy_cell - sq_half, sy_cell + sq_half end
	local modified = BlendCorridor(data, true, lb, W, stable, col_lo, wave, octaves, amp_scale, seed, skip_lo, skip_hi)
	local ok_set = pcall(api.editor.SetGrid, map, "height", data, box)
	if ok_set then RefreshTerrainAfterEdit(map, box) end
	FreeGrid(data)
	Log("vertical seam blended", { bx = bx, W = W, modified = modified, set_ok = ok_set })
end

local function BlendHorizontalSeam(api, map, seam_y, gw, gh, map_w, map_h, W, stable, wave, octaves, amp_scale, seed, sx_cell, sq_half)
	local wpc_y = map_h / gh
	local by = floor(seam_y / wpc_y + 0.5)
	local pad = W + stable + 2
	local row_lo = max(0, by - pad)
	local row_hi = min(gh - 1, by + pad)
	local box = api.box(0, floor(row_lo * wpc_y), floor(map_w), ceil((row_hi + 1) * wpc_y))
	local ok, data = pcall(api.editor.GetGrid, map, "height", box)
	if not ok or not data or type(data.get) ~= "function" then Log("horizontal GetGrid failed"); return end
	local lb = by - row_lo
	local skip_lo, skip_hi
	if sx_cell and sq_half then skip_lo, skip_hi = sx_cell - sq_half, sx_cell + sq_half end
	local modified = BlendCorridor(data, false, lb, W, stable, row_lo, wave, octaves, amp_scale, seed, skip_lo, skip_hi)
	local ok_set = pcall(api.editor.SetGrid, map, "height", data, box)
	if ok_set then RefreshTerrainAfterEdit(map, box) end
	FreeGrid(data)
	Log("horizontal seam blended", { by = by, W = W, modified = modified, set_ok = ok_set })
end

-- 2D intersection patch: bilinear base from the four stable corners just outside the square,
-- plus the same windowed noise (2D window) so it joins the two corridors naturally.
local function BlendIntersection(api, map, seam_x, seam_y, gw, gh, map_w, map_h, W, stable, wave, octaves, amp_scale, seed)
	local wpc_x = map_w / gw
	local wpc_y = map_h / gh
	local bx = floor(seam_x / wpc_x + 0.5)
	local by = floor(seam_y / wpc_y + 0.5)
	local pad = W + stable + 2
	local cx_lo = max(0, bx - pad); local cx_hi = min(gw - 1, bx + pad)
	local cy_lo = max(0, by - pad); local cy_hi = min(gh - 1, by + pad)
	local box = api.box(floor(cx_lo * wpc_x), floor(cy_lo * wpc_y), ceil((cx_hi + 1) * wpc_x), ceil((cy_hi + 1) * wpc_y))
	local ok, data = pcall(api.editor.GetGrid, map, "height", box)
	if not ok or not data or type(data.get) ~= "function" then Log("intersection GetGrid failed"); return end
	local bw, bh = data:size()
	local lx = bx - cx_lo
	local ly = by - cy_lo
	local x0 = max(0, lx - W); local x1 = min(bw - 1, lx + W)
	local y0 = max(0, ly - W); local y1 = min(bh - 1, ly + W)
	local ax0 = max(0, x0 - stable); local ax1 = min(bw - 1, x1 + stable)
	local ay0 = max(0, y0 - stable); local ay1 = min(bh - 1, y1 + stable)
	local TL = NumAt(data, ax0, ay0); local TR = NumAt(data, ax1, ay0)
	local BL = NumAt(data, ax0, ay1); local BR = NumAt(data, ax1, ay1)
	local denx = (ax1 - ax0); local deny = (ay1 - ay0)
	if denx <= 0 or deny <= 0 then FreeGrid(data); return end
	local lo, hi = TL, TL
	for _, h in ipairs({ TR, BL, BR }) do
		if h < lo then lo = h end
		if h > hi then hi = h end
	end
	local relief = hi - lo
	local iters = max(1, floor(num("SEAM_BLEND_SMOOTH_ITERATIONS", 8)))
	-- Load the patch (+1-cell border) into a 2D buffer, 2D-diffuse the interior windowed to the
	-- crossing centre (border stays pinned -> continuous with the two corridors), then write +
	-- subtle noise. Matches the corridor smoothing so the junction is coherent.
	local buf = {}
	for x = max(0, x0 - 1), min(bw - 1, x1 + 1) do
		local col = {}
		for y = max(0, y0 - 1), min(bh - 1, y1 + 1) do col[y] = NumAt(data, x, y) end
		buf[x] = col
	end
	local spanx = max(1, x1 - x0)
	local spany = max(1, y1 - y0)
	local function bget(x, y, fallback)
		local c = buf[x]
		local v = c and c[y]
		return (type(v) == "number") and v or fallback
	end
	for _ = 1, iters do
		for x = x0, x1 do
			local uu = (x - x0) / spanx
			local colx = buf[x]
			for y = y0, y1 do
				local vv = (y - y0) / spany
				local w = Window(uu) * Window(vv)
				local h = colx[y]
				local avg = (bget(x - 1, y, h) + bget(x + 1, y, h) + bget(x, y - 1, h) + bget(x, y + 1, h)) * 0.25
				colx[y] = h + w * (avg - h)
			end
		end
	end
	local modified = 0
	for x = x0, x1 do
		local uu = (x - x0) / spanx
		local colx = buf[x]
		for y = y0, y1 do
			local vv = (y - y0) / spany
			local detail = Fbm((cx_lo + x) / wave, (cy_lo + y) / wave, octaves, seed)
				* relief * amp_scale * Window(uu) * Window(vv)
			data:set(x, y, floor(colx[y] + detail + 0.5))
			modified = modified + 1
		end
	end
	local ok_set = pcall(api.editor.SetGrid, map, "height", data, box)
	if ok_set then RefreshTerrainAfterEdit(map, box) end
	FreeGrid(data)
	Log("intersection blended", { bx = bx, by = by, modified = modified, set_ok = ok_set })
end

local SeamBlend = {}
SeamBlend.Hermite = Hermite
SeamBlend.Fbm = Fbm

function SeamBlend.Apply(map)
	if not Enabled() then return false, "disabled" end
	map = map or Global("CurrentMap")
	if not map then return false, "no map" end
	local api = GridApi()
	if not api then Log("apply skipped", { reason = "grid api unavailable" }); return false end
	local ok_ref, gref = pcall(api.editor.GetGrid, map, "height", api.box(0, 0, 1, 1))
	-- GetGrid with a tiny box just to fail fast if the height grid is unavailable; real fetches
	-- happen per-seam below. Resolve full dims from terrain instead.
	if ok_ref then FreeGrid(gref) end

	local terrain_api = Global("terrain")
	local gw, gh
	if type(terrain_api) == "table" and type(terrain_api.HeightMapSize) == "function" then
		local ok, w, h = pcall(terrain_api.HeightMapSize, map)
		if ok and type(w) == "number" and type(h) == "number" then gw, gh = w, h end
	end
	local map_w, map_h, tiles_w = MapWorldSize(map)
	if type(gw) ~= "number" or gw <= 0 or type(map_w) ~= "number" or map_w <= 0 then
		Log("apply skipped", { reason = "bad dims", gw = gw, map_w = map_w }); return false
	end

	local cells_per_tile = (type(tiles_w) == "number" and tiles_w > 0) and (gw / tiles_w) or 1
	local function tiles_to_cells(key, dflt) return max(1, floor(max(1, num(key, dflt)) * cells_per_tile + 0.5)) end
	local W = tiles_to_cells("SEAM_BLEND_HALF_WIDTH_TILES", 12)
	local stable = tiles_to_cells("SEAM_BLEND_STABLE_SAMPLE_TILES", 3)
	local wave = max(2, tiles_to_cells("SEAM_BLEND_NOISE_FREQUENCY_TILES", 6))
	local octaves = max(1, floor(num("SEAM_BLEND_NOISE_OCTAVES", 4)))
	local amp_scale = max(0, num("SEAM_BLEND_NOISE_AMPLITUDE_SCALE", 0.6))
	local seed = floor(num("SEAM_BLEND_SEED", 1337))
	local sq_half = W

	local gen = SuperBigMap.MapGeneration
	local seam_x, seam_y
	if gen and type(gen.GetSeamWorldBoundaries) == "function" then
		seam_x, seam_y = gen.GetSeamWorldBoundaries(map)
	end
	Log("apply begin", {
		gw = gw, gh = gh, W = W, stable = stable, wave = wave, octaves = octaves,
		amp_scale = amp_scale, seam_x = seam_x and floor(seam_x) or "none",
		seam_y = seam_y and floor(seam_y) or "none",
	})
	if not seam_x and not seam_y then
		Log("apply skipped", { reason = "E/F and 14/15 boundaries not found" })
		return false, "no seams"
	end
	local patch = seam_x and seam_y

	RunPaused("SuperBigMapSeamBlend", function()
		-- Restore the raw mirrored heights first (or snapshot them on the first run) so this
		-- Apply -- and every live-tuner re-Apply -- blends from the original, never compounding.
		local snap_action = EnsureRawHeightsRestored(api, map, map_w, map_h)
		Log("snapshot", { action = snap_action })
		if seam_x then
			BlendVerticalSeam(api, map, seam_x, gw, gh, map_w, map_h, W, stable, wave, octaves, amp_scale, seed,
				patch and floor(seam_y / (map_h / gh) + 0.5) or nil, patch and sq_half or nil)
		end
		if seam_y then
			BlendHorizontalSeam(api, map, seam_y, gw, gh, map_w, map_h, W, stable, wave, octaves, amp_scale, seed,
				patch and floor(seam_x / (map_w / gw) + 0.5) or nil, patch and sq_half or nil)
		end
		if patch then
			BlendIntersection(api, map, seam_x, seam_y, gw, gh, map_w, map_h, W, stable, wave, octaves, amp_scale, seed)
		end
	end)
	Log("apply done")
	return true
end

SuperBigMap.SeamBlend = SeamBlend

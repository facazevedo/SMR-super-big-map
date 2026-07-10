-- Super Big Map -- terrain/grid copy + mirror-block mechanics for the L-frame expansion.
--
-- Owns the low-level grid copy (CopyEditorGrid / Flip*), the per-sector-block copy
-- that mirrors terrain + objects into the L-frame (CopySectorBlock and the
-- SECTOR_MIRROR_BLOCKS plan helpers), post-copy fixups (ResnapForeignObjects,
-- ForceFramePassable, RemoveFrameUndergroundAccess), the renderer re-stream
-- (ReinvalidateExpandedTerrain), and sector-geometry lookups. Object classification
-- and cloning live in sbm_object_clone (loaded first); this module binds those
-- helpers at load time. The orchestration (RunSectorMirrorPlanIfEnabled, the
-- generator hook) lives in sbm_map_generation, which loads after this file.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local TryCall = Engine.TryCall
local Unpack = Engine.Unpack
local IsKindOfSafe = Engine.IsKindOf
local ObjectPosition = Engine.ObjectPos

local function cfg_bool(key, default)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "boolean" then
		return value
	end
	return default
end

local function cfg_number(key, default, min_value)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "number" and (min_value == nil or value >= min_value) then
		return value
	end
	return default
end

local function DebugPrint(text)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Generation", text)
	end
end

local function VerbosePrint(text)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("GenerationVerbose", text)
	end
end

local function InitSeq(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog and type(DebugLog.InitSeq) == "function" then
		DebugLog.InitSeq(message, data)
	end
end

-- Per-step trace for the STRETCH frame-fill (gated on Config.DEBUG_STRETCH). Deliberately
-- fine-grained so the LAST line before a stuck-at-loading pinpoints exactly which grid step hung
-- or threw. Temporary diagnostic scope; the code stays, only the flag is turned off for release.
local function StretchLog(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Stretch", message, data)
	end
end

local function TerrainSize(map)
	-- Map size = mapdata tiles x const.HeightTileSize (world units per tile). This is
	-- exactly how the engine reports map size (see MapData.lua) and is ASSERT-FREE.
	-- We must NOT call map:GetMapSize() OR terrain.GetMapSize(map): they are the SAME
	-- engine function (map.GetMapSize == terrain.GetMapSize) and it asserts
	-- "HGE::l_GetMapSize: Map expected" for some map objects -- the function-field
	-- check passes but the CALL asserts, and pcall cannot suppress that dialog.
	-- mapdata.Width is synced to the (expanded) grid size before this runs.
	local mapdata = map and map.mapdata
	local const_tbl = Global("const")
	local tile = type(const_tbl) == "table" and const_tbl.HeightTileSize or nil
	if type(mapdata) == "table" and type(mapdata.Width) == "number" and type(mapdata.Height) == "number"
		and type(tile) == "number" and tile > 0 then
		return mapdata.Width * tile, mapdata.Height * tile
	end

	return map and map.Width or 0, map and map.Height or 0
end

local function PointXY(pos)
	if not pos then
		return false
	end
	if type(pos.xy) == "function" then
		local x, y = SafeCall(pos.xy, pos)
		return x, y
	end
	if type(pos.x) == "number" and type(pos.y) == "number" then
		return pos.x, pos.y
	end
	return false
end

-- Object-side helpers live in sbm_object_clone (loaded first). Bind them to their
-- original local names so the copy code below is unchanged; assert presence so a
-- load-order / export mistake fails LOUDLY at startup, not as a deferred nil-call.
local ObjectClone = SuperBigMap.ObjectClone
assert(type(ObjectClone) == "table",
	"sbm_terrain_copy: SuperBigMap.ObjectClone missing -- load sbm_object_clone before this file")
local ShouldSkipObject = ObjectClone.ShouldSkipObject
local IsImportantSectorObject = ObjectClone.IsImportantSectorObject
local CloneObjectAtOffset = ObjectClone.CloneObjectAtOffset
local ApplyMirrorOrientation = ObjectClone.ApplyMirrorOrientation
local ObjectInsideBox = ObjectClone.ObjectInsideBox
local IsUndergroundAccessObject = ObjectClone.IsUndergroundAccessObject
assert(type(ShouldSkipObject) == "function" and type(CloneObjectAtOffset) == "function"
	and type(ApplyMirrorOrientation) == "function" and type(IsImportantSectorObject) == "function"
	and type(ObjectInsideBox) == "function" and type(IsUndergroundAccessObject) == "function",
	"sbm_terrain_copy: required ObjectClone helpers missing (check sbm_object_clone exports)")

-- Re-invalidate the entire terrain so the renderer re-streams height and texture
-- across the cloned quadrants. Called from the lifecycle PostNewMapLoaded hook
-- as a second-chance refresh: if the MapGenerated-time invalidation didn't take
-- effect (e.g. the renderer wasn't ready, or the engine clamped the invalidate
-- bbox to the original PlayArea), this pass forces the texture/height to
-- re-render across the whole expanded map. Safe to call repeatedly.
-- Sample a grid at 9 positions across its full extent. The cloned quadrant is
-- physically inside the grid (offset, offset) to (size, size) -- if those cells
-- contain a real value (texture index or height), the renderer SHOULD show
-- content. If they contain 0/sentinel, the grid lacks data.
local function SampleGrid(label, grid)
	if not grid or type(grid.size) ~= "function" or type(grid.get) ~= "function" then
		return
	end
	local gw, gh = grid:size()
	if not gw or gw <= 0 then return end

	local samples = {
		{ "TL_0.1", math.floor(gw * 0.1), math.floor(gh * 0.1) },
		{ "TM_0.5", math.floor(gw * 0.5), math.floor(gh * 0.1) },
		{ "TR_0.9", math.floor(gw * 0.9), math.floor(gh * 0.1) },
		{ "ML_0.1", math.floor(gw * 0.1), math.floor(gh * 0.5) },
		{ "MM_0.5", math.floor(gw * 0.5), math.floor(gh * 0.5) },
		{ "MR_0.9", math.floor(gw * 0.9), math.floor(gh * 0.5) },
		{ "BL_0.1", math.floor(gw * 0.1), math.floor(gh * 0.9) },
		{ "BM_0.5", math.floor(gw * 0.5), math.floor(gh * 0.9) },
		{ "BR_0.9", math.floor(gw * 0.9), math.floor(gh * 0.9) },
	}
	local parts = {}
	for i = 1, #samples do
		local name, x, y = samples[i][1], samples[i][2], samples[i][3]
		local ok, value = pcall(grid.get, grid, x, y)
		parts[#parts + 1] = name .. "=" .. tostring(ok and value or "err")
	end
	DebugPrint(string.format("%s size=%sx%s samples: %s", tostring(label), tostring(gw), tostring(gh), table.concat(parts, " ")))
end

local function SampleTypeGrid(map, terrain_api)
	if type(terrain_api.GetTypeGrid) == "function" then
		local g = SafeCall(terrain_api.GetTypeGrid, map)
		SampleGrid("type_grid", g)
	end
	if type(terrain_api.GetHeightGrid) == "function" then
		local g = SafeCall(terrain_api.GetHeightGrid, map)
		SampleGrid("height_grid", g)
	end
end

-- Full-map invalidation bbox in WORLD units, or false if the engine box() ctor
-- is unavailable (some calls then fall back to a whole-map invalidate).
local function FullMapInvalidateBox(map_width, map_height)
	local box_fn = Global("box")
	if type(box_fn) ~= "function" then
		return false
	end
	return box_fn(0, 0, map_width, map_height)
end

-- Repaint/refresh the cloned frame: the type/height grids are populated by the
-- mirror plan, but the renderer may not stream textures into the expanded area
-- until terrain is explicitly invalidated. Called after map generation and again
-- on load (save preserves grid data but not the renderer's streamed state).
local function ReinvalidateExpandedTerrain(map)
	if not cfg_bool("QUADRANT_COPY_TERRAIN", true) then
		DebugPrint("ReinvalidateExpandedTerrain skipped: QUADRANT_COPY_TERRAIN disabled")
		return false
	end
	local terrain_api = Global("terrain")
	if type(terrain_api) ~= "table" then
		DebugPrint("ReinvalidateExpandedTerrain skipped: no terrain api")
		return false
	end
	local map_width, map_height = TerrainSize(map)
	if not map_width or map_width <= 0 or not map_height or map_height <= 0 then
		DebugPrint("ReinvalidateExpandedTerrain skipped: invalid terrain size")
		return false
	end

	-- Diagnostic: dimensions of the terrain grids (which may differ from
	-- mapdata.Width) + texture-index samples at 9 positions across the map.
	-- If samples in the cloned quadrant (e.g. BR_0.9) come back as 0/invalid,
	-- the type grid lacks data there -> renderer correctly draws no texture.
	-- If samples look the same as the source quadrant (TL_0.1), data is fine
	-- and the renderer just hasn't refreshed.
	if type(terrain_api.HeightMapSize) == "function" then
		local ok, hw, hh = pcall(terrain_api.HeightMapSize, map)
		if ok then
			DebugPrint(string.format("terrain.HeightMapSize=%sx%s", tostring(hw), tostring(hh)))
		end
	end
	if type(terrain_api.TypeMapSize) == "function" then
		local ok, tw, th = pcall(terrain_api.TypeMapSize, map)
		if ok then
			DebugPrint(string.format("terrain.TypeMapSize=%sx%s", tostring(tw), tostring(th)))
		end
	end
	SampleTypeGrid(map, terrain_api)

	-- Detect "this map was expanded by the mod" without relying on transient
	-- per-map markers (SuperBigMapSourceWidthTiles etc.), which are set during
	-- generation but NOT persisted in a save. The reliable indicator is the
	-- ratio between map.Width (world units) and mapdata.Width (tile units): on a
	-- vanilla map both report 4096/4096 -> 100 wu/tile. On an expanded map the
	-- mapdata stays at the .fpk's native tile count while map.Width covers the
	-- expanded world extent (e.g. mapdata=6144 but map.Width=819200, ratio 133),
	-- OR the mapdata itself was forced larger (e.g. 8192 mapdata for an 8192
	-- map.Width). Both cases produce a wider map than the source quadrant would
	-- on its own, so we treat anything where wu/tile > 100 OR mapdata > 4096 as
	-- expanded.
	local const_tbl = Global("const")
	local height_tile = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number" and const_tbl.HeightTileSize > 0)
		and const_tbl.HeightTileSize
		or 100
	local mapdata = map and map.mapdata
	local mapdata_width = type(mapdata) == "table" and type(mapdata.Width) == "number" and mapdata.Width or 0
	local wu_per_tile = mapdata_width > 0 and (map_width / mapdata_width) or height_tile
	local has_markers = map and (map.SuperBigMapSourceWidthTiles or map.SuperBigMapGeneratorWidthTiles or map.SuperBigMapDesiredWidthTiles)
	local expanded = has_markers or wu_per_tile > height_tile + 1 or mapdata_width > 4096

	if not expanded then
		DebugPrint(string.format(
			"ReinvalidateExpandedTerrain skipped: vanilla map (mapdata=%s wu/tile=%s)",
			tostring(mapdata_width), tostring(wu_per_tile)
		))
		return false
	end

	local invalidate_box = FullMapInvalidateBox(map_width, map_height)
	DebugPrint(string.format(
		"ReinvalidateExpandedTerrain: terrain=%sx%s mapdata=%s wu/tile=%s markers=%s bbox=%s",
		tostring(map_width), tostring(map_height),
		tostring(mapdata_width), tostring(wu_per_tile),
		tostring(has_markers and true or false),
		invalidate_box and "full-map" or "none"
	))

	if type(terrain_api.InvalidateHeight) == "function" then
		if invalidate_box then
			SafeCall(terrain_api.InvalidateHeight, map, invalidate_box)
		else
			SafeCall(terrain_api.InvalidateHeight, map)
		end
	end
	if type(terrain_api.InvalidateType) == "function" then
		if invalidate_box then
			SafeCall(terrain_api.InvalidateType, map, invalidate_box)
		else
			SafeCall(terrain_api.InvalidateType, map)
		end
	end
	if type(terrain_api.RebuildPassability) == "function" then
		if invalidate_box then
			SafeCall(terrain_api.RebuildPassability, map, invalidate_box)
		else
			SafeCall(terrain_api.RebuildPassability, map)
		end
	end
	-- Vanilla engine border fix.
	if type(terrain_api.FixHeightBorder) == "function" and invalidate_box then
		SafeCall(terrain_api.FixHeightBorder, map, invalidate_box)
	end
	-- High-level map-side rebuild. The editor calls this after every height
	-- edit (XEditorRebuildGrids); it triggers a more thorough refresh than the
	-- low-level terrain.Invalidate* calls alone, including buildable grid +
	-- water + objects-z update. Bbox in WORLD units.
	if type(map.RebuildGrids) == "function" and invalidate_box then
		DebugPrint("ReinvalidateExpandedTerrain: map:RebuildGrids")
		SafeCall(map.RebuildGrids, map, invalidate_box)
	end
	-- HashGrids rolls the engine's terrain-hash, which some systems poll to
	-- detect "terrain changed, redraw me" (e.g. clutter, decals). If present,
	-- bumping the hash should kick anything still cached.
	if type(terrain_api.HashGrids) == "function" then
		local ok, h = pcall(terrain_api.HashGrids, map)
		if ok then
			DebugPrint("ReinvalidateExpandedTerrain: terrain.HashGrids -> " .. tostring(h))
		end
	end
	return true
end


-- Sector geometry helpers used by the block copy / mirror plan: the world rect of a
-- sector's area, and lookup of a live MapSector by its display name.
local function SectorWorldRect(area)
	if not area or type(area.Center) ~= "function" or type(area.sizex) ~= "function" or type(area.sizey) ~= "function" then
		return nil
	end
	local c = SafeCall(area.Center, area)
	local w = SafeCall(area.sizex, area)
	local h = SafeCall(area.sizey, area)
	if not c or type(w) ~= "number" or type(h) ~= "number" then
		return nil
	end
	local cx, cy = c:xy()
	return cx - math.floor(w / 2), cy - math.floor(h / 2), cx + math.floor(w / 2), cy + math.floor(h / 2)
end

local function FindSectorByName(map, name)
	local city = map and map.City
	local sectors = city and city.MapSectors
	if type(sectors) ~= "table" then
		return nil
	end
	for col = 1, #sectors do
		local rowt = sectors[col]
		if type(rowt) == "table" then
			for row = 1, #rowt do
				local s = rowt[row]
				if s and tostring(s.display_name) == name then
					return s
				end
			end
		end
	end
	return nil
end

-- World coordinate of the shared edge between two adjacent named sectors. axis "x" -> the
-- vertical seam between side-by-side columns; axis "y" -> the horizontal seam between rows.
local function SectorBoundary(map, a_name, b_name, axis)
	local a = FindSectorByName(map, a_name)
	local b = FindSectorByName(map, b_name)
	if not a or not b then return nil end
	local ax1, ay1 = SectorWorldRect(a.area)
	local bx1, by1 = SectorWorldRect(b.area)
	if not ax1 or not bx1 then return nil end
	if axis == "x" then return math.max(ax1, bx1) end
	return math.max(ay1, by1)
end

local function CopyGridRect(get_fn, set_fn, map, fx1, fy1, fx2, fy2, tx1, ty1, map_w, map_h, table_key)
	local box_fn = Global("box")
	local point_fn = Global("point")
	if type(get_fn) ~= "function" or type(set_fn) ~= "function" then
		return false
	end
	local ok, grid = pcall(get_fn, map)
	if not ok or not grid or type(grid.size) ~= "function" or type(grid.clone) ~= "function" or type(grid.copyrect) ~= "function" then
		return false
	end
	local gw, gh = grid:size()
	local function cx(wx) return math.max(0, math.min(gw, math.floor(gw * wx / map_w + 0.5))) end
	local function cy(wy) return math.max(0, math.min(gh, math.floor(gh * wy / map_h + 0.5))) end
	local src = grid:clone()
	pcall(grid.copyrect, grid, src, box_fn(cx(fx1), cy(fy1), cx(fx2), cy(fy2)), point_fn(cx(tx1), cy(ty1)))
	if type(src.free) == "function" then pcall(src.free, src) end
	local set_ok = TryCall(set_fn, map, grid)
	if not set_ok and table_key then
		set_ok = TryCall(set_fn, map, { [table_key] = grid, invalid_grid_type = 0 })
	end
	return set_ok == true
end

-- Return a new grid that is `g` flipped left<->right (mirror across the vertical
-- / y axis). Uses 1-column copyrect (C-speed) instead of per-cell Lua. Caller
-- frees the result; `g` is left intact. Returns nil if the grid lacks the ops.
local function FlipGridHorizontal(g)
	local box_fn = Global("box")
	local point_fn = Global("point")
	if not g or type(g.size) ~= "function" or type(g.clone) ~= "function"
		or type(g.copyrect) ~= "function" or type(box_fn) ~= "function" or type(point_fn) ~= "function" then
		return nil
	end
	local w, h = g:size()
	if type(w) ~= "number" or w <= 0 or type(h) ~= "number" or h <= 0 then
		return nil
	end
	local out = g:clone()
	for x = 0, w - 1 do
		pcall(out.copyrect, out, g, box_fn(x, 0, x + 1, h), point_fn(w - 1 - x, 0))
	end
	return out
end

-- Flip a grid TOP<->BOTTOM (reverse local Y: new_y = h-1-old_y). The "horizontal
-- mirror" in the sector-mirror plan (a reflection across the horizontal axis).
local function FlipGridVertical(g)
	local box_fn = Global("box")
	local point_fn = Global("point")
	if not g or type(g.size) ~= "function" or type(g.clone) ~= "function"
		or type(g.copyrect) ~= "function" or type(box_fn) ~= "function" or type(point_fn) ~= "function" then
		return nil
	end
	local w, h = g:size()
	if type(w) ~= "number" or w <= 0 or type(h) ~= "number" or h <= 0 then
		return nil
	end
	local out = g:clone()
	for y = 0, h - 1 do
		pcall(out.copyrect, out, g, box_fn(0, y, w, y + 1), point_fn(0, h - 1 - y))
	end
	return out
end

-- Copy one named terrain grid region from from_box to to_box using the editor's
-- RENDER-AWARE editor.GetGrid/editor.SetGrid (the same path XEditorUndo uses to
-- restore grid changes -- it notifies the renderer). A raw GetGridRef:copyrect
-- changes the grid DATA but does NOT refresh the colorize tint, which is why the
-- copied sector kept the wrong color. from_box/to_box are WORLD boxes; SetGrid
-- handles each grid's own resolution. When mirror_x is true the region is flipped
-- left<->right before being applied (a mirror across the y axis). Returns true on
-- success.
local function CopyEditorGrid(map, name, from_box, to_box, debug, mirror_x, mirror_y)
	local editor_api = Global("editor")
	if type(editor_api) ~= "table" or type(editor_api.GetGrid) ~= "function" or type(editor_api.SetGrid) ~= "function" then
		return false, "GetGrid/SetGrid unavailable"
	end
	local ok_get, data = pcall(editor_api.GetGrid, map, name, from_box)
	if not ok_get or not data then
		if debug then DebugPrint(string.format("  grid %-16s GetGrid failed (%s)", tostring(name), tostring(data))) end
		return false, "GetGrid failed"
	end
	local function free_grid(x)
		if x and (type(x) == "table" or type(x) == "userdata") then
			pcall(function() if type(x.free) == "function" then x:free() end end)
		end
	end
	-- Apply the requested internal flips in turn (X then Y); each flip allocates a
	-- new grid, so free the previous intermediate (but never the original `data`,
	-- which is freed once at the end).
	local apply = data
	if mirror_x then
		local f = FlipGridHorizontal(apply)
		if f then
			if apply ~= data then free_grid(apply) end
			apply = f
		elseif debug then
			DebugPrint(string.format("  grid %-16s H-flip unavailable -- copied un-mirrored on X", tostring(name)))
		end
	end
	if mirror_y then
		local f = FlipGridVertical(apply)
		if f then
			if apply ~= data then free_grid(apply) end
			apply = f
		elseif debug then
			DebugPrint(string.format("  grid %-16s V-flip unavailable -- copied un-mirrored on Y", tostring(name)))
		end
	end
	local ok_set, set_err = pcall(editor_api.SetGrid, map, name, apply, to_box)
	if apply ~= data then free_grid(apply) end
	free_grid(data)
	if debug then
		DebugPrint(string.format("  grid %-16s GetGrid/SetGrid set_ok=%s mx=%s my=%s%s",
			tostring(name), tostring(ok_set), tostring(mirror_x == true), tostring(mirror_y == true),
			ok_set and "" or (" err=" .. tostring(set_err))))
	end
	return ok_set == true
end

-- Resample one EDITOR MapGrid (colour / biome / clutter / grass) from the source region (from_box)
-- up to the full map (to_box). These are compute-backed grids, so editor.GetGrid returns a
-- resample-able grid directly (unlike the NATIVE height/type grids, which need the terrain API and
-- assert in GridResample). GridToCompute guards the odd case; the result is repacked to the
-- destination format before editor.SetGrid so its copyrect into storage matches. Returns success.
local function ResampleMapGrid(map, name, from_box, to_box, interpolate)
	local editor_api = Global("editor")
	local GridToCompute = Global("GridToCompute")
	local GridResample = Global("GridResample")
	local GridRepack = Global("GridRepack")
	local IsComputeGrid = Global("IsComputeGrid")
	if type(editor_api) ~= "table" or type(editor_api.GetGrid) ~= "function"
		or type(editor_api.SetGrid) ~= "function" or type(GridToCompute) ~= "function"
		or type(GridResample) ~= "function" then
		return false
	end
	local function free_grid(x)
		if x and (type(x) == "table" or type(x) == "userdata") then
			pcall(function() if type(x.free) == "function" then x:free() end end)
		end
	end
	StretchLog("mapgrid: get src", { grid = name })
	-- GetGrid(from_box) is ALWAYS safe: the source region is within any grid's coverage.
	local ok_s, src = pcall(editor_api.GetGrid, map, name, from_box)
	if not ok_s or not src then
		StretchLog("mapgrid: src absent/failed -- skip", { grid = name, err = tostring(src) })
		return false
	end
	-- SIZE GUARD: some MapGrids (e.g. BiomeGrid) are allocated only for the generated SOURCE region,
	-- NOT the full expanded map. GetGrid(to_box = full) on such a grid overflows its storage and
	-- trips a C assert (dtGrid.h: x2 <= src.m_width) that pcall CANNOT catch. Detect it without
	-- issuing the bad read: for a FULL-map grid the source sub-grid is ~frac of the ref; for a
	-- SOURCE-sized grid it is ~all of it. If the source region already fills most of the grid, the
	-- grid does not cover the full map -> skip (leaving it source-only rather than asserting).
	local function grid_w(g)
		if not g or type(g.size) ~= "function" then return nil end
		local ok, w = pcall(function() return g:size() end)
		return ok and type(w) == "number" and w or nil
	end
	local frac = 1.0
	if type(to_box.sizex) == "function" and type(from_box.sizex) == "function" then
		local ok_t, tw = pcall(function() return to_box:sizex() end)
		local ok_f, fw = pcall(function() return from_box:sizex() end)
		if ok_t and ok_f and type(tw) == "number" and tw > 0 and type(fw) == "number" then
			frac = (fw + 0.0) / tw
		end
	end
	local ref = (type(editor_api.GetGridRef) == "function") and SafeCall(editor_api.GetGridRef, map, name) or nil
	local ref_w, src_w = grid_w(ref), grid_w(src)
	if type(ref_w) == "number" and ref_w > 0 and type(src_w) == "number"
		and src_w > ref_w * (frac + 1.0) / 2 then
		StretchLog("mapgrid: NOT full-map sized -- skip (avoids full-box overflow assert)",
			{ grid = name, src_w = src_w, ref_w = ref_w, frac = tostring(frac) })
		free_grid(src)
		return false
	end
	local ok_d, dst_ref = pcall(editor_api.GetGrid, map, name, to_box)
	if not ok_d or not dst_ref then
		free_grid(src)
		StretchLog("mapgrid: dst ref failed -- skip", { grid = name })
		return false
	end
	local ok_all, res = pcall(function()
		local dw, dh = dst_ref:size()
		StretchLog("mapgrid: dims", { grid = name, dw = dw, dh = dh })
		local src_c = GridToCompute(src)
		local stretched = GridResample(src_c, dw, dh, interpolate == true)
		local out = stretched
		if type(GridRepack) == "function" and type(IsComputeGrid) == "function" then
			local fmt, bits = IsComputeGrid(dst_ref)
			if fmt then out = GridRepack(stretched, fmt, bits) end
		end
		local ok_set = pcall(editor_api.SetGrid, map, name, out, to_box)
		StretchLog("mapgrid: set done", { grid = name, ok_set = ok_set })
		if src_c ~= src then free_grid(src_c) end
		if out ~= stretched then free_grid(out) end
		free_grid(stretched)
		return ok_set == true
	end)
	free_grid(dst_ref)
	free_grid(src)
	if not ok_all then
		StretchLog("mapgrid: EXCEPTION", { grid = name, err = tostring(res) })
	end
	return ok_all and res == true
end

-- True once BiomeGrid has been resized to the FULL expanded map (so the stretch won't leave a grey
-- frame). Same source-vs-ref size test as the ResampleMapGrid guard: for a full-map grid the
-- source sub-grid is ~frac of the ref; for a source-only grid it is ~all of it. Returns true if
-- biome is full-map OR absent (nothing to wait for). Polled before the stretch instead of a fixed
-- settle -- lets the load proceed the instant biome is ready rather than always waiting the cap.
local function StretchBiomeReady(map)
	if not map then return true end
	local editor_api = Global("editor")
	if type(editor_api) ~= "table" or type(editor_api.GetGrid) ~= "function"
		or type(editor_api.GetGridRef) ~= "function" then return true end
	local box_fn = Global("box")
	if type(box_fn) ~= "function" then return true end
	local const_tbl = Global("const")
	local hts = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number") and const_tbl.HeightTileSize or 1
	local sw = map.SuperBigMapSourceWidthTiles or map.SuperBigMapGeneratorWidthTiles
	local sh = map.SuperBigMapSourceHeightTiles or map.SuperBigMapGeneratorHeightTiles
	local full = map.SuperBigMapDesiredWidthTiles or (map.mapdata and map.mapdata.Width)
	if not (type(sw) == "number" and type(full) == "number" and full > sw) then return true end
	local from_box = box_fn(0, 0, sw * hts, (sh or sw) * hts)
	local ok_s, src = pcall(editor_api.GetGrid, map, "BiomeGrid", from_box)
	if not ok_s or not src then return true end -- absent -> nothing to wait for
	local function gw(g)
		if not g or type(g.size) ~= "function" then return nil end
		local ok, w = pcall(function() return g:size() end)
		return ok and type(w) == "number" and w or nil
	end
	local ref = SafeCall(editor_api.GetGridRef, map, "BiomeGrid")
	local rw, sw2 = gw(ref), gw(src)
	pcall(function() if type(src.free) == "function" then src:free() end end)
	if type(rw) ~= "number" or type(sw2) ~= "number" or rw <= 0 then return true end
	local frac = (sw + 0.0) / full
	return sw2 <= rw * (frac + 1.0) / 2
end

-- STRETCH frame-fill mode: resample the generated SOURCE corner of the terrain up to the FULL map
-- size, so the map is ONE continuous terrain (no L-frame, no mirror seam). Features come out
-- ~full/source (about 1.33x) larger -- a "zoomed" version of the real generated terrain.
--
-- Scope: HEIGHT + TERRAIN-TYPE only (shape + ground texture -- enough to judge the look). Biome/
-- colour and objects/deposits are NOT touched here (separate passes). We must go through the
-- engine's COMPUTE-grid terrain API the same way the map generator does: editor.GetGrid returns
-- NATIVE storage grids that GridResample rejects ("Grid Type Not Supported"), so each grid is
-- converted to a compute grid (GridToCompute) before resampling and written back through the
-- terrain setter (terrain.SetHeightGrid / SetTypeGrid accept a compute grid). Returns (ok, done).
local function StretchSourceToFull(map, debug)
	StretchLog("StretchSourceToFull: ENTER", { map = tostring(map and (map.name or "?")) })
	if not map then return false, 0 end
	local terrain_api = Global("terrain")
	local GridToCompute = Global("GridToCompute")
	local GridResample = Global("GridResample")
	local IsComputeGrid = Global("IsComputeGrid")
	local NewComputeGrid = Global("NewComputeGrid")
	local box_fn = Global("box")
	local point_fn = Global("point")
	if type(terrain_api) ~= "table" or type(GridToCompute) ~= "function" or type(GridResample) ~= "function"
		or type(IsComputeGrid) ~= "function" or type(NewComputeGrid) ~= "function"
		or type(box_fn) ~= "function" or type(point_fn) ~= "function" then
		DebugPrint("StretchSourceToFull: required grid/terrain API unavailable -- cannot stretch")
		return false, 0
	end
	local sw_tiles = map.SuperBigMapSourceWidthTiles or map.SuperBigMapGeneratorWidthTiles
	local sh_tiles = map.SuperBigMapSourceHeightTiles or map.SuperBigMapGeneratorHeightTiles
	local full_tw = map.SuperBigMapDesiredWidthTiles
	local full_th = map.SuperBigMapDesiredHeightTiles
	if type(full_tw) ~= "number" or full_tw <= 0 then
		local mapdata = map.mapdata
		full_tw = (type(mapdata) == "table" and type(mapdata.Width) == "number") and mapdata.Width or nil
		full_th = (type(mapdata) == "table" and type(mapdata.Height) == "number") and mapdata.Height or full_tw
	end
	if type(sw_tiles) ~= "number" or type(sh_tiles) ~= "number" or sw_tiles <= 0 or sh_tiles <= 0
		or type(full_tw) ~= "number" or type(full_th) ~= "number" or full_tw <= 0 or full_th <= 0 then
		DebugPrint("StretchSourceToFull: source/full tile sizes unknown -- cannot stretch")
		return false, 0
	end
	if full_tw <= sw_tiles and full_th <= sh_tiles then
		DebugPrint(string.format("StretchSourceToFull: no expansion to stretch (source %sx%s == full %sx%s tiles)",
			tostring(sw_tiles), tostring(sh_tiles), tostring(full_tw), tostring(full_th)))
		return false, 0
	end
	-- Force FLOAT division: this engine's Lua does INTEGER division on int/int (6144/8192 -> 0),
	-- which would collapse the source corner to 1x1 and stretch a single pixel across the map.
	-- (+ 0.0) promotes to float (matching the game's own DivToStr idiom) -> 0.75 as intended.
	local frac_w = (sw_tiles + 0.0) / full_tw
	local frac_h = (sh_tiles + 0.0) / full_th

	local function free_grid(x)
		if x and (type(x) == "table" or type(x) == "userdata") then
			pcall(function() if type(x.free) == "function" then x:free() end end)
		end
	end

	-- Read the full grid via get_fn, take its source corner (cells [0..scw]x[0..sch]), resample
	-- that up to the full cell dims (all in compute-grid space so GridResample accepts it), then
	-- write back via set_fn (+ invalidate). The 'raw' grid from get_fn is left for the engine.
	-- EVERY sub-step is StretchLog'd so a stuck/failed grid is pinpointed to the exact line.
	local function stretch_one(label, get_fn, set_fn, invalidate_fn, interpolate)
		if type(get_fn) ~= "function" or type(set_fn) ~= "function" then
			StretchLog("stretch_one: missing get/set fn", { grid = label })
			return false
		end
		StretchLog("stretch_one: BEGIN", { grid = label, interpolate = interpolate == true })
		local ok_g, raw = pcall(get_fn, map)
		if not ok_g or not raw then
			StretchLog("stretch_one: get FAILED", { grid = label, err = tostring(raw) })
			return false
		end
		StretchLog("stretch_one: got source grid", { grid = label })
		local ok_all, res = pcall(function()
			StretchLog("stretch_one: GridToCompute...", { grid = label })
			local full_c = GridToCompute(raw)
			local fw, fh = full_c:size()
			StretchLog("stretch_one: full grid size", { grid = label, fw = fw, fh = fh })
			local scw = math.max(1, math.min(fw, math.floor(fw * frac_w + 0.5)))
			local sch = math.max(1, math.min(fh, math.floor(fh * frac_h + 0.5)))
			local fmt, bits = IsComputeGrid(full_c)
			StretchLog("stretch_one: NewComputeGrid corner", { grid = label, scw = scw, sch = sch, fmt = tostring(fmt), bits = tostring(bits) })
			local src_sub = NewComputeGrid(scw, sch, fmt, bits)
			StretchLog("stretch_one: copyrect corner...", { grid = label })
			src_sub:copyrect(full_c, box_fn(0, 0, scw, sch), point_fn(0, 0))
			StretchLog("stretch_one: GridResample...", { grid = label, to_w = fw, to_h = fh })
			local stretched = GridResample(src_sub, fw, fh, interpolate == true)
			StretchLog("stretch_one: resample done -> set_fn...", { grid = label })
			local ok_set = pcall(set_fn, map, stretched)
			StretchLog("stretch_one: set_fn done", { grid = label, ok_set = ok_set })
			if type(invalidate_fn) == "function" then pcall(invalidate_fn, map) end
			StretchLog("stretch_one: invalidate done -> freeing", { grid = label })
			free_grid(src_sub)
			if stretched ~= src_sub then free_grid(stretched) end
			if full_c ~= raw then free_grid(full_c) end
			return ok_set == true
		end)
		if not ok_all then
			StretchLog("stretch_one: EXCEPTION", { grid = label, err = tostring(res) })
		else
			StretchLog("stretch_one: END", { grid = label, ok = res == true })
		end
		return ok_all and res == true
	end

	-- Per-step wall-clock timing (DEBUG_STRETCH) to find the loading hotspot. Each grid call is one
	-- long C call -- Lua is single-threaded, so nothing else (not even the UI) runs during it.
	local ticks = Global("GetPreciseTicks") or Global("RealTime")
	local function now_ms()
		if type(ticks) == "function" then
			local ok, t = pcall(ticks)
			if ok and type(t) == "number" then return t end
		end
		return 0
	end
	local t_total = now_ms()
	local function timed(label, fn, ...)
		local t0 = now_ms()
		local a, b = fn(...)
		StretchLog("TIMING: " .. label, { ms = now_ms() - t0 })
		return a, b
	end

	StretchLog("StretchSourceToFull: begin resample", { src_w = sw_tiles, src_h = sh_tiles, full_w = full_tw, full_h = full_th, frac_w = tostring(frac_w) })
	DebugPrint(string.format("StretchSourceToFull: source %sx%s tiles -> full %sx%s tiles (frac %s)",
		tostring(sw_tiles), tostring(sh_tiles), tostring(full_tw), tostring(full_th), tostring(frac_w)))
	local done = 0
	StretchLog("StretchSourceToFull: -> stretch HEIGHT")
	if timed("height", stretch_one, "height", terrain_api.GetHeightGrid, terrain_api.SetHeightGrid, terrain_api.InvalidateHeight, true) then done = done + 1 end
	StretchLog("StretchSourceToFull: -> stretch TYPE")
	if timed("type", stretch_one, "type", terrain_api.GetTypeGrid, terrain_api.SetTypeGrid, terrain_api.InvalidateType, false) then done = done + 1 end
	-- Colour / biome / clutter / grass MapGrids: without these the expanded area shows relief but
	-- renders GREY (no Mars tint). They are compute-backed editor grids, so the editor.GetGrid/
	-- SetGrid + resample path works for them (the native height/type grids above needed the terrain
	-- API). editor.GetGrid with a WORLD box returns exactly the source region, so no corner extract.
	do
		local const_tbl = Global("const")
		local hts = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number") and const_tbl.HeightTileSize or 1
		local box_fn = Global("box")
		if type(box_fn) == "function" then
			local src_box = box_fn(0, 0, sw_tiles * hts, sh_tiles * hts)
			local full_box = box_fn(0, 0, full_tw * hts, full_th * hts)
			local map_grids = {
				{ name = "colorize",        interp = false },
				{ name = "BiomeGrid",       interp = false },
				{ name = "clutter_density", interp = true  },
				{ name = "grass_density",   interp = true  },
			}
			for _, mg in ipairs(map_grids) do
				StretchLog("StretchSourceToFull: -> stretch MAPGRID", { grid = mg.name })
				if timed("mapgrid:" .. mg.name, ResampleMapGrid, map, mg.name, src_box, full_box, mg.interp) then done = done + 1 end
			end
		end
	end
	StretchLog("StretchSourceToFull: -> ReinvalidateExpandedTerrain")
	timed("reinvalidate", ReinvalidateExpandedTerrain, map)
	StretchLog("StretchSourceToFull: COMPLETE", { grids_done = done, total_ms = now_ms() - t_total })
	DebugPrint(string.format("StretchSourceToFull: done (%s grids stretched: height+type+colour/biome/clutter/grass)", tostring(done)))
	return done > 0, done
end

-- STRETCH step 2 (decorations): the generator placed all its scatter/decor in the SOURCE corner
-- (anchored at world origin); once the terrain is stretched to full size those decorations are
-- clustered in one corner on the wrong ground. Move each decoration to its matching spot on the
-- stretched terrain (position * full/source), snap it onto the new surface (SetTerrainZ), and grow
-- the object itself by the SAME factor so it matches the enlarged terrain features.
--
-- Only cosmetic decor is touched: `not ShouldSkipObject` (skips City/sectors/buildings/units/
-- rockets/mystery/underground) AND `not IsImportantSectorObject` (skips resource-deposit markers).
-- Anomalies/effect markers are already skipped by ShouldSkipObject. The colony/landing objects stay
-- put (ShouldSkipObject); only the scatter moves. Deposits/anomalies are a separate later pass.
-- Returns the number of decorations moved.
local function ScaleDecorationsToFull(map, debug)
	StretchLog("ScaleDecorationsToFull: ENTER", { map = tostring(map and (map.name or "?")) })
	if not map then return 0 end
	local const_tbl = Global("const")
	local hts = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number") and const_tbl.HeightTileSize or 1
	local box_fn = Global("box")
	local point_fn = Global("point")
	if type(box_fn) ~= "function" or type(point_fn) ~= "function" then
		StretchLog("ScaleDecorationsToFull: box/point unavailable -- skip")
		return 0
	end
	local sw_tiles = map.SuperBigMapSourceWidthTiles or map.SuperBigMapGeneratorWidthTiles
	local sh_tiles = map.SuperBigMapSourceHeightTiles or map.SuperBigMapGeneratorHeightTiles
	local full_tw = map.SuperBigMapDesiredWidthTiles
	local full_th = map.SuperBigMapDesiredHeightTiles
	if type(full_tw) ~= "number" or full_tw <= 0 then
		local mapdata = map.mapdata
		full_tw = (type(mapdata) == "table" and type(mapdata.Width) == "number") and mapdata.Width or nil
		full_th = (type(mapdata) == "table" and type(mapdata.Height) == "number") and mapdata.Height or full_tw
	end
	if type(sw_tiles) ~= "number" or type(sh_tiles) ~= "number" or sw_tiles <= 0 or sh_tiles <= 0
		or type(full_tw) ~= "number" or type(full_th) ~= "number" or full_tw <= sw_tiles then
		StretchLog("ScaleDecorationsToFull: sizes unknown / no expansion -- skip")
		return 0
	end
	-- Terrain was stretched UP by full/source; decorations move the same way AND grow by that factor
	-- (force FLOAT division -- this Lua does integer division on int/int).
	local scale_x = (full_tw + 0.0) / sw_tiles
	local scale_y = (full_th + 0.0) / sh_tiles
	local src_box = box_fn(0, 0, sw_tiles * hts, sh_tiles * hts)
	-- Collect into a Lua list first (inline MapForEach -- avoids a forward reference to the
	-- CollectObjectsInBox helper declared later in this file), so we mutate objects OUTSIDE the
	-- C callback (moving/scaling inside MapForEach is unsafe).
	local objs = {}
	if type(map.MapForEach) == "function" then
		pcall(map.MapForEach, map, src_box, "CObject", function(o) objs[#objs + 1] = o end)
	end
	StretchLog("ScaleDecorationsToFull: collected", {
		count = #objs, scale_x = tostring(scale_x), scale_y = tostring(scale_y),
		src_tiles = tostring(sw_tiles) .. "x" .. tostring(sh_tiles),
		full_tiles = tostring(full_tw) .. "x" .. tostring(full_th),
		src_box_wu = tostring(sw_tiles * hts) .. "x" .. tostring(sh_tiles * hts),
	})

	-- Exhaustive trace (gated on Config.DEBUG_STRETCH via StretchLog): per-category skip counts, a
	-- sample of the first objects' old->new position + old->new scale (verifies the transform), and
	-- the min/max of the resulting positions (confirms the decor fans out across the full map, i.e.
	-- new_x_range ~ 0..full_wu, not clustered in the source corner).
	local MAX_SCALE = 500 -- engine object-scale ceiling (percent)
	local full_wu = full_tw * hts
	local moved, scaled = 0, 0
	local skipped_skip, skipped_marker, skipped_nopos, no_setpos = 0, 0, 0, 0
	local sample_n = 0
	local minx, miny, maxx, maxy
	-- Time the whole pass (DEBUG_STRETCH) for the loading-hotspot investigation.
	local ticks = Global("GetPreciseTicks") or Global("RealTime")
	local t0 = 0
	if type(ticks) == "function" then local ok, t = pcall(ticks); if ok and type(t) == "number" then t0 = t end end
	-- DECOR TOP-UP (config STRETCH_DECOR_TOPUP): the stretch spreads the ORIGINAL decoration count
	-- over area_factor (~1.78x) more area, thinning density. Give each moved decoration an
	-- (area_factor - 1) chance to spawn ONE jittered clone nearby (within ~0.75 sector), restoring
	-- per-area density while keeping the generator's local clustering character.
	local rand_fn = Global("AsyncRand")
	local topup_on = cfg_bool("STRETCH_DECOR_TOPUP", true) and type(rand_fn) == "function"
		and type(CloneObjectAtOffset) == "function"
	local area_factor_permille = math.floor(scale_x * scale_y * 1000 + 0.5) -- e.g. 1778
	local topup_permille = math.max(0, area_factor_permille - 1000)         -- e.g. 778
	local TOPUP_JITTER = 30000 -- wu (~3/4 sector)
	local topped_up = 0
	-- BATCH passability edits around the mass move: without this every SetPos/SetScale runs its
	-- own local passability update -- measured ~10ms per object, 87s for ~8300 objects (log
	-- 09.18.54); the engine's own mass-spawn code (Billboards.lua, AutoRemoveObj.lua) uses this
	-- exact Suspend/Resume idiom to batch the rebuild into ONE pass at Resume. The per-object
	-- bodies are pcall'd, so the loop cannot throw past the Resume below.
	local pass_batch = type(map.SuspendPassEdits) == "function" and type(map.ResumePassEdits) == "function"
	if pass_batch then pcall(map.SuspendPassEdits, map, "SuperBigMapStretchDecor") end
	for _, obj in ipairs(objs) do
		if not obj then
			-- nil entry, ignore
		elseif ShouldSkipObject(obj) then
			skipped_skip = skipped_skip + 1
		elseif IsImportantSectorObject(obj) then
			skipped_marker = skipped_marker + 1
		else
			pcall(function()
				local pos = ObjectPosition(obj)
				if not pos then skipped_nopos = skipped_nopos + 1; return end
				local ox, oy = PointXY(pos)
				if type(ox) ~= "number" or type(oy) ~= "number" then skipped_nopos = skipped_nopos + 1; return end
				local nx = math.floor(ox * scale_x + 0.5)
				local ny = math.floor(oy * scale_y + 0.5)
				local np = point_fn(nx, ny)
				local z_ok = false
				if type(np.SetTerrainZ) == "function" then
					local ok_z, pz = pcall(np.SetTerrainZ, np, map)
					if ok_z and pz then np = pz; z_ok = true end
				end
				if type(obj.SetPos) == "function" then
					pcall(obj.SetPos, obj, np)
					moved = moved + 1
					minx = minx and math.min(minx, nx) or nx
					maxx = maxx and math.max(maxx, nx) or nx
					miny = miny and math.min(miny, ny) or ny
					maxy = maxy and math.max(maxy, ny) or ny
				else
					no_setpos = no_setpos + 1
				end
				-- Grow the object to match the enlarged terrain features.
				local old_scale, new_scale
				if type(obj.GetScale) == "function" and type(obj.SetScale) == "function" then
					local s = SafeCall(obj.GetScale, obj)
					if type(s) == "number" and s > 0 then
						old_scale = s
						local ns = math.floor(s * scale_x + 0.5)
						if ns > MAX_SCALE then ns = MAX_SCALE elseif ns < 1 then ns = 1 end
						SafeCall(obj.SetScale, obj, ns)
						new_scale = ns
						scaled = scaled + 1
					end
				end
				if sample_n < 15 then
					sample_n = sample_n + 1
					StretchLog("decor sample", {
						n = sample_n, class = tostring(obj.class),
						old_xy = tostring(ox) .. "," .. tostring(oy),
						new_xy = tostring(nx) .. "," .. tostring(ny),
						z_snapped = z_ok, old_scale = old_scale, new_scale = new_scale,
					})
				end
				-- Density top-up: chance to add one jittered clone of this decoration nearby.
				if topup_on and rand_fn(1000) < topup_permille then
					local jx = rand_fn(2 * TOPUP_JITTER + 1) - TOPUP_JITTER
					local jy = rand_fn(2 * TOPUP_JITTER + 1) - TOPUP_JITTER
					local cx = math.max(0, math.min(full_wu - 1, nx + jx))
					local cy = math.max(0, math.min(full_wu - 1, ny + jy))
					-- obj is already AT np, so the clone offset is just the jitter (clamped).
					local clone = CloneObjectAtOffset(map, obj, point_fn(cx - nx, cy - ny))
					if clone then
						-- Snap the clone onto the surface at its jittered spot.
						local cp = point_fn(cx, cy)
						if type(cp.SetTerrainZ) == "function" then
							local ok_cz, cpz = pcall(cp.SetTerrainZ, cp, map)
							if ok_cz and cpz then cp = cpz end
						end
						if type(clone.SetPos) == "function" then pcall(clone.SetPos, clone, cp) end
						topped_up = topped_up + 1
					end
				end
			end)
		end
	end
	if pass_batch then pcall(map.ResumePassEdits, map, "SuperBigMapStretchDecor") end
	local elapsed_ms = 0
	if type(ticks) == "function" then local ok, t = pcall(ticks); if ok and type(t) == "number" then elapsed_ms = t - t0 end end
	StretchLog("ScaleDecorationsToFull: DONE", {
		collected = #objs, moved = moved, scaled = scaled,
		skipped_shouldskip = skipped_skip, skipped_marker = skipped_marker,
		skipped_nopos = skipped_nopos, no_setpos = no_setpos,
		new_x_range = minx and (tostring(minx) .. ".." .. tostring(maxx)) or "none",
		new_y_range = miny and (tostring(miny) .. ".." .. tostring(maxy)) or "none",
		full_wu = full_wu, elapsed_ms = elapsed_ms,
		topped_up = topped_up, topup_permille = topup_permille,
	})
	DebugPrint(string.format("ScaleDecorationsToFull: moved %s decorations (scaled %s, topped up %s; skipped skip=%s marker=%s nopos=%s)",
		tostring(moved), tostring(scaled), tostring(topped_up), tostring(skipped_skip), tostring(skipped_marker), tostring(skipped_nopos)))
	return moved
end

-- STRETCH step 3 (markers): move the generated DEPOSIT / ANOMALY / EFFECT markers (and any
-- already-spawned deposits/anomalies, e.g. the start sector's revealed ones) to their scaled spot
-- on the stretched terrain -- the same position * (full/source) transform as the decorations.
-- Without this they stay clustered in the source corner. Positions only: marker SIZE is gameplay
-- (scan radius/visuals), so scale is left untouched. Gated on config STRETCH_SCALE_MARKERS.
local function ScaleMarkersToFull(map, debug)
	StretchLog("ScaleMarkersToFull: ENTER")
	if not map or not cfg_bool("STRETCH_SCALE_MARKERS", true) then return 0 end
	local const_tbl = Global("const")
	local hts = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number") and const_tbl.HeightTileSize or 1
	local box_fn = Global("box")
	local point_fn = Global("point")
	if type(box_fn) ~= "function" or type(point_fn) ~= "function" then return 0 end
	local sw_tiles = map.SuperBigMapSourceWidthTiles or map.SuperBigMapGeneratorWidthTiles
	local sh_tiles = map.SuperBigMapSourceHeightTiles or map.SuperBigMapGeneratorHeightTiles
	local full_tw = map.SuperBigMapDesiredWidthTiles
	local full_th = map.SuperBigMapDesiredHeightTiles
	if type(full_tw) ~= "number" or full_tw <= 0 then
		local mapdata = map.mapdata
		full_tw = (type(mapdata) == "table" and type(mapdata.Width) == "number") and mapdata.Width or nil
		full_th = (type(mapdata) == "table" and type(mapdata.Height) == "number") and mapdata.Height or full_tw
	end
	if type(sw_tiles) ~= "number" or type(sh_tiles) ~= "number" or sw_tiles <= 0 or sh_tiles <= 0
		or type(full_tw) ~= "number" or type(full_th) ~= "number" or full_tw <= sw_tiles then
		StretchLog("ScaleMarkersToFull: sizes unknown / no expansion -- skip")
		return 0
	end
	local scale_x = (full_tw + 0.0) / sw_tiles
	local scale_y = (full_th + 0.0) / sh_tiles
	local src_box = box_fn(0, 0, sw_tiles * hts, sh_tiles * hts)
	local function is_marker(obj)
		return IsImportantSectorObject(obj) -- resource deposit markers (surface/subsurface/terrain)
			or IsKindOfSafe(obj, "Deposit")
			or IsKindOfSafe(obj, "SubsurfaceAnomaly")
			or IsKindOfSafe(obj, "SubsurfaceAnomalyMarker")
			or IsKindOfSafe(obj, "EffectDepositMarker")
			-- Tunnel/entrance MARKERS move with the stretch on BOTH maps (user-confirmed design):
			-- vanilla generates the surface and underground natural entrances at IDENTICAL native
			-- coordinates (Align logs), so applying the identical x(full/source) transform to both
			-- sides keeps every entrance pair vertically corresponding AND sitting on the terrain
			-- feature it was generated on. The visible structures follow in
			-- MoveEntranceVisualsToScale (STRETCH_MOVE_ENTRANCE_VISUALS).
			or IsKindOfSafe(obj, "SurfaceUndergroundTunnelMarker")
	end
	local objs = {}
	if type(map.MapForEach) == "function" then
		pcall(map.MapForEach, map, src_box, "CObject", function(o) objs[#objs + 1] = o end)
	end
	local moved, sample_n, reregistered = 0, 0, 0
	-- Sector marker REGISTRIES: each MapSector keeps per-sector marker lists (sector.markers.*)
	-- that vanilla Scan reveals from. A moved marker must be re-registered from its old sector to
	-- its new one, or scanning the new sector misses it (and scanning the old one reveals a marker
	-- that is no longer there). Same Unregister/Register pattern as EvenOutDepositDensity.
	local city = map.City
	local get_sector = Global("GetMapSectorXY")
	-- Batch passability edits around the mass marker move (same idiom/reason as the decor pass).
	local pass_batch = type(map.SuspendPassEdits) == "function" and type(map.ResumePassEdits) == "function"
	if pass_batch then pcall(map.SuspendPassEdits, map, "SuperBigMapStretchMarkers") end
	for _, obj in ipairs(objs) do
		if obj and is_marker(obj) then
			pcall(function()
				local pos = ObjectPosition(obj)
				if not pos then return end
				local ox, oy = PointXY(pos)
				if type(ox) ~= "number" or type(oy) ~= "number" then return end
				local np = point_fn(math.floor(ox * scale_x + 0.5), math.floor(oy * scale_y + 0.5))
				if type(np.SetTerrainZ) == "function" then
					local ok_z, pz = pcall(np.SetTerrainZ, np, map)
					if ok_z and pz then np = pz end
				end
				if type(obj.SetPos) == "function" then
					pcall(obj.SetPos, obj, np)
					moved = moved + 1
					if city and type(get_sector) == "function" and IsKindOfSafe(obj, "DepositMarker") then
						local nx2, ny2 = PointXY(np)
						if type(nx2) == "number" then
							local ok_o, old_sec = pcall(get_sector, city, ox, oy)
							local ok_n, new_sec = pcall(get_sector, city, nx2, ny2)
							if ok_o and ok_n and old_sec and new_sec and old_sec ~= new_sec then
								if type(old_sec.UnregisterDeposit) == "function" then pcall(old_sec.UnregisterDeposit, old_sec, obj) end
								if type(new_sec.RegisterDeposit) == "function" then pcall(new_sec.RegisterDeposit, new_sec, obj) end
								reregistered = reregistered + 1
							end
						end
					end
					if sample_n < 10 then
						sample_n = sample_n + 1
						local nx2, ny2 = PointXY(np)
						StretchLog("marker sample", {
							n = sample_n, class = tostring(obj.class),
							old_xy = tostring(ox) .. "," .. tostring(oy),
							new_xy = tostring(nx2) .. "," .. tostring(ny2),
						})
					end
				end
			end)
		end
	end
	if pass_batch then pcall(map.ResumePassEdits, map, "SuperBigMapStretchMarkers") end
	StretchLog("ScaleMarkersToFull: DONE", { scanned = #objs, moved = moved, reregistered = reregistered })
	DebugPrint(string.format("ScaleMarkersToFull: moved %s deposit/anomaly markers (%s re-registered to new sectors)",
		tostring(moved), tostring(reregistered)))
	return moved
end

-- STRETCH step 3b (entrance VISUALS): the Align diagnostics proved the tunnel MARKERS on both
-- maps already correspond after the stretch (both moved x1.333), but the entrances the player
-- SEES stayed at the pre-stretch positions: the decoration pass deliberately SKIPS every
-- underground-access object (ShouldSkipObject/IsUndergroundAccessObject -- a mirror-era guard
-- against cloning/deleting entrance structures), so the signs / entrance structures / spawner
-- visuals never moved (observed: surface visuals at K7+N5 = markers' H9+K7 positions / 1.333).
-- This pass applies the SAME position*(full/source) transform to those visuals -- everything
-- matching IsUndergroundAccessObject or a SpawnsOnCityInit tunnel spawner, EXCEPT the tunnel
-- markers themselves (already moved by ScaleMarkersToFull; moving twice would double-scale).
-- Runs on BOTH maps, so entrance pairs stay vertically corresponding. Every object handled is
-- logged under the "Align" scope. Gated on STRETCH_MOVE_ENTRANCE_VISUALS; once per map.
local function MoveEntranceVisualsToScale(map)
	if not cfg_bool("STRETCH_MOVE_ENTRANCE_VISUALS", true) then return 0 end
	if not map or map.SuperBigMapEntranceVisualsMoved == true then return 0 end
	local object_clone = SuperBigMap.ObjectClone
	local is_access = object_clone and object_clone.IsUndergroundAccessObject
	local point_fn = Global("point")
	if type(is_access) ~= "function" or type(point_fn) ~= "function"
		or type(map.MapForEach) ~= "function" then
		return 0
	end
	local sw_tiles = map.SuperBigMapSourceWidthTiles or map.SuperBigMapGeneratorWidthTiles
	local full_tw = map.SuperBigMapDesiredWidthTiles or (map.mapdata and map.mapdata.Width)
	if not (type(sw_tiles) == "number" and type(full_tw) == "number" and sw_tiles > 0 and full_tw > sw_tiles) then
		return 0
	end
	local const_tbl = Global("const")
	local hts = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number") and const_tbl.HeightTileSize or 1
	local scale = (full_tw + 0.0) / sw_tiles
	local src_w = sw_tiles * hts
	map.SuperBigMapEntranceVisualsMoved = true
	local DebugLog = SuperBigMap.DebugLog
	local function AlignLog(message, data)
		if DebugLog then DebugLog.Info("Align", message, data) end
	end
	local moved, seen_objs = 0, {}
	local function handle(obj, via)
		if not obj or seen_objs[obj] then return end
		seen_objs[obj] = true
		-- Tunnel markers themselves are moved by ScaleMarkersToFull -- never twice.
		if IsKindOfSafe(obj, "SurfaceUndergroundTunnelMarker") then return end
		local pos = ObjectPosition(obj)
		if not pos then return end
		local ox, oy = PointXY(pos)
		if type(ox) ~= "number" or type(oy) ~= "number" then return end
		-- Only objects still inside the SOURCE region need moving (idempotence: an already-moved
		-- or frame-placed object lies beyond it on at least one axis).
		if ox >= src_w or oy >= src_w then return end
		local np = point_fn(math.floor(ox * scale + 0.5), math.floor(oy * scale + 0.5))
		if type(np.SetTerrainZ) == "function" then
			local ok_z, pz = pcall(np.SetTerrainZ, np, map)
			if ok_z and pz then np = pz end
		end
		local ok_set = false
		if type(obj.SetPos) == "function" then
			ok_set = pcall(obj.SetPos, obj, np)
		end
		if ok_set then moved = moved + 1 end
		AlignLog("entrance visual moved", {
			via = via, class = tostring(obj.class or "?"),
			from = tostring(ox) .. "," .. tostring(oy),
			to = tostring(math.floor(ox * scale + 0.5)) .. "," .. tostring(math.floor(oy * scale + 0.5)),
			ok = ok_set,
		})
	end
	-- Sweep 1: everything the skip-list recognizes as an underground-access object.
	pcall(map.MapForEach, map, "map", "CObject", function(obj)
		local ok, matched = pcall(is_access, obj)
		if ok and matched then handle(obj, "access") end
	end)
	-- Sweep 2: the CityInit tunnel SPAWNER prefabs (they can carry the visible structure and are
	-- not underground-access-classified).
	pcall(map.MapForEach, map, "map", "SpawnsTunnelOnCityInit", function(obj)
		handle(obj, "spawner")
	end)
	StretchLog("MoveEntranceVisualsToScale: DONE", { moved = moved })
	DebugPrint(string.format("MoveEntranceVisualsToScale: moved %s entrance visuals", tostring(moved)))
	return moved
end

-- STRETCH step 5: relocate the INITIAL revealed sector(s). Vanilla picks the start sector by its
-- expected resources BEFORE the stretch moves everything x(full/source), so the scanned sector
-- (e.g. K11) no longer matches where its content went. For each scanned sector: find the sector
-- containing its SCALED center; if different, move any landed rocket in it to its scaled spot,
-- un-scan the old sector (status + persisted revealed_obj + decal) and vanilla-Scan the target
-- (spawns deposits from the re-registered marker lists, updates decal/notifications). Keeps the
-- start sector "as close as possible to the corresponding original sector" on the expanded map.
-- Must run AFTER ScaleMarkersToFull (re-registered lists) and BEFORE EnforceScanGateAfterStretch
-- (which then hides anything revealed that spilled outside the new scanned sector). Gated on
-- config STRETCH_RELOCATE_START_SECTOR.
local function StretchRelocateStartSector(map)
	StretchLog("StretchRelocateStartSector: ENTER")
	if not map or not cfg_bool("STRETCH_RELOCATE_START_SECTOR", true) then return 0 end
	local city = map.City
	local get_sector = Global("GetMapSectorXY")
	local DoneObject = Global("DoneObject")
	local IsValid = Global("IsValid")
	local point_fn = Global("point")
	if not city or type(get_sector) ~= "function" or type(point_fn) ~= "function" then
		StretchLog("StretchRelocateStartSector: city/GetMapSectorXY unavailable -- skip")
		return 0
	end
	local sw = map.SuperBigMapSourceWidthTiles or map.SuperBigMapGeneratorWidthTiles
	local full = map.SuperBigMapDesiredWidthTiles or (map.mapdata and map.mapdata.Width)
	if not (type(sw) == "number" and type(full) == "number" and sw > 0 and full > sw) then
		StretchLog("StretchRelocateStartSector: sizes unknown / no expansion -- skip")
		return 0
	end
	local scale = (full + 0.0) / sw
	-- Collect the currently scanned sectors (at this point in the load: the 1-2 initial ones).
	local scanned = {}
	if type(city.MapSectors) == "table" then
		for _, sector_col in pairs(city.MapSectors) do
			if type(sector_col) == "table" then
				for _, sec in pairs(sector_col) do
					if type(sec) == "table" and sec.status and sec.status ~= "unexplored" then
						scanned[#scanned + 1] = sec
					end
				end
			end
		end
	end
	local relocated = 0
	for _, old in ipairs(scanned) do
		pcall(function()
			if not old.area then return end
			local ctr = old.area:Center()
			local cx, cy = PointXY(ctr)
			if type(cx) ~= "number" then return end
			local ok_t, target = pcall(get_sector, city, math.floor(cx * scale + 0.5), math.floor(cy * scale + 0.5))
			if not ok_t or not target or target == old then
				StretchLog("relocate: target same/none -- sector kept", { old = tostring(old.id) })
				return
			end
			local status = old.status
			-- Move any landed rocket in the old sector to its scaled position (Z-snapped).
			local rockets_moved = 0
			if type(map.MapForEach) == "function" then
				pcall(map.MapForEach, map, old.area, "RocketBase", function(r)
					local rp = ObjectPosition(r)
					if not rp then return end
					local rx, ry = PointXY(rp)
					if type(rx) ~= "number" then return end
					local np = point_fn(math.floor(rx * scale + 0.5), math.floor(ry * scale + 0.5))
					if type(np.SetTerrainZ) == "function" then
						local ok_z, pz = pcall(np.SetTerrainZ, np, map)
						if ok_z and pz then np = pz end
					end
					if type(r.SetPos) == "function" then
						pcall(r.SetPos, r, np)
						rockets_moved = rockets_moved + 1
					end
				end)
			end
			-- Un-scan the old sector: reset live status, delete the PERSISTED reveal marker (a
			-- RevealedMapSector object that would re-apply the scan on save/load), refresh decal.
			old.status = "unexplored"
			if old.revealed_obj then
				if type(IsValid) == "function" and IsValid(old.revealed_obj) and type(DoneObject) == "function" then
					pcall(DoneObject, old.revealed_obj)
				end
				old.revealed_obj = nil
			end
			old.revealed_surf = nil
			old.revealed_deep = nil
			if type(old.UpdateDecal) == "function" then pcall(old.UpdateDecal, old) end
			-- Vanilla-scan the target with the old status (spawns deposits, decal, notifications).
			if type(target.Scan) == "function" then pcall(target.Scan, target, status) end
			-- Keep the exploration bookkeeping consistent (overview exit_to, profile fallbacks).
			if city.InitialSector == old then city.InitialSector = target end
			relocated = relocated + 1
			StretchLog("relocate: start sector moved", {
				old = tostring(old.id), new = tostring(target.id),
				status = tostring(status), rockets_moved = rockets_moved,
			})
		end)
	end
	StretchLog("StretchRelocateStartSector: DONE", { scanned = #scanned, relocated = relocated })
	DebugPrint(string.format("StretchRelocateStartSector: relocated %s scanned sector(s)", tostring(relocated)))
	return relocated
end

-- UNDERGROUND ENTRANCE ALIGNMENT (config ALIGN_UNDERGROUND_ENTRANCES): translate the WHOLE
-- underground map so the natural tunnel entrances sit directly beneath their surface
-- counterparts. Vanilla generates the two maps' tunnel spawners at unrelated coordinates, but
-- observation (56W0N) shows the underground entrance layout is the surface layout shifted by ONE
-- uniform offset (ug H9->surf K7 and ug K7->surf N5 are both exactly -3,-2 sectors). The offset
-- is NOT assumed constant across maps: it is DERIVED per map from the actual entrance sets --
-- try anchoring the first underground entrance to each surface entrance and keep the candidate
-- offset under which EVERY underground entrance has a surface entrance at ug+offset (wrapped,
-- half-sector tolerance). If no candidate matches all entrances, the map has no uniform
-- translation: log and change NOTHING. Otherwise TOROIDALLY shift the entire underground map by
-- the offset: every terrain grid (height/type/colour/biome) and every object moves by (dx,dy)
-- with wrap-around -- content pushed off one edge re-enters on the opposite side -- preserving
-- all underground spatial relationships while making every entrance pair correspond vertically.
-- Deposit markers are re-registered into their new sectors. Runs once per underground map.
local function TranslateUndergroundToMatchEntrances(map, debug)
	if not cfg_bool("ALIGN_UNDERGROUND_ENTRANCES", false) then return false end
	if not map or map.SuperBigMapUndergroundAligned == true then return false end
	local main_map = Global("MainMap")
	local box_fn = Global("box")
	local point_fn = Global("point")
	local terrain_api = Global("terrain")
	local GridToCompute = Global("GridToCompute")
	local IsComputeGrid = Global("IsComputeGrid")
	local NewComputeGrid = Global("NewComputeGrid")
	local GridRepack = Global("GridRepack")
	if not main_map or type(main_map.MapForEach) ~= "function" or type(map.MapForEach) ~= "function"
		or type(box_fn) ~= "function" or type(point_fn) ~= "function" or type(terrain_api) ~= "table"
		or type(GridToCompute) ~= "function" or type(IsComputeGrid) ~= "function"
		or type(NewComputeGrid) ~= "function" then
		StretchLog("underground align: required APIs unavailable -- skip")
		return false
	end
	local map_w = type(map.Width) == "number" and map.Width or nil
	local map_h = type(map.Height) == "number" and map.Height or map_w
	if not map_w or map_w <= 0 then
		StretchLog("underground align: map size unknown -- skip")
		return false
	end

	-- Exhaustive alignment diagnostics: scope "Align" (config DEBUG_ALIGN).
	local DebugLog = SuperBigMap.DebugLog
	local function AlignLog(message, data)
		if DebugLog then DebugLog.Info("Align", message, data) end
	end
	local function map_ident(m)
		if not m then return "nil" end
		return tostring(m.name or (m.mapdata and m.mapdata.id) or "?")
	end
	local function sector_of(m, x, y)
		local get_sector = Global("GetMapSectorXY")
		local m_city = m and m.City
		if type(get_sector) ~= "function" or not m_city then return "?" end
		local ok, sec = pcall(get_sector, m_city, x, y)
		return tostring((ok and sec) and sec.id or "nil")
	end
	-- CRITICAL sanity checks: which map objects are we actually measuring? A wrong MainMap (e.g.
	-- pointing at the underground) would make the two entrance sets nearly identical and produce
	-- a bogus ~zero offset that "matches" everything.
	AlignLog("maps", {
		main_map = map_ident(main_map), ug_map = map_ident(map),
		same_object = main_map == map,
		current_map = map_ident(Global("CurrentMap")),
		map_w = map_w, map_h = map_h,
	})

	-- 1) Collect entrance marker positions on both maps (with class -- the surface should carry
	-- UndergroundTunnelMarker, the underground SurfaceTunnelMarker; a mismatch means we measured
	-- the wrong map).
	local function collect(m, label)
		local list = {}
		pcall(m.MapForEach, m, "map", "SurfaceUndergroundTunnelMarker", function(o)
			local pos = ObjectPosition(o)
			if not pos then return end
			local x, y = PointXY(pos)
			if type(x) == "number" then
				list[#list + 1] = { x = x, y = y, class = tostring(o.class or "?") }
				AlignLog("entrance", {
					side = label, n = #list, class = tostring(o.class or "?"),
					xy = tostring(x) .. "," .. tostring(y),
					sector = sector_of(m, x, y),
				})
			end
		end)
		return list
	end
	local surf, ug = collect(main_map, "surface"), collect(map, "underground")
	StretchLog("underground align: entrances collected", { surf = #surf, ug = #ug })
	if #surf == 0 or #ug == 0 then
		map.SuperBigMapUndergroundAligned = true
		return false
	end

	-- 2) Derive the per-map uniform offset (see header). Wrapped, half-sector tolerance.
	local TOL = 20480
	local function wrap_delta(a, b, size) -- shortest wrapped delta from a to b
		local d = (b - a) % size
		if d > size / 2 then d = d - size end
		return d
	end
	-- Full pairwise delta matrix (wu and sectors) -- shows the true pairing at a glance.
	for i, u in ipairs(ug) do
		for j, s in ipairs(surf) do
			local ddx = wrap_delta(u.x, s.x, map_w)
			local ddy = wrap_delta(u.y, s.y, map_h)
			AlignLog("delta ug->surf", {
				ug = i, surf = j, dx = ddx, dy = ddy,
				sectors = string.format("%.2f,%.2f", (ddx + 0.0) / 40960, (ddy + 0.0) / 40960),
			})
		end
	end
	-- Candidate evaluation with DISTINCT matching: each underground entrance must match a
	-- DIFFERENT surface entrance (injective) -- without this, near-coincident sets let one surface
	-- entrance satisfy several underground ones and a bogus offset can claim a full match.
	local best_offset, best_matches, best_err
	for cand_j, s in ipairs(surf) do
		local dx = wrap_delta(ug[1].x, s.x, map_w)
		local dy = wrap_delta(ug[1].y, s.y, map_h)
		local matches, total_err = 0, 0
		local used_surf = {}
		for ui, u in ipairs(ug) do
			local best_j, best_e
			for j, s2 in ipairs(surf) do
				if not used_surf[j] then
					local ex = math.abs(wrap_delta((u.x + dx) % map_w, s2.x, map_w))
					local ey = math.abs(wrap_delta((u.y + dy) % map_h, s2.y, map_h))
					local e = ex + ey
					if ex <= TOL and ey <= TOL and (not best_e or e < best_e) then
						best_j, best_e = j, e
					end
				end
			end
			AlignLog("candidate pair", {
				candidate = cand_j, ug = ui,
				matched_surf = tostring(best_j or "none"),
				residual_wu = tostring(best_e or "-"),
			})
			if best_j then
				used_surf[best_j] = true
				matches = matches + 1
				total_err = total_err + best_e
			end
		end
		StretchLog("underground align: candidate offset", {
			dx = dx, dy = dy, matches = matches, of = #ug, total_err = total_err,
		})
		-- Prefer more matches; tie-break on smaller total residual.
		if not best_matches or matches > best_matches
			or (matches == best_matches and total_err < (best_err or math.huge)) then
			best_matches, best_offset, best_err = matches, { dx = dx, dy = dy }, total_err
		end
	end
	if not best_offset or best_matches < #ug then
		StretchLog("underground align: NO uniform offset matches all entrances -- map left unchanged", {
			best_matches = tostring(best_matches), needed = #ug,
		})
		map.SuperBigMapUndergroundAligned = true
		return false
	end
	local dx, dy = best_offset.dx, best_offset.dy
	StretchLog("underground align: offset chosen", {
		dx = dx, dy = dy, matches = best_matches, total_err = best_err,
		sectors = string.format("%.2f,%.2f", (dx + 0.0) / 40960, (dy + 0.0) / 40960),
	})
	map.SuperBigMapUndergroundAligned = true
	if dx == 0 and dy == 0 then
		return true
	end

	-- 3) Toroidal grid shift: copy into a fresh compute grid as 4 wrapped blocks.
	local function wrap_translate_compute(cg, w, h, dxc, dyc)
		local fmt, bits = IsComputeGrid(cg)
		if not fmt then return nil end
		local dst = NewComputeGrid(w, h, fmt, bits)
		dxc = dxc % w
		dyc = dyc % h
		local function blk(sx1, sy1, sx2, sy2, tx, ty)
			if sx2 > sx1 and sy2 > sy1 then
				dst:copyrect(cg, box_fn(sx1, sy1, sx2, sy2), point_fn(tx, ty))
			end
		end
		blk(0, 0, w - dxc, h - dyc, dxc, dyc)
		blk(w - dxc, 0, w, h - dyc, 0, dyc)
		blk(0, h - dyc, w - dxc, h, dxc, 0)
		blk(w - dxc, h - dyc, w, h, 0, 0)
		return dst
	end
	local function free_grid(x)
		if x and (type(x) == "table" or type(x) == "userdata") then
			pcall(function() if type(x.free) == "function" then x:free() end end)
		end
	end

	-- Height + type via the terrain API (native grids -> compute, same as the stretch).
	local function shift_terrain_grid(label, get_fn, set_fn, invalidate_fn)
		local ok, err = pcall(function()
			local src = get_fn(map)
			if not src then return end
			local cg = GridToCompute(src)
			local w, h = cg:size()
			local dxc = math.floor((dx % map_w) * w / map_w + 0.5)
			local dyc = math.floor((dy % map_h) * h / map_h + 0.5)
			local dst = wrap_translate_compute(cg, w, h, dxc, dyc)
			if dst then
				set_fn(map, dst)
				if type(invalidate_fn) == "function" then pcall(invalidate_fn, map) end
				free_grid(dst)
			end
			if cg ~= src then free_grid(cg) end
			free_grid(src)
		end)
		StretchLog("underground align: grid shifted", { grid = label, ok = ok, err = ok and nil or tostring(err) })
	end
	shift_terrain_grid("height", terrain_api.GetHeightGrid, terrain_api.SetHeightGrid, terrain_api.InvalidateHeight)
	shift_terrain_grid("type", terrain_api.GetTypeGrid, terrain_api.SetTypeGrid, terrain_api.InvalidateType)

	-- Editor MapGrids (colour/biome); absent grids are skipped by the pcall guards.
	local editor_api = Global("editor")
	if type(editor_api) == "table" and type(editor_api.GetGrid) == "function" and type(editor_api.SetGrid) == "function" then
		local full_box = box_fn(0, 0, map_w, map_h)
		for _, name in ipairs({ "colorize", "BiomeGrid" }) do
			local ok, err = pcall(function()
				local ok_g, src = pcall(editor_api.GetGrid, map, name, full_box)
				if not ok_g or not src then return end
				local cg = GridToCompute(src)
				local w, h = cg:size()
				local dxc = math.floor((dx % map_w) * w / map_w + 0.5)
				local dyc = math.floor((dy % map_h) * h / map_h + 0.5)
				local dst = wrap_translate_compute(cg, w, h, dxc, dyc)
				if dst then
					local out = dst
					if type(GridRepack) == "function" then
						local fmt, bits = IsComputeGrid(src)
						if fmt then out = GridRepack(dst, fmt, bits) end
					end
					pcall(editor_api.SetGrid, map, name, out, full_box)
					if out ~= dst then free_grid(out) end
					free_grid(dst)
				end
				if cg ~= src then free_grid(cg) end
				free_grid(src)
			end)
			StretchLog("underground align: mapgrid shifted", { grid = name, ok = ok, err = ok and nil or tostring(err) })
		end
	end

	-- 4) Move EVERY object by the wrapped offset (Z-snapped), batching passability edits.
	-- UI/bookkeeping objects (sector decals, holders, overview decals) stay put.
	local skip_classes = {
		City = true, MapSector = true, RandomMapGeneratorHolder = true, RevealedMapSector = true,
		SectorUnexplored = true, SectorScanned = true, SectorTarget = true, SectorRadius = true,
	}
	local city = map.City
	local get_sector = Global("GetMapSectorXY")
	local objs = {}
	pcall(map.MapForEach, map, "map", "CObject", function(o) objs[#objs + 1] = o end)
	local moved, reregistered = 0, 0
	local pass_batch = type(map.SuspendPassEdits) == "function" and type(map.ResumePassEdits) == "function"
	if pass_batch then pcall(map.SuspendPassEdits, map, "SuperBigMapUndergroundAlign") end
	for _, obj in ipairs(objs) do
		if obj and not skip_classes[obj.class or false] then
			pcall(function()
				local pos = ObjectPosition(obj)
				if not pos then return end
				local ox, oy = PointXY(pos)
				if type(ox) ~= "number" or type(oy) ~= "number" then return end
				local nx = (ox + dx) % map_w
				local ny = (oy + dy) % map_h
				local np = point_fn(math.floor(nx), math.floor(ny))
				if type(np.SetTerrainZ) == "function" then
					local ok_z, pz = pcall(np.SetTerrainZ, np, map)
					if ok_z and pz then np = pz end
				end
				if type(obj.SetPos) == "function" then
					pcall(obj.SetPos, obj, np)
					moved = moved + 1
					if city and type(get_sector) == "function" and IsKindOfSafe(obj, "DepositMarker") then
						local ok_o, old_sec = pcall(get_sector, city, ox, oy)
						local ok_n, new_sec = pcall(get_sector, city, nx, ny)
						if ok_o and ok_n and old_sec and new_sec and old_sec ~= new_sec then
							if type(old_sec.UnregisterDeposit) == "function" then pcall(old_sec.UnregisterDeposit, old_sec, obj) end
							if type(new_sec.RegisterDeposit) == "function" then pcall(new_sec.RegisterDeposit, new_sec, obj) end
							reregistered = reregistered + 1
						end
					end
				end
			end)
		end
	end
	if pass_batch then pcall(map.ResumePassEdits, map, "SuperBigMapUndergroundAlign") end

	-- 5) Rebuild derived state over the shifted map.
	ReinvalidateExpandedTerrain(map)
	local rebuild_buildable = Global("RebuildBuildableGrid")
	if type(rebuild_buildable) == "function" and map.buildable then
		SafeCall(rebuild_buildable, map)
	end
	StretchLog("underground align: DONE", { dx = dx, dy = dy, moved = moved, reregistered = reregistered })
	DebugPrint(string.format("underground aligned to surface entrances: shifted by %s,%s wu (%s objects)",
		tostring(dx), tostring(dy), tostring(moved)))
	return true
end

-- After a sector's terrain is copied into to_box, any object that was ALREADY
-- sitting in that destination region (e.g. a mystery "pile of stone" / anomaly a
-- story event dropped into the frame) is now floating above or buried under the
-- freshly-copied surface, because its Z was set against the OLD terrain height.
-- Force each such object back onto the new surface (snap Z), and if it now shares
-- its spot with another non-interacting object, nudge it to the nearest clear
-- destlockable point so the two do not intersect.
--
-- clone_set holds the objects this copy just placed (the faithful source replica):
-- those are already at the correct Z and must NOT be moved, so they are excluded
-- from the re-snap (but DO count as "occupying" when de-overlapping a foreign
-- object, so we don't drop a pile on top of a copied rock).
local function ResnapForeignObjects(map, to_box, clone_set)
	if not cfg_bool("RESNAP_FRAME_OBJECTS", true) then
		return 0, 0, "disabled"
	end
	if type(map) ~= "table" or type(map.MapForEach) ~= "function" then
		return 0, 0, "no map iterator"
	end
	local guim_wu = Global("guim")
	if type(guim_wu) ~= "number" or guim_wu <= 0 then
		guim_wu = 1000 -- HG default: 1 metre = 1000 world units
	end

	-- Classes we must never reposition: live units (own their Z/pathing), the
	-- map's structural singletons, and in-progress player construction. NOTE we do
	-- NOT skip Building here -- some mystery props (e.g. Black Cube structures) are
	-- building-class objects and ARE what we want re-snapped onto the new ground.
	local function resnap_skip(obj)
		if clone_set[obj] then return true end
		if IsKindOfSafe(obj, "Unit") then return true end
		if IsKindOfSafe(obj, "ConstructionSite") then return true end
		if IsKindOfSafe(obj, "RandomMapGeneratorHolder") then return true end
		if IsKindOfSafe(obj, "MapSector") or IsKindOfSafe(obj, "City") then return true end
		if type(obj.GetParent) == "function" then
			local ok, parent = pcall(obj.GetParent, obj)
			if ok and parent ~= nil then return true end -- attached: follows its host
		end
		return false
	end

	local resnapped, moved = 0, 0
	pcall(map.MapForEach, map, to_box, "CObject", function(obj)
		if not obj or resnap_skip(obj) then
			return
		end
		local pos = ObjectPosition(obj)
		if not pos then return end

		-- 1) Snap Z to the freshly-copied surface. SetTerrainZ reads the height grid
		-- (already pushed by editor.SetGrid), so this is the NEW height even before
		-- the deferred RebuildGrids.
		local snapped = pos
		if type(pos.SetTerrainZ) == "function" then
			local ok, p = pcall(pos.SetTerrainZ, pos, map)
			if ok and p then snapped = p end
		end

		-- 2) De-overlap. Is another non-interacting object sitting in the same spot?
		-- Query a small radius (the object's own radius, or ~1 m) around the snapped
		-- point. Decals are flat ground paint and never block; self and children are
		-- ignored. Clones we just placed DO count, so a pile won't be left inside a
		-- copied rock.
		local dest = snapped
		if type(map.MapGetFirst) == "function" then
			local radius = guim_wu
			if type(obj.GetRadius) == "function" then
				local ok_r, orad = pcall(obj.GetRadius, obj)
				if ok_r and type(orad) == "number" and orad > 0 then radius = orad end
			end
			local occupied = map:MapGetFirst(snapped, radius, "CObject", function(other)
				if other == obj then return false end
				if IsKindOfSafe(other, "Decal") then return false end
				if type(other.GetParent) == "function" then
					local ok, par = pcall(other.GetParent, other)
					if ok and par == obj then return false end
				end
				return true
			end)
			if occupied ~= nil and type(obj.GetDestlockablePointNearby) == "function" then
				-- Find the nearest clear point (not reserved by another object). Use
				-- the OBJECT-reference overload, GetDestlockablePointNearby(obj, radius,
				-- checkPassability): the engine requires a luaGameObject here (the
				-- (map, point, ...) global form asserts "Expected luaGameObject"). The
				-- object hasn't been moved yet, so its 2D position == snapped's.
				local ok, free = pcall(obj.GetDestlockablePointNearby, obj, 10 * guim_wu, false)
				if ok and free then
					if type(free.SetTerrainZ) == "function" then
						local ok2, fz = pcall(free.SetTerrainZ, free, map)
						if ok2 and fz then free = fz end
					end
					dest = free
					moved = moved + 1
				end
			end
		end

		if type(obj.SetPos) == "function" then
			pcall(obj.SetPos, obj, dest)
			resnapped = resnapped + 1
		end
	end)

	return resnapped, moved
end

-- Delete an object via the engine's DoneObject (falls back to obj:delete()).
local function DestroyObject(obj)
	if not obj then return end
	local done_object = Global("DoneObject")
	if type(done_object) == "function" and pcall(done_object, obj) then
		return
	end
	if type(obj.delete) == "function" then pcall(obj.delete, obj) end
end


-- Bounding box (world) of the block whose two OPPOSITE corner sectors are named.
-- Returns x1,y1,x2,y2 spanning all sectors between (and including) the corners.
local function BlockBox(map, a_name, b_name)
	local a = FindSectorByName(map, a_name)
	local b = FindSectorByName(map, b_name)
	if not a or not b then return nil end
	local ax1, ay1, ax2, ay2 = SectorWorldRect(a.area)
	local bx1, by1, bx2, by2 = SectorWorldRect(b.area)
	if not ax1 or not bx1 then return nil end
	return math.min(ax1, bx1), math.min(ay1, by1), math.max(ax2, bx2), math.max(ay2, by2)
end

-- Collect objects in a world box into a Lua list (so we can iterate with yields,
-- which is not possible inside a MapForEach C-callback).
local function CollectObjectsInBox(map, box)
	local list = {}
	if type(map.MapForEach) == "function" then
		pcall(map.MapForEach, map, box, "CObject", function(o)
			list[#list + 1] = o
		end)
	end
	return list
end

-- Copy a whole BLOCK of sectors in ONE shot, optionally mirrored on each axis.
-- This is the fast path used by the L-frame fill: each group is a single
-- reflection across a seam line, so the per-sector internal mirrors are
-- equivalent to one block-level flip (verified: reflecting cols F:J across the
-- E/F edge lands exactly on cols A:E with the same internal reversal). Grids are
-- flipped once per grid for the whole block (~5 GetGrid/SetGrid instead of one per
-- sector); objects are deleted (dest) + cloned (source) in one pass each, yielding
-- every YIELD_EVERY objects so the game stays responsive. defer_refresh skips the
-- per-block refresh for the batch caller.
local YIELD_EVERY = 64
-- phase: "terrain" (grids only), "objects" (delete/clone/resnap only), or "both"
-- (default). The L-frame plan runs "terrain" for all blocks first (so the mirrored
-- ground renders immediately), then "objects" for all blocks (the slow part).
local function CopySectorBlock(map, src_a, src_b, dst_a, dst_b, mirror_x, mirror_y, defer_refresh, label, phase)
	map = map or Global("CurrentMap")
	local terrain_api = Global("terrain")
	local box_fn = Global("box")
	local point_fn = Global("point")
	if type(terrain_api) ~= "table" or type(box_fn) ~= "function" or type(point_fn) ~= "function" then
		return false, "api unavailable"
	end
	local sx1, sy1, sx2, sy2 = BlockBox(map, src_a, src_b)
	local dx1, dy1 = BlockBox(map, dst_a, dst_b)
	if not sx1 or not dx1 then
		DebugPrint(string.format("CopySectorBlock %s: corners not found", tostring(label)))
		return false, "corners not found"
	end
	local map_w, map_h = TerrainSize(map)
	if type(map_w) ~= "number" or map_w <= 0 or type(map_h) ~= "number" or map_h <= 0 then
		return false, "bad map size"
	end
	-- dest box = source size at the dest origin (exact-size copy)
	local dx2 = dx1 + (sx2 - sx1)
	local dy2 = dy1 + (sy2 - sy1)
	-- bounds guard: never read/write outside the terrain grid (OOB SetGrid corrupts
	-- the heap). The 20x20 gate also checks this, but guard here too.
	if sx1 < 0 or sy1 < 0 or sx2 > map_w or sy2 > map_h
		or dx1 < 0 or dy1 < 0 or dx2 > map_w or dy2 > map_h then
		DebugPrint(string.format("CopySectorBlock %s SKIPPED: outside terrain bounds", tostring(label)))
		return false, "outside terrain bounds"
	end
	local debug = cfg_bool("DEBUG_GENERATION", false)
	local src_box = box_fn(sx1, sy1, sx2, sy2)
	local dst_box = box_fn(dx1, dy1, dx2, dy2)
	phase = phase or "both"
	local do_terrain = phase ~= "objects"
	local do_objects = phase ~= "terrain"
	-- Pre-declared so the summary log reads correctly regardless of phase.
	local deleted, cloned, skipped_nth, skipped_edge, resnapped, moved = 0, 0, 0, 0, 0, 0

	-- TERRAIN: ONE flip+copy of the whole block per grid.
	if do_terrain then
		local editor_api = Global("editor")
		local grid_names = (type(editor_api) == "table" and type(editor_api.GetGridNames) == "function")
			and SafeCall(editor_api.GetGridNames) or nil
		if type(grid_names) ~= "table" or #grid_names == 0 then
			grid_names = { "height", "terrain_type", "colorize", "BiomeGrid", "clutter_density", "grass_density", "impassability", "passability" }
		end
		for _, name in ipairs(grid_names) do
			CopyEditorGrid(map, name, src_box, dst_box, debug, mirror_x, mirror_y)
		end
	end

	-- OBJECTS: delete the dest block's scatter, clone the source block's scatter
	-- (reflected within the block; resources/anomalies always cloned, decor thinned
	-- by skip-Nth and edge-skip), then re-snap survivors onto the new surface.
	if do_objects then
		local sleep = Global("Sleep")

		local dst_objs = CollectObjectsInBox(map, dst_box)
		for i = 1, #dst_objs do
			local obj = dst_objs[i]
			if obj and not ShouldSkipObject(obj)
				and obj.SuperBigMapFakeTerrain ~= true and obj.fake_terrain ~= true then
				DestroyObject(obj)
				deleted = deleted + 1
			end
			if type(sleep) == "function" and i % YIELD_EVERY == 0 then sleep(1) end
		end

		local skip_n = math.floor(cfg_number("MIRROR_DECOR_SKIP_EVERY_NTH", 0))
		if skip_n < 1 then skip_n = 0 end -- 0 = clone all; 1 = skip ALL decor; 2 = every 2nd; ...
		local edge_skip = cfg_bool("MIRROR_SKIP_EDGE_TOUCHING_DECOR", true)
		local decor_seen = 0

		local clone_set = {}
		local src_objs = CollectObjectsInBox(map, src_box)
		for i = 1, #src_objs do
			local obj = src_objs[i]
			if obj and not ShouldSkipObject(obj)
				and obj.SuperBigMapFakeTerrain ~= true and obj.fake_terrain ~= true then
				local thin = false
				if not IsImportantSectorObject(obj) then
					if skip_n > 0 then
						decor_seen = decor_seen + 1
						if decor_seen % skip_n == 0 then
							thin = true
							skipped_nth = skipped_nth + 1
						end
					end
					if not thin and edge_skip and not ObjectInsideBox(obj, sx1, sy1, sx2, sy2) then
						thin = true
						skipped_edge = skipped_edge + 1
					end
				end
				if not thin then
					local pos = ObjectPosition(obj)
					if pos then
						local ox, oy = PointXY(pos)
						if type(ox) == "number" and type(oy) == "number" then
							local lx = mirror_x and (sx2 - ox) or (ox - sx1)
							local ly = mirror_y and (sy2 - oy) or (oy - sy1)
							local obj_offset = point_fn(math.floor(dx1 + lx - ox), math.floor(dy1 + ly - oy), 0)
							local clone = CloneObjectAtOffset(map, obj, obj_offset)
							if clone then
								cloned = cloned + 1
								clone_set[clone] = true
								ApplyMirrorOrientation(obj, clone, mirror_x, mirror_y)
							end
						end
					end
				end
			end
			if type(sleep) == "function" and i % YIELD_EVERY == 0 then sleep(1) end
		end

		resnapped, moved = ResnapForeignObjects(map, dst_box, clone_set)
	end

	-- 5) Refresh (unless the batch caller does one combined refresh).
	if not defer_refresh then
		if type(terrain_api.InvalidateHeight) == "function" then SafeCall(terrain_api.InvalidateHeight, map, dst_box) end
		if type(terrain_api.InvalidateType) == "function" then SafeCall(terrain_api.InvalidateType, map, dst_box) end
		if type(terrain_api.RebuildPassability) == "function" then SafeCall(terrain_api.RebuildPassability, map, dst_box) end
		if type(map.RebuildGrids) == "function" then SafeCall(map.RebuildGrids, map, dst_box) end
		if type(terrain_api.HashGrids) == "function" then SafeCall(terrain_api.HashGrids, map) end
	end

	DebugPrint(string.format(
		"CopySectorBlock %s%s [%s]: src=[%s,%s..%s,%s] dst=[%s,%s..%s,%s] deleted=%s cloned=%s skipped(nth=%s edge=%s) resnapped=%s moved=%s",
		tostring(label), (mirror_x and mirror_y) and " (XY)" or mirror_x and " (X)" or mirror_y and " (Y)" or "",
		tostring(phase),
		tostring(sx1), tostring(sy1), tostring(sx2), tostring(sy2),
		tostring(dx1), tostring(dy1), tostring(dx2), tostring(dy2),
		tostring(deleted), tostring(cloned), tostring(skipped_nth), tostring(skipped_edge),
		tostring(resnapped), tostring(moved)))
	return true, dx1, dy1, dx2, dy2
end

-- The three L-frame fill blocks (corner sectors define each block's extent). Each
-- is a single reflection across a seam line:
--   left   : cols F:J rows 0:14  -> cols A:E rows 0:14  (mirror X)
--   top    : cols F:T rows 10:14 -> cols F:T rows 15:19 (mirror Y)
--   corner : cols F:J rows 10:14 -> cols A:E rows 15:19 (mirror X+Y, 180 deg)
local SECTOR_MIRROR_BLOCKS = {
	{ label = "left",   src_a = "F0",  src_b = "J14", dst_a = "E0",  dst_b = "A14", mx = true,  my = false },
	{ label = "top",    src_a = "F10", src_b = "T14", dst_a = "F15", dst_b = "T19", mx = false, my = true },
	{ label = "corner", src_a = "F10", src_b = "J14", dst_a = "E15", dst_b = "A19", mx = true,  my = true },
}

-- Diagnostic: report, by NAME, whether each L-frame block-corner sector currently
-- exists on the map (via the live MapSectors name lookup). A full 20x20 grid has all
-- of them; "MISSING" entries are exactly why SectorMirrorBlocksFit / WarnCannotExpand
-- fire, and reveal whether the frame sectors vanished after the grid was built.
local function FrameSectorProbe(map)
	local seen, names = {}, {}
	for _, b in ipairs(SECTOR_MIRROR_BLOCKS) do
		for _, nm in ipairs({ b.src_a, b.src_b, b.dst_a, b.dst_b }) do
			if not seen[nm] then
				seen[nm] = true
				names[#names + 1] = nm
			end
		end
	end
	local parts = {}
	for _, nm in ipairs(names) do
		parts[#parts + 1] = nm .. "=" .. (FindSectorByName(map, nm) and "ok" or "MISSING")
	end
	return table.concat(parts, " ")
end

-- Verify the map expanded to a usable 20x20 grid: every block's source AND dest
-- corner sectors exist and the block boxes lie inside the terrain. If not, the
-- grid is too small (e.g. the ~13-sector 6144->8192 map) -> skip the whole fill.
local function SectorMirrorBlocksFit(map, map_w, map_h)
	for _, b in ipairs(SECTOR_MIRROR_BLOCKS) do
		local sx1, sy1, sx2, sy2 = BlockBox(map, b.src_a, b.src_b)
		local dx1, dy1 = BlockBox(map, b.dst_a, b.dst_b)
		InitSeq("SectorMirrorBlocksFit: block", {
			label = tostring(b.label),
			src = b.src_a .. ".." .. b.src_b,
			dst = b.dst_a .. ".." .. b.dst_b,
			src_corner_found = sx1 ~= nil,
			dst_corner_found = dx1 ~= nil,
			src_box = sx1 and (tostring(sx1) .. "," .. tostring(sy1) .. ".." .. tostring(sx2) .. "," .. tostring(sy2)) or "nil",
		})
		if not sx1 or not dx1 then
			return false, string.format("block %s corners missing", tostring(b.label))
		end
		local dx2 = dx1 + (sx2 - sx1)
		local dy2 = dy1 + (sy2 - sy1)
		if sx1 < 0 or sy1 < 0 or sx2 > map_w or sy2 > map_h
			or dx1 < 0 or dy1 < 0 or dx2 > map_w or dy2 > map_h then
			return false, string.format("block %s outside terrain (terrain=%sx%s)",
				tostring(b.label), tostring(map_w), tostring(map_h))
		end
	end
	return true
end

-- Warn (log always; modal popup if WARN_ON_CANNOT_EXPAND) that this map cannot be
-- expanded because it did not generate as a full 20x20 sector grid. Once per map.
local function WarnCannotExpand(map, reason)
	local detail = string.format(
		"This map cannot be properly expanded.\n\n" ..
		"It did not generate as a full 20x20 sector grid, so the Super Big Map frame " ..
		"mirroring was skipped (%s).\n\n" ..
		"Start a new game and pick a different map to get the expanded frame.",
		tostring(reason))
	print("[Super Big Map] CANNOT EXPAND MAP: " .. tostring(reason)
		.. " -- frame mirroring skipped (map is not a full 20x20 sector grid)")
	-- Full live-grid dump at the instant the warning fires: this is the key evidence
	-- for the "built 20x20, then frame sectors vanish + not-20x20 warning" bug.
	do
		local mw, mh = TerrainSize(map)
		local grid = SuperBigMap.SectorGrid
		local const_tbl = Global("const")
		InitSeq("WarnCannotExpand: live grid state at warning", {
			reason = tostring(reason),
			terrain = tostring(mw) .. "x" .. tostring(mh),
			const_SectorCount = const_tbl and tostring(const_tbl.SectorCount) or "?",
			describe = (grid and type(grid.DescribeMap) == "function") and grid.DescribeMap(map) or "?",
			frame_sectors = FrameSectorProbe(map),
		})
	end
	if not cfg_bool("WARN_ON_CANNOT_EXPAND", true) then
		return
	end
	if map and map.SuperBigMapCannotExpandWarned == true then
		return
	end
	if map then map.SuperBigMapCannotExpandWarned = true end
	-- Show the warning in place of the new-game "Welcome to Mars, Commander!" popup:
	-- hide the welcome popup while ours is up, restore it when OK is pressed. Falls
	-- back to a plain message box if the shared helper is unavailable.
	if type(SuperBigMap.ShowMessageOverWelcome) == "function" then
		SuperBigMap.ShowMessageOverWelcome("Super Big Map", detail)
	else
		local create_box = Global("CreateMessageBox")
		if type(create_box) == "function" then
			pcall(create_box, nil, "Super Big Map", detail)
		else
			DebugPrint("WarnCannotExpand: CreateMessageBox unavailable -- logged only")
		end
	end
end

-- Force the expanded L-frame region PASSABLE (editor.SetPassableBox + RebuildPassability),
-- regardless of the copied terrain's slope. Ported from the original working fix (commit
-- 9e940f8): a rover unloaded from a rocket that lands in the frame is otherwise trapped
-- where the copied (e.g. cliff) terrain reads impassable. PassBorder=0 removes the baked
-- edge ring; this removes the slope-based impassability INSIDE the frame. The frame is the
-- L beyond the corner-anchored source: right strip [source_w, map_w] x full height, plus
-- bottom strip x[0, source_w] x y[source_h, map_h], with an optional seam bridge into the
-- source. Mod maps only; gated on FORCE_FRAME_PASSABLE.
local function ForceFramePassable(map)
	if not cfg_bool("FORCE_FRAME_PASSABLE", true) then
		return false, "disabled"
	end
	map = map or Global("CurrentMap")
	local grid = SuperBigMap.SectorGrid
	if not (grid and type(grid.IsModMap) == "function" and grid.IsModMap(map)) then
		return false, "not a mod map"
	end
	local terrain_api = Global("terrain")
	local box_fn = Global("box")
	local editor_api = Global("editor")
	local has_set_passable = type(editor_api) == "table" and type(editor_api.SetPassableBox) == "function"
	if type(terrain_api) ~= "table" or type(box_fn) ~= "function" or not has_set_passable then
		DebugPrint("ForceFramePassable skipped: editor.SetPassableBox / terrain API unavailable")
		return false, "api unavailable"
	end

	local map_width, map_height = TerrainSize(map)
	local source_width = map and map.SuperBigMapSourceWidth
	local source_height = map and map.SuperBigMapSourceHeight
	if type(map_width) ~= "number" or type(source_width) ~= "number" or type(source_height) ~= "number" then
		return false, "no source extent"
	end
	if map_width <= source_width and map_height <= source_height then
		return false, "no frame"
	end

	local const_tbl = Global("const") or {}
	local pass_tile = (type(const_tbl.PassTileSize) == "number" and const_tbl.PassTileSize > 0)
		and const_tbl.PassTileSize or 0
	local bridge = pass_tile * cfg_number("FRAME_PASSABLE_BRIDGE_TILES", 2, 0)
	local inner_x = math.max(0, source_width - bridge)
	local inner_y = math.max(0, source_height - bridge)
	local boxes = {
		box_fn(inner_x, 0, map_width, map_height),
		box_fn(0, inner_y, inner_x, map_height),
	}

	local reason = "SuperBigMapFramePassable"
	local net_pause = Global("NetPauseUpdateHash")
	local net_resume = Global("NetResumeUpdateHash")
	local has_set_impassable = type(editor_api.SetImpassableBox) == "function"
	local has_rebuild = type(terrain_api.RebuildPassability) == "function"

	if type(net_pause) == "function" then SafeCall(net_pause, reason) end
	if type(map.SuspendPassEdits) == "function" then SafeCall(map.SuspendPassEdits, map, reason) end

	local ok_set = pcall(function()
		for i = 1, #boxes do
			-- Clear any forced-IMpassable flag first, then force passable.
			if has_set_impassable then editor_api.SetImpassableBox(boxes[i], false) end
			editor_api.SetPassableBox(boxes[i], true)
		end
	end)
	local ok_rebuild = true
	if has_rebuild then
		ok_rebuild = pcall(function()
			for i = 1, #boxes do terrain_api.RebuildPassability(map, boxes[i]) end
		end)
	end

	-- Balanced cleanup -- ALWAYS runs, even if the apply above errored.
	if type(map.ResumePassEdits) == "function" then SafeCall(map.ResumePassEdits, map, reason) end
	if type(net_resume) == "function" then SafeCall(net_resume, reason) end

	if ok_set and ok_rebuild then
		map.SuperBigMapFramePassable = true
	end
	DebugPrint(string.format(
		"ForceFramePassable: source=%sx%s map=%sx%s bridge=%s set_impassable=%s rebuild=%s ok_set=%s ok_rebuild=%s",
		tostring(source_width), tostring(source_height), tostring(map_width), tostring(map_height),
		tostring(bridge), tostring(has_set_impassable), tostring(has_rebuild),
		tostring(ok_set), tostring(ok_rebuild)))
	return ok_set and ok_rebuild
end

-- SAFETY SWEEP: an underground entrance (tunnel / passage access) must never appear in the
-- cloned L-frame. The per-block dest-clear deletes generator scatter with `not ShouldSkipObject`,
-- but ShouldSkipObject returns TRUE for underground-access objects (to protect the real entrance
-- from being cloned), so a generator-placed entrance that happened to land OUTSIDE the source
-- quadrant is shielded from that deletion and survives in the frame. After the clone completes,
-- delete any underground-access object whose center lies in the frame (the L beyond the corner-
-- anchored source). The genuine entrance in the source quadrant is never inside these boxes, so
-- it is left untouched. Mod maps only; gated on REMOVE_FRAME_UNDERGROUND_ACCESS; reversible.
local function RemoveFrameUndergroundAccess(map)
	if not cfg_bool("REMOVE_FRAME_UNDERGROUND_ACCESS", true) then
		return false, "disabled"
	end
	map = map or Global("CurrentMap")
	local box_fn = Global("box")
	if not map or type(box_fn) ~= "function" or type(map.MapForEach) ~= "function" then
		return false, "api unavailable"
	end
	local map_width, map_height = TerrainSize(map)
	local source_width = map and map.SuperBigMapSourceWidth
	local source_height = map and map.SuperBigMapSourceHeight
	if type(map_width) ~= "number" or type(source_width) ~= "number" or type(source_height) ~= "number" then
		return false, "no source extent"
	end
	if map_width <= source_width and map_height <= source_height then
		return false, "no frame"
	end
	-- The frame is the L beyond the corner-anchored source: right strip (full height) plus the
	-- bottom strip under the source. The two boxes do not overlap and exclude the source quadrant.
	local boxes = {
		box_fn(source_width, 0, map_width, map_height),
		box_fn(0, source_height, source_width, map_height),
	}
	local removed = 0
	for i = 1, #boxes do
		local objs = CollectObjectsInBox(map, boxes[i])
		for j = 1, #objs do
			local obj = objs[j]
			if obj and IsUndergroundAccessObject(obj) then
				VerbosePrint(string.format(
					"RemoveFrameUndergroundAccess: deleting frame entrance class=%s", tostring(obj.class)))
				DestroyObject(obj)
				removed = removed + 1
			end
		end
	end
	DebugPrint(string.format(
		"RemoveFrameUndergroundAccess: source=%sx%s map=%sx%s removed=%s",
		tostring(source_width), tostring(source_height),
		tostring(map_width), tostring(map_height), tostring(removed)))
	return true, removed
end

-- Public API: terrain/grid copy + mirror-block mechanics consumed by sbm_map_generation.
local TerrainCopy = {
	ReinvalidateExpandedTerrain = ReinvalidateExpandedTerrain,
	SectorWorldRect = SectorWorldRect,
	FindSectorByName = FindSectorByName,
	SectorBoundary = SectorBoundary,
	CopyGridRect = CopyGridRect,
	CopyEditorGrid = CopyEditorGrid,
	StretchSourceToFull = StretchSourceToFull,
	StretchBiomeReady = StretchBiomeReady,
	ScaleDecorationsToFull = ScaleDecorationsToFull,
	ScaleMarkersToFull = ScaleMarkersToFull,
	StretchRelocateStartSector = StretchRelocateStartSector,
	TranslateUndergroundToMatchEntrances = TranslateUndergroundToMatchEntrances,
	MoveEntranceVisualsToScale = MoveEntranceVisualsToScale,
	ResnapForeignObjects = ResnapForeignObjects,
	DestroyObject = DestroyObject,
	BlockBox = BlockBox,
	CollectObjectsInBox = CollectObjectsInBox,
	CopySectorBlock = CopySectorBlock,
	SECTOR_MIRROR_BLOCKS = SECTOR_MIRROR_BLOCKS,
	FrameSectorProbe = FrameSectorProbe,
	SectorMirrorBlocksFit = SectorMirrorBlocksFit,
	WarnCannotExpand = WarnCannotExpand,
	ForceFramePassable = ForceFramePassable,
	RemoveFrameUndergroundAccess = RemoveFrameUndergroundAccess,
}
SuperBigMap.TerrainCopy = TerrainCopy

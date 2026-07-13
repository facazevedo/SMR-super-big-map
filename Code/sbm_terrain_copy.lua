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
	map.SuperBigMapRevalidationRebuiltGrids = false
	DebugPrint(string.format(
		"ReinvalidateExpandedTerrain: terrain=%sx%s mapdata=%s wu/tile=%s markers=%s bbox=%s",
		tostring(map_width), tostring(map_height),
		tostring(mapdata_width), tostring(wu_per_tile),
		tostring(has_markers and true or false),
		invalidate_box and "full-map" or "none"
	))

	local profiler = SuperBigMap.LoadingProfiler
	local function profiled_call(name, fn, ...)
		local token = profiler and type(profiler.Begin) == "function" and profiler.Begin(
			"terrain revalidation: " .. tostring(name), nil, map) or false
		local results = { pcall(fn, ...) }
		if token and type(profiler.End) == "function" then
			profiler.End(token, { error = results[1] and nil or tostring(results[2]) }, results[1] == true)
		end
		return Unpack(results, 1, #results)
	end

	-- RebuildGrids is the editor's authoritative post-height-edit entry point. It already
	-- invalidates terrain and rebuilds passability/buildable/water/object-Z state, so running
	-- InvalidateHeight + InvalidateType + RebuildPassability immediately before it duplicates
	-- the most expensive work. Keep the old sequence as a fail-safe fallback.
	local consolidated = cfg_bool("OPTIMIZE_STRETCH_REVALIDATION", true)
		and type(map.RebuildGrids) == "function" and invalidate_box
	local consolidated_ok = false
	if consolidated then
		DebugPrint("ReinvalidateExpandedTerrain: consolidated map:RebuildGrids")
		consolidated_ok = profiled_call("consolidated RebuildGrids", map.RebuildGrids,
			map, invalidate_box) == true
		-- Engine methods commonly return nil on success; pcall success is the signal. The helper
		-- returns pcall's boolean first, so consolidated_ok is true even with a nil method result.
		if consolidated_ok then
			map.SuperBigMapRevalidationRebuiltGrids = true
			-- Preserve the explicit vanilla border repair. It is kept outside the consolidated
			-- call until the profiler proves RebuildGrids subsumes it on expanded terrain.
			if type(terrain_api.FixHeightBorder) == "function" then
				profiled_call("consolidated FixHeightBorder", terrain_api.FixHeightBorder,
					map, invalidate_box)
			end
		end
	end
	if not consolidated_ok then
		if consolidated then
			DebugPrint("ReinvalidateExpandedTerrain: consolidated rebuild failed -- legacy fallback")
		end
		if type(terrain_api.InvalidateHeight) == "function" then
			if invalidate_box then
				profiled_call("legacy InvalidateHeight", terrain_api.InvalidateHeight, map, invalidate_box)
			else
				profiled_call("legacy InvalidateHeight", terrain_api.InvalidateHeight, map)
			end
		end
		if type(terrain_api.InvalidateType) == "function" then
			if invalidate_box then
				profiled_call("legacy InvalidateType", terrain_api.InvalidateType, map, invalidate_box)
			else
				profiled_call("legacy InvalidateType", terrain_api.InvalidateType, map)
			end
		end
		if type(terrain_api.RebuildPassability) == "function" then
			if invalidate_box then
				profiled_call("legacy RebuildPassability", terrain_api.RebuildPassability, map, invalidate_box)
			else
				profiled_call("legacy RebuildPassability", terrain_api.RebuildPassability, map)
			end
		end
		if type(terrain_api.FixHeightBorder) == "function" and invalidate_box then
			profiled_call("legacy FixHeightBorder", terrain_api.FixHeightBorder, map, invalidate_box)
		end
		if type(map.RebuildGrids) == "function" and invalidate_box then
			DebugPrint("ReinvalidateExpandedTerrain: legacy map:RebuildGrids")
			local rebuild_ok = profiled_call("legacy RebuildGrids", map.RebuildGrids, map, invalidate_box)
			if rebuild_ok == true then map.SuperBigMapRevalidationRebuiltGrids = true end
		end
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
-- After the x(full/source) HEIGHT-VALUE scale the map's declared height RANGES go stale:
-- BuildableGrid:Build marks every hex outside mapdata.visible_height_range as UNBUILDABLE
-- (map_max_height = range.to*guim), and playable_height_range gates playable-area checks
-- the same way. Terrain that sat near the top of a range EXCEEDS it after the x1.333 scale,
-- so the post-stretch RebuildBuildableGrid marked e.g. the underground floor around a
-- passage unbuildable -- and placing the elevator's underground construction site asserted
-- in C (HGE::FlattenTerrainInShape: z != nUnbuildableZ, the flatten target z was the
-- unbuildable sentinel). Scale both ranges by the same factor, rounding OUTWARD (floor the
-- bottom, ceil the top). Ranges are in METERS; the scale is a pure ratio, so meters scale by
-- the same mul/div. Deliberately NOT calling terrain.SetPassableHeight: vanilla only applies
-- it from the map-editor property handler, so calling it in-game would ADD a restriction
-- vanilla games don't have. Idempotent per map (flag stamp). MUST run before the stretch
-- branches' RebuildBuildableGrid.
local function ScaleHeightRanges(map, mul, div, add_wu)
	if cfg_bool("STRETCH_SCALE_HEIGHTS", true) ~= true then return false end
	local mapdata = map and map.mapdata
	if type(mapdata) ~= "table" or type(mul) ~= "number" or type(div) ~= "number" or div <= 0 then
		StretchLog("ScaleHeightRanges: skipped", { reason = "mapdata/factor unavailable" })
		return false
	end
	if mapdata.SuperBigMapHeightRangesScaled == true then
		StretchLog("ScaleHeightRanges: already scaled -- skip")
		return false
	end
	-- Ranges are in METERS; the height transform is affine in world units
	-- (h' = h*mul/div + add_wu), so the meter transform is v*mul/div + add_wu/guim.
	add_wu = type(add_wu) == "number" and add_wu or 0
	local guim_v = Global("guim") or 1000
	local function scale_out(v, up)
		local scaled = (v * mul + 0.0) / div + (add_wu + 0.0) / guim_v
		return up and math.ceil(scaled) or math.floor(scaled)
	end
	local function scale_range(tag, range)
		if type(range) ~= "table" or type(range.from) ~= "number" or type(range.to) ~= "number" then
			StretchLog("ScaleHeightRanges: no range to scale", { range = tag, value = tostring(range) })
			return
		end
		local from0, to0 = range.from, range.to
		range.from = scale_out(from0, false)
		range.to = scale_out(to0, true)
		StretchLog("ScaleHeightRanges: scaled", {
			range = tag, mul = mul, div = div, add_wu = add_wu,
			from = tostring(from0) .. " -> " .. tostring(range.from),
			to = tostring(to0) .. " -> " .. tostring(range.to),
		})
	end
	scale_range("visible_height_range", mapdata.visible_height_range)
	scale_range("playable_height_range", mapdata.playable_height_range)
	-- Some engine paths read the range straight off the MAP object (Pathfinding
	-- GetPlayableAreaNearby reads map.playable_height_range); scale it too when it is a
	-- separate table (if it aliases mapdata's, the scale above already covered it).
	if type(map.playable_height_range) == "table" and map.playable_height_range ~= mapdata.playable_height_range then
		scale_range("map.playable_height_range", map.playable_height_range)
	end
	if type(map.visible_height_range) == "table" and map.visible_height_range ~= mapdata.visible_height_range then
		scale_range("map.visible_height_range", map.visible_height_range)
	end
	mapdata.SuperBigMapHeightRangesScaled = true
	return true
end

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
	local function stretch_one(label, get_fn, set_fn, invalidate_fn, interpolate, scale_values)
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
			-- FULL 3D STRETCH (config STRETCH_SCALE_HEIGHTS): scale the HEIGHT VALUES by the same
			-- full/source factor as X/Y, making the stretch a true similarity transform -- vanilla
			-- slope steepness and object seating geometry are preserved (XY-only stretching made
			-- slopes 25% shallower while object meshes scaled x1.333 in all axes; big formations
			-- sculpted into relief ended up floating). Height grid only -- type/colour/biome are
			-- CATEGORICAL values and must never be scaled.
			--
			-- HEIGHT BUDGET (user decision, "shift + adaptive z-scale"): the grid is 16-bit
			-- (0..cap=65535). High-relief maps overflow at x4/3 (60657*4/3 = 80876) and clip
			-- into flat-top plateaus. Two gated remedies, applied as ONE affine GridMulDivAdd
			-- (h' = h*zmul/zdiv + zadd):
			--   STRETCH_SHIFT_HEIGHTS_DOWN -- shift the whole field down so the SOURCE minimum
			--     lands at FLOOR_MARGIN (frees min*scale of headroom at the top);
			--   STRETCH_ADAPTIVE_Z_SCALE   -- if the span STILL overflows, reduce only the Z
			--     scale to exactly fit: zmul/zdiv = (cap-FLOOR_MARGIN)/(max0-min0) (~1.20 on
			--     this map vs 1.333; slopes ~90% of vanilla steepness ONLY on maps that need it).
			-- min0/max0 are measured on the SOURCE grid (src_sub) BEFORE the resample: the
			-- resampled grid's minimum includes the border-ring interpolation artifact (~33),
			-- which would nullify the shift. The applied transform is STAMPED on the map
			-- (SuperBigMapZScaleMul/Div/Add) for the height-range scaling and the relief-dz
			-- consumers. Both flags false = exactly the old behavior (x full/source, add 0).
			if scale_values and cfg_bool("STRETCH_SCALE_HEIGHTS", true) then
				local grid_muldivadd = Global("GridMulDivAdd")
				local grid_minmax = Global("GridMinMax")
				if type(grid_muldivadd) == "function" then
					-- Source-grid span (pre-resample: artifact-free vanilla values).
					local min0, max0
					if type(grid_minmax) == "function" then
						local ok_mm, a, b = pcall(grid_minmax, src_sub)
						if ok_mm then min0, max0 = a, b end
					end
					local cap
					local const_tbl = Global("const")
					if type(const_tbl) == "table" and type(const_tbl.MaxTerrainHeight) == "number"
						and type(const_tbl.TerrainHeightScale) == "number" and const_tbl.TerrainHeightScale > 0 then
						cap = math.floor(const_tbl.MaxTerrainHeight / const_tbl.TerrainHeightScale)
					end
					local FLOOR_MARGIN = 1000 -- 1 m of bottom headroom (resample undershoot buffer)
					local zmul, zdiv, zadd = full_tw, sw_tiles, 0
					local adaptive = false
					if type(min0) == "number" and type(max0) == "number" and max0 > min0 and cap then
						local shift = cfg_bool("STRETCH_SHIFT_HEIGHTS_DOWN", true)
						if shift and cfg_bool("STRETCH_ADAPTIVE_Z_SCALE", true)
							and (max0 - min0) * zmul / zdiv + FLOOR_MARGIN > cap then
							zmul, zdiv = cap - FLOOR_MARGIN, max0 - min0
							adaptive = true
						end
						if shift then
							zadd = FLOOR_MARGIN - math.floor(min0 * zmul / zdiv)
						end
					end
					local ok_scale, err_scale = pcall(grid_muldivadd, stretched, zmul, zdiv, zadd)
					-- Stamp the applied Z transform for consumers (height ranges, relief dz).
					map.SuperBigMapZScaleMul = zmul
					map.SuperBigMapZScaleDiv = zdiv
					map.SuperBigMapZScaleAdd = zadd
					local min1, max1
					if type(grid_minmax) == "function" then
						local ok_mm2, a2, b2 = pcall(grid_minmax, stretched)
						if ok_mm2 then min1, max1 = a2, b2 end
					end
					-- Clamp belt-and-braces: the border-ring resample undershoot can go negative
					-- after the shift, and a hair of overshoot can exceed the cap at the rim.
					local clamped = false
					if cap and ((type(max1) == "number" and max1 > cap) or (type(min1) == "number" and min1 < 0)) then
						local grid_clamp = Global("GridClamp")
						if type(grid_clamp) == "function" then
							clamped = pcall(grid_clamp, stretched, 0, cap) == true
						end
					end
					StretchLog("height scale (full 3D stretch, shift + adaptive z)", {
						grid = label, ok = ok_scale, err = ok_scale and nil or tostring(err_scale),
						zmul = zmul, zdiv = zdiv, zadd = zadd, adaptive = adaptive,
						z_scale = string.format("%.4f", (zmul + 0.0) / zdiv),
						src_min = tostring(min0), src_max = tostring(max0),
						min_after = tostring(min1), max_after = tostring(max1),
						cap = tostring(cap), clamped = clamped,
					})
				else
					StretchLog("height scale SKIPPED -- GridMulDivAdd unavailable", { grid = label })
				end
			end
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
	if timed("height", stretch_one, "height", terrain_api.GetHeightGrid, terrain_api.SetHeightGrid, terrain_api.InvalidateHeight, true, true) then
		done = done + 1
		-- Height VALUES just transformed (h*zmul/zdiv + zadd, stamped by stretch_one) -> the
		-- declared buildable/playable height ranges must follow the SAME affine transform
		-- before any buildable rebuild.
		timed("height-ranges", ScaleHeightRanges, map,
			map.SuperBigMapZScaleMul or full_tw,
			map.SuperBigMapZScaleDiv or sw_tiles,
			map.SuperBigMapZScaleAdd or 0)
	end
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

-- RELIEF ANNOTATIONS (config STRETCH_RELIEF_AWARE_DECOR): captured BEFORE the terrain stretch,
-- per map: for every root object with an explicit Z in the source region, its relationship to
-- the ground -- dz = obj_z - terrain_height(xy). After the terrain stretches in X/Y/Z, the
-- correct placement is new_z = stretched_terrain_height(new_xy) + dz * (full/source): anchored
-- to the ACTUAL stretched ground (absorbing resample smoothing) while preserving the scaled
-- embedding (half-buried stays proportionally half-buried; the SetTerrainZ hard-snap destroyed
-- intentional embedding). Weak keys: entries vanish with their objects; table dropped per map
-- after the stretch branch (never savegame-persisted).
local decor_relief_by_map = setmetatable({}, { __mode = "k" })
local decor_objects_by_map = setmetatable({}, { __mode = "k" })

local function AnnotateDecorRelief(map)
	if not map or not cfg_bool("STRETCH_RELIEF_AWARE_DECOR", true) then return 0 end
	if type(map.MapForEach) ~= "function" then return 0 end
	local terrain_api = Global("terrain")
	local box_fn = Global("box")
	if type(terrain_api) ~= "table" or type(terrain_api.GetHeight) ~= "function"
		or type(box_fn) ~= "function" then
		return 0
	end
	local const_tbl = Global("const")
	local hts = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number") and const_tbl.HeightTileSize or 1
	local sw_tiles = map.SuperBigMapSourceWidthTiles or map.SuperBigMapGeneratorWidthTiles
	local sh_tiles = map.SuperBigMapSourceHeightTiles or map.SuperBigMapGeneratorHeightTiles
	if type(sw_tiles) ~= "number" or sw_tiles <= 0 then return 0 end
	sh_tiles = (type(sh_tiles) == "number" and sh_tiles > 0) and sh_tiles or sw_tiles
	local src_box = box_fn(0, 0, sw_tiles * hts, sh_tiles * hts)
	local relief = setmetatable({}, { __mode = "k" })
	local objects = {}
	local annotated, sampled = 0, 0
	local DebugLog = SuperBigMap.DebugLog
	pcall(map.MapForEach, map, src_box, "CObject", function(obj)
		if not obj then return end
		objects[#objects + 1] = obj
		-- Relief is consumed only by the decoration scaling pass. Avoid terrain-height calls for
		-- buildings, markers, units, attached children, and other objects that pass never moves.
		if cfg_bool("OPTIMIZE_STRETCH_DECOR_TRAVERSAL", true)
			and (ShouldSkipObject(obj) or IsImportantSectorObject(obj)) then return end
		if type(obj.GetParent) == "function" then
			local ok_p, parent = pcall(obj.GetParent, obj)
			if ok_p and parent then return end -- attached children follow their parent
		end
		local pos = ObjectPosition(obj)
		if not pos then return end
		local pz
		pcall(function() pz = pos:z() end)
		if type(pz) ~= "number" then return end -- terrain-glued: no explicit z to preserve
		local ok_h, h = pcall(terrain_api.GetHeight, map, pos)
		if not ok_h or type(h) ~= "number" then return end
		relief[obj] = pz - h
		annotated = annotated + 1
		if sampled < 8 and DebugLog and DebugLog.On("Align") then
			sampled = sampled + 1
			local px, py = PointXY(pos)
			DebugLog.Info("Align", "relief annotated", {
				n = sampled, class = tostring(obj.class or "?"),
				xy = tostring(px) .. "," .. tostring(py), dz = pz - h,
			})
		end
	end)
	decor_relief_by_map[map] = relief
	if cfg_bool("OPTIMIZE_STRETCH_DECOR_TRAVERSAL", true) then
		decor_objects_by_map[map] = objects
	end
	StretchLog("AnnotateDecorRelief: DONE", { annotated = annotated, collected = #objects })
	DebugPrint(string.format("relief annotations: %s objects", tostring(annotated)))
	return annotated
end

local function ClearDecorRelief(map)
	if map then
		decor_relief_by_map[map] = nil
		decor_objects_by_map[map] = nil
	end
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
	local terrain_api_g = Global("terrain") -- for relief-aware Z placement
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
	local objs = cfg_bool("OPTIMIZE_STRETCH_DECOR_TRAVERSAL", true)
		and decor_objects_by_map[map] or nil
	local reused_collection = type(objs) == "table"
	if not reused_collection then
		objs = {}
	end
	if not reused_collection and type(map.MapForEach) == "function" then
		pcall(map.MapForEach, map, src_box, "CObject", function(o) objs[#objs + 1] = o end)
	end
	StretchLog("ScaleDecorationsToFull: collected", {
		count = #objs, scale_x = tostring(scale_x), scale_y = tostring(scale_y),
		reused_pre_stretch_collection = reused_collection,
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
				local z_mode = "snap"
				-- Relief-aware Z: reproduce the object's pre-stretch relationship to the ground
				-- (dz annotated before the terrain stretch), scaled by the same factor, on top of
				-- the ACTUAL stretched terrain height at the destination.
				local relief = decor_relief_by_map[map]
				local dz = relief and relief[obj]
				if type(dz) == "number" and type(terrain_api_g) == "table"
					and type(terrain_api_g.GetHeight) == "function" then
					local ok_h, h = pcall(terrain_api_g.GetHeight, map, np)
					if ok_h and type(h) == "number" then
						-- dz scales by the Z factor (which the shift+adaptive height transform
						-- may have set below the XY factor; the shift offset cancels in a
						-- difference). Fallback: the XY factor when no stamp (heights unscaled).
						local zs = (type(map.SuperBigMapZScaleMul) == "number"
							and type(map.SuperBigMapZScaleDiv) == "number"
							and map.SuperBigMapZScaleDiv > 0)
							and ((map.SuperBigMapZScaleMul + 0.0) / map.SuperBigMapZScaleDiv) or scale_x
						np = point_fn(nx, ny, h + math.floor(dz * zs + 0.5))
						z_ok = true
						z_mode = "relief"
					end
				end
				if not z_ok and type(np.SetTerrainZ) == "function" then
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
						z_snapped = z_ok, z_mode = z_mode,
						old_scale = old_scale, new_scale = new_scale,
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
-- This pass applies the SAME position*(full/source) transform to those visuals.
--
-- DEFERRED ELEVATOR MIGRATION:
-- A surface Elevator can be instant-completed before deferred underground expansion while its
-- underground half is still a ConstructionSite. Completion destroys the surface site, leaving
-- the underground site's linked_obj as a stale Lua table; moving that site later also carries
-- stale construction/build-grid state. Snapshot those pairs, remove ONLY the pending underground
-- site with DoneObject (never Cancel/RestoreTerrain), then rebuild a finished underground half
-- after terrain + buildability are final. The correctly placed surface Elevator is untouched.
local function IsLiveGameObject(obj)
	if not obj then return false end
	local is_valid = Global("IsValid")
	if type(is_valid) == "function" then
		return SafeCall(is_valid, obj) == true
	end
	return type(obj.GetPos) == "function"
end

local function IsElevatorConstructionSite(obj)
	if not IsLiveGameObject(obj) or not IsKindOfSafe(obj, "ConstructionSite") then return false end
	local class_name = obj.building_class or obj.template_name
	if type(obj.GetBuildingClass) == "function" then
		local value = SafeCall(obj.GetBuildingClass, obj)
		if type(value) == "string" then class_name = value end
	end
	return class_name == "Elevator" or IsKindOfSafe(obj.building_class_proto, "ElevatorBase")
end

local function ElevatorMigrationLog(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then DebugLog.Info("ElevatorTerrain", message, data) end
end

local function ElevatorTerrainFingerprint(map, cx, cy)
	local terrain_api = Global("terrain")
	local point_fn = Global("point")
	if type(terrain_api) ~= "table" or type(terrain_api.GetHeight) ~= "function"
		or type(point_fn) ~= "function" then return nil end
	local values, checksum, lo, hi = {}, 0, nil, nil
	for gy = -2, 2 do
		for gx = -2, 2 do
			local z = SafeCall(terrain_api.GetHeight, map, point_fn(cx + gx * 512, cy + gy * 512))
			if type(z) ~= "number" then return nil end
			values[#values + 1] = z
			checksum = checksum + z * (#values + 11)
			lo = not lo and z or math.min(lo, z)
			hi = not hi and z or math.max(hi, z)
		end
	end
	return { values = values, checksum = checksum, min_z = lo, max_z = hi }
end

local function SameElevatorTerrainFingerprint(a, b)
	if type(a) ~= "table" or type(b) ~= "table" or #a.values ~= #b.values then return false end
	for i = 1, #a.values do
		if a.values[i] ~= b.values[i] then return false end
	end
	return true
end

local function BeginDeferredElevatorMigration(map)
	local records = {}
	if not map or not map.mapdata or map.mapdata.Environment ~= "Underground"
		or type(map.MapForEach) ~= "function" or type(map.MapFindNearest) ~= "function" then
		return records
	end
	local sites = {}
	pcall(map.MapForEach, map, "map", "ConstructionSite", function(site)
		if IsElevatorConstructionSite(site) then sites[#sites + 1] = site end
	end)
	local done_object = Global("DoneObject")
	if #sites > 0 and type(done_object) ~= "function" then
		error("deferred Elevator migration cannot remove pending underground sites")
	end
	for _, site in ipairs(sites) do
		local site_pos = ObjectPosition(site)
		local passage = site_pos and SafeCall(map.MapFindNearest, map, site_pos, "map",
			"SurfacePassageBase", "UndergroundPassageBase") or nil
		local surface_passage = IsLiveGameObject(passage) and passage.other or nil
		local surface_elevator = IsLiveGameObject(surface_passage) and surface_passage.elevator or nil
		if IsLiveGameObject(surface_elevator) and IsKindOfSafe(surface_elevator, "ElevatorBase") then
			local surface_pos = ObjectPosition(surface_elevator)
			local sx, sy = PointXY(surface_pos)
			if type(sx) == "number" and type(sy) == "number" then
				local angle = type(site.GetAngle) == "function" and SafeCall(site.GetAngle, site) or 0
				local palette
				if type(surface_elevator.GetColorizationMaterials) == "function" then
					local ok_colors, c1, c2, c3, c4 = pcall(surface_elevator.GetColorizationMaterials, surface_elevator)
					if ok_colors then palette = { c1, c2, c3, c4 } end
				end
				local record = {
					surface_elevator = surface_elevator,
					surface_passage = surface_passage,
					underground_passage = passage,
					surface_x = sx,
					surface_y = sy,
					angle = angle or 0,
					name = surface_elevator.name,
					palette = palette,
					user_include_in_lrt = surface_elevator.user_include_in_lrt,
					old_site = site,
					restored = false,
				}
				records[#records + 1] = record
				ElevatorMigrationLog("deferred Elevator annotated before underground expansion", {
					n = #records, site = tostring(site), surface_elevator = tostring(surface_elevator),
					underground_passage = tostring(passage), surface_passage = tostring(surface_passage),
					target_x = sx, target_y = sy, angle = tostring(angle),
				})
				-- Clear passage occupancy first. The old linked_obj is deliberately never dereferenced:
				-- it may be the destroyed surface ConstructionSite that caused HGE::l_GetPos.
				if passage.elevator_construction == site or not IsLiveGameObject(passage.elevator_construction) then
					passage.elevator_construction = false
				end
				if surface_passage.elevator_construction == site
					or not IsLiveGameObject(surface_passage.elevator_construction) then
					surface_passage.elevator_construction = false
				end
				site.linked_obj = false
				local ok_done, done_err = pcall(done_object, site)
				if not ok_done or IsLiveGameObject(site) then
					error("failed to remove pending underground Elevator site: " .. tostring(done_err))
				end
				ElevatorMigrationLog("pending underground Elevator site removed without terrain restore", {
					n = #records, old_site = tostring(site), target_x = sx, target_y = sy,
				})
			end
		else
			ElevatorMigrationLog("underground Elevator site left in place (no finished surface counterpart)", {
				site = tostring(site), passage = tostring(passage), surface_passage = tostring(surface_passage),
				surface_elevator = tostring(surface_elevator),
			})
		end
	end
	ElevatorMigrationLog("deferred Elevator annotation/removal complete", {
		pending_sites = #sites, migrations = #records,
	})
	return records
end

local function RestoreDeferredElevatorMigration(map, records, reason)
	if type(records) ~= "table" or #records == 0 then return 0 end
	local point_fn = Global("point")
	local place_building = Global("PlaceBuildingIn")
	if type(point_fn) ~= "function" or type(place_building) ~= "function" then
		error("deferred Elevator migration cannot rebuild finished underground counterparts")
	end
	local restored = 0
	for i, record in ipairs(records) do
		if not record.restored then
			local terrain_before = ElevatorTerrainFingerprint(map, record.surface_x, record.surface_y)
			local target = point_fn(record.surface_x, record.surface_y)
			if type(target.SetTerrainZ) == "function" then
				local snapped = SafeCall(target.SetTerrainZ, target, map)
				if snapped then target = snapped end
			end
			local target_z = type(target.z) == "function" and SafeCall(target.z, target) or nil
			local instance = {
				city = map.City,
				name = record.name,
			}
			local params = {
				alternative_entity_t = {
					entity = "ElevatorUnderground",
					palette = record.palette,
				},
			}
			local bld = SafeCall(place_building, "Elevator", map, instance, params)
			if not IsLiveGameObject(bld) then
				error("failed to rebuild underground Elevator counterpart " .. tostring(i))
			end
			if type(bld.SetAngle) == "function" then SafeCall(bld.SetAngle, bld, record.angle or 0) end
			if type(bld.SetPos) == "function" then SafeCall(bld.SetPos, bld, target) end
			if type(bld.ApplyToGrids) == "function" then SafeCall(bld.ApplyToGrids, bld) end
			if record.user_include_in_lrt ~= nil then bld.user_include_in_lrt = record.user_include_in_lrt end
			local terrain_after = ElevatorTerrainFingerprint(map, record.surface_x, record.surface_y)
			local terrain_unchanged = SameElevatorTerrainFingerprint(terrain_before, terrain_after)
			if not terrain_unchanged then
				error("rebuilding underground Elevator counterpart changed terrain at "
					.. tostring(record.surface_x) .. "," .. tostring(record.surface_y))
			end
			local passage = type(map.MapFindNearest) == "function"
				and SafeCall(map.MapFindNearest, map, target, "map", "SurfacePassageBase", "UndergroundPassageBase") or nil
			if IsLiveGameObject(passage) then passage.elevator_construction = false end
			record.rebuilt_elevator = bld
			record.restored = true
			restored = restored + 1
			ElevatorMigrationLog("finished underground Elevator counterpart rebuilt", {
				n = i, reason = tostring(reason or "normal"), elevator = tostring(bld),
				surface_elevator = tostring(record.surface_elevator), passage = tostring(passage),
				x = record.surface_x, y = record.surface_y, z = tostring(target_z),
				terrain_unchanged = tostring(terrain_unchanged),
				terrain_checksum = terrain_after and terrain_after.checksum or "?",
				terrain_min_z = terrain_after and terrain_after.min_z or "?",
				terrain_max_z = terrain_after and terrain_after.max_z or "?",
			})
		end
	end
	return restored
end

-- Continue STRETCH step 3b: move everything matching IsUndergroundAccessObject or a
-- SpawnsOnCityInit tunnel spawner, EXCEPT the tunnel
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
	local function is_elevator_or_site(obj)
		if IsKindOfSafe(obj, "ElevatorBase") then return true, "elevator" end
		if not IsKindOfSafe(obj, "ConstructionSite") then return false end
		local class_name = obj.building_class or obj.template_name
		if type(obj.GetBuildingClass) == "function" then
			local ok, value = pcall(obj.GetBuildingClass, obj)
			if ok and type(value) == "string" then class_name = value end
		end
		if class_name == "Elevator" or IsKindOfSafe(obj.building_class_proto, "ElevatorBase") then
			return true, "elevator_site"
		end
		return false
	end
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
		local nx = math.floor(ox * scale + 0.5)
		local ny = math.floor(oy * scale + 0.5)
		local pair_exact = false
		local elevator_kind = is_elevator_or_site(obj)
		if elevator_kind then
			local linked = IsKindOfSafe(obj, "ElevatorBase") and obj.other or obj.linked_obj
			-- A destroyed construction site remains a Lua table with GetPos but is no longer a
			-- luaGameObject. Never cross the engine boundary unless IsValid confirms it is live.
			if IsLiveGameObject(linked) and type(linked.GetPos) == "function" then
				local ok_lp, linked_pos = pcall(linked.GetPos, linked)
				local lx, ly
				if ok_lp then lx, ly = PointXY(linked_pos) end
				if type(lx) == "number" and type(ly) == "number" then
					-- The surface half already occupies its final expanded coordinate. Use that exact
					-- XY for the underground half instead of relying on rounding the scale twice.
					nx, ny = lx, ly
					pair_exact = true
				end
			end
		end
		local np = point_fn(nx, ny)
		-- Relief-aware Z (same scheme as the decor pass): reproduce the annotated pre-stretch
		-- ground relationship, scaled, on the actual stretched terrain; fall back to a snap.
		local placed_z = false
		local relief = decor_relief_by_map[map]
		local dz = relief and relief[obj]
		local terrain_api = Global("terrain")
		if type(dz) == "number" and type(terrain_api) == "table"
			and type(terrain_api.GetHeight) == "function" then
			local ok_h, h = pcall(terrain_api.GetHeight, map, np)
			if ok_h and type(h) == "number" then
				-- dz scales by the Z factor stamped by the height transform (may be below the
				-- XY factor under adaptive z-scale; the shift offset cancels in a difference).
				local zs = (type(map.SuperBigMapZScaleMul) == "number"
					and type(map.SuperBigMapZScaleDiv) == "number"
					and map.SuperBigMapZScaleDiv > 0)
					and ((map.SuperBigMapZScaleMul + 0.0) / map.SuperBigMapZScaleDiv) or scale
				np = point_fn(nx, ny, h + math.floor(dz * zs + 0.5))
				placed_z = true
			end
		end
		if not placed_z and type(np.SetTerrainZ) == "function" then
			local ok_z, pz = pcall(np.SetTerrainZ, np, map)
			if ok_z and pz then np = pz end
		end
		-- ENTRANCE SIGN: the badge is placed at terrain level (vanilla InvalidZ), so a nearby
		-- terrain rise half-occludes it under the tilted overview camera (user report: sign
		-- "half exposed"). Float it above the LOCAL terrain MAX (sampled in a small radius, so
		-- a bump between camera and sign can't clip it) plus a clearance, guaranteeing the whole
		-- badge is visible. Config ENTRANCE_SIGN_CLEARANCE_WU / ENTRANCE_SIGN_CLEARANCE_RADIUS_HEXES.
		if IsKindOfSafe(obj, "SurfaceUndergroundTunnelSign")
			and type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function" then
			local clearance = cfg_number("ENTRANCE_SIGN_CLEARANCE_WU", 1500, 0)
			local rad_hexes = math.max(0, math.floor(cfg_number("ENTRANCE_SIGN_CLEARANCE_RADIUS_HEXES", 3, 0)))
			local hex_wu = (type(const_tbl) == "table" and type(const_tbl.HexSize) == "number"
				and const_tbl.HexSize > 0) and const_tbl.HexSize or 1000
			local r = rad_hexes * hex_wu
			local zmax
			local offsets = { { 0, 0 } }
			if r > 0 then
				local d = math.floor(r * 7 / 10)
				offsets = {
					{ 0, 0 }, { r, 0 }, { -r, 0 }, { 0, r }, { 0, -r },
					{ d, d }, { -d, d }, { d, -d }, { -d, -d },
				}
			end
			for _, o in ipairs(offsets) do
				local ok_h2, h2 = pcall(terrain_api.GetHeight, map, point_fn(nx + o[1], ny + o[2]))
				if ok_h2 and type(h2) == "number" and (zmax == nil or h2 > zmax) then zmax = h2 end
			end
			if type(zmax) == "number" then
				np = point_fn(nx, ny, zmax + clearance)
				placed_z = true
				AlignLog("entrance sign floated above local terrain max", {
					xy = tostring(nx) .. "," .. tostring(ny),
					terrain_max = zmax, clearance = clearance, z = zmax + clearance,
				})
			end
		end
		local ok_set = false
		local rehexed = false
		if type(obj.SetPos) == "function" then
			-- BUILDINGS (e.g. the natural UndergroundPassage) occupy object_hex_grid slots at
			-- their placement position; a bare SetPos moves the visuals but LEAVES THE HEX
			-- REGISTRATION BEHIND -- construction snapping (the Elevator's ElevatorPassage search
			-- goes through HexGridShapeGetObjectList) then finds nothing at the visible spot.
			-- Re-register the hex shape across the move.
			local hex_grid = map.object_hex_grid
			local hex_remove = Global("HexGridShapeRemoveObject")
			local hex_add = Global("HexGridShapeAddObject")
			local shape
			-- Entrance passages plus an Elevator/Elevator construction site created before deferred
			-- underground expansion must carry their occupied hexes to the stretched coordinate.
			-- luaHex.cpp asserts 'handle > 0' (uncatchable C-side) both for handle-less objects
			-- AND when removing an object that is not currently registered in the grid -- some
			-- Building-derived entrance indicators pass a Building+handle test yet were never
			-- hex-registered by vanilla (crash log 16.44.48). Whitelist, don't heuristic.
			local is_valid_fn = Global("IsValid")
			if hex_grid and type(hex_remove) == "function" and type(hex_add) == "function"
				and (IsKindOfSafe(obj, "ElevatorPassage") or is_elevator_or_site(obj))
				and (type(is_valid_fn) ~= "function" or is_valid_fn(obj) == true)
				and type(obj.handle) == "number" and obj.handle > 0
				and type(obj.GetShapePoints) == "function" then
				local ok_sh, sh = pcall(obj.GetShapePoints, obj)
				if ok_sh and sh then shape = sh end
			end
			-- REGISTRATION PRE-CHECK: luaHex.cpp asserts 'handle > 0' (uncatchable) when
			-- REMOVING an object that is not currently registered at its cells. Verify via
			-- HexGridShapeGetObjectList that the object really is registered there before
			-- removing; if it is not, skip the remove but still ADD after the move (that IS
			-- the desired end state for the snap machinery), and log the anomaly.
			local was_registered = false
			if shape then
				local hex_list = Global("HexGridShapeGetObjectList")
				if type(hex_list) == "function" then
					local ok_l, list = pcall(hex_list, hex_grid, obj, shape)
					if ok_l and type(list) == "table" then
						for _, o2 in ipairs(list) do
							if o2 == obj then was_registered = true break end
						end
					end
				end
				if not was_registered then
					AlignLog("hex re-reg pre-check: object NOT registered at its cells -- remove skipped", {
						class = tostring(obj.class or "?"), handle = tostring(obj.handle),
					})
				end
			end
			if shape and was_registered then pcall(hex_remove, hex_grid, obj, shape) end
			ok_set = pcall(obj.SetPos, obj, np)
			if shape then
				rehexed = pcall(hex_add, hex_grid, obj, shape) == true
			end
		end
		if ok_set then moved = moved + 1 end
		-- ENTRANCE SIGN always visible (user report: badge vanishes when the camera comes
		-- close). Vanilla's ScaleSmallObjects sets these signs depth-tested (disableZ=false) in
		-- the close/normal camera, so terrain occludes the ground badge; in overview it uses
		-- SetNoDepthTest(true) to render on top. Make the entrance sign ALWAYS render on top +
		-- visible so it shows at every zoom. (ScaleSmallObjects re-asserts depth test on
		-- overview transitions -- that is re-corrected by the OverviewModeDialog.ScaleSmallObjects
		-- wrapper in sbm_sector_highlight.)
		if ok_set and cfg_bool("ALWAYS_SHOW_ENTRANCE_SIGN", true)
			and IsKindOfSafe(obj, "SurfaceUndergroundTunnelSign") then
			if type(obj.SetNoDepthTest) == "function" then pcall(obj.SetNoDepthTest, obj, true) end
			if type(obj.SetVisible) == "function" then pcall(obj.SetVisible, obj, true) end
			if type(obj.SetOpacity) == "function" then pcall(obj.SetOpacity, obj, 100) end
		end
		AlignLog("entrance visual moved", {
			via = via, class = tostring(obj.class or "?"),
			from = tostring(ox) .. "," .. tostring(oy),
			to = tostring(nx) .. "," .. tostring(ny),
			ok = ok_set, rehexed = rehexed, paired_exact_xy = pair_exact,
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
	-- Sweep 3: a player can construct the paired Elevator while the underground is still at its
	-- native size. The underground half (or its linked construction site) is a Building, excluded
	-- from decoration movement and not an entrance-marker class, so move it explicitly now.
	pcall(map.MapForEach, map, "map", "ElevatorBase", function(obj)
		handle(obj, "pre-expansion elevator")
	end)
	pcall(map.MapForEach, map, "map", "ConstructionSite", function(obj)
		local matched = is_elevator_or_site(obj)
		if matched then handle(obj, "pre-expansion elevator site") end
	end)
	StretchLog("MoveEntranceVisualsToScale: DONE", { moved = moved })
	DebugPrint(string.format("MoveEntranceVisualsToScale: moved %s entrance visuals", tostring(moved)))
	return moved
end

-- STRETCH step 3c (floater audit): find objects HOVERING above the stretched terrain and log
-- exactly who they are. Cause under investigation (user screenshot: large rock formations
-- floating): the decoration pass SKIPS several categories (ShouldSkipObject: mystery objects,
-- underground access, buildings, ~450-800 per map in the logs) -- a skipped object keeps its OLD
-- Z at its OLD position while the terrain there stretched away and may now be lower. Every
-- floater logs class / position / z / terrain height / dz / whether it has a parent and, most
-- diagnostic, the ShouldSkipObject verdict (true = the decor pass skipped it -- cause confirmed).
-- When STRETCH_RESNAP_FLOATERS is on, non-Building floaters are snapped down onto the terrain
-- (Buildings are logged but never touched). Surface map only -- underground ceilings would
-- misflag. Threshold 300 wu above terrain.
local function AuditFloatingObjects(map, phase)
	phase = tostring(phase or "?")
	if not map or type(map.MapForEach) ~= "function" then return 0 end
	local terrain_api = Global("terrain")
	local point_fn = Global("point")
	if type(terrain_api) ~= "table" or type(terrain_api.GetHeight) ~= "function"
		or type(point_fn) ~= "function" then
		return 0
	end
	local DebugLog = SuperBigMap.DebugLog
	local function AlignLog(msg, data)
		if DebugLog then DebugLog.Info("Align", msg, data) end
	end
	local object_clone = SuperBigMap.ObjectClone
	local should_skip = object_clone and object_clone.ShouldSkipObject
	local fix = cfg_bool("STRETCH_RESNAP_FLOATERS", true)
	local THRESHOLD = 300       -- wu above terrain at the ORIGIN = floating
	local EDGE_THRESHOLD = 1500 -- wu clearance under a big mesh's EDGES = visual overhang float
	local BIG_RADIUS = 6000     -- wu: objects at least this wide get the edge check
	local skip_classes = {
		City = true, MapSector = true, RandomMapGeneratorHolder = true, RevealedMapSector = true,
		SectorUnexplored = true, SectorScanned = true, SectorTarget = true, SectorRadius = true,
		CameraObj = true,
	}
	local floaters, fixed, examined = 0, 0, 0
	local edge_floaters, skipped_parent, no_explicit_z = 0, 0, 0
	local class_counts = {}
	local pass_batch = type(map.SuspendPassEdits) == "function" and type(map.ResumePassEdits) == "function"
	if pass_batch then pcall(map.SuspendPassEdits, map, "SuperBigMapFloaterAudit") end
	pcall(map.MapForEach, map, "map", "CObject", function(obj)
		if not obj or skip_classes[obj.class or false] then return end
		-- Attached children follow their parent; only audit root objects (counted -- a large
		-- attached mesh under a distant parent would be a blind spot worth knowing about).
		if type(obj.GetParent) == "function" then
			local ok_p, parent = pcall(obj.GetParent, obj)
			if ok_p and parent then
				skipped_parent = skipped_parent + 1
				return
			end
		end
		local pos = ObjectPosition(obj)
		if not pos then return end
		local px, py = PointXY(pos)
		if type(px) ~= "number" or type(py) ~= "number" then return end
		local pz
		pcall(function() pz = pos:z() end)
		if type(pz) ~= "number" then
			no_explicit_z = no_explicit_z + 1
			return
		end
		examined = examined + 1
		local ok_h, h = pcall(terrain_api.GetHeight, map, pos)
		if not ok_h or type(h) ~= "number" then return end
		local dz = pz - h
		local cls = tostring(obj.class or "?")
		if dz > THRESHOLD then
			floaters = floaters + 1
			class_counts[cls] = (class_counts[cls] or 0) + 1
			local skipped_verdict = "?"
			if type(should_skip) == "function" then
				local ok_s, v = pcall(should_skip, obj)
				if ok_s then skipped_verdict = v and true or false end
			end
			local is_building = IsKindOfSafe(obj, "Building")
			if floaters <= 25 then
				AlignLog("floater", {
					phase = phase, class = cls, xy = tostring(px) .. "," .. tostring(py),
					z = pz, terrain_h = h, dz = dz,
					decor_pass_skips_it = skipped_verdict, building = is_building,
				})
			end
			if fix and not is_building and type(obj.SetPos) == "function" then
				local np = point_fn(px, py, h)
				if pcall(obj.SetPos, obj, np) then fixed = fixed + 1 end
			end
			return
		end
		-- EDGE CHECK for large meshes: the origin can sit ON the ground while the mesh bulk
		-- hangs over lower terrain (screenshot: razor-flat rock base high above a dip). Sample
		-- the terrain under the mesh edges; large positive clearance = visual float that the
		-- origin test cannot see. Log-only (auto-lowering could bury the origin side).
		if type(obj.GetRadius) == "function" then
			local ok_r, r = pcall(obj.GetRadius, obj)
			if ok_r and type(r) == "number" and r >= BIG_RADIUS then
				local worst
				for _, off in ipairs({ {r, 0}, {-r, 0}, {0, r}, {0, -r} }) do
					local ok_h2, h2 = pcall(terrain_api.GetHeight, map, point_fn(px + off[1], py + off[2]))
					if ok_h2 and type(h2) == "number" then
						local clearance = pz - h2
						if not worst or clearance > worst then worst = clearance end
					end
				end
				if worst and worst > EDGE_THRESHOLD then
					edge_floaters = edge_floaters + 1
					if edge_floaters <= 25 then
						AlignLog("floater (edge overhang)", {
							phase = phase, class = cls, xy = tostring(px) .. "," .. tostring(py),
							z = pz, dz_origin = dz, worst_edge_clearance = worst, radius = r,
						})
					end
				end
			end
		end
	end)
	if pass_batch then pcall(map.ResumePassEdits, map, "SuperBigMapFloaterAudit") end
	local top = {}
	for cls, n in pairs(class_counts) do top[#top + 1] = cls .. "=" .. n end
	table.sort(top)
	AlignLog("floater audit DONE", {
		phase = phase, examined = examined, floaters = floaters, fixed = fixed,
		edge_overhangs = edge_floaters, skipped_attached = skipped_parent, no_explicit_z = no_explicit_z,
		by_class = table.concat(top, " "),
	})
	StretchLog("AuditFloatingObjects: DONE", { phase = phase, floaters = floaters, fixed = fixed, edge_overhangs = edge_floaters })
	DebugPrint(string.format("floater audit [%s]: %s floating (%s snapped), %s edge overhangs",
		phase, tostring(floaters), tostring(fixed), tostring(edge_floaters)))
	return floaters
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
-- source. Mod maps only; gated on FORCE_FRAME_PASSABLE. defer_rebuild=true applies the
-- overlay without a standalone rebuild when an immediately-following full revalidation will
-- rebuild passability once for the same final state.
local function ForceFramePassable(map, defer_rebuild)
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
	local single_write = cfg_bool("OPTIMIZE_FRAME_PASSABLE_WRITES", true)
	local has_rebuild = type(terrain_api.RebuildPassability) == "function"
	defer_rebuild = defer_rebuild == true

	if type(net_pause) == "function" then SafeCall(net_pause, reason) end
	if type(map.SuspendPassEdits) == "function" then SafeCall(map.SuspendPassEdits, map, reason) end

	local ok_set = pcall(function()
		for i = 1, #boxes do
			-- The engine editor's own force-passable brush performs SetPassableBox(true) alone.
			-- Retain the older explicit impassable-clear as a config fallback.
			if has_set_impassable and not single_write then editor_api.SetImpassableBox(boxes[i], false) end
			editor_api.SetPassableBox(boxes[i], true)
		end
	end)
	local ok_rebuild = true
	if has_rebuild and not defer_rebuild then
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
		"ForceFramePassable: source=%sx%s map=%sx%s bridge=%s set_impassable=%s single_write=%s rebuild=%s deferred=%s ok_set=%s ok_rebuild=%s",
		tostring(source_width), tostring(source_height), tostring(map_width), tostring(map_height),
		tostring(bridge), tostring(has_set_impassable), tostring(single_write), tostring(has_rebuild), tostring(defer_rebuild),
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

-- TERRAIN SPIKE AUDIT (config DEBUG_SPIKES, scope "Spikes"). The entrance "spike crown"
-- artifact persisted even after the entrance pads were PROVEN clean at generation end
-- (post-gen re-level read back the exact leveled z) -- so some LATER pipeline stage creates
-- it, or it is on the other map. This audit samples the height field on a coarse lattice
-- (~16k GetHeight calls, one long C burst) and logs the global min/max plus the TALLEST
-- samples with world coordinates. Called with a stage label at every stretch-pipeline step
-- on both maps: the first stage whose report shows the max exploding (and where) names the
-- culprit. Cheap enough to leave in while DEBUG_SPIKES is on.
local function SpikeAudit(map, label)
	if not cfg_bool("DEBUG_SPIKES", false) then return end
	map = map or Global("CurrentMap")
	local terrain_api = Global("terrain")
	local point_fn = Global("point")
	if not (map and type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function"
		and type(point_fn) == "function") then
		return
	end
	local w, h
	if type(terrain_api.GetMapSize) == "function" then
		local ok, ww, hh = pcall(terrain_api.GetMapSize, map)
		if ok then w, h = ww, hh end
	end
	if not (type(w) == "number" and w > 0) then
		local mapdata = map.mapdata
		local tile = 100
		local const_tbl = Global("const")
		if type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number" then
			tile = const_tbl.HeightTileSize
		end
		w = (type(mapdata) == "table" and type(mapdata.Width) == "number") and mapdata.Width * tile or nil
		h = (type(mapdata) == "table" and type(mapdata.Height) == "number") and mapdata.Height * tile or w
	end
	if not w then return end
	h = h or w
	local step = math.max(1, math.floor(w / 128)) -- 128x128 lattice
	local zmin, zmax
	local top = {} -- top-8 tallest samples { z, x, y }
	local function consider(z, x, y)
		if zmin == nil or z < zmin then zmin = z end
		if zmax == nil or z > zmax then zmax = z end
		if #top < 8 then
			top[#top + 1] = { z = z, x = x, y = y }
			table.sort(top, function(a, b) return a.z > b.z end)
		elseif z > top[#top].z then
			top[#top] = { z = z, x = x, y = y }
			table.sort(top, function(a, b) return a.z > b.z end)
		end
	end
	local y = 0
	while y < h do
		local x = 0
		while x < w do
			local ok_h, z = pcall(terrain_api.GetHeight, map, point_fn(x, y))
			if ok_h and type(z) == "number" then consider(z, x, y) end
			x = x + step
		end
		y = y + step
	end
	local parts = {}
	for _, t in ipairs(top) do
		parts[#parts + 1] = string.format("z=%d@(%d,%d)", t.z, t.x, t.y)
	end
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Spikes", "audit " .. tostring(label), {
			map = tostring(map.name), z_min = tostring(zmin), z_max = tostring(zmax),
			step = step, tallest = table.concat(parts, " "),
		})
	end
end

-- FINE spike scan (config DEBUG_SPIKES): dense sampling around a point. The map-wide
-- SpikeAudit lattice (step ~6400) is blind to 1-2-cell needles (a needle is ~100-200 wu
-- wide); this scans a small area at 400-wu steps -- used around each entrance in the timed
-- ground-truth dumps to prove or disprove thin needles the coarse audit misses.
local function FineSpikeScan(map, cx, cy, radius, step, label)
	if not cfg_bool("DEBUG_SPIKES", false) then return end
	map = map or Global("CurrentMap")
	local terrain_api = Global("terrain")
	local point_fn = Global("point")
	if not (map and type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function"
		and type(point_fn) == "function" and type(cx) == "number" and type(cy) == "number") then
		return
	end
	radius = radius or 12000
	step = step or 400
	local zmin, zmax
	local top = {}
	local y = cy - radius
	while y <= cy + radius do
		local x = cx - radius
		while x <= cx + radius do
			local ok, z = pcall(terrain_api.GetHeight, map, point_fn(x, y))
			if ok and type(z) == "number" then
				if zmin == nil or z < zmin then zmin = z end
				if zmax == nil or z > zmax then zmax = z end
				if #top < 5 then
					top[#top + 1] = { z = z, x = x, y = y }
					table.sort(top, function(a, b) return a.z > b.z end)
				elseif z > top[#top].z then
					top[#top] = { z = z, x = x, y = y }
					table.sort(top, function(a, b) return a.z > b.z end)
				end
			end
			x = x + step
		end
		y = y + step
	end
	local parts = {}
	for _, t in ipairs(top) do
		parts[#parts + 1] = string.format("z=%d@(%d,%d)", t.z, t.x, t.y)
	end
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Spikes", "fine scan " .. tostring(label), {
			map = tostring(map.name), center = tostring(cx) .. "," .. tostring(cy),
			radius = radius, step = step,
			z_min = tostring(zmin), z_max = tostring(zmax),
			spread = tostring(zmin and zmax and (zmax - zmin)),
			tallest = table.concat(parts, " "),
		})
	end
end

-- Public API: terrain/grid copy + mirror-block mechanics consumed by sbm_map_generation.
local TerrainCopy = {
	SpikeAudit = SpikeAudit,
	FineSpikeScan = FineSpikeScan,
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
	MoveEntranceVisualsToScale = MoveEntranceVisualsToScale,
	BeginDeferredElevatorMigration = BeginDeferredElevatorMigration,
	RestoreDeferredElevatorMigration = RestoreDeferredElevatorMigration,
	AuditFloatingObjects = AuditFloatingObjects,
	AnnotateDecorRelief = AnnotateDecorRelief,
	ClearDecorRelief = ClearDecorRelief,
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

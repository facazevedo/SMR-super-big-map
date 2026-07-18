-- Super Big Map -- stretch-only terrain expansion.
--
-- Owns proportional terrain-grid resampling, decoration/marker/entrance transforms,
-- stretch-specific correction passes, renderer refresh, and sector-geometry lookups.
-- Object classification and generic enrichment cloning live in sbm_object_clone.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local IsKindOfSafe = Engine.IsKindOf
local ObjectPosition = Engine.ObjectPos

local function cfg_bool(key, default)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "boolean" then
		return value
	end
	return default
end

local function LoadingBegin(name, map, data)
	local diagnostics = SuperBigMap.Diagnostics
	return diagnostics and type(diagnostics.LoadingBegin) == "function"
		and diagnostics.LoadingBegin(name, map, data) or false
end

local function LoadingEnd(token, data, ok)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.LoadingEnd) == "function" then
		diagnostics.LoadingEnd(token, data, ok)
	end
end

local function LoadingStep(name, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.LoadingStep) == "function" then
		diagnostics.LoadingStep(name, data, map)
	end
end

local function EntranceAudit(event, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.Elevator) == "function" then
		diagnostics.Elevator(event, data, map)
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

-- Object-side helpers live in sbm_object_clone (loaded first).
local ObjectClone = SuperBigMap.ObjectClone
assert(type(ObjectClone) == "table",
	"sbm_terrain_copy: SuperBigMap.ObjectClone missing -- load sbm_object_clone before this file")
local ShouldSkipObject = ObjectClone.ShouldSkipObject
local IsImportantSectorObject = ObjectClone.IsImportantSectorObject
local CloneObjectAtOffset = ObjectClone.CloneObjectAtOffset
assert(type(ShouldSkipObject) == "function" and type(CloneObjectAtOffset) == "function"
	and type(IsImportantSectorObject) == "function",
	"sbm_terrain_copy: required ObjectClone helpers missing (check sbm_object_clone exports)")

-- Re-invalidate the entire terrain so the renderer re-streams height and texture
-- across the expanded terrain. Called from the lifecycle PostNewMapLoaded hook
-- as a second-chance refresh: if the MapGenerated-time invalidation didn't take
-- effect (e.g. the renderer wasn't ready, or the engine clamped the invalidate
-- bbox to the original PlayArea), this pass forces the texture/height to
-- re-render across the whole expanded map. Safe to call repeatedly.
-- Full-map invalidation bbox in WORLD units, or false if the engine box() ctor
-- is unavailable (some calls then fall back to a whole-map invalidate).
local function FullMapInvalidateBox(map_width, map_height)
	local box_fn = Global("box")
	if type(box_fn) ~= "function" then
		return false
	end
	return box_fn(0, 0, map_width, map_height)
end

-- Repaint/refresh the expanded terrain: the renderer may not stream textures into the expanded area
-- until terrain is explicitly invalidated. Called after map generation and again
-- on load (save preserves grid data but not the renderer's streamed state).
local function ReinvalidateExpandedTerrain(map)
	local terrain_api = Global("terrain")
	if type(terrain_api) ~= "table" then
		return false
	end
	local map_width, map_height = TerrainSize(map)
	if not map_width or map_width <= 0 or not map_height or map_height <= 0 then
		return false
	end

	-- Detect "this map was expanded by the mod" without relying on transient
	-- per-map markers (SuperBigMapSourceWidthTiles etc.), which are set during
	-- generation but NOT persisted in a save. The reliable indicator is the
	-- ratio between map.Width (world units) and mapdata.Width (tile units): on a
	-- vanilla map both report 4096/4096 -> 100 wu/tile. On an expanded map the
	-- mapdata stays at the .fpk's native tile count while map.Width covers the
	-- expanded world extent (e.g. mapdata=6144 but map.Width=819200, ratio 133),
	-- OR the mapdata itself was forced larger (e.g. 8192 mapdata for an 8192
	-- map.Width). Both cases produce a wider map than the native source would
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
		return false
	end

	local invalidate_box = FullMapInvalidateBox(map_width, map_height)
	map.SuperBigMapRevalidationRebuiltGrids = false

	-- RebuildGrids is the editor's authoritative post-height-edit entry point. It already
	-- invalidates terrain and rebuilds passability/buildable/water/object-Z state, so running
	-- InvalidateHeight + InvalidateType + RebuildPassability immediately before it duplicates
	-- the most expensive work. Keep the old sequence as a fail-safe fallback.
	local consolidated = cfg_bool("OPTIMIZE_STRETCH_REVALIDATION", true)
		and type(map.RebuildGrids) == "function" and invalidate_box
	local consolidated_ok = false
	if consolidated then
		consolidated_ok = pcall(map.RebuildGrids,
			map, invalidate_box) == true
		-- Engine methods commonly return nil on success; pcall success is the signal. The helper
		-- returns pcall's boolean first, so consolidated_ok is true even with a nil method result.
		if consolidated_ok then
			map.SuperBigMapRevalidationRebuiltGrids = true
			-- Preserve the explicit vanilla border repair. It is kept outside the consolidated
			-- call because RebuildGrids does not consistently repair it on expanded terrain.
			if type(terrain_api.FixHeightBorder) == "function" then
				pcall(terrain_api.FixHeightBorder,
					map, invalidate_box)
			end
		end
	end
	if not consolidated_ok then
		if type(terrain_api.InvalidateHeight) == "function" then
			if invalidate_box then
				pcall(terrain_api.InvalidateHeight, map, invalidate_box)
			else
				pcall(terrain_api.InvalidateHeight, map)
			end
		end
		if type(terrain_api.InvalidateType) == "function" then
			if invalidate_box then
				pcall(terrain_api.InvalidateType, map, invalidate_box)
			else
				pcall(terrain_api.InvalidateType, map)
			end
		end
		if type(terrain_api.RebuildPassability) == "function" then
			if invalidate_box then
				pcall(terrain_api.RebuildPassability, map, invalidate_box)
			else
				pcall(terrain_api.RebuildPassability, map)
			end
		end
		if type(terrain_api.FixHeightBorder) == "function" and invalidate_box then
			pcall(terrain_api.FixHeightBorder, map, invalidate_box)
		end
		if type(map.RebuildGrids) == "function" and invalidate_box then
			local rebuild_ok = pcall(map.RebuildGrids, map, invalidate_box)
			if rebuild_ok == true then map.SuperBigMapRevalidationRebuiltGrids = true end
		end
	end
	-- HashGrids rolls the engine's terrain-hash, which some systems poll to
	-- detect "terrain changed, redraw me" (e.g. clutter, decals). If present,
	-- bumping the hash should kick anything still cached.
	if type(terrain_api.HashGrids) == "function" then
		pcall(terrain_api.HashGrids, map)
	end
	return true
end


-- Sector geometry helpers used by stretch-time start-sector and entrance handling.
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

-- Resample one EDITOR MapGrid (colour / biome / clutter / grass) from the source region (from_box)
-- up to the full map (to_box). These are compute-backed grids, so editor.GetGrid returns a
-- resample-able grid directly (unlike the NATIVE height/type grids, which need the terrain API and
-- assert in GridResample). GridToCompute guards the odd case. Destination dimensions come from
-- GetGridRef and the source sub-grid supplies the same storage format, avoiding a discarded
-- full-map GetGrid copy. The old full read remains as a compatibility fallback. Returns success.
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
	-- GetGrid(from_box) is ALWAYS safe: the source region is within any grid's coverage.
	local ok_s, src = pcall(editor_api.GetGrid, map, name, from_box)
	if not ok_s or not src then
		return false
	end
	-- SIZE GUARD: some MapGrids (e.g. BiomeGrid) are allocated only for the generated SOURCE region,
	-- NOT the full expanded map. GetGrid(to_box = full) on such a grid overflows its storage and
	-- trips a C assert (dtGrid.h: x2 <= src.m_width) that pcall CANNOT catch. Detect it without
	-- issuing the bad read: for a FULL-map grid the source sub-grid is ~frac of the ref; for a
	-- SOURCE-sized grid it is ~all of it. If the source region already fills most of the grid, the
	-- grid does not cover the full map -> skip (leaving it source-only rather than asserting).
	local function grid_size(g)
		if not g or type(g.size) ~= "function" then return nil, nil end
		local ok, w, h = pcall(function() return g:size() end)
		if not ok or type(w) ~= "number" or type(h) ~= "number" then return nil, nil end
		return w, h
	end
	local function grid_format(g)
		if not g or type(IsComputeGrid) ~= "function" then return nil, nil end
		local ok, fmt, bits = pcall(IsComputeGrid, g)
		if not ok then return nil, nil end
		return fmt, bits
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
	local ref_w, ref_h = grid_size(ref)
	local src_w = grid_size(src)
	if type(ref_w) == "number" and ref_w > 0 and type(src_w) == "number"
		and src_w > ref_w * (frac + 1.0) / 2 then
		free_grid(src)
		return false
	end
	local dw, dh = ref_w, ref_h
	local target_fmt, target_bits = grid_format(ref)
	if not target_fmt then target_fmt, target_bits = grid_format(src) end
	local dst_ref
	local metadata_source = "grid_ref"
	-- A nil format is valid for ordinary/hierarchical grids: the old path also saw nil from
	-- IsComputeGrid(dst_ref) and skipped GridRepack. Read the full destination only when its
	-- dimensions are unavailable from GetGridRef.
	if type(dw) ~= "number" or dw <= 0 or type(dh) ~= "number" or dh <= 0 then
		local ok_d
		ok_d, dst_ref = pcall(editor_api.GetGrid, map, name, to_box)
		if not ok_d or not dst_ref then
			free_grid(src)
			return false
		end
		dw, dh = grid_size(dst_ref)
		if not target_fmt then target_fmt, target_bits = grid_format(dst_ref) end
		metadata_source = "full_destination_fallback"
	end
	local ok_all, res = pcall(function()
		local src_c = GridToCompute(src)
		local stretched = GridResample(src_c, dw, dh, interpolate == true)
		local out = stretched
		local stretched_fmt, stretched_bits = grid_format(stretched)
		if type(GridRepack) == "function" and target_fmt
			and (stretched_fmt ~= target_fmt or stretched_bits ~= target_bits) then
			out = GridRepack(stretched, target_fmt, target_bits)
		end
		local ok_set = pcall(editor_api.SetGrid, map, name, out, to_box)
		if src_c ~= src then free_grid(src_c) end
		if out ~= stretched then free_grid(out) end
		free_grid(stretched)
		return ok_set == true
	end)
	free_grid(dst_ref)
	free_grid(src)
	return ok_all and res == true
end

-- True once BiomeGrid has been resized to the full expanded map. Same source-vs-ref size test as the ResampleMapGrid guard: for a full-map grid the
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

-- Resample the generated source terrain up to the full destination as one continuous terrain. Features come out
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
		return false
	end
	if mapdata.SuperBigMapHeightRangesScaled == true then
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
			return
		end
		local from0, to0 = range.from, range.to
		range.from = scale_out(from0, false)
		range.to = scale_out(to0, true)
	end
	-- mapdata is a shared preset and survives Map destruction. Preserve the exact
	-- vanilla ranges so the next non-expanded game does not inherit stretched-height
	-- bounds from the previous expanded session.
	if mapdata.SuperBigMapOriginalHeightRangesCaptured ~= true then
		mapdata.SuperBigMapOriginalHeightRangesCaptured = true
		if type(mapdata.visible_height_range) == "table" then
			mapdata.SuperBigMapOriginalVisibleHeightFrom = mapdata.visible_height_range.from
			mapdata.SuperBigMapOriginalVisibleHeightTo = mapdata.visible_height_range.to
		end
		if type(mapdata.playable_height_range) == "table" then
			mapdata.SuperBigMapOriginalPlayableHeightFrom = mapdata.playable_height_range.from
			mapdata.SuperBigMapOriginalPlayableHeightTo = mapdata.playable_height_range.to
		end
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

local function StretchSourceToFull(map)
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
		return false, 0
	end
	if full_tw <= sw_tiles and full_th <= sh_tiles then
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
	-- write back via set_fn (+ invalidate). Extract the corner in the raw/native format BEFORE
	-- GridToCompute so only the 6144^2 source cells are converted instead of all 8192^2 cells.
	-- The original full-grid conversion remains the compatibility fallback. The 'raw' grid from
	-- get_fn is left for the engine.
	local function stretch_one(label, get_fn, set_fn, invalidate_fn, interpolate, scale_values)
		local grid_token = LoadingBegin("terrain grid stretch: " .. tostring(label), map, {
			interpolate = tostring(interpolate == true),
			scale_values = tostring(scale_values == true),
		})
		if type(get_fn) ~= "function" or type(set_fn) ~= "function" then
			LoadingEnd(grid_token, { error = "terrain getter/setter unavailable" }, false)
			return false
		end
		local ok_g, raw = pcall(get_fn, map)
		if not ok_g or not raw then
			LoadingEnd(grid_token, { error = "terrain getter failed" }, false)
			return false
		end
		local measured_fw, measured_fh
		local extraction_path = "unknown"
		local ok_all, res = pcall(function()
			local full_c
			local ok_size, fw, fh = pcall(function() return raw:size() end)
			if not ok_size or type(fw) ~= "number" or type(fh) ~= "number" then
				full_c = GridToCompute(raw)
				fw, fh = full_c:size()
				extraction_path = "full_grid_compute_fallback"
			end
			measured_fw, measured_fh = fw, fh
			local scw = math.max(1, math.min(fw, math.floor(fw * frac_w + 0.5)))
			local sch = math.max(1, math.min(fh, math.floor(fh * frac_h + 0.5)))
			local src_sub, native_sub
			if not full_c and type(raw.new_instance) == "function" then
				local ok_corner = pcall(function()
					native_sub = raw:new_instance(scw, sch)
					if not native_sub or type(native_sub.copyrect) ~= "function" then
						error("native corner grid/copyrect unavailable")
					end
					native_sub:copyrect(raw, box_fn(0, 0, scw, sch), point_fn(0, 0))
					src_sub = GridToCompute(native_sub)
					if not src_sub then error("native corner GridToCompute failed") end
				end)
				if not ok_corner then
					if src_sub and src_sub ~= native_sub then free_grid(src_sub) end
					src_sub = nil
					free_grid(native_sub)
					native_sub = nil
				else
					extraction_path = "native_corner_then_compute"
				end
			end
			if not src_sub then
				full_c = full_c or GridToCompute(raw)
				extraction_path = "full_grid_compute_then_corner"
				local fmt, bits = IsComputeGrid(full_c)
				src_sub = NewComputeGrid(scw, sch, fmt, bits)
				src_sub:copyrect(full_c, box_fn(0, 0, scw, sch), point_fn(0, 0))
			end
			if native_sub and src_sub ~= native_sub then
				free_grid(native_sub)
				native_sub = nil
			end
			local fmt, bits = IsComputeGrid(src_sub)
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
					if type(min0) == "number" and type(max0) == "number" and max0 > min0 and cap then
						local shift = cfg_bool("STRETCH_SHIFT_HEIGHTS_DOWN", true)
						if shift and cfg_bool("STRETCH_ADAPTIVE_Z_SCALE", true)
							and (max0 - min0) * zmul / zdiv + FLOOR_MARGIN > cap then
							zmul, zdiv = cap - FLOOR_MARGIN, max0 - min0
						end
						if shift then
							zadd = FLOOR_MARGIN - math.floor(min0 * zmul / zdiv)
						end
					end
					pcall(grid_muldivadd, stretched, zmul, zdiv, zadd)
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
					if cap and ((type(max1) == "number" and max1 > cap) or (type(min1) == "number" and min1 < 0)) then
						local grid_clamp = Global("GridClamp")
						if type(grid_clamp) == "function" then
							pcall(grid_clamp, stretched, 0, cap)
						end
					end
				end
			end
			local ok_set = pcall(set_fn, map, stretched)
			if type(invalidate_fn) == "function" then pcall(invalidate_fn, map) end
			free_grid(src_sub)
			if stretched ~= src_sub then free_grid(stretched) end
			if full_c ~= raw then free_grid(full_c) end
			return ok_set == true
		end)
		local success = ok_all and res == true
		LoadingEnd(grid_token, {
			full_cells = tostring(measured_fw) .. "x" .. tostring(measured_fh),
			extraction_path = extraction_path,
			error = ok_all and "" or tostring(res),
		}, success)
		return success
	end

	local done = 0
	if stretch_one("height", terrain_api.GetHeightGrid, terrain_api.SetHeightGrid,
		terrain_api.InvalidateHeight, true, true) then
		done = done + 1
		-- Height VALUES just transformed (h*zmul/zdiv + zadd, stamped by stretch_one) -> the
		-- declared buildable/playable height ranges must follow the SAME affine transform
		-- before any buildable rebuild.
		ScaleHeightRanges(map,
			map.SuperBigMapZScaleMul or full_tw,
			map.SuperBigMapZScaleDiv or sw_tiles,
			map.SuperBigMapZScaleAdd or 0)
	end
	if stretch_one("type", terrain_api.GetTypeGrid, terrain_api.SetTypeGrid,
		terrain_api.InvalidateType, false) then done = done + 1 end
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
				local grid_token = LoadingBegin("terrain map grid stretch: " .. mg.name, map,
					{ interpolate = tostring(mg.interp == true) })
				local grid_ok = ResampleMapGrid(map, mg.name, src_box, full_box, mg.interp)
				LoadingEnd(grid_token, nil, grid_ok)
				if grid_ok then done = done + 1 end
			end
		end
	end
	local invalidate_token = LoadingBegin("invalidate expanded terrain", map)
	ReinvalidateExpandedTerrain(map)
	LoadingEnd(invalidate_token, nil, true)
	LoadingStep("terrain stretch grid suite complete", {
		completed_grids = done,
		source_tiles = tostring(sw_tiles) .. "x" .. tostring(sh_tiles),
		destination_tiles = tostring(full_tw) .. "x" .. tostring(full_th),
	}, map)
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
	local annotated = 0
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
	end)
	decor_relief_by_map[map] = relief
	if cfg_bool("OPTIMIZE_STRETCH_DECOR_TRAVERSAL", true) then
		decor_objects_by_map[map] = objects
	end
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
-- Returns the number of decorations moved. When pass_edits_already_suspended is true, the
-- caller owns the balanced ResumePassEdits after this pass and any adjacent mass edits.
local function ScaleDecorationsToFull(map, pass_edits_already_suspended)
	local terrain_api_g = Global("terrain") -- for relief-aware Z placement
	if not map then return 0 end
	local const_tbl = Global("const")
	local hts = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number") and const_tbl.HeightTileSize or 1
	local box_fn = Global("box")
	local point_fn = Global("point")
	if type(box_fn) ~= "function" or type(point_fn) ~= "function" then
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

	local MAX_SCALE = 500 -- engine object-scale ceiling (percent)
	local full_wu = full_tw * hts
	local moved = 0
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
	-- BATCH passability edits around the mass move: without this every SetPos/SetScale runs its
			-- own local passability update; the engine's own mass-spawn code uses this
	-- exact Suspend/Resume idiom to batch the rebuild into ONE pass at Resume. The per-object
	-- bodies are pcall'd, so the loop cannot throw past the Resume below.
	local pass_batch = type(map.SuspendPassEdits) == "function" and type(map.ResumePassEdits) == "function"
	local owns_pass_batch = pass_batch and pass_edits_already_suspended ~= true
	if owns_pass_batch then pcall(map.SuspendPassEdits, map, "SuperBigMapStretchDecor") end
	local is_valid = Global("IsValid")
	for _, obj in ipairs(objs) do
		if not obj then
			-- nil entry, ignore
		elseif type(is_valid) == "function" and SafeCall(is_valid, obj) ~= true then
			-- The cached pre-stretch traversal includes enrichment markers that staging has since
			-- destroyed. Do not cross into any C object method through their stale Lua wrappers.
		elseif ShouldSkipObject(obj) then
		elseif IsImportantSectorObject(obj) then
		else
			pcall(function()
				local pos = ObjectPosition(obj)
				if not pos then return end
				local ox, oy = PointXY(pos)
				if type(ox) ~= "number" or type(oy) ~= "number" then return end
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
				end
				-- Grow the object to match the enlarged terrain features.
				if type(obj.GetScale) == "function" and type(obj.SetScale) == "function" then
					local s = SafeCall(obj.GetScale, obj)
					if type(s) == "number" and s > 0 then
						local ns = math.floor(s * scale_x + 0.5)
						if ns > MAX_SCALE then ns = MAX_SCALE elseif ns < 1 then ns = 1 end
						SafeCall(obj.SetScale, obj, ns)
					end
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
					end
				end
			end)
		end
	end
	if owns_pass_batch then
		pcall(map.ResumePassEdits, map, "SuperBigMapStretchDecor")
	end
	return moved
end

-- STRETCH step 3 (markers): move the generated DEPOSIT / ANOMALY / EFFECT markers (and any
-- already-spawned deposits/anomalies, e.g. the start sector's revealed ones) to their scaled spot
-- on the stretched terrain -- the same position * (full/source) transform as the decorations.
-- Without this they stay clustered in the source corner. Positions only: marker SIZE is gameplay
-- (scan radius/visuals), so scale is left untouched. Gated on config STRETCH_SCALE_MARKERS.
local function ScaleMarkersToFull(map, _, pass_edits_already_suspended)
	if not map or not cfg_bool("STRETCH_SCALE_MARKERS", true) then return 0 end
	local const_tbl = Global("const")
	local hts = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number") and const_tbl.HeightTileSize or 1
	local box_fn = Global("box")
	local point_fn = Global("point")
	local world_to_hex = Global("WorldToHex")
	local hex_to_world = Global("HexToWorld")
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
		return 0
	end
	local scale_x = (full_tw + 0.0) / sw_tiles
	local scale_y = (full_th + 0.0) / sh_tiles
	local source_origin_x = tonumber(map.SuperBigMapSourceX) or 0
	local source_origin_y = tonumber(map.SuperBigMapSourceY) or 0
	local src_box = box_fn(0, 0, sw_tiles * hts, sh_tiles * hts)
	local function is_marker(obj)
		return IsImportantSectorObject(obj) -- resource deposit markers (surface/subsurface/terrain)
			or IsKindOfSafe(obj, "Deposit")
			or IsKindOfSafe(obj, "SubsurfaceAnomaly")
			or IsKindOfSafe(obj, "SubsurfaceAnomalyMarker")
			or IsKindOfSafe(obj, "EffectDepositMarker")
			-- Tunnel/entrance MARKERS move with the stretch on BOTH maps (user-confirmed design):
			-- vanilla generates the surface and underground natural entrances at IDENTICAL native
			-- coordinates, so applying the identical x(full/source) transform to both
			-- sides keeps every entrance pair vertically corresponding AND sitting on the terrain
			-- feature it was generated on. The visible structures follow in
			-- MoveEntranceVisualsToScale (STRETCH_MOVE_ENTRANCE_VISUALS).
			or IsKindOfSafe(obj, "SurfaceUndergroundTunnelMarker")
			-- PlaceArtefacts keeps these markers alive when underground wonders are deferred.
			-- They must receive the identical transform before the assigned wonder is materialized.
			or IsKindOfSafe(obj, "BuriedWonderMarker")
	end
	local objs = {}
	if type(map.MapForEach) == "function" then
		pcall(map.MapForEach, map, src_box, "CObject", function(o) objs[#objs + 1] = o end)
	end
	local moved = 0
	-- Sector marker REGISTRIES: each MapSector keeps per-sector marker lists (sector.markers.*)
	-- that vanilla Scan reveals from. A moved marker must be re-registered from its old sector to
	-- its new one, or scanning the new sector misses it (and scanning the old one reveals a marker
	-- that is no longer there). Re-register it with the sector containing the final coordinate.
	local city = map.City
	local get_sector = Global("GetMapSectorXY")
	-- Batch passability edits around the mass marker move (same idiom/reason as the decor pass).
	local pass_batch = type(map.SuspendPassEdits) == "function" and type(map.ResumePassEdits) == "function"
	local owns_pass_batch = pass_batch and pass_edits_already_suspended ~= true
	if owns_pass_batch then pcall(map.SuspendPassEdits, map, "SuperBigMapStretchMarkers") end
	for _, obj in ipairs(objs) do
		if obj and is_marker(obj) then
			pcall(function()
				-- Temporary-source enrichments are recreated directly at their final scaled hex after
				-- terrain stretching. Do not apply the proportional transform a second time; the same
				-- pass must still move entrance markers and any already-spawned live deposits.
				if obj.SuperBigMapNativeRecreatedAtFinal == true then
					return
				end
				local pos = ObjectPosition(obj)
				if not pos then return end
				local ox, oy = PointXY(pos)
				if type(ox) ~= "number" or type(oy) ~= "number" then return end
				local capture_owner = obj
				if type(capture_owner.SuperBigMapNativeSourceX) ~= "number"
					and type(obj.marker) == "table"
					and type(obj.marker.SuperBigMapNativeSourceX) == "number" then
					capture_owner = obj.marker
				end
				local source_x = type(capture_owner.SuperBigMapNativeSourceX) == "number"
					and capture_owner.SuperBigMapNativeSourceX or ox
				local source_y = type(capture_owner.SuperBigMapNativeSourceY) == "number"
					and capture_owner.SuperBigMapNativeSourceY or oy
				local oz = type(capture_owner.SuperBigMapNativeSourceZ) == "number"
					and capture_owner.SuperBigMapNativeSourceZ or nil
				if oz == nil then pcall(function() oz = pos:z() end) end
				local raw_nx = math.floor(source_origin_x
					+ (source_x - source_origin_x) * scale_x + 0.5)
				local raw_ny = math.floor(source_origin_y
					+ (source_y - source_origin_y) * scale_y + 0.5)
				local nx, ny = raw_nx, raw_ny
				local captured_native = type(capture_owner.SuperBigMapNativeSourceX) == "number"
					and type(capture_owner.SuperBigMapNativeSourceY) == "number"
				if captured_native and type(world_to_hex) == "function"
					and type(hex_to_world) == "function" then
					local ok_h, q, r = pcall(world_to_hex, point_fn(raw_nx, raw_ny))
					if ok_h and type(q) == "number" and type(r) == "number" then
						local ok_w, aligned_x, aligned_y = pcall(hex_to_world, q, r)
						if ok_w and type(aligned_x) == "number" and type(aligned_y) == "number" then
							nx, ny = aligned_x, aligned_y
						end
					end
					capture_owner.SuperBigMapRawStretchedX = raw_nx
					capture_owner.SuperBigMapRawStretchedY = raw_ny
					capture_owner.SuperBigMapExpectedStretchedX = nx
					capture_owner.SuperBigMapExpectedStretchedY = ny
				end
				local np = type(oz) == "number" and point_fn(nx, ny, oz) or point_fn(nx, ny)
				if cfg_bool("EXPANSION_STEP_09_RESNAP_ENRICHMENT_Z", true)
					and type(np.SetTerrainZ) == "function" then
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
							end
						end
					end
				end
			end)
		end
	end
	if owns_pass_batch then
		pcall(map.ResumePassEdits, map, "SuperBigMapStretchMarkers")
	end
	return moved
end

-- STRETCH step 3b (entrance visuals): the decoration pass deliberately skips live
-- underground-access objects, so this pass applies the same proportional transform separately.
--
-- DEFERRED ELEVATOR MIGRATION:
-- A surface Elevator can be instant-completed before deferred underground expansion while its
-- underground half is still a ConstructionSite. Completion destroys the surface site, leaving
-- the underground site's linked_obj as a stale Lua table; moving that site later also carries
-- stale construction/build-grid state. Snapshot those pairs, remove ONLY the pending underground
-- site with DoneObject (never Cancel/RestoreTerrain), then rebuild a finished underground half
-- after terrain + buildability are final. The correctly placed surface Elevator is untouched.
-- The rebuilt half must also receive the tail of ConstructionSite:Complete's vanilla lifecycle;
-- merely calling PlaceBuildingIn creates a Building object but omits QuickBuildSetup and the
-- ConstructionComplete message, which can leave the two halves at observably different stages.
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
			end
		else
			local surface_site = IsLiveGameObject(surface_passage)
				and surface_passage.elevator_construction or nil
			-- Preserve the authoritative underground snap target across the stretch. Once the
			-- passage has moved, a nearest search from this site's old coordinates can select the
			-- wrong entrance, while linked_obj points to the intentionally offset surface site.
			if IsElevatorConstructionSite(surface_site) then
				site.SuperBigMapDeferredElevatorPassage = passage
			end
		end
	end
	return records
end

local function CheckElevatorRestoreTransaction(transaction_guard, stage, map, bld, record, index)
	if type(transaction_guard) ~= "function" then return true end
	local ok, allowed, why = pcall(transaction_guard, stage, map, bld, record, index)
	if not ok then
		error("underground Elevator transaction guard failed at " .. tostring(stage)
			.. ": " .. tostring(allowed))
	end
	if allowed ~= true then
		error("underground Elevator transaction rejected at " .. tostring(stage)
			.. ": " .. tostring(why or allowed))
	end
	return true
end

local function RestoreDeferredElevatorMigration(map, records, reason, transaction_guard)
	if type(records) ~= "table" or #records == 0 then return 0 end
	local point_fn = Global("point")
	local place_building = Global("PlaceBuildingIn")
	local msg = Global("Msg")
	if type(point_fn) ~= "function" or type(place_building) ~= "function"
		or type(msg) ~= "function" then
		error("deferred Elevator migration cannot rebuild finished underground counterparts")
	end
	local restored = 0
	for i, record in ipairs(records) do
		if not record.restored then
			CheckElevatorRestoreTransaction(transaction_guard, "before-record", map, nil, record, i)
			-- Vanilla constructs the underground half on its linked underground passage/imprint.
			-- The surface entrance may have been shifted to nearby buildable terrain, so its XY is
			-- deliberately not authoritative for underground placement.
			local passage = record.underground_passage
			local passage_pos = IsLiveGameObject(passage) and ObjectPosition(passage) or nil
			local passage_x, passage_y = PointXY(passage_pos)
			if type(passage_x) ~= "number" or type(passage_y) ~= "number" then
				error("deferred Elevator migration lost underground passage " .. tostring(i))
			end
			local terrain_before = ElevatorTerrainFingerprint(map, passage_x, passage_y)
			local target = point_fn(passage_x, passage_y)
			if type(target.SetTerrainZ) == "function" then
				local snapped = SafeCall(target.SetTerrainZ, target, map)
				if snapped then target = snapped end
			end
			local instance = {
				city = map.City,
				name = record.name,
			}
			-- Seed the generation token into the object instance before PlaceObject/PlaceBuildingIn.
			-- GameInit is normally deferred, but this closes the lifecycle boundary even if a future
			-- engine build initializes supply elements during construction.
			CheckElevatorRestoreTransaction(transaction_guard, "before-create", map,
				instance, record, i)
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
			CheckElevatorRestoreTransaction(transaction_guard, "after-create", map, bld, record, i)
			local passage_angle = type(passage.GetAngle) == "function"
				and SafeCall(passage.GetAngle, passage) or record.angle or 0
			if type(bld.SetAngle) == "function" then SafeCall(bld.SetAngle, bld, passage_angle) end
			if type(bld.SetPos) == "function" then SafeCall(bld.SetPos, bld, target) end
			CheckElevatorRestoreTransaction(transaction_guard, "after-position", map, bld, record, i)
			CheckElevatorRestoreTransaction(transaction_guard, "before-apply-grids", map, bld, record, i)
			if type(bld.ApplyToGrids) == "function" then SafeCall(bld.ApplyToGrids, bld) end
			if record.user_include_in_lrt ~= nil then bld.user_include_in_lrt = record.user_include_in_lrt end

			-- Match the final steps of ConstructionSite:Complete("quick_build"). PlaceBuildingIn
			-- already performed the vanilla object creation above; these are the completion steps
			-- that distinguish a fully quick-built building from a directly spawned one.
			local quick_build_setup = false
			if type(bld.HasMember) == "function"
				and SafeCall(bld.HasMember, bld, "QuickBuildSetup") == true
				and type(bld.Notify) == "function" then
				local ok_notify, notify_err = pcall(bld.Notify, bld, "QuickBuildSetup")
				if not ok_notify then
					error("underground Elevator QuickBuildSetup failed: " .. tostring(notify_err))
				end
				quick_build_setup = true
			end
			CheckElevatorRestoreTransaction(transaction_guard, "before-construction-complete",
				map, bld, record, i)
			local ok_complete, complete_err = pcall(msg, "ConstructionComplete", bld, false)
			if not ok_complete then
				error("underground Elevator ConstructionComplete failed: " .. tostring(complete_err))
			end
			CheckElevatorRestoreTransaction(transaction_guard, "after-construction-complete",
				map, bld, record, i)
			local terrain_after = ElevatorTerrainFingerprint(map, passage_x, passage_y)
			local terrain_unchanged = SameElevatorTerrainFingerprint(terrain_before, terrain_after)
			if not terrain_unchanged then
				error("rebuilding underground Elevator counterpart changed terrain at "
					.. tostring(passage_x) .. "," .. tostring(passage_y))
			end
			passage.elevator_construction = false
			record.rebuilt_elevator = bld
			record.restored = true
			restored = restored + 1
		end
	end
	return restored
end

-- Surface entrance signs and underground exit signs share the engine class
-- SurfaceUndergroundTunnelSign, but they are not the same placement concept. A surface sign uses a
-- safe badge position beside the entrance footprint. An underground SurfaceTunnelMarker owns the
-- native SignUnderground symbol and that symbol stays on the authoritative SurfacePassage hex.
-- Keep separate anchors so no badge-offset or badge-restoration rule can affect the underground
-- marker. Vanilla maps never receive either final anchor.
local ENTRANCE_BADGE_POSITION_PATCH_VERSION = 4
local ENTRANCE_BADGE_MARKER_CLASSES = {
	"SurfaceUndergroundTunnelMarker", "UndergroundTunnelMarker", "SurfaceTunnelMarker",
}

local function PositionXYZ(pos)
	local x, y = PointXY(pos)
	local z
	if pos and type(pos.z) == "function" then z = SafeCall(pos.z, pos) end
	return x, y, z
end

local function WriteEntranceBadgeAnchor(obj, x, y, z)
	if not obj then return end
	obj.SuperBigMapEntranceBadgeAnchorX = x
	obj.SuperBigMapEntranceBadgeAnchorY = y
	obj.SuperBigMapEntranceBadgeAnchorZ = z
	obj.SuperBigMapEntranceBadgeAnchorFinal = true
end

local function EntranceBadgeAnchor(marker, sign)
	local passage = marker and marker.spawner
	local objects = { [1] = marker, [2] = passage, [3] = sign }
	for i = 1, 3 do
		local obj = objects[i]
		if obj and obj.SuperBigMapEntranceBadgeAnchorFinal == true
			and type(obj.SuperBigMapEntranceBadgeAnchorX) == "number"
			and type(obj.SuperBigMapEntranceBadgeAnchorY) == "number" then
			return obj.SuperBigMapEntranceBadgeAnchorX, obj.SuperBigMapEntranceBadgeAnchorY,
				obj.SuperBigMapEntranceBadgeAnchorZ, obj
		end
	end
	return nil
end

local function EntranceBadgeMap(marker, sign)
	local objects = { [1] = sign, [2] = marker, [3] = marker and marker.spawner }
	for i = 1, 3 do
		local obj = objects[i]
		if obj and type(obj.GetMap) == "function" then
			local map = SafeCall(obj.GetMap, obj)
			if map then return map end
		end
	end
	return nil
end

local function IsUndergroundExitMarker(marker, sign)
	if not marker or not IsKindOfSafe(marker, "SurfaceTunnelMarker") then return false end
	local map = EntranceBadgeMap(marker, sign)
	return map and map.mapdata and map.mapdata.Environment == "Underground"
end

local function WriteUndergroundExitSignAnchor(obj, x, y, z)
	if not obj then return end
	obj.SuperBigMapUndergroundExitSignX = x
	obj.SuperBigMapUndergroundExitSignY = y
	obj.SuperBigMapUndergroundExitSignZ = z
	obj.SuperBigMapUndergroundExitSignFinal = true
end

local function UndergroundExitSignAnchor(marker, sign)
	local passage = marker and marker.spawner
	local objects = { [1] = marker, [2] = passage, [3] = sign }
	for i = 1, 3 do
		local obj = objects[i]
		if obj and obj.SuperBigMapUndergroundExitSignFinal == true
			and type(obj.SuperBigMapUndergroundExitSignX) == "number"
			and type(obj.SuperBigMapUndergroundExitSignY) == "number" then
			return obj.SuperBigMapUndergroundExitSignX, obj.SuperBigMapUndergroundExitSignY,
				obj.SuperBigMapUndergroundExitSignZ, obj
		end
	end
	return nil
end

local function EntranceBadgeTerrainZ(marker, sign, x, y)
	if type(x) ~= "number" or type(y) ~= "number" then return nil end
	local map = EntranceBadgeMap(marker, sign)
	local terrain_api = Global("terrain")
	local point_fn = Global("point")
	if not map or type(terrain_api) ~= "table" or type(terrain_api.GetHeight) ~= "function"
		or type(point_fn) ~= "function" then
		return nil
	end
	local ok, z = pcall(terrain_api.GetHeight, map, point_fn(x, y))
	if ok and type(z) == "number" then return z end
	return nil
end

local function CaptureEntranceBadgePosition(marker, sign, reason)
	if not marker or not sign then return false end
	local pos = ObjectPosition(sign)
	local x, y, z = PositionXYZ(pos)
	if type(x) ~= "number" or type(y) ~= "number" then return false end
	local terrain_z = EntranceBadgeTerrainZ(marker, sign, x, y)
	if type(terrain_z) == "number" then z = terrain_z end
	WriteEntranceBadgeAnchor(marker, x, y, z)
	WriteEntranceBadgeAnchor(marker.spawner, x, y, z)
	WriteEntranceBadgeAnchor(sign, x, y, z)
	local point_fn = Global("point")
	local snapped = false
	if type(z) == "number" and type(point_fn) == "function" and type(sign.SetPos) == "function" then
		snapped = pcall(sign.SetPos, sign, point_fn(x, y, z))
	end
	return true
end

local function CaptureUndergroundExitSignPosition(marker, sign, reason)
	if not IsUndergroundExitMarker(marker, sign) or not sign
		or type(sign.SetPos) ~= "function" then return false end
	local passage = marker.spawner
	local passage_pos = IsLiveGameObject(passage) and ObjectPosition(passage) or nil
	local x, y = PointXY(passage_pos)
	if type(x) ~= "number" or type(y) ~= "number" then return false end
	local z = EntranceBadgeTerrainZ(marker, sign, x, y)
	WriteUndergroundExitSignAnchor(marker, x, y, z)
	WriteUndergroundExitSignAnchor(passage, x, y, z)
	WriteUndergroundExitSignAnchor(sign, x, y, z)
	local point_fn = Global("point")
	if type(point_fn) ~= "function" then return false end
	local target = type(z) == "number" and point_fn(x, y, z) or point_fn(x, y)
	return pcall(sign.SetPos, sign, target)
end

local function RestoreEntranceBadgePosition(marker, sign, reason)
	if not marker or not sign or type(sign.SetPos) ~= "function" then return false end
	if IsUndergroundExitMarker(marker, sign) then
		local x = UndergroundExitSignAnchor(marker, sign)
		if type(x) == "number" then
			return CaptureUndergroundExitSignPosition(marker, sign, reason)
		end
		return false
	end
	local x, y, z = EntranceBadgeAnchor(marker, sign)
	if type(x) ~= "number" or type(y) ~= "number" then return false end
	local point_fn = Global("point")
	if type(point_fn) ~= "function" then return false end
	local terrain_z = EntranceBadgeTerrainZ(marker, sign, x, y)
	if type(terrain_z) == "number" then z = terrain_z end
	-- Update the carriers first: the SetPos lock wrapper reads this anchor while applying target.
	WriteEntranceBadgeAnchor(marker, x, y, z)
	WriteEntranceBadgeAnchor(marker.spawner, x, y, z)
	WriteEntranceBadgeAnchor(sign, x, y, z)
	local target = type(z) == "number" and point_fn(x, y, z) or point_fn(x, y)
	local ok = pcall(sign.SetPos, sign, target)
	return ok
end

local function RestoreEntranceBadgePositions(map, reason)
	if not map or type(map.MapForEach) ~= "function" then return 0 end
	local restored = 0
	pcall(map.MapForEach, map, "map", "SurfaceUndergroundTunnelSign", function(sign)
		local marker = sign and sign.tunnel_marker
		if RestoreEntranceBadgePosition(marker, sign, reason) then restored = restored + 1 end
	end)
	return restored
end

local function PatchEntranceBadgePosition()
	if not cfg_bool("EXPANSION_STEP_08_SCALE_NATIVE_ENRICHMENT_XY", false) then return false end
	local State = SuperBigMap.State or {}
	SuperBigMap.State = State
	State.entrance_badge_place_sign_originals = State.entrance_badge_place_sign_originals or {}
	State.entrance_badge_place_sign_wrappers = State.entrance_badge_place_sign_wrappers or {}
	local originals = State.entrance_badge_place_sign_originals
	local wrappers = State.entrance_badge_place_sign_wrappers
	local targets = {}
	for _, class_name in ipairs(ENTRANCE_BADGE_MARKER_CLASSES) do
		local cls = Engine.ClassTable and Engine.ClassTable(class_name)
		local current = type(cls) == "table" and cls.PlaceSign or nil
		if current == wrappers[class_name] and type(originals[class_name]) == "function" then
			-- Peel off the previous hot-reload wrapper before installing the current code.
			current = originals[class_name]
		end
		if type(cls) == "table" and type(current) == "function" then
			targets[#targets + 1] = { name = class_name, cls = cls, original = current }
		end
	end
	local installed = 0
	for _, target in ipairs(targets) do
		local class_name, cls, original = target.name, target.cls, target.original
		local wrapper = function(marker, ...)
			local result = original(marker, ...)
			local sign = marker and marker.tunnel_sign
			if sign then
				if IsUndergroundExitMarker(marker, sign) then
					CaptureUndergroundExitSignPosition(marker, sign,
						"PlaceSign underground exit:" .. class_name)
				else
					local x = EntranceBadgeAnchor(marker, sign)
					if type(x) == "number" then
						RestoreEntranceBadgePosition(marker, sign, "PlaceSign:" .. class_name)
					else
						local map = type(marker.GetMap) == "function" and SafeCall(marker.GetMap, marker) or nil
						if map and map.SuperBigMapExpanded == true then
							CaptureEntranceBadgePosition(marker, sign,
								"first post-expansion PlaceSign:" .. class_name)
						end
					end
				end
			end
			return result
		end
		originals[class_name] = original
		wrappers[class_name] = wrapper
		cls.PlaceSign = wrapper
		installed = installed + 1
	end

	-- DepositMarker:PlaceDeposit unconditionally calls placed_obj:SetPos(x, y, InvalidZ)
	-- after SpawnDeposit returns. For an underground entrance, placed_obj is the sign that
	-- PlaceSign just restored to its final terrain-seated side anchor, so that base-class write moves
	-- the badge to the marker and the later SectorScanned repair visibly moves it back. Once a
	-- badge has a final anchor, make SetPos itself preserve that exact XYZ. Calls made while a
	-- new sign is still being constructed remain untouched because no anchor has been copied to
	-- the sign yet.
	local sign_class = Engine.ClassTable and Engine.ClassTable("SurfaceUndergroundTunnelSign")
	local current_set_pos = type(sign_class) == "table" and sign_class.SetPos or nil
	local previous_set_pos_wrapper = State.entrance_badge_set_pos_wrapper
	local previous_set_pos_original = State.entrance_badge_set_pos_original
	if current_set_pos == previous_set_pos_wrapper and type(previous_set_pos_original) == "function" then
		-- Peel off the previous hot-reload wrapper before installing the current code.
		current_set_pos = previous_set_pos_original
	end
	if type(sign_class) == "table" and type(current_set_pos) == "function" then
		local set_pos_wrapper = function(sign, ...)
			local marker = sign and sign.tunnel_marker
			local underground_exit = IsUndergroundExitMarker(marker, sign)
			local x, y, z
			if underground_exit then
				x, y, z = UndergroundExitSignAnchor(marker, sign)
			else
				x, y, z = EntranceBadgeAnchor(marker, sign)
			end
			if type(x) == "number" and type(y) == "number" then
				local point_fn = Global("point")
				if type(point_fn) == "function" then
					local terrain_z = EntranceBadgeTerrainZ(marker, sign, x, y)
					if type(terrain_z) == "number" then z = terrain_z end
					if underground_exit then
						WriteUndergroundExitSignAnchor(marker, x, y, z)
						WriteUndergroundExitSignAnchor(marker and marker.spawner, x, y, z)
						WriteUndergroundExitSignAnchor(sign, x, y, z)
					else
						WriteEntranceBadgeAnchor(marker, x, y, z)
						WriteEntranceBadgeAnchor(marker and marker.spawner, x, y, z)
						WriteEntranceBadgeAnchor(sign, x, y, z)
					end
					local target = type(z) == "number" and point_fn(x, y, z) or point_fn(x, y)
					return current_set_pos(sign, target)
				end
			end
			return current_set_pos(sign, ...)
		end
		State.entrance_badge_set_pos_original = current_set_pos
		State.entrance_badge_set_pos_wrapper = set_pos_wrapper
		sign_class.SetPos = set_pos_wrapper
		installed = installed + 1
	end
	State.entrance_badge_position_patch_version = ENTRANCE_BADGE_POSITION_PATCH_VERSION
	return installed > 0
end

local function RestoreEntranceBadgePositionPatch()
	local State = SuperBigMap.State or {}
	local originals = State.entrance_badge_place_sign_originals or {}
	local wrappers = State.entrance_badge_place_sign_wrappers or {}
	for _, class_name in ipairs(ENTRANCE_BADGE_MARKER_CLASSES) do
		local cls = Engine.ClassTable and Engine.ClassTable(class_name)
		if type(cls) == "table" and cls.PlaceSign == wrappers[class_name]
			and type(originals[class_name]) == "function" then
			cls.PlaceSign = originals[class_name]
		end
	end
	local sign_class = Engine.ClassTable and Engine.ClassTable("SurfaceUndergroundTunnelSign")
	local set_pos_wrapper = State.entrance_badge_set_pos_wrapper
	local set_pos_original = State.entrance_badge_set_pos_original
	if type(sign_class) == "table" and sign_class.SetPos == set_pos_wrapper
		and type(set_pos_original) == "function" then
		sign_class.SetPos = set_pos_original
	end
	State.entrance_badge_place_sign_originals = nil
	State.entrance_badge_place_sign_wrappers = nil
	State.entrance_badge_set_pos_original = nil
	State.entrance_badge_set_pos_wrapper = nil
	State.entrance_badge_position_patch_version = nil
end

-- Continue STRETCH step 3b: move everything matching IsUndergroundAccessObject or a
-- SpawnsOnCityInit tunnel spawner, EXCEPT the tunnel
-- markers themselves (already moved by ScaleMarkersToFull; moving twice would double-scale).
-- Runs on both maps, so entrance pairs stay vertically corresponding. Gated on
-- STRETCH_MOVE_ENTRANCE_VISUALS and applied once per map.
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
	local terrain_api = Global("terrain")
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
		-- A linked passage pair records the transformed vanilla underground hex during the
		-- lightweight bootstrap. The underground endpoint always uses it; the surface endpoint
		-- owns a separately committed nearby fallback only when its exact projected footprint is
		-- invalid. Ordinary access objects keep the proportional transform below.
		local committed_x = tonumber(obj.SuperBigMapCommittedPassageX)
		local committed_y = tonumber(obj.SuperBigMapCommittedPassageY)
		local committed = obj.SuperBigMapCommittedPassageLocked == true
			and type(committed_x) == "number" and type(committed_y) == "number"
		-- Only uncommitted objects still inside the source region need moving; an already
		-- transformed ordinary object lies beyond it on at least one axis.
		if not committed and (ox >= src_w or oy >= src_w) then return end
		local nx = committed and committed_x or math.floor(ox * scale + 0.5)
		local ny = committed and committed_y or math.floor(oy * scale + 0.5)
		local pair_exact = committed
		local pair_anchor = committed and "committed passage hex" or "scaled"
		local elevator_kind = is_elevator_or_site(obj)
		if elevator_kind then
			local underground = map.mapdata and map.mapdata.Environment == "Underground"
			local anchor
			if underground then
				-- On the underground map, vanilla's passage/imprint is authoritative. The linked
				-- surface half can be offset because the exact corresponding surface hex was not
				-- buildable. Never pull the underground site/building away from its imprint.
				anchor = IsKindOfSafe(obj, "ElevatorBase") and obj.passage
					or obj.SuperBigMapDeferredElevatorPassage
				pair_anchor = "underground_passage"
			else
				anchor = IsKindOfSafe(obj, "ElevatorBase") and obj.other or obj.linked_obj
				pair_anchor = "linked_counterpart"
			end
			-- A destroyed construction site remains a Lua table with GetPos but is no longer a
			-- luaGameObject. Never cross the engine boundary unless IsValid confirms it is live.
			if IsLiveGameObject(anchor) and type(anchor.GetPos) == "function" then
				local ok_lp, linked_pos = pcall(anchor.GetPos, anchor)
				local lx, ly
				if ok_lp then lx, ly = PointXY(linked_pos) end
				if type(lx) == "number" and type(ly) == "number" then
					-- Use the selected live anchor's exact final coordinate instead of independently
					-- scaling the Elevator and allowing it to drift away from its passage/counterpart.
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
		-- ENTRANCE SIGN: use the live terrain directly under the badge. Nearby relief must not
		-- lift it; no-depth-test visibility handles camera occlusion without floating the visual.
		if IsKindOfSafe(obj, "SurfaceUndergroundTunnelSign")
			and type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function" then
			local ok_h2, ground_z = pcall(terrain_api.GetHeight, map, point_fn(nx, ny))
			if ok_h2 and type(ground_z) == "number" then
				np = point_fn(nx, ny, ground_z)
				placed_z = true
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
			-- Some Building-derived entrance indicators have a handle but were never registered
			-- in the object grid, so only the known passage/elevator classes are eligible.
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
			-- removing; if it is not, skip the remove but still add it after the move.
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
			end
			if shape and was_registered then pcall(hex_remove, hex_grid, obj, shape) end
			ok_set = pcall(obj.SetPos, obj, np)
			if shape then
				rehexed = pcall(hex_add, hex_grid, obj, shape) == true
			end
		end
		if ok_set then moved = moved + 1 end
		if ok_set and obj.SuperBigMapDeferredElevatorPassage then
			obj.SuperBigMapDeferredElevatorPassage = nil
		end
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
	-- Vanilla deliberately moves a tunnel MARKER to a nearby unobstructed anomaly position. Keep the
	-- gameplay marker there, but bind its visual sign to marker.spawner -- the exact final passage
	-- object that owns the entrance. The two maps intentionally use different visual placement:
	--   * Surface: place the entrance sign on the closest safe cell beside the passage footprint.
	--   * Underground: place SignUnderground on the authoritative SurfacePassage hex itself.
	-- The latter is the actual underground exit symbol, not a surface-side badge, and moving it to a
	-- footprint-edge cell makes the displayed sector/hex disagree with the linked passage.
	local world_to_hex = Global("WorldToHex")
	local hex_to_world = Global("HexToWorld")
	local get_unbuildable = Global("buildUnbuildableZ")
	local shape_for_each = Global("HexShapeForEach")
	local get_elevator_shape = Global("GetExtendedSpawnShape")
	local badge_directions = {
		{ 1, 0 }, { 1, -1 }, { 0, -1 },
		{ -1, 0 }, { -1, 1 }, { 0, 1 },
	}
	local function find_badge_side_position(sign, passage, center_x, center_y)
		local buildable = map.buildable
		local hex_grid = map.object_hex_grid
		local badge_rules = SuperBigMap.DepositRules
		local badge_occupancy = badge_rules and type(badge_rules.BuildBadgeOccupancy) == "function"
			and badge_rules.BuildBadgeOccupancy(map, nil, sign) or nil
		if type(world_to_hex) ~= "function" or type(hex_to_world) ~= "function"
			or not buildable or type(buildable.GetZ) ~= "function"
			or type(get_unbuildable) ~= "function" then
			return nil
		end
		local ok_center, center_q, center_r = pcall(world_to_hex, point_fn(center_x, center_y))
		local ok_sentinel, unbuildable = pcall(get_unbuildable)
		if not ok_center or type(center_q) ~= "number" or not ok_sentinel then
			return nil
		end
		local old_pos = ObjectPosition(sign)
		local old_x, old_y = PointXY(old_pos)
		local function key(q, r)
			return tostring(q) .. ":" .. tostring(r)
		end
		local function candidate_valid(q, r)
			if badge_occupancy and type(badge_rules.BadgeHexOccupied) == "function"
				and badge_rules.BadgeHexOccupied(badge_occupancy, q, r) then
				return nil
			end
			local ok_b, build_z = pcall(buildable.GetZ, buildable, q, r)
			if not ok_b or build_z == nil or build_z == unbuildable then
				return nil
			end
			local ok_w, x, y = pcall(hex_to_world, q, r)
			if not ok_w or type(x) ~= "number" or type(y) ~= "number" then
				return nil
			end
			local pt = point_fn(x, y)
			if type(terrain_api) == "table" and type(terrain_api.IsPassable) == "function" then
				local ok_p, passable = pcall(terrain_api.IsPassable, map, pt)
				if not ok_p or passable ~= true then
					return nil
				end
			end
			if type(terrain_api) == "table" and type(terrain_api.GetTerrainNormal) == "function" then
				local ok_n, normal = pcall(terrain_api.GetTerrainNormal, map, pt)
				local normal_z = ok_n and normal and type(normal.z) == "function"
					and SafeCall(normal.z, normal) or nil
				if type(normal_z) ~= "number" or normal_z < 3700 then
					return nil
				end
			end
			if hex_grid and type(hex_grid.GetBuildObstructions) == "function" then
				local ok_o, obstructions = pcall(hex_grid.GetBuildObstructions, hex_grid, q, r)
				if not ok_o then
					return nil
				end
				if obstructions and #obstructions > 0 then
					return nil
				end
			end
			local direction_score = 0
			if type(old_x) == "number" and type(old_y) == "number" then
				local dx, dy = x - old_x, y - old_y
				direction_score = dx * dx + dy * dy
			end
			local dq, dr = q - center_q, r - center_r
			return {
				x = x, y = y, q = q, r = r, direction_score = direction_score,
				center_distance = (math.abs(dq) + math.abs(dr) + math.abs(dq + dr)) / 2,
			}
		end

		-- Seed the breadth-first search with every occupied passage cell. GetShapePoints is the
		-- closest description of the visible entrance; the Elevator spawn shape is a safe fallback
		-- for passage variants without their own registered shape.
		local footprint, frontier = {}, {}
		local function add_footprint(q, r)
			if type(q) ~= "number" or type(r) ~= "number" then return end
			local cell_key = key(q, r)
			if footprint[cell_key] then return end
			footprint[cell_key] = true
			frontier[#frontier + 1] = { q = q, r = r }
		end
		local shape
		if passage and type(passage.GetShapePoints) == "function" then
			local ok_shape, value = pcall(passage.GetShapePoints, passage)
			if ok_shape and value then shape = value end
		end
		if not shape and type(get_elevator_shape) == "function" then
			local ok_shape, value = pcall(get_elevator_shape, "Elevator")
			if ok_shape and value then shape = value end
		end
		if shape and type(shape_for_each) == "function" and passage then
			pcall(shape_for_each, shape, passage, function(q, r)
				add_footprint(q, r)
			end)
		end
		if #frontier == 0 then add_footprint(center_q, center_r) end

		local visited = {}
		for cell_key in pairs(footprint) do visited[cell_key] = true end
		-- Distance is measured from the footprint edge. The first valid result is therefore the
		-- closest safe badge position regardless of how large or asymmetric the entrance is.
		for edge_distance = 1, 8 do
			local next_frontier, next_seen = {}, {}
			for _, cell in ipairs(frontier) do
				for _, direction in ipairs(badge_directions) do
					local q, r = cell.q + direction[1], cell.r + direction[2]
					local cell_key = key(q, r)
					if not visited[cell_key] and not next_seen[cell_key] then
						next_seen[cell_key] = true
						next_frontier[#next_frontier + 1] = { q = q, r = r }
					end
				end
			end
			local best
			for _, cell in ipairs(next_frontier) do
				local candidate = candidate_valid(cell.q, cell.r)
				if candidate then
					candidate.edge_distance = edge_distance
					if not best or candidate.direction_score < best.direction_score
						or (candidate.direction_score == best.direction_score
							and (candidate.center_distance < best.center_distance
								or (candidate.center_distance == best.center_distance
									and (candidate.q < best.q
										or (candidate.q == best.q and candidate.r < best.r))))) then
						best = candidate
					end
				end
			end
			if best then return best end
			for cell_key in pairs(next_seen) do visited[cell_key] = true end
			frontier = next_frontier
			if #frontier == 0 then break end
		end
		return nil
	end
	pcall(map.MapForEach, map, "map", "SurfaceUndergroundTunnelSign", function(sign)
		local marker = sign and sign.tunnel_marker
		local passage = marker and marker.spawner
		local is_underground_exit = map.mapdata and map.mapdata.Environment == "Underground"
			and IsKindOfSafe(marker, "SurfaceTunnelMarker")
		local passage_pos = IsLiveGameObject(passage) and ObjectPosition(passage) or nil
		local px, py = PointXY(passage_pos)
		if not sign or type(sign.SetPos) ~= "function"
			or type(px) ~= "number" or type(py) ~= "number" then
			if marker and sign and not is_underground_exit then
				CaptureEntranceBadgePosition(marker, sign, "initial position; passage anchor unresolved")
			end
			return
		end
		if is_underground_exit then
			local ok_set = CaptureUndergroundExitSignPosition(marker, sign,
				"initial authoritative underground exit sign")
			if ok_set then
				sign.SuperBigMapPassageAnchored = true
				EntranceAudit("UNDERGROUND_EXIT_SIGN_ANCHORED", {
					passage_x = px, passage_y = py,
					sign_x = px, sign_y = py,
					exact_passage_hex = true,
				}, map)
				if cfg_bool("ALWAYS_SHOW_ENTRANCE_SIGN", true) then
					if type(sign.SetNoDepthTest) == "function" then pcall(sign.SetNoDepthTest, sign, true) end
					if type(sign.SetVisible) == "function" then pcall(sign.SetVisible, sign, true) end
					if type(sign.SetOpacity) == "function" then pcall(sign.SetOpacity, sign, 100) end
				end
			end
			return
		end
		local side = find_badge_side_position(sign, passage, px, py)
		if not side then
			CaptureEntranceBadgePosition(marker, sign, "initial position; no safe side hex")
			return
		end
		local badge_x, badge_y = side.x, side.y
		local anchor = point_fn(badge_x, badge_y)
		local terrain_z
		if type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function" then
			local ok_h, height = pcall(terrain_api.GetHeight, map, point_fn(badge_x, badge_y))
			if ok_h and type(height) == "number" then terrain_z = height end
		end
		if type(terrain_z) == "number" then
			anchor = point_fn(badge_x, badge_y, terrain_z)
		elseif type(anchor.SetTerrainZ) == "function" then
			local ok_z, snapped = pcall(anchor.SetTerrainZ, anchor, map)
			if ok_z and snapped then anchor = snapped end
		end
		local ok_set = pcall(sign.SetPos, sign, anchor)
		if ok_set then
			sign.SuperBigMapPassageAnchored = true
			CaptureEntranceBadgePosition(marker, sign, "initial post-expansion passage anchor")
			EntranceAudit("ENTRANCE_BADGE_ANCHORED", {
				passage_x = px, passage_y = py,
				badge_x = badge_x, badge_y = badge_y,
				badge_q = side.q, badge_r = side.r,
				edge_distance = side.edge_distance,
				center_distance = side.center_distance,
			}, map)
			if cfg_bool("ALWAYS_SHOW_ENTRANCE_SIGN", true) then
				if type(sign.SetNoDepthTest) == "function" then pcall(sign.SetNoDepthTest, sign, true) end
				if type(sign.SetVisible) == "function" then pcall(sign.SetVisible, sign, true) end
				if type(sign.SetOpacity) == "function" then pcall(sign.SetOpacity, sign, 100) end
			end
		else
			CaptureEntranceBadgePosition(marker, sign, "initial position; anchor SetPos failed")
		end
	end)
	return moved
end

-- Passage correspondence has three phases. The lightweight underground bootstrap records the
-- vanilla underground anchor as the authoritative source coordinate. After the surface stretch,
-- its proportional underground destination is projected onto the surface: the exact hex is used
-- when valid, otherwise only the surface entrance moves to the nearest valid surface footprint.
-- That surface choice is immutable from the first visible frame. Deferred underground expansion
-- later restores the underground anchor to its authoritative transformed coordinate and may clear
-- or prepare that footprint, but it is never allowed to move the surface entrance or Elevator.
local function AlignPassagePairsToSharedHex(underground_map, options)
	options = type(options) == "table" and options or {}
	local source_bootstrap = options.source_bootstrap == true
	local surface_map = Global("MainMap")
	if not underground_map or not surface_map or underground_map == surface_map then
		return false, { error = "surface/underground maps unavailable", pairs = 0 }
	end
	local point_fn = Global("point")
	local world_to_hex = Global("WorldToHex")
	local hex_to_world = Global("HexToWorld")
	local get_unbuildable = Global("buildUnbuildableZ")
	local validate_shape = Global("ValidateEachShapeHexPos")
	local get_shape = Global("GetExtendedSpawnShape")
	local get_outline = Global("GetEntityOutlineShape")
	local is_terrain_flat = Global("IsTerrainFlatForPlacement")
	local flatten_build_shape = Global("FlattenTerrainInBuildShape")
	local terrain_api = Global("terrain")
	if type(point_fn) ~= "function" or type(world_to_hex) ~= "function"
		or type(hex_to_world) ~= "function" or type(get_unbuildable) ~= "function" then
		return false, { error = "point/hex/buildability APIs unavailable", pairs = 0 }
	end
	local ok_sentinel, unbuildable_z = pcall(get_unbuildable)
	if not ok_sentinel then
		return false, { error = "unbuildable sentinel unavailable", pairs = 0 }
	end
	local elevator_shape
	if type(get_shape) == "function" then
		local ok_shape, value = pcall(get_shape, "Elevator")
		if ok_shape and type(value) == "table" then elevator_shape = value end
	end
	local surface_w, surface_h = TerrainSize(surface_map)
	local underground_w, underground_h = TerrainSize(underground_map)

	local function map_of(obj)
		if not obj or type(obj.GetMap) ~= "function" then return nil end
		local ok, value = pcall(obj.GetMap, obj)
		return ok and value or nil
	end

	local function map_point_in_bounds(map, x, y)
		local w, h = map == surface_map and surface_w or underground_w,
			map == surface_map and surface_h or underground_h
		return type(x) == "number" and type(y) == "number"
			and type(w) == "number" and type(h) == "number"
			and x >= 0 and y >= 0 and x < w and y < h
	end

	local minimum_normal_z = tonumber((SuperBigMap.Config or {}).TOPUP_MINIMUM_TERRAIN_NORMAL_Z) or 4080
	minimum_normal_z = math.max(0, math.min(4096, minimum_normal_z))
	local function footprint_buildable(map, q, r, angle, anchor)
		local buildable = map and map.buildable
		if not buildable or type(buildable.GetZ) ~= "function" then
			return false, "buildable grid unavailable"
		end
		local ok_world, x, y = pcall(hex_to_world, q, r)
		if not ok_world or not map_point_in_bounds(map, x, y) then
			return false, "center outside map"
		end
		local center = point_fn(x, y)
		local anchor_at_candidate = false
		local anchor_pos = anchor and ObjectPosition(anchor)
		if anchor_pos then
			local ok_anchor_hex, anchor_q, anchor_r = pcall(world_to_hex, anchor_pos)
			anchor_at_candidate = ok_anchor_hex and anchor_q == q and anchor_r == r
		end
		-- SurfacePassageBase:IsValidPlacement uses this exact vanilla predicate. Check it at
		-- every candidate before considering the larger Elevator spawn footprint.
		if type(is_terrain_flat) == "function" and type(get_outline) == "function"
			and anchor and anchor.entity then
			local ok_outline, outline = pcall(get_outline, anchor.entity)
			if not ok_outline or not outline then return false, "entity outline unavailable" end
			local ok_flat, flat = pcall(is_terrain_flat, buildable, outline, center, angle or 0)
			if not ok_flat or flat ~= true then return false, "vanilla terrain-flat test failed" end
		end
		local level
		local failure_reason
		local function valid_hex(hq, hr)
			local ok_xy, hx, hy = pcall(hex_to_world, hq, hr)
			if not ok_xy or not map_point_in_bounds(map, hx, hy) then
				failure_reason = "footprint outside map"
				return false
			end
			local ok_z, z = pcall(buildable.GetZ, buildable, hq, hr)
			if not ok_z or z == nil or z == unbuildable_z then
				failure_reason = "unbuildable footprint hex"
				return false
			end
			if level == nil then
				level = z
			elseif z ~= level then
				failure_reason = "uneven buildable footprint"
				return false
			end
			local hex_point = point_fn(hx, hy)
			-- A live passage can make its own occupied footprint non-passable. When validating
			-- the coordinate it already occupies, buildability/flatness/normal plus the obstruction
			-- query (which ignores only that anchor) describe the underlying terrain without
			-- mistaking the passage itself for a terrain defect.
			if not anchor_at_candidate and type(terrain_api) == "table"
				and type(terrain_api.IsPassable) == "function" then
				local ok_passable, passable = pcall(terrain_api.IsPassable, map, hex_point)
				if not ok_passable or passable ~= true then
					failure_reason = "impassable footprint hex"
					return false
				end
			end
			if type(terrain_api) == "table" and type(terrain_api.GetTerrainNormal) == "function" then
				local ok_normal, normal = pcall(terrain_api.GetTerrainNormal, map, hex_point)
				local normal_z = ok_normal and normal and type(normal.z) == "function"
					and SafeCall(normal.z, normal) or nil
				if type(normal_z) ~= "number" or normal_z < minimum_normal_z then
					failure_reason = "sloped footprint hex"
					return false
				end
			end
			local object_grid = map.object_hex_grid
			if object_grid and type(object_grid.GetBuildObstructions) == "function" then
				local ok_obstructions, obstructions = pcall(
					object_grid.GetBuildObstructions, object_grid, hq, hr)
				if not ok_obstructions then
					failure_reason = "obstruction query failed"
					return false
				end
				if type(obstructions) == "table" then
					for i = 1, #obstructions do
						local obstruction = obstructions[i]
						local follows_anchor = obstruction == anchor
							or (obstruction and (obstruction.passage == anchor
								or obstruction.other == anchor or obstruction.linked_obj == anchor
								or obstruction.SuperBigMapDeferredElevatorPassage == anchor
								or obstruction.spawner == anchor))
						if not follows_anchor then
							failure_reason = "blocked footprint hex"
							return false
						end
					end
				end
			end
			return true
		end
		if elevator_shape and type(validate_shape) == "function" then
			local ok, valid = pcall(validate_shape, elevator_shape, center, angle or 0, valid_hex)
			if not ok then return false, "Elevator shape validation failed" end
			if valid ~= true then return false, failure_reason or "invalid Elevator footprint" end
			return true
		end
		local valid = valid_hex(q, r)
		return valid, valid and nil or failure_reason
	end

	local function registered_shape(obj, map)
		local is_valid = Global("IsValid")
		if not obj or not map or not map.object_hex_grid
			or (type(is_valid) == "function" and is_valid(obj) ~= true)
			or type(obj.handle) ~= "number" or obj.handle <= 0
			or type(obj.GetShapePoints) ~= "function" then return nil, false end
		local ok_shape, shape = pcall(obj.GetShapePoints, obj)
		if not ok_shape or not shape then return nil, false end
		local get_list = Global("HexGridShapeGetObjectList")
		if type(get_list) ~= "function" then return shape, nil end
		local ok_list, list = pcall(get_list, map.object_hex_grid, obj, shape)
		if not ok_list or type(list) ~= "table" then return shape, nil end
		for i = 1, #list do
			if list[i] == obj then return shape, true end
		end
		return shape, false
	end

	local function move_object(obj, map, x, y)
		if not IsLiveGameObject(obj) or type(obj.SetPos) ~= "function" then return false end
		local destination = point_fn(x, y)
		if type(destination.SetTerrainZ) == "function" then
			local ok_z, snapped = pcall(destination.SetTerrainZ, destination, map)
			if ok_z and snapped then destination = snapped end
		end
		local shape, registered = registered_shape(obj, map)
		if shape and registered == nil then return false end
		local remove_shape = Global("HexGridShapeRemoveObject")
		local add_shape = Global("HexGridShapeAddObject")
		if shape and (type(add_shape) ~= "function"
			or (registered and type(remove_shape) ~= "function")) then
			return false
		end
		local remove_ok = true
		if shape and registered and type(remove_shape) == "function" then
			remove_ok = pcall(remove_shape, map.object_hex_grid, obj, shape)
		end
		local ok_set = pcall(obj.SetPos, obj, destination)
		local add_ok = true
		-- The list check makes removal safe. A shaped object that was absent from the grid still needs
		-- one registration at its final position so Elevator snapping sees the visible anchor.
		if shape and type(add_shape) == "function" then
			add_ok = pcall(add_shape, map.object_hex_grid, obj, shape)
		end
		return remove_ok and ok_set and add_ok
	end

	-- Vanilla prepares the surface passage with this exact Elevator shape after it has selected a
	-- naturally valid footprint. Our two-phase planner can move that passage after vanilla's call,
	-- so the preparation must follow the committed move instead of remaining at the discarded hex.
	-- This is deliberately not a placement fallback: footprint_buildable must accept the untouched
	-- terrain first, and a failed native preparation aborts the transaction.
	local function prepare_passage_pad(anchor, map, x, y)
		if not elevator_shape or type(flatten_build_shape) ~= "function" then
			return false, "vanilla passage-pad preparation unavailable"
		end
		if map_of(anchor) ~= map then return false, "passage anchor belongs to another map" end
		local ok_flatten, flatten_result = pcall(
			flatten_build_shape, elevator_shape, anchor, "flatten unbuildable")
		if not ok_flatten then
			return false, "vanilla passage-pad preparation failed: " .. tostring(flatten_result)
		end
		-- FlattenTerrainInBuildShape changes the ground, not the object's stored Z. Re-snap and
		-- re-register the passage at the same committed hex so visuals, collision, and the object
		-- grid all observe the prepared terrain from the first frame.
		if not move_object(anchor, map, x, y) then
			return false, "prepared passage could not be re-snapped"
		end
		anchor.SuperBigMapPassagePadPrepared = true
		return true
	end

	local function clear_passage_obstructions(anchor, map, x, y)
		local clear = Global("ClearObstructions")
		if type(clear) ~= "function" or not elevator_shape then
			return false, "vanilla passage obstruction clearance unavailable"
		end
		local pos = point_fn(x, y)
		if type(pos.SetTerrainZ) == "function" then
			local ok_z, snapped = pcall(pos.SetTerrainZ, pos, map)
			if ok_z and snapped then pos = snapped end
		end
		local angle = type(anchor.GetAngle) == "function" and SafeCall(anchor.GetAngle, anchor) or 0
		local ok, result = pcall(clear, map, pos, angle, map.obj_prefab_marker, nil, elevator_shape)
		return ok, ok and nil or tostring(result)
	end

	local function is_elevator_site(obj)
		if not IsKindOfSafe(obj, "ConstructionSite") then return false end
		local class_name = obj.building_class or obj.template_name
		if type(obj.GetBuildingClass) == "function" then
			local ok, value = pcall(obj.GetBuildingClass, obj)
			if ok and type(value) == "string" then class_name = value end
		end
		return class_name == "Elevator" or IsKindOfSafe(obj.building_class_proto, "ElevatorBase")
	end

	local function move_dependants(map, anchor, old_x, old_y, new_x, new_y)
		local moved = 0
		if not map or type(map.MapForEach) ~= "function" then return moved end
		pcall(map.MapForEach, map, "map", "CObject", function(obj)
			if not obj or obj == anchor then return end
			local exact = (IsKindOfSafe(obj, "ElevatorBase") or is_elevator_site(obj))
				and (obj.passage == anchor or obj.other == anchor or obj.linked_obj == anchor
					or obj.SuperBigMapDeferredElevatorPassage == anchor)
			local relative = obj.spawner == anchor or obj.passage == anchor
				or (obj.tunnel_marker and obj.tunnel_marker.spawner == anchor)
			if not exact and not relative then return end
			local x, y = new_x, new_y
			if not exact then
				local pos = ObjectPosition(obj)
				local ox, oy = PointXY(pos)
				if type(ox) ~= "number" or type(oy) ~= "number" then return end
				x, y = ox + (new_x - old_x), oy + (new_y - old_y)
			end
			if move_object(obj, map, x, y) then moved = moved + 1 end
		end)
		return moved
	end

	local stats = {
		pairs = 0, exact = 0, fallback = 0, moved_dependants = 0, checked = 0,
		mode = source_bootstrap and "source bootstrap" or "deferred final validation",
		locked = 0, surface_moves = 0,
	}
	local seen = {}
	local linked_pairs = {}
	if type(underground_map.MapForEach) == "function" then
		pcall(underground_map.MapForEach, underground_map, "map", "ElevatorPassage", function(anchor)
			local surface_anchor = anchor and anchor.other
			if IsLiveGameObject(anchor) and IsLiveGameObject(surface_anchor)
				and surface_anchor.other == anchor and map_of(surface_anchor) == surface_map
				and not seen[anchor] then
				seen[anchor], seen[surface_anchor] = true, true
				linked_pairs[#linked_pairs + 1] = { underground = anchor, surface = surface_anchor }
			end
		end)
	end
	if #linked_pairs == 0 then
		return false, { error = "no linked ElevatorPassage pairs found", pairs = 0 }
	end

	local source_width_tiles = tonumber(underground_map.SuperBigMapGeneratorWidthTiles)
		or tonumber(underground_map.SuperBigMapSourceWidthTiles)
	local source_height_tiles = tonumber(underground_map.SuperBigMapGeneratorHeightTiles)
		or tonumber(underground_map.SuperBigMapSourceHeightTiles)
	local desired_width_tiles = tonumber(underground_map.SuperBigMapDesiredWidthTiles)
	local desired_height_tiles = tonumber(underground_map.SuperBigMapDesiredHeightTiles)
	local function expansion_ratio(final_extent, source_extent)
		final_extent, source_extent = tonumber(final_extent), tonumber(source_extent)
		if final_extent and source_extent and source_extent > 0 and final_extent > source_extent then
			-- The engine Lua runtime preserves integer division when both operands are integers
			-- (8192 / 6144 becomes 1). Promote the numerator exactly as the terrain stretch does.
			return (final_extent + 0.0) / source_extent
		end
		return nil
	end
	local scale_x = expansion_ratio(desired_width_tiles, source_width_tiles)
	local scale_y = expansion_ratio(desired_height_tiles, source_height_tiles)
	local scale_x_source = scale_x and "underground tile metadata" or nil
	local scale_y_source = scale_y and "underground tile metadata" or nil
	-- The passage bootstrap runs inside the deliberately source-sized underground view. Some
	-- engine builds replace per-map generation markers during Proc_ResolveBuildable even though
	-- the backing markers and MainMap metadata remain authoritative. Resolve each axis from any
	-- exact live representation of the same geometry; no constant or scenario value is involved.
	if not scale_x then
		scale_x = expansion_ratio(surface_map.SuperBigMapDesiredWidthTiles,
			surface_map.SuperBigMapGeneratorWidthTiles or surface_map.SuperBigMapSourceWidthTiles)
		scale_x_source = scale_x and "surface tile metadata" or nil
	end
	if not scale_y then
		scale_y = expansion_ratio(surface_map.SuperBigMapDesiredHeightTiles,
			surface_map.SuperBigMapGeneratorHeightTiles or surface_map.SuperBigMapSourceHeightTiles)
		scale_y_source = scale_y and "surface tile metadata" or nil
	end
	if not scale_x then
		scale_x = expansion_ratio(underground_map.SuperBigMapExpandedWorldWidth,
			underground_map.Width or underground_map.SuperBigMapGeneratorWidth)
		scale_x_source = scale_x and "underground live backing/source world extents" or nil
	end
	if not scale_y then
		scale_y = expansion_ratio(underground_map.SuperBigMapExpandedWorldHeight,
			underground_map.Height or underground_map.SuperBigMapGeneratorHeight)
		scale_y_source = scale_y and "underground live backing/source world extents" or nil
	end
	EntranceAudit("PASSAGE_PLAN_SCALE_RESOLVED", {
		mode = source_bootstrap and "source bootstrap" or "deferred final validation",
		scale_x = scale_x, scale_y = scale_y,
		scale_x_source = scale_x_source, scale_y_source = scale_y_source,
		underground_generator_tiles = tostring(underground_map.SuperBigMapGeneratorWidthTiles)
			.. "x" .. tostring(underground_map.SuperBigMapGeneratorHeightTiles),
		underground_source_tiles = tostring(underground_map.SuperBigMapSourceWidthTiles)
			.. "x" .. tostring(underground_map.SuperBigMapSourceHeightTiles),
		underground_desired_tiles = tostring(underground_map.SuperBigMapDesiredWidthTiles)
			.. "x" .. tostring(underground_map.SuperBigMapDesiredHeightTiles),
		underground_live_world = tostring(underground_map.Width)
			.. "x" .. tostring(underground_map.Height),
		underground_expanded_world = tostring(underground_map.SuperBigMapExpandedWorldWidth)
			.. "x" .. tostring(underground_map.SuperBigMapExpandedWorldHeight),
	}, underground_map)
	if source_bootstrap and (not scale_x or not scale_y or scale_x <= 1 or scale_y <= 1) then
		return false, {
			error = "source/final passage scale unavailable",
			pairs = 0, scale_x = scale_x, scale_y = scale_y,
		}
	end

	local function scaled_final_hex(source_q, source_r)
		local ok_source, source_x, source_y = pcall(hex_to_world, source_q, source_r)
		if not ok_source or type(source_x) ~= "number" or type(source_y) ~= "number" then
			return nil
		end
		local raw_x = math.floor(source_x * scale_x + 0.5)
		local raw_y = math.floor(source_y * scale_y + 0.5)
		local ok_hex, final_q, final_r = pcall(world_to_hex, point_fn(raw_x, raw_y))
		if not ok_hex or type(final_q) ~= "number" or type(final_r) ~= "number" then
			return nil
		end
		local ok_final, final_x, final_y = pcall(hex_to_world, final_q, final_r)
		if not ok_final or type(final_x) ~= "number" or type(final_y) ~= "number" then
			return nil
		end
		return {
			source_q = source_q, source_r = source_r, source_x = source_x, source_y = source_y,
			final_q = final_q, final_r = final_r, final_x = final_x, final_y = final_y,
		}
	end

	local function stamp_plan(anchor, plan, endpoint_q, endpoint_r, endpoint_x, endpoint_y)
		anchor.SuperBigMapCommittedPassageLocked = true
		anchor.SuperBigMapCommittedPassagePlanVersion = 2
		anchor.SuperBigMapCommittedPassageSourceQ = plan.source_q
		anchor.SuperBigMapCommittedPassageSourceR = plan.source_r
		anchor.SuperBigMapCommittedPassageSourceX = plan.source_x
		anchor.SuperBigMapCommittedPassageSourceY = plan.source_y
		-- The transformed underground coordinate is authoritative and immutable. The surface
		-- endpoint normally uses it too, but may use a nearby surface-only fallback when that exact
		-- hex is not a valid surface footprint.
		anchor.SuperBigMapTrueUndergroundPassageQ = plan.final_q
		anchor.SuperBigMapTrueUndergroundPassageR = plan.final_r
		anchor.SuperBigMapTrueUndergroundPassageX = plan.final_x
		anchor.SuperBigMapTrueUndergroundPassageY = plan.final_y
		anchor.SuperBigMapCommittedPassageQ = endpoint_q or plan.final_q
		anchor.SuperBigMapCommittedPassageR = endpoint_r or plan.final_r
		anchor.SuperBigMapCommittedPassageX = endpoint_x or plan.final_x
		anchor.SuperBigMapCommittedPassageY = endpoint_y or plan.final_y
	end

	local directions = {
		{ 1, 0 }, { 1, -1 }, { 0, -1 },
		{ -1, 0 }, { -1, 1 }, { 0, 1 },
	}
	local function nearest_on_hex_rings(center_q, center_r, predicate, first_radius, max_radius)
		for radius = first_radius or 0, max_radius or 0 do
			if radius == 0 then
				if predicate(center_q, center_r) then return center_q, center_r, 0 end
			else
				local candidate_q, candidate_r = center_q - radius, center_r + radius
				for side = 1, 6 do
					local direction = directions[side]
					for _ = 1, radius do
						if predicate(candidate_q, candidate_r) then
							return candidate_q, candidate_r, radius
						end
						candidate_q = candidate_q + direction[1]
						candidate_r = candidate_r + direction[2]
					end
				end
			end
		end
		return nil
	end

	for i = 1, #linked_pairs do
		local pair = linked_pairs[i]
		local underground_anchor, surface_anchor = pair.underground, pair.surface
		local underground_pos, surface_pos = ObjectPosition(underground_anchor), ObjectPosition(surface_anchor)
		local ux, uy = PointXY(underground_pos)
		local sx, sy = PointXY(surface_pos)
		if type(ux) ~= "number" or type(uy) ~= "number"
			or type(sx) ~= "number" or type(sy) ~= "number" then
			return false, { error = "linked passage position unavailable", pairs = stats.pairs }
		end
		local ok_hex, origin_q, origin_r = pcall(world_to_hex, point_fn(ux, uy))
		if not ok_hex or type(origin_q) ~= "number" or type(origin_r) ~= "number" then
			return false, { error = "underground passage hex unavailable", pairs = stats.pairs }
		end
		local underground_angle = type(underground_anchor.GetAngle) == "function"
			and SafeCall(underground_anchor.GetAngle, underground_anchor) or 0
		local surface_angle = type(surface_anchor.GetAngle) == "function"
			and SafeCall(surface_anchor.GetAngle, surface_anchor) or 0
		if (tonumber(surface_map.hex_width) or 0) <= 0
			or (tonumber(underground_map.hex_width) or 0) <= 0 then
			return false, { error = "map hex dimensions unavailable", pairs = stats.pairs }
		end
		local surface_final_commit = source_bootstrap and options.prepare_surface_pad == true
		local committed = underground_anchor.SuperBigMapCommittedPassageLocked == true
			and surface_anchor.SuperBigMapCommittedPassageLocked == true
		local plan
		if source_bootstrap then
			local source_q = surface_final_commit
				and tonumber(underground_anchor.SuperBigMapCommittedPassageSourceQ) or origin_q
			local source_r = surface_final_commit
				and tonumber(underground_anchor.SuperBigMapCommittedPassageSourceR) or origin_r
			if type(source_q) ~= "number" or type(source_r) ~= "number" then
				return false, { error = "true underground source hex unavailable", pairs = stats.pairs }
			end
			plan = scaled_final_hex(source_q, source_r)
		else
			if not committed then
				return false, { error = "final underground alignment has no committed plan", pairs = stats.pairs }
			end
			plan = {
				source_q = tonumber(underground_anchor.SuperBigMapCommittedPassageSourceQ),
				source_r = tonumber(underground_anchor.SuperBigMapCommittedPassageSourceR),
				source_x = tonumber(underground_anchor.SuperBigMapCommittedPassageSourceX),
				source_y = tonumber(underground_anchor.SuperBigMapCommittedPassageSourceY),
				final_q = tonumber(underground_anchor.SuperBigMapTrueUndergroundPassageQ)
					or tonumber(underground_anchor.SuperBigMapCommittedPassageQ),
				final_r = tonumber(underground_anchor.SuperBigMapTrueUndergroundPassageR)
					or tonumber(underground_anchor.SuperBigMapCommittedPassageR),
				final_x = tonumber(underground_anchor.SuperBigMapTrueUndergroundPassageX)
					or tonumber(underground_anchor.SuperBigMapCommittedPassageX),
				final_y = tonumber(underground_anchor.SuperBigMapTrueUndergroundPassageY)
					or tonumber(underground_anchor.SuperBigMapCommittedPassageY),
			}
		end
		if not plan or type(plan.final_q) ~= "number" or type(plan.final_r) ~= "number"
			or type(plan.final_x) ~= "number" or type(plan.final_y) ~= "number" then
			return false, { error = "true underground passage transform unavailable", pairs = stats.pairs }
		end

		local surface_q, surface_r, surface_x, surface_y = plan.final_q, plan.final_r,
			plan.final_x, plan.final_y
		local surface_radius = 0
		local search_algorithm = "exact transformed underground hex"
		if surface_final_commit then
			local function surface_candidate(q, r)
				stats.checked = stats.checked + 1
				return footprint_buildable(surface_map, q, r, surface_angle, surface_anchor)
			end
			if not surface_candidate(surface_q, surface_r) then
				surface_q, surface_r, surface_radius = nearest_on_hex_rings(
					plan.final_q, plan.final_r, surface_candidate, 1,
					math.max(tonumber(surface_map.hex_width) or 0,
						tonumber(surface_map.hex_height) or 0))
				if surface_q == nil then
					return false, { error = "no valid surface footprint near true underground hex",
						pairs = stats.pairs, checked = stats.checked }
				end
				local ok_surface_world
				ok_surface_world, surface_x, surface_y = pcall(hex_to_world, surface_q, surface_r)
				if not ok_surface_world then
					return false, { error = "surface fallback world coordinate unavailable",
						pairs = stats.pairs }
				end
				search_algorithm = "nearest valid surface footprint to true underground hex"
			end
		elseif not source_bootstrap then
			surface_q = tonumber(surface_anchor.SuperBigMapCommittedPassageQ)
			surface_r = tonumber(surface_anchor.SuperBigMapCommittedPassageR)
			surface_x = tonumber(surface_anchor.SuperBigMapCommittedPassageX)
			surface_y = tonumber(surface_anchor.SuperBigMapCommittedPassageY)
			if type(surface_q) ~= "number" or type(surface_r) ~= "number"
				or type(surface_x) ~= "number" or type(surface_y) ~= "number" then
				return false, { error = "committed surface endpoint unavailable", pairs = stats.pairs }
			end
			search_algorithm = "immutable surface commitment and true underground hex"
		end

		local expected_ux, expected_uy
		local post_underground_q, post_underground_r
		if source_bootstrap then
			expected_ux, expected_uy = plan.source_x, plan.source_y
			post_underground_q, post_underground_r = plan.source_q, plan.source_r
			local underground_valid, underground_reason = footprint_buildable(
				underground_map, plan.source_q, plan.source_r, underground_angle, underground_anchor)
			if not underground_valid then
				return false, { error = "vanilla underground true position is invalid",
					pairs = stats.pairs, reason = underground_reason }
			end
			if not surface_final_commit and (ux ~= expected_ux or uy ~= expected_uy)
				and not move_object(underground_anchor, underground_map, expected_ux, expected_uy) then
				return false, { error = "true underground source position restore failed", pairs = stats.pairs }
			end
			if sx ~= surface_x or sy ~= surface_y then
				if not move_object(surface_anchor, surface_map, surface_x, surface_y) then
					return false, { error = "surface entrance commitment move failed", pairs = stats.pairs }
				end
				stats.surface_moves = stats.surface_moves + 1
			end
			stamp_plan(underground_anchor, plan)
			stamp_plan(surface_anchor, plan, surface_q, surface_r, surface_x, surface_y)
		else
			expected_ux, expected_uy = plan.final_x, plan.final_y
			post_underground_q, post_underground_r = plan.final_q, plan.final_r
			if sx ~= surface_x or sy ~= surface_y then
				return false, {
					error = "visible surface entrance drifted from its immutable commitment",
					pairs = stats.pairs,
					surface = tostring(sx) .. "," .. tostring(sy),
					committed = tostring(surface_x) .. "," .. tostring(surface_y),
				}
			end
			-- Inspect and clear the authoritative destination while the passage still occupies its
			-- source coordinate. ClearObstructions removes objects in the supplied shape; moving the
			-- passage first could therefore make the passage itself part of the cleanup query.
			local pre_valid, pre_reason = footprint_buildable(underground_map,
				plan.final_q, plan.final_r, underground_angle, underground_anchor)
			if not pre_valid then
				EntranceAudit("PASSAGE_PLAN_COMMITTED_INVALID", {
					pair = i, committed_q = plan.final_q, committed_r = plan.final_r,
					committed_x = plan.final_x, committed_y = plan.final_y,
					underground_valid = false, underground_reason = pre_reason,
					action = "clear and prepare immutable true underground position",
				}, underground_map)
			end
			local cleared, clear_reason = clear_passage_obstructions(underground_anchor,
				underground_map, expected_ux, expected_uy)
			if not cleared then
				return false, { error = "true underground passage obstruction clearance failed",
					pairs = stats.pairs, reason = clear_reason }
			end
			if ux ~= expected_ux or uy ~= expected_uy then
				if not move_object(underground_anchor, underground_map, expected_ux, expected_uy) then
					return false, { error = "true underground final move failed", pairs = stats.pairs }
				end
			end
		end
		local verify_ux, verify_uy = PointXY(ObjectPosition(underground_anchor))
		local verify_sx, verify_sy = PointXY(ObjectPosition(surface_anchor))
		if verify_ux ~= expected_ux or verify_uy ~= expected_uy
			or verify_sx ~= surface_x or verify_sy ~= surface_y then
			return false, {
				error = "linked passage post-move coordinate verification failed",
				pairs = stats.pairs,
				underground = tostring(verify_ux) .. "," .. tostring(verify_uy),
				surface = tostring(verify_sx) .. "," .. tostring(verify_sy),
				expected_underground = tostring(expected_ux) .. "," .. tostring(expected_uy),
				expected_surface = tostring(surface_x) .. "," .. tostring(surface_y),
			}
		end
		-- Re-run the complete validator after the anchors occupy their selected coordinates. This
		-- is map-explicit and therefore remains authoritative inside the source-view transaction,
		-- unlike SurfacePassageBase:IsValidPlacement -> GetBuildableGrid(self), whose private
		-- ambient lookup can observe the expanded backing instead of the presented source view.
		local underground_post_valid, underground_post_reason = footprint_buildable(
			underground_map, post_underground_q, post_underground_r,
			underground_angle, underground_anchor)
		local surface_post_valid, surface_post_reason
		if source_bootstrap and not surface_final_commit then
			-- This is only the provisional pre-stretch coordinate. The final surface terrain does
			-- not exist yet, so validating it here would make the underground truth depend on the
			-- unrelated pre-stretch surface found under the future coordinate.
			surface_post_valid = true
			surface_post_reason = "deferred until final surface stretch"
		else
			surface_post_valid, surface_post_reason = footprint_buildable(
				surface_map, surface_q, surface_r, surface_angle, surface_anchor)
		end
		EntranceAudit("PASSAGE_PLAN_POST_MOVE_VALIDATION", {
			pair = i, mode = source_bootstrap and "source bootstrap" or "deferred final validation",
			underground_valid = underground_post_valid,
			underground_reason = underground_post_reason,
			surface_valid = surface_post_valid, surface_reason = surface_post_reason,
			underground_q = post_underground_q, underground_r = post_underground_r,
			surface_q = surface_q, surface_r = surface_r,
		}, underground_map)
		local underground_must_already_be_valid = source_bootstrap
		if (underground_must_already_be_valid and not underground_post_valid)
			or not surface_post_valid then
			return false, {
				error = "linked passage post-move terrain validation failed",
				pairs = stats.pairs,
				underground_reason = underground_post_reason,
				surface_reason = surface_post_reason,
			}
		end

		-- Initial bootstrap runs before the surface stretch, so its provisional surface coordinate
		-- must not sculpt terrain that is about to be replaced. A second source-view planning pass
		-- after the final surface buildable-grid rebuild opts in here. Deferred underground final
		-- alignment always prepares the underground endpoint; it also prepares the surface endpoint
		-- when a final-grid incompatibility forced that endpoint to move.
		local prepare_surface = surface_final_commit
			or (not source_bootstrap and surface_anchor.SuperBigMapPassagePadPrepared ~= true)
		local prepare_underground = not source_bootstrap
			and options.prepare_underground_pad ~= false
		if prepare_surface then
			local prepared, reason = prepare_passage_pad(surface_anchor, surface_map, surface_x, surface_y)
			if not prepared then
				return false, { error = "surface passage pad preparation failed", pairs = stats.pairs,
					reason = reason }
			end
		end
		if prepare_underground then
			local prepared, reason = prepare_passage_pad(
				underground_anchor, underground_map, expected_ux, expected_uy)
			if not prepared then
				return false, { error = "underground passage pad preparation failed", pairs = stats.pairs,
					reason = reason }
			end
		end
		if prepare_surface or prepare_underground then
			local prepared_underground_valid, prepared_underground_reason = footprint_buildable(
				underground_map, post_underground_q, post_underground_r,
				underground_angle, underground_anchor)
			local prepared_surface_valid, prepared_surface_reason = footprint_buildable(
				surface_map, surface_q, surface_r, surface_angle, surface_anchor)
			EntranceAudit("PASSAGE_PLAN_PAD_PREPARED", {
				pair = i,
				mode = source_bootstrap and "surface final commitment" or "deferred final validation",
				surface_prepared = prepare_surface,
				underground_prepared = prepare_underground,
				surface_valid = prepared_surface_valid,
				surface_reason = prepared_surface_reason,
				underground_valid = prepared_underground_valid,
				underground_reason = prepared_underground_reason,
				underground_q = plan.final_q, underground_r = plan.final_r,
				surface_q = surface_q, surface_r = surface_r,
			}, underground_map)
			if not prepared_underground_valid or not prepared_surface_valid then
				return false, {
					error = "linked passage post-preparation terrain validation failed",
					pairs = stats.pairs,
					underground_reason = prepared_underground_reason,
					surface_reason = prepared_surface_reason,
				}
			end
		end
		stats.moved_dependants = stats.moved_dependants
			+ move_dependants(underground_map, underground_anchor, ux, uy, expected_ux, expected_uy)
		if source_bootstrap then
			stats.moved_dependants = stats.moved_dependants
				+ move_dependants(surface_map, surface_anchor, sx, sy, surface_x, surface_y)
		end
		stats.pairs = stats.pairs + 1
		if surface_radius == 0 then stats.exact = stats.exact + 1
		else stats.fallback = stats.fallback + 1 end
		underground_anchor.SuperBigMapTrueUndergroundPassageHex =
			tostring(plan.final_q) .. ":" .. tostring(plan.final_r)
		surface_anchor.SuperBigMapTrueUndergroundPassageHex =
			underground_anchor.SuperBigMapTrueUndergroundPassageHex
		surface_anchor.SuperBigMapSurfacePassageHex = tostring(surface_q) .. ":" .. tostring(surface_r)
		EntranceAudit(source_bootstrap and "PASSAGE_PLAN_COMMITTED" or "PASSAGE_PLAN_VALIDATED", {
			pair = i,
			algorithm = search_algorithm,
			radius = surface_radius,
			source_x = plan.source_x, source_y = plan.source_y,
			final_x = plan.final_x, final_y = plan.final_y,
			final_q = plan.final_q, final_r = plan.final_r,
			surface_x = surface_x, surface_y = surface_y,
			surface_q = surface_q, surface_r = surface_r,
			surface_before_x = sx, surface_before_y = sy,
			underground_before_x = ux, underground_before_y = uy,
			surface_moved_during_deferred_final = false,
			committed_relocated = false,
		}, underground_map)
	end
	return true, stats
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
	if not map or not cfg_bool("STRETCH_RELOCATE_START_SECTOR", true) then return 0 end
	local city = map.City
	local get_sector = Global("GetMapSectorXY")
	local DoneObject = Global("DoneObject")
	local IsValid = Global("IsValid")
	local point_fn = Global("point")
	if not city or type(get_sector) ~= "function" or type(point_fn) ~= "function" then
		return 0
	end
	local sw = map.SuperBigMapSourceWidthTiles or map.SuperBigMapGeneratorWidthTiles
	local full = map.SuperBigMapDesiredWidthTiles or (map.mapdata and map.mapdata.Width)
	if not (type(sw) == "number" and type(full) == "number" and sw > 0 and full > sw) then
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
				return
			end
			local status = old.status
			-- Move any landed rocket in the old sector to its scaled position (Z-snapped).
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
		end)
	end
	return relocated
end

-- Public API consumed by the stretch-only map-generation pipeline.
local TerrainCopy = {
	ReinvalidateExpandedTerrain = ReinvalidateExpandedTerrain,
	SectorWorldRect = SectorWorldRect,
	FindSectorByName = FindSectorByName,
	SectorBoundary = SectorBoundary,
	StretchSourceToFull = StretchSourceToFull,
	StretchBiomeReady = StretchBiomeReady,
	ScaleDecorationsToFull = ScaleDecorationsToFull,
	ScaleMarkersToFull = ScaleMarkersToFull,
	StretchRelocateStartSector = StretchRelocateStartSector,
	MoveEntranceVisualsToScale = MoveEntranceVisualsToScale,
	AlignPassagePairsToSharedHex = AlignPassagePairsToSharedHex,
	PatchEntranceBadgePosition = PatchEntranceBadgePosition,
	RestoreEntranceBadgePositionPatch = RestoreEntranceBadgePositionPatch,
	RestoreEntranceBadgePositions = RestoreEntranceBadgePositions,
	BeginDeferredElevatorMigration = BeginDeferredElevatorMigration,
	RestoreDeferredElevatorMigration = RestoreDeferredElevatorMigration,
	AnnotateDecorRelief = AnnotateDecorRelief,
	ClearDecorRelief = ClearDecorRelief,
}
SuperBigMap.TerrainCopy = TerrainCopy

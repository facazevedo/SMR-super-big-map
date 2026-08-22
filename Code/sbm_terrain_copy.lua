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

local function cfg_str(key, default)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "string" and value ~= "" then
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

local function TerrainCreaseAudit(event, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.TerrainCreaseRepair) == "function" then
		diagnostics.TerrainCreaseRepair(event, data, map)
	end
end

local function NotifyDeterminismCaptureForTest(stage, map, details)
	local generation = SuperBigMap.MapGeneration
	local notify = type(generation) == "table"
		and generation.NotifyDeterminismCaptureForTest or nil
	if type(notify) ~= "function" then return false end
	return notify(stage, map, details)
end

local function EntranceAudit(event, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.Elevator) == "function" then
		diagnostics.Elevator(event, data, map)
	end
end

-- Diagnostics.Elevator swallows a record when its channel is off, which is the right default for
-- one-line audits. A record whose DATA is expensive to collect must ask first.
local function EntranceAuditEnabled()
	local diagnostics = SuperBigMap.Diagnostics
	if type(diagnostics) ~= "table" then return false end
	local supply = type(diagnostics.ElevatorSupplyEnabled) == "function"
		and diagnostics.ElevatorSupplyEnabled() == true
	local enrichment = type(diagnostics.EnrichmentEnabled) == "function"
		and diagnostics.EnrichmentEnabled() == true
	return supply or enrichment
end

local function UndergroundDecorationAudit(event, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.UndergroundDecoration) == "function" then
		diagnostics.UndergroundDecoration(event, data, map)
	end
end

local function UndergroundDecorationAuditEnabled(map)
	local mapdata = map and map.mapdata
	if type(mapdata) ~= "table" or mapdata.Environment ~= "Underground" then return false end
	local diagnostics = SuperBigMap.Diagnostics
	return diagnostics and type(diagnostics.UndergroundDecorationEnabled) == "function"
		and diagnostics.UndergroundDecorationEnabled() == true
end

-- The wall-forming, selectable underground blockers are CaveInRubble and TunnelBlockerRubble
-- objects. The latter are the live "Collapsed Tunnel" objects spawned from TunnelBlockerMarker.
-- RemovableRocks are ordinary scatter/removal decorations and must not be used as a proxy: doing
-- so made the audit report hundreds of correctly moved rocks while the actual rubble walls
-- (Buildings, and thus skipped by the cosmetic-decoration pass) stayed at source position/size.
local function IsCaveInObject(obj)
	if not obj then return false end
	if IsKindOfSafe(obj, "CaveInRubble") or IsKindOfSafe(obj, "TunnelBlockerRubble") then
		return true
	end
	local class = obj.class
	return class == "CaveInRubble" or class == "TunnelBlockerRubble"
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
local ObjectScalesWithTerrain = ObjectClone.ObjectScalesWithTerrain
assert(type(ShouldSkipObject) == "function" and type(CloneObjectAtOffset) == "function"
	and type(IsImportantSectorObject) == "function"
	and type(ObjectScalesWithTerrain) == "function",
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
local function ReinvalidateExpandedTerrain(map, defer_gameplay_rebuild)
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
	-- StretchSourceToFull has just installed and invalidated the new height/type grids. During the
	-- underground first-access transaction, decorations and wonders still have to move before the
	-- authoritative RebuildPassability/RebuildBuildableGrid pair can run. RebuildGrids here rebuilt
	-- those gameplay grids against an intermediate object layout, costing another full-map pass that
	-- was always discarded a few seconds later. Preserve the cheap border/hash refresh but defer the
	-- gameplay rebuild when the caller guarantees that final synchronization point.
	if defer_gameplay_rebuild == true then
		if type(terrain_api.FixHeightBorder) == "function" and invalidate_box then
			pcall(terrain_api.FixHeightBorder, map, invalidate_box)
		end
		if type(terrain_api.HashGrids) == "function" then
			pcall(terrain_api.HashGrids, map)
		end
		return true
	end

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

-- Resample one EDITOR MapGrid (colour / biome) from the source region (from_box)
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
	-- GetGrid(from_box) is ALWAYS safe: the source region is within any grid's coverage. Keep this
	-- separate from conversion/resampling so the next runtime log identifies the real BiomeGrid
	-- bottleneck instead of reporting one opaque multi-second step.
	local source_token = LoadingBegin("terrain map grid " .. tostring(name)
		.. ": source extraction", map)
	local ok_s, src = pcall(editor_api.GetGrid, map, name, from_box)
	local src_w0, src_h0
	if ok_s and src then src_w0, src_h0 = grid_size(src) end
	LoadingEnd(source_token, {
		source_cells = tostring(src_w0 or "?") .. "x" .. tostring(src_h0 or "?"),
	}, ok_s and src ~= nil)
	if not ok_s or not src then return false end
	local frac = 1.0
	if type(to_box.sizex) == "function" and type(from_box.sizex) == "function" then
		local ok_t, tw = pcall(function() return to_box:sizex() end)
		local ok_f, fw = pcall(function() return from_box:sizex() end)
		if ok_t and ok_f and type(tw) == "number" and tw > 0 and type(fw) == "number" then
			frac = (fw + 0.0) / tw
		end
	end
	local metadata_token = LoadingBegin("terrain map grid " .. tostring(name)
		.. ": destination metadata", map)
	local ref = (type(editor_api.GetGridRef) == "function")
		and SafeCall(editor_api.GetGridRef, map, name) or nil
	local ref_w, ref_h = grid_size(ref)
	local src_w = grid_size(src)
	local target_fmt, target_bits = grid_format(ref)
	if not target_fmt then target_fmt, target_bits = grid_format(src) end
	LoadingEnd(metadata_token, {
		destination_cells = tostring(ref_w or "?") .. "x" .. tostring(ref_h or "?"),
		target_format = tostring(target_fmt or "hierarchical"),
		target_bits = tostring(target_bits or "?"),
	}, true)
	if type(ref_w) == "number" and ref_w > 0 and type(src_w) == "number"
		and src_w > ref_w * (frac + 1.0) / 2 then
		free_grid(src)
		return false
	end
	local dw, dh = ref_w, ref_h
	local dst_ref
	local metadata_source = "grid_ref"
	-- A nil format is valid for ordinary/hierarchical grids: the old path also saw nil from
	-- IsComputeGrid(dst_ref) and skipped GridRepack. Read the full destination only when its
	-- dimensions are unavailable from GetGridRef.
	if type(dw) ~= "number" or dw <= 0 or type(dh) ~= "number" or dh <= 0 then
		local fallback_token = LoadingBegin("terrain map grid " .. tostring(name)
			.. ": destination fallback read", map)
		local ok_d
		ok_d, dst_ref = pcall(editor_api.GetGrid, map, name, to_box)
		LoadingEnd(fallback_token, nil, ok_d and dst_ref ~= nil)
		if not ok_d or not dst_ref then
			free_grid(src)
			return false
		end
		dw, dh = grid_size(dst_ref)
		if not target_fmt then target_fmt, target_bits = grid_format(dst_ref) end
		metadata_source = "full_destination_fallback"
	end
	local src_c, stretched, out
	local write_mode = "editor_set_grid"
	local ok_all, res = pcall(function()
		local convert_token = LoadingBegin("terrain map grid " .. tostring(name)
			.. ": compute conversion", map)
		local ok_convert, converted = pcall(GridToCompute, src)
		LoadingEnd(convert_token, nil, ok_convert and converted ~= nil)
		if not ok_convert or not converted then
			error("MapGrid compute conversion failed: " .. tostring(converted))
		end
		src_c = converted

		local resample_token = LoadingBegin("terrain map grid " .. tostring(name)
			.. ": resample", map, {
				destination_cells = tostring(dw) .. "x" .. tostring(dh),
				interpolate = tostring(interpolate == true),
			})
		local ok_resample, resampled = pcall(GridResample, src_c, dw, dh,
			interpolate == true)
		LoadingEnd(resample_token, nil, ok_resample and resampled ~= nil)
		if not ok_resample or not resampled then
			error("MapGrid resample failed: " .. tostring(resampled))
		end
		stretched = resampled
		out = stretched
		local stretched_fmt, stretched_bits = grid_format(stretched)
		if type(GridRepack) == "function" and target_fmt
			and (stretched_fmt ~= target_fmt or stretched_bits ~= target_bits) then
			local repack_token = LoadingBegin("terrain map grid " .. tostring(name)
				.. ": format repack", map)
			local ok_repack, repacked = pcall(GridRepack, stretched, target_fmt, target_bits)
			LoadingEnd(repack_token, nil, ok_repack and repacked ~= nil)
			if not ok_repack or not repacked then
				error("MapGrid repack failed: " .. tostring(repacked))
			end
			out = repacked
		end

		local write_token = LoadingBegin("terrain map grid " .. tostring(name)
			.. ": destination write", map)
		local ok_set = false
		local map_grid_get_ref = Global("MapGridGetRef")
		local direct_ref = type(map_grid_get_ref) == "function"
			and SafeCall(map_grid_get_ref, map, name) or nil
		local out_w, out_h = grid_size(out)
		local can_direct_copy = cfg_bool("OPTIMIZE_MAP_GRID_DIRECT_COPY", true)
			and direct_ref and direct_ref == ref and type(ref.copy) == "function"
			and out_w == ref_w and out_h == ref_h
		if can_direct_copy then
			ok_set = pcall(ref.copy, ref, out)
			if ok_set then
				write_mode = "vanilla_map_import_direct_copy"
				local invalidate_overlay = Global("DbgInvalidateTerrainOverlay")
				if type(invalidate_overlay) == "function" then
					pcall(invalidate_overlay, to_box)
				end
				local msg = Global("Msg")
				if type(msg) == "function" then pcall(msg, "OnMapGridChanged", map, name, to_box) end
			end
		end
		if not ok_set then
			write_mode = can_direct_copy and "editor_set_grid_after_direct_failure"
				or "editor_set_grid"
			ok_set = pcall(editor_api.SetGrid, map, name, out, to_box)
		end
		LoadingEnd(write_token, { mode = write_mode }, ok_set)
		return ok_set == true
	end)
	if out and out ~= stretched then free_grid(out) end
	if stretched and stretched ~= src_c then free_grid(stretched) end
	if src_c and src_c ~= src then free_grid(src_c) end
	free_grid(dst_ref)
	free_grid(src)
	if not ok_all then
		LoadingStep("terrain map grid " .. tostring(name) .. ": pipeline error", {
			error = tostring(res), metadata_source = metadata_source,
		}, map)
	end
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
-- measured_max is the measured final grid maximum when whole-map normalization was required.
-- It caps the declared upper range at the terrain ceiling instead of allowing the original
-- range endpoint's affine projection to extend beyond what the buildable grid can represent.
local function ScaleHeightRanges(map, mul, div, add_wu, measured_max)
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
	-- Grid height units -> metres. The engine states the terrain ceiling as
	-- const.MaxTerrainHeight world units over const.TerrainHeightScale units per grid step.
	local measured_to
	if type(measured_max) == "number" and measured_max > 0 then
		local const_tbl = Global("const")
		local hscale = (type(const_tbl) == "table" and type(const_tbl.TerrainHeightScale) == "number"
			and const_tbl.TerrainHeightScale > 0) and const_tbl.TerrainHeightScale or 1
		measured_to = math.ceil((measured_max * hscale + 0.0) / guim_v)
	end
	local function scale_range(tag, range)
		if type(range) ~= "table" or type(range.from) ~= "number" or type(range.to) ~= "number" then
			return
		end
		local from0, to0 = range.from, range.to
		range.from = scale_out(from0, false)
		range.to = measured_to or scale_out(to0, true)
		if range.to <= range.from then range.to = range.from + 1 end
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

-- ---------------------------------------------------------------------------------------------
-- WHOLE-MAP HEIGHT NORMALIZATION
--
-- Version 738's surface transform normalized the full SOURCE height span into the available U16
-- range. Its one-metre floor leaves almost the entire range available for relief, avoiding the
-- visibly flattened mountains produced by reserving a five-metre floor.
local Z_FLOOR_WU = 1000

-- A few vanilla height fields contain long one-cell discontinuities in their perimeter terrain.
-- Resampling makes those bad source edges much easier to see as striped vertical walls. Detect
-- coherent steps facing any grid edge within the two-sector outer ring. Wide-ring source discovery
-- is read-only and returns track hints for the destination-resolution border repair below; the
-- immediate-edge destination pass still performs version 839's complete translation and quintic
-- interpolation here. The central 16 x 16 sectors are never scanned, ordinary broken Rough Terrain
-- cliffs fail the long/dense-track gate, and version 738's affine transform still runs exactly once.
local function RepairInternalHeightStep(grid, wide_ring_only)
	local GridMinMax = Global("GridMinMax")
	if type(GridMinMax) ~= "function" or not grid or type(grid.size) ~= "function"
		or type(grid.get) ~= "function" or type(grid.set) ~= "function" then
		return false, { reason = "height-grid access unavailable" }
	end
	local ok_size, w, h = pcall(grid.size, grid)
	if not ok_size or type(w) ~= "number" or type(h) ~= "number" or w < 8 or h < 2 then
		return false, { reason = "height grid too small" }
	end
	local ok_mm, mn, mx = pcall(GridMinMax, grid)
	if not ok_mm or type(mn) ~= "number" or type(mx) ~= "number" or mx <= mn then
		return false, { reason = "height range unavailable" }
	end


	local relief = mx - mn
	-- A source crease can be about 0.7-1.0% of total relief per cell. The former 2.5%
	-- threshold was therefore higher than the wall itself and guaranteed a no-op on that map.
	local threshold = math.max(256, math.floor(relief * 0.005 + 0.5))
	-- The expanded map has 20 sectors per side. Scan exactly the two outermost sector widths.
	-- Some maps also carry a second coherent defect farther inside the outer ring, hundreds of samples
	-- from the physical edge, which the former 64-cell skirt scan could never observe.
	local edge_margin = math.min(math.min(w, h) - 3,
		math.max(8, math.ceil(math.min(w, h) * 2 / 20)))
	-- Preserve the inexpensive full-resolution scan used by v839 beside the physical edge. The
	-- remainder of the two-sector ring is sampled every eight rows; a qualified sampled path is
	-- still refined on every individual row below.
	local near_margin = math.min(64, math.max(8, math.floor(math.min(w, h) / 192)))
	local wide_sample_step = 8
	-- The last eight samples are the engine's physical map-edge guard, not rendered terrain. A
	-- coherent sentinel transition there can dwarf the real source-skirt crease and must never be
	-- translated into the map. Source boundaries can resample tens of cells inward.
	local outer_guard = math.min(8, math.max(2, math.floor(math.min(w, h) / 1024)))
	local max_per_row = 6
	local max_row_gap = 4
	local tracks = {}
	local track_counts = { left = 0, right = 0, top = 0, bottom = 0 }
	local selected_tracks = {}

	local function at(axis, perp, along)
		if axis == "x" then return grid:get(perp, along) end
		return grid:get(along, perp)
	end

	local function put(axis, perp, along, value)
		if axis == "x" then grid:set(perp, along, value) else grid:set(along, perp, value) end
	end

	local function feather_join(axis, along, lo, hi)
		-- Blend two locally extrapolated terrain slopes with a quintic weight. The weight has zero
		-- first and second derivatives at both ends, so the repaired strip meets the untouched high
		-- terrain and translated low terrain without a lighting/curvature seam. Only the narrow
		-- cross-skirt join is resynthesized; relative relief on either side remains intact.
		if hi - lo < 4 then return 0 end
		local v0, v0_prev = at(axis, lo, along), at(axis, lo - 1, along)
		local v1, v1_next = at(axis, hi, along), at(axis, hi + 1, along)
		if type(v0) ~= "number" or type(v0_prev) ~= "number"
			or type(v1) ~= "number" or type(v1_next) ~= "number" then return 0 end
		local slope0, slope1 = v0 - v0_prev, v1_next - v1
		local span, changed = hi - lo, 0
		for p = lo + 1, hi - 1 do
			local t = (p - lo + 0.0) / span
			local smooth = t * t * t * (t * (t * 6 - 15) + 10)
			local left = v0 + slope0 * (p - lo)
			local right = v1 + slope1 * (p - hi)
			local value = math.floor(left + (right - left) * smooth + 0.5)
			put(axis, p, along, math.max(0, math.min(mx, value)))
			changed = changed + 1
		end
		return changed
	end

	local function offer_candidate(row, axis, perp, width, edge, low_before, jump)
		-- Collapse several adjacent samples from the same cliff face to its strongest edge.
		for i = 1, #row do
			if row[i].edge == edge and math.abs(row[i].perp - perp) <= 3 then
				if jump > row[i].jump then
					row[i] = {
						axis = axis, perp = perp, width = width, edge = edge,
						low_before = low_before, jump = jump,
					}
				end
				return
			end
		end
		row[#row + 1] = {
			axis = axis, perp = perp, width = width, edge = edge,
			low_before = low_before, jump = jump,
		}
		table.sort(row, function(a, b) return a.jump > b.jump end)
		if #row > max_per_row then row[#row] = nil end
	end

	local function scan_line_range(row, axis, along, perp0, perp1, edge)
		if perp1 < perp0 then return end
		for perp = perp0, perp1 do
			-- Bilinear resampling spreads a one-source-cell step across two destination cells at
			-- 6144 -> 8192. Inspect spans through three cells so two half-jumps at a resampled
			-- x=8160/8161 boundary are evaluated as the original coherent discontinuity. Endpoint
			-- flanks still reject an ordinary sustained slope. On the vanilla-size source pass the
			-- discontinuity is still one cell wide, so wider probes only waste startup time.
			local max_width = wide_ring_only and 1 or 3
			for width = 1, max_width do
				local v0, a = at(axis, perp - 1, along), at(axis, perp, along)
				local b, v3 = at(axis, perp + width, along),
					at(axis, perp + width + 1, along)
				if type(v0) == "number" and type(a) == "number" and type(b) == "number"
					and type(v3) == "number" then
					local jump = math.abs(b - a)
					local flank = math.max(math.abs(a - v0), math.abs(v3 - b), 1)
					local low_before = a < b
					local before_edge = edge == "left" or edge == "top"
					local low_points_to_edge = (before_edge and low_before)
						or (not before_edge and not low_before)
					-- Wide-ring discovery is sign agnostic: a resampling defect may be either a
					-- depressed or a raised strip.  The immediate physical-edge pass retains the
					-- proven v839 rule (only translate a lower region toward its adjacent edge).
					if (wide_ring_only or low_points_to_edge)
						and jump >= threshold and jump >= flank * 2 then
						offer_candidate(row, axis, perp, width, edge, low_before, jump)
					end
				end
			end
		end
	end

	local function collect_axis(axis, perp_n, along_n, before_edge, after_edge,
			before_perp0, before_perp1, after_perp0, after_perp1, sample_step)
		local active = {}
		sample_step = math.max(1, sample_step or 1)
		for along = 0, along_n - 1, sample_step do
			local row = {}
			scan_line_range(row, axis, along, before_perp0, before_perp1, before_edge)
			scan_line_range(row, axis, along, after_perp0, after_perp1, after_edge)

			local used = {}
			for _, candidate in ipairs(row) do
				local best_i, best_distance
				for i, track in ipairs(active) do
					if not used[i] and candidate.edge == track.edge
						and candidate.low_before == track.low_before
						and along - track.last_along <= max_row_gap * sample_step then
						local distance = math.abs(candidate.perp - track.last_perp)
						-- Wide-ring discovery is deliberately grid-aligned: inherited height-field seams
						-- stay almost fixed in the perpendicular coordinate. Do not let a sampled path
						-- wander onto a neighbouring natural contour between eight-row samples.
						local allowed_distance = sample_step > 1 and 3
							or 5 * (along - track.last_along)
						if distance <= allowed_distance
							and (not best_distance or distance < best_distance) then
							best_i, best_distance = i, distance
						end
					end
				end
				local track = best_i and active[best_i] or nil
				if not track then
					track = {
						axis = axis, edge = candidate.edge, low_before = candidate.low_before,
							perp_n = perp_n, along_n = along_n,
							sample_step = sample_step,
						first_along = along, last_along = along,
						last_perp = candidate.perp, count = 0,
						sum_jump = 0, max_jump = 0, points = {},
					}
					tracks[#tracks + 1] = track
					track_counts[candidate.edge] = track_counts[candidate.edge] + 1
					active[#active + 1] = track
					best_i = #active
				end
				used[best_i] = true
				track.last_along, track.last_perp = along, candidate.perp
				track.count = track.count + 1
				track.sum_jump = track.sum_jump + candidate.jump
				track.max_jump = math.max(track.max_jump, candidate.jump)
				track.points[#track.points + 1] = {
					perp = candidate.perp, width = candidate.width,
					along = along, jump = candidate.jump,
				}
			end

			local still_active = {}
			for _, track in ipairs(active) do
				if along - track.last_along <= max_row_gap * sample_step then
					still_active[#still_active + 1] = track
				end
			end
			active = still_active
		end
	end

	local function refine_step(track, along, predicted)
		local before_edge = track.edge == "left" or track.edge == "top"
		local lo = math.max(1, predicted - 6)
		local hi = math.min(track.perp_n - 3, predicted + 6)
		local best_perp, best_width, best_distance, best_jump
		for perp = lo, hi do
			for width = 1, 3 do
				local v0, a = at(track.axis, perp - 1, along), at(track.axis, perp, along)
				local b, v3 = at(track.axis, perp + width, along),
					at(track.axis, perp + width + 1, along)
				if type(v0) == "number" and type(a) == "number" and type(b) == "number"
					and type(v3) == "number" then
					local low_before = a < b
					local points_to_edge = (before_edge and low_before)
						or (not before_edge and not low_before)
					local jump = math.abs(b - a)
					local flank = math.max(math.abs(a - v0), math.abs(v3 - b), 1)
					local distance = math.abs(perp - predicted)
					-- Interpolated gaps must satisfy the identical directional, contrast, and flank
					-- tests as stored candidates. Choosing an arbitrary stronger outward drop here
					-- could extend a repaired strip to a neighbouring natural contour.
					local direction_matches = low_before == track.low_before
					if direction_matches and (wide_ring_only or points_to_edge)
						and jump >= threshold and jump >= flank * 2
						and (not best_distance or distance < best_distance
							or (distance == best_distance and jump > best_jump)) then
						best_perp, best_width = perp, width
						best_distance, best_jump = distance, jump
					end
				end
			end
		end
		return best_perp, best_width
	end

	local function validate_sampled_track(track)
		if (track.sample_step or 1) <= 1 then return end
		local predictions = {}
		local function add_prediction(along, perp, width, jump)
			if along >= 0 and along < track.along_n then
				predictions[#predictions + 1] = {
					along = along, perp = perp, width = width, jump = jump,
				}
			end
		end
		for i, point in ipairs(track.points) do
			add_prediction(point.along, point.perp, point.width, point.jump)
			local next_point = track.points[i + 1]
			if next_point then
				local gap = next_point.along - point.along
				for da = 1, gap - 1 do
					local t = (da + 0.0) / gap
					add_prediction(point.along + da,
						math.floor(point.perp + (next_point.perp - point.perp) * t + 0.5),
						math.floor(point.width + (next_point.width - point.width) * t + 0.5),
						math.floor(point.jump + (next_point.jump - point.jump) * t + 0.5))
				end
			end
		end
		local validated = {}
		local function validated_point(along, predicted)
			local perp, width = refine_step(track, along, predicted)
			if not perp then return end
			local a = at(track.axis, perp, along)
			local b = at(track.axis, perp + width, along)
			return { along = along, perp = perp, width = width, jump = math.abs(b - a) }
		end
		for _, prediction in ipairs(predictions) do
			local point = validated_point(prediction.along, prediction.perp)
			if point then validated[#validated + 1] = point end
		end

		-- A sampled endpoint may fall just before a taper where only the two/three-cell validation
		-- probe still sees the inherited step. Walk outward until four consecutive rows fail instead
		-- of leaving a short segment-end cap after the last width-one hit.
		if #validated > 0 then
			local prefix, first = {}, validated[1]
			local misses = 0
			for delta = 1, track.sample_step * 4 do
				local along = first.along - delta
				if along < 0 then break end
				local point = validated_point(along, first.perp)
				if point then
					prefix[#prefix + 1] = point
					misses = 0
				else
					misses = misses + 1
					if misses >= 4 then break end
				end
			end
			for i = 1, #prefix do table.insert(validated, 1, prefix[i]) end

			local last = validated[#validated]
			misses = 0
			for delta = 1, track.sample_step * 4 do
				local along = last.along + delta
				if along >= track.along_n then break end
				local point = validated_point(along, last.perp)
				if point then
					validated[#validated + 1] = point
					misses = 0
				else
					misses = misses + 1
					if misses >= 4 then break end
				end
			end
		end

		local sum_jump, max_jump = 0, 0
		for _, point in ipairs(validated) do
			sum_jump = sum_jump + point.jump
			max_jump = math.max(max_jump, point.jump)
		end
		track.points = validated
		track.count = #validated
		track.sum_jump = sum_jump
		track.max_jump = max_jump
		track.sample_step = 1
		if #validated > 0 then
			track.first_along = validated[1].along
			track.last_along = validated[#validated].along
			track.last_perp = validated[#validated].perp
		end
	end

	local pause = Global("PauseInfiniteLoopDetection")
	local resume = Global("ResumeInfiniteLoopDetection")
	if type(pause) == "function" then pcall(pause, "SBMInternalHeightStepRepair") end
	local ok_repair, repair_err = pcall(function()
		-- X scans catch left/right edge-facing walls; transposed Y scans catch top/bottom walls.
		-- Keep v839's full-resolution near-edge pass, then coarsely discover paths in the rest of
		-- the two-sector ring. Every accepted coarse path is refined per-row before it can write.
		local function collect_ring(axis, perp_n, along_n, before_edge, after_edge)
			if not wide_ring_only then
				collect_axis(axis, perp_n, along_n, before_edge, after_edge,
					outer_guard, math.min(near_margin, perp_n - 3),
					math.max(1, perp_n - near_margin - 2),
					perp_n - outer_guard - 3, 1)
			elseif edge_margin > near_margin + 4 then
				collect_axis(axis, perp_n, along_n, before_edge, after_edge,
					near_margin + 1, math.min(edge_margin, perp_n - 3),
					math.max(1, perp_n - edge_margin - 2),
					perp_n - near_margin - 3, wide_sample_step)
			end
		end
		collect_ring("x", w, h, "left", "right")
		collect_ring("y", h, w, "top", "bottom")

		local qualified = {}
		for _, track in ipairs(tracks) do
			local coarse_span = track.last_along - track.first_along + 1
			local coarse_min_perp, coarse_max_perp
			for _, point in ipairs(track.points) do
				coarse_min_perp = not coarse_min_perp and point.perp
					or math.min(coarse_min_perp, point.perp)
				coarse_max_perp = not coarse_max_perp and point.perp
					or math.max(coarse_max_perp, point.perp)
			end
			local coarse_perp_span = (coarse_max_perp or 0) - (coarse_min_perp or 0)
			local coarse_straight = not wide_ring_only
				or coarse_perp_span <= math.max(3, math.floor(coarse_span / 100))
			-- Coarse discovery is read-only. Before a wide-ring path can write anything, rescan its
			-- complete physical span and require the same per-row contrast/direction test as v839.
			if coarse_straight then validate_sampled_track(track) end
			local span = track.last_along - track.first_along + 1
			local samples_in_span = math.floor((span - 1) / track.sample_step) + 1
			-- This runtime performs integer division for int/int. Promote explicitly: otherwise a
			-- real 1,192-of-1,194-cell boundary track reads as density ZERO and is discarded.
			local dense = samples_in_span > 0
				and (track.count + 0.0) / samples_in_span or 0
			local average = track.count > 0 and track.sum_jump / track.count or 0
			-- A span-based detector also sees short steep pieces of ordinary outer mountains. Only
			-- a long, dense line is the inherited source-grid boundary that can become the user's
			-- segmented wall. This retains the long coherent perimeter runs while rejecting the
			-- 1,200+ short fragments found by the first multi-cell candidate.
			local min_span = math.max(96, math.floor(track.along_n / 50))
			local min_count = math.max(8, math.ceil(min_span / track.sample_step))
			local min_perp, max_perp
			for _, point in ipairs(track.points) do
				min_perp = not min_perp and point.perp or math.min(min_perp, point.perp)
				max_perp = not max_perp and point.perp or math.max(max_perp, point.perp)
			end
			local perp_span = (max_perp or 0) - (min_perp or 0)
			local straight = not wide_ring_only
				or perp_span <= math.max(3, math.floor(span / 100))
			if coarse_straight and straight and track.count >= min_count and dense >= 0.95
				and average >= threshold * 1.25 and track.max_jump >= threshold * 1.75 then
				track.score = track.sum_jump * dense
				qualified[#qualified + 1] = track
			end
		end
		if #qualified == 0 then return end
		table.sort(qualified, function(a, b) return a.score > b.score end)
		-- The length/density/average/max gate above reduces the first multi-cell attempt's 1,249
		-- fragments to a small coherent boundary cohort. Keep all of those tracks: a
		-- second relative-score cutoff discarded a real bottom segment and left a 1,171-cell wall.
		selected_tracks = qualified

		for _, selected in ipairs(selected_tracks) do
			-- Fill short detection gaps so the translated region cannot retain isolated wall stripes.
			local points = {}
			local first_point = selected.points[1]
			if first_point and selected.sample_step > 1 then
				for along = math.max(0, first_point.along - selected.sample_step + 1),
						first_point.along - 1 do
					points[#points + 1] = {
						perp = first_point.perp, width = first_point.width,
						along = along, jump = first_point.jump,
					}
				end
			end
			for i, point in ipairs(selected.points) do
				points[#points + 1] = point
				local next_point = selected.points[i + 1]
				if next_point and next_point.along > point.along + 1 then
					local gap = next_point.along - point.along
					for da = 1, gap - 1 do
						local t = (da + 0.0) / gap
						points[#points + 1] = {
							perp = math.floor(point.perp
								+ (next_point.perp - point.perp) * t + 0.5),
							width = math.floor(point.width
								+ (next_point.width - point.width) * t + 0.5),
							along = point.along + da,
							jump = math.floor(point.jump
								+ (next_point.jump - point.jump) * t + 0.5),
						}
					end
				end
			end
			local last_point = selected.points[#selected.points]
			if last_point and selected.sample_step > 1 then
				for along = last_point.along + 1,
						math.min(selected.along_n - 1,
							last_point.along + selected.sample_step - 1) do
					points[#points + 1] = {
						perp = last_point.perp, width = last_point.width,
						along = along, jump = last_point.jump,
					}
				end
			end

			local modified, detected = 0, 0
			local min_offset, max_offset
			for _, point in ipairs(points) do
				local along = point.along
				local perp, width = refine_step(selected, along, point.perp)
				if perp then
					local before_edge = selected.edge == "left" or selected.edge == "top"
					-- Wide discovery is sign agnostic, so derive the low/high samples from
					-- the measured boundary direction instead of assuming the low side is
					-- always the side facing the physical edge.  The near-edge write pass
					-- has already admitted only that direction, making this equivalent there.
					local low_perp = selected.low_before and perp or perp + width
					local high_perp = selected.low_before and perp + width or perp
					local low = at(selected.axis, low_perp, along)
					local high = at(selected.axis, high_perp, along)
					if type(low) == "number" and type(high) == "number" and high > low then
						local offset = high - low
						min_offset = not min_offset and offset or math.min(min_offset, offset)
						max_offset = not max_offset and offset or math.max(max_offset, offset)
						detected = detected + 1
						-- Wide-ring discovery is read-only. The proven v839 border algorithm must see
						-- and repair the real resampled wall at destination resolution; translating here
						-- first forced later passes to synthesize an already erased boundary and produced
						-- a straight pale strip in the destination terrain.
						if not wide_ring_only then
							-- Translate the low region. The feather below then replaces the inherited
							-- resampling ramp and a few samples on both sides with a slope-matched join.
							local perp0 = before_edge and 0 or perp + width
							local perp1 = before_edge and perp or selected.perp_n - 1
							for p = perp0, perp1 do
								local original = at(selected.axis, p, along)
								if type(original) == "number" then
									put(selected.axis, p, along, math.min(mx, original + offset))
									modified = modified + 1
								end
							end
							local join_lo, join_hi
							if before_edge then
								join_lo = math.max(outer_guard + 1, perp - 6)
								join_hi = math.min(selected.perp_n - 2, perp + width + 12)
							else
								join_lo = math.max(1, perp - 12)
								join_hi = math.min(selected.perp_n - outer_guard - 2,
									perp + width + 6)
							end
							modified = modified
								+ feather_join(selected.axis, along, join_lo, join_hi)
						end
					end
				end
			end
			selected.modified = modified
			selected.detected = detected
			selected.min_offset = min_offset
			selected.max_offset = max_offset
		end
		selected_tracks[1].qualified = #qualified
	end)
	if type(resume) == "function" then pcall(resume, "SBMInternalHeightStepRepair") end
	if not ok_repair then
		return false, { reason = tostring(repair_err), threshold = threshold, min = mn, max = mx }
	end

	local modified, detected = 0, 0
	local edges, axes = {}, {}
	local min_offset, max_offset
	for _, selected in ipairs(selected_tracks) do
		modified = modified + (selected.modified or 0)
		detected = detected + (selected.detected or 0)
		edges[#edges + 1] = selected.edge
		axes[#axes + 1] = selected.axis
		if selected.min_offset then
			min_offset = not min_offset and selected.min_offset
				or math.min(min_offset, selected.min_offset)
			max_offset = not max_offset and selected.max_offset
				or math.max(max_offset, selected.max_offset)
		end
	end
	if (wide_ring_only and detected <= 0) or (not wide_ring_only and modified <= 0) then
		return false, {
			reason = "no edge-facing outer-ring step", threshold = threshold,
			edge_margin = wide_ring_only and edge_margin or near_margin,
			outer_guard = outer_guard, candidates = #tracks,
			left_tracks = track_counts.left, right_tracks = track_counts.right,
			top_tracks = track_counts.top, bottom_tracks = track_counts.bottom,
			min = mn, max = mx,
		}
	end
	local primary = selected_tracks[1]
	return true, {
		reason = wide_ring_only
			and "vanilla outer-ring steps detected for destination border interpolation"
			or "destination edge lower regions translated with slope-matched feathered joins",
		threshold = threshold,
		edge_margin = wide_ring_only and edge_margin or near_margin, outer_guard = outer_guard,
		axis = table.concat(axes, ","), edge = table.concat(edges, ","),
		first_along = primary.first_along, last_along = primary.last_along,
		edge_perp = primary.last_perp, rows = primary.count,
		repairs = #selected_tracks, qualified = primary.qualified,
		modified = modified, detected = detected,
		min_offset = min_offset, max_offset = max_offset,
		left_tracks = track_counts.left, right_tracks = track_counts.right,
		top_tracks = track_counts.top, bottom_tracks = track_counts.bottom,
		min = mn, max = mx,
	}, selected_tracks
end

-- Finish source-qualified defects after resampling.  A single boundary denotes a strip which
-- reaches its adjacent physical edge; two overlapping, opposite-facing boundaries denote a finite
-- raised/depressed strip.  Edge strips retain v839's translate-plus-quintic row repair, but the
-- complete repaired row is blended in two dimensions with a C2 envelope at the track endpoints.
-- This removes the abrupt row starts which made a second, perpendicular scar.  A finite strip is
-- raised/lowered and tilted between both flanks, then joined to both sides with the same C2 row
-- interpolation.  Detection and correction are sign agnostic and are confined to the two-sector
-- source-qualified outer ring; no map, seed, or coordinate is used here.
local function FinishResampledHeightStepsWithBorderInterpolation(grid,
		source_w, source_h, source_tracks)
	local GridMinMax = Global("GridMinMax")
	if type(GridMinMax) ~= "function" or not grid or type(grid.size) ~= "function"
		or type(grid.get) ~= "function" or type(grid.set) ~= "function"
		or type(source_tracks) ~= "table" or #source_tracks == 0
		or type(source_w) ~= "number" or source_w < 2
		or type(source_h) ~= "number" or source_h < 2 then
		return false, { reason = "no qualified source tracks" }
	end
	local ok_size, w, h = pcall(grid.size, grid)
	if not ok_size or type(w) ~= "number" or type(h) ~= "number" or w < 8 or h < 8 then
		return false, { reason = "destination height grid unavailable" }
	end
	local ok_mm, mn, mx = pcall(GridMinMax, grid)
	if not ok_mm or type(mn) ~= "number" or type(mx) ~= "number" or mx <= mn then
		return false, { reason = "destination height range unavailable" }
	end

	local relief = mx - mn
	local threshold = math.max(256, math.floor(relief * 0.005 + 0.5))
	local outer_guard = math.min(8, math.max(2, math.floor(math.min(w, h) / 1024)))
	local function at(axis, perp, along)
		if axis == "x" then return grid:get(perp, along) end
		return grid:get(along, perp)
	end
	local function put(axis, perp, along, value)
		if axis == "x" then grid:set(perp, along, value) else grid:set(along, perp, value) end
	end
	local function mapped_index(value, source_n, destination_n)
		return math.max(0, math.min(destination_n - 1,
			math.floor(value * destination_n / source_n + 0.5)))
	end
	local function quintic(t)
		t = math.max(0, math.min(1, t))
		return t * t * t * (t * (t * 6 - 15) + 10)
	end
	local function refine_step(axis, perp_n, along, predicted, expected_low_before)
		local lo = math.max(1, predicted - 6)
		local hi = math.min(perp_n - 3, predicted + 6)
		local best_perp, best_width, best_distance, best_jump
		for perp = lo, hi do
			for width = 1, 3 do
				local v0, a = at(axis, perp - 1, along), at(axis, perp, along)
				local b, v3 = at(axis, perp + width, along),
					at(axis, perp + width + 1, along)
				if type(v0) == "number" and type(a) == "number" and type(b) == "number"
					and type(v3) == "number" then
					local low_before = a < b
					local jump = math.abs(b - a)
					local flank = math.max(math.abs(a - v0), math.abs(v3 - b), 1)
					local distance = math.abs(perp - predicted)
					if low_before == expected_low_before
						and jump >= threshold and jump >= flank * 2
						and (not best_distance or distance < best_distance
							or (distance == best_distance and jump > best_jump)) then
						best_perp, best_width = perp, width
						best_distance, best_jump = distance, jump
					end
				end
			end
		end
		return best_perp, best_width, best_jump
	end

	local function smooth_profile(profile, lo, hi, radius, passes)
		for _ = 1, passes do
			local next_profile = {}
			for along = lo, hi do
				local sum, count = 0, 0
				for q = math.max(lo, along - radius), math.min(hi, along + radius) do
					sum, count = sum + (profile[q] or 0), count + 1
				end
				next_profile[along] = sum / math.max(1, count)
			end
			profile = next_profile
		end
		return profile
	end
	local function signed_after_correction(axis, perp, width, along)
		local before_prev = at(axis, perp - 1, along)
		local before = at(axis, perp, along)
		local after = at(axis, perp + width, along)
		local after_next = at(axis, perp + width + 1, along)
		if type(before_prev) ~= "number" or type(before) ~= "number"
			or type(after) ~= "number" or type(after_next) ~= "number" then return nil end
		-- Preserve the terrain's local grade through the resampled ramp.  Matching AFTER directly
		-- to BEFORE made an otherwise continuous hillside locally level; the resulting planar ribbon
		-- had a bright straight shoulder at its far side even though the original step was gone.
		-- Extrapolate the two untouched flank slopes through the ramp and translate AFTER only by the
		-- unexplained residual.  The detector guarantees the ramp dominates both flank slopes; the
		-- half-offset clamp is a final guard against an unusual pair of disagreeing natural slopes.
		local raw = before - after
		local slope = ((before - before_prev) + (after_next - after)) * 0.5
		local correction = raw + slope * width
		if raw > 0 then
			correction = math.max(raw * 0.5, math.min(raw * 1.5, correction))
		else
			correction = math.min(raw * 0.5, math.max(raw * 1.5, correction))
		end
		return correction
	end
	local function blend_value(original, target, alpha)
		return math.max(0, math.min(mx,
			math.floor(original + (target - original) * alpha + 0.5)))
	end

	local modified, rows, tracks, min_offset, max_offset = 0, 0, 0
	local coherent_profile_modified, coherent_profile_rows = 0, 0
	local bounded_strips, edge_strips = 0, 0
	local pause = Global("PauseInfiniteLoopDetection")
	local resume = Global("ResumeInfiniteLoopDetection")
	if type(pause) == "function" then pcall(pause, "SBMResampledBorderInterpolation") end
	local ok_finish, finish_err = pcall(function()
		local plans = {}
		for _, source_track in ipairs(source_tracks) do
			local axis, edge = source_track.axis, source_track.edge
			local source_perp_n = axis == "x" and source_w or source_h
			local source_along_n = axis == "x" and source_h or source_w
			local destination_perp_n = axis == "x" and w or h
			local destination_along_n = axis == "x" and h or w
			local mapped = {}
			for _, point in ipairs(source_track.points or {}) do
				mapped[#mapped + 1] = {
					along = mapped_index(point.along, source_along_n, destination_along_n),
					perp = mapped_index(point.perp, source_perp_n, destination_perp_n),
				}
			end
			if #mapped > 0 then
				tracks = tracks + 1
				local processed = {}
				local samples, first_along, last_along = {}, nil, nil
				for i, point in ipairs(mapped) do
					local next_point = mapped[i + 1]
					local segment_last_along = next_point and next_point.along - 1 or point.along
					segment_last_along = math.max(point.along, segment_last_along)
					for along = point.along, segment_last_along do
						if not processed[along] then
							processed[along] = true
							local t = next_point and next_point.along > point.along
								and (along - point.along + 0.0)
									/ (next_point.along - point.along) or 0
							local predicted = math.floor(point.perp + (next_point and
								(next_point.perp - point.perp) * t or 0) + 0.5)
							local perp, width = refine_step(axis,
								destination_perp_n, along, predicted,
								source_track.low_before == true)
							if perp then
								local correction = signed_after_correction(axis, perp, width, along)
								if type(correction) == "number" then
									local magnitude = math.abs(correction)
									min_offset = not min_offset and magnitude or math.min(min_offset, magnitude)
									max_offset = not max_offset and magnitude or math.max(max_offset, magnitude)
									samples[along] = {
										perp = perp, width = width, correction_after = correction,
									}
									first_along = not first_along and along or math.min(first_along, along)
									last_along = not last_along and along or math.max(last_along, along)
								end
							end
						end
					end
				end
				if first_along and last_along then
					local sum_perp, sum_correction, sample_count = 0, 0, 0
					for _, sample in pairs(samples) do
						sum_perp = sum_perp + sample.perp
						sum_correction = sum_correction + sample.correction_after
						sample_count = sample_count + 1
					end
					plans[#plans + 1] = {
						axis = axis, edge = edge, perp_n = destination_perp_n,
						along_n = destination_along_n,
						first_along = first_along, last_along = last_along, samples = samples,
						low_before = source_track.low_before == true,
						mean_perp = sum_perp / math.max(1, sample_count),
						mean_correction_after = sum_correction / math.max(1, sample_count),
					}
				end
			end
		end

		local function densify(plan)
			local keys = {}
			for along in pairs(plan.samples) do keys[#keys + 1] = along end
			table.sort(keys)
			local geometry, profile = {}, {}
			for i, along0 in ipairs(keys) do
				local a = plan.samples[along0]
				local along1 = keys[i + 1] or along0
				local b = plan.samples[along1] or a
				for along = along0, along1 do
					local t = along1 > along0 and (along - along0 + 0.0) / (along1 - along0) or 0
					geometry[along] = {
						perp = math.floor(a.perp + (b.perp - a.perp) * t + 0.5),
						width = math.floor(a.width + (b.width - a.width) * t + 0.5),
					}
					profile[along] = a.correction_after
						+ (b.correction_after - a.correction_after) * t
				end
			end
			profile = smooth_profile(profile, plan.first_along, plan.last_along, 2, 2)
			return geometry, profile
		end

		local paired, pairs = {}, {}
		for i = 1, #plans do
			if not paired[i] then
				local best_j, best_distance
				for j = i + 1, #plans do
					local a, b = plans[i], plans[j]
					local overlap = math.min(a.last_along, b.last_along)
						- math.max(a.first_along, b.first_along) + 1
					local min_span = math.min(a.last_along - a.first_along + 1,
						b.last_along - b.first_along + 1)
					local distance = math.abs(a.mean_perp - b.mean_perp)
					local left, right = a, b
					if left.mean_perp > right.mean_perp then left, right = right, left end
					local enclosed_same_direction = left.mean_correction_after
						* (-right.mean_correction_after) > 0
					if not paired[j] and a.axis == b.axis and a.edge == b.edge
						and a.low_before ~= b.low_before and overlap >= min_span * 0.75
						and enclosed_same_direction
						and distance >= 8 and distance <= a.perp_n / 10
						and (not best_distance or distance < best_distance) then
						best_j, best_distance = j, distance
					end
				end
				if best_j then
					paired[i], paired[best_j] = true, true
					pairs[#pairs + 1] = { plans[i], plans[best_j] }
				end
			end
		end
		bounded_strips = #pairs
		edge_strips = #plans - bounded_strips * 2

		local function endpoint_alpha(along, first_along, last_along, taper)
			-- This runtime uses integer division for int/int.  Promote before constructing the
			-- envelope or the intended C2 taper collapses back into a one-row step.
			if along < first_along then
				return quintic((along - (first_along - taper) + 0.0) / taper)
			end
			if along > last_along then
				return 1 - quintic((along - last_along + 0.0) / taper)
			end
			return 1
		end

		local function apply_edge(plan)
			local geometry, profile = densify(plan)
			-- The source-qualified interior step is already localized to a 1--3-cell
			-- resampling ramp.  Reconstruct only that abnormal ramp, using the adjacent
			-- untouched samples as slope constraints.  Including those constraints in
			-- the writable band erased real relief and exposed the band as a pale ribbon.
			-- One anchor sample gives the 1--3-cell ramp enough room to match both slopes
			-- without creating the sharp normal that a zero-anchor reconstruction leaves.
			local anchor = 1
			local taper = math.min(40, math.max(20,
				math.floor((plan.last_along - plan.first_along + 1) / 6)))
			local lo_along = math.max(0, plan.first_along - taper)
			local hi_along = math.min(plan.along_n - 1, plan.last_along + taper)
			local first_geometry = geometry[plan.first_along]
			local last_geometry = geometry[plan.last_along]
			local before_edge = plan.edge == "left" or plan.edge == "top"
			local band_lo, band_hi = plan.perp_n - 1, 0
			for along = plan.first_along, plan.last_along do
				local sample = geometry[along]
				if sample then
					band_lo = math.min(band_lo, sample.perp - anchor)
					band_hi = math.max(band_hi, sample.perp + sample.width + anchor)
				end
			end
			band_lo = math.max(1, band_lo)
			band_hi = math.min(plan.perp_n - 2, band_hi)
			local band, correction_by_along, alpha_by_along = {}, {}, {}
			for along = lo_along, hi_along do
				local sample = geometry[along]
					or (along < plan.first_along and first_geometry or last_geometry)
				local correction_after = profile[along]
					or (along < plan.first_along and profile[plan.first_along]
						or profile[plan.last_along])
				local alpha = endpoint_alpha(along, plan.first_along, plan.last_along, taper)
				if sample and type(correction_after) == "number" and alpha > 0 then
					local correction = before_edge and -correction_after or correction_after
					correction_by_along[along] = correction
					alpha_by_along[along] = alpha
					local join_lo = math.max(1, sample.perp - anchor)
					local join_hi = math.min(plan.perp_n - 2,
						sample.perp + sample.width + anchor)
					local v0, v0_prev = at(plan.axis, join_lo, along),
						at(plan.axis, join_lo - 1, along)
					local v1, v1_next = at(plan.axis, join_hi, along),
						at(plan.axis, join_hi + 1, along)
					if type(v0) == "number" and type(v0_prev) == "number"
						and type(v1) == "number" and type(v1_next) == "number" then
						if before_edge then v0, v0_prev = v0 + correction, v0_prev + correction
						else v1, v1_next = v1 + correction, v1_next + correction end
						local slope0, slope1 = v0 - v0_prev, v1_next - v1
						local span = join_hi - join_lo
						local row = {}
						for p = band_lo, band_hi do
							local original = at(plan.axis, p, along)
							if type(original) == "number" then
								local target
								if p > join_lo and p < join_hi then
									local t = (p - join_lo + 0.0) / span
									local s = quintic(t)
									local left = v0 + slope0 * (p - join_lo)
									local right = v1 + slope1 * (p - join_hi)
									target = left + (right - left) * s
								elseif (before_edge and p <= join_lo)
									or (not before_edge and p >= join_hi) then
									target = original + correction
								else
									target = original
								end
								row[p] = target - original
							end
						end
						band[along] = row
					end
				end
			end
			-- The v839 target is derived per row.  Smooth only its correction in the narrow join
			-- band so changes of resampling width (two cells on one row, three on the next) cannot
			-- become a cross-track normal.  Outer terrain keeps the already-smooth profile exactly.
			-- One pass removes width-change cuts while retaining enough row variation
			-- that the repaired normal does not read as a ruler-straight terrain feature.
			for _ = 1, 1 do
				local next_band = {}
				for along = lo_along, hi_along do
					if band[along] then
						local row = {}
						for p = band_lo, band_hi do
							local sum, count = 0, 0
							for q = math.max(lo_along, along - 2), math.min(hi_along, along + 2) do
								if band[q] and type(band[q][p]) == "number" then
									sum, count = sum + band[q][p], count + 1
								end
							end
							if count > 0 then row[p] = sum / count end
						end
						next_band[along] = row
					end
				end
				band = next_band
			end
			for along = lo_along, hi_along do
				local correction = correction_by_along[along]
				local alpha = alpha_by_along[along]
				if type(correction) == "number" and type(alpha) == "number" then
					local p0 = before_edge and 0 or band_lo
					local p1 = before_edge and band_hi or plan.perp_n - 1
					for p = p0, p1 do
						local original = at(plan.axis, p, along)
						if type(original) == "number" then
							local delta = (p >= band_lo and p <= band_hi and band[along]
								and band[along][p]) or correction
							put(plan.axis, p, along,
								blend_value(original, original + delta, alpha))
							modified = modified + 1
						end
					end
					rows = rows + 1
				end
			end
		end

		local function apply_bounded(pair)
			local left, right = pair[1], pair[2]
			if left.mean_perp > right.mean_perp then left, right = right, left end
			local lg, lp = densify(left)
			local rg, rp = densify(right)
			local first_along = math.max(left.first_along, right.first_along)
			local last_along = math.min(left.last_along, right.last_along)
			local taper = math.min(40, math.max(20, math.floor((last_along - first_along + 1) / 6)))
			local lo_along = math.max(0, first_along - taper)
			local hi_along = math.min(left.along_n - 1, last_along + taper)
			local band_lo = math.max(1, math.floor(left.mean_perp - 12))
			local band_hi = math.min(left.perp_n - 2, math.ceil(right.mean_perp + 12))
			local band, alpha_by_along = {}, {}
			for along = lo_along, hi_along do
				local lc = math.max(left.first_along, math.min(left.last_along, along))
				local rc = math.max(right.first_along, math.min(right.last_along, along))
				local l, r = lg[lc], rg[rc]
				local corr_l = lp[lc]
				local corr_r = rp[rc] and -rp[rc] or nil
				local alpha = endpoint_alpha(along, first_along, last_along, taper)
				-- Both flank corrections must move the enclosed strip in the same direction;
				-- otherwise these are unrelated natural walls rather than a bounded defect.
				if l and r and type(corr_l) == "number" and type(corr_r) == "number"
					and corr_l * corr_r > 0 and alpha > 0 then
					local join_l = math.max(1, l.perp - 10)
					local core_l = math.min(right.perp_n - 2, l.perp + l.width + 8)
					local core_r = math.max(1, r.perp - 8)
					local join_r = math.min(right.perp_n - 2, r.perp + r.width + 10)
					if core_l < core_r then
						local function inside_correction(p)
							local u = (p - core_l + 0.0) / (core_r - core_l)
							u = math.max(0, math.min(1, u))
							-- Linear interpolation is the actual tilt requested for a finite strip:
							-- it matches independently measured translations at both flanks.
							return corr_l + (corr_r - corr_l) * u
						end
						local lv0, lv0_prev = at(left.axis, join_l, along),
							at(left.axis, join_l - 1, along)
						local lv1, lv1_next = at(left.axis, core_l, along),
							at(left.axis, core_l + 1, along)
						local rv0, rv0_prev = at(left.axis, core_r, along),
							at(left.axis, core_r - 1, along)
						local rv1, rv1_next = at(left.axis, join_r, along),
							at(left.axis, join_r + 1, along)
						if type(lv0) == "number" and type(lv0_prev) == "number"
							and type(lv1) == "number" and type(lv1_next) == "number"
							and type(rv0) == "number" and type(rv0_prev) == "number"
							and type(rv1) == "number" and type(rv1_next) == "number" then
							lv1 = lv1 + inside_correction(core_l)
							lv1_next = lv1_next + inside_correction(core_l + 1)
							rv0 = rv0 + inside_correction(core_r)
							rv0_prev = rv0_prev + inside_correction(core_r - 1)
							local ls0, ls1 = lv0 - lv0_prev, lv1_next - lv1
							local rs0, rs1 = rv0 - rv0_prev, rv1_next - rv1
							local lspan, rspan = core_l - join_l, join_r - core_r
							local row = {}
							for p = band_lo, band_hi do
								local original = at(left.axis, p, along)
								if type(original) == "number" then
									local target = original
									if p > join_l and p < core_l then
										local t = (p - join_l + 0.0) / lspan
										local s = quintic(t)
										local a = lv0 + ls0 * (p - join_l)
										local b = lv1 + ls1 * (p - core_l)
										target = a + (b - a) * s
									elseif p >= core_l and p <= core_r then
										target = original + inside_correction(p)
									elseif p > core_r and p < join_r then
										local t = (p - core_r + 0.0) / rspan
										local s = quintic(t)
										local a = rv0 + rs0 * (p - core_r)
										local b = rv1 + rs1 * (p - join_r)
										target = a + (b - a) * s
									end
									row[p] = target - original
								end
							end
							band[along] = row
							alpha_by_along[along] = alpha
						end
					end
				end
			end
			-- Coons-like cross joins above are exact per row; a short longitudinal relaxation
			-- makes their derivatives continuous through width changes without flattening the strip.
			for _ = 1, 2 do
				local next_band = {}
				for along = lo_along, hi_along do
					if band[along] then
						local row = {}
						for p = band_lo, band_hi do
							local sum, count = 0, 0
							for q = math.max(lo_along, along - 2), math.min(hi_along, along + 2) do
								if band[q] and type(band[q][p]) == "number" then
									sum, count = sum + band[q][p], count + 1
								end
							end
							if count > 0 then row[p] = sum / count end
						end
						next_band[along] = row
					end
				end
				band = next_band
			end
			for along = lo_along, hi_along do
				local row, alpha = band[along], alpha_by_along[along]
				if row and alpha then
					for p = band_lo, band_hi do
						local original, delta = at(left.axis, p, along), row[p]
						if type(original) == "number" and type(delta) == "number" then
							put(left.axis, p, along,
								blend_value(original, original + delta, alpha))
							modified = modified + 1
						end
					end
					rows = rows + 1
				end
			end
		end

		local function remove_coherent_track_profile(plan)
			-- Even after the step itself has gone, a long source-grid boundary can retain one
			-- ruler-straight normal: the same broad cross-profile is repeated on almost every
			-- row.  Replacing that band outright removes the normal but exposes a flat ribbon.
			-- Instead, decompose each cross-row against distant untouched anchors and remove
			-- only the component coherent along the track.  Each cell keeps its own along-track
			-- high-pass residual, while C2 envelopes make the filter exactly zero at both cross
			-- anchors and both finite endpoints.  The construction is axis-neutral and does not
			-- depend on whether the qualified strip is raised, depressed, bounded, or edge-facing.
			local geometry = densify(plan)
			local first_geometry = geometry[plan.first_along]
			local last_geometry = geometry[plan.last_along]
			if not first_geometry or not last_geometry then return end
			local half_span = math.max(32, math.min(48, math.floor(plan.perp_n / 170)))
			local edge_taper = math.min(14, math.max(8, math.floor(half_span / 3)))
			local along_radius = math.min(12, math.max(6,
				math.floor((plan.last_along - plan.first_along + 1) / 16)))
			local endpoint_taper = math.min(40, math.max(20,
				math.floor((plan.last_along - plan.first_along + 1) / 6)))
			local lo_along = math.max(0, plan.first_along - endpoint_taper)
			local hi_along = math.min(plan.along_n - 1, plan.last_along + endpoint_taper)
			local residual, original, centers = {}, {}, {}
			for along = lo_along, hi_along do
				local sample = geometry[along]
					or (along < plan.first_along and first_geometry or last_geometry)
				local center = math.floor(sample.perp + sample.width * 0.5 + 0.5)
				center = math.max(half_span, math.min(plan.perp_n - half_span - 1, center))
				centers[along] = center
				local left = at(plan.axis, center - half_span, along)
				local right = at(plan.axis, center + half_span, along)
				if type(left) == "number" and type(right) == "number" then
					local residual_row, original_row = {}, {}
					for offset = -half_span, half_span do
						local value = at(plan.axis, center + offset, along)
						if type(value) == "number" then
							local t = (offset + half_span + 0.0) / (2 * half_span)
							original_row[offset] = value
							residual_row[offset] = value - (left + (right - left) * t)
						end
					end
					residual[along], original[along] = residual_row, original_row
				end
			end
			for along = lo_along, hi_along do
				local residual_row, original_row, center = residual[along], original[along], centers[along]
				local end_alpha = endpoint_alpha(along, plan.first_along,
					plan.last_along, endpoint_taper)
				if residual_row and original_row and center and end_alpha > 0 then
					local row_changed = false
					for offset = -half_span + 1, half_span - 1 do
						local sum, count = 0, 0
						for q = math.max(lo_along, along - along_radius),
								math.min(hi_along, along + along_radius) do
							local qrow = residual[q]
							if qrow and type(qrow[offset]) == "number" then
								sum, count = sum + qrow[offset], count + 1
							end
						end
						if count > 0 and type(original_row[offset]) == "number" then
							local distance = math.min(offset + half_span, half_span - offset)
							local cross_alpha = quintic(math.min(1,
								(distance + 0.0) / edge_taper))
							local value = blend_value(original_row[offset],
								original_row[offset] - sum / count, end_alpha * cross_alpha)
							if value ~= original_row[offset] then
								put(plan.axis, center + offset, along, value)
								modified = modified + 1
								coherent_profile_modified = coherent_profile_modified + 1
								row_changed = true
							end
						end
					end
					if row_changed then coherent_profile_rows = coherent_profile_rows + 1 end
				end
			end
		end

		for _, pair in ipairs(pairs) do apply_bounded(pair) end
		for i, plan in ipairs(plans) do if not paired[i] then apply_edge(plan) end end
		for _, plan in ipairs(plans) do remove_coherent_track_profile(plan) end
	end)
	if type(resume) == "function" then pcall(resume, "SBMResampledBorderInterpolation") end
	if not ok_finish then
		return false, { reason = tostring(finish_err), tracks = tracks, rows = rows,
			modified = modified }
	end
	return modified > 0, {
		reason = modified > 0
			and "source-qualified strips repaired with C2 interpolation and coherent-profile removal"
			or "no source-qualified destination wall refined",
		threshold = threshold, outer_guard = outer_guard,
		tracks = tracks, edge_strips = edge_strips, bounded_strips = bounded_strips,
		rows = rows, modified = modified,
		coherent_profile_rows = coherent_profile_rows,
		coherent_profile_modified = coherent_profile_modified,
		min_offset = min_offset, max_offset = max_offset,
	}
end

-- TEST-ONLY SEAM (config StretchHeightGridDumpPath, empty = off). Writes a destination height
-- grid to "<prefix>-<environment>-<stage>.raw" so the offline gate can score the PURE transform
-- between its own input ("pre", straight out of GridResample) and its output ("post", right after
-- the Z transform) -- the engine's resample arithmetic is not reproducible offline, and by the end
-- of generation later terrain edits (flatten pads, the landing pit) have overwritten transformed
-- ground. Diagnostic only: a failure is logged and generation continues unaffected.
local function ZDumpHeightGrid(map, stage, grid)
	local prefix = cfg_str("STRETCH_HEIGHT_GRID_DUMP_PATH", nil)
	if not prefix or not grid then return end
	local save = Global("GridSaveRaw")
	if type(save) ~= "function" then return end
	local environment = (type(map.mapdata) == "table"
		and map.mapdata.Environment == "Underground") and "underground" or "surface"
	local path = prefix .. "-" .. environment .. "-" .. stage .. ".raw"
	local ok, err = pcall(save, path, grid)
	LoadingStep("terrain height grid test dump", {
		stage = stage,
		environment = environment,
		path = path,
		error = ok and tostring(err or "") or tostring(err),
	}, map)
end

-- source_map is optional. When supplied, height/type are read directly from that native-sized
-- map and written at full size to map, avoiding the old source -> destination-corner -> full-size
-- round trip. terrain_only is used by temporary-source migration; the normal surface tail still
-- owns MapGrid resampling and the authoritative gameplay-grid invalidation.
local function StretchSourceToFull(map, source_map, terrain_only)
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
	local direct_source = source_map and source_map ~= map
	local terrain_source = direct_source and source_map or map
	-- Relaunched stores terrain clutter in a native grid with a public writer but no reliable reader
	-- during generation on a temporary/non-current map slot. The generator wrapper captures vanilla's
	-- final SetClutterGrid input (or ClearClutterGrid value) while it is alive. Prefer that exact
	-- capture, retaining editor.GetGridRef only as a compatibility fallback for engine builds that do
	-- expose the native grid. Grass-like ground scatter is part of this clutter/object layer rather
	-- than a separate "grass_density" grid.
	local function stretch_clutter()
		if map.SuperBigMapClutterGridStretched == true then
			return true, false
		end
		local editor_api = Global("editor")
		if type(terrain_api.SetClutterGrid) ~= "function" then
			return false, false
		end
		local function grid_size(grid)
			if not grid or type(grid.size) ~= "function" then return nil, nil end
			local ok, width, height = pcall(grid.size, grid)
			if not ok or type(width) ~= "number" or type(height) ~= "number" then
				return nil, nil
			end
			return width, height
		end
		local function clutter_ref(owner)
			if type(editor_api) ~= "table" or type(editor_api.GetGridRef) ~= "function" then return nil end
			for _, alias in ipairs({ "clutter", "clutter_density" }) do
				local ref = SafeCall(editor_api.GetGridRef, owner, alias)
				if ref then return ref, alias end
			end
		end

		local token = LoadingBegin("terrain clutter grid stretch", map, {
			direct_source = tostring(direct_source == true),
		})
		local captured_grid = terrain_source.SuperBigMapCapturedClutterGrid
		local captured_fill = terrain_source.SuperBigMapCapturedClutterFill
		local source_ref, source_alias
		if captured_grid then
			source_ref, source_alias = captured_grid, "captured_SetClutterGrid"
		else
			source_ref, source_alias = clutter_ref(terrain_source)
		end
		local destination_ref, destination_alias = clutter_ref(map)
		local source_w, source_h = grid_size(source_ref)
		local destination_w, destination_h = grid_size(destination_ref)
		if captured_fill ~= nil and not source_ref then
			local clear_ok, clear_result = pcall(terrain_api.ClearClutterGrid, map, captured_fill)
			local success = clear_ok and clear_result == true
			if success then map.SuperBigMapClutterGridStretched = true end
			terrain_source.SuperBigMapCapturedClutterFill = nil
			LoadingEnd(token, {
				source_alias = "captured_ClearClutterGrid",
				destination_alias = "native_clear",
				source_cells = "uniform",
				destination_cells = "uniform",
				extraction_path = "uniform_native_clear",
				error = success and "" or tostring(clear_result),
			}, success)
			return success, success
		end
		if source_w and source_h and (not destination_w or not destination_h) then
			destination_w = math.max(1, math.floor((source_w * full_tw + 0.0) / sw_tiles + 0.5))
			destination_h = math.max(1, math.floor((source_h * full_th + 0.0) / sh_tiles + 0.5))
			destination_alias = "scaled_source_dimensions"
		end
		if not source_w or not source_h or not destination_w or not destination_h then
			LoadingEnd(token, {
				error = "captured/native clutter source unavailable",
				source_alias = source_alias or "none",
				destination_alias = destination_alias or "none",
			}, false)
			if captured_grid then
				terrain_source.SuperBigMapCapturedClutterGrid = nil
				free_grid(captured_grid)
			end
			return false, false
		end

		local source_is_captured = captured_grid ~= nil
		local source_cells_w = (direct_source or source_is_captured) and source_w
			or math.max(1, math.min(source_w, math.floor(destination_w * frac_w + 0.5)))
		local source_cells_h = (direct_source or source_is_captured) and source_h
			or math.max(1, math.min(source_h, math.floor(destination_h * frac_h + 0.5)))
		local native_sub, source_compute, full_compute, stretched
		local extraction_path = source_is_captured and "captured_generator_grid"
			or direct_source and "direct_source_ref" or "unknown"
		local ok_all, result = pcall(function()
			if direct_source or source_is_captured then
				source_compute = GridToCompute(source_ref)
				if not source_compute then error("native source clutter conversion failed") end
			elseif type(source_ref.new_instance) == "function" then
				local corner_ok = pcall(function()
					native_sub = source_ref:new_instance(source_cells_w, source_cells_h)
					if not native_sub or type(native_sub.copyrect) ~= "function" then
						error("native clutter corner allocation failed")
					end
					native_sub:copyrect(source_ref,
						box_fn(0, 0, source_cells_w, source_cells_h), point_fn(0, 0))
					source_compute = GridToCompute(native_sub)
					if not source_compute then error("native clutter corner conversion failed") end
				end)
				if corner_ok then
					extraction_path = "native_corner_then_compute"
				else
					if source_compute and source_compute ~= native_sub then free_grid(source_compute) end
					source_compute = nil
					free_grid(native_sub)
					native_sub = nil
				end
			end
			if not source_compute then
				full_compute = GridToCompute(source_ref)
				if not full_compute then error("full clutter grid conversion failed") end
				local format, bits = IsComputeGrid(full_compute)
				source_compute = NewComputeGrid(source_cells_w, source_cells_h, format, bits)
				if not source_compute then error("compute clutter corner allocation failed") end
				source_compute:copyrect(full_compute,
					box_fn(0, 0, source_cells_w, source_cells_h), point_fn(0, 0))
				extraction_path = "full_compute_then_corner"
			end

			stretched = GridResample(source_compute, destination_w, destination_h, true)
			if not stretched then error("clutter resample failed") end
			local set_ok, set_result = pcall(terrain_api.SetClutterGrid, map, stretched)
			if not set_ok or set_result ~= true then
				error("terrain.SetClutterGrid failed: " .. tostring(set_result))
			end
			local msg = Global("Msg")
			if type(msg) == "function" then pcall(msg, "OnMapGridChanged", map, "clutter", false) end
			return true
		end)
		if native_sub then free_grid(native_sub) end
		if stretched and stretched ~= source_compute then free_grid(stretched) end
		if source_compute and source_compute ~= source_ref and source_compute ~= full_compute
			and source_compute ~= native_sub then
			free_grid(source_compute)
		end
		if full_compute and full_compute ~= source_ref then free_grid(full_compute) end
		if captured_grid then
			if terrain_source.SuperBigMapCapturedClutterGrid == captured_grid then
				terrain_source.SuperBigMapCapturedClutterGrid = nil
			end
			free_grid(captured_grid)
		end
		local success = ok_all and result == true
		if success then map.SuperBigMapClutterGridStretched = true end
		LoadingEnd(token, {
			source_alias = source_alias,
			destination_alias = destination_alias,
			source_cells = tostring(source_cells_w) .. "x" .. tostring(source_cells_h),
			destination_cells = tostring(destination_w) .. "x" .. tostring(destination_h),
			extraction_path = extraction_path,
			error = ok_all and "" or tostring(result),
		}, success)
		return success, success
	end
	local function stretch_one(label, get_fn, set_fn, invalidate_fn, interpolate, scale_values)
		local grid_token = LoadingBegin("terrain grid stretch: " .. tostring(label), map, {
			interpolate = tostring(interpolate == true),
			scale_values = tostring(scale_values == true),
		})
		if type(get_fn) ~= "function" or type(set_fn) ~= "function" then
			LoadingEnd(grid_token, { error = "terrain getter/setter unavailable" }, false)
			return false
		end
		local ok_g, raw = pcall(get_fn, terrain_source)
		if not ok_g or not raw then
			LoadingEnd(grid_token, { error = "terrain getter failed" }, false)
			return false
		end
		local measured_fw, measured_fh
		local extraction_path = "unknown"
		local internal_step_repair
		local source_step_tracks
		local function merge_step_report(report)
			if not report then return end
			if internal_step_repair then
				internal_step_repair = {
					reason = tostring(internal_step_repair.reason) .. "; " .. tostring(report.reason),
					rows = (internal_step_repair.rows or 0) + (report.rows or 0),
					modified = (internal_step_repair.modified or 0) + (report.modified or 0),
				}
			else
				internal_step_repair = report
			end
		end
		local ok_all, res = pcall(function()
			local full_c
			local ok_size, fw, fh = pcall(function() return raw:size() end)
			if not ok_size or type(fw) ~= "number" or type(fh) ~= "number" then
				full_c = GridToCompute(raw)
				fw, fh = full_c:size()
				extraction_path = "full_grid_compute_fallback"
			end
			local source_fw, source_fh = fw, fh
			if direct_source then
				local destination_raw = get_fn(map)
				if not destination_raw or type(destination_raw.size) ~= "function" then
					error("direct destination terrain grid unavailable")
				end
				local ok_destination_size, destination_fw, destination_fh =
					pcall(destination_raw.size, destination_raw)
				if not ok_destination_size or type(destination_fw) ~= "number"
					or type(destination_fh) ~= "number" then
					error("direct destination terrain grid size unavailable")
				end
				fw, fh = destination_fw, destination_fh
			end
			measured_fw, measured_fh = fw, fh
			local scw = direct_source and source_fw
				or math.max(1, math.min(fw, math.floor(fw * frac_w + 0.5)))
			local sch = direct_source and source_fh
				or math.max(1, math.min(fh, math.floor(fh * frac_h + 0.5)))
			local src_sub, native_sub
			if direct_source then
				src_sub = full_c or GridToCompute(raw)
				if not src_sub then error("direct source GridToCompute failed") end
				extraction_path = "direct_source_compute"
			elseif not full_c and type(raw.new_instance) == "function" then
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
			local environment = type(map.mapdata) == "table" and map.mapdata.Environment or nil
			-- Detect coherent perimeter defects while the grid is still at vanilla resolution. This
			-- is substantially cheaper than discovering them across the 8192-square destination. The
			-- source remains byte-for-byte untouched so the destination pass can apply v839's complete
			-- translate-plus-interpolate border algorithm to the real resampled wall.
			-- Diagnostic source dumps are test-only because the configured prefix is empty in release.
			if scale_values then ZDumpHeightGrid(map, "source-pre", src_sub) end
			if scale_values and environment ~= "Underground"
				and cfg_bool("STRETCH_REPAIR_INTERNAL_HEIGHT_STEP", true) then
				local detected, report, tracks = RepairInternalHeightStep(src_sub, true)
				internal_step_repair = report
				if detected then
					source_step_tracks = tracks
				end
				TerrainCreaseAudit(detected and "SOURCE_DETECTED" or "SOURCE_SKIPPED", report, map)
			end
			if scale_values then ZDumpHeightGrid(map, "source-post", src_sub) end
			local fmt, bits = IsComputeGrid(src_sub)
			local stretched = GridResample(src_sub, fw, fh, interpolate == true)
			NotifyDeterminismCaptureForTest("pre_z_transform", map, {
				grid = stretched,
				grid_kind = scale_values and "surface_height" or "surface_terrain",
			})
			if scale_values then ZDumpHeightGrid(map, "pre", stretched) end
			-- Repair only the source tracks already proven defective, now at destination resolution,
			-- with the edge-reaching or bounded-strip interpolation selected from those tracks. No
			-- second outer-ring scan is needed and no unrelated terrain can enter this pass.
			if scale_values and environment ~= "Underground" and source_step_tracks
				and cfg_bool("STRETCH_REPAIR_INTERNAL_HEIGHT_STEP", true) then
				local repaired, report = FinishResampledHeightStepsWithBorderInterpolation(stretched,
					scw, sch, source_step_tracks)
				TerrainCreaseAudit(repaired and "DESTINATION_FINISHED"
					or "DESTINATION_FINISH_SKIPPED", report, map)
				merge_step_report(report)
			end
			if scale_values then ZDumpHeightGrid(map, "finish-post", stretched) end
			-- Retain v839's proven full-resolution destination-edge pass. The source-side pass above
			-- only handles deeper, grid-aligned defects; this one keeps the immediate resampled skirt
			-- seamless exactly as before.
			if scale_values and environment ~= "Underground"
				and cfg_bool("STRETCH_REPAIR_INTERNAL_HEIGHT_STEP", true) then
				local repaired, report = RepairInternalHeightStep(stretched, false)
				TerrainCreaseAudit(repaired and "DESTINATION_REPAIRED"
					or "DESTINATION_SKIPPED", report, map)
				merge_step_report(report)
			end
			-- FULL 3D STRETCH (config STRETCH_SCALE_HEIGHTS): scale the HEIGHT VALUES by the same
			-- full/source factor as X/Y, making the stretch a true similarity transform -- vanilla
			-- slope steepness and object seating geometry are preserved (XY-only stretching made
			-- slopes 25% shallower while object meshes scaled x1.333 in all axes; big formations
			-- sculpted into relief ended up floating). Height grid only -- type/colour/biome are
			-- CATEGORICAL values and must never be scaled.
			--
			-- HEIGHT BUDGET (version 738 mode): start with the same Z scale as X/Y. Shift the
			-- source minimum to a one-metre floor, then, only when that full-scale source span
			-- would exceed the ceiling, normalize the entire map with one affine transform:
			--
			--   h' = floor((h - min) * (cap - floor) / (max - min)) + floor
			--
			-- This makes the highest terrain point land exactly on the ceiling and applies the
			-- same scale to every height, rather than compressing only overflowing mountains.
			-- Both endpoints come from the source grid, matching version 738 and keeping the
			-- height transform consistent with the source-domain object and range consumers.
			-- Underground terrain keeps the full similarity transform because buried wonders and
			-- their sculpted openings require its Z ratio to remain identical to X/Y.
			if scale_values and cfg_bool("STRETCH_SCALE_HEIGHTS", true) then
				local grid_muldivadd = Global("GridMulDivAdd")
				local grid_minmax = Global("GridMinMax")
				if type(grid_muldivadd) == "function" then
					-- Exact version 738 behavior: measure the complete source grid before resampling.
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
					local environment = type(map.mapdata) == "table"
						and map.mapdata.Environment or nil
					local uniform_underground = environment == "Underground"
					local zmul, zdiv, zadd = full_tw, sw_tiles, 0
					local normalized = false
					local projected_max
					if type(min0) == "number" and type(max0) == "number" and max0 > min0 and cap then
						local shift = cfg_bool("STRETCH_SHIFT_HEIGHTS_DOWN", true)
						local span_at_full_scale = (max0 - min0) * zmul / zdiv + Z_FLOOR_WU
						projected_max = math.floor(span_at_full_scale)
						if not uniform_underground and shift
							and cfg_bool("STRETCH_ADAPTIVE_Z_SCALE", true)
							and span_at_full_scale > cap then
							zmul, zdiv = cap - Z_FLOOR_WU, max0 - min0
							normalized = true
						end
						if uniform_underground and span_at_full_scale > cap then
							error("uniform underground height stretch exceeds the terrain height budget")
						end
						if shift then
							zadd = Z_FLOOR_WU - math.floor((min0 * zmul + 0.0) / zdiv)
						end
					end
					pcall(grid_muldivadd, stretched, zmul, zdiv, zadd)
					-- Stamp the applied Z transform for consumers (height ranges, relief dz).
					map.SuperBigMapZScaleMul = zmul
					map.SuperBigMapZScaleDiv = zdiv
					map.SuperBigMapZScaleAdd = zadd
					map.SuperBigMapZScaleUniform = uniform_underground == true
					map.SuperBigMapZCompressionZones = nil
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
					map.SuperBigMapZMeasuredMaxHeight = normalized and max1 or nil
					LoadingStep("terrain height similarity transform", {
						environment = tostring(environment),
						xy_scale_mul = full_tw,
						xy_scale_div = sw_tiles,
						z_scale_mul = zmul,
						z_scale_div = zdiv,
						z_scale_add = zadd,
						uniform_required = tostring(uniform_underground),
						uniform_applied = tostring(zmul * sw_tiles == zdiv * full_tw),
						whole_map_normalized = tostring(normalized),
						source_min = tostring(min0),
						terrain_max = tostring(max0),
						projected_max = tostring(projected_max),
						final_min = tostring(min1),
						final_max = tostring(max1),
					}, map)
				end
			end
			NotifyDeterminismCaptureForTest("post_z_transform", map, {
				grid = stretched,
				grid_kind = scale_values and "surface_height" or "surface_terrain",
			})
			if scale_values then ZDumpHeightGrid(map, "post", stretched) end
			local ok_set = pcall(set_fn, map, stretched)
			if type(invalidate_fn) == "function" then pcall(invalidate_fn, map) end
			free_grid(src_sub)
			if stretched ~= src_sub then free_grid(stretched) end
			if full_c ~= raw and full_c ~= src_sub then free_grid(full_c) end
			return ok_set == true
		end)
		local success = ok_all and res == true
		LoadingEnd(grid_token, {
			full_cells = tostring(measured_fw) .. "x" .. tostring(measured_fh),
			extraction_path = extraction_path,
			internal_step_repair = internal_step_repair and internal_step_repair.reason or "not requested",
			internal_step_rows = internal_step_repair and internal_step_repair.rows or 0,
			internal_step_modified = internal_step_repair and internal_step_repair.modified or 0,
			error = ok_all and "" or tostring(res),
		}, success)
		return success
	end

	local done = 0
	local terrain_already_stretched = not direct_source
		and map.SuperBigMapDirectSourceTerrainStretched == true
	if terrain_already_stretched then
		done = 2
		LoadingStep("terrain grids already stretched directly from temporary source", {
			height = true, terrain_type = true,
		}, map)
	elseif stretch_one("height", terrain_api.GetHeightGrid, terrain_api.SetHeightGrid,
		terrain_api.InvalidateHeight, true, true) then
		done = done + 1
		-- Height VALUES just transformed (h*zmul/zdiv + zadd, stamped by stretch_one) -> the
		-- declared buildable/playable height ranges must follow the SAME affine transform
		-- before any buildable rebuild.
		ScaleHeightRanges(map,
			map.SuperBigMapZScaleMul or full_tw,
			map.SuperBigMapZScaleDiv or sw_tiles,
			map.SuperBigMapZScaleAdd or 0,
			map.SuperBigMapZMeasuredMaxHeight)
	end
	if not terrain_already_stretched and stretch_one("type", terrain_api.GetTypeGrid,
		terrain_api.SetTypeGrid, terrain_api.InvalidateType, false) then
		done = done + 1
	end
	local clutter_ok, clutter_changed = stretch_clutter()
	if terrain_only == true then
		LoadingStep("direct source terrain grid suite complete", {
			completed_grids = done,
			clutter = tostring(clutter_ok == true),
			source_tiles = tostring(sw_tiles) .. "x" .. tostring(sh_tiles),
			destination_tiles = tostring(full_tw) .. "x" .. tostring(full_th),
		}, map)
		return done > 0, done
	end
	if clutter_ok ~= true then
		map.SuperBigMapClutterGridStretchUnavailable = true
		LoadingStep("terrain clutter grid unavailable; continuing diagnostic generation", {
			source_tiles = tostring(sw_tiles) .. "x" .. tostring(sh_tiles),
			destination_tiles = tostring(full_tw) .. "x" .. tostring(full_th),
			direct_source = tostring(direct_source == true),
		}, map)
	end
	if clutter_changed then done = done + 1 end
	-- Colour and biome are compute-backed editor MapGrids. Clutter was handled through its native
	-- terrain grid above; Relaunched has no standalone grass-density grid.
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
	local mapdata = map and map.mapdata
	local defer_intermediate_rebuild = cfg_bool("OPTIMIZE_STRETCH_DEFERRED_REBUILDS", true)
		and cfg_bool("EXPANSION_STEP_11_REBUILD_GAMEPLAY_GRIDS", true)
		and type(mapdata) == "table" and mapdata.Environment == "Underground"
		and map.SuperBigMapUndergroundStretchPending == true
		and map.SuperBigMapStretchPipelinePending == true
	local invalidate_token = LoadingBegin("invalidate expanded terrain", map)
	local invalidate_ok = ReinvalidateExpandedTerrain(map, defer_intermediate_rebuild)
	map.SuperBigMapDeferredIntermediateTerrainRebuild = defer_intermediate_rebuild or nil
	LoadingEnd(invalidate_token, {
		deferred_gameplay_rebuild = tostring(defer_intermediate_rebuild == true),
	}, invalidate_ok == true)
	if invalidate_ok ~= true then
		error("expanded terrain revalidation failed")
	end
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
local decor_eligible_objects_by_map = setmetatable({}, { __mode = "k" })
local decor_relief_stats_by_map = setmetatable({}, { __mode = "k" })
local decor_position_audit_by_map = setmetatable({}, { __mode = "k" })
local cave_in_transform_capture_by_map = setmetatable({}, { __mode = "k" })
local cave_in_scaled_shape_cache = setmetatable({}, { __mode = "k" })
local underground_wonder_scaled_shape_cache = setmetatable({}, { __mode = "k" })

local CAVE_IN_SHAPE_PATCH_VERSION = 2
local UNDERGROUND_WONDER_SHAPE_PATCH_VERSION = 1
local BOTTOMLESS_PIT_SPAWN_PATCH_VERSION = 1

local function RoundSigned(value)
	if value >= 0 then return math.floor(value + 0.5) end
	return math.ceil(value - 0.5)
end

-- Rasterize a vanilla rubble wall's axial-hex footprint through the same world-space transform
-- used by the terrain. Mapping destination hex centers back into the source shape fills the
-- additional cells introduced by the 4/3 expansion instead of merely spreading the original
-- cells apart.
local function ScaleCaveInHexShape(source_shape, scale_x, scale_y)
	if type(source_shape) ~= "table" or #source_shape == 0
		or type(scale_x) ~= "number" or type(scale_y) ~= "number"
		or scale_x <= 1 or scale_y <= 1 then
		return source_shape
	end
	local point_fn = Global("point")
	local world_to_hex = Global("WorldToHex")
	local hex_to_world = Global("HexToWorld")
	if type(point_fn) ~= "function" or type(world_to_hex) ~= "function"
		or type(hex_to_world) ~= "function" then return source_shape end

	local source_set = {}
	local min_q, max_q, min_r, max_r
	for _, shape_point in ipairs(source_shape) do
		local q, r = PointXY(shape_point)
		if type(q) == "number" and type(r) == "number" then
			source_set[tostring(q) .. ":" .. tostring(r)] = true
			local ok_world, wx, wy = pcall(hex_to_world, q, r)
			if ok_world and type(wx) == "number" and type(wy) == "number" then
				local target_point = point_fn(RoundSigned(wx * scale_x), RoundSigned(wy * scale_y))
				local ok_hex, tq, tr = pcall(world_to_hex, target_point)
				if ok_hex and type(tq) == "number" and type(tr) == "number" then
					min_q = min_q and math.min(min_q, tq) or tq
					max_q = max_q and math.max(max_q, tq) or tq
					min_r = min_r and math.min(min_r, tr) or tr
					max_r = max_r and math.max(max_r, tr) or tr
				end
			end
		end
	end
	if not min_q then return source_shape end

	-- Three cells of padding covers the largest supported terrain ratio while keeping this tiny:
	-- Both supported rubble entities have compact local footprints, and this runs only for generated
	-- underground walls.
	min_q, max_q, min_r, max_r = min_q - 3, max_q + 3, min_r - 3, max_r + 3
	local scaled = {}
	for target_q = min_q, max_q do
		for target_r = min_r, max_r do
			local ok_world, target_x, target_y = pcall(hex_to_world, target_q, target_r)
			if ok_world and type(target_x) == "number" and type(target_y) == "number" then
				local source_point = point_fn(
					RoundSigned(target_x / scale_x), RoundSigned(target_y / scale_y))
				local ok_hex, source_q, source_r = pcall(world_to_hex, source_point)
				if ok_hex and source_set[tostring(source_q) .. ":" .. tostring(source_r)] then
					scaled[#scaled + 1] = point_fn(target_q, target_r)
				end
			end
		end
	end
	return #scaled > 0 and scaled or source_shape
end

local function CaveInShapeScale(obj)
	local x_mul = tonumber(obj and obj.SuperBigMapCaveInShapeScaleXMul)
	local x_div = tonumber(obj and obj.SuperBigMapCaveInShapeScaleXDiv)
	local y_mul = tonumber(obj and obj.SuperBigMapCaveInShapeScaleYMul)
	local y_div = tonumber(obj and obj.SuperBigMapCaveInShapeScaleYDiv)
	if not x_mul or not x_div or x_div <= 0 or not y_mul or not y_div or y_div <= 0 then
		return nil
	end
	return (x_mul + 0.0) / x_div, (y_mul + 0.0) / y_div
end

local function CaveInShapePointCount(obj)
	if not obj or type(obj.GetShapePoints) ~= "function" then return nil end
	local shape = SafeCall(obj.GetShapePoints, obj)
	return type(shape) == "table" and #shape or nil
end

-- Both rubble-wall classes inherit GridObject:GetShapePoints, whose entity outline is unaffected
-- by CObject:SetScale. Keep vanilla behavior for every unstamped object; only source blockers that
-- this mod stretches carry the ratio fields consumed by these transparent class wrappers. The
-- current entity is part of the cache key because TunnelBlockerRubble changes entity as clearing
-- progresses and each clearing phase must continue to use its own expanded vanilla outline.
local CAVE_IN_SHAPE_PATCHES = {
	{
		class = "CaveInRubble",
		original_key = "original_cave_in_shape_points",
		wrapper_key = "cave_in_shape_points_wrapper",
	},
	{
		class = "TunnelBlockerRubble",
		original_key = "original_tunnel_blocker_shape_points",
		wrapper_key = "tunnel_blocker_shape_points_wrapper",
	},
}

local function PatchCaveInShapeClass(State, spec, force_reinstall)
	local cls = Engine.ClassTable and Engine.ClassTable(spec.class)
	if type(cls) ~= "table" then return false end
	local current = cls.GetShapePoints
	local previous_wrapper = State[spec.wrapper_key]
	local previous_original = State[spec.original_key]
	if current == previous_wrapper and not force_reinstall then return true end
	if current == previous_wrapper and type(previous_original) == "function" then
		current = previous_original
		cls.GetShapePoints = current
	end
	if type(current) ~= "function" then
		local grid_object = Engine.ClassTable and Engine.ClassTable("GridObject")
		current = type(grid_object) == "table" and grid_object.GetShapePoints or nil
	end
	if type(current) ~= "function" then return false end
	local original = current
	local wrapper = function(obj, ...)
		local source_shape = original(obj, ...)
		local scale_x, scale_y = CaveInShapeScale(obj)
		if not scale_x or scale_x <= 1 or not scale_y or scale_y <= 1 then
			return source_shape
		end
		local entity = type(obj.GetEntity) == "function" and SafeCall(obj.GetEntity, obj)
			or obj.entity
		local cached = cave_in_scaled_shape_cache[obj]
		if type(cached) == "table" and cached.source_shape == source_shape
			and cached.entity == entity and cached.scale_x == scale_x
			and cached.scale_y == scale_y then
			return cached.shape
		end
		local shape = ScaleCaveInHexShape(source_shape, scale_x, scale_y)
		cave_in_scaled_shape_cache[obj] = {
			source_shape = source_shape,
			entity = entity,
			scale_x = scale_x,
			scale_y = scale_y,
			shape = shape,
		}
		return shape
	end
	State[spec.original_key] = original
	State[spec.wrapper_key] = wrapper
	cls.GetShapePoints = wrapper
	return true
end

local function PatchCaveInShapePoints()
	local State = SuperBigMap.State or {}
	SuperBigMap.State = State
	local force_reinstall = State.cave_in_shape_patch_version ~= CAVE_IN_SHAPE_PATCH_VERSION
	local all_patched = true
	for _, spec in ipairs(CAVE_IN_SHAPE_PATCHES) do
		if not PatchCaveInShapeClass(State, spec, force_reinstall) then all_patched = false end
	end
	State.cave_in_shape_patch_version = all_patched and CAVE_IN_SHAPE_PATCH_VERSION or nil
	return all_patched
end

local function RestoreCaveInShapePointsPatch()
	local State = SuperBigMap.State or {}
	for _, spec in ipairs(CAVE_IN_SHAPE_PATCHES) do
		local cls = Engine.ClassTable and Engine.ClassTable(spec.class)
		local wrapper = State[spec.wrapper_key]
		local original = State[spec.original_key]
		if type(cls) == "table" and cls.GetShapePoints == wrapper
			and type(original) == "function" then
			cls.GetShapePoints = original
		end
		State[spec.original_key] = nil
		State[spec.wrapper_key] = nil
	end
	State.cave_in_shape_patch_version = nil
	cave_in_scaled_shape_cache = setmetatable({}, { __mode = "k" })
end

local function UndergroundWonderShapeScale(obj)
	local x_mul = tonumber(obj and obj.SuperBigMapWonderShapeScaleXMul)
	local x_div = tonumber(obj and obj.SuperBigMapWonderShapeScaleXDiv)
	local y_mul = tonumber(obj and obj.SuperBigMapWonderShapeScaleYMul)
	local y_div = tonumber(obj and obj.SuperBigMapWonderShapeScaleYDiv)
	if not x_mul or not x_div or x_div <= 0 or not y_mul or not y_div or y_div <= 0 then
		return nil
	end
	return (x_mul + 0.0) / x_div, (y_mul + 0.0) / y_div
end

local function PatchBottomlessPitSpawnStartPos(State)
	local cls = Engine.ClassTable and Engine.ClassTable("BottomlessPit")
	if type(cls) ~= "table" then return false end
	local force_reinstall = State.bottomless_pit_spawn_patch_version
		~= BOTTOMLESS_PIT_SPAWN_PATCH_VERSION
	local previous_wrapper = State.bottomless_pit_spawn_start_wrapper
	local previous_original = State.original_bottomless_pit_spawn_start
	local current = cls.GetSpawnStartPos
	if current == previous_wrapper and not force_reinstall then return true end
	if current == previous_wrapper and type(previous_original) == "function" then
		current = previous_original
		cls.GetSpawnStartPos = current
	end
	if type(current) ~= "function" then return false end
	local original = current
	local wrapper = function(obj, ...)
		local scale_x, scale_y = UndergroundWonderShapeScale(obj)
		if not scale_x or scale_x <= 1 or not scale_y or scale_y <= 1 then
			return original(obj, ...)
		end
		local get_peripheral = Global("GetPeripheralHexShape")
		local for_each_hex = Global("HexShapeForEach")
		local hex_to_world = Global("HexToWorld")
		local terrain_api = Global("terrain")
		local is_obstructed = Global("IsDepositObstructed")
		local point_fn = Global("point")
		local const_tbl = Global("const")
		local table_lib = Global("table") or table
		local guim = tonumber(Global("guim"))
		if type(get_peripheral) ~= "function" or type(for_each_hex) ~= "function"
			or type(hex_to_world) ~= "function" or type(terrain_api) ~= "table"
			or type(terrain_api.GetHeight) ~= "function"
			or type(terrain_api.IsPassable) ~= "function"
			or type(is_obstructed) ~= "function" or type(point_fn) ~= "function"
			or type(const_tbl) ~= "table"
			or type(table_lib.shuffle) ~= "function" or not guim then
			return original(obj, ...)
		end
		local outline = type(obj.GetShapePoints) == "function" and obj:GetShapePoints() or nil
		local peripheral = type(outline) == "table" and get_peripheral(outline) or nil
		if not peripheral then return obj:GetPos() end
		table_lib.shuffle(peripheral)
		local map = obj:GetMap()
		local object_hex_grid = map and map.object_hex_grid
		if not map or not object_hex_grid then return original(obj, ...) end
		local max_z = terrain_api.GetHeight(map, obj:GetPos()) + 5 * guim
		local result_pos
		for_each_hex(peripheral, obj, function(q, r)
			local x, y = hex_to_world(q, r)
			if terrain_api.IsPassable(map, x, y)
				and not is_obstructed(object_hex_grid, x, y,
					const_tbl.DepositObstructMaxRadius)
				and terrain_api.GetHeight(map, x, y) < max_z then
				result_pos = point_fn(x, y)
				return true
			end
		end)
		return result_pos or obj:GetPos()
	end
	State.original_bottomless_pit_spawn_start = original
	State.bottomless_pit_spawn_start_wrapper = wrapper
	State.bottomless_pit_spawn_patch_version = BOTTOMLESS_PIT_SPAWN_PATCH_VERSION
	cls.GetSpawnStartPos = wrapper
	return true
end

-- Deferred buried wonders are Buildings, so the decoration pass deliberately skips them. Their
-- marker centers are transformed separately before construction; this wrapper expands the live
-- wonder's vanilla entity outline through the same world-space ratio. Untagged wonders (including
-- every vanilla-map instance) continue to call the exact original method.
local UNDERGROUND_WONDER_SHAPE_PATCHES = {
	{ class = "AncientArtifact", original_key = "original_ancient_artifact_shape_points",
		wrapper_key = "ancient_artifact_shape_points_wrapper" },
	{ class = "CaveOfWonders", original_key = "original_cave_of_wonders_shape_points",
		wrapper_key = "cave_of_wonders_shape_points_wrapper" },
	{ class = "BottomlessPit", original_key = "original_bottomless_pit_shape_points",
		wrapper_key = "bottomless_pit_shape_points_wrapper" },
	{ class = "JumboCave", original_key = "original_jumbo_cave_shape_points",
		wrapper_key = "jumbo_cave_shape_points_wrapper" },
}

local function PatchUndergroundWonderShapeClass(State, spec, force_reinstall)
	local cls = Engine.ClassTable and Engine.ClassTable(spec.class)
	if type(cls) ~= "table" then return false end
	local previous_wrapper = State[spec.wrapper_key]
	local previous_original = State[spec.original_key]
	local current = cls.GetShapePoints
	if current == previous_wrapper and not force_reinstall then return true end
	if current == previous_wrapper and type(previous_original) == "function" then
		current = previous_original
		cls.GetShapePoints = current
	end
	if type(current) ~= "function" then
		local grid_object = Engine.ClassTable and Engine.ClassTable("GridObject")
		current = type(grid_object) == "table" and grid_object.GetShapePoints or nil
	end
	if type(current) ~= "function" then return false end
	local original = current
	local wrapper = function(obj, ...)
		local source_shape = original(obj, ...)
		local scale_x, scale_y = UndergroundWonderShapeScale(obj)
		if not scale_x or scale_x <= 1 or not scale_y or scale_y <= 1 then
			return source_shape
		end
		local entity = type(obj.GetEntity) == "function" and SafeCall(obj.GetEntity, obj)
			or obj.entity
		local cached = underground_wonder_scaled_shape_cache[obj]
		if type(cached) == "table" and cached.source_shape == source_shape
			and cached.entity == entity and cached.scale_x == scale_x
			and cached.scale_y == scale_y then
			return cached.shape
		end
		local shape = ScaleCaveInHexShape(source_shape, scale_x, scale_y)
		underground_wonder_scaled_shape_cache[obj] = {
			source_shape = source_shape,
			entity = entity,
			scale_x = scale_x,
			scale_y = scale_y,
			shape = shape,
		}
		return shape
	end
	State[spec.original_key] = original
	State[spec.wrapper_key] = wrapper
	cls.GetShapePoints = wrapper
	return true
end

local function PatchUndergroundWonderShapePoints()
	local State = SuperBigMap.State or {}
	SuperBigMap.State = State
	local force_reinstall = State.underground_wonder_shape_patch_version
		~= UNDERGROUND_WONDER_SHAPE_PATCH_VERSION
	local all_patched = true
	for _, spec in ipairs(UNDERGROUND_WONDER_SHAPE_PATCHES) do
		if not PatchUndergroundWonderShapeClass(State, spec, force_reinstall) then
			all_patched = false
		end
	end
	if not PatchBottomlessPitSpawnStartPos(State) then all_patched = false end
	State.underground_wonder_shape_patch_version = all_patched
		and UNDERGROUND_WONDER_SHAPE_PATCH_VERSION or nil
	return all_patched
end

local function RestoreUndergroundWonderShapePointsPatch()
	local State = SuperBigMap.State or {}
	for _, spec in ipairs(UNDERGROUND_WONDER_SHAPE_PATCHES) do
		local cls = Engine.ClassTable and Engine.ClassTable(spec.class)
		local wrapper = State[spec.wrapper_key]
		local original = State[spec.original_key]
		if type(cls) == "table" and cls.GetShapePoints == wrapper
			and type(original) == "function" then
			cls.GetShapePoints = original
		end
		State[spec.original_key] = nil
		State[spec.wrapper_key] = nil
	end
	State.underground_wonder_shape_patch_version = nil
	local pit_cls = Engine.ClassTable and Engine.ClassTable("BottomlessPit")
	local pit_wrapper = State.bottomless_pit_spawn_start_wrapper
	local pit_original = State.original_bottomless_pit_spawn_start
	if type(pit_cls) == "table" and pit_cls.GetSpawnStartPos == pit_wrapper
		and type(pit_original) == "function" then
		pit_cls.GetSpawnStartPos = pit_original
	end
	State.original_bottomless_pit_spawn_start = nil
	State.bottomless_pit_spawn_start_wrapper = nil
	State.bottomless_pit_spawn_patch_version = nil
	underground_wonder_scaled_shape_cache = setmetatable({}, { __mode = "k" })
end

-- A terrain-glued CObject still returns a numeric z component: const.InvalidZ
-- (2147483647). Treating "numeric" as "explicit Z" converts that sentinel into a
-- gigantic relief offset and leaves rocks floating after the stretch. Match vanilla's
-- RandomMapGenerator exactly: CObject:IsValidZ is authoritative, with point:IsValidZ
-- and the sentinel comparison retained only as compatibility fallbacks.
local function ObjectHasExplicitZ(obj, pos)
	if obj and type(obj.IsValidZ) == "function" then
		local ok, valid = pcall(obj.IsValidZ, obj)
		if ok then return valid == true end
	end
	if pos and type(pos.IsValidZ) == "function" then
		local ok, valid = pcall(pos.IsValidZ, pos)
		if ok then return valid == true end
	end
	local pz
	pcall(function() pz = pos and pos:z() end)
	if type(pz) ~= "number" then return false end
	local const_tbl = Global("const")
	local invalid_z = type(const_tbl) == "table" and const_tbl.InvalidZ or Global("InvalidZ")
	return type(invalid_z) ~= "number" or pz ~= invalid_z
end

local function ObjectTransformSourceSnapshot(obj, pos)
	local x, y = PointXY(pos)
	local data = { x = x, y = y }
	if type(x) ~= "number" or type(y) ~= "number" then return data end
	local raw_z
	pcall(function() raw_z = pos:z() end)
	local explicit_z = ObjectHasExplicitZ(obj, pos)
	data.raw_z = raw_z
	data.explicit_z = explicit_z
	return data
end

local function DecorationPositionSnapshot(map, obj, pos)
	local data = ObjectTransformSourceSnapshot(obj, pos)
	local x, y = data.x, data.y
	if type(x) ~= "number" or type(y) ~= "number" then return data end
	local raw_z, explicit_z = data.raw_z, data.explicit_z
	local terrain_api = Global("terrain")
	local ground_z
	if type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function" then
		local ok, value = pcall(terrain_api.GetHeight, map, pos)
		if ok and type(value) == "number" then ground_z = value end
	end
	data.ground_z = ground_z
	data.effective_z = explicit_z and raw_z or ground_z
	if type(terrain_api) == "table" then
		if type(terrain_api.IsPointInBounds) == "function" then
			local ok, value = pcall(terrain_api.IsPointInBounds, map, pos)
			if ok then data.in_bounds = value == true end
		end
		if type(terrain_api.IsPassable) == "function" then
			local ok, value = pcall(terrain_api.IsPassable, map, pos)
			if ok then data.passable = value == true end
		end
		if type(terrain_api.GetTerrainType) == "function" then
			local ok, value = pcall(terrain_api.GetTerrainType, map, pos)
			if ok then
				data.terrain_type = value
				local textures = Global("TerrainTextures")
				local preset = type(textures) == "table" and textures[value]
				data.terrain_id = type(preset) == "table" and preset.id or nil
			end
		end
	end
	local world_to_hex = Global("WorldToHex")
	if type(world_to_hex) == "function" then
		local ok, q, r = pcall(world_to_hex, pos)
		if ok and type(q) == "number" and type(r) == "number" then
			data.q, data.r = q, r
			local buildable = map and map.buildable
			if buildable and type(buildable.GetZ) == "function" then
				local ok_b, build_z = pcall(buildable.GetZ, buildable, q, r)
				if ok_b then
					data.buildable_z = build_z
					local get_unbuildable = Global("buildUnbuildableZ")
					local sentinel = type(get_unbuildable) == "function"
						and SafeCall(get_unbuildable) or nil
					data.buildable = build_z ~= nil and build_z ~= sentinel
				end
			end
		end
	end
	return data
end

local function DecorationAuditFields(prefix, snapshot, out)
	out = out or {}
	snapshot = snapshot or {}
	for _, key in ipairs({
		"x", "y", "raw_z", "effective_z", "ground_z", "explicit_z",
		"q", "r", "in_bounds", "passable", "buildable", "buildable_z",
		"terrain_type", "terrain_id",
	}) do
		local value = snapshot[key]
		out[prefix .. key] = value == nil and "nil" or value
	end
	return out
end


-- terrain_source_map is optional. Direct temporary-source stretching installs the final terrain
-- before objects transfer, so its destination objects must be enumerated on map while their
-- pre-stretch ground heights are still sampled from the untouched temporary source.
local function AnnotateDecorRelief(map, terrain_source_map)
	if not map then return 0 end
	if type(map.MapForEach) ~= "function" then return 0 end
	local relief_enabled = cfg_bool("STRETCH_RELIEF_AWARE_DECOR", true)
	local optimize_traversal = cfg_bool("OPTIMIZE_STRETCH_DECOR_TRAVERSAL", true)
	-- The placement loop already rejects invalid wrappers before invoking any C-object method. Keep
	-- the eligible subset on underground maps too: enrichment staging may invalidate a few cached
	-- wrappers, but rescanning class/kind/parent metadata for every one of the ~6,500 surviving
	-- decorations cannot alter which valid objects pass the predicates captured here.
	local cache_eligible_objects = optimize_traversal
	local terrain_api = Global("terrain")
	local box_fn = Global("box")
	local relief_terrain_available = type(terrain_api) == "table"
		and type(terrain_api.GetHeight) == "function"
	local relief_terrain_map = terrain_source_map or map
	if type(box_fn) ~= "function" then return 0 end
	local const_tbl = Global("const")
	local hts = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number") and const_tbl.HeightTileSize or 1
	local sw_tiles = map.SuperBigMapSourceWidthTiles or map.SuperBigMapGeneratorWidthTiles
	local sh_tiles = map.SuperBigMapSourceHeightTiles or map.SuperBigMapGeneratorHeightTiles
	if type(sw_tiles) ~= "number" or sw_tiles <= 0 then return 0 end
	sh_tiles = (type(sh_tiles) == "number" and sh_tiles > 0) and sh_tiles or sw_tiles
	local src_box = box_fn(0, 0, sw_tiles * hts, sh_tiles * hts)
	local relief = setmetatable({}, { __mode = "k" })
	local objects = {}
	local eligible_objects = {}
	local annotated = 0
	local eligible = 0
	local terrain_glued = 0
	local height_failures = 0
	local max_abs_relief = 0
	local audit_on = UndergroundDecorationAuditEnabled(map)
	local audit_records = audit_on and setmetatable({}, { __mode = "k" }) or nil
	local audit_list = audit_on and {} or nil
	-- CaveInRubble and TunnelBlockerRubble are gameplay blockers, not cosmetic decorations. Keep a
	-- compact transform capture for the dedicated expansion pass; this is required state, not an
	-- audit record.
	local cave_capture = {
		list = {},
	}
	local capture_traversal_ok, capture_traversal_err = pcall(
		map.MapForEach, map, src_box, "CObject", function(obj)
		if not obj then return end
		objects[#objects + 1] = obj
		-- Persist the immutable vanilla transform before any parent, attachment, transfer, or
		-- destination operation can change it. Attached children follow their parent during the
		-- parent's move; deriving their transform later from that already-moved position applies the
		-- expansion twice. These stamps make every object use its one original source coordinate and
		-- source scale, on both the surface and underground paths.
		local source_pos = ObjectPosition(obj)
		if source_pos then
			local source_x, source_y = PointXY(source_pos)
			if type(source_x) == "number" and type(obj.SuperBigMapNativeSourceX) ~= "number" then
				obj.SuperBigMapNativeSourceX = source_x
			end
			if type(source_y) == "number" and type(obj.SuperBigMapNativeSourceY) ~= "number" then
				obj.SuperBigMapNativeSourceY = source_y
			end
			if type(obj.SuperBigMapNativeSourceZ) ~= "number" and type(source_pos.z) == "function" then
				local ok_z, source_z = pcall(source_pos.z, source_pos)
				if ok_z and type(source_z) == "number" then
					obj.SuperBigMapNativeSourceZ = source_z
				end
			end
		end
		if type(obj.SuperBigMapNativeSourceScale) ~= "number"
			and type(obj.GetScale) == "function" then
			local source_scale = SafeCall(obj.GetScale, obj)
			if type(source_scale) == "number" then
				obj.SuperBigMapNativeSourceScale = source_scale
			end
		end
		if type(obj.SuperBigMapNativeSourceAngle) ~= "number"
			and type(obj.GetAngle) == "function" then
			local source_angle = SafeCall(obj.GetAngle, obj)
			if type(source_angle) == "number" then
				obj.SuperBigMapNativeSourceAngle = source_angle
			end
		end
		obj.SuperBigMapNativeSourceClass = obj.SuperBigMapNativeSourceClass
			or tostring(obj.class or "?")
		local skip_object = ShouldSkipObject(obj)
		local important_object = IsImportantSectorObject(obj)
		if cache_eligible_objects and not skip_object and not important_object then
			eligible_objects[#eligible_objects + 1] = obj
		end
		if IsCaveInObject(obj) then
			local pos = ObjectPosition(obj)
			if pos then
				local source_scale = type(obj.GetScale) == "function"
					and SafeCall(obj.GetScale, obj) or nil
				local record = {
					index = #cave_capture.list + 1,
					object_ref = obj,
					object = tostring(obj),
					class = tostring(obj.class or "?"),
					source_scale = source_scale,
					source_shape_hexes = CaveInShapePointCount(obj),
					source = ObjectTransformSourceSnapshot(obj, pos),
				}
				cave_capture.list[#cave_capture.list + 1] = record
			end
		end
		if audit_on and not skip_object and not important_object then
			local pos = ObjectPosition(obj)
			if pos then
				local parent
				if type(obj.GetParent) == "function" then
					local ok_p, value = pcall(obj.GetParent, obj)
					if ok_p then parent = value end
				end
				local record = {
					index = #audit_list + 1,
					object = tostring(obj),
					class = tostring(obj.class or "?"),
					entity = tostring(type(obj.GetEntity) == "function"
						and SafeCall(obj.GetEntity, obj) or obj.entity or "?"),
					attached = parent ~= nil,
					parent = parent and tostring(parent) or "nil",
					source = DecorationPositionSnapshot(map, obj, pos),
				}
				audit_records[obj] = record
				audit_list[#audit_list + 1] = record
			end
		end
		if not relief_enabled or not relief_terrain_available then return end
		-- Relief is consumed only by the decoration scaling pass. Avoid terrain-height calls for
		-- buildings, markers, units, attached children, and other objects that pass never moves.
		if optimize_traversal
			and (skip_object or important_object) then return end
		if type(obj.GetParent) == "function" then
			local ok_p, parent = pcall(obj.GetParent, obj)
			if ok_p and parent then return end -- attached children follow their parent
		end
		local pos = ObjectPosition(obj)
		if not pos then return end
		eligible = eligible + 1
		if not ObjectHasExplicitZ(obj, pos) then
			terrain_glued = terrain_glued + 1
			return
		end
		local pz
		pcall(function() pz = pos:z() end)
		if type(pz) ~= "number" then return end
		local ok_h, h = pcall(terrain_api.GetHeight, relief_terrain_map, pos)
		if not ok_h or type(h) ~= "number" then
			height_failures = height_failures + 1
			return
		end
		local dz = pz - h
		relief[obj] = dz
		max_abs_relief = math.max(max_abs_relief, math.abs(dz))
		annotated = annotated + 1
	end)
	cave_capture.capture_ok = capture_traversal_ok == true
	cave_capture.capture_error = capture_traversal_ok ~= true
		and tostring(capture_traversal_err) or nil
	-- Native generation places a few objects (prefab markers) just BEYOND the source rect, so the
	-- src_box traversal above never sees them and they keep no source stamp. The surface survives
	-- that because TransferGeneratedObjects stamps through an unbounded MapGet before transfer -- it
	-- stamps those objects without moving them. The underground is stretched in place and has no
	-- transfer pass, so its out-of-box objects stayed unstamped and the parity bijection lost them
	-- (b2-10 (584773,619417) and b2-07 (591080,615669), one unstamped/one unclaimed each). Give the
	-- underground the surface's guarantee with a stamp-only sweep over the DESTINATION rect: it fills
	-- missing SuperBigMapNativeSource* only -- no relief, no cave capture, no eligibility, and no
	-- move, so the two scaling passes below keep their src_box scope and the proven floors are
	-- untouched. Anchoring the box at (0,0) keeps the negative-coordinate CameraObj out.
	local out_of_box_stamped = 0
	local out_of_box_despawned = 0
	if cfg_bool("STRETCH_STAMP_OUT_OF_BOX_SOURCES", true) then
		local full_tw = map.SuperBigMapDesiredWidthTiles
		local full_th = map.SuperBigMapDesiredHeightTiles
		if type(full_tw) ~= "number" or full_tw <= 0 then
			local mapdata = map.mapdata
			full_tw = (type(mapdata) == "table" and type(mapdata.Width) == "number") and mapdata.Width or nil
			full_th = (type(mapdata) == "table" and type(mapdata.Height) == "number") and mapdata.Height or full_tw
		end
		if type(full_tw) == "number" and type(full_th) == "number"
			and (full_tw > sw_tiles or full_th > sh_tiles) then
			-- Stamping is right only for the out-of-box objects vanilla itself has. Vanilla's own map
			-- box drops a prefab's spill past the source edge; the expanded run generates its native
			-- source inside the already enlarged map, so that spill survives as content with no
			-- vanilla counterpart, left unmoved by the src_box move passes (sweep-04, see
			-- config.StretchDespawnOutOfBoxContent). Every out-of-box VANILLA row measured across nine
			-- twin pairs on both maps is a PrefabMarker, so keep markers plus the destination's own
			-- enumerated infrastructure and despawn the rest. Collect first: destroying inside
			-- MapForEach would mutate the container being traversed.
			local despawn_out_of_box_content = cfg_bool("STRETCH_DESPAWN_OUT_OF_BOX_CONTENT", true)
			local keep_out_of_box_class = {
				PrefabMarker = true,
				MapSector = true,
				SectorUnexplored = true,
				SectorScanned = true,
				GridObjectList = true,
				CameraObj = true,
				RandomMapGeneratorHolder = true,
			}
			local src_w_wu, src_h_wu = sw_tiles * hts, sh_tiles * hts
			local out_of_box_content = {}
			pcall(map.MapForEach, map, box_fn(0, 0, full_tw * hts, full_th * hts), "CObject",
				function(obj)
				if not obj then return end
				if type(obj.SuperBigMapNativeSourceX) == "number" then return end
				local source_pos = ObjectPosition(obj)
				if not source_pos then return end
				local source_x, source_y = PointXY(source_pos)
				if type(source_x) ~= "number" or type(source_y) ~= "number" then return end
				if despawn_out_of_box_content
					and (source_x >= src_w_wu or source_y >= src_h_wu)
					and not keep_out_of_box_class[tostring(obj.class or "?")]
					and not IsKindOfSafe(obj, "PrefabMarker")
					and not IsKindOfSafe(obj, "MapSector")
					and not IsKindOfSafe(obj, "GridObjectList") then
					out_of_box_content[#out_of_box_content + 1] = obj
					return
				end
				obj.SuperBigMapNativeSourceX = source_x
				obj.SuperBigMapNativeSourceY = source_y
				if type(obj.SuperBigMapNativeSourceZ) ~= "number" and type(source_pos.z) == "function" then
					local ok_z, source_z = pcall(source_pos.z, source_pos)
					if ok_z and type(source_z) == "number" then
						obj.SuperBigMapNativeSourceZ = source_z
					end
				end
				if type(obj.SuperBigMapNativeSourceScale) ~= "number"
					and type(obj.GetScale) == "function" then
					local source_scale = SafeCall(obj.GetScale, obj)
					if type(source_scale) == "number" then
						obj.SuperBigMapNativeSourceScale = source_scale
					end
				end
				if type(obj.SuperBigMapNativeSourceAngle) ~= "number"
					and type(obj.GetAngle) == "function" then
					local source_angle = SafeCall(obj.GetAngle, obj)
					if type(source_angle) == "number" then
						obj.SuperBigMapNativeSourceAngle = source_angle
					end
				end
				obj.SuperBigMapNativeSourceClass = obj.SuperBigMapNativeSourceClass
					or tostring(obj.class or "?")
				out_of_box_stamped = out_of_box_stamped + 1
			end)
			local done_object = Global("DoneObject")
			if #out_of_box_content > 0 and type(done_object) == "function" then
				local is_valid = Global("IsValid")
				for index = 1, #out_of_box_content do
					local obj = out_of_box_content[index]
					local alive = type(is_valid) ~= "function" or SafeCall(is_valid, obj) == true
					if alive and pcall(done_object, obj) then
						out_of_box_despawned = out_of_box_despawned + 1
					end
				end
			end
		end
	end
	decor_relief_by_map[map] = relief
	decor_position_audit_by_map[map] = audit_records
	decor_relief_stats_by_map[map] = {
		scanned = #objects,
		audit_candidates = audit_on and #audit_list or 0,
		eligible = eligible,
		explicit_z = annotated,
		terrain_glued = terrain_glued,
		height_failures = height_failures,
		max_abs_relief = max_abs_relief,
		out_of_box_stamped = out_of_box_stamped,
		out_of_box_despawned = out_of_box_despawned,
		terrain_source_is_destination = relief_terrain_map == map,
	}
	cave_in_transform_capture_by_map[map] = cave_capture
	if optimize_traversal then
		decor_objects_by_map[map] = objects
		if cache_eligible_objects then decor_eligible_objects_by_map[map] = eligible_objects end
	end
	if audit_on then
		UndergroundDecorationAudit("CAPTURE_SUMMARY", {
			candidates = #audit_list,
			scanned = #objects,
			scale_source_width_tiles = sw_tiles,
			scale_source_height_tiles = sh_tiles,
		}, map)
		for _, record in ipairs(audit_list) do
			local data = DecorationAuditFields("source_", record.source, {
				index = record.index,
				object = record.object,
				class = record.class,
				entity = record.entity,
				attached = record.attached,
				parent = record.parent,
			})
			UndergroundDecorationAudit("PRE", data, map)
		end
	end
	LoadingStep("decoration relief capture complete", decor_relief_stats_by_map[map], map)
	return annotated
end

local function ClearDecorRelief(map)
	if map then
		decor_relief_by_map[map] = nil
		decor_objects_by_map[map] = nil
		decor_eligible_objects_by_map[map] = nil
		decor_relief_stats_by_map[map] = nil
		decor_position_audit_by_map[map] = nil
		cave_in_transform_capture_by_map[map] = nil
	end
end

local function CaveInTerrainGluedPoint(x, y, raw_z, explicit_z)
	local point_fn = Global("point")
	if type(point_fn) ~= "function" then return nil end
	if explicit_z == true and type(raw_z) == "number" then
		return point_fn(x, y, raw_z)
	end
	local pos = point_fn(x, y)
	if type(pos.SetInvalidZ) == "function" then
		local ok, invalid_pos = pcall(pos.SetInvalidZ, pos)
		if ok and invalid_pos then pos = invalid_pos end
	end
	return pos
end

-- CaveInRubble and TunnelBlockerRubble are Buildings and are intentionally excluded from the
-- cosmetic-decoration loop. Transform them explicitly while their vanilla source coordinates are
-- still captured, updating GridObject registration around each move so every expanded visual wall
-- and gameplay footprint continues to describe the same obstruction.
local function ScaleCapturedCaveInsToFull(map, scale_x, scale_y, full_tw, full_th, sw_tiles, sh_tiles)
	local capture = cave_in_transform_capture_by_map[map]
	local stats = {
		captured = type(capture) == "table" and type(capture.list) == "table"
			and #capture.list or 0,
		transformed = 0,
		missing_objects = 0,
		transform_failures = 0,
		grid_remove_failures = 0,
		grid_apply_failures = 0,
		cave_in_rubble = 0,
		tunnel_blocker_rubble = 0,
		source_shape_hexes = 0,
		expanded_shape_hexes = 0,
		scale_x = scale_x,
		scale_y = scale_y,
	}
	if type(capture) ~= "table" or type(capture.list) ~= "table" then
		stats.error = "no underground rubble-wall source capture"
		return false, stats
	end
	if capture.capture_ok ~= true then
		stats.error = "underground rubble-wall source traversal failed: "
			.. tostring(capture.capture_error)
		stats.transform_failures = #capture.list
		return false, stats
	end
	if #capture.list == 0 then
		return true, stats
	end
	if not PatchCaveInShapePoints() then
		stats.error = "underground rubble-wall GetShapePoints patch unavailable"
		stats.transform_failures = #capture.list
		return false, stats
	end

	local is_valid = Global("IsValid")
	local MAX_SCALE = 500
	for _, record in ipairs(capture.list) do
		if record.class == "CaveInRubble" then
			stats.cave_in_rubble = stats.cave_in_rubble + 1
		elseif record.class == "TunnelBlockerRubble" then
			stats.tunnel_blocker_rubble = stats.tunnel_blocker_rubble + 1
		end
		local obj = record.object_ref
		local live = obj ~= nil
			and (type(is_valid) ~= "function" or SafeCall(is_valid, obj) == true)
		if not live then
			stats.missing_objects = stats.missing_objects + 1
		else
			local source = record.source or {}
			local source_x, source_y = tonumber(source.x), tonumber(source.y)
			local old_scale = tonumber(record.source_scale)
			local had_grids = obj.grids_applied == true
			local transform_ok, transform_err = pcall(function()
				if type(source_x) ~= "number" or type(source_y) ~= "number" then
					error("source position unavailable")
				end
				if had_grids then
					if type(obj.RemoveFromGrids) ~= "function" then
						stats.grid_remove_failures = stats.grid_remove_failures + 1
						error("RemoveFromGrids unavailable")
					end
					obj:RemoveFromGrids()
					if obj.grids_applied == true then
						stats.grid_remove_failures = stats.grid_remove_failures + 1
						error("old underground rubble-wall footprint remained registered")
					end
				end

				-- Integer numerator/denominator fields survive save/load exactly and let the transparent
				-- class wrapper rebuild the expanded outline without serializing a point-array cache.
				obj.SuperBigMapCaveInShapeScaleXMul = full_tw
				obj.SuperBigMapCaveInShapeScaleXDiv = sw_tiles
				obj.SuperBigMapCaveInShapeScaleYMul = full_th
				obj.SuperBigMapCaveInShapeScaleYDiv = sh_tiles
				cave_in_scaled_shape_cache[obj] = nil

				local target_x = math.floor(source_x * scale_x + 0.5)
				local target_y = math.floor(source_y * scale_y + 0.5)
				local target = CaveInTerrainGluedPoint(target_x, target_y)
				if not target or type(obj.SetPos) ~= "function" then error("SetPos unavailable") end
				obj:SetPos(target)
				if type(old_scale) == "number" and old_scale > 0 then
					if type(obj.SetScale) ~= "function" then error("SetScale unavailable") end
					local target_scale = math.max(1,
						math.min(MAX_SCALE, math.floor(old_scale * scale_x + 0.5)))
					obj:SetScale(target_scale)
				end
				record.expanded_shape_hexes = CaveInShapePointCount(obj)
				if type(record.expanded_shape_hexes) ~= "number"
					or record.expanded_shape_hexes <= 0 then error("expanded shape unavailable") end

				if had_grids then
					if type(obj.ApplyToGrids) ~= "function" then
						stats.grid_apply_failures = stats.grid_apply_failures + 1
						error("ApplyToGrids unavailable")
					end
					obj:ApplyToGrids()
					if obj.grids_applied ~= true then
						stats.grid_apply_failures = stats.grid_apply_failures + 1
						error("expanded underground rubble-wall footprint was not registered")
					end
				end
			end)

			if not transform_ok then
				stats.transform_failures = stats.transform_failures + 1
				-- Restore the original object/grid state before aborting the map transaction. This keeps
				-- a protected failure from leaving a ghost blocker registered at either coordinate.
				pcall(function()
					if obj.grids_applied == true and type(obj.RemoveFromGrids) == "function" then
						obj:RemoveFromGrids()
					end
					obj.SuperBigMapCaveInShapeScaleXMul = nil
					obj.SuperBigMapCaveInShapeScaleXDiv = nil
					obj.SuperBigMapCaveInShapeScaleYMul = nil
					obj.SuperBigMapCaveInShapeScaleYDiv = nil
					cave_in_scaled_shape_cache[obj] = nil
					if type(old_scale) == "number" and type(obj.SetScale) == "function" then
						obj:SetScale(old_scale)
					end
					local original_pos = CaveInTerrainGluedPoint(
						source_x, source_y, source.raw_z, source.explicit_z)
					if original_pos and type(obj.SetPos) == "function" then obj:SetPos(original_pos) end
					if had_grids and type(obj.ApplyToGrids) == "function" then obj:ApplyToGrids() end
				end)
				stats.first_error = stats.first_error or (tostring(record.class)
					.. " " .. tostring(record.object) .. ": " .. tostring(transform_err))
			else
				stats.transformed = stats.transformed + 1
				stats.source_shape_hexes = stats.source_shape_hexes
					+ (tonumber(record.source_shape_hexes) or 0)
				stats.expanded_shape_hexes = stats.expanded_shape_hexes
					+ (tonumber(record.expanded_shape_hexes) or 0)
			end
		end
	end
	local ok = stats.missing_objects == 0 and stats.transform_failures == 0
	return ok, stats
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
	local optimized_traversal = cfg_bool("OPTIMIZE_STRETCH_DECOR_TRAVERSAL", true)
	local objs = optimized_traversal and decor_eligible_objects_by_map[map] or nil
	local preclassified = type(objs) == "table"
	if not preclassified and optimized_traversal then objs = decor_objects_by_map[map] end
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
	local relief_placed = 0
	local terrain_snapped = 0
	local unresolved_z = 0
	local setpos_failures = 0
	local topup_clones = 0
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
	local cave_ok, cave_stats = ScaleCapturedCaveInsToFull(
		map, scale_x, scale_y, full_tw, full_th, sw_tiles, sh_tiles)
	if cave_ok ~= true then
		if owns_pass_batch then pcall(map.ResumePassEdits, map, "SuperBigMapStretchDecor") end
		error("dedicated underground rubble-wall transform failed (captured="
			.. tostring(cave_stats and cave_stats.captured or "?")
			.. ", failures=" .. tostring(cave_stats and cave_stats.transform_failures or "?") .. ")")
	end
	local is_valid = Global("IsValid")
	local audit_on = UndergroundDecorationAuditEnabled(map)
	local audit_records = decor_position_audit_by_map[map]
	local relief = decor_relief_by_map[map]
	local terrain_get_height = type(terrain_api_g) == "table" and terrain_api_g.GetHeight or nil
	local z_scale = (type(map.SuperBigMapZScaleMul) == "number"
		and type(map.SuperBigMapZScaleDiv) == "number"
		and map.SuperBigMapZScaleDiv > 0)
		and ((map.SuperBigMapZScaleMul + 0.0) / map.SuperBigMapZScaleDiv) or scale_x
	local audit_post_count = 0
	for _, obj in ipairs(objs) do
		if not obj then
			-- nil entry, ignore
		elseif type(is_valid) == "function" and SafeCall(is_valid, obj) ~= true then
			-- The cached pre-stretch traversal includes enrichment markers that staging has since
			-- destroyed. Do not cross into any C object method through their stale Lua wrappers.
		elseif not preclassified and ShouldSkipObject(obj) then
		elseif not preclassified and IsImportantSectorObject(obj) then
		else
			pcall(function()
				-- Passage bootstrap can create a committed final-domain passage before this pass.
				-- Its attached indicator decal already follows that final parent, so transforming
				-- the child independently would apply a second 4/3 move.
				if type(obj.GetParent) == "function" then
					local ok_parent, parent = pcall(obj.GetParent, obj)
					if ok_parent and type(parent) == "table"
						and parent.SuperBigMapCommittedPassageLocked == true then
						return
					end
				end
				local pos = ObjectPosition(obj)
				if not pos then return end
				local audit_record = audit_on and audit_records and audit_records[obj]
				local before_snapshot = audit_on and DecorationPositionSnapshot(map, obj, pos) or nil
				local ox, oy = PointXY(pos)
				if type(ox) ~= "number" or type(oy) ~= "number" then return end
				local source_x = type(obj.SuperBigMapNativeSourceX) == "number"
					and obj.SuperBigMapNativeSourceX or ox
				local source_y = type(obj.SuperBigMapNativeSourceY) == "number"
					and obj.SuperBigMapNativeSourceY or oy
				local nx = math.floor(source_x * scale_x + 0.5)
				local ny = math.floor(source_y * scale_y + 0.5)
				local np = point_fn(nx, ny)
				local z_ok = false
				local z_mode = "snap"
				-- Relief-aware Z: reproduce the object's pre-stretch relationship to the ground
				-- (dz annotated before the terrain stretch), scaled by the same factor, on top of
				-- the ACTUAL stretched terrain height at the destination.
				local dz = relief and relief[obj]
				if type(dz) == "number" and type(terrain_get_height) == "function" then
					local ok_h, h = pcall(terrain_get_height, map, np)
					if ok_h and type(h) == "number" then
						-- dz scales by the Z factor (which the shift+adaptive height transform
						-- may have set below the XY factor; the shift offset cancels in a
						-- difference). Fallback: the XY factor when no stamp (heights unscaled).
						np = point_fn(nx, ny, h + math.floor(dz * z_scale + 0.5))
						z_ok = true
						z_mode = "relief"
						relief_placed = relief_placed + 1
					end
				end
				if not z_ok and type(np.SetTerrainZ) == "function" then
					local ok_z, pz = pcall(np.SetTerrainZ, np, map)
					if ok_z and pz then
						np = pz
						z_ok = true
						terrain_snapped = terrain_snapped + 1
					end
				end
				if not z_ok then unresolved_z = unresolved_z + 1 end
				if type(obj.SetPos) == "function" then
					local ok_set = pcall(obj.SetPos, obj, np)
					if not ok_set then setpos_failures = setpos_failures + 1 end
					moved = moved + 1
				end
				if audit_on then
					audit_post_count = audit_post_count + 1
					local actual_pos = ObjectPosition(obj)
					local actual = actual_pos and DecorationPositionSnapshot(map, obj, actual_pos) or {}
					local source = audit_record and audit_record.source or {}
					-- The authoritative expected coordinate always derives from the PRE-stretch
					-- snapshot, never from the object's current coordinate. If an attached child
					-- followed its parent before its own loop iteration, attempted_x/y will expose
					-- the second transform while expected_x/y retain the one-transform truth.
					local expected_x = type(source.x) == "number"
						and math.floor(source.x * scale_x + 0.5) or nx
					local expected_y = type(source.y) == "number"
						and math.floor(source.y * scale_y + 0.5) or ny
					local expected = DecorationPositionSnapshot(
						map, nil, point_fn(expected_x, expected_y))
					local expected_z = expected.ground_z
					local source_dz = type(source.effective_z) == "number"
						and type(source.ground_z) == "number"
						and source.explicit_z == true
						and (source.effective_z - source.ground_z) or nil
					if type(source_dz) == "number" and type(expected.ground_z) == "number" then
						expected_z = expected.ground_z + math.floor(source_dz * z_scale + 0.5)
					end
					expected.effective_z = expected_z
					local attached = "uncaptured"
					if audit_record then attached = audit_record.attached end
					local data = {
						index = audit_record and audit_record.index or "uncaptured",
						object = audit_record and audit_record.object or tostring(obj),
						class = audit_record and audit_record.class or tostring(obj.class or "?"),
						entity = audit_record and audit_record.entity or tostring(obj.entity or "?"),
						attached = attached,
						parent = audit_record and audit_record.parent or "uncaptured",
						transform_input_x = ox,
						transform_input_y = oy,
						attempted_x = nx,
						attempted_y = ny,
						expected_x = expected_x,
						expected_y = expected_y,
						expected_z = expected_z or "nil",
						x_error = type(actual.x) == "number" and actual.x - expected_x or "nil",
						y_error = type(actual.y) == "number" and actual.y - expected_y or "nil",
						z_error = type(actual.effective_z) == "number" and type(expected_z) == "number"
							and actual.effective_z - expected_z or "nil",
						z_mode = z_mode,
					}
					DecorationAuditFields("source_", source, data)
					DecorationAuditFields("before_move_", before_snapshot, data)
					DecorationAuditFields("expected_terrain_", expected, data)
					DecorationAuditFields("actual_", actual, data)
					UndergroundDecorationAudit("POST", data, map)
				end
				-- Grow the object to match the enlarged terrain features -- but only if it is
				-- decoration. A functional object's size is gameplay or generation geometry
				-- (scan radius, hex footprint, prefab placement footprint, sound/particle
				-- reach), so it keeps its vanilla scale, exactly as ScaleMarkersToFull already
				-- does for the markers it owns. See ObjectClone.ClassScalesWithTerrain.
				if type(obj.GetScale) == "function" and type(obj.SetScale) == "function"
					and ObjectScalesWithTerrain(obj) then
					local s = type(obj.SuperBigMapNativeSourceScale) == "number"
						and obj.SuperBigMapNativeSourceScale or SafeCall(obj.GetScale, obj)
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
					local clone = CloneObjectAtOffset(
						map, obj, point_fn(cx - nx, cy - ny), true)
					if clone then
						topup_clones = topup_clones + 1
						-- Snap the clone onto the surface at its jittered spot.
						local cp = point_fn(cx, cy)
						if type(cp.SetTerrainZ) == "function" then
							local ok_cz, cpz = pcall(cp.SetTerrainZ, cp, map)
							if ok_cz and cpz then cp = cpz end
						end
						if type(clone.SetPos) == "function" then pcall(clone.SetPos, clone, cp) end
						if audit_on then
							local clone_pos = ObjectPosition(clone)
							local clone_snapshot = clone_pos
								and DecorationPositionSnapshot(map, clone, clone_pos) or {}
							local clone_data = DecorationAuditFields("actual_", clone_snapshot, {
								source_index = audit_record and audit_record.index or "uncaptured",
								source_object = audit_record and audit_record.object or tostring(obj),
								object = tostring(clone),
								class = tostring(clone.class or "?"),
								entity = tostring(type(clone.GetEntity) == "function"
									and SafeCall(clone.GetEntity, clone) or clone.entity or "?"),
							})
							UndergroundDecorationAudit("POST_TOPUP", clone_data, map)
						end
					end
				end
			end)
		end
	end
	if owns_pass_batch then
		pcall(map.ResumePassEdits, map, "SuperBigMapStretchDecor")
	end
	local capture = decor_relief_stats_by_map[map] or {}
	if audit_on then
		UndergroundDecorationAudit("PLACEMENT_SUMMARY", {
			captured_candidates = capture.audit_candidates or 0,
			post_records = audit_post_count,
			moved = moved,
			topup_clones = topup_clones,
		}, map)
	end
	LoadingStep("decoration stretch placement complete", {
		scanned = capture.scanned or #objs,
		placement_inputs = #objs,
		preclassified = tostring(preclassified),
		reused_collection = tostring(reused_collection),
		moved = moved,
		cave_ins_transformed = cave_stats and cave_stats.transformed or 0,
		rubble_walls_transformed = cave_stats and cave_stats.transformed or 0,
		cave_in_rubble = cave_stats and cave_stats.cave_in_rubble or 0,
		tunnel_blocker_rubble = cave_stats and cave_stats.tunnel_blocker_rubble or 0,
		cave_in_source_shape_hexes = cave_stats and cave_stats.source_shape_hexes or 0,
		cave_in_expanded_shape_hexes = cave_stats and cave_stats.expanded_shape_hexes or 0,
		explicit_z_captured = capture.explicit_z or 0,
		terrain_glued_captured = capture.terrain_glued or 0,
		relief_placed = relief_placed,
		terrain_snapped = terrain_snapped,
		unresolved_z = unresolved_z,
		setpos_failures = setpos_failures,
		topup_clones = topup_clones,
	}, map)
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
	local marker_class_cache = {}
	local function is_marker(obj)
		local class = obj and obj.class
		if type(class) == "string" and marker_class_cache[class] ~= nil then
			return marker_class_cache[class]
		end
		local result = IsImportantSectorObject(obj) -- resource deposit markers (surface/subsurface/terrain)
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
		if type(class) == "string" then marker_class_cache[class] = result == true end
		return result
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
				-- Passage bootstrap runs against the already expanded surface and commits the surface
				-- anchor before this marker pass. Its tunnel marker and attached decal are therefore
				-- already in final-domain coordinates; scaling that marker again moves both visuals by
				-- a second 4/3 transform while leaving the committed passage/sign behind.
				if IsKindOfSafe(obj, "SurfaceUndergroundTunnelMarker")
					and type(obj.spawner) == "table"
					and obj.spawner.SuperBigMapCommittedPassageLocked == true then
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
				-- Buried wonders are materialized only after this pass. Preserve their authoritative
				-- native center so their large authored meshes can use the exact world-space affine
				-- transform. Unlike deposits, a buried-wonder anchor must NOT be moved to the nearest
				-- destination hex: a source hex center multiplied by 4/3 normally falls between hex
				-- centers, and that generic snap visibly separates Jumbo Cave's contact edge from the
				-- stretched wall (and shifts Cave of Wonders relative to its opening).
				local is_buried_wonder_marker = IsKindOfSafe(obj, "BuriedWonderMarker")
				if is_buried_wonder_marker then
					capture_owner.SuperBigMapNativeSourceX = source_x
					capture_owner.SuperBigMapNativeSourceY = source_y
					if type(oz) == "number" then capture_owner.SuperBigMapNativeSourceZ = oz end
				end
				local raw_nx = math.floor(source_origin_x
					+ (source_x - source_origin_x) * scale_x + 0.5)
				local raw_ny = math.floor(source_origin_y
					+ (source_y - source_origin_y) * scale_y + 0.5)
				local nx, ny = raw_nx, raw_ny
				local captured_native = type(capture_owner.SuperBigMapNativeSourceX) == "number"
					and type(capture_owner.SuperBigMapNativeSourceY) == "number"
				if captured_native and not is_buried_wonder_marker
					and type(world_to_hex) == "function"
					and type(hex_to_world) == "function" then
					local ok_h, q, r = pcall(world_to_hex, point_fn(raw_nx, raw_ny))
					if ok_h and type(q) == "number" and type(r) == "number" then
						local ok_w, aligned_x, aligned_y = pcall(hex_to_world, q, r)
						if ok_w and type(aligned_x) == "number" and type(aligned_y) == "number" then
							nx, ny = aligned_x, aligned_y
						end
					end
				end
				if captured_native then
					capture_owner.SuperBigMapRawStretchedX = raw_nx
					capture_owner.SuperBigMapRawStretchedY = raw_ny
					capture_owner.SuperBigMapExpectedStretchedX = nx
					capture_owner.SuperBigMapExpectedStretchedY = ny
					capture_owner.SuperBigMapXYTransformMode = is_buried_wonder_marker
						and "exact_world_affine" or "nearest_destination_hex"
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

-- Only surface-side entrance markers need the badge-position wrapper. Underground
-- SurfaceTunnelMarker/SignUnderground objects remain entirely under vanilla's reveal and placement
-- lifecycle, and the shared sign SetPos wrapper explicitly bypasses them.
local ENTRANCE_BADGE_POSITION_PATCH_VERSION = 6
local ENTRANCE_BADGE_MARKER_CLASSES = {
	"SurfaceUndergroundTunnelMarker", "UndergroundTunnelMarker",
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
	if type(z) == "number" and type(point_fn) == "function" and type(sign.SetPos) == "function" then
		pcall(sign.SetPos, sign, point_fn(x, y, z))
	end
	return true
end

local function RestoreEntranceBadgePosition(marker, sign, reason)
	if not marker or not sign or type(sign.SetPos) ~= "function" then return false end
	if IsUndergroundExitMarker(marker, sign) then return false end
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
	-- A pre-cleanup hot reload may still have the old no-op wrapper on the vanilla underground
	-- marker class. Peel it off once before installing the surface-only patch set.
	local underground_marker_class = Engine.ClassTable and Engine.ClassTable("SurfaceTunnelMarker")
	if type(underground_marker_class) == "table"
		and underground_marker_class.PlaceSign == wrappers.SurfaceTunnelMarker
		and type(originals.SurfaceTunnelMarker) == "function" then
		underground_marker_class.PlaceSign = originals.SurfaceTunnelMarker
	end
	originals.SurfaceTunnelMarker = nil
	wrappers.SurfaceTunnelMarker = nil
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
			if sign and not IsUndergroundExitMarker(marker, sign) then
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
			return result
		end
		originals[class_name] = original
		wrappers[class_name] = wrapper
		cls.PlaceSign = wrapper
		installed = installed + 1
	end

	-- DepositMarker:PlaceDeposit unconditionally calls placed_obj:SetPos(x, y, InvalidZ) after
	-- SpawnDeposit returns. For the surface entrance sign, that base-class write can move the sign
	-- away from its final side anchor. Once the surface sign has a final anchor, preserve its exact
	-- XYZ. Underground SurfaceTunnelMarker signs bypass this wrapper unchanged.
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
			if IsUndergroundExitMarker(marker, sign) then
				return current_set_pos(sign, ...)
			end
			local x, y, z = EntranceBadgeAnchor(marker, sign)
			if type(x) == "number" and type(y) == "number" then
				local point_fn = Global("point")
				if type(point_fn) == "function" then
					local terrain_z = EntranceBadgeTerrainZ(marker, sign, x, y)
					if type(terrain_z) == "number" then z = terrain_z end
					WriteEntranceBadgeAnchor(marker, x, y, z)
					WriteEntranceBadgeAnchor(marker and marker.spawner, x, y, z)
					WriteEntranceBadgeAnchor(sign, x, y, z)
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
		-- A naturally revealed underground SurfaceTunnelMarker may already own its vanilla
		-- SignUnderground visual. It is not a surface badge and must bypass this transform too.
		if map.mapdata and map.mapdata.Environment == "Underground"
			and IsKindOfSafe(obj, "SurfaceUndergroundTunnelSign")
			and IsKindOfSafe(obj.tunnel_marker, "SurfaceTunnelMarker") then
			return
		end
		-- ATTACHED INDICATOR CHILDREN: the passage entity auto-attaches its build-indicator visuals
		-- (ElevatorBuildIndicator_SurfaceDecal on the surface passage,
		-- ElevatorBuildIndicator_UndergroundPassageImprint underground). An attached child's world
		-- position is its committed parent's, so it is ALREADY in the final domain -- and it still
		-- lies inside the source region, so the source-region guard below cannot catch it. Sweep 1
		-- reaches it anyway because IsUndergroundAccessObject matches it through its parent's class,
		-- and transforming it independently applied a SECOND full/source move: measured at
		-- 4/3 x its parent's committed pose (surface decal at (737333,438773) for the parent at
		-- (553000,329080)). Same rule the decoration pass applies (ScaleDecorationsToFull).
		if type(obj.GetParent) == "function" then
			local ok_parent, parent = pcall(obj.GetParent, obj)
			if ok_parent and type(parent) == "table" and parent ~= obj
				and parent.SuperBigMapCommittedPassageLocked == true then
				EntranceAudit("ENTRANCE_VISUAL_ATTACHED_CHILD_SKIPPED", {
					via = via,
					class = tostring(obj.class),
					entity = tostring(obj.entity),
					parent_class = tostring(parent.class),
				}, map)
				return
			end
		end
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
			else
				anchor = IsKindOfSafe(obj, "ElevatorBase") and obj.other or obj.linked_obj
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
	-- Vanilla may place the surface entrance marker away from the passage. Keep the gameplay marker
	-- untouched, but place its visible surface badge on the closest safe cell beside the passage
	-- footprint. Underground SignUnderground objects are detected and skipped below.
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
			-- This is vanilla's exploration-created SignUnderground object, not a surface
			-- entrance badge. Its lifecycle and position remain untouched.
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
			CaptureEntranceBadgePosition(marker, sign, "initial post-expansion passage anchor")
			EntranceAudit("ENTRANCE_BADGE_ANCHORED", {
				passage_x = px, passage_y = py,
				badge_x = badge_x, badge_y = badge_y,
				badge_q = side.q, badge_r = side.r,
				edge_distance = side.edge_distance,
				center_distance = side.center_distance,
			}, map)
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

	-- Diagnostics only, never a placement input: footprint_buildable stops at the FIRST hex that
	-- refuses a candidate, which names the rule but not the shape of the defect. This walks the
	-- same Elevator footprint without early exit and reports every hex's decision inputs, so a
	-- refused exact transform image can be attributed to terrain (unbuildable/uneven/slope) or to
	-- a clearable object. Only called when the gated Elevator channel is on.
	local function describe_footprint(map, q, r, angle, anchor)
		local buildable = map and map.buildable
		local ok_world, x, y = pcall(hex_to_world, q, r)
		if not buildable or type(buildable.GetZ) ~= "function" or not ok_world then
			return "footprint description unavailable"
		end
		local parts = {}
		local function describe_hex(hq, hr)
			local entry = tostring(hq) .. ":" .. tostring(hr)
			local ok_xy, hx, hy = pcall(hex_to_world, hq, hr)
			if not ok_xy or not map_point_in_bounds(map, hx, hy) then
				parts[#parts + 1] = entry .. "=outside"
				return true
			end
			local ok_z, z = pcall(buildable.GetZ, buildable, hq, hr)
			local z_text = "?"
			if ok_z and z ~= nil then
				z_text = z == unbuildable_z and "UNBUILDABLE" or tostring(z)
			end
			local hex_point = point_fn(hx, hy)
			local passable_text = "?"
			if type(terrain_api) == "table" and type(terrain_api.IsPassable) == "function" then
				local ok_passable, passable = pcall(terrain_api.IsPassable, map, hex_point)
				if ok_passable then passable_text = tostring(passable) end
			end
			local normal_text = "?"
			if type(terrain_api) == "table" and type(terrain_api.GetTerrainNormal) == "function" then
				local ok_normal, normal = pcall(terrain_api.GetTerrainNormal, map, hex_point)
				local normal_z = ok_normal and normal and type(normal.z) == "function"
					and SafeCall(normal.z, normal) or nil
				if type(normal_z) == "number" then normal_text = tostring(normal_z) end
			end
			local blockers, first_blocker = 0, nil
			local object_grid = map.object_hex_grid
			if object_grid and type(object_grid.GetBuildObstructions) == "function" then
				local ok_obstructions, obstructions = pcall(
					object_grid.GetBuildObstructions, object_grid, hq, hr)
				if ok_obstructions and type(obstructions) == "table" then
					for oi = 1, #obstructions do
						local obstruction = obstructions[oi]
						local follows_anchor = obstruction == anchor
							or (obstruction and (obstruction.passage == anchor
								or obstruction.other == anchor or obstruction.linked_obj == anchor
								or obstruction.SuperBigMapDeferredElevatorPassage == anchor
								or obstruction.spawner == anchor))
						if not follows_anchor then
							blockers = blockers + 1
							first_blocker = first_blocker or tostring(obstruction and obstruction.class)
						end
					end
				end
			end
			parts[#parts + 1] = entry .. "=z" .. z_text .. ",pass" .. passable_text
				.. ",nz" .. normal_text .. ",blk" .. tostring(blockers)
				.. (first_blocker and ("(" .. first_blocker .. ")") or "")
			return true
		end
		if elevator_shape and type(validate_shape) == "function" then
			pcall(validate_shape, elevator_shape, point_fn(x, y), angle or 0, describe_hex)
		else
			describe_hex(q, r)
		end
		return table.concat(parts, " ")
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

	-- A standalone action-FX carrier is a FREE map object: an ActionFXParticles preset without
	-- `Attach` (the stock `Revealed` FX Particles_1LtXWp8i is one) places its ParSystem at
	-- `actor pose + preset offset` with the actor's angle and never parents it to the actor, so
	-- nothing carries it when that actor is moved afterwards. Vanilla never moves an actor after
	-- its reveal FX is played; this planner does, which left two expanded surface carriers stranded
	-- ~8000 wu from entrance #1 while the entrance kept none (iteration 029 evidence:
	-- _ralph/runs/full-object-parity/artifacts/run_iter029_parsystem/parsystem_verdict.md).
	--
	-- Carry them with the object they sit on. Eligibility is deliberately narrow so nothing else
	-- can be displaced: a live PARENTLESS ParSystem with no source record in EITHER namespace (the
	-- mod's own stretched copies always carry one) sitting on exactly that object's pre-move XY.
	-- Collect into a Lua list first -- moving objects inside MapForEach is unsafe.
	local fx_carriers_moved = 0
	local fx_carrier_index_by_map = {}
	local function fx_carrier_key(x, y)
		return tostring(x) .. "," .. tostring(y)
	end
	local function finite_z(value)
		if type(value) ~= "number" then return nil end
		-- The engine's invalid-Z sentinel is max_int; only a real height may be offset.
		if value <= -1000000000 or value >= 1000000000 then return nil end
		return value
	end
	local function fx_carrier_bucket(by_xy, x, y)
		local key = fx_carrier_key(x, y)
		local list = by_xy[key]
		if not list then
			list = {}
			by_xy[key] = list
		end
		return list
	end
	local function build_fx_carrier_index(map)
		local by_xy = {}
		fx_carrier_index_by_map[map] = by_xy
		if not map or type(map.MapForEach) ~= "function" then return by_xy end
		local carriers = {}
		pcall(map.MapForEach, map, "map", "ParSystem", function(obj)
			carriers[#carriers + 1] = obj
		end)
		for i = 1, #carriers do
			local obj = carriers[i]
			if IsLiveGameObject(obj)
				and type(obj.SuperBigMapNativeSourceX) ~= "number"
				and type(obj.SuperBigMapProvenanceX) ~= "number"
				and (type(obj.GetParent) ~= "function" or SafeCall(obj.GetParent, obj) == nil) then
				local cx, cy = PointXY(ObjectPosition(obj))
				if type(cx) == "number" and type(cy) == "number" then
					local list = fx_carrier_bucket(by_xy, cx, cy)
					list[#list + 1] = obj
				end
			end
		end
		return by_xy
	end
	local function carry_fx_carriers(map, old_x, old_y, old_z, new_x, new_y, new_z)
		local by_xy = fx_carrier_index_by_map[map] or build_fx_carrier_index(map)
		local key = fx_carrier_key(old_x, old_y)
		local list = by_xy[key]
		if not list then return 0 end
		by_xy[key] = nil
		local moved = 0
		for i = 1, #list do
			local obj = list[i]
			local cx, cy, cz
			if IsLiveGameObject(obj) and type(obj.SetPos) == "function" then
				local pos = ObjectPosition(obj)
				cx, cy = PointXY(pos)
				cz = (pos and type(pos.z) == "function") and finite_z(SafeCall(pos.z, pos)) or nil
			end
			if type(cx) == "number" and type(cy) == "number" then
				local tx, ty = cx + (new_x - old_x), cy + (new_y - old_y)
				local destination
				if cz and old_z and new_z then
					-- Keep the preset's own vertical offset above the actor on the new terrain.
					destination = point_fn(tx, ty, new_z + (cz - old_z))
				else
					destination = point_fn(tx, ty)
					if type(destination.SetTerrainZ) == "function" then
						local ok_z, snapped = pcall(destination.SetTerrainZ, destination, map)
						if ok_z and snapped then destination = snapped end
					end
				end
				if pcall(obj.SetPos, obj, destination) then
					moved = moved + 1
					local dest = fx_carrier_bucket(by_xy, tx, ty)
					dest[#dest + 1] = obj
				end
			end
		end
		fx_carriers_moved = fx_carriers_moved + moved
		return moved
	end

	local function move_object(obj, map, x, y)
		if not IsLiveGameObject(obj) or type(obj.SetPos) ~= "function" then return false end
		local before_pos = ObjectPosition(obj)
		local before_x, before_y = PointXY(before_pos)
		local before_z = (before_pos and type(before_pos.z) == "function")
			and finite_z(SafeCall(before_pos.z, before_pos)) or nil
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
		if ok_set and type(before_x) == "number" and type(before_y) == "number" then
			local after_pos = ObjectPosition(obj)
			local after_x, after_y = PointXY(after_pos)
			local after_z = (after_pos and type(after_pos.z) == "function")
				and finite_z(SafeCall(after_pos.z, after_pos)) or nil
			if type(after_x) == "number" and type(after_y) == "number"
				and (after_x ~= before_x or after_y ~= before_y) then
				carry_fx_carriers(map, before_x, before_y, before_z, after_x, after_y, after_z)
			end
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

	-- Passage planning used to perform a complete CObject traversal for every endpoint of every
	-- linked pair. On an expanded surface that means four full object scans merely to discover the
	-- handful of indicator/site objects attached to two passages. Build one dependency index per map
	-- and retain the exact same per-pair move order. This changes neither the dependency predicates
	-- nor their destination coordinates; it only removes repeated enumeration.
	local dependency_anchors_by_map = {}
	local dependant_index_by_map = {}
	local dependant_scan_stats = { scans = 0, objects = 0, matches = 0 }
	local function build_dependant_index(map)
		local by_anchor = {}
		local anchors = dependency_anchors_by_map[map] or {}
		for i = 1, #anchors do by_anchor[anchors[i]] = {} end
		if map and type(map.MapForEach) == "function" and #anchors > 0 then
			dependant_scan_stats.scans = dependant_scan_stats.scans + 1
			pcall(map.MapForEach, map, "map", "CObject", function(obj)
				if not obj then return end
				dependant_scan_stats.objects = dependant_scan_stats.objects + 1
				for i = 1, #anchors do
					local anchor = anchors[i]
					if obj ~= anchor then
						local exact = (IsKindOfSafe(obj, "ElevatorBase") or is_elevator_site(obj))
							and (obj.passage == anchor or obj.other == anchor
								or obj.linked_obj == anchor
								or obj.SuperBigMapDeferredElevatorPassage == anchor)
						local relative = obj.spawner == anchor or obj.passage == anchor
							or (obj.tunnel_marker and obj.tunnel_marker.spawner == anchor)
						if exact or relative then
							local list = by_anchor[anchor]
							list[#list + 1] = { object = obj, exact = exact == true }
							dependant_scan_stats.matches = dependant_scan_stats.matches + 1
						end
					end
				end
			end)
		end
		dependant_index_by_map[map] = by_anchor
		return by_anchor
	end
	local function move_dependants(map, anchor, old_x, old_y, new_x, new_y)
		local moved = 0
		if not map or not anchor then return moved end
		local by_anchor = dependant_index_by_map[map] or build_dependant_index(map)
		local dependants = by_anchor and by_anchor[anchor] or nil
		for i = 1, #(dependants or {}) do
			local entry = dependants[i]
			local obj = entry.object
			local x, y = new_x, new_y
			if not entry.exact then
				local pos = ObjectPosition(obj)
				local ox, oy = PointXY(pos)
				if type(ox) == "number" and type(oy) == "number" then
					x, y = ox + (new_x - old_x), oy + (new_y - old_y)
				else
					obj = nil
				end
			end
			if obj and move_object(obj, map, x, y) then moved = moved + 1 end
		end
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
	for i = 1, #linked_pairs do
		local pair = linked_pairs[i]
		local underground_list = dependency_anchors_by_map[underground_map]
		if not underground_list then
			underground_list = {}
			dependency_anchors_by_map[underground_map] = underground_list
		end
		underground_list[#underground_list + 1] = pair.underground
		local surface_list = dependency_anchors_by_map[surface_map]
		if not surface_list then
			surface_list = {}
			dependency_anchors_by_map[surface_map] = surface_list
		end
		surface_list[#surface_list + 1] = pair.surface
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

	-- Inverse of `scaled_final_hex`, for validity queries only: which SOURCE hex does a final hex come
	-- from. The final surface commitment runs while the underground map still presents its UN-STRETCHED
	-- source content on the resized canvas (the underground stretch is a later pipeline step), so a
	-- candidate hex's underground validity has to be asked of its source pre-image. The stretch is a
	-- similarity transform, so the same hex-count Elevator footprint covers 1/scale LESS real area after
	-- the stretch than the pre-image query inspects: asking on the source grid is the conservative side.
	local function source_preimage_hex(final_q, final_r)
		if not scale_x or not scale_y or scale_x <= 0 or scale_y <= 0 then return nil end
		local ok_world, final_x, final_y = pcall(hex_to_world, final_q, final_r)
		if not ok_world or type(final_x) ~= "number" or type(final_y) ~= "number" then return nil end
		local ok_hex, source_q, source_r = pcall(world_to_hex, point_fn(
			math.floor(final_x / scale_x + 0.5), math.floor(final_y / scale_y + 0.5)))
		if not ok_hex or type(source_q) ~= "number" or type(source_r) ~= "number" then return nil end
		return source_q, source_r
	end

	local function stamp_plan(anchor, plan, endpoint_q, endpoint_r, endpoint_x, endpoint_y)
		anchor.SuperBigMapCommittedPassageLocked = true
		anchor.SuperBigMapCommittedPassageSourceQ = plan.source_q
		anchor.SuperBigMapCommittedPassageSourceR = plan.source_r
		anchor.SuperBigMapCommittedPassageSourceX = plan.source_x
		anchor.SuperBigMapCommittedPassageSourceY = plan.source_y
		-- The pair's single co-located hex, authoritative and immutable once the final surface
		-- commitment has chosen it. BOTH endpoints receive it: the surface endpoint as its committed
		-- coordinate and the underground endpoint as the destination its deferred final alignment
		-- moves to. Before that commitment it is still the image of the vanilla underground hex.
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
		-- CO-LOCATION INPUT: this pair's own vanilla SURFACE coordinate. The lightweight bootstrap is
		-- the only moment the surface endpoint still stands exactly where vanilla put it (it is
		-- committed into the expanded domain further down), so record its source hex once here and
		-- never overwrite it; the final surface commitment transforms it into the pair's natural hex.
		if source_bootstrap and not surface_final_commit
			and tonumber(surface_anchor.SuperBigMapPassageSurfaceSourceQ) == nil then
			local ok_surface_hex, vanilla_surface_q, vanilla_surface_r =
				pcall(world_to_hex, point_fn(sx, sy))
			if not ok_surface_hex or type(vanilla_surface_q) ~= "number"
				or type(vanilla_surface_r) ~= "number" then
				return false, { error = "vanilla surface passage hex unavailable", pairs = stats.pairs }
			end
			surface_anchor.SuperBigMapPassageSurfaceSourceQ = vanilla_surface_q
			surface_anchor.SuperBigMapPassageSurfaceSourceR = vanilla_surface_r
			surface_anchor.SuperBigMapPassageSurfaceSourceX = sx
			surface_anchor.SuperBigMapPassageSurfaceSourceY = sy
		end
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
			-- CO-LOCATION (task gate `entrance-colocation`): a linked pair must occupy the SAME hex on
			-- both maps. Vanilla only aspires to that -- SpawnUndergroundPassage snaps the surface pos,
			-- then FindPassageSpawnPos may reject candidates and after 12 attempts falls back to a random
			-- passable position anywhere on the map -- so this pair is co-located by construction. The
			-- natural hex is the hex-snapped stretched image of the endpoint's own VANILLA SURFACE
			-- coordinate, and the underground endpoint follows it instead of the image of its own vanilla
			-- hex: co-location takes precedence over exact-affine placement for these two classes.
			local surface_source_q = tonumber(surface_anchor.SuperBigMapPassageSurfaceSourceQ)
			local surface_source_r = tonumber(surface_anchor.SuperBigMapPassageSurfaceSourceR)
			if type(surface_source_q) ~= "number" or type(surface_source_r) ~= "number" then
				return false, { error = "vanilla surface passage source hex unavailable",
					pairs = stats.pairs }
			end
			local natural = scaled_final_hex(surface_source_q, surface_source_r)
			if not natural then
				return false, { error = "vanilla surface passage transform unavailable",
					pairs = stats.pairs }
			end
			-- A candidate is acceptable only when the complete Elevator footprint is valid on BOTH maps:
			-- the surface in its final stretched form, the underground through the candidate's source
			-- pre-image. Both use the engine's own predicates; nothing is sculpted to make a hex fit.
			local surface_rejections, underground_rejections = {}, {}
			local natural_hex_surface_reason, natural_hex_underground_reason
			local underground_verdicts = {}
			local function underground_candidate(q, r)
				local pre_q, pre_r = source_preimage_hex(q, r)
				if pre_q == nil then return false, "underground pre-image hex unavailable" end
				local key = tostring(pre_q) .. ":" .. tostring(pre_r)
				local verdict = underground_verdicts[key]
				if verdict == nil then
					-- Adjacent final hexes share a pre-image at this scale; validate each source hex once.
					local valid, reason = footprint_buildable(
						underground_map, pre_q, pre_r, underground_angle, underground_anchor)
					verdict = { valid = valid == true, reason = reason, q = pre_q, r = pre_r }
					underground_verdicts[key] = verdict
				end
				return verdict.valid, verdict.reason, verdict.q, verdict.r
			end
			local function shared_candidate(q, r)
				stats.checked = stats.checked + 1
				local natural_hex = q == natural.final_q and r == natural.final_r
				local surface_valid, surface_reason = footprint_buildable(
					surface_map, q, r, surface_angle, surface_anchor)
				if not surface_valid then
					local key = "surface " .. tostring(surface_reason)
					surface_rejections[key] = (surface_rejections[key] or 0) + 1
					if natural_hex then natural_hex_surface_reason = tostring(surface_reason) end
					return false
				end
				local underground_valid, underground_reason = underground_candidate(q, r)
				if not underground_valid then
					local key = "underground " .. tostring(underground_reason)
					underground_rejections[key] = (underground_rejections[key] or 0) + 1
					if natural_hex then natural_hex_underground_reason = tostring(underground_reason) end
					return false
				end
				return true
			end
			local natural_underground_valid, natural_underground_reason,
				natural_preimage_q, natural_preimage_r =
					underground_candidate(natural.final_q, natural.final_r)
			surface_q, surface_r = natural.final_q, natural.final_r
			surface_x, surface_y = natural.final_x, natural.final_y
			search_algorithm = "stretched image of the vanilla surface hex, valid on both maps"
			if not shared_candidate(surface_q, surface_r) then
				-- Nearest-first ring search: the FIRST hex accepted on both maps is by construction the
				-- minimum-distance relocation, and both endpoints move to it TOGETHER.
				surface_q, surface_r, surface_radius = nearest_on_hex_rings(
					natural.final_q, natural.final_r, shared_candidate, 1,
					math.max(tonumber(surface_map.hex_width) or 0,
						tonumber(surface_map.hex_height) or 0))
				if surface_q == nil then
					return false, { error = "no hex valid on both maps near the stretched surface image",
						pairs = stats.pairs, checked = stats.checked }
				end
				local ok_shared_world
				ok_shared_world, surface_x, surface_y = pcall(hex_to_world, surface_q, surface_r)
				if not ok_shared_world then
					return false, { error = "co-located hex world coordinate unavailable",
						pairs = stats.pairs }
				end
				search_algorithm = "nearest hex valid on both maps to the stretched surface image"
				local rejection_summary = {}
				for reason, count in pairs(surface_rejections) do
					rejection_summary[#rejection_summary + 1] = reason .. " x" .. tostring(count)
				end
				for reason, count in pairs(underground_rejections) do
					rejection_summary[#rejection_summary + 1] = reason .. " x" .. tostring(count)
				end
				table.sort(rejection_summary)
				EntranceAudit("PASSAGE_PLAN_SURFACE_EXACT_REJECTED", {
					pair = i,
					exact_q = natural.final_q, exact_r = natural.final_r,
					exact_x = natural.final_x, exact_y = natural.final_y,
					exact_reason = natural_hex_surface_reason or natural_hex_underground_reason,
					exact_surface_reason = natural_hex_surface_reason,
					exact_underground_reason = natural_hex_underground_reason,
					committed_q = surface_q, committed_r = surface_r,
					committed_x = surface_x, committed_y = surface_y,
					committed_radius = surface_radius,
					delta_x = surface_x - natural.final_x, delta_y = surface_y - natural.final_y,
					surface_angle = surface_angle,
					candidates_rejected = table.concat(rejection_summary, "; "),
					exact_footprint = EntranceAuditEnabled()
						and describe_footprint(surface_map, natural.final_q, natural.final_r,
							surface_angle, surface_anchor) or nil,
					committed_footprint = EntranceAuditEnabled()
						and describe_footprint(surface_map, surface_q, surface_r,
							surface_angle, surface_anchor) or nil,
					exact_underground_footprint = EntranceAuditEnabled() and natural_preimage_q
						and describe_footprint(underground_map, natural_preimage_q, natural_preimage_r,
							underground_angle, underground_anchor) or nil,
				}, underground_map)
			end
			local _, committed_underground_reason, committed_preimage_q, committed_preimage_r =
				underground_candidate(surface_q, surface_r)
			local drift_x, drift_y = surface_x - natural.final_x, surface_y - natural.final_y
			local drift_dq, drift_dr = surface_q - natural.final_q, surface_r - natural.final_r
			-- Informational only, never a placement input: whether the underground map already accepts
			-- the FINAL hex proves which form its terrain is in while this commitment runs.
			local underground_final_hex_valid, underground_final_hex_reason = footprint_buildable(
				underground_map, surface_q, surface_r, underground_angle, underground_anchor)
			EntranceAudit("PASSAGE_PLAN_COLOCATED", {
				pair = i,
				algorithm = search_algorithm,
				radius = surface_radius,
				vanilla_surface_q = surface_source_q, vanilla_surface_r = surface_source_r,
				vanilla_surface_x = natural.source_x, vanilla_surface_y = natural.source_y,
				vanilla_underground_x = plan.source_x, vanilla_underground_y = plan.source_y,
				natural_q = natural.final_q, natural_r = natural.final_r,
				natural_x = natural.final_x, natural_y = natural.final_y,
				natural_surface_reason = natural_hex_surface_reason,
				natural_underground_valid = natural_underground_valid,
				natural_underground_reason = natural_underground_reason,
				natural_preimage_q = natural_preimage_q, natural_preimage_r = natural_preimage_r,
				shared_q = surface_q, shared_r = surface_r,
				shared_x = surface_x, shared_y = surface_y,
				shared_preimage_q = committed_preimage_q, shared_preimage_r = committed_preimage_r,
				shared_preimage_reason = committed_underground_reason,
				drift_x = drift_x, drift_y = drift_y,
				drift_wu = math.floor(math.sqrt(drift_x * drift_x + drift_y * drift_y) + 0.5),
				drift_hexes = math.max(math.abs(drift_dq), math.abs(drift_dr),
					math.abs(drift_dq + drift_dr)),
				image_of_vanilla_underground_q = plan.final_q,
				image_of_vanilla_underground_r = plan.final_r,
				underground_final_hex_valid = underground_final_hex_valid,
				underground_final_hex_reason = underground_final_hex_reason,
				candidates_checked = stats.checked,
			}, underground_map)
			-- One hex for the pair: the underground endpoint's deferred final destination becomes the
			-- co-located hex, so both stamps below carry identical coordinates.
			plan.final_q, plan.final_r = surface_q, surface_r
			plan.final_x, plan.final_y = surface_x, surface_y
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
		elseif not source_bootstrap then
			-- The final surface endpoint was already selected, moved, validated, and prepared by the
			-- surface-final commitment pass. Deferred underground construction neither moves nor edits
			-- that terrain (the coordinate checks above still reject drift). Re-running a placement
			-- validator now can only add false blockers from the live Elevator and its companion objects
			-- that legitimately occupy the committed footprint.
			surface_post_valid = true
			surface_post_reason = "immutable final surface commitment already validated"
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
			local prepared_surface_valid, prepared_surface_reason
			if prepare_surface then
				prepared_surface_valid, prepared_surface_reason = footprint_buildable(
					surface_map, surface_q, surface_r, surface_angle, surface_anchor)
			else
				-- Preparing only the underground endpoint cannot invalidate the already-committed
				-- surface terrain. Its live Elevator occupancy is not a placement failure.
				prepared_surface_valid = true
				prepared_surface_reason = "immutable final surface commitment unchanged"
			end
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
	stats.dependant_map_scans = dependant_scan_stats.scans
	stats.dependant_objects_scanned = dependant_scan_stats.objects
	stats.dependant_matches = dependant_scan_stats.matches
	stats.moved_fx_carriers = fx_carriers_moved
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
	PatchCaveInShapePoints = PatchCaveInShapePoints,
	RestoreCaveInShapePointsPatch = RestoreCaveInShapePointsPatch,
	PatchUndergroundWonderShapePoints = PatchUndergroundWonderShapePoints,
	RestoreUndergroundWonderShapePointsPatch = RestoreUndergroundWonderShapePointsPatch,
	ScaleHexShapeForExpansion = ScaleCaveInHexShape,
	BeginDeferredElevatorMigration = BeginDeferredElevatorMigration,
	RestoreDeferredElevatorMigration = RestoreDeferredElevatorMigration,
	AnnotateDecorRelief = AnnotateDecorRelief,
	ClearDecorRelief = ClearDecorRelief,
}
SuperBigMap.TerrainCopy = TerrainCopy

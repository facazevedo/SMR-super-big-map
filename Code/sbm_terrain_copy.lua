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

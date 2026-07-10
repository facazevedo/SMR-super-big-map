-- Super Big Map -- 20x20 frame map expansion.
--
-- For eligible random Surface maps this allocates an 8192-tile terrain, has the
-- random map generator produce the native source terrain, then fills the added
-- L-shaped frame by mirroring source edge blocks. The RandomMapGenerator.Generate/
-- DoGenerate hook and the frame-fill pass share pending-map state, so they live
-- together here.
--
-- Generic engine helpers come from sbm_engine. This module keeps ONLY a gen-time
-- TerrainSize and the infinite-loop-pause guard local, because their behavior is
-- context-specific to map generation -- e.g. DoGenerate temporarily overrides
-- terrain.GetMapSize so the generator only fills the source quadrant, and the gen-time
-- size must read mapdata.Width x HeightTileSize (assert-free), not map:GetMapSize.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local GENERATOR_PATCH_VERSION = SuperBigMap.GENERATOR_PATCH_VERSION or 2

-- Pending/blocked per-map state shared across this module's hooks (kept in the
-- shared State table rather than _G globals).
SuperBigMap.State = SuperBigMap.State or {}
SuperBigMap.State.quadrant_pending_maps = SuperBigMap.State.quadrant_pending_maps or {}
SuperBigMap.State.quadrant_blocked_maps = SuperBigMap.State.quadrant_blocked_maps or {}
local pending_maps = SuperBigMap.State.quadrant_pending_maps
local blocked_maps = SuperBigMap.State.quadrant_blocked_maps

-- Generic engine helpers from sbm_engine (loaded before this module). Aliased to locals
-- so existing call sites are unchanged; only the gen-time TerrainSize below stays local.
local Engine = SuperBigMap.Engine
local Global = Engine.Global
local TryCall = Engine.TryCall
local SafeCall = Engine.SafeCall
local Unpack = Engine.Unpack

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

local function cfg_string(key, default)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "string" and value ~= "" then
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

-- Per-step trace for the STRETCH frame-fill orchestration (gated on Config.DEBUG_STRETCH).
-- Pairs with the same-scope logging in sbm_terrain_copy so the whole path is traceable end to
-- end when diagnosing a stuck-at-loading. Temporary diagnostic scope; only the flag is flipped.
local function StretchLog(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Stretch", message, data)
	end
end

-- Per-object generation spam routes to its own scope so DEBUG_GENERATION stays readable;
-- enable DEBUG_GENERATIONVERBOSE (or the master) to see it.
local function VerbosePrint(text)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("GenerationVerbose", text)
	end
end

-- Init-sequence trace (gated on Config.DEBUG_INIT_SEQUENCE via DebugLog.InitSeq).
local function InitSeq(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog and type(DebugLog.InitSeq) == "function" then
		DebugLog.InitSeq(message, data)
	end
end

local function RunWithInfiniteLoopPause(reason, fn, ...)
	local pause = Global("PauseInfiniteLoopDetection")
	local resume = Global("ResumeInfiniteLoopDetection")
	if type(pause) == "function" then
		SafeCall(pause, reason)
	end

	local results = { pcall(fn, ...) }

	if type(resume) == "function" then
		SafeCall(resume, reason)
	end

	if not results[1] then
		error(results[2])
	end
	return Unpack(results, 2)
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

local IsKindOfSafe = Engine.IsKindOf
local ObjectPosition = Engine.ObjectPos

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


-- Terrain/grid copy + object cloning live in sbm_terrain_copy / sbm_object_clone,
-- loaded before this module. Bind the helpers called below (and re-exported through
-- MapGeneration for the lifecycle) to their original local names; assert presence so
-- a load-order mistake fails LOUDLY at startup, not as a deferred nil-call in gen.
local TerrainCopy = SuperBigMap.TerrainCopy
assert(type(TerrainCopy) == "table",
	"sbm_map_generation: SuperBigMap.TerrainCopy missing -- load sbm_terrain_copy before this file")
local SECTOR_MIRROR_BLOCKS = TerrainCopy.SECTOR_MIRROR_BLOCKS
local SectorBoundary = TerrainCopy.SectorBoundary
local FindSectorByName = TerrainCopy.FindSectorByName
local SectorMirrorBlocksFit = TerrainCopy.SectorMirrorBlocksFit
local CopySectorBlock = TerrainCopy.CopySectorBlock
local FrameSectorProbe = TerrainCopy.FrameSectorProbe
local WarnCannotExpand = TerrainCopy.WarnCannotExpand
local ForceFramePassable = TerrainCopy.ForceFramePassable
local ReinvalidateExpandedTerrain = TerrainCopy.ReinvalidateExpandedTerrain
local RemoveFrameUndergroundAccess = TerrainCopy.RemoveFrameUndergroundAccess
local StretchSourceToFull = TerrainCopy.StretchSourceToFull
local StretchBiomeReady = TerrainCopy.StretchBiomeReady
local ScaleDecorationsToFull = TerrainCopy.ScaleDecorationsToFull
local ScaleMarkersToFull = TerrainCopy.ScaleMarkersToFull
local StretchRelocateStartSector = TerrainCopy.StretchRelocateStartSector
local MoveEntranceVisualsToScale = TerrainCopy.MoveEntranceVisualsToScale
local AuditFloatingObjects = TerrainCopy.AuditFloatingObjects
assert(type(SECTOR_MIRROR_BLOCKS) == "table" and type(CopySectorBlock) == "function"
	and type(SectorMirrorBlocksFit) == "function" and type(ForceFramePassable) == "function"
	and type(ReinvalidateExpandedTerrain) == "function" and type(RemoveFrameUndergroundAccess) == "function"
	and type(SectorBoundary) == "function" and type(FindSectorByName) == "function"
	and type(FrameSectorProbe) == "function" and type(WarnCannotExpand) == "function",
	"sbm_map_generation: required TerrainCopy helpers missing (check sbm_terrain_copy exports)")

local function StorePendingMap(map_name, pending)
	if map_name and map_name ~= "" then
		pending_maps[map_name] = pending
	end
end

local function ClearPendingMap(map_name)
	if map_name and map_name ~= "" then
		pending_maps[map_name] = nil
	end
end

local function ShouldExpandNewMap()
	local toggle = SuperBigMap.PregameToggle
	if toggle and type(toggle.ShouldExpandNewMap) == "function" then
		local ok, result = pcall(toggle.ShouldExpandNewMap)
		return ok and result == true
	end
	return false
end

local function ClearPreparedMapInstance(map)
	if type(map) ~= "table" then
		return false
	end
	map.SuperBigMapQuadrantCopyPending = nil
	map.SuperBigMapSourceWidth = nil
	map.SuperBigMapSourceHeight = nil
	map.SuperBigMapSourceX = nil
	map.SuperBigMapSourceY = nil
	map.SuperBigMapOriginalWidthTiles = nil
	map.SuperBigMapOriginalHeightTiles = nil
	map.SuperBigMapSourceWidthTiles = nil
	map.SuperBigMapSourceHeightTiles = nil
	map.SuperBigMapDesiredWidthTiles = nil
	map.SuperBigMapDesiredHeightTiles = nil
	map.SuperBigMapGeneratorWidth = nil
	map.SuperBigMapGeneratorHeight = nil
	map.SuperBigMapGeneratorWidthTiles = nil
	map.SuperBigMapGeneratorHeightTiles = nil
	return true
end

local function RestorePreparedMapData(map_name, mapdata)
	if type(mapdata) ~= "table" then
		return false
	end
	local original_width = mapdata.SuperBigMapOriginalWidthTiles
	local original_height = mapdata.SuperBigMapOriginalHeightTiles
	if type(original_width) == "number" and original_width > 0 then
		mapdata.Width = original_width
	end
	if type(original_height) == "number" and original_height > 0 then
		mapdata.Height = original_height
	end
	if mapdata.SuperBigMapOriginalPassBorder ~= nil then
		mapdata.PassBorder = mapdata.SuperBigMapOriginalPassBorder
		local const_tbl = Global("const")
		local tile = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number" and const_tbl.HeightTileSize > 0)
			and const_tbl.HeightTileSize or 100
		if type(mapdata.PassBorderTiles) == "number" then
			mapdata.PassBorderTiles = math.floor((mapdata.PassBorder or 0) / tile)
		end
	end
	mapdata.SuperBigMapOriginalWidthTiles = nil
	mapdata.SuperBigMapOriginalHeightTiles = nil
	mapdata.SuperBigMapQuadrantCopyScale = nil
	mapdata.SuperBigMapQuadrantSourceWidthTiles = nil
	mapdata.SuperBigMapQuadrantSourceHeightTiles = nil
	mapdata.SuperBigMapOriginalPassBorder = nil
	ClearPendingMap(map_name)
	return true
end

local function AlignDown(value, step)
	step = type(step) == "number" and step > 0 and step or 1
	return math.floor(value / step) * step
end

local function AttachPendingMapState(map)
	if not map then
		return false
	end

	local pending = pending_maps[map.name or false]
	if not pending then
		return false
	end

	map.SuperBigMapQuadrantCopyPending = true
	map.SuperBigMapSourceWidth = pending.source_width
	map.SuperBigMapSourceHeight = pending.source_height
	map.SuperBigMapSourceX = pending.source_x or 0
	map.SuperBigMapSourceY = pending.source_y or 0
	map.SuperBigMapOriginalWidthTiles = pending.original_width
	map.SuperBigMapOriginalHeightTiles = pending.original_height
	map.SuperBigMapSourceWidthTiles = pending.source_width_tiles
	map.SuperBigMapSourceHeightTiles = pending.source_height_tiles
	map.SuperBigMapDesiredWidthTiles = pending.desired_width
	map.SuperBigMapDesiredHeightTiles = pending.desired_height
	map.SuperBigMapGeneratorWidth = pending.generator_width
	map.SuperBigMapGeneratorHeight = pending.generator_height
	map.SuperBigMapGeneratorWidthTiles = pending.generator_width_tiles
	map.SuperBigMapGeneratorHeightTiles = pending.generator_height_tiles

	VerbosePrint(string.format(
		"attached pending 2x2 quadrant copy to %s (source %s x %s world, %s x %s tiles)",
		tostring(map.name),
		tostring(pending.source_width),
		tostring(pending.source_height),
		tostring(pending.source_width_tiles),
		tostring(pending.source_height_tiles)
	))
	return true
end

local function IsEligibleMapData(map_slot, mapdata, map_instance)
	if not cfg_bool("ENABLE_QUADRANT_MAP_COPY", false) then
		return false, "feature disabled"
	end

	-- Underground expansion (config STRETCH_UNDERGROUND): the underground map generates in its
	-- own slot with Environment=="Underground"; when the flag is on it is exempt from the
	-- main-slot-only and surface-only gates, so it gets the same 8192 allocation + native-capped
	-- generator as the surface (its stretch then applies the identical transform).
	local underground_ok = cfg_bool("STRETCH_UNDERGROUND", false)
		and type(mapdata) == "table" and mapdata.Environment == "Underground"

	if cfg_bool("QUADRANT_MAIN_MAP_ONLY", true) and map_slot ~= 1 and not underground_ok then
		return false, "not the main map slot"
	end

	if cfg_bool("QUADRANT_RANDOM_MAPS_ONLY", true) and not (map_instance and map_instance.RandomMapGenObject) then
		return false, "not a random map generation"
	end

	if type(mapdata) ~= "table" or mapdata.NoTerrain then
		return false, "missing terrain mapdata"
	end

	if cfg_bool("QUADRANT_SURFACE_ONLY", true) and mapdata.Environment ~= "Surface" and not underground_ok then
		return false, "not a surface map"
	end

	if type(mapdata.Width) ~= "number" or type(mapdata.Height) ~= "number" or mapdata.Width <= 0 or mapdata.Height <= 0 then
		return false, "invalid map dimensions"
	end

	if mapdata.Width ~= mapdata.Height then
		return false, "map is not square"
	end

	return true
end

local function PrepareMapDataForQuadrantCopy(map_slot, map_name, map_instance, source)
	map_instance = type(map_instance) == "table" and map_instance or {}
	local mapdata = map_instance.mapdata
	local map_data_table = Global("MapData")
	if not mapdata and type(map_data_table) == "table" then
		mapdata = map_data_table[map_name or false]
		map_instance.mapdata = mapdata
	end

	if not ShouldExpandNewMap() then
		RestorePreparedMapData(map_name, mapdata)
		ClearPreparedMapInstance(map_instance)
		VerbosePrint(string.format(
			"quadrant prepare skipped for %s via %s: EXPAND MAP toggle is off",
			tostring(map_name),
			tostring(source or "ChangingMap")
		))
		return false
	end

	local ok, reason = IsEligibleMapData(map_slot, mapdata, map_instance)
	if not ok then
		VerbosePrint(string.format(
			"quadrant prepare skipped for %s via %s: %s",
			tostring(map_name),
			tostring(source or "ChangingMap"),
			tostring(reason)
		))
		return false
	end

	local scale = math.floor(cfg_number("QUADRANT_COPY_SCALE", 2, 2))
	if scale ~= 2 then
		scale = 2
	end

	local original_width = mapdata.SuperBigMapOriginalWidthTiles or mapdata.Width
	local original_height = mapdata.SuperBigMapOriginalHeightTiles or mapdata.Height
	local requested_width = original_width * scale
	local requested_height = original_height * scale
	local max_terrain_tiles = math.floor(cfg_number("QUADRANT_MAX_TERRAIN_TILES", 8192, 1))
	local max_random_tiles = math.floor(cfg_number("QUADRANT_MAX_RANDOM_GENERATOR_TILES", 6144, 1))
	local renderer_align = math.floor(cfg_number("QUADRANT_RENDERER_NODE_TILE_ALIGNMENT", 2048, 1))
	local max_tiles = math.min(max_terrain_tiles, max_random_tiles)
	local desired_width = AlignDown(math.min(requested_width, max_tiles), renderer_align)
	local desired_height = AlignDown(math.min(requested_height, max_tiles), renderer_align)
	desired_width = AlignDown(desired_width, scale)
	desired_height = AlignDown(desired_height, scale)
	local source_width_tiles = original_width
	local source_height_tiles = original_height
	local generator_width_tiles = false
	local generator_height_tiles = false
	local height_tile_size = Global("const") and const.HeightTileSize or 1

	local frame_mode = cfg_bool("EXPANSION_FRAME_MODE", false)

	if frame_mode then
		-- FRAME EXPANSION: keep the FULL native map as the original. The
		-- generator runs ONCE at the native size (original_width, e.g. 6144 =
		-- 15x15 sectors) and fills the map from the origin. We allocate a larger
		-- mapdata (forced expanded tiles, e.g. 8192 = 20x20) so a flat
		-- L-shaped frame of new sectors surrounds the original. Nothing is
		-- cloned or duplicated -- generator source == full original; the frame
		-- (beyond original_width) stays at the engine's default flat height +
		-- texture. The 2x2 source-cap math below is intentionally skipped.
		local forced_tiles = math.floor(cfg_number("QUADRANT_FORCE_EXPANDED_TILES", 8192, 1))
		desired_width = AlignDown(math.min(forced_tiles, max_terrain_tiles), renderer_align)
		desired_height = AlignDown(math.min(forced_tiles, max_terrain_tiles), renderer_align)
		generator_width_tiles = original_width
		generator_height_tiles = original_height
		source_width_tiles = original_width
		source_height_tiles = original_height
		DebugPrint(string.format(
			"frame expansion for %s: mapdata %s x %s tiles, full native original %s x %s tiles, flat L-frame around it",
			tostring(map_name),
			tostring(desired_width),
			tostring(desired_height),
			tostring(original_width),
			tostring(original_height)
		))
	end

	if desired_width <= original_width or desired_height <= original_height then
		mapdata.Width = original_width
		mapdata.Height = original_height
		pending_maps[map_name or false] = nil
		if not blocked_maps[map_name or false] then
			blocked_maps[map_name or false] = true
			DebugPrint(string.format(
				"native terrain cap prevents true expansion of %s (%s x %s tiles); leaving map size unchanged",
				tostring(map_name),
				tostring(original_width),
				tostring(original_height)
			))
		end
		return false
	end

	-- 2x2 source cap: only applies to the tiling hack, NOT frame mode (frame
	-- mode deliberately keeps source == full native original).
	if not frame_mode and (desired_width < requested_width or desired_height < requested_height) then
		source_width_tiles = math.floor(desired_width / scale)
		source_height_tiles = math.floor(desired_height / scale)
		DebugPrint(string.format(
			"mapgen cap applied for %s: requested %s x %s tiles, using %s x %s tiles with %s x %s source quadrants",
			tostring(map_name),
			tostring(requested_width),
			tostring(requested_height),
			tostring(desired_width),
			tostring(desired_height),
			tostring(source_width_tiles),
			tostring(source_height_tiles)
		))
	end

	if source_width_tiles <= 0 or source_height_tiles <= 0 then
		DebugPrint("quadrant prepare failed: source quadrant would be empty")
		return false
	end

	mapdata.SuperBigMapOriginalWidthTiles = original_width
	mapdata.SuperBigMapOriginalHeightTiles = original_height
	mapdata.SuperBigMapQuadrantCopyScale = scale
	mapdata.SuperBigMapQuadrantSourceWidthTiles = source_width_tiles
	mapdata.SuperBigMapQuadrantSourceHeightTiles = source_height_tiles
	mapdata.Width = desired_width
	mapdata.Height = desired_height

	-- The engine bakes a symmetric impassable border of mapdata.PassBorder into
	-- the passability grid at map-build time (the property help reads "requires a
	-- map restart to take effect"). On the expanded map that leaves a thick
	-- impassable ring around the whole playable area -- the entire L-shaped frame
	-- edge -- which traps rovers (e.g. one unloaded from a rocket that landed in
	-- the frame; confirmed via a passability grid-scan: OriginalPassBorder=102400
	-- == a 1024-tile ring). FullMapPlayable wants the WHOLE expanded map passable,
	-- so zero PassBorder HERE, before generation builds passability, so no border
	-- is baked. The true original is preserved for restore (sbm_map_bounds's
	-- ResetMapDataBounds only captures SuperBigMapOriginalPassBorder when it is nil).
	-- Zero PassBorder so the WHOLE expanded map (incl. the non-rendered L-frame) is
	-- passable -- otherwise the engine bakes a ~1024-tile impassable ring and a rover
	-- unloaded from a rocket that landed near the edge/frame is trapped. The engine's
	-- gameplay grids (heat, etc.) only cover [HeatGridBorder, size-HeatGridBorder], but we
	-- keep the map passable and instead CLAMP the heat query (sbm_heat_safety) so units in
	-- the outer strip don't crash Heat_Get. EXPANDED_MAP_EDGE_BORDER can set a positive
	-- impassable ring instead (rounded UP to a const.MapPatchSize multiple, required by the
	-- engine: l_EngineChangeMap asserts nPassBorder % MAP_PATCH == 0). 0 is always valid.
	do
		local const_tbl = Global("const")
		local patch = (type(const_tbl) == "table" and type(const_tbl.MapPatchSize) == "number" and const_tbl.MapPatchSize > 0)
			and const_tbl.MapPatchSize or nil
		local override = cfg_number("EXPANDED_MAP_EDGE_BORDER", -1)
		local want = (override > 0) and math.floor(override) or 0
		local safe_border = 0
		if want > 0 and patch then
			safe_border = math.floor((want + patch - 1) / patch) * patch -- round UP to a MapPatchSize multiple
		end
		local tile = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number" and const_tbl.HeightTileSize > 0)
			and const_tbl.HeightTileSize or 100
		if type(mapdata.PassBorder) == "number" and mapdata.PassBorder ~= safe_border then
			if mapdata.SuperBigMapOriginalPassBorder == nil then
				mapdata.SuperBigMapOriginalPassBorder = mapdata.PassBorder
			end
			DebugPrint(string.format(
				"frame expansion: PassBorder %s -> %s (full passability; heat queries clamped)",
				tostring(mapdata.PassBorder), tostring(safe_border)))
			mapdata.PassBorder = safe_border
			if type(mapdata.PassBorderTiles) == "number" then
				mapdata.PassBorderTiles = (tile > 0) and math.floor(safe_border / tile) or 0
			end
		end
	end

	-- The rendered original is always corner-anchored at (0,0); the flat frame is
	-- the L on the two far sides. The source origin is therefore always 0,0 (kept
	-- as explicit fields so the shape-agnostic frame-crater detection in
	-- sbm_fake_terrain keeps reading a defined origin).
	local source_x, source_y = 0, 0

	local pending = {
		source_width = source_width_tiles * height_tile_size,
		source_height = source_height_tiles * height_tile_size,
		source_x = source_x,
		source_y = source_y,
		generator_width = (generator_width_tiles or source_width_tiles) * height_tile_size,
		generator_height = (generator_height_tiles or source_height_tiles) * height_tile_size,
		original_width = original_width,
		original_height = original_height,
		source_width_tiles = source_width_tiles,
		source_height_tiles = source_height_tiles,
		generator_width_tiles = generator_width_tiles or source_width_tiles,
		generator_height_tiles = generator_height_tiles or source_height_tiles,
		desired_width = desired_width,
		desired_height = desired_height,
	}
	StorePendingMap(map_name, pending)

	map_instance.SuperBigMapQuadrantCopyPending = true
	map_instance.SuperBigMapSourceWidth = pending.source_width
	map_instance.SuperBigMapSourceHeight = pending.source_height
	map_instance.SuperBigMapSourceX = source_x
	map_instance.SuperBigMapSourceY = source_y
	map_instance.SuperBigMapOriginalWidthTiles = original_width
	map_instance.SuperBigMapOriginalHeightTiles = original_height
	map_instance.SuperBigMapSourceWidthTiles = source_width_tiles
	map_instance.SuperBigMapSourceHeightTiles = source_height_tiles
	map_instance.SuperBigMapDesiredWidthTiles = desired_width
	map_instance.SuperBigMapDesiredHeightTiles = desired_height
	map_instance.SuperBigMapGeneratorWidth = pending.generator_width
	map_instance.SuperBigMapGeneratorHeight = pending.generator_height
	map_instance.SuperBigMapGeneratorWidthTiles = pending.generator_width_tiles
	map_instance.SuperBigMapGeneratorHeightTiles = pending.generator_height_tiles

	DebugPrint(string.format(
		"prepared %s for 2x2 quadrant copy via %s (%s x %s tiles -> %s x %s tiles; source %s x %s tiles)",
		tostring(map_name),
		tostring(source or "ChangingMap"),
		tostring(original_width),
		tostring(original_height),
		tostring(desired_width),
		tostring(desired_height),
		tostring(source_width_tiles),
		tostring(source_height_tiles)
	))
	return true
end

-- Finalize an expanded map after generation (NOT a 2x2 tiler despite the legacy
-- "quadrant" markers): attach the pending source/generator markers, settle the engine,
-- and re-apply bounds/sectors. The frame is filled by the sector-mirror plan.
local function FinalizeExpandedMap(map)
	if map and not map.SuperBigMapQuadrantCopyPending then
		AttachPendingMapState(map)
	end

	if not map or not map.SuperBigMapQuadrantCopyPending then
		VerbosePrint("quadrant tile skipped: no pending expanded map")
		return false
	end

	local map_width, map_height = TerrainSize(map)
	local source_width = map.SuperBigMapSourceWidth or math.floor((map_width or 0) / 2)
	local source_height = map.SuperBigMapSourceHeight or math.floor((map_height or 0) / 2)
	if not map_width or not map_height or source_width <= 0 or source_height <= 0 then
		DebugPrint("quadrant tile failed: invalid terrain/source size")
		return false
	end
	if map_width <= source_width or map_height <= source_height then
		DebugPrint(string.format(
			"quadrant tile skipped: map was not expanded before load (%s x %s, source %s x %s)",
			tostring(map_width),
			tostring(map_height),
			tostring(source_width),
			tostring(source_height)
		))
		return false
	end

	-- Settle the engine after the generator produced the source quadrant: refresh the
	-- terrain hash + max object radius, re-apply the full-map bounds/sector fit, and clear
	-- the pending flag. The non-rendered L-frame is filled separately by the sector-mirror
	-- plan (RunSectorMirrorPlanIfEnabled); nothing is tiled here.
	local terrain_api = Global("terrain")
	if terrain_api and type(terrain_api.HashGrids) == "function" and map.mapdata then
		map.mapdata.terrain_hash = SafeCall(terrain_api.HashGrids, map) or map.mapdata.terrain_hash
	end

	local update_radius = Global("UpdateMapMaxObjRadius")
	if type(update_radius) == "function" then
		SafeCall(update_radius, map)
	end

	local apply_bounds = (SuperBigMap.Lifecycle and SuperBigMap.Lifecycle.Apply) or Global("SuperBigMap_Apply")
	if type(apply_bounds) == "function" then
		SafeCall(apply_bounds, map, true)
	end

	map.SuperBigMapQuadrantCopyPending = false
	pending_maps[map.name or false] = nil
	DebugPrint(string.format("expanded map finalized: %s (%s x %s)",
		tostring(map.name), tostring(map_width), tostring(map_height)))

	return true
end

local function PrintQuadrantDebug()
	local current_map = Global("CurrentMap")
	local map_width, map_height = TerrainSize(current_map)
	local mapdata = current_map and current_map.mapdata
	local get_map_name = Global("GetMapName")
	local map_name = type(get_map_name) == "function" and SafeCall(get_map_name) or current_map and current_map.name

	DebugPrint(string.format(
		"quadrant debug: enabled=%s, random-only=%s, current=%s, terrain=%s x %s, mapdata=%s x %s, env=%s, pending=%s, source=%s x %s",
		tostring(cfg_bool("ENABLE_QUADRANT_MAP_COPY", false)),
		tostring(cfg_bool("QUADRANT_RANDOM_MAPS_ONLY", true)),
		tostring(map_name),
		tostring(map_width),
		tostring(map_height),
		tostring(mapdata and mapdata.Width),
		tostring(mapdata and mapdata.Height),
		tostring(mapdata and mapdata.Environment),
		tostring(current_map and current_map.SuperBigMapQuadrantCopyPending),
		tostring(current_map and current_map.SuperBigMapSourceWidth),
		tostring(current_map and current_map.SuperBigMapSourceHeight)
	))
	return true
end

local function PatchRandomMapGenerator()
	if not cfg_bool("QUADRANT_PATCH_RANDOM_GENERATOR", true) then
		VerbosePrint("quadrant random-map generator hook disabled")
		return false
	end

	local generator_class = Global("RandomMapGenerator")
	if type(generator_class) ~= "table" or type(generator_class.Generate) ~= "function" then
		VerbosePrint("quadrant random-map generator hook waiting for class")
		return false
	end

	local State = SuperBigMap.State
	-- Re-verify the wrappers are STILL on the class, not just the version.
	-- ClassesBuilt (mod reload / class rebuild) resets the methods to vanilla and
	-- re-calls us; a version-only guard would wrongly think we're still patched
	-- and never re-install, leaving vanilla DoGenerate -> GSRP overflow.
	if State.generator_patch_version == GENERATOR_PATCH_VERSION
		and generator_class.Generate == State.generator_generate_wrapper
		and generator_class.DoGenerate == State.generator_do_generate_wrapper then
		return true
	end

	-- Capture the current (vanilla) methods as originals, but never capture our
	-- own wrapper (e.g. if only one of the two got reset).
	if generator_class.Generate ~= State.generator_generate_wrapper then
		State.generator_original_generate = generator_class.Generate
	end
	if generator_class.DoGenerate ~= State.generator_do_generate_wrapper then
		State.generator_original_do_generate = generator_class.DoGenerate
	end
	local original_generate = State.generator_original_generate
	local original_do_generate = State.generator_original_do_generate
	local generate_wrapper = function(self, params)
		params = type(params) == "table" and params or {}
		local blank_map = self and self.BlankMap
		local map_name = params.map_name or blank_map
		if blank_map and blank_map ~= "" then
			local map_data_table = Global("MapData")
			local mapdata = type(map_data_table) == "table" and map_data_table[blank_map] or nil
			local instance = {
				mapdata = mapdata,
				RandomMapGenObject = self,
			}
			PrepareMapDataForQuadrantCopy(params.map_slot or 1, map_name, instance, "RandomMapGenerator.Generate")
			if params.map_slot then
				params.mapdata = params.mapdata or instance.mapdata
				params.RandomMapGenObject = params.RandomMapGenObject or self
				params.SuperBigMapQuadrantCopyPending = instance.SuperBigMapQuadrantCopyPending
				params.SuperBigMapSourceWidth = instance.SuperBigMapSourceWidth
				params.SuperBigMapSourceHeight = instance.SuperBigMapSourceHeight
				params.SuperBigMapOriginalWidthTiles = instance.SuperBigMapOriginalWidthTiles
				params.SuperBigMapOriginalHeightTiles = instance.SuperBigMapOriginalHeightTiles
				params.SuperBigMapDesiredWidthTiles = instance.SuperBigMapDesiredWidthTiles
				params.SuperBigMapDesiredHeightTiles = instance.SuperBigMapDesiredHeightTiles
			end
		else
			VerbosePrint("quadrant random-map generator hook skipped: no BlankMap")
		end

		return original_generate(self, params)
	end
	generator_class.Generate = generate_wrapper
	State.generator_generate_wrapper = generate_wrapper

	if type(original_do_generate) == "function" then
		local do_generate_wrapper = function(self, map, ...)
			if not cfg_bool("QUADRANT_LIMIT_GENERATOR_TO_SOURCE", true) then
				return original_do_generate(self, map, ...)
			end

			local height_tile_size = (Global("const") and type(const.HeightTileSize) == "number" and const.HeightTileSize > 0)
				and const.HeightTileSize or 1
			local max_random_tiles = math.floor(cfg_number("QUADRANT_MAX_RANDOM_GENERATOR_TILES", 6144, 1))

			-- The vanilla generator sizes its working grids from the map's tile
			-- count and asserts (GridStableRandomPosSimple: size < GSRP_MAX_SIZE)
			-- once that exceeds the vanilla maximum. It reads the size from
			-- map:GetMapSize(), terrain.GetMapSize(map) AND
			-- RandomMapGenerator:GetMapSize() (= MapData[self.BlankMap].Width), and
			-- the working grids can also key off map.mapdata.Width. So we DETECT
			-- the real map size from every one of those sources and, if any exceeds
			-- the random-generator max, cap them ALL for the duration of the
			-- generate. (Earlier this keyed only off MapData[BlankMap], which some
			-- maps -- e.g. landing-spot previews -- don't have set, so the cap was
			-- skipped and the grid overflowed.)
			local map_data_table = Global("MapData")
			local blank = self and self.BlankMap
			local template = type(map_data_table) == "table" and type(blank) == "string" and map_data_table[blank] or nil
			local mapdata = map and map.mapdata
			local terrain_api = Global("terrain")
			local original_map_get_size = map and map.GetMapSize
			local original_terrain_get_size = terrain_api and terrain_api.GetMapSize

			local function world_to_tiles(w)
				return (type(w) == "number" and w > 0) and math.floor(w / height_tile_size + 0.5) or 0
			end
			local cur_w_tiles, cur_h_tiles = 0, 0
			local dbg_mapget_w = false
			if type(original_map_get_size) == "function" then
				local ok, ww, hh = pcall(original_map_get_size, map)
				if ok then
					dbg_mapget_w = ww
					cur_w_tiles = math.max(cur_w_tiles, world_to_tiles(ww))
					cur_h_tiles = math.max(cur_h_tiles, world_to_tiles(hh))
				end
			end
			if type(mapdata) == "table" then
				if type(mapdata.Width) == "number" then cur_w_tiles = math.max(cur_w_tiles, mapdata.Width) end
				if type(mapdata.Height) == "number" then cur_h_tiles = math.max(cur_h_tiles, mapdata.Height) end
			end
			if template then
				if type(template.Width) == "number" then cur_w_tiles = math.max(cur_w_tiles, template.Width) end
				if type(template.Height) == "number" then cur_h_tiles = math.max(cur_h_tiles, template.Height) end
			end

			DebugPrint(string.format(
				"DoGenerate cap check: blank=%s template_w=%s mapdata_w=%s map_getsize_w=%s detected=%sx%s max=%s -> %s",
				tostring(blank),
				tostring(template and template.Width),
				tostring(mapdata and mapdata.Width),
				tostring(dbg_mapget_w),
				tostring(cur_w_tiles), tostring(cur_h_tiles), tostring(max_random_tiles),
				(cur_w_tiles <= max_random_tiles and cur_h_tiles <= max_random_tiles) and "SKIP (fits)" or "CAP"))

			-- Map fits the vanilla generator: run completely untouched.
			if cur_w_tiles <= max_random_tiles and cur_h_tiles <= max_random_tiles then
				return original_do_generate(self, map, ...)
			end

			-- Cap to the per-map generator markers if present, else the max.
			local gen_width_tiles = (type(map.SuperBigMapGeneratorWidthTiles) == "number" and map.SuperBigMapGeneratorWidthTiles > 0)
				and map.SuperBigMapGeneratorWidthTiles or max_random_tiles
			local gen_height_tiles = (type(map.SuperBigMapGeneratorHeightTiles) == "number" and map.SuperBigMapGeneratorHeightTiles > 0)
				and map.SuperBigMapGeneratorHeightTiles or max_random_tiles
			gen_width_tiles = math.max(1, math.min(gen_width_tiles, max_random_tiles))
			gen_height_tiles = math.max(1, math.min(gen_height_tiles, max_random_tiles))

			local gen_world_w = (type(map.SuperBigMapGeneratorWidth) == "number" and map.SuperBigMapGeneratorWidth > 0)
				and map.SuperBigMapGeneratorWidth or (gen_width_tiles * height_tile_size)
			local gen_world_h = (type(map.SuperBigMapGeneratorHeight) == "number" and map.SuperBigMapGeneratorHeight > 0)
				and map.SuperBigMapGeneratorHeight or (gen_height_tiles * height_tile_size)

			local saved_template_w = template and template.Width
			local saved_template_h = template and template.Height
			local saved_mapdata_w = type(mapdata) == "table" and mapdata.Width or nil
			local saved_mapdata_h = type(mapdata) == "table" and mapdata.Height or nil

			map.GetMapSize = function(target)
				if target == map then
					return gen_world_w, gen_world_h
				end
				if type(original_map_get_size) == "function" then
					return original_map_get_size(target)
				end
				return gen_world_w, gen_world_h
			end
			if terrain_api and type(original_terrain_get_size) == "function" then
				terrain_api.GetMapSize = function(target)
					if target == map or (target == nil and Global("CurrentMap") == map) then
						return gen_world_w, gen_world_h
					end
					return original_terrain_get_size(target)
				end
			end
			if template then
				template.Width = gen_width_tiles
				template.Height = gen_height_tiles
			end
			if type(mapdata) == "table" then
				mapdata.Width = gen_width_tiles
				mapdata.Height = gen_height_tiles
			end

			DebugPrint(string.format(
				"limiting random generator to %s x %s tiles (%s x %s wu) [blank=%s, detected %s x %s tiles]",
				tostring(gen_width_tiles), tostring(gen_height_tiles),
				tostring(gen_world_w), tostring(gen_world_h),
				tostring(blank), tostring(cur_w_tiles), tostring(cur_h_tiles)
			))

			-- Make the AREA FACTOR computable at Begin time: mapdata.Width was just overridden to
			-- the generator size, and the pending-map markers can be wiped by the new-game Lua
			-- reload -- with both gone AreaFactor read 6144/6144 = 1 and the anomaly/research count
			-- scaling silently did nothing (logs showed anom_count_scale=1.000). Stamp the DETECTED
			-- full + generator tile sizes on the map so RmgPlacement (and the later stretch passes)
			-- always see desired=8192 / generator=6144.
			map.SuperBigMapDesiredWidthTiles = map.SuperBigMapDesiredWidthTiles or cur_w_tiles
			map.SuperBigMapDesiredHeightTiles = map.SuperBigMapDesiredHeightTiles or cur_h_tiles
			map.SuperBigMapGeneratorWidthTiles = map.SuperBigMapGeneratorWidthTiles or gen_width_tiles
			map.SuperBigMapGeneratorHeightTiles = map.SuperBigMapGeneratorHeightTiles or gen_height_tiles

			-- Terrain-safe placement auto-fit: relax the deposit/anomaly placement
			-- margins + spacing (placement-only knobs; never touch gen_zone/terrain)
			-- so the full preset counts seat in the smaller expanded play_zone. Sizes
			-- are already overridden here, so coverage is measured over the generated
			-- span. Restored in End() below, regardless of success.
			local placement = SuperBigMap.RmgPlacement
			local placement_active = placement and placement.Begin(self, map) or false

			local LT = SuperBigMap.DebugLog and SuperBigMap.DebugLog.LoadTime
			if LT then LT("DoGenerate: vanilla generator begin", { blank = tostring(self.BlankMap) }) end
			local results = { pcall(original_do_generate, self, map, ...) }
			if LT then LT("DoGenerate: vanilla generator end", { ok = results[1] == true }) end

			if placement_active then
				placement.End(map)
			end

			map.GetMapSize = original_map_get_size
			if terrain_api and original_terrain_get_size then
				terrain_api.GetMapSize = original_terrain_get_size
			end
			if template then
				template.Width = saved_template_w
				template.Height = saved_template_h
			end
			if type(mapdata) == "table" then
				mapdata.Width = saved_mapdata_w
				mapdata.Height = saved_mapdata_h
			end

			if not results[1] then
				error(results[2])
			end
			return Unpack(results, 2)
		end
		generator_class.DoGenerate = do_generate_wrapper
		State.generator_do_generate_wrapper = do_generate_wrapper
	end
	State.generator_patch_version = GENERATOR_PATCH_VERSION
	DebugPrint("quadrant random-map generator hook installed")
	return true
end


-- Config-driven L-frame fill: at game start, run the three block copies (fast
-- path: one grid flip per block instead of one per sector). Gated on a full 20x20
-- terrain grid. Yields inside the object loops; ONE combined refresh at the end.
local function RunSectorMirrorPlanIfEnabled(map)
	if not cfg_bool("SECTOR_MIRROR_PLAN_AT_START", false) then
		return false
	end
	map = map or Global("CurrentMap")
	if not map or map.SuperBigMapSectorMirrorDone == true or map.SuperBigMapSectorMirrorScheduled == true then
		return false
	end
	local create_thread = Global("CreateRealTimeThread")
	local sleep = Global("Sleep")
	if type(create_thread) ~= "function" or type(sleep) ~= "function" then
		return false
	end
	map.SuperBigMapSectorMirrorScheduled = true
	-- STRETCH loads fast (grid resample, no sector-by-sector work), so it does not need the long
	-- mirror-plan settle -- use a short stretch-specific settle to cut several seconds off the load.
	local fill_mode_early = cfg_string("EXPANSION_FRAME_FILL_MODE", "mirror")
	local settle_ms = math.max(0, cfg_number("TEST_COPY_SECTOR_DELAY_MS", 5000))
	if fill_mode_early == "stretch" then
		settle_ms = math.max(0, cfg_number("STRETCH_SETTLE_MS", 800))
	end
	StretchLog("RunSectorMirrorPlan: scheduled", { mode = fill_mode_early, settle_ms = settle_ms })
	if SuperBigMap.DebugLog and SuperBigMap.DebugLog.LoadTime then
		SuperBigMap.DebugLog.LoadTime("expansion plan scheduled", { mode = fill_mode_early, settle_ms = settle_ms })
	end
	InitSeq("RunSectorMirrorPlan: scheduled (waiting for F0 + settle)", {
		settle_ms = settle_ms,
		frame_sectors = FrameSectorProbe(map),
	})
	create_thread(function()
		-- Loading screen: hide the welcome popup's Close button + show a loading message
		-- while we expand, restored on completion (ExpansionLoadingBegin/End in lifecycle).
		-- Begin EARLY (before the F0 wait + settle) so the player can't dismiss the welcome
		-- and start playing mid-expansion. Gated to real mod maps (not the PreGame preview).
		local lc_name = tostring(map.name or (map.mapdata and map.mapdata.id) or "")
		local lc_grid = SuperBigMap.SectorGrid
		local lc_mod_map = type(lc_grid) == "table" and type(lc_grid.IsModMap) == "function"
			and lc_grid.IsModMap(map) == true
		if lc_name ~= "PreGame" and lc_mod_map and type(SuperBigMap.ExpansionLoadingBegin) == "function" then
			SuperBigMap.ExpansionLoadingBegin()
		end
		local function end_loading()
			if SuperBigMap.DebugLog and SuperBigMap.DebugLog.LoadTime then
				SuperBigMap.DebugLog.LoadTime("loading box torn down (expansion path finished)")
			end
			if type(SuperBigMap.ExpansionLoadingEnd) == "function" then
				SuperBigMap.ExpansionLoadingEnd()
			end
		end
		local waited = 0
		for _ = 1, 60 do
			if FindSectorByName(map, "F0") then
				break
			end
			sleep(250)
			waited = waited + 250
		end
		InitSeq("RunSectorMirrorPlan: F0 wait finished", {
			waited_ms = waited,
			f0_found = FindSectorByName(map, "F0") ~= nil,
		})
		if SuperBigMap.DebugLog and SuperBigMap.DebugLog.LoadTime then
			SuperBigMap.DebugLog.LoadTime("F0 sector ready", { waited_ms = waited })
		end
		-- MUST wait the full settle before stretching: the map keeps loading AFTER PostNewMapLoaded
		-- (terrain data fills + ~7500 decorations get placed over the next few seconds). A
		-- readiness poll on BiomeGrid's SIZE fires far too early (size is allocated up front, data
		-- is not) -- stretching a half-loaded map gives the grey/incomplete result with almost no
		-- decorations and a bloated reinvalidate. The fixed settle is the reliable "map fully
		-- loaded" wait; tune StretchSettleMs if needed, but it must cover the async object placement.
		--
		-- LOAD-TIMELINE SAMPLING (DEBUG_LOADTIME): while waiting, sample the map's object count
		-- every 500ms. The full settle is ALWAYS waited (measurement only, no behavior change);
		-- the samples show exactly when object placement completes, so the settle can later be
		-- shortened to a data-backed value instead of another guess.
		do
			local LT = SuperBigMap.DebugLog and SuperBigMap.DebugLog.LoadTime
			local lt_on = LT and SuperBigMap.DebugLog.On and SuperBigMap.DebugLog.On("LoadTime")
			if lt_on and type(map.MapForEach) == "function" then
				local function count_objects()
					local n = 0
					pcall(map.MapForEach, map, "map", "CObject", function() n = n + 1 end)
					return n
				end
				LT("settle begin", { settle_ms = settle_ms, objects = count_objects() })
				local waited, step = 0, 500
				while waited < settle_ms do
					sleep(step)
					waited = waited + step
					LT("settle sample", { waited_ms = waited, objects = count_objects() })
				end
				LT("settle done")
			else
				sleep(settle_ms)
			end
		end
		if map.SuperBigMapSectorMirrorDone == true then
			InitSeq("RunSectorMirrorPlan: already done after settle -- aborting", {})
			end_loading()
			return
		end
		InitSeq("RunSectorMirrorPlan: settle done, about to check 20x20 fit", {
			frame_sectors = FrameSectorProbe(map),
		})
		-- Only maps the mod ACTUALLY expanded are candidates. Skip SILENTLY (no
		-- "cannot expand" popup) for:
		--   * the "PreGame" mission-setup preview map (a native ~15x15 preview that
		--     carries no expansion -- this is what fired the warning BEFORE a scenario
		--     was even chosen), and
		--   * any non-mod map (IsModMap == false) -- the same authoritative gate
		--     Lifecycle.Apply uses, so the mirror plan can never disagree with it and
		--     run on a map Apply already skipped.
		-- The looser UseCustomSectorsForMap check is kept as an additional silent skip.
		local map_name = tostring(map.name or (map.mapdata and map.mapdata.id) or "")
		local grid = SuperBigMap.SectorGrid
		local is_mod_map = type(grid) == "table" and type(grid.IsModMap) == "function" and grid.IsModMap(map) == true
		local custom_ok = not (type(grid) == "table" and type(grid.UseCustomSectorsForMap) == "function")
			or grid.UseCustomSectorsForMap(map)
		if map_name == "PreGame" or not is_mod_map or not custom_ok then
			map.SuperBigMapSectorMirrorDone = true
			DebugPrint(string.format(
				"RunSectorMirrorPlanIfEnabled: skipped SILENTLY -- not a real expanded scenario (map=%s is_mod_map=%s custom_ok=%s); no warning",
				map_name, tostring(is_mod_map), tostring(custom_ok)))
			InitSeq("RunSectorMirrorPlan: skipped (not a real expanded scenario)", {
				map = map_name,
				is_mod_map = is_mod_map,
				custom_ok = custom_ok,
			})
			end_loading()
			return
		end
		local map_w, map_h = TerrainSize(map)
		if type(map_w) ~= "number" or map_w <= 0 or type(map_h) ~= "number" or map_h <= 0 then
			map.SuperBigMapSectorMirrorDone = true
			DebugPrint("RunSectorMirrorPlanIfEnabled: skipped -- terrain size unavailable")
			end_loading()
			WarnCannotExpand(map, "terrain size unavailable")
			return
		end

		-- FRAME FILL MODE dispatch (config EXPANSION_FRAME_FILL_MODE, see sbm_config.lua). Chosen
		-- HERE, BEFORE the mirror-block fit check, because non-mirror modes do NOT use the named
		-- mirror sectors: "stretch" works purely on the terrain grids by world coordinates, so it
		-- must never be gated by (or warn via) SectorMirrorBlocksFit.
		local fill_mode = cfg_string("EXPANSION_FRAME_FILL_MODE", "mirror")

		-- STRETCH: resample the generated source to fill the whole 20x20 (no frame, no mirror
		-- seam) -- one continuous terrain, features ~1.33x larger. STEP 1 = TERRAIN ONLY: the
		-- generated objects/deposits are NOT yet repositioned, so they stay clustered in the
		-- source corner until the object pass lands. Finalize (buildable/passability/rockets) and
		-- return -- the mirror block phases below are skipped entirely for this mode.
		if fill_mode == "stretch" then
			-- FAIL-SAFE: run the whole stretch + finalize inside pcall so that if ANY step throws,
			-- the expansion thread does not die before end_loading() -- that is what leaves the
			-- loading box stuck on screen forever. Whatever happens, we mark the map done and close
			-- the loading box below. Every step is StretchLog'd so the last line before a hang
			-- pinpoints where it stopped.
			StretchLog("stretch branch: ENTER")
			if SuperBigMap.DebugLog and SuperBigMap.DebugLog.LoadTime then
				SuperBigMap.DebugLog.LoadTime("stretch begin")
			end
			-- The stretch passes iterate the full-map grids + EVERY object in one uninterrupted go;
			-- without the old per-step yields the engine's infinite-loop detector trips ("Infinite
			-- loop detected!"). Pause it for the duration -- these are BOUNDED passes (finite grid
			-- steps + a fixed object list), the same guard the deposit top-up uses. The resume below
			-- is balanced and ALWAYS runs (after the pcall, before we return).
			local pause_ild = Global("PauseInfiniteLoopDetection")
			local resume_ild = Global("ResumeInfiniteLoopDetection")
			if type(pause_ild) == "function" then SafeCall(pause_ild, "SuperBigMapStretch") end
			local stretch_ticks = Global("GetPreciseTicks") or Global("RealTime")
			local stretch_t0 = 0
			if type(stretch_ticks) == "function" then local ok, t = pcall(stretch_ticks); if ok and type(t) == "number" then stretch_t0 = t end end
			local ok_stretch, n_grids = false, 0
			local ok_branch, branch_err = pcall(function()
				if type(StretchSourceToFull) == "function" then
					StretchLog("stretch branch: -> StretchSourceToFull")
					ok_stretch, n_grids = StretchSourceToFull(map, false)
					StretchLog("stretch branch: StretchSourceToFull returned", { ok = ok_stretch, grids = n_grids })
				else
					StretchLog("stretch branch: StretchSourceToFull MISSING")
					DebugPrint("RunSectorMirrorPlanIfEnabled: STRETCH unavailable (TerrainCopy.StretchSourceToFull missing) -- terrain left as generated")
				end
				-- Step 2: reposition + scale the generated decorations onto the stretched terrain
				-- (must run AFTER the height stretch so SetTerrainZ reads the new surface).
				if type(ScaleDecorationsToFull) == "function" then
					StretchLog("stretch branch: -> ScaleDecorationsToFull")
					local n_dec = ScaleDecorationsToFull(map, false)
					StretchLog("stretch branch: ScaleDecorationsToFull returned", { moved = n_dec })
				end
				-- Step 3: move the deposit/anomaly/effect markers to their scaled spots too
				-- (config STRETCH_SCALE_MARKERS) -- same transform, positions only.
				if type(ScaleMarkersToFull) == "function" then
					StretchLog("stretch branch: -> ScaleMarkersToFull")
					local n_mark = ScaleMarkersToFull(map, false)
					StretchLog("stretch branch: ScaleMarkersToFull returned", { moved = n_mark })
				end
				-- Step 3b: move the entrance VISUALS (signs/structures/spawners -- skipped by the
				-- decor pass) with the same transform, so what the player SEES matches the markers.
				if type(MoveEntranceVisualsToScale) == "function" then
					StretchLog("stretch branch: -> MoveEntranceVisualsToScale")
					local n_vis = MoveEntranceVisualsToScale(map)
					StretchLog("stretch branch: MoveEntranceVisualsToScale returned", { moved = n_vis })
				end
				-- Step 3c: FLOATER AUDIT -- objects hovering above the stretched terrain (e.g.
				-- decor-pass-skipped rocks that kept their old Z over now-lower ground). Logs
				-- class/dz/skip-verdict per floater under the Align scope; snaps non-Building
				-- floaters down when STRETCH_RESNAP_FLOATERS is on.
				if type(AuditFloatingObjects) == "function" then
					StretchLog("stretch branch: -> AuditFloatingObjects (early)")
					local n_float = AuditFloatingObjects(map, "early")
					StretchLog("stretch branch: AuditFloatingObjects returned", { floaters = n_float })
				end
				-- Step 4: relocate the initial revealed sector(s) to the scaled position of the
				-- original pick, moving the landed rocket along (config STRETCH_RELOCATE_START_SECTOR).
				if type(StretchRelocateStartSector) == "function" then
					StretchLog("stretch branch: -> StretchRelocateStartSector")
					local n_rel = StretchRelocateStartSector(map)
					StretchLog("stretch branch: StretchRelocateStartSector returned", { relocated = n_rel })
				end
				-- Step 5: re-enforce scan-gating after the move (hide revealed enrichments that
				-- landed in unscanned sectors; place/reveal what moved into scanned ones).
				do
					local deposits = SuperBigMap.DepositRules
					if deposits and type(deposits.EnforceScanGateAfterStretch) == "function" then
						StretchLog("stretch branch: -> EnforceScanGateAfterStretch")
						SafeCall(deposits.EnforceScanGateAfterStretch, map)
					end
					-- Step 6: DENSITY NORMALIZATION (same suite as the mirror path, which the
					-- stretch branch never ran -- the cause of the over-crowded start sector):
					--   TopUpDeposits     raise the TOTAL to vanilla density x area (~1.78x),
					--                     stretch-aware baseline (all markers are generator output);
					--   RegisterCloned    register the top-up clones with their sectors;
					--   RespaceAnomalies  thin/respace the start sector's revealed anomalies;
					--   EvenOutDeposit    cap per-sector density (vanilla-like) and relocate the
					--                     surplus into sparse unscanned sectors.
					-- Net effect: proportionally MORE enrichments for the 20x20, at vanilla
					-- per-sector density -- no crowding.
					if deposits then
						if type(deposits.TopUpDeposits) == "function" then
							StretchLog("stretch branch: -> TopUpDeposits")
							SafeCall(deposits.TopUpDeposits, map)
						end
						if type(deposits.RegisterClonedMarkers) == "function" then
							StretchLog("stretch branch: -> RegisterClonedMarkers")
							SafeCall(deposits.RegisterClonedMarkers, map)
						end
						if type(deposits.RespaceAnomalies) == "function" then
							StretchLog("stretch branch: -> RespaceAnomalies")
							SafeCall(deposits.RespaceAnomalies, map)
						end
						if type(deposits.EvenOutDepositDensity) == "function" then
							StretchLog("stretch branch: -> EvenOutDepositDensity")
							SafeCall(deposits.EvenOutDepositDensity, map)
						end
						if type(deposits.LogDistributionReport) == "function" then
							SafeCall(deposits.LogDistributionReport, map, "stretch after density suite")
						end
					end
				end
				local function now2()
					if type(stretch_ticks) == "function" then local ok, t = pcall(stretch_ticks); if ok and type(t) == "number" then return t end end
					return 0
				end
				local ft = now2()
				StretchLog("stretch branch: -> RebuildBuildableGrid")
				local rebuild_buildable = Global("RebuildBuildableGrid")
				if type(rebuild_buildable) == "function" and map and map.buildable then
					SafeCall(rebuild_buildable, map)
				end
				StretchLog("TIMING: RebuildBuildableGrid", { ms = now2() - ft }); ft = now2()
				StretchLog("stretch branch: -> ForceFramePassable")
				SafeCall(ForceFramePassable, map)
				StretchLog("TIMING: ForceFramePassable", { ms = now2() - ft }); ft = now2()
				-- LATE + POST floater audits: catch floaters created AFTER the early audit --
				-- suspects: ForceFramePassable just above, or vanilla post-load passes (the early
				-- audit found only 7 small floaters yet big rocks still hovered on screen).
				if type(AuditFloatingObjects) == "function" then
					AuditFloatingObjects(map, "late")
					local ct = Global("CreateRealTimeThread")
					local sl = Global("Sleep")
					if type(ct) == "function" and type(sl) == "function" then
						ct(function()
							sl(30000)
							AuditFloatingObjects(map, "post30s")
						end)
					end
				end
				StretchLog("stretch branch: -> ResnapRocketsOnMap")
				local rockets = SuperBigMap.RocketRules
				if rockets and type(rockets.ResnapRocketsOnMap) == "function" then
					SafeCall(rockets.ResnapRocketsOnMap, map)
				end
				StretchLog("TIMING: ResnapRocketsOnMap", { ms = now2() - ft })
				StretchLog("stretch branch: finalize steps done")
			end)
			-- Balanced resume (always, even on error) so the loop detector is restored.
			if type(resume_ild) == "function" then SafeCall(resume_ild, "SuperBigMapStretch") end
			do
				local tnow = 0
				if type(stretch_ticks) == "function" then local ok, t = pcall(stretch_ticks); if ok and type(t) == "number" then tnow = t end end
				StretchLog("stretch branch: TOTAL expansion time", { ms = tnow - stretch_t0 })
				if SuperBigMap.DebugLog and SuperBigMap.DebugLog.LoadTime then
					SuperBigMap.DebugLog.LoadTime("stretch end", { stretch_ms = tnow - stretch_t0 })
				end
			end
			if not ok_branch then
				StretchLog("stretch branch: EXCEPTION -- map left as generated, closing loading box", { err = tostring(branch_err) })
				DebugPrint("RunSectorMirrorPlanIfEnabled: STRETCH branch ERROR: " .. tostring(branch_err))
			end
			-- ALWAYS mark done + expanded and close the loading box, even on error, so the game
			-- never hangs on the loading screen.
			map.SuperBigMapSectorMirrorDone = true
			map.SuperBigMapExpanded = true
			DebugPrint(string.format(
				"RunSectorMirrorPlanIfEnabled: STRETCH mode complete (terrain only) branch_ok=%s stretch_ok=%s grids=%s -- objects NOT yet repositioned",
				tostring(ok_branch), tostring(ok_stretch), tostring(n_grids)))
			InitSeq("RunSectorMirrorPlan: stretch complete (terrain only)", { branch_ok = ok_branch, ok = ok_stretch, grids = n_grids })
			StretchLog("stretch branch: -> end_loading()")
			end_loading()
			StretchLog("stretch branch: DONE")
			return
		end

		if fill_mode ~= "mirror" then
			DebugPrint(string.format(
				"RunSectorMirrorPlanIfEnabled: frame-fill mode '%s' not yet implemented -- falling back to 'mirror'",
				tostring(fill_mode)))
			InitSeq("RunSectorMirrorPlan: frame-fill mode fallback", { requested = fill_mode, used = "mirror" })
			fill_mode = "mirror"
		end

		-- MIRROR (and any not-yet-implemented mode that falls back to it) needs the full 20x20
		-- sector grid to reflect edge blocks into the named frame sectors:
		local fits, why = SectorMirrorBlocksFit(map, map_w, map_h)
		if not fits then
			map.SuperBigMapSectorMirrorDone = true
			DebugPrint(string.format(
				"RunSectorMirrorPlanIfEnabled: skipped -- not a full 20x20 terrain grid (%s)", tostring(why)))
			end_loading()
			WarnCannotExpand(map, why)
			return
		end
		local terrain_api = Global("terrain")
		local box_fn = Global("box")
		local n = #SECTOR_MIRROR_BLOCKS

		-- PHASE 1 -- TERRAIN: copy every block's grids first, then render the mirrored
		-- ground immediately (cheap Invalidate, no full rebuild), so the player sees the
		-- expanded landscape before the slow object cloning.
		local terrain_done = 0
		local ux1, uy1, ux2, uy2 -- union of destination boxes
		for _, b in ipairs(SECTOR_MIRROR_BLOCKS) do
			local ok, bx1, by1, bx2, by2 = CopySectorBlock(map, b.src_a, b.src_b, b.dst_a, b.dst_b, b.mx, b.my, true, b.label, "terrain")
			if ok then
				terrain_done = terrain_done + 1
				ux1 = ux1 and math.min(ux1, bx1) or bx1
				uy1 = uy1 and math.min(uy1, by1) or by1
				ux2 = ux2 and math.max(ux2, bx2) or bx2
				uy2 = uy2 and math.max(uy2, by2) or by2
			end
			sleep(1)
		end
		if type(box_fn) == "function" and ux1 and type(terrain_api) == "table" then
			local rbox = box_fn(ux1, uy1, ux2, uy2)
			if type(terrain_api.InvalidateHeight) == "function" then SafeCall(terrain_api.InvalidateHeight, map, rbox) end
			if type(terrain_api.InvalidateType) == "function" then SafeCall(terrain_api.InvalidateType, map, rbox) end
			if type(terrain_api.HashGrids) == "function" then SafeCall(terrain_api.HashGrids, map) end
		end

		-- PHASE 2 -- OBJECTS: delete/clone/resnap each block's scatter (the slow part,
		-- yields throughout), then ONE heavy rebuild so the placed objects' passability
		-- and Z settle.
		local obj_done = 0
		for _, b in ipairs(SECTOR_MIRROR_BLOCKS) do
			if CopySectorBlock(map, b.src_a, b.src_b, b.dst_a, b.dst_b, b.mx, b.my, true, b.label, "objects") then
				obj_done = obj_done + 1
			end
			sleep(1)
		end
		if type(box_fn) == "function" and ux1 and type(terrain_api) == "table" then
			local rbox = box_fn(ux1, uy1, ux2, uy2)
			if type(terrain_api.RebuildPassability) == "function" then SafeCall(terrain_api.RebuildPassability, map, rbox) end
			if type(map.RebuildGrids) == "function" then SafeCall(map.RebuildGrids, map, rbox) end
			if type(terrain_api.HashGrids) == "function" then SafeCall(terrain_api.HashGrids, map) end
		end

		-- Safety: a generator-placed underground entrance outside the source quadrant is shielded
		-- from the per-block dest-clear (ShouldSkipObject protects underground access), so it can
		-- linger in the cloned frame. Sweep it now that all object cloning/deletion is done.
		RemoveFrameUndergroundAccess(map)

		-- The dest-clear phase ran on the frame; recreate any sector decals that were
		-- caught in those boxes so the L-frame's overview grid stays visible. (With the
		-- decal classes exempt from deletion this should recreate 0; kept as a safety
		-- net in case any frame decal was lost.)
		local sectors = SuperBigMap.SectorExploration
		if sectors and type(sectors.RefreshSectorDecals) == "function" then
			SafeCall(sectors.RefreshSectorDecals, map.City)
		end

		-- Deposits: scatter the cloned resource-deposit markers across the expanded area onto
		-- similar terrain (reshuffle), THEN register each with the frame sector it ends up in,
		-- so scanning that sector spawns the deposit (and paints concrete) the vanilla way.
		local deposits = SuperBigMap.DepositRules
		if deposits then
			if type(deposits.ReshuffleClonedMarkers) == "function" then
				SafeCall(deposits.ReshuffleClonedMarkers, map)
			end
			-- Top up resource deposits to the expanded map's full vanilla density (clone extra
			-- source markers into the frame) BEFORE registration, so the added clones get
			-- registered and then spread by the even-out pass below.
			if type(deposits.TopUpDeposits) == "function" then
				SafeCall(deposits.TopUpDeposits, map)
			end
			if type(deposits.RegisterClonedMarkers) == "function" then
				SafeCall(deposits.RegisterClonedMarkers, map)
				end
			-- Re-space anomalies to vanilla-like even spacing now that the full map exists
			-- (generation packs them tighter so all FreeTech fit; this spreads them back out).
			if type(deposits.RespaceAnomalies) == "function" then
				SafeCall(deposits.RespaceAnomalies, map)
			end
			-- Even out RESOURCE-deposit density: the generator crams the full preset count into
			-- the shrunken gen-zone, so the source (incl. the start sector) is far denser than
			-- vanilla. This caps per-sector density and moves the surplus into the sparse frame.
			if type(deposits.EvenOutDepositDensity) == "function" then
				SafeCall(deposits.EvenOutDepositDensity, map)
			end
		end

		-- Rebuild the BUILDABLE z-grid now that the copy finalized the
		-- terrain heights. It was built from the PRE-copy terrain, so it's stale (e.g. holds
		-- 21262 where the copied ground is now 7832). The construction terrain-flatten that
		-- runs when a rocket landing site is placed levels the pad TO the z-grid value, so a
		-- stale grid carves a PILLAR (or hole). Rebuilding it to match the current terrain
		-- makes that flatten a no-op -> no deformation. (RebuildBuildableGrid is the wrapped
		-- global; ForceBuildableGridStorage is disabled, so this just recomputes from terrain.)
		do
			local rebuild_buildable = Global("RebuildBuildableGrid")
			if type(rebuild_buildable) == "function" and map and map.buildable then
				SafeCall(rebuild_buildable, map)
				DebugPrint("RunSectorMirrorPlan: rebuilt buildable z-grid to match copied terrain")
			end
		end

		-- Force the freshly-copied L-frame PASSABLE so a rover from a rocket landing in it
		-- isn't trapped where the copied (cliff) terrain reads impassable (the original
		-- 9e940f8 fix). Runs now that the frame terrain + passability grids are built.
		ForceFramePassable(map)

		-- The terrain under any rocket that landed BEFORE this copy (e.g. the first colony
		-- rocket, which lands during load) just changed. Re-snap landed rockets onto the
		-- new surface so they don't end up floating / on a copied hill.
		local rockets = SuperBigMap.RocketRules
		if rockets and type(rockets.ResnapRocketsOnMap) == "function" then
			SafeCall(rockets.ResnapRocketsOnMap, map)
		end

		map.SuperBigMapSectorMirrorDone = true
		-- Persisted marker (a MapVar, declared in sbm_sector_grid): records that THIS map was
		-- expanded by the mod, so IsModMap recognises it after a save/load (the transient/preset
		-- markers don't survive a save). Without it a reloaded mod save warns "started without
		-- Super Big Map" and the mod stays inert on an already-expanded map.
		map.SuperBigMapExpanded = true
		-- Expansion fully done (terrain + objects): restore the welcome
		-- popup's Close button + original text so the player can dismiss it and play.
		end_loading()
		DebugPrint(string.format(
			"RunSectorMirrorPlanIfEnabled: completed terrain=%s/%s objects=%s/%s blocks (settle=%sms)",
			tostring(terrain_done), tostring(n), tostring(obj_done), tostring(n), tostring(settle_ms)))
	end)
	return false
end


local function SyncMapDataToGrids(map)
	local terrain_api = Global("terrain")
	if type(terrain_api) ~= "table" then
		DebugPrint("SyncMapDataToGrids skipped: no terrain api")
		return false
	end
	if type(terrain_api.HeightMapSize) ~= "function" then
		DebugPrint("SyncMapDataToGrids skipped: HeightMapSize unavailable")
		return false
	end
	local mapdata = map and map.mapdata
	if type(mapdata) ~= "table" then
		DebugPrint("SyncMapDataToGrids skipped: no mapdata")
		return false
	end
	local ok, gw, gh = pcall(terrain_api.HeightMapSize, map)
	if not ok or type(gw) ~= "number" or gw <= 0 then
		DebugPrint("SyncMapDataToGrids skipped: HeightMapSize call failed")
		return false
	end
	gh = type(gh) == "number" and gh or gw

	local old_w = type(mapdata.Width) == "number" and mapdata.Width or 0
	local old_h = type(mapdata.Height) == "number" and mapdata.Height or 0
	if old_w == gw and old_h == gh then
		DebugPrint(string.format("SyncMapDataToGrids: already in sync (%sx%s)", tostring(old_w), tostring(old_h)))
		return false
	end

	-- Preserve original size so RestoreVanillaBehavior can put it back if the
	-- mod is disabled mid-session.
	if mapdata.SuperBigMapOriginalMapDataWidth == nil then
		mapdata.SuperBigMapOriginalMapDataWidth = old_w
	end
	if mapdata.SuperBigMapOriginalMapDataHeight == nil then
		mapdata.SuperBigMapOriginalMapDataHeight = old_h
	end

	mapdata.Width = gw
	mapdata.Height = gh
	DebugPrint(string.format(
		"SyncMapDataToGrids: mapdata %sx%s -> %sx%s to match terrain grids",
		tostring(old_w), tostring(old_h), tostring(gw), tostring(gh)
	))
	return true
end

-- STRETCH for the UNDERGROUND map (config STRETCH_UNDERGROUND): the same resample pipeline as the
-- surface in its minimal form -- terrain grids + decorations + markers (incl. tunnel markers), no
-- sector-grid work, no start-sector relocation, no density suite yet. Because BOTH maps receive
-- the IDENTICAL x(full/source) transform, surface<->underground entrances keep corresponding: the
-- game spawns an underground passage AT the surface passage's own x,y and links the pair by
-- object reference. Triggered from PostNewMapLoaded for Environment=="Underground" maps; gates on
-- the expansion sizes stamped by the DoGenerate wrapper (desired > generator).
local function RunUndergroundStretchIfEnabled(map)
	if not cfg_bool("STRETCH_UNDERGROUND", false) then return false end
	map = map or Global("CurrentMap")
	if not map or map.SuperBigMapUndergroundStretchDone == true then return false end
	local desired = map.SuperBigMapDesiredWidthTiles
	local gen_t = map.SuperBigMapGeneratorWidthTiles
	if not (type(desired) == "number" and type(gen_t) == "number" and desired > gen_t) then
		StretchLog("underground stretch: not an expanded underground map -- skip", {
			desired = tostring(desired), generator = tostring(gen_t),
		})
		return false
	end
	local create_thread = Global("CreateRealTimeThread")
	local sleep = Global("Sleep")
	if type(create_thread) ~= "function" or type(sleep) ~= "function" then return false end
	map.SuperBigMapUndergroundStretchDone = true
	local settle_ms = math.max(0, cfg_number("STRETCH_SETTLE_MS", 5000))
	StretchLog("underground stretch: scheduled", { settle_ms = settle_ms, desired = desired, generator = gen_t })
	create_thread(function()
		sleep(settle_ms)
		local pause_ild = Global("PauseInfiniteLoopDetection")
		local resume_ild = Global("ResumeInfiniteLoopDetection")
		if type(pause_ild) == "function" then SafeCall(pause_ild, "SuperBigMapUndergroundStretch") end
		local ok_branch, branch_err = pcall(function()
			-- Renderer bounds must cover the full 8192 grid (same fix as the surface).
			SafeCall(SyncMapDataToGrids, map)
			StretchLog("underground stretch: -> StretchSourceToFull")
			local ok_s, n_grids = StretchSourceToFull(map, false)
			StretchLog("underground stretch: grids done", { ok = ok_s, grids = n_grids })
			if type(ScaleDecorationsToFull) == "function" then
				StretchLog("underground stretch: -> ScaleDecorationsToFull")
				local n_dec = ScaleDecorationsToFull(map, false)
				StretchLog("underground stretch: decorations done", { moved = n_dec })
			end
			if type(ScaleMarkersToFull) == "function" then
				StretchLog("underground stretch: -> ScaleMarkersToFull")
				local n_mark = ScaleMarkersToFull(map, false)
				StretchLog("underground stretch: markers done", { moved = n_mark })
			end
			-- Entrance VISUALS follow their markers (same transform; see surface step 3b).
			if type(MoveEntranceVisualsToScale) == "function" then
				StretchLog("underground stretch: -> MoveEntranceVisualsToScale")
				local n_vis = MoveEntranceVisualsToScale(map)
				StretchLog("underground stretch: entrance visuals done", { moved = n_vis })
			end
			-- NOTE (user decision): NO entrance placement correction of any kind. Entrances on
			-- both maps receive exactly ONE transformation -- the stretch itself (position *
			-- full/source via ScaleMarkersToFull + MoveEntranceVisualsToScale), the same as every
			-- other object. Where vanilla generated a pair mismatched, it stays mismatched.
			-- TEMP (config UNDERGROUND_REVEAL_ALL_DEPOSITS): force-place + reveal every
			-- deposit/anomaly so the stretched underground layout can be inspected.
			if cfg_bool("UNDERGROUND_REVEAL_ALL_DEPOSITS", false) then
				local deposits = SuperBigMap.DepositRules
				if deposits and type(deposits.ForceRevealAllOnMap) == "function" then
					StretchLog("underground stretch: -> ForceRevealAllOnMap (TEMP)")
					SafeCall(deposits.ForceRevealAllOnMap, map)
				end
			end
			local rebuild_buildable = Global("RebuildBuildableGrid")
			if type(rebuild_buildable) == "function" and map.buildable then
				SafeCall(rebuild_buildable, map)
			end
		end)
		if type(resume_ild) == "function" then SafeCall(resume_ild, "SuperBigMapUndergroundStretch") end
		if not ok_branch then
			StretchLog("underground stretch: EXCEPTION -- map left as generated", { err = tostring(branch_err) })
			DebugPrint("RunUndergroundStretchIfEnabled ERROR: " .. tostring(branch_err))
		end
		StretchLog("underground stretch: DONE", { ok = ok_branch })
		DebugPrint("underground stretch complete")
	end)
	return true
end

local MapGeneration = {}

MapGeneration.RunUndergroundStretchIfEnabled = RunUndergroundStretchIfEnabled
MapGeneration.FinalizeExpandedMap = FinalizeExpandedMap
MapGeneration.PrintQuadrantDebug = PrintQuadrantDebug
MapGeneration.AttachPendingMapState = AttachPendingMapState
MapGeneration.PrepareMapDataForQuadrantCopy = PrepareMapDataForQuadrantCopy
MapGeneration.PatchRandomMapGenerator = PatchRandomMapGenerator
MapGeneration.SyncMapDataToGrids = SyncMapDataToGrids
MapGeneration.RunSectorMirrorPlanIfEnabled = RunSectorMirrorPlanIfEnabled
MapGeneration.ForceFramePassable = ForceFramePassable
MapGeneration.ReinvalidateExpandedTerrain = ReinvalidateExpandedTerrain

function MapGeneration.ApplyModBehavior()
	PatchRandomMapGenerator()
end

-- Restoring only affects FUTURE generation; maps already tiled stay tiled.
function MapGeneration.RestoreVanillaBehavior()
	local State = SuperBigMap.State or {}
	local generator_class = Global("RandomMapGenerator")
	if type(generator_class) == "table" then
		if type(State.generator_original_generate) == "function" then
			generator_class.Generate = State.generator_original_generate
		end
		if type(State.generator_original_do_generate) == "function" then
			generator_class.DoGenerate = State.generator_original_do_generate
		end
	end
	State.generator_original_generate = nil
	State.generator_original_do_generate = nil
	State.generator_patch_version = nil
end

SuperBigMap.MapGeneration = MapGeneration

-- Install the random-map generator hook NOW, at module load. Mods load their Lua AFTER the game
-- classes are built, so RandomMapGenerator already exists here -- and this runs BEFORE the
-- pre-game landing-spot preview generates a map. The OnMsg boot events (ClassesBuilt /
-- ClassesPostprocess / DataLoaded) can't cover that preview because they fire during engine boot,
-- before this mod's handlers are even registered; and ChangingMap fires only for a real map
-- change, after the preview. Without the hook here, vanilla DoGenerate runs on the expanded-size
-- grid and overflows GSRP ("GridStableRandomPosSimple: size < GSRP_MAX_SIZE"). The boot/ChangingMap
-- re-installs still handle later class rebuilds (which reset the methods to vanilla).
if (SuperBigMap.Config or {}).ENABLE_MOD ~= false then
	PatchRandomMapGenerator()
end

DebugPrint("map generation module loaded")

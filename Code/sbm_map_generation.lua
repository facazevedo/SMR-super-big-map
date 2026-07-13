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
SuperBigMap.State.underground_stretch_threads = SuperBigMap.State.underground_stretch_threads
	or setmetatable({}, { __mode = "k" })
local pending_maps = SuperBigMap.State.quadrant_pending_maps
local blocked_maps = SuperBigMap.State.quadrant_blocked_maps
local underground_stretch_threads = SuperBigMap.State.underground_stretch_threads

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

-- Update the loading box's live status line (see sbm_loading_ui SetLoadingPhase). Safe no-op
-- if the loading UI isn't present; " Please wait." is appended by SetLoadingPhase.
local function SetLoadingPhase(message)
	if type(SuperBigMap.SetLoadingPhase) == "function" then
		pcall(SuperBigMap.SetLoadingPhase, message)
	end
end

local function WakePendingUndergroundStretch()
	if not cfg_bool("OPTIMIZE_UNDERGROUND_WAKE_HANDOFF", true) then return 0 end
	local wakeup = Global("Wakeup")
	if type(wakeup) ~= "function" then return 0 end
	local woken = 0
	for _, thread in pairs(underground_stretch_threads) do
		if thread and pcall(wakeup, thread) then woken = woken + 1 end
	end
	local profiler = SuperBigMap.LoadingProfiler
	if profiler and type(profiler.Step) == "function" then
		profiler.Step("underground readiness: surface-complete wake handoff", { woken = woken }, Global("CurrentMap"))
	end
	return woken
end

-- Exhaustive entrance/exit forensic snapshots (no-op unless DEBUG_ENTRANCEPOSITIONS is on).
local function EntranceSnapshot(phase, map)
	local debug_mod = SuperBigMap.EntranceDebug
	if debug_mod and type(debug_mod.SnapshotAll) == "function" then
		pcall(debug_mod.SnapshotAll, phase, map)
	end
end

local function EntranceLinkSnapshot(a, b, phase)
	local debug_mod = SuperBigMap.EntranceDebug
	if debug_mod and type(debug_mod.LogLink) == "function" then
		pcall(debug_mod.LogLink, a, b, phase)
	end
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
	local profiler = SuperBigMap.LoadingProfiler
	if profiler and type(profiler.Step) == "function" then
		profiler.Step("stretch: " .. tostring(message), data, Global("CurrentMap"))
	end
end

-- True only while a real stretch pipeline has been scheduled and has not completed. Used to
-- suppress full-map rebuilds whose results would immediately be discarded by that stretch.
local function ShouldDeferStretchRebuilds(map)
	return cfg_bool("OPTIMIZE_STRETCH_DEFERRED_REBUILDS", true)
		and type(map) == "table"
		and (map.SuperBigMapStretchPipelinePending == true
			or map.SuperBigMapUndergroundStretchPending == true)
end

-- Cheap final state refresh after the stretch's authoritative grid rebuilds. Deliberately does
-- not call Lifecycle.Apply(..., true) or RebuildMapBounds: those are the duplicate full-grid
-- passes this optimization removes. Sector boxes/play ratios and max object radius are refreshed.
local function FinalizeDeferredStretchState(map, phase)
	if not map then return false end
	local bounds = SuperBigMap.MapBounds
	if bounds then
		if type(bounds.ResetMapDataBounds) == "function" then SafeCall(bounds.ResetMapDataBounds, map, map.mapdata) end
		if type(bounds.ResetMapAreas) == "function" then SafeCall(bounds.ResetMapAreas, map) end
		if type(bounds.RefreshSectors) == "function" then SafeCall(bounds.RefreshSectors, map) end
	end
	local update_radius = Global("UpdateMapMaxObjRadius")
	if type(update_radius) == "function" then SafeCall(update_radius, map) end
	map.SuperBigMapStretchPipelinePending = false
	local profiler = SuperBigMap.LoadingProfiler
	if profiler and type(profiler.Step) == "function" then
		profiler.Step("stretch optimization: final lightweight state refresh", {
			phase = tostring(phase), deferred_rebuilds = true,
		}, map)
	end
	return true
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
local AnnotateDecorRelief = TerrainCopy.AnnotateDecorRelief
local ClearDecorRelief = TerrainCopy.ClearDecorRelief
local SpikeAudit = TerrainCopy.SpikeAudit or function() end
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
		local defer = ShouldDeferStretchRebuilds(map)
		SafeCall(apply_bounds, map, not defer)
		if defer then
			local profiler = SuperBigMap.LoadingProfiler
			if profiler and type(profiler.Step) == "function" then
				profiler.Step("stretch optimization: deferred FinalizeExpandedMap full rebuild", nil, map)
			end
		end
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

-- ---------------------------------------------------------------------------------------
-- GENERATION-DETERMINISM instrumentation (config DebugGenRand -> scope "GenRand").
-- Purpose: find WHERE the expanded run's generator random stream diverges from vanilla.
-- The vanilla generator re-seeds its PRNG per procedure (ProcInvoke: rand_state:Set(
-- xxhash(Seed, tag)) before each proc), so divergence cannot leak across procs -- the
-- per-proc rand fingerprint (rand_state:Last() at ProcEnd) identifies exactly which proc
-- consumed a different roll sequence. Instrument:
--   * ProcStart: tag + per-proc seed + the map sizes / PassBorder the generator sees
--     (play-zone inputs -- GetPlayableArea reads map.mapdata.PassBorder);
--   * ProcEnd: tag + rand_state:Last() = the proc's stream FINGERPRINT;
--   * post-DoGenerate object census: per-class count + position/angle sums + samples,
--     logged in PRE-STRETCH coordinates, directly diffable between a vanilla run and an
--     expanded run (vanilla pos x 1 vs expanded pre-stretch pos must be IDENTICAL).
-- To use: run once vanilla (EXPAND off), once expanded, then diff the GenRand lines --
-- the first proc whose ProcEnd fingerprint differs is the divergence point.
-- ---------------------------------------------------------------------------------------
local function GenRandEnabled()
	return cfg_bool("DEBUG_GENRAND", false) or cfg_bool("DEBUG_LOGS", false)
end

local function GenRandLog(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then DebugLog.Info("GenRand", message, data) end
end

-- Reads the generator's rand fingerprint; RandState:Last() is what vanilla's own debug
-- instrumentation logs (RandomMapGenerator.lua AddHistory "RAND ... last %d").
local function GenRandLast(generator)
	local rs = generator and generator.rand_state
	if rs and type(rs.Last) == "function" then
		local ok, last = pcall(rs.Last, rs)
		if ok then return last end
	end
	return "n/a"
end

-- Per-class census of every map object: count + coordinate/angle sums + first samples.
-- Sum-based fingerprints make the diff robust to enumeration order.
local function GenRandCensus(map, label)
	if not GenRandEnabled() then return end
	if not map or type(map.MapForEach) ~= "function" then return end
	local pause = Global("PauseInfiniteLoopDetection")
	local resume = Global("ResumeInfiniteLoopDetection")
	if type(pause) == "function" then pcall(pause, "SBMGenRandCensus") end
	local per, total = {}, 0
	local swept_ok = pcall(map.MapForEach, map, "map", "CObject", function(obj)
		local class = (obj and obj.class) or "?"
		local e = per[class]
		if not e then
			e = { n = 0, sx = 0, sy = 0, sz = 0, sa = 0, samples = {} }
			per[class] = e
		end
		e.n = e.n + 1
		total = total + 1
		if type(obj.GetPos) == "function" then
			local okp, pos = pcall(obj.GetPos, obj)
			if okp and pos and type(pos.xyz) == "function" then
				local x, y, z = pos:xyz()
				if type(x) == "number" then
					e.sx = e.sx + x
					e.sy = e.sy + (y or 0)
					e.sz = e.sz + (type(z) == "number" and z or 0)
					local a = 0
					if type(obj.GetAngle) == "function" then
						local oka, aa = pcall(obj.GetAngle, obj)
						if oka and type(aa) == "number" then a = aa end
					end
					e.sa = e.sa + a
					if #e.samples < 3 then
						e.samples[#e.samples + 1] = string.format("(%s,%s,%s a=%s)",
							tostring(x), tostring(y), tostring(z), tostring(a))
					end
				end
			end
		end
	end)
	local classes = {}
	for class in pairs(per) do classes[#classes + 1] = class end
	table.sort(classes)
	GenRandLog("census begin", {
		label = tostring(label), map = tostring(map.name),
		classes = #classes, total_objects = total, swept_ok = swept_ok,
	})
	for _, class in ipairs(classes) do
		local e = per[class]
		GenRandLog(string.format("census %-44s n=%-6d sum=(%s,%s,%s) suma=%s %s",
			class, e.n, tostring(e.sx), tostring(e.sy), tostring(e.sz), tostring(e.sa),
			table.concat(e.samples, " ")))
	end
	GenRandLog("census end", { label = tostring(label), map = tostring(map.name) })
	if type(resume) == "function" then pcall(resume, "SBMGenRandCensus") end
end

-- Snapshot of every size/border input the generator derives placement from.
local function GenRandInputs(generator, map)
	local map_data_table = Global("MapData")
	local blank = generator and generator.BlankMap
	local template = type(map_data_table) == "table" and type(blank) == "string" and map_data_table[blank] or nil
	local mapdata = map and map.mapdata
	local mw, mh = "n/a", "n/a"
	if map and type(map.GetMapSize) == "function" then
		local ok, ww, hh = pcall(map.GetMapSize, map)
		if ok then mw, mh = ww, hh end
	end
	return {
		Seed = tostring(generator and generator.Seed),
		Id = tostring(generator and generator.Id),
		BlankMap = tostring(blank),
		map_getsize = tostring(mw) .. "x" .. tostring(mh),
		mapdata_wh = tostring(mapdata and mapdata.Width) .. "x" .. tostring(mapdata and mapdata.Height),
		template_wh = tostring(template and template.Width) .. "x" .. tostring(template and template.Height),
		mapdata_passborder = tostring(mapdata and mapdata.PassBorder),
		template_passborder = tostring(template and template.PassBorder),
		rand_last = tostring(GenRandLast(generator)),
	}
end

-- DETERMINISTIC PASSAGE PAIRING (config STRETCH_DETERMINISTIC_PASSAGES). During the
-- UNDERGROUND map's generation, vanilla spawns each SURFACE UndergroundPassage by searching
-- MainMap's buildable grid around the underground SurfacePassageMarker's position
-- (Picard RandomMapGen_PlaceArtefacts_Passages -> SpawnUndergroundPassage ->
-- FindPassageSpawnPos) and, when the search fails, falls back to a RANDOM passable position
-- (GetRandomPassable; up to 12 attempts). On an expanded map that search races the surface
-- map's ASYNC buildable-grid build ("Buildable grid ready" lands seconds after generation)
-- and the stretch passes, so an entrance can take the random fallback -- a DIFFERENT spot
-- every restart (log-proven: same surface generation fingerprints, entrances G8+Q16 one run
-- and J4+G8 the next), sometimes on a mountain ("passable" does not imply buildable, which
-- then asserts the construction flatten when the elevator is placed there). Vanilla's own
-- intent is CORRESPONDENCE: the underground maps are authored so the marker position is
-- valid on the surface too (see the vanilla TODO comment right at that call site). So on
-- expanded maps the surface passage is placed EXACTLY at the underground marker's position
-- (hex- and terrain-snapped, like vanilla's own placement) -- no search, no randomness. The
-- caller (Picard) then clears obstructions and links the pair exactly as vanilla does, and
-- the later stretch scales BOTH endpoints by the same factor, preserving correspondence.
-- Vanilla-size maps always run the original. Self-verifying via State (survives the
-- new-game Lua reload through the ClassesBuilt/ModsReloaded re-install).
-- Pairing trace (scope "Pairing", gated DEBUG_PAIRING): the v434 deterministic pairing
-- placed NOTHING (a run had the install line but zero placement lines while the entrance
-- moved again), so every call and every branch now logs -- one run pins the failure point.
local function PairingLog(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then DebugLog.Info("Pairing", message, data) end
end

local function PatchPassagePairing()
	if not cfg_bool("STRETCH_DETERMINISTIC_PASSAGES", true) then return false end
	local State = SuperBigMap.State
	local current = Global("SpawnUndergroundPassage")
	if type(current) ~= "function" then
		PairingLog("install waiting: SpawnUndergroundPassage not defined yet")
		return false
	end
	if current == State.spawn_passage_wrapper then return true end
	State.original_spawn_passage = current
	local wrapper = function(map, pos, angle, min_dist, passages)
		local original = State.original_spawn_passage
		local desired = map and map.SuperBigMapDesiredWidthTiles
		local gen_t = map and map.SuperBigMapGeneratorWidthTiles
		local expanded = type(desired) == "number" and type(gen_t) == "number" and desired > gen_t
		PairingLog("SpawnUndergroundPassage call", {
			map = tostring(map and map.name), pos = tostring(pos), angle = tostring(angle),
			min_dist = tostring(min_dist), passages_so_far = tostring(passages and #passages),
			desired_tiles = tostring(desired), generator_tiles = tostring(gen_t),
			expanded = expanded == true,
		})
		if not expanded then
			PairingLog("-> vanilla path (map not stamped as expanded)")
			return original(map, pos, angle, min_dist, passages)
		end
		local snap_hex = Global("SnapWorldToHex")
		local snap_angle = Global("SnapWorldToHexAngle")
		local get_shape = Global("GetExtendedSpawnShape")
		local place_building = Global("PlaceBuildingIn")
		local flatten = Global("FlattenTerrainInBuildShape")
		local const_tbl = Global("const")
		if type(snap_hex) ~= "function" or type(place_building) ~= "function" then
			PairingLog("-> vanilla path (helpers missing)", {
				snap_hex = tostring(type(snap_hex)), place_building = tostring(type(place_building)),
			})
			return original(map, pos, angle, min_dist, passages)
		end
		local position = snap_hex(pos)
		if type(snap_angle) == "function" then
			local ok_a, a = pcall(snap_angle, angle)
			if ok_a and a then angle = a end
		end
		if type(map.SnapToTerrain) == "function" then
			local ok_s, snapped = pcall(map.SnapToTerrain, map, position)
			if ok_s and snapped then position = snapped end
		end
		local shape = type(get_shape) == "function" and get_shape("Elevator") or nil
		local ok_p, passage = pcall(place_building, "UndergroundPassage", map)
		if not ok_p or not passage then
			PairingLog("-> vanilla path (PlaceBuildingIn failed)", { err = tostring(passage) })
			return original(map, pos, angle, min_dist, passages)
		end
		pcall(passage.SetPos, passage, position)
		pcall(passage.SetAngle, passage, angle)
		if type(const_tbl) == "table" and const_tbl.gofPermanent and type(passage.SetGameFlags) == "function" then
			pcall(passage.SetGameFlags, passage, const_tbl.gofPermanent)
		end
		-- Same pad sculpting vanilla does at this point ("flatten unbuildable" mode).
		if shape and type(flatten) == "function" then
			pcall(flatten, shape, passage, "flatten unbuildable")
		end
		PairingLog("-> DETERMINISTIC placement done", { position = tostring(position) })
		DebugPrint(string.format(
			"deterministic passage pairing: surface UndergroundPassage at %s (= underground marker pos, no search/random)",
			tostring(position)))
		return passage, shape
	end
	rawset(_G, "SpawnUndergroundPassage", wrapper)
	State.spawn_passage_wrapper = wrapper
	PairingLog("wrapper installed")
	DebugPrint("SpawnUndergroundPassage wrapped (deterministic passage pairing on expanded maps)")

	-- CREATOR TRAP (DEBUG_PAIRING): the SpawnUndergroundPassage wrapper was verified LIVE at
	-- the underground DoGenerate and still received ZERO calls while a surface
	-- UndergroundPassage appeared at a new random spot -- so the entrance is created through
	-- some other path. Every creation funnels through PlaceBuildingIn, so trap it there and
	-- log the CALLSTACK for UndergroundPassage placements; one run names the creator.
	local place_building = Global("PlaceBuildingIn")
	if type(place_building) == "function" and place_building ~= State.place_building_trap then
		State.original_place_building = place_building
		local trap = function(class, ...)
			if class == "UndergroundPassage" and (SuperBigMap.Config or {}).DEBUG_PAIRING == true then
				local stack = "n/a"
				pcall(function()
					if type(debug) == "table" and type(debug.traceback) == "function" then
						stack = debug.traceback("", 2)
					else
						local get_stack = Global("GetStack")
						if type(get_stack) == "function" then stack = tostring(get_stack(2)) end
					end
				end)
				PairingLog("PlaceBuildingIn(UndergroundPassage) CREATOR STACK: " .. tostring(stack))
			end
			return State.original_place_building(class, ...)
		end
		rawset(_G, "PlaceBuildingIn", trap)
		State.place_building_trap = trap
		PairingLog("PlaceBuildingIn creator trap installed")
	end

	-- LINK-TIME CORRECTION (the reliable layer). Both GLOBAL wraps were bypassed (verified
	-- live, zero calls) while the entrance kept moving -- but CLASS-method patches in this
	-- codebase demonstrably intercept vanilla (SelectSector, LandOnMars, ...). Every passage
	-- pair goes through exactly one ElevatorPassage:Link(other) at creation, with both
	-- endpoints in hand -- so correct the position THERE. On expanded games, always search from
	-- the UNDERGROUND endpoint's equivalent surface hex. If the complete Elevator footprint is
	-- buildable there, the surface passage uses that exact hex; otherwise choose the candidate
	-- with the smallest hex distance. Re-register its hex shape and clear obstructions exactly
	-- like vanilla's own spawn path does. Deterministic: the underground marker positions are
	-- proven identical across runs. Diagnostics log both endpoints and the caller stack.
	local passage_class = Engine.ClassTable and Engine.ClassTable("ElevatorPassage")
	if type(passage_class) == "table" and type(passage_class.Link) == "function"
		and passage_class.Link ~= State.passage_link_wrapper then
		State.original_passage_link = passage_class.Link
		local link_wrapper = function(self, other, ...)
			State.original_passage_link(self, other, ...)
			EntranceLinkSnapshot(self, other, "ElevatorPassage.Link after vanilla link, before SBM correction")
			local ok_fix, fix_err = pcall(function()
				local function env_of(o)
					if type(o) ~= "table" or type(o.GetMap) ~= "function" then return nil, nil end
					local ok_m, m = pcall(o.GetMap, o)
					if not ok_m or not m then return nil, nil end
					local md = m.mapdata
					return (type(md) == "table") and md.Environment or nil, m
				end
				local env_a, map_a = env_of(self)
				local env_b, map_b = env_of(other)
				local surface_obj, surface_map, under_obj
				if env_a == "Surface" and env_b == "Underground" then
					surface_obj, surface_map, under_obj = self, map_a, other
				elseif env_b == "Surface" and env_a == "Underground" then
					surface_obj, surface_map, under_obj = other, map_b, self
				end
				if not (surface_obj and under_obj) then return end
				local ok_ps, ps = pcall(surface_obj.GetPos, surface_obj)
				local ok_pu, pu = pcall(under_obj.GetPos, under_obj)
				if not (ok_ps and ok_pu and ps and pu) then return end
				local sx, sy = ps:xy()
				local ux, uy = pu:xy()
				if (SuperBigMap.Config or {}).DEBUG_PAIRING == true then
					local stack = "n/a"
					pcall(function()
						if type(debug) == "table" and type(debug.traceback) == "function" then
							stack = debug.traceback("", 3)
						end
					end)
					PairingLog("ElevatorPassage:Link", {
						surface_class = tostring(surface_obj.class), underground_class = tostring(under_obj.class),
						surface_pos = tostring(sx) .. "," .. tostring(sy),
						underground_pos = tostring(ux) .. "," .. tostring(uy),
					})
					PairingLog("Link caller stack: " .. tostring(stack))
				end
				if not cfg_bool("STRETCH_DETERMINISTIC_PASSAGES", true) then return end
				local desired = surface_map and surface_map.SuperBigMapDesiredWidthTiles
				local gen_t = surface_map and surface_map.SuperBigMapGeneratorWidthTiles
				local expanded = type(desired) == "number" and type(gen_t) == "number" and desired > gen_t
				if not expanded then return end
				-- SENTINEL FOOTPRINT PATCH (needle guard, runs for EVERY expanded pairing).
				-- Picard's post-Link flatten ("flatten unbuildable") covers the FULL extended
				-- spawn footprint; hexes at the footprint FRINGE can be unbuildable-sentinel
				-- even when the search approved the spot -- each such hex becomes one 65535
				-- needle ("crowning just before the entrance", too thin for the coarse spike
				-- audit lattice to catch). For every SENTINEL hex in the footprint, write the
				-- hex's OWN real terrain height into the buildable z-grid: the flatten then
				-- levels it to the height it already has -- a no-op. No constant-z pad, so no
				-- platform; buildable hexes keep their vanilla plateau values untouched.
				local point_fn0 = Global("point")
				local function PatchSentinelFootprint(cx0, cy0, radius_hexes, tag)
					local buildable = surface_map.buildable
					local z_grid = buildable and buildable.z_grid
					local wth = Global("WorldToHex")
					local hex_to_world = Global("HexToWorld")
					local build_unbuildable = Global("buildUnbuildableZ")
					local terrain_api0 = Global("terrain")
					if not (z_grid and type(z_grid.set) == "function" and type(wth) == "function"
						and type(hex_to_world) == "function" and type(build_unbuildable) == "function"
						and type(terrain_api0) == "table" and type(terrain_api0.GetHeight) == "function"
						and type(point_fn0) == "function") then
						PairingLog("sentinel footprint patch skipped (api unavailable)", { tag = tag })
						return
					end
					local ok_u, sentinel = pcall(build_unbuildable)
					if not ok_u then return end
					local ok_c, cq, cr = pcall(wth, point_fn0(cx0, cy0))
					if not (ok_c and type(cq) == "number") then return end
					local patched, kept = 0, 0
					local samples = {}
					for dq = -radius_hexes, radius_hexes do
						for dr = -radius_hexes, radius_hexes do
							local dist = (math.abs(dq) + math.abs(dr) + math.abs(dq + dr)) / 2
							if dist <= radius_hexes then
								local q, r = cq + dq, cr + dr
								local ok_z, bz = pcall(buildable.GetZ, buildable, q, r)
								if ok_z and bz == sentinel then
									local okw, hx, hy = pcall(hex_to_world, q, r)
									if okw and type(hx) == "number" then
										local okh, tz = pcall(terrain_api0.GetHeight, surface_map, point_fn0(hx, hy))
										if okh and type(tz) == "number" then
											local ok_s = pcall(z_grid.set, z_grid, q + math.floor(r / 2), r, tz)
											if ok_s then
												patched = patched + 1
												if #samples < 6 then
													samples[#samples + 1] = string.format("(%+d,%+d)z=%d", dq, dr, tz)
												end
											end
										end
									end
								elseif ok_z then
									kept = kept + 1
								end
							end
						end
					end
					PairingLog("sentinel footprint patch", {
						tag = tostring(tag), center = tostring(cx0) .. "," .. tostring(cy0),
						radius = radius_hexes, sentinel_patched = patched, buildable_kept = kept,
						samples = table.concat(samples, " "),
					})
				end
				-- Footprint radius from the actual spawn shape (max hex distance + margin).
				local footprint_radius = 8
				do
					local get_shape0 = Global("GetExtendedSpawnShape")
					if type(get_shape0) == "function" then
						local ok_sh0, shp0 = pcall(get_shape0, "Elevator")
						if ok_sh0 and type(shp0) == "table" then
							local maxd = 0
							for _, hexpt in ipairs(shp0) do
								local ok_xy0, hq, hr = pcall(function() return hexpt:x(), hexpt:y() end)
								if ok_xy0 and type(hq) == "number" then
									local d0 = (math.abs(hq) + math.abs(hr) + math.abs(hq + hr)) / 2
									if d0 > maxd then maxd = d0 end
								end
							end
							if maxd > 0 then footprint_radius = maxd + 2 end
						end
					end
				end
				-- EXACT-HEX-FIRST SEARCH (no terrain edits). One HexGridFindBuildable call tests
				-- the equivalent surface hex first and expands outward by hex distance. Use our own
				-- footprint filter instead of FindBuildableAreaAround: vanilla keeps the first
				-- candidate elevation in a closure for the whole search, so a rejected mountain/cliff
				-- elevation can prevent a later, nearby buildable elevation from ever being accepted.
				-- Here every candidate independently establishes its own required flat elevation.
				-- Mountains/cliffs are rejected through the buildable grid and decorations/
				-- structures through object_hex_grid without manufacturing a terrain platform.
				local point_fn = Global("point")
				local native_find = Global("HexGridFindBuildable")
				local hex_to_world = Global("HexToWorld")
				local validate_shape = Global("ValidateEachShapeHexPos")
				local get_unbuildable = Global("buildUnbuildableZ")
				local get_shape = Global("GetExtendedSpawnShape")
				if type(point_fn) ~= "function" or type(native_find) ~= "function"
					or type(hex_to_world) ~= "function" or type(validate_shape) ~= "function"
					or type(get_unbuildable) ~= "function" or type(get_shape) ~= "function" then
					PairingLog("near-marker search unavailable -- vanilla placement kept", {
						native_find = tostring(type(native_find)),
						validate_shape = tostring(type(validate_shape)),
					})
					return
				end
				local ok_shp, espace = pcall(get_shape, "Elevator")
				if not (ok_shp and espace) then
					PairingLog("near-marker search: no spawn shape -- vanilla placement kept")
					return
				end
				local ok_ang, angle = pcall(surface_obj.GetAngle, surface_obj)
				angle = (ok_ang and angle) or 0
				local hex_grid = surface_map.object_hex_grid
				local buildable = surface_map.buildable
				if not (buildable and buildable.z_grid and type(buildable.GetZ) == "function") then
					PairingLog("near-marker search: buildable grid unavailable -- vanilla placement kept")
					return
				end
				local found_x, found_y, found_depth, found_hex_dist = nil, nil, nil, nil
				local attempts = 1
				local world_to_hex = Global("WorldToHex")
				local marker_q, marker_r
				if type(world_to_hex) == "function" then
					local ok_mh, mq, mr = pcall(world_to_hex, point_fn(ux, uy))
					if ok_mh and type(mq) == "number" and type(mr) == "number" then
						marker_q, marker_r = mq, mr
					end
				end
				if marker_q == nil then
					PairingLog("near-marker search: WorldToHex unavailable -- vanilla placement kept")
					return
				end
				local ok_uz, unbuildable_z = pcall(get_unbuildable)
				if not (ok_uz and type(unbuildable_z) == "number") then
					PairingLog("near-marker search: unbuildable sentinel unavailable -- vanilla placement kept")
					return
				end
				local candidates_checked = 0
				local footprint_hexes_checked = 0
				local function candidate_rejected(q, r)
					candidates_checked = candidates_checked + 1
					local candidate_z = false
					local function footprint_hex_valid(x, y)
						footprint_hexes_checked = footprint_hexes_checked + 1
						local z = buildable:GetZ(x, y)
						if z == unbuildable_z then return false end
						candidate_z = candidate_z or z
						if z ~= candidate_z then return false end
						local obstructions = hex_grid and hex_grid:GetBuildObstructions(x, y)
						if obstructions and #obstructions > 0 then return false end
						return true
					end
					local candidate_pos = point_fn(hex_to_world(q, r))
					return validate_shape(espace, candidate_pos, angle, footprint_hex_valid) ~= true
				end
				local profiler = SuperBigMap.LoadingProfiler
				local search_token = profiler and type(profiler.Begin) == "function" and profiler.Begin(
					"entrance alignment: native nearest-footprint search", {
						target_x = ux, target_y = uy,
						algorithm = "single HexGridFindBuildable + candidate-local footprint",
					}, surface_map) or false
				local ok_f, fx, fy, fd, result_q, result_r = pcall(function()
					local bq, br, depth = native_find(marker_q, marker_r, hex_grid,
						buildable.z_grid, unbuildable_z, candidate_rejected)
					if bq == nil then return end
					local x, y = hex_to_world(bq, br)
					return x, y, depth, bq, br
				end)
				local search_ok = ok_f and type(fx) == "number" and type(fy) == "number"
				if search_token and type(profiler.End) == "function" then
					profiler.End(search_token, {
						found = search_ok, result_x = search_ok and fx or nil,
						result_y = search_ok and fy or nil, result_q = result_q, result_r = result_r,
						candidates_checked = candidates_checked,
						footprint_hexes_checked = footprint_hexes_checked,
						error = not ok_f and tostring(fx) or nil,
					}, search_ok)
				end
				if search_ok then
					found_x, found_y, found_depth = fx, fy, fd
					if marker_q and type(world_to_hex) == "function" then
						local ok_ch, cq, cr = pcall(world_to_hex, point_fn(fx, fy))
						if ok_ch and type(cq) == "number" and type(cr) == "number" then
							local dq, dr = cq - marker_q, cr - marker_r
							found_hex_dist = (math.abs(dq) + math.abs(dr) + math.abs(dq + dr)) / 2
						end
					end
				end
				local exact_hex = found_hex_dist == 0
				if not found_x then
					PairingLog("near-marker search FAILED -- vanilla placement kept", {
						attempts = attempts, algorithm = "single-native-candidate-local-search",
						candidates_checked = candidates_checked,
						marker = tostring(ux) .. "," .. tostring(uy),
						error = not ok_f and tostring(fx) or nil,
					})
					return
				end
				local np = point_fn(found_x, found_y, found_depth)
				if type(surface_map.SnapToTerrain) == "function" then
					local ok_s, snapped = pcall(surface_map.SnapToTerrain, surface_map, np)
					if ok_s and snapped then np = snapped end
				end
				local hex_remove = Global("HexGridShapeRemoveObject")
				local hex_add = Global("HexGridShapeAddObject")
				local is_valid_fn = Global("IsValid")
				local shape
				if hex_grid and type(hex_remove) == "function" and type(hex_add) == "function"
					and (type(is_valid_fn) ~= "function" or is_valid_fn(surface_obj) == true)
					and type(surface_obj.handle) == "number" and surface_obj.handle > 0
					and type(surface_obj.GetShapePoints) == "function" then
					local ok_sh, sh = pcall(surface_obj.GetShapePoints, surface_obj)
					if ok_sh and sh then shape = sh end
				end
				-- Registration pre-check: luaHex asserts (uncatchable) on removing an object
				-- that is not actually registered at its cells; verify first, and if not
				-- registered skip the remove but still add after the move (desired end state).
				local was_registered = false
				if shape then
					local hex_list = Global("HexGridShapeGetObjectList")
					if type(hex_list) == "function" then
						local ok_l, list = pcall(hex_list, hex_grid, surface_obj, shape)
						if ok_l and type(list) == "table" then
							for _, o2 in ipairs(list) do
								if o2 == surface_obj then was_registered = true break end
							end
						end
					end
					if not was_registered then
						PairingLog("hex re-reg pre-check: passage NOT registered at its cells -- remove skipped", {
							handle = tostring(surface_obj.handle),
						})
					end
				end
				if shape and was_registered then pcall(hex_remove, hex_grid, surface_obj, shape) end
				local ok_set = pcall(surface_obj.SetPos, surface_obj, np)
				local rehexed = false
				if shape then rehexed = pcall(hex_add, hex_grid, surface_obj, shape) == true end
				-- Obstruction clearing, exactly as vanilla does after its own placement.
				local clear = Global("ClearObstructions")
				if type(clear) == "function" then
					pcall(clear, surface_map, np, angle, surface_map.obj_prefab_marker, nil, espace)
				end
				-- Needle guard at the relocated position (before Picard's post-Link flatten).
				PatchSentinelFootprint(found_x, found_y, footprint_radius, "relocated-placement")
				-- Remember the pad for the post-generation smoothing pass.
				State.sbm_entrance_pads = State.sbm_entrance_pads or {}
				table.insert(State.sbm_entrance_pads, {
					map = surface_map, x = found_x, y = found_y, hex_radius = footprint_radius,
				})
				local fdx, fdy = found_x - ux, found_y - uy
				PairingLog("LINK-TIME CORRECTION: surface entrance aligned to underground exit hex", {
					from = tostring(sx) .. "," .. tostring(sy),
					marker = tostring(ux) .. "," .. tostring(uy),
					to = tostring(found_x) .. "," .. tostring(found_y),
					exact_hex = exact_hex, hex_distance = tostring(found_hex_dist),
					dist_from_marker = math.floor(math.sqrt(fdx * fdx + fdy * fdy + 0.0) + 0.5),
					attempts = attempts, algorithm = "single-native-candidate-local-search",
					candidates_checked = candidates_checked,
					moved = ok_set, rehexed = rehexed,
				})
			end)
			if not ok_fix then
				PairingLog("Link correction ERROR", { err = tostring(fix_err) })
			end
			EntranceLinkSnapshot(self, other, "ElevatorPassage.Link after SBM correction")
			EntranceSnapshot("passage link completed", nil)
		end
		passage_class.Link = link_wrapper
		State.passage_link_wrapper = link_wrapper
		PairingLog("ElevatorPassage:Link wrapped (link-time correction)")
	end
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
		and generator_class.DoGenerate == State.generator_do_generate_wrapper
		and generator_class.ProcStart == State.generator_proc_start_wrapper
		and generator_class.ProcEnd == State.generator_proc_end_wrapper then
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
	if generator_class.ProcStart ~= State.generator_proc_start_wrapper then
		State.generator_original_proc_start = generator_class.ProcStart
	end
	if generator_class.ProcEnd ~= State.generator_proc_end_wrapper then
		State.generator_original_proc_end = generator_class.ProcEnd
	end
	local original_generate = State.generator_original_generate
	local original_do_generate = State.generator_original_do_generate
	local original_proc_start = State.generator_original_proc_start
	local original_proc_end = State.generator_original_proc_end

	-- GenRand instrumentation: per-proc rand-stream fingerprints (see helpers above).
	-- ProcInvoke re-seeds the PRNG (rand_state:Set(xxhash(Seed, tag))) right BEFORE
	-- ProcStart, so ProcStart logs the fresh per-proc seed state and ProcEnd logs the
	-- last value the proc consumed -- its stream fingerprint.
	if type(original_proc_start) == "function" then
		local proc_start_wrapper = function(self, tag, ...)
			if GenRandEnabled() then
				local seed = "n/a"
				if type(self.ProcSeed) == "function" then
					local ok, s = pcall(self.ProcSeed, self, tag)
					if ok then seed = s end
				end
				local md = State.genrand_active_mapdata
				GenRandLog(string.format("ProcStart %-24s seed=%s rand_last=%s passborder=%s mapdata_w=%s",
					tostring(tag), tostring(seed), tostring(GenRandLast(self)),
					tostring(md and md.PassBorder), tostring(md and md.Width)))
			end
			return original_proc_start(self, tag, ...)
		end
		generator_class.ProcStart = proc_start_wrapper
		State.generator_proc_start_wrapper = proc_start_wrapper
	end
	if type(original_proc_end) == "function" then
		local proc_end_wrapper = function(self, tag, ...)
			if GenRandEnabled() then
				GenRandLog(string.format("ProcEnd   %-24s rand_last=%s   <-- fingerprint",
					tostring(tag), tostring(GenRandLast(self))))
			end
			return original_proc_end(self, tag, ...)
		end
		generator_class.ProcEnd = proc_end_wrapper
		State.generator_proc_end_wrapper = proc_end_wrapper
	end
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

			-- Map fits the vanilla generator: run completely untouched (but instrumented
			-- when GenRand debugging is on -- this path IS the vanilla baseline run).
			if cur_w_tiles <= max_random_tiles and cur_h_tiles <= max_random_tiles then
				if GenRandEnabled() then
					State.genrand_active_mapdata = mapdata or template or false
					GenRandLog("DoGenerate begin (NATIVE-size run, vanilla baseline)", GenRandInputs(self, map))
					local profiler = SuperBigMap.LoadingProfiler
					local load_token = profiler and type(profiler.Begin) == "function" and profiler.Begin(
						"RandomMapGenerator.DoGenerate native body",
						{ blank = tostring(self.BlankMap), detected_width_tiles = cur_w_tiles,
							detected_height_tiles = cur_h_tiles }, map) or false
					local results = { pcall(original_do_generate, self, map, ...) }
					if load_token and type(profiler.End) == "function" then
						profiler.End(load_token, { result_count = #results - 1,
							error = results[1] and nil or tostring(results[2]) }, results[1] == true)
					end
					State.genrand_active_mapdata = false
					if not results[1] then
						GenRandLog("DoGenerate FAILED (native)", { err = tostring(results[2]) })
						error(results[2])
					end
					GenRandCensus(map, "post-gen NATIVE")
					return Unpack(results, 2)
				end
				local profiler = SuperBigMap.LoadingProfiler
				local load_token = profiler and type(profiler.Begin) == "function" and profiler.Begin(
					"RandomMapGenerator.DoGenerate native body",
					{ blank = tostring(self.BlankMap), detected_width_tiles = cur_w_tiles,
						detected_height_tiles = cur_h_tiles }, map) or false
				if not load_token then return original_do_generate(self, map, ...) end
				local function complete(...)
					profiler.End(load_token, { result_count = select("#", ...) }, true)
					return ...
				end
				return complete(original_do_generate(self, map, ...))
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

			-- VANILLA-EXACT PLAY ZONE: PrepareMapDataForQuadrantCopy zeroed mapdata.PassBorder
			-- BEFORE ChangeMap so the engine bakes full passability (frame reachable). But the
			-- generator ALSO reads map.mapdata.PassBorder to compute its play zone
			-- (RandomMapGenerator GetPlayableArea x2, BiomeFiller POI frame) -- with 0 instead
			-- of the native ~1024-tile border the play zone is BIGGER than vanilla, the
			-- placement masks differ, and the per-proc rand stream diverges: the same seed
			-- placed the same lake prefab at a different position/rotation. The engine consumed
			-- PassBorder at ChangeMap (before DoGenerate), so restoring the ORIGINAL value for
			-- just this DoGenerate window gives the generator vanilla-identical inputs while
			-- the baked passability stays border-free. Restored (re-zeroed) below.
			local saved_mapdata_pb, saved_mapdata_pbt, saved_template_pb, saved_template_pbt
			if cfg_bool("STRETCH_VANILLA_EXACT_PASSBORDER", true) then
				local orig_pb = (type(mapdata) == "table" and mapdata.SuperBigMapOriginalPassBorder)
					or (template and template.SuperBigMapOriginalPassBorder)
				if type(orig_pb) == "number" and orig_pb > 0 then
					if type(mapdata) == "table" and mapdata.PassBorder ~= orig_pb then
						saved_mapdata_pb = mapdata.PassBorder
						saved_mapdata_pbt = mapdata.PassBorderTiles
						mapdata.PassBorder = orig_pb
						if type(mapdata.PassBorderTiles) == "number" then
							mapdata.PassBorderTiles = math.floor(orig_pb / height_tile_size)
						end
					end
					if template and template ~= mapdata and template.PassBorder ~= orig_pb then
						saved_template_pb = template.PassBorder
						saved_template_pbt = template.PassBorderTiles
						template.PassBorder = orig_pb
						if type(template.PassBorderTiles) == "number" then
							template.PassBorderTiles = math.floor(orig_pb / height_tile_size)
						end
					end
					DebugPrint(string.format(
						"vanilla-exact play zone: PassBorder %s -> %s for the DoGenerate window (re-zeroed after)",
						tostring(saved_mapdata_pb), tostring(orig_pb)))
				end
			end

			-- Terrain-safe placement auto-fit: relax the deposit/anomaly placement
			-- margins + spacing (placement-only knobs; never touch gen_zone/terrain)
			-- so the full preset counts seat in the smaller expanded play_zone. Sizes
			-- are already overridden here, so coverage is measured over the generated
			-- span. Restored in End() below, regardless of success.
			-- (In STRETCH mode Begin() self-skips: bit-identical generation required.)
			local placement = SuperBigMap.RmgPlacement
			local placement_active = placement and placement.Begin(self, map) or false

			if GenRandEnabled() then
				State.genrand_active_mapdata = mapdata or template or false
				GenRandLog("DoGenerate begin (EXPANDED run, capped sizes)", GenRandInputs(self, map))
			end

			-- JUST-IN-TIME pairing-wrapper verification: the passage pairing runs INSIDE the
			-- underground map's DoGenerate (Picard PlaceArtefacts_Passages), and anything can
			-- have redefined the global since module load (a v434 run had the install line but
			-- ZERO pairing calls). Verify + reinstall right here, and log the verdict.
			do
				local live = Global("SpawnUndergroundPassage")
				local was_installed = live ~= nil and live == State.spawn_passage_wrapper
				if not was_installed then
					PatchPassagePairing()
				end
				local live2 = Global("SpawnUndergroundPassage")
				PairingLog("wrapper status at DoGenerate", {
					blank = tostring(self.BlankMap),
					was_installed = was_installed,
					now_installed = live2 ~= nil and live2 == State.spawn_passage_wrapper,
					global_type = tostring(type(live)),
				})
			end

			-- DETERMINISTIC ENTRANCE PAIRING, the no-terrain-touching way (config
			-- PAIRING_SURFACE_BUILDABLE_REBUILD). The entrance pairing runs INSIDE the
			-- UNDERGROUND generation: vanilla searches MainMap's BUILDABLE grid around each
			-- underground marker and falls back to a RANDOM position when the search fails.
			-- On expanded maps the surface buildable grid is STALE at that moment (built from
			-- the blank map; the async "Buildable grid ready" rebuild lands seconds later), so
			-- the search sometimes fails -> random fallback -> an entrance at a different spot
			-- per restart. Rebuilding the surface buildable grid RIGHT HERE -- synchronously,
			-- from the fully generated surface terrain, before the underground generation --
			-- makes the search inputs deterministic: same terrain, same grid, same marker
			-- positions => the SAME all-buildable spot every run, vanilla's own clean flatten,
			-- zero terrain interference from the mod. (The forced-position correction chain of
			-- v437-v441 stays retired: forcing spots the grid calls unbuildable is what
			-- produced the spike artifacts.)
			if cfg_bool("PAIRING_SURFACE_BUILDABLE_REBUILD", true) then
				local env = (type(mapdata) == "table" and mapdata.Environment)
					or (template and template.Environment)
				if env == "Underground" then
					local main_map = Global("MainMap")
					local rebuild = Global("RebuildBuildableGrid")
					if main_map and main_map ~= map and type(rebuild) == "function" and main_map.buildable then
						local t0 = 0
						local ticks = Global("GetPreciseTicks")
						if type(ticks) == "function" then local okt, t = pcall(ticks); if okt then t0 = t end end
						local ok_rb, err_rb = pcall(rebuild, main_map)
						local t1 = t0
						if type(ticks) == "function" then local okt, t = pcall(ticks); if okt then t1 = t end end
						DebugPrint(string.format(
							"surface buildable grid rebuilt before underground generation (deterministic entrance pairing): ok=%s ms=%s%s",
							tostring(ok_rb), tostring(t1 - t0), ok_rb and "" or (" err=" .. tostring(err_rb))))
					end
				end
			end

			local LT = SuperBigMap.DebugLog and SuperBigMap.DebugLog.LoadTime
			if LT then LT("DoGenerate: vanilla generator begin", { blank = tostring(self.BlankMap) }) end
			local profiler = SuperBigMap.LoadingProfiler
			local load_token = profiler and type(profiler.Begin) == "function" and profiler.Begin(
				"RandomMapGenerator.DoGenerate vanilla body",
				{ blank = tostring(self.BlankMap), detected_width_tiles = cur_w_tiles,
					detected_height_tiles = cur_h_tiles, generator_width_tiles = gen_width_tiles,
					generator_height_tiles = gen_height_tiles }, map) or false
			EntranceSnapshot("DoGenerate before vanilla generator: " .. tostring(self.BlankMap), map)
			local results = { pcall(original_do_generate, self, map, ...) }
			EntranceSnapshot("DoGenerate after vanilla generator: " .. tostring(self.BlankMap), map)
			if load_token and type(profiler.End) == "function" then
				profiler.End(load_token, { result_count = #results - 1,
					error = results[1] and nil or tostring(results[2]) }, results[1] == true)
			end
			if LT then LT("DoGenerate: vanilla generator end", { ok = results[1] == true }) end

			State.genrand_active_mapdata = false

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
				if saved_template_pb ~= nil then
					template.PassBorder = saved_template_pb
					template.PassBorderTiles = saved_template_pbt
				end
			end
			if type(mapdata) == "table" then
				mapdata.Width = saved_mapdata_w
				mapdata.Height = saved_mapdata_h
				if saved_mapdata_pb ~= nil then
					mapdata.PassBorder = saved_mapdata_pb
					mapdata.PassBorderTiles = saved_mapdata_pbt
				end
			end

			if not results[1] then
				if GenRandEnabled() then
					GenRandLog("DoGenerate FAILED (expanded)", { err = tostring(results[2]) })
				end
				error(results[2])
			end
			-- POST-GENERATION PAD SMOOTHING (config PASSAGE_PAD_SMOOTHING). The generator's
			-- entrance flatten is PER-HEX -- one height per hex -- so even with clean values it
			-- leaves faint hex terracing (zigzag creases) around the entrances. After the
			-- generator has fully finished (nothing re-flattens after this), smooth the height
			-- field around each remembered entrance footprint with the engine's own GridSmooth
			-- (the same op the map generator uses for terrain filtering). Runs PRE-stretch, so
			-- the stretch resample carries the smoothed ground to the final map. One height-grid
			-- get/set for all pads (~1-2s during loading).
			do
				local pads = State.sbm_entrance_pads
				if type(pads) == "table" and #pads > 0 and cfg_bool("PASSAGE_PAD_SMOOTHING", true) then
					local terrain_api3 = Global("terrain")
					local grid_to_compute = Global("GridToCompute")
					local new_grid = Global("NewComputeGrid")
					local is_compute = Global("IsComputeGrid")
					local grid_smooth = Global("GridSmooth")
					local box_fn3 = Global("box")
					local point_fn3 = Global("point")
					local const_tbl3 = Global("const")
					local tile3 = (type(const_tbl3) == "table" and type(const_tbl3.HeightTileSize) == "number"
						and const_tbl3.HeightTileSize > 0) and const_tbl3.HeightTileSize or 100
					local hex3 = (type(const_tbl3) == "table" and type(const_tbl3.HexSize) == "number"
						and const_tbl3.HexSize > 0) and const_tbl3.HexSize or 1000
					local function free_grid3(g)
						if g then pcall(function() if type(g.free) == "function" then g:free() end end) end
					end
					if type(terrain_api3) == "table" and type(terrain_api3.GetHeightGrid) == "function"
						and type(terrain_api3.SetHeightGrid) == "function" and type(grid_smooth) == "function"
						and type(grid_to_compute) == "function" and type(new_grid) == "function"
						and type(box_fn3) == "function" and type(point_fn3) == "function" then
						-- All pads are on the same (surface) map in practice; group by map anyway.
						local by_map = {}
						for _, pad in ipairs(pads) do
							if pad.map then
								by_map[pad.map] = by_map[pad.map] or {}
								table.insert(by_map[pad.map], pad)
							end
						end
						for pmap, plist in pairs(by_map) do
							local ok_all, err_all = pcall(function()
								local raw = terrain_api3.GetHeightGrid(pmap)
								local full = grid_to_compute(raw)
								local fw, fh = full:size()
								local fmt, bits
								if type(is_compute) == "function" then
									fmt, bits = is_compute(full)
								end
								fmt = fmt or "F"
								for _, pad in ipairs(plist) do
									-- +10 hexes: the outer ~30 tiles are the FEATHER band (see below),
								-- so the footprint itself stays inside the fully-smoothed core.
								local radius_wu = ((pad.hex_radius or 10) + 10) * hex3
									local r_tiles = math.floor(radius_wu / tile3 + 0.5)
									local cx_t = math.floor(pad.x / tile3 + 0.5)
									local cy_t = math.floor(pad.y / tile3 + 0.5)
									local x0 = math.max(0, cx_t - r_tiles)
									local y0 = math.max(0, cy_t - r_tiles)
									local x1 = math.min(fw, cx_t + r_tiles)
									local y1 = math.min(fh, cy_t + r_tiles)
									local w, h = x1 - x0, y1 - y0
									if w > 4 and h > 4 then
										local region = new_grid(w, h, fmt, bits)
										region:copyrect(full, box_fn3(x0, y0, x1, y1), point_fn3(0, 0))
										local smoothed = new_grid(w, h, fmt, bits)
										local ok_s, err_s = pcall(grid_smooth, region, smoothed, 3)
										local blended = 0
										if ok_s then
											-- FEATHER the region edge: a hard copyrect boundary
											-- between smoothed interior and untouched exterior
											-- reads as a straight LINE on the ground (user
											-- report). Blend an edge band: original terrain at
											-- the border -> fully smoothed at band depth, so the
											-- transition is gradual and invisible. Integer math:
											-- multiply before dividing (engine Lua truncates).
											local BAND = 30 -- tiles (~3000 wu)
											local pause3 = Global("PauseInfiniteLoopDetection")
											local resume3 = Global("ResumeInfiniteLoopDetection")
											if type(pause3) == "function" then pcall(pause3, "SBMPadFeather") end
											local ok_f, err_f = pcall(function()
												for yy = 0, h - 1 do
													local dy0 = math.min(yy, h - 1 - yy)
													for xx = 0, w - 1 do
														local dd = math.min(xx, w - 1 - xx, dy0)
														if dd < BAND then
															local ov = region:get(xx, yy)
															local sv = smoothed:get(xx, yy)
															if type(ov) == "number" and type(sv) == "number" then
																smoothed:set(xx, yy, ov + (sv - ov) * dd / BAND)
																blended = blended + 1
															end
														end
													end
												end
											end)
											if type(resume3) == "function" then pcall(resume3, "SBMPadFeather") end
											if not ok_f then
												PairingLog("pad feather ERROR", { err = tostring(err_f) })
											end
											full:copyrect(smoothed, box_fn3(0, 0, w, h), point_fn3(x0, y0))
										end
										free_grid3(region)
										free_grid3(smoothed)
										PairingLog("post-gen pad smoothing", {
											x = pad.x, y = pad.y, region = tostring(w) .. "x" .. tostring(h),
											smoothed = ok_s, feathered_cells = blended,
											err = ok_s and nil or tostring(err_s),
										})
									end
								end
								terrain_api3.SetHeightGrid(pmap, full)
								if type(terrain_api3.InvalidateHeight) == "function" then
									pcall(terrain_api3.InvalidateHeight, pmap)
								end
								if full ~= raw then free_grid3(full) end
							end)
							if not ok_all then
								PairingLog("post-gen pad smoothing ERROR", { err = tostring(err_all) })
							end
						end
					end
					-- Consumed: never smooth stale pads on a later generation/new game.
					State.sbm_entrance_pads = nil
				end
			end
			GenRandCensus(map, "post-gen EXPANDED (pre-stretch)")
			-- Spike audits (DEBUG_SPIKES): the generated map, and -- after the UNDERGROUND
			-- generation, which is when the passage pairing touches MainMap -- the surface too.
			SpikeAudit(map, "post-gen " .. tostring(self.BlankMap))
			do
				local main_map = Global("MainMap")
				if main_map and main_map ~= map then
					SpikeAudit(main_map, "post-gen(" .. tostring(self.BlankMap) .. ") MainMap")
				end
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
		if cfg_bool("OPTIMIZE_STRETCH_DEFERRED_REBUILDS", true) then
			map.SuperBigMapStretchPipelinePending = true
		end
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
			SetLoadingPhase("Expanding the surface map")
		end
		local function end_loading()
			-- Fail-safe: if the stretch exited before its final lightweight refresh, restore the
			-- original full rebuild path rather than leave partially refreshed map state.
			if map.SuperBigMapStretchPipelinePending == true then
				local lifecycle = SuperBigMap.Lifecycle
				if lifecycle and type(lifecycle.Apply) == "function" then
					SafeCall(lifecycle.Apply, map, true)
				end
				map.SuperBigMapStretchPipelinePending = false
				local profiler = SuperBigMap.LoadingProfiler
				if profiler and type(profiler.Step) == "function" then
					profiler.Step("stretch optimization: fallback full rebuild", { phase = "surface exit" }, map)
				end
			end
			if SuperBigMap.DebugLog and SuperBigMap.DebugLog.LoadTime then
				SuperBigMap.DebugLog.LoadTime("loading box torn down (expansion path finished)")
			end
			if type(SuperBigMap.ExpansionLoadingEnd) == "function" then
				SuperBigMap.ExpansionLoadingEnd()
			end
		end
		local loading_profiler = SuperBigMap.LoadingProfiler
		local waited = 0
		local f0_token = loading_profiler and type(loading_profiler.Begin) == "function"
			and loading_profiler.Begin("surface readiness: wait for F0 sector", { max_wait_ms = 15000 }, map) or false
		for _ = 1, 60 do
			if FindSectorByName(map, "F0") then
				break
			end
			sleep(250)
			waited = waited + 250
		end
		if f0_token and type(loading_profiler.End) == "function" then
			loading_profiler.End(f0_token, { waited_ms = waited,
				f0_found = FindSectorByName(map, "F0") ~= nil }, true)
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
			local settle_token = loading_profiler and type(loading_profiler.Begin) == "function"
				and loading_profiler.Begin("surface readiness: fixed settle", { settle_ms = settle_ms }, map) or false
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
			if settle_token and type(loading_profiler.End) == "function" then
				loading_profiler.End(settle_token, { configured_ms = settle_ms }, true)
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
			EntranceSnapshot("surface stretch begin", map)
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
			local frame_passability_preapplied = false
			local stretch_token = loading_profiler and type(loading_profiler.Begin) == "function"
				and loading_profiler.Begin("surface expansion: complete stretch pipeline", {
					fill_mode = fill_mode, settle_ms = settle_ms,
				}, map) or false
			local ok_branch, branch_err = pcall(function()
				if type(StretchSourceToFull) == "function" then
					-- Relief annotations MUST be captured BEFORE the terrain stretch (they record
					-- each object's relationship to the PRE-stretch ground).
					if type(AnnotateDecorRelief) == "function" then
						StretchLog("stretch branch: -> AnnotateDecorRelief")
						AnnotateDecorRelief(map)
					end
					if cfg_bool("OPTIMIZE_STRETCH_PASSABILITY", true) then
						StretchLog("stretch branch: pre-applying frame passability before authoritative revalidation")
						local pass_token = loading_profiler and type(loading_profiler.Begin) == "function"
							and loading_profiler.Begin("surface passability: preapply frame overlay", nil, map) or false
						frame_passability_preapplied = SafeCall(ForceFramePassable, map, true) == true
						if pass_token and type(loading_profiler.End) == "function" then
							loading_profiler.End(pass_token, {
								applied = frame_passability_preapplied,
							}, frame_passability_preapplied)
						end
					end
					SpikeAudit(map, "surface pre-stretch")
					SetLoadingPhase("Stretching the surface terrain")
					StretchLog("stretch branch: -> StretchSourceToFull")
					ok_stretch, n_grids = StretchSourceToFull(map, false)
					StretchLog("stretch branch: StretchSourceToFull returned", { ok = ok_stretch, grids = n_grids })
					SpikeAudit(map, "surface post-StretchSourceToFull")
				else
					StretchLog("stretch branch: StretchSourceToFull MISSING")
					DebugPrint("RunSectorMirrorPlanIfEnabled: STRETCH unavailable (TerrainCopy.StretchSourceToFull missing) -- terrain left as generated")
				end
				-- Step 2: reposition + scale the generated decorations onto the stretched terrain
				-- (must run AFTER the height stretch so SetTerrainZ reads the new surface).
				if type(ScaleDecorationsToFull) == "function" then
					SetLoadingPhase("Repositioning surface rocks and decorations")
					StretchLog("stretch branch: -> ScaleDecorationsToFull")
					local n_dec = ScaleDecorationsToFull(map, false)
					StretchLog("stretch branch: ScaleDecorationsToFull returned", { moved = n_dec })
					SpikeAudit(map, "surface post-ScaleDecorations")
				end
				-- Step 3: move the deposit/anomaly/effect markers to their scaled spots too
				-- (config STRETCH_SCALE_MARKERS) -- same transform, positions only.
				if type(ScaleMarkersToFull) == "function" then
					SetLoadingPhase("Repositioning surface resource deposits")
					StretchLog("stretch branch: -> ScaleMarkersToFull")
					local n_mark = ScaleMarkersToFull(map, false)
					StretchLog("stretch branch: ScaleMarkersToFull returned", { moved = n_mark })
					EntranceSnapshot("surface after ScaleMarkersToFull", map)
				end
				-- Step 3b: move the entrance VISUALS (signs/structures/spawners -- skipped by the
				-- decor pass) with the same transform, so what the player SEES matches the markers.
				if type(MoveEntranceVisualsToScale) == "function" then
					SetLoadingPhase("Aligning the underground entrances")
					StretchLog("stretch branch: -> MoveEntranceVisualsToScale")
					local n_vis = MoveEntranceVisualsToScale(map)
					StretchLog("stretch branch: MoveEntranceVisualsToScale returned", { moved = n_vis })
					EntranceSnapshot("surface after MoveEntranceVisualsToScale", map)
					SpikeAudit(map, "surface post-MoveEntranceVisuals")
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
				-- START SECTOR: when the InitialExplore wrapper deferred the vanilla pick
				-- (STRETCH_VANILLA_START_SECTOR), reveal the winner's x4/3 block NOW -- the
				-- markers are at their scaled positions, so Scan spawns deposits correctly.
				-- Mutually exclusive with the legacy relocation (which would re-scale a
				-- freshly scanned sector).
				local vanilla_start_pending = (SuperBigMap.State or {}).sbm_vanilla_start ~= nil
				if vanilla_start_pending then
					local sectors_mod = SuperBigMap.SectorExploration
					if sectors_mod and type(sectors_mod.RevealVanillaStartSectors) == "function" then
						StretchLog("stretch branch: -> RevealVanillaStartSectors (vanilla-equivalent start)")
						local n_rev = SafeCall(sectors_mod.RevealVanillaStartSectors, map)
						StretchLog("stretch branch: RevealVanillaStartSectors returned", { scanned = n_rev })
					end
				elseif type(StretchRelocateStartSector) == "function" then
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
						SetLoadingPhase("Distributing surface resources and anomalies")
						if type(deposits.TopUpDeposits) == "function" then
							StretchLog("stretch branch: -> TopUpDeposits")
							SafeCall(deposits.TopUpDeposits, map)
						end
						-- TopUpAnomalies: post-gen replacement for the in-generation anomaly count
						-- scaling (which shifted the generator's random stream and made expanded
						-- layouts diverge from vanilla). BEFORE RespaceAnomalies so clones get
						-- spaced too.
						if type(deposits.TopUpAnomalies) == "function" then
							StretchLog("stretch branch: -> TopUpAnomalies")
							SafeCall(deposits.TopUpAnomalies, map)
						end
						if type(deposits.TopUpEffectDeposits) == "function" then
							StretchLog("stretch branch: -> TopUpEffectDeposits")
							SafeCall(deposits.TopUpEffectDeposits, map)
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
						if type(deposits.ClearTopUpPlacementPool) == "function" then
							deposits.ClearTopUpPlacementPool(map)
						end
					end
				end
				local function now2()
					if type(stretch_ticks) == "function" then local ok, t = pcall(stretch_ticks); if ok and type(t) == "number" then return t end end
					return 0
				end
				local ft = now2()
				SpikeAudit(map, "surface post-density-suite")
				SetLoadingPhase("Rebuilding the surface build grid")
				StretchLog("stretch branch: -> RebuildBuildableGrid")
				local rebuild_buildable = Global("RebuildBuildableGrid")
				local buildable_already_rebuilt = cfg_bool("OPTIMIZE_STRETCH_REVALIDATION", true)
					and map.SuperBigMapRevalidationRebuiltGrids == true
				if buildable_already_rebuilt then
					StretchLog("stretch branch: RebuildBuildableGrid already completed by consolidated revalidation -- skip duplicate")
				elseif type(rebuild_buildable) == "function" and map and map.buildable then
					SafeCall(rebuild_buildable, map)
				end
				StretchLog("TIMING: RebuildBuildableGrid", { ms = now2() - ft }); ft = now2()
				local passability_already_baked = cfg_bool("OPTIMIZE_STRETCH_PASSABILITY", true)
					and frame_passability_preapplied and ok_stretch
				if passability_already_baked then
					StretchLog("stretch branch: frame passability already applied before authoritative revalidation -- skip duplicate")
				else
					StretchLog("stretch branch: -> ForceFramePassable")
					SafeCall(ForceFramePassable, map, cfg_bool("OPTIMIZE_STRETCH_PASSABILITY", true))
				end
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
			if stretch_token and type(loading_profiler.End) == "function" then
				loading_profiler.End(stretch_token, {
					grids = n_grids, stretch_ok = ok_stretch,
					error = ok_branch and nil or tostring(branch_err),
				}, ok_branch == true)
			end
			-- Balanced resume (always, even on error) so the loop detector is restored.
			if type(resume_ild) == "function" then SafeCall(resume_ild, "SuperBigMapStretch") end
			if type(ClearDecorRelief) == "function" then ClearDecorRelief(map) end
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
			if ok_branch and map.SuperBigMapStretchPipelinePending == true then
				FinalizeDeferredStretchState(map, "surface")
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
			EntranceSnapshot("surface stretch final", map)
			end_loading()
			WakePendingUndergroundStretch()
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

-- The generation stamps used by the stretch are transient ordinary map fields. Preserve their
-- primitive values in one MapVar while work is deferred, so saving on the surface and reloading
-- before first underground access cannot lose the transform geometry and expose a source-layout
-- underground. Restoring is idempotent and does not overwrite live generation stamps.
local function RestoreDeferredUndergroundGeometry(map)
	local g = map and map.SuperBigMapUndergroundDeferredGeometry
	if type(g) ~= "table" then return false end
	local fields = {
		SuperBigMapDesiredWidthTiles = "desired_width_tiles",
		SuperBigMapDesiredHeightTiles = "desired_height_tiles",
		SuperBigMapGeneratorWidthTiles = "generator_width_tiles",
		SuperBigMapGeneratorHeightTiles = "generator_height_tiles",
		SuperBigMapSourceWidthTiles = "source_width_tiles",
		SuperBigMapSourceHeightTiles = "source_height_tiles",
		SuperBigMapSourceWidth = "source_width",
		SuperBigMapSourceHeight = "source_height",
	}
	for field, key in pairs(fields) do
		if map[field] == nil and type(g[key]) == "number" then map[field] = g[key] end
	end
	return true
end

local function SaveDeferredUndergroundGeometry(map)
	if not map then return false end
	map.SuperBigMapUndergroundDeferredGeometry = {
		desired_width_tiles = map.SuperBigMapDesiredWidthTiles,
		desired_height_tiles = map.SuperBigMapDesiredHeightTiles,
		generator_width_tiles = map.SuperBigMapGeneratorWidthTiles,
		generator_height_tiles = map.SuperBigMapGeneratorHeightTiles,
		source_width_tiles = map.SuperBigMapSourceWidthTiles,
		source_height_tiles = map.SuperBigMapSourceHeightTiles,
		source_width = map.SuperBigMapSourceWidth,
		source_height = map.SuperBigMapSourceHeight,
	}
	return true
end

-- STRETCH for the UNDERGROUND map (config STRETCH_UNDERGROUND): the same resample pipeline as the
-- surface in its underground form -- terrain grids + decorations + markers (incl. tunnel markers),
-- final buildable/passability grids, and enrichment density normalization. Because BOTH maps receive
-- the IDENTICAL x(full/source) transform, surface<->underground entrances keep corresponding: the
-- game spawns an underground passage AT the surface passage's own x,y and links the pair by
-- object reference. Triggered from PostNewMapLoaded for Environment=="Underground" maps; gates on
-- the expansion sizes stamped by the DoGenerate wrapper (desired > generator).
local function RunUndergroundStretchIfEnabled(map, force_now)
	if not cfg_bool("STRETCH_UNDERGROUND", false) then return false end
	map = map or Global("CurrentMap")
	if not map then return false end
	RestoreDeferredUndergroundGeometry(map)
	if map.SuperBigMapUndergroundPrepared == true then
		map.SuperBigMapUndergroundStretchDone = true
		map.SuperBigMapUndergroundStretchPending = false
	end
	if map.SuperBigMapUndergroundStretchDone == true then
		return force_now == true and true or false
	end
	if map.SuperBigMapUndergroundPreparationFailed == true then
		return false, map.SuperBigMapUndergroundStretchFailed
			or "a previous underground preparation attempt failed"
	end
	if map.SuperBigMapUndergroundStretchRunning == true then
		if force_now == true then
			return false, "underground expansion already running"
		end
		return true, "underground expansion already running"
	end
	local desired = map.SuperBigMapDesiredWidthTiles
	local gen_t = map.SuperBigMapGeneratorWidthTiles
	if not (type(desired) == "number" and type(gen_t) == "number" and desired > gen_t) then
		StretchLog("underground stretch: not an expanded underground map -- skip", {
			desired = tostring(desired), generator = tostring(gen_t),
		})
		return false
	end
	-- Keep vanilla underground generation eager: this function is called only AFTER vanilla has
	-- created the underground exits, surface passages, links, and source enrichments. When enabled,
	-- postpone just the expensive expansion/post-processing while the underground is not current.
	-- ChangeCurrentMapSlot is wrapped below and forces this complete pipeline before access.
	local current_map = Global("CurrentMap")
	if force_now ~= true and cfg_bool("DEFER_UNDERGROUND_EXPANSION_UNTIL_FIRST_ACCESS", false)
		and current_map ~= map then
		map.SuperBigMapUndergroundStretchPending = true
		map.SuperBigMapUndergroundStretchFailed = nil
		map.SuperBigMapUndergroundPreparationFailed = false
		SaveDeferredUndergroundGeometry(map)
		StretchLog("underground stretch: deferred until first access", {
			desired = desired, generator = gen_t, map = tostring(map.name),
		})
		return true
	end
	local create_thread = Global("CreateRealTimeThread")
	local sleep = Global("Sleep")
	if force_now ~= true and (type(create_thread) ~= "function" or type(sleep) ~= "function") then
		return false
	end
	map.SuperBigMapUndergroundStretchPending = true
	map.SuperBigMapUndergroundStretchRunning = true
	map.SuperBigMapUndergroundStretchFailed = nil
	if cfg_bool("OPTIMIZE_STRETCH_DEFERRED_REBUILDS", true) then
		map.SuperBigMapStretchPipelinePending = true
	end
	-- A first-access run happens long after vanilla map generation completed, so the original
	-- readiness settle is unnecessary. The eager startup path retains its proven settle/wakeup.
	local settle_ms = force_now == true and 0 or math.max(0, cfg_number("STRETCH_SETTLE_MS", 5000))
	StretchLog("underground stretch: scheduled", { settle_ms = settle_ms, desired = desired, generator = gen_t })
	-- LOADING PHASE: keep the loading box up (and the welcome popup hidden) until this
	-- stretch too has finished -- the box previously came down when the SURFACE branch
	-- finished, leaving the welcome popup visible but unclickable while this thread still
	-- blocked the game (reference-counted; see sbm_loading_ui).
	if type(SuperBigMap.ExpansionLoadingBegin) == "function" then
		pcall(SuperBigMap.ExpansionLoadingBegin)
		SetLoadingPhase("Expanding the underground map")
	end
	local function run_pipeline()
		local loading_profiler = SuperBigMap.LoadingProfiler
		local settle_token = loading_profiler and type(loading_profiler.Begin) == "function"
			and loading_profiler.Begin("underground readiness: fixed settle", { settle_ms = settle_ms }, map) or false
		local wait_wakeup = Global("WaitWakeup")
		if settle_ms > 0 then
			if cfg_bool("OPTIMIZE_UNDERGROUND_WAKE_HANDOFF", true) and type(wait_wakeup) == "function" then
				wait_wakeup(settle_ms)
			else
				sleep(settle_ms)
			end
		end
		underground_stretch_threads[map] = nil
		if settle_token and type(loading_profiler.End) == "function" then
			loading_profiler.End(settle_token, { configured_ms = settle_ms }, true)
		end
		local pause_ild = Global("PauseInfiniteLoopDetection")
		local resume_ild = Global("ResumeInfiniteLoopDetection")
		if type(pause_ild) == "function" then SafeCall(pause_ild, "SuperBigMapUndergroundStretch") end
		local stretch_token = loading_profiler and type(loading_profiler.Begin) == "function"
			and loading_profiler.Begin("underground expansion: complete stretch pipeline", {
				settle_ms = settle_ms, desired_tiles = desired, generator_tiles = gen_t,
			}, map) or false
		local ok_branch, branch_err = pcall(function()
			EntranceSnapshot("underground stretch begin", map)
			-- Renderer bounds must cover the full 8192 grid (same fix as the surface).
			SafeCall(SyncMapDataToGrids, map)
			SpikeAudit(map, "underground pre-stretch")
			-- Relief annotations BEFORE the underground terrain stretch (same as the surface).
			if type(AnnotateDecorRelief) == "function" then
				StretchLog("underground stretch: -> AnnotateDecorRelief")
				AnnotateDecorRelief(map)
			end
			SetLoadingPhase("Stretching the underground terrain")
			StretchLog("underground stretch: -> StretchSourceToFull")
			local ok_s, n_grids = StretchSourceToFull(map, false)
			StretchLog("underground stretch: grids done", { ok = ok_s, grids = n_grids })
			if ok_s ~= true or type(n_grids) ~= "number" or n_grids < 2 then
				error("underground terrain stretch did not complete its height/type grids")
			end
			SpikeAudit(map, "underground post-StretchSourceToFull")
			if type(ScaleDecorationsToFull) == "function" then
				SetLoadingPhase("Repositioning underground rocks and decorations")
				StretchLog("underground stretch: -> ScaleDecorationsToFull")
				local n_dec = ScaleDecorationsToFull(map, false)
				StretchLog("underground stretch: decorations done", { moved = n_dec })
			end
			if type(ScaleMarkersToFull) == "function" then
				SetLoadingPhase("Repositioning underground resource deposits")
				StretchLog("underground stretch: -> ScaleMarkersToFull")
				local n_mark = ScaleMarkersToFull(map, false)
				StretchLog("underground stretch: markers done", { moved = n_mark })
				EntranceSnapshot("underground after ScaleMarkersToFull", map)
			end
			-- Entrance VISUALS follow their markers (same transform; see surface step 3b).
			if type(MoveEntranceVisualsToScale) == "function" then
				StretchLog("underground stretch: -> MoveEntranceVisualsToScale")
				local n_vis = MoveEntranceVisualsToScale(map)
				StretchLog("underground stretch: entrance visuals done", { moved = n_vis })
				EntranceSnapshot("underground after MoveEntranceVisualsToScale", map)
			end
			SpikeAudit(map, "underground post-MoveEntranceVisuals")
			-- NOTE (user decision): NO entrance placement correction of any kind. Entrances on
			-- both maps receive exactly ONE transformation -- the stretch itself (position *
			-- full/source via ScaleMarkersToFull + MoveEntranceVisualsToScale), the same as every
			-- other object. Where vanilla generated a pair mismatched, it stays mismatched.
			-- Grids FIRST: the density suite's placement pools require the LIVE buildable grid
			-- (underground pools are buildable-floor-only -- without the rebuild they would
			-- sample the stale pre-stretch grid and put enrichments out in the inaccessible
			-- rock/void, which is exactly what happened). RebuildBuildableGrid remains explicit.
			-- Passability is already rebuilt inside StretchSourceToFull's final terrain revalidation;
			-- the optimization avoids immediately rebuilding that identical grid a second time.
			do
				local rebuild_buildable = Global("RebuildBuildableGrid")
				local buildable_already_rebuilt = cfg_bool("OPTIMIZE_STRETCH_REVALIDATION", true)
					and map.SuperBigMapRevalidationRebuiltGrids == true
				if buildable_already_rebuilt then
					StretchLog("underground stretch: RebuildBuildableGrid already completed by consolidated revalidation -- skip duplicate")
				elseif type(rebuild_buildable) == "function" and map.buildable then
					SetLoadingPhase("Rebuilding the underground build grid")
					StretchLog("underground stretch: -> RebuildBuildableGrid")
					SafeCall(rebuild_buildable, map)
				end
				local terrain_api2 = Global("terrain")
				if type(terrain_api2) == "table" and type(terrain_api2.RebuildPassability) == "function" then
					if cfg_bool("OPTIMIZE_STRETCH_PASSABILITY", true) then
						StretchLog("underground stretch: RebuildPassability already completed by stretch revalidation -- skip duplicate")
					else
						StretchLog("underground stretch: -> RebuildPassability")
						SafeCall(terrain_api2.RebuildPassability, map)
					end
				end
			end
			-- DENSITY NORMALIZATION (same suite as the surface stretch branch): the underground
			-- grew by the same x1.78 area, so its enrichments must be topped up to vanilla
			-- density too (they weren't -- the underground sat ~44% under vanilla density).
			-- The x1.78 factor is correct per BUILDABLE area as well: the buildable floor
			-- stretched by the same factor as the map (the census logs the measured numbers).
			-- Placement pools are buildable-floor-only underground (CanReceiveDeposit), so no
			-- enrichment lands in the inaccessible rock/void. Runs BEFORE the TEMP
			-- ForceRevealAllOnMap so the inspection reveal also places/reveals the clones.
			do
				local deposits = SuperBigMap.DepositRules
				if deposits then
					if type(deposits.LogBuildableSectorCensus) == "function" then
						SafeCall(deposits.LogBuildableSectorCensus, map, "underground post-stretch, pre-topup")
					end
					if type(deposits.TopUpDeposits) == "function" then
						SetLoadingPhase("Distributing underground resources and anomalies")
						StretchLog("underground stretch: -> TopUpDeposits")
						SafeCall(deposits.TopUpDeposits, map)
					end
					if type(deposits.TopUpAnomalies) == "function" then
						StretchLog("underground stretch: -> TopUpAnomalies")
						SafeCall(deposits.TopUpAnomalies, map)
					end
					if type(deposits.TopUpEffectDeposits) == "function" then
						StretchLog("underground stretch: -> TopUpEffectDeposits")
						SafeCall(deposits.TopUpEffectDeposits, map)
					end
					if type(deposits.RegisterClonedMarkers) == "function" then
						StretchLog("underground stretch: -> RegisterClonedMarkers")
						SafeCall(deposits.RegisterClonedMarkers, map)
					end
					if type(deposits.RespaceAnomalies) == "function" then
						StretchLog("underground stretch: -> RespaceAnomalies")
						SafeCall(deposits.RespaceAnomalies, map)
					end
					if type(deposits.EvenOutDepositDensity) == "function" then
						StretchLog("underground stretch: -> EvenOutDepositDensity")
						SafeCall(deposits.EvenOutDepositDensity, map)
					end
					if type(deposits.LogDistributionReport) == "function" then
						SafeCall(deposits.LogDistributionReport, map, "underground after density suite")
					end
					if type(deposits.ClearTopUpPlacementPool) == "function" then
						deposits.ClearTopUpPlacementPool(map)
					end
				end
			end
			-- TEMP (config UNDERGROUND_REVEAL_ALL_DEPOSITS): force-place + reveal every
			-- deposit/anomaly so the stretched underground layout can be inspected.
			if cfg_bool("UNDERGROUND_REVEAL_ALL_DEPOSITS", false) then
				local deposits = SuperBigMap.DepositRules
				if deposits and type(deposits.ForceRevealAllOnMap) == "function" then
					StretchLog("underground stretch: -> ForceRevealAllOnMap (TEMP)")
					SafeCall(deposits.ForceRevealAllOnMap, map)
				end
			end
			-- (Buildable + passability rebuilds moved ABOVE the density suite -- its
			-- buildable-floor-only pools need the live grid.)
			SpikeAudit(map, "underground DONE")
			local main_map2 = Global("MainMap")
			if main_map2 and main_map2 ~= map then
				SpikeAudit(main_map2, "surface at underground-stretch DONE")
			end
		end)
		if stretch_token and type(loading_profiler.End) == "function" then
			loading_profiler.End(stretch_token, {
				error = ok_branch and nil or tostring(branch_err),
			}, ok_branch == true)
		end
		EntranceSnapshot("underground stretch final", map)
		if type(resume_ild) == "function" then SafeCall(resume_ild, "SuperBigMapUndergroundStretch") end
		if not ok_branch then
			StretchLog("underground stretch: EXCEPTION -- map left as generated", { err = tostring(branch_err) })
			DebugPrint("RunUndergroundStretchIfEnabled ERROR: " .. tostring(branch_err))
		end
		if type(ClearDecorRelief) == "function" then ClearDecorRelief(map) end
		if ok_branch and map.SuperBigMapStretchPipelinePending == true then
			FinalizeDeferredStretchState(map, "underground")
		elseif map.SuperBigMapStretchPipelinePending == true then
			local lifecycle = SuperBigMap.Lifecycle
			if lifecycle and type(lifecycle.Apply) == "function" then SafeCall(lifecycle.Apply, map, true) end
			map.SuperBigMapStretchPipelinePending = false
			local profiler = SuperBigMap.LoadingProfiler
			if profiler and type(profiler.Step) == "function" then
				profiler.Step("stretch optimization: fallback full rebuild", { phase = "underground exit" }, map)
			end
		end
		if ok_branch then
			map.SuperBigMapUndergroundStretchDone = true
			map.SuperBigMapUndergroundPrepared = true
			map.SuperBigMapExpanded = true
			map.SuperBigMapUndergroundDeferredGeometry = false
			map.SuperBigMapUndergroundStretchPending = false
			map.SuperBigMapUndergroundStretchFailed = nil
			map.SuperBigMapUndergroundPreparationFailed = false
		else
			-- Never expose a half-processed underground and never retry automatically: several
			-- stretch stages are intentionally one-way, so repeating after a partial failure could
			-- scale terrain or objects twice. The access gate reports the failure and stays closed.
			map.SuperBigMapUndergroundStretchPending = false
			map.SuperBigMapUndergroundStretchFailed = tostring(branch_err or "unknown error")
			map.SuperBigMapUndergroundPreparationFailed = true
		end
		map.SuperBigMapUndergroundStretchRunning = false
		StretchLog("underground stretch: DONE", {
			ok = ok_branch, first_access = force_now == true,
			error = ok_branch and nil or tostring(branch_err),
		})
		DebugPrint(ok_branch and "underground stretch complete" or "underground stretch failed; access remains blocked")
		local msg = Global("Msg")
		if type(msg) == "function" then
			pcall(msg, "SuperBigMapUndergroundExpansionDone", map, ok_branch, branch_err)
		end
		-- End of this loading phase (single exit point of the thread; every step above is
		-- pcall-guarded, so this always runs).
		if type(SuperBigMap.ExpansionLoadingEnd) == "function" then
			pcall(SuperBigMap.ExpansionLoadingEnd)
		end
		return ok_branch == true, branch_err
	end
	if force_now == true then
		return run_pipeline()
	end
	local thread = create_thread(run_pipeline)
	underground_stretch_threads[map] = thread
	return true
end

-- FIRST-ACCESS GATE. Every vanilla HUD/object route that changes between already-loaded map
-- slots funnels through ChangeCurrentMapSlot. Hold that one call before it emits CurrentMapChange
-- or exposes the target map, run the complete deferred underground pipeline, and switch only on
-- success. The normal map-switch loading screen is opened BEFORE the heavy work and kept open
-- across the eventual switch. No terrain flatten/sculpt operation is added here: entrance objects
-- are moved only by the existing post-stretch marker/visual pass against final terrain.
local function PatchDeferredUndergroundAccess()
	local State = SuperBigMap.State
	local current = Global("ChangeCurrentMapSlot")
	if type(current) ~= "function" then return false end
	if current == State.change_current_map_slot_wrapper
		and State.underground_access_patch_version == GENERATOR_PATCH_VERSION then
		return true
	end
	-- Hot-reload upgrade: unwrap our previous closure before capturing the vanilla original.
	if current == State.change_current_map_slot_wrapper
		and type(State.original_change_current_map_slot) == "function" then
		current = State.original_change_current_map_slot
		rawset(_G, "ChangeCurrentMapSlot", current)
	end
	State.original_change_current_map_slot = current
	local wrapper = function(map_slot, loading_screen, loading_screen_id)
		local original = State.original_change_current_map_slot
		if type(original) ~= "function" then return end
		local maps = Global("Maps")
		local target = type(maps) == "table" and maps[map_slot] or nil
		RestoreDeferredUndergroundGeometry(target)
		local env = target and target.mapdata and target.mapdata.Environment
		local desired = target and target.SuperBigMapDesiredWidthTiles
		local generator = target and target.SuperBigMapGeneratorWidthTiles
		local expanded_target = type(desired) == "number" and type(generator) == "number"
			and desired > generator
		if env ~= "Underground" or not cfg_bool("STRETCH_UNDERGROUND", false)
			or not expanded_target or target.SuperBigMapUndergroundPrepared == true
			or target.SuperBigMapUndergroundStretchDone == true then
			return original(map_slot, loading_screen, loading_screen_id)
		end

		-- A second switch request can arrive while the first caller is preparing the map. Wait for
		-- that authoritative run rather than launching a second one over partially changed grids.
		if target.SuperBigMapUndergroundStretchRunning == true then
			local wait_msg = Global("WaitMsg")
			if type(wait_msg) == "function" then
				wait_msg("SuperBigMapUndergroundExpansionDone", 120000)
			end
			if target.SuperBigMapUndergroundStretchDone == true then
				return original(map_slot, loading_screen, loading_screen_id)
			end
		end

		local function show_failure(reason)
			StretchLog("underground access blocked: deferred preparation failed", {
				map = tostring(target and target.name), error = tostring(reason),
			})
			local create_box = Global("CreateMessageBox")
			if type(create_box) == "function" then
				local untranslated = Global("Untranslated")
				local wrap = type(untranslated) == "function" and untranslated or function(s) return s end
				pcall(create_box, nil, wrap("Super Big Map"), wrap(
					"The underground could not be prepared safely, so access remains blocked. "
					.. "Please check the Super Big Map debug log.\n\n" .. tostring(reason or "Unknown error")))
			end
		end

		if target.SuperBigMapUndergroundStretchFailed
			or target.SuperBigMapUndergroundPreparationFailed == true then
			show_failure(target.SuperBigMapUndergroundStretchFailed
				or "A previous underground preparation attempt failed")
			return false
		end

		local screen_id = loading_screen_id or "idChangeCurrentMapSlot"
		local screen_open = loading_screen ~= false
		local open_screen = Global("LoadingScreenOpen")
		local close_screen = Global("LoadingScreenClose")
		local wait_render = Global("WaitRenderMode")
		if screen_open and type(open_screen) == "function" then
			open_screen(screen_id, map_slot)
			if type(wait_render) == "function" then wait_render("ui") end
		else
			screen_open = false
		end

		SetLoadingPhase("Preparing the underground map for first access")
		local ok, err = RunUndergroundStretchIfEnabled(target, true)
		if ok ~= true then
			if screen_open then
				if type(close_screen) == "function" then close_screen(screen_id, map_slot) end
				if type(wait_render) == "function" then wait_render("scene") end
			end
			show_failure(err or target.SuperBigMapUndergroundStretchFailed or "Preparation did not complete")
			return false
		end

		SetLoadingPhase("Opening the completed underground map")
		-- We already own the screen, so suppress the original's open/close pair and close it only
		-- after ChangeCurrentMapSlot has switched maps and waited for scene rendering.
		local result = original(map_slot, screen_open and false or loading_screen, loading_screen_id)
		if screen_open and type(close_screen) == "function" then close_screen(screen_id, map_slot) end
		return result
	end
	rawset(_G, "ChangeCurrentMapSlot", wrapper)
	State.change_current_map_slot_wrapper = wrapper
	State.underground_access_patch_version = GENERATOR_PATCH_VERSION
	DebugPrint("deferred underground first-access gate installed")
	return true
end

local MapGeneration = {}

MapGeneration.RunUndergroundStretchIfEnabled = RunUndergroundStretchIfEnabled
MapGeneration.ShouldDeferStretchRebuilds = ShouldDeferStretchRebuilds
MapGeneration.FinalizeExpandedMap = FinalizeExpandedMap
MapGeneration.PrintQuadrantDebug = PrintQuadrantDebug
MapGeneration.AttachPendingMapState = AttachPendingMapState
MapGeneration.PrepareMapDataForQuadrantCopy = PrepareMapDataForQuadrantCopy
MapGeneration.PatchRandomMapGenerator = PatchRandomMapGenerator
MapGeneration.PatchPassagePairing = PatchPassagePairing
MapGeneration.PatchDeferredUndergroundAccess = PatchDeferredUndergroundAccess
MapGeneration.SyncMapDataToGrids = SyncMapDataToGrids
MapGeneration.RunSectorMirrorPlanIfEnabled = RunSectorMirrorPlanIfEnabled
MapGeneration.ForceFramePassable = ForceFramePassable
MapGeneration.ReinvalidateExpandedTerrain = ReinvalidateExpandedTerrain

function MapGeneration.ApplyModBehavior()
	PatchRandomMapGenerator()
	PatchPassagePairing()
	PatchDeferredUndergroundAccess()
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
	if State.spawn_passage_wrapper and Global("SpawnUndergroundPassage") == State.spawn_passage_wrapper
		and type(State.original_spawn_passage) == "function" then
		rawset(_G, "SpawnUndergroundPassage", State.original_spawn_passage)
	end
	State.spawn_passage_wrapper = nil
	State.original_spawn_passage = nil
	if State.place_building_trap and Global("PlaceBuildingIn") == State.place_building_trap
		and type(State.original_place_building) == "function" then
		rawset(_G, "PlaceBuildingIn", State.original_place_building)
	end
	State.place_building_trap = nil
	State.original_place_building = nil
	local passage_class = Engine.ClassTable and Engine.ClassTable("ElevatorPassage")
	if type(passage_class) == "table" and State.passage_link_wrapper
		and passage_class.Link == State.passage_link_wrapper
		and type(State.original_passage_link) == "function" then
		passage_class.Link = State.original_passage_link
	end
	State.passage_link_wrapper = nil
	State.original_passage_link = nil
	if State.change_current_map_slot_wrapper
		and Global("ChangeCurrentMapSlot") == State.change_current_map_slot_wrapper
		and type(State.original_change_current_map_slot) == "function" then
		rawset(_G, "ChangeCurrentMapSlot", State.original_change_current_map_slot)
	end
	State.change_current_map_slot_wrapper = nil
	State.original_change_current_map_slot = nil
	State.underground_access_patch_version = nil
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
	-- Passage pairing wrap installs at module load for the same reason -- and because module
	-- load is what re-runs after the NEW-GAME Lua reload (game files redefine the global,
	-- wiping any wrapper; Lifecycle.Enable early-returns since State.active persisted, so a
	-- reinstall must not depend on it). Self-verifying, so repeat calls are no-ops.
	PatchPassagePairing()
	PatchDeferredUndergroundAccess()
end

DebugPrint("map generation module loaded")

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
SuperBigMap.State.underground_recovery_maps = SuperBigMap.State.underground_recovery_maps
	or setmetatable({}, { __mode = "k" })
local pending_maps = SuperBigMap.State.quadrant_pending_maps
local blocked_maps = SuperBigMap.State.quadrant_blocked_maps
local underground_stretch_threads = SuperBigMap.State.underground_stretch_threads
local underground_recovery_maps = SuperBigMap.State.underground_recovery_maps

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

local function PackValues(...)
	return { n = select("#", ...), ... }
end

-- Separately gated nested loading trace. These helpers only surround calls that already happen;
-- they do not add gameplay work, yields, waits, or ordering changes. SafeCall keeps its original
-- error-swallowing semantics and direct calls remain direct at their call sites.
local function InvestigationBegin(name, map, data)
	local profiler = SuperBigMap.LoadingProfiler
	if profiler and type(profiler.InvestigationBegin) == "function" then
		return profiler.InvestigationBegin(name, data, map)
	end
	return false
end

local function InvestigationEnd(token, data, ok)
	local profiler = SuperBigMap.LoadingProfiler
	if token and profiler and type(profiler.InvestigationEnd) == "function" then
		return profiler.InvestigationEnd(token, data, ok)
	end
	return false
end

local function InvestigationSafeCall(name, map, fn, ...)
	local token = InvestigationBegin(name, map)
	local a, b, c, d = SafeCall(fn, ...)
	InvestigationEnd(token, {
		first_result = tostring(a),
		second_result = tostring(b),
	}, true)
	return a, b, c, d
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

-- Dedicated forensic channel for deferred underground first access. Unlike the broad Stretch
-- trace, this records the complete control-flow decision at every entry point so a missing click,
-- overwritten hook, incomplete map identity, or early-return state is unambiguous in one grep.
local function UndergroundAccessLog(message, data, level)
	local DebugLog = SuperBigMap.DebugLog
	local enabled = DebugLog and type(DebugLog.On) == "function"
		and DebugLog.On("UndergroundAccess") == true
	if DebugLog then
		local emit = level == "error" and DebugLog.Error
			or level == "warn" and DebugLog.Warn or DebugLog.Info
		if type(emit) == "function" then emit("UndergroundAccess", message, data) end
	end
	if enabled then
		local profiler = SuperBigMap.LoadingProfiler
		if profiler and type(profiler.Step) == "function" then
			profiler.Step("underground access: " .. tostring(message), data, Global("CurrentMap"))
		end
	end
end

local function UndergroundAccessState(map, extra)
	local data = {
		map = tostring(map and map.name),
		map_ref = tostring(map),
		map_slot = tostring(map and map.slot),
		environment = tostring(map and map.mapdata and map.mapdata.Environment),
		current_map = tostring(Global("CurrentMap") and Global("CurrentMap").name),
		current_ref = tostring(Global("CurrentMap")),
		main_ref = tostring(Global("MainMap")),
		underground_ref = tostring(Global("UndergroundMap")),
		desired_width = tostring(map and map.SuperBigMapDesiredWidthTiles),
		desired_height = tostring(map and map.SuperBigMapDesiredHeightTiles),
		generator_width = tostring(map and map.SuperBigMapGeneratorWidthTiles),
		generator_height = tostring(map and map.SuperBigMapGeneratorHeightTiles),
		source_width = tostring(map and map.SuperBigMapSourceWidthTiles),
		source_height = tostring(map and map.SuperBigMapSourceHeightTiles),
		prepared = tostring(map and map.SuperBigMapUndergroundPrepared),
		done = tostring(map and map.SuperBigMapUndergroundStretchDone),
		pending = tostring(map and map.SuperBigMapUndergroundStretchPending),
		running = tostring(map and map.SuperBigMapUndergroundStretchRunning),
		failed = tostring(map and map.SuperBigMapUndergroundPreparationFailed),
		failure = tostring(map and map.SuperBigMapUndergroundStretchFailed),
		deferred_geometry = tostring(map and type(map.SuperBigMapUndergroundDeferredGeometry) == "table"),
		stretch_underground = tostring(cfg_bool("STRETCH_UNDERGROUND", false)),
		defer_first_access = tostring(cfg_bool("DEFER_UNDERGROUND_EXPANSION_UNTIL_FIRST_ACCESS", false)),
	}
	if type(extra) == "table" then
		for key, value in pairs(extra) do data[key] = value end
	end
	return data
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
local PatchEntranceBadgePosition = TerrainCopy.PatchEntranceBadgePosition
local RestoreEntranceBadgePositionPatch = TerrainCopy.RestoreEntranceBadgePositionPatch
local RestoreEntranceBadgePositions = TerrainCopy.RestoreEntranceBadgePositions
local BeginDeferredElevatorMigration = TerrainCopy.BeginDeferredElevatorMigration
local RestoreDeferredElevatorMigration = TerrainCopy.RestoreDeferredElevatorMigration
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
	map.SuperBigMapExpandedWorldWidth = nil
	map.SuperBigMapExpandedWorldHeight = nil
	map.SuperBigMapExpandedHexWidth = nil
	map.SuperBigMapExpandedHexHeight = nil
	map.SuperBigMapDeferredBackingPromotion = nil
	map.SuperBigMapBackingPromotionComplete = nil
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
	-- The temporary source map deliberately shares the destination's BlankMap name, but must
	-- never inherit the name-keyed expanded pending record. Its native backing is the exact
	-- vanilla generator view and is discarded immediately after migration.
	if map.SuperBigMapVanillaSourceMigration == true then
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
	map.SuperBigMapDeferredBackingPromotion = pending.deferred_backing == true

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
	local deferred_backing = cfg_bool("DEFER_EXPANDED_BACKING_UNTIL_AFTER_VANILLA_SOURCE", false)
		and mapdata.Environment == "Surface"

	mapdata.SuperBigMapOriginalWidthTiles = original_width
	mapdata.SuperBigMapOriginalHeightTiles = original_height
	mapdata.SuperBigMapQuadrantCopyScale = scale
	mapdata.SuperBigMapQuadrantSourceWidthTiles = source_width_tiles
	mapdata.SuperBigMapQuadrantSourceHeightTiles = source_height_tiles
	if deferred_backing then
		-- Keep ChangeMap on a genuine vanilla backing. The desired dimensions remain in the
		-- pending record and are promoted only after native source generation has completed.
		mapdata.Width = original_width
		mapdata.Height = original_height
	else
		mapdata.Width = desired_width
		mapdata.Height = desired_height
	end

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
	if not deferred_backing then
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
	if deferred_backing and mapdata.SuperBigMapOriginalPassBorder == nil then
		mapdata.SuperBigMapOriginalPassBorder = mapdata.PassBorder
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
		deferred_backing = deferred_backing,
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
	map_instance.SuperBigMapDeferredBackingPromotion = deferred_backing

	DebugPrint(string.format(
		"prepared %s for 2x2 quadrant copy via %s (%s x %s tiles -> %s x %s tiles; source %s x %s tiles; deferred_backing=%s)",
		tostring(map_name),
		tostring(source or "ChangingMap"),
		tostring(original_width),
		tostring(original_height),
		tostring(desired_width),
		tostring(desired_height),
		tostring(source_width_tiles),
		tostring(source_height_tiles),
		tostring(deferred_backing)
	))
	return true
end

local CaptureGeneratedNativeEnrichments

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
	CaptureGeneratedNativeEnrichments(map, "FinalizeExpandedMap")
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

local function EnrichmentSpreadBoundary(generator, map, phase, data)
	local diagnostics = SuperBigMap.EnrichmentSpreadDiagnostics
	if diagnostics and type(diagnostics.TraceGeneratorBoundary) == "function" then
		pcall(diagnostics.TraceGeneratorBoundary, generator, map, phase, data)
	end
end

CaptureGeneratedNativeEnrichments = function(map, label)
	if not cfg_bool("EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE", false) then return 0 end
	local deposits = SuperBigMap.DepositRules
	if deposits and type(deposits.CaptureNativeEnrichmentPositions) == "function" then
		local ok, count = pcall(deposits.CaptureNativeEnrichmentPositions, map, label)
		if ok then return count or 0 end
		DebugPrint("native enrichment capture ERROR: " .. tostring(count))
	end
	if map then map.SuperBigMapNativeEnrichmentCapturePending = true end
	return 0
end

local function BackingPromotionLog(message, data, level)
	local debug_log = SuperBigMap.DebugLog
	if not debug_log then return end
	local fn = level == "error" and debug_log.Error
		or (level == "warn" and debug_log.Warn or debug_log.Info)
	if type(fn) == "function" then pcall(fn, "EnrichmentSpreadComparison", message, data) end
end

local function MigrationTicks()
	local ticks = Global("GetPreciseTicks") or Global("RealTime")
	if type(ticks) == "function" then
		local ok, value = pcall(ticks)
		if ok and type(value) == "number" then return value end
	end
	return 0
end

local function MigrationGridSize(grid)
	if not grid or type(grid.size) ~= "function" then return nil, nil end
	local ok, width, height = pcall(grid.size, grid)
	if not ok then return nil, nil end
	return width, height or width
end

local function FreeMigrationGrid(grid, raw)
	if grid and grid ~= raw and type(grid.free) == "function" then
		pcall(grid.free, grid)
	end
end

-- Copy the generated native terrain into the already allocated expanded backing. Unlike the
-- retired live-promotion experiment, both setter inputs are derived from the destination's own
-- grids, so their dimensions necessarily match the destination terrain and satisfy the engine's
-- SetHeightGrid/SetTypeGrid invariant.
local function CopyMigratedTerrain(source, destination, stats)
	local terrain_api = Global("terrain")
	local grid_to_compute = Global("GridToCompute")
	local box_fn = Global("box")
	local point_fn = Global("point")
	if type(terrain_api) ~= "table"
		or type(terrain_api.GetHeightGrid) ~= "function"
		or type(terrain_api.SetHeightGrid) ~= "function"
		or type(terrain_api.GetTypeGrid) ~= "function"
		or type(terrain_api.SetTypeGrid) ~= "function"
		or type(grid_to_compute) ~= "function"
		or type(box_fn) ~= "function" or type(point_fn) ~= "function" then
		error("temporary source migration terrain API unavailable")
	end

	local started = MigrationTicks()
	local source_height_raw = terrain_api.GetHeightGrid(source)
	local destination_height_raw = terrain_api.GetHeightGrid(destination)
	local source_type_raw = terrain_api.GetTypeGrid(source)
	local destination_type_raw = terrain_api.GetTypeGrid(destination)
	if not source_height_raw or not destination_height_raw or not source_type_raw or not destination_type_raw then
		error("temporary source migration could not capture all terrain grids")
	end

	local shw, shh = MigrationGridSize(source_height_raw)
	local dhw, dhh = MigrationGridSize(destination_height_raw)
	local stw, sth = MigrationGridSize(source_type_raw)
	local dtw, dth = MigrationGridSize(destination_type_raw)
	stats.source_height_grid = tostring(shw) .. "x" .. tostring(shh)
	stats.destination_height_grid = tostring(dhw) .. "x" .. tostring(dhh)
	stats.source_type_grid = tostring(stw) .. "x" .. tostring(sth)
	stats.destination_type_grid = tostring(dtw) .. "x" .. tostring(dth)
	if not shw or not shh or not dhw or not dhh or shw > dhw or shh > dhh
		or not stw or not sth or not dtw or not dth or stw > dtw or sth > dth then
		error(string.format("temporary source grid dimensions do not fit destination: height %sx%s -> %sx%s; type %sx%s -> %sx%s",
			tostring(shw), tostring(shh), tostring(dhw), tostring(dhh),
			tostring(stw), tostring(sth), tostring(dtw), tostring(dth)))
	end

	local source_height = grid_to_compute(source_height_raw)
	local destination_height = grid_to_compute(destination_height_raw)
	local source_type = grid_to_compute(source_type_raw)
	local destination_type = grid_to_compute(destination_type_raw)
	if not source_height or not destination_height or not source_type or not destination_type then
		FreeMigrationGrid(source_height, source_height_raw)
		FreeMigrationGrid(destination_height, destination_height_raw)
		FreeMigrationGrid(source_type, source_type_raw)
		FreeMigrationGrid(destination_type, destination_type_raw)
		error("temporary source GridToCompute conversion failed")
	end

	local ok, err = pcall(function()
		destination_height:copyrect(source_height, box_fn(0, 0, shw, shh), point_fn(0, 0))
		destination_type:copyrect(source_type, box_fn(0, 0, stw, sth), point_fn(0, 0))
		local height_error = terrain_api.SetHeightGrid(destination, destination_height)
		if height_error then error("SetHeightGrid: " .. tostring(height_error)) end
		local type_error = terrain_api.SetTypeGrid(destination, destination_type)
		if type_error then error("SetTypeGrid: " .. tostring(type_error)) end
	end)
	FreeMigrationGrid(source_height, source_height_raw)
	FreeMigrationGrid(destination_height, destination_height_raw)
	FreeMigrationGrid(source_type, source_type_raw)
	FreeMigrationGrid(destination_type, destination_type_raw)
	if not ok then error(err) end
	stats.terrain_copy_ms = MigrationTicks() - started
	BackingPromotionLog("TEMP_SOURCE_TERRAIN_COPIED", {
		source_height = stats.source_height_grid,
		destination_height = stats.destination_height_grid,
		source_type = stats.source_type_grid,
		destination_type = stats.destination_type_grid,
		elapsed_ms = stats.terrain_copy_ms,
	})
end

local function MapObjects(map)
	if not map or type(map.MapGet) ~= "function" then return nil, "MapGet unavailable" end
	local ok, objects = pcall(map.MapGet, map, "map")
	if not ok or type(objects) ~= "table" then
		return nil, ok and "MapGet returned no table" or tostring(objects)
	end
	return objects
end

local function SnapshotMapObjectSet(map)
	local objects, err = MapObjects(map)
	if not objects then error("could not snapshot map objects: " .. tostring(err)) end
	local set = {}
	for i = 1, #objects do set[objects[i]] = true end
	return set, #objects
end

local function TransferGeneratedObjects(source, destination, stats, source_baseline)
	local objects, err = MapObjects(source)
	if not objects then error("could not enumerate source objects: " .. tostring(err)) end
	local is_valid = Global("IsValid")
	local started = MigrationTicks()
	local roots, seen_roots = {}, {}
	local generated_enumerated = 0
	for i = 1, #objects do
		local root = objects[i]
		local valid = type(is_valid) ~= "function" or is_valid(root)
		if valid and not (source_baseline and source_baseline[root]) then
			generated_enumerated = generated_enumerated + 1
			local parent_depth = 0
			while type(root.GetParent) == "function" and parent_depth < 64 do
				local parent = SafeCall(root.GetParent, root)
				local parent_valid = parent and (type(is_valid) ~= "function" or is_valid(parent))
				if not parent_valid or (source_baseline and source_baseline[parent]) then break end
				root = parent
				parent_depth = parent_depth + 1
			end
			if not seen_roots[root] then
				seen_roots[root] = true
				roots[#roots + 1] = root
			end
		end
	end
	local transferred, failed = 0, 0
	local failures = {}
	for i = 1, #roots do
		local obj = roots[i]
		local valid = type(is_valid) ~= "function" or is_valid(obj)
		if valid then
			if type(obj.TransferToMap) ~= "function" then
				failed = failed + 1
				if #failures < 8 then failures[#failures + 1] = tostring(obj.class) .. ":TransferToMap unavailable" end
			else
				-- TransferToMap preserves the current position when no replacement position is supplied
				-- (the vanilla rocket/unit call sites use this form). Avoid GetPos + GetMap around every
				-- object; one post-batch source audit below verifies the complete transaction instead.
				local ok, transfer_error = pcall(obj.TransferToMap, obj, destination)
				if ok then
					transferred = transferred + 1
				else
					failed = failed + 1
					if #failures < 8 then
						failures[#failures + 1] = tostring(obj.class) .. ":" .. tostring(transfer_error or "wrong destination")
					end
				end
			end
		end
	end
	local remaining_objects, remaining_error = MapObjects(source)
	if not remaining_objects then error("could not audit source after object transfer: " .. tostring(remaining_error)) end
	local remaining_generated = 0
	for i = 1, #remaining_objects do
		if not (source_baseline and source_baseline[remaining_objects[i]]) then
			remaining_generated = remaining_generated + 1
		end
	end
	stats.source_objects_enumerated = #objects
	stats.source_baseline_objects = stats.source_baseline_objects or 0
	stats.source_generated_objects = generated_enumerated
	stats.source_root_objects = #roots
	stats.source_objects_transferred = transferred
	stats.source_attached_objects = math.max(0, generated_enumerated - #roots)
	stats.source_object_transfer_failures = failed
	stats.source_generated_objects_remaining = remaining_generated
	stats.object_transfer_ms = MigrationTicks() - started
	BackingPromotionLog("TEMP_SOURCE_OBJECTS_TRANSFERRED", {
		enumerated = #objects, generated = generated_enumerated,
		roots = #roots, transferred = transferred,
		attached = stats.source_attached_objects, failed = failed,
		baseline = stats.source_baseline_objects, remaining_generated = remaining_generated,
		failure_samples = table.concat(failures, " | "), elapsed_ms = stats.object_transfer_ms,
	})
	if failed > 0 or remaining_generated > 0 then
		error(string.format("temporary source object migration failed for %d objects: %s",
			failed + remaining_generated, table.concat(failures, " | ")))
	end
end

local function FindTemporarySourceSlot(destination_slot)
	local maps = Global("Maps")
	local engine_config = Global("config")
	local max_slots = type(engine_config) == "table" and tonumber(engine_config.MapSlots) or 0
	max_slots = math.max(2, math.floor(max_slots or 0))
	for slot = max_slots, 2, -1 do
		if slot ~= destination_slot and type(maps) == "table" and maps[slot] == nil then
			return slot
		end
	end
	return nil
end

local function NewNativeSourceMapData(template, source_width, source_height, pass_border)
	local data = {}
	for key, value in pairs(template or {}) do
		if type(key) ~= "string" or not string.match(key, "^SuperBigMap") then
			data[key] = value
		end
	end
	data.Width = source_width
	data.Height = source_height
	data.PassBorder = pass_border
	local const_tbl = Global("const")
	local tile = type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize) or nil
	if type(data.PassBorderTiles) == "number" and tile and tile > 0 then
		data.PassBorderTiles = math.floor(pass_border / tile)
	end
	local preset = Global("MapDataPreset")
	if type(preset) == "table" and type(preset.new) == "function" then
		return preset:new(data)
	end
	return data
end

local function CopyGeneratedMapState(source, destination)
	destination.obj_prefab_marker = source.obj_prefab_marker
	destination.MapLowestZ = source.MapLowestZ
	destination.MapHighestZ = source.MapHighestZ
	for key, value in pairs(source) do
		if type(key) == "string" and string.match(key, "^SuperBigMap")
			and key ~= "SuperBigMapVanillaSourceMigration"
			and destination[key] == nil then
			destination[key] = value
		end
	end
end

-- Execute RandomMapGenerator exactly once on a real native backing, while retaining the already
-- allocated expanded map as the final destination. The temporary map never emits MapGenerated,
-- never runs the mod lifecycle, and is unloaded immediately after terrain/object migration.
local function GenerateOnTemporaryVanillaBacking(generator, destination, original_do_generate, ...)
	if not cfg_bool("GENERATE_VANILLA_SOURCE_ON_TEMPORARY_BACKING", false)
		or not cfg_bool("EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE", false)
		or not destination or not destination.mapdata
		or destination.mapdata.Environment ~= "Surface"
		or destination.SuperBigMapQuadrantCopyPending ~= true then
		return false
	end
	local source_width = tonumber(destination.SuperBigMapGeneratorWidthTiles)
	local source_height = tonumber(destination.SuperBigMapGeneratorHeightTiles)
	local desired_width = tonumber(destination.SuperBigMapDesiredWidthTiles)
	local desired_height = tonumber(destination.SuperBigMapDesiredHeightTiles)
	if not source_width or not source_height or not desired_width or not desired_height
		or source_width <= 0 or source_height <= 0
		or desired_width <= source_width or desired_height <= source_height then
		return false
	end
	local change_map_in_slot = Global("ChangeMapInSlot")
	local change_current_slot = Global("ChangeCurrentMapSlot")
	local set_current_map = Global("SetCurrentMap")
	local engine_set_current_slot = Global("EngineSetCurrentMapSlot")
	local get_current_slot = Global("GetCurrentMapSlot")
	local maps = Global("Maps")
	local silent_switch_available = type(set_current_map) == "function"
		and type(engine_set_current_slot) == "function"
	if type(change_map_in_slot) ~= "function"
		or (not silent_switch_available and type(change_current_slot) ~= "function")
		or type(get_current_slot) ~= "function" or type(maps) ~= "table" then
		error("temporary source migration map-slot API unavailable")
	end
	local function SwitchGeneratorCurrentSlot(slot)
		if silent_switch_available then
			local target = maps[slot]
			if not target then error("temporary source migration switch target is unavailable: " .. tostring(slot)) end
			set_current_map(target)
			engine_set_current_slot(slot)
			return true
		end
		change_current_slot(slot, false)
		return true
	end
	local destination_slot = destination.slot or get_current_slot()
	local source_slot = FindTemporarySourceSlot(destination_slot)
	if not source_slot then error("temporary source migration has no free map slot") end
	local map_data_table = Global("MapData")
	local blank_map = generator and generator.BlankMap
	local template = type(map_data_table) == "table" and map_data_table[blank_map or false] or destination.mapdata
	local pass_border = tonumber(destination.mapdata.SuperBigMapOriginalPassBorder)
		or tonumber(template and template.SuperBigMapOriginalPassBorder)
		or tonumber(template and template.PassBorder) or 0
	local source_mapdata = NewNativeSourceMapData(template, source_width, source_height, pass_border)
	local call_args = PackValues(...)
	local saved_template_width = template and template.Width
	local saved_template_height = template and template.Height
	local saved_template_pass_border = template and template.PassBorder
	local saved_template_pass_border_tiles = template and template.PassBorderTiles
	local function RestoreGeneratorTemplate()
		if not template then return end
		template.Width = saved_template_width
		template.Height = saved_template_height
		template.PassBorder = saved_template_pass_border
		template.PassBorderTiles = saved_template_pass_border_tiles
	end
	local source_instance = {
		mapdata = source_mapdata,
		RandomMapGenObject = generator,
		SuperBigMapVanillaSourceMigration = true,
	}

	local started = MigrationTicks()
	local stats = {
		map = tostring(destination.name), source_slot = source_slot,
		destination_slot = destination_slot,
		source_tiles = tostring(source_width) .. "x" .. tostring(source_height),
		destination_tiles = tostring(desired_width) .. "x" .. tostring(desired_height),
		pass_border = pass_border,
		current_switch_mode = silent_switch_available and "engine-silent" or "public-fallback",
	}
	BackingPromotionLog("TEMP_SOURCE_MIGRATION_BEGIN", stats)
	SetLoadingPhase("Generating the exact vanilla source terrain...")
	local source
	local source_baseline
	local saved_main_map = Global("MainMap")
	local saved_main_city = Global("MainCity")
	local results
	SuperBigMap.State.vanilla_source_migration_active = true
	local ok, migration_error = pcall(function()
		local allocation_started = MigrationTicks()
		local allocation_error = change_map_in_slot(source_slot, blank_map, source_instance)
		if allocation_error then error("temporary source ChangeMapInSlot: " .. tostring(allocation_error)) end
		source = maps[source_slot]
		if not source then error("temporary source map was not created") end
		stats.source_allocation_ms = MigrationTicks() - allocation_started
		local terrain_api = Global("terrain")
		local actual_width, actual_height
		if type(terrain_api) == "table" and type(terrain_api.HeightMapSize) == "function" then
			actual_width, actual_height = terrain_api.HeightMapSize(source)
			actual_height = actual_height or actual_width
		end
		BackingPromotionLog("TEMP_SOURCE_MAP_ALLOCATED", {
			slot = source_slot, elapsed_ms = stats.source_allocation_ms,
			mapdata = tostring(source.mapdata and source.mapdata.Width) .. "x" .. tostring(source.mapdata and source.mapdata.Height),
			height_backing = tostring(actual_width) .. "x" .. tostring(actual_height),
			pass_border = tostring(source.mapdata and source.mapdata.PassBorder),
		})
		if actual_width ~= source_width or actual_height ~= source_height then
			error(string.format("temporary source backing is not native-sized: got %sx%s expected %sx%s",
				tostring(actual_width), tostring(actual_height), tostring(source_width), tostring(source_height)))
		end
		source_baseline, stats.source_baseline_objects = SnapshotMapObjectSet(source)
		local destination_objects, destination_object_error = MapObjects(destination)
		if not destination_objects then
			error("could not snapshot destination infrastructure: " .. tostring(destination_object_error))
		end
		stats.destination_infrastructure_objects = #destination_objects
		BackingPromotionLog("TEMP_SOURCE_OBJECT_BASELINES", {
			source = stats.source_baseline_objects,
			destination = stats.destination_infrastructure_objects,
		})

		SwitchGeneratorCurrentSlot(source_slot)
		rawset(_G, "MainMap", source)
		if source.City ~= nil then rawset(_G, "MainCity", source.City) end
		-- RandomMapGenerator:GetMapSize reads MapData[self.BlankMap] directly rather than the
		-- supplied map. Keep that last generator input native-sized for exactly this transaction;
		-- the destination's engine backing remains expanded and its template is restored before
		-- any destination work resumes.
		if template then
			template.Width = source_width
			template.Height = source_height
			template.PassBorder = pass_border
			local const_tbl = Global("const")
			local tile = type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize) or nil
			if type(template.PassBorderTiles) == "number" and tile and tile > 0 then
				template.PassBorderTiles = math.floor(pass_border / tile)
			end
		end
		local generation_started = MigrationTicks()
		BackingPromotionLog("TEMP_SOURCE_GENERATION_BEGIN", {
			slot = source_slot, backing = tostring(actual_width) .. "x" .. tostring(actual_height),
			pass_border = tostring(source.mapdata.PassBorder), seed = tostring(generator and generator.Seed),
		})
		if type(source.SuspendPassEdits) == "function" then source:SuspendPassEdits("SuperBigMapVanillaSourceMigration") end
		results = PackValues(original_do_generate(generator, source,
			Unpack(call_args, 1, call_args.n)))
		local update_radius = Global("UpdateMapMaxObjRadius")
		if type(update_radius) == "function" then update_radius(source) end
		if type(source.ResumePassEdits) == "function" then source:ResumePassEdits("SuperBigMapVanillaSourceMigration") end
		stats.source_generation_ms = MigrationTicks() - generation_started
		CaptureGeneratedNativeEnrichments(source, "temporary vanilla backing generation complete")
		BackingPromotionLog("TEMP_SOURCE_GENERATION_END", {
			elapsed_ms = stats.source_generation_ms,
			map_lowest_z = tostring(source.MapLowestZ), map_highest_z = tostring(source.MapHighestZ),
		})

		rawset(_G, "MainMap", saved_main_map)
		rawset(_G, "MainCity", saved_main_city)
		RestoreGeneratorTemplate()
		SwitchGeneratorCurrentSlot(destination_slot)
		SetLoadingPhase("Migrating the vanilla source into the expanded terrain...")
		CopyMigratedTerrain(source, destination, stats)
		CopyGeneratedMapState(source, destination)
		TransferGeneratedObjects(source, destination, stats, source_baseline)
		CaptureGeneratedNativeEnrichments(destination, "temporary vanilla backing migrated to destination")
		-- The normal expanded-backing tail consumes these optional smoothing records immediately.
		-- This path deliberately preserves the vanilla-generated height field, so discard their
		-- temporary-map references instead of allowing a later map generation to consume stale pads.
		SuperBigMap.State.sbm_entrance_pads = nil

		local rebuild_started = MigrationTicks()
		local box_fn = Global("box")
		local map_width, map_height = destination:GetMapSize()
		if type(destination.RebuildGrids) ~= "function" or type(box_fn) ~= "function" then
			error("destination RebuildGrids API unavailable")
		end
		destination:RebuildGrids(box_fn(0, 0, map_width, map_height))
		destination.SuperBigMapSurfaceBuildableCurrent = true
		stats.destination_rebuild_ms = MigrationTicks() - rebuild_started
		BackingPromotionLog("TEMP_SOURCE_DESTINATION_REBUILT", {
			world_size = tostring(map_width) .. "x" .. tostring(map_height),
			elapsed_ms = stats.destination_rebuild_ms,
			buildable = tostring(destination.buildable),
		})
	end)

	-- Always restore the real surface as current and release the temporary slot. This also keeps
	-- the slot available for the vanilla additional-map/underground phase that follows Generate.
	rawset(_G, "MainMap", saved_main_map)
	rawset(_G, "MainCity", saved_main_city)
	RestoreGeneratorTemplate()
	if get_current_slot() ~= destination_slot then
		pcall(SwitchGeneratorCurrentSlot, destination_slot)
	end
	if maps[source_slot] then
		local unload_started = MigrationTicks()
		local unload_ok, unload_error = pcall(change_map_in_slot, source_slot, "")
		stats.source_unload_ms = MigrationTicks() - unload_started
		if not unload_ok and ok then
			ok, migration_error = false, "temporary source unload failed: " .. tostring(unload_error)
		end
	end
	SuperBigMap.State.vanilla_source_migration_active = false
	stats.total_ms = MigrationTicks() - started
	stats.ok = ok
	stats.error = ok and "none" or tostring(migration_error)
	destination.SuperBigMapVanillaSourceMigrationStats = stats
	if ok then
		BackingPromotionLog("TEMP_SOURCE_MIGRATION_END", stats)
	else
		BackingPromotionLog("TEMP_SOURCE_MIGRATION_FAILED", stats, "error")
	end
	if not ok then error("temporary vanilla source migration failed: " .. tostring(migration_error)) end
	SetLoadingPhase("Finishing the expanded map...")
	return true, results
end

-- Promote a genuinely vanilla-generated surface map to the deferred expanded destination without
-- replaying RandomMapGenerator. This deliberately exercises the engine's terrain setters as the
-- backing-resize boundary. If they cannot resize a live map, the transaction fails closed and the
-- diagnostics preserve every observed pre/post dimension; no source marker or generator result is
-- silently accepted as expanded.
local function PromoteDeferredExpandedBacking(map, reason)
	if not map or map.SuperBigMapDeferredBackingPromotion ~= true then return true, "not-required" end
	if map.SuperBigMapBackingPromotionComplete == true then return true, "already-complete" end
	local mapdata = map.mapdata
	local terrain_api = Global("terrain")
	local grid_to_compute = Global("GridToCompute")
	local new_compute_grid = Global("NewComputeGrid")
	local is_compute_grid = Global("IsComputeGrid")
	local grid_fill = Global("GridFill")
	local grid_min_max = Global("GridMinMax")
	local box_fn = Global("box")
	local point_fn = Global("point")
	local hex_to_world = Global("HexToWorld")
	local const_tbl = Global("const")
	local tile = type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize) or nil
	local desired_w = tonumber(map.SuperBigMapDesiredWidthTiles)
	local desired_h = tonumber(map.SuperBigMapDesiredHeightTiles)
	local source_w = tonumber(map.SuperBigMapGeneratorWidthTiles)
	local source_h = tonumber(map.SuperBigMapGeneratorHeightTiles)
	if type(mapdata) ~= "table" or type(terrain_api) ~= "table"
		or type(terrain_api.GetHeightGrid) ~= "function"
		or type(terrain_api.SetHeightGrid) ~= "function"
		or type(terrain_api.GetTypeGrid) ~= "function"
		or type(terrain_api.SetTypeGrid) ~= "function"
		or type(grid_to_compute) ~= "function" or type(new_compute_grid) ~= "function"
		or type(is_compute_grid) ~= "function" or type(grid_fill) ~= "function"
		or type(box_fn) ~= "function" or type(point_fn) ~= "function"
		or type(hex_to_world) ~= "function" or not tile or tile <= 0
		or not desired_w or not desired_h or not source_w or not source_h
		or desired_w <= source_w or desired_h <= source_h then
		return false, "required-promotion-api-or-dimensions-unavailable"
	end

	local ticks = Global("GetPreciseTicks") or Global("RealTime")
	local function now()
		if type(ticks) == "function" then
			local ok, value = pcall(ticks)
			if ok and type(value) == "number" then return value end
		end
		return 0
	end
	local function grid_size(grid)
		local ok, width, height = pcall(function() return grid:size() end)
		if not ok then return nil, nil end
		return width, height or width
	end
	local function grid_summary(grid)
		local width, height = grid_size(grid)
		local summary = { grid = tostring(grid), width = tostring(width), height = tostring(height) }
		if width and height and type(grid.get) == "function" then
			local probes = {
				{ 0, 0 }, { math.floor((width - 1) / 2), math.floor((height - 1) / 2) },
				{ width - 1, height - 1 },
			}
			local values = {}
			for i = 1, #probes do
				local x, y = probes[i][1], probes[i][2]
				local ok_value, value = pcall(grid.get, grid, x, y)
				values[#values + 1] = tostring(x) .. ":" .. tostring(y) .. "="
					.. tostring(ok_value and value or "ERROR")
			end
			summary.probes = table.concat(values, ",")
		end
		if type(grid_min_max) == "function" then
			local ok_range, minimum, maximum = pcall(grid_min_max, grid)
			if ok_range then summary.minimum, summary.maximum = minimum, maximum end
		end
		return summary
	end

	local started = now()
	local stats = {
		reason = tostring(reason), map = tostring(map.name),
		source_tiles = tostring(source_w) .. "x" .. tostring(source_h),
		destination_tiles = tostring(desired_w) .. "x" .. tostring(desired_h),
		mapdata_before = tostring(mapdata.Width) .. "x" .. tostring(mapdata.Height),
		map_fields_before = tostring(map.Width) .. "x" .. tostring(map.Height),
		hex_fields_before = tostring(map.hex_width) .. "x" .. tostring(map.hex_height),
		pass_border_before = tostring(mapdata.PassBorder),
	}
	pcall(function()
		local width, height = map:GetMapSize()
		stats.map_get_size_before = tostring(width) .. "x" .. tostring(height)
	end)
	if type(terrain_api.HeightMapSize) == "function" then
		local ok, width, height = pcall(terrain_api.HeightMapSize, map)
		if ok then stats.height_size_before = tostring(width) .. "x" .. tostring(height or width) end
	end
	if type(terrain_api.TypeMapSize) == "function" then
		local ok, width, height = pcall(terrain_api.TypeMapSize, map)
		if ok then stats.type_size_before = tostring(width) .. "x" .. tostring(height or width) end
	end
	BackingPromotionLog("DEFERRED_BACKING_PROMOTION_BEGIN", stats)

	local height_raw, height_compute, height_target
	local type_raw, type_compute, type_target
	local pause = Global("PauseInfiniteLoopDetection")
	local resume = Global("ResumeInfiniteLoopDetection")
	if type(pause) == "function" then pcall(pause, "SBMDeferredBackingPromotion") end
	local promotion_ok, promotion_err = pcall(function()
		height_raw = terrain_api.GetHeightGrid(map)
		type_raw = terrain_api.GetTypeGrid(map)
		if not height_raw or not type_raw then error("source-terrain-grid-capture-failed") end
		local height_source_w, height_source_h = grid_size(height_raw)
		local type_source_w, type_source_h = grid_size(type_raw)
		if height_source_w ~= source_w or height_source_h ~= source_h
			or not type_source_w or not type_source_h then
			error(string.format("unexpected-source-grid-size:height=%sx%s type=%sx%s expected=%sx%s",
				tostring(height_source_w), tostring(height_source_h),
				tostring(type_source_w), tostring(type_source_h), tostring(source_w), tostring(source_h)))
		end
		stats.height_source = grid_summary(height_raw)
		stats.type_source = grid_summary(type_raw)
		BackingPromotionLog("DEFERRED_BACKING_SOURCE_CAPTURED", {
			height_width = height_source_w, height_height = height_source_h,
			type_width = type_source_w, type_height = type_source_h,
			height_probes = stats.height_source.probes, type_probes = stats.type_source.probes,
			height_minimum = tostring(stats.height_source.minimum),
			height_maximum = tostring(stats.height_source.maximum),
			type_minimum = tostring(stats.type_source.minimum),
			type_maximum = tostring(stats.type_source.maximum),
		})

		height_compute = grid_to_compute(height_raw)
		type_compute = grid_to_compute(type_raw)
		if not height_compute or not type_compute then error("GridToCompute-failed") end
		local height_fmt, height_bits = is_compute_grid(height_compute)
		local type_fmt, type_bits = is_compute_grid(type_compute)
		local type_target_w = math.max(1, math.floor(type_source_w * desired_w / source_w + 0.5))
		local type_target_h = math.max(1, math.floor(type_source_h * desired_h / source_h + 0.5))
		height_target = new_compute_grid(desired_w, desired_h, height_fmt, height_bits)
		type_target = new_compute_grid(type_target_w, type_target_h, type_fmt, type_bits)
		if not height_target or not type_target then error("destination-grid-allocation-failed") end
		local height_fill = height_compute:get(0, 0)
		local type_fill = type_compute:get(0, 0)
		grid_fill(height_target, height_fill)
		grid_fill(type_target, type_fill)
		height_target:copyrect(height_compute,
			box_fn(0, 0, height_source_w, height_source_h), point_fn(0, 0))
		type_target:copyrect(type_compute,
			box_fn(0, 0, type_source_w, type_source_h), point_fn(0, 0))
		BackingPromotionLog("DEFERRED_BACKING_DESTINATION_PREPARED", {
			height_target = tostring(desired_w) .. "x" .. tostring(desired_h),
			type_target = tostring(type_target_w) .. "x" .. tostring(type_target_h),
			height_format = tostring(height_fmt) .. ":" .. tostring(height_bits),
			type_format = tostring(type_fmt) .. ":" .. tostring(type_bits),
			height_fill = tostring(height_fill), type_fill = tostring(type_fill),
		})

		local desired_world_w, desired_world_h = desired_w * tile, desired_h * tile
		local hx0, hy0 = hex_to_world(0, 0)
		local hx1 = select(1, hex_to_world(1, 0))
		local _, hy1 = hex_to_world(0, 1)
		local hex_step_x, hex_step_y = math.abs(hx1 - hx0), math.abs(hy1 - hy0)
		if hex_step_x <= 0 or hex_step_y <= 0 then error("hex-step-unavailable") end
		local desired_hex_w = math.ceil(desired_world_w / hex_step_x)
		local desired_hex_h = math.ceil(desired_world_h / hex_step_y)
		stats.destination_world = tostring(desired_world_w) .. "x" .. tostring(desired_world_h)
		stats.destination_hex = tostring(desired_hex_w) .. "x" .. tostring(desired_hex_h)

		mapdata.Width, mapdata.Height = desired_w, desired_h
		local edge_border = 0
		local patch = type(const_tbl) == "table" and tonumber(const_tbl.MapPatchSize) or nil
		local requested_border = cfg_number("EXPANDED_MAP_EDGE_BORDER", -1)
		if requested_border > 0 and patch and patch > 0 then
			edge_border = math.floor((requested_border + patch - 1) / patch) * patch
		end
		mapdata.PassBorder = edge_border
		if type(mapdata.PassBorderTiles) == "number" then
			mapdata.PassBorderTiles = math.floor(edge_border / tile)
		end
		map.Width, map.Height = desired_world_w, desired_world_h
		map.hex_width, map.hex_height = desired_hex_w, desired_hex_h
		map.SuperBigMapExpandedWorldWidth = desired_world_w
		map.SuperBigMapExpandedWorldHeight = desired_world_h
		map.SuperBigMapExpandedHexWidth = desired_hex_w
		map.SuperBigMapExpandedHexHeight = desired_hex_h

		local height_set_started = now()
		local height_set_error = terrain_api.SetHeightGrid(map, height_target)
		stats.height_set_ms = now() - height_set_started
		stats.height_set_error = tostring(height_set_error)
		if height_set_error then error("SetHeightGrid:" .. tostring(height_set_error)) end
		local type_set_started = now()
		local type_set_error = terrain_api.SetTypeGrid(map, type_target)
		stats.type_set_ms = now() - type_set_started
		stats.type_set_error = tostring(type_set_error)
		if type_set_error then error("SetTypeGrid:" .. tostring(type_set_error)) end

		local height_after_w, height_after_h
		if type(terrain_api.HeightMapSize) == "function" then
			height_after_w, height_after_h = terrain_api.HeightMapSize(map)
			height_after_h = height_after_h or height_after_w
		end
		local type_after_w, type_after_h
		if type(terrain_api.TypeMapSize) == "function" then
			type_after_w, type_after_h = terrain_api.TypeMapSize(map)
			type_after_h = type_after_h or type_after_w
		end
		stats.height_size_after = tostring(height_after_w) .. "x" .. tostring(height_after_h)
		stats.type_size_after = tostring(type_after_w) .. "x" .. tostring(type_after_h)
		local map_size_w, map_size_h
		pcall(function() map_size_w, map_size_h = map:GetMapSize() end)
		stats.map_get_size_after = tostring(map_size_w) .. "x" .. tostring(map_size_h)
		if height_after_w ~= desired_w or height_after_h ~= desired_h
			or type_after_w ~= type_target_w or type_after_h ~= type_target_h
			or map_size_w ~= desired_world_w or map_size_h ~= desired_world_h then
			error("live-backing-did-not-resize-to-destination")
		end

		local invalidate_box = box_fn(0, 0, desired_world_w, desired_world_h)
		if type(map.RebuildGrids) == "function" then map:RebuildGrids(invalidate_box) end
		map.SuperBigMapDeferredBackingPromotion = false
		map.SuperBigMapBackingPromotionComplete = true
		map.SuperBigMapBackingPromotionStats = stats
	end)
	if type(resume) == "function" then pcall(resume, "SBMDeferredBackingPromotion") end
	local function free_grid(grid, raw)
		if grid and grid ~= raw then pcall(function() if type(grid.free) == "function" then grid:free() end end) end
	end
	free_grid(height_target, height_raw)
	free_grid(type_target, type_raw)
	free_grid(height_compute, height_raw)
	free_grid(type_compute, type_raw)
	stats.total_ms = now() - started
	stats.ok = promotion_ok
	stats.error = promotion_ok and "none" or tostring(promotion_err)
	map.SuperBigMapBackingPromotionStats = stats
	if not promotion_ok then
		BackingPromotionLog("DEFERRED_BACKING_PROMOTION_FAILED", stats, "error")
		return false, tostring(promotion_err)
	end
	BackingPromotionLog("DEFERRED_BACKING_PROMOTION_END", stats)
	return true, "promoted"
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
		and generator_class.ProcEnd == State.generator_proc_end_wrapper
		and generator_class.OnGenerateLogic == State.generator_on_generate_logic_wrapper then
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
	if generator_class.OnGenerateLogic ~= State.generator_on_generate_logic_wrapper then
		State.generator_original_on_generate_logic = generator_class.OnGenerateLogic
	end
	local original_generate = State.generator_original_generate
	local original_do_generate = State.generator_original_do_generate
	local original_proc_start = State.generator_original_proc_start
	local original_proc_end = State.generator_original_proc_end
	local original_on_generate_logic = State.generator_original_on_generate_logic

	-- OnGenerateLogic receives the generator's private print function and random
	-- helpers in `env`. The RMG warnings never call global `print`, so this is the
	-- authoritative interception point for exact per-run enrichment targets.
	if type(original_on_generate_logic) == "function" then
		local on_generate_logic_wrapper = function(self, env, ...)
			if type(env) ~= "table" then
				return original_on_generate_logic(self, env, ...)
			end
			local map = env.map
			local environment = type(map) == "table" and type(map.mapdata) == "table"
				and map.mapdata.Environment or nil
			-- Only expanded-map generations enter this wrapper. Underground is included so its
			-- randomized requested resource totals survive a native placement shortfall; the
			-- vanilla-first completion wrapper below never changes cave masks or requested counts.
			if State.rmg_placement_active_map ~= map then
				return original_on_generate_logic(self, env, ...)
			end
			local is_underground = environment == "Underground"
			local rhelpers = env.rhelpers
			local saved_rrand = type(rhelpers) == "table" and rhelpers[2] or nil
			local saved_grand = type(rhelpers) == "table" and rhelpers[5] or nil
			local saved_rm_print = env.rm_print
			local saved_get_playable_area = env.GetPlayableArea
			local saved_gen_marker_obj = env.GenMarkerObj
			local saved_proc_invoke = env.ProcInvoke
			local saved_generate_resource_info = Global("GenerateResourceInfo")
			local saved_grid_min_max = Global("GridMinMax")
			local saved_hex_get_nearest_center = Global("HexGetNearestCenter")
			local generate_resource_info_wrapper
			local grid_min_max_wrapper
			local grid_min_max_installed_in_closure = false
			local grid_min_max_closure_had_raw = false
			local grid_min_max_closure_raw
			local hex_get_nearest_center_wrapper
			local hex_hook_installed_in_closure = false
			local hex_closure_had_raw = false
			local hex_closure_raw
			local gen_marker_obj_wrapper
			local proc_invoke_wrapper
			local feature_deposit_context
			local deposit_layer_filter_restores = {}
			local base_play_zone_snapshot
			local alignment_debug_log = SuperBigMap.DebugLog
			local alignment_trace_enabled = false
			if type(alignment_debug_log) == "table" and type(alignment_debug_log.On) == "function" then
				local ok_trace, trace = pcall(alignment_debug_log.On, "RmgAlignmentExhaustive")
				alignment_trace_enabled = ok_trace and trace == true
			end
			local function AlignmentTrace(message, data)
				if alignment_trace_enabled and type(alignment_debug_log.Info) == "function" then
					pcall(alignment_debug_log.Info, "RmgAlignmentExhaustive", message, data)
				end
			end
			local function point_xyz(pos)
				if not pos then return nil end
				local ok_xyz, x, y, z = pcall(function() return pos:xyz() end)
				if ok_xyz and x ~= nil and y ~= nil then return x, y, z end
				local ok_xy
				ok_xy, x, y = pcall(function() return pos:xy() end)
				if ok_xy and x ~= nil and y ~= nil then return x, y, nil end
				return nil
			end
			local function xy_key(pos)
				local x, y = point_xyz(pos)
				return x ~= nil and y ~= nil and (tostring(x) .. ":" .. tostring(y)) or nil
			end
			local function origin_desc(origin)
				if type(origin) ~= "table" then return tostring(origin or "unknown") end
				return table.concat({
					"proc=" .. tostring(origin.proc or "?"),
					"resource=" .. tostring(origin.resource or "?"),
					"index=" .. tostring(origin.index or "?"),
					"shape=" .. tostring(origin.shape or "?"),
					"source=" .. tostring(origin.source or "?"),
					"aligns=" .. tostring(origin.aligns),
					"role=" .. tostring(origin.role or "?"),
					"layer=" .. tostring(origin.layer or "?"),
					"grid=" .. tostring(origin.grid or "?"),
				}, ";")
			end
			local alignment_trace = {
				calls = 0, duplicate_calls = 0, duplicate_hexes = 0,
				candidate_collisions = 0, warning_count = 0,
				markers_on_duplicate_hexes = 0, unknown_origins = 0,
				hash_failures = 0, breakthrough_calls = 0,
				breakthrough_collisions = 0, breakthrough_replacements = 0,
				breakthrough_retained_collisions = 0,
				breakthrough_partial_quota_calls = 0,
				factory_calls = 0, factory_duplicate_calls = 0,
				factory_duplicate_hexes = 0, factory_hash_failures = 0,
				factory_unmatched_candidates = 0,
				by_hash = {}, duplicate_hashes = {}, by_aligned_xy = {},
				factory_by_hash = {}, factory_duplicate_hashes = {},
			}
			local candidate_origins_by_world_xy = {}
			local candidate_predictions_by_hash = {}
			local candidate_predictions_by_aligned_xy = {}
			local candidate_trace_sequence = 0
			local aligned_origin_by_hash = {}
			local consumed_aligned_hexes = {}
			local debug_lib = Global("debug")
			local getfenv_fn = Global("getfenv")
			local function function_environment(fn)
				if type(fn) ~= "function" then return nil, "not_a_function" end
				-- The mod sandbox exposes Lua 5.1 function environments even when the
				-- debug upvalue API is stripped. This table is the authoritative global
				-- lookup environment used by the compiled RandomMapGenerator closure.
				if type(getfenv_fn) == "function" then
					local ok_env, value = pcall(getfenv_fn, fn)
					if ok_env and type(value) == "table" then return value, "getfenv" end
				end
				if type(debug_lib) == "table" and type(debug_lib.getfenv) == "function" then
					local ok_env, value = pcall(debug_lib.getfenv, fn)
					if ok_env and type(value) == "table" then return value, "debug.getfenv" end
				end
				if type(debug_lib) == "table" and type(debug_lib.getupvalue) == "function" then
					for i = 1, 64 do
						local ok_up, name, value = pcall(debug_lib.getupvalue, fn, i)
						if not ok_up or name == nil then break end
						if name == "_ENV" and type(value) == "table" then
							return value, "debug.getupvalue:_ENV"
						end
					end
				end
				return nil, "unavailable"
			end
			-- The comparison observer deliberately sits beneath this wrapper. Introspect its saved
			-- vanilla function rather than the observer closure so private GridMinMax/alignment access
			-- remains exactly the same as it is without diagnostics.
			local closure_environment_target = original_on_generate_logic
			if closure_environment_target == State.enrichment_spread_on_generate_wrapper
				and type(State.enrichment_spread_original_on_generate) == "function" then
				closure_environment_target = State.enrichment_spread_original_on_generate
			end
			local generator_closure_env, generator_closure_env_source =
				function_environment(closure_environment_target)
			local function closure_global(name, fallback)
				if type(generator_closure_env) == "table" then
					local ok_value, value = pcall(function() return generator_closure_env[name] end)
					if ok_value and value ~= nil then return value end
				end
				return fallback
			end
			local const_tbl = Global("const")
			local complement_work_step = type(const_tbl) == "table"
				and type(const_tbl.TypeTileSize) == "number"
				and type(const_tbl.PrefabWorkRatio) == "number"
				and const_tbl.TypeTileSize * const_tbl.PrefabWorkRatio or nil
			-- Use the same closure environment as stock OnGenerateLogic. The compiled game
			-- function owns a private _ENV, so _G may expose a different function identity.
			local hex_get_nearest_center = closure_global("HexGetNearestCenter", saved_hex_get_nearest_center)
			local alignment_hash = closure_global("xxhash", Global("xxhash"))
			saved_grid_min_max = closure_global("GridMinMax", saved_grid_min_max)
			local closure_world_to_hex = closure_global("WorldToHex", Global("WorldToHex"))
			local closure_grid_dest = closure_global("GridDest", Global("GridDest"))
			local closure_grid_not = closure_global("GridNot", Global("GridNot"))
			local closure_new_grid = closure_global("NewGrid", Global("NewGrid"))
			local closure_new_compute_grid = closure_global("NewComputeGrid", Global("NewComputeGrid"))
			local closure_is_compute_grid = closure_global("IsComputeGrid", Global("IsComputeGrid"))
			local closure_grid_fill = closure_global("GridFill", Global("GridFill"))
			local closure_mask_buildable_grid =
				closure_global("MaskBuildableGrid", Global("MaskBuildableGrid"))
			local closure_build_unbuildable_z = closure_global("buildUnbuildableZ", Global("buildUnbuildableZ"))
			local closure_init_buildable_grid = closure_global("InitBuildableGrid", Global("InitBuildableGrid"))
			local closure_process_buildable_grid = closure_global("ProcessBuildableGrid", Global("ProcessBuildableGrid"))
			local closure_hex_to_world = closure_global("HexToWorld", Global("HexToWorld"))
			local closure_storage_to_hex = closure_global("StorageToHex", Global("StorageToHex"))
			local buildable_grid_class = closure_global("BuildableGrid", Global("BuildableGrid"))
			local saved_buildable_grid_build = type(buildable_grid_class) == "table"
				and buildable_grid_class.Build or nil
			local rebuild_buildable_grid_wrapper
			local rebuild_buildable_grid_installed = false
			local rebuild_buildable_grid_had_raw = false
			local rebuild_buildable_grid_raw
			local rebuild_buildable_grid_calls = 0
			local closure_metatable
			pcall(function() closure_metatable = getmetatable(generator_closure_env) end)
			AlignmentTrace("runtime function-environment capability", {
				environment_source = tostring(generator_closure_env_source),
				environment = tostring(generator_closure_env),
				environment_metatable = tostring(closure_metatable),
				environment_is_global = generator_closure_env == _G,
				getfenv_type = type(getfenv_fn),
				debug_type = type(debug_lib),
				debug_getfenv_type = type(debug_lib) == "table" and type(debug_lib.getfenv) or "n/a",
				debug_getupvalue_type = type(debug_lib) == "table" and type(debug_lib.getupvalue) or "n/a",
				hex_private = tostring(hex_get_nearest_center),
				hex_global = tostring(saved_hex_get_nearest_center),
				hash_private = tostring(alignment_hash),
				grid_min_max_private = tostring(saved_grid_min_max),
			})
			local function predict_alignment(pos)
				if not pos or type(complement_work_step) ~= "number" or complement_work_step <= 0
					or type(hex_get_nearest_center) ~= "function" or type(alignment_hash) ~= "function" then
					return nil
				end
				local ok_align, aligned = pcall(function()
					return hex_get_nearest_center(pos * complement_work_step)
				end)
				local aligned_x, aligned_y = point_xyz(aligned)
				if not ok_align or not aligned or aligned_x == nil or aligned_y == nil then return nil end
				local ok_hash, hash = pcall(alignment_hash, aligned)
				if not ok_hash or hash == nil then return nil end
				local aligned_z
				aligned_x, aligned_y, aligned_z = point_xyz(aligned)
				local q, r
				if type(closure_world_to_hex) == "function" then
					local ok_hex, hq, hr = pcall(closure_world_to_hex, aligned)
					if ok_hex then q, r = hq, hr end
				end
				-- Match the engine's collision identity whenever the global functions exposed to
				-- the mod sandbox are the same ones used by the private RMG closure. The marker-
				-- factory audit below independently verifies the actual post-snap result.
				return tostring(hash), aligned, aligned_x, aligned_y, aligned_z, q, r
			end
			local function aligned_hex_key(pos)
				return predict_alignment(pos)
			end
			-- Conservative set of positions consumed by native placement searches. NewAnomaly
			-- erodes the shared layers even when its rolled count is already full, so retaining
			-- every returned point mirrors the engine's own exclusion behavior. Breakthrough
			-- points are added separately from GridMinMax below.
			local consumed_search_positions = {}
			local function record_consumed_position(pos, occupies_aligned_hex, origin)
				if not pos then return false end
				local x, y = point_xyz(pos)
				if x == nil or y == nil then return false end
				consumed_search_positions[tostring(x) .. ":" .. tostring(y)] = { x = x, y = y }
				local world_key
				if alignment_trace_enabled and type(complement_work_step) == "number" then
					local ok_world, world_pos = pcall(function() return pos * complement_work_step end)
					world_key = ok_world and xy_key(world_pos) or nil
				end
				if world_key then
					local origins = candidate_origins_by_world_xy[world_key]
					if not origins then
						origins = {}
						candidate_origins_by_world_xy[world_key] = origins
					end
					origins[#origins + 1] = origin or { proc = "unknown", resource = "unknown" }
				end
				if alignment_trace_enabled then
					candidate_trace_sequence = candidate_trace_sequence + 1
					local predicted_hash, predicted_pos, predicted_x, predicted_y, predicted_z, q, r =
						predict_alignment(pos)
					local predicted_xy = predicted_pos and xy_key(predicted_pos) or nil
					local candidate_record = {
						index = candidate_trace_sequence,
						raw_work_x = x, raw_work_y = y,
						raw_world_key = world_key,
						predicted_hash = predicted_hash,
						predicted_x = predicted_x, predicted_y = predicted_y,
						predicted_z = predicted_z, predicted_xy = predicted_xy,
						q = q, r = r,
						declared_aligns = occupies_aligned_hex == true,
						origin = origin or { proc = "unknown", resource = "unknown" },
						origin_text = origin_desc(origin),
					}
					if predicted_hash then
						local predictions = candidate_predictions_by_hash[predicted_hash]
						if not predictions then
							predictions = {}
							candidate_predictions_by_hash[predicted_hash] = predictions
						end
						predictions[#predictions + 1] = candidate_record
					end
					if predicted_xy then
						local predictions = candidate_predictions_by_aligned_xy[predicted_xy]
						if not predictions then
							predictions = {}
							candidate_predictions_by_aligned_xy[predicted_xy] = predictions
						end
						predictions[#predictions + 1] = candidate_record
					end
					AlignmentTrace("sandbox-safe candidate prediction", {
						candidate_index = candidate_record.index,
						raw_work_x = x, raw_work_y = y,
						raw_world = tostring(world_key),
						predicted_hash = tostring(predicted_hash),
						predicted_aligned = tostring(predicted_x) .. ":" .. tostring(predicted_y)
							.. ":" .. tostring(predicted_z),
						q = tostring(q), r = tostring(r),
						declared_aligns = occupies_aligned_hex == true,
						origin = candidate_record.origin_text,
					})
				end
				if occupies_aligned_hex then
					local hex_key = aligned_hex_key(pos)
					if hex_key then
						if alignment_trace_enabled then
							local existing = aligned_origin_by_hash[hex_key]
							if existing then
								alignment_trace.candidate_collisions = alignment_trace.candidate_collisions + 1
								AlignmentTrace("candidate census already contains aligned hex", {
									hash = hex_key, work_x = x, work_y = y,
									existing = origin_desc(existing), incoming = origin_desc(origin),
								})
							end
							-- Mirror the engine's predecessor update for third-and-later collisions.
							aligned_origin_by_hash[hex_key] = origin or {
								proc = "unknown", resource = "unknown", index = "?", shape = "?",
							}
						end
						consumed_aligned_hexes[hex_key] = true
					end
				end
				return true
			end

			-- Read-only audit at the exact engine function lookup used by final alignment.
			-- Unlike debug.getupvalue, getfenv is available in the retail mod sandbox, so a
			-- temporary raw entry in the generator's own environment observes the real
			-- HexGetNearestCenter call. The original function is called once and unchanged.
			local function audit_final_hex_alignment(map_pos, aligned)
				alignment_trace.calls = alignment_trace.calls + 1
				local index = alignment_trace.calls
				local raw_x, raw_y, raw_z = point_xyz(map_pos)
				local aligned_x, aligned_y, aligned_z = point_xyz(aligned)
				local raw_key, aligned_key = xy_key(map_pos), xy_key(aligned)
				local ok_hash, native_hash = false, nil
				if type(alignment_hash) == "function" then
					ok_hash, native_hash = pcall(alignment_hash, aligned)
				end
				if not ok_hash or native_hash == nil then
					alignment_trace.hash_failures = alignment_trace.hash_failures + 1
				end
				local hash_key = ok_hash and native_hash ~= nil and native_hash
					or ("unavailable:" .. tostring(index))
				local hash_text = tostring(hash_key)
				local q, r
				if type(closure_world_to_hex) == "function" then
					local ok_hex, hq, hr = pcall(closure_world_to_hex, aligned)
					if ok_hex then q, r = hq, hr end
				end
				local origins = raw_key and candidate_origins_by_world_xy[raw_key] or nil
				local origin_parts = {}
				for i = 1, #(origins or {}) do
					origin_parts[#origin_parts + 1] = origin_desc(origins[i])
				end
				local origin_text = #origin_parts > 0
					and table.concat(origin_parts, " || ") or "unknown"
				if #origin_parts == 0 then
					alignment_trace.unknown_origins = alignment_trace.unknown_origins + 1
				end
				local previous = alignment_trace.by_hash[hash_key]
				local record = {
					index = index, hash = hash_key,
					raw_x = raw_x, raw_y = raw_y, raw_z = raw_z,
					aligned_x = aligned_x, aligned_y = aligned_y, aligned_z = aligned_z,
					aligned_key = aligned_key, q = q, r = r, origin = origin_text,
				}
				if previous then
					alignment_trace.duplicate_calls = alignment_trace.duplicate_calls + 1
					if not alignment_trace.duplicate_hashes[hash_key] then
						alignment_trace.duplicate_hashes[hash_key] = true
						alignment_trace.duplicate_hexes = alignment_trace.duplicate_hexes + 1
					end
					AlignmentTrace("AUTHORITATIVE duplicate aligned hex via private environment", {
						hash = hash_text, q = tostring(q), r = tostring(r),
						first_index = previous.index, incoming_index = index,
						first_raw = tostring(previous.raw_x) .. ":" .. tostring(previous.raw_y),
						incoming_raw = tostring(raw_x) .. ":" .. tostring(raw_y),
						first_aligned = tostring(previous.aligned_x) .. ":" .. tostring(previous.aligned_y),
						incoming_aligned = tostring(aligned_x) .. ":" .. tostring(aligned_y),
						same_aligned_xy = previous.aligned_key == aligned_key,
						first_origin = previous.origin, incoming_origin = origin_text,
					})
				end
				alignment_trace.by_hash[hash_key] = record
				local aligned_calls = aligned_key and alignment_trace.by_aligned_xy[aligned_key] or nil
				if aligned_key and not aligned_calls then
					aligned_calls = {}
					alignment_trace.by_aligned_xy[aligned_key] = aligned_calls
				end
				if aligned_calls then aligned_calls[#aligned_calls + 1] = record end
				AlignmentTrace("final alignment input via private environment", {
					index = index, hash = hash_text,
					duplicate_of = previous and previous.index or "none",
					raw_work_x = type(raw_x) == "number" and type(complement_work_step) == "number"
						and raw_x / complement_work_step or "n/a",
					raw_work_y = type(raw_y) == "number" and type(complement_work_step) == "number"
						and raw_y / complement_work_step or "n/a",
					raw_world = tostring(raw_x) .. ":" .. tostring(raw_y) .. ":" .. tostring(raw_z),
					aligned_world = tostring(aligned_x) .. ":" .. tostring(aligned_y) .. ":" .. tostring(aligned_z),
					q = tostring(q), r = tostring(r), origin = origin_text,
					census_origin = origin_desc(aligned_origin_by_hash[hash_text]),
				})
			end
			if alignment_trace_enabled and type(generator_closure_env) == "table"
				and type(hex_get_nearest_center) == "function" then
				hex_get_nearest_center_wrapper = function(pos, ...)
					local hex_results = PackValues(hex_get_nearest_center(pos, ...))
					local stack = State.rmg_placement_proc_stack
					local proc = type(stack) == "table" and tostring(stack[#stack]) or ""
					if proc == "PlaceAnomalies_AlignToHexGrid" then
						pcall(audit_final_hex_alignment, pos, hex_results[1])
					end
					return Unpack(hex_results, 1, hex_results.n)
				end
				hex_closure_raw = rawget(generator_closure_env, "HexGetNearestCenter")
				hex_closure_had_raw = hex_closure_raw ~= nil
				local ok_install = pcall(rawset, generator_closure_env,
					"HexGetNearestCenter", hex_get_nearest_center_wrapper)
				hex_hook_installed_in_closure = ok_install
					and rawget(generator_closure_env, "HexGetNearestCenter")
						== hex_get_nearest_center_wrapper
				AlignmentTrace("private-environment final Hex hook", {
					installed = hex_hook_installed_in_closure,
					environment_source = tostring(generator_closure_env_source),
					had_raw_entry = hex_closure_had_raw,
					original = tostring(hex_get_nearest_center),
					wrapper = tostring(hex_get_nearest_center_wrapper),
				})
			end
			local rolls, roll_index = {}, 0
			local roll_specs = {
				{ key = "event_base", value = self.AnomEventCount },
				{ key = "event_bonus", value = self.BonusCountEvent },
				{ key = "unlock", value = self.AnomTechUnlockCount },
				{ key = "complete_base", value = self.AnomFreeTechCount },
				{ key = "complete_bonus", value = self.BonusCountFreeTech },
				{ key = "breakthrough_bonus", value = self.BonusCountBreakthrough },
			}

			if type(map) == "table" then
				map.SuperBigMapExpectedResourceCounts = {}
				map.SuperBigMapExpectedResourceCountsByLayer = {}
				map.SuperBigMapResourceResidualShortfalls = {}
				map.SuperBigMapResourceTargetCapture = false
				map.SuperBigMapExpectedAnomalyCounts = {}
				map.SuperBigMapAnomalyTargetRolls = rolls
				map.SuperBigMapAnomalyTargetCapture = false
				map.SuperBigMapRmgGenZoneCoverage = nil
				map.SuperBigMapRmgGenZoneCoverageInfo = nil
				map.SuperBigMapRmgPlayableCoverage = nil
				map.SuperBigMapRmgPlayableCoverageInfo = nil
				local gen_area = env.gen_area_unscaled
				local gen_zone = env.gen_zone
				local gw, gh
				if gen_zone and type(gen_zone.size) == "function" then
					local ok_size, w, h = pcall(gen_zone.size, gen_zone)
					if ok_size then gw, gh = w, h end
				end
				local total = type(gw) == "number" and type(gh) == "number" and gw * gh or nil
				if type(gen_area) == "number" and gen_area > 0 and type(total) == "number" and total > 0 then
					local coverage = gen_area * 1.0 / total
					map.SuperBigMapRmgGenZoneCoverage = coverage
					map.SuperBigMapRmgGenZoneCoverageInfo = {
						coverage_source = "env.gen_area_unscaled / env.gen_zone:size",
						gen_cells = gen_area, gen_span_cells = total,
						grid_w = gw, grid_h = gh,
						cov_permille = math.floor(coverage * 1000),
					}
				end
			end

			local function capture_resource_info(res_info, source)
				if type(map) ~= "table" or type(res_info) ~= "table" then return false end
				local captured = 0
				for resource, info in pairs(res_info) do
					if type(resource) == "string" and type(info) == "table" then
						local layers, total = {}, 0
						for _, layer in ipairs({ "surf", "subs", "terr" }) do
							local count = type(info[layer]) == "table" and info[layer].count or nil
							if type(count) == "number" then
								layers[layer] = count
								total = total + count
							end
						end
						if next(layers) then
							map.SuperBigMapExpectedResourceCounts[resource] = total
							map.SuperBigMapExpectedResourceCountsByLayer[resource] = layers
							captured = captured + 1
						end
					end
				end
				if captured > 0 then
					map.SuperBigMapResourceTargetCapture = source
					return true
				end
				return false
			end

			local precomputed_res_info = self.ResInfo
			if precomputed_res_info == nil and type(self.GetProperty) == "function" then
				local ok, value = pcall(self.GetProperty, self, "ResInfo")
				if ok then precomputed_res_info = value end
			end
			local have_resource_targets = capture_resource_info(precomputed_res_info, "generator ResInfo")
			if not have_resource_targets and type(saved_generate_resource_info) == "function" then
				generate_resource_info_wrapper = function(...)
					local res_info = saved_generate_resource_info(...)
					capture_resource_info(res_info, "GenerateResourceInfo return")
					return res_info
				end
				rawset(_G, "GenerateResourceInfo", generate_resource_info_wrapper)
			end

			local function publish_anomaly_targets()
				if type(map) ~= "table" or roll_index < #roll_specs then return end
				map.SuperBigMapExpectedAnomalyCounts = {
					sequence = (rolls.event_base or 0) + (rolls.event_bonus or 0),
					unlock = rolls.unlock or 0,
					complete = (rolls.complete_base or 0) + (rolls.complete_bonus or 0),
				}
				map.SuperBigMapRolledBreakthroughCount =
					(type(self.AnomBreakthroughCount) == "number" and self.AnomBreakthroughCount or 0)
					+ (rolls.breakthrough_bonus or 0)
				map.SuperBigMapAnomalyTargetCapture = "OnGenerateLogic rrand"
			end

			-- The six-call anomaly classifier is surface-specific. Underground resource totals
			-- are still captured authoritatively through GenerateResourceInfo below, while cave
			-- anomaly families retain their untouched engine flow.
			if not is_underground and type(saved_rrand) == "function" then
				rhelpers[2] = function(value, ...)
					local result = saved_rrand(value, ...)
					local next_index = roll_index + 1
					local spec = roll_specs[next_index]
					-- These are the first six rrand calls in the engine's
					-- OnGenerateLogic (the anomaly_info constructor). Verify the
					-- argument identity so a future engine change fails closed.
					if spec and rawequal(value, spec.value) then
						roll_index = next_index
						rolls[spec.key] = result
						publish_anomaly_targets()
					end
					return result
				end
			end

			-- Proc_ResolveBuildable rebuilds map.buildable at the source-sized view, but native
			-- MaskBuildableGrid derives its cell-to-world step from the real expanded Terrain
			-- backing. Lua-facing Map size overrides cannot change that native field. Recreate the
			-- vanilla transaction without approximating it: enlarge the temporary work mask by the
			-- exact expanded/source ratio, pad the source buildable grid to the real expanded hex
			-- dimensions, invoke native MaskBuildableGrid, then crop the source work rectangle.
			-- For every source cell, native now evaluates the same world coordinate, same hex, and
			-- same buildable value it would on a genuinely vanilla allocation. No expected count,
			-- checksum, seed, or compensating coordinate participates in the algorithm.
			local function source_mask_log(message, data, level)
				local debug_log = SuperBigMap.DebugLog
				if not debug_log then return end
				local fn = level == "error" and debug_log.Error
					or (level == "warn" and debug_log.Warn or debug_log.Info)
				if type(fn) == "function" then
					pcall(fn, "EnrichmentSpreadComparison", message, data)
				end
			end

			-- SOURCE BUILDABLE RAW-GRID CAPACITY BRIDGE. BuildableGrid:Build is a two-stage vanilla
			-- transaction: InitBuildableGrid samples terrain/collision state into a raw hex grid,
			-- then ProcessBuildableGrid classifies connected areas. On an expanded allocation the
			-- native initializer can address the real expanded backing even while every logical map
			-- dimension exposes the vanilla source. A source-sized output silently changes native edge
			-- handling. Give the initializer full backing capacity WITHOUT changing the logical source
			-- view, crop the source rectangle, and run stock processing. Native code consequently owns
			-- PassBorder semantics; no Lua approximation of its hex-edge test is involved.
			-- Every dimension and threshold comes from the live map/vanilla globals; no expected cell
			-- count, checksum, seed, preset, or compensating coordinate participates in the result.
			local function source_buildable_trace(label, grid, classification, extra)
				local diagnostics = SuperBigMap.EnrichmentSpreadDiagnostics
				if diagnostics and type(diagnostics.TraceGridForensics) == "function" then
					local ok, traced = pcall(diagnostics.TraceGridForensics,
						map, label, grid, classification, extra)
					local status = {
						label = tostring(label), classification = tostring(classification),
						ok = ok, traced = tostring(traced), grid = tostring(grid),
					}
					if ok then
						source_mask_log("SOURCE_BUILDABLE_TRACE_STATUS", status)
					else
						source_mask_log("SOURCE_BUILDABLE_TRACE_STATUS", status, "error")
					end
				else
					source_mask_log("SOURCE_BUILDABLE_TRACE_STATUS", {
						label = tostring(label), classification = tostring(classification),
						ok = false, traced = "diagnostics-unavailable", grid = tostring(grid),
					}, "warn")
				end
			end

			local function source_buildable_compare(label, grid_a, grid_b,
				width, height, unbuildable_z, extra)
				local stats = {
					label = tostring(label), grid_a = tostring(grid_a), grid_b = tostring(grid_b),
					width = width, height = height, cells = width * height,
					exact_differences = 0, classification_differences = 0,
					a_buildable_only = 0, b_buildable_only = 0,
					exact_bbox = "none", classification_bbox = "none",
				}
				for key, value in pairs(extra or {}) do stats[key] = value end
				local min_x, min_y, max_x, max_y
				local class_min_x, class_min_y, class_max_x, class_max_y
				for y = 0, height - 1 do
					for x = 0, width - 1 do
						local a = grid_a:get(x, y)
						local b = grid_b:get(x, y)
						if a ~= b then
							stats.exact_differences = stats.exact_differences + 1
							min_x = min_x and math.min(min_x, x) or x
							min_y = min_y and math.min(min_y, y) or y
							max_x = max_x and math.max(max_x, x) or x
							max_y = max_y and math.max(max_y, y) or y
						end
						local a_buildable = a ~= unbuildable_z
						local b_buildable = b ~= unbuildable_z
						if a_buildable ~= b_buildable then
							stats.classification_differences = stats.classification_differences + 1
							if a_buildable then
								stats.a_buildable_only = stats.a_buildable_only + 1
							else
								stats.b_buildable_only = stats.b_buildable_only + 1
							end
							class_min_x = class_min_x and math.min(class_min_x, x) or x
							class_min_y = class_min_y and math.min(class_min_y, y) or y
							class_max_x = class_max_x and math.max(class_max_x, x) or x
							class_max_y = class_max_y and math.max(class_max_y, y) or y
							local q, r = closure_storage_to_hex(x, y)
							local world_x, world_y = closure_hex_to_world(q, r)
							source_mask_log("SOURCE_BUILDABLE_CLASSIFICATION_DIFFERENCE", {
								comparison = tostring(label), storage_x = x, storage_y = y,
								q = tostring(q), r = tostring(r),
								world_x = tostring(world_x), world_y = tostring(world_y),
								value_a = tostring(a), value_b = tostring(b),
								a_buildable = a_buildable, b_buildable = b_buildable,
							})
						end
					end
				end
				if min_x then
					stats.exact_bbox = tostring(min_x) .. ":" .. tostring(min_y)
						.. "-" .. tostring(max_x) .. ":" .. tostring(max_y)
				end
				if class_min_x then
					stats.classification_bbox = tostring(class_min_x) .. ":" .. tostring(class_min_y)
						.. "-" .. tostring(class_max_x) .. ":" .. tostring(class_max_y)
				end
				source_mask_log("SOURCE_BUILDABLE_GRID_COMPARISON", stats,
					stats.classification_differences > 0 and "warn" or nil)
				return stats
			end

			local function rebuild_source_buildable_grid(target_map)
				if is_underground
					or target_map ~= map
					or map.SuperBigMapDeferredBackingPromotion == true
					or not cfg_bool("EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE", false)
					or not cfg_bool("QUADRANT_LIMIT_BUILDABLE_GRID_TO_SOURCE", true) then
					return nil, "mode-not-eligible"
				end
				local desired_w = tonumber(map.SuperBigMapDesiredWidthTiles)
				local desired_h = tonumber(map.SuperBigMapDesiredHeightTiles)
				local generator_w = tonumber(map.SuperBigMapGeneratorWidthTiles)
				local generator_h = tonumber(map.SuperBigMapGeneratorHeightTiles)
				if not desired_w or not desired_h or not generator_w or not generator_h
					or desired_w <= generator_w or desired_h <= generator_h then
					return nil, "map-not-expanded"
				end

				local source_world_w = tonumber(map.SuperBigMapGeneratorWidth)
					or tonumber(map.SuperBigMapSourceWidth)
				local source_world_h = tonumber(map.SuperBigMapGeneratorHeight)
					or tonumber(map.SuperBigMapSourceHeight)
				local expanded_world_w = tonumber(map.SuperBigMapExpandedWorldWidth)
				local expanded_world_h = tonumber(map.SuperBigMapExpandedWorldHeight)
				local expanded_hex_w = tonumber(map.SuperBigMapExpandedHexWidth)
				local expanded_hex_h = tonumber(map.SuperBigMapExpandedHexHeight)
				local source_hex_w = tonumber(map.hex_width)
				local source_hex_h = tonumber(map.hex_height)
				local source_x = tonumber(map.SuperBigMapSourceX) or 0
				local source_y = tonumber(map.SuperBigMapSourceY) or 0
				if source_x ~= 0 or source_y ~= 0 then
					return nil, "nonzero-source-origin-unsupported"
				end
				if not source_world_w or not source_world_h or not expanded_world_w or not expanded_world_h
					or not expanded_hex_w or not expanded_hex_h or not source_hex_w or not source_hex_h
					or source_world_w <= 0 or source_world_h <= 0
					or source_hex_w <= 0 or source_hex_h <= 0
					or expanded_world_w <= source_world_w or expanded_world_h <= source_world_h
					or expanded_hex_w < source_hex_w or expanded_hex_h < source_hex_h then
					return nil, "bridge-dimensions-unavailable"
				end
				if type(closure_new_grid) ~= "function"
					or type(closure_init_buildable_grid) ~= "function"
					or type(closure_process_buildable_grid) ~= "function"
					or type(closure_hex_to_world) ~= "function"
					or type(closure_storage_to_hex) ~= "function" then
					return nil, "required-api-unavailable"
				end

				local unbuildable_z = 2 ^ 16 - 1
				if type(closure_build_unbuildable_z) == "function" then
					local ok_z, value = pcall(closure_build_unbuildable_z)
					if ok_z and type(value) == "number" then unbuildable_z = value end
				end
				local map_data = map.mapdata
				if type(map_data) ~= "table" then return nil, "mapdata-unavailable" end
				local pass_border = tonumber(map_data.PassBorder) or 0
				local guim = tonumber(closure_global("guim", Global("guim"))) or 1000
				local range = map_data.visible_height_range
				local range_from, range_to
				pcall(function()
					range_from = range and tonumber(range.from)
					range_to = range and tonumber(range.to)
				end)
				local init_params = {
					unbuildable_z = unbuildable_z,
					flat_threshold = closure_global("g_NCF_FlatThreshold", Global("g_NCF_FlatThreshold")),
					max_surface_height = closure_global("g_NCF_MaxSurfaceHeight", Global("g_NCF_MaxSurfaceHeight")),
					max_surface_error = closure_global("g_NCF_MaxSurfaceError", Global("g_NCF_MaxSurfaceError")),
					surface_types = closure_global("g_NCF_SurfaceTypes", Global("g_NCF_SurfaceTypes")),
					enum_flags = closure_global("g_NCF_EnumFlags", Global("g_NCF_EnumFlags")),
					ignore_game_flags = closure_global("g_NCF_IgnoreGameFlags", Global("g_NCF_IgnoreGameFlags")),
					map_border = pass_border,
					map_min_height = range_from and range_from * guim or 0,
					map_max_height = range_to and range_to * guim or unbuildable_z,
				}
				local process_params = {
					unbuildable_z = unbuildable_z,
					minsize = closure_global("g_NCF_FlatThresholdAreaMin", Global("g_NCF_FlatThresholdAreaMin")),
					maxsize = closure_global("g_NCF_FlatThresholdAreaMax", Global("g_NCF_FlatThresholdAreaMax")),
					mindelta = closure_global("g_NCF_FlatThresholdAreaMinHeightDelta",
						Global("g_NCF_FlatThresholdAreaMinHeightDelta")),
					maxdelta = closure_global("g_NCF_FlatThresholdAreaMaxHeightDelta",
						Global("g_NCF_FlatThresholdAreaMaxHeightDelta")),
					minarea = closure_global("g_NCF_MinArea", Global("g_NCF_MinArea")),
				}
				local required_init_params = {
					"unbuildable_z", "flat_threshold", "max_surface_height", "max_surface_error",
					"surface_types", "enum_flags", "ignore_game_flags", "map_border",
					"map_min_height", "map_max_height",
				}
				for i = 1, #required_init_params do
					local name = required_init_params[i]
					if type(init_params[name]) ~= "number" then
						return nil, "init-parameter-unavailable:" .. tostring(name)
					end
				end
				local required_process_params = {
					"unbuildable_z", "minsize", "maxsize", "mindelta", "maxdelta", "minarea",
				}
				for i = 1, #required_process_params do
					local name = required_process_params[i]
					if type(process_params[name]) ~= "number" then
						return nil, "process-parameter-unavailable:" .. tostring(name)
					end
				end

				local buildable = map.buildable
				if not buildable then
					local buildable_class = closure_global("BuildableGrid", Global("BuildableGrid"))
					if type(buildable_class) == "table" and type(buildable_class.new) == "function" then
						local ok_new, value = pcall(buildable_class.new, buildable_class)
						if ok_new then buildable = value; map.buildable = value end
					end
				end
				if not buildable then return nil, "buildable-object-unavailable" end

				local ticks = Global("GetPreciseTicks")
				local function now()
					if type(ticks) == "function" then
						local ok, value = pcall(ticks)
						if ok and type(value) == "number" then return value end
					end
					return 0
				end
				local started = now()
				local diagnostics_enabled = false
				local debug_log = SuperBigMap.DebugLog
				if debug_log and type(debug_log.On) == "function" then
					local ok_enabled, enabled = pcall(debug_log.On, "EnrichmentSpreadComparison")
					diagnostics_enabled = ok_enabled and enabled == true
				end
				local stats = {
					algorithm = "native InitBuildableGrid into full backing capacity under exact source view -> source crop -> native ProcessBuildableGrid",
					source_world = tostring(source_world_w) .. "x" .. tostring(source_world_h),
					expanded_world = tostring(expanded_world_w) .. "x" .. tostring(expanded_world_h),
					source_hex = tostring(source_hex_w) .. "x" .. tostring(source_hex_h),
					expanded_hex = tostring(expanded_hex_w) .. "x" .. tostring(expanded_hex_h),
					source_origin = tostring(source_x) .. ":" .. tostring(source_y),
					pass_border = pass_border, unbuildable_z = unbuildable_z,
					flat_threshold = init_params.flat_threshold,
					max_surface_height = init_params.max_surface_height,
					max_surface_error = init_params.max_surface_error,
					surface_types = init_params.surface_types,
					enum_flags = init_params.enum_flags,
					ignore_game_flags = init_params.ignore_game_flags,
					map_min_height = init_params.map_min_height,
					map_max_height = init_params.map_max_height,
					process_minsize = process_params.minsize,
					process_maxsize = process_params.maxsize,
					process_mindelta = process_params.mindelta,
					process_maxdelta = process_params.maxdelta,
					process_minarea = process_params.minarea,
					logical_view = "source",
					output_capacity = "expanded",
					border_mode = "native InitBuildableGrid under source view",
					diagnostic_shadow = diagnostics_enabled,
					old_grid = tostring(buildable.z_grid), old_grid_size = "unavailable",
				}
				pcall(function()
					local width, height = buildable.z_grid:size()
					stats.old_grid_size = tostring(width) .. "x" .. tostring(height or width)
				end)
				source_mask_log("SOURCE_BUILDABLE_BRIDGE_BEGIN", stats)

				local capacity_raw, source_raw, source_processed
				local direct_raw, direct_processed
				local pause = Global("PauseInfiniteLoopDetection")
				local resume = Global("ResumeInfiniteLoopDetection")
				if type(pause) == "function" then pcall(pause, "SBMSourceBuildableRawGridBridge") end
				local bridge_ok, bridge_err = pcall(function()
					capacity_raw = closure_new_grid(expanded_hex_w, expanded_hex_h, 16, unbuildable_z)
					source_raw = closure_new_grid(source_hex_w, source_hex_h, 16, unbuildable_z)
					source_processed = closure_new_grid(source_hex_w, source_hex_h, 16, unbuildable_z)
					if diagnostics_enabled then
						direct_raw = closure_new_grid(source_hex_w, source_hex_h, 16, unbuildable_z)
						direct_processed = closure_new_grid(source_hex_w, source_hex_h, 16, unbuildable_z)
					end
					if not capacity_raw or not source_raw or not source_processed
						or (diagnostics_enabled and (not direct_raw or not direct_processed)) then
						error("grid-allocation-failed")
					end
					stats.allocate_ms = now() - started

					-- The entire point of this bridge is the asymmetric transaction below: native output
					-- capacity matches the real backing, but every logical dimension stays source-sized.
					-- Assert that contract before entering native code and never rewrite these fields.
					local source_view_width, source_view_height = map.Width, map.Height
					local source_view_hex_width, source_view_hex_height = map.hex_width, map.hex_height
					local source_view_data_width, source_view_data_height = map_data.Width, map_data.Height
					local map_get_size = map.GetMapSize
					local terrain_api = closure_global("terrain", Global("terrain"))
					local terrain_get_size = type(terrain_api) == "table"
						and terrain_api.GetMapSize or nil
					local observed_map_w, observed_map_h, observed_terrain_w, observed_terrain_h
					if type(map_get_size) == "function" then
						local ok_size, width, height = pcall(map_get_size, map)
						if ok_size then observed_map_w, observed_map_h = width, height end
					end
					if type(terrain_get_size) == "function" then
						local ok_size, width, height = pcall(terrain_get_size, map)
						if ok_size then observed_terrain_w, observed_terrain_h = width, height end
					end
					local source_view_exact = source_view_width == source_world_w
						and source_view_height == source_world_h
						and source_view_hex_width == source_hex_w
						and source_view_hex_height == source_hex_h
						and source_view_data_width == generator_w
						and source_view_data_height == generator_h
						and observed_map_w == source_world_w and observed_map_h == source_world_h
						and observed_terrain_w == source_world_w and observed_terrain_h == source_world_h
					local view_audit = {
						exact = source_view_exact,
						map_fields = tostring(source_view_width) .. "x" .. tostring(source_view_height),
						hex_fields = tostring(source_view_hex_width) .. "x" .. tostring(source_view_hex_height),
						mapdata_tiles = tostring(source_view_data_width) .. "x" .. tostring(source_view_data_height),
						map_get_size = tostring(observed_map_w) .. "x" .. tostring(observed_map_h),
						terrain_get_size = tostring(observed_terrain_w) .. "x" .. tostring(observed_terrain_h),
						required_source_world = tostring(source_world_w) .. "x" .. tostring(source_world_h),
						required_source_hex = tostring(source_hex_w) .. "x" .. tostring(source_hex_h),
						required_source_tiles = tostring(generator_w) .. "x" .. tostring(generator_h),
						output_capacity = tostring(expanded_hex_w) .. "x" .. tostring(expanded_hex_h),
					}
					if source_view_exact then
						source_mask_log("SOURCE_BUILDABLE_LOGICAL_VIEW_AUDIT", view_audit)
					else
						source_mask_log("SOURCE_BUILDABLE_LOGICAL_VIEW_AUDIT", view_audit, "error")
					end
					if not source_view_exact then error("logical-source-view-not-exact") end

					source_mask_log("SOURCE_BUILDABLE_NATIVE_INIT_BEGIN", {
						logical_view = "source", logical_world = stats.source_world,
						logical_hex = stats.source_hex,
						output_capacity_hex = stats.expanded_hex,
						output_grid = tostring(capacity_raw), pass_border = pass_border,
						map_get_size_function = tostring(map_get_size),
						terrain_get_size_function = tostring(terrain_get_size),
					})
					local init_started = now()
					init_params.buildable_grid = capacity_raw
					closure_init_buildable_grid(map, init_params)
					stats.init_ms = now() - init_started
					source_mask_log("SOURCE_BUILDABLE_NATIVE_INIT_END", stats)
					source_buildable_trace("SOURCE_BUILDABLE_RAW_CAPACITY_SOURCE_VIEW",
						capacity_raw, "buildable", stats)

					local crop_started = now()
					for y = 0, source_hex_h - 1 do
						for x = 0, source_hex_w - 1 do
							source_raw:set(x, y, capacity_raw:get(x, y))
						end
					end
					stats.crop_ms = now() - crop_started
					source_mask_log("SOURCE_BUILDABLE_RAW_CROP_END", stats)
					source_buildable_trace("SOURCE_BUILDABLE_RAW_CAPACITY_CROPPED",
						source_raw, "buildable", stats)

					if diagnostics_enabled then
						local shadow_init_started = now()
						init_params.buildable_grid = direct_raw
						closure_init_buildable_grid(map, init_params)
						stats.shadow_init_ms = now() - shadow_init_started
						source_mask_log("SOURCE_BUILDABLE_DIRECT_SOURCE_SHADOW_INIT_END", stats)
						source_buildable_trace("SOURCE_BUILDABLE_RAW_DIRECT_SOURCE_SIZED",
							direct_raw, "buildable", stats)
						local comparison = source_buildable_compare(
							"capacity-source-view-crop-vs-direct-source-sized-raw",
							source_raw, direct_raw, source_hex_w, source_hex_h, unbuildable_z, {
								stage = "raw", primary = "full-capacity-source-view-crop",
								shadow = "direct-source-sized-native",
							})
						stats.raw_exact_differences = comparison.exact_differences
						stats.raw_classification_differences = comparison.classification_differences
						stats.raw_primary_buildable_only = comparison.a_buildable_only
						stats.raw_shadow_buildable_only = comparison.b_buildable_only
						stats.raw_classification_bbox = comparison.classification_bbox
					end

					local process_started = now()
					process_params.buildable_grid = source_raw
					process_params.buildable_z = source_processed
					source_mask_log("SOURCE_BUILDABLE_NATIVE_PROCESS_BEGIN", {
						input_grid = tostring(source_raw), output_grid = tostring(source_processed),
						source_hex = tostring(source_hex_w) .. "x" .. tostring(source_hex_h),
						minsize = process_params.minsize, maxsize = process_params.maxsize,
						mindelta = process_params.mindelta, maxdelta = process_params.maxdelta,
						minarea = process_params.minarea, unbuildable_z = unbuildable_z,
					})
					closure_process_buildable_grid(process_params)
					stats.process_ms = now() - process_started
					source_mask_log("SOURCE_BUILDABLE_NATIVE_PROCESS_END", stats)
					source_buildable_trace("SOURCE_BUILDABLE_PROCESSED_SOURCE",
						source_processed, "buildable", stats)
					if diagnostics_enabled then
						local shadow_process_started = now()
						process_params.buildable_grid = direct_raw
						process_params.buildable_z = direct_processed
						closure_process_buildable_grid(process_params)
						stats.shadow_process_ms = now() - shadow_process_started
						source_mask_log("SOURCE_BUILDABLE_DIRECT_SOURCE_SHADOW_PROCESS_END", stats)
						source_buildable_trace("SOURCE_BUILDABLE_PROCESSED_DIRECT_SOURCE_SHADOW",
							direct_processed, "buildable", stats)
						local comparison = source_buildable_compare(
							"capacity-source-view-crop-vs-direct-source-sized-processed",
							source_processed, direct_processed,
							source_hex_w, source_hex_h, unbuildable_z, {
								stage = "processed", primary = "full-capacity-source-view-crop",
								shadow = "direct-source-sized-native",
							})
						stats.processed_exact_differences = comparison.exact_differences
						stats.processed_classification_differences = comparison.classification_differences
						stats.processed_primary_buildable_only = comparison.a_buildable_only
						stats.processed_shadow_buildable_only = comparison.b_buildable_only
						stats.processed_classification_bbox = comparison.classification_bbox
					end

					local replaced_grid = buildable.z_grid
					buildable.z_grid = source_processed
					source_mask_log("SOURCE_BUILDABLE_GRID_TRANSFER", {
						old_grid = tostring(replaced_grid), new_grid = tostring(buildable.z_grid),
						source_hex = tostring(source_hex_w) .. "x" .. tostring(source_hex_h),
						ownership = "BuildableGrid.z_grid",
					})
					source_processed = nil -- ownership transferred to the live BuildableGrid
				end)
				if type(resume) == "function" then pcall(resume, "SBMSourceBuildableRawGridBridge") end
				if capacity_raw then pcall(function() capacity_raw:free() end) end
				if source_raw then pcall(function() source_raw:free() end) end
				if source_processed then pcall(function() source_processed:free() end) end
				if direct_raw then pcall(function() direct_raw:free() end) end
				if direct_processed then pcall(function() direct_processed:free() end) end
				stats.total_ms = now() - started
				stats.ok = bridge_ok
				stats.error = bridge_ok and "none" or tostring(bridge_err)
				map.SuperBigMapSourceBuildableGridBridge = stats
				if not bridge_ok then
					source_mask_log("SOURCE_BUILDABLE_BRIDGE_FAILED", stats, "error")
					return nil, "source-buildable-bridge-failed:" .. tostring(bridge_err)
				end
				source_mask_log("SOURCE_BUILDABLE_BRIDGE_END", stats)
				return true, nil
			end

			local function rebuild_source_invalid_mask(incoming_mask)
				if is_underground
					or map.SuperBigMapDeferredBackingPromotion == true
					or not cfg_bool("EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE", false)
					or not cfg_bool("QUADRANT_LIMIT_GENERATOR_TO_SOURCE", true) then
					return nil, "mode-not-eligible"
				end
				local desired_w = tonumber(map and map.SuperBigMapDesiredWidthTiles)
				local desired_h = tonumber(map and map.SuperBigMapDesiredHeightTiles)
				local generator_w = tonumber(map and map.SuperBigMapGeneratorWidthTiles)
				local generator_h = tonumber(map and map.SuperBigMapGeneratorHeightTiles)
				if not desired_w or not desired_h or not generator_w or not generator_h
					or desired_w <= generator_w or desired_h <= generator_h then
					return nil, "map-not-expanded"
				end
				local gen_zone = env.gen_zone
				local buildable = map and map.buildable
				local z_grid = buildable and buildable.z_grid
				if not gen_zone or not incoming_mask or not buildable or not z_grid
					or type(z_grid.get) ~= "function" or type(z_grid.set) ~= "function"
					or type(closure_new_grid) ~= "function"
					or type(closure_new_compute_grid) ~= "function"
					or type(closure_is_compute_grid) ~= "function"
					or type(closure_grid_fill) ~= "function"
					or type(closure_mask_buildable_grid) ~= "function"
					or type(closure_world_to_hex) ~= "function"
					or type(closure_grid_dest) ~= "function"
					or type(closure_grid_not) ~= "function"
					or type(complement_work_step) ~= "number" or complement_work_step <= 0 then
					return nil, "required-api-unavailable"
				end

				local ok_gen, grid_w, grid_h = pcall(gen_zone.size, gen_zone)
				grid_h = grid_h or grid_w
				local ok_mask, mask_w, mask_h = pcall(incoming_mask.size, incoming_mask)
				mask_h = mask_h or mask_w
				local ok_build, build_w, build_h = pcall(z_grid.size, z_grid)
				build_h = build_h or build_w
				if not ok_gen or not ok_mask or not ok_build
					or type(grid_w) ~= "number" or type(grid_h) ~= "number"
					or grid_w <= 0 or grid_h <= 0 or mask_w ~= grid_w or mask_h ~= grid_h then
					return nil, "grid-size-mismatch"
				end
				if type(map.hex_width) == "number" and type(map.hex_height) == "number"
					and (build_w ~= map.hex_width or build_h ~= map.hex_height) then
					return nil, "buildable-not-source-sized"
				end
				local source_x = tonumber(map.SuperBigMapSourceX) or 0
				local source_y = tonumber(map.SuperBigMapSourceY) or 0
				if source_x ~= 0 or source_y ~= 0 then
					return nil, "nonzero-source-origin-unsupported"
				end
				local source_world_w = tonumber(map.SuperBigMapGeneratorWidth)
					or tonumber(map.SuperBigMapSourceWidth)
				local source_world_h = tonumber(map.SuperBigMapGeneratorHeight)
					or tonumber(map.SuperBigMapSourceHeight)
				local expanded_world_w = tonumber(map.SuperBigMapExpandedWorldWidth)
				local expanded_world_h = tonumber(map.SuperBigMapExpandedWorldHeight)
				local expanded_hex_w = tonumber(map.SuperBigMapExpandedHexWidth)
				local expanded_hex_h = tonumber(map.SuperBigMapExpandedHexHeight)
				if not source_world_w or not source_world_h or not expanded_world_w or not expanded_world_h
					or not expanded_hex_w or not expanded_hex_h
					or source_world_w <= 0 or source_world_h <= 0
					or expanded_world_w <= source_world_w or expanded_world_h <= source_world_h
					or expanded_hex_w < build_w or expanded_hex_h < build_h then
					return nil, "bridge-dimensions-unavailable"
				end
				local virtual_w_numerator = grid_w * expanded_world_w
				local virtual_h_numerator = grid_h * expanded_world_h
				if virtual_w_numerator % source_world_w ~= 0
					or virtual_h_numerator % source_world_h ~= 0 then
					return nil, "nonintegral-work-grid-ratio"
				end
				local virtual_w = virtual_w_numerator / source_world_w
				local virtual_h = virtual_h_numerator / source_world_h
				if virtual_w < grid_w or virtual_h < grid_h then
					return nil, "invalid-virtual-work-grid"
				end
				local ok_compute, mask_format, mask_bits = pcall(closure_is_compute_grid, gen_zone)
				if not ok_compute or string.upper(tostring(mask_format)) ~= "U" or mask_bits ~= 16 then
					return nil, "source-mask-compute-format-unexpected:"
						.. tostring(mask_format) .. ":" .. tostring(mask_bits)
				end

				local unbuildable_z = 2 ^ 16 - 1
				if type(closure_build_unbuildable_z) == "function" then
					local ok_z, value = pcall(closure_build_unbuildable_z)
					if ok_z and type(value) == "number" then unbuildable_z = value end
				end
				local ok_create, repaired = pcall(closure_grid_dest, gen_zone)
				if not ok_create or not repaired then
					return nil, "GridDest-failed:" .. tostring(repaired)
				end
				local ok_not, not_err = pcall(closure_grid_not, gen_zone, repaired)
				if not ok_not then
					pcall(function() repaired:free() end)
					return nil, "GridNot-failed:" .. tostring(not_err)
				end

				local virtual_mask, virtual_z
				local ok_virtual_mask, virtual_mask_or_err = pcall(
					closure_new_compute_grid, virtual_w, virtual_h, mask_format, mask_bits)
				if ok_virtual_mask then virtual_mask = virtual_mask_or_err end
				local ok_virtual_z, virtual_z_or_err = pcall(
					closure_new_grid, expanded_hex_w, expanded_hex_h, 16, unbuildable_z)
				if ok_virtual_z then virtual_z = virtual_z_or_err end
				if not virtual_mask or not virtual_z then
					pcall(function() repaired:free() end)
					if virtual_mask then pcall(function() virtual_mask:free() end) end
					if virtual_z then pcall(function() virtual_z:free() end) end
					return nil, "virtual-grid-create-failed:mask=" .. tostring(virtual_mask_or_err)
						.. ";z=" .. tostring(virtual_z_or_err)
				end
				local ok_fill, fill_err = pcall(closure_grid_fill, virtual_mask, 1)
				if not ok_fill then
					pcall(function() repaired:free() end)
					pcall(function() virtual_mask:free() end)
					pcall(function() virtual_z:free() end)
					return nil, "virtual-mask-fill-failed:" .. tostring(fill_err)
				end

				local stats = {
					algorithm = "native MaskBuildableGrid on ratio-derived virtual source grid",
					grid = tostring(grid_w) .. "x" .. tostring(grid_h),
					virtual_grid = tostring(virtual_w) .. "x" .. tostring(virtual_h),
					virtual_mask_format = tostring(mask_format) .. tostring(mask_bits),
					buildable = tostring(build_w) .. "x" .. tostring(build_h),
					virtual_buildable = tostring(expanded_hex_w) .. "x" .. tostring(expanded_hex_h),
					source_world = tostring(source_world_w) .. "x" .. tostring(source_world_h),
					expanded_world = tostring(expanded_world_w) .. "x" .. tostring(expanded_world_h),
					work_step = complement_work_step, unbuildable_z = unbuildable_z,
					gen_cells = 0, outside_gen_cells = 0,
					direct_buildable_cells = 0, direct_unbuildable_cells = 0,
					direct_nil_buildable_cells = 0,
					repaired_zeros = 0, repaired_ones = 0,
					incoming_zeros = 0, incoming_ones = 0,
					changed_cells = 0, incoming_zero_to_one = 0, incoming_one_to_zero = 0,
					direct_native_differences = 0, direct_zero_native_one = 0,
					direct_one_native_zero = 0, difference_bbox = "none",
					checksum_a = 0, checksum_b = 0,
				}
				source_mask_log("SOURCE_MASK_NATIVE_BRIDGE_BEGIN", stats)
				local spread_diagnostics = SuperBigMap.EnrichmentSpreadDiagnostics
				if spread_diagnostics and type(spread_diagnostics.TraceGridForensics) == "function" then
					pcall(spread_diagnostics.TraceGridForensics, map,
						"SOURCE_MASK_BRIDGE_SOURCE_BUILDABLE", z_grid, "buildable", {
							bridge_grid = stats.grid, bridge_buildable = stats.buildable,
							source_world = stats.source_world, expanded_world = stats.expanded_world,
						})
				end
				local pause = Global("PauseInfiniteLoopDetection")
				local resume = Global("ResumeInfiniteLoopDetection")
				local ticks = Global("GetPreciseTicks")
				local started = 0
				if type(ticks) == "function" then
					local ok_ticks, value = pcall(ticks)
					if ok_ticks and type(value) == "number" then started = value end
				end
				if type(pause) == "function" then pcall(pause, "SBMSourceBuildableMaskNativeBridge") end
				local ok_bridge, bridge_err = pcall(function()
					-- The new grids are initialized invalid/unbuildable. Copy only the source
					-- rectangles; the padding safely represents terrain outside the source view.
					for y = 0, grid_h - 1 do
						for x = 0, grid_w - 1 do
							virtual_mask:set(x, y, repaired:get(x, y))
						end
					end
					for y = 0, build_h - 1 do
						for x = 0, build_w - 1 do
							virtual_z:set(x, y, z_grid:get(x, y))
						end
					end
					closure_mask_buildable_grid(map, virtual_z, virtual_mask, unbuildable_z)
					for y = 0, grid_h - 1 do
						for x = 0, grid_w - 1 do
							repaired:set(x, y, virtual_mask:get(x, y))
						end
					end
				end)
				pcall(function() virtual_mask:free() end)
				pcall(function() virtual_z:free() end)
				if not ok_bridge then
					if type(resume) == "function" then pcall(resume, "SBMSourceBuildableMaskNativeBridge") end
					pcall(function() repaired:free() end)
					return nil, "native-bridge-failed:" .. tostring(bridge_err)
				end

				local differences = {}
				local min_dx, min_dy, max_dx, max_dy
				local MOD = 2147483647
				local ok_scan, scan_err = pcall(function()
					local index = 0
					for y = 0, grid_h - 1 do
						local world_y = source_y + math.floor(y * source_world_h / grid_h)
						for x = 0, grid_w - 1 do
							index = index + 1
							local native_value = repaired:get(x, y)
							local incoming_value = incoming_mask:get(x, y)
							local gen_value = gen_zone:get(x, y)
							local direct_value = gen_value == 0 and 1 or 0
							local q, r, storage_x, build_z
							if direct_value == 0 then
								stats.gen_cells = stats.gen_cells + 1
								local world_x = source_x + math.floor(x * source_world_w / grid_w)
								q, r = closure_world_to_hex(world_x, world_y)
								storage_x = q + (r >= 0 and math.floor(r / 2) or math.ceil(r / 2))
								build_z = z_grid:get(storage_x, r)
								if build_z == nil then
									stats.direct_nil_buildable_cells = stats.direct_nil_buildable_cells + 1
									direct_value = 1
								elseif build_z == unbuildable_z then
									stats.direct_unbuildable_cells = stats.direct_unbuildable_cells + 1
									direct_value = 1
								else
									stats.direct_buildable_cells = stats.direct_buildable_cells + 1
								end
							else
								stats.outside_gen_cells = stats.outside_gen_cells + 1
							end

							if incoming_value == 0 then stats.incoming_zeros = stats.incoming_zeros + 1
							else stats.incoming_ones = stats.incoming_ones + 1 end
							if native_value == 0 then stats.repaired_zeros = stats.repaired_zeros + 1
							else stats.repaired_ones = stats.repaired_ones + 1 end
							if incoming_value ~= native_value then
								stats.changed_cells = stats.changed_cells + 1
								if incoming_value == 0 and native_value == 1 then
									stats.incoming_zero_to_one = stats.incoming_zero_to_one + 1
								elseif incoming_value == 1 and native_value == 0 then
									stats.incoming_one_to_zero = stats.incoming_one_to_zero + 1
								end
							end
							if direct_value ~= native_value then
								stats.direct_native_differences = stats.direct_native_differences + 1
								if direct_value == 0 then stats.direct_zero_native_one = stats.direct_zero_native_one + 1
								else stats.direct_one_native_zero = stats.direct_one_native_zero + 1 end
								min_dx = min_dx and math.min(min_dx, x) or x
								min_dy = min_dy and math.min(min_dy, y) or y
								max_dx = max_dx and math.max(max_dx, x) or x
								max_dy = max_dy and math.max(max_dy, y) or y
								if #differences < 128 then
									differences[#differences + 1] = {
										index = stats.direct_native_differences, x = x, y = y,
										direct = direct_value, native = native_value,
										world_x = source_x + math.floor(x * source_world_w / grid_w),
										world_y = world_y, q = tostring(q), r = tostring(r),
										storage_x = tostring(storage_x), build_z = tostring(build_z),
									}
								end
							end
							local normalized = native_value * 1000
							stats.checksum_a = (stats.checksum_a * 65599 + normalized + index * 97) % MOD
							stats.checksum_b = (stats.checksum_b
								+ (normalized % MOD) * ((index % 104729) * 2 + 1)) % MOD
						end
					end
				end)
				if type(resume) == "function" then pcall(resume, "SBMSourceBuildableMaskNativeBridge") end
				if not ok_scan then
					pcall(function() repaired:free() end)
					return nil, "bridge-audit-failed:" .. tostring(scan_err)
				end
				if min_dx then
					stats.difference_bbox = tostring(min_dx) .. ":" .. tostring(min_dy)
						.. "-" .. tostring(max_dx) .. ":" .. tostring(max_dy)
				end
				local finished = started
				if type(ticks) == "function" then
					local ok_ticks, value = pcall(ticks)
					if ok_ticks and type(value) == "number" then finished = value end
				end
				stats.ms = finished - started
				stats.logged_differences = #differences
				for _, difference in ipairs(differences) do
					source_mask_log("SOURCE_MASK_DIRECT_NATIVE_DIFFERENCE", difference)
				end
				map.SuperBigMapSourceBuildableMaskRepair = stats
				source_mask_log("SOURCE_MASK_NATIVE_BRIDGE_END", stats)
				source_mask_log("SOURCE_MASK_REPAIR", stats)
				return repaired, nil
			end

			-- Proc_ResolveBuildable calls this once to turn gen_zone into the actual placement
			-- play_zone. Capture its exact native area ratio before any resource/anomaly layer
			-- starts destructively eroding that zone.
			if type(saved_get_playable_area) == "function" then
				env.GetPlayableArea = function(...)
					local args = PackValues(...)
					local repaired_mask, repair_reason = rebuild_source_invalid_mask(args[3])
					if repaired_mask then
						args[3] = repaired_mask
						local spread_diagnostics = SuperBigMap.EnrichmentSpreadDiagnostics
						if spread_diagnostics and type(spread_diagnostics.TraceGridForensics) == "function" then
							pcall(spread_diagnostics.TraceGridForensics, map,
								"SOURCE_MASK_REPAIRED_PLAYABLE_INPUT", repaired_mask, "zero", {
									repair_reason = "native-bridge", pass_border = tostring(args[2]),
								})
						end
					elseif repair_reason ~= "mode-not-eligible" and repair_reason ~= "map-not-expanded" then
						source_mask_log("SOURCE_MASK_REPAIR_SKIPPED", {
							map = tostring(map and map.name), reason = tostring(repair_reason),
						}, "warn")
					end
					local results
					local ok_playable, playable_err = pcall(function()
						results = PackValues(saved_get_playable_area(Unpack(args, 1, args.n)))
					end)
					if repaired_mask then pcall(function() repaired_mask:free() end) end
					if not ok_playable then error(playable_err) end
					pcall(function()
						local play_area = results[1]
						local play_zone = results[2]
						if not base_play_zone_snapshot and play_zone
							and type(play_zone.clone) == "function" then
							base_play_zone_snapshot = play_zone:clone()
						end
						local gen_area = env.gen_area_unscaled
						if type(map) == "table" and type(play_area) == "number" and play_area > 0
							and type(gen_area) == "number" and gen_area > 0 then
							local coverage = play_area * 1.0 / gen_area
							if coverage > 1 then coverage = 1 end
							map.SuperBigMapRmgPlayableCoverage = coverage
							map.SuperBigMapRmgPlayableCoverageInfo = {
								coverage_source = "GetPlayableArea result / env.gen_area_unscaled",
								play_cells = play_area, gen_cells = gen_area,
								cov_permille = math.floor(coverage * 1000),
							}
							local debug_log = SuperBigMap.DebugLog
							if debug_log and type(debug_log.On) == "function"
								and debug_log.On("RmgPlacementExhaustive") == true then
								debug_log.Info("RmgPlacementExhaustive", "captured native play-zone coverage", {
									coverage = string.format("%.3f", coverage),
									play_cells = play_area, gen_cells = gen_area,
								})
							end
						end
					end)
					return Unpack(results, 1, results.n)
				end
			end

			-- Recreate the pristine per-layer candidate zone from the native play zone. This is
			-- used only when vanilla plus its unspaced retry exhausted the already-eroded live
			-- layer grid completely. It retains the native terrain mask and authored layer border;
			-- only inter-enrichment spacing is relaxed for the missing complement.
			local function build_pristine_candidate_zone(search_layer, resource_name)
				if not base_play_zone_snapshot or type(base_play_zone_snapshot.clone) ~= "function" then
					return nil, "pristine_play_zone_unavailable"
				end
				local grid_dest = Global("GridDest")
				local grid_mask = Global("GridMask")
				local grid_mul_div_add = Global("GridMulDivAdd")
				local get_terrain_texture = Global("GetTerrainTextureIndex")
				local terrain = Global("terrain")
				local const_tbl = Global("const")
				if type(grid_dest) ~= "function" or type(grid_mask) ~= "function"
					or type(terrain) ~= "table" or type(terrain.TypeTileSize) ~= "function"
					or type(const_tbl) ~= "table" or type(const_tbl.PrefabWorkRatio) ~= "number" then
					return nil, "pristine_zone_engine_api_unavailable"
				end
				local ok_tile, type_tile = pcall(terrain.TypeTileSize)
				local work_step = ok_tile and type(type_tile) == "number"
					and type_tile * const_tbl.PrefabWorkRatio or nil
				if type(work_step) ~= "number" or work_step <= 0 then
					return nil, "pristine_zone_work_step_unavailable"
				end

				local base, masked, candidate
				local ok_build, build_err = pcall(function()
					base = base_play_zone_snapshot:clone()
					local source = base
					-- Normal subsurface resources use the authored terrain-type mask. Subsurface
					-- anomalies deliberately use the full play zone in the stock generator.
					if search_layer == "subs" and resource_name ~= "Anomaly" then
						if type(get_terrain_texture) ~= "function" or type(grid_mul_div_add) ~= "function"
							or env.type_grid == nil then
							error("subsurface terrain-mask API unavailable")
						end
						local texture = get_terrain_texture(self.TerrainZoneMaskSubs)
						-- Stock GetMaskedTerrainTypeZone falls back to the unmasked play zone when
						-- the preset leaves TerrainZoneMaskSubs empty.
						if texture then
							masked = grid_dest(env.type_grid)
							grid_mask(env.type_grid, masked, texture)
							grid_mul_div_add(masked, base, 1, 0)
							source = masked
						end
					end

					local border
					if resource_name == "Anomaly" then
						local guim = type(Global("guim")) == "number" and Global("guim") or 1000
						local max_border = 256 * guim
						border = self.DepBorderAnomaly and self.DepBorderAnomaly ~= max_border
							and self.DepBorderAnomaly or self.DepBorderSubs
					elseif resource_name == "Effects" then
						border = self.DepBorderEffects
					elseif search_layer == "surf" then
						border = self.DepBorderSurf
					elseif search_layer == "subs" then
						border = self.DepBorderSubs
					else
						border = self.DepBorderTerr
					end
					if type(border) ~= "number" then error("layer border unavailable") end
					candidate = grid_dest(source)
					grid_mask(source, candidate, border / work_step + 1,
						type(Global("max_int")) == "number" and Global("max_int") or 2147483647, 1)
				end)
				if base then pcall(function() base:free() end) end
				if masked then pcall(function() masked:free() end) end
				if not ok_build then
					if candidate then pcall(function() candidate:free() end) end
					return nil, "pristine_zone_build_error:" .. tostring(build_err)
				end
				return candidate
			end

			-- VANILLA-FIRST COMPLETION. The engine's `grand` fallback retries a partial
			-- `find_all` search on the SAME clone already erased by the successful positions.
			-- On fragmented terrain that can report 8/9 even though the original valid zone has
			-- room for the missing marker. Run the native search first, preserve its complete
			-- valid result and random-state consumption, then replace only a native point that would
			-- align onto an already occupied gameplay hex and add requested-returned from
			-- a fresh clone of the ORIGINAL candidate grid. The complement uses an independent
			-- procedure-derived seed, so the native placement-search random stream is unchanged.
			if type(saved_grand) == "function" then
				rhelpers[5] = function(grid, params, ...)
					local requested = type(params) == "table" and params.count or nil
					local resource_label = type(params) == "table" and tostring(params.resource or "") or ""
					local search_layer = string.match(resource_label, "^(%a+)%s")
					if search_layer ~= "surf" and search_layer ~= "subs" and search_layer ~= "terr" then
						search_layer = nil
					end
					local resource_name = string.match(resource_label, "^%a+%s+(.+)$")
					local stack = State.rmg_placement_proc_stack
					local proc = type(stack) == "table" and tostring(stack[#stack]) or "PlaceAnomalies"
					local scalar_feature_context
					if proc == "PlaceAnomalies_FindFeatures_Deposits" and resource_label == "" then
						scalar_feature_context = feature_deposit_context
						feature_deposit_context = nil
						if type(scalar_feature_context) == "table" then
							search_layer = scalar_feature_context.layer
							resource_name = scalar_feature_context.resource
							resource_label = tostring(search_layer) .. " " .. tostring(resource_name)
						end
					end
					-- Only these selector results become entries in vanilla's `to_align` list.
					-- Surface resource deposits and cluster centers deliberately remain unaligned.
					local result_aligns_to_hex = search_layer == "subs" or search_layer == "terr"
						or resource_name == "Effects"
						or proc == "PlaceAnomalies_FindFeatures_Anomalies"
						or proc == "PlaceAnomalies_FindFeatures_EffectDeposits"
					local aligned_record_limit
					if resource_name == "Anomaly" and type(requested) == "number" then
						local function range_upper(range)
							local ok, value = pcall(function() return range and range.to end)
							return ok and type(value) == "number" and value or nil
						end
						local anomaly_kind = string.match(proc, "PlaceAnomalies_FindAnomalies_(%w+)$")
						local expected_key, max_count
						if anomaly_kind == "TechUnlock" then
							expected_key, max_count = "unlock", range_upper(self.AnomTechUnlockCount)
						elseif anomaly_kind == "Event" then
							expected_key = "sequence"
							local base, bonus = range_upper(self.AnomEventCount), range_upper(self.BonusCountEvent)
							if base and bonus then max_count = base + bonus end
						elseif anomaly_kind == "FreeTech" then
							expected_key = "complete"
							local base, bonus = range_upper(self.AnomFreeTechCount), range_upper(self.BonusCountFreeTech)
							if base and bonus then max_count = base + bonus end
						end
						local expected = expected_key and type(map) == "table"
							and type(map.SuperBigMapExpectedAnomalyCounts) == "table"
							and map.SuperBigMapExpectedAnomalyCounts[expected_key] or nil
						if type(expected) == "number" and type(max_count) == "number" then
							local already_placed = math.max(0, max_count - requested)
							aligned_record_limit = math.max(0, math.min(requested, expected - already_placed))
						end
					end
					local alignment_api_ready = type(complement_work_step) == "number"
						and complement_work_step > 0
						and type(hex_get_nearest_center) == "function"
						and type(alignment_hash) == "function"
					local collision_repair_enabled =
						cfg_bool("ENABLE_NATIVE_ALIGNED_HEX_COLLISION_REPAIR", false)
					local can_complete = cfg_bool("COMPLETE_NATIVE_ENRICHMENT_SHORTFALLS", true)
						and grid ~= nil and type(params) == "table"
						and params.mode == "find_all" and type(requested) == "number"
						and requested > 0 and search_layer ~= nil
						and (not result_aligns_to_hex or alignment_api_ready)
					local scalar_spacing = type(params) == "table" and (params.spacing or 0) or 0
					local can_repair_scalar_alignment =
						collision_repair_enabled
						and cfg_bool("COMPLETE_NATIVE_ENRICHMENT_SHORTFALLS", true)
						and result_aligns_to_hex
						and grid ~= nil and type(params) == "table" and requested == nil
						and scalar_spacing == 0 and alignment_api_ready

					-- Always snapshot before the native call. The shipped helper currently clones for
					-- count>1/find_all, but taking our own pre-call snapshot makes the completion path
					-- independent of that implementation detail and guarantees that it sees the exact
					-- original candidate grid on every engine version.
					local original_snapshot, scalar_snapshot
					local completion_reason = can_complete and "native_complete" or "not_eligible"
					if can_complete then
						local ok_snapshot, snapshot = pcall(function() return grid:clone() end)
						if ok_snapshot and snapshot then
							original_snapshot = snapshot
						else
							can_complete = false
							completion_reason = "pre_call_snapshot_failed"
						end
					end
					if can_repair_scalar_alignment then
						local ok_snapshot, snapshot = pcall(function() return grid:clone() end)
						if ok_snapshot and snapshot then
							scalar_snapshot = snapshot
						else
							can_repair_scalar_alignment = false
						end
					end

					-- Silence only the native helper's PREMATURE warning while its result is being
					-- completed. If completion still fails, the genuine warning is emitted below and
					-- the engine's outer requested-vs-placed warning remains active.
					local call_params = params
					if can_complete then
						call_params = {}
						for k, v in pairs(params) do call_params[k] = v end
						call_params.disable_warnings = true
					end

					local debug_log = SuperBigMap.DebugLog
					local trace_ok, trace = false, false
					if type(debug_log) == "table" and type(debug_log.On) == "function" then
						trace_ok, trace = pcall(debug_log.On, "RmgPlacementExhaustive")
					end
					local grid_count = Global("GridCount")
					local before = "n/a"
					if trace_ok and trace == true and type(grid_count) == "function" and grid then
						local ok_count, n = pcall(grid_count, grid, 0, 1)
						if ok_count then before = n end
					end

					local results = PackValues(saved_grand(grid, call_params, ...))
					-- A scalar engine point may be userdata or table-backed depending on the build.
					-- Probe the point API before treating a table as a list and applying `#`/ipairs.
					local native_first_is_point = xy_key(results[1]) ~= nil
					local positions = not native_first_is_point and type(results[1]) == "table"
						and results[1] or nil
					local native_returned = positions and #positions or 0
					local native_usable = native_returned
					local native_aligned_collisions = 0
					local native_aligned_replacements = 0
					local native_aligned_retained = 0
					local native_aligned_local_rejections = 0
					local native_aligned_global_fallbacks = 0
					local native_replacement_slots = {}
					local scalar_aligned_replacements = 0
					local scalar_repair_reason = can_repair_scalar_alignment
						and "native_scalar_unique" or "not_eligible"
					if can_repair_scalar_alignment and native_first_is_point then
						local native_point = results[1]
						local native_hex = aligned_hex_key(native_point)
						if native_hex and consumed_aligned_hexes[native_hex] then
							scalar_repair_reason = "collision_detected"
							local grid_random = closure_global("GridStableRandomPos", Global("GridStableRandomPos"))
							local proc_seed
							if type(self.ProcSeed) == "function" then
								local ok_seed, value = pcall(self.ProcSeed, self, proc)
								if ok_seed then proc_seed = value end
							end
							local native_x, native_y = point_xyz(native_point)
							local min_value = type(params.min) == "number" and params.min or 0
							local max_value = type(params.max) == "number" and params.max
								or (type(closure_global("max_int", Global("max_int"))) == "number"
									and closure_global("max_int", Global("max_int")) or 2147483647)
							local ok_native_original, native_original_value = pcall(function()
								return scalar_snapshot and scalar_snapshot:get(native_point)
							end)
							local attempt = 0
							while scalar_snapshot and type(grid_random) == "function" and proc_seed ~= nil
								and ok_native_original and type(native_original_value) == "number"
								and native_x ~= nil and native_y ~= nil and attempt < 4096 do
								attempt = attempt + 1
								local ok_retry_seed, retry_seed = pcall(alignment_hash,
									proc_seed, "SBMScalarAlignedReplacement", proc,
									tostring(native_x), tostring(native_y), attempt)
								if not ok_retry_seed or retry_seed == nil then
									scalar_repair_reason = "replacement_seed_unavailable"
									break
								end
								local ok_draw, extra = pcall(grid_random, scalar_snapshot, retry_seed,
									1, 0, min_value, max_value, params.weighted or false, params.mask)
								local candidate = ok_draw and type(extra) == "table" and extra[1] or nil
								if not candidate then
									scalar_repair_reason = ok_draw and "replacement_grid_exhausted"
										or ("replacement_draw_error:" .. tostring(extra))
									break
								end
								local candidate_x, candidate_y = point_xyz(candidate)
								local candidate_hex = aligned_hex_key(candidate)
								local candidate_key = candidate_x ~= nil and candidate_y ~= nil
									and (tostring(candidate_x) .. ":" .. tostring(candidate_y)) or nil
								local ok_live, live_value = pcall(function() return grid:get(candidate) end)
								local conflict = not candidate_hex or consumed_aligned_hexes[candidate_hex]
									or (candidate_key and consumed_search_positions[candidate_key])
									or not ok_live or type(live_value) ~= "number" or live_value <= 0
								if not conflict then
									-- Scalar GridStableRandomPos mutates the live selected cell even at
									-- zero spacing. Transfer that one-cell mutation transactionally so the
									-- discarded native point is restored and only its replacement is consumed.
									local ok_native_live, native_live_value = pcall(function()
										return grid:get(native_point)
									end)
									local transfer_ok = ok_native_live and type(native_live_value) == "number"
									if transfer_ok then
										transfer_ok = pcall(function()
											grid:set(native_x, native_y, native_original_value)
											grid:set(candidate_x, candidate_y, min_value)
										end)
									end
									local ok_native_verify, native_verify = pcall(function()
										return grid:get(native_point)
									end)
									local ok_candidate_verify, candidate_verify = pcall(function()
										return grid:get(candidate)
									end)
									transfer_ok = transfer_ok and ok_native_verify and ok_candidate_verify
										and native_verify == native_original_value
										and candidate_verify == min_value
									if transfer_ok then
										results[1] = candidate
										scalar_aligned_replacements = 1
										scalar_repair_reason = "collision_replaced"
										break
									end
									-- A partial setter failure must leave the native call exactly as it was.
									if ok_native_live and type(native_live_value) == "number" then
										pcall(function() grid:set(native_x, native_y, native_live_value) end)
									end
									if ok_live and type(live_value) == "number" then
										pcall(function() grid:set(candidate_x, candidate_y, live_value) end)
									end
									scalar_repair_reason = "live_grid_transfer_failed"
									break
								end
								if candidate_x == nil or candidate_y == nil
									or not pcall(function() scalar_snapshot:set(candidate_x, candidate_y, 0) end) then
									scalar_repair_reason = "replacement_candidate_retire_failed"
									break
								end
							end
							if attempt >= 4096 and scalar_aligned_replacements == 0 then
								scalar_repair_reason = "replacement_attempt_budget_exhausted"
							elseif not ok_native_original or type(native_original_value) ~= "number" then
								scalar_repair_reason = "native_pre_call_value_unavailable"
							end
							if scalar_aligned_replacements == 0 and scalar_repair_reason == "collision_detected" then
								scalar_repair_reason = "replacement_api_unavailable"
							end
						end
					end
					if scalar_snapshot then
						pcall(function() scalar_snapshot:free() end)
						scalar_snapshot = nil
					end
					-- Validate only entries that stock will append to `to_align`. Anomaly searches
					-- return a rolled-count prefix followed by an erosion-only tail; replacing in
					-- the exact native slot preserves that boundary, list order, downstream RNG
					-- assignment, and the returned count. A failed repair keeps the original point
					-- so the genuine engine warning remains visible. requested==1 is left native
					-- because stock mutates its live spacing footprint instead of a private clone.
					local aligned_prefix_count = 0
					if resource_name == "Anomaly" then
						if type(aligned_record_limit) == "number" then
							aligned_prefix_count = math.max(0,
								math.min(#(positions or {}), aligned_record_limit))
						end
					elseif result_aligns_to_hex then
						aligned_prefix_count = #(positions or {})
					end
					local alignment_repair_snapshot
					if collision_repair_enabled and can_complete and result_aligns_to_hex
						and requested > 1 and positions
						and aligned_prefix_count > 0 and original_snapshot then
						local ok_repair_clone, snapshot = pcall(function()
							return original_snapshot:clone()
						end)
						if ok_repair_clone then alignment_repair_snapshot = snapshot end
					end
					local function repair_native_aligned_slots()
						local repair_work = alignment_repair_snapshot
						alignment_repair_snapshot = nil
						if not repair_work then return end
						local repair_ready = true
						if repair_ready then
							-- The replacement draw must not return any original native entry, including
							-- an anomaly's erosion-only tail.
							for i = 1, #positions do
								local px, py = point_xyz(positions[i])
								if px == nil or py == nil
									or not pcall(function() repair_work:set(px, py, 0) end) then
									repair_ready = false
									break
								end
							end
						end
						local grid_random = closure_global("GridStableRandomPos",
							Global("GridStableRandomPos"))
						local grid_circle_set = closure_global("GridCircleSet", Global("GridCircleSet"))
						-- Preclassify the full final aligned prefix before drawing replacements.
						-- This reserves every valid later native/complement hex so an earlier repair
						-- cannot steal it and manufacture a second collision downstream.
						local collision_slots, reserved_hexes, classified_hexes = {}, {}, {}
						for hash in pairs(consumed_aligned_hexes) do classified_hexes[hash] = true end
						local final_aligned_count = resource_name == "Anomaly"
							and (type(aligned_record_limit) == "number"
								and math.min(#positions, aligned_record_limit) or 0)
							or #positions
						for i = 1, final_aligned_count do
							local hash = aligned_hex_key(positions[i])
							if hash and classified_hexes[hash] then
								collision_slots[i] = true
							elseif hash then
								classified_hexes[hash] = true
								reserved_hexes[hash] = true
							end
						end
						local native_spacing = type(params.spacing) == "number"
							and math.max(0, params.spacing) or 0
						-- Reconstruct the spacing exclusions that vanilla applied inside grand's
						-- temporary find_all clone. Collision slots are intentionally omitted because
						-- they are the later candidates being moved; every retained candidate keeps its
						-- original exclusion radius.
						if repair_ready and native_spacing > 0 then
							if type(grid_circle_set) ~= "function" then
								repair_ready = false
							else
								for i = 1, final_aligned_count do
									if not collision_slots[i] then
										local ok_spacing = pcall(grid_circle_set, repair_work, 0,
											positions[i], native_spacing)
										if not ok_spacing then
											repair_ready = false
											break
										end
									end
								end
							end
						end
						-- Keep a pristine full-zone fallback before the locality-biased draw consumes
						-- candidates. The first phase redraws into the original sector or one of its
						-- eight neighbours; if that 3x3 region has no valid unique snapped hex, the
						-- second phase may use any still-valid vanilla candidate so counts are preserved.
						local global_repair_work
						if repair_ready then
							local ok_global, clone = pcall(function() return repair_work:clone() end)
							if ok_global then
								global_repair_work = clone
							else
								repair_ready = false
							end
						end
						local min_value = type(params.min) == "number" and params.min or 0
						local max_value = type(params.max) == "number" and params.max
							or (type(closure_global("max_int", Global("max_int"))) == "number"
								and closure_global("max_int", Global("max_int")) or 2147483647)
						local grid_width, grid_height
						local ok_grid_size, size_x, size_y = pcall(function()
							return repair_work:size()
						end)
						if ok_grid_size and type(size_x) == "number" and size_x > 0 then
							grid_width = size_x
							grid_height = type(size_y) == "number" and size_y > 0 and size_y or size_x
						end
						local function sector_index(value, extent)
							if type(value) ~= "number" or type(extent) ~= "number" or extent <= 0 then
								return nil
							end
							return math.max(0, math.min(9, math.floor(value * 10 / extent)))
						end
						for i = 1, aligned_prefix_count do
							local native_pos = positions[i]
							local native_hex = aligned_hex_key(native_pos)
							local collision = collision_slots[i] == true
							if collision then
								native_aligned_collisions = native_aligned_collisions + 1
								local replacement, replacement_scope
								if repair_ready and type(grid_random) == "function" then
									local nx, ny = point_xyz(native_pos)
									local native_sector_x = sector_index(nx, grid_width)
									local native_sector_y = sector_index(ny, grid_height)
									local function draw_replacement(draw_grid, scope, attempts, require_neighbour)
										if not draw_grid then return nil end
										for attempt = 1, attempts do
										local seed
										if type(self.ProcSeed) == "function" then
											local ok_seed, proc_seed = pcall(self.ProcSeed, self,
												proc .. ":SBMAlignedSlot:" .. tostring(i))
											if ok_seed then
												local ok_hash, hashed = pcall(alignment_hash, proc_seed,
													"SBMNativeAlignedReplacement", scope, tostring(nx),
													tostring(ny), attempt)
												if ok_hash then seed = hashed end
											end
										end
										if type(seed) ~= "number" then return nil end
										local ok_draw, extra = pcall(grid_random, draw_grid, seed,
											1, 0, min_value, max_value, params.weighted or false, params.mask)
										local candidate = ok_draw and type(extra) == "table" and extra[1] or nil
										if not candidate then return nil end
										local cx, cy = point_xyz(candidate)
										local candidate_key = cx ~= nil and cy ~= nil
											and (tostring(cx) .. ":" .. tostring(cy)) or nil
										local candidate_hex = aligned_hex_key(candidate)
										local candidate_sector_x = sector_index(cx, grid_width)
										local candidate_sector_y = sector_index(cy, grid_height)
										local within_neighbourhood = native_sector_x ~= nil
											and native_sector_y ~= nil and candidate_sector_x ~= nil
											and candidate_sector_y ~= nil
											and math.abs(candidate_sector_x - native_sector_x) <= 1
											and math.abs(candidate_sector_y - native_sector_y) <= 1
										local ok_live, live_value = pcall(function()
											return grid:get(candidate)
										end)
										local candidate_conflict = not candidate_hex
											or consumed_aligned_hexes[candidate_hex]
											or reserved_hexes[candidate_hex]
											or (candidate_key and consumed_search_positions[candidate_key])
											or not ok_live or type(live_value) ~= "number" or live_value <= 0
										if not candidate_conflict and (not require_neighbour or within_neighbourhood) then
											return candidate
										elseif not candidate_conflict and require_neighbour then
											native_aligned_local_rejections =
												native_aligned_local_rejections + 1
										end
										if cx == nil or cy == nil
											or not pcall(function() draw_grid:set(cx, cy, 0) end) then
											return nil
										end
										end
										return nil
									end
									if native_sector_x ~= nil and native_sector_y ~= nil then
										replacement = draw_replacement(repair_work,
											"same_or_neighbor_sector", 1024, true)
										if replacement then replacement_scope = "same_or_neighbor_sector" end
									end
									if not replacement then
										native_aligned_global_fallbacks = native_aligned_global_fallbacks + 1
										replacement = draw_replacement(global_repair_work,
											"full_valid_zone", 4096, false)
										if replacement then replacement_scope = "full_valid_zone" end
									end
								end
								if replacement then
									positions[i] = replacement
									native_replacement_slots[i] = true
									native_hex = aligned_hex_key(replacement)
									if native_hex then reserved_hexes[native_hex] = true end
									native_aligned_replacements = native_aligned_replacements + 1
									if native_spacing > 0 then
										local local_masked = pcall(grid_circle_set, repair_work, 0,
											replacement, native_spacing)
										local global_masked = pcall(grid_circle_set, global_repair_work, 0,
											replacement, native_spacing)
										if not local_masked or not global_masked then repair_ready = false end
									end
									AlignmentTrace("native aligned collision replaced before final snap", {
										proc = proc, resource = resource_label, index = i,
										original_hash = tostring(aligned_hex_key(native_pos)),
										replacement_hash = tostring(native_hex),
										scope = tostring(replacement_scope), spacing = native_spacing,
									})
								else
									native_aligned_retained = native_aligned_retained + 1
								end
							end
						end
						if global_repair_work then pcall(function() global_repair_work:free() end) end
						if repair_work then pcall(function() repair_work:free() end) end
						results[1] = positions
					end
					local complemented = 0
					local live_zone_seeded = 0
					local aligned_hex_rejections = 0

					if can_complete and native_usable < requested then
						completion_reason = "completion_started"
						positions = positions or {}
						local grid_random = closure_global("GridStableRandomPos",
							Global("GridStableRandomPos"))
						local work = original_snapshot
						original_snapshot = nil
						local seen, seen_points = {}, {}
						local seen_aligned_hexes = {}
						local function remember(pos, erase_grid, seed_live_zone,
							enforce_unique_hex, track_aligned_hex, seed_value_source)
							if not pos then return false end
							if track_aligned_hex == nil then track_aligned_hex = enforce_unique_hex end
							local ok_xy, x, y = pcall(function() return pos:xy() end)
							if not ok_xy or x == nil or y == nil then return false end
							local key = tostring(x) .. ":" .. tostring(y)
							if seen[key] then return false end
							local hex_key = aligned_hex_key(pos)
							if enforce_unique_hex and not hex_key then return false end
							if enforce_unique_hex
								and (consumed_aligned_hexes[hex_key] or seen_aligned_hexes[hex_key]) then
								-- The engine aligns all deposit/anomaly work-grid points afterward with
								-- HexGetNearestCenter(pos * work_step). Distinct, nonadjacent work cells
								-- can therefore become the same gameplay hex; remove this rejected cell
								-- from the private candidate grid and draw another independent candidate.
								if not erase_grid then return false end
								local retired = pcall(function() erase_grid:set(x, y, 0) end)
								if not retired then return false end
								local ok_retired_value, retired_value = pcall(function()
									return erase_grid:get(x, y)
								end)
								if not ok_retired_value or type(retired_value) ~= "number"
									or retired_value > 0 then return false end
								for dx = -1, 1 do
									for dy = -1, 1 do
										if dx ~= 0 or dy ~= 0 then
											pcall(function() erase_grid:set(x + dx, y + dy, 0) end)
										end
									end
								end
								aligned_hex_rejections = aligned_hex_rejections + 1
								return false
							end
							local seed_value
							if seed_live_zone then
								-- SearchDepositLayer validates every returned point against its live
								-- resource zone before NewDep/NewAnomaly applies repulsion. A point
								-- recovered from the pristine native layer mask is outside that already-
								-- eroded zone by definition, so preserve its positive candidate value and
								-- restore only this selected cell to the live zone before returning it.
								local source = seed_value_source or erase_grid
								local ok_value, value = pcall(function() return source:get(pos) end)
								if not ok_value or type(value) ~= "number" or value <= 0 then return false end
								seed_value = value
							end
							if erase_grid then
								local ok_set = pcall(function() erase_grid:set(x, y, 0) end)
								if not ok_set then return false end
								for dx = -1, 1 do
									for dy = -1, 1 do
										if dx ~= 0 or dy ~= 0 then
											pcall(function() erase_grid:set(x + dx, y + dy, 0) end)
										end
									end
								end
							end
							if seed_live_zone then
								local ok_previous, previous = pcall(function() return grid:get(pos) end)
								local ok_seed = pcall(function() grid:set(x, y, seed_value) end)
								local ok_verify, live_value = pcall(function() return grid:get(pos) end)
								if not ok_seed or not ok_verify or type(live_value) ~= "number" or live_value <= 0 then
									if ok_previous and type(previous) == "number" then
										pcall(function() grid:set(x, y, previous) end)
									end
									return false
								end
								live_zone_seeded = live_zone_seeded + 1
							end
							seen[key] = true
							if hex_key and track_aligned_hex then seen_aligned_hexes[hex_key] = true end
							seen_points[#seen_points + 1] = { x = x, y = y }
							return true
						end
						local native_erased = true
						for i = 1, #positions do
							local occupies_hex = result_aligns_to_hex
								and (resource_name ~= "Anomaly"
									or (type(aligned_record_limit) == "number"
										and i <= aligned_record_limit))
							if remember(positions[i], work, false, false, occupies_hex) ~= true then
								native_erased = false
								break
							end
						end
						if not work then
							completion_reason = "pre_call_snapshot_missing"
						elseif not native_erased then
							completion_reason = "native_position_erase_failed"
						elseif type(grid_random) ~= "function" then
							completion_reason = "GridStableRandomPos_unavailable"
						end

						local min_value = type(params.min) == "number" and params.min or 0
						local max_value = type(params.max) == "number" and params.max
							or (type(Global("max_int")) == "number" and Global("max_int") or 2147483647)
						local function add_from_zone(candidate, scope, seed_value_source)
							local reason = "residual_shortfall"
							-- Draw one point at a time, retire its local work-grid footprint, and
							-- validate its exact aligned gameplay hex before accepting it. A batched
							-- zero-spacing call can return cells that later align to the same hex.
							local attempt = 0
							while #positions < requested and attempt < 4096 do
								attempt = attempt + 1
								local remaining = requested - #positions
								if remaining <= 0 then return "completed:" .. scope end
								local seed_tag = table.concat({
									"SBMEnrichmentComplement", proc, tostring(params.resource),
									tostring(requested), scope, tostring(attempt),
								}, ":")
								local seed
								if type(self.ProcSeed) == "function" then
									local ok_seed, value = pcall(self.ProcSeed, self, seed_tag)
									if ok_seed and type(value) == "number" then seed = value end
								end
								if type(seed) ~= "number" then
									local xxhash = Global("xxhash")
									if type(xxhash) == "function" then
										local ok_hash, value = pcall(xxhash, self.Seed or 0, seed_tag)
										if ok_hash and type(value) == "number" then seed = value end
									end
								end
								if type(seed) ~= "number" then
									return "independent_seed_unavailable:" .. scope
								end
								local ok_extra, extra = pcall(grid_random, candidate, seed, 1, 0,
									min_value, max_value, params.weighted or false, params.mask)
								if not ok_extra then
									return "GridStableRandomPos_error:" .. scope .. ":" .. tostring(extra)
								elseif type(extra) ~= "table" then
									return "GridStableRandomPos_non_table:" .. scope .. ":" .. tostring(type(extra))
								elseif #extra == 0 then
									return "no_unspaced_candidate:" .. scope
								end
								local added_this_attempt = 0
								local aligned_rejections_before = aligned_hex_rejections
								for i = 1, #extra do
									local pos = extra[i]
									local next_index = #positions + 1
									local occupies_hex = result_aligns_to_hex
										and (resource_name ~= "Anomaly"
											or (type(aligned_record_limit) == "number"
												and next_index <= aligned_record_limit))
									if remember(pos, candidate, scope == "pristine_layer",
										occupies_hex, occupies_hex, seed_value_source) then
										positions[#positions + 1] = pos
										complemented = complemented + 1
										added_this_attempt = added_this_attempt + 1
										if #positions >= requested then break end
									end
								end
								if added_this_attempt == 0 then
									if aligned_hex_rejections > aligned_rejections_before then
										-- The rejected hex footprint was retired from `candidate`; keep
										-- drawing instead of turning a correctable collision into a shortfall.
										reason = "residual_shortfall_after_aligned_hex_rejection:" .. scope
									else
										return "all_complement_candidates_duplicate:" .. scope
									end
								else
									reason = "residual_shortfall:" .. scope
								end
							end
							if #positions < requested and attempt >= 4096 then
								return "candidate_attempt_budget_exhausted:" .. scope
							end
							return #positions >= requested and ("completed:" .. scope) or reason
						end

						if work and native_erased and type(grid_random) == "function" then
							completion_reason = add_from_zone(work, "original")
						end

						-- A zero live grid means earlier vanilla placements consumed every location under
						-- the authored inter-enrichment repulsion. Preserve those placements, then seat only
						-- the missing complement on the pristine native layer mask with spacing removed.
						if #positions < requested and native_erased and type(grid_random) == "function" then
							local pristine, pristine_err = build_pristine_candidate_zone(search_layer, resource_name)
							if pristine then
								local pristine_ready = true
								local function erase_consumed_xy(xy)
									local exact_ok = pcall(function() pristine:set(xy.x, xy.y, 0) end)
									-- Retire the immediate work-grid neighborhood as a cheap first pass. The
									-- exact HexGetNearestCenter identity check in `remember` remains the
									-- authoritative guard against aligned-hex collisions.
									for dx = -1, 1 do
										for dy = -1, 1 do
											if dx ~= 0 or dy ~= 0 then
												pcall(function() pristine:set(xy.x + dx, xy.y + dy, 0) end)
											end
										end
									end
									return exact_ok
								end
								for _, xy in pairs(consumed_search_positions) do
									if not erase_consumed_xy(xy) then
										pristine_ready = false
										break
									end
								end
								if pristine_ready then
									for _, xy in ipairs(seen_points) do
										if not erase_consumed_xy(xy) then
											pristine_ready = false
											break
										end
									end
								end
								if pristine_ready then
									-- GridStableRandomPos may mutate its draw grid before returning the
									-- selected cell. Preserve the positive pre-draw value used to seed only
									-- the accepted live-zone cell for SearchDepositLayer validation.
									local ok_seed_source, seed_source = pcall(function()
										return pristine:clone()
									end)
									if ok_seed_source and seed_source then
										completion_reason = add_from_zone(pristine,
											"pristine_layer", seed_source)
										pcall(function() seed_source:free() end)
									else
										completion_reason = "pristine_seed_snapshot_failed"
									end
								else
									completion_reason = "pristine_used_position_erase_failed"
								end
								pcall(function() pristine:free() end)
							else
								completion_reason = pristine_err or "pristine_zone_unavailable"
							end
						end
						if #positions >= requested then
							if not string.find(completion_reason, "^completed:") then
								completion_reason = "completed"
							end
						elseif completion_reason == "completion_started" then
							completion_reason = "residual_shortfall"
						end
						if work then pcall(function() work:free() end) end
						results[1] = positions
						if (results.n or 0) < 1 then results.n = 1 end

						-- Do not hide a real residual failure. The outer generator will also emit its
						-- normal final "Placed X out of Y" warning after it consumes this result.
						if #positions < requested and type(saved_rm_print) == "function" then
							local missing = requested - #positions
							saved_rm_print("Could not find place for", missing, "out of", requested, params.resource)
						end
					end
					-- Authoritative target completion has first claim on scarce candidates. Only
					-- after the true requested count is filled do same-hex native slots consume an
					-- independent replacement candidate; unresolved slots retain the native point.
					local repair_ok, repair_err = pcall(repair_native_aligned_slots)
					if not repair_ok then
						AlignmentTrace("native aligned-slot repair failed closed", {
							proc = proc, error = tostring(repair_err),
						})
					end
					if alignment_repair_snapshot then
						pcall(function() alignment_repair_snapshot:free() end)
						alignment_repair_snapshot = nil
					end
					if original_snapshot then pcall(function() original_snapshot:free() end) end
					local final_positions = results[1]
					local single_occupies_hex = result_aligns_to_hex
					local origin_resource = resource_label ~= "" and resource_label or "?"
					local single_point_returned = record_consumed_position(final_positions,
						single_occupies_hex, {
							proc = proc, resource = origin_resource, index = 1,
							shape = "single_point", source = scalar_aligned_replacements > 0
								and "replacement" or "native", aligns = single_occupies_hex,
							role = single_occupies_hex and "aligned" or "nonaligning_or_unclassified",
							layer = tostring(search_layer), grid = tostring(grid),
						})
					local result_shape
					if single_point_returned then
						result_shape = "single_point"
						-- Single-point grand result.
					elseif type(final_positions) == "table" then
						result_shape = "list"
						for i = 1, #final_positions do
							local occupies_hex = result_aligns_to_hex
								and (resource_name ~= "Anomaly"
									or (type(aligned_record_limit) == "number"
										and i <= aligned_record_limit))
							record_consumed_position(final_positions[i], occupies_hex, {
								proc = proc, resource = origin_resource, index = i, shape = "list",
								source = native_replacement_slots[i] and "replacement"
									or (i <= native_usable and "native" or "complement"),
								aligns = occupies_hex,
								role = occupies_hex and "aligned"
									or (resource_name == "Anomaly" and "erosion_tail"
										or "nonaligning_or_unclassified"),
								layer = tostring(search_layer), grid = tostring(grid),
							})
						end
					elseif final_positions == nil then
						result_shape = "nil"
					else
						result_shape = type(final_positions)
					end

					if trace_ok and trace == true and type(debug_log.Info) == "function" then
						pcall(debug_log.Info, "RmgPlacementExhaustive", "vanilla-first placement search", {
							proc = proc,
							resource = tostring(type(params) == "table" and params.resource or "?"),
							requested = tostring(requested), spacing = tostring(type(params) == "table" and params.spacing),
							mode = tostring(type(params) == "table" and params.mode), positive_cells_before = before,
							native_returned = native_returned, native_usable = native_usable,
							native_aligned_collisions = native_aligned_collisions,
							native_aligned_replacements = native_aligned_replacements,
							native_aligned_retained = native_aligned_retained,
							native_aligned_local_rejections = native_aligned_local_rejections,
							native_aligned_global_fallbacks = native_aligned_global_fallbacks,
							scalar_aligned_replacements = scalar_aligned_replacements,
							scalar_repair_reason = scalar_repair_reason,
							complemented = complemented,
							live_zone_seeded = live_zone_seeded,
							aligned_hex_rejections = aligned_hex_rejections,
							aligned_record_limit = tostring(aligned_record_limit),
							result_shape = result_shape,
							single_point_returned = single_point_returned,
							final_returned = single_point_returned and 1
								or (type(results[1]) == "table" and #results[1] or native_returned),
							completion_reason = completion_reason,
							environment = tostring(environment),
						})
					end
					return Unpack(results, 1, results.n)
				end
			end

			if type(saved_rm_print) == "function" then
					env.rm_print = function(...)
						local call_args = PackValues(...)
						-- Deliver the native message first and unchanged. Everything below is a protected,
						-- read-only audit, so diagnostics can never hide or delay an engine warning.
						local original_results = PackValues(saved_rm_print(...))
						pcall(function()
							if call_args.n == 1 and call_args[1] == "Two markers aligned on the same hex!" then
								alignment_trace.warning_count = alignment_trace.warning_count + 1
							end
							local debug_log = SuperBigMap.DebugLog
						if debug_log and type(debug_log.On) == "function"
							and debug_log.On("RmgPlacementExhaustive") == true then
							local text_parts, args = {}, {}
							for i = 1, call_args.n do
								local value = call_args[i]
								text_parts[#text_parts + 1] = tostring(value)
								args[#args + 1] = tostring(i) .. ":" .. type(value) .. "=" .. tostring(value)
							end
							local stack = State.rmg_placement_proc_stack
							debug_log.Info("RmgPlacementExhaustive", "engine rm_print", {
								argc = call_args.n, args = table.concat(args, " | "),
								raw = table.concat(text_parts, " "),
								proc = type(stack) == "table" and tostring(stack[#stack]) or "?",
							})
						end
						if type(map) == "table"
							and call_args[1] == "Failed to find a place for all"
							and call_args[4] == "deposits. Placed"
							and call_args[6] == "out of" then
							local resource, placed, target = call_args[3], call_args[5], call_args[7]
							local capture = map.SuperBigMapResourceTargetCapture
							-- GenerateResourceInfo/ResInfo supplies the complete surf+subs+terr total.
							-- A warning contains only ONE layer's target and must never overwrite it.
							if type(resource) == "string" and type(target) == "number"
								and (not capture or capture == "rm_print failure args") then
								local layer_ids = { Surface = "surf", ["Sub-surface"] = "subs", Terrain = "terr" }
								local layer = layer_ids[call_args[2]]
								local by_layer = map.SuperBigMapExpectedResourceCountsByLayer
								by_layer[resource] = by_layer[resource] or {}
								if layer then by_layer[resource][layer] = target end
								if type(placed) == "number" then
									local residuals = map.SuperBigMapResourceResidualShortfalls
									local key = tostring(layer or call_args[2] or "?") .. ":" .. resource
									residuals[key] = {
										resource = resource,
										missing = math.max(0, target - placed),
									}
								end
								local layer_floor = 0
								for _, count in pairs(by_layer[resource]) do
									if type(count) == "number" then layer_floor = layer_floor + count end
								end
								map.SuperBigMapExpectedResourceCounts[resource] = math.max(
									map.SuperBigMapExpectedResourceCounts[resource] or 0, layer_floor, target)
								map.SuperBigMapResourceTargetCapture = "rm_print failure args"
							end
						end
					end)
					return Unpack(original_results, 1, original_results.n)
				end
			end

			local replace_breakthrough_selector = not is_underground
				and cfg_bool("ENABLE_NATIVE_ALIGNED_HEX_COLLISION_REPAIR", false)

			-- Breakthrough anomalies are the sole enrichment positions selected through
			-- GridMinMax instead of grand. The stock procedure calls it for every maximum
			-- quota slot even when the rolled quota is smaller, so only a fully rolled quota
			-- makes every returned maximum authoritative. In that safe case, replace a
			-- same-hex maximum with the next maximum from a private clone. The stock call and
			-- random stream remain untouched, and the requested anomaly count is unchanged.
			if type(saved_grid_min_max) == "function" and not replace_breakthrough_selector then
				grid_min_max_wrapper = function(...)
					local call_args = PackValues(...)
					local grid_results = PackValues(saved_grid_min_max(...))
					local stack = State.rmg_placement_proc_stack
					local proc = type(stack) == "table" and tostring(stack[#stack]) or ""
					local exact_breakthrough_call =
						proc == "PlaceAnomalies_FindAnomalies_Breakthrough"
						and call_args.n == 3 and call_args[2] == 1 and call_args[3] == true
					if exact_breakthrough_call then
						alignment_trace.breakthrough_calls = alignment_trace.breakthrough_calls + 1
						local candidate = grid_results[4]
						local candidate_hex = aligned_hex_key(candidate)
						local collision = candidate_hex and consumed_aligned_hexes[candidate_hex] or false
						local bonus_to
						pcall(function() bonus_to = self.BonusCountBreakthrough.to end)
						local full_quota = cfg_bool("ENABLE_NATIVE_ALIGNED_HEX_COLLISION_REPAIR", false)
							and cfg_bool("COMPLETE_NATIVE_ENRICHMENT_SHORTFALLS", true)
							and not is_underground
							and roll_index == #roll_specs
							and type(self.AnomBreakthroughCount) == "number"
							and type(rolls.breakthrough_bonus) == "number"
							and type(bonus_to) == "number"
							and self.AnomBreakthroughCount + rolls.breakthrough_bonus
								== self.AnomBreakthroughCount + bonus_to
						local repair_reason = collision and "collision_detected" or "native_unique"

						if collision then
							alignment_trace.breakthrough_collisions =
								alignment_trace.breakthrough_collisions + 1
						end
						if collision and full_quota and call_args[1] ~= nil then
							local ok_clone, work = pcall(function() return call_args[1]:clone() end)
							if ok_clone and work then
								local retry = grid_results
								for attempt = 1, 4096 do
									local rejected = retry[4]
									local reject_x, reject_y = point_xyz(rejected)
									if reject_x == nil or reject_y == nil then
										repair_reason = "candidate_coordinates_unavailable"
										break
									end
									local ok_retire = pcall(function() work:set(reject_x, reject_y, 0) end)
									if not ok_retire then
										repair_reason = "candidate_retire_failed"
										break
									end
									local next_results
									local ok_next, next_err = pcall(function()
										next_results = PackValues(saved_grid_min_max(
											work, Unpack(call_args, 2, call_args.n)))
									end)
									if not ok_next then
										repair_reason = "next_max_error:" .. tostring(next_err)
										break
									end
									local next_max, next_candidate = next_results[2], next_results[4]
									if type(next_max) ~= "number" or next_max <= 0 or not next_candidate then
										repair_reason = "next_max_exhausted"
										break
									end
									local next_hex = aligned_hex_key(next_candidate)
									if not next_hex then
										repair_reason = "next_max_alignment_unavailable"
										break
									elseif not consumed_aligned_hexes[next_hex] then
										-- Change only the maximum pair consumed by the breakthrough proc. The
										-- native minimum pair and tuple shape remain byte-for-byte equivalent.
										grid_results[2] = next_max
										grid_results[4] = next_candidate
										candidate = next_candidate
										candidate_hex = next_hex
										collision = false
										repair_reason = "collision_replaced"
										alignment_trace.breakthrough_replacements =
											alignment_trace.breakthrough_replacements + 1
										break
									end
									retry = next_results
									repair_reason = "next_max_still_collides"
								end
								pcall(function() work:free() end)
							else
								repair_reason = "candidate_clone_failed"
							end
						elseif collision and not full_quota then
							alignment_trace.breakthrough_partial_quota_calls =
								alignment_trace.breakthrough_partial_quota_calls + 1
							repair_reason = "partial_quota_fail_closed"
						end

						-- With a full quota every loop iteration reaches NewAnomaly. Partial-quota
						-- iterations include an indistinguishable erosion-only tail, so do not claim
						-- occupancy for them; the final closure audit will still expose any warning.
						if full_quota and candidate then
							record_consumed_position(candidate, true, {
								proc = proc, resource = "subs Anomaly/Breakthrough",
								index = alignment_trace.breakthrough_calls,
								shape = "single_point", source = repair_reason == "collision_replaced"
									and "replacement" or "native",
								aligns = true, role = "aligned",
							})
						elseif candidate then
							record_consumed_position(candidate, false, {
								proc = proc, resource = "subs Anomaly/Breakthrough",
								index = alignment_trace.breakthrough_calls,
								shape = "single_point", source = "native",
								aligns = false, role = "accepted_or_erosion_tail_unknown",
							})
						end
						if collision then
							alignment_trace.breakthrough_retained_collisions =
								alignment_trace.breakthrough_retained_collisions + 1
						end
						AlignmentTrace("breakthrough maximum audit", {
							call = alignment_trace.breakthrough_calls,
							full_quota = full_quota, rolled_bonus = tostring(rolls.breakthrough_bonus),
							bonus_max = tostring(bonus_to), hash = tostring(candidate_hex),
							collision_retained = collision, repair_reason = repair_reason,
						})
					end
					return Unpack(grid_results, 1, grid_results.n)
				end
				-- Stock OnGenerateLogic resolves GridMinMax through its private `_ENV`. Install
				-- there first and remember the exact raw entry so cleanup restores proxy lookup.
				if type(generator_closure_env) == "table" then
					grid_min_max_closure_raw = rawget(generator_closure_env, "GridMinMax")
					grid_min_max_closure_had_raw = grid_min_max_closure_raw ~= nil
					local ok_install = pcall(rawset, generator_closure_env,
						"GridMinMax", grid_min_max_wrapper)
					grid_min_max_installed_in_closure = ok_install
						and rawget(generator_closure_env, "GridMinMax") == grid_min_max_wrapper
				end
				if not grid_min_max_installed_in_closure then
					AlignmentTrace("breakthrough GridMinMax hook unavailable", {
						closure_env = tostring(generator_closure_env),
						resolved_function = tostring(saved_grid_min_max),
					})
				end
			end

			-- The stock breakthrough filler resolves GridMinMax through an inaccessible private
			-- environment. Once that grid is exhausted it can return (0,0) as if it were valid,
			-- so bypass that one procedure before NewAnomaly and rebuild its requested complement
			-- on the final expanded terrain. All other anomaly/resource/effect procedures retain
			-- their native selection functions and are protected by the general duplicate guard.
			-- Authoritative read-only audit of the engine's FINAL alignment loop. The compiled
			-- RMG closure owns a private `_ENV`, so changing `_G.HexGetNearestCenter` cannot see
			-- this call. ProcInvoke gives us the actual local alignment closure and its named
			-- `to_align`/`work_step` upvalues; inspect the engine-populated `info.align_pos` only
			-- AFTER the original function runs. No alignment is recomputed or mutated here.
			if type(saved_proc_invoke) == "function"
				and (replace_breakthrough_selector
					or (alignment_trace_enabled and not hex_hook_installed_in_closure)) then
				proc_invoke_wrapper = function(tag, func, randless)
					if replace_breakthrough_selector
						and tag == "PlaceAnomalies_FindAnomalies_Breakthrough" then
						local target = type(map.SuperBigMapRolledBreakthroughCount) == "number"
							and map.SuperBigMapRolledBreakthroughCount
							or ((type(self.AnomBreakthroughCount) == "number"
								and self.AnomBreakthroughCount or 0)
								+ (type(rolls.breakthrough_bonus) == "number"
									and rolls.breakthrough_bonus or 0))
						target = math.max(0, math.floor(target))
						map.SuperBigMapBreakthroughRepairTarget = target
						map.SuperBigMapBreakthroughAnomalySpacing = self.AnomalySpacing
						map.SuperBigMapBreakthroughDeepChance = self.DeepAnomBreakthroughChance
						map.SuperBigMapBreakthroughRepairPending = target > 0
						map.SuperBigMapBreakthroughSelector = "post_generation_vanilla_farthest"
						AlignmentTrace("bypassed exhausted private breakthrough selector", {
							target = target, spacing = tostring(self.AnomalySpacing),
							procedure = tag,
						})
						local debug_log = SuperBigMap.DebugLog
						if debug_log and type(debug_log.Info) == "function" then
							pcall(debug_log.Info, "Deposits",
								"deferred breakthrough selection to final expanded terrain", {
									target = target, spacing = tostring(self.AnomalySpacing),
								})
						end
						-- Keep the native ProcInvoke seed/procedure boundary. Its private function is
						-- the only skipped work, so later procedure random streams remain independent.
						return saved_proc_invoke(tag, function() end, randless)
					end
					if tag ~= "PlaceAnomalies_AlignToHexGrid" or type(func) ~= "function" then
						return saved_proc_invoke(tag, func, randless)
					end
					local closure_env, to_align, closure_work_step
					local upvalue_names = {}
					if type(debug_lib) == "table" and type(debug_lib.getupvalue) == "function" then
						for i = 1, 64 do
							local ok_up, name, value = pcall(debug_lib.getupvalue, func, i)
							if not ok_up or name == nil then break end
							upvalue_names[#upvalue_names + 1] = tostring(name)
							if name == "_ENV" then closure_env = value
							elseif name == "to_align" then to_align = value
							elseif name == "work_step" then closure_work_step = value end
						end
					end
					local closure_hash, closure_world_to_hex
					if type(closure_env) == "table" then
						pcall(function()
							closure_hash = closure_env.xxhash
							closure_world_to_hex = closure_env.WorldToHex
						end)
					end
					AlignmentTrace("alignment closure preflight", {
						upvalues = table.concat(upvalue_names, ","),
						to_align_count = type(to_align) == "table" and #to_align or "unavailable",
						work_step = tostring(closure_work_step),
						hash_function = tostring(closure_hash),
						world_to_hex = tostring(closure_world_to_hex),
					})
					local proc_results = PackValues(saved_proc_invoke(tag, func, randless))
					pcall(function()
							if type(to_align) ~= "table" or type(closure_work_step) ~= "number" then
								AlignmentTrace("alignment closure audit unavailable", {
									to_align = tostring(to_align), work_step = tostring(closure_work_step),
								})
								return
							end
							for index, info in ipairs(to_align) do
								alignment_trace.calls = alignment_trace.calls + 1
								local map_pos = info and info.pos and info.pos * closure_work_step or nil
								local aligned = info and info.align_pos or nil
								local raw_x, raw_y, raw_z = point_xyz(map_pos)
								local aligned_x, aligned_y, aligned_z = point_xyz(aligned)
								local raw_key, aligned_key = xy_key(map_pos), xy_key(aligned)
								local ok_hash, native_hash = false, nil
								if type(closure_hash) == "function" then
									ok_hash, native_hash = pcall(closure_hash, aligned)
								end
								if not ok_hash or native_hash == nil then
									alignment_trace.hash_failures = alignment_trace.hash_failures + 1
								end
								local hash_key = ok_hash and native_hash ~= nil and native_hash
									or ("unavailable:" .. tostring(index))
								local hash_text = tostring(hash_key)
								local q, r
								if type(closure_world_to_hex) == "function" then
									local ok_hex, hq, hr = pcall(closure_world_to_hex, aligned)
									if ok_hex then q, r = hq, hr end
								end
								local origins = raw_key and candidate_origins_by_world_xy[raw_key] or nil
								local origin_parts = {}
								for i = 1, #(origins or {}) do
									origin_parts[#origin_parts + 1] = origin_desc(origins[i])
								end
								local origin_text = #origin_parts > 0
									and table.concat(origin_parts, " || ") or "unknown"
								if #origin_parts == 0 then
									alignment_trace.unknown_origins = alignment_trace.unknown_origins + 1
								end
								local previous = alignment_trace.by_hash[hash_key]
								local record = {
									index = index, hash = hash_key,
									raw_x = raw_x, raw_y = raw_y, raw_z = raw_z,
									aligned_x = aligned_x, aligned_y = aligned_y, aligned_z = aligned_z,
									aligned_key = aligned_key, q = q, r = r, origin = origin_text,
								}
								if previous then
									alignment_trace.duplicate_calls = alignment_trace.duplicate_calls + 1
									if not alignment_trace.duplicate_hashes[hash_key] then
										alignment_trace.duplicate_hashes[hash_key] = true
										alignment_trace.duplicate_hexes = alignment_trace.duplicate_hexes + 1
									end
									AlignmentTrace("AUTHORITATIVE duplicate aligned hex", {
										hash = hash_text, q = tostring(q), r = tostring(r),
										first_index = previous.index, incoming_index = index,
										first_raw = tostring(previous.raw_x) .. ":" .. tostring(previous.raw_y),
										incoming_raw = tostring(raw_x) .. ":" .. tostring(raw_y),
										first_aligned = tostring(previous.aligned_x) .. ":" .. tostring(previous.aligned_y),
										incoming_aligned = tostring(aligned_x) .. ":" .. tostring(aligned_y),
										same_aligned_xy = previous.aligned_key == aligned_key,
										first_origin = previous.origin, incoming_origin = origin_text,
										incoming_layer = tostring(info.layer), incoming_resource = tostring(info.res),
										incoming_scenario = tostring(info.scenario),
									})
								end
								alignment_trace.by_hash[hash_key] = record
								local aligned_calls = aligned_key and alignment_trace.by_aligned_xy[aligned_key] or nil
								if aligned_key and not aligned_calls then
									aligned_calls = {}
									alignment_trace.by_aligned_xy[aligned_key] = aligned_calls
								end
								if aligned_calls then aligned_calls[#aligned_calls + 1] = record end
								AlignmentTrace("final alignment input", {
									index = index, hash = hash_text,
									duplicate_of = previous and previous.index or "none",
									raw_work_x = type(raw_x) == "number" and raw_x / closure_work_step or "n/a",
									raw_work_y = type(raw_y) == "number" and raw_y / closure_work_step or "n/a",
									raw_world = tostring(raw_x) .. ":" .. tostring(raw_y) .. ":" .. tostring(raw_z),
									aligned_world = tostring(aligned_x) .. ":" .. tostring(aligned_y) .. ":" .. tostring(aligned_z),
									q = tostring(q), r = tostring(r), origin = origin_text,
									info_layer = tostring(info.layer), info_resource = tostring(info.res),
									info_scenario = tostring(info.scenario),
									census_origin = origin_desc(aligned_origin_by_hash[hash_text]),
								})
							end
					end)
					return Unpack(proc_results, 1, proc_results.n)
				end
				env.ProcInvoke = proc_invoke_wrapper
			end

			-- Sandbox-safe authoritative observation point. GenMarkerObj receives the FINAL
			-- post-snap position after the private alignment closure has run, and is supplied
			-- directly through env even when getfenv/debug APIs are stripped. Audit every
			-- alignable marker independently of the private-hook trace, correlate its actual
			-- final hash/coordinate with every predicted raw candidate, and never mutate input,
			-- output, warning state, or marker position. The original factory is called once.
			if alignment_trace_enabled and type(saved_gen_marker_obj) == "function" then
				local function is_aligned_marker_class(name)
					name = tostring(name or "")
					return string.find(name, "SubsurfaceDepositMarker", 1, true) ~= nil
						or string.find(name, "TerrainDepositMarker", 1, true) ~= nil
						or string.find(name, "SubsurfaceAnomalyMarker", 1, true) ~= nil
						or string.find(name, "EffectDepositMarker", 1, true) ~= nil
				end
				local function class_name(value)
					local name = tostring(value)
					pcall(function()
						name = tostring(value.class or value.__name or value.ClassName or value)
					end)
					return name
				end
				local marker_field_names = {
					"resource", "deposit_type", "tech_action", "sequence", "sequence_list",
					"depth_layer", "grade", "max_amount", "density", "density2", "prefab",
				}
				local function marker_fields(value)
					if type(value) ~= "table" then return "type=" .. type(value) .. ";value=" .. tostring(value) end
					local parts = {}
					for i = 1, #marker_field_names do
						local key = marker_field_names[i]
						local field = value[key]
						if field ~= nil then
							parts[#parts + 1] = key .. "=" .. tostring(field)
						end
					end
					return #parts > 0 and table.concat(parts, ";") or "no_known_fields"
				end
				local function candidate_matches_text(matches)
					local parts = {}
					for i = 1, #(matches or {}) do
						local candidate = matches[i]
						parts[#parts + 1] = table.concat({
							"candidate=" .. tostring(candidate.index),
							"raw_work=" .. tostring(candidate.raw_work_x) .. ":" .. tostring(candidate.raw_work_y),
							"raw_world=" .. tostring(candidate.raw_world_key),
							"predicted=" .. tostring(candidate.predicted_x) .. ":" .. tostring(candidate.predicted_y),
							"hash=" .. tostring(candidate.predicted_hash),
							"declared_aligns=" .. tostring(candidate.declared_aligns),
							candidate.origin_text,
						}, ";")
					end
					return #parts > 0 and table.concat(parts, " || ") or "none"
				end
				gen_marker_obj_wrapper = function(marker_map, classdef, map_pos, lua_obj, debug_id, ...)
					local marker_results = PackValues(saved_gen_marker_obj(
						marker_map, classdef, map_pos, lua_obj, debug_id, ...))
					pcall(function()
						local declared_class = class_name(classdef)
						local obj = marker_results[1]
						local object_class = class_name(obj)
						local alignable_class = is_aligned_marker_class(declared_class)
							or is_aligned_marker_class(object_class)
						if not alignable_class then return end

						alignment_trace.factory_calls = alignment_trace.factory_calls + 1
						local factory_index = alignment_trace.factory_calls
						local aligned_x, aligned_y, aligned_z = point_xyz(map_pos)
						local aligned_key = xy_key(map_pos)
						local ok_hash, actual_hash = false, nil
						if type(alignment_hash) == "function" then
							ok_hash, actual_hash = pcall(alignment_hash, map_pos)
						end
						if not ok_hash or actual_hash == nil then
							alignment_trace.factory_hash_failures = alignment_trace.factory_hash_failures + 1
						end
						local actual_hash_key = ok_hash and actual_hash ~= nil and tostring(actual_hash) or nil
						local factory_key = actual_hash_key or (aligned_key and ("xy:" .. aligned_key))
							or ("unavailable:" .. tostring(factory_index))
						local predictions = actual_hash_key and candidate_predictions_by_hash[actual_hash_key] or nil
						local match_source = predictions and "predicted_hash" or "none"
						if not predictions and aligned_key then
							predictions = candidate_predictions_by_aligned_xy[aligned_key]
							if predictions then match_source = "predicted_aligned_xy" end
						end
						if not predictions or #predictions == 0 then
							alignment_trace.factory_unmatched_candidates =
								alignment_trace.factory_unmatched_candidates + 1
						end
						local declared_matches, unclassified_matches = 0, 0
						for i = 1, #(predictions or {}) do
							if predictions[i].declared_aligns then
								declared_matches = declared_matches + 1
							else
								unclassified_matches = unclassified_matches + 1
							end
						end
						local stack = State.rmg_placement_proc_stack
						local proc = type(stack) == "table" and tostring(stack[#stack]) or "?"
						local q, r
						if type(closure_world_to_hex) == "function" then
							local ok_hex, hq, hr = pcall(closure_world_to_hex, map_pos)
							if ok_hex then q, r = hq, hr end
						end
						local handle = "?"
						pcall(function() handle = tostring(obj.handle) end)
						local record = {
							index = factory_index, hash = factory_key, actual_hash = actual_hash_key,
							aligned_key = aligned_key, aligned_x = aligned_x, aligned_y = aligned_y,
							aligned_z = aligned_z, q = q, r = r, proc = proc,
							declared_class = declared_class, object_class = object_class,
							handle = handle, debug_id = tostring(debug_id),
							marker_fields = marker_fields(lua_obj), lua_obj = tostring(lua_obj),
							candidate_matches = candidate_matches_text(predictions),
							candidate_match_count = #(predictions or {}), match_source = match_source,
							declared_matches = declared_matches,
							unclassified_matches = unclassified_matches,
						}
						local previous = alignment_trace.factory_by_hash[factory_key]
						if previous then
							alignment_trace.factory_duplicate_calls =
								alignment_trace.factory_duplicate_calls + 1
							alignment_trace.markers_on_duplicate_hexes =
								alignment_trace.markers_on_duplicate_hexes + 1
							if not alignment_trace.factory_duplicate_hashes[factory_key] then
								alignment_trace.factory_duplicate_hashes[factory_key] = true
								alignment_trace.factory_duplicate_hexes =
									alignment_trace.factory_duplicate_hexes + 1
							end
							AlignmentTrace("SANDBOX-SAFE duplicate final marker hex", {
								hash = tostring(actual_hash_key), aligned_xy = tostring(aligned_key),
								q = tostring(q), r = tostring(r), same_aligned_xy = previous.aligned_key == aligned_key,
								first_index = previous.index, incoming_index = factory_index,
								first_class = previous.declared_class, incoming_class = declared_class,
								first_object_class = previous.object_class, incoming_object_class = object_class,
								first_proc = previous.proc, incoming_proc = proc,
								first_debug_id = previous.debug_id, incoming_debug_id = tostring(debug_id),
								first_fields = previous.marker_fields, incoming_fields = record.marker_fields,
								first_candidate_matches = previous.candidate_matches,
								incoming_candidate_matches = record.candidate_matches,
								first_match_source = previous.match_source, incoming_match_source = match_source,
								first_declared_matches = previous.declared_matches,
								incoming_declared_matches = declared_matches,
								first_unclassified_matches = previous.unclassified_matches,
								incoming_unclassified_matches = unclassified_matches,
							})
						end
						alignment_trace.factory_by_hash[factory_key] = record
						AlignmentTrace("sandbox-safe final marker factory observation", {
							factory_index = factory_index, duplicate_of = previous and previous.index or "none",
							hash = tostring(actual_hash_key), aligned_xy = tostring(aligned_key),
							aligned_world = tostring(aligned_x) .. ":" .. tostring(aligned_y)
								.. ":" .. tostring(aligned_z),
							q = tostring(q), r = tostring(r), proc = proc,
							declared_class = declared_class, object_class = object_class,
							handle = handle, debug_id = tostring(debug_id),
							marker_fields = record.marker_fields, lua_obj = tostring(lua_obj),
							candidate_match_count = record.candidate_match_count,
							candidate_match_source = match_source,
							declared_candidate_matches = declared_matches,
							unclassified_candidate_matches = unclassified_matches,
							candidate_matches = record.candidate_matches,
						})
					end)
					return Unpack(marker_results, 1, marker_results.n)
				end
				env.GenMarkerObj = gen_marker_obj_wrapper
			end

			-- Feature deposit scalar `grand` calls carry only {min,max}; their layer/resource
			-- lives in the immediately preceding DepositLayers[layer].filter(res) call. Capture
			-- that exact stock context so subsurface/terrain feature deposits enter the aligned
			-- census while surface cluster centers remain deliberately unaligned.
			local deposit_layers = closure_global("DepositLayers", Global("DepositLayers"))
			if type(deposit_layers) == "table" then
				local seen_layers = {}
				for key, layer_info in pairs(deposit_layers) do
					if type(layer_info) == "table" and not seen_layers[layer_info]
						and type(layer_info.filter) == "function" then
						seen_layers[layer_info] = true
						local original_filter = layer_info.filter
						local layer_id = tostring(layer_info.id or key)
						local filter_wrapper = function(...)
							local call_args = PackValues(...)
							local filter_results = PackValues(original_filter(...))
							local stack = State.rmg_placement_proc_stack
							local proc = type(stack) == "table" and tostring(stack[#stack]) or ""
							if proc == "PlaceAnomalies_FindFeatures_Deposits" then
								feature_deposit_context = nil
								if filter_results[1] then
									feature_deposit_context = {
										layer = layer_id, resource = tostring(call_args[1] or "?"),
									}
								end
							end
							return Unpack(filter_results, 1, filter_results.n)
						end
						layer_info.filter = filter_wrapper
						deposit_layer_filter_restores[#deposit_layer_filter_restores + 1] = {
							layer = layer_info, original = original_filter, wrapper = filter_wrapper,
						}
					end
				end
			end

			-- Stock Proc_ResolveBuildable calls private RebuildBuildableGrid, which then dynamically
			-- dispatches map.buildable:Build. Retail builds expose no getfenv/debug API, so the private
			-- global lookup cannot be replaced reliably. Intercept the public BuildableGrid method one
			-- call lower instead. The hook is scoped to this synchronous OnGenerateLogic transaction and
			-- restored immediately afterward, including errors.
			local desired_w = tonumber(map and map.SuperBigMapDesiredWidthTiles)
			local desired_h = tonumber(map and map.SuperBigMapDesiredHeightTiles)
			local generator_w = tonumber(map and map.SuperBigMapGeneratorWidthTiles)
			local generator_h = tonumber(map and map.SuperBigMapGeneratorHeightTiles)
			local rebuild_buildable_grid_required = not is_underground
				and map.SuperBigMapDeferredBackingPromotion ~= true
				and cfg_bool("EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE", false)
				and cfg_bool("QUADRANT_LIMIT_BUILDABLE_GRID_TO_SOURCE", true)
				and desired_w and desired_h and generator_w and generator_h
				and desired_w > generator_w and desired_h > generator_h
			rebuild_buildable_grid_wrapper = function(buildable, target_map, width, height, map_data, ...)
				rebuild_buildable_grid_calls = rebuild_buildable_grid_calls + 1
				source_mask_log("SOURCE_BUILDABLE_BRIDGE_CALL_BEGIN", {
					call = rebuild_buildable_grid_calls,
					buildable = tostring(buildable),
					target = tostring(target_map), target_is_generation_map = target_map == map,
					target_buildable_matches = target_map and target_map.buildable == buildable,
					requested_hex = tostring(width) .. "x" .. tostring(height),
					requested_mapdata_tiles = tostring(map_data and map_data.Width)
						.. "x" .. tostring(map_data and map_data.Height),
					target_world = tostring(target_map and target_map.Width)
						.. "x" .. tostring(target_map and target_map.Height),
					target_hex = tostring(target_map and target_map.hex_width)
						.. "x" .. tostring(target_map and target_map.hex_height),
					target_mapdata_tiles = tostring(target_map and target_map.mapdata
						and target_map.mapdata.Width) .. "x" .. tostring(target_map
						and target_map.mapdata and target_map.mapdata.Height),
				})
				local bridge_ok, bridge_reason = rebuild_source_buildable_grid(target_map)
				if bridge_ok then
					source_mask_log("SOURCE_BUILDABLE_BRIDGE_CALL_END", {
						call = rebuild_buildable_grid_calls, result = "bridged",
						grid = tostring(target_map and target_map.buildable
							and target_map.buildable.z_grid),
					})
					return
				end
				if bridge_reason == "mode-not-eligible" or bridge_reason == "map-not-expanded" then
					source_mask_log("SOURCE_BUILDABLE_BRIDGE_CALL_FALLBACK", {
						call = rebuild_buildable_grid_calls, reason = tostring(bridge_reason),
						native = tostring(saved_buildable_grid_build),
					}, "warn")
					if type(saved_buildable_grid_build) == "function" then
						return saved_buildable_grid_build(buildable, target_map,
							width, height, map_data, ...)
					end
				end
				local failure = "source buildable raw-grid bridge failed before vanilla mask/playable "
					.. "resolution: " .. tostring(bridge_reason)
				source_mask_log("SOURCE_BUILDABLE_BRIDGE_CALL_ABORT", {
					call = rebuild_buildable_grid_calls, reason = tostring(bridge_reason),
					failure = failure,
				}, "error")
				error(failure)
			end

			if rebuild_buildable_grid_required and type(buildable_grid_class) == "table"
				and type(saved_buildable_grid_build) == "function" then
				rebuild_buildable_grid_raw = rawget(buildable_grid_class, "Build")
				rebuild_buildable_grid_had_raw = rebuild_buildable_grid_raw ~= nil
				local ok_install = pcall(rawset, buildable_grid_class,
					"Build", rebuild_buildable_grid_wrapper)
				rebuild_buildable_grid_installed = ok_install
					and rawget(buildable_grid_class, "Build") == rebuild_buildable_grid_wrapper
			end
			source_mask_log("SOURCE_BUILDABLE_BRIDGE_HOOK_DECISION", {
				required = rebuild_buildable_grid_required and true or false,
				installed = rebuild_buildable_grid_installed,
				surface = not is_underground,
				desired_tiles = tostring(desired_w) .. "x" .. tostring(desired_h),
				generator_tiles = tostring(generator_w) .. "x" .. tostring(generator_h),
				hook_target = "BuildableGrid.Build",
				buildable_grid_class = tostring(buildable_grid_class),
				environment = tostring(generator_closure_env),
				environment_source = tostring(generator_closure_env_source),
				native = tostring(saved_buildable_grid_build),
				previous_raw = tostring(rebuild_buildable_grid_raw),
				previous_had_raw = rebuild_buildable_grid_had_raw,
			}, rebuild_buildable_grid_required and not rebuild_buildable_grid_installed
				and "error" or nil)

			local results
			if rebuild_buildable_grid_required and not rebuild_buildable_grid_installed then
				results = { false, "source buildable raw-grid bridge hook unavailable; refusing "
					.. "to generate a non-vanilla comparison" }
			else
				results = { pcall(original_on_generate_logic, self, env, ...) }
			end

			local rebuild_restore_ok = true
			local rebuild_restore_reason = "not-installed"
			if rebuild_buildable_grid_installed and type(buildable_grid_class) == "table" then
				local current = rawget(buildable_grid_class, "Build")
				if current == rebuild_buildable_grid_wrapper then
					local ok_restore = pcall(rawset, buildable_grid_class, "Build",
						rebuild_buildable_grid_had_raw and rebuild_buildable_grid_raw or nil)
					rebuild_restore_ok = ok_restore and rawget(buildable_grid_class,
						"Build") == (rebuild_buildable_grid_had_raw
						and rebuild_buildable_grid_raw or nil)
					rebuild_restore_reason = rebuild_restore_ok and "restored" or "restore-write-failed"
				else
					rebuild_restore_ok = false
					rebuild_restore_reason = "hook-replaced-during-generation:" .. tostring(current)
				end
			end
			local restore_status = {
				installed = rebuild_buildable_grid_installed,
				restored = rebuild_restore_ok,
				reason = rebuild_restore_reason,
				calls = rebuild_buildable_grid_calls,
				observed = rebuild_buildable_grid_calls > 0,
				generation_ok = results[1] == true,
				generation_error = results[1] and "none" or tostring(results[2]),
			}
			if rebuild_restore_ok then
				source_mask_log("SOURCE_BUILDABLE_BRIDGE_HOOK_RESTORE", restore_status)
			else
				source_mask_log("SOURCE_BUILDABLE_BRIDGE_HOOK_RESTORE", restore_status, "error")
			end
			if not rebuild_restore_ok and results[1] then
				results = { false, "source buildable raw-grid bridge cleanup failed: "
					.. tostring(rebuild_restore_reason) }
			elseif rebuild_buildable_grid_required and results[1]
				and rebuild_buildable_grid_calls == 0 then
				source_mask_log("SOURCE_BUILDABLE_BRIDGE_HOOK_NOT_OBSERVED", {
					hook_target = "BuildableGrid.Build", installed = rebuild_buildable_grid_installed,
					class = tostring(buildable_grid_class), native = tostring(saved_buildable_grid_build),
				}, "error")
				results = { false, "source buildable raw-grid bridge was installed but never called; "
					.. "refusing to accept a non-vanilla comparison" }
			end
			for i = #deposit_layer_filter_restores, 1, -1 do
				local restore = deposit_layer_filter_restores[i]
				if restore.layer.filter == restore.wrapper then restore.layer.filter = restore.original end
			end
			if gen_marker_obj_wrapper and env.GenMarkerObj == gen_marker_obj_wrapper then
				env.GenMarkerObj = saved_gen_marker_obj
			end
			if proc_invoke_wrapper and env.ProcInvoke == proc_invoke_wrapper then
				env.ProcInvoke = saved_proc_invoke
			end
			if type(rhelpers) == "table" and rhelpers[2] ~= saved_rrand then
				rhelpers[2] = saved_rrand
			end
			if type(rhelpers) == "table" and rhelpers[5] ~= saved_grand then
				rhelpers[5] = saved_grand
			end
			if env.rm_print ~= saved_rm_print then env.rm_print = saved_rm_print end
			if env.GetPlayableArea ~= saved_get_playable_area then
				env.GetPlayableArea = saved_get_playable_area
			end
			if generate_resource_info_wrapper
				and Global("GenerateResourceInfo") == generate_resource_info_wrapper then
				rawset(_G, "GenerateResourceInfo", saved_generate_resource_info)
			end
			if grid_min_max_installed_in_closure and type(generator_closure_env) == "table"
				and rawget(generator_closure_env, "GridMinMax") == grid_min_max_wrapper then
				rawset(generator_closure_env, "GridMinMax",
					grid_min_max_closure_had_raw and grid_min_max_closure_raw or nil)
			end
			if hex_hook_installed_in_closure and type(generator_closure_env) == "table"
				and rawget(generator_closure_env, "HexGetNearestCenter")
					== hex_get_nearest_center_wrapper then
				rawset(generator_closure_env, "HexGetNearestCenter",
					hex_closure_had_raw and hex_closure_raw or nil)
			end
			if base_play_zone_snapshot then
				pcall(function() base_play_zone_snapshot:free() end)
				base_play_zone_snapshot = nil
			end
			if alignment_trace_enabled then
				local duplicate_hashes = {}
				for hash in pairs(alignment_trace.duplicate_hashes) do
					duplicate_hashes[#duplicate_hashes + 1] = tostring(hash)
				end
				table.sort(duplicate_hashes)
				local factory_duplicate_hashes = {}
				for hash in pairs(alignment_trace.factory_duplicate_hashes) do
					factory_duplicate_hashes[#factory_duplicate_hashes + 1] = tostring(hash)
				end
				table.sort(factory_duplicate_hashes)
				local generator_debugging = self.debugging and true or false
				local warning_match = alignment_trace.hash_failures > 0
					and "indeterminate_hash_failure"
					or (not generator_debugging and "indeterminate_engine_debugging_off"
						or tostring(alignment_trace.warning_count == alignment_trace.duplicate_calls))
				AlignmentTrace("authoritative final-alignment summary", {
					map = tostring(map and (map.name or (map.mapdata and map.mapdata.id)) or "?"),
					environment = tostring(environment), alignment_calls = alignment_trace.calls,
					environment_source = tostring(generator_closure_env_source),
					hex_hook_installed = hex_hook_installed_in_closure,
					grid_min_max_hook_installed = grid_min_max_installed_in_closure,
					collision_repair_enabled =
						cfg_bool("ENABLE_NATIVE_ALIGNED_HEX_COLLISION_REPAIR", false),
					duplicate_calls = alignment_trace.duplicate_calls,
					duplicate_hexes = alignment_trace.duplicate_hexes,
					duplicate_hashes = table.concat(duplicate_hashes, ","),
					engine_warnings = alignment_trace.warning_count,
					generator_debugging = generator_debugging,
					warning_match = warning_match,
					hash_failures = alignment_trace.hash_failures,
					candidate_census_collisions = alignment_trace.candidate_collisions,
					breakthrough_calls = alignment_trace.breakthrough_calls,
					breakthrough_collisions = alignment_trace.breakthrough_collisions,
					breakthrough_replacements = alignment_trace.breakthrough_replacements,
					breakthrough_retained_collisions =
						alignment_trace.breakthrough_retained_collisions,
					breakthrough_partial_quota_calls =
						alignment_trace.breakthrough_partial_quota_calls,
					markers_on_duplicate_hexes = alignment_trace.markers_on_duplicate_hexes,
					unknown_origins = alignment_trace.unknown_origins,
					generation_ok = results[1] == true,
				})
				AlignmentTrace("sandbox-safe marker-factory summary", {
					map = tostring(map and (map.name or (map.mapdata and map.mapdata.id)) or "?"),
					environment = tostring(environment),
					factory_calls = alignment_trace.factory_calls,
					factory_duplicate_calls = alignment_trace.factory_duplicate_calls,
					factory_duplicate_hexes = alignment_trace.factory_duplicate_hexes,
					factory_duplicate_hashes = table.concat(factory_duplicate_hashes, ","),
					factory_hash_failures = alignment_trace.factory_hash_failures,
					factory_unmatched_candidates = alignment_trace.factory_unmatched_candidates,
					candidate_predictions = candidate_trace_sequence,
					engine_warnings = alignment_trace.warning_count,
					warning_match = tostring(alignment_trace.warning_count
						== alignment_trace.factory_duplicate_calls),
					private_alignment_hook_available = hex_hook_installed_in_closure,
					collision_repair_enabled =
						cfg_bool("ENABLE_NATIVE_ALIGNED_HEX_COLLISION_REPAIR", false),
					generation_ok = results[1] == true,
				})
			end

			-- If the engine kept GenerateResourceInfo as a lexical reference, reconstruct the
			-- exact requested totals without replaying any random rolls: after native generation,
			-- every successful request is represented by its marker, and each failed layer's
			-- authoritative outer warning supplied precisely (target - placed). Therefore
			-- native census + residual shortfalls is the original requested total for every
			-- resource, regardless of whether the run was 8/9, 3/8, or any other values.
			if results[1] and type(map) == "table" and type(map.MapForEach) == "function"
				and (not map.SuperBigMapResourceTargetCapture
					or map.SuperBigMapResourceTargetCapture == "rm_print failure args") then
				local native_counts = {}
				pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
					if not marker then return end
					local is_resource = Engine.IsKindOf(marker, "SurfaceDepositMarker")
						or Engine.IsKindOf(marker, "SubsurfaceDepositMarker")
						or Engine.IsKindOf(marker, "TerrainDepositMarker")
					if not is_resource then return end
					local resource = tostring(marker.resource or marker.class or "")
					if resource ~= "" then
						native_counts[resource] = (native_counts[resource] or 0) + 1
					end
				end)
				local residual_by_resource, residual_total = {}, 0
				for _, entry in pairs(map.SuperBigMapResourceResidualShortfalls or {}) do
					if type(entry) == "table" and type(entry.resource) == "string"
						and type(entry.missing) == "number" and entry.missing > 0 then
						residual_by_resource[entry.resource] =
							(residual_by_resource[entry.resource] or 0) + entry.missing
						residual_total = residual_total + entry.missing
					end
				end
				for resource, count in pairs(native_counts) do
					map.SuperBigMapExpectedResourceCounts[resource] =
						count + (residual_by_resource[resource] or 0)
				end
				for resource, missing in pairs(residual_by_resource) do
					if native_counts[resource] == nil then
						map.SuperBigMapExpectedResourceCounts[resource] = missing
					end
				end
				if next(map.SuperBigMapExpectedResourceCounts) then
					map.SuperBigMapResourceTargetCapture = residual_total > 0
						and "native census + authoritative RMG residuals"
						or "native census (all requested resources placed)"
				end
			end

			local debug_log = SuperBigMap.DebugLog
			if debug_log and type(map) == "table" then
				local data = {
					anomaly_capture = tostring(map.SuperBigMapAnomalyTargetCapture),
					resource_capture = tostring(map.SuperBigMapResourceTargetCapture),
					rolls_captured = roll_index,
				}
				for kind, count in pairs(map.SuperBigMapExpectedAnomalyCounts or {}) do
					data["anomaly_" .. tostring(kind)] = count
				end
				for resource, count in pairs(map.SuperBigMapExpectedResourceCounts or {}) do
					data["resource_" .. tostring(resource)] = count
				end
				debug_log.Info("Generation", "captured authoritative RMG enrichment targets", data)
			end
			if not results[1] then error(results[2]) end
			return Unpack(results, 2)
		end
		generator_class.OnGenerateLogic = on_generate_logic_wrapper
		State.generator_on_generate_logic_wrapper = on_generate_logic_wrapper
	end

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
			local result = original_proc_start(self, tag, ...)
			State.rmg_placement_proc_stack = State.rmg_placement_proc_stack or {}
			State.rmg_placement_proc_stack[#State.rmg_placement_proc_stack + 1] = tag
			-- Stretch-mode placement repair begins at the engine's outer PlaceAnomalies
			-- boundary, immediately before that procedure builds every border/spacing-derived
			-- candidate mask. ResolveBuildable is traced separately to prove the native play-zone
			-- inputs without changing them. Per-procedure random streams remain untouched.
			local active_map = State.rmg_placement_active_map
			local active_environment = type(active_map) == "table"
				and type(active_map.mapdata) == "table" and active_map.mapdata.Environment or nil
			local placement = SuperBigMap.RmgPlacement
			if placement and type(placement.TraceState) == "function"
				and (tag == "ResolveBuildable" or tag == "PlaceAnomalies") then
				pcall(placement.TraceState, self, active_map, "ProcStart before repair: " .. tostring(tag), {
					active_flag = tostring(State.rmg_placement_proc_active),
				})
			end
			if tag == "PlaceAnomalies" and active_map and active_environment ~= "Underground" then
				if placement and type(placement.Begin) == "function" then
					local ok, began = pcall(placement.Begin, self,
						State.rmg_placement_active_map, {
							allow_stretch_placement = true,
							preserve_native_counts = true,
						})
					State.rmg_placement_proc_active = ok and began == true
					if not ok then
						DebugPrint("PlaceAnomalies placement repair begin ERROR: " .. tostring(began))
						-- Begin publishes its rollback snapshot before mutation. Always attempt cleanup
						-- even though no successful active flag was returned.
						if type(placement.End) == "function" then
							local cleanup_ok, cleanup_err = pcall(placement.End, active_map)
							if not cleanup_ok then
								DebugPrint("PlaceAnomalies placement repair rollback ERROR: " .. tostring(cleanup_err))
							end
						end
					end
					if type(placement.TraceState) == "function" then
						pcall(placement.TraceState, self, active_map,
							"ProcStart after repair: PlaceAnomalies", {
								begin_ok = tostring(ok), begin_result = tostring(began),
							})
					end
				end
			end
			return result
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
			local result = original_proc_end(self, tag, ...)
			if tag == "PlaceAnomalies" and State.rmg_placement_proc_active then
				local placement = SuperBigMap.RmgPlacement
				local map = State.rmg_placement_active_map
				if placement and type(placement.TraceState) == "function" then
					pcall(placement.TraceState, self, map, "ProcEnd before restoration: PlaceAnomalies")
				end
				if placement and type(placement.End) == "function" then
					local ok, err = pcall(placement.End, map)
					if ok then
						State.rmg_placement_proc_active = false
					else
						DebugPrint("PlaceAnomalies placement repair end ERROR: " .. tostring(err))
					end
				end
			end
			local stack = State.rmg_placement_proc_stack
			if type(stack) == "table" then stack[#stack] = nil end
			return result
		end
		generator_class.ProcEnd = proc_end_wrapper
		State.generator_proc_end_wrapper = proc_end_wrapper
	end
	local generate_wrapper = function(self, params)
		params = type(params) == "table" and params or {}
		EnrichmentSpreadBoundary(self, nil, "expansion-Generate-before-source-allocation", {
			map_name = tostring(params.map_name), map_slot = tostring(params.map_slot),
		})
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
		EnrichmentSpreadBoundary(self, nil, "expansion-Generate-after-source-allocation", {
			map_name = tostring(params.map_name), map_slot = tostring(params.map_slot),
			pending = tostring(params.SuperBigMapQuadrantCopyPending),
			source_width = tostring(params.SuperBigMapSourceWidth),
			desired_width_tiles = tostring(params.SuperBigMapDesiredWidthTiles),
		})

		return original_generate(self, params)
	end
	generator_class.Generate = generate_wrapper
	State.generator_generate_wrapper = generate_wrapper

	if type(original_do_generate) == "function" then
		local do_generate_wrapper = function(self, map, ...)
			EnrichmentSpreadBoundary(self, map, "expansion-DoGenerate-entry-before-source-view")
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
					CaptureGeneratedNativeEnrichments(map, "DoGenerate native complete")
					local promoted, promotion_reason = PromoteDeferredExpandedBacking(map,
						"DoGenerate native complete")
					if not promoted then
						error("deferred expanded backing promotion failed: " .. tostring(promotion_reason))
					end
					return Unpack(results, 2)
				end
				local profiler = SuperBigMap.LoadingProfiler
				local load_token = profiler and type(profiler.Begin) == "function" and profiler.Begin(
					"RandomMapGenerator.DoGenerate native body",
					{ blank = tostring(self.BlankMap), detected_width_tiles = cur_w_tiles,
						detected_height_tiles = cur_h_tiles }, map) or false
				local function complete(...)
					if load_token then profiler.End(load_token, { result_count = select("#", ...) }, true) end
					CaptureGeneratedNativeEnrichments(map, "DoGenerate native complete")
					local promoted, promotion_reason = PromoteDeferredExpandedBacking(map,
						"DoGenerate native complete")
					if not promoted then
						error("deferred expanded backing promotion failed: " .. tostring(promotion_reason))
					end
					return ...
				end
				return complete(original_do_generate(self, map, ...))
			end

			-- Exact-source path: keep this already allocated expanded map as the destination, but
			-- execute the generator body once on a separate native-sized backing. The helper copies
			-- terrain, transfers the generated objects, rebuilds only the final destination grids,
			-- unloads the temporary slot, and returns the original DoGenerate result tuple.
			local migrated, migrated_results = GenerateOnTemporaryVanillaBacking(
				self, map, original_do_generate, ...)
			if migrated then
				GenRandCensus(map, "post-gen TEMP-NATIVE migrated destination")
				return Unpack(migrated_results, 1, migrated_results.n)
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
			local saved_map_width = map and map.Width
			local saved_map_height = map and map.Height
			local saved_map_hex_width = map and map.hex_width
			local saved_map_hex_height = map and map.hex_height
			local buildable_source_view = false

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

			-- ATOMIC SOURCE-SIZED MAP/BUILDABLE VIEW. Vanilla RebuildBuildableGrid does not consult
			-- map:GetMapSize, terrain.GetMapSize, or MapData.Width when choosing its grid
			-- dimensions; it directly passes map.hex_width/map.hex_height into BuildableGrid:Build.
			-- MaskBuildableGrid then consumes the Map object natively and can still project that grid
			-- through the cached map.Width/map.Height MapVars, which were initialized from the expanded
			-- allocation. Present all four cached extents as one vanilla-sized transaction (8192 ->
			-- 6144 gives world 819200 -> 614400 and hex 820x946 -> 615x710), restore all four
			-- immediately afterward even when native generation fails, and only then rebuild the real
			-- expanded gameplay grid.
			if cfg_bool("QUADRANT_LIMIT_BUILDABLE_GRID_TO_SOURCE", true)
				and type(saved_map_width) == "number" and saved_map_width > 0
				and type(saved_map_height) == "number" and saved_map_height > 0
				and type(saved_map_hex_width) == "number" and saved_map_hex_width > 0
				and type(saved_map_hex_height) == "number" and saved_map_hex_height > 0
				and cur_w_tiles > 0 and cur_h_tiles > 0 then
				local source_hex_width = math.max(1,
					math.floor((saved_map_hex_width * gen_width_tiles + 0.0) / cur_w_tiles + 0.5))
				local source_hex_height = math.max(1,
					math.floor((saved_map_hex_height * gen_height_tiles + 0.0) / cur_h_tiles + 0.5))
				local source_fits_expanded = gen_world_w <= saved_map_width and gen_world_h <= saved_map_height
					and source_hex_width <= saved_map_hex_width and source_hex_height <= saved_map_hex_height
				local source_is_smaller = gen_world_w < saved_map_width or gen_world_h < saved_map_height
					or source_hex_width < saved_map_hex_width or source_hex_height < saved_map_hex_height
				if source_fits_expanded and source_is_smaller then
					buildable_source_view = {
						source_world_width = gen_world_w, source_world_height = gen_world_h,
						expanded_world_width = saved_map_width, expanded_world_height = saved_map_height,
						source_hex_width = source_hex_width, source_hex_height = source_hex_height,
						expanded_hex_width = saved_map_hex_width, expanded_hex_height = saved_map_hex_height,
					}
					-- Retain the real backing dimensions while the Lua-facing Map fields present the
					-- source view. The source-mask bridge uses these values to make the native mask
					-- sampler's cell-to-world step identical to a genuinely vanilla allocation.
					map.SuperBigMapExpandedWorldWidth = saved_map_width
					map.SuperBigMapExpandedWorldHeight = saved_map_height
					map.SuperBigMapExpandedHexWidth = saved_map_hex_width
					map.SuperBigMapExpandedHexHeight = saved_map_hex_height
					map.Width = gen_world_w
					map.Height = gen_world_h
					map.hex_width = source_hex_width
					map.hex_height = source_hex_height
					DebugPrint(string.format(
						"vanilla cached map/buildable view installed: world %sx%s -> %sx%s; hex %sx%s -> %sx%s; tiles %sx%s -> %sx%s",
						tostring(saved_map_width), tostring(saved_map_height),
						tostring(gen_world_w), tostring(gen_world_h),
						tostring(saved_map_hex_width), tostring(saved_map_hex_height),
						tostring(source_hex_width), tostring(source_hex_height),
						tostring(cur_w_tiles), tostring(cur_h_tiles),
						tostring(gen_width_tiles), tostring(gen_height_tiles)))
					EnrichmentSpreadBoundary(self, map, "cached-map-buildable-source-view-installed", {
						expanded_world = tostring(saved_map_width) .. "x" .. tostring(saved_map_height),
						source_world = tostring(gen_world_w) .. "x" .. tostring(gen_world_h),
						expanded_hex = tostring(saved_map_hex_width) .. "x" .. tostring(saved_map_hex_height),
						source_hex = tostring(source_hex_width) .. "x" .. tostring(source_hex_height),
					})
				else
					DebugPrint(string.format(
						"vanilla cached map/buildable view skipped: source does not fit or is not smaller; world %sx%s -> %sx%s; hex %sx%s -> %sx%s",
						tostring(saved_map_width), tostring(saved_map_height),
						tostring(gen_world_w), tostring(gen_world_h),
						tostring(saved_map_hex_width), tostring(saved_map_hex_height),
						tostring(source_hex_width), tostring(source_hex_height)))
				end
			elseif cfg_bool("QUADRANT_LIMIT_BUILDABLE_GRID_TO_SOURCE", true) then
				DebugPrint(string.format(
					"vanilla cached map/buildable view unavailable: world=%sx%s hex=%sx%s tiles=%sx%s",
					tostring(saved_map_width), tostring(saved_map_height),
					tostring(saved_map_hex_width), tostring(saved_map_hex_height),
					tostring(cur_w_tiles), tostring(cur_h_tiles)))
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
			-- Whole-DoGenerate (mirror-mode) placement begins before OnGenerateLogic can capture
			-- this run's grids. Clear any retry residue so it deliberately uses the safe fallback
			-- rather than stale coverage from an earlier attempt. Stretch mode captures fresh data
			-- before its late PlaceAnomalies transaction.
			map.SuperBigMapRmgGenZoneCoverage = nil
			map.SuperBigMapRmgGenZoneCoverageInfo = nil
			map.SuperBigMapRmgPlayableCoverage = nil
			map.SuperBigMapRmgPlayableCoverageInfo = nil
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
			-- The mod now proves whether native surface ResolveBuildable has already replaced
			-- the provisional grid. That exact grid is reused when current; otherwise a
			-- synchronous correctness fallback rebuild runs before underground generation.
			-- Both paths make the search inputs deterministic: same terrain, same grid, same marker
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
						if main_map.SuperBigMapSurfaceBuildableCurrent == true then
							-- The surface RandomMapGenerator has already completed ResolveBuildable
							-- synchronously, and no surface terrain edit occurs before underground
							-- generation. Reusing that exact grid avoids recomputing identical input.
							DebugPrint("surface buildable grid already authoritative before underground generation; duplicate pairing rebuild skipped")
						else
							local t0 = 0
							local ticks = Global("GetPreciseTicks")
							if type(ticks) == "function" then local okt, t = pcall(ticks); if okt then t0 = t end end
							local ok_rb, err_rb = pcall(rebuild, main_map)
							local t1 = t0
							if type(ticks) == "function" then local okt, t = pcall(ticks); if okt then t1 = t end end
							if ok_rb then main_map.SuperBigMapSurfaceBuildableCurrent = true end
							DebugPrint(string.format(
								"surface buildable grid rebuilt before underground generation (deterministic entrance pairing): ok=%s ms=%s%s",
								tostring(ok_rb), tostring(t1 - t0), ok_rb and "" or (" err=" .. tostring(err_rb))))
						end
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
			local generation_environment = (type(mapdata) == "table" and mapdata.Environment)
				or (type(template) == "table" and template.Environment)
			local is_surface_generation = generation_environment ~= "Underground"

			-- VANILLA HEIGHT-MAP VIEW BRIDGE. Proc_InitPlayZone is the one native generator
			-- path which bypasses every size view above: it grows its terrace height grid from
			-- terrain.HeightMapSize(map), which still exposes the real 8192 backing allocation.
			-- That changes the terrain sampled later by ResolveBuildable even though GetMapSize,
			-- MapData, PassBorder, seed, and rand stream all match a 6144 vanilla run. During the
			-- native source transaction, make this final size read agree with the source view.
			--
			-- A vanilla 6144 SetHeightGrid cannot be allowed to replace the 8192 destination,
			-- so intercept that one write, copy it into the top-left of the existing full grid,
			-- and pass a full-sized options table to the real setter. Both native functions are
			-- restored immediately after DoGenerate, including its error path.
			local height_bridge = false
			local original_terrain_height_map_size = terrain_api and terrain_api.HeightMapSize
			local original_terrain_set_height_grid = terrain_api and terrain_api.SetHeightGrid
			local original_terrain_get_height_grid = terrain_api and terrain_api.GetHeightGrid
			if is_surface_generation and cfg_bool("QUADRANT_BRIDGE_VANILLA_HEIGHT_GRID", true)
				and type(original_terrain_height_map_size) == "function"
				and type(original_terrain_set_height_grid) == "function"
				and type(original_terrain_get_height_grid) == "function"
				and cur_w_tiles > gen_width_tiles and cur_h_tiles > gen_height_tiles then
				local grid_to_compute = Global("GridToCompute")
				local box_fn = Global("box")
				local point_fn = Global("point")
				if type(grid_to_compute) == "function" and type(box_fn) == "function"
					and type(point_fn) == "function" then
					local raw_ok, raw_width, raw_height = pcall(original_terrain_height_map_size, map)
					height_bridge = {
						height_size_calls = 0,
						set_calls = 0,
						bridged_writes = 0,
						raw_width = raw_ok and raw_width or "ERROR",
						raw_height = raw_ok and (raw_height or raw_width) or "ERROR",
					}

					terrain_api.HeightMapSize = function(target)
						if target == map or (target == nil and Global("CurrentMap") == map) then
							height_bridge.height_size_calls = height_bridge.height_size_calls + 1
							return gen_width_tiles, gen_height_tiles
						end
						return original_terrain_height_map_size(target)
					end

					terrain_api.SetHeightGrid = function(target, spec, ...)
						height_bridge.set_calls = height_bridge.set_calls + 1
						if target ~= map and not (target == nil and Global("CurrentMap") == map) then
							return original_terrain_set_height_grid(target, spec, ...)
						end

						local source = type(spec) == "table" and spec.height_grid or spec
						local size_ok, source_width, source_height = pcall(function()
							return source:size()
						end)
						source_height = source_height or source_width
						-- Only the exact Proc_InitPlayZone source-grid write is bridged. Any other
						-- setter call keeps its native semantics and is recorded in the trace.
						if not size_ok or source_width ~= gen_width_tiles or source_height ~= gen_height_tiles then
							EnrichmentSpreadBoundary(self, map, "height-grid-bridge-pass-through", {
								source_width = tostring(source_width), source_height = tostring(source_height),
								size_ok = tostring(size_ok), spec_type = tostring(type(spec)),
							})
							return original_terrain_set_height_grid(target, spec, ...)
						end

						local raw_full, compute_full
						local setter_results
						local setter_extra = PackValues(...)
						local bridge_ok, bridge_err = pcall(function()
							raw_full = original_terrain_get_height_grid(map)
							compute_full = grid_to_compute(raw_full)
							local full_width, full_height = compute_full:size()
							full_height = full_height or full_width
							if type(full_width) ~= "number" or type(full_height) ~= "number"
								or full_width <= source_width or full_height <= source_height then
								error(string.format(
									"expanded height backing unavailable: source=%sx%s backing=%sx%s",
									tostring(source_width), tostring(source_height),
									tostring(full_width), tostring(full_height)))
							end
							compute_full:copyrect(source,
								box_fn(0, 0, source_width, source_height), point_fn(0, 0))

							local bridged_spec = compute_full
							if type(spec) == "table" and spec.height_grid == source then
								bridged_spec = {}
								for key, value in pairs(spec) do bridged_spec[key] = value end
								bridged_spec.height_grid = compute_full
							end
							setter_results = PackValues(original_terrain_set_height_grid(target, bridged_spec,
								Unpack(setter_extra, 1, setter_extra.n)))
							height_bridge.bridged_writes = height_bridge.bridged_writes + 1
							height_bridge.source_width = source_width
							height_bridge.source_height = source_height
							height_bridge.full_width = full_width
							height_bridge.full_height = full_height
						end)
						if compute_full and compute_full ~= raw_full then
							pcall(function() if type(compute_full.free) == "function" then compute_full:free() end end)
						end
						if not bridge_ok then
							height_bridge.error = tostring(bridge_err)
							error("vanilla height-grid bridge failed: " .. tostring(bridge_err))
						end
						EnrichmentSpreadBoundary(self, map, "height-grid-bridge-write", {
							source = tostring(source_width) .. "x" .. tostring(source_height),
							backing = tostring(height_bridge.full_width) .. "x" .. tostring(height_bridge.full_height),
							bridged_writes = tostring(height_bridge.bridged_writes),
						})
						return Unpack(setter_results, 1, setter_results.n)
					end

					DebugPrint(string.format(
						"vanilla height-grid bridge installed: backing=%sx%s source=%sx%s",
						tostring(height_bridge.raw_width), tostring(height_bridge.raw_height),
						tostring(gen_width_tiles), tostring(gen_height_tiles)))
					EnrichmentSpreadBoundary(self, map, "height-grid-bridge-installed", {
						backing_width = tostring(height_bridge.raw_width),
						backing_height = tostring(height_bridge.raw_height),
						source_width = tostring(gen_width_tiles), source_height = tostring(gen_height_tiles),
					})
				else
					DebugPrint("vanilla height-grid bridge skipped: compute/copy API unavailable")
				end
			end
			if is_surface_generation then
				-- ResolveBuildable inside the native generator is the first authoritative build
				-- after the provisional loading-only placeholder. Mark it current only after the
				-- complete native generation transaction succeeds.
				map.SuperBigMapSurfaceBuildableCurrent = false
			end
			State.rmg_placement_active_map = map
			State.rmg_placement_proc_active = false
			State.rmg_placement_proc_stack = {}
			local results = { pcall(original_do_generate, self, map, ...) }
			-- Restore the cached MapVars before any diagnostic or bridge cleanup can run. The
			-- pcall above covers both the successful and failing native-generation paths, so an
			-- engine/Lua failure cannot leave the live expanded map reporting source dimensions.
			if buildable_source_view then
				map.Width = saved_map_width
				map.Height = saved_map_height
				map.hex_width = saved_map_hex_width
				map.hex_height = saved_map_hex_height
			end
			if height_bridge then
				terrain_api.HeightMapSize = original_terrain_height_map_size
				terrain_api.SetHeightGrid = original_terrain_set_height_grid
				DebugPrint(string.format(
					"vanilla height-grid bridge restored: height_size_calls=%s set_calls=%s bridged_writes=%s source=%sx%s backing=%sx%s error=%s",
					tostring(height_bridge.height_size_calls), tostring(height_bridge.set_calls),
					tostring(height_bridge.bridged_writes), tostring(height_bridge.source_width),
					tostring(height_bridge.source_height), tostring(height_bridge.full_width),
					tostring(height_bridge.full_height), tostring(height_bridge.error)))
				EnrichmentSpreadBoundary(self, map, "height-grid-bridge-restored", {
					height_size_calls = tostring(height_bridge.height_size_calls),
					set_calls = tostring(height_bridge.set_calls),
					bridged_writes = tostring(height_bridge.bridged_writes),
					source = tostring(height_bridge.source_width) .. "x" .. tostring(height_bridge.source_height),
					backing = tostring(height_bridge.full_width) .. "x" .. tostring(height_bridge.full_height),
					error = tostring(height_bridge.error),
				})
			end
			if buildable_source_view then
				DebugPrint(string.format(
					"vanilla cached map/buildable view restored after native placement: world %sx%s -> %sx%s; hex %sx%s -> %sx%s; generation_ok=%s",
					tostring(buildable_source_view.source_world_width), tostring(buildable_source_view.source_world_height),
					tostring(saved_map_width), tostring(saved_map_height),
					tostring(buildable_source_view.source_hex_width), tostring(buildable_source_view.source_hex_height),
					tostring(saved_map_hex_width), tostring(saved_map_hex_height),
					tostring(results[1] == true)))
				EnrichmentSpreadBoundary(self, map, "cached-map-buildable-source-view-restored", {
					source_world = tostring(buildable_source_view.source_world_width) .. "x" .. tostring(buildable_source_view.source_world_height),
					expanded_world = tostring(saved_map_width) .. "x" .. tostring(saved_map_height),
					source_hex = tostring(buildable_source_view.source_hex_width) .. "x" .. tostring(buildable_source_view.source_hex_height),
					expanded_hex = tostring(saved_map_hex_width) .. "x" .. tostring(saved_map_hex_height),
					generation_ok = tostring(results[1] == true),
				})
			end
			if next(map.SuperBigMapExpectedResourceCounts or {}) then
				local debug_log = SuperBigMap.DebugLog
				if debug_log then
					debug_log.Info("Generation", "captured RMG resource target floors",
						map.SuperBigMapExpectedResourceCounts)
				end
			end
			-- ProcEnd normally restores the late stretch placement snapshot. If the
			-- generator raised before ProcEnd, restore it here so no preset mutation
			-- can leak into another map generation.
			if State.rmg_placement_proc_active then
				if placement and type(placement.End) == "function" then
					local restore_ok, restore_err = pcall(placement.End, map)
					if restore_ok then
						State.rmg_placement_proc_active = false
					else
						DebugPrint("DoGenerate placement repair rollback ERROR: " .. tostring(restore_err))
						results[1] = false
						results[2] = "placement-property rollback failed: " .. tostring(restore_err)
					end
				end
			end
			State.rmg_placement_active_map = false
			State.rmg_placement_proc_stack = nil
			if results[1] and is_surface_generation and not buildable_source_view
				and map.buildable and map.buildable.z_grid
				and map.SuperBigMapProvisionalBuildableDeferred ~= true then
				map.SuperBigMapSurfaceBuildableCurrent = true
				map.SuperBigMapProvisionalBuildableDeferred = nil
				local debug_log = SuperBigMap.DebugLog
				if debug_log then
					pcall(debug_log.Info, "Bounds", "native surface ResolveBuildable grid is authoritative", {
						map = tostring(map.name or (map.mapdata and map.mapdata.id) or "?"),
						generator_tiles = tostring(gen_width_tiles) .. "x" .. tostring(gen_height_tiles),
					})
				end
			end
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

			-- Native placement deliberately used the source-sized 615x710 buildable grid above.
			-- Enrichments are final now, so replace it with the authoritative expanded 820x946 grid
			-- only after map dimensions and the full-map PassBorder have been restored. This rebuild
			-- cannot influence the already-completed vanilla candidate/repulsion transaction.
			if results[1] and is_surface_generation and buildable_source_view then
				local rebuild = Global("RebuildBuildableGrid")
				local ticks = Global("GetPreciseTicks")
				local t0 = 0
				if type(ticks) == "function" then
					local ok_ticks, value = pcall(ticks)
					if ok_ticks and type(value) == "number" then t0 = value end
				end
				local rebuild_ok, rebuild_err = false, "RebuildBuildableGrid unavailable"
				if type(rebuild) == "function" then
					rebuild_ok, rebuild_err = pcall(rebuild, map)
				end
				local t1 = t0
				if type(ticks) == "function" then
					local ok_ticks, value = pcall(ticks)
					if ok_ticks and type(value) == "number" then t1 = value end
				end
				local final_grid_w, final_grid_h = "nil", "nil"
				if rebuild_ok and map.buildable and map.buildable.z_grid then
					local ok_size, width, height = pcall(function() return map.buildable.z_grid:size() end)
					if ok_size then final_grid_w, final_grid_h = width, height or width end
					map.SuperBigMapSurfaceBuildableCurrent = true
					map.SuperBigMapProvisionalBuildableDeferred = nil
				else
					results[1] = false
					results[2] = "expanded buildable-grid rebuild failed: " .. tostring(rebuild_err)
				end
				DebugPrint(string.format(
					"expanded buildable grid rebuilt after native placement: ok=%s grid=%sx%s expected=%sx%s ms=%s%s",
					tostring(rebuild_ok), tostring(final_grid_w), tostring(final_grid_h),
					tostring(saved_map_hex_width), tostring(saved_map_hex_height), tostring(t1 - t0),
					rebuild_ok and "" or (" err=" .. tostring(rebuild_err))))
				EnrichmentSpreadBoundary(self, map, "expanded-buildable-grid-rebuilt-after-native-placement", {
					ok = tostring(rebuild_ok), grid = tostring(final_grid_w) .. "x" .. tostring(final_grid_h),
					expected = tostring(saved_map_hex_width) .. "x" .. tostring(saved_map_hex_height),
					ms = tostring(t1 - t0), error = rebuild_ok and "none" or tostring(rebuild_err),
				})
			end
			EnrichmentSpreadBoundary(self, map, "expansion-DoGenerate-after-source-view-restored")

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
			CaptureGeneratedNativeEnrichments(map, "DoGenerate expanded source complete")
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
	map = map or Global("CurrentMap")
	if not cfg_bool("SECTOR_MIRROR_PLAN_AT_START", false) then
		return false
	end
	if not map then
		return false
	end
	if map.SuperBigMapSectorMirrorDone == true then
		return false
	end
	-- Report an existing live schedule as success so the lifecycle caller does not run its
	-- fallback full-map rebuild in parallel with the expansion transaction.
	if map.SuperBigMapSectorMirrorScheduled == true then return true end
	local create_thread = Global("CreateRealTimeThread")
	local sleep = Global("Sleep")
	local yield_protected_call = Global("sprocall")
	if type(create_thread) ~= "function" or type(sleep) ~= "function"
		or type(yield_protected_call) ~= "function" then
		return false
	end
	map.SuperBigMapSectorMirrorScheduled = true
	-- STRETCH loads fast (grid resample, no sector-by-sector work), so it does not need the long
	-- mirror-plan settle -- use a short stretch-specific settle to cut several seconds off the load.
	local fill_mode_early = cfg_string("EXPANSION_FRAME_FILL_MODE", "mirror")
	local settle_ms = math.max(0, cfg_number("MIRROR_PLAN_SETTLE_MS", 5000))
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
	local schedule_ok, schedule_err = pcall(create_thread, function()
		-- Protect the entire asynchronous pipeline, not only its central stretch block, so
		-- readiness/setup errors take the normal full-rebuild fallback.
		local thread_ok, thread_err = yield_protected_call(function()
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
		local f0_detail_token = InvestigationBegin("surface readiness: F0 polling window", map, {
			max_wait_ms = 15000,
		})
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
		InvestigationEnd(f0_detail_token, {
			requested_wait_ms = waited,
			f0_found = FindSectorByName(map, "F0") ~= nil,
		}, true)
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
			local settle_detail_token = InvestigationBegin("surface readiness: fixed settle scheduling span", map, {
				configured_ms = settle_ms,
			})
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
			InvestigationEnd(settle_detail_token, { configured_ms = settle_ms }, true)
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
			-- One transaction owns the frame overlay plus both mass-object moves. ForceFramePassable,
			-- ScaleDecorationsToFull, and ScaleMarkersToFull otherwise each balance their own
			-- Suspend/Resume pair; those early resumes flush passability repeatedly even though the
			-- stretch already performs the authoritative RebuildGrids. Resume at the same logical
			-- boundary as the old marker pass (before later passability queries), and repeat the call
			-- after the protected branch as an error-path no-op so suspension is always balanced.
			local pass_batch_reason = "SuperBigMapSurfaceStretch"
			local pass_batch_active = false
			if cfg_bool("OPTIMIZE_STRETCH_PASSABILITY", true)
				and type(map.SuspendPassEdits) == "function" and type(map.ResumePassEdits) == "function" then
				local suspend_ok, suspend_result = pcall(map.SuspendPassEdits, map, pass_batch_reason)
				pass_batch_active = suspend_ok and suspend_result ~= false
				StretchLog("stretch branch: combined pass-edit transaction begin", {
					active = pass_batch_active, error = suspend_ok and nil or tostring(suspend_result),
				})
			end
			local function ResumeCombinedPassEdits(source)
				if not pass_batch_active then return true end
				-- Clear first so an engine exception cannot cause a second, unbalanced resume attempt.
				pass_batch_active = false
				local detail_token = InvestigationBegin(
					"surface: resume combined stretch passability edits", map, { source = source })
				local resume_ok, resume_err = pcall(map.ResumePassEdits, map, pass_batch_reason)
				InvestigationEnd(detail_token, {
					source = source, error = resume_ok and nil or tostring(resume_err),
				}, resume_ok)
				StretchLog("stretch branch: combined pass-edit transaction end", {
					source = source, ok = resume_ok, error = resume_ok and nil or tostring(resume_err),
				})
				return resume_ok
			end
			local ok_branch, branch_err = pcall(function()
				if type(StretchSourceToFull) == "function" then
					-- Relief annotations MUST be captured BEFORE the terrain stretch (they record
					-- each object's relationship to the PRE-stretch ground).
					if type(AnnotateDecorRelief) == "function" then
						StretchLog("stretch branch: -> AnnotateDecorRelief")
						local detail_token = InvestigationBegin("surface: annotate decoration relief", map)
						AnnotateDecorRelief(map)
						InvestigationEnd(detail_token, nil, true)
					end
					if cfg_bool("OPTIMIZE_STRETCH_PASSABILITY", true) then
						StretchLog("stretch branch: pre-applying frame passability before authoritative revalidation")
						local pass_token = loading_profiler and type(loading_profiler.Begin) == "function"
							and loading_profiler.Begin("surface passability: preapply frame overlay", nil, map) or false
						frame_passability_preapplied = InvestigationSafeCall(
							"surface: preapply frame passability", map, ForceFramePassable,
							map, true, pass_batch_active) == true
						if pass_token and type(loading_profiler.End) == "function" then
							loading_profiler.End(pass_token, {
								applied = frame_passability_preapplied,
							}, frame_passability_preapplied)
						end
					end
					local spike_token = InvestigationBegin("surface: spike audit pre-stretch", map)
					SpikeAudit(map, "surface pre-stretch")
					InvestigationEnd(spike_token, nil, true)
					local position_deposits = SuperBigMap.DepositRules
					if position_deposits
						and type(position_deposits.LogEnrichmentPositionCensus) == "function" then
						StretchLog("stretch branch: -> enrichment position census BEFORE stretch")
						InvestigationSafeCall("surface enrichment positions: before stretch", map,
							position_deposits.LogEnrichmentPositionCensus,
							map, "surface before stretch", true)
					end
					SetLoadingPhase("Stretching the surface terrain")
					if cfg_bool("EXPANSION_STEP_07_STRETCH_TERRAIN", true) then
						StretchLog("stretch branch: -> StretchSourceToFull")
						local terrain_token = InvestigationBegin("surface: stretch all terrain grids", map)
						-- The next call mutates terrain heights, so the native source-grid buildability
						-- snapshot is no longer current until the explicit final rebuild below succeeds.
						map.SuperBigMapSurfaceBuildableCurrent = false
						ok_stretch, n_grids = StretchSourceToFull(map, false)
						InvestigationEnd(terrain_token, { ok = ok_stretch, grids = n_grids }, ok_stretch == true)
						StretchLog("stretch branch: StretchSourceToFull returned", { ok = ok_stretch, grids = n_grids })
						spike_token = InvestigationBegin("surface: spike audit post-terrain", map)
						SpikeAudit(map, "surface post-StretchSourceToFull")
						InvestigationEnd(spike_token, nil, true)
					else
						ok_stretch, n_grids = true, 0
						StretchLog("stretch branch: terrain stretch skipped (expansion step 07 disabled)")
					end
				else
					StretchLog("stretch branch: StretchSourceToFull MISSING")
					DebugPrint("RunSectorMirrorPlanIfEnabled: STRETCH unavailable (TerrainCopy.StretchSourceToFull missing) -- terrain left as generated")
				end
				-- Step 2: reposition + scale the generated decorations onto the stretched terrain
				-- (must run AFTER the height stretch so SetTerrainZ reads the new surface).
				if type(ScaleDecorationsToFull) == "function" then
					SetLoadingPhase("Repositioning surface rocks and decorations")
					StretchLog("stretch branch: -> ScaleDecorationsToFull")
					local detail_token = InvestigationBegin("surface: reposition and top up decorations", map)
					local n_dec = ScaleDecorationsToFull(map, false, pass_batch_active)
					InvestigationEnd(detail_token, { moved = n_dec }, true)
					StretchLog("stretch branch: ScaleDecorationsToFull returned", { moved = n_dec })
					local spike_token = InvestigationBegin("surface: spike audit post-decorations", map)
					SpikeAudit(map, "surface post-ScaleDecorations")
					InvestigationEnd(spike_token, nil, true)
				end
				-- Step 3: move the deposit/anomaly/effect markers to their scaled spots too
				-- (config STRETCH_SCALE_MARKERS) -- same transform, positions only.
				if type(ScaleMarkersToFull) == "function" then
					SetLoadingPhase("Repositioning surface resource deposits")
					StretchLog("stretch branch: -> ScaleMarkersToFull")
					local detail_token = InvestigationBegin("surface: reposition enrichment markers", map)
					local n_mark = ScaleMarkersToFull(map, false, pass_batch_active)
					InvestigationEnd(detail_token, { moved = n_mark }, true)
					StretchLog("stretch branch: ScaleMarkersToFull returned", { moved = n_mark })
					EntranceSnapshot("surface after ScaleMarkersToFull", map)
					local position_deposits = SuperBigMap.DepositRules
					if position_deposits
						and type(position_deposits.LogEnrichmentPositionCensus) == "function" then
						StretchLog("stretch branch: -> enrichment position census AFTER stretch")
						InvestigationSafeCall("surface enrichment positions: after stretch", map,
							position_deposits.LogEnrichmentPositionCensus,
							map, "surface after marker stretch before topups", false)
					end
					if position_deposits
						and type(position_deposits.VerifyNativeEnrichmentTransform) == "function" then
						StretchLog("stretch branch: -> VerifyNativeEnrichmentTransform")
						local verified, verify_stats = position_deposits.VerifyNativeEnrichmentTransform(
							map, "surface after marker transform")
						if verified ~= true then
							error("native surface enrichment transformation verification failed (mismatches="
								.. tostring(verify_stats and verify_stats.mismatches or "unknown") .. ")")
						end
					end
				end
				ResumeCombinedPassEdits("after surface marker movement")
				-- Step 3b: move the entrance VISUALS (signs/structures/spawners -- skipped by the
				-- decor pass) with the same transform, so what the player SEES matches the markers.
				if type(MoveEntranceVisualsToScale) == "function" then
					SetLoadingPhase("Aligning the underground entrances")
					StretchLog("stretch branch: -> MoveEntranceVisualsToScale")
					local detail_token = InvestigationBegin("surface: align entrance visuals", map)
					local n_vis = MoveEntranceVisualsToScale(map)
					InvestigationEnd(detail_token, { moved = n_vis }, true)
					StretchLog("stretch branch: MoveEntranceVisualsToScale returned", { moved = n_vis })
					EntranceSnapshot("surface after MoveEntranceVisualsToScale", map)
					local spike_token = InvestigationBegin("surface: spike audit post-entrances", map)
					SpikeAudit(map, "surface post-MoveEntranceVisuals")
					InvestigationEnd(spike_token, nil, true)
				end
				-- Step 3c: FLOATER AUDIT -- objects hovering above the stretched terrain (e.g.
				-- decor-pass-skipped rocks that kept their old Z over now-lower ground). Logs
				-- class/dz/skip-verdict per floater under the Align scope; snaps non-Building
				-- floaters down when STRETCH_RESNAP_FLOATERS is on.
				if type(AuditFloatingObjects) == "function" then
					StretchLog("stretch branch: -> AuditFloatingObjects (early)")
					local detail_token = InvestigationBegin("surface: floating-object audit early", map)
					local n_float = AuditFloatingObjects(map, "early")
					InvestigationEnd(detail_token, { floaters = n_float }, true)
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
						local n_rev = InvestigationSafeCall("surface: reveal vanilla start sector", map,
							sectors_mod.RevealVanillaStartSectors, map)
						StretchLog("stretch branch: RevealVanillaStartSectors returned", { scanned = n_rev })
					end
				elseif type(StretchRelocateStartSector) == "function" then
					StretchLog("stretch branch: -> StretchRelocateStartSector")
					local detail_token = InvestigationBegin("surface: relocate start sector", map)
					local n_rel = StretchRelocateStartSector(map)
					InvestigationEnd(detail_token, { relocated = n_rel }, true)
					StretchLog("stretch branch: StretchRelocateStartSector returned", { relocated = n_rel })
				end
				-- Step 5: re-enforce scan-gating after the move (hide revealed enrichments that
				-- landed in unscanned sectors; place/reveal what moved into scanned ones).
				do
					local deposits = SuperBigMap.DepositRules
					if deposits and type(deposits.EnforceScanGateAfterStretch) == "function" then
						StretchLog("stretch branch: -> EnforceScanGateAfterStretch")
						InvestigationSafeCall("surface: enforce scan gate", map,
							deposits.EnforceScanGateAfterStretch, map)
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
							InvestigationSafeCall("surface enrichment: top up resource deposits", map,
								deposits.TopUpDeposits, map)
						end
						-- TopUpAnomalies: post-gen replacement for the in-generation anomaly count
						-- scaling (which shifted the generator's random stream and made expanded
						-- layouts diverge from vanilla). BEFORE RespaceAnomalies so clones get
						-- spaced too.
						if type(deposits.TopUpAnomalies) == "function" then
							StretchLog("stretch branch: -> TopUpAnomalies")
							InvestigationSafeCall("surface enrichment: top up anomalies", map,
								deposits.TopUpAnomalies, map)
						end
						if type(deposits.TopUpEffectDeposits) == "function" then
							StretchLog("stretch branch: -> TopUpEffectDeposits")
							InvestigationSafeCall("surface enrichment: top up effect markers", map,
								deposits.TopUpEffectDeposits, map)
						end
						if type(deposits.RegisterClonedMarkers) == "function" then
							StretchLog("stretch branch: -> RegisterClonedMarkers")
							InvestigationSafeCall("surface enrichment: register cloned markers", map,
								deposits.RegisterClonedMarkers, map)
						end
						if type(deposits.RespaceAnomalies) == "function" then
							StretchLog("stretch branch: -> RespaceAnomalies")
							InvestigationSafeCall("surface enrichment: respace anomalies", map,
								deposits.RespaceAnomalies, map)
						end
						if type(deposits.EvenOutDepositDensity) == "function" then
							StretchLog("stretch branch: -> EvenOutDepositDensity")
							InvestigationSafeCall("surface enrichment: even deposit density", map,
								deposits.EvenOutDepositDensity, map)
						end
						if type(deposits.ResolveBadgeMarkerOverlaps) == "function" then
							StretchLog("stretch branch: -> ResolveBadgeMarkerOverlaps")
							InvestigationSafeCall("surface enrichment: resolve badge overlaps", map,
								deposits.ResolveBadgeMarkerOverlaps, map, "surface density suite")
						end
						if type(deposits.RepairBreakthroughAnomalies) == "function" then
							StretchLog("stretch branch: -> RepairBreakthroughAnomalies")
							InvestigationSafeCall("surface enrichment: repair breakthrough selection", map,
								deposits.RepairBreakthroughAnomalies, map)
						end
						if type(deposits.LogEnrichmentPositionCensus) == "function" then
							StretchLog("stretch branch: -> final enrichment position census")
							InvestigationSafeCall("surface enrichment positions: final after density suite", map,
								deposits.LogEnrichmentPositionCensus,
								map, "surface final after topups and breakthroughs", false)
						end
						if type(deposits.AuditSurfaceTopUpRingExclusivity) == "function" then
							StretchLog("stretch branch: -> AuditSurfaceTopUpRingExclusivity")
							InvestigationSafeCall("surface enrichment: audit outer-ring exclusivity", map,
								deposits.AuditSurfaceTopUpRingExclusivity, map)
						end
						if type(deposits.LogDistributionReport) == "function" then
							InvestigationSafeCall("surface enrichment: distribution report", map,
								deposits.LogDistributionReport, map, "stretch after density suite")
						end
						if type(deposits.ClearTopUpPlacementPool) == "function" then
							local detail_token = InvestigationBegin("surface enrichment: clear placement pool", map)
							deposits.ClearTopUpPlacementPool(map)
							InvestigationEnd(detail_token, nil, true)
						end
					end
				end
				local function now2()
					if type(stretch_ticks) == "function" then local ok, t = pcall(stretch_ticks); if ok and type(t) == "number" then return t end end
					return 0
				end
				local ft = now2()
				local spike_token = InvestigationBegin("surface: spike audit post-density", map)
				SpikeAudit(map, "surface post-density-suite")
				InvestigationEnd(spike_token, nil, true)
				if cfg_bool("EXPANSION_STEP_11_REBUILD_GAMEPLAY_GRIDS", true) then
				SetLoadingPhase("Rebuilding the surface build grid")
				StretchLog("stretch branch: -> RebuildBuildableGrid")
				local rebuild_buildable = Global("RebuildBuildableGrid")
				-- map:RebuildGrids may return immediately after scheduling work; pcall success does NOT
				-- prove the buildable z-grid was synchronously rebuilt. The stale-grid regression produced
				-- landing pillars when this explicit pass was skipped, so correctness requires this one
				-- authoritative synchronous rebuild after all terrain-height edits.
				if type(rebuild_buildable) == "function" and map and map.buildable then
					local rebuild_token = InvestigationBegin("surface: rebuild buildable grid", map)
					local rebuild_ok, rebuild_err = pcall(rebuild_buildable, map)
					InvestigationEnd(rebuild_token, {
						ok = tostring(rebuild_ok), error = rebuild_ok and "" or tostring(rebuild_err),
					}, rebuild_ok)
					local debug_log = SuperBigMap.DebugLog
					if debug_log then
						debug_log.Info("RocketTerrain", "explicit final surface buildable-grid rebuild", {
							map = tostring(map.name or (map.mapdata and map.mapdata.id) or "?"),
							consolidated_flag = tostring(map.SuperBigMapRevalidationRebuiltGrids),
							ok = tostring(rebuild_ok), error = rebuild_ok and "" or tostring(rebuild_err),
						})
					end
					if not rebuild_ok then
						error("final surface RebuildBuildableGrid failed: " .. tostring(rebuild_err))
					end
					map.SuperBigMapSurfaceBuildableCurrent = true
				else
					error("final surface RebuildBuildableGrid unavailable")
				end
				StretchLog("TIMING: RebuildBuildableGrid", { ms = now2() - ft }); ft = now2()
				local passability_already_baked = cfg_bool("OPTIMIZE_STRETCH_PASSABILITY", true)
					and frame_passability_preapplied and ok_stretch
				if passability_already_baked then
					StretchLog("stretch branch: frame passability already applied before authoritative revalidation -- skip duplicate")
				else
					StretchLog("stretch branch: -> ForceFramePassable")
					InvestigationSafeCall("surface: final frame passability", map, ForceFramePassable,
						map, cfg_bool("OPTIMIZE_STRETCH_PASSABILITY", true))
				end
				StretchLog("TIMING: ForceFramePassable", { ms = now2() - ft }); ft = now2()
				else
					StretchLog("stretch branch: gameplay-grid rebuild skipped (expansion step 11 disabled)")
				end
				-- LATE + POST floater audits: catch floaters created AFTER the early audit --
				-- suspects: ForceFramePassable just above, or vanilla post-load passes (the early
				-- audit found only 7 small floaters yet big rocks still hovered on screen).
				if type(AuditFloatingObjects) == "function" then
					local detail_token = InvestigationBegin("surface: floating-object audit late", map)
					local late_floaters = AuditFloatingObjects(map, "late")
					InvestigationEnd(detail_token, { floaters = late_floaters }, true)
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
					InvestigationSafeCall("surface: resnap rockets", map, rockets.ResnapRocketsOnMap, map)
				end
				StretchLog("TIMING: ResnapRocketsOnMap", { ms = now2() - ft })
				StretchLog("stretch branch: finalize steps done")
			end)
			-- Error-path cleanup. On the normal path the transaction was already resumed above.
			ResumeCombinedPassEdits("surface stretch cleanup")
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
			if type(deposits.ResolveBadgeMarkerOverlaps) == "function" then
				SafeCall(deposits.ResolveBadgeMarkerOverlaps, map, "mirror density suite")
			end
			if type(deposits.RepairBreakthroughAnomalies) == "function" then
				SafeCall(deposits.RepairBreakthroughAnomalies, map)
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
		if not thread_ok then
			if map.SuperBigMapStretchPipelinePending == true then
				local lifecycle = SuperBigMap.Lifecycle
				if lifecycle and type(lifecycle.Apply) == "function" then
					SafeCall(lifecycle.Apply, map, true)
				end
			end
			map.SuperBigMapStretchPipelinePending = false
			map.SuperBigMapSectorMirrorScheduled = false
			DebugPrint("RunSectorMirrorPlanIfEnabled: expansion thread ERROR: " .. tostring(thread_err))
			if type(SuperBigMap.ExpansionLoadingEnd) == "function" then
				pcall(SuperBigMap.ExpansionLoadingEnd)
			end
		end
	end)
	if not schedule_ok then
		map.SuperBigMapStretchPipelinePending = false
		map.SuperBigMapSectorMirrorScheduled = false
		DebugPrint("RunSectorMirrorPlanIfEnabled: scheduling ERROR: " .. tostring(schedule_err))
	end
	return schedule_ok == true
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
	UndergroundAccessLog("preparation function entered", UndergroundAccessState(map, {
		force_now = tostring(force_now),
	}))
	if not cfg_bool("STRETCH_UNDERGROUND", false) then
		UndergroundAccessLog("preparation rejected: underground stretch disabled", UndergroundAccessState(map), "warn")
		return false, "underground stretch is disabled"
	end
	map = map or Global("CurrentMap")
	if not map then
		UndergroundAccessLog("preparation rejected: target map missing", UndergroundAccessState(map), "error")
		return false, "underground target map is missing"
	end
	local restored_geometry = RestoreDeferredUndergroundGeometry(map)
	UndergroundAccessLog("deferred geometry restore checked", UndergroundAccessState(map, {
		restored_geometry = tostring(restored_geometry),
	}))
	if map.SuperBigMapUndergroundPrepared == true then
		map.SuperBigMapUndergroundStretchDone = true
		map.SuperBigMapUndergroundStretchPending = false
		UndergroundAccessLog("prepared flag normalized to done", UndergroundAccessState(map))
	end
	if map.SuperBigMapUndergroundStretchDone == true then
		UndergroundAccessLog("preparation skipped: already complete", UndergroundAccessState(map, {
			force_result = tostring(force_now == true),
		}))
		return force_now == true and true or false
	end
	if map.SuperBigMapUndergroundPreparationFailed == true then
		UndergroundAccessLog("preparation rejected: previous attempt failed", UndergroundAccessState(map), "error")
		return false, map.SuperBigMapUndergroundStretchFailed
			or "a previous underground preparation attempt failed"
	end
	if map.SuperBigMapUndergroundStretchRunning == true then
		UndergroundAccessLog("preparation rejected: another run is active", UndergroundAccessState(map), "warn")
		if force_now == true then
			return false, "underground expansion already running"
		end
		return true, "underground expansion already running"
	end
	local desired = map.SuperBigMapDesiredWidthTiles
	local gen_t = map.SuperBigMapGeneratorWidthTiles
	if not (type(desired) == "number" and type(gen_t) == "number" and desired > gen_t) then
		UndergroundAccessLog("preparation rejected: target geometry is not expandable", UndergroundAccessState(map), "error")
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
		UndergroundAccessLog("preparation deferred until first access", UndergroundAccessState(map))
		StretchLog("underground stretch: deferred until first access", {
			desired = desired, generator = gen_t, map = tostring(map.name),
		})
		return true
	end
	local create_thread = Global("CreateRealTimeThread")
	local sleep = Global("Sleep")
	if force_now ~= true and (type(create_thread) ~= "function" or type(sleep) ~= "function") then
		UndergroundAccessLog("preparation rejected: asynchronous engine functions unavailable", UndergroundAccessState(map, {
			create_thread = tostring(create_thread), sleep = tostring(sleep),
		}), "error")
		return false, "required asynchronous engine functions are unavailable"
	end
	map.SuperBigMapUndergroundStretchPending = true
	map.SuperBigMapUndergroundStretchRunning = true
	map.SuperBigMapUndergroundStretchFailed = nil
	UndergroundAccessLog("preparation state changed to running", UndergroundAccessState(map, {
		force_now = tostring(force_now),
	}))
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
		UndergroundAccessLog("complete deferred pipeline started", UndergroundAccessState(map, {
			force_now = tostring(force_now), settle_ms = tostring(settle_ms),
		}))
		local loading_profiler = SuperBigMap.LoadingProfiler
		local settle_token = loading_profiler and type(loading_profiler.Begin) == "function"
			and loading_profiler.Begin("underground readiness: fixed settle", { settle_ms = settle_ms }, map) or false
		local settle_detail_token = InvestigationBegin("underground readiness: fixed settle scheduling span", map, {
			configured_ms = settle_ms,
		})
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
		InvestigationEnd(settle_detail_token, { configured_ms = settle_ms }, true)
		local pause_ild = Global("PauseInfiniteLoopDetection")
		local resume_ild = Global("ResumeInfiniteLoopDetection")
		if type(pause_ild) == "function" then SafeCall(pause_ild, "SuperBigMapUndergroundStretch") end
		local stretch_token = loading_profiler and type(loading_profiler.Begin) == "function"
			and loading_profiler.Begin("underground expansion: complete stretch pipeline", {
				settle_ms = settle_ms, desired_tiles = desired, generator_tiles = gen_t,
			}, map) or false
		local elevator_migrations = {}
		local ok_branch, branch_err = pcall(function()
			EntranceSnapshot("underground stretch begin", map)
			-- A surface Elevator may already be finished while its paired underground half is a
			-- pending site with a destroyed linked_obj. Snapshot/remove only that underground half
			-- before any position sweep; rebuild it after the final buildable grid exists.
			if type(BeginDeferredElevatorMigration) ~= "function"
				or type(RestoreDeferredElevatorMigration) ~= "function" then
				error("deferred Elevator migration helpers are unavailable")
			end
			local elevator_token = InvestigationBegin("underground: snapshot and remove deferred elevators", map)
			elevator_migrations = BeginDeferredElevatorMigration(map)
			InvestigationEnd(elevator_token, {
				migrations = type(elevator_migrations) == "table" and #elevator_migrations or 0,
			}, true)
			StretchLog("underground stretch: deferred Elevator annotation complete", {
				migrations = type(elevator_migrations) == "table" and #elevator_migrations or 0,
			})
			-- Renderer bounds must cover the full 8192 grid (same fix as the surface).
			InvestigationSafeCall("underground: synchronize mapdata to grids", map, SyncMapDataToGrids, map)
			local spike_token = InvestigationBegin("underground: spike audit pre-stretch", map)
			SpikeAudit(map, "underground pre-stretch")
			InvestigationEnd(spike_token, nil, true)
			-- Relief annotations BEFORE the underground terrain stretch (same as the surface).
			if type(AnnotateDecorRelief) == "function" then
				StretchLog("underground stretch: -> AnnotateDecorRelief")
				local detail_token = InvestigationBegin("underground: annotate decoration relief", map)
				AnnotateDecorRelief(map)
				InvestigationEnd(detail_token, nil, true)
			end
			local position_deposits = SuperBigMap.DepositRules
			if position_deposits
				and type(position_deposits.LogEnrichmentPositionCensus) == "function" then
				StretchLog("underground stretch: -> enrichment position census BEFORE stretch")
				InvestigationSafeCall("underground enrichment positions: before stretch", map,
					position_deposits.LogEnrichmentPositionCensus,
					map, "underground before stretch", true)
			end
			SetLoadingPhase("Stretching the underground terrain")
			local ok_s, n_grids = true, 0
			if cfg_bool("EXPANSION_STEP_07_STRETCH_TERRAIN", true) then
				StretchLog("underground stretch: -> StretchSourceToFull")
				local terrain_token = InvestigationBegin("underground: stretch all terrain grids", map)
				ok_s, n_grids = StretchSourceToFull(map, false)
				InvestigationEnd(terrain_token, { ok = ok_s, grids = n_grids }, ok_s == true)
				StretchLog("underground stretch: grids done", { ok = ok_s, grids = n_grids })
				if ok_s ~= true or type(n_grids) ~= "number" or n_grids < 2 then
					error("underground terrain stretch did not complete its height/type grids")
				end
			else
				StretchLog("underground stretch: terrain stretch skipped (expansion step 07 disabled)")
			end
			spike_token = InvestigationBegin("underground: spike audit post-terrain", map)
			SpikeAudit(map, "underground post-StretchSourceToFull")
			InvestigationEnd(spike_token, nil, true)
			if type(ScaleDecorationsToFull) == "function" then
				SetLoadingPhase("Repositioning underground rocks and decorations")
				StretchLog("underground stretch: -> ScaleDecorationsToFull")
				local detail_token = InvestigationBegin("underground: reposition and top up decorations", map)
				local n_dec = ScaleDecorationsToFull(map, false)
				InvestigationEnd(detail_token, { moved = n_dec }, true)
				StretchLog("underground stretch: decorations done", { moved = n_dec })
			end
			if type(ScaleMarkersToFull) == "function" then
				SetLoadingPhase("Repositioning underground resource deposits")
				StretchLog("underground stretch: -> ScaleMarkersToFull")
				local detail_token = InvestigationBegin("underground: reposition enrichment markers", map)
				local n_mark = ScaleMarkersToFull(map, false)
				InvestigationEnd(detail_token, { moved = n_mark }, true)
				StretchLog("underground stretch: markers done", { moved = n_mark })
				EntranceSnapshot("underground after ScaleMarkersToFull", map)
				local position_deposits = SuperBigMap.DepositRules
				if position_deposits
					and type(position_deposits.LogEnrichmentPositionCensus) == "function" then
					StretchLog("underground stretch: -> enrichment position census AFTER stretch")
					InvestigationSafeCall("underground enrichment positions: after stretch", map,
						position_deposits.LogEnrichmentPositionCensus,
						map, "underground after marker stretch before topups", false)
				end
				if position_deposits
					and type(position_deposits.VerifyNativeEnrichmentTransform) == "function" then
					StretchLog("underground stretch: -> VerifyNativeEnrichmentTransform")
					local verified, verify_stats = position_deposits.VerifyNativeEnrichmentTransform(
						map, "underground after marker transform")
					if verified ~= true then
						error("native underground enrichment transformation verification failed (mismatches="
							.. tostring(verify_stats and verify_stats.mismatches or "unknown") .. ")")
					end
				end
			end
			-- Entrance VISUALS follow their markers (same transform; see surface step 3b).
			if type(MoveEntranceVisualsToScale) == "function" then
				StretchLog("underground stretch: -> MoveEntranceVisualsToScale")
				local detail_token = InvestigationBegin("underground: align entrance visuals", map)
				local n_vis = MoveEntranceVisualsToScale(map)
				InvestigationEnd(detail_token, { moved = n_vis }, true)
				StretchLog("underground stretch: entrance visuals done", { moved = n_vis })
				EntranceSnapshot("underground after MoveEntranceVisualsToScale", map)
			end
			spike_token = InvestigationBegin("underground: spike audit post-entrances", map)
			SpikeAudit(map, "underground post-MoveEntranceVisuals")
			InvestigationEnd(spike_token, nil, true)
			-- Natural entrance objects still receive exactly one transformation (the stretch).
			-- The one exception is an Elevator already completed on the surface: its removed
			-- pending underground half is rebuilt later on its live underground passage/imprint.
			-- FINAL GRIDS FIRST. The consolidated terrain revalidation can report success on a
			-- non-current underground map before the Lua BuildableGrid has completed. v480 then
			-- sampled its stale pre-stretch grid and the authoritative rebuild happened only after
			-- CurrentMapChangeDone -- too late. Correctness wins here: synchronously rebuild final
			-- passability and buildability, invalidate every cached pool, and seed connectivity from
			-- the real underground entrances before any enrichment is accepted or moved.
			if cfg_bool("EXPANSION_STEP_11_REBUILD_GAMEPLAY_GRIDS", true) then
				SetLoadingPhase("Finalizing reachable underground terrain")
				local terrain_api2 = Global("terrain")
				if not (type(terrain_api2) == "table" and type(terrain_api2.RebuildPassability) == "function") then
					error("underground final passability rebuild is unavailable")
				end
				StretchLog("underground stretch: -> final RebuildPassability")
				local pass_token = InvestigationBegin("underground: final passability rebuild", map)
				local pass_ok, pass_err = pcall(terrain_api2.RebuildPassability, map)
				InvestigationEnd(pass_token, { error = pass_ok and nil or tostring(pass_err) }, pass_ok)
				if not pass_ok then error("underground final passability rebuild failed: " .. tostring(pass_err)) end
				local rebuild_buildable = Global("RebuildBuildableGrid")
				if type(rebuild_buildable) ~= "function" then
					error("underground final buildable-grid rebuild is unavailable")
				end
				SetLoadingPhase("Rebuilding the final underground build grid")
				StretchLog("underground stretch: -> final RebuildBuildableGrid")
				local build_token = InvestigationBegin("underground: final buildable-grid rebuild", map)
				local build_ok, build_err = pcall(rebuild_buildable, map)
				InvestigationEnd(build_token, { error = build_ok and nil or tostring(build_err) }, build_ok)
				if not build_ok then error("underground final buildable-grid rebuild failed: " .. tostring(build_err)) end
				map.SuperBigMapRevalidationRebuiltGrids = true
				if #elevator_migrations > 0 then
					SetLoadingPhase("Rebuilding underground Elevator counterparts")
					StretchLog("underground stretch: -> RestoreDeferredElevatorMigration", {
						migrations = #elevator_migrations,
					})
					local detail_token = InvestigationBegin("underground: restore deferred elevators", map, {
						migrations = #elevator_migrations,
					})
					local rebuilt = RestoreDeferredElevatorMigration(map, elevator_migrations, "post-buildable-grid")
					InvestigationEnd(detail_token, { rebuilt = rebuilt }, rebuilt == #elevator_migrations)
					if rebuilt ~= #elevator_migrations then
						error("deferred Elevator migration rebuilt " .. tostring(rebuilt)
							.. "/" .. tostring(#elevator_migrations) .. " counterparts")
					end
				end
				local deposits = SuperBigMap.DepositRules
				if not deposits then error("underground deposit rules are unavailable") end
				if type(deposits.ClearTopUpPlacementPool) == "function" then
					local detail_token = InvestigationBegin("underground enrichment: clear pre-suite placement pool", map)
					deposits.ClearTopUpPlacementPool(map)
					InvestigationEnd(detail_token, nil, true)
				end
				if type(deposits.PrepareUndergroundReachability) ~= "function" then
					error("underground entrance-reachability preparation is unavailable")
				end
				StretchLog("underground stretch: -> PrepareUndergroundReachability")
				local reach_token = InvestigationBegin("underground enrichment: prepare reachability", map)
				local reach_ok, reach_state = deposits.PrepareUndergroundReachability(map)
				InvestigationEnd(reach_token, {
					seeds = reach_state and type(reach_state.seeds) == "table" and #reach_state.seeds or 0,
				}, reach_ok == true)
				if reach_ok ~= true then
					error("underground entrance connectivity could not be initialized (seeds="
						.. tostring(reach_state and #reach_state.seeds or 0) .. ")")
				end
			else
				StretchLog("underground stretch: gameplay-grid rebuild skipped (expansion step 11 disabled)")
			end
			-- DENSITY NORMALIZATION (same suite as the surface stretch branch): the underground
			-- grew by the same x1.78 area, so its enrichments must be topped up to vanilla
			-- density too (they weren't -- the underground sat ~44% under vanilla density).
			-- The x1.78 factor is correct per BUILDABLE area as well: the buildable floor
			-- stretched by the same factor as the map (the census logs the measured numbers).
			-- Placement pools are buildable-floor-only underground (CanReceiveDeposit), so no
			-- enrichment lands in the inaccessible rock/void.
			do
				local deposits = SuperBigMap.DepositRules
				if deposits then
					if type(deposits.LogBuildableSectorCensus) == "function" then
						InvestigationSafeCall("underground enrichment: buildable-sector census", map,
							deposits.LogBuildableSectorCensus, map, "underground post-stretch, pre-topup")
					end
					if type(deposits.TopUpDeposits) == "function" then
						SetLoadingPhase("Distributing underground resources and anomalies")
						StretchLog("underground stretch: -> TopUpDeposits")
						InvestigationSafeCall("underground enrichment: top up resource deposits", map,
							deposits.TopUpDeposits, map)
					end
					if type(deposits.TopUpAnomalies) == "function" then
						StretchLog("underground stretch: -> TopUpAnomalies")
						InvestigationSafeCall("underground enrichment: top up anomalies", map,
							deposits.TopUpAnomalies, map)
					end
					if type(deposits.TopUpEffectDeposits) == "function" then
						StretchLog("underground stretch: -> TopUpEffectDeposits")
						InvestigationSafeCall("underground enrichment: top up effect markers", map,
							deposits.TopUpEffectDeposits, map)
					end
					if type(deposits.RegisterClonedMarkers) == "function" then
						StretchLog("underground stretch: -> RegisterClonedMarkers")
						InvestigationSafeCall("underground enrichment: register cloned markers", map,
							deposits.RegisterClonedMarkers, map)
					end
					if type(deposits.RespaceAnomalies) == "function" then
						StretchLog("underground stretch: -> RespaceAnomalies")
						InvestigationSafeCall("underground enrichment: respace anomalies", map,
							deposits.RespaceAnomalies, map)
					end
					if type(deposits.EvenOutDepositDensity) == "function" then
						StretchLog("underground stretch: -> EvenOutDepositDensity")
						InvestigationSafeCall("underground enrichment: even deposit density", map,
							deposits.EvenOutDepositDensity, map)
					end
					if type(deposits.RelocateUnreachableUndergroundEnrichments) ~= "function" then
						error("underground enrichment reachability audit is unavailable")
					end
					SetLoadingPhase("Moving underground enrichments onto reachable terrain")
					StretchLog("underground stretch: -> RelocateUnreachableUndergroundEnrichments")
					local audit_token = InvestigationBegin("underground enrichment: relocate unreachable markers", map)
					local audit_ok, audit_stats = deposits.RelocateUnreachableUndergroundEnrichments(map)
					InvestigationEnd(audit_token, {
						checked = audit_stats and audit_stats.checked,
						invalid = audit_stats and audit_stats.invalid,
						moved = audit_stats and audit_stats.moved,
						unresolved = audit_stats and audit_stats.unresolved,
					}, audit_ok == true)
					StretchLog("underground enrichment reachability audit returned", {
						ok = audit_ok, checked = audit_stats and audit_stats.checked,
						invalid = audit_stats and audit_stats.invalid, moved = audit_stats and audit_stats.moved,
						unresolved = audit_stats and audit_stats.unresolved,
					})
					if audit_ok ~= true then
						error("underground enrichment reachability audit left "
							.. tostring(audit_stats and audit_stats.unresolved or "unknown") .. " unresolved markers")
					end
					if type(deposits.ResolveBadgeMarkerOverlaps) == "function" then
						StretchLog("underground stretch: -> ResolveBadgeMarkerOverlaps")
						InvestigationSafeCall("underground enrichment: resolve badge overlaps", map,
							deposits.ResolveBadgeMarkerOverlaps, map, "underground reachable density suite")
					end
					if type(deposits.LogEnrichmentPositionCensus) == "function" then
						StretchLog("underground stretch: -> final enrichment position census")
						InvestigationSafeCall("underground enrichment positions: final after density suite", map,
							deposits.LogEnrichmentPositionCensus,
							map, "underground final after topups", false)
					end
					if type(deposits.LogDistributionReport) == "function" then
						InvestigationSafeCall("underground enrichment: distribution report", map,
							deposits.LogDistributionReport, map, "underground after reachable density suite")
					end
					if type(deposits.ClearTopUpPlacementPool) == "function" then
						local detail_token = InvestigationBegin("underground enrichment: clear post-suite placement pool", map)
						deposits.ClearTopUpPlacementPool(map)
						InvestigationEnd(detail_token, nil, true)
					end
				end
			end
			-- (Buildable + passability rebuilds moved ABOVE the density suite -- its
			-- buildable-floor-only pools need the live grid.)
			spike_token = InvestigationBegin("underground: spike audit complete", map)
			SpikeAudit(map, "underground DONE")
			InvestigationEnd(spike_token, nil, true)
			local main_map2 = Global("MainMap")
			if main_map2 and main_map2 ~= map then
				SpikeAudit(main_map2, "surface at underground-stretch DONE")
			end
		end)
		if not ok_branch and type(elevator_migrations) == "table" and #elevator_migrations > 0 then
			-- Do not strand the player without the removed underground half if a later stretch stage
			-- fails. Rebuild any record not already restored on the map's current live terrain.
			local recovery_ok, recovery_err = pcall(RestoreDeferredElevatorMigration, map,
				elevator_migrations, "pipeline-failure-recovery")
			StretchLog("underground stretch: deferred Elevator failure recovery", {
				ok = recovery_ok, err = recovery_ok and nil or tostring(recovery_err),
			})
		end
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
			-- The final passability/buildable grids were synchronously rebuilt before the
			-- reachability-filtered density suite. CurrentMapChangeDone must not immediately
			-- rebuild them again after placement and silently change the accepted terrain.
			map.SuperBigMapSkipNextLifecycleBoundsRebuild = true
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
			map.SuperBigMapSkipNextLifecycleBoundsRebuild = nil
		end
		map.SuperBigMapUndergroundStretchRunning = false
		UndergroundAccessLog("complete deferred pipeline finished", UndergroundAccessState(map, {
			ok = tostring(ok_branch), error = tostring(branch_err), first_access = tostring(force_now == true),
		}), ok_branch and "info" or "error")
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

local function NeedsDeferredUndergroundPreparation(map)
	if not map or not map.mapdata or map.mapdata.Environment ~= "Underground" then
		return false, "target is not an underground map"
	end
	if not cfg_bool("STRETCH_UNDERGROUND", false) then
		return false, "underground stretch is disabled"
	end
	RestoreDeferredUndergroundGeometry(map)
	local desired = map.SuperBigMapDesiredWidthTiles
	local generator = map.SuperBigMapGeneratorWidthTiles
	if not (type(desired) == "number" and type(generator) == "number" and desired > generator) then
		return false, "target has no deferred expandable geometry"
	end
	if map.SuperBigMapUndergroundPrepared == true or map.SuperBigMapUndergroundStretchDone == true then
		return false, "target is already prepared"
	end
	return true, "deferred underground preparation required"
end

local function ResolveHudUndergroundTarget(button)
	local entry = button and button.context
	local entry_source = "button.context"
	if entry and entry.index then
		local map_switch = Global("MapSwitchClass")
		if type(map_switch) == "table" and type(map_switch.GetEntries) == "function" then
			local ok, entries = pcall(map_switch.GetEntries)
			if ok and type(entries) == "table" then
				entry = entries[entry.index]
				entry_source = "MapSwitchClass.GetEntries[index]"
			else
				entry_source = "MapSwitchClass.GetEntries failed"
			end
		end
	end
	local target = button and button.Map or entry and entry.Map
	return target, entry, entry_source
end

-- The generated HUD handler was observed reaching CurrentMapChangeDone without calling the
-- replaceable global ChangeCurrentMapSlot in v478. Wrap each concrete HUD button's OnPress too,
-- so the underground symbol has a direct, deterministic route into our gate. This composes with
-- later generic constructor wrappers and leaves surface/asteroid entries untouched.
local function PatchDeferredUndergroundHudAccess(source)
	local State = SuperBigMap.State
	local hud_class = Engine.ClassTable("HUDButtonMapSwitch")
	local current = hud_class and hud_class.Init
	UndergroundAccessLog("HUD patch check", {
		source = tostring(source or "?"), hud_class = tostring(hud_class),
		current_init = tostring(current), stored_wrapper = tostring(State.underground_hud_init_wrapper),
		patch_version = tostring(State.underground_hud_patch_version),
		external_wrapper_present = tostring(State.underground_hud_init_wrapper ~= nil
			and current ~= State.underground_hud_init_wrapper),
	})
	if type(current) ~= "function" then
		UndergroundAccessLog("HUD patch unavailable: HUDButtonMapSwitch.Init missing", {
			source = tostring(source or "?"),
		}, "warn")
		return false
	end
	if current == State.underground_hud_init_wrapper
		and State.underground_hud_patch_version == GENERATOR_PATCH_VERSION then
		UndergroundAccessLog("HUD patch verified", { source = tostring(source or "?") })
		return true
	end
	-- Another engine/mod layer may wrap this constructor after us. Preserve that generic chain
	-- instead of wrapping it a second time: our stored wrapper remains its predecessor, while the
	-- CurrentMapChangeDone recovery independently guarantees preparation if a reload replaced it.
	if State.underground_hud_init_wrapper ~= nil
		and current ~= State.underground_hud_init_wrapper
		and State.underground_hud_patch_version == GENERATOR_PATCH_VERSION then
		UndergroundAccessLog("HUD patch preserved beneath a later wrapper", {
			source = tostring(source or "?"), current_init = tostring(current),
			stored_wrapper = tostring(State.underground_hud_init_wrapper),
		})
		return true
	end
	if current == State.underground_hud_init_wrapper
		and type(State.original_underground_hud_init) == "function" then
		current = State.original_underground_hud_init
		hud_class.Init = current
		UndergroundAccessLog("HUD patch hot-reload wrapper removed", {
			source = tostring(source or "?"), restored_init = tostring(current),
		})
	end
	State.original_underground_hud_init = current
	-- Capture the predecessor in this closure. Never read State.original_underground_hud_init from
	-- inside the wrapper: lifecycle re-verification may update that shared field later, and v479's
	-- mutable lookup allowed two generic wrapper layers to call one another indefinitely.
	local captured_original_init = current
	local wrapper = function(self, parent, context)
		local depth = (State.underground_hud_init_depth or 0) + 1
		State.underground_hud_init_depth = depth
		if depth > 1 then
			State.underground_hud_init_depth = depth - 1
			UndergroundAccessLog("HUD constructor recursion blocked", {
				source = tostring(source or "?"), depth = tostring(depth),
				captured_original_init = tostring(captured_original_init), current_init = tostring(hud_class.Init),
			}, "error")
			return
		end
		local ok_init, result = pcall(captured_original_init, self, parent, context)
		State.underground_hud_init_depth = depth - 1
		if not ok_init then
			UndergroundAccessLog("HUD predecessor constructor failed", {
				source = tostring(source or "?"), predecessor = tostring(captured_original_init),
				error = tostring(result),
			}, "error")
			error(result)
		end
		local frame = self and self[1]
		UndergroundAccessLog("HUD map-switch instance initialized", {
			instance = tostring(self), frame = tostring(frame), context = tostring(context),
			frame_on_press = tostring(frame and frame.OnPress), frame_map = tostring(frame and frame.Map),
		})
		if type(frame) ~= "table" or type(frame.OnPress) ~= "function" then
			UndergroundAccessLog("HUD instance not wrapped: press handler unavailable", {
				instance = tostring(self), frame = tostring(frame),
			}, "warn")
			return result
		end
		if frame.SuperBigMapUndergroundAccessPressVersion == GENERATOR_PATCH_VERSION then
			UndergroundAccessLog("HUD instance press handler already wrapped", { frame = tostring(frame) })
			return result
		end
		local original_press = frame.OnPress
		frame.OnPress = function(button, gamepad)
			local target, entry, entry_source = ResolveHudUndergroundTarget(button)
			local needs_prepare, reason = NeedsDeferredUndergroundPreparation(target)
			UndergroundAccessLog("HUD underground symbol press observed", UndergroundAccessState(target, {
				button = tostring(button), gamepad = tostring(gamepad), entry = tostring(entry),
				entry_source = tostring(entry_source), entry_enabled = tostring(entry and entry.Enabled),
				button_map = tostring(button and button.Map), needs_prepare = tostring(needs_prepare),
				decision = tostring(reason), gate_wrapper = tostring(State.change_current_map_slot_wrapper),
				global_switch = tostring(Global("ChangeCurrentMapSlot")),
			}))
			if not needs_prepare then
				return original_press(button, gamepad)
			end
			if button.SuperBigMapUndergroundAccessClickRunning == true then
				UndergroundAccessLog("HUD duplicate underground press ignored while preparation is active",
					UndergroundAccessState(target), "warn")
				return
			end
			local create_thread = Global("CreateRealTimeThread")
			if type(create_thread) ~= "function" then
				UndergroundAccessLog("HUD interception failed: CreateRealTimeThread missing",
					UndergroundAccessState(target), "error")
				return original_press(button, gamepad)
			end
			button.SuperBigMapUndergroundAccessClickRunning = true
			create_thread(function()
				UndergroundAccessLog("HUD first-access thread entered", UndergroundAccessState(target, {
					target_slot = tostring(target and target.slot),
				}))
				local gate = State.change_current_map_slot_wrapper
				if type(gate) == "function" and target and target.slot then
					gate(target.slot, true, "idChangeCurrentMapSlot")
				else
					UndergroundAccessLog("HUD first-access thread cannot invoke gate", UndergroundAccessState(target, {
						gate = tostring(gate), target_slot = tostring(target and target.slot),
					}), "error")
				end
				button.SuperBigMapUndergroundAccessClickRunning = false
				UndergroundAccessLog("HUD first-access thread exited", UndergroundAccessState(target))
			end)
			return
		end
		frame.SuperBigMapUndergroundAccessPressVersion = GENERATOR_PATCH_VERSION
		frame.SuperBigMapUndergroundAccessOriginalPress = original_press
		UndergroundAccessLog("HUD instance press handler wrapped", {
			frame = tostring(frame), original_press = tostring(original_press),
			wrapped_press = tostring(frame.OnPress),
		})
		return result
	end
	hud_class.Init = wrapper
	State.underground_hud_init_wrapper = wrapper
	State.underground_hud_patch_version = GENERATOR_PATCH_VERSION
	UndergroundAccessLog("HUD patch installed", {
		source = tostring(source or "?"), replaced_init = tostring(current), wrapper = tostring(wrapper),
		captured_original_init = tostring(captured_original_init),
	})
	return true
end

-- FIRST-ACCESS GATE. Every vanilla HUD/object route that changes between already-loaded map
-- slots funnels through ChangeCurrentMapSlot. Hold that one call before it emits CurrentMapChange
-- or exposes the target map, run the complete deferred underground pipeline, and switch only on
-- success. The normal map-switch loading screen is opened BEFORE the heavy work and kept open
-- across the eventual switch. No terrain flatten/sculpt operation is added here: entrance objects
-- are moved only by the existing post-stretch marker/visual pass against final terrain.
local function PatchDeferredUndergroundAccess(source)
	if not cfg_bool("EXPANSION_STEP_02_STRETCH_AND_TRANSFORM_VANILLA_SOURCE", false) then return false end
	local State = SuperBigMap.State
	local current = Global("ChangeCurrentMapSlot")
	UndergroundAccessLog("map-slot gate patch check", {
		source = tostring(source or "?"), current_switch = tostring(current),
		stored_wrapper = tostring(State.change_current_map_slot_wrapper),
		stored_original = tostring(State.original_change_current_map_slot),
		patch_version = tostring(State.underground_access_patch_version),
	})
	if type(current) ~= "function" then
		UndergroundAccessLog("map-slot gate unavailable: ChangeCurrentMapSlot missing", {
			source = tostring(source or "?"),
		}, "error")
		PatchDeferredUndergroundHudAccess(source)
		return false
	end
	if current == State.change_current_map_slot_wrapper
		and State.underground_access_patch_version == GENERATOR_PATCH_VERSION then
		StretchLog("underground access gate verified", { source = tostring(source or "?") })
		UndergroundAccessLog("map-slot gate verified", {
			source = tostring(source or "?"), wrapper = tostring(current),
		})
		PatchDeferredUndergroundHudAccess(source)
		return true
	end
	-- Hot-reload upgrade: unwrap our previous closure before capturing the vanilla original.
	if current == State.change_current_map_slot_wrapper
		and type(State.original_change_current_map_slot) == "function" then
		current = State.original_change_current_map_slot
		rawset(_G, "ChangeCurrentMapSlot", current)
		UndergroundAccessLog("map-slot gate hot-reload wrapper removed", {
			source = tostring(source or "?"), restored_switch = tostring(current),
		})
	end
	State.original_change_current_map_slot = current
	local captured_original_switch = current
	local wrapper = function(map_slot, loading_screen, loading_screen_id)
		-- Immutable predecessor: later lifecycle verification may update shared patch state, but an
		-- already-installed closure must never change which function it calls.
		local original = captured_original_switch
		UndergroundAccessLog("map-slot gate entered", {
			map_slot = tostring(map_slot), loading_screen = tostring(loading_screen),
			loading_screen_id = tostring(loading_screen_id), original_switch = tostring(original),
			current_global_switch = tostring(Global("ChangeCurrentMapSlot")),
		})
		if type(original) ~= "function" then
			UndergroundAccessLog("map-slot gate aborted: original switch missing", {
				map_slot = tostring(map_slot),
			}, "error")
			return
		end
		local maps = Global("Maps")
		local target = type(maps) == "table" and maps[map_slot] or nil
		local restored_geometry = RestoreDeferredUndergroundGeometry(target)
		local env = target and target.mapdata and target.mapdata.Environment
		local desired = target and target.SuperBigMapDesiredWidthTiles
		local generator = target and target.SuperBigMapGeneratorWidthTiles
		local expanded_target = type(desired) == "number" and type(generator) == "number"
			and desired > generator
		StretchLog("underground access gate: map switch requested", {
			map_slot = tostring(map_slot), map = tostring(target and target.name),
			environment = tostring(env), desired = tostring(desired), generator = tostring(generator),
			expanded_target = expanded_target == true,
			prepared = tostring(target and target.SuperBigMapUndergroundPrepared),
			done = tostring(target and target.SuperBigMapUndergroundStretchDone),
			pending = tostring(target and target.SuperBigMapUndergroundStretchPending),
		})
		local needs_prepare, decision = NeedsDeferredUndergroundPreparation(target)
		UndergroundAccessLog("map-slot target resolved", UndergroundAccessState(target, {
			requested_slot = tostring(map_slot), maps_table = tostring(maps),
			restored_geometry = tostring(restored_geometry), expanded_target = tostring(expanded_target),
			needs_prepare = tostring(needs_prepare), decision = tostring(decision),
		}))
		if not needs_prepare then
			UndergroundAccessLog("map-slot gate passing request to original", UndergroundAccessState(target, {
				decision = tostring(decision), original_switch = tostring(original),
			}))
			return original(map_slot, loading_screen, loading_screen_id)
		end

		-- A second switch request can arrive while the first caller is preparing the map. Wait for
		-- that authoritative run rather than launching a second one over partially changed grids.
		if target.SuperBigMapUndergroundStretchRunning == true then
			UndergroundAccessLog("map-slot gate waiting for active preparation", UndergroundAccessState(target))
			local wait_msg = Global("WaitMsg")
			if type(wait_msg) == "function" then
				local wait_result = wait_msg("SuperBigMapUndergroundExpansionDone", 120000)
				UndergroundAccessLog("map-slot gate active-preparation wait returned", UndergroundAccessState(target, {
					wait_result = tostring(wait_result),
				}))
			else
				UndergroundAccessLog("map-slot gate cannot wait: WaitMsg missing", UndergroundAccessState(target), "error")
			end
			if target.SuperBigMapUndergroundStretchDone == true then
				UndergroundAccessLog("map-slot gate passing after active preparation completed", UndergroundAccessState(target))
				return original(map_slot, loading_screen, loading_screen_id)
			end
		end

		local function show_failure(reason)
			UndergroundAccessLog("underground access failure dialog requested", UndergroundAccessState(target, {
				error = tostring(reason),
			}), "error")
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
			UndergroundAccessLog("map-slot gate blocked by saved failure state", UndergroundAccessState(target), "error")
			show_failure(target.SuperBigMapUndergroundStretchFailed
				or "A previous underground preparation attempt failed")
			return false
		end

		local screen_id = loading_screen_id or "idChangeCurrentMapSlot"
		local screen_open = loading_screen ~= false
		local open_screen = Global("LoadingScreenOpen")
		local close_screen = Global("LoadingScreenClose")
		local wait_render = Global("WaitRenderMode")
		UndergroundAccessLog("map-slot gate loading-screen decision", UndergroundAccessState(target, {
			screen_id = tostring(screen_id), screen_open_requested = tostring(screen_open),
			open_screen = tostring(open_screen), close_screen = tostring(close_screen),
			wait_render = tostring(wait_render),
		}))
		if screen_open and type(open_screen) == "function" then
			UndergroundAccessLog("opening first-access loading screen", UndergroundAccessState(target, {
				screen_id = tostring(screen_id),
			}))
			open_screen(screen_id, map_slot)
			if type(wait_render) == "function" then wait_render("ui") end
			UndergroundAccessLog("first-access loading screen is active", UndergroundAccessState(target, {
				screen_id = tostring(screen_id),
			}))
		else
			screen_open = false
			UndergroundAccessLog("first-access loading screen unavailable or suppressed", UndergroundAccessState(target), "warn")
		end

		SetLoadingPhase("Preparing the underground map for first access")
		UndergroundAccessLog("invoking complete preparation before map switch", UndergroundAccessState(target))
		local ok, err = RunUndergroundStretchIfEnabled(target, true)
		UndergroundAccessLog("complete preparation returned to map-slot gate", UndergroundAccessState(target, {
			ok = tostring(ok), error = tostring(err),
		}), ok == true and "info" or "error")
		if ok ~= true then
			if screen_open then
				UndergroundAccessLog("closing first-access loading screen after failure", UndergroundAccessState(target, {
					screen_id = tostring(screen_id),
				}))
				if type(close_screen) == "function" then close_screen(screen_id, map_slot) end
				if type(wait_render) == "function" then wait_render("scene") end
			end
			show_failure(err or target.SuperBigMapUndergroundStretchFailed or "Preparation did not complete")
			return false
		end

		SetLoadingPhase("Opening the completed underground map")
		-- We already own the screen, so suppress the original's open/close pair and close it only
		-- after ChangeCurrentMapSlot has switched maps and waited for scene rendering.
		UndergroundAccessLog("calling original map switch after successful preparation", UndergroundAccessState(target, {
			original_switch = tostring(original), suppress_original_screen = tostring(screen_open),
		}))
		local result = original(map_slot, screen_open and false or loading_screen, loading_screen_id)
		local get_current_slot = Global("GetCurrentMapSlot")
		local current_slot = type(get_current_slot) == "function" and SafeCall(get_current_slot) or nil
		UndergroundAccessLog("original map switch returned", UndergroundAccessState(target, {
			result = tostring(result), current_slot = tostring(current_slot),
		}))
		if screen_open and type(close_screen) == "function" then close_screen(screen_id, map_slot) end
		UndergroundAccessLog("map-slot gate completed", UndergroundAccessState(target, {
			screen_closed = tostring(screen_open and type(close_screen) == "function"),
		}))
		return result
	end
	rawset(_G, "ChangeCurrentMapSlot", wrapper)
	State.change_current_map_slot_wrapper = wrapper
	State.underground_access_patch_version = GENERATOR_PATCH_VERSION
	StretchLog("underground access gate installed", {
		source = tostring(source or "?"), replaced = tostring(current),
	})
	UndergroundAccessLog("map-slot gate installed", {
		source = tostring(source or "?"), replaced_switch = tostring(current), wrapper = tostring(wrapper),
		captured_original_switch = tostring(captured_original_switch),
	})
	PatchDeferredUndergroundHudAccess(source)
	DebugPrint("deferred underground first-access gate installed via " .. tostring(source or "module load"))
	return true
end

-- Last-resort safety net for switch routes that bypass both replaceable entry points. It runs
-- immediately after CurrentMapChangeDone in its own real-time thread, covers the already-current
-- underground with a loading screen, and completes the exact same atomic preparation pipeline.
-- The v478 trace proved this boundary is reached even when the generated HUD closure bypasses the
-- global gate, so deferred work can no longer remain permanently pending and invisible.
local function HandleDeferredUndergroundMapChange(map_slot, map)
	local needs_prepare, decision = NeedsDeferredUndergroundPreparation(map)
	UndergroundAccessLog("CurrentMapChangeDone fallback audit", UndergroundAccessState(map, {
		map_slot_event = tostring(map_slot), needs_prepare = tostring(needs_prepare),
		decision = tostring(decision), recovery_scheduled = tostring(map and underground_recovery_maps[map] == true),
	}))
	if not needs_prepare then return false end
	if underground_recovery_maps[map] == true then
		UndergroundAccessLog("CurrentMapChangeDone fallback already scheduled", UndergroundAccessState(map), "warn")
		return true
	end
	local create_thread = Global("CreateRealTimeThread")
	if type(create_thread) ~= "function" then
		UndergroundAccessLog("CurrentMapChangeDone fallback unavailable: CreateRealTimeThread missing",
			UndergroundAccessState(map), "error")
		return false
	end
	underground_recovery_maps[map] = true
	UndergroundAccessLog("CurrentMapChangeDone bypass confirmed; scheduling immediate preparation",
		UndergroundAccessState(map), "warn")
	create_thread(function()
		local screen_id = "idSuperBigMapUndergroundFirstAccessRecovery"
		local open_screen = Global("LoadingScreenOpen")
		local close_screen = Global("LoadingScreenClose")
		local wait_render = Global("WaitRenderMode")
		local screen_open = type(open_screen) == "function"
		UndergroundAccessLog("fallback preparation thread entered", UndergroundAccessState(map, {
			screen_id = screen_id, screen_open_available = tostring(screen_open),
			open_screen = tostring(open_screen), close_screen = tostring(close_screen),
			wait_render = tostring(wait_render),
		}))
		if screen_open then
			open_screen(screen_id, map_slot)
			if type(wait_render) == "function" then wait_render("ui") end
			UndergroundAccessLog("fallback loading screen is active", UndergroundAccessState(map, {
				screen_id = screen_id,
			}))
		end
		SetLoadingPhase("Preparing the underground map after a bypassed first-access switch")
		local ok, err = RunUndergroundStretchIfEnabled(map, true)
		UndergroundAccessLog("fallback complete preparation returned", UndergroundAccessState(map, {
			ok = tostring(ok), error = tostring(err),
		}), ok == true and "info" or "error")
		if screen_open and type(close_screen) == "function" then
			close_screen(screen_id, map_slot)
			if type(wait_render) == "function" then wait_render("scene") end
		end
		underground_recovery_maps[map] = nil
		if ok ~= true then
			local create_box = Global("CreateMessageBox")
			if type(create_box) == "function" then
				local untranslated = Global("Untranslated")
				local wrap = type(untranslated) == "function" and untranslated or function(s) return s end
				pcall(create_box, nil, wrap("Super Big Map"), wrap(
					"The underground first-access route bypassed its preparation gate, and recovery failed. "
					.. "Please check the UndergroundAccess debug log.\n\n" .. tostring(err or "Unknown error")))
			end
		end
		UndergroundAccessLog("fallback preparation thread exited", UndergroundAccessState(map, {
			ok = tostring(ok), screen_closed = tostring(screen_open and type(close_screen) == "function"),
		}), ok == true and "info" or "error")
	end)
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
MapGeneration.PatchEntranceBadgePosition = PatchEntranceBadgePosition
MapGeneration.RestoreEntranceBadgePositions = RestoreEntranceBadgePositions
MapGeneration.HandleDeferredUndergroundMapChange = HandleDeferredUndergroundMapChange
MapGeneration.SyncMapDataToGrids = SyncMapDataToGrids
MapGeneration.RunSectorMirrorPlanIfEnabled = RunSectorMirrorPlanIfEnabled
MapGeneration.ForceFramePassable = ForceFramePassable
MapGeneration.ReinvalidateExpandedTerrain = ReinvalidateExpandedTerrain

function MapGeneration.ApplyModBehavior()
	local generate_source = cfg_bool("EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE", false)
	local transform_source = cfg_bool("EXPANSION_STEP_02_STRETCH_AND_TRANSFORM_VANILLA_SOURCE", false)
	if not generate_source then
		MapGeneration.RestoreVanillaBehavior()
		return false
	end
	-- Remove any stage-02 wrappers left by an in-session config reload, then install the
	-- exact-vanilla generation wrapper owned by stage 01.
	if not transform_source then MapGeneration.RestoreVanillaBehavior() end
	PatchRandomMapGenerator()
	if transform_source then
		PatchPassagePairing()
		PatchEntranceBadgePosition()
		PatchDeferredUndergroundAccess("ApplyModBehavior")
	end
	return true
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
		if type(State.generator_original_proc_start) == "function" then
			generator_class.ProcStart = State.generator_original_proc_start
		end
		if type(State.generator_original_proc_end) == "function" then
			generator_class.ProcEnd = State.generator_original_proc_end
		end
		if type(State.generator_original_on_generate_logic) == "function" then
			generator_class.OnGenerateLogic = State.generator_original_on_generate_logic
		end
	end
	State.generator_original_generate = nil
	State.generator_original_do_generate = nil
	State.generator_original_proc_start = nil
	State.generator_original_proc_end = nil
	State.generator_original_on_generate_logic = nil
	State.generator_proc_start_wrapper = nil
	State.generator_proc_end_wrapper = nil
	State.generator_on_generate_logic_wrapper = nil
	State.rmg_placement_active_map = nil
	State.rmg_placement_proc_active = nil
	State.rmg_placement_proc_stack = nil
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
	local hud_class = Engine.ClassTable and Engine.ClassTable("HUDButtonMapSwitch")
	if type(hud_class) == "table" and State.underground_hud_init_wrapper
		and hud_class.Init == State.underground_hud_init_wrapper
		and type(State.original_underground_hud_init) == "function" then
		hud_class.Init = State.original_underground_hud_init
	end
	State.underground_hud_init_wrapper = nil
	State.original_underground_hud_init = nil
	State.underground_hud_patch_version = nil
	RestoreEntranceBadgePositionPatch()
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
local module_config = SuperBigMap.Config or {}
local module_generate_source = module_config.EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE == true
local module_transform_source = module_config.EXPANSION_STEP_02_STRETCH_AND_TRANSFORM_VANILLA_SOURCE == true
if module_config.ENABLE_MOD ~= false
	and module_generate_source
	and (SuperBigMap.State or {}).main_menu_vanilla ~= true then
	PatchRandomMapGenerator()
	if module_transform_source then
		PatchPassagePairing()
		PatchEntranceBadgePosition()
		PatchDeferredUndergroundAccess("module load")
	end
end

DebugPrint("map generation module loaded")

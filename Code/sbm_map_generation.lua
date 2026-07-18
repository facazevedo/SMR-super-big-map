-- Super Big Map -- stretch-only 20x20 map expansion.
--
-- For eligible random maps this allocates an 8192-tile destination, generates one
-- native vanilla source, then proportionally stretches its terrain and generated
-- content over the destination. The RandomMapGenerator.Generate/DoGenerate hook
-- and stretch pass share pending-map state, so they live together here.
--
-- Generic engine helpers come from sbm_engine. This module keeps only the gen-time
-- TerrainSize local because its behavior is context-specific to map generation --
-- e.g. DoGenerate temporarily overrides
-- terrain.GetMapSize so the generator only sees the native source view, and the gen-time
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
SuperBigMap.State.expansion_pending_maps = SuperBigMap.State.expansion_pending_maps or {}
SuperBigMap.State.expansion_blocked_maps = SuperBigMap.State.expansion_blocked_maps or {}
SuperBigMap.State.underground_recovery_maps = SuperBigMap.State.underground_recovery_maps
	or setmetatable({}, { __mode = "k" })
SuperBigMap.State.pending_underground_elevator_restores =
	SuperBigMap.State.pending_underground_elevator_restores
	or setmetatable({}, { __mode = "k" })
SuperBigMap.State.underground_elevator_restore_tokens =
	SuperBigMap.State.underground_elevator_restore_tokens or {}
SuperBigMap.State.underground_elevator_restore_epoch =
	SuperBigMap.State.underground_elevator_restore_epoch or 0
local pending_maps = SuperBigMap.State.expansion_pending_maps
local blocked_maps = SuperBigMap.State.expansion_blocked_maps
local underground_recovery_maps = SuperBigMap.State.underground_recovery_maps
local pending_underground_elevator_restores =
	SuperBigMap.State.pending_underground_elevator_restores
local underground_elevator_restore_tokens =
	SuperBigMap.State.underground_elevator_restore_tokens

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
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.LoadingPhase) == "function" then
		diagnostics.LoadingPhase(message, Global("CurrentMap"))
	end
	if type(SuperBigMap.SetLoadingPhase) == "function" then
		pcall(SuperBigMap.SetLoadingPhase, message)
	end
end

local function PackValues(...)
	return { n = select("#", ...), ... }
end

local function LoadingStart(reason, map, data)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.LoadingStart) == "function" then
		diagnostics.LoadingStart(reason, map, data)
	end
end

local function LoadingStep(name, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.LoadingStep) == "function" then
		diagnostics.LoadingStep(name, data, map)
	end
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

local function LoadingFinish(reason, map, data, ok)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.LoadingFinish) == "function" then
		diagnostics.LoadingFinish(reason, map, data, ok)
	end
end

-- Preserve SafeCall's exact behavior and result tuple while timing only the opt-in diagnostic run.
local function TimedSafeCall(name, map, func, ...)
	local diagnostics = SuperBigMap.Diagnostics
	if not (diagnostics and type(diagnostics.LoadingEnabled) == "function"
		and diagnostics.LoadingEnabled() == true) then
		return SafeCall(func, ...)
	end
	local token = LoadingBegin(name, map)
	local results = PackValues(SafeCall(func, ...))
	LoadingEnd(token, { first_result = tostring(results[1]) }, true)
	return Unpack(results, 1, results.n)
end

local function ExpansionAudit(event, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.Elevator) == "function" then
		diagnostics.Elevator(event, data, map)
	end
end

-- Instrument the generator's own procedure dispatcher only while the load-timing gate is on.
-- The wrapper is synchronous, restores env.ProcInvoke on every Lua success/error path, and returns
-- the exact original result tuple. With diagnostics off this is a direct tail call.
local function CallOnGenerateLogicTimed(original, self, env, map, ...)
	local diagnostics = SuperBigMap.Diagnostics
	if not (diagnostics and type(diagnostics.LoadingEnabled) == "function"
		and diagnostics.LoadingEnabled() == true) then
		return original(self, env, ...)
	end
	local saved_proc = type(env) == "table" and env.ProcInvoke or nil
	local timed_proc
	if type(saved_proc) == "function" then
		timed_proc = function(tag, func, randless)
			if type(func) ~= "function" then return saved_proc(tag, func, randless) end
			return saved_proc(tag, function(...)
				local token = LoadingBegin("RandomMap procedure: " .. tostring(tag), map, {
					tag = tostring(tag), randless = tostring(randless),
				})
				local result = PackValues(pcall(func, ...))
				LoadingEnd(token, { tag = tostring(tag) }, result[1] == true)
				if not result[1] then error(result[2]) end
				return Unpack(result, 2, result.n)
			end, randless)
		end
		env.ProcInvoke = timed_proc
	end
	local token = LoadingBegin("RandomMapGenerator.OnGenerateLogic", map)
	local result = PackValues(pcall(original, self, env, ...))
	if timed_proc and env.ProcInvoke == timed_proc then env.ProcInvoke = saved_proc end
	LoadingEnd(token, nil, result[1] == true)
	if not result[1] then error(result[2]) end
	return Unpack(result, 2, result.n)
end

local function SignalExpansionReadinessChanged(map, reason)
	local msg = Global("Msg")
	local signaled = type(msg) == "function" and pcall(msg,
		"SuperBigMapExpansionReadinessChanged", map, reason) == true
	return signaled
end

local function cfg_number(key, default, min_value)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "number" and (min_value == nil or value >= min_value) then
		return value
	end
	return default
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
	return true
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


-- Terrain stretching + object transforms live in sbm_terrain_copy / sbm_object_clone,
-- loaded before this module. Bind the helpers called below (and re-exported through
-- MapGeneration for the lifecycle) to their original local names; assert presence so
-- a load-order mistake fails LOUDLY at startup, not as a deferred nil-call in gen.
local TerrainCopy = SuperBigMap.TerrainCopy
assert(type(TerrainCopy) == "table",
	"sbm_map_generation: SuperBigMap.TerrainCopy missing -- load sbm_terrain_copy before this file")
local SectorBoundary = TerrainCopy.SectorBoundary
local FindSectorByName = TerrainCopy.FindSectorByName
local ReinvalidateExpandedTerrain = TerrainCopy.ReinvalidateExpandedTerrain
local StretchSourceToFull = TerrainCopy.StretchSourceToFull
local StretchBiomeReady = TerrainCopy.StretchBiomeReady
local ScaleDecorationsToFull = TerrainCopy.ScaleDecorationsToFull
local ScaleMarkersToFull = TerrainCopy.ScaleMarkersToFull
local StretchRelocateStartSector = TerrainCopy.StretchRelocateStartSector
local MoveEntranceVisualsToScale = TerrainCopy.MoveEntranceVisualsToScale
local AlignPassagePairsToSharedHex = TerrainCopy.AlignPassagePairsToSharedHex
local PatchEntranceBadgePosition = TerrainCopy.PatchEntranceBadgePosition
local RestoreEntranceBadgePositionPatch = TerrainCopy.RestoreEntranceBadgePositionPatch
local RestoreEntranceBadgePositions = TerrainCopy.RestoreEntranceBadgePositions
local BeginDeferredElevatorMigration = TerrainCopy.BeginDeferredElevatorMigration
local RestoreDeferredElevatorMigration = TerrainCopy.RestoreDeferredElevatorMigration
local AnnotateDecorRelief = TerrainCopy.AnnotateDecorRelief
local ClearDecorRelief = TerrainCopy.ClearDecorRelief
assert(type(ReinvalidateExpandedTerrain) == "function"
	and type(SectorBoundary) == "function" and type(FindSectorByName) == "function",
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

local function ClearPreparedMapInstance(map)
	if type(map) ~= "table" then
		return false
	end
	map.SuperBigMapExpansionPending = nil
	map.SuperBigMapNativeGenerationComplete = nil
	map.SuperBigMapNativeGenerationCompleteSource = nil
	map.SuperBigMapCityInitializationComplete = nil
	map.SuperBigMapSurfaceStretchDone = nil
	map.SuperBigMapSurfaceStretchScheduled = nil
	map.SuperBigMapSurfaceStretchAwaitingReadiness = nil
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
	map.SuperBigMapPassageBootstrapComplete = nil
	map.SuperBigMapPassageBootstrapCount = nil
	map.SuperBigMapDeferredUndergroundWondersPending = nil
	map.SuperBigMapDeferredUndergroundWondersDone = nil
	map.SuperBigMapDeferredUndergroundWonderCount = nil
	map.SuperBigMapDeferredUndergroundWondersSpawned = nil
	map.SuperBigMapDeferredTunnelSpawnsPending = nil
	map.SuperBigMapDeferredTunnelSpawnsDone = nil
	map.SuperBigMapDeferredTunnelSpawnCount = nil
	map.SuperBigMapDeferredTunnelSpawnsCreated = nil
	map.SuperBigMapGeneratorWidth = nil
	map.SuperBigMapGeneratorHeight = nil
	map.SuperBigMapGeneratorWidthTiles = nil
	map.SuperBigMapGeneratorHeightTiles = nil
	map.SuperBigMapExpandedWorldWidth = nil
	map.SuperBigMapExpandedWorldHeight = nil
	map.SuperBigMapExpandedHexWidth = nil
	map.SuperBigMapExpandedHexHeight = nil
	return true
end

-- The landing-screen toggle chooses whether the single stretch pipeline runs for
-- this new game. It does not select between expansion implementations.
local function ShouldExpandNewMap()
	local toggle = SuperBigMap.PregameToggle
	if toggle and type(toggle.ShouldExpandNewMap) == "function" then
		local ok, result = pcall(toggle.ShouldExpandNewMap)
		return ok and result == true
	end
	return false
end

local function RestorePreparedMapData(map_name, mapdata)
	if type(mapdata) ~= "table" then
		return false
	end
	local original_width = mapdata.SuperBigMapOriginalWidthTiles
		or mapdata.SuperBigMapOriginalMapDataWidth
	local original_height = mapdata.SuperBigMapOriginalHeightTiles
		or mapdata.SuperBigMapOriginalMapDataHeight
	if type(original_width) == "number" and original_width > 0 then
		mapdata.Width = original_width
	end
	if type(original_height) == "number" and original_height > 0 then
		mapdata.Height = original_height
	end
	if mapdata.SuperBigMapOriginalPassBorderCaptured == true then
		if mapdata.SuperBigMapOriginalPassBorderWasNil == true then
			mapdata.PassBorder = nil
		else
			mapdata.PassBorder = mapdata.SuperBigMapOriginalPassBorder
		end
		if mapdata.SuperBigMapOriginalPassBorderTilesWasNil == true then
			mapdata.PassBorderTiles = nil
		else
			mapdata.PassBorderTiles = mapdata.SuperBigMapOriginalPassBorderTiles
		end
	elseif mapdata.SuperBigMapOriginalPassBorder ~= nil then
		-- Legacy capture from an older in-process module version.
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
	mapdata.SuperBigMapSourceWidthTiles = nil
	mapdata.SuperBigMapSourceHeightTiles = nil
	mapdata.SuperBigMapOriginalPassBorder = nil
	mapdata.SuperBigMapOriginalPassBorderCaptured = nil
	mapdata.SuperBigMapOriginalPassBorderWasNil = nil
	mapdata.SuperBigMapOriginalPassBorderTiles = nil
	mapdata.SuperBigMapOriginalPassBorderTilesWasNil = nil
	mapdata.SuperBigMapOriginalMapDataWidth = nil
	mapdata.SuperBigMapOriginalMapDataHeight = nil
	if mapdata.SuperBigMapOriginalOverviewAllowedCaptured == true then
		if mapdata.SuperBigMapOriginalOverviewAllowedWasNil == true then
			mapdata.IsAllowedToEnterOverview = nil
		else
			mapdata.IsAllowedToEnterOverview = mapdata.SuperBigMapOriginalOverviewAllowed
		end
		mapdata.SuperBigMapOriginalOverviewAllowed = nil
		mapdata.SuperBigMapOriginalOverviewAllowedWasNil = nil
		mapdata.SuperBigMapOriginalOverviewAllowedCaptured = nil
	end
	if mapdata.SuperBigMapOriginalHeightRangesCaptured == true then
		if type(mapdata.visible_height_range) == "table" then
			mapdata.visible_height_range.from = mapdata.SuperBigMapOriginalVisibleHeightFrom
			mapdata.visible_height_range.to = mapdata.SuperBigMapOriginalVisibleHeightTo
		end
		if type(mapdata.playable_height_range) == "table" then
			mapdata.playable_height_range.from = mapdata.SuperBigMapOriginalPlayableHeightFrom
			mapdata.playable_height_range.to = mapdata.SuperBigMapOriginalPlayableHeightTo
		end
		mapdata.SuperBigMapOriginalVisibleHeightFrom = nil
		mapdata.SuperBigMapOriginalVisibleHeightTo = nil
		mapdata.SuperBigMapOriginalPlayableHeightFrom = nil
		mapdata.SuperBigMapOriginalPlayableHeightTo = nil
		mapdata.SuperBigMapOriginalHeightRangesCaptured = nil
		mapdata.SuperBigMapHeightRangesScaled = nil
	end
	if mapdata.SuperBigMapOriginalTerrainHashCaptured == true then
		if mapdata.SuperBigMapOriginalTerrainHashWasNil == true then
			mapdata.terrain_hash = nil
		else
			mapdata.terrain_hash = mapdata.SuperBigMapOriginalTerrainHash
		end
		mapdata.SuperBigMapOriginalTerrainHash = nil
		mapdata.SuperBigMapOriginalTerrainHashWasNil = nil
		mapdata.SuperBigMapOriginalTerrainHashCaptured = nil
	end
	-- MapData presets are process-shared. Remove every mod-owned annotation so a later vanilla map
	-- receives the same property surface as it would after a fresh game launch.
	local mod_fields = {}
	for key, value in pairs(mapdata) do
		if value ~= nil and tostring(key):find("^SuperBigMap") then
			mod_fields[#mod_fields + 1] = key
		end
	end
	for i = 1, #mod_fields do mapdata[mod_fields[i]] = nil end
	ClearPendingMap(map_name)
	return true
end

-- MapData presets are shared process-wide.  Expansion changes their dimensions,
-- pass border and underground-overview flag; unloading a Map object does not recreate
-- those presets.  Restore every touched preset when returning to pregame so the next
-- map starts from the same inputs as a fresh vanilla process.
local function RestorePreparedMapDataForVanillaSession(reason)
	local restored, seen = 0, {}
	local function restore(name, mapdata)
		if type(mapdata) ~= "table" or seen[mapdata] then return end
		seen[mapdata] = true
		local touched = false
		for key, value in pairs(mapdata) do
			if value ~= nil and tostring(key):find("^SuperBigMap") then
				touched = true
				break
			end
		end
		if touched then
			RestorePreparedMapData(name, mapdata)
			restored = restored + 1
		end
	end
	local map_data = Global("MapData")
	if type(map_data) == "table" then
		for name, mapdata in pairs(map_data) do restore(name, mapdata) end
	end
	for _, global_name in ipairs({ "CurrentMap", "MainMap" }) do
		local map = Global(global_name)
		restore(map and map.name, map and map.mapdata)
	end
	local keys = {}
	for name in pairs(pending_maps) do keys[#keys + 1] = name end
	for i = 1, #keys do pending_maps[keys[i]] = nil end
	return restored
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

	map.SuperBigMapExpansionPending = true
	map.SuperBigMapNativeGenerationComplete = nil
	map.SuperBigMapNativeGenerationCompleteSource = nil
	map.SuperBigMapCityInitializationComplete = nil
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

	return true
end

local function IsEligibleMapData(map_slot, mapdata, map_instance)
	if not cfg_bool("ENABLE_TERRAIN_EXPANSION", false) then
		return false, "feature disabled"
	end

	-- Underground expansion (config STRETCH_UNDERGROUND): the underground map generates in its
	-- own slot with Environment=="Underground"; when the flag is on it is exempt from the
	-- main-slot-only and surface-only gates, so it gets the same 8192 allocation + native-capped
	-- generator as the surface (its stretch then applies the identical transform).
	local underground_ok = cfg_bool("STRETCH_UNDERGROUND", false)
		and type(mapdata) == "table" and mapdata.Environment == "Underground"

	if map_slot ~= 1 and not underground_ok then
		return false, "not the main map slot"
	end

	if not (map_instance and map_instance.RandomMapGenObject) then
		return false, "not a random map generation"
	end

	if type(mapdata) ~= "table" or mapdata.NoTerrain then
		return false, "missing terrain mapdata"
	end

	if mapdata.Environment ~= "Surface" and not underground_ok then
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

local function PrepareMapDataForExpansion(map_slot, map_name, map_instance, source)
	map_instance = type(map_instance) == "table" and map_instance or {}
	local mapdata = map_instance.mapdata
	local map_data_table = Global("MapData")
	if not mapdata and type(map_data_table) == "table" then
		mapdata = map_data_table[map_name or false]
		map_instance.mapdata = mapdata
	end
	-- Keep the landing-site preview lightweight and vanilla-sized. Every real random
	-- map created after New Game uses the stretch-only expanded allocation below.
	if tostring(map_name or "") == "PreGame" then
		RestorePreparedMapData(map_name, mapdata)
		ClearPreparedMapInstance(map_instance)
		return false
	end
	if not ShouldExpandNewMap() then
		RestorePreparedMapData(map_name, mapdata)
		ClearPreparedMapInstance(map_instance)
		return false
	end

	local ok, reason = IsEligibleMapData(map_slot, mapdata, map_instance)
	if not ok then
		return false
	end

	local original_width = mapdata.SuperBigMapOriginalWidthTiles or mapdata.Width
	local original_height = mapdata.SuperBigMapOriginalHeightTiles or mapdata.Height
	local expanded_tiles = math.floor(cfg_number("EXPANDED_TERRAIN_TILES", 8192, 1))
	local renderer_align = math.floor(cfg_number("RENDERER_NODE_TILE_ALIGNMENT", 2048, 1))
	local desired_width = AlignDown(expanded_tiles, renderer_align)
	local desired_height = AlignDown(expanded_tiles, renderer_align)
	local source_width_tiles = original_width
	local source_height_tiles = original_height
	local generator_width_tiles = original_width
	local generator_height_tiles = original_height
	local height_tile_size = Global("const") and const.HeightTileSize or 1

	if desired_width <= original_width or desired_height <= original_height then
		mapdata.Width = original_width
		mapdata.Height = original_height
		pending_maps[map_name or false] = nil
		if not blocked_maps[map_name or false] then
			blocked_maps[map_name or false] = true
		end
		return false
	end

	if source_width_tiles <= 0 or source_height_tiles <= 0 then
		return false
	end
	-- Capture shared-preset values before any generation or expansion mutation.
	-- They must be restored byte-for-byte for the next vanilla game in this process.
	if mapdata.SuperBigMapOriginalPassBorderCaptured ~= true then
		mapdata.SuperBigMapOriginalPassBorderCaptured = true
		mapdata.SuperBigMapOriginalPassBorderWasNil = mapdata.PassBorder == nil
		mapdata.SuperBigMapOriginalPassBorder = mapdata.PassBorder
		mapdata.SuperBigMapOriginalPassBorderTilesWasNil = mapdata.PassBorderTiles == nil
		mapdata.SuperBigMapOriginalPassBorderTiles = mapdata.PassBorderTiles
	end
	if mapdata.SuperBigMapOriginalTerrainHashCaptured ~= true then
		mapdata.SuperBigMapOriginalTerrainHashCaptured = true
		mapdata.SuperBigMapOriginalTerrainHashWasNil = mapdata.terrain_hash == nil
		mapdata.SuperBigMapOriginalTerrainHash = mapdata.terrain_hash
	end

	mapdata.SuperBigMapOriginalWidthTiles = original_width
	mapdata.SuperBigMapOriginalHeightTiles = original_height
	mapdata.SuperBigMapSourceWidthTiles = source_width_tiles
	mapdata.SuperBigMapSourceHeightTiles = source_height_tiles
	mapdata.Width = desired_width
	mapdata.Height = desired_height

	-- The engine bakes a symmetric impassable border of mapdata.PassBorder into
	-- the passability grid at map-build time (the property help reads "requires a
	-- map restart to take effect"). On the expanded map that leaves a thick
	-- impassable ring around the whole playable area. FullMapPlayable wants the
	-- whole expanded terrain available, so zero PassBorder HERE, before generation
	-- builds passability, so no border
	-- is baked. The true original is preserved for restore (sbm_map_bounds's
	-- ResetMapDataBounds only captures SuperBigMapOriginalPassBorder when it is nil).
	-- Otherwise the engine bakes a ~1024-tile impassable ring. The engine's
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
			mapdata.PassBorder = safe_border
			if type(mapdata.PassBorderTiles) == "number" then
				mapdata.PassBorderTiles = (tile > 0) and math.floor(safe_border / tile) or 0
			end
		end
	end
	-- The vanilla source view and the proportional stretch share origin (0,0).
	local source_x, source_y = 0, 0

	local pending = {
		source_width = source_width_tiles * height_tile_size,
		source_height = source_height_tiles * height_tile_size,
		source_x = source_x,
		source_y = source_y,
		generator_width = generator_width_tiles * height_tile_size,
		generator_height = generator_height_tiles * height_tile_size,
		original_width = original_width,
		original_height = original_height,
		source_width_tiles = source_width_tiles,
		source_height_tiles = source_height_tiles,
		generator_width_tiles = generator_width_tiles,
		generator_height_tiles = generator_height_tiles,
		desired_width = desired_width,
		desired_height = desired_height,
	}
	StorePendingMap(map_name, pending)

	map_instance.SuperBigMapExpansionPending = true
	map_instance.SuperBigMapNativeGenerationComplete = nil
	map_instance.SuperBigMapNativeGenerationCompleteSource = nil
	map_instance.SuperBigMapCityInitializationComplete = nil
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

	return true
end

local CaptureGeneratedNativeEnrichments

-- Finalize the expanded destination after native source generation: attach the
-- source/destination geometry, settle the engine, and re-apply bounds/sectors.
local function FinalizeExpandedMap(map)
	if map and not map.SuperBigMapExpansionPending then
		AttachPendingMapState(map)
	end

	if not map or not map.SuperBigMapExpansionPending then
		return false
	end

	local map_width, map_height = TerrainSize(map)
	local source_width = map.SuperBigMapSourceWidth or math.floor((map_width or 0) / 2)
	local source_height = map.SuperBigMapSourceHeight or math.floor((map_height or 0) / 2)
	if not map_width or not map_height or source_width <= 0 or source_height <= 0 then
		return false
	end
	if map_width <= source_width or map_height <= source_height then
		return false
	end

	-- Settle the engine after source generation: refresh the terrain hash and object
	-- radius, re-apply the full-map bounds/sector fit, and clear the allocation flag.
	-- The surface stretch runs after the generation/city readiness milestones.
	local terrain_api = Global("terrain")
	if terrain_api and type(terrain_api.HashGrids) == "function" and map.mapdata then
		if map.mapdata.SuperBigMapOriginalTerrainHashCaptured ~= true then
			map.mapdata.SuperBigMapOriginalTerrainHashCaptured = true
			map.mapdata.SuperBigMapOriginalTerrainHashWasNil = map.mapdata.terrain_hash == nil
			map.mapdata.SuperBigMapOriginalTerrainHash = map.mapdata.terrain_hash
		end
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
	end

	map.SuperBigMapExpansionPending = false
	pending_maps[map.name or false] = nil
	CaptureGeneratedNativeEnrichments(map, "FinalizeExpandedMap")

	return true
end

CaptureGeneratedNativeEnrichments = function(map, label)
	if not cfg_bool("EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE", false) then return 0 end
	local grid = SuperBigMap.SectorGrid
	local is_destination = type(grid) == "table" and type(grid.IsModMap) == "function"
		and grid.IsModMap(map) == true
	local is_source_transaction = map and map.SuperBigMapVanillaSourceMigration == true
		or (SuperBigMap.State or {}).vanilla_source_migration_active == true
	if not is_destination and not is_source_transaction
		and not (map and map.SuperBigMapExpansionPending == true) then
		-- A normal vanilla-size run is not a source stage.  Do not annotate its
		-- markers or map object with SuperBigMap capture fields.
		return 0
	end
	local deposits = SuperBigMap.DepositRules
	if deposits and type(deposits.CaptureNativeEnrichmentPositions) == "function" then
		local ok, count = pcall(deposits.CaptureNativeEnrichmentPositions, map, label)
		if ok then return count or 0 end
	end
	if map then map.SuperBigMapNativeEnrichmentCapturePending = true end
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
local function CopyMigratedTerrain(source, destination)
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
end

local function MapObjects(map)
	if not map or type(map.MapGet) ~= "function" then return nil, "MapGet unavailable" end
	local ok, objects = pcall(map.MapGet, map, "map")
	if not ok then
		return nil, tostring(objects)
	end
	-- The native MapGet contract returns nil when the query has no matches. A freshly loaded
	-- temporary blank map can legitimately contain zero enumerable map objects before generation.
	if objects == nil then
		return {}
	end
	if type(objects) ~= "table" then
		return nil, "MapGet returned " .. type(objects)
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

local function TransferGeneratedObjects(source, destination, source_baseline, excluded_objects)
	local objects, err = MapObjects(source)
	if not objects then error("could not enumerate source objects: " .. tostring(err)) end
	local is_valid = Global("IsValid")
	local roots, seen_roots = {}, {}
	local function belongs_to_excluded_root(obj)
		local current, depth = obj, 0
		while current and depth < 64 do
			if excluded_objects and excluded_objects[current] then return true end
			if type(current.GetParent) ~= "function" then break end
			local parent = SafeCall(current.GetParent, current)
			local parent_valid = parent and (type(is_valid) ~= "function" or is_valid(parent))
			if not parent_valid or (source_baseline and source_baseline[parent]) then break end
			current = parent
			depth = depth + 1
		end
		return false
	end
	for i = 1, #objects do
		local root = objects[i]
		local valid = type(is_valid) ~= "function" or is_valid(root)
		if valid and not (source_baseline and source_baseline[root]) then
			if belongs_to_excluded_root(root) then
			else
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
	end
	local failed = 0
	local failures = {}
	-- TransferToMap removes the object from one map and inserts it into the other. With live
	-- pass edits, the engine updates spatial/passability state for every one of the ~20k decor
	-- roots individually. Batch both sides exactly like the later stretch mass-move transaction;
	-- ResumePassEdits performs one consolidated flush per map, and the authoritative destination
	-- RebuildGrids below still runs unchanged. If either API is absent or rejects suspension, that
	-- side transparently keeps the old per-object behavior.
	local pass_batch_reason = "SuperBigMapTemporarySourceObjectTransfer"
	local source_pass_batch, destination_pass_batch = false, false
	local function SuspendTransferPassEdits(map)
		if not map or type(map.SuspendPassEdits) ~= "function"
			or type(map.ResumePassEdits) ~= "function" then
			return false, "api unavailable"
		end
		local ok, result = pcall(map.SuspendPassEdits, map, pass_batch_reason)
		local active = ok and result ~= false
		return active, ok and nil or result
	end
	source_pass_batch = SuspendTransferPassEdits(source)
	destination_pass_batch = SuspendTransferPassEdits(destination)
	local transfer_loop_ok, transfer_loop_error = pcall(function()
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
					if not ok then
						failed = failed + 1
						if #failures < 8 then
							failures[#failures + 1] = tostring(obj.class) .. ":" .. tostring(transfer_error or "wrong destination")
						end
					end
				end
			end
		end
	end)
	local resume_failures = {}
	local function ResumeTransferPassEdits(map, role, active)
		if not active then return true end
		local ok, result = pcall(map.ResumePassEdits, map, pass_batch_reason)
		if not ok then resume_failures[#resume_failures + 1] = role .. ":" .. tostring(result) end
		return ok
	end
	-- Reverse order of acquisition. Cleanup happens even if an unexpected Lua error escaped the loop.
	ResumeTransferPassEdits(destination, "destination", destination_pass_batch)
	ResumeTransferPassEdits(source, "source", source_pass_batch)
	if not transfer_loop_ok then
		error("temporary source object transfer loop failed: " .. tostring(transfer_loop_error))
	end
	if #resume_failures > 0 then
		error("temporary source object transfer pass-batch cleanup failed: " .. table.concat(resume_failures, " | "))
	end
	local remaining_objects, remaining_error = MapObjects(source)
	if not remaining_objects then error("could not audit source after object transfer: " .. tostring(remaining_error)) end
	local remaining_generated = 0
	for i = 1, #remaining_objects do
		if not (source_baseline and source_baseline[remaining_objects[i]]) then
			if not belongs_to_excluded_root(remaining_objects[i]) then
				remaining_generated = remaining_generated + 1
			end
		end
	end
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

local function SupplyGridDimensions(grid)
	if not grid or type(grid.size) ~= "function" then return nil, nil end
	local ok, width, height = pcall(grid.size, grid)
	if not ok or type(width) ~= "number" then return nil, nil end
	return width, type(height) == "number" and height or width
end

local function IsExpandedSupplyContext(map)
	if type(map) ~= "table" then return false end
	local desired = map.SuperBigMapDesiredWidthTiles
	local generator = map.SuperBigMapGeneratorWidthTiles
	return map.SuperBigMapExpanded == true
		or (type(desired) == "number" and type(generator) == "number" and desired > generator)
end

local function SupplyObjectMap(obj)
	if type(obj) ~= "table" then return nil end
	local stored = rawget(obj, "map")
	if stored then return stored end
	local is_valid = Global("IsValid")
	if type(is_valid) == "function" and SafeCall(is_valid, obj) ~= true then return nil end
	if type(obj.GetMap) == "function" then return SafeCall(obj.GetMap, obj) end
	return nil
end

local function SupplyPointXY(point_value)
	if point_value == nil then return nil, nil end
	local ok, x, y = pcall(function() return point_value:xy() end)
	if ok and type(x) == "number" and type(y) == "number" then return x, y end
	if type(point_value) == "table" then
		x, y = rawget(point_value, "x"), rawget(point_value, "y")
		if type(x) == "number" and type(y) == "number" then return x, y end
	end
	return nil, nil
end

local function ValidateSupplyFragmentFootprint(connection_grid, fragment, resource)
	local elements = type(fragment) == "table" and rawget(fragment, "elements")
	if type(elements) ~= "table" then return 0, 0, 1 end
	local fragment_resource = fragment.supply_resource or resource
	local width, height = SupplyGridDimensions(connection_grid)
	local world_to_hex = Global("WorldToHex")
	local rotate = Global("HexRotate")
	local angle_to_direction = Global("HexAngleToDirection")
	local total_points, out_of_bounds, missing_shapes = 0, 0, 0
	for _, element in ipairs(elements) do
		local building = type(element) == "table" and rawget(element, "building") or nil
		local is_valid = Global("IsValid")
		local building_valid = building and (type(is_valid) ~= "function" or SafeCall(is_valid, building) == true)
		local pos = building_valid and Engine.ObjectPos(building) or nil
		local px, py = SupplyPointXY(pos)
		local q, r
		if type(world_to_hex) == "function" and building_valid then
			q, r = SafeCall(world_to_hex, building)
			if type(q) ~= "number" and type(px) == "number" then
				q, r = SafeCall(world_to_hex, px, py)
			end
		end
		local direction = type(angle_to_direction) == "function" and building_valid
			and SafeCall(angle_to_direction, building) or nil
		local shape
		if building_valid and type(building.GetSupplyGridConnectionShapePoints) == "function" then
			local ok, result = pcall(building.GetSupplyGridConnectionShapePoints,
				building, fragment_resource)
			if ok then shape = result end
		end
		if type(shape) ~= "table" then missing_shapes = missing_shapes + 1 end
		if type(shape) == "table" and type(q) == "number" and type(r) == "number" then
			for _, shape_point in ipairs(shape) do
				local local_q, local_r = SupplyPointXY(shape_point)
				local rotated_q, rotated_r = local_q, local_r
				if type(rotate) == "function" and type(direction) == "number"
					and type(local_q) == "number" and type(local_r) == "number" then
					rotated_q, rotated_r = SafeCall(rotate, local_q, local_r, direction)
				end
				local final_q = type(rotated_q) == "number" and q + rotated_q or nil
				local final_r = type(rotated_r) == "number" and r + rotated_r or nil
				local sx = type(final_q) == "number" and type(final_r) == "number"
					and final_q + final_r / 2 or nil
				local sy = final_r
				local in_bounds = type(sx) == "number" and type(sy) == "number"
					and type(width) == "number" and type(height) == "number"
					and sx >= 0 and sy >= 0 and sx < width and sy < height
				total_points = total_points + 1
				if not in_bounds then out_of_bounds = out_of_bounds + 1 end
			end
		end
	end
	return total_points, out_of_bounds, missing_shapes
end

local function CaptureSupplyGridRefs(map)
	local connections = type(map) == "table" and rawget(map, "supply_connection_grid") or nil
	return {
		map = map,
		connections = connections,
		electricity = type(connections) == "table" and connections.electricity or nil,
		water = type(connections) == "table" and connections.water or nil,
		overlay = type(map) == "table" and rawget(map, "supply_overlay_grid") or nil,
		object = type(map) == "table" and rawget(map, "object_hex_grid") or nil,
	}
end

local function SupplyRefSet(refs)
	local set = {}
	for _, name in ipairs({ "connections", "electricity", "water", "overlay", "object" }) do
		local value = type(refs) == "table" and refs[name] or nil
		if value ~= nil then set[value] = name end
	end
	return set
end

local function QueueUndergroundElevatorRestore(map, records, source)
	if type(map) ~= "table" or type(records) ~= "table" or #records == 0 then return nil end
	local State = SuperBigMap.State
	local old = pending_underground_elevator_restores[map]
	if type(old) == "table" and old.token_id then
		old.cancelled = true
		old.status = "superseded"
		underground_elevator_restore_tokens[old.token_id] = nil
	end
	State.underground_elevator_restore_epoch =
		(State.underground_elevator_restore_epoch or 0) + 1
	local source_map = Global("CurrentMap")
	if source_map == map then source_map = Global("MainMap") end
	local token = {
		token_id = State.underground_elevator_restore_epoch,
		map = map,
		records = records,
		source = tostring(source or "unknown"),
		source_map = source_map,
		forbidden_refs = SupplyRefSet(CaptureSupplyGridRefs(source_map)),
		status = "queued",
		connected = setmetatable({}, { __mode = "k" }),
		merged = setmetatable({}, { __mode = "k" }),
	}
	pending_underground_elevator_restores[map] = token
	underground_elevator_restore_tokens[token.token_id] = token
	map.SuperBigMapDeferredElevatorRestorePending = #records
	map.SuperBigMapDeferredElevatorRestoreToken = token.token_id
	ExpansionAudit("RESTORE_TOKEN_QUEUED", {
		token = token.token_id, records = #records, source = token.source,
		current_map_is_target = tostring(Global("CurrentMap") == map),
		source_map = tostring(source_map), forbidden_grid_refs = tostring(token.forbidden_refs),
	}, map)
	for index, record in ipairs(records) do
		local passage_pos = record.underground_passage and Engine.ObjectPos(record.underground_passage)
		local passage_x, passage_y = SupplyPointXY(passage_pos)
		ExpansionAudit("RESTORE_TOKEN_RECORD", {
			token = token.token_id, record = index,
			surface_x = tostring(record.surface_x), surface_y = tostring(record.surface_y),
			underground_passage_x = tostring(passage_x),
			underground_passage_y = tostring(passage_y),
			angle = tostring(record.angle), restored = tostring(record.restored == true),
		}, map)
	end
	return token
end

local function CurrentElevatorRestoreToken(map, token_id)
	local token = type(map) == "table" and pending_underground_elevator_restores[map] or nil
	if type(token) ~= "table" or token.token_id == nil then return nil end
	if token_id ~= nil and token.token_id ~= token_id then return nil end
	if token.cancelled == true or underground_elevator_restore_tokens[token.token_id] ~= token then
		return nil
	end
	return token
end

local function SupplyGridSetFailure(token, stage, reason)
	ExpansionAudit("SUPPLY_INVARIANT_FAILED", {
		token = tostring(type(token) == "table" and token.token_id or nil),
		stage = tostring(stage), reason = tostring(reason),
		status = tostring(type(token) == "table" and token.status or nil),
		current_map = tostring(Global("CurrentMap")),
	}, type(token) == "table" and token.map or nil)
	return false, tostring(reason)
end

local function ValidateSupplyGridSet(token, map, stage, require_current)
	if type(token) ~= "table" or CurrentElevatorRestoreToken(token.map, token.token_id) ~= token then
		return SupplyGridSetFailure(token, stage, "stale or superseded map-generation token")
	end
	if map ~= token.map and map ~= token.source_map then
		return SupplyGridSetFailure(token, stage, "grid owner is outside the restore transaction")
	end
	if require_current ~= false and Global("CurrentMap") ~= token.map then
		return SupplyGridSetFailure(token, stage, "the intended underground map is not current")
	end
	local refs = CaptureSupplyGridRefs(map)
	local expected_width = type(map) == "table" and tonumber(rawget(map, "hex_width")) or nil
	local expected_height = type(map) == "table" and tonumber(rawget(map, "hex_height")) or nil
	if not expected_width or not expected_height then
		return SupplyGridSetFailure(token, stage, "map hex dimensions are unavailable")
	end
	if type(refs.connections) ~= "table" or not refs.electricity or not refs.water
		or not refs.overlay or not refs.object then
		return SupplyGridSetFailure(token, stage, "one or more supply MapVars are unavailable")
	end
	for _, name in ipairs({ "electricity", "water", "overlay", "object" }) do
		local width, height = SupplyGridDimensions(refs[name])
		if width ~= expected_width or height ~= expected_height then
			return SupplyGridSetFailure(token, stage,
				name .. " grid dimensions differ from the owning map")
		end
	end
	if map == token.map then
		for _, name in ipairs({ "connections", "electricity", "water", "overlay", "object" }) do
			local forbidden_owner = token.forbidden_refs and token.forbidden_refs[refs[name]]
			if forbidden_owner then
				return SupplyGridSetFailure(token, stage,
					"target map retains a surface-grid reference")
			end
		end
		if token.authoritative_refs then
			for _, name in ipairs({ "connections", "electricity", "water", "overlay", "object" }) do
				if token.authoritative_refs[name] ~= refs[name] then
					return SupplyGridSetFailure(token, stage,
						"target supply-grid reference changed during the transaction")
				end
			end
		else
			token.authoritative_refs = refs
		end
	end
	local electricity_w, electricity_h = SupplyGridDimensions(refs.electricity)
	local water_w, water_h = SupplyGridDimensions(refs.water)
	local overlay_w, overlay_h = SupplyGridDimensions(refs.overlay)
	local object_w, object_h = SupplyGridDimensions(refs.object)
	ExpansionAudit("SUPPLY_GRID_SET_VALID", {
		token = token.token_id, stage = tostring(stage), status = tostring(token.status),
		require_current = tostring(require_current ~= false),
		expected_dimensions = tostring(expected_width) .. "x" .. tostring(expected_height),
		electricity_dimensions = tostring(electricity_w) .. "x" .. tostring(electricity_h),
		water_dimensions = tostring(water_w) .. "x" .. tostring(water_h),
		overlay_dimensions = tostring(overlay_w) .. "x" .. tostring(overlay_h),
		object_dimensions = tostring(object_w) .. "x" .. tostring(object_h),
		current_map_is_target = tostring(Global("CurrentMap") == token.map),
	}, map)
	return true, refs, expected_width, expected_height
end

local function ValidateSupplyBuildingFootprint(token, building, resource, stage)
	local ok, refs, width, height = ValidateSupplyGridSet(token, token.map, stage, true)
	if not ok then return false, refs end
	if type(building) ~= "table" then
		return SupplyGridSetFailure(token, stage, "supply building is unavailable")
	end
	local city = rawget(building, "city")
	if city ~= token.map.City then
		return SupplyGridSetFailure(token, stage, "Elevator city does not belong to the target map")
	end
	local world_to_hex = Global("WorldToHex")
	local rotate = Global("HexRotate")
	local angle_to_direction = Global("HexAngleToDirection")
	if type(world_to_hex) ~= "function" or type(building.GetSupplyGridConnectionShapePoints) ~= "function" then
		return SupplyGridSetFailure(token, stage, "supply footprint APIs are unavailable")
	end
	local q, r = SafeCall(world_to_hex, building)
	local direction = type(angle_to_direction) == "function"
		and SafeCall(angle_to_direction, building) or 0
	local shape_ok, shape = pcall(building.GetSupplyGridConnectionShapePoints, building, resource)
	if not shape_ok or type(shape) ~= "table" or #shape == 0
		or type(q) ~= "number" or type(r) ~= "number" then
		return SupplyGridSetFailure(token, stage, "Elevator supply footprint could not be resolved")
	end
	for _, shape_point in ipairs(shape) do
		local local_q, local_r = SupplyPointXY(shape_point)
		local rotated_q, rotated_r = local_q, local_r
		if type(rotate) == "function" and type(direction) == "number" then
			rotated_q, rotated_r = SafeCall(rotate, local_q, local_r, direction)
		end
		local final_q = type(rotated_q) == "number" and q + rotated_q or nil
		local final_r = type(rotated_r) == "number" and r + rotated_r or nil
		local sx = type(final_q) == "number" and type(final_r) == "number"
			and final_q + final_r / 2 or nil
		local sy = final_r
		local in_bounds = type(sx) == "number" and type(sy) == "number"
			and sx >= 0 and sy >= 0 and sx < width and sy < height
		if not in_bounds then
			return SupplyGridSetFailure(token, stage, "supply-fragment coordinate is out of bounds")
		end
	end
	local element = resource and rawget(building, resource) or nil
	if type(element) == "table" then
		if rawget(element, "building") ~= building then
			return SupplyGridSetFailure(token, stage, "supply element belongs to a different building")
		end
		local grid = rawget(element, "grid")
		if grid and token.forbidden_refs and token.forbidden_refs[grid] then
			return SupplyGridSetFailure(token, stage, "Elevator element retains a surface-grid reference")
		end
		if grid then
			local fragment_resource = type(grid) == "table" and grid.supply_resource or nil
			if fragment_resource and fragment_resource ~= resource then
				return SupplyGridSetFailure(token, stage, "Elevator element uses the wrong supply fragment")
			end
			for _, candidate in ipairs(type(grid) == "table" and rawget(grid, "elements") or {}) do
				local owner = type(candidate) == "table" and rawget(candidate, "building") or nil
				local owner_city = type(owner) == "table" and rawget(owner, "city") or nil
				if owner and owner_city ~= token.map.City then
					return SupplyGridSetFailure(token, stage,
						"new underground fragment contains a surface-map element")
				end
			end
		end
	end
	return true, refs
end

local function CompleteElevatorRestoreTransactionIfReady(token)
	if CurrentElevatorRestoreToken(token.map, token.token_id) ~= token then return false end
	for _, record in ipairs(token.records) do
		local building = record.rebuilt_elevator
		local connected = building and token.connected[building]
		local merged = building and token.merged[building]
		if not building or not connected or not merged
			or connected.electricity ~= true or connected.water ~= true
			or merged.electricity ~= true or merged.water ~= true then
			return false
		end
	end
	token.status = "complete"
	token.completed_on_map = Global("CurrentMap")
	pending_underground_elevator_restores[token.map] = nil
	underground_elevator_restore_tokens[token.token_id] = nil
	token.map.SuperBigMapDeferredElevatorRestorePending = nil
	token.map.SuperBigMapDeferredElevatorRestoreToken = nil
	token.map.SuperBigMapDeferredElevatorRestoreCompletedToken = token.token_id
	for index, record in ipairs(token.records) do
		local building = record.rebuilt_elevator
		local building_x, building_y = SupplyPointXY(building and Engine.ObjectPos(building))
		local connected = building and token.connected[building] or {}
		local merged = building and token.merged[building] or {}
		ExpansionAudit("RESTORE_RECORD_COMPLETE", {
			token = token.token_id, record = index,
			x = tostring(building_x), y = tostring(building_y),
			linked_other = tostring(type(building) == "table" and rawget(building, "other")),
			electricity_connected = tostring(connected and connected.electricity == true),
			water_connected = tostring(connected and connected.water == true),
			electricity_merged = tostring(merged and merged.electricity == true),
			water_merged = tostring(merged and merged.water == true),
		}, token.map)
	end
	ExpansionAudit("RESTORE_TOKEN_COMPLETE", {
		token = token.token_id, records = #token.records,
		completed_on_target = tostring(token.completed_on_map == token.map),
		status = token.status,
	}, token.map)
	return true
end

local function CopySupplyFragmentSynchronously(token, city, fragment, resource, stage)
	local map = SupplyObjectMap(city)
	if not map and city == token.map.City then map = token.map end
	if not map and token.source_map and city == token.source_map.City then map = token.source_map end
	local ok, refs = ValidateSupplyGridSet(token, map, stage, false)
	if not ok then return false, refs end
	if Global("CurrentMap") ~= token.map then
		return SupplyGridSetFailure(token, stage, "underground map changed before synchronous overlay copy")
	end
	local connection = refs[resource]
	local total_points, out_of_bounds, missing_shapes =
		ValidateSupplyFragmentFootprint(connection, fragment, resource)
	if total_points < 1 or out_of_bounds ~= 0 or missing_shapes ~= 0 then
		return SupplyGridSetFailure(token, stage,
			"supply fragment failed the complete coordinate audit")
	end
	-- Do not call CopySupplyFragmentToOverlayGrid here. Its native implementation reads every
	-- footprint back through the connection grid and asserts when a cross-map Elevator merge is
	-- still inside the second element's GameInit. The overlay does not need that read: vanilla's
	-- unmerged branch obtains the fragment ID and applies it directly to the building shape. Do the
	-- same bounded operation for each element owned by this city after the complete coordinate audit.
	local get_overlay_index = Global("GetGridOverlayIndex")
	local apply_overlay_id = Global("ApplyIDToOverlayGrid")
	local shift = Global("shift")
	if type(get_overlay_index) ~= "function" or type(apply_overlay_id) ~= "function"
		or (resource == "water" and type(shift) ~= "function") then
		return SupplyGridSetFailure(token, stage, "bounded overlay-copy APIs are unavailable")
	end
	local overlay_id = get_overlay_index(fragment)
	if type(overlay_id) ~= "number" then
		return SupplyGridSetFailure(token, stage, "merged fragment has no overlay ID")
	end
	if resource == "water" then overlay_id = shift(overlay_id, 4) end
	local applied = 0
	for _, element in ipairs(type(fragment) == "table" and rawget(fragment, "elements") or {}) do
		local building = type(element) == "table" and rawget(element, "building") or nil
		local building_city = type(building) == "table" and rawget(building, "city") or nil
		local building_map = SupplyObjectMap(building)
		if building and (building_city == city or building_map == map) then
			local shape_ok, shape = pcall(building.GetSupplyGridConnectionShapePoints,
				building, resource)
			if not shape_ok or type(shape) ~= "table" or #shape == 0 then
				return SupplyGridSetFailure(token, stage,
					"bounded overlay copy could not resolve an Elevator footprint")
			end
			local apply_ok, apply_error = pcall(apply_overlay_id,
				refs.overlay, building, shape, overlay_id)
			if not apply_ok then
				return SupplyGridSetFailure(token, stage, "bounded overlay copy failed: " .. tostring(apply_error))
			end
			applied = applied + 1
		end
	end
	if applied < 1 then
		return SupplyGridSetFailure(token, stage,
			"bounded overlay copy found no fragment element owned by the target city")
	end
	ExpansionAudit("SUPPLY_OVERLAY_COPY_COMPLETE", {
		token = token.token_id, stage = tostring(stage), resource = tostring(resource),
		footprint_points = total_points, applied_buildings = applied,
		overlay_id = overlay_id, current_map_is_target = tostring(Global("CurrentMap") == token.map),
	}, map)
	return true
end

local function MergeSupplyFragmentsSynchronously(token, new_grid, grid, filter, resource, copy_overlay)
	local get_connections = Global("GetElementConnections")
	local destroy_connections = Global("DestroyAllConnectionsFromElement")
	local connect_grids = Global("ConnectGrids")
	if type(get_connections) ~= "function" or type(destroy_connections) ~= "function"
		or type(connect_grids) ~= "function" then
		return SupplyGridSetFailure(token, "synchronous fragment merge",
			"vanilla supply-fragment APIs are unavailable")
	end
	if grid ~= new_grid then
		local elements = rawget(grid, "elements") or {}
		for index = #elements, 1, -1 do
			local element = elements[index]
			if not filter or filter(element) then
				local element_connections = get_connections(element)
				local saved = {}
				if type(element_connections) == "table" then
					for i, pair in ipairs(element_connections) do saved[i] = pair end
				end
				destroy_connections(element)
				grid:RemoveElement(element)
				new_grid:AddElement(element)
				for _, pair in ipairs(saved) do connect_grids(pair[1], pair[2]) end
			end
		end
	end
	local remaining = type(rawget(grid, "elements")) == "table" and #grid.elements or 0
	if not filter and remaining ~= 0 then
		return SupplyGridSetFailure(token, "synchronous fragment merge",
			"vanilla full merge left elements behind")
	end
	if remaining == 0 and type(grid.delete) == "function" then grid:delete() end
	if copy_overlay ~= false and not rawget(new_grid, "grid_subtype") then
		for _, city in ipairs(rawget(new_grid, "cities") or {}) do
			local copied, copy_error = CopySupplyFragmentSynchronously(token, city, new_grid,
				resource, "synchronous merged-fragment overlay copy")
			if not copied then return false, copy_error end
		end
	end
	return true
end

local function TaggedListContains(list, field, value)
	for _, item in ipairs(list) do
		if item[field] == value then return true end
	end
	return false
end

-- Vanilla SupplyGridConnectElement schedules an opaque game-time callback only when it merges
-- multiple neighbouring fragments. For a tagged restored Elevator, reproduce the normal-building
-- branch with the same public engine primitives and perform that merge/copy synchronously. This is
-- intentionally narrow: construction grids, switches, domes, and every untagged object retain the
-- original class method.
local function ConnectTaggedElevatorElementSynchronously(token, building, element,
	grid_class, new_grid_skin, force_create_connections)
	local resource = type(grid_class) == "table" and grid_class.supply_resource or nil
	if resource ~= "electricity" and resource ~= "water" then
		return SupplyGridSetFailure(token, "tagged synchronous element connection",
			"unsupported Elevator supply resource")
	end
	local valid, why = ValidateSupplyBuildingFootprint(token, building, resource,
		"before tagged synchronous element connection")
	if not valid then return false, why end
	local is_obj_in_dome = Global("IsObjInDome")
	if type(is_obj_in_dome) == "function" and is_obj_in_dome(building) then
		return SupplyGridSetFailure(token, "tagged synchronous element connection",
			"deferred underground Elevator unexpectedly belongs to a dome")
	end
	local has_member = type(building.HasMember) == "function"
	local construction_connections = has_member
		and SafeCall(building.HasMember, building, "construction_connections") == true
		and building.construction_connections ~= -1 and building.construction_connections or 0
	if building.connect_dir or construction_connections ~= 0 then
		return SupplyGridSetFailure(token, "tagged synchronous element connection",
			"unexpected preferred/construction connection state")
	end
	local apply_building = Global("SupplyGridApplyBuilding")
	local get_object_grid = Global("GetObjectHexGrid")
	local are_connected = Global("AreGridsConnected")
	local connect_grids = Global("ConnectGrids")
	local copy_grid_connections = Global("CopyGridConnections")
	local get_overlay_index = Global("GetGridOverlayIndex")
	local apply_overlay_id = Global("ApplyIDToOverlayGrid")
	local shift = Global("shift")
	if type(apply_building) ~= "function" or type(get_object_grid) ~= "function"
		or type(are_connected) ~= "function" or type(connect_grids) ~= "function"
		or type(copy_grid_connections) ~= "function"
		or type(get_overlay_index) ~= "function" or type(apply_overlay_id) ~= "function"
		or (resource == "water" and type(shift) ~= "function") then
		return SupplyGridSetFailure(token, "tagged synchronous element connection",
			"vanilla supply connection APIs are unavailable")
	end
	local refs = token.authoritative_refs
	local connection_grid = refs and refs[resource]
	local shape = building:GetSupplyGridConnectionShapePoints(resource)
	local shape_connections = building:GetShapeConnections(resource)
	local potential_neighbours = apply_building(connection_grid, building, shape,
		shape_connections, nil, false)
	-- The native engine result is an indexable point sequence, but it is not guaranteed to be
	-- represented as a plain Lua table. Vanilla only applies # and numeric indexing to it. Preserve
	-- that contract and additionally require complete point pairs before consuming the sequence.
	local neighbour_length_ok, neighbour_point_count = pcall(function()
		return #potential_neighbours
	end)
	if not neighbour_length_ok or type(neighbour_point_count) ~= "number"
		or neighbour_point_count < 0 or neighbour_point_count % 2 ~= 0 then
		return SupplyGridSetFailure(token, "tagged synchronous element connection",
			"SupplyGridApplyBuilding returned an invalid neighbour sequence")
	end
	new_grid_skin = new_grid_skin or (has_member
		and SafeCall(building.HasMember, building, "construction_grid_skin") == true
		and building.construction_grid_skin)
	local object_grid = get_object_grid(building)
	if not object_grid or type(object_grid.GetObjectAtPos) ~= "function" then
		return SupplyGridSetFailure(token, "tagged synchronous element connection",
			"object grid is unavailable")
	end
	local built_connections = {}
	local create_connection_call_data = {}
	local grid
	local grids_merged = false
	local function should_skip(other_grid)
		local ignore_grid_to_grid = not other_grid.grid_subtype
			and IsKindOfSafe(building, "Building")
		for _, entry in ipairs(built_connections) do
			local connected_grid = entry[1]
			if (ignore_grid_to_grid and connected_grid == other_grid)
				or (not ignore_grid_to_grid and are_connected(connected_grid, other_grid)) then
				return true
			end
		end
		return false
	end
	for index = 1, neighbour_point_count, 2 do
		local point_a, point_b = potential_neighbours[index], potential_neighbours[index + 1]
		local adjacent = object_grid:GetObjectAtPos(point_b, nil, nil,
			function(object) return object[resource] end)
		local adjacent_element = adjacent and adjacent[resource]
		local adjacent_grid = type(adjacent_element) == "table" and adjacent_element.grid or nil
		if not adjacent_grid then
			return SupplyGridSetFailure(token, "tagged synchronous element connection",
				"native neighbour has no supply fragment")
		end
		local force_connect = (IsKindOfSafe(building, "Building")
			and not IsKindOfSafe(building, "LifeSupportGridElement")
			and IsKindOfSafe(adjacent, "LifeSupportGridElement"))
			or (IsKindOfSafe(building, "LifeSupportGridElement")
				and IsKindOfSafe(adjacent, "Building")
				and not IsKindOfSafe(adjacent, "LifeSupportGridElement"))
		if not grid then
			if not should_skip(adjacent_grid)
				or (force_connect and not TaggedListContains(built_connections, 2, adjacent_element))
				or not TaggedListContains(built_connections, 1, adjacent_grid) then
				create_connection_call_data[#built_connections + 1] = {
					point_a, point_b, building, adjacent,
				}
				built_connections[#built_connections + 1] = { adjacent_grid, adjacent_element }
			end
			if not adjacent_grid.grid_subtype then
				grid = adjacent_grid
				grid:AddElement(element)
			end
		else
			if force_create_connections and adjacent_grid == grid then
				create_connection_call_data[#built_connections + 1] = {
					point_a, point_b, building, adjacent,
				}
				built_connections[#built_connections + 1] = { adjacent_grid, adjacent_element }
			elseif adjacent_grid ~= grid and adjacent_grid.grid_subtype == grid.grid_subtype then
				if not should_skip(adjacent_grid) then
					if not TaggedListContains(built_connections, 1, adjacent_grid) then
						create_connection_call_data[#built_connections + 1] = {
							point_a, point_b, building, adjacent,
						}
						built_connections[#built_connections + 1] = { adjacent_grid, adjacent_element }
					end
					grids_merged = grid
					for _, moved_element in ipairs(adjacent_grid.elements or {}) do
						grid:AddElement(moved_element)
					end
					copy_grid_connections(adjacent_grid, grid)
					adjacent_grid:delete()
				end
			elseif (force_connect and not TaggedListContains(built_connections, 2, adjacent_element))
				or (not are_connected(grid, adjacent_grid) and not should_skip(adjacent_grid)) then
				create_connection_call_data[#built_connections + 1] = {
					point_a, point_b, building, adjacent,
				}
				built_connections[#built_connections + 1] = { adjacent_grid, adjacent_element }
			end
		end
	end
	local city = rawget(building, "city") or token.map.City
	if not grid then
		local params = { city = city, element_skin = new_grid_skin }
		local create = type(grid_class) == "table" and grid_class.new
		if type(create) ~= "function" then
			return SupplyGridSetFailure(token, "tagged synchronous element connection",
				"supply grid constructor is unavailable")
		end
		grid = create(grid_class, params, token.map)
		if not grid then
			return SupplyGridSetFailure(token, "tagged synchronous element connection",
				"supply grid constructor failed")
		end
		grid:AddElement(element)
	elseif new_grid_skin and grids_merged and type(grids_merged.ChangeElementSkin) == "function" then
		grids_merged:ChangeElementSkin(new_grid_skin, nil, true)
	end
	for index, entry in ipairs(built_connections) do
		local other_grid, adjacent_element = entry[1], entry[2]
		local connection_data = create_connection_call_data[index]
		if connection_data then
			grid_class.CreateConnection(Unpack(connection_data, 1, 4))
		end
		if other_grid ~= grid and other_grid.grid_subtype ~= grid.grid_subtype then
			connect_grids(element, adjacent_element)
		end
	end
	if not grid.grid_subtype then
		if grids_merged then
			local copied, copy_error = CopySupplyFragmentSynchronously(token, city, grid,
				resource, "synchronous local merged-fragment overlay copy")
			if not copied then return false, copy_error end
		else
			local overlay_id = get_overlay_index(grid)
			if resource == "water" then overlay_id = shift(overlay_id, 4) end
			apply_overlay_id(refs.overlay, building, shape, overlay_id)
		end
	end
	return true
end

local function MergeTaggedElevatorGridsSynchronously(building, resource, token)
	local valid, why = ValidateSupplyBuildingFootprint(token, building, resource,
		"before synchronous passage-grid merge")
	if not valid then return false, why end
	local element = rawget(building, resource)
	local my_grid = type(element) == "table" and rawget(element, "grid") or nil
	if not my_grid then
		return true
	end
	local other = rawget(building, "other")
	local other_element = type(other) == "table" and rawget(other, resource) or nil
	local other_grid = type(other_element) == "table" and rawget(other_element, "grid") or nil
	if my_grid and other_grid and my_grid ~= other_grid then
		local other_map = SupplyObjectMap(other) or token.source_map
		local source_ok, source_error = ValidateSupplyGridSet(token, other_map,
			"before synchronous source passage-grid merge", false)
		if not source_ok then return false, source_error end
		if other_map ~= token.source_map
			or rawget(other, "city") ~= (token.source_map and token.source_map.City) then
			return SupplyGridSetFailure(token, "synchronous passage-grid merge",
				"linked Elevator does not belong to the captured source map")
		end
		local visit = Global("VisitConnectedElements")
		if type(visit) ~= "function" then
			return SupplyGridSetFailure(token, "synchronous passage-grid merge",
				"VisitConnectedElements is unavailable")
		end
		local visited_grids, visited_elements = {}, {}
		visit(element, resource, 0, 16384 + 64, false, visited_grids, visited_elements)
		local merged, merge_error = MergeSupplyFragmentsSynchronously(token, my_grid, other_grid,
			function(candidate) return visited_elements[candidate] end, resource)
		for _, visited in ipairs(visited_grids) do
			if visited and type(visited.free) == "function" then visited:free() end
		end
		if not merged then return false, merge_error end
	elseif my_grid and not rawget(my_grid, "grid_subtype") then
		local copied, copy_error = CopySupplyFragmentSynchronously(token, token.map.City,
			my_grid, resource, "synchronous unmerged-fragment overlay copy")
		if not copied then return false, copy_error end
	end
	token.merged[building] = token.merged[building] or {}
	token.merged[building][resource] = true
	CompleteElevatorRestoreTransactionIfReady(token)
	return true
end

local function PatchElevatorSupplyTransactionBoundary(source)
	local State = SuperBigMap.State
	local supply_class = Engine.ClassTable and Engine.ClassTable("SupplyGridObject")
	local passage_class = Engine.ClassTable and Engine.ClassTable("MapPassageLinked")
	local elevator_class = Engine.ClassTable and Engine.ClassTable("Elevator")
	if type(supply_class) ~= "table" or type(passage_class) ~= "table"
		or type(elevator_class) ~= "table" then
		return false
	end
	if State.elevator_supply_boundary_patch_version == GENERATOR_PATCH_VERSION
		and elevator_class.SupplyGridConnectElement == State.elevator_supply_connect_wrapper
		and elevator_class.MergeGrids == State.elevator_passage_merge_wrapper then
		return true
	end
	if elevator_class.SupplyGridConnectElement == State.elevator_supply_connect_wrapper
		and type(State.original_elevator_supply_connect) == "function" then
		elevator_class.SupplyGridConnectElement = State.original_elevator_supply_connect
	end
	if elevator_class.MergeGrids == State.elevator_passage_merge_wrapper
		and type(State.original_elevator_passage_merge_grids) == "function" then
		elevator_class.MergeGrids = State.original_elevator_passage_merge_grids
	end
	local original_connect = elevator_class.SupplyGridConnectElement
	local original_merge = elevator_class.MergeGrids
	if type(original_connect) ~= "function" or type(original_merge) ~= "function" then return false end
	local connect_wrapper = function(building, element, grid_class, new_grid_skin,
		force_create_connections)
		local token_id = type(building) == "table" and rawget(building, "SuperBigMapElevatorRestoreToken")
		local token = token_id and underground_elevator_restore_tokens[token_id] or nil
		if not token then
			return original_connect(building, element, grid_class, new_grid_skin,
				force_create_connections)
		end
		local resource = type(grid_class) == "table" and grid_class.supply_resource or nil
		ExpansionAudit("SUPPLY_CONNECT_BEGIN", {
			token = token.token_id, resource = tostring(resource),
			record = tostring(rawget(building, "SuperBigMapElevatorRestoreRecord")),
			had_grid = tostring(type(element) == "table" and rawget(element, "grid") ~= false),
		}, token.map)
		local ok, why = ValidateSupplyBuildingFootprint(token, building, resource,
			"before vanilla SupplyGridConnectElement")
		if not ok then error("blocked unsafe underground Elevator supply connection: " .. tostring(why)) end
		if rawget(element, "grid") ~= false then
			-- This object is a freshly recreated transaction member, so an attached fragment can only
			-- be stale work from an older lifecycle pass. Detach it without invoking the native
			-- disconnect path (which would consume the stale grid), then let vanilla build a fresh
			-- fragment against the already-validated current map.
			local stale_grid = rawget(element, "grid")
			if stale_grid and type(stale_grid.RemoveElement) == "function" then
				pcall(stale_grid.RemoveElement, stale_grid, element)
			end
			element.grid = false
		end
		local connected, connect_error = ConnectTaggedElevatorElementSynchronously(token,
			building, element, grid_class, new_grid_skin, force_create_connections)
		if not connected then
			error("underground Elevator synchronous supply connection failed: "
				.. tostring(connect_error))
		end
		local after_ok, after_why = ValidateSupplyBuildingFootprint(token, building, resource,
			"after synchronous SupplyGridConnectElement")
		if not after_ok or not rawget(element, "grid") then
			error("underground Elevator supply fragment failed post-connect validation: "
				.. tostring(after_why or "missing fragment"))
		end
		token.connected[building] = token.connected[building] or {}
		token.connected[building][resource] = true
		ExpansionAudit("SUPPLY_CONNECT_COMPLETE", {
			token = token.token_id, resource = tostring(resource),
			record = tostring(rawget(building, "SuperBigMapElevatorRestoreRecord")),
			fragment = tostring(type(element) == "table" and rawget(element, "grid")),
		}, token.map)
		local other = rawget(building, "other")
		local other_element = type(other) == "table" and rawget(other, resource) or nil
		if type(other_element) == "table" and rawget(other_element, "grid") then
			local merged, merge_error = MergeTaggedElevatorGridsSynchronously(
				building, resource, token)
			if not merged then
				error("underground Elevator supply fragment merge failed after connection: "
					.. tostring(merge_error))
			end
		end
		CompleteElevatorRestoreTransactionIfReady(token)
		return
	end
	local merge_wrapper = function(building, resource, ...)
		local token_id = type(building) == "table" and rawget(building, "SuperBigMapElevatorRestoreToken")
		local token = token_id and underground_elevator_restore_tokens[token_id] or nil
		if not token then return original_merge(building, resource, ...) end
		ExpansionAudit("SUPPLY_MERGE_BEGIN", {
			token = token.token_id, resource = tostring(resource),
			record = tostring(rawget(building, "SuperBigMapElevatorRestoreRecord")),
		}, token.map)
		local ok, why = MergeTaggedElevatorGridsSynchronously(building, resource, token)
		if not ok then error("blocked unsafe underground Elevator passage-grid merge: " .. tostring(why)) end
		ExpansionAudit("SUPPLY_MERGE_COMPLETE", {
			token = token.token_id, resource = tostring(resource),
			record = tostring(rawget(building, "SuperBigMapElevatorRestoreRecord")),
		}, token.map)
		return true
	end
	State.original_elevator_supply_connect = original_connect
	State.original_elevator_passage_merge_grids = original_merge
	State.elevator_supply_connect_wrapper = connect_wrapper
	State.elevator_passage_merge_wrapper = merge_wrapper
	State.elevator_supply_boundary_patch_version = GENERATOR_PATCH_VERSION
	elevator_class.SupplyGridConnectElement = connect_wrapper
	elevator_class.MergeGrids = merge_wrapper
	return true
end

-- Native CopySupplyFragmentToOverlayGrid asserts in C instead of returning a Lua error when its
-- overlay and connection grids disagree. Keep vanilla untouched for normal maps, but fail closed
-- on an expanded map if a future lifecycle regression presents incompatible MapVars. The ordering
-- correction below should make this guard a no-op.
local function PatchSupplyGridOverlayCopyGuard(source)
	local State = SuperBigMap.State
	local current = Global("CopySupplyFragmentToOverlayGrid")
	if current == State.supply_grid_overlay_copy_wrapper
		and State.supply_grid_overlay_copy_patch_version == GENERATOR_PATCH_VERSION then
		return true
	end
	if current == State.supply_grid_overlay_copy_wrapper
		and type(State.original_supply_grid_overlay_copy) == "function" then
		current = State.original_supply_grid_overlay_copy
		rawset(_G, "CopySupplyFragmentToOverlayGrid", current)
	end
	if type(current) ~= "function" then
		return false
	end
	State.original_supply_grid_overlay_copy = current
	local captured_original = current
	local wrapper = function(overlay, connection_grid, city, fragment, ...)
		local map = city and type(city.GetMap) == "function" and SafeCall(city.GetMap, city)
			or Global("CurrentMap")
		if IsExpandedSupplyContext(map) then
			local ow, oh = SupplyGridDimensions(overlay)
			local cw, ch = SupplyGridDimensions(connection_grid)
			if not ow or not oh or not cw or not ch or ow ~= cw or oh ~= ch then
				return false
			end
		end
		return captured_original(overlay, connection_grid, city, fragment, ...)
	end
	rawset(_G, "CopySupplyFragmentToOverlayGrid", wrapper)
	State.supply_grid_overlay_copy_wrapper = wrapper
	State.supply_grid_overlay_copy_patch_version = GENERATOR_PATCH_VERSION
	return true
end

local function FinalizePendingUndergroundElevators(map, reason)
	local token = CurrentElevatorRestoreToken(map)
	if not token then return true, 0 end
	local records = token.records
	if type(records) ~= "table" or #records == 0 then return true, 0 end
	ExpansionAudit("RESTORE_LIFECYCLE_BEGIN", {
		token = token.token_id, records = #records, reason = tostring(reason),
		status = tostring(token.status), current_map_is_target = tostring(Global("CurrentMap") == map),
	}, map)
	local ready, ready_reason = ValidateSupplyGridSet(token, map,
		"lifecycle restore boundary: " .. tostring(reason), true)
	if not ready then return false, ready_reason end
	if not PatchElevatorSupplyTransactionBoundary("FinalizePendingUndergroundElevators") then
		return false, "Elevator supply transaction boundary is unavailable"
	end
	token.status = "restoring"
	token.lifecycle_reason = tostring(reason)
	local function transaction_guard(stage, guarded_map, building, record, index)
		local building_pos = type(building) == "table" and Engine.ObjectPos(building) or nil
		local building_x, building_y = SupplyPointXY(building_pos)
		local passage_pos = type(record) == "table" and record.underground_passage
			and Engine.ObjectPos(record.underground_passage) or nil
		local passage_x, passage_y = SupplyPointXY(passage_pos)
		ExpansionAudit("RESTORE_RECORD_STAGE", {
			token = token.token_id, record = tostring(index), stage = tostring(stage),
			status = tostring(token.status), target_map_matches = tostring(guarded_map == map),
			building_x = tostring(building_x), building_y = tostring(building_y),
			passage_x = tostring(passage_x), passage_y = tostring(passage_y),
			current_map_is_target = tostring(Global("CurrentMap") == map),
		}, map)
		if CurrentElevatorRestoreToken(map, token.token_id) ~= token then
			return false, "stale map-generation token"
		end
		if guarded_map ~= map then return false, "restore changed its target map" end
		local ok, why = ValidateSupplyGridSet(token, map,
			"restore guard " .. tostring(stage), true)
		if not ok then return false, why end
		if (stage == "before-create" or stage == "after-create")
			and type(building) == "table" then
			building.SuperBigMapElevatorRestoreToken = token.token_id
			building.SuperBigMapElevatorRestoreRecord = index
		elseif building and (stage == "after-position" or stage == "before-apply-grids"
			or stage == "before-construction-complete" or stage == "after-construction-complete") then
			for _, resource in ipairs({ "electricity", "water" }) do
				local footprint_ok, footprint_reason = ValidateSupplyBuildingFootprint(token,
					building, resource, "restore guard " .. tostring(stage))
				if not footprint_ok then return false, footprint_reason end
			end
		end
		return true
	end
	local ok, rebuilt = pcall(RestoreDeferredElevatorMigration, map, records,
		reason or "current-map lifecycle event", transaction_guard)
	if not ok then
		token.status = "failed"
		token.failure = tostring(rebuilt)
		ExpansionAudit("RESTORE_LIFECYCLE_FAILED", {
			token = token.token_id, reason = tostring(reason), error = tostring(rebuilt),
		}, map)
		return false, tostring(rebuilt)
	end
	if rebuilt ~= #records then
		token.status = "failed"
		return false, "rebuilt " .. tostring(rebuilt) .. " of " .. tostring(#records)
	end
	CompleteElevatorRestoreTransactionIfReady(token)
	if token.status ~= "complete" then token.status = "awaiting-supply-gameinit" end
	ExpansionAudit("RESTORE_LIFECYCLE_END", {
		token = token.token_id, records = #records, rebuilt = tostring(rebuilt),
		status = tostring(token.status),
	}, map)
	return true, rebuilt
end

local function HandlePendingUndergroundElevatorRestore(map_slot, map, reason)
	local token = CurrentElevatorRestoreToken(map)
	if not token then
		ExpansionAudit("RESTORE_HANDLER_NO_PENDING_TOKEN", {
			map_slot = tostring(map_slot), reason = tostring(reason),
			completed_token = tostring(map and map.SuperBigMapDeferredElevatorRestoreCompletedToken),
		}, map)
		return true, 0
	end
	ExpansionAudit("RESTORE_HANDLER_ENTER", {
		token = token.token_id, status = tostring(token.status),
		map_slot = tostring(map_slot), reason = tostring(reason),
	}, map)
	if token.status ~= "queued" then
		return token.status ~= "failed", token.failure or token.status
	end
	local ok, result = FinalizePendingUndergroundElevators(map,
		reason or "CurrentMapChangeDone")
	if not ok then
		map.SuperBigMapUndergroundPreparationFailed = true
		map.SuperBigMapUndergroundStretchFailed = tostring(result)
	end
	return ok, result
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
		or destination.SuperBigMapExpansionPending ~= true then
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

	SetLoadingPhase("Generating the exact vanilla source terrain...")
	LoadingStep("temporary source transaction begin", {
		destination_slot = destination_slot, source_slot = source_slot,
		source_tiles = tostring(source_width) .. "x" .. tostring(source_height),
		destination_tiles = tostring(desired_width) .. "x" .. tostring(desired_height),
		pass_border = pass_border,
	}, destination)
	local source
	local source_baseline
	local native_enrichment_records
	local native_enrichment_excluded
	local native_enrichment_record_stats
	local source_generated_enrichments
	local vanilla_start_selection
	local saved_main_map = Global("MainMap")
	local saved_main_city = Global("MainCity")
	local results
	SuperBigMap.State.vanilla_source_migration_active = true
	local ok, migration_error = pcall(function()
		local allocation_token = LoadingBegin("allocate temporary vanilla backing", destination,
			{ source_slot = source_slot })
		local allocation_error = change_map_in_slot(source_slot, blank_map, source_instance)
		LoadingEnd(allocation_token, { error = tostring(allocation_error) }, allocation_error == nil)
		if allocation_error then error("temporary source ChangeMapInSlot: " .. tostring(allocation_error)) end
		source = maps[source_slot]
		if not source then error("temporary source map was not created") end
		local terrain_api = Global("terrain")
		local actual_width, actual_height
		if type(terrain_api) == "table" and type(terrain_api.HeightMapSize) == "function" then
			actual_width, actual_height = terrain_api.HeightMapSize(source)
			actual_height = actual_height or actual_width
		end
		if actual_width ~= source_width or actual_height ~= source_height then
			error(string.format("temporary source backing is not native-sized: got %sx%s expected %sx%s",
				tostring(actual_width), tostring(actual_height), tostring(source_width), tostring(source_height)))
		end
		source_baseline = SnapshotMapObjectSet(source)
		local baseline_count = 0
		if type(source_baseline) == "table" then
			for _ in pairs(source_baseline) do baseline_count = baseline_count + 1 end
		end
		LoadingStep("temporary source backing verified", {
			actual_tiles = tostring(actual_width) .. "x" .. tostring(actual_height),
			baseline_objects = baseline_count,
		}, source)

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
		if type(source.SuspendPassEdits) == "function" then source:SuspendPassEdits("SuperBigMapVanillaSourceMigration") end
		local generator_token = LoadingBegin("vanilla RandomMapGenerator.DoGenerate", source)
		if generator_token then
			local timed_results = PackValues(pcall(original_do_generate, generator, source,
				Unpack(call_args, 1, call_args.n)))
			LoadingEnd(generator_token, nil, timed_results[1] == true)
			if not timed_results[1] then error(timed_results[2]) end
			results = { n = timed_results.n - 1 }
			for result_index = 2, timed_results.n do
				results[result_index - 1] = timed_results[result_index]
			end
		else
			results = PackValues(original_do_generate(generator, source,
				Unpack(call_args, 1, call_args.n)))
		end
		local update_radius = Global("UpdateMapMaxObjRadius")
		if type(update_radius) == "function" then update_radius(source) end
		if type(source.ResumePassEdits) == "function" then source:ResumePassEdits("SuperBigMapVanillaSourceMigration") end
		source_generated_enrichments = CaptureGeneratedNativeEnrichments(
			source, "temporary vanilla backing generation complete")
		local deposits = SuperBigMap.DepositRules
		if not deposits or type(deposits.CaptureNativeEnrichmentRecords) ~= "function" then
			error("native enrichment value-record capture API unavailable")
		end
		native_enrichment_records, native_enrichment_excluded, native_enrichment_record_stats =
			deposits.CaptureNativeEnrichmentRecords(
				source, "temporary vanilla backing generation complete")
		LoadingStep("native enrichment records captured", {
			coordinate_count = source_generated_enrichments,
			record_count = native_enrichment_record_stats and native_enrichment_record_stats.count,
			record_signature = native_enrichment_record_stats and native_enrichment_record_stats.signature,
		}, source)
		if native_enrichment_record_stats.count ~= source_generated_enrichments then
			error(string.format("native enrichment coordinate/value capture mismatch: coordinates=%s records=%s",
				tostring(source_generated_enrichments),
				tostring(native_enrichment_record_stats.count)))
		end
		-- Capture the start choice at the same native-source boundary as enrichments. The final
		-- destination temporarily has no live markers until post-stretch recreation, so waiting for
		-- its InitialExplore would make vanilla choose from an empty or unrelated 20x20 set.
		local sectors = SuperBigMap.SectorExploration
		if not sectors or type(sectors.CaptureVanillaStartSelection) ~= "function" then
			error("native start-sector annotation API unavailable")
		end
		local start_capture_ok, selection, selection_error = pcall(
			sectors.CaptureVanillaStartSelection, source)
		if not (start_capture_ok and selection) then
			error("native start-sector annotation failed: "
				.. tostring(start_capture_ok and selection_error or selection))
		end
		vanilla_start_selection = selection
		LoadingStep("vanilla initial sector captured", {
			selection = tostring(selection),
		}, source)

		rawset(_G, "MainMap", saved_main_map)
		rawset(_G, "MainCity", saved_main_city)
		RestoreGeneratorTemplate()
		SwitchGeneratorCurrentSlot(destination_slot)
		SetLoadingPhase("Migrating the vanilla source into the expanded terrain...")
		local terrain_copy_token = LoadingBegin("copy native terrain to destination", destination)
		CopyMigratedTerrain(source, destination)
		LoadingEnd(terrain_copy_token, nil, true)
		local state_copy_token = LoadingBegin("copy generated map state", destination)
		CopyGeneratedMapState(source, destination)
		LoadingEnd(state_copy_token, nil, true)
		if type(deposits.StageNativeEnrichmentRecords) ~= "function" then
			error("native enrichment staging API unavailable")
		end
		local staged, stage_error = deposits.StageNativeEnrichmentRecords(destination,
			native_enrichment_records, "temporary vanilla backing migrated to destination")
		if staged ~= true then error("native enrichment staging failed: " .. tostring(stage_error)) end
		LoadingStep("native enrichment records staged on destination", {
			record_count = #native_enrichment_records,
		}, destination)
		local object_transfer_token = LoadingBegin("transfer generated non-enrichment objects", destination)
		local transferred = TransferGeneratedObjects(source, destination, source_baseline,
			native_enrichment_excluded)
		LoadingEnd(object_transfer_token, { transferred = tostring(transferred) }, true)
		-- The normal expanded-backing tail consumes these optional smoothing records immediately.
		-- This path deliberately preserves the vanilla-generated height field, so discard their
		-- temporary-map references instead of allowing a later map generation to consume stale pads.
		SuperBigMap.State.sbm_entrance_pads = nil

		local box_fn = Global("box")
		local map_width, map_height = destination:GetMapSize()
		if type(destination.RebuildGrids) ~= "function" or type(box_fn) ~= "function" then
			error("destination RebuildGrids API unavailable")
		end
		local rebuild_token = LoadingBegin("rebuild destination grids after source migration", destination)
		destination:RebuildGrids(box_fn(0, 0, map_width, map_height))
		LoadingEnd(rebuild_token, nil, true)
		destination.SuperBigMapSurfaceBuildableCurrent = true
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
		local unload_token = LoadingBegin("unload temporary vanilla backing", destination,
			{ source_slot = source_slot })
		local unload_ok, unload_error = pcall(change_map_in_slot, source_slot, "")
		LoadingEnd(unload_token, { error = tostring(unload_error) }, unload_ok)
		if not unload_ok and ok then
			ok, migration_error = false, "temporary source unload failed: " .. tostring(unload_error)
		end
	end
	if ok and native_enrichment_records then
		local deposits = SuperBigMap.DepositRules
		local verify_call_ok, records_ok, record_verify_stats = pcall(
			deposits.VerifyStagedNativeEnrichmentRecords, destination,
			native_enrichment_record_stats.count, native_enrichment_record_stats.signature,
			"after temporary source slot unload")
		if not (verify_call_ok and records_ok == true) then
			ok = false
			migration_error = "native enrichment records did not survive source unload: "
				.. tostring(verify_call_ok and record_verify_stats and record_verify_stats.reason or records_ok)
		end
		LoadingStep("staged enrichment records survived source unload", {
			verified = tostring(verify_call_ok and records_ok == true),
			record_count = native_enrichment_record_stats and native_enrichment_record_stats.count,
		}, destination)
	end
	if ok and vanilla_start_selection then
		local sectors = SuperBigMap.SectorExploration
		local stage_call_ok, staged, stage_error = pcall(
			sectors.StageVanillaStartSelection, destination, vanilla_start_selection,
			"temporary vanilla source migrated and unloaded")
		if not (stage_call_ok and staged == true) then
			ok = false
			migration_error = "native start-sector annotation did not survive migration: "
				.. tostring(stage_call_ok and stage_error or staged)
		end
	end
	if not ok then
		local deposits = SuperBigMap.DepositRules
		if deposits and type(deposits.ClearStagedNativeEnrichmentRecords) == "function" then
			pcall(deposits.ClearStagedNativeEnrichmentRecords, destination,
				"temporary source migration failed")
		end
		local sectors = SuperBigMap.SectorExploration
		if sectors and type(sectors.ClearPendingVanillaStartSelection) == "function" then
			pcall(sectors.ClearPendingVanillaStartSelection, destination,
				"temporary source migration failed")
		end
	end
	SuperBigMap.State.vanilla_source_migration_active = false
	if not ok then error("temporary vanilla source migration failed: " .. tostring(migration_error)) end
	SetLoadingPhase("Finishing the expanded map...")
	LoadingStep("temporary source transaction complete", nil, destination)
	return true, results
end

-- The underground generator's stock PlaceArtefacts procedure combines two unrelated jobs:
-- spawning every buried wonder and creating the two linked surface/underground passage anchors.
-- The former is expensive because its final ResumePassEdits processes every created object, while the
-- latter must exist before the player can place an Elevator.  Expanded maps therefore execute this
-- source-equivalent passage half during generation and retain the wonder markers, with their
-- already-shuffled vanilla class assignments, for first underground access.
local function ArtefactMapGet(map, class_name)
	if not map or type(map.MapGet) ~= "function" then return {} end
	local ok, objects = pcall(map.MapGet, map, "map", class_name)
	return ok and type(objects) == "table" and objects or {}
end

local function ArtefactApplyMarkerProperties(object, marker)
	local const_tbl = Global("const")
	local pos = marker:GetPos()
	if pos and type(pos.SetInvalidZ) == "function" then pos = pos:SetInvalidZ() end
	object:SetPos(pos)
	object:SetMirrored(marker:GetMirrored())
	object:SetAxis(marker:GetAxis())
	object:SetAngle(marker:GetAngle())
	object:SetScale(marker:GetScale())
	object:SetColorModifier(marker:GetColorModifier())
	if type(const_tbl) == "table" and const_tbl.gofPermanent then
		object:SetGameFlags(const_tbl.gofPermanent)
	end
end

local function ArtefactSpawnMarkerBuilding(marker, class_name, map)
	local place_building = Global("PlaceBuildingIn")
	local building = place_building(class_name, map)
	ArtefactApplyMarkerProperties(building, marker)
	return building
end

local function ArtefactClearObstructions(object, obj_prefab_marker, landscape_pos, shape)
	local clear = Global("ClearObstructions")
	local flatten_shape = shape
	if not flatten_shape and type(object.GetFlattenShape) == "function" then
		flatten_shape = object:GetFlattenShape()
	end
	return clear(object:GetMap(), object:GetPos(), object:GetAngle(), obj_prefab_marker,
		landscape_pos, flatten_shape)
end

local function DeferredArtefactPreflight(map)
	local required = {
		PlaceBuildingIn = Global("PlaceBuildingIn"),
		SpawnUndergroundPassage = Global("SpawnUndergroundPassage"),
		ClearObstructions = Global("ClearObstructions"),
		GetExtendedSpawnShape = Global("GetExtendedSpawnShape"),
		FlattenTerrainInBuildShape = Global("FlattenTerrainInBuildShape"),
		HexShapeForEach = Global("HexShapeForEach"),
		HexToWorld = Global("HexToWorld"),
		WorldToHex = Global("WorldToHex"),
		buildUnbuildableZ = Global("buildUnbuildableZ"),
		DoneObject = Global("DoneObject"),
		point = Global("point"),
		RGB = Global("RGB"),
	}
	for name, fn in pairs(required) do
		if type(fn) ~= "function" then return false, name .. " is unavailable" end
	end
	if not map or type(map.MapGet) ~= "function"
		or type(map.SuspendPassEdits) ~= "function" or type(map.ResumePassEdits) ~= "function"
		or type(map.buildable) ~= "table" or type(map.buildable.GetZ) ~= "function" then
		return false, "underground map grids or passage-edit methods are unavailable"
	end
	return true
end

local function VerifyBootstrapPassages(map, passages, expected)
	local surface_map = Global("MainMap")
	local linked, committed_pairs = 0, 0
	for index, underground_passage in ipairs(passages or {}) do
		local surface_passage = underground_passage and underground_passage.other
		if surface_passage and surface_passage.other == underground_passage
			and type(surface_passage.GetMap) == "function"
			and type(underground_passage.GetMap) == "function"
			and surface_passage:GetMap() == surface_map
			and underground_passage:GetMap() == map then
			linked = linked + 1
			local spos, upos = surface_passage:GetPos(), underground_passage:GetPos()
			local sx, sy = PointXY(spos)
			local ux, uy = PointXY(upos)
			local final_x = tonumber(underground_passage.SuperBigMapCommittedPassageX)
			local final_y = tonumber(underground_passage.SuperBigMapCommittedPassageY)
			local source_x = tonumber(underground_passage.SuperBigMapCommittedPassageSourceX)
			local source_y = tonumber(underground_passage.SuperBigMapCommittedPassageSourceY)
			if underground_passage.SuperBigMapCommittedPassageLocked == true
				and surface_passage.SuperBigMapCommittedPassageLocked == true
				and final_x == tonumber(surface_passage.SuperBigMapCommittedPassageX)
				and final_y == tonumber(surface_passage.SuperBigMapCommittedPassageY)
				and sx == final_x and sy == final_y and ux == source_x and uy == source_y then
				committed_pairs = committed_pairs + 1
			end
			local ok_underground, underground_valid = pcall(
				underground_passage.IsValidPlacement, underground_passage)
			local ok_surface, surface_valid = pcall(
				surface_passage.IsValidPlacement, surface_passage)
			-- Diagnostic only: SurfacePassageBase:IsValidPlacement calls GetBuildableGrid(self),
			-- whose ambient map lookup can observe the expanded backing while this transaction is
			-- deliberately presenting the underground source view. The common-hex planner performs
			-- the same vanilla flat test plus complete shape/slope/passability/obstruction validation
			-- with explicit map objects before and after each move; that result is authoritative here.
			ExpansionAudit("PASSAGE_BOOTSTRAP_OBJECT_METHOD_OBSERVATION", {
				pair = index,
				underground_call_ok = ok_underground,
				underground_valid = underground_valid,
				surface_call_ok = ok_surface,
				surface_valid = surface_valid,
				linked = true,
				committed = sx == final_x and sy == final_y and ux == source_x and uy == source_y,
			}, map)
		end
	end
	return #(passages or {}) == expected and linked == expected and committed_pairs == expected
end

local function BootstrapPassagesAndDeferWonders(env)
	local map = env and env.map
	local ready, reason = DeferredArtefactPreflight(map)
	if not ready then return false, reason end
	local surface_map = Global("MainMap")
	if type(surface_map) ~= "table" or surface_map == map
		or type(surface_map.mapdata) ~= "table" or surface_map.mapdata.Environment ~= "Surface" then
		return false, "surface map is unavailable"
	end
	local rhelpers = env.rhelpers
	local rand = type(rhelpers) == "table" and rhelpers[1]
	if type(rand) ~= "function" then return false, "vanilla random helper is unavailable" end
	local table_lib = Global("table") or table
	if type(table_lib) ~= "table" or type(table_lib.shuffle) ~= "function" then
		return false, "table.shuffle is unavailable"
	end

	local wonder_markers = ArtefactMapGet(map, "BuriedWonderMarker")
	local passage_markers = ArtefactMapGet(map, "SurfacePassageMarker")
	local desired_passages = 2
	if #passage_markers < desired_passages then
		return false, "only " .. tostring(#passage_markers)
			.. " SurfacePassageMarker objects exist; need " .. tostring(desired_passages)
	end

	-- Consume the PlaceArtefacts PRNG exactly as vanilla does: wonder-class shuffle first,
	-- passage-marker shuffle second. Only construction is deferred; all assignments are fixed now.
	local const_tbl = Global("const")
	if type(const_tbl) ~= "table" or type(const_tbl.RandomMap) ~= "table"
		or type(const_tbl.RandomMap.UndergroundPassagesMinDistance) ~= "number" then
		return false, "const.RandomMap.UndergroundPassagesMinDistance is unavailable"
	end
	local wonder_classes = {}
	for i, class_name in ipairs(type(const_tbl) == "table" and const_tbl.BuriedWonders or {}) do
		wonder_classes[i] = class_name
	end
	if #wonder_markers > 0 and #wonder_classes == 0 then
		return false, "const.BuriedWonders is unavailable"
	end
	if #wonder_markers > 0 then
		table_lib.shuffle(wonder_classes, rand)
		for index, marker in ipairs(wonder_markers) do
			marker.SuperBigMapDeferredWonderClass = wonder_classes[1 + ((index - 1) % #wonder_classes)]
			marker.SuperBigMapDeferredWonderIndex = index
		end
	end
	table_lib.shuffle(passage_markers, rand)

	local spawn_surface_anchor = Global("SpawnUndergroundPassage")
	local get_shape = Global("GetExtendedSpawnShape")
	local for_each_hex = Global("HexShapeForEach")
	local hex_to_world = Global("HexToWorld")
	local world_to_hex = Global("WorldToHex")
	local unbuildable_z = Global("buildUnbuildableZ")()
	local done_object = Global("DoneObject")
	local successful = {}
	map:SuspendPassEdits("SuperBigMap_PassageBootstrap")
	local ok, err = pcall(function()
		while #successful < desired_passages and #passage_markers > 0 do
			local marker = table.remove(passage_markers)
			local surface_anchor, surface_shape = spawn_surface_anchor(surface_map,
				marker:GetPos(), marker:GetAngle(), const_tbl.RandomMap.UndergroundPassagesMinDistance,
				successful)
			if surface_anchor then
				ArtefactClearObstructions(surface_anchor, surface_map.obj_prefab_marker,
					surface_anchor:GetPos(), surface_shape)
				local underground_anchor = ArtefactSpawnMarkerBuilding(marker, "SurfacePassage", map)
				underground_anchor:Link(surface_anchor)
				successful[#successful + 1] = underground_anchor

				local shape = get_shape("Elevator")
				local landscape_pos
				if map.buildable:GetZ(world_to_hex(underground_anchor)) == unbuildable_z then
					local closest_2d2
					for_each_hex(shape, underground_anchor, function(q, r, idx)
						local hex = shape[idx]
						local hex_center = Global("point")(hex_to_world(q, r))
						local build_z = map.buildable:GetZ(q, r)
						if build_z ~= unbuildable_z then
							local hx, hy = hex:xy()
							local dist2 = hx * hx + hy * hy
							if not landscape_pos or dist2 < closest_2d2 then
								landscape_pos, closest_2d2 = hex_center, dist2
							end
						end
					end)
				end
				ArtefactClearObstructions(underground_anchor, map.obj_prefab_marker, landscape_pos, shape)
				if underground_anchor:IsValidPlacement() then
					done_object(marker)
				else
					marker.editor_text_color = Global("RGB")(255, 0, 0)
				end
			end
		end
		for _, marker in ipairs(passage_markers) do done_object(marker) end
	end)
	local resume_ok, resume_err = pcall(map.ResumePassEdits, map, "SuperBigMap_PassageBootstrap")
	if not ok then error("passage-only artefact bootstrap failed: " .. tostring(err)) end
	if not resume_ok then error("passage bootstrap ResumePassEdits failed: " .. tostring(resume_err)) end
	if type(AlignPassagePairsToSharedHex) ~= "function" then
		error("passage bootstrap common-hex planner is unavailable")
	end
	local plan_ok, plan_stats = AlignPassagePairsToSharedHex(map, { source_bootstrap = true })
	if plan_ok ~= true then
		error("passage bootstrap common-hex planning failed: "
			.. tostring(plan_stats and plan_stats.error or "unknown error"))
	end
	if not VerifyBootstrapPassages(map, successful, desired_passages) then
		error("passage bootstrap did not create two valid committed linked Elevator anchors")
	end

	map.SuperBigMapDeferredUndergroundWondersPending = #wonder_markers > 0
	map.SuperBigMapDeferredUndergroundWondersDone = #wonder_markers == 0
	map.SuperBigMapDeferredUndergroundWonderCount = #wonder_markers
	map.SuperBigMapPassageBootstrapComplete = true
	map.SuperBigMapPassageBootstrapCount = #successful
	return true, {
		passages = #successful, wonders_deferred = #wonder_markers,
		planned_pairs = plan_stats and plan_stats.pairs or 0,
	}
end

local function FlattenDeferredWonder(wonder)
	local get_enclosed = Global("GetEnclosedShape")
	local shrink = Global("ShrinkShape")
	local get_outline = Global("GetEntityOutlineShape")
	local for_each_hex = Global("HexShapeForEach")
	local flatten = Global("FlattenTerrainInShape")
	local unbuildable = Global("buildUnbuildableZ")()
	local map = wonder:GetMap()
	local shape = get_enclosed(wonder:GetEntity())
	if #shape == 0 then shape = shrink(get_outline(wonder:GetEntity()), 2) end
	local buildable_z
	for_each_hex(shape, wonder, function(q, r)
		local z = map.buildable:GetZ(q, r)
		if z ~= unbuildable then buildable_z = z return true end
	end)
	if buildable_z then
		flatten(shape, wonder, map.buildable.z_grid, map.object_hex_grid,
			Global("g_NCF_FlatInner"), Global("g_NCF_FlatOuter"), -1, buildable_z)
		ArtefactClearObstructions(wonder, map.obj_prefab_marker, nil, shape)
	end
end

local function MaterializeDeferredUndergroundWonders(map)
	local markers = ArtefactMapGet(map, "BuriedWonderMarker")
	local planned = {}
	for _, marker in ipairs(markers) do
		if type(marker.SuperBigMapDeferredWonderClass) == "string"
			and marker.SuperBigMapDeferredWonderClass ~= "" then
			planned[#planned + 1] = marker
		end
	end
	if map.SuperBigMapDeferredUndergroundWondersPending ~= true and #planned == 0 then
		return true, 0
	end
	if #planned == 0 then
		return false, "deferred wonder plan is pending but no assigned BuriedWonderMarker survives"
	end
	local required = {
		Global("PlaceBuildingIn"), Global("GetEnclosedShape"), Global("ShrinkShape"),
		Global("GetEntityOutlineShape"), Global("HexShapeForEach"),
		Global("FlattenTerrainInShape"), Global("buildUnbuildableZ"), Global("DoneObject"),
	}
	for _, fn in ipairs(required) do
		if type(fn) ~= "function" then return false, "deferred wonder helper is unavailable" end
	end
	local spawned = 0
	map:SuspendPassEdits("SuperBigMap_DeferredUndergroundWonders")
	local ok, err = pcall(function()
		for _, marker in ipairs(planned) do
			local wonder = ArtefactSpawnMarkerBuilding(marker,
				marker.SuperBigMapDeferredWonderClass, map)
			FlattenDeferredWonder(wonder)
			Global("DoneObject")(marker)
			spawned = spawned + 1
		end
	end)
	local resume_ok, resume_err = pcall(map.ResumePassEdits, map,
		"SuperBigMap_DeferredUndergroundWonders")
	if not ok then return false, tostring(err) end
	if not resume_ok then return false, "ResumePassEdits failed: " .. tostring(resume_err) end
	map.SuperBigMapDeferredUndergroundWondersPending = false
	map.SuperBigMapDeferredUndergroundWondersDone = true
	map.SuperBigMapDeferredUndergroundWondersSpawned = spawned
	return spawned == #planned, spawned
end

-- SurfacePassage is the underground half of a natural Elevator anchor. Its inherited
-- SpawnsOnCityInit:Spawn creates the SurfaceTunnelMarker and immediately calls
-- FindUnobstructedDepositPos, which requires the BuildableGrid and object hex grid to have
-- identical dimensions. During deferred expansion CityInitialized sees a 6144 buildable grid and
-- an 8192 object grid, so spawning the marker then asserts in HexGridFindBuildable. Keep the linked
-- passage object eager (Elevator snapping depends on it), but defer only this child marker until the
-- first-access pipeline has stretched the terrain and rebuilt both final grids.
local function IsDeferredUndergroundTunnelSpawn(spawner)
	if not spawner or type(spawner.GetMap) ~= "function" then return false end
	local ok_map, map = pcall(spawner.GetMap, spawner)
	if not ok_map or type(map) ~= "table" or type(map.mapdata) ~= "table"
		or map.mapdata.Environment ~= "Underground" then
		return false
	end
	local desired = map.SuperBigMapDesiredWidthTiles
	local generated = map.SuperBigMapGeneratorWidthTiles
	return cfg_bool("STRETCH_UNDERGROUND", false)
		and type(desired) == "number" and type(generated) == "number" and desired > generated
		and map.SuperBigMapUndergroundPrepared ~= true
		and spawner.SuperBigMapDeferredTunnelSpawnDone ~= true,
		map
end

local function PatchDeferredUndergroundTunnelSpawn()
	local State = SuperBigMap.State
	local passage_class = Engine.ClassTable and Engine.ClassTable("SurfacePassage")
	if type(passage_class) ~= "table" then
		return false
	end
	local current = passage_class.Spawn
	if current == State.deferred_tunnel_spawn_wrapper then return true end
	if type(current) ~= "function" then
		return false
	end
	State.original_surface_passage_spawn = current
	local wrapper = function(self, ...)
		local should_defer, map = IsDeferredUndergroundTunnelSpawn(self)
		if should_defer then
			local newly_pending = self.SuperBigMapDeferredTunnelSpawnPending ~= true
			self.SuperBigMapDeferredTunnelSpawnPending = true
			map.SuperBigMapDeferredTunnelSpawnsPending = true
			if newly_pending then
				map.SuperBigMapDeferredTunnelSpawnCount =
					(type(map.SuperBigMapDeferredTunnelSpawnCount) == "number"
						and map.SuperBigMapDeferredTunnelSpawnCount or 0) + 1
			end
			return
		end
		local original = State.original_surface_passage_spawn
		return original(self, ...)
	end
	passage_class.Spawn = wrapper
	State.deferred_tunnel_spawn_wrapper = wrapper
	return true
end

local function MaterializeDeferredUndergroundTunnelSpawns(map)
	local State = SuperBigMap.State
	local original = State.original_surface_passage_spawn
	if type(original) ~= "function" then
		return false, "original SurfacePassage:Spawn is unavailable"
	end
	local passages = ArtefactMapGet(map, "SurfacePassage")
	local pending = {}
	for _, passage in ipairs(passages) do
		if passage.SuperBigMapDeferredTunnelSpawnPending == true
			and passage.SuperBigMapDeferredTunnelSpawnDone ~= true then
			pending[#pending + 1] = passage
		end
	end
	if map.SuperBigMapDeferredTunnelSpawnsPending ~= true and #pending == 0 then
		return true, 0
	end
	if #pending == 0 then
		return false, "tunnel marker spawn is pending but no deferred SurfacePassage survives"
	end
	local before = ArtefactMapGet(map, "SurfaceTunnelMarker")
	local spawned = 0
	for _, passage in ipairs(pending) do
		local ok, err = pcall(original, passage)
		if not ok then
			return false, "SurfacePassage marker spawn failed: " .. tostring(err)
		end
		local matched = false
		for _, marker in ipairs(ArtefactMapGet(map, "SurfaceTunnelMarker")) do
			if marker.spawner == passage then matched = true break end
		end
		if not matched then
			return false, "SurfacePassage marker spawn returned without a linked SurfaceTunnelMarker"
		end
		passage.SuperBigMapDeferredTunnelSpawnPending = false
		passage.SuperBigMapDeferredTunnelSpawnDone = true
		spawned = spawned + 1
	end
	local after = ArtefactMapGet(map, "SurfaceTunnelMarker")
	map.SuperBigMapDeferredTunnelSpawnsPending = false
	map.SuperBigMapDeferredTunnelSpawnsDone = true
	map.SuperBigMapDeferredTunnelSpawnsCreated = spawned
	return spawned == #pending, spawned
end

local function PatchRandomMapGenerator()
	-- This class hook is independent from the generator wrapper identity. Re-verify it before the
	-- version guard because ClassesBuilt can replace class methods without replacing the generator.
	PatchDeferredUndergroundTunnelSpawn()
	if not cfg_bool("PATCH_RANDOM_MAP_GENERATOR", true) then
		return false
	end

	local generator_class = Global("RandomMapGenerator")
	if type(generator_class) ~= "table" or type(generator_class.Generate) ~= "function" then
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
	if generator_class.OnGenerateLogic ~= State.generator_on_generate_logic_wrapper then
		State.generator_original_on_generate_logic = generator_class.OnGenerateLogic
	end
	local original_generate = State.generator_original_generate
	local original_do_generate = State.generator_original_do_generate
	local original_on_generate_logic = State.generator_original_on_generate_logic

	-- OnGenerateLogic exposes the private buildable-grid transaction and underground
	-- artefact procedure needed by the supported stretch pipeline.
	if type(original_on_generate_logic) == "function" then
		local on_generate_logic_wrapper = function(self, env, ...)
			if type(env) ~= "table" then
				return original_on_generate_logic(self, env, ...)
			end
			local map = env.map
			local environment = type(map) == "table" and type(map.mapdata) == "table"
				and map.mapdata.Environment or nil
			-- Normal generations enter the original method unchanged.
			if State.rmg_placement_active_map ~= map then
				return CallOnGenerateLogicTimed(original_on_generate_logic, self, env, map, ...)
			end
			local is_underground = environment == "Underground"
			local defer_underground_artefacts = is_underground
				and cfg_bool("STRETCH_UNDERGROUND", false)
				and cfg_bool("DEFER_UNDERGROUND_EXPANSION_UNTIL_FIRST_ACCESS", false)
			local saved_get_playable_area = env.GetPlayableArea
			local saved_proc_invoke = env.ProcInvoke
			local proc_invoke_wrapper
			local debug_lib = Global("debug")
			local getfenv_fn = Global("getfenv")
			local function function_environment(fn)
				if type(fn) ~= "function" then return nil end
				-- The mod sandbox exposes Lua 5.1 function environments even when the
				-- debug upvalue API is stripped. This table is the authoritative global
				-- lookup environment used by the compiled RandomMapGenerator closure.
				if type(getfenv_fn) == "function" then
					local ok_env, value = pcall(getfenv_fn, fn)
					if ok_env and type(value) == "table" then return value end
				end
				if type(debug_lib) == "table" and type(debug_lib.getfenv) == "function" then
					local ok_env, value = pcall(debug_lib.getfenv, fn)
					if ok_env and type(value) == "table" then return value end
				end
				if type(debug_lib) == "table" and type(debug_lib.getupvalue) == "function" then
					for i = 1, 64 do
						local ok_up, name, value = pcall(debug_lib.getupvalue, fn, i)
						if not ok_up or name == nil then break end
						if name == "_ENV" and type(value) == "table" then
							return value
						end
					end
				end
				return nil
			end
			local generator_closure_env = function_environment(original_on_generate_logic)
			local function closure_global(name, fallback)
				if type(generator_closure_env) == "table" then
					local ok_value, value = pcall(function() return generator_closure_env[name] end)
					if ok_value and value ~= nil then return value end
				end
				return fallback
			end
			-- Use the same closure environment as stock OnGenerateLogic. The compiled game
			-- function owns a private _ENV, so _G may expose a different function identity.
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
			-- Proc_ResolveBuildable rebuilds map.buildable at the source-sized view, but native
			-- MaskBuildableGrid derives its cell-to-world step from the real expanded Terrain
			-- backing. Lua-facing Map size overrides cannot change that native field. Recreate the
			-- vanilla transaction without approximating it: enlarge the temporary work mask by the
			-- exact expanded/source ratio, pad the source buildable grid to the real expanded hex
			-- dimensions, invoke native MaskBuildableGrid, then crop the source work rectangle.
			-- For every source cell, native now evaluates the same world coordinate, same hex, and
			-- same buildable value it would on a genuinely vanilla allocation. No expected count,
			-- checksum, seed, or compensating coordinate participates in the algorithm.
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
			-- Proc_ResolveBuildable performs a native mask call before GetPlayableArea. Retain the
			-- exact source-sized grid only for this synchronous generation transaction while the
			-- live BuildableGrid temporarily exposes a destination-sized, unbuildable-padded copy.
			local retained_source_buildable_grid
			local function rebuild_source_buildable_grid(target_map)
				if is_underground
					or target_map ~= map
					or not cfg_bool("EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE", false)
					or not cfg_bool("LIMIT_BUILDABLE_GRID_TO_SOURCE", true) then
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
				local build_map = map
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

				local capacity_raw, source_raw, source_processed
				local pause = Global("PauseInfiniteLoopDetection")
				local resume = Global("ResumeInfiniteLoopDetection")
				if type(pause) == "function" then pcall(pause, "SBMSourceBuildableRawGridBridge") end
				local bridge_ok, bridge_err = pcall(function()
					local capacity_hex_w = expanded_hex_w
					local capacity_hex_h = expanded_hex_h
					capacity_raw = closure_new_grid(capacity_hex_w, capacity_hex_h, 16, unbuildable_z)
					source_raw = closure_new_grid(source_hex_w, source_hex_h, 16, unbuildable_z)
					source_processed = closure_new_grid(source_hex_w, source_hex_h, 16, unbuildable_z)
					if not capacity_raw or not source_raw or not source_processed then
						error("grid-allocation-failed")
					end
					-- The entire point of this bridge is the asymmetric transaction below: native output
					-- capacity matches the real backing, but every logical dimension stays source-sized.
					-- Assert that contract before entering native code and never rewrite these fields.
					local build_map_data = build_map.mapdata or map_data
					local source_view_width, source_view_height = build_map.Width, build_map.Height
					local source_view_hex_width, source_view_hex_height = build_map.hex_width, build_map.hex_height
					local source_view_data_width, source_view_data_height =
						build_map_data.Width, build_map_data.Height
					local map_get_size = build_map.GetMapSize
					local terrain_api = closure_global("terrain", Global("terrain"))
					local terrain_get_size = type(terrain_api) == "table"
						and terrain_api.GetMapSize or nil
					local observed_map_w, observed_map_h, observed_terrain_w, observed_terrain_h
					if type(map_get_size) == "function" then
						local ok_size, width, height = pcall(map_get_size, build_map)
						if ok_size then observed_map_w, observed_map_h = width, height end
					end
					if type(terrain_get_size) == "function" then
						local ok_size, width, height = pcall(terrain_get_size, build_map)
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
					if not source_view_exact then error("logical-source-view-not-exact") end

					init_params.buildable_grid = capacity_raw
					closure_init_buildable_grid(build_map, init_params)
					for y = 0, source_hex_h - 1 do
						for x = 0, source_hex_w - 1 do
							source_raw:set(x, y, capacity_raw:get(x, y))
						end
					end
					process_params.buildable_grid = source_raw
					process_params.buildable_z = source_processed
					closure_process_buildable_grid(process_params)

					buildable.z_grid = source_processed
					source_processed = nil -- ownership transferred to the live BuildableGrid
				end)
				if type(resume) == "function" then pcall(resume, "SBMSourceBuildableRawGridBridge") end
				if capacity_raw then pcall(function() capacity_raw:free() end) end
				if source_raw then pcall(function() source_raw:free() end) end
				if source_processed then pcall(function() source_processed:free() end) end
				if not bridge_ok then
					return nil, "source-buildable-bridge-failed:" .. tostring(bridge_err)
				end
				return true, nil
			end

			local function rebuild_source_invalid_mask(incoming_mask)
				if not cfg_bool("EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE", false)
					or not cfg_bool("LIMIT_GENERATOR_TO_SOURCE", true) then
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
				local stock_z_grid = buildable and buildable.z_grid
				local z_grid = retained_source_buildable_grid or stock_z_grid
				if not gen_zone or not incoming_mask or not buildable or not z_grid
					or type(z_grid.get) ~= "function" or type(z_grid.set) ~= "function"
					or type(closure_new_grid) ~= "function"
					or type(closure_new_compute_grid) ~= "function"
					or type(closure_is_compute_grid) ~= "function"
					or type(closure_grid_fill) ~= "function"
					or type(closure_mask_buildable_grid) ~= "function"
					or type(closure_grid_dest) ~= "function"
					or type(closure_grid_not) ~= "function"
					then
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

				local ok_virtual_mask, virtual_mask_or_err = pcall(
					closure_new_compute_grid, virtual_w, virtual_h, mask_format, mask_bits)
				local virtual_mask = ok_virtual_mask and virtual_mask_or_err or nil
				local ok_virtual_z, virtual_z_or_err = pcall(
					closure_new_grid, expanded_hex_w, expanded_hex_h, 16, unbuildable_z)
				local virtual_z = ok_virtual_z and virtual_z_or_err or nil
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

				local pause = Global("PauseInfiniteLoopDetection")
				local resume = Global("ResumeInfiniteLoopDetection")
				if type(pause) == "function" then pcall(pause, "SBMSourceBuildableMaskNativeBridge") end
				local ok_bridge, bridge_err = pcall(function()
					-- The virtual grids are initialized invalid/unbuildable. Copy only the source
					-- rectangles; their padding represents terrain outside the source view.
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
				if virtual_mask then pcall(function() virtual_mask:free() end) end
				if virtual_z then pcall(function() virtual_z:free() end) end
				if type(resume) == "function" then pcall(resume, "SBMSourceBuildableMaskNativeBridge") end
				if not ok_bridge then
					pcall(function() repaired:free() end)
					return nil, "native-bridge-failed:" .. tostring(bridge_err)
				end
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
					elseif retained_source_buildable_grid then
						error("source playable-mask repair failed: " .. tostring(repair_reason))
					end
					local results
					local ok_playable, playable_err = pcall(function()
						results = PackValues(saved_get_playable_area(Unpack(args, 1, args.n)))
					end)
					if repaired_mask then pcall(function() repaired_mask:free() end) end
					if not ok_playable then error(playable_err) end
					return Unpack(results, 1, results.n)
				end
			end

			-- Keep the two passage anchors eager while deferring underground wonders.
			if type(saved_proc_invoke) == "function" and defer_underground_artefacts then
				proc_invoke_wrapper = function(tag, func, randless)
					if tag == "PlaceArtefacts" then
						return saved_proc_invoke(tag, function()
							local bootstrap_ok, details = BootstrapPassagesAndDeferWonders(env)
							if bootstrap_ok ~= true then
								local stock_results = PackValues(func())
								local stock_passages = ArtefactMapGet(map, "SurfacePassage")
								local plan_ok, plan_stats = AlignPassagePairsToSharedHex(map,
									{ source_bootstrap = true })
								if plan_ok ~= true then
									error("stock PlaceArtefacts passage planning failed after "
										.. tostring(details) .. ": "
										.. tostring(plan_stats and plan_stats.error or "unknown error"))
								end
								if not VerifyBootstrapPassages(map, stock_passages, 2) then
									error("stock PlaceArtefacts did not create two valid linked Elevator anchors after "
										.. tostring(details))
								end
								map.SuperBigMapPassageBootstrapComplete = true
								map.SuperBigMapPassageBootstrapCount = #stock_passages
								return Unpack(stock_results, 1, stock_results.n)
							end
							return details
						end, randless)
					end
					return saved_proc_invoke(tag, func, randless)
				end
				env.ProcInvoke = proc_invoke_wrapper
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
			local rebuild_buildable_grid_required =
				cfg_bool("EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE", false)
				and cfg_bool("LIMIT_BUILDABLE_GRID_TO_SOURCE", true)
				and desired_w and desired_h and generator_w and generator_h
				and desired_w > generator_w and desired_h > generator_h
			rebuild_buildable_grid_wrapper = function(buildable, target_map, width, height, map_data, ...)
				rebuild_buildable_grid_calls = rebuild_buildable_grid_calls + 1
				-- Surface generation now normally runs on a true vanilla-sized temporary map.
				-- Deferred underground generation still runs once on the final expanded backing,
				-- while its Lua-visible fields present the vanilla source extent. The stock
				-- ResolveBuildable sequence builds a source-sized z-grid and immediately passes it
				-- to native MaskBuildableGrid. Native code addresses the real backing extent, not
				-- the Lua view, so that mixed 615x710 / 820x946 transaction can read out of bounds.
				--
				-- Keep the exact source grid for the authoritative GetPlayableArea mask repair,
				-- but give the unavoidable stock mask call a backing-sized grid padded with
				-- UnbuildableZ. This changes no source value and adds no playable cell.
				if is_underground and target_map == map then
					if type(saved_buildable_grid_build) ~= "function"
						or type(closure_new_grid) ~= "function" then
						error("underground stock-mask safety APIs unavailable")
					end
					if retained_source_buildable_grid then
						error("underground source buildable grid already retained")
					end
					saved_buildable_grid_build(buildable, target_map, width, height, map_data, ...)
					local source_grid = buildable and buildable.z_grid
					local source_w, source_h
					if source_grid and type(source_grid.size) == "function" then
						local ok_size, grid_w, grid_h = pcall(source_grid.size, source_grid)
						if ok_size then source_w, source_h = grid_w, grid_h or grid_w end
					end
					local expected_source_w = tonumber(map.hex_width)
					local expected_source_h = tonumber(map.hex_height)
					local expanded_w = tonumber(map.SuperBigMapExpandedHexWidth)
					local expanded_h = tonumber(map.SuperBigMapExpandedHexHeight)
					local dimensions_valid = source_grid ~= nil
						and type(source_w) == "number" and type(source_h) == "number"
						and source_w == expected_source_w and source_h == expected_source_h
						and type(expanded_w) == "number" and type(expanded_h) == "number"
						and expanded_w >= source_w and expanded_h >= source_h
						and (expanded_w > source_w or expanded_h > source_h)
					if not dimensions_valid then
						error("underground stock-mask dimension invariant failed")
					end
					local unbuildable_z = 2 ^ 16 - 1
					if type(closure_build_unbuildable_z) == "function" then
						local ok_z, value = pcall(closure_build_unbuildable_z)
						if ok_z and type(value) == "number" then unbuildable_z = value end
					end
					local padded = closure_new_grid(expanded_w, expanded_h, 16, unbuildable_z)
					if not padded or type(padded.set) ~= "function" or type(source_grid.get) ~= "function" then
						if padded then pcall(function() padded:free() end) end
						error("underground stock-mask safety grid allocation failed")
					end
					for y = 0, source_h - 1 do
						for x = 0, source_w - 1 do
							padded:set(x, y, source_grid:get(x, y))
						end
					end
					retained_source_buildable_grid = source_grid
					buildable.z_grid = padded
					return
				end
				local bridge_ok, bridge_reason = rebuild_source_buildable_grid(target_map)
				if bridge_ok then
					return
				end
				if bridge_reason == "mode-not-eligible" or bridge_reason == "map-not-expanded" then
					if type(saved_buildable_grid_build) == "function" then
						return saved_buildable_grid_build(buildable, target_map,
							width, height, map_data, ...)
					end
				end
				local failure = "source buildable raw-grid bridge failed before vanilla mask/playable "
					.. "resolution: " .. tostring(bridge_reason)
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

			local results
			if rebuild_buildable_grid_required and not rebuild_buildable_grid_installed then
				results = { false, "source buildable raw-grid bridge hook unavailable" }
			else
				results = { pcall(CallOnGenerateLogicTimed,
					original_on_generate_logic, self, env, map, ...) }
			end

			if retained_source_buildable_grid then
				local retained = retained_source_buildable_grid
				retained_source_buildable_grid = nil
				local ok_free, free_error = pcall(function() retained:free() end)
				if not ok_free and results[1] then
					results = { false, "native source buildable cleanup failed: " .. tostring(free_error) }
				end
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
			if not rebuild_restore_ok and results[1] then
				results = { false, "source buildable raw-grid bridge cleanup failed: "
					.. tostring(rebuild_restore_reason) }
			elseif rebuild_buildable_grid_required and results[1]
				and rebuild_buildable_grid_calls == 0 then
				results = { false, "source buildable raw-grid bridge was installed but never called" }
			end
			if proc_invoke_wrapper and env.ProcInvoke == proc_invoke_wrapper then
				env.ProcInvoke = saved_proc_invoke
			end
			if env.GetPlayableArea ~= saved_get_playable_area then
				env.GetPlayableArea = saved_get_playable_area
			end
			if not results[1] then error(results[2]) end
			return Unpack(results, 2)
		end
		generator_class.OnGenerateLogic = on_generate_logic_wrapper
		State.generator_on_generate_logic_wrapper = on_generate_logic_wrapper
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
			PrepareMapDataForExpansion(params.map_slot or 1, map_name, instance, "RandomMapGenerator.Generate")
			if instance.SuperBigMapExpansionPending ~= true then
				-- EXPAND MAP is off (or the map is ineligible). Leave vanilla generation untouched.
				return original_generate(self, params)
			end
			if params.map_slot then
				params.mapdata = params.mapdata or instance.mapdata
				params.RandomMapGenObject = params.RandomMapGenObject or self
				params.SuperBigMapExpansionPending = instance.SuperBigMapExpansionPending
				params.SuperBigMapSourceWidth = instance.SuperBigMapSourceWidth
				params.SuperBigMapSourceHeight = instance.SuperBigMapSourceHeight
				params.SuperBigMapOriginalWidthTiles = instance.SuperBigMapOriginalWidthTiles
				params.SuperBigMapOriginalHeightTiles = instance.SuperBigMapOriginalHeightTiles
				params.SuperBigMapDesiredWidthTiles = instance.SuperBigMapDesiredWidthTiles
				params.SuperBigMapDesiredHeightTiles = instance.SuperBigMapDesiredHeightTiles
			end
		end
		return original_generate(self, params)
	end
	generator_class.Generate = generate_wrapper
	State.generator_generate_wrapper = generate_wrapper

	if type(original_do_generate) == "function" then
		local do_generate_wrapper = function(self, map, ...)
			local mapdata = map and map.mapdata
			local expansion_transaction = map and (
				map.SuperBigMapExpansionPending == true
					or map.SuperBigMapVanillaSourceMigration == true
				or map.SuperBigMapDesiredWidthTiles ~= nil)
				or type(mapdata) == "table" and (
					mapdata.SuperBigMapOriginalWidthTiles ~= nil
					or mapdata.SuperBigMapSourceWidthTiles ~= nil)
				or State.vanilla_source_migration_active == true
			if not expansion_transaction then
			-- Exact vanilla fast path: no temporary-source migration or expansion behavior.
				return original_do_generate(self, map, ...)
			end
			if not cfg_bool("LIMIT_GENERATOR_TO_SOURCE", true) then
				return original_do_generate(self, map, ...)
			end
			local loading_diagnostics = SuperBigMap.Diagnostics
			local loading_session_already_active = loading_diagnostics
				and type(loading_diagnostics.LoadingActive) == "function"
				and loading_diagnostics.LoadingActive() == true
			LoadingStart("RandomMapGenerator.DoGenerate", map, {
				environment = tostring(mapdata and mapdata.Environment),
				vanilla_source_migration = tostring(map and map.SuperBigMapVanillaSourceMigration == true),
				expansion_pending = tostring(map and map.SuperBigMapExpansionPending == true),
			})

			local height_tile_size = (Global("const") and type(const.HeightTileSize) == "number" and const.HeightTileSize > 0)
				and const.HeightTileSize or 1
			local max_random_tiles = math.floor(cfg_number("MAX_RANDOM_GENERATOR_TILES", 6144, 1))

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
			mapdata = map and map.mapdata
			local terrain_api = Global("terrain")
			local original_map_get_size = map and map.GetMapSize
			local original_terrain_get_size = terrain_api and terrain_api.GetMapSize

			local function world_to_tiles(w)
				return (type(w) == "number" and w > 0) and math.floor(w / height_tile_size + 0.5) or 0
			end
			local cur_w_tiles, cur_h_tiles = 0, 0
			if type(original_map_get_size) == "function" then
				local ok, ww, hh = pcall(original_map_get_size, map)
				if ok then
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

			-- Maps that already fit the native generator remain otherwise untouched.
			if cur_w_tiles <= max_random_tiles and cur_h_tiles <= max_random_tiles then
				local native_token = LoadingBegin("native-sized RandomMapGenerator.DoGenerate", map, {
					map_tiles = tostring(cur_w_tiles) .. "x" .. tostring(cur_h_tiles),
				})
				local results = PackValues(original_do_generate(self, map, ...))
				LoadingEnd(native_token, nil, true)
				CaptureGeneratedNativeEnrichments(map, "DoGenerate native complete")
				if loading_session_already_active then
					LoadingStep("nested native-sized map generation complete", {
						map_tiles = tostring(cur_w_tiles) .. "x" .. tostring(cur_h_tiles),
					}, map)
				else
					LoadingFinish("native-sized map generation complete", map, {
						map_tiles = tostring(cur_w_tiles) .. "x" .. tostring(cur_h_tiles),
					}, true)
				end
				return Unpack(results, 1, results.n)
			end

			-- Exact-source path: keep this already allocated expanded map as the destination, but
			-- execute the generator body once on a separate native-sized backing. The helper copies
			-- terrain, transfers the generated objects, rebuilds only the final destination grids,
			-- unloads the temporary slot, and returns the original DoGenerate result tuple.
			LoadingStep("attempt exact temporary-source transaction", {
				map_tiles = tostring(cur_w_tiles) .. "x" .. tostring(cur_h_tiles),
				generator_limit_tiles = max_random_tiles,
			}, map)
			local migrated, migrated_results = GenerateOnTemporaryVanillaBacking(
				self, map, original_do_generate, ...)
			if migrated then
				return Unpack(migrated_results, 1, migrated_results.n)
			end

			local backing_environment = (type(mapdata) == "table" and mapdata.Environment)
				or (type(template) == "table" and template.Environment)
			if backing_environment ~= "Underground" then
				error("expanded surface generation requires the exact temporary vanilla backing transaction")
			end

			-- Underground generation cannot use the temporary surface migration transaction:
			-- it must create and pair passage anchors against the live expanded surface. Present
			-- the expanded underground backing through an exact source-sized generator view, run
			-- vanilla once, then restore the real expanded dimensions before deferred stretching.
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
			if cfg_bool("LIMIT_BUILDABLE_GRID_TO_SOURCE", true)
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
				end
			end


			-- Make the AREA FACTOR computable at Begin time: mapdata.Width was just overridden to
			-- the generator size, and the pending-map markers can be wiped by the new-game Lua
			-- reload -- with both gone AreaFactor read 6144/6144 = 1 and the anomaly/research count
			-- scaling can silently do nothing if these values disappear. Stamp the detected
			-- full and generator tile sizes on the map so the later stretch passes
			-- always see desired=8192 / generator=6144.
			map.SuperBigMapDesiredWidthTiles = map.SuperBigMapDesiredWidthTiles or cur_w_tiles
			map.SuperBigMapDesiredHeightTiles = map.SuperBigMapDesiredHeightTiles or cur_h_tiles
			map.SuperBigMapGeneratorWidthTiles = map.SuperBigMapGeneratorWidthTiles or gen_width_tiles
			map.SuperBigMapGeneratorHeightTiles = map.SuperBigMapGeneratorHeightTiles or gen_height_tiles

			-- VANILLA-EXACT PLAY ZONE: PrepareMapDataForExpansion zeroed mapdata.PassBorder
			-- BEFORE ChangeMap so the engine bakes full-destination passability. But the
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
				end
			end

			-- DETERMINISTIC ENTRANCE PAIRING (config
			-- PAIRING_SURFACE_BUILDABLE_REBUILD). Passage selection runs during underground
			-- generation but searches MainMap's surface grids. A generic RebuildGrids completion
			-- flag is not sufficient here: after temporary-source migration it described a usable
			-- gameplay grid, yet vanilla FindPassageSpawnPos rejected both passage markers. Build
			-- the surface Z grid once, synchronously, immediately before passage selection, against
			-- the live surface map dimensions and object grid. Vanilla then selects a complete
			-- naturally buildable Elevator footprint. Once the final stretched surface is available,
			-- the plan is checked again and vanilla's normal passage-pad preparation is applied only
			-- to that already-valid committed footprint.
			if cfg_bool("PAIRING_SURFACE_BUILDABLE_REBUILD", true) then
				local env = (type(mapdata) == "table" and mapdata.Environment)
					or (template and template.Environment)
				if env == "Underground" then
					local main_map = Global("MainMap")
					local rebuild = Global("RebuildBuildableGrid")
					if main_map and main_map ~= map and type(rebuild) == "function" and main_map.buildable then
						if main_map.SuperBigMapSurfaceBuildablePairingReady ~= true then
							local ok_rb, err_rb = pcall(rebuild, main_map)
							if not ok_rb then
								error("surface passage pairing-grid rebuild failed: " .. tostring(err_rb))
							end
							main_map.SuperBigMapSurfaceBuildableCurrent = true
							main_map.SuperBigMapSurfaceBuildablePairingReady = true
						end
					end
				end
			end

			State.rmg_placement_active_map = map
			local expanded_backing_token = LoadingBegin(
				"source-view RandomMapGenerator.DoGenerate on expanded backing", map)
			local results = { pcall(original_do_generate, self, map, ...) }
			LoadingEnd(expanded_backing_token, nil, results[1] == true)
			-- Restore the cached MapVars before bridge cleanup can run. The
			-- pcall above covers both the successful and failing native-generation paths, so an
			-- engine/Lua failure cannot leave the live expanded map reporting source dimensions.
			if buildable_source_view then
				map.Width = saved_map_width
				map.Height = saved_map_height
				map.hex_width = saved_map_hex_width
				map.hex_height = saved_map_hex_height
			end
			State.rmg_placement_active_map = false

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
							pcall(function()
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
										local ok_s = pcall(grid_smooth, region, smoothed, 3)
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
											pcall(function()
												for yy = 0, h - 1 do
													local dy0 = math.min(yy, h - 1 - yy)
													for xx = 0, w - 1 do
														local dd = math.min(xx, w - 1 - xx, dy0)
														if dd < BAND then
															local ov = region:get(xx, yy)
															local sv = smoothed:get(xx, yy)
															if type(ov) == "number" and type(sv) == "number" then
																smoothed:set(xx, yy, ov + (sv - ov) * dd / BAND)
															end
														end
													end
												end
											end)
											if type(resume3) == "function" then pcall(resume3, "SBMPadFeather") end
											full:copyrect(smoothed, box_fn3(0, 0, w, h), point_fn3(x0, y0))
										end
										free_grid3(region)
										free_grid3(smoothed)
									end
								end
								terrain_api3.SetHeightGrid(pmap, full)
								if type(terrain_api3.InvalidateHeight) == "function" then
									pcall(terrain_api3.InvalidateHeight, pmap)
								end
								if full ~= raw then free_grid3(full) end
							end)
						end
					end
					-- Consumed: never smooth stale pads on a later generation/new game.
					State.sbm_entrance_pads = nil
				end
			end
			CaptureGeneratedNativeEnrichments(map, "DoGenerate expanded source complete")
			return Unpack(results, 2)
		end
		generator_class.DoGenerate = do_generate_wrapper
		State.generator_do_generate_wrapper = do_generate_wrapper
	end
	State.generator_patch_version = GENERATOR_PATCH_VERSION
	return true
end


-- Stretch-only surface expansion readiness gate.
local function SurfaceExpansionReadiness(map)
	if map.SuperBigMapNativeGenerationComplete ~= true then
		return false, "native generation has not completed"
	end
	if map.SuperBigMapCityInitializationComplete ~= true then
		return false, "city initialization and enrichment placement have not completed"
	end
	if map.SuperBigMapExpansionPending == true then
		return false, "expanded destination finalization is still pending"
	end
	if not FindSectorByName(map, "F0") then
		return false, "final sector grid does not contain F0"
	end
	return true, "native generation and destination finalization complete"
end

local function RunSurfaceStretchIfEnabled(map, readiness_source)
	map = map or Global("CurrentMap")
	if not cfg_bool("SURFACE_STRETCH_AT_START", false) then
		return false
	end
	if not map then
		return false
	end
	-- SuperBigMapExpanded is persisted per map. A loaded save has no new MapGenerated or
	-- CityInitialized transaction to wait for, and its expansion must never be repeated.
	if map.SuperBigMapExpanded == true and map.SuperBigMapExpansionPending ~= true then
		map.SuperBigMapSurfaceStretchDone = true
		map.SuperBigMapSurfaceStretchAwaitingReadiness = false
		map.SuperBigMapStretchPipelinePending = false
		SignalExpansionReadinessChanged(map, "persisted surface expansion already complete")
		return false
	end
	if map.SuperBigMapSurfaceStretchDone == true then
		return false
	end
	-- Report an existing live schedule as success so the lifecycle caller does not run its
	-- fallback full-map rebuild in parallel with the expansion transaction.
	if map.SuperBigMapSurfaceStretchScheduled == true then return true end
	if cfg_bool("OPTIMIZE_STRETCH_DEFERRED_REBUILDS", true) then
		map.SuperBigMapStretchPipelinePending = true
	end
	local ready, readiness = SurfaceExpansionReadiness(map)
	if not ready then
		map.SuperBigMapSurfaceStretchAwaitingReadiness = true
		-- This is an accepted deferred schedule. The lifecycle caller must not run the
		-- full-map fallback while MapGenerated/CityInitialized can satisfy the gate.
		return true
	end
	local create_thread = Global("CreateRealTimeThread")
	local yield_protected_call = Global("sprocall")
	if type(create_thread) ~= "function" or type(yield_protected_call) ~= "function" then
		map.SuperBigMapStretchPipelinePending = false
		return false
	end
	map.SuperBigMapSurfaceStretchAwaitingReadiness = false
	map.SuperBigMapSurfaceStretchScheduled = true
	local schedule_ok = pcall(create_thread, function()
		-- Protect the entire asynchronous pipeline, not only its central stretch block, so
		-- readiness/setup errors take the normal full-rebuild fallback.
		local thread_ok = yield_protected_call(function()
		-- Loading screen: hide the welcome popup's Close button + show a loading message
		-- while we expand, restored on completion (ExpansionLoadingBegin/End in lifecycle).
		-- Begin as soon as the native generation-complete gate opens so the player cannot
		-- start playing mid-expansion. Gated to real mod maps (not the PreGame preview).
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
			end
			if type(SuperBigMap.ExpansionLoadingEnd) == "function" then
				SuperBigMap.ExpansionLoadingEnd()
			end
		end
		if map.SuperBigMapSurfaceStretchDone == true then
			end_loading()
			return
		end
		-- Only maps the mod ACTUALLY expanded are candidates. Skip SILENTLY (no
		-- "cannot expand" popup) for:
		--   * the "PreGame" mission-setup preview map (a native ~15x15 preview that
		--     carries no expansion -- this is what fired the warning BEFORE a scenario
		--     was even chosen), and
		--   * any non-mod map (IsModMap == false) -- the same authoritative gate
		--     Lifecycle.Apply uses, so the stretch plan can never disagree with it and
		--     run on a map Apply already skipped.
		-- The looser UseCustomSectorsForMap check is kept as an additional silent skip.
		local map_name = tostring(map.name or (map.mapdata and map.mapdata.id) or "")
		local grid = SuperBigMap.SectorGrid
		local is_mod_map = type(grid) == "table" and type(grid.IsModMap) == "function" and grid.IsModMap(map) == true
		local custom_ok = not (type(grid) == "table" and type(grid.UseCustomSectorsForMap) == "function")
			or grid.UseCustomSectorsForMap(map)
		if map_name == "PreGame" or not is_mod_map or not custom_ok then
			map.SuperBigMapSurfaceStretchDone = true
			end_loading()
			return
		end
		local map_w, map_h = TerrainSize(map)
		if type(map_w) ~= "number" or map_w <= 0 or type(map_h) ~= "number" or map_h <= 0 then
			map.SuperBigMapSurfaceStretchDone = true
			end_loading()
			return
		end

		-- Resample the generated source to fill the whole destination as one continuous terrain.
		-- STEP 1 = TERRAIN ONLY: the
		-- generated objects/deposits are NOT yet repositioned, so they stay clustered in the
		-- source corner until the object pass lands.
		do
			-- Run the whole stretch + finalize inside pcall so an error cannot strand the loading UI.
			-- the expansion thread does not die before end_loading() -- that is what leaves the
			-- loading box stuck on screen forever. Whatever happens, we mark the map done and close
			-- the loading box below.
			-- The stretch passes iterate the full-map grids + EVERY object in one uninterrupted go;
			-- without the old per-step yields the engine's infinite-loop detector trips ("Infinite
			-- loop detected!"). Pause it for the duration -- these are BOUNDED passes (finite grid
			-- steps + a fixed object list), the same guard the deposit top-up uses. The resume below
			-- is balanced and ALWAYS runs (after the pcall, before we return).
			local pause_ild = Global("PauseInfiniteLoopDetection")
			local resume_ild = Global("ResumeInfiniteLoopDetection")
			if type(pause_ild) == "function" then SafeCall(pause_ild, "SuperBigMapStretch") end
			local ok_stretch, n_grids = false, 0
			local surface_pipeline_token = LoadingBegin("surface expansion pipeline", map)
			-- One transaction owns both mass-object moves so intermediate edits do not flush
			-- passability before the stretch's authoritative final revalidation.
			local pass_batch_reason = "SuperBigMapSurfaceStretch"
			local pass_batch_active = false
			if type(map.SuspendPassEdits) == "function" and type(map.ResumePassEdits) == "function" then
				local suspend_ok, suspend_result = pcall(map.SuspendPassEdits, map, pass_batch_reason)
				pass_batch_active = suspend_ok and suspend_result ~= false
			end
			local function ResumeCombinedPassEdits(source)
				if not pass_batch_active then return true end
				-- Clear first so an engine exception cannot cause a second, unbalanced resume attempt.
				pass_batch_active = false
				local resume_ok, resume_err = pcall(map.ResumePassEdits, map, pass_batch_reason)
				return resume_ok
			end
			local ok_branch, branch_err = pcall(function()
				if type(StretchSourceToFull) == "function" then
					-- Relief annotations MUST be captured BEFORE the terrain stretch (they record
					-- each object's relationship to the PRE-stretch ground).
					if type(AnnotateDecorRelief) == "function" then
						AnnotateDecorRelief(map)
					end
					SetLoadingPhase("Stretching the surface terrain")
					if cfg_bool("EXPANSION_STEP_07_STRETCH_TERRAIN", true) then
						-- The next call mutates terrain heights, so the native source-grid buildability
						-- snapshot is no longer current until the explicit final rebuild below succeeds.
						map.SuperBigMapSurfaceBuildableCurrent = false
						ok_stretch, n_grids = StretchSourceToFull(map)
					else
						ok_stretch, n_grids = true, 0
					end
				end
				-- The source map's enrichment OBJECTS were deliberately not transferred: their owning map
				-- slot has been unloaded. Stage 01 retained constructor-safe value records instead.
				-- Recreate them only now, after final terrain resampling, so every marker is born on its
				-- exact proportional hex and reads Z from the final destination terrain.
				local position_deposits = SuperBigMap.DepositRules
				local has_staged_records, staged_record_count = false, 0
				if position_deposits
					and type(position_deposits.HasStagedNativeEnrichmentRecords) == "function" then
					has_staged_records, staged_record_count =
						position_deposits.HasStagedNativeEnrichmentRecords(map)
				end
				-- Step 2: reposition + scale the generated decorations onto the stretched terrain
				-- (must run AFTER the height stretch so SetTerrainZ reads the new surface).
				if type(ScaleDecorationsToFull) == "function" then
					SetLoadingPhase("Repositioning surface rocks and decorations")
					ScaleDecorationsToFull(map, pass_batch_active)
				end
				if has_staged_records then
					if ok_stretch ~= true then
						error("cannot recreate staged native enrichments before a successful terrain stretch")
					end
					if type(position_deposits.RecreateStagedNativeEnrichments) ~= "function" then
						error("staged native enrichment recreation API unavailable")
					end
					SetLoadingPhase("Restoring the vanilla resources and anomalies")
					local recreated, recreate_stats = position_deposits.RecreateStagedNativeEnrichments(
						map, "surface after terrain and decoration stretch")
					if recreated ~= true then
						error("native enrichment recreation after stretch failed: "
							.. tostring(recreate_stats and recreate_stats.error or "unknown"))
					end
				end
				-- Step 3: move the deposit/anomaly/effect markers to their scaled spots too
				-- (config STRETCH_SCALE_MARKERS) -- same transform, positions only.
				if type(ScaleMarkersToFull) == "function" then
					SetLoadingPhase("Repositioning surface resource deposits")
					local n_mark = ScaleMarkersToFull(map, false, pass_batch_active)
					local position_deposits = SuperBigMap.DepositRules
					if position_deposits
						and type(position_deposits.VerifyNativeEnrichmentTransform) == "function" then
						local verified, verify_stats = position_deposits.VerifyNativeEnrichmentTransform(
							map, "surface after marker transform")
						if verified ~= true then
							error("native surface enrichment transformation verification failed (mismatches="
								.. tostring(verify_stats and verify_stats.mismatches or "unknown") .. ")")
						end
					end
				end
				ResumeCombinedPassEdits("after surface marker movement")
				-- Entrance visuals are finalized after the authoritative surface buildable-grid pass.
				-- Moving them here would anchor the badge to the provisional pre-validation coordinate.
				-- Step 4: consume the native-source start annotation after marker recreation. Every
				-- positive-overlap equivalent of the transformed vanilla winner is passed through the
				-- original vanilla InitialReveal resource/heat/buildability logic, and only its first
				-- winner is scanned. Mutually exclusive with legacy relocation (which would re-scale a
				-- freshly scanned destination sector).
				local sectors_mod = SuperBigMap.SectorExploration
				local vanilla_start_pending = sectors_mod
					and type(sectors_mod.HasPendingVanillaStartSelection) == "function"
					and sectors_mod.HasPendingVanillaStartSelection(map) == true
				if vanilla_start_pending then
					if sectors_mod and type(sectors_mod.RevealVanillaStartSectors) == "function" then
						local n_rev = SafeCall(sectors_mod.RevealVanillaStartSectors, map)
						if n_rev ~= 1 then
							error("stretched vanilla initial reveal failed: scanned=" .. tostring(n_rev))
						end
					end
				elseif cfg_bool("STRETCH_VANILLA_START_SECTOR", false) then
					error("native start-sector annotation missing before surface stretch")
				elseif type(StretchRelocateStartSector) == "function" then
					StretchRelocateStartSector(map)
				end
				-- Step 5: re-enforce scan-gating after the move (hide revealed enrichments that
				-- landed in unscanned sectors; place/reveal what moved into scanned ones).
				do
					local deposits = SuperBigMap.DepositRules
					if deposits and type(deposits.EnforceScanGateAfterStretch) == "function" then
						TimedSafeCall("surface enforce scan gate", map,
							deposits.EnforceScanGateAfterStretch, map)
					end
					-- Step 6: DENSITY NORMALIZATION after proportional marker movement:
					--   TopUpDeposits     raise the TOTAL to vanilla density x area (~1.78x),
					--                     stretch-aware baseline (all markers are generator output);
					--   RegisterCloned    register the top-up clones with their sectors;
					-- Net effect: proportionally MORE enrichments for the 20x20, at vanilla
					-- per-sector density -- no crowding.
					if deposits then
						SetLoadingPhase("Distributing surface resources and anomalies")
						if type(deposits.TopUpDeposits) == "function" then
							TimedSafeCall("surface top-up resources", map,
								deposits.TopUpDeposits, map)
						end
						-- TopUpAnomalies: post-gen replacement for the in-generation anomaly count
						-- scaling (which shifted the generator's random stream and made expanded
						-- layouts diverge from vanilla).
						if type(deposits.TopUpAnomalies) == "function" then
							TimedSafeCall("surface top-up anomalies", map,
								deposits.TopUpAnomalies, map)
						end
						if type(deposits.TopUpEffectDeposits) == "function" then
							TimedSafeCall("surface top-up effect deposits", map,
								deposits.TopUpEffectDeposits, map)
						end
						if type(deposits.RegisterClonedMarkers) == "function" then
							TimedSafeCall("surface register top-up markers", map,
								deposits.RegisterClonedMarkers, map)
						end
						if type(deposits.ResolveBadgeMarkerOverlaps) == "function" then
							TimedSafeCall("surface resolve marker overlaps", map,
								deposits.ResolveBadgeMarkerOverlaps, map, "surface density suite")
						end
						if type(deposits.AuditTopUpVanillaRepulsion) ~= "function" then
							error("top-up vanilla repulsion audit is unavailable")
						end
						local repulsion_token = LoadingBegin("surface hard repulsion audit", map)
						local repulsion_ok, repulsion_stats =
							deposits.AuditTopUpVanillaRepulsion(map, "surface final after density suite")
						LoadingEnd(repulsion_token, {
							violations = repulsion_stats and repulsion_stats.repulsion_violations,
						}, repulsion_ok == true)
						if repulsion_ok ~= true then
							error("surface top-up vanilla repulsion audit failed: density_failures="
								.. tostring(repulsion_stats and repulsion_stats.density_failures)
								.. " duplicate_hex_pairs="
								.. tostring(repulsion_stats and repulsion_stats.duplicate_hex_pairs)
								.. " repulsion_violations="
								.. tostring(repulsion_stats and repulsion_stats.repulsion_violations))
						end
						if type(deposits.AuditSurfaceTopUpRingExclusivity) == "function" then
							TimedSafeCall("surface audit outer-ring exclusivity", map,
								deposits.AuditSurfaceTopUpRingExclusivity, map)
						end
						if type(deposits.DebugAuditFinalEnrichments) == "function" then
							local audit_token = LoadingBegin("diagnostic surface enrichment audit", map)
							local call_ok, audit_ok, audit_stats = pcall(
								deposits.DebugAuditFinalEnrichments, map,
								"surface final before placement-pool cleanup")
							LoadingEnd(audit_token, {
								audit_ok = tostring(audit_ok),
								error = call_ok and "" or tostring(audit_ok),
								markers = call_ok and audit_stats and audit_stats.markers or nil,
							}, call_ok and audit_ok ~= false)
						end
						if type(deposits.ClearTopUpPlacementPool) == "function" then
							deposits.ClearTopUpPlacementPool(map)
						end
					end
				end
				if cfg_bool("EXPANSION_STEP_11_REBUILD_GAMEPLAY_GRIDS", true) then
					SetLoadingPhase("Rebuilding the surface build grid")
					local rebuild_buildable = Global("RebuildBuildableGrid")
					-- map:RebuildGrids may return immediately after scheduling work; pcall success does NOT
					-- prove the buildable z-grid was synchronously rebuilt. The stale-grid regression produced
					-- landing pillars when this explicit pass was skipped, so correctness requires this one
					-- authoritative synchronous rebuild after all terrain-height edits.
					if type(rebuild_buildable) == "function" and map and map.buildable then
						local rebuild_token = LoadingBegin("surface final RebuildBuildableGrid", map)
						local rebuild_ok, rebuild_err = pcall(rebuild_buildable, map)
						LoadingEnd(rebuild_token, { error = rebuild_ok and "" or tostring(rebuild_err) }, rebuild_ok)
						if not rebuild_ok then
							error("final surface RebuildBuildableGrid failed: " .. tostring(rebuild_err))
						end
						map.SuperBigMapSurfaceBuildableCurrent = true
					else
						error("final surface RebuildBuildableGrid unavailable")
					end
					-- The cheap underground bootstrap records the vanilla underground source hex before
					-- this surface exists in its stretched form. Project that authoritative hex onto the
					-- final surface now. Use it exactly when its full footprint is valid; otherwise commit
					-- the nearest valid surface-only hex without forcing early underground expansion.
					local maps = Global("Maps")
					if type(maps) == "table" and type(AlignPassagePairsToSharedHex) == "function" then
						local seen_underground = {}
						for slot, underground_map in pairs(maps) do
							local underground_environment = underground_map and underground_map.mapdata
								and underground_map.mapdata.Environment
							if slot ~= 1 and underground_environment == "Underground"
								and not seen_underground[underground_map]
								and underground_map.SuperBigMapPassageBootstrapComplete == true
								and underground_map.SuperBigMapPassageSurfaceFinalCommitted ~= true
								and underground_map.SuperBigMapUndergroundStretchDone ~= true then
								seen_underground[underground_map] = true
								local plan_ok, plan_stats = AlignPassagePairsToSharedHex(underground_map, {
									source_bootstrap = true,
									prepare_surface_pad = true,
								})
								if plan_ok ~= true then
									error("final surface passage commitment failed: "
										.. tostring(plan_stats and plan_stats.error or "unknown error")
										.. (plan_stats and plan_stats.reason
											and (": " .. tostring(plan_stats.reason)) or ""))
								end
								underground_map.SuperBigMapPassageSurfaceFinalCommitted = true
							end
						end
					end
					-- Now every surface passage owns its immutable final coordinate. Scale the remaining
					-- entrance structures and place each badge relative to that coordinate exactly once.
					if type(MoveEntranceVisualsToScale) == "function" then
						SetLoadingPhase("Aligning the underground entrances")
						MoveEntranceVisualsToScale(map)
					end
				end
				local rockets = SuperBigMap.RocketRules
				if rockets and type(rockets.ResnapRocketsOnMap) == "function" then
					SafeCall( rockets.ResnapRocketsOnMap, map)
				end
				-- The first overview can begin before temporary-source objects are migrated.
				-- Initialize the final passage and badge synchronously now that their final
				-- positions exist; otherwise vanilla first sees them on the next zoom event.
				local highlight = SuperBigMap.SectorHighlight
				if highlight and type(highlight.EnsureEntranceVisualsReady) == "function" then
					highlight.EnsureEntranceVisualsReady(map, nil, "surface stretch complete")
				end
			end)
			LoadingEnd(surface_pipeline_token, {
				terrain_grids = n_grids, error = ok_branch and "" or tostring(branch_err),
			}, ok_branch)
			-- Error-path cleanup. On the normal path the transaction was already resumed above.
			ResumeCombinedPassEdits("surface stretch cleanup")
			-- Balanced resume (always, even on error) so the loop detector is restored.
			if type(resume_ild) == "function" then SafeCall(resume_ild, "SuperBigMapStretch") end
			if type(ClearDecorRelief) == "function" then ClearDecorRelief(map) end
			if ok_branch and map.SuperBigMapStretchPipelinePending == true then
				FinalizeDeferredStretchState(map, "surface")
			end
			-- ALWAYS mark done + expanded and close the loading box, even on error, so the game
			-- never hangs on the loading screen.
			map.SuperBigMapSurfaceStretchDone = true
			map.SuperBigMapExpanded = true
			end_loading()
			SignalExpansionReadinessChanged(map, "surface stretch complete")
			LoadingFinish("surface expansion complete", map, {
				terrain_grids = n_grids, error = ok_branch and "" or tostring(branch_err),
			}, ok_branch)
			return
		end

		end)
		if not thread_ok then
			if map.SuperBigMapStretchPipelinePending == true then
				local lifecycle = SuperBigMap.Lifecycle
				if lifecycle and type(lifecycle.Apply) == "function" then
					SafeCall(lifecycle.Apply, map, true)
				end
			end
			map.SuperBigMapStretchPipelinePending = false
			map.SuperBigMapSurfaceStretchScheduled = false
			if type(SuperBigMap.ExpansionLoadingEnd) == "function" then
				pcall(SuperBigMap.ExpansionLoadingEnd)
			end
			LoadingFinish("surface expansion thread failed", map,
				{ error = tostring(thread_ok) }, false)
		end
	end)
	if not schedule_ok then
		map.SuperBigMapStretchPipelinePending = false
		map.SuperBigMapSurfaceStretchScheduled = false
	end
	return schedule_ok == true
end


local function SyncMapDataToGrids(map)
	local terrain_api = Global("terrain")
	if type(terrain_api) ~= "table" then
		return false
	end
	if type(terrain_api.HeightMapSize) ~= "function" then
		return false
	end
	local mapdata = map and map.mapdata
	if type(mapdata) ~= "table" then
		return false
	end
	local ok, gw, gh = pcall(terrain_api.HeightMapSize, map)
	if not ok or type(gw) ~= "number" or gw <= 0 then
		return false
	end
	gh = type(gh) == "number" and gh or gw

	local old_w = type(mapdata.Width) == "number" and mapdata.Width or 0
	local old_h = type(mapdata.Height) == "number" and mapdata.Height or 0
	if old_w == gw and old_h == gh then
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
-- final buildable/passability grids, and enrichment density normalization. The underground's
-- transformed vanilla passage hex is authoritative. Surface loading projects that hex onto the
-- final surface and commits the nearest valid surface-only fallback when the exact footprint is
-- uneven, blocked, or unbuildable. Triggered from PostNewMapLoaded for Environment=="Underground"
-- maps; gates on the expansion sizes stamped by the DoGenerate wrapper (desired > generator).
local function UndergroundExpansionReadiness(map)
	if map.SuperBigMapNativeGenerationComplete ~= true then
		return false, "underground native generation has not completed"
	end
	if map.SuperBigMapCityInitializationComplete ~= true then
		return false, "underground city initialization has not completed"
	end
	local surface = Global("MainMap")
	if type(surface) ~= "table" or surface == map then
		return true, "native generation complete; no surface dependency"
	end
	if not cfg_bool("SURFACE_STRETCH_AT_START", false) then
		return true, "native generation complete; surface expansion disabled"
	end
	local grid = SuperBigMap.SectorGrid
	if type(grid) == "table" and type(grid.IsModMap) == "function"
		and grid.IsModMap(surface) ~= true then
		return true, "native generation complete; surface is not a mod map"
	end
	if surface.SuperBigMapSurfaceStretchDone == true
		or (surface.SuperBigMapExpanded == true
			and surface.SuperBigMapExpansionPending ~= true
			and surface.SuperBigMapStretchPipelinePending ~= true) then
		return true, "native generation and surface expansion complete"
	end
	return false, "surface expansion transaction has not completed"
end

local function RunUndergroundStretchIfEnabled(map, force_now)
	if not cfg_bool("STRETCH_UNDERGROUND", false) then
		return false, "underground stretch is disabled"
	end
	map = map or Global("CurrentMap")
	if not map then
		return false, "underground target map is missing"
	end
	RestoreDeferredUndergroundGeometry(map)
	if map.SuperBigMapExpanded == true and map.SuperBigMapExpansionPending ~= true then
		map.SuperBigMapUndergroundPrepared = true
		map.SuperBigMapUndergroundStretchDone = true
		map.SuperBigMapUndergroundStretchPending = false
	end
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
		return false
	end
	-- The source terrain, enrichments, and two linked passage anchors are eager. Buried-wonder
	-- construction and the expensive expansion/post-processing are postponed while the underground
	-- is not current. ChangeCurrentMapSlot is wrapped below and forces the complete pipeline before
	-- access; Elevator placement remains available meanwhile through the verified surface anchors.
	local current_map = Global("CurrentMap")
	if force_now ~= true and cfg_bool("DEFER_UNDERGROUND_EXPANSION_UNTIL_FIRST_ACCESS", false)
		and current_map ~= map then
		map.SuperBigMapUndergroundStretchPending = true
		map.SuperBigMapUndergroundStretchFailed = nil
		map.SuperBigMapUndergroundPreparationFailed = false
		SaveDeferredUndergroundGeometry(map)
		return true
	end
	local create_thread = Global("CreateRealTimeThread")
	local wait_msg = Global("WaitMsg")
	local ready_now, readiness_now = UndergroundExpansionReadiness(map)
	if force_now == true and not ready_now then
		return false, readiness_now
	end
	if force_now ~= true and (type(create_thread) ~= "function"
		or (not ready_now and type(wait_msg) ~= "function")) then
		return false, "required asynchronous engine functions are unavailable"
	end
	map.SuperBigMapUndergroundStretchPending = true
	map.SuperBigMapUndergroundStretchRunning = true
	map.SuperBigMapUndergroundStretchFailed = nil
	if cfg_bool("OPTIMIZE_STRETCH_DEFERRED_REBUILDS", true) then
		map.SuperBigMapStretchPipelinePending = true
	end
	local function run_pipeline()
		LoadingStart("underground expansion first access", map, {
			force_now = tostring(force_now == true),
		})
		local ready, readiness = UndergroundExpansionReadiness(map)
		while not ready do
			wait_msg("SuperBigMapExpansionReadinessChanged")
			ready, readiness = UndergroundExpansionReadiness(map)
		end
		-- LOADING PHASE starts only after dependencies are ready; waiting for engine events must
		-- never hold the player behind a timing-dependent loading screen.
		if type(SuperBigMap.ExpansionLoadingBegin) == "function" then
			pcall(SuperBigMap.ExpansionLoadingBegin)
			SetLoadingPhase("Expanding the underground map")
		end
		local pause_ild = Global("PauseInfiniteLoopDetection")
		local resume_ild = Global("ResumeInfiniteLoopDetection")
		if type(pause_ild) == "function" then SafeCall(pause_ild, "SuperBigMapUndergroundStretch") end
		local elevator_migrations = {}
		local underground_pipeline_token = LoadingBegin("underground expansion pipeline", map)
		local ok_branch, branch_err = pcall(function()
			-- A surface Elevator may already be finished while its paired underground half is a
			-- pending site with a destroyed linked_obj. Snapshot/remove only that underground half
			-- before any position sweep; rebuild it after the final buildable grid exists.
			if type(BeginDeferredElevatorMigration) ~= "function"
				or type(RestoreDeferredElevatorMigration) ~= "function" then
				error("deferred Elevator migration helpers are unavailable")
			end
			elevator_migrations = BeginDeferredElevatorMigration(map)
			-- Renderer bounds must cover the full 8192 grid (same fix as the surface).
			SafeCall( SyncMapDataToGrids, map)
			-- Relief annotations BEFORE the underground terrain stretch (same as the surface).
			if type(AnnotateDecorRelief) == "function" then
				AnnotateDecorRelief(map)
			end
			local position_deposits = SuperBigMap.DepositRules
			-- Preserve the complete vanilla underground population by value, not by object lifetime.
			-- This runs only when first access actually starts the stretch, so an intervening save/load
			-- still persists the original marker objects. The same records are recreated below after
			-- the final height/type grids exist.
			if not position_deposits
				or type(position_deposits.StageAndRemoveNativeEnrichmentsForStretch) ~= "function" then
				error("underground native enrichment staging API is unavailable")
			end
			SetLoadingPhase("Preserving vanilla underground resources and anomalies")
			local staged, stage_stats = position_deposits.StageAndRemoveNativeEnrichmentsForStretch(
				map, "underground immediately before terrain stretch")
			if staged ~= true then
				error("underground native enrichment staging failed: "
					.. tostring(stage_stats and stage_stats.error or "unknown error"))
			end
			SetLoadingPhase("Stretching the underground terrain")
			local ok_s, n_grids = true, 0
			if cfg_bool("EXPANSION_STEP_07_STRETCH_TERRAIN", true) then
				ok_s, n_grids = StretchSourceToFull(map)
				if ok_s ~= true or type(n_grids) ~= "number" or n_grids < 2 then
					error("underground terrain stretch did not complete its height/type grids")
				end
			end
			if type(ScaleDecorationsToFull) == "function" then
				SetLoadingPhase("Repositioning underground rocks and decorations")
				ScaleDecorationsToFull(map)
			end
			-- Reconstruct every captured native marker directly at the identical proportional hex used
			-- by the surface transaction. Constructor properties are restored before Init and the
			-- complete class/property/coordinate record set is verified before top-ups can begin.
			if not position_deposits
				or type(position_deposits.RecreateStagedNativeEnrichments) ~= "function" then
				error("underground native enrichment recreation API is unavailable")
			end
			SetLoadingPhase("Restoring vanilla underground resources and anomalies")
			local recreated, recreate_stats = position_deposits.RecreateStagedNativeEnrichments(
				map, "underground after terrain and decoration stretch")
			if recreated ~= true then
				error("underground native enrichment recreation failed: "
					.. tostring(recreate_stats and recreate_stats.error or "unknown error"))
			end
			if type(ScaleMarkersToFull) == "function" then
				SetLoadingPhase("Repositioning underground resource deposits")
				local n_mark = ScaleMarkersToFull(map, false)
				local position_deposits = SuperBigMap.DepositRules
				if position_deposits
					and type(position_deposits.VerifyNativeEnrichmentTransform) == "function" then
					local verified, verify_stats = position_deposits.VerifyNativeEnrichmentTransform(
						map, "underground after marker transform")
					if verified ~= true then
						error("native underground enrichment transformation verification failed (mismatches="
							.. tostring(verify_stats and verify_stats.mismatches or "unknown") .. ")")
					end
				end
			end
			-- The vanilla wonder-class shuffle was consumed and recorded during generation, but
			-- construction was intentionally postponed. The markers have now received the same
			-- proportional transform as the terrain, so materialize each assigned wonder at its final
			-- location before the authoritative passability/buildability rebuilds below.
			do
				SetLoadingPhase("Creating underground wonders")
				local wonder_ok, wonder_result = MaterializeDeferredUndergroundWonders(map)
				if wonder_ok ~= true then
					error("deferred underground wonder materialization failed: " .. tostring(wonder_result))
				end
			end
			-- Entrance visuals are finalized only after the authoritative underground coordinate has
			-- been cleared, prepared, moved, and validated against the final gameplay grids.
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
				local passability_token = LoadingBegin("underground final RebuildPassability", map)
				local pass_ok, pass_err = pcall(terrain_api2.RebuildPassability, map)
				LoadingEnd(passability_token, { error = pass_ok and "" or tostring(pass_err) }, pass_ok)
				if not pass_ok then error("underground final passability rebuild failed: " .. tostring(pass_err)) end
				local rebuild_buildable = Global("RebuildBuildableGrid")
				if type(rebuild_buildable) ~= "function" then
					error("underground final buildable-grid rebuild is unavailable")
				end
				SetLoadingPhase("Rebuilding the final underground build grid")
				local buildable_token = LoadingBegin("underground final RebuildBuildableGrid", map)
				local build_ok, build_err = pcall(rebuild_buildable, map)
				LoadingEnd(buildable_token, { error = build_ok and "" or tostring(build_err) }, build_ok)
				if not build_ok then error("underground final buildable-grid rebuild failed: " .. tostring(build_err)) end
				map.SuperBigMapRevalidationRebuiltGrids = true
				if #elevator_migrations > 0 then
					-- Reconstruction is never performed from inside the stretch pipeline. The records carry
					-- a monotonic generation token into CurrentMapChangeDone (or the explicit already-current
					-- lifecycle message emitted at the pipeline exit). That event is the sole authority to
					-- create the Elevator after every final grid exists on the current underground map.
					local token = QueueUndergroundElevatorRestore(map, elevator_migrations,
						Global("CurrentMap") == map and "already-current underground pipeline"
						or "pre-switch underground pipeline")
					if not token then error("failed to create underground Elevator restore transaction") end
				end
				if type(AlignPassagePairsToSharedHex) ~= "function" then
					error("final passage-pair alignment API is unavailable")
				end
				SetLoadingPhase("Aligning surface and underground passage entrances")
				local pair_ok, pair_stats = AlignPassagePairsToSharedHex(map)
				if pair_ok ~= true then
					error("final passage-pair alignment failed: "
						.. tostring(pair_stats and pair_stats.error or "unknown error"))
				end
				if type(MoveEntranceVisualsToScale) == "function" then
					MoveEntranceVisualsToScale(map)
				end
				-- CityInitialized deliberately skipped SurfacePassage:Spawn while the source-sized
				-- buildable grid disagreed with the expanded object grid. Align and prepare the immutable
				-- true underground coordinate first, then create the deferred markers at that final
				-- position so they cannot masquerade as blockers or retain a stale source coordinate.
				SetLoadingPhase("Activating underground passage markers")
				local tunnel_ok, tunnel_result = MaterializeDeferredUndergroundTunnelSpawns(map)
				if tunnel_ok ~= true then
					error("deferred underground passage-marker activation failed: "
						.. tostring(tunnel_result))
				end
				local deposits = SuperBigMap.DepositRules
				if not deposits then error("underground deposit rules are unavailable") end
				if type(deposits.ClearTopUpPlacementPool) == "function" then
					deposits.ClearTopUpPlacementPool(map)
				end
				if type(deposits.PrepareUndergroundReachability) ~= "function" then
					error("underground entrance-reachability preparation is unavailable")
				end
				local reach_ok, reach_state = deposits.PrepareUndergroundReachability(map)
				if reach_ok ~= true then
					error("underground entrance connectivity could not be initialized (seeds="
						.. tostring(reach_state and #reach_state.seeds or 0) .. ")")
				end
			-- DENSITY NORMALIZATION (same suite as the surface stretch branch): the underground
			-- grew by the same x1.78 area, so its enrichments must be topped up to vanilla
			-- density too. The factor is correct per buildable area because the buildable floor
			-- stretches by the same factor as the map.
			-- Placement pools are buildable-floor-only underground (CanReceiveDeposit), so no
			-- enrichment lands in the inaccessible rock/void.
			do
				local deposits = SuperBigMap.DepositRules
				if deposits then
					if type(deposits.TopUpDeposits) == "function" then
						SetLoadingPhase("Distributing underground resources and anomalies")
						TimedSafeCall("underground top-up resources", map,
							deposits.TopUpDeposits, map)
					end
					if type(deposits.TopUpAnomalies) == "function" then
						TimedSafeCall("underground top-up anomalies", map,
							deposits.TopUpAnomalies, map)
					end
					if type(deposits.TopUpEffectDeposits) == "function" then
						TimedSafeCall("underground top-up effect deposits", map,
							deposits.TopUpEffectDeposits, map)
					end
					if type(deposits.RegisterClonedMarkers) == "function" then
						TimedSafeCall("underground register top-up markers", map,
							deposits.RegisterClonedMarkers, map)
					end
					if type(deposits.RelocateUnreachableUndergroundEnrichments) ~= "function" then
						error("underground enrichment reachability audit is unavailable")
					end
				SetLoadingPhase("Moving underground enrichments onto reachable terrain")
				local reachability_token = LoadingBegin(
					"underground relocate unreachable enrichments", map)
				local audit_ok, audit_stats = deposits.RelocateUnreachableUndergroundEnrichments(map)
				LoadingEnd(reachability_token, {
					moved = audit_stats and audit_stats.moved,
					unresolved = audit_stats and audit_stats.unresolved,
				}, audit_ok == true)
					if audit_ok ~= true then
						error("underground enrichment reachability audit left "
							.. tostring(audit_stats and audit_stats.unresolved or "unknown") .. " unresolved markers")
					end
					if type(deposits.ResolveBadgeMarkerOverlaps) == "function" then
						TimedSafeCall("underground resolve marker overlaps", map,
							deposits.ResolveBadgeMarkerOverlaps, map, "underground reachable density suite")
					end
					if type(deposits.AuditTopUpVanillaRepulsion) ~= "function" then
						error("top-up vanilla repulsion audit is unavailable")
					end
					local repulsion_token = LoadingBegin("underground hard repulsion audit", map)
					local repulsion_ok, repulsion_stats =
						deposits.AuditTopUpVanillaRepulsion(map, "underground final after density suite")
					LoadingEnd(repulsion_token, {
						violations = repulsion_stats and repulsion_stats.repulsion_violations,
					}, repulsion_ok == true)
					if repulsion_ok ~= true then
						error("underground top-up vanilla repulsion audit failed: density_failures="
							.. tostring(repulsion_stats and repulsion_stats.density_failures)
							.. " duplicate_hex_pairs="
							.. tostring(repulsion_stats and repulsion_stats.duplicate_hex_pairs)
							.. " repulsion_violations="
							.. tostring(repulsion_stats and repulsion_stats.repulsion_violations))
					end
					if type(deposits.DebugAuditFinalEnrichments) == "function" then
						local audit_token = LoadingBegin("diagnostic underground enrichment audit", map)
						local call_ok, audit_ok, audit_stats = pcall(
							deposits.DebugAuditFinalEnrichments, map,
							"underground final before temporary reveal")
						LoadingEnd(audit_token, {
							audit_ok = tostring(audit_ok),
							error = call_ok and "" or tostring(audit_ok),
							markers = call_ok and audit_stats and audit_stats.markers or nil,
						}, call_ok and audit_ok ~= false)
					end
					if cfg_bool("UNDERGROUND_REVEAL_ALL_ENRICHMENTS_FOR_TESTING", false) then
						if type(deposits.RevealAllUndergroundEnrichmentsForTesting) ~= "function" then
							error("temporary underground enrichment reveal API is unavailable")
						end
						SetLoadingPhase("Revealing underground enrichments for verification")
						local reveal_ok, reveal_stats =
							deposits.RevealAllUndergroundEnrichmentsForTesting(map)
						if reveal_ok ~= true then
							error("temporary underground enrichment reveal failed: "
								.. tostring(reveal_stats and reveal_stats.error or "unknown error"))
						end
						if type(deposits.DebugAuditFinalEnrichments) == "function" then
							local audit_token = LoadingBegin(
								"diagnostic underground post-reveal enrichment audit", map)
							local call_ok, audit_ok, audit_stats = pcall(
								deposits.DebugAuditFinalEnrichments, map,
								"underground after temporary RevealDeposits")
							LoadingEnd(audit_token, {
								audit_ok = tostring(audit_ok),
								error = call_ok and "" or tostring(audit_ok),
								markers = call_ok and audit_stats and audit_stats.markers or nil,
							}, call_ok and audit_ok ~= false)
						end
					end
					if type(deposits.ClearTopUpPlacementPool) == "function" then
						deposits.ClearTopUpPlacementPool(map)
					end
				end
			end
			end
			-- (Buildable + passability rebuilds moved ABOVE the density suite -- its
			-- buildable-floor-only pools need the live grid.)
		end)
		LoadingEnd(underground_pipeline_token, {
			elevator_migrations = #elevator_migrations,
			error = ok_branch and "" or tostring(branch_err),
		}, ok_branch)
		if not ok_branch and type(elevator_migrations) == "table" and #elevator_migrations > 0 then
			-- A partially failed terrain transaction is not a safe context in which to touch native
			-- supply grids. Invalidate the token and keep underground access blocked; never recreate
			-- the Elevator on the still-current surface or on grids whose rebuild did not complete.
			local failed_token = CurrentElevatorRestoreToken(map)
			if failed_token then
				failed_token.cancelled = true
				failed_token.status = "pipeline-failed"
				underground_elevator_restore_tokens[failed_token.token_id] = nil
			end
			pending_underground_elevator_restores[map] = nil
			map.SuperBigMapDeferredElevatorRestorePending = nil
			map.SuperBigMapDeferredElevatorRestoreToken = nil
		end
		if type(resume_ild) == "function" then SafeCall(resume_ild, "SuperBigMapUndergroundStretch") end
		if type(ClearDecorRelief) == "function" then ClearDecorRelief(map) end
		if ok_branch and map.SuperBigMapStretchPipelinePending == true then
			FinalizeDeferredStretchState(map, "underground")
		elseif map.SuperBigMapStretchPipelinePending == true then
			local lifecycle = SuperBigMap.Lifecycle
			if lifecycle and type(lifecycle.Apply) == "function" then SafeCall(lifecycle.Apply, map, true) end
			map.SuperBigMapStretchPipelinePending = false
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
		local msg = Global("Msg")
		if type(msg) == "function" then
			local restore_token = ok_branch and Global("CurrentMap") == map
				and CurrentElevatorRestoreToken(map) or nil
			if restore_token then
				pcall(msg, "SuperBigMapUndergroundSupplyReady", map,
					restore_token.token_id, "already-current pipeline complete")
			end
			pcall(msg, "SuperBigMapUndergroundExpansionDone", map, ok_branch, branch_err)
		end
		-- End of this loading phase (single exit point of the thread; every step above is
		-- pcall-guarded, so this always runs).
		if type(SuperBigMap.ExpansionLoadingEnd) == "function" then
			pcall(SuperBigMap.ExpansionLoadingEnd)
		end
		if force_now ~= true then
			LoadingFinish("underground asynchronous expansion complete", map, {
				elevator_migrations = #elevator_migrations,
				error = ok_branch and "" or tostring(branch_err),
			}, ok_branch)
		end
		return ok_branch == true, branch_err
	end
	if force_now == true then
		return run_pipeline()
	end
	create_thread(run_pipeline)
	return true
end

-- Persistent readiness handoff used by lifecycle completion events. PostNewMapLoaded may run
-- while the random generator is still filling terrain and objects, so it may only register a
-- deferred request. Both milestones are required: MapGenerated proves native terrain/object
-- generation returned; CityInitialized proves exploration and breakthrough placement returned.
local function NotifyGenerationMilestone(map, milestone, source)
	if type(map) ~= "table" then return false end
	local grid = SuperBigMap.SectorGrid
	local is_mod_map = type(grid) == "table" and type(grid.IsModMap) == "function"
		and grid.IsModMap(map) == true
	if not is_mod_map and map.SuperBigMapExpansionPending ~= true then
		-- These readiness fields are part of the stretch transaction.  A normal map
		-- must not acquire SuperBigMap state merely because the persistent lifecycle
		-- lifecycle handlers saw MapGenerated/CityInitialized.
		return false
	end
	if milestone == "MapGenerated" then
		map.SuperBigMapNativeGenerationComplete = true
		map.SuperBigMapNativeGenerationCompleteSource = tostring(source or milestone)
	elseif milestone == "CityInitialized" then
		map.SuperBigMapCityInitializationComplete = true
	else
		return false
	end
	SignalExpansionReadinessChanged(map, tostring(milestone) .. ": " .. tostring(source or milestone))

	local env = map.mapdata and map.mapdata.Environment
	if env == "Surface" then
		if is_mod_map and map.SuperBigMapVanillaSourceMigration ~= true then
			return RunSurfaceStretchIfEnabled(map, source)
		end
		return true
	end
	if env == "Underground" then
		return RunUndergroundStretchIfEnabled(map)
	end
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
	if type(current) ~= "function" then
		return false
	end
	if current == State.underground_hud_init_wrapper
		and State.underground_hud_patch_version == GENERATOR_PATCH_VERSION then
		return true
	end
	-- Another engine/mod layer may wrap this constructor after us. Preserve that generic chain
	-- instead of wrapping it a second time: our stored wrapper remains its predecessor, while the
	-- CurrentMapChangeDone recovery independently guarantees preparation if a reload replaced it.
	if State.underground_hud_init_wrapper ~= nil
		and current ~= State.underground_hud_init_wrapper
		and State.underground_hud_patch_version == GENERATOR_PATCH_VERSION then
		return true
	end
	if current == State.underground_hud_init_wrapper
		and type(State.original_underground_hud_init) == "function" then
		current = State.original_underground_hud_init
		hud_class.Init = current
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
			return
		end
		local ok_init, result = pcall(captured_original_init, self, parent, context)
		State.underground_hud_init_depth = depth - 1
		if not ok_init then
			error(result)
		end
		local frame = self and self[1]
		if type(frame) ~= "table" or type(frame.OnPress) ~= "function" then
			return result
		end
		if frame.SuperBigMapUndergroundAccessPressVersion == GENERATOR_PATCH_VERSION then
			return result
		end
		local original_press = frame.OnPress
		frame.OnPress = function(button, gamepad)
			local target, entry, entry_source = ResolveHudUndergroundTarget(button)
			local needs_prepare, reason = NeedsDeferredUndergroundPreparation(target)
			if not needs_prepare then
				return original_press(button, gamepad)
			end
			if button.SuperBigMapUndergroundAccessClickRunning == true then
				return
			end
			local create_thread = Global("CreateRealTimeThread")
			if type(create_thread) ~= "function" then
				return original_press(button, gamepad)
			end
			button.SuperBigMapUndergroundAccessClickRunning = true
			create_thread(function()
				local gate = State.change_current_map_slot_wrapper
				if type(gate) == "function" and target and target.slot then
					gate(target.slot, true, "idChangeCurrentMapSlot")
				end
				button.SuperBigMapUndergroundAccessClickRunning = false
			end)
			return
		end
		frame.SuperBigMapUndergroundAccessPressVersion = GENERATOR_PATCH_VERSION
		frame.SuperBigMapUndergroundAccessOriginalPress = original_press
		return result
	end
	hud_class.Init = wrapper
	State.underground_hud_init_wrapper = wrapper
	State.underground_hud_patch_version = GENERATOR_PATCH_VERSION
	return true
end

-- FIRST-ACCESS GATE. Every vanilla HUD/object route that changes between already-loaded map
-- slots funnels through ChangeCurrentMapSlot. Hold that one call before it emits CurrentMapChange
-- or exposes the target map, run the complete deferred underground pipeline, and switch only on
-- success. The normal map-switch loading screen is opened BEFORE the heavy work and kept open
-- across the eventual switch. The committed entrance footprint is naturally valid before the
-- native passage-pad preparation runs; final alignment never turns an invalid candidate into one.
local function PatchDeferredUndergroundAccess(source)
	if not cfg_bool("EXPANSION_STEP_02_STRETCH_AND_TRANSFORM_VANILLA_SOURCE", false) then return false end
	PatchSupplyGridOverlayCopyGuard(source)
	PatchElevatorSupplyTransactionBoundary(source)
	local State = SuperBigMap.State
	local current = Global("ChangeCurrentMapSlot")
	if type(current) ~= "function" then
		PatchDeferredUndergroundHudAccess(source)
		return false
	end
	if current == State.change_current_map_slot_wrapper
		and State.underground_access_patch_version == GENERATOR_PATCH_VERSION then
		PatchDeferredUndergroundHudAccess(source)
		return true
	end
	-- Hot-reload upgrade: unwrap our previous closure before capturing the vanilla original.
	if current == State.change_current_map_slot_wrapper
		and type(State.original_change_current_map_slot) == "function" then
		current = State.original_change_current_map_slot
		rawset(_G, "ChangeCurrentMapSlot", current)
	end
	State.original_change_current_map_slot = current
	local captured_original_switch = current
	local wrapper = function(map_slot, loading_screen, loading_screen_id)
		-- Immutable predecessor: later lifecycle verification may update shared patch state, but an
		-- already-installed closure must never change which function it calls.
		local original = captured_original_switch
		if type(original) ~= "function" then
			return
		end
		local maps = Global("Maps")
		local target = type(maps) == "table" and maps[map_slot] or nil
		RestoreDeferredUndergroundGeometry(target)
		local env = target and target.mapdata and target.mapdata.Environment
		local needs_prepare, decision = NeedsDeferredUndergroundPreparation(target)
		if not needs_prepare then
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
			local create_box = Global("CreateMessageBox")
			if type(create_box) == "function" then
				local untranslated = Global("Untranslated")
				local wrap = type(untranslated) == "function" and untranslated or function(s) return s end
				pcall(create_box, nil, wrap("Super Big Map"), wrap(
					"The underground could not be prepared safely, so access remains blocked. "
					.. "\n\n" .. tostring(reason or "Unknown error")))
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
			LoadingFinish("underground first-access preparation failed", target,
				{ error = tostring(err or target.SuperBigMapUndergroundStretchFailed) }, false)
			return false
		end

		SetLoadingPhase("Opening the completed underground map")
		-- We already own the screen, so suppress the original's open/close pair and close it only
		-- after ChangeCurrentMapSlot has switched maps and waited for scene rendering.
		local switch_restore_token = CurrentElevatorRestoreToken(target)
		local switch_restore_token_id = switch_restore_token and switch_restore_token.token_id
		local result = original(map_slot, screen_open and false or loading_screen, loading_screen_id)
		-- CurrentMapChangeDone is synchronous inside the original switch. It must have consumed the
		-- queued token; never perform a post-return reconstruction here, because that would recreate
		-- the old race with later engine lifecycle work.
		local after_token = switch_restore_token_id and CurrentElevatorRestoreToken(
			target, switch_restore_token_id) or nil
		local lifecycle_failed = after_token and after_token.status == "failed"
		local lifecycle_missed = after_token and after_token.status == "queued"
		if lifecycle_failed or lifecycle_missed then
			local restored_result = after_token.failure or
				"CurrentMapChangeDone did not consume Elevator restore token "
				.. tostring(switch_restore_token_id)
			target.SuperBigMapUndergroundPreparationFailed = true
			target.SuperBigMapUndergroundStretchFailed = tostring(restored_result)
			if screen_open and type(close_screen) == "function" then close_screen(screen_id, map_slot) end
			show_failure("Underground Elevator restoration failed at the map lifecycle boundary: "
				.. tostring(restored_result))
			LoadingFinish("underground map switch or Elevator restoration failed", target,
				{ error = tostring(restored_result), token = tostring(switch_restore_token_id) }, false)
			return false
		end
		if screen_open and type(close_screen) == "function" then close_screen(screen_id, map_slot) end
		LoadingFinish("underground first access complete", target, {
			elevator_token = tostring(switch_restore_token_id),
			elevator_token_status = tostring(after_token and after_token.status or "consumed-or-none"),
		}, true)
		return result
	end
	rawset(_G, "ChangeCurrentMapSlot", wrapper)
	State.change_current_map_slot_wrapper = wrapper
	State.underground_access_patch_version = GENERATOR_PATCH_VERSION
	PatchDeferredUndergroundHudAccess(source)
	return true
end

-- Last-resort safety net for switch routes that bypass both replaceable entry points. It runs
-- immediately after CurrentMapChangeDone in its own real-time thread, covers the already-current
-- underground with a loading screen, and completes the exact same atomic preparation pipeline.
-- This also covers generated HUD routes that bypass the replaceable entry points.
local function HandleDeferredUndergroundMapChange(map_slot, map)
	local needs_prepare, decision = NeedsDeferredUndergroundPreparation(map)
	if not needs_prepare then return false end
	if underground_recovery_maps[map] == true then
		return true
	end
	local create_thread = Global("CreateRealTimeThread")
	if type(create_thread) ~= "function" then
		return false
	end
	underground_recovery_maps[map] = true
	create_thread(function()
		local screen_id = "idSuperBigMapUndergroundFirstAccessRecovery"
		local open_screen = Global("LoadingScreenOpen")
		local close_screen = Global("LoadingScreenClose")
		local wait_render = Global("WaitRenderMode")
		local screen_open = type(open_screen) == "function"
		if screen_open then
			open_screen(screen_id, map_slot)
			if type(wait_render) == "function" then wait_render("ui") end
		end
		SetLoadingPhase("Preparing the underground map after a bypassed first-access switch")
		local ok, err = RunUndergroundStretchIfEnabled(map, true)
		if screen_open and type(close_screen) == "function" then
			close_screen(screen_id, map_slot)
			if type(wait_render) == "function" then wait_render("scene") end
		end
		underground_recovery_maps[map] = nil
		LoadingFinish("underground bypass-recovery complete", map,
			{ error = ok == true and "" or tostring(err) }, ok == true)
		if ok ~= true then
			local create_box = Global("CreateMessageBox")
			if type(create_box) == "function" then
				local untranslated = Global("Untranslated")
				local wrap = type(untranslated) == "function" and untranslated or function(s) return s end
				pcall(create_box, nil, wrap("Super Big Map"), wrap(
					"The underground first-access route bypassed its preparation gate, and recovery failed. "
					.. "\n\n" .. tostring(err or "Unknown error")))
			end
		end
	end)
	return true
end

local MapGeneration = {}

MapGeneration.RunUndergroundStretchIfEnabled = RunUndergroundStretchIfEnabled
MapGeneration.ShouldDeferStretchRebuilds = ShouldDeferStretchRebuilds
MapGeneration.FinalizeExpandedMap = FinalizeExpandedMap
MapGeneration.AttachPendingMapState = AttachPendingMapState
MapGeneration.PrepareMapDataForExpansion = PrepareMapDataForExpansion
MapGeneration.PatchRandomMapGenerator = PatchRandomMapGenerator
MapGeneration.PatchDeferredUndergroundAccess = PatchDeferredUndergroundAccess
MapGeneration.PatchEntranceBadgePosition = PatchEntranceBadgePosition
MapGeneration.RestoreEntranceBadgePositions = RestoreEntranceBadgePositions
MapGeneration.HandleDeferredUndergroundMapChange = HandleDeferredUndergroundMapChange
MapGeneration.HandlePendingUndergroundElevatorRestore = HandlePendingUndergroundElevatorRestore
MapGeneration.SyncMapDataToGrids = SyncMapDataToGrids
MapGeneration.RunSurfaceStretchIfEnabled = RunSurfaceStretchIfEnabled
MapGeneration.NotifyGenerationMilestone = NotifyGenerationMilestone
MapGeneration.ReinvalidateExpandedTerrain = ReinvalidateExpandedTerrain
MapGeneration.RestorePreparedMapDataForVanillaSession = RestorePreparedMapDataForVanillaSession

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
		PatchEntranceBadgePosition()
		PatchDeferredUndergroundAccess("ApplyModBehavior")
	end
	return true
end

-- Restoring only affects future generation; already-expanded maps retain their terrain.
function MapGeneration.RestoreVanillaBehavior()
	local State = SuperBigMap.State or {}
	-- Restore process-shared MapData presets as part of the domain teardown too,
	-- not only through the main-menu convenience path. This covers config disable,
	-- hot reload, and any alternate session exit that calls Lifecycle.Disable.
	RestorePreparedMapDataForVanillaSession("MapGeneration.RestoreVanillaBehavior")
	local generator_class = Global("RandomMapGenerator")
	if type(generator_class) == "table" then
		if type(State.generator_original_generate) == "function" then
			generator_class.Generate = State.generator_original_generate
		end
		if type(State.generator_original_do_generate) == "function" then
			generator_class.DoGenerate = State.generator_original_do_generate
		end
		if type(State.generator_original_on_generate_logic) == "function" then
			generator_class.OnGenerateLogic = State.generator_original_on_generate_logic
		end
	end
	State.generator_original_generate = nil
	State.generator_original_do_generate = nil
	State.generator_original_on_generate_logic = nil
	State.generator_generate_wrapper = nil
	State.generator_do_generate_wrapper = nil
	State.generator_on_generate_logic_wrapper = nil
	State.rmg_placement_active_map = nil
	State.sbm_entrance_pads = nil
	State.vanilla_source_migration_active = nil
	State.generator_patch_version = nil
	local surface_passage_class = Engine.ClassTable and Engine.ClassTable("SurfacePassage")
	if type(surface_passage_class) == "table" and State.deferred_tunnel_spawn_wrapper
		and surface_passage_class.Spawn == State.deferred_tunnel_spawn_wrapper
		and type(State.original_surface_passage_spawn) == "function" then
		surface_passage_class.Spawn = State.original_surface_passage_spawn
	end
	State.deferred_tunnel_spawn_wrapper = nil
	State.original_surface_passage_spawn = nil
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
	State.underground_hud_init_depth = nil
	local elevator_supply_class = Engine.ClassTable and Engine.ClassTable("Elevator")
	if type(elevator_supply_class) == "table" and State.elevator_supply_connect_wrapper
		and elevator_supply_class.SupplyGridConnectElement == State.elevator_supply_connect_wrapper
		and type(State.original_elevator_supply_connect) == "function" then
		elevator_supply_class.SupplyGridConnectElement = State.original_elevator_supply_connect
	end
	if type(elevator_supply_class) == "table" and State.elevator_passage_merge_wrapper
		and elevator_supply_class.MergeGrids == State.elevator_passage_merge_wrapper
		and type(State.original_elevator_passage_merge_grids) == "function" then
		elevator_supply_class.MergeGrids = State.original_elevator_passage_merge_grids
	end
	State.elevator_supply_connect_wrapper = nil
	State.original_elevator_supply_connect = nil
	State.elevator_passage_merge_wrapper = nil
	State.original_elevator_passage_merge_grids = nil
	State.elevator_supply_boundary_patch_version = nil
	if State.supply_grid_overlay_copy_wrapper
		and Global("CopySupplyFragmentToOverlayGrid") == State.supply_grid_overlay_copy_wrapper
		and type(State.original_supply_grid_overlay_copy) == "function" then
		rawset(_G, "CopySupplyFragmentToOverlayGrid", State.original_supply_grid_overlay_copy)
	end
	State.supply_grid_overlay_copy_wrapper = nil
	State.original_supply_grid_overlay_copy = nil
	State.supply_grid_overlay_copy_patch_version = nil
	for key in pairs(blocked_maps) do blocked_maps[key] = nil end
	for key in pairs(underground_recovery_maps) do underground_recovery_maps[key] = nil end
	State.underground_elevator_restore_epoch =
		(State.underground_elevator_restore_epoch or 0) + 1
	for key, token in pairs(pending_underground_elevator_restores) do
		if type(token) == "table" then
			token.cancelled = true
			token.status = "teardown"
			for _, record in ipairs(token.records or {}) do
				if type(record.rebuilt_elevator) == "table" then
					record.rebuilt_elevator.SuperBigMapElevatorRestoreToken = nil
					record.rebuilt_elevator.SuperBigMapElevatorRestoreRecord = nil
				end
			end
		end
		pending_underground_elevator_restores[key] = nil
	end
	for key in pairs(underground_elevator_restore_tokens) do
		underground_elevator_restore_tokens[key] = nil
	end
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
		PatchEntranceBadgePosition()
		PatchDeferredUndergroundAccess("module load")
	end
end

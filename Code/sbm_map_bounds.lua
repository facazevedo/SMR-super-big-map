-- Super Big Map -- playable-map bounds.
--
-- Expands the loaded map's playable construction boundary to the full terrain:
-- clears the vanilla PassBorder (saving the original for restore), resets the
-- play and constructable areas, rebuilds passability/buildable grids, re-fits
-- the sector grid boxes, and installs three permissive class-table overrides
-- that make construction status checks pass across the expanded edge sectors.
-- All of this is gated on Config.FULL_MAP_PLAYABLE. The per-map work is driven
-- by SuperBigMap.Lifecycle.Apply; RestoreVanillaBehavior reverses every step.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local FullHeightMin = Engine.FullHeightMin
local FullHeightMax = Engine.FullHeightMax
local Unpack = table.unpack or unpack

local function Pack(...)
	return { n = select("#", ...), ... }
end

-- Fresh per execution: same-version hot reloads must not retain old closures/code.
local MODULE_TOKEN = {}

local function IsLegacyMapBoundsFunction(fn)
	local debug_api = rawget(_G, "debug")
	if type(debug_api) ~= "table" or type(debug_api.getinfo) ~= "function" then return false end
	local ok, info = pcall(debug_api.getinfo, fn, "S")
	local source = ok and type(info) == "table" and tostring(info.source or "") or ""
	return string.find(string.lower(source), "sbm_map_bounds", 1, true) ~= nil
end

-- World units per map tile (const.HeightTileSize, default 100).
local function TileWorldSize(mapdata)
	local const_tbl = Global("const")
	if type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number" and const_tbl.HeightTileSize > 0 then
		return const_tbl.HeightTileSize
	end
	return 100
end

-- Round value UP to a multiple of granularity (integer-safe).
local function AlignUp(value, granularity)
	if type(granularity) ~= "number" or granularity <= 0 then
		return value
	end
	local n = math.floor((value + granularity - 1) / granularity)
	return n * granularity
end

-- Impassable edge border (world units) for the expanded map. DEFAULT 0 = full
-- passability (so rovers from an edge/frame landing are never trapped -- the long-
-- standing PassBorder=0 fix); the heat-query clamp (sbm_heat_safety) keeps that safe.
-- A positive Config.EXPANDED_MAP_EDGE_BORDER sets an impassable ring instead, rounded
-- UP to a const.MapPatchSize multiple (the engine asserts nPassBorder % MAP_PATCH == 0;
-- 0 is always a valid multiple).
local function SafeEdgeBorder()
	local cfg = SuperBigMap.Config or {}
	local override = cfg.EXPANDED_MAP_EDGE_BORDER
	local want = (type(override) == "number" and override > 0) and math.floor(override) or 0
	if want <= 0 then
		return 0
	end
	local const_tbl = Global("const")
	local patch = (type(const_tbl) == "table" and type(const_tbl.MapPatchSize) == "number" and const_tbl.MapPatchSize > 0)
		and const_tbl.MapPatchSize or nil
	if not patch then
		return 0 -- cannot align a positive value safely; full passability is always valid
	end
	return AlignUp(want, patch)
end

-- Map liveness / terrain size are intentionally NOT in sbm_engine (their resolution
-- order is context-specific); each consumer keeps its own copy.
local IsLiveMap = Engine.IsLiveMap

local TerrainSize = Engine.TerrainSize

local function FullMapPlayableEnabled()
	local cfg = SuperBigMap.Config
	return (cfg and cfg.FULL_MAP_PLAYABLE) == true
end

-- "Did this mod generate/expand this map?" -- the single gate that keeps ALL
-- bounds work inert on vanilla maps and on old saves that were started without
-- the mod (no expansion markers). Delegates to the authoritative predicate in
-- SuperBigMap.SectorGrid (loaded before this module). Without it, FULL_MAP_PLAYABLE
-- would rewrite PassBorder / play areas on any loaded map, which is exactly what
-- "do nothing on non-mod saves" forbids.
local function IsModMap(map)
	local grid = SuperBigMap.SectorGrid
	if grid and type(grid.IsModMap) == "function" then
		return grid.IsModMap(map) == true
	end
	return false
end

-- PassBorder gates the engine's placement bounds (flatten tool, building
-- placement, etc.): anything outside [PassBorder, width-PassBorder] is "out
-- of bounds". When FullMapPlayable is on we want the WHOLE terrain to be
-- flatten-able and buildable, including the new edge sectors, so PassBorder is forced
-- to 0. We deliberately do NOT clobber mapdata.playable_height_range /
-- visible_height_range -- vanilla landscape code reads .from / .to off those
-- tables to build the bbox z-component, and clearing them causes the native
-- HGE::Landscape_MarkLine to assert on bbox.IsValid().
local function ResetMapDataBounds(map, mapdata)
	if not FullMapPlayableEnabled() then
		return
	end

	if not IsModMap(map) then
		return
	end

	mapdata = mapdata or map and map.mapdata
	if not mapdata then
		return
	end

	if mapdata.SuperBigMapOriginalPassBorderCaptured ~= true then
		mapdata.SuperBigMapOriginalPassBorderCaptured = true
		mapdata.SuperBigMapOriginalPassBorderWasNil = mapdata.PassBorder == nil
		mapdata.SuperBigMapOriginalPassBorder = mapdata.PassBorder
		mapdata.SuperBigMapOriginalPassBorderTilesWasNil = mapdata.PassBorderTiles == nil
		mapdata.SuperBigMapOriginalPassBorderTiles = mapdata.PassBorderTiles
	end

	-- Default PassBorder = 0 so the whole expanded map is available. The engine's gameplay grids (heat, etc.) only
	-- cover [HeatGridBorder, size-HeatGridBorder], but we keep the map passable and CLAMP
	-- the heat query (sbm_heat_safety) rather than wall it off. A positive
	-- Config.EXPANDED_MAP_EDGE_BORDER instead sets an impassable ring (MapPatch-aligned).
	local border = SafeEdgeBorder()
	mapdata.PassBorder = border
	local tile = TileWorldSize(mapdata)
	mapdata.PassBorderTiles = (tile > 0) and math.floor(border / tile) or 0
end

local function ResetMapAreas(map)
	if not FullMapPlayableEnabled() or not map then
		return
	end

	if not IsModMap(map) then
		return
	end

	local width, height = TerrainSize(map)
	if not width or not height or width <= 0 or height <= 0 then
		return
	end

	if type(map.SetPlayArea) == "function" then
		SafeCall(map.SetPlayArea, map, false, true)
	elseif Global("box") then
		map.PlayArea = box(0, 0, 0, width, height, FullHeightMax())
	end

	if Global("box") then
		map.ConstructableArea = box(0, 0, width, height)
	end

	local camera = Global("cameraRTS")
	if camera and type(camera.SetBoundingBox) == "function" then
		local area = type(map.GetPlayArea) == "function" and SafeCall(map.GetPlayArea, map) or map.PlayArea
		if area then
			SafeCall(camera.SetBoundingBox, area)
		end
	end
end

local function RebuildMapBounds(map, skip_buildable)
	if not IsModMap(map) then
		return
	end

	local terrain_api = Global("terrain")

	if terrain_api and type(terrain_api.SetPassableHeight) == "function" then
		SafeCall(terrain_api.SetPassableHeight, map, FullHeightMin(), FullHeightMax())
	end

	if terrain_api and type(terrain_api.RebuildPassability) == "function" then
		SafeCall(terrain_api.RebuildPassability, map)
	end

	-- Stretch-eligible surface NewMap loads already have the engine-built blank-map grid. Keep
	-- the bounds/passable-height/passability work above, but allow that one identical buildable
	-- rebuild to be skipped. The later lifecycle/generator/final revalidations retain the
	-- authoritative grid, and all other callers keep the original full rebuild by default.
	local rebuild_buildable = Global("RebuildBuildableGrid")
	if not skip_buildable and type(rebuild_buildable) == "function" and map and map.buildable then
		SafeCall(rebuild_buildable, map)
	end
end

local function RefreshSectors(map)
	if not IsModMap(map) then
		return
	end

	local city = map and map.City
	local sectors = city and city.MapSectors
	local tile_size_fn = Global("GetMapSectorTileSize")
	local box_fn = Global("box")

	if type(sectors) ~= "table" or #sectors == 0 or type(tile_size_fn) ~= "function" or not box_fn then
		return
	end

	local tile = SafeCall(tile_size_fn, map)
	if not tile or tile <= 0 then
		return
	end

	local sector_count = Global("const") and const.SectorCount or 10
	local unbuildable_z = Global("buildUnbuildableZ") and buildUnbuildableZ() or false
	local build_ratio = Global("BuildableGridRatio")

	for j = 1, sector_count do
		local row = sectors[j]
		if type(row) == "table" then
			local x = (j - 1) * tile
			for i = 1, sector_count do
				local sector = row[i]
				if sector then
					local y = (i - 1) * tile
					sector.area = box_fn(x, y, x + tile, y + tile)
					-- MapSector is a saved object separate from .area. Vanilla's scan FX and
					-- UpdateDecal use GetPos(), so keep it synchronized whenever bounds move.
					if type(sector.SetPos) == "function" then
						SafeCall(sector.SetPos, sector, sector.area:Center())
					end

					if type(build_ratio) == "function" and map.buildable and map.buildable.z_grid and unbuildable_z then
						sector.play_ratio = SafeCall(build_ratio, map.buildable.z_grid, unbuildable_z, 100, sector.area) or sector.play_ratio
					end

					if type(sector.UpdateDecal) == "function" then
						SafeCall(sector.UpdateDecal, sector)
					end
				end
			end
		end
	end

	if type(city.InitMapArea) == "function" then
		SafeCall(city.InitMapArea, city)
	end
end

local MapBounds = {}

MapBounds.FullMapPlayableEnabled = FullMapPlayableEnabled
MapBounds.ResetMapDataBounds = ResetMapDataBounds
MapBounds.ResetMapAreas = ResetMapAreas
MapBounds.RebuildMapBounds = RebuildMapBounds
MapBounds.RefreshSectors = RefreshSectors

-- ---------------------------------------------------------------------------
-- LandscapeConstructionController:ValidateMark permissive override
-- ---------------------------------------------------------------------------
-- Final piece of the "Out of bounds" fix. SMR's Landscape Lua files load under
-- a custom _ENV: rawset(_G, "LandscapeMarkSmooth", ...) does not propagate to
-- LandscapeConstructionController:ValidateMark's lookup path (verified -- a
-- prior attempt wrapped the global but never fired, while LCC's mark_fail
-- stayed true). The LCC class table itself IS reachable via Engine.ClassTable,
-- so override ValidateMark there. We still call the original so it gets a
-- chance to populate self.obstruct_handles / self.obstruct_marks (overlap
-- detection), then convert any falsy result to true; the caller in
-- LandscapeTerraceController:Mark (and its peers) then sees success=true,
-- self.mark_fail = not true = false, and LandscapeOutOfBounds no longer fires.

local function InstallLCCValidateMarkPermissive()
	local class_table_fn = Engine.ClassTable
	if type(class_table_fn) ~= "function" then
		return
	end
	local cls = class_table_fn("LandscapeConstructionController")
	if not cls or type(cls.ValidateMark) ~= "function" then
		return
	end
	if rawget(_G, "BMOriginal_LCC_ValidateMark") then
		return
	end
	local original = cls.ValidateMark
	rawset(_G, "BMOriginal_LCC_ValidateMark", original)

	cls.ValidateMark = function(self, test)
		local result = original(self, test)
		-- Permissive (treat falsy as success) only on mod-expanded maps; on vanilla
		-- maps / non-mod saves landscape validation stays exactly vanilla.
		if (result == false or result == nil) and IsModMap(Global("CurrentMap")) then
			return true
		end
		return result
	end
end

local function UninstallLCCValidateMarkPermissive()
	local class_table_fn = Engine.ClassTable
	if type(class_table_fn) ~= "function" then return end
	local cls = class_table_fn("LandscapeConstructionController")
	local original = rawget(_G, "BMOriginal_LCC_ValidateMark")
	if cls and type(original) == "function" then
		cls.ValidateMark = original
	end
	rawset(_G, "BMOriginal_LCC_ValidateMark", nil)
end

MapBounds.InstallLCCValidateMarkPermissive = InstallLCCValidateMarkPermissive
MapBounds.UninstallLCCValidateMarkPermissive = UninstallLCCValidateMarkPermissive

-- ---------------------------------------------------------------------------
-- Pre-generation buildable-grid extent optimizer (expanded maps only)
-- ---------------------------------------------------------------------------
local function GetUnbuildableZ()
	local fn = rawget(_G, "buildUnbuildableZ")
	if type(fn) == "function" then
		local ok, value = pcall(fn)
		if ok and type(value) == "number" then
			return value
		end
	end
	local const_value = rawget(_G, "UnbuildableZ")
	return type(const_value) == "number" and const_value or 65535
end

-- MapVar constructs BuildableGrid before random generation. The terrain allocation is
-- already 8192 tiles at that point, but only the native 6144-tile source will be generated;
-- computing buildability for the provisional destination is unnecessary work.
-- Give that provisional loading-only object a full-sized all-unbuildable z-grid in one cheap
-- allocation. RandomMapGenerator's ResolveBuildable pass replaces it from generated terrain,
-- and the post-stretch pass replaces it again at the final full extent. No print function is
-- intercepted or filtered, and the placeholder cannot authorize construction prematurely.
local BUILDABLE_GRID_BUILD_PATCH_VERSION = 3
local function InitialBuildableDeferralInfo(map, self)
	local cfg = SuperBigMap.Config or {}
	if cfg.OPTIMIZE_STRETCH_DEFERRED_REBUILDS ~= true or not map or self.z_grid then
		return nil
	end
	local mapdata = map.mapdata
	-- This optimization is valid only for the new expanded surface map whose native
	-- generator is guaranteed to run ResolveBuildable next. Never infer eligibility from
	-- persistent mapdata size markers: save loads and underground maps must fail open to
	-- the native Build path.
	if type(mapdata) ~= "table" or mapdata.Environment ~= "Surface"
		or map.SuperBigMapExpansionPending ~= true then
		return nil
	end
	local desired_w = map.SuperBigMapDesiredWidthTiles
		or mapdata.Width
	local desired_h = map.SuperBigMapDesiredHeightTiles
		or mapdata.Height
	local generator_w = map.SuperBigMapGeneratorWidthTiles
		or mapdata.SuperBigMapOriginalWidthTiles
	local generator_h = map.SuperBigMapGeneratorHeightTiles
		or mapdata.SuperBigMapOriginalHeightTiles
	if type(desired_w) ~= "number" or desired_w <= 0
		or type(desired_h) ~= "number" or desired_h <= 0
		or type(generator_w) ~= "number" or generator_w <= 0 or generator_w >= desired_w
		or type(generator_h) ~= "number" or generator_h <= 0 or generator_h >= desired_h then
		return nil
	end
	return generator_w, generator_h, desired_w, desired_h
end

local function InstallBuildableGridPreGenerationOptimizer()
	local class_table_fn = Engine.ClassTable
	if type(class_table_fn) ~= "function" then
		return
	end
	local cls = class_table_fn("BuildableGrid")
	if not cls or type(cls.Build) ~= "function" then
		return
	end
	local State = SuperBigMap.State or {}
	local current = cls.Build
	local legacy_original = rawget(_G, "BMOriginal_BuildableGrid_Build")
	if State.buildable_grid_build_wrapper == nil
		and type(legacy_original) == "function" and current ~= legacy_original
		and IsLegacyMapBoundsFunction(current) then
		current = legacy_original
	end
	if current == State.buildable_grid_build_wrapper
		and State.buildable_grid_build_version == BUILDABLE_GRID_BUILD_PATCH_VERSION
		and State.buildable_grid_build_token == MODULE_TOKEN then
		return true
	end
	if current == State.buildable_grid_build_wrapper
		and type(State.original_buildable_grid_build) == "function" then
		current = State.original_buildable_grid_build
	end
	local original = current
	rawset(_G, "BMOriginal_BuildableGrid_Build", original)
	local wrapper
	wrapper = function(self, map, width, height, map_data, ...)
		local gen_w = InitialBuildableDeferralInfo(map, self)
		local new_grid = Global("NewGrid")
		if gen_w and type(new_grid) == "function"
			and type(width) == "number" and width > 0 and type(height) == "number" and height > 0 then
			local ok_grid, placeholder = pcall(new_grid, width, height, 16, GetUnbuildableZ())
			if not ok_grid or not placeholder then
				return original(self, map, width, height, map_data, ...)
			end
			self.z_grid = placeholder
			map.SuperBigMapProvisionalBuildableDeferred = true
			return
		end
		local results = Pack(original(self, map, width, height, map_data, ...))
		-- Reaching this point proves the native Build returned successfully and replaced
		-- the provisional grid. If it raises, this marker deliberately remains set.
		if map and map.SuperBigMapProvisionalBuildableDeferred == true then
			map.SuperBigMapProvisionalBuildableDeferred = nil
		end
		return Unpack(results, 1, results.n)
	end
	cls.Build = wrapper
	State.original_buildable_grid_build = original
	State.buildable_grid_build_wrapper = wrapper
	State.buildable_grid_build_version = BUILDABLE_GRID_BUILD_PATCH_VERSION
	State.buildable_grid_build_token = MODULE_TOKEN
	return true
end

local function UninstallBuildableGridPreGenerationOptimizer()
	local class_table_fn = Engine.ClassTable
	if type(class_table_fn) ~= "function" then return end
	local cls = class_table_fn("BuildableGrid")
	local State = SuperBigMap.State or {}
	if cls and cls.Build == State.buildable_grid_build_wrapper
		and type(State.original_buildable_grid_build) == "function" then
		cls.Build = State.original_buildable_grid_build
	end
	State.original_buildable_grid_build = nil
	State.buildable_grid_build_wrapper = nil
	State.buildable_grid_build_version = nil
	State.buildable_grid_build_token = nil
	rawset(_G, "BMOriginal_BuildableGrid_Build", nil)
end

MapBounds.InstallBuildableGridPreGenerationOptimizer = InstallBuildableGridPreGenerationOptimizer
MapBounds.UninstallBuildableGridPreGenerationOptimizer = UninstallBuildableGridPreGenerationOptimizer

-- Narrow reload-safe installer used after an expanded session is committed. It touches only
-- map-gated engine hooks; no current-map grids, pass borders, or permissive policies.
function MapBounds.ReinstallGlobalHooks()
	local cfg = SuperBigMap.Config or {}
	if cfg.ENABLE_MOD == false then return false end
	InstallBuildableGridPreGenerationOptimizer()
	return true
end

-- Bounds are applied per-map by SuperBigMap.Lifecycle.Apply. The only permissive
-- override retained here lets landscaping operate across the expanded terrain.
function MapBounds.ApplyModBehavior()
	local cfg = SuperBigMap.Config or {}
	MapBounds.ReinstallGlobalHooks()
	-- LANDSCAPING permissive (terraform across the expanded terrain): ON by default. Separate
	-- from buildability -- vanilla lets you landscape unbuildable ground to make it buildable,
	-- so the landscape tool must keep working across the full destination. Disable via
	-- Config.ALLOW_LANDSCAPING_ON_EXPANDED = false.
	if cfg.ALLOW_LANDSCAPING_ON_EXPANDED ~= false then
		InstallLCCValidateMarkPermissive()
	end
end

-- Restore order is the exact reverse of install. PassBorder is also put back
-- here so the engine's strict bounds resume when the mod is off.
function MapBounds.RestoreVanillaBehavior()
	UninstallBuildableGridPreGenerationOptimizer()
	UninstallLCCValidateMarkPermissive()

	local map = Global("CurrentMap")
	if not IsLiveMap(map) then
		map = Global("MainMap")
	end
	if not IsLiveMap(map) then
		return
	end

	local mapdata = map.mapdata
	if not mapdata then
		return
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
		mapdata.SuperBigMapOriginalPassBorder = nil
		mapdata.SuperBigMapOriginalPassBorderCaptured = nil
		mapdata.SuperBigMapOriginalPassBorderWasNil = nil
		mapdata.SuperBigMapOriginalPassBorderTiles = nil
		mapdata.SuperBigMapOriginalPassBorderTilesWasNil = nil
	elseif mapdata.SuperBigMapOriginalPassBorder ~= nil then
		mapdata.PassBorder = mapdata.SuperBigMapOriginalPassBorder
		mapdata.SuperBigMapOriginalPassBorder = nil
	end
end

SuperBigMap.MapBounds = MapBounds

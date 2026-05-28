-- Bigger Maps -- playable-map bounds.
--
-- Expands the loaded map's playable construction boundary to the full terrain:
-- clears the vanilla PassBorder / height ranges (saving the originals for restore),
-- resets the play and constructable areas, rebuilds passability/buildable grids,
-- and re-fits the sector grid boxes. All of this is gated on Config.FULL_MAP_PLAYABLE.
-- The per-map work is driven by BiggerMaps.Lifecycle.Apply; RestoreVanillaBehavior
-- puts the saved vanilla bounds back.

local BiggerMaps = rawget(_G, "BiggerMaps")
if type(BiggerMaps) ~= "table" then
	BiggerMaps = {}
	rawset(_G, "BiggerMaps", BiggerMaps)
end

local Engine = BiggerMaps.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local FullHeightMin = Engine.FullHeightMin
local FullHeightMax = Engine.FullHeightMax

-- Map liveness / terrain size are intentionally NOT in bm_engine (their resolution
-- order is context-specific); each consumer keeps its own copy.
local function IsLiveMap(map)
	if not map or type(map) ~= "table" then
		return false
	end

	if type(map.IsValid) == "function" and not SafeCall(map.IsValid, map) then
		return false
	end

	if not map.mapdata then
		return false
	end

	return true
end

local function TerrainSize(map)
	if not IsLiveMap(map) then
		return 0, 0
	end

	if type(map.Width) == "number" and type(map.Height) == "number" and map.Width > 0 and map.Height > 0 then
		return map.Width, map.Height
	end

	local terrain_api = Global("terrain")

	if terrain_api and type(terrain_api.GetMapSize) == "function" then
		local width, height = SafeCall(terrain_api.GetMapSize, map)
		if width and height then
			return width, height
		end
	end

	if map and type(map.GetMapSize) == "function" then
		local width, height = SafeCall(map.GetMapSize, map)
		if width and height then
			return width, height
		end
	end

	return map and map.Width or 0, map and map.Height or 0
end

local function FullMapPlayableEnabled()
	local cfg = BiggerMaps.Config
	return (cfg and cfg.FULL_MAP_PLAYABLE) == true
end

local function ResetMapDataBounds(map, mapdata)
	if not FullMapPlayableEnabled() then
		return
	end

	mapdata = mapdata or map and map.mapdata
	if not mapdata then
		return
	end

	if mapdata.BiggerMapsOriginalPassBorder == nil then
		mapdata.BiggerMapsOriginalPassBorder = mapdata.PassBorder
	end
	if mapdata.BiggerMapsOriginalPlayableHeightRange == nil then
		mapdata.BiggerMapsOriginalPlayableHeightRange = mapdata.playable_height_range
	end
	if mapdata.BiggerMapsOriginalVisibleHeightRange == nil then
		mapdata.BiggerMapsOriginalVisibleHeightRange = mapdata.visible_height_range
	end

	-- The sector grid decides the border: 0 for grids anchored at the map corner,
	-- or the vanilla grid offset for "expanded_with_vanilla_grid" (so the engine's
	-- selection overlay, anchored at PassBorder, stays aligned with the sectors).
	local grid = BiggerMaps.SectorGrid
	local resolve_border = grid and grid.ResolveMapBorder
	local new_border = (type(resolve_border) == "function" and SafeCall(resolve_border, map)) or 0
	if type(new_border) ~= "number" or new_border < 0 then
		new_border = 0
	end
	mapdata.PassBorder = new_border
	local width = TerrainSize(map)
	if new_border > 0 and width and width > 0 and type(mapdata.Width) == "number" and mapdata.Width > 0 then
		mapdata.PassBorderTiles = math.floor(new_border * mapdata.Width / width + 0.5)
	else
		mapdata.PassBorderTiles = 0
	end
	local DebugLog = BiggerMaps.DebugLog
	if DebugLog then
		DebugLog.Info("MapBounds", "ResetMapDataBounds set PassBorder", { PassBorder = new_border, mapdata_width = mapdata.Width })
	end
	mapdata.playable_height_range = false
	mapdata.visible_height_range = false

	if map then
		map.playable_height_range = false
	end
end

local function ResetMapAreas(map)
	if not FullMapPlayableEnabled() or not map then
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

local function RebuildMapBounds(map)
	local terrain_api = Global("terrain")

	if terrain_api and type(terrain_api.SetPassableHeight) == "function" then
		SafeCall(terrain_api.SetPassableHeight, map, FullHeightMin(), FullHeightMax())
	end

	if terrain_api and type(terrain_api.RebuildPassability) == "function" then
		SafeCall(terrain_api.RebuildPassability, map)
	end

	local rebuild_buildable = Global("RebuildBuildableGrid")
	if type(rebuild_buildable) == "function" and map and map.buildable then
		SafeCall(rebuild_buildable, map)
	end
end

local function RefreshSectors(map)
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

-- Bounds are applied per-map by BiggerMaps.Lifecycle.Apply (driven by the map OnMsg
-- flow); there is no global install step at enable time.
function MapBounds.ApplyModBehavior()
end

-- Put the saved vanilla bounds back on the current map's mapdata.
function MapBounds.RestoreVanillaBehavior()
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

	if mapdata.BiggerMapsOriginalPassBorder ~= nil then
		mapdata.PassBorder = mapdata.BiggerMapsOriginalPassBorder
		mapdata.BiggerMapsOriginalPassBorder = nil
	end
	if mapdata.BiggerMapsOriginalPlayableHeightRange ~= nil then
		mapdata.playable_height_range = mapdata.BiggerMapsOriginalPlayableHeightRange
		mapdata.BiggerMapsOriginalPlayableHeightRange = nil
	end
	if mapdata.BiggerMapsOriginalVisibleHeightRange ~= nil then
		mapdata.visible_height_range = mapdata.BiggerMapsOriginalVisibleHeightRange
		mapdata.BiggerMapsOriginalVisibleHeightRange = nil
	end
end

BiggerMaps.MapBounds = MapBounds

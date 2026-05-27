local MOD_PREFIX = "[Bigger Maps] "
local SECTOR_PATCH_VERSION = 21

local function Global(name)
	return rawget(_G, name)
end

local function ClassTable(name)
	local global_class = Global(name)
	if type(global_class) == "table" then
		return global_class
	end

	local classes = Global("g_Classes")
	local class_table = type(classes) == "table" and classes[name]
	return type(class_table) == "table" and class_table or false
end

local function Config()
	local config = Global("BiggerMapsConfig")
	return type(config) == "table" and config or {}
end

local function ConfigBool(name, default)
	local value = Config()[name]
	if type(value) == "boolean" then
		return value
	end
	return default
end

local function ConfigNumber(name, default, min_value)
	local value = Config()[name]
	if type(value) == "number" and (min_value == nil or value >= min_value) then
		return value
	end
	return default
end

local function DiagnosticLogsEnabled()
	return ConfigBool("EnableDiagnosticLogs", ConfigBool("DebugPrint", true))
end

local function DebugPrint(message)
	if DiagnosticLogsEnabled() then
		print(MOD_PREFIX .. tostring(message))
	end
end

local function SafeCall(fn, ...)
	if type(fn) ~= "function" then
		return nil
	end

	local ok, result, result2 = pcall(fn, ...)
	if ok then
		return result, result2
	end

	return nil
end

local function ClampNumber(value, min_value, max_value)
	local clamp = Global("Clamp")
	if type(clamp) == "function" then
		return clamp(value, min_value, max_value)
	end
	return math.max(min_value, math.min(max_value, value))
end

local function Round(value)
	return math.floor(value + 0.5)
end

local function TerrainSize(map)
	if not map then
		return 0, 0
	end

	if type(map.Width) == "number" and type(map.Height) == "number" and map.Width > 0 and map.Height > 0 then
		return map.Width, map.Height
	end

	if type(map.GetMapSize) == "function" then
		local width, height = SafeCall(map.GetMapSize, map)
		if width and height then
			return width, height
		end
	end

	return 0, 0
end

local function MapData(map)
	return map and map.mapdata or map
end

local function MapTileWorldSize(map)
	local width = TerrainSize(map)
	local mapdata = MapData(map)
	if width and width > 0 and mapdata and type(mapdata.Width) == "number" and mapdata.Width > 0 then
		return width / mapdata.Width
	end

	local const = Global("const")
	if type(const) == "table" and type(const.HeightTileSize) == "number" and const.HeightTileSize > 0 then
		return const.HeightTileSize
	end

	return 100
end

local function OriginalWidthTiles(map)
	local mapdata = MapData(map)
	if ConfigBool("VanillaSectorUseSourceQuadrant", true) then
		local source = map and map.BiggerMapsSourceWidthTiles
		if type(source) == "number" and source > 0 then
			return source
		end

		source = mapdata and mapdata.BiggerMapsQuadrantSourceWidthTiles
		if type(source) == "number" and source > 0 then
			return source
		end

		source = map and map.BiggerMapsGeneratorWidthTiles
		if type(source) == "number" and source > 0 then
			return source
		end
	end

	local value = map and map.BiggerMapsOriginalWidthTiles
	if type(value) == "number" and value > 0 then
		return value
	end

	value = mapdata and mapdata.BiggerMapsOriginalWidthTiles
	if type(value) == "number" and value > 0 then
		return value
	end

	return ConfigNumber("VanillaSectorBaseMapTiles", 4096, 1)
end

-- The TRUE vanilla sector footprint, in world units. It must never change with
-- map expansion: every sector always stays the size of a vanilla sector.
-- Verified against a full-resolution vanilla sector dump
-- (terrains/sector_15.lua: a 410 x 410 grid at step 100 ~= 40960 world units),
-- which equals source map tiles / vanilla sector count (4096 * 100 / 10 = 40960).
-- No border term: vanilla sectors span essentially the whole source map.
local function SectorTargetSize(map)
	local base_tiles = OriginalWidthTiles(map)
	local base_count = math.floor(ConfigNumber("VanillaSectorBaseCount", 10, 1))
	local target = base_tiles * MapTileWorldSize(map) / base_count
	return math.max(1, Round(target))
end

local function HasExpandedSectorSource(map)
	local mapdata = MapData(map)
	return map and map.BiggerMapsSourceWidthTiles
		or map and map.BiggerMapsGeneratorWidthTiles
		or map and map.BiggerMapsDesiredWidthTiles
		or mapdata and mapdata.BiggerMapsQuadrantSourceWidthTiles
end

local function CustomSectorStatus(map)
	if not ConfigBool("EnableVanillaSizedSectors", true) or not map then
		return false, not map and "no map" or "disabled"
	end

	local mapdata = MapData(map)
	if ConfigBool("VanillaSectorSurfaceOnly", true) and mapdata and mapdata.Environment ~= "Surface" then
		return false, "not surface"
	end

	if ConfigBool("VanillaSectorExpandedOnly", true) and not HasExpandedSectorSource(map) then
		return false, "not expanded/no source"
	end

	return true, "ok"
end

local function UseCustomSectorsForMap(map)
	return CustomSectorStatus(map)
end

local function SectorCountBounds()
	local min_count = math.floor(ConfigNumber("VanillaSectorMinCount", 10, 1))
	local max_count = math.floor(ConfigNumber("VanillaSectorMaxCount", 26, min_count))
	return min_count, max_count
end

-- The grid offset (world units) for the current map: the vanilla-grid alignment
-- offset for "expanded_with_vanilla_grid", else 0. Computed deterministically here
-- (NOT read from mapdata.PassBorder, which the engine and other code reset at
-- various times) so the BUILT grid and the cursor->sector lookup always use the
-- exact same value. If they ever disagree, the hover highlight drifts off the
-- sectors (e.g. sectors built at offset 20480 but the cursor mapped from 0).
local function GridBorder(map)
	if not UseCustomSectorsForMap(map) then
		return 0
	end
	if not ConfigBool("VanillaSectorAlignToVanillaGrid", false) then
		return 0
	end
	local target = SectorTargetSize(map)
	if target <= 0 then
		return 0
	end
	local mapdata = MapData(map)
	local anchor = Config()["VanillaSectorGridAnchor"]
	if type(anchor) ~= "number" then
		anchor = mapdata and mapdata.BiggerMapsOriginalPassBorder
	end
	if type(anchor) ~= "number" then
		return 0
	end
	return anchor % target
end

-- Resolves the full sector grid for a map. Sectors are always vanilla-sized
-- (SectorTargetSize), laid out uniformly from GridBorder(map). For
-- "expanded_with_vanilla_grid" that offset puts the grid on the vanilla lines and,
-- because the same offset feeds both the build and the cursor lookup, the hover
-- highlight tracks it. VanillaSectorForcedCount, if set, overrides the count.
local function ResolveSectorLayout(map)
	local width, height = TerrainSize(map)
	local mapdata = MapData(map)
	local border = GridBorder(map)
	local target = SectorTargetSize(map)
	local usable_width = math.max(1, width - 2 * border)
	local usable_height = math.max(1, height - 2 * border)
	local uniform = ConfigBool("VanillaSectorUniformGrid", true)
	local min_count, max_count = SectorCountBounds()

	local forced = Config()["VanillaSectorForcedCount"]
	forced = (type(forced) == "number" and forced > 0) and ClampNumber(math.floor(forced), min_count, max_count) or nil

	local count_x = forced
	local count_y = forced
	if not count_x then
		count_x = ClampNumber(uniform and Round(usable_width / target) or math.ceil(usable_width / target), min_count, max_count)
		count_y = ClampNumber(uniform and Round(usable_height / target) or math.ceil(usable_height / target), min_count, max_count)
	end

	return {
		border = border,
		count_x = count_x,
		count_y = count_y,
		count = math.max(count_x, count_y),
		target = target,
		step_x = uniform and usable_width / count_x or target,
		step_y = uniform and usable_height / count_y or target,
		uniform = uniform,
		usable_width = usable_width,
		usable_height = usable_height,
		width = width,
		height = height,
	}
end

-- Single source of truth for const.SectorCount: it equals the built grid's count
-- (ResolveSectorLayout) so the two can never disagree. False for maps that keep
-- vanilla sectors or when the terrain size is not available yet.
local function ResolveSectorCount(map)
	if not UseCustomSectorsForMap(map) then
		return false
	end

	local width, height = TerrainSize(map)
	if not width or width <= 0 or not height or height <= 0 then
		return false
	end

	return ResolveSectorLayout(map).count
end

-- The map border (world units) ResetMapDataBounds (BiggerMaps.lua) imposes so the
-- engine's PassBorder-based selection overlay matches the sectors. Same value the
-- grid is built from (GridBorder), so they can never disagree.
function BiggerMaps_ResolveMapBorder(map)
	return GridBorder(map)
end

local function DesiredWidthTiles(map)
	local mapdata = MapData(map)
	local value = map and map.BiggerMapsDesiredWidthTiles
	if type(value) == "number" and value > 0 then
		return value
	end

	value = mapdata and mapdata.Width
	if type(value) == "number" and value > 0 then
		return value
	end

	return false
end

local function SourceWidthTiles(map)
	local mapdata = MapData(map)
	local value = map and (map.BiggerMapsSourceWidthTiles or map.BiggerMapsGeneratorWidthTiles)
	if type(value) == "number" and value > 0 then
		return value
	end

	value = mapdata and mapdata.BiggerMapsQuadrantSourceWidthTiles
	if type(value) == "number" and value > 0 then
		return value
	end

	return OriginalWidthTiles(map)
end

local function BoolText(value)
	return value and "true" or "false"
end

local function MapName(map)
	local mapdata = MapData(map)
	return tostring(map and map.name or mapdata and (mapdata.id or mapdata.name) or "map")
end

local function DescribeMap(map)
	local mapdata = MapData(map)
	local width, height = TerrainSize(map)
	local custom, reason = CustomSectorStatus(map)
	local desired = DesiredWidthTiles(map)
	local source = SourceWidthTiles(map)
	local count = ResolveSectorCount(map) or false

	return string.format(
		"map=%s env=%s terrain=%s x %s mapdata=%s x %s sourceTiles=%s desiredTiles=%s custom=%s reason=%s count=%s const=%s",
		MapName(map),
		tostring(mapdata and mapdata.Environment),
		tostring(width),
		tostring(height),
		tostring(mapdata and mapdata.Width),
		tostring(mapdata and mapdata.Height),
		tostring(source),
		tostring(desired),
		BoolText(custom),
		tostring(reason),
		tostring(count),
		tostring(Global("const") and const.SectorCount)
	)
end

local function ConfigureGlobalSectorCount(map, reason)
	local const = Global("const")
	if type(const) ~= "table" then
		DebugPrint("sector count not configured via " .. tostring(reason) .. ": const missing")
		return false
	end

	local count = ResolveSectorCount(map)
	if not count then
		DebugPrint("sector count not configured via " .. tostring(reason) .. ": " .. DescribeMap(map))
		return false
	end

	if const.BiggerMapsOriginalSectorCount == nil then
		const.BiggerMapsOriginalSectorCount = const.SectorCount
	end

	if const.SectorCount ~= count then
		const.SectorCount = count
		DebugPrint(string.format(
			"sector count set to %s via %s",
			tostring(count),
			tostring(reason or "map")
		))
	else
		DebugPrint(string.format(
			"sector count already %s via %s",
			tostring(count),
			tostring(reason or "map")
		))
	end

	return count
end

local function ForEachSector(city, callback)
	local sectors = city and city.MapSectors
	if type(sectors) ~= "table" then
		return
	end

	for col = 1, #sectors do
		local row = sectors[col]
		if type(row) == "table" then
			for sector_row = 1, #row do
				local sector = row[sector_row]
				if sector then
					callback(sector, col, sector_row)
				end
			end
		end
	end
end

local function PickFromList(list, trand, weight_func)
	if #list <= 0 then
		return false
	end

	if type(trand) == "function" then
		return trand(list, weight_func)
	end

	return list[1]
end

local function MarkerAmount(marker)
	if not marker then
		return 0
	end

	if type(Global("IsKindOf")) == "function" and IsKindOf(marker, "SurfaceDepositMarker") and type(marker.GetEstimatedAmount) == "function" then
		return marker:GetEstimatedAmount() or 0
	end

	return marker.max_amount or 0
end

local function AddSurfaceSpawnPositions(sector, spawn_positions)
	local markers = sector and sector.markers and sector.markers.surface
	if type(markers) ~= "table" then
		return
	end

	for i = 1, #markers do
		local marker = markers[i]
		if marker and not marker.is_placed and type(marker.GetPos) == "function" then
			spawn_positions[marker] = marker:GetPos()
		end
	end
end

local function BuildFastInitialReveal(original_initial_reveal)
	return function(eligible, trand)
		if not ConfigBool("VanillaSectorFastInitialReveal", true) then
			return original_initial_reveal(eligible, trand)
		end

		if type(eligible) ~= "table" or #eligible <= 0 then
			return original_initial_reveal(eligible, trand)
		end

		local filtered, best = {}, {}
		local has_metals, has_concrete = {}, {}
		local qty_per_sector = {}
		local deposit_resources = Global("GroupResourceIds") and GroupResourceIds.DepositResources or {}
		local progress_interval = math.floor(ConfigNumber("VanillaSectorInitialRevealProgressInterval", 50, 1))

		DebugPrint("fast initial reveal evaluating " .. tostring(#eligible) .. " candidate sectors")

		for i = 1, #eligible do
			local sector = eligible[i]
			local qtys = {}
			local markers = sector and sector.markers and sector.markers.surface or {}

			for j = 1, #markers do
				local marker = markers[j]
				local resource = marker and marker.resource
				if resource and deposit_resources[resource] then
					qtys[resource] = (qtys[resource] or 0) + MarkerAmount(marker)
				end
			end

			if (qtys.Metals or 0) >= 50 then
				if qtys.Concrete then
					best[#best + 1] = sector
				else
					filtered[#filtered + 1] = sector
				end
			end
			if qtys.Metals then
				has_metals[#has_metals + 1] = sector
			end
			if qtys.Concrete then
				has_concrete[#has_concrete + 1] = sector
			end
			qty_per_sector[sector.id] = qtys
			if progress_interval > 0 and i % progress_interval == 0 then
				DebugPrint("fast initial reveal progress " .. tostring(i) .. "/" .. tostring(#eligible))
			end
		end

		local function weight_func(sector)
			if type(Global("MulDivRound")) == "function" and type(Global("const")) == "table" then
				return MulDivRound(sector.play_ratio or 0, sector.avg_heat or const.MaxHeat, const.MaxHeat)
			end
			return sector.play_ratio or 0
		end

		local revealed = {}
		local sector = PickFromList(best, trand, weight_func)
		if sector then
			revealed[1] = sector
		else
			sector = PickFromList(filtered, trand, weight_func)
			if not sector and #has_metals > 0 then
				table.sort(has_metals, function(a, b)
					return (qty_per_sector[a.id].Metals or 0) > (qty_per_sector[b.id].Metals or 0)
				end)
				sector = has_metals[1]
			end
			if not sector then
				sector = PickFromList(has_concrete, trand, weight_func) or PickFromList(eligible, trand, weight_func)
			end
			if sector then
				revealed[1] = sector
			end
			if sector and #has_concrete > 0 and not qty_per_sector[sector.id].Concrete then
				local pt = sector.area:Center()
				table.sort(has_concrete, function(a, b)
					return a.area:Dist2D(pt) < b.area:Dist2D(pt)
				end)
				revealed[2] = has_concrete[1]
			end
		end

		local spawn_positions = {}
		for i = 1, #revealed do
			AddSurfaceSpawnPositions(revealed[i], spawn_positions)
		end

		DebugPrint(string.format(
			"fast initial reveal selected %s sector(s) from %s candidates",
			tostring(#revealed),
			tostring(#eligible)
		))

		return revealed, spawn_positions
	end
end

local function IndexToLetters(index)
	local letters = ""
	while index > 0 do
		local mod = (index - 1) % 26
		letters = string.char(string.byte("A") + mod) .. letters
		index = math.floor((index - 1) / 26)
	end
	return letters
end

local function SectorName(row, col, count, orient)
	if orient == 0 then
		return IndexToLetters(count - col + 1) .. tostring(row - 1)
	elseif orient == 90 then
		return IndexToLetters(count - row + 1) .. tostring(count - col)
	elseif orient == 180 then
		return IndexToLetters(col) .. tostring(count - row)
	elseif orient == 270 then
		return IndexToLetters(row) .. tostring(col - 1)
	end

	return IndexToLetters(col) .. tostring(row - 1)
end

-- Finds the 1-based column index for world coordinate v in a boundary list.
local function ColFromBounds(bounds, v)
	for i = 1, #bounds - 1 do
		if v < bounds[i + 1] then
			return i
		end
	end
	return math.max(1, #bounds - 1)
end

local function SectorBounds(layout, col, row)
	if layout.bounds_x and layout.bounds_y then
		local x1 = layout.bounds_x[col]
		local y1 = layout.bounds_y[row]
		local x2 = layout.bounds_x[col + 1]
		local y2 = layout.bounds_y[row + 1]
		return x1, y1, math.max(x1 + 1, x2), math.max(y1 + 1, y2)
	end

	local x1 = layout.border + Round((col - 1) * layout.step_x)
	local y1 = layout.border + Round((row - 1) * layout.step_y)
	local x2 = col < layout.count_x and layout.border + Round(col * layout.step_x) or layout.border + layout.usable_width
	local y2 = row < layout.count_y and layout.border + Round(row * layout.step_y) or layout.border + layout.usable_height

	return x1, y1, math.max(x1 + 1, x2), math.max(y1 + 1, y2)
end

local function BuildSector(map, city, row, col, layout, orient, unbuildable_z, eligible_sectors)
	local x1, y1, x2, y2 = SectorBounds(layout, col, row)
	local bbox = box(x1, y1, x2, y2)
	local buildable_grid = map.buildable
	local heat_grid = map.heat_grid
	local name = SectorName(row, col, layout.count, orient)
	local sector_data = {
		id = name,
		display_name = name,
		area = bbox,
		play_ratio = BuildableGridRatio(buildable_grid.z_grid, unbuildable_z, 100, bbox),
		avg_heat = heat_grid and heat_grid:GetAverageHeatIn(bbox) or const.MaxHeat,
		row = row,
		col = col,
		city = city,
	}
	local map_sector_class = ClassTable("MapSector")
	local sector = map_sector_class:new(sector_data, map.slot)
	InitSector(map, sector, eligible_sectors)
	return sector
end

local function SetSectorCountForInit(count, fn)
	local const = Global("const")
	local previous = const and const.SectorCount
	if const then
		const.SectorCount = count
	end

	local ok, result = pcall(fn)

	if const then
		const.SectorCount = previous or count
	end

	if not ok then
		error(result)
	end
	return result
end

local function InstallBasicSectorPatch()
	DebugPrint(string.format(
		"sector basic patch attempt v%s: GetMapSectorTileSize=%s GetMapSectorXY=%s InitialReveal=%s",
		tostring(SECTOR_PATCH_VERSION),
		type(Global("GetMapSectorTileSize")),
		type(Global("GetMapSectorXY")),
		type(Global("InitialReveal"))
	))

	if Global("BiggerMapsSectorBasicPatchVersion") == SECTOR_PATCH_VERSION then
		DebugPrint("sector basic functions already patched")
		return true
	end

	if type(Global("GetMapSectorTileSize")) ~= "function" then
		DebugPrint("sector patch waiting for GetMapSectorTileSize")
		return false
	end

	if type(Global("GetMapSectorXY")) ~= "function" then
		DebugPrint("sector patch waiting for GetMapSectorXY")
		return false
	end

	rawset(_G, "BiggerMapsOriginalGetMapSectorTileSize", Global("BiggerMapsOriginalGetMapSectorTileSize") or GetMapSectorTileSize)
	rawset(_G, "BiggerMapsOriginalGetMapSectorXY", Global("BiggerMapsOriginalGetMapSectorXY") or GetMapSectorXY)
	rawset(_G, "BiggerMapsOriginalInitialReveal", Global("BiggerMapsOriginalInitialReveal") or InitialReveal)

	function GetMapSectorTileSize(map)
		if UseCustomSectorsForMap(map) then
			return ResolveSectorLayout(map).step_x
		end
		return BiggerMapsOriginalGetMapSectorTileSize(map)
	end

	function GetMapSectorXY(city, mx, my)
		local map = city and city.GetMap and city:GetMap()
		if not UseCustomSectorsForMap(map) then
			return BiggerMapsOriginalGetMapSectorXY(city, mx, my)
		end

		local layout = ResolveSectorLayout(map)
		local x = mx - layout.border
		local y = my - layout.border
		local col, row
		if layout.bounds_x and layout.bounds_y then
			col = ColFromBounds(layout.bounds_x, x)
			row = ColFromBounds(layout.bounds_y, y)
		else
			col = ClampNumber(1 + math.floor(x / layout.step_x), 1, layout.count_x)
			row = ClampNumber(1 + math.floor(y / layout.step_y), 1, layout.count_y)
		end
		local sector_col = city.MapSectors and city.MapSectors[col]
		return sector_col and sector_col[row]
	end

	if type(Global("BiggerMapsOriginalInitialReveal")) == "function" then
		InitialReveal = BuildFastInitialReveal(BiggerMapsOriginalInitialReveal)
	end

	rawset(_G, "BiggerMapsSectorBasicPatchVersion", SECTOR_PATCH_VERSION)
	DebugPrint("sector basic functions patched")
	return true
end

-- The scan-mode hover highlight ("SectorTarget", a SectorDecal = {Decal, Object})
-- is placed by SelectSector at sector.area:Center(), but unlike the plain-Decal
-- grid cells it anchors at its corner, so on our grids it renders half a sector
-- off (its top-left at the sector center) even though scans pick the right sector.
-- Re-place it at the sector's min corner on custom maps so it lines up.
local function InstallOverviewHighlightPatch()
	if Global("BiggerMapsOverviewPatchVersion") == SECTOR_PATCH_VERSION then
		return true
	end

	local overview_class = ClassTable("OverviewModeDialog")
	if not overview_class or type(overview_class.SelectSector) ~= "function" then
		return false
	end

	rawset(_G, "BiggerMapsOriginalOverviewSelectSector", Global("BiggerMapsOriginalOverviewSelectSector") or overview_class.SelectSector)

	overview_class.SelectSector = function(self, sector, ...)
		local result = BiggerMapsOriginalOverviewSelectSector(self, sector, ...)
		local point_fn = Global("point")
		if sector and sector.area and self.sector_obj and type(point_fn) == "function"
				and UseCustomSectorsForMap(Global("CurrentMap")) then
			-- The highlight decal anchors at a corner, so it lands half a sector off
			-- the cell. Nudge it back by half a sector on each axis -- a fixed
			-- per-sector compensation, independent of grid origin, count or size.
			local half = Round(sector.area:sizex() / 2)
			SafeCall(self.sector_obj.SetPos, self.sector_obj, sector.area:Center() + point_fn(half, half, 0))
		end
		return result
	end

	rawset(_G, "BiggerMapsOverviewPatchVersion", SECTOR_PATCH_VERSION)
	DebugPrint("overview highlight patch installed")
	return true
end

local function InstallSectorPatch()
	DebugPrint(string.format(
		"sector full patch attempt v%s: Exploration=%s g_Exploration=%s MapSector=%s InitSector=%s",
		tostring(SECTOR_PATCH_VERSION),
		type(Global("Exploration")),
		type(ClassTable("Exploration")),
		type(ClassTable("MapSector")),
		type(Global("InitSector"))
	))

	InstallOverviewHighlightPatch()

	if not ConfigBool("EnableVanillaSizedSectors", true) then
		DebugPrint("sector full patch disabled")
		return false
	end

	if Global("BiggerMapsSectorPatchVersion") == SECTOR_PATCH_VERSION then
		DebugPrint("sector full patch already installed")
		return true
	end

	if not InstallBasicSectorPatch() then
		return false
	end

	local exploration_class = ClassTable("Exploration")
	local map_sector_class = ClassTable("MapSector")

	if type(Global("InitSector")) ~= "function" then
		DebugPrint("sector patch waiting for InitSector")
		return false
	end

	if not exploration_class then
		DebugPrint("sector patch waiting for Exploration class")
		return false
	end

	if not map_sector_class then
		DebugPrint("sector patch waiting for MapSector class")
		return false
	end

	rawset(_G, "BiggerMapsOriginalExplorationInitSectors", Global("BiggerMapsOriginalExplorationInitSectors") or exploration_class.InitSectors)
	rawset(_G, "BiggerMapsOriginalExplorationInitMapArea", Global("BiggerMapsOriginalExplorationInitMapArea") or exploration_class.InitMapArea)
	rawset(_G, "BiggerMapsOriginalExplorationUpdateBuildableRatio", Global("BiggerMapsOriginalExplorationUpdateBuildableRatio") or exploration_class.UpdateBuildableRatio)

	exploration_class.InitSectors = function(self, map, eligible_sectors_with_surface_deposits_out)
		if not UseCustomSectorsForMap(map) then
			DebugPrint("sector InitSectors using vanilla path: " .. DescribeMap(map))
			return BiggerMapsOriginalExplorationInitSectors(self, map, eligible_sectors_with_surface_deposits_out)
		end

		ConfigureGlobalSectorCount(map, "InitSectors")
		local layout = ResolveSectorLayout(map)
		local orient = map.mapdata.OverviewOrientation
		local unbuildable_z = buildUnbuildableZ()
		local progress_interval = math.floor(ConfigNumber("VanillaSectorProgressColumnInterval", 2, 1))

		DebugPrint(string.format(
			"sector InitSectors begin: %s layout=%s x %s target=%s actual=%s x %s",
			DescribeMap(map),
			tostring(layout.count_x),
			tostring(layout.count_y),
			tostring(layout.target),
			tostring(Round(layout.step_x)),
			tostring(Round(layout.step_y))
		))

		if layout.bounds_x then
			local b = layout.bounds_x
			DebugPrint(string.format(
				"sector aligned grid: anchor=%s first sector=[%s..%s] last sector=[%s..%s] columns=%s",
				tostring(layout.anchor),
				tostring(b[1]), tostring(b[2]),
				tostring(b[#b - 1]), tostring(b[#b]),
				tostring(layout.count_x)
			))
		end

		return SetSectorCountForInit(layout.count, function()
			self.ExplorationQueue = {}
			self.MapSectors = {}
			self.BiggerMapsSectorCount = layout.count
			self.BiggerMapsSectorTargetSize = layout.target

			for col = 1, layout.count_x do
				local sectors_col = {}
				self.MapSectors[col] = sectors_col
				for row = 1, layout.count_y do
					local sector = BuildSector(map, self, row, col, layout, orient, unbuildable_z, eligible_sectors_with_surface_deposits_out)
					sectors_col[row] = sector
					self.MapSectors[sector] = true
				end
				if progress_interval > 0 and (col % progress_interval == 0 or col == layout.count_x) then
					DebugPrint("sector InitSectors progress column " .. tostring(col) .. "/" .. tostring(layout.count_x))
				end
			end

			DebugPrint(string.format(
				"vanilla-sized sector grid for %s: %s x %s sectors, target %s world units, actual %s x %s, uniform=%s",
				tostring(map.name or map.mapdata and map.mapdata.id or "map"),
				tostring(layout.count_x),
				tostring(layout.count_y),
				tostring(layout.target),
				tostring(Round(layout.step_x)),
				tostring(Round(layout.step_y)),
				tostring(layout.uniform)
			))
		end)
	end

	exploration_class.InitMapArea = function(self)
		if not UseCustomSectorsForMap(self:GetMap()) then
			DebugPrint("sector InitMapArea using vanilla path: " .. DescribeMap(self:GetMap()))
			return BiggerMapsOriginalExplorationInitMapArea(self)
		end

		local last_col = #self.MapSectors
		local last_row = last_col > 0 and #self.MapSectors[last_col] or 0
		assert(last_col > 0 and last_row > 0)
		self.MapArea = box(
			self.MapSectors[1][1].area:min(),
			self.MapSectors[last_col][last_row].area:max())
		DebugPrint("sector InitMapArea complete: " .. tostring(last_col) .. " x " .. tostring(last_row))
	end

	exploration_class.UpdateBuildableRatio = function(self, bbox)
		if not UseCustomSectorsForMap(self:GetMap()) then
			return BiggerMapsOriginalExplorationUpdateBuildableRatio(self, bbox)
		end

		local unbuildable_z = buildUnbuildableZ()
		local buildable_grid = self:GetMap().buildable
		local processed = 0
		ForEachSector(self, function(sector)
			if not bbox or bbox:Intersect2D(sector.area) ~= const.irOutside then
				sector.play_ratio = BuildableGridRatio(buildable_grid.z_grid, unbuildable_z, 100, sector.area)
				processed = processed + 1
			end
		end)
		DebugPrint("sector UpdateBuildableRatio processed " .. tostring(processed) .. " sectors")
	end

	function UnexploredSectorsExist(city)
		local can_scan
		local fully_scanned = true
		local saw_sector = false

		ForEachSector(city, function(sector)
			saw_sector = true
			if sector:CanBeScanned() then
				can_scan = true
			end
			if sector.status ~= "deep scanned" then
				fully_scanned = false
			end
		end)

		if not saw_sector then
			return can_scan, false
		end
		return can_scan, fully_scanned
	end

	exploration_class.GatherDiscoveredDeposits = function(self)
		local deposits = InitDepositInfoTable()

		ForEachSector(self, function(sector)
			ProcessDepositMarkers(sector.markers.surface, deposits, 1)
			ProcessDepositMarkers(sector.markers.subsurface, deposits, 2)
			ProcessDepositMarkers(sector.markers.deep, deposits, 2)
		end)

		return deposits
	end

	function ShowExploration_Sectors(city, time)
		ForEachSector(city, function(sector)
			local decal = sector.decal
			if IsValid(decal) then
				decal:SetEnumFlags(const.efVisible)
			end
		end)
	end

	function HideExploration_Sectors(city, time)
		ForEachSector(city, function(sector)
			local decal = sector.decal
			if IsValid(decal) then
				decal:ClearEnumFlags(const.efVisible)
			end
		end)
	end

	function UpdateScannedSectorVisuals(status)
		ForEachSector(Global("MainCity"), function(sector)
			if not status or sector.status == status then
				sector:UpdateDecal()
			end
		end)
	end

	rawset(_G, "BiggerMapsSectorPatchVersion", SECTOR_PATCH_VERSION)
	DebugPrint("vanilla-sized sector patch installed")
	return true
end

local function ChainOnMsg(message_name, handler)
	local previous = OnMsg[message_name]

	OnMsg[message_name] = function(...)
		if previous then
			previous(...)
		end

		handler(...)
	end
end

DebugPrint("sector patch loaded v" .. tostring(SECTOR_PATCH_VERSION))
InstallSectorPatch()

local function EnsureSectorPatch(map, reason)
	DebugPrint("sector EnsureSectorPatch via " .. tostring(reason) .. ": " .. DescribeMap(map))
	InstallSectorPatch()
	ConfigureGlobalSectorCount(map, reason)
end

ChainOnMsg("ClassesPostprocess", function()
	DebugPrint("sector hook ClassesPostprocess")
	InstallSectorPatch()
end)

ChainOnMsg("ClassesBuilt", function()
	DebugPrint("sector hook ClassesBuilt")
	InstallSectorPatch()
end)

ChainOnMsg("DataLoaded", function()
	DebugPrint("sector hook DataLoaded")
	InstallSectorPatch()
end)

ChainOnMsg("ModsReloaded", function()
	DebugPrint("sector hook ModsReloaded")
	InstallSectorPatch()
end)

ChainOnMsg("ChangingMap", function(map_slot, map_name, map_instance)
	EnsureSectorPatch(map_instance, "ChangingMap")
end)

ChainOnMsg("PreNewMap", function(map, mapdata)
	EnsureSectorPatch(map or mapdata, "PreNewMap")
end)

ChainOnMsg("NewMap", function(map, mapdata)
	EnsureSectorPatch(map or mapdata, "NewMap")
end)

ChainOnMsg("MapGenerated", function(map)
	EnsureSectorPatch(map, "MapGenerated")
end)

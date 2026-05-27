local MOD_PREFIX = "[Bigger Maps] "
local SECTOR_PATCH_VERSION = 4

local function Global(name)
	return rawget(_G, name)
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

local function DebugPrint(message)
	if ConfigBool("DebugPrint", true) then
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

local function MapTileWorldSize(map)
	local width = TerrainSize(map)
	local mapdata = map and map.mapdata
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
	local mapdata = map and map.mapdata
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

local function SectorTargetSize(map)
	local mapdata = map and map.mapdata
	local base_tiles = OriginalWidthTiles(map)
	local base_count = math.floor(ConfigNumber("VanillaSectorBaseCount", 10, 1))
	local base_border = mapdata and mapdata.BiggerMapsOriginalPassBorder
	if type(base_border) ~= "number" then
		base_border = mapdata and mapdata.PassBorder or 0
	end

	local target = (base_tiles * MapTileWorldSize(map) - 2 * base_border) / base_count
	return math.max(1, Round(target))
end

local function HasExpandedSectorSource(map)
	local mapdata = map and map.mapdata
	return map and map.BiggerMapsSourceWidthTiles
		or map and map.BiggerMapsGeneratorWidthTiles
		or mapdata and mapdata.BiggerMapsQuadrantSourceWidthTiles
end

local function UseCustomSectorsForMap(map)
	if not ConfigBool("EnableVanillaSizedSectors", true) or not map then
		return false
	end

	local mapdata = map.mapdata
	if ConfigBool("VanillaSectorSurfaceOnly", true) and mapdata and mapdata.Environment ~= "Surface" then
		return false
	end

	if ConfigBool("VanillaSectorExpandedOnly", true) and not HasExpandedSectorSource(map) then
		return false
	end

	return true
end

local function ResolveSectorLayout(map)
	local width, height = TerrainSize(map)
	local mapdata = map and map.mapdata
	local border = mapdata and mapdata.PassBorder or 0
	local target = SectorTargetSize(map)
	local usable_width = math.max(1, width - 2 * border)
	local usable_height = math.max(1, height - 2 * border)
	local uniform = ConfigBool("VanillaSectorUniformGrid", true)
	local count_x = uniform and Round(usable_width / target) or math.ceil(usable_width / target)
	local count_y = uniform and Round(usable_height / target) or math.ceil(usable_height / target)
	local min_count = math.floor(ConfigNumber("VanillaSectorMinCount", 10, 1))
	local max_count = math.floor(ConfigNumber("VanillaSectorMaxCount", 26, min_count))
	local forced_count = Config()["VanillaSectorForcedCount"]

	if type(forced_count) == "number" and forced_count > 0 then
		count_x = ClampNumber(math.floor(forced_count), min_count, max_count)
		count_y = count_x
	else
		count_x = ClampNumber(count_x, min_count, max_count)
		count_y = ClampNumber(count_y, min_count, max_count)
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

local function SectorBounds(layout, col, row)
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
	local sector = MapSector:new(sector_data, map.slot)
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

local function InstallSectorPatch()
	if not ConfigBool("EnableVanillaSizedSectors", true) then
		return false
	end

	if Global("BiggerMapsSectorPatchVersion") == SECTOR_PATCH_VERSION then
		return true
	end

	if type(Global("Exploration")) ~= "table" or type(Global("MapSector")) ~= "table" or type(Global("InitSector")) ~= "function" then
		return false
	end

	if type(Global("GetMapSectorTileSize")) ~= "function" then
		return false
	end

	rawset(_G, "BiggerMapsOriginalGetMapSectorTileSize", Global("BiggerMapsOriginalGetMapSectorTileSize") or GetMapSectorTileSize)
	rawset(_G, "BiggerMapsOriginalGetMapSectorXY", Global("BiggerMapsOriginalGetMapSectorXY") or GetMapSectorXY)
	rawset(_G, "BiggerMapsOriginalExplorationInitSectors", Global("BiggerMapsOriginalExplorationInitSectors") or Exploration.InitSectors)
	rawset(_G, "BiggerMapsOriginalExplorationInitMapArea", Global("BiggerMapsOriginalExplorationInitMapArea") or Exploration.InitMapArea)
	rawset(_G, "BiggerMapsOriginalExplorationUpdateBuildableRatio", Global("BiggerMapsOriginalExplorationUpdateBuildableRatio") or Exploration.UpdateBuildableRatio)
	rawset(_G, "BiggerMapsOriginalInitialReveal", Global("BiggerMapsOriginalInitialReveal") or InitialReveal)

	if type(Global("BiggerMapsOriginalInitialReveal")) == "function" then
		InitialReveal = BuildFastInitialReveal(BiggerMapsOriginalInitialReveal)
	end

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
		local col = ClampNumber(1 + math.floor(x / layout.step_x), 1, layout.count_x)
		local row = ClampNumber(1 + math.floor(y / layout.step_y), 1, layout.count_y)
		local sector_col = city.MapSectors and city.MapSectors[col]
		return sector_col and sector_col[row]
	end

	function Exploration:InitSectors(map, eligible_sectors_with_surface_deposits_out)
		if not UseCustomSectorsForMap(map) then
			return BiggerMapsOriginalExplorationInitSectors(self, map, eligible_sectors_with_surface_deposits_out)
		end

		local layout = ResolveSectorLayout(map)
		local orient = map.mapdata.OverviewOrientation
		local unbuildable_z = buildUnbuildableZ()

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

	function Exploration:InitMapArea()
		if not UseCustomSectorsForMap(self:GetMap()) then
			return BiggerMapsOriginalExplorationInitMapArea(self)
		end

		local last_col = #self.MapSectors
		local last_row = last_col > 0 and #self.MapSectors[last_col] or 0
		assert(last_col > 0 and last_row > 0)
		self.MapArea = box(
			self.MapSectors[1][1].area:min(),
			self.MapSectors[last_col][last_row].area:max())
	end

	function Exploration:UpdateBuildableRatio(bbox)
		if not UseCustomSectorsForMap(self:GetMap()) then
			return BiggerMapsOriginalExplorationUpdateBuildableRatio(self, bbox)
		end

		local unbuildable_z = buildUnbuildableZ()
		local buildable_grid = self:GetMap().buildable
		ForEachSector(self, function(sector)
			if not bbox or bbox:Intersect2D(sector.area) ~= const.irOutside then
				sector.play_ratio = BuildableGridRatio(buildable_grid.z_grid, unbuildable_z, 100, sector.area)
			end
		end)
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

	function Exploration:GatherDiscoveredDeposits()
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

DebugPrint("sector patch loaded")
InstallSectorPatch()

ChainOnMsg("ClassesPostprocess", function()
	InstallSectorPatch()
end)

ChainOnMsg("ClassesBuilt", function()
	InstallSectorPatch()
end)

ChainOnMsg("DataLoaded", function()
	InstallSectorPatch()
end)

ChainOnMsg("ModsReloaded", function()
	InstallSectorPatch()
end)

ChainOnMsg("ChangingMap", function()
	InstallSectorPatch()
end)

ChainOnMsg("PreNewMap", function()
	InstallSectorPatch()
end)

ChainOnMsg("NewMap", function()
	InstallSectorPatch()
end)

ChainOnMsg("MapGenerated", function()
	InstallSectorPatch()
end)

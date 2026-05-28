-- Bigger Maps -- sector exploration patch.
--
-- Installs the engine-side sector behavior for vanilla-sized custom grids: it
-- overrides the global GetMapSectorTileSize / GetMapSectorXY / InitialReveal and the
-- Exploration:InitSectors / InitMapArea / UpdateBuildableRatio / GatherDiscoveredDeposits
-- methods (plus the global Show/Hide/Update sector-visual helpers and
-- UnexploredSectorsExist) so the city builds and scans our grid instead of the
-- vanilla 10x10. All grid math comes from BiggerMaps.SectorGrid; the hover-highlight
-- fix-up is delegated to BiggerMaps.SectorHighlight. These globals/methods MUST stay
-- global (the engine calls them by name); vanilla originals are saved in
-- BiggerMaps.State so RestoreVanillaBehavior can put them back.

local BiggerMaps = rawget(_G, "BiggerMaps")
if type(BiggerMaps) ~= "table" then
	BiggerMaps = {}
	rawset(_G, "BiggerMaps", BiggerMaps)
end

local Engine = BiggerMaps.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local ClassTable = Engine.ClassTable
local ClampNumber = Engine.ClampNumber
local Round = Engine.Round
local SECTOR_PATCH_VERSION = BiggerMaps.SECTOR_PATCH_VERSION or 21

local Grid = BiggerMaps.SectorGrid

local function DebugPrint(message)
	local DebugLog = BiggerMaps.DebugLog
	if DebugLog then
		DebugLog.Info("Sector", message)
	end
end

local function cfg_bool(key, default)
	local value = (BiggerMaps.Config or {})[key]
	if type(value) == "boolean" then
		return value
	end
	return default
end

local function cfg_number(key, default, min_value)
	local value = (BiggerMaps.Config or {})[key]
	if type(value) == "number" and (min_value == nil or value >= min_value) then
		return value
	end
	return default
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
		if not cfg_bool("SECTOR_FAST_INITIAL_REVEAL", true) then
			return original_initial_reveal(eligible, trand)
		end

		if type(eligible) ~= "table" or #eligible <= 0 then
			return original_initial_reveal(eligible, trand)
		end

		local filtered, best = {}, {}
		local has_metals, has_concrete = {}, {}
		local qty_per_sector = {}
		local deposit_resources = Global("GroupResourceIds") and GroupResourceIds.DepositResources or {}
		local progress_interval = math.floor(cfg_number("SECTOR_INITIAL_REVEAL_PROGRESS_INTERVAL", 50, 1))

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

local function BuildSector(map, city, row, col, layout, orient, unbuildable_z, eligible_sectors)
	local x1, y1, x2, y2 = Grid.SectorBounds(layout, col, row)
	local bbox = box(x1, y1, x2, y2)
	local buildable_grid = map.buildable
	local heat_grid = map.heat_grid
	local name = Grid.SectorName(row, col, layout.count, orient)
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
	local State = BiggerMaps.State

	DebugPrint(string.format(
		"sector basic patch attempt v%s: GetMapSectorTileSize=%s GetMapSectorXY=%s InitialReveal=%s",
		tostring(SECTOR_PATCH_VERSION),
		type(Global("GetMapSectorTileSize")),
		type(Global("GetMapSectorXY")),
		type(Global("InitialReveal"))
	))

	if State.sector_basic_patch_version == SECTOR_PATCH_VERSION then
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

	-- Save the vanilla originals once (subsequent re-patches keep the true vanilla
	-- value, not the already-installed override) and capture them as upvalues.
	local original_tile_size = State.original_get_map_sector_tile_size or GetMapSectorTileSize
	local original_sector_xy = State.original_get_map_sector_xy or GetMapSectorXY
	local original_initial_reveal = State.original_initial_reveal or InitialReveal
	State.original_get_map_sector_tile_size = original_tile_size
	State.original_get_map_sector_xy = original_sector_xy
	State.original_initial_reveal = original_initial_reveal

	function GetMapSectorTileSize(map)
		if Grid.UseCustomSectorsForMap(map) then
			return Grid.ResolveSectorLayout(map).step_x
		end
		return original_tile_size(map)
	end

	function GetMapSectorXY(city, mx, my)
		local map = city and city.GetMap and city:GetMap()
		if not Grid.UseCustomSectorsForMap(map) then
			return original_sector_xy(city, mx, my)
		end

		local layout = Grid.ResolveSectorLayout(map)
		local x = mx - layout.border
		local y = my - layout.border
		local col = ClampNumber(1 + math.floor(x / layout.step_x), 1, layout.count_x)
		local row = ClampNumber(1 + math.floor(y / layout.step_y), 1, layout.count_y)
		local sector_col = city.MapSectors and city.MapSectors[col]
		return sector_col and sector_col[row]
	end

	if type(original_initial_reveal) == "function" then
		InitialReveal = BuildFastInitialReveal(original_initial_reveal)
	end

	State.sector_basic_patch_version = SECTOR_PATCH_VERSION
	DebugPrint("sector basic functions patched")
	return true
end

local function InstallSectorPatch()
	local State = BiggerMaps.State

	DebugPrint(string.format(
		"sector full patch attempt v%s: Exploration=%s g_Exploration=%s MapSector=%s InitSector=%s",
		tostring(SECTOR_PATCH_VERSION),
		type(Global("Exploration")),
		type(ClassTable("Exploration")),
		type(ClassTable("MapSector")),
		type(Global("InitSector"))
	))

	local highlight = BiggerMaps.SectorHighlight
	if highlight then
		highlight.Install()
	end

	if not cfg_bool("ENABLE_VANILLA_SIZED_SECTORS", true) then
		DebugPrint("sector full patch disabled")
		return false
	end

	if State.sector_patch_version == SECTOR_PATCH_VERSION then
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

	local original_init_sectors = State.original_exploration_init_sectors or exploration_class.InitSectors
	local original_init_map_area = State.original_exploration_init_map_area or exploration_class.InitMapArea
	local original_update_buildable_ratio = State.original_exploration_update_buildable_ratio or exploration_class.UpdateBuildableRatio
	State.original_exploration_init_sectors = original_init_sectors
	State.original_exploration_init_map_area = original_init_map_area
	State.original_exploration_update_buildable_ratio = original_update_buildable_ratio

	exploration_class.InitSectors = function(self, map, eligible_sectors_with_surface_deposits_out)
		if not Grid.UseCustomSectorsForMap(map) then
			DebugPrint("sector InitSectors using vanilla path: " .. Grid.DescribeMap(map))
			return original_init_sectors(self, map, eligible_sectors_with_surface_deposits_out)
		end

		Grid.ConfigureGlobalSectorCount(map, "InitSectors")
		local layout = Grid.ResolveSectorLayout(map)
		local orient = map.mapdata.OverviewOrientation
		local unbuildable_z = buildUnbuildableZ()
		local progress_interval = math.floor(cfg_number("SECTOR_PROGRESS_COLUMN_INTERVAL", 2, 1))

		DebugPrint(string.format(
			"sector InitSectors begin: %s layout=%s x %s target=%s actual=%s x %s",
			Grid.DescribeMap(map),
			tostring(layout.count_x),
			tostring(layout.count_y),
			tostring(layout.target),
			tostring(Round(layout.step_x)),
			tostring(Round(layout.step_y))
		))

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
		if not Grid.UseCustomSectorsForMap(self:GetMap()) then
			DebugPrint("sector InitMapArea using vanilla path: " .. Grid.DescribeMap(self:GetMap()))
			return original_init_map_area(self)
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
		if not Grid.UseCustomSectorsForMap(self:GetMap()) then
			return original_update_buildable_ratio(self, bbox)
		end

		local unbuildable_z = buildUnbuildableZ()
		local buildable_grid = self:GetMap().buildable
		local processed = 0
		Grid.ForEachSector(self, function(sector)
			if not bbox or bbox:Intersect2D(sector.area) ~= const.irOutside then
				sector.play_ratio = BuildableGridRatio(buildable_grid.z_grid, unbuildable_z, 100, sector.area)
				processed = processed + 1
			end
		end)
		DebugPrint("sector UpdateBuildableRatio processed " .. tostring(processed) .. " sectors")
	end

	-- The following are global / class functions the engine calls by name. They are
	-- overridden in place; the pre-existing value (a function in vanilla, or false if
	-- absent) is saved once so RestoreVanillaBehavior can put it back.
	if State.original_unexplored_sectors_exist == nil then
		State.original_unexplored_sectors_exist = Global("UnexploredSectorsExist") or false
	end
	function UnexploredSectorsExist(city)
		local can_scan
		local fully_scanned = true
		local saw_sector = false

		Grid.ForEachSector(city, function(sector)
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

	if State.original_exploration_gather_discovered_deposits == nil then
		State.original_exploration_gather_discovered_deposits = exploration_class.GatherDiscoveredDeposits or false
	end
	exploration_class.GatherDiscoveredDeposits = function(self)
		local deposits = InitDepositInfoTable()

		Grid.ForEachSector(self, function(sector)
			ProcessDepositMarkers(sector.markers.surface, deposits, 1)
			ProcessDepositMarkers(sector.markers.subsurface, deposits, 2)
			ProcessDepositMarkers(sector.markers.deep, deposits, 2)
		end)

		return deposits
	end

	if State.original_show_exploration_sectors == nil then
		State.original_show_exploration_sectors = Global("ShowExploration_Sectors") or false
	end
	function ShowExploration_Sectors(city, time)
		Grid.ForEachSector(city, function(sector)
			local decal = sector.decal
			if IsValid(decal) then
				decal:SetEnumFlags(const.efVisible)
			end
		end)
	end

	if State.original_hide_exploration_sectors == nil then
		State.original_hide_exploration_sectors = Global("HideExploration_Sectors") or false
	end
	function HideExploration_Sectors(city, time)
		Grid.ForEachSector(city, function(sector)
			local decal = sector.decal
			if IsValid(decal) then
				decal:ClearEnumFlags(const.efVisible)
			end
		end)
	end

	if State.original_update_scanned_sector_visuals == nil then
		State.original_update_scanned_sector_visuals = Global("UpdateScannedSectorVisuals") or false
	end
	function UpdateScannedSectorVisuals(status)
		Grid.ForEachSector(Global("MainCity"), function(sector)
			if not status or sector.status == status then
				sector:UpdateDecal()
			end
		end)
	end

	State.sector_patch_version = SECTOR_PATCH_VERSION
	DebugPrint("vanilla-sized sector patch installed")
	return true
end

local function EnsureSectorPatch(map, reason)
	DebugPrint("sector EnsureSectorPatch via " .. tostring(reason) .. ": " .. Grid.DescribeMap(map))
	InstallSectorPatch()
	Grid.ConfigureGlobalSectorCount(map, reason)
end

local function restore_global(name, saved)
	if type(saved) == "function" then
		rawset(_G, name, saved)
	elseif saved == false then
		rawset(_G, name, nil)
	end
end

local SectorExploration = {}

SectorExploration.InstallSectorPatch = InstallSectorPatch
SectorExploration.EnsureSectorPatch = EnsureSectorPatch

function SectorExploration.ApplyModBehavior()
	InstallSectorPatch()
end

function SectorExploration.RestoreVanillaBehavior()
	local State = BiggerMaps.State or {}

	if type(State.original_get_map_sector_tile_size) == "function" then
		rawset(_G, "GetMapSectorTileSize", State.original_get_map_sector_tile_size)
	end
	if type(State.original_get_map_sector_xy) == "function" then
		rawset(_G, "GetMapSectorXY", State.original_get_map_sector_xy)
	end
	if type(State.original_initial_reveal) == "function" then
		rawset(_G, "InitialReveal", State.original_initial_reveal)
	end
	State.original_get_map_sector_tile_size = nil
	State.original_get_map_sector_xy = nil
	State.original_initial_reveal = nil

	local exploration_class = ClassTable("Exploration")
	if exploration_class then
		if type(State.original_exploration_init_sectors) == "function" then
			exploration_class.InitSectors = State.original_exploration_init_sectors
		end
		if type(State.original_exploration_init_map_area) == "function" then
			exploration_class.InitMapArea = State.original_exploration_init_map_area
		end
		if type(State.original_exploration_update_buildable_ratio) == "function" then
			exploration_class.UpdateBuildableRatio = State.original_exploration_update_buildable_ratio
		end
		if type(State.original_exploration_gather_discovered_deposits) == "function" then
			exploration_class.GatherDiscoveredDeposits = State.original_exploration_gather_discovered_deposits
		elseif State.original_exploration_gather_discovered_deposits == false then
			exploration_class.GatherDiscoveredDeposits = nil
		end
	end
	State.original_exploration_init_sectors = nil
	State.original_exploration_init_map_area = nil
	State.original_exploration_update_buildable_ratio = nil
	State.original_exploration_gather_discovered_deposits = nil

	restore_global("UnexploredSectorsExist", State.original_unexplored_sectors_exist)
	restore_global("ShowExploration_Sectors", State.original_show_exploration_sectors)
	restore_global("HideExploration_Sectors", State.original_hide_exploration_sectors)
	restore_global("UpdateScannedSectorVisuals", State.original_update_scanned_sector_visuals)
	State.original_unexplored_sectors_exist = nil
	State.original_show_exploration_sectors = nil
	State.original_hide_exploration_sectors = nil
	State.original_update_scanned_sector_visuals = nil

	-- Clear the patch guards so a later Enable re-installs cleanly.
	State.sector_basic_patch_version = nil
	State.sector_patch_version = nil
end

BiggerMaps.SectorExploration = SectorExploration

DebugPrint("sector exploration module loaded v" .. tostring(SECTOR_PATCH_VERSION))

-- Super Big Map -- sector exploration patch.
--
-- Installs the engine-side sector behavior for vanilla-sized custom grids: it
-- overrides the global GetMapSectorTileSize / GetMapSectorXY / InitialReveal and the
-- Exploration:InitSectors / InitMapArea / UpdateBuildableRatio / GatherDiscoveredDeposits
-- methods (plus the global Show/Hide/Update sector-visual helpers and
-- UnexploredSectorsExist) so the city builds and scans our grid instead of the
-- vanilla 10x10. All grid math comes from SuperBigMap.SectorGrid; the hover-highlight
-- fix-up is delegated to SuperBigMap.SectorHighlight. These globals/methods MUST stay
-- global (the engine calls them by name); vanilla originals are saved in
-- SuperBigMap.State so RestoreVanillaBehavior can put them back.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local ClassTable = Engine.ClassTable
local ClampNumber = Engine.ClampNumber
local SECTOR_PATCH_VERSION = SuperBigMap.SECTOR_PATCH_VERSION or 21

local Grid = SuperBigMap.SectorGrid

-- Shared by both patch installers and the later visual callbacks. Keeping this at file scope
-- avoids global lookup from ShowExploration_Sectors/UpdateScannedSectorVisuals.
local function UndergroundExplorationUiOn(city)
	if (SuperBigMap.Config or {}).UNDERGROUND_EXPLORATION_UI ~= true or not city then return false end
	local ok, map, env = pcall(function()
		local current_map = city:GetMap()
		return current_map, current_map and current_map.mapdata and current_map.mapdata.Environment
	end)
	-- IsExplorationAvailable_Queue is also consulted by vanilla InitSectors. Advertising the
	-- informational underground UI before the atomic stretch is complete makes vanilla run
	-- InitialExplore, scan a sector, and permanently place its deposits in otherwise untouched
	-- darkness. Keep vanilla's underground=false result during initialization; the overview UI
	-- becomes available only after the mod has finished preparing the map.
	return ok and map and env == "Underground" and map.SuperBigMapExpanded == true
end

local function cfg_bool(key, default)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "boolean" then
		return value
	end
	return default
end

-- GetMapSectorXY is called from engine hex searches once per tested hex. Recomputing the full
-- layout there can execute tens of thousands of Lua instructions during one deposit placement and
-- trip the engine's infinite-loop detector. Cache the immutable lookup layout after the live grid
-- is complete. The serialized MapSectors table is authoritative on load: map preset resolution can
-- briefly report another map's 15x15 layout while this city still owns a valid 20x20 grid.
local sector_lookup_layout_cache = setmetatable({}, { __mode = "k" })

local function LiveSectorGridDimensions(sectors)
	if type(sectors) ~= "table" then return 0, 0 end
	local count_x = 0
	while type(sectors[count_x + 1]) == "table" do
		count_x = count_x + 1
	end
	if count_x <= 0 then return 0, 0 end

	local count_y = false
	for col = 1, count_x do
		local column = sectors[col]
		local rows = 0
		while column[rows + 1] ~= nil do
			rows = rows + 1
		end
		if rows <= 0 or (count_y and rows ~= count_y) then
			return 0, 0
		end
		count_y = rows
	end
	return count_x, count_y or 0
end

local function BuildLiveSectorLookupLayout(city)
	local sectors = city and city.MapSectors
	local count_x, count_y = LiveSectorGridDimensions(sectors)
	if count_x <= 0 or count_y <= 0 then return nil end

	local first_sector = sectors[1] and sectors[1][1]
	local last_sector = sectors[count_x] and sectors[count_x][count_y]
	if not first_sector or not last_sector or not first_sector.area or not last_sector.area then
		return nil
	end

	local ok, min_point, max_point, min_x, min_y, max_x, max_y = pcall(function()
		local first_min = first_sector.area:min()
		local last_max = last_sector.area:max()
		return first_min, last_max, first_min:x(), first_min:y(), last_max:x(), last_max:y()
	end)
	if not ok then return nil end

	local width, height = max_x - min_x, max_y - min_y
	if width <= 0 or height <= 0 then return nil end
	return {
		border = min_x,
		origin_x = min_x,
		origin_y = min_y,
		count_x = count_x,
		count_y = count_y,
		count = math.max(count_x, count_y),
		step_x = width / count_x,
		step_y = height / count_y,
		uniform = true,
		usable_width = width,
		usable_height = height,
		width = width,
		height = height,
		min_point = min_point,
		max_point = max_point,
		first_sector = first_sector,
		last_sector = last_sector,
	}
end

local function CacheLiveSectorLookupLayout(city, layout)
	if not city or not layout then return layout end
	sector_lookup_layout_cache[city] = {
		sectors = city.MapSectors,
		first_sector = layout.first_sector,
		last_sector = layout.last_sector,
		count_x = layout.count_x,
		count_y = layout.count_y,
		layout = layout,
	}
	return layout
end

local function GetLiveCachedSectorLookupLayout(city)
	local sectors = city and city.MapSectors
	local cached = city and sector_lookup_layout_cache[city]
	if cached and cached.sectors == sectors and type(sectors) == "table" then
		local first_col = sectors[1]
		local last_col = sectors[cached.count_x]
		if first_col and first_col[1] == cached.first_sector
			and first_col[cached.count_y + 1] == nil
			and last_col and last_col[cached.count_y] == cached.last_sector
			and sectors[cached.count_x + 1] == nil then
			return cached.layout
		end
	end
	return nil
end

local function GetCachedSectorLookupLayout(city, map)
	local live = GetLiveCachedSectorLookupLayout(city)
	if live then return live end

	-- Prefer geometry reconstructed from the actual saved grid. This preserves old save state
	-- and prevents a transient/wrong map preset from shrinking lookup to 15x15.
	local layout = BuildLiveSectorLookupLayout(city)
	if layout then
		return CacheLiveSectorLookupLayout(city, layout)
	end

	local sectors = city and city.MapSectors
	layout = Grid.ResolveSectorLayout(map)
	if city and type(sectors) == "table" and layout then
		local first_col = sectors[1]
		local last_col = sectors[layout.count_x]
		local first_sector = first_col and first_col[1]
		local last_sector = last_col and last_col[layout.count_y]
		-- Do not cache a partially-built grid; a later lookup after InitSectors completes will retry.
		if first_sector and last_sector then
			sector_lookup_layout_cache[city] = {
				sectors = sectors,
				first_sector = first_sector,
				last_sector = last_sector,
				count_x = layout.count_x,
				count_y = layout.count_y,
				layout = layout,
			}
		end
	end
	return layout
end

-- World-unit width of the live sector[1][1] (the actual built size), or nil.
local function LiveSectorSize(city)
	local sectors = city and type(city.MapSectors) == "table" and city.MapSectors
	local first = sectors and type(sectors[1]) == "table" and sectors[1][1]
	if first and first.area and type(first.area.sizex) == "function" then
		local ok, sx = pcall(first.area.sizex, first.area)
		if ok and type(sx) == "number" then
			return sx
		end
	end
	return nil
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

local function CityMap(city)
	if city and type(city.GetMap) == "function" then
		return SafeCall(city.GetMap, city)
	end
	return nil
end

local function SectorInteractionEnabled()
	local diagnostics = SuperBigMap.Diagnostics
	return type(diagnostics) == "table"
		and type(diagnostics.SectorInteractionEnabled) == "function"
		and diagnostics.SectorInteractionEnabled() == true
end

local function SectorInteractionAudit(event, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if type(diagnostics) == "table" and type(diagnostics.SectorInteraction) == "function" then
		diagnostics.SectorInteraction(event, data, map)
	end
end

local function OverviewGridEnabled()
	local diagnostics = SuperBigMap.Diagnostics
	return type(diagnostics) == "table"
		and type(diagnostics.OverviewGridEnabled) == "function"
		and diagnostics.OverviewGridEnabled() == true
end

local function OverviewGridAudit(event, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if type(diagnostics) == "table" and type(diagnostics.OverviewGrid) == "function" then
		diagnostics.OverviewGrid(event, data, map)
	end
end

local function SectorDiagnosticData(sector, data)
	data = type(data) == "table" and data or {}
	if not sector then
		data.sector = "nil"
		return data
	end
	data.sector = tostring(sector)
	data.sector_id = tostring(sector.id)
	data.sector_display_name = tostring(sector.display_name)
	data.sector_col = tostring(sector.col)
	data.sector_row = tostring(sector.row)
	data.sector_status = tostring(sector.status)
	data.sector_play_ratio = tostring(sector.play_ratio)
	data.sector_area = tostring(sector.area)
	if sector.area then
		local ok, area_min, area_max, area_center, area_size_x, area_size_y = pcall(function()
			return sector.area:min(), sector.area:max(), sector.area:Center(),
				sector.area:sizex(), sector.area:sizey()
		end)
		if ok then
			data.sector_area_min = tostring(area_min)
			data.sector_area_max = tostring(area_max)
			data.sector_area_center = tostring(area_center)
			data.sector_area_size = tostring(area_size_x) .. "x" .. tostring(area_size_y)
		end
	end
	if type(sector.CanBeScanned) == "function" then
		data.sector_can_scan = tostring(SafeCall(sector.CanBeScanned, sector))
	end
	if type(sector.HasBlockers) == "function" then
		data.sector_has_blockers = tostring(SafeCall(sector.HasBlockers, sector))
	end
	local city = sector.city
	local queue = city and city.ExplorationQueue
	data.queue_count = tostring(type(queue) == "table" and #queue or nil)
	if type(queue) == "table" then
		for i = 1, #queue do
			if queue[i] == sector then
				data.queue_index = tostring(i)
				break
			end
		end
	end
	local decal = sector.decal
	local is_valid = Global("IsValid")
	data.sector_decal = tostring(decal)
	data.sector_decal_valid = tostring(decal
		and (type(is_valid) ~= "function" or SafeCall(is_valid, decal) == true))
	if decal then
		data.sector_decal_pos = tostring(type(decal.GetPos) == "function"
			and SafeCall(decal.GetPos, decal))
		data.sector_decal_scale = tostring(type(decal.GetScale) == "function"
			and SafeCall(decal.GetScale, decal))
		data.sector_decal_visible = tostring(type(decal.GetVisible) == "function"
			and SafeCall(decal.GetVisible, decal))
		data.sector_decal_enum_flags = tostring(type(decal.GetEnumFlags) == "function"
			and SafeCall(decal.GetEnumFlags, decal))
	end
	return data
end

local function AuditSectorGrid(city, event, detail)
	if not SectorInteractionEnabled() then return end
	local map = CityMap(city)
	local layout = map and Grid.ResolveSectorLayout(map)
	local live_layout = BuildLiveSectorLookupLayout(city)
	local sectors = city and city.MapSectors
	local cols = 0
	if type(sectors) == "table" then
		while type(sectors[cols + 1]) == "table" do cols = cols + 1 end
	end
	local rows = 0
	if cols > 0 then
		while sectors[1][rows + 1] ~= nil do rows = rows + 1 end
	end
	local data = {
		reason = tostring(event),
		grid_columns = tostring(cols),
		grid_rows = tostring(rows),
		city = tostring(city),
		city_map_area = tostring(city and city.MapArea),
		map_world_size = tostring(map and map.Width) .. "x" .. tostring(map and map.Height),
		map_pass_border = tostring(map and map.mapdata and map.mapdata.PassBorder),
		layout_border = tostring(layout and layout.border),
		layout_count = tostring(layout and layout.count_x) .. "x" .. tostring(layout and layout.count_y),
		layout_step = tostring(layout and layout.step_x) .. "x" .. tostring(layout and layout.step_y),
		layout_size = tostring(layout and layout.width) .. "x" .. tostring(layout and layout.height),
		live_layout_count = tostring(live_layout and live_layout.count_x)
			.. "x" .. tostring(live_layout and live_layout.count_y),
		live_layout_step = tostring(live_layout and live_layout.step_x)
			.. "x" .. tostring(live_layout and live_layout.step_y),
		live_layout_size = tostring(live_layout and live_layout.width)
			.. "x" .. tostring(live_layout and live_layout.height),
		const_sector_count = tostring(Global("const") and const.SectorCount),
	}
	SectorInteractionAudit("GRID_SUMMARY", data, map)
	if detail ~= true or type(sectors) ~= "table" then return end
	local samples = {
		{ 1, 1 }, { 5, 13 }, { 5, 14 }, { 6, 13 }, { 6, 14 },
		{ 6, 20 }, { 20, 1 }, { 20, 13 }, { 20, 14 }, { 20, 20 },
	}
	for i = 1, #samples do
		local col, row = samples[i][1], samples[i][2]
		local sector = sectors[col] and sectors[col][row]
		SectorInteractionAudit("GRID_SAMPLE", SectorDiagnosticData(sector, {
			reason = tostring(event),
			sample = tostring(col) .. "," .. tostring(row),
		}), map)
	end
end

local function UsesCustomCitySectors(city)
	return Grid.UseCustomSectorsForMap(CityMap(city)) == true
end

local function BuildFastInitialReveal(original_initial_reveal)
	return function(eligible, trand)
		if not cfg_bool("SECTOR_FAST_INITIAL_REVEAL", true) then
			return original_initial_reveal(eligible, trand)
		end

		if type(eligible) ~= "table" or #eligible <= 0 then
			return original_initial_reveal(eligible, trand)
		end

		-- The fast selector is an expanded-grid optimization, not a replacement for
		-- vanilla InitialReveal.  On a non-expanded map call the exact engine function
		-- before inspecting or re-weighting a single sector.
		local first_city = eligible[1] and eligible[1].city
		if not UsesCustomCitySectors(first_city) then
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


		return revealed, spawn_positions
	end
end

local function BuildSector(map, city, row, col, layout, orient, unbuildable_z, eligible_sectors)
	local x1, y1, x2, y2 = Grid.SectorBounds(layout, col, row)
	local bbox = box(x1, y1, x2, y2)
	local buildable_grid = map.buildable
	local heat_grid = map.heat_grid
	local name = Grid.SectorName(row, col, layout.count, orient)
	local display_name = Grid.SectorDisplayName(row, col, layout.count, orient)
	local sector_data = {
		id = name,
		display_name = display_name,
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

-- Existing expanded saves may already contain a correctly-sized MapSectors grid
-- with the old right-to-left visible labels. Relabel those sector objects in place:
-- display_name is presentation only, while id remains untouched so exploration
-- queues, deposits, and serialized object references keep their original identity.
local function RefreshSectorDisplayNames(map)
	if not Grid.UseCustomSectorsForMap(map) then return 0 end
	local city = map and map.City
	if not city or type(city.MapSectors) ~= "table"
		or type(Grid.SectorDisplayName) ~= "function" then return 0 end

	local live_layout = BuildLiveSectorLookupLayout(city)
	local count = live_layout and live_layout.count or Grid.ResolveSectorCount(map)
	if type(count) ~= "number" or count <= 0 then return 0 end
	local mapdata = map.mapdata
	local orient = type(mapdata) == "table" and mapdata.OverviewOrientation or 0
	local changed = 0
	Grid.ForEachSector(city, function(sector, col, row)
		local display_name = Grid.SectorDisplayName(row, col, count, orient)
		if sector.display_name ~= display_name then
			sector.display_name = display_name
			changed = changed + 1
		end
	end)
	return changed
end

local SectorDecalClasses = { "SectorUnexplored", "SectorScanned" }
local SectorDecalEntitySet = { SectorUnexplored = true, SectorScanned = true }
local SectorSelectionClasses = { "SectorRadius", "SectorTarget" }

local function ResolveVisualMap(city, map)
	if map then
		return map
	end
	if city and type(city.GetMap) == "function" then
		local city_map = SafeCall(city.GetMap, city)
		if city_map then
			return city_map
		end
	end
	return Global("CurrentMap")
end

local function ForEachMapObjectByClass(map, classes, callback, _, filter)
	if not map or type(map.MapForEach) ~= "function" then
		return 0
	end

	local objects = {}
	for i = 1, #classes do
		local class = classes[i]
		pcall(map.MapForEach, map, "map", class, function(obj)
			objects[#objects + 1] = obj
		end)
	end

	local count = 0
	for i = 1, #objects do
		local obj = objects[i]
		if IsValid(obj) and (not filter or filter(obj)) then
			local ok = pcall(callback, obj)
			if ok then
				count = count + 1
			end
		end
	end
	return count
end

local function IsSectorDecalEntity(obj)
	if not obj or type(obj.GetEntity) ~= "function" then
		return false
	end
	local entity = SafeCall(obj.GetEntity, obj)
	return SectorDecalEntitySet[entity] == true
end

local function ForEachSectorDecalObject(map, callback, reason)
	local count = ForEachMapObjectByClass(map, SectorDecalClasses, callback, reason)
	if count > 0 then
		return count
	end

	local fallback_count = ForEachMapObjectByClass(map, { "Decal" }, callback, reason, IsSectorDecalEntity)
	return fallback_count
end

local function PointXY(value)
	if not value then return nil end
	local ok, x, y = pcall(function() return value:x(), value:y() end)
	if ok and type(x) == "number" and type(y) == "number" then
		return x, y
	end
	return nil
end

local function PositionMatches(obj, target)
	if not obj or not target or type(obj.GetPos) ~= "function" then return false end
	local pos = SafeCall(obj.GetPos, obj)
	local x, y = PointXY(pos)
	local target_x, target_y = PointXY(target)
	return x ~= nil and target_x ~= nil and x == target_x and y == target_y
end

local function ExpectedSectorDecalScale(sector)
	local area = sector and sector.area
	if not area or type(area.sizex) ~= "function" then return nil end
	local size = SafeCall(area.sizex, area)
	if type(size) ~= "number" or size <= 0 then return nil end
	local guim = Global("guim")
	guim = type(guim) == "number" and guim > 0 and guim or 100
	local mul_div_round = Global("MulDivRound")
	local scale = type(mul_div_round) == "function"
		and SafeCall(mul_div_round, size, 100, 100 * guim)
		or math.floor(size / guim + 0.5)
	return type(scale) == "number" and scale + 1 or nil
end

-- MapSector is a saved game object separate from its serialized .area. Old saves can therefore
-- hold a correct 20x20 area table while the object itself still sits at a pre-repair position.
-- Vanilla places the active scan effect and refreshed decal at MapSector:GetPos(), while queue
-- numbers use area:Center(); keeping the two sources synchronized prevents the huge displaced
-- scan/grid rectangle seen when the queue became active around nightfall.
local function NormalizeSectorVisualGeometry(sector)
	local stats = {
		sectors = 0, sector_positions = 0, decal_positions = 0, decal_scales = 0,
		scan_positions = 0, queue_text_positions = 0,
	}
	if not sector or not sector.area or type(sector.area.Center) ~= "function" then return stats end
	local center = SafeCall(sector.area.Center, sector.area)
	if not center then return stats end
	stats.sectors = 1

	if type(sector.SetPos) == "function" and not PositionMatches(sector, center) then
		if pcall(sector.SetPos, sector, center) then stats.sector_positions = 1 end
	end

	local decal = sector.decal
	if IsValid(decal) then
		if type(decal.SetPos) == "function" and not PositionMatches(decal, center) then
			if pcall(decal.SetPos, decal, center) then stats.decal_positions = 1 end
		end
		local expected_scale = ExpectedSectorDecalScale(sector)
		local current_scale = type(decal.GetScale) == "function" and SafeCall(decal.GetScale, decal)
		if expected_scale and current_scale ~= expected_scale and type(decal.SetScale) == "function" then
			if pcall(decal.SetScale, decal, expected_scale) then stats.decal_scales = 1 end
		end
	end

	local scan_obj = sector.scan_obj
	if IsValid(scan_obj) and type(scan_obj.SetPos) == "function"
		and not PositionMatches(scan_obj, center) then
		if pcall(scan_obj.SetPos, scan_obj, center) then stats.scan_positions = 1 end
	end

	local queue_text = sector.queue_text
	if IsValid(queue_text) and type(queue_text.SetPos) == "function"
		and not PositionMatches(queue_text, center) then
		if pcall(queue_text.SetPos, queue_text, center) then stats.queue_text_positions = 1 end
	end
	return stats
end

local function RepairSectorVisualGeometry(city)
	local totals = {
		sectors = 0, sector_positions = 0, decal_positions = 0, decal_scales = 0,
		scan_positions = 0, queue_text_positions = 0,
	}
	Grid.ForEachSector(city, function(sector)
		local stats = NormalizeSectorVisualGeometry(sector)
		for key, value in pairs(stats) do totals[key] = (totals[key] or 0) + value end
	end)
	return totals
end

-- SectorUnexplored/SectorScanned are exclusively MapSector-owned visuals. Remove only objects
-- that are not referenced by any live saved sector; no MapSector, scan state, queue, deposit, or
-- gameplay object is replaced.
local function PruneOrphanSectorDecals(city, map)
	map = ResolveVisualMap(city, map)
	local referenced = {}
	Grid.ForEachSector(city, function(sector)
		if IsValid(sector.decal) then referenced[sector.decal] = true end
	end)
	local done_object = Global("DoneObject")
	local orphan_count, object_count = 0, 0
	local orphan_samples = {}
	ForEachSectorDecalObject(map, function(obj)
		object_count = object_count + 1
		if not referenced[obj] and type(done_object) == "function" then
			if #orphan_samples < 12 then
				orphan_samples[#orphan_samples + 1] = table.concat({
					tostring(obj),
					tostring(type(obj.GetEntity) == "function" and SafeCall(obj.GetEntity, obj)),
					tostring(type(obj.GetPos) == "function" and SafeCall(obj.GetPos, obj)),
					tostring(type(obj.GetScale) == "function" and SafeCall(obj.GetScale, obj)),
				}, "@")
			end
			done_object(obj)
			orphan_count = orphan_count + 1
		end
	end, "PruneOrphanSectorDecals")
	return orphan_count, object_count,
		#orphan_samples > 0 and table.concat(orphan_samples, "|") or "none"
end

local function MapSectorObjects(map)
	local objects = {}
	if not map or type(map.MapForEach) ~= "function" then return objects end
	pcall(map.MapForEach, map, "map", "MapSector", function(obj)
		if obj and obj.class == "MapSector" then objects[#objects + 1] = obj end
	end)
	return objects
end

local function DestroyMapSectorObjects(map, keep)
	local done_object = Global("DoneObject")
	local is_valid = Global("IsValid")
	if type(done_object) ~= "function" then return 0, 0 end
	local objects = MapSectorObjects(map)
	local removed = 0
	for i = 1, #objects do
		local sector = objects[i]
		local valid = type(is_valid) ~= "function" or SafeCall(is_valid, sector) == true
		if valid and not (keep and keep[sector]) then
			pcall(done_object, sector)
			removed = removed + 1
		end
	end
	return removed, #objects
end

-- Rebuilding self.MapSectors used to discard only the Lua table and decals, leaving each old
-- saved MapSector object on the map. Prune those unreferenced structural objects on load, and
-- destroy the complete old set before an intentional rebuild.
local function PruneOrphanMapSectors(city, map)
	local keep = {}
	Grid.ForEachSector(city, function(sector) keep[sector] = true end)
	return DestroyMapSectorObjects(ResolveVisualMap(city, map), keep)
end

local function AuditOverviewGridVisuals(city, event, extra)
	if not OverviewGridEnabled() then return false end
	city = city or Global("UICity") or Global("MainCity")
	local map = ResolveVisualMap(city)
	if not city or not map or not Grid.UseCustomSectorsForMap(map) then return false end

	local referenced = {}
	local data = type(extra) == "table" and extra or {}
	local mismatch_samples = {}
	local expected_decal_scale
	data.reason = tostring(event)
	data.city = tostring(city)
	data.city_map_area = tostring(city.MapArea)
	data.const_sector_count = tostring(Global("const") and const.SectorCount)
	data.map_world_size = tostring(map.Width) .. "x" .. tostring(map.Height)
	data.map_night_lights_state = tostring(map.NightLightsState)
	data.exploration_queue_count = tostring(
		type(city.ExplorationQueue) == "table" and #city.ExplorationQueue or nil)
	data.canonical_decal_count = 0
	data.canonical_decal_visible = 0
	data.sector_position_mismatches = 0
	data.decal_position_mismatches = 0
	data.decal_scale_mismatches = 0
	data.scan_object_count = 0
	data.scan_position_mismatches = 0
	data.queue_text_count = 0
	data.queue_text_position_mismatches = 0

	local function AddMismatch(kind, sector, value, expected)
		if #mismatch_samples >= 12 then return end
		mismatch_samples[#mismatch_samples + 1] = table.concat({
			tostring(kind), tostring(sector and sector.id), tostring(value), tostring(expected),
		}, ":")
	end

	Grid.ForEachSector(city, function(sector)
		local center = sector.area and type(sector.area.Center) == "function"
			and SafeCall(sector.area.Center, sector.area)
		if center and not PositionMatches(sector, center) then
			data.sector_position_mismatches = data.sector_position_mismatches + 1
			AddMismatch("sector_pos", sector,
				type(sector.GetPos) == "function" and SafeCall(sector.GetPos, sector), center)
		end
		local decal = sector.decal
		if IsValid(decal) then
			referenced[decal] = true
			data.canonical_decal_count = data.canonical_decal_count + 1
			if type(decal.GetVisible) == "function" and SafeCall(decal.GetVisible, decal) == true then
				data.canonical_decal_visible = data.canonical_decal_visible + 1
			end
			if center and not PositionMatches(decal, center) then
				data.decal_position_mismatches = data.decal_position_mismatches + 1
				AddMismatch("decal_pos", sector, SafeCall(decal.GetPos, decal), center)
			end
			local expected_scale = ExpectedSectorDecalScale(sector)
			expected_decal_scale = expected_decal_scale or expected_scale
			local scale = type(decal.GetScale) == "function" and SafeCall(decal.GetScale, decal)
			if expected_scale and scale ~= expected_scale then
				data.decal_scale_mismatches = data.decal_scale_mismatches + 1
				AddMismatch("decal_scale", sector, scale, expected_scale)
			end
		end
		local scan_obj = sector.scan_obj
		if IsValid(scan_obj) then
			data.scan_object_count = data.scan_object_count + 1
			if center and not PositionMatches(scan_obj, center) then
				data.scan_position_mismatches = data.scan_position_mismatches + 1
				AddMismatch("scan_pos", sector, SafeCall(scan_obj.GetPos, scan_obj), center)
			end
			data.scan_sector_id = tostring(sector.id)
			data.scan_sector_pos = tostring(type(sector.GetPos) == "function"
				and SafeCall(sector.GetPos, sector))
			data.scan_object = tostring(scan_obj)
			data.scan_object_pos = tostring(type(scan_obj.GetPos) == "function"
				and SafeCall(scan_obj.GetPos, scan_obj))
			data.scan_object_scale = tostring(type(scan_obj.GetScale) == "function"
				and SafeCall(scan_obj.GetScale, scan_obj))
			data.scan_object_entity = tostring(type(scan_obj.GetEntity) == "function"
				and SafeCall(scan_obj.GetEntity, scan_obj))
			data.scan_object_visible = tostring(type(scan_obj.GetVisible) == "function"
				and SafeCall(scan_obj.GetVisible, scan_obj))
			data.scan_sector_status = tostring(sector.status)
			data.scan_sector_progress = tostring(sector.scan_progress)
			data.scan_sector_area = tostring(sector.area)
		end
		local queue_text = sector.queue_text
		if IsValid(queue_text) then
			data.queue_text_count = data.queue_text_count + 1
			if center and not PositionMatches(queue_text, center) then
				data.queue_text_position_mismatches = data.queue_text_position_mismatches + 1
				AddMismatch("queue_text_pos", sector, SafeCall(queue_text.GetPos, queue_text), center)
			end
		end
	end)

	data.expected_decal_scale = tostring(expected_decal_scale)
	data.mismatch_samples = #mismatch_samples > 0 and table.concat(mismatch_samples, "|") or "none"
	data.map_sector_decal_objects = 0
	data.orphan_sector_decal_objects = 0
	local decal_object_samples = {}
	ForEachSectorDecalObject(map, function(obj)
		data.map_sector_decal_objects = data.map_sector_decal_objects + 1
		if not referenced[obj] then
			data.orphan_sector_decal_objects = data.orphan_sector_decal_objects + 1
		end
		if #decal_object_samples < 12 then
			decal_object_samples[#decal_object_samples + 1] = table.concat({
				tostring(obj),
				tostring(type(obj.GetEntity) == "function" and SafeCall(obj.GetEntity, obj)),
				tostring(type(obj.GetPos) == "function" and SafeCall(obj.GetPos, obj)),
				tostring(type(obj.GetScale) == "function" and SafeCall(obj.GetScale, obj)),
				tostring(referenced[obj] == true),
			}, "@")
		end
	end, "AuditOverviewGridVisuals")
	data.sector_decal_object_samples = #decal_object_samples > 0
		and table.concat(decal_object_samples, "|") or "none"

	local selection_samples = {}
	data.selection_object_count = ForEachMapObjectByClass(map, SectorSelectionClasses, function(obj)
		if #selection_samples < 12 then
			selection_samples[#selection_samples + 1] = table.concat({
				tostring(obj),
				tostring(type(obj.GetEntity) == "function" and SafeCall(obj.GetEntity, obj)),
				tostring(type(obj.GetPos) == "function" and SafeCall(obj.GetPos, obj)),
				tostring(type(obj.GetScale) == "function" and SafeCall(obj.GetScale, obj)),
				tostring(type(obj.GetVisible) == "function" and SafeCall(obj.GetVisible, obj)),
			}, "@")
		end
	end, "AuditOverviewGridVisuals selections")
	data.selection_object_samples = #selection_samples > 0
		and table.concat(selection_samples, "|") or "none"

	local get_time = Global("GetTimeOfDay")
	if type(get_time) == "function" then
		local hour, minute = SafeCall(get_time)
		data.time_of_day = tostring(hour) .. ":" .. tostring(minute)
	end
	local get_lightmodel = Global("GetLightmodel")
	if type(get_lightmodel) == "function" then
		data.lightmodel = tostring(SafeCall(get_lightmodel, 1))
	end
	local current_lightmodel_list = Global("GetCurrentLightmodelList")
	if type(current_lightmodel_list) == "function" then
		data.lightmodel_list = tostring(SafeCall(current_lightmodel_list))
	end
	local is_overview = Global("IsOverviewMode")
	data.overview_active = tostring(type(is_overview) == "function" and SafeCall(is_overview) == true)
	local hr = Global("hr")
	if type(hr) == "table" then
		data.hr_far_z = tostring(hr.FarZ)
		data.hr_shadow_range_override = tostring(hr.ShadowRangeOverride)
		data.hr_shadow_fade_percent = tostring(hr.ShadowFadeOutRangePercent)
		data.hr_tod_force_time = tostring(hr.TODForceTime)
	end
	OverviewGridAudit("VISUAL_SNAPSHOT", data, map)
	return true
end

local function HideSectorDecals(city, reason)
	local count = 0
	Grid.ForEachSector(city, function(sector)
		local decal = sector.decal
		if IsValid(decal) then
			decal:ClearEnumFlags(const.efVisible)
			count = count + 1
		end
	end)
	return count
end

local function HideSectorDecalObjects(city, reason, map)
	map = ResolveVisualMap(city, map)
	local count = ForEachSectorDecalObject(map, function(obj)
		obj:ClearEnumFlags(const.efVisible)
	end, reason)
	return count
end

local function HideOverviewSelectionObjects(reason, map)
	map = ResolveVisualMap(nil, map)
	local count = ForEachMapObjectByClass(map, SectorSelectionClasses, function(obj)
		obj:ClearEnumFlags(const.efVisible)
	end, reason)
	return count
end

local function HideSectorVisuals(city, reason)
	local map = ResolveVisualMap(city)
	HideSectorDecals(city, reason)
	local hidden_decal_objects = HideSectorDecalObjects(city, reason, map)
	local hidden_selection = HideOverviewSelectionObjects(reason, map)
	return hidden_decal_objects, hidden_selection
end

local function DestroySectorDecalRefs(city, reason)
	local done_object = Global("DoneObject")
	if type(done_object) ~= "function" then
		return 0
	end

	local count = 0
	Grid.ForEachSector(city, function(sector)
		local decal = sector.decal
		if IsValid(decal) then
			done_object(decal)
			sector.decal = nil
			count = count + 1
		end
	end)
	return count
end

local function DestroySectorDecalObjects(map, reason)
	local done_object = Global("DoneObject")
	if type(done_object) ~= "function" then
		return 0
	end

	local count = ForEachSectorDecalObject(map, function(obj)
		done_object(obj)
	end, reason)
	return count
end

local function DestroyExistingSectorVisuals(city, map, reason)
	map = ResolveVisualMap(city, map)
	local ref_count = DestroySectorDecalRefs(city, reason)
	local object_count = DestroySectorDecalObjects(map, reason)
	return ref_count, object_count
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
	local State = SuperBigMap.State


	if State.sector_basic_patch_version == SECTOR_PATCH_VERSION then
		return true
	end

	if type(Global("GetMapSectorTileSize")) ~= "function" then
		return false
	end

	if type(Global("GetMapSectorXY")) ~= "function" then
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
			local city = map and map.City
			local layout = city and GetCachedSectorLookupLayout(city, map) or Grid.ResolveSectorLayout(map)
			local step = layout.step_x
			return step
		end
		local vanilla = original_tile_size(map)
		return vanilla
	end

	function GetMapSectorXY(city, mx, my)
		-- The completed expanded grid is the steady-state hot path. Avoid even resolving the map
		-- or re-running the custom-map predicate for every hex tested by HexGridFindBuildable.
		local map
		local layout = GetLiveCachedSectorLookupLayout(city)
		if not layout then
			map = city and city.GetMap and city:GetMap()
			if not Grid.UseCustomSectorsForMap(map) then
				return original_sector_xy(city, mx, my)
			end
			layout = GetCachedSectorLookupLayout(city, map)
		end
		local origin_x = layout.origin_x or layout.border
		local origin_y = layout.origin_y or layout.border
		local x = mx - origin_x
		local y = my - origin_y
		local raw_col = 1 + math.floor(x / layout.step_x)
		local raw_row = 1 + math.floor(y / layout.step_y)
		local col = ClampNumber(raw_col, 1, layout.count_x)
		local row = ClampNumber(raw_row, 1, layout.count_y)
		local sector_col = city.MapSectors and city.MapSectors[col]
		local sector = sector_col and sector_col[row]
		if SectorInteractionEnabled() then
			local is_overview = Global("IsOverviewMode")
			local overview = type(is_overview) == "function" and SafeCall(is_overview) == true
			if overview then
				map = map or CityMap(city)
				local State = SuperBigMap.State or {}
				local signature = tostring(map) .. ":" .. tostring(raw_col) .. ":" .. tostring(raw_row)
					.. ":" .. tostring(sector and sector.id)
				if State.sector_interaction_lookup_signature ~= signature then
					State.sector_interaction_lookup_signature = signature
					SectorInteractionAudit("SECTOR_LOOKUP", SectorDiagnosticData(sector, {
						input_world_x = tostring(mx),
						input_world_y = tostring(my),
						adjusted_x = tostring(x),
						adjusted_y = tostring(y),
						raw_col = tostring(raw_col),
						raw_row = tostring(raw_row),
						clamped_col = tostring(col),
						clamped_row = tostring(row),
						was_clamped = tostring(raw_col ~= col or raw_row ~= row),
						layout_border = tostring(layout.border),
						layout_origin = tostring(origin_x) .. "," .. tostring(origin_y),
						layout_step = tostring(layout.step_x) .. "x" .. tostring(layout.step_y),
						layout_count = tostring(layout.count_x) .. "x" .. tostring(layout.count_y),
						layout_size = tostring(layout.width) .. "x" .. tostring(layout.height),
						city_map_area = tostring(city and city.MapArea),
					}), map)
				end
			end
		end
		return sector
	end

	-- Underground overview sector UI: vanilla HARD-GATES the sector hover/rollover/scan-queue off
	-- underground maps -- IsExplorationAvailable_Sectors/Queue return false for
	-- Environment=="Underground" (Exploration.lua:569-577), so OverviewModeDialog:SelectSector
	-- early-outs before drawing the highlight decal or rollover (the "hover shows nothing
	-- underground"). Wrap both to return
	-- true for fully prepared underground cities when config UNDERGROUND_EXPLORATION_UI is on
	-- (checked live, so flipping the config takes effect without a reload). The preparation gate
	-- is gameplay-critical: without it vanilla InitSectors performs InitialExplore merely because
	-- the queue reports available, revealing a random underground sector. Asteroids keep vanilla
	-- behavior.
	local orig_avail_sectors = State.original_is_expl_avail_sectors or Global("IsExplorationAvailable_Sectors")
	local orig_avail_queue = State.original_is_expl_avail_queue or Global("IsExplorationAvailable_Queue")
	State.original_is_expl_avail_sectors = orig_avail_sectors
	State.original_is_expl_avail_queue = orig_avail_queue
	if type(orig_avail_sectors) == "function" then
		function IsExplorationAvailable_Sectors(city)
			if UndergroundExplorationUiOn(city) then return true end
			return orig_avail_sectors(city)
		end
	end
	if type(orig_avail_queue) == "function" then
		function IsExplorationAvailable_Queue(city)
			if UndergroundExplorationUiOn(city) then return true end
			return orig_avail_queue(city)
		end
	end

	if type(original_initial_reveal) == "function" then
		InitialReveal = BuildFastInitialReveal(original_initial_reveal)
	end

	State.sector_basic_patch_version = SECTOR_PATCH_VERSION
	return true
end

-- ---------------------------------------------------------------------------------------
-- VANILLA-EQUIVALENT START SECTOR (config STRETCH_VANILLA_START_SECTOR, scope "StartSector").
-- Vanilla picks the initially revealed sector by RESOURCE QUALITY, not position:
-- Exploration:InitialExplore -> InitialReveal(eligible, trand) over the 10x10 sector grid
-- (origin PassBorder, tile (W-2*border)/10), preferring Metals>=50 + Concrete, weighted by
-- play_ratio*avg_heat, with the map-seed-deterministic CreateMapRand("Exploration") stream.
-- On the expanded map the candidate set is the 20x20 grid, so the (deterministic) pick lands
-- somewhere unrelated to vanilla's. Fix: while the temporary native backing and all of its
-- markers still exist, run vanilla's OWN ORIGINAL InitialReveal (not the fast wrapper -- exact
-- vanilla semantics including CanPlaceDeposit gating) over VIRTUAL 10x10 sectors at native
-- geometry and annotate its first winner. AFTER the stretch, collect every live 20x20 sector with
-- positive-area intersection against that winner's proportionally transformed box, pass those
-- equivalents through vanilla InitialReveal again, and scan only its first winner. InitialReveal
-- reads plain sector fields, so lightweight virtual source tables work without constructing a
-- second exploration grid.
-- ---------------------------------------------------------------------------------------
-- Native-source start annotations are transient generation data. Keying them by destination map
-- prevents a deferred underground map or a second map slot from consuming the surface selection.
local pending_vanilla_start_by_map = setmetatable({}, { __mode = "k" })

-- Build the virtual vanilla sector list and run vanilla's InitialReveal over it.
-- Returns { winners = { {x0,y0,x1,y1,id}, ... } } or nil + reason.
local function VanillaStartPick(city, map)
	local State = SuperBigMap.State or {}
	local box_fn = Global("box")
	local initial_reveal = State.original_initial_reveal or Global("InitialReveal")
	local ratio_fn = Global("BuildableGridRatio")
	local unb_fn = Global("buildUnbuildableZ")
	local is_kind_classes = Global("IsKindOfClasses")
	local const_tbl = Global("const")
	if type(box_fn) ~= "function" or type(initial_reveal) ~= "function"
		or type(ratio_fn) ~= "function" or type(unb_fn) ~= "function"
		or type(is_kind_classes) ~= "function" or type(map.MapForEach) ~= "function" then
		return nil, "api unavailable"
	end
	if type(city.CreateMapRand) ~= "function" then
		return nil, "CreateMapRand unavailable"
	end
	local mapdata = map.mapdata
	local hts = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number")
		and const_tbl.HeightTileSize or 100
	local src_w = map.SuperBigMapSourceWidth
	if type(src_w) ~= "number" or src_w <= 0 then
		local swt = map.SuperBigMapSourceWidthTiles or map.SuperBigMapGeneratorWidthTiles
		src_w = (type(swt) == "number" and swt > 0) and swt * hts or nil
	end
	if not src_w and type(mapdata) == "table" and type(mapdata.Width) == "number" then
		-- Vanilla (non-expanded) map: analysis mode uses the real map width.
		src_w = mapdata.Width * hts
	end
	if not src_w then return nil, "source width unknown" end
	-- VANILLA geometry: 10x10 tiles of (source_width - 2*border)/10 starting at border. The
	-- expansion zeroed mapdata.PassBorder; the vanilla value is preserved in
	-- SuperBigMapOriginalPassBorder (on vanilla maps PassBorder itself is intact).
	local border = (type(mapdata) == "table" and type(mapdata.SuperBigMapOriginalPassBorder) == "number")
		and mapdata.SuperBigMapOriginalPassBorder
		or (type(mapdata) == "table" and type(mapdata.PassBorder) == "number") and mapdata.PassBorder
		or 0
	local VN = 10 -- vanilla const.SectorCount (vanilla CreateSector's naming hardcodes 10)
	local tile = math.floor((src_w - 2 * border) / VN)
	if tile <= 0 then return nil, "bad tile size" end
	local ok_u, unbuildable = pcall(unb_fn)
	if not ok_u then return nil, "unbuildable z unavailable" end
	local buildable = map.buildable
	local heat_grid = map.heat_grid
	local orient = (type(mapdata) == "table" and mapdata.OverviewOrientation) or 0
	local max_heat = (type(const_tbl) == "table" and type(const_tbl.MaxHeat) == "number")
		and const_tbl.MaxHeat or 100
	-- Vanilla CreateSector naming (its formula hardcodes the 10x10 layout).
	local function vname(row, col)
		if orient == 90 then
			return string.char(string.byte("A") + 10 - row) .. (10 - col)
		elseif orient == 180 then
			return string.char(string.byte("A") + col - 1) .. (10 - row)
		elseif orient == 270 then
			return string.char(string.byte("A") + row - 1) .. (col - 1)
		end
		return string.char(string.byte("A") + 10 - col) .. (row - 1)
	end
	local eligible = {}
	local virtual_grid = {}
	for col = 1, VN do
		virtual_grid[col] = {}
		local x = border + (col - 1) * tile
		for row = 1, VN do
			local y = border + (row - 1) * tile
			local area = box_fn(x, y, x + tile, y + tile)
			local sec = {
				id = vname(row, col), area = area, row = row, col = col,
				markers = { surface = {} },
				play_ratio = 0, avg_heat = max_heat,
			}
			virtual_grid[col][row] = sec
			if buildable and buildable.z_grid then
				local ok_r, r = pcall(ratio_fn, buildable.z_grid, unbuildable, 100, area)
				if ok_r and type(r) == "number" then sec.play_ratio = r end
			end
			if heat_grid and type(heat_grid.GetAverageHeatIn) == "function" then
				local ok_h, hv = pcall(heat_grid.GetAverageHeatIn, heat_grid, area)
				if ok_h and type(hv) == "number" then sec.avg_heat = hv end
			end
			local has_surface = false
			pcall(map.MapForEach, map, area, "DepositMarker", function(m)
				local ok_k, is_surf = pcall(is_kind_classes, m, "TerrainDepositMarker", "SurfaceDepositMarker")
				if ok_k and is_surf then
					sec.markers.surface[#sec.markers.surface + 1] = m
					has_surface = true
				end
			end)
			-- Vanilla eligibility: has a surface/terrain marker AND not on the outer ring.
			if has_surface and row > 1 and row < VN and col > 1 and col < VN then
				eligible[#eligible + 1] = sec
				eligible[sec] = true
			end
		end
	end
	if #eligible == 0 then return nil, "no eligible virtual sectors" end

	-- CanPlaceDeposit requires the owning city's vanilla exploration geometry even though the
	-- temporary source never reaches InitSectors/InitMapArea. Install the exact transient 10x10
	-- view for vanilla InitialReveal, then restore the city and global count.
	local saved_map_area = city.MapArea
	local saved_map_sectors = city.MapSectors
	local saved_sector_count = type(const_tbl) == "table" and const_tbl.SectorCount or nil
	city.MapArea = box_fn(border, border, border + VN * tile, border + VN * tile)
	city.MapSectors = virtual_grid
	if type(const_tbl) == "table" then const_tbl.SectorCount = VN end

	-- Same seeded stream vanilla's InitialExplore would create.
	local ok_rand, _, trand = pcall(city.CreateMapRand, city, "Exploration")
	local ok_pick, revealed
	if ok_rand and type(trand) == "function" then
		ok_pick, revealed = pcall(initial_reveal, eligible, trand)
	end
	city.MapArea = saved_map_area
	city.MapSectors = saved_map_sectors
	if type(const_tbl) == "table" then const_tbl.SectorCount = saved_sector_count or VN end
	if not (ok_rand and type(trand) == "function") then return nil, "trand unavailable" end
	if not (ok_pick and type(revealed) == "table" and #revealed > 0) then
		return nil, "InitialReveal failed: " .. tostring(revealed)
	end
	-- Vanilla can return a second, nearest-concrete sector in its fallback branch, and it SCANS
	-- that sector, so its content spawns. Capture every winner: the first stays the transform
	-- anchor, the second drives the auxiliary reveal (its absence measured as b2-04's missing
	-- TerrainDepositConcrete).
	local winners = {}
	for _, sec in ipairs(revealed) do
		local mn, mx = sec.area:min(), sec.area:max()
		local x0, y0 = mn:xy()
		local x1, y1 = mx:xy()
		winners[#winners + 1] = { x0 = x0, y0 = y0, x1 = x1, y1 = y1, id = sec.id }
	end
	return { winners = winners }
end

local function CaptureVanillaStartSelection(map)
	-- A temporary generation backing may not own a fully initialized City yet. CreateMapRand is
	-- delegated to UIColony, so the current destination city is an equivalent deterministic owner.
	local city = map and map.City or Global("MainCity")
	if not city then return nil, "native source city unavailable" end
	local ok, selection, reason = pcall(VanillaStartPick, city, map)
	if not (ok and type(selection) == "table" and type(selection.winners) == "table"
		and #selection.winners >= 1) then
		return nil, tostring(ok and reason or selection)
	end
	return selection
end

local function StageVanillaStartSelection(map, selection, reason)
	if not map or type(selection) ~= "table" or type(selection.winners) ~= "table"
		or #selection.winners < 1 then return false, "invalid native start annotation" end
	pending_vanilla_start_by_map[map] = selection
	local winner = selection.winners[1]
	map.SuperBigMapVanillaStartSourceSector = winner.id
	map.SuperBigMapVanillaStartSourceX0 = winner.x0
	map.SuperBigMapVanillaStartSourceY0 = winner.y0
	map.SuperBigMapVanillaStartSourceX1 = winner.x1
	map.SuperBigMapVanillaStartSourceY1 = winner.y1
	-- Vanilla's InitialReveal fallback also reveals the nearest concrete sector (revealed[2],
	-- Exploration.lua:971-976). Its content spawns in vanilla, so it must spawn here too.
	local second = selection.winners[2]
	map.SuperBigMapVanillaStartSource2Sector = second and second.id or nil
	map.SuperBigMapVanillaStartSource2X0 = second and second.x0 or nil
	map.SuperBigMapVanillaStartSource2Y0 = second and second.y0 or nil
	map.SuperBigMapVanillaStartSource2X1 = second and second.x1 or nil
	map.SuperBigMapVanillaStartSource2Y1 = second and second.y1 or nil
	return true
end

local function HasPendingVanillaStartSelection(map)
	return map ~= nil and pending_vanilla_start_by_map[map] ~= nil
end

local function ClearPendingVanillaStartSelection(map, reason)
	if map then pending_vanilla_start_by_map[map] = nil end
end

-- Wrap Exploration:InitialExplore: on expanded surface maps, skip vanilla's own 20x20 reveal
-- entirely and preserve the annotation already captured from the native source. The compatibility
-- path can still reconstruct and stage a source pick if temporary backing is not in use.
local function PatchInitialExplore()
	if (SuperBigMap.Config or {}).STRETCH_VANILLA_START_SECTOR ~= true then return false end
	local State = SuperBigMap.State
	local cls = ClassTable("Exploration")
	if type(cls) ~= "table" or type(cls.InitialExplore) ~= "function" then
		cls = ClassTable("City")
	end
	if type(cls) ~= "table" or type(cls.InitialExplore) ~= "function" then
		return false
	end
	if cls.InitialExplore == State.initial_explore_wrapper then return true end
	if type(State.original_initial_explore) ~= "function" then
		State.original_initial_explore = cls.InitialExplore
	end
	local wrapper = function(self, eligible_out, ...)
		local original = State.original_initial_explore
		local map
		pcall(function() map = self:GetMap() end)
		local desired = map and map.SuperBigMapDesiredWidthTiles
		local gen_t = map and map.SuperBigMapGeneratorWidthTiles
		local expanded = type(desired) == "number" and type(gen_t) == "number" and desired > gen_t
		local env = map and map.mapdata and map.mapdata.Environment
		if not (expanded and env == "Surface"
			and (SuperBigMap.Config or {}).STRETCH_VANILLA_START_SECTOR == true) then
			-- Exact vanilla path with no reconstruction or extra random stream.
			return original(self, eligible_out, ...)
		end
		-- The exact winner was captured while the temporary native source and its markers still
		-- existed. At this later destination InitSectors boundary those markers are deliberately
		-- staged as value records, so recomputing from the live destination would see no resources.
		if HasPendingVanillaStartSelection(map) then
			return
		end
		local ok_pick, pick, reason = pcall(VanillaStartPick, self, map)
		if not (ok_pick and pick) then
			return original(self, eligible_out, ...)
		end
		-- Compatibility fallback for an expanded path without a temporary source. Defer this
		-- reconstructed native selection exactly as the source-capture path does.
		StageVanillaStartSelection(map, pick, "InitialExplore compatibility fallback")
	end
	cls.InitialExplore = wrapper
	State.initial_explore_wrapper = wrapper
	return true
end

-- Post-stretch reveal: transform the annotated vanilla winner box and collect every live expanded
-- sector with positive-area overlap. Those sectors are the positional equivalents of the stretched
-- vanilla footprint. Run vanilla's own InitialReveal over that complete candidate set so its normal
-- metals/concrete, buildability, heat, and seeded-random rules choose the single initial winner.
-- Only that first winner is scanned; then replicate InitialExplore's tail (commander bonus deposit
-- plus forced overview SelectSector).
local function RevealVanillaStartSectors(map)
	local State = SuperBigMap.State or {}
	map = map or Global("MainMap")
	local data = map and pending_vanilla_start_by_map[map]
	if not data then return 0 end
	pending_vanilla_start_by_map[map] = nil
	local city = map and map.City
	if not (city and Grid and type(Grid.ForEachSector) == "function") then
		return 0
	end
	local sw = map.SuperBigMapSourceWidthTiles or map.SuperBigMapGeneratorWidthTiles
	local full = map.SuperBigMapDesiredWidthTiles
	if not (type(sw) == "number" and type(full) == "number" and sw > 0 and full > sw) then
		return 0
	end
	local winner = data.winners and data.winners[1]
	if not winner then error("native source start annotation has no first winner") end
	local source_w = tonumber(map.SuperBigMapSourceWidthTiles)
		or tonumber(map.SuperBigMapGeneratorWidthTiles) or sw
	local source_h = tonumber(map.SuperBigMapSourceHeightTiles)
		or tonumber(map.SuperBigMapGeneratorHeightTiles) or source_w
	local final_w = tonumber(map.SuperBigMapDesiredWidthTiles) or full
	local final_h = tonumber(map.SuperBigMapDesiredHeightTiles) or final_w
	local origin_x = tonumber(map.SuperBigMapSourceX) or 0
	local origin_y = tonumber(map.SuperBigMapSourceY) or 0
	-- The game preserves integer division when both operands are integers.  A plain
	-- 8192 / 6144 therefore becomes 1 and leaves the reveal box at its unscaled
	-- source coordinate.  Terrain/object stretching deliberately adds 0.0 before
	-- division; use the identical floating proportional transform here.
	local scale_x = (final_w + 0.0) / source_w
	local scale_y = (final_h + 0.0) / source_h
	if (final_w > source_w and scale_x <= 1.0)
		or (final_h > source_h and scale_y <= 1.0) then
		error(string.format("invalid stretched start-sector scale: source=%sx%s final=%sx%s scale=%s,%s",
			tostring(source_w), tostring(source_h), tostring(final_w), tostring(final_h),
			tostring(scale_x), tostring(scale_y)))
	end
	local x0 = math.floor(origin_x + (winner.x0 - origin_x) * scale_x + 0.5)
	local y0 = math.floor(origin_y + (winner.y0 - origin_y) * scale_y + 0.5)
	local x1 = math.floor(origin_x + (winner.x1 - origin_x) * scale_x + 0.5)
	local y1 = math.floor(origin_y + (winner.y1 - origin_y) * scale_y + 0.5)
	local box_fn = Global("box")
	local transformed_box = type(box_fn) == "function" and box_fn(x0, y0, x1, y1) or nil
	if transformed_box and type(city.UpdateBuildableRatio) == "function" then
		pcall(city.UpdateBuildableRatio, city, transformed_box)
	end

	local overlaps = {}
	local heat_grid = map.heat_grid
	Grid.ForEachSector(city, function(sector)
		local a = sector and sector.area
		if not a then return end
		local mn, mx = a:min(), a:max()
		local ax0, ay0 = mn:xy()
		local ax1, ay1 = mx:xy()
		local ix = math.min(ax1, x1) - math.max(ax0, x0)
		local iy = math.min(ay1, y1) - math.max(ay0, y0)
		if ix <= 0 or iy <= 0 then return end
		if heat_grid and type(heat_grid.GetAverageHeatIn) == "function" then
			local ok_heat, avg_heat = pcall(heat_grid.GetAverageHeatIn, heat_grid, a)
			if ok_heat and type(avg_heat) == "number" then sector.avg_heat = avg_heat end
		end
		local overlap = ix * iy
		overlaps[#overlaps + 1] = { sector = sector, overlap = overlap }
	end)
	if #overlaps == 0 then
		error("no expanded sector intersects the transformed vanilla start sector")
	end

	-- A stretched 10x10 source sector can cover several 20x20 destination sectors. Every positive
	-- intersection belongs to that transformed footprint, so let the exact vanilla selection logic
	-- decide between all of them instead of imposing a second geometric policy.
	local candidates = {}
	for i = 1, #overlaps do
		local sector = overlaps[i].sector
		candidates[#candidates + 1] = sector
		candidates[sector] = true
	end
	if #candidates == 0 then
		error("no positional equivalent for transformed vanilla start sector")
	end

	local initial_reveal = State.original_initial_reveal
	if type(initial_reveal) ~= "function" then
		error("vanilla InitialReveal unavailable for transformed start candidates")
	end
	local ok_rand, _, trand = pcall(city.CreateMapRand, city, "Exploration")
	if not (ok_rand and type(trand) == "function") then
		error("vanilla Exploration random stream unavailable for transformed start candidates")
	end
	local ok_pick, revealed, spawn_positions = pcall(initial_reveal, candidates, trand)
	if not (ok_pick and type(revealed) == "table" and revealed[1]
		and candidates[revealed[1]] == true) then
		error("vanilla InitialReveal failed for transformed start candidates: " .. tostring(revealed))
	end
	local selected = revealed[1]
	-- Vanilla's fallback branch returns an auxiliary nearest-concrete sector (revealed[2]) and
	-- SCANS it, so its content spawns. The anchor (camera, InitialSector) stays vanilla's first
	-- winner, but the scan set must be the whole revealed set or the auxiliary sector's deposits
	-- are missing from the expanded map (measured: b2-04's TerrainDepositConcrete).
	local reveal_targets = { selected }
	local winner2 = data.winners and data.winners[2]
	if winner2 then
		local w2cx = math.floor(origin_x + ((winner2.x0 + winner2.x1) * 0.5 - origin_x) * scale_x + 0.5)
		local w2cy = math.floor(origin_y + ((winner2.y0 + winner2.y1) * 0.5 - origin_y) * scale_y + 0.5)
		local w2_sector
		Grid.ForEachSector(city, function(sector)
			local a = sector and sector.area
			if not a or w2_sector then return end
			local mn, mx = a:min(), a:max()
			local ax0, ay0 = mn:xy()
			local ax1, ay1 = mx:xy()
			if w2cx >= ax0 and w2cx < ax1 and w2cy >= ay0 and w2cy < ay1 then w2_sector = sector end
		end)
		if not w2_sector then
			error("no expanded sector contains the transformed auxiliary concrete sector center")
		end
		if w2_sector ~= selected then
			reveal_targets[#reveal_targets + 1] = w2_sector
			-- InitialReveal precomputed CanPlaceDeposit spawn positions only for the first
			-- winner's candidate sectors; replicate its inner loop for the auxiliary sector
			-- (Exploration.lua:900-906) so its surface markers spawn exactly the same way.
			for j = 1, #(w2_sector.markers and w2_sector.markers.surface or "") do
				local marker = w2_sector.markers.surface[j]
				if marker and not spawn_positions[marker]
					and type(marker.CanPlaceDeposit) == "function" then
					local ok_sp, sp = pcall(marker.CanPlaceDeposit, marker)
					if ok_sp and sp then spawn_positions[marker] = sp end
				end
			end
		end
	end
	-- This is still initial generation: remove any accidental destination reveal produced while the
	-- class wrapper was being reclaimed, then persist only vanilla's selected initial winner.
	local done_object = Global("DoneObject")
	local is_valid = Global("IsValid")
	if type(map.MapForEach) == "function" and type(done_object) == "function" then
		local persisted_reveals = {}
		pcall(map.MapForEach, map, "map", "RevealedMapSector", function(obj)
			persisted_reveals[#persisted_reveals + 1] = obj
		end)
		for i = 1, #persisted_reveals do
			local obj = persisted_reveals[i]
			if type(is_valid) ~= "function" or is_valid(obj) then pcall(done_object, obj) end
		end
	end
	Grid.ForEachSector(city, function(sector)
		sector.status = "unexplored"
		sector.revealed_obj = nil
		sector.revealed_surf = nil
		sector.revealed_deep = nil
		if type(sector.UpdateDecal) == "function" then pcall(sector.UpdateDecal, sector) end
	end)
	city.InitialSector = selected
	local blocked_targets = {}
	for i = 1, #reveal_targets do
		local target = reveal_targets[i]
		local scan_ok, scan_error = pcall(target.Scan, target, "scanned", nil, spawn_positions)
		if not scan_ok then
			error(string.format("stretched-equivalent start sector %s scan failed: %s",
				tostring(target.id), tostring(scan_error)))
		end
		if target.status == "unexplored" then
			blocked_targets[#blocked_targets + 1] = tostring(target.id)
		end
	end

	local scanned_total = 0
	Grid.ForEachSector(city, function(sector)
		if sector.status and sector.status ~= "unexplored" then scanned_total = scanned_total + 1 end
	end)
	if scanned_total ~= #reveal_targets or selected.status == "unexplored" then
		error(string.format("stretched-equivalent reveal verification failed: expected=%s scanned=%s selected_status=%s blocked=%s",
			tostring(#reveal_targets), tostring(scanned_total), tostring(selected.status),
			table.concat(blocked_targets, "+")))
	end

	-- A destination sector keeps its PHYSICAL size while the map grows, so vanilla's winner sector
	-- stretches to 4/3 of one destination sector and the single scan above covers only part of the
	-- footprint. Vanilla placed the deposit of EVERY surface marker in its winner sector, so the
	-- markers that fall in the footprint's remainder must be placed too, or the expanded map is
	-- short exactly those deposits (measured at 45S82E: 2 SurfaceDepositMetals + 1
	-- TerrainDepositConcrete, artifacts/start_sector_footprint_verdict.md). The footprint box is the
	-- exact stretched image of vanilla's sector, so placing over it - and never over the whole
	-- overlapping sectors, which cover far more ground - reproduces vanilla's placed set exactly.
	-- Vanilla's own RevealDeposits does the work, with the spawn positions InitialReveal already
	-- computed for every candidate sector's markers.
	-- The candidate markers are read from the LIVE map over the footprint box, exactly as vanilla's
	-- InitSector builds a sector's marker lists (GetDepthClass == "surface"), instead of trusting the
	-- destination sectors' bookkeeping: this reveal runs mid-stretch, right after the markers were
	-- recreated at their stretched positions, so a sector list built earlier can name objects that no
	-- longer exist. The stamps are read back by the parity dump.
	if (SuperBigMap.Config or {}).START_SECTOR_FOOTPRINT_DEPOSITS == true then
		local reveal_deposits = Global("RevealDeposits")
		if type(reveal_deposits) ~= "function" then
			error("vanilla RevealDeposits unavailable for the stretched start footprint")
		end
		if not transformed_box then
			error("stretched start footprint box unavailable")
		end
		-- MEMBERSHIP IS DECIDED IN SOURCE SPACE. Vanilla spawned exactly the markers of its
		-- winner sector; every native marker carries its vanilla position as an immutable stamp,
		-- and the winner rect is staged in native coordinates. Testing the STRETCHED position
		-- against the STRETCHED box re-derives that decision through two roundings (the affine
		-- image and the hex snap) and measurably flips markers near the boundary in both
		-- directions (b2-04 lost its TerrainDepositConcrete, b2-10 gained a SubsurfaceDepositWater).
		-- The half-open test matches vanilla's sector membership.
		local source_rects = {}
		for wi = 1, #(data.winners or "") do
			local w = data.winners[wi]
			if type(w) == "table" and w.x0 and w.y0 and w.x1 and w.y1 then
				source_rects[#source_rects + 1] = w
			end
		end
		if #source_rects == 0 then
			error("vanilla start winner rects unavailable in source coordinates")
		end
		local function source_membership(marker)
			local mx = tonumber(rawget(marker, "SuperBigMapNativeSourceX"))
			local my = tonumber(rawget(marker, "SuperBigMapNativeSourceY"))
			if not mx or not my then return nil end
			for ri = 1, #source_rects do
				local r = source_rects[ri]
				if mx >= r.x0 and mx < r.x1 and my >= r.y0 and my < r.y1 then return true end
			end
			return false
		end

		-- (1) The destination start sector's own vanilla Scan ran over a physically
		-- sector-sized area: a hex-snapped marker can sit inside it while its source was
		-- OUTSIDE vanilla's winner. Vanilla never spawned those; despawn them before the
		-- remainder pass so the final spawned set is exactly vanilla's.
		local despawned = 0
		local despawned_markers = {}
		do
			-- GLOBAL sweep: mechanisms other than the sector scan can also place a deposit
			-- (measured at b2-10: a marker just outside the winner's corner arrived placed
			-- while the scan-list walk saw nothing), so the source-space rule is enforced on
			-- the whole map, not on the reveal bookkeeping.
			local sweep_done = Global("DoneObject")
			local sweep_valid = Global("IsValid")
			pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
				if not rawget(marker, "is_placed") then return end
				if source_membership(marker) ~= false then return end
				local obj = rawget(marker, "placed_obj")
				if obj and type(sweep_done) == "function"
					and (type(sweep_valid) ~= "function" or sweep_valid(obj)) then
					pcall(sweep_done, obj)
				end
				marker.placed_obj = false
				marker.is_placed = false
				despawned_markers[marker] = true
				despawned = despawned + 1
			end)
			-- Purge every sector's revealed bookkeeping of the despawned markers; a stale
			-- entry re-materializes the deposit on save/load.
			Grid.ForEachSector(city, function(sector)
				local lists = { sector.revealed_surf, sector.revealed_deep }
				for li = 1, 2 do
					local lst = lists[li]
					if type(lst) == "table" then
						for i = #lst, 1, -1 do
							if despawned_markers[lst[i]] then table.remove(lst, i) end
						end
					end
				end
			end)
		end

		-- (2) Spawn the footprint remainder: every not-yet-placed native marker whose SOURCE
		-- lies in the winner rect, split by vanilla's own depth classes exactly as
		-- MapSector:Scan does on a fresh sector - block first, then surface (with the spawn
		-- positions InitialReveal computed), then subsurface. The old pass spawned only
		-- depth "surface", so vanilla's subsurface anomalies (SubsurfaceAnomalyMarker is a
		-- DepositMarker of depth "subsurface") never appeared (b2-07, b2-10).
		-- The enumeration box is padded: the hex snap can move a source-inside marker's
		-- final position slightly outside the exact image of the winner rect.
		local pad = 4000
		local box_fn2 = Global("box")
		local search_box = type(box_fn2) == "function"
			and box_fn2(x0 - pad, y0 - pad, x1 + pad, y1 + pad) or transformed_box
		local seen, pending = 0, { block = {}, surface = {}, subsurface = {} }
		pcall(map.MapForEach, map, search_box, "DepositMarker", function(marker)
			seen = seen + 1
			if marker.is_placed or type(marker.GetDepthClass) ~= "function" then return end
			if source_membership(marker) ~= true then return end
			local ok_depth, depth = pcall(marker.GetDepthClass, marker)
			if not ok_depth or not pending[depth] then return end
			local ok_pos, mx, my = pcall(marker.GetVisualPosXYZ, marker)
			if not (ok_pos and type(mx) == "number" and type(my) == "number") then return end
			pending[depth][#pending[depth] + 1] = { marker = marker, x = mx, y = my }
		end)
		-- Engine enumeration order is not specified; a fixed order keeps the placement sequence
		-- (and therefore any obstruction interaction between two of them) reproducible.
		local placed_extra, pending_total = 0, 0
		for _, depth in ipairs({ "block", "surface", "subsurface" }) do
			local group = pending[depth]
			table.sort(group, function(a, b)
				if a.x ~= b.x then return a.x < b.x end
				if a.y ~= b.y then return a.y < b.y end
				return tostring(a.marker) < tostring(b.marker)
			end)
			local list = {}
			for i = 1, #group do list[i] = group[i].marker end
			pending_total = pending_total + #list
			if #list > 0 then
				local ok_reveal, count
				if depth == "surface" then
					ok_reveal, count = pcall(reveal_deposits, list, nil, nil, nil, spawn_positions)
				else
					ok_reveal, count = pcall(reveal_deposits, list, nil, nil, nil)
				end
				if not ok_reveal then
					error("stretched start footprint " .. depth .. " placement failed: " .. tostring(count))
				end
				placed_extra = placed_extra + (tonumber(count) or 0)
			end
		end
		-- Vanilla's rare-anomaly "Revealed" FX (a persistent ParSystem carrier) fires from
		-- SetRevealed(true) -> OnRevealedValueChanged -> OnReveal during PlaceDeposit. A
		-- footprint-remainder spawn runs mid-stretch, where the FX pipeline was measured not to
		-- produce the carrier (b2-07), so replay it end-of-tick, the same deferral vanilla uses
		-- for OnDepositsSpawned.
		for i = 1, #pending.subsurface do
			local marker = pending.subsurface[i].marker
			local obj = rawget(marker, "placed_obj")
			if obj and rawget(obj, "rare") then
				local play_fx = Global("PlayFX")
				local delayed = Global("DelayedCall")
				if type(play_fx) == "function" and type(delayed) == "function" then
					pcall(delayed, 0, play_fx, "Revealed", "start", obj)
				elseif type(play_fx) == "function" then
					pcall(play_fx, "Revealed", "start", obj)
				end
			end
		end
		if placed_extra > 0 then
			-- Vanilla's own tail for a reveal that spawned deposits (MapSector:Scan).
			pcall(function()
				local delayed = Global("DelayedCall")
				local on_spawned = Global("OnDepositsSpawned")
				if type(delayed) == "function" and type(on_spawned) == "function" then
					delayed(0, on_spawned, city)
				end
			end)
		end
		-- The scan gate (DepositRules.EnforceScanGateAfterStretch, step 5) despawns deposits that
		-- sit in unscanned sectors. Part of vanilla's own start footprint necessarily does, so the
		-- box travels with the map and that pass exempts it.
		map.SuperBigMapStartFootprintX0 = x0
		map.SuperBigMapStartFootprintY0 = y0
		map.SuperBigMapStartFootprintX1 = x1
		map.SuperBigMapStartFootprintY1 = y1
		map.SuperBigMapStartFootprintBox = string.format("%s,%s,%s,%s", tostring(x0), tostring(y0),
			tostring(x1), tostring(y1))
		map.SuperBigMapStartFootprintSectors = #overlaps
		map.SuperBigMapStartFootprintMarkers = seen
		map.SuperBigMapStartFootprintPending = pending_total
		map.SuperBigMapStartFootprintDeposits = placed_extra
		map.SuperBigMapStartFootprintDespawned = despawned
		if winner2 then
			map.SuperBigMapStartFootprint2X0 = math.floor(origin_x + (winner2.x0 - origin_x) * scale_x + 0.5)
			map.SuperBigMapStartFootprint2Y0 = math.floor(origin_y + (winner2.y0 - origin_y) * scale_y + 0.5)
			map.SuperBigMapStartFootprint2X1 = math.floor(origin_x + (winner2.x1 - origin_x) * scale_x + 0.5)
			map.SuperBigMapStartFootprint2Y1 = math.floor(origin_y + (winner2.y1 - origin_y) * scale_y + 0.5)
		end
	end

	if selected then
		-- Vanilla tail: overview exit_to + forced SelectSector on the deterministic anchor.
		pcall(function()
			local igi = Global("GetInGameInterface")()
			if igi and igi:IsInMode("overview") then
				if igi.mode_dialog then
					igi.mode_dialog.exit_to = city.InitialSector.area:Center()
				end
				local get_mode_dlg = Global("GetInGameInterfaceModeDlg")
				local dlg = type(get_mode_dlg) == "function" and get_mode_dlg() or nil
				if dlg and type(dlg.SelectSector) == "function" then
					dlg:SelectSector(selected, nil, "forced")
				end
			end
		end)
		-- Vanilla tail: commander-profile bonus subsurface deposit near the start.
		pcall(function()
			local get_profile = Global("GetCommanderProfile")
			local profile = type(get_profile) == "function" and get_profile().id or nil
			local deposit, resource
			if profile == "hydroengineer" then
				deposit, resource = "SubsurfaceDepositWater", "Water"
			elseif profile == "astrogeologist" then
				deposit, resource = "SubsurfaceDepositPreciousMetals", "PreciousMetals"
			end
			if deposit and not map:MapHasAny("map", deposit) then
				local marker = map:MapFindNearest(city.InitialSector.area:Center(), "map",
					"SubsurfaceDepositMarker", function(o)
						return not o.is_placed and o.resource == resource and o.depth_layer <= 1
					end)
				if marker then
					marker.revealed = true
					marker:PlaceDeposit()
				end
			end
		end)
	end
	return scanned_total
end

local function InstallSectorPatch()
	local State = SuperBigMap.State


	local highlight = SuperBigMap.SectorHighlight
	if highlight then
		highlight.Install()
	end

	if not cfg_bool("ENABLE_EXPANDED_SECTORS", true) then
		return false
	end

	if State.sector_patch_version == SECTOR_PATCH_VERSION then
		return true
	end

	if not InstallBasicSectorPatch() then
		return false
	end

	local exploration_class = ClassTable("Exploration")
	local map_sector_class = ClassTable("MapSector")

	if type(Global("InitSector")) ~= "function" then
		return false
	end

	if not exploration_class then
		return false
	end

	if not map_sector_class then
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
			-- Vanilla InitSectors reads the process-global const.SectorCount.  An expanded
			-- map previously left that value at 20, causing the next vanilla map to build
			-- a 20x20 grid.  Restore the vanilla input immediately before the original call.
			if type(Grid.NormalizeVanillaSectorCount) == "function" then
				Grid.NormalizeVanillaSectorCount("Exploration.InitSectors vanilla path")
			end
			return original_init_sectors(self, map, eligible_sectors_with_surface_deposits_out)
		end

		DestroyExistingSectorVisuals(self, map, "InitSectors")
		DestroyMapSectorObjects(map)
		Grid.ConfigureGlobalSectorCount(map, "InitSectors")
		local layout = Grid.ResolveSectorLayout(map)
		local orient = map.mapdata.OverviewOrientation
		local unbuildable_z = buildUnbuildableZ()
		return SetSectorCountForInit(layout.count, function()
			self.ExplorationQueue = {}
			self.MapSectors = {}
			self.SuperBigMapSectorCount = layout.count
			self.SuperBigMapSectorTargetSize = layout.target

			for col = 1, layout.count_x do
				local sectors_col = {}
				self.MapSectors[col] = sectors_col
				for row = 1, layout.count_y do
					local sector = BuildSector(map, self, row, col, layout, orient, unbuildable_z, eligible_sectors_with_surface_deposits_out)
					sectors_col[row] = sector
					self.MapSectors[sector] = true
				end
			end

		end)
	end

	-- Remember OUR custom InitSectors closure so EnsureSectorsBuilt can detect when the
	-- class method has been clobbered by another system (the random-map generator re-runs
	-- vanilla InitSectors around MapGenerated, which rebuilds the grid at the oversized
	-- vanilla size) and reclaim/call ours directly to restore the vanilla-sized layout.
	State.superbigmap_init_sectors = exploration_class.InitSectors

	exploration_class.InitMapArea = function(self)
		if not Grid.UseCustomSectorsForMap(self:GetMap()) then
			return original_init_map_area(self)
		end

		local last_col = #self.MapSectors
		local last_row = last_col > 0 and #self.MapSectors[last_col] or 0
		assert(last_col > 0 and last_row > 0)

		-- With FullMapPlayable on, the engine's playable MapArea covers the whole
		-- terrain. This matches sbm_map_bounds for PassBorder and PlayArea.
		local map = self:GetMap()
		local bounds = SuperBigMap.MapBounds
		local full_map = bounds and type(bounds.FullMapPlayableEnabled) == "function" and bounds.FullMapPlayableEnabled()
		local map_width = map and map.Width
		local map_height = map and map.Height
		if full_map and type(map_width) == "number" and type(map_height) == "number" and map_width > 0 and map_height > 0 then
			self.MapArea = box(0, 0, map_width, map_height)
			return
		end

		self.MapArea = box(
			self.MapSectors[1][1].area:min(),
			self.MapSectors[last_col][last_row].area:max())
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
	end

	-- The following are global / class functions the engine calls by name. They are
	-- overridden in place; the pre-existing value (a function in vanilla, or false if
	-- absent) is saved once so RestoreVanillaBehavior can put it back.
	if State.original_unexplored_sectors_exist == nil then
		State.original_unexplored_sectors_exist = Global("UnexploredSectorsExist") or false
	end
	function UnexploredSectorsExist(city)
		if not UsesCustomCitySectors(city) then
			local original = State.original_unexplored_sectors_exist
			if type(original) == "function" then return original(city) end
		end
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
		if not UsesCustomCitySectors(self) then
			local original = State.original_exploration_gather_discovered_deposits
			if type(original) == "function" then return original(self) end
		end
		-- InitDepositInfoTable and ProcessDepositMarkers were globals in older
		-- Surviving Mars builds, but in Surviving Mars Relaunched they are
		-- function-locals inside vanilla's GatherDiscoveredDeposits (the runtime
		-- asserts "Attempt to use an undefined global 'InitDepositInfoTable'"
		-- otherwise). Without those helpers we cannot reproduce the deposits
		-- table here, so delegate to the saved vanilla function: it iterates the
		-- sectors we already installed on this city via InitSectors, so the
		-- expanded grid is covered with no information loss.
		local init_fn = rawget(_G, "InitDepositInfoTable")
		local process_fn = rawget(_G, "ProcessDepositMarkers")
		if type(init_fn) ~= "function" or type(process_fn) ~= "function" then
			local fallback = State.original_exploration_gather_discovered_deposits
			if type(fallback) == "function" then
				return fallback(self)
			end
			return {}
		end

		local deposits = init_fn()
		Grid.ForEachSector(self, function(sector)
			process_fn(sector.markers.surface, deposits, 1)
			process_fn(sector.markers.subsurface, deposits, 2)
			process_fn(sector.markers.deep, deposits, 2)
		end)
		return deposits
	end

	if State.original_show_exploration_sectors == nil then
		State.original_show_exploration_sectors = Global("ShowExploration_Sectors") or false
	end
	function ShowExploration_Sectors(city, time)
		if not UsesCustomCitySectors(city) then
			local original = State.original_show_exploration_sectors
			if type(original) == "function" then return original(city, time) end
		end
		local visual_repairs = RepairSectorVisualGeometry(city)
		local orphan_decals, _, orphan_samples = PruneOrphanSectorDecals(city)
		AuditSectorGrid(city, "ShowExploration_Sectors", true)
		-- Underground MapSectors are data-only: keep them for hover names and buildable ratios,
		-- but never re-show their grid decals when overview mode opens.
		if UndergroundExplorationUiOn(city) then
			HideSectorVisuals(city, "ShowExploration_Sectors underground data-only")
			return
		end
		Grid.ForEachSector(city, function(sector)
			local decal = sector.decal
			if IsValid(decal) then
				decal:SetEnumFlags(const.efVisible)
			end
		end)
		AuditOverviewGridVisuals(city, "ShowExploration_Sectors", {
			repaired_sector_positions = tostring(visual_repairs.sector_positions),
			repaired_decal_positions = tostring(visual_repairs.decal_positions),
			repaired_decal_scales = tostring(visual_repairs.decal_scales),
			repaired_scan_positions = tostring(visual_repairs.scan_positions),
			pruned_orphan_decals = tostring(orphan_decals),
			pruned_orphan_samples = tostring(orphan_samples),
		})
	end

	if State.original_hide_exploration_sectors == nil then
		State.original_hide_exploration_sectors = Global("HideExploration_Sectors") or false
	end
	function HideExploration_Sectors(city, time)
		if not UsesCustomCitySectors(city) then
			local original = State.original_hide_exploration_sectors
			if type(original) == "function" then return original(city, time) end
		end
		HideSectorVisuals(city, "HideExploration_Sectors")
	end

	if State.original_update_scanned_sector_visuals == nil then
		State.original_update_scanned_sector_visuals = Global("UpdateScannedSectorVisuals") or false
	end
	function UpdateScannedSectorVisuals(status)
		local city = Global("MainCity")
		if not UsesCustomCitySectors(city) then
			local original = State.original_update_scanned_sector_visuals
			if type(original) == "function" then return original(status) end
		end
		if UndergroundExplorationUiOn(city) then
			HideSectorVisuals(city, "UpdateScannedSectorVisuals underground data-only")
			return
		end
		Grid.ForEachSector(city, function(sector)
			if not status or sector.status == status then
				sector:UpdateDecal()
			end
		end)
		local visual_repairs = RepairSectorVisualGeometry(city)
		local orphan_decals, _, orphan_samples = PruneOrphanSectorDecals(city)
		AuditOverviewGridVisuals(city, "UpdateScannedSectorVisuals", {
			status_filter = tostring(status),
			repaired_sector_positions = tostring(visual_repairs.sector_positions),
			repaired_decal_positions = tostring(visual_repairs.decal_positions),
			repaired_decal_scales = tostring(visual_repairs.decal_scales),
			repaired_scan_positions = tostring(visual_repairs.scan_positions),
			pruned_orphan_decals = tostring(orphan_decals),
			pruned_orphan_samples = tostring(orphan_samples),
		})
	end

	State.sector_patch_version = SECTOR_PATCH_VERSION
	return true
end

local function EnsureSectorPatch(map, reason)
	InstallSectorPatch()
	if Grid.UseCustomSectorsForMap(map) then
		Grid.ConfigureGlobalSectorCount(map, reason)
	elseif type(Grid.NormalizeVanillaSectorCount) == "function" then
		Grid.NormalizeVanillaSectorCount(tostring(reason or "EnsureSectorPatch") .. " non-custom map")
	end
end

-- Force-rebuild MapSectors when the live grid doesn't match the layout this mod
-- expects. Some maps (e.g. BlankBig_*) load through a path that doesn't call
-- Exploration:InitSectors at all -- the engine carries over a pre-built sector
-- grid -- so our patched InitSectors never fires and the user sees 10x10 huge
-- sectors instead of the expected ~vanilla-sized count. This fallback runs after
-- MapGenerated / PostNewMapLoaded: if map.City exists and its MapSectors count
-- (rows or cols) disagrees with our resolved layout count, we explicitly invoke
-- the patched InitSectors+InitMapArea so the grid is rebuilt to the expected
-- vanilla-sized count.
--
-- Safe on new games (the user has confirmed expanded terrain requires a new
-- game anyway; carrying-over state from a save isn't supported). The fallback
-- is skipped if the live count already matches the layout, so it never clobbers
-- correctly-initialised state.
local function EnsureSectorsBuilt(map, reason)
	if not Grid.UseCustomSectorsForMap(map) then
		return false, "not custom"
	end

	local city = map and map.City
	if not city then
		return false, "no city"
	end

	local exploration_class = ClassTable("Exploration")
	if not exploration_class or type(exploration_class.InitSectors) ~= "function" then
		return false, "no init_sectors"
	end

	local expected = Grid.ResolveSectorCount(map)
	if type(expected) ~= "number" or expected <= 0 then
		return false, "no expected"
	end

	local sectors = type(city.MapSectors) == "table" and city.MapSectors or false
	local cols, rows = LiveSectorGridDimensions(sectors)

	-- SIZE check (count alone is not enough). A 20x20 grid built early with the
	-- vanilla mapWidth/10 tile size passes the count test but is 2x oversized (the
	-- "10x10 big sectors" bug -- 20 oversized sectors spanning 2x the terrain).
	-- Compare the live sector[1][1] world size to the mod's intended step
	-- (mapWidth/count from ResolveSectorLayout) and rebuild if count OR size is off.
	local layout = Grid.ResolveSectorLayout(map)
	local expected_step = layout and layout.step_x
	local live_size = LiveSectorSize(city)
	local size_ok = (type(expected_step) ~= "number") or (type(live_size) ~= "number")
		or (math.abs(live_size - expected_step) <= 2)
	local live_layout = BuildLiveSectorLookupLayout(city)
	local covers_live_terrain = live_layout
		and type(map.Width) == "number" and type(map.Height) == "number"
		and math.abs(live_layout.width - map.Width) <= 2
		and math.abs(live_layout.height - map.Height) <= 2

	-- A complete, vanilla-sector-sized saved grid that covers the live terrain is already
	-- correct even if ResolveSectorCount briefly sees another map preset. Preserve its objects,
	-- scan states, queue, deposits, and decals; repair only the derived runtime state.
	if size_ok and ((cols == expected and rows == expected) or covers_live_terrain) then
		sector_lookup_layout_cache[city] = nil
		live_layout = BuildLiveSectorLookupLayout(city) or live_layout
		if live_layout then
			CacheLiveSectorLookupLayout(city, live_layout)
			city.SuperBigMapSectorCount = live_layout.count
			city.SuperBigMapSectorTargetSize = live_layout.step_x
			local box_fn = Global("box")
			if type(box_fn) == "function" then
				local ok_area, repaired_area = pcall(box_fn, live_layout.min_point, live_layout.max_point)
				if ok_area and repaired_area then
					city.MapArea = repaired_area
				end
			end
			Grid.ConfigureGlobalSectorCount(map,
				tostring(reason or "EnsureSectorsBuilt") .. " live grid", live_layout.count)
		end
		local visual_repairs = RepairSectorVisualGeometry(city)
		local orphan_decals, _, orphan_samples = PruneOrphanSectorDecals(city, map)
		local orphan_sectors, sector_objects = PruneOrphanMapSectors(city, map)
		local relabeled = RefreshSectorDisplayNames(map)
		AuditOverviewGridVisuals(city, "EnsureSectorsBuilt:matches", {
			lifecycle_reason = tostring(reason),
			repaired_sector_positions = tostring(visual_repairs.sector_positions),
			repaired_decal_positions = tostring(visual_repairs.decal_positions),
			repaired_decal_scales = tostring(visual_repairs.decal_scales),
			repaired_scan_positions = tostring(visual_repairs.scan_positions),
			pruned_orphan_decals = tostring(orphan_decals),
			pruned_orphan_samples = tostring(orphan_samples),
			pruned_orphan_map_sectors = tostring(orphan_sectors),
			map_sector_objects = tostring(sector_objects),
		})
		AuditSectorGrid(city, tostring(reason or "EnsureSectorsBuilt") .. ": matches", false)
		return true, relabeled > 0 and "matches; relabeled" or "matches"
	end

	-- The rebuild only produces the correct size if it runs through the mod's CUSTOM
	-- InitSectors (which uses layout.step_x). The random-map generator re-runs vanilla
	-- InitSectors around MapGenerated, CLOBBERING our closure on the class -- and since a
	-- foreign function is also "different from the saved original", a != original check
	-- wrongly reports the mod as installed and the rebuild reproduces the oversized
	-- vanilla grid (the intermittent oversized-sector / "cannot expand" on Big maps).
	-- Compare against OUR stored closure instead; if the class method was clobbered,
	-- reclaim it, and always rebuild by calling our closure DIRECTLY.
	local State = SuperBigMap.State or {}
	local custom_fn = State.superbigmap_init_sectors
	local custom_installed = type(custom_fn) == "function" and exploration_class.InitSectors == custom_fn
	if not custom_installed then
		pcall(InstallSectorPatch)
		exploration_class = ClassTable("Exploration") or exploration_class
		custom_fn = State.superbigmap_init_sectors
		-- InstallSectorPatch is version-guarded and may not re-assign if it believes the
		-- patch is current; force the class method back to OUR closure so this rebuild AND
		-- every later InitSectors call use the vanilla-sized layout.
		if type(custom_fn) == "function" and exploration_class.InitSectors ~= custom_fn then
			exploration_class.InitSectors = custom_fn
		end
		custom_installed = type(custom_fn) == "function" and exploration_class.InitSectors == custom_fn
	end


	-- Prefer our stored closure (independent of whatever is currently on the class).
	-- Random-map generation can also restore Exploration.InitialExplore after the initial mod
	-- install. Reclaim the deferral wrapper immediately before InitSectors invokes that method.
	PatchInitialExplore()
	local init_fn = (type(custom_fn) == "function") and custom_fn or exploration_class.InitSectors
	local ok, err = pcall(init_fn, city, map, {})
	if not ok then
		return false, err
	end

	-- InitMapArea reads MapSectors to compute the playable area; re-run it so the
	-- bounds and overview match the freshly-built grid.
	if type(exploration_class.InitMapArea) == "function" then
		pcall(exploration_class.InitMapArea, city)
	end
	sector_lookup_layout_cache[city] = nil
	local rebuilt_layout = BuildLiveSectorLookupLayout(city)
	if rebuilt_layout then
		CacheLiveSectorLookupLayout(city, rebuilt_layout)
		Grid.ConfigureGlobalSectorCount(map,
			tostring(reason or "EnsureSectorsBuilt") .. " rebuilt grid", rebuilt_layout.count)
	end
	local visual_repairs = RepairSectorVisualGeometry(city)
	local orphan_decals, _, orphan_samples = PruneOrphanSectorDecals(city, map)
	local orphan_sectors, sector_objects = PruneOrphanMapSectors(city, map)
	RefreshSectorDisplayNames(map)
	AuditOverviewGridVisuals(city, "EnsureSectorsBuilt:rebuilt", {
		lifecycle_reason = tostring(reason),
		repaired_sector_positions = tostring(visual_repairs.sector_positions),
		repaired_decal_positions = tostring(visual_repairs.decal_positions),
		repaired_decal_scales = tostring(visual_repairs.decal_scales),
		repaired_scan_positions = tostring(visual_repairs.scan_positions),
		pruned_orphan_decals = tostring(orphan_decals),
		pruned_orphan_samples = tostring(orphan_samples),
		pruned_orphan_map_sectors = tostring(orphan_sectors),
		map_sector_objects = tostring(sector_objects),
	})
	AuditSectorGrid(city, tostring(reason or "EnsureSectorsBuilt") .. ": rebuilt", true)

	return true, "rebuilt"
end

local function restore_global(name, saved)
	if type(saved) == "function" then
		rawset(_G, name, saved)
	elseif saved == false then
		rawset(_G, name, nil)
	end
end

-- Recreate any missing per-sector overview decals (SectorUnexplored/SectorScanned).
-- For any sector whose .decal was destroyed, vanilla
-- MapSector:UpdateDecal places a fresh one (sectors with a valid decal are skipped,
-- so the core grid is not churned). Returns the number of decals recreated.
local function RefreshSectorDecals(city)
	city = city or Global("MainCity")
	if not city then
		return 0
	end
	if UndergroundExplorationUiOn(city) then
		-- Underground draws no grid, but the decal population must stay one-per-sector so the
		-- expanded map's object set matches its vanilla twin. Recreate anything missing through
		-- the patched UpdateDecal (which creates hidden underground), then hide everything again.
		local ug_recreated = 0
		Grid.ForEachSector(city, function(sector)
			if not IsValid(sector.decal) and type(sector.UpdateDecal) == "function" then
				SafeCall(sector.UpdateDecal, sector)
				ug_recreated = ug_recreated + 1
			end
		end)
		HideSectorVisuals(city, "RefreshSectorDecals underground data-only")
		return ug_recreated
	end
	local recreated = 0
	Grid.ForEachSector(city, function(sector)
		if not IsValid(sector.decal) and type(sector.UpdateDecal) == "function" then
			SafeCall(sector.UpdateDecal, sector)
			recreated = recreated + 1
		end
	end)
	RepairSectorVisualGeometry(city)
	PruneOrphanSectorDecals(city)
	return recreated
end

local SectorExploration = {}

SectorExploration.RefreshSectorDecals = RefreshSectorDecals
SectorExploration.RefreshSectorDisplayNames = RefreshSectorDisplayNames
SectorExploration.NormalizeSectorVisualGeometry = NormalizeSectorVisualGeometry
SectorExploration.RepairSectorVisualGeometry = RepairSectorVisualGeometry
SectorExploration.PruneOrphanSectorDecals = PruneOrphanSectorDecals
SectorExploration.PruneOrphanMapSectors = PruneOrphanMapSectors
SectorExploration.AuditOverviewGridVisuals = AuditOverviewGridVisuals

SectorExploration.InstallSectorPatch = InstallSectorPatch
SectorExploration.PatchInitialExplore = PatchInitialExplore
SectorExploration.CaptureVanillaStartSelection = CaptureVanillaStartSelection
SectorExploration.StageVanillaStartSelection = StageVanillaStartSelection
SectorExploration.HasPendingVanillaStartSelection = HasPendingVanillaStartSelection
SectorExploration.ClearPendingVanillaStartSelection = ClearPendingVanillaStartSelection
SectorExploration.RevealVanillaStartSectors = RevealVanillaStartSectors
SectorExploration.EnsureSectorPatch = EnsureSectorPatch
SectorExploration.EnsureSectorsBuilt = EnsureSectorsBuilt
SectorExploration.HideSectorVisuals = HideSectorVisuals
function SectorExploration.ApplyModBehavior()
	InstallSectorPatch()
	PatchInitialExplore()
end

function SectorExploration.RestoreVanillaBehavior()
	local State = SuperBigMap.State or {}

	if type(State.original_get_map_sector_tile_size) == "function" then
		rawset(_G, "GetMapSectorTileSize", State.original_get_map_sector_tile_size)
	end
	if type(State.original_get_map_sector_xy) == "function" then
		rawset(_G, "GetMapSectorXY", State.original_get_map_sector_xy)
	end
	if type(State.original_initial_reveal) == "function" then
		rawset(_G, "InitialReveal", State.original_initial_reveal)
	end
	do
		local cls = ClassTable("Exploration")
		if not (type(cls) == "table" and cls.InitialExplore == State.initial_explore_wrapper) then
			cls = ClassTable("City")
		end
		if type(cls) == "table" and cls.InitialExplore == State.initial_explore_wrapper
			and type(State.original_initial_explore) == "function" then
			cls.InitialExplore = State.original_initial_explore
		end
		State.initial_explore_wrapper = nil
		State.original_initial_explore = nil
		pending_vanilla_start_by_map = setmetatable({}, { __mode = "k" })
	end
	if type(State.original_is_expl_avail_sectors) == "function" then
		rawset(_G, "IsExplorationAvailable_Sectors", State.original_is_expl_avail_sectors)
	end
	if type(State.original_is_expl_avail_queue) == "function" then
		rawset(_G, "IsExplorationAvailable_Queue", State.original_is_expl_avail_queue)
	end
	State.original_get_map_sector_tile_size = nil
	State.original_get_map_sector_xy = nil
	State.original_initial_reveal = nil
	State.original_is_expl_avail_sectors = nil
	State.original_is_expl_avail_queue = nil

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
	State.superbigmap_init_sectors = nil

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

SuperBigMap.SectorExploration = SectorExploration

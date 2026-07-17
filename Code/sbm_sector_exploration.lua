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
local Round = Engine.Round
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

local function DebugPrint(message)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Sector", message)
	end
end

-- Init-sequence trace (gated on Config.DEBUG_INIT_SEQUENCE via DebugLog.InitSeq).
local function InitSeq(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog and type(DebugLog.InitSeq) == "function" then
		DebugLog.InitSeq(message, data)
	end
end

-- One-shot verbose diagnostics for the sector-init flow, gated on
-- Config.SHOW_SECTOR_DIAGNOSTICS. These print whether or not the normal
-- DebugLog gate would have hidden them, because they're collected to diagnose
-- *missing* events (e.g. an InitSectors call we don't see in the log).
local function DiagOn()
	local DebugLog = SuperBigMap.DebugLog
	return DebugLog ~= nil and DebugLog.On("Sector") == true
end

local function DiagPrint(message)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Sector", message)
	end
end

-- Inspect a city's MapSectors and return a one-line summary: column count, row
-- count, first sector's area dimensions, MapArea bounds. The width/height of
-- sector[1][1] reveals whether the engine pre-built sectors with a different
-- size than our layout expects (e.g. vanilla 12288/10 = 1228.8-tile sectors on
-- a BlankBig map vs. our expected 410-tile vanilla-sized sectors).
local function DescribeCityState(city)
	if not city then
		return "city=nil"
	end
	local sectors = type(city.MapSectors) == "table" and city.MapSectors or false
	local cols = 0
	if sectors then
		while type(sectors[cols + 1]) == "table" do
			cols = cols + 1
		end
	end
	local rows = 0
	if cols > 0 and type(sectors[1]) == "table" then
		while sectors[1][rows + 1] ~= nil do
			rows = rows + 1
		end
	end

	local size_x, size_y = "?", "?"
	if cols > 0 and rows > 0 then
		local first = sectors[1][1]
		if first and first.area then
			local ok_x, sx = pcall(first.area.sizex, first.area)
			local ok_y, sy = pcall(first.area.sizey, first.area)
			if ok_x then size_x = tostring(sx) end
			if ok_y then size_y = tostring(sy) end
		end
	end

	local map_area = "?"
	if city.MapArea then
		local ok, sx = pcall(city.MapArea.sizex, city.MapArea)
		local ok2, sy = pcall(city.MapArea.sizey, city.MapArea)
		if ok and ok2 then
			map_area = tostring(sx) .. "x" .. tostring(sy)
		end
	end

	return string.format(
		"city=%s MapSectors=%dx%d sector[1][1]_size=%sx%s MapArea_size=%s",
		tostring(city), cols, rows, size_x, size_y, map_area
	)
end

-- Compare exploration_class.InitSectors to the original we saved in State, and
-- report whether our patched function is still installed. Important because if
-- something (engine reload, another mod, our own restore path) replaced the
-- class function, InitSectors would not call our patched version.
local function DescribeInitSectorsBinding()
	local cls = ClassTable("Exploration")
	local State = SuperBigMap.State or {}
	if not cls then
		return "exploration_class=nil"
	end
	local live = cls.InitSectors
	local saved_original = State.original_exploration_init_sectors
	return string.format(
		"exploration_class.InitSectors=%s saved_original=%s same_as_original=%s",
		tostring(live),
		tostring(saved_original),
		tostring(live == saved_original)
	)
end

local function DiagSnapshot(label, map)
	if not DiagOn() then
		return
	end
	local city = map and map.City
	DiagPrint(string.format(
		"%s: map=%s env=%s mapdata=%sx%s terrain=%sx%s | %s | %s",
		tostring(label),
		tostring(map and map.name or (map and map.mapdata and map.mapdata.id) or "?"),
		tostring(map and map.mapdata and map.mapdata.Environment),
		tostring(map and map.mapdata and map.mapdata.Width),
		tostring(map and map.mapdata and map.mapdata.Height),
		tostring(map and map.Width),
		tostring(map and map.Height),
		DescribeCityState(city),
		DescribeInitSectorsBinding()
	))
end

local function cfg_bool(key, default)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "boolean" then
		return value
	end
	return default
end

-- Gated sector-SIZING diagnostics (config.DebugSectorSizing), de-duplicated per
-- tag so cursor-driven calls don't spam. Pair with sbm_sector_grid's SizingDiag.
local sizing_diag_last = {}
local function SizingDiag(tag, msg)
	local DebugLog = SuperBigMap.DebugLog
	if not (DebugLog and DebugLog.On("SectorSizing")) then
		return
	end
	if sizing_diag_last[tag] == msg then
		return
	end
	sizing_diag_last[tag] = msg
	DebugLog.Info("SectorSizing", msg, { tag = "expl/" .. tostring(tag) })
end

-- GetMapSectorXY is called from engine hex searches once per tested hex. Recomputing the full
-- layout there can execute tens of thousands of Lua instructions during one deposit placement and
-- trip the engine's infinite-loop detector. Cache the immutable lookup layout after the live grid
-- is complete. The MapSectors table plus its first/last sector objects form the invalidation key,
-- so InitSectors rebuilds and save-loaded grids automatically force one fresh resolution.
local sector_lookup_layout_cache = setmetatable({}, { __mode = "k" })
local function GetLiveCachedSectorLookupLayout(city)
	local sectors = city and city.MapSectors
	local cached = city and sector_lookup_layout_cache[city]
	if cached and cached.sectors == sectors and type(sectors) == "table" then
		local first_col = sectors[1]
		local last_col = sectors[cached.count_x]
		if first_col and first_col[1] == cached.first_sector
			and last_col and last_col[cached.count_y] == cached.last_sector then
			return cached.layout
		end
	end
	return nil
end

local function GetCachedSectorLookupLayout(city, map)
	local live = GetLiveCachedSectorLookupLayout(city)
	if live then return live end
	local sectors = city and city.MapSectors

	local layout = Grid.ResolveSectorLayout(map)
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
			SizingDiag("GetMapSectorXYLayoutCache", string.format(
				"cached completed %sx%s lookup layout for city=%s map=%s",
				tostring(layout.count_x), tostring(layout.count_y), tostring(city), tostring(map)))
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

local function cfg_number(key, default, min_value)
	local value = (SuperBigMap.Config or {})[key]
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

local function InterfaceMode()
	local get_mode = Global("GetInGameInterfaceMode")
	if type(get_mode) == "function" then
		return SafeCall(get_mode)
	end
	return nil
end

local SectorDecalClasses = { "SectorUnexplored", "SectorScanned" }
local SectorDecalEntitySet = { SectorUnexplored = true, SectorScanned = true }
local SectorSelectionClasses = { "SectorRadius", "SectorTarget" }

local function SectorVisualDiagOn()
	local Config = SuperBigMap.Config
	return Config and Config.SHOW_SECTOR_VISUAL_DIAGNOSTICS == true
end

local function VisualDiag(message, data)
	if not SectorVisualDiagOn() then
		return
	end
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Sector", message, data)
	end
end

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

local function ForEachMapObjectByClass(map, classes, callback, reason, filter)
	if not map or type(map.MapForEach) ~= "function" then
		VisualDiag("map object scan skipped", { reason = reason or "?", cause = "no map.MapForEach" })
		return 0
	end

	local objects = {}
	for i = 1, #classes do
		local class = classes[i]
		local ok, err = pcall(map.MapForEach, map, "map", class, function(obj)
			objects[#objects + 1] = obj
		end)
		if not ok then
			VisualDiag("map object scan failed", {
				reason = reason or "?",
				class = class,
				error = err,
			})
		end
	end

	local count = 0
	for i = 1, #objects do
		local obj = objects[i]
		if IsValid(obj) and (not filter or filter(obj)) then
			local ok, err = pcall(callback, obj)
			if ok then
				count = count + 1
			else
				VisualDiag("map object callback failed", {
					reason = reason or "?",
					error = err,
				})
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
	if fallback_count > 0 then
		VisualDiag("map sector decal fallback matched", {
			reason = reason or "?",
			count = fallback_count,
			mode = InterfaceMode(),
		})
	end
	return fallback_count
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
	VisualDiag("sector decal refs hidden", {
		reason = reason or "?",
		count = count,
		mode = InterfaceMode(),
	})
	return count
end

local function HideSectorDecalObjects(city, reason, map)
	map = ResolveVisualMap(city, map)
	local count = ForEachSectorDecalObject(map, function(obj)
		obj:ClearEnumFlags(const.efVisible)
	end, reason)
	VisualDiag("map sector decal objects hidden", {
		reason = reason or "?",
		count = count,
		mode = InterfaceMode(),
	})
	return count
end

local function HideOverviewSelectionObjects(reason, map)
	map = ResolveVisualMap(nil, map)
	local count = ForEachMapObjectByClass(map, SectorSelectionClasses, function(obj)
		obj:ClearEnumFlags(const.efVisible)
	end, reason)
	VisualDiag("overview selection objects hidden", {
		reason = reason or "?",
		count = count,
		mode = InterfaceMode(),
	})
	return count
end

local function HideSectorVisuals(city, reason)
	local map = ResolveVisualMap(city)
	local hidden_decal_refs = HideSectorDecals(city, reason)
	local hidden_decal_objects = HideSectorDecalObjects(city, reason, map)
	local hidden_selection = HideOverviewSelectionObjects(reason, map)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Sector", "overview sector visuals hidden", {
			reason = reason or "?",
			sector_decal_refs = hidden_decal_refs,
			sector_decal_objects = hidden_decal_objects,
			selection_objects = hidden_selection,
			mode = InterfaceMode(),
		})
	end
	return hidden_decal_objects, hidden_selection
end

local function DestroySectorDecalRefs(city, reason)
	local done_object = Global("DoneObject")
	if type(done_object) ~= "function" then
		VisualDiag("sector decal ref destroy skipped", { reason = reason or "?", cause = "no DoneObject" })
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
	VisualDiag("sector decal refs destroyed before rebuild", {
		reason = reason or "?",
		count = count,
		mode = InterfaceMode(),
	})
	return count
end

local function DestroySectorDecalObjects(map, reason)
	local done_object = Global("DoneObject")
	if type(done_object) ~= "function" then
		VisualDiag("map sector decal destroy skipped", { reason = reason or "?", cause = "no DoneObject" })
		return 0
	end

	local count = ForEachSectorDecalObject(map, function(obj)
		done_object(obj)
	end, reason)
	VisualDiag("map sector decal objects destroyed before rebuild", {
		reason = reason or "?",
		count = count,
		mode = InterfaceMode(),
	})
	return count
end

local function DestroyExistingSectorVisuals(city, map, reason)
	map = ResolveVisualMap(city, map)
	InitSeq("sector visuals about to be destroyed", {
		reason = reason or "?",
		grid = DescribeCityState(city),
		mode = InterfaceMode(),
	})
	local ref_count = DestroySectorDecalRefs(city, reason)
	local object_count = DestroySectorDecalObjects(map, reason)
	InitSeq("sector visuals destroyed", {
		reason = reason or "?",
		sector_decal_refs = ref_count,
		sector_decal_objects = object_count,
	})
	VisualDiag("sector visuals destroyed before rebuild", {
		reason = reason or "?",
		sector_decal_refs = ref_count,
		sector_decal_objects = object_count,
		mode = InterfaceMode(),
	})
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
			local city = map and map.City
			local layout = city and GetCachedSectorLookupLayout(city, map) or Grid.ResolveSectorLayout(map)
			local step = layout.step_x
			SizingDiag("GetMapSectorTileSize", string.format("GetMapSectorTileSize CUSTOM -> step_x=%s", tostring(Round(step))))
			return step
		end
		local vanilla = original_tile_size(map)
		SizingDiag("GetMapSectorTileSize", string.format(
			"GetMapSectorTileSize VANILLA -> %s (UseCustomSectorsForMap=false)", tostring(vanilla)))
		return vanilla
	end

	-- Diagnostic state for GetMapSectorXY: log once per (col,row) pair when the
	-- cursor moves to a new sector cell. Reveals what our layout-based math says
	-- vs. what city.MapSectors actually returns (e.g. nil if MapSectors only has
	-- 10 rows but our layout says col=15).
	local last_logged_xy = false
	function GetMapSectorXY(city, mx, my)
		-- The completed expanded grid is the steady-state hot path. Avoid even resolving the map
		-- or re-running the custom-map predicate for every hex tested by HexGridFindBuildable.
		local layout = GetLiveCachedSectorLookupLayout(city)
		if not layout then
			local map = city and city.GetMap and city:GetMap()
			if not Grid.UseCustomSectorsForMap(map) then
				return original_sector_xy(city, mx, my)
			end
			layout = GetCachedSectorLookupLayout(city, map)
		end
		local x = mx - layout.border
		local y = my - layout.border
		local col = ClampNumber(1 + math.floor(x / layout.step_x), 1, layout.count_x)
		local row = ClampNumber(1 + math.floor(y / layout.step_y), 1, layout.count_y)
		local sector_col = city.MapSectors and city.MapSectors[col]
		local sector = sector_col and sector_col[row]

		if DiagOn() then
			local key = tostring(col) .. "," .. tostring(row)
			if key ~= last_logged_xy then
				last_logged_xy = key
				local cols = 0
				if city and type(city.MapSectors) == "table" then
					while type(city.MapSectors[cols + 1]) == "table" do
						cols = cols + 1
					end
				end
				local rows = 0
				if cols > 0 and type(city.MapSectors[1]) == "table" then
					while city.MapSectors[1][rows + 1] ~= nil do
						rows = rows + 1
					end
				end
				print(string.format(
					"[Super Big Map] SectorDiag: GetMapSectorXY mx=%s my=%s border=%s step=%s layout=%sx%s -> col=%s row=%s sector=%s MapSectors=%dx%d",
					tostring(mx), tostring(my),
					tostring(layout.border), tostring(Round(layout.step_x)),
					tostring(layout.count_x), tostring(layout.count_y),
					tostring(col), tostring(row),
					tostring(sector and sector.id or "nil"),
					cols, rows
				))
			end
		end

		return sector
	end

	-- Underground overview sector UI: vanilla HARD-GATES the sector hover/rollover/scan-queue off
	-- underground maps -- IsExplorationAvailable_Sectors/Queue return false for
	-- Environment=="Underground" (Exploration.lua:569-577), so OverviewModeDialog:SelectSector
	-- early-outs before drawing the highlight decal or rollover (the "hover shows nothing
	-- underground" report; the Hover logs proved sector RESOLUTION worked). Wrap both to return
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
	DebugPrint("sector basic functions patched")
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
-- geometry and annotate its first winner. AFTER the stretch, collect only the live 20x20 sectors
-- intersecting that winner's proportionally transformed box, run the same vanilla rule over that
-- small set, and reveal only its first result. InitialReveal only reads plain sector fields, so
-- lightweight virtual source tables work without constructing a second exploration grid.
-- ---------------------------------------------------------------------------------------
local function StartLog(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then DebugLog.Info("StartSector", message, data) end
end

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
	local diag = {}
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
	-- view for both diagnostics and vanilla InitialReveal, then restore the city and global count.
	local saved_map_area = city.MapArea
	local saved_map_sectors = city.MapSectors
	local saved_sector_count = type(const_tbl) == "table" and const_tbl.SectorCount or nil
	city.MapArea = box_fn(border, border, border + VN * tile, border + VN * tile)
	city.MapSectors = virtual_grid
	if type(const_tbl) == "table" then const_tbl.SectorCount = VN end
	DebugPrint(string.format("native start temporary exploration view installed: grid=%dx%d area=%d,%d-%d,%d",
		VN, VN, border, border, border + VN * tile, border + VN * tile))

	-- Keep diagnostics side-effect-free and cheap. Vanilla's actual InitialReveal below performs
	-- the authoritative CanPlaceDeposit-gated resource calculation once.
	for i = 1, #eligible do
		local sec = eligible[i]
		diag[#diag + 1] = string.format("%s(m=%d pr=%d heat=%d w=%d)",
			sec.id, #sec.markers.surface, sec.play_ratio, sec.avg_heat,
			math.floor(sec.play_ratio * sec.avg_heat / max_heat))
	end
	StartLog("virtual vanilla sectors built", {
		eligible = #eligible, tile = tile, border = border, orient = orient,
		candidates = table.concat(diag, " "),
	})
	-- Same seeded stream vanilla's InitialExplore would create.
	local ok_rand, _, trand = pcall(city.CreateMapRand, city, "Exploration")
	local ok_pick, revealed
	if ok_rand and type(trand) == "function" then
		ok_pick, revealed = pcall(initial_reveal, eligible, trand)
	end
	city.MapArea = saved_map_area
	city.MapSectors = saved_map_sectors
	if type(const_tbl) == "table" then const_tbl.SectorCount = saved_sector_count or VN end
	DebugPrint("native start temporary exploration view restored")
	if not (ok_rand and type(trand) == "function") then return nil, "trand unavailable" end
	if not (ok_pick and type(revealed) == "table" and #revealed > 0) then
		return nil, "InitialReveal failed: " .. tostring(revealed)
	end
	-- Vanilla can return a second, nearest-concrete sector in its fallback branch. The requested
	-- expanded behavior is exactly one reveal corresponding to VANILLA'S FIRST winner, never a
	-- random choice between the first and its auxiliary concrete sector.
	local vanilla_revealed_count = #revealed
	if #revealed > 1 then
		StartLog("multiple vanilla source winners -- annotating first only", {
			count = #revealed, first = tostring(revealed[1] and revealed[1].id),
			auxiliary = tostring(revealed[2] and revealed[2].id),
		})
	end
	revealed = { revealed[1] }
	local winners = {}
	for _, sec in ipairs(revealed) do
		local mn, mx = sec.area:min(), sec.area:max()
		local x0, y0 = mn:xy()
		local x1, y1 = mx:xy()
		winners[#winners + 1] = { x0 = x0, y0 = y0, x1 = x1, y1 = y1, id = sec.id }
		StartLog("vanilla start pick", { id = tostring(sec.id), box = string.format("%d,%d-%d,%d", x0, y0, x1, y1) })
		DebugPrint("vanilla-equivalent starting sector selected: " .. tostring(sec.id))
	end
	return { winners = winners, vanilla_revealed_count = vanilla_revealed_count }
end

local function CaptureVanillaStartSelection(map)
	-- A temporary generation backing may not own a fully initialized City yet. CreateMapRand is
	-- delegated to UIColony, so the current destination city is an equivalent deterministic owner.
	local city = map and map.City or Global("MainCity")
	if not city then return nil, "native source city unavailable" end
	local ok, selection, reason = pcall(VanillaStartPick, city, map)
	if not (ok and type(selection) == "table" and type(selection.winners) == "table"
		and #selection.winners == 1) then
		return nil, tostring(ok and reason or selection)
	end
	local winner = selection.winners[1]
	StartLog("native source start sector annotated", {
		map = tostring(map.name), sector = tostring(winner.id),
		source_box = string.format("%s,%s-%s,%s", tostring(winner.x0), tostring(winner.y0),
			tostring(winner.x1), tostring(winner.y1)),
		vanilla_revealed_count = tostring(selection.vanilla_revealed_count),
	})
	DebugPrint(string.format("native start annotated: sector=%s box=%s,%s-%s,%s vanilla_count=%s",
		tostring(winner.id), tostring(winner.x0), tostring(winner.y0), tostring(winner.x1),
		tostring(winner.y1), tostring(selection.vanilla_revealed_count)))
	return selection
end

local function StageVanillaStartSelection(map, selection, reason)
	if not map or type(selection) ~= "table" or type(selection.winners) ~= "table"
		or #selection.winners ~= 1 then return false, "invalid native start annotation" end
	pending_vanilla_start_by_map[map] = selection
	local winner = selection.winners[1]
	map.SuperBigMapVanillaStartSourceSector = winner.id
	map.SuperBigMapVanillaStartSourceX0 = winner.x0
	map.SuperBigMapVanillaStartSourceY0 = winner.y0
	map.SuperBigMapVanillaStartSourceX1 = winner.x1
	map.SuperBigMapVanillaStartSourceY1 = winner.y1
	StartLog("native source start annotation staged for destination", {
		map = tostring(map.name), reason = tostring(reason), sector = tostring(winner.id),
	})
	return true
end

local function HasPendingVanillaStartSelection(map)
	return map ~= nil and pending_vanilla_start_by_map[map] ~= nil
end

local function ClearPendingVanillaStartSelection(map, reason)
	if map then pending_vanilla_start_by_map[map] = nil end
	StartLog("native source start annotation cleared", {
		map = tostring(map and map.name), reason = tostring(reason),
	})
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
		StartLog("InitialExplore patch waiting (class unavailable)")
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
			-- VALIDATION MODE on VANILLA surface maps (DEBUG_STARTSECTOR): run the same
			-- reconstruction ANALYSIS (no scanning, no deferral, own rand stream -- zero
			-- interference) right before vanilla's own selection, so one vanilla run logs
			-- our predicted pick next to vanilla's native 'starting sector selected:' print.
			-- A mismatch, with both candidate tables in the log, pinpoints the divergent
			-- input (qty / play_ratio / heat / eligibility).
			if env == "Surface" and not expanded
				and (SuperBigMap.Config or {}).DEBUG_STARTSECTOR == true then
				local ok_a, pick_a, reason_a = pcall(VanillaStartPick, self, map)
				StartLog("VALIDATION (vanilla map): reconstruction pick", {
					ok = ok_a and pick_a ~= nil,
					prediction = (ok_a and pick_a) and table.concat((function()
						local ids = {}
						for _, w in ipairs(pick_a.winners) do ids[#ids + 1] = tostring(w.id) end
						return ids
					end)(), "+") or tostring(ok_a and reason_a or pick_a),
				})
			end
			original(self, eligible_out, ...) -- InitialExplore returns nothing
			pcall(function()
				if env == "Surface" and not expanded then
					StartLog("VALIDATION (vanilla map): vanilla actual InitialSector", {
						id = tostring(self.InitialSector and self.InitialSector.id),
					})
				end
			end)
			return
		end
		-- The exact winner was captured while the temporary native source and its markers still
		-- existed. At this later destination InitSectors boundary those markers are deliberately
		-- staged as value records, so recomputing from the live destination would see no resources.
		if HasPendingVanillaStartSelection(map) then
			StartLog("initial reveal deferred using staged native source annotation", {
				sector = tostring(map.SuperBigMapVanillaStartSourceSector),
			})
			return
		end
		local ok_pick, pick, reason = pcall(VanillaStartPick, self, map)
		if not (ok_pick and pick) then
			StartLog("vanilla start pick FAILED -- falling back to vanilla InitialExplore", {
				reason = tostring(ok_pick and reason or pick),
			})
			return original(self, eligible_out, ...)
		end
		-- Compatibility fallback for an expanded path without a temporary source. Defer this
		-- reconstructed native selection exactly as the source-capture path does.
		StageVanillaStartSelection(map, pick, "InitialExplore compatibility fallback")
		StartLog("initial reveal DEFERRED to post-stretch", { winners = #pick.winners })
	end
	cls.InitialExplore = wrapper
	State.initial_explore_wrapper = wrapper
	StartLog("Exploration.InitialExplore wrapped (vanilla-equivalent start sector)")
	return true
end

-- Post-stretch reveal: transform the annotated vanilla winner box, rank the live expanded sectors
-- by geometric overlap, then run vanilla's own InitialReveal only over the sector(s) tied for the
-- greatest overlap. Position therefore decides equivalence first; vanilla resource/heat rules are
-- used only to break a genuine positional tie. Scan exactly the first vanilla result, then replicate
-- InitialExplore's tail (commander bonus deposit plus forced overview SelectSector).
local function RevealVanillaStartSectors(map)
	local State = SuperBigMap.State or {}
	map = map or Global("MainMap")
	local data = map and pending_vanilla_start_by_map[map]
	if not data then return 0 end
	pending_vanilla_start_by_map[map] = nil
	local city = map and map.City
	if not (city and Grid and type(Grid.ForEachSector) == "function") then
		StartLog("post-stretch reveal skipped (city/grid unavailable)")
		return 0
	end
	local sw = map.SuperBigMapSourceWidthTiles or map.SuperBigMapGeneratorWidthTiles
	local full = map.SuperBigMapDesiredWidthTiles
	if not (type(sw) == "number" and type(full) == "number" and sw > 0 and full > sw) then
		StartLog("post-stretch reveal skipped (sizes unknown)")
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
	local scale_x, scale_y = final_w / source_w, final_h / source_h
	local x0 = math.floor(origin_x + (winner.x0 - origin_x) * scale_x + 0.5)
	local y0 = math.floor(origin_y + (winner.y0 - origin_y) * scale_y + 0.5)
	local x1 = math.floor(origin_x + (winner.x1 - origin_x) * scale_x + 0.5)
	local y1 = math.floor(origin_y + (winner.y1 - origin_y) * scale_y + 0.5)
	local box_fn = Global("box")
	local transformed_box = type(box_fn) == "function" and box_fn(x0, y0, x1, y1) or nil
	if transformed_box and type(city.UpdateBuildableRatio) == "function" then
		pcall(city.UpdateBuildableRatio, city, transformed_box)
	end

	local overlaps, candidate_log = {}, {}
	local max_overlap = 0
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
		if overlap > max_overlap then max_overlap = overlap end
		overlaps[#overlaps + 1] = { sector = sector, overlap = overlap }
		local marker_count = sector.markers and sector.markers.surface
			and #sector.markers.surface or 0
		candidate_log[#candidate_log + 1] = string.format("%s(overlap=%d markers=%d play=%s heat=%s)",
			tostring(sector.id), overlap, marker_count,
			tostring(sector.play_ratio), tostring(sector.avg_heat))
	end)
	if #overlaps == 0 then
		error("no expanded sector intersects the transformed vanilla start sector")
	end

	-- A stretched 10x10 source sector can touch several 20x20 destination sectors. Treating every
	-- positive intersection as equivalent lets a one-unit sliver beat the sector containing almost
	-- the entire transformed footprint. Keep only maximum-overlap sectors; exact ties are the only
	-- case where multiple destination sectors are equally faithful positional equivalents.
	local candidates, positional_log = {}, {}
	for i = 1, #overlaps do
		local record = overlaps[i]
		if record.overlap == max_overlap then
			local sector = record.sector
			candidates[#candidates + 1] = sector
			candidates[sector] = true
			positional_log[#positional_log + 1] = tostring(sector.id)
		end
	end
	if #candidates == 0 then
		error("no maximum-overlap equivalent for transformed vanilla start sector")
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
	local diagnostics = {
		source_sector = tostring(winner.id),
		source_box = string.format("%d,%d-%d,%d", winner.x0, winner.y0, winner.x1, winner.y1),
		source_origin = string.format("%d,%d", origin_x, origin_y),
		source_tiles = string.format("%dx%d", source_w, source_h),
		final_tiles = string.format("%dx%d", final_w, final_h),
		scale = string.format("%.9f,%.9f", scale_x, scale_y),
		transformed_box = string.format("%d,%d-%d,%d", x0, y0, x1, y1),
		intersections = table.concat(candidate_log, " "),
		max_overlap = max_overlap,
		positional_candidates = table.concat(positional_log, "+"),
		positional_candidate_count = #candidates,
		vanilla_result_count = #revealed,
		selected = tostring(selected.id),
	}
	StartLog("post-stretch vanilla candidate selection", {
		source_sector = diagnostics.source_sector,
		source_box = diagnostics.source_box,
		scale = diagnostics.scale,
		transformed_box = diagnostics.transformed_box,
		intersection_count = #overlaps, intersections = diagnostics.intersections,
		max_overlap = max_overlap, positional_candidates = diagnostics.positional_candidates,
		candidate_count = #candidates,
		vanilla_result_count = #revealed, selected = tostring(selected.id),
	})
	DebugPrint(string.format("transformed native start: source=%s source_box=%s scale=%s box=%s intersections=%s max_overlap=%s positional=%s selected=%s",
		diagnostics.source_sector, diagnostics.source_box, diagnostics.scale,
		diagnostics.transformed_box, diagnostics.intersections, tostring(max_overlap),
		diagnostics.positional_candidates, diagnostics.selected))

	-- This is still initial generation: remove any accidental destination reveal produced while the
	-- class wrapper was being reclaimed, then persist exactly the one vanilla-selected candidate.
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
	local cleared = 0
	Grid.ForEachSector(city, function(sector)
		if sector.status and sector.status ~= "unexplored" then cleared = cleared + 1 end
		sector.status = "unexplored"
		sector.revealed_obj = nil
		sector.revealed_surf = nil
		sector.revealed_deep = nil
		if type(sector.UpdateDecal) == "function" then pcall(sector.UpdateDecal, sector) end
	end)
	city.InitialSector = false
	local scan_ok, scan_error = pcall(selected.Scan, selected, "scanned", nil, spawn_positions)
	if not scan_ok then error("selected transformed start sector scan failed: " .. tostring(scan_error)) end
	city.InitialSector = selected

	local scanned_total = 0
	Grid.ForEachSector(city, function(sector)
		if sector.status and sector.status ~= "unexplored" then scanned_total = scanned_total + 1 end
	end)
	if scanned_total ~= 1 or selected.status == "unexplored" then
		error(string.format("initial reveal cardinality verification failed: scanned=%s selected_status=%s",
			tostring(scanned_total), tostring(selected.status)))
	end
	StartLog("post-stretch reveal: exactly one sector scanned", {
		source_sector = tostring(winner.id), selected = tostring(selected.id),
		cleared_preexisting = cleared, scanned = scanned_total,
	})
	DebugPrint(string.format("transformed native start verified: source=%s selected=%s scanned=%s cleared=%s",
		tostring(winner.id), tostring(selected.id), tostring(scanned_total), tostring(cleared)))

	if selected then
		-- Vanilla tail: overview exit_to + forced SelectSector on the last revealed sector.
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
	StartLog("post-stretch reveal DONE", {
		scanned = scanned_total,
		initial_sector = tostring(city.InitialSector and city.InitialSector.id),
	})
	diagnostics.scanned = scanned_total
	diagnostics.cleared_preexisting = cleared
	diagnostics.initial_sector = tostring(city.InitialSector and city.InitialSector.id)
	DebugPrint(string.format("vanilla-equivalent start revealed: %s sector(s), InitialSector=%s",
		tostring(scanned_total), tostring(city.InitialSector and city.InitialSector.id)))
	return scanned_total, diagnostics
end

local function InstallSectorPatch()
	local State = SuperBigMap.State

	DebugPrint(string.format(
		"sector full patch attempt v%s: Exploration=%s g_Exploration=%s MapSector=%s InitSector=%s",
		tostring(SECTOR_PATCH_VERSION),
		type(Global("Exploration")),
		type(ClassTable("Exploration")),
		type(ClassTable("MapSector")),
		type(Global("InitSector"))
	))

	local highlight = SuperBigMap.SectorHighlight
	if highlight then
		highlight.Install()
	end

	if not cfg_bool("ENABLE_EXPANDED_SECTORS", true) then
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
		-- Unconditional diagnostic so we know the engine actually called us
		-- (even when SHOW_SECTOR_DIAGNOSTICS is off, this fires whenever
		-- InitSectors enters -- useful when DebugLog is somehow disabled).
		DiagPrint(string.format(
			"InitSectors ENTER: self=%s map=%s name=%s",
			tostring(self), tostring(map),
			tostring(map and map.name or (map and map.mapdata and map.mapdata.id) or "?")
		))

		if not Grid.UseCustomSectorsForMap(map) then
			SizingDiag("InitSectors", "InitSectors VANILLA path (UseCustomSectorsForMap=false) -> sectors sized mapWidth/10 (OVERSIZED on expanded maps)")
			DebugPrint("sector InitSectors using vanilla path: " .. Grid.DescribeMap(map))
			return original_init_sectors(self, map, eligible_sectors_with_surface_deposits_out)
		end

		DestroyExistingSectorVisuals(self, map, "InitSectors")
		Grid.ConfigureGlobalSectorCount(map, "InitSectors")
		local layout = Grid.ResolveSectorLayout(map)
		InitSeq("InitSectors: building grid", {
			count_x = layout.count_x,
			count_y = layout.count_y,
			target = layout.target,
			map = Grid.DescribeMap(map),
		})
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
			InitSeq("InitSectors: grid built", {
				count_x = layout.count_x,
				count_y = layout.count_y,
				live = DescribeCityState(self),
			})
			SizingDiag("InitSectors", string.format(
				"InitSectors CUSTOM built: count=%sx%s layout.step=%sx%s actual sector[1][1] size=%s (match=%s)",
				tostring(layout.count_x), tostring(layout.count_y),
				tostring(Round(layout.step_x)), tostring(Round(layout.step_y)),
				tostring(LiveSectorSize(self)),
				tostring(LiveSectorSize(self) ~= nil and math.abs(LiveSectorSize(self) - layout.step_x) <= 2)))
		end)
	end

	-- Remember OUR custom InitSectors closure so EnsureSectorsBuilt can detect when the
	-- class method has been clobbered by another system (the random-map generator re-runs
	-- vanilla InitSectors around MapGenerated, which rebuilds the grid at the oversized
	-- vanilla size) and reclaim/call ours directly to restore the vanilla-sized layout.
	State.superbigmap_init_sectors = exploration_class.InitSectors

	exploration_class.InitMapArea = function(self)
		if not Grid.UseCustomSectorsForMap(self:GetMap()) then
			DebugPrint("sector InitMapArea using vanilla path: " .. Grid.DescribeMap(self:GetMap()))
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
			DebugPrint(string.format(
				"sector InitMapArea full-terrain MapArea: 0,0 -> %d,%d (%d x %d sectors)",
				map_width, map_height, last_col, last_row))
			return
		end

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
				DebugPrint("GatherDiscoveredDeposits delegating to vanilla (helpers not global in this build)")
				return fallback(self)
			end
			DebugPrint("GatherDiscoveredDeposits returning empty (no fallback)")
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
	end

	if State.original_hide_exploration_sectors == nil then
		State.original_hide_exploration_sectors = Global("HideExploration_Sectors") or false
	end
	function HideExploration_Sectors(city, time)
		HideSectorVisuals(city, "HideExploration_Sectors")
	end

	if State.original_update_scanned_sector_visuals == nil then
		State.original_update_scanned_sector_visuals = Global("UpdateScannedSectorVisuals") or false
	end
	function UpdateScannedSectorVisuals(status)
		local city = Global("MainCity")
		if UndergroundExplorationUiOn(city) then
			HideSectorVisuals(city, "UpdateScannedSectorVisuals underground data-only")
			return
		end
		Grid.ForEachSector(city, function(sector)
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
		DebugPrint("EnsureSectorsBuilt via " .. tostring(reason) .. ": no map.City yet")
		return false, "no city"
	end

	local exploration_class = ClassTable("Exploration")
	if not exploration_class or type(exploration_class.InitSectors) ~= "function" then
		DebugPrint("EnsureSectorsBuilt via " .. tostring(reason) .. ": no patched InitSectors")
		return false, "no init_sectors"
	end

	local expected = Grid.ResolveSectorCount(map)
	if type(expected) ~= "number" or expected <= 0 then
		DebugPrint("EnsureSectorsBuilt via " .. tostring(reason) .. ": no expected count: " .. Grid.DescribeMap(map))
		return false, "no expected"
	end

	local sectors = type(city.MapSectors) == "table" and city.MapSectors or false
	-- #city.MapSectors counts the numerically-indexed columns. We also store the
	-- sector object itself as a key (boolean true) so length-operator on a sparse
	-- mix is unreliable; count columns explicitly.
	local cols = 0
	if sectors then
		while type(sectors[cols + 1]) == "table" do
			cols = cols + 1
		end
	end
	local rows = 0
	if cols > 0 and type(sectors[1]) == "table" then
		while sectors[1][rows + 1] ~= nil do
			rows = rows + 1
		end
	end

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

	DebugPrint(string.format(
		"EnsureSectorsBuilt via %s: live=%dx%d expected=%dx%d live_size=%s step=%s size_ok=%s city=%s",
		tostring(reason), cols, rows, expected, expected,
		tostring(live_size), tostring(expected_step and Round(expected_step)), tostring(size_ok),
		tostring(city)
	))
	SizingDiag("EnsureSectorsBuilt", string.format(
		"EnsureSectorsBuilt via %s: live=%dx%d expected_count=%d live_size=%s expected_step=%s size_ok=%s %s",
		tostring(reason), cols, rows, expected,
		tostring(live_size), tostring(expected_step and Round(expected_step)), tostring(size_ok),
		Grid.DescribeMap(map)))

	InitSeq("EnsureSectorsBuilt: decision", {
		reason = tostring(reason),
		live_cols = cols,
		live_rows = rows,
		expected = expected,
		live_size = tostring(live_size),
		expected_step = tostring(expected_step and Round(expected_step)),
		size_ok = size_ok,
		will_rebuild = not (cols == expected and rows == expected and size_ok),
	})

	if cols == expected and rows == expected and size_ok then
		return true, "matches"
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
		SizingDiag("EnsureSectorsBuilt", "custom InitSectors NOT active on class (missing/clobbered) -> (re)installing + reclaiming")
		pcall(InstallSectorPatch)
		exploration_class = ClassTable("Exploration") or exploration_class
		custom_fn = State.superbigmap_init_sectors
		-- InstallSectorPatch is version-guarded and may not re-assign if it believes the
		-- patch is current; force the class method back to OUR closure so this rebuild AND
		-- every later InitSectors call use the vanilla-sized layout.
		if type(custom_fn) == "function" and exploration_class.InitSectors ~= custom_fn then
			exploration_class.InitSectors = custom_fn
			DebugPrint("EnsureSectorsBuilt: reclaimed clobbered Exploration.InitSectors -> mod custom closure")
		end
		custom_installed = type(custom_fn) == "function" and exploration_class.InitSectors == custom_fn
	end

	DebugPrint(string.format(
		"EnsureSectorsBuilt via %s: forcing InitSectors rebuild (%dx%d -> %dx%d, size %s -> step %s, custom_init=%s)",
		tostring(reason), cols, rows, expected, expected,
		tostring(live_size), tostring(expected_step and Round(expected_step)), tostring(custom_installed)
	))

	InitSeq("EnsureSectorsBuilt: forcing InitSectors rebuild", {
		reason = tostring(reason),
		from = tostring(cols) .. "x" .. tostring(rows),
		to = tostring(expected) .. "x" .. tostring(expected),
	})
	-- Prefer our stored closure (independent of whatever is currently on the class).
	-- Random-map generation can also restore Exploration.InitialExplore after the initial mod
	-- install. Reclaim the deferral wrapper immediately before InitSectors invokes that method.
	PatchInitialExplore()
	local init_fn = (type(custom_fn) == "function") and custom_fn or exploration_class.InitSectors
	local ok, err = pcall(init_fn, city, map, {})
	if not ok then
		DebugPrint("EnsureSectorsBuilt: InitSectors threw: " .. tostring(err))
		return false, err
	end

	-- InitMapArea reads MapSectors to compute the playable area; re-run it so the
	-- bounds and overview match the freshly-built grid.
	if type(exploration_class.InitMapArea) == "function" then
		pcall(exploration_class.InitMapArea, city)
	end

	local new_size = LiveSectorSize(city)
	local new_ok = type(new_size) == "number" and type(expected_step) == "number"
		and math.abs(new_size - expected_step) <= 2
	SizingDiag("EnsureSectorsBuilt", string.format(
		"EnsureSectorsBuilt via %s: rebuilt -> sector[1][1] size=%s (expected step=%s, ok=%s)",
		tostring(reason), tostring(new_size), tostring(expected_step and Round(expected_step)), tostring(new_ok)))
	if type(new_size) == "number" and type(expected_step) == "number" and not new_ok then
		DebugPrint(string.format(
			"EnsureSectorsBuilt via %s: WARNING rebuilt grid still wrong size (%s, expected %s) -- custom InitSectors path not active",
			tostring(reason), tostring(new_size), tostring(Round(expected_step))))
	end

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
	local ok_env, env = pcall(function() return city:GetMap().mapdata.Environment end)
	if ok_env and env == "Underground" and (SuperBigMap.Config or {}).UNDERGROUND_EXPLORATION_UI == true then
		HideSectorVisuals(city, "RefreshSectorDecals underground data-only")
		return 0
	end
	local recreated = 0
	Grid.ForEachSector(city, function(sector)
		if not IsValid(sector.decal) and type(sector.UpdateDecal) == "function" then
			SafeCall(sector.UpdateDecal, sector)
			recreated = recreated + 1
		end
	end)
	if recreated > 0 then
		DebugPrint("RefreshSectorDecals: recreated " .. tostring(recreated) .. " missing sector decals")
	end
	InitSeq("RefreshSectorDecals", { recreated = recreated })
	return recreated
end

local SectorExploration = {}

SectorExploration.RefreshSectorDecals = RefreshSectorDecals

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
SectorExploration.DiagSnapshot = DiagSnapshot
SectorExploration.DiagOn = DiagOn
SectorExploration.DescribeCityState = DescribeCityState
SectorExploration.DescribeInitSectorsBinding = DescribeInitSectorsBinding

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

DebugPrint("sector exploration module loaded v" .. tostring(SECTOR_PATCH_VERSION))

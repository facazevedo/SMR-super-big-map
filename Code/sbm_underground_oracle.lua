-- Super Big Map -- where the underground entrances belong, without building the underground.
--
-- The two underground entrances are not generated content.  Every BlankUnderground_0X map ships
-- exactly two authored SurfacePassageMarker objects, present the instant the map is loaded and
-- identical for every seed (verified: two full underground generations of BlankUnderground_04 with
-- different generator seeds produced the same two positions as a bare load of the map).  Vanilla's
-- RandomMapGen_PlaceArtefacts_Passages then puts the underground side exactly on a marker and asks
-- SpawnUndergroundPassage to find a surface spot starting from that same position.
--
-- So the whole answer is: pick the blank map the way vanilla picks it, load it into a spare slot,
-- read the two markers, unload.  No generation runs, so there is no prefab solver, no terrain
-- raster, and no seed involved in the positions themselves -- only in which of the four maps is
-- chosen.  Measured cost is a single map load, about three seconds, and it is cached per map name
-- so a session pays it at most once per blank map.
--
-- NEVER obtain these by generating the map.  Proc_PlaceArtefacts runs
-- RandomMapGen_PlaceArtefacts_Passages, which spawns UndergroundPassage objects onto the LIVE
-- surface map: four throwaway generations left a live surface holding ten passages instead of two,
-- three of them stacked on one spot.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall

local Oracle = {}
SuperBigMap.UndergroundOracle = Oracle

Oracle.VERSION = 1

-- Source-coordinate markers keyed by blank map name.  Authored content, so one read per session
-- per map is enough; the cache is deliberately not weak.
Oracle.Cache = {}

local function cfg_bool(key, default)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "boolean" then
		return value
	end
	return default
end

local function trace(fmt, ...)
	if not cfg_bool("TRACE_UNDERGROUND_ORACLE", true) then return end
	print(string.format("[SBM ORACLE] " .. fmt, ...))
end

-- Vanilla's PickUndergroundMap is a local in RandomMapGenerator_Picard.lua, so the candidate list
-- and the draw are mirrored here rather than guessed at.  Keyed on the surface generator's seed,
-- which is settled long before the underground would ever be built.
Oracle.BLANK_UNDERGROUND_MAPS = {
	"BlankUnderground_01",
	"BlankUnderground_02",
	"BlankUnderground_03",
	"BlankUnderground_04",
}

function Oracle.PickUndergroundMapName(surface_map)
	local get_generator = Global("GetRandomMapGenerator")
	if type(get_generator) ~= "function" then
		return nil, "GetRandomMapGenerator unavailable"
	end
	local generator = SafeCall(get_generator, surface_map or Global("MainMap"))
	local seed = generator and generator.Seed
	if type(seed) ~= "number" then
		return nil, "surface generator has no seed"
	end
	local table_rand = (Global("table") or {}).rand
	if type(table_rand) ~= "function" then
		return nil, "table.rand unavailable"
	end
	local name = SafeCall(table_rand, Oracle.BLANK_UNDERGROUND_MAPS, seed)
	if type(name) ~= "string" or name == "" then
		return nil, "underground map draw failed"
	end
	return name
end

local function find_free_slot()
	local maps = Global("Maps")
	if type(maps) ~= "table" then return nil, "Maps unavailable" end
	local config_tbl = Global("config")
	local slots = tonumber(type(config_tbl) == "table" and config_tbl.MapSlots or nil) or 0
	if slots < 1 then return nil, "config.MapSlots unavailable" end
	for slot = 1, slots do
		if not maps[slot] then return slot end
	end
	return nil, string.format("no free map slot (all %d in use)", slots)
end

-- Load the blank map into a spare slot, read its authored markers, unload.  Returns markers in
-- SOURCE (vanilla, unexpanded) world coordinates.
function Oracle.ReadVanillaEntrances(map_name)
	if type(map_name) ~= "string" or map_name == "" then
		return nil, "no underground map name"
	end
	local cached = Oracle.Cache[map_name]
	if cached then return cached end

	local can_yield = Global("CanYield")
	if type(can_yield) == "function" and SafeCall(can_yield) ~= true then
		-- ChangeMapInSlot asserts CanYield(); refuse rather than trip an engine assert.
		return nil, "underground oracle requires a yielding thread"
	end
	local change_map_in_slot = Global("ChangeMapInSlot")
	local map_data = Global("MapData")
	if type(change_map_in_slot) ~= "function" then
		return nil, "ChangeMapInSlot unavailable"
	end
	if type(map_data) ~= "table" or not map_data[map_name] then
		return nil, string.format("no mapdata for %s", tostring(map_name))
	end

	local slot, slot_error = find_free_slot()
	if not slot then return nil, slot_error end

	local started = SafeCall(Global("GetPreciseTicks")) or 0
	local load_ok, load_error = pcall(change_map_in_slot, slot, map_name)
	local maps = Global("Maps")
	local map = load_ok and maps and maps[slot] or nil

	local markers, failure
	if not load_ok then
		failure = "blank underground load failed: " .. tostring(load_error)
	elseif not map then
		failure = "blank underground load produced no map"
	else
		markers = {}
		local ok_scan, scan_error = pcall(function()
			for _, obj in ipairs(map:MapGet("map", "SurfacePassageMarker") or {}) do
				local x, y, z = obj:GetPosXYZ()
				markers[#markers + 1] = { x = x, y = y, z = z, angle = obj:GetAngle() }
			end
		end)
		if not ok_scan then
			markers, failure = nil, "marker scan failed: " .. tostring(scan_error)
		end
		-- The stretch that will be applied to these positions is calibrated against the vanilla
		-- source geometry, so a blank map of a different size would silently misplace both
		-- entrances.  Record the size and let the caller compare.
		if markers then
			local terrain_api = Global("terrain")
			local size = type(terrain_api) == "table" and type(terrain_api.HeightMapSize) == "function"
				and SafeCall(terrain_api.HeightMapSize, map) or nil
			markers.height_map_size = tonumber(size)
		end
	end

	-- Always unload, including on failure: a live spare slot would break the next caller and would
	-- leave a whole map resident for the rest of the session.
	local unload_ok, unload_error = pcall(change_map_in_slot, slot, "")
	if not unload_ok then
		trace("WARNING failed to unload slot %d: %s", slot, tostring(unload_error))
	end

	if failure then
		trace("FAILED %s: %s", tostring(map_name), failure)
		return nil, failure
	end

	local elapsed = (SafeCall(Global("GetPreciseTicks")) or 0) - started
	Oracle.Cache[map_name] = markers
	local parts = {}
	for index, marker in ipairs(markers) do
		parts[#parts + 1] = string.format("%d=(%d,%d)@%d", index, marker.x, marker.y, marker.angle)
	end
	trace("read %s slot=%d ms=%d size=%s markers=%d %s", map_name, slot, elapsed,
		tostring(markers.height_map_size), #markers, table.concat(parts, " "))
	return markers
end

-- Markers for the underground map this surface will get, in source coordinates.
function Oracle.SourceEntrances(surface_map)
	local name, pick_error = Oracle.PickUndergroundMapName(surface_map)
	if not name then return nil, pick_error end
	local markers, read_error = Oracle.ReadVanillaEntrances(name)
	if not markers then return nil, read_error end
	return markers, name
end

-- The same markers moved onto the expanded map.  The stretch is the mod's canonical one: destination
-- world position = source world position * desired/source tiles, per axis.
function Oracle.ExpandedEntrances(destination_map, surface_map)
	if type(destination_map) ~= "table" then
		return nil, "no destination map"
	end
	local desired_w = tonumber(destination_map.SuperBigMapDesiredWidthTiles)
	local desired_h = tonumber(destination_map.SuperBigMapDesiredHeightTiles)
	local source_w = tonumber(destination_map.SuperBigMapGeneratorWidthTiles)
		or tonumber(destination_map.SuperBigMapSourceWidthTiles)
	local source_h = tonumber(destination_map.SuperBigMapGeneratorHeightTiles)
		or tonumber(destination_map.SuperBigMapSourceHeightTiles)
	if not desired_w or not desired_h or not source_w or not source_h
		or source_w <= 0 or source_h <= 0 then
		return nil, "destination map has no expanded source geometry"
	end

	local markers, name_or_error = Oracle.SourceEntrances(surface_map or destination_map)
	if not markers then return nil, name_or_error end

	-- A blank underground sized differently from the vanilla surface source would break the
	-- calibration; fail loudly rather than place both entrances in the wrong place.
	local size = tonumber(markers.height_map_size)
	if size and (size ~= source_w or size ~= source_h) then
		return nil, string.format(
			"blank underground is %sx%s but the surface source is %sx%s", tostring(size),
			tostring(size), tostring(source_w), tostring(source_h))
	end

	local scale_x = (desired_w + 0.0) / source_w
	local scale_y = (desired_h + 0.0) / source_h
	local expanded = { source_map_name = name_or_error, scale_x = scale_x, scale_y = scale_y }
	for index, marker in ipairs(markers) do
		expanded[index] = {
			x = math.floor(marker.x * scale_x + 0.5),
			y = math.floor(marker.y * scale_y + 0.5),
			angle = marker.angle,
			source_x = marker.x,
			source_y = marker.y,
		}
	end
	local parts = {}
	for index, marker in ipairs(expanded) do
		parts[#parts + 1] = string.format("%d=(%d,%d)@%d<-(%d,%d)", index, marker.x, marker.y,
			marker.angle, marker.source_x, marker.source_y)
	end
	trace("expanded %s scale=%.4f/%.4f %s", tostring(name_or_error), scale_x, scale_y,
		table.concat(parts, " "))
	return expanded
end

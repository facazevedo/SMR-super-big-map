-- TEMPORARY diagnostic module -- REMOVE BEFORE RELEASE, and remove from metadata.lua 'code'.
--
-- One consolidated dump for the four open problems, so a single in-game run produces every fact
-- instead of needing a rebuild per question:
--
--   1. entrance badges      do the signs exist, in which sector, revealed, visible, at what scale
--   2. concrete/regolith    every TerrainDeposit with its sector, that sector's status, visibility
--   3. sector reveal        how many sectors are non-unexplored at each moment, and which
--   4. underground access   lazy descriptor state, capsule count, live re-entry count/sequence,
--                           the passage pair on each side and their hex separation
--
-- Every read is wrapped so the dump can never break generation. Output is one [SBM DUMP] line per
-- fact, prefixed with the call-site tag.

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall

local Dump = {}
SuperBigMap.ProblemDump = Dump

local function say(tag, key, value)
	print(string.format("[SBM DUMP] %s %s=%s", tostring(tag), tostring(key), tostring(value)))
end

local function hex_of(pos)
	local world_to_hex = Global("WorldToHex")
	if type(world_to_hex) ~= "function" or not pos then return "?", "?" end
	local ok, q, r = pcall(world_to_hex, pos)
	if not ok then return "?", "?" end
	return tostring(q), tostring(r)
end

-- Sector lookup by area containment. GetMapSectorXY is not reliably reachable from every context,
-- and the grid's own iterator is what the mod already trusts elsewhere.
local function sector_index(map)
	local list = {}
	local city = map and map.City
	local grid = SuperBigMap.SectorGrid
	if not city or type(grid) ~= "table" or type(grid.ForEachSector) ~= "function" then
		return list
	end
	pcall(grid.ForEachSector, city, function(sector)
		local area = sector and sector.area
		if not area then return end
		local ok, mn, mx = pcall(function() return area:min(), area:max() end)
		if not ok or not mn or not mx then return end
		local x0, y0 = mn:xy()
		local x1, y1 = mx:xy()
		list[#list + 1] = {
			id = tostring(sector.id), status = tostring(sector.status),
			x0 = x0, y0 = y0, x1 = x1, y1 = y1,
		}
	end)
	return list
end

local function sector_at(list, x, y)
	if type(x) ~= "number" or type(y) ~= "number" then return "?", "?" end
	for _, s in ipairs(list) do
		if x >= s.x0 and x < s.x1 and y >= s.y0 and y < s.y1 then return s.id, s.status end
	end
	return "none", "none"
end

local function object_xy(obj)
	local pos = obj and type(obj.GetPos) == "function" and SafeCall(obj.GetPos, obj) or nil
	if not pos or type(pos.xy) ~= "function" then return nil, nil, nil end
	local x, y = pos:xy()
	return x, y, pos
end

function Dump.Run(tag, map)
	map = map or Global("CurrentMap")
	if not map or type(map.MapForEach) ~= "function" then
		say(tag, "map", "unavailable")
		return
	end
	local sectors = sector_index(map)
	local scanned, scanned_ids = 0, {}
	for _, s in ipairs(sectors) do
		if s.status ~= "unexplored" and s.status ~= "nil" then
			scanned = scanned + 1
			scanned_ids[#scanned_ids + 1] = s.id .. "=" .. s.status
		end
	end
	say(tag, "sectors_total", #sectors)
	say(tag, "sectors_revealed", scanned)
	say(tag, "revealed_ids", table.concat(scanned_ids, ","))

	-- 1. entrance badges
	local signs = 0
	pcall(map.MapForEach, map, "map", "SurfaceUndergroundTunnelSign", function(sign)
		signs = signs + 1
		local x, y = object_xy(sign)
		local sid, sstatus = sector_at(sectors, x, y)
		say(tag, "sign" .. signs, string.format(
			"sector=%s:%s revealed=%s visible=%s scale=%s opacity=%s",
			sid, sstatus, tostring(sign.revealed),
			tostring(type(sign.GetVisible) == "function" and SafeCall(sign.GetVisible, sign)),
			tostring(type(sign.GetScale) == "function" and SafeCall(sign.GetScale, sign)),
			tostring(type(sign.GetOpacity) == "function" and SafeCall(sign.GetOpacity, sign))))
	end)
	say(tag, "entrance_signs", signs)
	local const_tbl = Global("const")
	say(tag, "overview_scale_up", type(const_tbl) == "table"
		and const_tbl.SignsOverviewCameraScaleUp or "?")
	local is_overview = Global("IsOverviewMode")
	say(tag, "overview_active", type(is_overview) == "function"
		and SafeCall(is_overview) == true or "?")

	-- 2. concrete / regolith deposits
	local deposits = 0
	pcall(map.MapForEach, map, "map", "TerrainDeposit", function(obj)
		deposits = deposits + 1
		local x, y = object_xy(obj)
		local sid, sstatus = sector_at(sectors, x, y)
		say(tag, "terrain_deposit" .. deposits, string.format("class=%s sector=%s:%s visible=%s",
			tostring(obj.class), sid, sstatus,
			tostring(type(obj.GetVisible) == "function" and SafeCall(obj.GetVisible, obj))))
	end)
	say(tag, "terrain_deposits", deposits)

	-- 4. underground access state
	local descriptor = map.SuperBigMapLazyUndergroundDescriptor
	local report = map.SuperBigMapLazyUndergroundFeasibilityReport
	say(tag, "descriptor_state", type(descriptor) == "table" and descriptor.state or "none")
	say(tag, "descriptor_capsules", type(descriptor) == "table"
		and type(descriptor.capsules) == "table" and #descriptor.capsules or "none")
	if type(report) == "table" then
		say(tag, "capsules_published", report.capsules_published)
		say(tag, "live_reentry_count", report.persisted_state_live_reentry_count)
		say(tag, "live_reentry_sequence", report.persisted_state_live_reentry_phase_sequence)
		say(tag, "final_grid_revalidation", report.final_grid_revalidation)
	end
	say(tag, "blocked_reason", map.SuperBigMapLazyUndergroundBlockedReason)

	-- 3/4. passage pair positions and their separation
	local surface_side = {}
	pcall(map.MapForEach, map, "map", "UndergroundPassage", function(obj)
		local x, y, pos = object_xy(obj)
		local q, r = hex_of(pos)
		local sid, sstatus = sector_at(sectors, x, y)
		surface_side[#surface_side + 1] = { x = x, y = y, q = q, r = r, id = sid, st = sstatus }
		say(tag, "surface_passage" .. #surface_side, string.format(
			"world=%s,%s hex=%s:%s sector=%s:%s linked=%s",
			tostring(x), tostring(y), q, r, sid, sstatus, tostring(obj.other ~= nil)))
	end)
	say(tag, "surface_passages", #surface_side)
	local underground = Global("UndergroundMap")
	if underground and type(underground.MapForEach) == "function" then
		local n = 0
		pcall(underground.MapForEach, underground, "map", "SurfacePassage", function(obj)
			n = n + 1
			local x, y, pos = object_xy(obj)
			local q, r = hex_of(pos)
			local peer = surface_side[n]
			local separation = "?"
			if peer and type(x) == "number" and type(peer.x) == "number" then
				local dx, dy = x - peer.x, y - peer.y
				separation = tostring(math.floor(math.sqrt(dx * dx + dy * dy) + 0.5))
			end
			say(tag, "underground_passage" .. n, string.format(
				"world=%s,%s hex=%s:%s linked=%s world_distance_to_surface_peer=%s",
				tostring(x), tostring(y), q, r, tostring(obj.other ~= nil), separation))
		end)
		say(tag, "underground_passages", n)
	else
		say(tag, "underground_passages", "no underground map")
	end
end

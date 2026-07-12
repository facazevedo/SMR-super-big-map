-- Super Big Map -- exhaustive surface entrance / underground exit position diagnostics.
-- Read-only and fully gated by config.DebugEntrancePositions (DEBUG_ENTRANCEPOSITIONS).

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local IsKindOfSafe = Engine.IsKindOf
local ObjectPos = Engine.ObjectPos
local SCOPE = "EntrancePositions"

local function DebugOn()
	local log = SuperBigMap.DebugLog
	return log and log.On and log.On(SCOPE) == true
end

local function Log(message, data)
	local log = SuperBigMap.DebugLog
	if log then log.Info(SCOPE, message, data) end
end

local function Warn(message, data)
	local log = SuperBigMap.DebugLog
	if log then log.Warn(SCOPE, message, data) end
end

local function PointXYZ(pos)
	if not pos then return nil, nil, nil end
	local ok, x, y, z = pcall(function()
		local px, py = pos:xy()
		local pz = type(pos.z) == "function" and pos:z() or nil
		return px, py, pz
	end)
	if ok then return x, y, z end
	return nil, nil, nil
end

local function MapEnvironment(map)
	local md = map and map.mapdata
	return type(md) == "table" and tostring(md.Environment or "?") or "?"
end

local function MapName(map)
	local md = map and map.mapdata
	return tostring((type(md) == "table" and md.id) or (map and map.name) or "?")
end

local function ObjectMap(obj)
	if obj and type(obj.GetMap) == "function" then
		local map = SafeCall(obj.GetMap, obj)
		if map then return map end
	end
	return nil
end

local ENTRANCE_KINDS = {
	"SpawnsTunnelOnCityInit",
	"SurfaceUndergroundTunnelMarker",
	"SurfaceUndergroundTunnelSign",
	"ElevatorPassage",
}

local CLASS_TOKENS = {
	"SurfacePassage",
	"UndergroundPassage",
	"SurfaceTunnelMarker",
	"UndergroundTunnelMarker",
	"SurfaceUndergroundTunnel",
	"ElevatorPassage",
	"TunnelSign",
}

local function EntranceKinds(obj)
	local kinds = {}
	for _, kind in ipairs(ENTRANCE_KINDS) do
		if IsKindOfSafe(obj, kind) then kinds[#kinds + 1] = kind end
	end
	return kinds
end

local function IsEntranceObject(obj)
	if not obj then return false end
	for _, kind in ipairs(ENTRANCE_KINDS) do
		if IsKindOfSafe(obj, kind) then return true end
	end
	local class = tostring(obj.class or "")
	for _, token in ipairs(CLASS_TOKENS) do
		if class:find(token, 1, true) then return true end
	end
	return false
end

local function HexAt(pos)
	local world_to_hex = Global("WorldToHex")
	if not pos or type(world_to_hex) ~= "function" then return nil, nil end
	local ok, q, r = pcall(world_to_hex, pos)
	if ok and type(q) == "number" and type(r) == "number" then return q, r end
	return nil, nil
end

local function TerrainFacts(map, pos, q, r)
	local terrain_api = Global("terrain")
	local terrain_z, passable = nil, nil
	if type(terrain_api) == "table" then
		if type(terrain_api.GetHeight) == "function" then
			local ok, value = pcall(terrain_api.GetHeight, map, pos)
			if ok then terrain_z = value end
		end
		if type(terrain_api.IsPassable) == "function" then
			local ok, value = pcall(terrain_api.IsPassable, map, pos)
			if ok then passable = value == true end
		end
	end
	local build_z, sentinel, buildable = nil, nil, nil
	local grid = map and map.buildable
	if grid and type(grid.GetZ) == "function" and type(q) == "number" then
		local ok, value = pcall(grid.GetZ, grid, q, r)
		if ok then build_z = value end
		local unbuildable = Global("buildUnbuildableZ")
		if type(unbuildable) == "function" then
			local ok_u, value_u = pcall(unbuildable)
			if ok_u then sentinel = value_u end
		end
		if build_z ~= nil and sentinel ~= nil then buildable = build_z ~= sentinel end
	end
	return terrain_z, passable, build_z, sentinel, buildable
end

local function SectorFacts(map, x, y)
	local city = map and map.City
	local get_sector = Global("GetMapSectorXY")
	if not city or type(get_sector) ~= "function" or type(x) ~= "number" then
		return "nil", "nil", "nil"
	end
	local ok, sector = pcall(get_sector, city, x, y)
	if not ok or not sector then return "nil", "nil", "nil" end
	return tostring(sector.id or "?"), tostring(sector.col or "?"), tostring(sector.row or "?")
end

local function LinkedFacts(obj, x, y)
	local linked = obj and (obj.other or obj.linked_obj)
	if not linked then return {} end
	local linked_pos = ObjectPos(linked)
	local lx, ly, lz = PointXYZ(linked_pos)
	local lq, lr = HexAt(linked_pos)
	local linked_map = ObjectMap(linked)
	return {
		linked_class = tostring(linked.class or "?"),
		linked_handle = tostring(linked.handle or "?"),
		linked_map = MapName(linked_map),
		linked_env = MapEnvironment(linked_map),
		linked_x = tostring(lx), linked_y = tostring(ly), linked_z = tostring(lz),
		linked_q = tostring(lq), linked_r = tostring(lr),
		linked_dx = type(x) == "number" and type(lx) == "number" and (lx - x) or "?",
		linked_dy = type(y) == "number" and type(ly) == "number" and (ly - y) or "?",
	}
end

local function DescribeObject(map, obj, index, phase)
	local pos = ObjectPos(obj)
	local x, y, z = PointXYZ(pos)
	local q, r = HexAt(pos)
	local terrain_z, passable, build_z, sentinel, buildable = TerrainFacts(map, pos, q, r)
	local sector, sector_col, sector_row = SectorFacts(map, x, y)
	local angle = type(obj.GetAngle) == "function" and SafeCall(obj.GetAngle, obj) or nil
	local entity = type(obj.GetEntity) == "function" and SafeCall(obj.GetEntity, obj) or obj.entity
	local vx, vy, vz
	if type(obj.GetVisualPosXYZ) == "function" then
		vx, vy, vz = SafeCall(obj.GetVisualPosXYZ, obj)
	end
	local kinds = EntranceKinds(obj)
	local is_anchor = IsKindOfSafe(obj, "ElevatorPassage")
		or IsKindOfSafe(obj, "SurfaceUndergroundTunnelMarker")
		or IsKindOfSafe(obj, "SpawnsTunnelOnCityInit")
	local rec = {
		obj = obj, map = map, phase = phase, index = index,
		class = tostring(obj.class or "?"), handle = tostring(obj.handle or "?"),
		env = MapEnvironment(map), map_name = MapName(map), map_ref = tostring(map),
		x = x, y = y, z = z, q = q, r = r, anchor = is_anchor == true,
	}
	local data = {
		phase = phase, index = index, map = rec.map_name, map_ref = rec.map_ref, env = rec.env,
		class = rec.class, handle = rec.handle, kinds = table.concat(kinds, "+"), anchor = rec.anchor,
		x = tostring(x), y = tostring(y), z = tostring(z), q = tostring(q), r = tostring(r),
		visual_x = tostring(vx), visual_y = tostring(vy), visual_z = tostring(vz),
		terrain_z = tostring(terrain_z), dz_terrain = type(z) == "number" and type(terrain_z) == "number"
			and (z - terrain_z) or "?",
		passable = tostring(passable), buildable = tostring(buildable), build_z = tostring(build_z),
		unbuildable_sentinel = tostring(sentinel), sector = sector, sector_col = sector_col,
		sector_row = sector_row, angle = tostring(angle), entity = tostring(entity),
		is_placed = tostring(obj.is_placed), permanent = tostring(obj.permanent),
		quadrant_clone = tostring(obj.SuperBigMapQuadrantClone), visuals_moved = tostring(obj.SuperBigMapEntranceVisualsMoved),
	}
	for k, v in pairs(LinkedFacts(obj, x, y)) do data[k] = v end
	Log("object", data)
	return rec
end

local function CollectMap(map, phase)
	local records = {}
	if not map or type(map.MapForEach) ~= "function" then
		Warn("map unavailable", { phase = phase, map = tostring(map) })
		return records
	end
	local w, h = Engine.MapWorldSize(map)
	Log("map begin", {
		phase = phase, map = MapName(map), map_ref = tostring(map), env = MapEnvironment(map),
		world_w = tostring(w), world_h = tostring(h), mapdata_w = tostring(map.mapdata and map.mapdata.Width),
		mapdata_h = tostring(map.mapdata and map.mapdata.Height), source_tiles = tostring(map.SuperBigMapSourceWidthTiles),
		generator_tiles = tostring(map.SuperBigMapGeneratorWidthTiles), desired_tiles = tostring(map.SuperBigMapDesiredWidthTiles),
		markers_scaled = tostring(map.SuperBigMapMarkersScaled), visuals_moved = tostring(map.SuperBigMapEntranceVisualsMoved),
	})
	local objects = {}
	pcall(map.MapForEach, map, "map", "CObject", function(obj)
		if IsEntranceObject(obj) then objects[#objects + 1] = obj end
	end)
	table.sort(objects, function(a, b)
		local ac, bc = tostring(a.class or ""), tostring(b.class or "")
		if ac ~= bc then return ac < bc end
		local ap, bp = ObjectPos(a), ObjectPos(b)
		local ax, ay = PointXYZ(ap)
		local bx, by = PointXYZ(bp)
		if ax ~= bx then return (ax or -1) < (bx or -1) end
		if ay ~= by then return (ay or -1) < (by or -1) end
		return tostring(a.handle or "") < tostring(b.handle or "")
	end)
	local by_class = {}
	for i, obj in ipairs(objects) do
		local rec = DescribeObject(map, obj, i, phase)
		records[#records + 1] = rec
		by_class[rec.class] = (by_class[rec.class] or 0) + 1
	end
	local class_keys = {}
	for class in pairs(by_class) do class_keys[#class_keys + 1] = class end
	table.sort(class_keys)
	local class_parts = {}
	for _, class in ipairs(class_keys) do class_parts[#class_parts + 1] = class .. "=" .. tostring(by_class[class]) end
	Log("map end", {
		phase = phase, map = MapName(map), env = MapEnvironment(map), total = #records,
		by_class = table.concat(class_parts, " "),
	})
	return records
end

local function DiscoverMaps(focus_map)
	local maps, seen = {}, {}
	local function add(map)
		if type(map) == "table" and type(map.MapForEach) == "function" and not seen[map] then
			seen[map] = true
			maps[#maps + 1] = map
		end
	end
	add(focus_map)
	add(Global("MainMap"))
	add(Global("CurrentMap"))
	local all_maps = Global("Maps")
	if type(all_maps) == "table" then
		for _, map in pairs(all_maps) do add(map) end
	end
	table.sort(maps, function(a, b)
		local ae, be = MapEnvironment(a), MapEnvironment(b)
		if ae ~= be then return ae < be end
		return MapName(a) < MapName(b)
	end)
	return maps
end

local function Pairwise(records, phase)
	local surface, underground = {}, {}
	for _, rec in ipairs(records) do
		if rec.anchor and rec.env == "Surface" then surface[#surface + 1] = rec end
		if rec.anchor and rec.env == "Underground" then underground[#underground + 1] = rec end
	end
	Log("pairwise begin", { phase = phase, surface = #surface, underground = #underground })
	local best_surface, best_underground = {}, {}
	local surface_exact, surface_mismatch = 0, 0
	local underground_exact, underground_mismatch = 0, 0
	for si, s in ipairs(surface) do
		for ui, u in ipairs(underground) do
			local dx = type(s.x) == "number" and type(u.x) == "number" and (s.x - u.x) or nil
			local dy = type(s.y) == "number" and type(u.y) == "number" and (s.y - u.y) or nil
			local dz = type(s.z) == "number" and type(u.z) == "number" and (s.z - u.z) or nil
			local world_dist = dx and dy and math.floor(math.sqrt(dx * dx + dy * dy) + 0.5) or nil
			local dq = type(s.q) == "number" and type(u.q) == "number" and (s.q - u.q) or nil
			local dr = type(s.r) == "number" and type(u.r) == "number" and (s.r - u.r) or nil
			local hex_dist = dq and dr and (math.abs(dq) + math.abs(dr) + math.abs(dq + dr)) / 2 or nil
			Log("pair", {
				phase = phase, surface_index = si, underground_index = ui,
				surface = s.class .. "#" .. s.handle, underground = u.class .. "#" .. u.handle,
				surface_map = s.map_name, underground_map = u.map_name,
				surface_xy = tostring(s.x) .. "," .. tostring(s.y), underground_xy = tostring(u.x) .. "," .. tostring(u.y),
				surface_hex = tostring(s.q) .. "," .. tostring(s.r), underground_hex = tostring(u.q) .. "," .. tostring(u.r),
				dx = tostring(dx), dy = tostring(dy), dz = tostring(dz), world_dist = tostring(world_dist),
				dq = tostring(dq), dr = tostring(dr), hex_dist = tostring(hex_dist), exact_hex = tostring(hex_dist == 0),
			})
			if world_dist and (not best_surface[si] or world_dist < best_surface[si].dist) then
				best_surface[si] = { index = ui, dist = world_dist, hex_dist = hex_dist, dx = dx, dy = dy }
			end
			if world_dist and (not best_underground[ui] or world_dist < best_underground[ui].dist) then
				best_underground[ui] = { index = si, dist = world_dist, hex_dist = hex_dist, dx = dx, dy = dy }
			end
		end
	end
	for si, best in pairs(best_surface) do
		local s, u = surface[si], underground[best.index]
		local data = {
			phase = phase, surface = s.class .. "#" .. s.handle, underground = u.class .. "#" .. u.handle,
			world_dist = best.dist, hex_dist = tostring(best.hex_dist), dx = best.dx, dy = best.dy,
			exact_hex = tostring(best.hex_dist == 0),
		}
		if best.hex_dist == 0 then
			surface_exact = surface_exact + 1
			Log("best surface match", data)
		else
			surface_mismatch = surface_mismatch + 1
			Warn("best surface mismatch", data)
		end
	end
	for ui, best in pairs(best_underground) do
		local u, s = underground[ui], surface[best.index]
		local data = {
			phase = phase, underground = u.class .. "#" .. u.handle, surface = s.class .. "#" .. s.handle,
			world_dist = best.dist, hex_dist = tostring(best.hex_dist), dx = best.dx, dy = best.dy,
			exact_hex = tostring(best.hex_dist == 0),
		}
		if best.hex_dist == 0 then
			underground_exact = underground_exact + 1
			Log("best underground match", data)
		else
			underground_mismatch = underground_mismatch + 1
			Warn("best underground mismatch", data)
		end
	end
	Log("pairwise end", {
		phase = phase, surface = #surface, underground = #underground,
		surface_exact = surface_exact, surface_mismatch = surface_mismatch,
		underground_exact = underground_exact, underground_mismatch = underground_mismatch,
	})
end

local EntranceDebug = {}

function EntranceDebug.SnapshotAll(phase, focus_map)
	if not DebugOn() then return false end
	phase = tostring(phase or "unspecified")
	local maps = DiscoverMaps(focus_map)
	Log("snapshot begin", { phase = phase, maps = #maps, focus_map = MapName(focus_map) })
	local records = {}
	for _, map in ipairs(maps) do
		local map_records = CollectMap(map, phase)
		for _, rec in ipairs(map_records) do records[#records + 1] = rec end
	end
	Pairwise(records, phase)
	Log("snapshot end", { phase = phase, maps = #maps, objects = #records })
	return true
end

function EntranceDebug.LogLink(a, b, phase)
	if not DebugOn() then return false end
	local function side(prefix, obj, out)
		local map = ObjectMap(obj)
		local pos = ObjectPos(obj)
		local x, y, z = PointXYZ(pos)
		local q, r = HexAt(pos)
		out[prefix .. "_class"] = tostring(obj and obj.class or "?")
		out[prefix .. "_handle"] = tostring(obj and obj.handle or "?")
		out[prefix .. "_map"] = MapName(map)
		out[prefix .. "_env"] = MapEnvironment(map)
		out[prefix .. "_x"], out[prefix .. "_y"], out[prefix .. "_z"] = tostring(x), tostring(y), tostring(z)
		out[prefix .. "_q"], out[prefix .. "_r"] = tostring(q), tostring(r)
		return x, y, q, r
	end
	local data = { phase = tostring(phase or "link") }
	local ax, ay, aq, ar = side("a", a, data)
	local bx, by, bq, br = side("b", b, data)
	local dx = type(ax) == "number" and type(bx) == "number" and (ax - bx) or nil
	local dy = type(ay) == "number" and type(by) == "number" and (ay - by) or nil
	local dq = type(aq) == "number" and type(bq) == "number" and (aq - bq) or nil
	local dr = type(ar) == "number" and type(br) == "number" and (ar - br) or nil
	data.dx, data.dy = tostring(dx), tostring(dy)
	data.world_dist = tostring(dx and dy and math.floor(math.sqrt(dx * dx + dy * dy) + 0.5) or nil)
	data.dq, data.dr = tostring(dq), tostring(dr)
	local hex_dist = dq and dr and (math.abs(dq) + math.abs(dr) + math.abs(dq + dr)) / 2 or nil
	data.hex_dist = tostring(hex_dist)
	data.exact_hex = tostring(hex_dist == 0)
	if hex_dist == 0 then Log("link", data) else Warn("link mismatch", data) end
	return true
end

SuperBigMap.EntranceDebug = EntranceDebug

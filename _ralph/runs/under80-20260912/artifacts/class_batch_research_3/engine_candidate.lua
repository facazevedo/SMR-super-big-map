-- Super Big Map -- narrow shared engine-access helpers.
--
-- This is the only shared "misc" module, and it is deliberately bounded to ONE
-- responsibility: safe, guarded access to the Surviving Mars Relaunched engine
-- (global lookup, protected calls, object/class queries, live-map size, message-hook
-- chaining, numeric helpers). Do NOT add domain logic here -- sector/overview/map-gen
-- behavior belongs in its own sbm_<domain> module.
--
-- NOTE on terrain size: Engine.TerrainSize / Engine.MapWorldSize here serve the LIVE-map
-- and assert-free (mapdata x tile) cases. The map-generation module keeps its OWN
-- gen-time TerrainSize because during generation the size is in flux and map:GetMapSize
-- can assert -- it must read mapdata.Width x HeightTileSize in a particular order there.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = {}
local type, pcall = type, pcall

-- Read a global by name without invoking metatables.
function Engine.Global(name)
	return rawget(_G, name)
end

-- pcall wrapper that returns the result(s) on success, nil on failure. Returns up to
-- three results (enough for every call site in the mod).
function Engine.SafeCall(fn, ...)
	if type(fn) ~= "function" then
		return nil
	end
	local ok, result, result2, result3 = pcall(fn, ...)
	if ok then
		return result, result2, result3
	end
	return nil
end

-- pcall wrapper that returns the raw (ok, ...) tuple.
function Engine.TryCall(fn, ...)
	if type(fn) ~= "function" then
		return false
	end
	return pcall(fn, ...)
end

-- Lua 5.3/5.4 table.unpack with a fallback to the global unpack.
function Engine.Unpack(t, first, last)
	local unpack_fn = table.unpack or rawget(_G, "unpack")
	return unpack_fn(t, first, last)
end

function Engine.Round(value)
	return math.floor(value + 0.5)
end

function Engine.ClampNumber(value, min_value, max_value)
	local clamp = rawget(_G, "Clamp")
	if type(clamp) == "function" then
		return clamp(value, min_value, max_value)
	end
	return math.max(min_value, math.min(max_value, value))
end

function Engine.FullHeightMin()
	return rawget(_G, "min_int") or -2147483647
end

function Engine.FullHeightMax()
	return rawget(_G, "max_int") or 2147483647
end

-- Resolve a class table by name (direct global or via g_Classes). Returns the
-- table or false.
function Engine.ClassTable(name)
	local global_class = rawget(_G, name)
	if type(global_class) == "table" then
		return global_class
	end
	local classes = rawget(_G, "g_Classes")
	local class_table = type(classes) == "table" and classes[name]
	return type(class_table) == "table" and class_table or false
end

-- True if obj is (or derives from) the named engine class. Uses the global IsKindOf when
-- present, else the object's own :IsKindOf. Safe against asserting userdata.
function Engine.IsKindOf(obj, class)
	if obj == nil then
		return false
	end
	local is_kind_of = rawget(_G, "IsKindOf")
	if type(is_kind_of) == "function" then
		return Engine.SafeCall(is_kind_of, obj, class) == true
	end
	if type(obj.IsKindOf) == "function" then
		return Engine.SafeCall(obj.IsKindOf, obj, class) == true
	end
	return false
end

-- Native list negatives can avoid repeated protected scalar queries. Capture
-- identities only to qualify the known native pair; never cache class results.
local canonical_single_kind = Engine.IsKindOf
local canonical_safe_call = Engine.SafeCall
local native_single_kind = Engine.Global("IsKindOf")
local native_many_kinds = Engine.Global("IsKindOfClasses")
-- debug is intentionally unavailable in the mod sandbox. Use the standard
-- serialization distinction instead: Lua functions dump, native C functions
-- do not. Verify both sides once; an unavailable/unexpected protocol disables
-- batching rather than changing the sandbox or assuming a function is native.
local string_api = Engine.Global("string")
local function_dump = type(string_api) == "table" and string_api.dump
local native_dump_error
if type(function_dump) == "function" then
	local lua_ok, lua_bytes = pcall(function_dump, function() return true end)
	local native_ok, native_error = pcall(function_dump, pcall)
	if lua_ok and type(lua_bytes) == "string" and not native_ok and type(native_error) == "string" then
		native_dump_error = native_error
	end
end
local function IsNativeClassPrimitive(fn)
	if type(fn) ~= "function" or not native_dump_error then return false end
	local ok, value = pcall(function_dump, fn)
	return not ok and value == native_dump_error
end
local native_kind_pair = IsNativeClassPrimitive(native_single_kind)
	and IsNativeClassPrimitive(native_many_kinds)

-- Return the first matching list entry and the scalar predicate's value.
-- A negative native result is final only while every qualified identity is live.
-- Positive/failed native queries, custom helpers and rebinding retain the exact
-- original ordered scalar calls (including the last false/nil return value).
function Engine.FirstKindOf(obj, classes, single_kind)
	single_kind = single_kind or Engine.IsKindOf
	if native_kind_pair and type(obj) == "table" and #classes > 0
		and single_kind == canonical_single_kind
		and Engine.IsKindOf == canonical_single_kind
		and Engine.SafeCall == canonical_safe_call
		and rawget(_G, "IsKindOf") == native_single_kind
		and rawget(_G, "IsKindOfClasses") == native_many_kinds then
		local ok, value = pcall(native_many_kinds, obj, classes)
		if ok and value == false then return nil, false end
	end
	local last_value
	for i = 1, #classes do
		last_value = single_kind(obj, classes[i])
		if last_value then return classes[i], last_value end
	end
	return nil, last_value
end

-- Best-effort world position of an object: GetPos, then visual-position fallbacks.
-- Returns a point, or false when no position is resolvable.
function Engine.ObjectPos(obj)
	if not obj then
		return false
	end
	if type(obj.GetPos) == "function" then
		local pos = Engine.SafeCall(obj.GetPos, obj)
		if pos then
			return pos
		end
	end
	local point_fn = rawget(_G, "point")
	if type(obj.GetVisualPosXYZ) == "function" and type(point_fn) == "function" then
		local x, y, z = Engine.SafeCall(obj.GetVisualPosXYZ, obj)
		if x and y then
			return point_fn(x, y, z or 0)
		end
	end
	if type(obj.GetVisualPos) == "function" then
		local pos = Engine.SafeCall(obj.GetVisualPos, obj)
		if pos then
			return pos
		end
	end
	return false
end

-- True when map is a live, valid game map (has mapdata and passes IsValid).
function Engine.IsLiveMap(map)
	if not map or type(map) ~= "table" then
		return false
	end
	if type(map.IsValid) == "function" and not Engine.SafeCall(map.IsValid, map) then
		return false
	end
	if not map.mapdata then
		return false
	end
	return true
end

-- World-unit size (width, height) of a LIVE map. Prefers the cached map.Width/Height
-- MapVars (world units), then terrain.GetMapSize, then map:GetMapSize; 0,0 if not live.
-- During map GENERATION use sbm_map_generation's own assert-free TerrainSize instead.
function Engine.TerrainSize(map)
	if not Engine.IsLiveMap(map) then
		return 0, 0
	end
	if type(map.Width) == "number" and type(map.Height) == "number" and map.Width > 0 and map.Height > 0 then
		return map.Width, map.Height
	end
	local terrain_api = rawget(_G, "terrain")
	if terrain_api and type(terrain_api.GetMapSize) == "function" then
		local width, height = Engine.SafeCall(terrain_api.GetMapSize, map)
		if width and height then
			return width, height
		end
	end
	if type(map.GetMapSize) == "function" then
		local width, height = Engine.SafeCall(map.GetMapSize, map)
		if width and height then
			return width, height
		end
	end
	return map.Width or 0, map.Height or 0
end

-- World size as (width, height, tile) from mapdata.Width x const.HeightTileSize -- the
-- assert-free form (never calls GetMapSize), used by terrain-grid code. nil if unavailable.
function Engine.MapWorldSize(map)
	local mapdata = map and map.mapdata
	local const_tbl = rawget(_G, "const")
	local tile = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number"
		and const_tbl.HeightTileSize > 0) and const_tbl.HeightTileSize or nil
	if type(mapdata) == "table" and type(mapdata.Width) == "number" and type(mapdata.Height) == "number"
		and type(tile) == "number" then
		return mapdata.Width * tile, mapdata.Height * tile, tile
	end
	return nil
end

-- Random integer in [0, n-1]. Prefers the engine RNG (AsyncRand); falls back to a small
-- LCG so placement still varies if AsyncRand is unavailable.
local rng_seed = 0x4d2 * 7919
function Engine.RandInt(n)
	if n <= 0 then
		return 0
	end
	local async_rand = rawget(_G, "AsyncRand")
	if type(async_rand) == "function" then
		local ok, value = pcall(async_rand, n)
		if ok and type(value) == "number" and value >= 0 and value < n then
			return value
		end
	end
	rng_seed = (rng_seed * 1103515245 + 12345) % 2147483648
	return rng_seed % n
end

-- Append a handler to an OnMsg entry, preserving any previously-registered one.
function Engine.ChainOnMsg(message_name, handler)
	local OnMsg = rawget(_G, "OnMsg")
	if type(OnMsg) ~= "table" then
		return
	end
	local previous = OnMsg[message_name]
	OnMsg[message_name] = function(...)
		if previous then
			previous(...)
		end
		handler(...)
	end
end

SuperBigMap.Engine = Engine

-- Bigger Maps -- narrow shared engine-access helpers.
--
-- This is the only shared "misc" module, and it is deliberately bounded to ONE
-- responsibility: safe, guarded access to the Surviving Mars Relaunched engine
-- (global lookup, protected calls, message-hook chaining, class lookup, numeric
-- helpers). Do NOT add domain logic here -- sector/overview/map-gen code belongs
-- in its own bm_<domain> module.
--
-- NOTE: TerrainSize / map-liveness / the generator infinite-loop guard are NOT
-- here on purpose. Their behavior is context-specific (e.g. the map-generation
-- module temporarily overrides terrain.GetMapSize during generation, so it must
-- read terrain size in a particular order), so each owning module keeps its own.

local BiggerMaps = rawget(_G, "BiggerMaps")
if type(BiggerMaps) ~= "table" then
	BiggerMaps = {}
	rawset(_G, "BiggerMaps", BiggerMaps)
end

local Engine = {}

-- Read a global by name without invoking metatables.
function Engine.Global(name)
	return rawget(_G, name)
end

-- pcall wrapper that returns the result(s) on success, nil on failure.
function Engine.SafeCall(fn, ...)
	if type(fn) ~= "function" then
		return nil
	end
	local ok, result, result2 = pcall(fn, ...)
	if ok then
		return result, result2
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

BiggerMaps.Engine = Engine

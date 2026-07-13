-- Super Big Map -- exhaustive, observational loading-performance profiler.
-- Strictly gated by config.DebugLoadingSteps (DEBUG_LOADINGSTEPS). This module never
-- sleeps, yields, schedules work, changes ordering, or invokes gameplay operations.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local state = {
	active = false,
	session = 0,
	sequence = 0,
	started_at = 0,
	last_at = 0,
	depth = 0,
}

local function Enabled()
	return (SuperBigMap.Config or {}).DEBUG_LOADINGSTEPS == true
end

local function Now()
	local fn = Global("GetPreciseTicks") or Global("RealTime")
	if type(fn) == "function" then
		local ok, value = pcall(fn)
		if ok and type(value) == "number" then return value end
	end
	return 0
end

local function Copy(data)
	local out = {}
	if type(data) == "table" then
		for key, value in pairs(data) do out[key] = value end
	end
	return out
end

local function AddMap(out, map)
	if type(map) ~= "table" then return end
	local mapdata = map.mapdata
	out.map = tostring((type(mapdata) == "table" and mapdata.id) or map.name or "?")
	out.environment = tostring(type(mapdata) == "table" and mapdata.Environment or "?")
	out.map_ref = tostring(map)
	out.mapdata_width = tostring(type(mapdata) == "table" and mapdata.Width or nil)
	out.mapdata_height = tostring(type(mapdata) == "table" and mapdata.Height or nil)
	out.desired_tiles = tostring(map.SuperBigMapDesiredWidthTiles)
	out.generator_tiles = tostring(map.SuperBigMapGeneratorWidthTiles)
	out.expanded = tostring(map.SuperBigMapExpanded)
end

local function Emit(event, name, data, map, at)
	if not Enabled() then return false end
	at = at or Now()
	state.sequence = state.sequence + 1
	local out = Copy(data)
	out.event = event
	out.session = state.session
	out.sequence = state.sequence
	out.total_ms = at - state.started_at
	out.since_previous_ms = at - state.last_at
	out.depth = state.depth
	AddMap(out, map)
	state.last_at = at
	local log = SuperBigMap.DebugLog
	if log then log.Info("LoadingSteps", tostring(name), out) end
	return true
end

local Profiler = {}

function Profiler.IsActive()
	return Enabled() and state.active == true
end

function Profiler.Start(reason, data, map)
	if not Enabled() then return false end
	if state.active then
		return Emit("SESSION CONTINUE", reason or "loading", data, map)
	end
	local at = Now()
	state.active = true
	state.session = state.session + 1
	state.sequence = 0
	state.started_at = at
	state.last_at = at
	state.depth = 0
	return Emit("SESSION BEGIN", reason or "loading", data, map, at)
end

local function EnsureActive(name, map)
	if not Enabled() then return false end
	if not state.active then Profiler.Start("implicit before " .. tostring(name), nil, map) end
	return state.active
end

function Profiler.Step(name, data, map)
	if not state.active or not Enabled() then return false end
	return Emit("STEP", name, data, map)
end

function Profiler.Begin(name, data, map)
	if not EnsureActive(name, map) then return false end
	local at = Now()
	local token = {
		name = tostring(name), at = at, session = state.session,
		depth = state.depth, map = map,
	}
	Emit("BEGIN", token.name, data, map, at)
	state.depth = state.depth + 1
	return token
end

function Profiler.End(token, data, ok)
	if type(token) ~= "table" or not Enabled() then return false end
	local at = Now()
	state.depth = math.max(0, token.depth or (state.depth - 1))
	local out = Copy(data)
	out.duration_ms = at - (token.at or at)
	out.ok = ok == nil and true or ok == true
	out.begin_session = token.session
	return Emit(ok == false and "ERROR" or "END", token.name, out, token.map, at)
end

function Profiler.Stop(reason, data, map)
	if not state.active or not Enabled() then return false end
	Emit("SESSION END", reason or "loading complete", data, map)
	state.active = false
	state.depth = 0
	return true
end

SuperBigMap.LoadingProfiler = Profiler

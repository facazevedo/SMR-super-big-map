-- Super Big Map -- centralized debug logging.
--
-- DebugLog.Info/Warn/Error(scope, message, data) print one line:
--   [Super Big Map] <LEVEL><scope>: <message> {k=v, ...}
-- A line prints when EITHER the master flag SuperBigMap.Config.DEBUG_LOGS is true
-- (turns on every scope), OR the line's own per-scope flag DEBUG_<SCOPE> is true
-- (e.g. scope "Generation" -> DEBUG_GENERATION). This lets you trace a single domain
-- in isolation, or flip everything on at once. Config is read lazily on each call so
-- gating always reflects the live config. ALL mod logging routes through here -- no raw
-- print() in mod-owned modules.
--
-- Scopes in use (each has a matching DEBUG_<SCOPE> flag in sbm_config.lua):
--   Lifecycle, Generation, Sector, SectorSizing, Deposits, TopUpEdgeDistribution, RmgPlacement,
--   RmgPlacementExhaustive, Stretch, Loading, LoadTime, LoadingSteps,
--   LoadingInvestigation,
--   UndergroundAccess,
--   Hover, Align, EntrancePositions, Overview, Camera, Rocket, RocketTerrain, ElevatorTerrain,
--   Heat, Bounds, FakeTerrain, Validation, Zoom,
--   ZoomVanilla, RestartNotice, PregameToggle, EditorCamera, InitSeq.
--
-- DebugLog.LoadTime(step, data) is the LOAD TIMELINE channel (scope "LoadTime"): each mark prints
-- total=+Xms (since the first mark this session) and delta=+Yms (since the previous mark), so one
-- grep of "LoadTime" reconstructs the whole loading pipeline with where every ms went.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local PREFIX = "[Super Big Map] "
local emission_stats = {}

local function current_config()
	return SuperBigMap.Config or {}
end

-- True when the master flag is on, or this scope's own DEBUG_<SCOPE> flag is on.
local function enabled(scope)
	local cfg = current_config()
	if cfg.DEBUG_LOGS == true then
		return true
	end
	if scope ~= nil and scope ~= "" then
		return cfg["DEBUG_" .. string.upper(tostring(scope))] == true
	end
	return false
end

-- Convert a {key=value} table into a stable, readable string. Values use tostring
-- (safe for engine userdata, which is never indexed here). Keys are sorted for stable
-- output across runs.
local function format_data(data)
	if type(data) ~= "table" then
		return ""
	end
	local keys = {}
	for k in pairs(data) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for i = 1, #keys do
		parts[i] = tostring(keys[i]) .. "=" .. tostring(data[keys[i]])
	end
	if #parts == 0 then
		return ""
	end
	return " {" .. table.concat(parts, ", ") .. "}"
end

local function emit(level, scope, message, data)
	if not enabled(scope) then
		return
	end
	local print_fn = rawget(_G, "print")
	if type(print_fn) ~= "function" then
		return
	end
	local measure = current_config().DEBUG_LOADINGINVESTIGATION == true
	local ticks = measure and (rawget(_G, "GetPreciseTicks") or rawget(_G, "RealTime")) or nil
	local before = 0
	if type(ticks) == "function" then
		local ok, value = pcall(ticks)
		if ok and type(value) == "number" then before = value end
	end
	print_fn(PREFIX .. level .. tostring(scope) .. ": " .. tostring(message) .. format_data(data))
	if type(ticks) == "function" then
		local ok, after = pcall(ticks)
		if ok and type(after) == "number" then
			local key = tostring(scope)
			local stat = emission_stats[key]
			if not stat then
				stat = { calls = 0, total_ms = 0, max_ms = 0 }
				emission_stats[key] = stat
			end
			local elapsed = math.max(0, after - before)
			stat.calls = stat.calls + 1
			stat.total_ms = stat.total_ms + elapsed
			if elapsed > stat.max_ms then stat.max_ms = elapsed end
		end
	end
end

local DebugLog = {}

function DebugLog.Info(scope, message, data)
	emit("", scope, message, data)
end

function DebugLog.Warn(scope, message, data)
	emit("WARN ", scope, message, data)
end

function DebugLog.Error(scope, message, data)
	emit("ERROR ", scope, message, data)
end

-- True when a given scope would print right now. Callers can use this to skip building
-- expensive log data when the scope is off.
function DebugLog.On(scope)
	return enabled(scope)
end

function DebugLog.ResetEmissionStats()
	emission_stats = {}
end

function DebugLog.GetEmissionStats()
	local out = {}
	for scope, stat in pairs(emission_stats) do
		out[scope] = {
			calls = stat.calls,
			total_ms = stat.total_ms,
			max_ms = stat.max_ms,
		}
	end
	return out
end

-- Load-timeline trace: the "LoadTime" scope. Marks a named step with total ms since the first
-- mark and delta ms since the previous mark. Timer resets when marks are >30s apart (a new load).
local load_t0, load_prev = false, false
function DebugLog.LoadTime(step, data)
	local profiler = SuperBigMap.LoadingProfiler
	if profiler and type(profiler.Step) == "function" then
		profiler.Step("legacy timeline: " .. tostring(step), data)
	end
	if not enabled("LoadTime") then
		return false
	end
	local gpt = rawget(_G, "GetPreciseTicks") or rawget(_G, "RealTime")
	local t = 0
	if type(gpt) == "function" then
		local ok, v = pcall(gpt)
		if ok and type(v) == "number" then t = v end
	end
	if not load_t0 or (load_prev and (t - load_prev) > 30000) then
		load_t0, load_prev = t, t
	end
	local out = { total_ms = t - load_t0, delta_ms = t - (load_prev or t) }
	if type(data) == "table" then
		for k, v in pairs(data) do out[k] = v end
	end
	load_prev = t
	emit("", "LoadTime", step, out)
	return true
end

-- Init-sequence trace: the "InitSeq" scope. Kept as named helpers because callers use
-- InitSeqOn() to skip heavy data assembly when the channel is off.
function DebugLog.InitSeqOn()
	return enabled("InitSeq")
end

function DebugLog.InitSeq(message, data)
	local profiler = SuperBigMap.LoadingProfiler
	if profiler and type(profiler.Step) == "function" then
		profiler.Step("init sequence: " .. tostring(message), data)
	end
	if not enabled("InitSeq") then
		return false
	end
	emit("", "InitSeq", message, data)
	return true
end

SuperBigMap.DebugLog = DebugLog

-- Super Big Map -- exhaustive, observational loading-performance profiler.
-- The ordered phase trace is gated by config.DebugLoadingSteps. The nested hotspot trace and
-- descending session summary are separately gated by config.DebugLoadingInvestigation. This
-- module never sleeps, yields, schedules work, changes ordering, or invokes gameplay operations.

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
	investigation_sequence = 0,
	investigation_last_at = 0,
	investigation_depth = 0,
	investigation_totals = {},
	investigation_stack = {},
}

local function StepsEnabled()
	return (SuperBigMap.Config or {}).DEBUG_LOADINGSTEPS == true
end

local function InvestigationEnabled()
	return (SuperBigMap.Config or {}).DEBUG_LOADINGINVESTIGATION == true
end

local function Enabled()
	return StepsEnabled() or InvestigationEnabled()
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
	if not StepsEnabled() then return false end
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

local function EmitInvestigation(event, name, data, map, at)
	if not InvestigationEnabled() or state.active ~= true then return false end
	at = at or Now()
	state.investigation_sequence = state.investigation_sequence + 1
	local out = Copy(data)
	out.event = event
	out.session = state.session
	out.sequence = state.investigation_sequence
	out.total_ms = at - state.started_at
	out.since_previous_ms = at - state.investigation_last_at
	out.depth = state.investigation_depth
	AddMap(out, map)
	state.investigation_last_at = at
	local log = SuperBigMap.DebugLog
	if log then log.Info("LoadingInvestigation", tostring(name), out) end
	return true
end

local Profiler = {}
local EnsureActive

function Profiler.IsActive()
	return Enabled() and state.active == true
end

function Profiler.InvestigationEnabled()
	return InvestigationEnabled()
end

function Profiler.Start(reason, data, map)
	if not Enabled() then return false end
	if state.active then
		local emitted = Emit("SESSION CONTINUE", reason or "loading", data, map)
		EmitInvestigation("SESSION CONTINUE", reason or "loading", data, map)
		return emitted or InvestigationEnabled()
	end
	local at = Now()
	state.active = true
	state.session = state.session + 1
	state.sequence = 0
	state.started_at = at
	state.last_at = at
	state.depth = 0
	state.investigation_sequence = 0
	state.investigation_last_at = at
	state.investigation_depth = 0
	state.investigation_totals = {}
	state.investigation_stack = {}
	local log = SuperBigMap.DebugLog
	if InvestigationEnabled() and log and type(log.ResetEmissionStats) == "function" then
		log.ResetEmissionStats()
	end
	local emitted = Emit("SESSION BEGIN", reason or "loading", data, map, at)
	EmitInvestigation("SESSION BEGIN", reason or "loading", data, map, at)
	return emitted or InvestigationEnabled()
end

function Profiler.InvestigationStep(name, data, map)
	if not state.active or not InvestigationEnabled() then return false end
	return EmitInvestigation("STEP", name, data, map)
end

function Profiler.InvestigationBegin(name, data, map)
	if not InvestigationEnabled() or not EnsureActive(name, map) then return false end
	local at = Now()
	local token = {
		name = tostring(name), at = at, session = state.session,
		depth = state.investigation_depth, map = map, child_ms = 0,
	}
	EmitInvestigation("BEGIN", token.name, data, map, at)
	state.investigation_depth = state.investigation_depth + 1
	state.investigation_stack[#state.investigation_stack + 1] = token
	return token
end

function Profiler.InvestigationEnd(token, data, ok)
	if type(token) ~= "table" or not InvestigationEnabled() then return false end
	local at = Now()
	state.investigation_depth = math.max(0, token.depth or (state.investigation_depth - 1))
	local duration = at - (token.at or at)
	local exclusive = math.max(0, duration - (token.child_ms or 0))
	local stack = state.investigation_stack
	local token_index
	for i = #stack, 1, -1 do
		if stack[i] == token then token_index = i; break end
	end
	if token_index then
		local parent = stack[token_index - 1]
		if parent then parent.child_ms = (parent.child_ms or 0) + duration end
		table.remove(stack, token_index)
	end
	local out = Copy(data)
	out.duration_ms = duration
	out.exclusive_ms = exclusive
	out.ok = ok == nil and true or ok == true
	out.begin_session = token.session
	local totals = state.investigation_totals
	local total = totals[token.name]
	if not total then
		total = { calls = 0, total_ms = 0, exclusive_ms = 0, max_ms = 0, errors = 0 }
		totals[token.name] = total
	end
	total.calls = total.calls + 1
	total.total_ms = total.total_ms + duration
	total.exclusive_ms = total.exclusive_ms + exclusive
	if duration > total.max_ms then total.max_ms = duration end
	if ok == false then total.errors = total.errors + 1 end
	return EmitInvestigation(ok == false and "ERROR" or "END", token.name, out, token.map, at)
end

EnsureActive = function(name, map)
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
	if InvestigationEnabled() then
		token.investigation_token = Profiler.InvestigationBegin(
			"phase: " .. token.name, data, map)
	end
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
	if token.investigation_token then
		Profiler.InvestigationEnd(token.investigation_token, data, ok)
	end
	return Emit(ok == false and "ERROR" or "END", token.name, out, token.map, at)
end

function Profiler.Stop(reason, data, map)
	if not state.active or not Enabled() then return false end
	if InvestigationEnabled() then
		local log = SuperBigMap.DebugLog
		local log_stats = log and type(log.GetEmissionStats) == "function"
			and log.GetEmissionStats() or {}
		local log_ranked = {}
		for scope, stat in pairs(log_stats) do
			log_ranked[#log_ranked + 1] = { scope = scope, stat = stat }
		end
		table.sort(log_ranked, function(a, b)
			if a.stat.total_ms == b.stat.total_ms then return a.scope < b.scope end
			return a.stat.total_ms > b.stat.total_ms
		end)
		for rank, item in ipairs(log_ranked) do
			EmitInvestigation("LOGGING SUMMARY", "diagnostic scope: " .. item.scope, {
				rank = rank,
				lines = item.stat.calls,
				total_print_ms = item.stat.total_ms,
				max_print_ms = item.stat.max_ms,
			}, map)
		end
		local ranked = {}
		for name, total in pairs(state.investigation_totals) do
			ranked[#ranked + 1] = { name = name, total = total }
		end
		table.sort(ranked, function(a, b)
			if a.total.exclusive_ms == b.total.exclusive_ms then return a.name < b.name end
			return a.total.exclusive_ms > b.total.exclusive_ms
		end)
		for rank, item in ipairs(ranked) do
			EmitInvestigation("SUMMARY", item.name, {
				rank = rank,
				calls = item.total.calls,
				inclusive_total_ms = item.total.total_ms,
				exclusive_total_ms = item.total.exclusive_ms,
				max_ms = item.total.max_ms,
				errors = item.total.errors,
			}, map)
		end
		EmitInvestigation("SESSION END", reason or "loading complete", data, map)
	end
	Emit("SESSION END", reason or "loading complete", data, map)
	state.active = false
	state.depth = 0
	state.investigation_depth = 0
	state.investigation_stack = {}
	return true
end

SuperBigMap.LoadingProfiler = Profiler

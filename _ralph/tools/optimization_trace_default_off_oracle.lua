-- Executable Lua 5.3 oracle for the v979 default-off optimization-trace API.
local saved_print = print
local saved_tostring = tostring
local saved_string_format = string.format
local function read(path)
	local file, open_error = io.open(path, "rb")
	if not file then error(open_error) end
	local text = file:read("*a")
	file:close()
	return text
end

local generation = read("Code/sbm_map_generation.lua")
local terrain = read("Code/sbm_terrain_copy.lua")
local noop_marker = "-- Default-off optimization-trace API."
local noop_start = assert(generation:find(noop_marker, 1, true))
local noop_end = assert(generation:find("local function PointXY", noop_start, true))
local first_ordinary_call = assert(generation:find(
	"SuperBigMap.OptimizationTrace.Start(destination,", 1, true))
local lazy_gate = assert(generation:find(
	"if SuperBigMap.State.lazy_underground_reload_restore_ok ~= false", 1, true))
if not (noop_start < noop_end and noop_end < first_ordinary_call
	and first_ordinary_call < lazy_gate) then
	error("default-off trace API is not outside the lazy gate and before ordinary calls")
end
local noop_source = generation:sub(noop_start, noop_end - 1)
for _, forbidden in ipairs({
	"GetPreciseTicks", "RealTime", "AsyncStringToFile", "print", "AsyncRand",
	"InteractionRand", "tostring", "string.format", "pcall", "g_SmrRalphOptimizationTracePath",
}) do
	if noop_source:find(forbidden, 1, true) then
		error("default-off trace API contains forbidden work: " .. forbidden)
	end
end

local calls = { clock = 0, format = 0, file = 0, console = 0, rng = 0 }
local function forbidden(kind)
	return function()
		calls[kind] = calls[kind] + 1
		error("default-off trace attempted " .. kind)
	end
end
GetPreciseTicks = forbidden("clock")
RealTime = forbidden("clock")
AsyncStringToFile = forbidden("file")
AsyncRand = forbidden("rng")
InteractionRand = forbidden("rng")
print = forbidden("console")
tostring = forbidden("format")
string.format = forbidden("format")
g_SmrRalphOptimizationTracePath = nil

SuperBigMap = {
	Config = {
		DEBUG_LOGGING_ENABLED = false,
		DEBUG_LOADING_TIMINGS = false,
		LAZY_UNDERGROUND_SOURCE_GENERATION_FEASIBILITY = false,
		LAZY_UNDERGROUND_SOURCE_GENERATION = false,
	},
	Engine = {
		Global = function(name) return rawget(_G, name) end,
		SafeCall = function(fn, ...) return fn(...) end,
		IsKindOf = function() return false end,
		ObjectPos = function() return false end,
	},
}

local install_source = "local SuperBigMap = rawget(_G, 'SuperBigMap')\n" .. noop_source
local install, install_error = load(install_source, "default-off-trace-api", "t", _G)
if not install then error(install_error) end
install()
local trace = SuperBigMap.OptimizationTrace
if type(trace) ~= "table" or trace.NOOP_DEFAULT_OFF ~= true then
	error("default-off trace table was not installed")
end
for _, method in ipairs({
	"ConfiguredPath", "IsActive", "Start", "Before", "After", "Step", "Error",
	"EarlyReturn", "Finish", "Emit", "Publish",
}) do
	if type(trace[method]) ~= "function" then error("missing no-op method: " .. method) end
end

local map = { slot = 1, mapdata = { Environment = "Surface", id = "default-off-oracle" } }
if trace.Start(map, "ordinary temporary-source stretch") ~= false
	or trace.Before("ordinary map operation", map, { count = 1 }) ~= false
	or trace.After("ordinary map operation", map, { count = 1 }) ~= false
	or trace.Error("ordinary map operation", map, "synthetic") ~= false
	or trace.Finish(map, true, "ordinary completion") ~= false then
	error("default-off map trace call returned active")
end

-- Load the real diagnostics module and exercise its trace bridge with all debug channels disabled.
dofile("Code/sbm_diagnostics.lua")
local diagnostics = assert(SuperBigMap.Diagnostics)
if diagnostics.LoadingStep("default-off diagnostics step", { count = 1 }, map) ~= false
	or diagnostics.LoadingPhase("default-off diagnostics phase", map, { count = 1 }) ~= false then
	error("default-off diagnostics bridge returned active")
end
local token = diagnostics.LoadingBegin("default-off diagnostics boundary", map, { count = 1 })
if token ~= false or diagnostics.LoadingEnd(token, { count = 1 }, true) ~= false
	or diagnostics.LoadingFinish("default-off diagnostics finish", map, nil, true) ~= false then
	error("default-off diagnostics boundary returned active")
end

-- Execute the real terrain trace adapter and representative before/after/error calls.
local terrain_start = assert(terrain:find("local function OptimizationTraceBoundary", 1, true))
local terrain_end = assert(terrain:find("local function TerrainCreaseAudit", terrain_start, true))
local terrain_probe_source = "local SuperBigMap = rawget(_G, 'SuperBigMap')\n"
	.. terrain:sub(terrain_start, terrain_end - 1)
	.. "\nTraceBefore('terrain default-off before', ...)"
	.. "\nTraceAfter('terrain default-off after', ...)"
	.. "\nTraceError('terrain default-off error', select(1, ...), 'synthetic')"
	.. "\nreturn true"
local terrain_probe, terrain_error = load(
	terrain_probe_source, "default-off-terrain-trace-adapter", "t", _G)
if not terrain_probe then error(terrain_error) end
if terrain_probe(map, { count = 1 }) ~= true then error("terrain trace adapter probe failed") end

if calls.clock ~= 0 or calls.format ~= 0 or calls.file ~= 0
	or calls.console ~= 0 or calls.rng ~= 0 then
	error("default-off trace performed forbidden work")
end
tostring = saved_tostring
string.format = saved_string_format
saved_print("ok=true")
saved_print("map_calls_safe=true")
saved_print("terrain_calls_safe=true")
saved_print("diagnostic_calls_safe=true")
saved_print("clock_calls=0")
saved_print("format_calls=0")
saved_print("file_calls=0")
saved_print("console_calls=0")
saved_print("rng_calls=0")

-- Execute the production heartbeat function with absent/malformed sinks and prove the guard does
-- not reach clocks, formatting, file/console I/O, or RNG.
local function read(path)
	local file = assert(io.open(path, "rb"))
	local text = file:read("*a")
	file:close()
	return text
end
local source = read("Code/sbm_map_generation.lua")
local first = assert(source:find("function SuperBigMap.DiagnosticPhaseHeartbeat", 1, true))
local last = assert(source:find("local function PointXY", first, true))
local function_body = source:sub(first, last - 1)
local calls = { global = 0, clock = 0, file = 0, rng = 0, console = 0 }
local SuperBigMap = {}
local function Global(name)
	calls.global = calls.global + 1
	if name == "GetPreciseTicks" or name == "RealTime" then calls.clock = calls.clock + 1 end
	if name == "AsyncStringToFile" then calls.file = calls.file + 1 end
	if name == "AsyncRand" or name == "InteractionRand" then calls.rng = calls.rng + 1 end
	if name == "print" then calls.console = calls.console + 1 end
	error("default-off heartbeat reached Global(" .. name .. ")")
end
local install = assert(load(
	"local SuperBigMap, Global = ...\n" .. function_body .. "\nreturn SuperBigMap",
	"v992-heartbeat-default-off", "t", _G))
install(SuperBigMap, Global)
local emit = assert(SuperBigMap.DiagnosticPhaseHeartbeat)
local map = { slot=1, mapdata={Environment="Surface"} }
assert(emit(map, "absent", "BEFORE", {count=1}) == false)
g_SmrRalphDiagnosticFailureSink = { schema="wrong" }
assert(emit(map, "malformed", "BEFORE", {count=1}) == false)
g_SmrRalphDiagnosticFailureSink = {
	schema="smr.ralph.lazy-terminal-failure-sink.v1", diagnostic_only=true,
	acceptance_timing_eligible=false, nonce="x",
	manifest_sha256=string.rep("0", 64),
}
assert(emit(map, "missing-heartbeat-prefix", "BEFORE", {count=1}) == false)
g_SmrRalphDiagnosticFailureSink = nil
assert(calls.global == 0 and calls.clock == 0 and calls.file == 0
	and calls.rng == 0 and calls.console == 0)
print("ok=true")
print("default_off_calls=3")
print("global_calls=0")
print("clock_calls=0")
print("file_calls=0")
print("rng_calls=0")
print("console_calls=0")

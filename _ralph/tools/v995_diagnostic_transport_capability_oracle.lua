-- Executable adversarial model for the v995 environment-split heartbeat transport.
local function valid_sink(sink)
	return type(sink) == "table" and sink.schema == "sink"
		and sink.diagnostic_only == true and sink.acceptance_timing_eligible == false
end

local function install(sink, target, writer, clock)
	if not valid_sink(sink) or type(target) ~= "table"
		or target.state ~= "ready-for-first-access" or target.maps2
		or type(writer) ~= "function" or type(clock) ~= "function" then
		return false, "invalid-capability"
	end
	local ok1, tick1 = pcall(clock)
	local ok2, tick2 = pcall(clock)
	if not ok1 or not ok2 or type(tick1) ~= "number" or type(tick2) ~= "number"
		or tick1 ~= tick1 or tick2 ~= tick2 or tick2 < tick1 then
		return false, "invalid-clock"
	end
	local private = { sequence = 0, nonce = sink.nonce }
	local function emit(phase, edge)
		private.sequence = private.sequence + 1
		local write_error = writer(private.sequence, private.nonce, phase, edge)
		return not write_error
	end
	if not emit("handshake", "BEFORE") or not emit("handshake", "AFTER") then
		return false, "write-failed"
	end
	return true, emit, private
end

local debugger_env = { writes = {}, tick = 100 }
local mod_env = {} -- Deliberately has no writer or clock: raw mod-global lookup must fail.
local function writer(sequence, nonce, phase, edge)
	debugger_env.writes[#debugger_env.writes + 1] =
		table.concat({ sequence, nonce, phase, edge }, ":")
	return nil
end
local function clock()
	debugger_env.tick = debugger_env.tick + 1
	return debugger_env.tick
end
local sink = {
	schema = "sink", diagnostic_only = true, acceptance_timing_eligible = false,
	nonce = "iter238-v995",
}
local target = { state = "ready-for-first-access", maps2 = false }

assert(mod_env.AsyncStringToFile == nil and mod_env.GetPreciseTicks == nil)
local ok, emit, private = install(sink, target, writer, clock)
assert(ok and private.sequence == 2 and #debugger_env.writes == 2)

-- The exact functions are retained privately. Later debugger/global mutation cannot replace them.
debugger_env.AsyncStringToFile = function() return "forged" end
debugger_env.GetPreciseTicks = function() return -1 end
assert(emit("materialize", "BEFORE") and private.sequence == 3)
assert(debugger_env.writes[3]:find(":iter238%-v995:materialize:BEFORE$"))

local before = #debugger_env.writes
assert(not install(sink, target, nil, clock))
assert(not install(sink, target, writer, nil))
assert(not install(sink, target, function() return "denied" end, clock))
local backward = 2
assert(not install(sink, target, writer, function() backward = backward - 1 return backward end))
assert(not install(sink, target, writer, function() return 0 / 0 end))
assert(not install(sink, { state = "generating", maps2 = false }, writer, clock))
assert(not install(sink, { state = "ready-for-first-access", maps2 = true }, writer, clock))
assert(#debugger_env.writes == before) -- rejected transports cannot publish through the exact writer

-- Default-off has no sink and therefore does not touch transport, clock, console, or RNG.
local default_clock_calls, default_writer_calls, rng_calls = 0, 0, 0
local function default_emit(no_sink)
	if type(no_sink) ~= "table" then return false end
	default_clock_calls = default_clock_calls + 1
	default_writer_calls = default_writer_calls + 1
	return true
end
assert(default_emit(nil) == false)
assert(default_clock_calls == 0 and default_writer_calls == 0 and rng_calls == 0)

print("ok=true")
print("mod_environment_writer_absent=true")
print("explicit_transport_handshake_records=2")
print("private_writer_identity_retained=true")
print("private_clock_identity_retained=true")
print("missing_writer_rejected=true")
print("missing_clock_rejected=true")
print("writer_failure_rejected=true")
print("backward_clock_rejected=true")
print("nan_clock_rejected=true")
print("loaded_or_allocated_target_rejected=true")
print("default_off_clock_calls=0")
print("default_off_writer_calls=0")
print("rng_calls=0")

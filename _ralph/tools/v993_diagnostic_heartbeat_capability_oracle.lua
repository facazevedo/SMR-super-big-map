-- Executable model for the post-T1 mod-environment heartbeat capability.
local writes, clocks, materialize_calls = {}, 0, 0
local debugger_env, mod_env = {}, {}
local function valid(sink)
	return type(sink) == "table"
		and sink.schema == "smr.ralph.lazy-terminal-failure-sink.v1"
		and sink.diagnostic_only == true
		and sink.acceptance_timing_eligible == false
		and type(sink.nonce) == "string" and sink.nonce ~= ""
		and type(sink.manifest_sha256) == "string" and #sink.manifest_sha256 == 64
		and type(sink.heartbeat_prefix) == "string" and sink.heartbeat_prefix ~= ""
		and type(sink.bundle_path) == "string" and sink.bundle_path ~= ""
		and type(sink.sentinel_path) == "string" and sink.sentinel_path ~= ""
end
local function install(sink, t1)
	if not valid(sink) or not t1 or t1.state ~= "ready-for-first-access"
		or t1.attempts ~= 0 or t1.generation ~= 0 or t1.maps2 then
		return false
	end
	local private = {
		schema=sink.schema, diagnostic_only=true, acceptance_timing_eligible=false,
		nonce=sink.nonce, manifest_sha256=sink.manifest_sha256,
		heartbeat_prefix=sink.heartbeat_prefix, bundle_path=sink.bundle_path,
		sentinel_path=sink.sentinel_path, sequence=0,
	}
	local function emit(phase, edge)
		clocks = clocks + 1
		private.sequence = private.sequence + 1
		writes[#writes + 1] = table.concat({
			private.nonce, private.manifest_sha256, tostring(private.sequence), phase, edge,
		}, ":")
		return true
	end
	if not emit("diagnostic-heartbeat-handshake", "BEFORE")
		or not emit("diagnostic-heartbeat-handshake", "AFTER") then return false end
	return true, emit, private
end

local sink = {
	schema="smr.ralph.lazy-terminal-failure-sink.v1", diagnostic_only=true,
	acceptance_timing_eligible=false, nonce="iter236", manifest_sha256=string.rep("a",64),
	heartbeat_prefix="run/phase_", bundle_path="run/bundle", sentinel_path="run/terminal",
}
debugger_env.g_SmrRalphDiagnosticFailureSink = sink
assert(mod_env.g_SmrRalphDiagnosticFailureSink == nil)
local ok, emitter, private = install(sink, {
	state="ready-for-first-access", attempts=0, generation=0, maps2=false,
})
assert(ok and #writes == 2 and private.sequence == 2)

-- The staged table is not retained; mutation cannot alter the private identity.
sink.nonce, sink.manifest_sha256, sink.heartbeat_prefix = "spoof", string.rep("b",64), "bad/"
assert(emitter("lazy-wrapper-materialize-call", "BEFORE"))
assert(writes[3]:match("^iter236:" .. string.rep("a",64) .. ":3:"))

-- Simulated module reload clears/replaces the public emitter, but the exact wrapper-captured
-- closure remains on the synchronous call stack and reaches both sides of the native boundary.
mod_env.DiagnosticPhaseHeartbeat = function() return false end
local wrapper_emitter = emitter
local function materialize(explicit)
	assert(type(explicit) == "function")
	materialize_calls = materialize_calls + 1
	assert(explicit("lazy-materialize-entry", "BEFORE"))
	assert(explicit("lazy-native-GenerateRandomMap", "BEFORE"))
	assert(explicit("lazy-native-GenerateRandomMap", "AFTER"))
end
materialize(wrapper_emitter)
assert(materialize_calls == 1 and private.sequence == 6)

local before = materialize_calls
local malformed_ok = install({schema="wrong"}, {state="ready-for-first-access",attempts=0,generation=0})
local loaded_ok = install({
	schema="smr.ralph.lazy-terminal-failure-sink.v1", diagnostic_only=true,
	acceptance_timing_eligible=false, nonce="x", manifest_sha256=string.rep("a",64),
	heartbeat_prefix="p", bundle_path="b", sentinel_path="s",
}, {state="generating",attempts=1,generation=0,maps2=false})
assert(not malformed_ok and not loaded_ok and materialize_calls == before)

print("ok=true")
print("debugger_global_not_visible_to_mod_env=true")
print("handshake_records=2")
print("private_sink_immutable=true")
print("reload_safe_explicit_emitter=true")
print("native_boundary_records=2")
print("materialize_calls=1")
print("invalid_handshake_materialize_calls=0")
print("rule_waivers=0")

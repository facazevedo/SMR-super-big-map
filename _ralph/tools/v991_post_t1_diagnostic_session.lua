-- Reusable, non-promoting post-T1 diagnostic lab command runner.
--
-- The controller arms g_SmrRalphDiagnosticSession and g_SmrRalphDiagnosticCommand with an exact
-- nonce + command-manifest SHA-256, then invokes this file. Each invocation executes one bounded
-- primitive-copy hypothesis. It never changes map slots, releases deferred access, calls an
-- object position setter, consumes randomness, or writes a gameplay grid. A separate cleanup
-- command clears both globals.

local session = rawget(_G, "g_SmrRalphDiagnosticSession")
local command = rawget(_G, "g_SmrRalphDiagnosticCommand")
local function valid_hex(value) return type(value) == "string" and #value == 64
	and value:match("^[0-9a-fA-F]+$") ~= nil end
if type(session) ~= "table" or session.schema ~= "smr.ralph.post-t1-diagnostic-session.v1"
	or session.diagnostic_only ~= true or session.acceptance_timing_eligible ~= false
	or session.can_promote ~= false or session.can_release_underground ~= false
	or type(session.nonce) ~= "string" or session.nonce == "" or #session.nonce > 128
	or not valid_hex(session.manifest_sha256)
	or type(session.deadline_ms) ~= "number" or session.deadline_ms < 1
	or session.deadline_ms > 300000
	or type(command) ~= "table" or command.nonce ~= session.nonce
	or command.manifest_sha256 ~= session.manifest_sha256
	or type(command.sequence) ~= "number" or command.sequence ~= (session.sequence or 0) + 1
	or type(command.output_path) ~= "string" or command.output_path == ""
	or #command.output_path > 1024 then
	error("invalid fail-closed post-T1 diagnostic command envelope")
end
local now = type(RealTime) == "function" and RealTime() or nil
if type(now) ~= "number" or type(session.started_ms) ~= "number"
	or now - session.started_ms > session.deadline_ms then
	rawset(_G, "g_SmrRalphDiagnosticCommand", nil)
	rawset(_G, "g_SmrRalphDiagnosticSession", nil)
	error("post-T1 diagnostic session deadline expired")
end
if command.name == "cleanup" then
	rawset(_G, "g_SmrRalphDiagnosticCommand", nil)
	rawset(_G, "g_SmrRalphDiagnosticSession", nil)
	return "diagnostic-session-cleaned"
end
if command.name ~= "enrichment-relocation-private-simulation" then
	error("unsupported post-T1 diagnostic command")
end

local maps = rawget(_G, "Maps")
local underground = type(maps) == "table" and maps[2] or nil
local debug = underground and underground.SuperBigMapUndergroundEnrichmentRelocationDebug
if type(debug) ~= "table" or debug.schema ~= 3 or debug.bounded ~= true
	or type(debug.candidate_corpus) ~= "table" or #debug.candidate_corpus > 256
	or type(debug.records) ~= "table" or #debug.records > 8 then
	error("persisted enrichment diagnostic corpus is unavailable or unbounded")
end
local function digest(values)
	local value = 5381
	for i, record in ipairs(values) do
		for _, field in ipairs({ i, record.x, record.y, record.q, record.r, record.source }) do
			local text = tostring(field == nil and "" or field)
			for j = 1, #text do value = (value * 33 + text:byte(j)) % 2147483647 end
		end
	end
	return value
end
local live_before = digest(debug.candidate_corpus)
if live_before ~= debug.candidate_corpus_digest then error("live diagnostic corpus digest drift") end
local clone = {}
for i, record in ipairs(debug.candidate_corpus) do
	clone[i] = { x = record.x, y = record.y, q = record.q, r = record.r,
		source = record.source }
end
local clone_before = digest(clone)
-- Private simulation: model committed-only consumption by removing at most one candidate for each
-- marker that actually moved. No engine object or live persisted table is written.
local simulated_commits = 0
for _, record in ipairs(debug.records) do
	if record.result == "moved" and #clone > 0 then
		table.remove(clone, 1)
		simulated_commits = simulated_commits + 1
	end
end
local clone_after = digest(clone)
local live_after = digest(debug.candidate_corpus)
if live_after ~= live_before then error("diagnostic mutated live candidate corpus") end
local rows = {
	"schema=smr.ralph.v991-enrichment-private-simulation.v1", "ok=true",
	"diagnostic_only=true", "acceptance_timing_eligible=false", "can_promote=false",
	"can_release_underground=false", "live_mutations=0", "rng_calls=0",
	"nonce=" .. session.nonce, "command_manifest_sha256=" .. session.manifest_sha256,
	"sequence=" .. tostring(command.sequence), "candidate_count=" .. tostring(#debug.candidate_corpus),
	"marker_count=" .. tostring(#debug.records), "simulated_commits=" .. tostring(simulated_commits),
	"live_before_hash=" .. tostring(live_before), "live_after_hash=" .. tostring(live_after),
	"private_clone_before_hash=" .. tostring(clone_before),
	"private_clone_after_hash=" .. tostring(clone_after),
	"rejection_histogram_present=" .. tostring(type(debug.rejection_histogram) == "table"),
	"root_candidate_1=profile-specific-candidate-consumption",
}
local write_error = AsyncStringToFile(command.output_path, table.concat(rows, "\n") .. "\n")
if write_error then error("diagnostic response write failed: " .. tostring(write_error)) end
session.sequence = command.sequence
rawset(_G, "g_SmrRalphDiagnosticCommand", nil)
return "diagnostic-command-complete"

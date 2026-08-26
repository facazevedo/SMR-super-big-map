-- Diagnostic-only real-corpus producer for PrepareOuterResourceTerrain guard screening.
--
-- Load after the Super Big Map modules exist and before expanded surface generation.  The host
-- must provide a fresh output path and the immutable capture identity.  The production seam is
-- default-off; this probe explicitly enables it and rewrites one tiny ordered TSV after each
-- preparation/repair call.  No gameplay result or timing from a probe-enabled run is authoritative.

local out_path = rawget(_G, "g_SbmGuardCorpusOutPath")
local identity = rawget(_G, "g_SbmGuardCorpusIdentity")
if type(out_path) ~= "string" or out_path == "" then
	error("g_SbmGuardCorpusOutPath must be a fresh non-empty path")
end
if type(identity) ~= "table" then error("g_SbmGuardCorpusIdentity must be a table") end

local required_identity = {
	"coordinate", "preset", "source_commit", "terrain_source_sha256",
	"scenario_input_sha256", "task_sha256",
}
for _, key in ipairs(required_identity) do
	local value = identity[key]
	if type(value) ~= "string" or value == "" or string.find(value, "[\t\r\n]") then
		error("invalid guard corpus identity " .. key)
	end
end
if identity.coordinate ~= "14N134W" or identity.preset ~= "RoughTerrain" then
	error("guard corpus probe is pinned to 14N134W RoughTerrain")
end

local mod
for _, candidate in ipairs(ModsLoaded or empty_table) do
	if candidate and candidate.id == "SuperBigMap" then mod = candidate break end
end
local SBM = (mod and type(mod.env) == "table" and mod.env.SuperBigMap)
	or rawget(_G, "SuperBigMap")
local terrain_copy = type(SBM) == "table" and SBM.TerrainCopy or nil
if type(terrain_copy) ~= "table"
	or type(terrain_copy.SetOuterResourceGuardCorpusHookForTest) ~= "function" then
	error("outer resource guard corpus seam is unavailable")
end
if type(AsyncStringToFile) ~= "function" then error("AsyncStringToFile is unavailable") end

local function scalar(value)
	if type(value) ~= "number" or value ~= value
		or value == math.huge or value == -math.huge then
		error("guard corpus contains a non-finite number")
	end
	return string.format("%.17g", value)
end

local function clean(value, label)
	value = tostring(value or "")
	if value == "" or string.find(value, "[\t\r\n]") then
		error("invalid guard corpus " .. tostring(label))
	end
	return value
end

local observations = {}
local function render()
	local lines = { "SCHEMA\tsmr.ralph.protected_guard_observation.v1" }
	for _, key in ipairs(required_identity) do
		lines[#lines + 1] = table.concat({ "IDENTITY", key, identity[key] }, "\t")
	end
	for call_index, observation in ipairs(observations) do
		lines[#lines + 1] = table.concat({
			"CALL", tostring(call_index), tostring(observation.map_width),
			tostring(observation.map_height), scalar(observation.height_tile),
			scalar(observation.cells_per_hex), tostring(observation.ring_sectors),
		}, "\t")
		for index, guard in ipairs(observation.guards or empty_table) do
			lines[#lines + 1] = table.concat({
				"GUARD", tostring(call_index), tostring(index), clean(guard.id, "guard id"),
				scalar(guard.cx), scalar(guard.cy), scalar(guard.radius),
			}, "\t")
		end
		for index, pass in ipairs(observation.passes or empty_table) do
			lines[#lines + 1] = table.concat({
				"PASS", tostring(call_index), tostring(index), clean(pass.id, "pass id"),
				scalar(pass.cx), scalar(pass.cy), scalar(pass.visit_radius),
				tostring(pass.width), tostring(pass.height),
			}, "\t")
		end
	end
	return table.concat(lines, "\n") .. "\n"
end

local armed, arm_error = terrain_copy.SetOuterResourceGuardCorpusHookForTest(function(payload)
	if type(payload) ~= "table" or payload.schema ~= "smr.ralph.protected_guard_observation.v1"
		or type(payload.guards) ~= "table" or type(payload.passes) ~= "table" then
		error("invalid outer resource guard observation")
	end
	observations[#observations + 1] = payload
	local err = AsyncStringToFile(out_path, render())
	if err then error("guard corpus write failed: " .. tostring(err)) end
	return true
end)
if armed ~= true then error("guard corpus hook did not arm: " .. tostring(arm_error)) end

rawset(_G, "g_SbmGuardCorpusProbeArmed", true)
rawset(_G, "g_SbmGuardCorpusProbeDisarm", function()
	terrain_copy.SetOuterResourceGuardCorpusHookForTest(nil)
	rawset(_G, "g_SbmGuardCorpusProbeArmed", false)
	return true
end)
return "smr_guard_corpus_probe_armed"

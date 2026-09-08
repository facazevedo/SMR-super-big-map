-- Production regression for staged native-enrichment records across module replacement.
-- Run from the project root: lua _ralph/tools/parity/native_enrichment_reload_cache_test.lua

local module_path = "Code/sbm_deposits.lua"

local function hash(material)
	-- The production function only requires a stable scalar hash. Keeping this fixture small
	-- makes the test exercise the real stage/verify/clear functions without engine dependencies.
	return "fixture:" .. tostring(#material) .. ":" .. material
end

rawset(_G, "SuperBigMap", {
	Engine = {
		Global = function(name)
			if name == "xxhash" then return hash end
		end,
		SafeCall = function(fn, ...)
			return fn(...)
		end,
	},
})

local function load_rules()
	assert(dofile(module_path) == nil)
	return assert(SuperBigMap.DepositRules)
end

local function records(tag)
	return {
		{ class = "DepositMarker", source_x = 10, source_y = 20, source_z = 30,
			properties = { resource = tag, max_amount = 5000 } },
		{ class = "SubsurfaceAnomalyMarker", source_x = 40, source_y = 50, source_z = 60,
			properties = { sequence = "Anomaly_" .. tag, revealed = false } },
	}
end

local function verify(rules, map, signature, label)
	local ok, stats = rules.VerifyStagedNativeEnrichmentRecords(
		map, 2, signature, label)
	assert(ok == true, label .. ": staged records unavailable or changed (count="
		.. tostring(stats and stats.count) .. ", signature="
		.. tostring(stats and stats.signature) .. ")")
end

local old_rules = load_rules()
local staged_before_reload = {}
assert(old_rules.StageNativeEnrichmentRecords(
	staged_before_reload, records("before"), "before module replacement"))
local before_signature = staged_before_reload.SuperBigMapNativeEnrichmentRecordSignature
verify(old_rules, staged_before_reload, before_signature, "old verifier before replacement")

local new_rules = load_rules()
assert(new_rules ~= old_rules, "module replacement did not publish a new rules table")
verify(old_rules, staged_before_reload, before_signature, "old verifier after replacement")
verify(new_rules, staged_before_reload, before_signature, "new verifier after replacement")
new_rules.ClearStagedNativeEnrichmentRecords(staged_before_reload, "new instance cleanup")
assert(select(1, old_rules.HasStagedNativeEnrichmentRecords(staged_before_reload)) == false,
	"new instance cleanup was not visible to old instance")

local staged_after_reload = {}
assert(new_rules.StageNativeEnrichmentRecords(
	staged_after_reload, records("after"), "after module replacement"))
local after_signature = staged_after_reload.SuperBigMapNativeEnrichmentRecordSignature
verify(new_rules, staged_after_reload, after_signature, "new verifier after replacement stage")
verify(old_rules, staged_after_reload, after_signature, "old verifier after replacement stage")
old_rules.ClearStagedNativeEnrichmentRecords(staged_after_reload, "old instance cleanup")
assert(select(1, new_rules.HasStagedNativeEnrichmentRecords(staged_after_reload)) == false,
	"old instance cleanup was not visible to new instance")

local cache = assert(SuperBigMap.State.pending_native_enrichment_records_by_map)
assert(getmetatable(cache) and getmetatable(cache).__mode == "k",
	"shared staged-record cache must retain weak map keys")
do
	local abandoned = {}
	assert(new_rules.StageNativeEnrichmentRecords(
		abandoned, records("abandoned"), "abandoned map weak-key test"))
	assert(cache[abandoned] ~= nil)
end
collectgarbage("collect")
collectgarbage("collect")
local remaining = 0
for _ in pairs(cache) do remaining = remaining + 1 end
assert(remaining == 0, "abandoned map retained in shared weak-key cache")

print("PASS staged native-enrichment cache survives module replacement in both directions")
print("PASS cleanup is shared and abandoned map keys remain weak")

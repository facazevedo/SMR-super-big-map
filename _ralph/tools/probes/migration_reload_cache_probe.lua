-- Diagnostic only. The host must reload through smr after status becomes ready.
-- Pause inside the real stage call; retain no extra map/record references in globals.
local sbm
for _, mod in ipairs(ModsLoaded or {}) do
	local value = mod.env and rawget(mod.env, "SuperBigMap")
	if type(value) == "table" then sbm = value; break end
end
assert(sbm and type(sbm.DepositRules) == "table", "migration cache probe: no rules")
local rules = sbm.DepositRules
local stage = rules.StageNativeEnrichmentRecords
local verify = rules.VerifyStagedNativeEnrichmentRecords
assert(type(stage) == "function" and type(verify) == "function", "migration cache probe: missing APIs")
assert(type(Sleep) == "function", "migration cache probe: Sleep unavailable")
local trace = { status = "installed", installed_rules = tostring(rules) }
rawset(_G, "MIGRATION_CACHE_TRACE", trace)
local seen = false
local function result(fn, map, count, signature)
	local ok, stats = fn(map, count, signature, "controlled reload comparison")
	return { ok = ok, count = stats.count, signature = tostring(stats.signature),
		expected_count = stats.expected_count, expected_signature = tostring(stats.expected_signature) }
end
rules.StageNativeEnrichmentRecords = function(map, records, reason, signature)
	local staged, err = stage(map, records, reason, signature)
	if not seen and staged == true and #records > 300 then
		seen = true
		trace.map_token = tostring(map)
		trace.count = #records
		trace.signature = tostring(signature)
		trace.stage_reason = tostring(reason)
		trace.reloads_before = const.LuaReloads or 0
		trace.before = result(verify, map, #records, signature)
		trace.status = "ready"
		print("[MigrationCacheProbe] ready count=" .. tostring(#records))
		-- The host captures this state, injects one reload, then authorizes comparison.
		-- No OnMsg registration at runtime and no in-game ReloadLua invocation.
		while rawget(_G, "MIGRATION_CACHE_COMPARE") ~= true do Sleep(50) end
		trace.reloads_after = const.LuaReloads or 0
		trace.published_rules = tostring(sbm.DepositRules)
		trace.rules_changed = rules ~= sbm.DepositRules
		trace.old_after = result(verify, map, #records, signature)
		trace.published_after = result(sbm.DepositRules.VerifyStagedNativeEnrichmentRecords,
			map, #records, signature)
		trace.status = "compared"
		print("[MigrationCacheProbe] compared old=" .. tostring(trace.old_after.ok)
			.. " published=" .. tostring(trace.published_after.ok)
			.. " published_count=" .. tostring(trace.published_after.count))
		-- Preserve the first red verifier result for host capture and scoped teardown.
		-- Do not permit migration cleanup to create unrelated cascade errors.
		while true do Sleep(50) end
	end
	return staged, err
end
return "migration cache probe installed"

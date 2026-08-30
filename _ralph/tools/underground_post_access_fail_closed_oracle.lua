-- Executable offline oracle for v987's post-access audit propagation.
-- It models the exact pcall/boolean boundary and sticky materialization publication contract.

local function normalize_pipeline(body)
	local call_ok, result, detail = pcall(body)
	local ok, reason = call_ok, detail
	if call_ok then
		if result == false then ok = false else reason = nil end
	else
		reason = result
	end
	return ok == true, reason
end

local function materialize(pair_result, audit_result, pad_z_certificate, body_raises)
	local descriptor = { state = "generating", failure = "", failure_sticky = false }
	local report = { materialization_running = true, error = "" }
	local map = {}
	local ok, reason = normalize_pipeline(function()
		if body_raises then error("ordinary pipeline exception") end
		map.pair_ok = pair_result == true
		if pair_result ~= true then return false, "pair audit failed" end
		map.audit_ok = audit_result == true
		if audit_result ~= true then return false, "enrichment audit failed" end
	end)
	descriptor.materialization_passage_pair_ok = map.pair_ok == true
	descriptor.materialization_enrichment_reachability_ok = map.audit_ok == true
	descriptor.materialization_passage_pad_z_certificate_exact = pad_z_certificate == true
	report.materialization_passage_pair_ok = descriptor.materialization_passage_pair_ok
	report.materialization_enrichment_reachability_ok =
		descriptor.materialization_enrichment_reachability_ok
	if not ok or descriptor.materialization_passage_pair_ok ~= true
		or descriptor.materialization_enrichment_reachability_ok ~= true then
		descriptor.state = "blocked"
		descriptor.failure_sticky = true
		descriptor.failure = tostring(reason or "mandatory audit omitted")
		report.materialization_running = false
		report.error = descriptor.failure
	end
	if descriptor.state ~= "blocked"
		and descriptor.materialization_passage_pad_z_certificate_exact ~= true then
		descriptor.state = "blocked"
		descriptor.failure_sticky = true
		descriptor.failure = "exact passage-pad target-Z certificate omitted"
		report.materialization_running = false
		report.error = descriptor.failure
	end
	-- Exact v986 monotonic publication rule: a blocked callback/result is never overwritten.
	if descriptor.state ~= "blocked" then descriptor.state = "complete" end
	return descriptor, report
end

local function expect_blocked(name, pair_result, audit_result, pad_z_certificate, raises, reason)
	local descriptor, report = materialize(pair_result, audit_result, pad_z_certificate, raises)
	assert(descriptor.state == "blocked", name .. " did not block")
	assert(descriptor.failure_sticky == true, name .. " was not sticky")
	assert(report.materialization_running == false, name .. " remained running")
	assert(descriptor.failure:find(reason, 1, true), name .. " lost its exact reason")
end

expect_blocked("pair false", false, true, true, false, "pair audit failed")
expect_blocked("audit false", true, false, true, false, "enrichment audit failed")
expect_blocked("ordinary exception", true, true, true, true, "ordinary pipeline exception")
expect_blocked("missing pair", nil, true, true, false, "pair audit failed")
expect_blocked("missing audit", true, nil, true, false, "enrichment audit failed")
expect_blocked("missing target-Z certificate", true, true, false, false,
	"exact passage-pad target-Z certificate omitted")

local descriptor, report = materialize(true, true, true, false)
assert(descriptor.state == "complete")
assert(descriptor.failure_sticky == false)
assert(report.materialization_passage_pair_ok == true)
assert(report.materialization_enrichment_reachability_ok == true)

print("ok=true")
print("explicit_false_paths=4")
print("ordinary_exception_paths=1")
print("sticky_overwrite_rejections=6")
print("complete_paths=1")

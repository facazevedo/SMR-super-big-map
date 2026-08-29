-- Deterministic Lua 5.3 model for the v985 capsule-publication/re-entrant-release boundary.

local PUBLISHED = "surface-capsules-published-awaiting-final-grid"

local function closing_contract(descriptor, report)
	return descriptor.state == PUBLISHED
		and type(descriptor.capsules) == "table" and #descriptor.capsules == 2
		and (tonumber(descriptor.plan_digest) or 0) > 0
		and (tonumber(descriptor.validation_z_digest) or 0) > 0
		and tonumber(descriptor.capsule_planner_version) == 7
		and tonumber(report.capsules_published) == 2
		and tonumber(report.validation_z_certificates) == 2
		and tonumber(report.validation_z_digest) == tonumber(descriptor.validation_z_digest)
		and report.deterministic_repeat == true
		and report.final_grid_revalidation ~= true
		and type(descriptor.capsules[1].validation_z) == "number"
		and type(descriptor.capsules[2].validation_z) == "number"
end

local function block(descriptor, report, reason)
	-- Match production's sticky state, while preserving the first failure in this oracle so a
	-- second block attempt is directly observable as a regression.
	if descriptor.failure_sticky == true then return false, descriptor.failure end
	descriptor.state = "blocked"
	descriptor.failure = reason
	descriptor.failure_sticky = true
	report.failure_sticky = true
	report.error = reason
	return false, reason
end

local function transaction(release_callback, release_result)
	local descriptor = {
		state = "suppressed-awaiting-surface-capsules",
		capsules = { { x = 1, validation_z = 7000 }, { x = 2, validation_z = 9000 } },
		plan_digest = 982288,
		validation_z_digest = 77123,
		capsule_planner_version = 7,
	}
	local report = {
		capsules_published = 0,
		deterministic_repeat = false,
		final_grid_revalidation = false,
	}
	-- Exact production ordering: publish every closing-guard field without an intervening call.
	descriptor.state = PUBLISHED
	report.capsules_published = 2
	report.validation_z_certificates = 2
	report.validation_z_digest = descriptor.validation_z_digest
	report.deterministic_repeat = true
	report.final_grid_revalidation = false
	report.surface_capsule_objects_persisted = true
	report.native_source_retention_released_before_t1 = false

	local callback_ok = release_callback(descriptor, report)
	if descriptor.state == "blocked" or descriptor.failure_sticky == true then
		return false, descriptor, report, callback_ok
	end
	if release_result ~= true then
		block(descriptor, report, "retained native source release failed")
		return false, descriptor, report, callback_ok
	end
	if descriptor.state ~= PUBLISHED then
		block(descriptor, report, "publication state changed during release")
		return false, descriptor, report, callback_ok
	end
	report.native_source_retention_released_before_t1 = true
	return true, descriptor, report, callback_ok
end

local function healthy_callback(descriptor, report)
	return closing_contract(descriptor, report)
		and report.native_source_retention_released_before_t1 == false
end

local healthy, healthy_descriptor, healthy_report, healthy_callback_ok =
	transaction(healthy_callback, true)

local callback_blocked, blocked_descriptor, blocked_report, contract_before_block = transaction(
	function(descriptor, report)
		local exact = closing_contract(descriptor, report)
		block(descriptor, report, "callback-owned sticky failure")
		return exact
	end, true)

local release_failed, failed_descriptor, failed_report, failed_callback_ok =
	transaction(healthy_callback, false)

local callback_and_release_failed, double_descriptor, double_report, double_contract_ok =
	transaction(function(descriptor, report)
		local exact = closing_contract(descriptor, report)
		block(descriptor, report, "first callback failure")
		return exact
	end, false)

local legacy_descriptor = {
	state = "suppressed-awaiting-surface-capsules",
	capsules = { {}, {} },
	plan_digest = 982288,
}
local legacy_report = {
	capsules_published = 0,
	validation_z_certificates = 0,
	deterministic_repeat = false,
	final_grid_revalidation = false,
}
local legacy_rejected = not closing_contract(legacy_descriptor, legacy_report)

local checks = {
	closing_reentry_before_release_passed = healthy_callback_ok == true,
	retention_certified_only_after_success = healthy == true
		and healthy_descriptor.state == PUBLISHED
		and healthy_report.native_source_retention_released_before_t1 == true,
	release_failure_blocked = release_failed == false
		and failed_descriptor.state == "blocked" and failed_descriptor.failure_sticky == true,
	release_failure_not_certified = failed_callback_ok == true
		and failed_report.native_source_retention_released_before_t1 == false,
	callback_block_preserved = callback_blocked == false and contract_before_block == true
		and blocked_descriptor.state == "blocked"
		and blocked_descriptor.failure == "callback-owned sticky failure",
	callback_block_not_overwritten = blocked_report.native_source_retention_released_before_t1 == false,
	blocked_reason_preserved = callback_and_release_failed == false and double_contract_ok == true
		and double_descriptor.state == "blocked"
		and double_descriptor.failure == "first callback failure"
		and double_report.error == "first callback failure"
		and double_report.native_source_retention_released_before_t1 == false,
	publication_never_regressed = healthy_descriptor.state == PUBLISHED
		and blocked_descriptor.state == "blocked" and failed_descriptor.state == "blocked"
		and double_descriptor.state == "blocked",
	legacy_release_before_publication_rejected = legacy_rejected,
}

local ok = true
for _, value in pairs(checks) do ok = ok and value == true end
print("ok=" .. tostring(ok))
for _, key in ipairs({
	"closing_reentry_before_release_passed",
	"retention_certified_only_after_success",
	"release_failure_blocked",
	"release_failure_not_certified",
	"callback_block_preserved",
	"callback_block_not_overwritten",
	"blocked_reason_preserved",
	"publication_never_regressed",
	"legacy_release_before_publication_rejected",
}) do
	print(key .. "=" .. tostring(checks[key]))
end
os.exit(ok and 0 or 1)

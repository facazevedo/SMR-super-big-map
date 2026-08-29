-- Deterministic Lua 5.3 model for the v974 persisted-state/live-rebuild distinction.
-- Process-local weak ownership permits only the two canonical Surface rebuild re-entries; the
-- same persisted fields without that ownership model a loaded interrupted save and must block.
local live_transactions = setmetatable({}, { __mode = "k" })
local loading_refs = setmetatable({}, { __mode = "k" })
local globals = { Maps = {}, UndergroundMap = nil, restore_tokens = nil, visible = true }

local function owned_in_flight(surface, descriptor, report)
	local owner = live_transactions[surface]
	if type(owner) ~= "table" or owner.descriptor ~= descriptor or owner.report ~= report
		or owner.map_slot ~= descriptor.map_slot
		or owner.reserved_seed ~= descriptor.reserved_seed then return false end
	if surface.environment ~= "Surface" or descriptor.map_slot ~= 2
		or descriptor.implementation ~= true
		or descriptor.suppression_committed ~= true or descriptor.suppression_used ~= true
		or descriptor.literal_v964_continues ~= false
		or descriptor.failure_sticky == true or descriptor.failure ~= ""
		or report.suppression_committed ~= true or report.suppression_used ~= true
		or report.literal_v964_continues ~= false or report.shadow_only ~= false
		or report.materialization_running == true
		or descriptor.materialization_attempts ~= 0 or descriptor.generation_count ~= 0
		or globals.UndergroundMap ~= nil or globals.Maps[descriptor.map_slot] ~= nil
		or type(globals.restore_tokens) == "table" and #globals.restore_tokens > 0
		or surface.stretch_pipeline_pending ~= true or surface.surface_stretch_done == true
		or surface.surface_stretch_scheduled ~= true
		or surface.post_pipeline_revalidation_scheduled ~= true
		or surface.post_pipeline_revalidation_complete == true
		or surface.post_pipeline_revalidation_error ~= nil
		or loading_refs[surface] ~= true or globals.visible ~= true then return false end
	if descriptor.state == "suppressed-awaiting-surface-capsules" then
		return #descriptor.capsules == 0 and descriptor.plan_digest == 0
			and report.capsule_plan_pending == true and report.capsules_published == 0,
			"first-canonical-rebuild"
	end
	if descriptor.state == "surface-capsules-published-awaiting-final-grid" then
		return #descriptor.capsules == 2 and descriptor.plan_digest > 0
			and report.capsules_published == 2 and report.deterministic_repeat == true
			and report.final_grid_revalidation ~= true,
			"closing-canonical-rebuild"
	end
	return false
end

local function validate(surface)
	local descriptor, report = surface.descriptor, surface.report
	if descriptor.state == "ready-for-first-access" or descriptor.state == "complete" then
		return true, descriptor.state
	end
	local owned, phase = owned_in_flight(surface, descriptor, report)
	if owned then return true, phase end
	descriptor.state = "blocked"
	descriptor.failure_sticky = true
	descriptor.failure = "persisted incomplete lazy state"
	return false, "blocked"
end

local function new_surface()
	local descriptor = {
		state = "suppressed-awaiting-surface-capsules", implementation = true,
		map_slot = 2, reserved_seed = 314159, suppression_committed = true,
		suppression_used = true, literal_v964_continues = false, failure_sticky = false,
		failure = "", materialization_attempts = 0, generation_count = 0,
		capsules = {}, plan_digest = 0,
	}
	local report = {
		suppression_committed = true, suppression_used = true,
		literal_v964_continues = false, shadow_only = false,
		materialization_running = false, capsule_plan_pending = true, capsules_published = 0,
	}
	return {
		environment = "Surface", descriptor = descriptor, report = report,
		stretch_pipeline_pending = true, surface_stretch_done = false,
		surface_stretch_scheduled = true, post_pipeline_revalidation_scheduled = true,
		post_pipeline_revalidation_complete = false,
	}
end

local live = new_surface()
live_transactions[live] = {
	descriptor = live.descriptor, report = live.report,
	map_slot = live.descriptor.map_slot, reserved_seed = live.descriptor.reserved_seed,
}
loading_refs[live] = true
local first_ok, first_phase = validate(live)
local first_reentry_exact = first_ok and first_phase == "first-canonical-rebuild"
	and live.descriptor.state == "suppressed-awaiting-surface-capsules"

live.descriptor.state = "surface-capsules-published-awaiting-final-grid"
live.descriptor.capsules = { { q = 1 }, { q = 2 } }
live.descriptor.plan_digest = 99
live.report.capsule_plan_pending = false
live.report.capsules_published = 2
live.report.deterministic_repeat = true
live.report.final_grid_revalidation = false
local closing_ok, closing_phase = validate(live)
local closing_reentry_exact = closing_ok and closing_phase == "closing-canonical-rebuild"
	and live.descriptor.state == "surface-capsules-published-awaiting-final-grid"

-- Same serialized values, different map object, and no weak transaction owner: a reload is blocked.
local loaded = new_surface()
loading_refs[loaded] = true
local loaded_ok = validate(loaded)
local loaded_incomplete_rejected = loaded_ok == false and loaded.descriptor.state == "blocked"
	and loaded.descriptor.failure_sticky == true

local coverless = new_surface()
live_transactions[coverless] = {
	descriptor = coverless.descriptor, report = coverless.report,
	map_slot = coverless.descriptor.map_slot, reserved_seed = coverless.descriptor.reserved_seed,
}
local coverless_ok = validate(coverless)
local cover_required = coverless_ok == false and coverless.descriptor.state == "blocked"

local pending_restore = new_surface()
live_transactions[pending_restore] = {
	descriptor = pending_restore.descriptor, report = pending_restore.report,
	map_slot = pending_restore.descriptor.map_slot,
	reserved_seed = pending_restore.descriptor.reserved_seed,
}
loading_refs[pending_restore] = true
globals.restore_tokens = { {} }
local restore_ok = validate(pending_restore)
globals.restore_tokens = nil
local no_restore_tokens_required = restore_ok == false
	and pending_restore.descriptor.state == "blocked"

local ok = first_reentry_exact and closing_reentry_exact and loaded_incomplete_rejected
	and cover_required and no_restore_tokens_required
print("ok=" .. tostring(ok))
print("first_reentry_exact=" .. tostring(first_reentry_exact))
print("closing_reentry_exact=" .. tostring(closing_reentry_exact))
print("loaded_incomplete_rejected=" .. tostring(loaded_incomplete_rejected))
print("cover_required=" .. tostring(cover_required))
print("no_restore_tokens_required=" .. tostring(no_restore_tokens_required))
if not ok then os.exit(1) end

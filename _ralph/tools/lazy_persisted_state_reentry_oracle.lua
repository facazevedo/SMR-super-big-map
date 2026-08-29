-- Deterministic Lua 5.3 model for the v980 persisted-state/live-rebuild distinction.
-- A process-local owner proves the exact pre-cover 000 phase. The two canonical 111 phases also
-- require the Surface loading cover. Identical serialized state after reload remains fail-closed.
local live_transactions = setmetatable({}, { __mode = "k" })
local loading_refs = setmetatable({}, { __mode = "k" })
local globals = { Maps = {}, UndergroundMap = nil, restore_tokens = nil, visible = true }

local function failed(invariant, actual)
	return false, nil, tostring(invariant) .. "=" .. tostring(actual)
end

local function owned_in_flight(surface, descriptor, report)
	local owner = live_transactions[surface]
	if type(owner) ~= "table" then return failed("process_local_owner", type(owner)) end
	if owner.descriptor ~= descriptor then return failed("owner_descriptor_identity", false) end
	if owner.report ~= report then return failed("owner_report_identity", false) end
	if owner.map_slot ~= descriptor.map_slot then return failed("owner_map_slot", owner.map_slot) end
	if owner.reserved_seed ~= descriptor.reserved_seed then
		return failed("owner_reserved_seed", owner.reserved_seed)
	end
	if surface.environment ~= "Surface" then return failed("surface_environment", surface.environment) end
	if descriptor.map_slot ~= 2 then return failed("descriptor_map_slot", descriptor.map_slot) end
	if descriptor.implementation ~= true then
		return failed("descriptor_implementation", descriptor.implementation)
	end
	if descriptor.suppression_committed ~= true or descriptor.suppression_used ~= true
		or descriptor.literal_v964_continues ~= false
		or descriptor.failure_sticky == true or descriptor.failure ~= ""
		or report.suppression_committed ~= true or report.suppression_used ~= true
		or report.literal_v964_continues ~= false or report.shadow_only ~= false
		or report.materialization_running == true
		or descriptor.materialization_attempts ~= 0 or descriptor.generation_count ~= 0 then
		return failed("common_suppression_contract", false)
	end
	if globals.UndergroundMap then return failed("underground_map_absent", false) end
	if globals.Maps[descriptor.map_slot] then
		return failed("maps_slot_absent", false)
	end
	if type(globals.restore_tokens) == "table" and #globals.restore_tokens > 0 then
		return failed("pending_engine_restore_tokens", #globals.restore_tokens)
	end
	if surface.surface_stretch_done == true then
		return failed("surface_stretch_done", surface.surface_stretch_done)
	end
	if surface.post_pipeline_revalidation_complete == true then
		return failed("post_pipeline_revalidation_complete", true)
	end
	if surface.post_pipeline_revalidation_error ~= nil then
		return failed("post_pipeline_revalidation_error", surface.post_pipeline_revalidation_error)
	end
	local function canonical_loading_cover(phase)
		if loading_refs[surface] ~= true then
			return failed("canonical_loading_cover", false)
		end
		if globals.visible ~= true then
			return failed("canonical_loading_visible", globals.visible)
		end
		return true, phase
	end

	local pending = surface.stretch_pipeline_pending == true
	local stretch_scheduled = surface.surface_stretch_scheduled == true
	local post_scheduled = surface.post_pipeline_revalidation_scheduled == true
	if descriptor.state == "suppressed-awaiting-surface-capsules" then
		local exact = #descriptor.capsules == 0 and descriptor.plan_digest == 0
			and report.capsule_plan_pending == true and report.capsules_published == 0
		if not exact then return failed("suppressed_capsule_contract", false) end
		if not pending and not stretch_scheduled and not post_scheduled then
			if loading_refs[surface] == true then
				return failed("pre_surface_loading_cover", true)
			end
			return true, "pre-surface-pipeline"
		end
		if pending and stretch_scheduled and post_scheduled then
			return canonical_loading_cover("first-canonical-rebuild")
		end
		return failed("suppressed_phase_markers",
			tostring(pending) .. "/" .. tostring(stretch_scheduled) .. "/" .. tostring(post_scheduled))
	end
	if descriptor.state == "surface-capsules-published-awaiting-final-grid" then
		if not pending or not stretch_scheduled or not post_scheduled then
			return failed("closing_phase_markers", false)
		end
		local exact = #descriptor.capsules == 2 and descriptor.plan_digest > 0
			and report.capsules_published == 2 and report.deterministic_repeat == true
			and report.final_grid_revalidation ~= true
		if not exact then return failed("closing_capsule_contract", false) end
		return canonical_loading_cover("closing-canonical-rebuild")
	end
	return failed("descriptor_state", descriptor.state)
end

local function validate(surface)
	local descriptor, report = surface.descriptor, surface.report
	local owned, phase, guard = owned_in_flight(surface, descriptor, report)
	if owned then return true, phase, nil end
	descriptor.state = "blocked"
	descriptor.failure_sticky = true
	descriptor.failure = "persisted incomplete lazy state"
	return false, "blocked", guard
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
		stretch_pipeline_pending = false, surface_stretch_done = false,
		surface_stretch_scheduled = false, post_pipeline_revalidation_scheduled = false,
		post_pipeline_revalidation_complete = false,
	}
end

local function own(surface, cover)
	live_transactions[surface] = {
		descriptor = surface.descriptor, report = surface.report,
		map_slot = surface.descriptor.map_slot, reserved_seed = surface.descriptor.reserved_seed,
	}
	if cover ~= false then loading_refs[surface] = true end
end

local function publish_capsules(surface)
	surface.descriptor.state = "surface-capsules-published-awaiting-final-grid"
	surface.descriptor.capsules = { { q = 1 }, { q = 2 } }
	surface.descriptor.plan_digest = 99
	surface.report.capsule_plan_pending = false
	surface.report.capsules_published = 2
	surface.report.deterministic_repeat = true
	surface.report.final_grid_revalidation = false
end

local function rejected(surface, expected_guard)
	local ok, _, guard = validate(surface)
	return ok == false and surface.descriptor.state == "blocked"
		and surface.descriptor.failure_sticky == true
		and (not expected_guard or guard:match("^" .. expected_guard .. "=")) ~= nil
end

local live = new_surface()
own(live, false)
local pre_ok, pre_phase = validate(live)
local pre_pipeline_reentry_exact = pre_ok and pre_phase == "pre-surface-pipeline"
	and live.descriptor.state == "suppressed-awaiting-surface-capsules"

loading_refs[live] = true
live.stretch_pipeline_pending = true
live.surface_stretch_scheduled = true
live.post_pipeline_revalidation_scheduled = true
local first_ok, first_phase = validate(live)
local first_reentry_exact = first_ok and first_phase == "first-canonical-rebuild"
	and live.descriptor.state == "suppressed-awaiting-surface-capsules"

publish_capsules(live)
local closing_ok, closing_phase = validate(live)
local closing_reentry_exact = closing_ok and closing_phase == "closing-canonical-rebuild"
	and live.descriptor.state == "surface-capsules-published-awaiting-final-grid"
local nil_sentinels_all_phases_accepted = pre_pipeline_reentry_exact
	and first_reentry_exact and closing_reentry_exact

-- Surviving Mars represents an unloaded engine map with literal false as well as nil. Both
-- globals may carry that sentinel and must remain accepted through every exact owned phase.
globals.UndergroundMap = false
globals.Maps[2] = false
local false_live = new_surface()
own(false_live, false)
local false_pre_ok, false_pre_phase = validate(false_live)
loading_refs[false_live] = true
false_live.stretch_pipeline_pending = true
false_live.surface_stretch_scheduled = true
false_live.post_pipeline_revalidation_scheduled = true
local false_first_ok, false_first_phase = validate(false_live)
publish_capsules(false_live)
local false_closing_ok, false_closing_phase = validate(false_live)
local false_sentinels_all_phases_accepted = false_pre_ok
	and false_pre_phase == "pre-surface-pipeline"
	and false_first_ok and false_first_phase == "first-canonical-rebuild"
	and false_closing_ok and false_closing_phase == "closing-canonical-rebuild"
globals.UndergroundMap = nil
globals.Maps[2] = nil

local real_underground = new_surface()
own(real_underground)
globals.UndergroundMap = {}
local real_underground_map_rejected = rejected(real_underground, "underground_map_absent")
globals.UndergroundMap = nil

local occupied_maps_slot = new_surface()
own(occupied_maps_slot)
globals.Maps[2] = {}
local occupied_maps_slot_rejected = rejected(occupied_maps_slot, "maps_slot_absent")
globals.Maps[2] = nil

-- Reloaded state and a separately modeled ownerless live-looking state both lack the weak owner.
globals.UndergroundMap = false
globals.Maps[2] = false
local loaded = new_surface()
loading_refs[loaded] = true
local loaded_incomplete_rejected = rejected(loaded, "process_local_owner")
local ownerless = new_surface()
loading_refs[ownerless] = true
local ownerless_rejected = rejected(ownerless, "process_local_owner")
globals.UndergroundMap = nil
globals.Maps[2] = nil

-- Both nil and literal-false refs are exact pre-cover values, and overall loading visibility is
-- deliberately ignored in this phase. A true Surface ref would contradict the observed ordering.
local pre_false_cover = new_surface()
own(pre_false_cover, false)
loading_refs[pre_false_cover] = false
globals.visible = false
local pre_false_ok, pre_false_phase = validate(pre_false_cover)
globals.visible = true
local pre_nil_and_false_cover_accepted = pre_pipeline_reentry_exact
	and pre_false_ok and pre_false_phase == "pre-surface-pipeline"
local pre_visibility_not_gated = pre_pipeline_reentry_exact and pre_false_ok

local pre_covered = new_surface()
own(pre_covered)
local pre_true_cover_rejected = rejected(pre_covered, "pre_surface_loading_cover")

local first_coverless = new_surface()
first_coverless.stretch_pipeline_pending = true
first_coverless.surface_stretch_scheduled = true
first_coverless.post_pipeline_revalidation_scheduled = true
own(first_coverless, false)
local first_coverless_rejected = rejected(first_coverless, "canonical_loading_cover")
local closing_coverless = new_surface()
closing_coverless.stretch_pipeline_pending = true
closing_coverless.surface_stretch_scheduled = true
closing_coverless.post_pipeline_revalidation_scheduled = true
publish_capsules(closing_coverless)
own(closing_coverless, false)
local closing_coverless_rejected = rejected(closing_coverless, "canonical_loading_cover")
local canonical_coverless_all_phases_rejected =
	first_coverless_rejected and closing_coverless_rejected

local first_hidden = new_surface()
first_hidden.stretch_pipeline_pending = true
first_hidden.surface_stretch_scheduled = true
first_hidden.post_pipeline_revalidation_scheduled = true
own(first_hidden)
globals.visible = false
local first_hidden_rejected = rejected(first_hidden, "canonical_loading_visible")
globals.visible = true
local closing_hidden = new_surface()
closing_hidden.stretch_pipeline_pending = true
closing_hidden.surface_stretch_scheduled = true
closing_hidden.post_pipeline_revalidation_scheduled = true
publish_capsules(closing_hidden)
own(closing_hidden)
globals.visible = false
local closing_hidden_rejected = rejected(closing_hidden, "canonical_loading_visible")
globals.visible = true
local canonical_hidden_all_phases_rejected = first_hidden_rejected and closing_hidden_rejected
local cover_required = canonical_coverless_all_phases_rejected
	and canonical_hidden_all_phases_rejected and pre_true_cover_rejected

local pending_restore = new_surface()
own(pending_restore)
globals.restore_tokens = { {} }
local no_restore_tokens_required = rejected(pending_restore, "pending_engine_restore_tokens")
globals.restore_tokens = nil

-- The only valid suppressed marker triples are 000 and 111; reject every mixed triple.
local invalid_suppressed_phase_mixtures_rejected = true
local invalid_suppressed_phase_mixture_cases = 0
for mask = 1, 6 do
	local mixed = new_surface()
	mixed.stretch_pipeline_pending = mask % 2 == 1
	mixed.surface_stretch_scheduled = math.floor(mask / 2) % 2 == 1
	mixed.post_pipeline_revalidation_scheduled = math.floor(mask / 4) % 2 == 1
	own(mixed)
	invalid_suppressed_phase_mixture_cases = invalid_suppressed_phase_mixture_cases + 1
	invalid_suppressed_phase_mixtures_rejected =
		invalid_suppressed_phase_mixtures_rejected and rejected(mixed, "suppressed_phase_markers")
end

-- Closing is legal only at 111, so reject all other seven marker triples.
local invalid_closing_phase_mixtures_rejected = true
local invalid_closing_phase_mixture_cases = 0
for mask = 0, 6 do
	local mixed = new_surface()
	mixed.stretch_pipeline_pending = mask % 2 == 1
	mixed.surface_stretch_scheduled = math.floor(mask / 2) % 2 == 1
	mixed.post_pipeline_revalidation_scheduled = math.floor(mask / 4) % 2 == 1
	publish_capsules(mixed)
	own(mixed)
	invalid_closing_phase_mixture_cases = invalid_closing_phase_mixture_cases + 1
	invalid_closing_phase_mixtures_rejected =
		invalid_closing_phase_mixtures_rejected and rejected(mixed, "closing_phase_markers")
end

local done = new_surface()
done.surface_stretch_done = true
own(done)
local done_rejected = rejected(done, "surface_stretch_done")
local errored = new_surface()
errored.post_pipeline_revalidation_error = "forced"
own(errored)
local error_rejected = rejected(errored, "post_pipeline_revalidation_error")
local pre_done_or_error_rejected = done_rejected and error_rejected

local ok = pre_pipeline_reentry_exact and first_reentry_exact and closing_reentry_exact
	and nil_sentinels_all_phases_accepted and false_sentinels_all_phases_accepted
	and real_underground_map_rejected and occupied_maps_slot_rejected
	and loaded_incomplete_rejected and ownerless_rejected and cover_required
	and pre_nil_and_false_cover_accepted and pre_visibility_not_gated
	and pre_true_cover_rejected and canonical_coverless_all_phases_rejected
	and canonical_hidden_all_phases_rejected
	and no_restore_tokens_required and invalid_suppressed_phase_mixtures_rejected
	and invalid_closing_phase_mixtures_rejected and pre_done_or_error_rejected
print("ok=" .. tostring(ok))
print("pre_pipeline_reentry_exact=" .. tostring(pre_pipeline_reentry_exact))
print("first_reentry_exact=" .. tostring(first_reentry_exact))
print("closing_reentry_exact=" .. tostring(closing_reentry_exact))
print("nil_sentinels_all_phases_accepted=" .. tostring(nil_sentinels_all_phases_accepted))
print("false_sentinels_all_phases_accepted=" .. tostring(false_sentinels_all_phases_accepted))
print("real_underground_map_rejected=" .. tostring(real_underground_map_rejected))
print("occupied_maps_slot_rejected=" .. tostring(occupied_maps_slot_rejected))
print("loaded_incomplete_rejected=" .. tostring(loaded_incomplete_rejected))
print("ownerless_rejected=" .. tostring(ownerless_rejected))
print("cover_required=" .. tostring(cover_required))
print("pre_nil_and_false_cover_accepted=" .. tostring(pre_nil_and_false_cover_accepted))
print("pre_visibility_not_gated=" .. tostring(pre_visibility_not_gated))
print("pre_true_cover_rejected=" .. tostring(pre_true_cover_rejected))
print("canonical_coverless_all_phases_rejected="
	.. tostring(canonical_coverless_all_phases_rejected))
print("canonical_hidden_all_phases_rejected="
	.. tostring(canonical_hidden_all_phases_rejected))
print("no_restore_tokens_required=" .. tostring(no_restore_tokens_required))
print("invalid_suppressed_phase_mixtures_rejected="
	.. tostring(invalid_suppressed_phase_mixtures_rejected))
print("invalid_suppressed_phase_mixture_cases=" .. invalid_suppressed_phase_mixture_cases)
print("invalid_closing_phase_mixtures_rejected="
	.. tostring(invalid_closing_phase_mixtures_rejected))
print("invalid_closing_phase_mixture_cases=" .. invalid_closing_phase_mixture_cases)
print("pre_done_or_error_rejected=" .. tostring(pre_done_or_error_rejected))
if not ok then os.exit(1) end

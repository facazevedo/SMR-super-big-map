-- Deterministic Lua 5.3 model for v986 live materialization re-entry.
-- Only a weak process-local owner can distinguish a same-session `generating` descriptor from a
-- serialized/reloaded interrupted transaction. A sticky callback failure must never be overwritten.
local owners = setmetatable({}, { __mode = "k" })
local globals = { maps = {}, underground = nil, restore_tokens = nil }

local function base()
	local descriptor = {
		state = "generating", implementation = true, map_slot = 2, reserved_seed = 314159,
		suppression_committed = true, suppression_used = true, literal_v964_continues = false,
		failure = "", failure_sticky = false, materialization_attempts = 1,
		generation_count = 0, capsule_planner_version = 7, plan_digest = 529881249,
		validation_z_digest = 400807124,
		capsules = { { validation_z = 31312 }, { validation_z = 31312 } },
	}
	local report = {
		suppression_committed = true, suppression_used = true, literal_v964_continues = false,
		shadow_only = false, materialization_attempts = 1,
		materialization_route = "change-current-map-slot", materialization_running = true,
		materialization_complete = false, access_blocked = false, failure_sticky = false, error = "",
		capsules_published = 2, validation_z_certificates = 2,
		validation_z_digest = descriptor.validation_z_digest, deterministic_repeat = true,
		final_grid_revalidation = true, persisted_state_live_reentry_allowed = true,
		persisted_state_live_reentry_count = 2,
		persisted_state_live_reentry_phase_sequence =
			"pre-surface-pipeline>closing-canonical-rebuild",
		persisted_state_materialization_reentry_allowed = false,
		persisted_state_materialization_reentry_phase = "",
		persisted_state_materialization_reentry_count = 0,
		persisted_state_materialization_reentry_phase_sequence = "",
	}
	return {
		environment = "Surface", descriptor = descriptor, report = report,
		stretch_done = true, pipeline_pending = false, post_complete = true,
		post_error = nil,
	}
end

local function own(surface)
	owners[surface] = {
		descriptor = surface.descriptor, report = surface.report,
		map_slot = surface.descriptor.map_slot, reserved_seed = surface.descriptor.reserved_seed,
		route = surface.report.materialization_route, attempt = 1,
	}
end

local function failed(name, actual)
	return false, nil, tostring(name) .. "=" .. tostring(actual)
end

local function owned(surface)
	local descriptor, report = surface.descriptor, surface.report
	local owner = owners[surface]
	if type(owner) ~= "table" then return failed("process_local_owner", type(owner)) end
	if owner.descriptor ~= descriptor or owner.report ~= report then
		return failed("owner_identity", false)
	end
	if owner.map_slot ~= descriptor.map_slot or owner.reserved_seed ~= descriptor.reserved_seed
		or owner.route ~= report.materialization_route or owner.attempt ~= 1
		or owner.attempt ~= descriptor.materialization_attempts then
		return failed("owner_transaction_identity", false)
	end
	if surface.environment ~= "Surface" or descriptor.state ~= "generating"
		or descriptor.map_slot ~= 2 or descriptor.implementation ~= true
		or descriptor.suppression_committed ~= true or descriptor.suppression_used ~= true
		or descriptor.literal_v964_continues ~= false or descriptor.failure_sticky == true
		or descriptor.failure ~= "" or descriptor.materialization_attempts ~= 1 then
		return failed("descriptor_contract", false)
	end
	if descriptor.generation_count ~= 0 and descriptor.generation_count ~= 1 then
		return failed("generation_count", descriptor.generation_count)
	end
	if report.materialization_running ~= true or report.materialization_complete == true
		or report.access_blocked == true or report.failure_sticky == true or report.error ~= ""
		or report.materialization_attempts ~= 1 or report.materialization_route ~= owner.route then
		return failed("report_contract", false)
	end
	if surface.stretch_done ~= true or surface.pipeline_pending == true
		or surface.post_complete ~= true or surface.post_error ~= nil then
		return failed("surface_final_contract", false)
	end
	if #descriptor.capsules ~= 2 or descriptor.capsule_planner_version ~= 7
		or descriptor.plan_digest <= 0 or descriptor.validation_z_digest <= 0
		or report.capsules_published ~= 2 or report.validation_z_certificates ~= 2
		or report.validation_z_digest ~= descriptor.validation_z_digest
		or report.deterministic_repeat ~= true or report.final_grid_revalidation ~= true
		or report.persisted_state_live_reentry_allowed ~= true
		or report.persisted_state_live_reentry_count ~= 2
		or report.persisted_state_live_reentry_phase_sequence
			~= "pre-surface-pipeline>closing-canonical-rebuild" then
		return failed("surface_certificate", false)
	end
	for _, capsule in ipairs(descriptor.capsules) do
		local z = capsule.validation_z
		if type(z) ~= "number" or z ~= z or z ~= math.floor(z) or z < 0 or z >= 65535 then
			return failed("validation_z", z)
		end
	end
	if type(globals.restore_tokens) == "table" and #globals.restore_tokens > 0 then
		return failed("pending_restore_tokens", #globals.restore_tokens)
	end
	local map = globals.maps[descriptor.map_slot]
	if globals.underground and map ~= globals.underground then
		return failed("underground_identity", false)
	end
	if descriptor.generation_count == 1 and not map then return failed("generated_map_absent", false) end
	if map and map.environment ~= "Underground" then return failed("underground_environment", map.environment) end
	if map then
		return true, descriptor.generation_count == 1 and "materialization-deferred-pipeline"
			or (globals.underground == map and "materialization-native-callback"
				or "materialization-native-map-load")
	end
	return true, "materialization-pre-publication"
end

local function validate(surface)
	local ok, phase, guard = owned(surface)
	if not ok then
		owners[surface] = nil
		surface.descriptor.state = "blocked"
		surface.descriptor.failure_sticky = true
		surface.descriptor.failure = "interrupted: " .. tostring(guard)
		surface.report.materialization_running = false
		surface.report.access_blocked = true
		return false, guard
	end
	local report = surface.report
	report.persisted_state_materialization_reentry_allowed = true
	report.persisted_state_materialization_reentry_phase = phase
	report.persisted_state_materialization_reentry_count =
		(report.persisted_state_materialization_reentry_count or 0) + 1
	local sequence = report.persisted_state_materialization_reentry_phase_sequence
	report.persisted_state_materialization_reentry_phase_sequence = sequence == ""
		and phase or sequence .. ">" .. phase
	return true, phase
end

local function rejected(mutator, guard_prefix)
	globals.maps, globals.underground, globals.restore_tokens = {}, nil, nil
	local surface = base()
	own(surface)
	mutator(surface, owners[surface])
	local ok, guard = validate(surface)
	return not ok and surface.descriptor.state == "blocked"
		and surface.descriptor.failure_sticky == true and owners[surface] == nil
		and tostring(guard):match("^" .. guard_prefix .. "=") ~= nil
end

globals.maps, globals.underground = {}, nil
local pre = base()
own(pre)
local pre_ok, pre_phase = validate(pre)

local callback_map = { environment = "Underground" }
globals.maps, globals.underground = { [2] = callback_map }, nil
local map_load = base()
own(map_load)
local map_load_ok, map_load_phase = validate(map_load)

globals.maps, globals.underground = { [2] = callback_map }, callback_map
local callback = base()
own(callback)
local callback_ok, callback_phase = validate(callback)

local pipeline_map = { environment = "Underground" }
globals.maps, globals.underground = { [2] = pipeline_map }, pipeline_map
local pipeline = base()
pipeline.descriptor.generation_count = 1
own(pipeline)
local pipeline_ok, pipeline_phase = validate(pipeline)

local loaded_ownerless = rejected(function(surface) owners[surface] = nil end,
	"process_local_owner")
local owner_mismatch = rejected(function(_, owner) owner.route = "wrong" end,
	"owner_transaction_identity")
local pending_restore = rejected(function() globals.restore_tokens = { {} } end,
	"pending_restore_tokens")
local wrong_map_identity = rejected(function()
	globals.maps[2], globals.underground = { environment = "Underground" },
		{ environment = "Underground" }
end, "underground_identity")
local invalid_generation = rejected(function(surface) surface.descriptor.generation_count = 2 end,
	"generation_count")
local invalid_validation_z = rejected(function(surface)
	 surface.descriptor.capsules[1].validation_z = 65535
end, "validation_z")

-- Simulate a nested callback blocking while the outer protected transaction later returns a map.
globals.maps, globals.underground, globals.restore_tokens = {}, nil, nil
local sticky = base()
own(sticky)
owners[sticky] = nil
sticky.descriptor.state, sticky.descriptor.failure_sticky = "blocked", true
sticky.descriptor.failure = "nested callback blocked"
sticky.report.materialization_running, sticky.report.access_blocked = false, true
local outer_returned_map = { environment = "Underground" }
local still_owned = owned(sticky)
if still_owned then error("blocked transaction unexpectedly retained ownership") end
local callback_block_never_overwritten = sticky.descriptor.state == "blocked"
	and sticky.descriptor.failure == "nested callback blocked"
	and sticky.descriptor.failure_sticky == true and outer_returned_map ~= nil

-- Normal final publication verifies ownership before committing and clears its process-local token.
globals.maps, globals.underground = { [2] = pipeline_map }, pipeline_map
local success = base()
success.descriptor.generation_count = 1
own(success)
local success_owned = owned(success)
if success_owned then
	success.descriptor.state = "complete"
	success.report.materialization_running = false
	success.report.materialization_complete = true
	owners[success] = nil
end
local success_commits_and_clears_owner = success_owned and success.descriptor.state == "complete"
	and success.report.materialization_complete == true and owners[success] == nil

local exact_phase_history = pre_ok and map_load_ok and callback_ok and pipeline_ok
	and pre_phase == "materialization-pre-publication"
	and map_load_phase == "materialization-native-map-load"
	and callback_phase == "materialization-native-callback"
	and pipeline_phase == "materialization-deferred-pipeline"
	and pipeline.report.persisted_state_materialization_reentry_allowed == true
	and pipeline.report.persisted_state_materialization_reentry_count == 1

local ok = exact_phase_history and loaded_ownerless and owner_mismatch and pending_restore
	and wrong_map_identity and invalid_generation and invalid_validation_z
	and callback_block_never_overwritten and success_commits_and_clears_owner
print("ok=" .. tostring(ok))
print("exact_phase_history=" .. tostring(exact_phase_history))
print("pre_phase=" .. tostring(pre_phase))
print("map_load_phase=" .. tostring(map_load_phase))
print("callback_phase=" .. tostring(callback_phase))
print("pipeline_phase=" .. tostring(pipeline_phase))
print("loaded_ownerless=" .. tostring(loaded_ownerless))
print("owner_mismatch=" .. tostring(owner_mismatch))
print("pending_restore=" .. tostring(pending_restore))
print("wrong_map_identity=" .. tostring(wrong_map_identity))
print("invalid_generation=" .. tostring(invalid_generation))
print("invalid_validation_z=" .. tostring(invalid_validation_z))
print("callback_block_never_overwritten=" .. tostring(callback_block_never_overwritten))
print("success_commits_and_clears_owner=" .. tostring(success_commits_and_clears_owner))
if not ok then os.exit(1) end

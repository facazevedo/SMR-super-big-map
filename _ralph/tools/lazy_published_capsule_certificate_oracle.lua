-- Deterministic Lua 5.3 model for the v983 published-capsule certificate.

local function fixture()
	local surface = {}
	local descriptor = {
		state = "surface-capsules-published-awaiting-final-grid",
		plan_digest = 983289,
		capsules = {
			{ index = 1, x = 100, y = 200, angle = 0, published = true },
			{ index = 2, x = 300, y = 400, angle = 3600, published = true },
		},
	}
	local report = {
		capsules_published = 2,
		surface_capsule_objects_persisted = true,
		native_source_retention_released_before_t1 = true,
		deterministic_repeat = true,
		capsule_validation_contract_exact = true,
		plan_digest = descriptor.plan_digest,
		main_depth_zero_validation_exact = true,
		plan_safe_for_publication = true,
		full_validation_complete = true,
		publication_validation_calls = 2,
		publication_validation_exact_centers = 2,
		publication_validation_depth = 0,
		full_search_mismatches = 0,
		replay_depth_zero_validation_exact = true,
		repeat_plan_safe_for_publication = true,
		repeat_full_validation_complete = true,
		repeat_publication_validation_calls = 0,
		repeat_publication_validation_exact_centers = 0,
		repeat_publication_validation_depth = 0,
		fresh_grid_architecture_used = true,
		fresh_grid_expected_rebuilds = 2,
		fresh_grid_first_rebuild_complete = true,
		fresh_grid_closing_rebuild_complete = true,
		fresh_grid_rebuild_shape_exact = true,
		canonical_rebuilds_during_capsule_prepare = 2,
		canonical_rebuild_fallbacks_during_capsule_prepare = 0,
	}
	local placement_calls = 0
	local passages, markers, signs = {}, {}, {}
	for index, capsule in ipairs(descriptor.capsules) do
		local passage = {
			valid = true, map = surface, capsule_index = index,
			x = capsule.x, y = capsule.y, angle = capsule.angle, other = nil,
			IsValidPlacement = function()
				placement_calls = placement_calls + 1
				return false -- The committed object self-obstructs this ambient diagnostic predicate.
			end,
		}
		local marker = { valid = true, spawner = passage }
		local sign = { valid = true, tunnel_marker = marker }
		marker.tunnel_sign = sign
		passages[#passages + 1] = passage
		markers[#markers + 1] = marker
		signs[#signs + 1] = sign
	end
	return {
		surface = surface, descriptor = descriptor, report = report,
		passages = passages, markers = markers, signs = signs,
		placement_calls = function() return placement_calls end,
	}
end

local function certificate(descriptor, report)
	if descriptor.state ~= "surface-capsules-published-awaiting-final-grid"
		and descriptor.state ~= "ready-for-first-access" then return false end
	if #descriptor.capsules ~= 2 or descriptor.plan_digest <= 0 then return false end
	for index, capsule in ipairs(descriptor.capsules) do
		if capsule.index ~= index or capsule.published ~= true then return false end
	end
	if report.capsules_published ~= 2
		or report.surface_capsule_objects_persisted ~= true
		or report.native_source_retention_released_before_t1 ~= true
		or report.deterministic_repeat ~= true
		or report.capsule_validation_contract_exact ~= true
		or report.plan_digest ~= descriptor.plan_digest then return false end
	if report.main_depth_zero_validation_exact ~= true
		or report.plan_safe_for_publication ~= true
		or report.full_validation_complete ~= true
		or report.publication_validation_calls ~= 2
		or report.publication_validation_exact_centers ~= 2
		or report.publication_validation_depth ~= 0
		or report.full_search_mismatches ~= 0 then return false end
	if report.replay_depth_zero_validation_exact ~= true
		or report.repeat_plan_safe_for_publication ~= true
		or report.repeat_full_validation_complete ~= true
		or report.repeat_publication_validation_calls ~= 0
		or report.repeat_publication_validation_exact_centers ~= 0
		or report.repeat_publication_validation_depth ~= 0 then return false end
	return report.fresh_grid_architecture_used == true
		and report.fresh_grid_expected_rebuilds == 2
		and report.fresh_grid_first_rebuild_complete == true
		and report.fresh_grid_closing_rebuild_complete == true
		and report.fresh_grid_rebuild_shape_exact == true
		and report.canonical_rebuilds_during_capsule_prepare == 2
		and report.canonical_rebuild_fallbacks_during_capsule_prepare == 0
end

local function validate(case)
	if not certificate(case.descriptor, case.report) then return false, "certificate" end
	local found, counts = {}, {}
	for _, passage in ipairs(case.passages) do
		local index = passage.capsule_index
		if case.descriptor.capsules[index] then
			counts[index] = (counts[index] or 0) + 1
			if counts[index] == 1 then found[index] = passage end
		end
	end
	local marker_lists = {}
	for index, capsule in ipairs(case.descriptor.capsules) do
		local passage = found[index]
		if counts[index] ~= 1 or not passage then return false, "passage-count" end
		if passage.x ~= capsule.x or passage.y ~= capsule.y then return false, "moved" end
		if passage.angle ~= capsule.angle then return false, "angle" end
		if passage.other then return false, "linked" end
		if passage.valid ~= true or passage.map ~= case.surface then return false, "invalid" end
		marker_lists[passage] = {}
	end
	for _, marker in ipairs(case.markers) do
		local list = marker_lists[marker.spawner]
		if list then list[#list + 1] = marker end
	end
	local sign_lists = {}
	for _, sign in ipairs(case.signs) do
		local marker = sign.tunnel_marker
		local list = sign_lists[marker]
		if not list then list = {}; sign_lists[marker] = list end
		list[#list + 1] = sign
	end
	for _, passage in ipairs(found) do
		local marker_list = marker_lists[passage]
		if #marker_list ~= 1 then return false, "marker-count" end
		local marker = marker_list[1]
		if marker.valid ~= true or marker.spawner ~= passage then return false, "marker-invalid" end
		local sign_list = sign_lists[marker] or {}
		if #sign_list ~= 1 then return false, "sign-count" end
		local sign = sign_list[1]
		if sign.valid ~= true or marker.tunnel_sign ~= sign
			or sign.tunnel_marker ~= marker then return false, "sign-invalid" end
	end
	return true
end

local healthy = fixture()
local healthy_ok = validate(healthy)

local moved = fixture(); moved.passages[1].x = moved.passages[1].x + 1
local duplicate = fixture(); duplicate.passages[#duplicate.passages + 1] = {
	valid = true, map = duplicate.surface, capsule_index = 1,
	x = 100, y = 200, angle = 0,
}
local linked = fixture(); linked.passages[1].other = {}
local invalid = fixture(); invalid.passages[1].valid = false
local missing_marker = fixture(); table.remove(missing_marker.markers, 1)
local duplicate_marker = fixture(); duplicate_marker.markers[#duplicate_marker.markers + 1] = {
	valid = true, spawner = duplicate_marker.passages[1],
}
local missing_sign = fixture(); table.remove(missing_sign.signs, 1)
local duplicate_sign = fixture(); duplicate_sign.signs[#duplicate_sign.signs + 1] = {
	valid = true, tunnel_marker = duplicate_sign.markers[1],
}
local missing_planner = fixture(); missing_planner.report.main_depth_zero_validation_exact = false
local missing_closing = fixture(); missing_closing.report.fresh_grid_closing_rebuild_complete = false

local checks = {
	healthy_exact_certificate_accepted = healthy_ok == true,
	self_obstructed_is_valid_placement_not_called = healthy.placement_calls() == 0,
	moved_passage_rejected = validate(moved) == false,
	duplicate_passage_rejected = validate(duplicate) == false,
	linked_passage_rejected = validate(linked) == false,
	invalid_passage_rejected = validate(invalid) == false,
	missing_marker_rejected = validate(missing_marker) == false,
	duplicate_marker_rejected = validate(duplicate_marker) == false,
	missing_sign_rejected = validate(missing_sign) == false,
	duplicate_sign_rejected = validate(duplicate_sign) == false,
	missing_planner_certificate_rejected = validate(missing_planner) == false,
	missing_closing_rebuild_certificate_rejected = validate(missing_closing) == false,
}

local ok = true
for _, value in pairs(checks) do ok = ok and value == true end
print("ok=" .. tostring(ok))
for _, key in ipairs({
	"healthy_exact_certificate_accepted",
	"self_obstructed_is_valid_placement_not_called",
	"moved_passage_rejected",
	"duplicate_passage_rejected",
	"linked_passage_rejected",
	"invalid_passage_rejected",
	"missing_marker_rejected",
	"duplicate_marker_rejected",
	"missing_sign_rejected",
	"duplicate_sign_rejected",
	"missing_planner_certificate_rejected",
	"missing_closing_rebuild_certificate_rejected",
}) do
	print(key .. "=" .. tostring(checks[key]))
end
os.exit(ok and 0 or 1)

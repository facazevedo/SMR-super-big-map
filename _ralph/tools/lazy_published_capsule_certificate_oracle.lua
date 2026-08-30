-- Deterministic Lua 5.3 model for the v985 published-capsule certificate.

local function validation_z_digest(descriptor)
	local digest = descriptor.plan_digest
	for index, capsule in ipairs(descriptor.capsules) do
		digest = (digest * 48271 + capsule.validation_z + index) % 2147483647
	end
	return digest == 0 and 1 or digest
end

local function fixture()
	local surface = {}
	local descriptor = {
		state = "surface-capsules-published-awaiting-final-grid",
		plan_digest = 983289,
		capsule_planner_version = 7,
		capsules = {
			{ index = 1, x = 100, y = 200, angle = 0,
				validation_z = 7000, published = true },
			{ index = 2, x = 300, y = 400, angle = 3600,
				validation_z = 9000, published = true },
		},
	}
	descriptor.validation_z_digest = validation_z_digest(descriptor)
	local report = {
		capsules_published = 2,
		surface_capsule_objects_persisted = true,
		native_source_retention_released_before_t1 = true,
		deterministic_repeat = true,
		capsule_validation_contract_exact = true,
		plan_digest = descriptor.plan_digest,
		validation_z_digest = descriptor.validation_z_digest,
		main_depth_zero_validation_exact = true,
		plan_safe_for_publication = true,
		full_validation_complete = true,
		publication_validation_calls = 2,
		publication_validation_exact_centers = 2,
		validation_z_certificates = 2,
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
	if #descriptor.capsules ~= 2 or descriptor.plan_digest <= 0
		or descriptor.validation_z_digest <= 0
		or descriptor.capsule_planner_version ~= 7 then return false end
	for index, capsule in ipairs(descriptor.capsules) do
		if capsule.index ~= index or type(capsule.validation_z) ~= "number"
			or capsule.validation_z ~= capsule.validation_z
			or capsule.validation_z < 0 or capsule.validation_z >= 65535
			or capsule.validation_z ~= math.floor(capsule.validation_z)
			or capsule.published ~= true then return false end
	end
	if descriptor.validation_z_digest ~= validation_z_digest(descriptor)
		or report.validation_z_digest ~= descriptor.validation_z_digest then return false end
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
		or report.validation_z_certificates ~= 2
		or report.publication_validation_depth ~= 0
		or report.full_search_mismatches ~= 0 then return false end
	if report.replay_depth_zero_validation_exact ~= true
		or report.repeat_plan_safe_for_publication ~= true
		or report.repeat_full_validation_complete ~= true
		or report.repeat_publication_validation_calls ~= 0
		or report.repeat_publication_validation_exact_centers ~= 0
		or report.repeat_publication_validation_depth ~= 0 then return false end
	local local_exact = report.surface_single_flush_requested == true
		and report.surface_single_flush_used == true
		and report.surface_single_flush_fallback ~= true
		and report.surface_single_flush_provenance_exact == true
		and report.surface_single_flush_local_passability_calls == 4
		and report.surface_single_flush_buildable_calls == 2
		and report.surface_single_flush_height_snapshots == 2
		and report.surface_single_flush_height_mismatches == 0
		and report.surface_single_flush_object_family_count == 6
		and report.surface_single_flush_object_association_failures == 0
		and report.surface_single_flush_dirty_digest
			== report.outer_passage_pad_finalization_dirty_digest
		and report.surface_single_flush_dirty_regions == 2
		and report.surface_single_flush_coverage_permille > 0
		and report.surface_single_flush_coverage_permille <= 150
		and report.surface_single_flush_closing_complete == true
		and report.surface_single_flush_cleanup_complete == true
		and report.canonical_rebuilds_during_capsule_prepare == 0
	local canonical_exact = report.surface_single_flush_used ~= true
		and report.canonical_rebuilds_during_capsule_prepare >= 1
		and report.canonical_rebuilds_during_capsule_prepare <= 2
	return report.fresh_grid_architecture_used == true
		and report.fresh_grid_first_rebuild_complete == true
		and report.fresh_grid_closing_rebuild_complete == true
		and report.fresh_grid_rebuild_shape_exact == true
		and report.canonical_rebuild_fallbacks_during_capsule_prepare == 0
		and (local_exact or canonical_exact)
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
local local_final = fixture()
local_final.report.surface_single_flush_requested = true
local_final.report.surface_single_flush_used = true
local_final.report.surface_single_flush_fallback = false
local_final.report.surface_single_flush_provenance_exact = true
local_final.report.surface_single_flush_local_passability_calls = 4
local_final.report.surface_single_flush_buildable_calls = 2
local_final.report.surface_single_flush_height_snapshots = 2
local_final.report.surface_single_flush_height_mismatches = 0
local_final.report.surface_single_flush_object_family_count = 6
local_final.report.surface_single_flush_object_association_failures = 0
local_final.report.surface_single_flush_dirty_digest = 782361
local_final.report.outer_passage_pad_finalization_dirty_digest = 782361
local_final.report.surface_single_flush_dirty_regions = 2
local_final.report.surface_single_flush_coverage_permille = 14
local_final.report.surface_single_flush_closing_complete = true
local_final.report.surface_single_flush_cleanup_complete = true
local_final.report.canonical_rebuilds_during_capsule_prepare = 0
local local_final_ok = validate(local_final)
local local_final_height_drift = fixture()
for key, value in pairs(local_final.report) do local_final_height_drift.report[key] = value end
local_final_height_drift.report.surface_single_flush_height_mismatches = 1
local local_final_bad_association = fixture()
for key, value in pairs(local_final.report) do local_final_bad_association.report[key] = value end
local_final_bad_association.report.surface_single_flush_object_association_failures = 1
local local_final_bad_digest = fixture()
for key, value in pairs(local_final.report) do local_final_bad_digest.report[key] = value end
local_final_bad_digest.report.surface_single_flush_dirty_digest = 782362
local local_final_missing_closing = fixture()
for key, value in pairs(local_final.report) do local_final_missing_closing.report[key] = value end
local_final_missing_closing.report.surface_single_flush_closing_complete = false
local local_final_one_buildable = fixture()
for key, value in pairs(local_final.report) do local_final_one_buildable.report[key] = value end
local_final_one_buildable.report.surface_single_flush_buildable_calls = 1

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
local missing_validation_z = fixture(); missing_validation_z.descriptor.capsules[1].validation_z = nil
local missing_validation_z_count = fixture(); missing_validation_z_count.report.validation_z_certificates = 1
local wrong_validation_z = fixture(); wrong_validation_z.descriptor.capsules[1].validation_z = 7001
local invalid_validation_z = fixture(); invalid_validation_z.descriptor.capsules[1].validation_z = 65535
local old_planner = fixture(); old_planner.descriptor.capsule_planner_version = 6

local checks = {
	healthy_exact_certificate_accepted = healthy_ok == true,
	local_single_flush_exact_certificate_accepted = local_final_ok == true,
	local_single_flush_height_drift_rejected = validate(local_final_height_drift) == false,
	local_single_flush_bad_association_rejected = validate(local_final_bad_association) == false,
	local_single_flush_bad_digest_rejected = validate(local_final_bad_digest) == false,
	local_single_flush_missing_closing_rejected = validate(local_final_missing_closing) == false,
	local_single_flush_one_buildable_rejected = validate(local_final_one_buildable) == false,
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
	missing_validation_z_rejected = validate(missing_validation_z) == false,
	missing_validation_z_count_rejected = validate(missing_validation_z_count) == false,
	wrong_validation_z_digest_rejected = validate(wrong_validation_z) == false,
	invalid_validation_z_range_rejected = validate(invalid_validation_z) == false,
	old_planner_schema_rejected = validate(old_planner) == false,
}

local ok = true
for _, value in pairs(checks) do ok = ok and value == true end
print("ok=" .. tostring(ok))
for _, key in ipairs({
	"healthy_exact_certificate_accepted",
	"local_single_flush_exact_certificate_accepted",
	"local_single_flush_height_drift_rejected",
	"local_single_flush_bad_association_rejected",
	"local_single_flush_bad_digest_rejected",
	"local_single_flush_missing_closing_rejected",
	"local_single_flush_one_buildable_rejected",
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
	"missing_validation_z_rejected",
	"missing_validation_z_count_rejected",
	"wrong_validation_z_digest_rejected",
	"invalid_validation_z_range_rejected",
	"old_planner_schema_rejected",
}) do
	print(key .. "=" .. tostring(checks[key]))
end
os.exit(ok and 0 or 1)

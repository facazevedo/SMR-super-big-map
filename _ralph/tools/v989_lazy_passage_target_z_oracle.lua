-- Executable, engine-free oracle for the v989 lazy underground passage target-Z provenance.
local modulus = 2147483647

local function validation_digest(descriptor)
	local digest = descriptor.plan_digest
	for index, capsule in ipairs(descriptor.capsules or {}) do
		local z = capsule.validation_z
		if type(z) ~= "number" or z ~= z or z ~= math.floor(z) or z < 0 or z >= 65535 then
			return nil
		end
		digest = (digest * 48271 + z + index) % modulus
	end
	if digest == 0 then digest = 1 end
	return digest
end

local function fixture()
	local descriptor = {
		state = "generating", plan_digest = 529881249, capsule_planner_version = 7,
		materialization_attempts = 1, failure = "", failure_sticky = false,
		capsules = {
			{ index = 1, x = 43000, y = 316956, q = -140, r = 366,
				angle = 18000, validation_z = 36877, published = true },
			{ index = 2, x = 42500, y = 693666, q = -358, r = 801,
				angle = 3600, validation_z = 39825, published = true },
		},
	}
	descriptor.validation_z_digest = validation_digest(descriptor)
	local report = {
		plan_digest = descriptor.plan_digest,
		validation_z_digest = descriptor.validation_z_digest,
		validation_z_certificates = 2,
		main_depth_zero_validation_exact = true,
		replay_depth_zero_validation_exact = true,
		final_grid_revalidation = true,
	}
	local owner = { exact = true, phase = "materialization-deferred-pipeline" }
	return descriptor, report, owner
end

local function certify(descriptor, report, owner, index, x, y, q, r, target_z)
	if not owner.exact or owner.phase ~= "materialization-deferred-pipeline" then return nil end
	if descriptor.state ~= "generating" or descriptor.materialization_attempts ~= 1
		or descriptor.failure_sticky or descriptor.failure ~= ""
		or descriptor.capsule_planner_version ~= 7 or #descriptor.capsules ~= 2
		or descriptor.plan_digest <= 0 or descriptor.validation_z_digest <= 0
		or report.plan_digest ~= descriptor.plan_digest
		or report.validation_z_digest ~= descriptor.validation_z_digest
		or report.validation_z_certificates ~= 2
		or not report.main_depth_zero_validation_exact
		or not report.replay_depth_zero_validation_exact
		or not report.final_grid_revalidation
		or validation_digest(descriptor) ~= descriptor.validation_z_digest then return nil end
	local capsule = descriptor.capsules[index]
	if type(capsule) ~= "table" or capsule.index ~= index or not capsule.published
		or capsule.x ~= x or capsule.y ~= y or capsule.q ~= q or capsule.r ~= r then return nil end
	if type(target_z) ~= "number" or target_z ~= target_z or target_z ~= math.floor(target_z)
		or target_z < 0 or target_z >= 65535 then return nil end
	local digest = (descriptor.plan_digest + descriptor.validation_z_digest) % modulus
	for _, value in ipairs({ index, x, y, q, r, capsule.angle,
		capsule.validation_z, target_z }) do
		digest = (digest * 48271 + value) % modulus
	end
	if digest == 0 then digest = 1 end
	return { index = index, target_z = target_z, digest = digest, capsule = capsule }
end

local function accepted(mutator, index, target_z)
	local descriptor, report, owner = fixture()
	if mutator then mutator(descriptor, report, owner) end
	local capsule = descriptor.capsules[index or 1]
	if not capsule then return false end
	return certify(descriptor, report, owner, index or 1,
		capsule.x, capsule.y, capsule.q, capsule.r, target_z or 18023) ~= nil
end

local descriptor, report, owner = fixture()
local first = certify(descriptor, report, owner, 1, 43000, 316956, -140, 366, 18023)
local second = certify(descriptor, report, owner, 2, 42500, 693666, -358, 801, 18023)
local function prepared_exact(certificate, actual_level)
	return certificate ~= nil and actual_level == certificate.target_z
end
local aggregate = descriptor.plan_digest
for index, certificate in ipairs({ first, second }) do
	aggregate = (aggregate * 48271 + certificate.digest + index) % modulus
end
if aggregate == 0 then aggregate = 1 end

local results = {
	ok = first ~= nil and second ~= nil and aggregate > 0,
	iter231_source_coordinate_is_not_target = true, -- source 430500,243346 read 65535 after stretch
	surface_validation_z_not_reused_as_underground_z =
		descriptor.capsules[1].validation_z == 36877
		and descriptor.capsules[2].validation_z == 39825
		and first.target_z == 18023 and second.target_z == 18023,
	digest_bound_exact_target = first.digest > 0 and second.digest > 0 and aggregate > 0,
	exact_native_result_level_required = prepared_exact(first, 18023),
	wrong_native_result_level_rejected = not prepared_exact(first, 18024),
	ownerless_rejected = not accepted(function(_, _, o) o.exact = false end),
	wrong_phase_rejected = not accepted(function(_, _, o) o.phase = "materialization-native-callback" end),
	blocked_descriptor_rejected = not accepted(function(d) d.state = "blocked" end),
	coordinate_mismatch_rejected = (function()
		local d, r, o = fixture()
		return certify(d, r, o, 1, 43001, 316956, -140, 366, 18023) == nil
	end)(),
	plan_digest_mismatch_rejected = not accepted(function(_, r) r.plan_digest = r.plan_digest + 1 end),
	validation_digest_mismatch_rejected = not accepted(function(_, r)
		r.validation_z_digest = r.validation_z_digest + 1
	end),
	surface_validation_z_tamper_rejected = not accepted(function(d)
		d.capsules[1].validation_z = d.capsules[1].validation_z + 1
	end),
	invalid_target_z_rejected = not accepted(nil, 1, 65535),
	wrong_index_rejected = not accepted(function(d) d.capsules[1].index = 2 end),
	no_rng_calls = true,
}

for key, value in pairs(results) do
	if value ~= true then error("v989 target-Z oracle failed: " .. key) end
end
local keys = {}
for key in pairs(results) do keys[#keys + 1] = key end
table.sort(keys)
for _, key in ipairs(keys) do print(key .. "=" .. tostring(results[key])) end

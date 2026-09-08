-- Focused production-function regression for bounded direct-seeded surface clusters.
-- Run from the project root:
--   lua _ralph/tools/parity/direct_seeded_topup_test.lua [report-path]

local function read(path)
	local file = assert(io.open(path, "rb"))
	local value = file:read("*a")
	file:close()
	return value
end

local deposits_source = read("Code/sbm_deposits.lua")
local config_source = read("Code/sbm_config.lua")
local metadata_source = read("metadata.lua")
local topup = assert(deposits_source:match(
	"(function DepositRules%.TopUpDeposits.-)\nfunction DepositRules%.TopUpAnomalies"),
	"production DepositRules.TopUpDeposits function not found")

local begin_marker = "-- DIRECT_SEEDED_CLUSTER_PLANNER_BEGIN"
local end_marker = "-- DIRECT_SEEDED_CLUSTER_PLANNER_END"
local planner_start = assert(deposits_source:find(begin_marker, 1, true),
	"production direct planner begin marker missing")
local planner_end = assert(deposits_source:find(end_marker, planner_start, true),
	"production direct planner end marker missing")
local planner_source = deposits_source:sub(planner_start + #begin_marker, planner_end - 1)
local environment = setmetatable({ DepositRules = {} }, { __index = _G })
local chunk, load_error
if _VERSION == "Lua 5.1" then
	chunk, load_error = loadstring(planner_source, "direct_seeded_cluster_planner")
	assert(chunk, load_error)
	setfenv(chunk, environment)
else
	chunk, load_error = load(planner_source, "direct_seeded_cluster_planner", "t", environment)
	assert(chunk, load_error)
end
chunk()
local planner = assert(environment.DepositRules.BuildDirectSeededSurfaceClusterPlans,
	"production direct planner function missing")

local function new_rng(seed)
	local state, calls = seed, 0
	return function(limit)
		assert(type(limit) == "number" and limit > 0)
		state = (state * 48271 + 1) % 2147483647
		calls = calls + 1
		return state % limit
	end, function() return calls end
end

local centers = {}
for index = 1, 12 do
	centers[index] = {
		id = index, q = index * 100, r = index * 7,
		band = index <= 6 and "outer" or "inner",
	}
end
local offsets = {
	{ dq = 0, dr = 0 }, { dq = 3, dr = 0 }, { dq = 0, dr = 3 },
	{ dq = -3, dr = 3 }, { dq = -3, dr = 0 }, { dq = 0, dr = -3 },
}
local specs = {
	{ resource_target = 3, extractor_target = 1, strength = "standard",
		anomaly_capacity = 0, reward_capacity = 3 },
	{ resource_target = 4, extractor_target = 2, strength = "strong",
		anomaly_capacity = 1, reward_capacity = 5 },
	{ resource_target = 3, extractor_target = 1, strength = "standard",
		anomaly_capacity = 0, reward_capacity = 3 },
	{ resource_target = 4, extractor_target = 2, strength = "strong",
		anomaly_capacity = 1, reward_capacity = 5 },
}

local function run(seed)
	local rand_int, rng_calls = new_rng(seed)
	local validation_calls, static_calls, dynamic_calls = 0, 0, 0
	local plans, planner_error, stats = planner({
		centers = centers, offsets = offsets, specs = specs, outer_count = 2,
		cluster_radius = 12, minimum_member_distance = 3,
		rand_int = rand_int,
		classify_center = function(center) return center.band end,
		build_candidate = function(center, center_index, offset, band)
			validation_calls = validation_calls + 1
			assert(center.band == band)
			return {
				q = center.q + offset.dq, r = center.r + offset.dr,
				center = center_index, band = band,
			}
		end,
		validate_static = function(candidate)
			static_calls = static_calls + 1
			return candidate.q ~= nil and candidate.r ~= nil
		end,
		validate_dynamic = function(candidate)
			dynamic_calls = dynamic_calls + 1
			return candidate.q ~= nil and candidate.r ~= nil
		end,
	})
	assert(plans, planner_error)
	assert(#plans == #specs and stats.plans == #specs)
	assert(stats.outer_plans == 2 and stats.inner_plans == 2)
	assert(stats.centers_attempted == #specs)
	assert(stats.candidate_attempts == validation_calls)
	assert(validation_calls == 14, "planner retained more than exact cluster demand")
	assert(stats.static_validations == static_calls and static_calls == 14,
		"planner did not count exact-coordinate static validations")
	assert(stats.static_cache_reuses == 0, "planner reported unexpected static-cache reuse")
	assert(stats.dynamic_validations == dynamic_calls and dynamic_calls == 14,
		"planner did not count mutable placement validations")
	assert(stats.accepted_candidates == 14 and stats.rejected_candidates == 0,
		"planner did not separate attempted/rejected/accepted counts")
	assert(stats.candidate_attempts <= stats.candidate_attempt_budget)
	local encoded = {}
	for index, plan in ipairs(plans) do
		assert(plan.id == index and #plan.candidates == specs[index].resource_target)
		assert(plan.outermost == (index <= 2))
		for _, candidate in ipairs(plan.candidates) do
			assert(candidate.band == (index <= 2 and "outer" or "inner"))
			encoded[#encoded + 1] = table.concat({
				index, candidate.center, candidate.q, candidate.r,
			}, ":")
		end
	end
	return table.concat(encoded, "|"), rng_calls(), stats
end

local first, first_rng_calls, first_stats = run(918273)
local repeat_result, repeat_rng_calls = run(918273)
local different = run(918274)
assert(first == repeat_result, "same private seed did not reproduce plans")
assert(first_rng_calls == repeat_rng_calls, "same private seed changed draw count")
assert(first ~= different, "different private seed did not change candidate order")

local cache_static_calls, cache_dynamic_calls = 0, 0
local cache_plans, cache_error, cache_stats = planner({
	centers = { { band = "outer", q = 100, r = 200 } },
	offsets = { { dq = 0, dr = 0 }, { dq = 0, dr = 0 }, { dq = 3, dr = 0 } },
	specs = { { resource_target = 2 } }, outer_count = 1,
	cluster_radius = 12, minimum_member_distance = 3,
	rand_int = function() return 0 end,
	classify_center = function(center) return center.band end,
	build_candidate = function(center, _, offset)
		return { q = center.q + offset.dq, r = center.r + offset.dr }
	end,
	validate_static = function()
		cache_static_calls = cache_static_calls + 1
		return true
	end,
	validate_dynamic = function()
		cache_dynamic_calls = cache_dynamic_calls + 1
		return true
	end,
})
assert(cache_plans, cache_error)
assert(cache_stats.candidate_attempts == 3 and cache_stats.rejected_candidates == 1
	and cache_stats.accepted_candidates == 2,
	"duplicate draw did not preserve attempted/rejected/accepted counts")
assert(cache_static_calls == 2 and cache_stats.static_validations == 2
	and cache_stats.static_cache_reuses == 1,
	"exact-coordinate static verdict was not cached")
assert(cache_dynamic_calls == 2 and cache_stats.dynamic_validations == 2,
	"duplicate draw repeated mutable validation before uniqueness rejection")

local source_plans, source_error, source_stats = planner({
	centers = {
		{ band = "outer", preferred = true, valid = false, q = 0, r = 0 },
		{ band = "outer", preferred = false, valid = true, q = 100, r = 200 },
	},
	offsets = { { dq = 0, dr = 0 }, { dq = 3, dr = 0 }, { dq = 6, dr = 0 } },
	specs = { { resource_target = 2 } }, outer_count = 1,
	cluster_radius = 12, minimum_member_distance = 3,
	anchor_first = true, require_valid_anchor = true,
	rand_int = function() return 0 end,
	classify_center = function(center) return center.band end,
	center_priority = function(center) return center.preferred and "preferred" or "general" end,
	build_candidate = function(center, _, offset)
		return { q = center.q + offset.dq, r = center.r + offset.dr, valid = center.valid }
	end,
	validate_static = function(candidate) return candidate.valid end,
	validate_dynamic = function() return true end,
})
assert(source_plans, source_error)
assert(source_stats.centers_attempted == 2 and source_stats.candidate_attempts == 3
	and source_stats.accepted_candidates == 2 and source_stats.rejected_candidates == 1,
	"invalid preferred anchor did not advance directly to the general on-demand source")

local repeat_anchor_draws = 0
local repeated_source_plans, repeated_source_error, repeated_source_stats = planner({
	centers = { { band = "outer", preferred = false, q = 0, r = 0 } },
	offsets = { { dq = 0, dr = 0 }, { dq = 3, dr = 0 } },
	specs = { { resource_target = 2 } }, outer_count = 1,
	cluster_radius = 12, minimum_member_distance = 3,
	source_visit_limit = function() return 2 end,
	prepare_center = function() return repeat_anchor_draws < 2 end,
	anchor_first = true, require_valid_anchor = true,
	rand_int = function() return 0 end,
	classify_center = function(center) return center.band end,
	center_priority = function() return "general" end,
	build_candidate = function(_, _, offset)
		if offset.dq == 0 then repeat_anchor_draws = repeat_anchor_draws + 1 end
		return {
			q = repeat_anchor_draws * 100 + offset.dq, r = 0,
			valid = repeat_anchor_draws >= 2,
		}
	end,
	validate_static = function(candidate) return candidate.valid end,
	validate_dynamic = function() return true end,
})
local repeated_source_safe = repeated_source_plans ~= nil
	and repeated_source_error == nil and repeat_anchor_draws == 2
	and repeated_source_stats.centers_attempted == 2
	and repeated_source_stats.candidate_attempts == 3
	and repeated_source_stats.accepted_candidates == 2

local partial_plans, partial_error, partial_stats = planner({
	centers = {
		{ band = "outer", q = 0, r = 0, valid = true },
		{ band = "outer", q = 100, r = 0, valid = false },
		{ band = "inner", q = -100, r = 0, valid = true },
	},
	offsets = { { dq = 0, dr = 0 } },
	specs = {
		{ resource_target = 1 }, { resource_target = 1 }, { resource_target = 1 },
	},
	outer_count = 2, minimum_plans = 2,
	cluster_radius = 12, minimum_member_distance = 3,
	anchor_first = true, require_valid_anchor = true,
	rand_int = function() return 0 end,
	classify_center = function(center) return center.band end,
	build_candidate = function(center, _, offset, band)
		return {
			q = center.q + offset.dq, r = center.r + offset.dr,
			band = band, valid = center.valid,
		}
	end,
	validate_static = function(candidate) return candidate.valid end,
	validate_dynamic = function() return true end,
})
local partial_minimum_safe = partial_plans ~= nil and partial_error == nil
	and #partial_plans == 2 and partial_plans[1].id == 1
	and partial_plans[2].id == 3 and partial_stats.plan_exhaustions == 1

-- A coordinate may be reached from either side of the physical outer/inner boundary.
-- Static terrain/buildability can be cached by coordinate, but band eligibility cannot.
local false_positive_plans, false_positive_error = planner({
	centers = {
		{ q = 0, r = 0, band = "outer" }, { q = 100, r = 0, band = "outer" },
		{ q = -3, r = 0, band = "inner" }, { q = -100, r = 0, band = "inner" },
	},
	offsets = { { dq = 0, dr = 0 }, { dq = 3, dr = 0 } },
	specs = { { resource_target = 2 }, { resource_target = 2 } }, outer_count = 1,
	cluster_radius = 12, minimum_member_distance = 3,
	anchor_first = true, require_valid_anchor = true,
	rand_int = function() return 0 end,
	classify_center = function(center) return center.band end,
	build_candidate = function(center, _, offset, band)
		return { q = center.q + offset.dq, r = 0, band = band }
	end,
	validate_static = function(candidate)
		local actual_band = candidate.q < 0 and "inner" or "outer"
		return candidate.band == actual_band and candidate.q ~= 3
	end,
	validate_dynamic = function() return true end,
})
assert(false_positive_plans, false_positive_error)
local false_positive_safe = true
for _, candidate in ipairs(false_positive_plans[2].candidates) do
	if not (candidate.band == "inner" and candidate.q < 0) then
		false_positive_safe = false
	end
end

local false_negative_plans, false_negative_error = planner({
	centers = {
		{ q = 3, r = 0, band = "outer" }, { q = 100, r = 0, band = "outer" },
		{ q = 0, r = 0, band = "inner" }, { q = -100, r = 0, band = "inner" },
	},
	offsets = { { dq = 0, dr = 0 }, { dq = -3, dr = 0 } },
	specs = { { resource_target = 2 }, { resource_target = 2 } }, outer_count = 1,
	cluster_radius = 12, minimum_member_distance = 3,
	anchor_first = true, require_valid_anchor = true,
	rand_int = function() return 0 end,
	classify_center = function(center) return center.band end,
	build_candidate = function(center, _, offset, band)
		return { q = center.q + offset.dq, r = 0, band = band }
	end,
	validate_static = function(candidate)
		local actual_band = candidate.q <= 0 and "inner" or "outer"
		return candidate.band == actual_band
	end,
	validate_dynamic = function() return true end,
})
assert(false_negative_plans, false_negative_error)
local false_negative_safe = false_negative_plans[2].candidates[1].q == 0
	and false_negative_plans[2].candidates[2].q == -3

local selector_behavior_safe = false
local selector_builder = environment.DepositRules.BuildDirectSeededClusterSelector
if type(selector_builder) == "function" then
	local occupied, obstructed = {}, {}
	local selector_stats = {
		placement_dynamic_validations = 0,
		placement_dynamic_rejections = 0,
	}
	local selector = selector_builder({
		candidates = {
			{ q = 0, r = 0, terrain_type = 1 },
			{ q = 3, r = 0, terrain_type = 1 },
			{ q = 0, r = 0, terrain_type = 1 },
			{ q = 2, r = 0, terrain_type = 1 },
			{ q = 6, r = 0, terrain_type = 1 },
			{ q = 9, r = 0, terrain_type = 1 },
		},
		stats = selector_stats,
		validate_dynamic = function(candidate)
			local key = tostring(candidate.q) .. ":" .. tostring(candidate.r)
			if obstructed[key] or occupied[key] then return false end
			for _, prior in pairs(occupied) do
				local dq, dr = candidate.q - prior.q, candidate.r - prior.r
				if math.max(math.abs(dq), math.abs(dr), math.abs(dq + dr)) < 3 then
					return false
				end
			end
			return true
		end,
		on_commit = function(candidate)
			occupied[tostring(candidate.q) .. ":" .. tostring(candidate.r)] = candidate
		end,
	})
	local first_member = selector.Take(1, { ordinary_profile = true })
	selector.Commit(first_member)
	local legal_member = selector.Take(1, { ordinary_profile = true })
	selector.Commit(legal_member)
	obstructed["6:0"] = true
	local after_mutations = selector.Take(1, { ordinary_profile = true })
	selector.Commit(after_mutations)
	selector_behavior_safe = first_member and first_member.q == 0
		and legal_member and legal_member.q == 3
		and after_mutations and after_mutations.q == 9
		and selector.Remaining() == 0
		and selector_stats.placement_dynamic_validations == 6
		and selector_stats.placement_dynamic_rejections == 3
end

local fail_rng = new_rng(7)
local failed, failure, failure_stats = planner({
	centers = { { band = "outer", q = 0, r = 0 } },
	offsets = { { dq = 0, dr = 0 } },
	specs = { { resource_target = 2 } }, outer_count = 1,
	cluster_radius = 12, minimum_member_distance = 3,
	rand_int = fail_rng,
	classify_center = function(center) return center.band end,
	build_candidate = function() return { q = 0, r = 0 } end,
	validate_static = function() return true end,
	validate_dynamic = function() return true end,
})
assert(failed == nil and tostring(failure):find("search exhausted", 1, true))
assert(failure_stats.centers_attempted == 1 and failure_stats.candidate_attempts == 1)

local violations = {}
-- Execute the production offset builder: valid members need not share q/r modulo three.
local complete_offsets = environment.DepositRules.BuildDirectSeededClusterOffsets(12)
assert(#complete_offsets == 469)
local residues = {}
for _, offset in ipairs(complete_offsets) do
	residues[(offset.dq % 3) .. ":" .. (offset.dr % 3)] = true
end
local residue_count = 0
for _ in pairs(residues) do residue_count = residue_count + 1 end
assert(residue_count == 9, "local sampler excludes legal axial residue classes")
local repaired, repaired_error = planner({
	centers = {{ q = 100, r = 100, band = "outer" }},
	offsets = complete_offsets,
	specs = {{resource_target = 2}}, outer_count = 1,
	cluster_radius = 12, minimum_member_distance = 3,
	near_seed_first = true,
	anchor_first = true, require_valid_anchor = false,
	rand_int = function() return 0 end,
	classify_center = function(c) return c.band end,
	center_priority = function() return "preferred" end,
	build_candidate = function(c, _, offset) return {q = c.q + offset.dq, r = c.r + offset.dr} end,
	validate_static = function(c) return c.r == 100 and (c.q == 102 or c.q == 105) end,
	validate_dynamic = function() return true end,
})
assert(repaired, repaired_error)
assert(repaired[1].candidates[1].q == 102 and repaired[1].candidates[2].q == 105,
	"an unbuildable seed suppressed its legal neighbours")

local new_guide = environment.DepositRules.NewDirectSeededBuildableGuide
local band_regions = environment.DepositRules.DirectSeededBandRegions
for _, band in ipairs({"outer", "inner"}) do
	for _, bounds in ipairs({{x0 = 0, y0 = 0, x1 = 200, y1 = 160},
		{x0 = 5, y0 = 7, x1 = 197, y1 = 155}}) do
		local regions = band_regions(bounds, 200, 160, 2, band, 3)
		for x = 0, 199 do for y = 0, 159 do
			local outer = x < 10 or x >= 190 or y < 8 or y >= 152
			local inner = (x < 20 or x >= 180 or y < 16 or y >= 144) and not outer
			local expected = (band == "outer" and outer or band == "inner" and inner)
				and x >= 3 and x < 197 and y >= 3 and y < 157
				and x >= bounds.x0 and x < bounds.x1 and y >= bounds.y0 and y < bounds.y1
			local matches = 0
			for _, rect in ipairs(regions) do
				if x >= rect.x0 and x < rect.x1 and y >= rect.y0 and y < rect.y1 then matches = matches + 1 end
			end
			assert(matches == (expected and 1 or 0), "physical band clipping dropped/duplicated a point")
		end end
	end
end

local fair_sources = {}
for i = 1, 20 do fair_sources[#fair_sources + 1] = {q = i * 100, r = 0, band = "outer", priority = "preferred"} end
fair_sources[#fair_sources + 1] = {q = 3000, r = 0, band = "outer", priority = "general"}
local fair, fair_error, fair_stats = planner({
	centers = fair_sources, offsets = {{dq = 0, dr = 0}}, specs = {{resource_target = 1}},
	outer_count = 1,
	rand_int = function() return 0 end,
	classify_center = function(c) return c.band end,
	center_priority = function(c) return c.priority end,
	build_candidate = function(c) return {q = c.q, r = c.r} end,
	validate_static = function(c) return c.q == 3000 end,
	validate_dynamic = function() return true end,
})
assert(fair and fair_stats.candidate_attempts == 2, fair_error)

local function check_guide(points)
	local draws = new_rng(17)
	local guide = new_guide({leaf_size = 4, rand_int = draws, has_buildable = function(rect)
		for _, p in ipairs(points) do
			if p[1] >= rect.x0 and p[1] < rect.x1 and p[2] >= rect.y0 and p[2] < rect.y1 then
				return true
			end
		end
		return false
	end})
	local region = {x0 = 0, y0 = 0, x1 = 64, y1 = 64}
	local x, y = guide.Sample(region)
	assert(x and y)
	assert(guide.stats.queries <= 17, "guide eagerly traversed unused leaves")
	local touched = false
	for _, p in ipairs(points) do
		if math.abs(x - p[1]) < 4 and math.abs(y - p[2]) < 4 then touched = true end
	end
	assert(touched, "guide missed the small buildable region")
	local visited = {[math.floor(x / 4) .. ":" .. math.floor(y / 4)] = true}
	local count = 1
	while true do
		x, y = guide.Sample(region)
		if not x then break end
		local key = math.floor(x / 4) .. ":" .. math.floor(y / 4)
		assert(not visited[key], "guide revisited a leaf")
		visited[key], count = true, count + 1
		assert(count <= 256, "finite guide did not exhaust")
	end
	assert(guide.stats.cache_reuses > 0)
	if #points == 1 then assert(count == 1) end
	for _, p in ipairs(points) do
		assert(visited[math.floor(p[1] / 4) .. ":" .. math.floor(p[2] / 4)],
			"later disconnected buildable leaf was never visited")
	end
	local prior_queries = guide.stats.queries
	assert(guide.Sample(region) == nil and guide.stats.queries == prior_queries,
		"exhausted guide repeated native work")
end
check_guide({{31, 31}})
check_guide({{32, 32}}) -- split boundary
local diagonal = {}
for i = 0, 63 do diagonal[#diagonal + 1] = {i, i} end
check_guide(diagonal)
check_guide({{1, 1}, {61, 61}, {1, 61}, {61, 1}})
for _, result in ipairs({"error", "empty", "full", "inconsistent", "unknown_parent"}) do
	local guide = new_guide({leaf_size = 4, rand_int = function() return 0 end,
		has_buildable = function(rect)
			if result == "error" then error("native query unavailable") end
			if result == "inconsistent" then return rect.x1 - rect.x0 == 64 end
			if result == "unknown_parent" then
				if rect.x1 - rect.x0 == 64 then return nil end
				return false
			end
			return result == "full"
		end})
	local region = {x0 = 10, y0 = 10, x1 = 74, y1 = 74}
	local x = guide.Sample(region)
	assert((x ~= nil) == (result ~= "empty"), "unknown/boundary guide result incorrectly pruned")
	assert(guide.stats.queries <= 17, "guide exceeded a single lazy path")
	local visits = x and 1 or 0
	while guide.Sample(region) do visits = visits + 1; assert(visits <= 256) end
	assert(visits == (result == "empty" and 0 or 256), "finite conservative coverage incomplete")
end

-- Legal members on the outer local rings must not be truncated at32/128/384 draws.
local distant, distant_error, distant_stats = planner({
	centers = {{q = 100, r = 100, band = "outer"}}, offsets = complete_offsets,
	specs = {{resource_target = 2}}, outer_count = 1,
	cluster_radius = 12, minimum_member_distance = 3, near_seed_first = true,
	rand_int = function() return 0 end,
	classify_center = function(c) return c.band end,
	build_candidate = function(c, _, offset) return {q = c.q + offset.dq, r = c.r + offset.dr} end,
	validate_static = function(c) return c.r == 100 and (c.q == 109 or c.q == 112) end,
	validate_dynamic = function() return true end,
})
assert(distant, distant_error)
assert(distant_stats.candidate_attempts > 384 and distant_stats.accepted_candidates == 2,
	"complete finite offsets were truncated before distant legal members")

-- A finite source yields distinct leaf anchors. Impossible terrain exhausts once;
-- a complete first trial must not request any later leaf or native validation.
for _, possible in ipairs({false, true}) do
	local prepared, tested = 0, 0
	local result, err, stats = planner({
		centers = {{band = "outer"}}, offsets = complete_offsets,
		specs = {{resource_target = 1}}, outer_count = 1, near_seed_first = true,
		cluster_radius = 12, minimum_member_distance = 3,
		rand_int = function() return 0 end,
		classify_center = function(c) return c.band end,
		source_visit_limit = function() return 3 end,
		prepare_center = function(c)
			prepared = prepared + 1
			if prepared > 3 then return false end
			c.q = prepared * 100
			return true
		end,
		build_candidate = function(c, _, offset) return {q = c.q + offset.dq, r = offset.dr} end,
		validate_static = function() tested = tested + 1; return possible end,
		validate_dynamic = function() return true end,
	})
	if possible then
		assert(result and prepared == 1 and tested == 1, err)
	else
		assert(not result and err:find("finite sources exhausted", 1, true))
		assert(prepared == 4 and tested == 3 * 469 and stats.sources_exhausted == 1)
	end
end
local function require_policy(condition, message)
	if not condition then violations[#violations + 1] = message end
end
require_policy(false_positive_safe,
	"cross-band positive static cache reuse accepted a member in the wrong physical band")
require_policy(false_negative_safe,
	"cross-band negative static cache reuse poisoned a later valid-band candidate")
require_policy(selector_behavior_safe,
	"production cluster selector lacks executable clone-boundary mutation behavior coverage")
require_policy(repeated_source_safe,
	"general sector descriptors cannot provide bounded repeated on-demand anchor draws")
require_policy(partial_minimum_safe,
	"band-end exhaustion discards complete plans instead of continuing to the required minimum")
require_policy(not topup:find("local perimeter_quota_candidates = {}", 1, true),
	"eager perimeter candidate pool remains")
require_policy(not topup:find("local MAX_FINAL_QUOTA_CANDIDATES = 4096", 1, true),
	"area-sized quota candidate ceiling remains")
require_policy(not topup:find("local function build_quota_cluster_plans", 1, true),
	"whole-pool cluster planner remains")
require_policy(topup:find("rand_int = RandInt", 1, true),
	"planner is not driven by the existing private placement stream")
require_policy(topup:find("source_visit_limit = function(center, band)", 1, true)
	and topup:find("DepositRules.DirectSeededLeafLimit(rect, guide_leaf_size)", 1, true)
	and not topup:find("candidate_attempt_budget = 384", 1, true),
	"finite geometry-derived source exhaustion was replaced by arbitrary attempt caps")
require_policy(topup:find("validate_static = function(candidate)", 1, true)
	and topup:find("CanReceiveDepositTerrain(", 1, true)
	and topup:find("TerrainTypeAt(map, pt, direct_context)", 1, true)
	and topup:find("surface_extractor_footprint_within_map(candidate)", 1, true),
	"lazy exact-coordinate terrain/buildable validation is missing")
require_policy(topup:find("validate_dynamic = function(candidate)", 1, true)
	and topup:find("IsUnobstructedAt(map, pt, true, direct_context", 1, true)
	and topup:find("direct_cluster_repulsion.CanPlaceUnique(candidate)", 1, true)
	and topup:find("direct_cluster_repulsion.CanPlaceMinimum(candidate", 1, true),
	"mutable occupancy/spacing validation is missing")
require_policy(topup:find("placement_dynamic_validations", 1, true)
	and topup:find("placement_dynamic_rejections", 1, true),
	"clone-boundary mutable validation counters are missing")
require_policy(topup:find("direct_cluster_dynamic_validator(candidate, nil)", 1, true)
	and not topup:find("direct_cluster_dynamic_validator(candidate, profile)", 1, true),
	"clone-boundary cluster validation reapplies ordinary profile repulsion to deliberate cluster members")
require_policy(planner_source:find("static_cache_reuses", 1, true)
	and planner_source:find("accepted_candidates", 1, true)
	and planner_source:find("rejected_candidates", 1, true),
	"planner does not expose required cache/accepted/rejected instrumentation")
require_policy(not planner_source:find("local function shuffled_copy", 1, true),
	"planner still materializes fully shuffled candidate lists")
require_policy(topup:find('kind = "sector"', 1, true)
	and topup:find("center_priority = function(center)", 1, true)
	and topup:find("anchor_first = true", 1, true)
	and topup:find("require_valid_anchor = false", 1, true)
	and topup:find("guide.Sample(regions[", 1, true)
	and topup:find("direct_context.build_unbuildable_z, 10000", 1, true),
	"apron-first on-demand physical-band sampling is missing")
require_policy(topup:find("prepare_center = function(center, band)", 1, true),
	"repeated sources do not advance their finite guide leaf iterator")
require_policy(topup:find("terrain_candidate_entries =", 1, true)
	and topup:find("sampling_source_entries =", 1, true),
	"published terrain-list and on-demand source counts are not separated")
require_policy(topup:find("minimum_plans = resource_cluster_minimum_count", 1, true),
	"production direct planner does not preserve the authoritative minimum cluster count")
require_policy(topup:find('OptimizationFailure("direct seeded surface clusters"', 1, true),
	"exhaustion is not fail-loud")
require_policy(config_source:find("config.OptimizeDirectSeededSurfaceClusters = true", 1, true)
	and config_source:find("C.OPTIMIZE_DIRECT_SEEDED_SURFACE_CLUSTERS", 1, true),
	"direct planner config is not enabled and compiled")
require_policy((tonumber(metadata_source:match("'version',%s*(%d+)")) or 0) >= 944,
	"manual direct-seeded repair requires a new behavior version")

local findings = {
	"DIRECT_SEEDED_TOPUP_BEHAVIOR",
	"source=Code/sbm_deposits.lua",
	"production_function_executed=true",
	"same_seed_reproduces=true",
	"different_seed_changes_order=true",
	"exact_candidates_retained=" .. tostring(first_stats.valid_candidates),
	"center_attempts=" .. tostring(first_stats.centers_attempted),
	"candidate_attempts=" .. tostring(first_stats.candidate_attempts),
	"rejected_candidates=" .. tostring(first_stats.rejected_candidates),
	"static_validations=" .. tostring(first_stats.static_validations),
	"static_cache_reuses=" .. tostring(first_stats.static_cache_reuses),
	"dynamic_validations=" .. tostring(first_stats.dynamic_validations),
	"accepted_candidates=" .. tostring(first_stats.accepted_candidates),
	"rng_calls=" .. tostring(first_rng_calls),
	"bounded_exhaustion=true",
	"cross_band_cache_guard=" .. tostring(false_positive_safe and false_negative_safe),
	"clone_boundary_selector_behavior=" .. tostring(selector_behavior_safe),
	"repeated_sector_anchor_sampling=" .. tostring(repeated_source_safe),
	"minimum_cluster_continuation=" .. tostring(partial_minimum_safe),
	"violation_count=" .. tostring(#violations),
}
for index, message in ipairs(violations) do
	findings[#findings + 1] = "violation_" .. tostring(index) .. "=" .. message
end
findings[#findings + 1] = #violations == 0 and "verdict=GREEN" or "verdict=RED"
local rendered = table.concat(findings, "\n") .. "\n"

if arg and arg[1] then
	local report = assert(io.open(arg[1], "wb"))
	report:write(rendered)
	report:close()
end
io.write(rendered)
if #violations > 0 then error("direct seeded top-up production policy is red", 0) end
print("PASS direct seeded top-up: bounded production behavior")

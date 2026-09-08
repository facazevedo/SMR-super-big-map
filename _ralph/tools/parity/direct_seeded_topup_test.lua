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
	local validation_calls = 0
	local plans, planner_error, stats = planner({
		centers = centers, offsets = offsets, specs = specs, outer_count = 2,
		cluster_radius = 12, minimum_member_distance = 3,
		center_attempt_budget = 3, candidate_attempt_budget = 18,
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
	})
	assert(plans, planner_error)
	assert(#plans == #specs and stats.plans == #specs)
	assert(stats.outer_plans == 2 and stats.inner_plans == 2)
	assert(stats.centers_attempted == #specs)
	assert(stats.candidate_attempts == validation_calls)
	assert(validation_calls == 14, "planner retained more than exact cluster demand")
	assert(stats.candidate_attempts <= #specs * stats.candidate_attempt_budget)
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

local fail_rng = new_rng(7)
local failed, failure, failure_stats = planner({
	centers = { { band = "outer", q = 0, r = 0 } },
	offsets = { { dq = 0, dr = 0 } },
	specs = { { resource_target = 2 } }, outer_count = 1,
	cluster_radius = 12, minimum_member_distance = 3,
	center_attempt_budget = 1, candidate_attempt_budget = 1,
	rand_int = fail_rng,
	classify_center = function(center) return center.band end,
	build_candidate = function() return { q = 0, r = 0 } end,
})
assert(failed == nil and tostring(failure):find("search exhausted", 1, true))
assert(failure_stats.centers_attempted == 1 and failure_stats.candidate_attempts == 1)

local violations = {}
local function require_policy(condition, message)
	if not condition then violations[#violations + 1] = message end
end
require_policy(not topup:find("local perimeter_quota_candidates = {}", 1, true),
	"eager perimeter candidate pool remains")
require_policy(not topup:find("local MAX_FINAL_QUOTA_CANDIDATES = 4096", 1, true),
	"area-sized quota candidate ceiling remains")
require_policy(not topup:find("local function build_quota_cluster_plans", 1, true),
	"whole-pool cluster planner remains")
require_policy(topup:find("rand_int = RandInt", 1, true),
	"planner is not driven by the existing private placement stream")
require_policy(topup:find("center_attempt_budget = 64", 1, true)
	and topup:find("candidate_attempt_budget = 384", 1, true),
	"production attempt budgets are missing")
require_policy(topup:find("CanReceiveDeposit(", 1, true)
	and topup:find("TerrainTypeAt(map, pt, direct_context)", 1, true)
	and topup:find("surface_extractor_footprint_within_map(candidate)", 1, true)
	and topup:find("direct_cluster_repulsion.CanPlaceUnique(candidate)", 1, true)
	and topup:find("direct_cluster_repulsion.CanPlaceMinimum(candidate", 1, true),
	"complete production terrain/buildable/spacing validation is missing")
require_policy(topup:find('OptimizationFailure("direct seeded surface clusters"', 1, true),
	"exhaustion is not fail-loud")
require_policy(config_source:find("config.OptimizeDirectSeededSurfaceClusters = true", 1, true)
	and config_source:find("C.OPTIMIZE_DIRECT_SEEDED_SURFACE_CLUSTERS", 1, true),
	"direct planner config is not enabled and compiled")
require_policy(metadata_source:find("'version', 937", 1, true),
	"behavior-change version is not 937")

local findings = {
	"DIRECT_SEEDED_TOPUP_BEHAVIOR",
	"source=Code/sbm_deposits.lua",
	"production_function_executed=true",
	"same_seed_reproduces=true",
	"different_seed_changes_order=true",
	"exact_candidates_retained=" .. tostring(first_stats.valid_candidates),
	"center_attempts=" .. tostring(first_stats.centers_attempted),
	"candidate_attempts=" .. tostring(first_stats.candidate_attempts),
	"rng_calls=" .. tostring(first_rng_calls),
	"bounded_exhaustion=true",
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

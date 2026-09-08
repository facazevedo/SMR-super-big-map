-- Focused regression for demand-driven surface effect top-up candidates.
-- Run from the project root:
--   lua _ralph/tools/parity/surface_effect_demand_driven_test.lua

local function read(path)
	local file = assert(io.open(path, "rb"))
	local value = file:read("*a")
	file:close()
	return value
end

local source = read("Code/sbm_deposits.lua")
local effects = assert(source:match(
	"(function DepositRules%.TopUpEffectDeposits.-)\n%-%- Final cross%-pass invariant"),
	"production DepositRules.TopUpEffectDeposits function not found")

local violations = {}
local checks = 0
local function require_policy(name, condition)
	checks = checks + 1
	if not condition then violations[#violations + 1] = name end
end

require_policy("surface effects use the demand-driven path",
	not effects:find("local sequential_underground = underground", 1, true)
		and effects:find("local sequential_placement =", 1, true) ~= nil)
require_policy("surface effects do not prebuild the 512-entry reserve",
	not effects:find("math.max(512, total_shortfall * 32)", 1, true))
require_policy("effect status reports demand counters",
	effects:find("candidate_attempts = candidate_samples_total", 1, true) ~= nil
		and effects:find("candidate_rejections =", 1, true) ~= nil
		and effects:find("candidate_accepted =", 1, true) ~= nil)
require_policy("bounded surface exhaustion records an optimization failure",
	effects:find('OptimizationFailure("surface_effect_demand"', 1, true) ~= nil)

local begin_marker = "-- DEMAND_DRIVEN_EFFECT_CANDIDATE_BEGIN"
local end_marker = "-- DEMAND_DRIVEN_EFFECT_CANDIDATE_END"
local helper_start = source:find(begin_marker, 1, true)
local helper_end = helper_start and source:find(end_marker, helper_start, true)
require_policy("production demand helper exists", helper_start ~= nil and helper_end ~= nil)

if helper_start and helper_end then
	local helper_source = source:sub(helper_start + #begin_marker, helper_end - 1)
	local environment = setmetatable({ DepositRules = {} }, { __index = _G })
	local chunk, load_error
	if _VERSION == "Lua 5.1" then
		chunk, load_error = loadstring(helper_source, "demand_driven_effect_candidate")
		assert(chunk, load_error)
		setfenv(chunk, environment)
	else
		chunk, load_error = load(
			helper_source, "demand_driven_effect_candidate", "t", environment)
		assert(chunk, load_error)
	end
	chunk()
	local take_next = assert(environment.DepositRules.TakeNextDemandDrivenEffectCandidate,
		"production demand helper function missing")

	local samples, rebuilds, takes = 0, 0, 0
	local available
	local candidate, owner, stats = take_next({
		maximum_samples = 5,
		sample_count = function() return samples end,
		sample = function()
			samples = samples + 1
			if samples == 1 then return false end
			available = { id = samples }
			return true
		end,
		rebuild = function() rebuilds = rebuilds + 1 end,
		take = function()
			takes = takes + 1
			if available then
				local value = available
				available = nil
				return value, "selector"
			end
		end,
	})
	require_policy("helper stops on the first accepted candidate",
		candidate and candidate.id == 2 and owner == "selector"
			and samples == 2 and rebuilds == 1 and takes == 1)
	require_policy("helper reports attempted/rejected/accepted counts",
		stats and stats.attempted == 2 and stats.rejected == 1 and stats.accepted == 1)

	local exhausted, _, exhausted_stats = take_next({
		maximum_samples = 3,
		sample_count = function() return 0 end,
		sample = function() return false end,
		rebuild = function() error("rebuild on rejected sample") end,
		take = function() error("take on rejected sample") end,
	})
	require_policy("helper has finite fail-closed exhaustion",
		exhausted == nil and exhausted_stats and exhausted_stats.attempted == 3
			and exhausted_stats.rejected == 3 and exhausted_stats.accepted == 0
			and exhausted_stats.exhausted == true)
end

for _, name in ipairs(violations) do print("FAIL " .. name) end
print(string.format("surface effect demand checks: %d passed, %d failed",
	checks - #violations, #violations))
if #violations > 0 then os.exit(1) end

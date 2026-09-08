-- Focused red/green source-policy regression for direct seeded surface resource top-ups.
-- Run from the project root:
--   lua _ralph/tools/parity/direct_seeded_topup_test.lua [report-path]
--
-- This deliberately reads the shipped TopUpDeposits function.  The arrival (v936) is red:
-- it constructs a broad perimeter candidate pool and then repeatedly scans that complete pool
-- while planning clusters.  A green implementation must replace both mechanisms with bounded,
-- demand-driven attempts; gameplay validity remains covered by the existing rule/terrain gates.

local function read(path)
	local file = assert(io.open(path, "rb"))
	local value = file:read("*a")
	file:close()
	return value
end

local deposits_source = read("Code/sbm_deposits.lua")
local topup = assert(deposits_source:match(
	"(function DepositRules%.TopUpDeposits.-)\nfunction DepositRules%.TopUpAnomalies"),
	"production DepositRules.TopUpDeposits function not found")

local eager_pool_decl = topup:find("local perimeter_quota_candidates = {}", 1, true)
local exhaustive_descriptor_scan = topup:find(
	"for _, descriptor in ipairs(edge_ctx.sectors) do", 1, true)
local area_cap = topup:find("local MAX_FINAL_QUOTA_CANDIDATES = 4096", 1, true)
local planner_start = topup:find("local function build_quota_cluster_plans", 1, true)
local planner_end = topup:find("local function new_planned_cluster_selector", 1, true)
assert(planner_start and planner_end and planner_end > planner_start,
	"production quota-cluster planner block not found")
local planner = topup:sub(planner_start, planner_end - 1)
local anchor_scan = planner:find("for _, anchor in ipairs(candidates) do", 1, true)
local candidate_scan = planner:find("for _, candidate in ipairs(candidates) do", 1, true)
local full_pool_sort = planner:find("table.sort(candidates", 1, true)

local findings = {
	"DIRECT_SEEDED_TOPUP_BASELINE",
	"source=Code/sbm_deposits.lua",
	"eager_perimeter_pool=" .. tostring(eager_pool_decl ~= nil),
	"exhaustive_descriptor_scan=" .. tostring(exhaustive_descriptor_scan ~= nil),
	"area_sized_candidate_cap_4096=" .. tostring(area_cap ~= nil),
	"planner_full_pool_sort=" .. tostring(full_pool_sort ~= nil),
	"planner_anchor_full_scan=" .. tostring(anchor_scan ~= nil),
	"planner_nested_candidate_full_scan=" .. tostring(
		anchor_scan ~= nil and candidate_scan ~= nil and candidate_scan > anchor_scan),
}

local violations = {}
local function reject(condition, message)
	if condition then violations[#violations + 1] = message end
end
reject(eager_pool_decl ~= nil and exhaustive_descriptor_scan ~= nil and area_cap ~= nil,
	"surface quota candidates are eagerly accumulated across perimeter descriptors up to 4096")
reject(full_pool_sort ~= nil,
	"cluster planning sorts the complete retained candidate pool before placement")
reject(anchor_scan ~= nil and candidate_scan ~= nil and candidate_scan > anchor_scan,
	"each cluster can rescan the complete pool for anchors and again for neighbours")

findings[#findings + 1] = "violation_count=" .. tostring(#violations)
for index, message in ipairs(violations) do
	findings[#findings + 1] = "violation_" .. tostring(index) .. "=" .. message
end
findings[#findings + 1] = #violations == 0
	and "verdict=GREEN" or "verdict=RED"
local rendered = table.concat(findings, "\n") .. "\n"

if arg and arg[1] then
	local report = assert(io.open(arg[1], "wb"))
	report:write(rendered)
	report:close()
end
io.write(rendered)

if #violations > 0 then
	error("direct seeded top-up policy is red: eager pool/repeated selection remain", 0)
end
print("PASS direct seeded top-up: bounded demand-driven acceptance")

-- Production-function red/green regression for the final surface top-up spacing audit.
-- Run from the project root:
--   lua _ralph/tools/parity/hard_spacing_spatial_index_test.lua

local module_path = "Code/sbm_deposits.lua"

local function read_file(path)
	local file = assert(io.open(path, "rb"))
	local source = file:read("*a")
	file:close()
	return source
end

local function read_commit(commit, path)
	local pipe = assert(io.popen("git show " .. commit .. ":" .. path, "r"))
	local source = pipe:read("*a")
	assert(pipe:close(), "could not read " .. commit .. ":" .. path)
	return source
end

local function extract_audit(source)
	local failure = source:match(
		"(local function OptimizationFailure.-)local function CountMapString") or ""
	local helper = source:match(
		"(local function BuildSurfaceHardSpacingCandidateRows.-)\n%-%- Vanilla applies") or ""
	local audit = assert(source:match(
		"(function DepositRules%.AuditTopUpVanillaRepulsion.-)\n%-%- Count the final physical"),
		"production spacing audit not found")
	return failure .. "\n" .. helper .. "\n" .. audit
end

local profiles = {
	{ layer = "surf", resource = "Metals", repulse_same = 6400,
		repulse_layer = 6400, repulse_all = 12800 },
	{ layer = "surf", resource = "Concrete", repulse_same = 20000,
		repulse_layer = 6400, repulse_all = 12800 },
	{ layer = "subs", resource = "Water", repulse_same = 25600,
		repulse_layer = 6400, repulse_all = 12800 },
	{ layer = "subs", resource = "PreciousMetals", repulse_same = 20000,
		repulse_layer = 4800, repulse_all = 12800 },
	{ layer = "subs", resource = "Anomaly", repulse_same = 3200,
		repulse_layer = 6400, repulse_all = 7200 },
	{ layer = "surf", resource = "Effects", repulse_same = 12000,
		repulse_layer = 6400, repulse_all = 7200 },
}

local function world_from_hex(q, r)
	return q * 1000 + r * 500, r * 866
end

local function new_marker(index, topup, q, r, profile_index)
	local profile = profiles[profile_index]
	local x, y = world_from_hex(q, r)
	local class = profile.resource == "Anomaly" and "SubsurfaceAnomalyMarker"
		or profile.resource == "Effects" and "EffectDepositMarker"
		or profile.layer == "surf" and "SurfaceDepositMarker"
		or "SubsurfaceDepositMarker"
	local pos = { x = x, y = y, q = q, r = r }
	function pos:xy() return self.x, self.y end
	return {
		class = class,
		profile = profile,
		anomaly = profile.resource == "Anomaly",
		pos = pos,
		is_placed = index % 11 ~= 0,
		SuperBigMapResourceTopUp = topup or nil,
	}
end

local function build_fixture()
	local markers = {}
	local state = 961
	local function random(limit)
		state = (state * 1103515245 + 12345) % 2147483648
		return state % limit
	end
	for index = 1, 615 do
		-- Ten early top-ups plus the final 255 entries give the observed 265/615 split.
		local topup = (index >= 2 and index <= 11) or index >= 361
		local q, r = random(861) - 20, random(987) - 20
		markers[index] = new_marker(index, topup, q, r, random(#profiles) + 1)
	end

	-- Deterministic boundary cases exercise duplicate, enrichment, outer-anomaly,
	-- quota, repulsion, and lexicographic first-detail reporting.
	markers[1] = new_marker(1, false, 0, 0, 1)
	markers[2] = new_marker(2, true, 0, 0, 1)
	markers[3] = new_marker(3, true, 2, 0, 3)
	markers[4] = new_marker(4, true, 3, 0, 4)
	markers[5] = new_marker(5, true, 20, 20, 5)
	markers[5].SuperBigMapAnomalyTopUp = true
	markers[5].SuperBigMapOuterRingRedistributed = true
	markers[6] = new_marker(6, true, 29, 20, 5)
	markers[6].SuperBigMapAnomalyTopUp = true
	markers[7] = new_marker(7, true, 40, 40, 1)
	markers[7].SuperBigMapOuterRingResourceQuotaTopUp = true
	markers[8] = new_marker(8, true, 42, 40, 2)
	markers[8].SuperBigMapOuterRingResourceQuotaTopUp = true

	local map = {
		mapdata = { Environment = "Surface" },
		SuperBigMapEnrichmentTopUpStatus = {
			resources = { complete = true, remaining_shortfall = 0 },
			anomalies = { complete = true, remaining_shortfall = 0 },
			effects = { complete = true, remaining_shortfall = 0 },
		},
		markers = markers,
	}
	function map:MapForEach(_, _, callback)
		for _, marker in ipairs(self.markers) do callback(marker) end
	end
	return map
end

local function run(source, label, options)
	local pair_evaluations = 0
	local point_fn = function(x, y) return { x = x, y = y } end
	local env = {
		DepositRules = {},
		SuperBigMap = { State = {} },
		cfg = function()
			return {
				MOUNTAIN_BASE_QUOTA_MINIMUM_HEX_DISTANCE = 3,
				OPTIMIZE_TOPUP_HARD_SPACING_SPATIAL_INDEX = true,
			}
		end,
		Global = function(name)
			if name == "point" then return point_fn end
			if name == "WorldToHex" then
				return function(point)
					-- This fixture uses the same reversible axial-to-world transform above.
					local r = math.floor(point.y / 866 + 0.5)
					local q = math.floor((point.x - r * 500) / 1000 + 0.5)
					return q, r
				end
			end
		end,
		IsUndergroundMap = function(map)
			return map and map.mapdata and map.mapdata.Environment == "Underground"
		end,
		TopUpEnrichmentMinimumHexDistance = function() return 3 end,
		IsEnrichmentMarker = function() return true end,
		ObjectPos = function(marker) return marker and marker.pos end,
		VanillaRepulsionProfileForMarker = function(_, marker) return marker.profile end,
		IsAnomalyMarker = function(marker) return marker and marker.anomaly == true end,
		IsKindOfSafe = function(marker, class) return marker and marker.class == class end,
		EnrichmentSectorKey = function() return nil end,
		SectorAtPoint = function() return nil end,
		UndergroundFallbackMinimumHexDistance = function() return 6 end,
		RoundedWorldDistance = function(distance_sq)
			return distance_sq and math.floor(math.sqrt(distance_sq) + 0.5) or 0
		end,
		PairRepulsionRadius = function(a, b)
			pair_evaluations = pair_evaluations + 1
			if not a or not b then return nil end
			if a.layer ~= b.layer then return a.repulse_all + b.repulse_all end
			if a.resource ~= b.resource then return a.repulse_layer + b.repulse_layer end
			return a.repulse_same + b.repulse_same
		end,
	}
	setmetatable(env, { __index = _G })
	local chunk = assert(load(extract_audit(source)
		.. "\nreturn DepositRules.AuditTopUpVanillaRepulsion", label, "t", env))
	local audit = chunk()
	local map = build_fixture()
	if options and options.invalid_profile then
		map.markers[1].profile = {
			layer = "surf", resource = "Metals", repulse_same = 0 / 0,
			repulse_layer = 6400, repulse_all = 12800,
		}
	end
	local call_ok, ok, report = pcall(audit, map, "shared fixture reason")
	if options and options.expect_error then
		return call_ok, ok, report, pair_evaluations,
			env.SuperBigMap.State.optimization_failures
	end
	assert(call_ok, ok)
	return ok, report, pair_evaluations
end

local function compare_baseline_fields(expected, actual, label)
	for key, value in pairs(expected) do
		assert(actual[key] == value, label .. ": report field " .. tostring(key)
			.. " changed (expected=" .. tostring(value) .. ", actual="
			.. tostring(actual[key]) .. ")")
	end
end

local baseline_source = read_commit("844fee0", module_path)
local historical_source = read_commit("eb614c6", module_path)
local current_source = read_file(module_path)

local baseline_ok, baseline, baseline_pair_evaluations = run(baseline_source, "v934-baseline")
assert(baseline.markers == 615 and baseline.topups == 265, "fixture population mismatch")
assert(baseline.checked_pairs == 127730, "fixture checked-pair budget mismatch")
assert(baseline.duplicate_hex_pairs > 0 and baseline.first_duplicate_hex_pair ~= "",
	"duplicate and first-detail path not exercised")
assert(baseline.enrichment_spacing_violations > 0
	and baseline.first_enrichment_spacing_violation ~= "",
	"enrichment and first-detail path not exercised")
assert(baseline.surface_quota_spacing_violations > 0
	and baseline.first_surface_quota_spacing_violation ~= "",
	"quota and first-detail path not exercised")
assert(baseline.outer_ring_spacing_violations > 0, "outer anomaly path not exercised")
assert(baseline.repulsion_violations > 0 and baseline.first_repulsion_violation ~= "",
	"repulsion and first-detail path not exercised")
assert(baseline_pair_evaluations > 0, "literal production pair predicate was not exercised")

local historical_ok, historical, historical_pair_evaluations =
	run(historical_source, "historical-index-reference")
assert(historical_ok == baseline_ok, "historical fast path changed the audit verdict")
compare_baseline_fields(baseline, historical, "historical fast path")
assert(historical.hard_spacing_spatial_index_used == true,
	"historical reference did not exercise its indexed fast path")
assert(historical.hard_spacing_spatial_index_candidate_pairs
	< historical.checked_pairs, "historical fixture did not prove pruning")
assert(historical_pair_evaluations < baseline_pair_evaluations,
	"historical fixture did not reduce production pair-predicate evaluations")
print(string.format(
	"PASS reference fast path preserves all v934 fields and reduces pair predicates %d -> %d",
	baseline_pair_evaluations, historical_pair_evaluations))

local current_ok, current, current_pair_evaluations = run(current_source, "current-production")
assert(current_ok == baseline_ok, "current audit verdict differs from v934")
compare_baseline_fields(baseline, current, "current production")
assert(current.hard_spacing_spatial_index_requested == true,
	"RED: current production does not request the surface spacing spatial index")
assert(current.hard_spacing_spatial_index_used == true,
	"RED: current production did not use the surface spacing spatial index")
assert(current.hard_spacing_spatial_index_candidate_pairs < current.checked_pairs,
	"RED: current production did not prune any checked-pair candidates")
assert(current.hard_spacing_spatial_index_pruned_pairs
	== current.checked_pairs - current.hard_spacing_spatial_index_candidate_pairs,
	"indexed pair-accounting certificate mismatch")
assert(current_pair_evaluations < baseline_pair_evaluations,
	"RED: current production did not reduce pair-predicate evaluations")
print(string.format(
	"PASS current production preserves all fields and reduces pair predicates %d -> %d",
	baseline_pair_evaluations, current_pair_evaluations))

local failure_call_ok, failure_error, _, failure_pair_evaluations, failures =
	run(current_source, "current-production-fail-loud", {
		invalid_profile = true, expect_error = true,
	})
assert(failure_call_ok == false, "invalid coverage certificate did not raise an error")
assert(tostring(failure_error):find("invalid repulse_same", 1, true),
	"certificate error omitted its concrete cause: " .. tostring(failure_error))
assert(failure_pair_evaluations == 0,
	"certificate failure silently entered the pair audit")
assert(type(failures) == "table" and #failures == 1,
	"certificate failure was not recorded exactly once")
assert(failures[1].unit == "surface hard spacing spatial index"
	and tostring(failures[1].reason):find("invalid repulse_same", 1, true),
	"recorded optimization failure omitted its unit or cause")
print("PASS invalid surface certificate records OptimizationFailure and raises without fallback")

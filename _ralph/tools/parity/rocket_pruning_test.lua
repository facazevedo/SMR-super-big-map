-- Execute the production scorer against immutable v960, with a live incumbent.
-- No engine/RNG dependency. Winners and all descriptive fields must stay exact.
local function read(path)
	local f = assert(io.open(path, "r")); local s = f:read("*a"); f:close(); return s
end
local old = assert(io.popen("git show 2e2676c:Code/sbm_terrain_copy.lua", "r"))
local reference = old:read("*a"); assert(old:close())
local production = read(arg[1] or "Code/sbm_terrain_copy.lua")
local function block(source)
	local first = assert(source:find("\tlocal relief_directions = {", 1, true))
	local last = assert(source:find("\tlocal cluster_groups_by_plan, cluster_groups = {}, {}", first, true))
	return source:sub(first, last - 1)
end
local function compile(source, env)
	return assert(load(block(source) .. "\nreturn candidate_score, finalize_rocket_relief, rocket_sampling",
		"rocket pruning scorer", "t", setmetatable(env, {__index = _G})))()
end
local tests = 0
local function check(ok, why) assert(ok, why); tests = tests + 1 end
local function equal(a, b, why)
	check((a == nil) == (b == nil), why .. " availability")
	if a then
		for k, v in pairs(a) do check(b[k] == v, why .. "." .. k) end
		for k, v in pairs(b) do check(a[k] == v, why .. " extra." .. k) end
	end
end
local function fixture(case)
	local calls = {height = 0, ready = 0, clearance = 0, pad = 0}
	local env = {height_tile = 100, cells_per_hex = 10, hex_size = 1000, guim_v = 100,
		map_w = 200000, map_h = 200000, rocket_outer_radius = 3, rocket_offsets = {},
		pads = {}, change = 0}
	for q = -3, 3 do for r = -3, 3 do
		if math.max(math.abs(q), math.abs(r), math.abs(q+r)) <= 3 then
			env.rocket_offsets[#env.rocket_offsets+1] = {q, r}
		end
	end end
	function env.world_xy(q, r)
		if case == 7 and q == 15 then return nil end
		return (q+r*0.5)*1000+18000, r*866+18000
	end
	function env.grid_value(x, y)
		calls.height = calls.height+1
		x = math.max(0, math.min(1999, math.floor(x+0.5)))
		y = math.max(0, math.min(1999, math.floor(y+0.5)))
		if case == 6 and (x+y)%17 == 0 then return nil end
		if case == 1 or case == 2 or case == 9 then return env.change end
		if case == 8 then return 65535 - (x*7+y*11)%4 + env.change end
		if case == 10 then return (x+y)%2 * 65535 + env.change end
		return (x*x*7+y*y*11+x*y*3)%4000 + env.change
	end
	function env.resource_clearance(q, r)
		calls.clearance = calls.clearance+1; return (q-r)%13 ~= 0
	end
	function env.separated_from_rocket_pads(q, r)
		calls.pad = calls.pad+1
		for _, pad in ipairs(env.pads) do
			if env.axial_distance(q, r, pad.q, pad.r) < 8 then return false end
		end
		return true
	end
	function env.in_outer_band(x, y) return x < 70000 or y < 70000 end
	function env.axial_distance(q, r, cq, cr)
		return math.max(math.abs(q-cq), math.abs(r-cr), math.abs(q+r-cq-cr))
	end
	function env.rocket_shape_ready(q, r)
		calls.ready = calls.ready+1
		if case == 2 or case == 4 then return false end
		if case == 9 then return true end
		return (q+r)%7 == 0
	end
	return env, calls
end
local totals = {eager_heights = 0, pruned_heights = 0, range = 0, score = 0}
for case = 1, 10 do
	local a, ac = fixture(case)
	local b, bc = fixture(case)
	local eager, finish_a = compile(reference, a)
	local scorer, finish_b, stats = compile(production, b)
	for group = 1, 4 do
		local best_a, best_b
		local cq, cr = group-2, group*2
		for dq = -18, 18 do for dr = -18, 18 do
			local distance = math.max(math.abs(dq), math.abs(dr), math.abs(dq+dr))
			if distance <= 18 then
				local q, r = cq+dq, cr+dr
				local ca = eager(q, r, cq, cr)
				local cb = scorer(q, r, cq, cr, best_b and best_b.score, distance)
				if cb then equal(ca, cb, "unpruned candidate") end
				if ca and (not best_a or ca.score < best_a.score) then best_a = ca end
				if cb and (not best_b or cb.score < best_b.score) then best_b = cb end
				equal(best_a, best_b, "every traversal prefix")
			end
		end end
		check(best_a ~= nil, "fixture winner required")
		check(finish_a(best_a) == true and finish_b(best_b) == true, "winner certificate")
		equal(best_a, best_b, "final relief metadata")
		a.pads[#a.pads+1] = best_a; b.pads[#b.pads+1] = best_b
	end
	check(stats.relief_reads == 36 and stats.selected_groups == 4, "winner relief count")
	check(bc.height <= ac.height, "pruning must not add height reads")
	-- No incumbent is the unchanged exhaustive path, including missing/zero heights.
	for q = -8, 15 do for r = -8, 15 do
		equal(eager(q, r, 0, 0), scorer(q, r, 0, 0), "no incumbent")
	end end
	totals.eager_heights = totals.eager_heights+ac.height
	totals.pruned_heights = totals.pruned_heights+bc.height
	totals.range = totals.range+(stats.pruned_range or 0)
	totals.score = totals.score+(stats.pruned_score or 0)
end
-- The boundary is >=, not >: strict replacement retains the first equal-score winner.
do
	local env, calls = fixture(9)
	env.resource_clearance = function() return true end
	local scorer, _, stats = compile(production, env)
	local first = scorer(0, 0, 0, 0)
	check(first and first.score == -1000000000, "zero height/readiness score")
	local before = calls.clearance+calls.height+calls.ready
	check(scorer(0, 0, 0, 0, first.score) == nil, "equal bound must prune")
	check(calls.clearance+calls.height+calls.ready == before, "distance bound must precede queries")
	check(stats.pruned_score > 0, "early prune accounted")
end
-- Prove progressive pruning really avoids the remaining footprint, on non-ready terrain.
do
	local env, calls = fixture(4)
	env.resource_clearance = function() return true end
	env.grid_value = function() calls.height = calls.height+1; return calls.height%2*1000 end
	local scorer, _, stats = compile(production, env)
	check(scorer(0, 0, 0, 0, 1) == nil, "partial range cannot beat incumbent")
	check(calls.height == 2, "range prune should stop after the first differing sample")
	check(stats.pruned_range == 1, "partial range prune accounted")
end
check(totals.range > 0 and totals.score > 0, "both bounds exercised")
check(totals.pruned_heights < totals.eager_heights, "measurable read reduction required")
check(not block(production):find("Random", 1, true), "no RNG in pruning")
check(production:find("candidate_score(cq + dq, cr + dr, cq, cr,", 1, true),
	"production traversal must pass its incumbent to the scorer")
print("rocket pruning: " .. tests .. " checks passed; height reads " .. totals.eager_heights
	.. " -> " .. totals.pruned_heights .. "; score/range prunes " .. totals.score .. "/" .. totals.range)

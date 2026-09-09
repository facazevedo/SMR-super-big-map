-- Exercise the actual production scorer against the immutable v957 eager scorer.
-- No engine or random stream: the synthetic maps deliberately include nil/zero heights,
-- negative axial coordinates, rounded world coordinates, ties and live pad exclusions.
local function read(path)
	local f = assert(io.open(path, "r")); local s = f:read("*a"); f:close(); return s
end
local old = assert(io.popen("git show 9982d4b:Code/sbm_terrain_copy.lua", "r"))
local reference = old:read("*a"); assert(old:close())
local production = read("Code/sbm_terrain_copy.lua")
local function block(source)
	local first = assert(source:find("\tlocal relief_directions = {", 1, true))
	local last = assert(source:find("\tlocal cluster_groups_by_plan, cluster_groups = {}, {}", first, true))
	return source:sub(first, last - 1)
end
local function compile(source, env)
	return assert(load(block(source) .. "\nreturn candidate_score, finalize_rocket_relief, rocket_sampling",
		"rocket scorer", "t", setmetatable(env, {__index = _G})))()
end
local tests = 0
local function check(ok, msg) assert(ok, msg); tests = tests + 1 end
local function fixture(case)
	local calls = {height = 0, world = 0, ready = 0}
	local env = {height_tile=100, cells_per_hex=10, hex_size=1000, guim_v=100,
		map_w=200000, map_h=200000, rocket_outer_radius=3, rocket_offsets={}, change=0,
		pad_q=false, pad_r=false}
	for q=-3,3 do for r=-3,3 do
		if math.max(math.abs(q), math.abs(r), math.abs(q+r))<=3 then
			env.rocket_offsets[#env.rocket_offsets+1]={q,r}
		end
	end end
	function env.world_xy(q,r)
		calls.world=calls.world+1
		if case==2 and q==15 and r==0 then return nil end
		return (q+r*0.5)*1000+30000, r*866+30000
	end
	function env.grid_value(x,y)
		calls.height=calls.height+1
		x=math.max(0,math.min(1999,math.floor(x+0.5)))
		y=math.max(0,math.min(1999,math.floor(y+0.5)))
		if case==3 and x%37==0 then return nil end
		if case==4 then return env.change end
		if case==5 then return 1000+math.floor(x/10)*50+env.change end
		return (x*x*7+y*y*11+x*y*3)%4000+env.change
	end
	function env.resource_clearance(q,r) return (q-r)%9~=0 end
	function env.separated_from_rocket_pads(q,r)
		return not env.pad_q or env.axial_distance(q,r,env.pad_q,env.pad_r)>=8
	end
	function env.in_outer_band(x,y) return x<70000 or y<70000 end
	function env.axial_distance(q,r,cq,cr)
		return math.max(math.abs(q-cq),math.abs(r-cr),math.abs(q+r-cq-cr))
	end
	function env.rocket_shape_ready(q,r)
		calls.ready=calls.ready+1; return (q+r)%7==0
	end
	return env,calls
end
for case=1,5 do
	local a, acalls=fixture(case)
	local b, bcalls=fixture(case)
	local eager=compile(reference,a)
	local scorer,finish,stats=compile(production,b)
	check(type(finish)=="function", "winner-only relief finalizer missing")
	local last_winner
	for group=1,4 do
		local best_a,best_b
		for q=-8,16 do for r=-8,16 do
			local ea,eb=eager(q,r,group,group*2),scorer(q,r,group,group*2)
			check((ea==nil)==(eb==nil), "candidate eligibility changed")
			if ea then
				for _,key in ipairs({"x","y","q","r","ready_before","height_range","score"}) do
					check(ea[key]==eb[key], "candidate "..key.." changed")
				end
				check(eb.mountain==nil and eb.maximum_rise==nil and eb.higher_samples==nil,
					"losing candidates must not calculate surrounding relief")
				if not best_a or ea.score<best_a.score then best_a=ea end
				if not best_b or eb.score<best_b.score then best_b=eb end
			end
		end end
		check(best_a~=nil and best_b~=nil,"fixture must select a winner")
		check(finish(best_b)==true,"winner certificate failed")
		for key,value in pairs(best_a) do check(best_b[key]==value,"winner "..key.." changed") end
		a.pad_q,a.pad_r=best_a.q,best_a.r; b.pad_q,b.pad_r=best_b.q,best_b.r
		last_winner=best_b
	end
	check(bcalls.height<acalls.height/5,"height samples were not reused")
	check(bcalls.world<acalls.world/5,"hex conversions were not reused")
	check(bcalls.ready==acalls.ready,"live readiness call order/count changed")
	check(stats.relief_reads==4*9 and stats.selected_groups==4,"winner-only read accounting")
	check(stats.height_hits>stats.height_misses,"cache coverage")
	-- A changed source between selection and publication must not be silently accepted.
	b.pad_q=false
	local winner=scorer(last_winner.q,last_winner.r,0,0); check(winner~=nil,"certificate fixture")
	b.change=1
	local ok,reason=finish(winner)
	check(ok==false and type(reason)=="string","stale winner center must fail closed")
	-- A new planning invocation must not inherit any terrain sample from the preceding epoch.
	local new_score,new_finish=compile(production,b)
	local new_winner=new_score(last_winner.q,last_winner.r,0,0)
	check(new_finish(new_winner)==true,"cache leaked into a later planning epoch")
end
check(not block(production):find("Random",1,true),"no RNG belongs in the sampling optimization")
check(production:find('OptimizationFailure("rocket terrain sampling", relief_error, map)',1,true),
	"production publication must surface a failed certificate")
print("rocket sampling: "..tests.." checks passed")

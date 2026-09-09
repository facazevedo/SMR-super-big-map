-- The exact current read predicates/order versus v957, without touching feather/write code.
local old = assert(io.popen("git show 9982d4b:Code/sbm_terrain_copy.lua", "r"))
local reference = old:read("*a"); assert(old:close())
local f = assert(io.open(arg[1] or "Code/sbm_terrain_copy.lua", "r"))
local production = f:read("*a"); f:close()
local function extract(source, name, following)
	local a=assert(source:find("\tlocal function "..name.."(",1,true))
	local b=assert(source:find("\tlocal function "..following.."(",a+1,true))
	return source:sub(a,b-1)
end
local function compile(source,env)
	return assert(load(extract(source,"scan_line_range","collect_axis")
		..extract(source,"refine_step","validate_sampled_track")
		.."\nreturn scan_line_range, refine_step", "crease samples", "t",
		setmetatable(env,{__index=_G})))()
end
local tests=0
local function check(ok,msg) assert(ok,msg);tests=tests+1 end
local function equal(a,b)
	if type(a)~=type(b) then return false end
	if type(a)~="table" then return a==b end
	for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
	for k in pairs(b) do if a[k]==nil then return false end end
	return true
end
local function fixture(wide,pattern,sign,step)
	local reads=0
	local env={wide_ring_only=wide,threshold=128,accessed={}}
	function env.at(axis,p,along)
		reads=reads+1
		env.accessed[axis..":"..p..":"..along]=true
		if p<0 or p>=64 or (pattern==4 and p%13==0) then return nil end
		local v=10000+(p>=step and sign*1000 or 0)
		if pattern==2 then v=v+p*200 end -- sustained slope
		if pattern==3 then v=v+((p*37+along*31)%29)*10 end -- noisy coherent boundary
		if pattern==5 then v=(p>=step and 65535 or 0) end
		if pattern==6 then v=v+(p>=step+8 and -sign*1000 or 0) end
		return v
	end
	function env.offer_candidate(row,axis,perp,width,edge,low_before,jump)
		row[#row+1]={axis=axis,perp=perp,width=width,edge=edge,low_before=low_before,jump=jump}
	end
	return env,function() return reads end
end
for _,wide in ipairs({false,true}) do
	for pattern=1,6 do for _,sign in ipairs({-1,1}) do for _,step in ipairs({1,20,40,63}) do
		for _,edge in ipairs({"left","right","top","bottom"}) do
			local axis=(edge=="left" or edge=="right") and "x" or "y"
			local a,ar=fixture(wide,pattern,sign,step)
			local b,br=fixture(wide,pattern,sign,step)
			local scan_a,refine_a=compile(reference,a)
			local scan_b,refine_b=compile(production,b)
			local left,right={},{}
			scan_a(left,axis,7,1,61,edge);scan_b(right,axis,7,1,61,edge)
			check(equal(left,right),"discovery candidates or ordering changed")
			local track={axis=axis,edge=edge,perp_n=64,low_before=sign>0}
			for _,predicted in ipairs({1,20,40,61}) do
				local p,w=refine_a(track,7,predicted)
				local op,ow=refine_b(track,7,predicted)
				check(p==op and w==ow,"refinement winner changed")
			end
			check(br()<ar()/2,"rolling neighbourhood did not remove repeated grid reads")
			check(equal(a.accessed,b.accessed),"sample coordinate union changed")
			-- Reusing samples across calls would be stale after a preceding track write.
			a.at=function() return 0 end;b.at=a.at
			local p,w=refine_a(track,7,20);local op,ow=refine_b(track,7,20)
			check(p==op and w==ow,"refinement reused samples from before another track write")
		end
	end end end
end
-- These geometry repairs are intentionally outside this optimization.
for _,wide in ipairs({false,true}) do
	for _,range in ipairs({{4,3},{1,1},{61,61},{1,2}}) do
		local a,ar=fixture(wide,4,1,1)
		local b,br=fixture(wide,4,1,1)
		local sa,ra=compile(reference,a);local sb,rb=compile(production,b)
		local left,right={},{}
		sa(left,"x",0,range[1],range[2],"left")
		sb(right,"x",0,range[1],range[2],"left")
		check(equal(left,right),"empty/singleton discovery changed")
		check(br()<=ar(),"short discovery read past the original neighborhood")
		local before_a,before_b=ar(),br()
		local track={axis="x",edge="left",perp_n=2,low_before=true}
		local p,w=ra(track,0,1);local op,ow=rb(track,0,1)
		check(p==op and w==ow and ar()==before_a and br()==before_b,
			"empty refinement must not read or invent an edge")
	end
end
local actual_join=extract(production,"feather_join","offer_candidate")
local expected_join=extract(reference,"feather_join","offer_candidate")
if production:find("\tlocal join_basis_cache = {}\n\tlocal function feather_join",1,true) then
	-- v966 explicitly optimizes this formerly untouched body. Retain a strict
	-- source certificate: permit ONLY this exact coefficient-hoisting rewrite.
	-- The separate join-basis oracle also checks all rounded outputs and cache reuse.
	local original_loop=[=[		for p = lo + 1, hi - 1 do
			local t = (p - lo + 0.0) / span
			local t3 = t * t * t
			local t4, t5 = t3 * t, t3 * t * t
			local smooth = 10 * t3 - 15 * t4 + 6 * t5
			local value = math.floor(v0 + delta * smooth
				+ m0 * (t - 6 * t3 + 8 * t4 - 3 * t5)
				+ m1 * (-4 * t3 + 7 * t4 - 3 * t5) + 0.5)
]=]
	local cached_loop=[=[		-- These coefficients depend only on integer span and relative position.
		-- Preserve their original floating-point expressions and final evaluation order.
		local basis = join_basis_cache[span]
		if not basis then
			basis = {}
			for relative = 1, span - 1 do
				local t = (relative + 0.0) / span
				local t3 = t * t * t
				local t4, t5 = t3 * t, t3 * t * t
				basis[relative] = { 10 * t3 - 15 * t4 + 6 * t5,
					t - 6 * t3 + 8 * t4 - 3 * t5, -4 * t3 + 7 * t4 - 3 * t5 }
			end
			join_basis_cache[span] = basis
		end
		for p = lo + 1, hi - 1 do
			local coefficients = basis[p - lo]
			local value = math.floor(v0 + delta * coefficients[1]
				+ m0 * coefficients[2] + m1 * coefficients[3] + 0.5)
]=]
	local start,finish=assert(expected_join:find(original_loop,1,true))
	expected_join=expected_join:sub(1,start-1)..cached_loop..expected_join:sub(finish+1)
end
check(actual_join==expected_join,"bounded monotone edge join changed outside exact basis hoist")
print("crease sampling: "..tests.." checks passed")

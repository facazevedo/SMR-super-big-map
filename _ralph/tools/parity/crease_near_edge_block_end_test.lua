-- Near-edge block ends: the vanilla border's offset blocks end in short grid-aligned steps
-- perpendicular to the edge, often wedges fading inward. They are blended out; natural cliffs,
-- steps that do not start at the edge and ends of destination-pass seams are left alone.
local f=assert(io.open(arg[1] or "Code/sbm_terrain_copy.lua","r"))
local source=f:read("*a");f:close()
local discovery=assert(source:match("(local function BuildHeightStepDiscoveryIndex.-)\nlocal function RepairInternalHeightStep"),
	"native crease discovery helper missing")
local repair=assert(source:match("(local function RepairNearEdgeSourceSeams.-\nend)\n"),
	"near-edge seam repair missing")
local near_edge=assert(load(discovery.."\n"..repair.."\nreturn RepairNearEdgeSourceSeams"))()
local api=dofile("_ralph/tools/parity/native_grid_double.lua")
api.GridMask=function(input,output,lo,hi)
	local w,h=input:size()
	for y=0,h-1 do for x=0,w-1 do
		local v=input:get(x,y)
		output:set(x,y,(v>=lo and v<=hi) and 1 or 0)
	end end
end
-- The band depth scales with map size (near_margin = size/192): 2688 cells gives the 14-cell band
-- a block end needs. Heights are procedural; only writes are stored.
local N=2688
api.GridMinMax=function() return 15000,26000 end
local function lazy(fn)
	local g={format="u",bits=16,writes={}}
	function g:size() return N,N end
	function g:get(x,y)
		assert(x>=0 and x<N and y>=0 and y<N,"read outside grid")
		return self.writes[y*N+x] or fn(x,y)
	end
	function g:set(x,y,v)
		assert(x>=0 and x<N and y>=0 and y<N,"write outside grid")
		self.writes[y*N+x]=math.max(0,math.min(65535,math.floor(v)))
	end
	function g:new_instance(w,h) return api.NewComputeGrid(w,h,"u",16) end
	function g:free() end
	return g
end
local checks=0
local function check(ok,message) assert(ok,message);checks=checks+1 end
local function base(x,y) return 20000+math.floor(900*math.sin(x/37)+700*math.cos(y/29)+(x*y)%7) end
-- Features are described in edge coordinates (pos along the edge, depth from it) and mapped.
local function field(edge,feature)
	return function(x,y)
		local pos,depth
		if edge=="bottom" then pos,depth=x,N-1-y elseif edge=="top" then pos,depth=x,y
		elseif edge=="left" then pos,depth=y,x else pos,depth=y,N-1-x end
		return base(x,y)+feature(pos,depth)
	end
end
local function cell(edge,pos,depth)
	if edge=="bottom" then return pos,N-1-depth elseif edge=="top" then return pos,depth
	elseif edge=="left" then return depth,pos end
	return N-1-depth,pos
end
local function height(g,edge,pos,depth) local x,y=cell(edge,pos,depth);return g:get(x,y) end
local function excess(g,edge,c,depth)
	local v0,a,b,v3=height(g,edge,c-1,depth),height(g,edge,c,depth),height(g,edge,c+1,depth),height(g,edge,c+2,depth)
	return (b-a)-((a-v0)+(v3-b))/2
end
local function changed_positions(g,edge)
	local list={}
	for key in pairs(g.writes) do
		local x,y=key%N,key//N
		local pos,depth
		if edge=="bottom" then pos,depth=x,N-1-y elseif edge=="top" then pos,depth=x,y
		elseif edge=="left" then pos,depth=y,x else pos,depth=y,N-1-x end
		list[#list+1]={pos,depth}
	end
	return list
end

-- 1. The 15S67E shape: a raised seam piece (depth 6, 60 cells) on a seam line that also carries a
-- long lowered seam, over a block tilted into a wedge (440 units at the edge, 40 at depth 10).
-- Repairing the piece leaves the wedge as two block ends, which are then blended out.
local block=function(pos,depth)
	local z=0
	if pos>=1300 and pos<=1359 then
		if depth<=10 then z=z+(11-depth)*40 end
		if depth<=6 then z=z+300 end
	end
	if pos>=100 and pos<=400 and depth<=6 then z=z-1000 end
	return z
end
for _,edge in ipairs({"bottom","top","left","right"}) do
	local g=lazy(field(edge,block))
	check(excess(g,edge,1299,0)>=700,"fixture block end missing on "..edge)
	local ok,report=near_edge(api,g)
	check(ok and report.qualified==1,edge.." seam piece not repaired: "..tostring(report.lines))
	check(report.ends==2,edge.." block ends not repaired: "..tostring(report.end_lines))
	check(report.end_lines:find(edge..":1299:d0-",1,true)==1 and report.end_lines:find(edge..":1359:d0-",1,true),
		"block end summary wrong: "..tostring(report.end_lines))
	for depth=0,10 do for _,c in ipairs({1299,1359}) do
		check(math.abs(excess(g,edge,c,depth))<=12,edge.." block-end step remains at "..c..", depth "..depth..": "..excess(g,edge,c,depth))
	end end
	for _,p in ipairs(changed_positions(g,edge)) do
		check(p[1]>=1260 and p[1]<=1400,edge.." changed a cell away from the block: pos "..p[1])
		check(p[2]<=40,edge.." changed a cell too deep: depth "..p[2])
	end
	-- The blend is gentle: no new step anywhere across either 24-cell ramp.
	for depth=0,10 do for _,c0 in ipairs({1288,1348}) do for c=c0,c0+22 do
		check(math.abs(excess(g,edge,c,depth))<=40,edge.." ramp too steep at "..c..","..depth..": "..excess(g,edge,c,depth))
	end end end
end

-- 2. A straight cliff that runs from the edge far inland is terrain, not a block end.
local g=lazy(field("bottom",function(pos,depth) if pos>=1500 and depth<=60 then return 400 end return 0 end))
local ok,report=near_edge(api,g)
check(report.ends==0 and next(g.writes)==nil,"inland cliff was treated as a block end")

-- 1b. The contrast test finds this seam only 10 cells inside its block (its step is weak there).
-- The block end still lies within the repaired stretch and is blended out.
local offset_block=function(pos,depth)
	local z=0
	if pos>=1300 and pos<=1359 then
		if depth<=10 then z=z+(11-depth)*40 end
		if depth<=6 then z=z+(pos<1310 and 60 or 300) end
	end
	if pos>=100 and pos<=400 and depth<=6 then z=z-1000 end
	return z
end
g=lazy(field("bottom",offset_block))
ok,report=near_edge(api,g)
check(ok and report.qualified==1 and report.lines:find(":1310-1359:raised",1,true),"offset seam piece not found: "..tostring(report.lines))
check(report.end_lines:find("bottom:1299:d0-",1,true)==1,"block end before the detected seam start missed: "..tostring(report.end_lines))
for depth=0,10 do
	check(math.abs(excess(g,"bottom",1299,depth))<=12,"offset block end remains at depth "..depth..": "..excess(g,"bottom",1299,depth))
end

-- 2b. Even at the end of a repaired seam piece, a cliff that carries on inland is terrain.
g=lazy(field("bottom",function(pos,depth)
	local z=0
	if pos>=1500 and depth<=60 then z=z+400 end
	if pos>=1500 and pos<=1559 and depth<=6 then z=z+300 end
	if pos>=100 and pos<=400 and depth<=6 then z=z-1000 end
	return z
end))
ok,report=near_edge(api,g)
check(report.qualified==1 and report.ends==0,"inland cliff at a piece end was treated as a block end: "..tostring(report.end_lines))
for _,p in ipairs(changed_positions(g,"bottom")) do
	check(p[2]<=6,"the inland cliff was reshaped at depth "..p[2])
end

-- 3. A step that does not start at the edge is left alone.
g=lazy(field("bottom",function(pos,depth) if pos>=1700 and depth>=5 and depth<=12 then return 400 end return 0 end))
ok,report=near_edge(api,g)
check(report.ends==0,"a step away from the edge was treated as a block end")

-- 4. The ends of a long lowered seam belong to the destination pass, which translates the seam.
g=lazy(field("bottom",function(pos,depth) if pos>=200 and pos<=600 and depth<=10 then return -1000 end return 0 end))
ok,report=near_edge(api,g)
check(report.qualified==0 and report.ends==0 and next(g.writes)==nil,
	"destination-pass seam or its ends were touched: "..tostring(report.lines).." / "..tostring(report.end_lines))

-- 5. A lone short block with no seam line behind it is ordinary terrain: neither its side nor
-- its ends change.
g=lazy(field("bottom",function(pos,depth) if pos>=200 and pos<=259 and depth<=10 then return -1000 end return 0 end))
ok,report=near_edge(api,g)
check(report.qualified==0 and report.ends==0 and next(g.writes)==nil,"lone block was repaired")

-- 6. Deterministic.
local a,b=lazy(field("bottom",block)),lazy(field("bottom",block))
near_edge(api,a);near_edge(api,b)
local same=true
for k,v in pairs(a.writes) do if b.writes[k]~=v then same=false end end
for k in pairs(b.writes) do if a.writes[k]==nil then same=false end end
check(same,"block-end repair is not deterministic")
print("near-edge block ends: "..checks.." checks passed")

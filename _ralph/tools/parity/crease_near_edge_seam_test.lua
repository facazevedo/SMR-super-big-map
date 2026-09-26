-- Near-edge seam pieces: vanilla border seams the destination pass leaves (short pieces and raised
-- edge strips on a long seam line) are bent onto the inner surface; nothing else changes.
local f=assert(io.open(arg[1] or "Code/sbm_terrain_copy.lua","r"))
local source=f:read("*a");f:close()
local discovery=assert(source:match("(local function BuildHeightStepDiscoveryIndex.-)\nlocal function RepairInternalHeightStep"),
	"native crease discovery helper missing")
local repair=assert(source:match("(local function RepairNearEdgeSourceSeams.-\nend)\n"),
	"near-edge seam repair missing")
local near_edge=assert(load(discovery.."\n"..repair.."\nreturn RepairNearEdgeSourceSeams"))()
local api=dofile("_ralph/tools/parity/native_grid_double.lua")
-- The double leaves GridMask to each test; the discovery test proves both bound conventions agree.
api.GridMask=function(input,output,lo,hi)
	local w,h=input:size()
	for y=0,h-1 do for x=0,w-1 do
		local v=input:get(x,y)
		output:set(x,y,(v>=lo and v<=hi) and 1 or 0)
	end end
end
local checks=0
local function check(ok,message) assert(ok,message);checks=checks+1 end

-- Production wiring: vanilla resolution, after the wide-ring repair, before resampling, loud failure.
local call=source:find("RepairNearEdgeSourceSeams(seam_api, src_sub)",1,true)
local wide=source:find("RepairQualifiedSourceHeightSteps(src_sub, tracks)",1,true)
local resample=source:find("GridResample(src_sub, fw, fh",1,true)
check(call and wide and resample and wide<call and call<resample,"near-edge repair must run on the source grid before resampling")
check(source:find('OptimizationFailure("near-edge seam discovery", seam_report.error, map)',1,true)~=nil,
	"near-edge discovery failure is not surfaced")
check(source:find('cfg_bool("STRETCH_REPAIR_NEAR_EDGE_SEAMS", true)',1,true)~=nil,"near-edge repair flag missing")
local cf=assert(io.open("Code/sbm_config.lua","r"));local config=cf:read("*a");cf:close()
check(config:find("config.StretchRepairNearEdgeSeams = true",1,true)~=nil,"near-edge repair must default on")
check(config:find("C.STRETCH_REPAIR_NEAR_EDGE_SEAMS = as_bool(config.StretchRepairNearEdgeSeams)",1,true)~=nil,
	"near-edge repair config key missing")

local N=256
-- Smooth rolling terrain with a gentle slope toward the right edge: no natural one-cell steps.
local function base(x,y) return 20000+math.floor(900*math.sin(x/37)+700*math.cos(y/29)-4*x+(x*y)%7) end
-- seams: list of {edge_side_depth, first, last, delta}; delta is added to the edge-side strip
-- (cells from the right edge through depth) on those rows. Depth 6 = the step between cells
-- N-8 and N-7, i.e. discovery perp N-8.
local function fixture(seams,extra)
	local grid=api.NewComputeGrid(N,N,"u",16)
	for y=0,N-1 do for x=0,N-1 do
		local z=base(x,y)
		for _,s in ipairs(seams) do
			if y>=s[2] and y<=s[3] and x>=N-1-s[1] then z=z+s[4] end
		end
		if extra then z=extra(x,y,z) end
		grid:set(x,y,z)
	end end
	return grid
end
local function snapshot(grid)
	local copy={}
	for y=0,N-1 do for x=0,N-1 do copy[y*N+x]=grid:get(x,y) end end
	return copy
end
local function changed_cells(grid,before)
	local list={}
	for y=0,N-1 do for x=0,N-1 do
		if grid:get(x,y)~=before[y*N+x] then list[#list+1]={x,y} end
	end end
	return list
end
-- Height continuity at the seam: the edge-side cell continues the inner slope.
local function seam_error(grid,depth,y)
	local e=N-1-depth
	local inner,inner_next,edge=grid:get(e-1,y),grid:get(e-2,y),grid:get(e,y)
	return math.abs(edge-(inner+(inner-inner_next)))
end

-- 1. The 49N28E shape: a raised 40-row strip at depth 6 on the line of a long lowered seam.
local grid=fixture({{6,0,39,300},{6,100,255,-1000}})
local before=snapshot(grid)
local ok,report=near_edge(api,grid)
check(ok and report.qualified==1,"raised piece on a seam line must be repaired: "..tostring(report.reason))
check(report.lines:find("right:"..(N-8)..":0-39:raised",1,true)~=nil,"piece summary wrong: "..tostring(report.lines))
for y=0,39 do check(seam_error(grid,6,y)<=2,"seam step remains at row "..y..": "..seam_error(grid,6,y)) end
for _,cell in ipairs(changed_cells(grid,before)) do
	check(cell[1]>=N-7,"an inner cell changed: "..cell[1]..","..cell[2])
	check(cell[2]<100,"the destination-class lowered seam must stay for the destination pass")
end
-- No ridge or terrace along the edge: the repaired strip is as smooth between rows as the
-- surrounding terrain (the original strip stood 300 units proud of row 40).
local max_row_step,natural=0,0
for y=1,99 do
	for x=N-7,N-1 do max_row_step=math.max(max_row_step,math.abs(grid:get(x,y)-grid:get(x,y-1))) end
	for x=N-20,N-9 do natural=math.max(natural,math.abs(grid:get(x,y)-grid:get(x,y-1))) end
end
check(max_row_step<=natural+24,"repaired strip is rougher than its surroundings: "..max_row_step.." vs "..natural)
-- The long lowered seam is untouched and still a full-strength step.
check(grid:get(N-7,150)-grid:get(N-8,150)<=-900,"destination-class seam was altered")
grid:free()

-- 2. A short lowered piece on the same line is left by the destination pass (too short); repair it.
grid=fixture({{6,10,49,-400},{6,100,255,-1000}})
ok,report=near_edge(api,grid)
check(ok and report.qualified==1 and report.lines:find(":10-49:low",1,true),"short lowered piece must be repaired: "..tostring(report.lines))
for y=10,49 do check(seam_error(grid,6,y)<=2,"short lowered seam remains at row "..y) end
grid:free()

-- 3. A long lowered seam too weak for the destination pass is repaired here instead.
grid=fixture({{6,0,255,-240}})
ok,report=near_edge(api,grid)
check(ok and report.qualified==1,"weak long seam must be repaired: "..tostring(report.lines))
grid:free()

-- 4. The same raised strip on a line with no long seam is ordinary terrain: no change.
grid=fixture({{6,0,39,300}})
before=snapshot(grid)
ok,report=near_edge(api,grid)
check(not ok and report.qualified==0 and #changed_cells(grid,before)==0,"unsupported short piece must not be repaired")
grid:free()

-- 5. A cliff that is not grid-aligned (diagonal) never forms a seam line.
grid=fixture({},function(x,y,z) if x-N+12>=math.floor(y/12) then return z+800 end return z end)
before=snapshot(grid)
ok,report=near_edge(api,grid)
check(#changed_cells(grid,before)==0,"diagonal cliff was treated as a seam")
grid:free()

-- 6. Pieces too short to see (under 16 rows) are left alone.
grid=fixture({{6,0,9,300},{6,100,255,-1000}})
before=snapshot(grid)
ok,report=near_edge(api,grid)
check(report.qualified==0 and #changed_cells(grid,before)==0,"a 10-row piece must not be repaired")
grid:free()

-- 7. Every edge: mirror/transpose the case-1 field and expect the same repair.
local function oriented(edge)
	local plain=fixture({{6,0,39,300},{6,100,255,-1000}})
	local g=api.NewComputeGrid(N,N,"u",16)
	for y=0,N-1 do for x=0,N-1 do
		local sx,sy=x,y
		if edge=="left" then sx=N-1-x elseif edge=="top" then sx,sy=N-1-y,x elseif edge=="bottom" then sx,sy=y,x end
		g:set(x,y,plain:get(sx,sy))
	end end
	plain:free()
	return g
end
for _,edge in ipairs({"left","top","bottom"}) do
	grid=oriented(edge)
	ok,report=near_edge(api,grid)
	check(ok and report.qualified==1 and report.lines:find(edge..":",1,true)==1,
		edge.." edge piece not repaired: "..tostring(report.lines))
	grid:free()
end

-- 8. Repair is deterministic.
local a,b=fixture({{6,0,39,300},{6,100,255,-1000}}),fixture({{6,0,39,300},{6,100,255,-1000}})
near_edge(api,a);near_edge(api,b)
local same=true
for y=0,N-1 do for x=0,N-1 do if a:get(x,y)~=b:get(x,y) then same=false end end end
check(same,"repair is not deterministic");a:free();b:free()

-- 9. A strip tilted against the inner slope is bent to match it: no crease line at the seam, and
-- the bend fades to the strip's own slope by the physical edge.
grid=fixture({{6,100,255,-1000}},function(x,y,z)
	-- Real slope mismatches change gradually along the edge; this one fades out over rows 40-69.
	local tilt=y<=39 and 45 or math.max(0,math.floor(45*(69-y)/30))
	if y<=69 and x>=N-7 then return z+(y<=39 and 300 or 0)+tilt*(x-(N-7)) end
	return z
end)
before=snapshot(grid)
ok,report=near_edge(api,grid)
check(ok and report.qualified==1,"tilted raised piece must be repaired: "..tostring(report.lines))
for y=0,39 do
	local e=N-7
	local inner_slope=grid:get(e-1,y)-grid:get(e-2,y)
	local edge_slope=grid:get(e+1,y)-grid:get(e,y)
	check(math.abs(edge_slope-inner_slope)<=12,"slope crease remains at row "..y..": "..(edge_slope-inner_slope))
	local outer=(grid:get(N-1,y)-grid:get(N-2,y))-(before[y*N+N-1]-before[y*N+N-2])
	check(math.abs(outer)<=6,"bend does not fade out by the physical edge at row "..y..": "..outer)
end
grid:free()

-- 10. Vanilla heights are 8-unit quantised with cell-scale detail. The repaired strip must stay as
-- smooth along the edge as the terrain inside it (per-row slope bends made it three times rougher).
local function noisy(x,y,z)
	local r=((x*7919+y*104729)%97)/97
	return z+8*math.floor(r*4-2)
end
grid=fixture({{6,0,63,300},{6,100,255,-1000}},function(x,y,z)
	z=noisy(x,y,z)
	return z-z%8
end)
ok,report=near_edge(api,grid)
check(ok and report.qualified==1,"noisy raised piece must be repaired: "..tostring(report.lines))
local function roughness(x0,x1)
	local total,n=0,0
	for y=1,62 do for x=x0,x1 do
		total=total+math.abs(grid:get(x,y+1)-2*grid:get(x,y)+grid:get(x,y-1));n=n+1
	end end
	return total/n
end
local inside,strip=roughness(N-20,N-9),roughness(N-7,N-1)
check(strip<=inside*1.5+4,"repaired strip is rougher along the edge: "..strip.." vs "..inside)
grid:free()

-- 11. Real seams fade rather than stop (49N28E: 300 units at row 50, zero near row 69). The
-- contrast test loses the tail first; the hold region must still flatten all of it.
grid=fixture({{6,100,255,-1000}},function(x,y,z)
	if x>=N-7 and y<=69 then return z+(y<=39 and 300 or math.floor(300*(69-y)/30)) end
	return z
end)
ok,report=near_edge(api,grid)
check(ok and report.qualified==1,"fading piece must be repaired: "..tostring(report.lines))
for y=0,75 do check(seam_error(grid,6,y)<=2,"fading seam tail remains at row "..y..": "..seam_error(grid,6,y)) end
grid:free()

-- 12. Missing native API fails loudly without writing.
local missing={};for k,v in pairs(api) do missing[k]=v end;missing.GridMask=nil
grid=fixture({{6,0,39,300},{6,100,255,-1000}})
before=snapshot(grid)
ok,report=near_edge(missing,grid)
check(not ok and report.error and report.error:find("GridMask",1,true),"missing API must fail explicitly")
check(#changed_cells(grid,before)==0,"failed discovery wrote heights")
grid:free()
print("near-edge seam repair: "..checks.." checks passed")

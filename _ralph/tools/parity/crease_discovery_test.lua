-- Native discovery only: exact scalar candidates remain the acceptance oracle.
local f=assert(io.open("Code/sbm_terrain_copy.lua","r"))
local source=f:read("*a");f:close()
local body=assert(source:match("(local function BuildHeightStepDiscoveryIndex.-)\nlocal function RepairInternalHeightStep"),
	"native crease discovery helper missing")
local build=assert(load(body.."\nreturn BuildHeightStepDiscoveryIndex"))()
local api=dofile("_ralph/tools/parity/native_grid_double.lua")
local checks=0
local function check(ok,message) assert(ok,message);checks=checks+1 end
check(source:find("BuildHeightStepDiscoveryIndex(discovery_api, grid, axis,",1,true)~=nil,
	"production discovery does not use native prefilter")
check(source:find('OptimizationFailure("native crease discovery", report.error, map)',1,true)~=nil,
	"production discovery failure is not surfaced")
local function same(a,b)
	if type(a)~=type(b) then return false end
	if type(a)~="table" then return a==b end
	for k,v in pairs(a) do if not same(v,b[k]) then return false end end
	for k in pairs(b) do if a[k]==nil then return false end end
	return true
end
local function oracle(grid,axis,p0,p1,n,step,widths,threshold)
	local rows={};local w,h=grid:size();local perpendicular=axis=="x" and w or h
	local function at(p,a) return axis=="x" and grid:get(p,a) or grid:get(a,p) end
	for along=0,n-1,step do
		local row={}
		for p=p0,p1 do
			for width=1,widths do
				if p>=1 and p+width+1<perpendicular then
					local v0,a,b,v3=at(p-1,along),at(p,along),at(p+width,along),at(p+width+1,along)
					local jump=math.abs(b-a)
					if jump>=threshold and jump>=2*math.max(math.abs(a-v0),math.abs(v3-b),1) then
						row[#row+1]=p;break
					end
				end
			end
		end
		if #row>0 then rows[along]=row end
	end
	return rows
end
for _,inclusive in ipairs({false,true}) do
	api.GridMask=function(input,output,lo,hi)
		local w,h=input:size()
		for y=0,h-1 do for x=0,w-1 do
			local v=input:get(x,y)
			output:set(x,y,((inclusive and v>=lo or not inclusive and v>lo) and v<=hi) and 1 or 0)
		end end
	end
	for case=1,12 do
		local grid=api.NewComputeGrid(39,35,"u",16)
		for y=0,34 do for x=0,38 do
			local p=case%2==0 and y or x
			local jump=({127,128,129,65535})[(case-1)%4+1]
			local z=p>=17 and jump or 0
			if case>=9 then z=(x*x*71+y*y*139+x*y*51)%65536 end
			if case==5 or case==6 then z=math.min(65535,z+p*64) end
			if case==7 or case==8 then z=65535-z end
			grid:set(x,y,z)
		end end
		for _,axis in ipairs({"x","y"}) do for _,step in ipairs({1,8}) do for _,widths in ipairs({1,3}) do
			local n=axis=="x" and 35 or 39
			local perpendicular=axis=="x" and 39 or 35
			local rows,stats=build(api,grid,axis,1,perpendicular-3,n,step,widths,128)
			check(rows~=nil,"native build failed: "..tostring(stats))
			check(same(rows,oracle(grid,axis,1,perpendicular-3,n,step,widths,128)),"candidate/order mismatch")
			check(stats.enumerated>=stats.candidates,"enumeration census")
			local fast,fast_stats,offers=build(api,grid,axis,1,perpendicular-3,n,step,widths,128,true)
			check(same(rows,fast),"signed offer export changed candidate order: "..tostring(fast_stats).." case="..case.." axis="..axis.." step="..step.." widths="..widths)
			local function at(p,a) return axis=="x" and grid:get(p,a) or grid:get(a,p) end
			for _,sign in ipairs({-1,1}) do
				local directed,dstats,doffers=build(api,grid,axis,1,perpendicular-3,n,step,widths,128,true,sign)
				check(directed~=nil,'directed discovery failed: '..tostring(dstats))
				local expected_rows={}
				for along,row in pairs(offers) do for p,position in pairs(row) do
					local found=false
					for width,jump in pairs(position) do
						local expected=jump*sign>0 and jump or nil
						local actual=doffers[along] and doffers[along][p] and doffers[along][p][width]
						check(actual==expected,'edge mask changed a qualifying signed offer')
						found=found or expected~=nil
					end
					if found then expected_rows[along]=expected_rows[along] or {};table.insert(expected_rows[along],p) end
				end end
				for _,row in pairs(expected_rows) do table.sort(row) end
				check(same(directed,expected_rows),'edge mask changed candidate order')
			end
			for along=0,n-1,step do for p=1,perpendicular-3 do for width=1,widths do
				if p+width+1<perpendicular then
					local v0,a,b,v3=at(p-1,along),at(p,along),at(p+width,along),at(p+width+1,along)
					local jump=b-a
					local expected=math.abs(jump)>=128 and math.abs(jump)>=2*math.max(math.abs(a-v0),math.abs(v3-b),1)
					local actual=offers[along] and offers[along][p] and offers[along][p][width]
					check((expected and actual==jump) or (not expected and actual==nil),"signed offer differs from scalar predicate")
				end
			end end end
		end end end
		grid:free()
	end
end
local grid=api.NewComputeGrid(39,35,"u",16)
for y=0,34 do for x=17,38 do grid:set(x,y,128) end end
local missing={};for k,v in pairs(api) do missing[k]=v end;missing.GridMask=nil
local rows,why=build(missing,grid,"x",1,36,35,1,3,128)
check(rows==nil and why:find("GridMask",1,true),"missing API must fail explicitly")
local truncated={};for k,v in pairs(api) do truncated[k]=v end;truncated.GridForeach=function() end
rows,why=build(truncated,grid,"x",1,36,35,1,3,128)
check(rows==nil and why:find("enumeration",1,true),"lost callback must fail")
local duplicate={};for k,v in pairs(api) do duplicate[k]=v end
duplicate.GridForeach=function(g,callback,lo,hi)
	api.GridForeach(g,function(v,x,y) callback(v,x,y);callback(v,x,y) end,lo,hi)
end
rows,why=build(duplicate,grid,"x",1,36,35,1,3,128)
check(rows==nil and why:find("duplicate",1,true),"duplicate callback must fail")
check(grid:get(0,0)==0 and grid:get(38,34)==128,"discovery changed input grid")
grid:free()
print("native crease discovery: "..checks.." checks passed")

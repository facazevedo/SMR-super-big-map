-- Native arithmetic/ownership test double plus the literal current scalar reference.
local api=dofile("_ralph/tools/parity/native_grid_double.lua")
local file=assert(io.open("Code/sbm_terrain_copy.lua","r"))
local source=file:read("*a");file:close()
local body=assert(source:match("(local function RasterNaturalMountainBaseAprons.-)\nlocal function CreateNaturalMountainBaseBuildableAprons"))
local native=assert(load(body.."\nreturn RasterNaturalMountainBaseAprons","production native apron"))()
local reference=dofile("_ralph/tools/parity/v958_scalar_apron.lua")
local tests=0
local function check(ok,msg) assert(ok,msg);tests=tests+1 end
for case=1,16 do
	local grid=api.NewComputeGrid(32,30,"u",16)
	for y=0,29 do for x=0,31 do
		local v=case%4==0 and 65535-(x*37+y*19)%500
			or case%4==1 and (x*37+y*19)%500
			or case%4==2 and 30000+x*11-y*5
			or (x*x*137+y*y*83+x*y*23)%65536
		grid:set(x,y,v)
	end end
	local selected={}
	for index=1,3 do
		local x,y=12+index*2,10+index*3
		local angle=(case*29+index*73)*0.01
		selected[index]={x=x,y=y,sector_x=case,sector_y=index,center=grid:get(x,y),
			gx=math.cos(angle)*3.7,gy=math.sin(angle)*3.7,mountain_x=math.cos(angle),
			mountain_y=math.sin(angle),requires_edit=index~=2}
	end
	local before=grid:clone()
	local policy={outer_short=5,outer_long=6.75,core_fraction=0.2+(case%6)*0.1}
	local ok_a,stats_a=reference(before,selected,policy)
	local ok_b,stats_b,reason=native(api,grid,selected,policy)
	check(ok_a and ok_b,"native/reference failed: "..tostring(reason))
	check(stats_a.modified==stats_b.modified,"modified-cell census changed")
	check(stats_a.shaped==stats_b.shaped and stats_b.shaped==2,"no-edit opportunity was shaped")
	for y=0,29 do for x=0,31 do
		check(before:get(x,y)==grid:get(x,y),"scalar/native height differs at "..case..":"..x..","..y)
	end end
	before:free();grid:free()
end
local grid=api.NewComputeGrid(32,30,"u",16)
local policy={outer_short=5,outer_long=6.75,core_fraction=0.3}
local selected={{x=16,y=16,sector_x=0,sector_y=0,center=400,
	gx=3,gy=0,mountain_x=1,mountain_y=0,requires_edit=true}}
local absent={};for k,v in pairs(api) do absent[k]=v end;absent.GridRound=nil
local ok,stats,reason=native(absent,grid,selected,policy)
check(ok==false and reason:find("GridRound",1,true),"missing native API must fail explicitly")
check(stats.modified==0 and grid:get(16,16)==0,"missing API changed terrain")
local broken={};for k,v in pairs(api) do broken[k]=v end
broken.GridForeach=function() end
ok,stats,reason=native(broken,grid,selected,policy)
check(ok==false and reason:find("enumeration mismatch",1,true),"lost rounding corrections must fail")
check(stats.modified==0 and grid:get(16,16)==0,"enumeration failure published terrain")
grid:free()
-- Allocation failures cannot depend on the game engine's non-throwing assert/error.
grid=api.NewComputeGrid(32,30,"u",16)
local allocation={};for k,v in pairs(api) do allocation[k]=v end
allocation.GridRepack=function() return nil end
ok,stats,reason=native(allocation,grid,selected,policy)
check(ok==false and reason:find("allocation failed",1,true),"allocation failure was not explicit")
check(stats.modified==0 and grid:get(16,16)==0,"allocation failure published terrain")
grid:free()
print("native apron double: "..tests.." checks passed (real-engine differential proof still required)")

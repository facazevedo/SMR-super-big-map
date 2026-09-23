-- Compare the production bounded path with both its strict path and literal
-- scalar raster. A single patch may differ by at most one stored height unit.
local api=dofile('_ralph/tools/parity/native_grid_double.lua')
local f=assert(io.open('Code/sbm_terrain_copy.lua','r'));local source=f:read('*a');f:close()
local body=assert(source:match('(local function RasterNaturalMountainBaseAprons.-)\nlocal function CreateNaturalMountainBaseBuildableAprons'))
local raster=assert(load(body..'\nreturn RasterNaturalMountainBaseAprons'))()
local reference=dofile('_ralph/tools/parity/v958_scalar_apron.lua')
local checks,bounded=0,0
for case=1,72 do
	local grid=api.NewComputeGrid(47,43,'u',16)
	for y=0,42 do for x=0,46 do
		local z=case%3==0 and (x*x*137+y*y*83+x*y*23)%65536
			or math.max(0,math.min(65535,(case%3==1 and 500 or 64500)+x*11-y*7))
		grid:set(x,y,z)
	end end
	local scalar,strict=grid:clone(),grid:clone()
	local angle=case*.37
	local selected={{x=23,y=21,sector_x=case,sector_y=7,center=grid:get(23,21),
		gx=math.cos(angle)*3.7,gy=math.sin(angle)*3.7,mountain_x=math.cos(angle),
		mountain_y=math.sin(angle),requires_edit=true}}
	local policy={outer_short=9,outer_long=12.15,core_fraction=.2+(case%6)*.1}
	assert(reference(scalar,selected,policy))
	local ok,exact,why=raster(api,strict,selected,policy);assert(ok,why)
	policy.rounding_tolerance=1
	local ok,approx,why=raster(api,grid,selected,policy);assert(ok,why)
	assert(approx.exact_samples<=exact.exact_samples,'bounded mode added scalar work')
	bounded=bounded+approx.bounded_rounding_cells
	for y=0,42 do for x=0,46 do
		assert(scalar:get(x,y)==strict:get(x,y),'strict raster changed')
		assert(math.abs(grid:get(x,y)-scalar:get(x,y))<=1,'rounding envelope exceeded one height unit')
		checks=checks+1
	end end
	grid:free();strict:free();scalar:free()
end
assert(bounded>0,'bounded path was not exercised')
print('bounded apron rounding: '..checks..' cells; '..bounded..' redundant exact corrections avoided')

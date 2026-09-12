local f=assert(io.open('Code/sbm_terrain_copy.lua','r')) -- actual production
local candidate_source=f:read('*a');f:close()
local previous=assert(io.popen('git show 1f67811:Code/sbm_terrain_copy.lua','r'))
local old_source=previous:read('*a');assert(previous:close())
local function raster(source)
    local a=assert(source:find('local function RasterNaturalMountainBaseAprons(',1,true))
    local b=assert(source:find('local function CreateNaturalMountainBaseBuildableAprons(',a,true))
    return assert(load(source:sub(a,b-1)..'\nreturn RasterNaturalMountainBaseAprons'))()
end
local old,new=raster(old_source),raster(candidate_source)
local api=dofile('_ralph/tools/parity/native_grid_double.lua')
local checks=0
for _,core in ipairs({0,0.1,0.19999,0.2,0.75,0.75001,0.99}) do
    for _,short in ipairs({0.5,5}) do
        local grid=api.NewComputeGrid(33,35,'u',16)
        for y=0,34 do for x=0,32 do grid:set(x,y,30000+x*31-y*17) end end
        local before=grid:clone()
        local selected={{x=16,y=17,sector_x=3,sector_y=4,center=30123,gx=1.7,gy=-2.3,
            mountain_x=0.6,mountain_y=0.8,requires_edit=true}}
        local policy={outer_short=short,outer_long=short*1.35,core_fraction=core}
        local ok1,s1,e1=old(api,before,selected,policy)
        local ok2,s2,e2=new(api,grid,selected,policy)
        assert(ok1 and ok2,tostring(e1)..'/'..tostring(e2))
        assert(s1.modified==s2.modified and s1.shaped==s2.shaped,'domain census differs')
        for y=0,34 do for x=0,32 do
            assert(grid:get(x,y)==before:get(x,y),'domain/boundary output differs')
            checks=checks+1
        end end
        grid:free();before:free()
    end
end
print('scalar-domain fallback/core endpoints: '..checks..' exact cell checks passed')

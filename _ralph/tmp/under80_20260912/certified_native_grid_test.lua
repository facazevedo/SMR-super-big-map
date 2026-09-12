arg = {arg[1] or '_ralph/runs/under80-20260912/artifacts/certified_steps_research/terrain_candidate.lua'}
dofile('_ralph/tmp/under80_20260912/certificate_offline.lua')
local f = assert(io.open(arg[1], 'r'))
local source = f:read('*a'); f:close()
local body = assert(source:match('(local function BuildHeightStepDiscoveryIndex.-)\nlocal function RepairInternalHeightStep'))
local build = assert(load(body..'\nreturn BuildHeightStepDiscoveryIndex'))()
local api = dofile('_ralph/tools/parity/native_grid_double.lua')
api.GridMask = function(input, output, lo, hi)
    local w,h=input:size()
    for y=0,h-1 do for x=0,w-1 do
        local v=input:get(x,y); output:set(x,y,v>lo and v<=hi and 1 or 0)
    end end
end
local original = api.GridForeach
local grid = api.NewComputeGrid(9,5,'u',16)
for y=0,4 do for x=4,8 do grid:set(x,y,128) end end
for _, bad in ipairs({1,3,262144,131072}) do
    api.GridForeach = function(g, callback, lo, hi)
        original(g,function(_,x,y) callback(bad,x,y) end,lo,hi)
    end
    local rows, why = build(api,grid,'x',1,6,5,1,3,128)
    assert(rows == nil and type(why)=='string','invalid certificate silently accepted')
end
grid:free()
print('invalid certificate rejection: 4 checks passed')

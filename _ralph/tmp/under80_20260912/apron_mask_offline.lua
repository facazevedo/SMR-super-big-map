-- Research-only additions to the existing grid double, not engine substitutes.
local original_dofile=dofile
dofile=function(path)
    local value=original_dofile(path)
    if path=='_ralph/tools/parity/native_grid_double.lua' then
        value.GridPow=function(grid,mul,div)
            local power=mul/(div or 1)
            for y=0,grid.h-1 do for x=0,grid.w-1 do
                grid.values[y*grid.w+x]=string.unpack('f',string.pack('f',grid:get(x,y)^power))
            end end
        end
    end
    return value
end
arg={'_ralph/runs/under80-20260912/artifacts/native_mask_research/terrain_candidate.lua',
    '_ralph/tools/parity/native_apron_test.lua'}
original_dofile('_ralph/tmp/under80_20260912/replay_binding_candidate.lua')

local f = assert(io.open(arg[1], 'r'))
local source = f:read('*a'); f:close()
local body = assert(source:match('(local function BuildHeightStepDiscoveryIndex.-)\nlocal function RepairInternalHeightStep'))
local build = assert(load(body..'\nreturn BuildHeightStepDiscoveryIndex'))()
local api = dofile('_ralph/tools/parity/native_grid_double.lua')
for _, inclusive in ipairs({false, true}) do
    api.GridMask = function(input, output, lo, hi)
        local w, h = input:size()
        for y=0,h-1 do for x=0,w-1 do
            local v = input:get(x,y)
            output:set(x,y, ((inclusive and v>=lo or not inclusive and v>lo) and v<=hi) and 1 or 0)
        end end
    end
    print('certificate oracle: '..dofile('_ralph/tmp/under80_20260912/certificate_oracle.lua')(build, api)..' checks passed; inclusive='..tostring(inclusive))
end

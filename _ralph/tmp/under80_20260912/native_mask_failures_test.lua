local native=dofile('_ralph/tmp/under80_20260912/native_apron_mask.lua')
local checks=0
local function check(ok,why) assert(ok,why);checks=checks+1 end
local function execute(fail_new,fail_clone,corrupt_pow,missing_count,domain)
    local api=dofile('_ralph/tools/parity/native_grid_double.lua')
    api.GridPow=function(grid,mul,div)
        for y=0,grid.h-1 do for x=0,grid.w-1 do
            grid.values[y*grid.w+x]=string.unpack('f',string.pack('f',grid:get(x,y)^(mul/(div or 1))))
        end end
    end
    local allocations,clones,powers=0,0,0
    local all,owned={},{}
    local function wrap(g)
        all[#all+1]=g
        local original=g.clone
        g.clone=function(self)
            clones=clones+1
            if clones==fail_clone then return nil end
            return wrap(original(self))
        end
        return g
    end
    local allocate=api.NewComputeGrid
    api.NewComputeGrid=function(...)
        allocations=allocations+1
        if allocations==fail_new then return nil end
        return wrap(allocate(...))
    end
    local pow=api.GridPow
    api.GridPow=function(grid,...)
        powers=powers+1
        pow(grid,...)
        if powers==corrupt_pow then api.GridMulDivAdd(grid,1001,1000,0) end
    end
    if missing_count then api.GridCount=function() return nil end end
    local function own(g) if g then owned[#owned+1]=g end;return g end
    local candidate={x=40,y=40,mountain_x=0.6,mountain_y=0.8}
    local policy={core_fraction=domain or 1/3}
    local mask,why=native(api,own,candidate,policy,24,32.4,0,0,81,81)
    for i=#owned,1,-1 do owned[i]:free() end
    for _,g in ipairs(all) do check(g.freed,'scratch grid leaked') end
    return mask,why,allocations,clones,powers
end
local mask,why,allocations,clones,powers=execute()
check(mask and not why,'qualified mask rejected')
for i=1,allocations do
    mask,why=execute(i)
    check(not mask and type(why)=='string' and why:find('allocation'),'allocation failure not explicit')
end
for i=1,clones do
    mask,why=execute(nil,i)
    check(not mask and type(why)=='string' and why:find('allocation'),'clone failure not explicit')
end
for i=1,powers do
    mask,why=execute(nil,nil,i)
    check(not mask and type(why)=='string' and why:find('residual'),'bad native power was not rejected')
end
mask,why=execute(nil,nil,nil,true)
check(not mask and type(why)=='string','invalid census accepted')
for _,core in ipairs({0,0.199999,0.750001,0.99}) do
    mask,why,allocations=execute(nil,nil,nil,nil,core)
    check(not mask and not why and allocations==0,'out-of-domain mask must select scalar before native work')
end
print('native mask failure/domain/ownership: '..checks..' checks passed; '..allocations..' final allocations')

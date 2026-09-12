-- Scratch grids only: verify the prerequisite for a future coordinate certificate.
local result={status='running',checks=0}
rawset(_G,'SBM_NATIVE_STEP_CERT_PROBE',result)
local owned={}
local function fail(why) result.error=why; error(why); return false end
local function own(grid)
    if not grid then fail('scratch allocation failed'); return end
    owned[#owned+1]=grid;return grid
end
local ok,why=pcall(function()
    local values={-16777216,-16777215,-8388609,-4194304,-1,0,1,4194304,8388609,16777215,16777216}
    local grid=own(NewComputeGrid(#values,17,'f',32))
    if not grid then return end
    for y=0,16 do for x=0,#values-1 do grid:set(x,y,values[x+1])end end
    local function check(target,label)
        for y=0,16 do for x=0,#values-1 do
            local actual=target:get(x,y)
            if actual~=values[x+1] then return fail(label..' signed integer mismatch '..x..'/'..y..'/'..tostring(actual))end
            result.checks=result.checks+1
        end end
        return true
    end
    if not check(grid,'direct')then return end
    local fraction=own(grid:clone());if not fraction then return end
    GridMulDivAdd(fraction,1,4194304,0)
    GridMulDivAdd(fraction,4194304,1,0)
    if not check(fraction,'dyadic roundtrip')then return end
    local copied=own(NewComputeGrid(#values,17,'f',32));if not copied then return end
    copied:copyrect(grid,box(0,0,#values,1),point(0,0))
    local filled=1
    while filled<17 do
        local count=math.min(filled,17-filled)
        copied:copyrect(copied,box(0,0,#values,count),point(0,filled))
        filled=filled+count
    end
    if not check(copied,'signed doubling copy')then return end
    local opposite=own(grid:clone());if not opposite then return end
    GridMulDivAdd(opposite,-1,1,0)
    GridAdd(opposite,grid)
    for y=0,16 do for x=0,#values-1 do
        if opposite:get(x,y)~=0 then return fail('signed exact cancellation failed')end
        result.checks=result.checks+1
    end end
end)
for i=#owned,1,-1 do owned[i]:free()end
result.status=ok and not result.error and 'pass' or 'fail'
result.error=result.error or (not ok and tostring(why) or nil)
print('SIGNED_COORDINATE_PROBE',result.status,result.checks)
return result.status

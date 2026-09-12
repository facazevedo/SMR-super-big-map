-- Scratch prerequisite: positive setters, adaptive bias, signed native decode.
local result={status='running',checks=0}
rawset(_G,'SBM_NATIVE_STEP_CERT_PROBE',result)
local owned={}
local function fail(why)result.error=why;error(why);return false end
local function own(grid)if not grid then fail('allocation failed');return end;owned[#owned+1]=grid;return grid end
local ok,why=pcall(function()
    for _,values in ipairs({{-16777216,-16777215,-8388608,-4194304,-1,0},
        {-8388608,-4194304,-1,0,1,4194304,8388608},
        {0,1,4194304,8388608,16777215,16777216}})do
        local minimum,maximum=values[1],values[#values]
        if maximum-minimum>16777216 then return fail('span escaped f32 integer range')end
        local grid=own(NewComputeGrid(#values,17,'f',32));if not grid then return end
        for x=0,#values-1 do grid:set(x,0,values[x+1]-minimum)end
        local filled=1
        while filled<17 do
            local count=math.min(filled,17-filled)
            grid:copyrect(grid,box(0,0,#values,count),point(0,filled));filled=filled+count
        end
        GridMulDivAdd(grid,1,1,minimum)
        local magnitude=own(grid:clone());if not magnitude then return end
        GridAbs(magnitude)
        for y=0,16 do for x=0,#values-1 do
            if magnitude:get(x,y)~=math.abs(values[x+1]) then return fail('signed native decode magnitude mismatch')end
            result.checks=result.checks+1
        end end
        GridMulDivAdd(grid,1,4194304,0)
        GridMulDivAdd(grid,4194304,1,0)
        GridMulDivAdd(grid,1,1,-minimum)
        for y=0,16 do for x=0,#values-1 do
            if grid:get(x,y)~=values[x+1]-minimum then return fail('adaptive dyadic roundtrip mismatch')end
            result.checks=result.checks+1
        end end
    end
end)
for i=#owned,1,-1 do owned[i]:free()end
result.status=ok and not result.error and 'pass' or 'fail'
result.error=result.error or (not ok and tostring(why) or nil)
print('ADAPTIVE_COORDINATE_PROBE',result.status,result.checks)
return result.status

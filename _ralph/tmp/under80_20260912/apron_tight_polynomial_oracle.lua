-- Independent scalar core/quintic oracle for the ACTUAL native polynomial block.
-- Explicit issue collection: engine error()/assert() are not control flow here.
return function(polynomial,api)
    local report={checks=0,max_error_units=0,issues={}}
    local W,S=16777216,67108864
    local function issue(s)report.issues[#report.issues+1]=tostring(s)end
    local cores={0.2,0.2+1.0/W,0.25-0.5/W,0.25,0.25+0.5/W,1.0/3.0,
        0.4,0.6-1.0/W,0.6,0.6+1.0/W,0.75-0.5/W,0.75}
    for _,core in ipairs(cores)do
        local owned={}
        local function own(g)if g then owned[#owned+1]=g end;return g end
        local ok,why=pcall(function()
            local w,h=257,24
            local grid=own(api.NewComputeGrid(w,h,'f',32))
            if not grid then issue('polynomial input allocation');return end
            local norms={}
            local c=math.floor(core*W+0.5)
            for y=0,h-1 do for x=0,w-1 do
                local encoded
                if y==0 then encoded=math.floor(x*S/256.0)
                elseif y<8 then encoded=c*4+x-128
                elseif y<13 then encoded=S+x-128
                else encoded=(x*7919+y*104729)%75497472 end
                grid:set(x,y,encoded)
                -- Native f32 get is unsigned; positive integral seed readback is
                -- exact and records any representational rounding of the setter.
                norms[y*w+x]=grid:get(x,y)/(S+0.0)
            end end
            api.GridMulDivAdd(grid,1,S,0)
            local result,err=polynomial(api,own,grid,{core_fraction=core})
            if not result or err then issue(err or 'polynomial failed');return end
            for y=0,h-1 do for x=0,w-1 do
                local n=norms[y*w+x]
                local expected
                if n<=core then expected=1 elseif n>=1 then expected=0
                else
                    local t=(n-core)/(1-core)
                    expected=1-t*t*t*(t*(t*6-15)+10)
                end
                local actual=result:get(x,y)
                local difference=math.abs(actual-expected*W)
                report.max_error_units=math.max(report.max_error_units,difference)
                if actual<0 or actual>W or actual~=math.floor(actual) or difference>76 then
                    issue('polynomial/core U24 allowance exceeded at '..tostring(core)..'/'..x..'/'..y)
                    return
                end
                report.checks=report.checks+1
            end end
        end)
        if not ok then issue(why)end
        for i=#owned,1,-1 do
            local freed,err=pcall(owned[i].free,owned[i])
            if not freed then issue('polynomial cleanup: '..tostring(err))end
        end
        if #report.issues>0 then break end
    end
    report.expected_checks=12*257*24
    if report.checks~=report.expected_checks then issue('incomplete polynomial census')end
    report.status=#report.issues==0 and 'pass' or 'fail'
    return report
end

-- Production indexed confirmation vs the accepted live rolling predicate.
local f=assert(io.open(arg[1] or 'Code/sbm_terrain_copy.lua','r'))
local source=f:read('*a');f:close()
local a=assert(source:find('local function RefineIndexedHeightStep(',1,true),
    'production indexed refinement missing')
local b=assert(source:find('-- INDEXED_HEIGHT_REFINE_END',a,true))
local indexed=assert(load(source:sub(a,b-1)..'\nreturn RefineIndexedHeightStep'))()
local old=assert(io.popen('git show ee25640:Code/sbm_terrain_copy.lua','r'))
local baseline=old:read('*a');assert(old:close())
a=assert(baseline:find('\tlocal function refine_step(',1,true))
b=assert(baseline:find('\tlocal function validate_sampled_track(',a,true))
local env=setmetatable({wide_ring_only=false,threshold=128},{__index=_G})
local rolling=assert(load(baseline:sub(a,b-1)..'\nreturn refine_step','accepted refinement','t',env))()
local checks=0
local function check(ok,why) assert(ok,why);checks=checks+1 end
local seed=91371
local function random(n) seed=(seed*48271)%2147483647;return seed%n end
for trial=1,1024 do
    local values={}
    local step,sign=8+random(45),random(2)*2-1
    for p=0,63 do
        local v=10000+p*(trial%11)+(p>=step and sign*1000 or 0)
        if trial%3==0 then v=v+random(2001)-1000 end
        if trial%7==0 then v=random(65536) end
        if trial%13~=0 or p%17~=0 then values[p]=v end
    end
    -- Literal all-width native superset: no directional or winner decisions here.
    local candidates={}
    for p=1,61 do
        for width=1,3 do
            local v0,x,y,v3=values[p-1],values[p],values[p+width],values[p+width+1]
            if v0 and x and y and v3 then
                local jump=math.abs(y-x)
                if jump>=128 and jump>=2*math.max(math.abs(x-v0),math.abs(v3-y),1) then
                    candidates[#candidates+1]=p;break
                end
            end
        end
    end
    for _,edge in ipairs({'left','right','top','bottom'}) do
        local axis=(edge=='left' or edge=='right') and 'x' or 'y'
        for _,low in ipairs({false,true}) do
            local track={axis=axis,edge=edge,perp_n=64,low_before=low}
            for predicted=1,61,3 do
                local seen={}
                env.at=function(actual,p,along)
                    check(actual==axis and along==19,'axis/along changed')
                    return values[p]
                end
                local rp,rw=rolling(track,19,predicted)
                local function at(actual,p,along)
                    check(not seen[p],'indexed sample read twice')
                    check(actual==axis and along==19,'indexed coordinates changed')
                    seen[p]=true;return values[p]
                end
                local ip,iw=indexed(at,track,19,predicted,math.max(1,predicted-6),
                    math.min(61,predicted+6),3,128,candidates)
                check(ip==rp and iw==rw,'indexed winner/width/tie differs')
            end
        end
    end
end
local reads=0
local p,w=indexed(function() reads=reads+1 end,{axis='x',edge='left'},0,10,4,16,3,128,{})
check(p==nil and w==nil and reads==0,'certified empty row must avoid native reads')
check(source:find('refinement_guide.RegisterWrite(selected.axis, row.along,',1,true)~=nil,
    'track writes not invalidating native discovery guide')
print('indexed refinement: '..checks..' checks passed')

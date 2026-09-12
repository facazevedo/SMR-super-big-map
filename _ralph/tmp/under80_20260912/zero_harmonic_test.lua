-- Actual predecessor/candidate cell expressions; one cache lifetime per patch.
local f=assert(io.open('Code/sbm_terrain_copy.lua','r'))
local previous=f:read('*a');f:close()
f=assert(io.open('_ralph/runs/under80-20260912/artifacts/zero_harmonic_research/terrain_candidate.lua','r'))
local current=f:read('*a');f:close()
local function body(source)
    local start=assert(source:find('local function apply_native_patch',1,true))
    start=assert(source:find('local dx, dy = x - patch.cx, y - patch.cy',start,true))
    local finish=assert(source:find('coarse:set(coarse_x, coarse_y,',start,true))
    return source:sub(start,finish-1)..' return math.floor(weight * native_weight_scale + 0.5)'
end
local prefix_start=assert(current:find('local cached_zero_sine, cached_zero_harmonic',1,true))
local prefix_end=assert(current:find('for coarse_y',prefix_start,true))
local prefix=current:sub(prefix_start,prefix_end-1)
local function protection(distance,radius,transition)
    if distance<=radius then return 0 end
    if transition<=0 or distance>=radius+transition then return 1 end
    local t=(distance-radius)/(transition+0.0)
    return t*t*t*(t*(t*6-15)+10)
end
local counts={old=0,new=0}
local function compile(source,label,preamble)
    local library={};for key,value in pairs(math) do library[key]=value end
    local env=setmetatable({math=library,ProtectedTerrainBlendWeight=protection,
        native_weight_scale=4096,maximum_width_scale=1.35},{__index=_G})
    local function bind(offset)
        library.sin=function(value) counts[label]=counts[label]+1;return math.sin(value)+(offset or 0) end
    end
    bind(0)
    local factory=assert(load('return function()\n'..preamble..'\nreturn function()\n'
        ..body(source)..'\nend end','coarse cache '..label,'t',env))()
    return factory,env,bind
end
local old_factory,a,bind_old=compile(previous,'old','')
local new_factory,b,bind_new=compile(current,'new',prefix)
local checks=0
local function check(ok,why) assert(ok,why);checks=checks+1 end
for _,has_atan2 in ipairs({false,true}) do
    a.math.atan2=has_atan2 and (math.atan2 or math.atan) or nil
    b.math.atan2=a.math.atan2
    local before_old,before_new=counts.old,counts.new
    for case=1,36 do
        local core=({0,1,30,110})[(case-1)%4+1]+0.0
        local transition=({20,60,360})[(case-1)%3+1]+0.0
        local phase=case%2==0 and case%7 or case*0.1745
        local patch={cx=17.13,cy=-26.97,core_cells=core,phase=phase,
            relief_x=math.cos(phase),relief_y=math.sin(phase)}
        local radius=core+transition*1.35
        local guards=case%3==0 and {{cx=0,cy=0,radius=40,transition=0}}
            or case%3==1 and {{cx=-45,cy=26,radius=20,transition=60},{cx=65,cy=-40,radius=80,transition=10}}
            or {}
        for _,env in ipairs({a,b}) do
            env.patch=patch;env.radius=radius;env.base_transition=transition
            env.transition_irregularity=case%2==0 and 0.45 or 0.38
            env.protection_blends=guards
        end
        local old,new=old_factory(),new_factory()
        for iy=-16,16 do for ix=-16,16 do
            a.x=patch.cx+ix*radius/14;a.y=patch.cy+iy*radius/14;b.x=a.x;b.y=a.y
            check(old()==new(),'coarse mask changed')
        end end
        for angle=0,330,30 do for _,r in ipairs({0,core,radius}) do
            for _,epsilon in ipairs({-1e-9,0,1e-9}) do
                a.x=patch.cx+(r+epsilon)*math.cos(angle*math.pi/180)
                a.y=patch.cy+(r+epsilon)*math.sin(angle*math.pi/180);b.x=a.x;b.y=a.y
                check(old()==new(),'coarse mask boundary changed')
            end
        end end
        a.math.atan2=nil;b.math.atan2=nil
        a.x=patch.cx+core+transition*0.5;a.y=patch.cy;b.x=a.x;b.y=a.y
        for _,offset in ipairs({0,0.003,0,-0.005,0}) do
            bind_old(offset);bind_new(offset)
            check(old()==new(),'sine rebinding reused stale value')
            check(old()==new(),'rebound cache differs')
        end
        a.math.atan2=has_atan2 and (math.atan2 or math.atan) or nil;b.math.atan2=a.math.atan2
    end
    local old_calls,new_calls=counts.old-before_old,counts.new-before_new
    if not has_atan2 then check(new_calls<old_calls/20,'zero-angle trig calls were not eliminated') end
    print('atan2 '..tostring(has_atan2)..': sine calls '..old_calls..' -> '..new_calls)
end
print('zero harmonic: '..checks..' exact coarse/domain/lifetime checks passed')

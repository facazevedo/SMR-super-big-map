-- Private prototype: exact scalar fixtures and allocation/residual/census failures.
local native=dofile('_ralph/tmp/under80_20260912/native_outer_mask.lua')
local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local source=read('Code/sbm_terrain_copy.lua'):gsub('\r\n','\n')
local first=assert(source:find('local function apply_native_patch',1,true))
first=assert(source:find('local dx, dy = x - patch.cx, y - patch.cy',first,true))
local last=assert(source:find('coarse:set(coarse_x, coarse_y,',first,true))
local body=source:sub(first,last-1)..' return math.floor(weight * native_weight_scale + 0.5)'
local protection=assert(source:match('(local function ProtectedTerrainBlendWeight.-\nend)'))
local checks=0
local function check(ok,why)assert(ok,why);checks=checks+1 end
local function fixture(transition)
    return {width=37,height=39,sample_step=1,x0=0,y0=0,radius=15.5,base_transition=10,
        irregularity=0,atan2_present=false,cached_zero_harmonic=0,
        patch={cx=18,cy=19,core_cells=2,relief_x=1,relief_y=0,phase=0},
        guards=transition and {{cx=27,cy=19,radius=3,transition=transition}} or {}}
end
local function scalar(row,fail)
    local m={};for k,v in pairs(math)do m[k]=v end;m.atan2=nil
    local env=setmetatable({math=m,patch=row.patch,protection_blends=row.guards,
        radius=row.radius,base_transition=row.base_transition,transition_irregularity=row.irregularity,
        native_weight_scale=4096,maximum_width_scale=1.35},{__index=_G})
    env.ProtectedTerrainBlendWeight=assert(load(protection..'\nreturn ProtectedTerrainBlendWeight','protect','t',env))()
    local cell=assert(load('local cached_zero_sine,cached_zero_harmonic\n'..body,'cell','t',env))
    return function(x,y)
        if fail then error('injected scalar error')end
        env.x,env.y=row.x0+x*row.sample_step,row.y0+y*row.sample_step
        return cell()
    end
end
local function api_for(mode,fail_at)
    local api=dofile('_ralph/tools/parity/native_grid_double.lua')
    local owned,seen,allocations={}, {},0
    local function register(g)
        if not seen[g]then seen[g]=true;owned[#owned+1]=g end
        local old=g.clone
        g.clone=function(self)
            allocations=allocations+1
            if mode=='allocation' and allocations==fail_at then return nil end
            return register(old(self))
        end
        return g
    end
    local new=api.NewComputeGrid
    api.NewComputeGrid=function(...)
        allocations=allocations+1
        if mode=='allocation' and allocations==fail_at then return nil end
        return register(new(...))
    end
    function api.GridMask(input,output,lo,hi)
        local w,h=input:size()
        for y=0,h-1 do for x=0,w-1 do
            local v=input:get(x,y);output:set(x,y,v>lo and v<=hi and 1 or 0)
        end end
    end
    local pow=api.GridPow
    api.GridPow=function(g,m,d)
        pow(g,m,d)
        if (mode=='root' or mode=='huge_root') and m==1 and d==2
            or mode=='reciprocal' and m==-1 then
            api.GridMulDivAdd(g,mode=='huge_root' and 1000 or 2,1,0)
        elseif mode=='nan_root' and m==1 and d==2 then g.values[0]=0/0 end
    end
    local each=api.GridForeach
    api.GridForeach=function(g,fn,lo,hi)
        if mode=='census' then return end
        if mode=='duplicate' then
            return each(g,function(v,x,y)fn(v,x,y);fn(v,x,y)end,lo,hi)
        end
        if mode=='coordinate' then return each(g,function(v,x,y)fn(v,-1,y)end,lo,hi)end
        return each(g,fn,lo,hi)
    end
    return api,owned,function()return allocations end
end
for _,transition in ipairs({false,0,.38,20})do
    local row=fixture(transition)
    local api,owned=api_for()
    local literal=scalar(row)
    local output,stats,why=native(api,row,literal)
    check(output~=nil,tostring(why))
    check(stats.derived_numerator>=2,'rounded-down integer error budget')
    for y=0,row.height-1 do for x=0,row.width-1 do
        check(output:get(x,y)==literal(x,y),'fixture mask differs')
    end end
    output:free()
    for _,g in ipairs(owned)do check(g.freed,'normal allocation leak')end
end
local row=fixture(.38)
local api,owned,count=api_for()
local output,stats=native(api,row,scalar(row))
check(output~=nil,'allocation census fixture');output:free()
local total=count()
for failed=1,total do
    local api,owned=api_for('allocation',failed)
    local output,_,why=native(api,row,scalar(row))
    check(output==nil and why~=nil,'allocation failure accepted')
    for _,g in ipairs(owned)do check(g.freed,'failed allocation leak')end
end
for _,mode in ipairs({'root','huge_root','reciprocal','nan_root','census','duplicate','coordinate','scalar'})do
    local api,owned=api_for(mode)
    local output,_,why=native(api,row,scalar(row,mode=='scalar'))
    check(output==nil and why~=nil,'failure accepted: '..mode)
    for _,g in ipairs(owned)do check(g.freed,'failure leaked: '..mode)end
end
local api,owned=api_for()
local row=fixture();row.patch.cx=.5
local output,_,why=native(api,row,scalar(row))
check(output==nil and why~=nil and #owned==0,'unsupported domain allocated/published')
-- Engine-style logging-only error() must not be used as control flow.
local api,owned=api_for('huge_root')
local original_error,logged=error,0
_G.error=function()logged=logged+1 end
local output,_,why=native(api,fixture(),scalar(fixture()))
_G.error=original_error
check(output==nil and why~=nil and logged==0,'rejection depends on throwing error()')
for _,g in ipairs(owned)do check(g.freed,'logging-only error cleanup leak')end
-- Proof-domain regressions: every refusal must precede allocation.
for _,case in ipairs({'huge_coordinates','wrong_radius','small_budget','wrong_harmonic'}) do
    local row=fixture()
    local epsilon
    if case=='huge_coordinates' then row.x0=1e20;row.y0=1e20;row.patch.cx=1e20;row.patch.cy=1e20
    elseif case=='wrong_radius' then row.radius=1
    elseif case=='small_budget' then epsilon=1
    elseif case=='wrong_harmonic' then row.cached_zero_harmonic=.5 end
    local api,owned=api_for()
    local output,_,why=native(api,row,scalar(row),epsilon)
    if output then output:free() end
    check(output==nil and why~=nil and #owned==0,'unqualified input accepted/allocated: '..case)
end
print('PASS private native outer mask: '..checks..' exact/failure checks; '..total..' allocation failure points')

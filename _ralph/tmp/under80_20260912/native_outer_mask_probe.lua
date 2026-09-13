-- Scratch-only native test of the unproved mask prototype on all captured patches.
local result={status='running',calls={},samples=0,corrected=0,kernel_ms=0}
rawset(_G,'SBM_NATIVE_STEP_CERT_PROBE',result)
local root='D:/PROJS/SMR/super-big-map/'
local data=root..'_ralph/runs/under80-20260912/artifacts/outer_mask_world_coordinate_study_reference/'
local function fail(why) result.status='fail';result.error=tostring(why);error(result.error) end
local function read(path)
    local err,text=AsyncFileToString(path)
    if err or type(text)~='string' then fail('read failed: '..path..' '..tostring(err));return nil end
    return text
end
local geometry_source=read(data..'geometry.lua');if not geometry_source then return end
local geometry_chunk,why=load(geometry_source,'@outer-geometry','t',_G)
if not geometry_chunk then fail(why);return end
local rows=geometry_chunk()
local prototype_source=read(root..'_ralph/tmp/under80_20260912/native_outer_mask.lua')
if not prototype_source then return end
local prototype_chunk,why=load(prototype_source,'@native-outer-mask-research','t',_G)
if not prototype_chunk then fail(why);return end
local native=prototype_chunk()
local source=read(root..'Code/sbm_terrain_copy.lua');if not source then return end
source=source:gsub('\r\n','\n')
local first=source:find('local function apply_native_patch',1,true)
first=first and source:find('local dx, dy = x - patch.cx, y - patch.cy',first,true)
local last=first and source:find('coarse:set(coarse_x, coarse_y,',first,true)
local protection=source:match('(local function ProtectedTerrainBlendWeight.-\nend)')
if not first or not last or not protection then fail('scalar source boundaries');return end
local body=source:sub(first,last-1)..' return math.floor(weight * native_weight_scale + 0.5)'
local m={};for key,value in pairs(math) do m[key]=value end
m.atan2=nil
local env=setmetatable({math=m,native_weight_scale=4096,maximum_width_scale=1.35},{__index=_G})
local pc,why=load(protection..'\nreturn ProtectedTerrainBlendWeight','@actual-protection','t',env)
if not pc then fail(why);return end
env.ProtectedTerrainBlendWeight=pc()
local api={}
for _,name in ipairs({'NewComputeGrid','GridMulDivAdd','GridAdd','GridAddMulDiv',
    'GridPow','GridAbs','GridMask','GridClamp','GridRound','GridCount','GridForeach','point','box'}) do
    api[name]=rawget(_G,name)
    if type(api[name])~='function' then fail('missing native '..name);return end
end
local paused=type(PauseInfiniteLoopDetection)=='function'
if paused then PauseInfiniteLoopDetection('NativeOuterMaskScratch') end
local ok,err=pcall(function()
    for index,row in ipairs(rows) do
        if row.atan2_present then fail('captured atan2 domain changed');return end
        env.patch,env.protection_blends=row.patch,row.guards
        env.radius,env.base_transition=row.radius,row.base_transition
        env.transition_irregularity=row.irregularity
        local scalar_chunk,why=load('local cached_zero_sine,cached_zero_harmonic\n'..body,
            '@actual-mask-cell','t',env)
        if not scalar_chunk then fail(why);return end
        local function scalar(cx,cy)
            env.x,env.y=row.x0+cx*row.sample_step,row.y0+cy*row.sample_step
            return scalar_chunk()
        end
        local before=GetPreciseTicks()
        local grid,stats,problem=native(api,row,scalar)
        local elapsed=GetPreciseTicks()-before
        if not grid then fail('patch '..index..': '..tostring(problem));return end
        local entry={patch=index,guards=#row.guards,kernel_ms=elapsed,stats=stats,checked=0}
        result.calls[#result.calls+1]=entry
        local bytes=read(data..string.format('patch_%03d_scalar.u16',index))
        if not bytes or #bytes~=row.width*row.height*2 then
            grid:free();fail('scalar byte census '..index);return
        end
        for cy=0,row.height-1 do for cx=0,row.width-1 do
            local at=2*(cy*row.width+cx)+1
            local expected=string.byte(bytes,at)+256*string.byte(bytes,at+1)
            local actual=scalar(cx,cy)
            local value=grid:get(cx,cy)
            if actual~=expected or value~=expected then
                entry.first_difference={x=cx,y=cy,expected=expected,native=value,scalar=actual}
                grid:free();fail('native or source mask mismatch patch '..index);return
            end
            entry.checked=entry.checked+1
        end end
        grid:free()
        result.samples=result.samples+entry.checked
        result.corrected=result.corrected+stats.corrected
        result.kernel_ms=result.kernel_ms+elapsed
        print('NATIVE_OUTER_MASK_PATCH '..index..' checked='..entry.checked..' corrected='..stats.corrected..' kernel_ms='..elapsed)
    end
end)
if paused and type(ResumeInfiniteLoopDetection)=='function' then ResumeInfiniteLoopDetection('NativeOuterMaskScratch') end
if not ok then fail(err);return end
if result.error then return end
if result.samples~=948237 or #result.calls~=#rows then fail('incomplete native scratch census');return end
result.status='pass'
result.certificate_proved=false
return 'NATIVE_OUTER_MASK_SCRATCH_PASS'

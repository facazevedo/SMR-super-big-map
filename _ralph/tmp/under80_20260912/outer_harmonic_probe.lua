-- Fresh scratch engine probe; no production hooks or terrain installation.
local result={status='running',checks=0,max_error_scaled=0,cases={}}
rawset(_G,'SBM_NATIVE_STEP_CERT_PROBE',result)
local owned={}
local function own(g) owned[#owned+1]=g;return g end
local function free_all() for i=#owned,1,-1 do owned[i]:free();owned[i]=nil end end
PauseInfiniteLoopDetection('SBMOuterHarmonicProbe')
local ok,why=pcall(function()
    local env,sbm
    for _,mod in ipairs(ModsLoaded or {}) do
        local value=mod.env and rawget(mod.env,'SuperBigMap')
        if value and value.Config then env,sbm=mod.env,value;break end
    end
    if not sbm or type(math.atan2)~='function' then error('required mod/atan2 unavailable') end
    local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/tmp/under80_20260912/outer_harmonic_research.lua')
    if err or not source then error(tostring(err)) end
    local fn,compile_error=load(source,'@outer-harmonic','t',env)
    if not fn then error(tostring(compile_error)) end
    local native=fn()
    local api={}
    for _,name in ipairs({'NewComputeGrid','GridMulDivAdd','GridAddMulDiv','GridAdd'}) do
        api[name]=sbm.Engine.Global(name)
    end
    local phases={0,1,2,3,4,5,6,0.52325,1.047,2.094,3.1415,4.189,5.236,6.282}
    local S,output_scale=8388608,4194304
    for _,phase in ipairs(phases) do
        local u,v=own(api.NewComputeGrid(721,1,'f',32)),own(api.NewComputeGrid(721,1,'f',32))
        local coordinates={}
        for i=0,720 do
            local angle=(i-360)*math.pi/360
            local x,y=math.cos(angle),math.sin(angle)
            if i%180==0 then
                x=({-1,0,1,0,-1})[i/180+1]
                y=({0,-1,0,1,0})[i/180+1]
            end
            coordinates[i]={x,y}
            u:set(i,0,math.floor(x*S+0.5)+S)
            v:set(i,0,math.floor(y*S+0.5)+S)
        end
        api.GridMulDivAdd(u,1,1,-S);api.GridMulDivAdd(u,1,S,0)
        api.GridMulDivAdd(v,1,1,-S);api.GridMulDivAdd(v,1,S,0)
        local started=GetPreciseTicks()
        local grid=native(api,own,u,v,phase)
        local native_ms=GetPreciseTicks()-started
        api.GridMulDivAdd(grid,output_scale,1,2*output_scale)
        local max_error=0
        for i=0,720 do
            local xy=coordinates[i]
            local angle=math.atan2(xy[2],xy[1])
            local expected=0.52*math.sin(3*angle+phase)
                +0.30*math.sin(5*angle-phase*1.37)+0.18*math.sin(7*angle+phase*0.73)
            local actual=grid:get(i,0)-2*output_scale
            local error=math.ceil(math.abs(actual-expected*output_scale))
            max_error=math.max(max_error,error)
            result.checks=result.checks+1
        end
        result.max_error_scaled=math.max(result.max_error_scaled,max_error)
        result.cases[#result.cases+1]={phase=phase,max_error_scaled=max_error,native_ms=native_ms}
        free_all()
    end
    result.output_scale=output_scale
end)
free_all()
ResumeInfiniteLoopDetection('SBMOuterHarmonicProbe')
result.status,result.error=ok and 'pass' or 'fail',ok and '' or tostring(why)
print('SBM_OUTER_HARMONIC_PROBE',result.status,result.checks,result.max_error_scaled,result.error)

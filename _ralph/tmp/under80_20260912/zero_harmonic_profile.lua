-- Install only the candidate outer helper in this fresh diagnostic process.
-- No production/deployed file is changed. Full predecessor outputs are captured.
local result={status='setup',calls={}}
rawset(_G,'SBM_ZERO_HARMONIC_DIAGNOSTIC',result)
local env,sbm
for _,mod in ipairs(ModsLoaded or {}) do
    local value=mod.env and rawget(mod.env,'SuperBigMap')
    if value and value.Config then env,sbm=mod.env,value;break end
end
if not sbm then result.status='fail';error('zero harmonic: mod missing');return end
local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/runs/under80-20260912/artifacts/zero_harmonic_research/terrain_candidate.lua')
if err or not source then result.status='fail';error('zero harmonic: source missing');return end
local fn,compile_error=load(source,'@zero-harmonic-candidate','t',env)
if not fn then result.status='fail';error(tostring(compile_error));return end
local original=sbm.TerrainCopy
fn()
local candidate=sbm.TerrainCopy.PrepareOuterResourceTerrain
sbm.TerrainCopy=original
if type(candidate)~='function' then result.status='fail';error('zero harmonic: helper missing');return end
local function pack(...) return {n=select('#',...),...} end
local unpack_values=table.unpack or unpack
original.PrepareOuterResourceTerrain=function(...)
    local started=GetPreciseTicks()
    local values=pack(candidate(...))
    result.calls[#result.calls+1]={elapsed_ms=GetPreciseTicks()-started,
        first_return=tostring(values[1]),atan2_present=type(env.math.atan2)=='function'}
    result.status='pass'
    return unpack_values(values,1,values.n)
end
-- Profile the separate relief-capture hotspot; this run is diagnostic, not a
-- cold timing sample. Capture is dynamically reached through a named upvalue.
local function upvalue(fn,wanted)
    for i=1,200 do
        local name,value=debug.getupvalue(fn,i)
        if not name then break end
        if name==wanted then return value,i end
    end
end
local generate=upvalue(sbm.State.generator_do_generate_wrapper,'GenerateOnTemporaryVanillaBacking')
local annotate,index
if generate then annotate,index=upvalue(generate,'AnnotateDecorRelief') end
if not annotate or not index or type(FunctionProfilerStart)~='function' then
    result.status='fail';error('zero harmonic: relief profiler hook unavailable');return
end
local captures=0
local wrapper=function(...)
    captures=captures+1
    config.FunctionProfilter_CallStackFile='__PROFILE_OUTPUT__/function_relief_'..captures..'.json'
    FunctionProfilerStart()
    local values=pack(annotate(...))
    FunctionProfilerStop('__PROFILE_OUTPUT__/function_relief_'..captures..'.txt',true)
    return unpack_values(values,1,values.n)
end
if debug.setupvalue(generate,index,wrapper)~='AnnotateDecorRelief' then
    result.status='fail';error('zero harmonic: relief profiler install failed');return
end
sbm.Config.DEBUG_LOGGING_ENABLED=true
sbm.Config.DEBUG_LOADING_TIMINGS=true
result.status='ready'
return 'ZERO_HARMONIC_READY'

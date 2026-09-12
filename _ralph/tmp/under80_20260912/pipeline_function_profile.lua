-- Diagnostic only: profile the entire pre-T1 surface work, not an acceptance
-- timing sample. Stop only after the required scheduled revalidation finishes.
local result={status='setup',calls={}}
rawset(_G,'SBM_PIPELINE_FUNCTION_DIAGNOSTIC',result)
local sbm
for _,mod in ipairs(ModsLoaded or {}) do
    local value=mod.env and rawget(mod.env,'SuperBigMap')
    if value and value.Config then sbm=value;break end
end
if not sbm or type(FunctionProfilerStart)~='function' or type(FunctionProfilerStop)~='function' then
    result.status='fail';error('pipeline profiler unavailable');return
end
local original=sbm.GenerationGrids.RebuildFinal
if type(original)~='function' then result.status='fail';error('revalidation hook unavailable');return end
local function pack(...) return {n=select('#',...),...} end
local unpack_values=table.unpack or unpack
local active=true
sbm.GenerationGrids.RebuildFinal=function(map,stage,...)
    local values=pack(original(map,stage,...))
    if active and map and map.mapdata and map.mapdata.Environment=='Surface'
        and stage=='post-pipeline scheduled revalidation' then
        active=false
        FunctionProfilerStop('__PROFILE_OUTPUT__/function_pipeline.txt',true)
        result.calls[#result.calls+1]={stopped_after=stage,
            map_environment=map.mapdata.Environment,first_return=tostring(values[1])}
        result.status='pass'
        sbm.GenerationGrids.RebuildFinal=original
    end
    return unpack_values(values,1,values.n)
end
config.FunctionProfilter_CallStackFile='__PROFILE_OUTPUT__/function_pipeline.json'
sbm.Config.DEBUG_LOGGING_ENABLED=true
sbm.Config.DEBUG_LOADING_TIMINGS=true
result.status='profiling'
FunctionProfilerStart()
return 'PIPELINE_FUNCTION_PROFILER_READY'

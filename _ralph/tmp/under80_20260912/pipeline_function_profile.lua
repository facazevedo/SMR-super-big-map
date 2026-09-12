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
local start_profiler,stop_profiler=FunctionProfilerStart,FunctionProfilerStop
result.intercepted_starts=0;result.intercepted_stops=0
-- GridProc.Run unconditionally stops/dumps the global profiler, including the
-- pregame procedure. Suppress only these profiling controls in this owned
-- diagnostic process; keep the original game procedures and all RNG untouched.
rawset(_G,'FunctionProfilerStart',function()result.intercepted_starts=result.intercepted_starts+1 end)
rawset(_G,'FunctionProfilerStop',function()result.intercepted_stops=result.intercepted_stops+1 end)
sbm.GenerationGrids.RebuildFinal=function(map,stage,...)
    local values=pack(original(map,stage,...))
    if active and map and map.mapdata and map.mapdata.Environment=='Surface'
        and stage=='post-pipeline scheduled revalidation' then
        active=false
        stop_profiler('__PROFILE_OUTPUT__/function_pipeline.txt',true)
        rawset(_G,'FunctionProfilerStart',start_profiler)
        rawset(_G,'FunctionProfilerStop',stop_profiler)
        local err,report=AsyncFileToString('__PROFILE_OUTPUT__/function_pipeline.txt')
        local complete=not err and type(report)=='string'
            and report:find('Total Calls:',1,true)
            and report:find('sbm_terrain_copy.lua',1,true)
            and report:find('sbm_map_generation.lua',1,true)
        result.calls[#result.calls+1]={stopped_after=stage,
            map_environment=map.mapdata.Environment,first_return=tostring(values[1]),
            complete_function_report=complete and true or false,report_bytes=report and #report or 0}
        result.status=complete and 'pass' or 'fail'
        sbm.GenerationGrids.RebuildFinal=original
    end
    return unpack_values(values,1,values.n)
end
config.FunctionProfilter_CallStackFile='__PROFILE_OUTPUT__/function_pipeline.json'
sbm.Config.DEBUG_LOGGING_ENABLED=true
sbm.Config.DEBUG_LOADING_TIMINGS=true
result.status='profiling'
start_profiler()
return 'PIPELINE_FUNCTION_PROFILER_READY'

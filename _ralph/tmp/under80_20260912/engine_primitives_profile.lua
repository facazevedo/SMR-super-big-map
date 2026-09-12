-- Fresh-process diagnostic: snapshot only immutable Lua call/type primitives in
-- the engine helper chunk. Game function lookups and the mod sandbox stay live.
local result={status='setup',calls={}}
rawset(_G,'SBM_ENGINE_PRIMITIVES_DIAGNOSTIC',result)
local env,sbm
for _,mod in ipairs(ModsLoaded or {}) do
    local value=mod.env and rawget(mod.env,'SuperBigMap')
    if value and value.Config then env,sbm=mod.env,value;break end
end
if not sbm then result.status='fail';error('engine primitives: mod missing');return end
local function environment_index(fn)
    for i=1,200 do
        local name,value=debug.getupvalue(fn,i)
        if not name then break end
        if name=='_ENV' then return i,value end
    end
end
local index,engine_env=environment_index(sbm.Engine.Global)
local terrain_index=environment_index(sbm.TerrainCopy.PrepareOuterResourceTerrain)
local safe_index=environment_index(sbm.Engine.SafeCall)
if not index or engine_env~=env or not terrain_index or not safe_index
    or debug.upvalueid(sbm.Engine.Global,index)==debug.upvalueid(sbm.TerrainCopy.PrepareOuterResourceTerrain,terrain_index)
    or debug.upvalueid(sbm.Engine.Global,index)~=debug.upvalueid(sbm.Engine.SafeCall,safe_index) then
    result.status='fail';error('engine primitives: module environment isolation failed');return
end
local proxy=setmetatable({type=env.type,pcall=env.pcall},{__index=env,__newindex=env})
if debug.setupvalue(sbm.Engine.Global,index,proxy)~='_ENV' then
    result.status='fail';error('engine primitives: install failed');return
end
result.calls={{scope='engine helper module only',game_function_lookups='unchanged',
    primitive_names='type,pcall',diagnostic_proxy_not_production=true}}
result.status='pass'
sbm.Config.DEBUG_LOGGING_ENABLED=true
sbm.Config.DEBUG_LOADING_TIMINGS=true
return 'ENGINE_PRIMITIVES_READY'

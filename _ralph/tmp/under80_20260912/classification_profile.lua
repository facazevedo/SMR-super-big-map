-- Fresh diagnostic only. Recompile the changed annotation with its ORIGINAL
-- private upvalue cells, so later placement consumes the same captured tables.
local result={status='setup',calls={}}
rawset(_G,'SBM_CLASSIFICATION_DIAGNOSTIC',result)
local env,sbm
for _,mod in ipairs(ModsLoaded or {}) do
    local value=mod.env and rawget(mod.env,'SuperBigMap')
    if value and value.Config then env,sbm=mod.env,value;break end
end
local function fail(reason)result.status='fail';error('classification: '..reason)end
if not sbm or type(debug.upvaluejoin)~='function' then fail('mod/upvalue API missing');return end
local function upvalue(fn,wanted)
    if type(fn)~='function' then return end
    for i=1,200 do
        local name,value=debug.getupvalue(fn,i)
        if not name then break end
        if name==wanted then return value,i end
    end
end
local original=sbm.TerrainCopy.AnnotateDecorRelief
local generate=upvalue(sbm.MapGeneration.PatchRandomMapGenerator,'GenerateOnTemporaryVanillaBacking')
local captured,index=upvalue(generate,'AnnotateDecorRelief')
if captured~=original or not index then fail('annotation callsite mismatch');return end
local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/runs/under80-20260912/artifacts/classification_reuse_research/terrain_candidate.lua')
if err or not source then fail('terrain candidate missing');return end
source=source:gsub('\r\n','\n')
local first=source:find('local function AnnotateDecorRelief(',1,true)
local last=first and source:find('local function ClearDecorRelief(',first,true)
if not first or not last then fail('annotation anchors missing');return end
local names,values,indices={},{},{}
for i=1,200 do
    local name,value=debug.getupvalue(original,i)
    if not name then break end
    indices[name]=i
    if name~='_ENV' then names[#names+1]=name;values[#names]=value end
end
local prefix='local '..table.concat(names,',')..' = ...\n'
local fn,why=load(prefix..source:sub(first,last-1)..'\nreturn AnnotateDecorRelief',
    '@classification-annotation','t',env)
if not fn then fail(tostring(why));return end
local unpack_values=table.unpack or unpack
local candidate=fn(unpack_values(values,1,#names))
local joined=0
for i=1,200 do
    local name=debug.getupvalue(candidate,i)
    if not name then break end
    if not indices[name] then fail('unexpected upvalue '..name);return end
    debug.upvaluejoin(candidate,i,original,indices[name]);joined=joined+1
end
err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/runs/under80-20260912/artifacts/classification_reuse_research/rock_candidate.lua')
if err or not source then fail('rock candidate missing');return end
fn,why=load(source,'@classification-rock','t',env)
if not fn then fail(tostring(why));return end
-- No maps/captures exist yet; all production grounding consumers read this API
-- dynamically. Load its complete context-owning module, not a partial helper.
fn()
local function pack(...)return {n=select('#',...),...}end
local wrapper=function(map,...)
    local started=GetPreciseTicks()
    local values=pack(candidate(map,...))
    local failures=map.SuperBigMapRockGroundingStats and map.SuperBigMapRockGroundingStats.failures
    result.calls[#result.calls+1]={elapsed_ms=GetPreciseTicks()-started,
        environment=map.mapdata and map.mapdata.Environment,joined_upvalues=joined,
        failures=failures or 0,first_return=tostring(values[1])}
    if failures and failures>0 then result.status='fail'
    elseif result.status~='fail' then result.status='pass' end
    return unpack_values(values,1,values.n)
end
if debug.setupvalue(generate,index,wrapper)~='AnnotateDecorRelief' then fail('callsite install failed');return end
sbm.TerrainCopy.AnnotateDecorRelief=wrapper
sbm.Config.DEBUG_LOGGING_ENABLED=true
sbm.Config.DEBUG_LOADING_TIMINGS=true
result.status='ready'
return 'CLASSIFICATION_REUSE_READY'

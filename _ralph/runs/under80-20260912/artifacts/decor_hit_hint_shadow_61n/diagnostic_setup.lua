-- Full native old/new predicate comparison; preserve original query results.
local result={status='setup',calls={}}
rawset(_G,'SBM_DECOR_HINT_DIAGNOSTIC',result)
local sbm,env
for _,mod in ipairs(ModsLoaded or {})do
    local value=mod.env and rawget(mod.env,'SuperBigMap')
    if value and value.DecorTopUp then sbm,env=value,mod.env;break end
end
local function fail(why)result.status='fail';result.error=why;error(why)end
if not sbm then fail('decor module missing');return end
local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/tmp/under80_20260912/decor_hit_hint.lua')
if err or type(source)~='string' then fail('research query missing');return end
local chunk,why=load(source,'@research/decor_hit_hint.lua','t',env)
if not chunk then fail(why);return end
local factory=chunk()
local original_run=sbm.DecorTopUp.Run
local original_final=sbm.GenerationGrids.RebuildFinal
local owner,slot,old
for i=1,200 do
    local name,value=debug.getupvalue(original_run,i)
    if not name then break end
    if name=='circle_hits' then owner,slot,old=original_run,i,value;break end
end
if not old then fail('live circle query upvalue missing');return end
local candidate=factory(old)
local current
local function query(list,x,y,radius)
    if not current then return old(list,x,y,radius) end
    local before=GetPreciseTicks()
    local expected=old(list,x,y,radius)
    current.old_ms=current.old_ms+GetPreciseTicks()-before
    before=GetPreciseTicks()
    local actual=candidate(list,x,y,radius)
    current.new_ms=current.new_ms+GetPreciseTicks()-before
    current.queries=current.queries+1
    if expected~=actual then
        current.mismatches=current.mismatches+1
        if not current.first_mismatch then current.first_mismatch={x=x,y=y,radius=radius}end
    end
    current.lists[list]=true
    return expected
end
debug.setupvalue(owner,slot,query)
local function pack(...)return {n=select('#',...),...}end
local unpack_values=table.unpack or unpack
sbm.DecorTopUp.Run=function(map,...)
    local row={environment=map.mapdata.Environment,old_ms=0,new_ms=0,queries=0,mismatches=0,lists={}}
    current=row
    local values=pack(original_run(map,...))
    current=nil
    row.indexes={}
    for list in pairs(row.lists)do
        local cache=list.hit_hint_cache or {}
        local entry={circles=#list,queries=cache.queries,hits=cache.hits,tests=cache.tests,
            index_queries=cache.index_queries,slots=cache.slots}
        row.indexes[#row.indexes+1]=entry
    end
    row.lists=nil
    result.calls[#result.calls+1]=row
    if row.mismatches>0 then fail('native query mismatch')end
    return unpack_values(values,1,values.n)
end
sbm.GenerationGrids.RebuildFinal=function(map,stage,...)
    local values=pack(original_final(map,stage,...))
    if map.mapdata.Environment=='Surface' and stage=='post-pipeline scheduled revalidation' then
        debug.setupvalue(owner,slot,old)
        sbm.DecorTopUp.Run=original_run
        sbm.GenerationGrids.RebuildFinal=original_final
        result.restored=true
        if not result.error and #result.calls>0 then result.status='pass' end
    end
    return unpack_values(values,1,values.n)
end
result.status='ready'
return 'DECOR_HINT_SHADOW_READY'

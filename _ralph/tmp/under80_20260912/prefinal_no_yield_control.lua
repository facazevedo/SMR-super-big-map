-- Diagnostic only: retain EVERY production rebuild and readiness condition.
-- Test whether one explicit yield before the immediate final call is sufficient
-- to settle the aggregate while the original game-time hold remains unchanged.
-- Never interpret a matching aggregate alone as permission to remove a rebuild.
local result={status='setup',calls={},comparisons={}}
rawset(_G,'SBM_PREFINAL_YIELD_DIAGNOSTIC',result)
result.observation_control='no explicit yield'
local sbm
for _,mod in ipairs(ModsLoaded or {}) do
    local value=mod.env and rawget(mod.env,'SuperBigMap')
    if value and value.GenerationGrids then sbm=value;break end
end
local function fail(reason)result.status='fail';result.error=reason;error(reason)end
if not sbm or type(Sleep)~='function' or type(GridWriteStr)~='function'
    or type(xxhash)~='function' or type(terrain)~='table'
    or type(terrain.GetPassGrid)~='function' then fail('yield probe APIs missing');return end
local original=sbm.GenerationGrids.RebuildFinal
if type(original)~='function' then fail('final rebuild missing');return end
local snapshots={}
local function capture(map,label)
    local state={label=label,aggregate=tostring(terrain.HashPassability(map)),
        real_time=RealTime(),game_time=GameTime(),hashes={},suspend_reasons={}}
    local count=terrain.GetPassGridsCount(map)
    if type(count)~='number' or count<1 or count>8 then fail('bad grid count');return end
    local blobs={}
    for index=0,count-1 do
        local grid=terrain.GetPassGrid(map,index)
        local blob,err=GridWriteStr(grid)
        if err or type(blob)~='string' then fail('pass grid serialization failed');return end
        blobs[#blobs+1]=blob
        state.hashes[#state.hashes+1]=tostring(xxhash(blob))
    end
    for reason in pairs(map.SuspendPassEditsReasons or {}) do
        state.suspend_reasons[#state.suspend_reasons+1]=tostring(reason)
    end
    table.sort(state.suspend_reasons)
    snapshots[label]={blobs=blobs,aggregate=state.aggregate}
    result.calls[#result.calls+1]=state
end
local function compare(left,right)
    local a,b=snapshots[left],snapshots[right]
    local same=a and b and #a.blobs==#b.blobs
    if same then for i=1,#a.blobs do if a.blobs[i]~=b.blobs[i] then same=false end end end
    result.comparisons[#result.comparisons+1]={left=left,right=right,
        exact_exposed_grids=same,aggregate_equal=a and b and a.aggregate==b.aggregate}
end
local did_immediate=false
sbm.GenerationGrids.RebuildFinal=function(map,stage,...)
    if map.mapdata.Environment~='Surface' then return original(map,stage,...) end
    if stage=='after last object-grid transaction' then
        if did_immediate then fail('duplicate immediate call');return end
        did_immediate=true
        capture(map,'before_yield')
        -- Matched observation control: no explicit yield.
        capture(map,'after_yield')
        local returned=original(map,stage,...)
        capture(map,'after_immediate')
        compare('before_yield','after_yield')
        compare('after_yield','after_immediate')
        return returned
    elseif stage=='post-pipeline scheduled revalidation' then
        capture(map,'scheduled_entry')
        local returned=original(map,stage,...)
        capture(map,'scheduled_after')
        compare('after_immediate','scheduled_entry')
        compare('scheduled_entry','scheduled_after')
        compare('after_immediate','scheduled_after')
        sbm.GenerationGrids.RebuildFinal=original
        if result.status~='fail' and did_immediate then result.status='pass' end
        return returned
    end
    return original(map,stage,...)
end
result.status='armed'
return 'PREFINAL_YIELD_READY'

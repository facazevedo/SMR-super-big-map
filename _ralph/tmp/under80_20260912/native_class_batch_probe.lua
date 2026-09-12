-- Unrun native API research. Class tables only: no object mutation or map generation.
local result={status='setup',calls={},checks=0,mismatches={}}
rawset(_G,'SBM_NATIVE_STEP_CERT_PROBE',result)
local sbm
for _,mod in ipairs(ModsLoaded or {}) do
    local value=mod.env and rawget(mod.env,'SuperBigMap')
    if value and value.ObjectClone then sbm=value;break end
end
if not sbm or type(IsKindOf)~='function' or type(IsKindOfClasses)~='function'
    or type(g_Classes)~='table' or type(debug.getinfo)~='function' then
    result.status='fail';result.error='native class APIs missing';return
end
result.single_kind=debug.getinfo(IsKindOf,'S').what
result.batch_kind=debug.getinfo(IsKindOfClasses,'S').what
local wanted={mystery_kinds=true,underground_access_clone_kinds=true,skip_clone_kinds=true}
local lists={resources={'SurfaceDepositMarker','SubsurfaceDepositMarker','TerrainDepositMarker'},
    spawned={'Deposit','SubsurfaceAnomaly','SubsurfaceAnomalyMarker','EffectDepositMarker'}}
for _,fn in ipairs({sbm.ObjectClone.IsMysteryRelatedObject,
    sbm.ObjectClone.IsUndergroundAccessObject,sbm.ObjectClone.ShouldSkipObject}) do
    for index=1,200 do
        local name,value=debug.getupvalue(fn,index)
        if not name then break end
        if wanted[name] then lists[name]=value end
    end
end
for name in pairs(wanted) do
    if not lists[name] then result.status='fail';result.error='list missing: '..name;return end
end
local names={}
for name,cls in pairs(g_Classes) do
    if type(name)=='string' and type(cls)=='table' then names[#names+1]=name end
end
table.sort(names)
result.classes=#names
for label,kinds in pairs(lists) do
    local positives,errors=0,0
    for _,name in ipairs(names) do
        local obj=g_Classes[name]
        local expected=false
        for _,kind in ipairs(kinds) do
            local ok,value=pcall(IsKindOf,obj,kind)
            if not ok then errors=errors+1 end
            if ok and value==true then expected=true;break end
        end
        local ok,value=pcall(IsKindOfClasses,obj,kinds)
        if not ok then errors=errors+1 end
        local actual=ok and value==true
        result.checks=result.checks+1
        if actual then positives=positives+1 end
        if actual~=expected and #result.mismatches<20 then
            result.mismatches[#result.mismatches+1]={class=name,list=label,expected=expected,actual=actual}
        end
    end
    result.calls[#result.calls+1]={list=label,kinds=#kinds,positives=positives,errors=errors}
    if errors>0 then result.status='fail' end
end
if result.status~='fail' then result.status=#result.mismatches==0 and 'pass' or 'fail' end
return 'NATIVE_CLASS_LIST_COMPARISON_COMPLETE'

-- Fresh-process diagnostic only. Count the mod's environment fallback lookups;
-- delegate the original sandbox lookup unchanged, including blacklist/errors.
-- Sparse deterministic caller sampling is guidance, NOT exact per-file timing.
local result={status='setup',calls={},keys={},sampled_callers={},sampled_functions={}}
rawset(_G,'SBM_GLOBAL_LOOKUP_DIAGNOSTIC',result)
local env,sbm
for _,mod in ipairs(ModsLoaded or {})do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.GenerationGrids then env,sbm=mod.env,value;break end
end
local function fail(why)result.status='fail';result.error=why;error(why)end
if not sbm then fail('global lookup mod missing');return end
local meta=getmetatable(env) -- root diagnostic only; never exposed to the mod
local original_index=meta and meta.__index
local original_final=sbm.GenerationGrids.RebuildFinal
if type(original_index)~='function' or type(original_final)~='function' then
 fail('global lookup boundaries missing');return
end
local enabled=true
local wrapped_index
wrapped_index=function(target,key)
 if enabled and target==env then
  local count=(result.keys[key] or 0)+1
  result.keys[key]=count
  if count%1024==1 then
   local info=debug.getinfo(2,'S')
   local file=info and info.source or 'unknown'
   local group=result.sampled_callers[file]
   if not group then group={};result.sampled_callers[file]=group end
   group[key]=(group[key] or 0)+1
   local label=file..':'..tostring(info and info.linedefined or -1)
   local fn_group=result.sampled_functions[label]
   if not fn_group then fn_group={};result.sampled_functions[label]=fn_group end
   fn_group[key]=(fn_group[key] or 0)+1
  end
 end
 return original_index(target,key)
end
meta.__index=wrapped_index
local unpack_values=table.unpack or unpack
local function pack(...)return {n=select('#',...),...}end
local function snapshot(stage)
 local row={stage=stage,keys={}}
 for key,count in pairs(result.keys)do row.keys[key]=count end
 result.calls[#result.calls+1]=row
end
sbm.GenerationGrids.RebuildFinal=function(map,stage,...)
 local values=pack(original_final(map,stage,...))
 if map.mapdata.Environment=='Surface' then
  snapshot(stage)
  if stage=='post-pipeline scheduled revalidation' then
   enabled=false
   if meta.__index~=wrapped_index then fail('global lookup hook unexpectedly rebound')
   else
    meta.__index=original_index
    sbm.GenerationGrids.RebuildFinal=original_final
    result.restored=true;result.status='pass'
   end
  end
 end
 return unpack_values(values,1,values.n)
end
-- Verify that forbidden lookup behavior remains unchanged, without granting access.
result.debug_still_blocked=env.debug==nil
if not result.debug_still_blocked then
 enabled=false;meta.__index=original_index;sbm.GenerationGrids.RebuildFinal=original_final
 fail('global lookup changed sandbox behavior');return
end
result.status='ready'
return 'GLOBAL_LOOKUP_PROFILE_READY'

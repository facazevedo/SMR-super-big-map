-- Diagnostic only: inspect the actual nested production owners after cleanup.
local result={status='ready',calls={}}
rawset(_G,'SBM_STARTUP_BUNDLE_DIAGNOSTIC',result)
local sbm
for _,mod in ipairs(ModsLoaded or {})do
 local s=mod.env and rawget(mod.env,'SuperBigMap')
 if s and s.GenerationGrids then sbm=s;break end
end
if not sbm then result.status='fail';return end
local originals,wrappers={},{}
local native_mask,native_and,native_grid=GridMask,GridAnd,IsComputeGrid
local serialize=GridWriteStr
result.mask_boundaries=0;result.and_boundaries=0;result.compared_cells=0
local function equal(a,b)
 local aa,ae=serialize(a);local bb,be=serialize(b)
 if ae or be or type(aa)~='string' or aa~=bb then result.error='native boundary differs' end
 local w,h=a:size();result.compared_cells=result.compared_cells+w*h
end
local function upvalue(fn,wanted)
 for i=1,200 do local name,value=debug.getupvalue(fn,i);if not name then break end
  if name==wanted then return value end
 end
end
result.class_batch_enabled=upvalue(sbm.Engine.FirstKindOf,'native_kind_pair')==true
local match=upvalue(sbm.ObjectClone.ClassScalesWithTerrain,'MatchScaleKeepName')
result.name_cache_enabled=match and upvalue(match,'native_find_ok')==true
for _,name in ipairs({'InstallNativeFillerMaskCache','InstallNativePlayableDistanceCache'})do
 local original=sbm[name];originals[name]=original
 wrappers[name]=function(generator,class,read,write)
  local close,stats
  if name=='InstallNativeFillerMaskCache' then
   -- Read/write proxy preserves each owner's identity contract while observing
   -- the actual production wrapper's complete API-boundary outputs.
   local native_before={GridMask=read('GridMask'),GridAnd=read('GridAnd')}
   local logical={}
   local function observed_read(key)
    local fn=read(key);return logical[fn] or fn
   end
   local function observed_write(key,fn)
    if (key=='GridMask' or key=='GridAnd') and fn~=native_before[key] then
     local observe
     if key=='GridMask' then
      observe=function(...)
       local count=stats and stats.calls or 0
       local values=table.pack(fn(...))
       if stats and stats.calls>count then
        local src,dst,from,to,scale=...
        local expected=dst:clone()
        native_mask(src,expected,from,to,scale)
        equal(expected,dst);expected:free()
        result.mask_boundaries=result.mask_boundaries+1
       end
       return table.unpack(values,1,values.n)
      end
     else
      observe=function(...)
       local dst,other=...
       local count=stats and stats.and_calls or 0
       local expected=select('#',...)==2 and native_grid(dst) and dst:clone()
       local values=table.pack(fn(...))
       if stats and stats.and_calls>count then
        if not expected then result.error='And input not captured'
        else native_and(expected,other);equal(expected,dst) end
        result.and_boundaries=result.and_boundaries+1
       end
       if expected then expected:free() end
       return table.unpack(values,1,values.n)
      end
     end
     logical[observe]=fn
     return write(key,observe)
    end
    return write(key,fn)
   end
   close,stats=original(generator,class,observed_read,observed_write)
  else close,stats=original(generator,class,read,write) end
  result.calls[#result.calls+1]={name=name,stats=stats}
  return close,stats
 end
 sbm[name]=wrappers[name]
end
local original_final=sbm.GenerationGrids.RebuildFinal
sbm.GenerationGrids.RebuildFinal=function(map,stage,...)
 local values=table.pack(original_final(map,stage,...))
 if map.mapdata.Environment=='Surface' and stage=='post-pipeline scheduled revalidation' then
  local filler,distance=0,0
  for _,row in ipairs(result.calls)do
   local s=row.stats
   if not s.installed or not s.restored or s.failure or s.live~=0 then result.error='owner not clean' end
   if row.name=='InstallNativeFillerMaskCache' then filler=filler+(s.hits or 0)
   else distance=distance+(s.cached_primary or 0) end
  end
  if filler==0 or distance==0 then result.error='missing active cache' end
  if not result.class_batch_enabled or not result.name_cache_enabled then result.error='classification optimization inactive' end
  if result.mask_boundaries==0 or result.mask_boundaries~=result.and_boundaries then result.error='missing boundary proof' end
  for name,fn in pairs(originals)do
   if sbm[name]~=wrappers[name]then result.error='installer rebound' else sbm[name]=fn end
  end
  sbm.GenerationGrids.RebuildFinal=original_final
  result.status=result.error and 'fail' or 'pass'
 end
 return table.unpack(values,1,values.n)
end
return 'STARTUP_BUNDLE_DIAGNOSTIC_READY'

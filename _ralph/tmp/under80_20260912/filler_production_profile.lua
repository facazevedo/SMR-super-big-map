-- Read production counters at scheduled final revalidation, after outer cleanup.
-- Existing native procedure observer retains complete output/RNG/process gates.
local result={kind='filler_production',status='ready',scopes={}}
local map_ref
local observer={result=result}
function observer.generation_enter(original,generator,map,row)
 if row.environment=='Underground' then map_ref=map end
 return true
end
function observer.generation_exit()return true end
function observer.procedure_start()return true end
function observer.procedure_end()return true end
function observer.restore()
 local stats=map_ref and map_ref.SuperBigMapNativeFillerMaskStats
 if type(stats)~='table' then result.status='fail';return false,'production counters missing' end
 local row={};for k,v in pairs(stats)do row[k]=v end
 result.scopes[1]=row
 if not row.installed or not row.restored or row.failure or row.live~=0 or row.hits<=0 then
  result.status='fail';return false,'production cache not active/restored'
 end
 result.status='pass';map_ref=nil;return true
end
local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/tmp/under80_20260912/native_proc_profile.lua')
if err or type(source)~='string'then error('native procedure source missing');return end
local base,why=load(source,'@native_proc_profile.lua','t',_G)
if not base then error(why);return end
if rawget(_G,'SBM_NATIVE_PROC_OBSERVER')~=nil then error('observer slot occupied');return end
rawset(_G,'SBM_NATIVE_PROC_OBSERVER',observer)
local ok,value=pcall(base)
rawset(_G,'SBM_NATIVE_PROC_OBSERVER',nil)
if not ok then error(value);return end
return value

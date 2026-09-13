local root='D:/PROJS/SMR/super-big-map/'
local function module(path)
 local err,source=AsyncFileToString(root..path)
 if err or type(source)~='string'then error('source missing '..path);return end
 local fn,why=load(source,'@'..path,'t',_G);if not fn then error(why);return end;return fn
end
local make=module('_ralph/runs/under80-20260912/artifacts/playable_distance_production_observer/observer.lua')
local base=module('_ralph/tmp/under80_20260912/native_proc_profile.lua')
if not make or not base then return end
local observer=make()(GetPreciseTicks);local enter,restore=observer.generation_enter,observer.restore
local map_ref
observer.generation_enter=function(original,generator,map,row)
 if row.environment=='Underground'then map_ref=map end
 return enter(original,generator,map,row)
end
observer.restore=function()
 local ok,why=restore()
 local stats=map_ref and map_ref.SuperBigMapNativePlayableDistanceStats
 if type(stats)~='table'then observer.result.status='fail';return false,'production stats missing'end
 local copy={};for k,v in pairs(stats)do copy[k]=v end;observer.result.production=copy;map_ref=nil
 if not copy.installed or not copy.restored or copy.failure or copy.live~=0 or copy.cached_primary<=0 or copy.cached_secondary<=0 then
  observer.result.status='fail';return false,'production cache not active/clean'
 end
 return ok,why
end
if rawget(_G,'SBM_NATIVE_PROC_OBSERVER')~=nil then error('observer occupied');return end
rawset(_G,'SBM_NATIVE_PROC_OBSERVER',observer);local ok,value=pcall(base)
rawset(_G,'SBM_NATIVE_PROC_OBSERVER',nil);if not ok then error(value);return end;return value

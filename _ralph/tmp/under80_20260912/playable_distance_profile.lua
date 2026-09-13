local root='D:/PROJS/SMR/super-big-map/'
local function module(path)
 local err,source=AsyncFileToString(root..path)
 if err or type(source)~='string'then error('distance source missing '..path);return end
 local fn,why=load(source,'@'..path,'t',_G)
 if not fn then error(why);return end
 return fn
end
local observer=module('_ralph/runs/under80-20260912/artifacts/playable_distance_observer_v2/observer.lua')
local base=module('_ralph/tmp/under80_20260912/native_proc_profile.lua')
if not observer or not base then return end
if rawget(_G,'SBM_NATIVE_PROC_OBSERVER')~=nil then error('observer already occupied');return end
rawset(_G,'SBM_NATIVE_PROC_OBSERVER',observer()(GetPreciseTicks))
local ok,value=pcall(base)
rawset(_G,'SBM_NATIVE_PROC_OBSERVER',nil)
if not ok then error(value);return end
return value

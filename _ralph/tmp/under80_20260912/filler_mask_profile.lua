-- Diagnostic files only; actual production/engine generation remains untouched.
local root='D:/PROJS/SMR/super-big-map/_ralph/tmp/under80_20260912/'
local function module(name)
 local err,source=AsyncFileToString(root..name)
 if err or type(source)~='string'then error('filler shadow source missing: '..name);return end
 local fn,why=load(source,'@'..name,'t',_G)
 if not fn then error(why);return end
 return fn
end
local factory=module('filler_mask_observer.lua')
local kernel=module('filler_mask_cache.lua')
local base=module('native_proc_profile.lua')
if not factory or not kernel or not base then return end
if rawget(_G,'SBM_NATIVE_PROC_OBSERVER')~=nil then error('observer slot already occupied');return end
rawset(_G,'SBM_NATIVE_PROC_OBSERVER',factory()(GetPreciseTicks,kernel()))
local ok,value=pcall(base)
rawset(_G,'SBM_NATIVE_PROC_OBSERVER',nil)
if not ok then error(value);return end
return value

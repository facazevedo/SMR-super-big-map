-- Load diagnostic code only, never reload production or replace native generation.
local root='D:/PROJS/SMR/super-big-map/_ralph/tmp/under80_20260912/'
local function read(name)
 local err,source=AsyncFileToString(root..name)
 if err or type(source)~='string'then error('primitive probe source unavailable: '..name);return end
 return source
end
local observer_source=read('prefab_primitive_observer.lua')
local base_source=read('native_proc_profile.lua')
if not observer_source or not base_source then return end
local factory,why=load(observer_source,'@prefab-primitive-observer','t',_G)
if not factory then error(why);return end
local base;base,why=load(base_source,'@prefab-primitive-base','t',_G)
if not base then error(why);return end
if rawget(_G,'SBM_NATIVE_PROC_OBSERVER')~=nil then error('native observer slot already occupied');return end
local observer=factory()(GetPreciseTicks)
rawset(_G,'SBM_NATIVE_PROC_OBSERVER',observer)
local ok,value=pcall(base)
rawset(_G,'SBM_NATIVE_PROC_OBSERVER',nil)
if not ok then error(value);return end
return value

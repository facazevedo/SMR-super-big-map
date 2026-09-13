-- Reuse production full-output shadow with actual helper-sequence replay.
local root='D:/PROJS/SMR/super-big-map/'
local err,source=AsyncFileToString(root..'_ralph/tmp/under80_20260912/playable_distance_production_profile.lua')
if err or type(source)~='string'then error('production profile missing');return end
source=source:gsub('playable_distance_production_observer/observer.lua','playable_distance_helper_replay/observer.lua')
local support=[=[local sbm
for _,mod in ipairs(ModsLoaded or {})do local s=mod.env and rawget(mod.env,'SuperBigMap');if s and s.InstallNativePlayableDistanceCache then sbm=s;break end end
local bridge_module=module('_ralph/runs/under80-20260912/artifacts/playable_distance_helper_replay/bridge.lua')
if not sbm or not bridge_module then error('replay support missing');return end
local observer=make()(GetPreciseTicks,{install=sbm.InstallNativePlayableDistanceCache,bridge=bridge_module()})]=]
local anchor='local observer=make()(GetPreciseTicks)'
local a,b=source:find(anchor,1,true);if not a then error('profile anchor missing');return end
source=source:sub(1,a-1)..support..source:sub(b+1)
local fn,why=load(source,'@actual-helper-replay-profile','t',_G)
if not fn then error(why);return end
return fn()

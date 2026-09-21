-- ModEnv rawset shadows can outlive the Map object restored by LoadGame.
-- Resolve a stale published map through the live registry, while preserving a
-- deliberately published temporary source that still owns its native slot.
local old,live={slot=1,City={}},{slot=1,City={}}
local source={slot=3,City={}}
local env=setmetatable({MainMap=old,MainCity=old.City,Maps={[1]=live,[3]=source}}, {__index=_G})
env._G=env
assert(loadfile('Code/sbm_engine.lua','t',env))()
local E=env.SuperBigMap.Engine
assert(E.Global('MainMap')==live,'old loaded map shadow must resolve to the live surface')
assert(E.Global('MainCity')==live.City,'old loaded city shadow must resolve with its live map')
env.MainMap=source;env.MainCity=source.City
assert(E.Global('MainMap')==source and E.Global('MainCity')==source.City,'live temporary source was overridden')
env.Maps[3]=nil
assert(E.Global('MainMap')==live and E.Global('MainCity')==live.City,'released temporary backing survived as main map')
env.MainMap=live;env.MainCity=old.City
assert(E.Global('MainMap')==live and E.Global('MainCity')==live.City,'live city must follow current map ownership')
env.Maps=nil
assert(E.Global('MainMap')==live and E.Global('MainCity')==old.City,'bootstrap without a map registry changed')
env.SomeOtherGlobal={}
assert(E.Global('SomeOtherGlobal')==env.SomeOtherGlobal,'unrelated global lookup changed')
print('engine map identity: stale save/load aliases, released backing, live temporary source and bootstrap passed')

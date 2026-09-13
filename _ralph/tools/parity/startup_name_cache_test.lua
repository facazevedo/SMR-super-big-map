local function read(path) local f=assert(io.open(path));local s=f:read('*a');f:close();return s end
local f=assert(io.popen('git show 1c75b81:Code/sbm_object_clone.lua'))
local original=f:read('*a');assert(f:close())
local candidate=read('Code/sbm_object_clone.lua')
local function world(source)
 local env=setmetatable({}, {__index=_G});env._G=env
 env.string={};for k,v in pairs(string)do env.string[k]=v end
 local e={Global=function()return nil end,SafeCall=function(fn,...)return fn(...)end,
  IsKindOf=function()return false end}
 env.SuperBigMap={Engine=e};assert(load(source,'fixture','t',env))()
 return env.SuperBigMap.ObjectClone,env
end
local a,ae=world(original);local b,be=world(candidate)
local checks=0
local tokens={'Rock','Mystery','BlackCube','Marsgate','SurfacePassage','UndergroundPassage',
 'SurfaceUndergroundTunnel','ElevatorBuildIndicator_Underground','SignUnderground',
 'Marker','Deposit','Anomaly','Tunnel','Sign','Elevator','MapSector','Sector',
 'GridObjectList','RandomMapGeneratorHolder','CameraObj','ParSystem','SoundSource',
 'PrefabFeatureMarker','CaveInRubble','TunnelBlockerRubble','BottomlessPit','JumboCave',''}
local function tuple(fn,...)
 return table.pack(fn(...))
end
local function same(x,y)
 assert(x.n==y.n);for i=1,x.n do assert(x[i]==y[i])end;checks=checks+1
end
local function run(name)
 same(tuple(a.ClassScalesWithTerrain,name),tuple(b.ClassScalesWithTerrain,name))
 same(tuple(a.MatchUndergroundAccessName,'entity',name),tuple(b.MatchUndergroundAccessName,'entity',name))
 same(tuple(a.IsMysteryRelatedObject,{class=name}),tuple(b.IsMysteryRelatedObject,{class=name}))
end
for pass=1,3 do
 for _,x in ipairs(tokens)do for _,y in ipairs(tokens)do run(x..y);run('_'..x..y..'_33')end end
end
for i=1,5000 do run('Rock'..i)end -- exceed each bounded cache
for _,name in ipairs(tokens)do run(name)end
run(nil);run(false);run(42)
-- Custom hooks and field replacement are observed on every ordered fallback call.
local ac,bc=0,0
ae.string.find=function(...)ac=ac+1;return string.find(...)end
be.string.find=function(...)bc=bc+1;return string.find(...)end
for _,name in ipairs(tokens)do run(name);run(name)end
assert(ac==bc and ac>0)
ae.string.find=string.find;be.string.find=string.find
for _,name in ipairs(tokens)do run(name)end
print('PASS '..checks..' pure-name cache and replacement checks')

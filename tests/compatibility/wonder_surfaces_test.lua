local f=assert(io.open('Code/sbm_map_generation.lua','r'))
local source=f:read('*a');f:close()
local block=assert(source:match('function WonderVerticalDiagnostics.FinalizeTerrainSurfaces.-\nend\n'))
local map={mapdata={Environment='Underground'},SuperBigMapUndergroundStretchDone=true}
local current=map
local objects={}
local function wonder(class,has,flags,stamp)
  local w={class=class,has=has,flags=flags,calls=0,SuperBigMapWonderFlattenZ=stamp}
  function w:GetEnumFlags(mask) return self.flags & mask end
  function w:ClearEnumFlags(mask) self.calls=self.calls+1;self.flags=self.flags & ~mask end
  function w:SetEnumFlags(mask) self.calls=self.calls+1;self.flags=self.flags | mask end
  -- No geometry or terrain-writing APIs are supplied: any use is a test failure.
  return w
end
local diagnostics={}
local env=setmetatable({WonderVerticalDiagnostics=diagnostics,
  Global=function(name)
    if name=='CurrentMap' then return current end
    if name=='const' then return {efApplyToGrids=8} end
    if name=='EntitySurfaces' then return {TerrainHole=64,Height=4} end
    if name=='HasAnySurfaces' then return function(w,mask,attached) assert(mask==68 and attached);return w.has end end
  end,
  Engine={MapDataEnvironment=function(data) return data.Environment end},
  ArtefactMapGet=function(owner,class) assert(owner==map and class=='UndergroundWonder');return objects end,
  LoadingStep=function() end,
},{__index=_G})
assert(load(block,'production native surface publication','t',env))()
local run=diagnostics.FinalizeTerrainSurfaces
for _,class in ipairs({'AncientArtifact','CaveOfWonders','BottomlessPit','JumboCave'}) do
  objects[#objects+1]=wonder(class,true,136,1000)
end
local inert=wonder('BottomlessPit',true,128,1000);objects[#objects+1]=inert
local no_surface=wonder('JumboCave',false,136,1000);objects[#objects+1]=no_surface
local vanilla=wonder('BottomlessPit',true,136,nil);objects[#objects+1]=vanilla
current={}
assert(run(map)==false)
for _,w in ipairs(objects) do assert(w.calls==0) end
current=map
local ok,result=run(map,'first frame')
assert(ok and result.refreshed==4)
for i=1,4 do assert(objects[i].flags==136 and objects[i].calls==2) end
assert(inert.calls==0 and no_surface.calls==0 and vanilla.calls==0)
ok,result=run(map,'repeat');assert(ok and result.refreshed==0)
ok,result=run(map,'resources settled',true);assert(ok and result.refreshed==4)
for i=1,4 do assert(objects[i].calls==4 and objects[i].flags==136) end
local untouched={mapdata={Environment='Surface'},SuperBigMapUndergroundStretchDone=true}
assert(run(untouched))
-- Already-current completion must not depend on an Elevator restoration token.
local handoff=assert(source:match('(local restore_token = ok_branch and Global%("CurrentMap"%) == map.-)\n\t\t\tpcall%(msg, "SuperBigMapUndergroundExpansionDone"'))
local messages={}
local handoff_env=setmetatable({map=map,ok_branch=true,Global=function() return map end,
  CurrentElevatorRestoreToken=function() return nil end,
  msg=function(name,owner,token) messages[#messages+1]={name,owner,token} end,
},{__index=_G})
assert(load(handoff,'production no-elevator completion','t',handoff_env))()
assert(#messages==1 and messages[1][1]=='SuperBigMapUndergroundSupplyReady' and messages[1][2]==map)
-- Source-cleared maps preserve the already-resampled vanilla terrain on every
-- activation/load. No legacy shape or terrain API is exposed to this fixture.
local reseat=assert(source:match('function WonderVerticalDiagnostics.ReseatAll.-\nend\n'))
local positions_ok=true
local position_checks=0
diagnostics.RestoreExpectedPositionsBeforeAnomalySpawn=function(owner)
  assert(owner==map);position_checks=position_checks+1
  return positions_ok,{checked=4,corrected=0,error=not positions_ok and 'bad pose' or nil}
end
map.SuperBigMapDeferredUndergroundWondersSourceCleared=true
assert(load(reseat,'production source-cleared lifecycle','t',env))()
ok,result=diagnostics.ReseatAll(map,'load')
assert(ok and result.terrain_preserved and position_checks==1)
assert(map.SuperBigMapWonderLifecycleReseatDone and not map.SuperBigMapWonderLifecycleReseatFailed)
positions_ok=false
ok,result=diagnostics.ReseatAll(map,'bad load')
assert(not ok and map.SuperBigMapWonderLifecycleReseatFailed=='bad pose')
current={}
assert(not diagnostics.ReseatAll(map,'offscreen'))
assert(position_checks==2)
-- The reused object-only verifier must not open a pass-edit transaction for an
-- already-correct map. A moved object is corrected once, with balanced grids.
current=map
local restore=assert(source:match('function WonderVerticalDiagnostics.RestoreExpectedPositionsBeforeAnomalySpawn.-\nend\n'))
local suspends,resumes,positions=0,0,0
map.SuspendPassEdits=function() suspends=suspends+1 end
map.ResumePassEdits=function() resumes=resumes+1 end
env.DeferredWonderScaleRatios=function() return {} end
env.PointXY=function(p) return p.x,p.y end
diagnostics.SafePointZ=function(p) return p.z end
diagnostics.ExactStretchedWonderXY=function() return 400,800 end
local original_global=env.Global
env.Global=function(name)
  if name=='point' then return function(x,y,z) return {x=x,y=y,z=z} end end
  return original_global(name)
end
objects={}
for _,class in ipairs({'AncientArtifact','CaveOfWonders','BottomlessPit','JumboCave'}) do
  local w=wonder(class,true,136,1000)
  w.pos={x=400,y=800,z=1000};w.grids_applied=true
  function w:GetPos() return self.pos end
  function w:SetPos(p) self.pos=p;positions=positions+1 end
  function w:RemoveFromGrids() self.grids_applied=false end
  function w:ApplyToGrids() self.grids_applied=true end
  objects[#objects+1]=w
end
assert(load(restore,'production object-only finalizer','t',env))()
ok,result=diagnostics.RestoreExpectedPositionsBeforeAnomalySpawn(map,'unchanged')
assert(ok and result.checked==4 and positions==0 and suspends==0 and resumes==0)
objects[2].pos.x=401
ok,result=diagnostics.RestoreExpectedPositionsBeforeAnomalySpawn(map,'move')
assert(ok and result.corrected==1 and positions==1 and suspends==1 and resumes==1)
assert(objects[2].pos.x==400 and objects[2].grids_applied)
objects={}
ok,result=diagnostics.ReseatAll(map,'wonders removed by gameplay')
assert(ok and result.skipped)
local settle_source=assert(source:match('(local function SettleUndergroundSceneResources.-\nend)\n'))
local waits,publishes=0,0
local resources_ready,surfaces_ready=true,true
env.WaitForUndergroundResourceRequests=function()
  waits=waits+1;return resources_ready,'resource result'
end
diagnostics.FinalizeTerrainSurfaces=function(owner,reason,force)
  assert(owner==map and force);publishes=publishes+1
  return surfaces_ready,'surface result'
end
local settle=assert(load(settle_source..'\nreturn SettleUndergroundSceneResources','production resource finalizer','t',env))()
assert(settle(map,'ready') and waits==1 and publishes==1)
surfaces_ready=false
ok,result=settle(map,'native failure')
assert(not ok and result=='surface result' and waits==2 and publishes==2)
resources_ready=false
ok,result=settle(map,'resource failure')
assert(not ok and waits==4 and publishes==2)
print('PASS: all wonder classes preserve source-cleared terrain, finalize native surfaces without geometry writes, preserve flags, skip vanilla/offscreen/inert objects, and complete without an Elevator')

local function read(path)
 local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s
end
local source=read('Code/sbm_terrain_copy.lua')
local generation=read('Code/sbm_map_generation.lua')
local align=assert(source:match('local function AlignPassagePairsToSharedHex.-\nend\n'))
local function compile(block,result,env)
 return assert(load(block..'\nreturn '..result,'production passage safety','t',
  setmetatable(env,{__index=_G})))()
end

-- Every hex in each nearer ring must be exhausted before any further ring.
local rings=assert(align:match('(local directions = {.-)\n\tfor i = 1, #linked_pairs do'))
local search=compile(rings,'nearest_on_hex_rings',{})
for limit=0,20 do
 local seen,count,last={},0,0
 local q=search(20,30,function(x,y)
  local radius=math.max(math.abs(x-20),math.abs(y-30),math.abs(x+y-50))
  assert(radius>=last and radius<=limit);last=radius
  local key=x..':'..y;assert(not seen[key]);seen[key]=true;count=count+1
  return false
 end,0,limit)
 assert(q==nil and count==1+3*limit*(limit+1))
end
for target=0,10 do
 local q,r,radius=search(20,30,function(x,y) return x==20+target and y==30 end,0,20)
 assert(q==20+target and r==30 and radius==target)
end

-- The native flatten-unbuildable option must never receive a rejected footprint.
-- In the reported failure, a provisional surface anchor reached this function
-- with the 65535 unbuildable sentinel. No mutation may precede rejection.
local pad=assert(source:match('(local function prepare_passage_pad.-)\n\tlocal function clear_passage_obstructions'))
local map,anchor={},{}
local calls,valid=0,false
local run=compile(pad,'prepare_passage_pad',{
 elevator_shape={},map_of=function() return map end,
 flatten_build_shape=function() calls=calls+1 end,
 move_object=function() calls=calls+1;return true end,
 point_fn=function(x,y) return {x=x,y=y} end,
 world_to_hex=function(p) return p.x,p.y end,
 SafeCall=function(fn,...) return fn(...) end,
 footprint_buildable=function() return valid,'unbuildable footprint hex' end,
})
local ok=run(anchor,map,10,20)
assert(not ok and calls==0 and not anchor.SuperBigMapPassagePadPrepared,
 'rejected Elevator footprint must not be flattened or marked prepared')
valid=true
assert(run(anchor,map,10,20) and calls==2 and anchor.SuperBigMapPassagePadPrepared)

-- Exercise the complete production three-phase planner, including the real
-- Elevator footprint walk, with isolated engine protocol doubles.
local validate=assert(source:match('local function ValidateSurfacePassageCommitment.-\nend\n'))
local function point(x,y,z)
 return {px=x,py=y,pz=z or 100,z=function(p) return p.pz end,
  SetTerrainZ=function(p) return p end}
end
local function distance(q,r) return math.max(math.abs(q-40),math.abs(r-40),math.abs(q+r-80)) end
for _,case in ipairs({{0},{1},{2},{17},{0,true},{0,false,true}}) do
 local required_ring,invalid_edge,padding_only=case[1],case[2],case[3]
 local surface={Width=100,Height=100,hex_width=100,hex_height=100}
 local underground={Width=100,Height=100,hex_width=100,hex_height=100,
  SuperBigMapGeneratorWidthTiles=50,SuperBigMapGeneratorHeightTiles=50,
  SuperBigMapDesiredWidthTiles=100,SuperBigMapDesiredHeightTiles=100}
 local function anchor(owner,x,y)
  local a={entity='Passage',pos=point(x,y),owner=owner}
  function a:GetMap() return self.owner end
  function a:GetPos() return self.pos end
  function a:SetPos(p) self.pos=p end
  function a:GetAngle() return 0 end
  return a
 end
 local u,s=anchor(underground,20,20),anchor(surface,10,10)
 u.other,s.other=s,u
 local writes=0
 for _,owner in ipairs({surface,underground}) do
  owner.buildable={GetZ=function(self,q,r)
   if owner==surface and invalid_edge and q==41 and r==40 then return 65535 end
   if owner==surface and padding_only and q==43 and r==40 then return 65535 end
   return 100
  end}
  owner.object_hex_grid={GetBuildObstructions=function() return {} end}
  owner.MapForEach=function(self,scope,class,fn)
   if class=='ElevatorPassage' or class=='CObject' then fn(self==surface and s or u) end
  end
 end
 local globals={MainMap=surface,point=point,
  WorldToHex=function(p) return p.px,p.py end,HexToWorld=function(q,r) return q,r end,
  buildUnbuildableZ=function() return 65535 end,
  GetExtendedSpawnShape=function(class) assert(class=='Elevator');return {{0,0},{1,0},{3,0}} end,
  BuildingTemplates={Elevator={GetBuildShape=function() return {{0,0},{1,0}} end,
   GetFlattenShape=function() return {{0,0},{1,0}} end}},
  GetEntityOutlineShape=function() return {{0,0}} end,
  IsTerrainFlatForPlacement=function(buildable,shape,p)
   return buildable~=surface.buildable or distance(p.px,p.py)>=required_ring
  end,
  ValidateEachShapeHexPos=function(shape,p,angle,fn)
   for _,offset in ipairs(shape) do if not fn(p.px+offset[1],p.py+offset[2]) then return false end end
   return true
  end,
  terrain={IsPassable=function() return true end},
  FlattenTerrainInBuildShape=function() writes=writes+1 end,
  ClearObstructions=function() writes=writes+1 end,
 }
 local environment={Global=function(name) return globals[name] end,
  TerrainSize=function(m) return m.Width,m.Height end,
  ObjectPosition=function(a) return a.pos end,PointXY=function(p) return p.px,p.py end,
  IsLiveGameObject=function(a) return type(a)=='table' end,
  SafeCall=function(fn,...) return fn(...) end,IsKindOfSafe=function() return false end,
  EntranceAudit=function() end,EntranceAuditEnabled=function() return false end}
 local planner=compile(validate..align,'AlignPassagePairsToSharedHex',environment)
 assert(planner(underground,{source_bootstrap=true}))
 assert(u.pos.px==20 and s.pos.px==40 and writes==0)
 local deferred,result=planner(underground)
 assert(not deferred and result.error:find('not committed') and writes==0 and u.pos.px==20,
  'bootstrap lock alone must reject deferred mutation')
 assert(planner(underground,{source_bootstrap=true,prepare_surface_pad=true}))
 assert(u.pos.px==20 and u.pos.py==20,'surface fallback cannot move underground truth')
 local expected_ring=invalid_edge and 1 or required_ring
 assert(distance(s.pos.px,s.pos.py)==expected_ring,
  'a valid center does not authorize an invalid outer Elevator footprint hex')
 assert(surface.SuperBigMapPassageGlueReport[1].ring_distance==expected_ring)
 local sx,sy=s.pos.px,s.pos.py
 local final,stats=planner(underground)
 assert(final and u.pos.px==40 and u.pos.py==40 and s.pos.px==sx and s.pos.py==sy)
 assert(stats.fallback==(expected_ring==0 and 0 or 1),'deferred report must retain the actual offset')
 assert(writes==2,'surface planning must not rewrite naturally buildable terrain; only underground clearance/pad mutate')
 -- Losing transient map flags (save/load) must not invalidate the persisted object commitment.
 underground.SuperBigMapPassageSurfaceFinalCommitted=nil
 local validator=compile(validate,'ValidateSurfacePassageCommitment',environment)
 assert(validator(underground) and validator(underground,true))
 local previous_flat=globals.IsTerrainFlatForPlacement
 globals.IsTerrainFlatForPlacement=function() return false end
 assert(validator(underground) and not validator(underground,true),
  'generation must check the settled terrain, but later Elevator occupancy is not a load failure')
 globals.IsTerrainFlatForPlacement=previous_flat
 -- Every pair is checked before any deferred mutation, including a corrupt second pair.
 local u2,s2=anchor(underground,25,25),anchor(surface,50,50)
 u2.other,s2.other=s2,u2
 underground.MapForEach=function(self,scope,class,fn)
  if class=='ElevatorPassage' then fn(u);fn(u2) end
 end
 local before=writes
 assert(not planner(underground) and writes==before)
 local native_shape=globals.GetExtendedSpawnShape
 globals.GetExtendedSpawnShape=nil
 local accepted,why=planner(underground,{source_bootstrap=true})
 assert(not accepted and why.error=='complete Elevator placement APIs unavailable' and writes==before,
  'missing placement APIs must not degrade the Elevator check to one center tile')
 globals.GetExtendedSpawnShape=native_shape
end

local sbm={GenerationReadiness={}}
local messages={}
local failure=assert(generation:match('function SuperBigMap.GenerationReadiness.RecordSurfaceExpansionFailure.-\nend\n'))
compile(failure,'true',{SuperBigMap=sbm,SignalExpansionReadinessChanged=function() end,
 Global=function(name) if name=='print' then return function(s) messages[#messages+1]=s end end end})
local surface={SuperBigMapExpanded=true,SuperBigMapSurfaceStretchDone=true,
 SuperBigMapSurfacePostPipelineRevalidationComplete=true}
sbm.GenerationReadiness.RecordSurfaceExpansionFailure(surface,'first fault')
sbm.GenerationReadiness.RecordSurfaceExpansionFailure(surface,'cleanup fault')
assert(surface.SuperBigMapSurfaceStretchFailed=='first fault' and #messages==1)
assert(not surface.SuperBigMapExpanded and not surface.SuperBigMapSurfaceStretchDone
 and not surface.SuperBigMapSurfacePostPipelineRevalidationComplete)
-- Exercise the real inner-branch completion block, not just its failure helper.
local completion=assert(generation:match('%-%- Closing the loading UI.-\n(.-)\n\t\t\tend_loading%(%)'))
for _,success in ipairs({false,true}) do
 local target={}
 compile(completion,'true',{map=target,ok_branch=success,branch_err='branch fault',SuperBigMap=sbm})
 assert(target.SuperBigMapSurfaceStretchDone==success and target.SuperBigMapExpanded==success)
 assert((not not target.SuperBigMapSurfaceStretchFailed)==not success)
end
local readiness=assert(generation:match('local function UndergroundExpansionReadiness.-\nend\n'))
local committed=false
local ready=compile(readiness,'UndergroundExpansionReadiness',{
 Global=function(name) if name=='MainMap' then return surface end end,
 cfg_bool=function() return true end,SuperBigMap=sbm,
 TerrainCopy={ValidateSurfacePassageCommitment=function() return committed,'missing final pad' end}})
local ug={SuperBigMapNativeGenerationComplete=true,SuperBigMapCityInitializationComplete=true}
local good,reason,terminal=ready(ug)
assert(not good and terminal and reason:find('first fault'))
surface.SuperBigMapSurfaceStretchFailed=nil
surface.SuperBigMapSurfaceStretchDone=true
good,reason,terminal=ready(ug)
assert(not good and terminal and reason:find('missing final pad'))
committed=true
assert(ready(ug))
surface.SuperBigMapSurfaceStretchScheduled=true
good,reason,terminal=ready(ug)
assert(not good and not terminal,'underground must wait for the final native grid validation')
surface.SuperBigMapSurfacePostPipelineRevalidationComplete=true
assert(ready(ug))
surface.SuperBigMapSurfaceStretchScheduled=nil
surface.SuperBigMapSurfaceStretchDone=false
good,reason,terminal=ready(ug)
assert(not good and not terminal,'a genuinely running surface must wait, not fail')

print('passage safety: complete planner, nearest valid rings, immutable underground, pad guard, load and failure gates passed')

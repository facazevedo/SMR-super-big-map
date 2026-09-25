-- Decor top-up open-base rims (24S74W, build 1111): the stamp planner must apply the final
-- seating's rim rule, dz <= -gap-2, so a stamp the final pass could not seat is rejected.
local function read(path)local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua')
dofile('Code/sbm_decoration_seating.lua')
local G=SuperBigMap.DecorationGeometry
local seating=SuperBigMap.DecorationSeating
local code=read('Code/sbm_decoration_validation.lua')

-- 1. PlanSupportIsland against an independent reference with and without rim gaps.
math.randomseed(1111)
local function reference(components)
 local low,high,roots=-math.huge,math.huge,0
 for _,c in ipairs(components) do
  low=math.max(low,c.visible-c.clearance[2])
  if c.terrain then roots=roots+1;high=math.min(high,-c.clearance[1]) end
  if c.foundation_gap then high=math.min(high,-c.foundation_gap-2) end
 end
 if roots==0 or low>math.floor(high) then return nil end
 local dz=math.floor(math.min(0,high));if dz<low then dz=math.ceil(low) end
 return dz
end
local constrained,rejected=0,0
for trial=1,4000 do
 local list={}
 for i=1,math.random(1,6) do
  local bottom=math.random(-40,60);local top=bottom+math.random(0,300)
  list[i]={clearance={bottom,top},visible=math.random(2,80),terrain=math.random(0,2)>0}
  if math.random(0,3)==0 then list[i].foundation_gap=math.random(-5,400)+math.random() end
 end
 local dz=seating.PlanSupportIsland(list,function()error('clearances must not resample')end)
 local want=reference(list)
 assert(dz==want,'rim-constrained island plan differs from the reference')
 local plain={}
 for i,c in ipairs(list) do plain[i]={clearance=c.clearance,visible=c.visible,terrain=c.terrain} end
 local old=seating.PlanSupportIsland(plain,function()end)
 if dz~=old then constrained=constrained+1 end
 if old and not dz then rejected=rejected+1 end
 if dz and old then assert(dz<=old,'a rim can only lower the plan') end
end
assert(constrained>0 and rejected>0,'fixture never exercised the rim bound')

-- 2. TargetFoundationGap: production rim descriptors, frame exclusions and similarity.
local globals={const={HeightTileSize=100}}
local terrain_height
local env=setmetatable({Geometry=G,Global=function(n)return globals[n]end,Projected=function()return false end,
 Matrix=function(r)return r.matrix end,min=math.min,max=math.max,floor=math.floor},{__index=_G})
env.World=assert(load(assert(code:match('(local function World%(.-\nend)\n'))..'\nreturn World','world','t',env))()
env.FoundationDescriptors=assert(load(assert(code:match('(local function FoundationDescriptors%(.-\nend)\n'))
 ..'\nreturn FoundationDescriptors','descriptors','t',env))()
local target=assert(load(assert(code:match('(local function TargetFoundationGap%(.-\nend)\n'))
 ..'\nreturn TargetFoundationGap','target rim','t',env))()
local function box_asset()
 local g={vertices={{0,0,0},{10,0,0},{10,10,0},{0,10,0},{0,0,10},{10,0,10},{10,10,10},{0,10,10}},components={}}
 local c={bounds={0,0,0,10,10,10},vertices={1,2,3,4,5,6,7,8},triangles={
  {1,2,6},{1,6,5},{2,3,7},{2,7,6},{3,4,8},{3,8,7},{4,1,5},{4,5,8},{5,6,7},{5,7,8}}}
 g.components[1]=c
 return {complete=true,parts={{lod=0,mesh={geometry=g}}}},g,c
end
local function object(overrides)
 local o={GetParent=function()end,GetClipPlane=function()return 0 end,GetSkewX=function()return 0 end,
  GetSkewY=function()return 0 end,GetWarped=function()return false end,GetTerrainDistortedSupport=function()return false end}
 for k,v in pairs(overrides or {}) do o[k]=v end
 return o
end
local function height_at(x,y)return terrain_height(x,y)end
for trial=1,300 do
 local asset=box_asset()
 local s=math.random(3,40);local origin={math.random(2000,6000),math.random(2000,6000),math.random(0,500)}
 local record={obj=object(),asset=asset,pose={origin=origin,shift={0,0,0}},
  matrix={origin=origin,columns={{s,0,0},{0,s,0},{0,0,s}}}}
 local p={math.random(2000,6000),math.random(2000,6000),math.random(0,500)};local ratio=1+math.random()
 local slope=math.random(-3,3)/10
 terrain_height=function(x,y)return 40+math.floor(x*slope)end
 local points={}
 for i,v in ipairs({{0,0,0},{10,0,0},{10,10,0},{0,10,0}}) do
  local w={origin[1]+v[1]*s,origin[2]+v[2]*s,origin[3]+v[3]*s}
  points[i]={p[1]+(w[1]-origin[1])*ratio,p[2]+(w[2]-origin[2])*ratio,p[3]+(w[3]-origin[3])*ratio}
 end
 local want=G.FoundationClearance(points,{{1,2},{2,3},{3,4},{4,1}},height_at,100,10000,10000)
 local gap=target(record,origin,p,ratio,height_at,10000,10000)
 assert(want and gap and math.abs(gap-want)<1e-6,'proposed-pose rim gap differs from the transformed rim')
end
do
 local asset=box_asset();local origin={5000,5000,100}
 local record={obj=object(),asset=asset,pose={origin=origin,shift={0,0,0}},matrix={origin=origin,columns={{10,0,0},{0,10,0},{0,0,10}}}}
 terrain_height=function()return 50 end
 assert(math.abs(target(record,origin,{5200,5100,120},1.5,height_at,10000,10000)-70)<1e-9,'flat rim gap')
 assert(target(record,origin,{9990,5100,120},1.5,height_at,10000,10000)==false,'rim beyond the map must fail closed')
 record.matrix.columns[3]={0,0,-10}
 assert(target(record,origin,{5200,5100,120},1.5,height_at,10000,10000)==nil,'upside-down cap is not a ground rim')
 record.matrix.columns[3]={0,0,10};record.obj=object({GetParent=function()return {} end})
 assert(target(record,origin,{5200,5100,120},1.5,height_at,10000,10000)==nil,'attached object excluded like FoundationEvidence')
 local closed=box_asset();local c=closed.parts[1].mesh.geometry.components[1]
 c.triangles[#c.triangles+1]={1,3,2};c.triangles[#c.triangles+1]={1,4,3}
 record.obj=object();record.asset=closed
 assert(target(record,origin,{5200,5100,120},1.5,height_at,10000,10000)==nil,'closed rock has no rim')
end

-- 3. BuildDecorPlacement: rim gaps constrain, reject, fail closed, and spare rocks on rocks.
local body=assert(code:match('(function Validator%.BuildDecorPlacement.-\nend)\n'))
local bounds=assert(code:match('(local function WorldBounds.-\nend)\n'))
local context,gaps,calls
local pglobals={const={HeightTileSize=100},box=function(...)return {...}end,
 terrain={GetMinMaxHeight=function()return 50,50 end,GetHeight=function()return 50 end}}
local validator={CaptureGroup=function()return context end}
local penv=setmetatable({Validator=validator,SBM={ObjectClone={ObjectScalesWithTerrain=function()return true end},DecorationSeating=seating},
 Global=function(n)return pglobals[n]end,Enabled=function()return true end,
 Matrix=function(r)return r.matrix end,min=math.min,max=math.max,abs=math.abs,floor=math.floor,
 TargetFoundationGap=function(record)calls[#calls+1]=record;return gaps[record] end,Point=function(p)return p end,
 Geometry={SupportVertices=function(_,c)return c.vertices end}},{__index=_G})
penv.WorldBounds=assert(load(bounds..'\nreturn WorldBounds','bounds','t',penv))()
penv.World=assert(load(assert(code:match('(local function World%(.-\nend)\n'))..'\nreturn World','world','t',penv))()
assert(load(body,'planner','t',penv))()
local map={GetMapSize=function()return 10000,10000 end}
local vertices={{-10,-10,0},{10,-10,0},{10,10,300},{-10,10,300}}
local function rock(x)
 local o={GetScale=function()return 100 end,IsValidZ=function()return true end}
 local c={vertices={1,2,3,4},samples=vertices,bounds={-10,-10,0,10,10,300}}
 local r={obj=o,relevant=true,complete=true,pose={origin={x,5000,50},shift={0,0,0}},
  matrix={origin={x,5000,50},columns={{1,0,0},{0,1,0},{0,0,1}}}}
 r.nodes={{record=r,supported=true,geometry={vertices=vertices},component=c,contacts={terrain=true}}}
 return o,r
end
local center={xyz=function()return 5000,5000,50 end}
local o,r=rock(5000);context={list={r}}
gaps={};calls={}
local base=validator.BuildDecorPlacement(map,{o},center,1)
assert(base.ok and base.placements[o].zero_offset_proven and #calls==1,'rimless rock must keep the zero certificate')
gaps[r]=20;calls={}
local low=validator.BuildDecorPlacement(map,{o},center,1)
assert(low.ok and not low.placements[o].zero_offset_proven,'rim gap must force the full interval plan')
assert(low.placements[o].position[3]==base.placements[o].position[3]-22,'rim must be covered by 2 units exactly')
gaps[r]=1238;calls={}
local refused=validator.BuildDecorPlacement(map,{o},center,1)
assert(not refused.ok and refused.reason=='support island cannot retain contact and visibility','unseatable rim must reject the stamp')
gaps[r]=2;calls={}
local within=validator.BuildDecorPlacement(map,{o},center,1)
assert(within.ok and within.placements[o].zero_offset_proven,'a gap at the nomination threshold is not a rim defect')
gaps[r]=false;calls={}
local unknown=validator.BuildDecorPlacement(map,{o},center,1)
assert(not unknown.ok and unknown.reason=='open-base rim terrain unavailable','unmeasurable rim must fail closed')
local o2,r2=rock(5015)
r.nodes[1].edges={r2.nodes[1]};context={list={r,r2}};gaps={[r]=1238,[r2]=1238};calls={}
local stacked=validator.BuildDecorPlacement(map,{o,o2},center,1)
assert(stacked.ok and #calls==0,'rocks resting on stamp rocks keep the overhang exemption')
-- 4. Invalid-Z scatter (61N136W): its visual Z stood 81 above its transform origin, so the old
--    plan lifted it with the group and left a planned-as-embedded stone floating. Plan from the
--    transform origin and seat that origin on the destination terrain.
local zo={GetScale=function()return 111 end,IsValidZ=function()return false end}
local zv={{-20,-20,-44},{20,-20,-44},{20,20,44},{-20,20,44}}
local zc={vertices={1,2,3,4},samples=zv,bounds={-20,-20,-44,20,20,44}}
local zr={obj=zo,relevant=true,complete=true,pose={origin={5000,5000,131},shift={0,0,0}},
 matrix={origin={5000,5000,50},columns={{1.11,0,0},{0,1.11,0},{0,0,1.11}}}}
zr.nodes={{record=zr,supported=true,geometry={vertices=zv},component=zc,contacts={terrain=true}}}
context={list={zr}};gaps={};calls={}
local zplan=validator.BuildDecorPlacement(map,{zo},{xyz=function()return 5000,5000,50 end},4/3)
assert(zplan.ok and zplan.placements[zo].position[3]==50,'invalid-Z scatter must sit on the destination terrain')
assert(zplan.placements[zo].zero_offset_proven,'embedded terrain-bound scatter keeps its exact zero plan')
zo.IsValidZ=function()return true end
local lifted=validator.BuildDecorPlacement(map,{zo},{xyz=function()return 5000,5000,50 end},4/3)
assert(lifted.ok and lifted.placements[zo].position[3]==math.floor(50+(131-50)*4/3+.5),'explicit-Z objects keep the vertical similarity')
print(string.format('decor top-up rims: 4000 island plans (%d constrained, %d rejected), 300 proposed-pose rims, planner accept/reject/fail-closed/overhang cases, terrain-bound invalid-Z origin',constrained,rejected))

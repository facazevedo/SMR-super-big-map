local function point(x,y,z)
 return {xyz=function()return x,y,z end,xy=function()return x,y end}
end
local globals={point=point,terrain={GetHeight=function()return 0 end},
 ComposeRotation=function(axis,angle,axis2,angle2)
  assert(angle==0,'original pose must be composed before the world-space tilt')
  return axis2,angle2
 end}
SuperBigMap={Engine={Global=function(k)return globals[k]end}}
dofile('Code/sbm_decoration_geometry.lua');dofile('Code/sbm_decoration_validation.lua')
local V=SuperBigMap.DecorationValidation
local contexts
for i=1,100 do local k,v=debug.getupvalue(V.RotationSeatingEvidence,i);if k=='contexts' then contexts=v;break end end
local obj={GetAxis=function()return point(0,0,4096)end,GetAngle=function()return 0 end,SetAxisAngle=function()end}
local geometry={vertices={{0,0,0},{10,0,0},{0,10,10},{0,20,20},{10,20,20},{0,30,30}}}
local function component(first)
 return {vertices={first,first+1,first+2},triangles={{first,first+1,first+2}}}
end
local record={obj=obj,complete=true,pose={matrix={origin={0,0,0},columns={{1,0,0},{0,1,0},{0,0,1}}},shift={0,0,0},scale=100},nodes={}}
for _,first in ipairs({1,4})do record.nodes[#record.nodes+1]={record=record,geometry=geometry,component=component(first)}end
local entry={obj=obj,components={{height=10,vertices={geometry.vertices[1],geometry.vertices[2],geometry.vertices[3]}},
 {height=10,vertices={geometry.vertices[4],geometry.vertices[5],geometry.vertices[6]}}}}
local map={};contexts[map]={by_object={[obj]=record}}
for degrees=1,30 do for direction=0,7 do
 local r=assert(V.RotationSeatingEvidence(map,entry,degrees,direction))
 assert(r.angle==degrees*60 and r.degrees==degrees)
 for ci,c in ipairs(r.components)do
  assert(c.required_visibility==5,'rotation lowered the original visibility requirement')
  for i=1,3 do for j=1,3 do
   local a,b=c.vertices[i],c.vertices[j]
   local old_a,old_b=entry.components[ci].vertices[i],entry.components[ci].vertices[j]
   local d,old_d=0,0
   for k=1,3 do
    d=d+(a[k]-b[k])^2;old_d=old_d+(old_a[k]-old_b[k])^2
    assert(a[k]>=r.bounds[k] and a[k]<=r.bounds[k+3],'rotated bounds missed a vertex')
   end
   assert(math.abs(d-old_d)<1e-8,'rotation distorted the native mesh')
  end end
 end
end end
geometry.animated=true
assert(not V.RotationSeatingEvidence(map,entry,5,0),'animated meshes must not enter rigid tilt search')
geometry.animated=nil;record.pose.parent={}
assert(not V.RotationSeatingEvidence(map,entry,5,0),'attached geometry must remain excluded')
print('rigid tilt planner: 240 rotations preserve geometry, bounds and original visible-height floors; unsafe assets vetoed')

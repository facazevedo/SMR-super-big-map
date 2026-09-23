SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
local hit=G.VerticalTriangleContact
local a={{0,0,10},{10,0,10},{0,10,10}}
local b={{0,0,0},{10,0,0},{0,10,0}}
assert(hit(a,b,20)==10 and hit(a,b,9)==nil and hit(b,a,20)==nil)
assert(hit(a,{{20,20,0},{30,20,0},{20,30,0}},20)==nil)
math.randomseed(384)
local checks=0
for trial=1,10000 do
 local a,b={},{}
 for i=1,3 do
  a[i]={math.random()*10,math.random()*10,math.random()*10+10}
  b[i]={math.random()*10,math.random()*10,math.random()*10}
 end
 local distance=hit(a,b,30)
 if distance then
  local function translated(d)
   local t={};for i,p in ipairs(a)do t[i]={p[1],p[2],p[3]-d}end;return t
  end
  assert(not G.TrianglesSeparated(translated(distance),b,1e-7),'proposed contact misses triangles')
  assert(G.TrianglesSeparated(translated(distance-1e-5),b,0),'earlier intersection skipped')
  checks=checks+1
 end
end
dofile('Code/sbm_decoration_validation.lua')
local V=SuperBigMap.DecorationValidation
local contexts
for i=1,100 do local k,v=debug.getupvalue(V.SeatingVerticalContact,i);if k=='contexts'then contexts=v;break end end
local map,obj,neighbor={},{},{}
local function record(o,z)
 return {obj=o,complete=true,pose={matrix={origin={0,0,z},columns={{1,0,0},{0,1,0},{0,0,1}}},shift={0,0,0},scale=100}}
end
local component={vertices={1,2,3},triangles={{1,2,3}},bounds={0,0,0,10,10,0}}
local geometry={vertices=b,components={component}}
local r,n=record(obj,10),record(neighbor,5)
r.nodes={{record=r,geometry=geometry,component=component,lod=0}}
local node={record=n,geometry=geometry,component=component,lod=0}
local context={by_object={[obj]=r},index={Query=function()return {node}end}}
contexts[map]=context
assert(V.SeatingVerticalContact(map,obj,{0,0,10,10,10,10},10)==-4,'stop before cliff contact, not at ground')
node.unknown=true
assert(not V.SeatingVerticalContact(map,obj,{0,0,10,10,10,10},10),'unknown geometry must veto')
node.unknown=nil;node.partial=true
assert(not V.SeatingVerticalContact(map,obj,{0,0,10,10,10,10},10),'partial clipping must veto')
node.partial=nil;node.lod=1
assert(not V.SeatingVerticalContact(map,obj,{0,0,10,10,10,10},10),'alternate LOD is not an extra physical support')
node.lod=0;n.pose.matrix.origin[3]=20
assert(not V.SeatingVerticalContact(map,obj,{0,0,10,10,10,10},10),'support above must not pull rock upward')
print('PASS vertical first-contact sweep:',checks,'random boundaries; rooted-proof handoff and unknown/LOD guards')

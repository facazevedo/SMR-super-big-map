SuperBigMap={Engine={Global=function(k)if k=='guim'then return 1 end end}}
dofile('Code/sbm_decoration_geometry.lua');dofile('Code/sbm_decoration_validation.lua')
local V=SuperBigMap.DecorationValidation
local function up(fn,name)for i=1,100 do local k,v=debug.getupvalue(fn,i);if k==name then return v elseif not k then break end end end
local scan=up(V.Validate,'Scan');local contact=up(scan,'ComponentContact')
local g={vertices={{0,0,0},{1,0,0},{0,1,0},{0,0,.01},{1,0,.01},{0,1,.01}}}
local a={bounds={0,0,0,1,1,0},vertices={1,2,3},triangles={{1,2,3}}}
local b={bounds={0,0,.01,1,1,.01},vertices={4,5,6},triangles={{4,5,6}}}
local calls=0;local original=V.TrianglesContact
V.TrianglesContact=function(...)calls=calls+1;return original(...)end
local function pair(cols,origin)
 local r={pose={matrix={origin=origin or {0,0,0},columns=cols},shift={0,0,0},scale=100}}
 return {record=r,geometry=g,component=a},{record=r,geometry=g,component=b}
end
local an,bn=pair({{1,0,0},{0,1,0},{0,0,1}})
assert(contact(an,bn,.02),'nearby rendered triangles should contact')
local n=calls
an,bn=pair({{0,1,0},{-1,0,0},{0,0,1}},{10000,20000,30000})
assert(contact(an,bn,.02),'rigidly transformed contact lost')
assert(calls==n,'same-mesh contact should be reused across rigid instance transforms')
an,bn=pair({{3,0,0},{0,3,0},{0,0,3}})
assert(not contact(an,bn,.02),'different instance scale reused the wrong contact tolerance')
-- Bounds must account for all singular values, including a nonuniform transform.
an,bn=pair({{1,0,0},{0,1,0},{0,0,3}})
assert(not contact(an,bn,.02),'nonuniform transform falsely reused a positive contact')
-- A proof at a stricter distance remains a proof at a looser distance; do not
-- repeat the same asset triangle search for every top-up's distinct scale.
a.rigid_contacts=nil;b.rigid_contacts=nil
an,bn=pair({{1,0,0},{0,1,0},{0,0,1}})
assert(contact(an,bn,.02,true));n=calls
assert(contact(an,bn,.03,true))
assert(calls==n,'placement repeated a contact proof already valid at a stricter tolerance')
assert(contact(bn,an,.03,true) and calls==n,'reverse traversal repeated a symmetric contact proof')
local raw=up(contact,'RawComponentContact')
local tree=SuperBigMap.DecorationGeometry.TriangleTree
SuperBigMap.DecorationGeometry.TriangleTree=function()error('disjoint component boxes built a triangle hierarchy')end
local hit,separated=raw(an,bn,.001)
assert(not hit and separated,'disjoint component bounds did not provide complete separation')
SuperBigMap.DecorationGeometry.TriangleTree=tree
math.randomseed(332)
for trial=1,1000 do
 local scale=.1+math.random()*4;local angle=math.random()*6
 local c,s=math.cos(angle)*scale,math.sin(angle)*scale
 an,bn=pair({{c,s,0},{-s,c,0},{0,0,scale}},{123,456,789})
 local tolerance=.005+math.random()*.06
 local expected,sep=raw(an,bn,tolerance)
 local actual,separated=contact(an,bn,tolerance,true)
 assert((not not actual)==(not not expected),'monotone cache changed contact decision')
 if separated then assert(sep,'monotone cache invented negative separation')end
 -- Distinct object frames must still delegate to exact world-space contact.
 bn.record={pose={matrix={origin={123+math.random(),456,789},
  columns={{c,s,0},{-s,c,0},{0,0,scale}}},shift={0,0,0},scale=100}}
 expected,sep=raw(an,bn,tolerance)
 local separate,separate_sep=contact(an,bn,tolerance,true)
 assert(separate==expected and separate_sep==sep,'cross-object frames changed contact/separation')
end
-- Closed separated solids permit the converse reuse. Open triangle sheets
-- above deliberately did not provide a complete outside-volume witness.
local tetra={vertices={{0,0,0},{1,0,0},{0,1,0},{0,0,1},{0,0,2},{1,0,2},{0,1,2},{0,0,3}}}
local ta={bounds={0,0,0,1,1,1},vertices={1,2,3,4},triangles={{1,3,2},{1,2,4},{2,3,4},{3,1,4}}}
local tb={bounds={0,0,2,1,1,3},vertices={5,6,7,8},triangles={{5,7,6},{5,6,8},{6,7,8},{7,5,8}}}
an,bn=pair({{1,0,0},{0,1,0},{0,0,1}})
an.geometry,bn.geometry=tetra,tetra;an.component,bn.component=ta,tb
local hit,separated=contact(an,bn,.5,true)
assert(not hit and separated,'closed separate tetrahedra lack a negative witness')
n=calls;hit,separated=contact(an,bn,.2,true)
assert(not hit and separated and calls==n,'stricter separation needlessly repeated triangle tests')
assert(contact(an,bn,1.1,true),'looser tolerance reused an invalid negative proof')
print('contact cache: exact asset identity, rigid transform reuse, scale and metric-bound guards passed')

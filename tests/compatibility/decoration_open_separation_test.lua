SuperBigMap={Engine={Global=function(k)if k=='guim'then return 1 end end}}
dofile('Code/sbm_decoration_geometry.lua');dofile('Code/sbm_decoration_validation.lua')
local V=SuperBigMap.DecorationValidation
local function up(fn,name)
 for i=1,100 do local k,v=debug.getupvalue(fn,i);if k==name then return v elseif not k then break end end
end
local raw=up(up(up(V.Validate,'Scan'),'ComponentContact'),'RawComponentContact')
local function triangle(points)
 local b=SuperBigMap.DecorationGeometry.Bounds()
 for _,p in ipairs(points)do SuperBigMap.DecorationGeometry.Extend(b,p)end
 return {record={pose={matrix={origin={0,0,0},columns={{1,0,0},{0,1,0},{0,0,1}}},shift={0,0,0},scale=100}},
  geometry={vertices=points},component={bounds=b,vertices={1,2,3},triangles={{1,2,3}}}}
end
local a=triangle({{0,0,0},{2,0,0},{0,2,0}})
local b=triangle({{2,2,0},{3,2,0},{2,3,0}})
local geometry=SuperBigMap.DecorationGeometry
local volume=geometry.PointInClosedComponent
geometry.PointInClosedComponent=function()error('outside-vertex proof should precede expensive containment')end
local hit,separated=raw(a,b,.01)
assert(not hit and separated,'a later outside vertex must resolve the open-mesh containment ambiguity')
hit,separated=raw(b,a,.01)
assert(not hit and separated,'separation proof must be symmetric')
geometry.PointInClosedComponent=volume
b=triangle({{.2,.2,0},{.3,.2,0},{.2,.3,0}})
hit,separated=raw(a,b,.01)
assert(hit and not separated,'coplanar contact must never be dismissed by the new bounds proof')
b=triangle({{.5,.5,-1},{.5,.5,1},{1,1,0}})
hit,separated=raw(a,b,.01)
assert(hit and not separated,'crossing triangles must remain contacts')
b=triangle({{1,1,0},{1.2,1,0},{1,1.2,0}})
hit,separated=raw(a,b,.01)
assert(hit and not separated,'shared boundary contact must remain a contact')
a=triangle({{.3,.3,.3},{1.5,1.5,1.5},{1.6,1.5,1.5}})
b=triangle({{0,0,0},{2,0,0},{0,2,0}})
b.geometry.vertices[4]={0,0,2}
b.component={bounds={0,0,0,2,2,2},vertices={1,2,3,4},triangles={{1,3,2},{1,2,4},{1,4,3}}}
local surface_clear
hit,separated,surface_clear=raw(a,b,.01)
assert(not hit and not separated,'an unresolved open-mesh first-vertex enclosure must remain conservative')
assert(surface_clear,'a complete face search may authorize a guarded sweep without claiming closed-volume separation')
print('PASS complete triangle exclusion plus symmetric outside-vertex proof for open components')

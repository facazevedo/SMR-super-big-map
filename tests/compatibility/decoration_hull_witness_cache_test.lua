SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
local vertices={{0,0,0},{1,0,0},{0,1,0},{0,0,1}}
local component={bounds={0,0,0,1,1,1},vertices={1,2,3,4},triangles={{1,3,2},{1,2,4},{1,4,3},{2,3,4}}}
local proxy=setmetatable({},{__index=vertices})
local geometry={vertices=proxy,components={component}}
assert(G.PointOutsideComponentHull(geometry,component,{2,2,2}))
assert(component.outside_planes and #component.outside_planes>0,'complete separating witness was not retained')
setmetatable(proxy,{__index=function()error('repeated outside witness rescanned immutable mesh vertices')end})
assert(G.PointOutsideComponentHull(geometry,component,{3,3,3}))
setmetatable(proxy,{__index=vertices})
for i=1,1000 do
 local p={i%13/60,i%17/70,i%19/80}
 assert(p[1]+p[2]+p[3]<1)
 assert(not G.PointOutsideComponentHull(geometry,component,p),'cached half-space invented separation inside the convex hull')
end
-- Cached axes are only complete negative witnesses. An unrelated direction
-- falls through to the original full search; touching/boundary points are not
-- reclassified, and the cache remains bounded as query directions vary.
for i=1,200 do
 local p={math.cos(i)*3,math.sin(i)*3,math.sin(i*.17)*3}
 assert(G.PointOutsideComponentHull(geometry,component,p))
 assert(#component.outside_planes<=64)
end
for _,p in ipairs(vertices)do assert(not G.PointOutsideComponentHull(geometry,component,p))end
assert(not G.PointOutsideComponentHull(geometry,component,{.1,.12,.14}))
assert(component.interior_tetrahedra and component.interior_tetrahedra.hint,'strict interior tetrahedron was not retained')
setmetatable(proxy,{__index=function()error('proven interior rescanned immutable hull vertices')end})
assert(not G.PointOutsideComponentHull(geometry,component,{.11,.13,.15}))
setmetatable(proxy,{__index=vertices})
-- An interior hull certificate must never become a positive solid-volume
-- answer for an open authored mesh.
component.closed=false
assert(G.PointInClosedComponent(geometry,component,{.11,.13,.15})==nil)
-- Compare complete verdicts with the previous implementation on many points,
-- including near boundaries. Only the new interior shortcut is disabled in
-- the reference; full separating projections and all tolerances are identical.
local handle=assert(io.open('Code/sbm_decoration_geometry.lua'));local source=handle:read('*a');handle:close()
source=source:gsub('if HullInteriorWitness%(geometry,component,p,epsilon%) then return false end','if false then return false end')
assert(load(source,'reference geometry'))()
local reference=SuperBigMap.DecorationGeometry
math.randomseed(440)
for i=1,5000 do
 local p={math.random()*1.4-.2,math.random()*1.4-.2,math.random()*1.4-.2}
 assert(G.PointOutsideComponentHull(geometry,component,p)==reference.PointOutsideComponentHull(geometry,component,p),
  'interior shortcut changed the full separating-axis result')
end
print('convex support witnesses: immutable all-vertex separating planes reused; interior/boundary unknowns retained; bounded cache')

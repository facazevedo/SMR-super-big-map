SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
local g={vertices={{0,0,0},{10,0,0},{0,10,0},{0,0,10},{10,0,10},{0,10,10}}}
local c={bounds={0,0,0,10,10,10},vertices={1,2,3,4,5,6},triangles={{4,5,6}}}
assert(not G.ComponentRayClear(g,c,{2,2,5},{0,0,1}),'roof did not occlude an interior point')
assert(G.ComponentRayClear(g,c,{8,8,5},{0,0,1}),'empty part of a bounding box became a solid volume')
assert(G.ComponentRayClear(g,c,{2,2,11},{0,0,1}),'geometry behind the ray blocked visibility')
assert(not G.ComponentRayClear(g,c,{5,5,5},{0,0,1}),'edge contact was accepted as clear')
assert(not G.ComponentRayClear(g,c,{2,2,10},{1,0,0}),'coplanar ray was accepted as clear')
g.animated=true
assert(not G.ComponentRayClear(g,c,{8,8,5},{0,0,1}),'animated geometry used a static proof')
print('cosmetic visibility: exact roof hits, empty AABB regions, behind-ray rejection, edge/coplanar ambiguity and animation guards passed')

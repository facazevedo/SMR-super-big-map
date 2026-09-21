-- Support extrema/visibility need every distinct rendered position, not repeated
-- normal/UV seam vertices. Topology and the original vertex buffer stay intact.
SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
local g={vertices={{1,2,3},{1,2,3},{1+1e-13,2,3},{4,5,6},{4,5,6}}}
local c={vertices={1,2,3,4,5},triangles={{1,3,4},{2,3,5}}}
local v=G.SupportVertices(g,c)
assert(#v==3 and v[1]==1 and v[2]==3 and v[3]==4,'only exact duplicate positions may be elided')
assert(#c.vertices==5 and c.triangles[2][3]==5 and #g.vertices==5,'native topology or geometry changed')
assert(G.SupportVertices(g,c)==v,'shared immutable component positions should be cached')
local other={vertices={5,3,1}}
assert(#G.SupportVertices(g,other)==3,'components must not share deduplication state')
print('support vertices: exact-only deduplication, stable order, cached identity and unchanged topology passed')

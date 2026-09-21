-- Complete triangle intervals may prove a gap on a slope even when a whole
-- fragment's min Z is below the maximum terrain under a different corner.
SuperBigMap={Engine={Global=function()return nil end}}
dofile('Code/sbm_decoration_geometry.lua')
local prove=SuperBigMap.DecorationGeometry.TrianglesAboveTerrain
assert(type(prove)=='function','missing complete terrain interval proof')
local triangles={{{0,0,10},{100,0,110},{0,100,10}}}
local function slope(b)return b[4]end
assert(prove(triangles,slope,3),'ten-unit parallel-slope gap was not proved')
local crossing={{{0,0,10},{100,0,90},{0,100,10}}}
assert(not prove(crossing,slope,3),'intersecting slope falsely proved separated')
local crest={{{0,0,10},{100,0,10},{0,100,10}}}
local function interior_peak(b)
 return b[1]<=30 and b[4]>=30 and b[2]<=30 and b[5]>=30 and 20 or 0
end
assert(not prove(crest,interior_peak,3),'interior terrain crest ignored')
assert(not prove(triangles,function()return nil end,3),'missing terrain certified')
assert(not prove({},slope,3),'empty geometry certified')
assert(not prove(triangles,slope,3,0),'exhausted budget certified')
assert(not prove(triangles,slope,11),'error margin ignored')
assert(not prove(triangles,function()return 0/0 end,3),'nonfinite terrain certified')
print('terrain intervals: complete slope proof, interior collision and missing/bounded coverage passed')

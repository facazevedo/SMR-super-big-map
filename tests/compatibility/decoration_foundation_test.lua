SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
local function mesh()
 local g={vertices={{0,0,0},{10,0,0},{10,10,0},{0,10,0},{0,0,10},{10,0,10},{10,10,10},{0,10,10}}}
 local c={bounds={0,0,0,10,10,10},vertices={1,2,3,4,5,6,7,8},triangles={
  {1,2,6},{1,6,5},{2,3,7},{2,7,6},{3,4,8},{3,8,7},{4,1,5},{4,5,8},{5,6,7},{5,7,8}}}
 return g,c
end
local g,c=mesh();local rim=assert(G.FoundationBoundary(g,c))
assert(G.SegmentInsideRenderedBody(g,c,{2,2,4},{8,8,6}),'upper body of open-bottom rock rejected')
assert(G.PointInClosedComponent(g,c,{2,2,4})==nil,'ordinary closed-volume proof was weakened')
assert(not G.SegmentInsideRenderedBody(g,c,{2,2,-1},{8,8,6}),'segment below an open base inferred a solid')
assert(not G.SegmentInsideRenderedBody(g,c,{2,2,4},{12,8,6}),'segment outside actual sides accepted')
assert(#rim.edges==4 and #rim.vertices==4,'open base was not recognized')
assert(G.FoundationBoundary(g,c)==rim,'immutable mesh boundary should be cached')
g,c=mesh();c.triangles[#c.triangles+1]={1,3,2};c.triangles[#c.triangles+1]={1,4,3}
assert(not G.FoundationBoundary(g,c),'closed rock must not invent an open foundation')
g,c=mesh();table.remove(c.triangles,1)
assert(not G.FoundationBoundary(g,c),'a side hole must not be treated as a bottom rim')
assert(not G.SegmentInsideRenderedBody(g,c,{2,2,4},{8,8,6}),'body with an unclosed side granted containment')
do
 local g,c=mesh();c.triangles[#c.triangles+1]={1,3,2};c.triangles[#c.triangles+1]={1,4,3}
 local faces=#c.triangles
 for i=1,8 do local p=g.vertices[i];g.vertices[i+8]={p[1]+20,p[2],p[3]};c.vertices[#c.vertices+1]=i+8 end
 for i=1,faces do local t=c.triangles[i];c.triangles[#c.triangles+1]={t[1]+8,t[2]+8,t[3]+8} end
 c.bounds={0,0,0,30,10,10}
 assert(G.PointInClosedComponent(g,c,{5,5,5}) and G.PointInClosedComponent(g,c,{25,5,5}))
 assert(not G.SegmentInsideRenderedBody(g,c,{5,5,5},{25,5,5}),'interior endpoints hid an exposed middle segment')
end
g,c=mesh();g.vertices[1][3]=1
assert(not G.FoundationBoundary(g,c),'boundary outside the bottom band must fail conservatively')
g,c=mesh();g.animated=true
assert(not G.FoundationBoundary(g,c),'animated geometry may not use a static boundary cache')
g,c=mesh();g.vertices[9]={0,0,0};c.vertices[#c.vertices+1]=9;c.triangles[1][1]=9
assert(G.FoundationBoundary(g,c),'UV/normal duplicates must weld by position')
local gap=G.FoundationClearance({{1,5,-2},{29,5,-2}},{{1,2}},function(x)return x==10 and -10 or 0 end,10,100,100)
assert(math.abs(gap-8)<1e-9,'buried endpoints hid an exposed edge over a terrain valley')
gap=G.FoundationClearance({{5,5,12},{25,15,42}},{{1,2}},function(x,y)return x+y end,10,100,100)
assert(math.abs(gap-2)<1e-9,'sloped terrain clearance changed between cell/diagonal crossings')
assert(not G.FoundationClearance({{1,5,0},{29,5,0}},{{1,2}},function()return nil end,10,100,100),'missing terrain accepted')
assert(not G.FoundationClearance({{-1,5,0},{29,5,0}},{{1,2}},function()return 0 end,10,100,100),'out-of-map foundation accepted')
for n=1,100 do
 local points={{1,5,n%19},{79,65,n%31},{65,1,n%13}}
 local edges={{1,2},{2,3},{3,1}}
 local function terrain(x,y)return (x*3+y*7+n)%23 end
 local full=assert(G.FoundationClearance(points,edges,terrain,10,100,100))
 for _,budget in ipairs({full-1,full,full+1})do
  local bounded=G.FoundationClearance(points,edges,terrain,10,100,100,budget)
  assert((full>budget and bounded==nil) or bounded==full,'early rejection changed an accepted full-rim proof')
 end
end
for n=1,100 do
 local f={points={{41.1,45.2,n%19},{119.4,105.3,n%31},{105.7,41.6,n%13}},edges={{1,2},{2,3},{3,1}},tile=10,width=200,height=200}
 local function terrain(x,y)return (x*3+y*7+n)%23 end
 for _,d in ipairs({{10,20},{-20,-30},{20,-10},{.5,1.25}})do
  local shifted={};for i,p in ipairs(f.points)do shifted[i]={p[1]+d[1],p[2]+d[2],p[3]}end
  local reference=assert(G.FoundationClearance(shifted,f.edges,terrain,10,200,200))
  local fast=assert(G.FoundationTranslationClearance(f,d[1],d[2],terrain))
  assert(math.abs(fast-reference)<1e-9,'translated stencil differs from complete shifted edge proof')
  assert(not G.FoundationTranslationClearance(f,d[1],d[2],terrain,reference-1),'stencil accepted an over-budget edge')
 end
 assert(f.translation_stencil,'integer translations did not reuse a geometric stencil')
 assert(not G.FoundationTranslationClearance(f,-100,0,terrain),'stencil accepted out-of-map terrain')
 assert(not G.FoundationTranslationClearance(f,0,0,function()return nil end),'stencil accepted missing terrain')
end
do
 local f={points={{1,1,3},{8,2,5},{7,8,9}},edges={{1,2},{2,3},{3,1}},tile=10,width=100,height=100}
 local calls=0
 local function terrain(x,y)calls=calls+1;return x+y end
 local first=assert(G.FoundationTranslationClearance(f,10,10,terrain))
 assert(calls==4,'one terrain cell was reread for each rim crossing')
 local second=assert(G.FoundationTranslationClearance(f,10,10,function(x,y)return x+y+7 end))
 assert(math.abs(second-first+7)<1e-9,'cell heights leaked into a later destination inspection')
 assert(not G.FoundationTranslationClearance(f,10,10,function()return 0/0 end),'nonfinite corner accepted')
end
print('foundation geometry: open bottom loops only, welded seams, full terrain crossings and conservative unknowns passed')

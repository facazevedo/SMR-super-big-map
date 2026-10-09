SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua')
local actual=SuperBigMap.DecorationGeometry.TrianglesAboveHeightfield
local reference=dofile('tests/compatibility/fixtures/heightfield_reference.lua')
math.randomseed(57168)
for i=1,1000 do
 local ox=i%2==0 and 450000 or 0
 local samples={}
 for x=0,100,10 do for y=0,100,10 do samples[(x+ox)..':'..y]=math.random(-100,100) end end
 local function height(x,y)return samples[x..':'..y]end
 local triangles={}
 for j=1,4 do
  local t={}
  for k=1,3 do t[k]={ox+math.random(11,88),math.random(11,88),math.random(-200,300)} end
  triangles[j]=t
 end
 -- Include degenerate projections, repeated faces, exact boundaries, positive
 -- floats, holes in terrain data and exhausted work budgets.
 if i%3==0 then triangles[2]=triangles[1] end
 if i%5==0 then for _,t in ipairs(triangles)do for _,p in ipairs(t)do p[3]=500 end end end
 if i%7==0 then triangles[1][1][1]=ox+20;triangles[1][2][1]=ox+20;triangles[1][3][1]=ox+20 end
 if i%11==0 then samples[(ox+40)..':40']=nil end
 local margin=i%4==0 and 0 or .2
 local budget=i%13==0 and 20 or 65536
 for _,mode in ipairs({false,true,'positive'})do
  local a,b,c=reference(triangles,height,10,ox+110,110,margin,budget,mode)
  local x,y,z=actual(triangles,height,10,ox+110,110,margin,budget,mode)
  assert(a==x and b==y and c==z,'exact result/extrema parity '..i..' '..tostring(mode))
 end
end
local triangles={}
for i=1,50 do triangles[i]={{10,10,50},{80,20,50},{20,80,50}} end
local slow,fast=0,0
assert(reference(triangles,function()slow=slow+1;return 0 end,10,100,100,0,65536,true))
assert(actual(triangles,function()fast=fast+1;return 0 end,10,100,100,0,65536,true))
assert(fast*40<slow,'repeated mesh faces must reuse exact terrain cells')
assert(not actual(triangles,function()return 100 end,10,100,100,0,65536,'positive'),
 'cache must be discarded before a later terrain query')
print('heightfield cells: exact old-algorithm parity, bounded work, query reuse and no cross-call cache')

-- Cells outside a face's XY footprint can skip clipping, including thin,
-- reversed and degenerate faces. Expanded diagonal planes require 3x XY padding.
for _,triangle in ipairs({{{20,20,50},{80,80,70},{81,80,80}},
 {{20,20,50},{81,80,80},{80,80,70}},{{20,20,50},{20,80,70},{20,30,80}}}) do
 for _,margin in ipairs({0,.2,3,12}) do
  for _,mode in ipairs({false,true,'positive'}) do
   local query=function(x,y)return (x*3+y*7)%13 end
   local a,b,c=reference({triangle},query,10,200,200,margin,65536,mode)
   local x,y,z=actual({triangle},query,10,200,200,margin,65536,mode)
   assert(a==x and b==y and c==z,'cell separation changed clipped extrema')
  end
 end
end
print('heightfield cell separation: expanded diagonal planes, reversed winding and zero-area projections passed')

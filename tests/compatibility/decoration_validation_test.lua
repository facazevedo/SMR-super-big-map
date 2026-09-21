SuperBigMap={Engine={Global=function()return nil end}}
dofile('Code/sbm_decoration_geometry.lua')
dofile('Code/sbm_decoration_validation.lua')
local V=SuperBigMap.DecorationValidation
local index=V.Index(10)
local a,b={bounds={-20,-20,0,0,0,1}},{bounds={100,100,0,101,101,1}}
index:Add(a);index:Add(b)
assert(#index:Query({-1,-1,0,1,1,1},0)==1)
assert(#index:Query({50,50,0,51,51,1},0)==0)
assert(#index:Query({100,100,30,101,101,31},0)==0,'exclude distant Z despite same bucket')
local large={bounds={0,0,0,1000,1000,1}};index:Add(large)
assert(#index.large==1 and #index:Query({500,500,0,501,501,1},0)==1)
-- Selection over an unchanged union of regions visits each matching object
-- once, with exactly the same first-encounter order as individual queries.
local regions={{-1,-1,0,1,1,1},{100,100,0,101,101,1},{500,500,0,501,501,1},
 {100,100,30,101,101,31},{-30,-30,0,0,0,1}}
local expected,expected_seen,actual,seen={},{},{},{}
for _,r in ipairs(regions)do for _,n in ipairs(index:Query(r,2))do
 if not expected_seen[n]then expected_seen[n]=true;expected[#expected+1]=n end
end end
for _,r in ipairs(regions)do index:QueryOnce(r,2,seen,function(n)actual[#actual+1]=n end)end
assert(#actual==#expected)
for i,n in ipairs(expected)do assert(actual[i]==n,'union query changed selection/order')end
assert(#index:Query({-1,-1,0,1,1,1},0)==2,'union query must not consume ordinary index entries')
math.randomseed(339)
local random_index=V.Index(10)
for i=1,150 do
 local x,y,z=math.random(-50,50),math.random(-50,50),math.random(-50,50)
 random_index:Add({bounds={x,y,z,x+math.random(0,200),y+math.random(0,200),z+math.random(0,30)}})
end
expected,expected_seen,actual,seen={},{},{},{}
for i=1,200 do
 local x,y,z=math.random(-70,150),math.random(-70,150),math.random(-70,70)
 local r={x,y,z,x+math.random(0,40),y+math.random(0,40),z+math.random(0,40)}
 local pad=i%5
 for _,n in ipairs(random_index:Query(r,pad))do
  if not expected_seen[n]then expected_seen[n]=true;expected[#expected+1]=n end
 end
 random_index:QueryOnce(r,pad,seen,function(n)actual[#actual+1]=n end)
end
assert(#actual==#expected)
for i,n in ipairs(expected)do assert(actual[i]==n,'randomized union changed selection/order')end
local t={{0,0,0},{10,0,0},{0,10,0}}
assert(V.TriangleDistanceSquared({1,1,2},table.unpack(t))==4)
assert(V.TriangleDistanceSquared({-1,0,0},table.unpack(t))==1)
local cross_a={{-10,0,0},{10,0,0},{0,-10,0}}
local cross_b={{0,-5,1},{0,5,1},{0,0,11}}
assert(math.abs(V.TrianglePairDistanceSquared(cross_a,cross_b)-1)<1e-10,'near skew edges need an interior-distance witness')
assert(V.TrianglePairDistanceSquared(t,{{1,1,-2},{1,1,2},{2,1,0}})==0,'intersecting triangles have zero distance')
assert(V.TrianglePairDistanceSquared(t,{{0,0,5},{10,0,5},{0,10,5}})==25,'separated parallel faces')
assert(V.TrianglesContact(cross_a,cross_b,1),'interior edge distance at the tolerance remains accepted')
assert(not V.TrianglesContact(cross_a,cross_b,0.99),'near edges outside tolerance stay separated')
assert(V.TrianglesContact(t,{{1,1,-2},{1,1,2},{2,1,0}},0),'intersection cannot be pruned')
math.randomseed(204403908)
for sample=1,2000 do
 local a,b={},{}
 for i=1,3 do a[i]={};b[i]={};for j=1,3 do a[i][j]=math.random(-20,20)/4;b[i][j]=math.random(-20,20)/4 end end
 local tolerance=sample%7/10
 assert(V.TrianglesContact(a,b,tolerance)==(V.TrianglePairDistanceSquared(a,b)<=tolerance*tolerance),
  'separating-axis optimization must agree with exhaustive distance')
end
assert(V.Classify({{supported=true}},true,false)=='valid')
assert(V.Classify({{supported=true}},false,false)=='inconclusive','missing geometry must not pass')
assert(V.Classify({{supported=false}},true,false)=='inconclusive','sample misses not defects')
assert(V.Classify({{supported=false,defect=true,reason='separated'}},true,false)=='confirmed defect')
assert(V.Classify({},true,false)=='inconclusive','no geometry is not valid')
assert(V.Classify({{supported=true}},true,true)=='confirmed defect','broken attachment')
print('decoration validation: spatial indexing, exact triangle witnesses, conservative three-way classification passed')

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
local t={{0,0,0},{10,0,0},{0,10,0}}
assert(V.TriangleDistanceSquared({1,1,2},table.unpack(t))==4)
assert(V.TriangleDistanceSquared({-1,0,0},table.unpack(t))==1)
assert(V.Classify({{supported=true}},true,false)=='valid')
assert(V.Classify({{supported=true}},false,false)=='inconclusive','missing geometry must not pass')
assert(V.Classify({{supported=false}},true,false)=='inconclusive','sample misses not defects')
assert(V.Classify({{supported=false,defect=true,reason='separated'}},true,false)=='confirmed defect')
assert(V.Classify({},true,false)=='inconclusive','no geometry is not valid')
assert(V.Classify({{supported=true}},true,true)=='confirmed defect','broken attachment')
print('decoration validation: spatial indexing, exact triangle witnesses, conservative three-way classification passed')

SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
local seen={};local calls=0
local function height(x,y)
 assert(x%1==0 and y%1==0)
 local key=x..':'..y;assert(not seen[key]);seen[key]=true;calls=calls+1
 return x==3 and y==6 and 99 or x-y
end
local bound=G.IntegerTerrainUpper({2.2,3.1,0,4.6,6.2,1},height,100,100,1,1024)
assert(bound==101 and calls==42,'complete padded integer footprint or height rounding budget lost')
for x=1,6 do for y=2,8 do assert(seen[x..':'..y],'integer terrain point omitted')end end
local reached=false
assert(not G.IntegerTerrainUpper({0,0,0,50,50,1},function()reached=true end,100,100,2,1024))
assert(not reached,'large unbounded height walk must not start')
for _,bad in ipairs({false,0/0,math.huge,-math.huge}) do
 assert(not G.IntegerTerrainUpper({1,1,0,2,2,1},function()return bad end,10,10,1,1024))
end
calls=0
assert(G.IntegerTerrainUpper({-.5,-.5,0,1,1,1},function(x,y)
 assert(x>=0 and y>=0 and x<2 and y<2);calls=calls+1;return 0
end,2,2,1,1024)==2 and calls==4)
print('integer terrain bound: exhaustive footprint, native-coordinate clamp, bounded work, missing/nonfinite veto')

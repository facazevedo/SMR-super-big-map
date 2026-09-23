SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
local width,height=137,119
local seen,allowed,calls={},nil,0
local function value(x,y)return (x*337+y*29+x*y*7)%301-150 end
local cached=G.CachedIntegerTerrainUpper(function(x,y)
 assert(x%1==0 and y%1==0 and x>=0 and y>=0 and x<width and y<height)
 assert(allowed[x+y*width],'cache read outside the exact requested rectangle')
 assert(not seen[x+y*width],'cache re-read an immutable native height')
 seen[x+y*width]=true;calls=calls+1;return value(x,y)
end,width,height)
local rng=12345
local function rand(n)rng=(rng*48271)%2147483647;return rng%n end
for i=1,6000 do
 local x,y=rand(155)-8,rand(135)-8
 local rect={x+.2,y+.8,0,x+rand(35)+.4,y+rand(35)+.3,100}
 local padding=rand(5);allowed={}
 local exact=G.IntegerTerrainUpper(rect,function(a,b)allowed[a+b*width]=true;return value(a,b)end,width,height,padding,1024)
 assert(cached(rect,padding,1024)==exact,'cached terrain maximum differs from exhaustive oracle')
 assert(cached(rect,padding,1024)==exact,'overlapping cached query changed result')
end
assert(calls<=width*height)
for _,bad in ipairs({false,0/0,math.huge,-math.huge}) do
 for _,at in ipairs({{3,3},{0,3},{3,0}}) do
  local f=G.CachedIntegerTerrainUpper(function(x,y)if x==at[1] and y==at[2] then return bad end;return 7 end,10,10)
  assert(f({0,0,0,3,3,1},0,1024)==nil,'invalid block/row/column was accepted')
  assert(f({0,0,0,3,3,1},0,1024)==nil,'cached invalid block was accepted')
 end
end
local changed=G.CachedIntegerTerrainUpper(function()return 80 end,10,10)
assert(changed({0,0,0,3,3,1},0,1024)==82,'cache leaked between terrain transactions')
print('terrain cache: 12000 exact oracle comparisons, footprint/unique-read guards, invalid blocks and transaction isolation')

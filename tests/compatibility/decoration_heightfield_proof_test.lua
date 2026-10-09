SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua')
local prove=SuperBigMap.DecorationGeometry.TrianglesAboveHeightfield
local function plane(x,y)return x*.5+y*.25 end
local function triangle(gap)
 local t={}
 for _,p in ipairs({{15,12},{85,30},{40,89}}) do t[#t+1]={p[1],p[2],plane(p[1],p[2])+gap} end
 return {t}
end
assert(prove(triangle(.2),plane,10,100,100,.01),'correlated slope proof lost a separated parallel triangle')
assert(not prove(triangle(.2),plane,10,100,100,.2),'XY/Z uncertainty must not be ignored')
assert(not prove(triangle(0),plane,10,100,100,0),'exact terrain contact is not separation')
assert(not prove(triangle(-.1),plane,10,100,100,0),'penetrating triangle is not separation')
assert(not prove(triangle(10),function(x,y)if x==40 and y==40 then return 1000 end return plane(x,y)end,10,100,100,0),
 'interior terrain peak missed by mesh vertices must veto proof')
assert(not prove(triangle(10),function()return nil end,10,100,100,0),'missing terrain must fail closed')
assert(not prove(triangle(10),plane,10,100,100,0,1),'budget exhaustion must fail closed')
local _,low,high=prove(triangle(.2),plane,10,100,100,0,4096,true)
assert(math.abs(low-.2)<1e-8 and math.abs(high-.2)<1e-8,'complete plane clearance extrema')
_,low,high=prove(triangle(-.2),plane,10,100,100,0,4096,true)
assert(math.abs(low+.2)<1e-8 and math.abs(high+.2)<1e-8,'penetrating extrema remain available to the planner')
_,low=prove(triangle(10),plane,10,100,100,0,1,true)
assert(low==nil,'partial extrema from an exhausted scan must not authorize placement')
assert(not prove({{{-1,0,10},{1,0,10},{0,1,10}}},plane,10,100,100,0),'out-of-map proof must fail closed')
-- Cell diagonal matters: the lower and upper planes differ on this saddle.
local function saddle(x,y)return x==10 and y==10 and 100 or 0 end
assert(prove({{{2,1,20},{3,1,20},{3,2,30}}},saddle,10,100,100,0))
assert(not prove({{{2,1,5},{3,1,5},{3,2,5}}},saddle,10,100,100,0))
math.randomseed(409)
for i=1,500 do
 local gx,gy=(math.random()-.5)*4,(math.random()-.5)*4
 local error=.01+math.random();local margin=error*(1+math.abs(gx)+math.abs(gy))
 local gap=margin+(i%2==0 and .1 or -.1)
 local function h(x,y)return 500+gx*x+gy*y end
 local t={}
 for _,p in ipairs({{15,15},{80,25},{30,80}}) do t[#t+1]={p[1],p[2],h(p[1],p[2])+gap} end
 assert(prove({t},h,10,100,100,error)==(i%2==0),'slope/uncertainty oracle mismatch '..i)
end
print('heightfield proof: full triangle clipping, native diagonal, terrain peaks, numerical bounds and fail-closed limits')

-- Proposal-only mode retains exactly the full scan's positive result/extrema.
-- Negative scans stop at their first counterexample and expose no partial gap.
local full_queries,fast_queries=0,0
local touching=triangle(-.2)
local full,lo,hi=prove(touching,function(x,y)full_queries=full_queries+1;return plane(x,y)end,10,100,100,0,65536,true)
local fast,a,b=prove(touching,function(x,y)fast_queries=fast_queries+1;return plane(x,y)end,10,100,100,0,65536,'positive')
assert(not full and not fast and a==nil and b==nil)
assert(fast_queries<full_queries/4,'nonpositive witness must stop redundant clearance work')
assert(lo<0 and hi<0,'full extrema mode must still finish penetrating meshes')
math.randomseed(570168)
for i=1,400 do
 local samples={}
 for x=0,100,10 do for y=0,100,10 do samples[x..':'..y]=math.random(-50,50) end end
 local function h(x,y)return samples[x..':'..y]end
 local faces={}
 for j=1,3 do
  local t={}
  for k=1,3 do t[k]={math.random(10,85),math.random(10,85),math.random(-80,100)+(i%2==0 and 150 or 0)} end
  faces[j]=t
 end
 local budget=i%7==0 and 1 or 65536
 local old,low,high=prove(faces,h,10,110,110,0,budget,true)
 local new,l,u=prove(faces,h,10,110,110,0,budget,'positive')
 assert(old==new,'proposal parity on rough terrain '..i)
 if old then assert(low==l and high==u,'positive extrema must remain complete '..i)
 else assert(l==nil and u==nil,'failed proposal must not publish a partial clearance') end
end
assert(not prove(triangle(10),function()return nil end,10,100,100,0,65536,'positive'))
print('positive clearance: randomized full-scan parity, complete extrema, early counterexample and failed-proof isolation')

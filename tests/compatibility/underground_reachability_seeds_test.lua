local f=assert(io.open('Code/sbm_deposits.lua','r'));local source=f:read('*a');f:close()
local block=assert(source:match('(local function BuildUndergroundReachability%(map%).-)\n%-%- Evaluate the immutable'))
local function fixture(edges, seeds, mode, fail_seed_queries)
  local calls, points={},{}
  for i=1,#edges do points[i]={id=i,SetTerrainZ=function(self)return self end} end
  local state={legacy_pathfinder_pass_version=1}
  local globals={const={HexSize=1},WorldToHex=function(p)return p.id,0 end}
  local function query(map,a,b,class,radius)
    assert(class==1 and (radius==nil or radius==0))
    calls[#calls+1]={a.id,b.id}
    if fail_seed_queries and b.id<=#seeds then error('path service failure')end
    if mode=='pf' then return edges[a.id][b.id] or false end
    return edges[a.id][b.id] and 0 or -1
  end
  if mode=='pf' then globals.pf={HasPosPath=query} else globals.ConnectivityCheck=query end
  local map={PassVersion=1,MapForEach=function(self,scope,class,fn)
    if class=='UndergroundPassageBase' then for _,i in ipairs(seeds)do fn(points[i])end end
  end}
  local env=setmetatable({SuperBigMap={State=state},underground_reachability_by_map={},
    IsUndergroundMap=function()return true end,ObjectPos=function(p)return p end,
    Global=function(k)return globals[k]end},{__index=_G})
  local build,check=assert(load(block..'\nreturn BuildUndergroundReachability,IsReachableFromUndergroundEntrance','production reachability','t',env))()
  return build,check,map,points,calls,state
end
local function closure(n,arcs)
  local e={};for a=1,n do e[a]={[a]=true}end
  for _,v in ipairs(arcs)do e[v[1]][v[2]]=true end
  for k=1,n do for a=1,n do for b=1,n do if e[a][k]and e[k][b]then e[a][b]=true end end end end
  return e
end
-- Disconnected and one-way entrances remain semantically distinct. Reverse-only
-- reachability cannot make an earlier seed cover a later one.
for _,mode in ipairs({'distance','pf'})do
  local edges=closure(7,{{1,2},{2,4},{3,1},{3,5}})
  local build,check,map,p,calls,state=fixture(edges,{1,2,3},mode)
  local s=build(map)
  assert(#s.seeds==3 and #s.query_seeds==2 and s.query_seeds[1]==p[1]and s.query_seeds[2]==p[3])
  assert(check(map,p[4])and check(map,p[5])and not check(map,p[6]))
  local before=#calls;assert(not check(map,p[6])and #calls==before,'negative cache lost')
  -- A changed pass grid or tunnel version must discard both path answers and
  -- entrance dominance proofs, including when the game clock is paused.
  edges[3][5]=nil;map.PassVersion=2
  assert(not check(map,p[5])and build(map)~=s)
  edges[3][5]=true;state.legacy_pathfinder_pass_version=2
  assert(check(map,p[5]))
end
do
  local build,check,map,p=fixture(closure(4,{{1,2},{2,3}}),{1,2},'distance',true)
  local s=build(map);assert(#s.query_seeds==2 and s.failures>0)
  assert(check(map,p[3]),'unknown seed relation discarded a valid entrance')
end
-- Compare the production reduction with an independent all-entrance OR over
-- arbitrary directed graphs, including disconnected islands and cycles.
math.randomseed(1197)
local comparisons=0
for trial=1,600 do
  local n=math.random(5,20);local arcs={}
  for a=1,n do for b=1,n do if a~=b and math.random()<0.07 then arcs[#arcs+1]={a,b}end end end
  local edges=closure(n,arcs);local seeds={}
  for a=1,math.random(1,math.min(n,8))do seeds[a]=a end
  local build,check,map,p=fixture(edges,seeds,trial%2==0 and 'pf' or 'distance')
  local s=build(map);assert(#s.seeds==#seeds,'geometry consumers lost original entrances')
  for target=1,n do
    local expected=false
    for _,a in ipairs(seeds)do expected=expected or edges[a][target]==true end
    assert(check(map,p[target])==expected,'directed reachability changed')
    comparisons=comparisons+1
  end
end
print('underground entrance dominance: '..comparisons..' directed-graph comparisons, cache invalidation and failed-query fallback passed')

-- Ranged exclusions must contain no reachable endpoint, use full 3D distance,
-- require explicit negative evidence, and expire with the passability proof.
do
  local points={}
  local function point(x,y,z)
    local p={x=x,y=y,z=z};p.xyz=function(self)return self.x,self.y,self.z end
    p.SetTerrainZ=function(self)return self end
    points[#points+1]=p;return p
  end
  local entrance=point(0,0,0)
  local unreachable=point(100000,100000,0)
  local nearby=point(108000,108000,0)
  local high=point(108000,108000,20000)
  local reachable={[entrance]=true,[high]=true}
  local exact_calls,range_calls=0,0
  local uncertain=false
  local globals={WorldToHex=function(p)return p.x,p.y+p.z*100 end,const={HexSize=1000}}
  globals.ConnectivityCheck=function(map,a,b,class,radius)
    exact_calls=exact_calls+1;return reachable[b] and 1 or -1
  end
  globals.pf={PosPathLen=function(map,a,b,class,radius)
    range_calls=range_calls+1
    if uncertain then return nil end
    for p in pairs(reachable)do
      local dx,dy,dz=p.x-b.x,p.y-b.y,p.z-b.z
      if dx*dx+dy*dy+dz*dz<=radius*radius then return true,1 end
    end
    return false
  end}
  local map={SuperBigMapLegacyPathfinder=true,PassVersion=1,
    MapForEach=function(self,scope,class,fn)if class=='UndergroundPassageBase'then fn(entrance)end end}
  local env=setmetatable({SuperBigMap={State={}},underground_reachability_by_map={},
    IsUndergroundMap=function()return true end,ObjectPos=function(p)return p end,
    Global=function(k)return globals[k]end},{__index=_G})
  local build,check=assert(load(block..'\nreturn BuildUndergroundReachability,IsReachableFromUndergroundEntrance','production ranged reachability','t',env))()
  assert(not check(map,unreachable)and exact_calls==1 and range_calls==1)
  assert(not check(map,nearby)and exact_calls==1 and build(map).region_hits==1)
  assert(check(map,high)and exact_calls==2,'2D region incorrectly hid a reachable elevated point')
  reachable[nearby]=true;map.PassVersion=2
  assert(check(map,nearby),'passability change retained an obsolete negative sphere')
  uncertain=true;reachable[nearby]=nil;map.PassVersion=3
  assert(not check(map,unreachable))
  local before=exact_calls;assert(not check(map,nearby)and exact_calls==before+1,'nil range result became a certificate')
  assert(not build(map).negative_regions)
end
print('native ranged negative certificates: exact 3D containment, invalidation and unknown-result fallback passed')

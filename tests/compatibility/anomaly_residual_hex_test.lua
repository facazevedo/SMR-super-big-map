local file = assert(io.open('Code/sbm_deposits.lua', 'r'))
local source = file:read('*a'); file:close()
local block = assert(source:match('(function DepositRules.BuildSurfaceResidualHexCandidates.-)\nfunction DepositRules.TopUpAnomalies'))
local map, ctx, terrain_calls = {}, {}, 0
local origin_x, origin_y = 0, 0
local function point(x, y) return {x=x, y=y} end
local api = {
  point=point,
  WorldToHex=function(p)
    local r=(p.y-origin_y)/10
    return math.floor((p.x-origin_x)/10-r/2), math.floor(r)
  end,
  HexToWorld=function(q,r) return origin_x+(q+r/2)*10, origin_y+r*10 end,
}
local env = setmetatable({DepositRules={}, Global=function(k)return api[k]end,
  IsUndergroundMap=function(m)return m.underground end,
  SectorAtPoint=function(_,x,y) return {status=x-origin_x>=40 and 'scanned' or 'unexplored'} end,
  SectorIsScanned=function(s)return s.status=='scanned'end,
  IsBuildableAt=function(m,p,strict,c)assert(m==map and c==ctx and strict==true);return true end,
  CanReceiveDeposit=function(m,p,c)
    assert(m==map and c==ctx);terrain_calls=terrain_calls+1
    local valid=not(p.x-origin_x==15 and p.y-origin_y==10)
    return valid,valid,100,valid,nil,nil,valid
  end,
  ValleyScore=function()return 1,2,3 end,
  IsMountainBaseRelief=function(a,b,c)assert(a==1 and b==2 and c==3);return true end,
}, {__index=_G})
assert(load(block,'production finite residual hex search','t',env))()
local search=env.DepositRules.BuildSurfaceResidualHexCandidates
local function run()
  local visited={}
  local c,s=search(map,ctx,{x0=origin_x,y0=origin_y,x1=origin_x+50,y1=origin_y+50},function(p)
    local key=p.q..':'..p.r
    assert(not visited[key],'hex visited twice');visited[key]=true
    assert(p.x>=origin_x and p.x<origin_x+50 and p.y>=origin_y and p.y<origin_y+50,'outside bounds')
    return key=='-1:3' or key=='3:1' or key=='1:1' or key=='4:0'
  end)
  assert(s.visited==25 and s.terrain_checks==3 and s.accepted==2,'finite coverage or validators changed')
  local positions={};for _,p in ipairs(c)do positions[p.q..':'..p.r]=true;assert(p._sbm_terrain_valid and p.mountain_base)end
  assert(positions['-1:3'] and positions['3:1'],'missed narrow legal pockets or axial skew')
end
run();origin_x,origin_y=137,-81;run()
local c,s=search(map,ctx,{x0=137,y0=-81,x1=187,y1=-31},function()return false end)
assert(#c==0 and s.visited==25 and s.terrain_checks==0,'impossible search must finish without relaxing rejection')
local exclusions={[-1]={{-5,2},{4,20}},[0]={{1,2}},[1]={{-4,0},{3,4}},[3]={{0,1}},[5]={{-99,99}}}
local function accept(p)
  for _,interval in ipairs(exclusions[p.q]or{})do if p.r>=interval[1] and p.r<=interval[2]then return false end end
  return true
end
local bounds={x0=137,y0=-81,x1=187,y1=-31}
local reference=search(map,ctx,bounds,accept)
local optimized,optimized_stats=search(map,ctx,bounds,accept,exclusions)
assert(#reference==#optimized and optimized_stats.repulsion_skipped>0,'interval traversal changed candidate count')
for i,p in ipairs(reference)do
  assert(p.q==optimized[i].q and p.r==optimized[i].r,'interval traversal changed candidate order')
end
env.IsBuildableAt=function()return false end
local unbuildable,unbuildable_stats=search(map,ctx,bounds,function()error('spacing checked on an unbuildable hex')end)
assert(#unbuildable==0 and unbuildable_stats.terrain_checks==0,'native unbuildability did not short-circuit')
map.underground=true
c,s=search(map,ctx,{},function()error('underground search forbidden')end)
assert(#c==0 and s.visited==0,'surface fallback changed underground behavior')
print('surface residual hex search: complete finite coverage, strict validators, translated skew grid, underground isolation')

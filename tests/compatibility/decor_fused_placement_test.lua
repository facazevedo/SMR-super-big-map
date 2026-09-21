-- Compare the production fused placement transform with the former two-pass
-- vertex-buffer calculation. Scan/support classification is tested separately.
local function read(path)local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_seating.lua')
local seating=SuperBigMap.DecorationSeating
local code=read('Code/sbm_decoration_validation.lua')
local body=assert(code:match('(function Validator%.BuildDecorPlacement.-\nend)\n'))
local bounds=assert(code:match('(local function WorldBounds.-\nend)\n'))
local context,flat,vertex_walks
local function height(x,y)
 if flat then return 50 end
 return math.floor(x/7)+math.floor(y/11)+math.floor((x%127)/3)
end
local globals={const={HeightTileSize=100},box=function(...)return {...}end,
 terrain={GetMinMaxHeight=function(_,b)if flat then return 50,50 end;return math.floor(b[1]/7)+math.floor(b[2]/11),math.floor(b[3]/7)+math.floor(b[4]/11)+42 end,
 GetHeight=function(_,x,y)
  assert(type(x)=='number'and type(y)=='number'and x==math.floor(x)and y==math.floor(y),'height XY must preserve integer point rounding')
  return height(x,y)
 end}}
local validator={CaptureGroup=function()return context end}
local env=setmetatable({Validator=validator,SBM={ObjectClone={ObjectScalesWithTerrain=function()return true end},DecorationSeating=seating},
 Global=function(n)return globals[n]end,Enabled=function()return true end,
 Matrix=function(r)return r.matrix end,min=math.min,max=math.max,abs=math.abs,floor=math.floor,
 Geometry={SupportVertices=function(_,c)vertex_walks=vertex_walks+1;return c.vertices end}},{__index=_G})
env.WorldBounds=assert(load(bounds..'\nreturn WorldBounds','production bounds','t',env))()
env.World=assert(load(assert(code:match('(local function World%(.-\nend)\n'))..'\nreturn World','production world','t',env))()
assert(load(body,'production fused transform','t',env))()
local map={GetMapSize=function()return 10000,10000 end}
math.randomseed(329)
for trial=1,500 do
 flat=trial%3==0
 local sc=math.random(30,490);local factor=1+math.random()/2
 local origin={5000+math.random(-300,300),5000+math.random(-300,300),math.random(-100,1300)}
 local center={xyz=function()return 5000,5000,300 end}
 local object={GetScale=function()return sc end}
 local angle=math.random()*6;local tilt=trial%2==0 and 0 or math.random()*2
 local cs,sn,ct,st=math.cos(angle),math.sin(angle),math.cos(tilt),math.sin(tilt)
 local scale=sc/100
 local matrix={origin=origin,columns={{cs*ct*scale,sn*ct*scale,-st*scale},{-sn*scale,cs*scale,0},{cs*st*scale,sn*st*scale,ct*scale}}}
 local record={obj=object,relevant=true,complete=true,pose={origin=origin,shift={0,0,0}},matrix=matrix}
 local component={vertices={},samples={},bounds={math.huge,math.huge,math.huge,-math.huge,-math.huge,-math.huge}}
 local geometry={vertices={}}
 for i=1,math.random(4,650)do
  local v={math.random(-90,90)+.5,math.random(-90,90)-.5,math.random(-20,180)/3}
  geometry.vertices[i]=v;component.vertices[i]=i
  if i<=8 then component.samples[#component.samples+1]=v end
  for a=1,3 do component.bounds[a]=math.min(component.bounds[a],v[a]);component.bounds[a+3]=math.max(component.bounds[a+3],v[a])end
 end
 local node={supported=true,geometry=geometry,component=component,contacts={terrain=true}}
 record.nodes={node};context={list={record}}
 local ns=math.min(500,math.max(1,math.floor(sc*factor+.5)));local ratio=ns/(sc+0.0)
 local p={math.floor(5000+(origin[1]-5000)*factor+.5),math.floor(5000+(origin[2]-5000)*factor+.5),math.floor(300+(origin[3]-300)*factor+.5)}
 local old={vertices={},terrain=true};local low,high,exposed=math.huge,-math.huge,-math.huge
 for _,v in ipairs(geometry.vertices)do
  local w={}
  for a=1,3 do w[a]=matrix.origin[a]+record.pose.shift[a]+matrix.columns[1][a]*v[1]+matrix.columns[2][a]*v[2]+matrix.columns[3][a]*v[3]end
  local h=height(math.floor(w[1]+.5),math.floor(w[2]+.5))
  low=math.min(low,w[3]);high=math.max(high,w[3]);exposed=math.max(exposed,w[3]-h)
  old.vertices[#old.vertices+1]={p[1]+(w[1]-origin[1])*ratio,p[2]+(w[2]-origin[2])*ratio,p[3]+(w[3]-origin[3])*ratio}
 end
 old.visible=math.max(2,math.min(high-low,math.max(0,exposed))*.5)
 local dz,reason=seating.PlanSupportIsland({old},function(x,y)return height(math.floor(x+.5),math.floor(y+.5))end)
 local coefficient_reads=0
 for a=1,3 do
  local values=matrix.columns[a]
  matrix.columns[a]=setmetatable({},{__index=function(_,i)coefficient_reads=coefficient_reads+1;return values[i]end})
 end
 local origin_reads=0
 record.pose.origin=setmetatable({},{__index=function(_,i)origin_reads=origin_reads+1;return origin[i]end})
 vertex_walks=0
 local result=validator.BuildDecorPlacement(map,{object},center,factor)
 assert(result.ok==(dz~=nil),'placement acceptance changed')
 if dz then
  local entry=result.placements[object]
  assert(entry.position[1]==p[1]and entry.position[2]==p[2]and entry.position[3]==p[3]+dz and entry.scale==ns,'coordinates or scale changed')
  assert(entry.zero_offset_proven or entry.components[1].vertices==nil,'fused planner still retains a redundant transformed vertex buffer')
 else assert(result.reason==reason,'rejection reason changed')end
 if flat and tilt==0 then assert(vertex_walks==0,'certified flat upright placement redundantly walks every vertex')end
 -- At most eight fixture witnesses add a bounded preflight; this bound is
 -- independent of whether the component has four or 650 vertices.
 assert(coefficient_reads<=150,'placement repeatedly loads invariant matrix coefficients per vertex')
 assert(origin_reads<=48,'placement repeatedly loads the unchanged source origin per vertex')
end
flat=true
local o={GetScale=function()return 100 end}
local vertices={{-10,-10,0},{10,-10,0},{10,10,100},{-10,10,100}}
local c={vertices={1,2,3,4},bounds={-10,-10,0,10,10,100}}
local r={obj=o,relevant=true,complete=true,pose={origin={5000,5000,0},shift={0,0,0}},
 matrix={origin={5000,5000,0},columns={{1,0,0},{0,1,0},{0,0,1}}}}
r.nodes={{supported=true,geometry={vertices=vertices},component=c,contacts={terrain=true}}}
context={list={r}};local center={xyz=function()return 5000,5000,0 end}
local reference=validator.BuildDecorPlacement(map,{o},center,4/3)
c.samples=vertices
local fast=validator.BuildDecorPlacement(map,{o},center,4/3)
assert(fast.ok and fast.placements[o].zero_offset_proven,'already-correct placement did not use its positive zero-offset proof')
for a=1,3 do assert(fast.placements[o].position[a]==reference.placements[o].position[a],'zero-offset proof changed placement')end
local o2={GetScale=function()return 100 end}
local r2={obj=o2,relevant=true,complete=true,pose={origin={5020,5000,0},shift={0,0,0}},
 matrix={origin={5020,5000,0},columns={{1,0,0},{0,1,0},{0,0,1}}}}
r.nodes[1].record=r
r2.nodes={{record=r2,supported=true,geometry={vertices=vertices},component=c,contacts={terrain=true}}}
r.nodes[1].edges={r2.nodes[1]};context={list={r,r2}}
local linked=validator.BuildDecorPlacement(map,{o,o2},center,4/3)
assert(linked.ok and linked.groups==1 and not linked.placements[o].zero_offset_proven
 and not linked.placements[o2].zero_offset_proven,'cross-object support island bypassed full interval planning')
r2.nodes[1].supported=false
assert(not validator.BuildDecorPlacement(map,{o,o2},center,4/3).ok,
 'a proven independent placement cannot approve an unsupported linked member')
print('fused placement: 500 exact old/new acceptance, XYZ and scale comparisons on flat and uneven terrain, tilted/scaled meshes')

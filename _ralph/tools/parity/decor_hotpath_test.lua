local path=arg[1] or 'Code/sbm_decor_topup.lua'
local f=assert(io.open(path,'rb'));local source=f:read('*a'):gsub('\r\n','\n');f:close()
local p=assert(io.popen('git show f4d1da6:Code/sbm_decor_topup.lua','r'))
local previous=p:read('*a'):gsub('\r\n','\n');assert(p:close())
local function circles(s)
 local body=assert(s:match('(local function circle_hits%(.-)\nend'))..'\nend'
 return assert(load(body..'\nreturn circle_hits'))()
end
local current=circles(source)
-- Reuse the independent 64k oracle fixture, deriving hint activity from the
-- accepted index serial rather than adding counters to candidate production.
local function query(list,x,y,r)
 local serial=list.spatial_index and list.spatial_index.serial
 local hit=current(list,x,y,r)
 local cache=list.hit_hint_cache
 if hit and list.spatial_index and list.spatial_index.serial==serial then
  cache.hits=(cache.hits or 0)+1
 else cache.index_queries=(cache.index_queries or 0)+1 end
 cache.hits=cache.hits or 0;cache.index_queries=cache.index_queries or 0
 return hit
end
dofile('_ralph/tools/parity/decor_hint_oracle.lua')(circles(previous),query)

local function cursor_factory(s)
 local body=assert(s:match('%-%- DECOR_FINITE_SITES_BEGIN(.-)%-%- DECOR_FINITE_SITES_END'))
 return assert(load(body..'\nreturn NewDecorInteriorCursor'))()
end
local old_cursor,new_cursor=cursor_factory(previous),cursor_factory(source)
local checks,draw_checks=0,0
local function check_cursor(shape,seed,limit,fractional)
 local function stream()
  local state,calls,args,values=seed,0,{},{}
  return function(n)
   calls=calls+1;state=(state*16807)%2147483647
   local value=fractional and calls==1 and 0.5 or state%n
   args[calls],values[calls]=n,value
   return value
  end,args,values
 end
 local ra,aa,va=stream();local rb,ab,vb=stream()
 local a=old_cursor(shape[1],shape[2],shape[3],shape[4],shape[5],ra)
 local b=new_cursor(shape[1],shape[2],shape[3],shape[4],shape[5],rb)
 for i=1,limit or 200000 do
  local ax,ay=a();local bx,by=b()
  assert(ax==bx and ay==by,'cursor coordinate differs')
  assert(#aa==#ab,'cursor draw count differs')
  checks=checks+1
  if ax==nil then
   local before=#aa
   assert(a()==nil and b()==nil and #aa==before and #ab==before,'draw after exhaustion')
   break
  end
 end
 for i=1,#aa do
  assert(aa[i]==ab[i] and va[i]==vb[i],'cursor draw argument/value differs')
  draw_checks=draw_checks+1
 end
end
for seed=1,41 do
 for _,shape in ipairs({{0,0,9,7,1},{-17,12,18,41,4},{8,8,9,9,20},
  {0.25,-0.75,41.5,19.25,3.75},{0,0,200,300,7},{0,0,8,8,4},
  {0,0,0,20,1},{5,3,-2,8,1},{-67108865,0,-67108800,97,4}})do
  check_cursor(shape,seed)
 end
 check_cursor({0,0,10000,10000,1},seed,40) -- oversized-count legacy domain
end
check_cursor({0,0,11,13,3},71,40,true) -- non-integral custom RNG retains legacy
print('PASS cursor '..checks..' coordinates and '..draw_checks..' exact random-call arguments/values')

local function type_factory(s)
 local a=assert(s:find('local get_type = terrain_api.GetTerrainType',1,true))
 local b=assert(s:find('-- Vanilla-like context means',a,true))
 return assert(load('return function(terrain_api,map,point_fn,type_tile)\n'
  ..s:sub(a,b-1)..'\nreturn terrain_type_at end'))()
end
local old_type,new_type=type_factory(previous),type_factory(source)
for _,mode in ipairs({'valid','error','string','missing','callable'})do
 local function setup(factory)
  local calls,points=0,{}
  local api={}
  if mode~='missing' then api.GetTerrainType=function(map,p)
   calls=calls+1;points[calls]=p.x..':'..p.y
   if mode=='error' then error('native error fixture')end
   return mode=='string' and 'invalid' or (p.x*17+p.y*11)%7
  end end
  if mode=='callable' then api.GetTerrainType=setmetatable({},{__call=api.GetTerrainType})end
  local q=factory(api,{},function(x,y)return {x=x,y=y}end,200)
  api.GetTerrainType=function()error('must retain entry function')end
  return q,points
 end
 local a,pa=setup(old_type);local b,pb=setup(new_type)
 for i=1,100 do
  local x,y=(i*71)%1300+0.25,(i*97)%1100-0.25
  assert(a(x,y)==b(x,y) and a(x,y)==b(x,y),'type cache/failure result differs')
 end
 assert(table.concat(pa,'|')==table.concat(pb,'|'),'native type query arguments differ')
end
print('PASS terrain type cache values, native query arguments, failures and entry binding')

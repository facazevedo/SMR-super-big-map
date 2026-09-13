-- Actual accepted/candidate synthetic loops, cache/matcher prefixes and circles.
-- Native stamping is a controlled shared stub; its literal unchanged body is
-- checked separately by the candidate generator. These are NOT full native tests.
local base=arg[1] or '_ralph/runs/under80-20260912/artifacts/decor_rejection_fusion/'
local function read(name)local f=assert(io.open(base..name,'r'));local s=f:read('*a');f:close();return s end
local old,new=read('accepted.lua'),read('candidate.lua')
local checks=0
local function check(v,why)assert(v,why);checks=checks+1 end
local function compile(source,label)
 local circle=assert(source:match('(local function circle_hits%(.-)\nend'))..'\nend\n'
 local cursor=assert(source:match('%-%- DECOR_FINITE_SITES_BEGIN(.-)%-%- DECOR_FINITE_SITES_END'))
 local a=assert(source:find('\t\tlocal function try_stamp(',1,true))
 local b=assert(source:find('\n\t\t-- 5. Vanilla',a,true))
 local prefix=source:sub(a,b-1)
 local tail=prefix:find('\t\t\tlocal prefab = weighted_rand(',1,true)
 if tail then prefix=prefix:sub(1,tail-1)..'\t\t\treturn stamp_matched(prefabs, sx, sy, site_radius)\n\t\tend\n' end
 local c=assert(source:find('local get_type = terrain_api.GetTerrainType',1,true))
 local d=assert(source:find('-- Vanilla-like context means',c,true))
 local terrain=source:sub(c,d-1)
 local body=assert(source:match('(local attempts, budget = .-)\n\t\tend\n\t\tstats%.placed_synthetic'))
 -- Record every attempted candidate after its result, preserving live operation
 -- order, random draws and all original counters; compare complete rows, not hashes.
 local count
 body,count=body:gsub('(\n%s*)if outcome == "placed" then','%1trace_outcome(template.marker.id, sx, sy, template.radius, outcome)%1if outcome == "placed" then')
 check(count==2,'both random and finite outcome trace seams')
 return circle..cursor..terrain..prefix..body
end
local left,right=compile(old,'old'),compile(new,'new')
local function encode(value)
 if type(value)~='table' then return type(value)..':'..tostring(value)end
 local keys={};for k in pairs(value)do keys[#keys+1]=k end
 table.sort(keys,function(a,b)return tostring(a)<tostring(b)end)
 local out={};for _,k in ipairs(keys)do out[#out+1]=encode(k)..'='..encode(value[k])end
 return '{'..table.concat(out,';')..'}'
end
local function run(chunk,seed,mode,n_templates,wanted,trace_enabled)
 local trace,matcher_calls,terrain_calls,circle_trace={},0,0,{}
 local function event(...)
  if trace_enabled then trace[#trace+1]=encode({...}) end
 end
 local templates,obstruct,decorated={}, {}, {}
 for i=1,12 do
  local c={x=(i*17)%96,y=(i*29)%96,r=mode=='blocked' and 200 or 5+i%5}
  if i%2==0 then obstruct[#obstruct+1]=c else decorated[#decorated+1]=c end
 end
 if mode=='decorated' then obstruct={};decorated={{x=48,y=48,r=200}}end
 local env=setmetatable({target=wanted,placed=0,placed_synthetic=0,templates=templates,
  per_group=40,jitter_max=350,map_w=96,map_h=96,type_tile=2,MAX_ROTATION=21600,
  band_x0=10,band_y0=10,band_x1=86,band_y1=86,
  allowed_count=mode=='no_filter' and 0 or 1,allowed_types={[0]=mode=='missing',[1]=true},stats={},
  cfg_number=function(k,v)if k=='STRETCH_DECOR_ENGINE_PASS_SYNTHETIC_TEMPLATE_PATIENCE'then return 3 end;return v end,
  rotate_radius=function(dist,angle)event('rotate',dist,angle);return dist%5,angle%7 end,
  map={},revision=12,version=34,matches_cache={},obstruct=obstruct,decorated=decorated,
  point_fn=function(x,y)event('point',x,y);return{x=x,y=y}end,
  SafeCall=function(fn,...)event('safe');local ok,a,b=pcall(fn,...);if ok then return a,b end end,
  trace_outcome=function(...)event('outcome',...)end,
 },{__index=_G})
 local draw_count,seed_calls=0,0
 env.stream={rand=function(n)
  draw_count=draw_count+1;seed=(seed*16807)%2147483647
  local v=seed%n;event('rand',n,v);return v
 end,seed=function()seed_calls=seed_calls+1;seed=(seed*16807)%2147483647;event('seed',seed);return seed end}
 local api={GetTerrainType=function(_,p)
  terrain_calls=terrain_calls+1;event('terrain',p.x,p.y)
  if mode=='terrain_error'then error('terrain test')end
  if mode=='terrain_string'then return 'invalid'end
  if mode=='terrain_reject'then return 2 end
  return (math.floor(p.x/2)+math.floor(p.y/2))%7==0 and 2 or 1
 end}
 if mode=='missing'then api.GetTerrainType=nil end
 if mode=='callable'then api.GetTerrainType=setmetatable({},{__call=api.GetTerrainType})end
 env.terrain_api=api
 for i=1,n_templates do
  local prefabs={{id=i}}
  local marker={id=i}
  function marker:GetMatchingMarkers(revision,version)
   matcher_calls=matcher_calls+1;event('match',self.id,revision,version)
   if mode=='matcher_retry' and matcher_calls<8 then error('retryable matcher')end
   if mode=='matcher_false' and matcher_calls<8 then return false end
   if mode=='matcher_empty'then return {}end
   return prefabs
  end
  templates[i]={x=45+i%5,y=43+i%7,radius=3+i%3,marker=marker}
 end
 local tail_calls=0
 env.stamp_matched=function(prefabs,x,y,radius)
  tail_calls=tail_calls+1;event('tail',prefabs[1].id,x,y,radius)
  local pick=env.stream.seed()
  local dx,dy=env.stream.rand(3),env.stream.rand(4)
  if mode=='tail_failed' or tail_calls%11==0 then return 'failed'end
  if mode=='tail_empty' then return 'empty'end
  if mode=='tail_no_match'then return 'no_match'end
  if mode=='tail_bounds'then return 'bounds'end
  if mode=='tail_band'then return 'band'end
  env.placed=env.placed+1
  local c={x=x+dx,y=y+dy,r=radius-1}
  decorated[#decorated+1]=c
  if pick%2==0 then obstruct[#obstruct+1]=c end
  return 'placed','prefab'..prefabs[1].id
 end
 assert(load(chunk,'actual synthetic loop','t',env))()
 local function circles(list)
  local rows={};for i,c in ipairs(list)do rows[i]={c.x,c.y,c.r}end
  return {circles=rows,count=list.spatial_index and list.spatial_index.count,
   serial=list.spatial_index and list.spatial_index.serial}
 end
 return {stats=env.stats,placed=env.placed,placed_synthetic=env.placed_synthetic,draws=draw_count,
  seed_calls=seed_calls,final_seed=seed,matchers=matcher_calls,terrain=terrain_calls,tail_calls=tail_calls,
  obstruct=circles(obstruct),decorated=circles(decorated)},trace
end
local modes={'ordinary','blocked','decorated','no_filter','missing','callable','terrain_error',
 'terrain_string','terrain_reject','matcher_retry','matcher_false','matcher_empty',
 'tail_failed','tail_empty','tail_no_match','tail_bounds','tail_band'}
local events,cases=0,0
for seed=1,7 do
 for _,mode in ipairs(modes)do
  local a,ta=run(left,seed*71,mode,1+seed%3,1+seed%4,true)
  local b,tb=run(right,seed*71,mode,1+seed%3,1+seed%4,true)
  check(encode(a)==encode(b),'full state differs '..mode..' seed'..seed)
  check(#ta==#tb,'trace length differs '..mode)
  for i=1,#ta do check(ta[i]==tb[i],'ordered event differs '..mode..' at'..i)end
  events=events+#ta;cases=cases+1
 end
end
-- Both-order coarse Lua model timings; no per-call clocks. Includes construction,
-- caches/indexes/loops and result collection equally. NOT native or startup timing.
local function bench(chunk)
 local start=os.clock();local count=0
 for i=1,8 do local r=run(chunk,71+i,'blocked',12,1,false);count=count+r.draws end
 return os.clock()-start,count
end
local a,ac=bench(left);local b,bc=bench(right);local c,cc=bench(right);local d,dc=bench(left)
check(ac==bc and bc==cc and cc==dc,'benchmark workload differs')
print('PASS '..checks..' checks across '..cases..' exact synthetic-loop cases and '..events..' complete ordered events')
print(string.format('MODEL ONLY old/new %.6f/%.6f s; new/old %.6f/%.6f s',a,b,c,d))

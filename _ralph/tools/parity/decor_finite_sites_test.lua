-- Exercise the actual production synthetic loop, not a separate planner model.
local file=assert(io.open('Code/sbm_decor_topup.lua','rb'))
local source=file:read('*a'); file:close()
local helper=source:match('%-%- DECOR_FINITE_SITES_BEGIN(.-)%-%- DECOR_FINITE_SITES_END') or ''
local body=assert(source:match('(local attempts, budget = .-)\n\t\tend\n\t\tstats%.placed_synthetic'))
local function run(wanted,blocked,terrain_ok,seed,template_count)
  local template={x=20,y=20,radius=2,marker={}}
  local calls,points=0,{}
  local env=setmetatable({target=wanted,placed=0,placed_synthetic=0,templates={template},
    per_group=100,jitter_max=2800,map_w=48,map_h=48,type_tile=1,MAX_ROTATION=21600,
    band_x0=4,band_y0=4,band_x1=44,band_y1=44,
    allowed_count=1,allowed_types={[1]=true},stats={},
    terrain_type_at=function() return terrain_ok and 1 or 2 end,
    cfg_number=function(_,default) return default end,
    rotate_radius=function() return 0,0 end,
    stream={rand=function(n) seed=(seed*16807)%2147483647; return seed%n end},
  },{__index=_G})
  for i=2,template_count or 1 do
    env.templates[i]={x=20,y=20,radius=2,marker=template.marker}
  end
  env.try_stamp=function(marker,x,y,radius)
    assert(marker==template.marker and radius==2,'template filters/radius changed')
    assert(x>=2 and y>=2 and x+2<48 and y+2<48,'footprint bounds bypassed')
    calls=calls+1
    if not template_count then points[#points+1]=x..':'..y end
    if blocked==true or calls<=blocked then return 'obstruct' end
    env.placed=env.placed+1
    return 'placed'
  end
  assert(load(helper..'\n'..body,'production synthetic decor loop','t',env))()
  return env,calls,table.concat(points,',')
end

local env,calls,points=run(1,24,true,901)
assert(env.placed==1 and calls==25,'template retired after random misses before a legal candidate')
assert(env.stats.synthetic_templates_exhausted==0,'untried candidate geometry called exhausted')
local same,same_calls,same_points=run(1,24,true,901)
assert(same.placed==env.placed and same_calls==calls and same_points==points,'seed replay changed')
local exact,exact_calls=run(3,24,true,43)
assert(exact.placed==3 and exact_calls==27,'must stop at exact demand')
local exhausted,exhausted_calls=run(1,true,true,19)
assert(exhausted.placed==0 and exhausted_calls>24 and exhausted_calls<10000,
  'genuinely blocked finite candidate set must terminate')
assert(exhausted.stats.synthetic_templates_exhausted==1)
local terrain,terrain_calls=run(1,0,false,27)
assert(terrain.placed==0 and terrain_calls==0,'terrain rule bypassed')
assert(terrain.stats.synthetic_templates_exhausted==1)
local many,many_calls=run(1,true,true,19,230)
assert(many.placed==0 and many.stats.synthetic_templates_exhausted==230)
assert(many.stats.synthetic_finite_attempts==230*40*40 and many_calls<400000,
  'many-template finite exhaustion repeated cells or failed to terminate')

-- Cover every finite cell once, replay it, stay within half-open bounds, and do
-- not issue random draws after exhaustion. This helper exists only in the fix.
local cursor_factory=assert(load(helper..'\nreturn NewDecorInteriorCursor'))()
assert(type(cursor_factory)=='function')
for _,shape in ipairs({{0,0,9,7,1},{-17,12,18,41,4},{8,8,9,9,20}}) do
  local draws=0
  local function random(n) draws=draws+1; return (draws*7)%n end
  local cursor=cursor_factory(shape[1],shape[2],shape[3],shape[4],shape[5],random)
  local seen,count={},0
  while true do
    local x,y=cursor()
    if x==nil then break end
    assert(x>=shape[1] and x<shape[3] and y>=shape[2] and y<shape[4])
    local cell=math.floor((x-shape[1])/shape[5])..':'..math.floor((y-shape[2])/shape[5])
    assert(not seen[cell],'finite source repeated a visited cell')
    seen[cell]=true; count=count+1
  end
  assert(count==math.ceil((shape[3]-shape[1])/shape[5])*math.ceil((shape[4]-shape[2])/shape[5]))
  local before=draws; assert(cursor()==nil and cursor()==nil and draws==before)
end
print('PASS finite synthetic decor production loop and geometry')

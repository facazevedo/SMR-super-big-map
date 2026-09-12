-- Compare actual production stamping with only its matching cache removed.
local file=assert(io.open('Code/sbm_decor_topup.lua','rb'))
local source=file:read('*a'):gsub('\r\n','\n'); file:close()
local helpers=assert(source:match('%-%- DECOR_OUTPUT_HELPERS_BEGIN(.-)%-%- DECOR_OUTPUT_HELPERS_END'))
local circles=assert(source:match('(local function circle_hits%(.-)\nend'))..'\nend'
local weight=assert(source:match('(local function prefab_weight_decor%(.+)\n\t\tlocal defs_cache'))
local body=assert(source:match('(local function try_stamp%(.+\n\t\tend)\n\n\t\t%-%- 5%.'))
local cache_decl=assert(source:match('local matches_cache = {}'))
local first=assert(body:find('local prefabs = matches_cache[marker]',1,true))
local last=assert(body:find('if type(prefabs) ~= "table"',first,true))
local uncached=body:sub(1,first-1)
  ..'local prefabs = SafeCall(marker.GetMatchingMarkers, marker, revision, version)\n\t\t\t'
  ..body:sub(last)

local linear_circles = [[local function circle_hits(list,x,y,radius)
  for i=1,#list do
    local c=list[i]
    local dx,dy=x-c.x,y-c.y
    local reach=radius+c.r
    if dx*dx+dy*dy<reach*reach then return true end
  end
  return false
end]]
local function fixture(cached, linear)
  local a={weight=100,max_radius=1,rotation=360,orientation=0,decor_obstruct=true}
  local b={weight=70,max_radius=1,rotation=360,orientation=0}
  local list={a,b}
  local calls,trace,outcomes,weights,placements={},{},{},{},{}
  local seed=17
  local function draw(n)
    seed=(seed*16807)%2147483647
    local value=n and n>0 and seed%n or seed
    trace[#trace+1]=tostring(n)..':'..value
    return value
  end
  local env=setmetatable({environment='Surface',map={},
    placed=0,objects=0,placed_list={},prefabs_count={},decorated={},
    obstruct={{x=0,y=0,r=5}},dropped_non_cosmetic=0,dropped_out_of_band=0,
    defs_cache={},raster_cache={},prefab_markers={[a]='a',[b]='b'},
    type_tile=1,length_scale=1,revision=7,version=9,gof=0,
    repeat_reduct=50,rstep=5,min_prefab_radius=1,
    mul_div_round=function(x,y,z) return math.floor(x*y/z+0.5) end,
    stream={seed=function() return draw() end,rand=draw},
    point_fn=function(x,y) return {x=x,y=y} end,
    rotate_radius=function() return 0,0 end,in_band=function() return false end,
    SafeCall=function(fn,...) local ok,result=pcall(fn,...); if ok then return result end end,
    IsKindOfSafe=function() return false end,
    ObjectScalesWithTerrain=function() return false end,
    ObjectPosition=function(obj) return obj.pos end,
    PointXY=function(pos) return pos.x,pos.y end,
    done_object=function(obj) obj.deleted=true end,
  },{__index=_G})
  env.weighted_rand=function(prefabs,get_weight,random)
    assert(prefabs==list and prefabs[1]==a and prefabs[2]==b,'matching order/list changed')
    local wa,wb=get_weight(a),get_weight(b)
    weights[#weights+1]=wa..':'..wb
    return random%(wa+wb)<wa and a or b
  end
  env.place_prefab=function(map,name,center,angle,unused,params)
    assert(params.dont_change_terrain==true)
    placements[#placements+1]=name..':'..center.x..':'..center.y..':'..angle
    return nil,{{class='Rocks01',pos=center,SetPos=function(obj,pos) obj.pos=pos end}}
  end
  local markers={}
  for _,name in ipairs({'normal','empty','retry','non_table'}) do
    local marker={name=name}
    marker.GetMatchingMarkers=function(self,revision,version)
      assert(self==marker and revision==7 and version==9)
      calls[name]=(calls[name] or 0)+1
      if name=='empty' then return {} end
      if name=='retry' and calls[name]==1 then error('transient matcher failure') end
      if name=='non_table' and calls[name]==1 then return false end
      return list
    end
    markers[name]=marker
  end
  local chunk=helpers..'\n'..(linear and linear_circles or circles)..'\n'..weight..'\n'..cache_decl..'\n'
    ..(cached and body or uncached)..'\nreturn try_stamp'
  local stamp=assert(load(chunk,'production matching cache stamp','t',env))()
  local function attempt(name,x,y)
    local outcome,prefab=stamp(markers[name],x,y,1)
    outcomes[#outcomes+1]=outcome..':'..tostring(prefab)
    return outcome
  end
  assert(attempt('empty',0,0)=='no_match')
  assert(attempt('empty',0,0)=='no_match','overlap must not change no_match precedence')
  assert(attempt('retry',0,0)=='no_match')
  assert(attempt('retry',0,0)=='obstruct','matcher errors must remain retryable')
  assert(attempt('non_table',0,0)=='no_match')
  assert(attempt('non_table',0,0)=='obstruct','non-table result cached permanently')
  assert(attempt('normal',100,100)=='placed')
  assert(attempt('normal',100,100)~='placed','cached matches bypassed new occupancy')
  assert(attempt('normal',200,100)=='placed')
  for i=1,3000 do
    local name=i%3==0 and 'retry' or i%3==1 and 'normal' or 'non_table'
    attempt(name,i%100==0 and 1000+i*20 or 0,100*(i%100==0 and 1 or 0))
  end
  assert(weights[1]~=weights[2],'repeat reduction did not stay live')
  assert(#list==2 and list[1]==a and list[2]==b,'cached list mutated')
  local snapshot=table.concat(outcomes,'|')..'\n'..table.concat(trace,'|')..'\n'
    ..table.concat(weights,'|')..'\n'..table.concat(placements,'|')..'\n'
    ..env.placed..':'..env.objects..':'..#env.decorated..':'..#env.obstruct
  if cached then
    assert(calls.normal==1 and calls.empty==1 and calls.retry==2 and calls.non_table==2)
    -- Re-instantiation is a new Run; changed marker filters must be read again.
    markers.normal.GetMatchingMarkers=function() calls.normal=calls.normal+1; return {} end
    local next_stamp=assert(load(chunk,'fresh production pass','t',env))()
    assert(next_stamp(markers.normal,90000,90000,1)=='no_match')
    assert(calls.normal==2,'matching cache leaked between runs')
  end
  local total=0; for _,n in pairs(calls) do total=total+n end
  return snapshot,total
end

local old,old_calls=fixture(false)
local current,current_calls=fixture(true)
assert(old==current,'cache changed outcomes, ordered placements, weights, or RNG trace')
assert(current==fixture(true,true),'spatial query changed outcomes, placements, weights, or RNG trace')
assert(old_calls>3000 and current_calls==7)
print('PASS production matching cache: identical outcomes/placements/RNG; matcher calls '
  ..old_calls..' -> '..current_calls..' (includes fresh-pass invalidation check)')

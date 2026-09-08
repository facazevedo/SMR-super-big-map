-- The production stamp loop, with native placement replaced by deterministic objects.
local file=assert(io.open('Code/sbm_decor_topup.lua','rb'))
local source=file:read('*a'); file:close()
local helpers=source:match('%-%- DECOR_OUTPUT_HELPERS_BEGIN(.-)%-%- DECOR_OUTPUT_HELPERS_END') or ''
local body=assert(source:match('(local function try_stamp%(.+\n\t\tend)\n\r?\n\t\t%-%- 5%.'))
local checks=0
local function run(classes,environment,options)
  local prefab={max_radius=1,rotation=1,orientation=0}
  local env=setmetatable({environment=environment, map={},
    placed=0,objects=0,placed_list={},prefabs_count={},decorated={},obstruct={},
    dropped_non_cosmetic=0,dropped_out_of_band=0,
    defs_cache={},raster_cache={},matches_cache={},prefab_markers={[prefab]='test'},
    type_tile=1,length_scale=1,revision=0,version=1,gof=0,
    stream={seed=function() return 1 end,rand=function() return 0 end},
    point_fn=function(x,y) return {x=x,y=y} end,
    rotate_radius=function() return 0,0 end,
    circle_hits=function() return false end,in_band=function() return false end,
    weighted_rand=function() return prefab end,
    SafeCall=function(fn,...) return fn(...) end,
    IsKindOfSafe=function(obj,kind) return obj.kind==kind end,
    ObjectScalesWithTerrain=function() return true end,
    ObjectPosition=function(obj) return obj.pos end,
    PointXY=function(pos) if pos then return pos.x,pos.y end end,
    done_object=function(obj) obj.deleted=true end,
  },{__index=_G})
  for key,value in pairs(options or {}) do env[key]=value end
  local objects={}
  for _,entry in ipairs(classes) do
    objects[#objects+1]={class=type(entry)=='table' and entry.class or entry,
      kind=type(entry)=='table' and entry.kind or nil,
      pos={x=type(entry)=='table' and entry.x or 50,y=type(entry)=='table' and entry.y or 50},
      SetPos=function(obj,pos) obj.pos=pos end}
  end
  env.place_prefab=function() return nil,objects end
  local stamp=assert(load(helpers..'\n'..body..'\nreturn try_stamp','production decor stamp','t',env))()
  local outcome=stamp({GetMatchingMarkers=function() return {prefab} end},51,51,1)
  return outcome,env,objects
end

for _,environment in ipairs({'Surface','Underground'}) do
  local outcome,env,objs=run({'PrefabMarker','CliffDark_01','DecCrater_01','RocksDark_01',
    'Stones01','GeyserWarmup','Geyser_01','Geyser_02','Geyser_03','UnknownThing'},environment)
  assert(outcome=='placed' and env.placed==1)
  assert(#env.placed_list==5 and env.objects==5,'non-cosmetic output leaked into PassObjects')
  for i=6,10 do assert(objs[i].deleted,'forbidden created object was not removed') end
  checks=checks+7
  outcome,env,objs=run({'PrefabMarker','Underground_Arch01'},environment)
  if environment=='Underground' then
    assert(outcome=='placed' and #env.placed_list==2)
  else
    assert(outcome~='placed' and env.placed==0 and #env.placed_list==0,
      'stamp marker alone must not count as restored cosmetic density')
    assert(objs[1].deleted and objs[2].deleted)
  end
  checks=checks+1
  outcome,env,objs=run({'PrefabMarker',{class='RocksFake',kind='Building'}},environment)
  assert(outcome~='placed' and #env.placed_list==0 and env.objects==0 and env.placed==0)
  assert(objs[1].deleted and objs[2].deleted,'gameplay kind must override cosmetic-looking prefix')
  assert(#env.decorated==0 and #env.obstruct==0,'empty stamp reserved density/occupancy')
  checks=checks+3
end
for _,pos in ipairs({{x=80,y=50},{x=50,y=80}}) do
  local outcome,env,objs=run({'PrefabMarker',{class='Rocks01',x=pos.x,y=pos.y}},'Surface',
    {length_scale=4/3,map_w=100,map_h=100,
     in_band=function(x,y) return x<10 or y<10 or x>=90 or y>=90 end})
  assert(outcome~='placed' and env.placed==0 and #env.placed_list==0,
    'rounding pushed retained decor into the forbidden band')
  assert(objs[1].deleted and objs[2].deleted)
  checks=checks+1
end
print('PASS production decor output filter: '..checks..' checks')

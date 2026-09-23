-- Current vanilla sorts handles before its seeded shuffle. Recreated handles
-- must never replace those native inputs; interception is exact-list scoped.
local f=assert(io.open('Code/sbm_map_generation.lua','r'));local source=f:read('*a');f:close()
local body=assert(source:match('(function SuperBigMap.FinalizeDeferredBreakthroughAnomalyInitialization.-)\nlocal function PatchRandomMapGenerator'))
local function run(legacy,fail,missing)
  local lib={};for k,v in pairs(table) do lib[k]=v end
  local function real_sort(t,field) table.sort(t,function(a,b)return a[field]<b[field] end);return t end
  lib.sortby_field=real_sort
  local sbm={Config={BREAKTHROUGH_STAGED_ORDER=true},State={}}
  local env=setmetatable({SuperBigMap=sbm,Global=function(name)assert(name=='table');return lib end,
    LoadingStep=function()end},{__index=_G})
  assert(load(body,'production breakthrough replay','t',env))()
  local markers={}
  for i=1,6 do markers[i]={class='SubsurfaceAnomalyMarker',tech_action='breakthrough',
    handle=100-i,SuperBigMapNativeSourceX=i,SuperBigMapNativeSourceY=9,alive=true} end
  local map={SuperBigMapBreakthroughInitializationDeferred=true,SuperBigMapStartStagedBreakthroughOrder={}}
  for i=1,6 do map.SuperBigMapStartStagedBreakthroughOrder[i]={class=markers[i].class,
    source_x=i,source_y=9,source_handle=i*10} end
  if missing then map.SuperBigMapStartStagedBreakthroughOrder[2].source_handle=nil end
  function map:MapGet() local out={};for i=#markers,1,-1 do if markers[i].alive then out[#out+1]=markers[i] end end;return out end
  function map:MapForEach(_,_,fn) for _,m in ipairs(markers) do if m.alive then fn(m) end end end
  local city={};function city:MapGet(...)return map:MapGet(...)end;map.City=city
  local map_get=city.MapGet;local draws=0;local received
  sbm.State.original_city_init_breakthrough_anomalies=function(self)
    local a=self:MapGet('map','SubsurfaceAnomalyMarker',function(o)return o.tech_action=='breakthrough'end)
    local unrelated={{handle=6},{handle=1}}
    assert(lib.sortby_field(unrelated,'handle')==unrelated and unrelated[1].handle==1)
    if not legacy then assert(lib.sortby_field(a,'handle')==a) end
    if fail then error('injected initializer failure') end
    received={};for i,o in ipairs(a) do received[i]=o.SuperBigMapNativeSourceX end
    -- Stand-in for unchanged native RNG: consume once, then remove one marker.
    draws=draws+1;a[2].alive=false
  end
  local ok,stats=sbm.FinalizeDeferredBreakthroughAnomalyInitialization(map,'fixture')
  assert(city.MapGet==map_get and lib.sortby_field==real_sort,'temporary hooks leaked')
  for i,m in ipairs(markers) do assert(m.handle==100-i,'live handle was changed') end
  if fail or missing then assert(not ok and stats.error,'initializer error was accepted');return end
  assert(ok and stats.before==6 and stats.after==5 and draws==1)
  for i=1,6 do assert(received[i]==i,'source order was replaced by recreated-handle order') end
  assert(not markers[2].alive)
  assert(map.SuperBigMapBreakthroughNativeHandleSortApplied==not legacy)
end
run(false);run(true);run(false,true);run(false,false,true)
print('PASS native handle replay, legacy query order, unchanged RNG/handles, scoped sort, and error cleanup')

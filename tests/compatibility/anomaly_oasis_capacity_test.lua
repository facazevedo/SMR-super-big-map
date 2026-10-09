local f=assert(io.open('Code/sbm_deposits.lua','r'));local source=f:read('*a');f:close()
local block=assert(source:match('(if not c and not underground and not surface_edge_ring then.-)\n%s*if not c then break end'))
for _,mode in ipairs({'moved','unchanged','underground','edge','already_selected','failed_move'})do
  local occupied={[1]=true,[2]=true,[3]=true}
  local old_tracker={};local profile={};local fills,rebuilds=0,0
  local env=setmetatable({map={},repulsion=old_tracker,anomaly_profile=profile,
    c=mode=='already_selected' and {} or nil,underground=mode=='underground',surface_edge_ring=mode=='edge',
    surface_oasis_capacity_refills=0,surface_hex_fallback_added=0,oasis_stats={moved=0}}, {__index=_G})
  env.fill_oasis_clusters=function()
    fills=fills+1
    if mode=='failed_move'then error('oasis movement rejected')end
    if mode=='moved' and env.oasis_stats.moved==0 then
      occupied={};env.oasis_stats={moved=3}
    end
  end
  env.NewTopUpRepulsionTracker=function(map)
    assert(map==env.map and next(occupied)==nil,'occupancy rebuilt before moves')
    return {CanPlace=function(c,p)assert(p==profile);return not occupied[c.x]end}
  end
  env.rebuild_surface_hex_selector=function()
    rebuilds=rebuilds+1
    assert(env.repulsion~=old_tracker,'stale negative placement cache survived movement')
    local n=0
    return {Take=function(_,p)
      n=n+1;local c={x=n};return n<=3 and env.repulsion.CanPlace(c,p)and c or nil
    end}
  end
  env.take_reachable_candidate=function(selector,p)return selector.Take(nil,p)end
  local run=assert(load(block,'production oasis capacity refill','t',env))
  local ok=pcall(run)
  if mode=='moved'then
    assert(ok and env.c.x==1 and fills==1 and rebuilds==1 and env.surface_oasis_capacity_refills==1)
    assert(env.selected_whole_map_selector==env.surface_hex_selector)
    for x=2,3 do assert(env.take_reachable_candidate(env.surface_hex_selector,profile).x==x)end
    assert(not env.take_reachable_candidate(env.surface_hex_selector,profile))
    env.c=nil;run();assert(rebuilds==1 and env.c==nil,'no-progress refill loop')
  elseif mode=='failed_move'then assert(not ok and rebuilds==0)
  else
    assert(ok and rebuilds==0 and env.surface_oasis_capacity_refills==0)
    assert(fills==(mode=='unchanged' and 1 or 0),'unrelated placement path changed')
  end
end
local fill_block=assert(source:match('(local function fill_oasis_clusters%(%).-)%s*if shortfall <= 0'))
local count=0
local env=setmetatable({map={},IsUndergroundMap=function()return false end,
  RunPaused=function(_,fn)fn();return true end,
  FillOasisClusterAnomalies=function()
    count=count+1;return true,{slots=7,moved=count==1 and 7 or 0,already_filled=count==1 and 0 or 7,unfilled=0}
  end},{__index=_G})
local run,stats=assert(load('local oasis_stats\n'..fill_block..'\nreturn fill_oasis_clusters,function()return oasis_stats end','oasis movement accounting','t',env))()
run();run();assert(stats().moved==7 and stats().already_filled==7,'idempotent final fill lost movement accounting')
print('oasis capacity refill: moved slots reused with fresh strict occupancy; no-progress bounded; normal/underground paths preserved')

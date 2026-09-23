local file=assert(io.open('Code/sbm_terrain_copy.lua','r'))
local source=file:read('*a');file:close()
local block=assert(source:match('(local forced_source = .-)\n\tlocal clutter_ok'))
local map={SuperBigMapForcedImpassSource='source-raster',SuperBigMapForcedImpassDeferred=true}
local events, freed, applied={}, {}, {}
local original={size=function() return 3,3 end}
local resized={}
local env=setmetatable({map=map,full_tw=8,full_th=8,sw_tiles=6,sh_tiles=6,
  Global=function(name)
    if name=='const' then return {HeightTileSize=100} end
    assert(name=='GridReadStr')
    return function(bytes) assert(bytes=='source-raster');return original end
  end,
  GridResample=function(grid,w,h,interp)
    assert(grid==original and w==4 and h==4 and interp==false)
    return resized
  end,
  terrain_api={
    SetForcedImpassableBox=function(owner,box,value)
      assert(owner==map and box[3]==800 and box[4]==800 and value==false)
      events[#events+1]='clear'
    end,
    SetForcedImpassFromMask=function(owner,grid)
      assert(owner==map and grid==resized and events[1]=='clear')
      events[#events+1]='apply'
    end,
  },
  box_fn=function(...) return {...} end,
  free_grid=function(grid) freed[grid]=true end,
  LoadingBegin=function()return true end,LoadingEnd=function(token,stats,ok)assert(ok)end,
},{__index=_G})
assert(load(block,'actual forced-mask stretch','t',env))()
assert(events[1]=='clear' and events[2]=='apply' and #events==2)
assert(freed[original] and freed[resized])
assert(map.SuperBigMapForcedImpassSource==false)
assert(map.SuperBigMapForcedImpassDeferred==false)
-- Failed native writes retain the persisted bytes and pending bit, even with the
-- engine's log-only error implementation. First access must remain closed.
map.SuperBigMapForcedImpassSource='source-raster';map.SuperBigMapForcedImpassDeferred=true
env.error=function() end
env.LoadingEnd=function(token,stats,ok) assert(not ok and stats.error:find('injected')) end
env.terrain_api.SetForcedImpassFromMask=function() return 'injected native failure' end
local result=assert(load(block,'failed forced-mask stretch','t',env))()
assert(result==false and map.SuperBigMapForcedImpassSource=='source-raster' and map.SuperBigMapForcedImpassDeferred)
map.SuperBigMapForcedImpassSource=false
assert(assert(load(block,'missing deferred source','t',env))()==false)
assert(map.SuperBigMapForcedImpassDeferred)
-- A logging-only error must never let pipeline cleanup publish a prepared map.
local f=assert(io.open('Code/sbm_map_generation.lua','r'))
local generation=f:read('*a');f:close()
local gate=assert(generation:match('(if map.SuperBigMapForcedImpassDeferred == true then.-)\n\t\tLoadingEnd%(underground_pipeline_token'))
for _,pending in ipairs({false,true}) do
 local e=setmetatable({map={SuperBigMapForcedImpassDeferred=pending},ok_branch=true},{__index=_G})
 assert(load(gate..'\nreturn ok_branch,branch_err','final forced-mask readiness gate','t',e))()
 assert(e.ok_branch==not pending)
 if pending then assert(e.branch_err:find('not applied')) end
end
print('PASS: captured source mask, categorical scaling, additive-setter clearing order, world bounds, cleanup, persistence release')

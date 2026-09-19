local file=assert(io.open('Code/sbm_terrain_copy.lua','r'))
local source=file:read('*a');file:close()
local block=assert(source:match('(local forced_source = .-)\n\tlocal clutter_ok'))
local map={SuperBigMapForcedImpassSource='source-raster'}
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
print('PASS: captured source mask, categorical scaling, additive-setter clearing order, world bounds, cleanup, persistence release')

-- A saved expansion failure proves ownership, but never proves readiness.
-- The reporters' saves have Expanded=false and lose their transient dimensions.
local globals={const={HeightTileSize=100},IsModEditorMap=function()return false end}
local env={}
setmetatable(env,{__index=_G});env._G=env
env.SuperBigMap={Engine={Global=function(k)return globals[k] end,
  SafeCall=function(fn,...)return fn(...) end,Round=function(v)return math.floor(v+.5)end}}
assert(loadfile('Code/sbm_sector_grid.lua','t',env))()
local grid=env.SuperBigMap.SectorGrid
local failure='surface top-up spacing audit failed: density_failures=1'
local map={Width=819200,Height=819200,mapdata={Width=6144,Height=6144},
  SuperBigMapExpanded=false,SuperBigMapSurfaceStretchFailed=failure}
assert(grid.IsModMap(map),'saved native dimensions must identify the expansion before synchronization')
map.mapdata.Width=8192;map.mapdata.Height=8192 -- SyncMapDataToGrids consumes the dimensional fallback.
assert(grid.IsModMap(map),'failed expanded save lost ownership after mapdata synchronization')
assert(map.SuperBigMapExpanded==false and map.SuperBigMapSurfaceStretchFailed==failure,
  'ownership lookup must not mark an interrupted expansion complete or clear its safety failure')
for _,value in ipairs({false,''}) do
  map.SuperBigMapSurfaceStretchFailed=value
  assert(not grid.IsModMap(map),'vanilla large maps must not be claimed')
end
map.SuperBigMapSurfaceStretchFailed=failure
globals.IsModEditorMap=function()return true end
assert(not grid.IsModMap(map),'editor map must remain excluded')
print('failed map identity: ownership survives synchronization without changing readiness')

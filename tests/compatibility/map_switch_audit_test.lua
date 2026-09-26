-- Owner report 2026-09-26: returning from the underground to the surface after some play raised the
-- game's "mod problem detected" popup. The outer resource terrain audit ran on every surface map
-- switch and "repaired" a footprint blocked by the player's buildings with
-- terrain.SetPassability(map, box, value), which the engine rejects ("Grid expected").
local function read(path) local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local terrain_copy=read('Code/sbm_terrain_copy.lua')
local lifecycle=read('Code/sbm_lifecycle.lua')

-- The audit is read-only: no passability writes anywhere in the terrain module.
assert(not terrain_copy:find('SetPassability',1,true) or terrain_copy:find('SetPassability(map, box, value), a signature',1,true),
  'the terrain audit never writes passability')
for call in terrain_copy:gmatch('[%w_%.]*SetPassability%s*,') do error('passability write remains: '..call) end
assert(not terrain_copy:find('set_exact_offsets_passable',1,true),'the footprint passability repair is gone')

-- The map-switch audit runs only before the surface pipeline publishes T1.
local block=assert(lifecycle:match('(if IsModMap%(map%) and map and map%.mapdata and Engine%.MapDataEnvironment%(map%.mapdata%) == "Surface".-AuditOuterResourceTerrain, map%))'),
  'map-switch audit block not found')
assert(block:find('map.SuperBigMapSurfacePostPipelineRevalidationComplete ~= true',1,true),
  'the map-switch audit is skipped once T1 is published (and after loads)')
print('map switch audit: read-only and limited to the generation boundary')

local f=assert(io.open('Code/sbm_map_generation.lua','r'))
local source=f:read('*a');f:close()
local body=assert(source:match('function SuperBigMap.GenerationReadiness.CanResumePassageFailure.-\nend\n'))
local sbm={GenerationReadiness={},SectorGrid={IsModMap=function(m)return m.modmap end}}
local surface={SuperBigMapExpanded=true}
local pair={SuperBigMapCommittedPassageLocked=true,SuperBigMapDeferredTunnelSpawnPending=true,
 SuperBigMapTrueUndergroundPassageX=40,SuperBigMapTrueUndergroundPassageY=60,
 GetPos=function()return {40,60}end,other={GetMap=function()return surface end}}
local links_valid=true
local env=setmetatable({SuperBigMap=sbm,Engine={MapDataEnvironment=function(d)return d.environment end},
 Global=function()return surface end,TerrainCopy={ValidateSurfacePassageCommitment=function()return links_valid end},
 ArtefactMapGet=function()return {pair}end,PointXY=function(p)return p[1],p[2]end},{__index=_G})
assert(load(body,'production recovery gate','t',env))()
local check=sbm.GenerationReadiness.CanResumePassageFailure
local signature='final passage-pair alignment failed: underground passage pad preparation failed: refusing to flatten invalid Elevator footprint: blocked footprint hex'
local map={modmap=true,mapdata={environment='Underground'},SuperBigMapUndergroundPreparationFailed=true,
 SuperBigMapNativeGenerationComplete=true,SuperBigMapCityInitializationComplete=true,
 SuperBigMapUndergroundStretchFailed='Mod/SuperBigMap/Code/sbm_map_generation.lua:13409: '..signature,
 SuperBigMapUndergroundDeferredGeometry={source_width_tiles=6144,source_height_tiles=6144,
 desired_width_tiles=8192,desired_height_tiles=8192}}
assert(check(map),'known saved passage failure must resume after the source transform')
assert(map.SuperBigMapUndergroundPreparationFailed and not map.SuperBigMapPassageFailureRecovery,
 'eligibility query must not mutate saved failure evidence')
for _,field in ipairs({'SuperBigMapUndergroundPrepared','SuperBigMapExpanded','SuperBigMapForcedImpassDeferred',
 'SuperBigMapPassageFailureRecovery'}) do map[field]=true;assert(not check(map),field);map[field]=nil end
for _,field in ipairs({'SuperBigMapNativeGenerationComplete','SuperBigMapCityInitializationComplete','modmap'}) do
 map[field]=false;assert(not check(map),field);map[field]=true
end
local failure=map.SuperBigMapUndergroundStretchFailed
for _,reason in ipairs({'unbuildable footprint hex','uneven buildable footprint','pipeline failed',signature..' | cleanup failed'}) do
 map.SuperBigMapUndergroundStretchFailed=reason;assert(not check(map),'unknown failure accepted')
end
map.SuperBigMapUndergroundStretchFailed=failure
pair.SuperBigMapDeferredTunnelSpawnPending=false;assert(not check(map));pair.SuperBigMapDeferredTunnelSpawnPending=true
pair.SuperBigMapTrueUndergroundPassageX=41;assert(not check(map));pair.SuperBigMapTrueUndergroundPassageX=40
links_valid=false;assert(not check(map));links_valid=true
surface.SuperBigMapExpanded=false;assert(not check(map));surface.SuperBigMapExpanded=true
map.mapdata.environment='Surface';assert(not check(map));map.mapdata.environment='Underground'
local geometry=map.SuperBigMapUndergroundDeferredGeometry
map.SuperBigMapUndergroundDeferredGeometry=false;assert(not check(map));map.SuperBigMapUndergroundDeferredGeometry=geometry
geometry.desired_width_tiles=6144;assert(not check(map));geometry.desired_width_tiles=8192
assert(check(map))
-- Exercise the production entry path up to the pipeline boundary. A transient
-- dependency failure must leave the original evidence eligible for a later try.
local entry=assert(source:match('(local function RunUndergroundStretchIfEnabled.-)\n\tlocal function run_pipeline'))
local ready=false
env.cfg_bool=function(name,default) return name=='STRETCH_UNDERGROUND' or default end
env.RestoreDeferredUndergroundGeometry=function()end
env.UndergroundExpansionReadiness=function()return ready,'surface is still preparing'end
map.SuperBigMapDesiredWidthTiles=8192;map.SuperBigMapGeneratorWidthTiles=6144
local run=assert(load(entry..'\n return true\nend\nreturn RunUndergroundStretchIfEnabled',
 'production recovery entry','t',env))()
local started,reason=run(map,true)
assert(not started and reason=='surface is still preparing')
assert(map.SuperBigMapUndergroundPreparationFailed and map.SuperBigMapUndergroundStretchFailed==failure
 and not map.SuperBigMapPassageFailureRecovery and not map.SuperBigMapUndergroundStretchRunning,
 'waiting for readiness consumed the saved recovery attempt')
ready=true
assert(run(map,true) and map.SuperBigMapPassageFailureRecovery.status=='running'
 and map.SuperBigMapPassageFailureRecovery.original_failure==failure
 and map.SuperBigMapPassageFailureRecovery.terrain_replayed==false
 and map.SuperBigMapUndergroundPreparationFailed==false and map.SuperBigMapUndergroundStretchRunning,
 'ready recovery did not start exactly once at the pipeline boundary')
print('passage failure recovery: exact stage, immutable anchors, no retry, and malformed/foreign evidence gates passed')

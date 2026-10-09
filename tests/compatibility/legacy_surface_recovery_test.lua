local file=assert(io.open('Code/sbm_map_generation.lua','r'));local source=file:read('*a');file:close()
local body=assert(source:match('(function SuperBigMap.GenerationReadiness.IsLegacySurfaceDensityFailure.-)\nlocal function UndergroundExpansionReadiness'))
local failure='Mod/SuperBigMap/Code/sbm_map_generation.lua:12334: surface top-up spacing audit failed: density_failures=1 duplicate_hex_pairs=0 first_duplicate_hex_pair= repulsion_violations=0 outer_ring_spacing_violations=0 surface_quota_spacing_violations=0 first_surface_quota_spacing_violation= first_repulsion_violation='
local env=setmetatable({SuperBigMap={GenerationReadiness={},DepositRules={FlushStartupTechnologySpawns=function()return true end}}},{__index=_G})
assert(load(body,'production legacy recovery','t',env))()
local r=env.SuperBigMap.GenerationReadiness
assert(r.IsLegacySurfaceDensityFailure(failure))
for _,bad in ipairs({'terrain stretch failed',failure:gsub('density_failures=1','density_failures=0'),
  failure:gsub('repulsion_violations=0','repulsion_violations=2'),failure:gsub('duplicate_hex_pairs=0','duplicate_hex_pairs=1'),
  'surface top-up spacing audit failed: density_failures=1'})do
  assert(not r.IsLegacySurfaceDensityFailure(bad),'unrelated/incomplete failure accepted')
end
for _,fault in ipairs({'none','geometry','geometry_api','alignment','commitment','built','built_valid','built_terrain','built_link','built_position','rewards'})do
  local succeeds=fault=='none' or fault=='built_valid'
  local resources={consumed=17};local buildings={count=50};local terrain={signature='unchanged'}
  local surface={SuperBigMapSurfaceStretchFailed=failure,SuperBigMapExpanded=false,
    SuperBigMapNativeGenerationComplete=true,SuperBigMapCityInitializationComplete=true,
    resources=resources,buildings=buildings,terrain=terrain,MapForEach=function()end}
  local underground={SuperBigMapNativeGenerationComplete=true,SuperBigMapCityInitializationComplete=true,
    SuperBigMapUndergroundDeferredGeometry={desired_width_tiles=8192,desired_height_tiles=8192}}
  local anchor={elevator=fault=='built' and {} or false};local paused=0
  local globals={MainMap=surface,UndergroundMap=underground,const={HeightTileSize=100},
    IsValid=function(v)return type(v)=='table'end,Pause=function()paused=paused+1 end,Resume=function()paused=paused-1 end}
  if fault:find('built_',1,true)then
    local function pos(x,y)return {x=function()return x end,y=function()return y end}end
    local p=pos(100,200)
    local twin={GetMap=function()return underground end,other=anchor,SuperBigMapCommittedPassageLocked=true}
    local e={GetMap=function()return surface end,GetPos=function()return fault=='built_position' and pos(101,200)or p end,passage=anchor}
    local other={GetMap=function()return underground end,passage=twin,other=e}
    e.other=other;anchor.elevator=e;anchor.other=twin;twin.elevator=other
    if fault=='built_link'then other.other=false end
    anchor.GetPos=function()return p end;anchor.GetAngle=function()return 0 end
    anchor.SuperBigMapCommittedPassageLocked=true
    anchor.SuperBigMapCommittedPassageX=100;anchor.SuperBigMapCommittedPassageY=200
    globals.BuildingTemplates={Elevator={GetBuildShape=function()return {}end}}
    globals.GetEntityOutlineShape=function()return {}end
    globals.IsTerrainFlatForPlacement=function()return fault~='built_terrain'end
  end
  env.Global=function(k)return globals[k]end
  env.SuperBigMap.DepositRules.FlushStartupTechnologySpawns=function()return fault~='rewards','injected reward failure'end
  surface.GetMapSize=function()
    if fault=='geometry_api'then error('injected native geometry failure')end
    return fault=='geometry' and 614400 or 819200,819200
  end
  env.RestoreDeferredUndergroundGeometry=function()return true end
  env.TerrainCopy={
    PendingSurfaceEntranceObjects=function()return {anchors={[anchor]=true}}end,
    BuildSurfaceEntranceClearance=function()return function()return true end end,
    AlignPassagePairsToSharedHex=function(_,options)
      assert(options.only_unprepared_surface,'retry could move a committed entrance')
      return fault~='alignment',{error='injected failure'}
    end,
    ValidateSurfacePassageCommitment=function()return fault~='commitment','injected invalid pad'end,
  }
  local ok=r.RecoverLoadedSurfaceDensityFailure(surface)
  assert(ok==succeeds,'wrong recovery outcome: '..fault)
  assert(surface.SuperBigMapExpanded==succeeds)
  if ok then assert(surface.SuperBigMapSurfaceStretchFailed==false)
  else assert(surface.SuperBigMapSurfaceStretchFailed==failure)end
  assert(surface.resources==resources and resources.consumed==17 and surface.buildings==buildings and surface.terrain==terrain,
    'legacy recovery replayed population/terrain generation')
  assert(paused==0,'recovery leaked the game pause')
  if ok then
    local report=surface.SuperBigMapLegacySurfaceRecovery
    assert(report.original_failure==failure)
    assert(not r.RecoverLoadedSurfaceDensityFailure(surface),'completed recovery ran twice')
    assert(surface.SuperBigMapLegacySurfaceRecovery==report and paused==0)
    if fault=='built_valid'then assert(report.existing_elevators_kept==1 and anchor.SuperBigMapPassagePadPrepared)end
  end
end
print('legacy surface recovery: narrow eligibility, native pad validation, unchanged colony, failure retention and pause cleanup passed')

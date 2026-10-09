local f=assert(io.open('Code/sbm_deposits.lua'));local source=f:read('*a');f:close()
local block=assert(source:match('(local function PatchStartupTechnologySpawns.-)\nfunction DepositRules.ApplyModBehavior'))
local restore=assert(source:match('function DepositRules.RestoreVanillaBehavior.-\nend\n'))
local sbm={State={},GENERATOR_PATCH_VERSION=476,SectorGrid={IsModMap=function(m)return m.owned==true end}}
local rules={HasStagedNativeEnrichmentRecords=function(m)return m.staged==true end}
local map={owned=true,SuperBigMapStretchPipelinePending=true}
local calls={}
local function native(tech,resource,environment)
 calls[#calls+1]={tech.id,resource,environment}
 if tech.fail then error('injected partial native failure')end
 return 'native',resource
end
local env=setmetatable({SuperBigMap=sbm,DepositRules=rules,MainMap=map,TechDef={},
 SpawnResourceOrAnomaly=native,RestoreBadgeOverlapPrevention=function()end},{__index=_G})
env.Global=function(k)return env[k]end
local install=assert(load(block..restore..'\nreturn PatchStartupTechnologySpawns','production technology deferral','t',env))()
for _,id in ipairs({'CoreMetals','CoreRareMetals','CoreWater','AlienImprints'})do env.TechDef[id]={id=id}end
assert(install());local wrapper=env.SpawnResourceOrAnomaly
assert(install() and env.SpawnResourceOrAnomaly==wrapper,'installation stacked wrappers')
for _,id in ipairs({'CoreMetals','CoreRareMetals','CoreWater','AlienImprints'})do
 local resource='Metals';if id=='AlienImprints'then resource=false end
 env.SpawnResourceOrAnomaly(env.TechDef[id],resource,'Surface')
end
assert(#calls==0 and #map.SuperBigMapDeferredStartupTechSpawns==4,'startup rewards were placed before final terrain')
assert(not rules.FlushStartupTechnologySpawns(map) and #calls==0,'unfinished terrain accepted')
map.SuperBigMapSurfaceStretchDone=true
local ok,count=rules.FlushStartupTechnologySpawns(map)
assert(ok and count==4 and #calls==4 and map.SuperBigMapDeferredStartupTechSpawns==false)
assert(calls[1][1]=='CoreMetals' and calls[4][1]=='AlienImprints','native callback order changed')
assert(calls[4][2]==false,'anomaly reward became a resource reward')
assert(rules.FlushStartupTechnologySpawns(map) and #calls==4,'reward duplicated on repeated completion')
-- A retained partial callback must fail without invoking it for a second time.
env.TechDef.broken={id='broken',fail=true}
env.SpawnResourceOrAnomaly(env.TechDef.broken,'Water','Surface')
assert(not rules.FlushStartupTechnologySpawns(map) and #calls==5)
assert(map.SuperBigMapDeferredStartupTechSpawns[1].status=='failed')
assert(not rules.FlushStartupTechnologySpawns(map) and #calls==5,'partial reward retried and duplicated')
map.SuperBigMapDeferredStartupTechSpawns=false
-- Loaded completed maps have no transient startup flags; runtime research stays native.
map.SuperBigMapStretchPipelinePending=false
assert(env.SpawnResourceOrAnomaly(env.TechDef.CoreWater,'Water','Surface')=='native' and #calls==6)
map.SuperBigMapStretchPipelinePending=true;map.owned=false
assert(env.SpawnResourceOrAnomaly(env.TechDef.CoreWater,'Water','Surface')=='native' and #calls==7)
map.owned=true
assert(env.SpawnResourceOrAnomaly(env.TechDef.CoreWater,'Water','Underground')=='native' and #calls==8)
map.SuperBigMapSurfacePostPipelineRevalidationComplete=true
assert(env.SpawnResourceOrAnomaly(env.TechDef.CoreWater,'Water','Surface')=='native' and #calls==9)
-- Reinstall uses the true original, including when only the patch identity changes.
sbm.GENERATOR_PATCH_VERSION=477;assert(install());assert(env.SpawnResourceOrAnomaly~=wrapper)
assert(sbm.State.startup_technology_spawn_original==native)
rules.RestoreVanillaBehavior();assert(env.SpawnResourceOrAnomaly==native)
assert(install());local foreign=function()end;env.SpawnResourceOrAnomaly=foreign
rules.RestoreVanillaBehavior();assert(env.SpawnResourceOrAnomaly==foreign,'restore overwrote another mod')
print('startup technology rewards: deferred native execution, order, once-only completion, partial failure, vanilla/runtime delegation and reload passed')

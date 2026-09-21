-- Exercise the production functions, including a ban on release-only native
-- diagnostic calls. Gameplay rebuild calls must still execute in both modes.
local function read(path)local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
SuperBigMap={Config={},Engine={Global=function(n)return _G[n]end}}
dofile('Code/sbm_diagnostics.lua')
local audit=SuperBigMap.Diagnostics.GenerationAuditEnabled
assert(type(audit)=='function','generation observation gate missing')
assert(not audit(),'default configuration must not collect generation evidence')
for _,key in ipairs({'DECORATION_VALIDATION_ENABLED','NATIVE_SOURCE_MANIFEST','TRACE_UNDERGROUND_ROCK_PARITY'})do
 SuperBigMap.Config[key]=true;assert(audit(),key);SuperBigMap.Config[key]=false
end
SuperBigMap.Config.DEBUG_LOADING_TIMINGS=true;assert(not audit(),'debug master gate remains required')
SuperBigMap.Config.DEBUG_LOGGING_ENABLED=true;assert(audit());SuperBigMap.Config={}
local calls={hash=0,height=0,texture=0,pass=0,build=0,apron=0}
local globals={terrain={HashPassability=function()calls.hash=calls.hash+1;return 19 end,
 InvalidateHeight=function()calls.height=calls.height+1 end,InvalidateType=function()calls.texture=calls.texture+1 end,
 RebuildPassability=function()calls.pass=calls.pass+1 end},box=function(...)return {...}end,
 RebuildBuildableGrid=function()calls.build=calls.build+1 end,
 WorldToHex=function()calls.apron=calls.apron+1;return 1,2 end,point=function(...)return {...}end,
 buildUnbuildableZ=function()return -1 end}
local env=setmetatable({SuperBigMap=SuperBigMap,Global=function(n)return globals[n]end,
 Engine={MapDataEnvironment=function()return 'Surface'end},cfg_bool=function(_,default)return default end,
 TerrainSize=function()return 819200,819200 end,GetPreciseTicks=function()return 0 end,
 LoadingBegin=function()end,LoadingEnd=function()end,LoadingStep=function()end,SetLoadingPhase=function()end},{__index=_G})
SuperBigMap.GenerationGrids={}
local source=read('Code/sbm_map_generation.lua')
local body=assert(source:match('(function SuperBigMap%.GenerationGrids%.RebuildFinal%b()%s*.-)\n%-%- Stretch%-only surface expansion readiness gate%.'))
assert(load(body,'production RebuildFinal','t',env))()
local map={mapdata={},SuperBigMapFinalPassHashBefore='stale',SuperBigMapFinalPassHashAfter='stale'}
assert(SuperBigMap.GenerationGrids.RebuildFinal(map,'release'))
assert(calls.hash==0,'release must not hash full passability grids')
assert(calls.height==1 and calls.texture==1 and calls.pass==1 and calls.build==1,'release must retain every gameplay rebuild')
assert(map.SuperBigMapFinalPassHashBefore==nil and map.SuperBigMapFinalPassHashAfter==nil,'old diagnostic hashes must not look current')
SuperBigMap.Config.DECORATION_VALIDATION_ENABLED=true
assert(SuperBigMap.GenerationGrids.RebuildFinal(map,'validation'))
assert(calls.hash==2 and calls.pass==2 and calls.build==2,'validation restores evidence without duplicating rebuilds')
source=read('Code/sbm_terrain_copy.lua')
body=assert(source:match('(local function AuditNaturalMountainBaseBuildableAprons%b()%s*.-)\n%-%- The resource layout'))
local apron=assert(load(body..'\nreturn AuditNaturalMountainBaseBuildableAprons','production apron audit','t',env))()
map.SuperBigMapNaturalMountainBaseApronCenters={{x=1,y=2}}
map.buildable={GetZ=function()return 0 end}
SuperBigMap.Config.DECORATION_VALIDATION_ENABLED=false
assert(apron(map));assert(calls.apron==0,'release must omit report-only apron queries')
SuperBigMap.Config.DECORATION_VALIDATION_ENABLED=true
assert(apron(map));assert(calls.apron==1,'diagnostic apron audit remains available')
print('release observations: no grid hashes or apron-only queries; gameplay rebuilds and validation evidence preserved')

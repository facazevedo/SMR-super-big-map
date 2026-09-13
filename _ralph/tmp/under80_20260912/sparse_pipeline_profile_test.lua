local path='_ralph/tmp/under80_20260912/sparse_pipeline_profile.lua'
local checks=0
local function check(value,message)assert(value,message);checks=checks+1 end
local function fixture()
 local tick=0
 local map={mapdata={Environment='Surface',id='fixture'}}
 local diag={}
 for _,key in ipairs({'LoadingEnabled','LoadingActive','LoadingStart','LoadingStep',
 'LoadingPhase','LoadingFinish','LoadingBegin','LoadingEnd'})do diag[key]=function()return false end end
 local terrain={}
 for _,key in ipairs({'InvalidateHeight','InvalidateType','RebuildPassability'})do
  terrain[key]=function()tick=tick+3;return true,nil,7,nil end
 end
 local function RepairInternalHeightStep(grid,source)
  if grid=='error' then error('fixture helper error')end
  tick=tick+5;return true,nil,source,nil
 end
 local function RepairQualifiedSourceHeightSteps()tick=tick+7;return false,nil end
 local function RasterNaturalMountainBaseAprons()tick=tick+9;return true,{modified=2},nil end
 local function CreateNaturalMountainBaseBuildableAprons(m,g)
  local a,b,c=RasterNaturalMountainBaseAprons();return a,b,c
 end
 local function StretchSourceToFull(m,g)
  local a,b,c,d=RepairInternalHeightStep(g,true)
  RepairInternalHeightStep(g,false);RepairQualifiedSourceHeightSteps()
  CreateNaturalMountainBaseBuildableAprons(m,g)
  return a,b,c,d
 end
 local final_count=0
 local grids={RebuildFinal=function(m,stage)
  final_count=final_count+1
  local token=diag.LoadingBegin('fixture rebuild',m)
  for _,key in ipairs({'InvalidateHeight','InvalidateType','RebuildPassability'})do terrain[key](m)end
  diag.LoadingEnd(token,nil,true)
  if stage=='error' then error('fixture final error')end
  return true,nil,17,nil
 end}
 local sbm={Diagnostics=diag,GenerationGrids=grids,
  Config={DEBUG_LOGGING_ENABLED=false,DEBUG_LOADING_TIMINGS=false},
  TerrainCopy={StretchSourceToFull=StretchSourceToFull},Engine={Global=function()return terrain end}}
 local env=setmetatable({ModsLoaded={{env={SuperBigMap=sbm}}},CurrentMap=map,
  GetPreciseTicks=function()return tick end,print=function()end},{__index=_G})
 env._G=env
 local saved={};for k,v in pairs(diag)do saved[k]=v end
 local native={};for k,v in pairs(terrain)do native[k]=v end
 local original_final=grids.RebuildFinal
 local function restored()
  for k,v in pairs(saved)do check(diag[k]==v,'diagnostic hook leaked '..k)end
  for k,v in pairs(native)do check(terrain[k]==v,'native hook leaked '..k)end
  check(grids.RebuildFinal==original_final,'final hook leaked')
  check(sbm.Config.DEBUG_LOGGING_ENABLED==false and sbm.Config.DEBUG_LOADING_TIMINGS==false,'config mutated')
 end
 return env,sbm,map,restored,function()return final_count end
end
do
 local env,sbm,map,restored,count=fixture()
 check(assert(loadfile(path,'t',env))()=='SPARSE_PIPELINE_PROFILE_READY','setup failed')
 local diag=sbm.Diagnostics
 diag.LoadingStart('fixture',map)
 local outer=diag.LoadingBegin('outer',map)
 local values=table.pack(sbm.TerrainCopy.StretchSourceToFull(map,{}))
 check(values.n==4 and values[1]==true and values[2]==nil and values[3]==true and values[4]==nil,'helper return tuple')
 local other=coroutine.create(function()
  local token=diag.LoadingBegin('other thread',map);diag.LoadingEnd(token,nil,true)
 end)
 check(coroutine.resume(other),'separate thread failed')
 diag.LoadingEnd(outer,nil,true)
 diag.LoadingFinish('fixture',map)
 for _,row in ipairs({{map,'immediate'},{{mapdata={Environment='Underground'}},'underground'},
  {map,'post-pipeline scheduled revalidation'}})do
  values=table.pack(sbm.GenerationGrids.RebuildFinal(row[1],row[2]))
  check(values.n==4 and values[1]==true and values[2]==nil and values[3]==17 and values[4]==nil,'final return tuple')
 end
 local r=env.SBM_SPARSE_PIPELINE_DIAGNOSTIC
 check(r.status=='pass' and r.restored and r.config_unchanged and r.open_spans==0,'normal restoration failed')
 check(r.completed_spans==r.span_count and r.hooks==13,'span/hook census')
 check(count()==3,'rebuild omitted')
 local names={};for _,row in ipairs(r.calls)do names[row.name]=(names[row.name] or 0)+1
  check(row.duration_ms>=row.exclusive_ms and row.exclusive_ms>=0,'duration accounting')end
 check(names['helper crease repair source']==1 and names['helper crease repair destination']==1,'crease phase labels')
 check(names['helper native apron raster']==1 and names['native final RebuildPassability']==3,'nested native census')
 restored()
 env.SBM_SPARSE_PIPELINE_RESTORE('again');restored()
end
for _,missing in ipairs({'diagnostic','upvalue','native'})do
 local env,sbm,map,restored=fixture()
 if missing=='diagnostic' then sbm.Diagnostics.LoadingEnd=nil
 elseif missing=='upvalue' then sbm.TerrainCopy.StretchSourceToFull=function()end
 else sbm.Engine.Global().RebuildPassability=nil end
 local before={};for k,v in pairs(sbm.Diagnostics)do before[k]=v end
 assert(loadfile(path,'t',env))()
 check(env.SBM_SPARSE_PIPELINE_DIAGNOSTIC.status=='fail','missing prerequisite accepted')
 for k,v in pairs(before)do check(sbm.Diagnostics[k]==v,'partial setup mutation')end
end
for _,which in ipairs({'helper','final'})do
 local env,sbm,map,restored=fixture()
 assert(loadfile(path,'t',env))()
 local ok
 if which=='helper' then ok=pcall(sbm.TerrainCopy.StretchSourceToFull,map,'error')
 else ok=pcall(sbm.GenerationGrids.RebuildFinal,map,'error')end
 check(not ok,'fixture error swallowed')
 check(env.SBM_SPARSE_PIPELINE_DIAGNOSTIC.status=='fail','error not latched')
 restored()
end
print('PASS sparse pipeline probe: '..checks..' setup/tuple/thread/nesting/census/error/restoration checks')

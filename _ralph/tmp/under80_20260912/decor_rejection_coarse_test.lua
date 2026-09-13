local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local checks=0
local function check(v,m)assert(v,m);checks=checks+1 end
for _,variant in ipairs({'old','new'})do
 for _,mode in ipairs({'normal','failed_run','rebound','missing_source'})do
  local mod_env=setmetatable({}, {__index=_G});mod_env._G=mod_env
  local sbm={Config={STRETCH_DECOR_ENGINE_PASS=false},Engine={Global=function()end,
   SafeCall=function(fn,...)if type(fn)=='function'then local ok,v=pcall(fn,...);if ok then return v end end end},
   GenerationGrids={RebuildFinal=function()return nil,'final',nil end}}
  mod_env.SuperBigMap=sbm
  assert(load(read('Code/sbm_decor_topup.lua'),'accepted module','t',mod_env))()
  local original,final=sbm.DecorTopUp.Run,sbm.GenerationGrids.RebuildFinal
  local ticks=0
  local harness=setmetatable({ModsLoaded={{env=mod_env}},print=function()end,
   assert=function()end,GetPreciseTicks=function()ticks=ticks+1;return ticks end},{__index=_G})
  harness._G=harness
  harness.AsyncFileToString=function(path)
   if mode=='missing_source' and path:find('candidate.lua',1,true)then return 'missing' end
   return nil,read(path:gsub('^D:/PROJS/SMR/super%-big%-map/',''))
  end
  local setup=assert(load(read('_ralph/tmp/under80_20260912/decor_rejection_coarse_'..variant..'.lua'),'coarse entry','t',harness))
  setup()
  local result=harness.SBM_DECOR_REJECTION_COARSE
  if mode=='missing_source' and variant=='new'then
   check(result.status=='fail' and sbm.DecorTopUp.Run==original and sbm.GenerationGrids.RebuildFinal==final,'preflight no hooks')
  else
   check(result.status=='ready','setup ready')
   local map={mapdata={Environment='Surface'},MapForEach=function()end}
   if mode=='failed_run'then map.MapForEach=nil end
   local ok,stats=sbm.DecorTopUp.Run(map)
   check(result.calls[1].duration_ms==1 and ticks==2,'two whole-Run clocks only')
   if mode=='failed_run'then
    check(not ok and stats.error and result.status=='fail' and result.restored,'false Run immediate cleanup')
   else check(ok and stats.reason=='disabled','original private config')end
   local replacement=function()end
   if mode=='rebound'then sbm.DecorTopUp.Run=replacement end
   local values=table.pack(sbm.GenerationGrids.RebuildFinal(map,'post-pipeline scheduled revalidation'))
   check(values.n==3 and values[2]=='final','final nil tuple')
   if mode=='rebound'then check(result.status=='fail' and sbm.DecorTopUp.Run==replacement,'preserve rebound')
   elseif mode=='failed_run'then check(result.status=='fail' and sbm.DecorTopUp.Run==original,'failure remains latched')
   else check(result.status=='pass' and result.restored and result.config_unchanged,'normal cleanup')end
   check(sbm.GenerationGrids.RebuildFinal==final,'final owner restored')
   check(variant=='old' and result.joined_cells==0 or variant=='new' and result.joined_cells>0,'candidate-only exact cell joins')
  end
 end
end
print('PASS '..checks..' coarse old/new actual-module lifecycle and timing fixture checks')

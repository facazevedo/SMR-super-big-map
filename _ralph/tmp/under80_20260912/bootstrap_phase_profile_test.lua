-- Wrapper contract fixture. Actual native body semantics require native parity runs.
local checks=0
local function check(v,why)assert(v,why);checks=checks+1 end
local function fixture(mode)
 local tick=0
 local shared={count=0,advance=function()tick=tick+3 end}
 local function BootstrapPassagesAndDeferWonders(native_env)
  shared.count=shared.count+1
  if native_env.raise then error('fixture bootstrap exception')end
  return true,{passages=2,wonders_deferred=3},nil
 end
 local original=BootstrapPassagesAndDeferWonders
 local function PatchRandomMapGenerator(native_env)return BootstrapPassagesAndDeferWonders(native_env)end
 local original_final=function(map,stage)
  if stage=='error' then error('fixture final exception')end
  return true,nil,17,nil
 end
 local sbm={Config={DEBUG_LOGGING_ENABLED=false,DEBUG_LOADING_TIMINGS=false},
  MapGeneration={PatchRandomMapGenerator=PatchRandomMapGenerator},GenerationGrids={RebuildFinal=original_final}}
 local env=setmetatable({GetPreciseTicks=function()return tick end,print=function()end},{__index=_G})
 env._G=env;env.SuperBigMap=sbm;env.ModsLoaded={{env=env}}
 env.AsyncFileToString=function(path)
  if mode=='missing_source' then return 'missing',nil end
  local f=assert(io.open(path:gsub('D:/PROJS/SMR/super%-big%-map/',''),'r'))
  local s=f:read('*a');f:close();return nil,s
 end
 env.load=function(source,name,...)
  if name~='@bootstrap-phase-profile'then return load(source,name,...)end
  -- Isolate lifecycle/tuple/upvalue-join tests from native map construction.
  return function(bootstrap_phase)
   local shared
   return function(native_env)
    shared.count=shared.count+1
    for i,name in ipairs({'preflight','wonder_assignment','native_wonder_clearance','native_wonder_resume',
     'surface_bridge_setup','surface_bridge_copy','surface_bridge_bind','passage_spawn_clearance',
     'passage_resume','surface_bridge_restore','common_hex_planning','verification'})do
     bootstrap_phase(native_env.bad_phase and i==2 and 'wrong' or name)
     shared.advance()
     if native_env.early and i==1 then return false,'not ready',nil end
     if native_env.raise and i==2 then error('fixture bootstrap exception')end
    end
    return true,{passages=2,wonders_deferred=3},nil
   end
  end
 end
 if mode=='missing_callsite'then sbm.MapGeneration.PatchRandomMapGenerator=function()end end
 local function restored()
  check(sbm.GenerationGrids.RebuildFinal==original_final,'final hook leaked')
  local found
  for i=1,20 do local name,value=debug.getupvalue(PatchRandomMapGenerator,i);if not name then break end
   if name=='BootstrapPassagesAndDeferWonders'then found=value end end
  check(found==original,'bootstrap cell leaked')
  check(sbm.Config.DEBUG_LOGGING_ENABLED==false and sbm.Config.DEBUG_LOADING_TIMINGS==false,'config changed')
 end
 return env,sbm,shared,restored
end
for _,mode in ipairs({'normal','early','raise','bad_phase','final_error','missing_source','missing_callsite'})do
 local env,sbm,shared,restored=fixture(mode)
 local setup=assert(loadfile('_ralph/tmp/under80_20260912/bootstrap_phase_profile.lua','t',env))()
 local r=env.SBM_BOOTSTRAP_PHASE_DIAGNOSTIC
 if mode=='missing_source' or mode=='missing_callsite'then
  check(not setup and r.status=='fail','missing setup prerequisite accepted');restored()
 else
  check(setup=='BOOTSTRAP_PHASE_PROFILE_READY' and r.status=='ready','setup failed')
  check(r.source_reconstruction and r.joined_upvalues==2,'source/private upvalue contract')
  local native_env={map={mapdata={Environment='Underground'}},early=mode=='early',raise=mode=='raise',bad_phase=mode=='bad_phase'}
  local values=table.pack(pcall(sbm.MapGeneration.PatchRandomMapGenerator,native_env))
  check(shared.count==1,'private cell not joined')
  if mode=='raise'then check(not values[1] and r.status=='fail','bootstrap exception swallowed')
  elseif mode=='early'then check(values.n==4 and values[1] and values[2]==false and values[3]=='not ready' and values[4]==nil,'early tuple changed')
  else
   check(values.n==4 and values[1] and values[2]==true and values[3].passages==2 and values[4]==nil,'success tuple changed')
   local stage=mode=='final_error' and 'error' or 'post-pipeline scheduled revalidation'
   local final=table.pack(pcall(sbm.GenerationGrids.RebuildFinal,{mapdata={Environment='Surface'}},stage))
   if mode=='final_error'then check(not final[1] and r.status=='fail','final exception swallowed')
   else check(final.n==5 and final[1] and final[2] and final[3]==nil and final[4]==17 and final[5]==nil,'final tuple changed')end
  end
  if mode=='normal'then
   check(r.status=='pass' and r.restored and r.config_unchanged,'normal audit state')
   check(#r.calls==1 and #r.calls[1].phases==12 and r.calls[1].phase_sum_ms==36,'phase census/accounting')
  else check(r.status=='fail' and r.error,'failure not latched')end
  restored()
 end
end
print('PASS bootstrap wrapper: '..checks..' tuple/private-cell/setup/phase/error/restoration checks')

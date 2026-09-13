local path='_ralph/tmp/under80_20260912/native_proc_profile.lua'
local checks=0
local function check(value,message)assert(value,message);checks=checks+1 end
local function fixture(mode)
 local tick=0
 local map={mapdata={Environment='Underground',id='fixture'}}
 local surface={mapdata={Environment='Surface',id='surface'}}
 local class={}
 local counts={start=0,finish=0,generate=0,final=0}
 class.Generate=function()end;class.DoGenerate=function()end;class.OnGenerateLogic=function()end
 class.ProcStart=function(self,tag,...)
  counts.start=counts.start+1;tick=tick+1
  if mode=='start_error' then error('fixture start error')end
  return nil,tag,nil,...
 end
 class.ProcEnd=function(self,tag,...)
  counts.finish=counts.finish+1;tick=tick+2
  if mode=='end_error' then error('fixture end error')end
  return nil,tag,nil,...
 end
 local sbm={Config={DEBUG_LOGGING_ENABLED=false,DEBUG_LOADING_TIMINGS=false},
  Engine={Global=function(name)check(name=='RandomMapGenerator','unexpected global');return class end},
  GenerationGrids={RebuildFinal=function(m,stage,...)
   counts.final=counts.final+1
   if mode=='final_error' then error('fixture final error')end
   return nil,stage,nil,...
  end}}
 sbm.CallDoGenerateWithRockParityTrace=function(original,generator,m,...)
  counts.generate=counts.generate+1
  return original(generator,m,...)
 end
 local env=setmetatable({ModsLoaded={{env={SuperBigMap=sbm}}},
  GetPreciseTicks=function()return tick end,print=function()end},{__index=_G})
 env._G=env
 local originals={};for k,v in pairs(class)do originals[k]=v end
 local original_call=sbm.CallDoGenerateWithRockParityTrace
 local original_final=sbm.GenerationGrids.RebuildFinal
 local function restored()
  for k,v in pairs(originals)do check(class[k]==v,'leaked class method '..k)end
  check(sbm.CallDoGenerateWithRockParityTrace==original_call,'leaked generation hook')
  check(sbm.GenerationGrids.RebuildFinal==original_final,'leaked final hook')
  check(not sbm.Config.DEBUG_LOGGING_ENABLED and not sbm.Config.DEBUG_LOADING_TIMINGS,'changed config')
 end
 local generator={Id='fixture'}
 local function proc(tag,nested)
  local values=table.pack(class.ProcStart(generator,tag,7,nil))
  check(values.n==5 and values[1]==nil and values[2]==tag and values[3]==nil
   and values[4]==7 and values[5]==nil,'ProcStart tuple')
  tick=tick+3
  if nested then nested()end
  values=table.pack(class.ProcEnd(generator,tag,9,nil))
  check(values.n==5 and values[1]==nil and values[2]==tag and values[3]==nil
   and values[4]==9 and values[5]==nil,'ProcEnd tuple')
 end
 return env,sbm,class,map,surface,generator,proc,restored,counts,function(n)tick=tick+n end
end
do
 local env,sbm,class,map,surface,generator,proc,restored,counts=fixture()
 check(assert(loadfile(path,'t',env))()=='NATIVE_PROC_PROFILE_READY','setup')
 local r=env.SBM_NATIVE_PROC_DIAGNOSTIC
 local values=table.pack(sbm.CallDoGenerateWithRockParityTrace(function(self,m,...)
  check(self==generator and m==map,'generation identity')
  local args=table.pack(...);check(args.n==3 and args[1]==4 and args[2]==nil and args[3]==nil,'generation args')
  proc('FindPrefabPos');proc('ApplyTerrain');proc('ApplyTerrain')
  proc('parent',function()proc('child')end)
  return nil,8,nil,nil
 end,generator,map,4,nil,nil))
 check(values.n==4 and values[1]==nil and values[2]==8 and values[3]==nil and values[4]==nil,'generation tuple')
 check(#r.calls==5 and #r.generations==1,'procedure census')
 check(r.calls[2].occurrence==1 and r.calls[3].occurrence==2,'repeated tags collapsed')
 check(r.calls[4].parent==r.calls[5].id,'nested parent')
 check(r.calls[5].duration_ms>r.calls[5].exclusive_ms,'child accounting')
 check(r.generations[1].open_procedures==0 and r.generations[1].boundaries_restored,'local restoration')
 for _,entry in ipairs({{surface,'immediate'},{map,'underground'},{surface,'post-pipeline scheduled revalidation'}})do
  values=table.pack(sbm.GenerationGrids.RebuildFinal(entry[1],entry[2],11,nil))
  check(values.n==5 and values[1]==nil and values[2]==entry[2] and values[4]==11 and values[5]==nil,'final tuple')
 end
 check(r.status=='pass' and r.restored and r.class_methods_unchanged and r.config_unchanged,'normal diagnostic status')
 check(r.span_count==5 and r.completed_spans==5 and r.active_generations==0 and r.hooks==2,'final census')
 check(counts.generate==1 and counts.start==5 and counts.finish==5 and counts.final==3,'native calls changed')
 restored();env.SBM_NATIVE_PROC_RESTORE('again');restored()
end
-- Compose with pre-existing projection wrappers and nested/coroutine native generations.
do
 local env,sbm,class,map,surface,generator,proc,restored=fixture()
 assert(loadfile(path,'t',env))()
 local saved_start,saved_end=class.ProcStart,class.ProcEnd
 local before,after=0,0
 class.ProcStart=function(...)before=before+1;return saved_start(...)end
 class.ProcEnd=function(...)after=after+1;return saved_end(...)end
 local projected_start,projected_end=class.ProcStart,class.ProcEnd
 sbm.CallDoGenerateWithRockParityTrace(function()
  proc('outer',function()
   sbm.CallDoGenerateWithRockParityTrace(function()proc('inner')end,generator,map)
   local co=coroutine.create(function()
    sbm.CallDoGenerateWithRockParityTrace(function()proc('parallel')end,generator,surface)
   end)
   check(coroutine.resume(co),'coroutine generation')
  end)
 end,generator,map)
 check(class.ProcStart==projected_start and class.ProcEnd==projected_end,'projection wrapper not restored')
 class.ProcStart=saved_start;class.ProcEnd=saved_end
 sbm.GenerationGrids.RebuildFinal(surface,'post-pipeline scheduled revalidation')
 local r=env.SBM_NATIVE_PROC_DIAGNOSTIC
 check(r.status=='pass' and #r.generations==3 and #r.calls==3,'nested context isolation')
 check(before==3 and after==3,'projection wrapper calls changed')
 restored()
end
for _,mode in ipairs({'start_error','end_error','generation_error','final_error','mismatch','unfinished','logging_error'})do
 local env,sbm,class,map,surface,generator,proc,restored=fixture(mode)
 if mode=='logging_error' then env.error=function()end end
 assert(loadfile(path,'t',env))()
 local ok
 if mode=='final_error' then ok=pcall(sbm.GenerationGrids.RebuildFinal,surface,'error')
 else
  ok=pcall(sbm.CallDoGenerateWithRockParityTrace,function()
   if mode=='generation_error' or mode=='logging_error' then error('fixture generation error')end
   if mode=='mismatch' or mode=='unfinished' then
    class.ProcStart(generator,'one')
    if mode=='mismatch' then class.ProcEnd(generator,'two')end
   else proc('one')end
  end,generator,map)
 end
 if mode=='mismatch' or mode=='unfinished' then
  check(ok,'diagnostic mismatch affected native return')
  sbm.GenerationGrids.RebuildFinal(surface,'post-pipeline scheduled revalidation')
 elseif mode=='logging_error' then check(ok,'logging-only error fixture threw')
 else check(not ok,'native exception swallowed')end
 local r=env.SBM_NATIVE_PROC_DIAGNOSTIC
 check(r.status=='fail' and #r.issues>0,'failure not latched: '..mode)
 restored()
end
-- Missing prerequisites never partially install hooks.
for _,missing in ipairs({'ProcEnd','DoGenerate','call','final'})do
 local env,sbm,class,map,surface,generator,proc,restored=fixture()
 if missing=='call' then sbm.CallDoGenerateWithRockParityTrace=nil
 elseif missing=='final' then sbm.GenerationGrids.RebuildFinal=nil
 else class[missing]=nil end
 local a,b,c=class.ProcStart,sbm.CallDoGenerateWithRockParityTrace,sbm.GenerationGrids.RebuildFinal
 assert(loadfile(path,'t',env))()
 check(env.SBM_NATIVE_PROC_DIAGNOSTIC.status=='fail','missing prerequisite accepted')
 check(a==class.ProcStart and b==sbm.CallDoGenerateWithRockParityTrace and c==sbm.GenerationGrids.RebuildFinal,'partial setup')
end
print('PASS native procedure probe: '..checks..' tuple/nesting/projection/thread/failure/restoration checks')

-- Temporary coarse native procedure timings, including procedures before OnGenerateLogic.
-- No class-generation-method replacement, source reload, RNG calls or config changes.
local result={status='setup',calls={},generations={},issues={},started_at=GetPreciseTicks()}
rawset(_G,'SBM_NATIVE_PROC_DIAGNOSTIC',result)
local function fail(why)
 result.status='fail';result.issues[#result.issues+1]=tostring(why)
 result.error=result.error or tostring(why)
end
-- Optional diagnostic-only observer. No observer means the original coarse probe.
local observer=rawget(_G,'SBM_NATIVE_PROC_OBSERVER')
if observer~=nil then
 if type(observer)~='table' or type(observer.result)~='table'then fail('invalid native observer');return end
 for _,name in ipairs({'generation_enter','generation_exit','procedure_start','procedure_end','restore'})do
  if type(observer[name])~='function'then fail('missing observer callback '..name);return end
 end
 result.primitive=observer.result
end
local function observe(name,...)
 if not observer then return true end
 local ok,passed,why=pcall(observer[name],...)
 if not ok or passed~=true then
  fail('observer '..name..': '..tostring(ok and why or passed));return false
 end
 return true
end
local sbm
for _,mod in ipairs(ModsLoaded or {})do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.Config then sbm=value;break end
end
local class=sbm and sbm.Engine and sbm.Engine.Global('RandomMapGenerator')
if not sbm or not sbm.State or not sbm.GenerationGrids or type(class)~='table'
 or type(sbm.CallDoGenerateWithRockParityTrace)~='function'
 or type(sbm.GenerationGrids.RebuildFinal)~='function'then
 fail('native procedure prerequisites unavailable');return
end
for _,name in ipairs({'ProcStart','ProcEnd','Generate','DoGenerate','OnGenerateLogic'})do
 if type(class[name])~='function'then fail('missing generator method '..name);return end
end
local pack=function(...)return {n=select('#',...),...}end
local unpack_values=table.unpack or unpack
local contexts,sequence={},0
local original_call=sbm.CallDoGenerateWithRockParityTrace
local original_final=sbm.GenerationGrids.RebuildFinal
local config_before={sbm.Config.DEBUG_LOGGING_ENABLED,sbm.Config.DEBUG_LOADING_TIMINGS}
local methods_before={}
for _,name in ipairs({'ProcStart','ProcEnd'})do
 methods_before[name]=class[name]
end
local generation_keys={Generate='generator_generate_wrapper',DoGenerate='generator_do_generate_wrapper',
 OnGenerateLogic='generator_on_generate_logic_wrapper'}
local function generation_methods()
 local snapshot={};local valid=true
 for name,state_key in pairs(generation_keys)do
  snapshot[name]=class[name]
  if type(class[name])~='function' or class[name]~=sbm.State[state_key] then
   valid=false;fail('unregistered generator method: '..name)
  end
 end
 return snapshot,valid
end
local restored=false
local call_wrapper,final_wrapper,restore
local function thread_key()return coroutine.running() or 'main'end
local function current(key)
 local stack=contexts[key];return stack and stack[#stack]
end
local function close(ctx,tag,ok)
 local stack=ctx.stack;local token=stack[#stack]
 if not token or token.name~=tag then fail('native procedure nesting/tag mismatch');return end
 stack[#stack]=nil
 local duration=GetPreciseTicks()-token.at
 local parent=stack[#stack]
 if parent then parent.child_ms=parent.child_ms+duration
 else ctx.row.procedure_ms=ctx.row.procedure_ms+duration end
 local row={id=token.id,generation=ctx.row.id,environment=ctx.row.environment,
  map=ctx.row.map,name=tag,occurrence=token.occurrence,parent=parent and parent.id or 0,
  ordinal=token.ordinal,start_ms=token.at-result.started_at,duration_ms=duration,
  exclusive_ms=duration-token.child_ms,ok=ok~=false}
 result.calls[#result.calls+1]=row
 if row.exclusive_ms<0 or duration<0 then fail('negative native procedure duration')end
end
restore=function(reason)
 if restored then return end
 local active=0;for _,stack in pairs(contexts)do active=active+#stack end
 result.active_generations=active
 if active~=0 then fail('active native generation at restoration')end
 observe('restore',reason)
 if sbm.CallDoGenerateWithRockParityTrace~=call_wrapper then fail('generation hook rebound')
 else sbm.CallDoGenerateWithRockParityTrace=original_call end
 if sbm.GenerationGrids.RebuildFinal~=final_wrapper then fail('final hook rebound')
 else sbm.GenerationGrids.RebuildFinal=original_final end
 local _,registered=generation_methods()
 result.class_methods_validated=registered
 for name,fn in pairs(methods_before)do
  if class[name]~=fn then result.class_methods_validated=false;fail('class boundary changed: '..name)end
 end
 result.config_unchanged=sbm.Config.DEBUG_LOGGING_ENABLED==config_before[1]
  and sbm.Config.DEBUG_LOADING_TIMINGS==config_before[2]
 if not result.config_unchanged then fail('debug config changed')end
 result.span_count=sequence;result.completed_spans=#result.calls
 result.elapsed_ms=GetPreciseTicks()-result.started_at
 result.restore_reason=reason;restored=true
 result.restored=sbm.CallDoGenerateWithRockParityTrace==original_call
  and sbm.GenerationGrids.RebuildFinal==original_final and result.class_methods_validated
 result.status=#result.issues==0 and 'pass' or 'fail'
 print('[SBM native proc profile] '..result.status..' generations='..#result.generations
  ..' procedures='..#result.calls..' restored='..tostring(result.restored))
end
call_wrapper=function(original,generator,map,...)
 if restored then return original_call(original,generator,map,...)end
 if #result.generations>=32 then
  fail('native generation cap exceeded');restore('generation cap')
  return original_call(original,generator,map,...)
 end
 local key=thread_key();local context_stack=contexts[key]
 if not context_stack then context_stack={};contexts[key]=context_stack end
 local data=map and map.mapdata
 local row={id=#result.generations+1,environment=data and data.Environment or '?',
  map=data and tostring(data.id or '?') or '?',start_ms=GetPreciseTicks()-result.started_at,
  procedure_ms=0,procedure_count=0}
 result.generations[#result.generations+1]=row
 local generation_before,registered=generation_methods()
 row.generation_methods_registered=registered
 local ctx={row=row,stack={},counts={}}
 context_stack[#context_stack+1]=ctx
 observe('generation_enter',original,generator,map,row)
 local saved_start,saved_end=class.ProcStart,class.ProcEnd
 local start_wrapper=function(self,tag,...)
  local values=pack(pcall(saved_start,self,tag,...))
  if not values[1]then fail('ProcStart error: '..tostring(values[2]));error(values[2]);return nil end
  if self==generator and thread_key()==key and current(key)==ctx then
   if sequence>=4096 then fail('native procedure cap exceeded')
   else
    sequence=sequence+1;tag=tostring(tag)
    row.procedure_count=row.procedure_count+1
    ctx.counts[tag]=(ctx.counts[tag] or 0)+1
    ctx.stack[#ctx.stack+1]={id=sequence,name=tag,ordinal=row.procedure_count,
     occurrence=ctx.counts[tag],at=GetPreciseTicks(),child_ms=0}
    observe('procedure_start',row,tag,sequence)
   end
  end
  return unpack_values(values,2,values.n)
 end
 local end_wrapper=function(self,tag,...)
  if self==generator and thread_key()==key and current(key)==ctx then
   local token=ctx.stack[#ctx.stack]
   observe('procedure_end',row,tostring(tag),token and token.id)
   close(ctx,tostring(tag),true)
  end
  local values=pack(pcall(saved_end,self,tag,...))
  if not values[1]then fail('ProcEnd error: '..tostring(values[2]));error(values[2]);return nil end
  return unpack_values(values,2,values.n)
 end
 class.ProcStart=start_wrapper;class.ProcEnd=end_wrapper
 local values=pack(pcall(original_call,original,generator,map,...))
 observe('generation_exit',row,values[1])
 row.duration_ms=GetPreciseTicks()-result.started_at-row.start_ms
 row.remainder_ms=row.duration_ms-row.procedure_ms
 row.open_procedures=#ctx.stack;row.ok=values[1]
 if row.open_procedures~=0 then fail('unfinished native procedures')end
 if row.remainder_ms<0 then fail('negative native generation remainder')end
 if class.ProcStart~=start_wrapper then fail('ProcStart rebound during native generation')
 else class.ProcStart=saved_start end
 if class.ProcEnd~=end_wrapper then fail('ProcEnd rebound during native generation')
 else class.ProcEnd=saved_end end
 row.boundaries_restored=class.ProcStart==saved_start and class.ProcEnd==saved_end
 row.generation_methods_unchanged=true
 for name,fn in pairs(generation_before)do
  if class[name]~=fn then row.generation_methods_unchanged=false;fail('generator method changed within native call: '..name)end
 end
 context_stack[#context_stack]=nil
 if not values[1]then
  fail('native generation error: '..tostring(values[2]));restore('generation error')
  error(values[2]);return nil
 end
 return unpack_values(values,2,values.n)
end
final_wrapper=function(map,stage,...)
 local values=pack(pcall(original_final,map,stage,...))
 if not values[1]then fail('final error: '..tostring(values[2]));restore('final error');error(values[2]);return nil end
 if map and map.mapdata and map.mapdata.Environment=='Surface'
  and stage=='post-pipeline scheduled revalidation'then restore(stage)end
 return unpack_values(values,2,values.n)
end
sbm.CallDoGenerateWithRockParityTrace=call_wrapper
sbm.GenerationGrids.RebuildFinal=final_wrapper
rawset(_G,'SBM_NATIVE_PROC_RESTORE',restore)
result.status='ready';result.hooks=2
return 'NATIVE_PROC_PROFILE_READY'

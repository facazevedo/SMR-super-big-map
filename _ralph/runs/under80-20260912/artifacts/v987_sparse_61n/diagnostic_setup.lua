-- Fresh-process, in-memory coarse timings. No module reload, per-cell probes,
-- config/engine setting changes, cache changes, RNG calls or moved generation work.
local result={status='setup',calls={},events={},issues={},started_at=GetPreciseTicks()}
rawset(_G,'SBM_SPARSE_PIPELINE_DIAGNOSTIC',result)
local function fail(why)
 result.status='fail';result.issues[#result.issues+1]=tostring(why)
 result.error=result.error or tostring(why)
end
local sbm
for _,mod in ipairs(ModsLoaded or {})do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.Config then sbm=value;break end
end
if not sbm or not sbm.Diagnostics or not sbm.GenerationGrids or not sbm.TerrainCopy
 or type(debug.getupvalue)~='function' or type(debug.setupvalue)~='function' then
 fail('sparse profile prerequisites unavailable');return
end
local function pack(...)return {n=select('#',...),...}end
local unpack_values=table.unpack or unpack
local hooks,stacks,open={}, {}, {}
local sequence,thread_sequence=0,0
local thread_ids={}
local restoring,restored=false,false
local function thread_key()return coroutine.running() or 'main'end
local function context(map)
 map=map or rawget(_G,'CurrentMap')
 local data=map and map.mapdata
 return data and data.Environment or '?',data and tostring(data.id or '?') or '?'
end
local function scalar_data(data)
 local out={}
 if type(data)=='table' then for key,value in pairs(data)do
  local k,v=type(key),type(value)
  if (k=='string' or k=='number') and (v=='number' or v=='string' or v=='boolean')then out[key]=value end
 end end
 return out
end
local function begin(name,map,data)
 if restored then return false end
 if sequence>=16384 then fail('sparse span cap exceeded');return false end
 local key=thread_key();local stack=stacks[key]
 if not stack then stack={};stacks[key]=stack;thread_sequence=thread_sequence+1;thread_ids[key]=thread_sequence end
 sequence=sequence+1
 local environment,map_id=context(map)
 local parent=stack[#stack]
 local token={id=sequence,name=tostring(name),at=GetPreciseTicks(),child_ms=0,
  parent=parent and parent.id or 0,thread=thread_ids[key],environment=environment,map=map_id,
  data=scalar_data(data),key=key}
 stack[#stack+1]=token;open[token]=true
 return token
end
local function finish(token,data,ok)
 if not token then return false end
 if not open[token] then fail('unknown or duplicate sparse token');return false end
 local now=GetPreciseTicks();local stack=stacks[token.key]
 if token.key~=thread_key() or not stack or stack[#stack]~=token then
  fail('sparse span nesting/thread mismatch');return false
 end
 stack[#stack]=nil;open[token]=nil
 local duration=now-token.at
 local parent=stack[#stack]
 if parent then parent.child_ms=parent.child_ms+duration end
 local row={id=token.id,parent=token.parent,thread=token.thread,name=token.name,
  environment=token.environment,map=token.map,start_ms=token.at-result.started_at,
  duration_ms=duration,exclusive_ms=duration-token.child_ms,ok=ok~=false,
  inputs=token.data,outputs=scalar_data(data)}
 result.calls[#result.calls+1]=row
 if duration<0 or row.exclusive_ms<0 then fail('negative sparse duration')end
 return true
end
local function event(kind,name,map)
 if #result.events>=4096 then fail('sparse event cap exceeded');return false end
 local environment,map_id=context(map)
 result.events[#result.events+1]={kind=kind,name=tostring(name),environment=environment,
  map=map_id,at_ms=GetPreciseTicks()-result.started_at}
 return true
end
local function add_table(owner,key,wrapper)
 if type(owner)~='table' or type(owner[key])~='function' then fail('missing hook '..key);return false end
 hooks[#hooks+1]={name=key,original=owner[key],wrapper=wrapper,
  get=function()return owner[key]end,set=function(fn)owner[key]=fn;return true end}
 return true
end
local function upvalue(fn,wanted)
 if type(fn)~='function' then return end
 for i=1,200 do local name,value=debug.getupvalue(fn,i);if not name then break end
  if name==wanted then return value,i end
 end
end
local restore
local function measured(name,fn,map_argument)
 return function(...)
  local args=pack(...)
  local label=name
  if name=='helper crease repair' then label=name..(args[2] and ' source' or ' destination')end
  local token=begin(label,map_argument and args[map_argument] or nil)
  local values=pack(pcall(fn,...))
  finish(token,nil,values[1])
  if not values[1] then
   fail(name..': '..tostring(values[2]));restore('wrapped error')
   error(values[2]);return nil
  end
  return unpack_values(values,2,values.n)
 end
end
local function add_upvalue(caller,name,label,map_argument)
 local fn,index=upvalue(caller,name)
 if type(fn)~='function' then fail('missing helper '..name);return false end
 hooks[#hooks+1]={name=name,original=fn,wrapper=measured(label,fn,map_argument),
  get=function()return (upvalue(caller,name))end,
  set=function(value)return debug.setupvalue(caller,index,value)==name end}
 return true
end
local diag=sbm.Diagnostics
local active=false
local replacements={
 LoadingEnabled=function()return true end,
 LoadingActive=function()return active end,
 LoadingStart=function(name,map)active=true;return event('start',name,map)end,
 LoadingStep=function(name,data,map)return event('step',name,map)end,
 LoadingPhase=function(name,map)return event('phase',name,map)end,
 LoadingFinish=function(name,map)active=false;return event('finish',name,map)end,
 LoadingBegin=begin,LoadingEnd=finish,
}
for _,key in ipairs({'LoadingEnabled','LoadingActive','LoadingStart','LoadingStep',
 'LoadingPhase','LoadingFinish','LoadingBegin','LoadingEnd'})do
 if not add_table(diag,key,replacements[key])then return end
end
local stretch=sbm.TerrainCopy.StretchSourceToFull
for _,spec in ipairs({{'RepairInternalHeightStep','helper crease repair'},
 {'RepairQualifiedSourceHeightSteps','helper source crease correction'},
 {'CreateNaturalMountainBaseBuildableAprons','helper natural apron',1}})do
 if not add_upvalue(stretch,spec[1],spec[2],spec[3])then return end
end
local apron=upvalue(stretch,'CreateNaturalMountainBaseBuildableAprons')
if not add_upvalue(apron,'RasterNaturalMountainBaseAprons','helper native apron raster')then return end
local terrain_api=sbm.Engine and sbm.Engine.Global('terrain')
for _,name in ipairs({'InvalidateHeight','InvalidateType','RebuildPassability'})do
 if type(terrain_api)~='table' or type(terrain_api[name])~='function'then
  fail('native final boundary unavailable: '..name);return
 end
end
local original_final=sbm.GenerationGrids.RebuildFinal
if type(original_final)~='function'then fail('scheduled restore boundary missing');return end
local config_before={logging=sbm.Config.DEBUG_LOGGING_ENABLED,timing=sbm.Config.DEBUG_LOADING_TIMINGS}
restore=function(reason)
 if restored or restoring then return end
 restoring=true
 local count=0;for _ in pairs(open)do count=count+1 end
 result.open_spans=count
 if count~=0 then fail('unfinished sparse spans at restoration')end
 for i=#hooks,1,-1 do
  local hook=hooks[i]
  if hook.installed then
   if hook.get()~=hook.wrapper then fail('hook rebound: '..hook.name)
   elseif not hook.set(hook.original) or hook.get()~=hook.original then fail('hook restore failed: '..hook.name)end
  end
 end
 result.config_unchanged=sbm.Config.DEBUG_LOGGING_ENABLED==config_before.logging
  and sbm.Config.DEBUG_LOADING_TIMINGS==config_before.timing
 if not result.config_unchanged then fail('debug configuration changed')end
 restored=true;restoring=false
 result.restored=#result.issues==0;result.restore_reason=reason
 result.span_count=sequence;result.completed_spans=#result.calls
 result.elapsed_ms=GetPreciseTicks()-result.started_at
 result.status=#result.issues==0 and 'pass' or 'fail'
 print('[SBM sparse profile] '..result.status..' spans='..#result.calls..' open='..count..' restored='..tostring(result.restored))
end
local final_wrapper=function(map,stage,...)
 local saved,wrappers={},{}
 for _,name in ipairs({'InvalidateHeight','InvalidateType','RebuildPassability'})do
  saved[name]=terrain_api[name]
  wrappers[name]=measured('native final '..name,saved[name],1)
 end
 for name,fn in pairs(wrappers)do terrain_api[name]=fn end
 local token=begin('helper final rebuild: '..tostring(stage),map)
 local values=pack(pcall(original_final,map,stage,...))
 for name,fn in pairs(saved)do
  if terrain_api[name]~=wrappers[name] then fail('native hook rebound: '..name)
  else terrain_api[name]=fn end
 end
 finish(token,nil,values[1])
 if not values[1]then fail(tostring(values[2]));restore('final error');error(values[2]);return nil end
 if map and map.mapdata and map.mapdata.Environment=='Surface' and stage=='post-pipeline scheduled revalidation'then
  restore(stage)
 end
 return unpack_values(values,2,values.n)
end
if not add_table(sbm.GenerationGrids,'RebuildFinal',final_wrapper)then return end
for _,hook in ipairs(hooks)do
 if hook.get()~=hook.original or not hook.set(hook.wrapper)then
  fail('hook install failed: '..hook.name);restore('setup failure');return
 end
 hook.installed=true
end
rawset(_G,'SBM_SPARSE_PIPELINE_RESTORE',restore)
result.status='ready';result.hooks=#hooks
return 'SPARSE_PIPELINE_PROFILE_READY'

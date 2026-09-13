-- Factory for a native-procedure observer. Instrument only selected UG stages.
return function(ticks)
 local result={status='ready',scopes={},issues={},call_count=0}
 local function fail(why)
  result.status='fail';result.issues[#result.issues+1]=tostring(why)
  return false,tostring(why)
 end
 local pack=function(...)return {n=select('#',...),...}end
 local unpack_values=table.unpack or unpack
 local names={'GridDistanceMars','GridMask','GridAnd','GridOr','GridNot','GridMulDivAdd',
  'GridMulAddScaled','GridDest','NewComputeGrid','GridMinMax','GridEquals',
  'GridStableRandomPosSimple','GridStableRandomPos','GridCircleSet','GridOpFree'}
 local selected={FindPrefabPos_Playable=true,FindPrefabPos_Filler=true,FindPrefabPos_Base=true}
 result.primitives={};for _,name in ipairs(names)do result.primitives[#result.primitives+1]=name end
 result.primitives[#result.primitives+1]='table.weighted_rand'
 local generations={}
 local active
 local function key()return coroutine.running() or 'main'end
 local function environment(fn)
  if type(debug)~='table' or type(debug.getupvalue)~='function'then return end
  for i=1,200 do
   local name,value=debug.getupvalue(fn,i)
   if not name then return end
   if name=='_ENV' and type(value)=='table'then return value end
  end
 end
 local function close(ok)
  local scope=active
  if not scope then return fail('no primitive scope to close')end
  local row=scope.row
  row.duration_ms=ticks()-scope.started
  row.remainder_ms=row.duration_ms-row.primitive_ms
  row.completed=ok==true and #scope.stack==0
  row.open_primitives=#scope.stack
  row.globals_restored=true
  for i=#scope.hooks,1,-1 do
   local hook=scope.hooks[i]
   if hook.installed then
    if hook.owner[hook.name]~=hook.wrapper then
     row.globals_restored=false;fail('primitive rebound: '..hook.label)
    else
     local restored=pcall(function()
      hook.owner[hook.name]=hook.original
      rawset(hook.owner,hook.name,hook.original_raw)
     end)
     if not restored or hook.owner[hook.name]~=hook.original or rawget(hook.owner,hook.name)~=hook.original_raw then
      row.globals_restored=false;fail('primitive restore failed: '..hook.label)
     end
    end
   end
  end
  if not row.completed then fail('unfinished primitive scope')end
  if row.remainder_ms<0 then fail('negative primitive remainder')end
  active=nil
  return #result.issues==0,table.concat(result.issues,'; ')
 end
 local function measure(scope,hook)
  return function(...)
   -- Other coroutines retain the original call without timing or argument copies.
   if active~=scope or key()~=scope.key then return hook.original(...)end
   if result.call_count>=250000 then
    fail('primitive call cap exceeded');return hook.original(...)
   end
   local row=scope.row
   result.call_count=result.call_count+1;row.call_count=row.call_count+1
   local stats=row.primitives[hook.label]
   if not stats then stats={count=0,inclusive_ms=0,exclusive_ms=0};row.primitives[hook.label]=stats end
   stats.count=stats.count+1
   local token={child_ms=0};scope.stack[#scope.stack+1]=token
   local started=ticks()
   local values=pack(pcall(hook.original,...))
   local elapsed=ticks()-started
   if scope.stack[#scope.stack]~=token then fail('primitive stack mismatch')end
   scope.stack[#scope.stack]=nil
   local parent=scope.stack[#scope.stack]
   if parent then parent.child_ms=parent.child_ms+elapsed
   else row.primitive_ms=row.primitive_ms+elapsed end
   local exclusive=elapsed-token.child_ms
   stats.inclusive_ms=stats.inclusive_ms+elapsed
   stats.exclusive_ms=stats.exclusive_ms+exclusive
   if elapsed<0 or exclusive<0 then fail('negative primitive duration')end
   if not values[1]then fail('primitive error: '..hook.label..': '..tostring(values[2]));error(values[2]);return nil end
   return unpack_values(values,2,values.n)
  end
 end
 local observer={result=result}
 observer.generation_enter=function(original,generator,map,row)
  if row.environment~='Underground'then return true end
  local owner=environment(original)
  if not owner then return fail('shipped native _ENV unavailable')end
  local hooks={}
  for _,name in ipairs(names)do
   if type(owner[name])~='function'then return fail('shipped primitive unavailable: '..name)end
   hooks[#hooks+1]={owner=owner,name=name,label=name,original=owner[name]}
  end
  if type(owner.table)~='table' or type(owner.table.weighted_rand)~='function'then
   return fail('shipped weighted table selection unavailable')
  end
  hooks[#hooks+1]={owner=owner.table,name='weighted_rand',label='table.weighted_rand',original=owner.table.weighted_rand}
  generations[row.id]={hooks=hooks,key=key()}
  return true
 end
 observer.procedure_start=function(generation,tag,id)
  if generation.environment~='Underground' or not selected[tag]then return true end
  if active then return fail('nested selected primitive scope')end
  local context=generations[generation.id]
  if not context or context.key~=key()then return fail('missing native primitive context')end
  if #result.scopes>=16 then return fail('primitive scope cap exceeded')end
  local row={id=#result.scopes+1,procedure_id=id,generation=generation.id,name=tag,
   environment=generation.environment,primitives={},call_count=0,primitive_ms=0}
  local scope={row=row,key=key(),hooks={},stack={},started=ticks()}
  result.scopes[#result.scopes+1]=row
  -- Verify every original BEFORE mutating any slot.
  for _,hook in ipairs(context.hooks)do
   if hook.owner[hook.name]~=hook.original then return fail('primitive changed before scope: '..hook.label)end
   local entry={owner=hook.owner,name=hook.name,label=hook.label,original=hook.original,
    original_raw=rawget(hook.owner,hook.name)}
   entry.wrapper=measure(scope,entry);scope.hooks[#scope.hooks+1]=entry
  end
  active=scope
  for _,hook in ipairs(scope.hooks)do
   -- Mark attempted writes so an exception after assignment still permits cleanup.
   local ok=pcall(function()hook.owner[hook.name]=hook.wrapper end)
   hook.installed=hook.owner[hook.name]==hook.wrapper
   if not ok or not hook.installed then fail('primitive install failed: '..hook.label);close(false);return false,'install failed' end
  end
  return true
 end
 observer.procedure_end=function(generation,tag,id)
  if generation.environment~='Underground' or not selected[tag]then return true end
  if not active or active.row.procedure_id~=id or active.row.generation~=generation.id or active.key~=key()then
   return fail('primitive scope endpoint mismatch')
  end
  return close(true)
 end
 observer.generation_exit=function(row,ok)
  if active and active.row.generation==row.id then close(false)end
  generations[row.id]=nil
  if not ok then return fail('native generation failed')end
  return #result.issues==0,table.concat(result.issues,'; ')
 end
 observer.restore=function()
  if active then close(false)end
  if next(generations)then fail('retained primitive generation context')end
  result.globals_restored=true
  local count=0
  for _,row in ipairs(result.scopes)do
   if row.globals_restored~=true then result.globals_restored=false end
   count=count+row.call_count
  end
  if count~=result.call_count then fail('primitive count mismatch')end
  result.status=#result.issues==0 and 'pass' or 'fail'
  return #result.issues==0,table.concat(result.issues,'; ')
 end
 return observer
end

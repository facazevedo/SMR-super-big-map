 -- Appended to the existing observer's ownership/full-grid comparison helpers.
 local function cache_api(scope)
  return {mask=scope.api.GridMask,intersect=scope.api.GridAnd,clear=scope.api.GridCircleSet,
   clone=clone,copy=function(dst,src)dst:copy(src)end,free=free}
 end
 local function new_cache(scope,place)
  local cache,why=make_cache(cache_api(scope),scope.frozen,place,scope.row.capacity)
  if not cache then fail(why);return end
  caches[#caches+1]=cache;return cache
 end
 local function append(scope,event)
  if #scope.events>=16384 then return fail('mutation journal cap')end
  scope.events[#scope.events+1]=event;return true
 end
 local function prepare(scope,args)
  if args.n~=5 or args[1]~=scope.source or not scope.place or args[2]==scope.source or args[2]==scope.place
   or math.type(args[3])~='integer' or math.type(args[4])~='integer' or math.type(args[5])~='integer'
   or args[5]~=1 or scope.pending then return fail('mask/source lineage contract')end
  if not scope.prepared then
   local ok,w,h,lo,hi=valid_grid(scope.api,scope.source,16777216)
   if not ok or not valid_grid(scope.api,scope.place,16777216,w,h)then return false end
   local row=scope.row;row.width,row.height,row.minimum,row.maximum=w,h,lo,hi
   row.capacity=math.min(8,math.floor(16777216/(w*h*4)))
   if row.capacity<1 then return fail('cache payload too large')end
   row.cache_byte_bound=row.capacity*w*h*4
   scope.guard=clone(scope.source);scope.frozen=clone(scope.source)
   scope.place_guard=clone(scope.place);scope.initial_place=clone(scope.place)
   scope.destination=own(scope.api.GridDest(scope.source))
   if not scope.guard or not scope.frozen or not scope.place_guard or not scope.initial_place or not scope.destination then return false end
   local test=clone(scope.source);if not test then return false end
   local value=test:get(0,0);test:set(0,0,value==0 and 1 or 0)
   local forward=difference(scope,scope.guard,test)
   local reverse=difference(scope,test,scope.guard);local same=difference(scope,scope.guard,scope.guard)
   free(test)
   if forward~=1 or reverse~=1 or same~=0 then return fail('native comparator self-test')end
   row.comparator_self_test=true;row.self_test_cells=3*w*h
   scope.cache=new_cache(scope,scope.place);if not scope.cache then return false end
   scope.prepared=true
  end
  return equal(scope,scope.source,scope.guard,'fixed_source') and equal(scope,scope.place,scope.place_guard,'live_place')
 end
 local function verify_and(scope,args)
  local request=scope.pending
  if not request or args.n~=2 or args[1]~=request.destination or args[2]~=scope.place then return fail('mask/And pairing')end
  scope.pending=nil
  scope.api.GridFill(scope.destination,7)
  local good,why=scope.cache.apply(scope.destination,request.from,request.to,request.scale)
  if not good then return fail(why)end
  if not equal(scope,scope.destination,args[1],'live_mask') or not equal(scope,scope.frozen,scope.guard,'private_source')then return false end
  local row=scope.row
  row.requests[#row.requests+1]={from=request.from,to=request.to,scale=request.scale}
  local key=tostring(request.from)..':'..tostring(request.to)..':'..tostring(request.scale)
  if not scope.keys[key]then scope.keys[key]=true;row.unique_keys=row.unique_keys+1 end
  return append(scope,{kind='request',from=request.from,to=request.to,scale=request.scale})
 end
 local function verify_clear(scope,args)
  if args.n~=4 or args[2]~=0 or scope.pending then return fail('unexpected place mutation')end
  local good,why=scope.cache.clear(args[2],args[3],args[4])
  if not good then return fail(why)end
  scope.api.GridCircleSet(scope.place_guard,args[2],args[3],args[4])
  if not equal(scope,scope.place,scope.place_guard,'cleared_place')then return false end
  scope.row.clears=scope.row.clears+1
  return append(scope,{kind='clear',value=args[2],center=args[3],radius=args[4]})
 end
 local function snapshot(stats)local out={};for k,v in pairs(stats)do out[k]=v end;return out end
 local function benchmark(scope,cached)
  local started=ticks()
  local place=clone(scope.initial_place);if not place then return end
  local cache=cached and new_cache(scope,place) or nil
  if cached and not cache then return end
  for _,event in ipairs(scope.events)do
   if event.kind=='clear'then
    scope.api.GridCircleSet(place,event.value,event.center,event.radius)
    if cache then local ok,why=cache.clear(event.value,event.center,event.radius);if not ok then fail(why);return end end
   else
    local dest=own(scope.api.GridDest(scope.frozen));if not dest then return end
    if cache then local ok,why=cache.apply(dest,event.from,event.to,event.scale);if not ok then fail(why);return end
    else scope.api.GridMask(scope.frozen,dest,event.from,event.to,event.scale);scope.api.GridAnd(dest,place)end
    free(dest)
   end
  end
  if cache then local ok,why=cache.close();if not ok then fail(why);return end end
  -- Comparison stays outside the timed work; clone/free the common replay place
  -- inside the interval and verify its final values via one shared survivor.
  scope.benchmark_final:copy(place)
  free(place)
  local elapsed=ticks()-started
  if elapsed<0 or not equal(scope,scope.benchmark_final,scope.place_guard,'benchmark_place')
   or not equal(scope,scope.frozen,scope.guard,'benchmark_source')then return end
  return {ms=elapsed,cached=cached,stats=cache and snapshot(cache.stats)}
 end
 local hook_names={'GridDistanceMars','GridMask','GridAnd','GridCircleSet'}
 local function restore_hook(scope)
  for _,name in ipairs(hook_names)do
   local hook=scope.hooks[name]
   if hook and hook.installed then
    if scope.owner[name]==hook.wrapper then rawset(scope.owner,name,hook.raw)
    else fail('native hook rebound '..name)end
    hook.installed=false
    if scope.owner[name]~=hook.original or rawget(scope.owner,name)~=hook.raw then fail('native restore '..name)end
   end
  end
  scope.installed=false;scope.row.hook_restored=#result.issues==0
  return scope.row.hook_restored
 end
 local observer={result=result}
 observer.generation_enter=function(original,generator,map,row)
  if row.environment~='Underground'then return true end
  if context then return fail('nested generation')end
  local owner=env_of(original);if not owner then return fail('native owner missing')end
  local api={}
  for _,name in ipairs({'GridDistanceMars','GridMask','GridAnd','GridCircleSet','GridFill','GridRepack',
   'GridAddMulDiv','GridAbs','GridCount','GridMinMax','GridDest','IsComputeGrid'})do
   if type(owner[name])~='function'then return fail('native API missing '..name)end
   api[name]=owner[name]
  end
  context={owner=owner,api=api,id=row.id,key=key()};return true
 end
 observer.procedure_start=function(generation,tag,id)
  if generation.environment~='Underground' or tag~='FindPrefabPos_Filler'then return true end
  if not context or context.id~=generation.id or context.key~=key() or active or #result.scopes~=0 then return fail('scope identity')end
  local row={generation=generation.id,procedure_id=id,name=tag,requests={},unique_keys=0,clears=0,distance_calls=0,
   comparisons=0,compared_cells=0,output_comparisons=0,immutable_comparisons=0,benchmarks={}}
  local scope={owner=context.owner,api=context.api,key=key(),row=row,keys={},events={},hooks={}}
  active=scope;result.scopes[#result.scopes+1]=row
  for _,name in ipairs(hook_names)do
   local hook={original=scope.owner[name],raw=rawget(scope.owner,name)};scope.hooks[name]=hook
   hook.wrapper=function(...)
    if active~=scope or key()~=scope.key then return hook.original(...)end
    local args=pack(...);local prepared=false
    if #result.issues==0 and name=='GridMask'then
     local ok,value=pcall(prepare,scope,args);prepared=ok and value==true
     if not ok then fail('prepare exception '..tostring(value))end
    end
    local returned=pack(pcall(hook.original,...))
    if not returned[1]then fail('actual native exception '..name);error(returned[2]);return nil end
    if #result.issues==0 then
     local ok,why=pcall(function()
      if name=='GridDistanceMars'then
       if args.n~=4 or args[1]==args[2] or scope.source then fail('distance lineage');return end
       scope.place,scope.source=args[1],args[2];row.distance_calls=row.distance_calls+1
      elseif name=='GridMask' and prepared then
       scope.pending={destination=args[2],from=args[3],to=args[4],scale=args[5]}
      elseif name=='GridAnd'then
       if scope.pending then verify_and(scope,args)
       elseif scope.prepared and (args[1]==scope.place or args[1]==scope.source)then fail('unexpected And mutation')end
      elseif name=='GridCircleSet' and scope.prepared then
       if args[1]==scope.place then verify_clear(scope,args)
       elseif args[1]==scope.source then fail('distance source circle mutation')end
      end
     end)
     if not ok then fail('eligibility verification '..tostring(why))end
    end
    return unpack_values(returned,2,returned.n)
   end
  end
  for _,name in ipairs(hook_names)do
   local hook=scope.hooks[name]
   local ok,why=pcall(function()scope.owner[name]=hook.wrapper end)
   hook.installed=scope.owner[name]==hook.wrapper;scope.installed=true
   if not ok or not hook.installed then restore_hook(scope);return fail('hook install '..tostring(why))end
  end
  return true
 end
 observer.procedure_end=function(generation,tag,id)
  if generation.environment~='Underground' or tag~='FindPrefabPos_Filler'then return true end
  local scope=active
  if not scope or scope.row.procedure_id~=id or scope.row.generation~=generation.id or scope.key~=key()then return fail('scope endpoint')end
  local ok,why=pcall(function()
   if not restore_hook(scope) or #result.issues~=0 then return end
   if not scope.prepared or scope.pending or #scope.row.requests==0 then fail('incomplete mask/And stream');return end
   -- Filler frees its caller-owned place grid before ProcEnd. Do not read it
   -- here: the last exact per-clear/request comparison is the live witness.
   local closed,err=scope.cache.close();if not closed then fail(err);return end
   scope.row.shadow_stats=snapshot(scope.cache.stats)
   scope.benchmark_final=own(scope.api.GridDest(scope.frozen));if not scope.benchmark_final then return end
   for _,order in ipairs({'old_new','new_old'})do
    local a=benchmark(scope,order=='new_old');if not a then return end
    local b=benchmark(scope,order=='old_new');if not b then return end
    scope.row.benchmarks[#scope.row.benchmarks+1]={order=order,old_ms=(a.cached and b or a).ms,
     new_ms=(a.cached and a or b).ms,stats=(a.cached and a or b).stats}
   end
   scope.row.journal_events=#scope.events;scope.events={}
   scope.row.completed=#result.issues==0
  end)
  if not ok then fail('scope completion '..tostring(why))end
  if scope.installed then pcall(restore_hook,scope)end
  cleanup();scope.events={};scope.row.scratch_released=next(owned)==nil;active=nil
  return #result.issues==0,table.concat(result.issues,'; ')
 end
 observer.generation_exit=function(row,ok)
  if row.environment~='Underground'then return true end
  if active then
   pcall(restore_hook,active);cleanup();active.events={};active.row.scratch_released=next(owned)==nil;active=nil
   fail('unfinished scope')
  end
  context=nil;if not ok then fail('native generation failed')end
  return #result.issues==0,table.concat(result.issues,'; ')
 end
 observer.restore=function()
  if active or context then fail('retained context')end
  if active then pcall(restore_hook,active);cleanup();active.events={};active.row.scratch_released=next(owned)==nil;active=nil end
  context=nil;cleanup()
  result.globals_restored=true
  for _,row in ipairs(result.scopes)do if not row.hook_restored then result.globals_restored=false end end
  result.scratch_released=next(owned)==nil;result.status=#result.issues==0 and 'pass' or 'fail'
  return #result.issues==0,table.concat(result.issues,'; ')
 end
 return observer
end

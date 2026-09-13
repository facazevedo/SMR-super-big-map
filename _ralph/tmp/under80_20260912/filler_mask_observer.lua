-- Private native shadow. Every real game write is still the original GridMask.
return function(ticks,make_cache)
 local result={status='ready',kind='filler_mask_shadow',scopes={},issues={}}
 local function fail(why)
  result.status='fail';result.issues[#result.issues+1]=tostring(why)
  return false,tostring(why)
 end
 local pack=function(...)return {n=select('#',...),...}end
 local unpack_values=table.unpack or unpack
 local context,active
 local owned,caches={},{}
 local function key()return coroutine.running() or 'main'end
 local function number(v)return type(v)=='number' and v==v and v>-math.huge and v<math.huge end
 local function env_of(fn)
  for i=1,200 do local name,value=debug.getupvalue(fn,i)
   if not name then break end
   if name=='_ENV' and type(value)=='table'then return value end
  end
 end
 local function own(grid)
  if (type(grid)~='table' and type(grid)~='userdata') or owned[grid]
   or (active and grid==active.source)then fail('invalid or aliased scratch allocation');return nil end
  owned[grid]=true;return grid
 end
 local function free(grid)
  if not owned[grid]then error('attempt to free unowned scratch');return end
  grid:free();owned[grid]=nil
 end
 local function clone(grid)return own(grid:clone())end
 local function cleanup()
  for _,cache in ipairs(caches)do
   local ok,good,why=pcall(cache.close)
   if not ok or not good then fail('cache cleanup: '..tostring(ok and why or good))end
  end
  caches={}
  for grid in pairs(owned)do local ok,why=pcall(free,grid)
   if not ok then fail('scratch cleanup: '..tostring(why))end
  end
 end
 local function valid_grid(api,grid,limit,w,h)
  if api.IsComputeGrid(grid)~='U'then return fail('comparison requires unsigned integer grid')end
  local x,y=grid:size()
  if not number(x) or not number(y) or x<=0 or y<=0 or x%1~=0 or y%1~=0
   or (w and (x~=w or y~=h))then return fail('native grid dimensions')end
  local lo,hi=api.GridMinMax(grid)
  if not number(lo) or not number(hi) or lo<0 or hi>limit or lo%1~=0 or hi%1~=0 then
   return fail('native grid outside exact integer comparison range')
  end
  return true,x,y,lo,hi
 end
 local function difference(scope,a,b)
  local api,row=scope.api,scope.row
  if not valid_grid(api,a,16777216,row.width,row.height)
   or not valid_grid(api,b,16777216,row.width,row.height)then return false end
  local delta=own(api.GridRepack(a,'f',32,true))
  if not delta then return false end
  local expected=own(api.GridRepack(b,'f',32,true))
  if not expected then return false end
  api.GridAddMulDiv(delta,expected,-1)
  api.GridAbs(delta)
  local different=api.GridCount(delta,1,2147483647)
  free(expected);free(delta)
  if not number(different) or different<0 or different%1~=0 then fail('invalid native difference count');return nil end
  return different
 end
 local function equal(scope,a,b,kind)
  local row=scope.row
  local different=difference(scope,a,b)
  if different~=0 then return fail('full-grid mismatch: '..kind..' '..tostring(different))end
  row.comparisons=row.comparisons+1
  row.compared_cells=row.compared_cells+row.width*row.height
  if kind=='live_mask' or kind=='sentinel_mask'then row.output_comparisons=row.output_comparisons+1
  else row.immutable_comparisons=row.immutable_comparisons+1 end
  return true
 end
 local function cache_api(scope)
  return {mask=scope.original_mask,clone=clone,copy=function(dst,src)dst:copy(src)end,free=free}
 end
 local function new_cache(scope)
  local cache,why=make_cache(cache_api(scope),scope.frozen,scope.row.capacity)
  if not cache then fail(why);return nil end
  caches[#caches+1]=cache;return cache
 end
 local function prepare(scope,args)
  if args.n~=5 or args[1]==args[2] or not number(args[3]) or not number(args[4]) or args[5]~=1 then
   return fail('unsupported real filler mask signature')
  end
  if scope.source and args[1]~=scope.source then return fail('filler changed source identity')end
  if not scope.source then
   scope.source=args[1]
   local ok,w,h,lo,hi=valid_grid(scope.api,scope.source,16777216)
   if not ok then return false end
   local row=scope.row
   row.width,row.height,row.minimum,row.maximum=w,h,lo,hi
   row.capacity=math.min(8,math.floor(16777216/(w*h*4)))
   if row.capacity<1 then return fail('source too large for bounded mask cache')end
   row.cache_byte_bound=row.capacity*w*h*4
   scope.guard=clone(scope.source);scope.frozen=clone(scope.source)
   scope.destination=own(scope.api.GridDest(scope.source))
   scope.oracle=own(scope.api.GridDest(scope.source))
   if not scope.guard or not scope.frozen or not scope.destination or not scope.oracle then return false end
   local test=clone(scope.source);if not test then return false end
   local value=test:get(0,0)
   test:set(0,0,value==0 and 1 or 0)
   local forward=difference(scope,scope.guard,test)
   local reverse=difference(scope,test,scope.guard)
   local same=difference(scope,scope.guard,scope.guard)
   free(test)
   if forward~=1 or reverse~=1 or same~=0 then return fail('native full-grid comparator self-test failed')end
   row.comparator_self_test=true;row.self_test_cells=3*w*h
   scope.cache=new_cache(scope)
   if not scope.cache then return false end
  end
  return true
 end
 local function verify(scope,args)
  local row,api=scope.row,scope.api
  if #row.requests>=8192 then return fail('filler request cap')end
  if not equal(scope,scope.source,scope.guard,'real_source')then return false end
  local from,to,scale=args[3],args[4],args[5]
  row.requests[#row.requests+1]={from=from,to=to,scale=scale}
  local by_to=scope.keys[from];if not by_to then by_to={};scope.keys[from]=by_to end
  local by_scale=by_to[to];if not by_scale then by_scale={};by_to[to]=by_scale end
  if not by_scale[scale]then by_scale[scale]=true;row.unique_keys=row.unique_keys+1 end
  api.GridFill(scope.destination,7)
  local good,why=scope.cache.apply(scope.destination,from,to,scale)
  if not good then return fail('private cache apply: '..tostring(why))end
  api.GridFill(scope.oracle,11)
  scope.original_mask(scope.frozen,scope.oracle,from,to,scale)
  if not equal(scope,scope.destination,args[2],'live_mask')
   or not equal(scope,scope.oracle,args[2],'sentinel_mask')
   or not equal(scope,scope.frozen,scope.guard,'private_source')then return false end
  return true
 end
 local function snapshot(stats)local out={};for k,v in pairs(stats)do out[k]=v end;return out end
 local function benchmark(scope,cached)
  local started=ticks();local cache
  if cached then cache=new_cache(scope);if not cache then return nil end end
  for _,request in ipairs(scope.row.requests)do
   local dest=own(scope.api.GridDest(scope.frozen))
   if not dest then return nil end
   if cache then
    local ok,why=cache.apply(dest,request.from,request.to,request.scale)
    if not ok then fail('benchmark cache: '..tostring(why));return nil end
   else scope.original_mask(scope.frozen,dest,request.from,request.to,request.scale)end
   free(dest)
  end
  if cache then local ok,why=cache.close();if not ok then fail('benchmark close: '..tostring(why));return nil end end
  local elapsed=ticks()-started
  if elapsed<0 then fail('negative benchmark duration');return nil end
  if not equal(scope,scope.frozen,scope.guard,'benchmark_source')then return nil end
  return {ms=elapsed,cached=cached,stats=cache and snapshot(cache.stats) or nil}
 end
 local function restore_hook(scope)
  if scope.installed then
   if scope.owner.GridMask~=scope.wrapper then return fail('real GridMask rebound')end
   scope.owner.GridMask=scope.original_mask
   rawset(scope.owner,'GridMask',scope.original_raw)
   if scope.owner.GridMask~=scope.original_mask or rawget(scope.owner,'GridMask')~=scope.original_raw then
    return fail('real GridMask restoration failed')
   end
  end
  scope.row.hook_restored=true;scope.installed=false
  return true
 end
 local observer={result=result}
 observer.generation_enter=function(original,generator,map,row)
  if row.environment~='Underground'then return true end
  if context then return fail('nested underground shadow context')end
  local owner=env_of(original)
  if not owner then return fail('native _ENV missing')end
  local api={}
  for _,name in ipairs({'GridMask','GridFill','GridRepack','GridAddMulDiv','GridAbs','GridCount',
   'GridMinMax','GridDest','IsComputeGrid'})do
   if type(owner[name])~='function'then return fail('native shadow API missing: '..name)end
   api[name]=owner[name]
  end
  context={owner=owner,api=api,id=row.id,key=key()}
  return true
 end
 observer.procedure_start=function(generation,tag,id)
  if generation.environment~='Underground' or tag~='FindPrefabPos_Filler'then return true end
  if not context or context.id~=generation.id or context.key~=key() or active or #result.scopes~=0 then
   return fail('invalid filler shadow scope')
  end
  local row={generation=generation.id,procedure_id=id,name=tag,requests={},unique_keys=0,
   comparisons=0,compared_cells=0,output_comparisons=0,immutable_comparisons=0,benchmarks={}}
  local scope={owner=context.owner,api=context.api,original_mask=context.owner.GridMask,
   original_raw=rawget(context.owner,'GridMask'),key=key(),row=row,keys={}}
  active=scope;result.scopes[#result.scopes+1]=row
  scope.wrapper=function(...)
   if active~=scope or key()~=scope.key then return scope.original_mask(...)end
   local args=pack(...);local prepared=false
   if #result.issues==0 then
    local ok,good=pcall(prepare,scope,args)
    prepared=ok and good==true
    if not ok then fail('shadow prepare exception: '..tostring(good))end
   end
   -- Never replace, suppress or roll back the real mask or its native return tuple.
   local values=pack(pcall(scope.original_mask,...))
   if not values[1]then fail('real mask error: '..tostring(values[2]));error(values[2]);return nil end
   if prepared then
    local ok,good=pcall(verify,scope,args)
    if not ok then fail('shadow verification exception: '..tostring(good))end
   end
   return unpack_values(values,2,values.n)
  end
  local ok,why=pcall(function()scope.owner.GridMask=scope.wrapper end)
  scope.installed=scope.owner.GridMask==scope.wrapper
  if not ok or not scope.installed then restore_hook(scope);return fail('shadow hook install: '..tostring(why))end
  return true
 end
 observer.procedure_end=function(generation,tag,id)
  if generation.environment~='Underground' or tag~='FindPrefabPos_Filler'then return true end
  local scope=active
  if not scope or scope.row.procedure_id~=id or scope.row.generation~=generation.id or key()~=scope.key then
   return fail('filler shadow endpoint mismatch')
  end
  local ok,why=pcall(function()
   if not restore_hook(scope)then return end
   if #result.issues~=0 then return end
   if #scope.row.requests==0 then fail('no filler requests captured');return end
   local closed,close_error=scope.cache.close()
   if not closed then fail(close_error);return end
   scope.row.shadow_stats=snapshot(scope.cache.stats)
   for _,order in ipairs({'old_new','new_old'})do
    local a=benchmark(scope,order=='new_old');if not a then return end
    local b=benchmark(scope,order=='old_new');if not b then return end
    scope.row.benchmarks[#scope.row.benchmarks+1]={order=order,
     old_ms=(a.cached and b or a).ms,new_ms=(a.cached and a or b).ms,
     stats=(a.cached and a or b).stats}
   end
   scope.row.completed=#result.issues==0
  end)
  if not ok then fail('shadow completion exception: '..tostring(why))end
  if scope.installed then local restored,err=pcall(restore_hook,scope);if not restored then fail(err)end end
  cleanup();scope.row.scratch_released=next(owned)==nil
  active=nil
  return #result.issues==0,table.concat(result.issues,'; ')
 end
 observer.generation_exit=function(row,ok)
  if row.environment~='Underground'then return true end
  if active then
   local restored,why=pcall(restore_hook,active);if not restored then fail(why)end
   cleanup();active.row.scratch_released=next(owned)==nil;active=nil
   fail('unfinished filler shadow scope')
  end
  context=nil
  if not ok then fail('native generation error')end
  return #result.issues==0,table.concat(result.issues,'; ')
 end
 observer.restore=function()
  if active or context then fail('retained filler shadow context')end
  if active then
   local ok,why=pcall(restore_hook,active);if not ok then fail(why)end
   cleanup();active.row.scratch_released=next(owned)==nil;active=nil
  end
  context=nil
  cleanup()
  result.globals_restored=not active
  for _,row in ipairs(result.scopes)do if not row.hook_restored then result.globals_restored=false end end
  result.scratch_released=next(owned)==nil
  result.status=#result.issues==0 and 'pass' or 'fail'
  return #result.issues==0,table.concat(result.issues,'; ')
 end
 return observer
end

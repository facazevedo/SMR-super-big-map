-- Private native shadow. Every real game write is still the original GridMask.
return function(ticks,make_cache)
 local result={status='ready',kind='playable_distance_shadow',scopes={},issues={}}
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
   or (active and (grid==active.place or grid==active.bounds or grid==active.current_primary))then fail('invalid or aliased scratch allocation');return nil end
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
  if kind=='raw_union' or kind=='primary' or kind=='secondary'then row.output_comparisons=row.output_comparisons+1
  else row.immutable_comparisons=row.immutable_comparisons+1 end
  return true
 end

 -- Appended to proven unsigned/f32 comparison and private ownership helpers.
 local function append(scope,event)
  if #scope.events>=4096 then return fail('distance journal cap')end
  scope.events[#scope.events+1]=event;return true
 end
 local function guards(scope)
  if not scope.place_freed and not equal(scope,scope.place,scope.place_guard,'place_guard')then return false end
  if not scope.bounds_freed and not equal(scope,scope.bounds,scope.frozen_bounds,'bounds_guard')then return false end
  return true
 end
 local function prepare_union(scope,args)
  if args.n~=3 or args[1]==args[2] or args[1]==args[3] or args[2]==args[3]
   or scope.pending or scope.current_primary then return fail('primary union lineage')end
  local api,row=scope.api,scope.row
  if not scope.prepared then
   scope.place,scope.bounds=args[1],args[3]
   local ok,w,h=valid_grid(api,scope.place,1)
   if not ok or not valid_grid(api,scope.bounds,1,w,h)then return false end
   row.width,row.height=w,h
   scope.place_guard=clone(scope.place);scope.initial_place=clone(scope.place)
   scope.frozen_bounds=clone(scope.bounds)
   scope.distance_place=own(api.GridDest(scope.place));scope.distance_bounds=own(api.GridDest(scope.bounds))
   scope.scratch=own(api.GridDest(scope.place))
   if not scope.place_guard or not scope.initial_place or not scope.frozen_bounds
    or not scope.distance_place or not scope.distance_bounds or not scope.scratch then return false end
   local test=clone(scope.place);if not test then return false end
   test:set(0,0,test:get(0,0)==0 and 1 or 0)
   local forward=difference(scope,scope.place_guard,test)
   local reverse=difference(scope,test,scope.place_guard);local same=difference(scope,scope.place_guard,scope.place_guard)
   free(test)
   if forward~=1 or reverse~=1 or same~=0 then return fail('comparator self-test')end
   row.comparator_self_test=true;row.self_test_cells=3*w*h
   api.GridDistanceMars(scope.frozen_bounds,scope.distance_bounds,1,1)
   scope.dirty=true;scope.prepared=true
  end
  if args[1]~=scope.place or args[3]~=scope.bounds or scope.place_freed or scope.bounds_freed then return fail('union changed input identity')end
  if not guards(scope)then return false end
  api.GridOr(scope.place_guard,scope.scratch,scope.frozen_bounds)
  if not equal(scope,scope.scratch,args[2],'raw_union')then return false end
  scope.pending=args[2];scope.current_primary=args[2]
  row.unions=row.unions+1;return true
 end
 local function return_shape(scope,kind,returned,destination)
  local shape={tostring(returned.n-1)}
  for i=2,returned.n do
   shape[#shape+1]=returned[i]==destination and 'destination' or type(returned[i])
  end
  local key=table.concat(shape,':');local map=scope.row.return_shapes[kind]
  map[key]=(map[key]or 0)+1
 end
 local function verify_distance(scope,args,returned)
  local api,row=scope.api,scope.row
  if not scope.prepared then return fail('distance before union')end
  if args.n==3 and args[1]==scope.pending and args[2]==1 and args[3]==1 then
   if not scope.dirty then return fail('unexpected primary without placement epoch')end
   api.GridDistanceMars(scope.place_guard,scope.distance_place,1,1)
   scope.dirty=false;scope.pending=nil
   api.GridMin(scope.distance_place,scope.scratch,scope.distance_bounds)
   if not equal(scope,scope.scratch,args[1],'primary')or not guards(scope)then return false end
   row.primary=row.primary+1;return_shape(scope,'primary',returned,args[1])
   return append(scope,{kind='primary'})
  elseif args.n==4 and args[1]==scope.place and args[2]~=scope.place and args[2]~=scope.bounds
   and args[3]==1 and args[4]==1 and not scope.pending and not scope.dirty and scope.current_primary then
   if not equal(scope,scope.distance_place,args[2],'secondary')or not guards(scope)then return false end
   row.secondary=row.secondary+1;return_shape(scope,'secondary',returned,args[2])
   return append(scope,{kind='secondary'})
  end
  return fail('unsupported actual distance boundary')
 end
 local function verify_write(scope,args)
  if args.n~=4 or math.type(args[2])~='integer' or args[2]~=1 or not number(args[4])
   or args[4]<0 or scope.pending or scope.place_freed then return fail('unsupported place write')end
  scope.api.GridCircleSet(scope.place_guard,args[2],args[3],args[4])
  if not equal(scope,scope.place,scope.place_guard,'place_write')then return false end
  scope.dirty=true;scope.row.writes=scope.row.writes+1
  return append(scope,{kind='write',value=args[2],center=args[3],radius=args[4]})
 end
 local function before_free(scope,args)
  if not scope.prepared then return true end
  if args.n~=1 then return fail('unsupported native free shape')end
  local grid=args[1]
  if grid==scope.bounds then
   if scope.bounds_freed or scope.pending or not guards(scope)then return fail('bounds free guard')end
   scope.bounds_freed=true;scope.row.bounds_frees=scope.row.bounds_frees+1
  elseif grid==scope.place then
   if scope.place_freed or scope.pending or not equal(scope,scope.place,scope.place_guard,'place_free')then return fail('place free guard')end
   scope.place_freed=true;scope.row.place_frees=scope.row.place_frees+1
  elseif grid and grid==scope.current_primary then
   if scope.pending then return fail('primary freed before distance')end
   scope.current_primary=nil;scope.row.primary_frees=scope.row.primary_frees+1
   return append(scope,{kind='release_primary'})
  end
  return true
 end
 local function benchmark(scope,cached)
  local api=scope.api;local started=ticks()
  local place=clone(scope.initial_place);local bounds=clone(scope.frozen_bounds)
  if not place or not bounds then return end
  local distance_place,distance_bounds,primary;local dirty=true
  local stats={primary=0,secondary=0,writes=0,primary_frees=0,transforms=0,unions=0,minimums=0,copies=0}
  if cached then
   distance_place=own(api.GridDest(place));distance_bounds=own(api.GridDest(bounds))
   if not distance_place or not distance_bounds then return end
   api.GridDistanceMars(bounds,distance_bounds,1,1);stats.transforms=stats.transforms+1
  end
  for _,event in ipairs(scope.events)do
   if event.kind=='primary'then
    if primary then fail('replay primary lifetime');return end
    primary=own(api.GridDest(place));if not primary then return end
    api.GridOr(place,primary,bounds);stats.unions=stats.unions+1
    if cached then
     if not dirty then fail('replay epoch');return end
     api.GridDistanceMars(place,distance_place,1,1);stats.transforms=stats.transforms+1;dirty=false
     api.GridMin(distance_place,primary,distance_bounds);stats.minimums=stats.minimums+1
    else api.GridDistanceMars(primary,1,1);stats.transforms=stats.transforms+1 end
    stats.primary=stats.primary+1
   elseif event.kind=='secondary'then
    local dest=own(api.GridDest(place));if not dest then return end
    if cached then
     if dirty or not primary then fail('replay secondary epoch');return end
     dest:copy(distance_place);stats.copies=stats.copies+1
    else api.GridDistanceMars(place,dest,1,1);stats.transforms=stats.transforms+1 end
    free(dest);stats.secondary=stats.secondary+1
   elseif event.kind=='write'then
    api.GridCircleSet(place,event.value,event.center,event.radius);dirty=true;stats.writes=stats.writes+1
   elseif event.kind=='release_primary'then
    if not primary then fail('replay missing primary');return end
    free(primary);primary=nil;stats.primary_frees=stats.primary_frees+1
   else fail('unknown replay event');return end
  end
  if primary then fail('replay retained primary');return end
  if cached then free(distance_place);free(distance_bounds)end
  scope.final_place:copy(place);scope.final_bounds:copy(bounds)
  free(place);free(bounds)
  local elapsed=ticks()-started
  if elapsed<0 or not equal(scope,scope.final_place,scope.place_guard,'replay_place')
   or not equal(scope,scope.final_bounds,scope.frozen_bounds,'replay_bounds')then return end
  return {ms=elapsed,cached=cached,stats=stats}
 end
 local hook_names={'GridOr','GridDistanceMars','GridCircleSet','GridOpFree'}
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
  for _,name in ipairs({'GridOr','GridDistanceMars','GridCircleSet','GridOpFree','GridMin','GridRepack',
   'GridAddMulDiv','GridAbs','GridCount','GridMinMax','GridDest','IsComputeGrid'})do
   if type(owner[name])~='function'then return fail('native API missing '..name)end
   api[name]=owner[name]
  end
  context={owner=owner,api=api,id=row.id,key=key()};return true
 end
 observer.procedure_start=function(generation,tag,id)
  if generation.environment~='Underground' or tag~='FindPrefabPos_Playable'then return true end
  if not context or context.id~=generation.id or context.key~=key() or active or #result.scopes~=0 then return fail('scope identity')end
  local row={generation=generation.id,procedure_id=id,name=tag,unions=0,primary=0,secondary=0,writes=0,
   primary_frees=0,bounds_frees=0,place_frees=0,return_shapes={primary={},secondary={}},
   comparisons=0,compared_cells=0,output_comparisons=0,immutable_comparisons=0,benchmarks={}}
  local scope={owner=context.owner,api=context.api,key=key(),row=row,events={},hooks={}}
  active=scope;result.scopes[#result.scopes+1]=row
  for _,name in ipairs(hook_names)do
   local hook={original=scope.owner[name],raw=rawget(scope.owner,name)};scope.hooks[name]=hook
   hook.wrapper=function(...)
    if active~=scope or key()~=scope.key then return hook.original(...)end
    local args=pack(...)
    if #result.issues==0 and name=='GridOpFree'then
     local ok,why=pcall(before_free,scope,args);if not ok then fail('before-free exception '..tostring(why))end
    end
    local returned=pack(pcall(hook.original,...))
    if not returned[1]then fail('actual native exception '..name);error(returned[2]);return nil end
    if #result.issues==0 then
     local ok,why=pcall(function()
      if name=='GridOr'then prepare_union(scope,args)
      elseif name=='GridDistanceMars'then verify_distance(scope,args,returned)
      elseif name=='GridCircleSet' and scope.prepared then
       if args[1]==scope.place then verify_write(scope,args)
       elseif args[1]==scope.bounds then fail('fixed bounds mutation')end
      end
     end)
     if not ok then fail('distance verification '..tostring(why))end
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
  if generation.environment~='Underground' or tag~='FindPrefabPos_Playable'then return true end
  local scope=active
  if not scope or scope.row.procedure_id~=id or scope.row.generation~=generation.id or scope.key~=key()then return fail('scope endpoint')end
  local ok,why=pcall(function()
   if not restore_hook(scope) or #result.issues~=0 then return end
   if not scope.prepared or scope.pending or scope.current_primary or not scope.place_freed or not scope.bounds_freed
    or scope.row.primary==0 or scope.row.secondary==0 then fail('incomplete distance stream');return end
   scope.final_place=own(scope.api.GridDest(scope.initial_place));scope.final_bounds=own(scope.api.GridDest(scope.frozen_bounds))
   if not scope.final_place or not scope.final_bounds then return end
   for _,order in ipairs({'old_new','new_old'})do
    local a=benchmark(scope,order=='new_old');if not a then return end
    local b=benchmark(scope,order=='old_new');if not b then return end
    local old,new=(a.cached and b or a),(a.cached and a or b)
    scope.row.benchmarks[#scope.row.benchmarks+1]={order=order,old_ms=old.ms,new_ms=new.ms,old_stats=old.stats,new_stats=new.stats}
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

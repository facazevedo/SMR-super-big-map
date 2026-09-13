-- Private observer factory: actual calls execute ONCE; the accepted prefix reads
-- a bounded event replay with separate terrain/matcher caches. No extra RNG/native
-- point/terrain/matcher/circle calls are issued by the accepted-prefix oracle.
return function(make_oracle)
 local result={status='ready',calls={},issues={},kind='decor_rejection_shadow'}
 local pack=function(...)return {n=select('#',...),...}end
 local unpack_values=table.unpack or unpack
 local active,row,oracle,queue,read_at
 local function fail(why)
  result.status='fail';result.error=result.error or tostring(why)
  result.issues[#result.issues+1]=tostring(why)
  return false
 end
 local function copy(t,limit)
  local out,n={},0
  for k,v in pairs(t)do
   n=n+1;if n>limit then fail('oracle cache-entry cap');return {},n end
   out[k]=v
  end
  return out,n
 end
 local function consume(name,...)
  local args=pack(...);local event=queue and queue[read_at]
  read_at=(read_at or 1)+1
  if not event or event.name~=name or args.n~=event.args.n then
   fail('prefix replay call mismatch '..name);return nil
  end
  for i=1,args.n do
   if args[i]~=event.args[i] or (type(args[i])=='number' and math.type(args[i])~=math.type(event.args[i]))then
    fail('prefix argument mismatch '..name..':'..i);return nil
   end
  end
  row.replayed=row.replayed+1
  return unpack_values(event.values,1,event.values.n)
 end
 local probe={result=result}
 function probe.wrap(name,fn)
  if type(fn)~='function'then return fn end
  return function(...)
   local values=pack(fn(...))
   if active then
    if #queue>=8 then fail('prefix event cap');return unpack_values(values,1,values.n)end
    queue[#queue+1]={name=name,args=pack(...),values=values}
    row.recorded=row.recorded+1
    row.peak_events=math.max(row.peak_events,#queue)
   end
   return unpack_values(values,1,values.n)
  end
 end
 function probe.enter(environment)
  if row then return fail('recursive decor Run')end
  row={environment=environment,prefixes=0,recorded=0,replayed=0,peak_events=0,
   outcomes=0,rejections={},rng_calls=0,prefix_rng_calls=0,oracle_initialized=false}
  result.calls[#result.calls+1]=row
  oracle=nil;return true
 end
 function probe.begin(template,x,y,allowed_count,allowed_types,type_cache,matches_cache,
  get_type,map,type_tile,revision,version,obstruct,decorated)
  if active or not row then return fail('prefix lifetime mismatch')end
  if row.prefixes>=1000000 then return fail('prefix count cap')end
  if not oracle then
   local types,nt=copy(type_cache,262144)
   local matches,nm=copy(matches_cache,8192)
   row.terrain_cache_entries,row.matcher_cache_entries=nt,nm
   oracle=make_oracle({map=map,type_tile=type_tile,revision=revision,version=version,
    allowed_count=allowed_count,allowed_types=allowed_types,type_cache=types,
    matches_cache=matches,obstruct=obstruct,decorated=decorated,
    get_type=type(get_type)=='function' and function(...)return consume('terrain',...)end or get_type,
    point_fn=function(...)return consume('point',...)end,
    SafeCall=function(...)return consume('safe',...)end,
    circle_hits=function(...)return consume('circle',...)end})
   row.oracle_initialized=true
  end
  active={marker=template.marker,x=x,y=y,radius=template.radius}
  queue={};read_at=1;return true
 end
 function probe.active()return active~=nil end
 function probe.finish(outcome,prefabs)
  if not active then return fail('prefix finish without begin')end
  local ok,expected,matched=pcall(oracle,active.marker,active.x,active.y,active.radius)
  if not ok then fail('prefix oracle error '..tostring(expected))
  elseif expected~=outcome or matched~=prefabs then fail('prefix outcome/list mismatch')end
  if read_at~=#queue+1 then fail('prefix event count mismatch')end
  row.prefixes=row.prefixes+1
  active,queue=nil,nil
  return result.error==nil
 end
 function probe.outcome(outcome)
  if not row then return fail('outcome outside decor Run')end
  if type(outcome)~='string'then return fail('invalid synthetic outcome')end
  row.outcomes=row.outcomes+1
  row.rejections[outcome]=(row.rejections[outcome]or 0)+1
 end
 function probe.stream(original,...)
  local stream=original(...)
  if type(stream)~='table'then return stream end
  local out={}
  for k,v in pairs(stream)do out[k]=v end
  for _,name in ipairs({'rand','seed'})do
   local fn=stream[name]
   out[name]=function(...)
    row.rng_calls=row.rng_calls+1
    if active then row.prefix_rng_calls=row.prefix_rng_calls+1;fail('rejection prefix drew RNG')end
    return fn(...)
   end
  end
  return out
 end
 function probe.leave(ok,stats)
  if active then fail('unfinished prefix')end
  if not row then return fail('Run leave without enter')end
  row.ok,row.stats=ok,stats
  if not ok or type(stats)~='table' or stats.error then fail('candidate decor Run failed')end
  if type(stats)~='table'then stats={}end
  if row.prefixes~=(stats.synthetic_finite_attempts or 0)
   or row.outcomes~=(stats.synthetic_attempts or 0) or row.recorded~=row.replayed then fail('complete decor census mismatch')end
  row,oracle,active,queue=nil,nil,nil,nil
  return result.error==nil
 end
 function probe.close()
  if row or active then fail('observer closed during Run')end
  result.status=result.error and 'fail' or 'pass'
  result.scratch_released=row==nil and active==nil and queue==nil and oracle==nil
  return result.error==nil
 end
 return probe
end

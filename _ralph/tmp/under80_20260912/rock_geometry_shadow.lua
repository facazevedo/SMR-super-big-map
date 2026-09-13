-- Candidate drives the game. Accepted Capture consumes a bounded replay of
-- every external object/terrain/ray/point/clock/eligibility call on private state.
local result={kind='rock_geometry_shadow',status='setup',calls={},issues={}}
rawset(_G,'SBM_ROCK_GEOMETRY_SHADOW',result)
local function fail(why)
 result.error=result.error or tostring(why);result.status='fail'
 if #result.issues<32 then result.issues[#result.issues+1]=tostring(why)end
end
local sbm,env
for _,mod in ipairs(ModsLoaded or {})do
 local s=mod.env and rawget(mod.env,'SuperBigMap')
 if s and s.RockGrounding then sbm,env=s,mod.env;break end
end
if not sbm or not sbm.GenerationGrids then fail('modules missing');return end
local original,final=sbm.RockGrounding.Capture,sbm.GenerationGrids.RebuildFinal
local function read(path)
 local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/'..path)
 if err or type(source)~='string'then fail('source unavailable '..path);return end
 return source:gsub('\r\n','\n')
end
local qualification=read('_ralph/tmp/under80_20260912/rock_geometry_native.lua')
local accepted=read('_ralph/runs/under80-20260912/artifacts/rock_geometry_candidate_2/accepted.lua')
local candidate=read('_ralph/runs/under80-20260912/artifacts/rock_geometry_candidate_2/candidate.lua')
if result.error then return end
local factory,why=load(qualification,'@rock-geometry-native','t',env)
if not factory then fail(why);return end
local geometry=factory()(sbm.Engine)
result.native_qualified=geometry.enabled
if not geometry.enabled then fail('native geometry did not qualify');return end
local cells,names,values={},{},{}
for i=1,100 do
 local name,value=debug.getupvalue(original,i);if not name then break end
 cells[name]=i;values[name]=value;if name~='_ENV'then names[#names+1]=name end
end
if not values.captures or not values.Global or not values.Eligible then fail('private seams missing');return end
local pack=function(...)return {n=select('#',...),...}end
local unpack_values=table.unpack or unpack
local function equal(a,b)
 if type(a)~=type(b)then return false end
 if type(a)=='number'then return a==b and math.type(a)==math.type(b)end
 if type(a)~='table'then return rawequal(a,b)end
 if rawequal(a,b)then return true end
 for k,v in pairs(a)do if not equal(v,b[k])then return false end end
 for k in pairs(b)do if a[k]==nil then return false end end
 return true
end
local MAIN={};local contexts={};local oracle_captures={}
local function thread()return coroutine.running() or MAIN end
local trace={}
local qualify=geometry.Qualify
geometry.Qualify=function(bounds,visual)
 local ok=qualify(bounds,visual)
 local context=contexts[thread()]
 if context then
  context.qualified=ok
  if not ok then context.noncanonical=true end
 end
 return ok
end
function trace.geometry(role,fn)
 local context=contexts[thread()]
 if fn~=geometry[role]then context.noncanonical=true end
end
function trace.noncanonical()contexts[thread()].noncanonical=true end
function trace.call(label,fn,...)
 local context=contexts[thread()]
 if not context then fail('external call outside Capture');return end
 local args=pack(...)
 if context.oracle then
  context.cursor=context.cursor+1
  local event=context.events[context.cursor]
  -- Arguments contain engine objects/points: require identity and subtype,
  -- never deep-compare live object trees or invoke their equality metamethods.
  local matches=event and event.label==label and event.fn==fn and event.args.n==args.n
  if matches then
   for i=1,args.n do
    if type(args[i])=='number'then
     if not equal(args[i],event.args[i])then matches=false;break end
    elseif not rawequal(args[i],event.args[i])then matches=false;break end
   end
  end
  if not matches then fail('replay mismatch '..label..' at '..context.cursor);return end
  return unpack_values(event.values,1,event.values.n)
 end
 if #context.events>=1024 then fail('per-Capture event cap');return end
 local returned=pack(fn(...))
 context.events[#context.events+1]={label=label,fn=fn,args=args,values=returned}
 return unpack_values(returned,1,returned.n)
end
local function global(name)
 local value=values.Global(name)
 if name=='point' or name=='GetPreciseTicks'then
  return function(...)return trace.call(name,value,...)end
 end
 -- The actual source has no terrain-table mutation or other terrain operation.
 if name=='terrain'then return {GetHeight=function(...)return trace.call('height',value.GetHeight,...)end}end
 return value
end
local function eligible(...)return trace.call('Eligible',values.Eligible,...)end
local function compile(source,oracle)
 if not oracle then
  local count
  source,count=source:gsub('(local (geometry_%d+_fn) = (bounds)%.([%w_]+))',function(line,fn,receiver,method)
   return line..'\n __trace.geometry("'..receiver..'_'..method..'", '..fn..')'
  end)
  local point_count
  source,point_count=source:gsub('(local (geometry_%d+_fn) = (visual)%.([%w_]+))',function(line,fn,receiver,method)
   return line..'\n __trace.geometry("'..receiver..'_'..method..'", '..fn..')'
  end)
  if count+point_count~=15 then fail('candidate geometry observer anchors');return end
  local fallback_count
  -- Preserve literal fallback count evaluation while refusing an impure oracle.
  source,fallback_count=source:gsub('\telse\n\tcount = math.min', '\telse\n\t\t__trace.noncanonical()\n\tcount = math.min')
  if fallback_count~=1 then fail('candidate count fallback anchor');return end
 end
 source=source:gsub('obj:([%w_]+)%(',function(name)return '__trace.call("'..name..'", obj.'..name..', obj, ' end)
 source=source:gsub(', obj, %)',', obj)')
 source=source:gsub('segment_fn%(obj, ray_from, ray_to%)','__trace.call("IntersectSegment", segment_fn, obj, ray_from, ray_to)')
 local prefix='local NativeGeometry, __trace\nlocal '..table.concat(names,',')..'\n'
 local chunk,err=load(prefix..source..'\nreturn Capture','@rock-geometry-shadow-Capture','t',env)
 if not chunk then fail(err);return end
 local fn=chunk();local joined=0
 for i=1,100 do
  local name=debug.getupvalue(fn,i);if not name then break end
  if name=='NativeGeometry'then debug.setupvalue(fn,i,geometry)
  elseif name=='__trace'then debug.setupvalue(fn,i,trace)
  elseif name=='Global'then debug.setupvalue(fn,i,global)
  elseif name=='Eligible'then debug.setupvalue(fn,i,eligible)
  elseif name=='captures' and oracle then debug.setupvalue(fn,i,oracle_captures)
  elseif cells[name]then debug.upvaluejoin(fn,i,original,cells[name]);joined=joined+1
  else fail('unjoined cell '..name);return end
 end
 result[oracle and 'oracle_joined' or 'candidate_joined']=joined
 return fn
end
local actual,oracle=compile(candidate,false),compile(accepted,true)
if result.error then return end
local config={sbm.Config.DEBUG_LOGGING_ENABLED,sbm.Config.DEBUG_LOADING_TIMINGS}
local capture_wrapper,final_wrapper,restored
local function restore()
 if restored then return end;restored=true
 if next(contexts) or next(oracle_captures)then fail('active shadow state')end
 if sbm.RockGrounding.Capture==capture_wrapper then sbm.RockGrounding.Capture=original else fail('capture rebound')end
 if sbm.GenerationGrids.RebuildFinal==final_wrapper then sbm.GenerationGrids.RebuildFinal=final else fail('final rebound')end
 result.config_unchanged=config[1]==sbm.Config.DEBUG_LOGGING_ENABLED and config[2]==sbm.Config.DEBUG_LOADING_TIMINGS
 if not result.config_unchanged then fail('config changed')end
 result.restored=sbm.RockGrounding.Capture==original and sbm.GenerationGrids.RebuildFinal==final
 result.status=result.error and 'fail' or 'pass'
 print('[SBM rock geometry shadow] '..result.status)
end
local rows={}
capture_wrapper=function(map,obj,...)
 local key=thread()
 if next(contexts)then fail('overlapping Capture');return original(map,obj,...)end
 local environment=map and map.mapdata and map.mapdata.Environment or '?'
 local row=rows[environment]
 if not row then
  if #result.calls>=4 then fail('environment cap');return original(map,obj,...)end
  row={environment=environment,captures=0,events=0,peak_events=0,records=0,mismatches=0,qualified=0}
  rows[environment]=row;result.calls[#result.calls+1]=row
 end
 local original_context=values.captures[map]
 if original_context then
  local copy={}
  for k,v in pairs(original_context)do copy[k]=v end
  copy.objects={};copy.stats={}
  for k,v in pairs(original_context.stats)do copy.stats[k]=v end
  -- Preserve an existing record if an unusual caller recaptures the same object.
  copy.objects[obj]=original_context.objects[obj]
  oracle_captures[map]=copy
 end
 local context={events={},cursor=0};contexts[key]=context
 local returned=pack(pcall(actual,map,obj,...))
 context.oracle=true
 local replayed
 if context.noncanonical then
  fail('noncanonical geometry: refuse repeated oracle getters');replayed={n=1,false}
 else replayed=pack(pcall(oracle,map,obj,...))end
 if context.qualified then row.qualified=row.qualified+1 end
 row.captures=row.captures+1;row.events=row.events+#context.events
 row.peak_events=math.max(row.peak_events,#context.events)
 local correct=returned[1] and replayed[1] and equal(returned,replayed) and context.cursor==#context.events
 if original_context then
  local expected=oracle_captures[map]
  correct=correct and equal(original_context.stats,expected.stats) and equal(original_context.objects[obj],expected.objects[obj])
  if original_context.objects[obj]then row.records=row.records+1 end
 end
 if not correct then row.mismatches=row.mismatches+1;fail('Capture record/counter/tuple mismatch')end
 contexts[key]=nil;oracle_captures[map]=nil
 if result.error or not returned[1] or returned[2]==false then fail('candidate/replay failed');restore()end
 if not returned[1]then error(returned[2]);return nil end
 return unpack_values(returned,2,returned.n)
end
final_wrapper=function(map,stage,...)
 local returned=pack(pcall(final,map,stage,...))
 if not returned[1] or returned[2]==false then fail('final failed');restore()end
 if map and map.mapdata and map.mapdata.Environment=='Surface' and stage=='post-pipeline scheduled revalidation'then restore()end
 if not returned[1]then error(returned[2]);return nil end
 return unpack_values(returned,2,returned.n)
end
sbm.RockGrounding.Capture=capture_wrapper;sbm.GenerationGrids.RebuildFinal=final_wrapper
result.status='ready';return 'ROCK_GEOMETRY_SHADOW_READY'

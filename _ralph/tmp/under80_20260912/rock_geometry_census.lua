-- Diagnostic only. Observe existing reads; never supply a cached answer.
local result={kind='rock_geometry_census',status='setup',calls={},issues={},joined_cells=0}
rawset(_G,'SBM_ROCK_GEOMETRY_CENSUS',result)
local function fail(why)
 result.error=result.error or tostring(why)
 result.failure_count=(result.failure_count or 0)+1
 if #result.issues<32 then result.issues[#result.issues+1]=tostring(why)end
 result.status='fail'
end
local sbm,env
for _,mod in ipairs(ModsLoaded or {})do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.RockGrounding then sbm,env=value,mod.env;break end
end
if not sbm or not sbm.GenerationGrids then fail('rock/final module unavailable');return end
local original,final=sbm.RockGrounding.Capture,sbm.GenerationGrids.RebuildFinal
if type(original)~='function' or type(final)~='function'then fail('capture/final seams missing');return end
local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/Code/sbm_rock_grounding.lua')
if err or type(source)~='string'then fail('capture source unavailable');return end
source=source:gsub('\r\n','\n')
local start=source:find('local function Capture(',1,true)
local stop=start and source:find('\nend\n',start,true)
if not start or not stop then fail('capture source anchors');return end
local body=source:sub(start,stop+3)
local roles={
 {'bounds','maxz',3},{'bounds','sizex',2},{'bounds','sizey',2},
 {'bounds','minx',1},{'bounds','miny',1},{'bounds','minz',1},
 {'visual','z',3},{'visual','x',1},{'visual','y',1},
}
local substitutions=0
for _,role in ipairs(roles)do
 local receiver,method,expected=table.unpack(role)
 local needle=receiver..':'..method..'()'
 local replacement='__probe.read("'..receiver..'.'..method..'", '..receiver..', '..receiver..'.'..method..')'
 local count
 body,count=body:gsub(receiver..':'..method..'%(%)',replacement)
 if count~=expected then fail('capture read anchor '..needle..' count '..count);return end
 substitutions=substitutions+count
end
result.source_substitutions=substitutions
local pack=function(...)return{n=select('#',...),...}end
local unpack_values=table.unpack or unpack
local MAIN={}
local contexts={}
local active_count=0
local function thread()return coroutine.running() or MAIN end
local probe={}
local function equal(a,b)
 if a.n~=b.n then return false end
 for i=1,a.n do
  if type(a[i])~=type(b[i]) or a[i]~=b[i]then return false end
  if type(a[i])=='number' and math.type(a[i])~=math.type(b[i])then return false end
 end
 return true
end
function probe.read(role,receiver,fn)
 local context=contexts[thread()]
 if not context then fail('read outside capture');return fn(receiver)end
 local aggregate=context.row.reads[role]
 if not aggregate then
  aggregate={calls=0,repeated=0,changed_value=0,changed_method=0,changed_receiver=0,nonscalar=0}
  context.row.reads[role]=aggregate
 end
 aggregate.calls=aggregate.calls+1
 -- Call the original method exactly once, with the original receiver and tuple.
 local values=pack(fn(receiver))
 for i=1,values.n do
  local kind=type(values[i])
  if kind~='number' and kind~='boolean' and kind~='nil' then aggregate.nonscalar=aggregate.nonscalar+1 end
 end
 local first=context.first[role]
 if first then
  aggregate.repeated=aggregate.repeated+1
  if first.fn~=fn then aggregate.changed_method=aggregate.changed_method+1 end
  if first.receiver~=receiver then aggregate.changed_receiver=aggregate.changed_receiver+1 end
  if not equal(first.values,values)then aggregate.changed_value=aggregate.changed_value+1 end
 else
  context.first[role]={fn=fn,receiver=receiver,values=values}
  context.size=context.size+1
  result.peak_roles=math.max(result.peak_roles or 0,context.size)
 end
 return unpack_values(values,1,values.n)
end
local cells,names={},{}
for i=1,200 do
 local name=debug.getupvalue(original,i)
 if not name then break end
 cells[name]=i;if name~='_ENV'then names[#names+1]=name end
end
local declaration=#names>0 and 'local '..table.concat(names,',')..'\n' or ''
local chunk,why=load('local __probe\n'..declaration..body..'\nreturn Capture','@rock-geometry-census-Capture','t',env)
if not chunk then fail(why);return end
local observed=chunk()
local injected=false
for i=1,200 do
 local name=debug.getupvalue(observed,i)
 if not name then break end
 if name=='__probe'then debug.setupvalue(observed,i,probe);injected=true
 elseif cells[name]then debug.upvaluejoin(observed,i,original,cells[name]);result.joined_cells=result.joined_cells+1
 else fail('unjoined capture cell '..name);return end
end
if not injected or type(math.type)~='function'then fail('probe/numeric subtype unavailable');return end
local config={sbm.Config.DEBUG_LOGGING_ENABLED,sbm.Config.DEBUG_LOADING_TIMINGS}
local capture_wrapper,final_wrapper
local restored=false
local rows={}
local function restore()
 if restored then return end
 restored=true
 if next(contexts)then fail('active capture at restoration')end
 if sbm.RockGrounding.Capture==capture_wrapper then sbm.RockGrounding.Capture=original else fail('capture rebound')end
 if sbm.GenerationGrids.RebuildFinal==final_wrapper then sbm.GenerationGrids.RebuildFinal=final else fail('final rebound')end
 result.config_unchanged=config[1]==sbm.Config.DEBUG_LOGGING_ENABLED and config[2]==sbm.Config.DEBUG_LOADING_TIMINGS
 if not result.config_unchanged then fail('config changed')end
 result.restored=sbm.RockGrounding.Capture==original and sbm.GenerationGrids.RebuildFinal==final
 result.status=result.error and 'fail' or 'pass'
 print('[SBM rock geometry census] '..result.status)
end
capture_wrapper=function(map,obj,...)
 local key=thread()
 if contexts[key]then fail('recursive Capture');return original(map,obj,...)end
 if active_count>=16 then fail('concurrent capture cap');return original(map,obj,...)end
 local environment=map and map.mapdata and map.mapdata.Environment or '?'
 local row=rows[environment]
 if not row then
  if #result.calls>=4 then fail('environment cap');return original(map,obj,...)end
  row={environment=environment,captures=0,reads={}};rows[environment]=row;result.calls[#result.calls+1]=row
 end
 row.captures=row.captures+1
 contexts[key]={row=row,first={},size=0}
 active_count=active_count+1
 result.peak_active=math.max(result.peak_active or 0,active_count)
 local values=pack(pcall(observed,map,obj,...))
 contexts[key]=nil
 active_count=active_count-1
 if not values[1]then fail('capture raised: '..tostring(values[2]));restore();error(values[2]);return nil end
 -- Capture normally returns no values; preserve that, and reject unexpected false results.
 if values[2]==false then fail('capture returned false');restore()end
 return unpack_values(values,2,values.n)
end
final_wrapper=function(map,stage,...)
 local values=pack(pcall(final,map,stage,...))
 if not values[1]then fail('final raised');restore();error(values[2]);return nil end
 if values[2]==false then fail('final returned false');restore()end
 if map and map.mapdata and map.mapdata.Environment=='Surface' and stage=='post-pipeline scheduled revalidation'then restore()end
 return unpack_values(values,2,values.n)
end
sbm.RockGrounding.Capture=capture_wrapper;sbm.GenerationGrids.RebuildFinal=final_wrapper
result.status='ready'
return 'ROCK_GEOMETRY_CENSUS_READY'

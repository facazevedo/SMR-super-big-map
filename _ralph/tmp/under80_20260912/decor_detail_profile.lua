-- Diagnostic-only helper census/timing. Clone only Run and join every original
-- private upvalue cell; do not reload the module or replace any engine API.
local result={status='setup',calls={}}
rawset(_G,'SBM_DECOR_DETAIL_DIAGNOSTIC',result)
local env,sbm
for _,mod in ipairs(ModsLoaded or {})do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.DecorTopUp then env,sbm=mod.env,value;break end
end
local function fail(why)result.status='fail';result.error=why;error(why)end
if not sbm then fail('decor detail mod missing');return end
local original=sbm.DecorTopUp.Run
local cells,names={},{}
for i=1,200 do
 local name=debug.getupvalue(original,i)
 if not name then break end
 cells[name]=i
 if name~='_ENV' then names[#names+1]=name end
end
local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/Code/sbm_decor_topup.lua')
if err or type(source)~='string' then fail('decor detail source missing');return end
source=source:gsub('\r\n','\n')
local a=source:find('function DecorTopUp.Run(',1,true)
if not a then fail('decor Run anchor');return end
source=source:sub(a):gsub('^function DecorTopUp.Run%(', 'local function ProfiledRun(')
local function once(anchor,replacement)
 local first,last=source:find(anchor,1,true)
 if not first or source:find(anchor,last+1,true)then fail('ambiguous anchor '..anchor);return false end
 source=source:sub(1,first-1)..replacement..source:sub(last+1);return true
end
if not once('local function ProfiledRun(map, pass_edits_already_suspended)\n',
 'local function ProfiledRun(map, pass_edits_already_suspended)\n'
 ..' local circle_hits=probe_measure("circle_hits",circle_hits,1)\n'
 ..' local original_cursor=NewDecorInteriorCursor\n'
 ..' local function NewDecorInteriorCursor(...) return probe_measure("cursor",original_cursor(...),2) end\n')then return end
if not once('if not stream then error("BraidRandom unavailable") end',
 'if not stream then error("BraidRandom unavailable") end\n'
 ..' stream.rand=probe_measure("rand",stream.rand,1)\n'
 ..' stream.seed=probe_measure("seed",stream.seed,1)\n'
 ..' place_prefab=probe_measure("place_prefab",place_prefab,2)')then return end
if not once('\t\t-- 5. Vanilla\'s loop',
 '\t\ttry_stamp=probe_measure("try_stamp",try_stamp,2)\n\t\t-- 5. Vanilla\'s loop')then return end
if not once('local get_type = terrain_api.GetTerrainType',
 'local get_type = probe_measure("native_get_type",terrain_api.GetTerrainType,1)')then return end
if not once('\t\t\t-- Vanilla-like context means',
 '\t\t\tterrain_type_at=probe_measure("terrain_type_at",terrain_type_at,1)\n'
 ..'\t\t\t-- Vanilla-like context means')then return end
local active,depth= nil,0
local starts,children={},{}
local function measure(name,fn,arity)
 if type(fn)~='function' then return fn end
 local counters=active.helpers[name]
 if not counters then counters={calls=0,inclusive_ms=0,exclusive_ms=0};active.helpers[name]=counters end
 local function begin()
  depth=depth+1;starts[depth]=GetPreciseTicks();children[depth]=0
 end
 local function finish()
  local elapsed=GetPreciseTicks()-starts[depth]
  counters.calls=counters.calls+1
  counters.inclusive_ms=counters.inclusive_ms+elapsed
  counters.exclusive_ms=counters.exclusive_ms+elapsed-children[depth]
  depth=depth-1
  if depth>0 then children[depth]=children[depth]+elapsed end
 end
 if arity==1 then return function(...)
  begin();local value=fn(...);finish();return value
 end end
 return function(...)
  begin();local x,y=fn(...);finish();return x,y
 end
end
local prefix='local probe_measure=...\n'
if #names>0 then prefix=prefix..'local '..table.concat(names,',')..'\n'end
local chunk,why=load(prefix..source..'\nreturn ProfiledRun','@decor-detail-profile','t',env)
if not chunk then fail(tostring(why));return end
local candidate=chunk(measure)
for i=1,200 do
 local name=debug.getupvalue(candidate,i)
 if not name then break end
 if cells[name]then debug.upvaluejoin(candidate,i,original,cells[name])
 elseif name~='probe_measure'then fail('unjoined decor cell '..name);return end
end
local original_final=sbm.GenerationGrids.RebuildFinal
sbm.DecorTopUp.Run=function(map,...)
 if active then fail('recursive decor profiling');return original(map,...)end
 active={environment=map.mapdata.Environment,helpers={}}
 local row=active
 local start=GetPreciseTicks()
 local ok,stats=candidate(map,...)
 row.total_ms=GetPreciseTicks()-start
 row.ok,row.stats=ok,stats
 active=nil
 result.calls[#result.calls+1]=row
 if not ok or (stats and stats.error) or depth~=0 then fail('decor helper run failed')end
 return ok,stats
end
local unpack_values=table.unpack or unpack
local function pack(...)return {n=select('#',...),...}end
sbm.GenerationGrids.RebuildFinal=function(map,stage,...)
 local values=pack(original_final(map,stage,...))
 if map.mapdata.Environment=='Surface' and stage=='post-pipeline scheduled revalidation' then
  sbm.DecorTopUp.Run=original
  sbm.GenerationGrids.RebuildFinal=original_final
  result.restored=true
  if not result.error and #result.calls>0 then result.status='pass' end
 end
 return unpack_values(values,1,values.n)
end
result.status='ready'
return 'DECOR_DETAIL_PROFILE_READY'

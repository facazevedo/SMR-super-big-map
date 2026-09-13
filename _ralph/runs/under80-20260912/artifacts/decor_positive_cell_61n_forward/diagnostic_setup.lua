-- Compare every native query using separate old/new indexes. Clone ONLY Run;
-- join every original private cell except the private circle query wrapper.
local result={status='setup',calls={}}
rawset(_G,'SBM_DECOR_POSITIVE_CELL_DIAGNOSTIC',result)
local reverse=false
result.reverse=reverse
local env,sbm
for _,mod in ipairs(ModsLoaded or {})do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.DecorTopUp then env,sbm=mod.env,value;break end
end
local function fail(why)result.status='fail';result.error=result.error or tostring(why);error(why)end
if not sbm then fail('positive cell mod missing');return end
local original=sbm.DecorTopUp.Run
local cells,names,values={},{},{}
for i=1,200 do
 local name,value=debug.getupvalue(original,i)
 if not name then break end
 cells[name],values[name]=i,value
 if name~='_ENV' then names[#names+1]=name end
end
local function read(path)
 local err,text=AsyncFileToString('D:/PROJS/SMR/super-big-map/'..path)
 if err or type(text)~='string' then fail('source missing '..path);return end
 return text:gsub('\r\n','\n')
end
local source=read('Code/sbm_decor_topup.lua')
local helper=read('_ralph/tmp/under80_20260912/decor_positive_cell.lua')
if not source or not helper then return end
local body=source:match('(local function circle_hits%(.-)\nend')
if not body then fail('indexed body unavailable');return end
body=body..'\nend'
local indexed_body,n=body:gsub('then return true end','then return true, c end')
if n~=1 then fail('indexed winning circle anchor');return end
local chunk,why=load(indexed_body..'\nreturn circle_hits','@positive-cell-index','t',env)
if not chunk then fail(why);return end
local indexed=chunk()
local factory_chunk,why=load(helper,'@positive-cell-helper','t',env)
if not factory_chunk then fail(why);return end
local candidate_query=factory_chunk()(indexed)
local old=values.circle_hits
if type(old)~='function' then fail('old circle query missing');return end
local active
local function query(list,x,y,radius)
 local copy=active.lists[list]
 if not copy then copy={};active.lists[list]=copy end
 for i=#copy+1,#list do copy[i]=list[i] end
 local serial=copy.spatial_index and copy.spatial_index.serial or 0
 local expected,actual,start
 if reverse then
  start=GetPreciseTicks();actual=candidate_query(copy,x,y,radius)
  active.new_ms=active.new_ms+GetPreciseTicks()-start
  start=GetPreciseTicks();expected=old(list,x,y,radius)
  active.old_ms=active.old_ms+GetPreciseTicks()-start
 else
  start=GetPreciseTicks();expected=old(list,x,y,radius)
  active.old_ms=active.old_ms+GetPreciseTicks()-start
  start=GetPreciseTicks();actual=candidate_query(copy,x,y,radius)
  active.new_ms=active.new_ms+GetPreciseTicks()-start
 end
 active.queries=active.queries+1
 if actual and (copy.spatial_index and copy.spatial_index.serial or 0)==serial then
  active.certified=active.certified+1
 end
 if expected~=actual then
  active.mismatches=active.mismatches+1
  active.first_mismatch=active.first_mismatch or {x=x,y=y,radius=radius}
  fail('native positive-cell query mismatch')
 end
 return expected
end
local a=source:find('function DecorTopUp.Run(',1,true)
if not a then fail('Run anchor missing');return end
local run_source=source:sub(a):gsub('^function DecorTopUp.Run%(', 'local function ShadowRun(')
local prefix=#names>0 and ('local '..table.concat(names,',')..'\n') or ''
local run_chunk,why=load(prefix..run_source..'\nreturn ShadowRun','@positive-cell-Run','t',env)
if not run_chunk then fail(why);return end
local shadow=run_chunk()
for i=1,200 do
 local name=debug.getupvalue(shadow,i)
 if not name then break end
 if name=='circle_hits' then debug.setupvalue(shadow,i,query)
 elseif cells[name] then debug.upvaluejoin(shadow,i,original,cells[name])
 else fail('unjoined Run cell '..name);return end
end
local original_final=sbm.GenerationGrids.RebuildFinal
sbm.DecorTopUp.Run=function(map,...)
 if active then fail('recursive positive-cell shadow');return original(map,...)end
 local row={environment=map.mapdata.Environment,queries=0,certified=0,mismatches=0,
  old_ms=0,new_ms=0,lists={}}
 active=row
 local ok,stats=shadow(map,...)
 active=nil
 row.ok,row.stats=ok,stats
 row.indexes={}
 for original_list,copy in pairs(row.lists)do
  local cache=copy.positive_cell_cache or {}
  row.indexes[#row.indexes+1]={circles=#original_list,slots=cache.slots,learned=cache.learned,
   full_queries=copy.spatial_index and copy.spatial_index.serial or 0}
 end
 row.lists=nil
 result.calls[#result.calls+1]=row
 if not ok or (stats and stats.error) then fail('decor run failed')end
 return ok,stats
end
local function pack(...)return {n=select('#',...),...}end
local unpack_values=table.unpack or unpack
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
return 'DECOR_POSITIVE_CELL_SHADOW_READY'

-- Full-map candidate Run, with exact old/new circle and cursor argument shadows.
-- Only the original cursor calls the actual private RNG; candidate calls replay
-- those exact arguments/values. Restore original wrappers at surface readiness.
local result={status='setup',calls={}}
rawset(_G,'SBM_DECOR_HOTPATH_DIAGNOSTIC',result)
local env,sbm
for _,mod in ipairs(ModsLoaded or {})do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.DecorTopUp then env,sbm=mod.env,value;break end
end
local function fail(why)result.status='fail';result.error=why;error(why)end
if not sbm then fail('hotpath mod missing');return end
local original=sbm.DecorTopUp.Run
local cells,names,values={},{},{}
for i=1,200 do
 local name,value=debug.getupvalue(original,i)
 if not name then break end
 cells[name],values[name]=i,value
 if name~='_ENV' then names[#names+1]=name end
end
local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/runs/under80-20260912/artifacts/decor_hotpath_research_2/decor_candidate.lua')
if err or type(source)~='string' then fail('hotpath source missing');return end
source=source:gsub('\r\n','\n')
local function compile_helper(name)
 local a=source:find('local function '..name..'(',1,true)
 local b=a and source:find('\nend',a,true)
 if not b then fail('helper anchor '..name);return end
 local chunk,why=load(source:sub(a,b+3)..'\nreturn '..name,'@hotpath-'..name,'t',env)
 if not chunk then fail(tostring(why));return end
 return chunk()
end
local new_circle=compile_helper('circle_hits')
local new_cursor=compile_helper('NewDecorInteriorCursor')
local old_circle,old_cursor=values.circle_hits,values.NewDecorInteriorCursor
if not new_circle or not new_cursor or not old_circle or not old_cursor then fail('helper unavailable');return end
local active
local function circle_shadow(list,x,y,radius)
 local start=GetPreciseTicks()
 local expected=old_circle(list,x,y,radius)
 active.old_circle_ms=active.old_circle_ms+GetPreciseTicks()-start
 local serial=list.spatial_index and list.spatial_index.serial
 start=GetPreciseTicks()
 local actual=new_circle(list,x,y,radius)
 active.new_circle_ms=active.new_circle_ms+GetPreciseTicks()-start
 active.circle_queries=active.circle_queries+1
 if actual and list.spatial_index and list.spatial_index.serial==serial then
  active.hint_hits=active.hint_hits+1
 end
 if actual~=expected then active.circle_mismatches=active.circle_mismatches+1;fail('circle mismatch')end
 return expected
end
local function cursor_shadow(x0,y0,x1,y1,step,rand)
 local args,draws={},{}
 local read,write=0,0
 local function record(n)
  write=write+1;args[write]=n;draws[write]=rand(n);return draws[write]
 end
 local function replay(n)
  read=read+1
  if read>write or args[read]~=n then
   active.cursor_mismatches=active.cursor_mismatches+1;fail('cursor RNG argument/count mismatch');return 0
  end
  return draws[read]
 end
 local before=old_cursor(x0,y0,x1,y1,step,record)
 local candidate=new_cursor(x0,y0,x1,y1,step,replay)
 active.cursor_constructors=active.cursor_constructors+1
 active.cursor_draws=active.cursor_draws+write
 if read~=write then active.cursor_mismatches=active.cursor_mismatches+1;fail('constructor RNG count mismatch')end
 return function()
  read,write=0,0
  local ax,ay=before()
  local bx,by=candidate()
  active.cursor_calls=active.cursor_calls+1
  active.cursor_draws=active.cursor_draws+write
  if read~=write or ax~=bx or ay~=by then
   active.cursor_mismatches=active.cursor_mismatches+1;fail('cursor coordinate/draw mismatch')
  end
  return ax,ay
 end
end
local a=source:find('function DecorTopUp.Run(',1,true)
if not a then fail('Run source anchor');return end
local run_source=source:sub(a):gsub('^function DecorTopUp.Run%(', 'local function CandidateRun(')
local prefix=#names>0 and ('local '..table.concat(names,',')..'\n') or ''
local chunk,why=load(prefix..run_source..'\nreturn CandidateRun','@decor-hotpath-Run','t',env)
if not chunk then fail(tostring(why));return end
local candidate=chunk()
for i=1,200 do
 local name=debug.getupvalue(candidate,i)
 if not name then break end
 if name=='circle_hits' then debug.setupvalue(candidate,i,circle_shadow)
 elseif name=='NewDecorInteriorCursor' then debug.setupvalue(candidate,i,cursor_shadow)
 elseif cells[name]then debug.upvaluejoin(candidate,i,original,cells[name])
 else fail('unjoined Run cell '..name);return end
end
local original_final=sbm.GenerationGrids.RebuildFinal
sbm.DecorTopUp.Run=function(map,...)
 if active then fail('recursive decor shadow');return original(map,...)end
 active={environment=map.mapdata.Environment,circle_queries=0,hint_hits=0,circle_mismatches=0,
  old_circle_ms=0,new_circle_ms=0,cursor_constructors=0,cursor_calls=0,cursor_draws=0,cursor_mismatches=0}
 local row=active
 local ok,stats=candidate(map,...)
 row.ok,row.stats=ok,stats
 active=nil
 result.calls[#result.calls+1]=row
 if not ok or (stats and stats.error) then fail('candidate Run failed')end
 return ok,stats
end
local unpack_values=table.unpack or unpack
local function pack(...)return {n=select('#',...),...}end
sbm.GenerationGrids.RebuildFinal=function(map,stage,...)
 local packed=pack(original_final(map,stage,...))
 if map.mapdata.Environment=='Surface' and stage=='post-pipeline scheduled revalidation' then
  sbm.DecorTopUp.Run=original
  sbm.GenerationGrids.RebuildFinal=original_final
  result.restored=true
  local row=result.calls[1]
  if not result.error and row and row.circle_queries>0 and row.hint_hits>0 and row.cursor_calls>0 then result.status='pass' end
 end
 return unpack_values(packed,1,packed.n)
end
result.status='ready'
return 'DECOR_HOTPATH_SHADOW_READY'

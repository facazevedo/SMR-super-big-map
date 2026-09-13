-- Diagnostic only. Preserve lexical operands and every original private cell.
local result={status='setup',calls={}}
rawset(_G,'SBM_CREASE_DETAIL_DIAGNOSTIC',result)
local env,sbm
for _,mod in ipairs(ModsLoaded or {}) do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.Config then env,sbm=mod.env,value;break end
end
local function fail(why)result.status='fail';result.error=why;error(why)end
if not sbm then fail('crease detail mod missing');return end
local function upvalue(fn,wanted)
 for i=1,200 do
  local name,value=debug.getupvalue(fn,i);if not name then break end
  if name==wanted then return value,i end
 end
end
local caller=sbm.TerrainCopy.StretchSourceToFull
local original,call_index=upvalue(caller,'RepairInternalHeightStep')
if type(original)~='function' then fail('crease callsite missing');return end
local cells,names={},{}
for i=1,200 do
 local name=debug.getupvalue(original,i);if not name then break end
 cells[name]=i;if name~='_ENV' then names[#names+1]=name end
end
local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/Code/sbm_terrain_copy.lua')
if err or type(source)~='string' then fail('crease source missing');return end
source=source:gsub('\r\n','\n')
local a=source:find('local function RepairInternalHeightStep(',1,true)
local b=a and source:find('local function RepairQualifiedSourceHeightSteps(',a,true)
if not a or not b then fail('crease anchors');return end
source=source:sub(a,b-1)
local function once(anchor,replacement)
 local first,last=source:find(anchor,1,true)
 if not first or source:find(anchor,last+1,true) then fail('ambiguous anchor '..anchor);return false end
 source=source:sub(1,first-1)..replacement..source:sub(last+1);return true
end
local active,depth=nil,0
local starts,children={},{}
local function measure(name,fn,arity)
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
  depth=depth-1;if depth>0 then children[depth]=children[depth]+elapsed end
 end
 if arity==1 then return function(...)
  begin();local value=fn(...);finish();return value
 end end
 return function(...)
  begin();local x,y=fn(...);finish();return x,y
 end
end
local function index_wrapper(fn)
 local timed=measure('native_discovery',fn,2)
 return function(...)
  local rows,stats=timed(...)
  if rows then
   local census=active.index_census
   for _,row in pairs(rows) do
    local last,run=nil,0
    for _,perp in ipairs(row) do
     census.positions=census.positions+1
     if last and perp==last+1 then run=run+1
     else census.runs=census.runs+1;run=1 end
     if run>census.longest then census.longest=run end
     last=perp
    end
   end
  end
  return rows,stats
 end
end
if not once('local function RepairInternalHeightStep(grid, wide_ring_only)\n',
 'local function RepairInternalHeightStep(grid, wide_ring_only)\n'
 ..' local BuildHeightStepDiscoveryIndex=probe_index(BuildHeightStepDiscoveryIndex)\n'
 ..' local TranslateHeightTrack=probe_measure("native_translation",TranslateHeightTrack,2)\n') then return end
if not once('\t-- INDEXED_HEIGHT_REFINE_END\n',
 '\t-- INDEXED_HEIGHT_REFINE_END\n\tRefineIndexedHeightStep=probe_measure("indexed_refinement",RefineIndexedHeightStep,2)\n') then return end
if not once('\tlocal refinement_guide = not wide_ring_only and NewHeightStepRefinementGuide() or nil\n',
 '\tlocal refinement_guide = not wide_ring_only and NewHeightStepRefinementGuide() or nil\n'
 ..' if refinement_guide then refinement_guide.Candidates=probe_measure("guide_query",refinement_guide.Candidates,1) end\n') then return end
for _,spec in ipairs({{'offer_candidate','feather_join',1},{'collect_axis','scan_line_range',1},
 {'refine_step','collect_axis',1},{'validate_sampled_track','refine_step',2}}) do
 local anchor='\tlocal function '..spec[1]..'('
 if not once(anchor,'\t'..spec[2]..'=probe_measure("'..spec[2]..'",'..spec[2]..','..spec[3]..')\n'..anchor) then return end
end
local prefix='local probe_measure,probe_index=...\n'
if #names>0 then prefix=prefix..'local '..table.concat(names,',')..'\n' end
local chunk,why=load(prefix..source..'\nreturn RepairInternalHeightStep','@crease-detail-profile','t',env)
if not chunk then fail(tostring(why));return end
local candidate=chunk(measure,index_wrapper)
for i=1,200 do
 local name=debug.getupvalue(candidate,i);if not name then break end
 if cells[name] then debug.upvaluejoin(candidate,i,original,cells[name])
 elseif name~='probe_measure' and name~='probe_index' then fail('unjoined crease cell '..name);return end
end
local unpack_values=table.unpack or unpack
local function pack(...)return {n=select('#',...),...}end
local function wrapper(grid,wide_ring_only)
 if active then fail('recursive crease call');return original(grid,wide_ring_only) end
 local w,h=grid:size()
 active={wide_ring_only=wide_ring_only,width=w,height=h,helpers={},index_census={positions=0,runs=0,longest=0}}
 local row=active;local started=GetPreciseTicks()
 local values=pack(candidate(grid,wide_ring_only))
 row.total_ms=GetPreciseTicks()-started;row.ok=values[1];row.report=values[2];row.stats=values[4]
 result.calls[#result.calls+1]=row;active=nil
 if depth~=0 or (row.report and row.report.error) then fail('crease profile incomplete') end
 return unpack_values(values,1,values.n)
end
if debug.setupvalue(caller,call_index,wrapper)~='RepairInternalHeightStep' then fail('crease installation');return end
local original_final=sbm.GenerationGrids.RebuildFinal
sbm.GenerationGrids.RebuildFinal=function(map,stage,...)
 local values=pack(original_final(map,stage,...))
 if map.mapdata.Environment=='Surface' and stage=='post-pipeline scheduled revalidation' then
  debug.setupvalue(caller,call_index,original)
  sbm.GenerationGrids.RebuildFinal=original_final
  result.restored=true
  if not result.error and #result.calls>=2 then result.status='pass' end
 end
 return unpack_values(values,1,values.n)
end
sbm.Config.DEBUG_LOGGING_ENABLED=true
sbm.Config.DEBUG_LOADING_TIMINGS=true
result.status='ready'
return 'CREASE_DETAIL_PROFILE_READY'

-- Fresh-process diagnostic only. Recompile one function and join every original
-- upvalue cell; no TerrainCopy module reload or reset of private annotation state.
local result={status='setup',calls={}}
rawset(_G,'SBM_CREASE_PHASE_DIAGNOSTIC',result)
local env,sbm
for _,mod in ipairs(ModsLoaded or {})do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.Config then env,sbm=mod.env,value;break end
end
local function fail(why)result.status='fail';result.error=why;error(why)end
if not sbm then fail('crease profile mod missing');return end
local function upvalue(fn,wanted)
 for i=1,200 do
  local name,value=debug.getupvalue(fn,i)
  if not name then break end
  if name==wanted then return value,i end
 end
end
local caller=sbm.TerrainCopy.StretchSourceToFull
result.native_class_pair=upvalue(sbm.Engine.FirstKindOf,'native_kind_pair')
result.live_class_single=upvalue(sbm.Engine.FirstKindOf,'native_single_kind')
 ==sbm.Engine.Global('IsKindOf')
result.live_class_many=upvalue(sbm.Engine.FirstKindOf,'native_many_kinds')
 ==sbm.Engine.Global('IsKindOfClasses')
result.clone_current_batch=upvalue(sbm.ObjectClone.ShouldSkipObject,'FirstKindOfSafe')
 ==sbm.Engine.FirstKindOf
result.clone_current_scalar=upvalue(sbm.ObjectClone.ShouldSkipObject,'IsKindOfSafe')
 ==sbm.Engine.IsKindOf
local generate=upvalue(sbm.MapGeneration.PatchRandomMapGenerator,'GenerateOnTemporaryVanillaBacking')
local annotation=upvalue(generate,'AnnotateDecorRelief')
result.annotation_current=annotation==sbm.TerrainCopy.AnnotateDecorRelief
result.annotation_current_skip=upvalue(annotation,'ShouldSkipObject')
 ==sbm.ObjectClone.ShouldSkipObject
result.annotation_current_important=upvalue(annotation,'IsImportantSectorObject')
 ==sbm.ObjectClone.IsImportantSectorObject
local original,call_index=upvalue(caller,'RepairInternalHeightStep')
if type(original)~='function' then fail('crease profile callsite missing');return end
local original_cells,names={},{}
for i=1,200 do
 local name=debug.getupvalue(original,i)
 if not name then break end
 original_cells[name]=i
 if name~='_ENV' then names[#names+1]=name end
end
local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/Code/sbm_terrain_copy.lua')
if err or type(source)~='string' then fail('crease source missing');return end
source=source:gsub('\r\n','\n')
local first=source:find('local function RepairInternalHeightStep(',1,true)
local last=first and source:find('local function RepairQualifiedSourceHeightSteps(',first,true)
if not first or not last then fail('crease source anchors');return end
source=source:sub(first,last-1)
local function once(anchor,replacement)
 local a,b=source:find(anchor,1,true)
 if not a or source:find(anchor,b+1,true)then fail('crease ambiguous anchor: '..anchor);return false end
 source=source:sub(1,a-1)..replacement..source:sub(b+1)
 return true
end
if not once('\t\tcollect_ring("x", w, h, "left", "right")',
 '\t\tlocal phase_tick = phase_begin()\n\t\tcollect_ring("x", w, h, "left", "right")')then return end
if not once('\t\tif discovery_error then return end -- No qualification or height writes on failure.',
 '\t\tphase_end("discovery_and_tracks", phase_tick)\n\t\tif discovery_error then return end -- No qualification or height writes on failure.')then return end
if not once('\t\tlocal qualified = {}',
 '\t\tphase_tick = phase_begin()\n\t\tlocal qualified = {}')then return end
if not once('\t\tif #qualified == 0 then return end',
 '\t\tphase_end("qualification", phase_tick)\n\t\tif #qualified == 0 then return end')then return end
if not once('\t\tfor _, selected in ipairs(selected_tracks) do',
 '\t\tphase_tick = phase_begin()\n\t\tfor _, selected in ipairs(selected_tracks) do')then return end
if not once('\t\tselected_tracks[1].qualified = #qualified',
 '\t\tphase_end("selected_refinement_and_writes", phase_tick)\n\t\tselected_tracks[1].qualified = #qualified')then return end
local active
local function phase_begin()return GetPreciseTicks()end
local function phase_end(name,started)
 if not active then fail('crease phase without active call');return end
 active.phases[name]=(active.phases[name] or 0)+GetPreciseTicks()-started
end
local prefix='local phase_begin,phase_end=...\n'
if #names>0 then prefix=prefix..'local '..table.concat(names,',')..'\n'end
local chunk,why=load(prefix..source..'\nreturn RepairInternalHeightStep','@crease-phase-profile','t',env)
if not chunk then fail(tostring(why));return end
local candidate=chunk(phase_begin,phase_end)
for i=1,200 do
 local name=debug.getupvalue(candidate,i)
 if not name then break end
 if original_cells[name]then debug.upvaluejoin(candidate,i,original,original_cells[name])
 elseif name~='phase_begin' and name~='phase_end'then fail('unjoined original cell: '..name);return end
end
local unpack_values=table.unpack or unpack
local function pack(...)return {n=select('#',...),...}end
-- At most four native discovery calls per crease pass: no per-cell timing hooks.
local discovery,discovery_index=upvalue(candidate,'BuildHeightStepDiscoveryIndex')
if type(discovery)~='function' then fail('native discovery cell missing');return end
local function discovery_wrapper(...)
 local started=GetPreciseTicks()
 local values=pack(discovery(...))
 if active then
  active.native_discovery_ms=active.native_discovery_ms+GetPreciseTicks()-started
  active.native_discovery_calls=active.native_discovery_calls+1
 end
 return unpack_values(values,1,values.n)
end
debug.setupvalue(candidate,discovery_index,discovery_wrapper)
local function wrapper(grid,wide_ring_only)
 if active then fail('unexpected recursive crease pass');return original(grid,wide_ring_only)end
 local w,h=grid:size()
 active={wide_ring_only=wide_ring_only,width=w,height=h,phases={},
  native_discovery_ms=0,native_discovery_calls=0}
 local row=active
 local started=GetPreciseTicks()
 local values=pack(candidate(grid,wide_ring_only))
 row.elapsed_ms=GetPreciseTicks()-started
 row.ok=values[1];row.report=values[2];row.stats=values[4]
 result.calls[#result.calls+1]=row
 active=nil
 if row.report and row.report.error then result.status='fail'
 elseif row.native_discovery_calls~=4 or not row.phases.discovery_and_tracks
  or not row.phases.qualification then result.status='fail';result.error='missing phase instrumentation'
 elseif result.status~='fail' and #result.calls>=2 then result.status='pass'end
 return unpack_values(values,1,values.n)
end
if debug.setupvalue(caller,call_index,wrapper)~='RepairInternalHeightStep'then fail('crease wrapper installation');return end
sbm.Config.DEBUG_LOGGING_ENABLED=true
sbm.Config.DEBUG_LOADING_TIMINGS=true
result.status='ready'
return 'CREASE_PHASE_PROFILE_READY'

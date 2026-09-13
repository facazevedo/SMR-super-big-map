-- Compare complete old/candidate repair functions with original lexical layout.
-- Reverse order: candidate runs on a clone first; original on the actual grid second.
local result={status='setup',calls={}}
rawset(_G,'SBM_CREASE_SCAN_RUNS_SHADOW',result)
local env,sbm
for _,mod in ipairs(ModsLoaded or {}) do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.Config then env,sbm=mod.env,value;break end
end
local function fail(why)result.status='fail';result.error=why;error(why)end
if not sbm then fail('crease run mod missing');return end
local function upvalue(fn,wanted)
 for i=1,200 do
  local name,value=debug.getupvalue(fn,i);if not name then break end
  if name==wanted then return value,i end
 end
end
local caller=sbm.TerrainCopy.StretchSourceToFull
local original,call_index=upvalue(caller,'RepairInternalHeightStep')
if type(original)~='function' then fail('crease run callsite missing');return end
local cells,names={},{}
for i=1,200 do
 local name=debug.getupvalue(original,i);if not name then break end
 cells[name]=i;if name~='_ENV' then names[#names+1]=name end
end
local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/runs/under80-20260912/artifacts/crease_scan_runs_research/sbm_terrain_copy.lua')
if err or type(source)~='string' then fail('crease run source missing');return end
source=source:gsub('\r\n','\n')
local a=source:find('local function RepairInternalHeightStep(',1,true)
local b=a and source:find('local function RepairQualifiedSourceHeightSteps(',a,true)
if not a or not b then fail('crease run anchors');return end
source=source:sub(a,b-1)
local prefix=#names>0 and ('local '..table.concat(names,',')..'\n') or ''
local chunk,why=load(prefix..source..'\nreturn RepairInternalHeightStep','@crease-scan-runs-shadow','t',env)
if not chunk then fail(tostring(why));return end
local candidate=chunk()
for i=1,200 do
 local name=debug.getupvalue(candidate,i);if not name then break end
 if cells[name] then debug.upvaluejoin(candidate,i,original,cells[name])
 else fail('unjoined crease run cell '..name);return end
end
local function equal(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end
 return true
end
if type(GridRepack)~='function' or type(GridAddMulDiv)~='function' or type(GridMinMax)~='function' then
 fail('native full-grid comparison APIs missing');return
end
local unpack_values=table.unpack or unpack
local function pack(...)return {n=select('#',...),...}end
local active=false
local function wrapper(grid,wide_ring_only)
 if active then fail('recursive crease run');return original(grid,wide_ring_only) end
 active=true
 local owned={}
 local function own(g)if g then owned[#owned+1]=g end;return g end
 local values,row
 local ok,why=pcall(function()
  local before=own(grid:clone())
  if not before then error('crease reference clone failed');return end
  local w,h=grid:size()
  local start=GetPreciseTicks()
  local candidate_values=pack(candidate(before,wide_ring_only))
  local middle=GetPreciseTicks()
  values=pack(original(grid,wide_ring_only))
  local finish=GetPreciseTicks()
  row={wide_ring_only=wide_ring_only,width=w,height=h,cells=w*h,
   order='candidate_first',old_ms=finish-middle,new_ms=middle-start,returns_equal=equal(candidate_values,values)}
  local difference=own(GridRepack(grid,'f',32,true))
  local reference=own(GridRepack(before,'f',32,true))
  if not difference or not reference then error('crease comparison allocation failed');return end
  -- U16 integers and their signed differences are exact in f32. Checking both
  -- extrema certifies every cell; no sampled/hash-only equality claim.
  GridAddMulDiv(difference,reference,-1)
  local lo,hi=GridMinMax(difference)
  row.difference_min,row.difference_max=lo,hi
  row.grids_equal=lo==0 and hi==0
 end)
 local cleanup_ok=true
 for i=#owned,1,-1 do if not pcall(owned[i].free,owned[i]) then cleanup_ok=false end end
 active=false
 if row then row.cleanup_ok=cleanup_ok;result.calls[#result.calls+1]=row end
 if not ok or not row or not values or not cleanup_ok or not row.returns_equal or not row.grids_equal then
  fail('crease run comparison failed '..tostring(why));return
 end
 return unpack_values(values,1,values.n)
end
if debug.setupvalue(caller,call_index,wrapper)~='RepairInternalHeightStep' then fail('crease run installation');return end
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
return 'CREASE_SCAN_RUNS_SHADOW_READY'

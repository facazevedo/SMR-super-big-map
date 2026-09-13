-- Native primitive/packet oracle followed by complete source/destination repair
-- comparison. Candidate runs only on the same pending grids as the predecessor.
local result={status='setup',calls={}}
rawset(_G,'SBM_CREASE_OFFER_SHADOW',result)
local reverse=false
result.reverse=reverse
local env,sbm
for _,mod in ipairs(ModsLoaded or {})do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.Config then env,sbm=mod.env,value;break end
end
local function fail(why)result.status='fail';result.error=result.error or tostring(why);error(why)end
if not sbm then fail('crease offer mod missing');return end
local function upvalue(fn,wanted)
 for i=1,200 do local name,value=debug.getupvalue(fn,i);if not name then break end
  if name==wanted then return value,i end
 end
end
local caller=sbm.TerrainCopy.StretchSourceToFull
local original,call_index=upvalue(caller,'RepairInternalHeightStep')
if type(original)~='function'then fail('repair upvalue missing');return end
local old_build=upvalue(original,'BuildHeightStepDiscoveryIndex')
if type(old_build)~='function'then fail('discovery upvalue missing');return end
local function read(path)
 local err,s=AsyncFileToString('D:/PROJS/SMR/super-big-map/'..path)
 if err or type(s)~='string'then fail('source missing '..path);return end
 return s:gsub('\r\n','\n')
end
local source=read('_ralph/runs/under80-20260912/artifacts/crease_offer_research_2/sbm_terrain_copy.lua')
if not source then return end
local function compile(name,last,old,replacements)
 local a=source:find('local function '..name..'(',1,true)
 local b=a and source:find(last,a,true)
 if not a or not b then fail('source anchors '..name);return end
 local cells,names={},{}
 for i=1,200 do local key=debug.getupvalue(old,i);if not key then break end
  cells[key]=i;if key~='_ENV'then names[#names+1]=key end
 end
 local prefix=#names>0 and ('local '..table.concat(names,',')..'\n')or ''
 local chunk,why=load(prefix..source:sub(a,b-1)..'\nreturn '..name,'@crease-offer-'..name,'t',env)
 if not chunk then fail(why);return end
 local fn=chunk()
 for i=1,200 do local key=debug.getupvalue(fn,i);if not key then break end
  if replacements and replacements[key]then debug.setupvalue(fn,i,replacements[key])
  elseif cells[key]then debug.upvaluejoin(fn,i,old,cells[key])
  else fail('unjoined '..name..' cell '..key);return end
 end
 return fn
end
local build=compile('BuildHeightStepDiscoveryIndex','-- Batched translation of independent rows',old_build)
if not build then return end
local candidate=compile('RepairInternalHeightStep','local function RepairQualifiedSourceHeightSteps(',original,
 {BuildHeightStepDiscoveryIndex=build})
if not candidate then return end
local api={}
for _,name in ipairs({'IsComputeGrid','GridRepack','GridMulDivAdd','GridAdd','GridAbs',
 'GridMask','GridCount','GridForeach','NewComputeGrid','box','point'})do
 api[name]=_G[name]
 if type(api[name])~='function'then fail('native API missing '..name);return end
end
local oracle_source=read('_ralph/tmp/under80_20260912/crease_offer_oracle.lua')
if not oracle_source then return end
local oracle_chunk,why=load(oracle_source,'@crease-offer-oracle','t',env)
if not oracle_chunk then fail(why);return end
local checks,issues,primitive=oracle_chunk()(build,api)
result.native_oracle={checks=checks,issues=issues,primitive=primitive}
if type(issues)~='table' or #issues>0 then fail('native packet/copy oracle failed');return end
local function equal(a,b)
 if type(a)~=type(b)then return false end
 if type(a)~='table'then return a==b end
 for k,v in pairs(a)do if not equal(v,b[k])then return false end end
 for k in pairs(b)do if a[k]==nil then return false end end
 return true
end
local function pack(...)return {n=select('#',...),...}end
local unpack_values=table.unpack or unpack
local active=false
local function wrapper(grid,wide)
 if active then fail('recursive crease offer shadow');return original(grid,wide)end
 active=true
 local owned={}
 local function own(g)if g then owned[#owned+1]=g end;return g end
 local values,row
 local ok,why=pcall(function()
  local before=own(grid:clone())
  if not before then fail('reference clone failed');return end
  local w,h=grid:size()
  local old_values,start,old_ms,new_ms
  if reverse then
   start=GetPreciseTicks();values=pack(candidate(grid,wide));new_ms=GetPreciseTicks()-start
   start=GetPreciseTicks();old_values=pack(original(before,wide));old_ms=GetPreciseTicks()-start
  else
   start=GetPreciseTicks();old_values=pack(original(before,wide));old_ms=GetPreciseTicks()-start
   start=GetPreciseTicks();values=pack(candidate(grid,wide));new_ms=GetPreciseTicks()-start
  end
  row={wide_ring_only=wide,width=w,height=h,cells=w*h,old_ms=old_ms,new_ms=new_ms,
   returns_equal=equal(old_values,values)}
  local difference=own(GridRepack(grid,'f',32,true))
  local reference=own(GridRepack(before,'f',32,true))
  if not difference or not reference then fail('comparison allocation failed');return end
  GridAddMulDiv(difference,reference,-1)
  local lo,hi=GridMinMax(difference)
  row.difference_min,row.difference_max=lo,hi
  row.grids_equal=lo==0 and hi==0
 end)
 local cleanup_ok=true
 for i=#owned,1,-1 do if not pcall(owned[i].free,owned[i])then cleanup_ok=false end end
 active=false
 if row then row.cleanup_ok=cleanup_ok;result.calls[#result.calls+1]=row end
 if not ok or result.error or not row or not values or not cleanup_ok or not row.returns_equal or not row.grids_equal then
  fail('crease offer full-grid comparison failed '..tostring(why));return
 end
 return unpack_values(values,1,values.n)
end
if debug.setupvalue(caller,call_index,wrapper)~='RepairInternalHeightStep'then fail('repair wrapper installation');return end
local original_final=sbm.GenerationGrids.RebuildFinal
sbm.GenerationGrids.RebuildFinal=function(map,stage,...)
 local values=pack(original_final(map,stage,...))
 if map.mapdata.Environment=='Surface' and stage=='post-pipeline scheduled revalidation'then
  debug.setupvalue(caller,call_index,original)
  sbm.GenerationGrids.RebuildFinal=original_final
  result.restored=true
  if not result.error and #result.calls>=2 then result.status='pass' end
 end
 return unpack_values(values,1,values.n)
end
result.status='ready'
return 'CREASE_OFFER_SHADOW_READY'

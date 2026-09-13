-- Nondeployed full-raster shadow. The accepted raster ALWAYS supplies game output.
local result={status='setup',calls={}}
rawset(_G,'SBM_APRON_LOCAL_SHADOW',result)
local reverse=true
result.reverse=reverse
local function fail(why)result.status='fail';result.error=result.error or tostring(why)end
local env,sbm
for _,mod in ipairs(ModsLoaded or {})do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.Config then env,sbm=mod.env,value;break end
end
if not sbm then fail('apron mod missing');return end
local function upvalue(fn,wanted)
 for i=1,200 do local name,value=debug.getupvalue(fn,i);if not name then break end
  if name==wanted then return value,i end
 end
end
local create=upvalue(sbm.TerrainCopy.StretchSourceToFull,'CreateNaturalMountainBaseBuildableAprons')
if type(create)~='function'then fail('apron caller missing');return end
local original,index=upvalue(create,'RasterNaturalMountainBaseAprons')
if type(original)~='function'then fail('apron raster missing');return end
local function read(path)
 local err,text=AsyncFileToString('D:/PROJS/SMR/super-big-map/'..path)
 if err or type(text)~='string'then fail('missing source '..path);return end
 return text:gsub('\r\n','\n')
end
local function compile(text,name)
 local fn,why=load(text,name,'t',env)
 if not fn then fail(why);return end
 return fn()
end
local source=read('_ralph/runs/under80-20260912/artifacts/apron_local_research/terrain_candidate.lua')
if not source then return end
local a=source:find('local function RasterNaturalMountainBaseAprons(',1,true)
local b=a and source:find('local function CreateNaturalMountainBaseBuildableAprons(',a,true)
if not a or not b then fail('raster anchors missing');return end
local candidate=compile(source:sub(a,b-1)..'\nreturn RasterNaturalMountainBaseAprons','@apron-local-raster')
if not candidate then return end
local p=source:find('local core=math.floor(policy.core_fraction*W+0.5)',a,true)
local q=p and source:find('return polynomial,nil,cube',p,true)
if not p or not q then fail('polynomial anchors missing');return end
local polynomial=compile('return function(api,own,radius,policy) local W=16777216;local w,h=radius:size()\n'
 ..source:sub(p,q+#'return polynomial,nil,cube'-1)..'\nend','@actual-apron-polynomial')
if not polynomial then return end
local oracle_source=read('_ralph/tmp/under80_20260912/apron_local_oracle.lua')
if not oracle_source then return end
local oracle=compile(oracle_source,'@apron-polynomial-oracle')
if not oracle then return end
local poly_api={}
for _,name in ipairs({'NewComputeGrid','GridMulDivAdd','GridClamp','GridRound','box','point'})do
 poly_api[name]=sbm.Engine.Global(name)
 if type(poly_api[name])~='function'then fail('missing API '..name);return end
end
PauseInfiniteLoopDetection('SBMApronLocalPolynomial')
local ok,primitive=pcall(oracle,polynomial,poly_api)
ResumeInfiniteLoopDetection('SBMApronLocalPolynomial')
result.primitive=primitive
if not ok or type(primitive)~='table' or primitive.status~='pass'then
 fail('native polynomial/core oracle failed');return
end
local active=false
local wrapper=function(api,grid,selected,policy)
 if active then fail('recursive apron shadow');return original(api,grid,selected,policy)end
 active=true
 local copy=grid:clone()
 if not copy then active=false;fail('scratch clone failed');return original(api,grid,selected,policy)end
 local row={core_fraction=policy.core_fraction}
 local function run_old()
  local started=GetPreciseTicks()
  row.old_ok,row.old_stats,row.old_error=original(api,grid,selected,policy)
  row.old_ms=GetPreciseTicks()-started
 end
 local function run_new()
  local started=GetPreciseTicks()
  local ok,a,b,c=pcall(candidate,api,copy,selected,policy)
  row.new_ms=GetPreciseTicks()-started
  if ok then row.new_ok,row.new_stats,row.new_error=a,b,c
  else row.new_ok=false;row.new_error=tostring(a)end
 end
 if reverse then run_new();run_old()else run_old();run_new()end
 local owned={copy}
 local function own(g)if g then owned[#owned+1]=g end;return g end
 local checked,why=pcall(function()
  local delta=own(api.GridRepack(copy,'f',32,true))
  local accepted=own(api.GridRepack(grid,'f',32,true))
  if not delta or not accepted then fail('comparison allocation');return end
  api.GridAddMulDiv(delta,accepted,-1);api.GridAbs(delta)
  row.minimum,row.maximum=api.GridMinMax(delta)
  api.GridMulDivAdd(delta,2,1,0)
  row.different=api.GridCount(delta,1,2147483647)
  local w,h=grid:size();row.cells=w*h
  if not row.old_ok or not row.new_ok or row.old_error or row.new_error
   or row.minimum~=0 or row.maximum~=0 or row.different~=0
   or row.old_stats.modified~=row.new_stats.modified or row.old_stats.shaped~=row.new_stats.shaped
   or row.new_stats.exact_samples>=row.old_stats.exact_samples then fail('full apron comparison failed')end
 end)
 if not checked then fail(why)end
 row.cleanup=true
 for i=#owned,1,-1 do local freed,err=pcall(owned[i].free,owned[i])
  if not freed then row.cleanup=false;fail(err)end
 end
 result.calls[#result.calls+1]=row
 active=false
 return row.old_ok,row.old_stats,row.old_error
end
if debug.setupvalue(create,index,wrapper)~='RasterNaturalMountainBaseAprons'then
 fail('wrapper install failed');return
end
local original_final=sbm.GenerationGrids.RebuildFinal
local function pack(...)return {n=select('#',...),...}end
local unpack_values=table.unpack or unpack
sbm.GenerationGrids.RebuildFinal=function(map,stage,...)
 local values=pack(original_final(map,stage,...))
 if map.mapdata.Environment=='Surface' and stage=='post-pipeline scheduled revalidation'then
  result.restored=debug.setupvalue(create,index,original)=='RasterNaturalMountainBaseAprons'
  sbm.GenerationGrids.RebuildFinal=original_final
  if not result.restored then fail('wrapper restoration failed')end
  if not result.error and result.restored and #result.calls==1 then result.status='pass'
  elseif not result.error then fail('unexpected apron call census')end
 end
 return unpack_values(values,1,values.n)
end
result.status='ready'
return 'APRON_LOCAL_SHADOW_READY'

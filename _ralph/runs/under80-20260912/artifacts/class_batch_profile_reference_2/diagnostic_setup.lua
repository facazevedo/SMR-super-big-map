-- Fresh-process diagnostic only. Preserve existing Engine and ObjectClone table
-- identities and annotation state; replace only the five classification closures.
local result={status='setup',calls={},batch_calls=0,negative_batches=0,scalar_calls=0,replaced_cells=0}
rawset(_G,'SBM_CLASS_BATCH_DIAGNOSTIC',result)
local env,sbm
for _,mod in ipairs(ModsLoaded or {}) do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.Config then env,sbm=mod.env,value;break end
end
local function fail(reason)result.status='fail';result.error=reason;error(reason)end
if not sbm then fail('class batch: mod missing');return end
local function read(name)
 local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/runs/under80-20260912/artifacts/class_batch_research_3/'..name..'_candidate.lua')
 if err or not source then fail('class batch source missing');return end
 return source:gsub('\r\n','\n')
end
local function upvalue(fn,wanted)
 if type(fn)~='function' then return end
 for i=1,200 do local name,value=debug.getupvalue(fn,i)
  if not name then break end
  if name==wanted then return value,i end
 end
end
local source=read('engine');if not source then return end
local first=source:find('-- Native list negatives',1,true)
local last=first and source:find('-- Best-effort world position',first,true)
if not first or not last or sbm.Engine.FirstKindOf then fail('class batch helper anchors/state');return end
local helper=source:sub(first,last-1)
helper=helper:gsub('local ok, value = pcall%(native_many_kinds, obj, classes%)',
 'diagnostic.batch_calls=diagnostic.batch_calls+1\n\t\tlocal ok, value = pcall(native_many_kinds, obj, classes)')
helper=helper:gsub('if ok and value == false then return nil, false end',
 'if ok and value == false then diagnostic.negative_batches=diagnostic.negative_batches+1;return nil, false end')
helper=helper:gsub('last_value = single_kind%(obj, classes%[i%]%)',
 'diagnostic.scalar_calls=diagnostic.scalar_calls+1\n\t\tlast_value = single_kind(obj, classes[i])')
local fn,why=load('local Engine,type,pcall,diagnostic=...\n'..helper,'@class-batch-helper','t',env)
if not fn then fail(tostring(why));return end
fn(sbm.Engine,type,pcall,result)
result.native_pair=upvalue(sbm.Engine.FirstKindOf,'native_kind_pair')
if result.native_pair~=true then fail('native class pair did not qualify');return end
local original_clone=sbm.ObjectClone
source=read('object_clone');if not source then return end
fn,why=load(source,'@class-batch-object-clone','t',env)
if not fn then fail(tostring(why));return end
fn()
local candidate_clone=sbm.ObjectClone
local replacements={}
for _,name in ipairs({'IsMysteryRelatedObject','IsUndergroundAccessObject',
 'IsResourceDepositMarker','ShouldSkipObject','IsImportantSectorObject'}) do
 local previous,candidate=original_clone[name],candidate_clone[name]
 if type(previous)~='function' or type(candidate)~='function' then fail('classifier missing: '..name);return end
 replacements[previous]=candidate
 original_clone[name]=candidate
end
sbm.ObjectClone=original_clone -- RockGrounding and other captured table references stay valid.
local seen={}
local function rewrite(fn)
 if seen[fn] then return end;seen[fn]=true
 for i=1,200 do
  local name,value=debug.getupvalue(fn,i)
  if not name then break end
  if replacements[value] then
   if debug.setupvalue(fn,i,replacements[value])~=name then fail('classifier upvalue replacement failed');return end
   result.replaced_cells=result.replaced_cells+1
  elseif type(value)=='function' then rewrite(value) end
 end
end
for _,module in pairs(sbm) do
 if type(module)=='function' then rewrite(module)
 elseif type(module)=='table' then
  for _,value in pairs(module)do if type(value)=='function' then rewrite(value)end end
 end
end
local original=sbm.TerrainCopy.AnnotateDecorRelief
if upvalue(original,'ShouldSkipObject')~=original_clone.ShouldSkipObject
 or upvalue(original,'IsImportantSectorObject')~=original_clone.IsImportantSectorObject
 or result.replaced_cells<1 then fail('annotation classifiers not replaced');return end
local generate=upvalue(sbm.MapGeneration.PatchRandomMapGenerator,'GenerateOnTemporaryVanillaBacking')
local captured,index=upvalue(generate,'AnnotateDecorRelief')
if captured~=original or not index then fail('annotation callsite changed');return end
local function pack(...)return {n=select('#',...),...}end
local unpack_values=table.unpack or unpack
local wrapper=function(map,...)
 local started=GetPreciseTicks()
 local values=pack(original(map,...))
 local failures=map.SuperBigMapRockGroundingStats and map.SuperBigMapRockGroundingStats.failures or 0
 result.calls[#result.calls+1]={elapsed_ms=GetPreciseTicks()-started,
  environment=map.mapdata.Environment,batch_calls=result.batch_calls,
  negative_batches=result.negative_batches,scalar_calls=result.scalar_calls,failures=failures}
 if failures>0 then result.status='fail'
 elseif result.status~='fail' and result.negative_batches>0 then result.status='pass' end
 return unpack_values(values,1,values.n)
end
if debug.setupvalue(generate,index,wrapper)~='AnnotateDecorRelief' then fail('annotation wrapper install failed');return end
sbm.TerrainCopy.AnnotateDecorRelief=wrapper
sbm.Config.DEBUG_LOGGING_ENABLED=true
sbm.Config.DEBUG_LOADING_TIMINGS=true
result.status='ready'
return 'CLASS_BATCH_READY'

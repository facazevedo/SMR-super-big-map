-- Diagnostic-only clone of one function; join all original private upvalue cells.
local result={status='setup',calls={},issues={}}
rawset(_G,'SBM_BOOTSTRAP_PHASE_DIAGNOSTIC',result)
local function fail(why)
 result.status='fail';result.issues[#result.issues+1]=tostring(why)
 result.error=result.error or tostring(why)
end
local env,sbm
for _,mod in ipairs(ModsLoaded or {})do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.Config then env,sbm=mod.env,value;break end
end
if not sbm or not sbm.MapGeneration or not sbm.GenerationGrids
 or type(debug.upvaluejoin)~='function'then fail('bootstrap profile prerequisites');return end
local function upvalue(fn,wanted)
 if type(fn)~='function'then return end
 for i=1,200 do local name,value=debug.getupvalue(fn,i);if not name then break end
  if name==wanted then return value,i end
 end
end
local caller=sbm.MapGeneration.PatchRandomMapGenerator
local original,index=upvalue(caller,'BootstrapPassagesAndDeferWonders')
local original_final=sbm.GenerationGrids.RebuildFinal
if type(original)~='function' or type(original_final)~='function'then fail('bootstrap callsite or restore boundary missing');return end
local function read(path)
 local err,text=AsyncFileToString('D:/PROJS/SMR/super-big-map/'..path)
 if err or type(text)~='string'then fail('missing bootstrap source '..path);return end
 return text:gsub('\r\n','\n')
end
local source=read('Code/sbm_map_generation.lua')
local instrument_source=read('_ralph/tmp/under80_20260912/bootstrap_phase_instrument.lua')
if not source or not instrument_source then return end
local first=source:find('local function BootstrapPassagesAndDeferWonders(',1,true)
local last=first and source:find('local function DeferredWonderScaleRatios(',first,true)
if not first or not last then fail('bootstrap source boundaries');return end
source=source:sub(first,last-1)
local factory,why=load(instrument_source,'@bootstrap-phase-instrument','t',env)
if not factory then fail(why);return end
local instrument=factory()
local modified,edits=instrument(source)
if not modified then fail(edits);return end
-- Independently remove every insertion before compiling; original source must match.
local reversed=modified
for i=#edits,1,-1 do
 local edit=edits[i];local text=edit.inserted..edit.anchor
 local a,b=reversed:find(text,1,true)
 if not a or reversed:find(text,b+1,true)then fail('bootstrap reversal anchor');return end
 reversed=reversed:sub(1,a-1)..edit.anchor..reversed:sub(b+1)
end
if reversed~=source or #edits~=12 then fail('non-observational source delta');return end
result.source_reconstruction=true;result.expected_phases={}
for _,edit in ipairs(edits)do result.expected_phases[#result.expected_phases+1]=edit.phase end
local active
local function phase(name)
 if not active then fail('bootstrap phase outside call');return end
 local now=GetPreciseTicks()
 if active.phase then
  active.phases[#active.phases+1]={name=active.phase,duration_ms=now-active.phase_at}
 end
 active.phase=name;active.phase_at=now
end
local cells,names={},{}
for i=1,200 do local name=debug.getupvalue(original,i);if not name then break end
 cells[name]=i;if name~='_ENV'then names[#names+1]=name end
end
local prefix='local bootstrap_phase=...\n'
if #names>0 then prefix=prefix..'local '..table.concat(names,',')..'\n'end
local chunk,compile_error=load(prefix..modified..'\nreturn BootstrapPassagesAndDeferWonders','@bootstrap-phase-profile','t',env)
if not chunk then fail(compile_error);return end
local candidate=chunk(phase)
local joined,seen=0,{}
for i=1,200 do local name=debug.getupvalue(candidate,i);if not name then break end
 if cells[name]then debug.upvaluejoin(candidate,i,original,cells[name]);joined=joined+1;seen[name]=true
 elseif name~='bootstrap_phase'then fail('unjoined bootstrap upvalue: '..name);return end
end
for name in pairs(cells)do if not seen[name]then fail('lost original bootstrap upvalue: '..name);return end end
result.joined_upvalues=joined
local function pack(...)return {n=select('#',...),...}end
local unpack_values=table.unpack or unpack
local wrapper,final_wrapper
local logging,timing=sbm.Config.DEBUG_LOGGING_ENABLED,sbm.Config.DEBUG_LOADING_TIMINGS
local restored=false
local function restore(reason)
 if restored then return end
 if upvalue(caller,'BootstrapPassagesAndDeferWonders')==wrapper then
  if debug.setupvalue(caller,index,original)~='BootstrapPassagesAndDeferWonders'then fail('bootstrap restore failed')end
 elseif upvalue(caller,'BootstrapPassagesAndDeferWonders')~=original then fail('bootstrap hook rebound')end
 if sbm.GenerationGrids.RebuildFinal==final_wrapper then sbm.GenerationGrids.RebuildFinal=original_final
 elseif sbm.GenerationGrids.RebuildFinal~=original_final then fail('bootstrap final hook rebound')end
 result.config_unchanged=sbm.Config.DEBUG_LOGGING_ENABLED==logging and sbm.Config.DEBUG_LOADING_TIMINGS==timing
 if not result.config_unchanged then fail('bootstrap debug config changed')end
 restored=true;result.restored=#result.issues==0;result.restore_reason=reason
 if not result.error and #result.calls==1 and result.calls[1].ok then result.status='pass'
 elseif not result.error then fail('bootstrap call census')end
 print('[SBM bootstrap phases] '..result.status..' calls='..#result.calls..' restored='..tostring(result.restored))
end
wrapper=function(native_env)
 if active then fail('recursive bootstrap profile');return original(native_env)end
 local row={phases={},environment=native_env and native_env.map and native_env.map.mapdata.Environment}
 active=row
 local started=GetPreciseTicks()
 local values=pack(pcall(candidate,native_env))
 local finished=GetPreciseTicks()
 row.elapsed_ms=finished-started
 if row.phase then row.phases[#row.phases+1]={name=row.phase,duration_ms=finished-row.phase_at}end
 row.phase=nil;row.phase_at=nil
 row.ok=values[1] and values[2]==true;row.details=type(values[3])=='table' and values[3] or nil
 row.phase_sum_ms=0
 for i,item in ipairs(row.phases)do
  row.phase_sum_ms=row.phase_sum_ms+item.duration_ms
  if item.name~=result.expected_phases[i] or item.duration_ms<0 then fail('bootstrap phase order/duration')end
 end
 if not row.ok or #row.phases~=12 or row.phase_sum_ms>row.elapsed_ms then fail('bootstrap phase completion')end
 result.calls[#result.calls+1]=row;active=nil
 if not values[1] then fail(values[2]);restore('bootstrap exception');error(values[2]);return false,tostring(values[2])end
 if not row.ok then restore('bootstrap returned failure')end
 return unpack_values(values,2,values.n)
end
final_wrapper=function(map,stage,...)
 local values=pack(pcall(original_final,map,stage,...))
 if not values[1]then fail(values[2]);restore('final exception');error(values[2]);return nil end
 if map and map.mapdata and map.mapdata.Environment=='Surface' and stage=='post-pipeline scheduled revalidation'then
  restore(stage)
 end
 return unpack_values(values,2,values.n)
end
if debug.setupvalue(caller,index,wrapper)~='BootstrapPassagesAndDeferWonders'then
 fail('bootstrap wrapper install');restore('install failure');return
end
sbm.GenerationGrids.RebuildFinal=final_wrapper
result.status='ready'
return 'BOOTSTRAP_PHASE_PROFILE_READY'

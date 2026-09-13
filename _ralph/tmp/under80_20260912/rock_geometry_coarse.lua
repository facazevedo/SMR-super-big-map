-- Two clocks around whole annotation, including helper initialization and cleanup.
return function(use_candidate)
 local result={kind='rock_geometry_coarse',variant=use_candidate and 'candidate' or 'accepted',
  status='setup',calls={},issues={},joined_cells=0,initializations=0}
 rawset(_G,'SBM_ROCK_GEOMETRY_COARSE',result)
 local function fail(why)
  result.error=result.error or tostring(why);result.status='fail'
  if #result.issues<32 then result.issues[#result.issues+1]=tostring(why)end
 end
 local sbm,env
 for _,mod in ipairs(ModsLoaded or {})do
  local s=mod.env and rawget(mod.env,'SuperBigMap')
  if s and s.RockGrounding then sbm,env=s,mod.env;break end
 end
 if not sbm or not sbm.MapGeneration or not sbm.TerrainCopy or not sbm.GenerationGrids then fail('modules missing');return end
 local function upvalue(fn,wanted)
  if type(fn)~='function'then return end
  for i=1,200 do local name,value=debug.getupvalue(fn,i);if not name then break end
   if name==wanted then return value,i end
  end
 end
 local caller=sbm.MapGeneration.RunSurfaceStretchIfEnabled
 local original_annotation,index=upvalue(caller,'AnnotateDecorRelief')
 local original_capture,original_final=sbm.RockGrounding.Capture,sbm.GenerationGrids.RebuildFinal
 if type(original_annotation)~='function' or original_annotation~=sbm.TerrainCopy.AnnotateDecorRelief
  or type(original_capture)~='function' or type(original_final)~='function'then fail('actual seams missing');return end
 local measured=original_capture
 local geometry,factory={},nil
 local function read(path)
  local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/'..path)
  if err or type(source)~='string'then fail('source missing '..path);return end
  return source:gsub('\r\n','\n')
 end
 if use_candidate then
  local source=read('_ralph/runs/under80-20260912/artifacts/rock_geometry_candidate_2/candidate.lua')
  local helper=read('_ralph/tmp/under80_20260912/rock_geometry_native.lua')
  if result.error then return end
  local chunk,why=load(helper,'@rock-geometry-native','t',env)
  if not chunk then fail(why);return end
  factory=chunk() -- Compile only; initialization is inside the measured annotation.
  local cells,names={},{}
  for i=1,100 do
   local name=debug.getupvalue(original_capture,i);if not name then break end
   cells[name]=i;if name~='_ENV'then names[#names+1]=name end
  end
  chunk,why=load('local NativeGeometry\nlocal '..table.concat(names,',')..'\n'..source..'\nreturn Capture',
   '@rock-geometry-coarse-Capture','t',env)
  if not chunk then fail(why);return end
  measured=chunk()
  for i=1,100 do
   local name=debug.getupvalue(measured,i);if not name then break end
   if name=='NativeGeometry'then debug.setupvalue(measured,i,geometry)
   elseif cells[name]then debug.upvaluejoin(measured,i,original_capture,cells[name]);result.joined_cells=result.joined_cells+1
   else fail('unjoined candidate cell '..name);return end
  end
 end
 local pack=function(...)return{n=select('#',...),...}end
 local unpack_values=table.unpack or unpack
 local config={sbm.Config.DEBUG_LOGGING_ENABLED,sbm.Config.DEBUG_LOADING_TIMINGS}
 local annotation_wrapper,final_wrapper,active,restored
 local function restore()
  if restored then return end;restored=true
  if active then fail('restore during annotation')end
  if upvalue(caller,'AnnotateDecorRelief')==annotation_wrapper then debug.setupvalue(caller,index,original_annotation)
  else fail('annotation rebound')end
  if sbm.GenerationGrids.RebuildFinal==final_wrapper then sbm.GenerationGrids.RebuildFinal=original_final
  else fail('final rebound')end
  if sbm.RockGrounding.Capture~=original_capture then fail('capture not restored')end
  result.config_unchanged=config[1]==sbm.Config.DEBUG_LOGGING_ENABLED and config[2]==sbm.Config.DEBUG_LOADING_TIMINGS
  if not result.config_unchanged then fail('config changed')end
  result.restored=upvalue(caller,'AnnotateDecorRelief')==original_annotation
   and sbm.GenerationGrids.RebuildFinal==original_final and sbm.RockGrounding.Capture==original_capture
  result.status=result.error and 'fail' or 'pass'
  print('[SBM rock geometry coarse] '..result.variant..' '..result.status)
 end
 annotation_wrapper=function(map,...)
  if active then fail('recursive annotation');return original_annotation(map,...)end
  if #result.calls>=4 then fail('annotation cap');restore();return original_annotation(map,...)end
  active=true
  local started=GetPreciseTicks()
  local returned=pack(pcall(function(...)
   if use_candidate then
    if result.initializations==0 then
     local initialized=factory(sbm.Engine)
     if not initialized.enabled then fail('native qualification failed');return false end
     for k,v in pairs(initialized)do geometry[k]=v end
     result.initializations=1
    end
    if sbm.RockGrounding.Capture~=original_capture then fail('capture rebound before annotation');return false end
    sbm.RockGrounding.Capture=measured
   end
   return original_annotation(map,...)
  end,...))
  if use_candidate and sbm.RockGrounding.Capture==measured then sbm.RockGrounding.Capture=original_capture
  elseif sbm.RockGrounding.Capture~=original_capture then fail('capture rebound during annotation')end
  local elapsed=GetPreciseTicks()-started
  active=false
  local stats=map and map.SuperBigMapRockGroundingStats
  result.calls[#result.calls+1]={environment=map and map.mapdata and map.mapdata.Environment or '?',
   duration_ms=elapsed,ok=returned[1] and returned[2]~=false,annotated=returned[2],
   capture_ms=stats and stats.capture_ms,failures=stats and stats.failures}
  if not returned[1] or returned[2]==false or result.error then fail('annotation failed');restore()end
  if not returned[1]then error(returned[2]);return nil end
  return unpack_values(returned,2,returned.n)
 end
 final_wrapper=function(map,stage,...)
  local returned=pack(pcall(original_final,map,stage,...))
  if not returned[1] or returned[2]==false then fail('final failed');restore()end
  if map and map.mapdata and map.mapdata.Environment=='Surface' and stage=='post-pipeline scheduled revalidation'then restore()end
  if not returned[1]then error(returned[2]);return nil end
  return unpack_values(returned,2,returned.n)
 end
 debug.setupvalue(caller,index,annotation_wrapper);sbm.GenerationGrids.RebuildFinal=final_wrapper
 result.status='ready';return 'ROCK_GEOMETRY_COARSE_READY'
end

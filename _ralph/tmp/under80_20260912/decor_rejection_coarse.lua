-- Coarse whole-Run timing only: no per-candidate wrappers, replay or counters.
return function(use_candidate)
 local result={kind='decor_rejection_coarse',variant=use_candidate and 'candidate' or 'accepted',
  status='setup',calls={},issues={},joined_cells=0}
 rawset(_G,'SBM_DECOR_REJECTION_COARSE',result)
 local function fail(why)result.error=result.error or tostring(why);result.issues[#result.issues+1]=tostring(why);result.status='fail' end
 local sbm,env
 for _,mod in ipairs(ModsLoaded or {})do
  local value=mod.env and rawget(mod.env,'SuperBigMap')
  if value and value.DecorTopUp then sbm,env=value,mod.env;break end
 end
 if not sbm or not sbm.GenerationGrids then fail('decor module unavailable');return end
 local original,final=sbm.DecorTopUp.Run,sbm.GenerationGrids.RebuildFinal
 if type(original)~='function' or type(final)~='function'then fail('coarse seams missing');return end
 local measured=original
 if use_candidate then
  local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/runs/under80-20260912/artifacts/decor_rejection_fusion_2/candidate.lua')
  if err or type(source)~='string'then fail('candidate source missing');return end
  source=source:gsub('\r\n','\n')
  local cells,names={},{}
  for i=1,200 do
   local name=debug.getupvalue(original,i)
   if not name then break end
   cells[name]=i;if name~='_ENV'then names[#names+1]=name end
  end
  local start=source:find('function DecorTopUp.Run(',1,true)
  if not start then fail('candidate Run anchor');return end
  local body='local '..table.concat(names,',')..'\n'..
   source:sub(start):gsub('^function DecorTopUp.Run%(','local function CandidateRun(')..'\nreturn CandidateRun'
  local chunk,why=load(body,'@decor-rejection-coarse-Run','t',env)
  if not chunk then fail(why);return end
  measured=chunk()
  for i=1,200 do
   local name=debug.getupvalue(measured,i)
   if not name then break end
   if not cells[name]then fail('unjoined candidate cell '..name);return end
   debug.upvaluejoin(measured,i,original,cells[name]);result.joined_cells=result.joined_cells+1
  end
 end
 local config={sbm.Config.DEBUG_LOGGING_ENABLED,sbm.Config.DEBUG_LOADING_TIMINGS}
 local run_wrapper,final_wrapper,active
 local pack=function(...)return{n=select('#',...),...}end
 local unpack_values=table.unpack or unpack
 local function restore()
  if active then fail('coarse restore during Run')end
  if sbm.DecorTopUp.Run==run_wrapper then sbm.DecorTopUp.Run=original else fail('coarse Run rebound')end
  if sbm.GenerationGrids.RebuildFinal==final_wrapper then sbm.GenerationGrids.RebuildFinal=final else fail('coarse final rebound')end
  result.config_unchanged=config[1]==sbm.Config.DEBUG_LOGGING_ENABLED and config[2]==sbm.Config.DEBUG_LOADING_TIMINGS
  if not result.config_unchanged then fail('coarse config changed')end
  result.restored=sbm.DecorTopUp.Run==original and sbm.GenerationGrids.RebuildFinal==final
  result.status=result.error and 'fail' or 'pass'
  print('[SBM decor coarse] '..result.variant..' '..result.status)
 end
 run_wrapper=function(map,...)
  if active then fail('recursive decor Run');return original(map,...)end
  active=true
  local started=GetPreciseTicks()
  local values=pack(pcall(measured,map,...))
  local elapsed=GetPreciseTicks()-started
  active=false
  local row={environment=map and map.mapdata and map.mapdata.Environment or '?',
   duration_ms=elapsed,ok=values[1] and values[2],stats=values[3]}
  result.calls[#result.calls+1]=row
  if not values[1] or not values[2] or (type(values[3])=='table' and values[3].error)then
   fail('measured decor failed');restore()
  end
  if not values[1]then error(values[2]);return nil end
  return unpack_values(values,2,values.n)
 end
 final_wrapper=function(map,stage,...)
  local values=pack(pcall(final,map,stage,...))
  if not values[1]then fail('final failed');restore();error(values[2]);return nil end
  if map and map.mapdata and map.mapdata.Environment=='Surface' and stage=='post-pipeline scheduled revalidation'then restore()end
  return unpack_values(values,2,values.n)
 end
 sbm.DecorTopUp.Run=run_wrapper;sbm.GenerationGrids.RebuildFinal=final_wrapper
 result.status='ready';return 'DECOR_REJECTION_COARSE_READY'
end

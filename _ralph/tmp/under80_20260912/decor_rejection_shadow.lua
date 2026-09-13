-- Diagnostic-only clone of Run with exact joined original private cells. No
-- production/engine reload, published method/global mutation or second RNG run.
local root='D:/PROJS/SMR/super-big-map/'
local result={status='setup',calls={},issues={}}
rawset(_G,'SBM_DECOR_REJECTION_DIAGNOSTIC',result)
local function fail(why)
 result.status='fail';result.error=result.error or tostring(why)
 result.issues[#result.issues+1]=tostring(why);return false
end
local function read(path)
 local err,s=AsyncFileToString(root..path)
 if err or type(s)~='string'then fail('source missing '..path);return nil end
 return s:gsub('\r\n','\n')
end
local env,sbm
for _,mod in ipairs(ModsLoaded or {})do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.DecorTopUp then env,sbm=mod.env,value;break end
end
if not sbm or not sbm.GenerationGrids then fail('decor mod unavailable');return end
local original,original_final=sbm.DecorTopUp.Run,sbm.GenerationGrids.RebuildFinal
if type(original)~='function' or type(original_final)~='function'then fail('decor seams unavailable');return end
local source=read('_ralph/runs/under80-20260912/artifacts/decor_rejection_fusion_2/candidate.lua')
local factory=read('_ralph/tmp/under80_20260912/decor_rejection_probe.lua')
local oracle=read('_ralph/runs/under80-20260912/artifacts/decor_rejection_fusion_2/oracle_factory.lua')
if not source or not factory or not oracle then return end
local ff,fe=load(factory,'@decor-rejection-probe','t',_G)
local of,oe=load(oracle,'@accepted-rejection-prefix','t',env)
if not ff or not of then fail(fe or oe);return end
local probe=ff()(of())
result=probe.result;rawset(_G,'SBM_DECOR_REJECTION_DIAGNOSTIC',result)
local cells,names,values={},{},{}
for i=1,200 do
 local name,value=debug.getupvalue(original,i)
 if not name then break end
 cells[name],values[name]=i,value
 if name~='_ENV' then names[#names+1]=name end
end
local function once(old,new)
 local a,b=source:find(old,1,true)
 if not a or source:find(old,b+1,true)then return fail('source anchor missing/duplicate '..old:sub(1,80))end
 source=source:sub(1,a-1)..new..source:sub(b+1);return true
end
if not once('local point_fn = Global("point")','local point_fn = __probe.wrap("point", Global("point"))')
 or not once('local get_type = terrain_api.GetTerrainType','local get_type = __probe.wrap("terrain", terrain_api.GetTerrainType)')then return end
local begin='\t\t\t\t\tlocal outcome\n\t\t\t\t\t-- Private finite-loop specialization:'
if not once(begin,'\t\t\t\t\tlocal outcome\n'..
 '\t\t\t\t\t__probe.begin(template, sx, sy, allowed_count, allowed_types, type_cache, matches_cache, get_type, map, type_tile, revision, version, obstruct, decorated)\n'..
 '\t\t\t\t\t-- Private finite-loop specialization:')then return end
if not once('outcome = stamp_matched(prefabs, sx, sy, site_radius)',
 '__probe.finish(nil, prefabs)\n\t\t\t\t\t\t\toutcome = stamp_matched(prefabs, sx, sy, site_radius)')then return end
local finish='\t\t\t\t\tend\n\t\t\t\t\tif outcome == "placed" then'
if not once(finish,'\t\t\t\t\tend\n\t\t\t\t\tif __probe.active() then __probe.finish(outcome, nil) end\n\t\t\t\t\tif outcome == "placed" then')then return end
-- Only two synthetic outcomes have an immediately preceding complete prefix.
local synthetic=assert(source:find('local attempts, budget = ',1,true))
local head,body=source:sub(1,synthetic-1),source:sub(synthetic)
local count
body,count=body:gsub('(\n%s*)if outcome == "placed" then','%1__probe.outcome(outcome)%1if outcome == "placed" then')
if count~=2 then fail('synthetic outcome seams');return end
source=head..body
local start=source:find('function DecorTopUp.Run(',1,true)
if not start then fail('Run anchor');return end
local code='local __probe\nlocal '..table.concat(names,',')..'\n'..
 source:sub(start):gsub('^function DecorTopUp.Run%(','local function CandidateRun(')..'\nreturn CandidateRun'
local chunk,why=load(code,'@decor-rejection-shadow-Run','t',env)
if not chunk then fail(why);return end
local candidate=chunk();local joined=0
for i=1,200 do
 local name=debug.getupvalue(candidate,i)
 if not name then break end
 if name=='__probe'then debug.setupvalue(candidate,i,probe)
 elseif name=='SafeCall'then debug.setupvalue(candidate,i,probe.wrap('safe',values.SafeCall))
 elseif name=='circle_hits'then debug.setupvalue(candidate,i,probe.wrap('circle',values.circle_hits))
 elseif name=='MakeStream'then debug.setupvalue(candidate,i,function(...)return probe.stream(values.MakeStream,...)end)
 elseif cells[name]then debug.upvaluejoin(candidate,i,original,cells[name]);joined=joined+1
 else fail('unjoined private Run cell '..name);return end
end
result.joined_cells=joined
local config_before={sbm.Config.DEBUG_LOGGING_ENABLED,sbm.Config.DEBUG_LOADING_TIMINGS}
local run_wrapper,final_wrapper
local pack=function(...)return {n=select('#',...),...}end
local unpack_values=table.unpack or unpack
local function restore()
 probe.close()
 if sbm.DecorTopUp.Run==run_wrapper then sbm.DecorTopUp.Run=original else fail('Run rebound')end
 if sbm.GenerationGrids.RebuildFinal==final_wrapper then sbm.GenerationGrids.RebuildFinal=original_final else fail('final rebound')end
 result.config_unchanged=config_before[1]==sbm.Config.DEBUG_LOGGING_ENABLED and config_before[2]==sbm.Config.DEBUG_LOADING_TIMINGS
 if not result.config_unchanged then fail('config changed')end
 result.restored=sbm.DecorTopUp.Run==original and sbm.GenerationGrids.RebuildFinal==original_final
 if not result.restored then fail('hooks not restored')end
 result.status=result.error and 'fail' or 'pass'
 print('[SBM decor rejection shadow] '..result.status..' restored='..tostring(result.restored))
end
run_wrapper=function(map,...)
 probe.enter(map and map.mapdata and map.mapdata.Environment or '?')
 local values=pack(pcall(candidate,map,...))
 if values[1]then probe.leave(values[2],values[3])else fail(values[2]);probe.leave(false,{error=tostring(values[2])})end
 if not values[1]then restore();error(values[2]);return nil end
 if not values[2] or result.error then restore() end
 return unpack_values(values,2,values.n)
end
final_wrapper=function(map,stage,...)
 local values=pack(pcall(original_final,map,stage,...))
 if not values[1]then fail(values[2]);restore();error(values[2]);return nil end
 if map and map.mapdata and map.mapdata.Environment=='Surface' and stage=='post-pipeline scheduled revalidation'then restore()end
 return unpack_values(values,2,values.n)
end
sbm.DecorTopUp.Run=run_wrapper;sbm.GenerationGrids.RebuildFinal=final_wrapper
result.status='ready';return 'DECOR_REJECTION_SHADOW_READY'

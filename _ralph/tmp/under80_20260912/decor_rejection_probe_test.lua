local base='_ralph/runs/under80-20260912/artifacts/decor_rejection_fusion_2/'
local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local source=read(base..'candidate.lua')
local make=assert(loadfile('_ralph/tmp/under80_20260912/decor_rejection_probe.lua'))()
local oracle=assert(loadfile(base..'oracle_factory.lua'))()
local checks=0
local function check(ok,why)assert(ok,why);checks=checks+1 end
local a=assert(source:find('\t\t\t\t\tlocal outcome\n\t\t\t\t\t-- Private finite-loop specialization:',1,true))
local b=assert(source:find('\n\t\t\t\t\tif outcome == "placed" then',a,true))
local prefix=source:sub(a,b-1)
local old='outcome = stamp_matched(prefabs, sx, sy, site_radius)'
local i,j=assert(prefix:find(old,1,true))
prefix=prefix:sub(1,i-1)..'probe.finish(nil, prefabs); outcome = "accepted"'..prefix:sub(j+1)
prefix=prefix..'\nif probe.active() then probe.finish(outcome,nil) end\nreturn outcome'
local circle=assert(source:match('(local function circle_hits%(.-)\nend'))..'\nend\nreturn circle_hits'
local query=assert(load(circle))()
for _,mode in ipairs({'normal','blocked','decorated','empty','retry','missing','reject','nofilter'})do
 local probe=make(oracle);probe.enter('Surface')
 local calls={point=0,terrain=0,safe=0,circle=0}
 local matches,types={},{}
 local env=setmetatable({probe=probe,type_cache=types,matches_cache=matches,type_tile=2,
  allowed_count=mode=='nofilter' and 0 or 1,allowed_types={[0]=mode=='missing',[1]=true},
  revision=3,version=9,map={},obstruct={},decorated={}}, {__index=_G})
 if mode=='blocked'then env.obstruct[1]={x=0,y=0,r=999}end
 if mode=='decorated'then env.decorated[1]={x=0,y=0,r=999}end
 env.point_fn=probe.wrap('point',function(x,y)calls.point=calls.point+1;return {x=x,y=y}end)
 env.get_type=mode~='missing' and probe.wrap('terrain',function(map,p)
  check(map==env.map,'map forwarded');calls.terrain=calls.terrain+1
  return mode=='reject' and 2 or 1
 end)or nil
 env.SafeCall=probe.wrap('safe',function(fn,...)calls.safe=calls.safe+1;local ok,v=pcall(fn,...);if ok then return v end end)
 env.circle_hits=probe.wrap('circle',function(...)calls.circle=calls.circle+1;return query(...)end)
 local marker={},{}
 local match_count=0
 function marker:GetMatchingMarkers(rev,ver)
  check(rev==3 and ver==9,'matcher args');match_count=match_count+1
  if mode=='retry' and match_count<4 then error('temporary failure')end
  if mode=='empty'then return {}end
  return {{id=1}}
 end
 env.template={marker=marker,radius=2}
 local fn=assert(load(prefix,'actual finite prefix','t',env))
 for n=1,80 do
  env.sx,env.sy=n%11,n%7
  probe.begin(env.template,env.sx,env.sy,env.allowed_count,env.allowed_types,types,matches,
   env.get_type,env.map,2,3,9,env.obstruct,env.decorated)
  local outcome=fn()
  check(outcome~=nil,'prefix result');probe.outcome(outcome)
  if n==30 then env.obstruct[#env.obstruct+1]={x=5,y=5,r=1}end
 end
 probe.leave(true,{synthetic_finite_attempts=80,synthetic_attempts=80})
 check(probe.close(),'native replay probe failed '..tostring(probe.result.error))
 local row=probe.result.calls[1]
 check(row.prefixes==80 and row.outcomes==80,'complete prefix census')
 check(row.recorded==row.replayed and row.peak_events<=5,'bounded exact replay')
 check(row.recorded==calls.point+calls.terrain+calls.safe+calls.circle,'actual calls executed once')
 check(row.prefix_rng_calls==0 and probe.result.scratch_released,'no RNG or retained scratch')
 if mode=='retry'then check(match_count==4,'failed matcher remains retryable')end
 if mode=='empty'then check(match_count==1,'empty matcher cache preserved')end
end
do
 local probe=make(function()return function()return 'wrong'end end)
 probe.enter('Surface');probe.begin({marker={},radius=1},0,0,0,{}, {},{},nil,{},1,1,1,{}, {})
 check(not probe.finish(nil,{}),'outcome mismatch rejected')
 probe.outcome('accepted');probe.leave(true,{synthetic_finite_attempts=1,synthetic_attempts=1})
 check(not probe.close() and probe.result.status=='fail','failure persists')
end
do
 local probe=make(oracle);probe.enter('Surface');probe.leave(false,nil)
 check(not probe.close() and probe.result.scratch_released,'bad Run result safely closes')
end
do
 local probe=make(oracle);probe.enter('Surface')
 local stream=probe.stream(function()return{rand=function(...)return nil,select('#',...),nil end,seed=function()return 91 end}end)
 local values=table.pack(stream.rand(3,nil,5))
 check(values.n==3 and values[2]==3 and stream.seed()==91,'stream tuple/args preserved')
 probe.leave(true,{});check(probe.close() and probe.result.calls[1].rng_calls==2,'stream census')
end
-- Execute the complete native setup against an actual loaded production module.
-- Disabled Run verifies joined registry/config cells and normal hook restoration.
for _,mode in ipairs({'normal','rebound','missing_source','run_failure'})do
 local mod_env=setmetatable({}, {__index=_G});mod_env._G=mod_env
 local sbm={Config={STRETCH_DECOR_ENGINE_PASS=false},Engine={Global=function()end,
  SafeCall=function(fn,...)if type(fn)=='function'then local ok,v=pcall(fn,...);if ok then return v end end end},
  GenerationGrids={RebuildFinal=function()return nil,'final',nil end}}
 mod_env.SuperBigMap=sbm
 assert(load(read('Code/sbm_decor_topup.lua'),'actual accepted decor','t',mod_env))()
 local original,final=sbm.DecorTopUp.Run,sbm.GenerationGrids.RebuildFinal
 local harness=setmetatable({ModsLoaded={{env=mod_env}},print=function()end},{__index=_G});harness._G=harness
 harness.AsyncFileToString=function(path)
  if mode=='missing_source'then return 'missing' end
  return nil,read(path:gsub('^D:/PROJS/SMR/super%-big%-map/',''))
 end
 local setup=assert(load(read('_ralph/tmp/under80_20260912/decor_rejection_shadow.lua'),'actual shadow setup','t',harness))
 setup()
 local result=harness.SBM_DECOR_REJECTION_DIAGNOSTIC
 if mode=='missing_source'then
  check(result.status=='fail' and sbm.DecorTopUp.Run==original and sbm.GenerationGrids.RebuildFinal==final,'missing source before hooks')
 else
  check(result.status=='ready' and result.joined_cells>0,'actual setup/joins')
  local map={mapdata={Environment='Surface'},MapForEach=function()end}
  if mode=='run_failure'then map.MapForEach=nil end
  local ok,stats=sbm.DecorTopUp.Run(map)
  if mode=='run_failure'then
   check(not ok and stats.error and result.status=='fail' and result.restored,'Run failure restored immediately')
  else check(ok and stats.reason=='disabled','actual Run config/private cell')end
  local replacement=function()end
  if mode=='rebound'then sbm.DecorTopUp.Run=replacement end
  local ret=table.pack(sbm.GenerationGrids.RebuildFinal(map,'post-pipeline scheduled revalidation'))
  check(ret.n==3 and ret[2]=='final','final tuple preserved')
  if mode=='run_failure'then check(result.status=='fail' and sbm.DecorTopUp.Run==original,'failed Run stays restored')
  elseif mode=='rebound'then check(result.status=='fail' and sbm.DecorTopUp.Run==replacement,'unowned rebound not overwritten')
  else check(result.status=='pass' and result.restored and result.config_unchanged and sbm.DecorTopUp.Run==original,'normal restore')end
  check(sbm.GenerationGrids.RebuildFinal==final,'final restored')
 end
end
print('PASS '..checks..' actual-prefix native-replay and complete setup/lifecycle fixture checks')

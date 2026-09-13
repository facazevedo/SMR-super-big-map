local make=assert(loadfile('_ralph/tmp/under80_20260912/prefab_primitive_observer.lua'))()
local checks=0
local function check(v,m)assert(v,m);checks=checks+1 end
local function fixture(mode)
 local tick=0;local actual={};local owner={};local originals={}
 local obs=make(function()return tick end)
 local function stub(name)
  return function(...)
   actual[name]=(actual[name] or 0)+1;tick=tick+2
   if mode=='error' and name=='GridMask'then error('fixture native primitive error')end
   return nil,name,nil,...
  end
 end
 for _,name in ipairs(obs.result.primitives)do
  if name~='table.weighted_rand'then owner[name]=stub(name)end
 end
 owner.table={weighted_rand=stub('table.weighted_rand')}
 owner.GridDest=function(...)tick=tick+1;actual.GridDest=(actual.GridDest or 0)+1
  local values=table.pack(owner.NewComputeGrid(...));tick=tick+1
  return table.unpack(values,1,values.n)
 end
 for k,v in pairs(owner)do originals[k]=v end
 originals.weighted=owner.table.weighted_rand
 local original=assert(load('return function() return GridMask end','@fixture-native','t',owner))()
 local row={id=1,environment='Underground'}
 local function restored()
  for k,v in pairs(originals)do
   if k~='weighted'then check(owner[k]==v,'primitive leaked '..k)end
  end
  check(owner.table.weighted_rand==originals.weighted,'weighted selection leaked')
 end
 return obs,owner,original,row,actual,restored,function()return tick end
end
do
 local obs,owner,original,row,actual,restored=fixture()
 check(obs.generation_enter(original,{},nil,row),'enter')
 for i,tag in ipairs({'FindPrefabPos_Playable','FindPrefabPos_Filler','FindPrefabPos_Base'})do
  check(obs.procedure_start(row,tag,i),'start')
  for _,name in ipairs(obs.result.primitives)do
   local fn=name=='table.weighted_rand' and owner.table.weighted_rand or owner[name]
   local values=table.pack(fn(4,nil,nil))
   check(values.n==6 and values[1]==nil and values[3]==nil and values[4]==4
    and values[5]==nil and values[6]==nil,'primitive tuple '..name)
  end
  local before=obs.result.call_count
  local co=coroutine.create(function()owner.GridMask(9)end)
  check(coroutine.resume(co),'unrelated coroutine')
  check(obs.result.call_count==before,'other coroutine counted')
  check(obs.procedure_end(row,tag,i),'end')
  restored()
  local s=obs.result.scopes[i]
  check(s.call_count==17 and s.completed and s.globals_restored and s.open_primitives==0,'scope census')
  check(s.primitives.GridDest.count==1 and s.primitives.NewComputeGrid.count==2,'nested allocation census')
  check(s.primitives.GridDest.inclusive_ms==4 and s.primitives.GridDest.exclusive_ms==2,'nested exclusive cost')
  local sum=0;for _,p in pairs(s.primitives)do sum=sum+p.exclusive_ms end
  check(sum==s.primitive_ms and s.remainder_ms>=0,'primitive accounting')
 end
 check(obs.generation_exit(row,true),'exit');check(obs.restore(),'restore')
 check(obs.result.status=='pass' and obs.result.call_count==51 and obs.result.globals_restored,'final result')
 check(actual.GridMask==6 and actual.GridStableRandomPos==3 and actual['table.weighted_rand']==3,'native call fidelity')
 restored()
end
-- No mutation/census on surface or unselected procedures.
do
 local obs,owner,original,row,actual,restored=fixture()
 row.environment='Surface'
 check(obs.generation_enter(original,{},nil,row),'surface enter')
 check(obs.procedure_start(row,'FindPrefabPos_Playable',1),'surface start')
 owner.GridMask();check(obs.procedure_end(row,'FindPrefabPos_Playable',1),'surface end')
 check(obs.generation_exit(row,true),'surface exit')
 row.environment='Underground'
 check(obs.generation_enter(original,{},nil,row),'UG enter')
 check(obs.procedure_start(row,'ApplyTerrain',2),'unselected start')
 owner.GridMask();check(obs.procedure_end(row,'ApplyTerrain',2),'unselected end')
 check(obs.generation_exit(row,true) and obs.restore(),'unselected restoration')
 check(obs.result.call_count==0 and #obs.result.scopes==0 and actual.GridMask==2,'selection scope')
 restored()
end
for _,missing in ipairs({'env','GridMask','table','weighted_rand'})do
 local obs,owner,original,row,actual,restored=fixture()
 local before=owner.GridDistanceMars
 if missing=='env'then original=function()return 1 end
 elseif missing=='table'then owner.table=nil
 elseif missing=='weighted_rand'then owner.table.weighted_rand=nil
 else owner[missing]=nil end
 check(not obs.generation_enter(original,{},nil,row),'missing prerequisite accepted '..missing)
 check(owner.GridDistanceMars==before and obs.result.status=='fail','partial preflight mutation')
end
for _,mode in ipairs({'error','unfinished','endpoint','rebound','changed_before','cap'})do
 local obs,owner,original,row,actual,restored=fixture(mode)
 check(obs.generation_enter(original,{},nil,row),'failure fixture enter')
 local saved=owner.GridMask
 if mode=='changed_before'then
  owner.GridMask=function()end
  check(not obs.procedure_start(row,'FindPrefabPos_Playable',1),'changed owner accepted')
  owner.GridMask=saved
 else
  check(obs.procedure_start(row,'FindPrefabPos_Playable',1),'failure fixture start')
  if mode=='error'then
   check(not pcall(owner.GridMask),'primitive exception swallowed')
  elseif mode=='endpoint'then
   check(not obs.procedure_end(row,'FindPrefabPos_Playable',2),'wrong endpoint accepted')
  elseif mode=='rebound'then
   local replacement=function()end;owner.GridMask=replacement
   check(not obs.procedure_end(row,'FindPrefabPos_Playable',1),'rebound accepted')
   check(owner.GridMask==replacement,'overwrote unrelated replacement');owner.GridMask=saved
  elseif mode=='cap'then
   obs.result.call_count=250000;owner.GridMask()
   check(actual.GridMask==1,'cap prevented native call')
  end
 end
 obs.generation_exit(row,mode~='error');obs.restore()
 check(obs.result.status=='fail' and #obs.result.issues>0,'failure not latched '..mode)
 restored()
end
-- Exception after a proxy assignment still restores every attempted slot.
do
 local obs,owner,original,row,actual,restored=fixture()
 local backing={};for k,v in pairs(owner)do backing[k]=v;owner[k]=nil end
 local armed=true
 setmetatable(owner,{__index=backing,__newindex=function(_,name,value)
  backing[name]=value
  if armed and name=='GridAnd'then armed=false;error('fixture install exception')end
 end})
 check(obs.generation_enter(original,{},nil,row),'proxy enter')
 check(not obs.procedure_start(row,'FindPrefabPos_Playable',1),'partial install accepted')
 obs.generation_exit(row,true);obs.restore()
 check(obs.result.status=='fail' and obs.result.scopes[1].globals_restored,'partial install cleanup')
 restored()
end
-- Real driver + inherited coarse probe, with native calls resolved through _ENV.
do
 local obs,owner,original,row,actual,restored=fixture()
 local inherited={};for k,v in pairs(owner)do inherited[k]=v;owner[k]=nil end
 setmetatable(owner,{__index=inherited})
 check(obs.generation_enter(original,{},nil,row),'inherited owner enter')
 check(obs.procedure_start(row,'FindPrefabPos_Playable',1),'inherited owner start')
 check(rawget(owner,'GridMask')~=nil,'fixture did not create raw hook')
 owner.GridMask()
 check(obs.procedure_end(row,'FindPrefabPos_Playable',1),'inherited owner end')
 for _,name in ipairs(obs.result.primitives)do
  if name~='table.weighted_rand'then check(rawget(owner,name)==nil,'inherited raw slot leaked '..name)end
 end
 check(obs.generation_exit(row,true) and obs.restore(),'inherited owner restoration')
 restored()
end
-- Real driver + inherited coarse probe, with native calls resolved through _ENV.
do
 local tick=0
 local class={Generate=function()end,DoGenerate=function()end,OnGenerateLogic=function()end,
  ProcStart=function()end,ProcEnd=function()end}
 local sbm={State={generator_generate_wrapper=class.Generate,generator_do_generate_wrapper=class.DoGenerate,
  generator_on_generate_logic_wrapper=class.OnGenerateLogic},Config={},
  Engine={Global=function()return class end},GenerationGrids={RebuildFinal=function()return nil,5,nil end},
  CallDoGenerateWithRockParityTrace=function(original,generator,map,...)return original(generator,map,...)end}
 local env=setmetatable({ModsLoaded={{env={SuperBigMap=sbm}}},class=class,
  GetPreciseTicks=function()return tick end,print=function()end,
  AsyncFileToString=function(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return nil,s end},
  {__index=_G})
 env._G=env
 for _,name in ipairs(make(function()return tick end).result.primitives)do
  if name~='table.weighted_rand'then env[name]=function(...)tick=tick+1;return ... end end
 end
 env.table=setmetatable({weighted_rand=function(...)tick=tick+1;return ... end},{__index=table})
 local original=assert(load([[return function(self,map,...)
  for _,tag in ipairs({'FindPrefabPos_Playable','FindPrefabPos_Filler','FindPrefabPos_Base'})do
   class.ProcStart(self,tag);GridMask(1);GridStableRandomPos({},17);class.ProcEnd(self,tag)
  end
  return nil,7,nil,...
 end]],'@fixture-shipped','t',env))()
 local saved_call,saved_final,saved_mask=sbm.CallDoGenerateWithRockParityTrace,sbm.GenerationGrids.RebuildFinal,env.GridMask
 local setup=assert(loadfile('_ralph/tmp/under80_20260912/prefab_primitive_profile.lua','t',env))()
 check(setup=='NATIVE_PROC_PROFILE_READY' and env.SBM_NATIVE_PROC_OBSERVER==nil,'integrated setup/observer slot')
 local values=table.pack(sbm.CallDoGenerateWithRockParityTrace(original,{}, {mapdata={Environment='Underground'}},3,nil))
 check(values.n==5 and values[1]==nil and values[2]==7 and values[3]==nil and values[4]==3 and values[5]==nil,'integrated native tuple')
 sbm.GenerationGrids.RebuildFinal({mapdata={Environment='Surface'}},'post-pipeline scheduled revalidation')
 local r=env.SBM_NATIVE_PROC_DIAGNOSTIC
 check(r.status=='pass' and r.restored and #r.calls==3,'integrated coarse result')
 check(r.primitive.status=='pass' and r.primitive.globals_restored and r.primitive.call_count==6,'integrated primitive result')
 check(sbm.CallDoGenerateWithRockParityTrace==saved_call and sbm.GenerationGrids.RebuildFinal==saved_final
  and env.GridMask==saved_mask,'integrated restoration')
end
print('PASS prefab primitive observer: '..checks..' scope/tuple/count/nesting/thread/owner/failure/driver checks')

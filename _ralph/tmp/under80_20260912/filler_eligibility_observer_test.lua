local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local source=read('_ralph/tmp/under80_20260912/filler_mask_observer_test.lua')
source=source:sub(1,assert(source:find('\ndo\n local obs',1,true))-1)
local function replace(old,new)
 local a,b=source:find(old,1,true);assert(a,'fixture anchor '..old)
 assert(not source:find(old,b+1,true),'duplicate fixture anchor')
 source=source:sub(1,a-1)..new..source:sub(b+1)
end
replace("_ralph/tmp/under80_20260912/filler_mask_observer.lua","_ralph/runs/under80-20260912/artifacts/filler_eligibility_observer/observer.lua")
replace('filler_mask_cache.lua','filler_eligibility_cache.lua')
replace('local game_source','local game_source,game_place')
replace(' owner.GridFill=function',[[
 owner.GridDistanceMars=function(place,dest,a,b)
  check(place==game_place and dest==game_source and a==1 and b==1,'actual distance lineage')
  return nil,'distance',nil
 end
 owner.GridAnd=function(a,b)
  check(live[a] and live[b],'and freed grid');tick=tick+3
  for i=1,8 do a.v[i]=a.v[i]~=0 and b.v[i]~=0 and 1 or 0 end
  return nil,'and',nil,a,b
 end
 owner.GridCircleSet=function(g,value,p,r)
  check(live[g],'circle freed grid');tick=tick+1
  for y=0,1 do for x=0,3 do
   if (x-p.x)^2+(y-p.y)^2<=r*r then g.v[y*4+x+1]=value end
  end end
  return nil,'circle',nil,g
 end
 owner.GridFill=function]])
replace(" local dest=grid(nil,'U',true)"," local dest=grid(nil,'U',true)\n game_place=grid({65535,65535,65535,65535,65535,65535,65535,65535},'U',true)")
replace(' local saved=owner.GridMask',[[
 local saved={}
 for _,name in ipairs({'GridMask','GridAnd','GridCircleSet','GridDistanceMars'})do saved[name]=owner[name]end
]])
replace("check(owner.GridMask==saved,'native mask hook leaked')", "for name,fn in pairs(saved)do check(owner[name]==fn,'native hook leaked '..name)end")
replace('function()return tick end,grid','function()return tick end,grid,game_place')
local tests=[[
for _,mode in ipairs({'normal','bad_copy','source_mutation','partial_mask','clone_alias','repack_error','bad_comparator','private_mask_error','unexpected_mutation','missing_and'})do
 local obs,owner,original,row,src,dest,clean,actual,ticks,grid,place=fixture(mode)
 check(obs.generation_enter(original,{},nil,row),'enter')
 check(obs.procedure_start(row,'FindPrefabPos_Filler',3),'start')
 local values=table.pack(owner.GridDistanceMars(place,src,1,1))
 check(values.n==3 and values[2]=='distance','distance nil tuple preserved')
 local requests={1,2,1,3,1,2,4,5,6,7,8,9,10,11,11,11}
 for i,lo in ipairs(requests)do
  if mode=='unexpected_mutation' and i==2 then place.v[1]=0 end
  local expected={}
  for j,v in ipairs(src.v)do expected[j]=v>=lo and place.v[j]~=0 and 1 or 0 end
  values=table.pack(owner.GridMask(src,dest,lo,2147483647,1))
  check(values.n==6 and values[2]=='mask' and values[4]==src and values[5]==dest,'mask nil tuple preserved')
  if mode~='missing_and' or i~=#requests then
   values=table.pack(owner.GridAnd(dest,place))
   check(values.n==5 and values[2]=='and' and values[4]==dest and values[5]==place,'and nil tuple preserved')
  end
  if mode=='normal'then for j,v in ipairs(expected)do check(dest.v[j]==v,'actual complete eligibility unchanged')end end
  if i%4==0 and mode~='missing_and'then
   values=table.pack(owner.GridCircleSet(place,0,{x=i%5-1,y=i%3-1},0.5))
   check(values.n==4 and values[2]=='circle' and values[4]==place,'circle nil tuple preserved')
  end
 end
 local ok=obs.procedure_end(row,'FindPrefabPos_Filler',3)
 obs.generation_exit(row,true);obs.restore()
 check(actual()==#requests,'every actual mask executes once')
 local scope=obs.result.scopes[1]
 if mode=='normal'then
  check(ok and obs.result.status=='pass' and scope.completed,'successful native-shaped trace')
  check(#scope.requests==#requests and scope.clears==4 and scope.journal_events==#requests+4,'ordered mutation journal')
  check(scope.output_comparisons==#requests and scope.comparisons==4*#requests+4+8,'complete native-shaped comparisons')
  check(#scope.benchmarks==2,'both replay orders')
  for _,b in ipairs(scope.benchmarks)do
   check(b.old_ms>=0 and b.new_ms>=0,'coarse replay clocks')
   for k,v in pairs(scope.shadow_stats)do check(b.stats[k]==v,'full replay work census '..k)end
  end
 else check(not ok and obs.result.status=='fail' and #obs.result.issues>0,'fault rejected '..mode)end
 clean()
end
for _,mode in ipairs({'inherited','unfinished','rebound'})do
 local obs,owner,original,row,src,dest,clean,actual,tick,grid,place=fixture()
 if mode=='inherited'then
  local inherited={};for k,v in pairs(owner)do inherited[k]=v;owner[k]=nil end
  setmetatable(owner,{__index=inherited})
 end
 local saved=owner.GridMask
 check(obs.generation_enter(original,{},nil,row),'lifecycle enter')
 check(obs.procedure_start(row,'FindPrefabPos_Filler',3),'lifecycle start')
 owner.GridDistanceMars(place,src,1,1);owner.GridMask(src,dest,1,2147483647,1);owner.GridAnd(dest,place)
 if mode=='inherited'then
  local co=coroutine.create(function()owner.GridMask(src,dest,2,2147483647,1);owner.GridAnd(dest,place)end)
  check(coroutine.resume(co),'foreign thread calls')
  check(#obs.result.scopes[1].requests==1 and actual()==2,'foreign calls not captured')
  check(obs.procedure_end(row,'FindPrefabPos_Filler',3),'inherited end')
  obs.generation_exit(row,true);check(obs.restore(),'inherited restore')
  for _,name in ipairs({'GridMask','GridAnd','GridCircleSet','GridDistanceMars'})do check(rawget(owner,name)==nil,'inherited raw slot restored')end
 elseif mode=='unfinished'then check(not obs.restore(),'unfinished fails and cleans')
 else
  local replacement=function()end;owner.GridMask=replacement
  check(not obs.procedure_end(row,'FindPrefabPos_Filler',3),'rebound scope fails')
  obs.generation_exit(row,true);obs.restore()
  check(owner.GridMask==replacement,'unrelated replacement preserved');owner.GridMask=saved
 end
 clean()
end
-- Full composition with the unchanged native-procedure owner/lifecycle driver.
do
 local obs,owner,original,row,src,dest,clean,actual,tick,grid,place=fixture()
 local class={Generate=function()end,DoGenerate=function()end,OnGenerateLogic=function()end,
  ProcStart=function()end,ProcEnd=function()end}
 local sbm={Config={},State={generator_generate_wrapper=class.Generate,
  generator_do_generate_wrapper=class.DoGenerate,generator_on_generate_logic_wrapper=class.OnGenerateLogic},
  Engine={Global=function()return class end},GenerationGrids={RebuildFinal=function()return true,nil end},
  CallDoGenerateWithRockParityTrace=function(fn,generator,map,...)return fn(generator,map,...)end}
 owner.class=class;owner.src=src;owner.dest=dest;owner.place=place
 owner.ModsLoaded={{env={SuperBigMap=sbm}}};owner.GetPreciseTicks=tick;owner.print=function()end
 owner.AsyncFileToString=function(path)local f=assert(io.open(path,'r'));local text=f:read('*a');f:close();return nil,text end
 setmetatable(owner,{__index=_G});owner._G=owner
 local fn=assert(load('return function(self,map) class.ProcStart(self,"FindPrefabPos_Filler");GridDistanceMars(place,src,1,1);GridMask(src,dest,1,2147483647,1);GridAnd(dest,place);class.ProcEnd(self,"FindPrefabPos_Filler");return nil,17,nil end','@fixture-shipped','t',owner))()
 check(assert(loadfile('_ralph/tmp/under80_20260912/filler_eligibility_profile.lua','t',owner))()=='NATIVE_PROC_PROFILE_READY','driver ready')
 check(owner.SBM_NATIVE_PROC_OBSERVER==nil,'registration removed')
 local values=table.pack(sbm.CallDoGenerateWithRockParityTrace(fn,{}, {mapdata={Environment='Underground'}}))
 check(values.n==3 and values[2]==17,'driver nil tuple')
 sbm.GenerationGrids.RebuildFinal({mapdata={Environment='Surface'}},'post-pipeline scheduled revalidation')
 local r=owner.SBM_NATIVE_PROC_DIAGNOSTIC
 check(r.status=='pass' and r.restored and r.primitive.status=='pass' and r.primitive.scratch_released,'driver full cleanup')
 clean()
end
print('PASS '..checks..' mutation observer actual-call/tuple/lineage/replay/cleanup checks')
]]
assert(load(source..'\n'..tests,'extended eligibility observer fixture','t',_G))()

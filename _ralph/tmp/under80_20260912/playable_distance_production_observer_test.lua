local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local source=read('_ralph/tmp/under80_20260912/playable_distance_observer_test.lua')
source=source:sub(1,assert(source:find("\nfor _,mode in ipairs({'normal'",1,true))-1)
local function replace(old,new)local a,b=assert(source:find(old,1,true));source=source:sub(1,a-1)..new..source:sub(b+1)end
replace("dst.v=values;return nil,'distance',nil,dst,nil","dst.v=values;return dst")
replace('saved,function()return tick end','saved,function()return tick end,borrowed')
local tests=[=[
local obs,owner,original,row,unused,clean,actual,place,bounds,grid,saved,ticks,borrowed=fixture()
for _,name in ipairs({'GridAnd','GridNot','GridMask','GridFill','GridMulDivAdd','GridMulAddScaled'})do owner[name]=function()end end
local class={Generate=function()end,DoGenerate=function()end,OnGenerateLogic=function()end,ProcStart=function()end,ProcEnd=function()end}
local generator={};local map={mapdata={Environment='Underground'}}
local install=assert(loadfile('_ralph/tmp/under80_20260912/playable_distance_helper.lua'))()
local close,stats
local function dest(src)local d=owner.GridDest(src);borrowed[d]=true;return d end
local function stream()
 local primary
 for epoch=1,3 do
  primary=dest(place);owner.GridOr(place,primary,bounds);owner.GridDistanceMars(primary,1,1)
  for j=1,2 do local secondary=dest(place);owner.GridDistanceMars(place,secondary,1,1);secondary.v[1]=999;owner.GridOpFree(secondary)end
  if epoch<3 then owner.GridCircleSet(place,1,{x=epoch,y=epoch},0);owner.GridOpFree(primary)end
 end
 owner.GridOpFree(bounds);owner.GridOpFree(place);owner.GridOpFree(primary)
end
local sbm={Config={},State={generator_generate_wrapper=class.Generate,generator_do_generate_wrapper=class.DoGenerate,
 generator_on_generate_logic_wrapper=class.OnGenerateLogic},Engine={Global=function()return class end},
 GenerationGrids={RebuildFinal=function()return true,nil end},
 CallDoGenerateWithRockParityTrace=function(fn,g,m,...)return fn(g,m,...)end}
owner.class=class;owner.stream=stream;owner.ModsLoaded={{env={SuperBigMap=sbm}}};owner.GetPreciseTicks=ticks;owner.print=function()end
owner.AsyncFileToString=function(path)local f=assert(io.open(path,'r'));local text=f:read('*a');f:close();return nil,text end
setmetatable(owner,{__index=_G});owner._G=owner
local fn=assert(load('return function(self,map) class.ProcStart(self,"FindPrefabPos_Playable");stream();class.ProcEnd(self,"FindPrefabPos_Playable");return nil,17,nil end','native-shaped','t',owner))()
check(assert(loadfile('_ralph/tmp/under80_20260912/playable_distance_production_profile.lua','t',owner))()=='NATIVE_PROC_PROFILE_READY','profile ready')
close,stats=install(generator,class,function(k)return owner[k]end,function(k,v)owner[k]=v;return true end)
map.SuperBigMapNativePlayableDistanceStats=stats
local values=table.pack(sbm.CallDoGenerateWithRockParityTrace(fn,generator,map))
check(values.n==3 and values[2]==17,'native caller tuple')
check(close(),'production close '..tostring(stats.failure))
sbm.GenerationGrids.RebuildFinal({mapdata={Environment='Surface'}},'post-pipeline scheduled revalidation')
local r=owner.SBM_NATIVE_PROC_DIAGNOSTIC
check(r.status=='pass' and r.restored,'driver status '..tostring(r.error))
check(r.primitive.status=='pass' and r.primitive.scratch_released and r.primitive.globals_restored,'shadow restored')
check(r.primitive.production.cached_primary==2 and r.primitive.production.cached_secondary==5,'actual cached substitutions observed')
check(r.primitive.production.invalidations==0 and r.primitive.production.guards==2,'independent oracle never invalidates production')
check(r.primitive.scopes[1].primary==3 and r.primitive.scopes[1].secondary==6,'every substituted output compared')
check(actual()==2,'oracle and replay use private originals, no extra real native transform')
clean();print('PASS '..checks..' actual helper/independent native-oracle/driver composition checks')
]=]
assert(load(source..'\n'..tests,'production shadow composition','t',_G))()

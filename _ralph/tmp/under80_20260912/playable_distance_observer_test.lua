-- Model validates observer protocol, not the native distance identity or speed.
local make=assert(loadfile('_ralph/runs/under80-20260912/artifacts/playable_distance_observer/observer.lua'))()
local checks=0
local function check(v,m)assert(v,m);checks=checks+1 end
local hooks={'GridOr','GridDistanceMars','GridCircleSet','GridOpFree'}
local function fixture(mode)
 local live,borrowed={},{};local tick,actual_distance=0,0
 local mt={};mt.__index=mt
 local function grid(values,fmt,caller)
  local g=setmetatable({v={},format=fmt or 'U'},mt)
  for i=1,16 do g.v[i]=values and values[i] or 0 end
  live[g]=true;if caller then borrowed[g]=true end;return g
 end
 function mt:size()check(live[self],'size freed');return 4,4 end
 function mt:get(x,y)check(live[self],'get freed');return self.v[y*4+x+1]end
 function mt:set(x,y,v)check(live[self],'set freed');self.v[y*4+x+1]=v end
 function mt:clone()
  check(live[self],'clone freed');tick=tick+1
  if mode=='clone_alias'then return self end
  return grid(self.v,self.format)
 end
 function mt:copy(src)
  check(live[self] and live[src],'copy freed');tick=tick+1
  for i=1,16 do self.v[i]=src.v[i]+(mode=='bad_copy' and 1 or 0)end
 end
 function mt:free()
  check(live[self] and not borrowed[self],'free borrowed/dead');live[self]=nil;tick=tick+1
 end
 local owner={}
 owner.GridDest=function(g)check(live[g],'dest freed');tick=tick+1;return grid(nil,g.format)end
 owner.GridOr=function(a,d,b)
  check(live[a] and live[d] and live[b],'or freed');tick=tick+2
  for i=1,16 do d.v[i]=(a.v[i]~=0 or b.v[i]~=0) and 1 or 0 end
  return nil,'or',nil,d,nil
 end
 owner.GridMin=function(a,d,b)
  check(live[a] and live[d] and live[b],'min freed');tick=tick+2
  for i=1,16 do d.v[i]=math.min(a.v[i],b.v[i])+(mode=='bad_min' and 1 or 0)end
 end
 owner.GridDistanceMars=function(src,dst,a,b)
  local inplace=type(dst)=='number'
  if inplace then check(dst==1 and a==1,'inplace args');dst=src
  else check(a==1 and b==1,'outplace args')end
  check(live[src] and live[dst],'distance freed');tick=tick+10
  if borrowed[src]then actual_distance=actual_distance+1 end
  if mode=='native_error' and borrowed[src]then error('actual-distance-sentinel')end
  if mode=='private_error' and not borrowed[src]then error('private-distance-sentinel')end
  local values={}
  for y=0,3 do for x=0,3 do
   local best=65535
   for yy=0,3 do for xx=0,3 do
    if src.v[yy*4+xx+1]~=0 then best=math.min(best,math.abs(x-xx)+math.abs(y-yy))end
   end end
   values[y*4+x+1]=best
  end end
  dst.v=values;return nil,'distance',nil,dst,nil
 end
 owner.GridCircleSet=function(g,value,p,r)
  check(live[g],'circle freed');tick=tick+1
  for y=0,3 do for x=0,3 do if (x-p.x)^2+(y-p.y)^2<=r*r then g.v[y*4+x+1]=value end end end
  return nil,'circle',nil,g
 end
 owner.GridOpFree=function(g)
  if g then check(borrowed[g] and live[g],'game free ownership');borrowed[g]=nil;g:free()end
  return nil,'free',nil
 end
 owner.GridRepack=function(g,fmt,bits,copy)
  check(live[g] and fmt=='f' and bits==32 and copy,'repack contract')
  if mode=='repack_error'then error('repack sentinel')end
  return grid(g.v,'F')
 end
 owner.GridAddMulDiv=function(a,b,mul)for i=1,16 do a.v[i]=a.v[i]+b.v[i]*mul end end
 owner.GridAbs=function(g)for i=1,16 do g.v[i]=math.abs(g.v[i])end end
 owner.GridCount=function(g,lo,hi)
  if mode=='bad_comparator'then return 0 end
  local n=0;for _,v in ipairs(g.v)do if lo<=v and v<=hi then n=n+1 end end;return n
 end
 owner.GridMinMax=function(g)
  check(live[g],'minmax freed');local lo,hi=math.huge,-math.huge
  for _,v in ipairs(g.v)do lo=math.min(lo,v);hi=math.max(hi,v)end;return lo,hi
 end
 owner.IsComputeGrid=function(g)return g.format end
 local saved={};for _,name in ipairs(hooks)do saved[name]=owner[name]end
 local place,bounds=grid(nil,'U',true),grid(nil,'U',true);bounds.v[1]=1
 local original=assert(load('return function()return GridOr end','native-shaped','t',owner))()
 local row={id=1,environment='Underground'}
 local obs=make(function()return tick end)
 local function tuple(name,...)
  local v=table.pack(...)
  check(v[1]==nil and v[2]==name and v[3]==nil,'native tuple holes '..name)
  check(v.n==({distance=5,or_=5,circle=4,free=3})[name=='or' and 'or_' or name],'native tuple length')
 end
 local function stream()
  local primary
  for epoch=1,3 do
   primary=grid(nil,'U',true);tuple('or',owner.GridOr(place,primary,bounds))
   tuple('distance',owner.GridDistanceMars(primary,1,1))
   if mode=='place_mutation' and epoch==2 then place.v[16]=1 end
   if mode=='bounds_mutation' and epoch==2 then bounds.v[16]=1 end
   for j=1,2 do
    local secondary=grid(nil,'U',true)
    tuple('distance',owner.GridDistanceMars(place,secondary,1,1))
    -- Weighting can destroy the caller's output; the cached field must survive.
    secondary.v[1]=999;owner.GridOpFree(secondary)
   end
   if epoch<3 or mode=='last_write'then tuple('circle',owner.GridCircleSet(place,1,{x=epoch,y=epoch},0))end
   if epoch<3 then tuple('free',owner.GridOpFree(primary));primary=nil end
  end
  if mode=='free_mutation'then place.v[16]=1 end
  tuple('free',owner.GridOpFree(bounds));tuple('free',owner.GridOpFree(place))
  tuple('free',owner.GridOpFree(primary));tuple('free',owner.GridOpFree(nil))
 end
 local function clean(rebound)
  for _,name in ipairs(hooks)do if name~=rebound then check(owner[name]==saved[name],'hook leaked '..name)end end
  for g in pairs(live)do check(borrowed[g],'scratch leaked')end
 end
 return obs,owner,original,row,stream,clean,function()return actual_distance end,place,bounds,grid,saved,function()return tick end
end
for _,mode in ipairs({'normal','last_write','bad_copy','bad_min','clone_alias','repack_error',
 'bad_comparator','private_error','native_error','place_mutation','bounds_mutation','free_mutation'})do
 local obs,owner,original,row,stream,clean,actual=fixture(mode)
 check(obs.generation_enter(original,{},nil,row),'enter')
 check(obs.procedure_start(row,'FindPrefabPos_Playable',3),'start')
 local ran,why=pcall(stream)
 if mode=='native_error'then check(not ran and tostring(why):find('actual%-distance%-sentinel'),'original error preserved')
 else check(ran,why)end
 local ok=obs.procedure_end(row,'FindPrefabPos_Playable',3)
 obs.generation_exit(row,true);obs.restore()
 if mode=='normal' or mode=='last_write'then
  check(ok and obs.result.status=='pass',table.concat(obs.result.issues,';'))
  local s=obs.result.scopes[1];local p,n,w=3,6,mode=='last_write' and 3 or 2
  check(actual()==p+n,'all actual transforms exactly once')
  check(s.primary==p and s.secondary==n and s.writes==w and s.unions==p,'boundary census')
  check(s.primary_frees==p and s.place_frees==1 and s.bounds_frees==1,'free census')
  check(s.comparisons==6*p+3*n+w+11 and s.output_comparisons==2*p+n,'comparison census')
  check(s.compared_cells==16*s.comparisons and s.self_test_cells==48,'full-cell census')
  check(s.journal_events==2*p+n+w and s.completed and s.scratch_released,'journal/completion')
  check(s.return_shapes.primary['5:nil:string:nil:destination:nil']==p,'primary tuple census')
  check(s.return_shapes.secondary['5:nil:string:nil:destination:nil']==n,'secondary tuple census')
  check(#s.benchmarks==2 and s.benchmarks[1].order=='old_new' and s.benchmarks[2].order=='new_old','both orders')
  for _,b in ipairs(s.benchmarks)do
   check(b.old_ms>0 and b.new_ms>0,'complete replay clocks')
   check(b.old_stats.transforms==p+n and b.new_stats.transforms==p+1,'transform work')
   check(b.new_stats.minimums==p and b.new_stats.copies==n and b.old_stats.unions==p and b.new_stats.unions==p,'replacement work')
   check(b.new_stats.writes==w and b.old_stats.writes==w,'replay all writes')
  end
 else check(not ok and obs.result.status=='fail' and #obs.result.issues>0,'fault not rejected '..mode)end
 clean()
end
for _,mode in ipairs({'inherited','unfinished','rebound','wrong_pair'})do
 local obs,owner,original,row,stream,clean,actual,place,bounds,grid,saved=fixture()
 if mode=='inherited'then
  local inherited={};for k,v in pairs(owner)do inherited[k]=v;owner[k]=nil end
  setmetatable(owner,{__index=inherited})
 end
 obs.generation_enter(original,{},nil,row);obs.procedure_start(row,'FindPrefabPos_Playable',3)
 if mode=='inherited'then
  local co=coroutine.create(function()local g=grid(nil,'U',true);owner.GridDistanceMars(g,1,1);owner.GridOpFree(g)end)
  check(coroutine.resume(co),'foreign coroutine original path')
  stream();check(obs.procedure_end(row,'FindPrefabPos_Playable',3),'inherited end')
  obs.generation_exit(row,true);check(obs.restore(),'inherited restore')
  check(actual()==10,'foreign transform runs once without capture')
  for _,name in ipairs(hooks)do check(rawget(owner,name)==nil,'raw inherited slot restored')end
 elseif mode=='unfinished'then
  local g=grid(nil,'U',true);owner.GridOr(place,g,bounds);check(not obs.restore(),'unfinished fails')
 elseif mode=='wrong_pair'then
  local g=grid(nil,'U',true);owner.GridOr(place,g,bounds);owner.GridDistanceMars(place,g,1,1)
  check(not obs.procedure_end(row,'FindPrefabPos_Playable',3),'wrong pair fails');obs.generation_exit(row,true);obs.restore()
 else
  local replacement=function()end;owner.GridOr=replacement
  check(not obs.procedure_end(row,'FindPrefabPos_Playable',3),'rebound fails');obs.generation_exit(row,true);obs.restore()
  check(owner.GridOr==replacement,'replacement preserved');owner.GridOr=saved.GridOr
 end
 clean()
end
-- Integrate the actual profile registration and unchanged owner/lifecycle driver.
do
 local obs,owner,original,row,stream,clean,actual,place,bounds,grid,saved,ticks=fixture()
 local class={Generate=function()end,DoGenerate=function()end,OnGenerateLogic=function()end,
  ProcStart=function()end,ProcEnd=function()end}
 local sbm={Config={},State={generator_generate_wrapper=class.Generate,
  generator_do_generate_wrapper=class.DoGenerate,generator_on_generate_logic_wrapper=class.OnGenerateLogic},
  Engine={Global=function()return class end},GenerationGrids={RebuildFinal=function()return true,nil end},
  CallDoGenerateWithRockParityTrace=function(fn,generator,map,...)return fn(generator,map,...)end}
 owner.class=class;owner.stream=stream;owner.ModsLoaded={{env={SuperBigMap=sbm}}}
 owner.GetPreciseTicks=ticks;owner.print=function()end
 owner.AsyncFileToString=function(path)local f=assert(io.open(path,'r'));local text=f:read('*a');f:close();return nil,text end
 setmetatable(owner,{__index=_G});owner._G=owner
 local fn=assert(load('return function(self,map) class.ProcStart(self,"FindPrefabPos_Playable");stream();class.ProcEnd(self,"FindPrefabPos_Playable");return nil,17,nil end','@fixture-native','t',owner))()
 check(assert(loadfile('_ralph/tmp/under80_20260912/playable_distance_profile.lua','t',owner))()=='NATIVE_PROC_PROFILE_READY','driver ready')
 check(owner.SBM_NATIVE_PROC_OBSERVER==nil,'registration removed')
 local values=table.pack(sbm.CallDoGenerateWithRockParityTrace(fn,{}, {mapdata={Environment='Underground'}}))
 check(values.n==3 and values[2]==17,'driver tuple preserved')
 sbm.GenerationGrids.RebuildFinal({mapdata={Environment='Surface'}},'post-pipeline scheduled revalidation')
 local r=owner.SBM_NATIVE_PROC_DIAGNOSTIC
 check(r.status=='pass' and r.restored and r.primitive.status=='pass' and r.primitive.scratch_released,'driver complete cleanup')
 clean()
end
do
 local obs,owner,original,row,stream,clean,actual,place,bounds,grid=fixture()
 obs.generation_enter(original,{},nil,row);obs.procedure_start(row,'FindPrefabPos_Playable',3)
 local g=grid(nil,'U',true);owner.GridOr(place,g,bounds);owner.GridDistanceMars(g,1,1)
 for i=1,4097 do local dest=grid(nil,'U',true);owner.GridDistanceMars(place,dest,1,1);owner.GridOpFree(dest)end
 check(not obs.procedure_end(row,'FindPrefabPos_Playable',3),'journal cap rejects')
 obs.generation_exit(row,true);obs.restore()
 check(table.concat(obs.result.issues,';'):find('distance journal cap',1,true),'explicit journal cap failure')
 check(actual()==4098,'cap does not skip real calls');clean()
end
print('PASS '..checks..' playable observer model checks (native identity/speed require game evidence)')

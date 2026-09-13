local make=assert(loadfile('_ralph/tmp/under80_20260912/filler_mask_observer.lua'))()
local kernel=assert(loadfile('_ralph/tmp/under80_20260912/filler_mask_cache.lua'))()
local checks=0
local function check(v,m)assert(v,m);checks=checks+1 end
local function fixture(mode)
 local tick=0;local live,borrowed={},{};local actual=0;local game_source
 local mt={};mt.__index=mt
 local function grid(values,format,caller)
  local g=setmetatable({v={},format=format or 'U'},mt)
  for i=1,8 do g.v[i]=values and values[i] or 0 end
  live[g]=true;if caller then borrowed[g]=true end
  return g
 end
 function mt:size()return 4,2 end
 function mt:get(x,y)check(live[self],'get freed grid');return self.v[y*4+x+1]end
 function mt:set(x,y,v)check(live[self],'set freed grid');self.v[y*4+x+1]=v end
 function mt:clone()
  tick=tick+1
  if mode=='clone_alias'then return self end
  return grid(self.v,self.format)
 end
 function mt:copy(from)
  check(live[self] and live[from],'copy freed grid');tick=tick+1
  for i=1,8 do self.v[i]=from.v[i]+(mode=='bad_copy' and 1 or 0)end
 end
 function mt:free()check(live[self] and not borrowed[self],'free borrowed/dead grid');live[self]=nil;tick=tick+1 end
 local owner={}
 owner.GridMask=function(src,dst,lo,hi,scale)
  check(live[src] and live[dst],'mask freed grid');tick=tick+5
  if src==game_source then actual=actual+1 end
  if mode=='private_mask_error' and src~=game_source then error('fixture private mask error')end
  if mode=='source_mutation'then src.v[1]=src.v[1]+1 end
  for i,value in ipairs(src.v)do
   if mode~='partial_mask' or value>=lo then dst.v[i]=(value>=lo and value<=hi) and scale or 0 end
  end
  return nil,'mask',nil,src,dst,nil
 end
 owner.GridFill=function(g,v)check(live[g],'fill freed');for i=1,8 do g.v[i]=v end;tick=tick+1 end
 owner.GridDest=function(g)check(live[g],'dest freed');tick=tick+1;return grid(nil,g.format)end
 owner.GridRepack=function(g,fmt,bits,copy)
  check(copy==true and bits==32 and fmt=='f' and live[g],'repack contract')
  if mode=='repack_error'then error('fixture repack error')end
  return grid(g.v,'F')
 end
 owner.GridAddMulDiv=function(a,b,mul)for i=1,8 do a.v[i]=a.v[i]+b.v[i]*mul end end
 owner.GridAbs=function(g)for i=1,8 do g.v[i]=math.abs(g.v[i])end end
 owner.GridCount=function(g,lo,hi)
  if mode=='bad_comparator'then return 0 end
  local n=0;for _,v in ipairs(g.v)do if lo<=v and v<=hi then n=n+1 end end;return n
 end
 owner.GridMinMax=function(g)
  check(live[g],'minmax freed');local lo,hi=math.huge,-math.huge
  for _,v in ipairs(g.v)do lo=math.min(lo,v);hi=math.max(hi,v)end
  return lo,hi
 end
 owner.IsComputeGrid=function(g)return g.format end
 game_source=grid({0,1,2,3,5,8,13,21},'U',true)
 local dest=grid(nil,'U',true)
 local original=assert(load('return function()return GridMask end','@fixture-native','t',owner))()
 local row={id=1,environment='Underground'}
 local observer=make(function()return tick end,kernel)
 local saved=owner.GridMask
 local function clean()
  check(owner.GridMask==saved,'native mask hook leaked')
  for g in pairs(live)do check(borrowed[g],'private native grid leaked')end
  check(live[game_source] and live[dest],'caller grids freed')
 end
 return observer,owner,original,row,game_source,dest,clean,function()return actual end,
  function()return tick end,grid
end
do
 local obs,owner,original,row,src,dest,clean,actual=fixture()
 check(obs.generation_enter(original,{},nil,row),'enter')
 check(obs.procedure_start(row,'FindPrefabPos_Filler',3),'start')
 local requests={1,2,1,3,1,2,4,5,6,7,8,9,10,11,11,11}
 for _,lo in ipairs(requests)do
  local values=table.pack(owner.GridMask(src,dest,lo,2147483647,1))
  check(values.n==6 and values[1]==nil and values[2]=='mask' and values[3]==nil
   and values[4]==src and values[5]==dest and values[6]==nil,'real mask tuple')
  for i,value in ipairs(src.v)do check(dest.v[i]==(value>=lo and 1 or 0),'real output changed')end
 end
 check(actual()==#requests,'extra real source mask call')
 check(obs.procedure_end(row,'FindPrefabPos_Filler',3),'end')
 check(obs.generation_exit(row,true) and obs.restore(),'restore')
 local r=obs.result;local s=r.scopes[1]
 check(r.status=='pass' and r.globals_restored and r.scratch_released,'status')
 check(s.comparator_self_test and s.self_test_cells==24,'comparator self-test')
 check(s.completed and s.hook_restored and s.scratch_released,'scope complete')
 check(#s.requests==16 and s.unique_keys==11 and s.capacity==8 and s.cache_byte_bound<=16777216,'request/cap census')
 check(s.comparisons==68 and s.compared_cells==544 and s.output_comparisons==32 and s.immutable_comparisons==36,'full equality census')
 check(s.shadow_stats.calls==16 and s.shadow_stats.hits==5 and s.shadow_stats.misses==11
  and s.shadow_stats.evictions==3 and s.shadow_stats.live==0,'shadow LRU census')
 check(#s.benchmarks==2 and s.benchmarks[1].order=='old_new' and s.benchmarks[2].order=='new_old','both orders')
 for _,b in ipairs(s.benchmarks)do
  check(b.old_ms>0 and b.new_ms>0 and b.stats.calls==16 and b.stats.hits==5
   and b.stats.live==0 and b.stats.freed==b.stats.clones,'benchmark full cleanup/census')
 end
 clean()
end
for _,mode in ipairs({'source_mutation','bad_copy','clone_alias','private_mask_error','repack_error',
 'bad_comparator','partial_mask','source_changed','unsupported','unfinished'})do
 local obs,owner,original,row,src,dest,clean,actual,tick,grid=fixture(mode)
 check(obs.generation_enter(original,{},nil,row),'failure enter')
 check(obs.procedure_start(row,'FindPrefabPos_Filler',3),'failure start')
 owner.GridMask(src,dest,1,2147483647,1)
 if mode=='source_changed'then
  local other=grid({0,1,2,3,5,8,13,21},'U',true)
  owner.GridMask(other,dest,1,2147483647,1)
 elseif mode=='unsupported'then owner.GridMask(src,dest,1,2147483647,1,9)
 elseif mode=='bad_copy'then owner.GridMask(src,dest,1,2147483647,1)end
 if mode~='unfinished'then check(not obs.procedure_end(row,'FindPrefabPos_Filler',3),'failure accepted '..mode)end
 obs.generation_exit(row,true);obs.restore()
 check(obs.result.status=='fail' and #obs.result.issues>0,'failure not latched '..mode)
 clean()
end
-- Inherited raw slots and unrelated coroutines preserve the native path.
do
 local obs,owner,original,row,src,dest,clean,actual=fixture()
 local inherited={};for k,v in pairs(owner)do inherited[k]=v;owner[k]=nil end
 setmetatable(owner,{__index=inherited})
 check(obs.generation_enter(original,{},nil,row),'inherited enter')
 check(obs.procedure_start(row,'FindPrefabPos_Filler',3),'inherited start')
 owner.GridMask(src,dest,1,2147483647,1)
 local co=coroutine.create(function()owner.GridMask(src,dest,2,2147483647,1)end)
 check(coroutine.resume(co),'other coroutine native call')
 check(#obs.result.scopes[1].requests==1 and actual()==2,'unrelated call captured')
 check(obs.procedure_end(row,'FindPrefabPos_Filler',3),'inherited end')
 check(obs.generation_exit(row,true) and obs.restore(),'inherited restore')
 check(rawget(owner,'GridMask')==nil,'inherited raw slot leaked');clean()
end
-- Restore during an unfinished scope must remove the global hook and scratch too.
do
 local obs,owner,original,row,src,dest,clean=fixture()
 obs.generation_enter(original,{},nil,row);obs.procedure_start(row,'FindPrefabPos_Filler',3)
 owner.GridMask(src,dest,1,2147483647,1)
 check(not obs.restore(),'active restore accepted');clean()
end
-- Full driver composition with the existing native-proc lifecycle guard.
do
 local obs,owner,original,row,src,dest,clean,actual,tick=fixture()
 local class={Generate=function()end,DoGenerate=function()end,OnGenerateLogic=function()end,
  ProcStart=function()end,ProcEnd=function()end}
 local sbm={Config={},State={generator_generate_wrapper=class.Generate,
  generator_do_generate_wrapper=class.DoGenerate,generator_on_generate_logic_wrapper=class.OnGenerateLogic},
  Engine={Global=function()return class end},GenerationGrids={RebuildFinal=function()return true,nil end},
  CallDoGenerateWithRockParityTrace=function(fn,generator,map,...)return fn(generator,map,...)end}
 owner.class=class;owner.src=src;owner.dest=dest
 owner.ModsLoaded={{env={SuperBigMap=sbm}}};owner.GetPreciseTicks=tick;owner.print=function()end
 owner.AsyncFileToString=function(path)local f=assert(io.open(path,'r'));local text=f:read('*a');f:close();return nil,text end
 setmetatable(owner,{__index=_G});owner._G=owner
 local fn=assert(load([[return function(self,map)
  class.ProcStart(self,'FindPrefabPos_Filler');GridMask(src,dest,1,2147483647,1)
  class.ProcEnd(self,'FindPrefabPos_Filler');return nil,17,nil
 end]],'@fixture-shipped','t',owner))()
 check(assert(loadfile('_ralph/tmp/under80_20260912/filler_mask_profile.lua','t',owner))()=='NATIVE_PROC_PROFILE_READY','driver ready')
 check(owner.SBM_NATIVE_PROC_OBSERVER==nil,'observer registration leaked')
 local values=table.pack(sbm.CallDoGenerateWithRockParityTrace(fn,{}, {mapdata={Environment='Underground'}}))
 check(values.n==3 and values[1]==nil and values[2]==17 and values[3]==nil,'driver native tuple')
 sbm.GenerationGrids.RebuildFinal({mapdata={Environment='Surface'}},'post-pipeline scheduled revalidation')
 local r=owner.SBM_NATIVE_PROC_DIAGNOSTIC
 check(r.status=='pass' and r.restored and r.primitive.status=='pass' and r.primitive.scratch_released,'driver final result')
 clean()
end
print('PASS native filler shadow observer: '..checks..' exact-grid/source/tuple/ownership/failure/driver checks')

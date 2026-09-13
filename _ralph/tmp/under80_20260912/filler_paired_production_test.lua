-- Executes the actual marker-delimited production helper, not the private kernel.
local file = assert(io.open('Code/sbm_map_generation.lua', 'r'))
local source = file:read('*a'); file:close()
local block = assert(source:match('%-%- BEGIN NATIVE FILLER MASK CACHE.-%-%- END NATIVE FILLER MASK CACHE%.'))
local checks = 0
local function check(v, why) assert(v, why); checks = checks + 1 end
local function pack(...) return {n=select('#',...),...} end
local function fixture(options)
 options = options or {}
 local env = setmetatable({SuperBigMap={}}, {__index=_G})
 assert(load(block,'actual production filler','t',env))()
 local api, original, grids, borrowed = {}, {}, {}, {}
 local native_calls, fail_free = 0, options.free_error
 local current_place
 local function grid(values, format)
  local g = {values={},format=format or 'U',w=options.width or 768,h=768}
  for i,v in ipairs(values or {0,3,4,5,7,12,30}) do g.values[i]=v end
  grids[g]=true
  function g:size() assert(not self.dead); return self.w,self.h end
  function g:clone()
   assert(not self.dead)
   if options.clone_error then error('clone fault') end
   if options.clone_alias then return self end
   if options.clone_false then return false end
   return grid(self.values,self.format)
  end
  function g:copy(other)
   assert(not self.dead and not other.dead)
   if options.copy_error then self.values[1]=999;error('copy fault') end
   for i,v in ipairs(other.values) do self.values[i]=v end
  end
  function g:free()
   check(not borrowed[self], 'freed borrowed grid')
   check(not self.dead,'double free')
   if fail_free then fail_free=false;error('free fault') end
   self.dead=true
  end
  return g
 end
 api.IsComputeGrid=function(g)return type(g)=='table' and not g.dead and g.format or false end
 api.GridMinMax=function(g)return math.min(table.unpack(g.values)),math.max(table.unpack(g.values))end
 api.GridDest=function(g)local d=grid(g.values);borrowed[d]=true;return d end
 api.GridDistanceMars=function(src,dst,a,b)
  if type(dst)=='table' then for i,v in ipairs(src.values)do dst.values[i]=v end end
  return nil,'distance',nil
 end
 api.GridMask=function(src,dst,lo,hi,scale)
  native_calls=native_calls+1
  if options.mask_error then error('mask fault') end
  if type(dst)~='table' then scale,hi,lo,dst=hi,lo,dst,src end
  if math.type(lo)~='integer' then return nil,'native rejected float',nil end
  for i,v in ipairs(src.values)do dst.values[i]=(v>=lo and v<=hi) and scale or 0 end
  if options.mask_tuple then return nil,dst,nil end
  return dst
 end
 api.GridRepack=function(g)local out=grid(g.values,'f');return out end
 api.GridAddMulDiv=function(a,b,scale)for i,v in ipairs(b.values)do a.values[i]=a.values[i]+v*scale end end
 api.GridAbs=function(g)for i,v in ipairs(g.values)do g.values[i]=math.abs(v)end end
 api.GridCount=function(g,lo,hi)local n=0;for _,v in ipairs(g.values)do if v>=lo and v<=hi then n=n+1 end end;return n end
 for _,name in ipairs({'GridAnd','GridOr','GridNot','GridCircleSet','GridFill','GridMulDivAdd','GridMulAddScaled','GridOpFree'})do
  api[name]=function(g)if g and g.values then g.values[1]=99 end;return nil,'mutation',nil end
 end
 api.GridAnd=function(dst,other)
  if options.and_error then error('And fault') end
  for i,v in ipairs(dst.values)do dst.values[i]=(v~=0 and other.values[i]~=0) and 1 or 0 end
  if options.and_tuple then return nil,dst,nil end
  return dst
 end
 api.GridCircleSet=function(dst,value,center,radius)
  for i in ipairs(dst.values)do if math.abs(i-center)<=radius then dst.values[i]=value end end
  if options.clear_error and not borrowed[dst] then error('clear fault') end
  return nil,'circle',nil
 end
 api.GridOpFree=function(dst)if dst then check(not dst.dead,'free once');dst.dead=true end;return nil,'free',nil end
 for k,v in pairs(api)do original[k]=v end
 local generator, other = {}, {}
 local class={ProcStart=function()return nil,'start',nil end,ProcEnd=function()return nil,'end',nil end}
 local old_start,old_end=class.ProcStart,class.ProcEnd
 local writes=0
 local function write(k,v)
  writes=writes+1
  if options.write_error and writes==3 then error('write fault') end
  if options.write_false and writes==3 then return false end
  if options.restore_false and v==original[k] then return false end
  api[k]=v;return true
 end
 if options.missing then api.GridAbs=nil;original.GridAbs=nil end
 local close,stats=env.SuperBigMap.InstallNativeFillerMaskCache(generator,class,function(k)return api[k]end,write)
 local function enter(who)
  local tuple=pack(class.ProcStart(who or generator,'FindPrefabPos_Filler'))
  check(tuple.n==3 and tuple[1]==nil and tuple[2]=='start' and tuple[3]==nil,'start tuple')
  local place=grid();borrowed[place]=true
  local distance=api.GridDest(place)
  local ret=pack(api.GridDistanceMars(place,distance,1,1))
  check(ret.n==3 and ret[2]=='distance','distance tuple')
  for i in ipairs(place.values)do place.values[i]=1 end
  current_place=place
  return distance,place
 end
 local function apply(src,lo,raw_only)
  local dst=api.GridDest(src)
  local ret=pack(api.GridMask(src,dst,lo,2147483647,1))
  if not raw_only then api.GridAnd(dst,current_place)end
  return dst,ret
 end
 local function leave(who)
  if current_place and not current_place.dead then api.GridOpFree(current_place)end
  local tuple=pack(class.ProcEnd(who or generator,'FindPrefabPos_Filler'))
  check(tuple.n==3 and tuple[2]=='end','end tuple')
 end
 local function clean(expect_failure)
  local good=close()
  check(good==not expect_failure,'cleanup status '..tostring(stats.failure))
  if not options.restore_false and not options.rebind then
   for k,v in pairs(original)do check(api[k]==v,'global restore '..k)end
   check(class.ProcStart==old_start and class.ProcEnd==old_end,'class restore')
  end
  if not options.restore_false then
   for g in pairs(grids)do check(borrowed[g] or g.dead,'scratch leaked')end
  end
  check(stats.live==0,'live scratch remains')
  return stats
 end
 return {api=api,original=original,class=class,generator=generator,other=other,enter=enter,
  apply=apply,leave=leave,clean=clean,close=close,stats=stats,count=function()return native_calls end}
end
do
 local f=fixture();local src=f.enter()
 for i=1,100 do
  local lo=({3,4,5,7,12})[(i-1)%5+1]
  local dst,ret=f.apply(src,lo)
  check(ret.n==1 and ret[1]==dst,'native destination tuple')
  for j,v in ipairs(src.values)do check(dst.values[j]==(v>=lo and 1 or 0),'exact mask')end
  dst.values[1]=555 -- caller changes must not poison the immutable cache
 end
 f.leave();local s=f.clean()
 check(s.hits==95 and s.misses==5 and f.count()==5,'native call reduction')
 check(s.guards==1 and s.place_guards==1 and s.capacity==7 and s.clones==10,'source/place and capacity')
 check(s.and_hits==95 and s.and_misses==5,'And reduction')
 check(s.pair_byte_bound<=33554432 and s.peak<=2*s.capacity+4,'memory bound')
 check(f.close(),'idempotent close')
end
do -- force LRU eviction with more keys than the payload budget
 local f=fixture();local src=f.enter()
 for i=1,90 do f.apply(src,i%9)end
 f.leave();local s=f.clean();check(s.misses==90 and s.hits==0,'LRU eviction')
end
do
 local f=fixture();local src=f.enter();f.apply(src,3)
 local _,ret=f.apply(src,3.0)
 check(ret.n==3 and ret[2]=='native rejected float','float tuple preserved')
 f.apply(src,3);f.leave();local s=f.clean();check(s.hits==0 and s.invalidations==1,'unpaired And after float fallback disables cache')
end
for _,name in ipairs({'GridAnd','GridOr','GridNot','GridCircleSet','GridFill','GridMulDivAdd',
 'GridMulAddScaled','GridOpFree','GridAddMulDiv','GridAbs','GridRepack'})do
 local f=fixture();local src=f.enter();f.apply(src,3)
 if name=='GridAnd' then f.api[name](src,src)
 elseif name=='GridCircleSet' then f.api[name](src,0,2,0)
 elseif name=='GridOpFree' then f.api[name](src);f.leave();local s=f.clean();check(s.invalidations==1,'free invalidation');goto next_mutation
 elseif name=='GridAddMulDiv' then f.api[name](src,src,1)
 elseif name=='GridRepack' then f.api[name](src):free()
 else f.api[name](src)end
 f.apply(src,3);f.leave();local s=f.clean();check(s.hits==0 and s.invalidations==1,'mutation invalidation '..name)
 ::next_mutation::
end
do
 local f=fixture();local src=f.enter();f.apply(src,3)
 f.api.GridMask(src,3,2147483647,1)
 f.apply(src,3);f.leave();local s=f.clean();check(s.invalidations==1,'in-place mask invalidates')
end
do
 local f=fixture();local src=f.enter();f.apply(src,3);src.values[2]=2
 f.leave();local s=f.clean(true);check(s.failure:find('immutable source changed',1,true),'direct mutation certificate')
end
do -- source mutation from a different coroutine must also invalidate
 local f=fixture();local src=f.enter();f.apply(src,3)
 local co=coroutine.create(function()f.api.GridFill(src)end)
 check(coroutine.resume(co),'other thread mutation');f.apply(src,3);f.leave()
 local s=f.clean();check(s.hits==0 and s.invalidations==1,'cross-thread mutation')
end
do
 local f=fixture();local src=f.enter();f.apply(src,3)
 local co=coroutine.create(function()f.apply(src,3)end)
 check(coroutine.resume(co),'other thread pass-through');f.apply(src,3);f.leave()
 local s=f.clean();check(s.hits==0 and f.count()==3 and s.invalidations==1,'cross-thread pair stays native and invalidates')
end
do
 local f=fixture();local src=f.enter(f.other);f.apply(src,3);f.apply(src,3);f.leave(f.other)
 local s=f.clean();check(s.calls==0 and f.count()==2,'generator isolation')
end
for _,kind in ipairs({'clone_error','clone_alias','clone_false','copy_error','mask_error','mask_tuple','free_error'})do
 local f=fixture({[kind]=true});local src=f.enter()
 pcall(f.apply,src,3);pcall(f.apply,src,3)
 f.leave();local s=f.clean(true);check(s.failure~=nil,'failure latch '..kind)
end
for _,kind in ipairs({'write_error','write_false'})do
 local f=fixture({[kind]=true});f.clean(true)
end
do
 local f=fixture({missing=true});local src=f.enter();f.apply(src,3);f.leave()
 local s=f.clean();check(not s.installed and s.calls==0,'unsupported API fallback')
end
do
 local f=fixture({width=4096});local src=f.enter();f.apply(src,3);f.leave()
 local s=f.clean();check(s.calls==0 and f.count()==1,'unsupported dimension fallback')
end
do -- outer cleanup substitutes for missing ProcEnd after native failure
 local f=fixture();local src=f.enter();f.apply(src,3);f.clean()
end
do
 local f=fixture({rebind=true});local src=f.enter();f.apply(src,3)
 local replacement=function()end;f.api.GridMask=replacement
 f.leave();local s=f.clean(true);check(f.api.GridMask==replacement,'do not overwrite unrelated rebound')
end
-- Separate raw and boolean output boundaries, maintained clears, caller trial writes.
do
 local f=fixture();local src,place=f.enter()
 for trial=1,60 do
  local lo=({3,4,5,7,12})[(trial-1)%5+1]
  local dst,ret=f.apply(src,lo,true)
  for i,v in ipairs(src.values)do check(dst.values[i]==(v>=lo and 1 or 0),'raw boundary')end
  if trial%3==0 then
   local tuple=pack(f.api.GridCircleSet(place,0,trial%7+1,0))
   check(tuple.n==3 and tuple[2]=='circle','clear tuple')
  end
  local tuple=pack(f.api.GridAnd(dst,place))
  check(tuple.n==1 and tuple[1]==dst,'And destination tuple')
  for i,v in ipairs(src.values)do check(dst.values[i]==((v>=lo and place.values[i]~=0)and 1 or 0),'eligibility boundary')end
  dst.values[1]=777
 end
 f.leave();local s=f.clean()
 check(s.clears==20 and s.updates>0 and s.and_hits==55,'maintained clear census')
end
do -- A first pending mask is initialized from the post-clear place state.
 local f=fixture();local src,place=f.enter()
 local dst=f.apply(src,3,true);f.api.GridCircleSet(place,0,2,0);f.api.GridAnd(dst,place)
 check(dst.values[2]==0,'first pending clear');f.leave();f.clean()
end
do -- Wrong pairing must leave a complete raw mask for ordinary native fallback.
 local f=fixture();local src,place=f.enter()
 local dst=f.apply(src,3,true);local other=f.api.GridDest(place)
 f.api.GridAnd(dst,other);f.leave();local s=f.clean()
 check(s.and_calls==0 and s.invalidations==1,'abandoned pair')
end
do -- Unsupported place writes invalidate before writing, including cross-thread calls.
 local f=fixture();local src,place=f.enter();f.apply(src,3)
 local co=coroutine.create(function()f.api.GridCircleSet(place,0,2,0)end)
 check(coroutine.resume(co),'cross-thread clear')
 f.apply(src,3);f.leave();local s=f.clean();check(s.hits==0 and s.invalidations==1,'place invalidation')
end
do
 local f=fixture();local src,place=f.enter();f.apply(src,3);place.values[2]=0
 f.leave();local s=f.clean(true);check(s.failure:find('maintained place changed',1,true),'direct place guard before free')
end
for _,kind in ipairs({'and_error','and_tuple','clear_error'})do
 local f=fixture({[kind]=true});local src,place=f.enter()
 pcall(f.apply,src,3)
 if kind=='clear_error'then pcall(f.api.GridCircleSet,place,0,2,0)end
 f.leave();local s=f.clean(true);check(s.failure~=nil,'paired fault '..kind)
end
print('PASS '..checks..' actual-production paired filler fixture checks')

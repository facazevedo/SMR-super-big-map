local make=assert(loadfile('_ralph/tmp/under80_20260912/filler_mask_cache.lua'))()
local checks=0
local function check(v,m)assert(v,m);checks=checks+1 end
local function fixture(mode)
 local source={0,1,2,3,4,5,10,31,255,65535}
 local live={};local mask_calls=0
 local source_text=table.concat(source,',')
 local function mask(src,dst,lo,hi,scale)
  mask_calls=mask_calls+1
  if mode=='mask_error'then error('fixture mask')end
  for i=1,#src do dst[i]=(src[i]>=lo and src[i]<=hi) and scale or 0 end
 end
 local function copy(dst,src)
  if mode=='copy_error'then error('fixture copy')end
  for i=1,#src do dst[i]=src[i]end
 end
 local fail_free_once=mode=='free_error'
 local api={mask=mask,copy=copy,
  clone=function(dst)
   if mode=='clone_error'then error('fixture clone')end
   if mode=='clone_nil'then return nil end
   if mode=='clone_false'then return false end
   if mode=='clone_alias'then return dst end
   local out={};for i=1,#dst do out[i]=dst[i]end;live[out]=true;return out
  end,
  free=function(grid)
   if fail_free_once then fail_free_once=false;error('fixture free')end
   check(live[grid]==true,'free borrowed or already-freed grid')
   live[grid]=nil
  end}
 local function clean()
  check(next(live)==nil,'owned masks leaked')
  check(table.concat(source,',')==source_text,'mutated source')
 end
 return api,source,clean,function()return mask_calls end
end
for capacity=0,8 do
 local api,source,clean=fixture()
 local cache=assert(make(api,source,capacity))
 local dest,expected={},{}
 for i=1,300 do
  local lo=(i*17)%13/2;local hi=(i%3==0) and 31 or 65535;local scale=(i%5==0) and 7 or 1
  for j=1,#source do dest[j]=-100 end
  check(cache.apply(dest,lo,hi,scale),'private apply')
  -- Independent integer-mask oracle; no cache/API implementation reuse.
  for j,value in ipairs(source)do
   expected[j]=(value>=lo and value<=hi) and scale or 0
   check(dest[j]==expected[j],'mask mismatch')
  end
  check(cache.stats.live<=capacity and cache.stats.peak<=capacity,'capacity exceeded')
  -- Subsequent caller mutation must not poison cached results.
  dest[1]=1234
 end
 check(cache.stats.calls==300 and cache.stats.masks==cache.stats.misses,'call census')
 check(cache.stats.hits+cache.stats.misses==300,'hit/miss census')
 check(cache.close(),'normal close');check(cache.close(),'idempotent close')
 check(cache.stats.live==0 and cache.stats.freed==cache.stats.clones,'ownership census')
 clean()
end
do
 local api,source,clean,count=fixture()
 local c=assert(make(api,source,2));local d={}
 for _,lo in ipairs({1,2,1,3,1,2})do check(c.apply(d,lo,65535,1),'LRU apply')end
 check(c.stats.hits==2 and c.stats.misses==4 and c.stats.evictions==2 and count()==4,'LRU trace')
 check(c.close(),'LRU close');clean()
 check(not c.apply(d,1,2,1),'closed cache used')
end
for _,mode in ipairs({'mask_error','copy_error','clone_error','clone_nil','clone_false','clone_alias','free_error'})do
 local api,source,clean=fixture(mode)
 local c=assert(make(api,source,1));local d={}
 if mode=='copy_error'then check(c.apply(d,1,2,1),'copy fixture prime');check(not c.apply(d,1,2,1),'copy exception ignored')
 elseif mode=='free_error'then
  check(c.apply(d,1,2,1),'free fixture prime');check(not c.apply(d,2,3,1),'free exception ignored')
  check(c.stats.live==1,'lost ownership on failed free')
 else check(not c.apply(d,1,2,1),'failure ignored '..mode)end
 check(not c.close(),'failure latch lost')
 clean()
end
do
 local api,source,clean,count=fixture();local c=assert(make(api,source,4));local d={}
 check(c.apply(d,1.5,31,7),'full-write prime')
 for i=1,#source do d[i]=-999 end
 check(c.apply(d,1.5,31,7),'full-write hit')
 for i,value in ipairs(source)do check(d[i]==((value>=1.5 and value<=31) and 7 or 0),'hit did not fully overwrite')end
 check(count()==1 and c.stats.hits==1,'hit recomputed mask')
 check(c.apply(d,1.5,31,1) and c.apply(d,1.5,255,1),'complete parameter key')
 check(count()==3,'scale/to key conflated')
 check(c.close(),'full-write close');clean()
end
for _,bad in ipairs({-1,33,0.5,math.huge})do
 local api,source=fixture();check(make(api,source,bad)==nil,'invalid capacity')
end
do
 local api,source,clean=fixture();local c=assert(make(api,source,1))
 check(not c.apply(source,0,1,1),'source alias accepted');c.close();clean()
end
print('PASS private immutable filler mask cache: '..checks..' output/LRU/bounds/ownership/error checks')

local make=dofile('_ralph/tmp/under80_20260912/filler_paired_cache.lua')
local checks=0
local function check(v,m)assert(v,m);checks=checks+1 end
local function copy(g)local c={};for k,v in pairs(g)do c[k]=v end;return c end
local function equal(a,b)for i=1,#a do if a[i]~=b[i]then return false end end;return #a==#b end
local function mask(s,d,lo,hi,scale)for i,v in ipairs(s)do d[i]=v>=lo and v<=hi and scale or 0 end;return d end
local function intersect(a,b)for i,v in ipairs(a)do a[i]=v~=0 and b[i]~=0 and 1 or 0 end;return a end
local function clear(g,value,p,r)for i=1,#g do if math.abs(i-p.x)<=r then g[i]=value end end end
local function fixture(capacity,mode)
 local src,place={},{};for i=1,41 do src[i]=i%17;place[i]=({0,1,2,65535})[i%4+1]end
 local owned={};local clones=0;local failing=false
 local api={mask=mask,intersect=intersect,clear=clear,
  copy=function(d,s)if failing and (mode=='raw_copy' or mode=='eligible_copy')then error('copy')end;for i,v in ipairs(s)do d[i]=v end end,
  clone=function(g)
   clones=clones+1
   if mode=='raw_alias' or mode=='eligible_alias' and clones==2 then return g end
   if failing and mode=='clone_error'then error('clone')end
   local c=copy(g);owned[c]=true;return c
  end,
  free=function(g)if failing and mode=='free_retry'then error('free')end;check(owned[g] and g~=src and g~=place,'owned free');owned[g]=nil end}
 local cache=assert(make(api,src,place,capacity))
 return cache,api,src,place,owned,function(value)failing=value end
end
for _,capacity in ipairs({0,1,2,3,5,7})do
 local cache,api,src,place,owned=fixture(capacity)
 local source_guard=copy(src)
 for i=1,240 do
  local lo=({3,4,5,7,12})[i%5+1];local dst={}
  local raw={};mask(src,raw,lo,2147483647,1)
  check(cache.mask(dst,lo,2147483647,1),'raw request')
  check(equal(dst,raw),'mask boundary is complete RAW mask')
  if i%7==0 then
   clear(place,0,{x=i%47-3},2.5);local guard=copy(place)
   check(cache.clear(0,{x=i%47-3},2.5),'clear while pair pending')
   check(equal(place,guard),'never mutate caller place')
   check(equal(dst,raw),'pending destination stays raw after clear')
  end
  local expected=copy(raw);intersect(expected,place)
  check(cache.intersect(dst,place),'And request')
  check(equal(dst,expected),'And boundary is current eligibility')
  for j=1,#dst do dst[j]=13 end
  if i%3==0 then clear(place,0,{x=i%47-3},1.5);check(cache.clear(0,{x=i%47-3},1.5),'later clear')end
  check(equal(src,source_guard),'source immutable')
  check(cache.stats.live<=2*capacity,'pair allocation bound')
 end
 check(cache.close() and not next(owned),'all pairs freed')
 check(cache.stats.clones==cache.stats.freed and cache.stats.live==0,'ownership counters')
 check(not cache.mask({},3,2147483647,1) and not cache.intersect({},place),'closed operations')
end
for _,mode in ipairs({'raw_alias','eligible_alias','raw_copy','eligible_copy','mask_error','and_error','clear_error','clone_error',
 'free_retry','pending_close','second_mask','wrong_and','source_alias','float_key','invalidate'})do
 local cache,api,src,place,owned,set_fail=fixture(2,mode);local dst={}
 local ok=cache.mask(dst,3,2147483647,1)
 if mode=='raw_alias'then check(not ok,'raw clone alias refused')
 elseif mode=='pending_close'then check(not cache.close(),'incomplete pair cleanup')
 elseif mode=='second_mask'then check(not cache.mask({},4,2147483647,1),'second pending mask refused')
 elseif mode=='wrong_and'then check(not cache.intersect({},place),'wrong destination refused')
 else
  check(ok,'first mask')
  ok=cache.intersect(dst,place)
  if mode=='eligible_alias'then check(not ok,'second clone alias refused')
  else
   check(ok,'first And')
   if mode=='raw_copy'then set_fail(true);ok=cache.mask(dst,3,2147483647,1)
   elseif mode=='eligible_copy'then check(cache.mask(dst,3,2147483647,1),'raw hit before failure');set_fail(true);ok=cache.intersect(dst,place)
   elseif mode=='mask_error'then api.mask=function()error('mask')end;ok=cache.mask(dst,4,2147483647,1)
   elseif mode=='and_error'then check(cache.mask(dst,4,2147483647,1),'raw miss');api.intersect=function()error('and')end;ok=cache.intersect(dst,place)
   elseif mode=='clear_error'then api.clear=function()error('clear')end;ok=cache.clear(0,{x=1},2)
   elseif mode=='clone_error'then set_fail(true);ok=cache.mask(dst,4,2147483647,1)
   elseif mode=='free_retry'then set_fail(true);ok=cache.close();check(next(owned)~=nil,'retain failed frees')
   elseif mode=='source_alias'then ok=cache.mask(src,3,2147483647,1)
   elseif mode=='float_key'then ok=cache.mask(dst,3.0,2147483647,1)
   elseif mode=='invalidate'then cache.invalidate('source changed');ok=cache.mask(dst,3,2147483647,1)end
   check(not ok,'failure propagated '..mode)
  end
 end
 set_fail(false);cache.close();check(not next(owned),'failed-pair owned cleanup '..mode)
 check(not cache.mask({},3,2147483647,1),'failure latched '..mode)
end
print('PASS '..checks..' paired raw/And boundary, mutation, ownership and failure checks')

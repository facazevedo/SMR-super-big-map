local make=dofile('_ralph/tmp/under80_20260912/filler_eligibility_cache.lua')
local checks=0
local function check(v,m)assert(v,m);checks=checks+1 end
local function grid(w,h,fn)
 local g={w=w,h=h};for y=0,h-1 do for x=0,w-1 do g[y*w+x+1]=fn and fn(x,y) or 0 end end;return g
end
local function equal(a,b)
 if a.w~=b.w or a.h~=b.h then return false end
 for i=1,a.w*a.h do if a[i]~=b[i]then return false end end;return true
end
local function copy(g)local c={};for k,v in pairs(g)do c[k]=v end;return c end
local function mask(s,d,lo,hi,scale)for i=1,s.w*s.h do d[i]=s[i]>=lo and s[i]<=hi and scale or 0 end;return d end
-- Native GridAnd is boolean conjunction, not integer bitwise AND (contract probe).
local function intersect(a,b)for i=1,a.w*a.h do a[i]=a[i]~=0 and b[i]~=0 and 1 or 0 end;return a end
local function circle(g,value,p,r)
 for y=0,g.h-1 do for x=0,g.w-1 do
  if (x-p.x)^2+(y-p.y)^2<=r*r then g[y*g.w+x+1]=value end
 end end
end
for _,capacity in ipairs({0,1,2,5,8})do
 for _,shape in ipairs({{7,9},{16,13},{1,1}})do
  local w,h=table.unpack(shape)
  local source=grid(w,h,function(x,y)return (x*13+y*7)%19 end)
  local source_guard=copy(source)
  local place=grid(w,h,function(x,y)return ({0,1,2,3,65534,65535})[(x+y)%6+1] end)
  local owned={};local live=0
  local api={mask=mask,intersect=intersect,clear=circle,copy=function(d,s)for i=1,s.w*s.h do d[i]=s[i]end end,
   clone=function(g)local c=copy(g);owned[c]=true;live=live+1;return c end,
   free=function(g)check(owned[g] and g~=source and g~=place,'free only owned');owned[g]=nil;live=live-1 end}
  local cache=assert(make(api,source,place,capacity))
  for i=1,150 do
   if i%3==0 then
    local p={x=(i*11)%(w+6)-3,y=(i*7)%(h+6)-3};local r=i%6+0.5
    circle(place,0,p,r);local frozen=copy(place)
    check(cache.clear(0,p,r),'clear update')
    check(equal(place,frozen),'kernel never clears caller place')
   else
    local lo=({3,4,5,7,12})[i%5+1]
    local expected=grid(w,h);mask(source,expected,lo,2147483647,1);intersect(expected,place)
    local actual=grid(w,h,function()return 7 end)
    check(cache.apply(actual,lo,2147483647,1),'request')
    check(equal(actual,expected),'complete mask AND current place')
    -- Later zone/similarity/trial writes cannot contaminate cached eligibility.
    for j=1,w*h do actual[j]=91 end
    check(equal(source,source_guard),'fixed source untouched')
   end
   check(cache.stats.live<=capacity and live==cache.stats.live,'bounded ownership')
  end
  check(cache.close() and live==0 and not next(owned),'complete cleanup')
  check(not cache.apply(grid(w,h),3,2147483647,1),'closed apply refused')
  check(not cache.clear(0,{x=0,y=0},1),'closed clear refused')
 end
end
for _,mode in ipairs({'invalidate','source_alias','place_alias','clone_alias','copy_error','mask_error','and_error','clear_error','free_retry','float_key','nonzero_clear'})do
 local source=grid(4,4,function()return 10 end);local place=grid(4,4,function()return 1 end)
 local owned={};local failing=false
 local api={mask=mask,intersect=intersect,clear=circle,
  copy=function(d,s)if mode=='copy_error' and failing then error('copy')end;for i=1,16 do d[i]=s[i]end end,
  clone=function(g)if mode=='clone_alias'then return g end;local c=copy(g);owned[c]=true;return c end,
  free=function(g)if mode=='free_retry' and failing then error('free')end;check(owned[g],'failure cleanup ownership');owned[g]=nil end}
 local cache=assert(make(api,source,place,2));local dest=grid(4,4)
 local ok=cache.apply(dest,3,2147483647,1)
 if mode=='clone_alias'then check(not ok,'clone alias refused')
 else
  check(ok,'initial request');failing=true
  if mode=='invalidate'then cache.invalidate('source changed');ok=cache.apply(dest,3,2147483647,1)
  elseif mode=='source_alias'then ok=cache.apply(source,3,2147483647,1)
  elseif mode=='place_alias'then ok=cache.apply(place,3,2147483647,1)
  elseif mode=='float_key'then ok=cache.apply(dest,3.0,2147483647,1)
  elseif mode=='nonzero_clear'then ok=cache.clear(1,{x=0,y=0},1)
  elseif mode=='copy_error'then ok=cache.apply(dest,3,2147483647,1)
  elseif mode=='mask_error'then api.mask=function()error('mask')end;ok=cache.apply(dest,4,2147483647,1)
  elseif mode=='and_error'then api.intersect=function()error('and')end;ok=cache.apply(dest,4,2147483647,1)
  elseif mode=='clear_error'then api.clear=function()error('clear')end;ok=cache.clear(0,{x=0,y=0},1)
  elseif mode=='free_retry'then ok=cache.close();check(next(owned)~=nil,'failed free retains ownership')end
  check(not ok,'operation failure propagated '..mode)
 end
 failing=false;cache.close();check(not next(owned),'failed kernel cleanup '..mode)
 check(not cache.apply(dest,3,2147483647,1),'failure stays latched '..mode)
end
check(not make({},nil,nil,0),'invalid constructor')
print('PASS '..checks..' mutation-aware eligibility kernel checks')

-- Independent exhaustive/accepted/candidate query comparisons.
return function(old,candidate)
local checks=0
local function oracle(list,x,y,r)
 for i=1,#list do
  local c=list[i];local dx,dy=x-c.x,y-c.y;local reach=r+c.r
  if dx*dx+dy*dy<reach*reach then return true end
 end
 return false
end
local function check(list,x,y,r)
 local a,b,c=old(list,x,y,r),candidate(list,x,y,r),oracle(list,x,y,r)
 assert(a==b and b==c,('hint differs at %.17g %.17g %.17g'):format(x,y,r))
 checks=checks+1
end
for _,center in ipairs({-32768,-16384,-0.5,0,0.5,16384,32768})do
 local list={{x=center,y=center,r=8192}}
 for repeat_index=1,40 do
  for _,delta in ipairs({-2,-1,-0.001,0,0.001,1,2})do
   for _,r in ipairs({0,1,8192,32768})do
    check(list,center+8192+r+delta,center,r)
    check(list,center,center-8192-r+delta,r)
   end
  end
 end
end
local state=71
local function rand(n)state=(state*16807)%2147483647;return state%n end
local list={}
for batch=1,12 do
 for i=1,40 do list[#list+1]={x=rand(1600000)-800000+0.25,y=rand(1600000)-800000-0.25,r=rand(50000)}end
 for i=1,4000 do check(list,rand(1800000)-900000,rand(1800000)-900000,({0,1,8192,11000.25,32768})[i%5+1])end
end
local a,b={},{}
for i=1,40 do check(a,17,29,1);check(b,17,29,1)end
a[#a+1]={x=17,y=29,r=8192}
for i=1,40 do check(a,17+i,29,1);check(b,17+i,29,1)end
assert(a.hit_hint_cache.hits>0 and b.hit_hint_cache.hits==0,'positive hint/lifetime not exercised')
-- The last-hit circle remains private and immutable; appends must still be indexed
-- on the first hint miss, including after many early positive returns.
a[#a+1]={x=40000,y=0,r=20}
check(a,40000,0,1)
check(a,40040,0,1)
assert(a.spatial_index.count==2,'append lost while hint bypassed indexing')
for _,center in ipairs({-67108864,67108864})do
 local edge={{x=center,y=0,r=8192}}
 for i=1,40 do check(edge,center,0,1)end
 for _,dx in ipairs({-0.000001,0,0.000001})do check(edge,center+8193+dx,0,1)end
end
local fallback={{x=67108865,y=0,r=1}}
for i=1,40 do check(fallback,67108865,0,1)end
assert(fallback.hit_hint_cache.hits==0,'unsupported domain used hint')
-- Negative query radii retain the accepted indexed behavior, even where its
-- geometric domain is not equivalent to the exhaustive positive-radius oracle.
for i=1,40 do assert(candidate(a,0,0,-8192)==old(a,0,0,-8192))end
local capacity={{x=0,y=0,r=1000000}}
for i=1,40 do check(capacity,0,0,1)end
capacity.hit_hint_cache.slots=32768
check(capacity,40000,40000,1)
assert(capacity.hit_hint_cache.slots==32768,'storage bound exceeded')
assert(not (capacity.hit_hint_cache.rows[9] and capacity.hit_hint_cache.rows[9][9]),'full cache grew')
assert(list.hit_hint_cache.hits>0 and list.hit_hint_cache.index_queries>0)
print('PASS '..checks..' old/hint/exhaustive comparisons; hint hits '..list.hit_hint_cache.hits
 ..'; appends, boundaries, storage limit and unsupported numeric domains')
end

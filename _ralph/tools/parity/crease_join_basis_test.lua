-- Exact join oracle, including limited opposing tangents and reused widths.
local pipe=assert(io.popen('git show 8342ab2:Code/sbm_terrain_copy.lua','r'))
local old_source=pipe:read('*a');assert(pipe:close())
local f=assert(io.open(arg[1] or 'Code/sbm_terrain_copy.lua','r'))
local new_source=f:read('*a');f:close()
local checks=0
local function check(ok,why)assert(ok,why);checks=checks+1 end
local function module(source)
 local body=source:match('(local join_basis_cache = {}.-)\n\tlocal function offer_candidate')
  or assert(source:match('(local function feather_join.-)\n\tlocal function offer_candidate'))
 local cells,reads,writes={},0,0
 local env=setmetatable({at=function(axis,p,along)reads=reads+1;return cells[p]end,
  put=function(axis,p,along,v)writes=writes+1;cells[p]=v end},{__index=_G})
 local join,cache=assert(load(body..'\nreturn feather_join, join_basis_cache','join oracle','t',env))()
 return {join=join,cache=cache,cells=cells,counts=function()return reads,writes end}
end
local a,b=module(old_source),module(new_source)
check(type(b.cache)=='table','production does not reuse exact join coefficients')
local saved={}
for repeat_index=1,20 do
 for span=1,96 do
  local lo=7;local hi=lo+span
  local z0=(span*293+repeat_index*523)%65536
  local z1=(span*701+repeat_index*313)%65536
  for _,m in ipairs({a,b})do
   m.cells[lo]=z0;m.cells[hi]=z1
   m.cells[lo-1]=(z0+repeat_index*7919)%65536
   m.cells[hi+1]=(z1-repeat_index*3571)%65536
   for p=lo+1,hi-1 do m.cells[p]=-1 end
  end
  local axis=repeat_index%2==0 and 'x' or 'y'
  local ca=a.join(axis,repeat_index,lo,hi);local cb=b.join(axis,repeat_index,lo,hi)
  check(ca==cb,'join write count changed')
  for p=lo-1,hi+1 do check(a.cells[p]==b.cells[p],'join height/rounding changed')end
  if span>=4 then
   if saved[span]then check(saved[span]==b.cache[span],'same-width coefficients were rebuilt')
   else saved[span]=b.cache[span]end
  end
 end
end
local ar,aw=a.counts();local br,bw=b.counts()
check(ar==br and aw==bw,'join terrain access order/count changed')
print('crease join basis: '..checks..' checks; exact coefficients reused for 93 widths')

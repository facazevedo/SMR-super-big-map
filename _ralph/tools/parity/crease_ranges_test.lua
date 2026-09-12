-- Actual old rolling scan and row-offer logic; compare singleton calls to ranges.
local f=assert(io.open(arg[1] or 'Code/sbm_terrain_copy.lua','r'))
local source=f:read('*a');f:close()
local a=assert(source:find('\tlocal function offer_candidate(',1,true))
local b=assert(source:find('\tlocal function collect_axis(',a,true))
local body=source:sub(a,b-1)
local old=assert(io.popen('git show c4d3e67:Code/sbm_terrain_copy.lua','r'))
local previous=old:read('*a');assert(old:close())
local pa=assert(previous:find('\tlocal function offer_candidate(',1,true))
local pb=assert(previous:find('\tlocal function collect_axis(',pa,true))
local previous_body=previous:sub(pa,pb-1)
local checks,old_reads,new_reads,old_calls,new_calls=0,0,0,0,0
local function same(a,b)
 checks=checks+1;assert(type(a)==type(b),'type changed')
 if type(a)=='table' then
  for k,v in pairs(a)do same(v,b[k])end
  for k in pairs(b)do assert(a[k]~=nil,'extra field')end
 else assert(a==b,'value changed')end
end
local function compile(wide,pattern,baseline)
 local accessed,reads={},0
 local env={wide_ring_only=wide,threshold=128,max_per_row=6}
 env.at=function(axis,p,along)
  reads=reads+1;accessed[axis..':'..p..':'..along]=true
  if p<0 or p>65 or (pattern==4 and p%13==0)then return nil end
  if pattern==1 then return p>=30 and 14000 or 10000 end
  if pattern==2 then return p>=30 and 10000 or 14000 end
  if pattern==3 then return 10000+p*400 end
  if pattern==5 then return (p%5)*1000 end
  if pattern==6 then return p%7<3 and 65535 or 0 end
  return (p*p*137+p*along*31)%65536
 end
 setmetatable(env,{__index=_G})
 local compiled=(baseline and previous_body or body)..(baseline
  and '\nreturn scan_line_range' or '\nreturn scan_line_range,scan_indexed_ranges')
 local scan,ranges=assert(load(compiled,'@crease-ranges','t',env))()
 return scan,ranges,accessed,function()return reads end,env
end
local sets={{},{1},{1,2},{1,2,3,7,8,10,16,17,18,19,40,60,61,62,63},
 {2,4,6,8,10,12,14},{8,9,9,10,3,4}} -- duplicate/descending still preserve offers
for mask=0,255 do
 local row={}
 for bit=0,7 do if math.floor(mask/2^bit)%2==1 then row[#row+1]=25+bit end end
 sets[#sets+1]=row
end
local full={};for p=1,63 do full[#full+1]=p end;sets[#sets+1]=full
for _,wide in ipairs({false,true})do for pattern=1,7 do
 for _,edge in ipairs({'left','right','top','bottom'})do
  local axis=(edge=='left' or edge=='right')and'x'or'y'
  for _,positions in ipairs(sets)do
   local scan,_,seen_old,count_old,old_env=compile(wide,pattern,true)
   local _,ranges,seen_new,count_new,new_env=compile(wide,pattern)
   local before,after={},{}
   for _,p in ipairs(positions)do scan(before,axis,7,p,p,edge);old_calls=old_calls+1 end
   ranges(after,axis,7,positions,edge)
   local last
   for _,p in ipairs(positions)do if not last or p~=last+1 then new_calls=new_calls+1 end;last=p end
   same(before,after);same(seen_old,seen_new)
   assert(count_new()<=count_old(),'more native reads')
   old_reads=old_reads+count_old();new_reads=new_reads+count_new()
   -- New invocations observe changed terrain; no samples escape a scan call.
   old_env.at=function()return 0 end;new_env.at=old_env.at
   local flat_old,flat_new={},{}
   for _,p in ipairs(positions)do scan(flat_old,axis,7,p,p,edge)end
   ranges(flat_new,axis,7,positions,edge);same(flat_old,flat_new);assert(#flat_new==0)
   local empty={};ranges(empty,axis,7,nil,edge);assert(#empty==0)
  end
 end
end end
assert(new_reads<old_reads and new_calls<old_calls)
print('PASS crease ranges: '..checks..' exact offers/read-coordinate checks; reads '
 ..old_reads..' -> '..new_reads..', scan calls '..old_calls..' -> '..new_calls)

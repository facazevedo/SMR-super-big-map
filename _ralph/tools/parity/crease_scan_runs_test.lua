-- Compare complete actual collect_axis implementations, not just scan samples.
local function read(path)
 local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s
end
local p=assert(io.popen('git show f4d1da6:Code/sbm_terrain_copy.lua','r'))
local previous=p:read('*a');assert(p:close())
local sources={previous,read('Code/sbm_terrain_copy.lua')}
local function body(s)
 local a=assert(s:find('\tlocal function offer_candidate(',1,true))
 local b=assert(s:find('\tlocal function refine_step(',a,true))
 return s:sub(a,b-1)
end
local function compile(s)
 return assert(load([[return function(at,wide_ring_only,threshold,BuildHeightStepDiscoveryIndex)
 local math,type,ipairs,pairs,table=math,type,ipairs,pairs,table
 local max_per_row,max_row_gap=6,4
 local tracks,track_counts={}, {left=0,right=0,top=0,bottom=0}
 local discovery_api,grid={},{}
 local discovery_error
 local discovery_stats={candidates=0,cells=0,copies=0,sampled_rows=0,enumerated=0}
 local domains={}
 local refinement_guide=not wide_ring_only and {RegisterDomain=function(...)
  domains[#domains+1]={...}
 end} or nil
 ]]..body(s)..[[
 return collect_axis,tracks,track_counts,discovery_stats,domains
 end]],'actual collect_axis'))()
end
local old,new=compile(sources[1]),compile(sources[2])
local checks,old_reads,new_reads=0,0,0
local function equal(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end
 return true
end
local function check(ok,why)assert(ok,why);checks=checks+1 end
for case=1,640 do
 local wide=case%2==0
 local step=wide and 8 or 1
 local threshold=case%3==0 and 256 or 128
 local function fixture(label)
  local accessed={}
  local function at(axis,p,along)
   if label=='old' then old_reads=old_reads+1 else new_reads=new_reads+1 end
   local key=axis..':'..p..':'..along;accessed[key]=true
   if case%11==0 and p%13==0 then return nil end
   local v=15000+((p*17+along*7+case)%9)*12
   local boundary=10+(math.floor(along/4)+case)%7
   if p>=boundary then v=v+((case%3)-1)*1000 end
   if p>=45+(case%9) then v=v+(case%2==0 and 1700 or -1700) end
   if case%7==0 then v=v+p*200 end
   if case%13==0 then v=p%4<2 and 0 or 65535 end
   return v
  end
  local function native(api,grid,axis,lo,hi,along_n,sample_step,max_width,t)
   local rows={};local count=0
   for along=0,along_n-1,sample_step do
    local row={}
    for p=lo,hi do
     if case%5==0 or (p+along+case)%11<case%9+1 then row[#row+1]=p;count=count+1 end
    end
    if #row>0 then rows[along]=row end
   end
   return rows,{candidates=count,cells=(hi-lo+1)*along_n,copies=1,sampled_rows=along_n,enumerated=count}
  end
  local fn,tracks,counts,stats,domains=(label=='old' and old or new)(at,wide,threshold,native)
  fn('x',64,48,'left','right',1,27,35,59,step)
  fn('y',64,48,'top','bottom',1,27,35,59,step)
  return {tracks,counts,stats,domains},accessed
 end
 local a,aa=fixture('old');local b,bb=fixture('new')
 check(equal(a,b),'complete track/point/order/domain/census changed in case '..case)
 check(equal(aa,bb),'height read coordinate union changed in case '..case)
end
check(new_reads<old_reads*0.6,'contiguous discovery did not remove expected reads')
-- Both native-index calls must finish before any scalar scan/domain/track work.
-- Retain missing/error behavior for first and second discovery failures.
for _,failure in ipairs({1,2}) do for _,throws in ipairs({false,true}) do
 local outputs={}
 for variant,factory in ipairs({old,new}) do
  local calls,reads=0,0
  local function native()
   calls=calls+1
   if calls==failure then
    if throws then error('injected discovery error') end
    return nil,'injected discovery failure'
   end
   return {[0]={2,3,4}},{candidates=3,cells=12,copies=1,sampled_rows=1,enumerated=3}
  end
  local fn,tracks,counts,stats,domains=factory(function()reads=reads+1;return 1234 end,false,128,native)
  local ok=pcall(fn,'x',64,48,'left','right',1,27,35,59,1)
  check(ok==not throws,'native discovery error propagation changed')
  check(reads==0 and #tracks==0 and #domains==0,'failed discovery entered scalar scan')
  outputs[variant]={tracks,counts,stats,domains}
 end
 check(equal(outputs[1],outputs[2]),'failure left different discovery/track state')
end end
print(('PASS: %d full-track checks; native height reads %d -> %d'):format(checks,old_reads,new_reads))

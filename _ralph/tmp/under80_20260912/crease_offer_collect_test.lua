-- Whole actual collect_axis versus v987: complete tracks, points, ordering,
-- domains and counters. No refinement certificate consumption is permitted.
local path=arg[1] or '_ralph/runs/under80-20260912/artifacts/crease_offer_research_2/sbm_terrain_copy.lua'
local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local sources={read('Code/sbm_terrain_copy.lua'),read(path)}
local function compile(s)
 local a=assert(s:find('\tlocal function offer_candidate(',1,true))
 local b=assert(s:find('\tlocal function refine_step(',a,true))
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
 ]]..s:sub(a,b-1)..[[
 return collect_axis,tracks,track_counts,discovery_stats,domains,function()return discovery_error end
 end]],'actual offer collect_axis'))()
end
local factories={compile(sources[1]),compile(sources[2])}
local checks,reads={0},{0,0}
local function same(a,b)
 if type(a)~=type(b)then return false end
 if type(a)~='table'then return a==b end
 for k,v in pairs(a)do if not same(v,b[k])then return false end end
 for k in pairs(b)do if a[k]==nil then return false end end
 return true
end
local function check(ok,why)assert(ok,why);checks[1]=checks[1]+1 end
for case=1,240 do
 local outputs,boundary_reads={},{}
 local wide=case%2==0
 local threshold=case%3==0 and 256 or 128
 local step=wide and 8 or 1
 for variant,factory in ipairs(factories)do
  local boundaries={}
  local function height(axis,p,a)
   if p<0 or p>=64 then return case%2==0 and nil or 65535 end
   local v=15000+((p*17+a*7+case)%9)*12
   local boundary=10+(math.floor(a/4)+case)%7
   if p>=boundary then v=v+((case%3)-1)*1000 end
   if p>=45+case%9 then v=v+(case%2==0 and 1700 or -1700)end
   if case%7==0 then v=v+p*200 end
   if case%13==0 then v=p%4<2 and 0 or 65535 end
   if case%17==0 then v=(p+a+case)%5<3 and 0 or 65535 end
   return v
  end
  local function at(axis,p,a)
   reads[variant]=reads[variant]+1
   if p>=59 then local key=axis..':'..p..':'..a;boundaries[key]=(boundaries[key]or 0)+1 end
   return height(axis,p,a)
  end
  local function native(api,grid,axis,lo,hi,an,ss,mw,t)
   local rows,offers,count,candidates={},{},0,0
   for width=1,mw do offers[width]={}end
   for along=0,an-1,ss do
    for p=lo,hi do
     local any=false
     for width=1,mw do
      if p+width+1<64 then
       local v0,a,b,v3=height(axis,p-1,along),height(axis,p,along),height(axis,p+width,along),height(axis,p+width+1,along)
       local delta=b-a
       if math.abs(delta)>=t and math.abs(delta)>=2*math.max(math.abs(a-v0),math.abs(v3-b),1)then
        offers[width][along]=offers[width][along] or {}
        offers[width][along][p]=delta
        count=count+1;any=true
       end
      end
     end
     if any then
      rows[along]=rows[along]or {};rows[along][#rows[along]+1]=p;candidates=candidates+1
     end
    end
   end
   return rows,{candidates=candidates,cells=(hi-lo+1)*an,copies=1,sampled_rows=an,enumerated=count},offers
  end
  local fn,tracks,counts,stats,domains,error_value=factory(at,wide,threshold,native)
  fn('x',64,48,'left','right',1,27,35,61,step)
  fn('y',64,48,'top','bottom',1,27,35,61,step)
  outputs[variant]={tracks,counts,stats,domains,error_value()}
  boundary_reads[variant]=boundaries
 end
 check(same(outputs[1],outputs[2]),'full track/domain/census differs case '..case)
 -- New certified reads can disappear, but every potentially out-of-bounds
 -- read from the original boundary scanner must remain in the same multiplicity.
 for key,count in pairs(boundary_reads[1])do
  local p=tonumber(key:match('^[^:]+:(%d+):'))
  if p>=64 then check(boundary_reads[2][key]==count,'boundary read changed '..key)end
 end
end
check(reads[2]<reads[1]/2,'collection did not remove repeated native height reads')
for _,failure in ipairs({1,2})do for _,throws in ipairs({false,true})do
 local outputs={}
 for variant,factory in ipairs(factories)do
  local calls,nreads=0,0
  local function native()
   calls=calls+1
   if calls==failure then if throws then error('injected')end;return nil,'injected' end
   return {[0]={2,3}},{candidates=2,cells=12,copies=1,sampled_rows=1,enumerated=2},{}
  end
  local fn,tracks,counts,stats,domains,error_value=factory(function()nreads=nreads+1;return 1234 end,false,128,native)
  local ok=pcall(fn,'x',64,48,'left','right',1,27,35,61,1)
  check(ok==not throws,'discovery failure propagation')
  check(nreads==0 and #tracks==0 and #domains==0,'failed discovery entered collection')
  outputs[variant]={tracks,counts,stats,domains,error_value()}
 end
 check(same(outputs[1],outputs[2]),'failure state differs')
end end
print('PASS collection offers:',checks[1],'full track/boundary/failure checks; height reads',reads[1],'->',reads[2])

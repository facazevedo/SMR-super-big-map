-- Full scalar detector/refinement/feather oracle, isolating only row batching.
local p=assert(io.popen('git show 8342ab2:Code/sbm_terrain_copy.lua','r'))
local previous=p:read('*a');assert(p:close())
local f=assert(io.open(arg[1]or'Code/sbm_terrain_copy.lua','r'));local candidate=f:read('*a');f:close()
local kernel_source=candidate
if arg[2]then local k=assert(io.open(arg[2],'r'));kernel_source=k:read('*a');k:close()end
local kernel_body=assert(kernel_source:match('(local function TranslateHeightTrack.-)\nreturn TranslateHeightTrack')
 or kernel_source:match('(local function TranslateHeightTrack.-)\nlocal function RepairInternalHeightStep'))
local translate=assert(load(kernel_body..'\nreturn TranslateHeightTrack'))()
local discovery_body=assert(candidate:match('(local function BuildHeightStepDiscoveryIndex.-)\nlocal function TranslateHeightTrack'))
local native_discovery=assert(load(discovery_body..'\nreturn BuildHeightStepDiscoveryIndex'))()
local api=dofile('_ralph/tools/parity/native_grid_double.lua')
api.GridMask=function(input,output,lo,hi)
 local w,h=input:size();for y=0,h-1 do for x=0,w-1 do
  local v=input:get(x,y);output:set(x,y,v>=lo and v<=hi and 1 or 0)
 end end
end
local function extract(s)
 return assert(s:match('(local function RepairInternalHeightStep.-)\n%-%- Repair already%-qualified')
  or s:match('(local function RepairInternalHeightStep.-)\nreturn RepairInternalHeightStep'))
end
local checks,batched=0,0
local function check(ok,msg)assert(ok,msg);checks=checks+1 end
local function run(s,case)
 local n=256;local writes={};local g={size=function()return n,n end}
 function g:get(x,y)
  -- Tiny synthetic maps use the scalar reader's existing nil-sample contract;
  -- full-size physical-edge bounds are independently tested by guard_join_test.
  if x<0 or y<0 or x>=n or y>=n then return nil end
  local v=writes[y*n+x];if v then return v end
  local z=30000
  if case%2==0 and x<=4 then z=z-2000 end
  if case%3~=0 and x>=n-5 then z=z-3000 end
  if case%4~=0 and y<=4 then z=z-2500 end
  if case%5~=0 and y>=n-5 then z=z-3500 end
  return z+((x*13+y*31+case)%11)
 end
 function g:set(x,y,z)assert(x>=0 and y>=0 and x<n and y<n);writes[y*n+x]=z end
 function g:new_instance(w,h)return api.NewComputeGrid(w,h,'u',16)end
 local scratch=api.NewComputeGrid(1,1,'u',16);g.copyrect=scratch.copyrect;scratch:free()
 local function scalar_discovery(_,_,_,p0,p1,along_n,step)
  local rows,positions={},{};for p=p0,p1 do positions[#positions+1]=p end
  for along=0,along_n-1,step do rows[along]=positions end;return rows,{}
 end
 local function counted_translation(...)
  batched=batched+1
  return translate(...)
 end
 local env=setmetatable({BuildHeightStepDiscoveryIndex=s==candidate and native_discovery or scalar_discovery,TranslateHeightTrack=counted_translation,
  Global=function(k)if k=='GridMinMax'then return function()return 0,65535 end end;return api[k]end},{__index=_G})
 local repair=assert(load(extract(s)..'\nreturn RepairInternalHeightStep','track order','t',env))()
 local changed,report=repair(g,false)
 check(changed and report.repairs>0,'fixture must exercise an accepted track: '..tostring(report.reason))
 return g,report
end
for case=1,10 do
 local a,ra=run(previous,case);local b,rb=run(candidate,case)
 check(ra.modified==rb.modified and ra.detected==rb.detected and ra.repairs==rb.repairs,'repair census changed')
 for y=0,255 do for x=0,255 do check(a:get(x,y)==b:get(x,y),'track order/feather changed output')end end
end
check(batched>0,'production did not batch track rows')
print('crease track order: '..checks..' checks; '..batched..' tracks')

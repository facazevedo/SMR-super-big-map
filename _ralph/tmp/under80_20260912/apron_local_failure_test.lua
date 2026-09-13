-- Each new local-error operation may fail; partial scratch must never be returned.
local path=arg[1] or '_ralph/runs/under80-20260912/artifacts/apron_local_research/terrain_candidate.lua'
local f=assert(io.open(path,'r'));local source=f:read('*a');f:close()
local a=assert(source:find('local NativeApronMask = function(',1,true))
local b=assert(source:find('\n\tlocal required =',a,true))
local native=assert(load(source:sub(a,b-1)..'\nreturn NativeApronMask'))()
local checks=0
for failure=0,6 do
 local api=dofile('_ralph/tools/parity/native_grid_double.lua')
 local owned,copied,muls={},false,0
 local function injected()error('injected local operation '..failure)end
 local function own(g)
  if not g then return nil end
  owned[#owned+1]=g
  local copy=g.copyrect
  g.copyrect=function(self,other,...)
   if self~=other then copied=true;if failure==0 then injected()end end
   return copy(self,other,...)
  end
  return g
 end
 local mul,clamp=api.GridMulDivAdd,api.GridClamp
 api.GridMulDivAdd=function(...)
  if copied then muls=muls+1;if muls==failure then injected()end end
  return mul(...)
 end
 api.GridClamp=function(...)
  if copied and failure==6 then injected()end
  return clamp(...)
 end
 local ok,why=pcall(native,api,own,{x=40,y=40,mountain_x=.6,mountain_y=.8},
  {core_fraction=.2},24,32.4,0,0,81,81)
 assert(not ok and tostring(why):find('injected local operation',1,true),'injection did not abort scratch publication')
 for i=#owned,1,-1 do owned[i]:free()end
 for _,g in ipairs(owned)do assert(g.freed,'local scratch leaked');checks=checks+1 end
 checks=checks+1
end
print('PASS '..checks..' local scratch checks across seven injected copy/arithmetic failures')

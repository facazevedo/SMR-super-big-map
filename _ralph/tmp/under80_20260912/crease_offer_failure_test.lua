-- Every native allocation position plus the new scratch copy. This does not
-- model engine logging-only errors; real normal-path parity remains mandatory.
local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local function compile(path)
 local body=assert(read(path):match('(local function BuildHeightStepDiscoveryIndex.-)\nend'))..'\nend'
 return assert(load(body..'\nreturn BuildHeightStepDiscoveryIndex'))()
end
local old=compile('Code/sbm_terrain_copy.lua')
local new=compile('_ralph/runs/under80-20260912/artifacts/crease_offer_research_2/sbm_terrain_copy.lua')
local api=dofile('_ralph/tools/parity/native_grid_double.lua')
api.GridMask=function(input,output,lo,hi)
 local w,h=input:size()
 for y=0,h-1 do for x=0,w-1 do
  local v=input:get(x,y);output:set(x,y,v>lo and v<=hi and 1 or 0)
 end end
end
local grid=api.NewComputeGrid(9,5,'u',16)
for y=0,4 do for x=4,8 do grid:set(x,y,128)end end
local methods=getmetatable(grid).__index
local make,repack,instance,copy=api.NewComputeGrid,api.GridRepack,methods.new_instance,methods.copyrect
local counter,allocated,fail_at,mode,copy_failure=0,{},nil,nil,false
local function allocation(fn,...)
 counter=counter+1
 if counter==fail_at then
  if mode=='throw'then error('injected allocation throw')end
  if mode=='false'then return false end
  return nil
 end
 local g=fn(...);allocated[#allocated+1]=g;return g
end
api.NewComputeGrid=function(...)return allocation(make,...)end
api.GridRepack=function(...)return allocation(repack,...)end
methods.new_instance=function(...)return allocation(instance,...)end
methods.copyrect=function(self,from,...)
 if copy_failure and self.format=='f' and from.format=='f'then error('injected signed copy')end
 return copy(self,from,...)
end
local checks=0
local function run(fn,n,kind,copy_bad)
 counter,allocated,fail_at,mode,copy_failure=0,{},n,kind,copy_bad
 local rows,detail=fn(api,grid,'x',1,6,5,1,3,128)
 if n or copy_bad then assert(rows==nil and type(detail)=='string','failure was not surfaced')
 else assert(rows~=nil,'normal build failed '..tostring(detail))end
 for _,g in ipairs(allocated)do assert(g.freed,'owned allocation leaked')end
 assert(not grid.freed and grid:get(0,0)==0 and grid:get(8,4)==128,'input changed/freed')
 checks=checks+1
 return counter
end
local old_count,new_count=run(old),run(new)
assert(old_count==new_count,'candidate added grid allocations')
for n=1,new_count do
 for _,kind in ipairs({'nil','false','throw'})do run(new,n,kind)end
end
run(new,nil,nil,true)
grid:free()
print('PASS crease offer ownership:',checks,'normal/failure cases;',new_count,'allocations unchanged from v987; signed-copy throw contained')

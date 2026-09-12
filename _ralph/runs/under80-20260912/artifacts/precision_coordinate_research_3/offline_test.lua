-- Execute the actual raster with f32 operations; native differential evidence
-- and the exact rational proof are separate requirements, not replaced here.
local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local source=read(arg[1] or '_ralph/runs/under80-20260912/artifacts/precision_coordinate_research_3/terrain_candidate.lua')
local p=assert(io.popen('git show c4d3e67:Code/sbm_terrain_copy.lua','r'))
local previous=p:read('*a');assert(p:close())
local function raster(s)
 local a=assert(s:find('local function RasterNaturalMountainBaseAprons(',1,true))
 local b=assert(s:find('local function CreateNaturalMountainBaseBuildableAprons(',a,true))
 return assert(load(s:sub(a,b-1)..'\nreturn RasterNaturalMountainBaseAprons'))()
end
local old,new=raster(previous),raster(source)
local literal=dofile('_ralph/tools/parity/v958_scalar_apron.lua')
local api=dofile('_ralph/tools/parity/native_grid_double.lua')
local checks,reduced=0,0
local eps=0.000000000931322574615478515625
for _,core in ipairs({0.1,0.2-eps,0.2,0.2+eps,0.25,0.6-eps,0.6,0.6+eps,0.75,0.75+eps,0.99})do
 for shape=1,3 do
  local grid=api.NewComputeGrid(33,35,'u',16)
  for y=0,34 do for x=0,32 do
   grid:set(x,y,shape==1 and 30000+x*31-y*17 or shape==2 and (x*x*137+y*y*83+x*y*23)%65536
    or 65000-(x*37+y*19)%500)
  end end
  local before,expected=grid:clone(),grid:clone()
  local selected={{x=16,y=17,sector_x=shape,sector_y=4,center=grid:get(16,17),gx=1.7,gy=-2.3,
   mountain_x=0.6,mountain_y=0.8,requires_edit=true}}
  local policy={outer_short=12,outer_long=16.2,core_fraction=core}
  local ok1,s1,e1=old(api,before,selected,policy)
  local calls={upper=0,sensitivity=0}
  local instrumented={};for key,value in pairs(api)do instrumented[key]=value end
  local expected_numerator=core<=0.60 and 5 or 7
  instrumented.GridMulDivAdd=function(g,mul,div,add)
   if mul==1 and div==1 and (add==1280 or add==1792)then
    assert(add==expected_numerator*256,'upper-weight branch mismatch');calls.upper=calls.upper+1
   end
   if (mul==15 or mul==21) and div==65536 and add==0 then
    assert(mul==3*expected_numerator,'cubic branch mismatch');calls.sensitivity=calls.sensitivity+1
   end
   return api.GridMulDivAdd(g,mul,div,add)
  end
  local ok2,s2,e2=new(instrumented,grid,selected,policy)
  local ok3,s3,e3=literal(expected,selected,policy)
  assert(ok1 and ok2 and ok3,tostring(e1)..'/'..tostring(e2)..'/'..tostring(e3))
  assert(s1.modified==s2.modified and s2.modified==s3.modified and s1.shaped==s2.shaped)
  assert(calls.upper==1 and calls.sensitivity==1,'both error terms must use the same branch')
  assert(s2.exact_samples<=s1.exact_samples,'tighter bracket increased ambiguous cells')
  if s2.exact_samples<s1.exact_samples then reduced=reduced+1 end
  for y=0,34 do for x=0,32 do
   assert(grid:get(x,y)==before:get(x,y) and grid:get(x,y)==expected:get(x,y),'final height changed')
   checks=checks+1
  end end
  grid:free();before:free();expected:free()
 end
end
assert(reduced>0,'bound did not exercise a reduction')
print('PASS adaptive-Q22 apron: '..checks..' exact three-way cells; reduced cases '..reduced)

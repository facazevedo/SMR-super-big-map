-- Actual candidate versus accepted raster AND literal pre-native scalar oracle.
local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local path=arg[1] or '_ralph/runs/under80-20260912/artifacts/apron_local_research/terrain_candidate.lua'
local source=read(path)
local p=assert(io.popen('git show 56fbf44:Code/sbm_terrain_copy.lua','r'))
local previous=p:read('*a');assert(p:close())
local function raster(s)
 local a=assert(s:find('local function RasterNaturalMountainBaseAprons(',1,true))
 local b=assert(s:find('local function CreateNaturalMountainBaseBuildableAprons(',a,true))
 return assert(load(s:sub(a,b-1)..'\nreturn RasterNaturalMountainBaseAprons'))()
end
local old,new=raster(previous),raster(source)
local literal=dofile('_ralph/tools/parity/v958_scalar_apron.lua')
local api=dofile('_ralph/tools/parity/native_grid_double.lua')
local checks,reduced,increased,old_exact,new_exact=0,0,0,0,0
local eps=0.000000000931322574615478515625
for _,core in ipairs({0.1,0.2-eps,0.2,0.2+eps,0.25,0.3,1.0/3.0,0.4,0.5,0.65,0.7,0.6-eps,0.6,0.6+eps,0.75,0.75+eps,0.99})do
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
  local ok2,s2,e2=new(api,grid,selected,policy)
  local ok3,s3,e3=literal(expected,selected,policy)
  assert(ok1 and ok2 and ok3,tostring(e1)..'/'..tostring(e2)..'/'..tostring(e3))
  for _,key in ipairs({'modified','shaped','raster_cells','native_mask_cells','native_mask_patches','scalar_mask_patches'})do
   assert(s1[key]==s2[key],'census changed: '..key)
  end
  assert(s2.modified==s3.modified)
  old_exact=old_exact+s1.exact_samples;new_exact=new_exact+s2.exact_samples
  if s2.exact_samples<s1.exact_samples then reduced=reduced+1 end
  if s2.exact_samples>s1.exact_samples then increased=increased+1 end
  if s1.native_mask_patches==0 then assert(s1.exact_samples==s2.exact_samples,'scalar fallback changed')end
  for y=0,34 do for x=0,32 do
   assert(grid:get(x,y)==before:get(x,y) and grid:get(x,y)==expected:get(x,y),'final height changed')
   checks=checks+1
  end end
  grid:free();before:free();expected:free()
 end
end
assert(reduced>0 and new_exact<old_exact,'no overall correction reduction')
print('PASS local-error raster: '..checks..' exact three-way cells; reduced/increased '..reduced..'/'..increased
 ..'; old/new corrections '..old_exact..'/'..new_exact..'; +1 H margin included')


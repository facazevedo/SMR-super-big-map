-- Full actual patch functions: native-grid double, final-grid equality, and
-- allocation/fill failure cleanup. Real native mask equality is tested separately.
local function read(path)
 local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s
end
local p=assert(io.popen('git show f4d1da6:Code/sbm_terrain_copy.lua','r'))
local previous=p:read('*a');assert(p:close())
local sources={previous,read('Code/sbm_terrain_copy.lua')}
local function body(s)
 local a=assert(s:find('local function aligned_native_bounds(',1,true))
 local b=assert(s:find('local function apply_native_raster()',a,true))
 s=s:sub(a,b-1)
 local count
 s,count=s:gsub('local function own%(value%)','local function own(value) probe_own(value)',1)
 assert(count==1)
 return s..' return apply_native_patch'
end
local api=dofile('_ralph/tools/parity/native_grid_double.lua')
local function protection(distance,radius,transition)
 if distance<=radius then return 0 end
 if transition<=0 or distance>=radius+transition then return 1 end
 local t=(distance-radius)/(transition+0.0)
 return t*t*t*(t*(t*6-15)+10)
end
local checks=0
local function check(value,why)assert(value,why);checks=checks+1 end
local function run(source,case,fault)
 local w,h=49,45
 local grid=api.NewComputeGrid(w,h,'u',16)
 for y=0,h-1 do for x=0,w-1 do grid:set(x,y,3000+(x*37+y*19+case*41)%1300) end end
 local before=grid:clone()
 local allocated={}
 local calls={fill=0,new=0,circles=0}
 local library={};for k,v in pairs(math) do library[k]=v end
 library.atan2=case%2==0 and (math.atan2 or math.atan) or nil
 local guards=case%3==0 and {{cx=35,cy=29,radius=2.0}} or {}
 local env=setmetatable({math=library,grid=grid,width=w,height=h,
  cells_per_hex=1.0,transition_minimum_width=3.0,transition_irregularity=0.38,
  native_sample_step=4,native_tile_step=1,height_tile=1.0,
  native_height_scale=256,native_weight_scale=4096,dirty_height_regions={},
  protected_ready_sites_near=function()return guards end,
  ProtectedTerrainBlendWeight=protection,
  point_fn=api.point,box_fn=api.box,native_repack=api.GridRepack,
  native_resample=api.GridResample,native_mul_div_add=api.GridMulDivAdd,
  native_add_mul_div=api.GridAddMulDiv,native_add=api.GridAdd,
  native_clamp=api.GridClamp,native_abs=api.GridAbs,
  native_count=api.GridCount,native_is_compute=api.IsComputeGrid,
  probe_own=function(g)if g then allocated[g]=true end end,
  native_new_grid=function(...)
   calls.new=calls.new+1
   if fault=='coarse_allocation' and calls.new==2 then return nil end
   return api.NewComputeGrid(...)
  end,
  native_fill=function(g,v)
   calls.fill=calls.fill+1
   if fault=='fill_before' then error('injected fill before write') end
   api.GridFill(g,v)
   if fault=='fill_after' then error('injected fill after write') end
  end,
  native_circle_set=function(g,v,cx,cy,radius,zero,step)
   calls.circles=calls.circles+1
   check(zero==0 and step==1,'unexpected native circle fixture arguments')
   local gw,gh=g:size()
   for y=0,gh-1 do for x=0,gw-1 do
    if (x-cx)*(x-cx)+(y-cy)*(y-cy)<=radius*radius then g:set(x,y,v) end
   end end
  end},{__index=_G})
 local fn=assert(load(body(source),'actual native patch','t',env))()
 local patch={cx=case%2==0 and 2.7 or 24.3,cy=case%4==0 and 43.1 or 21.7,
  core_cells=2.0,outer_cells=10.0,kind=case%3==0 and 'surface' or 'rocket',
  target=3456,grade_x=0.3,grade_y=-0.7,phase=case*0.711,
  relief_x=math.cos(case),relief_y=math.sin(case),q=1,r=2}
 local ok,a,b,c=pcall(fn,patch)
 for g in pairs(allocated) do check(g.freed,'owned patch allocation leaked') end
 if fault then
  check(not ok,'injected failure was not propagated')
  check(#env.dirty_height_regions==0,'failure published dirty region')
  for y=0,h-1 do for x=0,w-1 do check(grid:get(x,y)==before:get(x,y),'failure published partial terrain') end end
 else
  check(ok,'patch failed '..tostring(a))
  check(#env.dirty_height_regions==1,'patch dirty region missing')
 end
 before:free()
 return grid,{a,b,c},calls
end
for case=1,20 do
 local a,sa,ca=run(sources[1],case)
 local b,sb,cb=run(sources[2],case)
 for i=1,3 do check(sa[i]==sb[i],'patch accounting changed') end
 for y=0,44 do for x=0,48 do check(a:get(x,y)==b:get(x,y),'final native-double height changed') end end
 check(ca.fill==0 and cb.fill==1,'required fill not exercised')
 a:free();b:free()
end
for _,fault in ipairs({'coarse_allocation','fill_before','fill_after'}) do
 local grid=run(sources[2],3,fault);grid:free()
end
-- Execute the actual required-API guard against a missing GridFill.
local s=sources[2]
local a=assert(s:find('local native_new_grid = Global("NewComputeGrid")',1,true))
local b=assert(s:find('local native_weight_scale, native_height_scale',a,true))
local missing=assert(load(s:sub(a,b-1)..' return native_missing','required native APIs','t',
 setmetatable({grid={copyrect=function()end,new_instance=function()end},
 Global=function(name)if name~='GridFill' then return function()end end end},{__index=_G})))()
check(#missing==1 and missing[1]=='GridFill','missing fill API not explicitly required')
print('PASS: '..checks..' full-patch, U16 output, accounting, ownership and required-API checks')

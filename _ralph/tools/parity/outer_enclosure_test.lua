-- Whole actual coarse blocks, including zero initialization and enclosure.
local function read(path)
 local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s
end
local p=assert(io.popen('git show f4d1da6:Code/sbm_terrain_copy.lua','r'))
local previous=p:read('*a');assert(p:close())
local current=read('Code/sbm_terrain_copy.lua')
local function block(s)
 local a=assert(s:find('local function apply_native_patch',1,true))
 a=assert(s:find('local coarse_width =',a,true))
 local b=assert(s:find('mask = own(native_resample(coarse,',a,true))
 return s:sub(a,b-1)..' return coarse, samples'
end
local function compile(s)
 return assert(load('return function(_ENV) '..block(s)..' end'))()
end
local old,new=compile(previous),compile(current)
local function protection(distance,radius,transition)
 if distance<=radius then return 0 end
 if transition<=0 or distance>=radius+transition then return 1 end
 local t=(distance-radius)/(transition+0.0)
 return t*t*t*(t*(t*6-15)+10)
end
local grids,sets,fills=0,0,0
local function allocate(w,h)
 local g={w=w,h=h,data={}};grids=grids+1
 function g:set(x,y,v)
  assert(x>=0 and x<self.w and y>=0 and y<self.h)
  self.data[y*self.w+x]=v;sets=sets+1
 end
 return g
end
local library={};for k,v in pairs(math) do library[k]=v end
local env=setmetatable({math=library,own=function(v)return v end,
 native_new_grid=allocate,native_fill=function(g,v)
  fills=fills+1;for i=0,g.w*g.h-1 do g.data[i]=v end
 end,ProtectedTerrainBlendWeight=protection,native_weight_scale=4096,
 maximum_width_scale=1.35},{__index=_G})
local checks,skipped,total=0,0,0
for case=1,800 do
 local step=({1,4,2})[case%3+1]
 local w,h=({17,33,65,97})[case%4+1],({19,49,71})[case%3+1]
 local base=({0,65000,-65000,65537})[case%4+1]
 local phase=case*0.713
 local radius=({0,0.000001,3,20,64,140,65536,65537})[case%8+1]+0.0
 local core=radius*({0,0.06,0.2,0.9})[case%4+1]
 env.x0=base;env.y0=-base
 env.x1=base+(w-1)*step;env.y1=-base+(h-1)*step
 env.local_width=env.x1-env.x0+1;env.local_height=env.y1-env.y0+1
 env.sample_step=step;env.radius=radius;env.base_transition=(radius-core)/1.35
 env.patch={cx=base+(w-1)*step*0.5+math.sin(phase),
  cy=-base+(h-1)*step*0.5+math.cos(phase),core_cells=core,
  phase=phase,relief_x=math.cos(phase),relief_y=math.sin(phase)}
 env.transition_irregularity=case%2==0 and 0.38 or 0.45
 env.protection_blends={}
 for i=1,case%9 do env.protection_blends[i]={cx=env.patch.cx+i*3,
  cy=env.patch.cy-i*9,radius=i*2.0,transition=case%5==0 and 0 or i*4.0} end
 library.atan2=case%2==0 and (math.atan2 or math.atan) or nil
 local before=sets;local a,na=old(env);local oldsets=sets-before
 before=sets;local b,nb=new(env);local newsets=sets-before
 assert(na==nb and oldsets==na and a.w==b.w and a.h==b.h)
 for i=0,na-1 do assert(a.data[i]==b.data[i],('case %d cell %d: %s / %s'):format(case,i,tostring(a.data[i]),tostring(b.data[i])));checks=checks+1 end
 skipped=skipped+oldsets-newsets;total=total+oldsets
end
assert(fills==800 and grids==1600 and skipped>0)
print(('PASS: %d complete masks, %d exact U12 cells; %d/%d scalar evaluations omitted'):format(800,checks,skipped,total))

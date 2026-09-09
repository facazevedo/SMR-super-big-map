-- Compare actual production weight with its committed predecessor, including
-- points immediately around the new constant-region certificates.
local f=assert(io.open("Code/sbm_terrain_copy.lua","r"))
local current=f:read("*a");f:close()
local p=assert(io.popen("git show 691f900:Code/sbm_terrain_copy.lua","r"))
local previous=p:read("*a");assert(p:close())
local function weight_body(source)
 local raster=assert(source:match("(local function RasterNaturalMountainBaseAprons.-)\nlocal function CreateNaturalMountainBaseBuildableAprons"))
 return assert(raster:match("(local function weight.-)\n\tfor index,candidate"))
end
local checks,sqrt_old,sqrt_new=0,0,0
local function check(ok,msg) assert(ok,msg);checks=checks+1 end
local function compile(body,core,old)
 local env=setmetatable({policy={core_fraction=core},stats={mask_fast_zero=0,mask_fast_one=0},
  core_radius2=(core*0.90)*(core*0.90),sqrt=function(v)
   if old then sqrt_old=sqrt_old+1 else sqrt_new=sqrt_new+1 end
   return math.sqrt(v)
  end},{__index=_G})
 return assert(load(body.."\nreturn weight","production-mask","t",env))(),env
end
for _,core in ipairs({0,0.01,0.2,0.58,0.8,0.99}) do
 local old=compile(weight_body(previous),core,true)
 local new,env=compile(weight_body(current),core,false)
 for angle=0,359,3 do
  local theta=angle*math.pi/180
  local c={mountain_x=math.cos(theta),mountain_y=math.sin(theta)}
  for x=-42,42,3 do for y=-42,42,3 do
   check(new(c,19.73,26.81,x,y)==old(c,19.73,26.81,x,y),"weight changed")
  end end
  for _,radius in ipairs({0,0.0001,core*.90,core*.91,core,1.09,1.10,1.12}) do
   for _,delta in ipairs({-1e-10,0,1e-10}) do
    local r=math.max(0,radius+delta)
    local dx,dy=r*19.73*c.mountain_x,r*19.73*c.mountain_y
    check(new(c,19.73,26.81,dx,dy)==old(c,19.73,26.81,dx,dy),"certificate boundary changed")
   end
  end
 end
 if core>0 then check(env.stats.mask_fast_one>0,"inner certificate not exercised") end
 check(env.stats.mask_fast_zero>0,"outer certificate not exercised")
end
check(sqrt_new<sqrt_old*0.75,"constant regions did not reduce square roots")
local bounds_body=assert(current:match("(local function mask_row_bounds.-)\n\tlocal function weight"),
 "conservative mask row bounds missing")
local factory=assert(load(bounds_body.."\nreturn mask_row_bounds","mask-row-bounds","t",
 setmetatable({floor=math.floor,ceil=math.ceil,min=math.min,max=math.max,sqrt=math.sqrt},
 {__index=_G})))()
local original=compile(weight_body(previous),0.33,true)
local skipped,total=0,0
for _,short in ipairs({4.0,35.0,120.0,400.0}) do
 for angle=0,330,30 do
  local theta=angle*math.pi/180
  local c={x=0,y=0,mountain_x=math.cos(theta),mountain_y=math.sin(theta)}
  local long=short*1.35
  local bound=math.ceil(long+2)
  local row_bounds=factory(c,short,long,-bound,bound)
  local step=math.max(1,math.floor(bound/30))
  for y=-bound,bound,step do
   local lo,hi=row_bounds(y)
   for x=-bound,bound,step do
    local value=original(c,short,long,x,y)
    check(value==0 or (x>=lo and x<=hi),"row pruning omitted nonzero weight")
    total=total+1
    if x<lo or x>hi then skipped=skipped+1 end
   end
  end
 end
end
check(skipped>total*0.1,"row bounds did not omit zero cells")
print("apron mask: "..checks.." checks passed; square roots "..sqrt_old.." -> "..sqrt_new)
print("row bounds omitted "..skipped.." of "..total.." tested zero candidates without losing a nonzero weight")

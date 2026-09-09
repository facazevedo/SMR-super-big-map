-- Execute the actual scalar coarse-mask body against its accepted predecessor.
local f=assert(io.open('Code/sbm_terrain_copy.lua','r'));local current=f:read('*a');f:close()
local p=assert(io.popen('git show 8342ab2:Code/sbm_terrain_copy.lua','r'))
local previous=p:read('*a');assert(p:close())
local function body(source)
 local start=assert(source:find('local function apply_native_patch',1,true))
 start=assert(source:find('local dx, dy = x - patch.cx, y - patch.cy',start,true))
 local finish=assert(source:find('coarse:set(coarse_x, coarse_y,',start,true))
 return source:sub(start,finish-1)..' return math.floor(weight * native_weight_scale + 0.5)'
end
local function protection(distance,radius,transition)
 if distance<=radius then return 0 end
 if transition<=0 or distance>=radius+transition then return 1 end
 local t=(distance-radius)/(transition+0.0)
 return t*t*t*(t*(t*6-15)+10)
end
local calls={old=0,new=0};local checks=0
local function compile(source,label)
 local m={};for k,v in pairs(math) do m[k]=v end
 m.atan2=math.atan2 or math.atan
 m.sin=function(x) calls[label]=calls[label]+1;return math.sin(x) end
 local env=setmetatable({math=m,ProtectedTerrainBlendWeight=protection,
  native_weight_scale=4096,maximum_width_scale=1.35},{__index=_G})
 return assert(load(body(source),'outer mask '..label,'t',env)),env
end
local old,a=compile(previous,'old');local new,b=compile(current,'new')
local function check(ok,msg) assert(ok,msg);checks=checks+1 end
for _,core in ipairs({0.0,1.0,30.0,110.0}) do
 for _,transition in ipairs({20.0,60.0,360.0}) do
  for _,irregularity in ipairs({0.0,0.38,0.45}) do
   for _,phase in ipairs({0.0,1.313,6.282}) do
    local patch={cx=17.13,cy=-26.97,core_cells=core,phase=phase,
     relief_x=math.cos(phase),relief_y=math.sin(phase)}
    local radius=core+transition*1.35
    for _,protection_blends in ipairs({{},{{cx=0,cy=0,radius=40,transition=0}},
     {{cx=-45,cy=26,radius=20,transition=60},{cx=65,cy=-40,radius=80,transition=10}}}) do
     for _,env in ipairs({a,b}) do
      env.patch=patch;env.radius=radius;env.base_transition=transition
      env.transition_irregularity=irregularity;env.protection_blends=protection_blends
     end
     for iy=-16,16 do for ix=-16,16 do
      a.x=patch.cx+ix*radius/14;a.y=patch.cy+iy*radius/14;b.x=a.x;b.y=a.y
      check(old()==new(),'coarse mask changed')
     end end
     for angle=0,330,30 do for _,r in ipairs({0,core,radius}) do
      for _,epsilon in ipairs({-1e-9,0,1e-9}) do
       a.x=patch.cx+(r+epsilon)*math.cos(angle*math.pi/180)
       a.y=patch.cy+(r+epsilon)*math.sin(angle*math.pi/180);b.x=a.x;b.y=a.y
       check(old()==new(),'coarse mask boundary changed')
      end
     end end
    end
   end
  end
 end
end
check(calls.new<calls.old*.8,'constant regions did not remove trigonometry')
print('outer mask shortcuts: '..checks..' checks; sine calls '..calls.old..' -> '..calls.new)

-- Differential native-contact fixture with independent current/predecessor modules.
local p=assert(io.popen('git show 8342ab2:Code/sbm_rock_grounding.lua','r'))
local previous=p:read('*a');assert(p:close())
local f=assert(io.open(arg[1] or 'Code/sbm_rock_grounding.lua','r'))
local candidate=f:read('*a');f:close()
local checks,calls_old,calls_new,rays_old,rays_new=0,0,0,0,0
local function check(ok,msg) assert(ok,msg);checks=checks+1 end
local ptmt={};ptmt.__index={x=function(p)return p[1]end,y=function(p)return p[2]end,z=function(p)return p[3]end}
ptmt.__eq=function(a,b)return a[1]==b[1] and a[2]==b[2] and a[3]==b[3]end
local function pt(x,y,z)return setmetatable({x,y,z},ptmt)end
local function same(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for k,v in pairs(a)do if not same(v,b[k])then return false end end
 for k in pairs(b)do if a[k]==nil then return false end end
 return true
end
local function module(source)
 local env={};env._G=env;setmetatable(env,{__index=_G})
 local globals={point=pt,const={HeightTileSize=100},GetPreciseTicks=function()return 0 end,
  EntityData={Rock={editor_category='StonesRocksCliffs',entity={material_type='Rock'}}},
  terrain={GetHeight=function(m,p)return m.height(p)end}}
 env.SuperBigMap={Engine={Global=function(k)return globals[k]end},Config={},ObjectClone={
  ShouldSkipObject=function(o)return o.skip end,IsImportantSectorObject=function(o)return o.important end,
  ObjectScalesWithTerrain=function(o)return not o.no_scale end}}
 assert(load(source,'grounding differential','t',env))()
 return env.SuperBigMap.RockGrounding
end
local old,new=module(previous),module(candidate)
local function captured(mod,map,obj)
 for i=1,20 do local name,value=debug.getupvalue(mod.Capture,i)
  if name=='captures' then return value[map].objects[obj]end
 end
 error('capture table unavailable')
end
local function fixture(seed,label)
 local map={GetMapSize=function()return 100000,100000 end}
 map.height=function(p)return 15000+((p:x()*13+p:y()*17+seed*29)%6000)end
 local o={pos=pt(40000,50000,16000),visual=pt(40000,50000,16000+(seed%5)*2000),scale=100,
  angle=seed,axis=pt(0,0,1),skip=seed%19==0,important=seed%23==0,no_scale=seed%29==0}
 function o:GetPos()return self.pos end;function o:GetVisualPos()return self.visual end
 function o:IsValidZ()return seed%7~=0 or self.final end
 function o:GetScale()return self.scale end;function o:GetAngle()return self.angle end
 function o:GetAxis()return self.axis end;function o:GetParent()return nil end
 function o:GetEntity()return 'Rock'end;function o:SetPos(p)self.pos=p end
 function o:GetObjectBBox()
  local v=self.visual;local sx=300+(seed%11)*337;local sy=400+(seed%13)*311
  local values={minx=v:x()-math.floor(sx/2),miny=v:y()-math.floor(sy/2),
   sizex=sx,sizey=sy,minz=v:z()-500+(seed%4)*500,maxz=v:z()+3500}
  local b={};for key,value in pairs(values)do b[key]=function()
   if label=='old'then calls_old=calls_old+1 else calls_new=calls_new+1 end
   return value
  end end;return b
 end
 function o:IntersectSegment(lo,hi)
  if (lo:x()+lo:y())%17==0 then return nil end
  local z=self.visual:z()+(((lo:x()*31+lo:y()*47+seed)%3500)-500)*self.scale/100
  if z<lo:z() or z>hi:z()then return nil end
  return pt(lo:x(),lo:y(),z)
 end
 return map,o
end
for seed=1,360 do
 local ma,a=fixture(seed,'old');local mb,b=fixture(seed,'new')
 old.BeginCapture(ma);new.BeginCapture(mb);old.Capture(ma,a);new.Capture(mb,b)
 rays_old=rays_old+ma.SuperBigMapRockGroundingStats.rays
 rays_new=rays_new+mb.SuperBigMapRockGroundingStats.rays
 check(same(captured(old,ma,a),captured(new,mb,b)),'native contact records changed')
 for _,o in ipairs({a,b})do o.scale=133;o.final=true;o.pos=pt(53333,66667,16000);o.visual=o.pos end
 local x,xe=old.Apply(ma,a,1,4/3);local y,ye=new.Apply(mb,b,1,4/3)
 check(x==y and xe==ye,'grounding delta changed')
 check(a.pos==b.pos,'final rock position changed')
 check(a.SuperBigMapRockGroundingContactCount==b.SuperBigMapRockGroundingContactCount,'contact census changed')
end
check(calls_new<calls_old*.5,'capture did not remove repeated bounding-box calls')
check(rays_new<rays_old,'capture did not reject impossible ray contacts')
check(candidate:match('(local function Apply.-)\nlocal function Failure')
 ==previous:match('(local function Apply.-)\nlocal function Failure'),
 'individual grounding implementation changed')
print('rock capture cache: '..checks..' checks; geometry calls '..calls_old..' -> '..calls_new
 ..'; capture rays '..rays_old..' -> '..rays_new)

-- Execute the actual ownership and placement planner on translated scenes.
local f=assert(io.open('Code/sbm_terrain_copy.lua','r'));local source=f:read('*a');f:close()
local block=assert(source:match('(function TerrainCopy.PendingSurfaceEntranceObjects.-)\n%-%- The reference must'))
local function point(x,y)return {xy=function()return x,y end}end
local function box(a,b,c,d)return {minx=function()return a end,miny=function()return b end,
 maxx=function()return c end,maxy=function()return d end}end
local globals={EntitySurfaces={TerrainHole=1},HasAnySurfaces=function(o)return o.cut==true end,
 ForEachSurface=function(o,flag,fn)fn(point(o.x-20,o.y-20),point(o.x+20,o.y-20),point(o.x,o.y+20))end}
SuperBigMap={Engine={Global=function(k)return globals[k]end}}
dofile('Code/sbm_decoration_validation.lua')
SuperBigMap.RockGrounding={Eligible=function(o)return o.rock==true end}
local copy={}
local env=setmetatable({TerrainCopy=copy,SuperBigMap=SuperBigMap,
 Global=function(k)return globals[k]end,IsLiveGameObject=function(o)return type(o)=='table' and not o.deleted end,
 ObjectPosition=function(o)return point(o.x,o.y)end,PointXY=function(p)return p:xy()end},{__index=_G})
assert(load(block,'production entrance clearance','t',env))()
for _,offset in ipairs({0,12345,900000}) do
 local function object(x,y,half)
  local o={x=x+offset,y=y+offset}
  function o:GetObjectBBox()return box(self.x-half,self.y-half,self.x+half,self.y+half)end
  function o:SetPos()error('clearance must not move any object')end
  return o
 end
 local anchor=object(100,100,5);anchor.other={};anchor.SuperBigMapCommittedPassageLocked=true;anchor.cut=true
 local child=object(100,100,10);child.rock=true
 anchor.GetAttaches=function()return {child}end
 local marker=object(100,100,2);marker.spawner=anchor
 local sign=object(100,100,3);sign.tunnel_marker=marker
 local rock=object(118,100,2);rock.rock=true
 local unrelated=object(102,100,2);unrelated.rock=true
 local finished=object(500,500,5);finished.SuperBigMapCommittedPassageLocked=true
 finished.SuperBigMapPassagePadPrepared=true
 local all={sign,unrelated,marker,child,rock,anchor,finished}
 local map={MapForEach=function(self,scope,class,fn)
  if class=='ElevatorPassage' then fn(anchor);fn(finished)
  else for _,o in ipairs(all)do fn(o)end end
 end}
 local scene=copy.PendingSurfaceEntranceObjects(map)
 assert(scene.objects[anchor]==anchor and scene.objects[child]==anchor
  and scene.objects[marker]==anchor and scene.objects[sign]==anchor)
 assert(not scene.objects[rock] and not scene.objects[unrelated] and not scene.objects[finished])
 local clear=copy.BuildSurfaceEntranceClearance(map,scene)
 assert(not clear(anchor,100+offset,100+offset),'native clear build grid hid decorative overlap')
 unrelated.rock=false
 clear=copy.BuildSurfaceEntranceClearance(map,scene)
 assert(not clear(anchor,100+offset,100+offset),'cut faces outside the render bbox were omitted')
 assert(clear(anchor,140+offset,140+offset),'valid nearby entrance was rejected')
 assert(not clear({},140+offset,140+offset),'unknown entrance obtained clearance')
 assert(rock.x==118+offset and rock.y==100+offset,'correct rock moved')
 globals.ForEachSurface=nil
 assert(not pcall(copy.BuildSurfaceEntranceClearance,map,scene),'missing cut geometry was accepted')
 globals.ForEachSurface=function(o,flag,fn)fn(point(o.x-20,o.y-20),point(o.x+20,o.y-20),point(o.x,o.y+20))end
end
print('entrance clearance: ownership, settled rocks, cut extent, missing geometry and translated scenarios passed')

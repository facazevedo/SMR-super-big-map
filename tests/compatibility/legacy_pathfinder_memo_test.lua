-- 2026-10-02 "XL map Stutter save": on expanded maps ConnectivityCheck is a real path search, and
-- vanilla ClearWasteRockConstructionSite:GetOutputPile made ~1900 failing searches without
-- yielding (8 s freezes every ~25 s). Two exact mitigations are checked here:
-- 1. identical searches are memoized only within one GameTime and one passability version;
-- 2. on legacy maps the dump-spot search skips spots already proved unreachable for the same rover
--    position and stops new searches after a per-call budget, continuing on the next call.
SuperBigMap={State={}}
const={ConnectivitySupported=true,HexSize=0}
MapVarValues={}
function MapVar(name,default) MapVarValues[name]=default end
local function P(x,y,z) return {ispoint=true,x=x,y=y,z=z or 0,xyz=function(p) return p.x,p.y,p.z end,
  xy=function(p) return p.x,p.y end} end
point=P
function IsPoint(p) return type(p)=='table' and p.ispoint==true end
function IsValid(o) return type(o)=='table' and o.valid==true end
function ResolveMap(v) return type(v)=='table' and (v.mapdata and v or v.map) or Maps[v] end
local map={mapdata={GameLogic=true},SuperBigMapLegacyPathfinder=true}
local vanilla={mapdata={GameLogic=true}}
Maps={[1]=map,[2]=vanilla}
LoadedMaps={}
for _,name in ipairs({'ConnectivityResume','ConnectivitySuspend','ConnectivityCheck','ConnectivityCheckAll',
  'ConnectivityCheckObj','ConnectivityCheckObjAll','ConnectivityCheckObjSpot','EngineChangeMap',
  'LoadGame','LoadGameFromMem','GetTopClosestDests'}) do _G[name]=function() return 'native' end end
local last_alloc
function EngineChangeMap(slot,folder,data) last_alloc=data;return 'allocated' end
local now=1000
function GameTime() return now end
local ticks=0
function GetPreciseTicks() return ticks end
local handlers={}
local searches=0
-- Reachable = x >= 0. A ranged search succeeds when any point within range of the target is.
pf={PosPathLen=function(m,a,b,c,range) searches=searches+1;ticks=ticks+10
  if b.x+(range or 0)<0 then return false end
  if b.x<0 then return true,math.abs(a.x)+math.abs(a.y) end
  return true,math.abs(b.x-a.x)+math.abs(b.y-a.y) end}
function IsKindOf(o,cls) return type(o)=='table' and o.kind==cls end
terrain={FindPassable=function(m,p) return p end}
-- Vanilla-shaped waste rock site: probes many spots, all unreachable, without yielding.
local site_class={}
function site_class.IsRoverReachable(self,m,q,r,rover)
  return ConnectivityCheck(m,rover:GetPos(),P(q,r),rover.pfclass)
end
function site_class.GetOutputPile(self,rover)
  for i=1,self.spots do
    if self:IsRoverReachable(self:GetMap(),-i,0,rover) then return 'pile' end
  end
  return false
end
local derived={GetOutputPile=site_class.GetOutputPile,IsRoverReachable=site_class.IsRoverReachable}
-- Vanilla-shaped drone estimate: one connectivity search from the drone to the requester.
local approach_calls=0
local requester_class={GetDroneApproachDist=function(self,drone)
  approach_calls=approach_calls+1
  return ConnectivityCheck(drone.map,drone:GetPos(),self:GetPos(),0)
end}
local depot_class={GetDroneApproachDist=requester_class.GetDroneApproachDist}
g_CObjectFuncs={}
g_Classes={ClearWasteRockConstructionSite=site_class,DerivedSite=derived,Map={},
  TaskRequester=requester_class,Depot=depot_class}
SuperBigMap.Engine={ChainOnMsg=function(name,fn) handlers[name]=fn end}
assert(loadfile('Code/sbm_legacy_pathfinder.lua'))()
local legacy=SuperBigMap.LegacyPathfinder
assert(handlers.OnPassabilityChanged,'the cache listens for passability changes')
assert(legacy.ApplyModBehavior())

-- 1. Memo: identical queries within one GameTime search once; GameTime or passability resets it.
local from,to=P(0,0),P(10,0)
assert(ConnectivityCheck(map,from,to,0)==10 and searches==1)
assert(ConnectivityCheck(map,from,to,0)==10 and searches==1,'identical query is memoized')
assert(ConnectivityCheck(map,from,P(-5,0),0)==nil and searches==2)
assert(ConnectivityCheck(map,from,P(-5,0),0)==nil and searches==2,'unreachable verdicts are memoized too')
assert(ConnectivityCheck(map,from,to,1)==10 and searches==3,'pass class is part of the key')
now=now+1
assert(ConnectivityCheck(map,from,to,0)==10 and searches==4,'a new GameTime searches again')
handlers.OnPassabilityChanged(map)
assert(ConnectivityCheck(map,from,to,0)==10 and searches==5,'a passability change searches again')
print('legacy pathfinder memo: exact within one GameTime and passability version')

-- 2. Dump search: budgeted per call, failures remembered, progress across calls, derived classes.
assert(site_class.GetOutputPile~=derived.GetOutputPile or g_Classes.DerivedSite.GetOutputPile==site_class.GetOutputPile)
assert(g_Classes.DerivedSite.GetOutputPile==site_class.GetOutputPile,'derived copies are patched too')
local rover={valid=true,pfclass=0,map=map,GetPos=function() return P(0,0) end}
local site={spots=40,GetMap=function() return map end}
setmetatable(site,{__index=site_class})
searches=0;ticks=0;now=now+1
assert(site:GetOutputPile(rover)==false)
local first=searches
assert(first>0 and first<40,'one call stops at the budget instead of searching all 40 spots: '..first)
local total=first
for _=1,10 do
  now=now+1;ticks=0
  local before=searches
  assert(site:GetOutputPile(rover)==false)
  total=total+(searches-before)
end
assert(total==40,'every spot is searched exactly once across calls: '..total)
assert(legacy.dump_budget_exhausted>=1)
-- A reachable spot is still reported, but only by a real search.
local good={spots=1,GetMap=function() return map end}
setmetatable(good,{__index=site_class})
local reach_original=site_class.IsRoverReachable
now=now+1;ticks=0;searches=0
site_class.IsRoverReachable=function(self,m,q,r,rv) return reach_original(self,m,7,0,rv) end
assert(good:GetOutputPile(rover)=='pile' and searches==1,'a reachable spot is found by one real search')
site_class.IsRoverReachable=reach_original
-- Normal-size maps never use the patch.
local normal_rover={valid=true,pfclass=0,map=vanilla,GetPos=function() return P(0,0) end}
local normal={spots=3,GetMap=function() return vanilla end}
setmetatable(normal,{__index=site_class})
searches=0
normal:GetOutputPile(normal_rover)
assert(searches==0,'vanilla maps keep native connectivity and the unpatched search')
-- Idempotent: applying again does not wrap the wrapper.
local pile=site_class.GetOutputPile
assert(legacy.ApplyModBehavior())
assert(site_class.GetOutputPile==pile,'repeated ApplyModBehavior keeps one wrapper')
print('legacy dump search: budgeted, incremental, exact, vanilla maps untouched, idempotent')
-- 3. Cold load from the main menu: the slot holds only the unflagged menu map, yet an 8192-tile
-- expanded map must still get the legacy pathfinder; a vanilla-size map stays native.
Maps[3]={mapdata={GameLogic=true}}
assert(EngineChangeMap(3,'cold',{GameLogic=true,Width=8192,Height=8192})=='allocated')
assert(last_alloc.GameLogic==false and Maps[3].SuperBigMapLegacyPathfinder==true,'cold load allocates legacy')
assert(EngineChangeMap(4,'empty',{GameLogic=true,Width=8192,Height=8192})=='allocated' and last_alloc.GameLogic==false,
  'no map in the slot yet still allocates legacy')
assert(EngineChangeMap(3,'vanilla',{GameLogic=true,Width=6144,Height=6144})=='allocated' and last_alloc.GameLogic==true,
  'vanilla-size maps keep native connectivity')
print('legacy allocation: expanded maps detected by size, including cold loads')
-- 4. Cold load: at the main menu the hooks are removed; the saved legacy maps must have them
-- back before vanilla's OnMsg.LoadGame resumes native connectivity.
LoadedMaps={}
assert(legacy.RestoreVanillaBehavior())
assert(ConnectivityResume(map)=='native','main menu keeps vanilla connectivity')
assert(handlers.PersistPostLoad,'hooks are installed after the save is restored')
LoadedMaps={vanilla}
handlers.PersistPostLoad()
assert(ConnectivityResume(map)=='native','a vanilla save installs nothing')
LoadedMaps={map,vanilla}
handlers.PersistPostLoad()
assert(ConnectivityResume(map)==nil,'a legacy map never reaches the native resume')
assert(ConnectivityResume(vanilla)=='native','vanilla maps still resume natively')
print('legacy cold load: hooks installed at PersistPostLoad, before LoadGame resumes connectivity')
-- 5. List form ("any destination reachable?"): a ranged search rejects an unreachable set at once,
-- and otherwise the nearest destinations are searched first with an early exit.
LoadedMaps={map}
legacy.ApplyModBehavior()
now=now+100;searches=0
local far={P(-50,0),P(-50,10),P(-50,20),P(-50,30),P(-50,40),P(-50,50)}
assert(ConnectivityCheck(map,P(0,0),far,0)==nil and searches==1,'an unreachable site costs one ranged search: '..searches)
now=now+1;searches=0
local mixed={P(-50,0),P(-50,10),P(2,0),P(-50,20),P(-50,30),P(-50,40)}
assert(ConnectivityCheck(map,P(0,0),mixed,0)==2 and searches==2,'nearest reachable point ends the search: '..searches)
now=now+1;searches=0
assert(ConnectivityCheck(map,P(0,0),{P(-1,0),P(3,0)},0)==3,'short lists skip the ranged search')
print('legacy list check: ranged rejection and nearest-first early exit')
-- 6. Drone task-swap estimate: vanilla reachability, remembered per drone and target; 2D distance.
assert(g_Classes.Depot.GetDroneApproachDist==g_Classes.TaskRequester.GetDroneApproachDist,'derived copies patched')
local function obj(x,y,extra) local o={valid=true,map=map,GetPos=function() return P(x,y) end}
  for k,v in pairs(extra or {}) do o[k]=v end return setmetatable(o,{__index=requester_class}) end
local hub={}
local drone={valid=true,map=map,command_center=hub,GetPos=function() return P(0,0) end,
  GetDist2D=function(self,o) local x,y=o:GetPos():xyz() return math.floor(math.sqrt(x*x+y*y)) end}
local target=obj(30,40)
approach_calls=0
assert(target:GetDroneApproachDist(drone)==50 and approach_calls==1)
now=now+1
assert(target:GetDroneApproachDist(drone)==50 and approach_calls==1,'reachability is remembered across ticks')
local unreachable=obj(-30,0)
assert(unreachable:GetDroneApproachDist(drone)==nil and approach_calls==2)
assert(unreachable:GetDroneApproachDist(drone)==nil and approach_calls==2,'unreachable is remembered too')
handlers.OnPassabilityChanged(map)
assert(target:GetDroneApproachDist(drone)==50 and approach_calls==3,'passability change asks again')
handlers.PFTunnelChanged()
assert(target:GetDroneApproachDist(drone)==50 and approach_calls==4,'tunnel change asks again')
local sibling=setmetatable({},{__index=drone})
assert(target:GetDroneApproachDist(sibling)==50 and approach_calls==4,'drones of one command center share the answer')
drone.command_center={}
assert(target:GetDroneApproachDist(drone)==50 and approach_calls==5,'another command center asks again')
now=now+150001
assert(target:GetDroneApproachDist(drone)==50 and approach_calls==6,'entries expire')
local flyer=setmetatable({kind='FlyingObject'},{__index=drone})
target:GetDroneApproachDist(flyer);target:GetDroneApproachDist(flyer)
assert(approach_calls==8,'flying drones keep the vanilla call')
local vanilla_drone=setmetatable({map=vanilla},{__index=drone})
target:GetDroneApproachDist(vanilla_drone)
assert(approach_calls==9,'vanilla-size maps keep the vanilla call')
print('legacy drone estimate: reachability cached per command center and target, invalidated on changes, 2D distance')
-- 7. GetTopClosestDests: vanilla's 2D fallback order on legacy maps, no path searches.
function table.icopy(t) local c={} for i=1,#t do c[i]=t[i] end return c end
function IsCloser2D(u,a,b) local ux,uy=u:GetPos():xyz() local ax,ay=a:xyz() local bx,by=b:xyz()
  return (ax-ux)^2+(ay-uy)^2 < (bx-ux)^2+(by-uy)^2 end
local walker={valid=true,map=map,GetPos=function() return P(0,0) end}
local ring={}
for i=1,30 do ring[i]=P(i*10*((i%2==0) and 1 or -1),0) end
searches=0
local top=GetTopClosestDests(map,ring,walker,3)
assert(#top==3 and searches==0,'no path searches')
assert(top[1].x==-10 and top[2].x==20 and top[3].x==-30,'2D order')
assert(#GetTopClosestDests(map,{P(1,0),P(2,0)},walker,5)==2,'short lists returned whole')
assert(GetTopClosestDests(vanilla,ring,walker,3)=='native','vanilla maps keep the vanilla ranking')
print('legacy GetTopClosestDests: 2D fallback order on legacy maps, vanilla elsewhere')

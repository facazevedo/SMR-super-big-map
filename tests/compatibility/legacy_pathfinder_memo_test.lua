-- 2026-10-02 "XL map Stutter save": on expanded maps ConnectivityCheck is a real path search, and
-- vanilla ClearWasteRockConstructionSite:GetOutputPile made ~1900 failing searches without
-- yielding (8 s freezes every ~25 s). Two exact mitigations are checked here:
-- 1. identical searches are memoized only within one GameTime and one passability version;
-- 2. on legacy maps the dump-spot search skips spots already proved unreachable for the same rover
--    position and stops new searches after a per-call budget, continuing on the next call.
SuperBigMap={State={}}
const={ConnectivitySupported=true}
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
  'LoadGame','LoadGameFromMem'}) do _G[name]=function() return 'native' end end
local last_alloc
function EngineChangeMap(slot,folder,data) last_alloc=data;return 'allocated' end
local now=1000
function GameTime() return now end
local ticks=0
function GetPreciseTicks() return ticks end
local handlers={}
local searches=0
pf={PosPathLen=function(m,a,b,c) searches=searches+1;ticks=ticks+10
  if b.x<0 then return false end return true,math.abs(b.x-a.x)+math.abs(b.y-a.y) end}
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
g_CObjectFuncs={}
g_Classes={ClearWasteRockConstructionSite=site_class,DerivedSite=derived,Map={}}
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

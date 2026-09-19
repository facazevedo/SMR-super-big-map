-- Isolated protocol fixture; no game or external tools needed.
SuperBigMap={State={}}
const={ConnectivitySupported=true}
MapVarValues={}
function MapVar(name,default) MapVarValues[name]=default end
function point(x,y,z) return {ispoint=true,x=x,y=y,z=z} end
function IsPoint(p) return type(p)=='table' and p.ispoint==true end
function IsValid(o) return type(o)=='table' and o.valid==true end
function ResolveMap(v) return type(v)=='table' and (v.mapdata and v or v.map) or Maps[v] end
local map={mapdata={GameLogic=true},SuperBigMapExpansionPending=true}
local vanilla={mapdata={GameLogic=true}}
Maps={[1]=map,[2]=vanilla}
LoadedMaps={}
local native_calls, allocation=0
local function native(...) native_calls=native_calls+1;return 123,... end
local originals={}
for _,name in ipairs({'ConnectivityResume','ConnectivitySuspend','ConnectivityCheck','ConnectivityCheckAll','ConnectivityCheckObj','ConnectivityCheckObjAll','ConnectivityCheckObjSpot'}) do
  local identity=name
  _G[name]=function(...) assert(identity);return native(...) end
  originals[name]=_G[name]
end
function EngineChangeMap(slot,folder,data) allocation=data;return 'allocation-result',slot end
function LoadGame(...) return ... end
function LoadGameFromMem(...) return ... end
local original_load=LoadGame
g_CObjectFuncs={ConnectivityCheck=ConnectivityCheckObj}
g_Classes={Map={ConnectivityCheck=ConnectivityCheck},Unit={CanReach=ConnectivityCheckObj}}
pf={PosPathLen=function(m,a,b,c)
  assert(m==map)
  if b.x<0 then return false,55 end
  return true,math.abs(b.x-a.x)+math.abs(b.y-a.y)
end}
terrain={FindPassable=function(m,p,c,r) return p.x<0 and nil or p end}
assert(loadfile('Code/sbm_legacy_pathfinder.lua'))()
local legacy=SuperBigMap.LegacyPathfinder
assert(LoadGame~=original_load)
assert(legacy.ApplyModBehavior())
local data={GameLogic=true,Width=8192,Height=8192}
assert(EngineChangeMap(1,'fixture',data)=='allocation-result')
assert(allocation~=data and allocation.GameLogic==false and data.GameLogic==true)
assert(map.SuperBigMapLegacyPathfinder)
assert(MapVarValues.SuperBigMapLegacyPathfinder(map)==true)
local a,b=point(0,0),point(5,7)
assert(ConnectivityCheck(map,a,b,0)==12)
assert(ConnectivityCheck(map,a,5,7,nil,0)==12)
assert(ConnectivityCheck(map,a,a,0)==0)
assert(ConnectivityCheck(map,a,point(-5,0),0)==nil)
assert(ConnectivityCheck(map,a,{point(-5,0),b},0)==12)
local all=ConnectivityCheckAll(map,a,{b,point(-5,0),a},0)
assert(all[1]==12 and all[2]==-1 and all[3]==0)
local unit={valid=true,map=map,GetPos=function() return a end,GetPfClass=function() return 1 end}
assert(ConnectivityCheckObj(unit,b)==12)
assert(g_Classes.Unit.CanReach(unit,b)==12)
assert(g_CObjectFuncs.ConnectivityCheck(unit,b)==12)
assert(g_Classes.Map.ConnectivityCheck(map,a,b)==12)
local target={valid=true,map=map,GetSpotRange=function() return 0,1 end,
  GetSpotPos=function(self,index) return index==0 and point(-5,0) or b end}
assert(ConnectivityCheckObjSpot(unit,target,'work','idle')==12)
local previous=native_calls
ConnectivityResume(map)
assert(native_calls==previous)
assert(ConnectivityCheck(vanilla,a,b)==123)
assert(native_calls==previous+1)
legacy.ApplyModBehavior()
assert(ConnectivityCheck(map,a,b)==12)
LoadedMaps={map}
assert(legacy.RestoreVanillaBehavior()==false)
LoadedMaps={}
assert(legacy.RestoreVanillaBehavior())
assert(ConnectivityCheck==originals.ConnectivityCheck and g_Classes.Map.ConnectivityCheck==originals.ConnectivityCheck)
assert(LoadGame('save-fixture')=='save-fixture')
assert(ConnectivityCheck(map,a,b)==12)
print('PASS: allocation isolation, real path lengths, unreachable/zero/list/XYZ/object/spot calls, native delegation, class aliases, reload guard, restoration')

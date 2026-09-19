local file = assert(io.open('Code/sbm_deposits.lua', 'r'))
local source = file:read('*a'); file:close()
local block = assert(source:match('function DepositRules.InitializeSurfaceDepositDiscovery.-\nend\n'))
  .. assert(source:match('function DepositRules.RestorePendingSurfaceDiscovery.-\nend\n'))
local hidden, scanned = {status='unexplored'}, {status='scanned'}
local globals = {g_SignsVisible=true, ShouldShowResourceIcons=function() return true end,
  IsValid=function(o) return not o.deleted end}
local rows = {}
local function object(class, sector, revealed)
  local obj={class=class, sector=sector, revealed=revealed, visible=revealed,
    amount=12345, x=#rows+1, calls=0}
  function obj:SetVisible(value) self.visible=value end
  if class~='TerrainDeposit' then
    function obj:PickVisibilityState() self.visible=self.revealed and globals.g_SignsVisible end
  end
  rows[#rows+1]=obj
  return obj
end
local anomaly=object('SubsurfaceAnomaly',hidden,true)
local resource=object('SubsurfaceDeposit',hidden,true)
local concrete=object('TerrainDeposit',hidden,true)
local initial=object('SubsurfaceDeposit',scanned,true)
local undiscovered=object('SubsurfaceDeposit',scanned,false)
local map={expanded=true, City={}}
function map:MapForEach() error('discovery must never enumerate the map') end
local env=setmetatable({DepositRules={},SuperBigMap={SectorGrid={IsModMap=function(m)return m.expanded end}},
  IsUndergroundMap=function(m)return m.underground end,
  cfg=function()return {STRETCH_ENFORCE_SCAN_GATE=true}end,
  Global=function(name)return globals[name]end,
  IsScanGatedDeposit=function(o)return o.class=='SubsurfaceDeposit' or o.class=='SubsurfaceAnomaly'end,
  IsKindOfSafe=function(o,c)return o.class==c end,
  ObjectPos=function(obj)return {xy=function()return obj.x,0 end}end,
  SectorAtPoint=function(m,x)return rows[x].sector end,
  SetRevealedState=function(o,value)
    o.calls=o.calls+1;o.revealed=value;if o.PickVisibilityState then o:PickVisibilityState()end
  end,
},{__index=_G})
assert(load(block,'actual scan discovery','t',env))()
local initialize=env.DepositRules.InitializeSurfaceDepositDiscovery
local restore=env.DepositRules.RestorePendingSurfaceDiscovery
for _,o in ipairs({anomaly,resource,concrete}) do
  assert(initialize(map,o)==false)
  assert(not o.revealed and not o.visible and map.SuperBigMapScanHiddenDeposits[o])
  assert(o.amount==12345 and o.calls==0, 'no reveal/unreveal callbacks during initialization')
end
assert(initialize(map,initial)==true and initial.revealed)
assert(not undiscovered.revealed)
assert(restore(map,scanned)==0 and anomaly.calls==0, 'unrelated scan does nothing')
-- TerrainDeposit has a default-true flag, so load restores it from persisted pending state.
concrete.revealed=true;concrete.visible=true
assert(restore(map)==0 and not concrete.visible and not concrete.revealed)
assert(restore(map)==0 and anomaly.calls==0)
hidden.status='scanned';globals.g_SignsVisible=false
assert(restore(map,hidden)==3 and next(map.SuperBigMapScanHiddenDeposits)==nil)
assert(anomaly.revealed and resource.revealed and concrete.revealed)
assert(not anomaly.visible and not concrete.visible, 'respect player icon visibility')
assert(not undiscovered.revealed, 'never reveal objects outside the pending set')
assert(restore(map,hidden)==0 and anomaly.calls==1)
local dead=object('SubsurfaceDeposit',hidden,false);dead.deleted=true
map.SuperBigMapScanHiddenDeposits[dead]=true
restore(map);assert(not map.SuperBigMapScanHiddenDeposits[dead])
hidden.status='unexplored';anomaly.revealed=true;anomaly.visible=true
map.underground=true;assert(initialize(map,anomaly)==true and anomaly.revealed)
map.underground=false;map.expanded=false;assert(initialize(map,anomaly)==true and anomaly.revealed)
map.expanded=true;hidden.status=nil
assert(initialize(map,anomaly)==false and not anomaly.revealed, 'unknown scan state is not discovery')
hidden.status='deep scanned'
assert(restore(map,hidden)==1 and anomaly.revealed)
local ordinary=object('SurfaceDepositMetals',hidden,true)
assert(initialize(map,ordinary)==true and ordinary.revealed, 'do not hide physical surface piles')
assert(initialize(map,nil)==true)
local highlight_file=assert(io.open('Code/sbm_sector_highlight.lua','r'))
local highlight=highlight_file:read('*a');highlight_file:close()
assert(not highlight:find('ApplyOverviewResourceScanGate',1,true),
  'the old whole-map overview workaround must not mask incorrect initial state')
assert(highlight:find('RestorePendingSurfaceDiscovery(map, self)',1,true),
  'sector scan must discover pending objects synchronously, including while paused')
print('PASS: discovery at placement, no full-map enumeration or reveal FX, pending-only scans/load, positions/amounts, icon toggle, underground/vanilla isolation')

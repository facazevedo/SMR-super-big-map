-- Exercise the real commander grant through discovery initialization and scan cleanup.
local f=assert(io.open('Code/sbm_deposits.lua','rb'));local source=f:read('*a');f:close()
local body=assert(source:match('(local function IsCommanderStartDeposit.-\nend)'))
for _,name in ipairs({'RevealCommanderStartDeposit','InitializeSurfaceDepositDiscovery','EnforceScanGateAfterStretch'}) do
  body=body..'\n'..assert(source:match('(function DepositRules%.'..name..'.-\nend)'))
end
local checked=0
for _,profile in ipairs({'astrogeologist','hydroengineer'}) do
  for _,initial in ipairs({'unplaced','hidden','revealed'}) do
    local resource=profile=='astrogeologist' and 'PreciousMetals' or 'Water'
    local class='SubsurfaceDeposit'..resource
    local sector={status='unexplored'}
    local objects,markers={},{}
    local function marker(res,depth,distance,placed,revealed)
      local m={resource=res,depth_layer=depth,distance=distance,is_placed=placed,class='SubsurfaceDepositMarker'}
      function m:PlaceDeposit()
        self.calls=(self.calls or 0)+1
        self.is_placed=true
        self.placed_obj={class='SubsurfaceDeposit'..self.resource,resource=self.resource,
          marker=self,revealed=self.revealed,visible=self.revealed,distance=self.distance}
        function self.placed_obj:SetVisible(v)self.visible=v end
        objects[#objects+1]=self.placed_obj
        return self.placed_obj
      end
      markers[#markers+1]=m
      if placed then m.revealed=revealed;m:PlaceDeposit() end
      return m
    end
    local deep=marker(resource,2,1,false,false)
    local bonus=marker(resource,1,10,initial~='unplaced',initial=='revealed')
    local farther=marker(resource,1,20,false,false)
    local ordinary=marker('Metals',1,2,true,false)
    local map={expanded=true,City={InitialSector={area={Center=function()return 0 end}},MapSectors={}}}
    map.SuperBigMapScanHiddenDeposits={}
    if bonus.placed_obj and initial=='hidden' then map.SuperBigMapScanHiddenDeposits[bonus.placed_obj]=true end
    function map:MapFindNearest(center,area,want,predicate)
      local best
      for _,o in ipairs(want=='SubsurfaceDepositMarker' and markers or objects) do
        if o.class==want and not o.deleted and predicate(o) and (not best or o.distance<best.distance) then best=o end
      end
      return best
    end
    function map:MapForEach(area,want,fn)for _,m in ipairs(markers)do fn(m)end end
    local globals={GetCommanderProfile=function()return {id=profile}end,
      IsValid=function(o)return o and not o.deleted end,DoneObject=function(o)o.deleted=true end,
      GetMapSectorXY=function()return sector end}
    local env=setmetatable({DepositRules={},SuperBigMap={SectorGrid={IsModMap=function(m)return m.expanded end}},
      Global=function(n)return globals[n]end,IsUndergroundMap=function(m)return m.underground end,
      cfg=function()return {STRETCH_ENFORCE_SCAN_GATE=true}end,ExpansionStepEnabled=function()return true end,
      SetRevealedState=function(o,v)o.revealed=v;o.visible=v end,
      ObjectPos=function()return {xy=function()return 100,100 end}end,
      SectorAtPoint=function()return sector end,SectorIsScanned=function(s)return s.status=='scanned'end,
      IsScanGatedDeposit=function()return true end,IsKindOfSafe=function()return false end,
      IsResourceDepositMarker=function()return true end,IsConcreteTerrainDepositMarker=function()return false end,
      MoveConcreteImprints=function()end,
    },{__index=_G})
    assert(load(body,'production commander discovery','t',env))()
    local rules=env.DepositRules
    assert(rules.RevealCommanderStartDeposit(map))
    local deposit=bonus.placed_obj
    assert(deposit and deposit.revealed and deposit.visible,'commander bonus must be discovered')
    assert(not deep.is_placed and not farther.is_placed,'only the nearest shallow deposit is granted')
    assert(not map.SuperBigMapScanHiddenDeposits[deposit],'explicit grant must leave the pending scan set')
    assert(rules.InitializeSurfaceDepositDiscovery(map,deposit) and deposit.revealed)
    assert(not rules.InitializeSurfaceDepositDiscovery(map,ordinary.placed_obj),'ordinary deposit remains scan-gated')
    rules.EnforceScanGateAfterStretch(map)
    assert(not deposit.deleted and bonus.is_placed and deposit.revealed,'scan cleanup erased the commander bonus')
    assert(ordinary.is_placed==false,'ordinary unscanned deposit must still be removed')
    assert(sector.status=='unexplored','commander grant must not scan another sector')
    assert(rules.RevealCommanderStartDeposit(map) and bonus.calls==1,'grant is not idempotent')
    deposit.deleted=true;bonus.placed_obj=false;bonus.is_placed=false
    assert(rules.RevealCommanderStartDeposit(map) and bonus.calls==1,'depletion must not grant another deposit')
    map.SuperBigMapCommanderStartDeposit=nil
    bonus.is_placed=true;bonus.revealed=true;bonus.placed_obj=deposit
    assert(rules.RevealCommanderStartDeposit(map,true),'old depleted save repair failed')
    assert(map.SuperBigMapCommanderStartDeposit.deposit==false and not farther.is_placed,
      'old save repair must not replace an exhausted deposit')
    map.SuperBigMapCommanderStartDeposit=nil
    markers={};objects={}
    local granted,reason=rules.RevealCommanderStartDeposit(map,true)
    assert(granted==false and reason:find('marker unavailable'),'unavailable old deposits need a non-throwing result')
    checked=checked+1
  end
end
for _,case in ipairs({{expanded=false},{expanded=true,underground=true}})do
  case.City={InitialSector={}}
  local env=setmetatable({DepositRules={},SuperBigMap={SectorGrid={IsModMap=function(m)return m.expanded end}},
    IsUndergroundMap=function(m)return m.underground end,Global=function()error('ineligible map queried commander')end}, {__index=_G})
  assert(load(body,'isolated commander discovery','t',env))()
  assert(env.DepositRules.RevealCommanderStartDeposit(case))
end
print('commander discovery: '..checked..' grant/cleanup cases; no extra scans, duplicate grants, or vanilla/underground changes')

-- Exercise the production wonder pass with observation on/off. Placement,
-- rejection and RNG consumption must agree; report-only native calls must stop.
local function read(path)
 local f=assert(io.open(path,'rb'));local s=f:read('*a'):gsub('\r\n','\n');f:close();return s
end
local deposits=read('Code/sbm_deposits.lua')
local wonder=assert(deposits:match('(function DepositRules%.EnsureDeferredUndergroundWonderAnomaliesReachable%b()%s*.-)\nfunction DepositRules%.SetUndergroundWonderReservedHexes'))
local function run(observe,case)
 local calls={fresh=0,diagnostic=0,reach=0,eval=0,draws=0}
 local function pt(x,y)return {x=x,y=y,xy=function(p)return p.x,p.y end,SetTerrainZ=function(p)return p end}end
 local marker={class='SubsurfaceSpecialAnomalyMarker',SuperBigMapDeferredWonderAnomaly=true,
  pos=pt(10,10),spawner={class='BottomlessPit',pos=pt(10,10)},SetPos=function(o,p)o.pos=p end}
 local map={City={},SuperBigMapWonderReachabilityReport={{stale=true}},MapForEach=function(_,_,_,fn)fn(marker)end}
 local function terrain_ok(p)return case~='invalid' and (case~='repair' or p.x>=12)end
 local ctx={flatness_minimum=4080,buildable={},build_unbuildable_z=-1,
  buildable_get_z=function()calls.diagnostic=calls.diagnostic+1;return 0 end}
 local api={point=pt,WorldToHex=function(p)return p.x,p.y end,HexToWorld=function(q,r)return q,r end}
 local env=setmetatable({DepositRules={},SuperBigMap={Diagnostics={GenerationAuditEnabled=function()return observe end}},
  Global=function(n)return api[n]end,SeedDeterministicPlacement=function()end,
  IsUndergroundMap=function()return true end,IsKindOfSafe=function()return true end,
  BuildUndergroundReachability=function()return {available=true,seeds={pt(1,1)},checks=0,rejected=0,failures=0}end,
  SharedTopUpValidationContext=function()return ctx end,NewDepositValidationContext=function()calls.fresh=calls.fresh+1;return ctx end,
  UndergroundWonderReservedHexes=function()return {}end,MapWorldSize=function()return 100,100 end,
  ObjectPos=function(o)return o.pos end,DEFERRED_WONDER_ANOMALY_MAX_LOCAL_RADIUS=3,
  EvaluateDepositTerrain=function(_,p)calls.eval=calls.eval+1;return terrain_ok(p),nil,nil,nil,p.x,p.y end,
  IsUnobstructedAt=function()return case~='obstructed'end,
  IsReachableFromUndergroundEntrance=function()calls.reach=calls.reach+1;return false end,
  IsBuildableAt=function(_,p)calls.diagnostic=calls.diagnostic+1;return terrain_ok(p),p.x,p.y end,
  PassableAt=function()calls.diagnostic=calls.diagnostic+1;return true end,
  FlatnessAt=function()calls.diagnostic=calls.diagnostic+1;return 4096 end,
  HexDistance=function(a,b,c,d)return math.abs(a-c)+math.abs(b-d)end,
  BadgeHexOccupied=function()return case=='occupied'end,CoordinateHexKey=function(q,r)return q..':'..r end,
  BuildBadgeOccupancy=function()return {}end,
  ForEachHexInRing=function(q,r,radius,fn)fn(q+radius,r)end,
  RandInt=function(n)calls.draws=calls.draws+1;return n-1 end,
  SetRevealedState=function()end,SectorAtPoint=function()end,StampResolvedBadgeHex=function()end,
  MoveBadgeMarker=function(o,_,candidate)o:SetPos(candidate.point);return true end,
  AuditEmit=function()end}, {__index=_G})
 assert(load(wonder,'production wonder release observations','t',env))()
 local ok,stats=env.DepositRules.EnsureDeferredUndergroundWonderAnomaliesReachable(map,case=='repair')
 if observe then
  assert(calls.fresh==1 and calls.diagnostic>0 and calls.reach>0,'diagnostic mode must still inspect')
  assert(stats.details and map.SuperBigMapWonderReachabilityReport,'diagnostic report missing')
 else
  assert(calls.fresh==0 and calls.diagnostic==0 and calls.reach==0,'release performed report-only native checks')
  assert(stats.details==nil and stats.entrance_disconnected==nil and map.SuperBigMapWonderReachabilityReport==nil,
   'release must not publish stale or unmeasured findings')
 end
 return ok,stats,marker,calls
end
for _,case in ipairs({'valid','invalid','occupied','obstructed','repair'})do
 local a,sa,ma,ca=run(false,case);local b,sb,mb,cb=run(true,case)
 assert(a==b and a==(case=='valid' or case=='repair'),'placement verdict changed: '..case)
 for _,key in ipairs({'valid','invalid','moved','unresolved','terrain_invalid','too_far','overlaps','candidates_tested'})do
  assert(sa[key]==sb[key],'production result changed: '..case..' '..key)
 end
 assert(ma.pos.x==mb.pos.x and ma.pos.y==mb.pos.y and ca.draws==cb.draws,'placement/RNG changed')
 assert(ca.eval<cb.eval,'duplicate observation terrain evaluations not removed')
 if case=='repair'then assert(ma.pos.x==12 and sa.moved==1,'nearest valid repair must remain')end
end

-- Execute each previously unconditional normal-summary print block, not a
-- stand-in logger. Error/failure messages deliberately remain available.
local function print_block(source,tag)
 local hit=assert(source:find('[Super Big Map]['..tag..']',1,true))
 local start
 for pos in source:sub(1,hit):gmatch('()local print_fn =')do start=pos end
 local finish=assert(source:find('\n\tend',hit,true))
 return source:sub(assert(start),finish+5)
end
local config={};local printed=0
local env=setmetatable({report={},stats={},cfg_bool=function(k,default)local v=config[k];if v==nil then return default end;return v end,
 cfg=function()return config end,AuditEnabled=function()return false end,CountMapString=function()return ''end,
 Global=function(n)if n=='print'then return function()printed=printed+1 end end end}, {__index=_G})
local loading=assert(deposits:match('(local function LoadingDiagnosticsEnabled%b()%s*.-\nend)'))
env.LoadingDiagnosticsEnabled=assert(load(loading..'\nreturn LoadingDiagnosticsEnabled','loading gate','t',env))()
local terrain=read('Code/sbm_terrain_copy.lua')
for _,entry in ipairs({{terrain,'OuterResourceTerrain'},{terrain,'OuterResourceTerrainAudit'},{deposits,'OuterResourceTopUpCensus'}})do
 local emit=assert(load(print_block(entry[1],entry[2]),'production summary '..entry[2],'t',env))
 for _,settings in ipairs({{}, {DEBUG_LOADING_TIMINGS=true}, {DEBUG_LOGGING_ENABLED=true}})do
  config=settings;printed=0;emit();assert(printed==0,'release summary leaked: '..entry[2])
 end
 config={DEBUG_LOGGING_ENABLED=true,DEBUG_LOADING_TIMINGS=true};printed=0;emit();assert(printed==1,'opt-in summary lost')
end
-- The expensive capture dispatch and full footprint descriptions are evidence,
-- not correction inputs. Keep their release gates at the call site.
assert(terrain:find('if not cfg_bool("DECORATION_VALIDATION_ENABLED", true) then validation = nil end',1,true))
assert(terrain:find('twin_image_footprint = EntranceAuditEnabled() and anchor_surface_reason',1,true))
assert(terrain:find('committed_footprint = EntranceAuditEnabled() and anchor_surface_reason',1,true))
local scheduled=assert(deposits:match('(function DepositRules%.SchedulePostDeferredSurfaceResourceTopUpCensus%b()%s*.-)\n%-%- Final invariant check'))
local observe=false;local jobs={};local census=0
local sbm={Diagnostics={GenerationAuditEnabled=function()return observe end},DepositRules={}}
local scope=setmetatable({SuperBigMap=sbm,DepositRules=sbm.DepositRules,Global=function()end,
 IsUndergroundMap=function()return false end,Sleep=function()end},{__index=_G});scope._G=scope
assert(load(scheduled,'production deferred census gate','t',scope))()
sbm.DepositRules.CensusFinalOuterResourceTopUps=function()census=census+1;return true,{}end
local map={CreateGameTimeThread=function(_,fn)jobs[#jobs+1]=fn end}
local schedule=sbm.DepositRules.SchedulePostDeferredSurfaceResourceTopUpCensus
assert(not schedule(map) and #jobs==0 and not map.SuperBigMapOuterResourceCensusScheduled,'release must not schedule a report-only census')
observe=true;assert(schedule(map));assert(not schedule(map) and #jobs==1,'diagnostic census must coalesce')
observe=false;jobs[1]();assert(census==0,'queued diagnostic must honor disabling before execution')
observe=true;jobs[1]();assert(census==1 and map.SuperBigMapOuterResourceCensusPostGameInitOK,'opt-in census must still work')
print('release quiet: no normal summary leaks or report-only wonder queries; verdicts, repair, RNG and opt-in diagnostics preserved')

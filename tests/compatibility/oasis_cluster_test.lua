-- Owner ruling 2026-09-26, "oasis" clusters: each outer resource cluster mixes resources, usually
-- one anomaly and sometimes one dome bonus, with no badge repeated inside the cluster; anomaly
-- top-ups outside clusters use the whole-map placement of the deposit top-ups.
local function read(path) local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local deposits=read('Code/sbm_deposits.lua')
local config=read('Code/sbm_config.lua')

-- 1. The badge a marker shows: resource kind and layer, the anomaly, the dome-effect type.
local block=assert(deposits:match('(function DepositRules%.ClusterBadgeKey.-\r?\nend)\r?\n'),'badge key not found')
local function kind_of(obj,class) return obj.kinds[class]==true end
local env=setmetatable({DepositRules={},IsKindOfSafe=kind_of},{__index=_G})
local key=assert(load(block..'\nreturn DepositRules.ClusterBadgeKey','badge','t',env))()
local function marker(kinds,fields) local m={kinds={}} for _,k in ipairs(kinds) do m.kinds[k]=true end
  for k,v in pairs(fields or {}) do m[k]=v end return m end
assert(key(marker({'SurfaceDepositMarker'},{resource='Metals'}))=='surface:Metals')
assert(key(marker({'SubsurfaceDepositMarker'},{resource='Metals'}))=='subsurface:Metals',
  'surface and subsurface metals show different badges')
assert(key(marker({'TerrainDepositMarker'},{resource='Concrete'}))=='terrain:Concrete')
assert(key(marker({'SubsurfaceAnomalyMarker'},{tech_action='complete'}))=='anomaly','every anomaly shows the same badge')
assert(key(marker({'EffectDepositMarker'},{deposit_type='BeautyEffectDeposit'}))=='effect:BeautyEffectDeposit')
assert(key(nil)==nil)

-- 2. Settings: one anomaly per cluster at most, whole-map anomaly top-ups, dome bonuses enabled.
assert(config:find('config.OuterResourceClusterMaximumAnomalies = 1',1,true),'at most one anomaly badge per cluster')
assert(config:find('config.TopUpAnomalyOuterRingSectors = 0',1,true),'anomaly top-ups are whole-map, not ring-only')
assert(config:find('config.OuterResourceClusterDomeBonusPercent = 33',1,true),'about a third of clusters get a dome bonus')
assert(config:find('config.OuterResourceClusterAnomalyPercent = 75',1,true))

-- 3. The wiring that enforces the rule stays in place.
assert(deposits:find('active_cluster_badges[DepositRules.ClusterBadgeKey(template)]',1,true),
  'cluster deposits skip badges the cluster already shows')
assert(deposits:find('outside_oasis_clusters(candidate) and repulsion.CanPlace(candidate, profile)',1,true),
  'whole-map anomaly top-ups keep out of cluster areas')
assert(deposits:find('and (stats.cluster_badge_repeats or 0) == 0',1,true),'the census fails on a repeated badge')
assert(deposits:find('local function FillOasisClusterAnomalies(map)',1,true))
assert(deposits:find('clone.SuperBigMapClusterDomeBonus = true',1,true))
print('oasis clusters: badge keys, settings, and rule wiring')

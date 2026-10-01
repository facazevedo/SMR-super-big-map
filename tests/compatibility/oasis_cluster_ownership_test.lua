-- Sweep case 23S112W (2026-10-01): two outer clusters 15 hexes apart have overlapping 12-hex areas.
-- The oasis anomaly fill put cluster 1's anomaly 6 hexes from cluster 6, which has no anomaly slot,
-- and the census (nearest cluster, lowest index on a tie) failed with anomaly_cluster_overflow=1.
-- Fills must only use spots their own cluster owns under that same rule.
local function read(path) local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local deposits=read('Code/sbm_deposits.lua')
local distance_block=assert(deposits:match('(local function AxialHexDistance.-\r?\nend)\r?\n'),'AxialHexDistance not found')
local block=assert(deposits:match('(function DepositRules%.NearestClusterPadIndex.-\r?\nend)\r?\n'),
  'NearestClusterPadIndex not found')
local env=setmetatable({DepositRules={}},{__index=_G})
local nearest=assert(load(distance_block..'\n'..block..'\nreturn DepositRules.NearestClusterPadIndex','nearest','t',env))()

-- The 23S112W geometry: pad 1 at (268,920), pad 6 at (283,909); the anomaly at (278,908).
local pads={}
pads[1]={cluster_q=268,cluster_r=920}
for i=2,5 do pads[i]={cluster_q=0,cluster_r=0} end
pads[6]={cluster_q=283,cluster_r=909}
assert(nearest(pads,278,908,12)==6,'the 23S112W spot belongs to cluster 6')
assert(nearest(pads,268,920,12)==1,'a cluster owns its own centre')
assert(nearest(pads,500,500,12)==nil,'a spot outside every cluster belongs to none')
-- Ties go to the lowest pad index, as in the census.
local tie={{q=0,r=0},{q=4,r=0}}
assert(nearest(tie,2,0,12)==1,'equal distance resolves to the lower index')
-- pad.q/pad.r are used when the cluster centre is absent.
assert(nearest({{q=10,r=10}},10,11,12)==1)

-- Both fills apply the rule before accepting a spot.
assert(deposits:find('local clear = nearest_cluster(q, r) == cluster',1,true),
  'the oasis anomaly fill keeps only spots its cluster owns')
assert(deposits:find('local clear = DepositRules.NearestClusterPadIndex(\n\t\t\t\t\t\t\t\tmap.SuperBigMapOuterResourceRocketPads, q, r, radius) == pad_index',1,true)
  or deposits:find('DepositRules.NearestClusterPadIndex(\r\n',1,true),
  'the oasis dome bonus keeps only spots its cluster owns')
print('oasis cluster ownership: fills use the census nearest-cluster rule')

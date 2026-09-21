SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_seating.lua')
local S=SuperBigMap.DecorationSeating
local function stone(x,z,h)
 return {height=h,vertices={{x,0,z},{x+2,0,z},{x+1,0,z+h}}}
end
local p=S.Plan({stone(0,20,10)},function()return 0 end,{tile=1})
assert(p and p.dx==0 and p.dy==0 and p.dz==-20,'whole floating rock seats without XY change')
p=S.Plan({stone(0,0,10),stone(20,20,10)},function()return 0 end,{tile=1})
assert(not p,'never bury the grounded piece to fix a disconnected fragment')
p=S.Plan({stone(0,0,10),stone(20,20,10)},function(x,y)return y==1 and (x>=20 and 20 or 0) or 0 end,{tile=1,allow_xy=true,rings=2})
assert(p and p.dy==1 and p.dz==0,'top-up cluster can use nearby matching terrain without deforming meshes')
p=S.Plan({stone(0,20,10)},function()return nil end,{tile=1})
assert(not p,'missing terrain never permits repair')
p=S.Plan({stone(0,20,10)},function()return 0 end,{tile=1,allowed=function()return false end})
assert(not p,'placement guard can veto a correction')
-- Native rock meshes often extend below their origin. Visibility retention must
-- compare with the already visible formation, not require exposing half of a
-- large buried foundation while also grounding its detached small stone.
local partial={stone(0,-320,580),stone(20,74,124)}
p=S.Plan(partial,function()return 0 end,{tile=1,retain_existing_visibility=true})
assert(p and p.dz==-74,'partly buried foundation must not prevent a safe minimal seating')
assert(260+p.dz>=260/2 and 198+p.dz>=124/2,'retain at least half each originally visible component')
p=S.Plan({stone(0,-9,10),stone(20,20,10)},function()return 0 end,{tile=1,retain_existing_visibility=true})
assert(not p,'an already small exposed tip must not be buried to repair another component')
dofile('Code/sbm_decoration_geometry.lua')
local separated=SuperBigMap.DecorationGeometry.TrianglesSeparated
local a={{0,0,0},{2,0,0},{0,2,0}}
assert(separated(a,{{2,2,0},{3,2,0},{2,3,0}},0),'coplanar disjoint triangles with overlapping boxes')
assert(not separated(a,{{0,0,0},{1,0,0},{0,1,0}},0),'coplanar overlap rejected')
assert(separated(a,{{0,0,5},{2,0,5},{0,2,5}},1),'parallel separate planes')
assert(not separated(a,{{0,0,1},{2,0,1},{0,2,1}},2),'tolerance is conservative')
assert(not separated(a,{{0.5,0.5,-1},{0.5,0.5,1},{1,1,0}},0),'crossing triangles rejected')

local function point(x,y,z)return {xyz=function()return x,y,z end}end
local pos=point(20,0,20)
local obj={GetVisualPos=function()return pos end,GetPos=function()return pos end,
 GetPosXYZ=function()return pos:xyz()end,SetPos=function(_,p)pos=p end,GetEntity=function()return 'Stone'end}
local success=true;local checks=0
local validator={SeatingEvidence=function()return {{obj=obj,confirmed=true,bounds={20,0,20,22,2,30},components={stone(20,20,10)}}}end,
 SeatingPlacementClear=function()return true end,
 RecordSeating=function()obj.SuperBigMapSupportRepair={version=1};return true end,
 Run=function()
  checks=checks+1
  if success then obj.SuperBigMapSupportValidation={current_geometry_status='valid',placement_repaired=true};return {}end
  obj.SuperBigMapSupportValidation={current_geometry_status='inconclusive'};return {}
 end}
local globals={point=point,const={HeightTileSize=100},terrain={GetHeight=function()return 0 end,GetTerrainType=function()return 1 end},GetPreciseTicks=function()return 1 end}
SuperBigMap={Engine={Global=function(n)return globals[n]end,MapDataEnvironment=function()return 'Surface'end},DecorationValidation=validator}
dofile('Code/sbm_decoration_seating.lua');S=SuperBigMap.DecorationSeating
local map={mapdata={},GetMapSize=function()return 100000,100000 end}
local report=S.Run(map)
assert(report.corrected==1 and select(3,pos:xyz())==0 and checks==1,'independent proof accepts verified placement')
local annotation=obj.SuperBigMapSupportRepair
success=false;pos=point(20,0,20);report=S.Run(map)
assert(report.corrected==0 and report.rejected==1 and report.records[1].rolled_back,'failed proof must not be reported as repaired')
assert(select(3,pos:xyz())==20 and obj.SuperBigMapSupportRepair==annotation,'rollback restores position and previous annotation')
assert(checks==3,'rollback must refresh the diagnostic ledger')
success=true
for _,fault in ipairs({'record exception','record refusal','verification exception'})do
 pos=point(20,0,20);local before=pos;local old_record,old_run=validator.RecordSeating,validator.Run
 validator.RecordSeating=function(...)
  obj.SuperBigMapSupportRepair={partial=true}
  if fault=='record exception' then error('record failed')end
  if fault=='record refusal' then return false end
  return old_record(...)
 end
 validator.Run=function(...)if fault=='verification exception'then error('verification failed')end;return old_run(...)end
 report=S.Run(map)
 assert(report.corrected==0 and pos==before and obj.SuperBigMapSupportRepair==annotation,'surface rollback failed: '..fault)
 validator.RecordSeating,validator.Run=old_record,old_run
end
pos=point(20,0,20);local before=pos;local old_evidence=validator.SeatingEvidence
validator.SeatingEvidence=function()
 local rows=old_evidence();rows[2]={obj={GetVisualPos=function()error('later candidate failed')end}};return rows
end
report=S.Run(map)
assert(report.error and report.corrected==0 and pos==before and obj.SuperBigMapSupportRepair==annotation,'a later preparation exception leaked the earlier move')
print('decoration seating: rigid corrections, no buried clusters, native XY preservation and fail-closed terrain passed')

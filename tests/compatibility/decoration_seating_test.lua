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
for n=1,200 do
 local components={stone(0,n%21-5,10+n%7),stone(20,n%29-8,12+n%9)}
 local height=function(x,y)return (x+y+n)%7 end
 local options={tile=1,retain_existing_visibility=true,allowed=function()return false end}
 local rejected,_,terrain_proposal=S.Plan(components,height,options)
 options.allowed=nil
 local reference=S.Plan(components,height,options)
 assert(not rejected,'collision veto must still reject the actual proposal')
 assert((not reference and not terrain_proposal) or (reference and terrain_proposal
  and reference.dx==terrain_proposal.dx and reference.dy==terrain_proposal.dy and reference.dz==terrain_proposal.dz),
  'terrain-only proposal differs from the previous independent planner call')
end
-- Native rock meshes often extend below their origin. Visibility retention must
-- compare with the already visible formation, not require exposing half of a
-- large buried foundation while also grounding its detached small stone.
local partial={stone(0,-320,580),stone(20,74,124)}
p=S.Plan(partial,function()return 0 end,{tile=1,retain_existing_visibility=true})
assert(p and p.dz==-74,'partly buried foundation must not prevent a safe minimal seating')
assert(260+p.dz>=260/2 and 198+p.dz>=124/2,'retain at least half each originally visible component')
p=S.Plan({stone(0,-9,10),stone(20,20,10)},function()return 0 end,{tile=1,retain_existing_visibility=true})
assert(not p,'an already small exposed tip must not be buried to repair another component')
assert(S.FlatTranslationImpossible({stone(0,0,10),stone(20,20,10)},0),
 'flat terrain cannot repair a rigid group by changing only XY')
assert(not S.FlatTranslationImpossible({stone(0,20,10)},0),'a plain floating rock still has a valid rigid Z interval')
assert(S.MaximumVisibleDrop({stone(0,0,10),stone(20,20,10)},function()return 0 end)==5,
 'object support search must remain possible within visibility budget even when terrain-only seating is impossible')
p=S.Plan({stone(0,-.5,10)},function()return 0 end,{tile=1})
assert(p and p.dz==0,'an already supported visible rock may keep its pose')
p=S.Plan({stone(0,-9.5,10)},function()return 0 end,{tile=1})
assert(p and p.dz==5,'positive fractional visibility bound must round up inside the feasible interval')
for n=1,120 do
 local components={stone(0,n%19-8,10+n%7),stone(20,n%23-5,12+n%5)}
 local h=n%11-5
 local opts={tile=1,allow_xy=true,rings=2,retain_existing_visibility=true,
  allowed=function(dx,dy)return dx==1 and dy==1 end}
 local ordinary=S.Plan(components,function()return h end,opts)
 opts.flat_height=function()return h end
 local fast=S.Plan(components,function()return h end,opts)
 assert((not ordinary and not fast) or (ordinary and fast and ordinary.dx==fast.dx and ordinary.dy==fast.dy and ordinary.dz==fast.dz),
  'certified flat height must preserve the complete planner result')
 opts.flat_height=function()return nil end
 local fallback=S.Plan(components,function(x,y)return x>20 and y>0 and 2 or h end,opts)
 opts.flat_height=nil
 local reference=S.Plan(components,function(x,y)return x>20 and y>0 and 2 or h end,opts)
 assert((not fallback and not reference) or (fallback and reference and fallback.dx==reference.dx and fallback.dy==reference.dy and fallback.dz==reference.dz),
  'nonflat/unknown certificate must retain the full original vertex search')
end
local fixed=stone(0,20,10);fixed.required_visibility=5
p=S.Plan({fixed},function()error('already fixed visibility and certified flat geometry need no vertex queries')end,
 {tile=1,retain_existing_visibility=true,flat_height=function()return 0 end})
assert(p and p.dz==-20,'flat certificate removes redundant height queries without changing seating')
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
local validator={SurfaceSupportSummary=function()return {eligible=1,unresolved=0}end,
 SeatingEvidence=function()return {{obj=obj,confirmed=true,bounds={20,0,20,22,2,30},components={stone(20,20,10)}}}end,
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
validator.SeatingEvidence=old_evidence
validator.SeatingPlacementClear=function()return false end
validator.SeatingVerticalContact=function()return -5 end
success=true;pos=point(20,0,20)
report=S.Run(map)
assert(report.corrected==1 and select(3,pos:xyz())==15 and report.records[1].support=='rendered rock',
 'verified cliff contact must stop a native stone before the terrain-only proposal')
annotation=obj.SuperBigMapSupportRepair
success=false;pos=point(20,0,20);before=pos
report=S.Run(map)
assert(report.corrected==0 and report.rejected==1 and pos==before and obj.SuperBigMapSupportRepair==annotation,
 'continuous contact proposal does not replace independent rooted-support verification')
validator.SeatingVerticalContact=function()return -999 end
success=true;pos=point(20,0,20)
report=S.Run(map)
assert(report.corrected==0 and report.rejected==1,'object support proposal may not lower past the visible terrain bound')
validator.SeatingVerticalContact=function()return nil,'no rendered support along vertical move' end
pos=point(20,0,20);report=S.Run(map)
assert(report.corrected==1 and select(3,pos:xyz())==0,'complete clear sweep allows a terrain seating proposal')
validator.SeatingVerticalContact=function()return nil,'unknown swept neighbour' end
pos=point(20,0,20);report=S.Run(map)
assert(report.corrected==0 and report.rejected==1,'unknown swept geometry must still veto movement')
print('decoration seating: rigid corrections, no buried clusters, native XY preservation and fail-closed terrain passed')
validator.SeatingEvidence=function()return {}end
validator.SurfaceSupportSummary=function()return {eligible=1,unresolved=1}end
report=S.Run(map)
assert(report.error and report.support.unresolved==1,'unattempted inconclusive rock must block readiness')
validator.SurfaceSupportSummary=function()return nil,'support evidence missing'end
report=S.Run(map)
assert(report.error=='support evidence missing','missing all-rock census must block readiness')
validator.SurfaceSupportSummary=function()return {eligible=1,unresolved=0}end
validator.SeatingEvidence=old_evidence
local axis,angle=point(0,0,4096),0
obj.GetAxis=function()return axis end;obj.GetAngle=function()return angle end
obj.SetAxisAngle=function(_,a,b)axis,angle=a,b end
validator.SeatingPlacementClear=function(_,_,_,rotation)return rotation~=nil end
validator.RotationSeatingEvidence=function(_,entry,degrees)
 return {components=entry.components,bounds=entry.bounds,axis=point(4096,0,0),angle=degrees*60,degrees=degrees}
end
validator.SeatingCurrentPoseClear=function()return true end
validator.SeatingRotationMatches=function()return true end
local before_axis,before_angle=axis,angle
pos=point(20,0,20);success=false;before=pos
report=S.Run(map)
assert(report.corrected==0 and pos==before and axis==before_axis and angle==before_angle,
 'failed post-tilt proof must restore the complete position and orientation')
pos=point(20,0,20);success=true;report=S.Run(map)
assert(report.corrected==1 and angle==60 and report.records[1].tilt_degrees==1,
 'accepted rigid tilt must be independently verified and explicitly recorded')
validator.SeatingCurrentPoseClear=function()return false end
before_axis,before_angle=axis,angle;pos=point(20,0,20);before=pos
report=S.Run(map)
assert(report.corrected==0 and pos==before and axis==before_axis and angle==before_angle,
 'native-pose collision rejection must restore both position and rotation before support verification')

-- A confirmed gap can disagree with the coarse vertex-height proposal near
-- a steep integer terrain boundary. A no-op must reach exact face refinement.
local refinements=0
validator.SeatingEvidence=function()
 return {{obj=obj,confirmed=true,bounds={20,0,20,22,2,30},components={stone(20,0,10)}}}
end
validator.RefineSeatingComponents=function(_,entry)
 refinements=refinements+1;entry.components[1].clearance={3,10};return true
end
validator.SeatingPlacementClear=function()return true end
validator.SeatingCurrentPoseClear=function()return true end
success=true;pos=point(20,0,20)
report=S.Run(map)
assert(refinements==1 and report.corrected==1 and report.rejected==0 and select(3,pos:xyz())==17,
 'zero-distance proposal prevented a confirmed floating rock from reaching refined seating')
print('confirmed-gap no-op: face refinement runs and actual positive validation still gates the correction')

-- Prefer a safe in-place tilt over an earlier tilt's exhaustive XY search.
-- Both choices still require the actual-pose verifier, not a planner verdict.
validator.SeatingEvidence=old_evidence
validator.RefineSeatingComponents=nil
validator.SeatingVerticalContact=function()return nil,'unknown swept neighbour'end
local tilted_queries=0
validator.SeatingPlacementClear=function(_,_,bounds,rotation)
 if not rotation then return false end
 tilted_queries=tilted_queries+1
 return rotation.degrees==2 or bounds[1]~=20 or bounds[2]~=0
end
pos=point(20,0,20);success=true;report=S.Run(map)
assert(report.corrected==1 and report.records[1].tilt_degrees==2 and tilted_queries==9,
 'a blocked shallow tilt searched XY before the next safe in-place orientation')
assert(select(1,pos:xyz())==20 and select(2,pos:xyz())==0,'in-place tilt changed authored XY')

-- The selected native neighbour region already covers sixteen height tiles.
-- A safe same-orientation placement in its outer half must be tried before
-- falling back to tilts, without going beyond the inspected region.
local rotations=0;local old_rotation=validator.RotationSeatingEvidence
validator.RotationSeatingEvidence=function(...)rotations=rotations+1;return old_rotation(...)end
validator.SeatingPlacementClear=function(_,_,bounds,rotation)
 return not rotation and bounds[1]==1020 and bounds[2]==0
end
pos=point(20,0,20);report=S.Run(map)
assert(report.corrected==1 and rotations==0 and select(1,pos:xyz())==1020,
 'native translation failed to use the safe outer half of its inspected neighbourhood')
local coarse_queries=0
validator.SeatingPlacementClear=function(_,_,bounds,rotation)
 coarse_queries=coarse_queries+1
 assert(bounds[1]>=0 and bounds[2]>=0 and bounds[1]<=1620 and bounds[2]<=1600,
  'coarse proposal escaped the original inspected neighbourhood')
 return not rotation and bounds[1]==1220 and bounds[2]==1200
end
pos=point(20,0,20);report=S.Run(map)
assert(report.corrected==1 and rotations==0 and coarse_queries<85,
 'coarse search did not find a fully guarded rigid pose before the fine fallback')
assert(select(1,pos:xyz())==1220 and select(2,pos:xyz())==1200,'coarse proposal was not independently committed')
print('coarse rigid search: bounded proposal, exact fine fallback and actual-pose verification retained')

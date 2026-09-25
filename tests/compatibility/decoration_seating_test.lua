SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_seating.lua')
local S=SuperBigMap.DecorationSeating
do
 local vertices=setmetatable({},{__index=function()error('redundant vertex traversal after exact clearance')end})
 local component={vertices=vertices,height=20,clearance={5,25}}
 local p=S.Plan({component},function()error('redundant height query')end,{
  tile=1,allow_xy=true,offsets={{1,0}},retain_existing_visibility=true,
  clearance=function()return 5,25 end,
  flat_height=function()error('unused flat fallback was evaluated')end,
  allowed=function(dx)return dx~=0 end})
 assert(p and p.dx==1 and p.dz==-5,'lazy bounding box changed the exact-clearance proposal')
end
do
 local old=SuperBigMap.DecorationGeometry;local calls=0;local level=8
 SuperBigMap.DecorationGeometry={FoundationTranslationClearance=function(_,_,_,_,budget)
  calls=calls+1;return level<=budget and level or nil
 end}
 local cache,f={},{}
 assert(not S.CachedFoundationClearance(cache,f,1,2,nil,5) and calls==1)
 assert(not S.CachedFoundationClearance(cache,f,1,2,nil,4) and calls==1,'smaller rejected budget retraced')
 assert(S.CachedFoundationClearance(cache,f,1,2,nil,9)==8 and calls==2,'larger budget failed to retry')
 assert(S.CachedFoundationClearance(cache,f,1,2,nil,10)==8 and calls==2,'exact candidate retraced')
 assert(not S.CachedFoundationClearance(cache,f,1,2,nil,7) and calls==2,'cached gap exceeded new budget')
 level=3
 assert(S.CachedFoundationClearance({},f,1,2,nil,9)==3 and calls==3,'cache escaped its terrain transaction')
 SuperBigMap.DecorationGeometry=old
end
for n=1,100 do
 local points={}
 for i=1,200 do points[i]={i,i%17,(i*37+n)%499}end
 table.sort(points,function(a,b)return a[3]<b[3]end)
 local function height(x,y)return (x*7+y*13+n)%41-20 end
 local low,high=math.huge,-math.huge
 for _,p in ipairs(points)do local d=p[3]-height(p[1]+3,p[2]-4);low=math.min(low,d);high=math.max(high,d)end
 local a,b=S.BoundedClearance(points,height,-20,20,3,-4)
 assert(a==low and b==high,'bounded clearance changed complete vertex extrema')
end
local calls=0;local ordered={}
for i=1,1000 do ordered[i]={0,0,i}end
local lo,hi=S.BoundedClearance(ordered,function()calls=calls+1;return 0 end,-2,2,0,0)
assert(lo==1 and hi==1000 and calls<10,'certified flat interval did not prune redundant vertex queries')
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
local small,main=stone(0,0,2),stone(20,20,80)
small.volume=1;main.volume=100
S.MarkSmallFragments({small,main})
assert(small.allow_burial and not main.allow_burial,'fragment policy must preserve the main formation')
p=S.Plan({small,main},function()return 0 end,{tile=1,retain_existing_visibility=true})
assert(p and p.dz==-20,'tiny fragment should not force a rotation or block safe main-rock seating')
assert(not S.FlatTranslationImpossible({small,main},0),'flat preflight ignored permitted small-fragment burial')
small.volume=12.5;S.MarkSmallFragments({small,main})
assert(small.allow_burial and not main.allow_burial,'a one-eighth attached chip should not constrain the dominant shape')
small.volume=16;S.MarkSmallFragments({small,main})
assert(not small.allow_burial,'a substantial secondary rock cannot be buried as a small chip')
small.volume=1;S.MarkSmallFragments({small,main})
assert(S.MaximumVisibleDrop({small,main},function()return 0 end)==60,'small fragment constrained the main-rock visibility budget')
local many={main}
for i=1,20 do local c=stone(i,0,2);c.volume=1;many[#many+1]=c end
S.MarkSmallFragments(many)
for _,c in ipairs(many)do assert(not c.allow_burial,'many small pieces exceeded the combined burial budget')end
local alternate=stone(0,0,2);alternate.volume=1;alternate.lod=1
S.MarkSmallFragments({main,alternate})
assert(not alternate.allow_burial,'an entire alternate LOD was classified as a small fragment')
small.volume=nil;S.MarkSmallFragments({small,main})
assert(not small.allow_burial and not main.allow_burial,'unknown size must preserve all visibility constraints')
small.volume=1;small.burial_owner='separate';main.burial_owner='main'
S.MarkSmallFragments({small,main})
assert(not small.allow_burial and not main.allow_burial,'a separate small rock became a buryable attached fragment')
local root,upper=stone(0,10,10),stone(0,30,10);upper.terrain_root=false
p=S.Plan({root,upper},function()return 0 end,{tile=1})
assert(p and p.dz==-10,'rigid dependent forced its supported root into the terrain')
local open=stone(0,-10,100)
open.foundation={gap=20}
p=S.Plan({open},function()return 0 end,{tile=1,retain_existing_visibility=true})
assert(p and p.dz==-22,'an already grounded component left its open foundation exposed')
local too_low=stone(0,-10,20);too_low.foundation={gap=20}
assert(not S.Plan({too_low},function()return 0 end,{tile=1,retain_existing_visibility=true}),
 'foundation correction erased the main visible formation')
do
 local c=stone(0,0,100);c.foundation={gap=20,maximum_z=20}
 local options={tile=1,allow_xy=true,offsets={{1,0}},allowed=function(dx)return dx==1 end,
  clearance=function()return 0,100,0 end}
 local old=SuperBigMap.DecorationGeometry
 SuperBigMap.DecorationGeometry={FoundationTranslationClearance=function()error('flat rim proof was redundantly traced')end}
 local flat=S.Plan({c},function()return 0 end,options)
 assert(flat and flat.dx==1 and flat.dz==-22,'certified flat destination changed the seating interval')
 local traced=0
 SuperBigMap.DecorationGeometry.FoundationTranslationClearance=function()traced=traced+1;return 20 end
 options.clearance=function()return 0,100 end
 local complete=S.Plan({c},function()return 0 end,options)
 assert(traced==1 and complete.dx==flat.dx and complete.dz==flat.dz,'nonflat destination lost its complete edge proof')
 SuperBigMap.DecorationGeometry=old
end
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

local function point(x,y,z)return {xyz=function()return x,y,z end,xy=function()return x,y end}end
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
local sector={area={minx=function()return 0 end,miny=function()return 0 end,maxx=function()return 100000 end,maxy=function()return 100000 end}}
globals.GetMapSectorXY=function()return sector end
SuperBigMap={Engine={Global=function(n)return globals[n]end,MapDataEnvironment=function()return 'Surface'end},DecorationValidation=validator}
dofile('Code/sbm_decoration_seating.lua');S=SuperBigMap.DecorationSeating
SuperBigMap.TerrainCopy={VerifyNativeHeightReference=function()return true end,ReleaseNativeHeightReference=function()end} -- no native grid: strict seating
local map={City={},mapdata={},GetMapSize=function()return 100000,100000 end}
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
local rotations=0
validator.RotationSeatingEvidence=function()rotations=rotations+1;error('tilting is forbidden')end
validator.SeatingCurrentPoseClear=function()return true end
validator.SeatingRotationMatches=function()return true end
local before_axis,before_angle=axis,angle
pos=point(20,0,20);success=false;before=pos
report=S.Run(map)
assert(report.corrected==0 and pos==before and axis==before_axis and angle==before_angle,
 'failed seating must retain the complete position and orientation')
pos=point(20,0,20);success=true;report=S.Run(map)
assert(report.corrected==0 and report.rejected==1 and axis==before_axis and angle==before_angle and rotations==0,
 'unseatable formation must fail without attempting any added tilt')
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

-- Even an available rotation-based solution must never be attempted.
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
assert(report.corrected==0 and report.rejected==1 and tilted_queries==0 and rotations==0,
 'an unsafe placement must not invoke the removed tilt fallback')
assert(select(1,pos:xyz())==20 and select(2,pos:xyz())==0,'failed placement changed authored XY')

-- The selected native neighbour region already covers sixteen height tiles.
-- A safe same-orientation placement in its outer half must be tried before
-- rejecting the placement, without going beyond the inspected region.
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
assert(report.corrected==1 and rotations==0 and coarse_queries<300,
 'nearest-first search escaped the bounded candidate set')
assert(select(1,pos:xyz())==1220 and select(2,pos:xyz())==1200,'coarse proposal was not independently committed')
print('coarse rigid search: bounded proposal, exact fine fallback and actual-pose verification retained')

local offsets=S.NearbyOffsets(100,16);local seen,last={},0
for _,d in ipairs(offsets)do
 local distance=d[1]*d[1]+d[2]*d[2];local key=d[1]..':'..d[2]
 assert(distance>=last and not seen[key],'nearby lattice is not unique and nearest-first')
 seen[key]=true;last=distance
end
assert(#offsets==1088 and offsets==S.NearbyOffsets(100,16),'immutable offset lattice was not reused')
validator.SeatingPlacementClear=function(_,_,b)
 return (b[1]==220 and b[2]==200) or (b[1]==420 and b[2]==0)
end
pos=point(20,0,20);report=S.Run(map)
assert(report.corrected==1 and select(1,pos:xyz())==220 and select(2,pos:xyz())==200,
 'farther compass location won over nearer safe diagonal')
local old_sector=sector
sector={area={minx=function()return 0 end,miny=function()return 0 end,maxx=function()return 200 end,maxy=function()return 200 end}}
pos=point(20,0,20);before=pos;report=S.Run(map)
assert(report.corrected==0 and pos==before,'native correction escaped its original sector')
sector=old_sector
map.City=nil;report=S.Run(map)
assert(report.corrected==0,'unknown sector identity authorized horizontal relocation')
map.City={}
print('vanilla proximity: nearest sampled safe translation wins; cross-sector and unknown-sector moves fail closed')

-- A valid nonzero terrain lowering rejected by collision must not trigger a
-- second full mesh/heightfield intersection pass for that identical pose.
validator.SeatingEvidence=old_evidence
validator.SeatingPlacementClear=function()return false end
validator.RefineSeatingComponents=function()error('redundant collision-veto terrain refinement')end
pos=point(20,0,20);report=S.Run(map)
assert(report.corrected==0 and report.rejected==1 and not report.error,
 'collision rejection repeated terrain refinement or swallowed the failure')

-- A rigid support stack is one transaction: refusal or a failed independent
-- proof for either member must restore every member, including annotations.
local rider_pos=point(20,0,40)
local rider={GetVisualPos=function()return rider_pos end,GetPos=function()return rider_pos end,
 GetPosXYZ=function()return rider_pos:xyz()end,SetPos=function(_,p)rider_pos=p end,GetEntity=function()return 'Rider'end}
validator.SeatingEvidence=function()
 local e=old_evidence();e[1].foundation=true;return e
end
validator.SeatingGroup=function(_,entry)
 entry.members={{obj=obj,foundation=true,bounds=entry.bounds},{obj=rider,bounds={20,0,40,22,2,50}}}
 entry.group_members={[obj]=true,[rider]=true};return entry
end
validator.SeatingPlacementClear=function()return true end
for _,fault in ipairs({'child annotation','child verification'})do
 pos=point(20,0,20);rider_pos=point(20,0,40)
 local old_root,old_rider=pos,rider_pos
 obj.SuperBigMapSupportRepair=nil;rider.SuperBigMapSupportRepair=nil
 validator.RecordSeating=function(_,o)
  o.SuperBigMapSupportRepair={test=true}
  return o~=rider or fault~='child annotation'
 end
 validator.Run=function()
  obj.SuperBigMapSupportValidation={current_geometry_status='valid',placement_repaired=true}
  rider.SuperBigMapSupportValidation={current_geometry_status='inconclusive'}
  return {}
 end
 report=S.Run(map)
 assert(report.corrected==0 and pos==old_root and rider_pos==old_rider,'partial rigid stack committed: '..fault)
 assert(not report.error and report.rejections[1]
  and report.rejections[1].reason==(fault=='child annotation' and 'correction evidence was refused'
   or 'independent rendered-placement verification failed'),
  'fixture did not reach its intended child transaction fault: '..fault)
 assert(not obj.SuperBigMapSupportRepair and not rider.SuperBigMapSupportRepair,'rigid stack rollback leaked repair metadata')
end
print('rigid support transactions: child refusal and failed proof restore the whole stack')

pos=point(20,0,20);rider_pos=point(20,0,40)
validator.SeatingPlacementClear=function(_,_,b)return b[1]==220 and b[2]==200 end
validator.RecordSeating=function()return true end
validator.Run=function()
 obj.SuperBigMapSupportValidation={current_geometry_status='valid',placement_repaired=true}
 rider.SuperBigMapSupportValidation={current_geometry_status='valid',placement_repaired=true}
 return {}
end
report=S.Run(map)
assert(report.corrected==2 and report.rejected==0 and select(1,pos:xyz())==220
 and select(2,pos:xyz())==200 and select(1,rider_pos:xyz())==220 and select(2,rider_pos:xyz())==200,
 'rigid group skipped the near two-tile pocket and searched only a coarser lattice')
print('rigid support search: nearest local two-tile pocket precedes the coarse fallback')

pos=point(20,0,20);rider_pos=point(20,0,40)
validator.SeatingPlacementClear=function(_,_,b)return b[1]==2220 and b[2]==2000 end
report=S.Run(map)
assert(report.corrected==2 and report.rejected==0 and select(1,pos:xyz())==2220
 and select(2,pos:xyz())==2000 and select(1,rider_pos:xyz())==2220,
 'rigid group discarded a safe pocket between distant coarse-lattice candidates')
print('rigid support search: finer fallback fills coarse gaps without extending the search radius')

pos=point(20,0,20);rider_pos=point(20,0,40)
validator.SeatingPlacementClear=function(_,_,b)return b[1]==2220 and b[2]==2100 end
report=S.Run(map)
assert(report.corrected==2 and report.rejected==0 and select(2,pos:xyz())==2100
 and select(2,rider_pos:xyz())==2100,'rigid stack missed a one-tile pocket after both coarser lattices failed')
print('rigid support search: one-tile fallback retains the shared stack pose')

-- Two floating open-base rocks that rest only on each other (30S146E Rocks_03_66
-- pairs) are seated once as one rigid group. The partner's own stale evidence
-- entry must not move it a second time after the group transaction committed.
pos=point(20,0,20);rider_pos=point(20,0,40)
validator.SeatingPlacementClear=function()return true end
validator.SeatingEvidence=function()
 local e=old_evidence();e[1].foundation=true
 e[2]={obj=rider,confirmed=true,foundation=true,bounds={20,0,40,22,2,50},components={stone(20,20,10)}}
 return e
end
local grouped_calls=0
validator.SeatingGroup=function(_,entry)
 if entry.obj~=obj then return nil end
 grouped_calls=grouped_calls+1
 entry.members={{obj=obj,foundation=true,bounds=entry.bounds},{obj=rider,foundation=true,bounds={20,0,40,22,2,50}}}
 entry.group_members={[obj]=true,[rider]=true};return entry
end
report=S.Run(map)
assert(grouped_calls==1 and report.corrected==2 and report.rejected==0 and not report.error,
 'floating open-base pair was not committed as one rigid group')
assert(select(3,pos:xyz())==0 and select(3,rider_pos:xyz())==20,
 'grouped open-base partner moved again from its own stale evidence entry')
print('floating open-base pair: one shared rigid move, no second move of the partner')

-- NearbyOffsets sorts by packed integer keys; the order must equal the original
-- squared-distance, then x, then y comparator order, with integer coordinates.
local function comparator_offsets(step,rings)
 local result={}
 for x=-rings,rings do for y=-rings,rings do if x~=0 or y~=0 then result[#result+1]={x*step,y*step} end end end
 table.sort(result,function(a,b)
  local da,db=a[1]*a[1]+a[2]*a[2],b[1]*b[1]+b[2]*b[2]
  if da~=db then return da<db end
  if a[1]~=b[1] then return a[1]<b[1] end
  return a[2]<b[2]
 end)
 return result
end
for _,c in ipairs({{100,1},{100,8},{200,16},{400,32},{3,5}}) do
 local a,b=comparator_offsets(c[1],c[2]),S.NearbyOffsets(c[1],c[2])
 assert(#a==#b,'offset count changed')
 for i=1,#a do assert(a[i][1]==b[i][1] and a[i][2]==b[i][2] and math.type(a[i][1])==math.type(b[i][1]),'offset order changed at '..i) end
end
print('nearby offsets: packed-key order equals the comparator order')

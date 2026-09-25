-- End-to-end mocked native API: support graph, source capture, transform,
-- missing geometry and load-style reconstruction, with mutation tripwires.
local function point(x,y,z)
 return {x=function()return x end,y=function()return y end,z=function()return z end,
  xy=function()return x,y end,
  xyz=function()return x,y,z end}
end
local function box(x0,y0,z0,x1,y1,z1)
 return {minx=function()return x0 end,miny=function()return y0 end,minz=function()return z0 end,
  maxx=function()return x1 end,maxy=function()return y1 end,maxz=function()return z1 end}
end
local globals={point=point,box=box,guim=1,const={HeightTileSize=1},EntitySurfaces={TerrainHole=8},
	GetRenderingMeshLods=function()return {get=function()return nil end}end,
 IsValid=function(o)return not o.deleted end,GetPreciseTicks=function()return 0 end,
 HasAnySurfaces=function()return false end,print=function()end,
 EntityData={Rock={editor_category='StonesRocksCliffs'},Unknown={editor_category='StonesRocksCliffs'}},
 terrain={GetHeight=function()return 0 end,GetMinMaxHeight=function()return 0,0 end}}
SuperBigMap={Engine={Global=function(n)return globals[n]end},Config={},ObjectClone={
 ObjectScalesWithTerrain=function()return true end,ShouldSkipObject=function()return false end,
 IsImportantSectorObject=function()return false end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
local verts={{-10,-10,0},{10,-10,0},{10,10,0},{-10,10,0},{-10,-10,20},{10,-10,20},{10,10,20},{-10,10,20}}
local triangles={{1,2,3},{1,3,4},{5,7,6},{5,8,7},{1,5,6},{1,6,2},{4,3,7},{4,7,8},{1,4,8},{1,8,5},{2,6,7},{2,7,3}}
local component={bounds={-10,-10,0,10,10,20},samples=verts,triangles=triangles,vertices={1,2,3,4,5,6,7,8}}
local geometry={vertices=verts,components={component},animated=false}
local asset={complete=true,parts={{lod=0,mesh={path='rock',geometry=geometry}}}}
function G.Entity(entity)return entity=='Unknown' and {complete=false,parts={},reason='missing'} or asset end
dofile('Code/sbm_decoration_validation.lua')
local V=SuperBigMap.DecorationValidation
local list={};local map={}
function map:GetMapSize()return 10000,10000 end
function map:MapForEach(_,_,fn)for _,o in ipairs(list)do if not o.deleted then fn(o)end end end
local function object(handle,x,y,z,entity)
 local o={handle=handle,x=x,y=y,z=z,entity=entity or 'Rock',class='Rock',scale=100}
 function o:GetEntity()return self.entity end
 function o:GetState()return 0 end
 function o:GetParent()return self.parent end
 function o:GetVisualPos()return point(self.x,self.y,self.z)end
 o.GetPos=o.GetVisualPos
 function o:GetWorldScale()return self.scale end
 function o:IsValidZ()return true end
 function o:GetRelativePoint(p)local a,b,c=p:xyz();local s=self.scale/100.0;return point(self.x+a*s,self.y+b*s,self.z+c*s)end
 function o:GetLocalPoint(p)local a,b,c=p:xyz();local s=100.0/self.scale;return point((a-self.x)*s,(b-self.y)*s,(c-self.z)*s)end
 function o:GetClipPlane()return 0 end
 function o:GetTerrainDistortedSupport()return 'disabled' end
 function o:GetObjectBBox()local s=self.scale/100.0;return box(self.x-10*s,self.y-10*s,self.z,self.x+10*s,self.y+10*s,self.z+20*s)end
 function o:SetPos()error('validator must never move objects')end
 function o:SetScale()error('validator must never resize objects')end
 function o:SetRenderingMeshLods()error('validator must never change rendering')end
 return o
end
local function capture()
 V.BeginCapture(map,map)
 for _,o in ipairs(list)do V.Capture(map,o,false,false)end
 V.FinishCapture(map)
end
local lower=object(1,100,100,0);local upper=object(2,100,100,20)
list={lower,upper};capture()
local report=V.Validate(map,'native stack')
assert(report.valid==2 and report.confirmed_defect==0,'legitimate stack roots through lower rock')
assert(upper.SuperBigMapSupportBaseline.components['0:rock:1'].supported)
-- A newly available terrain witness does not erase a STILL PRESENT native
-- object contact. The fast terrain path must explicitly verify the saved edge.
globals.terrain.GetHeight=function()return 20 end
globals.terrain.GetMinMaxHeight=function()return 20,20 end
report=V.Validate(map,'additional terrain witness')
assert(report.valid==2,'fast terrain witness discarded intact native stack contact')
globals.terrain.GetHeight=function()return 0 end
globals.terrain.GetMinMaxHeight=function()return 0,0 end
upper.z=32;report=V.Validate(map,'known split column')
assert(report.confirmed_defect==1 and upper.SuperBigMapSupportValidation.status=='confirmed defect')
upper.z=20;upper.x=115;capture();report=V.Validate(map,'overhang')
assert(report.valid==2,'legitimate overhang has a real contact, not terrain-only support')
report=V.Recheck(map,'load');assert(report.valid==2,'load-style index rebuild retains baseline')
local missing=object(3,500,500,0,'Unknown');list[#list+1]=missing
capture();report=V.Validate(map,'missing asset')
assert(missing.SuperBigMapSupportValidation.status=='inconclusive')
local child=object(4,900,900,200);child.parent=lower;list[#list+1]=child
capture();report=V.Validate(map,'attachment')
assert(child.SuperBigMapSupportValidation.status=='valid')
child.parent=nil;report=V.Validate(map,'broken attachment')
assert(child.SuperBigMapSupportValidation.status=='confirmed defect')
-- A floating cycle cannot prove its own support.
list={object(5,1000,1000,200),object(6,1000,1000,220)};capture();report=V.Validate(map,'floating stack')
assert(report.valid==0,'unrooted stack is not supported')
-- An unrecorded old save has no proof of native support preservation.
list={object(7,100,100,0)};report=V.Recheck(map,'old save')
assert(report.inconclusive==1 and not report.instances[1].native_baseline)
-- Real cosmetic CObjects may have no engine handle. Support identities must not
-- alias different rocks merely because both have nil handles.
local a,b=object(nil,100,100,0),object(nil,100,100,20)
list={a,b};capture();report=V.Validate(map,'handle-less native stack')
assert(report.valid==2 and report.instances[1].id~=report.instances[2].id)
report=V.Recheck(map,'unchanged switch')
assert(report.valid==2 and report.validation_profile.nodes==0,'unchanged supported instances reuse witnesses')
a.z=-50;report=V.Recheck(map,'support moved away')
assert(b.SuperBigMapSupportValidation.status=='confirmed defect','dependent upper rock must recheck')
list={object(nil,300,300,0)};V.Clear(map);capture();V.Validate(map)
globals.terrain.GetHeight=function()return -100 end
globals.terrain.GetMinMaxHeight=function()return -100,-100 end
report=V.Recheck(map,'terrain support removed')
assert(report.confirmed_defect==1,'unchanged explicit pose must still recheck lost terrain witness')
globals.terrain.GetHeight=function()return 0 end
globals.terrain.GetMinMaxHeight=function()return 0,0 end
-- A top-up prefab group records its native stack BEFORE similarity.
local c,d=object(nil,500,500,0),object(nil,500,500,20)
list={c,d};V.BeginCapture(map,map);V.CaptureGroup(map,list)
c.scale=200;d.scale=200;d.z=40
report=V.Validate(map,'top-up similarity')
assert(report.valid==2,'native prefab support survives a uniform group similarity')
-- Simulate inactive-map serialization dropping arbitrary cosmetic-object fields.
c.SuperBigMapDecorEnginePass=true;V.Validate(map,'persist explicit top-up policy')
local c_id,d_id=c.SuperBigMapSupportId,d.SuperBigMapSupportId
c.SuperBigMapSupportBaseline=nil;c.SuperBigMapSupportId=nil
c.SuperBigMapDecorEnginePass=nil
d.SuperBigMapSupportBaseline=nil;d.SuperBigMapSupportId=nil
V.Clear(map);report=V.Recheck(map,'value-only ledger restore')
assert(report.valid==2 and c.SuperBigMapSupportId==c_id and d.SuperBigMapSupportId==d_id)
assert(c.SuperBigMapDecorEnginePass==true and d.SuperBigMapDecorEnginePass~=true,'restore known top-up policy without granting native stones XY permission')
-- Ambiguous duplicate poses must not be guessed when rebinding source support.
local e,f=object(nil,800,800,0),object(nil,800,800,0)
list={e,f};capture();V.Validate(map)
e.SuperBigMapSupportBaseline=nil;e.SuperBigMapSupportId=nil
f.SuperBigMapSupportBaseline=nil;f.SuperBigMapSupportId=nil
V.Clear(map);report=V.Recheck(map,'ambiguous ledger entry')
assert(report.inconclusive==2,'duplicate placement cannot imply native identity')
local hole=object(50,200,200,0,'Unknown')
function hole:GetObjectBBox()return box(0,0,-100,1000,1000,100)end
globals.HasAnySurfaces=function(o)return o==hole end
globals.ForEachSurface=function(o,flag,fn)
 assert(o==hole and flag==8);fn(point(200,200,0),point(240,200,0),point(200,240,0))
end
local outside=object(51,500,500,0);local inside=object(52,205,205,0);inside.scale=10
list={hole,outside,inside};capture();report=V.Validate(map,'exact native terrain cut')
assert(outside.SuperBigMapSupportValidation.status=='valid','whole wonder bbox must not hide real floor outside native cut triangles')
assert(inside.SuperBigMapSupportValidation.status=='inconclusive','height field inside a terrain cut is not visible support')
do
 local enabled=SuperBigMap.Config.DECORATION_VALIDATION_ENABLED
 local grounding=SuperBigMap.RockGrounding
 SuperBigMap.Config.DECORATION_VALIDATION_ENABLED=false
 SuperBigMap.RockGrounding={Eligible=function(o)return o~=hole end}
 -- Deliberately put the hole LAST. A one-pass nomination must not mark the
 -- first rock grounded before discovering this later terrain-cutting object.
 list={inside,outside,hole}
 V.WithCorrectionEvidence(map,'Surface',function()
  local result=assert(V.SurfaceSupportSummary(map))
  assert(result.eligible==2 and result.unresolved==1,
   'fast correction census accepted the invisible floor under a terrain hole')
  assert(outside.SuperBigMapSupportValidation.current_geometry_status=='valid',
   'conservative hole bounds prevented exact visible-floor validation outside the cut')
  return {}
 end)
 SuperBigMap.Config.DECORATION_VALIDATION_ENABLED=enabled
 SuperBigMap.RockGrounding=grounding
end
globals.HasAnySurfaces=function()return false end
local subtle=object(53,1200,1200,0);list={subtle};capture();V.Validate(map)
subtle.z=0.5;report=V.Validate(map,'sub-tile floating defect')
assert(report.valid==0,'half a tile above ground must never be accepted by a full-tile contact tolerance')
-- Projection volumes (including unexplored-sector overlays) are neither solid
-- supports nor free-floating rendered triangles.
globals.IsKindOf=function(o,kind)return kind=='Decal' and o.projected or false end
local projected=object(54,1400,1400,20);projected.projected=true
local elevated=object(55,1400,1400,20)
list={projected,elevated};capture();report=V.Validate(map,'projection is not solid support')
assert(projected.SuperBigMapSupportValidation.status=='inconclusive')
assert(elevated.SuperBigMapSupportValidation.status=='confirmed defect')
-- Objects spawned after capture may support a component. A missing entry must
-- never be treated as proof of empty space, even if its mesh is unavailable.
local late=object(56,1600,1600,40,'Unknown');local raised=object(57,1600,1600,0)
list={raised};capture();raised.z=40;list[#list+1]=late
report=V.Validate(map,'uncaptured late support')
assert(raised.SuperBigMapSupportValidation.status=='inconclusive')
-- A tight height query could miss neighbouring interpolation nodes. Enlarge it
-- by a grid tile before using its maximum to prove negative terrain separation.
list={object(58,1800,1800,4)};capture()
local queried
globals.terrain.GetMinMaxHeight=function(_,b)queried=b;return 0,b:minx()<=1789 and 4 or 0 end
report=V.Validate(map,'conservative terrain rectangle')
assert(queried:minx()==1789 and list[1].SuperBigMapSupportValidation.status=='inconclusive')
globals.terrain.GetMinMaxHeight=function()return 0,0 end
-- A saved surface has no transient generation milestone, including old saves.
local scheduled_count=0
SuperBigMap.Engine.MapDataEnvironment=function()return 'Surface' end
globals.Sleep=function()end
globals.Maps={[1]=map};map.slot=1
globals.CreateRealTimeThread=function(fn)scheduled_count=scheduled_count+1;fn()end
V.Schedule(map,'not ready');assert(scheduled_count==0,'never check mid-generation')
V.Loaded(map);V.Schedule(map,'loaded surface')
assert(scheduled_count==1 and map.SuperBigMapDecorationValidation.reason=='loaded surface','loaded expanded surfaces must be checked without transient T1 flag')
-- A deliberately corrected native defect is distinguished from preserved
-- native support. Registration alone cannot pass geometry or a different pose.
local repaired=object(99,2500,2500,20);list={repaired};capture();V.Validate(map)
assert(repaired.SuperBigMapSupportValidation.status=='confirmed defect')
repaired.z=0
assert(V.RecordSeating(map,repaired,{2500,2500,20},{2500,2500,0}))
report=V.Validate(map,'recorded correction')
assert(report.valid==1 and report.instances[1].placement_repaired and not report.instances[1].support_preserved)
repaired.z=10;report=V.Validate(map,'correction moved again')
assert(report.confirmed_defect==1 and not report.instances[1].placement_repaired)
repaired.z=0;V.Validate(map)
repaired.SuperBigMapSupportRepair=nil;repaired.SuperBigMapSupportBaseline=nil;V.Clear(map)
report=V.Recheck(map,'corrected save/load')
assert(report.valid==1 and report.instances[1].placement_repaired,'ledger retains correction without rewriting native evidence')
-- Targeted correction verification includes previous support dependents, while
-- unrelated checked instances retain their evidence without a redundant scan.
local root,dependent,unrelated=object(101,3000,3000,0),object(102,3000,3000,20),object(103,5000,5000,0)
list={root,dependent,unrelated};capture();V.Validate(map)
local unchanged=unrelated.SuperBigMapSupportValidation
root.z=-50;report=V.CheckPlacements(map,{{obj=root}},'targeted correction dependency')
assert(dependent.SuperBigMapSupportValidation.status=='confirmed defect')
assert(unrelated.SuperBigMapSupportValidation==unchanged and report.valid==2 and report.confirmed_defect==1)
-- A sub-tile gap can be confirmed only beyond the conservative transform and
-- quantization error, while the XY height query still includes full grid nodes.
globals.const.HeightTileSize=100
list={object(104,6000,6000,20)};capture();report=V.Validate(map,'bounded small-mesh separation')
assert(report.confirmed_defect==1 and report.instances[1].findings[1].separation_error_bound==3)
list[1].z=2.5;report=V.Validate(map,'inside transform uncertainty')
assert(report.inconclusive==1,'unresolved sub-error separation must not be confirmed')
-- A placement guard must use a neighbouring skinned fragment's current bone
-- transform, not its object/rest pose, when ruling out mesh intersections.
local original_entity,original_bone=G.Entity,G.BoneMatrix
local animated_geometry={vertices=verts,components={component},animated=true,rigid_skin=true}
component.bone=1
local animated_asset={complete=true,animated=true,parts={{lod=0,mesh={path='animated',geometry=animated_geometry}}}}
G.Entity=function(entity)if entity=='Animated' then return animated_asset end;return original_entity(entity)end
G.BoneMatrix=function(o)return {origin={o.x+50,o.y,o.z},columns={{1,0,0},{0,1,0},{0,0,1}}}end
globals.EntityData.Animated={editor_category='StonesRocksCliffs'}
globals.GetStateIdx=function(s)return s=='idle' and 0 or 1 end
globals.GetAnimDuration=function()return 10 end
local blocker,candidate=object(105,100,100,0,'Animated'),object(106,300,100,20)
function blocker:GetAnimPhase()return 0 end
list={blocker,candidate};capture();V.Validate(map)
assert(not V.SeatingPlacementClear(map,candidate,{140,90,0,160,110,20}),'posed neighbour must veto collision')
G.Entity,G.BoneMatrix=original_entity,original_bone;component.bone=nil
-- Neither rock's extremal vertices need lie on the other surface. Crossing
-- triangle interiors still form a legitimate rooted connection.
list={object(110,7000,7000,0),object(111,7015,7015,15)}
capture();report=V.Validate(map,'intersecting triangle interiors')
assert(report.valid==2,'full rendered triangle intersection must root the overhang')
local embedded=object(113,7000,7000,5);embedded.scale=25
list={object(114,7000,7000,0),embedded};capture();report=V.Validate(map,'embedded fragment')
assert(report.valid==2,'closed solid containment must root fully embedded fragments')
assert(G.PointInClosedComponent(geometry,component,{0,0,10})==true)
assert(G.PointInClosedComponent(geometry,component,{30,0,10})==false)
local open={bounds=component.bounds,vertices=component.vertices,triangles={triangles[1],triangles[2]}}
assert(G.PointInClosedComponent(geometry,open,{0,0,10})==nil,'open sheet cannot prove containment')
local mirrored=object(112,8000,8000,0)
function mirrored:GetMirrored()return true end
function mirrored:GetRelativePoint(p)local a,b,c=p:xyz();return point(self.x+a,self.y-b,self.z+c)end
list={mirrored};capture();report=V.Validate(map,'native mirrored basis')
assert(report.valid==1,'native relative-point basis already contains mirror reflection')
-- Intentional native clearing changes the entity, not the verified placement.
-- Its current mesh still needs complete contact proof and a native descriptor.
G.Entity=function(entity)return {complete=true,parts={{lod=0,material='native',mesh={path=entity,geometry=geometry}}}}end
local rubble=object(987,100,100,0,'CaveIn_TunnelBlocker_1');rubble.class='TunnelBlockerRubble'
rubble.anim_phases=5;rubble.gradual_clearing_name='CaveIn_TunnelBlocker';rubble.progress=0
function rubble:GetForcedLOD()return 0 end
function rubble:GetClearProgress()return self.progress end
list={rubble};V.Clear(map);capture();V.Validate(map)
assert(V.RecordRubbleSeating(map,rubble,{100,100,1},{100,100,0}))
rubble.entity='CaveIn_TunnelBlocker_3';rubble.progress=42
report=V.Validate(map,'native clearing transition')
assert(report.valid==1 and report.instances[1].native_clearing_transition,'verified native clearing transition lost its placement evidence')
rubble.x=101;report=V.Validate(map,'moved clearing geometry')
assert(report.valid==0,'entity-transition exception accepted a changed placement')
rubble.x=100;rubble.progress=21;report=V.Validate(map,'wrong clearing entity')
assert(report.valid==0,'wrong native clearing phase accepted')
print('support fixtures: native formations, precise defects, missing evidence, lifecycle and native clearing transitions passed')
-- Native wonder prefabs contain visible attached architecture deliberately
-- excluded from the free-standing scaling pass. It still supplies real support.
local parent,arch,fragment=object(120,8500,8500,0),object(121,8500,8500,20),object(122,8500,8500,40)
arch.parent=parent
function parent:ForEachAttach(fn)fn(arch)end
local scales=SuperBigMap.ObjectClone.ObjectScalesWithTerrain
SuperBigMap.ObjectClone.ObjectScalesWithTerrain=function(o)return o~=arch end
list={parent,arch,fragment};capture();report=V.Validate(map,'attached prefab support mesh')
assert(fragment.SuperBigMapSupportValidation.status=='valid','attached native prefab architecture must provide verified mesh support')
SuperBigMap.ObjectClone.ObjectScalesWithTerrain=scales
-- Late native logical markers have positively empty rendering, not missing
-- decoration meshes. Their lack of a pre-expansion baseline is not a defect.
local sight=object(130,9000,9000,400,'');sight.class='SafariSight'
list={sight};V.Clear(map);report=V.Recheck(map,'late safari marker')
assert(report.valid==1 and report.instances[1].render_kind=='native non-rendering logical marker')
assert(not report.instances[1].native_baseline,'do not invent a baseline for a post-generation marker')

-- Release mode disables exhaustive diagnostics on BOTH layers, but retains
-- scoped correction evidence. It does not fabricate a native-source baseline
-- or overwrite the last diagnostic report with a partial-map "pass".
SuperBigMap.Config.DECORATION_VALIDATION_ENABLED=false
SuperBigMap.RockGrounding={Eligible=function(o)return o.class=='Rock' and not o:GetParent() end}
G.Entity=original_entity
local historical=map.SuperBigMapDecorationValidation
for _,method in ipairs({'BeginCapture','Capture','FinishCapture','CaptureGroup','Validate','Recheck'})do
 assert(V.Run(method,map)==nil,'disabled exhaustive diagnostic ran: '..method)
end
local calls=scheduled_count
V.Schedule(map,'surface disabled');SuperBigMap.Engine.MapDataEnvironment=function()return 'Underground'end
map.SuperBigMapUndergroundPrepared=true;V.Schedule(map,'underground disabled')
assert(scheduled_count==calls,'disabled lifecycle diagnostics scheduled work')
local loose=object(140,3000,3000,20)
local distant=object(141,9000,9000,500,'Unknown')
distant.class='UnrelatedDecoration'
list={loose,distant}
local instance=G.Instance
local loose_builds=0
G.Instance=function(o)
 assert(o~=distant,'correction inspected distant geometry')
 if o==loose then loose_builds=loose_builds+1 end
 return instance(o)
end
local result=V.WithCorrectionEvidence(map,'Surface',function()
 assert(loose_builds==1,'surface nomination and initial proof rebuilt the same unchanged instance')
 local entries=V.SeatingEvidence(map)
 assert(#entries==1 and entries[1].obj==loose and entries[1].confirmed)
 loose.z=0;assert(V.RecordSeating(map,loose,{3000,3000,20},{3000,3000,0}))
 local proof=V.VerifyCorrection(map,{{obj=loose}},'release surface correction')
 assert(loose_builds>1,'changed placement reused the nomination geometry')
 assert(proof and loose.SuperBigMapSupportValidation.current_geometry_status=='valid')
 assert(loose.SuperBigMapSupportValidation.placement_repaired)
 assert(not loose.SuperBigMapSupportBaseline and not loose.SuperBigMapSupportValidation.native_baseline)
 return {corrected=1}
end)
assert(result.corrected==1 and map.SuperBigMapDecorationValidation==historical)
G.Instance=instance
-- Overlapping candidate neighbourhoods must classify each unchanged neighbour
-- once, including negative decisions. Exact support still runs afterwards.
local n1,n2,neighbour,excluded=object(150,7000,7000,20),object(151,7001,7000,20),
 object(152,7000,7001,0),object(153,7000,7002,0)
excluded.entity='Excluded';excluded.class='UnrelatedDecoration'
local old_skip,old_scales=SuperBigMap.ObjectClone.ShouldSkipObject,SuperBigMap.ObjectClone.ObjectScalesWithTerrain
local classifications={}
SuperBigMap.ObjectClone.ShouldSkipObject=function(o)
 classifications[o]=(classifications[o] or 0)+1;return false
end
SuperBigMap.ObjectClone.ObjectScalesWithTerrain=function(o)return o~=excluded end
list={n1,n2,neighbour,excluded}
V.WithCorrectionEvidence(map,'Surface',function()return {}end)
assert(classifications[neighbour]==nil and classifications[excluded]==1,
 'unchanged eligible neighbour was reclassified, or negative neighbourhood decisions repeated')
SuperBigMap.ObjectClone.ShouldSkipObject,SuperBigMap.ObjectClone.ObjectScalesWithTerrain=old_skip,old_scales
local base,top=object(142,4000,4000,0),object(143,4000,4000,20)
list={base,top}
V.WithCorrectionEvidence(map,'Surface',function()
 assert(#V.SeatingEvidence(map)==0,'diagnostics-off correction must preserve a legitimate stack')
 return {}
end)
local unknown=object(144,5000,5000,20,'Unknown');loose=object(145,5000,5000,20)
list={unknown,loose}
V.WithCorrectionEvidence(map,'Surface',function()
 assert(#V.SeatingEvidence(map)==0,'unknown nearby geometry must veto a correction')
 return {}
end)
local block=object(146,6000,6000,20,'CaveIn_TunnelBlocker_1')
block.class='TunnelBlockerRubble';block.remaining_work_to_clear=100;block.required_work_to_clear=100
function block:GetForcedLOD()return self.forced end
local distant=object(147,1000,1000,0)
function distant:GetAnimPhase()error('release correction must not fingerprint an unrelated object')end
list={block,distant}
local prior_print,release_logs=globals.print,0
globals.print=function()release_logs=release_logs+1 end
V.WithCorrectionEvidence(map,'Underground',function()
 assert(block.SuperBigMapSupportValidation.geometry_complete)
 block.z=0;block.forced=0
 assert(V.RecordRubbleSeating(map,block,{6000,6000,20},{6000,6000,0}))
 local proof=V.VerifyCorrection(map,{{obj=block}},'release underground correction')
 assert(proof and block.SuperBigMapSupportValidation.placement_repaired)
 assert(block.SuperBigMapSupportValidation.current_geometry_status=='valid')
 return {corrected=1}
end)
assert(map.SuperBigMapDecorationValidation==historical,'partial correction report replaced the full diagnostic report')
assert(release_logs==0,'release correction must not print diagnostic success summaries')
globals.print=prior_print
print('release mode: both-layer diagnostics disabled, scoped fixes preserved, no distant mesh scans or invented baselines')

-- A native multi-rock entity may have one grounded component and one proven
-- floating component. Nominate its rigid pose; the planner must still preserve
-- every visible component, native XY, neighbours, attachments and dependents.
SuperBigMap.Config.DECORATION_VALIDATION_ENABLED=true
SuperBigMap.RockGrounding={Eligible=function()return true end}
local group_vertices={};for i,p in ipairs(verts)do group_vertices[i]=p;group_vertices[i+8]={p[1]+40,p[2],p[3]+5}end
local small={bounds={30,-10,5,50,10,25},samples={},triangles={},vertices={}}
for i=9,16 do small.vertices[#small.vertices+1]=i;small.samples[#small.samples+1]=group_vertices[i]end
for _,t in ipairs(triangles)do small.triangles[#small.triangles+1]={t[1]+8,t[2]+8,t[3]+8}end
local group_asset={complete=true,parts={{lod=0,mesh={path='native-group',geometry={vertices=group_vertices,components={component,small}}}}}}
G.Entity=function()return group_asset end
local group=object(901,3000,3000,0)
function group:GetObjectBBox()return box(2990,2990,0,3050,3010,25)end
list={group};capture();report=V.Validate(map,'native partly grounded group')
assert(report.confirmed_defect==1,'group fixture did not reproduce its detached fragment')
local candidates=V.SeatingEvidence(map)
assert(#candidates==1 and candidates[1].obj==group and #candidates[1].components==2,'safe native group was not nominated for visibility-preserving rigid planning')
group.ForEachAttach=function(_,fn)fn({})end
assert(#V.SeatingEvidence(map)==0,'native attachment must veto group correction')
group.ForEachAttach=nil
SuperBigMap.Config.DECORATION_VALIDATION_ENABLED=false
V.WithCorrectionEvidence(map,'Surface',function()
 assert(#V.SeatingEvidence(map)==1,'a grounded origin hid a detached component in release mode')
 return {}
end)
SuperBigMap.Config.DECORATION_VALIDATION_ENABLED=true
print('native groups: detached fragment nominated without allowing attachment changes')

-- Native geometry still protects authored contacts, but authored gaps must now
-- be corrected as well. Source negative proofs no longer serve an exemption.
local original_signature=G.CompositionSignature
G.CompositionSignature=function(value)return value==group_asset and 'complete fixture group' or original_signature(value)end
SuperBigMap.Config.DECORATION_VALIDATION_ENABLED=false
group.SuperBigMapSupportBaseline=nil
local native_capture=V.CaptureNativeCompositions(map)
assert(native_capture and native_capture.captured and native_capture.candidates==1)
assert(native_capture.geometry_only and group.SuperBigMapSupportBaseline.geometry_only,
 'source frames must be distinguished from a source support census')
assert(not group.SuperBigMapSupportBaseline.components['0:native-group:2'].supported)
V.WithCorrectionEvidence(map,'Surface',function()
 assert(not group.SuperBigMapSupportValidation.native_composition_verified,'native gap exemption must stay disabled')
 assert(group.SuperBigMapSupportValidation.current_geometry_status~='valid','authored gap was incorrectly relabeled grounded')
 assert(#V.SeatingEvidence(map)==1,'native floating assembly must be nominated for correction')
 return {}
end)
group.z=100
V.WithCorrectionEvidence(map,'Surface',function()
 assert(not group.SuperBigMapSupportValidation.native_composition_verified,'lost native root was exempted')
 assert(#V.SeatingEvidence(map)==1,'expansion-induced unsupported assembly must be nominated')
 return {}
end)
group.z=0
G.CompositionSignature=original_signature
SuperBigMap.Config.DECORATION_VALIDATION_ENABLED=true
print('release native composition: exact capture, unchanged authored gaps, lost-root veto, no mutation')

SuperBigMap.Config.DECORATION_VALIDATION_ENABLED=false
G.Entity=function()return asset end
local native_single=object(902,3500,3500,100)
native_single.GetRelativePoint=function()error('single-component native nomination performed redundant vertex probes')end
list={native_single}
local single_capture=V.CaptureNativeCompositions(map)
assert(single_capture and single_capture.captured and single_capture.candidates==0)
assert(not native_single.SuperBigMapSupportBaseline,'invented a native supported-plus-gap assembly from one component')
local lod_asset={complete=true,parts={}}
for lod=0,3 do lod_asset.parts[#lod_asset.parts+1]={lod=lod,mesh={path='alternative-lod-'..lod,geometry=geometry}} end
G.Entity=function()return lod_asset end
local native_bbox=native_single.GetObjectBBox
native_single.GetObjectBBox=function()error('native map without assemblies built a redundant bounds index')end
local lod_capture=V.CaptureNativeCompositions(map)
assert(lod_capture and lod_capture.captured and lod_capture.candidates==0,'alternative LODs were treated as simultaneous composition fragments')
assert(not native_single.SuperBigMapSupportBaseline,'alternative LODs invented a native gap exemption')
native_single.GetObjectBBox=native_bbox
SuperBigMap.Config.DECORATION_VALIDATION_ENABLED=true

-- A candidate completely inside a closed neighbouring rock has no intersecting
-- surface triangles, but is not an empty placement. The same indexed complete
-- contact/containment proof used for support must reject it.
G.Entity=function()return asset end
local enclosed=object(910,4000,4000,100);enclosed.scale=10
local enclosing=object(911,4000,4000,0)
list={enclosed,enclosing};capture();V.Validate(map,'enclosed placement fixture')
assert(not V.SeatingPlacementClear(map,enclosed,{3999,3999,10,4001,4001,12}),'a contained placement was incorrectly called empty')

-- A placement group with a permanently unrooted component is already rejected;
-- subsequent components cannot add outgoing support edges to that component.
-- Do not finish unrelated triangle searches after that decision is certain.
SuperBigMap.Config.DECORATION_VALIDATION_ENABLED=false
G.Entity=original_entity
dofile('Code/sbm_decoration_seating.lua')
SuperBigMap.NativeHeightReferences=setmetatable({},{__index=function()return {} end}) -- no native grid: strict seating
local first_bad,second_bad=object(920,3000,3000,20),object(921,8000,8000,20)
first_bad.GetScale=first_bad.GetWorldScale;second_bad.GetScale=second_bad.GetWorldScale
local make_index=V.Index;local queries=0
V.Index=function(...)
 local index=make_index(...);local query=index.Query
 index.Query=function(...)queries=queries+1;return query(...)end
 return index
end
list={first_bad,second_bad}
local rejected=V.BuildDecorPlacement(map,list,point(5000,5000,0),4/3)
assert(not rejected.ok and rejected.reason=='native decor component has no verified rigid support')
assert(queries==1,'known rejected stamp continued checking later components')
V.Index=make_index
local ground,stacked=object(922,3000,3000,0),object(923,3000,3000,20)
ground.GetScale=ground.GetWorldScale;stacked.GetScale=stacked.GetWorldScale
list={ground,stacked}
assert(V.BuildDecorPlacement(map,list,point(3000,3000,0),4/3).ok,'short circuit rejected a rooted native stack')
local cap=object(924,3000,3000,40);cap.GetScale=cap.GetWorldScale
list={cap,stacked,ground}
assert(V.BuildDecorPlacement(map,list,point(3000,3000,0),4/3).ok,'short circuit rejected a support chain resolved later')
local distance=V.TriangleDistanceSquared
V.TriangleDistanceSquared=function()error('known rejected prefab did unrelated mesh contact work')end
list={ground,stacked,second_bad}
local early=V.BuildDecorPlacement(map,list,point(3000,3000,0),4/3)
assert(not early.ok and early.reason=='native decor component has no verified rigid support',
 'late isolated unsupported piece did not reject the new prefab before unrelated contacts')
V.TriangleDistanceSquared=distance
print('prefab failure preflight: isolated late float rejects before unrelated mesh work; rooted chains still pass')

-- Complete positive neighbour contact makes a second terrain-face witness
-- redundant. A conservative padded height upper bound need not equal the
-- terrain directly under this mesh, so it must not force that expensive walk.
G.Entity=function()return asset end
globals.terrain.GetMinMaxHeight=function()return 0,100 end
local terrain_queries=0
globals.terrain.GetHeight=function()terrain_queries=terrain_queries+1;return 0 end
list={object(930,3000,3000,0),object(931,3000,3000,20)}
V.WithCorrectionEvidence(map,'Surface',function()
 local summary=V.SurfaceSupportSummary(map)
 assert(summary.eligible==2 and summary.unresolved==0,'rooted stack lost positive support')
 return {}
end)
assert(terrain_queries<100,'rooted component still repeated an unnecessary terrain-face witness search')
-- With no rooted neighbour, the face-interior witness MUST still be tried.
globals.terrain.GetHeight=function(_,p,y)
 local x=type(p)=='number' and p or p:x();y=y or p:y()
 return math.abs(x-3000)<3 and math.abs(y-3000)<3 and 20 or 0
end
list={object(932,3000,3000,20)}
V.WithCorrectionEvidence(map,'Surface',function()
 assert(V.SurfaceSupportSummary(map).unresolved==0,'deferred face-only terrain support was skipped')
 return {}
end)
print('support proof ordering: one rooted witness suffices; face-only roots still receive full terrain search')

-- An unselected grounded neighbour has only a conservative world-bounds role.
-- A complete affine pose for it is unused; acquiring one must not be necessary.
local face_height=globals.terrain.GetHeight
globals.terrain.GetHeight=function()return 0 end
local far_grounded=object(933,8000,8000,0)
far_grounded.GetVisualPos=function()error('unselected bounds-only object captured an unused affine pose')end
local far_bbox=far_grounded.GetObjectBBox;local far_bounds_calls=0
far_grounded.GetObjectBBox=function(self)far_bounds_calls=far_bounds_calls+1;return far_bbox(self)end
list={object(934,3000,3000,0),object(935,3000,3000,20),far_grounded}
V.WithCorrectionEvidence(map,'Surface',function()
 assert(far_bounds_calls==1,'unchanged preparation repeatedly acquired the same native bounds')
 local summary=V.SurfaceSupportSummary(map)
 assert(summary.eligible==3 and summary.unresolved==0,'bounds-only shortcut lost positive coverage')
 -- Mutation begins here: the initial snapshot must no longer authorize reuse.
 far_grounded.x=9000
 V.Validate(map,'after callback mutation')
 assert(far_bounds_calls>1,'post-preparation scan reused stale native bounds')
 return {}
end)
print('correction scan: unselected world-bounds records need no unused local pose')
globals.terrain.GetHeight=face_height

-- A neighbour with a detached component may itself need to move. Preserve an
-- independent terrain-face root instead of inventing a dependency on that
-- assembly, which would otherwise veto its safe correction.
G.Entity=function(entity)return entity=='Group' and group_asset or asset end
globals.EntityData.Group=globals.EntityData.Rock
globals.const.HeightTileSize=1
globals.terrain.GetMinMaxHeight=function(_,bounds)
 return 0,bounds:minx()<=3000 and bounds:maxx()>=3000 and 20 or 0
end
local movable_group=object(940,3000,3000,0,'Group')
function movable_group:GetObjectBBox()return box(2990,2990,0,3050,3010,25)end
list={movable_group,object(941,3000,3000,20)}
V.WithCorrectionEvidence(map,'Surface',function()
 local evidence=V.SeatingEvidence(map)
 assert(#evidence==1 and evidence[1].obj==movable_group,
  'independent terrain-face root became a false dependency on a movable assembly')
 return {}
end)

-- A supported cliff is not visually seated when its open base crosses above
-- terrain. Nominate it despite the old positive contact, then verify the actual
-- moved foundation independently before accepting the repair.
local open_triangles={};for i=3,#triangles do open_triangles[#open_triangles+1]=triangles[i] end
local open_component={bounds=component.bounds,samples=verts,triangles=open_triangles,vertices=component.vertices}
local open_geometry={vertices=verts,components={open_component},animated=false}
local open_asset={complete=true,parts={{lod=0,mesh={path='open-foundation',geometry=open_geometry}}}}
G.Entity=function()return open_asset end
globals.terrain.GetHeight=function(_,p,y)
 local x=type(p)=='number' and p or p:x()
 return x<=3000 and 0 or -10
end
globals.terrain.GetMinMaxHeight=function()return -10,0 end
local cliff=object(950,3000,3000,0)
cliff.GetSkewX=function()return 0 end;cliff.GetSkewY=cliff.GetSkewX
cliff.GetWarped=function()return false end
cliff.GetPosXYZ=function(self)return self.x,self.y,self.z end
cliff.SetPos=function(self,p)self.x,self.y,self.z=p:xyz()end
globals.terrain.GetTerrainType=function()return 1 end
SuperBigMap.Engine.MapDataEnvironment=function()return 'Surface'end
list={cliff}
V.WithCorrectionEvidence(map,'Surface',function()
 assert(V.SurfaceSupportSummary(map).unresolved==1,'single contact exempted an exposed open base')
 local entries=V.SeatingEvidence(map)
 assert(#entries==1 and entries[1].foundation,'exposed foundation was not nominated')
 return {}
end)
local seated=SuperBigMap.DecorationSeating.Run(map)
assert(seated.corrected==1 and seated.rejected==0 and not seated.error,'foundation seating failed')
assert(cliff.x==3000 and cliff.y==3000 and cliff.z==-12,'foundation correction changed XY or failed to cover the open edge')
assert(not cliff.SuperBigMapSupportValidation.foundation_unresolved,'actual-pose foundation remained exposed')
V.WithCorrectionEvidence(map,'Surface',function()
 assert(V.SurfaceSupportSummary(map).unresolved==0,'seated foundation failed independent repeat census')
 assert(#V.SeatingEvidence(map)==0,'already covered foundation was moved again')
 return {}
end)
print('foundation integration: single-contact false positive repaired vertically, independently verified and idempotent')

-- Lower a supported stack as one rigid translation. Separate small objects
-- retain independent visibility budgets and the original support relationship.
cliff.z=0;cliff.SuperBigMapSupportRepair=nil
local rider=object(951,3000,3000,20,'Rider')
globals.EntityData.Rider=globals.EntityData.Rock
rider.GetSkewX=cliff.GetSkewX;rider.GetSkewY=cliff.GetSkewY
rider.GetWarped=cliff.GetWarped;rider.GetPosXYZ=cliff.GetPosXYZ;rider.SetPos=cliff.SetPos
G.Entity=function(entity)return entity=='Rider' and asset or open_asset end
list={cliff,rider}
local grouped=SuperBigMap.DecorationSeating.Run(map)
assert(grouped.corrected==2 and grouped.rejected==0 and not grouped.error,
 'rigid support group did not seat both objects: '..tostring(grouped.error))
assert(cliff.z==-12 and rider.z==8,'supported stack lost its relative pose')
V.WithCorrectionEvidence(map,'Surface',function()
 assert(V.SurfaceSupportSummary(map).unresolved==0,'translated stack failed repeat support census')
 return {}
end)
print('rigid support group: root and dependent translate together without added tilt or hidden separate rocks')

-- An upper open-bottom rock is preserved by its actual rooted contact, not
-- by burying its rim. When the lower rock needs seating, carry both together.
cliff.z=0;rider.z=20
cliff.SuperBigMapSupportRepair=nil;rider.SuperBigMapSupportRepair=nil
G.Entity=function()return open_asset end
local overhang_group=SuperBigMap.DecorationSeating.Run(map)
assert(overhang_group.corrected==2 and overhang_group.rejected==0 and not overhang_group.error,
 'preserved open-base dependent was left behind when its support moved: '..tostring(overhang_group.error))
assert(cliff.z==-12 and rider.z==8,'open-base supported formation lost its rigid relative pose')
assert(rider.SuperBigMapSupportValidation.supported_overhang_preserved,
 'moved open-base dependent lost its actual supported-overhang proof')
print('preserved overhang dependency: correcting its support carries the full native stack')

-- Authored inverted caps have their open mouth above the body. It is not a
-- ground-facing foundation; forcing it below terrain erases the entire rock.
local cap=object(952,5000,5000,20)
cap.GetSkewX=cliff.GetSkewX;cap.GetSkewY=cliff.GetSkewY
cap.GetWarped=cliff.GetWarped;cap.GetPosXYZ=cliff.GetPosXYZ;cap.SetPos=cliff.SetPos
function cap:GetRelativePoint(p)local a,b,c=p:xyz();return point(self.x+a,self.y-b,self.z-c)end
function cap:GetLocalPoint(p)local a,b,c=p:xyz();return point(a-self.x,self.y-b,self.z-c)end
function cap:GetObjectBBox()return box(self.x-10,self.y-10,self.z-20,self.x+10,self.y+10,self.z)end
globals.terrain.GetHeight=function()return 0 end
globals.terrain.GetMinMaxHeight=function()return 0,0 end
list={cap}
assert(not V.FoundationEvidence(map,cap),'upward cap opening was mistaken for a terrain-facing base')
V.WithCorrectionEvidence(map,'Surface',function()
 assert(V.SurfaceSupportSummary(map).unresolved==0,'grounded inverted native cap was rejected')
 return {}
end)
cap.z=30
V.WithCorrectionEvidence(map,'Surface',function()
 assert(V.SurfaceSupportSummary(map).unresolved==1,'orientation exception falsely grounded a floating inverted cap')
 return {}
end)
local cap_repair=SuperBigMap.DecorationSeating.Run(map)
assert(cap_repair.corrected==1 and not cap_repair.error and cap.z==20,'floating inverted cap did not seat at its actual lower surface')
print('native inverted caps: upward opening preserved; unsupported bodies still require actual ground contact')

-- A steep strip under the root would bury its uphill rider if the stack were
-- lowered vertically. The nearest safe lateral translation moves BOTH objects
-- rigidly, and both retain their sector, terrain type and positive support.
cliff.x,cliff.y,cliff.z=3000,3000,0
rider.x,rider.y,rider.z=2990,3000,20
cliff.SuperBigMapSupportRepair=nil;rider.SuperBigMapSupportRepair=nil
globals.terrain.GetHeight=function(_,p,y)
 local x=type(p)=='number' and p or p:x();return x>3000 and x<=3010 and -30 or 0
end
globals.terrain.GetMinMaxHeight=function()return -30,0 end
globals.GetMapSectorXY=function()return {area=box(0,0,0,10000,10000,100)}end
map.City={};list={cliff,rider}
local lateral=SuperBigMap.DecorationSeating.Run(map)
assert(not lateral.error and lateral.corrected==2 and lateral.rejected==0,'same-sector stack relocation failed: '..tostring(lateral.error))
assert(cliff.x<3000 and math.abs(cliff.x-3000)<=12 and cliff.y==3000,'stack did not choose a nearby safe pose')
assert(rider.x==cliff.x-10 and rider.y==cliff.y and rider.z==cliff.z+20,'lateral stack movement changed native composition')
print('same-sector stack integration: bounded nearest translation preserves all relative poses and positive support')

local inspected=object(953,5000,5000,0)
inspected.GetSkewX=cliff.GetSkewX;inspected.GetSkewY=cliff.GetSkewY;inspected.GetWarped=cliff.GetWarped
G.Entity=function()return {complete=true,parts={open_asset.parts[1],{lod=1,mesh=open_asset.parts[1].mesh}}}end
local observed={};local level=0
globals.terrain.GetMinMaxHeight=function()return -10,0 end
globals.terrain.GetHeight=function(_,x,y)
 local key=x..':'..y;assert(not observed[key],'one inspection queried a shared LOD terrain corner twice')
 observed[key]=true;return level
end
assert(V.FoundationEvidence(map,inspected).gap==0)
observed={};level=-5
assert(V.FoundationEvidence(map,inspected).gap==5,'foundation terrain cache escaped its single-pose inspection')
print('foundation LOD terrain cache: shared corners read once, later inspections always see fresh terrain')

-- Nomination only needs gap>2. A rim within 2 of the covering terrain minimum
-- is answered without the exact crossing walk; every other rim still gets the
-- exact measurement, so the candidate decision and candidate gaps are unchanged.
local exact_queries=0
globals.terrain.GetHeight=function()exact_queries=exact_queries+1;return level end
level=0;globals.terrain.GetMinMaxHeight=function()return -1,0 end
local bounded=V.FoundationEvidence(map,inspected,2)
assert(bounded.below_threshold and bounded.gap<=2 and exact_queries==0,'bounded rim still ran the exact crossing walk')
assert(V.FoundationEvidence(map,inspected).gap<=2,'threshold shortcut disagrees with the exact non-candidate verdict')
for _,case in ipairs({{-5,-5,-5},{0,-10,0},{-3,-4,0}})do
 level=case[1];globals.terrain.GetMinMaxHeight=function()return case[2],case[3] end
 local exact=V.FoundationEvidence(map,inspected);local fast=V.FoundationEvidence(map,inspected,2)
 assert(fast.below_threshold and exact.gap<=2 or fast.gap==exact.gap,'threshold mode changed an exact rim gap')
 assert((fast.gap>2)==(exact.gap>2),'threshold mode changed the nomination decision')
end
print('foundation nomination threshold: bounded rims skip the crossing walk; all other gaps stay exact')

-- Sloped ground: the whole-rim range fails, so each edge is bounded by its own
-- terrain range, and only edges that still fail take their exact crossing walk.
local range_calls=0
local function ranges(first,rest)
 range_calls=0
 globals.terrain.GetMinMaxHeight=function()range_calls=range_calls+1;if range_calls==1 then return first,0 end;return rest,0 end
end
level=0;exact_queries=0;ranges(-10,-1)
local edge_bounded=V.FoundationEvidence(map,inspected,2)
assert(edge_bounded.below_threshold and edge_bounded.gap<=2 and exact_queries==0 and range_calls>1,
 'per-edge terrain ranges did not prove a sloped buried rim')
level=0;exact_queries=0;ranges(-10,-10)
local walked=V.FoundationEvidence(map,inspected,2)
assert(walked.below_threshold and walked.gap<=2 and exact_queries>0,'failing edge bounds skipped the exact per-edge walk')
level=-5;ranges(-10,-10)
local exceeding=V.FoundationEvidence(map,inspected,2);ranges(-10,-10)
local reference=V.FoundationEvidence(map,inspected)
assert(not exceeding.below_threshold and exceeding.gap==reference.gap and exceeding.gap>2,
 'an edge above the threshold did not fall through to the exact rim measurement')
print('foundation nomination threshold: per-edge ranges and exact edge walks keep the gap>2 decision exact')

G.Entity=function()return open_asset end
cliff.x,cliff.y,cliff.z=3000,3000,0;cliff.SuperBigMapSupportRepair=nil
list={cliff}
globals.terrain.GetHeight=function()return -10 end
globals.terrain.GetMinMaxHeight=function()return -11,-9 end
local full_clearance=G.FoundationClearance;local rim_checks=0
G.FoundationClearance=function(points,edges,...)
 -- Count complete rim proofs; single-edge nomination walks are not repeats.
 if #edges>1 then rim_checks=rim_checks+1 end;return full_clearance(points,edges,...)
end
V.WithCorrectionEvidence(map,'Surface',function()
 assert(rim_checks==1,'unchanged preparation repeated the complete nomination rim proof')
 assert(V.SurfaceSupportSummary(map).unresolved==1)
 cliff.z=-12
 assert(V.VerifyCorrection(map,{{obj=cliff}},'test actual changed pose'))
 assert(not cliff.SuperBigMapSupportValidation.foundation_unresolved,
  'post-move proof did not inspect the actual pose')
 cliff.z=1
 assert(V.VerifyCorrection(map,{{obj=cliff}},'test exposed actual pose'))
 assert(rim_checks==2 and cliff.SuperBigMapSupportValidation.foundation_unresolved,
  'later exposed pose reused a previous terrain proof')
 return {}
end)
G.FoundationClearance=full_clearance
print('foundation preparation: unchanged nomination reused; post-move proof remains independent')

globals.terrain.GetMinMaxHeight=function()return -10,-10 end
G.FoundationClearance=function()error('certified flat rim needs no edge traversal')end
assert(V.FoundationEvidence(map,cliff).gap==11,'flat certificate changed the exact exposed rim clearance')
G.FoundationClearance=full_clearance
print('foundation flat terrain: exact maximum rim clearance without redundant edge traversal')

-- The whole opening is embedded inside a larger grounded body. Preserve the
-- native stack rather than incorrectly dragging its upper rock to terrain.
globals.terrain.GetHeight=function()return 0 end
globals.terrain.GetMinMaxHeight=function()return 0,0 end
local pedestal=object(960,5000,5000,0,'Rider');pedestal.scale=200
local stacked=object(961,5000,5000,30)
for _,o in ipairs({pedestal,stacked}) do
 o.GetSkewX=cliff.GetSkewX;o.GetSkewY=cliff.GetSkewY;o.GetWarped=cliff.GetWarped
end
G.Entity=function(entity)return entity=='Rider' and asset or open_asset end
list={pedestal,stacked}
V.WithCorrectionEvidence(map,'Surface',function()
 assert(stacked.SuperBigMapSupportValidation.supported_overhang_preserved or stacked.SuperBigMapSupportValidation.foundation_support_covered,'embedded rim lost its actual neighbour-body proof')
 assert(V.SurfaceSupportSummary(map).unresolved==0,'native supported stack was treated as floating')
 assert(#V.SeatingEvidence(map)==0,'supported native stack was nominated for a destructive terrain move')
 return {}
end)
stacked.x=5015
V.WithCorrectionEvidence(map,'Surface',function()
 assert(not stacked.SuperBigMapSupportValidation.foundation_support_covered,'overhang was mislabeled as full-rim coverage')
 assert(stacked.SuperBigMapSupportValidation.supported_overhang_preserved,'supported natural overhang was not preserved')
 assert(not stacked.SuperBigMapSupportValidation.foundation_unresolved,'actual supported overhang still requests burial')
 assert(#V.SeatingEvidence(map)==0,'supported overhang was nominated for a shape-changing correction')
 local function up(fn,key)
  for i=1,100 do local k,v=debug.getupvalue(fn,i);if k==key then return v elseif not k then break end end
 end
 local context=up(V.SeatingGroup,'contexts')[map]
 local preserve=up(V.Validate,'SupportedRockOverhang')
 local record
 for _,r in ipairs(context.list) do if r.obj==stacked then record=r end end
 assert(record and preserve,'overhang fixture could not inspect its actual record')
 -- Ordinary support scanning can stop at terrain before recording rock
 -- edges. A complete, real neighbour must still certify the overhang.
 for _,n in ipairs(record.nodes) do n.edges={} end
 assert(preserve(context,record,record.foundation),'missing first-witness edge hid actual rooted support')
 for _,n in ipairs(record.nodes) do
  local rim=record.foundation.by_component[n.component]
  if rim and rim.gap>2 then
   assert(#n.edges>0 and n.edges[1].record.obj==pedestal,
    'preserved overhang lost its dependency on the actual supporting rock')
  end
 end
 for _,r in ipairs(context.list) do if r.obj==pedestal then
  for _,n in ipairs(r.nodes) do n.unknown_support=true end
 end end
 assert(not preserve(context,record,record.foundation),'unknown neighbour acquired a support exemption')
 return {}
end)
-- A terrain witness may coexist with real stack support. It must not suppress
-- loading the neighbour geometry needed to preserve the native overhang.
globals.terrain.GetHeight=function(_,p,y)
 local x=type(p)=='number' and p or p:x();return x>=5024 and 30 or 0
end
globals.terrain.GetMinMaxHeight=function()return 0,30 end
V.WithCorrectionEvidence(map,'Surface',function()
 assert(stacked.SuperBigMapSupportValidation.supported_overhang_preserved,
  'terrain-first foundation nomination omitted its actual supporting neighbour')
 assert(#V.SeatingEvidence(map)==0,'terrain witness caused unnecessary stack burial')
 return {}
end)
globals.terrain.GetHeight=function()return 0 end
globals.terrain.GetMinMaxHeight=function()return 0,0 end
local prior_eligible=SuperBigMap.RockGrounding.Eligible
local eligibility_calls,exclude_pedestal={},false
SuperBigMap.RockGrounding.Eligible=function(o)
 eligibility_calls[o]=(eligibility_calls[o] or 0)+1
 return not (exclude_pedestal and o==pedestal) and prior_eligible(o)
end
V.WithCorrectionEvidence(map,'Surface',function()
 assert(eligibility_calls[pedestal]==1 and eligibility_calls[stacked]==1,
  'unchanged nomination repeated rock eligibility for neighbour LODs')
 exclude_pedestal=true
 V.Validate(map,'classification changed after preparation')
 assert(stacked.SuperBigMapSupportValidation.foundation_unresolved,
  'nomination eligibility cache escaped the immutable preparation snapshot')
 return {}
end)
SuperBigMap.RockGrounding.Eligible=prior_eligible
stacked.x=5040
V.WithCorrectionEvidence(map,'Surface',function()
 assert(stacked.SuperBigMapSupportValidation.foundation_unresolved,'detached opening incorrectly gained an overhang exemption')
 assert(not stacked.SuperBigMapSupportValidation.supported_overhang_preserved,'detached rock was labeled supported')
 return {}
end)
print('native stack foundations: supported overhangs preserved, detached rocks still require correction')

pedestal.z=100;stacked.x,stacked.z=5000,130
V.WithCorrectionEvidence(map,'Surface',function()
 assert(V.SurfaceSupportSummary(map).unresolved==2,'two touching floating rocks bootstrapped their own support')
 assert(not stacked.SuperBigMapSupportValidation.supported_overhang_preserved,'unrooted stack gained overhang permission')
 return {}
end)
pedestal.z=0;stacked.z=30
print('overhang roots: a detached contacting stack remains unsupported')

stacked.x=5000
local short_vertices={}
for i,p in ipairs(verts) do short_vertices[i]={p[1],p[2],p[3]/4} end
local short_component={bounds={-10,-10,0,10,10,5},samples=short_vertices,triangles=triangles,vertices=component.vertices}
local short_geometry={vertices=short_vertices,components={short_component},animated=false}
local changing_lods={complete=true,parts={asset.parts[1],{lod=1,mesh={path='short-pedestal',geometry=short_geometry}}}}
G.Entity=function(entity)return entity=='Rider' and changing_lods or open_asset end
V.WithCorrectionEvidence(map,'Surface',function()
 assert(not stacked.SuperBigMapSupportValidation.foundation_support_covered,'one covered LOD exempted an exposed alternate LOD')
 assert(stacked.SuperBigMapSupportValidation.foundation_unresolved,'alternate LOD hole was accepted')
 return {}
end)
print('native stack foundation LODs: every rendered neighbour alternative must cover the complete rim')

local twin_lods={complete=true,parts={asset.parts[1],{lod=1,mesh=asset.parts[1].mesh}}}
G.Entity=function()return twin_lods end
list={object(970,5000,5000,0)}
local terrain_reads=0
globals.terrain.GetHeight=function()terrain_reads=terrain_reads+1;return 0 end
V.WithCorrectionEvidence(map,'Surface',function()
 assert(V.SurfaceSupportSummary(map).unresolved==0)
 assert(terrain_reads==1,'identical actual LOD vertex was queried repeatedly')
 return {}
end)
local raised_vertices={}
for i,p in ipairs(verts) do raised_vertices[i]={p[1],p[2],p[3]+30} end
local raised_component={bounds={-10,-10,30,10,10,50},samples=raised_vertices,triangles=triangles,vertices=component.vertices}
local raised_geometry={vertices=raised_vertices,components={raised_component},animated=false}
G.Entity=function()return {complete=true,parts={asset.parts[1],{lod=1,mesh={path='raised-lod',geometry=raised_geometry}}}} end
V.WithCorrectionEvidence(map,'Surface',function()
 assert(V.SurfaceSupportSummary(map).unresolved==1,'one grounded LOD incorrectly supported an elevated alternate LOD')
 return {}
end)
print('shared LOD witness: exact common vertex proves all alternatives; mismatching floating LOD still fails')

-- Distinct LOD geometry buffers with exactly the same opening share only the
-- rim proof. A tiny coordinate difference must still receive its own proof.
do
 local original=open_asset.parts[1].mesh.geometry
 local original_component=original.components[1]
 local vertices={};for i,p in ipairs(original.vertices) do vertices[i]={p[1],p[2],p[3]} end
 local copy={bounds=original_component.bounds,vertices=original_component.vertices,triangles=original_component.triangles,samples=vertices}
 local second={vertices=vertices,components={copy},animated=false}
 local duplicate={complete=true,parts={open_asset.parts[1],{lod=1,mesh={path='identical-rim',geometry=second}}}}
 G.Entity=function()return duplicate end
 globals.terrain.GetMinMaxHeight=function()return -10,0 end
 globals.terrain.GetHeight=function()return -5 end
 local calls=0;G.FoundationClearance=function(...)calls=calls+1;return full_clearance(...)end
 local evidence=V.FoundationEvidence(map,inspected)
 assert(calls==1 and evidence.gap==5,'identical LOD opening repeated its full terrain proof')
 assert(evidence.by_component[copy]==evidence.by_component[original_component])
 vertices[1][1]=vertices[1][1]+1e-9;copy.foundation_boundary=nil
 -- Rebuild asset/component identity after changing a test buffer: native
 -- geometry caches are immutable and must not be invalidated behind a caller.
 local changed={bounds=original_component.bounds,vertices=original_component.vertices,triangles=original_component.triangles,samples=vertices}
 G.Entity=function()return {complete=true,parts={open_asset.parts[1],{lod=1,mesh={path='different-rim',geometry={vertices=vertices,components={changed},animated=false}}}}}end
 calls=0;evidence=V.FoundationEvidence(map,inspected)
 assert(calls==2,'near-identical opening was rounded into an unsafe shared proof')
 G.FoundationClearance=full_clearance
end
print('identical LOD foundations: exact boundary identity shares proof; distinct coordinates never alias')

do
 local lower_vertices={};for i,p in ipairs(verts) do lower_vertices[i]={p[1],p[2],p[3]-1} end
 local lower_component={bounds={-10,-10,-1,10,10,19},samples=lower_vertices,triangles=triangles,vertices=component.vertices}
 local lower_geometry={vertices=lower_vertices,components={lower_component},animated=false}
 local two_lods={complete=true,parts={asset.parts[1],{lod=1,mesh={path='lower-lod',geometry=lower_geometry}}}}
 G.Entity=function()return two_lods end
 globals.terrain.GetMinMaxHeight=function()return 0,0 end
 local reads=0;globals.terrain.GetHeight=function()reads=reads+1;return 0 end
 list={object(971,5000,5000,0)}
 V.WithCorrectionEvidence(map,'Surface',function()
  assert(V.SurfaceSupportSummary(map).unresolved==0 and reads==1,'same XY with distinct LOD heights reread terrain')
  return {}
 end)
 list[1].z=5;reads=0
 V.WithCorrectionEvidence(map,'Surface',function()
  assert(V.SurfaceSupportSummary(map).unresolved==1 and reads>0,'terrain or contact cache escaped the instance inspection')
  return {}
 end)
end
print('LOD terrain coordinates: same XY shares height, distinct Z still receives its own contact decision')

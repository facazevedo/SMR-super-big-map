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
local c_id,d_id=c.SuperBigMapSupportId,d.SuperBigMapSupportId
c.SuperBigMapSupportBaseline=nil;c.SuperBigMapSupportId=nil
d.SuperBigMapSupportBaseline=nil;d.SuperBigMapSupportId=nil
V.Clear(map);report=V.Recheck(map,'value-only ledger restore')
assert(report.valid==2 and c.SuperBigMapSupportId==c_id and d.SuperBigMapSupportId==d_id)
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
print('support fixtures: native stack/overhang/attachment accepted; split/attachment defects detected; unknown/cycles/old saves not passed; read-only and load recheck passed')

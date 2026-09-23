-- A skipped gameplay structure can still supply actual rendered support beside
-- its terrain hole. Support inclusion must not authorize moving that structure.
local function point(x,y,z)
 return {x=function()return x end,y=function()return y end,z=function()return z end,
  xy=function()return x,y end,xyz=function()return x,y,z end}
end
local function box(x0,y0,z0,x1,y1,z1)
 return {minx=function()return x0 end,miny=function()return y0 end,minz=function()return z0 end,
  maxx=function()return x1 end,maxy=function()return y1 end,maxz=function()return z1 end}
end
local globals={point=point,box=box,guim=1,const={HeightTileSize=100},EntitySurfaces={TerrainHole=8},
 GetRenderingMeshLods=function()return {get=function()end}end,
 IsValid=function(o)return not o.deleted end,GetPreciseTicks=function()return 0 end,print=function()end,
 IsKindOf=function(o,k)return o.editor and k=='EditorVisibleObject' or false end,
 HasAnySurfaces=function(o)return o.cut==true end,
 EntityData={Rock={editor_category='StonesRocksCliffs'},Structure={editor_category='Buildings'}},
 terrain={GetHeight=function()return 0 end,GetMinMaxHeight=function()return 0,0 end}}
globals.ForEachSurface=function(o,flag,fn)
 assert(flag==8)
 fn(point(o.x-5,o.y-5,0),point(o.x+5,o.y-5,0),point(o.x+5,o.y+5,0))
 fn(point(o.x-5,o.y-5,0),point(o.x+5,o.y+5,0),point(o.x-5,o.y+5,0))
end
SuperBigMap={Engine={Global=function(k)return globals[k]end},Config={DECORATION_VALIDATION_ENABLED=false},
 ObjectClone={ObjectScalesWithTerrain=function(o)return o.entity=='Rock' end,
  ShouldSkipObject=function(o)return o.entity~='Rock' end,IsImportantSectorObject=function(o)return o.entity~='Rock' end},
 RockGrounding={Eligible=function(o)return o.entity=='Rock' end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
local vertices={{-10,-10,0},{10,-10,0},{10,10,0},{-10,10,0},{-10,-10,20},{10,-10,20},{10,10,20},{-10,10,20}}
local triangles={{1,2,3},{1,3,4},{5,7,6},{5,8,7},{1,5,6},{1,6,2},{4,3,7},{4,7,8},{1,4,8},{1,8,5},{2,6,7},{2,7,3}}
local component={bounds={-10,-10,0,10,10,20},samples=vertices,triangles=triangles,vertices={1,2,3,4,5,6,7,8}}
local geometry={vertices=vertices,components={component},animated=false}
local asset={complete=true,parts={{lod=0,mesh={path='fixture',geometry=geometry}}}}
local missing=false
local structure_reads=0
G.Entity=function(entity)
 if entity=='Structure' then structure_reads=structure_reads+1 end
 if missing and entity=='Structure' then return {complete=false,parts={},reason='missing mesh'} end
 return asset
end
dofile('Code/sbm_decoration_validation.lua')
local V=SuperBigMap.DecorationValidation
local function object(entity,x,y,z,scale)
 local o={entity=entity,class=entity,x=x,y=y,z=z,scale=scale or 100}
 function o:GetEntity()return self.entity end
 function o:GetState()return 0 end
 function o:GetParent()return false end
 function o:GetVisualPos()return point(self.x,self.y,self.z)end
 o.GetPos=o.GetVisualPos
 function o:GetWorldScale()return self.scale end
 function o:IsValidZ()return true end
 function o:GetRelativePoint(p)local a,b,c=p:xyz();local s=self.scale/100.0;return point(self.x+a*s,self.y+b*s,self.z+c*s)end
 function o:GetLocalPoint(p)local a,b,c=p:xyz();local s=100.0/self.scale;return point((a-self.x)*s,(b-self.y)*s,(c-self.z)*s)end
 function o:GetClipPlane()return 0 end
 function o:GetTerrainDistortedSupport()return 'disabled' end
 function o:GetObjectBBox()local s=self.scale/100.0;return box(self.x-10*s,self.y-10*s,self.z,self.x+10*s,self.y+10*s,self.z+20*s)end
 function o:SetPos()error('support proof must not move structures or rocks')end
 function o:SetScale()error('support proof must not resize anything')end
 return o
end
local roof,stone=object('Structure',1000,1000,0),object('Rock',1000,1000,20,25)
roof.cut=true
local map={}
function map:GetMapSize()return 10000,10000 end
function map:MapForEach(_,_,fn)fn(stone);fn(roof)end
local function census()
 return V.WithCorrectionEvidence(map,'Surface',function(owner)
  local result=V.SurfaceSupportSummary(owner)
  local entries=V.SeatingEvidence(owner)
  for _,entry in ipairs(entries) do assert(entry.obj~=roof,'support inclusion nominated a gameplay structure for movement') end
  if result.unresolved==0 then assert(#entries==0,'already-supported rock was nominated for movement') end
  return result
 end)
end
local r=census()
assert(r.eligible==1 and r.graph==1 and r.unresolved==0,'skipped terrain-cut structure was replaced by unknown bounds')
missing=true;r=census()
assert(r.unresolved==1,'missing structure geometry fabricated support')
missing=false;roof.editor=true;r=census()
assert(r.unresolved==1,'editor-only hole marker became a rendered support')
roof.editor=false;roof.cut=false;r=census()
assert(r.unresolved==1,'ordinary excluded object was implicitly promoted')
-- A nearby box is only a broad-phase cut candidate. A real vertex on visible
-- ground outside the exact hole needs no structural mesh or support graph.
roof.cut=true;missing=true;stone.x=1008;stone.z=0;stone.scale=10;structure_reads=0
r=census()
assert(r.terrain==1 and r.unresolved==0,'visible ground beside a cut was not accepted')
assert(structure_reads==0,'direct terrain witness still decoded unrelated structure')
stone.x=1000;r=census()
assert(r.unresolved==1,'height field beneath the actual cut fabricated support')
local surfaces=globals.ForEachSurface
stone.x=1008;globals.ForEachSurface=nil;r=census()
assert(r.unresolved==1,'missing cut API bypassed conservative bounds')
globals.ForEachSurface=function()error('unavailable cut geometry')end;r=census()
assert(r.unresolved==1,'failed cut API bypassed conservative bounds')
globals.ForEachSurface=function(o,flag,fn)fn(point(0,0,0),point(0,0,1),point(0,0,2))end;r=census()
assert(r.unresolved==1,'degenerate cut geometry bypassed conservative bounds')
globals.ForEachSurface=surfaces
print('terrain-cut supports: actual rendered contact, no movement, missing/editor/excluded geometry fail closed')

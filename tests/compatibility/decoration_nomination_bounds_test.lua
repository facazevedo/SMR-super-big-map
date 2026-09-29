-- Rotating a component's local AABB can enclose empty corners outside the
-- native tight object box. Nomination must inspect the same neighbours as Scan.
-- Otherwise an ordinary grounded neighbour becomes "unknown support" and
-- prevents correction of a genuinely floating rock. No scenario/asset whitelist.
local function point(x,y,z)
 return {x=function()return x end,y=function()return y end,z=function()return z end,
  xy=function()return x,y end,xyz=function()return x,y,z end}
end
local function box(a,b,c,d,e,f)
 return {minx=function()return a end,miny=function()return b end,minz=function()return c end,
  maxx=function()return d end,maxy=function()return e end,maxz=function()return f end}
end
local globals={point=point,box=box,guim=1,const={HeightTileSize=100},EntitySurfaces={},
 GetRenderingMeshLods=function()return {get=function()end}end,
 IsValid=function(o)return not o.deleted end,GetPreciseTicks=function()return 0 end,
 IsKindOf=function()return false end,print=function()end,
 EntityData={Rock={editor_category='StonesRocksCliffs'},Neighbour={editor_category='StonesRocksCliffs'}},
 terrain={GetHeight=function()return 0 end,GetMinMaxHeight=function()return 0,0 end}}
SuperBigMap={Engine={Global=function(k)return globals[k]end},Config={DECORATION_VALIDATION_ENABLED=false},
 ObjectClone={ObjectScalesWithTerrain=function()return true end,ShouldSkipObject=function()return false end,
  IsImportantSectorObject=function()return false end},RockGrounding={Eligible=function()return true end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
local function asset(vertices,triangles,path)
 local bounds=G.Bounds();local ids={}
 for i,p in ipairs(vertices)do G.Extend(bounds,p);ids[i]=i end
 local component={bounds=bounds,samples=vertices,triangles=triangles,vertices=ids}
 local geometry={vertices=vertices,components={component},animated=false}
 return {complete=true,parts={{lod=0,mesh={path=path,geometry=geometry}}}}
end
local tetra=asset({{-10,-10,0},{10,-10,0},{-10,10,0},{-10,-10,20}},
 {{1,3,2},{1,2,4},{1,4,3},{2,3,4}},'tetra')
local tall=asset({{-1,-1,0},{1,-1,0},{1,1,0},{-1,1,0},{-1,-1,310},{1,-1,310},{1,1,310},{-1,1,310}},
 {{1,2,3},{1,3,4},{5,7,6},{5,8,7},{1,5,6},{1,6,2},{4,3,7},{4,7,8},{1,4,8},{1,8,5},{2,6,7},{2,7,3}},'tall')
local missing=false
G.Entity=function(entity)
 if entity=='Rock' then return tetra end
 if missing then return {complete=false,parts={},reason='missing neighbour geometry'} end
 return tall
end
dofile('Code/sbm_decoration_validation.lua')
local V=SuperBigMap.DecorationValidation
local function object(entity,x,y,z,rotated)
 local o={entity=entity,class=entity,x=x,y=y,z=z}
 local c,s=rotated and math.sqrt(.5) or 1,rotated and math.sqrt(.5) or 0
 function o:GetEntity()return self.entity end
 function o:GetState()return 0 end
 function o:GetParent()return false end
 function o:GetVisualPos()return point(self.x,self.y,self.z)end
 o.GetPos=o.GetVisualPos
 function o:GetWorldScale()return 100 end
 function o:IsValidZ()return true end
 function o:GetRelativePoint(p)local a,b,d=p:xyz();return point(self.x+c*a-s*b,self.y+s*a+c*b,self.z+d)end
 function o:GetLocalPoint(p)local a,b,d=p:xyz();a,b=a-self.x,b-self.y;return point(c*a+s*b,-s*a+c*b,d-self.z)end
 function o:GetClipPlane()return 0 end
 function o:GetTerrainDistortedSupport()return 'disabled' end
 function o:GetObjectBBox()
  local a=entity=='Rock' and tetra or tall;local b=G.Bounds()
  for _,p in ipairs(a.parts[1].mesh.geometry.vertices)do G.Extend(b,{self:GetRelativePoint(point(table.unpack(p))):xyz()}) end
  return box(table.unpack(b))
 end
 function o:SetPos()error('inspection must leave rock placements untouched')end
 function o:SetScale()error('inspection must leave rock scale untouched')end
 return o
end
local rock=object('Rock',1000,1000,300,true)
local neighbour=object('Neighbour',1000,1010,0)
local distant=object('Neighbour',9000,9000,0)
local objects={rock,neighbour,distant}
local map={}
function map:GetMapSize()return 10000,10000 end
function map:MapForEach(_,_,fn)for _,o in ipairs(objects)do fn(o)end end
local function inspect()
 return V.WithCorrectionEvidence(map,'Surface',function(owner)
  return {summary=V.SurfaceSupportSummary(owner),entries=V.SeatingEvidence(owner)}
 end)
end
local result=inspect()
assert(result.summary.unresolved==1,'the floating target must remain a defect until actually corrected')
assert(#result.entries==1 and result.entries[1].obj==rock,
 'tight object nomination omitted a neighbour in the validator component bounds')
assert(neighbour.SuperBigMapSupportValidation and neighbour.SuperBigMapSupportValidation.current_geometry_status=='valid',
 'nearby grounded rock was not positively classified')
assert(not distant.SuperBigMapSupportValidation,'local nomination expanded into a whole-map detailed scan')
assert(neighbour.x==1000 and neighbour.y==1010 and neighbour.z==0,'grounded neighbour moved')
-- Reversing enumeration cannot change the nomination/proof decision.
objects={distant,neighbour,rock};result=inspect()
assert(#result.entries==1 and result.entries[1].obj==rock,'enumeration order changed correction eligibility')
-- A genuinely unavailable neighbour still blocks movement; resolving the bounds
-- mismatch must not waive missing geometry or simply ignore neighbours.
missing=true;result=inspect()
assert(result.summary.unresolved>0 and #result.entries==0,'missing geometry authorized a guessed correction')
missing=false;rock.z=0;result=inspect()
assert(result.summary.unresolved==0 and #result.entries==0,'correctly placed rocks were nominated for movement')
-- A real rock-to-rock contact must remain a positive witness, rather than
-- treating every candidate without terrain contact as a loose stone to lower.
rock.z=300;neighbour.y=1000;result=inspect()
assert(result.summary.unresolved==0 and #result.entries==0,'a supported rock was nominated for movement')
assert(rock.z==300 and neighbour.z==0,'support inspection moved an already-correct formation')
print('nomination bounds: matching rendered broad phase, local work, unchanged correct rocks and unknown veto')

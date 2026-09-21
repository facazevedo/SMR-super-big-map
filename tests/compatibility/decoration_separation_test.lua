-- Red/green: overlapping candidate boxes are not actual support, and a rotated
-- local AABB can extend below terrain even when every rendered vertex is above it.
local function point(x,y,z)return {xyz=function()return x,y,z end,xy=function()return x,y end}end
local function box(a,b,c,d,e,f)return {minx=function()return a end,miny=function()return b end,minz=function()return c end,
 maxx=function()return d end,maxy=function()return e end,maxz=function()return f end}end
local assets={};local objects={}
local globals={point=point,box=box,guim=1,const={HeightTileSize=100},EntitySurfaces={},
 IsValid=function()return true end,GetPreciseTicks=function()return 0 end,print=function()end,
 EntityData={},GetRenderingMeshLods=function()return nil end,
 terrain={GetHeight=function()return 0 end,GetMinMaxHeight=function()return 0,0 end}}
SuperBigMap={Engine={Global=function(n)return globals[n]end},Config={},ObjectClone={
 ObjectScalesWithTerrain=function()return true end,ShouldSkipObject=function()return false end,IsImportantSectorObject=function()return false end}}
dofile('Code/sbm_decoration_geometry.lua');local G=SuperBigMap.DecorationGeometry
function G.Entity(name)return assets[name]end
dofile('Code/sbm_decoration_validation.lua');local V=SuperBigMap.DecorationValidation
local map={GetMapSize=function()return 10000,10000 end}
function map:MapForEach(_,_,fn)for _,o in ipairs(objects)do fn(o)end end
local function object(name,verts,transform)
 local bounds=G.Bounds();for _,p in ipairs(verts)do G.Extend(bounds,p)end
 local c={bounds=bounds,vertices={1,2,3},triangles={{1,2,3}},samples=verts,bottom=verts[1]}
 assets[name]={complete=true,parts={{lod=0,mesh={path=name,geometry={vertices=verts,components={c},quantum=0}}}}}
 local o={class=name,handle=#objects+1}
 function o:GetEntity()return name end;function o:GetState()return 0 end
 function o:GetParent()return nil end;function o:GetWorldScale()return 100 end
 function o:IsValidZ()return true end
 function o:GetVisualPos()return self:GetRelativePoint(point(0,0,0))end;o.GetPos=o.GetVisualPos
 function o:GetRelativePoint(p)local x,y,z=p:xyz();if transform then x,y,z=transform(x,y,z)end;return point(500+x,500+y,z)end
 function o:GetClipPlane()return 0 end;function o:GetTerrainDistortedSupport()return 'disabled'end
 function o:GetObjectBBox()
  local b=G.Bounds();for _,p in ipairs(verts)do local x,y,z=self:GetRelativePoint(point(table.unpack(p))):xyz();G.Extend(b,{x,y,z})end
  return box(table.unpack(b))
 end
 objects[#objects+1]=o;return o,c
end
local function validate()
 V.BeginCapture(map,map);for _,o in ipairs(objects)do V.Capture(map,o,false,false)end
 V.FinishCapture(map);return V.Validate(map)
end
local loose=object('Loose',{{0,0,10},{20,0,10},{0,20,12}})
local support=object('Support',{{20,20,0},{20,15,0},{15,20,20}})
validate()
assert(support.SuperBigMapSupportValidation.current_geometry_status=='valid','real terrain witness lost')
assert(loose.SuperBigMapSupportValidation.current_geometry_status=='confirmed defect','disjoint actual triangles remained inconclusive because boxes overlap')
-- An unknown enclosing mesh must still veto a negative conclusion.
assets.Support={complete=false,parts={}}
validate();assert(loose.SuperBigMapSupportValidation.current_geometry_status=='inconclusive','unknown neighbour falsely certified empty')
objects={}
local rotated=object('Rotated',{{-10,0,10},{10,0,-10},{10,10,10}},function(x,y,z)return (x-z)/math.sqrt(2),y,10+(x+z)/math.sqrt(2)end)
validate()
assert(rotated.SuperBigMapSupportValidation.current_geometry_status=='confirmed defect','rotated conservative AABB hid a real ten-unit ground gap')
objects={}
local crest=object('Crest',{{0,0,10},{12,0,10},{0,12,10}})
globals.terrain.GetHeight=function(_,p)local x,y=p:xy();return x==504 and y==504 and 12 or 0 end
globals.terrain.GetMinMaxHeight=function()return 0,12 end
validate()
assert(crest.SuperBigMapSupportValidation.current_geometry_status=='valid','terrain can contact a triangle interior without reaching any mesh vertex')
globals.terrain.GetHeight=function(_,p)local x,y=p:xy();return x==508 and y==508 and 12 or 0 end
validate()
assert(crest.SuperBigMapSupportValidation.current_geometry_status~='valid','a terrain crest outside the triangle must not supply support')
print('decoration separation: complete triangle separation, unknown veto and exact transformed bounds passed')
-- Release blocker corrections may avoid proving old negative gaps, but actual
-- corrected placements still need complete positive witnesses, including faces.
SuperBigMap.Config.DECORATION_VALIDATION_ENABLED=false
crest.class='TunnelBlockerRubble';crest.required_work_to_clear=100;crest.remaining_work_to_clear=100
assets.CaveIn_TunnelBlocker_1=assets.Crest
function crest:GetEntity()return 'CaveIn_TunnelBlocker_1'end
globals.terrain.GetHeight=function()return 0 end
V.Correction(map,'Underground',function()
 assert(crest.SuperBigMapSupportValidation.current_geometry_status~='valid','missing support cannot count as a positive proof')
end)
globals.terrain.GetHeight=function(_,p)local x,y=p:xy();return x==504 and y==504 and 12 or 0 end
V.Correction(map,'Underground',function()
 assert(crest.SuperBigMapSupportValidation.current_geometry_status=='inconclusive','a placement proposal must not claim verification')
 V.VerifyCorrection(map,{{obj=crest}},'fixture actual placement')
 assert(crest.SuperBigMapSupportValidation.current_geometry_status=='valid','deferred face-interior witness must still be checked')
end)

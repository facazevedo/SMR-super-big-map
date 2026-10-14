-- Rounded engine point samples can overestimate contact on a steep slope.
-- Exercise the actual service and exact triangle refinement, with the final
-- independent verdict based on the unrounded rendered terrain plane.
local function read(path)
 local f=assert(io.open(path));local s=f:read('*a');f:close();return s
end
local function point(x,y,z)
 return {x=x,y=y,z=z,xyz=function(p)return p.x,p.y,p.z end,xy=function(p)return p.x,p.y end}
end
local function ground(x)return 10*(x-20000)end
local pos=point(20000,20000,20)
local obj={SuperBigMapDecorEnginePass=true,GetVisualPos=function()return pos end,
 GetPos=function()return pos end,GetPosXYZ=function()return pos:xyz()end,
 SetPos=function(_,p)pos=p end,GetEntity=function()return 'Sloped top-up'end}
local vertices={{20000.51,20000,20},{20000.51,20001,30},{20001.51,20000,30}}
local geometry={vertices=vertices}
local record={complete=true,nodes={{component={triangles={{1,2,3}}},geometry=geometry}}}
local map={City={},mapdata={},GetMapSize=function()return 100000,100000 end}
local globals={point=point,const={HeightTileSize=10},GetPreciseTicks=function()return 1 end,
 terrain={GetTerrainType=function()return 1 end,GetHeight=function(_,x)
  return ground(type(x)=='table' and x.x or x)
 end}}
local sector={area={minx=function()return 0 end,miny=function()return 0 end,
 maxx=function()return 100000 end,maxy=function()return 100000 end}}
globals.GetMapSectorXY=function()return sector end
SuperBigMap={Engine={Global=function(n)return globals[n]end,MapDataEnvironment=function()return 'Surface'end}}
dofile('Code/sbm_decoration_geometry.lua')
local validator={SeatingEvidence=function()
 return {{obj=obj,confirmed=true,bounds={20000,20000,20,20002,20002,30},
  components={{vertices=vertices,height=10}}}}
end,SeatingPlacementClear=function()return true end,
 RecordSeating=function()obj.SuperBigMapSupportRepair={version=1};return true end}
local refinement=assert(read('Code/sbm_decoration_validation.lua'):match('function Validator.RefineSeatingComponents.-\nend\n'))
assert(load(refinement,'production terrain refinement','t',setmetatable({Validator=validator,
 contexts={[map]={by_object={[obj]=record}}},Global=function(n)return globals[n]end,
 Geometry=SuperBigMap.DecorationGeometry,World=function(_,p)return p end},{__index=_G})))()
local checks=0
validator.VerifyCorrection=function()
 checks=checks+1
 local low,high=math.huge,-math.huge
 for _,v in ipairs(vertices)do
  local gap=v[3]+pos.z-20-ground(v[1]);low=math.min(low,gap);high=math.max(high,gap)
 end
 local valid=low<=0 and high>=5
 obj.SuperBigMapSupportValidation={current_geometry_status=valid and 'valid' or 'confirmed defect',placement_repaired=valid}
 return {}
end
validator.SurfaceSupportSummary=function()
 return {eligible=1,unresolved=obj.SuperBigMapSupportValidation.placement_repaired and 0 or 1}
end
SuperBigMap.DecorationValidation=validator
SuperBigMap.TerrainCopy={VerifyNativeHeightReference=function()return true end,ReleaseNativeHeightReference=function()end}
dofile('Code/sbm_decoration_seating.lua')
local result=SuperBigMap.DecorationSeating.Run(map)
assert(result.corrected==1 and result.rejected==0 and not result.error and checks==1,
 'rounded terrain contact left a top-up floating and rolled it back instead of seating it')
assert(pos.x==20000 and pos.y==20000 and pos.z==3,'exact slope correction changed XY or lost its contact margin')
print('top-up slope seating: exact terrain planes, preserved visibility and independent verification passed')

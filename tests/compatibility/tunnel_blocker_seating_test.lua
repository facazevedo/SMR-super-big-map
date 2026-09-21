-- Native-call failure injection: restoring a cosmetic correction must also
-- restore gameplay grid membership, even when a mutator throws mid-operation.
local function scenario(failure,foreign)
 local function point(x,y,z)return {xyz=function()return x,y,z end}end
 local original=point(100,200,10000);local pos=original;local forced
 local raised=false
 local function inject(name)
  if (failure==name or failure=='rollback' and name=='lod') and not raised then raised=true;error('injected '..name)end
 end
 local obj={class='TunnelBlockerRubble',handle=1,grids_applied=true,
  required_work_to_clear=120000,remaining_work_to_clear=120000,
  SuperBigMapSupportValidation={geometry_complete=true,current_geometry_status='confirmed defect'}}
 function obj:GetEntity()return 'CaveIn_TunnelBlocker_1'end
 function obj:GetState()return 0 end
 function obj:GetParent()return nil end
 function obj:GetForcedLOD()return forced end
 function obj:SetForcedLOD(v)forced=v>=0 and v or nil;inject('lod')end
 function obj:GetMirrored()return false end
 function obj:GetWarped()return false end
 function obj:GetSkewX()return 0 end
 function obj:GetSkewY()return 0 end
 function obj:GetVisualPos()return pos end
 function obj:GetPos()return pos end
 function obj:GetPosXYZ()return pos:xyz()end
 function obj:SetPos(v)
  if failure=='rollback' and raised and v==original then error('persistent restore failure')end
  pos=v;inject('position')
 end
 function obj:GetWorldScale()return 133 end
 function obj:GetShapePoints()return {1,2,3}end
 function obj:RemoveFromGrids()self.grids_applied=false;inject('remove')end
 function obj:ApplyToGrids()self.grids_applied=true;inject('apply')end
 local components={};for i=1,99 do components[i]={bottom={0,0,0}}end
 components[26].bottom[3]=0.12;components[29].bottom[3]=0.325
 local mesh={geometry={vertex_count=7791,index_count=28215,components=components,
  bounds={-78.83563232421875,-112.61820220947266,-4.167948246002197,71.57398223876953,102.43913269042969,63.287967681884766}}}
 mesh.path='Meshes/CaveIn_TunnelBlocker_1_mesh.sub_0.hgrm'
 local native={complete=true,parts={{lod=0,mesh=mesh,material='native'},
  {lod=1,mesh={path='Meshes/CaveIn_TunnelBlocker_1_mesh_lod1.sub_0.hgrm'},material='native'}}}
 local geometry={ReadMesh=function()return mesh end,Entity=function()return native end,
  Instance=function()return foreign and {complete=true,parts={{lod=0,mesh={path='foreign'},material='native'}}} or native end}
 local checks=0
 local validator={RecordRubbleSeating=function()
  if failure=='refused' then return false end
  inject('record');obj.SuperBigMapSupportRepair={version=1,forced_lod=0};return true
 end,Run=function()
  checks=checks+1;inject('verification')
  obj.SuperBigMapSupportValidation={current_geometry_status=failure=='proof' and 'inconclusive' or 'valid',placement_repaired=true}
  return {}
 end}
 local globals={point=point,guim=100,const={InvalidLODIndex=-1},GetPreciseTicks=function()return 1 end,
  HasAnySurfaces=function()return false end,EntitySurfaces={Height=1,Terrain=2,TerrainHole=4}}
 SuperBigMap={Engine={Global=function(k)return globals[k]end,MapDataEnvironment=function()return 'Underground'end},
  DecorationGeometry=geometry,DecorationValidation=validator}
 dofile('Code/sbm_decoration_seating.lua')
 local map={mapdata={},MapGet=function()return {obj}end}
 local ok,report=pcall(SuperBigMap.DecorationSeating.RunUnderground,map)
 assert(ok,'native failure escaped correction transaction: '..tostring(report))
 assert(obj.grids_applied and obj.remaining_work_to_clear==120000,'gameplay state changed')
 if failure=='rollback' then
  assert(report.error and report.error:find('rollback failed',1,true),'unrecoverable rollback was silently accepted')
  assert(report.corrected==0 and forced==nil and obj.SuperBigMapSupportRepair==nil,'later restore steps not attempted')
 elseif failure or foreign then
  assert(pos==original and forced==nil and obj.SuperBigMapSupportRepair==nil,'rollback did not restore exact state: '..tostring(failure))
  assert(report.corrected==0,'failed or foreign correction reported as accepted')
 else
  assert(report.corrected==1 and forced==0 and select(3,pos:xyz())==9956,'verified native correction not accepted')
 end
 return report,checks
end
scenario(nil,false)
for _,failure in ipairs({'remove','position','lod','apply','record','refused','verification','proof','rollback'})do scenario(failure,false)end
scenario(nil,true)
print('tunnel blocker seating: native-only correction and transactional error/proof rollback passed')

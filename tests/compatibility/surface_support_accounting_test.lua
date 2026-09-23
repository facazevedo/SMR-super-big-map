local globals={IsValid=function(o)return not o.deleted end}
SuperBigMap={Engine={Global=function(k)return globals[k]end},DecorationGeometry={},
 RockGrounding={Eligible=function(o)return o.eligible~=false end}}
dofile('Code/sbm_decoration_validation.lua')
local V=SuperBigMap.DecorationValidation
local contexts
for i=1,100 do local k,v=debug.getupvalue(V.SurfaceSupportSummary,i);if k=='contexts' then contexts=v;break end end
assert(contexts)
local function record(row,witness)
 return {relevant=true,complete=true,support_terrain_witness=witness,obj={GetEntity=function()return 'Rock'end,
  GetVisualPos=function()return {xyz=function()return 1,2,3 end}end,SuperBigMapSupportValidation=row}}
end
local map={}
assert(V.SurfaceSupportSummary(map)==nil)
local direct=record(nil,true)
local valid=record({geometry_complete=true,current_geometry_status='valid'})
local native=record({geometry_complete=true,current_geometry_status='confirmed defect',native_composition_verified=true})
local missing=record(nil)
local incomplete=record({geometry_complete=false,current_geometry_status='valid'})
local c={list={direct,valid,native,missing,incomplete},repair_targets={}}
contexts[map]=c
local r=V.SurfaceSupportSummary(map)
assert(r.eligible==5 and r.terrain==1 and r.graph==1 and r.native_composition==0 and r.unresolved==3,
 'native floating composition is no longer an acceptable support exemption')
c.repair_targets[direct.obj]=true
r=V.SurfaceSupportSummary(map)
assert(r.terrain==0 and r.unresolved==4,'a nominated correction cannot reuse an obsolete terrain witness')
incomplete.obj.deleted=true;missing.obj.eligible=false
r=V.SurfaceSupportSummary(map)
assert(r.eligible==3 and r.unresolved==2,'only current eligible rocks belong in the census')
valid.complete=false
r=V.SurfaceSupportSummary(map)
assert(r.unresolved==3,'stale valid annotation must not hide missing current geometry')
print('surface support accounting: explicit positive proofs, complete coverage, unknowns fail closed')

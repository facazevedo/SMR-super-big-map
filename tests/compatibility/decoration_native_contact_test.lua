-- Prove the alternative-contact path uses captured source geometry, not merely
-- current rooted support or a matching asset filename.
local globals={IsValid=function(o)return o~=nil end,const={HeightTileSize=100},guim=1000}
SuperBigMap={Engine={Global=function(n)return globals[n]end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
G.CompositionSignature=function(asset)return asset.signature end
dofile('Code/sbm_decoration_validation.lua')
local V=SuperBigMap.DecorationValidation
local function up(fn,key)for i=1,90 do local n,v=debug.getupvalue(fn,i);if n==key then return v elseif not n then break end end end
local proof=up(V.Validate,'PreservedContacts')
local vertices={{0,0,0},{1,0,0},{0,1,0},{0,0,1}}
local component={bounds={0,0,0,1,1,1},vertices={1,2,3,4},triangles={{1,3,2},{1,2,4},{1,4,3},{2,3,4}},closed=true}
local geometry={vertices=vertices,components={component}}
local frame={{0,0,0},{1,0,0},{0,1,0},{0,0,1}}
local function make(handle,x)
 local baseline={geometry_complete=true,composition_signature='native-bytes',components={piece={supported=true,contacts={terrain=true}}},
  composition_pose={origin={x,0,0},columns={{1000,0,0},{0,1000,0},{0,0,1000}},scale=100},composition_frames={piece=frame}}
 local obj={handle=handle,SuperBigMapSupportBaseline=baseline}
 local r={obj=obj,complete=true,asset={signature='native-bytes'},nodes={}}
 local node={record=r,key='piece',geometry=geometry,component=component,supported=true,contacts={terrain=true}}
 r.nodes={node};return r,node,baseline
end
local a,an,ab=make(1,1000);local b,bn,bb=make(2,0)
an.contacts={['object:h2:piece']=true}
local context={list={a,b}}
assert(proof(context,{})['h1:piece'],'actual source contact may supplement a sparse first-witness capture')
ab.composition_pose.origin[1]=1003
assert(not proof(context,{})['h1:piece'],'a source gap outside tolerance cannot be invented as contact')
ab.composition_pose.origin[1]=1000
local saved=ab.composition_pose;ab.composition_pose=nil
assert(not proof(context,{})['h1:piece'],'missing source transform stays unknown');ab.composition_pose=saved
a.asset.signature='modified';assert(not proof(context,{})['h1:piece'],'changed geometry invalidates the source comparison');a.asset.signature='native-bytes'
ab.composition_frames.piece={{5,0,0},{6,0,0},{5,1,0},{5,0,1}}
assert(not proof(context,{})['h1:piece'],'captured bone frame, not the current frame, determines native contact')
ab.composition_frames.piece=frame
bn.supported=false;assert(not proof(context,{})['h1:piece'],'current unsupported neighbour cannot ground the piece')
print('native contact: exact source triangles, sparse capture completion, source-gap/missing-pose/mutated-geometry vetoes')

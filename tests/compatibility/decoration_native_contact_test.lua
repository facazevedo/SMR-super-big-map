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
local native=up(V.SeatingPlacementClear,'NativeComponent')
local contact=up(V.SeatingPlacementClear,'ComponentContact')
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
assert(contact(native(an),native(bn),2),'captured source geometry must retain actual native contact')
ab.composition_pose.origin[1]=1003
assert(not contact(native(an),native(bn),2),'a source gap outside tolerance cannot be invented as contact')
ab.composition_pose.origin[1]=1000
local saved=ab.composition_pose;ab.composition_pose=nil
assert(not native(an),'missing source transform stays unknown');ab.composition_pose=saved
a.asset.signature='modified';assert(not native(an),'changed geometry invalidates the source comparison');a.asset.signature='native-bytes'
ab.composition_frames.piece={{5,0,0},{6,0,0},{5,1,0},{5,0,1}}
assert(not contact(native(an),native(bn),2),'captured bone frame, not the current frame, determines native contact')
ab.composition_frames.piece=frame
local captured=native(an)
assert(native(an)==captured,'unchanged native comparison frame was rebuilt')
ab.composition_pose.origin[1]=1001
assert(native(an)~=captured,'changed native origin reused the old comparison pose')
ab.composition_pose.origin[1]=1000;captured=native(an)
ab.composition_pose.columns[1][1]=ab.composition_pose.columns[1][1]+.25
assert(native(an)~=captured,'changed native basis reused the old comparison pose')
ab.composition_pose.columns[1][1]=ab.composition_pose.columns[1][1]-.25
captured=native(an);frame[1][3]=frame[1][3]+1
assert(native(an)~=captured,'changed native fragment frame reused the old comparison pose')
frame[1][3]=frame[1][3]-1
print('native contact: exact source triangles, sparse capture completion, source-gap/missing-pose/mutated-geometry vetoes')

-- Seating may retain the same verified native/current intersecting component
-- pair, but cannot introduce a collision or use missing source geometry.
local contexts=up(V.SeatingPlacementClear,'contexts')
local function bounds(x,y,z)
 return {minx=function()return x end,miny=function()return y end,minz=function()return z end,
  maxx=function()return x+1000 end,maxy=function()return y+1000 end,maxz=function()return z+1000 end}
end
local function pose(r,b)
 local p=b.composition_pose
 r.pose={matrix={origin={table.unpack(p.origin)},columns=p.columns},shift={0,0,0},scale=100}
 function r.obj:GetObjectBBox()return bounds(table.unpack(r.pose.matrix.origin))end
 function r.obj:GetEntity()return 'fixture rock'end
end
pose(a,ab);pose(b,bb);bn.supported=true
local owner={};contexts[owner]={by_object={[a.obj]=a,[b.obj]=b},index={Query=function()return {bn}end}}
assert(V.SeatingPlacementClear(owner,a.obj,{1000,0,-1,2000,1000,999}),'verified native/current intersection was treated as a new collision')
ab.composition_pose.origin[1]=1003
assert(not V.SeatingPlacementClear(owner,a.obj,{1000,0,-1,2000,1000,999}),'a non-native intersection was permitted')
ab.composition_pose.origin[1]=1000
local prior=b.obj.SuperBigMapSupportBaseline;b.obj.SuperBigMapSupportBaseline=nil
assert(not V.SeatingPlacementClear(owner,a.obj,{1000,0,-1,2000,1000,999}),'missing neighbour baseline permitted collision')
b.obj.SuperBigMapSupportBaseline=prior
a.obj.SuperBigMapDecorEnginePass=true
assert(not V.SeatingPlacementClear(owner,a.obj,{1000,0,-1,2000,1000,999}),'native intersection rule leaked to top-up movement')
a.obj.SuperBigMapDecorEnginePass=nil
a.pose.matrix.origin={0,0,1003}
assert(not V.SeatingPlacementClear(owner,a.obj,{0,0,999,1000,1000,1999}),'new current collision was permitted by old source contact')
print('seating intersections: native and current proof required; new, unknown and top-up collisions vetoed')

-- Later proposals must see previously seated poses, not their stale broad-phase
-- records. An overlapping object box alone is not a collision.
a.pose.matrix.origin={1000,0,0}
local moved={obj=b.obj,complete=true,asset=b.asset,
 pose={matrix={origin={10000,0,0},columns=bb.composition_pose.columns},shift={0,0,0},scale=100}}
moved.nodes={{record=moved,geometry=geometry,component=component,key='piece',bounds={10000,0,0,11000,1000,1000}}}
contexts[owner].seated={[b.obj]=moved}
assert(V.SeatingPlacementClear(owner,a.obj,{1000,0,-1,2000,1000,999}),
 'stale pre-move neighbour must not block a later proposal')
moved.pose.matrix.origin={1000,0,-1};moved.nodes[1].bounds={1000,0,-1,2000,1000,999}
b.obj.SuperBigMapSupportBaseline=nil
assert(not V.SeatingPlacementClear(owner,a.obj,{1000,0,-1,2000,1000,999}),
 'fresh moved-neighbour geometry must veto an unproven collision')
print('seating transaction: current moved geometry replaces stale bounds for later candidates')

-- Planning-only caching may reuse unchanged source pair proofs, never the
-- contact at a proposed pose. Independent actual-pose checks get no cache.
contexts[owner].seated=nil;b.obj.SuperBigMapSupportBaseline=prior
local contact_index
for i=1,90 do local n=debug.getupvalue(V.SeatingPlacementClear,i);if n=='ComponentContact' then contact_index=i;break end end
local calls=0
debug.setupvalue(V.SeatingPlacementClear,contact_index,function(...)calls=calls+1;return contact(...)end)
local search={}
assert(V.SeatingPlacementClear(owner,a.obj,{1000,0,-1,2000,1000,999},nil,search))
local first=calls
assert(V.SeatingPlacementClear(owner,a.obj,{1000,0,-2,2000,1000,998},nil,search))
assert(calls-first==1 and first==3,'only unchanged current/native pair proofs may be reused')
local second=calls
assert(V.SeatingPlacementClear(owner,a.obj,{1000,0,-2,2000,1000,998}))
assert(calls-second==3,'independent placement verification must rebuild source pair proofs')
assert(not V.SeatingPlacementClear(owner,a.obj,{1000,0,1,2000,1000,1001},nil,search),
 'cached original pair must not permit a disallowed upward collision')
assert(search.blocker==bn,'rejected neighbour becomes an ordering hint only')
assert(V.SeatingPlacementClear(owner,a.obj,{5000,0,0,6000,1000,1000},nil,search),
 'blocker hint must not reuse an old contact verdict at a new pose')
debug.setupvalue(V.SeatingPlacementClear,contact_index,contact)
print('seating search: immutable source-pair reuse, fresh candidate checks and independent verification')

-- Cache sharing is scoped to one proposal and one exact source frame. Different
-- components of that same rigid object may share it, but later positions may not.
local seen={}
debug.setupvalue(V.SeatingPlacementClear,contact_index,function(own)
 seen[#seen+1]=own.transform_record;return false,true
end)
a.nodes={an,{record=a,geometry=geometry,component=component}}
assert(V.SeatingPlacementClear(owner,a.obj,{5000,0,0,6000,1000,1000}))
assert(#seen==2 and seen[1]==seen[2],'one rigid proposal rebuilt the same pose for every component')
local prior_transform=seen[1];seen={}
assert(V.SeatingPlacementClear(owner,a.obj,{6000,0,0,7000,1000,1000}))
assert(seen[1]==seen[2] and seen[1]~=prior_transform,'transformed vertices leaked between proposed positions')
local separate={pose={matrix=a.pose.matrix,shift={0,0,0},scale=100}}
a.nodes[2].transform_record=separate;seen={}
assert(V.SeatingPlacementClear(owner,a.obj,{6000,0,0,7000,1000,1000}))
assert(seen[1]~=seen[2],'distinct source frames incorrectly share transformed geometry')
debug.setupvalue(V.SeatingPlacementClear,contact_index,contact)
print('rigid proposal caches: same-frame sharing, separate-frame isolation and fresh-position lifetime')

local globals={guim=100}
SuperBigMap={Engine={Global=function(n)return globals[n]end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
local formats={fmt_float32_c3=3,fmt_uint8_c4=49,fmt_unorm8_c4=39}
local pts={{0,0,0},{1,0,0},{0,1,0},{0,0,0},{1,0,0},{0,1,0}}
local bytes={}
for i,p in ipairs(pts)do
 for b in string.pack('<BBBBBBBBfff',i<=3 and 0 or 1,0,0,0,255,0,0,0,table.unpack(p)):gmatch('.')do bytes[#bytes+1]=b:byte()end
end
local data={maxBonesPerVertex=1,geom={vertices=bytes,indices={0,1,2,3,4,5},numVertices=6,
 vertexLayout={streams={{stride=20}},attributes={{name='pos',format=3,offset=8},
 {name='bone_indices_1',format=49,offset=0},{name='bone_weights_1',format=39,offset=4}}}}}
local g,why=G.Decode(data,{0,0,0,1,1,0},formats)
assert(g,why);assert(g.rigid_skin and #g.components==2,'coincident vertices on different bones must not weld')
assert(g.components[1].bone==1 and g.components[2].bone==2)
bytes[21]=1;g=assert(G.Decode(data,{0,0,0,1,1,0},formats));assert(not g.rigid_skin,'mixed-bone triangles require a separate decoder')
bytes[21]=0;bytes[5]=254;g=assert(G.Decode(data,{0,0,0,1,1,0},formats));assert(not g.rigid_skin,'non-unit weights cannot pass')
bytes[5]=255;data.maxBonesPerVertex=2;g=assert(G.Decode(data,{0,0,0,1,1,0},formats));assert(not g.rigid_skin)
local function v(x,y,z,w)return {x=function()return x end,y=function()return y end,z=function()return z end,w=function()return w end}end
local visual={}
local bind
bind=setmetatable({},{__mul=function(a,b)
 assert(a==bind) -- only inverse bind * native visual, never the reverse
 assert(b==visual)
 return {values=function()return v(0,-2,0,10),v(2,0,0,20),v(0,0,2,30),v(0,0,0,1)end}
end})
g={rigid_skin=true,bones={{name='stone'}},bind_pose={bind}}
local posed={GetVisualBoneTransform=function(_,name)assert(name=='stone');return visual end,GetWorldScale=function()return 200 end}
local matrix=assert(G.BoneMatrix(posed,g,1))
assert(matrix.origin[1]==1000 and matrix.origin[3]==3000)
assert(matrix.columns[1][2]==200 and matrix.columns[2][1]==-200)
assert(G.RigidMatrix(matrix))
matrix.columns[2][1]=-100;assert(not G.RigidMatrix(matrix),'nonuniform scale is not a rigid inverse')
matrix.columns[2][1]=-200;matrix.columns[2][2]=1;assert(not G.RigidMatrix(matrix),'shear must be inconclusive')
assert(not G.BoneMatrix({GetVisualBoneTransform=function()return nil end},g,1),'unavailable/offscreen bone pose must not pass')
posed.GetWorldScale=function()return 300 end
assert(not G.BoneMatrix(posed,g,1),'stale pre-expansion bone transforms must not pass')
print('rigid skinning: validated weights, bone-safe seams, row-vector transform, affine guards and missing pose failures passed')

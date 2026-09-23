SuperBigMap={Engine={Global=function()return nil end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
local formats={fmt_sint16_c2=28,fmt_sint16_c1=26,fmt_float32_c3=3}
local function mesh(points,indices)
 local bytes={}
 for _,p in ipairs(points)do for byte in string.pack('<fff',table.unpack(p)):gmatch('.')do bytes[#bytes+1]=byte:byte()end end
 return {maxBonesPerVertex=0,geom={vertices=bytes,indices=indices,numVertices=#points,
  vertexLayout={streams={{stride=12}},attributes={{name='pos',format=3,offset=0}}}}}
end
local pts={{0,0,0},{1,0,0},{0,1,0},{0,0,0},{0,1,0},{0,0,1}, {5,5,5},{6,5,5},{5,6,5}}
local data=mesh(pts,{0,1,2,3,4,5,6,7,8,0,6,6})
local decoded,err=G.Decode(data,{0,0,0,6,6,5},formats)
assert(decoded,err);assert(#decoded.components==2,'UV seam welded, detached triangle retained')
assert(#decoded.components[1].triangles==2)
assert(decoded.components[2].bounds[3]==5)
data.geom.indices[1]=99;assert(not G.Decode(data,{0,0,0,6,6,5},formats));data.geom.indices[1]=0
assert(not G.Decode(data,{0,0,0,7,6,5},formats),'bounds mismatch must be inconclusive')
data.geom.vertexLayout.attributes[1].format=99
assert(not G.Decode(data,{0,0,0,6,6,5},formats),'unknown encoding must be inconclusive')
local q={-32767,-32767,-32767,32767,-32767,-32767,0,32767,32767};local bytes={}
for _,value in ipairs(q)do local packed=string.pack('<i2',value);bytes[#bytes+1]=packed:byte(1);bytes[#bytes+1]=packed:byte(2)end
data={maxBonesPerVertex=0,geom={vertices=bytes,indices={0,1,2},numVertices=3,
 vertexLayout={streams={{stride=6}},attributes={{name='pos_xy',format=28,offset=0},{name='pos_z',format=26,offset=4}}}}}
decoded,err=G.Decode(data,{-3,-3,490,3,3,496},formats)
assert(decoded,err);assert(decoded.vertices[1][3]==490 and decoded.vertices[3][3]==496)
data.maxBonesPerVertex=nil;assert(not G.Decode(data,{-3,-3,490,3,3,496},formats),'missing animation metadata')
local entity=G.Entity('missing',0);assert(not entity.complete and entity.reason)
print('decoration geometry: split/float decoding, disconnected fragments, exact seams, bounds guard and missing-data failures passed')
-- Fused extrema capture must retain the scalar seven-pass witness order and
-- first-vertex tie handling, not merely equivalent bounding-box coordinates.
math.randomseed(379)
for trial=1,250 do
 local points,indices={},{}
 local bounds={math.huge,math.huge,math.huge,-math.huge,-math.huge,-math.huge}
 for i=1,36 do
  points[i]={math.random(-7,7),math.random(-7,7),math.random(-7,7)}
  for a=1,3 do bounds[a]=math.min(bounds[a],points[i][a]);bounds[a+3]=math.max(bounds[a+3],points[i][a]) end
 end
 for i=0,35,3 do indices[#indices+1]=i;indices[#indices+1]=i+1;indices[#indices+1]=i+2 end
 local g=assert(G.Decode(mesh(points,indices),bounds,formats))
 for _,component in ipairs(g.components) do
  local expected,seen={},{}
  for axis=1,3 do for _,sign in ipairs({-1,1}) do
   local best
   for _,i in ipairs(component.vertices) do
    if not best or g.vertices[i][axis]*sign>g.vertices[best][axis]*sign then best=i end
   end
   if best and not seen[best] then expected[#expected+1]=g.vertices[best];seen[best]=true end
  end end
  assert(#expected==#component.samples,'extrema witness count changed')
  for i,p in ipairs(expected) do assert(component.samples[i]==p,'extrema witness identity/tie order changed') end
  local bottom
  for _,i in ipairs(component.vertices) do if not bottom or g.vertices[i][3]<g.vertices[bottom][3] then bottom=i end end
  assert(component.bottom==g.vertices[bottom],'bottom witness identity changed')
 end
end
print('geometry fused extrema: 250 meshes retain all scalar witness identities and tie order')

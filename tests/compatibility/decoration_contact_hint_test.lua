SuperBigMap={Engine={Global=function(k)if k=='guim' then return 1 end end}}
dofile('Code/sbm_decoration_geometry.lua');dofile('Code/sbm_decoration_validation.lua')
local V,G=SuperBigMap.DecorationValidation,SuperBigMap.DecorationGeometry
local function up(fn,name)
 for i=1,100 do local k,v=debug.getupvalue(fn,i);if k==name then return v elseif not k then break end end
end
local raw=up(up(up(V.Validate,'Scan'),'ComponentContact'),'RawComponentContact')
local function mesh(points)
 local c={vertices={1,2,3},triangles={{1,2,3}},bounds=G.Bounds()}
 for _,p in ipairs(points) do G.Extend(c.bounds,p) end
 return {vertices=points},c
end
local ag,ac=mesh({{0,0,0},{3,0,0},{0,3,0}})
local bg,bc=mesh({{1.5,1.4,-1},{1.5,1.4,1},{1.55,1.45,0}})
local function node(g,c,x,y,z)
 return {geometry=g,component=c,record={pose={scale=100,shift={0,0,0},
  matrix={origin={x or 0,y or 0,z or 0},columns={{1,0,0},{0,1,0},{0,0,1}}}}}}
end
assert(raw(node(ag,ac),node(bg,bc),.001),'initial contact missing')
assert(ac.contact_hints[bc],'no triangle hint recorded')
local tree=G.TriangleTree
G.TriangleTree=function()error('translated certified triangle pair unnecessarily entered BVH')end
assert(raw(node(ag,ac,1000,2000,3000),node(bg,bc,1000,2000,3000),.001))
assert(raw(node(ag,ac),node(bg,bc,-.61,0,0),.001),'changed-bucket exact face witness unnecessarily entered BVH')
G.TriangleTree=tree
-- Same coarse bucket and overlapping boxes, but current triangles no longer
-- touch: the old witness MUST be tested again and rejected at this new pose.
local hit,separated=raw(node(ag,ac),node(bg,bc,.2,.2,0),.001)
assert(not hit and separated,'old contact verdict leaked through a changed pose')
local other_g,other_c=mesh({{1.5,1.4,-1},{1.5,1.4,1},{1.55,1.45,0}})
G.TriangleTree=function()error('expected fresh component query')end
assert(not pcall(raw,node(ag,ac),node(other_g,other_c),.001),'hint crossed component identity')
G.TriangleTree=tree
local big_g,big_c=mesh({{-100,-100,-100},{100,100,-100},{0,0,100}})
for i=1,65 do
 -- Force fresh bucket discoveries so eviction is exercised even though the
 -- last exact triangle witness can now satisfy many of these shifted poses.
 local previous=ac.contact_hints[big_c];if previous then previous.recent=nil end
 assert(raw(node(ag,ac),node(big_g,big_c,i*.61,i*.61,0),.001))
end
local pair=ac.contact_hints[big_c]
assert(#pair.order==32,'relative-pose hint buckets grew without bound')
local count=0
for key,bucket in pairs(pair) do if key~='order' and key~='recent' then count=count+1;assert(#bucket<=4) end end
assert(count==32,'evicted hint bucket leaked')
print('positive contact hints: fresh-pose proof, changed pose, component identity and bounded eviction passed')

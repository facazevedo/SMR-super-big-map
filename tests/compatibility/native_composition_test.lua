-- Owner ruling 2026-09-25 (vanilla compositions): rocks keep vanilla's authored floats and rim
-- gaps scaled with the rock; only what the expansion made worse is corrected, and only back to
-- the vanilla relationship.
local function read(path)local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua')
dofile('Code/sbm_decoration_seating.lua')
local G,S=SuperBigMap.DecorationGeometry,SuperBigMap.DecorationSeating
local code=read('Code/sbm_decoration_validation.lua')

-- 1. Planner: no vanilla targets plans exactly as before; targets replace contact / full cover.
local function comp(low,high,extra)
 local c={vertices={{0,0,low},{10,0,high}},height=high-low}
 for k,v in pairs(extra or {}) do c[k]=v end
 return c
end
local flat=function()return 0 end
local plain=S.Plan({comp(40,140)},flat,{tile=100})
assert(plain and plain.dz==-40,'a floating component still seats to terrain contact')
local kept=S.Plan({comp(40,140,{allowed_clearance=35})},flat,{tile=100})
assert(kept and kept.dz==-5,'a widened vanilla float returns to its vanilla clearance only')
local authored=S.Plan({comp(40,140,{terrain_root=false}),comp(-5,120)},flat,{tile=100})
assert(authored and authored.dz==0,'a vanilla-authored float demands no terrain contact')
local rim=S.Plan({comp(-30,400,{foundation={gap=120}})},flat,{tile=100})
assert(rim and rim.dz==-122,'an open base still closes fully without a vanilla gap')
local vanilla_rim=S.Plan({comp(-30,400,{foundation={gap=120,allowed_gap=43}})},flat,{tile=100})
assert(vanilla_rim and vanilla_rim.dz==-77,'a widened rim closes back to its vanilla gap')

-- 2. Vanilla measurement and the authored rule on synthetic native / expanded terrain.
local block=assert(code:match('(local NATIVE_GROUND_VERSION.-)\nlocal function WorldBounds'))
local terrain_height=1333
local refs={}
local env=setmetatable({SBM={NativeHeightReferences=refs},Geometry={SupportVertices=function(_,c)return c.vertices end,
 FoundationClearance=G.FoundationClearance},
 Global=function(n)
  if n=='const' then return {HeightTileSize=100} end
  if n=='terrain' then return {GetHeight=function(_,p)return terrain_height end} end
 end,
 Matrix=function(r)return r.matrix end,Point=function(p)return p end,
 FoundationDescriptors=function(asset)return asset.found end,
 floor=math.floor,min=math.min,max=math.max},{__index=_G})
env.World=assert(load(assert(code:match('(local function World%(.-\nend)\n'))..'\nreturn World','world','t',env))()
local run=assert(load(block..'\nreturn NativeGround,MarkNativeAuthored','native','t',env))
local NativeGround,MarkNativeAuthored=run()
local grid={get=function(_,x,y)return 1000 end}
local map={}
refs[map]={grid=grid,w=200,h=200,tile=100,height_scale=1}
local function rock(local_low,local_high,extra)
 local obj={SuperBigMapNativeSourceX=5000,SuperBigMapNativeSourceY=5000,SuperBigMapNativeSourceZ=1000,
  SuperBigMapNativeSourceScale=100,SuperBigMapNativeSourceAngle=0,GetAngle=function()return 0 end,GetScale=function()return 133 end}
 for k,v in pairs(extra or {}) do obj[k]=v end
 local vertices={{-10,-10,local_low},{10,10,local_high}}
 local node={key='0:mesh:1',supported=false,geometry={vertices=vertices},component={vertices={1,2}}}
 local record={obj=obj,pose={origin={6667,6667,1333},shift={0,0,0}},asset={},nodes={node},
  matrix={origin={6667,6667,1333},columns={{1.33,0,0},{0,1.33,0},{0,0,1.33}}}}
 return record,node,obj
end
-- A pebble resting 117 above vanilla ground: now 155.6 above the scaled ground -> authored.
local record,node,obj=rock(117,200)
MarkNativeAuthored(map,record)
assert(math.abs(obj.SuperBigMapNativeGround.nodes['0:mesh:1']-117)<1e-6,'vanilla clearance measured at the vanilla pose')
assert(node.native_authored and math.abs(node.native_allowed-(117*1.33+4))<1e-6,'a vanilla float is authored')
assert(env.Validator==nil)
-- The expansion lowered the ground under it by 33 more: not authored, target = vanilla clearance.
terrain_height=1300
record,node=rock(117,200);MarkNativeAuthored(map,record)
assert(not node.native_authored and math.abs(node.native_allowed-(117*1.33+4))<1e-6,'a widened float keeps a vanilla target')
-- A piece embedded in vanilla ground that floats now keeps the strict terrain rule.
record,node=rock(-20,80);MarkNativeAuthored(map,record)
assert(not node.native_authored and node.native_allowed==nil,'a vanilla-grounded piece stays strict')
terrain_height=1333
-- No vanilla reference: mod top-ups, rotated rocks, no grid.
record,node=rock(117,200,{SuperBigMapDecorEnginePass=true});MarkNativeAuthored(map,record)
assert(not node.native_authored and node.native_allowed==nil,'top-ups have no vanilla reference')
record,node=rock(117,200,{SuperBigMapNativeSourceAngle=5});MarkNativeAuthored(map,record)
assert(not node.native_authored,'a rotated rock has no vanilla reference')
local stored_record,stored_node,stored_obj=rock(117,200);MarkNativeAuthored(map,stored_record)
refs[map]=nil
local reload=rock(117,200);reload.obj.SuperBigMapNativeGround=stored_obj.SuperBigMapNativeGround
MarkNativeAuthored(map,reload)
assert(reload.nodes[1].native_authored,'stored vanilla evidence is reused without the grid')
record,node=rock(117,200);MarkNativeAuthored(map,record)
assert(not node.native_authored,'no grid and no stored evidence keeps the strict rule')
refs[map]={grid=grid,w=200,h=200,tile=100,height_scale=1}
-- Open rim: vanilla gap 30 at the vanilla pose.
local r2,_,o2=rock(-5,100)
local g={vertices={{-20,-20,30},{20,-20,30},{20,20,30},{-20,20,30}}}
r2.asset={found={{geometry=g,rim={vertices={1,2,3,4},edges={{1,2},{2,3},{3,4},{4,1}}}}}}
local native=NativeGround(map,r2)
assert(native and math.abs(native.rim-30)<1e-6,'vanilla rim gap measured at the vanilla pose')

-- 3. Classify accepts vanilla-authored floats, still refuses real defects.
local classify=assert(load(assert(code:match('(function Validator%.Classify.-\nend)\n'))..'\nreturn Validator.Classify','classify','t',
 setmetatable({Validator={}},{__index=_G})))()
assert(classify({{supported=false,native_authored=true},{supported=true}},true)=='valid','authored float is valid')
assert(classify({{supported=false,defect=true,native_authored=true}},true)=='valid','authored float is not a defect')
assert(classify({{supported=false,defect=true}},true)=='confirmed defect','real floats stay defects')
assert(classify({{supported=false}},true)=='inconclusive','unproven support stays inconclusive')
print('native compositions: planner targets, vanilla-pose measurement, authored/widened/strict cases, stored evidence, classification')

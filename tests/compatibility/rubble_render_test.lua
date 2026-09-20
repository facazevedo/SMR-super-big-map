local f=assert(io.open('Code/sbm_terrain_copy.lua','r'))
local source=f:read('*a');f:close()
local block=assert(source:match('local cave_in_ground_mesh_lods.-\n%-%- CaveInRubble and TunnelBlockerRubble'))
local calls,reads=0,0
local map={mapdata={env='Underground'},SuperBigMapUndergroundPrepared=true}
local o={class='CaveInRubble',entity='CaveIn_Buildings',state='falling',phase=1234,work=50000,scale=133}
function o:GetEntity() return self.entity end
function o:GetMap() return map end
local parts={{mesh='Meshes/CaveIn_Buildings_mesh.sub_0.hgrm',material='air'},
 {mesh='Meshes/CaveIn_Buildings_mesh.sub_1.hgrm',material='ground'}}
local signature={MaxBonesPerVertex=0,NumVertices=144,NumIndices=516,
 Box={min=function() return {z=function() return 493.443 end} end,max=function() return {z=function() return 498.931 end} end}}
local globals={CurrentMap=map,GetStateIdx=function(s)return s end,GetStateLODCount=function()return 1 end,
 GetStateLODMeshData=function()reads=reads+1;return parts end,
 GetRenderMeshProperties=function(path)return path==parts[1].mesh and signature or {MaxBonesPerVertex=1} end,
 ResourceManager={GetResourceID=function(p)return p end,GetResource=function(p,wait)assert(wait);return p end},
 GetMeshLodsData=function(mesh,material)assert(mesh==parts[2].mesh and material=='ground');return {mesh=mesh} end,
 SetRenderingMeshLods=function(obj,lods)assert(obj==o and lods.mesh==parts[2].mesh);calls=calls+1 end}
local env=setmetatable({Global=function(n)return globals[n] end,
 Engine={MapDataEnvironment=function(md)return md.env end}},{__index=_G})
local function load_functions()
 return assert(load(block..'\nreturn InitializeCaveInRendering,InitializeUndergroundRubbleRendering','render','t',env))()
end
local initialize,activate=load_functions()
assert(initialize(o) and calls==1)
assert(o.state=='falling' and o.phase==1234 and o.work==50000 and o.scale==133)
assert(initialize(o) and calls==2 and reads==2,'one cached descriptor, not a per-object resource rebuild')
map.SuperBigMapUndergroundPrepared=false
assert(not initialize(o))
o.SuperBigMapCaveInShapeScaleXMul=8192;o.SuperBigMapCaveInShapeScaleXDiv=6144
assert(initialize(o),'initial generation is supported before prepared flag')
for _,reason in ipairs({'class','entity','surface'}) do
 o.class=reason=='class' and 'TunnelBlockerRubble' or 'CaveInRubble'
 o.entity=reason=='entity' and 'CaveIn_UndergroundMicroDome' or 'CaveIn_Buildings'
 map.mapdata.env=reason=='surface' and 'Surface' or 'Underground'
 assert(not initialize(o),reason)
end
o.class='CaveInRubble';o.entity='CaveIn_Buildings';map.mapdata.env='Underground'
map.SuperBigMapUndergroundPrepared=true
function map:MapForEach(scope,class,fn)assert(scope=='map' and class=='CaveInRubble');fn(o) end
assert(activate(map)==1)
globals.CurrentMap={};assert(activate(map)==0);globals.CurrentMap=map
signature.NumVertices=145;initialize=load_functions();assert(not initialize(o),'changed asset must not be filtered')
signature.NumVertices=144
signature.Box.min=function()return {z=function()return 0 end}end
initialize=load_functions();assert(not initialize(o),'fixed native asset must be retained')
globals.SetRenderingMeshLods=nil;initialize=load_functions();assert(not initialize(o),'unavailable renderer API is safe')
local transform=assert(source:match('local function ScaleCapturedCaveInsToFull.-\nend\n'))
assert(transform:find('obj:SetScale(target_scale)',1,true)<transform:find('InitializeCaveInRendering(obj)',1,true))
f=assert(io.open('Code/sbm_lifecycle.lua','r'));local lifecycle=f:read('*a');f:close()
for _,event in ipairs({'LoadGame','CurrentMapChangeDone'}) do
 local handler=assert(lifecycle:match('RegisterOnce%("'..event..'", function.-\nend%)'))
 assert(handler:find('InitializeUndergroundRubbleRendering',1,true),event)
end
assert(lifecycle:find('RegisterOnce("BuildingInit"',1,true),'new gameplay cave-ins are covered')
print('rubble rendering: defect signature, cache, map/class guards, untouched gameplay/animation, fresh/load/switch/new-object paths passed')

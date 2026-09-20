local f=assert(io.open('Code/sbm_terrain_copy.lua','r'))
local source=f:read('*a');f:close()
local block=assert(source:match('local cave_in_clip_plane.-\n%-%- CaveInRubble and TunnelBlockerRubble'))
local calls,reads=0,0
local map={mapdata={env='Underground'},SuperBigMapUndergroundPrepared=true}
local o={class='CaveInRubble',entity='CaveIn_Buildings',state='idle',phase=0,work=50000,scale=133,clip=0}
function o:GetEntity() return self.entity end
function o:GetMap() return map end
function o:GetState()return self.state end
function o:GetAnimPhase(channel)assert(channel==1);return self.phase end
function o:GetClipPlane()return self.clip end
function o:SetClipPlane(p)self.clip=p end
function o:TimeToAnimEnd()return 3333-self.phase end
function o:CreateGameTimeThread(fn)self.pending=fn;return fn end
local parts={{mesh='Meshes/CaveIn_Buildings_mesh.sub_0.hgrm',material='air'},
 {mesh='Meshes/CaveIn_Buildings_mesh.sub_1.hgrm',material='ground'}}
local signature={MaxBonesPerVertex=0,NumVertices=144,NumIndices=516,
 Box={min=function() return {z=function() return 493.443 end} end,max=function() return {z=function() return 498.931 end} end}}
local native={native=true,parts=parts}
local globals={CurrentMap=map,GetStateIdx=function(s)return s end,GetStateLODCount=function()return 1 end,
 GetStateLODMeshData=function()reads=reads+1;return parts end,
 GetRenderMeshProperties=function(path)return path==parts[1].mesh and signature or {MaxBonesPerVertex=1} end,
 ResourceManager={GetResourceID=function(p)return p end},
 GetStateMeshLodsData=function(entity,state)assert(entity==o.entity and state==o.state);return native end,
 SetRenderingMeshLods=function(obj,lods)assert(obj==o and lods==native and #lods.parts==2);calls=calls+1 end,
 point=function(x,y,z)return {x=x,y=y,z=z}end,guim=100,
 EncodePlane=function(norm,base,loc)assert(norm.z==-4096 and base.z==49000 and loc);return 987 end,
 GetAnimDuration=function(entity,state)assert(entity==o.entity and state=='falling');return 3333 end,
 IsValid=function(obj)return obj==o and not obj.deleted end,
 Sleep=function(ms)assert(ms>0 and ms<=500);o.phase=math.min(3332,o.phase+ms)end}
local notifications=0
local env=setmetatable({SuperBigMap={DecorationValidation={Schedule=function(m,why)assert(m==map and why=='cave-in settled');notifications=notifications+1 end}},Global=function(n)return globals[n] end,
 Engine={MapDataEnvironment=function(md)return md.env end}},{__index=_G})
local function load_functions()
 return assert(load(block..'\nreturn InitializeCaveInRendering,InitializeUndergroundRubbleRendering','render','t',env))()
end
local initialize,activate=load_functions()
assert(initialize(o) and calls==1 and o.clip==987)
assert(o.state=='idle' and o.phase==0 and o.work==50000 and o.scale==133)
assert(initialize(o) and calls==2 and reads==2,'one cached signature/plane')
assert(notifications==1,'unchanged clip does not schedule duplicate validation')
o.state='falling';o.phase=1234
assert(initialize(o) and o.clip==0 and o.pending,'do not clip falling rubble')
local first=o.pending;initialize(o);assert(o.pending==first,'one settle thread per object')
assert(o.state=='falling' and o.phase==1234 and o.work==50000 and o.scale==133)
o.pending();assert(o.clip==987 and o.phase==3332 and o.state=='falling','no state reset')
o.clip=123;local prior=calls;assert(not initialize(o) and o.clip==123 and calls==prior,'foreign clip preserved')
o.clip=0
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
local handler=assert(lifecycle:match('RegisterOnce%("BuildingInit", function.-\nend%)'))
assert(handler:find('Sleep(1)',1,true)<handler:find('InitializeCaveInRendering(obj)',1,true),'inspect final spawn pose')
print('rubble rendering: native two-part descriptor, settled-only clip, signature/cache/ownership, untouched gameplay, lifecycle passed')

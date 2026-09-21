local function point(x,y,z)return {xyz=function()return x,y,z end}end
local parent={class='ExampleWonder',GetSpotRange=function()return 2,4 end,GetSpotName=function()return 'Effect' end}
local obj={class='ParSystem',GetParent=function()return parent end,GetEntity=function()return '' end,
 GetParticlesName=function()return 'ExampleMist' end,GetScale=function()return 100 end,
 GetAttachSpot=function()return 3 end,GetAttachOffset=function()return point(0,0,0)end,
 GetAttachAngle=function()return 0 end,GetEnumFlags=function()return 0 end}
local fx={id='native-example',Attach=true,Source='Actor',SourceRemap=false,Actor='ExampleWonder',Target='any',
 Particles='ExampleMist',Particles2='',Particles3='',Particles4='',Spot='Effect',Scale=100,ScaleMember='',
 Orientation='',Offset=point(0,0,0),Flags='',Disabled=false,GetAssignedFX=function()return {obj}end}
local globals={IsKindOf=function(o,c)return o==obj and c=='ParSystem' end,IsValid=function(o)return o~=nil end,
 IsParticleSystem=function(n)return n=='ExampleMist' end,FXLists={ActionFXParticles={fx}},
 GetRenderingMeshLods=function()return {get=function()end}end,const={efWalkable=1,efCollision=2,efApplyToGrids=4}}
SuperBigMap={Engine={Global=function(n)return globals[n]end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
assert(G.ParticleAttachment(obj),'native assigned effect with exact recipe and placement')
fx.GetAssignedFX=function()return {}end;assert(not G.ParticleAttachment(obj),'matching name alone is not native ownership');fx.GetAssignedFX=function()return {obj}end
for k,bad in pairs({Actor='OtherWonder',Attach=false,SourceRemap='Prop',ScaleMember='dynamic',Orientation='Random2D',Particles='wrong',Spot='Wrong',Scale=133,Disabled=true})do
 local old=fx[k];fx[k]=bad;assert(not G.ParticleAttachment(obj),'changed rule: '..k);fx[k]=old
end
obj.GetAttachOffset=function()return point(0,0,1)end;assert(not G.ParticleAttachment(obj),'shifted emitter fails');obj.GetAttachOffset=function()return point(0,0,0)end
obj.GetAttachAngle=function()return 60 end;assert(not G.ParticleAttachment(obj),'rotated emitter fails');obj.GetAttachAngle=function()return 0 end
obj.GetAttachSpot=function()return 8 end;assert(not G.ParticleAttachment(obj),'spot index outside native range');obj.GetAttachSpot=function()return 3 end
globals.GetRenderingMeshLods=function()return {get=function()return {lods={}}end}end;assert(not G.ParticleAttachment(obj),'mesh override cannot masquerade as a native emitter')
globals.GetRenderingMeshLods=function()return {get=function()end}end
obj.GetEnumFlags=function()return 1 end;assert(not G.ParticleAttachment(obj),'physical flags need geometry inspection')
print('particles: exact native FX ownership, asset identity, parent/spot/scale/offset/orientation, no physical override')

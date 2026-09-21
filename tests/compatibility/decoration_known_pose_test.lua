-- Public native reference verification; no sandboxed file APIs are supplied.
local created,removed,bad_phase,missing_pose,fail_cleanup,change_map=0,0
local ignore_cleanup=false
local reference_objects={}
local active_map={};local reference_origin={0,0,-10000}
local function point(x,y,z)return {xyz=function()return x,y,z end}end
local globals={guim=100,point=point,CurrentMap=active_map,
 const={MaxAnimChannels=4,eDontLoop=32768,efCollision=1,efWalkable=2,efApplyToGrids=4,efSelectable=8,efLightShadow=16,efSunShadow=32,gofPriorityAnim=128},
 GetAnimDuration=function(_,state)return (state==0 or state=='idle') and 33 or 3333 end,
 GetStateAnimFile=function(_,state)return 'Animations/CaveIn_Buildings_'..((state==0 or state=='idle') and 'idle' or 'falling')..'.hgacl' end,
 CanYield=function()return true end,IsValid=function(o)return not o.dead end,
 DoneObject=function(o)
  if ignore_cleanup then return end
  assert(not o.dead,'cleanup retried an already deleted reference')
  o.dead=true;removed=removed+1;if fail_cleanup then error('injected cleanup failure')end
 end}
globals.Sleep=function()if change_map then globals.CurrentMap={}end end
SuperBigMap={Engine={Global=function(n)return globals[n]end}}
dofile('Code/sbm_decoration_known_poses.lua')
local bank=SuperBigMap.DecorationKnownPoses
local matrices={}
for name,pose in pairs(bank.poses)do
 matrices[name]={};local bytes=pose.hex:gsub('..',function(h)return string.char(tonumber(h,16))end)
 for at=1,#bytes,49 do
  local n,x,y,z,a,b,c,d,e,f,g,h,i=string.unpack('<Bffffffffffff',bytes,at)
  matrices[name][n]={origin={x,y,z},columns={{a,b,c},{d,e,f},{g,h,i}}}
 end
end
local bones,bind={},{}
for i=1,112 do bones[i]={name='bone'..i};bind[i]={}end
local bp={x=function()return 0 end,y=function()return 0 end,z=function()return 0 end}
globals.GetRenderMeshProperties=function()return {Box={min=function()return bp end,max=function()return bp end}}end
globals.ResourceManager={GetResourceID=function(p)return p end,LoadToolResource=function(path)
 return {AsAnyRef=function()return {get=function()
  if path==bank.mesh then return {skeleton={skeleton="TResRef('"..bank.skeleton.."')",bindPose=bind}}end
  return {bones=bones}
 end}end}
end}
local prototype={}
function prototype:ClearEnumFlags(flags)assert(flags==63);self.nonphysical=true end
function prototype:SetGameFlags(flags)assert(flags==128);self.priority=true end
function prototype:ChangeEntity(e)assert(e==bank.entity)end
function prototype:SetPos(p)local x,y,z=p:xyz();assert(self.nonphysical and x==reference_origin[1] and y==reference_origin[2] and z==reference_origin[3]);self.origin={x,y,z}end
function prototype:SetAngle(a)assert(a==0)end
function prototype:SetScale(s)assert(s==100)end
function prototype:SetStateText(s,flags)assert(flags==0);self.state=s;self.flags=s=='falling' and 32768 or 0 end
function prototype:GetAnimFlags()return self.flags==32768 and -32768 or self.flags end
function prototype:SetAnimPhase(c,p)assert(c==1);self.phase=p end
function prototype:SetAnimSpeed(c,s)assert(c==1 and s==0)end
function prototype:GetState()return self.state end
globals.PlaceObject=function(class,_,map)
 assert(class=='Shapeshifter' and map==active_map);created=created+1
 local o=setmetatable({class=class},{__index=prototype})
 reference_objects[#reference_objects+1]=o;return o
end
dofile('Code/sbm_decoration_geometry.lua');local G=SuperBigMap.DecorationGeometry
G.Decode=function()return {rigid_skin=true,vertices={{0,0,0},{2,3,4}},components={{bone=3,vertices={1,2}}}}end
local native_bone=G.BoneMatrix
G.BoneMatrix=function(o,geometry,bone)
 if o.class~='Shapeshifter' then return native_bone(o,geometry,bone)end
 assert(o.priority and o.nonphysical and not o.dead);if missing_pose then return nil end
 local m=matrices[o.state][bone];local r={origin={},columns={{},{},{}}}
 for a=1,3 do
  r.origin[a]=100*m.origin[a]+o.origin[a]
  for b=1,3 do r.columns[b][a]=100*m.columns[b][a]end
 end
 if o.state=='idle' and o.phase==bad_phase then r.origin[1]=r.origin[1]+10 end
 return r
end
local geom=G.ReadMesh(bank.mesh).geometry
local o={class='CaveInRubble',state=0,phase=0,x=1000,y=2000,z=3000,scale=133,extra=false}
function o:GetEntity()return bank.entity end
function o:GetState()return self.state end
function o:GetStateText()return self.state==0 and 'idle' or 'falling' end
function o:GetParent()return nil end
function o:GetMirrored()return false end
function o:GetWarped()return false end
function o:GetSkewX()return 0 end
o.GetSkewY=o.GetSkewX
function o:GetAnim(c)return c==1 and self.state or self.extra and 0 or -1 end
function o:GetAnimFlags()return self.flags or 0 end
function o:GetAnimWeight()return 1000 end
function o:GetAnimCrossfade()return 0 end
function o:GetAnimPhase()return self.phase end
function o:GetVisualBoneTransform()return nil end
function o:GetWorldScale()return self.scale end
function o:GetRelativePoint(p)local x,y,z=p:xyz();return point(self.x+x*self.scale/100.0,self.y+y*self.scale/100.0,self.z+z*self.scale/100.0)end
function o:SetPos()error('read-only pose cache must not move objects')end
function o:SetRenderingMeshLods()error('read-only pose cache must not write rendering')end
assert(not G.BoneMatrix(o,geom,3),'unverified cache must not be used')
assert(G.PrepareKnownPoses());assert(created==34 and removed==34,'all phases and native terminal flags sampled and references cleaned')
local a=assert(G.BoneMatrix(o,geom,3));assert(G.PrepareKnownPoses() and created==34,'verified poses are shared')
o.x=o.x+123;o.scale=200
local b=assert(G.BoneMatrix(o,geom,3))
assert(math.abs((b.origin[1]-o.x)/(a.origin[1]-(o.x-123))-200/133)<1e-8,'each instance needs its own transform')
o.extra=true;assert(not G.BoneMatrix(o,geom,3),'extra animation channels cannot use cached poses');o.extra=false
o.state=1;o.phase=100;assert(not G.BoneMatrix(o,geom,3),'falling intermediate pose is not a settled pose')
o.phase=3332;assert(not G.BoneMatrix(o,geom,3),'unverified looping falling flag variant must be rejected')
o.flags=-32768;assert(G.BoneMatrix(o,geom,3),'native signed eDontLoop terminal state must be inspectable')
o.flags=32768;assert(G.BoneMatrix(o,geom,3),'native unsigned eDontLoop terminal state must be inspectable')
o.flags=32769;assert(not G.BoneMatrix(o,geom,3),'unknown animation flags must not use the cache')
o.flags=-32768;o.phase=200;assert(not G.BoneMatrix(o,geom,3),'non-looping moving pose is still not settled')
o.flags=0
o.state=0;o.phase=0
for _,mode in ipairs({'mismatch','missing','cleanup','map'})do
 G.ClearCache();bad_phase=mode=='mismatch' and 13 or nil;missing_pose=mode=='missing';fail_cleanup=mode=='cleanup';change_map=mode=='map'
 assert(not G.PrepareKnownPoses(),mode..' must fail closed')
 assert(created==removed,mode..' must clean every owned reference')
 assert(not G.BoneMatrix(o,G.ReadMesh(bank.mesh).geometry,3),'failed verification must not authorize fallback')
 globals.CurrentMap=active_map
end
bad_phase=nil;missing_pose=false;fail_cleanup=false;change_map=false
assert(G.PrepareKnownPoses(),'failed verification may be retried')
G.ClearCache();ignore_cleanup=true
local ignored_before=created
assert(not G.PrepareKnownPoses(),'ignored native deletion must not publish a verified pose cache')
assert(created==ignored_before+34 and created-removed==34,'ignored deletion fixture did not retain all owned references')
assert(not G.BoneMatrix(o,G.ReadMesh(bank.mesh).geometry,3),'surviving references must veto fallback certification')
assert(not G.PrepareKnownPoses() and created==ignored_before+34,'failed cleanup retry must not create another batch')
-- Clearing decoded caches must not discard ownership of outstanding references.
G.ClearCache();ignore_cleanup=false
assert(G.PrepareKnownPoses(),'cleanup should recover after native removal works again')
assert(created==removed,'retry leaked the earlier reference batch')
for _,reference in ipairs(reference_objects)do assert(reference.dead,'an owned reference remains alive')end
G.ClearCache();reference_origin={120000,230000,-20000}
assert(G.PrepareKnownPoses(point(table.unpack(reference_origin))),'translated invisible references must verify against their actual origin')
G.ClearCache();globals.CanYield=function()return false end
local before=created;assert(not G.PrepareKnownPoses() and created==before,'non-yielding transactions must not create references')
print('known poses: native per-phase verification, cleanup, per-instance guards and fail-closed retry passed')

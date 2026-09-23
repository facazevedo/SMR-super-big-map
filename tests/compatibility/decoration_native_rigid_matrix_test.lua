local function point(x,y,z)return {xyz=function()return x,y,z end}end
SuperBigMap={Engine={Global=function(k)if k=='guim' then return 100 elseif k=='point' then return point end end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
local mirror=false;local stale=0;local scale=150
local function row(x,y,z,w)return {x=function()return x end,y=function()return y end,z=function()return z end,w=function()return w end}end
local obj={GetParent=function()return false end,GetMirrored=function()return mirror end,
 GetWorldScale=function()return scale end,GetRelativePoint=function(_,p)
  local x,y,z=p:xyz();return point(1000+1.5*x,2000+(mirror and -1 or 1)*1.5*y,3000+1.5*z)
 end,
 GetTransformMatrix=function()return {values=function()
  return row(1.5,0,0,10+stale),row(0,1.5,0,20),row(0,0,1.5,30),row(0,0,0,1)
 end}end}
local m=G.NativeRigidMatrix(obj)
assert(m and m.origin[1]==1000 and m.columns[2][2]==150)
mirror=true;m=G.NativeRigidMatrix(obj)
assert(m and m.columns[2][2]==-150,'native local-Y mirror must be restored')
stale=.1;assert(not G.NativeRigidMatrix(obj),'stale visual position must be rejected')
stale=0;scale=133;assert(not G.NativeRigidMatrix(obj),'stale visual scale must be rejected')
scale=150;obj.GetParent=function()return {}end
assert(not G.NativeRigidMatrix(obj),'unsupported attachment transform must be rejected')
print('native rigid matrix: exact floating columns, mirror restoration and independent stale-pose vetoes')

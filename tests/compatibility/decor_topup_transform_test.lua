-- The prefab's 3D relationships must not be flattened during density top-up.
local terrain_calls=0
local function point(x,y,z)
 return {x=function()return x end,y=function()return y end,z=function()return z end,
  xy=function()return x,y end,xyz=function()return x,y,z end}
end
local globals={point=point,terrain={GetHeight=function(_,p)terrain_calls=terrain_calls+1;return math.floor(100+p:x()/10+.5) end}}
SuperBigMap={Engine={Global=function(k)return globals[k]end,SafeCall=function(f,...)return f(...)end,
 IsKindOf=function()return false end,ObjectPos=function(o)return o:GetPos()end},ObjectClone={}}
dofile('Code/sbm_decor_topup.lua')
local function object(x,y,z)
 return {GetPos=function()return point(x,y,z)end,IsValidZ=function()return z~=nil end}
end
local transform=SuperBigMap.DecorTopUp.StretchedPosition
assert(type(transform)=='function','production top-up must preserve full prefab similarity')
local center=point(100,100,50)
local a=transform({},object(120,140,80),center,4/3)
local b=transform({},object(150,140,110),center,4/3)
assert(a:x()==127 and a:y()==153 and a:z()==90,'authored native Z must scale around group centre')
assert(b:x()-a:x()==40 and b:z()-a:z()==40,'native relative XYZ contact must survive')
assert(terrain_calls==0,'authored Z must not be independently reset to terrain')
local buried=transform({},object(100,100,40),center,4/3)
assert(buried:z()==37,'negative authored offset must survive')
local grounded=transform({},object(120,140,nil),center,4/3)
assert(grounded:z()==113 and terrain_calls==1,'native terrain-relative scatter must follow terrain at its destination, not be lifted with the group')
local unchanged=transform({},object(120,140,80),center,1)
assert(unchanged:x()==120 and unchanged:y()==140 and unchanged:z()==80,'unit scale identity')
print('decor top-up 3D similarity fixture passed')

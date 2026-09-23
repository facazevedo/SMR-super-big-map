SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua')
local function reference(a,b,tolerance)
 local function sub(p,q)return {p[1]-q[1],p[2]-q[2],p[3]-q[3]}end
 local function cross(p,q)return {p[2]*q[3]-p[3]*q[2],p[3]*q[1]-p[1]*q[3],p[1]*q[2]-p[2]*q[1]}end
 local function separated(axis)
  local length=math.sqrt(axis[1]^2+axis[2]^2+axis[3]^2)
  if length<1e-12 then return false end
  local al,ah,bl,bh=math.huge,-math.huge,math.huge,-math.huge
  for i=1,3 do
   local x=a[i][1]*axis[1]+a[i][2]*axis[2]+a[i][3]*axis[3]
   local y=b[i][1]*axis[1]+b[i][2]*axis[2]+b[i][3]*axis[3]
   al=math.min(al,x);ah=math.max(ah,x);bl=math.min(bl,y);bh=math.max(bh,y)
  end
  return al>bh+tolerance*length or bl>ah+tolerance*length
 end
 local ae={sub(a[2],a[1]),sub(a[3],a[2]),sub(a[1],a[3])}
 local be={sub(b[2],b[1]),sub(b[3],b[2]),sub(b[1],b[3])}
 local an,bn=cross(ae[1],ae[2]),cross(be[1],be[2])
 if separated(an)or separated(bn)then return true end
 for i=1,3 do
  if separated(cross(an,ae[i]))or separated(cross(bn,be[i]))then return true end
  for j=1,3 do if separated(cross(ae[i],be[j]))then return true end end
 end
 return false
end
local optimized=SuperBigMap.DecorationGeometry.TrianglesSeparated
math.randomseed(71523)
for case=1,3000 do
 local a,b={},{};local scale=10^(case%7-3)
 for i=1,3 do a[i]={};b[i]={};for j=1,3 do
  a[i][j]=(math.random()-.5)*scale;b[i][j]=(math.random()-.5)*scale
 end end
 if case%3==0 then for i=1,3 do a[i][3]=0;b[i][3]=0 end end
 if case%7==0 then b[1]=a[1]end
 if case%11==0 then a[3]=a[2]end
 for _,t in ipairs({0,.00001,.01,2})do
  local separated,strict=optimized(a,b,t)
  assert(separated==reference(a,b,t),'SAT semantics changed in case '..case)
  assert(strict==reference(a,b,0),'fused zero-tolerance decision changed in case '..case)
 end
end
print('triangle SAT: 12000 equivalent decisions across scale, coplanar, touching and degenerate cases')
-- Coincident finite projections need no normalization. Tiny but separated
-- axes still use the original sqrt-based degeneracy decision, not a squared
-- threshold whose rounding can differ at the boundary.
for _,scale in ipairs({1e-8,1e-6,1e-4,1,1e5}) do
 local a={{0,0,0},{scale,0,0},{0,scale,0}}
 for _,offset in ipairs({0,scale*1e-8,scale,scale*2}) do
  local b={{offset,0,0},{offset+scale,0,0},{offset,scale,0}}
  for _,t in ipairs({0,1e-12,.01,2}) do
   local separated,strict=optimized(a,b,t)
   assert(separated==reference(a,b,t) and strict==reference(a,b,0))
  end
 end
end
print('triangle SAT: overlapping/tiny-axis normalization shortcut parity')

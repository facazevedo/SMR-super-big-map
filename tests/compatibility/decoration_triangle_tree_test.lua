SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
local f=assert(io.open('Code/sbm_decoration_geometry.lua','r'));local source=f:read('*a');f:close()
local old=assert(source:match('(function Geometry.TriangleTree.-\nend)\n'))
old=old:gsub('function Geometry.TriangleTree','return function',1)
local replacements
old,replacements=old:gsub('local a=entries%[i%]%.bounds\n.-\n\t\tend',
 'local a=entries[i].bounds\n\t\t\tfor axis=1,3 do b[axis]=math.min(b[axis],a[axis]);b[axis+3]=math.max(b[axis+3],a[axis+3]) end\n\t\tend',1)
assert(replacements==1)
local reference=assert(load(old,'original library-min/max tree','t',setmetatable({Bounds=G.Bounds},{__index=_G})))()
local function same_tree(a,b)
 for axis=1,6 do assert(a.bounds[axis]==b.bounds[axis],'changed a reference extremum') end
 assert((a.items~=nil)==(b.items~=nil),'changed reference tree topology')
 if a.items then
  assert(#a.items==#b.items)
  for i=1,#a.items do assert(a.items[i].triangle==b.items[i].triangle,'changed median/leaf ordering') end
 else same_tree(a.left,b.left);same_tree(a.right,b.right) end
end
math.randomseed(367)
local checks=0
for _,count in ipairs({1,12,13,25,127,512,4096}) do
 for mode=1,4 do
  local g={vertices={}};local c={triangles={}}
  for i=1,count do
   local x=mode==1 and i or mode==2 and count-i or mode==3 and 0 or math.random(-1000,1000)
   local y=mode==3 and 0 or math.random(-1000,1000)
   local z=mode==3 and 0 or math.random(-50,50)
   local t={};for k=1,3 do
    g.vertices[#g.vertices+1]={x+(k==2 and 2 or 0),y+(k==3 and 2 or 0),z}
    t[k]=#g.vertices
   end
   c.triangles[i]=t
  end
  local tree=G.TriangleTree(g,c);local seen={}
  same_tree(tree,reference(g,{triangles=c.triangles}))
  local function inspect(node)
   local bound=G.Bounds();local n=0
   if node.items then
    assert(#node.items<=4)
    for _,item in ipairs(node.items) do
     assert(not seen[item.triangle],'duplicated triangle');seen[item.triangle]=true;n=n+1
     for _,vi in ipairs(item.triangle) do G.Extend(bound,g.vertices[vi]) end
    end
   else
    local a,na=inspect(node.left);local b,nb=inspect(node.right);n=na+nb
    assert(math.abs(na-nb)<=1,'unbalanced median partition')
    for axis=1,3 do bound[axis]=math.min(a[axis],b[axis]);bound[axis+3]=math.max(a[axis+3],b[axis+3]) end
   end
   for axis=1,6 do assert(node.bounds[axis]==bound[axis],'tree omitted a geometric bound');checks=checks+1 end
   return bound,n
  end
  local _,n=inspect(tree);assert(n==count)
  for _,t in ipairs(c.triangles) do assert(seen[t],'triangle lost from tree') end
  assert(G.TriangleTree(g,c)==tree,'immutable mesh tree was rebuilt')
 end
end
print('triangle tree: '..checks..' exact bounds checks; ordered, reversed, coincident and random meshes retain every triangle once')

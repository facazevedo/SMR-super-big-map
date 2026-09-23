SuperBigMap={Engine={Global=function(k)if k=='guim' then return 1 end end}}
dofile('Code/sbm_decoration_geometry.lua')
local f=assert(io.open('Code/sbm_decoration_validation.lua','rb'));local source=f:read('*a');f:close()
local function up(fn,name)
 for i=1,100 do local k,v=debug.getupvalue(fn,i);if k==name then return v elseif not k then break end end
end
local function load_raw(text)
 assert(load(text,'component contact fixture','t',_G))()
 local contact=up(up(SuperBigMap.DecorationValidation.Validate,'Scan'),'ComponentContact')
 return up(contact,'RawComponentContact'),contact
end
local optimized,cached=load_raw(source)
local before,after=assert(source:find('\tlocal function visit(at,bt)',1,true))
local finish=assert(source:find('\n\tif visit(Geometry.TriangleTree',after,true))
local reference_body=[[
 local function bounds(record,tree,cache)
  local value=cache[tree]
  if not value then value=WorldBounds(record,tree.bounds);cache[tree]=value end
  return value
 end
 local function visit(at,bt)
  if not Overlap(bounds(ar,at,ac),bounds(br,bt,bc),tolerance) then return false end
  if at.items and bt.items then
   for _,ai in ipairs(at.items) do for _,bi in ipairs(bt.items) do
    if Overlap(bounds(ar,ai,ac),bounds(br,bi,bc),tolerance) then
     local x,y={},{}
     for i=1,3 do x[i]=vertex(a,ar,av,ai.triangle[i]);y[i]=vertex(b,br,bv,bi.triangle[i]) end
     if Validator.TrianglesContact(x,y,tolerance) then return true end
    end
   end end
   return false
  end
  if at.items then return visit(at,bt.left) or visit(at,bt.right) end
  if bt.items then return visit(at.left,bt) or visit(at.right,bt) end
  return visit(at.left,bt.left) or visit(at.left,bt.right) or visit(at.right,bt.left) or visit(at.right,bt.right)
 end]]
local reference_source=source:sub(1,before-1)..reference_body..source:sub(finish)
local projection_start=assert(reference_source:find('\n\tlocal projected_a,projected_b',1,true))
local projection_end=assert(reference_source:find('\n\tlocal function vertex_cache',projection_start,true))
reference_source=reference_source:sub(1,projection_start-1)..reference_source:sub(projection_end)
local shortcut_start=assert(reference_source:find('\t\t-- If the COMPLETE transformed component box',1,true))
local shortcut_end=assert(reference_source:find('\t\tfor _,vi in ipairs(Geometry.SupportVertices(node.geometry,node.component)) do',shortcut_start,true))
reference_source=reference_source:sub(1,shortcut_start-1)..reference_source:sub(shortcut_end)
local replacements
reference_source,replacements=reference_source:gsub('\tif OrientedContactSeparated%(ar,a.component.bounds,br,b.component.bounds,tolerance%) then return false,true,true end\n','')
assert(replacements==1,'reference must omit oriented-box shortcut')
reference_source,replacements=reference_source:gsub('local hint_key,hint_bucket\n\tif ar~=br then','local hint_key,hint_bucket\n\tif false then')
assert(replacements==1,'reference must disable positive hints')
local reference=load_raw(reference_source)
local G=SuperBigMap.DecorationGeometry
local gf=assert(io.open('Code/sbm_decoration_geometry.lua','rb'));local gs=gf:read('*a');gf:close()
local ts=assert(gs:find('function Geometry.TriangleTree(',1,true))
local te=assert(gs:find('\n-- Separating-axis proof',ts,true))
local old_tree_source=gs:sub(ts,te-1):gsub('function Geometry.TriangleTree','return function',1)
old_tree_source=old_tree_source:gsub('last%-first<4','last-first<12',1)
local old_tree=assert(load(old_tree_source,'old 12-triangle leaf reference','t',
 setmetatable({Bounds=G.Bounds},{__index=_G})))()
local new_tree=G.TriangleTree
math.randomseed(387)
for trial=1,400 do
 local geometry={vertices={}};local component={vertices={},triangles={},bounds=G.Bounds()}
 local size=2+trial%9
 for y=0,size do for x=0,size do
  local p={x,y,math.random()*.3};geometry.vertices[#geometry.vertices+1]=p
  component.vertices[#component.vertices+1]=#geometry.vertices;G.Extend(component.bounds,p)
 end end
 for y=0,size-1 do for x=0,size-1 do
  local i=y*(size+1)+x+1
  component.triangles[#component.triangles+1]={i,i+1,i+size+1}
  component.triangles[#component.triangles+1]={i+1,i+size+2,i+size+1}
 end end
 local function node(angle,tilt,x,y,z)
  local c,s=math.cos(angle),math.sin(angle);local ct,st=math.cos(tilt),math.sin(tilt)
  return {geometry=geometry,component=component,record={pose={scale=100,shift={0,0,0},
   matrix={origin={x,y,z},columns={{c,s,0},{-s*ct,c*ct,st},{s*st,-c*st,ct}}}}}}
 end
 local offset=trial%3==0 and 800000 or 0
 local a=node(math.random()*6,math.random(),offset,offset,offset)
 local b=node(math.random()*6,math.random(),offset+(math.random()-.5)*size,offset,offset+(math.random()-.5)*2)
 if trial%4==0 then
  for axis=1,3 do
   local factor=(axis==1 and -1 or 1)*(.25+math.random()*3)
   for j=1,3 do b.record.pose.matrix.columns[axis][j]=b.record.pose.matrix.columns[axis][j]*factor end
  end
 end
 for _,tolerance in ipairs({0,1e-7,.01,2}) do
  local hit,separated,surfaces=optimized(a,b,tolerance)
  component.triangle_tree=nil;G.TriangleTree=old_tree
  local old,old_separated,old_surfaces=reference(a,b,tolerance)
  component.triangle_tree=nil;G.TriangleTree=new_tree
  assert(hit==old and separated==old_separated,'leaf pruning changed full contact evidence '..trial)
  assert(surfaces==old_surfaces,'tree traversal changed open-surface separation evidence '..trial)
 end
 if trial%5==0 then
  -- Only the neighbour changes: the stationary record's projection cache must
  -- use the NEW reference frame, including shifts, origins and basis changes.
  for mutation=1,4 do
   local hit,separated,surfaces=cached(a,b,.01)
   local function fresh(n)
    local p=n.record.pose;local c=p.matrix.columns
    return {geometry=n.geometry,component=n.component,record={pose={scale=100,
     shift={table.unpack(p.shift)},matrix={origin={table.unpack(p.matrix.origin)},
      columns={{table.unpack(c[1])},{table.unpack(c[2])},{table.unpack(c[3])}}}}}}
   end
   local old,old_separated,old_surfaces=reference(fresh(a),fresh(b),.01)
   assert(hit==old and separated==old_separated and (separated or surfaces==old_surfaces),
    'neighbour-frame mutation retained stale projected bounds '..trial..':'..mutation..' '..
    table.concat({tostring(hit),tostring(separated),tostring(surfaces),tostring(old),tostring(old_separated),tostring(old_surfaces)},','))
   if mutation==1 then b.record.pose.shift[1]=size*.3
   elseif mutation==2 then b.record.pose.matrix.origin[3]=offset+.4
   elseif mutation==3 then
    local columns=b.record.pose.matrix.columns
    for i=1,3 do local x,y=columns[i][1],columns[i][2];columns[i][1],columns[i][2]=-y,x end
   end
  end
 end
end
print('leaf pruning: 1600 exact parity cases plus 320 reference-frame mutation checks; rotated/reflected/nonuniform multi-leaf meshes and large offsets')

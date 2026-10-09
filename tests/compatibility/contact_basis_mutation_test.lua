-- An in-place basis rotation must invalidate matrix-derived broad-phase bounds.
SuperBigMap={Engine={Global=function(k) if k=='guim' then return 1 end end}}
dofile('Code/sbm_decoration_geometry.lua')
dofile('Code/sbm_decoration_validation.lua')
local function up(fn,name)
 for i=1,100 do local k,v=debug.getupvalue(fn,i);if k==name then return v elseif not k then break end end
end
local contact=up(up(SuperBigMap.DecorationValidation.Validate,'Scan'),'ComponentContact')
local function node(vertices,bounds)
 return {geometry={vertices=vertices},component={vertices={1,2,3},triangles={{1,2,3}},bounds=bounds},
  record={pose={scale=100,shift={0,0,0},matrix={origin={0,0,0},columns={{1,0,0},{0,1,0},{0,0,1}}}}}}
end
local a=node({{-9,.01,0},{-8.5,.01,0},{-9,.05,0}},{-9,.01,0,-8.5,.05,0})
local b=node({{0,0,0},{1,0,0},{0,10,0}},{0,0,0,1,10,0})
assert(not contact(a,b,.001),'unrotated triangles should be separated')
local columns=b.record.pose.matrix.columns
for i=1,3 do local x,y=columns[i][1],columns[i][2];columns[i][1],columns[i][2]=-y,x end
assert(contact(a,b,.001),'rotated triangle contact lost to stale absolute basis')
for i=1,3 do local x,y=columns[i][1],columns[i][2];columns[i][1],columns[i][2]=y,-x end
assert(not contact(a,b,.001),'restored basis retained stale positive contact')
print('contact basis mutation: exact rotated contact and restored separation')

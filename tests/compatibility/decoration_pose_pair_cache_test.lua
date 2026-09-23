SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua');dofile('Code/sbm_decoration_validation.lua')
local function up(fn,name)
 for i=1,100 do local k,v=debug.getupvalue(fn,i);if k==name then return v,i elseif not k then break end end
 error('missing '..name)
end
local contact=up(up(SuperBigMap.DecorationValidation.Validate,'Scan'),'ComponentContact')
local original,index=up(contact,'RawComponentContact');local calls=0
debug.setupvalue(contact,index,function()calls=calls+1;return false,true,true end)
local function node()
 return {geometry={},component={},record={pose={shift={0,0,0},matrix={origin={0,0,0},columns={{1,0,0},{0,1,0},{0,0,1}}}}}}
end
local a,b=node(),node()
local function check(expected)
 local x,y,z=contact(a,b,2);assert(x==false and y==true and z==true)
 assert(calls==expected,'unexpected complete pair traversal count: '..calls..' vs '..expected)
end
check(1);check(1)
assert(select(2,contact(b,a,2)) and calls==1,'symmetric exact frame pair repeated work')
contact(a,b,1);assert(calls==2,'changed tolerance reused a different query')
a.record.pose.shift[1]=1;check(3)
b.record.pose.matrix.origin[2]=1;check(4)
a.record.pose.matrix.columns[1][3]=.01;check(5)
a.geometry={};check(6);a.component={};check(7)
b.record.pose={shift={0,0,0},matrix=b.record.pose.matrix};check(8)
-- A changed frame cannot retain the old pose's transformed triangle/box data.
a.record.pose.contact_bounds={};a.record.pose.contact_vertices={};a.record.pose.contact_triangles={};a.record.pose.oriented_contact_bounds={}
a.record.pose.shift[3]=1;check(9)
assert(not a.record.pose.contact_bounds and not a.record.pose.contact_vertices and not a.record.pose.contact_triangles and not a.record.pose.oriented_contact_bounds)
debug.setupvalue(contact,index,original)
print('pose pair cache: exact symmetric reuse, tolerance/origin/basis/shift/asset/component/fresh-capture invalidation and transformed-cache cleanup passed')

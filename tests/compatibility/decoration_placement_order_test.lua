SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua');dofile('Code/sbm_decoration_validation.lua')
local V=SuperBigMap.DecorationValidation
local function up(fn,name,replacement)
 for i=1,100 do local key,value=debug.getupvalue(fn,i)
  if key==name then if replacement then debug.setupvalue(fn,i,replacement) end;return value
  elseif not key then break end
 end
 error('missing upvalue '..name)
end
local matrix={origin={0,0,0},columns={{1,0,0},{0,1,0},{0,0,1}}}
local object={GetEntity=function()return 'RocksFixture'end}
local record={obj=object,pose={matrix=matrix,shift={0,0,0},scale=100},nodes={}}
local geometry={}
for i=1,3 do record.nodes[i]={record=record,geometry=geometry,component={id=i}} end
local other={obj={GetEntity=function()return 'CliffFixture'end},complete=true}
local neighbour={record=other}
local map={}
up(V.SeatingPlacementClear,'contexts')[map]={by_object={[object]=record},index={Query=function()return {neighbour}end}}
local calls={};local blocked=3
up(V.SeatingPlacementClear,'ComponentContact',function(own,node)
 assert(node==neighbour)
 calls[#calls+1]=own.component.id
 return own.component.id==blocked,own.component.id~=blocked
end)
local rotation={bounds={0,0,0,10,10,10},record=record}
local search={}
assert(not V.SeatingPlacementClear(map,object,{1,0,0,11,10,10},rotation,search))
assert(table.concat(calls,',')=='1,2,3')
calls={}
assert(not V.SeatingPlacementClear(map,object,{2,0,0,12,10,10},rotation,search))
assert(table.concat(calls,',')=='3','new proposal repeated known unhelpful member ordering')
blocked=1;calls={}
assert(not V.SeatingPlacementClear(map,object,{3,0,0,13,10,10},rotation,search))
assert(table.concat(calls,',')=='3,2,1','ordering hint became a cached collision verdict')
blocked=0;calls={}
assert(V.SeatingPlacementClear(map,object,{4,0,0,14,10,10},rotation,search))
assert(#calls==3,'accepted proposal skipped a component')
-- A new asset/component cannot accidentally inherit the old member identity.
record.nodes[1].component={id=1};record.nodes[1].geometry={};calls={}
assert(V.SeatingPlacementClear(map,object,{5,0,0,15,10,10},rotation,search))
assert(#calls==3)
print('placement ordering: fresh-pose checks, all-member acceptance and identity guards passed')

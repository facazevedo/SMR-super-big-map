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

-- Complete, eligible cosmetic rocks may interpenetrate without changing pose
-- orientation. Unknown gameplay neighbours still take the full guarded path.
SuperBigMap.RockGrounding={Eligible=function(o)return o==object or o==other.obj end}
other.obj.GetObjectBBox=function()return {
 minx=function()return 0 end,miny=function()return 0 end,minz=function()return 0 end,
 maxx=function()return 10 end,maxy=function()return 10 end,maxz=function()return 10 end}end
blocked=1;calls={}
assert(V.SeatingPlacementClear(map,object,{5,0,-5,15,10,5},rotation,search),
 'cosmetic rock overlap was rejected')
assert(#calls==0,'allowed cosmetic overlap performed redundant collision rejection')
neighbour.unknown=true
assert(V.SeatingPlacementClear(map,object,{5,0,-5,15,10,5},rotation,search),
 'permitted partial decorative overlap demanded unused neighbour geometry')
neighbour.unknown=nil;neighbour.partial=true
assert(V.SeatingPlacementClear(map,object,{5,0,-5,15,10,5},rotation,search),
 'partial decorative geometry was used to forbid an allowed overlap')
neighbour.partial=nil
SuperBigMap.RockGrounding.Eligible=function(o)return o==object end
assert(not V.SeatingPlacementClear(map,object,{5,0,-5,15,10,5},rotation,search),
 'a gameplay neighbour was granted cosmetic overlap permission')
SuperBigMap.RockGrounding.Eligible=function(o)return o==other.obj end
assert(not V.SeatingPlacementClear(map,object,{5,0,-5,15,10,5},rotation,search),
 'a noncosmetic mover was granted overlap permission')
neighbour.unknown=true
assert(not V.SeatingPlacementClear(map,object,{5,0,-5,15,10,5},rotation,search),
 'unknown noncosmetic geometry was granted an overlap exemption')
local instance=SuperBigMap.DecorationGeometry.Instance
SuperBigMap.DecorationGeometry.Instance=function()return {complete=true,render_kind='native non-rendering logical marker'}end
assert(V.SeatingPlacementClear(map,object,{5,0,-5,15,10,5},rotation,search),
 'verified non-rendering marker bounds blocked a cosmetic seating')
other.nonphysical=nil
SuperBigMap.DecorationGeometry.Instance=function()return {complete=false,render_kind='native non-rendering logical marker'}end
assert(not V.SeatingPlacementClear(map,object,{5,0,-5,15,10,5},rotation,search),
 'incomplete geometry was treated as a verified non-rendering marker')
SuperBigMap.DecorationGeometry.Instance=instance
print('cosmetic overlap: both objects must qualify; gameplay and possible containment remain guarded')

-- An open-base correction may not sever an existing dependent's root. The
-- original bounds are inspected even if that dependent leaves the target box.
up(V.SeatingPlacementClear,'Global',function(key)if key=='const' then return {HeightTileSize=1}end end)
record.foundation={};neighbour.unknown=nil;other.nonphysical=nil
SuperBigMap.RockGrounding.Eligible=function()return true end
neighbour.edges={record.nodes[1]}
local retained=false
up(V.SeatingPlacementClear,'ComponentContact',function(a,b)
 assert(a==neighbour and b.original==record.nodes[1],'dependent checked against the wrong support component')
 return retained,false
end)
local ok,_,reason=V.SeatingPlacementClear(map,object,{5,0,-5,15,10,5},rotation,{})
assert(not ok and reason=='dependent support would be lost','seating severed an existing support root')
retained=true
assert(V.SeatingPlacementClear(map,object,{5,0,-5,15,10,5},rotation,{}),
 'a positively retained dependent contact vetoed a safe foundation correction')
print('foundation dependencies: preserved exact proposed contact required before movement')

local function bb(a,b,c,d,e,f)return {
 minx=function()return a end,miny=function()return b end,minz=function()return c end,
 maxx=function()return d end,maxy=function()return e end,maxz=function()return f end}end
record.foundation=nil;neighbour.edges={};neighbour.unknown=true
object.GetObjectBBox=function()return bb(0,0,0,100,100,100)end
other.obj.GetObjectBBox=function()return bb(10,10,20,20,20,30)end
SuperBigMap.DecorationGeometry.Instance=function()return {complete=false}end
assert(V.SeatingPlacementClear(map,object,{0,0,-10,100,100,90},nil,{}),
 'straight downward translation redundantly forbade an unchanged enclosed neighbour')
other.nodes={neighbour}
up(V.SeatingPlacementClear,'CosmeticExteriorWitness',function()return false end)
assert(not V.SeatingPlacementClear(map,object,{0,0,10,100,100,110},nil,{}),
 'the downward monotonic-visibility proof incorrectly authorized an upward move')
print('downward overlap: unchanged neighbour exposure preserved; no upward exemption')

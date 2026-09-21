SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_seating.lua')
local plan=SuperBigMap.DecorationSeating.PlanSupportIsland
local function flat()return 0 end
local function part(bottom,top,root,visible)
 return {vertices={{0,0,bottom},{0,0,top}},terrain=root,visible=visible or 5}
end
assert(plan({part(10,30,true),part(30,45,false)},flat)==-10,'whole stack seats once without sinking the upper object independently')
assert(plan({part(-10,20,true),part(20,35,false)},flat)==0,'already supported group stays put')
assert(plan({part(-30,-5,true,10)},flat)==15,'a buried group can rise while retaining root contact')
assert(plan({part(0,20,false)},flat)==nil,'unsupported cycles cannot invent a terrain root')
assert(plan({part(10,20,true,15)},flat)==nil,'impossible contact/exposure rejects the island')
assert(plan({part(10,20,true)},function()return nil end)==nil,'missing terrain is not a pass')
assert(plan({{vertices={},terrain=true,visible=5}},flat)==nil,'missing geometry is not a pass')
assert(plan({part(5,30,true),part(10,40,true),part(35,50,false)},flat)==-10,'all terrain roots retain contact with a single rigid shift')
print('decor support islands: rooted stacks, common shifts, visibility and missing-evidence rejection passed')
local bounded=part(10,30,true);bounded.flat_height=0
assert(plan({bounded},function()error('certified constant terrain should not be sampled again')end)==-10,
 'exact constant-terrain bound must preserve the same plan')

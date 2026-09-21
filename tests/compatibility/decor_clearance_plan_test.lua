SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_seating.lua')
local plan=SuperBigMap.DecorationSeating.PlanSupportIsland
math.randomseed(327)
local function height(x,y)return math.floor(x/3)+math.floor(y/7)end
for trial=1,2000 do
 local full,compact={},{}
 for c=1,math.random(1,8)do
  local p={vertices={},visible=math.random(2,30),terrain=math.random(0,1)==1}
  local bottom,top=math.huge,-math.huge
  for i=1,math.random(2,50)do
   local x,y,z=math.random(-40,40),math.random(-40,40),math.random(-30,100)
   p.vertices[i]={x,y,z};local d=z-height(x,y);bottom=math.min(bottom,d);top=math.max(top,d)
  end
  full[c]=p;compact[c]={clearance={bottom,top},visible=p.visible,terrain=p.terrain}
 end
 local a,why=plan(full,height)
 local b,reason=plan(compact,function()error('measured clearances must not allocate/resample vertices')end)
 assert(a==b and why==reason,'compact sufficient statistics changed the support/visibility result')
end
for _,bad in ipairs({{}, {0}, {4,2}, {0,math.huge}, {0,0/0}})do
 assert(plan({{clearance=bad,terrain=true,visible=2}},height)==nil,'missing/nonfinite clearances must fail closed')
end
print('decor clearance planner: 2000 identical full-vertex/compact plans, missing and invalid bounds rejected')

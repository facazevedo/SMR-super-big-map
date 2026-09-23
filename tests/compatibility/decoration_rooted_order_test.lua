SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua');dofile('Code/sbm_decoration_validation.lua')
local function up(fn,name)
 for i=1,100 do local k,v=debug.getupvalue(fn,i);if k==name then return v elseif not k then break end end
end
local scan=up(SuperBigMap.DecorationValidation.Validate,'Scan')
local order=assert(up(scan,'RootedCandidatesFirst'))
math.randomseed(386)
for trial=1,5000 do
 local nodes={};local roots,others={},{}
 for i=1,trial%61 do
  local node={supported=math.random(1,3)==1,unknown=math.random(1,9)==1,id=i}
  nodes[i]=node
  local group=node.supported and roots or others;group[#group+1]=node
 end
 local actual=order(nodes)
 assert(#actual==#nodes,'candidate omitted')
 for i,node in ipairs(roots) do assert(actual[i]==node,'root order changed') end
 for i,node in ipairs(others) do assert(actual[#roots+i]==node,'unrooted/unknown order changed') end
 for i,node in ipairs(nodes) do assert(node.id==i,'input reordered') end
end
-- The ordering does not invent any root, mutate its status, or omit unknowns.
local cycle={{supported=false},{supported=false},{unknown=true}}
assert(order(cycle)==cycle)
print('root-first support search: 5000 stable full-set partitions; unknowns and unrooted cycles retained')

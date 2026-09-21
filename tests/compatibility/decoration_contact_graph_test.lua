SuperBigMap={Engine={Global=function()end},DecorationGeometry={}}
dofile('Code/sbm_decoration_validation.lua')
local V=SuperBigMap.DecorationValidation
local graph={root={root=true},a={edges={root=true}},b={edges={a=true}},
 cycle1={edges={cycle2=true}},cycle2={edges={cycle1=true}},missing={edges={absent=true}}}
local reached=V.PreservedContactGraph(graph)
assert(reached.root and reached.a and reached.b,'proven alternative native contacts retain a rooted relationship')
assert(not reached.cycle1 and not reached.cycle2,'unsupported cycles are not support')
assert(not reached.missing,'a missing native counterpart is not a root')
graph.root.root=false
assert(not next(V.PreservedContactGraph(graph)),'losing the last root invalidates every dependent')
print('contact graph: positive native/current edge intersection, rooted closure, cycles and missing nodes')

local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a'):gsub('\r\n','\n');f:close();return s end
local current=read(arg[1] or 'Code/sbm_terrain_copy.lua')
local tested=read('_ralph/runs/under80-20260912/artifacts/crease_offer_research_2/sbm_terrain_copy.lua')
assert(current==tested,'production differs from native-shadowed candidate')
local pipe=assert(io.popen('git show 56fbf44:Code/sbm_terrain_copy.lua','r'))
local previous=pipe:read('*a'):gsub('\r\n','\n');assert(pipe:close())
for _,anchors in ipairs({
 {'\tlocal function NewHeightStepRefinementGuide(','\t-- INDEXED_HEIGHT_REFINE_END'},
 {'\tlocal function scan_line_range(','\tlocal function collect_axis('},
 {'\tlocal function refine_step(','local function RepairQualifiedSourceHeightSteps('},
})do
 local a=assert(previous:find(anchors[1],1,true))
 local b=assert(previous:find(anchors[2],a,true))
 assert(current:find(previous:sub(a,b-1),1,true),'changed retained scalar/refinement/write block '..anchors[1])
end
assert(current:find('if not offers or perp > perp_n - max_width - 2 then',1,true),'missing width-boundary fallback')
assert(current:find('local signed = a',1,true),'scratch reuse changed')
print('PASS exact native-shadowed source; v987 scalar/refinement/write blocks and boundary fallback retained')

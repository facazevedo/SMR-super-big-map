-- 2S67W (2026-10-01): a vanilla StonesDarkGroup_03 float lifted 26 units beyond its scaled vanilla
-- clearance was a confirmed defect, but another rock rested on it, and a dependent vetoed every
-- non-open-base move. A dependent that qualifies as a rigid-group member now makes the rock a group
-- root; it is then moved only together with that dependent, never alone.
local function read(path) local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local validation=read('Code/sbm_decoration_validation.lua')
local seating=read('Code/sbm_decoration_seating.lua')
local helper=assert(validation:match('local function RigidGroupDependent%(context,candidate%)(.-)\r?\nend\r?\n'),'helper not found')
for _,rule in ipairs({'not candidate.complete','candidate.pose.parent','eligible(candidate.obj)',
  'ForEachAttach','node.partial or node.geometry.animated or (not node.supported and not node.native_authored)'}) do
  assert(helper:find(rule,1,true),'rigid dependent rule missing: '..rule)
end
assert(validation:find('if RigidGroupDependent(context,other.record) then group_root=true else safe=false end',1,true),
  'a qualifying dependent makes a group root; any other dependent still vetoes')
assert(validation:find('if not root or not (root.foundation or entry.group_root) then return nil end',1,true),
  'the group builder accepts group roots')
assert(seating:find('if grouped then entry=grouped elseif entry.group_root then entry=nil end',1,true),
  'a group root that cannot form its group is never moved alone')
assert(seating:find('reason="a dependent rock could not join the rigid seating group"',1,true))
print('rigid group roots: lifted floats move only together with their dependents')

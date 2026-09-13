local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local source=read('_ralph/tmp/under80_20260912/playable_distance_production_observer_test.lua')
local function replace(old,new)
 local a,b=assert(source:find(old,1,true));assert(not source:find(old,b+1,true),'duplicate replay model anchor')
 source=source:sub(1,a-1)..new..source:sub(b+1)
end
replace("replace('saved,function()return tick end','saved,function()return tick end,borrowed')",
 "replace('saved,function()return tick end','saved,function()return tick end,borrowed')\n"..
 "replace(\"check(borrowed[g] and live[g],'game free ownership')\",\"check(live[g],'native free lifetime')\")")
replace('local sbm={Config={}', 'local sbm={InstallNativePlayableDistanceCache=install,Config={}')
replace('playable_distance_production_profile.lua','playable_distance_helper_replay_profile.lua')
replace("clean();print('PASS '",[[
for _,b in ipairs(r.primitive.scopes[1].benchmarks)do
 check(b.old_stats.transforms==9 and b.new_stats.transforms==6,'all replay transforms including calibration')
 check(b.new_stats.minimums==2 and b.new_stats.copies==5,'actual replacement work')
 for k,v in pairs(stats)do check(b.helper_stats[k]==v,'complete replay helper census '..k)end
 check(b.helper_stats.guards==2 and b.helper_stats.allocated==8 and b.helper_stats.freed==8,'full guard/cleanup cost')
end
clean();print('PASS ']])
assert(load(source,'actual helper complete-sequence fixture','t',_G))()

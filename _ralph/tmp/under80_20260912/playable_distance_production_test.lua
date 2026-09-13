local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local source=read('_ralph/tmp/under80_20260912/playable_distance_helper_test.lua')
local old="local install=assert(loadfile('_ralph/tmp/under80_20260912/playable_distance_helper.lua'))()"
local new=[=[local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local production=read('Code/sbm_map_generation.lua')
local block=assert(production:match('%-%- BEGIN NATIVE PLAYABLE DISTANCE CACHE%..-%-%- END NATIVE PLAYABLE DISTANCE CACHE%.'))
local env=setmetatable({SuperBigMap={}}, {__index=_G})
assert(load(block,'actual production distance helper','t',env))()
local install=env.SuperBigMap.InstallNativePlayableDistanceCache]=]
local a,b=assert(source:find(old,1,true));source=source:sub(1,a-1)..new..source:sub(b+1)
assert(load(source,'actual production distance fixture','t',_G))()

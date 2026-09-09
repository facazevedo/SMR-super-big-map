local f=assert(io.open(arg[1] or 'Code/sbm_terrain_copy.lua','r'))
local source=f:read('*a');f:close()
local a=assert(source:find('local function ResolveBoundedRocketSeed(',1,true),'production seed resolver missing')
local b=assert(source:find('-- BOUNDED_ROCKET_SEED_END',a,true))
local resolve=assert(load(source:sub(a,b-1)..'\nreturn ResolveBoundedRocketSeed'))()
local checks=0
local function check(ok,why) assert(ok,why);checks=checks+1 end
local function original(map)
    local generator=map.RandomMapGenObject
    local seed=math.abs(math.floor(generator.Seed))%2147483647
    local material=tostring(generator.GenerationHash or '')..'|'..tostring(map.mapdata.RandomMapPreset or '')..'|sbm-bounded-rocket-v1'
    for i=1,#material do seed=(seed*48271+material:byte(i)+1)%2147483647 end
    return seed==0 and 1 or seed
end
for _,numeric in ipairs({0,1,-1,12345678,-8909488827485014858,9223372036854775000}) do
    for _,hash in ipairs({'','generated','abcde123'}) do
        for _,preset in ipairs({'','terrain_one','terrain_two'}) do
            local map={RandomMapGenObject={Seed=numeric,GenerationHash=hash},mapdata={RandomMapPreset=preset}}
            local expected=original(map)
            check(resolve(map)==expected,'existing initial seed changed')
            map.RandomMapGenObject=nil
            map.SuperBigMapPlacementSeed=numeric
            check(resolve(map)==expected,'transient generator cleanup changed retry seed')
            local next_map={SuperBigMapPlacementSeed=numeric,mapdata={RandomMapPreset=preset}}
            check(type(resolve(next_map))=='number','persisted immutable source seed unavailable')
        end
    end
end
local seed,err=resolve({mapdata={}})
check(seed==nil and err~=nil,'missing source silently became fixed zero')
for _,value in ipairs({0,-1,2147483647,0.5,'bad'}) do
    seed,err=resolve({SuperBigMapBoundedRocketSeed=value})
    check(seed==nil and err~=nil,'invalid cached seed silently reused')
end
check(source:find('OptimizationFailure("seeded rocket planner", seed_error, map)',1,true)~=nil,'seed failure not recorded')
print('bounded rocket seed: '..checks..' checks passed')

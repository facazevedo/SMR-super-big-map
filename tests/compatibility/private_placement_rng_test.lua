local file=assert(io.open('Code/sbm_deposits.lua','r'));local source=file:read('*a');file:close()
local body=assert(source:match('(local function RandInt%b().-\nend)'))
local env={math=math,type=type,tonumber=tonumber,error=error}
local create=assert(load('return function(rng) local deterministic_placement_rng=rng\n'..body..'\nreturn RandInt end',
 'production private placement stream','t',env))()
local ok,why=pcall(create(nil),10)
assert(not ok and tostring(why):find('private placement RNG has no map seed',1,true),
 'missing map seed must not fall back to engine/session randomness')
assert(not source:find('EngineRandInt',1,true),'placement still imports an engine RNG fallback')
local a,b={state=1234567,calls=0},{state=1234567,calls=0}
local rand_a,rand_b=create(a),create(b)
for i=1,10000 do
 local limit=1+(i*37)%12345
 local value=rand_a(limit)
 assert(value==rand_b(limit) and value>=0 and value<limit,'private stream changed its deterministic range/sequence')
end
assert(a.calls==10000 and b.calls==10000)
assert(rand_a(0)==0 and a.calls==10000,'empty range must not consume a draw')
print('private placement RNG: 10000 reproducible draws; missing map seed fails without engine fallback')

local file=assert(io.open('Code/sbm_deposits.lua','r'));local source=file:read('*a');file:close()
local block=assert(source:match('(if not c and not underground and not surface_hex_selector then%s+%-%- A crowded.-)%s+if not c and not underground then'))
local env={candidate_samples=0,MAX_SAMPLES=4,candidates={},surface_on_demand_added=0}
setmetatable(env,{__index=_G})
env.grow_candidate_pool=function(target,limit)
  while #env.candidates<target and env.candidate_samples<limit do
    env.candidate_samples=env.candidate_samples+1
    env.candidates[#env.candidates+1]={sample=env.candidate_samples}
  end
end
env.new_whole_map_selector=function(_,candidates,loads)
  assert(#candidates==1,'exhausted pool was rebuilt for one new sample')
  assert(type(loads)=='table' and next(loads)==nil,'single candidate caused a marker census')
  return candidates
end
env.take_reachable_candidate=function(candidates)
  for _,candidate in ipairs(candidates)do
    if not candidate.used and candidate.sample%2==0 then candidate.used=true;return candidate end
  end
end
local take=assert(load(block,'production anomaly residual search','t',env))
for i=1,3 do
  env.c=nil;take()
  assert(env.c and env.c.sample==i*2,'progress consumed the budget needed by later anomalies')
end
-- An impossible placement stops after one full round; a larger quota must not
-- turn the residual search into an unbounded retry or relax the validator.
env.take_reachable_candidate=function()return nil end
local before=env.candidate_samples;env.c=nil;take()
assert(env.c==nil and env.candidate_samples-before==env.MAX_SAMPLES,'failed search was not bounded')
print('anomaly residual search: progress renews the next placement budget; impossible search stays bounded')

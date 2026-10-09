SuperBigMap = {}
dofile('Code/sbm_anomaly_quota.lua')
local q = SuperBigMap.AnomalyQuota
local fields = {'AnomEventCount','BonusCountEvent','AnomTechUnlockCount','AnomFreeTechCount','BonusCountFreeTech'}
local generator = {}
for _,field in ipairs(fields) do generator[field] = {} end
local draws = {7,20,17,7,10,999}
local n = 0
local helpers = {function() end, function() n=n+1; return draws[n] end}
local env = {map={}, rhelpers=helpers}
local finish = q.Begin(generator,env)
for _,field in ipairs(fields) do env.rhelpers[2](generator[field]) end
env.rhelpers[2]({}) -- later generator draws cannot inflate the captured quota
finish(true)
assert(env.rhelpers==helpers and n==6, 'random helper or random sequence changed')
local requested = env.map.SuperBigMapRequestedAnomalies
assert(requested.complete==17 and requested.sequence==27 and requested.unlock==17)
local targets = q.Targets(requested, {complete=15,sequence=27,unlock=17},
  {complete=15,sequence=27,unlock=17,breakthrough=15,other=2},
  {complete=15,sequence=27,unlock=17,breakthrough=15}, 16/9)
assert(targets.complete==30, 'native shortfall leaked into expanded quota')
assert(targets.sequence==48 and targets.unlock==30)
assert(targets.breakthrough==15 and targets.other==2, 'finite/unique content scaled')
targets=q.Targets({complete=3}, {}, {}, {}, 16/9)
assert(targets.complete==5, 'entirely missing native category was skipped')
targets=q.Targets({complete=3}, {complete=8}, {complete=10}, {complete=8}, 2)
assert(targets.complete==18, 'extra native or special content was lost')
targets=q.Targets(false,{complete=8},{complete=16},{complete=16},2)
assert(targets.complete==16, 'legacy fallback or repeat placement changed')
for _,mode in ipairs({'failed','wrong_order','incomplete'}) do
  n=0;local cleanup=q.Begin(generator,env)
  if mode=='wrong_order' then env.rhelpers[2]({})
  elseif mode=='incomplete' then env.rhelpers[2](generator.AnomEventCount)
  else for _,field in ipairs(fields) do env.rhelpers[2](generator[field]) end end
  cleanup(mode~='failed')
  assert(env.rhelpers==helpers and env.map.SuperBigMapRequestedAnomalies==false,
    'failed/incompatible generation published a guessed quota')
end
print('requested anomaly quotas: exact draws, no rerolls, missing families, extras, finite pools, legacy and error cleanup passed')

local file=assert(io.open('Code/sbm_deposits.lua','r'));local source=file:read('*a');file:close()
local block=assert(source:match('(local function create_anomaly.-\n\tend)\n'))
local map={};local donor={};local calls=0
local function point(x,y,z)return {x=x,y=y,z=z}end
local e=setmetatable({map=map,point=point,ObjectPos=function(o)
 assert(o==donor);return {xy=function()return 7,9 end}end,
 clone_fn=function(m,o,offset)assert(m==map and o==donor and offset.x==13 and offset.y==21);calls=calls+1;return {copied=true}end,
 Global=function(name)assert(name=='PlaceObject');return function(class,props,m,_,pos)
 assert(class=='SubsurfaceAnomalyMarker' and props.depth_layer==1 and m==map and pos.x==20 and pos.y==30)
 calls=calls+1;return {created=true}end end},{__index=_G})
local create=assert(load(block..'\nreturn create_anomaly','production anomaly creation','t',e))()
assert(create(donor,20,30).copied and create(nil,20,30).created and calls==2,
 'zero-source anomaly creation still needs a donor')
print('anomaly creation: donor reuse and entirely empty source supported')

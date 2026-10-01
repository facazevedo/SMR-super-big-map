-- More Deposits compatibility (owner report 2026-10-01): a mod that fixes a resource's generation
-- presets to one grade makes every deposit of that resource premium-grade, and the oasis rule's
-- "one premium per cluster" then left strong clusters one extractor short ("extractors=1/2").
-- Such resources are not premium on that map. Vanilla presets must never be read as single-grade.
local function read(path) local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local deposits=read('Code/sbm_deposits.lua')
local block=assert(deposits:match('(function DepositRules%.SingleGradeResources.-\r?\nend)\r?\n'),
  'SingleGradeResources not found')
local env=setmetatable({DepositRules={}},{__index=_G})
local single=assert(load(block..'\nreturn DepositRules.SingleGradeResources','single','t',env))()
local grades={'Very Low','Low','Average','High','Very High'}
-- Unset grade weights default to 50, as the ResourcePreset class does.
local function preset(resource,fields)
  local p=setmetatable(fields or {},{__index=function(_,key)
    if type(key)=='string' and (key:find('Weight',1,true)) then return 50 end end})
  p.resource=resource
  return p
end
local function subs(weights) local f={} for layer=1,2 do for i,g in ipairs(grades) do
  f['Subs'..layer..'Weight'..g]=weights[i] end end return f end
local function terr(weights) local f={} for i=1,5 do f['TerrWeightGrade'..i]=weights[i] end return f end

-- 1. Vanilla Mars presets (weights from Data/ResourcePreset.lua): nothing is single-grade.
local vanilla={
  Concrete_High=preset('Concrete',terr{10,20,40,20,10}),
  Concrete_VeryLow=preset('Concrete',terr{20,30,40,10,0}),
  Metals_VeryHigh=preset('Metals',subs{5,15,30,30,20}),
  Metals_VeryLow=preset('Metals',subs{20,30,40,10,0}),
  PreciousMetals_High=preset('PreciousMetals',subs{10,20,40,20,10}),
  Water_VeryLow=preset('Water',subs{50,40,10,0,0}),
  Polymers_High=preset('Polymers'),
}
assert(next(single(vanilla,grades))==nil,'vanilla presets are never single-grade')

-- 2. More Deposits with its default "grade fix": every Mars preset of the four extractor
-- resources is Very High only. Asteroid presets are left alone by that mod and ignored here.
local fixed={}
for _,level in ipairs({'VeryLow','Low','High','VeryHigh'}) do
  fixed['Concrete_'..level]=preset('Concrete',terr{0,0,0,0,100})
  fixed['Metals_'..level]=preset('Metals',subs{0,0,0,0,100})
  fixed['PreciousMetals_'..level]=preset('PreciousMetals',subs{0,0,0,0,100})
  fixed['Water_'..level]=preset('Water',subs{0,0,0,0,100})
  fixed['Polymers_'..level]=preset('Polymers')
end
fixed.Metals_Asteroid_High=preset('Metals',subs{0,10,25,35,30})
-- Below & Beyond's underground presets stay mixed (the mod is surface-only); the live game has them
-- and an earlier version of this check read them, missing every grade-fixed resource.
fixed.Metals_Underground=preset('Metals',subs{10,20,40,20,10})
fixed.Water_Underground=preset('Water',subs{40,40,20,0,0})
fixed.Concrete_Underground=preset('Concrete',terr{10,20,40,20,10})
fixed.PreciousMetals_Underground=preset('PreciousMetals',subs{10,20,40,20,10})
fixed.AsteroidCType_Metals_Average=preset('Metals',subs{0,0,35,40,25})
local result=single(fixed,grades)
assert(result.Concrete and result.Metals and result.PreciousMetals and result.Water,
  'grade-fixed resources are single-grade')
assert(not result.Polymers,'surface-only Polymers has no grade and stays unaffected')

-- 3. One preset of a resource left mixed (the mod's option turned off for that resource).
fixed.Water_High=preset('Water',subs{40,40,20,0,0})
assert(not single(fixed,grades).Water,'any mixed preset keeps the normal premium rule')

-- 4. The placement uses it: single-grade resources are never premium.
assert(deposits:find('if template and single_grade_resources[tostring(template.resource)] then return false end',1,true),
  'premium_template consults the single-grade resources')
assert(next(single(nil,grades))==nil and next(single(vanilla,{}))==nil,'missing inputs are harmless')
print('single-grade resources: vanilla unaffected, More Deposits grade fix not premium')

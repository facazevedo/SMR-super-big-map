-- ProductionOverUnder returns its infobar arrow as a plain string inside a T, which debug builds
-- assert on. SBM's shim (debug/developer builds only) wraps such parameters in Untranslated(),
-- at InfobarObj:GetResourceText, where the infobar re-translates its texts on every refresh.
TMeta={__name='T',__newindex=function() error('Modifying localized strings is forbidden') end}
local untranslated_calls=0
function Untranslated(s) untranslated_calls=untranslated_calls+1 return setmetatable({s,untranslated=true},TMeta) end
local function T(t) return setmetatable(t,TMeta) end
local handlers={}
local function engine() return {ChainOnMsg=function(name,fn) handlers[name]=fn end} end
local vanilla=function(self,res) return T{1,'<amount>',amount=5} end
InfobarObj={GetResourceText=vanilla}
Platform={debug=true}
CreateRealTimeThread=function(fn) fn() end
SuperBigMap={State={},Engine=engine()}
assert(loadfile('Code/sbm_mod_compat.lua'))()
local compat=SuperBigMap.ModCompat
local clean=vanilla(nil,'Metals')
assert(InfobarObj.GetResourceText~=vanilla,'installed at load in a debug build')
-- Another mod replaces the method after SBM loaded (its own ClassesBuilt handler).
local arrow_text=function(self,res)
  return T{100001999999,'<resource_text> <arrow>',resource_text=T{1,'12'},arrow='<color 100 0 0>v</color>',_language='English'}
end
rawset(InfobarObj,'GetResourceText',arrow_text)
handlers.ClassesBuilt()
local out=InfobarObj:GetResourceText('Metals')
assert(getmetatable(out)==TMeta and getmetatable(out.arrow)==TMeta and out.arrow[1]=='<color 100 0 0>v</color>','arrow wrapped')
assert(out[2]=='<resource_text> <arrow>' and out._language=='English' and getmetatable(out.resource_text)==TMeta,'rest kept')
-- Replaced again later: the game-start hook wraps the new one too.
rawset(InfobarObj,'GetResourceText',arrow_text)
handlers.LoadGame()
assert(getmetatable(InfobarObj:GetResourceText('Metals').arrow)==TMeta,'re-wrapped on load')
local calls=untranslated_calls
assert(compat.ApplyModBehavior() and untranslated_calls==calls,'idempotent')
rawset(InfobarObj,'GetResourceText',vanilla)
compat.ApplyModBehavior()
local v=InfobarObj:GetResourceText('Metals')
assert(v.amount==5 and getmetatable(v)==TMeta,'texts without plain-string parameters pass unchanged')
compat.RestoreVanillaBehavior()
assert(InfobarObj.GetResourceText==vanilla,'restored')
-- Release builds keep the method untouched.
Platform={}
local release=function() end
InfobarObj={GetResourceText=release}
SuperBigMap={State={},Engine=engine()}
assert(loadfile('Code/sbm_mod_compat.lua'))()
handlers.ClassesBuilt();handlers.LoadGame()
assert(InfobarObj.GetResourceText==release,'release builds untouched')
print('mod compat: GetResourceText plain-string parameters become Untranslated in debug builds only')

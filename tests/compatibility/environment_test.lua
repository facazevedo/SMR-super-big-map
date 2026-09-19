dofile("Code/sbm_engine.lua")
local environment = SuperBigMap.Engine.MapDataEnvironment
assert(environment(nil) == nil)
assert(environment(false) == nil)
assert(environment({}) == nil)
assert(environment({ Environment = "Surface" }) == "Surface")
assert(environment({ Environment = "Underground" }) == "Underground")
assert(environment({ Environment = "Asteroid" }) == "Asteroid")
local calls = 0
local preset = setmetatable({ GameStates = { Underground = true }, Environment = "Surface" }, {
  __index = { GetEnvironment = function(self)
    calls = calls + 1
    return self.GameStates.Underground and "Underground" or "Surface"
  end },
})
assert(environment(preset) == "Underground", "new accessor takes priority over stale property")
preset.GameStates.Underground = false
assert(environment(preset) == "Surface", "no stale mod-side cache")
assert(calls == 2)
assert(preset.Environment == "Surface", "mapdata must not be modified")
print("PASS: current accessor, inherited method, legacy fallback, live changes, no mutation")
local engine = SuperBigMap.Engine
local old_shape, outline_shape, new_shape = {}, {}, {}
GetEnclosedShape = function(entity) assert(entity == "Wonder"); return old_shape end
g_NCF_FlatOuter = 3000
const = { HexSize = 1000 }
assert(engine.WonderFlattenShape("Wonder") == old_shape)
assert(engine.WonderFlattenOuter() == 3000)
GetEnclosedShape = nil
GetEntityOutlineShape = function(entity) assert(entity == "Wonder"); return outline_shape end
ShrinkShape = function(shape, amount)
  assert(shape == outline_shape and amount == 2)
  return new_shape
end
assert(engine.WonderFlattenShape("Wonder") == new_shape)
assert(engine.WonderFlattenOuter() == 1500)
ShrinkShape = nil
assert(engine.WonderFlattenShape("Wonder") == nil)
print("PASS: old and 1.1 wonder shape/radius protocols; missing helper fails closed")
local owner = { Landscapes = {} }
LandscapeFinish = function(map, mark) assert(map == owner and mark == 42); return "map-owned" end
assert(engine.FinishLandscape(owner, 42) == "map-owned")
LandscapeFinish = function(mark, extra) assert(mark == 42 and extra == nil); return "legacy" end
assert(engine.FinishLandscape({}, 42) == "legacy")
print("PASS: landscape finish routes to explicit map owner on 1.1 and legacy mark on older games")

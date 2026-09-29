-- A DLC/environment or another wrapper may retain an older SBM calculator.
-- Reinstalling and restoring our latest hook must not redirect that older hook
-- into itself (or clear the function it still needs to call).
local vanilla_calls, foreign_calls = 0, 0
local vanilla = function(angle, map)
 vanilla_calls = vanilla_calls + 1
 assert(angle == 2700 and map == CurrentMap, 'camera arguments changed')
 return false, false
end
CurrentMap = {}
CalcOverviewCameraPos = vanilla
SuperBigMap = {
 Config = {}, State = {},
 Engine = {
  Global = function(name)return _G[name]end,
  SafeCall = function(fn, ...)if type(fn)=='function' then return fn(...)end end,
  IsLiveMap = function(map)return map==CurrentMap end,
 },
 SectorGrid = {IsModMap = function()return true end},
}
dofile('Code/sbm_overview_camera.lua')
local camera = SuperBigMap.OverviewCamera
camera.ApplyModBehavior()
local first = CalcOverviewCameraPos
camera.ApplyModBehavior()
assert(CalcOverviewCameraPos == first, 'repeated installation added a wrapper')
local foreign = function(angle, map)
 foreign_calls = foreign_calls + 1
 assert(foreign_calls < 10, 'camera rebind created recursive wrappers')
 return first(angle, map)
end
CalcOverviewCameraPos = foreign
camera.ApplyModBehavior()
assert(CalcOverviewCameraPos ~= foreign, 'replacement calculator was not wrapped')
CalcOverviewCameraPos(2700, CurrentMap)
assert(vanilla_calls == 1 and foreign_calls == 1, 'predecessor was not called exactly once')
camera.RestoreVanillaBehavior()
assert(CalcOverviewCameraPos == foreign, 'restore clobbered the replacement owner')
CalcOverviewCameraPos(2700, CurrentMap)
assert(vanilla_calls == 2 and foreign_calls == 2, 'restore broke a retained old wrapper')
-- An environment can publish an older SBM wrapper again; its own predecessor
-- must remain immutable when a new installation adopts it.
CalcOverviewCameraPos = first
camera.ApplyModBehavior()
CalcOverviewCameraPos(2700, CurrentMap)
assert(vanilla_calls == 3, 'adopting an older wrapper redirected its predecessor')
local replacement = function()return 'fresh', 'calculator' end
CalcOverviewCameraPos = replacement
camera.RestoreVanillaBehavior()
assert(CalcOverviewCameraPos == replacement, 'restore clobbered a newer external owner')
print('overview camera rebind: immutable predecessors, idempotence and ownership-safe restore')

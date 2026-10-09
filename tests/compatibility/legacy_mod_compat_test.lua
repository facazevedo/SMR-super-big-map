-- Known callers across mod combinations, map ownership and message reloads.
local handlers = {}
local function fire(name, ...)
  for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end
function GetStaticMsgNames() end
function CurrentThread() return coroutine.running() end
Platform = {}
ModsLoaded = {}
g_Classes = {Elevator = {}, TrainTerminal = {}}
SuperBigMap = {State = {}, ModCompat = {}, Engine = {
  Global = function(name) return rawget(_G, name) end,
  ChainOnMsg = function(name, fn)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], fn)
  end,
}}
local path = 'Code/sbm_mod_compat_legacy.lua'
assert(loadfile(path))()
local compat = SuperBigMap.ModCompat
assert(MapGet == nil and OmegaTelescopeActiveandPowered == nil, 'no global API/counter pollution')
local valid = function(obj) return obj and not obj.deleted or false end
local mars = {id = 'AKQWwUW', version = 55, env = {IsValid = valid}}
local omega = {id = 'JFHbPn6', version = 37, env = {}}
ModsLoaded = {mars, omega}
fire('ModsReloaded')
assert(mars.env.MapGet and mars.env.IsValid ~= valid)
assert(omega.env.OmegaTelescopeActiveandPowered == 0)
assert(omega.env.ChanceForBreakthroughSequenceToActivate == 0)
omega.env.OmegaTelescopeActiveandPowered = 7
omega.env.ChanceForBreakthroughSequenceToActivate = 123
local first = mars.env.MapGet
compat.ApplyLegacyCompatibility()
assert(mars.env.MapGet == first and omega.env.OmegaTelescopeActiveandPowered == 7)
assert(omega.env.ChanceForBreakthroughSequenceToActivate == 123)
local surface, underground = {}, {}
CurrentMap = surface
local queries = {}
for _, map in ipairs({surface, underground}) do
  function map:MapGet(pos, radius, class)
    queries[#queries + 1] = {map = self, pos = pos, radius = radius, class = class}
    return {self}
  end
end
local function object(map)
  return {GetMap = function() return map end, GetPos = function() return 'same coordinates' end}
end
local a, b = object(surface), object(underground)
-- Callbacks may overlap across their Sleep(600); context must be per thread.
local function query(obj)
  assert(mars.env.IsValid(obj))
  coroutine.yield()
  local result = mars.env.MapGet(obj:GetPos(), 30, 'UndergroundElevator', 'Elevator')
  assert(result[1] == obj:GetMap() and #result == 1)
end
local ca, cb = coroutine.create(function() query(a) end), coroutine.create(function() query(b) end)
assert(coroutine.resume(ca)); assert(coroutine.resume(cb))
assert(coroutine.resume(cb)); assert(coroutine.resume(ca))
assert(#queries == 2 and queries[1].map == underground and queries[2].map == surface)
assert(queries[1].class == 'Elevator', 'removed class excluded')
assert(not pcall(mars.env.MapGet, a:GetPos(), 30, 'Elevator'), 'no stale or guessed map')
assert(mars.env.IsValid(a))
assert(not pcall(mars.env.MapGet, 'different position', 30, 'Elevator'), 'unexpected caller rejected')
a.deleted = true
assert(not mars.env.IsValid(a))
assert(not pcall(mars.env.MapGet, a:GetPos(), 30, 'Elevator'))
a.deleted = nil
g_Classes.UndergroundElevator = {}
assert(mars.env.IsValid(a))
assert(#mars.env.MapGet(a:GetPos(), 30, 'UndergroundElevator', 'Elevator') == 1, 'union deduplicated')
-- Reload registration is idempotent within one native message epoch.
assert(loadfile(path))()
assert(#handlers.ModsReloaded == 1)
handlers = {}
GetStaticMsgNames = function() return {} end
assert(loadfile(path))()
assert(#handlers.ModsReloaded == 1)
fire('ModUnloadLua', 'UnrelatedMod')
assert(mars.env.MapGet)
fire('ModUnloadLua', 'AKQWwUW')
assert(mars.env.MapGet == nil and mars.env.IsValid == valid)
-- Disabled, future/fixed mods and pre-existing adapters are untouched.
ModsLoaded = {}
compat.ApplyLegacyCompatibility()
assert(mars.env.MapGet == nil)
ModsLoaded = {mars}; mars.version = 56
compat.ApplyLegacyCompatibility(); assert(mars.env.MapGet == nil)
mars.version = 55
local foreign = function() return 'foreign' end
mars.env.MapGet = foreign
compat.ApplyLegacyCompatibility(); assert(mars.env.MapGet == foreign and mars.env.IsValid == valid)
mars.env.MapGet = nil; MapGet = foreign
-- Real sandbox rawget falls through to native globals; emulate the exposed API.
mars.env.MapGet = MapGet
compat.ApplyLegacyCompatibility(); assert(mars.env.MapGet == foreign)
mars.env.MapGet = nil; MapGet = nil
compat.ApplyLegacyCompatibility()
mars.env.MapGet = foreign
fire('ModUnloadLua', 'SuperBigMap')
assert(mars.env.MapGet == foreign, 'do not remove later third-party replacement')
assert(omega.env.OmegaTelescopeActiveandPowered == 7, 'never erase live counters')
assert(rawget(_G, 'OmegaTelescopeActiveandPowered') == nil)
print('legacy mod compatibility: isolated adapters, map ownership, lifecycle and counter preservation passed')

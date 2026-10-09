-- The inspection button must complete both halves while simulation is paused.
-- Native placement emits the first site message before creating the second half.
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local real_tasks, game_tasks, events = {}, {}, {}
local surface, underground = {}, {}
local globals = { CurrentMap = surface }
globals.GetStaticMsgNames = function() end
local handlers, registrations = {}, 0
local function queue(list, fn) list[#list + 1] = coroutine.create(fn) end
globals.CreateRealTimeThread = function(fn) queue(real_tasks, fn) end
globals.CreateGameTimeThread = function(fn) queue(game_tasks, fn) end
globals.WaitNextFrame = function() coroutine.yield() end
globals.IsValid = function(obj) return obj.valid == true end
local function step(list)
  local pending = {}
  for _, co in ipairs(list) do pending[#pending + 1] = co end
  for i = #list, 1, -1 do list[i] = nil end
  for _, co in ipairs(pending) do
    local ok, err = coroutine.resume(co)
    assert(ok, err)
    if coroutine.status(co) ~= "dead" then list[#list + 1] = co end
  end
end
local sbm = {
  State = {}, Config = { PLACE_ELEVATOR_BUTTON_ENABLED = true },
  Lifecycle = { IsActive = function() return true end },
  SectorGrid = { IsModMap = function(map) return map == surface or map == underground end },
  Diagnostics = { Elevator = function(event, data) events[#events + 1] = {event, data} end },
  Engine = {
    Global = function(name) return globals[name] end,
    SafeCall = function(fn, ...) return fn(...) end,
    ChainOnMsg = function(name, fn) handlers[name] = fn; registrations = registrations + 1 end,
  },
}
local env = setmetatable({SuperBigMap = sbm}, {__index = _G})
env._G = env
assert(loadfile("Code/sbm_place_elevator_button.lua", "t", env))()
check(registrations == 1, "register the native placement message")
assert(loadfile("Code/sbm_place_elevator_button.lua", "t", env))()
check(registrations == 1, "module reload must not duplicate the message")
handlers = {}
globals.GetStaticMsgNames = function() end
assert(loadfile("Code/sbm_place_elevator_button.lua", "t", env))()
check(registrations == 2 and handlers.ConstructionSitePlaced,
  "full Lua reload must re-register against the replacement native registry")
local handle = handlers.ConstructionSitePlaced
local function pair()
  local p1, p2 = {valid = true}, {valid = true}
  local a = {valid = true, building_class = "Elevator", snapped_to = p1,
    GetMap = function() return surface end}
  local b = {valid = false, building_class = "Elevator", snapped_to = p2,
    GetMap = function() return underground end}
  local calls = 0
  local leader = {valid = true}
  local group = {leader, a, b}
  a.construction_group, b.construction_group = group, group
  function leader:Complete(mode)
    check(mode == "quick_build", "use native quick-build for the entire group")
    check(b.valid, "second half must exist before completion")
    calls = calls + 1
    a.valid, b.valid, self.valid = false, false, false
    globals.CreateGameTimeThread(function()
      local first = {valid = true, GetMap = a.GetMap}
      local second = {valid = true, GetMap = b.GetMap}
      first.other, second.other = second, first
      p1.elevator, p2.elevator = first, second
    end)
  end
  return a, b, function() return calls end
end

local a, b, calls = pair()
sbm.State.place_elevator_button_armed = true
handle(a, "Elevator")
step(real_tasks) -- the native placement stack has not created its other half yet
check(calls() == 0, "never finish inside the first site's placement message")
b.valid = true
handle(b, "Elevator")
step(real_tasks) -- only wall-clock/render tasks run while paused
check(calls() == 1, "paused placement must complete both halves without advancing game time")
check(not a.valid and not b.valid, "neither construction site may remain")
step(real_tasks)
check(calls() == 1, "paired site messages must not build twice")
step(game_tasks) -- normal native GameInit when simulation resumes
check(events[#events][1] == "TEMP_BUTTON_COMPLETE", "native GameInit links both completed buildings")

local c, d, ordinary_calls = pair()
d.valid = true
handle(c, "Elevator")
step(real_tasks); step(game_tasks)
check(ordinary_calls() == 0, "ordinary elevator construction must remain unchanged")

sbm.State.place_elevator_button_armed = true
handle({valid = true, building_class = "Other"}, "Other")
check(sbm.State.place_elevator_button_armed == true, "unrelated construction must not consume the button")
sbm.Config.PLACE_ELEVATOR_BUTTON_ENABLED = false
handle(c, "Elevator")
step(real_tasks); step(game_tasks)
check(ordinary_calls() == 0, "disabled inspection aid must never complete construction")
print("elevator button completion: " .. checks .. " checks passed")

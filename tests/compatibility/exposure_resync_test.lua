-- After a map switch on an expanded map the game's eye-adaptation reset (hr.AutoExposureReset)
-- lands on a pre-scene frame, so the new map eases in over ~2 s instead of appearing correctly
-- exposed at once as in vanilla (measured 2026-09-28). The mod re-issues the reset once the scene
-- renders, only for expanded maps, only while that map stays current, and only with eye
-- adaptation on.
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function read(path)
	local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s
end

-- hr is a proxy so every write to AutoExposureReset can be counted.
local sets = 0
local backing = { AutoExposureReset = 0, AutoExposureMode = 1, FarZ = 700000 }
local hr = setmetatable({}, { __index = backing, __newindex = function(_, k, v)
	if k == "AutoExposureReset" and v == 1 then sets = sets + 1 end
	backing[k] = v
end })
local map_a, map_b = { name = "A" }, { name = "B" }
local globals = { hr = hr, CurrentMap = map_a, ChangingMap = false, table = table }
local waited, threads = {}, {}
globals.WaitNextFrame = function(n) waited[#waited + 1] = n; hr.AutoExposureReset = 0 end -- the engine consumes the flag each frame
globals.CreateRealTimeThread = function(fn) threads[#threads + 1] = fn end
local SuperBigMap = {
	Engine = { Global = function(name) return globals[name] end },
	Config = {},
	State = {},
}
local env = setmetatable({ SuperBigMap = SuperBigMap }, { __index = _G })
env._G = env
assert(loadfile("Code/sbm_overview_render.lua", "t", env))()
local R = SuperBigMap.OverviewRender

-- 1. The reset is re-issued after the first frames and again a little later, while the map stays current.
check(R.ResyncExposureAfterMapSwitch(map_a) == true and #threads == 1, "a switch must schedule the resync")
threads[1]()
check(#waited == 2 and waited[1] >= 4 and waited[2] >= 4, "the resync must wait for the scene to render: " .. table.concat(waited, ","))
check(sets == 2, "the reset must be re-issued twice, got " .. sets)

-- 2. Another switch in between: nothing is re-issued for the old map.
waited, threads, sets = {}, {}, 0
R.ResyncExposureAfterMapSwitch(map_a)
globals.CurrentMap = map_b
threads[1]()
check(sets == 0, "a resync for a map that is no longer current must do nothing")
globals.CurrentMap = map_a
waited, threads, sets = {}, {}, 0
R.ResyncExposureAfterMapSwitch(map_a)
globals.ChangingMap = true
threads[1]()
check(sets == 0, "a resync during another map change must do nothing")
globals.ChangingMap = false

-- 3. Eye adaptation off, or no engine variable: no thread.
threads = {}
hr.AutoExposureMode = 0
check(R.ResyncExposureAfterMapSwitch(map_a) == false and #threads == 0, "eye adaptation off must schedule nothing")
hr.AutoExposureMode = 1
globals.hr = { AutoExposureMode = 1 }
check(R.ResyncExposureAfterMapSwitch(map_a) == false and #threads == 0, "an engine without the reset variable must schedule nothing")
globals.hr = hr

-- 4. Wiring: only expanded maps, from the map-switch handler.
local lifecycle = read("Code/sbm_lifecycle.lua")
check(lifecycle:find("if IsModMap(map) and render and type(render.ResyncExposureAfterMapSwitch) == \"function\" then", 1, true),
	"the lifecycle must resync only for expanded maps")
local handler = lifecycle:match('RegisterOnce%("CurrentMapChangeDone".-\nend%)')
check(handler and handler:find("render.ResyncExposureAfterMapSwitch", 1, true), "the resync must run from CurrentMapChangeDone")
print("exposure resync: " .. checks .. " checks passed")

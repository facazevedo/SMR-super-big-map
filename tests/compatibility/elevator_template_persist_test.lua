-- The Elevator placement fix must never store a function on BuildingTemplates.Elevator: every
-- construction site keeps that template as building_class_proto and the savegame persists it by
-- value, so a function there made every save during Elevator construction fail with "Fatal
-- persist errors" (found 2026-09-27). The template resolves methods through its class, so patching
-- ElevatorBase and the Elevator class already covers the construction controller's call.
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end

local vanilla = function() return "vanilla" end
local ElevatorBase = { PlaceConstructionSite = vanilla }
local ElevatorClass = { PlaceConstructionSite = vanilla } -- classes are method-flattened copies
-- As measured in game: no own field, metatable __index is g_Classes.Elevator.
local template = setmetatable({ id = "Elevator", display_name = "Elevator" }, { __index = ElevatorClass })
local classes = { ElevatorBase = ElevatorBase, Elevator = ElevatorClass }
local globals = { BuildingTemplates = { Elevator = template } }
local SuperBigMap = {
	Engine = {
		Global = function(name) return globals[name] end,
		SafeCall = function(fn, ...) local r = { pcall(fn, ...) }; if r[1] then return select(2, table.unpack(r)) end end,
		ClassTable = function(name) return classes[name] end,
	},
	Config = { ENABLE_MOD = true, PREVENT_ELEVATOR_FLATTEN = true },
	State = {},
	SectorGrid = { IsModMap = function() return true end },
}
local function load_module()
	local env = setmetatable({ SuperBigMap = SuperBigMap }, { __index = _G })
	env._G = env
	assert(loadfile("Code/sbm_rocket_rules.lua", "t", env))()
	return SuperBigMap.RocketRules
end
local R = load_module()
local State = SuperBigMap.State

local function template_functions()
	local found = {}
	for k, v in pairs(template) do
		if type(v) == "function" then found[#found + 1] = tostring(k) end
	end
	return found
end

-- 1. Expanded session: both classes carry the wrapper, the template stays data-only.
R.ApplyModBehavior()
local wrapper = State.elevator_base_place_construction_site_wrapper
check(type(wrapper) == "function" and wrapper ~= vanilla, "the elevator placement wrapper must be installed")
check(ElevatorBase.PlaceConstructionSite == wrapper and ElevatorClass.PlaceConstructionSite == wrapper, "both classes must be patched")
check(rawget(template, "PlaceConstructionSite") == nil, "the template must not hold the wrapper")
check(template.PlaceConstructionSite == wrapper, "the template must still reach the wrapper through its class")
check(#template_functions() == 0, "a persisted template must contain no functions: " .. table.concat(template_functions(), ","))
R.ApplyModBehavior()
check(ElevatorClass.PlaceConstructionSite == wrapper and rawget(template, "PlaceConstructionSite") == nil, "re-applying is a no-op")

-- 2. A wrapper an earlier build left on the template (same process) is removed.
rawset(template, "PlaceConstructionSite", wrapper)
State.elevator_base_place_construction_site_version = 2
R.ApplyModBehavior()
check(rawget(template, "PlaceConstructionSite") == nil, "a stale template wrapper must be removed")
local wrapper2 = State.elevator_base_place_construction_site_wrapper
check(ElevatorClass.PlaceConstructionSite == wrapper2 and template.PlaceConstructionSite == wrapper2, "the new wrapper reaches the template")

-- 3. Vanilla session: classes restored, and no vanilla function is written onto the template.
R.RestoreVanillaBehavior()
check(ElevatorBase.PlaceConstructionSite == vanilla and ElevatorClass.PlaceConstructionSite == vanilla, "restore must bring back the vanilla methods")
check(rawget(template, "PlaceConstructionSite") == nil and #template_functions() == 0, "restore must leave the template data-only")

-- 4. Another mod's own override on the template is left alone.
local foreign = function() return "foreign" end
rawset(template, "PlaceConstructionSite", foreign)
R.ApplyModBehavior()
check(rawget(template, "PlaceConstructionSite") == foreign, "a foreign template override must be kept")
R.RestoreVanillaBehavior()
check(rawget(template, "PlaceConstructionSite") == foreign, "restore must keep a foreign template override")
rawset(template, "PlaceConstructionSite", nil)

-- 5. The source never assigns a method onto the template.
local f = assert(io.open("Code/sbm_rocket_rules.lua", "rb")); local src = f:read("*a"); f:close()
check(not src:find("ElevatorTemplate.PlaceConstructionSite =", 1, true), "no template assignment may remain")
check(src:find("local ELEVATOR_METHOD_PATCH_VERSION = 3", 1, true), "the patch version must be bumped so live installs are redone")
print("elevator template persist: " .. checks .. " checks passed")

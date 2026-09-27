-- Complete underground darkness: the shipped shader sources and cache-bypass entries are mounted
-- when the mod loads, before any map is shown (the renderer builds the reflection programs once per
-- process and never reloads them). Every shader stage is gated on hr.MeshDebugParam2, which the
-- module sets to its flag together with strength 100 only for an expanded underground; everywhere
-- else the flag is 0 and the strength is vanilla's.
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end

local function read(path)
	local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s
end

-- Load the module against a stub engine environment.
local function load_module(opts)
	local calls = { mounts = {}, unmounts = {}, reload = 0 }
	local labels = {}
	-- The sandbox hides MountFolder, UnmountByLabel and ReloadShaders from direct lookup; the
	-- module must reach them through the engine's FuncResolver helper, so the stub exposes them
	-- only there.
	local hidden = {}
	local globals = {
		FuncResolver = function(name)
			return function(self) return hidden[name] end
		end,
	}
	hidden.MountFolder = function(target, source, flags)
		calls.mounts[#calls.mounts + 1] = { target = target, source = source, flags = flags }
		if opts.mount_error then return opts.mount_error end
		local label = flags:match("label:([%w_]+)")
		labels[label] = (labels[label] or 0) + 1
		return false
	end
	hidden.UnmountByLabel = function(label)
		calls.unmounts[#calls.unmounts + 1] = label
		labels[label] = 0
	end
	hidden.ReloadShaders = function() calls.reload = calls.reload + 1 end
	hidden.MountsByLabel = function(label) return labels[label] or 0 end
	local hr = opts.hr or { MeshDebugParam2 = 0 }
	for k, v in pairs({
		CurrentMap = opts.current_map,
		LoadedMaps = opts.loaded_maps,
		print = function() end,
		LuaRevision = opts.lua_revision or 405907,
		AssetsRevision = opts.assets_revision or 33225,
		Platform = opts.platform or { pc = true },
		config = opts.config or { GraphicsApi = "d3d12" },
		hr = hr,
	}) do globals[k] = v end
	if opts.no_resolver then globals.FuncResolver = nil end
	local SuperBigMap = {
		Engine = {
			Global = function(name) return globals[name] end,
			SafeCall = function(fn, ...) return pcall(fn, ...) end,
		},
		Config = { UNDERGROUND_COMPLETE_DARKNESS = opts.enabled,
			UNDERGROUND_COMPLETE_DARKNESS_LUA_REVISION = 405907,
			UNDERGROUND_COMPLETE_DARKNESS_ASSETS_REVISION = 33225 },
		State = opts.state or {},
	}
	local env = setmetatable({
		SuperBigMap = SuperBigMap,
		CurrentModPath = opts.mod_path,
		io = { exists = function(path) return opts.exists(path) end },
	}, { __index = _G })
	env._G = env
	local chunk = assert(loadfile("Code/sbm_underground_darkness.lua", "t", env))
	chunk()
	return SuperBigMap, calls, hr
end

local all_present = function() return true end
local FLAG = 1396853041

-- 1. Loading the module (no map shown yet) mounts both folders, seethrough with priority, and
-- compiles or reloads nothing itself. The mark flag stays off.
local sbm, calls, hr = load_module({ enabled = true, mod_path = "AppData/Mods/super-big-map/", exists = all_present })
local D = sbm.UndergroundDarkness
check(D.MARK_FLAG == FLAG, "module flag must be SBM1")
check(D.Mounted() and D.Active(), "loading before any map must mount and be active: " .. tostring(sbm.State.underground_darkness_mount_reason))
check(#calls.mounts == 2, "expected two mounts, got " .. #calls.mounts)
check(calls.mounts[1].target == "Shaders" and calls.mounts[1].source == "AppData/Mods/super-big-map/Shaders/", "shader source mount wrong")
check(calls.mounts[2].target == "ShaderCache" and calls.mounts[2].source == "AppData/Mods/super-big-map/ShaderCache/", "cache bypass mount wrong")
for _, m in ipairs(calls.mounts) do
	check(m.flags:find("seethrough", 1, true) and m.flags:find("priority:high", 1, true), "mount must be seethrough with priority: " .. m.flags)
end
check(calls.reload == 0, "the module must never call ReloadShaders (it cannot swap built programs)")
check(hr.MeshDebugParam2 == 0, "loading must leave the mark flag off")

-- 2. The per-map decision: only an expanded underground gets strength 100 with the flag on.
check(D.ApplyForMap(nil, "Underground", true) == 100 and hr.MeshDebugParam2 == FLAG, "expanded underground: strength 100 and flag on")
check(D.ApplyForMap(nil, "Surface", true) == 90 and hr.MeshDebugParam2 == 0, "expanded surface: flag off")
check(D.ApplyForMap(nil, "Underground", true) == 100 and hr.MeshDebugParam2 == FLAG, "back underground: flag on again")
check(D.ApplyForMap(nil, "Underground", false) == 90 and hr.MeshDebugParam2 == 0, "vanilla underground: strength 90, flag off")
check(D.RevealStrength(nil, false) == 90, "a vanilla map must keep strength 90")
D.ApplyForMap(nil, "Underground", true)
check(D.RestoreVanillaBehavior() == true and hr.MeshDebugParam2 == 0, "a vanilla session must clear the flag")
check(D.ApplyModBehavior() == true and hr.MeshDebugParam2 == 0, "starting an expanded session sets nothing until a map needs it")
local ok, why = D.Mount()
check(ok and why == "already mounted" and #calls.mounts == 2, "a second mount must be a no-op")

-- 3. A value someone else put in hr.MeshDebugParam2 is never clobbered; no flag, no strength 100.
hr.MeshDebugParam2 = 7
check(D.ApplyForMap(nil, "Underground", true) == 90 and hr.MeshDebugParam2 == 7, "a foreign value must be kept and complete darkness refused")
D.SetMarking(false)
check(hr.MeshDebugParam2 == 7, "switching off must not clear a foreign value")
hr.MeshDebugParam2 = 0

-- 4. An hr that does not keep the flag (engine without the variable) refuses strength 100.
do
	local sink = setmetatable({}, { __index = function(_, k) if k == "MeshDebugParam2" then return 0 end end,
		__newindex = function() end })
	local s = load_module({ enabled = true, mod_path = "M/", exists = all_present, hr = sink })
	check(s.UndergroundDarkness.Active(), "mounting only needs the variable to read as a number")
	check(s.UndergroundDarkness.ApplyForMap(nil, "Underground", true) == 90, "a flag that does not read back must refuse strength 100")
	check(s.State.underground_darkness_marking_reason == "hr.MeshDebugParam2 did not keep the flag", "reason must say the flag did not hold")
end

-- 5. Mod unloaded: flag off, both folders unmounted, vanilla strength from then on.
D.ApplyForMap(nil, "Underground", true)
check(D.Unmount("mod unloaded") == 2 and hr.MeshDebugParam2 == 0, "unmount must remove both mounts and clear the flag")
check(not D.Mounted() and not D.Active() and D.ApplyForMap(nil, "Underground", true) == 90, "after unmount everything is vanilla")
check(calls.reload == 0, "unmounting must not call ReloadShaders either")

-- 6. A map already shown when the mod loads: the renderer may hold the game's programs, so the
-- module mounts but never reports strength 100 (a restart is needed).
for _, case in ipairs({ { current_map = { name = "PreGame" } }, { loaded_maps = { { name = "PreGame" } } } }) do
	local s = load_module({ enabled = true, mod_path = "M/", exists = all_present,
		current_map = case.current_map, loaded_maps = case.loaded_maps })
	check(s.UndergroundDarkness.Mounted() and not s.UndergroundDarkness.Active(), "a late mount must not be active")
	check(tostring(s.State.underground_darkness_mount_reason):find("restart", 1, true), "late mount reason must ask for a restart")
	check(s.UndergroundDarkness.ApplyForMap(nil, "Underground", true) == 90, "a late mount must keep strength 90")
end

-- 7. A re-executed module keeps the process's mount and verdict.
do
	local state = { underground_darkness_mounted = true, underground_darkness_programs_from_mount = true }
	local s, c = load_module({ enabled = true, mod_path = "M/", exists = all_present, state = state,
		current_map = { name = "Surface" } })
	check(#c.mounts == 0 and s.UndergroundDarkness.Active(), "re-execution must not remount or lose the verdict")
end

-- 8. Every refusal to mount falls back to vanilla strength and says why.
local function refused(opts, needle, message)
	opts.enabled = opts.enabled ~= false
	opts.mod_path = opts.mod_path or "M/"
	opts.exists = opts.exists or all_present
	local s, c = load_module(opts)
	check(not s.UndergroundDarkness.Mounted(), message .. ": must not mount")
	check(tostring(s.State.underground_darkness_mount_reason):find(needle, 1, true),
		message .. ": reason " .. tostring(s.State.underground_darkness_mount_reason))
	check(s.UndergroundDarkness.ApplyForMap(nil, "Underground", true) == 90, message .. ": strength 90")
	return c
end
refused({ exists = function(p) return not p:find("ApplyReflections", 1, true) end }, "ApplyReflections.fx", "missing source")
refused({ no_resolver = true }, "MountFolder unavailable", "no resolver")
refused({ lua_revision = 405908 }, "differs from the shader cache build", "other Lua build")
refused({ assets_revision = 1 }, "differs from the shader cache build", "other assets build")
refused({ platform = { pc = false, xbox = true } }, "not the PC build", "console")
refused({ config = { GraphicsApi = "vulkan" } }, "is not d3d12", "other graphics API")
refused({ hr = {} }, "hr.MeshDebugParam2 unavailable", "no flag variable")
refused({ mount_error = "no such folder" }, "mount failed", "mount error")
local c = refused({ enabled = false }, "disabled by configuration", "disabled")
check(#c.mounts == 0, "disabled configuration must not mount")

-- 9. Wiring: lifecycle phases, the mod-unload hook, the per-map decision at both darkness sites,
-- and the shader flag.
local lifecycle = read("Code/sbm_lifecycle.lua")
local apply = lifecycle:match("local APPLY_ORDER = (%b{})")
local restore = lifecycle:match("local RESTORE_ORDER = (%b{})")
check(apply and apply:find('"UndergroundDarkness"', 1, true), "the expanded-session apply phase must include the module")
check(restore and restore:find('"UndergroundDarkness"', 1, true), "the vanilla restore phase must clear the flag")
check(restore:find('"UndergroundDarkness"', 1, true) < restore:find('"HeatSafety"', 1, true), "restore must run in reverse order")
check(lifecycle:find('RegisterOnce("ModUnloadLua"', 1, true) and lifecycle:find('darkness.Unmount, "mod unloaded"', 1, true),
	"unloading the mod must unmount")
check(lifecycle:find("SafeCall(darkness.ApplyForMap, map, environment, IsModMap(map))", 1, true), "lifecycle darkness state must use ApplyForMap")
check(lifecycle:find("SafeCall(darkness.SetMarking, false)", 1, true), "lifecycle must clear the flag whenever the map is not a complete-darkness underground")
local generation = read("Code/sbm_map_generation.lua")
check(generation:find("pcall(darkness.ApplyForMap, map, environment, is_mod_map)", 1, true), "EnsureVanillaDarknessReady must use ApplyForMap")
check(not generation:find('local expected = environment == "Underground" and 90 or 0', 1, true), "hard-coded strength 90 must be gone")
for _, path in ipairs({ "Code/sbm_lifecycle.lua", "Code/sbm_map_generation.lua", "Code/sbm_underground_darkness.lua" }) do
	local src = read(path)
	check(not src:find("EnsureShadersActive", 1, true), path .. " must not keep the ReloadShaders switch")
	check(not src:find('real_global_function("ReloadShaders")', 1, true), path .. " must not call ReloadShaders")
end
local module = read("Code/sbm_underground_darkness.lua")
check(module:find("\ndo\n\tlocal State = SuperBigMap.State\n\tif State.underground_darkness_mounted ~= true then", 1, true), "the module must mount at load")
local header = read("Shaders/SbmReflectionMark.fh")
check(header:find("#define SBM_MARK_FLAG " .. FLAG, 1, true), "shader flag must match the module flag")
local config = read("Code/sbm_config.lua")
check(config:find("config.UndergroundCompleteDarkness = true", 1, true), "complete darkness must default on")
check(config:find("C.UNDERGROUND_COMPLETE_DARKNESS = as_bool(config.UndergroundCompleteDarkness)", 1, true), "config key missing")
local metadata = read("metadata.lua")
local pos_dark = metadata:find("Code/sbm_underground_darkness.lua", 1, true)
local pos_life = metadata:find("Code/sbm_lifecycle.lua", 1, true)
check(pos_dark and pos_life and pos_dark < pos_life, "darkness module must load before the lifecycle")
print("underground darkness module: " .. checks .. " checks passed")

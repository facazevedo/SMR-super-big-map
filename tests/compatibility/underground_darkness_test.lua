-- Complete underground darkness: the shipped shader sources and cache-bypass entries are mounted
-- only during an expanded session, switched in only before an expanded underground is shown, and
-- removed again for a vanilla session or when the mod is unloaded. The complete strength is
-- reported only while the shaders are mounted and in use, and only for mod maps.
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
	for k, v in pairs({
		CurrentMap = opts.current_map,
		print = function() end,
		LuaRevision = opts.lua_revision or 405907,
		AssetsRevision = opts.assets_revision or 33225,
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
		State = opts.state,
	}
	local env = setmetatable({
		SuperBigMap = SuperBigMap,
		CurrentModPath = opts.mod_path,
		io = { exists = function(path) return opts.exists(path) end },
	}, { __index = _G })
	env._G = env
	local chunk = assert(loadfile("Code/sbm_underground_darkness.lua", "t", env))
	chunk()
	return SuperBigMap, calls
end

local all_present = function() return true end

-- 1. Loading the module changes nothing: the main menu and vanilla sessions keep the game's shaders.
local sbm, calls = load_module({ enabled = true, mod_path = "AppData/Mods/super-big-map/", exists = all_present })
local D = sbm.UndergroundDarkness
check(not D.Mounted() and #calls.mounts == 0 and calls.reload == 0, "loading the module must not mount or reload anything")
check(D.RevealStrength(nil, true) == 90, "before an expanded session the strength must stay vanilla")

-- 2. Expanded session: mount both folders, seethrough with priority, but compile nothing yet.
check(D.ApplyModBehavior() == true, "expanded session must mount: " .. tostring(sbm.State.underground_darkness_mount_reason))
check(D.Mounted() and not D.Active(), "mounted but not yet switched in")
check(#calls.mounts == 2, "expected two mounts, got " .. #calls.mounts)
check(calls.mounts[1].target == "Shaders" and calls.mounts[1].source == "AppData/Mods/super-big-map/Shaders/", "shader source mount wrong")
check(calls.mounts[2].target == "ShaderCache" and calls.mounts[2].source == "AppData/Mods/super-big-map/ShaderCache/", "cache bypass mount wrong")
for _, m in ipairs(calls.mounts) do
	check(m.flags:find("seethrough", 1, true) and m.flags:find("priority:high", 1, true), "mount must be seethrough with priority: " .. m.flags)
end
check(calls.reload == 0, "mounting must not reload shaders (no START-to-T1 cost)")
check(D.RevealStrength(nil, true) == 90, "strength 100 requires the shaders to be in use")

-- 3. First expanded underground: switch the shaders in once, then report strength 100 for mod maps.
check(D.EnsureShadersActive() == true and calls.reload == 1, "switching in must reload shaders once")
check(D.EnsureShadersActive() == true and calls.reload == 1, "a second switch must be a no-op")
check(D.Active() and D.RevealStrength(nil, true) == 100, "mod underground must use strength 100 once active")
check(D.RevealStrength(nil, false) == 90, "a vanilla map must keep strength 90")
local ok, why = D.Mount()
check(ok and why == "already mounted" and #calls.mounts == 2, "a second mount must be a no-op")

-- 4. Vanilla session: unmount both folders and reload so the game's own programs come back.
check(D.RestoreVanillaBehavior() == true, "restore must succeed")
check(#calls.unmounts == 2 and calls.reload == 2, "restore must unmount both folders and reload once")
check(not D.Mounted() and not D.Active() and D.RevealStrength(nil, true) == 90, "after restore everything is vanilla")
D.RestoreVanillaBehavior()
check(#calls.unmounts == 2 and calls.reload == 2, "restoring twice must be a no-op")

-- 4b. A session that never reached the underground unmounts without reloading.
sbm, calls = load_module({ enabled = true, mod_path = "M/", exists = all_present })
sbm.UndergroundDarkness.ApplyModBehavior()
sbm.UndergroundDarkness.RestoreVanillaBehavior()
check(#calls.unmounts == 2 and calls.reload == 0, "an unswitched mount must unmount without a shader reload")

-- 4c. Switching in is refused when nothing is mounted.
sbm, calls = load_module({ enabled = true, mod_path = "M/", exists = all_present })
check(sbm.UndergroundDarkness.EnsureShadersActive() == false and calls.reload == 0, "no switch without a mount")

-- 5. Missing shipped source: nothing mounted, vanilla strength everywhere.
sbm, calls = load_module({ enabled = true, mod_path = "M/", exists = function(p) return not p:find("ApplyReflections", 1, true) end })
sbm.UndergroundDarkness.ApplyModBehavior()
check(not sbm.UndergroundDarkness.Mounted() and #calls.mounts == 0, "must not mount with a shipped source missing")
check(tostring(sbm.State.underground_darkness_mount_reason):find("ApplyReflections.fx", 1, true), "reason must name the missing file")
check(sbm.UndergroundDarkness.RevealStrength(nil, true) == 90, "unmounted module must fall back to vanilla strength")

-- 5b. Without FuncResolver (and no direct MountFolder) nothing mounts and the reason says so.
do
	local sbm2 = load_module({ enabled = true, mod_path = "M/", exists = all_present, no_resolver = true })
	sbm2.UndergroundDarkness.ApplyModBehavior()
	check(not sbm2.UndergroundDarkness.Mounted() and sbm2.State.underground_darkness_mount_reason == "MountFolder unavailable",
		"missing resolver must report MountFolder unavailable")
end

-- 5c. Another game build (updated shader cache) must not mount, and must say why.
do
	local sbm3 = load_module({ enabled = true, mod_path = "M/", exists = all_present, lua_revision = 405907 + 1 })
	sbm3.UndergroundDarkness.ApplyModBehavior()
	check(not sbm3.UndergroundDarkness.Mounted(), "a different game build must not mount")
	check(tostring(sbm3.State.underground_darkness_mount_reason):find("differs from the shader cache build", 1, true), "reason must name the build mismatch")
	check(sbm3.UndergroundDarkness.RevealStrength(nil, true) == 90, "build mismatch must fall back to vanilla strength")
	local sbm4 = load_module({ enabled = true, mod_path = "M/", exists = all_present, assets_revision = 1 })
	sbm4.UndergroundDarkness.ApplyModBehavior()
	check(not sbm4.UndergroundDarkness.Mounted(), "a different assets build must not mount")
end

-- 6. Mount error and disabled configuration both fall back.
sbm = load_module({ enabled = true, mod_path = "M/", exists = all_present, mount_error = "no such folder" })
sbm.UndergroundDarkness.ApplyModBehavior()
check(not sbm.UndergroundDarkness.Mounted() and sbm.UndergroundDarkness.RevealStrength(nil, true) == 90, "mount error must fall back")
sbm, calls = load_module({ enabled = false, mod_path = "M/", exists = all_present })
sbm.UndergroundDarkness.ApplyModBehavior()
check(#calls.mounts == 0 and sbm.UndergroundDarkness.RevealStrength(nil, true) == 90, "disabled configuration must not mount")

-- 7. Wiring: lifecycle phases, the mod-unload hook, the switch before each underground strength.
local lifecycle = read("Code/sbm_lifecycle.lua")
local apply = lifecycle:match("local APPLY_ORDER = (%b{})")
local restore = lifecycle:match("local RESTORE_ORDER = (%b{})")
check(apply and apply:find('"UndergroundDarkness"', 1, true), "the expanded-session apply phase must mount")
check(restore and restore:find('"UndergroundDarkness"', 1, true), "the vanilla restore phase must unmount")
check(restore:find('"UndergroundDarkness"', 1, true) < restore:find('"HeatSafety"', 1, true), "restore must run in reverse order")
check(lifecycle:find('RegisterOnce("ModUnloadLua"', 1, true) and lifecycle:find('darkness.Unmount, "mod unloaded"', 1, true),
	"unloading the mod must unmount")
check(lifecycle:find("darkness.RevealStrength(map, IsModMap(map))", 1, true), "lifecycle darkness state must use RevealStrength")
check(lifecycle:find("SafeCall(darkness.EnsureShadersActive)", 1, true), "lifecycle must switch the shaders in before the underground strength")
local generation = read("Code/sbm_map_generation.lua")
check(generation:find("darkness.RevealStrength(map, is_mod_map)", 1, true), "EnsureVanillaDarknessReady must use RevealStrength")
check(generation:find("pcall(darkness.EnsureShadersActive)", 1, true), "EnsureVanillaDarknessReady must switch the shaders in")
check(not generation:find('local expected = environment == "Underground" and 90 or 0', 1, true), "hard-coded strength 90 must be gone")
local module = read("Code/sbm_underground_darkness.lua")
check(not module:find("\ndo\n\tlocal ok, why = Darkness.Mount()", 1, true), "the module must not mount at load")
local config = read("Code/sbm_config.lua")
check(config:find("config.UndergroundCompleteDarkness = true", 1, true), "complete darkness must default on")
check(config:find("C.UNDERGROUND_COMPLETE_DARKNESS = as_bool(config.UndergroundCompleteDarkness)", 1, true), "config key missing")
local metadata = read("metadata.lua")
local pos_dark = metadata:find("Code/sbm_underground_darkness.lua", 1, true)
local pos_life = metadata:find("Code/sbm_lifecycle.lua", 1, true)
check(pos_dark and pos_life and pos_dark < pos_life, "darkness module must load before the lifecycle")
print("underground darkness module: " .. checks .. " checks passed")

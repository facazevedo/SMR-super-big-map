-- Complete underground darkness: the module mounts the shipped shader sources and cache-bypass
-- entries over the game's paths, reports the complete strength only for mounted mod maps, and
-- the two darkness enforcement points consult it.
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end

local function read(path)
	local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s
end

-- Load the module against a stub engine environment.
local function load_module(opts)
	local calls = { mounts = {}, reload = 0 }
	local labels = {}
	-- The sandbox hides MountFolder from direct lookup; the module must reach it through the
	-- engine's FuncResolver helper, so the stub exposes it only there.
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
	globals.MountsByLabel = function(label) return labels[label] or 0 end
	for k, v in pairs({
		ReloadShaders = function() calls.reload = calls.reload + 1 end,
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

-- 1. Normal mount: both folders, seethrough with priority, strength 100 for mod maps only.
local sbm, calls = load_module({ enabled = true, mod_path = "AppData/Mods/super-big-map/", exists = all_present })
local D = sbm.UndergroundDarkness
check(D.Mounted(), "module did not mount: " .. tostring(sbm.State.underground_darkness_mount_reason))
check(#calls.mounts == 2, "expected two mounts, got " .. #calls.mounts)
check(calls.mounts[1].target == "Shaders" and calls.mounts[1].source == "AppData/Mods/super-big-map/Shaders/", "shader source mount wrong")
check(calls.mounts[2].target == "ShaderCache" and calls.mounts[2].source == "AppData/Mods/super-big-map/ShaderCache/", "cache bypass mount wrong")
for _, m in ipairs(calls.mounts) do
	check(m.flags:find("seethrough", 1, true) and m.flags:find("priority:high", 1, true), "mount must be seethrough with priority: " .. m.flags)
end
check(D.RevealStrength(nil, true) == 100, "mod underground must use strength 100")
check(D.RevealStrength(nil, false) == 90, "vanilla underground must keep strength 90")
check(calls.reload == 0, "no shader reload without a current map")

-- 2. Mounting mid-session reloads shaders once; a second Mount is a no-op.
sbm, calls = load_module({ enabled = true, mod_path = "M/", exists = all_present, current_map = {} })
check(calls.reload == 1, "mid-session mount must reload shaders once")
local ok, why = sbm.UndergroundDarkness.Mount()
check(ok and why == "already mounted" and #calls.mounts == 2, "second mount must be a no-op")

-- 3. Missing shipped source: nothing mounted, vanilla strength everywhere.
sbm, calls = load_module({ enabled = true, mod_path = "M/", exists = function(p) return not p:find("ApplyReflections", 1, true) end })
check(not sbm.UndergroundDarkness.Mounted() and #calls.mounts == 0, "must not mount with a shipped source missing")
check(tostring(sbm.State.underground_darkness_mount_reason):find("ApplyReflections.fx", 1, true), "reason must name the missing file")
check(sbm.UndergroundDarkness.RevealStrength(nil, true) == 90, "unmounted module must fall back to vanilla strength")

-- 3b. Without FuncResolver (and no direct MountFolder) nothing mounts and the reason says so.
do
	local sbm2 = load_module({ enabled = true, mod_path = "M/", exists = all_present, no_resolver = true })
	check(not sbm2.UndergroundDarkness.Mounted() and sbm2.State.underground_darkness_mount_reason == "MountFolder unavailable",
		"missing resolver must report MountFolder unavailable")
end

-- 3c. Another game build (updated shader cache) must not mount, and must say why.
do
	local sbm3 = load_module({ enabled = true, mod_path = "M/", exists = all_present, lua_revision = 405907 + 1 })
	check(not sbm3.UndergroundDarkness.Mounted(), "a different game build must not mount")
	check(tostring(sbm3.State.underground_darkness_mount_reason):find("differs from the shader cache build", 1, true), "reason must name the build mismatch")
	check(sbm3.UndergroundDarkness.RevealStrength(nil, true) == 90, "build mismatch must fall back to vanilla strength")
	local sbm4 = load_module({ enabled = true, mod_path = "M/", exists = all_present, assets_revision = 1 })
	check(not sbm4.UndergroundDarkness.Mounted(), "a different assets build must not mount")
end

-- 4. Mount error and disabled configuration both fall back.
sbm = load_module({ enabled = true, mod_path = "M/", exists = all_present, mount_error = "no such folder" })
check(not sbm.UndergroundDarkness.Mounted() and sbm.UndergroundDarkness.RevealStrength(nil, true) == 90, "mount error must fall back")
sbm, calls = load_module({ enabled = false, mod_path = "M/", exists = all_present })
check(#calls.mounts == 0 and sbm.UndergroundDarkness.RevealStrength(nil, true) == 90, "disabled configuration must not mount")

-- 5. The enforcement points consult the module; the config flag defaults on.
local lifecycle = read("Code/sbm_lifecycle.lua")
check(lifecycle:find("darkness.RevealStrength(map, IsModMap(map))", 1, true), "lifecycle darkness state must use RevealStrength")
local generation = read("Code/sbm_map_generation.lua")
check(generation:find("darkness.RevealStrength(map, is_mod_map)", 1, true), "EnsureVanillaDarknessReady must use RevealStrength")
check(not generation:find('local expected = environment == "Underground" and 90 or 0', 1, true), "hard-coded strength 90 must be gone")
local config = read("Code/sbm_config.lua")
check(config:find("config.UndergroundCompleteDarkness = true", 1, true), "complete darkness must default on")
check(config:find("C.UNDERGROUND_COMPLETE_DARKNESS = as_bool(config.UndergroundCompleteDarkness)", 1, true), "config key missing")
local metadata = read("metadata.lua")
local pos_dark = metadata:find("Code/sbm_underground_darkness.lua", 1, true)
local pos_life = metadata:find("Code/sbm_lifecycle.lua", 1, true)
check(pos_dark and pos_life and pos_dark < pos_life, "darkness module must load before the lifecycle")
print("underground darkness module: " .. checks .. " checks passed")

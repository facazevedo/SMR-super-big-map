-- Super Big Map -- complete underground darkness on expanded maps.
--
-- Vanilla paints its underground darkness at strength 90 (hr.EnableDarknessReveal), so 10% of
-- the lit cave shows through and the unexplored passages stay faintly readable. At strength 100
-- the darkness pass writes exact black, but the screen-space reflection composite runs AFTER it
-- and adds the environment glint of the cave walls on top, so unexplored walls still show.
--
-- The composite cannot know which pixels the darkness covered: it reads only the blurred
-- reflection map, the material buffers and the depth copy, and the reveal spheres are bound to
-- the darkness pass alone. The reflection map itself is the one per-pixel channel written after
-- the darkness pass, so the mod ships four shader sources (Shaders/) that carry the information
-- through it without changing any explored pixel:
--   * Reflections.fx        stores a pixel's vanilla reflection scaled by 2^14 when the scene
--                           color at that pixel is exactly black (fully covered by darkness);
--                           the scale is exact in the r11g11b10 storage format;
--   * ReflectionDenoising.fx and ReflectionConvolution.fx decode the scale before they blend
--                           neighbours, so every blurred mip an explored pixel samples is the
--                           vanilla value bit for bit, and re-encode a marked pixel's own entry;
--   * ApplyReflections.fx   discards a pixel whose own unblurred entry is marked and decodes
--                           the four texels of any sampling that touches level 0.
-- Measured at 49N28E: unexplored pixels 0/255 in every channel; explored pixels differ from
-- the same run at strength 90 by 0.05/255 on average, the darkness change itself.
--
-- Scope. The renderer builds these reflection programs once, at the first 3D frame of the process
-- (the colony-site globe), and never reloads them: ReloadShaders, ReloadShader, an asset reload
-- (ForceReloadBinAssets + LoadBinAssets) and switching variants all left them in place (measured
-- 2026-09-27), and LoadAllShaders only retries the D3DCopyDSV programs into a fatal assert. So the
-- sources are mounted when the mod loads, before any map is shown, and stay in use for the process.
-- Every stage is gated on one per-frame constant instead (SbmReflectionMark.fh): hr.MeshDebugParam2,
-- which no game shader reads and which is 0 everywhere else. The flag and strength 100 are set
-- together only while an expanded underground is current; a vanilla session, the surface, the main
-- menu and an unloaded mod (ModUnloadLua) keep the flag off, where every stage runs its vanilla code
-- path (no mark, no decode, the game's own hardware filtering) at the game's own strength.
--
-- The compiled-shader cache (ShaderCache/<hash>) is keyed by shader name and defines, never by
-- source, so the mod also ships zero-byte files under the 47 cache entries of these shaders.
-- Mounted over the pack, they make the cache load fail for exactly those entries and the engine
-- compiles them from the mounted sources (shipped config hr.EnableShaderCompilation = 1); every
-- other shader still comes from the cache. The engine mounts a mod's own BinAssets/Materials
-- over the game's the same way. Nothing in the game install is modified.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall

SuperBigMap.State = SuperBigMap.State or {}

local Darkness = {}
SuperBigMap.UndergroundDarkness = Darkness

Darkness.VERSION = 1
Darkness.VANILLA_STRENGTH = 90
Darkness.COMPLETE_STRENGTH = 100
Darkness.SHADER_LABEL = "SuperBigMapShaders"
Darkness.CACHE_LABEL = "SuperBigMapShaderCache"
-- Must equal SBM_MARK_FLAG in Shaders/SbmReflectionMark.fh ("SBM1").
Darkness.MARK_FLAG = 1396853041
-- Every shipped source must be present, or the reflection chain would decode marks it never
-- receives (harmless) or, worse, mark entries nothing decodes.
Darkness.SHADER_FILES = {
	"SbmReflectionMark.fh", "Reflections.fx", "ReflectionDenoising.fx",
	"ReflectionConvolution.fx", "ApplyReflections.fx",
}

local function cfg_bool(key, default)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "boolean" then return value end
	return default
end

function Darkness.Enabled()
	return cfg_bool("UNDERGROUND_COMPLETE_DARKNESS", true)
end

-- The bypass entries name the compiled-cache files of one exact game build. A game update
-- changes them, and then the shipped sources would never be compiled while the module still
-- reported itself mounted. Mount only for the build the entries were taken from; on any other
-- build the module stays off and the underground keeps vanilla's strength.
function Darkness.GameBuildMatches()
	local config = SuperBigMap.Config or {}
	local want_lua, want_assets = config.UNDERGROUND_COMPLETE_DARKNESS_LUA_REVISION,
		config.UNDERGROUND_COMPLETE_DARKNESS_ASSETS_REVISION
	if type(want_lua) ~= "number" or type(want_assets) ~= "number" then return false, "no known game build" end
	local lua, assets = Global("LuaRevision"), Global("AssetsRevision")
	if lua ~= want_lua or assets ~= want_assets then
		return false, "game build " .. tostring(lua) .. "/" .. tostring(assets)
			.. " differs from the shader cache build " .. want_lua .. "/" .. want_assets
	end
	return true
end

-- The reveal strength an underground map gets: complete for a mod map when the mounted programs
-- are in use, else vanilla's. Strength 100 without the reflection marks would still show the wall
-- glints, so ApplyForMap only reports it once the mark flag is confirmed on.
function Darkness.RevealStrength(map, is_mod_map)
	if Darkness.Enabled() and is_mod_map == true and Darkness.Active() then
		return Darkness.COMPLETE_STRENGTH
	end
	return Darkness.VANILLA_STRENGTH
end

function Darkness.Mounted()
	local State = SuperBigMap.State or {}
	return State.underground_darkness_mounted == true
end

-- True when the mount preceded every map of this process, so the renderer built the reflection
-- programs from the mounted sources.
function Darkness.Active()
	local State = SuperBigMap.State or {}
	return State.underground_darkness_mounted == true and State.underground_darkness_programs_from_mount == true
end

-- A map already loaded means the renderer may have built the reflection programs from the game's
-- cache; they would stay in use until the game restarts.
function Darkness.MapAlreadyLoaded()
	local maps = Global("LoadedMaps")
	if type(maps) == "table" and next(maps) ~= nil then return true end
	local current = Global("CurrentMap")
	return current ~= nil and current ~= false and current ~= ""
end

-- The mod sandbox blacklists MountFolder (and debug/io/load). The owner ruled on 2026-09-27 that
-- this mod may reach it anyway, knowingly: the engine's own FuncResolver(name) helper, which the
-- sandbox leaves exposed, returns a global function by name from the real environment. Used only
-- for the two mounts of the mod's own folders declared in this file.
local function real_global_function(name)
	local value = Global(name)
	if type(value) == "function" then return value end
	local resolver = Global("FuncResolver")
	if type(resolver) ~= "function" then return nil end
	local ok, getter = pcall(resolver, name)
	if not ok or type(getter) ~= "function" then return nil end
	local ok_get, fn = pcall(getter, {})
	if ok_get and type(fn) == "function" then return fn end
	return nil
end
Darkness.RealGlobalFunction = real_global_function

local function count_mounts(label)
	local mounts_by_label = real_global_function("MountsByLabel")
	if type(mounts_by_label) ~= "function" then return nil end
	local ok, count = pcall(mounts_by_label, label)
	if ok and type(count) == "number" then return count end
	return nil
end

-- Mount the shipped shader sources over the game's shader path and the cache-bypass entries over
-- the compiled-shader cache. Both are seethrough: only the shipped files take precedence.
-- Returns true when both mounts are in place, else false and the reason.
function Darkness.Mount()
	local State = SuperBigMap.State
	if not State then return false, "state unavailable" end
	if State.underground_darkness_mounted == true then return true, "already mounted" end
	if not Darkness.Enabled() then return false, "disabled by configuration" end
	local build_ok, build_why = Darkness.GameBuildMatches()
	if not build_ok then return false, build_why end
	-- The bypass entries name the PC Direct3D 12 cache; other platforms compile nothing at runtime.
	local platform, config = Global("Platform"), Global("config")
	if type(platform) == "table" and platform.pc ~= true then return false, "not the PC build" end
	if type(config) == "table" and config.GraphicsApi ~= nil and config.GraphicsApi ~= "d3d12" then
		return false, "graphics API " .. tostring(config.GraphicsApi) .. " is not d3d12"
	end
	local hr = Global("hr")
	if type(hr) ~= "table" or type(hr.MeshDebugParam2) ~= "number" then
		return false, "hr.MeshDebugParam2 unavailable"
	end
	local mod_path = rawget(_G, "CurrentModPath")
	if type(mod_path) ~= "string" or mod_path == "" then
		return false, "mod content path unavailable"
	end
	local mount_folder = real_global_function("MountFolder")
	if type(mount_folder) ~= "function" then return false, "MountFolder unavailable" end
	-- io is sandboxed for mods; the check runs where it is available (tests, harness).
	local io_exists = type(io) == "table" and io.exists
	if type(io_exists) == "function" then
		for _, name in ipairs(Darkness.SHADER_FILES) do
			local ok, exists = pcall(io_exists, mod_path .. "Shaders/" .. name)
			if not ok or exists ~= true then
				return false, "shipped shader source missing: " .. name
			end
		end
	end
	if (count_mounts(Darkness.SHADER_LABEL) or 0) == 0 then
		local ok, err = pcall(mount_folder, "Shaders", mod_path .. "Shaders/",
			"priority:high,seethrough,label:" .. Darkness.SHADER_LABEL)
		if not ok or err then
			return false, "shader source mount failed: " .. tostring(ok and err or err)
		end
	end
	if (count_mounts(Darkness.CACHE_LABEL) or 0) == 0 then
		local ok, err = pcall(mount_folder, "ShaderCache", mod_path .. "ShaderCache/",
			"priority:high,seethrough,label:" .. Darkness.CACHE_LABEL)
		if not ok or err then
			return false, "shader cache bypass mount failed: " .. tostring(ok and err or err)
		end
	end
	State.underground_darkness_mounted = true
	return true, "mounted"
end

-- Switch the reflection marks on or off. On requires programs built from the mounted sources and a
-- free hr.MeshDebugParam2 (0); it is confirmed by reading the value back. Off restores 0.
-- Returns true when the requested state holds.
function Darkness.SetMarking(on)
	local State = SuperBigMap.State or {}
	local hr = Global("hr")
	if type(hr) ~= "table" or type(hr.MeshDebugParam2) ~= "number" then
		State.underground_darkness_marking = false
		return on ~= true
	end
	if on == true and Darkness.Enabled() and Darkness.Active() then
		if hr.MeshDebugParam2 ~= Darkness.MARK_FLAG then
			if hr.MeshDebugParam2 ~= 0 then
				State.underground_darkness_marking = false
				State.underground_darkness_marking_reason = "hr.MeshDebugParam2 in use: " .. tostring(hr.MeshDebugParam2)
				return false
			end
			hr.MeshDebugParam2 = Darkness.MARK_FLAG
		end
		State.underground_darkness_marking = hr.MeshDebugParam2 == Darkness.MARK_FLAG
		State.underground_darkness_marking_reason = State.underground_darkness_marking and "on"
			or "hr.MeshDebugParam2 did not keep the flag"
		return State.underground_darkness_marking
	end
	if hr.MeshDebugParam2 == Darkness.MARK_FLAG then hr.MeshDebugParam2 = 0 end
	State.underground_darkness_marking = false
	State.underground_darkness_marking_reason = "off"
	return on ~= true
end

-- The darkness for the map now current: the complete strength with the marks on for an expanded
-- underground, else the vanilla strength with the marks off. Every map switch goes through here.
function Darkness.ApplyForMap(map, environment, is_mod_map)
	if environment == "Underground" and is_mod_map == true
		and Darkness.RevealStrength(map, true) == Darkness.COMPLETE_STRENGTH then
		if Darkness.SetMarking(true) == true then return Darkness.COMPLETE_STRENGTH end
		-- Refused: keep vanilla's strength and say why, once per reason.
		local State = SuperBigMap.State or {}
		local reason = State.underground_darkness_marking_reason
		Darkness.SetMarking(false)
		State.underground_darkness_marking_reason = reason
		if State.underground_darkness_refusal_printed ~= reason
			and (SuperBigMap.Config or {}).DEBUG_LOGGING_ENABLED == true then
			State.underground_darkness_refusal_printed = reason
			local print_fn = Global("print")
			if type(print_fn) == "function" then
				print_fn("[SuperBigMap] underground darkness stays at vanilla strength: " .. tostring(reason))
			end
		end
		return Darkness.VANILLA_STRENGTH
	end
	Darkness.SetMarking(false)
	return Darkness.VANILLA_STRENGTH
end

-- Remove both mounts and switch the marks off. The programs the renderer built stay in memory
-- until the game restarts; with the flag off they run their vanilla code paths.
function Darkness.Unmount(reason)
	local State = SuperBigMap.State or {}
	Darkness.SetMarking(false)
	local unmount = real_global_function("UnmountByLabel")
	local removed = 0
	for _, label in ipairs({ Darkness.SHADER_LABEL, Darkness.CACHE_LABEL }) do
		if (count_mounts(label) or 0) > 0 and type(unmount) == "function" then
			if pcall(unmount, label) then removed = removed + 1 end
		end
	end
	State.underground_darkness_mounted = false
	State.underground_darkness_programs_from_mount = false
	State.underground_darkness_mount_reason = "unmounted: " .. tostring(reason or "mod unloaded")
	return removed
end

-- Lifecycle phases. The mount belongs to the process (see Scope above); a session only owns the
-- mark flag, which the lifecycle's darkness step sets per map through ApplyForMap.
function Darkness.ApplyModBehavior()
	return Darkness.Active()
end

function Darkness.RestoreVanillaBehavior()
	Darkness.SetMarking(false)
	return true
end

-- Test hook: the mounted state is process-wide, so tests that run on a fresh State can query it.
function Darkness.Status()
	return {
		enabled = Darkness.Enabled(), mounted = Darkness.Mounted(), active = Darkness.Active(),
		marking = (SuperBigMap.State or {}).underground_darkness_marking == true,
		shader_mounts = count_mounts(Darkness.SHADER_LABEL),
		cache_mounts = count_mounts(Darkness.CACHE_LABEL),
		reveal_strength_mod = Darkness.RevealStrength(nil, true),
		reveal_strength_vanilla = Darkness.RevealStrength(nil, false),
	}
end

-- Mount now, before any map is shown, so the renderer builds the reflection programs from the
-- shipped sources. A re-executed module keeps the process's mount and its verdict.
do
	local State = SuperBigMap.State
	if State.underground_darkness_mounted ~= true then
		local map_loaded = Darkness.MapAlreadyLoaded()
		local ok, why = Darkness.Mount()
		State.underground_darkness_programs_from_mount = ok and not map_loaded
		if ok and map_loaded then
			why = "mounted after a map was shown; complete darkness needs a game restart"
		end
		State.underground_darkness_mount_reason = why
		local print_fn = (SuperBigMap.Config or {}).DEBUG_LOGGING_ENABLED == true and Global("print")
		if type(print_fn) == "function" then
			print_fn("[SuperBigMap] underground darkness shaders " .. (ok and "mounted" or "not mounted")
				.. ": " .. tostring(why))
		end
	end
end

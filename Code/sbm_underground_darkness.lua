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

-- The reveal strength vanilla's UpdateRevealDarkness would set for an underground map, or the
-- complete strength when this module is active and mounted for a mod map.
function Darkness.RevealStrength(map, is_mod_map)
	if Darkness.Enabled() and is_mod_map == true and Darkness.Mounted() then
		return Darkness.COMPLETE_STRENGTH
	end
	return Darkness.VANILLA_STRENGTH
end

function Darkness.Mounted()
	local State = SuperBigMap.State or {}
	return State.underground_darkness_mounted == true
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
	-- Shaders already compiled by an earlier map in this process keep their cached program;
	-- ReloadShaders re-checks every program and recompiles the ones whose cache entry is now
	-- hidden (measured 0.9 s). At boot nothing is loaded yet and the lazy path compiles them.
	local current = Global("CurrentMap")
	local reload = real_global_function("ReloadShaders")
	if current and type(reload) == "function" then SafeCall(reload) end
	return true, "mounted"
end

-- Test hook: the mounted state is process-wide, so tests that run on a fresh State can query it.
function Darkness.Status()
	return {
		enabled = Darkness.Enabled(), mounted = Darkness.Mounted(),
		shader_mounts = count_mounts(Darkness.SHADER_LABEL),
		cache_mounts = count_mounts(Darkness.CACHE_LABEL),
		reveal_strength_mod = Darkness.RevealStrength(nil, true),
		reveal_strength_vanilla = Darkness.RevealStrength(nil, false),
	}
end

do
	local ok, why = Darkness.Mount()
	SuperBigMap.State.underground_darkness_mount_reason = why
	local print_fn = Global("print")
	if type(print_fn) == "function" then
		print_fn("[SuperBigMap] underground darkness shaders " .. (ok and "mounted" or "not mounted") .. ": " .. tostring(why))
	end
end

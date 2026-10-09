-- Narrow adapters for verified legacy callers. These work on expanded and
-- ordinary saves; they do not enable SBM's map-generation/gameplay changes.
local SBM = rawget(_G, "SuperBigMap")
local Compat, State, Engine = SBM.ModCompat, SBM.State, SBM.Engine
local Global = Engine.Global
local state = State.legacy_mod_compat or {}
State.legacy_mod_compat = state

local function Loaded(id, version)
	for _, mod in ipairs(Global("ModsLoaded") or {}) do
		if mod.id == id and (not version or mod.version == version) then return mod end
	end
end

-- sandbox rawget falls through to native globals; pairs sees only own fields.
local function Own(env, key)
	for k, value in pairs(env) do if k == key then return value end end
end

local function RestoreMars()
	local saved = state.mars
	if not saved then return end
	for key, wrapper in pairs(saved.wrappers) do
		if Own(saved.env, key) == wrapper then rawset(saved.env, key, saved.originals[key]) end
	end
	state.mars = nil
end

local function ApplyMars()
	local mod = Loaded("AKQWwUW", 55)
	local env = mod and mod.env
	local saved = state.mars
	if saved and saved.env == env and Own(env, "MapGet") == saved.wrappers.MapGet
		and Own(env, "IsValid") == saved.wrappers.IsValid then return end
	RestoreMars()
	-- Never supersede an engine API, an author's update, or another adapter.
	if not env or rawget(env, "MapGet") ~= nil then return end
	local valid, current_thread = rawget(env, "IsValid"), Global("CurrentThread")
	if type(valid) ~= "function" or type(current_thread) ~= "function" then return end
	local contexts = setmetatable({}, {__mode = "k"})
	local main_thread = {}
	local function Key() return current_thread() or main_thread end
	local wrappers = {}
	-- v55 NorseName.lua.lua:205 and :227 both call IsValid(bld) immediately
	-- before MapGet(bld:GetPos(), radius, classes...). Remember that exact
	-- owner per coroutine, consuming it once. No CurrentMap/MainMap fallback:
	-- paired elevators can initialize on a map the player is not viewing.
	wrappers.IsValid = function(obj, ...)
		local result = valid(obj, ...)
		contexts[Key()] = result and type(obj) == "table" and type(obj.GetMap) == "function" and obj or nil
		return result
	end
	wrappers.MapGet = function(pos, radius, ...)
		local key = Key()
		local obj = contexts[key]
		contexts[key] = nil
		if not obj or not valid(obj) or obj:GetPos() ~= pos then
			error("SBM: Mars Expedition v55 MapGet requires its validated building", 2)
		end
		local map = obj:GetMap()
		if not map or type(map.MapGet) ~= "function" then return {} end
		local result, seen = {}, {}
		local classes = Global("g_Classes") or {}
		-- Separate native class queries implement the old union, and skip the
		-- retired UndergroundElevator class. Do not pass it as a filter string.
		for i = 1, select("#", ...) do
			local class = select(i, ...)
			if classes[class] then
				for _, candidate in ipairs(map:MapGet(pos, radius, class)) do
					if not seen[candidate] then
						seen[candidate] = true
						result[#result + 1] = candidate
					end
				end
			end
		end
		return result
	end
	state.mars = {env = env, wrappers = wrappers,
		originals = {IsValid = Own(env, "IsValid"), MapGet = Own(env, "MapGet")}}
	for key, wrapper in pairs(wrappers) do rawset(env, key, wrapper) end
end

local function ApplyOmega()
	local mod = Loaded("JFHbPn6", 37)
	if not mod or type(mod.env) ~= "table" then return end
	-- These are the author's transient counters, reset by NewGame/LoadGame.
	-- Declare them in that mod's environment only; no new game-wide globals,
	-- no resets of live values, and no change to its breakthrough logic.
	for _, name in ipairs({"OmegaTelescopeActiveandPowered", "ChanceForBreakthroughSequenceToActivate"}) do
		if Own(mod.env, name) == nil then rawset(mod.env, name, rawget(mod.env, name) or 0) end
	end
end

local function RestoreSaveList()
	local saved = state.save_list
	if not saved then return end
	saved.active = false
	if Global("Untranslated") == saved.wrapper then Untranslated = saved.base end
	for meta, hook in pairs(saved.concat) do
		if meta.__concat == hook.wrapper then meta.__concat = hook.base end
	end
	state.save_list = nil
end

local function ApplySaveList()
	local platform = Global("Platform") or {}
	if not (platform.debug or platform.developer) then return end
	-- Coexist during migration; the standalone fix is removed after verification.
	if Loaded("LocalSaveListFix") then return end
	local untranslated, tag = Global("Untranslated"), Global("TLookupTag")
	local t_meta, concat_meta = Global("TMeta"), Global("TConcatMeta")
	if type(untranslated) ~= "function" or type(tag) ~= "function"
		or type(t_meta) ~= "table" or type(concat_meta) ~= "table" then return end
	local saved = state.save_list
	if not saved then
		saved = {active = true, tags = setmetatable({}, {__mode = "k"}), concat = {}}
		state.save_list = saved
	end
	if untranslated ~= saved.wrapper then
		saved.base = untranslated
		saved.wrapper = function(value)
			if saved.active and value == "<nbsp>..." then
				local value_tag = tag(value)
				saved.tags[value_tag] = true
				return value_tag
			end
			return untranslated(value)
		end
		Untranslated = saved.wrapper
	end
	for _, meta in ipairs({t_meta, concat_meta}) do
		local prior = saved.concat[meta]
		if not prior or meta.__concat ~= prior.wrapper then
			local base = meta.__concat
			local wrapper = function(left, right)
				if saved.active and type(left) == "string" and type(right) == "table" and saved.tags[right] then
					left = saved.base(left)
				end
				return base(left, right)
			end
			saved.concat[meta] = {base = base, wrapper = wrapper}
			meta.__concat = wrapper
		end
	end
end

function Compat.ApplyLegacyCompatibility()
	ApplyOmega()
	ApplyMars()
	ApplySaveList()
end

function Compat.RestoreLegacyCompatibility()
	RestoreMars()
	RestoreSaveList()
	-- Omega counters belong to its running game: never erase their values.
end

-- Native Lua reload recreates the message registry but preserves mod state.
local epoch = Global("GetStaticMsgNames")
if state.message_epoch ~= epoch or not state.messages_registered then
	state.message_epoch, state.messages_registered = epoch, true
	for _, msg in ipairs({"ModsReloaded", "LoadGame", "NewGame", "ClassesBuilt"}) do
		Engine.ChainOnMsg(msg, function() SBM.ModCompat.ApplyLegacyCompatibility() end)
	end
	Engine.ChainOnMsg("ModUnloadLua", function(id)
		if id == "SuperBigMap" then SBM.ModCompat.RestoreLegacyCompatibility()
		elseif id == "AKQWwUW" then RestoreMars() end
	end)
end
Compat.ApplyLegacyCompatibility()

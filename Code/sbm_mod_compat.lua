-- Super Big Map -- compatibility shims for other mods' mistakes, applied from SBM only.
--
-- ProductionOverUnder (sSK4LjU) replaces InfobarObj.GetResourceText and returns
-- T{"<resource_text> <arrow>", arrow = "<color 255 0 0>v</color>"}: the arrow is a plain Lua
-- string inside a translated text. Debug and developer builds (MarsDebug.exe) assert on that
-- ("Attempt to use plain text or numbers '<color 100 0 0>v</color>' as a localized string",
-- CommonLua/Core/localization.lua) every time the infobar refreshes; release builds skip the check
-- and show the same text. Owner 2026-10-04: make SBM compatible without modifying the other mod.
-- In those builds only, the texts InfobarObj:GetResourceText returns pass plain-string parameters
-- as Untranslated(), which renders exactly the same.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end
local Engine = SuperBigMap.Engine or {}
local Global = Engine.Global or function(name) return rawget(_G, name) end
local State = SuperBigMap.State or {}
SuperBigMap.State = State

local ModCompat = {}

local function DevBuild()
	local platform = Global("Platform")
	return type(platform) == "table" and (platform.debug or platform.developer) and true or false
end

-- Returns value unchanged unless it is a T table with plain-string parameters; then a copy with
-- those parameters wrapped in Untranslated().
function ModCompat.UntranslatedParams(value)
	local t_meta, untranslated = Global("TMeta"), Global("Untranslated")
	if type(value) ~= "table" or getmetatable(value) ~= t_meta or type(untranslated) ~= "function" then
		return value
	end
	-- Named parameters only; underscore keys (such as _language) are the string's own data.
	local function is_plain(key, param)
		return type(key) == "string" and key:sub(1, 1) ~= "_" and type(param) == "string"
	end
	local plain = false
	for key, param in pairs(value) do
		if is_plain(key, param) then plain = true break end
	end
	if not plain then return value end
	-- Localized strings may not be modified (TMeta.__newindex asserts): build the copy, then tag it.
	local copy = {}
	for key, param in pairs(value) do
		copy[key] = is_plain(key, param) and untranslated(param) or param
	end
	return setmetatable(copy, t_meta)
end

-- The infobar re-translates its resource texts on every refresh through
-- InfobarObj:GetResourceText(res), so the parameters are fixed where that text is produced. Other
-- mods replace the method in their own OnMsg.ClassesBuilt (ProductionOverUnder rawsets it), and
-- message order between mods is not fixed: wrap whatever method is current, again after all
-- ClassesBuilt handlers and on every game start, and re-wrap if another mod replaced the wrapper.
function ModCompat.ApplyModBehavior()
	if not DevBuild() then return false end
	local infobar = Global("InfobarObj")
	if type(infobar) ~= "table" or type(infobar.GetResourceText) ~= "function" then return false end
	local saved = State.mod_compat_resource_text
	local current = infobar.GetResourceText
	if saved and current == saved.wrapper then return true end
	local wrapper = function(self, ...)
		return ModCompat.UntranslatedParams(current(self, ...))
	end
	rawset(infobar, "GetResourceText", wrapper)
	State.mod_compat_resource_text = { wrapped = current, wrapper = wrapper }
	return true
end

function ModCompat.RestoreVanillaBehavior()
	local saved = State.mod_compat_resource_text
	local infobar = Global("InfobarObj")
	if saved and type(infobar) == "table" and infobar.GetResourceText == saved.wrapper then
		rawset(infobar, "GetResourceText", saved.wrapped)
	end
	State.mod_compat_resource_text = nil
end

SuperBigMap.ModCompat = ModCompat

if Engine.ChainOnMsg then
	Engine.ChainOnMsg("ClassesBuilt", function()
		ModCompat.ApplyModBehavior()
		-- Run once more after the remaining ClassesBuilt handlers (other mods) have finished.
		local thread = Global("CreateRealTimeThread")
		if type(thread) == "function" then thread(function() ModCompat.ApplyModBehavior() end) end
	end)
	for _, msg in ipairs({ "LoadGame", "NewMapLoaded" }) do
		Engine.ChainOnMsg(msg, function() ModCompat.ApplyModBehavior() end)
	end
end
ModCompat.ApplyModBehavior()

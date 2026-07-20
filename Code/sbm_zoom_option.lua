-- Super Big Map -- "Max Zoom Level" in-game option (Options / Display).
--
-- Adds a slider to the vanilla Options / Display menu that controls how far the
-- camera can zoom out. The value is PER-SAVEGAME: it is stored with storage =
-- "session", which the engine keeps in GameVar("g_SessionOptions") -- a table
-- serialized into the savegame and restored on load (confirmed in the local game
-- files: CommonLua/OptionsObject.lua L13 declares the GameVar; MergeOptionsFromTables
-- L253 reads session values; SaveToTables L280 writes them). So each save remembers
-- its own max zoom, a new game starts at the default, and the setting never leaks to
-- other games/scenarios -- exactly the requested scope.
--
-- The base game itself appends to OptionsObject.properties from Lua (OptionsObject.lua
-- L142-146 adds the "Limit UI Aspect Ratio" option that way), so this module appends
-- the slider the same supported way. The control matches the existing Display sliders
-- (UIScale/Brightness: editor = "number", slider = true; L135-138).
--
-- The value is a PERCENT of vanilla max zoom: 100% = exactly vanilla (ZoomPlus off),
-- up to 1200%. It drives the camera through the mod's ZoomPlus far-zoom override
-- (sbm_zoomplus_integration). The lifecycle installs both only for a game explicitly
-- started with EXPAND MAP, so vanilla sessions never gain this property or camera patch.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end
local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall

local OPTION_ID = "SuperBigMapMaxZoom"

local function cfg()
	return SuperBigMap.Config or {}
end

local function Enabled()
	return cfg().ENABLE_MAX_ZOOM_OPTION ~= false
end

local function ExpansionSessionActive()
	local lifecycle = SuperBigMap.Lifecycle
	return lifecycle and type(lifecycle.IsActive) == "function"
		and SafeCall(lifecycle.IsActive) == true
end

local function DefaultPercent()
	local v = cfg().MAX_ZOOM_OPTION_DEFAULT_PERCENT
	return (type(v) == "number" and v >= 100) and math.floor(v) or 900
end

local function MinPercent()
	local v = cfg().MAX_ZOOM_OPTION_MIN_PERCENT
	return (type(v) == "number" and v >= 100) and math.floor(v) or 100
end

local function MaxPercent()
	local v = cfg().MAX_ZOOM_OPTION_MAX_PERCENT
	return (type(v) == "number" and v > MinPercent()) and math.floor(v) or 1200
end

local function StepPercent()
	local v = cfg().MAX_ZOOM_OPTION_STEP_PERCENT
	return (type(v) == "number" and v > 0) and math.floor(v) or 25
end

local ZoomOption = {}

function ZoomOption.IsInstalled()
	local opt = Global("OptionsObject")
	if type(opt) ~= "table" or type(opt.properties) ~= "table" then return false end
	for i = 1, #opt.properties do
		local property = opt.properties[i]
		if type(property) == "table" and property.id == OPTION_ID then return true end
	end
	return false
end

ZoomOption.OPTION_ID = OPTION_ID

-- The per-save percent from g_SessionOptions (serialized in the savegame), clamped to
-- the slider range. Falls back to the default when unset (new game / not yet changed).
function ZoomOption.GetPercent()
	local def = DefaultPercent()
	local g = Global("g_SessionOptions")
	local v = type(g) == "table" and g[OPTION_ID] or nil
	if type(v) ~= "number" then
		return def
	end
	local lo, hi = MinPercent(), MaxPercent()
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

-- Camera far-zoom multiplier (>= 1.0). 100% -> 1.0 (vanilla; ZoomPlus stays off).
function ZoomOption.GetMultiplier()
	return ZoomOption.GetPercent() / 100
end

local function as_text(s)
	local Untranslated = Global("Untranslated")
	return (type(Untranslated) == "function") and Untranslated(s) or s
end

-- Rollover help text, with the CURRENT value baked in so the right-side rollover box
-- shows where the bar is. Re-evaluated live as the slider moves (see the rollover
-- watcher below), so the number tracks the drag in real time.
function ZoomOption.BuildHelpText(pct)
	pct = (type(pct) == "number") and math.floor(pct + 0.5) or DefaultPercent()
	return as_text(string.format(
		"Current zoom level: %d%%\n\nDefault Zoom Level (10x10 grid): %d%%\n\nRecommended Zoom level for a 20x20 grid: %d%%\n\nZoom settings are saved separately for each savegame.",
		pct, MinPercent(), DefaultPercent()))
end

-- Append the slider to the in-game Options / Display list. Idempotent (skips if an
-- option with this id is already present, e.g. after a mod hot-reload).
function ZoomOption.AppendOption()
	if not Enabled() then return false end
	local opt = Global("OptionsObject")
	if type(opt) ~= "table" or type(opt.properties) ~= "table" then
		return false
	end
	for i = 1, #opt.properties do
		local p = opt.properties[i]
		if type(p) == "table" and p.id == OPTION_ID then
			return true -- already added
		end
	end

	local Untranslated = Global("Untranslated")
	local function label(text)
		return (type(Untranslated) == "function") and Untranslated(text) or text
	end

	opt.properties[#opt.properties + 1] = {
		name = label("Max Zoom Level"),
		id = OPTION_ID,
		category = "Display",
		storage = "session",          -- per-savegame (GameVar g_SessionOptions), NOT global
		editor = "number",
		slider = true,
		min = MinPercent(),
		max = MaxPercent(),
		step = StepPercent(),
		snap_offset = StepPercent(),
		default = DefaultPercent(),
		SortKey = 5000,               -- after the stock Display options
		-- Per-save setting: only meaningful inside a game, so hide it with no game loaded
		-- (the same guard the engine uses for in-game game-rule options).
		no_edit = function() return not rawget(_G, "Game") end,
		-- A FUNCTION so SetupOptionRollover (prop_eval) bakes the CURRENT value into the
		-- rollover each time it builds; the watcher below keeps it live during a drag.
		help_text = function(_option, options_obj)
			local pct
			if options_obj and type(options_obj.GetProperty) == "function" then
				local ok, v = pcall(options_obj.GetProperty, options_obj, OPTION_ID)
				if ok and type(v) == "number" then pct = v end
			end
			return ZoomOption.BuildHelpText(pct)
		end,
	}
	return true
end

-- Re-apply the saved zoom to the live camera via the ZoomPlus integration (which now
-- reads ZoomOption.GetMultiplier()). Safe to call any time; no-op without a camera.
function ZoomOption.Apply()
	if not Enabled() or not ExpansionSessionActive() then return end
	local zi = SuperBigMap.ZoomPlusIntegration
	if zi and type(zi.ApplyNormalZoom) == "function" then
		SafeCall(zi.ApplyNormalZoom)
	end
end

function ZoomOption.ApplyModBehavior()
	ZoomOption.AppendOption()
end

function ZoomOption.RestoreVanillaBehavior()
	local opt = Global("OptionsObject")
	if type(opt) ~= "table" or type(opt.properties) ~= "table" then return end
	for i = #opt.properties, 1, -1 do
		local p = opt.properties[i]
		if type(p) == "table" and p.id == OPTION_ID then
			table.remove(opt.properties, i)
		end
	end
end

-- ---------------------------------------------------------------------------------------
-- Live rollover value: keep the right-side rollover box showing the CURRENT slider value
-- while the user drags. SetupOptionRollover bakes the value in once when the rollover is
-- built; this watcher re-sets the control's rollover text and refreshes the open rollover
-- (MarsRollover idContent:OnContextUpdate re-reads control:GetRolloverText) as the bound
-- value changes -- updated in place, no flicker. Triggered by the engine's
-- "CreateRolloverWindow" message so it only runs while OUR row's rollover is open.
-- ---------------------------------------------------------------------------------------

-- Is this the rollover control for the Max Zoom Level option row?
local function IsZoomRolloverControl(control)
	if type(control) ~= "table" or type(control.GetContext) ~= "function" then
		return false
	end
	local ok, ctx = pcall(control.GetContext, control)
	if not ok or type(ctx) ~= "table" then return false end
	local pm = ctx.prop_meta
	return type(pm) == "table" and pm.id == OPTION_ID
end

-- The value currently bound to the row (the live drag value, before Apply): read from the
-- row's property object, falling back to the edited OptionsObj, then the saved value.
local function LiveEditedPercent(control)
	local resolve = Global("ResolvePropObj")
	local obj
	if type(resolve) == "function" and type(control.GetContext) == "function" then
		local ok, ctx = pcall(control.GetContext, control)
		if ok and ctx then
			local ok2, o = pcall(resolve, ctx)
			if ok2 then obj = o end
		end
	end
	obj = obj or Global("OptionsObj")
	if obj and type(obj.GetProperty) == "function" then
		local ok, v = pcall(obj.GetProperty, obj, OPTION_ID)
		if ok and type(v) == "number" then return v end
	end
	return ZoomOption.GetPercent()
end

function ZoomOption.StartRolloverWatcher(win, control)
	if not Enabled() or not ExpansionSessionActive() or not IsZoomRolloverControl(control) then return end
	local create_thread = Global("CreateRealTimeThread")
	local sleep = Global("Sleep")
	if type(create_thread) ~= "function" or type(sleep) ~= "function" then return end
	create_thread(function()
		local last
		local update_rollover = Global("XUpdateRolloverWindow")
		while true do
			-- Stop as soon as this rollover is no longer the active one (mouse left the row).
			if Global("RolloverWin") ~= win or Global("RolloverControl") ~= control then break end
			if type(win) ~= "table" or win.window_state == "destroying" then break end
			local pct = LiveEditedPercent(control)
			if pct ~= last then
				last = pct
				if type(control.SetRolloverText) == "function" then
					pcall(control.SetRolloverText, control, ZoomOption.BuildHelpText(pct))
				end
				if type(update_rollover) == "function" then
					pcall(update_rollover, win)
				end
			end
			sleep(50)
		end
	end)
end

SuperBigMap.ZoomOption = ZoomOption

-- Message observers stay registered so an expanded session can apply its per-save value, but
-- they delegate to the live module and are strictly session-gated. They never add the option;
-- only Lifecycle.Enable -> ApplyModBehavior does that after EXPAND MAP is committed.
local State = SuperBigMap.State or {}
SuperBigMap.State = State
if State.zoom_option_messages_registered ~= true then
	State.zoom_option_messages_registered = true
	Engine.ChainOnMsg("OptionsApply", function()
		local live = SuperBigMap.ZoomOption
		if live and type(live.Apply) == "function" then live.Apply() end
	end)
	Engine.ChainOnMsg("LoadGame", function()
		local live = SuperBigMap.ZoomOption
		if live and type(live.Apply) == "function" then live.Apply() end
	end)
	Engine.ChainOnMsg("CreateRolloverWindow", function(win, control)
		local live = SuperBigMap.ZoomOption
		if live and type(live.StartRolloverWatcher) == "function" then
			live.StartRolloverWatcher(win, control)
		end
	end)
end

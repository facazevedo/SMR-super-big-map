-- Super Big Map -- pre-game opt-in toggle for the stretch-only expansion.
--
-- Adds an EXPAND MAP toggle to the colony-site action bar and exposes the
-- session flag used by map generation. The visual toggle alone does not stretch
-- preview/random maps; pressing START arms the selected value for the real map
-- generation that follows. ON selects the sole 20x20 stretch pipeline; OFF leaves
-- the new game completely vanilla-sized.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine or {}
local Global = Engine.Global or function(name) return rawget(_G, name) end
local SafeCall = Engine.SafeCall or function(fn, ...)
	local ok, a, b, c, d = pcall(fn, ...)
	if ok then return a, b, c, d end
	return nil
end
local Unpack = Engine.Unpack or unpack

local State = SuperBigMap.State or {}
SuperBigMap.State = State

State.pregame_expand_selected = false
State.pregame_expand_start_armed = false

local function BoxText(b)
	if not b then
		return "nil"
	end
	if type(b.minx) == "function" and type(b.miny) == "function"
		and type(b.maxx) == "function" and type(b.maxy) == "function" then
		return string.format("%s,%s,%s,%s", tostring(b:minx()), tostring(b:miny()), tostring(b:maxx()), tostring(b:maxy()))
	end
	return tostring(b)
end

local function SetCurrentParamsArmed(value)
	local params = Global("g_CurrentMapParams")
	if type(params) == "table" then
		params.SuperBigMapExpandMap = value == true or nil
	end
end

local function SetSelected(value, source)
	State.pregame_expand_selected = value == true
	if not State.pregame_expand_selected then
		State.pregame_expand_start_armed = false
		SetCurrentParamsArmed(false)
	end
	return State.pregame_expand_selected
end

local function SetStartArmed(value, source)
	State.pregame_expand_start_armed = value == true
	SetCurrentParamsArmed(State.pregame_expand_start_armed)
	return State.pregame_expand_start_armed
end

local function IsSelected()
	return State.pregame_expand_selected == true
end

-- The new-game flow RELOADS Lua between the landing screen and generation, wiping
-- SuperBigMap.State -- including the armed EXPAND flag -- so Generate could run UNEXPANDED
-- before stretch allocation can be prepared. g_CurrentMapParams is deliberately NOT a GlobalVar ("they have
-- to persist between PreGame and in-game" -- PreGameMission.lua:314) so it SURVIVES that reload,
-- and SetStartArmed already mirrors the flag into it (SetCurrentParamsArmed). Read it back:
-- ShouldExpandNewMap falls back to the params flag, and module load restores State from it.
local function ParamsArmed()
	local params = Global("g_CurrentMapParams")
	return type(params) == "table" and params.SuperBigMapExpandMap == true
end

local function ShouldExpandNewMap()
	return State.pregame_expand_start_armed == true or ParamsArmed()
end

-- Post-reload restore: re-hydrate the wiped State from the surviving params flag so the
-- selection/armed state (and the UI underline) stay consistent after the new-game Lua reload.
if ParamsArmed() and State.pregame_expand_start_armed ~= true then
	State.pregame_expand_selected = true
	State.pregame_expand_start_armed = true
end

local function IsModMap(map)
	local grid = SuperBigMap.SectorGrid
	if grid and type(grid.IsModMap) == "function" then
		local ok, res = pcall(grid.IsModMap, map)
		return ok and res == true
	end
	return false
end

local ApplyExpandUnderline

local function ShouldUseModZoom(map)
	return IsModMap(map or Global("CurrentMap"))
end

local function ResetForVanillaSession(source, dialog)
	SetSelected(false, source or "vanilla_session_reset")
	SetStartArmed(false, source or "vanilla_session_reset")
	if dialog then
		ApplyExpandUnderline(dialog)
	end
end

local function ExpandActionName()
	return "EXPAND MAP"
end

local function UpdateExpandActionLabel(action)
	if action then
		action.ActionName = ExpandActionName()
	end
	return action
end

local function ActionById(host, id)
	if not host then return nil end
	if type(host.ActionById) == "function" then
		local ok, action = pcall(host.ActionById, host, id)
		if ok and action then return action end
	end
	if type(host.GetActions) == "function" then
		local ok, actions = pcall(host.GetActions, host)
		if ok and type(actions) == "table" then
			for i = 1, #actions do
				if actions[i] and actions[i].ActionId == id then
					return actions[i]
				end
			end
		end
	end
	return nil
end

local function UpdateDialogExpandActionLabel(dialog)
	return UpdateExpandActionLabel(ActionById(dialog, "super_big_map_expand"))
end

local function ResolveExpandButton(dialog)
	local action_bar = dialog and dialog.idActionBar
	local toolbar = action_bar and action_bar.idToolBar
	local resolve = toolbar and toolbar.ResolveId
	if type(resolve) == "function" then
		local ok, button = pcall(resolve, toolbar, "idsuper_big_map_expand")
		if ok and button then
			local sig = "toolbar|" .. BoxText(button.box) .. "|"
				.. tostring(button.measure_width) .. "|" .. tostring(button.measure_height)
			if State.pregame_expand_resolve_sig ~= sig then
				State.pregame_expand_resolve_sig = sig
			end
			return button
		end
	end
	resolve = dialog and dialog.ResolveId
	if type(resolve) == "function" then
		local ok, button = pcall(resolve, dialog, "idsuper_big_map_expand")
		if ok and button then
			local sig = "dialog|" .. BoxText(button.box) .. "|"
				.. tostring(button.measure_width) .. "|" .. tostring(button.measure_height)
			if State.pregame_expand_resolve_sig ~= sig then
				State.pregame_expand_resolve_sig = sig
			end
			return button
		end
	end
	if State.pregame_expand_resolve_sig ~= "missing" then
		State.pregame_expand_resolve_sig = "missing"
	end
	return false
end

local function ExpandBarColor()
	local rgba = Global("RGBA")
	if type(rgba) == "function" then
		-- The UI renderer displays this one channel brighter, matching target #DCC6A0 in-game.
		return rgba(219, 197, 159, 255)
	end
	return 4292879835
end

local function IsAlive(win)
	return win and win.window_state ~= "destroying"
end

local function ExpandBarState(dialog)
	local info = State.pregame_expand_bar
	if type(info) ~= "table" or info.dialog ~= dialog then
		info = {
			dialog = dialog,
			holder = false,
			track = false,
			fill = false,
		}
		State.pregame_expand_bar = info
	end
	return info
end

-- Anchor the selection bar to the live action button rather than fixed screen coordinates.
-- Other landing-screen mods can rebuild and resize the toolbar at any time, moving EXPAND MAP.
local EXPAND_BAR_HEIGHT = 8
local EXPAND_BAR_BOTTOM_INSET = 10

local function PositionExpandBar(dialog, bar, button)
	button = button or ResolveExpandButton(dialog)
	if not button or type(bar) ~= "table" or not IsAlive(bar.holder)
		or not IsAlive(bar.track) or not IsAlive(bar.fill) then
		return false
	end
	local box = button.box
	if not box or type(box.minx) ~= "function" or type(box.maxy) ~= "function"
		or type(box.sizex) ~= "function" or type(bar.holder.SetBox) ~= "function" then
		return false
	end
	local allocated_width = math.max(1, box:sizex())
	local measured_width = tonumber(button.measure_width)
	local length = measured_width and measured_width > 0
		and math.min(allocated_width, measured_width) or allocated_width
	length = math.max(1, length)
	-- Center the same intrinsic-width bar under EXPAND MAP whether Filter Landing Spots is
	-- installed or not; only the button's live screen position is allowed to change.
	local x = box:minx() + math.floor((allocated_width - length) / 2)
	local y = box:maxy() - EXPAND_BAR_BOTTOM_INSET
	State.pregame_underline_x = x
	State.pregame_underline_y = y
	State.pregame_underline_length = length
	SafeCall(bar.holder.SetBox, bar.holder, x, y - EXPAND_BAR_BOTTOM_INSET,
		length, EXPAND_BAR_HEIGHT + EXPAND_BAR_BOTTOM_INSET * 2, "dont-move")
	SafeCall(bar.track.SetBox, bar.track, x, y, length, EXPAND_BAR_HEIGHT, "dont-move")
	SafeCall(bar.fill.SetBox, bar.fill, x, y, length, EXPAND_BAR_HEIGHT, "dont-move")
	local geometry_sig = table.concat({ BoxText(box), tostring(x), tostring(y), tostring(length) }, "|")
	if State.pregame_expand_bar_geometry_sig ~= geometry_sig then
		State.pregame_expand_bar_geometry_sig = geometry_sig
	end
	return button
end

local function DeleteOldUnderline(dialog)
	local resolve = dialog and dialog.ResolveId
	if type(resolve) ~= "function" then return end
	local ok, old = pcall(resolve, dialog, "idSuperBigMapUnderline")
	if ok and old and type(old.delete) == "function" then
		SafeCall(old.delete, old)
	end
end

local function EnsureExpandBar(dialog, button)
	local info = ExpandBarState(dialog)
	if IsAlive(info.holder) and IsAlive(info.track) and IsAlive(info.fill) then
		return info
	end
	local XWindow = Global("XWindow")
	if type(XWindow) ~= "table" or not dialog then
		return false
	end
	DeleteOldUnderline(dialog)
	local holder = XWindow:new({
		Id = "idSuperBigMapExpandBar",
		Dock = "ignore",
		HAlign = "none",
		VAlign = "none",
		ZOrder = 100,
		HandleMouse = false,
		DrawOnTop = true,
	}, dialog, dialog.context)
	local track = XWindow:new({
		Dock = "ignore",
		HAlign = "none",
		VAlign = "none",
		Background = ExpandBarColor(),
		HandleMouse = false,
		ZOrder = 0,
	}, holder, dialog.context)
	local fill = XWindow:new({
		Dock = "ignore",
		HAlign = "none",
		VAlign = "none",
		Background = ExpandBarColor(),
		HandleMouse = false,
		ZOrder = 1,
	}, holder, dialog.context)
	info.holder = holder
	info.track = track
	info.fill = fill
	return info
end

-- True while the landing screen is the interactive front, i.e. no modal popup (e.g. the "Custom
-- coordinates" input) is covering it. The underline bar draws on top (DrawOnTop) and is a child
-- of the landing dialog, so without this gate it would float OVER such a popup even though the
-- EXPAND MAP button underneath is covered. Uses the desktop's modal window: if a modal is up and
-- the landing dialog is not within it, the button is covered -> the bar must hide.
local function LandingScreenInteractive(dialog)
	if not IsAlive(dialog) then return false end
	local desktop = dialog.desktop
	if not desktop then
		local terminal = Global("terminal")
		desktop = terminal and terminal.desktop
	end
	if not desktop then return true end
	local modal = (type(desktop.GetModalWindow) == "function" and desktop:GetModalWindow()) or desktop.modal_window
	if not modal or modal == desktop then return true end
	return type(dialog.IsWithin) == "function" and dialog:IsWithin(modal) == true
end

-- Keep the expand-underline bar's visibility synced to (selected AND landing screen interactive)
-- while it exists, so it hides the instant a modal popup (Custom coordinates, etc.) covers the
-- EXPAND MAP button and re-shows when the popup closes. Runs only during the pregame landing
-- screen: it self-terminates once the bar (a child of the landing dialog) is destroyed, and
-- ApplyExpandUnderline restarts it when the bar is recreated. One instance at a time.
local function StartExpandBarWatcher()
	local is_valid = Global("IsValidThread")
	local existing = State.pregame_expand_bar_watcher
	if existing and (type(is_valid) ~= "function" or is_valid(existing)) then
		return
	end
	local create_thread = Global("CreateRealTimeThread")
	local sleep = Global("Sleep")
	if type(create_thread) ~= "function" or type(sleep) ~= "function" then return end
	State.pregame_expand_bar_watcher = create_thread(function()
		while true do
			local info = State.pregame_expand_bar
			if type(info) ~= "table" or not IsAlive(info.holder) then
				break   -- bar gone (left the landing screen); ApplyExpandUnderline restarts it
			end
			PositionExpandBar(info.dialog, info)
			local visible = IsSelected() and LandingScreenInteractive(info.dialog)
			for _, win in ipairs({ info.holder, info.track, info.fill }) do
				if IsAlive(win) and type(win.SetVisible) == "function" then
					SafeCall(win.SetVisible, win, visible)
				end
			end
			sleep(50)
		end
	end)
end

ApplyExpandUnderline = function(dialog)
	local button = ResolveExpandButton(dialog)
	if not button then
		return false
	end
	local color = ExpandBarColor()
	local bar = EnsureExpandBar(dialog, button)
	if not bar then
		return false
	end
	if type(bar.track.SetBackground) == "function" then
		SafeCall(bar.track.SetBackground, bar.track, color)
	else
		bar.track.Background = color
	end
	if type(bar.fill.SetBackground) == "function" then
		SafeCall(bar.fill.SetBackground, bar.fill, color)
	else
		bar.fill.Background = color
	end
	PositionExpandBar(dialog, bar, button)
	local visible = IsSelected() and LandingScreenInteractive(dialog)
	for _, win in ipairs({ bar.holder, bar.track, bar.fill }) do
		if IsAlive(win) then
			if type(win.SetVisible) == "function" then
				SafeCall(win.SetVisible, win, visible)
			else
				win.Visible = visible
			end
		end
	end
	-- Keep it synced while the screen is up (hide over modal popups, re-show on close).
	StartExpandBarWatcher()
	return true
end

local function SetSortKey(action, key)
	if not action then return end
	if type(action.SetActionSortKey) == "function" then
		SafeCall(action.SetActionSortKey, action, key)
	else
		action.ActionSortKey = key
	end
end

local function RememberSortKey(action)
	if action and action.SuperBigMapOriginalActionSortKeyCaptured ~= true then
		action.SuperBigMapOriginalActionSortKeyCaptured = true
		action.SuperBigMapOriginalActionSortKey = action.ActionSortKey
	end
end

-- Keep EXPAND MAP immediately before START in every configuration. Filter Landing Spots uses
-- `fls_filter_landing_spots` at sort key 040; giving EXPAND its own 045 slot preserves both
-- intended layouts:
--   vanilla actions: BACK / CUSTOM / RANDOM / EXPAND MAP / START
--   with Filter:     BACK / CUSTOM / RANDOM / FILTER / EXPAND MAP / START
-- Reapply this when an existing action bar is reused because either mod may rebuild it later.
local function ReorderLandingActions(dialog)
	local back = ActionById(dialog, "back")
	local custom = ActionById(dialog, "custom")
	local random = ActionById(dialog, "random")
	local filter = ActionById(dialog, "fls_filter_landing_spots")
	local start = ActionById(dialog, "start")
	-- Do not use ipairs over optional actions: a missing CUSTOM/FILTER entry would
	-- stop at the first nil and leave later vanilla sort keys unrestorable.
	RememberSortKey(back)
	RememberSortKey(custom)
	RememberSortKey(random)
	RememberSortKey(filter)
	RememberSortKey(start)
	SetSortKey(back, "010")
	SetSortKey(custom, "020")
	SetSortKey(random, "030")
	SetSortKey(filter, "040")
	SetSortKey(ActionById(dialog, "super_big_map_expand"), "045")
	SetSortKey(start, "050")
end

local function RefreshActions(host)
	if not host or type(host.UpdateActionViews) ~= "function" then return end
	SafeCall(host.UpdateActionViews, host, host.idActionBar or host)
	ApplyExpandUnderline(host)
end

local function InstallLandingDialogAction(dialog)
	if not dialog then
		return false
	end
	local XAction = Global("XAction")
	if type(XAction) ~= "table" then
		return false
	end
	State.pregame_toggle_dialogs = State.pregame_toggle_dialogs
		or setmetatable({}, { __mode = "k" })
	State.pregame_toggle_dialogs[dialog] = true
	-- Source of truth is whether our action is ACTUALLY on the dialog, not a sticky
	-- per-dialog flag: the dialog instance can be reused across opens while its action bar
	-- is rebuilt (by the engine or another landing-spot mod, e.g. Filter Landing Spots),
	-- which drops our action but leaves SuperBigMapExpandActionInstalled set -- that was the
	-- "EXPAND MAP button disappeared" case. Re-add whenever it is missing; skip only when it
	-- is genuinely still present.
	local action_present = ActionById(dialog, "super_big_map_expand") ~= nil
	if action_present then
		ReorderLandingActions(dialog)
		RefreshActions(dialog)
		dialog.SuperBigMapExpandActionInstalled = true
		return false
	end

	local back_action = ActionById(dialog, "back")
	if back_action and back_action.SuperBigMapBackWrapped ~= true then
		local original_on_action = back_action.OnAction
		back_action.SuperBigMapBackOriginalOnAction = original_on_action
		back_action.OnAction = function(action, host, source, ...)
			SetSelected(false, "back")
			ApplyExpandUnderline(host or dialog)
			if type(original_on_action) == "function" then
				return original_on_action(action, host, source, ...)
			end
		end
		back_action.SuperBigMapBackWrapped = true
	end

	local start_action = ActionById(dialog, "start")
	if start_action and start_action.SuperBigMapStartWrapped ~= true then
		local original_on_action = start_action.OnAction
		start_action.SuperBigMapStartOriginalOnAction = original_on_action
		start_action.OnAction = function(action, host, source, ...)
			local expand = IsSelected()
			local diagnostics = SuperBigMap.Diagnostics
			local params = Global("g_CurrentMapParams")
			SetStartArmed(expand, "start")
			-- START is the ownership boundary for every gameplay modification. Until this
			-- exact moment only the pregame opt-in control exists; OFF explicitly keeps the
			-- full lifecycle disabled, while ON installs the generation hooks before vanilla
			-- enters NewGame/GenerateRandomMap.
			local lifecycle = SuperBigMap.Lifecycle
			if expand and lifecycle and type(lifecycle.BeginExpandedSession) == "function" then
				SafeCall(lifecycle.BeginExpandedSession, "pregame START with EXPAND MAP")
			elseif lifecycle and type(lifecycle.BeginVanillaSession) == "function" then
				SafeCall(lifecycle.BeginVanillaSession, "pregame START without EXPAND MAP", false)
			end
			-- Resolve the preset from the same inputs and branch used by native
			-- GenerateCurrentRandomMap, after lifecycle setup and immediately before
			-- accepting/submitting the unchanged native START action.
			if type(params) == "table" and params.SuperBigMapRalphProfileEnabled == true then
				if not diagnostics
					or type(diagnostics.RalphProfileResolveCurrentPreset) ~= "function"
					or diagnostics.RalphProfileResolveCurrentPreset() ~= true
					or type(diagnostics.RalphProfileStart) ~= "function"
					or diagnostics.RalphProfileStart({
						expand_selected = expand,
						action_id = action and action.ActionId,
						source = source,
						}) ~= true then
					error("Ralph profile rejected START or preset proof before generation")
					return false
				end
			end
			if type(original_on_action) == "function" then
				return original_on_action(action, host, source, ...)
			end
		end
		start_action.SuperBigMapStartWrapped = true
	end

	XAction:new({
		ActionId = "super_big_map_expand",
		ActionName = ExpandActionName(),
		ActionTranslate = false,
		ActionToolbar = "ActionBar",
		ActionSortKey = "045",
		OnAction = function(action, host)
			SetSelected(not IsSelected(), "toggle")
			UpdateExpandActionLabel(action)
			ApplyExpandUnderline(host or dialog)
		end,
		RolloverText = "Generate this new game as a stretch-expanded 20 x 20 Super Big Map.",
	}, dialog, dialog.context)

	dialog.SuperBigMapExpandActionInstalled = true
	ReorderLandingActions(dialog)
	UpdateDialogExpandActionLabel(dialog)
	RefreshActions(dialog)
	return true
end

local function PatchLandingDialog()
	local cls = Global("PGMissionLandingSpotRemastered")
	if type(cls) ~= "table" or type(cls.Open) ~= "function" then
		return false
	end
	if State.pregame_toggle_open_original and cls.Open == State.pregame_toggle_open_wrapper then
		return true
	end
	if cls.Open ~= State.pregame_toggle_open_wrapper then
		-- Live Open is NOT our wrapper: first install, a ClassesBuilt reset, or another mod
		-- (e.g. Filter Landing Spots) replaced/re-wrapped it. Capture whatever is live as the
		-- original so we chain over it instead of clobbering the other mod.
		State.pregame_toggle_open_original = cls.Open
	end

	local original_open = State.pregame_toggle_open_original
	local wrapper = function(self, ...)
		SetSelected(false, "landing_open")
		SetStartArmed(false, "landing_open")
		local results = { original_open(self, ...) }
		InstallLandingDialogAction(self)
		return Unpack(results)
	end
	cls.Open = wrapper
	State.pregame_toggle_open_wrapper = wrapper
	return true
end

local function RestoreLandingDialog()
	local cls = Global("PGMissionLandingSpotRemastered")
	if type(cls) == "table" and State.pregame_toggle_open_original
		and cls.Open == State.pregame_toggle_open_wrapper then
		cls.Open = State.pregame_toggle_open_original
	end
	for dialog in pairs(State.pregame_toggle_dialogs or {}) do
		local expand_action = ActionById(dialog, "super_big_map_expand")
		if expand_action then
			if type(dialog.RemoveAction) == "function" then
				SafeCall(dialog.RemoveAction, dialog, expand_action)
			end
			if type(expand_action.delete) == "function" then SafeCall(expand_action.delete, expand_action) end
		end
		for _, id in ipairs({ "back", "custom", "random", "fls_filter_landing_spots", "start" }) do
			local action = ActionById(dialog, id)
			if action then
				if id == "back" and action.SuperBigMapBackWrapped == true then
					action.OnAction = action.SuperBigMapBackOriginalOnAction
					action.SuperBigMapBackOriginalOnAction = nil
					action.SuperBigMapBackWrapped = nil
				elseif id == "start" and action.SuperBigMapStartWrapped == true then
					action.OnAction = action.SuperBigMapStartOriginalOnAction
					action.SuperBigMapStartOriginalOnAction = nil
					action.SuperBigMapStartWrapped = nil
				end
				if action.SuperBigMapOriginalActionSortKeyCaptured == true then
					if action.SuperBigMapOriginalActionSortKey == nil then
						action.ActionSortKey = nil
					else
						SetSortKey(action, action.SuperBigMapOriginalActionSortKey)
					end
					action.SuperBigMapOriginalActionSortKey = nil
					action.SuperBigMapOriginalActionSortKeyCaptured = nil
				end
			end
		end
		dialog.SuperBigMapExpandActionInstalled = nil
		if type(dialog.UpdateActionViews) == "function" then
			SafeCall(dialog.UpdateActionViews, dialog, dialog.idActionBar or dialog)
		end
	end
	local bar = State.pregame_expand_bar
	if type(bar) == "table" and bar.holder and type(bar.holder.delete) == "function" then
		SafeCall(bar.holder.delete, bar.holder)
	end
	local watcher = State.pregame_expand_bar_watcher
	local delete_thread = Global("DeleteThread")
	if watcher and type(delete_thread) == "function" then
		SafeCall(delete_thread, watcher)
	end
	State.pregame_expand_bar = nil
	State.pregame_expand_bar_watcher = nil
	State.pregame_expand_bar_geometry_sig = nil
	State.pregame_expand_resolve_sig = nil
	State.pregame_underline_x = nil
	State.pregame_underline_y = nil
	State.pregame_underline_length = nil
	State.pregame_toggle_dialogs = nil
	State.pregame_toggle_open_original = nil
	State.pregame_toggle_open_wrapper = nil
end

local PregameToggle = {
	SetSelected = SetSelected,
	SetStartArmed = SetStartArmed,
	ResetForVanillaSession = ResetForVanillaSession,
	IsSelected = IsSelected,
	ShouldExpandNewMap = ShouldExpandNewMap,
	ShouldUseModZoom = ShouldUseModZoom,
	InstallLandingDialogAction = InstallLandingDialogAction,
	PatchLandingDialog = PatchLandingDialog,
}

function PregameToggle.ApplyModBehavior()
	return PatchLandingDialog()
end

function PregameToggle.RestoreVanillaBehavior()
	RestoreLandingDialog()
	SetSelected(false, "restore")
	SetStartArmed(false, "restore")
end

SuperBigMap.PregameToggle = PregameToggle

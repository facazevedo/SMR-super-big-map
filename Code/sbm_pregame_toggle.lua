-- Super Big Map -- pre-game opt-in toggle.
--
-- Adds an EXPAND MAP toggle to the colony-site action bar and exposes the
-- session flag used by map generation. The visual toggle alone does not expand
-- preview/random maps; pressing START arms the selected value for the real map
-- generation that follows.

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

local function Log(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Lifecycle", message, data)
	end
end

local function ToggleLog(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("PregameToggle", message, data)
	end
end

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
	Log("pregame expand-map selection changed", {
		enabled = State.pregame_expand_selected,
		source = tostring(source or "?"),
	})
	return State.pregame_expand_selected
end

local function SetStartArmed(value, source)
	State.pregame_expand_start_armed = value == true
	SetCurrentParamsArmed(State.pregame_expand_start_armed)
	Log("pregame expand-map start armed", {
		enabled = State.pregame_expand_start_armed,
		source = tostring(source or "?"),
	})
	return State.pregame_expand_start_armed
end

local function IsSelected()
	return State.pregame_expand_selected == true
end

-- The new-game flow RELOADS Lua between the landing screen and generation, wiping
-- SuperBigMap.State -- including the armed EXPAND flag -- so Generate could run UNEXPANDED
-- (v378 crash log: 'expand action clicked selected=true' but no 'frame expansion' prepare and a
-- 'SKIP (fits)' 6144 cap check). g_CurrentMapParams is deliberately NOT a GlobalVar ("they have
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
	Log("pregame expand-map state RESTORED from g_CurrentMapParams (post-reload)", {})
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
		ToggleLog("action label updated", {
			action = tostring(action.ActionId),
			name = tostring(action.ActionName),
		})
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
			ToggleLog("expand button resolved via toolbar", {
				button_box = BoxText(button.box),
				measure_width = tostring(button.measure_width),
				measure_height = tostring(button.measure_height),
			})
			return button
		end
	end
	resolve = dialog and dialog.ResolveId
	if type(resolve) == "function" then
		local ok, button = pcall(resolve, dialog, "idsuper_big_map_expand")
		if ok and button then
			ToggleLog("expand button resolved via dialog", {
				button_box = BoxText(button.box),
				measure_width = tostring(button.measure_width),
				measure_height = tostring(button.measure_height),
			})
			return button
		end
	end
	ToggleLog("expand button not resolved")
	return false
end

local function ResolveStartButton(dialog)
	local action_bar = dialog and dialog.idActionBar
	local toolbar = action_bar and action_bar.idToolBar
	local resolve = toolbar and toolbar.ResolveId
	if type(resolve) == "function" then
		local ok, button = pcall(resolve, toolbar, "idstart")
		if ok and button then
			return button
		end
	end
	resolve = dialog and dialog.ResolveId
	if type(resolve) == "function" then
		local ok, button = pcall(resolve, dialog, "idstart")
		if ok and button then
			return button
		end
	end
	return false
end

local function ActionTextColor(button)
	local label = button and button.idLabel
	if label and type(label.CalcTextColor) == "function" then
		local color = SafeCall(label.CalcTextColor, label)
		if type(color) == "number" then return color end
	end
	if button and type(button.CalcTextColor) == "function" then
		local color = SafeCall(button.CalcTextColor, button)
		if type(color) == "number" then return color end
	end
	local styles = Global("TextStyles")
	local style = type(styles) == "table" and styles.ActionSmall
	if type(style) == "table" and type(style.TextColor) == "number" then
		return style.TextColor
	end
	local const_tbl = Global("const")
	if type(const_tbl) == "table" and type(const_tbl.GameColorA) == "number" then
		return const_tbl.GameColorA
	end
	local rgba = Global("RGBA")
	if type(rgba) == "function" then
		return rgba(255, 238, 200, 255)
	end
	return 4293840584
end

local function ExpandBarColor()
	local rgba = Global("RGBA")
	if type(rgba) == "function" then
		-- The UI renderer displays this one channel brighter, matching target #DCC6A0 in-game.
		return rgba(219, 197, 159, 255)
	end
	return 4292879835
end

local EXPAND_BAR_X = 905
local EXPAND_BAR_Y = 2072
local EXPAND_BAR_LENGTH = 217

local function EnsureUnderlineTuneDefaults(button)
	State.pregame_underline_x = EXPAND_BAR_X
	State.pregame_underline_y = EXPAND_BAR_Y
	State.pregame_underline_length = EXPAND_BAR_LENGTH
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
	ToggleLog("expand bar created", {
		button_box = BoxText(button and button.box),
	})
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
		ToggleLog("underline skipped: button missing", {
			selected = IsSelected(),
		})
		return false
	end
	local color = ExpandBarColor()
	EnsureUnderlineTuneDefaults(button)
	local bar = EnsureExpandBar(dialog, button)
	if not bar then
		ToggleLog("expand bar skipped: missing windows")
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
	if button.box and type(button.box.minx) == "function" and type(button.box.maxy) == "function"
		and type(button.box.sizex) == "function" and type(bar.holder.SetBox) == "function" then
		local line_height = 8
		local x = State.pregame_underline_x or button.box:minx()
		local y = State.pregame_underline_y or button.box:maxy() - 10
		local length = math.max(1, State.pregame_underline_length or button.box:sizex())
		SafeCall(bar.holder.SetBox, bar.holder, x, y - 10, length, line_height + 20, "dont-move")
		SafeCall(bar.track.SetBox, bar.track, x, y, length, line_height, "dont-move")
		SafeCall(bar.fill.SetBox, bar.fill, x, y, length, line_height, "dont-move")
	end
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
	ToggleLog("underline applied", {
		button_box = BoxText(button.box),
		color = tostring(color),
		selected = IsSelected(),
		start_box = BoxText((ResolveStartButton(dialog) or {}).box),
		bar_box = BoxText(bar.holder and bar.holder.box),
		fill_box = BoxText(bar.fill and bar.fill.box),
		tune_x = tostring(State.pregame_underline_x),
		tune_y = tostring(State.pregame_underline_y),
		tune_length = tostring(State.pregame_underline_length),
		visible = tostring(visible),
	})
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

local function RefreshActions(host)
	if not host or type(host.UpdateActionViews) ~= "function" then return end
	ToggleLog("refresh actions", {
		host = tostring(host.class or host.Id or host),
	})
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
	-- Source of truth is whether our action is ACTUALLY on the dialog, not a sticky
	-- per-dialog flag: the dialog instance can be reused across opens while its action bar
	-- is rebuilt (by the engine or another landing-spot mod, e.g. Filter Landing Spots),
	-- which drops our action but leaves SuperBigMapExpandActionInstalled set -- that was the
	-- "EXPAND MAP button disappeared" case. Re-add whenever it is missing; skip only when it
	-- is genuinely still present.
	local action_present = ActionById(dialog, "super_big_map_expand") ~= nil
	if action_present then
		ToggleLog("InstallLandingDialogAction: action already present -- skip", {
			dialog = tostring(dialog.class or dialog.Id or "nil"),
			flag = dialog.SuperBigMapExpandActionInstalled == true,
		})
		dialog.SuperBigMapExpandActionInstalled = true
		return false
	end
	ToggleLog("InstallLandingDialogAction: (re)installing action", {
		dialog = tostring(dialog.class or dialog.Id or "nil"),
		flag_was_set = dialog.SuperBigMapExpandActionInstalled == true,
	})

	SetSortKey(ActionById(dialog, "back"), "010")
	SetSortKey(ActionById(dialog, "custom"), "020")
	SetSortKey(ActionById(dialog, "random"), "030")
	SetSortKey(ActionById(dialog, "start"), "050")

	local back_action = ActionById(dialog, "back")
	if back_action and back_action.SuperBigMapBackWrapped ~= true then
		local original_on_action = back_action.OnAction
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
		start_action.OnAction = function(action, host, source, ...)
			SetStartArmed(IsSelected(), "start")
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
		ActionSortKey = "040",
		OnAction = function(action, host)
			SetSelected(not IsSelected(), "toggle")
			ToggleLog("expand action clicked", {
				host = tostring(host and (host.class or host.Id) or "nil"),
				selected = IsSelected(),
			})
			UpdateExpandActionLabel(action)
			ApplyExpandUnderline(host or dialog)
		end,
		RolloverText = "Generate this new game as a 20 x 20 Super Big Map.",
	}, dialog, dialog.context)

	dialog.SuperBigMapExpandActionInstalled = true
	UpdateDialogExpandActionLabel(dialog)
	RefreshActions(dialog)
	return true
end

-- Diagnostic: is the live PGMissionLandingSpotRemastered.Open our wrapper, the captured
-- original, or a FOREIGN one (another landing-spot mod replaced it after us)?
local function OpenIsOurs()
	local cls = Global("PGMissionLandingSpotRemastered")
	if type(cls) ~= "table" then return "no-class" end
	if type(cls.Open) ~= "function" then return "no-open" end
	if cls.Open == State.pregame_toggle_open_wrapper then return "ours" end
	if cls.Open == State.pregame_toggle_open_original then return "original/vanilla" end
	return "foreign"
end

local function LogOpenState(reason)
	local cls = Global("PGMissionLandingSpotRemastered")
	ToggleLog("Open-state check", {
		reason = tostring(reason or "?"),
		class_present = type(cls) == "table",
		open_is = OpenIsOurs(),
		live_open = tostring((type(cls) == "table") and cls.Open or "nil"),
		our_wrapper = tostring(State.pregame_toggle_open_wrapper or "nil"),
		our_original = tostring(State.pregame_toggle_open_original or "nil"),
	})
end

local function PatchLandingDialog()
	local cls = Global("PGMissionLandingSpotRemastered")
	if type(cls) ~= "table" or type(cls.Open) ~= "function" then
		ToggleLog("PatchLandingDialog: class/Open unavailable", {
			class_present = type(cls) == "table",
		})
		return false
	end
	if State.pregame_toggle_open_original and cls.Open == State.pregame_toggle_open_wrapper then
		ToggleLog("PatchLandingDialog: our Open wrapper already installed (ok)", {
			live_open = tostring(cls.Open),
		})
		return true
	end
	if cls.Open ~= State.pregame_toggle_open_wrapper then
		-- Live Open is NOT our wrapper: first install, a ClassesBuilt reset, or another mod
		-- (e.g. Filter Landing Spots) replaced/re-wrapped it. Capture whatever is live as the
		-- original so we chain over it instead of clobbering the other mod.
		ToggleLog("PatchLandingDialog: (re)wrapping Open -- live method was not ours", {
			open_is = OpenIsOurs(),
			had_prior_wrapper = State.pregame_toggle_open_wrapper ~= nil,
			live_is_prior_original = cls.Open == State.pregame_toggle_open_original,
			live_open = tostring(cls.Open),
			prior_wrapper = tostring(State.pregame_toggle_open_wrapper or "nil"),
		})
		State.pregame_toggle_open_original = cls.Open
	end

	local original_open = State.pregame_toggle_open_original
	local wrapper = function(self, ...)
		ToggleLog("landing dialog Open wrapper ENTER", {
			dialog_instance = tostring(self),
			dialog_class = tostring(self and self.class or "nil"),
		})
		SetSelected(false, "landing_open")
		SetStartArmed(false, "landing_open")
		local results = { original_open(self, ...) }
		InstallLandingDialogAction(self)
		ToggleLog("landing dialog Open wrapper fired (after install)", {
			dialog_instance = tostring(self),
			action_present_after = self and ActionById(self, "super_big_map_expand") ~= nil,
		})
		return Unpack(results)
	end
	cls.Open = wrapper
	State.pregame_toggle_open_wrapper = wrapper
	Log("pregame expand-map toggle patched")
	return true
end

local function RestoreLandingDialog()
	local cls = Global("PGMissionLandingSpotRemastered")
	if type(cls) == "table" and State.pregame_toggle_open_original
		and cls.Open == State.pregame_toggle_open_wrapper then
		cls.Open = State.pregame_toggle_open_original
	end
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
	LogOpenState = LogOpenState,
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

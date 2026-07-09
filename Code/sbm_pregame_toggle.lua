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

local function ShouldExpandNewMap()
	return State.pregame_expand_start_armed == true
end

local function IsModMap(map)
	local grid = SuperBigMap.SectorGrid
	if grid and type(grid.IsModMap) == "function" then
		local ok, res = pcall(grid.IsModMap, map)
		return ok and res == true
	end
	return false
end

local function ShouldUseModZoom(map)
	return IsModMap(map or Global("CurrentMap"))
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

local UpdateExpandButtonVisual

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

local function ActionTextColor(button)
	local const_tbl = Global("const")
	if type(const_tbl) == "table" and type(const_tbl.GameColorA) == "number" then
		return const_tbl.GameColorA
	end
	local styles = Global("TextStyles")
	local style = type(styles) == "table" and styles.ActionSmall
	if type(style) == "table" and type(style.TextColor) == "number" then
		return style.TextColor
	end
	local rgba = Global("RGBA")
	if type(rgba) == "function" then
		return rgba(255, 238, 200, 255)
	end
	return 4293840584
end

local function SetWindowVisible(win, value)
	if not win then return end
	if type(win.SetVisible) == "function" then
		SafeCall(win.SetVisible, win, value == true)
	else
		win.Visible = value == true
	end
end

local function CleanupDialogUnderline(dialog)
	if not dialog then return end
	local underline = dialog.SuperBigMapExpandUnderline
	local resolve = dialog.ResolveId
	if type(resolve) == "function" then
		local ok, child = pcall(resolve, dialog, "idSuperBigMapUnderline")
		if ok and child then underline = child end
	end
	if underline then
		if type(underline.delete) == "function" then
			SafeCall(underline.delete, underline)
		else
			SetWindowVisible(underline, false)
		end
	end
	dialog.SuperBigMapExpandUnderline = nil
end

UpdateExpandButtonVisual = function(button)
	if not button then
		ToggleLog("button visual skipped: button missing", {
			selected = IsSelected(),
		})
		return false
	end
	local underline = button.SuperBigMapUnderline
	if not underline then
		local resolve = button.ResolveId
		if type(resolve) == "function" then
			local ok, child = pcall(resolve, button, "idSuperBigMapUnderline")
			if ok and child then underline = child end
		end
	end
	if not underline then
		ToggleLog("button visual skipped: underline missing", {
			button_box = BoxText(button.box),
			class = tostring(button.class),
		})
		return false
	end
	local color = ActionTextColor(button)
	if type(underline.SetBackground) == "function" then
		SafeCall(underline.SetBackground, underline, color)
	else
		underline.Background = color
	end

	local visible = IsSelected()
	local box = button.box
	local valid_box = box and type(box.minx) == "function" and type(box.maxy) == "function" and type(box.sizex) == "function"
		and box:sizex() > 0
	if valid_box and type(underline.SetBox) == "function" then
		local line_height = 4
		local bottom_gap = 6
		local y = box:maxy() - bottom_gap - line_height
		SafeCall(underline.SetBox, underline, box:minx(), y, box:sizex(), line_height, "dont-move")
	else
		visible = false
	end
	SetWindowVisible(underline, visible)
	ToggleLog("button visual applied", {
		button_box = BoxText(button.box),
		class = tostring(button.class),
		color = tostring(color),
		selected = IsSelected(),
		underline_box = BoxText(underline.box),
		visible = tostring(visible),
	})
	return true
end

local function EnsureExpandButtonClass()
	local cls = Global("SuperBigMapExpandMenuEntry")
	if type(cls) ~= "table" then
		local DefineClass = Global("DefineClass")
		local MenuEntry = Global("MenuEntry")
		if type(DefineClass) ~= "table" or type(MenuEntry) ~= "table" then
			ToggleLog("button class skipped: base unavailable", {
				define_class_type = type(DefineClass),
				menu_entry_type = type(MenuEntry),
			})
			return false
		end
		DefineClass.SuperBigMapExpandMenuEntry = {
			__parents = { "MenuEntry" },
		}
		cls = Global("SuperBigMapExpandMenuEntry")
	end
	if type(cls) ~= "table" then
		ToggleLog("button class skipped: define failed")
		return false
	end

	cls.Init = function(self, parent, context)
		local MenuEntry = Global("MenuEntry")
		if type(MenuEntry) == "table" and type(MenuEntry.Init) == "function" then
			SafeCall(MenuEntry.Init, self, parent, context)
		end
		local XWindow = Global("XWindow")
		if type(XWindow) ~= "table" then
			ToggleLog("underline child skipped: XWindow unavailable", {
				xwindow_type = type(XWindow),
			})
			return
		end
		local underline = XWindow:new({
			Id = "idSuperBigMapUnderline",
			Dock = "ignore",
			HAlign = "none",
			VAlign = "none",
			ZOrder = 100,
			MinHeight = 4,
			MaxHeight = 4,
			HandleMouse = false,
			Background = ActionTextColor(self),
		}, self, context)
		self.SuperBigMapUnderline = underline
		SetWindowVisible(underline, false)
		ToggleLog("underline child created", {
			button_box = BoxText(self.box),
			underline_box = BoxText(underline.box),
		})
	end

	cls.Open = function(self, ...)
		local XTextButton = Global("XTextButton")
		if type(XTextButton) == "table" and type(XTextButton.Open) == "function" then
			SafeCall(XTextButton.Open, self, ...)
		end
		UpdateExpandButtonVisual(self)
	end

	cls.OnLayoutComplete = function(self, ...)
		local MenuEntry = Global("MenuEntry")
		if type(MenuEntry) == "table" and type(MenuEntry.OnLayoutComplete) == "function" then
			SafeCall(MenuEntry.OnLayoutComplete, self, ...)
		end
		UpdateExpandButtonVisual(self)
	end

	cls.OnSetFocus = function(self, ...)
		local MenuEntry = Global("MenuEntry")
		if type(MenuEntry) == "table" and type(MenuEntry.OnSetFocus) == "function" then
			SafeCall(MenuEntry.OnSetFocus, self, ...)
		end
		UpdateExpandButtonVisual(self)
	end

	cls.OnSetRollover = function(self, ...)
		local XTextButton = Global("XTextButton")
		if type(XTextButton) == "table" and type(XTextButton.OnSetRollover) == "function" then
			SafeCall(XTextButton.OnSetRollover, self, ...)
		end
		UpdateExpandButtonVisual(self)
	end

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
	UpdateExpandButtonVisual(ResolveExpandButton(host))
end

local function InstallLandingDialogAction(dialog)
	if not dialog or dialog.SuperBigMapExpandActionInstalled == true then
		return false
	end
	local XAction = Global("XAction")
	if type(XAction) ~= "table" then
		return false
	end
	local expand_button_template = EnsureExpandButtonClass() and "SuperBigMapExpandMenuEntry" or "MenuEntry"
	CleanupDialogUnderline(dialog)

	SetSortKey(ActionById(dialog, "back"), "010")
	SetSortKey(ActionById(dialog, "custom"), "020")
	SetSortKey(ActionById(dialog, "random"), "030")
	SetSortKey(ActionById(dialog, "start"), "050")

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
		ActionButtonTemplate = expand_button_template,
		ActionToolbar = "ActionBar",
		ActionSortKey = "040",
		OnAction = function(action, host, source)
			SetSelected(not IsSelected(), "toggle")
			ToggleLog("expand action clicked", {
				host = tostring(host and (host.class or host.Id) or "nil"),
				source = tostring(source and (source.class or source.Id) or "nil"),
				selected = IsSelected(),
			})
			UpdateExpandActionLabel(action)
			UpdateExpandButtonVisual(source or ResolveExpandButton(host or dialog))
		end,
		RolloverText = "Generate this new game as a 20 x 20 Super Big Map.",
	}, dialog, dialog.context)

	dialog.SuperBigMapExpandActionInstalled = true
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

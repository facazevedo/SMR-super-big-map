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

local function TransparentColor()
	local rgba = Global("RGBA")
	if type(rgba) == "function" then
		return rgba(0, 0, 0, 0)
	end
	return 0
end

local function PanelColor()
	local rgba = Global("RGBA")
	if type(rgba) == "function" then
		return rgba(0, 0, 0, 180)
	end
	return 3019898880
end

local function HoverColor()
	local rgba = Global("RGBA")
	if type(rgba) == "function" then
		return rgba(90, 120, 150, 180)
	end
	return 3025821846
end

local function UiBox(...)
	local box_fn = Global("box")
	if type(box_fn) == "function" then
		return box_fn(...)
	end
	return nil
end

local function IsUnderlineTunerEnabled()
	local config = SuperBigMap.Config
	return type(config) == "table" and config.DEBUG_PREGAMETOGGLE == true
end

local function EnsureUnderlineTuneDefaults(button)
	if not button or not button.box then return end
	if State.pregame_underline_x == nil and type(button.box.minx) == "function" then
		State.pregame_underline_x = button.box:minx()
	end
	if State.pregame_underline_y == nil and type(button.box.maxy) == "function" then
		State.pregame_underline_y = button.box:maxy() - 10
	end
	if State.pregame_underline_length == nil and type(button.box.sizex) == "function" then
		State.pregame_underline_length = button.box:sizex()
	end
end

local ApplyExpandUnderline

local function SetText(ctrl, text)
	if ctrl and type(ctrl.SetText) == "function" then
		SafeCall(ctrl.SetText, ctrl, tostring(text))
	end
end

local function UnderlineTunerState(dialog)
	local info = State.pregame_underline_tuner
	if type(info) ~= "table" or info.dialog ~= dialog then
		info = {
			dialog = dialog,
			window = false,
			labels = {},
		}
		State.pregame_underline_tuner = info
	end
	return info
end

local function UpdateUnderlineTuner(dialog)
	local info = State.pregame_underline_tuner
	if type(info) ~= "table" or info.dialog ~= dialog or type(info.labels) ~= "table" then return end
	SetText(info.labels.x, State.pregame_underline_x or 0)
	SetText(info.labels.y, State.pregame_underline_y or 0)
	SetText(info.labels.length, State.pregame_underline_length or 0)
end

local function AdjustUnderlineValue(dialog, field, delta)
	local button = ResolveExpandButton(dialog)
	EnsureUnderlineTuneDefaults(button)
	if field == "x" then
		State.pregame_underline_x = (State.pregame_underline_x or 0) + delta
	elseif field == "y" then
		State.pregame_underline_y = (State.pregame_underline_y or 0) + delta
	elseif field == "length" then
		State.pregame_underline_length = math.max(1, (State.pregame_underline_length or 1) + delta)
	end
	UpdateUnderlineTuner(dialog)
	if ApplyExpandUnderline then
		ApplyExpandUnderline(dialog)
	end
end

local function NewTextButton(parent, text, on_press)
	local XTextButton = Global("XTextButton")
	if type(XTextButton) ~= "table" then return nil end
	local btn = XTextButton:new({
		Translate = false,
		TextStyle = "ActionSmall",
		MinWidth = 38,
		MinHeight = 30,
		Background = TransparentColor(),
		FocusedBackground = TransparentColor(),
		RolloverBackground = HoverColor(),
		PressedBackground = HoverColor(),
	}, parent, parent and parent.context)
	SetText(btn, text)
	btn.OnPress = function()
		if type(on_press) == "function" then
			on_press()
		end
	end
	return btn
end

local function NewTextLabel(parent, text, min_width)
	local XLabel = Global("XLabel")
	if type(XLabel) ~= "table" then return nil end
	local label = XLabel:new({
		Translate = false,
		TextStyle = "ActionSmall",
		MinWidth = min_width or 0,
		VAlign = "center",
		HAlign = "center",
	}, parent, parent and parent.context)
	SetText(label, text)
	return label
end

local function AddTuneRow(dialog, tuner, labels, field, label_text)
	local XWindow = Global("XWindow")
	if type(XWindow) ~= "table" then return end
	local row = XWindow:new({
		LayoutMethod = "HList",
		LayoutHSpacing = 6,
		HAlign = "center",
		MinHeight = 34,
	}, tuner, tuner.context)
	NewTextLabel(row, label_text, 95)
	NewTextButton(row, "<", function() AdjustUnderlineValue(dialog, field, -1) end)
	local value_label = NewTextLabel(row, "0", 90)
	NewTextButton(row, ">", function() AdjustUnderlineValue(dialog, field, 1) end)
	labels[field] = value_label
end

local function EnsureUnderlineTuner(dialog, button)
	if not IsUnderlineTunerEnabled() or not dialog then return false end
	EnsureUnderlineTuneDefaults(button)
	local info = UnderlineTunerState(dialog)
	if info.window and info.window.window_state ~= "destroying" then
		UpdateUnderlineTuner(dialog)
		return info.window
	end
	local XWindow = Global("XWindow")
	if type(XWindow) ~= "table" then return false end
	local tuner = XWindow:new({
		Id = "idSuperBigMapUnderlineTuner",
		Dock = false,
		HAlign = "center",
		VAlign = "center",
		ZOrder = 200,
		LayoutMethod = "VList",
		LayoutVSpacing = 8,
		MinWidth = 420,
		Padding = UiBox(16, 12, 16, 12),
		Background = PanelColor(),
		BorderWidth = 1,
		BorderColor = ActionTextColor(button),
	}, dialog, dialog.context)
	info.window = tuner
	info.labels = {}
	NewTextLabel(tuner, "EXPAND MAP UNDERLINE", 0)
	AddTuneRow(dialog, tuner, info.labels, "x", "X")
	AddTuneRow(dialog, tuner, info.labels, "y", "Y")
	AddTuneRow(dialog, tuner, info.labels, "length", "LENGTH")
	if type(tuner.Open) == "function" and tuner.window_state == "new" then
		SafeCall(tuner.Open, tuner)
	end
	UpdateUnderlineTuner(dialog)
	ToggleLog("underline tuner created", {
		x = tostring(State.pregame_underline_x),
		y = tostring(State.pregame_underline_y),
		length = tostring(State.pregame_underline_length),
	})
	return tuner
end

ApplyExpandUnderline = function(dialog)
	local button = ResolveExpandButton(dialog)
	if not button then
		ToggleLog("underline skipped: button missing", {
			selected = IsSelected(),
		})
		return false
	end
	local underline = dialog and dialog.SuperBigMapExpandUnderline or false
	local resolve = dialog and dialog.ResolveId
	if type(resolve) == "function" then
		local ok, child = pcall(resolve, dialog, "idSuperBigMapUnderline")
		if ok and child then underline = child end
	end
	if not underline then
		local XWindow = Global("XWindow")
		if type(XWindow) ~= "table" then
			ToggleLog("underline skipped: XWindow unavailable", {
				xwindow_type = type(XWindow),
			})
			return false
		end
		underline = XWindow:new({
			Id = "idSuperBigMapUnderline",
			Dock = false,
			ZOrder = 100,
			MinHeight = 4,
			MaxHeight = 4,
			Background = ActionTextColor(button),
		}, dialog, dialog.context)
		dialog.SuperBigMapExpandUnderline = underline
		ToggleLog("underline created", {
			button_box = BoxText(button.box),
			underline_box = BoxText(underline.box),
			measure_width = tostring(underline.measure_width),
			measure_height = tostring(underline.measure_height),
		})
	end
	local color = ActionTextColor(button)
	EnsureUnderlineTuneDefaults(button)
	EnsureUnderlineTuner(dialog, button)
	if underline.SetBackground then
		SafeCall(underline.SetBackground, underline, color)
	else
		underline.Background = color
	end
	if button.box and type(button.box.minx) == "function" and type(button.box.maxy) == "function"
		and type(button.box.sizex) == "function" and type(underline.SetBox) == "function" then
		local line_height = 4
		local x = State.pregame_underline_x or button.box:minx()
		local y = State.pregame_underline_y or button.box:maxy() - 10
		local length = math.max(1, State.pregame_underline_length or button.box:sizex())
		SafeCall(underline.SetBox, underline, x, y, length, line_height)
	end
	if type(underline.SetVisible) == "function" then
		SafeCall(underline.SetVisible, underline, IsSelected())
	else
		underline.Visible = IsSelected()
	end
	ToggleLog("underline applied", {
		button_box = BoxText(button.box),
		color = tostring(color),
		selected = IsSelected(),
		start_box = BoxText((ResolveStartButton(dialog) or {}).box),
		underline_box = BoxText(underline.box),
		tune_x = tostring(State.pregame_underline_x),
		tune_y = tostring(State.pregame_underline_y),
		tune_length = tostring(State.pregame_underline_length),
		visible = type(underline.GetVisible) == "function" and tostring(underline:GetVisible()) or tostring(underline.Visible),
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
	if not dialog or dialog.SuperBigMapExpandActionInstalled == true then
		return false
	end
	local XAction = Global("XAction")
	if type(XAction) ~= "table" then
		return false
	end

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

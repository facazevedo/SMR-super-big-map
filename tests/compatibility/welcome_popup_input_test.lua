-- The welcome popup that SBM hides during expansion must come back modal and focused, exactly as
-- XDialog:Open left it; otherwise gamepad A (routed through the modal window's keyboard focus)
-- cannot close it (owner report on Xbox, 2026-09-27). Loads the production module against a
-- desktop double that reproduces the engine's modal/focus rules from CommonLua/X.
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end

-- Desktop double: modal log, focus log and the SetVisibleInstant hide rules of the engine.
local desktop = { modal_log = {}, focus_log = {}, modal_window = nil, keyboard_focus = nil }
local function new_window(name, props)
	local w = { name = name, visible = true, window_state = "open", desktop = desktop, children = {} }
	for k, v in pairs(props or {}) do w[k] = v end
	function w:IsWithin(other)
		local cur = self
		while cur do
			if cur == other then return true end
			cur = cur.parent
		end
		return false
	end
	function w:IsVisible() return self.visible and self.window_state ~= "destroying" end
	function w:SetVisibleInstant(v)
		if self.visible == v then return end
		self.visible = v
		if not v then
			if desktop.modal_window and desktop.modal_window:IsWithin(self) then desktop:RestoreModalWindow() end
			if desktop.keyboard_focus and desktop.keyboard_focus:IsWithin(self) then desktop:RestoreFocus() end
		end
	end
	function w:SetModal(set)
		if set == false then return desktop:RemoveModalWindow(self) end
		return desktop:SetModalWindow(self)
	end
	function w:SetFocus() return desktop:SetKeyboardFocus(self) end
	function w:SetFocus_OnOpen(focus) if (focus or self.FocusOnOpen) == "self" then self:SetFocus() end end
	function w:SetZOrder(z) self.z = z end
	function w:Close()
		self.window_state = "destroyed"; self.visible = false
		desktop:RemoveModalWindow(self)
		for i = #desktop.focus_log, 1, -1 do if desktop.focus_log[i] == self then table.remove(desktop.focus_log, i) end end
		if desktop.keyboard_focus == self then desktop:RestoreFocus() end
	end
	return w
end
local root = new_window("desktop")
desktop.root = root
function desktop:RestoreModalWindow()
	local win
	for i = #self.modal_log, 1, -1 do
		local cand = self.modal_log[i]
		if cand:IsVisible() and (not win or (cand.z or 0) >= (win.z or 0)) then win = cand end
	end
	self.modal_window = win or root
	self:RestoreFocus()
end
function desktop:SetModalWindow(win)
	for i = #self.modal_log, 1, -1 do if self.modal_log[i] == win then table.remove(self.modal_log, i) end end
	self.modal_log[#self.modal_log + 1] = win
	if not win:IsVisible() then return end
	if self.modal_window and self.modal_window ~= root and (self.modal_window.z or 0) > (win.z or 0) then return end
	self.modal_window = win
	if self.keyboard_focus and not self.keyboard_focus:IsWithin(win) then self.keyboard_focus = nil end
	self:RestoreFocus()
end
function desktop:RemoveModalWindow(win)
	for i = #self.modal_log, 1, -1 do if self.modal_log[i] == win then table.remove(self.modal_log, i) end end
	if self.modal_window == win then self.modal_window = nil; self:RestoreModalWindow() end
end
function desktop:SetKeyboardFocus(win)
	for i = #self.focus_log, 1, -1 do if self.focus_log[i] == win then table.remove(self.focus_log, i) end end
	self.focus_log[#self.focus_log + 1] = win
	if not win:IsWithin(self.modal_window or root) or not win:IsVisible() then return end
	self.keyboard_focus = win
end
function desktop:RestoreFocus()
	for i = #self.focus_log, 1, -1 do
		local w = self.focus_log[i]
		if w:IsWithin(self.modal_window or root) and w:IsVisible() then self.keyboard_focus = w; return end
	end
	self.keyboard_focus = nil
end
desktop.modal_window = root

-- The HUD owns focus before the popup opens; the popup opens the way XDialog:Open opens it.
local hud = new_window("hud", { parent = root }); hud:SetFocus()
local popup = new_window("PopupNotification", { parent = root, IsModal = true, FocusOnOpen = "self", z = 10,
	context = { id = "WelcomeGameInfo", voiced_text = "Welcome to Mars!" } })
popup:SetModal(popup.IsModal); popup:SetFocus_OnOpen()
check(desktop.modal_window == popup and desktop.keyboard_focus == popup, "fixture: popup must open modal and focused")

local dialogs = { PopupNotification = popup }
local boxes = {}
local globals = {
	GetDialog = function(id) return dialogs[id] end,
	CreateMessageBox = function()
		local box = new_window("MessageBox", { parent = root, IsModal = true, FocusOnOpen = "self", z = 20 })
		box:SetModal(true); box:SetFocus()
		boxes[#boxes + 1] = box
		return box
	end,
	terminal = { desktop = desktop },
	Untranslated = function(s) return s end,
	CreateRealTimeThread = function() end,
	PopupNotificationPresets = {},
	SetPopupNotificationText = function() end,
	PlayVoicedText = function() end,
}
local SuperBigMap = {
	Engine = { Global = function(name) return globals[name] end, SafeCall = function(f, ...) return pcall(f, ...) end },
	State = {},
	Diagnostics = {},
}
local env = setmetatable({ SuperBigMap = SuperBigMap }, { __index = _G })
env._G = env
assert(loadfile("Code/sbm_loading_ui.lua", "t", env))()

-- 1. Expansion loading: the popup is hidden under the loading box, then handed back.
SuperBigMap.ExpansionLoadingBegin("surface")
check(popup.visible == false, "popup must be hidden during expansion")
check(#boxes == 1 and desktop.modal_window == boxes[1], "loading box must be the modal window during expansion")
SuperBigMap.ExpansionLoadingEnd(true)
check(boxes[1].window_state == "destroyed", "loading box must close at the end")
check(popup.visible == true, "popup must be visible again")
check(desktop.modal_window == popup, "re-shown popup must be the modal window again (gamepad input target)")
check(desktop.keyboard_focus == popup, "re-shown popup must hold keyboard focus (gamepad A reaches its Close)")

-- 2. A window genuinely on top keeps its input: re-showing under it must not steal focus.
popup:SetVisibleInstant(false)
local top = new_window("OtherModal", { parent = root, IsModal = true, FocusOnOpen = "self", z = 30 })
top:SetModal(true); top:SetFocus()
SuperBigMap.RestoreDialogInput(popup)
check(desktop.modal_window == top and desktop.keyboard_focus == top, "a higher modal window must keep modality and focus")
top:Close()
popup:SetVisibleInstant(true); SuperBigMap.RestoreDialogInput(popup)
check(desktop.modal_window == popup and desktop.keyboard_focus == popup, "after the higher window closes the popup regains input")

-- 3. Destroyed dialogs are ignored.
popup.window_state = "destroyed"
check(SuperBigMap.RestoreDialogInput(popup) == false, "a destroyed dialog must be ignored")

-- 4. The warning box path (ShowMessageOverWelcome) also restores input.
local src = io.open("Code/sbm_loading_ui.lua", "rb"):read("*a")
check(select(2, src:gsub("RestoreDialogInput%(", "")) >= 3, "both re-show paths must call RestoreDialogInput")
print("welcome popup input: " .. checks .. " checks passed")

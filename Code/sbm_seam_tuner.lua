-- Super Big Map -- TEMPORARY in-game tuner for the seam-blend parameters.
--
-- A DRAGGABLE on-screen panel with one row per SeamBlend parameter: label, "-", an EDITABLE
-- numeric field (type a value; floats show decimals), "+". Footer: Apply / Undo / Reset / Close.
-- Editing a field or pressing -/+ only changes a working copy; Apply writes the values into
-- SuperBigMap.Config and re-runs SeamBlend.Apply (which restores the raw mirrored heights from
-- its snapshot first, so each Apply re-blends from the original -- no compounding). The blend
-- runs on a BACKGROUND real-time thread so the panel stays responsive; while it runs the Apply
-- button reads "Wait..." and re-entry is blocked. Undo steps back through the applied history;
-- Reset restores defaults. All control text is forced WHITE and constant (no hover/press colour
-- change). Gated by Config.SEAM_TUNER_ENABLED; turn OFF once the look is dialled in.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall

local floor = math.floor

local function cfg() return SuperBigMap.Config or {} end

-- key = raw config field (= normalized C key via NORM). int=false -> float (shown with decimals).
local PARAMS = {
	{ key = "SeamBlendHalfWidthTiles",      label = "Half width (tiles)",    default = 12,   step = 1,   min = 1, max = 64,     int = true },
	{ key = "SeamBlendStableSampleTiles",   label = "Stable sample (tiles)", default = 3,    step = 1,   min = 1, max = 20,     int = true },
	{ key = "SeamBlendNoiseOctaves",        label = "Noise octaves",         default = 4,    step = 1,   min = 1, max = 8,      int = true },
	{ key = "SeamBlendNoiseFrequencyTiles", label = "Noise wavelength",      default = 6,    step = 1,   min = 1, max = 40,     int = true },
	{ key = "SeamBlendNoiseAmplitudeScale", label = "Noise amplitude",       default = 0.6,  step = 0.1, min = 0, max = 3,      int = false, decimals = 2 },
	{ key = "SeamBlendSeed",                label = "Seed",                  default = 1337, step = 1,   min = 0, max = 999999, int = true },
}

local NORM = {
	SeamBlendHalfWidthTiles = "SEAM_BLEND_HALF_WIDTH_TILES",
	SeamBlendStableSampleTiles = "SEAM_BLEND_STABLE_SAMPLE_TILES",
	SeamBlendNoiseOctaves = "SEAM_BLEND_NOISE_OCTAVES",
	SeamBlendNoiseFrequencyTiles = "SEAM_BLEND_NOISE_FREQUENCY_TILES",
	SeamBlendNoiseAmplitudeScale = "SEAM_BLEND_NOISE_AMPLITUDE_SCALE",
	SeamBlendSeed = "SEAM_BLEND_SEED",
}

local PANEL_X0, PANEL_Y0 = 24, 120

local panel = false
local edit_fields = {}    -- key -> XEdit
local values = {}
local history = {}        -- stack of applied value-sets (copies); top = currently applied
local applying = false
local drag = nil
local apply_button = false
local undo_button = false
local reset_button = false
local panel_x, panel_y = PANEL_X0, PANEL_Y0

local function PanelValid()
	return panel and panel.window_state ~= "destroying" and panel.window_state ~= "destroyed"
end

local function Color(r, g, b, a)
	local RGBA = Global("RGBA")
	return (type(RGBA) == "function") and RGBA(r, g, b, a) or 0
end
local function White() return Color(236, 236, 238, 255) end

local function Fmt(p, v)
	if p.int then return tostring(floor(v + 0.5)) end
	return string.format("%." .. tostring(p.decimals or 2) .. "f", v)
end

local function Clamp(p, v)
	if v < p.min then v = p.min elseif v > p.max then v = p.max end
	if p.int then return floor(v + 0.5) end
	local d = p.decimals or 2
	local scale = 10 ^ d
	return floor(v * scale + 0.5) / scale
end

local function InitValues()
	local C = cfg()
	for _, p in ipairs(PARAMS) do
		local c = C[NORM[p.key]]
		values[p.key] = Clamp(p, (type(c) == "number") and c or p.default)
	end
end

local function WriteToConfig()
	local C = SuperBigMap.Config
	if type(C) ~= "table" then return end
	for _, p in ipairs(PARAMS) do
		C[NORM[p.key]] = values[p.key]
	end
end

-- Read a field's current text -> clamped number (falls back to the stored value if unparseable).
local function ReadField(p)
	local e = edit_fields[p.key]
	if e and type(e.GetText) == "function" then
		local n = tonumber(e:GetText())
		if n then return Clamp(p, n) end
	end
	return values[p.key]
end

-- Write the canonical formatted value into a field WITHOUT firing OnTextChanged (notify=false).
local function SetFieldText(p)
	local e = edit_fields[p.key]
	if e and type(e.SetText) == "function" then e:SetText(Fmt(p, values[p.key]), false) end
end

local function Adjust(p, dir)
	values[p.key] = Clamp(p, ReadField(p) + dir * p.step)
	SetFieldText(p)
end

local function SetBtnText(btn, txt)
	if btn and btn.window_state ~= "destroyed" and type(btn.SetText) == "function" then
		btn:SetText(txt)
	end
end

-- Run SeamBlend.Apply on a background real-time thread. The TRIGGERING button (Apply/Undo/Reset)
-- shows "Wait..." for the whole duration of the blend, then its normal label is restored. The
-- blend yields cooperatively (see sbm_seam_blend BlendCorridor), so the UI keeps painting --
-- "Wait..." appears as soon as the blend starts and lasts exactly as long as it does (a fast
-- blend shows it only briefly). No artificial delay.
local function RunBlend(btn, idle_text)
	if applying then return end
	local seam = SuperBigMap.SeamBlend
	local map = Global("CurrentMap")
	if not (seam and type(seam.Apply) == "function" and map) then return end
	WriteToConfig()
	local create_thread = Global("CreateRealTimeThread")
	if type(create_thread) ~= "function" then
		SafeCall(seam.Apply, map)
		return
	end
	applying = true
	SetBtnText(btn, "Wait...")
	create_thread(function()
		SafeCall(seam.Apply, map)
		applying = false
		SetBtnText(btn, idle_text)
	end)
end

local function CopyValues()
	local c = {}
	for _, p in ipairs(PARAMS) do c[p.key] = values[p.key] end
	return c
end

local function SetValues(snap)
	if type(snap) ~= "table" then return end
	for _, p in ipairs(PARAMS) do
		if type(snap[p.key]) == "number" then
			values[p.key] = snap[p.key]
			SetFieldText(p)
		end
	end
end

local function PushHistory()
	history[#history + 1] = CopyValues()
end

local function ApplyAction()
	if applying then return end
	for _, p in ipairs(PARAMS) do
		values[p.key] = ReadField(p) -- capture typed values
		SetFieldText(p)              -- canonicalize the display
	end
	PushHistory()
	RunBlend(apply_button, "Apply")
end

local function ResetAction()
	if applying then return end
	for _, p in ipairs(PARAMS) do
		values[p.key] = Clamp(p, p.default)
		SetFieldText(p)
	end
	PushHistory()
	RunBlend(reset_button, "Reset")
end

-- Step back one applied state (clamped at the initial state).
local function UndoAction()
	if applying then return end
	if #history >= 2 then
		table.remove(history)
		SetValues(history[#history])
		RunBlend(undo_button, "Undo")
	end
end

-- Force a control's text WHITE in every state (normal/rollover/disabled), so it never recolours
-- on hover or press. SetTextStyle (run in Init) overrides TextColor, so set it AFTER creation.
local function Whiten(ctrl)
	if not ctrl then return end
	local w = White()
	if type(ctrl.SetTextColor) == "function" then ctrl:SetTextColor(w) end
	if type(ctrl.SetRolloverTextColor) == "function" then ctrl:SetRolloverTextColor(w) end
	if type(ctrl.SetDisabledTextColor) == "function" then ctrl:SetDisabledTextColor(w) end
	if type(ctrl.SetDisabledRolloverTextColor) == "function" then ctrl:SetDisabledRolloverTextColor(w) end
end

local function MakeButton(parent, text, onpress, minw)
	local XTextButton = Global("XTextButton")
	local box = Global("box")
	if type(XTextButton) ~= "table" then return nil end
	local b = XTextButton:new({
		Text = text,
		Translate = false,
		TextStyle = "ConsoleLog",
		Padding = box(8, 2, 8, 2),
		Margins = box(2, 0, 2, 0),
		MinWidth = minw or 34,
		Background = Color(60, 60, 72, 235),
		RolloverBackground = Color(95, 95, 115, 235),
		PressedBackground = Color(70, 70, 86, 235),
		RolloverTextColor = White(),
		DisabledTextColor = White(),
		DisabledRolloverTextColor = White(),
		OnPress = function(_self, _gamepad) SafeCall(onpress) end,
	}, parent)
	Whiten(b)
	return b
end

local function MakeText(parent, text, minw)
	local XText = Global("XText")
	if type(XText) ~= "table" then return nil end
	local t = XText:new({
		Translate = false,
		TextStyle = "ConsoleLog",
		MinWidth = minw,
		RolloverTextColor = White(),
		DisabledTextColor = White(),
		DisabledRolloverTextColor = White(),
	}, parent)
	if t and type(t.SetText) == "function" then t:SetText(text) end
	Whiten(t)
	return t
end

local function MakeEdit(parent, p)
	local XEdit = Global("XEdit")
	local box = Global("box")
	if type(XEdit) ~= "table" then return nil end
	local e = XEdit:new({
		Translate = false,
		TextStyle = "ConsoleLog",
		MinWidth = 72,
		MaxWidth = 72,
		MaxLen = 12,
		Margins = box(2, 0, 2, 0),
		Padding = box(4, 1, 4, 1),
		Background = Color(28, 28, 36, 255),
		FocusedBackground = Color(46, 46, 60, 255),
		RolloverTextColor = White(),
		DisabledTextColor = White(),
		DisabledRolloverTextColor = White(),
		OnTextChanged = function(self)
			local n = tonumber(self:GetText())
			if n then values[p.key] = Clamp(p, n) end
		end,
	}, parent)
	Whiten(e)
	if e and type(e.SetText) == "function" then e:SetText(Fmt(p, values[p.key]), false) end
	return e
end

local function Hide()
	if PanelValid() and type(panel.delete) == "function" then
		pcall(function() panel:delete() end)
	end
	panel = false
	edit_fields = {}
	apply_button = false
	undo_button = false
	reset_button = false
	drag = nil
end

local function Build()
	local desktop = (Global("terminal") or {}).desktop
	local XWindow = Global("XWindow")
	local box = Global("box")
	if not desktop or type(XWindow) ~= "table" or type(Global("XTextButton")) ~= "table" then
		return false
	end

	panel_x, panel_y = PANEL_X0, PANEL_Y0
	panel = XWindow:new({
		Id = "SBMSeamTuner",
		HAlign = "left",
		VAlign = "top",
		Margins = box(panel_x, panel_y, 0, 0),
		Padding = box(10, 10, 10, 10),
		LayoutMethod = "VList",
		LayoutVSpacing = 4,
		MinWidth = 430,
		MaxWidth = 430,
		Background = Color(8, 8, 12, 230),
		HandleMouse = true,
		ZOrder = 100000,
		-- Drag from any non-interactive area: buttons/fields consume their own clicks, labels
		-- and the background fall through to here. terminal.desktop mouse-capture pattern.
		OnMouseButtonDown = function(self, pt, button)
			if button ~= "L" then return end
			local term = Global("terminal")
			if term and term.desktop and type(term.desktop.SetMouseCapture) == "function" then
				term.desktop:SetMouseCapture(self)
			end
			drag = { ox = pt:x(), oy = pt:y(), bx = panel_x, by = panel_y }
			return "break"
		end,
		OnMousePos = function(self, pt, button)
			local term = Global("terminal")
			if drag and term and term.desktop and term.desktop:GetMouseCapture() == self then
				-- Margins are logical units (multiplied by self.scale at layout); pt is in screen
				-- pixels. Convert the screen delta to logical units so the panel tracks the mouse
				-- 1:1 regardless of the UI scale (otherwise it lags / moves at a different speed).
				local sx, sy = 1000, 1000
				local sc = self.scale
				if sc then
					local ok, a, b = pcall(function() return sc:x(), sc:y() end)
					if ok then
						if type(a) == "number" and a > 0 then sx = a end
						if type(b) == "number" and b > 0 then sy = b end
					end
				end
				panel_x = drag.bx + (pt:x() - drag.ox) * 1000 / sx
				panel_y = drag.by + (pt:y() - drag.oy) * 1000 / sy
				if type(self.SetMargins) == "function" then
					self:SetMargins(box(floor(panel_x), floor(panel_y), 0, 0))
				end
				return "break"
			end
		end,
		OnMouseButtonUp = function(self, pt, button)
			if button ~= "L" then return end
			local term = Global("terminal")
			if term and term.desktop and type(term.desktop.SetMouseCapture) == "function" then
				term.desktop:SetMouseCapture(false)
			end
			drag = nil
			return "break"
		end,
	}, desktop)

	MakeText(panel, "Seam Blend Tuner  (drag anywhere; type or +/- , then Apply)")

	for _, p in ipairs(PARAMS) do
		local row = XWindow:new({ LayoutMethod = "HList", LayoutHSpacing = 6 }, panel)
		MakeText(row, p.label, 210)
		MakeButton(row, "-", function() Adjust(p, -1) end)
		edit_fields[p.key] = MakeEdit(row, p)
		MakeButton(row, "+", function() Adjust(p, 1) end)
	end

	local footer = XWindow:new({ LayoutMethod = "HList", LayoutHSpacing = 10 }, panel)
	apply_button = MakeButton(footer, "Apply", function() ApplyAction() end, 90)
	undo_button = MakeButton(footer, "Undo", function() UndoAction() end, 80)
	reset_button = MakeButton(footer, "Reset", function() ResetAction() end, 80)
	MakeButton(footer, "Close", function() Hide() end, 70)

	if type(panel.Open) == "function" then pcall(function() panel:Open() end) end
	return true
end

local SeamTuner = {}

function SeamTuner.Show()
	if cfg().SEAM_TUNER_ENABLED ~= true then return false end
	if PanelValid() then return true end
	InitValues()
	history = { CopyValues() } -- seed with the initial (expansion-applied) state for Undo
	return Build()
end

SeamTuner.Hide = Hide

function SeamTuner.Toggle()
	if PanelValid() then Hide() else SeamTuner.Show() end
end

SuperBigMap.SeamTuner = SeamTuner

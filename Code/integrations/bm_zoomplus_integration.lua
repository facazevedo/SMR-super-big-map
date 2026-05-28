-- Bigger Maps -- ZoomPlus integration.
--
-- The bundled ZoomPlus.lua is a self-contained, protected third-party camera-zoom
-- module. This is the ONLY Bigger Maps code that touches the global ZoomPlus table:
-- it sets the multiplier / scenario-editor allowance from Config and (re)applies the
-- zoom after map and camera resets. RestoreVanillaBehavior disables ZoomPlus.

local BiggerMaps = rawget(_G, "BiggerMaps")
if type(BiggerMaps) ~= "table" then
	BiggerMaps = {}
	rawset(_G, "BiggerMaps", BiggerMaps)
end

local Engine = BiggerMaps.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local Config = BiggerMaps.Config or {}

local NORMAL_ZOOM_ENABLED = Config.ENABLE_NORMAL_ZOOM_PLUS == true
local NORMAL_ZOOM_MULTIPLIER = (type(Config.NORMAL_ZOOM_MULTIPLIER) == "number") and Config.NORMAL_ZOOM_MULTIPLIER or 4.0
local ALLOW_ZOOMPLUS_WITH_SCENARIO_EDITOR_HOST = Config.ALLOW_ZOOMPLUS_WITH_SCENARIO_EDITOR_HOST == true

local function ApplyNormalZoom()
	if not NORMAL_ZOOM_ENABLED then
		return false
	end

	local zoom_plus = Global("ZoomPlus")
	if type(zoom_plus) ~= "table" then
		return false
	end

	zoom_plus.Config = type(zoom_plus.Config) == "table" and zoom_plus.Config or {}
	zoom_plus.Config.ALLOW_WITH_SCENARIO_EDITOR_HOST = ALLOW_ZOOMPLUS_WITH_SCENARIO_EDITOR_HOST

	if type(zoom_plus.SetMultiplier) == "function" then
		SafeCall(zoom_plus.SetMultiplier, NORMAL_ZOOM_MULTIPLIER)
	end
	if type(zoom_plus.Init) == "function" then
		SafeCall(zoom_plus.Init)
	end
	if type(zoom_plus.IsEnabled) == "function" and SafeCall(zoom_plus.IsEnabled) then
		if type(zoom_plus.Reapply) == "function" then
			return SafeCall(zoom_plus.Reapply) == true
		end
		return true
	end
	if type(zoom_plus.Enable) == "function" then
		return SafeCall(zoom_plus.Enable, "preserve camera") == true
	end

	return false
end

local ZoomPlusIntegration = {}

ZoomPlusIntegration.ApplyNormalZoom = ApplyNormalZoom

function ZoomPlusIntegration.ApplyModBehavior()
	ApplyNormalZoom()
end

function ZoomPlusIntegration.RestoreVanillaBehavior()
	local zoom_plus = Global("ZoomPlus")
	if type(zoom_plus) == "table" and type(zoom_plus.Disable) == "function" then
		SafeCall(zoom_plus.Disable)
	end
end

BiggerMaps.ZoomPlusIntegration = ZoomPlusIntegration

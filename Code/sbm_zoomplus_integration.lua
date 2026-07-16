-- Super Big Map -- ZoomPlus integration.
--
-- The bundled `Code/ZoomPlus.lua` is a self-contained camera-zoom module. This is the ONLY
-- Super Big Map code that touches the global ZoomPlus table: it sets the multiplier /
-- scenario-editor allowance / debug-log toggle from Config and (re)applies the zoom after map
-- and camera resets. RestoreVanillaBehavior disables ZoomPlus. ZoomPlus stays drop-in-ready:
-- do not introduce dependencies from inside `ZoomPlus.lua` on the SuperBigMap namespace.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local Config = SuperBigMap.Config or {}

local NORMAL_ZOOM_ENABLED = Config.ENABLE_NORMAL_ZOOM_PLUS == true
local NORMAL_ZOOM_MULTIPLIER = (type(Config.NORMAL_ZOOM_MULTIPLIER) == "number") and Config.NORMAL_ZOOM_MULTIPLIER or 4.0
local SHOW_ZOOM_DEBUG_LOGS = Config.DEBUG_ZOOM == true or Config.DEBUG_LOGS == true
local PRE_AIM_OVERVIEW_EXIT = Config.PRE_AIM_OVERVIEW_EXIT ~= false
local OVERVIEW_EXIT_PAN_TIME = (type(Config.OVERVIEW_EXIT_PAN_TIME) == "number") and Config.OVERVIEW_EXIT_PAN_TIME or 250

-- Multiplier actually applied to ZoomPlus on the last ApplyNormalZoom, so a CHANGED
-- value (e.g. the user moved the Max Zoom Level slider) is re-applied from the vanilla
-- baseline instead of stacking on the previous far distance.
local last_applied_multiplier = false

-- True on the MOD EDITOR test map -- Super Big Map must leave the camera vanilla there.
local function InModEditor()
	local fn = Global("IsModEditorMap")
	if type(fn) == "function" then
		local ok, res = pcall(fn)
		return ok and res == true
	end
	return false
end

local function ShouldUseModZoom()
	local grid = SuperBigMap.SectorGrid
	if grid and type(grid.IsModMap) == "function" then
		local ok, result = pcall(grid.IsModMap, Global("CurrentMap"))
		return ok and result == true
	end
	return false
end

local function DisableZoomPlus(zoom_plus)
	if type(zoom_plus) == "table" and type(zoom_plus.Disable) == "function" then
		SafeCall(zoom_plus.Disable)
	end
	last_applied_multiplier = false
end

-- The far-zoom multiplier to use: the per-save "Max Zoom Level" option when present
-- (sbm_zoom_option), else the static Config multiplier. >= 1.0 (1.0 = vanilla).
local function EffectiveMultiplier()
	local opt = SuperBigMap.ZoomOption
	if opt and type(opt.GetMultiplier) == "function" then
		local ok, m = pcall(opt.GetMultiplier)
		if ok and type(m) == "number" and m >= 1.0 then
			return m
		end
	end
	return NORMAL_ZOOM_MULTIPLIER
end

local function ApplyNormalZoom()
	if not NORMAL_ZOOM_ENABLED then
		return false
	end

	local zoom_plus = Global("SuperBigMapZoomPlus")
	if type(zoom_plus) ~= "table" then
		return false
	end

	if SuperBigMap.DebugLog and SuperBigMap.DebugLog.On and SuperBigMap.DebugLog.On("ZoomVanilla") then
		-- Ground-truth snapshot: the live camera zoom-out limit and const default (which
		-- ZoomPlus patches) + overview FOV (current vs saved-vanilla). Lets one repro show
		-- directly whether zoom/FOV is vanilla and which mechanism made it non-vanilla.
		local const_tbl = Global("const")
		local def = type(const_tbl) == "table" and const_tbl.DefaultCameraRTS or nil
		local cam_cfg = type(const_tbl) == "table" and const_tbl.Camera or nil
		local cam = Global("cameraRTS")
		local live_props = (type(cam) == "table" and type(cam.GetProperties) == "function")
			and SafeCall(cam.GetProperties, 1) or nil
		SuperBigMap.DebugLog.Info("ZoomVanilla", "ApplyNormalZoom snapshot", {
			map = tostring((Global("CurrentMap") or {}).name or "?"),
			should_use_mod_zoom = ShouldUseModZoom(),
			normal_zoom_enabled = NORMAL_ZOOM_ENABLED,
			zp_enabled = type(zoom_plus.IsEnabled) == "function" and (SafeCall(zoom_plus.IsEnabled) == true) or "?",
			effective_multiplier = EffectiveMultiplier(),
			const_default_zoom_out = (type(def) == "table") and def.LookatDistZoomOut or "?",
			live_zoom_out = (type(live_props) == "table") and live_props.LookatDistZoomOut or "?",
			zp_saved_vanilla_zoom_out = zoom_plus.original_default_zoom_out,
			fov_16_9 = (type(cam_cfg) == "table") and cam_cfg.OverviewFovX_16_9 or "?",
			vanilla_fov_16_9 = (type(cam_cfg) == "table") and cam_cfg.SuperBigMapOriginalOverviewFovX_16_9 or "?",
		})
	end

	if not ShouldUseModZoom() then
		DisableZoomPlus(zoom_plus)
		local DebugLog = SuperBigMap.DebugLog
		if DebugLog then
			DebugLog.Info("Zoom", "current map is not Super Big Map-expanded -- ZoomPlus left disabled")
		end
		return false
	end

	-- In the mod editor, stay VANILLA: disable ZoomPlus instead of applying it, so the
	-- editor camera/zoom is stock. (ZoomPlus re-applies normally on real game maps.)
	if InModEditor() then
		DisableZoomPlus(zoom_plus)
		local DebugLog = SuperBigMap.DebugLog
		if DebugLog then
			DebugLog.Info("Zoom", "mod editor detected -- ZoomPlus left disabled (vanilla camera)")
		end
		return false
	end

	zoom_plus.Config = type(zoom_plus.Config) == "table" and zoom_plus.Config or {}
	zoom_plus.Config.SHOW_ZOOM_DEBUG_LOGS = SHOW_ZOOM_DEBUG_LOGS
	zoom_plus.Config.PRE_AIM_OVERVIEW_EXIT = PRE_AIM_OVERVIEW_EXIT
	zoom_plus.Config.OVERVIEW_EXIT_PAN_TIME = OVERVIEW_EXIT_PAN_TIME

	local multiplier = EffectiveMultiplier()

	-- 100% / vanilla: ensure ZoomPlus is OFF so the camera's max zoom-out is exactly
	-- stock (ZoomPlus.SetMultiplier rejects <= 1, so "vanilla" must mean disabled).
	if multiplier <= 1.0 then
		if type(zoom_plus.IsEnabled) == "function" and SafeCall(zoom_plus.IsEnabled) == true
			and type(zoom_plus.Disable) == "function" then
			SafeCall(zoom_plus.Disable)
		end
		last_applied_multiplier = 1.0
		return true
	end

	local enabled = type(zoom_plus.IsEnabled) == "function" and SafeCall(zoom_plus.IsEnabled) == true
	-- A changed multiplier must be re-applied from the vanilla baseline: ZoomPlus captured
	-- the original zoom-out once and applies original * multiplier, so disable first
	-- (restores baseline + unpatches const) then re-enable with the new multiplier.
	if enabled and last_applied_multiplier ~= multiplier then
		if type(zoom_plus.Disable) == "function" then
			SafeCall(zoom_plus.Disable)
		end
		enabled = false
	end

	if type(zoom_plus.SetMultiplier) == "function" then
		SafeCall(zoom_plus.SetMultiplier, multiplier)
	end
	if type(zoom_plus.Init) == "function" then
		SafeCall(zoom_plus.Init)
	end

	local result
	if enabled then
		result = (type(zoom_plus.Reapply) ~= "function") or (SafeCall(zoom_plus.Reapply) == true)
	elseif type(zoom_plus.Enable) == "function" then
		result = SafeCall(zoom_plus.Enable, "preserve camera") == true
	else
		result = false
	end
	last_applied_multiplier = multiplier
	return result == true
end

local ZoomPlusIntegration = {}

ZoomPlusIntegration.ApplyNormalZoom = ApplyNormalZoom

function ZoomPlusIntegration.ApplyModBehavior()
	ApplyNormalZoom()
end

function ZoomPlusIntegration.RestoreVanillaBehavior()
	local zoom_plus = Global("SuperBigMapZoomPlus")
	DisableZoomPlus(zoom_plus)
end

SuperBigMap.ZoomPlusIntegration = ZoomPlusIntegration

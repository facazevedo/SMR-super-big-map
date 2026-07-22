-- Super Big Map -- ZoomPlus integration.
--
-- The bundled `Code/ZoomPlus.lua` is a self-contained camera-zoom module. This is the ONLY
-- Super Big Map code that touches the global ZoomPlus table: it sets the multiplier /
-- scenario-editor allowance from Config and (re)applies the zoom after map
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
local PRE_AIM_OVERVIEW_EXIT = Config.PRE_AIM_OVERVIEW_EXIT ~= false
local OVERVIEW_EXIT_PAN_TIME = (type(Config.OVERVIEW_EXIT_PAN_TIME) == "number") and Config.OVERVIEW_EXIT_PAN_TIME or 250

-- Multiplier actually applied to ZoomPlus on the last ApplyNormalZoom, so a CHANGED
-- value (e.g. the user moved the Max Zoom Level slider) is re-applied from the vanilla
-- baseline instead of stacking on the previous far distance.
local last_applied_multiplier = false

local function PointXYZ(point)
	if not point then return nil, nil, nil end
	return SafeCall(point.x, point), SafeCall(point.y, point), SafeCall(point.z, point)
end

local function PointValid(point)
	if not point then return false end
	local ok_method, is_valid = pcall(function() return point.IsValid end)
	return ok_method and type(is_valid) == "function" and SafeCall(is_valid, point) == true
end

-- Scalar snapshot of every value needed to diagnose an incorrect far-zoom limit.
-- All engine calls are protected because this also runs during save-load transitions.
local function CameraSnapshot()
	local out = {}
	local camera = Global("cameraRTS")
	local props = type(camera) == "table" and SafeCall(camera.GetProperties, 1) or nil
	local const_tbl = Global("const")
	local defaults = type(const_tbl) == "table" and const_tbl.DefaultCameraRTS or nil
	out.live_zoom_out = tostring(type(props) == "table" and props.LookatDistZoomOut or nil)
	out.default_zoom_out = tostring(type(defaults) == "table" and defaults.LookatDistZoomOut or nil)
	out.sane_z = tostring(type(const_tbl) == "table" and const_tbl.SanePosMaxZ or nil)
	out.interface_mode = tostring(SafeCall(Global("GetInGameInterfaceMode")))
	out.overview_active = tostring(SafeCall(Global("IsOverviewMode")) == true)
	out.transition_active = tostring(Global("CameraTransitionThread") ~= nil
		and Global("CameraTransitionThread") ~= false)
	out.changing_map = tostring(Global("ChangingMap") ~= nil and Global("ChangingMap") ~= false)
	if type(camera) == "table" then
		local zoom = SafeCall(camera.GetZoom)
		local min_zoom, max_zoom = SafeCall(camera.GetZoomLimits)
		out.zoom = tostring(zoom)
		out.zoom_scaled = tostring(type(zoom) == "number" and zoom * 1000 or nil)
		out.min_zoom = tostring(min_zoom)
		out.max_zoom = tostring(max_zoom)
		local eye = SafeCall(camera.GetEye)
		local lookat = SafeCall(camera.GetLookAt)
		local eye_valid = PointValid(eye)
		local lookat_valid = PointValid(lookat)
		out.eye_valid = tostring(eye_valid)
		out.lookat_valid = tostring(lookat_valid)
		local ex, ey, ez
		local lx, ly, lz
		if eye_valid then ex, ey, ez = PointXYZ(eye) end
		if lookat_valid then lx, ly, lz = PointXYZ(lookat) end
		out.eye_x, out.eye_y, out.eye_z = tostring(ex), tostring(ey), tostring(ez)
		out.lookat_x, out.lookat_y, out.lookat_z = tostring(lx), tostring(ly), tostring(lz)
		-- Never call the engine point-distance method here: the debug runtime asserts before pcall can
		-- contain it when either startup point is invalid. The scalar coordinates
		-- above are sufficient to reconstruct distance from a captured log.
	end
	return out
end

local function ZoomAudit(event, data)
	local diagnostics = SuperBigMap.Diagnostics
	if not diagnostics or type(diagnostics.Zoom) ~= "function" then return false end
	local out = CameraSnapshot()
	local zoom_plus = Global("SuperBigMapZoomPlus")
	if type(zoom_plus) == "table" and type(zoom_plus.GetDebugState) == "function" then
		local state = SafeCall(zoom_plus.GetDebugState)
		if type(state) == "table" then
			for key, value in pairs(state) do out["zp_" .. tostring(key)] = value end
		end
	end
	if type(data) == "table" then
		for key, value in pairs(data) do out[key] = value end
	end
	return diagnostics.Zoom(event, out, Global("CurrentMap"))
end

local function AttachZoomAudit(zoom_plus)
	if type(zoom_plus) ~= "table" then return end
	zoom_plus.Config = type(zoom_plus.Config) == "table" and zoom_plus.Config or {}
	local diagnostics = SuperBigMap.Diagnostics
	local enabled = diagnostics and type(diagnostics.ZoomEnabled) == "function"
		and diagnostics.ZoomEnabled() == true
	if enabled then
		zoom_plus.Config.AUDIT = function(event, data)
			ZoomAudit("ZOOMPLUS_" .. tostring(event), data)
		end
	else
		zoom_plus.Config.AUDIT = nil
	end
end

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
	local toggle = SuperBigMap.PregameToggle
	if toggle and type(toggle.ShouldUseModZoom) == "function" then
		local ok, result = pcall(toggle.ShouldUseModZoom, Global("CurrentMap"))
		return ok and result == true
	end
	local grid = SuperBigMap.SectorGrid
	if grid and type(grid.IsModMap) == "function" then
		local ok, result = pcall(grid.IsModMap, Global("CurrentMap"))
		return ok and result == true
	end
	return false
end

local function DisableZoomPlus(zoom_plus, source)
	ZoomAudit("DISABLE_BEGIN", { source = tostring(source or "?") })
	if type(zoom_plus) == "table" and type(zoom_plus.Disable) == "function" then
		SafeCall(zoom_plus.Disable)
	end
	last_applied_multiplier = false
	ZoomAudit("DISABLE_END", { source = tostring(source or "?") })
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

local function ApplyNormalZoom(source)
	source = tostring(source or "unspecified")
	if not NORMAL_ZOOM_ENABLED then
		ZoomAudit("APPLY_SKIPPED", { source = source, reason = "config_disabled" })
		return false
	end

	local zoom_plus = Global("SuperBigMapZoomPlus")
	if type(zoom_plus) ~= "table" then
		ZoomAudit("APPLY_SKIPPED", { source = source, reason = "zoomplus_missing" })
		return false
	end
	AttachZoomAudit(zoom_plus)

	local should_use = ShouldUseModZoom()
	if not should_use then
		DisableZoomPlus(zoom_plus, source .. ":not_mod_map")
		return false
	end

	-- In the mod editor, stay VANILLA: disable ZoomPlus instead of applying it, so the
	-- editor camera/zoom is stock. (ZoomPlus re-applies normally on real game maps.)
	if InModEditor() then
		DisableZoomPlus(zoom_plus, source .. ":mod_editor")
		return false
	end

	zoom_plus.Config = type(zoom_plus.Config) == "table" and zoom_plus.Config or {}
	zoom_plus.Config.PRE_AIM_OVERVIEW_EXIT = PRE_AIM_OVERVIEW_EXIT
	zoom_plus.Config.OVERVIEW_EXIT_PAN_TIME = OVERVIEW_EXIT_PAN_TIME

	local multiplier = EffectiveMultiplier()
	ZoomAudit("APPLY_BEGIN", {
		source = source,
		effective_multiplier = tostring(multiplier),
		last_applied_multiplier = tostring(last_applied_multiplier),
	})

	-- 100% / vanilla: ensure ZoomPlus is OFF so the camera's max zoom-out is exactly
	-- stock (ZoomPlus.SetMultiplier rejects <= 1, so "vanilla" must mean disabled).
	if multiplier <= 1.0 then
		if type(zoom_plus.IsEnabled) == "function" and SafeCall(zoom_plus.IsEnabled) == true
			and type(zoom_plus.Disable) == "function" then
			SafeCall(zoom_plus.Disable)
		end
		last_applied_multiplier = 1.0
		ZoomAudit("APPLY_END", {
			source = source, effective_multiplier = tostring(multiplier), result = "vanilla",
		})
		return true
	end

	local enabled = type(zoom_plus.IsEnabled) == "function" and SafeCall(zoom_plus.IsEnabled) == true
	-- A changed multiplier must be re-applied from the vanilla baseline: ZoomPlus captured
	-- the original zoom-out once and applies original * multiplier, so disable first
	-- (restores baseline + unpatches const) then re-enable with the new multiplier.
	if enabled and last_applied_multiplier ~= multiplier then
		ZoomAudit("APPLY_MULTIPLIER_CHANGED", {
			source = source,
			previous_multiplier = tostring(last_applied_multiplier),
			effective_multiplier = tostring(multiplier),
		})
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
	ZoomAudit("APPLY_END", {
		source = source,
		effective_multiplier = tostring(multiplier),
		was_enabled = tostring(enabled),
		result = tostring(result == true),
	})
	return result == true
end

local ZoomPlusIntegration = {}

ZoomPlusIntegration.ApplyNormalZoom = ApplyNormalZoom
ZoomPlusIntegration.DebugSnapshot = CameraSnapshot

function ZoomPlusIntegration.ApplyModBehavior()
	ApplyNormalZoom("ApplyModBehavior")
end

function ZoomPlusIntegration.RestoreVanillaBehavior()
	local zoom_plus = Global("SuperBigMapZoomPlus")
	AttachZoomAudit(zoom_plus)
	DisableZoomPlus(zoom_plus, "RestoreVanillaBehavior")
end

SuperBigMap.ZoomPlusIntegration = ZoomPlusIntegration

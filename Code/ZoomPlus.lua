-- Zoom+ camera controls.
--
-- A module that increases the RTS camera's far zoom-out distance by a configurable
-- multiplier without touching zoom-in or the overview-exit targeting logic. This copy
-- is PRIVATE to Super Big Map: it lives on the unique global SuperBigMapZoomPlus, never
-- the shared `ZoomPlus` global, and references no other mod (no Scenario Editor hooks).
--
-- Public API (all on the SuperBigMapZoomPlus table):
--   ZoomPlus.Enable(preserve_camera) -> bool
--   ZoomPlus.Disable()                -> bool
--   ZoomPlus.Toggle()                 -> string status
--   ZoomPlus.IsEnabled()              -> bool
--   ZoomPlus.Reapply()                -- after map / camera resets
--   ZoomPlus.Init()                   -- install lifecycle / overview hooks
--   ZoomPlus.SetMultiplier(value)
--   ZoomPlus.GetMultiplier()
--
-- Notes for overview behaviour:
--   Overview mode stores a return camera as saved_camera.eye_offset, then
--   vanilla restores cameraRTS properties at the end of the overview exit
--   transition. Zoom+ adjusts only the far zoom distance and carefully
--   preserves vanilla's overview targeting so the camera still exits toward
--   the hovered sector.

-- Super Big Map's PRIVATE ZoomPlus instance. It must NOT share the global `ZoomPlus`
-- table with other mods (e.g. the Scenario Editor mod bundles its own ZoomPlus under
-- that same name) -- each owns its own state and camera handling. So this copy is
-- registered ONLY under a unique global and the table itself is kept local; nothing
-- here ever touches _G.ZoomPlus. Used solely by Super Big Map.
local ZoomPlus = rawget(_G, "SuperBigMapZoomPlus") or {}
rawset(_G, "SuperBigMapZoomPlus", ZoomPlus)

ZoomPlus.Config = ZoomPlus.Config or {}
-- Default multiplier; Super Big Map overrides it via ZoomPlus.SetMultiplier().
if type(ZoomPlus.Config.MULTIPLIER) ~= "number" or ZoomPlus.Config.MULTIPLIER <= 1 then
	ZoomPlus.Config.MULTIPLIER = 1.5
end

local ZP = ZoomPlus
local ZOOM_OUT_OVERVIEW_REPEAT_MS = 500
local ZOOM_OUT_OVERVIEW_REPEAT_COUNT = 4
local ZOOM_RESTORE_RETRY_MS = 100
local ZOOM_RESTORE_RETRY_COUNT = 60
-- Polling cadence used when waiting for OverviewModeDialog.saved_camera to be set
-- up after vanilla starts the overview transition. Total wait budget is
-- ZOOM_DEFERRED_CLAMP_RETRY_MS * ZOOM_DEFERRED_CLAMP_RETRY_COUNT (about 6 s).
local ZOOM_DEFERRED_CLAMP_RETRY_MS = 100
local ZOOM_DEFERRED_CLAMP_RETRY_COUNT = 60
local ZOOM_FIRST_EXIT_TAKEOVER_TIMEOUT_MS = 5000

local ZoomPlus_InstallOverviewReturnCameraHook
local ZoomPlus_RemoveOverviewReturnCameraHook
local ZoomPlus_InstallZoomOutOverviewTriggerHook
local ZoomPlus_RemoveZoomOutOverviewTriggerHook
local ZoomPlus_RemoveWheelEventDebugHook
local ZoomPlus_InstallVanillaOverviewDiagnostics
local ZoomPlus_RemoveVanillaOverviewDiagnostics

local function ZoomPlus_CanModifyCamera()
	-- Super Big Map owns this instance and decides when it is enabled/disabled (the
	-- integration disables it where vanilla camera is wanted, e.g. the editor), so the
	-- camera may always be modified while ZoomPlus is enabled.
	return true
end

local function ZoomPlus_ShouldApplyZoomPlusCamera()
	return ZP.enabled == true and ZoomPlus_CanModifyCamera()
end

local function ZoomPlus_DebugValue(value)
	if value == nil then
		return "nil"
	end
	local value_type = type(value)
	if value_type == "string" or value_type == "number" or value_type == "boolean" then
		return tostring(value)
	end
	local ok, text = pcall(tostring, value)
	return ok and text or ("<" .. value_type .. ">")
end

local function ZoomPlus_DebugUiLabel(object)
	if not object then
		return "nil"
	end
	if type(object) ~= "table" and type(object) ~= "userdata" then
		return tostring(object)
	end
	local ok, id = pcall(function()
		return object.Id or object.id or object.class
	end)
	return ok and id and tostring(id) or ZoomPlus_DebugValue(object)
end

local function ZoomPlus_DebugEnabled(allow_inactive)
	if not allow_inactive and not ZoomPlus_CanModifyCamera() then
		return false
	end
	return type(ZP.Config) == "table" and ZP.Config.SHOW_ZOOM_DEBUG_LOGS == true
end

local function ZoomPlus_DebugCameraSummary()
	local parts = {}
	local get_mode = rawget(_G, "GetInGameInterfaceMode")
	if type(get_mode) == "function" then
		local ok, mode = pcall(get_mode)
		parts[#parts + 1] = "mode=" .. (ok and ZoomPlus_DebugValue(mode) or "err")
	end
	local get_dialog = rawget(_G, "GetDialog")
	if type(get_dialog) == "function" then
		local ok, build_menu = pcall(get_dialog, "XBuildMenu")
		parts[#parts + 1] = "build_menu_open=" .. tostring(ok and build_menu ~= nil and build_menu ~= false)
	end
	local camera_rts = rawget(_G, "cameraRTS")
	if type(camera_rts) == "table" then
		if type(camera_rts.GetZoom) == "function" then
			local ok, zoom = pcall(camera_rts.GetZoom)
			parts[#parts + 1] = "zoom=" .. (ok and ZoomPlus_DebugValue(zoom) or "err")
		end
		if type(camera_rts.GetZoomLimits) == "function" then
			local ok, min_zoom, max_zoom = pcall(camera_rts.GetZoomLimits)
			parts[#parts + 1] = "limits="
				.. (ok and ZoomPlus_DebugValue(min_zoom) .. "," .. ZoomPlus_DebugValue(max_zoom) or "err")
		end
		if type(camera_rts.GetProperties) == "function" then
			local ok, props = pcall(camera_rts.GetProperties, 1)
			if ok and type(props) == "table" then
				parts[#parts + 1] = "ZoomStep=" .. ZoomPlus_DebugValue(props.ZoomStep)
				parts[#parts + 1] = "ZoomTime=" .. ZoomPlus_DebugValue(props.ZoomTime)
				parts[#parts + 1] = "LookatDistZoomOut=" .. ZoomPlus_DebugValue(props.LookatDistZoomOut)
			end
		end
	end
	parts[#parts + 1] = "zoom_plus=" .. tostring(ZP.enabled == true)
	return table.concat(parts, "; ")
end

local function ZoomPlus_DebugPropsSummary(props)
	if type(props) ~= "table" then
		return "props=nil"
	end
	return "LookatDistZoomIn=" .. ZoomPlus_DebugValue(props.LookatDistZoomIn)
		.. "; LookatDistZoomOut=" .. ZoomPlus_DebugValue(props.LookatDistZoomOut)
		.. "; ZoomStep=" .. ZoomPlus_DebugValue(props.ZoomStep)
		.. "; ZoomTime=" .. ZoomPlus_DebugValue(props.ZoomTime)
end

local function ZoomPlus_VectorSummary(value)
	if not value then
		return "nil"
	end
	local len = "?"
	if type(value) == "table" or type(value) == "userdata" then
		local fn = value.Len
		if type(fn) == "function" then
			local ok, result = pcall(fn, value)
			if ok then
				len = ZoomPlus_DebugValue(result)
			end
		end
	end
	return ZoomPlus_DebugValue(value) .. "[len=" .. len .. "]"
end

local function ZoomPlus_SavedCameraSummary(dialog)
	local saved = dialog and dialog.saved_camera
	local eye_offset = saved and saved.eye_offset
	local lookat = saved and (saved.lookat or saved.look_at)
	return "saved=" .. tostring(saved ~= nil)
		.. "; saved_eye_offset=" .. ZoomPlus_VectorSummary(eye_offset)
		.. "; saved_lookat=" .. ZoomPlus_DebugValue(lookat)
end

local function ZoomPlus_Debug(trigger, object, path, success, extra, key, allow_inactive)
	if not ZoomPlus_DebugEnabled(allow_inactive) then
		return
	end
	local message = "zoom: "
		.. "trigger=" .. tostring(trigger or "")
		.. "; object=" .. ZoomPlus_DebugUiLabel(object)
		.. "; path=" .. tostring(path or "")
		.. "; success=" .. tostring(success == true)
		.. "; " .. ZoomPlus_DebugCameraSummary()
		.. (extra and extra ~= "" and ("; " .. tostring(extra)) or "")
	ZP.debug_last = ZP.debug_last or {}
	if key and ZP.debug_last[key] == message then
		return
	end
	if key then
		ZP.debug_last[key] = message
	end
	print("[Super Big Map] ZoomPlus: " .. message)
end

local function ZoomPlus_ShouldLogVanillaDiagnostics()
	return ZP.vanilla_diagnostics_armed == true and ZP.enabled ~= true and ZoomPlus_DebugEnabled(true)
end

-- Disable/enable-path diagnostics. These previously routed to a host helper; this
-- private copy has no host, so they are no-ops kept only so existing call sites stay
-- valid. (General zoom diagnostics still go through ZoomPlus_Debug.)
local function ZoomPlus_DebugDisable(trigger, path, success, extra, key)
end

local function ZoomPlus_DebugEnable(trigger, path, success, extra, key)
end

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

function ZP.SetMultiplier(value)
	if type(value) ~= "number" or value <= 1 then
		return false
	end
	ZP.Config.MULTIPLIER = value
	return true
end

function ZP.GetMultiplier()
	local value = ZP.Config and ZP.Config.MULTIPLIER
	if type(value) ~= "number" or value <= 1 then
		return 1.5
	end
	return value
end

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- Return a shallow copy of a plain Lua table.
local function ZoomPlus_CopyTable(source)
	local copy = {}
	for key, value in pairs(source or {}) do
		copy[key] = value
	end
	return copy
end

local function ZoomPlus_GetDefaultRTSCameraProperties()
	local const_table = rawget(_G, "const")
	local defaults = const_table and const_table.DefaultCameraRTS
	return type(defaults) == "table" and defaults or false
end

local function ZoomPlus_NormalizeCameraProperties(props)
	if type(props) ~= "table" then
		return false
	end

	local defaults = ZoomPlus_GetDefaultRTSCameraProperties()
	local normalized = defaults and ZoomPlus_CopyTable(defaults) or {}
	for key, value in pairs(props) do
		normalized[key] = value
	end
	if type(ZP.original_default_zoom_out) == "number" then
		normalized.LookatDistZoomOut = normalized.LookatDistZoomOut or ZP.original_default_zoom_out
	end
	return normalized
end

-- Return the RTS camera API table when the engine exposes it.
local function ZoomPlus_GetRTSCamera()
	local camera_rts = rawget(_G, "cameraRTS")
	return type(camera_rts) == "table" and camera_rts or false
end

local function ZoomPlus_GetInterfaceMode()
	local get_mode = rawget(_G, "GetInGameInterfaceMode")
	if type(get_mode) == "function" then
		local ok, mode = pcall(get_mode)
		if ok then
			return mode
		end
	end
	return nil
end

local function ZoomPlus_IsCameraTransitionActive()
	return rawget(_G, "CameraTransitionThread") and true or false
end

-- Return whether the game is currently using the special overview camera state.
local function ZoomPlus_IsOverviewZoomActive()
	local is_overview = rawget(_G, "IsOverviewMode")
	if type(is_overview) == "function" then
		local ok, result = pcall(is_overview)
		return ok and result and true or false
	end
	return ZoomPlus_GetInterfaceMode() == "overview"
end

-- ---------------------------------------------------------------------------
-- Camera properties
-- ---------------------------------------------------------------------------

-- Return the active RTS camera properties when the engine API is available.
local function ZoomPlus_GetRTSCameraProperties()
	local camera_rts = ZoomPlus_GetRTSCamera()
	if not camera_rts or type(camera_rts.GetProperties) ~= "function" then
		return false
	end
	local ok, props = pcall(camera_rts.GetProperties, 1)
	return ok and type(props) == "table" and props or false
end

local function ZoomPlus_DebugCameraTablesSummary()
	return "transition=" .. tostring(ZoomPlus_IsCameraTransitionActive())
		.. "; overview=" .. tostring(ZoomPlus_IsOverviewZoomActive())
		.. "; live{" .. ZoomPlus_DebugPropsSummary(ZoomPlus_GetRTSCameraProperties()) .. "}"
		.. "; defaults{" .. ZoomPlus_DebugPropsSummary(ZoomPlus_GetDefaultRTSCameraProperties()) .. "}"
		.. "; original{" .. ZoomPlus_DebugPropsSummary(ZP.original_properties) .. "}"
		.. "; original_default_zoom_out=" .. ZoomPlus_DebugValue(ZP.original_default_zoom_out)
end

local function ZoomPlus_DebugOverviewExtra(dialog, prefix)
	local parts = {}
	if prefix and prefix ~= "" then
		parts[#parts + 1] = tostring(prefix)
	end
	parts[#parts + 1] = ZoomPlus_SavedCameraSummary(dialog)
	parts[#parts + 1] = ZoomPlus_DebugCameraTablesSummary()
	return table.concat(parts, "; ")
end

-- Return the normal RTS camera defaults while overview has temporary camera props applied.
local function ZoomPlus_GetNormalRTSCameraProperties()
	local defaults = ZoomPlus_GetDefaultRTSCameraProperties()
	if ZoomPlus_IsOverviewZoomActive() then
		if defaults then
			return defaults
		end
	end
	local props = ZoomPlus_GetRTSCameraProperties()
	local mode = ZoomPlus_GetInterfaceMode()
	if props and defaults and (mode == nil or mode == false) then
		local current_zoom_out = tonumber(props.LookatDistZoomOut)
		local default_zoom_out = tonumber(defaults.LookatDistZoomOut)
		if current_zoom_out and default_zoom_out and current_zoom_out < default_zoom_out then
			ZoomPlus_Debug(
				"capture",
				ZP,
				"use_defaults_while_mode_unset",
				true,
				ZoomPlus_DebugPropsSummary(props),
				"capture_mode_unset_defaults"
			)
			return defaults
		end
	end
	return props or defaults
end

-- Store the original RTS camera properties once. Keep the full table: the engine uses
-- fields such as ZoomStep/ZoomTime for normal mouse-wheel zoom.
local function ZoomPlus_CaptureOriginalZoomProperties()
	if ZP.original_properties then
		local normalized = ZoomPlus_NormalizeCameraProperties(ZP.original_properties)
		if normalized and type(normalized.LookatDistZoomOut) == "number" then
			ZP.original_properties = normalized
			return ZP.original_properties
		end
	end

	local props = ZoomPlus_NormalizeCameraProperties(ZoomPlus_GetNormalRTSCameraProperties())
	if not props or type(props.LookatDistZoomOut) ~= "number" then
		return false
	end

	if type(ZP.original_default_zoom_out) == "number" then
		props.LookatDistZoomOut = ZP.original_default_zoom_out
	end
	ZP.original_properties = props
	return ZP.original_properties
end

-- Apply the requested RTS camera property values.
local function ZoomPlus_SetRTSCameraZoomProperties(props)
	local camera_rts = ZoomPlus_GetRTSCamera()
	if not camera_rts or type(camera_rts.SetProperties) ~= "function" or type(props) ~= "table" then
		ZoomPlus_Debug(
			"set_properties",
			camera_rts,
			"camera_set_properties_unavailable",
			false,
			ZoomPlus_DebugPropsSummary(props)
		)
		return false
	end
	local ok = pcall(camera_rts.SetProperties, 1, props)
	ZoomPlus_Debug(
		"set_properties",
		camera_rts,
		"camera_set_properties_full_table",
		ok,
		ZoomPlus_DebugPropsSummary(props)
	)
	return ok
end

-- Patch the default table used by overview exit so the vanilla camera reset keeps Zoom+'s far limit.
local function ZoomPlus_SetDefaultZoomOut(zoom_out)
	local const = rawget(_G, "const")
	local defaults = const and const.DefaultCameraRTS
	if type(defaults) ~= "table" or type(zoom_out) ~= "number" then
		return false
	end
	if ZP.original_default_zoom_out == nil then
		ZP.original_default_zoom_out = defaults.LookatDistZoomOut
	end
	defaults.LookatDistZoomOut = zoom_out
	return true
end

-- Restore the default RTS zoom-out distance when Zoom+ turns off.
local function ZoomPlus_RestoreDefaultZoomOut()
	if ZP.original_default_zoom_out == nil then
		return true
	end
	local const = rawget(_G, "const")
	local defaults = const and const.DefaultCameraRTS
	if type(defaults) == "table" then
		defaults.LookatDistZoomOut = ZP.original_default_zoom_out
	end
	return true
end

-- Clear all transient Zoom+ camera state.
local function ZoomPlus_ClearTransientState()
	ZP.last_overview_zoom_out = false
	ZP.overview_zoom_out_count = false
	ZP.vanilla_overview_eye_offset = false
	ZP.first_overview_exit_takeover_armed = false
	ZP.first_overview_exit_takeover_token = false
end

local function ZoomPlus_IsValidCameraPoint(point)
	if not point then
		return false
	end
	local ok_method, is_valid = pcall(function()
		return point.IsValid
	end)
	if not ok_method then
		return false
	end
	if type(is_valid) == "function" then
		local ok, valid = pcall(is_valid, point)
		return ok and valid == true
	end
	return true
end

-- Reapply the current RTS camera position so changed zoom properties take effect immediately.
local function ZoomPlus_ReapplyCurrentCameraForZoomProperties()
	local camera_rts = ZoomPlus_GetRTSCamera()
	if not camera_rts or type(camera_rts.SetCamera) ~= "function" then
		return false
	end

	local get_eye = camera_rts.GetEye
	local get_lookat = camera_rts.GetLookAt
	if type(get_eye) ~= "function" or type(get_lookat) ~= "function" then
		return false
	end

	local ok_eye, eye = pcall(get_eye)
	local ok_lookat, lookat = pcall(get_lookat)
	if not ok_eye or not ok_lookat or not eye or not lookat then
		return false
	end
	if not ZoomPlus_IsValidCameraPoint(eye) or not ZoomPlus_IsValidCameraPoint(lookat) then
		return false
	end
	local ok = pcall(camera_rts.SetCamera, eye, lookat, 0)
	return ok
end

-- Return a concise status line for the current Zoom+ setting.
local function ZoomPlus_Status(action)
	local multiplier = ZP.last_multiplier or ZP.GetMultiplier()
	local zoom_out = ZP.last_zoom_out
	local suffix = zoom_out and ("; far zoom = " .. tostring(zoom_out)) or ""
	return "zoom+ " .. tostring(action) .. " x" .. string.format("%.2f", multiplier) .. suffix
end

-- ---------------------------------------------------------------------------
-- Overview return camera
-- ---------------------------------------------------------------------------

-- Return the active overview dialog when it has a saved return camera.
local function ZoomPlus_GetOverviewDialogWithSavedCamera()
	local get_interface = rawget(_G, "GetInGameInterface")
	if type(get_interface) ~= "function" then
		return false
	end
	local ok, igi = pcall(get_interface)
	local dialog = ok and igi and igi.mode_dialog
	return dialog and dialog.saved_camera and dialog or false
end

-- Remember overview's original saved camera when Zoom+ is enabled from overview.
local function ZoomPlus_CacheVanillaOverviewSavedCamera()
	local dialog = ZoomPlus_GetOverviewDialogWithSavedCamera()
	local saved = dialog and dialog.saved_camera
	if not saved or not saved.eye_offset or ZP.vanilla_overview_eye_offset then
		return false
	end
	ZP.vanilla_overview_eye_offset = saved.eye_offset
	return true
end

-- Restore the exact vanilla saved return camera when Zoom+ is turned off from overview.
local function ZoomPlus_RestoreVanillaOverviewSavedCamera()
	local dialog = ZoomPlus_GetOverviewDialogWithSavedCamera()
	local eye_offset = ZP.vanilla_overview_eye_offset
	if not dialog or not eye_offset then
		return false
	end
	dialog.saved_camera = dialog.saved_camera or {}
	dialog.saved_camera.eye_offset = eye_offset
	return true
end

-- Clamp only the return distance; the saved lookat stays vanilla so hovered-sector targeting is unchanged.
local function ZoomPlus_ClampOverviewSavedCameraToVanilla()
	local dialog = ZoomPlus_GetOverviewDialogWithSavedCamera()
	local saved = dialog and dialog.saved_camera
	local eye_offset = saved and saved.eye_offset
	local original = ZP.original_properties
	local guim_value = rawget(_G, "guim") or 1000
	local max_dist = original and tonumber(original.LookatDistZoomOut)
	local set_len = rawget(_G, "SetLen")
	if not saved or not eye_offset or type(max_dist) ~= "number" or type(set_len) ~= "function" then
		return false
	end

	local ok_len, current_len = pcall(function()
		return eye_offset:Len()
	end)
	local vanilla_len = max_dist * guim_value
	if not ok_len or type(current_len) ~= "number" or current_len <= vanilla_len then
		return false
	end

	local ok_offset, clamped = pcall(set_len, eye_offset, vanilla_len)
	if ok_offset and clamped then
		saved.eye_offset = clamped
		return true
	end
	return false
end

-- Keep vanilla's overview target while removing only the Zoom+ extra distance.
local function ZoomPlus_ApplyOverviewReturnCamera(dialog)
	if not ZoomPlus_ShouldApplyZoomPlusCamera() or not dialog then
		return false
	end

	return ZoomPlus_ClampOverviewSavedCameraToVanilla()
end

local function ZoomPlus_HasPointExitTarget(dialog)
	local exit_to = dialog and dialog.exit_to
	if not exit_to then
		return false
	end
	local is_point = rawget(_G, "IsPoint")
	if type(is_point) == "function" and not is_point(exit_to) then
		return false
	end
	return true
end

-- Arm one mod-driven transition override only for the startup overview return
-- camera that the host marks. Later overview exits have vanilla saved_camera data
-- and should be left completely to vanilla's transition path.
local function ZoomPlus_ArmFirstOverviewExitTakeover(dialog)
	if not ZoomPlus_HasPointExitTarget(dialog) then
		return false
	end
	local saved = dialog.saved_camera
	if type(saved) ~= "table" or saved.bigger_maps_startup_overview_return ~= true then
		return false
	end

	saved.bigger_maps_startup_overview_return = nil
	local token = {}
	ZP.first_overview_exit_takeover_token = token
	ZP.first_overview_exit_takeover_armed = true
	ZoomPlus_Debug(
		"overview_exit",
		dialog,
		"first_exit_takeover_armed",
		true,
		"exit_to=" .. ZoomPlus_VectorSummary(dialog.exit_to)
	)

	local create_thread = rawget(_G, "CreateRealTimeThread")
	local sleep = rawget(_G, "Sleep")
	if type(create_thread) == "function" and type(sleep) == "function" then
		pcall(create_thread, function(thread_token)
			sleep(ZOOM_FIRST_EXIT_TAKEOVER_TIMEOUT_MS)
			if ZP.first_overview_exit_takeover_token == thread_token then
				ZP.first_overview_exit_takeover_token = false
				ZP.first_overview_exit_takeover_armed = false
				ZoomPlus_Debug(
					"overview_exit",
					ZP,
					"first_exit_takeover_expired",
					true,
					"timeout_ms=" .. tostring(ZOOM_FIRST_EXIT_TAKEOVER_TIMEOUT_MS)
				)
			end
		end, token)
	end
	return true
end

function ZP.ConsumeFirstOverviewExitTakeover()
	if ZP.first_overview_exit_takeover_armed ~= true then
		return false
	end
	ZP.first_overview_exit_takeover_armed = false
	ZP.first_overview_exit_takeover_token = false
	ZoomPlus_Debug("overview_exit", ZP, "first_exit_takeover_consumed", true, "")
	return true
end

-- Pre-aim the overview exit: just before vanilla's RestoreCamera runs its descent
-- SetCamera(eye, lookat=exit_to, time), snap the LIVE camera's lookat to the exit
-- sector (keeping the current eye). RestoreCamera then interpolates from a camera
-- already looking at the sector to one looking at the same sector -> the lookat
-- stays put, so the sector is locked on screen and the camera descends STRAIGHT
-- onto it instead of panning across the map (the curved first zoom-in). Only fires
-- when exiting toward a specific sector/point (exit_to set); the "return to where
-- you were" (Escape, exit_to=false) path is left to vanilla. Gated by
-- ZP.Config.PRE_AIM_OVERVIEW_EXIT (default on).
local function ZoomPlus_PreAimOverviewExit(dialog, first_exit_takeover_armed)
	if first_exit_takeover_armed ~= true then
		return false
	end
	if not dialog then
		return false
	end
	if type(ZP.Config) == "table" and ZP.Config.PRE_AIM_OVERVIEW_EXIT == false then
		return false
	end
	local exit_to = dialog.exit_to
	if not ZoomPlus_HasPointExitTarget(dialog) then
		return false
	end
	local camera_rts = ZoomPlus_GetRTSCamera()
	if not camera_rts or type(camera_rts.SetCamera) ~= "function"
		or type(camera_rts.GetEye) ~= "function" or type(camera_rts.GetLookAt) ~= "function" then
		return false
	end
	local ok_eye, eye = pcall(camera_rts.GetEye)
	local ok_la, lookat = pcall(camera_rts.GetLookAt)
	if not ok_eye or not ok_la or not eye or not lookat
		or not ZoomPlus_IsValidCameraPoint(eye) or not ZoomPlus_IsValidCameraPoint(lookat) then
		return false
	end
	-- Re-position the WHOLE overview camera over the chosen sector at the current
	-- overview height/angle: keep the current eye->lookat offset but move both so
	-- the lookat sits on the sector. Vanilla's descent then keeps the camera facing
	-- the same way and X/Y-aligned to the sector, so it drops STRAIGHT onto it with
	-- no lookat pan and no eye overshoot. (Snapping only the lookat -- keeping the
	-- eye over map-center -- created a large sideways offset that the descent then
	-- interpolated away, which is the swing we saw.)
	local ok_off, offset = pcall(function()
		return eye - lookat
	end)
	if not ok_off or not offset then
		return false
	end
	local ok_new, new_eye = pcall(function()
		return exit_to + offset
	end)
	if not ok_new or not new_eye then
		return false
	end
	-- Stop the host mod's overview re-centering schedule first: it periodically
	-- re-snaps the overview camera to map-center, and if it fires during our pan it
	-- yanks the camera back to center, so vanilla's descent restarts from center and
	-- the curve returns. Optional/guarded -- a no-op when there's no such host.
	local host = rawget(_G, "SuperBigMap")
	if host and type(host.OverviewCamera) == "table" and type(host.OverviewCamera.CancelScheduledRefresh) == "function" then
		pcall(host.OverviewCamera.CancelScheduledRefresh)
	end

	-- Animate the lateral PAN to center the sector at the current overview height,
	-- then wait for it to finish, so vanilla's following descent starts from a
	-- camera already over the sector (lookat fixed) -> a straight drop with NO
	-- jump. Doing this instantly (time 0) teleported the camera sideways, which
	-- read as "jump to a farther spot, then zoom in". The Close wrapper runs in
	-- vanilla's sleepable transition thread, so Sleep here just delays the descent.
	local pan_time = (type(ZP.Config) == "table" and tonumber(ZP.Config.OVERVIEW_EXIT_PAN_TIME)) or 250
	if pan_time < 0 then
		pan_time = 0
	end
	local ok = pcall(camera_rts.SetCamera, new_eye, exit_to, pan_time)
	ZoomPlus_Debug(
		"overview_exit",
		dialog,
		"pre_aim_pan_over_sector",
		ok == true,
		"pan_time=" .. tostring(pan_time)
			.. "; exit_to=" .. ZoomPlus_VectorSummary(exit_to)
			.. "; old_eye=" .. ZoomPlus_VectorSummary(eye)
			.. "; new_eye=" .. ZoomPlus_VectorSummary(new_eye)
			.. "; offset=" .. ZoomPlus_VectorSummary(offset)
	)
	if ok and pan_time > 0 then
		local sleep = rawget(_G, "Sleep")
		if type(sleep) == "function" then
			pcall(sleep, pan_time)
		end
	end
	return ok == true
end

local function ZoomPlus_RestoreOriginalZoomProperties(original, path, reapply_camera)
	ZoomPlus_RestoreDefaultZoomOut()

	local restored = ZoomPlus_SetRTSCameraZoomProperties(original)
	local reapplied = false
	if restored and reapply_camera then
		reapplied = ZoomPlus_ReapplyCurrentCameraForZoomProperties()
	end

	ZoomPlus_Debug(
		"disable",
		ZoomPlus_GetRTSCamera() or ZP,
		path or "restore_original_properties",
		restored and (not reapply_camera or reapplied),
		"reapply_requested=" .. tostring(reapply_camera == true)
			.. "; reapplied=" .. tostring(reapplied == true)
			.. "; " .. ZoomPlus_DebugPropsSummary(original),
		"disable_restore:" .. tostring(path or "restore_original_properties"),
		true
	)
	return restored
end

-- Capture the live RTS camera eye, lookat, and the eye-to-lookat distance.
-- We snapshot these *before* changing camera properties so we can restore the
-- exact viewpoint after SetProperties (which can clamp the camera in when the
-- new properties have a smaller LookatDistZoomOut than the current eye distance).
local function ZoomPlus_CaptureLiveCameraView()
	local camera_rts = ZoomPlus_GetRTSCamera()
	if not camera_rts then
		return false, false, false
	end
	local get_eye = camera_rts.GetEye
	local get_lookat = camera_rts.GetLookAt
	if type(get_eye) ~= "function" or type(get_lookat) ~= "function" then
		return false, false, false
	end
	local ok_eye, eye = pcall(get_eye)
	local ok_lookat, lookat = pcall(get_lookat)
	if not ok_eye or not ok_lookat or not eye or not lookat then
		return false, false, false
	end
	if not ZoomPlus_IsValidCameraPoint(eye) or not ZoomPlus_IsValidCameraPoint(lookat) then
		return false, false, false
	end

	local distance = false
	if type(eye.Dist) == "function" then
		local ok_dist, value = pcall(eye.Dist, eye, lookat)
		if ok_dist and type(value) == "number" then
			distance = value
		end
	end
	if not distance then
		local ok_sub, diff = pcall(function()
			return eye - lookat
		end)
		if ok_sub and diff and type(diff.Len) == "function" then
			local ok_len, value = pcall(diff.Len, diff)
			if ok_len and type(value) == "number" then
				distance = value
			end
		end
	end
	return distance, eye, lookat
end

local function ZoomPlus_ApplyCapturedCameraView(eye, lookat)
	if not eye or not lookat then
		return false
	end
	if not ZoomPlus_IsValidCameraPoint(eye) or not ZoomPlus_IsValidCameraPoint(lookat) then
		return false
	end
	local camera_rts = ZoomPlus_GetRTSCamera()
	if not camera_rts or type(camera_rts.SetCamera) ~= "function" then
		return false
	end
	local ok = pcall(camera_rts.SetCamera, eye, lookat, 0)
	return ok == true
end

-- Restore vanilla camera properties without disturbing the user's current zoom:
-- snapshot eye/lookat first, then SetProperties (which may otherwise clamp the
-- camera in if it's currently beyond the vanilla LookatDistZoomOut), then put
-- the captured eye/lookat back so the user keeps their current viewpoint.
local function ZoomPlus_RestoreOriginalZoomPropertiesPreservingCamera(original, path)
	local distance, eye, lookat = ZoomPlus_CaptureLiveCameraView()
	local snapshot_ok = eye and lookat and true or false

	ZoomPlus_RestoreDefaultZoomOut()
	local restored = ZoomPlus_SetRTSCameraZoomProperties(original)
	local reapplied = restored and ZoomPlus_ApplyCapturedCameraView(eye, lookat) or false
	local success = restored and (not snapshot_ok or reapplied)

	ZoomPlus_Debug(
		"disable",
		ZoomPlus_GetRTSCamera() or ZP,
		path or "restore_preserving_camera",
		success,
		"captured_distance=" .. ZoomPlus_DebugValue(distance)
			.. "; reapplied=" .. tostring(reapplied == true)
			.. "; " .. ZoomPlus_DebugPropsSummary(original),
		"disable_restore_preserving_camera:" .. tostring(path or "restore_preserving_camera"),
		true
	)
	ZoomPlus_DebugDisable(
		"scenario_mode_disable",
		path or "restore_preserving_camera",
		success,
		"snapshot_ok=" .. tostring(snapshot_ok)
			.. "; captured_distance=" .. ZoomPlus_DebugValue(distance)
			.. "; set_props_ok=" .. tostring(restored == true)
			.. "; reapplied_camera=" .. tostring(reapplied == true)
			.. "; vanilla_LookatDistZoomOut=" .. ZoomPlus_DebugValue(original and original.LookatDistZoomOut),
		"restore_preserving_camera:" .. tostring(path or "restore_preserving_camera")
	)
	return restored
end

-- Switch to overview mode while disabling Zoom+. We use this when the user is
-- currently zoomed out farther than vanilla's far limit (only possible because
-- Zoom+ extended it): snapping cameraRTS.SetProperties to vanilla here would
-- jam the camera in. Instead we let vanilla's overview-close transition reset
-- camera properties at the end (const.DefaultCameraRTS is restored to vanilla
-- first so the eventual reset uses the unmodified zoom-out distance).
local function ZoomPlus_EnterOverviewModeForDisable(reason)
	local current_map = rawget(_G, "CurrentMap")
	if not current_map or not current_map.mapdata or not current_map.mapdata.IsAllowedToEnterOverview then
		ZoomPlus_Debug(
			"disable",
			ZP,
			"enter_overview_blocked_map_disallowed",
			false,
			"reason=" .. tostring(reason or "")
		)
		ZoomPlus_DebugDisable(
			"scenario_mode_disable",
			"enter_overview_blocked_map_disallowed",
			false,
			"reason=" .. tostring(reason or ""),
			"enter_overview:blocked_map"
		)
		return false
	end

	local get_interface = rawget(_G, "GetInGameInterface")
	if type(get_interface) ~= "function" then
		ZoomPlus_DebugDisable(
			"scenario_mode_disable",
			"enter_overview_blocked_get_interface_missing",
			false,
			"reason=" .. tostring(reason or ""),
			"enter_overview:get_interface_missing"
		)
		return false
	end
	local ok_igi, igi = pcall(get_interface)
	if not ok_igi or type(igi) ~= "table" or type(igi.SetMode) ~= "function" then
		ZoomPlus_DebugDisable(
			"scenario_mode_disable",
			"enter_overview_blocked_igi_unavailable",
			false,
			"reason=" .. tostring(reason or "")
				.. "; ok_igi=" .. tostring(ok_igi == true)
				.. "; igi_type=" .. type(igi),
			"enter_overview:igi_unavailable"
		)
		return false
	end

	local mode_dialog = igi.mode_dialog
	if
		mode_dialog
		and type(mode_dialog.AllowExitToOverview) == "function"
		and not mode_dialog:AllowExitToOverview()
	then
		ZoomPlus_Debug(
			"disable",
			ZP,
			"enter_overview_blocked_dialog_disallowed",
			false,
			"reason=" .. tostring(reason or "")
		)
		ZoomPlus_DebugDisable(
			"scenario_mode_disable",
			"enter_overview_blocked_dialog_disallowed",
			false,
			"reason=" .. tostring(reason or "")
				.. "; mode_dialog_class=" .. ZoomPlus_DebugUiLabel(mode_dialog),
			"enter_overview:blocked_dialog"
		)
		return false
	end

	-- Restore vanilla const.DefaultCameraRTS so when overview-close eventually
	-- resets cameraRTS at the tail of its transition, the limits used are
	-- vanilla, not Zoom+'s extended values.
	ZoomPlus_RestoreDefaultZoomOut()

	local ok_set = pcall(function()
		igi:SetMode("overview")
	end)
	ZoomPlus_Debug(
		"disable",
		ZP,
		"enter_overview_for_disable",
		ok_set == true,
		"reason=" .. tostring(reason or "")
	)
	ZoomPlus_DebugDisable(
		"scenario_mode_disable",
		"enter_overview_for_disable",
		ok_set == true,
		"reason=" .. tostring(reason or "")
			.. "; mode_dialog=" .. ZoomPlus_DebugUiLabel(mode_dialog),
		"enter_overview:set_mode"
	)
	return ok_set == true
end

-- Poll OverviewModeDialog.saved_camera until it is set up (vanilla creates it a
-- few frames into the overview-enter transition), then clamp its eye_offset to
-- vanilla's far zoom distance so the eventual overview-close lands the camera
-- at vanilla max instead of at the Zoom+ extended distance the user was at when
-- they pressed disable. Without this clamp, vanilla's SetProperties(1, defaults)
-- at the tail of overview-close meets an eye that's still at Zoom+ distance and
-- the engine slams the camera all the way in (the "very close" snap).
local function ZoomPlus_ScheduleClampOverviewSavedCamera(original)
	local create_thread = rawget(_G, "CreateRealTimeThread")
	local sleep = rawget(_G, "Sleep")
	if type(create_thread) ~= "function" or type(sleep) ~= "function" then
		ZoomPlus_DebugDisable(
			"scenario_mode_disable",
			"defer_clamp_unavailable_no_thread",
			false,
			"vanilla_LookatDistZoomOut=" .. ZoomPlus_DebugValue(original and original.LookatDistZoomOut),
			"overview:defer_clamp:no_thread"
		)
		return false
	end

	local token = {}
	ZP.deferred_clamp_token = token

	pcall(create_thread, function(thread_token)
		local attempts = 0
		while ZP.deferred_clamp_token == thread_token do
			local restored = ZoomPlus_RestoreVanillaOverviewSavedCamera()
			local clamped = ZoomPlus_ClampOverviewSavedCameraToVanilla()
			if restored or clamped then
				ZP.deferred_clamp_token = false
				ZoomPlus_DebugDisable(
					"scenario_mode_disable",
					"deferred_overview_saved_camera_clamped",
					true,
					"restored_cache=" .. tostring(restored == true)
						.. "; clamped=" .. tostring(clamped == true)
						.. "; attempts=" .. tostring(attempts),
					"overview:defer_clamp:done"
				)
				return
			end
			attempts = attempts + 1
			if attempts >= ZOOM_DEFERRED_CLAMP_RETRY_COUNT then
				ZP.deferred_clamp_token = false
				ZoomPlus_DebugDisable(
					"scenario_mode_disable",
					"deferred_overview_saved_camera_clamp_timeout",
					false,
					"attempts=" .. tostring(attempts)
						.. "; retry_ms=" .. tostring(ZOOM_DEFERRED_CLAMP_RETRY_MS),
					"overview:defer_clamp:timeout"
				)
				return
			end
			sleep(ZOOM_DEFERRED_CLAMP_RETRY_MS)
		end
	end, token)
	return true
end

-- Disable path used when the user is currently in (or transitioning into)
-- overview mode. The user wants to STAY in overview, so we leave the live
-- cameraRTS alone (vanilla's overview-close will reset it via
-- cameraRTS.SetProperties(1, defaults) at the tail of its transition) and only
-- clamp the saved return camera so the eventual exit lands at vanilla max.
local function ZoomPlus_StayInOverviewForDisable(original)
	-- Restore const.DefaultCameraRTS so vanilla overview-close eventually applies
	-- vanilla limits to the live camera. We must do this BEFORE the user exits
	-- overview, but it is safe to do it now while still in overview: const is a
	-- shared table, not the live camera.
	ZoomPlus_RestoreDefaultZoomOut()

	local restored_now = ZoomPlus_RestoreVanillaOverviewSavedCamera()
	local clamped_now = ZoomPlus_ClampOverviewSavedCameraToVanilla()
	local scheduled = false
	if not restored_now and not clamped_now then
		scheduled = ZoomPlus_ScheduleClampOverviewSavedCamera(original)
	end

	ZoomPlus_DebugDisable(
		"scenario_mode_disable",
		"stay_in_overview",
		true,
		"restored_now=" .. tostring(restored_now == true)
			.. "; clamped_now=" .. tostring(clamped_now == true)
			.. "; scheduled_deferred_clamp=" .. tostring(scheduled == true)
			.. "; vanilla_LookatDistZoomOut=" .. ZoomPlus_DebugValue(original and original.LookatDistZoomOut)
			.. "; live_cameraRTS_untouched=true",
		"stay_in_overview"
	)
	return true
end

local ZoomPlus_RunDisableEvaluation
local ZoomPlus_ScheduleDeferredDisableEvaluation

-- Re-run the disable rule decision tree given the live camera state at call
-- time. Used both immediately from ZP.Disable() (selection mode, no transition)
-- and from ZoomPlus_ScheduleDeferredDisableEvaluation when a non-overview
-- transition finishes.
ZoomPlus_RunDisableEvaluation = function(original, source)
	local mode_string = ZoomPlus_GetInterfaceMode()
	local overview_now = ZoomPlus_IsOverviewZoomActive() or mode_string == "overview"
	if overview_now then
		ZoomPlus_DebugDisable(
			"scenario_mode_disable",
			"evaluation_overview_now",
			true,
			"source=" .. tostring(source or "")
				.. "; mode=" .. ZoomPlus_DebugValue(mode_string),
			"eval:overview_now:" .. tostring(source or "")
		)
		return ZoomPlus_StayInOverviewForDisable(original)
	end

	local distance = select(1, ZoomPlus_CaptureLiveCameraView())
	local guim_value = rawget(_G, "guim") or 1000
	local vanilla_max = (tonumber(original.LookatDistZoomOut) or 0) * guim_value
	local beyond_vanilla = distance and vanilla_max > 0 and distance > vanilla_max

	ZoomPlus_DebugDisable(
		"scenario_mode_disable",
		"evaluation_decision",
		beyond_vanilla == true,
		"source=" .. tostring(source or "")
			.. "; mode=" .. ZoomPlus_DebugValue(mode_string)
			.. "; current_distance=" .. ZoomPlus_DebugValue(distance)
			.. "; vanilla_max=" .. ZoomPlus_DebugValue(vanilla_max)
			.. "; beyond_vanilla=" .. tostring(beyond_vanilla == true)
			.. "; vanilla_LookatDistZoomOut=" .. ZoomPlus_DebugValue(original.LookatDistZoomOut)
			.. "; guim=" .. ZoomPlus_DebugValue(guim_value),
		"eval:decision:" .. tostring(source or "")
	)

	if beyond_vanilla then
		if ZoomPlus_EnterOverviewModeForDisable("evaluation_" .. tostring(source or "beyond_vanilla")) then
			return true
		end
		ZoomPlus_DebugDisable(
			"scenario_mode_disable",
			"evaluation_enter_overview_failed_falling_back_to_preserve",
			false,
			"source=" .. tostring(source or "")
				.. "; current_distance=" .. ZoomPlus_DebugValue(distance)
				.. "; vanilla_max=" .. ZoomPlus_DebugValue(vanilla_max),
			"eval:enter_overview_failed:" .. tostring(source or "")
		)
	end

	return ZoomPlus_RestoreOriginalZoomPropertiesPreservingCamera(
		original,
		"preserve_zoom:" .. tostring(source or "")
	)
end

-- Wait for the active non-overview camera transition to end, then re-run the
-- disable rule decision tree against the post-transition camera state. This
-- avoids snapping cameraRTS in the middle of a transition (vanilla's transition
-- thread keeps writing camera properties; our SetProperties would race with it).
ZoomPlus_ScheduleDeferredDisableEvaluation = function(original)
	local create_thread = rawget(_G, "CreateRealTimeThread")
	local sleep = rawget(_G, "Sleep")
	if type(create_thread) ~= "function" or type(sleep) ~= "function" then
		ZoomPlus_DebugDisable(
			"scenario_mode_disable",
			"deferred_evaluation_unavailable_no_thread",
			false,
			"vanilla_LookatDistZoomOut=" .. ZoomPlus_DebugValue(original and original.LookatDistZoomOut),
			"deferred_eval:no_thread"
		)
		return ZoomPlus_RunDisableEvaluation(original, "deferred_no_thread_immediate")
	end

	local token = {}
	ZP.deferred_eval_token = token
	ZP.deferred_eval_original = ZoomPlus_CopyTable(original)

	ZoomPlus_DebugDisable(
		"scenario_mode_disable",
		"deferred_evaluation_started",
		true,
		"vanilla_LookatDistZoomOut=" .. ZoomPlus_DebugValue(original.LookatDistZoomOut)
			.. "; retry_ms=" .. tostring(ZOOM_RESTORE_RETRY_MS)
			.. "; retry_count=" .. tostring(ZOOM_RESTORE_RETRY_COUNT),
		"deferred_eval:start"
	)

	pcall(create_thread, function(thread_token)
		local attempts = 0
		while ZP.deferred_eval_token == thread_token do
			if not ZoomPlus_IsCameraTransitionActive() then
				local current_original = ZP.deferred_eval_original or original
				ZP.deferred_eval_token = false
				ZP.deferred_eval_original = false
				ZoomPlus_RunDisableEvaluation(current_original, "deferred_after_transition")
				return
			end
			attempts = attempts + 1
			if attempts >= ZOOM_RESTORE_RETRY_COUNT then
				local current_original = ZP.deferred_eval_original or original
				ZP.deferred_eval_token = false
				ZP.deferred_eval_original = false
				ZoomPlus_RunDisableEvaluation(current_original, "deferred_eval_timeout")
				return
			end
			sleep(ZOOM_RESTORE_RETRY_MS)
		end
	end, token)
	return true
end

-- ---------------------------------------------------------------------------
-- Public Zoom+ controls
-- ---------------------------------------------------------------------------

-- Apply Zoom+ to the RTS camera properties.
function ZP.Enable(preserve_camera)
	if not ZoomPlus_CanModifyCamera() then
		ZP.enabled = false
		ZoomPlus_RestoreDefaultZoomOut()
		ZoomPlus_RemoveOverviewReturnCameraHook()
		ZoomPlus_RemoveZoomOutOverviewTriggerHook()
		ZoomPlus_DebugEnable(
			"scenario_mode_enable",
			"camera_modification_blocked",
			false,
			"preserve_camera=" .. tostring(preserve_camera),
			"enable:no_modify"
		)
		return false
	end
	local original = ZoomPlus_CaptureOriginalZoomProperties()
	if not original or type(original.LookatDistZoomOut) ~= "number" then
		ZoomPlus_Debug("enable", ZP, "capture_original_failed", false, ZoomPlus_DebugPropsSummary(original))
		ZoomPlus_DebugEnable(
			"scenario_mode_enable",
			"capture_original_failed",
			false,
			"preserve_camera=" .. tostring(preserve_camera),
			"enable:capture_failed"
		)
		return false
	end

	ZoomPlus_InstallOverviewReturnCameraHook()
	ZoomPlus_InstallZoomOutOverviewTriggerHook()
	local multiplier = ZP.GetMultiplier()
	local props = ZoomPlus_CopyTable(original)
	-- Zoom+ intentionally changes only zoom-out; zoom-in and overview exit targeting stay vanilla.
	props.LookatDistZoomOut = original.LookatDistZoomOut * multiplier
	ZoomPlus_SetDefaultZoomOut(props.LookatDistZoomOut)

	ZP.last_multiplier = multiplier
	ZP.last_zoom_out = props.LookatDistZoomOut
	ZP.enabled = true

	local mode_string = ZoomPlus_GetInterfaceMode()
	local overview_active = ZoomPlus_IsOverviewZoomActive() or mode_string == "overview"
	local transition_active = ZoomPlus_IsCameraTransitionActive()

	ZoomPlus_DebugEnable(
		"scenario_mode_enable",
		"entry_state",
		true,
		"overview_active=" .. tostring(overview_active == true)
			.. "; mode=" .. ZoomPlus_DebugValue(mode_string)
			.. "; transition_active=" .. tostring(transition_active == true)
			.. "; preserve_camera=" .. tostring(preserve_camera)
			.. "; vanilla_LookatDistZoomOut=" .. ZoomPlus_DebugValue(original.LookatDistZoomOut)
			.. "; new_LookatDistZoomOut=" .. ZoomPlus_DebugValue(props.LookatDistZoomOut),
		"enable:entry"
	)

	-- CASE 1: User is in overview. Don't touch live cameraRTS or call SetProperties:
	-- vanilla freezes the camera through the overview transition and re-deriving
	-- eye distance from ZoomStep mid-overview would cause a visible jump. Just
	-- patch const.DefaultCameraRTS (already done above) and cache the saved
	-- camera so the disable path can clamp it back to vanilla on exit.
	if overview_active then
		local cached = ZoomPlus_CacheVanillaOverviewSavedCamera()
		ZoomPlus_Debug(
			"enable",
			ZP,
			"overview_cache_saved_camera",
			true,
			"cached=" .. tostring(cached == true) .. "; " .. ZoomPlus_DebugPropsSummary(props)
		)
		ZoomPlus_DebugEnable(
			"scenario_mode_enable",
			"overview_active_cache_only",
			true,
			"cached_saved_camera=" .. tostring(cached == true)
				.. "; live_cameraRTS_untouched=true",
			"enable:overview"
		)
		return true
	end

	-- CASE 2: A non-overview camera transition is in flight. Don't write camera
	-- properties in the middle of a transition: the transition thread is mutating
	-- camera state every frame; a SetProperties race would either be lost or
	-- produce a visible snap. const has already been patched, so the new far
	-- limit is in effect for any post-transition zoom.
	if transition_active then
		ZoomPlus_Debug(
			"enable",
			ZP,
			"defer_set_properties_while_transition_active",
			true,
			"preserve_camera=" .. tostring(preserve_camera) .. "; " .. ZoomPlus_DebugPropsSummary(props)
		)
		ZoomPlus_DebugEnable(
			"scenario_mode_enable",
			"defer_during_transition",
			true,
			"live_cameraRTS_untouched=true; const_already_patched=true",
			"enable:transition"
		)
		return true
	end

	-- CASE 3: Selection mode, no transition. Apply the new properties live, but
	-- snapshot the current eye/lookat FIRST and reapply them AFTER SetProperties
	-- so the user keeps the exact viewpoint they had at the moment scenario mode
	-- was enabled. Without this snapshot/restore, cameraRTS.SetProperties re-
	-- derives the live eye distance from ZoomStep * (LookatDistZoomOut -
	-- LookatDistZoomIn); raising LookatDistZoomOut by the multiplier therefore
	-- pushes the camera back automatically (the "auto zoom-out on enable" the
	-- user reported). The snapshot/restore costs one extra SetCamera(eye, lookat,
	-- 0) and is invisible because it lands at the original viewpoint.
	local pre_distance, pre_eye, pre_lookat
	if preserve_camera then
		pre_distance, pre_eye, pre_lookat = ZoomPlus_CaptureLiveCameraView()
	end

	if not ZoomPlus_SetRTSCameraZoomProperties(props) then
		ZP.enabled = false
		ZoomPlus_RestoreDefaultZoomOut()
		ZoomPlus_RemoveOverviewReturnCameraHook()
		ZoomPlus_RemoveZoomOutOverviewTriggerHook()
		ZoomPlus_Debug("enable", ZP, "apply_zoom_plus_properties", false, ZoomPlus_DebugPropsSummary(props))
		ZoomPlus_DebugEnable(
			"scenario_mode_enable",
			"set_properties_failed",
			false,
			"preserve_camera=" .. tostring(preserve_camera)
				.. "; pre_distance=" .. ZoomPlus_DebugValue(pre_distance),
			"enable:set_properties_failed"
		)
		return false
	end

	if preserve_camera then
		local snapshot_ok = pre_eye and pre_lookat and true or false
		local reapplied = snapshot_ok and ZoomPlus_ApplyCapturedCameraView(pre_eye, pre_lookat) or false
		local success = (not snapshot_ok) or reapplied
		ZoomPlus_Debug(
			"enable",
			ZP,
			"apply_zoom_plus_properties_preserving_camera",
			success,
			"preserve_camera=" .. tostring(preserve_camera)
				.. "; pre_distance=" .. ZoomPlus_DebugValue(pre_distance)
				.. "; reapplied=" .. tostring(reapplied == true)
				.. "; " .. ZoomPlus_DebugPropsSummary(props)
		)
		ZoomPlus_DebugEnable(
			"scenario_mode_enable",
			"selection_preserve_eye_lookat",
			success,
			"snapshot_ok=" .. tostring(snapshot_ok)
				.. "; pre_distance=" .. ZoomPlus_DebugValue(pre_distance)
				.. "; set_props_ok=true"
				.. "; reapplied_camera=" .. tostring(reapplied == true),
			"enable:selection_preserve"
		)
	else
		local reapplied = ZoomPlus_ReapplyCurrentCameraForZoomProperties()
		ZoomPlus_Debug(
			"enable",
			ZP,
			"reapply_current_camera",
			reapplied,
			"preserve_camera=" .. tostring(preserve_camera) .. "; " .. ZoomPlus_DebugPropsSummary(props)
		)
		ZoomPlus_DebugEnable(
			"scenario_mode_enable",
			"selection_reapply_current",
			reapplied == true,
			"reapplied_camera=" .. tostring(reapplied == true),
			"enable:selection_reapply"
		)
	end
	return true
end

-- Restore the RTS camera zoom properties captured before Zoom+. Dispatches to
-- one of four cases:
--   1. No captured original         → strip hooks/diagnostics and bail.
--   2. Overview active (or mode==overview) at disable time
--                                   → STAY in overview; clamp saved_camera.
--   3. Non-overview transition active
--                                   → defer evaluation until transition ends.
--   4. Selection mode, no transition → run rule decision now (preserve current
--                                       zoom, or enter overview if the user is
--                                       beyond vanilla's far limit).
function ZP.Disable()
	local original = ZP.original_properties
	if not original then
		ZP.enabled = false
		ZP.deferred_restore_token = false
		ZP.deferred_restore_original = false
		ZP.deferred_eval_token = false
		ZP.deferred_eval_original = false
		ZP.deferred_clamp_token = false
		ZoomPlus_RestoreDefaultZoomOut()
		ZoomPlus_ClearTransientState()
		ZoomPlus_RemoveOverviewReturnCameraHook()
		ZoomPlus_RemoveZoomOutOverviewTriggerHook()
		-- Always strip diagnostic wrappers on disable: leaving them installed makes
		-- vanilla overview zoom-in stutter during the transition (every frame logs).
		ZoomPlus_RemoveVanillaOverviewDiagnostics()
		ZoomPlus_Debug("disable", ZP, "no_original_properties", true, "", "disable_no_original", true)
		ZoomPlus_DebugDisable(
			"scenario_mode_disable",
			"no_original_properties",
			true,
			"zp_enabled_was=false; nothing_to_restore=true",
			"disable:no_original"
		)
		return true
	end

	-- Mark Zoom+ disabled and detach its hooks/diagnostics first so subsequent
	-- state checks read the live engine state, not Zoom+ wrappers.
	ZP.enabled = false
	ZoomPlus_RemoveOverviewReturnCameraHook()
	ZoomPlus_RemoveZoomOutOverviewTriggerHook()
	ZoomPlus_RemoveVanillaOverviewDiagnostics()

	-- Cancel any in-flight deferred work from a previous disable so the new
	-- evaluation owns the camera restoration end-to-end.
	ZP.deferred_restore_token = false
	ZP.deferred_restore_original = false
	ZP.deferred_eval_token = false
	ZP.deferred_eval_original = false
	ZP.deferred_clamp_token = false

	local mode_string = ZoomPlus_GetInterfaceMode()
	local overview_active = ZoomPlus_IsOverviewZoomActive() or mode_string == "overview"
	local transition_active = ZoomPlus_IsCameraTransitionActive()

	ZoomPlus_DebugDisable(
		"scenario_mode_disable",
		"entry_state",
		true,
		"overview_active=" .. tostring(overview_active == true)
			.. "; mode=" .. ZoomPlus_DebugValue(mode_string)
			.. "; transition_active=" .. tostring(transition_active == true)
			.. "; vanilla_LookatDistZoomOut=" .. ZoomPlus_DebugValue(original.LookatDistZoomOut),
		"disable:entry"
	)

	-- CASE 2: User is in overview (or transitioning into overview). Stay there.
	-- Vanilla's overview-close will reset live cameraRTS at the tail of its
	-- transition; we only need to clamp saved_camera so that exit lands at
	-- vanilla max instead of the Zoom+ extended distance.
	if overview_active then
		ZoomPlus_ClearTransientState()
		return ZoomPlus_StayInOverviewForDisable(original)
	end

	-- CASE 3: A non-overview camera transition is in flight. Defer evaluation
	-- until it ends so we read a stable post-transition camera state.
	if transition_active then
		ZoomPlus_ClearTransientState()
		return ZoomPlus_ScheduleDeferredDisableEvaluation(original)
	end

	-- CASE 4: Selection mode, no transition. Run the rule decision now.
	ZoomPlus_ClearTransientState()
	return ZoomPlus_RunDisableEvaluation(original, "selection_immediate")
end

-- Toggle Zoom+ mode and return a human-readable status string.
function ZP.Toggle()
	if ZP.enabled then
		return ZP.Disable() and ZoomPlus_Status("disabled") or "zoom+ disable failed"
	end
	return ZP.Enable() and ZoomPlus_Status("enabled") or "zoom+ enable failed"
end

-- Return whether Zoom+ mode is active.
function ZP.IsEnabled()
	return ZP.enabled and ZoomPlus_CanModifyCamera() and true or false
end

local function ZoomPlus_SetPropertiesArgsSummary(first, second, third)
	local props = type(third) == "table" and third
		or type(second) == "table" and second
		or type(first) == "table" and first
		or false
	return "args=" .. ZoomPlus_DebugValue(first)
		.. "," .. ZoomPlus_DebugValue(second)
		.. "," .. ZoomPlus_DebugValue(third)
		.. "; arg_props{" .. ZoomPlus_DebugPropsSummary(props) .. "}"
end

ZoomPlus_InstallVanillaOverviewDiagnostics = function(reason)
	if not ZoomPlus_DebugEnabled(true) then
		return false
	end

	ZP.vanilla_diagnostics_armed = true
	local installed = false
	local overview = rawget(_G, "OverviewModeDialog")
	if type(overview) == "table" then
		if
			type(overview.CheckBelowZoomLimit) == "function"
			and overview.CheckBelowZoomLimit ~= ZP.vanilla_diag_check_below_zoom_limit_wrapper
		then
			ZP.vanilla_diag_original_check_below_zoom_limit = overview.CheckBelowZoomLimit
			ZP.vanilla_diag_check_below_zoom_limit_wrapper = function(self, ...)
				local should_log = ZoomPlus_ShouldLogVanillaDiagnostics()
				if should_log then
					ZoomPlus_Debug(
						"vanilla_overview_zoom_in",
						self,
						"CheckBelowZoomLimit before",
						true,
						ZoomPlus_DebugOverviewExtra(self, "reason=" .. tostring(reason or "")),
						nil,
						true
					)
				end
				local result, r2, r3, r4 = ZP.vanilla_diag_original_check_below_zoom_limit(self, ...)
				if should_log then
					ZoomPlus_Debug(
						"vanilla_overview_zoom_in",
						self,
						"CheckBelowZoomLimit after",
						true,
						"result=" .. ZoomPlus_DebugValue(result)
							.. "; " .. ZoomPlus_DebugOverviewExtra(self, ""),
						nil,
						true
					)
				end
				return result, r2, r3, r4
			end
			overview.CheckBelowZoomLimit = ZP.vanilla_diag_check_below_zoom_limit_wrapper
			installed = true
		end

		if type(overview.Close) == "function" and overview.Close ~= ZP.vanilla_diag_close_wrapper then
			ZP.vanilla_diag_original_close = overview.Close
			ZP.vanilla_diag_close_wrapper = function(self, ...)
				local should_log = ZoomPlus_ShouldLogVanillaDiagnostics()
				if should_log then
					ZoomPlus_Debug(
						"vanilla_overview_close",
						self,
						"OverviewModeDialog.Close before",
						true,
						ZoomPlus_DebugOverviewExtra(self, "reason=" .. tostring(reason or "")),
						nil,
						true
					)
				end
				local result, r2, r3, r4 = ZP.vanilla_diag_original_close(self, ...)
				if should_log then
					ZoomPlus_Debug(
						"vanilla_overview_close",
						self,
						"OverviewModeDialog.Close after",
						true,
						"result=" .. ZoomPlus_DebugValue(result)
							.. "; " .. ZoomPlus_DebugOverviewExtra(self, ""),
						nil,
						true
					)
				end
				return result, r2, r3, r4
			end
			overview.Close = ZP.vanilla_diag_close_wrapper
			installed = true
		end
	end

	local camera_rts = ZoomPlus_GetRTSCamera()
	if
		camera_rts
		and type(camera_rts.SetProperties) == "function"
		and camera_rts.SetProperties ~= ZP.vanilla_diag_camera_set_properties_wrapper
	then
		ZP.vanilla_diag_original_camera_set_properties = camera_rts.SetProperties
		ZP.vanilla_diag_camera_set_properties_wrapper = function(first, second, third, ...)
			local should_log = ZoomPlus_ShouldLogVanillaDiagnostics()
			if should_log then
				ZoomPlus_Debug(
					"vanilla_camera_set_properties",
					camera_rts,
					"cameraRTS.SetProperties before",
					true,
					ZoomPlus_SetPropertiesArgsSummary(first, second, third)
						.. "; " .. ZoomPlus_DebugCameraTablesSummary(),
					nil,
					true
				)
			end
			local result, r2, r3, r4 = ZP.vanilla_diag_original_camera_set_properties(first, second, third, ...)
			if should_log then
				ZoomPlus_Debug(
					"vanilla_camera_set_properties",
					camera_rts,
					"cameraRTS.SetProperties after",
					true,
					"result=" .. ZoomPlus_DebugValue(result)
						.. "; " .. ZoomPlus_DebugCameraTablesSummary(),
					nil,
					true
				)
			end
			return result, r2, r3, r4
		end
		camera_rts.SetProperties = ZP.vanilla_diag_camera_set_properties_wrapper
		installed = true
	end

	local igi_class = rawget(_G, "InGameInterface")
	if
		type(igi_class) == "table"
		and type(igi_class.SetMode) == "function"
		and igi_class.SetMode ~= ZP.vanilla_diag_igi_set_mode_wrapper
	then
		ZP.vanilla_diag_original_igi_set_mode = igi_class.SetMode
		ZP.vanilla_diag_igi_set_mode_wrapper = function(self, mode, context, ...)
			local should_log = ZoomPlus_ShouldLogVanillaDiagnostics()
			if should_log then
				ZoomPlus_Debug(
					"vanilla_interface_set_mode",
					self,
					"InGameInterface.SetMode before",
					true,
					"target_mode=" .. ZoomPlus_DebugValue(mode)
						.. "; context=" .. ZoomPlus_DebugUiLabel(context)
						.. "; " .. ZoomPlus_DebugCameraTablesSummary(),
					nil,
					true
				)
			end
			local result, r2, r3, r4 = ZP.vanilla_diag_original_igi_set_mode(self, mode, context, ...)
			if should_log then
				ZoomPlus_Debug(
					"vanilla_interface_set_mode",
					self,
					"InGameInterface.SetMode after",
					true,
					"target_mode=" .. ZoomPlus_DebugValue(mode)
						.. "; result=" .. ZoomPlus_DebugValue(result)
						.. "; " .. ZoomPlus_DebugCameraTablesSummary(),
					nil,
					true
				)
			end
			return result, r2, r3, r4
		end
		igi_class.SetMode = ZP.vanilla_diag_igi_set_mode_wrapper
		installed = true
	end

	ZoomPlus_Debug(
		"diagnostics",
		ZP,
		"install_vanilla_overview_diagnostics",
		installed,
		"reason=" .. tostring(reason or "") .. "; " .. ZoomPlus_DebugCameraTablesSummary(),
		"install_vanilla_overview_diagnostics",
		true
	)
	return installed
end

ZoomPlus_RemoveVanillaOverviewDiagnostics = function()
	local restored_check_below = false
	local restored_close = false
	local restored_set_properties = false
	local restored_set_mode = false
	local overview = rawget(_G, "OverviewModeDialog")
	if type(overview) == "table" then
		if
			ZP.vanilla_diag_check_below_zoom_limit_wrapper
			and overview.CheckBelowZoomLimit == ZP.vanilla_diag_check_below_zoom_limit_wrapper
		then
			overview.CheckBelowZoomLimit = ZP.vanilla_diag_original_check_below_zoom_limit
			restored_check_below = true
		end
		if ZP.vanilla_diag_close_wrapper and overview.Close == ZP.vanilla_diag_close_wrapper then
			overview.Close = ZP.vanilla_diag_original_close
			restored_close = true
		end
	end

	local camera_rts = ZoomPlus_GetRTSCamera()
	if
		camera_rts
		and ZP.vanilla_diag_camera_set_properties_wrapper
		and camera_rts.SetProperties == ZP.vanilla_diag_camera_set_properties_wrapper
	then
		camera_rts.SetProperties = ZP.vanilla_diag_original_camera_set_properties
		restored_set_properties = true
	end

	local igi_class = rawget(_G, "InGameInterface")
	if
		type(igi_class) == "table"
		and ZP.vanilla_diag_igi_set_mode_wrapper
		and igi_class.SetMode == ZP.vanilla_diag_igi_set_mode_wrapper
	then
		igi_class.SetMode = ZP.vanilla_diag_original_igi_set_mode
		restored_set_mode = true
	end

	if restored_check_below then
		ZP.vanilla_diag_original_check_below_zoom_limit = nil
		ZP.vanilla_diag_check_below_zoom_limit_wrapper = nil
	end
	if restored_close then
		ZP.vanilla_diag_original_close = nil
		ZP.vanilla_diag_close_wrapper = nil
	end
	if restored_set_properties then
		ZP.vanilla_diag_original_camera_set_properties = nil
		ZP.vanilla_diag_camera_set_properties_wrapper = nil
	end
	if restored_set_mode then
		ZP.vanilla_diag_original_igi_set_mode = nil
		ZP.vanilla_diag_igi_set_mode_wrapper = nil
	end
	ZP.vanilla_diagnostics_armed = false
	return true
end

-- ---------------------------------------------------------------------------
-- Hook installation
-- ---------------------------------------------------------------------------

-- Install overview-exit hooks that adjust only the saved return distance, never the saved lookat.
ZoomPlus_InstallOverviewReturnCameraHook = function()
	local overview = rawget(_G, "OverviewModeDialog")
	if type(overview) ~= "table" or type(overview.Close) ~= "function" then
		return false
	end
	if ZP.overview_close_chained then
		if ZP.overview_close_wrapper and overview.Close == ZP.overview_close_wrapper then
			return true
		end
		ZoomPlus_RemoveOverviewReturnCameraHook()
	end

	ZP.original_overview_close = overview.Close
	ZP.overview_close_wrapper = function(self, ...)
		local first_exit_takeover_armed = ZoomPlus_ArmFirstOverviewExitTakeover(self)
		ZoomPlus_PreAimOverviewExit(self, first_exit_takeover_armed)
		ZoomPlus_ApplyOverviewReturnCamera(self)
		return ZP.original_overview_close(self, ...)
	end
	overview.Close = ZP.overview_close_wrapper
	if type(overview.CheckBelowZoomLimit) == "function" then
		ZP.original_overview_check_below_zoom_limit = overview.CheckBelowZoomLimit
		ZP.overview_check_below_zoom_limit_wrapper = function(self, ...)
			local adjusted = ZoomPlus_ApplyOverviewReturnCamera(self)
			local result = ZP.original_overview_check_below_zoom_limit(self, ...)
			ZoomPlus_Debug(
				"mouse_wheel_zoom_in",
				self,
				"overview_check_below_limit",
				result == "break",
				"return_camera_adjusted=" .. tostring(adjusted == true)
					.. "; result=" .. ZoomPlus_DebugValue(result)
			)
			return result
		end
		overview.CheckBelowZoomLimit = ZP.overview_check_below_zoom_limit_wrapper
	end

	ZP.overview_close_chained = true
	return true
end

ZoomPlus_RemoveOverviewReturnCameraHook = function()
	local overview = rawget(_G, "OverviewModeDialog")
	if type(overview) ~= "table" then
		return false
	end
	if ZP.overview_close_chained and type(ZP.original_overview_close) == "function" then
		if not ZP.overview_close_wrapper or overview.Close == ZP.overview_close_wrapper then
			overview.Close = ZP.original_overview_close
		end
	end
	if type(ZP.original_overview_check_below_zoom_limit) == "function" then
		if
			not ZP.overview_check_below_zoom_limit_wrapper
			or overview.CheckBelowZoomLimit == ZP.overview_check_below_zoom_limit_wrapper
		then
			overview.CheckBelowZoomLimit = ZP.original_overview_check_below_zoom_limit
		end
	end
	ZP.original_overview_close = nil
	ZP.original_overview_check_below_zoom_limit = nil
	ZP.overview_close_wrapper = nil
	ZP.overview_check_below_zoom_limit_wrapper = nil
	ZP.overview_close_chained = false
	return true
end

-- Let repeated zoom-out enter overview after the Zoom+ far limit is reached.
ZoomPlus_InstallZoomOutOverviewTriggerHook = function()
	local selection = rawget(_G, "SelectionModeDialog")
	if type(selection) ~= "table" or type(selection.CheckAboveZoomLimit) ~= "function" then
		return false
	end
	if ZP.selection_zoom_out_chained then
		if ZP.selection_check_above_zoom_limit_wrapper
			and selection.CheckAboveZoomLimit == ZP.selection_check_above_zoom_limit_wrapper
		then
			return true
		end
		ZoomPlus_RemoveZoomOutOverviewTriggerHook()
	end

	ZP.original_selection_check_above_zoom_limit = selection.CheckAboveZoomLimit
	ZP.selection_check_above_zoom_limit_wrapper = function(self, ...)
		if not ZoomPlus_ShouldApplyZoomPlusCamera() then
			return ZP.original_selection_check_above_zoom_limit(self, ...)
		end

		local editor_state = rawget(_G, "editor")
		local camera_rts = ZoomPlus_GetRTSCamera()
		local current_map = rawget(_G, "CurrentMap")
		local changing_map = rawget(_G, "ChangingMap")
		if editor_state and editor_state.Active or rawget(_G, "CameraTransitionThread") or changing_map then
			local result = ZP.original_selection_check_above_zoom_limit(self, ...)
			ZoomPlus_Debug(
				"mouse_wheel_zoom_out",
				self,
				"selection_original_blocked_by_editor_or_transition",
				result == "break",
				"result=" .. ZoomPlus_DebugValue(result)
			)
			return result
		end
		if not camera_rts or type(camera_rts.IsActive) ~= "function" or not camera_rts.IsActive() then
			local result = ZP.original_selection_check_above_zoom_limit(self, ...)
			ZoomPlus_Debug(
				"mouse_wheel_zoom_out",
				self,
				"selection_original_camera_inactive",
				result == "break",
				"result=" .. ZoomPlus_DebugValue(result)
			)
			return result
		end
		if not current_map or not current_map.mapdata or not current_map.mapdata.IsAllowedToEnterOverview then
			local result = ZP.original_selection_check_above_zoom_limit(self, ...)
			ZoomPlus_Debug(
				"mouse_wheel_zoom_out",
				self,
				"selection_original_overview_not_allowed",
				result == "break",
				"result=" .. ZoomPlus_DebugValue(result)
			)
			return result
		end
		if type(self.AllowExitToOverview) == "function" and not self:AllowExitToOverview() then
			local result = ZP.original_selection_check_above_zoom_limit(self, ...)
			ZoomPlus_Debug(
				"mouse_wheel_zoom_out",
				self,
				"selection_original_exit_to_overview_disallowed",
				result == "break",
				"result=" .. ZoomPlus_DebugValue(result)
			)
			return result
		end

		local get_zoom_limits = camera_rts.GetZoomLimits
		local get_zoom = camera_rts.GetZoom
		if type(get_zoom_limits) ~= "function" or type(get_zoom) ~= "function" then
			local result = ZP.original_selection_check_above_zoom_limit(self, ...)
			ZoomPlus_Debug(
				"mouse_wheel_zoom_out",
				self,
				"selection_original_zoom_api_missing",
				result == "break",
				"result=" .. ZoomPlus_DebugValue(result)
			)
			return result
		end

		local _, max_zoom = get_zoom_limits()
		local zoom = get_zoom() * 1000
		if type(max_zoom) == "number" and zoom >= max_zoom then
			local now_fn = rawget(_G, "now")
			local t = type(now_fn) == "function" and now_fn() or 0
			if t - (ZP.last_overview_zoom_out or 0) < ZOOM_OUT_OVERVIEW_REPEAT_MS then
				ZP.overview_zoom_out_count = (ZP.overview_zoom_out_count or 0) + 1
			else
				ZP.overview_zoom_out_count = 1
			end
			ZP.last_overview_zoom_out = t
			if ZP.overview_zoom_out_count > ZOOM_OUT_OVERVIEW_REPEAT_COUNT and self.parent then
				self.parent:SetMode("overview")
				ZoomPlus_Debug(
					"mouse_wheel_zoom_out",
					self,
					"selection_enter_overview_after_repeat",
					true,
					"zoom=" .. ZoomPlus_DebugValue(zoom)
						.. "; max_zoom=" .. ZoomPlus_DebugValue(max_zoom)
						.. "; count=" .. ZoomPlus_DebugValue(ZP.overview_zoom_out_count)
				)
				return "break"
			end
		end

		local result = ZP.original_selection_check_above_zoom_limit(self, ...)
		ZoomPlus_Debug(
			"mouse_wheel_zoom_out",
			self,
			"selection_original_after_zoom_plus_limit_check",
			result == "break",
			"zoom=" .. ZoomPlus_DebugValue(zoom)
				.. "; max_zoom=" .. ZoomPlus_DebugValue(max_zoom)
				.. "; count=" .. ZoomPlus_DebugValue(ZP.overview_zoom_out_count)
				.. "; result=" .. ZoomPlus_DebugValue(result)
		)
		return result
	end
	selection.CheckAboveZoomLimit = ZP.selection_check_above_zoom_limit_wrapper

	ZP.selection_zoom_out_chained = true
	return true
end

ZoomPlus_RemoveZoomOutOverviewTriggerHook = function()
	local selection = rawget(_G, "SelectionModeDialog")
	if type(selection) ~= "table" then
		return false
	end
	if ZP.selection_zoom_out_chained and type(ZP.original_selection_check_above_zoom_limit) == "function" then
		if
			not ZP.selection_check_above_zoom_limit_wrapper
			or selection.CheckAboveZoomLimit == ZP.selection_check_above_zoom_limit_wrapper
		then
			selection.CheckAboveZoomLimit = ZP.original_selection_check_above_zoom_limit
		end
	end
	ZP.original_selection_check_above_zoom_limit = nil
	ZP.selection_check_above_zoom_limit_wrapper = nil
	ZP.selection_zoom_out_chained = false
	return true
end

-- Reapply Zoom+ after map or camera resets.
function ZP.Reapply()
	if not ZoomPlus_CanModifyCamera() then
		return true
	end
	if not ZP.enabled then
		ZoomPlus_Debug("reapply", ZP, "skip_zoom_plus_disabled", true, "")
		return true
	end
	if ZoomPlus_IsCameraTransitionActive() then
		ZoomPlus_Debug("reapply", ZP, "skip_while_transition_active", true, "")
		return true
	end
	if ZoomPlus_IsOverviewZoomActive() then
		ZoomPlus_Debug("reapply", ZP, "skip_while_overview_active", true, "")
		return true
	end
	local camera_rts = ZoomPlus_GetRTSCamera()
	if camera_rts and type(camera_rts.IsMoving) == "function" and camera_rts.IsMoving() then
		ZoomPlus_Debug("reapply", ZP, "skip_while_camera_moving", true, "")
		return true
	end
	local ok = ZP.Enable("preserve camera")
	ZoomPlus_Debug("reapply", ZP, "enable_preserve_camera", ok, "")
	return ok
end

ZoomPlus_RemoveWheelEventDebugHook = function()
	local x_desktop = rawget(_G, "XDesktop")
	if type(x_desktop) ~= "table" then
		return false
	end
	if ZP.wheel_event_debug_chained and type(ZP.original_xdesktop_mouse_event) == "function" then
		if not ZP.debug_xdesktop_mouse_event_wrapper or x_desktop.MouseEvent == ZP.debug_xdesktop_mouse_event_wrapper then
			x_desktop.MouseEvent = ZP.original_xdesktop_mouse_event
		end
	end
	ZP.debug_xdesktop_mouse_event_wrapper = nil
	ZP.original_xdesktop_mouse_event = nil
	ZP.wheel_event_debug_chained = false
	return true
end

-- Public access to the diagnostic-wrapper removal. Called from the Scenario Editor
-- mode-exit path to guarantee no Zoom+ wrapper outlives a scenario session.
function ZP.RemoveDiagnosticWrappers()
	return ZoomPlus_RemoveVanillaOverviewDiagnostics()
end

-- Initialize Zoom+ lifecycle hooks.
function ZP.Init()
	ZoomPlus_RemoveWheelEventDebugHook()
	-- Diagnostics are opt-in only; never auto-reinstall them at init time. A separate
	-- explicit ZP.RemoveDiagnosticWrappers() / ZoomPlus_InstallVanillaOverviewDiagnostics()
	-- call must be made by debugging code if it wants the verbose wrappers back.
	ZoomPlus_RemoveVanillaOverviewDiagnostics()
	if not ZoomPlus_CanModifyCamera() then
		if ZP.enabled then
			ZP.Disable()
		else
			ZoomPlus_RestoreDefaultZoomOut()
		end
		ZoomPlus_RemoveOverviewReturnCameraHook()
		ZoomPlus_RemoveZoomOutOverviewTriggerHook()
	end
	return true
end

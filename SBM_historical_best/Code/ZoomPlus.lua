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

-- Optional, host-supplied observational callback. Keeping this as a plain Config
-- callback preserves ZoomPlus as a self-contained module with no SuperBigMap dependency.
local function ZoomPlus_Audit(event, data)
	local audit = type(ZP.Config) == "table" and ZP.Config.AUDIT or nil
	if type(audit) == "function" then
		pcall(audit, event, data or {})
	end
end

local function ZoomPlus_CanModifyCamera()
	-- Super Big Map owns this instance and decides when it is enabled/disabled (the
	-- integration disables it where vanilla camera is wanted, e.g. the editor), so the
	-- camera may always be modified while ZoomPlus is enabled.
	return true
end

local function ZoomPlus_ShouldApplyZoomPlusCamera()
	return ZP.enabled == true and ZoomPlus_CanModifyCamera()
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
			return defaults
		end
	end
	return props or defaults
end

-- Store the original RTS camera properties once. Keep the full table: the engine uses
-- fields such as ZoomStep/ZoomTime for normal mouse-wheel zoom.
local function ZoomPlus_CaptureOriginalZoomProperties()
	local defaults = ZoomPlus_GetDefaultRTSCameraProperties()
	local default_zoom_out = defaults and tonumber(defaults.LookatDistZoomOut) or nil
	local preserved_default = tonumber(ZP.original_default_zoom_out)
	local baseline_zoom_out = preserved_default or default_zoom_out
	local baseline_source = preserved_default and "captured_default" or "const_default"
	local actual_live = ZoomPlus_GetRTSCameraProperties()
	local live = ZoomPlus_GetNormalRTSCameraProperties()
	local live_zoom_out = type(actual_live) == "table" and tonumber(actual_live.LookatDistZoomOut) or nil
	local candidate_zoom_out = type(live) == "table" and tonumber(live.LookatDistZoomOut) or nil

	if ZP.original_properties then
		local normalized = ZoomPlus_NormalizeCameraProperties(ZP.original_properties)
		if normalized and type(normalized.LookatDistZoomOut) == "number" then
			-- A save resumed in overview can expose the temporary live overview limit
			-- (20000) before the interface reports overview mode. Never preserve that as
			-- the normal baseline: the stable default is the vanilla selection limit (600).
			if type(baseline_zoom_out) == "number" and baseline_zoom_out > 0 then
				normalized.LookatDistZoomOut = baseline_zoom_out
			end
			ZP.original_properties = normalized
			ZP.last_capture_live_zoom_out = live_zoom_out
			ZP.last_capture_default_zoom_out = default_zoom_out
			ZP.last_capture_baseline_zoom_out = normalized.LookatDistZoomOut
			ZP.last_capture_baseline_source = baseline_source .. ":repair_existing"
			ZoomPlus_Audit("BASELINE_CAPTURE", {
				live_zoom_out = live_zoom_out,
				candidate_zoom_out = candidate_zoom_out,
				default_zoom_out = default_zoom_out,
				baseline_zoom_out = normalized.LookatDistZoomOut,
				baseline_source = ZP.last_capture_baseline_source,
			})
			return ZP.original_properties
		end
	end

	local props = ZoomPlus_NormalizeCameraProperties(live)
	if not props or type(props.LookatDistZoomOut) ~= "number" then
		ZoomPlus_Audit("BASELINE_CAPTURE_FAILED", {
			live_zoom_out = live_zoom_out,
			candidate_zoom_out = candidate_zoom_out,
			default_zoom_out = default_zoom_out,
		})
		return false
	end

	if type(baseline_zoom_out) == "number" and baseline_zoom_out > 0 then
		props.LookatDistZoomOut = baseline_zoom_out
	end
	ZP.original_properties = props
	ZP.last_capture_live_zoom_out = live_zoom_out
	ZP.last_capture_default_zoom_out = default_zoom_out
	ZP.last_capture_baseline_zoom_out = props.LookatDistZoomOut
	ZP.last_capture_baseline_source = baseline_source
	ZoomPlus_Audit("BASELINE_CAPTURE", {
		live_zoom_out = live_zoom_out,
		candidate_zoom_out = candidate_zoom_out,
		default_zoom_out = default_zoom_out,
		baseline_zoom_out = props.LookatDistZoomOut,
		baseline_source = baseline_source,
	})
	return ZP.original_properties
end

-- Apply the requested RTS camera property values.
local function ZoomPlus_SetRTSCameraZoomProperties(props)
	local camera_rts = ZoomPlus_GetRTSCamera()
	if not camera_rts or type(camera_rts.SetProperties) ~= "function" or type(props) ~= "table" then
		return false
	end
	local ok = pcall(camera_rts.SetProperties, 1, props)
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

	local create_thread = rawget(_G, "CreateRealTimeThread")
	local sleep = rawget(_G, "Sleep")
	if type(create_thread) == "function" and type(sleep) == "function" then
		pcall(create_thread, function(thread_token)
			sleep(ZOOM_FIRST_EXIT_TAKEOVER_TIMEOUT_MS)
			if ZP.first_overview_exit_takeover_token == thread_token then
				ZP.first_overview_exit_takeover_token = false
				ZP.first_overview_exit_takeover_armed = false
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
	if ok and pan_time > 0 then
		local sleep = rawget(_G, "Sleep")
		if type(sleep) == "function" then
			pcall(sleep, pan_time)
		end
	end
	return ok == true
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
local function ZoomPlus_RestoreOriginalZoomPropertiesPreservingCamera(original)
	local _, eye, lookat = ZoomPlus_CaptureLiveCameraView()

	ZoomPlus_RestoreDefaultZoomOut()
	local restored = ZoomPlus_SetRTSCameraZoomProperties(original)
	if restored and eye and lookat then
		ZoomPlus_ApplyCapturedCameraView(eye, lookat)
	end

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
		return false
	end

	local get_interface = rawget(_G, "GetInGameInterface")
	if type(get_interface) ~= "function" then
		return false
	end
	local ok_igi, igi = pcall(get_interface)
	if not ok_igi or type(igi) ~= "table" or type(igi.SetMode) ~= "function" then
		return false
	end

	local mode_dialog = igi.mode_dialog
	-- InGameInterface:SetMode closes the current mode dialog unconditionally. During
	-- map/session normalization the interface can still retain a dialog whose XWindow
	-- has already entered `destroying` (or has not opened yet); XWindow:Close asserts
	-- before pcall can keep the debug error dialog off-screen. Only ask SetMode to
	-- replace a dialog in one of the two states its Close contract explicitly accepts.
	local mode_dialog_state = mode_dialog and mode_dialog.window_state
	if mode_dialog
		and mode_dialog_state ~= "open"
		and mode_dialog_state ~= "closing"
	then
		ZoomPlus_Audit("DISABLE_OVERVIEW_SKIPPED", {
			reason = tostring(reason or "?"),
			mode_dialog_state = tostring(mode_dialog_state),
		})
		return false
	end
	if
		mode_dialog
		and type(mode_dialog.AllowExitToOverview) == "function"
		and not mode_dialog:AllowExitToOverview()
	then
		return false
	end

	-- Restore vanilla const.DefaultCameraRTS so when overview-close eventually
	-- resets cameraRTS at the tail of its transition, the limits used are
	-- vanilla, not Zoom+'s extended values.
	ZoomPlus_RestoreDefaultZoomOut()

	local ok_set = pcall(function()
		igi:SetMode("overview")
	end)
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
				return
			end
			attempts = attempts + 1
			if attempts >= ZOOM_DEFERRED_CLAMP_RETRY_COUNT then
				ZP.deferred_clamp_token = false
				return
			end
			sleep(ZOOM_DEFERRED_CLAMP_RETRY_MS)
		end
	end, token)
	return true
end

-- Disable path used when the user is currently in (or transitioning into)
--                                   -> STAY in overview; clamp saved_camera.
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
		return ZoomPlus_StayInOverviewForDisable(original)
	end

	local distance = select(1, ZoomPlus_CaptureLiveCameraView())
	local guim_value = rawget(_G, "guim") or 1000
	local vanilla_max = (tonumber(original.LookatDistZoomOut) or 0) * guim_value
	local beyond_vanilla = distance and vanilla_max > 0 and distance > vanilla_max


	if beyond_vanilla then
		if ZoomPlus_EnterOverviewModeForDisable("evaluation_" .. tostring(source or "beyond_vanilla")) then
			return true
		end
	end

	return ZoomPlus_RestoreOriginalZoomPropertiesPreservingCamera(original)
end

-- Wait for the active non-overview camera transition to end, then re-run the
-- disable rule decision tree against the post-transition camera state. This
-- avoids snapping cameraRTS in the middle of a transition (vanilla's transition
-- thread keeps writing camera properties; our SetProperties would race with it).
ZoomPlus_ScheduleDeferredDisableEvaluation = function(original)
	local create_thread = rawget(_G, "CreateRealTimeThread")
	local sleep = rawget(_G, "Sleep")
	if type(create_thread) ~= "function" or type(sleep) ~= "function" then
		return ZoomPlus_RunDisableEvaluation(original, "deferred_no_thread_immediate")
	end

	local token = {}
	ZP.deferred_eval_token = token
	ZP.deferred_eval_original = ZoomPlus_CopyTable(original)


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
		return false
	end
	local original = ZoomPlus_CaptureOriginalZoomProperties()
	if not original or type(original.LookatDistZoomOut) ~= "number" then
		ZoomPlus_Audit("ENABLE_FAILED", { reason = "missing_original_zoom_out" })
		return false
	end

	ZoomPlus_InstallOverviewReturnCameraHook()
	ZoomPlus_InstallZoomOutOverviewTriggerHook()
	local multiplier = ZP.GetMultiplier()
	local props = ZoomPlus_CopyTable(original)
	-- Zoom+ intentionally changes only zoom-out; zoom-in and overview exit targeting stay vanilla.
	props.LookatDistZoomOut = original.LookatDistZoomOut * multiplier
	ZoomPlus_Audit("ENABLE_TARGET", {
		baseline_zoom_out = original.LookatDistZoomOut,
		multiplier = multiplier,
		target_zoom_out = props.LookatDistZoomOut,
		preserve_camera = tostring(preserve_camera),
	})
	ZoomPlus_SetDefaultZoomOut(props.LookatDistZoomOut)

	ZP.last_multiplier = multiplier
	ZP.last_zoom_out = props.LookatDistZoomOut
	ZP.enabled = true

	local mode_string = ZoomPlus_GetInterfaceMode()
	local overview_active = ZoomPlus_IsOverviewZoomActive() or mode_string == "overview"
	local transition_active = ZoomPlus_IsCameraTransitionActive()


	-- CASE 1: User is in overview. Don't touch live cameraRTS or call SetProperties:
	-- vanilla freezes the camera through the overview transition and re-deriving
	-- eye distance from ZoomStep mid-overview would cause a visible jump. Just
	-- patch const.DefaultCameraRTS (already done above) and cache the saved
	-- camera so the disable path can clamp it back to vanilla on exit.
	if overview_active then
		ZoomPlus_CacheVanillaOverviewSavedCamera()
		ZoomPlus_Audit("ENABLE_DEFERRED", { reason = "overview_active" })
		return true
	end

	-- CASE 2: A non-overview camera transition is in flight. Don't write camera
	-- properties in the middle of a transition: the transition thread is mutating
	-- camera state every frame; a SetProperties race would either be lost or
	-- produce a visible snap. const has already been patched, so the new far
	-- limit is in effect for any post-transition zoom.
	if transition_active then
		ZoomPlus_Audit("ENABLE_DEFERRED", { reason = "camera_transition" })
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
	local pre_eye, pre_lookat
	if preserve_camera then
		pre_eye, pre_lookat = select(2, ZoomPlus_CaptureLiveCameraView())
	end

	if not ZoomPlus_SetRTSCameraZoomProperties(props) then
		ZP.enabled = false
		ZoomPlus_RestoreDefaultZoomOut()
		ZoomPlus_RemoveOverviewReturnCameraHook()
		ZoomPlus_RemoveZoomOutOverviewTriggerHook()
		ZoomPlus_Audit("ENABLE_FAILED", { reason = "set_properties" })
		return false
	end

	if preserve_camera then
		if pre_eye and pre_lookat then
			ZoomPlus_ApplyCapturedCameraView(pre_eye, pre_lookat)
		end
	else
		ZoomPlus_ReapplyCurrentCameraForZoomProperties()
	end
	ZoomPlus_Audit("ENABLE_APPLIED", {
		baseline_zoom_out = original.LookatDistZoomOut,
		multiplier = multiplier,
		target_zoom_out = props.LookatDistZoomOut,
	})
	return true
end

-- Restore the RTS camera zoom properties captured before Zoom+. Dispatches to
-- one of four cases:
--   1. No captured original         -> strip hooks and bail.
--   2. Overview active (or mode==overview) at disable time
--                                   -> STAY in overview; clamp saved_camera.
--   3. Non-overview transition active
--                                   -> defer evaluation until transition ends.
--   4. Selection mode, no transition -> run rule decision now (preserve current
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
		return true
	end

	-- Mark Zoom+ disabled and detach its hooks first so subsequent
	-- state checks read the live engine state, not Zoom+ wrappers.
	ZP.enabled = false
	ZoomPlus_RemoveOverviewReturnCameraHook()
	ZoomPlus_RemoveZoomOutOverviewTriggerHook()

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
			ZoomPlus_ApplyOverviewReturnCamera(self)
			return ZP.original_overview_check_below_zoom_limit(self, ...)
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
			return ZP.original_selection_check_above_zoom_limit(self, ...)
		end
		if not camera_rts or type(camera_rts.IsActive) ~= "function" or not camera_rts.IsActive() then
			return ZP.original_selection_check_above_zoom_limit(self, ...)
		end
		if not current_map or not current_map.mapdata or not current_map.mapdata.IsAllowedToEnterOverview then
			return ZP.original_selection_check_above_zoom_limit(self, ...)
		end
		if type(self.AllowExitToOverview) == "function" and not self:AllowExitToOverview() then
			return ZP.original_selection_check_above_zoom_limit(self, ...)
		end

		local get_zoom_limits = camera_rts.GetZoomLimits
		local get_zoom = camera_rts.GetZoom
		if type(get_zoom_limits) ~= "function" or type(get_zoom) ~= "function" then
			return ZP.original_selection_check_above_zoom_limit(self, ...)
		end

		local min_zoom, max_zoom = get_zoom_limits()
		local zoom = get_zoom() * 1000
		ZoomPlus_Audit("ZOOM_OUT_CHECK", {
			zoom = zoom,
			min_zoom = min_zoom,
			max_zoom = max_zoom,
		})
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
				ZoomPlus_Audit("ZOOM_OUT_ENTER_OVERVIEW", {
					zoom = zoom,
					max_zoom = max_zoom,
					repeat_count = ZP.overview_zoom_out_count,
				})
				self.parent:SetMode("overview")
				return "break"
			end
		end

		return ZP.original_selection_check_above_zoom_limit(self, ...)
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
		return true
	end
	if ZoomPlus_IsCameraTransitionActive() then
		return true
	end
	if ZoomPlus_IsOverviewZoomActive() then
		return true
	end
	local camera_rts = ZoomPlus_GetRTSCamera()
	if camera_rts and type(camera_rts.IsMoving) == "function" and camera_rts.IsMoving() then
		return true
	end
	return ZP.Enable("preserve camera")
end

-- Read-only state used by the host's targeted diagnostics. Values are kept scalar
-- so the diagnostic formatter never walks engine tables or point userdata.
function ZP.GetDebugState()
	local original = ZP.original_properties
	return {
		enabled = tostring(ZP.enabled == true),
		configured_multiplier = tostring(ZP.GetMultiplier()),
		last_multiplier = tostring(ZP.last_multiplier),
		last_zoom_out = tostring(ZP.last_zoom_out),
		original_zoom_out = tostring(type(original) == "table" and original.LookatDistZoomOut or nil),
		original_default_zoom_out = tostring(ZP.original_default_zoom_out),
		capture_live_zoom_out = tostring(ZP.last_capture_live_zoom_out),
		capture_default_zoom_out = tostring(ZP.last_capture_default_zoom_out),
		capture_baseline_zoom_out = tostring(ZP.last_capture_baseline_zoom_out),
		capture_baseline_source = tostring(ZP.last_capture_baseline_source),
	}
end

-- Initialize Zoom+ lifecycle hooks.
function ZP.Init()
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

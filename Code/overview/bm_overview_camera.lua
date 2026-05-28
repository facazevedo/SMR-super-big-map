-- Bigger Maps -- overview camera framing.
--
-- Pulls the overview camera far enough back (and at the configured angle/FOV) to
-- frame an expanded map, then keeps it framed as the player toggles overview mode.
-- Owns: the FOV widening, the CalcOverviewCameraPos override, the screen-space
-- nudge, and the refresh/reschedule helpers that re-apply framing when overview is
-- (re)entered. RefreshOverviewCamera also drives the curtain and render-distance
-- modules via the BiggerMaps namespace (they load after this one).

local BiggerMaps = rawget(_G, "BiggerMaps")
if type(BiggerMaps) ~= "table" then
	BiggerMaps = {}
	rawset(_G, "BiggerMaps", BiggerMaps)
end

local Engine = BiggerMaps.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local Config = BiggerMaps.Config or {}

-- Map liveness / terrain size are intentionally NOT in bm_engine (their resolution
-- order is context-specific); each consumer keeps its own copy.
local function IsLiveMap(map)
	if not map or type(map) ~= "table" then
		return false
	end

	if type(map.IsValid) == "function" and not SafeCall(map.IsValid, map) then
		return false
	end

	if not map.mapdata then
		return false
	end

	return true
end

local function ResolveLiveMap(map)
	if IsLiveMap(map) then
		return map
	end

	map = Global("CurrentMap")
	if IsLiveMap(map) then
		return map
	end

	map = Global("MainMap")
	if IsLiveMap(map) then
		return map
	end

	return false
end

local function TerrainSize(map)
	if not IsLiveMap(map) then
		return 0, 0
	end

	if type(map.Width) == "number" and type(map.Height) == "number" and map.Width > 0 and map.Height > 0 then
		return map.Width, map.Height
	end

	local terrain_api = Global("terrain")

	if terrain_api and type(terrain_api.GetMapSize) == "function" then
		local width, height = SafeCall(terrain_api.GetMapSize, map)
		if width and height then
			return width, height
		end
	end

	if map and type(map.GetMapSize) == "function" then
		local width, height = SafeCall(map.GetMapSize, map)
		if width and height then
			return width, height
		end
	end

	return map and map.Width or 0, map and map.Height or 0
end

local function cfg_number(key, default)
	local value = Config[key]
	if type(value) == "number" then
		return value
	end
	return default
end

local OVERVIEW_DISTANCE_MULTIPLIER = cfg_number("OVERVIEW_DISTANCE_MULTIPLIER", 2.5)
local OVERVIEW_MIN_HEIGHT_PERCENT = cfg_number("OVERVIEW_MIN_HEIGHT_PERCENT", 140)
local OVERVIEW_CAMERA_XY_PERCENT = cfg_number("OVERVIEW_CAMERA_XY_PERCENT", 28)
local OVERVIEW_ZOOM_DISTANCE_PERCENT = cfg_number("OVERVIEW_ZOOM_DISTANCE_PERCENT", 140)
local OVERVIEW_NUDGE_HORIZONTAL_PERCENT = cfg_number("OVERVIEW_NUDGE_HORIZONTAL_PERCENT", 0)
local OVERVIEW_NUDGE_VERTICAL_PERCENT = cfg_number("OVERVIEW_NUDGE_VERTICAL_PERCENT", 0)
local OVERVIEW_VIEW_ANGLE_DEGREES = (type(Config.OVERVIEW_VIEW_ANGLE_DEGREES) == "number") and Config.OVERVIEW_VIEW_ANGLE_DEGREES or false
local OVERVIEW_FOV_16_9 = cfg_number("OVERVIEW_FOV_16_9", 3600)
local OVERVIEW_FOV_4_3 = cfg_number("OVERVIEW_FOV_4_3", 3400)

local overview_camera_patched = false
local original_calc_overview_camera_pos = false
local overview_reset_token = 0

local function ApplyOverviewNudge(pos, lookat, size)
	if OVERVIEW_NUDGE_HORIZONTAL_PERCENT == 0 and OVERVIEW_NUDGE_VERTICAL_PERCENT == 0 then
		return pos, lookat
	end
	if not pos or not lookat or not size or size <= 0 then
		return pos, lookat
	end

	local point_fn = Global("point")
	if type(point_fn) ~= "function" then
		return pos, lookat
	end

	local ok_offset, offset = pcall(function()
		return pos - lookat
	end)
	if not ok_offset or not offset or type(offset.xy) ~= "function" then
		return pos, lookat
	end

	local dx, dy = offset:xy()
	local len = math.sqrt(dx * dx + dy * dy)
	if len <= 0 then
		return pos, lookat
	end

	local right_x = dy / len
	local right_y = -dx / len
	local up_x = -dx / len
	local up_y = -dy / len
	local shift_x = math.floor(size * (OVERVIEW_NUDGE_HORIZONTAL_PERCENT * right_x + OVERVIEW_NUDGE_VERTICAL_PERCENT * up_x) / 100)
	local shift_y = math.floor(size * (OVERVIEW_NUDGE_HORIZONTAL_PERCENT * right_y + OVERVIEW_NUDGE_VERTICAL_PERCENT * up_y) / 100)
	if shift_x == 0 and shift_y == 0 then
		return pos, lookat
	end

	local shift = point_fn(shift_x, shift_y, 0)
	local ok_shift, shifted_pos, shifted_lookat = pcall(function()
		return pos + shift, lookat + shift
	end)
	if ok_shift and shifted_pos and shifted_lookat then
		return shifted_pos, shifted_lookat
	end

	return pos, lookat
end

local function OverviewAngle(angle)
	if type(OVERVIEW_VIEW_ANGLE_DEGREES) == "number" then
		return math.floor(OVERVIEW_VIEW_ANGLE_DEGREES * 60)
	end
	return angle or 45 * 60
end

local function PatchOverviewFov()
	local const = Global("const")
	if type(const) ~= "table" or type(const.Camera) ~= "table" then
		return
	end

	pcall(function()
		if const.Camera.BiggerMapsOriginalOverviewFovX_16_9 == nil then
			const.Camera.BiggerMapsOriginalOverviewFovX_16_9 = const.Camera.OverviewFovX_16_9
		end
		if const.Camera.BiggerMapsOriginalOverviewFovX_4_3 == nil then
			const.Camera.BiggerMapsOriginalOverviewFovX_4_3 = const.Camera.OverviewFovX_4_3
		end

		const.Camera.OverviewFovX_16_9 = math.max(const.Camera.OverviewFovX_16_9 or 0, OVERVIEW_FOV_16_9)
		const.Camera.OverviewFovX_4_3 = math.max(const.Camera.OverviewFovX_4_3 or 0, OVERVIEW_FOV_4_3)
	end)
end

local function PatchOverviewCamera()
	if overview_camera_patched or type(Global("CalcOverviewCameraPos")) ~= "function" then
		return
	end

	original_calc_overview_camera_pos = Global("CalcOverviewCameraPos")

	_G.CalcOverviewCameraPos = function(angle, map)
		angle = OverviewAngle(angle)
		local pos, lookat = original_calc_overview_camera_pos(angle, map)
		map = ResolveLiveMap(map)
		if not pos or not lookat or not map then
			return pos, lookat
		end

		local width, height = TerrainSize(map)
		local size = math.max(width or 0, height or 0)
		if size <= 0 then
			return pos, lookat
		end

		local point_fn = Global("point")
		if type(point_fn) == "function" then
			local center = point_fn(math.floor(width / 2), math.floor(height / 2), 0)
			if center and type(center.SetStepZ) == "function" then
				center = center:SetStepZ(map)
			end

			local offset = pos - lookat
			local dx, dy = offset:xy()
			local xy_len = math.sqrt(dx * dx + dy * dy)
			if center and xy_len > 0 then
				local xy_dist = size * OVERVIEW_CAMERA_XY_PERCENT / 100
				local new_dx = math.floor(dx * xy_dist / xy_len)
				local new_dy = math.floor(dy * xy_dist / xy_len)
				local new_z = math.floor(size * OVERVIEW_ZOOM_DISTANCE_PERCENT / 100)

				lookat = center
				pos = center + point_fn(new_dx, new_dy, new_z)
				pos, lookat = ApplyOverviewNudge(pos, lookat, size)
				return pos, lookat
			end
		end

		local offset = pos - lookat
		pos = lookat + offset * OVERVIEW_DISTANCE_MULTIPLIER

		local min_height = size * math.max(OVERVIEW_MIN_HEIGHT_PERCENT, OVERVIEW_ZOOM_DISTANCE_PERCENT) / 100
		local min_z = lookat:z() + min_height
		if pos:z() < min_z then
			pos = pos:SetZ(min_z)
		end

		pos, lookat = ApplyOverviewNudge(pos, lookat, size)
		return pos, lookat
	end

	overview_camera_patched = true
end

local function ResetOverviewCamera(map, transition_time)
	if type(Global("CalcOverviewCameraPos")) ~= "function" then
		return
	end

	local get_interface = Global("GetInGameInterface")
	local igi = SafeCall(get_interface)
	local camera = Global("cameraRTS")
	if not igi or not camera or type(camera.SetCamera) ~= "function" then
		return
	end
	if type(igi.IsInMode) ~= "function" or not SafeCall(igi.IsInMode, igi, "overview") then
		return
	end

	local dialog = igi.mode_dialog
	local angle = OverviewAngle(dialog and dialog.overview_angle)
	if dialog and type(OVERVIEW_VIEW_ANGLE_DEGREES) == "number" then
		dialog.overview_angle = angle
	end
	local pos, lookat = CalcOverviewCameraPos(angle, map)
	if pos and lookat then
		SafeCall(camera.SetCamera, pos, lookat, transition_time or 0)
	end
end

local function RefreshOverviewCamera()
	local curtains = BiggerMaps.OverviewCurtains
	local render = BiggerMaps.OverviewRender

	PatchOverviewFov()
	PatchOverviewCamera()
	if curtains then
		curtains.PatchOverviewCurtains()
	end

	if not (Global("IsOverviewMode") and IsOverviewMode()) then
		return false
	end

	if render then
		render.Apply(true)
	end
	if curtains then
		curtains.HideOverviewCurtains()
	end
	ResetOverviewCamera(Global("CurrentMap"), 0)
	return true
end

local function ScheduleOverviewCameraRefresh()
	local create_thread = Global("CreateRealTimeThread")
	if type(create_thread) ~= "function" then
		return false
	end

	overview_reset_token = overview_reset_token + 1
	local token = overview_reset_token
	SafeCall(create_thread, function()
		local sleep = Global("Sleep")
		local delays = { 0, 100, 650, 1100 }

		for i = 1, #delays do
			if token ~= overview_reset_token then
				return
			end

			local delay = delays[i]
			if delay > 0 and type(sleep) == "function" then
				sleep(delay)
			end

			if token ~= overview_reset_token then
				return
			end
			RefreshOverviewCamera()
		end
	end)
	return true
end

local OverviewCamera = {}

OverviewCamera.PatchOverviewFov = PatchOverviewFov
OverviewCamera.PatchOverviewCamera = PatchOverviewCamera
OverviewCamera.ResetOverviewCamera = ResetOverviewCamera
OverviewCamera.RefreshOverviewCamera = RefreshOverviewCamera
OverviewCamera.ScheduleOverviewCameraRefresh = ScheduleOverviewCameraRefresh

-- Invalidate any pending scheduled refresh (called when leaving overview mode).
function OverviewCamera.CancelScheduledRefresh()
	overview_reset_token = overview_reset_token + 1
end

function OverviewCamera.ApplyModBehavior()
	PatchOverviewFov()
	PatchOverviewCamera()
end

function OverviewCamera.RestoreVanillaBehavior()
	if overview_camera_patched and original_calc_overview_camera_pos then
		_G.CalcOverviewCameraPos = original_calc_overview_camera_pos
	end
	original_calc_overview_camera_pos = false
	overview_camera_patched = false

	local const = Global("const")
	if type(const) == "table" and type(const.Camera) == "table" then
		pcall(function()
			if const.Camera.BiggerMapsOriginalOverviewFovX_16_9 ~= nil then
				const.Camera.OverviewFovX_16_9 = const.Camera.BiggerMapsOriginalOverviewFovX_16_9
				const.Camera.BiggerMapsOriginalOverviewFovX_16_9 = nil
			end
			if const.Camera.BiggerMapsOriginalOverviewFovX_4_3 ~= nil then
				const.Camera.OverviewFovX_4_3 = const.Camera.BiggerMapsOriginalOverviewFovX_4_3
				const.Camera.BiggerMapsOriginalOverviewFovX_4_3 = nil
			end
		end)
	end

	-- Cancel any pending scheduled refresh so it cannot re-apply framing.
	overview_reset_token = overview_reset_token + 1
end

BiggerMaps.OverviewCamera = OverviewCamera

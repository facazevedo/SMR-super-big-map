-- Super Big Map -- overview camera framing.
--
-- Pulls the overview camera far enough back (and at the configured angle/FOV) to
-- frame an expanded map, then keeps it framed as the player toggles overview mode.
-- Owns: the FOV widening, the CalcOverviewCameraPos override, the screen-space
-- nudge, and the refresh/reschedule helpers that re-apply framing when overview is
-- (re)entered. RefreshOverviewCamera also drives the curtain and render-distance
-- modules via the SuperBigMap namespace (they load after this one).

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local Config = SuperBigMap.Config or {}


local function PointXYZ(p)
	if not p then
		return nil, nil, nil
	end
	return SafeCall(p.x, p), SafeCall(p.y, p), SafeCall(p.z, p)
end


-- Integer-safe component interpolation: a + (b-a)*num/den. This runtime's `/` is
-- integer division, so multiply BEFORE dividing (the product stays well within
-- 64-bit for camera-scale coords).
local function LerpComp(a, b, num, den)
	if den == 0 then
		return a
	end
	return a + (b - a) * num / den
end

-- Build an interpolated point between a and b at fraction num/den.
local function PointLerp(point_fn, a, b, num, den)
	local ax, ay, az = PointXYZ(a)
	local bx, by, bz = PointXYZ(b)
	if not ax or not bx then
		return nil
	end
	return point_fn(LerpComp(ax, bx, num, den), LerpComp(ay, by, num, den), LerpComp(az, bz, num, den))
end

-- Token so a new exit takeover cancels any still-running one.
local exit_takeover_token = 0

-- Map liveness / terrain size are intentionally NOT in sbm_engine (their resolution
-- order is context-specific); each consumer keeps its own copy.
local IsLiveMap = Engine.IsLiveMap

local function IsTemporaryVanillaSource(map)
	return map and map.SuperBigMapVanillaSourceMigration == true
end

local function CameraMigrationActive()
	local state = SuperBigMap.State
	return type(state) == "table" and state.vanilla_source_migration_active == true
end

local function ResolveLiveMap(map)
	if IsLiveMap(map) and not IsTemporaryVanillaSource(map) then
		return map
	end

	map = Global("CurrentMap")
	if IsLiveMap(map) and not IsTemporaryVanillaSource(map) then
		return map
	end

	map = Global("MainMap")
	if IsLiveMap(map) and not IsTemporaryVanillaSource(map) then
		return map
	end

	return false
end

-- Overview reshaping (FOV widen, camera pull-back, curtain hiding, far render
-- distance) applies ONLY to mod-expanded maps. On vanilla maps / old saves not
-- started with the mod, overview must look exactly vanilla, so every reshaping
-- entry point gates on this.
local function IsModMap(map)
	local grid = SuperBigMap.SectorGrid
	if grid and type(grid.IsModMap) == "function" then
		return grid.IsModMap(map) == true
	end
	return false
end

local TerrainSize = Engine.TerrainSize

-- Camera geometry must not depend on the transient map backing that happens to be
-- public while random generation is running. The destination's desired tile size
-- is the same stable geometry used to build the expanded sector grid. Convert it
-- with the engine tile size; fall back to the live terrain for old expanded saves
-- that predate the desired-size marker.
local function StableCameraTerrainSize(map)
	local live_width, live_height = TerrainSize(map)
	local mapdata = map and map.mapdata
	local width_tiles = map and tonumber(map.SuperBigMapDesiredWidthTiles)
	local height_tiles = map and tonumber(map.SuperBigMapDesiredHeightTiles)
	local source = "desired"
	if not width_tiles or width_tiles <= 0 or not height_tiles or height_tiles <= 0 then
		width_tiles = mapdata and tonumber(mapdata.Width)
		height_tiles = mapdata and tonumber(mapdata.Height)
		source = "mapdata"
	end
	local const_tbl = Global("const")
	local tile = type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize) or nil
	if width_tiles and width_tiles > 0 and height_tiles and height_tiles > 0
		and tile and tile > 0 then
		return width_tiles * tile, height_tiles * tile, source, live_width, live_height
	end
	return live_width, live_height, "live", live_width, live_height
end

local function CameraDestinationStatus(map, require_finalized)
	if CameraMigrationActive() then
		return false, "vanilla-source-migration-active"
	end
	if IsTemporaryVanillaSource(map) then
		return false, "temporary-vanilla-source"
	end
	if not IsLiveMap(map) then
		return false, "map-not-live"
	end
	if Global("CurrentMap") ~= map then
		return false, "map-not-current"
	end
	if not IsModMap(map) then
		return false, "not-mod-map"
	end
	if require_finalized and map.SuperBigMapExpansionPending == true then
		return false, "expanded-destination-pending"
	end
	return true, "ready"
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
local overview_camera_wrapper = false
local overview_reset_token = 0

-- Vanilla applies the overview FOV to the live renderer only when
-- OverviewModeDialog:StoreView runs. Exact-vanilla source generation switches maps
-- after that call, which can restore the normal lens even though our overview consts
-- still say 3600/3400. Re-apply the lens together with every destination reframe.
-- This preserves the configured overview distance and horizontal field of view.
local function ApplyLiveOverviewFov(transition_time, source)
	local camera_api = Global("camera")
	local const_tbl = Global("const")
	if type(camera_api) ~= "table" or type(camera_api.SetAutoFovX) ~= "function"
		or type(const_tbl) ~= "table" or type(const_tbl.Camera) ~= "table" then
		return false
	end
	local fov_4_3 = tonumber(const_tbl.Camera.OverviewFovX_4_3) or OVERVIEW_FOV_4_3
	local fov_16_9 = tonumber(const_tbl.Camera.OverviewFovX_16_9) or OVERVIEW_FOV_16_9
	local ok = pcall(camera_api.SetAutoFovX, 1, transition_time or 0,
		fov_4_3, 4, 3, fov_16_9, 16, 9)
	return ok
end

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

local RestoreOverviewFovVanilla  -- defined below; called by PatchOverviewFov's non-mod guard

local function PatchOverviewFov()
	local const = Global("const")
	if type(const) ~= "table" or type(const.Camera) ~= "table" then
		return
	end
	-- The exact-vanilla source transaction temporarily publishes a non-destination
	-- map. Keep the shared FOV vanilla until the expanded destination is restored.
	if CameraMigrationActive() or IsTemporaryVanillaSource(Global("CurrentMap")) then
		if type(RestoreOverviewFovVanilla) == "function" then
			RestoreOverviewFovVanilla()
		end
		return
	end

	-- Only widen the overview FOV on maps THIS mod expanded. On a vanilla / non-EXPAND
	-- map keep the stock FOV (restore it if a prior mod map widened the shared const).
	-- This is the fix for "a normal map's overview was not vanilla": the widen used to
	-- run unconditionally (ApplyOverviewPatches calls it on every map) and was only undone
	-- by RefreshOverviewCamera, so the two flip-flopped and the FOV was often left widened.
	if not IsModMap(ResolveLiveMap(Global("CurrentMap"))) then
		if type(RestoreOverviewFovVanilla) == "function" then
			RestoreOverviewFovVanilla()
		end
		return
	end

	pcall(function()
		if const.Camera.SuperBigMapOriginalOverviewFovX_16_9 == nil then
			const.Camera.SuperBigMapOriginalOverviewFovX_16_9 = const.Camera.OverviewFovX_16_9
		end
		if const.Camera.SuperBigMapOriginalOverviewFovX_4_3 == nil then
			const.Camera.SuperBigMapOriginalOverviewFovX_4_3 = const.Camera.OverviewFovX_4_3
		end

		const.Camera.OverviewFovX_16_9 = math.max(const.Camera.OverviewFovX_16_9 or 0, OVERVIEW_FOV_16_9)
		const.Camera.OverviewFovX_4_3 = math.max(const.Camera.OverviewFovX_4_3 or 0, OVERVIEW_FOV_4_3)
	end)
end

local function PatchOverviewCamera()
	local current = Global("CalcOverviewCameraPos")
	if current == overview_camera_wrapper and type(current) == "function" then
		overview_camera_patched = true
		return true
	end
	if type(current) ~= "function" then
		return false
	end

	-- The underground DLC reloads part of the game Lua while the first underground
	-- map is becoming current. That reload can replace the global calculator without
	-- reloading this module, leaving overview_camera_patched=true while our wrapper is
	-- no longer installed. Treat function identity as authoritative and wrap the new
	-- environment-specific vanilla calculator immediately.
	original_calc_overview_camera_pos = current

	local wrapper
	wrapper = function(angle, map)
		-- Vanilla must own every camera calculation while its temporary source map is
		-- public. Resolving that source to MainMap here would feed expanded geometry
		-- into a vanilla-map camera call and recreate the stale startup framing.
		if CameraMigrationActive() or IsTemporaryVanillaSource(map) then
			return original_calc_overview_camera_pos(angle, map)
		end
		local resolved = ResolveLiveMap(map)
		-- Non-mod map: hand back the engine's vanilla framing untouched (do not even
		-- override the view angle), so overview is exactly vanilla there.
		if not IsModMap(resolved) then
			return original_calc_overview_camera_pos(angle, map)
		end
		angle = OverviewAngle(angle)
		local pos, lookat = original_calc_overview_camera_pos(angle, map)
		map = resolved
		if not pos or not lookat or not map then
			return pos, lookat
		end
		local width, height = StableCameraTerrainSize(map)
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

	overview_camera_wrapper = wrapper
	_G.CalcOverviewCameraPos = wrapper
	overview_camera_patched = true
	return true
end

-- Before the overview SetCamera, raise the LIVE camera's LookatDistZoomOut to the
-- extended far limit so the engine doesn't clamp the far overview eye in close.
-- ZoomPlus keeps that extended value (vanilla * multiplier) on
-- const.DefaultCameraRTS, but it intentionally skips writing live SetProperties
-- while overview is active -- so on the FIRST/startup overview entry the live
-- camera still carries the vanilla zoom-out limit and the engine clamps the
-- requested far eye to a too-close framing (the user gets the "closer" overview).
-- A manual zoom-out cycle later applies the extended limit, which is why the
-- second overview is correctly framed. Pushing it here makes the first overview
-- match. Only writes when the live limit is below target; the SetCamera that
-- follows immediately commits the far eye, so there is no visible jump.
local function EnsureOverviewZoomOutLimit(camera)
	if type(camera.GetProperties) ~= "function" or type(camera.SetProperties) ~= "function" then
		return false
	end
	-- The OVERVIEW camera needs the engine's large overview LookatDistZoomOut
	-- (~20000) so the far bird's-eye eye isn't clamped in. On a wheel-zoom overview
	-- entry the engine flips the live camera to this itself; the auto/startup entry
	-- does NOT, leaving the selection limit (vanilla*multiplier, e.g. 5400) which
	-- clamps the eye close. Push the overview value onto the LIVE camera only (never
	-- const.DefaultCameraRTS) so selection mode keeps its own limit -- no "zoom out
	-- of Mars" leak -- and the engine restores selection props on overview exit.
	local cfg = SuperBigMap.Config or {}
	local target = tonumber(cfg.OVERVIEW_CAMERA_ZOOM_OUT_LIMIT) or 20000
	local props = SafeCall(camera.GetProperties, 1)
	local current = type(props) == "table" and tonumber(props.LookatDistZoomOut) or nil
	if type(props) ~= "table" then
		return false
	end
	if type(current) == "number" and current >= target then
		return false
	end
	props.LookatDistZoomOut = target
	SafeCall(camera.SetProperties, 1, props)
	return true
end

local function ResetOverviewCamera(map, transition_time, source)
	source = source or "?"
	map = ResolveLiveMap(map)
	local destination_ready, destination_reason = CameraDestinationStatus(map, true)
	if not destination_ready then
		return false
	end
	-- Verify the hook at the final call boundary as well as in RefreshOverviewCamera.
	-- Direct lifecycle callers can reach ResetOverviewCamera, and the underground
	-- environment reload may replace the global between scheduled refresh ticks.
	PatchOverviewCamera()
	local calc_overview = Global("CalcOverviewCameraPos")
	if type(calc_overview) ~= "function" then
		return false
	end

	local get_interface = Global("GetInGameInterface")
	local igi = SafeCall(get_interface)
	local camera = Global("cameraRTS")
	if not igi or not camera or type(camera.SetCamera) ~= "function" then
		return false
	end
	if type(igi.IsInMode) ~= "function" or not SafeCall(igi.IsInMode, igi, "overview") then
		return false
	end

	local dialog = igi.mode_dialog

	-- One-time return-camera seed for the STARTUP overview. The new game opens in
	-- overview with transition_time=0, so vanilla leaves dialog.saved_camera =
	-- false; the first exit then uses vanilla's fixed far default offset and (with
	-- our high overview eye) swerves before reaching the picked sector. The FIRST
	-- ResetOverviewCamera fires while the camera is still at its pre-overview
	-- (low/close) position -- capture THAT as the return camera so the first exit
	-- behaves like every later one. Guarded: only when saved_camera is unset, so
	-- vanilla's own capture on later (wheel) entries always wins.
	local cfg = SuperBigMap.Config or {}
	if cfg.SEED_STARTUP_OVERVIEW_RETURN_CAMERA == true and dialog and not dialog.saved_camera then
		-- Seed a CLEAN return camera (not the captured pre-overview camera, which on
		-- startup is a junk near-ground sideways view). A pure south+up offset with
		-- the eye ABOVE the lookat makes the first overview exit descend straight
		-- onto the picked sector instead of swerving. exit_to drives the lookat, so
		-- only the eye_offset matters; the lookat here is just a fallback.
		local point_fn = Global("point")
		local lookat = type(camera.GetLookAt) == "function" and SafeCall(camera.GetLookAt) or false
		if type(point_fn) == "function" then
			local south = tonumber(cfg.SEED_OVERVIEW_RETURN_SOUTH) or 100000
			local up = tonumber(cfg.SEED_OVERVIEW_RETURN_UP) or 67000
			local offset = point_fn(0, -south, up)
			dialog.saved_camera = {
				eye_offset = offset,
				lookat = lookat or offset,
				bigger_maps_startup_overview_return = true,
			}
		end
	end

	local angle = OverviewAngle(dialog and dialog.overview_angle)
	if dialog and type(OVERVIEW_VIEW_ANGLE_DEGREES) == "number" then
		dialog.overview_angle = angle
	end
	local pos, lookat = calc_overview(angle, map)
	if pos and lookat then
		-- Raise the live far-zoom limit first so the engine doesn't clamp the far
		-- overview eye on the first entry (see EnsureOverviewZoomOutLimit).
		EnsureOverviewZoomOutLimit(camera)
		ApplyLiveOverviewFov(transition_time or 0, source)
		SafeCall(camera.SetCamera, pos, lookat, transition_time or 0)
		return true
	end
	return false
end

-- Put the vanilla overview FOV back (the widened value is a global const, so it
-- must be actively restored when overview is entered on a non-mod map). Leaves the
-- saved-original markers in place so a later mod-map entry can re-widen.
function RestoreOverviewFovVanilla()
	local const = Global("const")
	if type(const) ~= "table" or type(const.Camera) ~= "table" then
		return
	end
	pcall(function()
		if const.Camera.SuperBigMapOriginalOverviewFovX_16_9 ~= nil then
			const.Camera.OverviewFovX_16_9 = const.Camera.SuperBigMapOriginalOverviewFovX_16_9
		end
		if const.Camera.SuperBigMapOriginalOverviewFovX_4_3 ~= nil then
			const.Camera.OverviewFovX_4_3 = const.Camera.SuperBigMapOriginalOverviewFovX_4_3
		end
	end)
end

local function RefreshOverviewCamera(source, expected_map)
	source = source or "RefreshOverviewCamera"
	local curtains = SuperBigMap.OverviewCurtains
	local render = SuperBigMap.OverviewRender
	local map = ResolveLiveMap(expected_map or Global("CurrentMap"))
	if expected_map and map ~= expected_map then
		return false
	end
	local destination_ready, destination_reason = CameraDestinationStatus(map, true)
	if not destination_ready and destination_reason ~= "not-mod-map" then
		return false
	end

	-- Non-mod map: keep overview vanilla. Undo the FOV widen and the far render
	-- distance, and do NOT reframe the camera or hide curtains. (The persistent
	-- CalcOverviewCameraPos / curtain stubs are themselves gated on IsModMap, so
	-- they pass through to vanilla too.)
	if not destination_ready then
		RestoreOverviewFovVanilla()
		if render then
			render.Apply(false)
		end
		return false
	end

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
	return ResetOverviewCamera(map, 0, source) == true
end

local function ScheduleOverviewCameraRefresh(expected_map, schedule_source)
	local create_thread = Global("CreateRealTimeThread")
	if type(create_thread) ~= "function" then
		return false
	end
	expected_map = ResolveLiveMap(expected_map or Global("CurrentMap"))
	schedule_source = schedule_source or "overview-entry"

	overview_reset_token = overview_reset_token + 1
	local token = overview_reset_token
	SafeCall(create_thread, function()
		local sleep = Global("Sleep")
		-- Re-apply the overview framing several times after entering overview. The
		-- early ticks catch the moment the overview mode becomes active; the later
		-- ticks must land AFTER the game's enter camera transition finishes,
		-- otherwise that transition (which ends on the game's closer target) overrides
		-- our snap and the view stays too close until the next manual camera move.
		-- The first overview entry of a session sets up the overview dialog and runs
		-- a slower transition, so the tail extends well past it.
		local delays = { 0, 100, 350, 700, 1200, 1800, 2500, 4000, 6000 }
		local elapsed = 0

		for i = 1, #delays do
			if token ~= overview_reset_token then
				return
			end

			local delay = delays[i]
			local wait = delay - elapsed
			if wait > 0 and type(sleep) == "function" then
				sleep(wait)
			end
			elapsed = delay

			if token ~= overview_reset_token then
				return
			end
			local ready, reason = CameraDestinationStatus(expected_map, true)
			if ready then
				RefreshOverviewCamera(schedule_source .. "#" .. tostring(i)
					.. "@" .. tostring(delay) .. "ms", expected_map)
			end
		end
	end)
	return true
end

local OverviewCamera = {}

OverviewCamera.PatchOverviewFov = PatchOverviewFov
OverviewCamera.RestoreOverviewFovVanilla = RestoreOverviewFovVanilla
OverviewCamera.PatchOverviewCamera = PatchOverviewCamera
OverviewCamera.ResetOverviewCamera = ResetOverviewCamera
OverviewCamera.RefreshOverviewCamera = RefreshOverviewCamera
OverviewCamera.ScheduleOverviewCameraRefresh = ScheduleOverviewCameraRefresh
OverviewCamera.IsPatched = function()
	return overview_camera_patched == true
end

-- Explicit handoff from map generation/lifecycle. Temporary-source generation can
-- consume the startup OverviewMode event, so this destination-bound retry series is
-- the authoritative post-generation camera entry point.
function OverviewCamera.ReframeFinalizedDestination(map, source)
	map = ResolveLiveMap(map)
	local ready, reason = CameraDestinationStatus(map, true)
	if not ready then
		return false
	end
	return ScheduleOverviewCameraRefresh(map, "destination-finalized:" .. tostring(source or "?"))
end

-- Invalidate any pending scheduled refresh (called when leaving overview mode).
function OverviewCamera.CancelScheduledRefresh()
	overview_reset_token = overview_reset_token + 1
end

-- Take over only the first/startup overview->sector EXIT descent with a straight,
-- mod-driven camera animation. ZoomPlus arms this one-shot from the marked startup
-- saved_camera; later overview exits are left to vanilla's transition path.
function OverviewCamera.TakeOverExitTransition(target_eye, target_lookat, time)
	local cfg = SuperBigMap.Config or {}
	if cfg.TAKEOVER_OVERVIEW_EXIT ~= true then
		return false
	end
	if not target_eye or not target_lookat or type(time) ~= "number" or time <= 0 then
		return false
	end
	if Global("ChangingMap") then
		return false
	end
	local camera = Global("cameraRTS")
	local point_fn = Global("point")
	if not camera or type(camera.SetCamera) ~= "function"
		or type(camera.GetEye) ~= "function" or type(camera.GetLookAt) ~= "function"
		or type(point_fn) ~= "function" then
		return false
	end
	local start_eye = SafeCall(camera.GetEye)
	local start_lookat = SafeCall(camera.GetLookAt)
	if not start_eye or not start_lookat then
		return false
	end
	local _, _, start_z = PointXYZ(start_eye)
	local _, _, target_z = PointXYZ(target_eye)
	-- Only the overview->selection descent: starts from the high overview eye and
	-- lands at a low selection eye. Tunable-ish constants chosen well between the
	-- two (overview eye ~1.0M, selection eye ~60k).
	if type(start_z) ~= "number" or type(target_z) ~= "number" or start_z <= 500000 or target_z >= 300000 then
		return false
	end
	local create_thread = Global("CreateRealTimeThread")
	local sleep = Global("Sleep")
	if type(create_thread) ~= "function" or type(sleep) ~= "function" then
		return false
	end
	local zoom_plus = Global("SuperBigMapZoomPlus")
	if
		type(zoom_plus) ~= "table"
		or type(zoom_plus.ConsumeFirstOverviewExitTakeover) ~= "function"
		or zoom_plus.ConsumeFirstOverviewExitTakeover() ~= true
	then
		return false
	end
	exit_takeover_token = exit_takeover_token + 1
	local token = exit_takeover_token
	create_thread(function()
		local frame = 16
		local steps = math.max(2, math.floor(time / frame))
		for i = 1, steps do
			if token ~= exit_takeover_token then
				return
			end
			-- smoothstep ease on t=i/steps, integer-safe in a 0..1000 domain.
			local ts = i * 1000 / steps
			local ease = ts * ts * (3000 - 2 * ts) / 1000 / 1000
			local e = PointLerp(point_fn, start_eye, target_eye, ease, 1000)
			local l = PointLerp(point_fn, start_lookat, target_lookat, ease, 1000)
			if e and l then
				pcall(camera.SetCamera, e, l, 0)
			end
			sleep(frame)
		end
		if token == exit_takeover_token then
			pcall(camera.SetCamera, target_eye, target_lookat, 0)
		end
	end)
	return true
end

function OverviewCamera.ApplyModBehavior()
	PatchOverviewFov()
	PatchOverviewCamera()
end

function OverviewCamera.RestoreVanillaBehavior()
	-- Restore only if our wrapper still owns the global. If an environment reload or
	-- another system has replaced it, writing the stale original back would clobber
	-- that newer owner.
	if overview_camera_patched and original_calc_overview_camera_pos
		and Global("CalcOverviewCameraPos") == overview_camera_wrapper then
		_G.CalcOverviewCameraPos = original_calc_overview_camera_pos
	end
	original_calc_overview_camera_pos = false
	overview_camera_wrapper = false
	overview_camera_patched = false

	local const = Global("const")
	if type(const) == "table" and type(const.Camera) == "table" then
		pcall(function()
			if const.Camera.SuperBigMapOriginalOverviewFovX_16_9 ~= nil then
				const.Camera.OverviewFovX_16_9 = const.Camera.SuperBigMapOriginalOverviewFovX_16_9
				const.Camera.SuperBigMapOriginalOverviewFovX_16_9 = nil
			end
			if const.Camera.SuperBigMapOriginalOverviewFovX_4_3 ~= nil then
				const.Camera.OverviewFovX_4_3 = const.Camera.SuperBigMapOriginalOverviewFovX_4_3
				const.Camera.SuperBigMapOriginalOverviewFovX_4_3 = nil
			end
		end)
	end

	-- Cancel any pending scheduled refresh so it cannot re-apply framing.
	overview_reset_token = overview_reset_token + 1
	-- Cancel an in-flight first-overview exit takeover too; otherwise its real-time
	-- thread can write one last expanded camera pose after the main menu is open.
	exit_takeover_token = exit_takeover_token + 1
end

SuperBigMap.OverviewCamera = OverviewCamera

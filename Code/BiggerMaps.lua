local MOD_PREFIX = "[Bigger Maps] "

local function Global(name)
	return rawget(_G, name)
end

local function SafeCall(fn, ...)
	if type(fn) ~= "function" then
		return nil
	end

	local ok, result, result2 = pcall(fn, ...)
	if ok then
		return result, result2
	end

	return nil
end

local function Config()
	local config = Global("BiggerMapsConfig")
	return type(config) == "table" and config or {}
end

local function ConfigNumber(name, default, min_value)
	local value = Config()[name]
	if type(value) == "number" and (min_value == nil or value >= min_value) then
		return value
	end
	return default
end

local function ConfigOptionalNumber(name, min_value)
	local value = Config()[name]
	if type(value) == "number" and (min_value == nil or value >= min_value) then
		return value
	end
	return false
end

local function ConfigBool(name, default)
	local value = Config()[name]
	if type(value) == "boolean" then
		return value
	end
	return default
end

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

local function FullHeightMin()
	return Global("min_int") or -2147483647
end

local function FullHeightMax()
	return Global("max_int") or 2147483647
end

local OVERVIEW_DISTANCE_MULTIPLIER = ConfigNumber("OverviewDistanceMultiplier", 2.5, 0)
local OVERVIEW_MIN_HEIGHT_PERCENT = ConfigNumber("OverviewMinHeightPercent", 140, 0)
local OVERVIEW_CAMERA_XY_PERCENT = ConfigNumber("OverviewCameraXYPercent", 28, 0)
local OVERVIEW_ZOOM_DISTANCE_PERCENT = ConfigNumber("OverviewZoomDistancePercent", 140, 0)
local OVERVIEW_NUDGE_HORIZONTAL_PERCENT = ConfigNumber("OverviewNudgeHorizontalPercent", 0)
local OVERVIEW_NUDGE_VERTICAL_PERCENT = ConfigNumber("OverviewNudgeVerticalPercent", 0)
local OVERVIEW_VIEW_ANGLE_DEGREES = ConfigOptionalNumber("OverviewViewAngleDegrees")
local OVERVIEW_FOV_16_9 = ConfigNumber("OverviewFovX16_9", 3600, 1)
local OVERVIEW_FOV_4_3 = ConfigNumber("OverviewFovX4_3", 3400, 1)
local OVERVIEW_FAR_Z = ConfigNumber("OverviewFarZ", 12000000, 1)
local OVERVIEW_HR_KEY = "BiggerMapsOverview"
local NORMAL_ZOOM_ENABLED = ConfigBool("EnableNormalZoomPlus", true)
local NORMAL_ZOOM_MULTIPLIER = ConfigNumber(
	"ZoomPlusLookatDistZoomOutMultiplier",
	ConfigNumber("NormalZoomMultiplier", 4.0, 1.01),
	1.01
)
local ALLOW_ZOOMPLUS_WITH_SCENARIO_EDITOR_HOST = ConfigBool("AllowZoomPlusWithScenarioEditorHost", true)
local HIDE_OVERVIEW_CURTAINS = ConfigBool("HideOverviewCurtains", true)
local DEBUG_PRINT = ConfigBool("EnableDiagnosticLogs", ConfigBool("DebugPrint", true))
local overview_camera_patched = false
local original_calc_overview_camera_pos = false
local original_calc_overview_curtains_size = false
local original_show_overview_map_curtains = false
local original_set_overview_curtains = false
local overview_render_distance_active = false
local overview_render_original_hr = false
local overview_reset_token = 0

local function FullMapPlayableEnabled()
	return ConfigBool("BiggerMapsFullMapPlayable", true)
end

local function ResetMapDataBounds(map, mapdata)
	if not FullMapPlayableEnabled() then
		return
	end

	mapdata = mapdata or map and map.mapdata
	if not mapdata then
		return
	end

	if mapdata.BiggerMapsOriginalPassBorder == nil then
		mapdata.BiggerMapsOriginalPassBorder = mapdata.PassBorder
	end
	if mapdata.BiggerMapsOriginalPlayableHeightRange == nil then
		mapdata.BiggerMapsOriginalPlayableHeightRange = mapdata.playable_height_range
	end
	if mapdata.BiggerMapsOriginalVisibleHeightRange == nil then
		mapdata.BiggerMapsOriginalVisibleHeightRange = mapdata.visible_height_range
	end

	-- The sector code decides the border: 0 for grids anchored at the map corner,
	-- or the vanilla grid offset for "expanded_with_vanilla_grid" (so the engine's
	-- selection overlay, anchored at PassBorder, stays aligned with the sectors).
	local resolve_border = Global("BiggerMaps_ResolveMapBorder")
	local new_border = (type(resolve_border) == "function" and SafeCall(resolve_border, map)) or 0
	if type(new_border) ~= "number" or new_border < 0 then
		new_border = 0
	end
	mapdata.PassBorder = new_border
	local width = TerrainSize(map)
	if new_border > 0 and width and width > 0 and type(mapdata.Width) == "number" and mapdata.Width > 0 then
		mapdata.PassBorderTiles = math.floor(new_border * mapdata.Width / width + 0.5)
	else
		mapdata.PassBorderTiles = 0
	end
	if DEBUG_PRINT and Global("print") then
		print(MOD_PREFIX .. "ResetMapDataBounds set PassBorder=" .. tostring(new_border) .. " (mapdata.Width=" .. tostring(mapdata.Width) .. ")")
	end
	mapdata.playable_height_range = false
	mapdata.visible_height_range = false

	if map then
		map.playable_height_range = false
	end
end

local function ResetMapAreas(map)
	if not FullMapPlayableEnabled() or not map then
		return
	end

	local width, height = TerrainSize(map)
	if not width or not height or width <= 0 or height <= 0 then
		return
	end

	if type(map.SetPlayArea) == "function" then
		SafeCall(map.SetPlayArea, map, false, true)
	elseif Global("box") then
		map.PlayArea = box(0, 0, 0, width, height, FullHeightMax())
	end

	if Global("box") then
		map.ConstructableArea = box(0, 0, width, height)
	end

	local camera = Global("cameraRTS")
	if camera and type(camera.SetBoundingBox) == "function" then
		local area = type(map.GetPlayArea) == "function" and SafeCall(map.GetPlayArea, map) or map.PlayArea
		if area then
			SafeCall(camera.SetBoundingBox, area)
		end
	end
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

local function ApplyOverviewRenderDistance(enable)
	local hr = Global("hr")
	if type(hr) ~= "table" then
		return
	end

	if enable then
		if overview_render_distance_active then
			hr.FarZ = OVERVIEW_FAR_Z
			hr.ShadowRangeOverride = OVERVIEW_FAR_Z
			hr.ShadowFadeOutRangePercent = 0
			return
		end

		overview_render_original_hr = {
			FarZ = hr.FarZ,
			ShadowRangeOverride = hr.ShadowRangeOverride,
			ShadowFadeOutRangePercent = hr.ShadowFadeOutRangePercent,
		}

		local table_api = Global("table")
		local changed = false
		if table_api and type(table_api.change) == "function" then
			changed = pcall(table_api.change, hr, OVERVIEW_HR_KEY, {
				FarZ = OVERVIEW_FAR_Z,
				ShadowRangeOverride = OVERVIEW_FAR_Z,
				ShadowFadeOutRangePercent = 0,
			})
		end

		if not changed then
			hr.FarZ = OVERVIEW_FAR_Z
			hr.ShadowRangeOverride = OVERVIEW_FAR_Z
			hr.ShadowFadeOutRangePercent = 0
		end
		overview_render_distance_active = true
	else
		if not overview_render_distance_active then
			return
		end

		local table_api = Global("table")
		local restored = false
		if table_api and type(table_api.restore) == "function" then
			restored = pcall(table_api.restore, hr, OVERVIEW_HR_KEY)
		end

		if not restored and overview_render_original_hr then
			hr.FarZ = overview_render_original_hr.FarZ
			hr.ShadowRangeOverride = overview_render_original_hr.ShadowRangeOverride
			hr.ShadowFadeOutRangePercent = overview_render_original_hr.ShadowFadeOutRangePercent
		end
		overview_render_distance_active = false
		overview_render_original_hr = false
	end
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

local function HideOverviewCurtains()
	if not HIDE_OVERVIEW_CURTAINS then
		return
	end

	local get_dialog = Global("GetDialog")
	local dlg = type(get_dialog) == "function" and SafeCall(get_dialog, "OverviewMapCurtains") or false
	if not dlg then
		return
	end

	if type(dlg.SetOverviewCurtains) == "function" then
		SafeCall(dlg.SetOverviewCurtains, dlg, 0, 0)
	end
	if type(dlg.SetVisible) == "function" then
		SafeCall(dlg.SetVisible, dlg, false, "instant")
	end
end

local function PatchOverviewCurtains()
	if not HIDE_OVERVIEW_CURTAINS then
		return
	end

	if not original_calc_overview_curtains_size and type(Global("CalcOverviewCurtainsSize")) == "function" then
		original_calc_overview_curtains_size = Global("CalcOverviewCurtainsSize")
		_G.CalcOverviewCurtainsSize = function()
			return 0, 0
		end
	end

	local curtains_class = Global("OverviewMapCurtainsUI")
	if
		type(curtains_class) == "table"
		and type(curtains_class.SetOverviewCurtains) == "function"
		and not original_set_overview_curtains
	then
		original_set_overview_curtains = curtains_class.SetOverviewCurtains
		curtains_class.SetOverviewCurtains = function(self)
			return original_set_overview_curtains(self, 0, 0)
		end
	end

	if not original_show_overview_map_curtains and type(Global("ShowOverviewMapCurtains")) == "function" then
		original_show_overview_map_curtains = Global("ShowOverviewMapCurtains")
		_G.ShowOverviewMapCurtains = function(show, force_close)
			if show then
				HideOverviewCurtains()
				return
			end
			return original_show_overview_map_curtains(false, force_close)
		end
	end

	HideOverviewCurtains()
end

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
	PatchOverviewFov()
	PatchOverviewCamera()
	PatchOverviewCurtains()

	if not (Global("IsOverviewMode") and IsOverviewMode()) then
		return false
	end

	ApplyOverviewRenderDistance(true)
	HideOverviewCurtains()
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

local function RebuildMapBounds(map)
	local terrain_api = Global("terrain")

	if terrain_api and type(terrain_api.SetPassableHeight) == "function" then
		SafeCall(terrain_api.SetPassableHeight, map, FullHeightMin(), FullHeightMax())
	end

	if terrain_api and type(terrain_api.RebuildPassability) == "function" then
		SafeCall(terrain_api.RebuildPassability, map)
	end

	local rebuild_buildable = Global("RebuildBuildableGrid")
	if type(rebuild_buildable) == "function" and map and map.buildable then
		SafeCall(rebuild_buildable, map)
	end
end

local function RefreshSectors(map)
	local city = map and map.City
	local sectors = city and city.MapSectors
	local tile_size_fn = Global("GetMapSectorTileSize")
	local box_fn = Global("box")

	if type(sectors) ~= "table" or #sectors == 0 or type(tile_size_fn) ~= "function" or not box_fn then
		return
	end

	local tile = SafeCall(tile_size_fn, map)
	if not tile or tile <= 0 then
		return
	end

	local sector_count = Global("const") and const.SectorCount or 10
	local unbuildable_z = Global("buildUnbuildableZ") and buildUnbuildableZ() or false
	local build_ratio = Global("BuildableGridRatio")

	for j = 1, sector_count do
		local row = sectors[j]
		if type(row) == "table" then
			local x = (j - 1) * tile
			for i = 1, sector_count do
				local sector = row[i]
				if sector then
					local y = (i - 1) * tile
					sector.area = box_fn(x, y, x + tile, y + tile)

					if type(build_ratio) == "function" and map.buildable and map.buildable.z_grid and unbuildable_z then
						sector.play_ratio = SafeCall(build_ratio, map.buildable.z_grid, unbuildable_z, 100, sector.area) or sector.play_ratio
					end

					if type(sector.UpdateDecal) == "function" then
						SafeCall(sector.UpdateDecal, sector)
					end
				end
			end
		end
	end

	if type(city.InitMapArea) == "function" then
		SafeCall(city.InitMapArea, city)
	end
end

function BiggerMaps_Apply(map, rebuild)
	map = ResolveLiveMap(map)
	if not map then
		return false
	end

	PatchOverviewFov()
	PatchOverviewCamera()
	PatchOverviewCurtains()
	ApplyNormalZoom()
	ResetMapDataBounds(map, map.mapdata)
	ResetMapAreas(map)

	if rebuild and FullMapPlayableEnabled() then
		RebuildMapBounds(map)
		RefreshSectors(map)
	end

	ApplyOverviewRenderDistance(Global("IsOverviewMode") and IsOverviewMode())
	ResetOverviewCamera(map, 0)

	if DEBUG_PRINT and Global("print") then
		local width, height = TerrainSize(map)
		print(MOD_PREFIX .. string.format("playable bounds reset to full terrain (%s x %s)", tostring(width), tostring(height)))
	end

	return true
end

local function ChainOnMsg(message_name, handler)
	local previous = OnMsg[message_name]

	OnMsg[message_name] = function(...)
		if previous then
			previous(...)
		end

		handler(...)
	end
end

ChainOnMsg("PreNewMap", function(map, mapdata)
	ResetMapDataBounds(map, mapdata)
end)

ChainOnMsg("NewMap", function(map, mapdata)
	BiggerMaps_Apply(map, true)
end)

ChainOnMsg("NewMapLoaded", function(map, mapdata)
	BiggerMaps_Apply(map, false)
end)

ChainOnMsg("PostNewMapLoaded", function(map, mapdata)
	BiggerMaps_Apply(map, true)
end)

ChainOnMsg("LoadGame", function()
	BiggerMaps_Apply(Global("CurrentMap"), true)
end)

ChainOnMsg("CurrentMapChangeDone", function(map_slot, map)
	BiggerMaps_Apply(map, true)
end)

ChainOnMsg("ClassesPostprocess", function()
	PatchOverviewFov()
	PatchOverviewCamera()
	PatchOverviewCurtains()
	ApplyNormalZoom()
end)

ChainOnMsg("DataLoaded", function()
	PatchOverviewFov()
	PatchOverviewCamera()
	PatchOverviewCurtains()
	ApplyNormalZoom()
end)

ChainOnMsg("OverviewMode", function(enabled)
	if enabled then
		RefreshOverviewCamera()
		ScheduleOverviewCameraRefresh()
	else
		overview_reset_token = overview_reset_token + 1
		ApplyOverviewRenderDistance(false)
	end
end)

ChainOnMsg("CameraTransitionEnd", function()
	ApplyNormalZoom()
	RefreshOverviewCamera()
end)

BiggerMaps_Apply(Global("CurrentMap"), true)

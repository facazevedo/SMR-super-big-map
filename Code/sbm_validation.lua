-- Super Big Map -- diagnostic self-checks (logs only, no behavior).
--
-- Cheap, read-only snapshots of the mod's runtime state, written through the
-- centralized logger. Called by the lifecycle around Enable/Disable when DEBUG_LOGS
-- is on, and available to call by hand from the console for troubleshooting. These
-- never change engine state.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global

local function log(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Validation", message, data)
	end
end

local function log_error(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog and type(DebugLog.Error) == "function" then
		DebugLog.Error("Validation", message, data)
	else
		log(message, data)
	end
end

local Validation = {}

local function IsPermanentTransitionStateKey(key)
	key = tostring(key or "")
	return key:find("^main_menu_") ~= nil
		or key:find("^original_main_menu_") ~= nil
		or key:find("^reset_game_session_") ~= nil
		or key == "original_reset_game_session"
		or key:find("^open_pregame_main_menu_reset_") ~= nil
		or key == "original_open_pregame_main_menu"
end

local function ResidualPatchState(State)
	local residual = {}
	for key, value in pairs(State or {}) do
		if value ~= nil and not IsPermanentTransitionStateKey(key) then
			local patchish = key:find("wrapper", 1, true)
				or key:find("original_", 1, true) == 1
				or key:find("_patch_version", 1, true)
				or key:find("_build_version", 1, true)
			if patchish then residual[#residual + 1] = tostring(key) end
		end
	end
	table.sort(residual)
	return residual
end

local function PollutedMapDataPresets()
	local polluted = {}
	local map_data = Global("MapData")
	if type(map_data) ~= "table" then return polluted end
	for name, mapdata in pairs(map_data) do
		if type(mapdata) == "table" then
			local fields = {}
			for key, value in pairs(mapdata) do
				if value ~= nil and tostring(key):find("^SuperBigMap") then
					fields[#fields + 1] = tostring(key)
				end
			end
			if #fields > 0 then
				table.sort(fields)
				polluted[#polluted + 1] = tostring(name) .. ":" .. table.concat(fields, "+")
			end
		end
	end
	table.sort(polluted)
	return polluted
end

-- After Enable: patches should be installed (version guards set, globals patched).
function Validation.CheckRuntimeState()
	local State = SuperBigMap.State or {}
	local const = Global("const")
	log("runtime state", {
		active = State.active == true,
		sector_patch = State.sector_patch_version,
		sector_basic_patch = State.sector_basic_patch_version,
		highlight_patch = State.overview_highlight_patch_version,
		generator_patch = State.generator_patch_version,
		sector_count = const and const.SectorCount,
		get_tile_size = type(Global("GetMapSectorTileSize")),
		calc_overview = type(Global("CalcOverviewCameraPos")),
	})
	return true
end

-- After Disable: the patch guards should be cleared (nil) and globals restored.
function Validation.CheckVanillaRestoration()
	local State = SuperBigMap.State or {}
	local const = Global("const")
	local camera = type(const) == "table" and const.Camera
	local residual = ResidualPatchState(State)
	local polluted = PollutedMapDataPresets()
	local zoom_plus = Global("SuperBigMapZoomPlus")
	local zoom_enabled = type(zoom_plus) == "table" and type(zoom_plus.IsEnabled) == "function"
		and Engine.SafeCall(zoom_plus.IsEnabled) == true
	local heat = SuperBigMap.HeatSafety
	local heat_patched = type(heat) == "table" and type(heat.IsPatched) == "function"
		and heat.IsPatched() == true
	local overview_camera = SuperBigMap.OverviewCamera
	local camera_patched = type(overview_camera) == "table" and type(overview_camera.IsPatched) == "function"
		and overview_camera.IsPatched() == true
	local curtains = SuperBigMap.OverviewCurtains
	local curtains_patched = type(curtains) == "table" and type(curtains.IsPatched) == "function"
		and curtains.IsPatched() == true
	local render = SuperBigMap.OverviewRender
	local render_active = type(render) == "table" and type(render.IsActive) == "function"
		and render.IsActive() == true
	local zoom_option = SuperBigMap.ZoomOption
	local zoom_option_installed = type(zoom_option) == "table" and type(zoom_option.IsInstalled) == "function"
		and zoom_option.IsInstalled() == true
	local current_params = Global("g_CurrentMapParams")
	local expand_param_armed = type(current_params) == "table"
		and current_params.SuperBigMapExpandMap == true
	local ok = State.active ~= true
		and type(const) == "table" and const.SectorCount == 10
		and State.original_enable_darkness_reveal_captured ~= true
		and State.restore_in_game_interface_wrapper == nil
		and not zoom_enabled and not zoom_option_installed and not expand_param_armed and not heat_patched
		and not camera_patched and not curtains_patched and not render_active
		and #residual == 0 and #polluted == 0
		and not (type(camera) == "table" and (
			camera.SuperBigMapOriginalOverviewFovX_16_9 ~= nil
			or camera.SuperBigMapOriginalOverviewFovX_4_3 ~= nil))
	local data = {
		ok = ok,
		active = State.active == true,
		sector_patch = State.sector_patch_version,
		sector_basic_patch = State.sector_basic_patch_version,
		highlight_patch = State.overview_highlight_patch_version,
		generator_patch = State.generator_patch_version,
		original_sector_count = State.original_sector_count,
		sector_count = (Global("const") or {}).SectorCount,
		darkness_override_captured = State.original_enable_darkness_reveal_captured == true,
		restore_interface_wrapper = State.restore_in_game_interface_wrapper ~= nil,
		zoomplus_enabled = zoom_enabled,
		zoom_option_installed = zoom_option_installed,
		expand_param_armed = expand_param_armed,
		heat_patched = heat_patched,
		overview_camera_patched = camera_patched,
		overview_curtains_patched = curtains_patched,
		overview_render_active = render_active,
		residual_patch_state = table.concat(residual, ","),
		polluted_mapdata_presets = table.concat(polluted, ","),
		fov_capture_present = type(camera) == "table" and (
			camera.SuperBigMapOriginalOverviewFovX_16_9 ~= nil
			or camera.SuperBigMapOriginalOverviewFovX_4_3 ~= nil) or false,
	}
	if ok then log("vanilla restoration verified", data)
	else log_error("VANILLA RESTORATION MISMATCH", data) end
	return ok, data
end

-- Deep non-expanded-map audit.  The wrappers may be installed so a later opt-in
-- game can expand, but all shared values and live map data must be vanilla.
function Validation.CheckVanillaMapState(map, reason)
	local State = SuperBigMap.State or {}
	local const = Global("const")
	local expected = 10
	local grid = SuperBigMap.SectorGrid
	if grid and type(grid.VanillaSectorCount) == "function" then
		local ok, value = pcall(grid.VanillaSectorCount)
		if ok and type(value) == "number" then expected = value end
	end
	local city = map and map.City
	local sectors = city and city.MapSectors
	local cols, rows = 0, 0
	if type(sectors) == "table" then
		while type(sectors[cols + 1]) == "table" do cols = cols + 1 end
		if cols > 0 then
			while sectors[1][rows + 1] ~= nil do rows = rows + 1 end
		end
	end
	local mapdata = map and map.mapdata
	local map_fields, preset_fields = {}, {}
	for key, value in pairs(type(map) == "table" and map or {}) do
		if value ~= nil and tostring(key):find("^SuperBigMap")
			and key ~= "SuperBigMapOldSaveWarned" then
			map_fields[#map_fields + 1] = tostring(key)
		end
	end
	for key, value in pairs(type(mapdata) == "table" and mapdata or {}) do
		if value ~= nil and tostring(key):find("^SuperBigMap") then
			preset_fields[#preset_fields + 1] = tostring(key)
		end
	end
	table.sort(map_fields)
	table.sort(preset_fields)
	local map_polluted = #map_fields > 0
	local preset_polluted = #preset_fields > 0
	local zoom_plus = Global("SuperBigMapZoomPlus")
	local zoom_enabled = type(zoom_plus) == "table" and type(zoom_plus.IsEnabled) == "function"
		and Engine.SafeCall(zoom_plus.IsEnabled) == true
	local sector_count_ok = type(const) == "table" and const.SectorCount == expected
	local live_grid_ok = cols == 0 or (cols == expected and rows == expected)
	local zoom_option = SuperBigMap.ZoomOption
	local zoom_option_installed = type(zoom_option) == "table" and type(zoom_option.IsInstalled) == "function"
		and zoom_option.IsInstalled() == true
	local ok = sector_count_ok and live_grid_ok and not map_polluted and not preset_polluted
		and not zoom_enabled and not zoom_option_installed
		and State.original_enable_darkness_reveal_captured ~= true
	local data = {
		reason = tostring(reason or "?"), ok = ok,
		map = tostring(map and (map.name or (mapdata and mapdata.id)) or "?"),
		sector_count = type(const) == "table" and const.SectorCount or "missing",
		expected_sector_count = expected,
		grid = tostring(cols) .. "x" .. tostring(rows),
		map_state_polluted = map_polluted,
		mapdata_state_polluted = preset_polluted,
		map_state_fields = table.concat(map_fields, ","),
		mapdata_state_fields = table.concat(preset_fields, ","),
		zoomplus_enabled = zoom_enabled,
		zoom_option_installed = zoom_option_installed,
		darkness_override_captured = State.original_enable_darkness_reveal_captured == true,
	}
	if ok then log("vanilla map state verified", data)
	else log_error("VANILLA MAP STATE MISMATCH", data) end
	return ok, data
end

-- Snapshot of the optional ZoomPlus integration.
function Validation.CheckIntegrations()
	local zoom_plus = Global("SuperBigMapZoomPlus")
	local present = type(zoom_plus) == "table"
	local enabled = false
	if present and type(zoom_plus.IsEnabled) == "function" then
		local ok, result = pcall(zoom_plus.IsEnabled)
		enabled = ok and result == true
	end
	log("integrations", {
		zoomplus_present = present,
		zoomplus_enabled = enabled,
	})
	return true
end

SuperBigMap.Validation = Validation

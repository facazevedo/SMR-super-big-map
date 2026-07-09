-- Super Big Map -- reversible lifecycle + the single OnMsg site.
--
-- Owns the master Enable/Disable (idempotent) and the per-map Apply. Enable installs
-- every domain's behavior (ApplyModBehavior) and applies it to the current map;
-- Disable restores vanilla (RestoreVanillaBehavior) in reverse order. ALL OnMsg
-- handlers live here, registered once and gated on IsActive(), each delegating to the
-- domain modules in the order the originals ran (e.g. tile quadrants before building
-- sectors on MapGenerated). No engine patching lives here -- only orchestration.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

SuperBigMap.State = SuperBigMap.State or {}

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall

-- Register an OnMsg handler at most ONCE per message per session, even across mod
-- hot-reloads. Engine.ChainOnMsg CHAINS (wraps the previous handler), so a mid-game
-- reload -- which re-executes this module -- would otherwise STACK our handlers and run
-- each event 2x, 3x, ... That double-ran the map-change handlers and tripped the engine's
-- re-entrancy assert (not IsChangingMap()) in DoneGame during pre-game generation. The
-- guard flag lives in State, which persists across reloads, so re-execution is a no-op.
-- (Handlers delegate to SuperBigMap.<module> functions read at call time, so reloaded
-- domain logic still applies even though the handler itself is registered only once.)
local function RegisterOnce(message_name, handler)
	local State = SuperBigMap.State
	State.registered_msgs = State.registered_msgs or {}
	if State.registered_msgs[message_name] then
		return
	end
	State.registered_msgs[message_name] = true
	Engine.ChainOnMsg(message_name, handler)
end

-- Init-sequence trace (gated on Config.DEBUG_INIT_SEQUENCE via DebugLog.InitSeq).
local function InitSeq(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog and type(DebugLog.InitSeq) == "function" then
		DebugLog.InitSeq(message, data)
	end
end

-- Map liveness / terrain size are intentionally NOT in sbm_engine (their resolution
-- order is context-specific); kept local for map resolution + the apply log.
local IsLiveMap = Engine.IsLiveMap

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

-- Authoritative "was this map generated/expanded by the mod?" gate (delegates to
-- SuperBigMap.SectorGrid). All per-map mod work is skipped when this is false, so
-- a vanilla map / an old save started without the mod is left completely untouched.
local function IsModMap(map)
	local grid = SuperBigMap.SectorGrid
	if grid and type(grid.IsModMap) == "function" then
		return grid.IsModMap(map) == true
	end
	return false
end

-- On loading a save that was NOT started with Super Big Map, warn once (per load)
-- that the expanded map needs a NEW game; the mod then stays completely inert and
-- the old save plays vanilla. The guard flag is TRANSIENT (set on the map instance,
-- which is rebuilt each load) so NOTHING is written into the save -- a vanilla save
-- must never gain mod markers, or it would look mod-started on the next load.
-- Returns true when the map is a non-mod save (so the caller skips all mod work).
local function WarnOldSaveIfNeeded(map)
	if IsModMap(map) then
		return false
	end

	local cfg = SuperBigMap.Config or {}
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		-- Diagnostic for the "expanded save loads as vanilla" case (no overview grid, no
		-- deposits, false old-save warning): show why IsModMap returned false on this load.
		local mapdata = map and map.mapdata
		local mw = (map and type(map.Width) == "number") and map.Width or 0
		local mdw = (type(mapdata) == "table" and type(mapdata.Width) == "number") and mapdata.Width or 0
		DebugLog.Info("Lifecycle", "IsModMap=false on load -- staying inert (vanilla); detection inputs", {
			map = tostring(map and (map.name or (map.mapdata and map.mapdata.id)) or "map"),
			warn_enabled = cfg.WARN_OLD_SAVE_NEEDS_NEW_GAME == true,
			SuperBigMapExpanded = tostring(map and map.SuperBigMapExpanded),
			map_width = mw,
			mapdata_width = mdw,
			wu_per_tile = (mdw > 0) and (mw / mdw) or "?",
		})
	end

	if cfg.WARN_OLD_SAVE_NEEDS_NEW_GAME ~= true then
		return true
	end
	if not map or map.SuperBigMapOldSaveWarned == true then
		return true
	end
	map.SuperBigMapOldSaveWarned = true

	local detail =
		"This save was started without Super Big Map.\n\n" ..
		"The expanded map only applies to games STARTED with the mod enabled, so " ..
		"this save keeps its original size and the mod stays inactive here.\n\n" ..
		"Start a NEW game to use Super Big Map. Otherwise this save will continue " ..
		"to play normally."
	local create_box = Global("CreateMessageBox")
	if type(create_box) == "function" then
		pcall(create_box, nil, "Super Big Map", detail)
	elseif DebugLog then
		DebugLog.Info("Lifecycle", "WarnOldSaveIfNeeded: CreateMessageBox unavailable -- logged only")
	end
	return true
end

local TerrainSize = Engine.TerrainSize

-- Re-install the static overview patches (FOV widen, camera override, curtain stubs)
-- and re-apply ZoomPlus. Delegates to the extracted domain modules.
local function ApplyOverviewPatches()
	local camera = SuperBigMap.OverviewCamera
	local curtains = SuperBigMap.OverviewCurtains
	local zoom = SuperBigMap.ZoomPlusIntegration

	if camera then
		camera.PatchOverviewFov()
		camera.PatchOverviewCamera()
	end
	if curtains then
		curtains.PatchOverviewCurtains()
	end
	if zoom then
		zoom.ApplyNormalZoom()
	end
end

local Lifecycle = {}

function Lifecycle.IsActive()
	return SuperBigMap.State.active == true
end

-- Per-map application: bring the loaded map's bounds/sectors/overview into the
-- mod's configured state. Safe to call repeatedly (each step is idempotent).
function Lifecycle.Apply(map, rebuild)
	map = ResolveLiveMap(map)
	if not map then
		return false
	end

	-- Keep the global overview patches installed (idempotent) so they are ready
	-- for when a mod map loads -- but they are internally gated to mod maps, so on
	-- a non-mod map they stay vanilla.
	ApplyOverviewPatches()

	-- New-game-only / mod-map-only gate: do NO per-map work (bounds, sector refit,
	-- overview reshaping) on vanilla maps or old saves not started with the mod.
	if not IsModMap(map) then
		local DebugLog = SuperBigMap.DebugLog
		if DebugLog then
			DebugLog.Info("Lifecycle", "skipped: not a mod map (vanilla/non-mod save)", {
				map = tostring(map.name or (map.mapdata and map.mapdata.id) or "map"),
			})
		end
		return false, "not a mod map"
	end

	-- Optional bottom-right "Scan All Sectors" button on mod maps (config-gated; no-op when
	-- SCAN_ALL_BUTTON_ENABLED is off; idempotent).
	local scan_btn = SuperBigMap.ScanAllButton
	if scan_btn and type(scan_btn.Show) == "function" then
		scan_btn.Show()
	end

	local bounds = SuperBigMap.MapBounds
	if bounds then
		bounds.ResetMapDataBounds(map, map.mapdata)
		bounds.ResetMapAreas(map)

		if rebuild and bounds.FullMapPlayableEnabled() then
			bounds.RebuildMapBounds(map)
			bounds.RefreshSectors(map)
		end
	end

	local render = SuperBigMap.OverviewRender
	if render then
		render.Apply(Global("IsOverviewMode") and IsOverviewMode())
	end
	local camera = SuperBigMap.OverviewCamera
	if camera then
		camera.ResetOverviewCamera(map, 0)
	end

	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		local width, height = TerrainSize(map)
		DebugLog.Info("Lifecycle", "playable bounds reset to full terrain", { width = width, height = height })
	end

	return true
end

-- Install order (dependencies first); restore is the exact reverse.
local APPLY_ORDER = {
	"PregameToggle",
	"MapGeneration",
	"SectorGrid",
	"SectorExploration",
	"SectorHighlight",
	"OverviewCamera",
	"OverviewCurtains",
	"OverviewRender",
	"ZoomPlusIntegration",
	"MapBounds",
	"FakeTerrain",
	"RocketRules",
	"HeatSafety",
}

local RESTORE_ORDER = {
	"HeatSafety",
	"RocketRules",
	"FakeTerrain",
	"MapBounds",
	"ZoomPlusIntegration",
	"OverviewRender",
	"OverviewCurtains",
	"OverviewCamera",
	"SectorHighlight",
	"SectorExploration",
	"SectorGrid",
	"MapGeneration",
	"PregameToggle",
}

local function run_phase(order, method)
	for i = 1, #order do
		local mod = SuperBigMap[order[i]]
		if type(mod) == "table" and type(mod[method]) == "function" then
			SafeCall(mod[method])
		end
	end
end

-- Log every ACTIVE (loaded) mod this session plus the editor/ZoomPlus context. Always
-- prints (one block) so we can see exactly which mods are live and why the camera is
-- being reshaped -- e.g. whether the Scenario Editor mod is actually loaded, and which
-- ZoomPlus instance owns the global. Gated by DEBUG_LOGS (Config.EnableDiagnosticLogs).
local function LogSessionDiagnostics()
	-- Gated like all mod debug output: only when Config.EnableDiagnosticLogs (DEBUG_LOGS) is on.
	if (SuperBigMap.Config or {}).DEBUG_LOGS ~= true then
		return
	end
	local print_fn = rawget(_G, "print")
	if type(print_fn) ~= "function" then
		return
	end
	local mods = Global("ModsLoaded")
	print_fn("[Super Big Map] ActiveMods: ===== loaded mods this session =====")
	if type(mods) == "table" then
		for i = 1, #mods do
			local m = mods[i]
			if type(m) == "table" then
				print_fn(string.format("[Super Big Map] ActiveMods:   %s | id=%s | v=%s",
					tostring(m.title or "?"), tostring(m.id or "?"), tostring(m.version or m.ModVersion or "?")))
			end
		end
	else
		print_fn("[Super Big Map] ActiveMods: (ModsLoaded unavailable)")
	end

	local is_editor = Global("IsEditorActive")
	local zoom_plus = Global("SuperBigMapZoomPlus")
	local scenario = rawget(_G, "ScenarioEditor")
	local mode_fn = rawget(_G, "ScenarioEditor_ModeIsActive")
	print_fn(string.format(
		"[Super Big Map] ActiveMods: context editor_active=%s ScenarioEditor_present=%s ScenarioEditor_ModeIsActive_present=%s ZoomPlus_present=%s ZoomPlus_enabled=%s",
		tostring(type(is_editor) == "function" and is_editor() or "no_fn"),
		tostring(scenario ~= nil),
		tostring(type(mode_fn) == "function"),
		tostring(type(zoom_plus) == "table"),
		tostring(type(zoom_plus) == "table" and zoom_plus.enabled)))
	print_fn("[Super Big Map] ActiveMods: ====================================")
end

function Lifecycle.Enable()
	local cfg = SuperBigMap.Config or {}
	if cfg.ENABLE_MOD == false then
		local DebugLog = SuperBigMap.DebugLog
		if DebugLog then
			DebugLog.Info("Lifecycle", "enable skipped: ENABLE_MOD is false")
		end
		return false
	end

	if Lifecycle.IsActive() then
		return true
	end

	run_phase(APPLY_ORDER, "ApplyModBehavior")
	SuperBigMap.State.active = true
	Lifecycle.Apply(Global("CurrentMap"), true)

	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Lifecycle", "enabled")
	end
	LogSessionDiagnostics()
	if SuperBigMap.Validation then
		SuperBigMap.Validation.CheckRuntimeState()
	end
	-- The "fresh restart needed" notice is fired from the ModsReloaded handler (so it can
	-- tell a runtime toggle from the cold boot via GameUiIsUp), not here.
	return true
end

function Lifecycle.Disable()
	if not Lifecycle.IsActive() then
		return true
	end

	run_phase(RESTORE_ORDER, "RestoreVanillaBehavior")
	SuperBigMap.State.active = false

	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Lifecycle", "disabled (vanilla behavior restored)")
	end
	if SuperBigMap.Validation then
		SuperBigMap.Validation.CheckVanillaRestoration()
	end
	return true
end

SuperBigMap.Lifecycle = Lifecycle

-- ============================================================================
-- The single OnMsg site. Every handler is gated on IsActive() and delegates to
-- the domain modules in the original dispatch order.
-- ============================================================================
local function active()
	return Lifecycle.IsActive()
end

-- True on the MOD EDITOR test map -- the authoritative "leave everything vanilla"
-- signal. IsModEditorMap (engine, GedModEditor.lua) is always available; the world
-- editor's IsEditorActive does NOT exist in normal sessions (it logged no_fn), which
-- is why an earlier gate on it never fired -- kept only as a secondary check.
local function editor_active()
	local fn = Global("IsModEditorMap")
	if type(fn) == "function" then
		local ok, res = pcall(fn)
		if ok and res then
			return true
		end
	end
	local we = Global("IsEditorActive")
	return type(we) == "function" and we() == true
end

-- ---- editor-camera diagnostics (gated on Config.DEBUG_EDITORCAMERA) ------------
local function EditorCamOn()
	local cfg = SuperBigMap.Config or {}
	return cfg.DEBUG_EDITORCAMERA == true
end

local function EditorCamLog(message, data)
	if not EditorCamOn() then
		return
	end
	local parts = {}
	if type(data) == "table" then
		local keys = {}
		for k in pairs(data) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(data[k]) end
	end
	local print_fn = rawget(_G, "print")
	if type(print_fn) == "function" then
		print_fn("[Super Big Map] EditorCam: " .. tostring(message)
			.. (#parts > 0 and (" {" .. table.concat(parts, ", ") .. "}") or ""))
	end
end

-- Flat snapshot of everything that could explain a bugged editor zoom/FOV.
local function CameraSnapshot()
	local snap = {}
	local is_editor = Global("IsEditorActive")
	snap.editor = type(is_editor) == "function" and (is_editor() == true) or false
	local is_ov = Global("IsOverviewMode")
	snap.overview = type(is_ov) == "function" and (SafeCall(is_ov) == true) or false

	local const_tbl = Global("const")
	if type(const_tbl) == "table" and type(const_tbl.Camera) == "table" then
		snap.fov_16_9 = const_tbl.Camera.OverviewFovX_16_9
		snap.fov_4_3 = const_tbl.Camera.OverviewFovX_4_3
		snap.fov_orig_16_9 = const_tbl.Camera.SuperBigMapOriginalOverviewFovX_16_9
	end

	local cam = Global("cameraRTS")
	if type(cam) == "table" then
		if type(cam.GetProperties) == "function" then
			local props = SafeCall(cam.GetProperties, 1)
			if type(props) == "table" then
				snap.zoom_in = props.LookatDistZoomIn
				snap.zoom_out = props.LookatDistZoomOut
				snap.fovx = props.FovX
				snap.zoom_step = props.ZoomStep
			end
		end
		if type(cam.GetZoom) == "function" then snap.zoom = SafeCall(cam.GetZoom) end
		if type(cam.GetEye) == "function" then
			local eye = SafeCall(cam.GetEye)
			if eye and type(eye.z) == "function" then snap.eye_z = SafeCall(eye.z, eye) end
		end
	end

	local zoom_plus = Global("SuperBigMapZoomPlus")
	if type(zoom_plus) == "table" then
		snap.zoomplus_present = true
		snap.zoomplus_enabled = type(zoom_plus.IsEnabled) == "function" and (SafeCall(zoom_plus.IsEnabled) == true) or "?"
	else
		snap.zoomplus_present = false
	end
	return snap
end


-- Welcome-popup warnings, the fresh-restart notice, and the expansion loading box live
-- in sbm_loading_ui (loaded before this module). Bind the two it exposes for the gates
-- below; the rest is reached via its SuperBigMap.* exports at runtime.
local LoadingUI = SuperBigMap.LoadingUI
assert(type(LoadingUI) == "table",
	"sbm_lifecycle: SuperBigMap.LoadingUI missing -- load sbm_loading_ui before this file")
local ShowEditorWarning = LoadingUI.ShowEditorWarning
local NoticeLog = LoadingUI.NoticeLog
assert(type(ShowEditorWarning) == "function" and type(NoticeLog) == "function",
	"sbm_lifecycle: required LoadingUI helpers missing (check sbm_loading_ui exports)")

-- One-time guard so the mod-editor "mod is OFF" warning shows once per editor entry.
local editor_warn_shown = false

-- When on the mod editor map, force Super Big Map fully vanilla: disable ZoomPlus,
-- restore the overview camera/render. Also shows a one-time
-- warning popup on top of the editor's welcome message (see ShowEditorWarning).
-- Called from the map-load events (GameEnterEditor does not fire for the mod editor).
-- Returns true when the mod editor was detected/handled.
local function HandleModEditorMap()
	if not editor_active() then
		-- Left the editor: re-arm the one-time warning for the next editor entry.
		editor_warn_shown = false
		return false
	end
	local zoom = SuperBigMap.ZoomPlusIntegration
	if zoom and type(zoom.RestoreVanillaBehavior) == "function" then zoom.RestoreVanillaBehavior() end
	local cam = SuperBigMap.OverviewCamera
	if cam and type(cam.RestoreVanillaBehavior) == "function" then cam.RestoreVanillaBehavior() end
	local render = SuperBigMap.OverviewRender
	if render and type(render.Apply) == "function" then render.Apply(false) end

	EditorCamLog("mod editor map detected -- forcing vanilla", CameraSnapshot())

	-- Show the warning once per editor entry, on top of the editor's welcome popup.
	-- Several map-load events fire on a single entry; the flag keeps it to one box.
	local cfg = SuperBigMap.Config or {}
	if not editor_warn_shown and cfg.WARN_OLD_SAVE_NEEDS_NEW_GAME == true then
		editor_warn_shown = true
		ShowEditorWarning()
	end
	return true
end

-- Sector lifecycle diagnostic helper. Gated on Config.SHOW_SECTOR_DIAGNOSTICS;
-- when ON, each OnMsg hook below calls this to snapshot the engine's sector
-- state at that exact lifecycle point (city existence, MapSectors size, sector
-- area dimensions, whether our patched InitSectors is still installed). Useful
-- to find out WHEN MapSectors gets populated for pre-built maps that don't
-- run our InitSectors -- the snapshot at MapSectorsReady / CityInitialized
-- shows whether the engine populated MapSectors itself.
local function DiagSnapshotEvent(label, map)
	local sectors = SuperBigMap.SectorExploration
	if sectors and type(sectors.DiagSnapshot) == "function" then
		sectors.DiagSnapshot(label, map)
	end
	-- Single-switch init-sequence timeline: one line per lifecycle event, in order,
	-- with the live sector-grid dimensions at that moment -- so we can see exactly
	-- WHEN a built 20x20 grid loses its frame sectors during initialization.
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog and type(DebugLog.InitSeqOn) == "function" and DebugLog.InitSeqOn() then
		local city = map and map.City
		local describe = (sectors and type(sectors.DescribeCityState) == "function")
			and sectors.DescribeCityState(city) or "?"
		DebugLog.InitSeq("event " .. tostring(label), {
			map = tostring(map and (map.name or (map.mapdata and map.mapdata.id)) or "?"),
			grid = describe,
		})
	end
end

-- Resolve the friendly "named" denomination of the current landing site (e.g.
-- "Marineris Alpha") in addition to the internal map id. g_CurrentMapParams.landing_spot
-- holds the chosen LandingSpot preset id ("" for random/custom coordinates); the
-- matching preset's display_name is the human name. Returns (id, display) where
-- either may be nil when unavailable (e.g. a random-coordinate game has no named spot).
local function ResolveLandingSpotName()
	local params = Global("g_CurrentMapParams")
	local spot_id = (type(params) == "table") and params.landing_spot or nil
	if type(spot_id) ~= "string" or spot_id == "" then
		return nil, nil
	end

	local presets = Global("Presets")
	local groups = (type(presets) == "table") and presets.LandingSpot or nil
	if type(groups) ~= "table" then
		return spot_id, nil
	end

	for _, group in pairs(groups) do
		if type(group) == "table" then
			for _, item in ipairs(group) do
				if type(item) == "table" and item.id == spot_id then
					local display
					local translate = Global("_InternalTranslate")
					if type(translate) == "function" and item.display_name ~= nil then
						local ok, text = pcall(translate, item.display_name)
						if ok and type(text) == "string" and text ~= "" then
							display = text
						end
					end
					return spot_id, display
				end
			end
		end
	end

	return spot_id, nil
end

-- Log the chosen map's name + Mars landing coordinates so the player can tell which
-- map they picked. Gated by Config.ShowChosenMapLog (off in normal play; one line
-- per map load when on). Internal lat/long are
-- degrees*60 (arc-minutes), so /60 ~= degrees; positive lat=N, positive long=E.
-- Logs BOTH denominations: the internal map id (mapdata.id) and the friendly named
-- landing site (LandingSpot display_name / id) when one was chosen.
local function LogChosenMap(map, reason)
	local cfg = SuperBigMap.Config or {}
	if cfg.DEBUG_CHOSENMAP ~= true and cfg.DEBUG_LOGS ~= true then
		return
	end
	map = map or Global("CurrentMap")
	if not map or map.SuperBigMapChosenMapLogged == true then
		return
	end
	map.SuperBigMapChosenMapLogged = true
	local mapdata = map.mapdata
	local params = Global("g_CurrentMapParams")
	local lat = (type(map.latitude) == "number" and map.latitude)
		or (type(params) == "table" and type(params.latitude) == "number" and params.latitude) or nil
	local long = (type(map.longitude) == "number" and map.longitude)
		or (type(params) == "table" and type(params.longitude) == "number" and params.longitude) or nil
	local function deg(v)
		if type(v) ~= "number" then return "?" end
		return string.format("%.2f", math.abs(v) / 60)
	end
	local ns = (type(lat) == "number") and (lat >= 0 and "N" or "S") or ""
	local ew = (type(long) == "number") and (long >= 0 and "E" or "W") or ""
	local spot_id, spot_display = ResolveLandingSpotName()
	local named
	if spot_id and spot_display then
		named = string.format("%s (\"%s\")", spot_id, spot_display)
	elseif spot_id then
		named = spot_id
	else
		named = "none (random/custom coordinates)"
	end
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("ChosenMap", string.format(
			"via %s -- name=%s mapdata=%s named=%s env=%s | coords lat=%s long=%s (~%s%s %s%s)",
			tostring(reason),
			tostring(map.name or (mapdata and mapdata.id) or "?"),
			tostring(mapdata and mapdata.id or "?"),
			named,
			tostring(mapdata and mapdata.Environment or "?"),
			tostring(lat), tostring(long), deg(lat), ns, deg(long), ew))
	end
end

RegisterOnce("PreNewMap", function(map, mapdata)
	if not active() then
		return
	end
	DiagSnapshotEvent("OnMsg.PreNewMap", map)
	local bounds = SuperBigMap.MapBounds
	if bounds then
		bounds.ResetMapDataBounds(map, mapdata)
	end
	local sectors = SuperBigMap.SectorExploration
	if sectors then
		sectors.EnsureSectorPatch(map or mapdata, "PreNewMap")
	end
end)

RegisterOnce("NewMap", function(map, mapdata)
	if not active() then
		return
	end
	DiagSnapshotEvent("OnMsg.NewMap", map)
	if HandleModEditorMap() then return end
	Lifecycle.Apply(map, true)
	local sectors = SuperBigMap.SectorExploration
	if sectors then
		sectors.EnsureSectorPatch(map or mapdata, "NewMap")
	end
end)

RegisterOnce("NewMapLoaded", function(map, mapdata)
	if not active() then
		return
	end
	DiagSnapshotEvent("OnMsg.NewMapLoaded", map)
	if HandleModEditorMap() then return end
	Lifecycle.Apply(map, false)
	-- Save-load path: the engine's NewMapLoaded restores MapSectors from save
	-- data; if that was built at a different sector size (e.g. saved at 10x10
	-- vanilla on a Big map), rebuild it here to match our current layout.
	local sectors = SuperBigMap.SectorExploration
	if sectors and type(sectors.EnsureSectorsBuilt) == "function" then
		sectors.EnsureSectorsBuilt(map, "NewMapLoaded")
	end
end)

RegisterOnce("PostNewMapLoaded", function(map, mapdata)
	if not active() then
		return
	end
	DiagSnapshotEvent("OnMsg.PostNewMapLoaded", map)
	if HandleModEditorMap() then return end
	LogChosenMap(map, "PostNewMapLoaded")
	Lifecycle.Apply(map, true)
	local sectors = SuperBigMap.SectorExploration
	if sectors and type(sectors.EnsureSectorsBuilt) == "function" then
		sectors.EnsureSectorsBuilt(map, "PostNewMapLoaded")
	end
	-- Expansion-completion work (grid sync, re-invalidate, frame copy/mirror, crater
	-- cleanup) runs ONLY on a real mod-expanded scenario. The "PreGame" mission-setup
	-- preview and any non-mod map are skipped entirely -- this is what stops the
	-- "not a 20x20 terrain" warning (and any frame work) from firing during setup,
	-- before a scenario is even chosen.
	if IsModMap(map) then
		-- Sync mapdata.Width/Height to the actual terrain grid size BEFORE the
		-- invalidate so the renderer's bounds extend to the full grid. The grids
		-- on expanded maps are 8192x8192 but mapdata often stays at the .fpk's
		-- native size (e.g. 6144), and the renderer appears to clamp drawing to
		-- mapdata bounds -- so the cloned quadrants never get textured.
		local gen = SuperBigMap.MapGeneration
		if gen and type(gen.SyncMapDataToGrids) == "function" then
			gen.SyncMapDataToGrids(map)
		end
		-- Fill the L-frame by mirroring the playable edge per the sector-mirror plan
		-- (left columns, top rows, and the corner; config-driven).
		if gen and type(gen.RunSectorMirrorPlanIfEnabled) == "function" then
			gen.RunSectorMirrorPlanIfEnabled(map)
		end
		-- Remove vanilla craters scattered in the non-rendered frame.
		local fake_terrain = SuperBigMap.FakeTerrain
		if fake_terrain and type(fake_terrain.RemoveFrameCraters) == "function" then
			fake_terrain.RemoveFrameCraters(map)
		end
	else
		InitSeq("PostNewMapLoaded: expansion-completion skipped (not a mod map)", {
			map = tostring(map and (map.name or (map.mapdata and map.mapdata.id)) or "?"),
		})
	end
	DiagSnapshotEvent("OnMsg.PostNewMapLoaded_AFTER_ensure", map)
end)

-- NOTE: A previous experiment hooked LandscapeCompleted to auto-repaint
-- "fake ground" objects inside the edited bbox. That hook ran unconditionally
-- whenever the mod was active and dropped stray sand-tinted objects at the
-- render boundary after any flatten/smooth/terrace edit. It has been removed
-- in favor of the explicit, button-driven fake-terrain system (see
-- sbm_fake_terrain.lua). Do not re-add an always-on landscape repaint hook.

-- Engine fires MapSectorsReady at the END of Exploration:InitExploration (after
-- InitSectors + InitMapArea + InitialExplore). If our patched InitSectors never
-- ran, the message still fires when vanilla InitSectors completes (with the
-- vanilla-built sector grid). Tapping it shows what state MapSectors is in at
-- that moment, which lets us tell whether the engine ever called any InitSectors
-- at all for the problematic map (e.g. BlankBig_03).
RegisterOnce("MapSectorsReady", function(exploration)
	if not active() then
		return
	end
	local sectors = SuperBigMap.SectorExploration
	if sectors and type(sectors.DiagOn) == "function" and sectors.DiagOn() then
		local map = exploration and type(exploration.GetMap) == "function" and exploration:GetMap() or false
		print("[Super Big Map] SectorDiag: OnMsg.MapSectorsReady: exploration=" .. tostring(exploration)
			.. " map=" .. tostring(map and map.name or "?")
			.. " | " .. sectors.DescribeCityState(exploration))
		-- Force-rebuild here too: if the engine's InitSectors built a 10x10
		-- vanilla grid for a map our layout expects to be bigger, this catches
		-- it after MapSectorsReady fires.
		if map and type(sectors.EnsureSectorsBuilt) == "function" then
			sectors.EnsureSectorsBuilt(map, "MapSectorsReady")
		end
	elseif sectors and type(sectors.EnsureSectorsBuilt) == "function" then
		local map = exploration and type(exploration.GetMap) == "function" and exploration:GetMap() or false
		if map then
			sectors.EnsureSectorsBuilt(map, "MapSectorsReady")
		end
	end
end)

-- CityInitialized fires from InitCity right after InitExploration. Tapping it
-- confirms whether InitCity ran for the map (when the engine's NewMapLoaded
-- handler conditions did not skip it).
RegisterOnce("CityInitialized", function(city)
	if not active() then
		return
	end
	local sectors = SuperBigMap.SectorExploration
	if sectors and type(sectors.DiagOn) == "function" and sectors.DiagOn() then
		local map = city and type(city.GetMap) == "function" and city:GetMap() or false
		print("[Super Big Map] SectorDiag: OnMsg.CityInitialized: city=" .. tostring(city)
			.. " map=" .. tostring(map and map.name or "?")
			.. " | " .. sectors.DescribeCityState(city))
	end
end)

-- Defensive guard against a vanilla crash exposed by upgrading the mod's
-- version mid-game.
--
-- The crash: vanilla RestoreInGameInterfaceOnLoadGame (InGameInterface.lua:754)
--   1. Reads InGameInterface_OverviewState (set by PersistLoad from save data).
--   2. SetMode("overview", { camera_transition_time = 0 }).
--   3. WaitMsg("CameraTransitionEnd")  -- thread yields here.
--   4. dlg.exit_to = InGameInterface_OverviewState.exit_to   -- crashes.
--
-- During the WaitMsg yield, if the save's mod version doesn't match the loaded
-- mod, the engine triggers a full Lua reload (Mod.lua dofile("autorun.lua")).
-- Re-running vanilla InGameInterface.lua hits its module-load initializer
-- `InGameInterface_OverviewState = false`, wiping the value PersistLoad just
-- restored. WaitMsg then returns and line 771 indexes `false`.
--
-- We can't stop the Lua reload (engine-internal). We CAN wrap the vanilla
-- function so it re-checks the global after the WaitMsg yield. If the global
-- was wiped to `false` mid-call, we skip the now-impossible restore step and
-- complete the rest of RestoreInGameInterfaceOnLoadGame cleanly.
local function InstallRestoreInGameInterfaceGuard()
	local State = SuperBigMap.State or {}
	SuperBigMap.State = State
	if State.original_restore_in_game_interface_on_load_game then
		return -- already wrapped
	end
	local original = rawget(_G, "RestoreInGameInterfaceOnLoadGame")
	if type(original) ~= "function" then
		return
	end
	State.original_restore_in_game_interface_on_load_game = original
	rawset(_G, "RestoreInGameInterfaceOnLoadGame", function(...)
		-- Capture the global BEFORE vanilla runs; if a reload mid-call wipes
		-- it, we still have the value to detect the wipe.
		local pre = rawget(_G, "InGameInterface_OverviewState")
		local ok, err = pcall(original, ...)
		if ok then
			return
		end
		-- Only swallow the specific known crash. Re-raise anything else.
		local err_str = tostring(err)
		if not err_str:find("InGameInterface_OverviewState") then
			error(err)
		end
		local DebugLog = SuperBigMap.DebugLog
		if DebugLog then
			DebugLog.Warn("Lifecycle",
				"vanilla RestoreInGameInterfaceOnLoadGame crashed (mod-reload mid-load wiped InGameInterface_OverviewState)",
				{ pre_was_table = type(pre) == "table", err = err_str })
		end
		print("[Super Big Map] vanilla RestoreInGameInterfaceOnLoadGame crash guarded: " .. err_str)
	end)
end

RegisterOnce("LoadGame", function()
	if not active() then
		return
	end
	InstallRestoreInGameInterfaceGuard()
	local current = Global("CurrentMap")
	DiagSnapshotEvent("OnMsg.LoadGame", current)
	-- Old save not started with the mod: warn once, then do nothing (the mod must
	-- not touch a vanilla save). Everything below is mod-map work, so bail out.
	if WarnOldSaveIfNeeded(current) then
		return
	end
	Lifecycle.Apply(current, true)
	-- Sync mapdata to the actual (expanded) terrain grids FIRST. On load, mapdata reverts to
	-- the preset's native tile count (e.g. 6144) while the saved terrain is the expanded size
	-- (e.g. 8192). The sector-count math derives from mapdata.Width, so if we rebuild sectors
	-- before this sync it computes the WRONG count (15x15 from 6144 instead of 20x20 from 8192)
	-- and the overview grid only covers part of the map. SyncMapDataToGrids sets mapdata.Width
	-- to match the real terrain, so it MUST run before EnsureSectorsBuilt.
	local gen = SuperBigMap.MapGeneration
	if gen and type(gen.SyncMapDataToGrids) == "function" and current then
		gen.SyncMapDataToGrids(current)
	end
	-- Save load preserves the city's MapSectors from save data; if its grid
	-- size doesn't match what our layout expects (e.g. saved at 10x10 vanilla,
	-- now expecting 20x20), rebuild here -- now that mapdata is synced to the real size.
	local sectors = SuperBigMap.SectorExploration
	if sectors and type(sectors.EnsureSectorsBuilt) == "function" and current then
		sectors.EnsureSectorsBuilt(current, "LoadGame")
	end
	-- Re-invalidate so the cloned quadrants get textures painted on. The save preserves the
	-- type/height grid data but the renderer may not stream textures into the expanded area
	-- until explicitly invalidated.
	if gen and type(gen.ReinvalidateExpandedTerrain) == "function" and current then
		gen.ReinvalidateExpandedTerrain(current)
	end
	-- Re-force the expanded frame passable on load (the forced-passability overlay is not
	-- necessarily saved, so reapply every load) -- keeps rovers from being trapped on the
	-- copied frame terrain.
	if gen and type(gen.ForceFramePassable) == "function" and current then
		gen.ForceFramePassable(current)
	end
	local fake_terrain = SuperBigMap.FakeTerrain
	if fake_terrain and type(fake_terrain.RemoveFrameCraters) == "function" and current then
		fake_terrain.RemoveFrameCraters(current)
	end
end)

RegisterOnce("CurrentMapChangeDone", function(map_slot, map)
	if not active() then
		return
	end
	DiagSnapshotEvent("OnMsg.CurrentMapChangeDone(slot=" .. tostring(map_slot) .. ")", map)
	if HandleModEditorMap() then return end
	LogChosenMap(map, "CurrentMapChangeDone")
	Lifecycle.Apply(map, true)
	local sectors = SuperBigMap.SectorExploration
	if sectors and type(sectors.EnsureSectorsBuilt) == "function" and map then
		sectors.EnsureSectorsBuilt(map, "CurrentMapChangeDone")
	end
end)

-- Authoritative, class-agnostic rocket-landing hook: the RocketLanded message fires for
-- every rocket regardless of subclass (the LandOnMars method wrap can miss subclasses if
-- the engine flattens methods). Delegates to RocketRules to snap a ground-landed rocket
-- onto the live (expanded) terrain and to log the landing diagnostics.
RegisterOnce("RocketLandAttempt", function(rocket)
	if not active() then
		return
	end
	local rockets = SuperBigMap.RocketRules
	if rockets and type(rockets.OnRocketLandAttempt) == "function" then
		SafeCall(rockets.OnRocketLandAttempt, rocket)
	end
end)

RegisterOnce("RocketLanded", function(rocket)
	if not active() then
		return
	end
	local rockets = SuperBigMap.RocketRules
	if rockets and type(rockets.OnRocketLanded) == "function" then
		SafeCall(rockets.OnRocketLanded, rocket)
	end
end)

-- The random-map generator hook must be installed whenever the mod is ENABLED, not only once
-- a mod map is active(): the pre-game landing-spot preview generates a random map
-- (PGMissionLandingSpotRemastered -> GenerateCurrentRandomMap) before any NewMap fires, so
-- active() (= State.active, set on per-map Apply) is still false at that point. Without the
-- hook, vanilla DoGenerate runs on the expanded-terrain-sized working grid and overflows the
-- engine limit -> assert "GridStableRandomPosSimple: size > 0 & size < GSRP_MAX_SIZE". The hook
-- is self-gating: its DoGenerate wrapper only caps OVERSIZED grids, so installing it while the
-- mod is merely enabled is transparent for normal vanilla-sized generation.
local function EnsureGeneratorHookInstalled()
	if (SuperBigMap.Config or {}).ENABLE_MOD == false then
		return
	end
	local gen = SuperBigMap.MapGeneration
	if gen and type(gen.PatchRandomMapGenerator) == "function" then
		gen.PatchRandomMapGenerator()
	end
end

local function EnsurePregameToggleInstalled()
	if (SuperBigMap.Config or {}).ENABLE_MOD == false then
		return
	end
	local toggle = SuperBigMap.PregameToggle
	if toggle and type(toggle.PatchLandingDialog) == "function" then
		toggle.PatchLandingDialog()
	end
end

RegisterOnce("ClassesPostprocess", function()
	-- Install the generator hook regardless of active() so it is ready before any pre-game
	-- landing-spot preview generates a map (prevents the GSRP overflow crash).
	EnsureGeneratorHookInstalled()
	EnsurePregameToggleInstalled()
	if not active() then
		return
	end
	-- Install the RestoreInGameInterfaceOnLoadGame guard at engine-init time so
	-- it's in place BEFORE any save load can begin. Our LoadGame hook also
	-- installs it as a safety net, but ClassesPostprocess fires very early --
	-- this catches save loads triggered from the main menu before OnMsg.LoadGame
	-- has fired.
	InstallRestoreInGameInterfaceGuard()
	ApplyOverviewPatches()
	local gen = SuperBigMap.MapGeneration
	if gen then
		gen.PatchRandomMapGenerator()
	end
	local sectors = SuperBigMap.SectorExploration
	if sectors then
		sectors.InstallSectorPatch()
	end
end)

RegisterOnce("DataLoaded", function()
	-- Ensure the generator hook is in place before any pre-game generation (independent of
	-- active()); DataLoaded fires at boot before the landing-spot screen.
	EnsureGeneratorHookInstalled()
	EnsurePregameToggleInstalled()
	if not active() then
		return
	end
	ApplyOverviewPatches()
	local gen = SuperBigMap.MapGeneration
	if gen then
		gen.PatchRandomMapGenerator()
	end
	local sectors = SuperBigMap.SectorExploration
	if sectors then
		sectors.InstallSectorPatch()
	end
end)

RegisterOnce("SectorScanned", function(status, sector, _old_status)
	if not active() then
		return
	end
	-- Reveal cloned subsurface deposits/anomalies now that their sector is scanned.
	local deposits = SuperBigMap.DepositRules
	if deposits and type(deposits.OnSectorScanned) == "function" then
		deposits.OnSectorScanned(status, sector)
	end
end)

RegisterOnce("ClassesBuilt", function()
	-- ClassesBuilt rebuilds RandomMapGenerator to vanilla. Re-install our hook even before a
	-- mod map is active, so a pre-game landing-spot preview can't run vanilla DoGenerate.
	EnsureGeneratorHookInstalled()
	EnsurePregameToggleInstalled()
	if not active() then
		return
	end
	-- ClassesBuilt rebuilds RandomMapGenerator to vanilla; re-install our hook
	-- (the patch self-verifies and re-applies if its wrapper was reset).
	local gen = SuperBigMap.MapGeneration
	if gen then
		gen.PatchRandomMapGenerator()
	end
	local sectors = SuperBigMap.SectorExploration
	if sectors then
		sectors.InstallSectorPatch()
	end
end)

RegisterOnce("ModsReloaded", function()
	NoticeLog("ModsReloaded handler fired", { active = active() })
	-- The restart notice must fire regardless of the active() gate below (it has its own
	-- gating), so try it first.
	if type(SuperBigMap.ShowFreshRestartNotice) == "function" then
		SuperBigMap.ShowFreshRestartNotice()
	end
	-- Re-install the generator hook on reload regardless of active() (a mod reload resets the
	-- RandomMapGenerator class to vanilla; the pre-game preview can run before any map is active).
	EnsureGeneratorHookInstalled()
	EnsurePregameToggleInstalled()
	if not active() then
		return
	end
	local gen = SuperBigMap.MapGeneration
	if gen then
		gen.PatchRandomMapGenerator()
	end
	local sectors = SuperBigMap.SectorExploration
	if sectors then
		sectors.InstallSectorPatch()
		-- A hot-reload (e.g. the mod files changed on disk mid-session) re-executes the
		-- modules but fires NO map event, so the live overview grid can be left collapsed
		-- to a vanilla 10x10. Rebuild OUR grid for the current map and recreate the
		-- per-sector decals so a reload is seamless instead of wiping the expanded grid.
		local map = Global("CurrentMap")
		if map then
			-- Restore const.SectorCount (a module re-exec can leave it at the vanilla 10,
			-- which renders a 10x10 overview even when our 20x20 MapSectors data survived).
			local grid = SuperBigMap.SectorGrid
			if grid and type(grid.ConfigureGlobalSectorCount) == "function" then
				SafeCall(grid.ConfigureGlobalSectorCount, map, "ModsReloaded")
			end
			if type(sectors.EnsureSectorsBuilt) == "function" then
				sectors.EnsureSectorsBuilt(map, "ModsReloaded")
			end
			if type(sectors.RefreshSectorDecals) == "function" then
				sectors.RefreshSectorDecals(map.City)
			end
		end
	end
	-- Re-apply bounds + overview framing for the current map too.
	if Lifecycle.IsActive() then
		Lifecycle.Apply(Global("CurrentMap"), true)
	end
	-- (restart notice is fired at the TOP of this handler, before the active() gate)
end)

RegisterOnce("ChangingMap", function(map_slot, map_name, map_instance)
	-- Re-verify the generator hook is installed before this map's generation, even when the
	-- mod isn't active() yet (landing-spot previews regenerate without ClassesBuilt and before
	-- any map is applied). This is the path that was overflowing GSRP into a crash.
	EnsureGeneratorHookInstalled()
	EnsurePregameToggleInstalled()
	if not active() then
		return
	end
	local gen = SuperBigMap.MapGeneration
	if gen then
		gen.PrepareMapDataForQuadrantCopy(map_slot, map_name, map_instance, "ChangingMap")
	end
	local sectors = SuperBigMap.SectorExploration
	if sectors then
		sectors.EnsureSectorPatch(map_instance, "ChangingMap")
	end
end)

RegisterOnce("NewMapObject", function(map)
	if not active() then
		return
	end
	local gen = SuperBigMap.MapGeneration
	if gen then
		gen.AttachPendingMapState(map)
	end
end)

RegisterOnce("MapGenerated", function(map)
	if not active() then
		return
	end
	DiagSnapshotEvent("OnMsg.MapGenerated_BEFORE_tile", map)
	local gen = SuperBigMap.MapGeneration
	if gen then
		gen.FinalizeExpandedMap(map)
	end
	local sectors = SuperBigMap.SectorExploration
	if sectors then
		sectors.EnsureSectorPatch(map, "MapGenerated")
		DiagSnapshotEvent("OnMsg.MapGenerated_AFTER_ensure_patch", map)
		if type(sectors.EnsureSectorsBuilt) == "function" then
			sectors.EnsureSectorsBuilt(map, "MapGenerated")
		end
		DiagSnapshotEvent("OnMsg.MapGenerated_AFTER_ensure_built", map)
	end
	-- Final terrain re-invalidate AFTER quadrant copy + sector rebuild.
	-- PostNewMapLoaded fires BEFORE MapGenerated, so the earlier invalidate ran
	-- when the type grid was still uniform 17 from initial map allocation.
	-- This second pass runs after the quadrant copy has populated the cloned
	-- areas with real texture indices, giving the renderer the chance to pick
	-- them up.
	if gen then
		if type(gen.SyncMapDataToGrids) == "function" then
			gen.SyncMapDataToGrids(map)
		end
		if type(gen.ReinvalidateExpandedTerrain) == "function" then
			gen.ReinvalidateExpandedTerrain(map)
		end
	end
	local fake_terrain = SuperBigMap.FakeTerrain
	if fake_terrain and type(fake_terrain.RemoveFrameCraters) == "function" then
		fake_terrain.RemoveFrameCraters(map)
	end
end)

RegisterOnce("OverviewMode", function(enabled)
	if editor_active() then
		EditorCamLog("OverviewMode handler skipped (editor)", { enabled = enabled == true })
		return
	end
	if not active() then
		return
	end
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Overview", "OverviewMode message", { enabled = enabled == true })
	end
	local camera = SuperBigMap.OverviewCamera
	if enabled then
		-- Re-apply the ZoomPlus far zoom-out limit BEFORE reframing. The overview
		-- camera pulls farther back than the vanilla zoom-out clamp allows, so without
		-- this the camera (correctly computed) gets clamped too close on the first
		-- entry -- which is why a manual zoom, routed through CameraTransitionEnd
		-- (ApplyNormalZoom + reframe), is what "fixes" it.
		local zoom = SuperBigMap.ZoomPlusIntegration
		if zoom then
			zoom.ApplyNormalZoom()
		end
		if camera then
			camera.RefreshOverviewCamera()
			camera.ScheduleOverviewCameraRefresh()
		end
	else
		if camera then
			camera.CancelScheduledRefresh()
		end
		local render = SuperBigMap.OverviewRender
		if render then
			render.Apply(false)
		end
		local sectors = SuperBigMap.SectorExploration
		if sectors and type(sectors.HideSectorVisuals) == "function" then
			sectors.HideSectorVisuals(Global("UICity"), "OverviewMode(false)")
		end
	end
end)

-- DIAGNOSTIC: sample the live camera through each transition so the curve in the
-- overview<->sector zoom is visible (lookat panning vs eye descending). Gated by
-- ShowOverviewCameraDiagnostics; logs the requested target then ~every 40ms until
-- the camera stops moving.
RegisterOnce("CameraTransitionStart", function(eye, lookat, time)
	if editor_active() then
		EditorCamLog("CameraTransitionStart skipped (editor)", CameraSnapshot())
		return
	end
	if not active() then
		return
	end
	-- Take over only the first/startup overview->sector exit descent with a straight
	-- mod-driven path. Later overview exits are left on the vanilla transition path.
	local overview = SuperBigMap.OverviewCamera
	if overview and type(overview.TakeOverExitTransition) == "function" then
		overview.TakeOverExitTransition(eye, lookat, time)
	end
	local cfg = SuperBigMap.Config or {}
	if cfg.DEBUG_CAMERA ~= true then
		return
	end
	local DebugLog = SuperBigMap.DebugLog
	local camera = Global("cameraRTS")
	local get_mode = Global("GetInGameInterfaceMode")
	local function xyz(p)
		if not p then
			return nil, nil, nil
		end
		return SafeCall(p.x, p), SafeCall(p.y, p), SafeCall(p.z, p)
	end
	if DebugLog then
		local ex, ey, ez = xyz(eye)
		local lx, ly, lz = xyz(lookat)
		DebugLog.Info("Camera", "CameraTransitionStart target", {
			mode = get_mode and SafeCall(get_mode) or "?", time = time,
			eye_x = ex, eye_y = ey, eye_z = ez, lookat_x = lx, lookat_y = ly, lookat_z = lz,
		})
	end
	local create_thread = Global("CreateRealTimeThread")
	local sleep = Global("Sleep")
	if type(create_thread) ~= "function" or type(sleep) ~= "function" or not camera or type(camera.GetEye) ~= "function" then
		return
	end
	create_thread(function()
		for i = 1, 50 do
			local e = SafeCall(camera.GetEye)
			local l = SafeCall(camera.GetLookAt)
			local moving = type(camera.IsMoving) == "function" and SafeCall(camera.IsMoving) and true or false
			if DebugLog and e and l then
				local ex, ey, ez = xyz(e)
				local lx, ly, lz = xyz(l)
				DebugLog.Info("Camera", "transition sample", {
					i = i, moving = moving,
					eye_x = ex, eye_y = ey, eye_z = ez, lookat_x = lx, lookat_y = ly, lookat_z = lz,
				})
			end
			if not moving and i > 2 then
				return
			end
			sleep(40)
		end
	end)
end)

RegisterOnce("CameraTransitionEnd", function()
	if editor_active() then
		EditorCamLog("CameraTransitionEnd skipped (editor)", CameraSnapshot())
		return
	end
	if not active() then
		return
	end
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Overview", "CameraTransitionEnd message")
	end
	local zoom = SuperBigMap.ZoomPlusIntegration
	if zoom then
		zoom.ApplyNormalZoom()
	end
	local camera = SuperBigMap.OverviewCamera
	if camera then
		camera.RefreshOverviewCamera()
	end
	local is_overview = Global("IsOverviewMode")
	local overview_active = type(is_overview) == "function" and SafeCall(is_overview) == true
	if overview_active ~= true then
		local sectors = SuperBigMap.SectorExploration
		if sectors and type(sectors.HideSectorVisuals) == "function" then
			sectors.HideSectorVisuals(Global("UICity"), "CameraTransitionEnd:not_overview")
		end
	end
end)

-- The map/mod editor is NOT a new game, so the mod must do nothing there: restore
-- the vanilla camera/overview/zoom (the editor uses stock camera behaviour) and warn
-- once that a new game is required. IsModMap() also returns false while the editor is
-- open, so every per-map gate stays vanilla.
RegisterOnce("GameEnterEditor", function()
	if not active() then
		return
	end
	EditorCamLog("GameEnterEditor fired -- BEFORE restore", CameraSnapshot())
	local cam = SuperBigMap.OverviewCamera
	if cam and type(cam.RestoreVanillaBehavior) == "function" then cam.RestoreVanillaBehavior() end
	local render = SuperBigMap.OverviewRender
	if render and type(render.Apply) == "function" then render.Apply(false) end
	local curtains = SuperBigMap.OverviewCurtains
	if curtains and type(curtains.RestoreVanillaBehavior) == "function" then curtains.RestoreVanillaBehavior() end
	local zoom = SuperBigMap.ZoomPlusIntegration
	if zoom and type(zoom.RestoreVanillaBehavior) == "function" then zoom.RestoreVanillaBehavior() end

	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Lifecycle", "GameEnterEditor: mod set inert (vanilla editor camera)")
	end

	local cfg = SuperBigMap.Config or {}
	if cfg.WARN_OLD_SAVE_NEEDS_NEW_GAME == true and SuperBigMap.State.editor_warned ~= true then
		SuperBigMap.State.editor_warned = true
		local create_box = Global("CreateMessageBox")
		if type(create_box) == "function" then
			pcall(create_box, nil, "Super Big Map",
				"Super Big Map does not operate in the map editor.\n\n" ..
				"The editor runs in vanilla mode; the expanded map and the mod's camera " ..
				"only apply to a NEW GAME started with the mod enabled.")
		end
	end

	EditorCamLog("GameEnterEditor -- AFTER restore", CameraSnapshot())
	-- Sample the camera for a few seconds after entering: if something RE-APPLIES a
	-- zoom/FOV after our restore, these lines will show WHEN and to WHAT, and whether
	-- ZoomPlus re-enabled itself -- the data needed to find the real culprit.
	if EditorCamOn() then
		local create_thread = Global("CreateRealTimeThread")
		local sleep = Global("Sleep")
		if type(create_thread) == "function" and type(sleep) == "function" then
			create_thread(function()
				for _, delay in ipairs({ 200, 500, 1000, 2000, 4000 }) do
					sleep(delay)
					if not editor_active() then
						EditorCamLog("sample -- editor closed, stopping", {})
						return
					end
					EditorCamLog("sample @+" .. tostring(delay) .. "ms", CameraSnapshot())
				end
			end)
		end
	end
end)

-- Leaving the editor: reinstall the mod's patches and re-apply to the current map
-- (Apply is a no-op on non-mod maps) so normal play resumes as before.
RegisterOnce("GameExitEditor", function()
	if not active() then
		return
	end
	EditorCamLog("GameExitEditor fired", CameraSnapshot())
	ApplyOverviewPatches()
	local zoom = SuperBigMap.ZoomPlusIntegration
	if zoom and type(zoom.ApplyModBehavior) == "function" then zoom.ApplyModBehavior() end
	local map = Global("CurrentMap")
	Lifecycle.Apply(map, true)
	local sectors = SuperBigMap.SectorExploration
	if sectors and type(sectors.EnsureSectorsBuilt) == "function" and map then
		sectors.EnsureSectorsBuilt(map, "GameExitEditor")
	end
end)

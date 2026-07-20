-- Super Big Map -- reversible lifecycle + the single OnMsg site.
--
-- Owns the master Enable/Disable (idempotent) and the per-map Apply. Enable installs
-- every domain's behavior (ApplyModBehavior) and applies it to the current map;
-- Disable restores vanilla (RestoreVanillaBehavior) in reverse order. ALL OnMsg
-- handlers live here, registered once and gated on IsActive(), each delegating to the
-- domain modules in the order the originals ran (e.g. expand terrain before building
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
local MAIN_MENU_GUARD_VERSION = 6
local InstallRestoreInGameInterfaceGuard
local UninstallRestoreInGameInterfaceGuard

local function LoadingLifecycle(event, map, data)
	local diagnostics = SuperBigMap.Diagnostics
	if not (diagnostics and type(diagnostics.LoadingStep) == "function") then return end
	local map_type = type(map)
	local expansion_related = (map_type == "table" or map_type == "userdata")
		and (map.SuperBigMapExpansionPending == true
		or map.SuperBigMapExpanded == true or map.SuperBigMapDesiredWidthTiles ~= nil
		or map.SuperBigMapVanillaSourceMigration == true)
	if not expansion_related and SuperBigMap.State.vanilla_source_migration_active ~= true then return end
	if event == "ChangingMap after expansion allocation plan"
		and type(diagnostics.LoadingStart) == "function" then
		diagnostics.LoadingStart("expanded map allocation", map, data)
		return
	end
	if type(diagnostics.LoadingActive) == "function" and diagnostics.LoadingActive() ~= true then return end
	diagnostics.LoadingStep("lifecycle: " .. tostring(event), data, map)
end

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
	State.msg_handlers = State.msg_handlers or {}
	-- Always replace the delegated body, even when the engine-facing wrapper was already
	-- registered by an earlier module execution. Hot reloads then adopt orchestration changes
	-- without stacking ChainOnMsg wrappers.
	State.msg_handlers[message_name] = handler
	if State.registered_msgs[message_name] then
		return
	end
	State.registered_msgs[message_name] = true
	Engine.ChainOnMsg(message_name, function(...)
		local live_handler = (SuperBigMap.State.msg_handlers or {})[message_name]
		if type(live_handler) ~= "function" then return end
		return live_handler(...)
	end)
end

-- Map liveness / terrain size are intentionally NOT in sbm_engine (their resolution
-- order is context-specific); kept local for map resolution and application.
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

-- TEMP test aid. hr.EnableDarknessReveal is process-global, so it must be derived from the map
-- environment on every transition. Capturing its live value after CurrentMapChangeDone is unsafe:
-- vanilla has already set it to the underground value (90), and restoring that snapshot on the
-- surface covers the entire terrain with the blue underground darkness mask.
local function ApplyUndergroundDarknessState(map)
	local hr = Global("hr")
	if type(hr) ~= "table" then return false end
	local State = SuperBigMap.State
	local environment = map and map.mapdata and map.mapdata.Environment
	local should_reveal = environment == "Underground"
		and (SuperBigMap.Config or {}).UNDERGROUND_REVEAL_ALL_DARKNESS == true
	local before = hr.EnableDarknessReveal
	-- Clear legacy snapshot state left by earlier versions. The correct non-test value is owned by
	-- vanilla UpdateRevealDarkness(map), not by whichever process-global value happened to be live.
	State.original_enable_darkness_reveal = nil
	State.original_enable_darkness_reveal_captured = nil
	if should_reveal then
		hr.EnableDarknessReveal = 0
	else
		local update_reveal = Global("UpdateRevealDarkness")
		if map and type(update_reveal) == "function" then
			SafeCall(update_reveal, map)
		else
			-- No gameplay map means no underground darkness reveal.
			hr.EnableDarknessReveal = 0
		end
	end
	LoadingLifecycle("UndergroundDarknessState", map, {
		environment = tostring(environment), before = tostring(before),
		after = tostring(hr.EnableDarknessReveal), forced_reveal = tostring(should_reveal),
	})
	return should_reveal
end

-- Correct shared state for a non-expanded map without uninstalling the transparent
-- wrappers required by a later opt-in expanded game.
local function NormalizeVanillaRuntimeState(map, reason)
	if map and IsModMap(map) then return false end
	local grid = SuperBigMap.SectorGrid
	if grid and type(grid.NormalizeVanillaSectorCount) == "function" then
		SafeCall(grid.NormalizeVanillaSectorCount, reason or "vanilla runtime")
	end
	local render = SuperBigMap.OverviewRender
	if render and type(render.Apply) == "function" then render.Apply(false) end
	local camera = SuperBigMap.OverviewCamera
	if not map and camera and type(camera.RestoreVanillaBehavior) == "function" then
		camera.RestoreVanillaBehavior()
	elseif camera and type(camera.RestoreOverviewFovVanilla) == "function" then
		camera.RestoreOverviewFovVanilla()
	end
	local zoom = SuperBigMap.ZoomPlusIntegration
	if zoom and type(zoom.RestoreVanillaBehavior) == "function" then
		zoom.RestoreVanillaBehavior()
	end
	local zoom_option = SuperBigMap.ZoomOption
	if zoom_option and type(zoom_option.RestoreVanillaBehavior) == "function" then
		zoom_option.RestoreVanillaBehavior()
	end
	local elevator_button = SuperBigMap.PlaceElevatorButton
	if (SuperBigMap.Config or {}).PLACE_ELEVATOR_BUTTON_ENABLED == true
		and elevator_button and type(elevator_button.Show) == "function" then
		SafeCall(elevator_button.Show)
	elseif elevator_button and type(elevator_button.Hide) == "function" then
		SafeCall(elevator_button.Hide)
	end
	ApplyUndergroundDarknessState(map)
	if type(UninstallRestoreInGameInterfaceGuard) == "function" then
		UninstallRestoreInGameInterfaceGuard()
	end
	return true
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

local function ForceVanillaMainMenuState(reason)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.LoadingFinish) == "function"
		and type(diagnostics.LoadingActive) == "function"
		and diagnostics.LoadingActive() == true then
		diagnostics.LoadingFinish("main-menu transition", Global("CurrentMap"), {
			reason = tostring(reason or "vanilla_reset"),
		}, false)
	end
	local toggle = SuperBigMap.PregameToggle
	if toggle and type(toggle.ResetForVanillaSession) == "function" then
		SafeCall(toggle.ResetForVanillaSession, tostring(reason or "vanilla_reset"))
	end
	local zoom = SuperBigMap.ZoomPlusIntegration
	if zoom and type(zoom.RestoreVanillaBehavior) == "function" then
		zoom.RestoreVanillaBehavior()
	end
	local camera = SuperBigMap.OverviewCamera
	if camera and type(camera.RestoreVanillaBehavior) == "function" then
		camera.RestoreVanillaBehavior()
	end
	local render = SuperBigMap.OverviewRender
	if render and type(render.RestoreVanillaBehavior) == "function" then
		render.RestoreVanillaBehavior()
	elseif render and type(render.Apply) == "function" then
		render.Apply(false)
	end
	local curtains = SuperBigMap.OverviewCurtains
	if curtains and type(curtains.RestoreVanillaBehavior) == "function" then
		curtains.RestoreVanillaBehavior()
	end
	if type(SuperBigMap.ExpansionLoadingEnd) == "function" then
		SafeCall(SuperBigMap.ExpansionLoadingEnd, true)
	end
	NormalizeVanillaRuntimeState(nil, tostring(reason or "main menu") .. " pre-disable")
	local generation = SuperBigMap.MapGeneration
	if generation and type(generation.RestorePreparedMapDataForVanillaSession) == "function" then
		SafeCall(generation.RestorePreparedMapDataForVanillaSession, reason or "main menu")
	end

	-- Returning to the main menu reverses every gameplay patch. The pregame EXPAND MAP control is
	-- intentionally retained: it is inert outside the colony-site dialog and must already be
	-- installed when the next scenario constructs that dialog.
	SuperBigMap.State.main_menu_vanilla = true
	local lifecycle = SuperBigMap.Lifecycle
	if lifecycle and type(lifecycle.Disable) == "function" then
		SafeCall(lifecycle.Disable, true)
	end
	if type(UninstallRestoreInGameInterfaceGuard) == "function" then
		UninstallRestoreInGameInterfaceGuard()
	end

end

-- The Relaunched game returns to pregame through ResetGameSession.  Guarding only
-- OpenPreGameMainMenu is insufficient because that global can be replaced after the
-- mod loads; ResetGameSession is the lower, authoritative session-destruction boundary.
local function InstallResetGameSessionGuard()
	local State = SuperBigMap.State
	if State.reset_game_session_wrapper
		and rawget(_G, "ResetGameSession") == State.reset_game_session_wrapper
		and State.reset_game_session_version == MAIN_MENU_GUARD_VERSION then
		return true
	end
	local original = rawget(_G, "ResetGameSession")
	if original == State.reset_game_session_wrapper then
		original = State.original_reset_game_session
	end
	if type(original) ~= "function" then return false end
	State.original_reset_game_session = original
	local wrapper = function(...)
		local lifecycle = SuperBigMap.Lifecycle
		if lifecycle and type(lifecycle.ReturnToMainMenuVanilla) == "function" then
			lifecycle.ReturnToMainMenuVanilla("ResetGameSession")
		else
			ForceVanillaMainMenuState("ResetGameSession")
		end
		return State.original_reset_game_session(...)
	end
	State.reset_game_session_wrapper = wrapper
	State.reset_game_session_version = MAIN_MENU_GUARD_VERSION
	rawset(_G, "ResetGameSession", wrapper)
	return true
end

local function InstallPreGameMainMenuResetGuard()
	local State = SuperBigMap.State
	if State.open_pregame_main_menu_reset_wrapper
		and rawget(_G, "OpenPreGameMainMenu") == State.open_pregame_main_menu_reset_wrapper
		and State.open_pregame_main_menu_reset_version == MAIN_MENU_GUARD_VERSION then
		return true
	end
	local original = rawget(_G, "OpenPreGameMainMenu")
	if original == State.open_pregame_main_menu_reset_wrapper then
		original = State.original_open_pregame_main_menu
	end
	if type(original) ~= "function" then
		return false
	end
	State.original_open_pregame_main_menu = original
	local wrapper = function(...)
		local lifecycle = SuperBigMap.Lifecycle
		if lifecycle and type(lifecycle.ReturnToMainMenuVanilla) == "function" then
			lifecycle.ReturnToMainMenuVanilla("OpenPreGameMainMenu")
		else
			ForceVanillaMainMenuState("OpenPreGameMainMenu")
		end
		return State.original_open_pregame_main_menu(...)
	end
	State.open_pregame_main_menu_reset_wrapper = wrapper
	State.open_pregame_main_menu_reset_version = MAIN_MENU_GUARD_VERSION
	rawset(_G, "OpenPreGameMainMenu", wrapper)
	return true
end

-- Full teardown on the main menu must not prevent the next game from using the mod. These
-- lifecycle-owned wrappers stay installed while every gameplay patch is removed, then restore
-- the complete apply phase immediately before vanilla starts or loads a game.
local function ReactivateFromMainMenu(reason)
	local State = SuperBigMap.State
	if State.main_menu_vanilla ~= true then return false end
	local lifecycle = SuperBigMap.Lifecycle
	if not (lifecycle and type(lifecycle.Enable) == "function") then return false end
	if SafeCall(lifecycle.Enable, true) ~= true then return false end
	State.main_menu_vanilla = false
	return true
end

local function InstallGameEntryGuard(global_name)
	local State = SuperBigMap.State
	local lower = string.lower(global_name)
	local wrapper_key = "main_menu_" .. lower .. "_wrapper"
	local original_key = "original_main_menu_" .. lower
	local version_key = "main_menu_" .. lower .. "_version"
	local current = rawget(_G, global_name)
	if State[wrapper_key] and current == State[wrapper_key]
		and State[version_key] == MAIN_MENU_GUARD_VERSION then
		return true
	end
	if current == State[wrapper_key] then current = State[original_key] end
	if type(current) ~= "function" then return false end
	State[original_key] = current
	local wrapper = function(...)
		ReactivateFromMainMenu(global_name)
		return State[original_key](...)
	end
	State[wrapper_key] = wrapper
	State[version_key] = MAIN_MENU_GUARD_VERSION
	rawset(_G, global_name, wrapper)
	return true
end

local function InstallMainMenuTransitionGuards()
	InstallPreGameMainMenuResetGuard()
	InstallResetGameSessionGuard()
	InstallGameEntryGuard("NewGame")
	InstallGameEntryGuard("LoadGame")
	InstallGameEntryGuard("LoadGameFromMem")
	InstallGameEntryGuard("GenerateRandomMap")
	InstallGameEntryGuard("GenerateCurrentRandomMap")
end

local Lifecycle = {}

function Lifecycle.IsActive()
	return SuperBigMap.State.active == true
end

-- Per-map application: bring the loaded map's bounds/sectors/overview into the
-- mod's configured state. Safe to call repeatedly (each step is idempotent).
function Lifecycle.Apply(map, rebuild, skip_buildable_rebuild)
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
		NormalizeVanillaRuntimeState(map, "Lifecycle.Apply non-mod map")
		return false, "not a mod map"
	end

	local bounds = SuperBigMap.MapBounds
	if bounds then
		bounds.ResetMapDataBounds(map, map.mapdata)
		bounds.ResetMapAreas(map)

		if rebuild and bounds.FullMapPlayableEnabled() then
			bounds.RebuildMapBounds(map, skip_buildable_rebuild)
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
	local elevator_button = SuperBigMap.PlaceElevatorButton
	if elevator_button and type(elevator_button.Show) == "function" then
		SafeCall(elevator_button.Show)
	end
	ApplyUndergroundDarknessState(map)
	if map.mapdata and map.mapdata.Environment == "Underground"
		and map.SuperBigMapUndergroundStretchDone == true
		and (SuperBigMap.Config or {}).UNDERGROUND_REVEAL_ALL_ENRICHMENTS_FOR_TESTING == true then
		local deposits = SuperBigMap.DepositRules
		if deposits and type(deposits.RevealAllUndergroundEnrichmentsForTesting) == "function" then
			SafeCall(deposits.RevealAllUndergroundEnrichmentsForTesting, map)
		end
	end
	return true
end

local function StretchEligibleForDeferredBounds(map)
	local config = SuperBigMap.Config or {}
	local env = map and map.mapdata and map.mapdata.Environment
	local desired = map and map.SuperBigMapDesiredWidthTiles
	local generator = map and map.SuperBigMapGeneratorWidthTiles
	return IsModMap(map)
		and type(desired) == "number" and type(generator) == "number" and desired > generator
		and (env ~= "Underground" or config.STRETCH_UNDERGROUND == true)
end

local function ShouldSkipNewMapBuildableRebuild(map)
	local config = SuperBigMap.Config or {}
	local env = map and map.mapdata and map.mapdata.Environment
	local buildable = map and map.buildable
	return config.OPTIMIZE_POSTLOAD_DEFERRED_BOUNDS == true
		and config.OPTIMIZE_STRETCH_DEFERRED_REBUILDS == true
		and config.SURFACE_STRETCH_AT_START == true
		and config.FULL_MAP_PLAYABLE == true
		and env == "Surface"
		and buildable and buildable.z_grid
		and StretchEligibleForDeferredBounds(map)
end

-- Install order (dependencies first); restore is the exact reverse.
local APPLY_ORDER = {
	"PregameToggle",
	"LoadingUI",
	"MapGeneration",
	"DepositRules",
	"SectorGrid",
	"SectorExploration",
	"SectorHighlight",
	"OverviewCamera",
	"OverviewCurtains",
	"OverviewRender",
	"ZoomOption",
	"ZoomPlusIntegration",
	"MapBounds",
	"RocketRules",
	"HeatSafety",
}

local RESTORE_ORDER = {
	"HeatSafety",
	"RocketRules",
	"MapBounds",
	"ZoomPlusIntegration",
	"ZoomOption",
	"OverviewRender",
	"OverviewCurtains",
	"OverviewCamera",
	"SectorHighlight",
	"SectorExploration",
	"SectorGrid",
	"DepositRules",
	"MapGeneration",
	"LoadingUI",
	"PregameToggle",
}

local function run_phase(order, method, skip_module)
	for i = 1, #order do
		local module_name = order[i]
		if module_name ~= skip_module then
			local mod = SuperBigMap[module_name]
			if type(mod) == "table" and type(mod[method]) == "function" then
				SafeCall(mod[method])
			end
		end
	end
end

function Lifecycle.Enable(force_from_main_menu)
	local cfg = SuperBigMap.Config or {}
	if cfg.ENABLE_MOD == false then
		return false
	end
	if SuperBigMap.State.main_menu_vanilla == true and force_from_main_menu ~= true then
		return false
	end

	if Lifecycle.IsActive() then
		return true
	end

	run_phase(APPLY_ORDER, "ApplyModBehavior")
	SuperBigMap.State.active = true
	if type(InstallRestoreInGameInterfaceGuard) == "function" then
		InstallRestoreInGameInterfaceGuard()
	end
	Lifecycle.Apply(Global("CurrentMap"), true)
	-- The "fresh restart needed" notice is fired from the ModsReloaded handler (so it can
	-- tell a runtime toggle from the cold boot via GameUiIsUp), not here.
	return true
end

function Lifecycle.Disable(keep_pregame_toggle)
	-- Always execute the idempotent reverse phase. A late Lua/class reload can
	-- leave a wrapper or shared preset behind even if State.active was already
	-- cleared, and main-menu teardown is the last safe point to normalize it.
	run_phase(RESTORE_ORDER, "RestoreVanillaBehavior",
		keep_pregame_toggle == true and "PregameToggle" or nil)
	local elevator_button = SuperBigMap.PlaceElevatorButton
	if elevator_button and type(elevator_button.Hide) == "function" then
		SafeCall(elevator_button.Hide)
	end
	ApplyUndergroundDarknessState(nil)
	SuperBigMap.State.active = false
	if type(UninstallRestoreInGameInterfaceGuard) == "function" then
		UninstallRestoreInGameInterfaceGuard()
	end
	return true
end

Lifecycle.ReturnToMainMenuVanilla = ForceVanillaMainMenuState
Lifecycle.ReactivateFromMainMenu = ReactivateFromMainMenu

SuperBigMap.Lifecycle = Lifecycle
InstallMainMenuTransitionGuards()

-- ============================================================================
-- The single OnMsg site. Every handler is gated on IsActive() and delegates to
-- the domain modules in the original dispatch order.
-- ============================================================================
local function active()
	return Lifecycle.IsActive()
end

-- True on the MOD EDITOR test map -- the authoritative "leave everything vanilla"
-- signal. IsModEditorMap (engine, GedModEditor.lua) is always available; the world
-- editor's IsEditorActive is kept only as a secondary check.
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

-- When on the mod editor map, force Super Big Map fully vanilla: disable ZoomPlus,
-- restore the overview camera/render (no popup -- the mod is silently inert in the editor).
-- Called from the map-load events (GameEnterEditor does not fire for the mod editor).
-- Returns true when the mod editor was detected/handled.
local function HandleModEditorMap()
	if not editor_active() then
		return false
	end
	local zoom = SuperBigMap.ZoomPlusIntegration
	if zoom and type(zoom.RestoreVanillaBehavior) == "function" then zoom.RestoreVanillaBehavior() end
	local cam = SuperBigMap.OverviewCamera
	if cam and type(cam.RestoreVanillaBehavior) == "function" then cam.RestoreVanillaBehavior() end
	local render = SuperBigMap.OverviewRender
	if render and type(render.Apply) == "function" then render.Apply(false) end

	return true
end

RegisterOnce("PreNewMap", function(map, mapdata)
	if not active() then
		return
	end
	if map and map.SuperBigMapVanillaSourceMigration == true then
		return
	end
	LoadingLifecycle("PreNewMap", map, { mapdata = tostring(mapdata) })
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
	if map and map.SuperBigMapVanillaSourceMigration == true then
		return
	end
	LoadingLifecycle("NewMap", map, { mapdata = tostring(mapdata) })
	if HandleModEditorMap() then return end
	local skip_buildable_rebuild = ShouldSkipNewMapBuildableRebuild(map) == true
	Lifecycle.Apply(map, true, skip_buildable_rebuild)
	local sectors = SuperBigMap.SectorExploration
	if sectors then
		sectors.EnsureSectorPatch(map or mapdata, "NewMap")
	end
end)

RegisterOnce("NewMapLoaded", function(map, mapdata)
	if not active() then
		return
	end
	if map and map.SuperBigMapVanillaSourceMigration == true then
		return
	end
	LoadingLifecycle("NewMapLoaded", map, { mapdata = tostring(mapdata) })
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
	if map and map.SuperBigMapVanillaSourceMigration == true then
		return
	end
	if HandleModEditorMap() then return end
	LoadingLifecycle("PostNewMapLoaded", map, { mapdata = tostring(mapdata) })
	local gen = SuperBigMap.MapGeneration
	local env = map and map.mapdata and map.mapdata.Environment
	if IsModMap(map) and gen and type(gen.PatchDeferredUndergroundAccess) == "function" then
		gen.PatchDeferredUndergroundAccess("PostNewMapLoaded:" .. tostring(env or "?"))
	end
	local config = SuperBigMap.Config or {}
	local stretch_eligible = StretchEligibleForDeferredBounds(map)
	local defer_postload_bounds = config.OPTIMIZE_POSTLOAD_DEFERRED_BOUNDS == true
		and stretch_eligible
	Lifecycle.Apply(map, not defer_postload_bounds)
	local sectors = SuperBigMap.SectorExploration
	if sectors and type(sectors.EnsureSectorsBuilt) == "function" then
		sectors.EnsureSectorsBuilt(map, "PostNewMapLoaded")
	end
	if env == "Underground" and not IsModMap(map) then
		NormalizeVanillaRuntimeState(map, "PostNewMapLoaded vanilla underground")
		return
	end
	-- Underground maps take their own stretch path, never the surface pipeline.
	if env == "Underground" then
		local scheduled = false
		if gen and type(gen.RunUndergroundStretchIfEnabled) == "function" then
			scheduled = gen.RunUndergroundStretchIfEnabled(map) == true
		end
		if defer_postload_bounds and not scheduled then
			Lifecycle.Apply(map, true)
		end
		-- Underground OVERVIEW mode (config UNDERGROUND_OVERVIEW_ENABLED): vanilla disallows
		-- overview on underground maps (mapdata.IsAllowedToEnterOverview=false), which is why
		-- there is no hover sector-highlight there -- zooming out stays in plain selection mode.
		-- Flipping the mapdata flag makes the game's own OverviewModeDialog (hover highlight,
		-- sector rollover, scan queue UI) work underground exactly as on the surface: the flag is
		-- read at CityStart and on every CurrentMapChangeDone to pick the dialog mode.
		if IsModMap(map) and (SuperBigMap.Config or {}).UNDERGROUND_OVERVIEW_ENABLED == true then
			if map.mapdata.IsAllowedToEnterOverview ~= true then
				if map.mapdata.SuperBigMapOriginalOverviewAllowedCaptured ~= true then
					map.mapdata.SuperBigMapOriginalOverviewAllowedCaptured = true
					map.mapdata.SuperBigMapOriginalOverviewAllowedWasNil =
						map.mapdata.IsAllowedToEnterOverview == nil
					map.mapdata.SuperBigMapOriginalOverviewAllowed = map.mapdata.IsAllowedToEnterOverview
				end
				map.mapdata.IsAllowedToEnterOverview = true
			end
		end
		return
	end

	-- Expansion-completion work runs only on a real mod-expanded scenario. The
	-- PreGame preview and non-mod maps are skipped entirely.
	if IsModMap(map) then
		-- Sync mapdata.Width/Height to the actual terrain grid size BEFORE the
		-- invalidate so the renderer's bounds extend to the full grid. The grids
		-- on expanded maps are 8192x8192 but mapdata often stays at the .fpk's
		-- native size (e.g. 6144), and the renderer appears to clamp drawing to
		-- mapdata bounds, so the expanded edge is fully rendered.
		if gen and type(gen.SyncMapDataToGrids) == "function" then
			gen.SyncMapDataToGrids(map)
		end
		-- Run the single supported proportional surface stretch.
		local scheduled = false
		if gen and type(gen.RunSurfaceStretchIfEnabled) == "function" then
			scheduled = gen.RunSurfaceStretchIfEnabled(map, "PostNewMapLoaded") == true
		end
		if defer_postload_bounds and not scheduled then
			Lifecycle.Apply(map, true)
		end
	end
end)

-- Engine fires MapSectorsReady at the END of Exploration:InitExploration (after
-- InitSectors + InitMapArea + InitialExplore). Ensure the final sector layout once
-- vanilla has completed that stage.
RegisterOnce("MapSectorsReady", function(exploration)
	if not active() then
		return
	end
	local sectors = SuperBigMap.SectorExploration
	local map = exploration and type(exploration.GetMap) == "function" and exploration:GetMap() or false
	LoadingLifecycle("MapSectorsReady", map)
	if sectors and map and type(sectors.EnsureSectorsBuilt) == "function" then
		sectors.EnsureSectorsBuilt(map, "MapSectorsReady")
	end
	if map and not IsModMap(map) then
		NormalizeVanillaRuntimeState(map, "MapSectorsReady non-mod map")
	end
end)

-- CityInitialized fires from InitCity right after InitExploration. Tapping it
-- confirms whether InitCity ran for the map (when the engine's NewMapLoaded
-- handler conditions did not skip it).
RegisterOnce("CityInitialized", function(city)
	if not active() then
		return
	end
	local map = city and type(city.GetMap) == "function" and city:GetMap() or false
	LoadingLifecycle("CityInitialized", map)
	local sectors = SuperBigMap.SectorExploration
	if sectors and map and type(sectors.EnsureSectorsBuilt) == "function" then
		sectors.EnsureSectorsBuilt(map, "CityInitialized-readiness-fallback")
	end
	local gen = SuperBigMap.MapGeneration
	if gen and map and type(gen.NotifyGenerationMilestone) == "function" then
		gen.NotifyGenerationMilestone(map, "CityInitialized", "CityInitialized-after-sectors")
	end
	local camera = SuperBigMap.OverviewCamera
	if IsModMap(map) and camera and type(camera.ReframeFinalizedDestination) == "function" then
		camera.ReframeFinalizedDestination(map, "CityInitialized")
	end
	if map and not IsModMap(map) then
		NormalizeVanillaRuntimeState(map, "CityInitialized non-mod map")
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
InstallRestoreInGameInterfaceGuard = function()
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
	local wrapper = function(...)
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
	end
	State.restore_in_game_interface_wrapper = wrapper
	rawset(_G, "RestoreInGameInterfaceOnLoadGame", wrapper)
end

UninstallRestoreInGameInterfaceGuard = function()
	local State = SuperBigMap.State or {}
	if rawget(_G, "RestoreInGameInterfaceOnLoadGame") == State.restore_in_game_interface_wrapper
		and type(State.original_restore_in_game_interface_on_load_game) == "function" then
		rawset(_G, "RestoreInGameInterfaceOnLoadGame",
			State.original_restore_in_game_interface_on_load_game)
	end
	State.restore_in_game_interface_wrapper = nil
	State.original_restore_in_game_interface_on_load_game = nil
end

RegisterOnce("LoadGame", function()
	if not active() then
		return
	end
	InstallRestoreInGameInterfaceGuard()
	local current = Global("CurrentMap")
	if not IsModMap(current) then
		NormalizeVanillaRuntimeState(current, "OnMsg.LoadGame non-mod save")
	end
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
	if gen and type(gen.PatchDeferredUndergroundAccess) == "function" then
		gen.PatchDeferredUndergroundAccess("LoadGame")
	end
	if gen and type(gen.SyncMapDataToGrids) == "function" and current then
		gen.SyncMapDataToGrids(current)
	end
	if gen and type(gen.ReseatExpandedUndergroundWonders) == "function" and current then
		local reseat_ok, reseat_result = gen.ReseatExpandedUndergroundWonders(current,
			"LoadGame after Lifecycle.Apply and mapdata synchronization")
		if reseat_ok ~= true then
			current.SuperBigMapUndergroundPreparationFailed = true
			current.SuperBigMapUndergroundStretchFailed = tostring(reseat_result)
		end
	end
	-- Save load preserves the city's MapSectors from save data; if its grid
	-- size doesn't match what our layout expects (e.g. saved at 10x10 vanilla,
	-- now expecting 20x20), rebuild here -- now that mapdata is synced to the real size.
	local sectors = SuperBigMap.SectorExploration
	if sectors and type(sectors.EnsureSectorsBuilt) == "function" and current then
		sectors.EnsureSectorsBuilt(current, "LoadGame")
	end
	-- Re-invalidate so the expanded terrain gets textures painted on. The save preserves the
	-- type/height grid data but the renderer may not stream textures into the expanded area
	-- until explicitly invalidated.
	if gen and type(gen.ReinvalidateExpandedTerrain) == "function" and current then
		gen.ReinvalidateExpandedTerrain(current)
	end
end)

-- Vanilla remembers selection/overview independently on each city. Capture only a real expanded
-- gameplay map being left; internal temporary-source switches run under the migration guard and
-- must neither replace nor consume this pending user-facing transition.
RegisterOnce("CurrentMapChange", function(map_slot, map)
	if not active() or editor_active() then return end
	local State = SuperBigMap.State or {}
	if State.vanilla_source_migration_active == true then return end
	local environment = map and map.mapdata and map.mapdata.Environment
	if IsModMap(map) and (environment == "Surface" or environment == "Underground") then
		State.overview_switch_source_map = map
		State.overview_switch_source_environment = environment
	else
		State.overview_switch_source_map = nil
		State.overview_switch_source_environment = nil
	end
end)

RegisterOnce("CurrentMapChangeDone", function(map_slot, map)
	-- Reclaim both menu-boundary wrappers after any late game-Lua replacement.
	InstallMainMenuTransitionGuards()
	if not active() then
		return
	end
	if HandleModEditorMap() then return end
	LoadingLifecycle("CurrentMapChangeDone", map, { map_slot = tostring(map_slot) })
	local gen = SuperBigMap.MapGeneration
	if IsModMap(map) and gen and type(gen.PatchDeferredUndergroundAccess) == "function" then
		gen.PatchDeferredUndergroundAccess("CurrentMapChangeDone")
	end
	-- Safety net for engine/generated-UI switch paths that bypassed the pre-switch gate. The
	-- handler schedules the full deferred preparation only when an unprepared expanded underground
	-- has already become current.
	if IsModMap(map) and gen and type(gen.HandleDeferredUndergroundMapChange) == "function" then
		gen.HandleDeferredUndergroundMapChange(map_slot, map)
	end
	local defer_rebuild = gen and type(gen.ShouldDeferStretchRebuilds) == "function"
		and gen.ShouldDeferStretchRebuilds(map) == true
	local skip_final_underground_rebuild = map
		and map.SuperBigMapSkipNextLifecycleBoundsRebuild == true
	if skip_final_underground_rebuild then
		map.SuperBigMapSkipNextLifecycleBoundsRebuild = nil
	end
	Lifecycle.Apply(map, not defer_rebuild and not skip_final_underground_rebuild)
	if IsModMap(map) and gen
		and type(gen.ReseatExpandedUndergroundWonders) == "function" then
		local reseat_ok, reseat_result = gen.ReseatExpandedUndergroundWonders(
			map, "CurrentMapChangeDone after Lifecycle.Apply")
		if reseat_ok ~= true then
			map.SuperBigMapUndergroundPreparationFailed = true
			map.SuperBigMapUndergroundStretchFailed = tostring(reseat_result)
		end
	end
	local sectors = SuperBigMap.SectorExploration
	if sectors and type(sectors.EnsureSectorsBuilt) == "function" and map then
		sectors.EnsureSectorsBuilt(map, "CurrentMapChangeDone")
	end
	-- This is the authoritative no-delay boundary for deferred underground Elevators. The map is
	-- current and Lifecycle.Apply has completed every final grid rebuild. The handler owns a
	-- monotonic generation token, so stale work from an older map transaction cannot proceed.
	if IsModMap(map) and gen
		and type(gen.HandlePendingUndergroundElevatorRestore) == "function" then
		gen.HandlePendingUndergroundElevatorRestore(
			map_slot, map, "CurrentMapChangeDone after Lifecycle.Apply")
	end
	-- Existing underground Elevators are moved by the stretch pass, so their cached absolute
	-- waypoint chains must be rebuilt after the final terrain/buildable lifecycle. Restore any
	-- rover lights deferred while that destination was off-screen at this same renderer-safe point.
	if IsModMap(map) and gen
		and type(gen.RebuildExpandedElevatorWaypointChains) == "function" then
		gen.RebuildExpandedElevatorWaypointChains(map,
			"CurrentMapChangeDone after final Elevator restoration")
	end
	if gen and type(gen.RestoreDeferredVehicleNightLights) == "function" then
		gen.RestoreDeferredVehicleNightLights(map)
	end
	if IsModMap(map) and gen
		and type(gen.RefreshBuriedWonderDarknessVisibility) == "function" then
		SafeCall(gen.RefreshBuriedWonderDarknessVisibility, map, "CurrentMapChangeDone")
	end
	local entrance_highlight = SuperBigMap.SectorHighlight
	if entrance_highlight and type(entrance_highlight.EnsureEntranceVisualsReady) == "function" then
		SafeCall(entrance_highlight.EnsureEntranceVisualsReady, map, nil, "CurrentMapChangeDone")
	end
	-- Clear any legacy underground overview decals on a map switch.
	do
		local highlight = SuperBigMap.SectorHighlight
		if highlight and type(highlight.UpdateUndergroundOverviewVisuals) == "function" then
			SafeCall(highlight.UpdateUndergroundOverviewVisuals, false)
		end
	end
	if not IsModMap(map) then
		NormalizeVanillaRuntimeState(map, "CurrentMapChangeDone non-mod map")
	end
	local State = SuperBigMap.State or {}
	if State.vanilla_source_migration_active ~= true then
		local source_map = State.overview_switch_source_map
		local source_environment = State.overview_switch_source_environment
		State.overview_switch_source_map = nil
		State.overview_switch_source_environment = nil
		local target_environment = map and map.mapdata and map.mapdata.Environment
		local surface_underground_switch = source_map and source_map ~= map
			and ((source_environment == "Surface" and target_environment == "Underground")
				or (source_environment == "Underground" and target_environment == "Surface"))
		if surface_underground_switch and IsModMap(map) then
			local camera = SuperBigMap.OverviewCamera
			if camera and type(camera.EnterAfterSurfaceUndergroundSwitch) == "function" then
				SafeCall(camera.EnterAfterSurfaceUndergroundSwitch, map,
					tostring(source_environment) .. "->" .. tostring(target_environment))
			end
		end
	end
end)

-- Already-current recovery never performs an artificial map switch, so it has no
-- CurrentMapChangeDone of its own. The completed stretch emits this explicit lifecycle event after
-- all final grids are installed; it follows the same tokenized handler and contains no timer.
RegisterOnce("SuperBigMapUndergroundSupplyReady", function(map, token_id, reason)
	if not active() or not IsModMap(map) then return end
	LoadingLifecycle("SuperBigMapUndergroundSupplyReady", map, {
		token = tostring(token_id), reason = tostring(reason),
	})
	local gen = SuperBigMap.MapGeneration
	if gen and type(gen.ReseatExpandedUndergroundWonders) == "function" then
		local reseat_ok, reseat_result = gen.ReseatExpandedUndergroundWonders(
			map, tostring(reason or "SuperBigMapUndergroundSupplyReady"))
		if reseat_ok ~= true then
			map.SuperBigMapUndergroundPreparationFailed = true
			map.SuperBigMapUndergroundStretchFailed = tostring(reseat_result)
			return
		end
	end
	if gen and type(gen.HandlePendingUndergroundElevatorRestore) == "function" then
		gen.HandlePendingUndergroundElevatorRestore(map and map.slot, map,
			tostring(reason or "SuperBigMapUndergroundSupplyReady") .. " token=" .. tostring(token_id))
	end
	if gen and type(gen.RebuildExpandedElevatorWaypointChains) == "function" then
		gen.RebuildExpandedElevatorWaypointChains(map,
			tostring(reason or "SuperBigMapUndergroundSupplyReady") .. " final geometry")
	end
end)

-- Authoritative, class-agnostic rocket-landing hook: the RocketLanded message fires for
-- every rocket regardless of subclass (the LandOnMars method wrap can miss subclasses if
-- the engine flattens methods). Delegates to RocketRules to snap a ground-landed rocket
-- onto the live expanded terrain.
RegisterOnce("RocketLandAttempt", function(rocket)
	if not active() then
		return
	end
	local map = rocket and type(rocket.GetMap) == "function" and SafeCall(rocket.GetMap, rocket)
	if not IsModMap(map) then return end
	local rockets = SuperBigMap.RocketRules
	if rockets and type(rockets.OnRocketLandAttempt) == "function" then
		SafeCall(rockets.OnRocketLandAttempt, rocket)
	end
end)

RegisterOnce("RocketLanded", function(rocket)
	if not active() then
		return
	end
	local map = rocket and type(rocket.GetMap) == "function" and SafeCall(rocket.GetMap, rocket)
	if not IsModMap(map) then return end
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
	if SuperBigMap.State.main_menu_vanilla == true then
		return
	end
	local gen = SuperBigMap.MapGeneration
	if gen and type(gen.PatchRandomMapGenerator) == "function" then
		gen.PatchRandomMapGenerator()
	end
	-- CommonLua finishes reloading after mod modules first execute and can replace global
	-- ChangeCurrentMapSlot with vanilla afterward. Re-verify the first-access underground gate
	-- from these later lifecycle events; the patch is identity-checked and otherwise a no-op.
	if gen and type(gen.PatchDeferredUndergroundAccess) == "function" then
		gen.PatchDeferredUndergroundAccess("EnsureGeneratorHookInstalled")
	end
end

local function EnsurePregameToggleInstalled(reason)
	if (SuperBigMap.Config or {}).ENABLE_MOD == false then
		return
	end
	InstallMainMenuTransitionGuards()
	-- Unlike gameplay patches, the opt-in control belongs to pregame itself. Classes can be
	-- rebuilt after ResetGameSession, so reclaim its Open wrapper even while gameplay remains in
	-- the fully vanilla main-menu state. PatchLandingDialog is identity-checked and otherwise inert.
	local toggle = SuperBigMap.PregameToggle
	if toggle and type(toggle.PatchLandingDialog) == "function" then
		toggle.PatchLandingDialog()
	end
end

RegisterOnce("ClassesPostprocess", function()
	-- Install the generator hook regardless of active() so it is ready before any pre-game
	-- landing-spot preview generates a map (prevents the GSRP overflow crash).
	EnsureGeneratorHookInstalled()
	EnsurePregameToggleInstalled("ClassesPostprocess")
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
	EnsurePregameToggleInstalled("DataLoaded")
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
	local sector_map = sector and type(sector.GetMap) == "function"
		and SafeCall(sector.GetMap, sector) or Global("CurrentMap")
	if not IsModMap(sector_map) then return end
	-- Reveal cloned subsurface deposits/anomalies now that their sector is scanned.
	local deposits = SuperBigMap.DepositRules
	if deposits and type(deposits.OnSectorScanned) == "function" then
		deposits.OnSectorScanned(status, sector)
	end
	-- Revealing an underground entrance completes a vanilla scenario that may create or refresh
	-- its sign. Re-assert the exact post-expansion starting XYZ after the reveal has run.
	local gen = SuperBigMap.MapGeneration
	if gen and type(gen.RestoreEntranceBadgePositions) == "function" then
		local map = sector_map
		if not map and sector and sector.city and type(sector.city.GetMap) == "function" then
			map = SafeCall(sector.city.GetMap, sector.city)
		end
		SafeCall(gen.RestoreEntranceBadgePositions, map or Global("CurrentMap"), "SectorScanned")
	end
end)

-- These wrappers sit on engine methods/functions that ClassesBuilt and Lua reloads recreate.
-- Reinstall them before the active-map gate: pre-game map previews and the first NewMap build
-- already use ConstructionController/BuildableGrid, so waiting for Lifecycle.Apply is too late.
local function ReinstallTerrainCriticalPatches(reason)
	local cfg = SuperBigMap.Config or {}
	if cfg.ENABLE_MOD == false then
		return false
	end
	if (SuperBigMap.State or {}).main_menu_vanilla == true then
		return false
	end
	-- These hooks are transparent on non-expanded maps, so keeping them installed while the
	-- main menu is visible avoids missing the first pre-active construction/grid call.
	local bounds = SuperBigMap.MapBounds
	local bounds_fn = bounds and (bounds.ReinstallGlobalHooks or bounds.ApplyModBehavior)
	local bounds_ok, bounds_result = false, "module/function unavailable"
	if type(bounds_fn) == "function" then
		bounds_ok, bounds_result = pcall(bounds_fn)
	end
	local rockets = SuperBigMap.RocketRules
	local rockets_fn = rockets and (rockets.ReinstallGlobalHooks or rockets.ApplyModBehavior)
	local rockets_ok, rockets_result = false, "module/function unavailable"
	if type(rockets_fn) == "function" then
		rockets_ok, rockets_result = pcall(rockets_fn)
	end
	return bounds_ok and rockets_ok
end

RegisterOnce("ClassesBuilt", function()
	-- ClassesBuilt rebuilds RandomMapGenerator to vanilla. Re-install our hook even before a
	-- mod map is active, so a pre-game landing-spot preview can't run vanilla DoGenerate.
	EnsureGeneratorHookInstalled()
	EnsurePregameToggleInstalled("ClassesBuilt")
	ReinstallTerrainCriticalPatches("ClassesBuilt")
	if not active() then
		return
	end
	-- ClassesBuilt rebuilds RandomMapGenerator to vanilla; re-install our hook
	-- (the patch self-verifies and re-applies if its wrapper was reset).
	local gen = SuperBigMap.MapGeneration
	if gen then
		gen.PatchRandomMapGenerator()
		if type(gen.PatchEntranceBadgePosition) == "function" then
			gen.PatchEntranceBadgePosition()
		end
		if type(gen.PatchCaveInShapePoints) == "function" then
			gen.PatchCaveInShapePoints()
		end
		if type(gen.PatchUndergroundWonderShapePoints) == "function" then
			gen.PatchUndergroundWonderShapePoints()
		end
	end
	local deposits = SuperBigMap.DepositRules
	if deposits and type(deposits.ApplyModBehavior) == "function" then
		SafeCall(deposits.ApplyModBehavior)
	end
	local sectors = SuperBigMap.SectorExploration
	if sectors then
		sectors.InstallSectorPatch()
		if type(sectors.PatchInitialExplore) == "function" then
			sectors.PatchInitialExplore()
		end
	end
	-- Global-function wraps (FlattenTerrainInBuildShape etc.) get wiped when a Lua reload
	-- re-executes the game files; the rocket patches self-verify, so re-applying is a no-op
	-- when they are still installed.
	local rockets = SuperBigMap.RocketRules
	if rockets and type(rockets.ApplyModBehavior) == "function" then
		SafeCall(rockets.ApplyModBehavior)
	end
end)

RegisterOnce("ModsReloaded", function()
	-- The restart notice must fire regardless of the active() gate below (it has its own
	-- gating), so try it first.
	if type(SuperBigMap.ShowFreshRestartNotice) == "function" then
		SuperBigMap.ShowFreshRestartNotice()
	end
	-- Re-install the generator hook on reload regardless of active() (a mod reload resets the
	-- RandomMapGenerator class to vanilla; the pre-game preview can run before any map is active).
	EnsureGeneratorHookInstalled()
	EnsurePregameToggleInstalled("ModsReloaded")
	ReinstallTerrainCriticalPatches("ModsReloaded")
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
	EnsurePregameToggleInstalled("ChangingMap")
	ReinstallTerrainCriticalPatches("ChangingMap")
	if not active() then
		return
	end
	if map_instance and map_instance.SuperBigMapVanillaSourceMigration == true then
		return
	end
	local gen = SuperBigMap.MapGeneration
	if gen then
		gen.PrepareMapDataForExpansion(map_slot, map_name, map_instance, "ChangingMap")
	end
	LoadingLifecycle("ChangingMap after expansion allocation plan", map_instance, {
		map_slot = tostring(map_slot), map_name = tostring(map_name),
	})
	local sectors = SuperBigMap.SectorExploration
	if sectors then
		sectors.EnsureSectorPatch(map_instance, "ChangingMap")
	end
end)

RegisterOnce("NewMapObject", function(map)
	if not active() then
		return
	end
	if map and map.SuperBigMapVanillaSourceMigration == true then
		return
	end
	local gen = SuperBigMap.MapGeneration
	if gen then
		gen.AttachPendingMapState(map)
	end
	LoadingLifecycle("NewMapObject", map)
end)

RegisterOnce("MapGenerated", function(map)
	if not active() then
		return
	end
	local gen = SuperBigMap.MapGeneration
	local mod_map = IsModMap(map)
	LoadingLifecycle("MapGenerated", map, { mod_map = tostring(mod_map) })
	if mod_map and gen and type(gen.PatchDeferredUndergroundAccess) == "function" then
		gen.PatchDeferredUndergroundAccess("MapGenerated")
	end
	local defer_rebuild = gen and type(gen.ShouldDeferStretchRebuilds) == "function"
		and gen.ShouldDeferStretchRebuilds(map) == true
	if gen then
		gen.FinalizeExpandedMap(map)
	end
	local sectors = SuperBigMap.SectorExploration
	if sectors then
		sectors.EnsureSectorPatch(map, "MapGenerated")
		if type(sectors.EnsureSectorsBuilt) == "function" then
			sectors.EnsureSectorsBuilt(map, "MapGenerated")
		end
	end
	-- Final terrain re-invalidate after source generation and sector rebuild.
	-- PostNewMapLoaded fires BEFORE MapGenerated, so the earlier invalidate ran
	-- when the type grid was still uniform 17 from initial map allocation.
	-- This second pass runs after generated texture data is available.
	if mod_map and gen then
		if type(gen.SyncMapDataToGrids) == "function" then
			gen.SyncMapDataToGrids(map)
		end
		if not defer_rebuild and type(gen.ReinvalidateExpandedTerrain) == "function" then
			gen.ReinvalidateExpandedTerrain(map)
		end
	end
	local entrance_highlight = SuperBigMap.SectorHighlight
	if mod_map and entrance_highlight and type(entrance_highlight.EnsureEntranceVisualsReady) == "function" then
		SafeCall(entrance_highlight.EnsureEntranceVisualsReady, map, nil, "MapGenerated-finalized")
	end
	-- The startup OverviewMode message may have fired while exact-vanilla source
	-- generation owned CurrentMap. Reframe explicitly now that the expanded map and
	-- its complete sector grid are finalized; retries cover the UI opening slightly
	-- after MapGenerated.
	local camera = SuperBigMap.OverviewCamera
	if mod_map and camera and type(camera.ReframeFinalizedDestination) == "function" then
		camera.ReframeFinalizedDestination(map, "MapGenerated-after-sectors")
	end
	if gen and type(gen.NotifyGenerationMilestone) == "function" then
		gen.NotifyGenerationMilestone(map, "MapGenerated", "MapGenerated-handler-complete")
	end
	if not mod_map then
		local environment = map and map.mapdata and map.mapdata.Environment
		local terrain_copy = SuperBigMap.TerrainCopy
		if environment == "Underground" and terrain_copy
			and type(terrain_copy.AuditCaveInSnapshot) == "function" then
			pcall(terrain_copy.AuditCaveInSnapshot, map, "vanilla",
				"vanilla underground MapGenerated final state")
		end
		NormalizeVanillaRuntimeState(map, "MapGenerated non-mod map")
	end
end)

RegisterOnce("OverviewMode", function(enabled)
	if SuperBigMap.State and SuperBigMap.State.vanilla_source_migration_active == true then
		return
	end
	if editor_active() then
		return
	end
	if not active() then
		return
	end
	local current_map = Global("CurrentMap")
	if not IsModMap(current_map) then
		NormalizeVanillaRuntimeState(current_map, "OverviewMode non-mod map")
		return
	end
	-- Underground sectors are data-only: keep their hover context but suppress all grid decals.
	local highlight = SuperBigMap.SectorHighlight
	if highlight and type(highlight.UpdateUndergroundOverviewVisuals) == "function" then
		SafeCall(highlight.UpdateUndergroundOverviewVisuals, enabled == true)
	end
	if enabled and highlight and type(highlight.EnsureEntranceVisualsReady) == "function" then
		SafeCall(highlight.EnsureEntranceVisualsReady, Global("CurrentMap"), true, "OverviewMode(true)")
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

-- Apply the custom first overview-exit transition on expanded maps.
RegisterOnce("CameraTransitionStart", function(eye, lookat, time)
	if editor_active() then
		return
	end
	if not active() then
		return
	end
	local current_map = Global("CurrentMap")
	if not IsModMap(current_map) then
		NormalizeVanillaRuntimeState(current_map, "CameraTransitionStart non-mod map")
		return
	end
	-- Take over only the first/startup overview->sector exit descent with a straight
	-- mod-driven path. Later overview exits are left on the vanilla transition path.
	local overview = SuperBigMap.OverviewCamera
	if overview and type(overview.TakeOverExitTransition) == "function" then
		overview.TakeOverExitTransition(eye, lookat, time)
	end
end)

RegisterOnce("CameraTransitionEnd", function()
	if SuperBigMap.State and SuperBigMap.State.vanilla_source_migration_active == true then
		return
	end
	if editor_active() then
		return
	end
	if not active() then
		return
	end
	local current_map = Global("CurrentMap")
	if not IsModMap(current_map) then
		NormalizeVanillaRuntimeState(current_map, "CameraTransitionEnd non-mod map")
		return
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
	local highlight = SuperBigMap.SectorHighlight
	if highlight and type(highlight.EnsureEntranceVisualsReady) == "function" then
		SafeCall(highlight.EnsureEntranceVisualsReady, Global("CurrentMap"), overview_active,
			"CameraTransitionEnd")
	end
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
	local cam = SuperBigMap.OverviewCamera
	if cam and type(cam.RestoreVanillaBehavior) == "function" then cam.RestoreVanillaBehavior() end
	local render = SuperBigMap.OverviewRender
	if render and type(render.Apply) == "function" then render.Apply(false) end
	local curtains = SuperBigMap.OverviewCurtains
	if curtains and type(curtains.RestoreVanillaBehavior) == "function" then curtains.RestoreVanillaBehavior() end
	local zoom = SuperBigMap.ZoomPlusIntegration
	if zoom and type(zoom.RestoreVanillaBehavior) == "function" then zoom.RestoreVanillaBehavior() end

end)

-- Leaving the editor: reinstall the mod's patches and re-apply to the current map
-- (Apply is a no-op on non-mod maps) so normal play resumes as before.
RegisterOnce("GameExitEditor", function()
	if not active() then
		return
	end
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

-- Bigger Maps -- reversible lifecycle + the single OnMsg site.
--
-- Owns the master Enable/Disable (idempotent) and the per-map Apply. Enable installs
-- every domain's behavior (ApplyModBehavior) and applies it to the current map;
-- Disable restores vanilla (RestoreVanillaBehavior) in reverse order. ALL OnMsg
-- handlers live here, registered once and gated on IsActive(), each delegating to the
-- domain modules in the order the originals ran (e.g. tile quadrants before building
-- sectors on MapGenerated). No engine patching lives here -- only orchestration.

local BiggerMaps = rawget(_G, "BiggerMaps")
if type(BiggerMaps) ~= "table" then
	BiggerMaps = {}
	rawset(_G, "BiggerMaps", BiggerMaps)
end

BiggerMaps.State = BiggerMaps.State or {}

local Engine = BiggerMaps.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall

-- Map liveness / terrain size are intentionally NOT in bm_engine (their resolution
-- order is context-specific); kept local for map resolution + the apply log.
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

-- Re-install the static overview patches (FOV widen, camera override, curtain stubs)
-- and re-apply ZoomPlus. Delegates to the extracted domain modules.
local function ApplyOverviewPatches()
	local camera = BiggerMaps.OverviewCamera
	local curtains = BiggerMaps.OverviewCurtains
	local zoom = BiggerMaps.ZoomPlusIntegration

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
	return BiggerMaps.State.active == true
end

-- Per-map application: bring the loaded map's bounds/sectors/overview into the
-- mod's configured state. Safe to call repeatedly (each step is idempotent).
function Lifecycle.Apply(map, rebuild)
	map = ResolveLiveMap(map)
	if not map then
		return false
	end

	ApplyOverviewPatches()

	local bounds = BiggerMaps.MapBounds
	if bounds then
		bounds.ResetMapDataBounds(map, map.mapdata)
		bounds.ResetMapAreas(map)

		if rebuild and bounds.FullMapPlayableEnabled() then
			bounds.RebuildMapBounds(map)
			bounds.RefreshSectors(map)
		end
	end

	local render = BiggerMaps.OverviewRender
	if render then
		render.Apply(Global("IsOverviewMode") and IsOverviewMode())
	end
	local camera = BiggerMaps.OverviewCamera
	if camera then
		camera.ResetOverviewCamera(map, 0)
	end

	local DebugLog = BiggerMaps.DebugLog
	if DebugLog then
		local width, height = TerrainSize(map)
		DebugLog.Info("Apply", "playable bounds reset to full terrain", { width = width, height = height })
	end

	return true
end

-- Install order (dependencies first); restore is the exact reverse.
local APPLY_ORDER = {
	"MapGeneration",
	"SectorGrid",
	"SectorExploration",
	"SectorHighlight",
	"OverviewCamera",
	"OverviewCurtains",
	"OverviewRender",
	"ZoomPlusIntegration",
	"MapBounds",
}

local RESTORE_ORDER = {
	"MapBounds",
	"ZoomPlusIntegration",
	"OverviewRender",
	"OverviewCurtains",
	"OverviewCamera",
	"SectorHighlight",
	"SectorExploration",
	"SectorGrid",
	"MapGeneration",
}

local function run_phase(order, method)
	for i = 1, #order do
		local mod = BiggerMaps[order[i]]
		if type(mod) == "table" and type(mod[method]) == "function" then
			SafeCall(mod[method])
		end
	end
end

function Lifecycle.Enable()
	local cfg = BiggerMaps.Config or {}
	if cfg.ENABLE_MOD == false then
		local DebugLog = BiggerMaps.DebugLog
		if DebugLog then
			DebugLog.Info("Lifecycle", "enable skipped: ENABLE_MOD is false")
		end
		return false
	end

	if Lifecycle.IsActive() then
		return true
	end

	run_phase(APPLY_ORDER, "ApplyModBehavior")
	BiggerMaps.State.active = true
	Lifecycle.Apply(Global("CurrentMap"), true)

	local DebugLog = BiggerMaps.DebugLog
	if DebugLog then
		DebugLog.Info("Lifecycle", "enabled")
	end
	if BiggerMaps.Validation then
		BiggerMaps.Validation.CheckRuntimeState()
	end
	return true
end

function Lifecycle.Disable()
	if not Lifecycle.IsActive() then
		return true
	end

	run_phase(RESTORE_ORDER, "RestoreVanillaBehavior")
	BiggerMaps.State.active = false

	local DebugLog = BiggerMaps.DebugLog
	if DebugLog then
		DebugLog.Info("Lifecycle", "disabled (vanilla behavior restored)")
	end
	if BiggerMaps.Validation then
		BiggerMaps.Validation.CheckVanillaRestoration()
	end
	return true
end

BiggerMaps.Lifecycle = Lifecycle

-- ============================================================================
-- The single OnMsg site. Every handler is gated on IsActive() and delegates to
-- the domain modules in the original dispatch order.
-- ============================================================================
local function active()
	return Lifecycle.IsActive()
end

Engine.ChainOnMsg("PreNewMap", function(map, mapdata)
	if not active() then
		return
	end
	local bounds = BiggerMaps.MapBounds
	if bounds then
		bounds.ResetMapDataBounds(map, mapdata)
	end
	local sectors = BiggerMaps.SectorExploration
	if sectors then
		sectors.EnsureSectorPatch(map or mapdata, "PreNewMap")
	end
end)

Engine.ChainOnMsg("NewMap", function(map, mapdata)
	if not active() then
		return
	end
	Lifecycle.Apply(map, true)
	local sectors = BiggerMaps.SectorExploration
	if sectors then
		sectors.EnsureSectorPatch(map or mapdata, "NewMap")
	end
end)

Engine.ChainOnMsg("NewMapLoaded", function(map, mapdata)
	if not active() then
		return
	end
	Lifecycle.Apply(map, false)
end)

Engine.ChainOnMsg("PostNewMapLoaded", function(map, mapdata)
	if not active() then
		return
	end
	Lifecycle.Apply(map, true)
end)

Engine.ChainOnMsg("LoadGame", function()
	if not active() then
		return
	end
	Lifecycle.Apply(Global("CurrentMap"), true)
end)

Engine.ChainOnMsg("CurrentMapChangeDone", function(map_slot, map)
	if not active() then
		return
	end
	Lifecycle.Apply(map, true)
end)

Engine.ChainOnMsg("ClassesPostprocess", function()
	if not active() then
		return
	end
	ApplyOverviewPatches()
	local gen = BiggerMaps.MapGeneration
	if gen then
		gen.PatchRandomMapGenerator()
	end
	local sectors = BiggerMaps.SectorExploration
	if sectors then
		sectors.InstallSectorPatch()
	end
end)

Engine.ChainOnMsg("DataLoaded", function()
	if not active() then
		return
	end
	ApplyOverviewPatches()
	local gen = BiggerMaps.MapGeneration
	if gen then
		gen.PatchRandomMapGenerator()
	end
	local sectors = BiggerMaps.SectorExploration
	if sectors then
		sectors.InstallSectorPatch()
	end
end)

Engine.ChainOnMsg("ClassesBuilt", function()
	if not active() then
		return
	end
	local sectors = BiggerMaps.SectorExploration
	if sectors then
		sectors.InstallSectorPatch()
	end
end)

Engine.ChainOnMsg("ModsReloaded", function()
	if not active() then
		return
	end
	local sectors = BiggerMaps.SectorExploration
	if sectors then
		sectors.InstallSectorPatch()
	end
end)

Engine.ChainOnMsg("ChangingMap", function(map_slot, map_name, map_instance)
	if not active() then
		return
	end
	local gen = BiggerMaps.MapGeneration
	if gen then
		gen.PrepareMapDataForQuadrantCopy(map_slot, map_name, map_instance, "ChangingMap")
	end
	local sectors = BiggerMaps.SectorExploration
	if sectors then
		sectors.EnsureSectorPatch(map_instance, "ChangingMap")
	end
end)

Engine.ChainOnMsg("NewMapObject", function(map)
	if not active() then
		return
	end
	local gen = BiggerMaps.MapGeneration
	if gen then
		gen.AttachPendingMapState(map)
	end
end)

Engine.ChainOnMsg("MapGenerated", function(map)
	if not active() then
		return
	end
	local gen = BiggerMaps.MapGeneration
	if gen then
		gen.TileQuadrants(map)
	end
	local sectors = BiggerMaps.SectorExploration
	if sectors then
		sectors.EnsureSectorPatch(map, "MapGenerated")
	end
end)

Engine.ChainOnMsg("OverviewMode", function(enabled)
	if not active() then
		return
	end
	local camera = BiggerMaps.OverviewCamera
	if enabled then
		if camera then
			camera.RefreshOverviewCamera()
			camera.ScheduleOverviewCameraRefresh()
		end
	else
		if camera then
			camera.CancelScheduledRefresh()
		end
		local render = BiggerMaps.OverviewRender
		if render then
			render.Apply(false)
		end
	end
end)

Engine.ChainOnMsg("CameraTransitionEnd", function()
	if not active() then
		return
	end
	local zoom = BiggerMaps.ZoomPlusIntegration
	if zoom then
		zoom.ApplyNormalZoom()
	end
	local camera = BiggerMaps.OverviewCamera
	if camera then
		camera.RefreshOverviewCamera()
	end
end)

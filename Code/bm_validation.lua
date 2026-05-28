-- Bigger Maps -- diagnostic self-checks (logs only, no behavior).
--
-- Cheap, read-only snapshots of the mod's runtime state, written through the
-- centralized logger. Called by the lifecycle around Enable/Disable when DEBUG_LOGS
-- is on, and available to call by hand from the console for troubleshooting. These
-- never change engine state.

local BiggerMaps = rawget(_G, "BiggerMaps")
if type(BiggerMaps) ~= "table" then
	BiggerMaps = {}
	rawset(_G, "BiggerMaps", BiggerMaps)
end

local Engine = BiggerMaps.Engine
local Global = Engine.Global

local function log(message, data)
	local DebugLog = BiggerMaps.DebugLog
	if DebugLog then
		DebugLog.Info("Validation", message, data)
	end
end

local Validation = {}

-- After Enable: patches should be installed (version guards set, globals patched).
function Validation.CheckRuntimeState()
	local State = BiggerMaps.State or {}
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
	local State = BiggerMaps.State or {}
	log("vanilla restoration", {
		active = State.active == true,
		sector_patch = State.sector_patch_version,
		sector_basic_patch = State.sector_basic_patch_version,
		highlight_patch = State.overview_highlight_patch_version,
		generator_patch = State.generator_patch_version,
		original_sector_count = State.original_sector_count,
	})
	return true
end

-- Snapshot of the optional ZoomPlus integration.
function Validation.CheckIntegrations()
	local zoom_plus = Global("ZoomPlus")
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

BiggerMaps.Validation = Validation

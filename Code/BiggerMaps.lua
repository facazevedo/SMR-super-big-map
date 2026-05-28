-- Bigger Maps -- mod entry point.
--
-- By the time this file loads, the foundation (version/config/debug/engine), the
-- domain modules, and the lifecycle have all loaded (see metadata.lua `code` order).
-- This file does nothing but log the active configuration and start the reversible
-- lifecycle once. Everything else -- patching, per-map apply, OnMsg wiring -- lives
-- in the domain modules and bm_lifecycle.lua.

local BiggerMaps = rawget(_G, "BiggerMaps")
if type(BiggerMaps) ~= "table" then
	return
end

local Config = BiggerMaps.Config or {}
local DebugLog = BiggerMaps.DebugLog
if DebugLog then
	DebugLog.Info("Init", "Bigger Maps loaded", {
		enabled = Config.ENABLE_MOD ~= false,
		terrain = Config.TERRAIN_SIZE,
		grid = Config.SECTOR_GRID,
	})
end

if BiggerMaps.Lifecycle and type(BiggerMaps.Lifecycle.Enable) == "function" then
	BiggerMaps.Lifecycle.Enable()
end

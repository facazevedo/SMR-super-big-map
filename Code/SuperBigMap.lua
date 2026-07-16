-- Super Big Map -- mod entry point.
--
-- By the time this file loads, the foundation (version/config/debug/engine), the
-- domain modules, and the lifecycle have all loaded (see metadata.lua `code` order).
-- This file does nothing but log the active configuration and start the reversible
-- lifecycle once. Everything else -- patching, per-map apply, OnMsg wiring -- lives
-- in the domain modules and sbm_lifecycle.lua.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	return
end

local Config = SuperBigMap.Config or {}
local DebugLog = SuperBigMap.DebugLog
if DebugLog then
	DebugLog.Info("Lifecycle", "Super Big Map loaded", {
		enabled = Config.ENABLE_MOD ~= false,
		layout = "stretch-expanded",
		sector_grid = "expanded-corner-anchored",
		expansion_step_01 = Config.EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE == true,
		enrichment_spread_comparison = Config.DEBUG_ENRICHMENTSPREADCOMPARISON == true,
	})
end

if SuperBigMap.Lifecycle and type(SuperBigMap.Lifecycle.Enable) == "function" then
	SuperBigMap.Lifecycle.Enable()
end

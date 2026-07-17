-- Super Big Map -- mod entry point.
--
-- By the time this file loads, the foundation (version/config/engine), the
-- domain modules, and the lifecycle have all loaded (see metadata.lua `code` order).
-- This file starts the reversible lifecycle once. Everything else -- patching,
-- per-map apply, and OnMsg wiring -- lives
-- in the domain modules and sbm_lifecycle.lua.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	return
end

if SuperBigMap.Lifecycle and type(SuperBigMap.Lifecycle.Enable) == "function" then
	SuperBigMap.Lifecycle.Enable()
end

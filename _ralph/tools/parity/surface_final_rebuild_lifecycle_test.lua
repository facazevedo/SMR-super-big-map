-- Production-function regression for the accepted surface final-grid lifecycle.
-- Run from the project root:
--   lua _ralph/tools/parity/surface_final_rebuild_lifecycle_test.lua

local function read(path)
	local file = assert(io.open(path, "rb"))
	local value = file:read("*a")
	file:close()
	return value
end

local config_source = read("Code/sbm_config.lua")
local map_source = read("Code/sbm_map_generation.lua")
local runner = assert(map_source:match(
	"(local function RunSurfaceStretchIfEnabled.-)\n\nlocal function SyncMapDataToGrids"),
	"production surface runner not found")
local rebuild_block = assert(map_source:match(
	"(function SuperBigMap%.GenerationGrids%.RebuildFinal.-)\n\n%-%- Stretch%-only surface"),
	"production final-grid rebuild not found")

-- The accepted practical-equivalence lifecycle commits every object-grid mutation through one
-- combined pass-edit transaction. A second and third whole-map rebuild added no gameplay
-- guarantee and cost several seconds apiece, so neither may return to the T1 path.
local immediate =
	'SuperBigMap.GenerationGrids.RebuildFinal(map, "after last object-grid transaction")'
local scheduled =
	'SuperBigMap.GenerationGrids.RebuildFinal(\n\t\t\t\t\t\tmap, "post-pipeline scheduled revalidation")'
local has_immediate = runner:find(immediate, 1, true) ~= nil
local has_scheduled = runner:find(scheduled, 1, true) ~= nil
assert(not has_immediate, "redundant immediate whole-map rebuild returned")
assert(not has_scheduled, "redundant scheduled whole-map rebuild returned")
assert(runner:find('ResumeCombinedPassEdits(\n\t\t\t\t\t"after surface marker movement")',1,true),
	"authoritative combined pass-edit commit is missing")
local ready=assert(runner:find("map.SuperBigMapSurfacePostPipelineRevalidationComplete = true",1,true))
local correction=assert(runner:find("map.SuperBigMapSurfaceDecorationCorrectionComplete = true",1,true))
assert(correction<ready,"T1 must wait for completed rock seating")
assert(not runner:find("sleep(2000)",1,true),"post-T1 seating delay returned")

-- Rejected-unit guard: neither the config seam nor the completion-deferral machinery may return
-- without new native-equivalence evidence.
assert(config_source:find("OptimizeDeferImmediateSurfaceFinalGridRebuild", 1, true) == nil,
	"rejected unit #11 config seam returned")
assert(runner:find("SuperBigMapSurfaceImmediateFinalRebuildSkipped", 1, true) == nil,
	"rejected unit #11 immediate-rebuild skip returned")
assert(runner:find("hold_completion_for_revalidation", 1, true) == nil,
	"rejected unit #11 completion deferral returned")

-- RebuildFinal remains available for underground preparation and recovery paths. Execute the
-- shipped implementation once to retain its independent full-grid contract.
local calls = {}
local function record(name, value)
	calls[#calls + 1] = { name = name, value = value }
end
local terrain = {
	InvalidateHeight = function(_, region) record("InvalidateHeight", region) end,
	InvalidateType = function(_, region) record("InvalidateType", region) end,
	RebuildPassability = function(_, region) record("RebuildPassability", region) end,
	HashPassability = function() return 123456 end,
}
local env = setmetatable({
	SuperBigMap = { GenerationGrids = {} },
	Engine = { MapDataEnvironment = function(mapdata) return mapdata.Environment end },
	Global = function(name)
		if name == "terrain" then return terrain end
		if name == "box" then
			return function(x0, y0, x1, y1)
				return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
			end
		end
		if name == "RebuildBuildableGrid" then
			return function(map) record("RebuildBuildableGrid", map) end
		end
		error("unexpected Global(" .. tostring(name) .. ")")
	end,
	cfg_bool = function(key, default)
		assert(key == "FINAL_PASSABILITY_INVALIDATE")
		return default
	end,
	TerrainSize = function() return 819200, 819200 end,
	GetPreciseTicks = function() return 0 end,
	LoadingBegin = function() return true end,
	LoadingEnd = function() end,
	SetLoadingPhase = function() end,
}, { __index = _G })
local rebuild = assert(load(rebuild_block
	.. "\nreturn SuperBigMap.GenerationGrids.RebuildFinal",
	"production-surface-final-rebuild", "t", env))()
local map = { mapdata = { Environment = "Surface" } }
local active_stages = {
	"offline recovery verification",
}
for _, stage in ipairs(active_stages) do rebuild(map, stage) end

local counts = {}
for _, call in ipairs(calls) do
	counts[call.name] = (counts[call.name] or 0) + 1
	if call.name ~= "RebuildBuildableGrid" then
		local box = call.value
		assert(box.x0 == 0 and box.y0 == 0 and box.x1 == 819200 and box.y1 == 819200,
			call.name .. " did not cover the whole expanded surface")
	end
end
local expected = #active_stages
assert(counts.InvalidateHeight == expected and counts.InvalidateType == expected
	and counts.RebuildPassability == expected and counts.RebuildBuildableGrid == expected,
	"production calls did not execute one complete rebuild sequence per active stage")
assert(map.SuperBigMapFinalPassCount == expected,
	"production rebuild counter did not observe every active surface call")
assert(expected == 1,"offline recovery contract should exercise one complete rebuild")
print("PASS surface final rebuild lifecycle: combined commit retained; redundant rebuilds absent")

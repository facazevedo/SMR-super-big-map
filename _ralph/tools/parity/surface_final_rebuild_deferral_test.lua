-- Production-function red/green regression for ranked optimization unit #11.
-- Run from the project root:
--   lua _ralph/tools/parity/surface_final_rebuild_deferral_test.lua

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

-- Keep the red case tied to the actual production lifecycle: v936 contains both the immediate
-- closing rebuild and the later canonical post-pipeline rebuild on one successful surface run.
local immediate =
	'SuperBigMap.GenerationGrids.RebuildFinal(map, "after last object-grid transaction")'
local scheduled =
	'SuperBigMap.GenerationGrids.RebuildFinal(\n\t\t\t\t\t\tmap, "post-pipeline scheduled revalidation")'
local has_immediate = runner:find(immediate, 1, true) ~= nil
local has_scheduled = runner:find(scheduled, 1, true) ~= nil
assert(has_immediate, "production red baseline lost its immediate final rebuild")
assert(has_scheduled, "production canonical post-pipeline rebuild is missing")

-- Green contract: defer the superseded immediate call, keep completion/loading pending until the
-- canonical scheduled call succeeds, and never retry a failed optimization behind a fallback.
local config_enabled = config_source:find(
	"config.OptimizeDeferImmediateSurfaceFinalGridRebuild = true", 1, true) ~= nil
local config_exported = config_source:find(
	"C.OPTIMIZE_DEFER_IMMEDIATE_SURFACE_FINAL_GRID_REBUILD", 1, true) ~= nil
local requests_deferral = runner:find(
	'cfg_bool("OPTIMIZE_DEFER_IMMEDIATE_SURFACE_FINAL_GRID_REBUILD", false)', 1, true) ~= nil
local skips_immediate = runner:find(
	"map.SuperBigMapSurfaceImmediateFinalRebuildSkipped = true", 1, true) ~= nil
local holds_completion = runner:find("hold_completion_for_revalidation", 1, true) ~= nil
local publishes_after_success = runner:find("publish_deferred_surface_completion()", 1, true) ~= nil
local hidden_retry = runner:find("post-pipeline revalidation failure fallback", 1, true) ~= nil
local deferral_ready = config_enabled and config_exported and requests_deferral
	and skips_immediate and holds_completion and publishes_after_success and not hidden_retry

-- Execute the shipped RebuildFinal implementation, not a copied model. Each invocation must
-- perform one complete invalidate/passability/buildable sequence; this makes the duplicate's
-- engine-call cost explicit even in the offline regression.
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
local active_stages = deferral_ready
	and { "post-pipeline scheduled revalidation" }
	or { "after last object-grid transaction", "post-pipeline scheduled revalidation" }
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
if expected == 2 then
	print("RED baseline: v936 surface path executes 2 whole-map passability + 2 buildable rebuilds")
end

assert(config_enabled and config_exported and requests_deferral,
	"RED: unit #11 deferral is not enabled in production")
assert(skips_immediate and holds_completion and publishes_after_success,
	"RED: surface completion is not gated on the single canonical rebuild")
assert(not hidden_retry,
	"optimized final rebuild must fail loudly instead of retrying behind a fallback")
print("PASS surface final rebuild deferral: one canonical rebuild before T1, fail-loud")

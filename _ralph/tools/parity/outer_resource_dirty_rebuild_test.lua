-- Production-function regression for ranked optimization unit #5.
-- The terrain writer owns its exact height-cell boxes; this test executes the shipped rebuild
-- helper against representative patch and terminal certificates and proves fail-loud behavior.

local function read(path)
	local file = assert(io.open(path, "rb"))
	local value = file:read("*a")
	file:close()
	return value
end

local terrain_source = read("Code/sbm_terrain_copy.lua")
local map_source = read("Code/sbm_map_generation.lua")

for _, token in ipairs({
	"dirty_height_regions[#dirty_height_regions + 1] = {",
	'source = "patch", kind = patch.kind, q = patch.q, r = patch.r,',
	"x0 = x0, y0 = y0, x1 = x1 + 1, y1 = y1 + 1,",
	"for _, region in ipairs(report.dirty_regions or {}) do",
	"dirty_region_certificate_version = 1,",
	"dirty_region_count = #dirty_height_regions,",
}) do
	assert(terrain_source:find(token, 1, true), "production certificate token missing: " .. token)
end
assert(not map_source:find(
	'SuperBigMap.GenerationGrids.RebuildFinal(\n\t\t\t\t\t\t\t\tmap, "after outer resource terrain preparation")',
	1, true), "preparation still uses whole-map RebuildFinal")
assert(not map_source:find(
	'SuperBigMap.GenerationGrids.RebuildFinal(map,\n\t\t\t\t\t\t\t\t"after outer resource terrain repair "',
	1, true), "repair still uses whole-map RebuildFinal")

local production_block = assert(terrain_source:match(
	"(local function RebuildOuterResourceTerrainRegions.-)\n%-%- Run only after the engine has rebuilt"),
	"production dirty-region rebuild helper not found")

local calls, failures, ticks = {}, {}, 0
local function record(name, value)
	calls[#calls + 1] = { name = name, value = value }
end
local terrain = {
	InvalidateHeight = function(_, region) record("InvalidateHeight", region) end,
	InvalidateType = function(_, region) record("InvalidateType", region) end,
	RebuildPassability = function(_, region) record("RebuildPassability", region) end,
}
local env = setmetatable({
	Global = function(name)
		if name == "terrain" then return terrain end
		if name == "RebuildBuildableGrid" then
			return function(map) record("RebuildBuildableGrid", map) end
		end
		if name == "box" then
			return function(x0, y0, x1, y1)
				return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
			end
		end
		if name == "const" then return { PassTileSize = 100 } end
		error("unexpected Global(" .. tostring(name) .. ")")
	end,
	TerrainSize = function() return 819200, 819200 end,
	GetPreciseTicks = function() ticks = ticks + 1 return ticks end,
	LoadingBegin = function() return true end,
	LoadingEnd = function() end,
	OptimizationFailure = function(unit, reason)
		failures[#failures + 1] = { unit = unit, reason = reason }
	end,
}, { __index = _G })
local rebuild = assert(load(production_block
	.. "\nreturn RebuildOuterResourceTerrainRegions", "production-dirty-rebuild", "t", env))()

local map = { mapdata = { Environment = "Surface" } }
local certificate = {
	dirty_region_certificate_version = 1,
	dirty_region_count = 2,
	dirty_height_regions = {
		{ source = "patch", kind = "extractor", q = 1, r = 2,
			x0 = 300, y0 = 3576, x1 = 1341, y1 = 4617 },
		{ source = "terminal", side = "left", x0 = 0, y0 = 180, x1 = 3, y1 = 507 },
	},
	height_grid_width = 8192, height_grid_height = 8192,
	height_tile_size = 100, map_width = 819200, map_height = 819200,
}
local ok, report = rebuild(map, certificate, "candidate regression")
assert(ok == true and report.regions == 2 and report.dependency_margin == 200)
assert(#failures == 0, "valid certificate recorded an optimization failure")
assert(#calls == 7, "unexpected rebuild call count: " .. tostring(#calls))

local expected = {
	{ x0 = 29800, y0 = 357400, x1 = 134300, y1 = 461900 },
	{ x0 = 0, y0 = 17800, x1 = 500, y1 = 50900 },
}
for region_index = 1, 2 do
	for call_offset, name in ipairs({ "InvalidateHeight", "InvalidateType", "RebuildPassability" }) do
		local call = calls[(region_index - 1) * 3 + call_offset]
		assert(call.name == name, "unexpected call order")
		for _, field in ipairs({ "x0", "y0", "x1", "y1" }) do
			assert(call.value[field] == expected[region_index][field],
				string.format("region %d %s mismatch", region_index, field))
		end
		assert(not (call.value.x0 == 0 and call.value.y0 == 0
			and call.value.x1 == 819200 and call.value.y1 == 819200),
			"intermediate rebuild unexpectedly used a whole-map box")
	end
end
assert(calls[7].name == "RebuildBuildableGrid" and calls[7].value == map,
	"full buildable rebuild missing")
assert(map.SuperBigMapRevalidationRebuiltGrids == true)

calls, failures = {}, {}
local invalid = {
	dirty_region_certificate_version = 1, dirty_region_count = 0,
	dirty_height_regions = {}, height_grid_width = 8192, height_grid_height = 8192,
	height_tile_size = 100, map_width = 819200, map_height = 819200,
}
local invalid_ok, invalid_error = pcall(rebuild, map, invalid, "invalid regression")
assert(invalid_ok == false and tostring(invalid_error):find("certificate count is invalid", 1, true),
	"invalid certificate did not fail loudly")
assert(#failures == 1 and failures[1].unit == "outer resource terrain dirty-region rebuild",
	"invalid certificate did not record exactly one optimization failure")
assert(#calls == 0, "invalid certificate performed a partial rebuild")

print("PASS outer resource dirty-region rebuild: patch + terminal bounds, margin, full buildable, fail-loud")

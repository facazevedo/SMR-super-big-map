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

local prepare_at = assert(map_source:find('"surface prepare outer resource terrain"', 1, true))
local rebuild_at = assert(map_source:find(
	"TerrainCopy.RebuildOuterResourceTerrainRegions(map, resource_terrain_stats", prepare_at, true))
local audit_at = assert(map_source:find("TerrainCopy.AuditOuterResourceTerrain(map)", rebuild_at, true))
local anomaly_at = assert(map_source:find('"surface top-up anomalies"', audit_at, true))
local effect_at = assert(map_source:find('"surface top-up effect deposits"', anomaly_at, true))
assert(prepare_at < rebuild_at and rebuild_at < audit_at
	and audit_at < anomaly_at and anomaly_at < effect_at,
	"scoped resource-terrain rebuild/audit must precede anomaly and effect placement")

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

-- A resource patch inside its rocket pad must not request a second native
-- pass. Partially overlapping boxes may merge only when scan area decreases.
calls, failures = {}, {}
certificate.dirty_height_regions={
 {source='patch',x0=100,y0=100,x1=200,y1=200},
 {source='patch',x0=125,y0=125,x1=175,y1=175},
 {source='patch',x0=150,y0=100,x1=250,y1=200},
 {source='patch',x0=700,y0=700,x1=710,y1=710},
}
certificate.dirty_region_count=4
ok,report=rebuild(map,certificate,'overlapping pads')
assert(ok and report.source_regions==4 and report.regions==2 and #calls==7)
assert(calls[1].value.x0==9800 and calls[1].value.y0==9800
 and calls[1].value.x1==25200 and calls[1].value.y1==20200,'merged coverage differs')
local original_area,merged_area=0,0
for _,r in ipairs(certificate.dirty_height_regions) do original_area=original_area+(r.x1-r.x0+4)*(r.y1-r.y0+4)*10000 end
for i=1,#calls-1,3 do local r=calls[i].value;merged_area=merged_area+(r.x1-r.x0)*(r.y1-r.y0) end
assert(merged_area<=original_area,'coalescing increased native scan area')
for _,r in ipairs(certificate.dirty_height_regions) do
 local covered=false
 for i=1,#calls-1,3 do local b=calls[i].value
  if b.x0<=r.x0*100-200 and b.y0<=r.y0*100-200 and b.x1>=r.x1*100+200 and b.y1>=r.y1*100+200 then covered=true end
 end
 assert(covered,'coalescing dropped a certified cell or dependency margin')
end
calls,failures={},{}
certificate.dirty_height_regions={
 {source='patch',x0=100,y0=100,x1=200,y1=200},
 {source='patch',x0=125,y0=125,x1=225,y1=225},
}
certificate.dirty_region_count=2
ok,report=rebuild(map,certificate,'non-rectangular overlap')
assert(ok and report.regions==2,'bounding-box overscan changed the certified union')
print("PASS outer resource dirty-region rebuild: exact union, no overscan, full buildable, fail-loud")

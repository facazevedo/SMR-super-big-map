-- Detached, read-only post-T1 probe for v972's bounded direct-ring Surface passage pads.
-- The returned flat scalar table is the only result; no globals or files are written.
local failures = {}
local counts = {
	pads = 0, depth0_calls = 0, depth0_accepts = 0, contrary = 0,
	native_failures = 0, world_hex_mismatches = 0, ring_failures = 0,
	inner_failures = 0, enrichment_pairs = 0, enrichment_spacing_failures = 0,
	rocket_pads = 0, rocket_pairs = 0, rocket_spacing_failures = 0,
}
local function fail(reason) failures[#failures + 1] = tostring(reason) end
local function axial(q1, r1, q2, r2)
	local dq, dr = q1 - q2, r1 - r2
	return math.max(math.abs(dq), math.abs(dr), math.abs(dq + dr))
end

local surface = type(MainMap) == "table" and MainMap or nil
if not surface or not surface.mapdata or surface.mapdata.Environment ~= "Surface" then
	local maps = type(Maps) == "table" and Maps or {}
	for _, map in pairs(maps) do
		if map and map.mapdata and map.mapdata.Environment == "Surface" then
			surface = map
			break
		end
	end
end
local report = surface and surface.SuperBigMapOuterPassageTerrainReport
local pads = surface and surface.SuperBigMapOuterPassagePads
local rockets = surface and surface.SuperBigMapOuterResourceRocketPads
if not surface or not surface.buildable or not surface.object_hex_grid then
	fail("initialized Surface grids unavailable")
end
if type(report) ~= "table" or report.passage_only ~= true
	or report.passage_pads_used ~= true or report.passage_pad_replay_exact ~= true
	or report.passage_pad_direct_outer_sampling ~= true
	or tonumber(report.passage_pad_attempt_cap_per_site) ~= 32
	or tonumber(report.passage_pad_viable_target_per_site) ~= 4
	or (tonumber(report.passage_pad_attempts) or 65) < 8
	or (tonumber(report.passage_pad_attempts) or 65) > 64
	or tonumber(report.passage_pad_viable) ~= 8
	or tonumber(report.passage_pad_replay_attempts) ~= tonumber(report.passage_pad_attempts)
	or tonumber(report.passage_pad_replay_viable) ~= 8
	or (tonumber(report.passage_pad_plan_ms) or 2001) < 0
	or (tonumber(report.passage_pad_plan_ms) or 2001) > 2000
	or report.passage_pad_inner_no_write ~= true
	or report.passage_pad_all_changed_cells_outer ~= true
	or report.native_raster_used ~= true or report.native_raster_fallback == true
	or tostring(report.error or "") ~= "" then
	fail("v972 terrain report is not an accepted bounded native two-pad certificate")
end
if type(pads) ~= "table" or #pads ~= 2 then fail("passage pad count is not two") end
if type(rockets) ~= "table" or #rockets ~= 6 then fail("resource rocket-pad count is not six") end
counts.pads = type(pads) == "table" and #pads or 0
counts.rocket_pads = type(rockets) == "table" and #rockets or 0

local required_apis = {
	HexGridFindBuildable = type(HexGridFindBuildable) == "function" and HexGridFindBuildable,
	ValidateEachShapeHexPos = type(ValidateEachShapeHexPos) == "function"
		and ValidateEachShapeHexPos,
	GetExtendedSpawnShape = type(GetExtendedSpawnShape) == "function" and GetExtendedSpawnShape,
	buildUnbuildableZ = type(buildUnbuildableZ) == "function" and buildUnbuildableZ,
	WorldToHex = type(WorldToHex) == "function" and WorldToHex,
	HexToWorld = type(HexToWorld) == "function" and HexToWorld,
	point = type(point) == "function" and point,
	IsKindOf = type(IsKindOf) == "function" and IsKindOf,
}
for name, value in pairs(required_apis) do
	if not value then fail(name .. " unavailable") end
end
local shape, unbuildable_z
if #failures == 0 then
	local shape_ok, shape_value = pcall(required_apis.GetExtendedSpawnShape, "Elevator")
	local sentinel_ok, sentinel = pcall(required_apis.buildUnbuildableZ)
	if shape_ok and type(shape_value) == "table" and #shape_value > 0 then
		shape = shape_value
	else
		fail("Elevator shape unavailable")
	end
	if sentinel_ok and type(sentinel) == "number" then
		unbuildable_z = sentinel
	else
		fail("unbuildable sentinel unavailable")
	end
end

local concrete, geysers, enrichments = {}, {}, {}
if surface and type(surface.MapForEach) == "function" and required_apis.WorldToHex
	and required_apis.point then
	local scan_ok = pcall(surface.MapForEach, surface, "map", "DepositMarker", function(marker)
		local position = marker:GetPos()
		local x, y = position:xy()
		local hex_ok, q, r = pcall(required_apis.WorldToHex, required_apis.point(x, y))
		if hex_ok and type(q) == "number" and type(r) == "number" then
			enrichments[#enrichments + 1] = { q = q, r = r }
		end
		if marker.resource == "Concrete"
			and required_apis.IsKindOf(marker, "TerrainDepositMarker")
			and type(marker.GetObstructionRadius) == "function" then
			local radius_ok, radius = pcall(marker.GetObstructionRadius, marker)
			if radius_ok and type(radius) == "number" then
				concrete[#concrete + 1] = { marker = marker, radius = radius }
			end
		end
	end)
	if not scan_ok then fail("DepositMarker enumeration failed") end
	local feature_ok = pcall(surface.MapForEach, surface, "map", "PrefabFeatureMarker",
		function(marker)
			local feature = type(PrefabFeaturePresets) == "table"
				and PrefabFeaturePresets[marker.FeatureType]
			if type(feature) ~= "table" or type(feature.chars) ~= "table" then return end
			for _, name in ipairs(feature.chars) do
				local preset = type(PrefabFeatureCharPresets) == "table"
					and PrefabFeatureCharPresets[name]
				if preset and required_apis.IsKindOf(
					preset, "PrefabFeatureCharPreset_Geyser") then
					if type(marker.FeatureRadius) == "number" then
						geysers[#geysers + 1] = { marker = marker, radius = marker.FeatureRadius }
					end
					return
				end
			end
		end)
	if not feature_ok then fail("PrefabFeatureMarker enumeration failed") end
else
	fail("Surface marker enumeration APIs unavailable")
end

local function deposit_clear(q, r)
	local x, y = required_apis.HexToWorld(q, r)
	local position = required_apis.point(x, y)
	for _, entry in ipairs(concrete) do
		if position:Dist2D(entry.marker) <= entry.radius then return false end
	end
	for _, entry in ipairs(geysers) do
		if position:Dist2D(entry.marker) <= entry.radius then return false end
	end
	return true
end

local function validate_pad(pad)
	counts.depth0_calls = counts.depth0_calls + 1
	local original_z = false
	local function shape_filter(q, r)
		local z = surface.buildable:GetZ(q, r)
		original_z = original_z or z
		if z == unbuildable_z or z ~= original_z then return false end
		local obstructions = surface.object_hex_grid:GetBuildObstructions(q, r)
		return #obstructions == 0 and deposit_clear(q, r)
	end
	local function continue_check(q, r)
		local x, y = required_apis.HexToWorld(q, r)
		return required_apis.ValidateEachShapeHexPos(shape,
			required_apis.point(x, y), pad.angle, shape_filter) ~= true
	end
	local call_ok, q, r, depth = pcall(required_apis.HexGridFindBuildable,
		pad.q, pad.r, surface.object_hex_grid, surface.buildable.z_grid,
		unbuildable_z, continue_check, 0)
	if not call_ok then
		counts.native_failures = counts.native_failures + 1
		return
	end
	if q == pad.q and r == pad.r and depth == 0 and type(original_z) == "number" then
		counts.depth0_accepts = counts.depth0_accepts + 1
	elseif q ~= nil or r ~= nil or depth ~= nil then
		counts.contrary = counts.contrary + 1
	end
end

if #failures == 0 then
	local size_ok, map_w, map_h = pcall(surface.GetMapSize, surface)
	map_h = map_h or map_w
	if not size_ok or type(map_w) ~= "number" or type(map_h) ~= "number" then
		fail("Surface dimensions unavailable")
	else
		local band_x, band_y = map_w / 10, map_h / 10
		local visit = tonumber(report.passage_pad_conservative_visit_radius_world) or -1
		for index, pad in ipairs(pads) do
			local world_ok, x, y = pcall(required_apis.HexToWorld, pad.q, pad.r)
			if not world_ok or x ~= pad.x or y ~= pad.y or tonumber(pad.index) ~= index then
				counts.world_hex_mismatches = counts.world_hex_mismatches + 1
			end
			if not (pad.x < band_x or pad.y < band_y
				or pad.x >= map_w - band_x or pad.y >= map_h - band_y) then
				counts.ring_failures = counts.ring_failures + 1
			end
			local nearest_x = math.max(band_x, math.min(map_w - band_x, pad.x))
			local nearest_y = math.max(band_y, math.min(map_h - band_y, pad.y))
			local dx, dy = pad.x - nearest_x, pad.y - nearest_y
			if visit <= 0 or pad.x < visit or pad.y < visit or pad.x >= map_w - visit
				or pad.y >= map_h - visit or math.sqrt(dx * dx + dy * dy) <= visit then
				counts.inner_failures = counts.inner_failures + 1
			end
			for _, entry in ipairs(enrichments) do
				counts.enrichment_pairs = counts.enrichment_pairs + 1
				if axial(pad.q, pad.r, entry.q, entry.r) < 3 then
					counts.enrichment_spacing_failures = counts.enrichment_spacing_failures + 1
				end
			end
			for _, rocket in ipairs(rockets) do
				counts.rocket_pairs = counts.rocket_pairs + 1
				local required = (tonumber(pad.required_core_radius) or 0)
					+ (tonumber(rocket.shape_radius) or 0) + 4
				if type(rocket.q) ~= "number" or type(rocket.r) ~= "number"
					or axial(pad.q, pad.r, rocket.q, rocket.r) < required then
					counts.rocket_spacing_failures = counts.rocket_spacing_failures + 1
				end
			end
			validate_pad(pad)
		end
	end
end

if counts.depth0_accepts ~= 2 then fail("two exact-center pad validations did not pass") end
if counts.contrary > 0 then fail("contrary depth-zero tuple observed") end
if counts.world_hex_mismatches + counts.ring_failures + counts.inner_failures
	+ counts.enrichment_spacing_failures + counts.rocket_spacing_failures > 0 then
	fail("outer passage-pad geometry/spacing certificate failed")
end
local ok = #failures == 0 and counts.pads == 2 and counts.rocket_pads == 6
	and counts.depth0_calls == 2 and counts.depth0_accepts == 2
	and counts.native_failures == 0 and counts.contrary == 0
return {
	schema = "smr.ralph.v972.direct-outer-passage-pad-engine-probe.v1",
	ok = ok, acceptance_failure_count = #failures,
	acceptance_failures = table.concat(failures, "|"), pads = counts.pads,
	rocket_pads = counts.rocket_pads, depth0_calls = counts.depth0_calls,
	depth0_accepts = counts.depth0_accepts, native_failures = counts.native_failures,
	contrary_tuples = counts.contrary, world_hex_mismatches = counts.world_hex_mismatches,
	ring_failures = counts.ring_failures, inner_failures = counts.inner_failures,
	enrichment_pairs = counts.enrichment_pairs,
	enrichment_spacing_failures = counts.enrichment_spacing_failures,
	rocket_pairs = counts.rocket_pairs, rocket_spacing_failures = counts.rocket_spacing_failures,
	plan_attempts = tonumber(report and report.passage_pad_attempts) or -1,
	plan_viable = tonumber(report and report.passage_pad_viable) or -1,
	replay_attempts = tonumber(report and report.passage_pad_replay_attempts) or -1,
	plan_ms = tonumber(report and report.passage_pad_plan_ms) or -1,
	unbounded_search_calls = 0,
}

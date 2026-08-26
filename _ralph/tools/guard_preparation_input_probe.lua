-- Diagnostic-only pre-call input capture for PrepareOuterResourceTerrain.
--
-- Load the ordinary determinism_capture_probe.lua first, then load this file before submitting
-- expanded generation.  This probe decorates the already-armed post_object_transform callback.
-- After that accepted boundary has been captured, it restores the ordinary callback and installs
-- a temporary table-level PrepareOuterResourceTerrain wrapper.  The wrapper snapshots every input
-- needed to reconstruct resource readiness and protected-guard order immediately before each
-- initial/repair call, then invokes the untouched original function.  Probe-enabled output and
-- timing are diagnostic only.

local out_base = rawget(_G, "g_SbmGuardInputCaptureOutBase")
local identity = rawget(_G, "g_SbmGuardInputCaptureIdentity")
if type(out_base) ~= "string" or out_base == "" then
	error("g_SbmGuardInputCaptureOutBase must be a fresh non-empty path")
end
if type(identity) ~= "table" then error("g_SbmGuardInputCaptureIdentity must be a table") end

local required_identity = {
	"coordinate", "preset", "source_commit", "source_version", "terrain_source_sha256",
	"scenario_input_sha256", "task_sha256",
}
for _, key in ipairs(required_identity) do
	local value = identity[key]
	if type(value) ~= "string" or value == "" or string.find(value, "[\t\r\n]") then
		error("invalid guard input identity " .. key)
	end
end
if identity.coordinate ~= "14N134W" or identity.preset ~= "RoughTerrain" then
	error("guard input probe is pinned to 14N134W RoughTerrain")
end

local mod
for _, candidate in ipairs(ModsLoaded or empty_table) do
	if candidate and candidate.id == "SuperBigMap" then mod = candidate break end
end
local SBM = (mod and type(mod.env) == "table" and mod.env.SuperBigMap)
	or rawget(_G, "SuperBigMap")
local state = type(SBM) == "table" and SBM.State or nil
local terrain_copy = type(SBM) == "table" and SBM.TerrainCopy or nil
local engine = type(SBM) == "table" and SBM.Engine or nil
local capture = type(state) == "table" and state.test_determinism_capture or nil
if type(terrain_copy) ~= "table"
	or type(terrain_copy.PrepareOuterResourceTerrain) ~= "function" then
	error("table-level PrepareOuterResourceTerrain export is unavailable")
end
if type(capture) ~= "table" or type(capture.hook) ~= "function" then
	error("ordinary determinism capture must be armed before guard input probe")
end
if type(capture.counts) ~= "table" or next(capture.counts) ~= nil then
	error("guard input probe must be armed before the first determinism checkpoint")
end
for _, name in ipairs({ "AsyncStringToFile", "GridWriteStr", "WorldToHex", "HexToWorld",
	"point", "GetExtendedSpawnShape", "buildUnbuildableZ" }) do
	if type(rawget(_G, name)) ~= "function" then error(name .. " is unavailable") end
end
if type(terrain) ~= "table" or type(terrain.GetHeightGrid) ~= "function"
	or type(terrain.GetPassGridsCount) ~= "function"
	or type(terrain.GetPassGrid) ~= "function" or type(terrain.IsPassable) ~= "function" then
	error("required terrain capture APIs are unavailable")
end
if type(engine) ~= "table" or type(engine.IsKindOf) ~= "function"
	or type(engine.ObjectPos) ~= "function" then
	error("SuperBigMap engine helpers are unavailable")
end

local original_capture_hook = capture.hook
local original_prepare = terrain_copy.PrepareOuterResourceTerrain
local PackValues = table.pack or function(...) return { n = select("#", ...), ... } end
local Unpack = table.unpack or unpack
local call_count, expected_map, wrapper_installed = 0, nil, false
local call_records = {}

local function write(path, value)
	local err = AsyncStringToFile(path, value)
	if err then error("guard input write failed " .. path .. ": " .. tostring(err)) end
end

local function clean(value, label, allow_empty)
	if value == nil then return "nil" end
	value = tostring(value)
	if (not allow_empty and value == "") or string.find(value, "[\t\r\n]") then
		error("invalid guard input " .. tostring(label))
	end
	return value
end

local function bool(value)
	return value == true and "true" or "false"
end

local function point_xy(pos)
	if not pos then return nil, nil end
	if type(pos.xy) == "function" then
		local ok, x, y = pcall(pos.xy, pos)
		if ok then return x, y end
	end
	if type(pos.x) == "number" and type(pos.y) == "number" then return pos.x, pos.y end
	return nil, nil
end

local function cfg_number(key, default)
	local value = type(SBM.Config) == "table" and SBM.Config[key] or nil
	return type(value) == "number" and value or default
end

local function grid_blob(grid, label)
	if not grid then error(label .. " grid is unavailable") end
	local blob, err = GridWriteStr(grid)
	if err or type(blob) ~= "string" then
		error("GridWriteStr failed for " .. label .. ": " .. tostring(err))
	end
	return blob
end

local function passability_blob(map)
	local ok_count, count = pcall(terrain.GetPassGridsCount, map)
	count = ok_count and tonumber(count) or nil
	if not count or count < 1 or count > 8 then
		error("invalid pass-grid count: " .. tostring(count))
	end
	local chunks = { "smr.ralph.passability.bundle.v1\n", tostring(count) .. "\n" }
	for index = 0, count - 1 do
		local ok_grid, grid = pcall(terrain.GetPassGrid, map, index)
		if not ok_grid or not grid then error("pass grid unavailable at " .. tostring(index)) end
		local blob = grid_blob(grid, "passability " .. tostring(index))
		chunks[#chunks + 1] = tostring(index) .. ":" .. tostring(#blob) .. "\n"
		chunks[#chunks + 1] = blob
	end
	return table.concat(chunks)
end

local function marker_identity(marker, traversal_index)
	local handle = marker and (marker.handle or marker.Handle)
	if type(handle) ~= "number" and type(handle) ~= "string" then handle = "" end
	return table.concat({
		"m", tostring(traversal_index), clean(handle, "marker handle", true),
		clean(marker and marker.class, "marker class", true),
		clean(marker and marker.SuperBigMapNativeSourceClass, "native source class", true),
		clean(marker and marker.SuperBigMapNativeSourceX, "native source x", true),
		clean(marker and marker.SuperBigMapNativeSourceY, "native source y", true),
		clean(marker and marker.SuperBigMapNativeSourceZ, "native source z", true),
	}, ":")
end

local function shape_offsets(template, extension)
	local ok, shape = pcall(GetExtendedSpawnShape, template, extension)
	if not ok or type(shape) ~= "table" or #shape == 0 then return {} end
	local offsets = {}
	for _, shape_pt in ipairs(shape) do
		local dq, dr = point_xy(shape_pt)
		if type(dq) == "number" and type(dr) == "number" then
			offsets[#offsets + 1] = { math.floor(dq + 0.5), math.floor(dr + 0.5) }
		end
	end
	return offsets
end

local function snapshot(call_index, map)
	if map ~= expected_map then error("PrepareOuterResourceTerrain received an unexpected map") end
	local mapdata = map and map.mapdata
	if type(mapdata) ~= "table" or mapdata.Environment ~= "Surface"
		or type(map.MapForEach) ~= "function" then
		error("guard input snapshot requires the expected surface map")
	end
	local height_grid = terrain.GetHeightGrid(map)
	local buildable_grid = map.buildable and map.buildable.z_grid
	local height_blob = grid_blob(height_grid, "height")
	local pass_blob = passability_blob(map)
	local buildable_blob = grid_blob(buildable_grid, "buildable")

	local const_tbl = rawget(_G, "const")
	local height_tile = type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize) or nil
	local hex_size = type(const_tbl) == "table" and tonumber(const_tbl.HexSize) or nil
	if not height_tile or height_tile <= 0 or not hex_size or hex_size <= 0 then
		error("height/hex constants are unavailable")
	end
	local map_w = type(mapdata.Width) == "number" and mapdata.Width * height_tile or nil
	local map_h = type(mapdata.Height) == "number" and mapdata.Height * height_tile or nil
	if not map_w or not map_h or map_w <= 0 or map_h <= 0 then
		error("surface map dimensions are unavailable")
	end
	local cells_per_hex = math.max(1, (hex_size + 0.0) / height_tile)
	local ring_sectors = math.max(0, math.min(20,
		math.floor(cfg_number("MOUNTAIN_BASE_APRON_OUTER_RING_SECTORS", 2))))
	local band_x, band_y = map_w * ring_sectors / 20, map_h * ring_sectors / 20
	local function in_outer_band(x, y)
		return type(x) == "number" and type(y) == "number" and x >= 0 and y >= 0
			and x < map_w and y < map_h
			and (x < band_x or y < band_y or x >= map_w - band_x or y >= map_h - band_y)
	end
	local function world_xy(q, r)
		local ok, x, y = pcall(HexToWorld, q, r)
		if ok and type(x) == "number" and type(y) == "number" then return x, y end
		return nil, nil
	end
	local function hex_passable(q, r)
		local x, y = world_xy(q, r)
		if not x then return false end
		local ok, value = pcall(terrain.IsPassable, map, point(x, y))
		return ok and value == true
	end
	local ok_unbuildable, unbuildable = pcall(buildUnbuildableZ)
	local buildable_get_z = map.buildable and map.buildable.GetZ
	local function offsets_ready(q, r, offsets, require_level)
		local level
		for _, offset in ipairs(offsets) do
			local hq, hr = q + offset[1], r + offset[2]
			if not hex_passable(hq, hr) then return false end
			if require_level then
				if type(buildable_get_z) ~= "function" or not ok_unbuildable
					or type(unbuildable) ~= "number" then return false end
				local ok_z, z = pcall(buildable_get_z, map.buildable, hq, hr)
				if not ok_z or type(z) ~= "number" or z == unbuildable then return false end
				if level == nil then level = z elseif z ~= level then return false end
			end
		end
		return #offsets > 0
	end
	local function disk_ready(q, r, radius, require_level)
		local offsets = {}
		for dq = -radius, radius do
			for dr = -radius, radius do
				if math.max(math.abs(dq), math.abs(dr), math.abs(dq + dr)) <= radius then
					offsets[#offsets + 1] = { dq, dr }
				end
			end
		end
		return offsets_ready(q, r, offsets, require_level)
	end
	local function offsets_radius(offsets, fallback)
		local radius = fallback or 0
		for _, offset in ipairs(offsets) do
			radius = math.max(radius, math.max(math.abs(offset[1]), math.abs(offset[2]),
				math.abs(offset[1] + offset[2])))
		end
		return radius
	end
	local function offsets_world_radius(q, r, offsets, fallback)
		local cx, cy = world_xy(q, r)
		if not cx then return fallback or 0 end
		local radius = fallback or 0
		for _, offset in ipairs(offsets) do
			local x, y = world_xy(q + offset[1], r + offset[2])
			if x then radius = math.max(radius,
				math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) / hex_size) end
		end
		return radius
	end

	local prior_sites = type(map.SuperBigMapOuterResourceTerrainSites) == "table"
		and map.SuperBigMapOuterResourceTerrainSites or {}
	local retry_failed_sites = {}
	for _, previous in ipairs(prior_sites) do
		if previous and previous.verified ~= true and type(previous.q) == "number"
			and type(previous.r) == "number" then
			local key = tostring(previous.kind) .. "|" .. tostring(previous.resource)
				.. "|" .. tostring(previous.q) .. "|" .. tostring(previous.r)
			retry_failed_sites[key] = true
		end
	end

	local resources, marker_ids = {}, {}
	local traversal_index = 0
	local ok_each, each_error = pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not marker then return end
		local surface = engine.IsKindOf(marker, "SurfaceDepositMarker")
		local extractor = engine.IsKindOf(marker, "SubsurfaceDepositMarker")
			or engine.IsKindOf(marker, "TerrainDepositMarker")
		if not surface and not extractor then return end
		local pos = engine.ObjectPos(marker)
		local x, y = point_xy(pos)
		if not in_outer_band(x, y) then return end
		local ok_hex, q, r = pcall(WorldToHex, point(x, y))
		if not ok_hex or type(q) ~= "number" or type(r) ~= "number" then return end
		traversal_index = traversal_index + 1
		local kind = extractor and "extractor" or "surface"
		local resource = tostring(marker.resource or marker.class or "?")
		local id = marker_identity(marker, traversal_index)
		marker_ids[marker] = id
		resources[#resources + 1] = {
			marker = marker, id = id, traversal_index = traversal_index,
			x = x, y = y, q = q, r = r, kind = kind, resource = resource,
			cluster_plan = marker.SuperBigMapResourceClusterPlan,
			cluster_strength = marker.SuperBigMapResourceClusterStrength,
			cluster_resource_target = marker.SuperBigMapResourceClusterResourceTarget,
			cluster_extractor_target = marker.SuperBigMapResourceClusterExtractorTarget,
			cluster_anomaly_capacity = marker.SuperBigMapResourceClusterAnomalyCapacity,
			cluster_reward_capacity = marker.SuperBigMapResourceClusterRewardCapacity,
			cluster_anchor = marker.SuperBigMapResourceClusterAnchor,
			cluster_premium = marker.SuperBigMapResourceClusterPremium,
		}
	end)
	if not ok_each then error("DepositMarker traversal failed: " .. tostring(each_error)) end
	table.sort(resources, function(a, b)
		if a.q == b.q then
			if a.r == b.r then return a.resource < b.resource end
			return a.r < b.r
		end
		return a.q < b.q
	end)

	local extractor_core = math.max(2,
		cfg_number("OUTER_RESOURCE_EXTRACTOR_CORE_RADIUS_HEXES", 3))
	local surface_core = math.max(1,
		cfg_number("OUTER_RESOURCE_SURFACE_CORE_RADIUS_HEXES", 1))
	local templates = {
		Concrete = "RegolithExtractor", Metals = "MetalsExtractor",
		PreciousMetals = "PreciousMetalsExtractor", Water = "WaterExtractor",
	}
	local shape_cache = {}
	for sorted_index, entry in ipairs(resources) do
		entry.sorted_index = sorted_index
		local offsets = {}
		local template = templates[entry.resource]
		if entry.kind == "extractor" and template then
			if not shape_cache[template] then shape_cache[template] = shape_offsets(template, 0) end
			offsets = shape_cache[template]
		end
		local radius = entry.kind == "extractor"
			and offsets_radius(offsets, math.floor(extractor_core + 0.5)) or 0
		local world_radius = entry.kind == "extractor"
			and offsets_world_radius(entry.q, entry.r, offsets, radius) or 0
		local required_core = entry.kind == "extractor"
			and math.max(extractor_core, math.ceil(world_radius + 5)) or surface_core + 2
		local key = entry.kind .. "|" .. entry.resource .. "|" .. tostring(entry.q)
			.. "|" .. tostring(entry.r)
		entry.force_retry = retry_failed_sites[key] == true
		entry.grid_ready = #offsets > 0
			and offsets_ready(entry.q, entry.r, offsets, true)
			or disk_ready(entry.q, entry.r, radius, entry.kind == "extractor")
		entry.ready = entry.grid_ready and not entry.force_retry
		entry.core_radius = radius
		entry.world_core_radius = world_radius
		entry.required_core_radius = required_core
		entry.guard_radius_cells = required_core * cells_per_hex
		entry.extractor_offsets = offsets
	end

	local call_tag = string.format("-call%02d", call_index)
	local height_path = out_base .. call_tag .. "-height.bin"
	local passability_path = out_base .. call_tag .. "-passability.bin"
	local buildable_path = out_base .. call_tag .. "-buildable.bin"
	local metadata_path = out_base .. call_tag .. "-metadata.tsv"
	write(height_path, height_blob)
	write(passability_path, pass_blob)
	write(buildable_path, buildable_blob)
	local lines = { "SCHEMA\tsmr.ralph.guard_preparation_input.v1" }
	for _, key in ipairs(required_identity) do
		lines[#lines + 1] = table.concat({ "IDENTITY", key, identity[key] }, "\t")
	end
	lines[#lines + 1] = table.concat({ "CALL", tostring(call_index), tostring(map_w),
		tostring(map_h), tostring(height_tile), tostring(hex_size), tostring(cells_per_hex),
		tostring(ring_sectors), height_path, passability_path, buildable_path }, "\t")
	for previous_index, previous in ipairs(prior_sites) do
		lines[#lines + 1] = table.concat({
			"PRIOR", tostring(previous_index), clean(marker_ids[previous.marker], "prior marker", true),
			clean(previous.kind, "prior kind", true), clean(previous.resource, "prior resource", true),
			clean(previous.q, "prior q", true), clean(previous.r, "prior r", true),
			bool(previous.verified), bool(previous.ready_before), bool(previous.modified),
		}, "\t")
	end
	for _, entry in ipairs(resources) do
		local offset_rows = {}
		for _, offset in ipairs(entry.extractor_offsets) do
			offset_rows[#offset_rows + 1] = tostring(offset[1]) .. "," .. tostring(offset[2])
		end
		lines[#lines + 1] = table.concat({
			"RESOURCE", tostring(entry.sorted_index), tostring(entry.traversal_index), entry.id,
			entry.kind, entry.resource, tostring(entry.x), tostring(entry.y), tostring(entry.q),
			tostring(entry.r), bool(entry.grid_ready), bool(entry.force_retry), bool(entry.ready),
			tostring(entry.core_radius), tostring(entry.world_core_radius),
			tostring(entry.required_core_radius), tostring(entry.guard_radius_cells),
			clean(entry.cluster_plan, "cluster plan", true),
			clean(entry.cluster_strength, "cluster strength", true),
			clean(entry.cluster_resource_target, "cluster resource target", true),
			clean(entry.cluster_extractor_target, "cluster extractor target", true),
			clean(entry.cluster_anomaly_capacity, "cluster anomaly capacity", true),
			clean(entry.cluster_reward_capacity, "cluster reward capacity", true),
			bool(entry.cluster_anchor), bool(entry.cluster_premium), table.concat(offset_rows, ";"),
		}, "\t")
	end
	write(metadata_path, table.concat(lines, "\n") .. "\n")
	call_records[#call_records + 1] = {
		index = call_index, height = height_path, passability = passability_path,
		buildable = buildable_path, metadata = metadata_path,
		resources = #resources, prior_sites = #prior_sites,
	}
end

local wrapped_prepare
local function restore_prepare(reason)
	if not wrapper_installed then return true end
	if terrain_copy.PrepareOuterResourceTerrain ~= wrapped_prepare then
		error("cannot restore PrepareOuterResourceTerrain after " .. tostring(reason)
			.. ": table export changed unexpectedly")
	end
	terrain_copy.PrepareOuterResourceTerrain = original_prepare
	wrapper_installed = false
	return true
end

wrapped_prepare = function(map)
	if not wrapper_installed or terrain_copy.PrepareOuterResourceTerrain ~= wrapped_prepare then
		error("guard input wrapper entered outside its armed lifecycle")
	end
	call_count = call_count + 1
	if call_count > 3 then
		restore_prepare("call bound exceeded")
		error("PrepareOuterResourceTerrain exceeded initial plus two repairs")
	end
	rawset(_G, "g_SbmGuardInputCaptureStatus", "capturing_call_" .. tostring(call_count))
	local ok_snapshot, snapshot_error = xpcall(function()
		snapshot(call_count, map)
	end, debug.traceback)
	if not ok_snapshot then
		pcall(restore_prepare, "snapshot failure")
		rawset(_G, "g_SbmGuardInputCaptureError", tostring(snapshot_error))
		rawset(_G, "g_SbmGuardInputCaptureStatus", "error")
		error(snapshot_error)
	end
	local results = PackValues(pcall(original_prepare, map))
	if results[1] ~= true then
		pcall(restore_prepare, "original failure")
		rawset(_G, "g_SbmGuardInputCaptureError", tostring(results[2]))
		rawset(_G, "g_SbmGuardInputCaptureStatus", "error")
		error(results[2])
	end
	if call_count == 3 then restore_prepare("maximum legal call completed") end
	rawset(_G, "g_SbmGuardInputCaptureStatus", wrapper_installed and "armed" or "captured")
	return Unpack(results, 2, results.n)
end

local decorated_hook
decorated_hook = function(stage, map, details)
	local result = original_capture_hook(stage, map, details)
	if result ~= true then error("ordinary determinism hook did not return true") end
	if stage == "post_object_transform" then
		if wrapper_installed or expected_map then error("post_object_transform repeated") end
		expected_map = map
		terrain_copy.PrepareOuterResourceTerrain = wrapped_prepare
		wrapper_installed = true
		if capture.hook ~= decorated_hook then error("determinism hook changed during decoration") end
		capture.hook = original_capture_hook
		rawset(_G, "g_SbmGuardInputCaptureStatus", "armed")
	end
	return true
end
capture.hook = decorated_hook

rawset(_G, "g_SbmGuardInputCaptureStatus", "waiting_post_object_transform")
rawset(_G, "g_SbmGuardInputCaptureError", false)
rawset(_G, "g_SbmGuardInputCaptureFinalize", function()
	if capture.hook == decorated_hook then
		capture.hook = original_capture_hook
		error("guard input finalizer ran before post_object_transform")
	end
	if capture.hook ~= original_capture_hook then
		error("ordinary determinism hook was not restored")
	end
	if call_count < 1 or call_count > 3 then
		error("guard input finalizer requires one to three preparation calls")
	end
	restore_prepare("finalize")
	local lines = { "SCHEMA\tsmr.ralph.guard_preparation_capture_manifest.v1" }
	for _, key in ipairs(required_identity) do
		lines[#lines + 1] = table.concat({ "IDENTITY", key, identity[key] }, "\t")
	end
	for _, record in ipairs(call_records) do
		lines[#lines + 1] = table.concat({ "CALL", tostring(record.index),
			tostring(record.resources), tostring(record.prior_sites), record.height,
			record.passability, record.buildable, record.metadata }, "\t")
	end
	write(out_base .. "-manifest.tsv", table.concat(lines, "\n") .. "\n")
	rawset(_G, "g_SbmGuardInputCaptureStatus", "complete")
	return true
end)
rawset(_G, "g_SbmGuardInputCaptureAbort", function(reason)
	if capture.hook == decorated_hook then capture.hook = original_capture_hook end
	if wrapper_installed then restore_prepare("abort") end
	rawset(_G, "g_SbmGuardInputCaptureStatus", "aborted")
	rawset(_G, "g_SbmGuardInputCaptureError", tostring(reason or "host abort"))
	return true
end)

return "smr_guard_preparation_input_probe_armed"

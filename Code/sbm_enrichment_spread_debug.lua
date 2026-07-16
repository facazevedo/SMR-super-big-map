-- Super Big Map -- mode-independent enrichment spread comparison diagnostics.
--
-- This module is deliberately observational. It wraps the vanilla RandomMapGenerator beneath
-- the expansion wrapper (when expansion step 01 is enabled) and directly (when it is disabled),
-- then forwards every call and return value unchanged. The same trace therefore exists in both
-- modes without changing map bounds, random state, candidate selection, or marker positions.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
if type(Engine) ~= "table" then return end
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local Unpack = table.unpack or unpack
local PATCH_VERSION = 9
local SCOPE = "EnrichmentSpreadComparison"

SuperBigMap.State = SuperBigMap.State or {}
local State = SuperBigMap.State
local runs_by_map = setmetatable({}, { __mode = "k" })

local function Pack(...)
	return { n = select("#", ...), ... }
end

local function ReturnPacked(values)
	return Unpack(values, 1, values.n)
end

local function Enabled()
	local debug_log = SuperBigMap.DebugLog
	return debug_log and type(debug_log.On) == "function" and debug_log.On(SCOPE) == true
end

local function Log(message, data, level)
	local debug_log = SuperBigMap.DebugLog
	if not debug_log then return end
	local fn = level == "error" and debug_log.Error
		or (level == "warn" and debug_log.Warn or debug_log.Info)
	if type(fn) == "function" then fn(SCOPE, message, data) end
end

local function Bool(value)
	return value == true and "true" or "false"
end

local function MapName(map)
	return tostring(map and (map.name or (map.mapdata and map.mapdata.id)) or "?")
end

local function PointXYZ(value)
	if value == nil then return nil end
	local ok_xyz, x, y, z = pcall(function() return value:xyz() end)
	if ok_xyz and type(x) == "number" and type(y) == "number" then return x, y, z end
	local ok_xy
	ok_xy, x, y = pcall(function() return value:xy() end)
	if ok_xy and type(x) == "number" and type(y) == "number" then return x, y, nil end
	return nil
end

local function ObjectPos(obj)
	if not obj then return nil end
	if type(obj.GetPos) == "function" then
		local ok, pos = pcall(obj.GetPos, obj)
		if ok and pos then return pos end
	end
	return obj.pos
end

local function DescribeValue(value)
	local x, y, z = PointXYZ(value)
	if x ~= nil then return tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z) end
	if type(value) == "table" then
		local parts = {}
		for i = 1, math.min(#value, 32) do
			parts[#parts + 1] = DescribeValue(value[i])
		end
		if #value > 32 then parts[#parts + 1] = "...(" .. tostring(#value) .. ")" end
		if #parts > 0 then return "[" .. table.concat(parts, "|") .. "]" end
	end
	local ok_size, w, h = pcall(function() return value:size() end)
	if ok_size and w ~= nil then return tostring(value) .. " size=" .. tostring(w) .. "x" .. tostring(h) end
	return tostring(value)
end

local function DescribePacked(values)
	local parts = {}
	for i = 1, values.n do parts[i] = DescribeValue(values[i]) end
	return table.concat(parts, " || ")
end

local function ScalarFields(value)
	if type(value) ~= "table" then return "n/a" end
	local keys, parts = {}, {}
	for key, item in pairs(value) do
		if type(item) == "string" or type(item) == "number" or type(item) == "boolean" then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. "=" .. tostring(value[key]) end
	return #parts > 0 and table.concat(parts, ";") or "none"
end

local function MemberTypes(value)
	if type(value) ~= "table" then return "not-table" end
	local members = {}
	local ok, err = pcall(function()
		for key, item in pairs(value) do
			members[#members + 1] = tostring(key) .. ":" .. type(item)
		end
	end)
	if not ok then return "ERROR:" .. tostring(err) end
	table.sort(members)
	if #members > 256 then
		local total = #members
		for index = #members, 257, -1 do members[index] = nil end
		members[#members + 1] = "...(total=" .. tostring(total) .. ")"
	end
	return #members > 0 and table.concat(members, ";") or "none"
end

local function FunctionEnvironment(fn)
	local getfenv_fn = Global("getfenv")
	if type(getfenv_fn) == "function" then
		local ok, environment = pcall(getfenv_fn, fn)
		if ok and type(environment) == "table" then return environment, "getfenv" end
	end
	local debug_lib = Global("debug")
	if type(debug_lib) == "table" and type(debug_lib.getupvalue) == "function" then
		for index = 1, 64 do
			local ok, name, value = pcall(debug_lib.getupvalue, fn, index)
			if not ok or name == nil then break end
			if name == "_ENV" and type(value) == "table" then return value, "debug._ENV" end
		end
	end
	return nil, "unavailable"
end

local function IsKindOfSafe(obj, class_name)
	if not obj or type(Engine.IsKindOf) ~= "function" then return false end
	local ok, result = pcall(Engine.IsKindOf, obj, class_name)
	return ok and result == true
end

local function RandLast(generator)
	if not generator then return nil end
	local rand_state = generator.rand_state or generator.RandState
	if rand_state and type(rand_state.Last) == "function" then
		local ok, value = pcall(rand_state.Last, rand_state)
		if ok then return value end
	end
	return nil
end

local GENERATOR_FIELDS = {
	"Seed", "Id", "BlankMap", "DepBorderSurf", "DepBorderSubs", "DepBorderTerr",
	"DepBorderAnomaly", "DepBorderEffects", "DepositSpacing", "AnomalySpacing",
	"EffectDepositSpacing", "AnomTechUnlockCount", "AnomEventCount", "AnomFreeTechCount",
	"AnomBreakthroughCount", "DeepAnomBreakthroughChance", "SurfaceDeposits", "SubsurfaceDeposits",
}

local function AddGeneratorFields(out, generator)
	for _, name in ipairs(GENERATOR_FIELDS) do
		out["generator_" .. string.lower(name)] = tostring(generator and generator[name])
	end
	out.generator_rand_last = tostring(RandLast(generator))
	local map_data_table = Global("MapData")
	local blank = generator and generator.BlankMap
	local template = type(map_data_table) == "table" and type(blank) == "string"
		and map_data_table[blank] or nil
	out.template_width_tiles = tostring(template and template.Width)
	out.template_height_tiles = tostring(template and template.Height)
	out.template_pass_border = tostring(template and template.PassBorder)
end

local function MapGeometry(map)
	local geometry = {
		map = MapName(map),
		environment = tostring(map and map.mapdata and map.mapdata.Environment),
		mapdata_width_tiles = tostring(map and map.mapdata and map.mapdata.Width),
		mapdata_height_tiles = tostring(map and map.mapdata and map.mapdata.Height),
		mapdata_pass_border = tostring(map and map.mapdata and map.mapdata.PassBorder),
		source_x = tostring(map and map.SuperBigMapSourceX),
		source_y = tostring(map and map.SuperBigMapSourceY),
		source_width = tostring(map and map.SuperBigMapSourceWidth),
		source_height = tostring(map and map.SuperBigMapSourceHeight),
		generator_width_tiles = tostring(map and map.SuperBigMapGeneratorWidthTiles),
		generator_height_tiles = tostring(map and map.SuperBigMapGeneratorHeightTiles),
		desired_width_tiles = tostring(map and map.SuperBigMapDesiredWidthTiles),
		desired_height_tiles = tostring(map and map.SuperBigMapDesiredHeightTiles),
	}
	if map and type(map.GetMapSize) == "function" then
		local ok, width, height = pcall(map.GetMapSize, map)
		if ok then
			geometry.map_get_size_width = tostring(width)
			geometry.map_get_size_height = tostring(height)
		end
	end
	local terrain_api = Global("terrain")
	if map and type(terrain_api) == "table" and type(terrain_api.GetMapSize) == "function" then
		local ok, width, height = pcall(terrain_api.GetMapSize, map)
		if ok then
			geometry.terrain_get_size_width = tostring(width)
			geometry.terrain_get_size_height = tostring(height)
		end
	end
	return geometry
end

local function Merge(target, source)
	for key, value in pairs(source or {}) do target[key] = value end
	return target
end

local function EffectiveSteps()
	local config = SuperBigMap.Config or {}
	local parts = {}
	for i = 1, 21 do
		parts[i] = config.EXPANSION_ENRICHMENT_STEPS
			and config.EXPANSION_ENRICHMENT_STEPS[i] == true and "1" or "0"
	end
	return table.concat(parts, "")
end

local function ModeFields()
	local config = SuperBigMap.Config or {}
	return {
		step01 = Bool(config.EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE),
		step02 = Bool(config.EXPANSION_STEP_02_STRETCH_AND_TRANSFORM_VANILLA_SOURCE),
		step03 = Bool(config.EXPANSION_STEP_03_GENERATE_ADDITIONAL_ENRICHMENTS),
		effective_steps_01_to_21 = EffectiveSteps(),
		terrain_mode = tostring(config.TERRAIN_SIZE),
		sector_mode = tostring(config.SECTOR_GRID),
		generator_patch = Bool(config.QUADRANT_PATCH_RANDOM_GENERATOR),
		limit_generator_to_source = Bool(config.QUADRANT_LIMIT_GENERATOR_TO_SOURCE),
		preserve_vanilla_pass_border = Bool(config.STRETCH_VANILLA_EXACT_PASSBORDER),
		rmg_placement_fix = Bool(config.ENABLE_RMG_PLACEMENT_FIX),
		native_collision_repair = Bool(config.ENABLE_NATIVE_ALIGNED_HEX_COLLISION_REPAIR),
		native_shortfall_completion = Bool(config.COMPLETE_NATIVE_ENRICHMENT_SHORTFALLS),
	}
end

local function ComparisonRegion(map)
	local const_tbl = Global("const")
	local tile = type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize) or 100
	local origin_x = tonumber(map and map.SuperBigMapSourceX) or 0
	local origin_y = tonumber(map and map.SuperBigMapSourceY) or 0
	local width = tonumber(map and map.SuperBigMapGeneratorWidth)
		or tonumber(map and map.SuperBigMapSourceWidth)
	local height = tonumber(map and map.SuperBigMapGeneratorHeight)
		or tonumber(map and map.SuperBigMapSourceHeight)
	if not width then
		local tiles = tonumber(map and map.SuperBigMapGeneratorWidthTiles)
			or tonumber(map and map.SuperBigMapSourceWidthTiles)
		if tiles then width = tiles * tile end
	end
	if not height then
		local tiles = tonumber(map and map.SuperBigMapGeneratorHeightTiles)
			or tonumber(map and map.SuperBigMapSourceHeightTiles)
		if tiles then height = tiles * tile end
	end
	if (not width or not height) and map and type(map.GetMapSize) == "function" then
		local ok, map_width, map_height = pcall(map.GetMapSize, map)
		if ok then width, height = width or map_width, height or map_height end
	end
	return origin_x, origin_y, tonumber(width) or 0, tonumber(height) or 0
end

local function ClassName(value)
	if value == nil then return "nil" end
	local name = tostring(value)
	pcall(function() name = tostring(value.class or value.__name or value.ClassName or value) end)
	return name
end

local function MarkerFamily(marker)
	if IsKindOfSafe(marker, "SubsurfaceAnomalyMarker") then
		return "anomaly", tostring(marker.sequence or marker.tech_action or marker.scenario or "ordinary")
	end
	if IsKindOfSafe(marker, "EffectDepositMarker") then
		return "effect", tostring(marker.deposit_type or marker.effect or marker.resource or "effect")
	end
	if IsKindOfSafe(marker, "SurfaceDepositMarker")
		or IsKindOfSafe(marker, "SubsurfaceDepositMarker")
		or IsKindOfSafe(marker, "TerrainDepositMarker") then
		return "resource", tostring(marker.resource or marker.deposit_type or "unknown")
	end
	return "other", tostring(marker.resource or marker.deposit_type or marker.sequence or "unknown")
end

local MARKER_FIELDS = {
	"resource", "deposit_type", "tech_action", "sequence", "sequence_list", "scenario",
	"depth_layer", "grade", "max_amount", "density", "density2", "prefab", "is_placed",
}

local function MarkerFields(marker)
	local parts = {}
	for _, name in ipairs(MARKER_FIELDS) do
		local value
		pcall(function() value = marker[name] end)
		if value ~= nil then parts[#parts + 1] = name .. "=" .. tostring(value) end
	end
	return #parts > 0 and table.concat(parts, ";") or "none"
end

local function PositionIdentity(pos)
	local x, y, z = PointXYZ(pos)
	local q, r, hash
	local world_to_hex = Global("WorldToHex")
	if pos and type(world_to_hex) == "function" then
		local ok, hq, hr = pcall(world_to_hex, pos)
		if ok then q, r = hq, hr end
	end
	local xxhash = Global("xxhash")
	if pos and type(xxhash) == "function" then
		local ok, value = pcall(xxhash, pos)
		if ok then hash = value end
	end
	return x, y, z, q, r, hash
end

local function SectorName(map, x, y)
	local get_sector = Global("GetMapSectorXY")
	local city = map and map.City
	if not city or type(get_sector) ~= "function" or x == nil then return "unavailable" end
	local ok, sector = pcall(get_sector, city, x, y)
	if not ok or not sector then return "none" end
	return tostring(sector.display_name or sector.id or sector.name or sector)
end

local function TallyText(tally)
	local keys, parts = {}, {}
	for key in pairs(tally) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. ":" .. tostring(tally[key]) end
	return #parts > 0 and table.concat(parts, ";") or "none"
end

local function Snapshot(map, phase)
	if not Enabled() then return 0 end
	map = map or Global("CurrentMap")
	if not map or type(map.MapForEach) ~= "function" then
		Log("SNAPSHOT_SKIPPED", { phase = tostring(phase), reason = "map/MapForEach unavailable" }, "warn")
		return 0
	end
	local origin_x, origin_y, region_width, region_height = ComparisonRegion(map)
	local records = {}
	local ok_scan, scan_error = pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		local pos = ObjectPos(marker)
		local x, y, z, q, r, hash = PositionIdentity(pos)
		local family, subtype = MarkerFamily(marker)
		local inside = type(x) == "number" and type(y) == "number" and region_width > 0 and region_height > 0
			and x >= origin_x and x < origin_x + region_width
			and y >= origin_y and y < origin_y + region_height
		local col, row = 0, 0
		if inside then
			col = math.max(1, math.min(10, math.floor((x - origin_x) * 10 / region_width) + 1))
			row = math.max(1, math.min(10, math.floor((y - origin_y) * 10 / region_height) + 1))
		end
		records[#records + 1] = {
			marker = marker, class = ClassName(marker), family = family, subtype = subtype,
			x = x, y = y, z = z, q = q, r = r, hash = hash, inside = inside,
			cell = inside and (string.format("%02d,%02d", col, row)) or "outside",
			sector = SectorName(map, x, y), fields = MarkerFields(marker),
			handle = tostring(marker.handle or marker),
		}
	end)
	if not ok_scan then
		Log("SNAPSHOT_SCAN_ERROR", { phase = tostring(phase), map = MapName(map), error = tostring(scan_error) }, "error")
		return 0
	end
	table.sort(records, function(a, b)
		local ak = table.concat({ a.family, a.subtype, a.class, tostring(a.x), tostring(a.y), a.handle }, "|")
		local bk = table.concat({ b.family, b.subtype, b.class, tostring(b.x), tostring(b.y), b.handle }, "|")
		return ak < bk
	end)

	local family_counts, subtype_counts, class_counts, sector_counts = {}, {}, {}, {}
	local grid_counts, grid_families = {}, {}
	local coordinate_counts, hash_counts = {}, {}
	local inside_count, outside_count = 0, 0
	local min_x, min_y, max_x, max_y, sum_x, sum_y = nil, nil, nil, nil, 0, 0
	for _, record in ipairs(records) do
		family_counts[record.family] = (family_counts[record.family] or 0) + 1
		local subtype_key = record.family .. "/" .. record.subtype
		subtype_counts[subtype_key] = (subtype_counts[subtype_key] or 0) + 1
		class_counts[record.class] = (class_counts[record.class] or 0) + 1
		sector_counts[record.sector] = (sector_counts[record.sector] or 0) + 1
		grid_counts[record.cell] = (grid_counts[record.cell] or 0) + 1
		grid_families[record.cell] = grid_families[record.cell] or {}
		grid_families[record.cell][record.family] = (grid_families[record.cell][record.family] or 0) + 1
		if record.inside then inside_count = inside_count + 1 else outside_count = outside_count + 1 end
		if type(record.x) == "number" and type(record.y) == "number" then
			min_x = min_x and math.min(min_x, record.x) or record.x
			min_y = min_y and math.min(min_y, record.y) or record.y
			max_x = max_x and math.max(max_x, record.x) or record.x
			max_y = max_y and math.max(max_y, record.y) or record.y
			sum_x, sum_y = sum_x + record.x, sum_y + record.y
			local key = tostring(record.x) .. ":" .. tostring(record.y)
			coordinate_counts[key] = (coordinate_counts[key] or 0) + 1
		end
		if record.hash ~= nil then hash_counts[tostring(record.hash)] = (hash_counts[tostring(record.hash)] or 0) + 1 end
	end

	local pair_count, nearest_sum, nearest_count, global_min = 0, 0, 0, nil
	for i = 1, #records do
		local current = records[i]
		local nearest, nearest_index, nearest_same, nearest_same_index
		if type(current.x) == "number" and type(current.y) == "number" then
			for j = 1, #records do
				if i ~= j and type(records[j].x) == "number" and type(records[j].y) == "number" then
					local dx, dy = current.x - records[j].x, current.y - records[j].y
					local distance = math.sqrt(dx * dx + dy * dy + 0.0)
					if not nearest or distance < nearest then nearest, nearest_index = distance, j end
					if current.family == records[j].family and (not nearest_same or distance < nearest_same) then
						nearest_same, nearest_same_index = distance, j
					end
					if j > i then
						pair_count = pair_count + 1
						global_min = global_min and math.min(global_min, distance) or distance
					end
				end
			end
		end
		current.nearest = nearest
		current.nearest_index = nearest_index
		current.nearest_same = nearest_same
		current.nearest_same_index = nearest_same_index
		if nearest then nearest_sum, nearest_count = nearest_sum + nearest, nearest_count + 1 end
	end

	local signature_parts = {}
	for _, record in ipairs(records) do
		signature_parts[#signature_parts + 1] = table.concat({
			record.family, record.subtype, record.class, tostring(record.x), tostring(record.y),
			tostring(record.z), tostring(record.q), tostring(record.r), tostring(record.hash),
		}, "|")
	end
	local signature_text = table.concat(signature_parts, "\n")
	local signature_hash = "unavailable"
	local xxhash = Global("xxhash")
	if type(xxhash) == "function" then
		local ok, value = pcall(xxhash, signature_text)
		if ok then signature_hash = tostring(value) end
	end
	local duplicate_coordinates, duplicate_hashes = 0, 0
	for _, count in pairs(coordinate_counts) do if count > 1 then duplicate_coordinates = duplicate_coordinates + count - 1 end end
	for _, count in pairs(hash_counts) do if count > 1 then duplicate_hashes = duplicate_hashes + count - 1 end end

	local begin = Merge(ModeFields(), MapGeometry(map))
	Merge(begin, {
		phase = tostring(phase), markers = #records,
		comparison_origin_x = origin_x, comparison_origin_y = origin_y,
		comparison_width = region_width, comparison_height = region_height,
		inside_comparison_region = inside_count, outside_comparison_region = outside_count,
	})
	Log("SNAPSHOT_BEGIN", begin)
	for index, record in ipairs(records) do
		local nearest_record = record.nearest_index and records[record.nearest_index] or nil
		local nearest_same_record = record.nearest_same_index and records[record.nearest_same_index] or nil
		Log("MARKER", {
			phase = tostring(phase), index = index, class = record.class,
			family = record.family, subtype = record.subtype, fields = record.fields,
			x = tostring(record.x), y = tostring(record.y), z = tostring(record.z),
			q = tostring(record.q), r = tostring(record.r), hash = tostring(record.hash),
			handle = record.handle, inside = Bool(record.inside), cell_10x10 = record.cell,
			sector = record.sector,
			normalized_x_permille = record.inside and math.floor((record.x - origin_x) * 1000 / region_width + 0.5) or "outside",
			normalized_y_permille = record.inside and math.floor((record.y - origin_y) * 1000 / region_height + 0.5) or "outside",
			nearest_index = tostring(record.nearest_index), nearest_distance = tostring(record.nearest),
			nearest_family = tostring(nearest_record and nearest_record.family),
			nearest_class = tostring(nearest_record and nearest_record.class),
			nearest_same_index = tostring(record.nearest_same_index),
			nearest_same_distance = tostring(record.nearest_same),
			nearest_same_class = tostring(nearest_same_record and nearest_same_record.class),
		})
	end
	for row = 1, 10 do
		for col = 1, 10 do
			local cell = string.format("%02d,%02d", col, row)
			Log("GRID_CELL", {
				phase = tostring(phase), cell_10x10 = cell, count = grid_counts[cell] or 0,
				families = TallyText(grid_families[cell] or {}),
			})
		end
	end
	Log("SNAPSHOT_END", {
		phase = tostring(phase), map = MapName(map), markers = #records, pairs = pair_count,
		inside_comparison_region = inside_count, outside_comparison_region = outside_count,
		family_counts = TallyText(family_counts), subtype_counts = TallyText(subtype_counts),
		class_counts = TallyText(class_counts), sector_counts = TallyText(sector_counts),
		min_x = tostring(min_x), min_y = tostring(min_y), max_x = tostring(max_x), max_y = tostring(max_y),
		centroid_x = #records > 0 and tostring(sum_x / #records) or "n/a",
		centroid_y = #records > 0 and tostring(sum_y / #records) or "n/a",
		global_min_pair_distance = tostring(global_min),
		average_nearest_distance = nearest_count > 0 and tostring(nearest_sum / nearest_count) or "n/a",
		duplicate_coordinates = duplicate_coordinates, duplicate_hashes = duplicate_hashes,
		signature_hash = signature_hash, signature_bytes = #signature_text,
	})
	return #records
end

local function NewRun(generator, source)
	State.enrichment_spread_comparison_sequence = (State.enrichment_spread_comparison_sequence or 0) + 1
	local run = {
		id = State.enrichment_spread_comparison_sequence,
		source = tostring(source), generator = generator,
		proc_stack = {}, proc_calls = 0, factory_calls = 0, warning_calls = 0,
		rrand_calls = 0, grand_calls = 0, playable_area_calls = 0,
		mask_buildable_calls = 0,
		rebuild_buildable_calls = 0,
		grid_min_max_calls = 0, hex_align_calls = 0, resource_info_calls = 0,
		factory_duplicate_calls = 0, factory_hashes = {}, factory_coordinates = {},
		factory_hexes = {},
	}
	return run
end

local function RunForMap(map, generator)
	local run = map and runs_by_map[map] or nil
	if not run then
		run = State.enrichment_spread_active_generate_run or NewRun(generator, "implicit")
		if map then runs_by_map[map] = run end
	end
	if map then run.map = map end
	return run
end

local function RunFields(run, map)
	local fields = Merge(ModeFields(), MapGeometry(map))
	fields.run_id = run and run.id or "?"
	fields.run_source = run and run.source or "?"
	return fields
end

local function CurrentProc(run)
	return run and run.proc_stack[#run.proc_stack] or "outside-proc"
end

-- Read-only forensic fingerprint for the grids which determine enrichment placement. A full
-- dump would add millions of log lines, so each audit records the authoritative dimensions plus
-- a fixed 17x17 spatial lattice. The two independent rolling checksums and the
-- explicit rows make Step-01-off/on comparisons deterministic while preserving the layout of
-- the sampled values. An optional region lets the expanded 8192 backing and its 6144 source
-- corner be fingerprinted separately without copying or resampling either grid.
-- Deliberately never call GridMinMax here: native terrain storage grids support size/get but
-- trigger the engine-level "Grid Type Not Supported" asset error in GridMinMax even under pcall.
local function GridAudit(run, label, grid, extra, region)
	if not Enabled() then return false end
	local ok_size, width, height = pcall(function() return grid:size() end)
	height = height or width
	local get_type = "unavailable"
	pcall(function() get_type = type(grid.get) end)
	if not ok_size or type(width) ~= "number" or type(height) ~= "number"
		or width <= 0 or height <= 0 or get_type ~= "function" then
		Log("GRID_AUDIT_UNAVAILABLE", Merge({
			run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
			grid = tostring(grid), size_ok = Bool(ok_size), width = tostring(width),
			height = tostring(height), get_type = get_type,
		}, extra), "warn")
		return false
	end

	local x0, y0, x1, y1 = 0, 0, width - 1, height - 1
	if type(region) == "table" then
		x0 = math.max(0, math.min(width - 1, math.floor(tonumber(region.x0) or 0)))
		y0 = math.max(0, math.min(height - 1, math.floor(tonumber(region.y0) or 0)))
		x1 = math.max(x0, math.min(width - 1, math.floor(tonumber(region.x1) or (width - 1))))
		y1 = math.max(y0, math.min(height - 1, math.floor(tonumber(region.y1) or (height - 1))))
	end

	local SAMPLE_SIDE, MOD = 17, 2147483647
	local xs = {}
	for ix = 0, SAMPLE_SIDE - 1 do
		xs[#xs + 1] = math.floor(x0 + (x1 - x0) * ix / (SAMPLE_SIDE - 1) + 0.5)
	end
	local begin_fields = Merge({
		run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
		grid = tostring(grid), width = width, height = height,
		region = tostring(x0) .. ":" .. tostring(y0) .. "-" .. tostring(x1) .. ":" .. tostring(y1),
		full_min_max = "omitted-native-grid-safe", sample_side = SAMPLE_SIDE,
		x_coordinates = table.concat(xs, ","),
	}, extra)
	Log("GRID_AUDIT_BEGIN", begin_fields)

	local checksum_a, checksum_b, sample_index = 0, 0, 0
	local sample_min, sample_max, numeric, zeros, ones, non_numeric = nil, nil, 0, 0, 0, 0
	for iy = 0, SAMPLE_SIDE - 1 do
		local y = math.floor(y0 + (y1 - y0) * iy / (SAMPLE_SIDE - 1) + 0.5)
		local row = {}
		for ix = 1, #xs do
			local x = xs[ix]
			local ok_get, value = pcall(grid.get, grid, x, y)
			sample_index = sample_index + 1
			if ok_get and type(value) == "number" then
				numeric = numeric + 1
				sample_min = sample_min == nil and value or math.min(sample_min, value)
				sample_max = sample_max == nil and value or math.max(sample_max, value)
				if value == 0 then zeros = zeros + 1 elseif value == 1 then ones = ones + 1 end
				local normalized = math.floor(value * 1000 + (value >= 0 and 0.5 or -0.5))
				checksum_a = (checksum_a * 65599 + normalized + sample_index * 97) % MOD
				checksum_b = (checksum_b + (normalized % MOD) * (sample_index * 2 + 1)) % MOD
				row[#row + 1] = tostring(value)
			else
				non_numeric = non_numeric + 1
				checksum_a = (checksum_a * 65599 + sample_index * 97) % MOD
				row[#row + 1] = ok_get and tostring(value) or "ERROR"
			end
		end
		Log("GRID_AUDIT_ROW", {
			run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
			row_index = iy + 1, y = y, values = table.concat(row, ","),
		})
	end
	Log("GRID_AUDIT_END", Merge({
		run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
		checksum_a = checksum_a, checksum_b = checksum_b, numeric_samples = numeric,
		non_numeric_samples = non_numeric, zero_samples = zeros, one_samples = ones,
		sample_min = tostring(sample_min), sample_max = tostring(sample_max),
	}, extra))
	return true
end

-- Exact-content terrain input fingerprint at the native height/type resolution. The engine's
-- xxhash implementation has explicit grid support and processes the backing in native code, so
-- this can cover the complete 6144x6144 source without a 37-million-cell Lua loop. A normalized
-- 24x24 block matrix makes fingerprints comparable when one run exposes a native terrain grid
-- and another exposes a compute grid, and localizes a mismatch to a 256x256 source-tile block.
-- Every source cell participates in exactly one block hash; no sampling or gameplay mutation is
-- involved. GridMinMax is used only on the normalized compute blocks (never on native terrain
-- storage, whose unsupported type previously raised an engine asset error).
local function FineTerrainGridFingerprint(run, label, grid, source_width, source_height, extra, options)
	if not Enabled() then return nil end
	options = type(options) == "table" and options or {}
	local xxhash_fn = Global("xxhash")
	local grid_to_compute = Global("GridToCompute")
	local grid_min_max = Global("GridMinMax")
	local box_fn = Global("box")
	local point_fn = Global("point")
	local ticks = Global("GetPreciseTicks")
	if type(xxhash_fn) ~= "function" or type(grid_to_compute) ~= "function"
		or type(box_fn) ~= "function" or type(point_fn) ~= "function" then
		Log("FINE_TERRAIN_GRID_UNAVAILABLE", Merge({
			run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
			grid = tostring(grid), xxhash_type = type(xxhash_fn),
			grid_to_compute_type = type(grid_to_compute), box_type = type(box_fn),
			point_type = type(point_fn),
		}, extra), "warn")
		return nil
	end

	local ok_size, input_width, input_height = pcall(function() return grid:size() end)
	input_height = input_height or input_width
	source_width = math.floor(tonumber(source_width) or tonumber(input_width) or 0)
	source_height = math.floor(tonumber(source_height) or tonumber(input_height) or 0)
	if not ok_size or type(input_width) ~= "number" or type(input_height) ~= "number"
		or source_width <= 0 or source_height <= 0
		or input_width < source_width or input_height < source_height then
		Log("FINE_TERRAIN_GRID_UNAVAILABLE", Merge({
			run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
			grid = tostring(grid), size_ok = Bool(ok_size), input_width = tostring(input_width),
			input_height = tostring(input_height), source_width = source_width,
			source_height = source_height, reason = "invalid-source-region",
		}, extra), "warn")
		return nil
	end

	local blocks_x = math.max(1, math.min(source_width,
		math.floor(tonumber(options.blocks_x) or 24)))
	local blocks_y = math.max(1, math.min(source_height,
		math.floor(tonumber(options.blocks_y) or 24)))
	local x_ranges = {}
	for bx = 0, blocks_x - 1 do
		local x0 = math.floor(bx * source_width / blocks_x)
		local x1 = math.floor((bx + 1) * source_width / blocks_x) - 1
		x_ranges[#x_ranges + 1] = tostring(x0) .. "-" .. tostring(x1)
	end
	local input_bits = "unavailable"
	pcall(function() input_bits = grid:bits() end)
	local started = 0
	if type(ticks) == "function" then
		local ok_ticks, value = pcall(ticks)
		if ok_ticks and type(value) == "number" then started = value end
	end
	Log("FINE_TERRAIN_GRID_BEGIN", Merge({
		run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
		grid = tostring(grid), input_width = input_width, input_height = input_height,
		source_width = source_width, source_height = source_height,
		source_cells = source_width * source_height, input_bits = tostring(input_bits),
		blocks_x = blocks_x, blocks_y = blocks_y, x_ranges = table.concat(x_ranges, ","),
		algorithm = "native-xxhash-plus-normalized-block-xxhash-v1",
	}, extra))

	local temporary_native, temporary_compute
	local ok_hash, stats = pcall(function()
		local result = {
			label = tostring(label), input_width = input_width, input_height = input_height,
			source_width = source_width, source_height = source_height,
			blocks_x = blocks_x, blocks_y = blocks_y,
			native_hash_a = xxhash_fn(grid),
			native_hash_b = xxhash_fn("SBM_FINE_TERRAIN_NATIVE_V1", grid),
			normalized_hash_a = 0, normalized_hash_b = 0,
			minimum = nil, maximum = nil,
		}
		for by = 0, blocks_y - 1 do
			local y0 = math.floor(by * source_height / blocks_y)
			local y1 = math.floor((by + 1) * source_height / blocks_y)
			local row_hash_a, row_hash_b, row_minimums, row_maximums = {}, {}, {}, {}
			for bx = 0, blocks_x - 1 do
				local x0 = math.floor(bx * source_width / blocks_x)
				local x1 = math.floor((bx + 1) * source_width / blocks_x)
				local block_width, block_height = x1 - x0, y1 - y0
				if type(grid.new_instance) ~= "function" then
					error("grid:new_instance unavailable")
				end
				temporary_native = grid:new_instance(block_width, block_height)
				if not temporary_native or type(temporary_native.copyrect) ~= "function" then
					error("native block allocation/copy unavailable")
				end
				temporary_native:copyrect(grid, box_fn(x0, y0, x1, y1), point_fn(0, 0))
				temporary_compute = grid_to_compute(temporary_native)
				if not temporary_compute then error("block GridToCompute failed") end
				local block_hash_a = xxhash_fn(temporary_compute)
				local block_hash_b = xxhash_fn("SBM_FINE_TERRAIN_BLOCK_V1", temporary_compute)
				local block_min, block_max = nil, nil
				if type(grid_min_max) == "function" then
					local ok_minmax, minimum, maximum = pcall(grid_min_max, temporary_compute)
					if ok_minmax then block_min, block_max = minimum, maximum end
				end
				result.minimum = block_min ~= nil and (result.minimum == nil
					and block_min or math.min(result.minimum, block_min)) or result.minimum
				result.maximum = block_max ~= nil and (result.maximum == nil
					and block_max or math.max(result.maximum, block_max)) or result.maximum
				result.normalized_hash_a = xxhash_fn(result.normalized_hash_a,
					bx, by, block_width, block_height, block_hash_a)
				result.normalized_hash_b = xxhash_fn(result.normalized_hash_b,
					bx, by, block_width, block_height, block_hash_b)
				row_hash_a[#row_hash_a + 1] = tostring(block_hash_a)
				row_hash_b[#row_hash_b + 1] = tostring(block_hash_b)
				row_minimums[#row_minimums + 1] = tostring(block_min)
				row_maximums[#row_maximums + 1] = tostring(block_max)
				if temporary_compute ~= temporary_native then
					pcall(function() temporary_compute:free() end)
				end
				temporary_compute = nil
				pcall(function() temporary_native:free() end)
				temporary_native = nil
			end
			Log("FINE_TERRAIN_BLOCK_ROW", Merge({
				run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
				block_row = by + 1, y_range = tostring(y0) .. "-" .. tostring(y1 - 1),
				hashes_a = table.concat(row_hash_a, ","),
				hashes_b = table.concat(row_hash_b, ","),
				minimums = table.concat(row_minimums, ","),
				maximums = table.concat(row_maximums, ","),
			}, extra))
		end
		return result
	end)
	if temporary_compute and temporary_compute ~= temporary_native then
		pcall(function() temporary_compute:free() end)
	end
	if temporary_native then pcall(function() temporary_native:free() end) end
	local elapsed = 0
	if type(ticks) == "function" then
		local ok_ticks, value = pcall(ticks)
		if ok_ticks and type(value) == "number" then elapsed = value - started end
	end
	if not ok_hash then
		Log("FINE_TERRAIN_GRID_FAILED", Merge({
			run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
			error = tostring(stats), ms = elapsed,
		}, extra), "warn")
		return nil
	end
	stats.ms = elapsed
	Log("FINE_TERRAIN_GRID_END", Merge({
		run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
		input_width = input_width, input_height = input_height,
		source_width = source_width, source_height = source_height,
		native_hash_a = tostring(stats.native_hash_a), native_hash_b = tostring(stats.native_hash_b),
		normalized_hash_a = tostring(stats.normalized_hash_a),
		normalized_hash_b = tostring(stats.normalized_hash_b),
		minimum = tostring(stats.minimum), maximum = tostring(stats.maximum), ms = elapsed,
	}, extra))
	return stats
end

-- Exhaustive usable-area forensic scan. Unlike GridAudit's fixed lattice this reads every cell,
-- so its checksums and counts detect even a one-cell difference. A compact 24x24 block matrix
-- preserves the spatial distribution without emitting one line per cell. When compare.values is
-- supplied, the scan also records exact before->after transitions made by a native grid operation.
local function GridFullAudit(run, label, grid, extra, options)
	if not Enabled() then return nil end
	options = type(options) == "table" and options or {}
	local ok_size, width, height = pcall(function() return grid:size() end)
	height = height or width
	local get_type = "unavailable"
	pcall(function() get_type = type(grid.get) end)
	if not ok_size or type(width) ~= "number" or type(height) ~= "number"
		or width <= 0 or height <= 0 or get_type ~= "function" then
		Log("GRID_FULL_AUDIT_UNAVAILABLE", Merge({
			run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
			grid = tostring(grid), size_ok = Bool(ok_size), width = tostring(width),
			height = tostring(height), get_type = get_type,
		}, extra), "warn")
		return nil
	end

	local blocks_x = math.max(1, math.min(width, math.floor(tonumber(options.blocks_x) or 24)))
	local blocks_y = math.max(1, math.min(height, math.floor(tonumber(options.blocks_y) or 24)))
	local x_ranges = {}
	for bx = 0, blocks_x - 1 do
		local first = math.floor(bx * width / blocks_x)
		local last = math.floor((bx + 1) * width / blocks_x) - 1
		x_ranges[#x_ranges + 1] = tostring(first) .. "-" .. tostring(last)
	end
	Log("GRID_FULL_AUDIT_BEGIN", Merge({
		run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
		grid = tostring(grid), width = width, height = height, cells = width * height,
		blocks_x = blocks_x, blocks_y = blocks_y, x_ranges = table.concat(x_ranges, ","),
		capture_values = Bool(options.capture_values == true),
		compare_label = tostring(options.compare and options.compare.label),
	}, extra))

	local ticks = Global("GetPreciseTicks")
	local started = 0
	if type(ticks) == "function" then
		local ok_ticks, value = pcall(ticks)
		if ok_ticks and type(value) == "number" then started = value end
	end
	local MOD = 2147483647
	local ok_scan, stats = pcall(function()
		local result = {
			label = tostring(label), width = width, height = height, cells = width * height,
			checksum_a = 0, checksum_b = 0, numeric = 0,
			zeros = 0, ones = 0, nonzero = 0, negative = 0,
			minimum = nil, maximum = nil, sum = 0,
			zero_min_x = nil, zero_min_y = nil, zero_max_x = nil, zero_max_y = nil,
			nonzero_min_x = nil, nonzero_min_y = nil, nonzero_max_x = nil, nonzero_max_y = nil,
			changed_min_x = nil, changed_min_y = nil, changed_max_x = nil, changed_max_y = nil,
			blocks = {}, histogram = options.histogram == true and {} or nil,
			values = options.capture_values == true and {} or nil,
			changed = 0, unchanged = 0, zero_to_one = 0, one_to_zero = 0,
			transitions = options.compare and {} or nil,
		}
		for by = 1, blocks_y do
			result.blocks[by] = {}
			for bx = 1, blocks_x do
				result.blocks[by][bx] = {
					cells = 0, zeros = 0, ones = 0, nonzero = 0, sum = 0,
					minimum = nil, maximum = nil, changed = 0,
					zero_to_one = 0, one_to_zero = 0,
				}
			end
		end
		local compare_values = options.compare and options.compare.values
		if options.compare and type(compare_values) ~= "table" then
			error("comparison values unavailable for " .. tostring(options.compare.label))
		end
		local index = 0
		for y = 0, height - 1 do
			local by = math.min(blocks_y, math.floor(y * blocks_y / height) + 1)
			for x = 0, width - 1 do
				index = index + 1
				local value = grid:get(x, y)
				if type(value) ~= "number" then
					error("non-numeric cell at " .. tostring(x) .. ":" .. tostring(y)
						.. " value=" .. tostring(value))
				end
				local bx = math.min(blocks_x, math.floor(x * blocks_x / width) + 1)
				local block = result.blocks[by][bx]
				result.numeric = result.numeric + 1
				result.minimum = result.minimum == nil and value or math.min(result.minimum, value)
				result.maximum = result.maximum == nil and value or math.max(result.maximum, value)
				result.sum = result.sum + value
				block.cells = block.cells + 1
				block.sum = block.sum + value
				block.minimum = block.minimum == nil and value or math.min(block.minimum, value)
				block.maximum = block.maximum == nil and value or math.max(block.maximum, value)
				if value == 0 then
					result.zeros = result.zeros + 1
					block.zeros = block.zeros + 1
					result.zero_min_x = result.zero_min_x == nil and x or math.min(result.zero_min_x, x)
					result.zero_min_y = result.zero_min_y == nil and y or math.min(result.zero_min_y, y)
					result.zero_max_x = result.zero_max_x == nil and x or math.max(result.zero_max_x, x)
					result.zero_max_y = result.zero_max_y == nil and y or math.max(result.zero_max_y, y)
				else
					result.nonzero = result.nonzero + 1
					block.nonzero = block.nonzero + 1
					result.nonzero_min_x = result.nonzero_min_x == nil and x or math.min(result.nonzero_min_x, x)
					result.nonzero_min_y = result.nonzero_min_y == nil and y or math.min(result.nonzero_min_y, y)
					result.nonzero_max_x = result.nonzero_max_x == nil and x or math.max(result.nonzero_max_x, x)
					result.nonzero_max_y = result.nonzero_max_y == nil and y or math.max(result.nonzero_max_y, y)
				end
				if value == 1 then
					result.ones = result.ones + 1
					block.ones = block.ones + 1
				elseif value < 0 then
					result.negative = result.negative + 1
				end
				if result.histogram then result.histogram[value] = (result.histogram[value] or 0) + 1 end
				if result.values then result.values[index] = value end
				local normalized = math.floor(value * 1000 + (value >= 0 and 0.5 or -0.5))
				result.checksum_a = (result.checksum_a * 65599 + normalized + index * 97) % MOD
				local normalized_mod = normalized % MOD
				result.checksum_b = (result.checksum_b
					+ normalized_mod * ((index % 104729) * 2 + 1)) % MOD
				if compare_values then
					local before = compare_values[index]
					if before == value then
						result.unchanged = result.unchanged + 1
					else
						result.changed = result.changed + 1
						block.changed = block.changed + 1
						result.changed_min_x = result.changed_min_x == nil and x or math.min(result.changed_min_x, x)
						result.changed_min_y = result.changed_min_y == nil and y or math.min(result.changed_min_y, y)
						result.changed_max_x = result.changed_max_x == nil and x or math.max(result.changed_max_x, x)
						result.changed_max_y = result.changed_max_y == nil and y or math.max(result.changed_max_y, y)
						if before == 0 and value == 1 then
							result.zero_to_one = result.zero_to_one + 1
							block.zero_to_one = block.zero_to_one + 1
						elseif before == 1 and value == 0 then
							result.one_to_zero = result.one_to_zero + 1
							block.one_to_zero = block.one_to_zero + 1
						end
						local transition = tostring(before) .. ">" .. tostring(value)
						result.transitions[transition] = (result.transitions[transition] or 0) + 1
					end
				end
			end
		end
		return result
	end)
	if not ok_scan then
		Log("GRID_FULL_AUDIT_FAILED", Merge({
			run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
			error = tostring(stats),
		}, extra), "warn")
		return nil
	end
	local elapsed = 0
	if type(ticks) == "function" then
		local ok_ticks, value = pcall(ticks)
		if ok_ticks and type(value) == "number" then elapsed = value - started end
	end
	local function bbox(min_x, min_y, max_x, max_y)
		if min_x == nil then return "none" end
		return tostring(min_x) .. ":" .. tostring(min_y) .. "-" .. tostring(max_x) .. ":" .. tostring(max_y)
	end
	Log("GRID_FULL_AUDIT_SUMMARY", Merge({
		run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
		width = width, height = height, cells = stats.cells, numeric_cells = stats.numeric,
		checksum_a = stats.checksum_a, checksum_b = stats.checksum_b,
		zeros = stats.zeros, ones = stats.ones, nonzero = stats.nonzero,
		negative = stats.negative, minimum = tostring(stats.minimum), maximum = tostring(stats.maximum),
		sum = tostring(stats.sum), zero_bbox = bbox(stats.zero_min_x, stats.zero_min_y,
			stats.zero_max_x, stats.zero_max_y),
		nonzero_bbox = bbox(stats.nonzero_min_x, stats.nonzero_min_y,
			stats.nonzero_max_x, stats.nonzero_max_y),
		changed_bbox = bbox(stats.changed_min_x, stats.changed_min_y,
			stats.changed_max_x, stats.changed_max_y),
		changed_cells = stats.changed, unchanged_cells = stats.unchanged,
		zero_to_one = stats.zero_to_one, one_to_zero = stats.one_to_zero,
		ms = elapsed,
	}, extra))

	if stats.histogram then
		local entries = {}
		for value, count in pairs(stats.histogram) do entries[#entries + 1] = { value = value, count = count } end
		table.sort(entries, function(a, b)
			if a.count ~= b.count then return a.count > b.count end
			return a.value < b.value
		end)
		local parts = {}
		for i = 1, math.min(#entries, 128) do
			parts[#parts + 1] = tostring(entries[i].value) .. ":" .. tostring(entries[i].count)
		end
		Log("GRID_FULL_HISTOGRAM", {
			run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
			distinct_values = #entries, entries_by_count = table.concat(parts, ";"),
			truncated = Bool(#entries > #parts),
		})
	end
	if stats.transitions then
		local keys, parts = {}, {}
		for transition in pairs(stats.transitions) do keys[#keys + 1] = transition end
		table.sort(keys)
		for _, transition in ipairs(keys) do
			parts[#parts + 1] = transition .. ":" .. tostring(stats.transitions[transition])
		end
		Log("GRID_FULL_TRANSITIONS", {
			run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
			compare_label = tostring(options.compare and options.compare.label),
			changed_cells = stats.changed, unchanged_cells = stats.unchanged,
			transitions = #parts > 0 and table.concat(parts, ";") or "none",
		})
	end

	if options.log_blocks ~= false then
		for by = 1, blocks_y do
			local cells, zeros, ones, nonzero, averages, minimums, maximums = {}, {}, {}, {}, {}, {}, {}
			local changed, zero_to_one, one_to_zero = {}, {}, {}
			for bx = 1, blocks_x do
				local block = stats.blocks[by][bx]
				cells[#cells + 1] = tostring(block.cells)
				zeros[#zeros + 1] = tostring(block.zeros)
				ones[#ones + 1] = tostring(block.ones)
				nonzero[#nonzero + 1] = tostring(block.nonzero)
				averages[#averages + 1] = block.cells > 0 and string.format("%.3f", block.sum / block.cells) or "nil"
				minimums[#minimums + 1] = tostring(block.minimum)
				maximums[#maximums + 1] = tostring(block.maximum)
				changed[#changed + 1] = tostring(block.changed)
				zero_to_one[#zero_to_one + 1] = tostring(block.zero_to_one)
				one_to_zero[#one_to_zero + 1] = tostring(block.one_to_zero)
			end
			local y0 = math.floor((by - 1) * height / blocks_y)
			local y1 = math.floor(by * height / blocks_y) - 1
			Log("GRID_FULL_BLOCK_ROW", {
				run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
				block_row = by, y_range = tostring(y0) .. "-" .. tostring(y1),
				cells = table.concat(cells, ","), zeros = table.concat(zeros, ","),
				ones = table.concat(ones, ","), nonzero = table.concat(nonzero, ","),
				averages = table.concat(averages, ","), minimums = table.concat(minimums, ","),
				maximums = table.concat(maximums, ","),
				changed = table.concat(changed, ","), zero_to_one = table.concat(zero_to_one, ","),
				one_to_zero = table.concat(one_to_zero, ","),
			})
		end
	end
	return stats
end

-- Lossless spatial dump for a binary classification derived from a native grid. Each row is
-- encoded as hexadecimal bits (four x-cells per digit, most-significant bit first). Unlike the
-- aggregate/full-grid hashes above, two logs can therefore be decoded and differenced later to
-- recover every mismatching coordinate without retaining engine grid userdata between runs.
local function GridPredicateBitmapAudit(run, label, grid, predicate_name, predicate, extra)
	if not Enabled() then return nil end
	local ok_size, width, height = pcall(function() return grid:size() end)
	height = height or width
	local get_type = "unavailable"
	pcall(function() get_type = type(grid.get) end)
	if not ok_size or type(width) ~= "number" or type(height) ~= "number"
		or width <= 0 or height <= 0 or get_type ~= "function" or type(predicate) ~= "function" then
		Log("GRID_PREDICATE_BITMAP_UNAVAILABLE", Merge({
			run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
			predicate = tostring(predicate_name), grid = tostring(grid), size_ok = Bool(ok_size),
			width = tostring(width), height = tostring(height), get_type = get_type,
			predicate_type = type(predicate),
		}, extra), "warn")
		return nil
	end

	Log("GRID_PREDICATE_BITMAP_BEGIN", Merge({
		run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
		predicate = tostring(predicate_name), grid = tostring(grid), width = width, height = height,
		cells = width * height, encoding = "hex-msb-first-4-x-cells-per-digit",
		valid_bits_last_digit = width % 4 == 0 and 4 or width % 4,
	}, extra))

	local MOD = 2147483647
	local hex_digits = "0123456789ABCDEF"
	local checksum_a, checksum_b, active_cells = 0, 0, 0
	local ok_scan, scan_error = pcall(function()
		local index = 0
		for y = 0, height - 1 do
			local digits = {}
			local nibble, nibble_bits, row_active = 0, 0, 0
			local row_checksum_a, row_checksum_b = 0, 0
			for x = 0, width - 1 do
				index = index + 1
				local value = grid:get(x, y)
				local active = predicate(value, x, y) == true
				local bit = active and 1 or 0
				if active then
					active_cells = active_cells + 1
					row_active = row_active + 1
				end
				nibble = nibble * 2 + bit
				nibble_bits = nibble_bits + 1
				checksum_a = (checksum_a * 65599 + bit + index * 97) % MOD
				checksum_b = (checksum_b + bit * ((index % 104729) * 2 + 1)) % MOD
				row_checksum_a = (row_checksum_a * 65599 + bit + (x + 1) * 97) % MOD
				row_checksum_b = (row_checksum_b + bit * (((x + 1) % 104729) * 2 + 1)) % MOD
				if nibble_bits == 4 then
					digits[#digits + 1] = string.sub(hex_digits, nibble + 1, nibble + 1)
					nibble, nibble_bits = 0, 0
				end
			end
			if nibble_bits > 0 then
				nibble = nibble * (2 ^ (4 - nibble_bits))
				digits[#digits + 1] = string.sub(hex_digits, nibble + 1, nibble + 1)
			end
			Log("GRID_PREDICATE_BITMAP_ROW", {
				run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
				predicate = tostring(predicate_name), y = y, active_cells = row_active,
				row_checksum_a = row_checksum_a, row_checksum_b = row_checksum_b,
				hex_bits = table.concat(digits),
			})
		end
	end)
	if not ok_scan then
		Log("GRID_PREDICATE_BITMAP_FAILED", Merge({
			run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
			predicate = tostring(predicate_name), error = tostring(scan_error),
		}, extra), "warn")
		return nil
	end
	local stats = {
		label = tostring(label), predicate = tostring(predicate_name), width = width, height = height,
		cells = width * height, active_cells = active_cells,
		inactive_cells = width * height - active_cells,
		checksum_a = checksum_a, checksum_b = checksum_b,
	}
	Log("GRID_PREDICATE_BITMAP_END", Merge({
		run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
		predicate = tostring(predicate_name), width = width, height = height, cells = width * height,
		active_cells = active_cells, inactive_cells = width * height - active_cells,
		checksum_a = checksum_a, checksum_b = checksum_b,
	}, extra))
	return stats
end

local function NativeMapExtentFields(map, z_grid, mask)
	local buildable = map and map.buildable
	local fields = {
		map = MapName(map), map_width_field = tostring(map and map.Width),
		map_height_field = tostring(map and map.Height),
		map_hex_width_field = tostring(map and map.hex_width),
		map_hex_height_field = tostring(map and map.hex_height),
		mapdata_width_tiles = tostring(map and map.mapdata and map.mapdata.Width),
		mapdata_height_tiles = tostring(map and map.mapdata and map.mapdata.Height),
		mapdata_pass_border = tostring(map and map.mapdata and map.mapdata.PassBorder),
		z_grid = DescribeValue(z_grid), mask_grid = DescribeValue(mask),
		buildable = tostring(buildable), buildable_type = type(buildable),
		buildable_class = tostring(buildable and buildable.class),
		buildable_scalars = ScalarFields(buildable),
		buildable_members = MemberTypes(buildable),
		buildable_z_grid = DescribeValue(buildable and buildable.z_grid),
		map_get_buildable_grid_type = tostring(map and type(map.GetBuildableGrid)),
		global_rebuild_buildable_grid = tostring(Global("RebuildBuildableGrid")),
		global_mask_buildable_grid = tostring(Global("MaskBuildableGrid")),
	}
	if map and type(map.GetMapSize) == "function" then
		local ok, width, height = pcall(map.GetMapSize, map)
		if ok then fields.map_get_size = tostring(width) .. "x" .. tostring(height) end
	end
	local terrain_api = Global("terrain")
	if type(terrain_api) == "table" and type(terrain_api.GetMapSize) == "function" then
		local ok, width, height = pcall(terrain_api.GetMapSize, map)
		if ok then fields.terrain_get_map_size = tostring(width) .. "x" .. tostring(height) end
	end
	if type(terrain_api) == "table" and type(terrain_api.HeightMapSize) == "function" then
		local ok, width, height = pcall(terrain_api.HeightMapSize, map)
		if ok then fields.terrain_height_map_size = tostring(width) .. "x" .. tostring(height or width) end
	end
	return fields
end

local function BuildableState(run, map, phase, extra)
	if not Enabled() then return false end
	local buildable = map and map.buildable
	local z_grid = buildable and buildable.z_grid
	local fields = NativeMapExtentFields(map, z_grid, nil)
	fields.run_id = run and run.id or "?"
	fields.proc = CurrentProc(run)
	fields.phase = tostring(phase)
	Merge(fields, extra)
	Log("BUILDABLE_STATE", fields)
	if z_grid then
		local label = tostring(phase):gsub("[^%w]+", "_"):upper()
		local audit_extra = {
			phase = tostring(phase), buildable = tostring(buildable),
			map_width_field = tostring(map and map.Width),
			map_height_field = tostring(map and map.Height),
			map_hex_width_field = tostring(map and map.hex_width),
			map_hex_height_field = tostring(map and map.hex_height),
		}
		GridAudit(run, "BUILDABLE_STATE_" .. label, z_grid, audit_extra)
		-- These are the two sides of the native ResolveBuildable transaction. Exhaustively hash
		-- the value grid and emit a lossless buildable/not-buildable bitmap at both boundaries.
		if phase == "proc-start-before-ResolveBuildable"
			or phase == "proc-end-before-ResolveBuildable-hook" then
			local full_options = { histogram = true, log_blocks = true }
			if phase == "proc-start-before-ResolveBuildable" then
				full_options.capture_values = true
			elseif run and run.resolve_buildable_before then
				local before = run.resolve_buildable_before
				local ok_size, width, height = pcall(function() return z_grid:size() end)
				height = height or width
				if ok_size and width == before.width and height == before.height then
					full_options.compare = before
				end
			end
			local full_stats = GridFullAudit(run, "BUILDABLE_FORENSIC_FULL_" .. label,
				z_grid, audit_extra, full_options)
			if phase == "proc-start-before-ResolveBuildable" and run then
				run.resolve_buildable_before = full_stats
			elseif phase == "proc-end-before-ResolveBuildable-hook" and run then
				if run.resolve_buildable_before then run.resolve_buildable_before.values = nil end
				run.resolve_buildable_before = nil
			end
			GridPredicateBitmapAudit(run, "BUILDABLE_FORENSIC_BITMAP_" .. label, z_grid,
				"value~=65535", function(value) return value ~= 65535 end, audit_extra)
		end
	end
	return true
end

-- Time the diagnostic algorithms themselves separately from the vanilla call they observe. This
-- is essential during loading investigations: full-grid hashing, bitmap emission, and marker
-- censuses are intentionally exhaustive but are not gameplay work and can be disabled later
-- without changing the generated map. The wrapper adds no calls, yields, or ordering changes.
local function TimedDiagnostic(name, fn, map_resolver, label_index)
	return function(...)
		local args = Pack(...)
		local map = map_resolver and map_resolver(args) or nil
		local label = tostring(args[label_index] or "?")
		local profiler = SuperBigMap.LoadingProfiler
		local token = profiler and type(profiler.InvestigationBegin) == "function"
			and profiler.InvestigationBegin(name, {
				label = label, work_class = "diagnostic-only",
				can_disable_without_gameplay_change = true,
			}, map) or false
		local results = Pack(fn(Unpack(args, 1, args.n)))
		if token and type(profiler.InvestigationEnd) == "function" then
			profiler.InvestigationEnd(token, {
				label = label, work_class = "diagnostic-only",
				can_disable_without_gameplay_change = true,
			}, true)
		end
		return Unpack(results, 1, results.n)
	end
end

Snapshot = TimedDiagnostic("diagnostic algorithm: enrichment spread snapshot", Snapshot,
	function(args) return args[1] end, 2)
GridAudit = TimedDiagnostic("diagnostic algorithm: sampled grid audit", GridAudit,
	function(args) return args[1] and args[1].map end, 2)
GridFullAudit = TimedDiagnostic("diagnostic algorithm: full grid audit", GridFullAudit,
	function(args) return args[1] and args[1].map end, 2)
GridPredicateBitmapAudit = TimedDiagnostic("diagnostic algorithm: grid predicate bitmap audit",
	GridPredicateBitmapAudit, function(args) return args[1] and args[1].map end, 2)
BuildableState = TimedDiagnostic("diagnostic algorithm: buildable-state audit", BuildableState,
	function(args) return args[2] end, 3)

local function LogRelevantEnvironment(run, env)
	local names = {}
	for name in pairs(env or {}) do
		local lower = string.lower(tostring(name))
		if string.find(lower, "build", 1, true) or string.find(lower, "mask", 1, true)
			or string.find(lower, "playable", 1, true) or string.find(lower, "grid", 1, true)
			or string.find(lower, "zone", 1, true) then
			names[#names + 1] = name
		end
	end
	table.sort(names, function(a, b) return tostring(a) < tostring(b) end)
	Log("GENERATOR_ENV_RELEVANT_BEGIN", {
		run_id = run and run.id or "?", proc = CurrentProc(run), symbols = #names,
		env = tostring(env), env_members = MemberTypes(env),
	})
	for index, name in ipairs(names) do
		local value = env[name]
		Log("GENERATOR_ENV_RELEVANT_SYMBOL", {
			run_id = run and run.id or "?", proc = CurrentProc(run), index = index,
			name = tostring(name), value_type = type(value), value = DescribeValue(value),
			scalars = ScalarFields(value), members = MemberTypes(value),
		})
	end
	Log("GENERATOR_ENV_RELEVANT_END", {
		run_id = run and run.id or "?", proc = CurrentProc(run), symbols = #names,
	})
end

local function LogNestedPoints(run, call_kind, call_index, value, result_index, path, seen)
	local x, y, z = PointXYZ(value)
	if x ~= nil then
		Log("HELPER_RESULT_POSITION", {
			run_id = run.id, proc = CurrentProc(run), helper = call_kind,
			call_index = call_index, result_index = result_index, path = path,
			x = x, y = y, z = tostring(z),
		})
		return
	end
	if type(value) ~= "table" then return end
	seen = seen or {}
	if seen[value] then return end
	seen[value] = true
	for i = 1, #value do
		LogNestedPoints(run, call_kind, call_index, value[i], result_index,
			path .. "[" .. tostring(i) .. "]", seen)
	end
end

local Diagnostics = {}
Diagnostics.Snapshot = Snapshot
Diagnostics.TraceBuildableState = BuildableState

-- Public read-only bridge for the map-generation sampler. Both comparison modes call this with
-- the actual height/type grids that InitBuildableGrid is about to observe and the same label, so
-- their normalized whole-source and block fingerprints can be compared directly across logs.
function Diagnostics.TraceFineTerrainForensics(map, label, height_grid, type_grid, extra, options)
	if not Enabled() then return false end
	options = type(options) == "table" and options or {}
	local run = map and RunForMap(map) or State.enrichment_spread_active_do_generate_run
	local source_width = math.floor(tonumber(options.source_width)
		or tonumber(map and map.SuperBigMapGeneratorWidthTiles)
		or tonumber(map and map.SuperBigMapSourceWidthTiles)
		or tonumber(map and map.mapdata and map.mapdata.Width) or 0)
	local source_height = math.floor(tonumber(options.source_height)
		or tonumber(map and map.SuperBigMapGeneratorHeightTiles)
		or tonumber(map and map.SuperBigMapSourceHeightTiles)
		or tonumber(map and map.mapdata and map.mapdata.Height) or 0)
	local fields = Merge({
		run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
		map = MapName(map), source_width = source_width, source_height = source_height,
		height_grid = tostring(height_grid), type_grid = tostring(type_grid),
		blocks_x = tostring(options.blocks_x or 24), blocks_y = tostring(options.blocks_y or 24),
	}, extra)
	Log("FINE_TERRAIN_PAIR_BEGIN", fields)
	local height_stats = FineTerrainGridFingerprint(run, tostring(label) .. "_HEIGHT",
		height_grid, source_width, source_height, extra, options)
	local type_stats = FineTerrainGridFingerprint(run, tostring(label) .. "_TYPE",
		type_grid, source_width, source_height, extra, options)
	local result = {
		height = height_stats, terrain_type = type_stats,
		ok = height_stats ~= nil and type_stats ~= nil,
	}
	Log("FINE_TERRAIN_PAIR_END", Merge({
		run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
		map = MapName(map), source_width = source_width, source_height = source_height,
		height_ok = Bool(height_stats ~= nil), type_ok = Bool(type_stats ~= nil),
		height_normalized_hash_a = tostring(height_stats and height_stats.normalized_hash_a),
		height_normalized_hash_b = tostring(height_stats and height_stats.normalized_hash_b),
		type_normalized_hash_a = tostring(type_stats and type_stats.normalized_hash_a),
		type_normalized_hash_b = tostring(type_stats and type_stats.normalized_hash_b),
		height_ms = tostring(height_stats and height_stats.ms),
		type_ms = tostring(type_stats and type_stats.ms),
	}, extra))
	return result
end

-- Public bridge for the expansion wrapper to expose grids which only exist inside its private
-- source-sized transaction (notably the repaired mask after it replaces the generator argument).
-- The classification name is intentionally finite so callers cannot inject behavior into this
-- observational module.
function Diagnostics.TraceGridForensics(map, label, grid, classification, extra)
	if not Enabled() then return false end
	local run = map and RunForMap(map) or State.enrichment_spread_active_do_generate_run
	local predicate_name, predicate
	if classification == "zero" then
		predicate_name = "value==0"
		predicate = function(value) return value == 0 end
	elseif classification == "nonzero" then
		predicate_name = "value~=0"
		predicate = function(value) return value ~= 0 end
	elseif classification == "buildable" then
		predicate_name = "value~=65535"
		predicate = function(value) return value ~= 65535 end
	else
		Log("GRID_FORENSICS_CLASSIFICATION_UNSUPPORTED", {
			run_id = run and run.id or "?", proc = CurrentProc(run), label = tostring(label),
			classification = tostring(classification),
		}, "warn")
		return false
	end
	GridFullAudit(run, tostring(label) .. "_FULL", grid, extra, {
		histogram = true, log_blocks = true,
	})
	GridPredicateBitmapAudit(run, tostring(label) .. "_BITMAP", grid,
		predicate_name, predicate, extra)
	return true
end

function Diagnostics.TraceGeneratorBoundary(generator, map, phase, extra)
	if not Enabled() then return false end
	local run = map and RunForMap(map, generator) or State.enrichment_spread_active_generate_run
	local fields = run and RunFields(run, map) or Merge(ModeFields(), MapGeometry(map))
	fields.run_id = run and run.id or "pending"
	fields.phase = tostring(phase)
	AddGeneratorFields(fields, generator)
	Merge(fields, extra)
	Log("GENERATOR_BOUNDARY", fields)
	if map and map.buildable then
		BuildableState(run, map, "generator-boundary-" .. tostring(phase), {
			boundary_phase = tostring(phase), generator = tostring(generator),
		})
	end
	return true
end

function Diagnostics.PatchGenerator(reason)
	if not Enabled() then return false end
	local generator_class = Global("RandomMapGenerator")
	if type(generator_class) ~= "table" or type(generator_class.Generate) ~= "function" then
		Log("PATCH_WAITING", { reason = tostring(reason), generator_class = tostring(generator_class) })
		return false
	end

	local function installed_here_or_below(method_name, wrapper_key, mapgen_wrapper_key, mapgen_original_key)
		local current = generator_class[method_name]
		local wrapper = State[wrapper_key]
		if current == wrapper then return true end
		return current == State[mapgen_wrapper_key] and State[mapgen_original_key] == wrapper
	end
	if State.enrichment_spread_patch_version == PATCH_VERSION
		and installed_here_or_below("Generate", "enrichment_spread_generate_wrapper", "generator_generate_wrapper", "generator_original_generate")
		and installed_here_or_below("DoGenerate", "enrichment_spread_do_generate_wrapper", "generator_do_generate_wrapper", "generator_original_do_generate")
		and installed_here_or_below("ProcStart", "enrichment_spread_proc_start_wrapper", "generator_proc_start_wrapper", "generator_original_proc_start")
		and installed_here_or_below("ProcEnd", "enrichment_spread_proc_end_wrapper", "generator_proc_end_wrapper", "generator_original_proc_end")
		and installed_here_or_below("OnGenerateLogic", "enrichment_spread_on_generate_wrapper", "generator_on_generate_logic_wrapper", "generator_original_on_generate_logic") then
		return true
	end

	local function capture_original(method_name, wrapper_key, original_key, mapgen_wrapper_key, mapgen_original_key)
		local current = generator_class[method_name]
		-- On a hot reload, the previous expansion wrapper may still be live when this earlier-loaded
		-- module executes. Peel both known wrapper layers in either order and observe their saved
		-- vanilla/underlying function; the freshly loaded expansion module will then reinstall above
		-- this observer exactly once. The bounded loop also handles expansion -> observer -> vanilla.
		for _ = 1, 4 do
			local previous = current
			if current == State[wrapper_key] and type(State[original_key]) == "function" then
				current = State[original_key]
			elseif current == State[mapgen_wrapper_key]
				and type(State[mapgen_original_key]) == "function" then
				current = State[mapgen_original_key]
			end
			if current == previous then break end
		end
		if type(current) == "function" then State[original_key] = current end
		return State[original_key]
	end
	local original_generate = capture_original("Generate", "enrichment_spread_generate_wrapper",
		"enrichment_spread_original_generate", "generator_generate_wrapper", "generator_original_generate")
	local original_do_generate = capture_original("DoGenerate", "enrichment_spread_do_generate_wrapper",
		"enrichment_spread_original_do_generate", "generator_do_generate_wrapper", "generator_original_do_generate")
	local original_proc_start = capture_original("ProcStart", "enrichment_spread_proc_start_wrapper",
		"enrichment_spread_original_proc_start", "generator_proc_start_wrapper", "generator_original_proc_start")
	local original_proc_end = capture_original("ProcEnd", "enrichment_spread_proc_end_wrapper",
		"enrichment_spread_original_proc_end", "generator_proc_end_wrapper", "generator_original_proc_end")
	local original_on_generate = capture_original("OnGenerateLogic", "enrichment_spread_on_generate_wrapper",
		"enrichment_spread_original_on_generate", "generator_on_generate_logic_wrapper", "generator_original_on_generate_logic")
	if type(original_generate) ~= "function" or type(original_do_generate) ~= "function"
		or type(original_proc_start) ~= "function" or type(original_proc_end) ~= "function"
		or type(original_on_generate) ~= "function" then
		Log("PATCH_INCOMPLETE", { reason = tostring(reason) }, "warn")
		return false
	end

	local generate_wrapper = function(generator, params, ...)
		local run = NewRun(generator, "Generate")
		local previous = State.enrichment_spread_active_generate_run
		State.enrichment_spread_active_generate_run = run
		local fields = RunFields(run, nil)
		fields.params = DescribeValue(params)
		fields.params_fields = ScalarFields(params)
		AddGeneratorFields(fields, generator)
		Log("GENERATE_BEGIN", fields)
		Log("PROCESS_MAP", {
			run_id = run.id,
			sequence = "01-config-and-template | 02-expanded-allocation-boundary | 03-generator-source-view | "
				.. "04-full-MaskBuildableGrid-before-after-census | 05-full-GetPlayableArea-accounting | "
				.. "06-procedure-boundary-and-random-fingerprint | 07-rrand-grand-GridMinMax-selection | "
				.. "08-HexGetNearestCenter-final-alignment | 09-GenMarkerObj-factory | "
				.. "10-post-DoGenerate-native-census | 11-PostNewMapLoaded-census | "
				.. "12-CityInitialized-census | 13-MapGenerated-before-and-after-finalize",
		})
		local results = Pack(pcall(original_generate, generator, params, ...))
		State.enrichment_spread_active_generate_run = previous
		Log("GENERATE_END", {
			run_id = run.id, ok = Bool(results[1]), error = results[1] and "none" or tostring(results[2]),
			proc_calls = run.proc_calls, factory_calls = run.factory_calls,
			warning_calls = run.warning_calls, rrand_calls = run.rrand_calls,
			grand_calls = run.grand_calls, playable_area_calls = run.playable_area_calls,
			mask_buildable_calls = run.mask_buildable_calls,
			rebuild_buildable_calls = run.rebuild_buildable_calls,
			grid_min_max_calls = run.grid_min_max_calls, hex_align_calls = run.hex_align_calls,
			resource_info_calls = run.resource_info_calls,
			factory_duplicate_calls = run.factory_duplicate_calls,
		})
		if not results[1] then error(results[2]) end
		return Unpack(results, 2, results.n)
	end

	local do_generate_wrapper = function(generator, map, ...)
		local run = RunForMap(map, generator)
		local previous = State.enrichment_spread_active_do_generate_run
		State.enrichment_spread_active_do_generate_run = run
		local fields = RunFields(run, map)
		AddGeneratorFields(fields, generator)
		Log("DO_GENERATE_BEGIN", fields)
		BuildableState(run, map, "do-generate-wrapper-entry")

		-- Observe the exact terrain input used by vanilla. Expanded allocation happens before
		-- this wrapper, so a Step-01-on run exposes the real 8192 backing while Step-01-off
		-- exposes vanilla's 6144 grid. Audit both the complete backing and the nominal source
		-- corner, then trace every native sampled read (InitPlayZone and ResolveBuildable).
		local terrain_api = Global("terrain")
		local original_get_height_grid = type(terrain_api) == "table" and terrain_api.GetHeightGrid
		local original_get_type_grid = type(terrain_api) == "table" and terrain_api.GetTypeGrid
		local get_height_wrapper = false
		local original_mask_buildable = Global("MaskBuildableGrid")
		local mask_buildable_wrapper = false
		run.height_grid_get_calls = 0
		run.mask_buildable_calls = 0
		if type(original_get_height_grid) == "function" then
			local ok_backing, backing = pcall(original_get_height_grid, map)
			if ok_backing and backing then
				GridAudit(run, "DO_GENERATE_INPUT_BACKING_FULL", backing, {
					mode = (SuperBigMap.Config or {}).EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE
						and "step01-on" or "step01-off",
				})
				local ok_bs, backing_width, backing_height = pcall(function() return backing:size() end)
				backing_height = backing_height or backing_width
				local source_width = tonumber(map and map.SuperBigMapGeneratorWidthTiles)
					or tonumber(map and map.SuperBigMapSourceWidthTiles)
					or tonumber(map and map.mapdata and map.mapdata.Width)
				local source_height = tonumber(map and map.SuperBigMapGeneratorHeightTiles)
					or tonumber(map and map.SuperBigMapSourceHeightTiles)
					or tonumber(map and map.mapdata and map.mapdata.Height)
				if ok_bs and type(source_width) == "number" and type(source_height) == "number"
					and (source_width < backing_width or source_height < backing_height) then
					GridAudit(run, "DO_GENERATE_INPUT_SOURCE_CORNER", backing, {
						source_width = source_width, source_height = source_height,
					}, { x0 = 0, y0 = 0, x1 = source_width - 1, y1 = source_height - 1 })
				end
			else
				Log("HEIGHT_GRID_BACKING_READ_FAILED", {
					run_id = run.id, map = MapName(map), error = tostring(backing),
				}, "warn")
			end
			GridAudit(run, "DO_GENERATE_BUILDABLE_BEFORE", map and map.buildable and map.buildable.z_grid)

			get_height_wrapper = function(target, ...)
				local args = Pack(...)
				run.height_grid_get_calls = run.height_grid_get_calls + 1
				local call_index = run.height_grid_get_calls
				Log("HEIGHT_GRID_GET_BEGIN", {
					run_id = run.id, proc = CurrentProc(run), call_index = call_index,
					target_map = MapName(target), args = DescribePacked(args),
					map_geometry = ScalarFields(MapGeometry(target)),
				})
				local results = Pack(pcall(original_get_height_grid, target, ...))
				local destination = args[1]
				local grid = destination
				local ok_dest = pcall(function() return destination:size() end)
				if not ok_dest then grid = results[2] end
				if results[1] then
					GridAudit(run, "HEIGHT_GRID_GET_RESULT_" .. tostring(call_index), grid, {
						call_index = call_index, get_args = DescribePacked(args),
					})
				end
				Log("HEIGHT_GRID_GET_END", {
					run_id = run.id, proc = CurrentProc(run), call_index = call_index,
					ok = Bool(results[1]), error = results[1] and "none" or tostring(results[2]),
					results = results[1] and DescribePacked({ n = results.n - 1,
						Unpack(results, 2, results.n) }) or "error",
				})
				if not results[1] then error(results[2]) end
				return Unpack(results, 2, results.n)
			end
			terrain_api.GetHeightGrid = get_height_wrapper
		end
		if type(original_mask_buildable) == "function" then
			mask_buildable_wrapper = function(target_map, z_grid, invalid_mask, ...)
				run.mask_buildable_calls = run.mask_buildable_calls + 1
				local call_index = run.mask_buildable_calls
				local extra = NativeMapExtentFields(target_map, z_grid, invalid_mask)
				extra.call_index = call_index
				extra.arguments_after_mask = DescribePacked(Pack(...))
				Log("MASK_BUILDABLE_BEGIN", Merge({
					run_id = run.id, proc = CurrentProc(run), call_index = call_index,
				}, extra))
				local before = GridFullAudit(run,
					"MASK_BUILDABLE_INVALID_BEFORE_" .. tostring(call_index), invalid_mask, extra, {
						histogram = true, capture_values = true, log_blocks = true,
					})
				GridFullAudit(run,
					"MASK_BUILDABLE_Z_GRID_" .. tostring(call_index), z_grid, extra, {
						histogram = false, log_blocks = true,
					})
				GridPredicateBitmapAudit(run,
					"MASK_BUILDABLE_Z_GRID_BITMAP_" .. tostring(call_index), z_grid,
					"value~=65535", function(value) return value ~= 65535 end, extra)
				GridPredicateBitmapAudit(run,
					"MASK_BUILDABLE_INVALID_BEFORE_BITMAP_" .. tostring(call_index), invalid_mask,
					"value==0", function(value) return value == 0 end, extra)
				local mask_results = Pack(pcall(original_mask_buildable,
					target_map, z_grid, invalid_mask, ...))
				local after
				if mask_results[1] then
					after = GridFullAudit(run,
						"MASK_BUILDABLE_INVALID_AFTER_" .. tostring(call_index), invalid_mask, extra, {
							histogram = true, compare = before, log_blocks = true,
						})
					GridPredicateBitmapAudit(run,
						"MASK_BUILDABLE_INVALID_AFTER_BITMAP_" .. tostring(call_index), invalid_mask,
						"value==0", function(value) return value == 0 end, extra)
				end
				if before then before.values = nil end
				Log("MASK_BUILDABLE_END", Merge({
					run_id = run.id, proc = CurrentProc(run), call_index = call_index,
					ok = Bool(mask_results[1]), error = mask_results[1] and "none" or tostring(mask_results[2]),
					before_zeros = tostring(before and before.zeros),
					before_ones = tostring(before and before.ones),
					after_zeros = tostring(after and after.zeros),
					after_ones = tostring(after and after.ones),
					changed_cells = tostring(after and after.changed),
					zero_to_one = tostring(after and after.zero_to_one),
					one_to_zero = tostring(after and after.one_to_zero),
				}, extra))
				if not mask_results[1] then error(mask_results[2]) end
				return Unpack(mask_results, 2, mask_results.n)
			end
			rawset(_G, "MaskBuildableGrid", mask_buildable_wrapper)
		end
		local results = Pack(pcall(original_do_generate, generator, map, ...))
		if mask_buildable_wrapper and Global("MaskBuildableGrid") == mask_buildable_wrapper then
			rawset(_G, "MaskBuildableGrid", original_mask_buildable)
		end
		if get_height_wrapper and terrain_api.GetHeightGrid == get_height_wrapper then
			terrain_api.GetHeightGrid = original_get_height_grid
		end
		BuildableState(run, map, "do-generate-wrapper-after-native")
		GridAudit(run, "DO_GENERATE_BUILDABLE_AFTER", map and map.buildable and map.buildable.z_grid)
		if results[1] then Snapshot(map, "post-vanilla-DoGenerate") end
		Log("DO_GENERATE_END", {
			run_id = run.id, map = MapName(map), ok = Bool(results[1]),
			error = results[1] and "none" or tostring(results[2]),
			proc_calls = run.proc_calls, factory_calls = run.factory_calls,
			warning_calls = run.warning_calls, rrand_calls = run.rrand_calls,
			grand_calls = run.grand_calls, playable_area_calls = run.playable_area_calls,
			mask_buildable_calls = run.mask_buildable_calls,
			rebuild_buildable_calls = run.rebuild_buildable_calls,
			grid_min_max_calls = run.grid_min_max_calls, hex_align_calls = run.hex_align_calls,
			resource_info_calls = run.resource_info_calls,
			factory_duplicate_calls = run.factory_duplicate_calls,
			height_grid_get_calls = run.height_grid_get_calls,
			final_rand_last = tostring(RandLast(generator)),
		})
		State.enrichment_spread_active_do_generate_run = previous
		if not results[1] then error(results[2]) end
		return Unpack(results, 2, results.n)
	end

	local proc_start_wrapper = function(generator, tag, ...)
		local run = State.enrichment_spread_active_do_generate_run
		local args = Pack(...)
		local rand_before = RandLast(generator)
		if run and tag == "ResolveBuildable" then
			-- Pure vanilla does not invoke the Lua-visible RebuildBuildableGrid closure, but
			-- ProcStart(ResolveBuildable) is observed in every surface run after the final
			-- 6144x6144 terrain exists and immediately before ResolveBuildable consumes the
			-- already initialized native buildable data. Capture the live height/type backing
			-- here. Step-01-on continues to emit the same label from the synchronized sampler
			-- immediately before its native InitBuildableGrid call.
			local step01_on = (SuperBigMap.Config or {})
				.EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE == true
			local target_map = run.map
			local environment = target_map and target_map.mapdata
				and target_map.mapdata.Environment
			if not step01_on and environment ~= "Underground"
				and not run.fine_terrain_buildable_input_audited then
				run.fine_terrain_buildable_input_audited = true
				local terrain_api = Global("terrain")
				local get_height = type(terrain_api) == "table" and terrain_api.GetHeightGrid
				local get_type = type(terrain_api) == "table" and terrain_api.GetTypeGrid
				local ok_height, height_grid = false, nil
				local ok_type, type_grid = false, nil
				if type(get_height) == "function" then
					ok_height, height_grid = pcall(get_height, target_map)
				end
				if type(get_type) == "function" then
					ok_type, type_grid = pcall(get_type, target_map)
				end
				if ok_height and height_grid and ok_type and type_grid then
					local trace_ok, trace_result = pcall(Diagnostics.TraceFineTerrainForensics,
						target_map, "FINE_TERRAIN_BUILDABLE_INPUT", height_grid, type_grid, {
							mode = "step01-off", stage = "proc-start-before-ResolveBuildable",
							input_map = MapName(target_map), rand_before = tostring(rand_before),
						}, { blocks_x = 24, blocks_y = 24 })
					if not trace_ok then
						Log("FINE_TERRAIN_BUILDABLE_INPUT_FAILED", {
							run_id = run.id, proc = CurrentProc(run), mode = "step01-off",
							stage = "proc-start-before-ResolveBuildable",
							error = tostring(trace_result),
						}, "warn")
					end
				else
					Log("FINE_TERRAIN_BUILDABLE_INPUT_UNAVAILABLE", {
						run_id = run.id, proc = CurrentProc(run), mode = "step01-off",
						stage = "proc-start-before-ResolveBuildable",
						height_ok = Bool(ok_height), type_ok = Bool(ok_type),
						height_error = tostring(height_grid), type_error = tostring(type_grid),
					}, "warn")
				end
			end
			BuildableState(run, run.map, "proc-start-before-ResolveBuildable", {
				rand_before = tostring(rand_before),
			})
		end
		if run then
			run.proc_calls = run.proc_calls + 1
			run.proc_stack[#run.proc_stack + 1] = tostring(tag)
		end
		local results = Pack(original_proc_start(generator, tag, ...))
		if run and tag == "ResolveBuildable" then
			BuildableState(run, run.map, "proc-start-after-ResolveBuildable-hook", {
				rand_after = tostring(RandLast(generator)),
			})
		end
		if run then
			local fields = RunFields(run, nil)
			fields.proc_index = run.proc_calls
			fields.tag = tostring(tag)
			fields.args = DescribePacked(args)
			fields.results = DescribePacked(results)
			fields.rand_before = tostring(rand_before)
			fields.rand_after = tostring(RandLast(generator))
			Log("PROC_BEGIN", fields)
		end
		return ReturnPacked(results)
	end

	local proc_end_wrapper = function(generator, tag, ...)
		local run = State.enrichment_spread_active_do_generate_run
		local args = Pack(...)
		local rand_before = RandLast(generator)
		if run and tag == "ResolveBuildable" then
			BuildableState(run, run.map, "proc-end-before-ResolveBuildable-hook", {
				rand_before = tostring(rand_before),
			})
		end
		local results = Pack(original_proc_end(generator, tag, ...))
		if run and tag == "ResolveBuildable" then
			BuildableState(run, run.map, "proc-end-after-ResolveBuildable-hook", {
				rand_after = tostring(RandLast(generator)),
			})
		end
		if run then
			Log("PROC_END", {
				run_id = run.id, proc_index = run.proc_calls, tag = tostring(tag),
				args = DescribePacked(args), results = DescribePacked(results),
				rand_before = tostring(rand_before), rand_after = tostring(RandLast(generator)),
			})
			run.proc_stack[#run.proc_stack] = nil
		end
		return ReturnPacked(results)
	end

	local on_generate_wrapper = function(generator, env, ...)
		if type(env) ~= "table" then return original_on_generate(generator, env, ...) end
		local map = env.map
		local run = RunForMap(map, generator)
		local rhelpers = env.rhelpers
		local saved_rrand = type(rhelpers) == "table" and rhelpers[2] or nil
		local saved_grand = type(rhelpers) == "table" and rhelpers[5] or nil
		local saved_rm_print = env.rm_print
		local saved_factory = env.GenMarkerObj
		local saved_playable = env.GetPlayableArea
		local saved_env_mask_buildable = env.MaskBuildableGrid
		local saved_env_rebuild_buildable = env.RebuildBuildableGrid
		local closure_env, closure_env_source = FunctionEnvironment(original_on_generate)
		local saved_grid_min_max, saved_hex_align, saved_resource_info
		if type(closure_env) == "table" then
			pcall(function()
				saved_grid_min_max = closure_env.GridMinMax
				saved_hex_align = closure_env.HexGetNearestCenter
				saved_resource_info = closure_env.GenerateResourceInfo
			end)
		end
		Log("ON_GENERATE_LOGIC_BEGIN", Merge(RunFields(run, map), {
			rrand_type = type(saved_rrand), grand_type = type(saved_grand),
			rm_print_type = type(saved_rm_print), factory_type = type(saved_factory),
			playable_area_type = type(saved_playable), closure_environment = closure_env_source,
			env_mask_buildable_type = type(saved_env_mask_buildable),
			env_mask_buildable = tostring(saved_env_mask_buildable),
			env_rebuild_buildable_type = type(saved_env_rebuild_buildable),
			env_rebuild_buildable = tostring(saved_env_rebuild_buildable),
			grid_min_max_type = type(saved_grid_min_max), hex_align_type = type(saved_hex_align),
			resource_info_type = type(saved_resource_info),
			gen_area_unscaled = tostring(env.gen_area_unscaled),
		}))
		LogRelevantEnvironment(run, env)
		BuildableState(run, map, "on-generate-logic-entry", {
			env_mask_buildable = tostring(saved_env_mask_buildable),
			env_rebuild_buildable = tostring(saved_env_rebuild_buildable),
		})
		GridAudit(run, "ON_GENERATE_INPUT_GEN_ZONE", env.gen_zone, {
			gen_area_unscaled = tostring(env.gen_area_unscaled),
		})
		GridFullAudit(run, "ON_GENERATE_INPUT_GEN_ZONE_FULL", env.gen_zone, {
			gen_area_unscaled = tostring(env.gen_area_unscaled),
		}, { histogram = true, log_blocks = true })
		GridPredicateBitmapAudit(run, "ON_GENERATE_INPUT_GEN_ZONE_BITMAP", env.gen_zone,
			"value~=0", function(value) return value ~= 0 end, {
				gen_area_unscaled = tostring(env.gen_area_unscaled),
			})
		GridAudit(run, "ON_GENERATE_INPUT_PLAY_ZONE", env.play_zone)
		GridAudit(run, "ON_GENERATE_INPUT_TYPE_GRID", env.type_grid)
		GridAudit(run, "ON_GENERATE_INPUT_BUILDABLE", map and map.buildable and map.buildable.z_grid)

		local rrand_wrapper, grand_wrapper, rm_print_wrapper, factory_wrapper, playable_wrapper
		local env_mask_buildable_wrapper, env_rebuild_buildable_wrapper
		local grid_min_max_wrapper, hex_align_wrapper, resource_info_wrapper
		if type(saved_env_mask_buildable) == "function" then
			env_mask_buildable_wrapper = function(target_map, z_grid, invalid_mask, ...)
				run.mask_buildable_calls = run.mask_buildable_calls + 1
				local call_index = run.mask_buildable_calls
				local extra = NativeMapExtentFields(target_map, z_grid, invalid_mask)
				extra.call_index = call_index
				extra.hook = "generator-env"
				extra.arguments_after_mask = DescribePacked(Pack(...))
				BuildableState(run, target_map, "env-MaskBuildableGrid-before-" .. tostring(call_index), extra)
				Log("MASK_BUILDABLE_BEGIN", Merge({
					run_id = run.id, proc = CurrentProc(run), call_index = call_index,
				}, extra))
				local before = GridFullAudit(run,
					"MASK_BUILDABLE_INVALID_BEFORE_" .. tostring(call_index), invalid_mask, extra, {
						histogram = true, capture_values = true, log_blocks = true,
					})
				GridFullAudit(run,
					"MASK_BUILDABLE_Z_GRID_" .. tostring(call_index), z_grid, extra, {
						histogram = false, log_blocks = true,
					})
				GridPredicateBitmapAudit(run,
					"MASK_BUILDABLE_Z_GRID_BITMAP_" .. tostring(call_index), z_grid,
					"value~=65535", function(value) return value ~= 65535 end, extra)
				GridPredicateBitmapAudit(run,
					"MASK_BUILDABLE_INVALID_BEFORE_BITMAP_" .. tostring(call_index), invalid_mask,
					"value==0", function(value) return value == 0 end, extra)
				local mask_results = Pack(pcall(saved_env_mask_buildable,
					target_map, z_grid, invalid_mask, ...))
				local after
				if mask_results[1] then
					after = GridFullAudit(run,
						"MASK_BUILDABLE_INVALID_AFTER_" .. tostring(call_index), invalid_mask, extra, {
							histogram = true, compare = before, log_blocks = true,
						})
					GridPredicateBitmapAudit(run,
						"MASK_BUILDABLE_INVALID_AFTER_BITMAP_" .. tostring(call_index), invalid_mask,
						"value==0", function(value) return value == 0 end, extra)
				end
				if before then before.values = nil end
				BuildableState(run, target_map, "env-MaskBuildableGrid-after-" .. tostring(call_index), extra)
				Log("MASK_BUILDABLE_END", Merge({
					run_id = run.id, proc = CurrentProc(run), call_index = call_index,
					ok = Bool(mask_results[1]),
					error = mask_results[1] and "none" or tostring(mask_results[2]),
					before_zeros = tostring(before and before.zeros),
					before_ones = tostring(before and before.ones),
					after_zeros = tostring(after and after.zeros),
					after_ones = tostring(after and after.ones),
					changed_cells = tostring(after and after.changed),
					zero_to_one = tostring(after and after.zero_to_one),
					one_to_zero = tostring(after and after.one_to_zero),
				}, extra))
				if not mask_results[1] then error(mask_results[2]) end
				return Unpack(mask_results, 2, mask_results.n)
			end
			env.MaskBuildableGrid = env_mask_buildable_wrapper
		end
		if type(saved_env_rebuild_buildable) == "function" then
			env_rebuild_buildable_wrapper = function(...)
				local args = Pack(...)
				local target_map = args[1] or map
				run.rebuild_buildable_calls = run.rebuild_buildable_calls + 1
				local call_index = run.rebuild_buildable_calls
				-- In pure vanilla mode this is the last observable boundary before stock
				-- RebuildBuildableGrid samples the native terrain. Step-01-on records the same
				-- label from the temporary native sampler immediately after its terrain sync.
				local step01_on = (SuperBigMap.Config or {})
					.EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE == true
				local environment = target_map and target_map.mapdata
					and target_map.mapdata.Environment
				if not step01_on and environment ~= "Underground"
					and not run.fine_terrain_buildable_input_audited then
					run.fine_terrain_buildable_input_audited = true
					local ok_height, height_grid = false, nil
					if type(original_get_height_grid) == "function" then
						ok_height, height_grid = pcall(original_get_height_grid, target_map)
					end
					local ok_type, type_grid = false, nil
					if type(original_get_type_grid) == "function" then
						ok_type, type_grid = pcall(original_get_type_grid, target_map)
					end
					if ok_height and height_grid and ok_type and type_grid then
						local trace_ok, trace_result = pcall(Diagnostics.TraceFineTerrainForensics,
							target_map,
							"FINE_TERRAIN_BUILDABLE_INPUT", height_grid, type_grid, {
								mode = "step01-off", hook = "generator-env-RebuildBuildableGrid",
								call_index = call_index, input_map = MapName(target_map),
							}, { blocks_x = 24, blocks_y = 24 })
						if not trace_ok then
							Log("FINE_TERRAIN_BUILDABLE_INPUT_FAILED", {
								run_id = run.id, proc = CurrentProc(run), mode = "step01-off",
								call_index = call_index, error = tostring(trace_result),
							}, "warn")
						end
					else
						Log("FINE_TERRAIN_BUILDABLE_INPUT_UNAVAILABLE", {
							run_id = run.id, proc = CurrentProc(run), mode = "step01-off",
							call_index = call_index, height_ok = Bool(ok_height),
							type_ok = Bool(ok_type), height_error = tostring(height_grid),
							type_error = tostring(type_grid),
						}, "warn")
					end
				end
				BuildableState(run, target_map, "env-RebuildBuildableGrid-before-" .. tostring(call_index), {
					call_index = call_index, hook = "generator-env", args = DescribePacked(args),
				})
				local rebuild_results = Pack(pcall(saved_env_rebuild_buildable, ...))
				BuildableState(run, target_map, "env-RebuildBuildableGrid-after-" .. tostring(call_index), {
					call_index = call_index, hook = "generator-env", ok = Bool(rebuild_results[1]),
					error = rebuild_results[1] and "none" or tostring(rebuild_results[2]),
				})
				Log("REBUILD_BUILDABLE", {
					run_id = run.id, proc = CurrentProc(run), call_index = call_index,
					hook = "generator-env", args = DescribePacked(args),
					ok = Bool(rebuild_results[1]),
					error = rebuild_results[1] and "none" or tostring(rebuild_results[2]),
					results = rebuild_results[1] and DescribePacked({ n = rebuild_results.n - 1,
						Unpack(rebuild_results, 2, rebuild_results.n) }) or "error",
				})
				if not rebuild_results[1] then error(rebuild_results[2]) end
				return Unpack(rebuild_results, 2, rebuild_results.n)
			end
			env.RebuildBuildableGrid = env_rebuild_buildable_wrapper
		end
		if type(saved_rrand) == "function" then
			rrand_wrapper = function(...)
				local args = Pack(...)
				local rand_before = RandLast(generator)
				local results = Pack(saved_rrand(...))
				run.rrand_calls = run.rrand_calls + 1
				Log("RRAND", {
					run_id = run.id, proc = CurrentProc(run), call_index = run.rrand_calls,
					args = DescribePacked(args), results = DescribePacked(results),
					rand_before = tostring(rand_before), rand_after = tostring(RandLast(generator)),
				})
				return ReturnPacked(results)
			end
			rhelpers[2] = rrand_wrapper
		end
		if type(saved_grand) == "function" then
			grand_wrapper = function(...)
				local args = Pack(...)
				local rand_before = RandLast(generator)
				local results = Pack(saved_grand(...))
				run.grand_calls = run.grand_calls + 1
				local call_index = run.grand_calls
				Log("GRAND", {
					run_id = run.id, proc = CurrentProc(run), call_index = call_index,
					args = DescribePacked(args), results = DescribePacked(results),
					rand_before = tostring(rand_before), rand_after = tostring(RandLast(generator)),
				})
				for i = 1, results.n do
					LogNestedPoints(run, "grand", call_index, results[i], i, "result", {})
				end
				return ReturnPacked(results)
			end
			rhelpers[5] = grand_wrapper
		end
		if type(saved_rm_print) == "function" then
			rm_print_wrapper = function(...)
				run.warning_calls = run.warning_calls + 1
				Log("RMG_PRINT", {
					run_id = run.id, proc = CurrentProc(run), call_index = run.warning_calls,
					args = DescribePacked(Pack(...)),
				})
				return saved_rm_print(...)
			end
			env.rm_print = rm_print_wrapper
		end
		if type(saved_playable) == "function" then
			playable_wrapper = function(...)
				local args = Pack(...)
				run.playable_area_calls = run.playable_area_calls + 1
				local call_index = run.playable_area_calls
				GridAudit(run, "PLAYABLE_HEIGHT_GRID_" .. tostring(call_index), args[1], {
					call_index = call_index, pass_border = tostring(args[2]),
				})
				GridAudit(run, "PLAYABLE_INVALID_MASK_" .. tostring(call_index), args[3], {
					call_index = call_index, pass_border = tostring(args[2]),
				})
				local full_extra = {
					call_index = call_index, pass_border = tostring(args[2]),
					work_step = tostring(env.work_step), map = MapName(map),
				}
				local height_stats = GridFullAudit(run,
					"PLAYABLE_HEIGHT_FULL_" .. tostring(call_index), args[1], full_extra, {
						histogram = false, log_blocks = true,
					})
				local invalid_stats = GridFullAudit(run,
					"PLAYABLE_INVALID_FULL_" .. tostring(call_index), args[3], full_extra, {
						histogram = true, log_blocks = true,
					})
				GridPredicateBitmapAudit(run,
					"PLAYABLE_INVALID_BITMAP_" .. tostring(call_index), args[3],
					"value==0", function(value) return value == 0 end, full_extra)
				Log("PLAYABLE_AREA_NATIVE_BEGIN", {
					run_id = run.id, proc = CurrentProc(run), call_index = call_index,
					args = DescribePacked(args), pass_border = tostring(args[2]),
					work_step = tostring(env.work_step), map_geometry = ScalarFields(MapGeometry(map)),
					invalid_zero_cells = tostring(invalid_stats and invalid_stats.zeros),
					invalid_one_cells = tostring(invalid_stats and invalid_stats.ones),
					height_checksum = height_stats and (tostring(height_stats.checksum_a)
						.. ":" .. tostring(height_stats.checksum_b)) or "unavailable",
				})
				local results = Pack(saved_playable(...))
				GridAudit(run, "PLAYABLE_RESULT_ZONE_" .. tostring(call_index), results[2], {
					call_index = call_index, playable_cells = tostring(results[1]),
				})
				local result_stats = GridFullAudit(run,
					"PLAYABLE_RESULT_FULL_" .. tostring(call_index), results[2], Merge({
						playable_cells = tostring(results[1]),
					}, full_extra), {
						histogram = true, log_blocks = true,
					})
				GridPredicateBitmapAudit(run,
					"PLAYABLE_RESULT_BITMAP_" .. tostring(call_index), results[2],
					"value~=0", function(value) return value ~= 0 end, Merge({
						playable_cells = tostring(results[1]),
					}, full_extra))
				local pass_border = tonumber(args[2]) or 0
				local work_step = tonumber(env.work_step) or 0
				local border_cells = work_step > 0 and math.floor(pass_border / work_step + 0.5) or 0
				local inside_border_width = height_stats
					and math.max(0, height_stats.width - 2 * border_cells) or 0
				local inside_border_height = height_stats
					and math.max(0, height_stats.height - 2 * border_cells) or 0
				local reported_usable = tonumber(results[1])
				local result_nonzero = result_stats and result_stats.nonzero
				local invalid_zero = invalid_stats and invalid_stats.zeros
				Log("PLAYABLE_AREA_ACCOUNTING", {
					run_id = run.id, proc = CurrentProc(run), call_index = call_index,
					pass_border_world = pass_border, work_step = work_step,
					border_cells = border_cells,
					inside_border_width = inside_border_width,
					inside_border_height = inside_border_height,
					inside_border_cells = inside_border_width * inside_border_height,
					invalid_zero_cells = tostring(invalid_zero),
					invalid_one_cells = tostring(invalid_stats and invalid_stats.ones),
					reported_usable_cells = tostring(reported_usable),
					result_nonzero_cells = tostring(result_nonzero),
					result_zero_cells = tostring(result_stats and result_stats.zeros),
					reported_minus_result_nonzero = tostring(reported_usable and result_nonzero
						and (reported_usable - result_nonzero) or nil),
					invalid_zero_minus_reported = tostring(invalid_zero and reported_usable
						and (invalid_zero - reported_usable) or nil),
					usable_fraction_of_invalid_zero = invalid_zero and invalid_zero > 0 and reported_usable
						and string.format("%.9f", reported_usable / invalid_zero) or "n/a",
				})
				Log("PLAYABLE_AREA", {
					run_id = run.id, proc = CurrentProc(run), call_index = call_index,
					args = DescribePacked(args), results = DescribePacked(results),
				})
				return ReturnPacked(results)
			end
			env.GetPlayableArea = playable_wrapper
		end
		if type(saved_factory) == "function" then
			factory_wrapper = function(marker_map, classdef, map_pos, lua_obj, debug_id, ...)
				local rand_before = RandLast(generator)
				local results = Pack(saved_factory(marker_map, classdef, map_pos, lua_obj, debug_id, ...))
				run.factory_calls = run.factory_calls + 1
				local obj = results[1]
				local x, y, z, q, r, hash = PositionIdentity(map_pos)
				local actual_pos = ObjectPos(obj)
				local actual_x, actual_y, actual_z, actual_q, actual_r, actual_hash = PositionIdentity(actual_pos)
				local selected_hash = actual_hash ~= nil and actual_hash or hash
				local coordinate_key = actual_x ~= nil and (tostring(actual_x) .. ":" .. tostring(actual_y))
					or (x ~= nil and (tostring(x) .. ":" .. tostring(y)) or nil)
				local hex_key = actual_q ~= nil and (tostring(actual_q) .. ":" .. tostring(actual_r))
					or (q ~= nil and (tostring(q) .. ":" .. tostring(r)) or nil)
				local duplicate_hash_of = selected_hash ~= nil and run.factory_hashes[tostring(selected_hash)] or nil
				local duplicate_coordinate_of = coordinate_key and run.factory_coordinates[coordinate_key] or nil
				local duplicate_hex_of = hex_key and run.factory_hexes[hex_key] or nil
				if duplicate_hash_of or duplicate_coordinate_of or duplicate_hex_of then
					run.factory_duplicate_calls = run.factory_duplicate_calls + 1
				end
				if selected_hash ~= nil then run.factory_hashes[tostring(selected_hash)] = run.factory_calls end
				if coordinate_key then run.factory_coordinates[coordinate_key] = run.factory_calls end
				if hex_key then run.factory_hexes[hex_key] = run.factory_calls end
				local origin_x, origin_y, width, height = ComparisonRegion(marker_map or map)
				local final_x, final_y = actual_x or x, actual_y or y
				local inside = type(final_x) == "number" and type(final_y) == "number" and width > 0 and height > 0
					and final_x >= origin_x and final_x < origin_x + width
					and final_y >= origin_y and final_y < origin_y + height
				local family, subtype = MarkerFamily(obj or lua_obj)
				Log("FACTORY", {
					run_id = run.id, proc = CurrentProc(run), factory_index = run.factory_calls,
					declared_class = ClassName(classdef), object_class = ClassName(obj),
					family = family, subtype = subtype, debug_id = tostring(debug_id),
					requested_x = tostring(x), requested_y = tostring(y), requested_z = tostring(z),
					requested_q = tostring(q), requested_r = tostring(r), requested_hash = tostring(hash),
					object_x = tostring(actual_x), object_y = tostring(actual_y), object_z = tostring(actual_z),
					object_q = tostring(actual_q), object_r = tostring(actual_r), object_hash = tostring(actual_hash),
					object_position_differs = Bool(actual_x ~= nil and (actual_x ~= x or actual_y ~= y or actual_z ~= z)),
					inside_comparison_region = Bool(inside),
					duplicate_hash_of_factory_index = tostring(duplicate_hash_of),
					duplicate_coordinate_of_factory_index = tostring(duplicate_coordinate_of),
					duplicate_hex_of_factory_index = tostring(duplicate_hex_of),
					marker_fields = MarkerFields(obj or lua_obj or {}), lua_obj = tostring(lua_obj),
					rand_before = tostring(rand_before), rand_after = tostring(RandLast(generator)),
				})
				return ReturnPacked(results)
			end
			env.GenMarkerObj = factory_wrapper
		end
		if type(closure_env) == "table" and type(saved_grid_min_max) == "function" then
			grid_min_max_wrapper = function(...)
				local args = Pack(...)
				local rand_before = RandLast(generator)
				local results = Pack(saved_grid_min_max(...))
				run.grid_min_max_calls = run.grid_min_max_calls + 1
				local call_index = run.grid_min_max_calls
				Log("GRID_MIN_MAX", {
					run_id = run.id, proc = CurrentProc(run), call_index = call_index,
					args = DescribePacked(args), results = DescribePacked(results),
					rand_before = tostring(rand_before), rand_after = tostring(RandLast(generator)),
				})
				for i = 1, results.n do
					LogNestedPoints(run, "GridMinMax", call_index, results[i], i, "result", {})
				end
				return ReturnPacked(results)
			end
			local installed = pcall(function() closure_env.GridMinMax = grid_min_max_wrapper end)
			if not installed then grid_min_max_wrapper = nil end
		end
		if type(closure_env) == "table" and type(saved_hex_align) == "function" then
			hex_align_wrapper = function(...)
				local args = Pack(...)
				local rand_before = RandLast(generator)
				local results = Pack(saved_hex_align(...))
				run.hex_align_calls = run.hex_align_calls + 1
				Log("HEX_ALIGN", {
					run_id = run.id, proc = CurrentProc(run), call_index = run.hex_align_calls,
					args = DescribePacked(args), results = DescribePacked(results),
					rand_before = tostring(rand_before), rand_after = tostring(RandLast(generator)),
				})
				return ReturnPacked(results)
			end
			local installed = pcall(function() closure_env.HexGetNearestCenter = hex_align_wrapper end)
			if not installed then hex_align_wrapper = nil end
		end
		if type(closure_env) == "table" and type(saved_resource_info) == "function" then
			resource_info_wrapper = function(...)
				local args = Pack(...)
				local rand_before = RandLast(generator)
				local results = Pack(saved_resource_info(...))
				run.resource_info_calls = run.resource_info_calls + 1
				Log("RESOURCE_INFO", {
					run_id = run.id, proc = CurrentProc(run), call_index = run.resource_info_calls,
					args = DescribePacked(args), results = DescribePacked(results),
					result_1_fields = ScalarFields(results[1]),
					rand_before = tostring(rand_before), rand_after = tostring(RandLast(generator)),
				})
				return ReturnPacked(results)
			end
			local installed = pcall(function() closure_env.GenerateResourceInfo = resource_info_wrapper end)
			if not installed then resource_info_wrapper = nil end
		end

		local results = Pack(pcall(original_on_generate, generator, env, ...))
		if type(rhelpers) == "table" then
			if rrand_wrapper and rhelpers[2] == rrand_wrapper then rhelpers[2] = saved_rrand end
			if grand_wrapper and rhelpers[5] == grand_wrapper then rhelpers[5] = saved_grand end
		end
		if rm_print_wrapper and env.rm_print == rm_print_wrapper then env.rm_print = saved_rm_print end
		if factory_wrapper and env.GenMarkerObj == factory_wrapper then env.GenMarkerObj = saved_factory end
		if playable_wrapper and env.GetPlayableArea == playable_wrapper then env.GetPlayableArea = saved_playable end
		if env_mask_buildable_wrapper and env.MaskBuildableGrid == env_mask_buildable_wrapper then
			env.MaskBuildableGrid = saved_env_mask_buildable
		end
		if env_rebuild_buildable_wrapper and env.RebuildBuildableGrid == env_rebuild_buildable_wrapper then
			env.RebuildBuildableGrid = saved_env_rebuild_buildable
		end
		if type(closure_env) == "table" then
			if grid_min_max_wrapper and closure_env.GridMinMax == grid_min_max_wrapper then
				pcall(function() closure_env.GridMinMax = saved_grid_min_max end)
			end
			if hex_align_wrapper and closure_env.HexGetNearestCenter == hex_align_wrapper then
				pcall(function() closure_env.HexGetNearestCenter = saved_hex_align end)
			end
			if resource_info_wrapper and closure_env.GenerateResourceInfo == resource_info_wrapper then
				pcall(function() closure_env.GenerateResourceInfo = saved_resource_info end)
			end
		end
		Log("ON_GENERATE_LOGIC_END", {
			run_id = run.id, map = MapName(map), ok = Bool(results[1]),
			error = results[1] and "none" or tostring(results[2]),
			factory_calls = run.factory_calls, warning_calls = run.warning_calls,
			rrand_calls = run.rrand_calls, grand_calls = run.grand_calls,
			playable_area_calls = run.playable_area_calls,
			mask_buildable_calls = run.mask_buildable_calls,
			rebuild_buildable_calls = run.rebuild_buildable_calls,
			grid_min_max_calls = run.grid_min_max_calls, hex_align_calls = run.hex_align_calls,
			resource_info_calls = run.resource_info_calls,
			factory_duplicate_calls = run.factory_duplicate_calls,
		})
		if not results[1] then error(results[2]) end
		return Unpack(results, 2, results.n)
	end

	State.enrichment_spread_generate_wrapper = generate_wrapper
	State.enrichment_spread_do_generate_wrapper = do_generate_wrapper
	State.enrichment_spread_proc_start_wrapper = proc_start_wrapper
	State.enrichment_spread_proc_end_wrapper = proc_end_wrapper
	State.enrichment_spread_on_generate_wrapper = on_generate_wrapper
	generator_class.Generate = generate_wrapper
	generator_class.DoGenerate = do_generate_wrapper
	generator_class.ProcStart = proc_start_wrapper
	generator_class.ProcEnd = proc_end_wrapper
	generator_class.OnGenerateLogic = on_generate_wrapper
	State.enrichment_spread_patch_version = PATCH_VERSION
	Log("PATCH_INSTALLED", { reason = tostring(reason or "module-load"), version = PATCH_VERSION })
	return true
end

SuperBigMap.EnrichmentSpreadDiagnostics = Diagnostics
Diagnostics.PatchGenerator("module-load")

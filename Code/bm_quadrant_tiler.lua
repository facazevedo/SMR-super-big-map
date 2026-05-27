local MOD_PREFIX = "[Bigger Maps] "
local GENERATOR_PATCH_VERSION = 2

local pending_maps = rawget(_G, "BiggerMapsQuadrantPendingMaps")
if type(pending_maps) ~= "table" then
	pending_maps = {}
	rawset(_G, "BiggerMapsQuadrantPendingMaps", pending_maps)
end

local blocked_maps = rawget(_G, "BiggerMapsQuadrantBlockedMaps")
if type(blocked_maps) ~= "table" then
	blocked_maps = {}
	rawset(_G, "BiggerMapsQuadrantBlockedMaps", blocked_maps)
end

local function Global(name)
	return rawget(_G, name)
end

local function TryCall(fn, ...)
	if type(fn) ~= "function" then
		return false
	end

	return pcall(fn, ...)
end

local function SafeCall(fn, ...)
	local ok, result, result2, result3 = TryCall(fn, ...)
	if ok then
		return result, result2, result3
	end
	return nil
end

local function Unpack(t, first, last)
	local unpack_fn = table.unpack or unpack
	return unpack_fn(t, first, last)
end

local function Config()
	local config = Global("BiggerMapsConfig")
	return type(config) == "table" and config or {}
end

local function ConfigNumber(name, default, min_value)
	local value = Config()[name]
	if type(value) == "number" and (min_value == nil or value >= min_value) then
		return value
	end
	return default
end

local function ConfigBool(name, default)
	local value = Config()[name]
	if type(value) == "boolean" then
		return value
	end
	return default
end

local function DebugPrint(text)
	if ConfigBool("EnableDiagnosticLogs", ConfigBool("DebugPrint", true)) and Global("print") then
		print(MOD_PREFIX .. text)
	end
end

local function VerbosePrint(text)
	if ConfigBool("QuadrantCopyVerbose", true) then
		DebugPrint(text)
	end
end

local function RunWithInfiniteLoopPause(reason, fn, ...)
	local pause = Global("PauseInfiniteLoopDetection")
	local resume = Global("ResumeInfiniteLoopDetection")
	if type(pause) == "function" then
		SafeCall(pause, reason)
	end

	local results = { pcall(fn, ...) }

	if type(resume) == "function" then
		SafeCall(resume, reason)
	end

	if not results[1] then
		error(results[2])
	end
	return Unpack(results, 2)
end

local function TerrainSize(map)
	local terrain_api = Global("terrain")
	if terrain_api and type(terrain_api.GetMapSize) == "function" then
		local width, height = SafeCall(terrain_api.GetMapSize, map)
		if width and height then
			return width, height
		end
	end

	if map and type(map.GetMapSize) == "function" then
		local width, height = SafeCall(map.GetMapSize, map)
		if width and height then
			return width, height
		end
	end

	return map and map.Width or 0, map and map.Height or 0
end

local function IsKindOfSafe(obj, class)
	local is_kind_of = Global("IsKindOf")
	if type(is_kind_of) == "function" then
		return SafeCall(is_kind_of, obj, class) == true
	end
	if obj and type(obj.IsKindOf) == "function" then
		return SafeCall(obj.IsKindOf, obj, class) == true
	end
	return false
end

local function ObjectPosition(obj)
	if not obj then
		return false
	end

	if type(obj.GetPos) == "function" then
		local pos = SafeCall(obj.GetPos, obj)
		if pos then
			return pos
		end
	end

	if type(obj.GetVisualPosXYZ) == "function" and type(Global("point")) == "function" then
		local x, y, z = SafeCall(obj.GetVisualPosXYZ, obj)
		if x and y then
			return point(x, y, z or 0)
		end
	end

	return false
end

local function PointXY(pos)
	if not pos then
		return false
	end
	if type(pos.xy) == "function" then
		local x, y = SafeCall(pos.xy, pos)
		return x, y
	end
	if type(pos.x) == "number" and type(pos.y) == "number" then
		return pos.x, pos.y
	end
	return false
end

local function IsInSourceQuadrant(pos, source_width, source_height)
	local x, y = PointXY(pos)
	if not x or not y then
		return false
	end
	return x >= 0 and y >= 0 and x < source_width and y < source_height
end

local skip_clone_classes = {
	City = true,
	MapSector = true,
	RandomMapGeneratorHolder = true,
	RevealedMapSector = true,
}

local skip_clone_kinds = {
	"Building",
	"Colonist",
	"ConstructionSite",
	"DroneBase",
	"BaseRover",
	"RocketBase",
	"ResourceStockpileBase",
	"Unit",
}

local function ShouldSkipObject(obj)
	if not obj or skip_clone_classes[obj.class or false] then
		return true
	end

	if obj.BiggerMapsQuadrantClone then
		return true
	end

	for i = 1, #skip_clone_kinds do
		if IsKindOfSafe(obj, skip_clone_kinds[i]) then
			return true
		end
	end

	return false
end

local function IsGeneratedMapObject(obj)
	if ShouldSkipObject(obj) then
		return false
	end

	local pos = ObjectPosition(obj)
	if not pos then
		return false
	end

	local const_table = Global("const")
	local gof_permanent = const_table and const_table.gofPermanent
	if gof_permanent and type(obj.GetGameFlags) == "function" then
		local flags = SafeCall(obj.GetGameFlags, obj, gof_permanent)
		if flags == 0 then
			return false
		end
	end

	return true, pos
end

local function CopyObjectTransform(source, clone, offset)
	local pos = ObjectPosition(source)
	if pos and type(clone.SetPos) == "function" then
		SafeCall(clone.SetPos, clone, pos + offset)
	end

	if type(source.GetAngle) == "function" and type(clone.SetAngle) == "function" then
		local angle = SafeCall(source.GetAngle, source)
		if angle then
			SafeCall(clone.SetAngle, clone, angle)
		end
	end

	if type(source.GetScale) == "function" and type(clone.SetScale) == "function" then
		local scale = SafeCall(source.GetScale, source)
		if scale then
			SafeCall(clone.SetScale, clone, scale)
		end
	end

	if type(source.GetColorizationPalette) == "function" and type(clone.SetColorizationPalette) == "function" then
		local palette = SafeCall(source.GetColorizationPalette, source)
		if palette then
			SafeCall(clone.SetColorizationPalette, clone, palette)
		end
	end

	if type(source.GetColorsAsTable) == "function" and type(clone.SetColorsFromTable) == "function" then
		local colors = SafeCall(source.GetColorsAsTable, source)
		if colors then
			SafeCall(clone.SetColorsFromTable, clone, colors)
		end
	end

	if type(source.GetGameFlags) == "function" and type(clone.SetGameFlags) == "function" then
		local flags = SafeCall(source.GetGameFlags, source)
		if type(flags) == "number" and flags ~= 0 then
			SafeCall(clone.SetGameFlags, clone, flags)
		end
	end

	if ConfigBool("QuadrantCopyEnumFlags", false) and type(source.GetEnumFlags) == "function" and type(clone.SetEnumFlags) == "function" then
		local flags = SafeCall(source.GetEnumFlags, source)
		if type(flags) == "number" and flags ~= 0 then
			SafeCall(clone.SetEnumFlags, clone, flags)
		end
	end
end

local function CloneObjectAtOffset(map, source, offset)
	local place_object = Global("PlaceObject")
	local pos = ObjectPosition(source)
	if type(place_object) ~= "function" or not pos then
		return false
	end

	local ok, clone = TryCall(place_object, source.class, nil, map, nil, pos + offset)
	if not ok or not clone then
		return false
	end

	if type(clone.CopyProperties) == "function" then
		SafeCall(clone.CopyProperties, clone, source)
	end

	clone.BiggerMapsQuadrantClone = true
	CopyObjectTransform(source, clone, offset)
	return clone
end

local function TileObjects(map, source_width, source_height)
	if not ConfigBool("QuadrantCopyObjects", true) then
		return 0, 0
	end

	local source_objects = {}
	local outside_objects = {}
	local map_for_each = map and map.MapForEach
	if type(map_for_each) ~= "function" then
		return 0, 0
	end

	SafeCall(map_for_each, map, "map", "CObject", function(obj)
		local include, pos = IsGeneratedMapObject(obj)
		if not include then
			return
		end

		if IsInSourceQuadrant(pos, source_width, source_height) then
			source_objects[#source_objects + 1] = obj
		else
			outside_objects[#outside_objects + 1] = obj
		end
	end)

	DebugPrint(string.format(
		"quadrant object scan complete: source=%s outside=%s",
		tostring(#source_objects),
		tostring(#outside_objects)
	))

	if ConfigBool("QuadrantCopyDeleteGeneratedOutsideSource", true) then
		local done_object = Global("DoneObject")
		for i = 1, #outside_objects do
			local obj = outside_objects[i]
			if type(done_object) == "function" then
				SafeCall(done_object, obj)
			elseif type(obj.delete) == "function" then
				SafeCall(obj.delete, obj)
			end
			if i % 1000 == 0 or i == #outside_objects then
				DebugPrint("quadrant outside-object cleanup progress " .. tostring(i) .. "/" .. tostring(#outside_objects))
			end
		end
	end

	local point_fn = Global("point")
	if type(point_fn) ~= "function" then
		return #source_objects, 0
	end

	local offsets = {
		point_fn(source_width, 0, 0),
		point_fn(0, source_height, 0),
		point_fn(source_width, source_height, 0),
	}

	local cloned = 0
	for i = 1, #source_objects do
		local obj = source_objects[i]
		for j = 1, #offsets do
			if CloneObjectAtOffset(map, obj, offsets[j]) then
				cloned = cloned + 1
			end
		end
		if i % 1000 == 0 or i == #source_objects then
			DebugPrint(string.format(
				"quadrant object clone progress %s/%s source, %s clones",
				tostring(i),
				tostring(#source_objects),
				tostring(cloned)
			))
		end
	end

	return #source_objects, cloned
end

local function TileGrid(grid, map_width, map_height, source_width, source_height, label)
	if not grid or type(grid.size) ~= "function" or type(grid.get) ~= "function" or type(grid.set) ~= "function" then
		return false
	end

	local grid_width, grid_height = grid:size()
	if not grid_width or not grid_height or grid_width <= 0 or grid_height <= 0 then
		return false
	end

	local offset_x = math.floor(grid_width * source_width / map_width)
	local offset_y = math.floor(grid_height * source_height / map_height)
	if offset_x <= 0 or offset_y <= 0 or offset_x >= grid_width or offset_y >= grid_height then
		return false
	end

	local source_max_x = math.min(offset_x, grid_width - offset_x - 1)
	local source_max_y = math.min(offset_y, grid_height - offset_y - 1)
	local progress_interval = 512

	DebugPrint(string.format(
		"quadrant %s grid copy begin: grid=%s x %s source=%s x %s offset=%s x %s",
		tostring(label or "terrain"),
		tostring(grid_width),
		tostring(grid_height),
		tostring(source_max_x + 1),
		tostring(source_max_y + 1),
		tostring(offset_x),
		tostring(offset_y)
	))

	for y = 0, source_max_y do
		for x = 0, source_max_x do
			local value = grid:get(x, y)
			grid:set(x + offset_x, y, value)
			grid:set(x, y + offset_y, value)
			grid:set(x + offset_x, y + offset_y, value)
		end
		if y % progress_interval == 0 or y == source_max_y then
			DebugPrint("quadrant " .. tostring(label or "terrain") .. " grid copy row " .. tostring(y + 1) .. "/" .. tostring(source_max_y + 1))
		end
	end

	DebugPrint("quadrant " .. tostring(label or "terrain") .. " grid copy complete")
	return true
end

local function TileTerrain(map, source_width, source_height)
	if not ConfigBool("QuadrantCopyTerrain", true) then
		return false
	end

	local terrain_api = Global("terrain")
	if type(terrain_api) ~= "table" then
		return false
	end

	local map_width, map_height = TerrainSize(map)
	if not map_width or not map_height or map_width <= 0 or map_height <= 0 then
		return false
	end

	local tiled_any = false

	if type(terrain_api.GetHeightGrid) == "function" and type(terrain_api.SetHeightGrid) == "function" then
		DebugPrint("quadrant terrain height grid fetch")
		local height_grid = SafeCall(terrain_api.GetHeightGrid, map)
		if TileGrid(height_grid, map_width, map_height, source_width, source_height, "height") then
			DebugPrint("quadrant terrain height grid apply")
			local ok = TryCall(terrain_api.SetHeightGrid, map, height_grid)
			if not ok then
				TryCall(terrain_api.SetHeightGrid, map, { height_grid = height_grid })
			end
			if type(terrain_api.InvalidateHeight) == "function" then
				SafeCall(terrain_api.InvalidateHeight, map)
			end
			tiled_any = true
		end
	end

	if type(terrain_api.GetTypeGrid) == "function" and type(terrain_api.SetTypeGrid) == "function" then
		DebugPrint("quadrant terrain type grid fetch")
		local type_grid = SafeCall(terrain_api.GetTypeGrid, map)
		if TileGrid(type_grid, map_width, map_height, source_width, source_height, "type") then
			DebugPrint("quadrant terrain type grid apply")
			local ok = TryCall(terrain_api.SetTypeGrid, map, type_grid)
			if not ok then
				TryCall(terrain_api.SetTypeGrid, map, { type_grid = type_grid })
			end
			if type(terrain_api.InvalidateType) == "function" then
				SafeCall(terrain_api.InvalidateType, map)
			end
			tiled_any = true
		end
	end

	if tiled_any and type(terrain_api.RebuildPassability) == "function" then
		DebugPrint("quadrant terrain rebuild passability begin")
		SafeCall(terrain_api.RebuildPassability, map)
		DebugPrint("quadrant terrain rebuild passability complete")
	end

	return tiled_any
end

local function IsEligibleMapData(map_slot, mapdata, map_instance)
	if not ConfigBool("EnableQuadrantMapCopy", false) then
		return false, "feature disabled"
	end

	if ConfigBool("QuadrantCopyMainMapOnly", true) and map_slot ~= 1 then
		return false, "not the main map slot"
	end

	if ConfigBool("QuadrantCopyRandomMapsOnly", true) and not (map_instance and map_instance.RandomMapGenObject) then
		return false, "not a random map generation"
	end

	if type(mapdata) ~= "table" or mapdata.NoTerrain then
		return false, "missing terrain mapdata"
	end

	if ConfigBool("QuadrantCopySurfaceOnly", true) and mapdata.Environment ~= "Surface" then
		return false, "not a surface map"
	end

	if type(mapdata.Width) ~= "number" or type(mapdata.Height) ~= "number" or mapdata.Width <= 0 or mapdata.Height <= 0 then
		return false, "invalid map dimensions"
	end

	if mapdata.Width ~= mapdata.Height then
		return false, "map is not square"
	end

	return true
end

local function StorePendingMap(map_name, pending)
	if map_name and map_name ~= "" then
		pending_maps[map_name] = pending
	end
end

local function AlignDown(value, step)
	step = type(step) == "number" and step > 0 and step or 1
	return math.floor(value / step) * step
end

local function AttachPendingMapState(map)
	if not map then
		return false
	end

	local pending = pending_maps[map.name or false]
	if not pending then
		return false
	end

	map.BiggerMapsQuadrantCopyPending = true
	map.BiggerMapsSourceWidth = pending.source_width
	map.BiggerMapsSourceHeight = pending.source_height
	map.BiggerMapsOriginalWidthTiles = pending.original_width
	map.BiggerMapsOriginalHeightTiles = pending.original_height
	map.BiggerMapsSourceWidthTiles = pending.source_width_tiles
	map.BiggerMapsSourceHeightTiles = pending.source_height_tiles
	map.BiggerMapsDesiredWidthTiles = pending.desired_width
	map.BiggerMapsDesiredHeightTiles = pending.desired_height
	map.BiggerMapsGeneratorWidth = pending.generator_width
	map.BiggerMapsGeneratorHeight = pending.generator_height
	map.BiggerMapsGeneratorWidthTiles = pending.generator_width_tiles
	map.BiggerMapsGeneratorHeightTiles = pending.generator_height_tiles

	VerbosePrint(string.format(
		"attached pending 2x2 quadrant copy to %s (source %s x %s world, %s x %s tiles)",
		tostring(map.name),
		tostring(pending.source_width),
		tostring(pending.source_height),
		tostring(pending.source_width_tiles),
		tostring(pending.source_height_tiles)
	))
	return true
end

local function PrepareMapDataForQuadrantCopy(map_slot, map_name, map_instance, source)
	map_instance = type(map_instance) == "table" and map_instance or {}
	local mapdata = map_instance.mapdata
	local map_data_table = Global("MapData")
	if not mapdata and type(map_data_table) == "table" then
		mapdata = map_data_table[map_name or false]
		map_instance.mapdata = mapdata
	end

	local ok, reason = IsEligibleMapData(map_slot, mapdata, map_instance)
	if not ok then
		VerbosePrint(string.format(
			"quadrant prepare skipped for %s via %s: %s",
			tostring(map_name),
			tostring(source or "ChangingMap"),
			tostring(reason)
		))
		return false
	end

	local scale = math.floor(ConfigNumber("QuadrantCopyScale", 2, 2))
	if scale ~= 2 then
		scale = 2
	end

	local original_width = mapdata.BiggerMapsOriginalWidthTiles or mapdata.Width
	local original_height = mapdata.BiggerMapsOriginalHeightTiles or mapdata.Height
	local requested_width = original_width * scale
	local requested_height = original_height * scale
	local max_terrain_tiles = math.floor(ConfigNumber("QuadrantCopyMaxTerrainTiles", 8192, 1))
	local max_random_tiles = math.floor(ConfigNumber("QuadrantCopyMaxRandomGeneratorTiles", 6144, 1))
	local renderer_align = math.floor(ConfigNumber("QuadrantCopyRendererNodeTileAlignment", 2048, 1))
	local max_tiles = math.min(max_terrain_tiles, max_random_tiles)
	local desired_width = AlignDown(math.min(requested_width, max_tiles), renderer_align)
	local desired_height = AlignDown(math.min(requested_height, max_tiles), renderer_align)
	desired_width = AlignDown(desired_width, scale)
	desired_height = AlignDown(desired_height, scale)
	local source_width_tiles = original_width
	local source_height_tiles = original_height
	local generator_width_tiles = false
	local generator_height_tiles = false
	local height_tile_size = Global("const") and const.HeightTileSize or 1

	if ConfigBool("QuadrantCopyNativeExpansionHack", false) then
		local forced_tiles = math.floor(ConfigNumber("QuadrantCopyForceExpandedTiles", 8192, 1))
		desired_width = AlignDown(math.min(forced_tiles, max_terrain_tiles), renderer_align)
		desired_height = AlignDown(math.min(forced_tiles, max_terrain_tiles), renderer_align)
		desired_width = AlignDown(desired_width, scale)
		desired_height = AlignDown(desired_height, scale)
		local generator_tiles = math.floor(ConfigNumber("QuadrantCopyGeneratorSourceTiles", math.floor(desired_width / scale), 1))
		generator_width_tiles = math.min(generator_tiles, math.floor(desired_width / scale), original_width)
		generator_height_tiles = math.min(generator_tiles, math.floor(desired_height / scale), original_height)
		source_width_tiles = generator_width_tiles
		source_height_tiles = generator_height_tiles
		DebugPrint(string.format(
			"native expansion hack for %s: terrain %s x %s tiles, generator/source quadrant %s x %s tiles",
			tostring(map_name),
			tostring(desired_width),
			tostring(desired_height),
			tostring(source_width_tiles),
			tostring(source_height_tiles)
		))
	else
		if desired_width <= original_width or desired_height <= original_height then
			mapdata.Width = original_width
			mapdata.Height = original_height
			pending_maps[map_name or false] = nil
			if not blocked_maps[map_name or false] then
				blocked_maps[map_name or false] = true
				DebugPrint(string.format(
					"native terrain cap prevents true expansion of %s (%s x %s tiles); leaving map size unchanged",
					tostring(map_name),
					tostring(original_width),
					tostring(original_height)
				))
			end
			return false
		end
	end

	if desired_width <= original_width or desired_height <= original_height then
		mapdata.Width = original_width
		mapdata.Height = original_height
		pending_maps[map_name or false] = nil
		if not blocked_maps[map_name or false] then
			blocked_maps[map_name or false] = true
			DebugPrint(string.format(
				"native terrain cap prevents true expansion of %s (%s x %s tiles); leaving map size unchanged",
				tostring(map_name),
				tostring(original_width),
				tostring(original_height)
			))
		end
		return false
	end

	if desired_width < requested_width or desired_height < requested_height then
		source_width_tiles = math.floor(desired_width / scale)
		source_height_tiles = math.floor(desired_height / scale)
		DebugPrint(string.format(
			"mapgen cap applied for %s: requested %s x %s tiles, using %s x %s tiles with %s x %s source quadrants",
			tostring(map_name),
			tostring(requested_width),
			tostring(requested_height),
			tostring(desired_width),
			tostring(desired_height),
			tostring(source_width_tiles),
			tostring(source_height_tiles)
		))
	end

	if source_width_tiles <= 0 or source_height_tiles <= 0 then
		DebugPrint("quadrant prepare failed: source quadrant would be empty")
		return false
	end

	mapdata.BiggerMapsOriginalWidthTiles = original_width
	mapdata.BiggerMapsOriginalHeightTiles = original_height
	mapdata.BiggerMapsQuadrantCopyScale = scale
	mapdata.BiggerMapsQuadrantSourceWidthTiles = source_width_tiles
	mapdata.BiggerMapsQuadrantSourceHeightTiles = source_height_tiles
	mapdata.Width = desired_width
	mapdata.Height = desired_height

	local pending = {
		source_width = source_width_tiles * height_tile_size,
		source_height = source_height_tiles * height_tile_size,
		generator_width = (generator_width_tiles or source_width_tiles) * height_tile_size,
		generator_height = (generator_height_tiles or source_height_tiles) * height_tile_size,
		original_width = original_width,
		original_height = original_height,
		source_width_tiles = source_width_tiles,
		source_height_tiles = source_height_tiles,
		generator_width_tiles = generator_width_tiles or source_width_tiles,
		generator_height_tiles = generator_height_tiles or source_height_tiles,
		desired_width = desired_width,
		desired_height = desired_height,
	}
	StorePendingMap(map_name, pending)

	map_instance.BiggerMapsQuadrantCopyPending = true
	map_instance.BiggerMapsSourceWidth = pending.source_width
	map_instance.BiggerMapsSourceHeight = pending.source_height
	map_instance.BiggerMapsOriginalWidthTiles = original_width
	map_instance.BiggerMapsOriginalHeightTiles = original_height
	map_instance.BiggerMapsSourceWidthTiles = source_width_tiles
	map_instance.BiggerMapsSourceHeightTiles = source_height_tiles
	map_instance.BiggerMapsDesiredWidthTiles = desired_width
	map_instance.BiggerMapsDesiredHeightTiles = desired_height
	map_instance.BiggerMapsGeneratorWidth = pending.generator_width
	map_instance.BiggerMapsGeneratorHeight = pending.generator_height
	map_instance.BiggerMapsGeneratorWidthTiles = pending.generator_width_tiles
	map_instance.BiggerMapsGeneratorHeightTiles = pending.generator_height_tiles

	DebugPrint(string.format(
		"prepared %s for 2x2 quadrant copy via %s (%s x %s tiles -> %s x %s tiles; source %s x %s tiles)",
		tostring(map_name),
		tostring(source or "ChangingMap"),
		tostring(original_width),
		tostring(original_height),
		tostring(desired_width),
		tostring(desired_height),
		tostring(source_width_tiles),
		tostring(source_height_tiles)
	))
	return true
end

function BiggerMaps_TileQuadrants(map)
	if map and not map.BiggerMapsQuadrantCopyPending then
		AttachPendingMapState(map)
	end

	if not map or not map.BiggerMapsQuadrantCopyPending then
		VerbosePrint("quadrant tile skipped: no pending expanded map")
		return false
	end

	local map_width, map_height = TerrainSize(map)
	local source_width = map.BiggerMapsSourceWidth or math.floor((map_width or 0) / 2)
	local source_height = map.BiggerMapsSourceHeight or math.floor((map_height or 0) / 2)
	if not map_width or not map_height or source_width <= 0 or source_height <= 0 then
		DebugPrint("quadrant tile failed: invalid terrain/source size")
		return false
	end
	if map_width <= source_width or map_height <= source_height then
		DebugPrint(string.format(
			"quadrant tile skipped: map was not expanded before load (%s x %s, source %s x %s)",
			tostring(map_width),
			tostring(map_height),
			tostring(source_width),
			tostring(source_height)
		))
		return false
	end

	DebugPrint(string.format(
		"copying source quadrant across expanded terrain (%s x %s source -> %s x %s map)",
		tostring(source_width),
		tostring(source_height),
		tostring(map_width),
		tostring(map_height)
	))

	local terrain_tiled, source_count, cloned_count = RunWithInfiniteLoopPause("BiggerMapsQuadrantTile", function()
		local tiled = TileTerrain(map, source_width, source_height)
		local source_objects, cloned_objects = TileObjects(map, source_width, source_height)
		return tiled, source_objects, cloned_objects
	end)

	local terrain_api = Global("terrain")
	if terrain_api and type(terrain_api.HashGrids) == "function" and map.mapdata then
		map.mapdata.terrain_hash = SafeCall(terrain_api.HashGrids, map) or map.mapdata.terrain_hash
	end

	local update_radius = Global("UpdateMapMaxObjRadius")
	if type(update_radius) == "function" then
		SafeCall(update_radius, map)
	end

	local apply_bounds = Global("BiggerMaps_Apply")
	if type(apply_bounds) == "function" then
		SafeCall(apply_bounds, map, true)
	end

	map.BiggerMapsQuadrantCopyPending = false
	pending_maps[map.name or false] = nil
	DebugPrint(string.format(
		"2x2 quadrant copy complete on %s (%s x %s); terrain=%s, source objects=%s, cloned objects=%s",
		tostring(map.name),
		tostring(map_width),
		tostring(map_height),
		tostring(terrain_tiled == true),
		tostring(source_count),
		tostring(cloned_count)
	))

	return true
end

function BiggerMaps_PrintQuadrantDebug()
	local current_map = Global("CurrentMap")
	local map_width, map_height = TerrainSize(current_map)
	local mapdata = current_map and current_map.mapdata
	local get_map_name = Global("GetMapName")
	local map_name = type(get_map_name) == "function" and SafeCall(get_map_name) or current_map and current_map.name

	DebugPrint(string.format(
		"quadrant debug: enabled=%s, random-only=%s, current=%s, terrain=%s x %s, mapdata=%s x %s, env=%s, pending=%s, source=%s x %s",
		tostring(ConfigBool("EnableQuadrantMapCopy", false)),
		tostring(ConfigBool("QuadrantCopyRandomMapsOnly", true)),
		tostring(map_name),
		tostring(map_width),
		tostring(map_height),
		tostring(mapdata and mapdata.Width),
		tostring(mapdata and mapdata.Height),
		tostring(mapdata and mapdata.Environment),
		tostring(current_map and current_map.BiggerMapsQuadrantCopyPending),
		tostring(current_map and current_map.BiggerMapsSourceWidth),
		tostring(current_map and current_map.BiggerMapsSourceHeight)
	))
	return true
end

local function PatchRandomMapGenerator()
	if not ConfigBool("QuadrantCopyPatchRandomGenerator", true) then
		VerbosePrint("quadrant random-map generator hook disabled")
		return false
	end

	local generator_class = Global("RandomMapGenerator")
	if type(generator_class) ~= "table" or type(generator_class.Generate) ~= "function" then
		VerbosePrint("quadrant random-map generator hook waiting for class")
		return false
	end

	if generator_class.BiggerMapsQuadrantGeneratePatchVersion == GENERATOR_PATCH_VERSION then
		return true
	end

	local original_generate = generator_class.BiggerMapsQuadrantOriginalGenerate or generator_class.Generate
	local original_do_generate = generator_class.BiggerMapsQuadrantOriginalDoGenerate or generator_class.DoGenerate
	generator_class.BiggerMapsQuadrantOriginalGenerate = original_generate
	generator_class.BiggerMapsQuadrantOriginalDoGenerate = original_do_generate
	generator_class.Generate = function(self, params)
		params = type(params) == "table" and params or {}
		local blank_map = self and self.BlankMap
		local map_name = params.map_name or blank_map
		if blank_map and blank_map ~= "" then
			local map_data_table = Global("MapData")
			local mapdata = type(map_data_table) == "table" and map_data_table[blank_map] or nil
			local instance = {
				mapdata = mapdata,
				RandomMapGenObject = self,
			}
			PrepareMapDataForQuadrantCopy(params.map_slot or 1, map_name, instance, "RandomMapGenerator.Generate")
			if params.map_slot then
				params.mapdata = params.mapdata or instance.mapdata
				params.RandomMapGenObject = params.RandomMapGenObject or self
				params.BiggerMapsQuadrantCopyPending = instance.BiggerMapsQuadrantCopyPending
				params.BiggerMapsSourceWidth = instance.BiggerMapsSourceWidth
				params.BiggerMapsSourceHeight = instance.BiggerMapsSourceHeight
				params.BiggerMapsOriginalWidthTiles = instance.BiggerMapsOriginalWidthTiles
				params.BiggerMapsOriginalHeightTiles = instance.BiggerMapsOriginalHeightTiles
				params.BiggerMapsDesiredWidthTiles = instance.BiggerMapsDesiredWidthTiles
				params.BiggerMapsDesiredHeightTiles = instance.BiggerMapsDesiredHeightTiles
			end
		else
			VerbosePrint("quadrant random-map generator hook skipped: no BlankMap")
		end

		return original_generate(self, params)
	end
	if type(original_do_generate) == "function" then
		generator_class.DoGenerate = function(self, map, ...)
			if not ConfigBool("QuadrantCopyLimitGeneratorToSource", true)
					or not (map and map.BiggerMapsQuadrantCopyPending and map.BiggerMapsGeneratorWidth and map.BiggerMapsGeneratorHeight) then
				return original_do_generate(self, map, ...)
			end

			local generator_width = map.BiggerMapsGeneratorWidth
			local generator_height = map.BiggerMapsGeneratorHeight
			local original_map_get_size = map.GetMapSize
			local terrain_api = Global("terrain")
			local original_terrain_get_size = terrain_api and terrain_api.GetMapSize

			map.GetMapSize = function(target)
				if target == map then
					return generator_width, generator_height
				end
				if type(original_map_get_size) == "function" then
					return original_map_get_size(target)
				end
				return generator_width, generator_height
			end

			if terrain_api and type(original_terrain_get_size) == "function" then
				terrain_api.GetMapSize = function(target)
					if target == map or (target == nil and Global("CurrentMap") == map) then
						return generator_width, generator_height
					end
					return original_terrain_get_size(target)
				end
			end

			DebugPrint(string.format(
				"limiting random generator to source quadrant %s x %s world units",
				tostring(generator_width),
				tostring(generator_height)
			))

			local results = { pcall(original_do_generate, self, map, ...) }

			map.GetMapSize = original_map_get_size
			if terrain_api and original_terrain_get_size then
				terrain_api.GetMapSize = original_terrain_get_size
			end

			if not results[1] then
				error(results[2])
			end
			return Unpack(results, 2)
		end
	end
	generator_class.BiggerMapsQuadrantGeneratePatched = true
	generator_class.BiggerMapsQuadrantGeneratePatchVersion = GENERATOR_PATCH_VERSION
	DebugPrint("quadrant random-map generator hook installed")
	return true
end

local function ChainOnMsg(message_name, handler)
	local previous = OnMsg[message_name]

	OnMsg[message_name] = function(...)
		if previous then
			previous(...)
		end

		handler(...)
	end
end

DebugPrint("quadrant tiler loaded")
PatchRandomMapGenerator()

ChainOnMsg("ClassesPostprocess", function()
	PatchRandomMapGenerator()
end)

ChainOnMsg("DataLoaded", function()
	PatchRandomMapGenerator()
end)

ChainOnMsg("ChangingMap", function(map_slot, map_name, map_instance)
	PrepareMapDataForQuadrantCopy(map_slot, map_name, map_instance, "ChangingMap")
end)

ChainOnMsg("NewMapObject", function(map)
	AttachPendingMapState(map)
end)

ChainOnMsg("MapGenerated", function(map)
	BiggerMaps_TileQuadrants(map)
end)

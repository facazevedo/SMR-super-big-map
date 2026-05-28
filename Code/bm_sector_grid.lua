-- Bigger Maps -- sector grid math (no engine patching).
--
-- Pure query/computation layer for the overview "sector tiles": where the grid
-- sits, how many sectors there are, and each sector's box / name. Sectors are
-- always vanilla-sized (SectorTargetSize, ~40960 world units); only the count and
-- offset vary by Config.SECTOR_GRID. ResolveSectorCount is the single source of the
-- count, fed to both the built grid and const.SectorCount so they cannot disagree.
-- The patching that consumes these (the exploration + highlight modules) lives
-- elsewhere; this module installs nothing global except (via ConfigureGlobalSectorCount)
-- const.SectorCount, which it can restore.

local BiggerMaps = rawget(_G, "BiggerMaps")
if type(BiggerMaps) ~= "table" then
	BiggerMaps = {}
	rawset(_G, "BiggerMaps", BiggerMaps)
end

local Engine = BiggerMaps.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local ClampNumber = Engine.ClampNumber
local Round = Engine.Round

-- Route the module's diagnostics through the centralized logger (scope "Sector").
local function DebugPrint(message)
	local DebugLog = BiggerMaps.DebugLog
	if DebugLog then
		DebugLog.Info("Sector", message)
	end
end

local function cfg_bool(key, default)
	local value = (BiggerMaps.Config or {})[key]
	if type(value) == "boolean" then
		return value
	end
	return default
end

local function cfg_number(key, default, min_value)
	local value = (BiggerMaps.Config or {})[key]
	if type(value) == "number" and (min_value == nil or value >= min_value) then
		return value
	end
	return default
end

local function cfg_value(key)
	return (BiggerMaps.Config or {})[key]
end

local function MapData(map)
	return map and map.mapdata or map
end

local function TerrainSize(map)
	if not map then
		return 0, 0
	end

	if type(map.Width) == "number" and type(map.Height) == "number" and map.Width > 0 and map.Height > 0 then
		return map.Width, map.Height
	end

	if type(map.GetMapSize) == "function" then
		local width, height = SafeCall(map.GetMapSize, map)
		if width and height then
			return width, height
		end
	end

	return 0, 0
end

local function MapTileWorldSize(map)
	local width = TerrainSize(map)
	local mapdata = MapData(map)
	if width and width > 0 and mapdata and type(mapdata.Width) == "number" and mapdata.Width > 0 then
		return width / mapdata.Width
	end

	local const = Global("const")
	if type(const) == "table" and type(const.HeightTileSize) == "number" and const.HeightTileSize > 0 then
		return const.HeightTileSize
	end

	return 100
end

local function OriginalWidthTiles(map)
	local mapdata = MapData(map)
	if cfg_bool("SECTOR_USE_SOURCE_QUADRANT", true) then
		local source = map and map.BiggerMapsSourceWidthTiles
		if type(source) == "number" and source > 0 then
			return source
		end

		source = mapdata and mapdata.BiggerMapsQuadrantSourceWidthTiles
		if type(source) == "number" and source > 0 then
			return source
		end

		source = map and map.BiggerMapsGeneratorWidthTiles
		if type(source) == "number" and source > 0 then
			return source
		end
	end

	local value = map and map.BiggerMapsOriginalWidthTiles
	if type(value) == "number" and value > 0 then
		return value
	end

	value = mapdata and mapdata.BiggerMapsOriginalWidthTiles
	if type(value) == "number" and value > 0 then
		return value
	end

	return cfg_number("SECTOR_BASE_MAP_TILES", 4096, 1)
end

-- The TRUE vanilla sector footprint, in world units. It must never change with
-- map expansion: every sector always stays the size of a vanilla sector.
-- Verified against a full-resolution vanilla sector dump
-- (terrains/sector_15.lua: a 410 x 410 grid at step 100 ~= 40960 world units),
-- which equals source map tiles / vanilla sector count (4096 * 100 / 10 = 40960).
-- No border term: vanilla sectors span essentially the whole source map.
local function SectorTargetSize(map)
	local base_tiles = OriginalWidthTiles(map)
	local base_count = math.floor(cfg_number("SECTOR_BASE_COUNT", 10, 1))
	local target = base_tiles * MapTileWorldSize(map) / base_count
	return math.max(1, Round(target))
end

local function HasExpandedSectorSource(map)
	local mapdata = MapData(map)
	return map and map.BiggerMapsSourceWidthTiles
		or map and map.BiggerMapsGeneratorWidthTiles
		or map and map.BiggerMapsDesiredWidthTiles
		or mapdata and mapdata.BiggerMapsQuadrantSourceWidthTiles
end

local function CustomSectorStatus(map)
	if not cfg_bool("ENABLE_VANILLA_SIZED_SECTORS", true) or not map then
		return false, not map and "no map" or "disabled"
	end

	local mapdata = MapData(map)
	if cfg_bool("SECTOR_SURFACE_ONLY", true) and mapdata and mapdata.Environment ~= "Surface" then
		return false, "not surface"
	end

	if cfg_bool("SECTOR_EXPANDED_ONLY", true) and not HasExpandedSectorSource(map) then
		return false, "not expanded/no source"
	end

	return true, "ok"
end

local function UseCustomSectorsForMap(map)
	return CustomSectorStatus(map)
end

local function SectorCountBounds()
	local min_count = math.floor(cfg_number("SECTOR_MIN_COUNT", 10, 1))
	local max_count = math.floor(cfg_number("SECTOR_MAX_COUNT", 40, 1))
	if max_count < min_count then
		max_count = min_count
	end
	return min_count, max_count
end

-- The grid offset (world units) for the current map: the vanilla-grid alignment
-- offset for "expanded_with_vanilla_grid", else 0. Computed deterministically here
-- (NOT read from mapdata.PassBorder, which the engine and other code reset at
-- various times) so the BUILT grid and the cursor->sector lookup always use the
-- exact same value. If they ever disagree, the hover highlight drifts off the
-- sectors (e.g. sectors built at offset 20480 but the cursor mapped from 0).
local function GridBorder(map)
	if not UseCustomSectorsForMap(map) then
		return 0
	end
	if not cfg_bool("SECTOR_ALIGN_TO_VANILLA_GRID", false) then
		return 0
	end
	local target = SectorTargetSize(map)
	if target <= 0 then
		return 0
	end
	local mapdata = MapData(map)
	local anchor = cfg_value("SECTOR_GRID_ANCHOR")
	if type(anchor) ~= "number" then
		anchor = mapdata and mapdata.BiggerMapsOriginalPassBorder
	end
	if type(anchor) ~= "number" then
		return 0
	end
	return anchor % target
end

-- Resolves the full sector grid for a map. Sectors are always vanilla-sized
-- (SectorTargetSize), laid out uniformly from GridBorder(map). For
-- "expanded_with_vanilla_grid" that offset puts the grid on the vanilla lines and,
-- because the same offset feeds both the build and the cursor lookup, the hover
-- highlight tracks it. SECTOR_FORCED_COUNT, if set, overrides the count.
local function ResolveSectorLayout(map)
	local width, height = TerrainSize(map)
	local border = GridBorder(map)
	local target = SectorTargetSize(map)
	local usable_width = math.max(1, width - 2 * border)
	local usable_height = math.max(1, height - 2 * border)
	local uniform = cfg_bool("SECTOR_UNIFORM_GRID", true)
	local min_count, max_count = SectorCountBounds()

	local forced = cfg_value("SECTOR_FORCED_COUNT")
	forced = (type(forced) == "number" and forced > 0) and ClampNumber(math.floor(forced), min_count, max_count) or nil

	local count_x = forced
	local count_y = forced
	if not count_x then
		count_x = ClampNumber(uniform and Round(usable_width / target) or math.ceil(usable_width / target), min_count, max_count)
		count_y = ClampNumber(uniform and Round(usable_height / target) or math.ceil(usable_height / target), min_count, max_count)
	end

	return {
		border = border,
		count_x = count_x,
		count_y = count_y,
		count = math.max(count_x, count_y),
		target = target,
		step_x = uniform and usable_width / count_x or target,
		step_y = uniform and usable_height / count_y or target,
		uniform = uniform,
		usable_width = usable_width,
		usable_height = usable_height,
		width = width,
		height = height,
	}
end

-- Single source of truth for const.SectorCount: it equals the built grid's count
-- (ResolveSectorLayout) so the two can never disagree. False for maps that keep
-- vanilla sectors or when the terrain size is not available yet.
local function ResolveSectorCount(map)
	if not UseCustomSectorsForMap(map) then
		return false
	end

	local width, height = TerrainSize(map)
	if not width or width <= 0 or not height or height <= 0 then
		return false
	end

	return ResolveSectorLayout(map).count
end

-- The map border (world units) bm_map_bounds imposes so the engine's PassBorder-
-- based selection overlay matches the sectors. Same value the grid is built from
-- (GridBorder), so they can never disagree.
local function ResolveMapBorder(map)
	return GridBorder(map)
end

local function DesiredWidthTiles(map)
	local mapdata = MapData(map)
	local value = map and map.BiggerMapsDesiredWidthTiles
	if type(value) == "number" and value > 0 then
		return value
	end

	value = mapdata and mapdata.Width
	if type(value) == "number" and value > 0 then
		return value
	end

	return false
end

local function SourceWidthTiles(map)
	local mapdata = MapData(map)
	local value = map and (map.BiggerMapsSourceWidthTiles or map.BiggerMapsGeneratorWidthTiles)
	if type(value) == "number" and value > 0 then
		return value
	end

	value = mapdata and mapdata.BiggerMapsQuadrantSourceWidthTiles
	if type(value) == "number" and value > 0 then
		return value
	end

	return OriginalWidthTiles(map)
end

local function BoolText(value)
	return value and "true" or "false"
end

local function MapName(map)
	local mapdata = MapData(map)
	return tostring(map and map.name or mapdata and (mapdata.id or mapdata.name) or "map")
end

local function DescribeMap(map)
	local mapdata = MapData(map)
	local width, height = TerrainSize(map)
	local custom, reason = CustomSectorStatus(map)
	local desired = DesiredWidthTiles(map)
	local source = SourceWidthTiles(map)
	local count = ResolveSectorCount(map) or false

	return string.format(
		"map=%s env=%s terrain=%s x %s mapdata=%s x %s sourceTiles=%s desiredTiles=%s custom=%s reason=%s count=%s const=%s",
		MapName(map),
		tostring(mapdata and mapdata.Environment),
		tostring(width),
		tostring(height),
		tostring(mapdata and mapdata.Width),
		tostring(mapdata and mapdata.Height),
		tostring(source),
		tostring(desired),
		BoolText(custom),
		tostring(reason),
		tostring(count),
		tostring(Global("const") and const.SectorCount)
	)
end

local function ConfigureGlobalSectorCount(map, reason)
	local const = Global("const")
	if type(const) ~= "table" then
		DebugPrint("sector count not configured via " .. tostring(reason) .. ": const missing")
		return false
	end

	local count = ResolveSectorCount(map)
	if not count then
		DebugPrint("sector count not configured via " .. tostring(reason) .. ": " .. DescribeMap(map))
		return false
	end

	local State = BiggerMaps.State
	if State and State.original_sector_count == nil then
		State.original_sector_count = const.SectorCount
	end

	if const.SectorCount ~= count then
		const.SectorCount = count
		DebugPrint(string.format(
			"sector count set to %s via %s",
			tostring(count),
			tostring(reason or "map")
		))
	else
		DebugPrint(string.format(
			"sector count already %s via %s",
			tostring(count),
			tostring(reason or "map")
		))
	end

	return count
end

local function ForEachSector(city, callback)
	local sectors = city and city.MapSectors
	if type(sectors) ~= "table" then
		return
	end

	for col = 1, #sectors do
		local row = sectors[col]
		if type(row) == "table" then
			for sector_row = 1, #row do
				local sector = row[sector_row]
				if sector then
					callback(sector, col, sector_row)
				end
			end
		end
	end
end

local function IndexToLetters(index)
	local letters = ""
	while index > 0 do
		local mod = (index - 1) % 26
		letters = string.char(string.byte("A") + mod) .. letters
		index = math.floor((index - 1) / 26)
	end
	return letters
end

local function SectorName(row, col, count, orient)
	if orient == 0 then
		return IndexToLetters(count - col + 1) .. tostring(row - 1)
	elseif orient == 90 then
		return IndexToLetters(count - row + 1) .. tostring(count - col)
	elseif orient == 180 then
		return IndexToLetters(col) .. tostring(count - row)
	elseif orient == 270 then
		return IndexToLetters(row) .. tostring(col - 1)
	end

	return IndexToLetters(col) .. tostring(row - 1)
end

local function SectorBounds(layout, col, row)
	local x1 = layout.border + Round((col - 1) * layout.step_x)
	local y1 = layout.border + Round((row - 1) * layout.step_y)
	local x2 = col < layout.count_x and layout.border + Round(col * layout.step_x) or layout.border + layout.usable_width
	local y2 = row < layout.count_y and layout.border + Round(row * layout.step_y) or layout.border + layout.usable_height

	return x1, y1, math.max(x1 + 1, x2), math.max(y1 + 1, y2)
end

local SectorGrid = {}

SectorGrid.MapData = MapData
SectorGrid.TerrainSize = TerrainSize
SectorGrid.SectorTargetSize = SectorTargetSize
SectorGrid.CustomSectorStatus = CustomSectorStatus
SectorGrid.UseCustomSectorsForMap = UseCustomSectorsForMap
SectorGrid.GridBorder = GridBorder
SectorGrid.ResolveSectorLayout = ResolveSectorLayout
SectorGrid.ResolveSectorCount = ResolveSectorCount
SectorGrid.ResolveMapBorder = ResolveMapBorder
SectorGrid.DescribeMap = DescribeMap
SectorGrid.ConfigureGlobalSectorCount = ConfigureGlobalSectorCount
SectorGrid.ForEachSector = ForEachSector
SectorGrid.SectorName = SectorName
SectorGrid.SectorBounds = SectorBounds

-- This module patches nothing at enable time; const.SectorCount is configured
-- per-map by the exploration patch. Disabling restores the saved vanilla count.
function SectorGrid.ApplyModBehavior()
end

function SectorGrid.RestoreVanillaBehavior()
	local const = Global("const")
	local State = BiggerMaps.State
	if type(const) == "table" and State and State.original_sector_count ~= nil then
		const.SectorCount = State.original_sector_count
		State.original_sector_count = nil
	end
end

BiggerMaps.SectorGrid = SectorGrid

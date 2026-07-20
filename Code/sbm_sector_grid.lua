-- Super Big Map -- sector grid math (no engine patching).
--
-- Pure query/computation layer for the overview "sector tiles": how many sectors
-- there are and each sector's box/name. Expanded maps always use one corner-anchored
-- grid of vanilla-sized sectors (~40960 world units). ResolveSectorCount is the single source of the
-- count, fed to both the built grid and const.SectorCount so they cannot disagree.
-- The patching that consumes these (the exploration + highlight modules) lives
-- elsewhere; this module installs nothing global except (via ConfigureGlobalSectorCount)
-- const.SectorCount, which it can restore.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local ClampNumber = Engine.ClampNumber
local Round = Engine.Round
local VANILLA_SECTOR_COUNT = 10

local function cfg_bool(key, default)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "boolean" then
		return value
	end
	return default
end

-- PERSISTED "this map was expanded by the mod" marker. The custom mapdata.SuperBigMap* fields
-- the mod sets during generation do NOT survive a save -- mapdata is a PRESET, reloaded fresh
-- on load and never serialized into the save -- so IsModMap couldn't recognise a mod-started
-- save on reload (it warned "started without Super Big Map" and stayed inert on an expanded
-- map). A MapVar is saved/restored PER MAP, so set map.SuperBigMapExpanded = true when the mod
-- expands; it then survives save/load and is the authoritative signal. Guarded so a hot reload
-- (module re-exec) doesn't hit MapVar's "already registered" assert.
do
	local register = Global("MapVar")
	local registry = Global("MapVarValues")
	if type(register) == "function" and (type(registry) ~= "table" or registry["SuperBigMapExpanded"] == nil) then
		register("SuperBigMapExpanded", false)
	end
	-- Separate persisted completion bit for the on-demand underground pipeline. The allocated
	-- underground grid is already full-sized before it is stretched, so dimensions alone cannot
	-- distinguish a pending source-layout map from a completed stretched one after save/load.
	registry = Global("MapVarValues")
	if type(register) == "function" and (type(registry) ~= "table" or registry["SuperBigMapUndergroundPrepared"] == nil) then
		register("SuperBigMapUndergroundPrepared", false)
	end
	registry = Global("MapVarValues")
	if type(register) == "function" and (type(registry) ~= "table" or registry["SuperBigMapUndergroundDeferredGeometry"] == nil) then
		register("SuperBigMapUndergroundDeferredGeometry", false)
	end
	registry = Global("MapVarValues")
	if type(register) == "function" and (type(registry) ~= "table" or registry["SuperBigMapUndergroundPreparationFailed"] == nil) then
		register("SuperBigMapUndergroundPreparationFailed", false)
	end
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

-- The TRUE vanilla sector footprint, in world units. It must never change with
-- map expansion: every sector always stays the size of a vanilla sector.
-- Verified against a full-resolution vanilla sector dump
-- (terrains/sector_15.lua: a 410 x 410 grid at step 100 ~= 40960 world units),
-- which equals vanilla map tiles * vanilla-tile-world-size / vanilla sector
-- count (4096 * 100 / 10 = 40960).
--
-- This is a constant derived from the fixed vanilla baseline: 4096 tiles / 10 sectors.
local function SectorTargetSize(map)
	local base_tiles = 4096
	local base_count = 10
	local const_tbl = Global("const")
	local height_tile = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number" and const_tbl.HeightTileSize > 0)
		and const_tbl.HeightTileSize
		or 100
	local target = base_tiles * height_tile / base_count
	return math.max(1, Round(target))
end

local function HasExpandedSectorSource(map)
	local mapdata = MapData(map)
	return map and map.SuperBigMapSourceWidthTiles
		or map and map.SuperBigMapGeneratorWidthTiles
		or map and map.SuperBigMapDesiredWidthTiles
		or mapdata and mapdata.SuperBigMapSourceWidthTiles
end

-- Single mod-wide predicate: "did THIS mod generate/expand this map?". True for a
-- new game being generated now (the transient map.SuperBigMap* markers are set in
-- PrepareMapDataForExpansion before NewMap fires) AND for a save that was
-- started with the mod active (the mapdata.SuperBigMap* markers persist in the
-- save). False for a vanilla map / an old save started without the mod -- so every
-- per-map mod behavior (bounds reset, custom sector grid, overview reshaping) gates
-- on this and stays completely inert on non-mod maps. The persisted-marker checks
-- (mapdata.SuperBigMapSourceWidthTiles / SuperBigMapOriginalWidthTiles)
-- are what survive a save/load, so they are the authoritative save-type signal.
local function IsModMap(map)
	if not map then
		return false
	end
	-- Never a mod context in the MOD EDITOR test map: it isn't a real game, so the mod
	-- stays fully vanilla there (no bounds/sector/overview reshaping). IsModEditorMap
	-- (engine, GedModEditor.lua) is the authoritative check and is always available;
	-- IsEditorActive -- the world editor -- does NOT exist in normal sessions, which is
	-- why an earlier gate on it never fired.
	local is_mod_editor_map = Global("IsModEditorMap")
	if type(is_mod_editor_map) == "function" then
		local ok, res = pcall(is_mod_editor_map)
		if ok and res then
			return false
		end
	end
	-- Persisted per-map marker (survives save/load) -- set when the mod expands the map.
	if map.SuperBigMapExpanded == true then
		return true
	end
	if HasExpandedSectorSource(map) then
		return true
	end
	local mapdata = MapData(map)
	if mapdata and type(mapdata.SuperBigMapOriginalWidthTiles) == "number" and mapdata.SuperBigMapOriginalWidthTiles > 0 then
		return true
	end
	-- World-to-tile ratio is a SAFE save/load fallback: a vanilla map is always exactly
	-- HeightTileSize world-units per tile (world = tiles x HeightTileSize), whatever its size,
	-- so a ratio above that can only be a mod-expanded map (the native-expansion mode stretches
	-- the world beyond mapdata.Width). Does NOT use mapdata.Width > 4096, which would wrongly
	-- flag a vanilla "Big" map (6144 tiles) and hijack old non-mod saves.
	if mapdata and type(mapdata.Width) == "number" and mapdata.Width > 0 then
		local const_tbl = Global("const")
		local height_tile = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number"
			and const_tbl.HeightTileSize > 0) and const_tbl.HeightTileSize or 100
		local world_w = TerrainSize(map)
		if type(world_w) == "number" and world_w > 0 and (world_w / mapdata.Width) > (height_tile + 1) then
			return true
		end
	end
	return false
end

local function CustomSectorStatus(map)
	if not cfg_bool("ENABLE_EXPANDED_SECTORS", true) or not map then
		return false, not map and "no map" or "expansion disabled"
	end

	local mapdata = MapData(map)
	if mapdata and mapdata.Environment ~= "Surface" then
		-- Expanded UNDERGROUND maps get the 20x20 custom grid too when the underground stretch is
		-- enabled (config STRETCH_UNDERGROUND): same layout math, driven by the same mapdata
		-- markers (SuperBigMapOriginalWidthTiles set by the prepare step). Without this exemption
		-- the underground otherwise keeps vanilla 10x10 sectors over the 8192 allocation.
		local underground_ok = cfg_bool("STRETCH_UNDERGROUND", false)
			and mapdata.Environment == "Underground"
		if not underground_ok then
			return false, "not surface"
		end
	end

	local is_mod_map = IsModMap(map)
	if not is_mod_map then
		return false, "not a Super Big Map-expanded map"
	end

	return true, "ok"
end

local function UseCustomSectorsForMap(map)
	return CustomSectorStatus(map)
end

local function SectorCountBounds()
	return 10, 40
end

-- Expanded sectors are always anchored at the terrain origin.
local function GridBorder(map)
	return 0
end

-- Stable terrain size in WORLD UNITS = mapdata tile count x the fixed engine tile
-- size (const.HeightTileSize). This is the mod's canonical map-size definition (see
-- sbm_map_generation MapSize) and the AUTHORITATIVE, deterministic terrain size.
--
-- The live terrain read can temporarily expose an in-progress MapArea during generation.
-- mapdata.Width and mapdata.Height are the stable final tile dimensions, so sector layout
-- is derived from them whenever they are available.
-- Returns false when mapdata size is unavailable (caller falls back to the live read).
local function StableTerrainSize(map)
	local mapdata = MapData(map)
	if not mapdata then
		return false
	end
	local wt, ht = mapdata.Width, mapdata.Height
	if type(wt) ~= "number" or wt <= 0 or type(ht) ~= "number" or ht <= 0 then
		return false
	end
	local const_tbl = Global("const")
	local tile = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number" and const_tbl.HeightTileSize > 0)
		and const_tbl.HeightTileSize or 100
	return wt * tile, ht * tile
end

-- Resolves the one supported expanded grid: corner anchored, count derived from
-- the vanilla sector footprint, and stretched by any fractional remainder so the
-- grid covers the complete destination exactly.
local function ResolveSectorLayout(map)
	local width, height = TerrainSize(map)
	-- Prefer the stable mapdata-derived terrain size over the live read so the grid is
	-- deterministic and never baked at 2x from a transient oversized terrain read (the
	-- intermittent "cannot expand" on Big maps). In correct cases the two are identical;
	-- this only corrects the transient 2x. Falls back to the live read if unavailable.
	local stable_w, stable_h = StableTerrainSize(map)
	if type(stable_w) == "number" and stable_w > 0 and type(stable_h) == "number" and stable_h > 0 then
		width, height = stable_w, stable_h
	end
	local border = GridBorder(map)
	local target = SectorTargetSize(map)
	local usable_width = math.max(1, width - 2 * border)
	local usable_height = math.max(1, height - 2 * border)
	local min_count, max_count = SectorCountBounds()
	local count_x = ClampNumber(Round(usable_width / target), min_count, max_count)
	local count_y = ClampNumber(Round(usable_height / target), min_count, max_count)
	local step_x = usable_width / count_x
	local step_y = usable_height / count_y


	return {
		border = border,
		count_x = count_x,
		count_y = count_y,
		count = math.max(count_x, count_y),
		target = target,
		step_x = step_x,
		step_y = step_y,
		uniform = true,
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

-- The map border (world units) sbm_map_bounds imposes so the engine's PassBorder-
-- based selection overlay matches the sectors. Same value the grid is built from
-- (GridBorder), so they can never disagree.
local function ResolveMapBorder(map)
	return GridBorder(map)
end

local function DesiredWidthTiles(map)
	local mapdata = MapData(map)
	local value = map and map.SuperBigMapDesiredWidthTiles
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
	local value = map and (map.SuperBigMapSourceWidthTiles or map.SuperBigMapGeneratorWidthTiles)
	if type(value) == "number" and value > 0 then
		return value
	end

	value = mapdata and mapdata.SuperBigMapSourceWidthTiles
	if type(value) == "number" and value > 0 then
		return value
	end

	value = map and map.SuperBigMapOriginalWidthTiles
	if type(value) == "number" and value > 0 then
		return value
	end
	return mapdata and mapdata.SuperBigMapOriginalWidthTiles or 4096
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
		return false
	end

	local count = ResolveSectorCount(map)
	if not count then
		return false
	end

	local State = SuperBigMap.State
	-- const.SectorCount is process-global, not map-local.  Capture the engine baseline
	-- independently of the current value: the current value may still be 20 after an
	-- expanded map if a menu transition bypassed teardown.
	if State and State.vanilla_sector_count == nil then
		State.vanilla_sector_count = VANILLA_SECTOR_COUNT
	end
	if State and State.original_sector_count == nil then
		State.original_sector_count = State.vanilla_sector_count or VANILLA_SECTOR_COUNT
	end

	if const.SectorCount ~= count then
		const.SectorCount = count
	end

	return count
end

-- Restore the process-global sector count before vanilla builds a city.  This is
-- deliberately callable while the mod's wrappers remain installed: a non-expanded
-- map must receive the same 10-sector input as an unmodified process even if the
-- main-menu teardown hook was replaced or missed.
local function NormalizeVanillaSectorCount(reason)
	local const = Global("const")
	if type(const) ~= "table" then
		return false
	end
	local State = SuperBigMap.State
	if State and State.vanilla_sector_count == nil then
		State.vanilla_sector_count = VANILLA_SECTOR_COUNT
	end
	const.SectorCount = (State and State.vanilla_sector_count) or VANILLA_SECTOR_COUNT
	return const.SectorCount
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

-- Visible labels are intentionally separate from MapSector.id. Vanilla names the
-- letter axis from right to left; keep that stable internal identity for queues,
-- saves, and diagnostics, but present the expanded grid in the conventional
-- left-to-right order requested by the player. OverviewOrientation changes which
-- world axis is horizontal, so mirror the letter component for each rotation while
-- leaving vanilla's row-number direction untouched.
local function SectorDisplayName(row, col, count, orient)
	if orient == 0 then
		return IndexToLetters(col) .. tostring(row - 1)
	elseif orient == 90 then
		return IndexToLetters(row) .. tostring(count - col)
	elseif orient == 180 then
		return IndexToLetters(count - col + 1) .. tostring(count - row)
	elseif orient == 270 then
		return IndexToLetters(count - row + 1) .. tostring(col - 1)
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
SectorGrid.IsModMap = IsModMap
SectorGrid.GridBorder = GridBorder
SectorGrid.ResolveSectorLayout = ResolveSectorLayout
SectorGrid.ResolveSectorCount = ResolveSectorCount
SectorGrid.ResolveMapBorder = ResolveMapBorder
SectorGrid.DescribeMap = DescribeMap
SectorGrid.ConfigureGlobalSectorCount = ConfigureGlobalSectorCount
SectorGrid.NormalizeVanillaSectorCount = NormalizeVanillaSectorCount
SectorGrid.VanillaSectorCount = function() return VANILLA_SECTOR_COUNT end
SectorGrid.ForEachSector = ForEachSector
SectorGrid.SectorName = SectorName
SectorGrid.SectorDisplayName = SectorDisplayName
SectorGrid.SectorBounds = SectorBounds

-- This module patches nothing at enable time; const.SectorCount is configured
-- per-map by the exploration patch. Disabling restores the saved vanilla count.
function SectorGrid.ApplyModBehavior()
end

function SectorGrid.RestoreVanillaBehavior()
	local State = SuperBigMap.State
	NormalizeVanillaSectorCount("SectorGrid.RestoreVanillaBehavior")
	if State then
		State.original_sector_count = nil
	end
end

SuperBigMap.SectorGrid = SectorGrid

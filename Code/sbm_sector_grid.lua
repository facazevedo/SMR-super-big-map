-- Super Big Map -- sector grid math (no engine patching).
--
-- Pure query/computation layer for the overview "sector tiles": where the grid
-- sits, how many sectors there are, and each sector's box / name. Sectors are
-- always vanilla-sized (SectorTargetSize, ~40960 world units); only the count and
-- offset vary by Config.SECTOR_GRID. ResolveSectorCount is the single source of the
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

-- Route the module's diagnostics through the centralized logger (scope "Sector").
local function DebugPrint(message)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Sector", message)
	end
end

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
end

local function cfg_number(key, default, min_value)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "number" and (min_value == nil or value >= min_value) then
		return value
	end
	return default
end

local function cfg_value(key)
	return (SuperBigMap.Config or {})[key]
end

-- Gated sector-SIZING diagnostics, de-duplicated per tag so frequently-called
-- functions (TerrainSize, ResolveSectorLayout via the cursor) don't spam -- a line
-- prints only when its message changes. Controlled by config.DebugSectorSizing.
local sizing_diag_last = {}
local function SizingDiag(tag, msg)
	local DebugLog = SuperBigMap.DebugLog
	if not (DebugLog and DebugLog.On("SectorSizing")) then
		return
	end
	if sizing_diag_last[tag] == msg then
		return
	end
	sizing_diag_last[tag] = msg
	DebugLog.Info("SectorSizing", msg, { tag = "grid/" .. tostring(tag) })
end

local function MapData(map)
	return map and map.mapdata or map
end

local function TerrainSize(map)
	if not map then
		return 0, 0
	end

	if type(map.Width) == "number" and type(map.Height) == "number" and map.Width > 0 and map.Height > 0 then
		SizingDiag("TerrainSize", string.format("TerrainSize via map.Width = %sx%s", tostring(map.Width), tostring(map.Height)))
		return map.Width, map.Height
	end

	if type(map.GetMapSize) == "function" then
		local width, height = SafeCall(map.GetMapSize, map)
		if width and height then
			SizingDiag("TerrainSize", string.format("TerrainSize via map:GetMapSize = %sx%s", tostring(width), tostring(height)))
			return width, height
		end
	end

	SizingDiag("TerrainSize", "TerrainSize FAILED -> 0,0 (map.Width and map:GetMapSize unavailable)")
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
		local source = map and map.SuperBigMapSourceWidthTiles
		if type(source) == "number" and source > 0 then
			return source
		end

		source = mapdata and mapdata.SuperBigMapQuadrantSourceWidthTiles
		if type(source) == "number" and source > 0 then
			return source
		end

		source = map and map.SuperBigMapGeneratorWidthTiles
		if type(source) == "number" and source > 0 then
			return source
		end
	end

	local value = map and map.SuperBigMapOriginalWidthTiles
	if type(value) == "number" and value > 0 then
		return value
	end

	value = mapdata and mapdata.SuperBigMapOriginalWidthTiles
	if type(value) == "number" and value > 0 then
		return value
	end

	return cfg_number("SECTOR_BASE_MAP_TILES", 4096, 1)
end

-- The TRUE vanilla sector footprint, in world units. It must never change with
-- map expansion: every sector always stays the size of a vanilla sector.
-- Verified against a full-resolution vanilla sector dump
-- (terrains/sector_15.lua: a 410 x 410 grid at step 100 ~= 40960 world units),
-- which equals vanilla map tiles * vanilla-tile-world-size / vanilla sector
-- count (4096 * 100 / 10 = 40960).
--
-- This is a CONSTANT derived from the fixed vanilla baseline (SECTOR_BASE_MAP_
-- TILES = 4096, SECTOR_BASE_COUNT = 10), NOT from the current map's source
-- quadrant size. Earlier this used OriginalWidthTiles(map), which returns the
-- generated source size -- fine in 2x2 mode (source = 4096 = 10 sectors -> 40960)
-- but WRONG in frame-expansion mode where the source is the full native map
-- (e.g. 6144 = 15 sectors -> 6144/10 = 61440 oversized sectors, giving a 13x13
-- grid instead of 20x20). The vanilla sector footprint never depends on how big
-- the generated region is, so we always use the fixed 4096/10 baseline.
local function SectorTargetSize(map)
	local base_tiles = math.floor(cfg_number("SECTOR_BASE_MAP_TILES", 4096, 1))
	local base_count = math.floor(cfg_number("SECTOR_BASE_COUNT", 10, 1))
	local const_tbl = Global("const")
	local height_tile = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number" and const_tbl.HeightTileSize > 0)
		and const_tbl.HeightTileSize
		or 100
	local target = base_tiles * height_tile / base_count
	SizingDiag("SectorTargetSize", string.format(
		"SectorTargetSize: base_tiles=%s base_count=%s height_tile=%s -> target=%s",
		tostring(base_tiles), tostring(base_count), tostring(height_tile), tostring(math.max(1, Round(target)))))
	return math.max(1, Round(target))
end

local function HasExpandedSectorSource(map)
	local mapdata = MapData(map)
	return map and map.SuperBigMapSourceWidthTiles
		or map and map.SuperBigMapGeneratorWidthTiles
		or map and map.SuperBigMapDesiredWidthTiles
		or mapdata and mapdata.SuperBigMapQuadrantSourceWidthTiles
end

-- Single mod-wide predicate: "did THIS mod generate/expand this map?". True for a
-- new game being generated now (the transient map.SuperBigMap* markers are set in
-- PrepareMapDataForQuadrantCopy before NewMap fires) AND for a save that was
-- started with the mod active (the mapdata.SuperBigMap* markers persist in the
-- save). False for a vanilla map / an old save started without the mod -- so every
-- per-map mod behavior (bounds reset, custom sector grid, overview reshaping) gates
-- on this and stays completely inert on non-mod maps. The persisted-marker checks
-- (mapdata.SuperBigMapQuadrantSourceWidthTiles / SuperBigMapOriginalWidthTiles)
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
	if not cfg_bool("ENABLE_VANILLA_SIZED_SECTORS", true) or not map then
		return false, not map and "no map" or "disabled"
	end

	local mapdata = MapData(map)
	if cfg_bool("SECTOR_SURFACE_ONLY", true) and mapdata and mapdata.Environment ~= "Surface" then
		-- Expanded UNDERGROUND maps get the 20x20 custom grid too when the underground stretch is
		-- enabled (config STRETCH_UNDERGROUND): same layout math, driven by the same mapdata
		-- markers (SuperBigMapOriginalWidthTiles set by the prepare step). Without this exemption
		-- the underground keeps vanilla 10x10 sectors over the 8192 allocation -- the Sector logs
		-- showed exactly "custom=false reason=not surface" for BlankUnderground_01.
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

	local has_expanded_marker = HasExpandedSectorSource(map)
		or map.SuperBigMapExpanded == true
		or (mapdata and type(mapdata.SuperBigMapOriginalWidthTiles) == "number" and mapdata.SuperBigMapOriginalWidthTiles > 0)
	if cfg_bool("SECTOR_EXPANDED_ONLY", true) and not has_expanded_marker then
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
		anchor = mapdata and mapdata.SuperBigMapOriginalPassBorder
	end
	if type(anchor) ~= "number" then
		return 0
	end
	return anchor % target
end

-- Stable terrain size in WORLD UNITS = mapdata tile count x the fixed engine tile
-- size (const.HeightTileSize). This is the mod's canonical map-size definition (see
-- sbm_map_generation MapSize) and the AUTHORITATIVE, deterministic terrain size.
--
-- It exists because the LIVE terrain read (map.Width / map:GetMapSize, via TerrainSize)
-- can transiently report DOUBLE the true size during the new-game expansion/bounds flux
-- -- it returns the oversized MapArea before the engine finalizes terrain. Feeding that
-- 2x width into ResolveSectorLayout bakes a 2x-oversized grid (count 20 x step 81920 ->
-- MapArea 2x terrain), which then fails the 20x20 fit check with "block outside terrain"
-- -- the INTERMITTENT "cannot expand" on the 8192-tile "Big" maps (same map sometimes
-- expands, sometimes does not, purely on load timing). mapdata.Width never suffers that
-- transient (it is the final tile count, consistent with the real terrain), so deriving
-- the layout from it makes the grid deterministic regardless of when it is computed.
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

-- Resolves the full sector grid for a map. Sectors are always vanilla-sized
-- (SectorTargetSize), laid out from GridBorder(map). Two layout modes:
--   * Stretch-to-fit (default, "expanded"): count = round(usable / target), each
--     sector slightly stretched so step = usable/count and the grid fills the
--     usable area exactly with no remainder.
--   * Drop partials ("expanded_with_vanilla_grid"): count = floor(usable / target),
--     step = exactly target. The grid covers count*target world units inside the
--     usable area; whatever doesn't fit (the partial sectors at the far edge) is
--     left as a margin and not included as a sector.
-- For "expanded_with_vanilla_grid" the vanilla-PassBorder offset puts the grid
-- on the vanilla lines; because the same offset feeds both the build and the
-- cursor lookup, the hover highlight tracks the grid. SECTOR_FORCED_COUNT, if
-- set, overrides the count.
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
	local uniform = cfg_bool("SECTOR_UNIFORM_GRID", true)
	local drop_partials = cfg_bool("SECTOR_ALIGN_TO_VANILLA_GRID", false)
	local min_count, max_count = SectorCountBounds()

	local forced = cfg_value("SECTOR_FORCED_COUNT")
	forced = (type(forced) == "number" and forced > 0) and ClampNumber(math.floor(forced), min_count, max_count) or nil

	local count_x = forced
	local count_y = forced
	if not count_x then
		if drop_partials then
			count_x = ClampNumber(math.floor(usable_width / target), min_count, max_count)
			count_y = ClampNumber(math.floor(usable_height / target), min_count, max_count)
		else
			count_x = ClampNumber(uniform and Round(usable_width / target) or math.ceil(usable_width / target), min_count, max_count)
			count_y = ClampNumber(uniform and Round(usable_height / target) or math.ceil(usable_height / target), min_count, max_count)
		end
	end

	-- step_x/step_y is the world-unit pitch between adjacent sectors. With
	-- drop-partials it is exactly the vanilla sector size; with stretch-to-fit
	-- it is usable/count so the grid spans the whole usable area.
	local step_x, step_y
	if drop_partials then
		step_x = target
		step_y = target
	elseif uniform then
		step_x = usable_width / count_x
		step_y = usable_height / count_y
	else
		step_x = target
		step_y = target
	end

	SizingDiag("ResolveSectorLayout", string.format(
		"ResolveSectorLayout: terrain=%sx%s usable=%sx%s target=%s border=%s -> count=%sx%s step=%sx%s (uniform=%s drop_partials=%s) [step*count=%sx%s]",
		tostring(Round(width)), tostring(Round(height)),
		tostring(Round(usable_width)), tostring(Round(usable_height)),
		tostring(target), tostring(Round(border)),
		tostring(count_x), tostring(count_y),
		tostring(Round(step_x)), tostring(Round(step_y)),
		tostring(uniform), tostring(drop_partials),
		tostring(Round(step_x * count_x)), tostring(Round(step_y * count_y))))

	return {
		border = border,
		count_x = count_x,
		count_y = count_y,
		count = math.max(count_x, count_y),
		target = target,
		step_x = step_x,
		step_y = step_y,
		uniform = uniform,
		drop_partials = drop_partials,
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

	value = mapdata and mapdata.SuperBigMapQuadrantSourceWidthTiles
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

	local State = SuperBigMap.State
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
	local x2, y2
	if layout.drop_partials then
		-- Each sector is exactly step (= vanilla sector size). The far edge
		-- stops at count*step + border, leaving a margin up to the map edge --
		-- the partial sectors are intentionally NOT included.
		x2 = layout.border + Round(col * layout.step_x)
		y2 = layout.border + Round(row * layout.step_y)
	else
		x2 = col < layout.count_x and layout.border + Round(col * layout.step_x) or layout.border + layout.usable_width
		y2 = row < layout.count_y and layout.border + Round(row * layout.step_y) or layout.border + layout.usable_height
	end

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
SectorGrid.ForEachSector = ForEachSector
SectorGrid.SectorName = SectorName
SectorGrid.SectorBounds = SectorBounds

-- This module patches nothing at enable time; const.SectorCount is configured
-- per-map by the exploration patch. Disabling restores the saved vanilla count.
function SectorGrid.ApplyModBehavior()
end

function SectorGrid.RestoreVanillaBehavior()
	local const = Global("const")
	local State = SuperBigMap.State
	if type(const) == "table" and State and State.original_sector_count ~= nil then
		const.SectorCount = State.original_sector_count
		State.original_sector_count = nil
	end
end

SuperBigMap.SectorGrid = SectorGrid

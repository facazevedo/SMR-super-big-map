-- Bigger Maps configuration.
-- Edit these values, then reload the mod or restart the game.

-- Private builder table (NOT a global). The raw settings below are read once into
-- the typed BiggerMaps.Config view at the bottom of this file; every module reads
-- that view. The bundled third-party ZoomPlus.lua used to read a global
-- BiggerMapsConfig, but it degrades safely without one (its fallback uses the same
-- multiplier 4.0 / scenario-editor-host = true configured here) and the ZoomPlus
-- integration also drives it directly, so no global config table is exported.
local config = {}

-- ============================================================================
-- MAIN SETTINGS: map size and sector grid
-- ============================================================================
-- These two values are the primary controls for the mod. The detailed flags in
-- the "Experimental ..." sections below are DERIVED from them, so in normal use
-- you only edit these two lines. Set BOTH to "original" for plain, unmodified
-- vanilla Surviving Mars behaviour.
--
-- config.BiggerMapsTerrainSize -- how large the playable terrain is:
--     "original"  Vanilla map size. No expansion: the game builds and renders
--                 its normal terrain. (Vanilla configuration.)
--     "expanded"  2x2 native expansion. The mod allocates an 8192-tile map, has
--                 the generator produce only a 4096-tile top-left source
--                 quadrant, then copies that quadrant into the other three
--                 quadrants -- about 4x the vanilla play area on a single map.
--                 Applies to random Surface maps only; everything else (e.g.
--                 underground breakthroughs) stays vanilla.
--
-- config.BiggerMapsSectorGrid -- how the overview "sector tiles" (the lettered
--                                scan grid you see in overview) are laid out.
--                                Sectors are always vanilla-sized (~40960 world
--                                units / 410 tiles, never changes); the options
--                                differ in count and grid position:
--     "original"                Vanilla: a 10 x 10 grid over the bordered PLAYABLE
--                               area only -- the map's outer border is left out of
--                               the grid, exactly like the unmodified game. The mod
--                               does not touch sectors or bounds. (Vanilla.)
--     "expanded"                Clean grid from the map corner (0,0): 20 x 20 full
--                               vanilla-sized sectors on the 8192 map, no partials.
--                               The whole terrain is made playable. RECOMMENDED:
--                               this matches the engine's own overview/selection
--                               grid (which the engine always anchors at the map
--                               corner), so the hover highlight lines up with the
--                               sectors and you can click them precisely.
--     "expanded_with_vanilla_grid"
--                               Same vanilla-sized sectors, but the grid is shifted
--                               to the ORIGINAL map's grid offset so the lines match
--                               where vanilla drew them. CAVEAT: the engine's hover-
--                               highlight is hard-anchored at the map corner and
--                               cannot be moved from Lua, so with this option the
--                               selection highlight does NOT line up with the shifted
--                               grid (you can't reliably click a sector). Use only if
--                               you care about the grid lines' position over clicking.
--
-- Recommended combinations:
--     "expanded" + "expanded"                    big 8192 map, clean grid, working selection (default)
--     "original" + "original"                    completely vanilla map and sectors
--     "expanded" + "expanded_with_vanilla_grid"  vanilla-aligned grid lines, but selection is offset
-- ============================================================================
config.BiggerMapsTerrainSize = "expanded"
config.BiggerMapsSectorGrid = "expanded_with_vanilla_grid"

-- Derived from the two settings above (edit the settings, not these helpers).
local bm_expanded_terrain = config.BiggerMapsTerrainSize == "expanded"
local bm_align_vanilla_grid = config.BiggerMapsSectorGrid == "expanded_with_vanilla_grid"
local bm_expanded_grid = config.BiggerMapsSectorGrid == "expanded" or bm_align_vanilla_grid
-- Enlarge the playable area to the full terrain (border included) whenever the
-- terrain or the sector grid is expanded; "original" + "original" leaves the
-- vanilla border untouched. Read by BiggerMaps.lua.
config.BiggerMapsFullMapPlayable = bm_expanded_terrain or bm_expanded_grid

-- Normal camera zoom. ZoomPlus applies:
-- LookatDistZoomOut = original.LookatDistZoomOut * ZoomPlusLookatDistZoomOutMultiplier.
config.EnableNormalZoomPlus = true
config.ZoomPlusLookatDistZoomOutMultiplier = 4.0
config.NormalZoomMultiplier = config.ZoomPlusLookatDistZoomOutMultiplier
config.AllowZoomPlusWithScenarioEditorHost = true

-- Overview camera distance and field of view.
-- Percent values scale from the loaded terrain size.
-- Larger zoom distance values put the overview camera farther away.
config.OverviewZoomDistancePercent = 140
config.OverviewCameraXYPercent = 28
config.OverviewDistanceMultiplier =120
config.OverviewMinHeightPercent = 140
-- Screen-space overview framing nudges, also percent of terrain size.
-- Positive horizontal moves the overview focus right; negative moves it left.
-- Positive vertical moves the overview focus up; negative moves it down.
-- If a direction feels inverted for your current overview angle, use a negative value.
config.OverviewNudgeHorizontalPercent = 0
config.OverviewNudgeVerticalPercent = 0
-- Horizontal rotation of the overview camera, in degrees. Vanilla starts at 45.
-- Set to false to let the game use its normal overview angle.
config.OverviewViewAngleDegrees = 45
config.OverviewFovX16_9 = 3600
config.OverviewFovX4_3 = 3400
config.OverviewFarZ = 12000000

-- Hide the dark overview map curtains around the visible map.
config.HideOverviewCurtains = true

-- Print Bigger Maps status and diagnostic messages in the game console/log.
-- Turn this off once the experimental map/sector flow is stable.
config.EnableDiagnosticLogs = true
config.DebugPrint = true

-- Experimental 2x2 map tiling. Controlled by BiggerMapsTerrainSize above
-- ("expanded" enables it, "original" disables it). New random surface maps are
-- created larger, then the source quadrant is copied into the other quadrants.
config.EnableQuadrantMapCopy = bm_expanded_terrain
config.QuadrantCopyScale = 2
config.QuadrantCopyMaxTerrainTiles = 8192
-- The random map generator's stable-position helper asserts around 8192
-- terrain tiles, while the renderer rejects some intermediate sizes. 6144 is
-- the largest renderer-safe random blank map size confirmed so far.
config.QuadrantCopyMaxRandomGeneratorTiles = 6144
config.QuadrantCopyRendererNodeTileAlignment = 2048
-- Experimental native-size hack: allocate an 8192 map, generate only a 4096
-- top-left source quadrant, then tile that quadrant into the rest of the map.
-- Enabled together with BiggerMapsTerrainSize = "expanded".
config.QuadrantCopyNativeExpansionHack = bm_expanded_terrain
config.QuadrantCopyForceExpandedTiles = 8192
config.QuadrantCopyGeneratorSourceTiles = 4096
config.QuadrantCopyLimitGeneratorToSource = true
config.QuadrantCopyMainMapOnly = true
config.QuadrantCopySurfaceOnly = true
config.QuadrantCopyRandomMapsOnly = true
config.QuadrantCopyPatchRandomGenerator = true
config.QuadrantCopyVerbose = false
config.QuadrantCopyTerrain = true
config.QuadrantCopyObjects = true
config.QuadrantCopyEnumFlags = false
config.QuadrantCopyDeleteGeneratedOutsideSource = true

-- Experimental sector (overview-grid) layout, used only when BiggerMapsSectorGrid
-- is "expanded". The mod divides the whole map into vanilla-sized sectors;
-- ResolveSectorCount feeds both the built grid and const.SectorCount from the
-- same value, so they always match. When BiggerMapsSectorGrid is "original" the
-- whole patch stays out of the way (EnableVanillaSizedSectors = false) and the
-- game builds its normal 10 x 10 playable-area grid.
config.EnableVanillaSizedSectors = bm_expanded_grid
config.VanillaSectorUniformGrid = true
config.VanillaSectorUseSourceQuadrant = true
config.VanillaSectorSurfaceOnly = true
-- The expanded grid covers the whole loaded map, so it is not restricted to maps
-- that were terrain-expanded.
config.VanillaSectorExpandedOnly = false
-- No fixed number: the count auto-derives so each sector matches the vanilla
-- sector footprint (see ResolveSectorCount in bm_sectors.lua).
config.VanillaSectorForcedCount = false
-- "expanded_with_vanilla_grid": anchor the grid to the original map's border
-- offset (partial edge sectors) instead of a clean division from the corner.
config.VanillaSectorAlignToVanillaGrid = bm_align_vanilla_grid
-- Optional manual anchor (world units) for the aligned grid. false = derive it
-- from the original map's PassBorder. Set a number to override if needed.
config.VanillaSectorGridAnchor = false
config.VanillaSectorBaseMapTiles = 4096
config.VanillaSectorBaseCount = 10
config.VanillaSectorMinCount = 10
config.VanillaSectorMaxCount = 40
config.VanillaSectorFastInitialReveal = true
config.VanillaSectorProgressColumnInterval = 2
config.VanillaSectorInitialRevealProgressInterval = 50

-- ============================================================================
-- Typed config view: BiggerMaps.Config
-- ============================================================================
-- The private `config` builder above is the single source of values. This view
-- re-exposes the same values under stable UPPERCASE names plus an ENABLE_MOD master
-- flag, with booleans coerced to real booleans, so the mod's own modules read a
-- clean, typed config (BiggerMaps.Config.*). Edit the settings above, not this view.
local BiggerMaps = rawget(_G, "BiggerMaps")
if type(BiggerMaps) ~= "table" then
	BiggerMaps = {}
	rawset(_G, "BiggerMaps", BiggerMaps)
end

local function as_bool(value)
	return value == true
end

local function as_number(value, default)
	if type(value) == "number" then
		return value
	end
	return default
end

local C = {}

-- Lifecycle / master
C.ENABLE_MOD = true

-- Map size + sector grid (master settings)
C.TERRAIN_SIZE = config.BiggerMapsTerrainSize
C.SECTOR_GRID = config.BiggerMapsSectorGrid
C.FULL_MAP_PLAYABLE = as_bool(config.BiggerMapsFullMapPlayable)

-- Debug logging
C.DEBUG_LOGS = as_bool(config.EnableDiagnosticLogs) or as_bool(config.DebugPrint)
C.DEBUG_QUADRANT_VERBOSE = as_bool(config.QuadrantCopyVerbose)

-- ZoomPlus integration
C.ENABLE_NORMAL_ZOOM_PLUS = as_bool(config.EnableNormalZoomPlus)
C.NORMAL_ZOOM_MULTIPLIER = as_number(config.ZoomPlusLookatDistZoomOutMultiplier, as_number(config.NormalZoomMultiplier, 4.0))
C.ALLOW_ZOOMPLUS_WITH_SCENARIO_EDITOR_HOST = as_bool(config.AllowZoomPlusWithScenarioEditorHost)

-- Overview camera / curtains / render distance
C.OVERVIEW_ZOOM_DISTANCE_PERCENT = as_number(config.OverviewZoomDistancePercent, 140)
C.OVERVIEW_CAMERA_XY_PERCENT = as_number(config.OverviewCameraXYPercent, 28)
C.OVERVIEW_DISTANCE_MULTIPLIER = as_number(config.OverviewDistanceMultiplier, 2.5)
C.OVERVIEW_MIN_HEIGHT_PERCENT = as_number(config.OverviewMinHeightPercent, 140)
C.OVERVIEW_NUDGE_HORIZONTAL_PERCENT = as_number(config.OverviewNudgeHorizontalPercent, 0)
C.OVERVIEW_NUDGE_VERTICAL_PERCENT = as_number(config.OverviewNudgeVerticalPercent, 0)
C.OVERVIEW_VIEW_ANGLE_DEGREES = config.OverviewViewAngleDegrees -- number, or false to use the game's angle
C.OVERVIEW_FOV_16_9 = as_number(config.OverviewFovX16_9, 3600)
C.OVERVIEW_FOV_4_3 = as_number(config.OverviewFovX4_3, 3400)
C.OVERVIEW_FAR_Z = as_number(config.OverviewFarZ, 12000000)
C.HIDE_OVERVIEW_CURTAINS = as_bool(config.HideOverviewCurtains)

-- Map generation (quadrant tiling)
C.ENABLE_QUADRANT_MAP_COPY = as_bool(config.EnableQuadrantMapCopy)
C.QUADRANT_COPY_SCALE = as_number(config.QuadrantCopyScale, 2)
C.QUADRANT_MAX_TERRAIN_TILES = as_number(config.QuadrantCopyMaxTerrainTiles, 8192)
C.QUADRANT_MAX_RANDOM_GENERATOR_TILES = as_number(config.QuadrantCopyMaxRandomGeneratorTiles, 6144)
C.QUADRANT_RENDERER_NODE_TILE_ALIGNMENT = as_number(config.QuadrantCopyRendererNodeTileAlignment, 2048)
C.QUADRANT_NATIVE_EXPANSION_HACK = as_bool(config.QuadrantCopyNativeExpansionHack)
C.QUADRANT_FORCE_EXPANDED_TILES = as_number(config.QuadrantCopyForceExpandedTiles, 8192)
C.QUADRANT_GENERATOR_SOURCE_TILES = as_number(config.QuadrantCopyGeneratorSourceTiles, 4096)
C.QUADRANT_LIMIT_GENERATOR_TO_SOURCE = as_bool(config.QuadrantCopyLimitGeneratorToSource)
C.QUADRANT_MAIN_MAP_ONLY = as_bool(config.QuadrantCopyMainMapOnly)
C.QUADRANT_SURFACE_ONLY = as_bool(config.QuadrantCopySurfaceOnly)
C.QUADRANT_RANDOM_MAPS_ONLY = as_bool(config.QuadrantCopyRandomMapsOnly)
C.QUADRANT_PATCH_RANDOM_GENERATOR = as_bool(config.QuadrantCopyPatchRandomGenerator)
C.QUADRANT_COPY_TERRAIN = as_bool(config.QuadrantCopyTerrain)
C.QUADRANT_COPY_OBJECTS = as_bool(config.QuadrantCopyObjects)
C.QUADRANT_COPY_ENUM_FLAGS = as_bool(config.QuadrantCopyEnumFlags)
C.QUADRANT_DELETE_GENERATED_OUTSIDE_SOURCE = as_bool(config.QuadrantCopyDeleteGeneratedOutsideSource)

-- Sectors (grid layout + exploration)
C.ENABLE_VANILLA_SIZED_SECTORS = as_bool(config.EnableVanillaSizedSectors)
C.SECTOR_UNIFORM_GRID = as_bool(config.VanillaSectorUniformGrid)
C.SECTOR_USE_SOURCE_QUADRANT = as_bool(config.VanillaSectorUseSourceQuadrant)
C.SECTOR_SURFACE_ONLY = as_bool(config.VanillaSectorSurfaceOnly)
C.SECTOR_EXPANDED_ONLY = as_bool(config.VanillaSectorExpandedOnly)
C.SECTOR_FORCED_COUNT = config.VanillaSectorForcedCount -- number, or false
C.SECTOR_ALIGN_TO_VANILLA_GRID = as_bool(config.VanillaSectorAlignToVanillaGrid)
C.SECTOR_GRID_ANCHOR = config.VanillaSectorGridAnchor -- number, or false
C.SECTOR_BASE_MAP_TILES = as_number(config.VanillaSectorBaseMapTiles, 4096)
C.SECTOR_BASE_COUNT = as_number(config.VanillaSectorBaseCount, 10)
C.SECTOR_MIN_COUNT = as_number(config.VanillaSectorMinCount, 10)
C.SECTOR_MAX_COUNT = as_number(config.VanillaSectorMaxCount, 40)
C.SECTOR_FAST_INITIAL_REVEAL = as_bool(config.VanillaSectorFastInitialReveal)
C.SECTOR_PROGRESS_COLUMN_INTERVAL = as_number(config.VanillaSectorProgressColumnInterval, 2)
C.SECTOR_INITIAL_REVEAL_PROGRESS_INTERVAL = as_number(config.VanillaSectorInitialRevealProgressInterval, 50)

BiggerMaps.Config = C

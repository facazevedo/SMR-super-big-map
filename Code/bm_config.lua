-- Bigger Maps configuration.
-- Edit these values, then reload the mod or restart the game.

local config = rawget(_G, "BiggerMapsConfig")
if type(config) ~= "table" then
	config = {}
	rawset(_G, "BiggerMapsConfig", config)
end

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

-- Experimental 2x2 map tiling.
-- New random surface maps are created at twice their normal width and height.
-- After vanilla generation finishes, the upper-left quadrant is copied to the
-- right, bottom, and bottom-right quadrants.
config.EnableQuadrantMapCopy = true
config.QuadrantCopyScale = 2
config.QuadrantCopyMaxTerrainTiles = 8192
-- The random map generator's stable-position helper asserts around 8192
-- terrain tiles, while the renderer rejects some intermediate sizes. 6144 is
-- the largest renderer-safe random blank map size confirmed so far.
config.QuadrantCopyMaxRandomGeneratorTiles = 6144
config.QuadrantCopyRendererNodeTileAlignment = 2048
-- Experimental native-size hack: allocate an 8192 map, generate only a 4096
-- top-left source quadrant, then tile that quadrant into the rest of the map.
config.QuadrantCopyNativeExpansionHack = true
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

-- Experimental sector layout for expanded maps.
-- The native expansion hack generates a 4096-tile source quadrant with the
-- normal 10 x 10 sector layout, then tiles that quadrant into an 8192 map.
-- The exact tile ratio (8192 / 4096 * 10) yields a 20 x 20 grid with the same
-- sector footprint as the pre-copy map. To get a finer overview grid, set
-- VanillaSectorForcedCount to the desired per-axis count (e.g. 40 -> 40 x 40,
-- half-size sectors). The forced count is clamped to [MinCount, MaxCount], so
-- MaxCount must be at least the forced count. ResolveSectorCount feeds both the
-- built grid and const.SectorCount, so they always match.
config.EnableVanillaSizedSectors = true
config.VanillaSectorUniformGrid = true
config.VanillaSectorUseSourceQuadrant = true
config.VanillaSectorSurfaceOnly = true
config.VanillaSectorExpandedOnly = true
config.VanillaSectorForcedCount = 40
config.VanillaSectorBaseMapTiles = 4096
config.VanillaSectorBaseCount = 10
config.VanillaSectorMinCount = 10
config.VanillaSectorMaxCount = 40
config.VanillaSectorFastInitialReveal = true
config.VanillaSectorProgressColumnInterval = 2
config.VanillaSectorInitialRevealProgressInterval = 50

-- Super Big Map configuration.
-- Edit these values, then reload the mod or restart the game.

-- Private builder table (NOT a global). The raw settings below are read once into
-- the typed SuperBigMap.Config view at the bottom of this file; every module reads
-- that view. The bundled third-party ZoomPlus.lua used to read a global
-- SuperBigMapConfig, but it degrades safely without one (its fallback uses the same
-- multiplier 4.0 / scenario-editor-host = true configured here) and the ZoomPlus
-- integration also drives it directly, so no global config table is exported.
local config = {}

-- ============================================================================
-- MAIN SETTINGS: map size and sector grid
-- ============================================================================
-- These two values are the primary controls for the mod. The detailed flags in
-- the "Experimental ..." sections below are DERIVED from them, so in normal use
-- you only edit these two lines. Set BOTH to "vanilla" for plain, unmodified
-- vanilla Surviving Mars behaviour.
--
-- config.SuperBigMapTerrainSize -- how large the playable terrain is:
--     "vanilla"   Vanilla map size (4096 mapdata tiles). The game builds and
--                 renders its normal terrain.
--     "expanded"  20x20 frame expansion. The mod allocates an 8192-tile mapdata,
--                 lets the random generator produce the native source terrain,
--                 then fills the added L-shaped frame by mirroring terrain and
--                 objects from the source edge blocks.
--                 Applies to random Surface maps only; everything else (e.g.
--                 underground breakthroughs) stays vanilla.
--
-- config.SuperBigMapSectorGrid -- how the overview "sector tiles" (the lettered
--                                scan grid you see in overview) are laid out.
--                                Sectors are always vanilla-sized (~40960 world
--                                units, never changes); the options differ in
--                                count and grid offset:
--     "vanilla"                 Vanilla: a 10 x 10 grid over the bordered PLAYABLE
--                               area only -- the map's outer border is left out of
--                               the grid, exactly like the unmodified game. The mod
--                               does not touch sectors or bounds.
--     "expanded"                Clean grid from the map corner (0,0): as many full
--                               vanilla-sized sectors as the terrain holds, no
--                               partials. The whole terrain is made playable.
--                               RECOMMENDED: this matches the engine's own overview/
--                               selection grid (anchored at the map corner), so
--                               the hover highlight lines up with the sectors and
--                               you can click them precisely.
--     "expanded_with_vanilla_grid"
--                               Same vanilla-sized sectors, but the grid is shifted
--                               to the ORIGINAL map's grid offset (vanilla
--                               PassBorder) so the lines match where vanilla drew
--                               them. Partial edge sectors are DROPPED -- only full
--                               vanilla-sized sectors are kept; a margin remains
--                               between the outermost sector and the map edge.
--                               CAVEAT: the engine's hover-highlight is hard-
--                               anchored at the map corner and cannot be moved from
--                               Lua, so with this option the selection highlight
--                               does NOT line up with the shifted grid (you can't
--                               reliably click a sector). Use only if you care about
--                               the grid lines' position over clicking.
--
-- IMPORTANT: switching to (or between) "expanded" terrain only takes effect on
-- a NEW GAME. Loading an existing save keeps the map data that was generated
-- at save time; the terrain expansion has to happen during map generation, so
-- the bigger 20x20 expanded map will not appear on a save that was started without
-- it (or with a different terrain setting). To see "expanded" terrain, start a
-- new game after editing this file.
--
-- The five combinations (resulting grid counts assume vanilla=4096-tile terrain
-- and expanded=8192-tile terrain at 100 wu/tile, vanilla sector=40960 wu):
--     "vanilla"  + "vanilla"                    truly vanilla: 10x10 over the
--                                               bordered playable area. Mod is a
--                                               complete no-op.
--     "vanilla"  + "expanded_with_vanilla_grid" vanilla terrain, vanilla offset,
--                                               drop partials -> ~9x9 inside the
--                                               vanilla map. Whole terrain made
--                                               playable.
--     "vanilla"  + "expanded"                   vanilla terrain, grid from (0,0)
--                                               spanning whole map -> 10x10 with
--                                               whole terrain playable.
--     "expanded" + "expanded_with_vanilla_grid" expanded terrain, vanilla offset,
--                                               drop partials -> 19x19 inside the
--                                               8192-tile map. Vanilla-aligned
--                                               grid lines but selection offset.
--     "expanded" + "expanded"                   expanded terrain, grid from (0,0)
--                                               -> 20x20. Clean grid, working
--                                               selection. (Default.)
-- ============================================================================
config.SuperBigMapTerrainSize = "expanded"
config.SuperBigMapSectorGrid = "expanded"

-- Derived from the two settings above (edit the settings, not these helpers).
local sbm_expanded_terrain = config.SuperBigMapTerrainSize == "expanded"
local sbm_align_vanilla_grid = config.SuperBigMapSectorGrid == "expanded_with_vanilla_grid"
local sbm_expanded_grid = config.SuperBigMapSectorGrid == "expanded" or sbm_align_vanilla_grid
-- Enlarge the playable area to the full terrain (border included) whenever the
-- terrain or the sector grid is expanded; "vanilla" + "vanilla" leaves the
-- vanilla border untouched. Read by SuperBigMap.lua.
config.SuperBigMapFullMapPlayable = sbm_expanded_terrain or sbm_expanded_grid

-- Normal camera zoom. ZoomPlus applies:
-- LookatDistZoomOut = original.LookatDistZoomOut * ZoomPlusLookatDistZoomOutMultiplier.
-- This multiplier is the FALLBACK/default; the in-game "Max Zoom Level" slider (below)
-- overrides it per-savegame when set.
config.EnableNormalZoomPlus = true
config.ZoomPlusLookatDistZoomOutMultiplier = 9
config.NormalZoomMultiplier = config.ZoomPlusLookatDistZoomOutMultiplier

-- IN-GAME "Max Zoom Level" option (Options / Display), handled by sbm_zoom_option.lua.
-- Adds a slider letting the player set how far the camera zooms out. The value is a
-- PERCENT of vanilla max zoom (100% = exactly vanilla / ZoomPlus off; higher = further)
-- and is stored PER-SAVEGAME (engine storage = "session" -> GameVar g_SessionOptions,
-- serialized into the save). It is restored when that save loads and is NOT shared with
-- other games/scenarios; a new game starts at the default. Drives the camera through
-- ZoomPlus, so it works on both vanilla and Super Big Map maps. Default 900% matches
-- ZoomPlusLookatDistZoomOutMultiplier (9x) above -- keep them in sync.
config.EnableMaxZoomOption = true
config.MaxZoomOptionDefaultPercent = 900
config.MaxZoomOptionMinPercent = 100
config.MaxZoomOptionMaxPercent = 1200
config.MaxZoomOptionStepPercent = 25

-- The far LookatDistZoomOut the OVERVIEW camera needs so its high bird's-eye eye
-- isn't clamped in close. The engine uses ~20000 for overview (it flips the live
-- camera to this on a wheel-zoom overview entry); the auto/startup overview entry
-- does NOT, so the mod pushes this value onto the LIVE camera (only) right before
-- the overview SetCamera, then the engine restores the selection limit on exit.
-- This is the overview framing distance, independent of the normal-zoom multiplier.
config.OverviewCameraZoomOutLimit = 20000

-- Seed the overview dialog's return camera on the STARTUP overview. A new game
-- opens directly in overview with transition_time=0, so vanilla never captures a
-- saved_camera; the FIRST zoom-in (overview exit) then falls back to a fixed far
-- default return offset (point(0,-300000,200000)) which, with our high overview
-- eye, makes the camera swerve before landing on the picked sector. When true,
-- the mod captures the pre-overview camera the first time it frames overview and
-- stores it as the dialog's saved_camera, so the first exit returns like every
-- subsequent one. Vanilla overwrites saved_camera on later (wheel) entries.
config.SeedStartupOverviewReturnCamera = true
-- The seeded return camera's eye offset from the sector, in world units: how far
-- SOUTH and UP the camera sits when the first overview exit lands on the picked
-- sector. A clean south+up offset (no sideways component, eye above the ground)
-- makes the first zoom-in descend STRAIGHT onto the sector instead of swerving.
-- Ratio up/south sets the view angle (~67/100 ≈ vanilla's selection angle);
-- smaller magnitudes = tighter/closer landing. Tune if the first zoom-in feels
-- too far out or too steep.
config.SeedOverviewReturnSouth = 100000
config.SeedOverviewReturnUp = 67000

-- Pre-aim the overview EXIT (zoom-in to a sector): snap the camera's lookat onto
-- the chosen sector before the descent so the sector stays locked on screen and
-- the camera zooms STRAIGHT down onto it, instead of panning the lookat across
-- the map (the curved first zoom-in). Applied by the ZoomPlus overview-exit hook.
config.PreAimOverviewExit = false
-- Take over only the first/startup overview->sector EXIT descent with a straight,
-- mod-driven camera animation. Later overview exits use vanilla's transition path.
-- This removes the startup first-zoom curve without replacing normal play zooms.
config.TakeoverOverviewExit = true
-- Milliseconds to animate the pre-aim PAN (centering the chosen sector at overview
-- height) before the descent, so the zoom-in is smooth instead of teleporting
-- sideways. 0 = instant (teleport). ~200-300 feels like a quick smooth glide.
config.OverviewExitPanTime = 250

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
config.OverviewNudgeVerticalPercent = -5
-- Horizontal rotation of the overview camera, in degrees. Vanilla starts at 45.
-- Set to false to let the game use its normal overview angle.
config.OverviewViewAngleDegrees = 45
config.OverviewFovX16_9 = 3600
config.OverviewFovX4_3 = 3400
config.OverviewFarZ = 12000000

-- Hide the dark overview map curtains around the visible map.
config.HideOverviewCurtains = true

-- ============================================================================
-- DEBUG LOGGING (all default false -- production ships silent)
-- ============================================================================
-- Every mod log line routes through SuperBigMap.DebugLog with a SCOPE. A line prints
-- when the MASTER flag below is true (turns on ALL scopes), OR that line's own scope
-- flag is true (trace one domain in isolation). Flip the master for a full trace, or a
-- single scope to focus. Each flag maps to DebugLog scope "<Name>" (see sbm_debug.lua).
config.EnableDiagnosticLogs = false  -- MASTER: when true, every scope below also logs

config.DebugLifecycle     = false   -- Lifecycle: enable/disable, Apply/Restore, OnMsg flow, old-save warning
config.DebugGeneration    = true    -- Generation: generator hook, frame allocation, mirror/clone plan (TEMP: investigating "cannot expand / not 20x20")
config.DebugGenerationVerbose = false -- GenerationVerbose: per-object clone spam (very noisy)
config.DebugSector        = true    -- Sector: grid build/patch, visibility, decal cleanup (TEMP: investigating "cannot expand / not 20x20")
config.DebugSectorSizing  = true    -- SectorSizing: sector-count/size math (noisy; per-tag deduped) (TEMP: investigating "cannot expand / not 20x20")
config.DebugDeposits      = true    -- Deposits: cloned-deposit reshuffle/register + anomaly top-up (TEMP: investigating landing-spot crowding / vanilla-proportion distribution)
config.DebugRmgPlacement  = true    -- RmgPlacement: deposit/anomaly placement auto-fit (coverage, scale, placed counts)
config.DebugStretch       = true    -- Stretch: per-step stretch frame-fill resample trace (TEMP: investigating stuck-at-loading)
config.DebugLoading       = true    -- Loading: loading-box watch loop + "Please wait" dot animation (TEMP: investigating animation stopping)
config.DebugLoadTime      = true    -- LoadTime: end-to-end load TIMELINE (each phase with total+delta ms, incl. samples during the stretch settle) (TEMP: finding where load time goes to speed it up)
config.DebugHover         = true    -- Hover: overview hover-highlight mapping (cursor pos, ray-hit Z vs authoritative height, sector bounds + containment) (TEMP: investigating misaligned overview highlight)
config.DebugOverview      = true    -- Overview: overview curtains + render-distance (TEMP: measuring overview camera eye/distance for "overview too far")
config.DebugCamera        = true    -- Camera: overview-camera state samples through transitions (TEMP: investigating overview->zoom-in smoothness + far snap)
config.DebugRocket        = false   -- Rocket: rocket landing Z-snap path
config.DebugHeat          = false   -- Heat: heat-grid clamp wraps
config.DebugBounds        = false   -- Bounds: playable bounds / PassBorder
config.DebugFakeTerrain   = false   -- FakeTerrain: frame crater cleanup
config.DebugValidation    = false   -- Validation: runtime validation snapshots
config.DebugZoom          = false   -- Zoom: ZoomPlus integration (also drives ZoomPlus's own logs)
config.DebugZoomVanilla   = true    -- ZoomVanilla: TEMP investigation -- trace why a NON-expanded (vanilla) map's zoom/FOV is or isn't left vanilla (ApplyNormalZoom gate + overview FOV widen/restore). Turn OFF after diagnosing.
config.DebugPregameToggle = true    -- PregameToggle: EXPAND MAP button/underline layout diagnostics (TEMP: investigating disappearing EXPAND MAP button)
config.DebugRestartNotice = false   -- RestartNotice: restart-notice decision path
config.DebugEditorCamera  = false   -- EditorCamera: map-editor camera trace
config.DebugInitSeq       = true    -- InitSeq: step-by-step init/expansion sequence trace (TEMP: investigating "cannot expand / not 20x20"; also dumps the live grid at WarnCannotExpand)
config.DebugChosenMap     = false   -- ChosenMap: one line per map load (id, landing site, coordinates)

-- (The non-rendered frame is made passable by zeroing mapdata.PassBorder before
-- generation in sbm_map_generation; no per-load passability pass is needed.)

-- Remove the vanilla DecCrater decals that the random-map decor pass scatters
-- across the NON-RENDERED frame (everything beyond the playable source quadrant).
-- Craters inside the rendered/playable area are vanilla and left untouched.
config.RemoveFrameCraters = true

-- Safety double-check after the L-frame clone: delete any underground entrance (tunnel/passage
-- access) left in the cloned frame. The dest-clear protects underground-access objects from
-- deletion, so a generator-placed entrance that landed outside the source quadrant can survive
-- in the frame; this removes it. The genuine entrance in the rendered source quadrant is never
-- in the frame boxes, so it is never touched. ON by default.
config.RemoveFrameUndergroundAccess = true

-- Silence the engine's "Buildable grid computing too slow! Took <ms>" message on the expanded
-- map. The buildable grid is built at the real (8192-tile) map dimensions, so the compute always
-- exceeds the engine's 1000 ms warning threshold; the message is informational only and inherent
-- to the larger map. Swallowed ONLY while building a mod-expanded map; vanilla maps keep it. true
-- = hide it, false = show it.
config.SilenceBuildableGridSlowWarning = true

-- After each sector copy (test copy, column mirror, or the console helper), force
-- any object that was ALREADY sitting in the destination region -- e.g. a mystery
-- "pile of stone" / anomaly a story event dropped into the frame -- onto the
-- freshly copied surface: its Z is re-snapped to the new terrain height, since the
-- ground under it just changed. If the spot is now occupied by another
-- non-interacting object (a decoration / rock that does not attach to it), the
-- object is nudged to the nearest clear, destlockable point nearby so the two do
-- not intersect. Objects the copy itself just placed (the faithful source replica)
-- and live units are left untouched.
config.ResnapFrameObjects = true

--- Re-snap a landing rocket onto the live (expanded) terrain surface. On a mod map
--- the copied frame region's height was changed after the engine first resolved
--- landing positions, so a rocket commanded to land in the expanded terrain could
--- descend to a stale Z (above or below the visible ground). When true, the mod
--- wraps RocketBase:LandOnMars to re-snap the landing SITE's Z to the current terrain
--- height (point:SetTerrainZ) right before vanilla reads the spot location. Ground
--- landings only: landings onto a landing pad keep the pad's Z. Mod maps only.
config.FixRocketLandingZ = true


-- Stop the rocket landing from DEFORMING the ground. When a rocket landing site is placed,
-- the engine's construction flatten (FlattenTerrainInBuildShape -> FlattenTerrainInShape)
-- levels the landing pad's footprint to the buildable z-grid -- on the copied/expanded
-- terrain that raises a tall flat PILLAR (it levels up to a nearby high point). When true,
-- the mod wraps the global FlattenTerrainInBuildShape and SKIPS it for rocket/pod landing
-- sites on mod maps, so the site sits on the natural terrain and the rocket lands there
-- (snapped to terrain Z) without carving/raising a pad. Mod maps only; other buildings
-- flatten normally.
config.PreventLandingPadFlatten = true

-- Impassable edge border (WORLD UNITS) kept around the expanded map. DEFAULT is full
-- passability (0) so a rover unloaded from a rocket that lands anywhere -- including near
-- the map edge / non-rendered frame -- is never trapped (the behavior fixed long ago by
-- zeroing PassBorder). The engine's gameplay grids (heat, etc.) only cover
-- [HeatGridBorder, size-HeatGridBorder]; rather than block movement with a border, the
-- heat query is CLAMPED (see ClampHeatQueriesOnExpandedMap) so units in the outer strip
-- don't crash Heat_Get. Set a positive number here to keep an impassable ring instead
-- (rounded up to a const.MapPatchSize multiple, required by the engine). false/0 = full
-- passability (recommended).
config.ExpandedMapEdgeBorder = false

-- Clamp heat-grid queries to the grid's valid range on expanded maps. With PassBorder=0
-- a unit can stand in the outer HeatGridBorder strip the heat grid does not cover, and
-- Heat_Get asserts (pGrid->inside). When true, the mod wraps HeatGrid:GetHeatAt/GetHeatAtXY
-- to clamp the query position into the grid so it reads the nearest in-grid heat instead
-- of crashing. In-bounds queries are unchanged (exact vanilla). Lets the full map stay
-- passable without an impassable ring.
config.ClampHeatQueriesOnExpandedMap = true

-- Force the buildable z-grid's unbuildable cells to a height (making them buildable).
-- DISABLED: we want VANILLA rules -- rockets/buildings only where the terrain is actually
-- buildable, so they can't land on cliffs. The post-copy RebuildBuildableGrid already makes
-- the grid recognize the new terrain (flat=buildable, cliff=unbuildable) correctly.
config.ForceBuildableGridStorage = false

-- Permissive BUILD override (BuildableGrid:GetZ -> buildable on cliffs). DISABLED: this is
-- what let a rocket land on a cliff (and then the construction flatten asserted on the
-- unbuildable cell). With it off, vanilla buildability (from the rebuilt-after-copy grid)
-- decides: you can build/land on the flat copied terrain but NOT on cliffs -- exactly like a
-- native map. (Cliffs can still be made buildable by LANDSCAPING them flat; see below.)
config.PermissiveBuildOnExpanded = false

-- Allow the LANDSCAPING tools (terraform / flatten / level) to operate across the WHOLE
-- expanded terrain. ENABLED: this is separate from buildability -- vanilla lets you landscape
-- unbuildable terrain to MAKE it buildable, and that must keep working on the expanded area
-- (otherwise the landscape tool fails "out of bounds" outside the original quadrant). It does
-- NOT make anything buildable on its own; it only lets the player reshape the new terrain.
config.AllowLandscapingOnExpanded = true

-- Force the expanded L-frame region PASSABLE after the terrain copy (editor.SetPassableBox
-- + RebuildPassability), regardless of the copied terrain's slope. Ported from the original
-- working fix (commit 9e940f8): a rover unloaded from a rocket that lands in the frame is
-- otherwise trapped where the copied (e.g. cliff) terrain reads impassable -- the
-- "rocket/rover stuck / deforms the ground to land" problem. PassBorder=0 removes the baked
-- edge ring; this removes the slope-based impassability inside the frame. Mod maps only.
config.ForceFramePassable = true
-- Extra pass-tiles forced passable INTO the rendered source area so the seam between the
-- original map and the frame is crossable (0 = frame only).
config.FramePassableBridgeTiles = 2



-- SECTOR-MIRROR PLAN (at game start): fill the L-shaped non-rendered frame by
-- reflecting the playable edge into it, terrain AND objects. Three groups:
--   1) LEFT frame  -- source cols F,G,H,I,J mirror (vertical) onto cols E,D,C,B,A,
--                     rows 0..14;
--   2) TOP frame   -- source rows 14,13,12,11,10 mirror (horizontal) onto rows
--                     15,16,17,18,19, cols F..T;
--   3) CORNER A15:E19 -- source cols F..J / rows 10..14 get BOTH mirrors (180 deg)
--                     so the corner matches both seams.
-- Each destination's existing scatter is replaced with mirrored copies of the
-- source. Runs post-load (TestCopySectorDelayMs settle), once per map, with one
-- combined refresh over the whole filled frame.
config.SectorMirrorPlanAtStart = true

-- Per-block DECOR clone thinning: SKIP cloning every Nth decorative source object
-- (rocks, decals, terrain prefabs, etc.) to cut the cost of filling a decor-dense
-- map (the slow part is ~thousands of PlaceObject calls, not the grid copy).
--   0 = skip nothing → clone all decor (default)
--   1 = skip every decor object → clone none (every position is a multiple of 1) ✓
--   2 = skip every 2nd (~50% fewer)
--   3 = every 3rd, etc.
-- A LOWER N skips MORE (1 skips all). Resource deposits and anomalies are ALWAYS
-- cloned (never skipped), so gameplay objects are preserved regardless of N.
config.MirrorDecorSkipEveryNth = 1

-- Skip cloning any DECORATION whose bounding sphere crosses the source block's
-- edge: its mirrored copy would straddle the seam / map edge and overhang (the
-- same broken-looking half-floating rock the post-load decor cleanup removes).
-- Resource deposits and anomalies are still cloned even if edge-touching. true =
-- skip edge-touching decor (default); false = clone it anyway.
config.MirrorSkipEdgeTouchingDecor = true

-- When the sector-mirror plan is enabled but the map did NOT generate as a full
-- 20x20 sector grid (so the frame can't be properly expanded/mirrored), pop up a
-- modal "this map can't be properly expanded" message (OK to dismiss). The reason
-- is always written to the log regardless; this flag only controls the popup.
config.WarnOnCannotExpand = true

-- When an OLD save that was NOT started with Super Big Map is loaded, show a
-- one-time (per load) modal explaining that the expanded map only applies to games
-- STARTED with the mod, and that this save will keep playing normally. The mod does
-- nothing else on such saves (no expansion, bounds, sector, or overview changes).
-- Nothing is written into the old save. Set false to suppress the popup entirely.
config.WarnOldSaveNeedsNewGame = true


-- Hide cloned subsurface deposits/anomalies until their (expanded/frame) sector is scanned.
-- The expansion mirror-copies the starting sector's already-revealed deposits into the
-- unscanned frame; without this they would be visible before scanning. ON by default.
-- (Resource deposits are always copied by cloning their invisible MARKERS -- which spawn the
-- real deposit on scan -- never the spawned objects; anomalies/effect deposits are not copied.)
config.HideClonedDepositsUntilScan = true
-- Reshuffle each cloned deposit onto nearby terrain that best matches the terrain its SOURCE
-- deposit sat on (same terrain type + similar flatness, must be passable). The copy places
-- deposit OBJECTS by translation while the terrain is mirrored, so a deposit can land off its
-- matching ground; this re-seats it. For concrete, the copied regolith patch is moved with
-- the marker only when the final sector is already scanned; unscanned sectors stay hidden.
config.ReshuffleClonedDeposits = true
-- Keep reshuffled deposits at least this many tiles away from the map's outer border (no
-- deposit is placed within this margin of the edge).
config.DepositEdgeMarginTiles = 4

-- ANOMALY RE-SPACING (sbm_deposits.lua RespaceAnomalies). On an expanded map the generator is
-- forced to pack anomalies ~20% tighter than vanilla so the full set (incl. all FreeTech) fits
-- the shrunken placement zone. When this is true, a post-generation pass spreads the UNREVEALED
-- anomaly markers back out to an even, vanilla-like spacing across the whole playable map
-- (unregister from the old sector -> move -> register in the new sector; scanning still reveals
-- them normally). Live anomalies in the already-scanned start sector are left untouched. Deposits
-- are NOT touched by this. true = re-space anomalies (recommended for vanilla-like spread).
-- EVEN OUT DEPOSIT DENSITY (sbm_deposits.lua EvenOutDepositDensity). The generator packs the
-- full preset deposit count into the shrunken gen-zone (see RMG PLACEMENT AUTO-FIT), so the
-- source region -- including the scanned START/landing sector -- ends up several times denser
-- than vanilla while the mirrored frame is sparse. When true, a post-generation pass caps each
-- sector at MaxResourceDepositsPerSector and relocates the surplus onto terrain-matched frame
-- tiles: it thins the source (start sector included -- surplus there is despawned and re-hidden
-- so it re-spawns vanilla-style when its new frame sector is scanned) and fills the frame. Total
-- count is unchanged; only the distribution is evened to vanilla-like proportions. false = leave
-- the packed source distribution.
config.EvenOutDepositDensity = true
-- Per-sector resource-deposit cap the even-out pass thins down to. Vanilla start sectors carry
-- only a couple of deposits; 3 keeps a small starting cluster while spreading the rest across the
-- map. Lower = sparser (closer to vanilla), higher = keep more in place. Tune from the
-- DebugDeposits DISTRIBUTION report (start-sector count vs average).
config.MaxResourceDepositsPerSector = 3
-- DEPOSIT TOP-UP (sbm_deposits.lua TopUpDeposits). The generator places the native (Big) deposit
-- count; over the larger 20x20 that is below vanilla density. When true, extra source resource
-- deposits are cloned onto terrain-matched frame tiles until the total reaches
-- source_count * area_factor (vanilla density x the bigger area); the clones are hidden until
-- their sector is scanned, and the even-out pass then spreads everything. All resource types
-- scale proportionally, including concrete (a cloned concrete marker paints its own regolith
-- patch on scan). false = native (Big) deposit count.
config.EnableDepositTopUp = true
-- Override the deposit target scale. false = auto (area factor); a number forces that multiplier.
config.DepositCountScaleOverride = false

config.RespaceAnomaliesToVanilla = true
-- Also thin the SCANNED start sector's REVEALED anomalies. RespaceAnomalies normally keeps
-- placed/revealed anomalies fixed; on an expanded map that leaves the landing sector denser than
-- vanilla (the generator packed them there). When true, revealed start-sector anomalies are
-- despawned + re-hidden and respaced out evenly with the rest, so the landing spot matches
-- vanilla anomaly density (they re-appear when their new sector is scanned). false = keep them.
config.EvenOutStartSectorAnomalies = true
-- How spread out the re-spaced anomalies are: the minimum distance between anomalies is
-- factor * sqrt(playable_area / anomaly_count). Lower = tighter (closer to the original packed
-- look), higher = more spread. 0.6 gives an even, vanilla-like fill that always fits; raise
-- toward 1.0 for a sparser feel. Tune from the DebugDeposits "respaced anomaly markers" log.
config.AnomalyEvenSpreadFactor = 0.6
-- How far (in tiles) the reshuffle search looks around the clone for a better-matching spot.
config.ReshuffleSearchRadiusTiles = 12
-- When a cloned CONCRETE (TerrainDeposit) marker is reshuffled to a new spot, clear the copied
-- Regolith/Regolith_02 terrain patch from its original mirrored position. If the marker's final
-- sector is already scanned, paint the same regolith shape at the final position; if it is still
-- unexplored, leave the final position clean and let vanilla paint the concrete patch when the
-- sector scans. Only regolith tiles are touched.
config.ClearInitialConcreteImprint = true
-- Max type-grid tiles the concrete-imprint flood fill will clear per blob. Regolith /
-- Regolith_02 are used ONLY as the concrete-deposit texture (confirmed in the game files:
-- TerrainDeposit.lua Concrete -> "Regolith"/"Regolith_02"; they do NOT appear in the map-gen
-- terrain sets and landscaping excludes them), so every regolith blob IS a concrete patch
-- bounded by non-regolith terrain -- the fill always stops at the patch edge, and there is no
-- natural regolith to protect. So there's no reason to cap by size: 0 = NO size limit (clear
-- the whole patch regardless of size; recommended). A positive value caps the fill at that many
-- tiles (a leftover safety knob). The clear only runs at a concrete marker's OLD mirrored
-- (always-unscanned, frame) position, so it never affects concrete in scanned/playable sectors.
config.ConcreteImprintMaxTiles = 0

-- Optional "Scan All Sectors" button (sbm_scan_all_button.lua): a bottom-right button that
-- deep-scans every sector (reveals surface/subsurface/deep deposits + anomalies). Config-gated --
-- the code ships but only appears when this is true. Handy for revealing the whole expanded map
-- (and for verifying the anomaly top-up). true = show the button, false = hide it.
config.ScanAllButtonEnabled = false

-- Show an on-screen notice (the game's standard message box) telling the player a fresh
-- restart is necessary -- but ONLY when they just turned the mod ON under Installed Mods
-- (an off->on toggle), NOT on a normal launch where it was already enabled. Set false to
-- silence it entirely. The notice also offers a persistent local "Don't show again"
-- action stored in LocalStorage.
config.ShowRestartNotice = true

-- Settle delay (ms) the auto copy waits AFTER the sectors exist before copying,
-- so the map is fully loaded/rendered first. Copying during load reads/writes
-- terrain that isn't finalized yet and produces garbage; the manual console copy
-- works because it runs well after load. This delay makes the auto copy match.
config.TestCopySectorDelayMs = 5000

-- Experimental 2x2 map tiling. Controlled by SuperBigMapTerrainSize above
-- ("expanded" enables it, "vanilla" disables it). New random surface maps are
-- created larger, then the source quadrant is copied into the other quadrants.
config.EnableQuadrantMapCopy = sbm_expanded_terrain
config.QuadrantCopyScale = 2
-- HARD ENGINE CAP: the terrain may not exceed 8192 tiles on either axis --
-- confirmed by the C++ assert geTerrain.cpp(231): m_mapdata.nWidth <= 8192 &
-- m_mapdata.nHeight <= 8192 (a 10240 allocation aborts map load). 8192 tiles =
-- 20x20 vanilla sectors is therefore the absolute maximum map size; do not raise.
config.QuadrantCopyMaxTerrainTiles = 8192
-- The random map generator's stable-position helper asserts around 8192
-- terrain tiles, while the renderer rejects some intermediate sizes. 6144 is
-- the largest renderer-safe random blank map size confirmed so far. (The
-- generator runs at the native size, NOT the allocation, so leave this at 6144.)
config.QuadrantCopyMaxRandomGeneratorTiles = 6144
config.QuadrantCopyRendererNodeTileAlignment = 2048
-- FRAME EXPANSION MODE (the only supported expansion geometry). Keep the FULL native
-- generated map as the "original" (e.g. a Big map's native 6144 tiles = 15x15 sectors),
-- allocate a larger 8192-tile (20x20) mapdata, and leave the extra 5-sector-wide L-shaped
-- frame around the original FLAT (uniform height, default texture). The generator runs once
-- at the native size and fills from the origin; nothing is cloned or duplicated. The frame is
-- then filled by mirroring the playable edge (the sector-mirror plan). The rendered original
-- is corner-anchored at (0,0); the flat frame forms an L on the right + bottom in world coords.
config.ExpansionFrameMode = sbm_expanded_terrain

-- FRAME FILL MODE -- how the L-shaped FRAME of new sectors (everything beyond the native
-- generated source, i.e. the outer band of the 20x20 map) gets its terrain. The native source
-- is ALWAYS produced by the vanilla map generator; only the surrounding frame is built by the
-- method chosen here. Flip this string to compare approaches to the source<->frame junction:
--
--   "mirror"       -- (default, original) reflect the source's edge blocks outward to fill the
--                     frame. Fast and uses real generated terrain, but the reflection is
--                     SYMMETRIC across the seam, so it shows a straight central crease and
--                     doubled / abrupt walls (the artifact we are trying to get rid of).
--
--   "desymmetrize" -- mirror as above, then WARP the frame so it is no longer a perfect
--                     reflection. Breaks the dead-straight crease and the mirror symmetry, but
--                     the terrain is still derived from the reflected source (a compromise).
--
--   "stretch"      -- NO frame at all: resample (stretch) the whole generated source to fill the
--                     full 20x20 allocation. Perfectly seamless -- one continuous terrain of real
--                     generator output -- but every feature ends up ~33% larger ("zoomed"),
--                     rather than genuinely new terrain.
--
--   "noise"        -- synthesize the frame with fractal noise that CONTINUES the source edge
--                     outward (no reflection). Adds genuinely new, non-symmetric terrain; only a
--                     thin join at the source->frame boundary remains to blend. Most natural, but
--                     the hardest to make match the generator's texture/biome look.
--
-- Any unrecognised value falls back to "mirror". IMPLEMENTATION STATUS (added incrementally):
--   "mirror"       -- complete.
--   "stretch"      -- TERRAIN done (grids are resampled to full size); generated objects and
--                     deposits are NOT yet repositioned, so they still sit in the source corner
--                     until the object pass lands. Use it now to judge the stretched-terrain look.
--   "desymmetrize" -- not implemented yet; logs a notice and falls back to "mirror".
--   "noise"        -- not implemented yet; logs a notice and falls back to "mirror".
-- The map is always complete/playable whatever is selected.
-- TEMPORARY: set to "stretch" for testing the stretched-terrain look (step 1). Set back to
-- "mirror" before release (stretch does not reposition objects/deposits yet).
config.ExpansionFrameFillMode = "stretch"
-- STRETCH extras. ScaleMarkers moves the generated DEPOSIT / ANOMALY / EFFECT markers (and any
-- already-spawned deposits/anomalies) to their scaled spots on the stretched terrain, exactly like
-- the decorations -- without it they stay clustered in the source corner. DecorTopUp restores the
-- per-area decoration density: the stretch spreads the ORIGINAL decor count over ~1.78x the area,
-- so each moved decoration gets a chance ((area_factor-1) probability) to spawn one jittered clone
-- nearby, bringing density back to the generated look.
config.StretchScaleMarkers = true
-- After the marker/deposit move, re-enforce scan-gating: hide revealed enrichments that landed in
-- UNSCANNED sectors (they re-reveal on a real scan) and place/reveal what moved INTO already-
-- scanned sectors -- otherwise the start sector's revealed deposits stay visible wherever the
-- stretch relocated them (e.g. G15/H15 visible while only K11 is scanned).
config.StretchEnforceScanGate = true
-- Relocate the INITIAL revealed sector to the scaled position of the original pick: vanilla
-- chooses the start sector by its resources BEFORE the stretch moves everything, so the scanned
-- sector no longer matches where its content went. Un-scans the original, vanilla-scans the
-- sector at the scaled center, and moves the landed rocket along -- keeping the start "as close
-- as possible to the corresponding original sector" on the expanded map.
config.StretchRelocateStartSector = true
-- UNDERGROUND stretch (in development, step 1+2: allocation + terrain/decor/marker stretch).
-- Expands the underground map to the same 8192 allocation and applies the IDENTICAL
-- x(full/source) transform as the surface, so surface<->underground entrances correspond
-- perfectly (the game spawns an underground passage AT the surface passage's own x,y and links
-- the pair by object reference -- equal transforms on both maps preserve that correspondence).
-- No underground sector-grid or density work yet.
config.StretchUnderground = true
-- TEMP (testing): unlock the underground map VIEW from the start of the game, so the stretched
-- underground can be inspected immediately via the map switcher (vanilla unlocks it later).
-- Turn OFF for release.
config.UnlockUndergroundViewAtStart = true
-- TEMP (testing): fully reveal the underground darkness fog (hr.EnableDarknessReveal=0) whenever
-- the underground map is viewed, so the whole stretched underground is visible without exploring.
-- Vanilla gameplay hides it and reveals by rover proximity. Turn OFF for release.
config.UndergroundRevealAllDarkness = true
-- DecorTopUp restores per-area decor density by cloning each moved decoration (adds ~5-6k extra
-- objects), but that clone burst noticeably slows the load. OFF by default -- the spread decor is
-- usually dense enough; set true if the map feels sparse and you'll accept the slower load.
config.StretchDecorTopUp = false
-- Settle delay (ms) before the STRETCH fill runs. It must be long enough that ALL terrain grids
-- have been resized to the full expanded map before we resample them -- in particular BiomeGrid
-- gets resized LATE, and if the stretch runs before it is full-size the frame keeps the default
-- biome and renders GREY (and the size guard in sbm_terrain_copy skips it). 5000ms is the proven
-- value (matches the a8474a8 build where the whole map stretched correctly). A shorter value loads
-- faster but risks the grey-frame biome issue; the real fix for speed is to poll for grid-readiness
-- rather than lower this blindly.
config.StretchSettleMs = 5000

-- Forced allocation = the 8192-tile hard cap (see QuadrantCopyMaxTerrainTiles).
config.QuadrantCopyForceExpandedTiles = 8192
-- Cap the random generator's working grid to the native source size during DoGenerate, so it
-- never exceeds the engine's GSRP_MAX_SIZE assert on the oversized allocation. Read by the hook.
config.QuadrantCopyLimitGeneratorToSource = true

-- RMG PLACEMENT AUTO-FIT (sbm_rmg_placement.lua). On an expanded map the vanilla
-- generator under-places deposits ("Failed to find a place", e.g. 13 of 23 concrete)
-- and subsurface anomalies ("grid weight is 0, Failed to find any" -> FreeTech 0),
-- because the placement zone (play_zone) is clipped to the playable terrain-type
-- region (gen_zone), each layer then erodes a DepBorder*-wide margin off it, and the
-- fixed preset counts have absolute-distance spacing that cannot fit the smaller
-- zone. Widening gen_zone would fix placement but FLATTENS terrain (gen_zone also
-- drives prefab/terrace shaping). This fix instead relaxes ONLY the placement-side
-- knobs -- it zeroes the per-layer borders and scales spacing/repulse by
-- sqrt(gen_zone coverage) just for the generation, then restores the originals. It
-- never touches gen_zone, prefabs, or the heightmap, so the terrain is unchanged.
-- true = apply on mod-expanded maps; false = exact vanilla placement.
config.EnableRmgPlacementFix = true
-- Zero the per-layer placement borders (DepBorderSurf/Subs/Terr/Anomaly/Effects)
-- during generation. This recovers the candidate cells the border erosion ate and is
-- the main lever that revives FreeTech (whose border defaults to max_border ->
-- DepBorderSubs). true = zero them (recommended), false = leave vanilla borders.
config.RmgPlacementZeroBorders = true
-- Floor on the spacing scale: the auto-fit never tightens spacing below this fraction
-- of vanilla. Set high (0.8) to stay AS CLOSE TO VANILLA as possible -- anomaly
-- spacing is nudged at most ~20% tighter, just enough to seat the trailing FreeTech
-- anomalies (borders-zeroed already fits ~43 of ~50; 0.8 gives comfortable margin).
-- Lower it (e.g. 0.6) only if a dense map ever shows an anomaly shortfall; raise it
-- toward 1.0 for even closer-to-vanilla spacing (with less fit margin).
config.RmgPlacementSpacingFloor = 0.8
-- Scale per-resource DEPOSIT spacing too (shared ResourcePreset). OFF by default:
-- resource deposits already reach their full preset counts at vanilla spacing once
-- the borders are zeroed, so scaling them only makes them denser than vanilla for no
-- benefit. Turn on only if a map ever under-places resource deposits.
config.RmgPlacementScaleDeposits = false
-- Extra squeeze multiplier applied on top of the measured sqrt(coverage) scale
-- (1.0 = auto only). Set below 1.0 to pack tighter than coverage predicts if a run
-- still shows shortfall; the floor above still bounds it. Tune from the
-- DebugRmgPlacement log's placed-vs-coverage numbers.
config.RmgPlacementExtraSqueeze = 1.0
-- Spacing scale used when gen_zone coverage cannot be measured reliably (the type
-- grid read returns an unusable ratio). Borders-only is not enough -- the trailing
-- FreeTech anomalies still starve the subsurface zone -- so the spacing is tightened
-- by this fixed fraction instead. 0.6 = ~1.7x the candidate-cell capacity, which
-- seats the full anomaly set. Scaling never exceeds the preset target counts.
config.RmgPlacementFallbackScale = 0.6

-- SCALE ANOMALY COUNTS TO MAP SIZE (sbm_rmg_placement.lua). The generator places the native
-- (Big) preset anomaly count; spread over the larger 20x20 that is well below vanilla density
-- for the map's size. When true, the anomaly count properties (AnomFreeTechCount/EventCount/
-- TechUnlockCount/BreakthroughCount + BonusCount*) are scaled up by the area factor
-- ((desired/generated tiles)^2 ~= 1.78) before generation, so the generator places
-- proportionally more anomalies WITH correct unique rewards (breakthroughs self-trim to the
-- game's available pool at load -- safe, they just plateau below the full scale). The gen-zone
-- anomaly spacing is tightened to fit the higher count; RespaceAnomalies spreads them after.
-- false = native (Big) anomaly count (leaner research for the bigger map).
config.ScaleAnomalyCountsToMapSize = true
-- Override the anomaly count scale. false = auto (area factor from the map's tile counts). A
-- number forces that multiplier (e.g. 1.5 for a gentler boost, 1.0 to effectively disable).
config.AnomalyCountScaleOverride = false
-- Lower spacing floor used ONLY while fitting the scaled-up anomaly count into the gen-zone
-- (below the normal RmgPlacementSpacingFloor, since more anomalies must fit). Raise toward the
-- normal floor if a run over-packs; lower if the RmgPlacement log shows placement shortfall.
config.AnomalyCountSpacingFloor = 0.35
config.QuadrantCopyMainMapOnly = true
config.QuadrantCopySurfaceOnly = true
config.QuadrantCopyRandomMapsOnly = true
config.QuadrantCopyPatchRandomGenerator = true
-- Copy engine enum flags (collision etc.) onto each mirrored clone (used by the live
-- object-clone helper that the frame mirror plan calls).
config.QuadrantCopyEnumFlags = false

-- Experimental sector (overview-grid) layout, used whenever SuperBigMapSectorGrid
-- is "expanded" or "expanded_with_vanilla_grid". The mod divides the whole map
-- into vanilla-sized sectors; ResolveSectorCount feeds both the built grid and
-- const.SectorCount from the same value, so they always match. When
-- SuperBigMapSectorGrid is "vanilla" the whole patch stays out of the way
-- (EnableVanillaSizedSectors = false) and the game builds its normal 10 x 10
-- playable-area grid.
config.EnableVanillaSizedSectors = sbm_expanded_grid
config.VanillaSectorUniformGrid = true
config.VanillaSectorUseSourceQuadrant = true
config.VanillaSectorSurfaceOnly = true
-- The expanded grid covers the whole loaded map, so it is not restricted to maps
-- that were terrain-expanded.
config.VanillaSectorExpandedOnly = false
-- No fixed number: the count auto-derives so each sector matches the vanilla
-- sector footprint (see ResolveSectorCount in sbm_sectors.lua).
config.VanillaSectorForcedCount = false
-- "expanded_with_vanilla_grid": anchor the grid to the original map's border
-- offset (partial edge sectors) instead of a clean division from the corner.
config.VanillaSectorAlignToVanillaGrid = sbm_align_vanilla_grid
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
-- Typed config view: SuperBigMap.Config
-- ============================================================================
-- The private `config` builder above is the single source of values. This view
-- re-exposes the same values under stable UPPERCASE names plus an ENABLE_MOD master
-- flag, with booleans coerced to real booleans, so the mod's own modules read a
-- clean, typed config (SuperBigMap.Config.*). Edit the settings above, not this view.
local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
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

local function as_string(value, default)
	if type(value) == "string" and value ~= "" then
		return value
	end
	return default
end

local C = {}

-- Lifecycle / master
C.ENABLE_MOD = true

-- Map size + sector grid (master settings)
C.TERRAIN_SIZE = config.SuperBigMapTerrainSize
C.SECTOR_GRID = config.SuperBigMapSectorGrid
C.FULL_MAP_PLAYABLE = as_bool(config.SuperBigMapFullMapPlayable)

-- Debug logging: master + per-scope (see sbm_debug.lua). Logger reads C.DEBUG_<SCOPE>.
C.DEBUG_LOGS          = as_bool(config.EnableDiagnosticLogs)   -- master: enables every scope
C.DEBUG_LIFECYCLE     = as_bool(config.DebugLifecycle)
C.DEBUG_GENERATION    = as_bool(config.DebugGeneration)
C.DEBUG_GENERATIONVERBOSE = as_bool(config.DebugGenerationVerbose)
C.DEBUG_SECTOR        = as_bool(config.DebugSector)
C.DEBUG_SECTORSIZING  = as_bool(config.DebugSectorSizing)
C.DEBUG_DEPOSITS      = as_bool(config.DebugDeposits)
C.DEBUG_RMGPLACEMENT  = as_bool(config.DebugRmgPlacement)
C.DEBUG_STRETCH       = as_bool(config.DebugStretch)
C.DEBUG_LOADING       = as_bool(config.DebugLoading)
C.DEBUG_LOADTIME      = as_bool(config.DebugLoadTime)
C.DEBUG_HOVER         = as_bool(config.DebugHover)
C.DEBUG_OVERVIEW      = as_bool(config.DebugOverview)
C.DEBUG_CAMERA        = as_bool(config.DebugCamera)
C.DEBUG_ROCKET        = as_bool(config.DebugRocket)
C.DEBUG_HEAT          = as_bool(config.DebugHeat)
C.DEBUG_BOUNDS        = as_bool(config.DebugBounds)
C.DEBUG_FAKETERRAIN   = as_bool(config.DebugFakeTerrain)
C.DEBUG_VALIDATION    = as_bool(config.DebugValidation)
C.DEBUG_ZOOM          = as_bool(config.DebugZoom)
C.DEBUG_ZOOMVANILLA   = as_bool(config.DebugZoomVanilla)
C.DEBUG_PREGAMETOGGLE = as_bool(config.DebugPregameToggle)
C.DEBUG_RESTARTNOTICE = as_bool(config.DebugRestartNotice)
C.DEBUG_EDITORCAMERA  = as_bool(config.DebugEditorCamera)
C.DEBUG_INITSEQ       = as_bool(config.DebugInitSeq)
C.DEBUG_CHOSENMAP     = as_bool(config.DebugChosenMap)

-- Settle delay (ms) the post-load mirror plan waits after sectors exist before copying.
C.TEST_COPY_SECTOR_DELAY_MS = as_number(config.TestCopySectorDelayMs, 5000)
C.SECTOR_MIRROR_PLAN_AT_START = as_bool(config.SectorMirrorPlanAtStart)
C.MIRROR_DECOR_SKIP_EVERY_NTH = as_number(config.MirrorDecorSkipEveryNth, 0)
C.MIRROR_SKIP_EDGE_TOUCHING_DECOR = as_bool(config.MirrorSkipEdgeTouchingDecor)
C.WARN_ON_CANNOT_EXPAND = as_bool(config.WarnOnCannotExpand)
C.WARN_OLD_SAVE_NEEDS_NEW_GAME = as_bool(config.WarnOldSaveNeedsNewGame)
C.SHOW_RESTART_NOTICE = as_bool(config.ShowRestartNotice)
C.SCAN_ALL_BUTTON_ENABLED = as_bool(config.ScanAllButtonEnabled)
C.HIDE_CLONED_DEPOSITS_UNTIL_SCAN = as_bool(config.HideClonedDepositsUntilScan)
C.RESHUFFLE_CLONED_DEPOSITS = as_bool(config.ReshuffleClonedDeposits)
C.RESHUFFLE_SEARCH_RADIUS_TILES = as_number(config.ReshuffleSearchRadiusTiles, 12)
C.CLEAR_INITIAL_CONCRETE_IMPRINT = as_bool(config.ClearInitialConcreteImprint)
C.CONCRETE_IMPRINT_MAX_TILES = as_number(config.ConcreteImprintMaxTiles, 0)
C.DEPOSIT_EDGE_MARGIN_TILES = as_number(config.DepositEdgeMarginTiles, 4)
C.RESPACE_ANOMALIES_TO_VANILLA = as_bool(config.RespaceAnomaliesToVanilla)
C.EVEN_OUT_DEPOSIT_DENSITY = as_bool(config.EvenOutDepositDensity)
C.MAX_RESOURCE_DEPOSITS_PER_SECTOR = as_number(config.MaxResourceDepositsPerSector, 3)
C.ENABLE_DEPOSIT_TOPUP = as_bool(config.EnableDepositTopUp)
C.DEPOSIT_COUNT_SCALE_OVERRIDE = (type(config.DepositCountScaleOverride) == "number" and config.DepositCountScaleOverride > 0)
	and config.DepositCountScaleOverride or false
C.EVEN_OUT_START_SECTOR_ANOMALIES = as_bool(config.EvenOutStartSectorAnomalies)
C.ANOMALY_EVEN_SPREAD_FACTOR = as_number(config.AnomalyEvenSpreadFactor, 0.6)
C.REMOVE_FRAME_CRATERS = as_bool(config.RemoveFrameCraters)
C.REMOVE_FRAME_UNDERGROUND_ACCESS = as_bool(config.RemoveFrameUndergroundAccess)
C.SILENCE_BUILDABLE_GRID_SLOW_WARNING = as_bool(config.SilenceBuildableGridSlowWarning)
C.RESNAP_FRAME_OBJECTS = as_bool(config.ResnapFrameObjects)
C.FIX_ROCKET_LANDING_Z = as_bool(config.FixRocketLandingZ)
C.PREVENT_LANDING_PAD_FLATTEN = as_bool(config.PreventLandingPadFlatten)
C.EXPANDED_MAP_EDGE_BORDER = (type(config.ExpandedMapEdgeBorder) == "number" and config.ExpandedMapEdgeBorder >= 0)
	and math.floor(config.ExpandedMapEdgeBorder) or false
C.CLAMP_HEAT_QUERIES = as_bool(config.ClampHeatQueriesOnExpandedMap)
C.FORCE_BUILDABLE_GRID_STORAGE = as_bool(config.ForceBuildableGridStorage)
C.PERMISSIVE_BUILD_ON_EXPANDED = as_bool(config.PermissiveBuildOnExpanded)
C.ALLOW_LANDSCAPING_ON_EXPANDED = as_bool(config.AllowLandscapingOnExpanded)
C.FORCE_FRAME_PASSABLE = as_bool(config.ForceFramePassable)
C.FRAME_PASSABLE_BRIDGE_TILES = as_number(config.FramePassableBridgeTiles, 2)

-- ZoomPlus integration
C.ENABLE_NORMAL_ZOOM_PLUS = as_bool(config.EnableNormalZoomPlus)
C.NORMAL_ZOOM_MULTIPLIER = as_number(config.ZoomPlusLookatDistZoomOutMultiplier, as_number(config.NormalZoomMultiplier, 4.0))
C.ENABLE_MAX_ZOOM_OPTION = as_bool(config.EnableMaxZoomOption)
C.MAX_ZOOM_OPTION_DEFAULT_PERCENT = as_number(config.MaxZoomOptionDefaultPercent, 900)
C.MAX_ZOOM_OPTION_MIN_PERCENT = as_number(config.MaxZoomOptionMinPercent, 100)
C.MAX_ZOOM_OPTION_MAX_PERCENT = as_number(config.MaxZoomOptionMaxPercent, 1200)
C.MAX_ZOOM_OPTION_STEP_PERCENT = as_number(config.MaxZoomOptionStepPercent, 25)
C.OVERVIEW_CAMERA_ZOOM_OUT_LIMIT = as_number(config.OverviewCameraZoomOutLimit, 20000)
C.SEED_STARTUP_OVERVIEW_RETURN_CAMERA = as_bool(config.SeedStartupOverviewReturnCamera)
C.SEED_OVERVIEW_RETURN_SOUTH = as_number(config.SeedOverviewReturnSouth, 100000)
C.SEED_OVERVIEW_RETURN_UP = as_number(config.SeedOverviewReturnUp, 67000)
C.PRE_AIM_OVERVIEW_EXIT = as_bool(config.PreAimOverviewExit)
C.OVERVIEW_EXIT_PAN_TIME = as_number(config.OverviewExitPanTime, 250)
C.TAKEOVER_OVERVIEW_EXIT = as_bool(config.TakeoverOverviewExit)

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
C.EXPANSION_FRAME_MODE = as_bool(config.ExpansionFrameMode)
C.EXPANSION_FRAME_FILL_MODE = as_string(config.ExpansionFrameFillMode, "mirror")
C.STRETCH_SCALE_MARKERS = as_bool(config.StretchScaleMarkers)
C.STRETCH_ENFORCE_SCAN_GATE = as_bool(config.StretchEnforceScanGate)
C.STRETCH_RELOCATE_START_SECTOR = as_bool(config.StretchRelocateStartSector)
C.STRETCH_UNDERGROUND = as_bool(config.StretchUnderground)
C.UNLOCK_UNDERGROUND_VIEW_AT_START = as_bool(config.UnlockUndergroundViewAtStart)
C.UNDERGROUND_REVEAL_ALL_DARKNESS = as_bool(config.UndergroundRevealAllDarkness)
C.STRETCH_DECOR_TOPUP = as_bool(config.StretchDecorTopUp)
C.STRETCH_SETTLE_MS = as_number(config.StretchSettleMs, 800)
C.QUADRANT_FORCE_EXPANDED_TILES = as_number(config.QuadrantCopyForceExpandedTiles, 8192)
C.QUADRANT_LIMIT_GENERATOR_TO_SOURCE = as_bool(config.QuadrantCopyLimitGeneratorToSource)
C.ENABLE_RMG_PLACEMENT_FIX = as_bool(config.EnableRmgPlacementFix)
C.RMG_PLACEMENT_ZERO_BORDERS = as_bool(config.RmgPlacementZeroBorders)
C.RMG_PLACEMENT_SPACING_FLOOR = as_number(config.RmgPlacementSpacingFloor, 0.8)
C.RMG_PLACEMENT_SCALE_DEPOSITS = as_bool(config.RmgPlacementScaleDeposits)
C.RMG_PLACEMENT_EXTRA_SQUEEZE = as_number(config.RmgPlacementExtraSqueeze, 1.0)
C.RMG_PLACEMENT_FALLBACK_SCALE = as_number(config.RmgPlacementFallbackScale, 0.6)
C.SCALE_ANOMALY_COUNTS_TO_MAP_SIZE = as_bool(config.ScaleAnomalyCountsToMapSize)
C.ANOMALY_COUNT_SCALE_OVERRIDE = (type(config.AnomalyCountScaleOverride) == "number" and config.AnomalyCountScaleOverride > 0)
	and config.AnomalyCountScaleOverride or false
C.ANOMALY_COUNT_SPACING_FLOOR = as_number(config.AnomalyCountSpacingFloor, 0.35)
C.QUADRANT_MAIN_MAP_ONLY = as_bool(config.QuadrantCopyMainMapOnly)
C.QUADRANT_SURFACE_ONLY = as_bool(config.QuadrantCopySurfaceOnly)
C.QUADRANT_RANDOM_MAPS_ONLY = as_bool(config.QuadrantCopyRandomMapsOnly)
C.QUADRANT_PATCH_RANDOM_GENERATOR = as_bool(config.QuadrantCopyPatchRandomGenerator)
C.QUADRANT_COPY_ENUM_FLAGS = as_bool(config.QuadrantCopyEnumFlags)

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

SuperBigMap.Config = C

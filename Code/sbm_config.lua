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
-- Reference profile from 626ddb8: Max Zoom Level 900% controls normal selection
-- zoom; overview itself uses 140% terrain distance with a 60-degree 16:9 FOV.
config.OverviewZoomDistancePercent = 140
config.OverviewCameraXYPercent = 28
config.OverviewDistanceMultiplier = 2.5
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
config.DebugGeneration    = true    -- TEMP multi-run verification: authoritative enrichment targets
config.DebugGenerationVerbose = false -- GenerationVerbose: per-object clone spam (very noisy)
config.DebugSector        = false   -- Sector: grid build/patch, visibility, decal cleanup (very noisy; leave off for loading benchmarks)
config.DebugSectorSizing  = true    -- TEMP camera verification: stable 20x20 layout geometry
config.DebugDeposits      = true    -- TEMP multi-run verification: complementary top-up totals and final mix
-- Exhaustive forensic trace for the surface anomaly top-up's outer three-sector ring.
-- Logs the complete live sector topology and raw-world corner orientation, every existing anomaly,
-- every sampled candidate (accepted/rejected with terrain tier), all 204 ring-sector coverage
-- records, stage-one sector draws, stage-two low-area choices, side/bin/layer fallbacks, a 20x20
-- accepted/selected/final matrix, every clone result, overlap checks, and the final scan/reveal
-- audit. This is intentionally very noisy and adds diagnostic overhead only while enabled.
config.DebugTopUpEdgeDistribution = false
config.DebugRmgPlacement  = false   -- RmgPlacement: deposit/anomaly placement auto-fit (coverage, scale, placed counts)
-- Exhaustive trace for the generator's enrichment-placement transaction. Logs every
-- ResolveBuildable/PlaceAnomalies boundary, all relaxed border/spacing values, every private
-- RMG warning argument tuple, and native placed-vs-requested counts. Temporarily enabled while
-- the loading-screen placement failures are being investigated; disable for release.
config.DebugRmgPlacementExhaustive = true -- TEMP multi-run verification: native vs complemented counts
-- Exhaustive read-only alignment trace. When the private generator closure is inaccessible, the
-- sandbox-safe marker-factory path still records actual post-snap hashes/classes/subtypes and
-- correlates collisions with the complete predicted raw-candidate stream. Never moves markers.
config.DebugRmgAlignmentExhaustive = true -- TEMP: identify remaining same-hex marker pairs
-- Correlated census of every resource, anomaly, and effect marker before terrain stretch,
-- immediately after marker scaling, and after the final density suite.
config.DebugEnrichmentPositionsExhaustive = true
-- Mode-independent, read-only trace for comparing enrichment spread with expansion step 01 on
-- and off. It observes the vanilla generator beneath any expansion wrapper and logs generator
-- inputs, procedure random fingerprints, placement-helper results, final factory coordinates,
-- and complete post-generation marker/spread censuses. Leave enabled for both comparison runs.
config.DebugEnrichmentSpreadComparison = true
config.DebugStretch       = false   -- Stretch: per-step stretch frame-fill resample trace
config.DebugLoading       = false   -- Loading: loading-box watch loop + "Please wait" dot animation
config.DebugLoadTime      = false   -- LoadTime: end-to-end load TIMELINE (each phase with total+delta ms, incl. samples during the stretch settle)
-- Exhaustive, read-only loading profiler. Records ordered lifecycle, generator, stretch,
-- loading-footer, and legacy timeline events with cumulative/gap/step durations. It adds
-- no sleeps, yields, scheduling, or behavioral changes; disable after collecting a trace.
config.DebugLoadingSteps  = false
-- Extra loading-performance investigation. Adds nested timings for the expensive terrain,
-- decoration, marker, enrichment, audit, and finalization calls plus a descending per-session
-- summary. Observational only: it never sleeps, yields, changes call order, or invokes extra
-- gameplay work. It does add log/timer overhead, so disable after collecting a representative run.
config.DebugLoadingInvestigation = false
-- Exhaustive first-access trace for deferred underground expansion. Logs every HUD click,
-- map-slot gate decision, state/geometry field, loading-screen transition, fallback path,
-- and preparation result. Keep enabled while investigating underground access.
config.DebugUndergroundAccess = false
config.DebugHover         = false   -- Hover: overview hover-highlight mapping
config.DebugAlign         = false   -- Align: legacy entrance/alignment trace; superseded by DebugEntrancePositions
-- Exhaustive surface-entrance / underground-exit forensic trace. Logs every relevant object,
-- marker, spawner, and linked passage with world+hex positions, terrain/buildability data,
-- pairwise cross-map deltas, and best matches at lifecycle and generation-event snapshots.
config.DebugEntrancePositions = false
config.DebugOverview      = true    -- TEMP camera verification: overview curtains + render-distance
config.DebugCamera        = true    -- TEMP camera verification: destination-bound framing and transitions
config.DebugRocket        = false   -- Rocket: rocket landing Z-snap path
-- Exhaustive trace for rocket/pod terrain changes. Logs patch identity and lifecycle state,
-- construction cursor/template/rocket identity, every mod-map flatten decision, buildable-vs-
-- live terrain Z, and the landing transaction before/after. Temporarily enabled for diagnosis.
config.DebugRocketTerrain = false
-- Optional Elevator terrain-forensics trace. Logs the exact class/global patch identity,
-- incoming construction arguments, both linked passage positions, buildable-vs-live terrain Z,
-- and 13x13 before/after height grids around both Elevator footprints. Disabled for release.
config.DebugElevatorTerrain = false
config.DebugHeat          = false   -- Heat: heat-grid clamp wraps
config.DebugBounds        = false   -- Bounds: playable bounds / PassBorder + buildable wrapper identity (temporary investigation)
config.DebugFakeTerrain   = false   -- FakeTerrain: frame crater cleanup
config.DebugValidation    = false   -- Validation: runtime validation snapshots
config.DebugZoom          = true    -- TEMP camera verification: live zoom limits and ZoomPlus state
config.DebugZoomVanilla   = false   -- ZoomVanilla: normal-map zoom/FOV diagnostics
config.DebugPregameToggle = false   -- PregameToggle: EXPAND MAP button/underline layout diagnostics
config.DebugRestartNotice = false   -- RestartNotice: restart-notice decision path
config.DebugEditorCamera  = false   -- EditorCamera: map-editor camera trace
config.DebugInitSeq       = false   -- InitSeq: step-by-step init/expansion sequence trace
config.DebugChosenMap     = false   -- ChosenMap: one line per map load (id, landing site, coordinates)
config.DebugSpikes        = false   -- Spikes: expensive terrain spike lattice audits
config.DebugPairing       = false   -- Pairing: legacy entrance pairing/pad trace
config.DebugFlatten       = false   -- Flatten: construction-flatten diagnostics
config.DebugGenRand       = false   -- GenRand: generation-determinism trace

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

-- Elevators are snap-only buildings: their natural Surface/Underground Passage already supplies
-- the prepared footprint. Vanilla ElevatorBase:PlaceConstructionSite receives `no_flatten=true`
-- but drops that argument when it creates the two linked sites, which can level the terrain to a
-- stale pre-expansion buildable Z and create a tall pillar. Force both linked Elevator sites and
-- any Elevator cursor/site fallback through the no-flatten path on Super Big Map maps.
config.PreventElevatorFlatten = true

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
-- source. Runs post-load (MirrorPlanSettleMs settle), once per map, with one
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
-- ENRICHMENT TOP-UP SWITCHES. Each expanded-map population can be controlled independently.
config.TopUpResources = true
config.TopUpAnomalies = true
config.TopUpVistas = true
config.TopUpResearchSites = true
config.TopUpMoraleVistas = true
-- Choose whole-map top-up positions by the live enrichment load divided by each sector's
-- sampled eligible terrain capacity. This preserves vanilla's terrain-driven pockets and the
-- original generated marker positions, while filling underrepresented sectors before adding
-- more markers to already-dense ones. Surface anomaly extras keep their separate outer-ring
-- routing below; this switch balances resources/effects and all underground top-up families.
config.TopUpSectorBalancedPlacement = true
-- Every eligible surface anomaly TOP-UP extra is reserved for this many sector rows/columns along
-- all four edges of the FINAL expanded map. Eligible kinds remain exactly the previously selected
-- standard categories: completed/free-tech rewards, technology unlocks, and event sequences
-- (including metal/rare-metal discoveries and large-cache/unique-scenic events). Breakthroughs
-- remain game-pool-capped and are not topped up; unique/other anomaly families are not cloned.
-- Resource, Vista, Research Site, and Morale Vista top-ups avoid this ring. Vanilla-generated
-- markers are not moved by this routing rule.
-- 0 restores whole-map placement with no reserved ring.
config.TopUpAnomalyOuterRingSectors = 3
-- Two-stage surface placement first chooses a random outer-ring sector, independently of terrain.
-- Inside that sector it keeps the least-restrictive viable terrain tier, sorts that tier by terrain
-- height, and randomly chooses within this lowest percentage. 35 means the lowest 35% of the best
-- tier. Passability, obstruction avoidance, and anomaly-hex non-overlap remain hard requirements.
config.TopUpAnomalyLowAreaPercent = 35

-- RESOURCE TOP-UP (sbm_deposits.lua TopUpDeposits). The generator places the native (Big) deposit
-- count; over the larger 20x20 that is below vanilla density. When true, extra source resource
-- deposits are cloned onto terrain-matched frame tiles until the total reaches
-- source_count * area_factor (vanilla density x the bigger area); the clones are hidden until
-- their sector is scanned, and the even-out pass then spreads everything. All resource types
-- scale proportionally, including concrete (a cloned concrete marker paints its own regolith
-- patch on scan). false = native (Big) deposit count.
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

-- TEMP verification control (sbm_place_elevator_button.lua): shows a bottom-right button that
-- enters the normal Elevator placement cursor, force-unlocks the template, and quick-builds the
-- next placed Elevator for free. This exists only to inspect surface/underground correspondence.
-- Set false again before release.
config.PlaceElevatorButtonEnabled = false

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
config.MirrorPlanSettleMs = 5000

-- ============================================================================
-- CORRECTED ENRICHMENT EXPANSION PIPELINE -- INDIVIDUAL STEP SWITCHES
-- ============================================================================
-- The original 19-stage diagnostic contract is retained. Its former step 01 has been expanded
-- into the three high-level stages below, so the complete contract now contains 21 switches.
-- Former steps 02-19 follow as steps 04-21 and remain independently controllable diagnostics.
-- A detailed switch can only run when its owning high-level stage is enabled. Disabling all
-- switches restores pure vanilla allocation, generation, and placement behavior.
--
-- 01: Generate and capture the source on a true vanilla backing, then promote its captured
-- terrain into the expanded destination before any geometric transformation.
config.ExpansionStep01GenerateAndCaptureVanillaSource = true
-- Run the single native RandomMapGenerator transaction on a real vanilla-sized temporary map.
-- InitBuildableGrid, ProcessBuildableGrid, MaskBuildableGrid, GetPlayableArea, and native enrichment
-- placement therefore all consume the same backing and object state as pure vanilla. Only after that
-- transaction finishes are its terrain and generated objects migrated into the expanded destination.
config.GenerateVanillaSourceOnTemporaryBacking = true
-- Disabled while the exact temporary-source transaction is active. The sampler path remains as a
-- diagnostic fallback, but copying terrain/collision state into a blank map cannot reproduce every
-- engine-private map index observed by InitBuildableGrid.
config.UseNativeHeightSamplerBacking = false
-- Mirror only collision-bearing source objects as lightweight entity proxies while the native
-- sampler builds its raw hex grid. This supplies InitBuildableGrid's non-terrain input without
-- running a second RandomMapGenerate or migrating gameplay objects.
config.UseNativeSamplerCollisionMirror = false
-- Use the contributing object's real class for each temporary collision proxy. This preserves
-- class-specific entity state and auto-attached collision surfaces; the sampler map is unloaded
-- immediately after generation, so no proxy becomes a gameplay object.
config.UseExactClassNativeSamplerCollisionProxies = false
-- Experimental exact-source backing mode. Disabled: SetHeightGrid/SetTypeGrid can replace only
-- same-sized live terrain grids, so a vanilla-to-expanded promotion requires a real map-backing
-- replacement rather than an in-place terrain setter.
config.DeferExpandedBackingUntilAfterVanillaSource = false
-- 02: Stretch the source terrain, transform each captured enrichment proportionally, align it
-- to the final hex/terrain height, verify the result, and rebuild the final gameplay grids.
config.ExpansionStep02StretchAndTransformVanillaSource = true
-- 03: Generate only the additional enrichments required by the increased area, treating every
-- transformed native enrichment as an immutable repulsion obstacle, then register and audit them.
config.ExpansionStep03GenerateAdditionalEnrichments = false
-- 04 (former 02): Preserve vanilla enrichment borders, counts, spacing, and repulsion.
config.ExpansionStep04PreserveVanillaEnrichmentRules = true
-- 05 (former 03): Reject exhausted, origin, repeated-coordinate, and repeated-hex native candidates.
config.ExpansionStep05RejectInvalidNativeCandidates = false
-- 06 (former 04): Capture every native enrichment coordinate and target shortfall before stretching.
config.ExpansionStep06CapturePreStretchEnrichments = true
-- 07 (former 05): Stretch the generated source terrain grids to the full expanded allocation.
config.ExpansionStep07StretchTerrain = true
-- 08 (former 06): Scale every native enrichment's X/Y coordinate by the exact terrain scale.
config.ExpansionStep08ScaleNativeEnrichmentXY = true
-- 09 (former 07): Re-snap scaled enrichments to the final live terrain height without changing X/Y.
config.ExpansionStep09ResnapEnrichmentZ = true
-- 10 (former 08): Verify each native post-stretch coordinate against its captured scaled coordinate.
config.ExpansionStep10VerifyNativeScale = true
-- 11 (former 09): Rebuild final passability and buildability before selecting added enrichment.
config.ExpansionStep11RebuildGameplayGrids = true
-- 12 (former 10): Build the coordinate, hex, family, layer, and vanilla-repulsion occupancy index.
config.ExpansionStep12BuildEnrichmentOccupancy = false
-- 13 (former 11): Calculate resource, effect, ordinary-anomaly, and breakthrough additions.
config.ExpansionStep13CalculateEnrichmentAdditions = false
-- 14 (former 12): Apply common bounds, terrain, reachability, uniqueness, and repulsion validation.
config.ExpansionStep14ValidateEnrichmentCandidates = false
-- 15 (former 13): Restrict each family to its configured region, including the anomaly outer ring.
config.ExpansionStep15ApplyCategoryRegions = false
-- 16 (former 14): Run the randomized vanilla or breakthrough farthest-point family selector.
config.ExpansionStep16SelectCategoryCandidates = false
-- 17 (former 15): Reserve each accepted coordinate and aligned hex before selecting another marker.
config.ExpansionStep17ReserveCandidatePositions = false
-- 18 (former 16): Perform final alignment and revalidate the aligned coordinate and hex.
config.ExpansionStep18AlignAndRevalidateCandidates = false
-- 19 (former 17): Construct markers only after their final candidate passes every enabled rule.
config.ExpansionStep19CreateEnrichmentMarkers = false
-- 20 (former 18): Register surface markers and configure underground proximity reveal.
config.ExpansionStep20RegisterAndRevealMarkers = false
-- 21 (former 19): Audit counts, coordinates, hexes, repulsion, regions, and breakthrough spread.
config.ExpansionStep21AuditFinalEnrichments = false

-- Expanded-map allocation. Controlled by SuperBigMapTerrainSize above
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
-- Any unrecognised value falls back to "mirror". IMPLEMENTATION STATUS:
--   "mirror"       -- complete.
--   "stretch"      -- production path: resamples terrain grids, relocates decorations,
--                     enrichments and entrances, then rebuilds final gameplay grids.
--   "desymmetrize" -- not implemented yet; logs a notice and falls back to "mirror".
--   "noise"        -- not implemented yet; logs a notice and falls back to "mirror".
-- The map is always complete/playable whatever is selected.
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
-- Underground enrichment density is restored after the final buildable grid exists.
config.StretchUnderground = true
-- Defer ONLY the expensive underground stretch/post-processing until the player first opens
-- the underground. Vanilla underground generation still runs during new-game loading, so its
-- exits, surface passages, links, and original enrichments exist from the beginning. The first
-- underground map switch is held behind the normal map loading screen until the complete atomic
-- pipeline finishes: terrain stretch, final grids, entrance/marker movement, and all top-ups.
-- This avoids exposing an intermediate underground with stale heights or missing resources.
config.DeferUndergroundExpansionUntilFirstAccess = true
-- Enable the vanilla OVERVIEW mode on the underground map (hover sector-highlight, sector
-- rollover, scan-queue UI -- exactly the surface behavior). Vanilla ships underground maps with
-- IsAllowedToEnterOverview=false, so without this there is no hover highlight underground.
config.UndergroundOverviewEnabled = true
-- Underground hover tooltip (informational ONLY). Vanilla hard-gates the overview sector UI off
-- underground (IsExplorationAvailable_Sectors/Queue return false for Environment=="Underground"),
-- so without this the overview shows nothing on hover there. With it, hovering shows a minimal
-- rollover -- "Sector <name>" + buildable area -- with NO scan status or visual grid, and
-- clicking does NOT queue anything (QueueForExploration is no-op'd for underground sectors).
config.UndergroundExplorationUI = true
-- Underground sectors remain available as invisible data for hover resolution, sector names,
-- and buildable-area percentages. No sector grid, veil, or hover-frame decals are drawn.
-- (Entrance placement correction removed by user decision: entrances receive only the stretch
-- transform itself, like every other object. Vanilla-mismatched pairs stay mismatched.)

-- FLOATER fix: after the stretch, snap objects found hovering >300 wu above the terrain back
-- down onto it (surface map only; Buildings are logged but never touched). The audit itself
-- always logs floaters -- class, height above ground, and whether the decor pass had skipped
-- the object -- under the Align scope.
config.StretchResnapFloaters = true

-- FULL 3D STRETCH: also scale the terrain HEIGHT VALUES by full/source (x1.333), matching the
-- X/Y grid stretch and the object mesh scaling -- a true similarity transform. Restores vanilla
-- slope steepness and object seating geometry (XY-only stretching made slopes 25% shallower
-- while meshes grew x1.333 in all axes; formations sculpted into relief floated). Off = the old
-- wider-and-gentler terrain for comparison.
config.StretchScaleHeights = true

-- RELIEF-AWARE decoration Z (user-designed): before the terrain stretch, annotate each object's
-- relationship to its ground (dz = z - terrain height); after the stretch, place it at the
-- ACTUAL stretched terrain height at its new spot + dz * (full/source). Preserves intentional
-- embedding (half-buried stays proportionally half-buried) and absorbs resample smoothing --
-- the plain SetTerrainZ snap (used as fallback / when off) forces every base onto the surface.
config.StretchReliefAwareDecor = true
-- Move the entrance VISUALS (tunnel signs, entrance structures, CityInit tunnel spawners) with
-- the same position*(full/source) transform as their markers, on BOTH maps (user-confirmed
-- design). Function and visuals stay co-located, every entrance sits on the terrain feature it
-- was generated on, and -- because both maps get the identical transform of natively identical
-- coordinates -- every surface/underground entrance pair keeps corresponding vertically.
config.StretchMoveEntranceVisuals = true
-- Keep the underground-entrance badge seated on the live terrain directly under its side
-- anchor. Nearby relief must not raise the badge; reveal-time sign creation and overview
-- refreshes may update appearance but cannot change its final XY or lift it off the ground.
-- Keep the underground-entrance badge visible at ALL zoom levels. Vanilla renders these
-- signs depth-tested in the close/normal camera (so terrain occludes them; the badge
-- "disappears when you come closer") and on-top only in overview. When true the mod forces
-- the entrance sign to no-depth-test + visible always, so it shows at every zoom.
config.AlwaysShowEntranceSign = true
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
-- LOADING OPTIMIZATIONS (stretch mode only). Defer the provisional blank-map buildability
-- calculation until native ResolveBuildable has generated terrain, and defer MapGenerated's
-- full-map bounds/buildable/passability rebuild because the stretch changes those grids moments
-- later and performs the authoritative final rebuild. Non-stretch paths are untouched. The final
-- sector geometry and max-object-radius refresh still run after stretching.
config.OptimizeStretchDeferredRebuilds = true
-- Apply the surface frame-passable overlay before the stretch's existing full revalidation and
-- avoid rebuilding the same passability grid again afterward. Underground likewise keeps the
-- revalidation performed inside StretchSourceToFull and skips its immediately repeated rebuild.
config.OptimizeStretchPassability = true
-- Use the engine's authoritative map:RebuildGrids once after stretching instead of first
-- performing the same low-level height/type/passability rebuilds separately. Falls back to the
-- legacy sequence automatically if the consolidated engine call is unavailable or fails.
config.OptimizeStretchRevalidation = true
-- Reuse the object list collected while recording pre-stretch decoration relief, avoiding a
-- second full MapForEach traversal immediately after the terrain stretch.
config.OptimizeStretchDecorTraversal = true
-- NewMap would repeat the engine's just-built blank-map buildable grid, and PostNewMapLoaded would
-- rebuild bounds/passability that the stretch immediately invalidates. Defer only the duplicate
-- NewMap buildable pass, then defer the later full Apply exactly like the MapGenerated hooks.
config.OptimizePostLoadDeferredBounds = true
-- Resource top-up builds a large validated candidate pool. Reuse its remaining candidates for
-- anomaly/effect top-ups and register stretch-mode clones at creation time instead of rescanning.
config.OptimizeTopUpPlacementPools = true
-- The editor's own force-passable brush uses SetPassableBox(true) alone. Skip the preceding
-- SetImpassableBox(false) full-frame scan while retaining the old two-write path as a fallback.
config.OptimizeFramePassableWrites = true
-- Wake the already-settled underground stretch thread as soon as surface finalization completes;
-- its timeout remains in place as a fallback when no surface pipeline is active.
config.OptimizeUndergroundWakeHandoff = true

-- Forced allocation = the 8192-tile hard cap (see QuadrantCopyMaxTerrainTiles).
config.QuadrantCopyForceExpandedTiles = 8192
-- Cap the random generator's working grid to the native source size during DoGenerate, so it
-- never exceeds the engine's GSRP_MAX_SIZE assert on the oversized allocation. Read by the hook.
config.QuadrantCopyLimitGeneratorToSource = true
-- RebuildBuildableGrid and MaskBuildableGrid bypass the normal map-size views: they consume
-- the cached map.Width/map.Height and map.hex_width/map.hex_height fields. Temporarily present
-- all four as one vanilla-sized source view during native generation, then restore them and
-- rebuild the full expanded gameplay grid afterward.
config.QuadrantCopyLimitBuildableGridToSource = true
-- Proc_InitPlayZone bypasses terrain.GetMapSize and grows its terrace grid from the real
-- backing terrain via terrain.HeightMapSize. During the exact vanilla-sized source window,
-- temporarily report the source size there too, then copy the resulting source height grid
-- into the expanded backing grid so vanilla never sees 8192 and the destination stays 8192.
config.QuadrantCopyBridgeVanillaHeightGrid = true

-- Legacy RMG placement tuning retained for diagnostic steps 04-05. With the current defaults,
-- step 04 preserves exact vanilla placement and step 05 remains off. Native shortfall completion
-- stays hard-disabled because stage 03 must add enrichments only after the native transform.
-- Zero the per-layer placement borders (DepBorderSurf/Subs/Terr/Anomaly/Effects)
-- during generation. This recovers the candidate cells the border erosion ate and is
-- the main lever that revives FreeTech (whose border defaults to max_border ->
-- DepBorderSubs). true = zero them (recommended), false = leave vanilla borders.
config.RmgPlacementZeroBorders = true
-- Floor on the base resource/effect spacing scale. 0.6 is the closest observed setting
-- that seats the full native resource set while retaining useful separation. Same-anomaly
-- packing has its own narrowly lower cap below because those markers share one eroded mask.
config.RmgPlacementSpacingFloor = 0.6
-- Resource layers share the same clipped play zone and mutually erase candidates through
-- RepulseAll. Scale their ResourcePreset distances with the measured coverage too; zeroing
-- borders alone cannot recover cells already consumed by earlier layers (the 11/27 Concrete
-- failure in the diagnostic run).
config.RmgPlacementScaleDeposits = true
-- Extra squeeze multiplier applied on top of the measured sqrt(coverage) scale
-- (1.0 = auto only). Set below 1.0 to pack tighter than coverage predicts if a run
-- still shows shortfall; the floor above still bounds it. Tune from the
-- DebugRmgPlacement log's placed-vs-coverage numbers.
config.RmgPlacementExtraSqueeze = 1.0
-- Known-safe scale from the observed worst case. It is both the fallback when the exact
-- work-grid read is unavailable and the upper cap on coverage-derived spacing: area coverage
-- alone cannot model fragmented zones or the sequential cross-layer repulsion erosion.
config.RmgPlacementFallbackScale = 0.6
-- Separate upper cap for same-anomaly spacing. Ordinary TechUnlock/Event/FreeTech markers
-- all share the native subs/Anomaly mask, and every placed marker erases a circle with radius
-- twice AnomalySpacing from that mask. The observed 15-work-cell setting left only six slots
-- for seven FreeTech markers after TechUnlock and Event placement. 0.55 rounds the stock
-- 20000-unit value down to 10400 (13 work cells), cutting that destructive area by about 25%
-- without changing resource spacing or AnomalyRepulseSubs/All. 1.0 disables this extra cap.
config.RmgPlacementAnomalySpacingCap = 0.55

-- SCALE ANOMALY COUNTS TO MAP SIZE (sbm_rmg_placement.lua). The generator places the native
-- (Big) preset anomaly count; spread over the larger 20x20 that is well below vanilla density
-- for the map's size. When true, the anomaly count properties (AnomFreeTechCount/EventCount/
-- TechUnlockCount/BreakthroughCount + BonusCount*) are scaled up by the area factor
-- ((desired/generated tiles)^2 ~= 1.78) before generation, so the generator places
-- proportionally more anomalies WITH correct unique rewards (breakthroughs self-trim to the
-- game's available pool at load -- safe, they just plateau below the full scale). The gen-zone
-- anomaly spacing is tightened to fit the higher count; RespaceAnomalies spreads them after.
-- false = native (Big) anomaly count (leaner research for the bigger map).
-- NOTE: in STRETCH fill mode only the in-generation COUNT scaling is skipped. The placement
-- auto-fit starts later at PlaceAnomalies, after terrain/prefab generation, so it can satisfy
-- the native source-map enrichment counts without changing terrain or prefab placement. The
-- post-generation top-up below then supplies the additional full-map density.
-- POST-GENERATION anomaly top-up (sbm_deposits.lua TopUpAnomalies) -- the stretch-mode
-- replacement for in-generation count scaling. After generation, clones anomaly MARKERS
-- (categories preserved via property copy; rewards resolve at scan; breakthroughs stay
-- pool-capped by the game) up to vanilla density x area factor, onto unscanned-sector tiles,
-- hidden + sector-registered so a real scan reveals them. Generator output stays bit-identical
-- to vanilla.
-- EFFECT-DEPOSIT TOP-UP (sbm_deposits.lua TopUpEffectDeposits). EffectDepositMarker is the
-- marker family behind Vistas, Research Sites, and marker-backed Morale Vistas. Stretching increases the terrain area by
-- ~1.78x but otherwise leaves their generator counts unchanged, so this independently tops
-- enabled effect types up to their source count x area factor. The three per-type switches above
-- let each family be controlled separately. Surface extras are randomly distributed outside the
-- anomaly-only outer ring and require passable, flat, buildable, unobstructed terrain.
-- VANILLA-EXACT PLAY ZONE (sbm_map_generation DoGenerate). The expansion zeroes
-- mapdata.PassBorder before ChangeMap so the whole expanded map is passable -- but the
-- generator also reads PassBorder to compute its play zone (GetPlayableArea, BiomeFiller POI
-- frame), so 0 gave it a BIGGER play zone than vanilla and diverged the per-proc random
-- stream (same lake prefab at another position/rotation). When true, the ORIGINAL PassBorder
-- is restored for just the DoGenerate window (the engine already baked full passability at
-- ChangeMap; only the generator's Lua-side reads see the restored value) and re-zeroed after.
config.StretchVanillaExactPassBorder = true
-- FLATTEN GUARD (sbm_rocket_rules flatten wrapper). On MOD maps, skip the engine
-- construction flatten when the site's anchor hex reads UNBUILDABLE from the buildable
-- z-grid -- the C flatten asserts (HGE::FlattenTerrainInShape: z != nUnbuildableZ) on
-- exactly that condition; vanilla's Lua reference implementation skips unbuildable hexes
-- the same way. Root cause was stale height ranges after the 3D stretch (see
-- ScaleHeightRanges); this guard keeps any residual case from crashing.
config.FlattenSkipWhenUnbuildable = true
-- DETERMINISTIC PASSAGE PAIRING (sbm_map_generation PatchPassagePairing). Vanilla spawns
-- each SURFACE underground-entrance by searching the surface buildable grid around the
-- underground marker's position, falling back to a RANDOM passable position when the search
-- fails. On expanded maps that search races the async buildable-grid build and the stretch,
-- so an entrance could land somewhere DIFFERENT every restart (sometimes on mountains).
-- When true, expanded maps place the surface passage exactly at the underground marker's
-- position (hex+terrain snapped, obstructions cleared by the caller as usual) -- fully
-- deterministic and correspondence-preserving. Vanilla-size maps always run the original.
-- RE-ENABLED (2026-07-11) and tightened to preserve vertical correspondence:
-- (a) PairingSurfaceBuildableRebuild proves/reuses the native ResolveBuildable grid (with a
--     synchronous rebuild fallback) -- the spike crowns came from a sentinel-poisoned grid;
-- (b) every linked surface passage first tests the underground exit's equivalent anchor hex;
--     if the complete Elevator footprint is not buildable there, it selects the closest
--     buildable candidate by hex distance;
-- (c) the pad repairs are footprint-sized everywhere (v441's leftover ring came from the
--     abandoned-spot repair still using a hardcoded small circle).
-- Net: every surface entrance occupies the same hex as its underground exit whenever that
-- complete surface footprint is buildable; otherwise it occupies the closest buildable hex.
config.StretchDeterministicPassages = true
-- DETERMINISTIC PAIRING, the no-terrain-touching way (sbm_map_generation, DoGenerate). The
-- entrance pairing searches the SURFACE buildable grid during the UNDERGROUND generation;
-- the mod now records whether native surface ResolveBuildable already produced the authoritative
-- grid. When true, pairing reuses that exact grid; if proof is absent it synchronously rebuilds
-- as a correctness fallback. Both paths restore deterministic vanilla search conditions without
-- editing terrain (unlike the retired forced-position correction chain).
config.PairingSurfaceBuildableRebuild = true
-- Post-generation smoothing of the ground around each entrance footprint (GridSmooth, the
-- engine's own terrain filter): the game's entrance flatten is per-hex, which leaves faint
-- hex terracing (zigzag creases) even with clean height values. Runs once pre-stretch.
config.PassagePadSmoothing = true
-- HEIGHT BUDGET (sbm_terrain_copy stretch_one). The height grid is 16-bit (0..65535); on
-- high-relief maps the x4/3 height scale overflows the ceiling (60657*4/3 = 80876) and the
-- tallest peaks clip into flat plateaus. Two remedies (user decision "shift + adaptive
-- z-scale"), applied as one affine transform h' = h*zmul/zdiv + zadd:
-- Shift the whole height field down so the SOURCE minimum lands ~1 m above 0 -- frees
-- min*scale of headroom at the top. Pure translation: slopes and relief unchanged.
config.StretchShiftHeightsDown = true
-- If the span STILL overflows after the shift, reduce ONLY the Z scale to exactly fit:
-- zmul/zdiv = (cap-margin)/(max-min) (~1.20 on the reference map vs 1.333). Slopes come out
-- ~90% of vanilla steepness ONLY on maps that need it; most maps keep the full 4/3. The
-- relief-dz and height-range consumers read the stamped factor, so seating stays correct.
config.StretchAdaptiveZScale = true
-- VANILLA-EQUIVALENT START SECTOR (sbm_sector_exploration PatchInitialExplore +
-- RevealVanillaStartSectors). Vanilla picks the initially revealed sector by resource
-- quality over its 10x10 grid with a map-seed-deterministic weighted rand; on the expanded
-- 20x20 grid the same algorithm picks somewhere else. When true, vanilla's OWN InitialReveal
-- runs over virtual 10x10 sectors at vanilla geometry (same markers, play_ratio, heat,
-- seeded rand), and after the stretch the expanded sectors covering the winner's x4/3 box
-- are revealed instead (replaces the legacy start-sector relocation on this path).
config.StretchVanillaStartSector = true
config.DebugStartSector = false     -- StartSector: virtual-sector candidates + weights, the vanilla pick, and the post-stretch reveal trace
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

local expansion_step_01 = as_bool(config.ExpansionStep01GenerateAndCaptureVanillaSource)
local expansion_step_02 = expansion_step_01
	and as_bool(config.ExpansionStep02StretchAndTransformVanillaSource)
local expansion_step_03 = expansion_step_02
	and as_bool(config.ExpansionStep03GenerateAdditionalEnrichments)
local expansion_step_04 = expansion_step_01
	and as_bool(config.ExpansionStep04PreserveVanillaEnrichmentRules)
local expansion_step_05 = expansion_step_01
	and as_bool(config.ExpansionStep05RejectInvalidNativeCandidates)
local expansion_step_06 = expansion_step_01
	and as_bool(config.ExpansionStep06CapturePreStretchEnrichments)
local expansion_step_07 = expansion_step_02
	and as_bool(config.ExpansionStep07StretchTerrain)
local expansion_step_08 = expansion_step_02
	and as_bool(config.ExpansionStep08ScaleNativeEnrichmentXY)
local expansion_step_09 = expansion_step_02
	and as_bool(config.ExpansionStep09ResnapEnrichmentZ)
local expansion_step_10 = expansion_step_02
	and as_bool(config.ExpansionStep10VerifyNativeScale)
local expansion_step_11 = expansion_step_02
	and as_bool(config.ExpansionStep11RebuildGameplayGrids)
local expansion_step_12 = expansion_step_03
	and as_bool(config.ExpansionStep12BuildEnrichmentOccupancy)
local expansion_step_13 = expansion_step_03
	and as_bool(config.ExpansionStep13CalculateEnrichmentAdditions)
local expansion_step_14 = expansion_step_03
	and as_bool(config.ExpansionStep14ValidateEnrichmentCandidates)
local expansion_step_15 = expansion_step_03
	and as_bool(config.ExpansionStep15ApplyCategoryRegions)
local expansion_step_16 = expansion_step_03
	and as_bool(config.ExpansionStep16SelectCategoryCandidates)
local expansion_step_17 = expansion_step_03
	and as_bool(config.ExpansionStep17ReserveCandidatePositions)
local expansion_step_18 = expansion_step_03
	and as_bool(config.ExpansionStep18AlignAndRevalidateCandidates)
local expansion_step_19 = expansion_step_03
	and as_bool(config.ExpansionStep19CreateEnrichmentMarkers)
-- Registration/reveal also finalizes transformed native markers, so it belongs to stage 02.
local expansion_step_20 = expansion_step_02
	and as_bool(config.ExpansionStep20RegisterAndRevealMarkers)
local expansion_step_21 = expansion_step_03
	and as_bool(config.ExpansionStep21AuditFinalEnrichments)

-- Lifecycle / master
C.ENABLE_MOD = true

-- Map size + sector grid (master settings)
C.TERRAIN_SIZE = expansion_step_01
	and config.SuperBigMapTerrainSize or "vanilla"
C.SECTOR_GRID = expansion_step_01
	and config.SuperBigMapSectorGrid or "vanilla"
C.FULL_MAP_PLAYABLE = expansion_step_01
	and as_bool(config.SuperBigMapFullMapPlayable)

-- Debug logging: master + per-scope (see sbm_debug.lua). Logger reads C.DEBUG_<SCOPE>.
C.DEBUG_LOGS          = as_bool(config.EnableDiagnosticLogs)   -- master: enables every scope
C.DEBUG_LIFECYCLE     = as_bool(config.DebugLifecycle)
C.DEBUG_GENERATION    = as_bool(config.DebugGeneration)
C.DEBUG_GENRAND       = as_bool(config.DebugGenRand)
C.DEBUG_FLATTEN       = as_bool(config.DebugFlatten)
C.DEBUG_PAIRING       = as_bool(config.DebugPairing)
C.DEBUG_SPIKES        = as_bool(config.DebugSpikes)
C.DEBUG_GENERATIONVERBOSE = as_bool(config.DebugGenerationVerbose)
C.DEBUG_SECTOR        = as_bool(config.DebugSector)
C.DEBUG_SECTORSIZING  = as_bool(config.DebugSectorSizing)
C.DEBUG_DEPOSITS      = as_bool(config.DebugDeposits)
C.DEBUG_TOPUPEDGEDISTRIBUTION = as_bool(config.DebugTopUpEdgeDistribution)
C.DEBUG_RMGPLACEMENT  = as_bool(config.DebugRmgPlacement)
C.DEBUG_RMGPLACEMENTEXHAUSTIVE = as_bool(config.DebugRmgPlacementExhaustive)
C.DEBUG_RMGALIGNMENTEXHAUSTIVE = as_bool(config.DebugRmgAlignmentExhaustive)
C.DEBUG_ENRICHMENTPOSITIONSEXHAUSTIVE = as_bool(config.DebugEnrichmentPositionsExhaustive)
C.DEBUG_ENRICHMENTSPREADCOMPARISON = as_bool(config.DebugEnrichmentSpreadComparison)
C.DEBUG_STRETCH       = as_bool(config.DebugStretch)
C.DEBUG_LOADING       = as_bool(config.DebugLoading)
C.DEBUG_LOADTIME      = as_bool(config.DebugLoadTime)
C.DEBUG_LOADINGSTEPS  = as_bool(config.DebugLoadingSteps)
C.DEBUG_LOADINGINVESTIGATION = as_bool(config.DebugLoadingInvestigation)
C.DEBUG_UNDERGROUNDACCESS = as_bool(config.DebugUndergroundAccess)
C.DEBUG_HOVER         = as_bool(config.DebugHover)
C.DEBUG_ALIGN         = as_bool(config.DebugAlign)
C.DEBUG_ENTRANCEPOSITIONS = as_bool(config.DebugEntrancePositions)
C.DEBUG_OVERVIEW      = as_bool(config.DebugOverview)
C.DEBUG_CAMERA        = as_bool(config.DebugCamera)
C.DEBUG_ROCKET        = as_bool(config.DebugRocket)
C.DEBUG_ROCKETTERRAIN = as_bool(config.DebugRocketTerrain)
C.DEBUG_ELEVATORTERRAIN = as_bool(config.DebugElevatorTerrain)
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
C.MIRROR_PLAN_SETTLE_MS = as_number(config.MirrorPlanSettleMs, 5000)
C.SECTOR_MIRROR_PLAN_AT_START = expansion_step_07
	and as_bool(config.SectorMirrorPlanAtStart)
C.MIRROR_DECOR_SKIP_EVERY_NTH = as_number(config.MirrorDecorSkipEveryNth, 0)
C.MIRROR_SKIP_EDGE_TOUCHING_DECOR = as_bool(config.MirrorSkipEdgeTouchingDecor)
C.WARN_ON_CANNOT_EXPAND = as_bool(config.WarnOnCannotExpand)
C.WARN_OLD_SAVE_NEEDS_NEW_GAME = as_bool(config.WarnOldSaveNeedsNewGame)
C.SHOW_RESTART_NOTICE = as_bool(config.ShowRestartNotice)
C.PLACE_ELEVATOR_BUTTON_ENABLED = as_bool(config.PlaceElevatorButtonEnabled)
C.HIDE_CLONED_DEPOSITS_UNTIL_SCAN = as_bool(config.HideClonedDepositsUntilScan)
C.RESHUFFLE_CLONED_DEPOSITS = as_bool(config.ReshuffleClonedDeposits)
C.RESHUFFLE_SEARCH_RADIUS_TILES = as_number(config.ReshuffleSearchRadiusTiles, 12)
C.CLEAR_INITIAL_CONCRETE_IMPRINT = as_bool(config.ClearInitialConcreteImprint)
C.CONCRETE_IMPRINT_MAX_TILES = as_number(config.ConcreteImprintMaxTiles, 0)
C.DEPOSIT_EDGE_MARGIN_TILES = as_number(config.DepositEdgeMarginTiles, 4)
C.RESPACE_ANOMALIES_TO_VANILLA = expansion_step_16
	and as_bool(config.RespaceAnomaliesToVanilla)
C.EVEN_OUT_DEPOSIT_DENSITY = expansion_step_16
	and as_bool(config.EvenOutDepositDensity)
C.MAX_RESOURCE_DEPOSITS_PER_SECTOR = as_number(config.MaxResourceDepositsPerSector, 3)
C.TOPUP_RESOURCES = expansion_step_13
	and as_bool(config.TopUpResources)
C.TOPUP_ANOMALIES = expansion_step_13
	and as_bool(config.TopUpAnomalies)
C.TOPUP_VISTAS = expansion_step_13
	and as_bool(config.TopUpVistas)
C.TOPUP_RESEARCH_SITES = expansion_step_13
	and as_bool(config.TopUpResearchSites)
C.TOPUP_MORALE_VISTAS = expansion_step_13
	and as_bool(config.TopUpMoraleVistas)
C.TOPUP_SECTOR_BALANCED_PLACEMENT = as_bool(config.TopUpSectorBalancedPlacement)
C.TOPUP_ANOMALY_OUTER_RING_SECTORS = as_number(config.TopUpAnomalyOuterRingSectors, 3)
C.TOPUP_ANOMALY_LOW_AREA_PERCENT = as_number(config.TopUpAnomalyLowAreaPercent, 35)
C.DEPOSIT_COUNT_SCALE_OVERRIDE = (type(config.DepositCountScaleOverride) == "number" and config.DepositCountScaleOverride > 0)
	and config.DepositCountScaleOverride or false
C.EVEN_OUT_START_SECTOR_ANOMALIES = as_bool(config.EvenOutStartSectorAnomalies)
C.ANOMALY_EVEN_SPREAD_FACTOR = as_number(config.AnomalyEvenSpreadFactor, 0.6)
C.REMOVE_FRAME_CRATERS = as_bool(config.RemoveFrameCraters)
C.REMOVE_FRAME_UNDERGROUND_ACCESS = as_bool(config.RemoveFrameUndergroundAccess)
C.RESNAP_FRAME_OBJECTS = as_bool(config.ResnapFrameObjects)
C.FIX_ROCKET_LANDING_Z = as_bool(config.FixRocketLandingZ)
C.PREVENT_LANDING_PAD_FLATTEN = as_bool(config.PreventLandingPadFlatten)
C.PREVENT_ELEVATOR_FLATTEN = as_bool(config.PreventElevatorFlatten)
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

-- Corrected enrichment expansion pipeline: three high-level stages plus the retained
-- independently switchable diagnostics from the original 19-stage contract.
C.EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE =
	expansion_step_01
C.GENERATE_VANILLA_SOURCE_ON_TEMPORARY_BACKING = expansion_step_01
	and as_bool(config.GenerateVanillaSourceOnTemporaryBacking)
C.USE_NATIVE_HEIGHT_SAMPLER_BACKING = expansion_step_01
	and as_bool(config.UseNativeHeightSamplerBacking)
C.USE_NATIVE_SAMPLER_COLLISION_MIRROR = C.USE_NATIVE_HEIGHT_SAMPLER_BACKING
	and as_bool(config.UseNativeSamplerCollisionMirror)
C.USE_EXACT_CLASS_NATIVE_SAMPLER_COLLISION_PROXIES = C.USE_NATIVE_SAMPLER_COLLISION_MIRROR
	and as_bool(config.UseExactClassNativeSamplerCollisionProxies)
C.DEFER_EXPANDED_BACKING_UNTIL_AFTER_VANILLA_SOURCE = expansion_step_01
	and as_bool(config.DeferExpandedBackingUntilAfterVanillaSource)
C.EXPANSION_STEP_02_STRETCH_AND_TRANSFORM_VANILLA_SOURCE =
	expansion_step_02
C.EXPANSION_STEP_03_GENERATE_ADDITIONAL_ENRICHMENTS =
	expansion_step_03
C.EXPANSION_STEP_04_PRESERVE_VANILLA_ENRICHMENT_RULES = expansion_step_04
C.EXPANSION_STEP_05_REJECT_INVALID_NATIVE_CANDIDATES = expansion_step_05
C.EXPANSION_STEP_06_CAPTURE_PRE_STRETCH_ENRICHMENTS = expansion_step_06
C.EXPANSION_STEP_07_STRETCH_TERRAIN = expansion_step_07
C.EXPANSION_STEP_08_SCALE_NATIVE_ENRICHMENT_XY = expansion_step_08
C.EXPANSION_STEP_09_RESNAP_ENRICHMENT_Z = expansion_step_09
C.EXPANSION_STEP_10_VERIFY_NATIVE_SCALE = expansion_step_10
C.EXPANSION_STEP_11_REBUILD_GAMEPLAY_GRIDS = expansion_step_11
C.EXPANSION_STEP_12_BUILD_ENRICHMENT_OCCUPANCY = expansion_step_12
C.EXPANSION_STEP_13_CALCULATE_ENRICHMENT_ADDITIONS = expansion_step_13
C.EXPANSION_STEP_14_VALIDATE_ENRICHMENT_CANDIDATES = expansion_step_14
C.EXPANSION_STEP_15_APPLY_CATEGORY_REGIONS = expansion_step_15
C.EXPANSION_STEP_16_SELECT_CATEGORY_CANDIDATES = expansion_step_16
C.EXPANSION_STEP_17_RESERVE_CANDIDATE_POSITIONS = expansion_step_17
C.EXPANSION_STEP_18_ALIGN_AND_REVALIDATE_CANDIDATES = expansion_step_18
C.EXPANSION_STEP_19_CREATE_ENRICHMENT_MARKERS = expansion_step_19
C.EXPANSION_STEP_20_REGISTER_AND_REVEAL_MARKERS = expansion_step_20
C.EXPANSION_STEP_21_AUDIT_FINAL_ENRICHMENTS = expansion_step_21
C.EXPANSION_ENRICHMENT_STEPS = {
	C.EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE,
	C.EXPANSION_STEP_02_STRETCH_AND_TRANSFORM_VANILLA_SOURCE,
	C.EXPANSION_STEP_03_GENERATE_ADDITIONAL_ENRICHMENTS,
	C.EXPANSION_STEP_04_PRESERVE_VANILLA_ENRICHMENT_RULES,
	C.EXPANSION_STEP_05_REJECT_INVALID_NATIVE_CANDIDATES,
	C.EXPANSION_STEP_06_CAPTURE_PRE_STRETCH_ENRICHMENTS,
	C.EXPANSION_STEP_07_STRETCH_TERRAIN,
	C.EXPANSION_STEP_08_SCALE_NATIVE_ENRICHMENT_XY,
	C.EXPANSION_STEP_09_RESNAP_ENRICHMENT_Z,
	C.EXPANSION_STEP_10_VERIFY_NATIVE_SCALE,
	C.EXPANSION_STEP_11_REBUILD_GAMEPLAY_GRIDS,
	C.EXPANSION_STEP_12_BUILD_ENRICHMENT_OCCUPANCY,
	C.EXPANSION_STEP_13_CALCULATE_ENRICHMENT_ADDITIONS,
	C.EXPANSION_STEP_14_VALIDATE_ENRICHMENT_CANDIDATES,
	C.EXPANSION_STEP_15_APPLY_CATEGORY_REGIONS,
	C.EXPANSION_STEP_16_SELECT_CATEGORY_CANDIDATES,
	C.EXPANSION_STEP_17_RESERVE_CANDIDATE_POSITIONS,
	C.EXPANSION_STEP_18_ALIGN_AND_REVALIDATE_CANDIDATES,
	C.EXPANSION_STEP_19_CREATE_ENRICHMENT_MARKERS,
	C.EXPANSION_STEP_20_REGISTER_AND_REVEAL_MARKERS,
	C.EXPANSION_STEP_21_AUDIT_FINAL_ENRICHMENTS,
}

-- Map generation (quadrant tiling)
C.ENABLE_QUADRANT_MAP_COPY = expansion_step_01
	and as_bool(config.EnableQuadrantMapCopy)
C.QUADRANT_COPY_SCALE = as_number(config.QuadrantCopyScale, 2)
C.QUADRANT_MAX_TERRAIN_TILES = as_number(config.QuadrantCopyMaxTerrainTiles, 8192)
C.QUADRANT_MAX_RANDOM_GENERATOR_TILES = as_number(config.QuadrantCopyMaxRandomGeneratorTiles, 6144)
C.QUADRANT_RENDERER_NODE_TILE_ALIGNMENT = as_number(config.QuadrantCopyRendererNodeTileAlignment, 2048)
C.EXPANSION_FRAME_MODE = expansion_step_01
	and as_bool(config.ExpansionFrameMode)
C.EXPANSION_FRAME_FILL_MODE = as_string(config.ExpansionFrameFillMode, "mirror")
C.STRETCH_SCALE_MARKERS = expansion_step_08
	and as_bool(config.StretchScaleMarkers)
C.STRETCH_ENFORCE_SCAN_GATE = expansion_step_20
	and as_bool(config.StretchEnforceScanGate)
C.STRETCH_RELOCATE_START_SECTOR = as_bool(config.StretchRelocateStartSector)
C.STRETCH_UNDERGROUND = expansion_step_07
	and as_bool(config.StretchUnderground)
C.DEFER_UNDERGROUND_EXPANSION_UNTIL_FIRST_ACCESS = as_bool(config.DeferUndergroundExpansionUntilFirstAccess)
C.UNDERGROUND_OVERVIEW_ENABLED = as_bool(config.UndergroundOverviewEnabled)
C.UNDERGROUND_EXPLORATION_UI = as_bool(config.UndergroundExplorationUI)
C.STRETCH_MOVE_ENTRANCE_VISUALS = expansion_step_08
	and as_bool(config.StretchMoveEntranceVisuals)
C.ALWAYS_SHOW_ENTRANCE_SIGN = as_bool(config.AlwaysShowEntranceSign)
C.STRETCH_RESNAP_FLOATERS = as_bool(config.StretchResnapFloaters)
C.STRETCH_SCALE_HEIGHTS = as_bool(config.StretchScaleHeights)
C.STRETCH_RELIEF_AWARE_DECOR = as_bool(config.StretchReliefAwareDecor)
C.STRETCH_DECOR_TOPUP = as_bool(config.StretchDecorTopUp)
C.STRETCH_SETTLE_MS = as_number(config.StretchSettleMs, 800)
C.OPTIMIZE_STRETCH_DEFERRED_REBUILDS = as_bool(config.OptimizeStretchDeferredRebuilds)
C.OPTIMIZE_STRETCH_PASSABILITY = as_bool(config.OptimizeStretchPassability)
C.OPTIMIZE_STRETCH_REVALIDATION = as_bool(config.OptimizeStretchRevalidation)
C.OPTIMIZE_STRETCH_DECOR_TRAVERSAL = as_bool(config.OptimizeStretchDecorTraversal)
C.OPTIMIZE_POSTLOAD_DEFERRED_BOUNDS = as_bool(config.OptimizePostLoadDeferredBounds)
C.OPTIMIZE_TOPUP_PLACEMENT_POOLS = as_bool(config.OptimizeTopUpPlacementPools)
C.OPTIMIZE_FRAME_PASSABLE_WRITES = as_bool(config.OptimizeFramePassableWrites)
C.OPTIMIZE_UNDERGROUND_WAKE_HANDOFF = as_bool(config.OptimizeUndergroundWakeHandoff)
C.QUADRANT_FORCE_EXPANDED_TILES = as_number(config.QuadrantCopyForceExpandedTiles, 8192)
C.QUADRANT_LIMIT_GENERATOR_TO_SOURCE = expansion_step_01
	and as_bool(config.QuadrantCopyLimitGeneratorToSource)
C.QUADRANT_LIMIT_BUILDABLE_GRID_TO_SOURCE = expansion_step_01
	and as_bool(config.QuadrantCopyLimitBuildableGridToSource)
C.QUADRANT_BRIDGE_VANILLA_HEIGHT_GRID = expansion_step_01
	and as_bool(config.QuadrantCopyBridgeVanillaHeightGrid)
C.ENABLE_RMG_PLACEMENT_FIX = expansion_step_01
	and not expansion_step_04
C.COMPLETE_NATIVE_ENRICHMENT_SHORTFALLS = false
C.ENABLE_NATIVE_ALIGNED_HEX_COLLISION_REPAIR = expansion_step_05
C.RMG_PLACEMENT_ZERO_BORDERS = as_bool(config.RmgPlacementZeroBorders)
C.RMG_PLACEMENT_SPACING_FLOOR = as_number(config.RmgPlacementSpacingFloor, 0.6)
C.RMG_PLACEMENT_SCALE_DEPOSITS = as_bool(config.RmgPlacementScaleDeposits)
C.RMG_PLACEMENT_EXTRA_SQUEEZE = as_number(config.RmgPlacementExtraSqueeze, 1.0)
C.RMG_PLACEMENT_FALLBACK_SCALE = as_number(config.RmgPlacementFallbackScale, 0.6)
C.RMG_PLACEMENT_ANOMALY_SPACING_CAP = as_number(config.RmgPlacementAnomalySpacingCap, 0.55)
C.STRETCH_VANILLA_EXACT_PASSBORDER = expansion_step_04
	and as_bool(config.StretchVanillaExactPassBorder)
C.FLATTEN_SKIP_WHEN_UNBUILDABLE = as_bool(config.FlattenSkipWhenUnbuildable)
C.STRETCH_DETERMINISTIC_PASSAGES = expansion_step_08
	and as_bool(config.StretchDeterministicPassages)
C.PAIRING_SURFACE_BUILDABLE_REBUILD = expansion_step_11
	and as_bool(config.PairingSurfaceBuildableRebuild)
C.PASSAGE_PAD_SMOOTHING = expansion_step_11
	and as_bool(config.PassagePadSmoothing)
C.STRETCH_SHIFT_HEIGHTS_DOWN = as_bool(config.StretchShiftHeightsDown)
C.STRETCH_ADAPTIVE_Z_SCALE = as_bool(config.StretchAdaptiveZScale)
C.STRETCH_VANILLA_START_SECTOR = expansion_step_20
	and as_bool(config.StretchVanillaStartSector)
C.DEBUG_STARTSECTOR   = as_bool(config.DebugStartSector)
C.ANOMALY_COUNT_SCALE_OVERRIDE = (type(config.AnomalyCountScaleOverride) == "number" and config.AnomalyCountScaleOverride > 0)
	and config.AnomalyCountScaleOverride or false
C.ANOMALY_COUNT_SPACING_FLOOR = as_number(config.AnomalyCountSpacingFloor, 0.35)
C.QUADRANT_MAIN_MAP_ONLY = as_bool(config.QuadrantCopyMainMapOnly)
C.QUADRANT_SURFACE_ONLY = as_bool(config.QuadrantCopySurfaceOnly)
C.QUADRANT_RANDOM_MAPS_ONLY = as_bool(config.QuadrantCopyRandomMapsOnly)
C.QUADRANT_PATCH_RANDOM_GENERATOR =
	expansion_step_01
	and as_bool(config.QuadrantCopyPatchRandomGenerator)
C.QUADRANT_COPY_ENUM_FLAGS = as_bool(config.QuadrantCopyEnumFlags)

-- Sectors (grid layout + exploration)
C.ENABLE_VANILLA_SIZED_SECTORS = expansion_step_01
	and as_bool(config.EnableVanillaSizedSectors)
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

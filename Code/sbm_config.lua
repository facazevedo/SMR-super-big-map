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
-- MAIN LAYOUT
-- ============================================================================
-- The mod has one supported layout: generate a native vanilla source, stretch it
-- over an 8192-tile destination, and build the corner-anchored expanded sector grid.
-- There are no mirror/noise/frame-fill or alternate sector-layout modes.
-- Disabling the mod restores vanilla behavior; changing expansion geometry requires
-- a new game because terrain allocation happens during random-map generation.
-- ============================================================================
config.SuperBigMapFullMapPlayable = true

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
config.DebugPregameToggle = false   -- PregameToggle: EXPAND MAP action, state, and underline diagnostics
config.DebugGeneration    = true    -- TEMP multi-run verification: authoritative enrichment targets
config.DebugGenerationVerbose = false -- GenerationVerbose: per-object clone spam (very noisy)
-- Lightweight aggregate timings for the temporary source -> expanded destination object handoff.
-- Records per-class counts/totals and the slowest individual transfers without changing order.
config.DebugMigrationPerformance = true
config.DebugSector        = false   -- Sector: grid build/patch, visibility, decal cleanup (very noisy; leave off for loading benchmarks)
config.DebugSectorSizing  = true    -- TEMP camera verification: stable 20x20 layout geometry
config.DebugDeposits      = true    -- TEMP multi-run verification: complementary top-up totals and final mix
-- Complete pre/post-stretch record trace for every native resource, anomaly, and effect marker.
-- Temporarily enabled to classify the underground coordinate collision as vanilla-preserved or
-- transform-introduced; disable after the recreation and supply-grid investigations are complete.
config.DebugEnrichmentPositionsExhaustive = true
-- Exhaustive forensic trace for the surface anomaly top-up's outer three-sector ring.
-- Logs the complete live sector topology and raw-world corner orientation, every existing anomaly,
-- every sampled candidate (accepted/rejected with terrain tier), all 204 ring-sector coverage
-- records, stage-one sector draws, stage-two low-area choices, side/bin/layer fallbacks, a 20x20
-- accepted/selected/final matrix, every clone result, overlap checks, and the final scan/reveal
-- audit. This is intentionally very noisy and adds diagnostic overhead only while enabled.
config.DebugTopUpEdgeDistribution = false
config.DebugStretch       = false
config.DebugLoading       = false   -- Loading: loading-box watch loop + "Please wait" dot animation
config.DebugLoadTime      = false
-- Exhaustive, read-only loading profiler. Records ordered lifecycle, generator, stretch,
-- loading-footer, and legacy timeline events with cumulative/gap/step durations. It adds
-- no sleeps, yields, scheduling, or behavioral changes; disable after collecting a trace.
config.DebugLoadingSteps  = true
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
config.DebugElevatorTerrain = true -- TEMP underground supply-grid assertion investigation
-- Exhaustive supply-grid lifecycle trace for deferred underground Elevator restoration. Records
-- generation tokens, map-scoped MapVar identities, grid dimensions, Elevator footprints,
-- synchronous fragment merges/copies, and every fail-closed transaction boundary.
-- Observational only; disable after the native pSupplyGrid assertion is resolved.
config.DebugSupplyGrid    = true
config.DebugHeat          = false   -- Heat: heat-grid clamp wraps
config.DebugBounds        = false   -- Bounds: playable bounds / PassBorder + buildable wrapper identity (temporary investigation)
config.DebugValidation    = false   -- Validation: runtime validation snapshots
config.DebugZoom          = true    -- TEMP camera verification: live zoom limits and ZoomPlus state
config.DebugZoomVanilla   = false   -- ZoomVanilla: normal-map zoom/FOV diagnostics
config.DebugRestartNotice = false   -- RestartNotice: restart-notice decision path
config.DebugEditorCamera  = false   -- EditorCamera: map-editor camera trace
config.DebugInitSeq       = false   -- InitSeq: step-by-step init/expansion sequence trace
config.DebugChosenMap     = false   -- ChosenMap: one line per map load (id, landing site, coordinates)
config.DebugSpikes        = false   -- Spikes: expensive terrain spike lattice audits
config.DebugPairing       = true    -- Pairing: startup passage bootstrap/link/position trace
config.DebugFlatten       = false   -- Flatten: construction-flatten diagnostics
config.DebugGenRand       = false   -- GenRand: generation-determinism trace

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
-- (otherwise the landscape tool fails "out of bounds" across the added destination area). It does
-- NOT make anything buildable on its own; it only lets the player reshape the new terrain.
config.AllowLandscapingOnExpanded = true

-- When an OLD save that was NOT started with Super Big Map is loaded, show a
-- one-time (per load) modal explaining that the expanded map only applies to games
-- STARTED with the mod, and that this save will keep playing normally. The mod does
-- nothing else on such saves (no expansion, bounds, sector, or overview changes).
-- Nothing is written into the old save. Set false to suppress the popup entirely.
config.WarnOldSaveNeedsNewGame = true


-- Hide added or proportionally relocated scan-gated enrichments until their final
-- expanded sector is scanned.
config.HideClonedDepositsUntilScan = true
-- Keep added deposits at least this many tiles away from the map's outer border (no
-- deposit is placed within this margin of the edge).
config.DepositEdgeMarginTiles = 4
-- ENRICHMENT TOP-UP SWITCHES. Each expanded-map population can be controlled independently.
config.TopUpResources = true
config.TopUpAnomalies = true
config.TopUpVistas = true
config.TopUpResearchSites = true
config.TopUpMoraleVistas = true
-- Hard terrain-evenness rule for every added enrichment on both maps. terrain normal Z uses
-- 4096 for perfectly horizontal ground; 4080 limits accepted top-up positions to approximately
-- five degrees or less, and the candidate must also pass the engine's buildable-grid test.
-- Native vanilla enrichments are never moved by this rule.
config.TopUpMinimumTerrainNormalZ = 4080
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
-- Inside that sector it accepts only flat, buildable, unobstructed terrain, sorts the viable
-- candidates by terrain height, and randomly chooses within this lowest percentage. 35 means the
-- lowest 35% of that valid pool. Anomaly-hex non-overlap remains a hard requirement.
config.TopUpAnomalyLowAreaPercent = 35

-- RESOURCE TOP-UP (sbm_deposits.lua TopUpDeposits). The generator places the native (Big) deposit
-- count; over the larger 20x20 that is below vanilla density. When true, extra source resource
-- deposits are cloned onto validated final-terrain coordinates until the total reaches
-- source_count * area_factor (vanilla density x the bigger area); clones are hidden until
-- their sector is scanned. All resource types
-- scale proportionally, including concrete (a cloned concrete marker paints its own regolith
-- patch on scan). false = native (Big) deposit count.
-- Override the deposit target scale. false = auto (area factor); a number forces that multiplier.
config.DepositCountScaleOverride = false

-- When stretch-time scan gating hides a placed concrete marker, or underground
-- reachability relocates it, clear the obsolete Regolith/Regolith_02 imprint.
config.ClearInitialConcreteImprint = true
-- Max type-grid tiles the concrete-imprint flood fill will clear per blob. Regolith /
-- Regolith_02 are used ONLY as the concrete-deposit texture (confirmed in the game files:
-- TerrainDeposit.lua Concrete -> "Regolith"/"Regolith_02"; they do NOT appear in the map-gen
-- terrain sets and landscaping excludes them), so every regolith blob IS a concrete patch
-- bounded by non-regolith terrain -- the fill always stops at the patch edge, and there is no
-- natural regolith to protect. So there's no reason to cap by size: 0 = NO size limit (clear
-- the whole patch regardless of size; recommended). A positive value caps the fill at that many
-- tiles.
config.ConcreteImprintMaxTiles = 0

-- TEMP verification control (sbm_place_elevator_button.lua): shows a bottom-right button that
-- enters the normal Elevator placement cursor, force-unlocks the template, and quick-builds the
-- next placed Elevator for free. This exists only to inspect surface/underground correspondence.
-- Set false again before release.
config.PlaceElevatorButtonEnabled = true

-- Show an on-screen notice (the game's standard message box) telling the player a fresh
-- restart is necessary -- but ONLY when they just turned the mod ON under Installed Mods
-- (an off->on toggle), NOT on a normal launch where it was already enabled. Set false to
-- silence it entirely. The notice also offers a persistent local "Don't show again"
-- action stored in LocalStorage.
config.ShowRestartNotice = true

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
-- 02: Stretch the source terrain, transform each captured enrichment proportionally, align it
-- to the final hex/terrain height, verify the result, and rebuild the final gameplay grids.
config.ExpansionStep02StretchAndTransformVanillaSource = true
-- 03: Generate only the additional enrichments required by the increased area, treating every
-- transformed native enrichment as an immutable repulsion obstacle, then register and audit them.
config.ExpansionStep03GenerateAdditionalEnrichments = true
-- 04 and 05 are retired compatibility slots. Native generation now runs unchanged on the exact
-- vanilla source backing, so neither generator-rule mutation nor native-candidate correction is
-- part of the expansion pipeline.
-- 06 (former 04): Capture every native enrichment coordinate, class, and property before stretching.
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
config.ExpansionStep12BuildEnrichmentOccupancy = true
-- 13 (former 11): Calculate resource, effect, and eligible ordinary-anomaly additions.
config.ExpansionStep13CalculateEnrichmentAdditions = true
-- 14 (former 12): Apply common bounds, terrain, reachability, uniqueness, and repulsion validation.
config.ExpansionStep14ValidateEnrichmentCandidates = true
-- 15 (former 13): Restrict each family to its configured region, including the anomaly outer ring.
config.ExpansionStep15ApplyCategoryRegions = true
-- 16 (former 14): Run the randomized category-specific candidate selector.
config.ExpansionStep16SelectCategoryCandidates = true
-- 17 (former 15): Reserve each accepted coordinate and aligned hex before selecting another marker.
config.ExpansionStep17ReserveCandidatePositions = true
-- 18 (former 16): Perform final alignment and revalidate the aligned coordinate and hex.
config.ExpansionStep18AlignAndRevalidateCandidates = true
-- 19 (former 17): Construct markers only after their final candidate passes every enabled rule.
config.ExpansionStep19CreateEnrichmentMarkers = true
-- 20 (former 18): Register surface markers and configure underground proximity reveal.
config.ExpansionStep20RegisterAndRevealMarkers = true
-- 21 (former 19): Audit counts, coordinates, hexes, repulsion, and category regions.
config.ExpansionStep21AuditFinalEnrichments = true

-- Stretch-only expanded-map allocation. A native source is generated once and
-- proportionally resampled over this destination; no terrain is tiled or mirrored.
-- HARD ENGINE CAP: the terrain may not exceed 8192 tiles on either axis --
-- confirmed by the C++ assert geTerrain.cpp(231): m_mapdata.nWidth <= 8192 &
-- m_mapdata.nHeight <= 8192 (a 10240 allocation aborts map load). 8192 tiles =
-- 20x20 vanilla sectors is therefore the absolute maximum map size; do not raise.
config.ExpandedTerrainTiles = 8192
-- The random map generator's stable-position helper asserts around 8192
-- terrain tiles, while the renderer rejects some intermediate sizes. 6144 is
-- the largest renderer-safe random blank map size confirmed so far. (The
-- generator runs at the native size, NOT the allocation, so leave this at 6144.)
config.RandomGeneratorMaxTiles = 6144
config.RendererNodeTileAlignment = 2048
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
-- Keep the two vanilla passage pairs and Elevator snap anchors eager, but postpone buried-wonder
-- construction plus the expensive underground stretch/post-processing until first access. The
-- underground passage's child SurfaceTunnelMarker is also postponed because its vanilla spawn
-- requires the final buildable and object grids to have matching dimensions; the linked passage
-- itself remains available for Elevator placement. Vanilla's wonder shuffle is consumed and
-- recorded at startup, so deferral does not change which wonder belongs to each marker.
config.DeferUndergroundExpansionUntilFirstAccess = true
-- TEMP (testing): fully reveal the underground darkness fog whenever that map is viewed.
-- RevealDarkness.lua normally restores hr.EnableDarknessReveal=90 on every underground map
-- switch; the lifecycle hook overrides it to 0 after the switch. Set false again for release.
config.UndergroundRevealAllDarkness = true
-- TEMP (testing): after the deferred underground stretch, vanilla restoration, top-ups, and
-- reachability corrections finish, place and reveal every underground enrichment immediately.
-- This bypasses proximity discovery only for visual distribution verification; set false again
-- after the underground population has been confirmed.
config.RevealAllUndergroundEnrichmentsForTesting = true
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
-- LOADING OPTIMIZATIONS. Defer the provisional blank-map buildability
-- calculation until native ResolveBuildable has generated terrain, and defer MapGenerated's
-- full-map bounds/buildable/passability rebuild because the stretch changes those grids moments
-- later and performs the authoritative final rebuild. Non-stretch paths are untouched. The final
-- sector geometry and max-object-radius refresh still run after stretching.
config.OptimizeStretchDeferredRebuilds = true
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
-- Cap the random generator's working grid to the native source size during DoGenerate, so it
-- never exceeds the engine's GSRP_MAX_SIZE assert on the oversized allocation. Read by the hook.
config.LimitGeneratorToSource = true
-- RebuildBuildableGrid and MaskBuildableGrid bypass the normal map-size views: they consume
-- the cached map.Width/map.Height and map.hex_width/map.hex_height fields. Temporarily present
-- all four as one vanilla-sized source view during native generation, then restore them and
-- rebuild the full expanded gameplay grid afterward.
config.LimitBuildableGridToSource = true
-- Proc_InitPlayZone bypasses terrain.GetMapSize and grows its terrace grid from the real
-- backing terrain via terrain.HeightMapSize. During the exact vanilla-sized source window,
-- temporarily report the source size there too, then copy the resulting source height grid
-- into the expanded backing grid so vanilla never sees 8192 and the destination stays 8192.
config.BridgeVanillaHeightGrid = true

-- POST-GENERATION anomaly top-up (sbm_deposits.lua TopUpAnomalies). After exact vanilla
-- generation and proportional marker recreation, clone eligible ordinary anomaly families up to
-- the observed vanilla population times the area factor. Surface additions are restricted to the
-- outer ring; underground additions use reachable buildable terrain across the whole map.
-- EFFECT-DEPOSIT TOP-UP (sbm_deposits.lua TopUpEffectDeposits). EffectDepositMarker is the
-- marker family behind Vistas, Research Sites, and marker-backed Morale Vistas. Stretching increases the terrain area by
-- ~1.78x but otherwise leaves their generator counts unchanged, so this independently tops
-- enabled effect types up to their source count x area factor. The three per-type switches above
-- let each family be controlled separately. Every resource, anomaly, and effect top-up on both
-- maps requires passable, flat, buildable, vanilla-unobstructed terrain. Surface resources and
-- effects are randomly distributed outside the anomaly-only outer ring.
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
-- LEGACY PASSAGE RELOCATION (sbm_map_generation PatchPassagePairing). Keep this off: forcing
-- a surface entrance toward an underground marker bypasses vanilla's complete-footprint
-- validation and can make the stock flatten extrude an unbuildable footprint into a terrain
-- column. The exact-source path now runs vanilla FindPassageSpawnPos against the authoritative
-- surface buildable grid. After both maps have their final stretched grids, the production path
-- aligns each linked pair to the underground hex or the nearest complete footprint buildable on
-- both maps; this legacy link-time relocation remains disabled.
config.StretchDeterministicPassages = false
-- DETERMINISTIC PAIRING, the no-terrain-touching way (sbm_map_generation, DoGenerate). The
-- entrance pairing searches the SURFACE buildable grid during the UNDERGROUND generation.
-- When true, the surface Z grid is synchronously rebuilt once immediately before that search;
-- generic migration/RebuildGrids completion flags are deliberately not reused as proof. This
-- restores vanilla's complete-footprint selection without editing terrain.
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
-- VANILLA-EQUIVALENT START SECTOR (sbm_sector_exploration source annotation +
-- RevealVanillaStartSectors). Vanilla's OWN InitialReveal runs while the native source markers
-- still exist, and its first 10x10 winner is recorded. After stretching, only 20x20 sectors that
-- intersect the proportionally transformed winner box are candidates; vanilla InitialReveal runs
-- again over that small set and exactly its first result is revealed. This replaces legacy
-- start-sector relocation and never preserves vanilla's optional second concrete sector.
config.StretchVanillaStartSector = true
config.DebugStartSector = false     -- StartSector: virtual-sector candidates + weights, the vanilla pick, and the post-stretch reveal trace
-- The sector layout is fixed: vanilla-sized sectors, corner anchored, covering the
-- complete expanded terrain. Only progress cadence remains configurable here.
config.SectorFastInitialReveal = true
config.SectorProgressColumnInterval = 2
config.SectorInitialRevealProgressInterval = 50

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

local C = {}

local expansion_step_01 = as_bool(config.ExpansionStep01GenerateAndCaptureVanillaSource)
local expansion_step_02 = expansion_step_01
	and as_bool(config.ExpansionStep02StretchAndTransformVanillaSource)
local expansion_step_03 = expansion_step_02
	and as_bool(config.ExpansionStep03GenerateAdditionalEnrichments)
-- Retain two false entries in the indexed step table so the public 06-21 numbering remains stable.
local expansion_step_04 = false
local expansion_step_05 = false
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

-- The only supported mod layout is stretch-expanded terrain with a corner-anchored
-- expanded sector grid. Expansion step 01 remains the diagnostic master gate.
C.FULL_MAP_PLAYABLE = expansion_step_01
	and as_bool(config.SuperBigMapFullMapPlayable)

-- Debug logging: master + per-scope (see sbm_debug.lua). Logger reads C.DEBUG_<SCOPE>.
C.DEBUG_LOGS          = as_bool(config.EnableDiagnosticLogs)   -- master: enables every scope
C.DEBUG_LIFECYCLE     = as_bool(config.DebugLifecycle)
C.DEBUG_PREGAMETOGGLE = as_bool(config.DebugPregameToggle)
C.DEBUG_GENERATION    = as_bool(config.DebugGeneration)
C.DEBUG_MIGRATIONPERFORMANCE = as_bool(config.DebugMigrationPerformance)
C.DEBUG_GENRAND       = as_bool(config.DebugGenRand)
C.DEBUG_FLATTEN       = as_bool(config.DebugFlatten)
C.DEBUG_PAIRING       = as_bool(config.DebugPairing)
C.DEBUG_SPIKES        = as_bool(config.DebugSpikes)
C.DEBUG_GENERATIONVERBOSE = as_bool(config.DebugGenerationVerbose)
C.DEBUG_SECTOR        = as_bool(config.DebugSector)
C.DEBUG_SECTORSIZING  = as_bool(config.DebugSectorSizing)
C.DEBUG_DEPOSITS      = as_bool(config.DebugDeposits)
C.DEBUG_ENRICHMENTPOSITIONSEXHAUSTIVE = as_bool(config.DebugEnrichmentPositionsExhaustive)
C.DEBUG_TOPUPEDGEDISTRIBUTION = as_bool(config.DebugTopUpEdgeDistribution)
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
C.DEBUG_SUPPLYGRID    = as_bool(config.DebugSupplyGrid)
C.DEBUG_HEAT          = as_bool(config.DebugHeat)
C.DEBUG_BOUNDS        = as_bool(config.DebugBounds)
C.DEBUG_VALIDATION    = as_bool(config.DebugValidation)
C.DEBUG_ZOOM          = as_bool(config.DebugZoom)
C.DEBUG_ZOOMVANILLA   = as_bool(config.DebugZoomVanilla)
C.DEBUG_RESTARTNOTICE = as_bool(config.DebugRestartNotice)
C.DEBUG_EDITORCAMERA  = as_bool(config.DebugEditorCamera)
C.DEBUG_INITSEQ       = as_bool(config.DebugInitSeq)
C.DEBUG_CHOSENMAP     = as_bool(config.DebugChosenMap)

C.SURFACE_STRETCH_AT_START = expansion_step_07
C.WARN_OLD_SAVE_NEEDS_NEW_GAME = as_bool(config.WarnOldSaveNeedsNewGame)
C.SHOW_RESTART_NOTICE = as_bool(config.ShowRestartNotice)
C.PLACE_ELEVATOR_BUTTON_ENABLED = as_bool(config.PlaceElevatorButtonEnabled)
C.HIDE_CLONED_DEPOSITS_UNTIL_SCAN = as_bool(config.HideClonedDepositsUntilScan)
C.CLEAR_INITIAL_CONCRETE_IMPRINT = as_bool(config.ClearInitialConcreteImprint)
C.CONCRETE_IMPRINT_MAX_TILES = as_number(config.ConcreteImprintMaxTiles, 0)
C.DEPOSIT_EDGE_MARGIN_TILES = as_number(config.DepositEdgeMarginTiles, 4)
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
C.TOPUP_MINIMUM_TERRAIN_NORMAL_Z = math.max(0, math.min(4096,
	as_number(config.TopUpMinimumTerrainNormalZ, 4080)))
C.TOPUP_SECTOR_BALANCED_PLACEMENT = as_bool(config.TopUpSectorBalancedPlacement)
C.TOPUP_ANOMALY_OUTER_RING_SECTORS = as_number(config.TopUpAnomalyOuterRingSectors, 3)
C.TOPUP_ANOMALY_LOW_AREA_PERCENT = as_number(config.TopUpAnomalyLowAreaPercent, 35)
C.DEPOSIT_COUNT_SCALE_OVERRIDE = (type(config.DepositCountScaleOverride) == "number" and config.DepositCountScaleOverride > 0)
	and config.DepositCountScaleOverride or false
C.FIX_ROCKET_LANDING_Z = as_bool(config.FixRocketLandingZ)
C.PREVENT_LANDING_PAD_FLATTEN = as_bool(config.PreventLandingPadFlatten)
C.PREVENT_ELEVATOR_FLATTEN = as_bool(config.PreventElevatorFlatten)
C.EXPANDED_MAP_EDGE_BORDER = (type(config.ExpandedMapEdgeBorder) == "number" and config.ExpandedMapEdgeBorder >= 0)
	and math.floor(config.ExpandedMapEdgeBorder) or false
C.CLAMP_HEAT_QUERIES = as_bool(config.ClampHeatQueriesOnExpandedMap)
C.FORCE_BUILDABLE_GRID_STORAGE = as_bool(config.ForceBuildableGridStorage)
C.PERMISSIVE_BUILD_ON_EXPANDED = as_bool(config.PermissiveBuildOnExpanded)
C.ALLOW_LANDSCAPING_ON_EXPANDED = as_bool(config.AllowLandscapingOnExpanded)

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
C.EXPANSION_STEP_02_STRETCH_AND_TRANSFORM_VANILLA_SOURCE =
	expansion_step_02
C.EXPANSION_STEP_03_GENERATE_ADDITIONAL_ENRICHMENTS =
	expansion_step_03
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
	false, -- retired compatibility slot 04
	false, -- retired compatibility slot 05
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

-- Stretch-only terrain allocation and generation bridge.
C.ENABLE_TERRAIN_EXPANSION = expansion_step_01
C.EXPANDED_TERRAIN_TILES = as_number(config.ExpandedTerrainTiles, 8192)
C.MAX_RANDOM_GENERATOR_TILES = as_number(config.RandomGeneratorMaxTiles, 6144)
C.RENDERER_NODE_TILE_ALIGNMENT = as_number(config.RendererNodeTileAlignment, 2048)
C.STRETCH_SCALE_MARKERS = expansion_step_08
	and as_bool(config.StretchScaleMarkers)
C.STRETCH_ENFORCE_SCAN_GATE = expansion_step_20
	and as_bool(config.StretchEnforceScanGate)
C.STRETCH_RELOCATE_START_SECTOR = as_bool(config.StretchRelocateStartSector)
C.STRETCH_UNDERGROUND = expansion_step_07
	and as_bool(config.StretchUnderground)
C.DEFER_UNDERGROUND_EXPANSION_UNTIL_FIRST_ACCESS = as_bool(config.DeferUndergroundExpansionUntilFirstAccess)
C.UNDERGROUND_REVEAL_ALL_DARKNESS = as_bool(config.UndergroundRevealAllDarkness)
C.UNDERGROUND_REVEAL_ALL_ENRICHMENTS_FOR_TESTING =
	as_bool(config.RevealAllUndergroundEnrichmentsForTesting)
C.UNDERGROUND_OVERVIEW_ENABLED = as_bool(config.UndergroundOverviewEnabled)
C.UNDERGROUND_EXPLORATION_UI = as_bool(config.UndergroundExplorationUI)
C.STRETCH_MOVE_ENTRANCE_VISUALS = expansion_step_08
	and as_bool(config.StretchMoveEntranceVisuals)
C.ALWAYS_SHOW_ENTRANCE_SIGN = as_bool(config.AlwaysShowEntranceSign)
C.STRETCH_RESNAP_FLOATERS = as_bool(config.StretchResnapFloaters)
C.STRETCH_SCALE_HEIGHTS = as_bool(config.StretchScaleHeights)
C.STRETCH_RELIEF_AWARE_DECOR = as_bool(config.StretchReliefAwareDecor)
C.STRETCH_DECOR_TOPUP = as_bool(config.StretchDecorTopUp)
C.OPTIMIZE_STRETCH_DEFERRED_REBUILDS = as_bool(config.OptimizeStretchDeferredRebuilds)
C.OPTIMIZE_STRETCH_REVALIDATION = as_bool(config.OptimizeStretchRevalidation)
C.OPTIMIZE_STRETCH_DECOR_TRAVERSAL = as_bool(config.OptimizeStretchDecorTraversal)
C.OPTIMIZE_POSTLOAD_DEFERRED_BOUNDS = as_bool(config.OptimizePostLoadDeferredBounds)
C.OPTIMIZE_TOPUP_PLACEMENT_POOLS = as_bool(config.OptimizeTopUpPlacementPools)
C.LIMIT_GENERATOR_TO_SOURCE = expansion_step_01
	and as_bool(config.LimitGeneratorToSource)
C.LIMIT_BUILDABLE_GRID_TO_SOURCE = expansion_step_01
	and as_bool(config.LimitBuildableGridToSource)
C.BRIDGE_VANILLA_HEIGHT_GRID = expansion_step_01
	and as_bool(config.BridgeVanillaHeightGrid)
C.ENABLE_RMG_PLACEMENT_FIX = false
C.COMPLETE_NATIVE_ENRICHMENT_SHORTFALLS = false
C.ENABLE_NATIVE_ALIGNED_HEX_COLLISION_REPAIR = false
C.STRETCH_VANILLA_EXACT_PASSBORDER = expansion_step_01
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
C.PATCH_RANDOM_MAP_GENERATOR = expansion_step_01

-- Fixed expanded sector layout + exploration progress controls.
C.ENABLE_EXPANDED_SECTORS = expansion_step_01
C.SECTOR_FAST_INITIAL_REVEAL = as_bool(config.SectorFastInitialReveal)
C.SECTOR_PROGRESS_COLUMN_INTERVAL = as_number(config.SectorProgressColumnInterval, 2)
C.SECTOR_INITIAL_REVEAL_PROGRESS_INTERVAL = as_number(config.SectorInitialRevealProgressInterval, 50)

SuperBigMap.Config = C

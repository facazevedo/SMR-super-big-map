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
-- RELEASE DIAGNOSTICS
-- ============================================================================
-- Diagnostic channels remain available for targeted troubleshooting and stay
-- disabled in published builds.
config.DebugLoggingEnabled = false
config.DebugLoadingTimings = false
config.DebugEnrichmentAudit = false
config.DebugElevatorTraversal = false
config.DebugElevatorSupply = false
config.DebugElevatorLogistics = false
config.DebugElevatorRocks = false
config.DebugZoom = false
config.DebugOverviewCamera = false
config.DebugSectorInteraction = false
config.DebugOverviewGridVisuals = false
config.DebugUndergroundDecorationPositions = false
-- Focused temporary parity trace: scalar-only and independent from the broad release-debug gate.
-- Keep enabled until the fresh vanilla/expanded twin isolates reservation versus consumer drift.
config.TraceUndergroundSeedReservation = true
-- Focused outer-ring terrain-crease trace. It records only detector/repair scalars and is
-- independent from the broad release-debug gate.
config.TraceTerrainCreaseRepair = true
-- Focused one-run audit of the bounded failed-footprint retry.  It records only
-- prior/current site provenance and patch construction, independent of broad debug logging.
config.TraceOuterResourceRetryProvenance = true
-- Diagnostic: record what the native source actually produced, at migration time, so a run can
-- prove nothing was destroyed after transfer without needing a second reproducible vanilla process.
config.NativeSourceManifest = true
-- Focused one-run parity trace. This is deliberately default-off; the Ralph harness may enable the
-- runtime constant before fresh twins to compare every stock generator procedure and rock delta.
config.TraceUndergroundRockParity = false

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
-- Every completed Surface <-> Underground transfer opens the destination in overview instead of
-- restoring that city's last selection/overview mode. Other map changes (asteroids, load, editor,
-- generation backing maps) retain vanilla behavior.
config.EnterOverviewAfterSurfaceUndergroundSwitch = true

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

-- TEMP test aids: show bottom-right buttons that (1) open the normal Elevator placement cursor,
-- unlock and quick-build the next placed Elevator, (2) follow the normal underground map switch
-- path, (3) reveal every surface sector, and (4) reveal all underground resources, anomalies,
-- effects, buried wonders, and darkness for inspection.
config.PlaceElevatorButtonEnabled = true

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

-- Allow the LANDSCAPING tools (terraform / flatten / level) to operate across the WHOLE
-- expanded terrain. ENABLED: this is separate from buildability -- vanilla lets you landscape
-- unbuildable terrain to MAKE it buildable, and that must keep working on the expanded area
-- (otherwise the landscape tool fails "out of bounds" across the added destination area). It does
-- NOT make anything buildable on its own; it only lets the player reshape the new terrain.
config.AllowLandscapingOnExpanded = true

-- Hide added or proportionally relocated scan-gated enrichments until their final
-- expanded sector is scanned.
config.HideClonedDepositsUntilScan = true
-- Keep added deposits at least this many tiles away from the map's outer border (no
-- deposit is placed within this margin of the edge).
config.DepositEdgeMarginTiles = 4
-- Restore vanilla enrichment density across the larger destination after the native population is
-- stretched. Added resource markers use the complete flat/buildable/passable/obstruction and
-- spacing validation path and remain hidden until their final sector is scanned.
config.TopUpResources = true
-- Underground additions are density content that may legitimately sit behind removable cave-in/
-- collapsed-tunnel walls. Temporarily exclude only CaveInRubble and TunnelBlockerRubble grid
-- footprints while the complete resource/anomaly/effect top-up suite runs, then restore every
-- wall before final audits. The legacy option name is retained for save/config compatibility.
config.UndergroundResourceTopUpsIgnoreRubbleWalls = true
config.TopUpAnomalies = true
config.TopUpVistas = true
config.TopUpResearchSites = true
config.TopUpMoraleVistas = true
-- Added dome-effect bonuses belong where a dome can realistically use them. Keep Vista, Research
-- Site, and marker-backed Morale Vista TOP-UPS out of the final two sector rows/columns along
-- every map edge. Native vanilla markers are never moved; underground effects are unchanged.
config.TopUpDomeEffectOuterRingExclusionSectors = 2
-- Hard terrain-evenness rule for every added enrichment on both maps. terrain normal Z uses
-- 4096 for perfectly horizontal ground; 4080 limits accepted top-up positions to approximately
-- five degrees or less, and the candidate must also pass the engine's buildable-grid test.
-- Native vanilla enrichments are never moved by this rule.
config.TopUpMinimumTerrainNormalZ = 4080
-- Choose strict whole-map top-up positions by the live enrichment load divided by each sector's
-- sampled eligible terrain capacity. This preserves vanilla's terrain-driven pockets and the
-- original generated marker positions. Surface anomaly extras use this same whole-map balancing;
-- inside a sector they prefer locally flat pockets with higher surrounding terrain (mountain
-- bases), while a strict normal/buildability gate excludes steep slopes. If underground vanilla
-- repulsion cannot fit every required marker, the residual fallback instead maximizes spacing from
-- existing enrichments and uses lower-loaded sectors only as a secondary diversity rule.
config.TopUpSectorBalancedPlacement = true
-- The underground density fallback is allowed to relax vanilla's much larger, resource-specific
-- repulsion radii so the expanded map can retain the exact scaled population. It must still keep
-- every fallback marker a meaningful distance from every other enrichment. Candidate sampling
-- continues until this hard axial-hex clearance is met; it never drops to adjacent unique hexes.
config.UndergroundFallbackMinimumHexDistance = 6
-- Surface anomaly density additions use the final physical perimeter. The placement code derives
-- that band from the live final sector geometry; this value is only its general width.
config.TopUpAnomalyOuterRingSectors = 2
config.TopUpAnomalyLowAreaPercent = 35
-- Emphasize mountain bases in the added population rather than treating them as a rare tie-breaker.
-- This percentage of each surface anomaly shortfall is selected first from strict flat/buildable
-- candidates beside higher terrain. If terrain or vanilla repulsion cannot supply the quota,
-- density completion may use other strict flat terrain; steep slopes never enter.
config.TopUpAnomalyMountainBaseMinimumPercent = 75
-- Mountain-foot terrain is often a narrow band, especially around a scenario's enclosing ranges.
-- Sample every unscanned sector evenly instead of relying on the ordinary whole-map random pool to
-- hit those bands by chance. Only the strongest few base candidates per sector enter the reserved
-- mountain-base selector, preventing broad central flats from overwhelming narrow mountain feet.
config.TopUpAnomalySurfaceSamplesPerSector = 64
config.TopUpAnomalyMountainBaseCandidatesPerSector = 8
-- Ignore tiny rolling-ground height differences: at least one surrounding sample must rise this
-- many metres above the flat candidate, and relief must appear in at least two ring samples.
config.TopUpAnomalyMountainBaseMinimumRiseMeters = 5

-- Reserve pseudorandom mountain-base opportunities for ordinary resource top-ups in the final
-- two-sector perimeter. Naturally buildable foothills are kept unchanged. Only marginally
-- sloped opportunities receive a small gently graded apron after the exact v738 whole-map height
-- transform; a broad irregular quintic feather returns to untouched terrain with matching
-- value/slope/curvature. This is a general terrain-shape rule and never consults scenario
-- coordinates or sector names.
config.CreateNaturalMountainBaseBuildableAprons = true
config.MountainBaseApronOuterRingSectors = 2
-- There is no longer a fixed perimeter resource quota.  The planner creates a pseudorandom six to
-- ten clusters instead, with their members split across the two disjoint bands: about 60% in
-- sectors touching the map edge and 40% in the adjacent (inner) sector band.
config.MountainBaseOuterRingResourceMinimum = 0
config.MountainBaseOutermostResourceMinimumPercent = 60
-- Every new enrichment marker keeps three hexes from existing resources/anomalies/effects and from
-- earlier top-ups.  Surface-deposit pairs are the sole exception: their physical rock piles may sit
-- on neighbouring hexes, though never on the same hex. Cluster planning remains conservative when
-- the eventual resource type is not known yet.
config.MountainBaseQuotaMinimumHexDistance = 3
config.TopUpEnrichmentMinimumHexDistance = 3
-- The final surface spacing audit retains the exact marker order, pair counters, predicates, and
-- first-violation order while a conservative dual spatial index omits pairs that are provably too
-- far apart to affect any rule. Underground retains the literal quadratic audit, and any failed
-- coverage certificate falls back to it on the surface as well.
config.OptimizeTopUpHardSpacingSpatialIndex = true
-- A two-sector ring has materially less natural flat foothill area than the prior three-sector
-- policy. Retain only the smallest extra set of deterministic low-slope foothills needed to
-- satisfy vanilla's unchanged resource clearance, never broad terrain shelves.
config.MountainBaseApronMaximumCount = 288
config.MountainBaseApronCoreRadiusHexes = 4
config.MountainBaseApronFeatherRadiusHexes = 20
-- Evaluate the broad organic apron feather on bounded native grids. Each patch snapshots its
-- exact preimage before copyback; a later failure restores those snapshots in reverse before the
-- literal legacy raster is allowed to run.
config.OptimizeMountainBaseApronNativeRaster = true

-- Once resource top-ups have chosen their final coordinates, prepare only the terrain that their
-- gameplay actually needs in the physical outer two-sector band.  Subsurface and terrain deposits
-- receive a small extractor-buildable core; exposed surface resources keep a passable collection
-- hex.  Each planned mountain cluster may additionally receive one nearby pad sized from
-- RocketLandingSite's live flatten shape. Building edits keep an exact level gameplay core, while
-- exposed surface piles retain a safe local grade. Every edit then
-- returns to untouched relief through a broad C2 quintic transition whose width expands with the
-- actual cut/fill height and stays aligned with the local slope. Native small-scale relief is
-- retained through most of that transition, while only the live building footprint and a narrow
-- safety margin stay perfectly level. This avoids the smooth artificial terrace left by flattening
-- the full rebuild guard. The rule is geometry-only and contains no scenario or sector-name cases.
config.PrepareOuterResourceTerrain = true
-- Preserve the terrain formula and patch order while evaluating its broad organic feather on a
-- bounded coarse mask and applying the millions of height blends with native grid arithmetic.
-- Any unavailable/failed native primitive discards the working compute grid and reruns the exact
-- legacy rasterizer from the untouched source height grid.
config.OptimizeOuterResourceTerrainNativeRaster = true
-- Resource terrain edits are confined to the physical outer two-sector ring. Rebuild passability
-- only for that ring (plus the stock two-pass-tile dependency margin) before the resource audit;
-- later whole-map final rebuilds remain unchanged and authoritative.
config.OptimizeOuterResourceTerrainRingRebuild = true
-- The two outer passage pads are the only terrain writes after the authoritative outer-ring
-- rebuild. Retain their exact native-raster visit disks and rebuild just those disks before the
-- depth-zero planner and after publication. Any incomplete provenance, unexpected object extent,
-- height mutation, API failure, or transaction-order mismatch invokes the former whole-map
-- canonical rebuild at the affected boundary (both boundaries when preplan proof is unavailable).
config.OptimizeSurfaceSingleFlushFinalization = true
-- On the initial pass, retain the broad natural feather, then settle connected components containing
-- a high-relief extractor or landing pad once with the minimum transition width. This mirrors the
-- successful post-rebuild repair geometry without discarding the seamless outer blend.
config.OptimizeOuterResourceTerrainNativePrecondition = true
-- Mountain-relief samples do not participate in rocket-pad candidate scoring. Preserve the
-- candidate table shape with neutral placeholders, then evaluate the identical eight-direction
-- relief predicate only for each selected group winner. Disabling this flag restores the literal
-- eager per-candidate sampling path.
config.OptimizeOuterResourceRocketReliefDeferral = true
-- Rocket-pad coordinates are policy outputs rather than vanilla content. Visit the unchanged
-- exhaustive offset disk through a map-seeded private permutation and retain the unchanged score's
-- best valid candidate from a fixed sample. Every group must complete before any pad patch is
-- published; otherwise the exact exhaustive scorer reruns from an untouched journal and mask.
config.OptimizeOuterResourceRocketBoundedPlanner = true
config.OuterResourceExtractorCoreRadiusHexes = 3
config.OuterResourceExtractorFeatherRadiusHexes = 7
config.OuterResourceSurfaceCoreRadiusHexes = 1
config.OuterResourceSurfaceFeatherRadiusHexes = 4
-- Even when a live extractor footprint expands the required core beyond the nominal values above,
-- retain enough transition width to absorb the cut/fill without drawing a sharp berm. The runtime
-- expands this minimum further when the measured height delta needs it. Low angular irregularity
-- prevents a geometric outline without turning broad height changes into scalloped shadow arcs.
config.OuterResourceTransitionMinimumWidthHexes = 14
config.OuterResourceTransitionIrregularityPercent = 12
config.OuterResourceClusterMinimumDeposits = 1
config.OuterResourceClusterMaximumDeposits = 5
config.OuterResourceClusterMinimumExtractorDeposits = 1
config.OuterResourceClusterMaximumExtractorDeposits = 3
-- Resource deposits, anomaly top-ups, and pad-hosted dome modifiers together may never exceed
-- five members in one cluster.
config.OuterResourceClusterMaximumTotalMembers = 5
config.OuterResourceClusterRadiusHexes = 12
config.OuterResourceClusterMinimumCount = 6
config.OuterResourceClusterMaximumAnomalies = 3
config.OuterResourceRocketPadExtraFeatherHexes = 6
config.OuterResourceRocketPadMaximumCount = 10
-- A dome-effect top-up may enter the otherwise excluded perimeter only at a newly modified,
-- engine-verified mountain rocket pad.  Ordinary perimeter terrain remains excluded.
config.MountainRocketPadsAllowDomeEffects = true

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

-- Show an on-screen notice (the game's standard message box) telling the player a fresh
-- restart is necessary -- but ONLY when they just turned the mod ON under Installed Mods
-- (an off->on toggle), NOT on a normal launch where it was already enabled. Set false to
-- silence it entirely. The notice also offers a persistent local "Don't show again"
-- action stored in LocalStorage.
config.ShowRestartNotice = true

-- ============================================================================
-- CORRECTED ENRICHMENT EXPANSION PIPELINE -- INDIVIDUAL STEP SWITCHES
-- ============================================================================
-- Three high-level stages own the detailed pipeline controls below. Detailed controls remain
-- independently switchable within their owning stage.
-- A detailed switch can only run when its owning high-level stage is enabled. Disabling all
-- switches restores pure vanilla allocation, generation, and placement behavior.
--
-- 01: Generate and capture the source on a true vanilla backing, then promote its captured
-- terrain into the expanded destination before any geometric transformation.
-- Expansion master gate: disabling stage 01 cascades through every expansion stage while the mod
-- remains loaded for explicitly enabled standalone test aids such as Place Elevator.
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
-- 13 (former 11): Calculate and place the additional enrichments needed to restore vanilla
-- density over the larger surface and underground areas.
config.ExpansionStep13CalculateEnrichmentAdditions = true
-- 14 (former 12): Apply common bounds, terrain, reachability, uniqueness, and repulsion validation.
config.ExpansionStep14ValidateEnrichmentCandidates = true
-- 15 (former 13): Apply category routing, including whole-map surface anomaly placement.
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
config.ExpansionStep21AuditFinalEnrichments = false

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
-- Preserve the cheap generated underground source/plan at START. The existing first-access gate
-- completes the proportional transformation, wonders, passages, markers, and decorations only
-- when the player presses Place Elevator.
config.DeferUndergroundExpansionUntilFirstAccess = true
-- v965 feasibility seam for deferring the *native underground allocation and source generation*
-- as well as its existing stretch. This is deliberately diagnostic-only and default-off: it
-- captures a saveable primitive generation descriptor and computes the two deterministic surface
-- passage capsules that a future lazy transaction would publish, but it does not suppress
-- GenerateNextMap or alter the v964 lifecycle. Runtime seed/capsule/save-load/access-route proof is
-- required before a separate compiled implementation flag may exist.
config.LazyUndergroundSourceGenerationFeasibility = false
-- v966-v970 functional lazy-underground implementation. This remains a separate default-off switch so
-- the v965 descriptor/capsule probe can still be run without suppressing the stock second map.
-- When enabled before module load, the Surface persists the exact primitive GenerateNextMap recipe,
-- publishes two deterministic passage capsules, and materializes the complete Underground map under
-- the foreground first-access cover. Once stock GenerateNextMap has been suppressed, any failure is
-- sticky and access remains blocked; the implementation never exposes a partial map.
config.LazyUndergroundSourceGeneration = false
-- v968 exact-center capsule planner. The enclosing lazy-underground implementation remains default-off;
-- when explicitly enabled, each private candidate gets one stock-compatible native validation at
-- depth 0: its snapped center is either accepted or rejected and neighbours are never searched.
-- Each selected center receives one fresh depth-0 publication validation before any object is created.
config.LazyUndergroundBoundedCapsulePlanner = true
-- v969-v970 fresh-grid capsule publication order. The lazy implementation remains default-off; when it
-- is explicitly enabled, never spend capsule-planner work against the known stale pre-final grids.
-- Publish one canonical Surface pass/buildable epoch first, plan and publish the two capsules on
-- those fresh grids, then close their terrain/object mutations with one final canonical rebuild.
config.LazyUndergroundFreshGridCapsulePlanning = true
-- v970 post-canonical stock capsule search. The enclosing lazy implementation remains default-off;
-- when enabled with fresh-grid planning, use the engine's unchanged nearest-buildable search only
-- after the first canonical Surface pass/buildable publication. A private start/angle stream is
-- capped at eight stock calls per deterministic main/replay plan, so the prior 512-footprint scan
-- cannot recur. Failure at the cap is sticky and publishes no capsule.
config.LazyUndergroundPostCanonicalStockCapsuleSearch = true
-- v972 bounded direct-ring passage-pad preconditioning. The enclosing lazy implementation remains
-- default-off. Candidate centers are sampled directly inside certified physical outer-ring strips;
-- only four viable footprints per site are scored and marker exclusion is a conservative
-- center-radius test before the exact obstruction-shape walk.
-- When enabled, two private deterministic Elevator footprints are reserved only after all Surface
-- enrichments are final, then flattened through the existing organic native outer-terrain journal.
-- The post-canonical capsule path consumes these exact sites and performs no nearest-site search.
config.LazyUndergroundOuterPassagePads = true
-- TEMP test aid: remove the underground darkness blanket on any underground gameplay map,
-- including vanilla-mode tests, and restore the previous value on surface/menu transitions.
config.UndergroundRevealAllDarkness = false
-- TEMP test aid: after underground stretching, top-ups, and reachability correction, invoke
-- vanilla RevealDeposits for every final underground enrichment.
config.RevealAllUndergroundEnrichmentsForTesting = false
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
-- FULL 3D STRETCH: also scale the terrain HEIGHT VALUES by full/source (x1.333), matching the
-- X/Y grid stretch and the object mesh scaling -- a true similarity transform. Restores vanilla
-- slope steepness and object seating geometry (XY-only stretching made slopes 25% shallower
-- while meshes grew x1.333 in all axes; formations sculpted into relief floated). When disabled,
-- only X/Y is stretched and slopes become shallower.
config.StretchScaleHeights = true

-- RELIEF-AWARE decoration Z (user-designed): before the terrain stretch, annotate each object's
-- relationship to its ground (dz = z - terrain height); after the stretch, place it at the
-- ACTUAL stretched terrain height at its new spot + dz * (full/source). Preserves intentional
-- embedding (half-buried stays proportionally half-buried) and absorbs resample smoothing --
-- the plain SetTerrainZ snap (used as fallback / when off) forces every base onto the surface.
config.StretchReliefAwareDecor = true
-- STAMP OUT-OF-BOX SOURCE OBJECTS (sbm_terrain_copy AnnotateDecorRelief). Native generation puts a
-- few objects just BEYOND the source rect, and the stretch passes enumerate that rect only, so
-- those objects are never stamped with their immutable native transform. The surface path is immune
-- because TransferGeneratedObjects stamps through an unbounded MapGet and simply leaves them where
-- they are; the underground is stretched in place and had no such pass, so the parity bijection
-- lost one object per affected case (b2-10, b2-07). When true, a stamp-only sweep over the
-- DESTINATION rect fills the missing SuperBigMapNativeSource* fields. Stamps only: nothing is
-- moved, rescaled or made eligible, so the scaling passes and the proven floors are unchanged.
config.StretchStampOutOfBoxSources = true
-- DESPAWN OUT-OF-BOX CONTENT (same sweep). Stamping keeps an out-of-box object; that is right for
-- the objects vanilla itself has out there and wrong for the ones it does not. Vanilla generates on
-- its own (smaller) map, whose box drops a prefab's spill past the edge; the expanded run generates
-- its native source inside the already enlarged map, so the same spill survives and appears as extra
-- content with no vanilla counterpart -- and, because the move passes enumerate the source rect only,
-- it also stays unmoved while its prefab siblings move away (sweep-04: Rocks_03 (588223,614853) and
-- RemovableRocks_02 (589778,615657), both absent from the vanilla control while the in-box sibling
-- RemovableRocks_01 (589278,612914) matched). Measured across nine twin pairs on both maps, EVERY
-- out-of-box vanilla row is a PrefabMarker, so when true the sweep stamps markers and the
-- destination's own enumerated infrastructure and despawns any other out-of-box object.
config.StretchDespawnOutOfBoxContent = true
-- Move the entrance VISUALS (tunnel signs, entrance structures, CityInit tunnel spawners) with
-- the same position*(full/source) transform as their markers, on BOTH maps (user-confirmed
-- design). Function and visuals stay co-located, every entrance sits on the terrain feature it
-- was generated on, and -- because both maps get the identical transform of natively identical
-- coordinates -- every surface/underground entrance pair keeps corresponding vertically.
config.StretchMoveEntranceVisuals = true
-- Keep the underground-entrance badge seated on the live terrain directly under its side
-- anchor. Nearby relief must not raise the badge; reveal-time sign creation and overview
-- refreshes may update appearance but cannot change its final XY or lift it off the ground.
-- Its visibility, scale, and depth testing remain vanilla: depth-tested in normal view and
-- no-depth-test only while overview is active, exactly like the resource badges.
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
-- The first real-time-thread boundary after the surface pipeline already performs the canonical
-- final passability/buildable rebuild required by T1. Skip the identical immediate rebuild at the
-- end of the protected pipeline; its result is otherwise overwritten before gameplay is exposed.
config.OptimizeDeferImmediateSurfaceFinalGridRebuild = true
-- Reuse the object list collected while recording pre-stretch decoration relief, avoiding a
-- second full MapForEach traversal immediately after the terrain stretch.
config.OptimizeStretchDecorTraversal = true
-- NewMap would repeat the engine's just-built blank-map buildable grid, and PostNewMapLoaded would
-- rebuild bounds/passability that the stretch immediately invalidates. Defer only the duplicate
-- NewMap buildable pass, then defer the later full Apply exactly like the MapGenerated hooks.
config.OptimizePostLoadDeferredBounds = true
-- Write a completed full-size color/biome MapGrid through the same direct destination-grid copy
-- used by vanilla's GridOpMapImport, then emit the normal change notification. The generic editor
-- SetGrid path converts the full world box and performs a copyrect even though source and
-- destination already cover the identical complete grid. Falls back to editor.SetGrid whenever
-- the destination is not a writable same-size grid.
config.OptimizeMapGridDirectCopy = true
-- Stretch height/type directly from the temporary 6144 terrain into the final 8192 backing.
-- This removes the full-grid intermediate copy while retaining the same resampler, affine height
-- transform, decoration-relief snapshot, and authoritative final gameplay-grid rebuild.
config.OptimizeDirectSourceTerrainStretch = true
-- Build resource top-up candidates adaptively, then reuse validated leftovers for anomaly/effect
-- top-ups and register stretch-mode clones at creation time instead of rescanning.
config.OptimizeTopUpPlacementPools = true
-- On the surface, ask the finalized native buildable grid which sectors contain at least one
-- buildable hex, then draw resource candidates uniformly from those sectors across the whole map.
-- Every selected coordinate still runs the complete terrain, obstruction, and vanilla-repulsion
-- checks.
config.OptimizeSurfaceResourceSectorSampling = true
-- Guaranteed surface clusters no longer need to precompute quota candidates across all 144
-- perimeter sectors. Visit those sectors in a scenario-seeded deterministic order, validate the
-- unchanged local terrain/obstruction/repulsion predicates, and stop each of the outermost and
-- adjacent perimeter bands once it has a bounded reserve for its already-planned cluster quotas.
config.OptimizeSurfaceResourceCandidateFirst = true
-- Build each guaranteed outer-ring resource cluster directly from a deterministic, bounded set of
-- fully validated hexes around the already-selected natural mountain-base centers. The complete
-- candidate-first perimeter scan remains a fail-closed fallback and runs before any clone is made.
config.OptimizeSurfaceResourceStreamingClusters = true
-- The sequential surface resource pass changes sector loads only when it commits a clone. Keep
-- that table live across selector rebuilds instead of rescanning every DepositMarker per clone.
config.OptimizeSurfaceResourceSelectorLoadCache = true
-- Validate anomaly terrain lazily and reuse the resource pass's safe candidates. This preserves
-- whole-map sector coverage and the complete placement constraints while avoiding an unconditional
-- 153,600-point terrain scan.
config.OptimizeAnomalyCandidateSearch = true
-- Reuse class-invariant DepositMarker property metadata and the immutable XYZ captured by stage 01
-- while serializing native enrichment records from the temporary source.
config.OptimizeNativeEnrichmentRecordCapture = true
-- Experimental only. Although the temporary surface source's passability grid is never consumed,
-- this engine asserts from map destruction unless every suspended PassEdits reason was resumed.
-- Keep the required flush enabled; disabling it is not a valid optimization on the retail build.
config.OptimizeDiscardTemporarySourcePassEdits = false
-- Experimental deferred reachability was slower in runtime testing because most candidates chosen
-- by the spacing selectors were unreachable, forcing hundreds of rejected ConnectivityCheck calls.
-- Keep reachability in the original candidate-validation path used by v658/308d89c.
config.OptimizeUndergroundDeferredCandidateReachability = false
-- Optional experimental batching across underground decoration/marker relocation. The measured
-- work is tiny, so keep this off by default to preserve native construction timing exactly. The
-- explicit authoritative final passability and buildable-grid rebuilds are never skipped.
config.OptimizeUndergroundPassEditBatch = false
-- Cap the random generator's working grid to the native source size during DoGenerate, so it
-- never exceeds the engine's GSRP_MAX_SIZE assert on the oversized allocation. Read by the hook.
config.LimitGeneratorToSource = true
-- RebuildBuildableGrid and MaskBuildableGrid bypass the normal map-size views: they consume
-- the cached map.Width/map.Height and map.hex_width/map.hex_height fields. Temporarily present
-- all four as one vanilla-sized source view during native generation, then restore them and
-- rebuild the full expanded gameplay grid afterward.
config.LimitBuildableGridToSource = true
-- POST-GENERATION anomaly top-up (sbm_deposits.lua TopUpAnomalies). After exact vanilla
-- generation and proportional marker recreation, clone eligible ordinary anomaly families up to
-- the observed vanilla population times the area factor. Surface additions are sector-balanced
-- across the whole scenario and prefer flat mountain-base pockets; underground additions use
-- reachable buildable terrain across the whole map.
-- EFFECT-DEPOSIT TOP-UP (sbm_deposits.lua TopUpEffectDeposits). EffectDepositMarker is the
-- marker family behind Vistas, Research Sites, and marker-backed Morale Vistas. Stretching increases the terrain area by
-- ~1.78x but otherwise leaves their generator counts unchanged, so this independently tops
-- enabled effect types up to their source count x area factor. The three per-type switches above
-- let each family be controlled separately. Surface dome-effect additions exclude the final three
-- sector rows/columns at every edge; native markers remain exact. Every resource, anomaly, and
-- effect top-up on both maps requires passable, flat, buildable, vanilla-unobstructed terrain.
-- VANILLA-EXACT PLAY ZONE (sbm_map_generation DoGenerate). The expansion zeroes
-- mapdata.PassBorder before ChangeMap so the whole expanded map is passable -- but the
-- generator also reads PassBorder to compute its play zone (GetPlayableArea, BiomeFiller POI
-- frame), so 0 gave it a BIGGER play zone than vanilla and diverged the per-proc random
-- stream (same lake prefab at another position/rotation). When true, the ORIGINAL PassBorder
-- is restored for just the DoGenerate window (the engine already baked full passability at
-- ChangeMap; only the generator's Lua-side reads see the restored value) and re-zeroed after.
-- The final gameplay-grid rebuild also derives and applies the exact mapped image of that vanilla
-- border through stock arbitrary passability boxes. A scalar 4/3 border is not exact on the
-- staggered property lattice, so the derived union is validated at every mapped source site.
config.StretchVanillaExactPassBorder = true
-- FLATTEN GUARD (sbm_rocket_rules flatten wrapper). On MOD maps, skip the engine
-- construction flatten when the site's anchor hex reads UNBUILDABLE from the buildable
-- z-grid -- the C flatten asserts (HGE::FlattenTerrainInShape: z != nUnbuildableZ) on
-- exactly that condition; vanilla's Lua reference implementation skips unbuildable hexes
-- the same way. Root cause was stale height ranges after the 3D stretch (see
-- ScaleHeightRanges); this guard keeps any residual case from crashing.
config.FlattenSkipWhenUnbuildable = true
-- DETERMINISTIC PAIRING, the no-terrain-touching way (sbm_map_generation, DoGenerate). The
-- entrance pairing searches the SURFACE buildable grid during the UNDERGROUND generation.
-- When true, the surface Z grid is synchronously rebuilt once immediately before that search;
-- generic migration/RebuildGrids completion flags are deliberately not reused as proof. This
-- restores vanilla's complete-footprint selection without editing terrain.
config.PairingSurfaceBuildableRebuild = true
-- SOURCE-SIZED FALLBACK SEARCH RADIUS (sbm_map_generation, passage bootstrap). When the first
-- buildable search around an underground passage marker fails, vanilla FindPassageSpawnPos
-- (Lua/Buildings/SurfacePassage.lua:119) retries from GetRandomPassableAroundOnMap(map, pos) with
-- no radius, and Lua/Pathfinding.lua:165 defaults it to Max(map:GetMapSize())/2 -- the EXPANDED
-- extent here (409600 instead of the native 307200), so the same marker and the same random value
-- reach a point up to a third further out. Passage selection runs entirely in SOURCE space against
-- the bridged native buildable grid, where everything outside the retained source square is
-- unbuildable, so an outside point can only fail, burn another random draw, and move the passage
-- to a site vanilla would never choose. When true, the caller-less fallback gets the source map's
-- radius for the duration of the bootstrap only.
config.PairingSourceFallbackRadius = true
-- SOURCE PASSABILITY FOR THE SAME FALLBACK (sbm_map_generation, passage bootstrap). With the
-- buildable answer bridged and the radius pinned above, the last expanded-map input left in
-- vanilla's fallback is the PASSABLE SET: GetRandomPassableAroundOnMap resolves
-- map:GetRandomPassablePoint (Lua/Pathfinding.lua:168) and that native chooser reads the map's own
-- pathfinding field, which Lua cannot substitute the way it substitutes a buildable grid. Measured
-- at 45S82E: identical center, radius and seed still diverge because the control's own point is
-- impassable on the expanded map and only 4713 of 16384 samples over the same source square are
-- passable there against the control's 7576. When true, the temporary native backing stays loaded
-- in its own map slot through the passage bootstrap and answers the fallback's passable-point
-- queries, so the selection sees the source's field; the slot is released as soon as the bootstrap's
-- selection window closes.
config.PairingSourcePassabilityBridge = true
-- Post-generation smoothing of the ground around each entrance footprint (GridSmooth, the
-- engine's own terrain filter): the game's entrance flatten is per-hex, which leaves faint
-- hex terracing (zigzag creases) even with clean height values. Runs once pre-stretch.
config.PassagePadSmoothing = true
-- NATIVE PASSAGE SPAWN WITHOUT THE SOURCE-POSE FLATTEN (sbm_map_generation, passage bootstrap).
-- Vanilla SpawnUndergroundPassage flattens the Elevator footprint into the live terrain as its
-- last step, at the level the buildable z_grid reports. The bootstrap runs that spawner on the
-- expanded surface map with the SOURCE-space buildable bridge installed, so the flatten carves a
-- source-pose, source-level hexagon into transformed ground - measured at 30S146E as two stale
-- craters 9.7 m and 33.0 m deep, one per passage pair, on top of the correct pad that
-- prepare_passage_pad later carves at the committed destination pose. When true, the bootstrap
-- reproduces the spawner's selection and placement steps and omits only that terrain edit; the
-- site choice, the random draws and the placed object are unchanged.
config.PassageNativeSpawnNoFlatten = true
-- NATIVE MARK-GRID PROJECTION (sbm_map_generation DoGenerate, underground in-place path). The
-- generator sizes its working grids from the Lua-visible source size (614400/800 = 768 cells),
-- but the NATIVE prefab rasterizer and the native GridGetMark reader project a grid over the
-- map's PHYSICAL extent -- 819200 on the expanded backing -- so the placement-mark grid quantizes
-- at 1066.67 wu per cell instead of vanilla's 800 and Proc_RemoveOverlappedObjects decides
-- boundary objects differently from a vanilla map. When true, the two ApplyTerrain procedures
-- allocate their mark grid at backing scale (819200/800 = 1024 cells) so the native cell step is
-- exactly vanilla's 800 wu, with the generated source view in the lower 768x768 corner. The mark
-- grid is never combined with another grid, so no other generator grid is affected.
config.UndergroundMarkGridBackingScale = true
-- HEIGHT BUDGET (version 738 mode). Shift the whole field so the source minimum lands one metre
-- above zero. If its full-scale span would overflow, normalize every map height into the remaining
-- range. This preserves substantially more mountain relief than reserving a five-metre floor.
config.StretchShiftHeightsDown = true
config.StretchAdaptiveZScale = true
-- Repair coherent discontinuities facing any edge within the two-sector outer ring of some vanilla
-- surface height fields. Detect them cheaply and without writes on the vanilla-size source, then at
-- destination resolution apply version 839's proven border algorithm: translate every lower cell
-- from the crease through its adjacent edge and replace the wall with a slope-matched quintic
-- interpolation. Outer relief survives without flat shelves, caps, or synthetic smooth strips; the
-- central 16 x 16 sectors and ordinary broken mountain cliffs are untouched.
config.StretchRepairInternalHeightStep = true
-- Reuse the exact four/six-value neighbourhood while refining a detected height-step row. This
-- changes only how often the native grid is read; candidate order, comparisons, and writes are
-- identical. The legacy branch remains available as a fail-closed diagnostic fallback.
config.OptimizeHeightStepRefineRollingWindow = true
-- Build a read-only native destination-crease candidate index. U16 operands, signed differences,
-- doubled flanks, and thresholds are all represented exactly in f32; accepted (perp,width,jump)
-- records are sorted back into the legacy loop order before the unchanged Lua offer/track/refine
-- path consumes them. Any native API, allocation, or enumeration failure falls back to the
-- unchanged rolling Lua scan before a terrain write can occur.
config.OptimizeHeightStepNativeDiscoveryIndex = true
-- The source crease detector visits only every eighth row in the two-sector perimeter and accepts
-- either jump direction. Compact exactly those sampled rows into bounded native slabs, apply the
-- unchanged U16 difference/flank predicate there, then restore the legacy perpendicular order before
-- the existing track qualification and scalar per-row refinement. The source grid remains read-only;
-- any allocation, native operation, enumeration, or cleanup failure falls back before repair writes.
config.OptimizeHeightStepNativeSourceDiscoveryIndex = true
-- INVALIDATE BEFORE EVERY FINAL PASSABILITY REBUILD, on the surface and the underground alike
-- (sbm_map_generation, expansion step 11). The engine rebuilds passability only over regions that
-- were INVALIDATED first -- its own generator always calls terrain.InvalidateHeight +
-- terrain.InvalidateType immediately before terrain.RebuildPassability
-- (RandomMapGenerator.lua:2900) -- so the mod's bare rebuild at an authoritative synchronization
-- point recomputed nothing. Measured at 45S82E: a buried wonder's impassability imprint stayed
-- cropped to a small box around it (6,276 of 40,401 window cells blocked against vanilla's 21,719),
-- and the identical rebuild preceded by the two invalidates restored 21,668 of them, taking the
-- twin difference from 15,459 cells to 67.
config.FinalPassabilityInvalidate = true
-- TEST-ONLY SEAM, empty string = off (never set in a played game). When set to a path prefix,
-- the height stretch writes the destination height grid twice with GridSaveRaw:
-- "<prefix>-<environment>-pre.raw" straight out of GridResample and "<prefix>-<environment>-
-- post.raw" right after the Z transform, BEFORE the terrain edits that run later in generation
-- (entrance/passage flatten pads, the landing pit) can overwrite transformed ground. Only that
-- pair makes the contract's `expanded == floor(vanilla*4/3) + shift` gate scorable cell by cell
-- offline: the engine's resample arithmetic is not reproducible outside the game, so the pure
-- transform can only be judged between its own input and output.
config.StretchHeightGridDumpPath = ""
-- VANILLA-EQUIVALENT START SECTOR (sbm_sector_exploration source annotation +
-- RevealVanillaStartSectors). Vanilla's OWN InitialReveal runs while the native source markers
-- still exist, and its first 10x10 winner is recorded. After stretching, only 20x20 sectors that
-- intersect the proportionally transformed winner box are candidates; vanilla InitialReveal runs
-- again over that small set and exactly its first result is revealed. This replaces legacy
-- start-sector relocation and never preserves vanilla's optional second concrete sector.
config.StretchVanillaStartSector = true
-- WHOLE-FOOTPRINT INITIAL DEPOSITS (sbm_sector_exploration RevealVanillaStartSectors). Destination
-- sectors keep their physical size while the map grows, so vanilla's winner sector stretches to 4/3
-- of one of them and scanning the single winning destination sector reveals only part of the
-- footprint. Vanilla places the deposit of EVERY surface marker in its winner sector, so the ones
-- in the remainder are simply never created: measured at 45S82E as 2 missing SurfaceDepositMetals
-- and 1 missing TerrainDepositConcrete, the entire surface residue there. When true, the markers
-- inside the transformed winner box that the scan missed are placed with vanilla's own
-- RevealDeposits and the spawn positions InitialReveal already computed. The box is the exact
-- stretched image of vanilla's sector, so the placed set is vanilla's placed set - unlike scanning
-- every overlapping sector, which would cover far more ground than vanilla revealed.
config.StartSectorFootprintDeposits = true
-- STAGED START-SPAWN REPLAY (sbm_sector_exploration StageNativeStartSpawns ->
-- ReplayStagedStartSpawns). Vanilla decided WHICH markers the initial reveal spawns, and WHERE,
-- on NATIVE terrain; re-deriving those decisions on the stretched destination measurably changes
-- the answer in both directions (v796/v797: extra metals, missing concrete). The native decisions
-- are staged while the source still exists, so the destination must replay exactly that set:
-- the reveal targets scan with their marker lists suppressed, every staged record is placed by
-- source stamp at the destination image of vanilla's own spawn position, and anything else that
-- arrived placed is swept. The staged set is the single source of truth; when it is absent the
-- StartSectorFootprintDeposits path above still applies.
config.StartSpawnStagedReplay = true
-- STAGED BREAKTHROUGH MARKER ORDER (sbm_sector_exploration StageNativeBreakthroughOrder ->
-- sbm_map_generation InstallStagedBreakthroughOrder). City:InitBreakThroughAnomalies shuffles the
-- array MapGet returns with a seeded rand and prunes from the tail, so which breakthrough anomaly
-- markers survive depends entirely on that enumeration order. The mod defers that initializer until
-- the recreated markers exist and then replays it on the expanded map, whose enumeration order is
-- its own: measured at b2-04 as one marker in and one out at 46/46. When true, vanilla's own order
-- is captured on the live native source and handed to the shipped method, so the prune replays
-- vanilla's decision instead of re-deriving it. The marker SET is untouched; only the ORDER.
config.BreakthroughStagedOrder = true
-- The sector layout is fixed: vanilla-sized sectors, corner anchored, covering the
-- complete expanded terrain.
config.SectorFastInitialReveal = true

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
local debug_logging_enabled = as_bool(config.DebugLoggingEnabled)
C.DEBUG_LOGGING_ENABLED = debug_logging_enabled
C.DEBUG_LOADING_TIMINGS = debug_logging_enabled and as_bool(config.DebugLoadingTimings)
C.DEBUG_ENRICHMENT_AUDIT = debug_logging_enabled and as_bool(config.DebugEnrichmentAudit)
C.DEBUG_ELEVATOR_TRAVERSAL = debug_logging_enabled and as_bool(config.DebugElevatorTraversal)
C.DEBUG_ELEVATOR_SUPPLY = debug_logging_enabled and as_bool(config.DebugElevatorSupply)
C.DEBUG_ELEVATOR_LOGISTICS = debug_logging_enabled and as_bool(config.DebugElevatorLogistics)
C.DEBUG_ELEVATOR_ROCKS = debug_logging_enabled and as_bool(config.DebugElevatorRocks)
C.DEBUG_ZOOM = debug_logging_enabled and as_bool(config.DebugZoom)
C.DEBUG_OVERVIEW_CAMERA = debug_logging_enabled and as_bool(config.DebugOverviewCamera)
C.DEBUG_SECTOR_INTERACTION = debug_logging_enabled and as_bool(config.DebugSectorInteraction)
C.DEBUG_OVERVIEW_GRID_VISUALS = debug_logging_enabled and as_bool(config.DebugOverviewGridVisuals)
C.DEBUG_UNDERGROUND_DECORATION_POSITIONS = debug_logging_enabled
	and as_bool(config.DebugUndergroundDecorationPositions)
C.TRACE_UNDERGROUND_SEED_RESERVATION = as_bool(config.TraceUndergroundSeedReservation)
C.TRACE_TERRAIN_CREASE_REPAIR = as_bool(config.TraceTerrainCreaseRepair)
C.TRACE_OUTER_RESOURCE_RETRY_PROVENANCE = as_bool(config.TraceOuterResourceRetryProvenance)
C.NATIVE_SOURCE_MANIFEST = as_bool(config.NativeSourceManifest)
C.TRACE_UNDERGROUND_ROCK_PARITY = as_bool(config.TraceUndergroundRockParity)

-- The only supported mod layout is stretch-expanded terrain with a corner-anchored
-- expanded sector grid. Expansion step 01 is the allocation and generation master gate.
C.FULL_MAP_PLAYABLE = expansion_step_01
	and as_bool(config.SuperBigMapFullMapPlayable)

C.SURFACE_STRETCH_AT_START = expansion_step_07
C.SHOW_RESTART_NOTICE = as_bool(config.ShowRestartNotice)
C.HIDE_CLONED_DEPOSITS_UNTIL_SCAN = as_bool(config.HideClonedDepositsUntilScan)
C.CLEAR_INITIAL_CONCRETE_IMPRINT = as_bool(config.ClearInitialConcreteImprint)
C.CONCRETE_IMPRINT_MAX_TILES = as_number(config.ConcreteImprintMaxTiles, 0)
C.DEPOSIT_EDGE_MARGIN_TILES = as_number(config.DepositEdgeMarginTiles, 4)
C.TOPUP_RESOURCES = expansion_step_13
	and as_bool(config.TopUpResources)
C.UNDERGROUND_RESOURCE_TOPUPS_IGNORE_RUBBLE_WALLS =
	as_bool(config.UndergroundResourceTopUpsIgnoreRubbleWalls)
C.UNDERGROUND_TOPUPS_IGNORE_RUBBLE_WALLS =
	C.UNDERGROUND_RESOURCE_TOPUPS_IGNORE_RUBBLE_WALLS
C.TOPUP_ANOMALIES = expansion_step_13
	and as_bool(config.TopUpAnomalies)
C.TOPUP_VISTAS = expansion_step_13
	and as_bool(config.TopUpVistas)
C.TOPUP_RESEARCH_SITES = expansion_step_13
	and as_bool(config.TopUpResearchSites)
C.TOPUP_MORALE_VISTAS = expansion_step_13
	and as_bool(config.TopUpMoraleVistas)
C.TOPUP_DOME_EFFECT_OUTER_RING_EXCLUSION_SECTORS = math.max(0,
	math.floor(as_number(config.TopUpDomeEffectOuterRingExclusionSectors, 2)))
C.TOPUP_MINIMUM_TERRAIN_NORMAL_Z = math.max(0, math.min(4096,
	as_number(config.TopUpMinimumTerrainNormalZ, 4080)))
C.TOPUP_SECTOR_BALANCED_PLACEMENT = as_bool(config.TopUpSectorBalancedPlacement)
C.UNDERGROUND_FALLBACK_MINIMUM_HEX_DISTANCE = math.max(2,
	math.floor(as_number(config.UndergroundFallbackMinimumHexDistance, 6)))
C.TOPUP_ANOMALY_OUTER_RING_SECTORS = math.max(0,
	math.floor(as_number(config.TopUpAnomalyOuterRingSectors, 2)))
C.TOPUP_ANOMALY_LOW_AREA_PERCENT = as_number(config.TopUpAnomalyLowAreaPercent, 35)
C.TOPUP_ANOMALY_MOUNTAIN_BASE_MINIMUM_PERCENT = math.max(0, math.min(100,
	as_number(config.TopUpAnomalyMountainBaseMinimumPercent, 75)))
C.TOPUP_ANOMALY_SURFACE_SAMPLES_PER_SECTOR = math.max(8, math.min(256,
	math.floor(as_number(config.TopUpAnomalySurfaceSamplesPerSector, 64))))
C.TOPUP_ANOMALY_MOUNTAIN_BASE_CANDIDATES_PER_SECTOR = math.max(1, math.min(32,
	math.floor(as_number(config.TopUpAnomalyMountainBaseCandidatesPerSector, 8))))
C.TOPUP_ANOMALY_MOUNTAIN_BASE_MINIMUM_RISE_METERS = math.max(1,
	as_number(config.TopUpAnomalyMountainBaseMinimumRiseMeters, 5))
C.CREATE_NATURAL_MOUNTAIN_BASE_BUILDABLE_APRONS =
	as_bool(config.CreateNaturalMountainBaseBuildableAprons)
C.MOUNTAIN_BASE_APRON_OUTER_RING_SECTORS = math.max(0,
	math.floor(as_number(config.MountainBaseApronOuterRingSectors, 2)))
C.MOUNTAIN_BASE_OUTER_RING_RESOURCE_MINIMUM = math.max(0,
	math.floor(as_number(config.MountainBaseOuterRingResourceMinimum, 0)))
C.MOUNTAIN_BASE_OUTERMOST_RESOURCE_MINIMUM_PERCENT = math.max(0, math.min(100,
	as_number(config.MountainBaseOutermostResourceMinimumPercent, 60)))
C.MOUNTAIN_BASE_QUOTA_MINIMUM_HEX_DISTANCE = math.max(1,
	math.floor(as_number(config.MountainBaseQuotaMinimumHexDistance, 3)))
C.TOPUP_ENRICHMENT_MINIMUM_HEX_DISTANCE = math.max(1,
	math.floor(as_number(config.TopUpEnrichmentMinimumHexDistance, 3)))
C.OPTIMIZE_TOPUP_HARD_SPACING_SPATIAL_INDEX =
	as_bool(config.OptimizeTopUpHardSpacingSpatialIndex)
C.MOUNTAIN_BASE_APRON_MAXIMUM_COUNT = math.max(0,
	math.floor(as_number(config.MountainBaseApronMaximumCount, 288)))
C.MOUNTAIN_BASE_APRON_CORE_RADIUS_HEXES = math.max(2,
	as_number(config.MountainBaseApronCoreRadiusHexes, 4))
C.MOUNTAIN_BASE_APRON_FEATHER_RADIUS_HEXES = math.max(
	C.MOUNTAIN_BASE_APRON_CORE_RADIUS_HEXES + 2,
	as_number(config.MountainBaseApronFeatherRadiusHexes, 20))
C.OPTIMIZE_MOUNTAIN_BASE_APRON_NATIVE_RASTER =
	as_bool(config.OptimizeMountainBaseApronNativeRaster)
C.PREPARE_OUTER_RESOURCE_TERRAIN = as_bool(config.PrepareOuterResourceTerrain)
C.OPTIMIZE_OUTER_RESOURCE_TERRAIN_NATIVE_RASTER =
	as_bool(config.OptimizeOuterResourceTerrainNativeRaster)
C.OPTIMIZE_OUTER_RESOURCE_TERRAIN_RING_REBUILD =
	as_bool(config.OptimizeOuterResourceTerrainRingRebuild)
C.OPTIMIZE_SURFACE_SINGLE_FLUSH_FINALIZATION =
	as_bool(config.OptimizeSurfaceSingleFlushFinalization)
C.OPTIMIZE_OUTER_RESOURCE_TERRAIN_NATIVE_PRECONDITION =
	as_bool(config.OptimizeOuterResourceTerrainNativePrecondition)
C.OPTIMIZE_OUTER_RESOURCE_ROCKET_RELIEF_DEFERRAL =
	as_bool(config.OptimizeOuterResourceRocketReliefDeferral)
C.OPTIMIZE_OUTER_RESOURCE_ROCKET_BOUNDED_PLANNER =
	as_bool(config.OptimizeOuterResourceRocketBoundedPlanner)
C.OUTER_RESOURCE_ROCKET_BOUNDED_SCORED_BUDGET_PER_GROUP = 256
C.OUTER_RESOURCE_EXTRACTOR_CORE_RADIUS_HEXES = math.max(2,
	as_number(config.OuterResourceExtractorCoreRadiusHexes, 3))
C.OUTER_RESOURCE_EXTRACTOR_FEATHER_RADIUS_HEXES = math.max(
	C.OUTER_RESOURCE_EXTRACTOR_CORE_RADIUS_HEXES + 2,
	as_number(config.OuterResourceExtractorFeatherRadiusHexes, 7))
C.OUTER_RESOURCE_SURFACE_CORE_RADIUS_HEXES = math.max(1,
	as_number(config.OuterResourceSurfaceCoreRadiusHexes, 1))
C.OUTER_RESOURCE_SURFACE_FEATHER_RADIUS_HEXES = math.max(
	C.OUTER_RESOURCE_SURFACE_CORE_RADIUS_HEXES + 2,
	as_number(config.OuterResourceSurfaceFeatherRadiusHexes, 4))
C.OUTER_RESOURCE_TRANSITION_MINIMUM_WIDTH_HEXES = math.max(2,
	as_number(config.OuterResourceTransitionMinimumWidthHexes, 14))
C.OUTER_RESOURCE_TRANSITION_IRREGULARITY_PERCENT = math.max(0, math.min(45,
	as_number(config.OuterResourceTransitionIrregularityPercent, 12)))
C.OUTER_RESOURCE_CLUSTER_MINIMUM_DEPOSITS = math.max(1,
	math.floor(as_number(config.OuterResourceClusterMinimumDeposits, 1)))
C.OUTER_RESOURCE_CLUSTER_MAXIMUM_DEPOSITS = math.max(
	C.OUTER_RESOURCE_CLUSTER_MINIMUM_DEPOSITS,
	math.floor(as_number(config.OuterResourceClusterMaximumDeposits, 5)))
C.OUTER_RESOURCE_CLUSTER_MINIMUM_EXTRACTOR_DEPOSITS = math.max(1,
	math.floor(as_number(config.OuterResourceClusterMinimumExtractorDeposits, 1)))
C.OUTER_RESOURCE_CLUSTER_MAXIMUM_EXTRACTOR_DEPOSITS = math.max(
	C.OUTER_RESOURCE_CLUSTER_MINIMUM_EXTRACTOR_DEPOSITS,
	math.min(C.OUTER_RESOURCE_CLUSTER_MAXIMUM_DEPOSITS,
		math.floor(as_number(config.OuterResourceClusterMaximumExtractorDeposits, 3))))
C.OUTER_RESOURCE_CLUSTER_MAXIMUM_TOTAL_MEMBERS = math.max(
	C.OUTER_RESOURCE_CLUSTER_MAXIMUM_DEPOSITS,
	math.floor(as_number(config.OuterResourceClusterMaximumTotalMembers, 5)))
C.OUTER_RESOURCE_CLUSTER_RADIUS_HEXES = math.max(4,
	math.floor(as_number(config.OuterResourceClusterRadiusHexes, 12)))
C.OUTER_RESOURCE_CLUSTER_MINIMUM_COUNT = math.max(0,
	math.floor(as_number(config.OuterResourceClusterMinimumCount, 6)))
C.OUTER_RESOURCE_CLUSTER_MAXIMUM_ANOMALIES = math.max(0,
	math.floor(as_number(config.OuterResourceClusterMaximumAnomalies, 3)))
C.OUTER_RESOURCE_ROCKET_PAD_EXTRA_FEATHER_HEXES = math.max(3,
	as_number(config.OuterResourceRocketPadExtraFeatherHexes, 6))
C.OUTER_RESOURCE_ROCKET_PAD_MAXIMUM_COUNT = math.max(0,
	math.floor(as_number(config.OuterResourceRocketPadMaximumCount, 10)))
C.MOUNTAIN_ROCKET_PADS_ALLOW_DOME_EFFECTS =
	as_bool(config.MountainRocketPadsAllowDomeEffects)
C.DEPOSIT_COUNT_SCALE_OVERRIDE = (type(config.DepositCountScaleOverride) == "number" and config.DepositCountScaleOverride > 0)
	and config.DepositCountScaleOverride or false
C.FIX_ROCKET_LANDING_Z = as_bool(config.FixRocketLandingZ)
C.PREVENT_LANDING_PAD_FLATTEN = as_bool(config.PreventLandingPadFlatten)
C.PREVENT_ELEVATOR_FLATTEN = as_bool(config.PreventElevatorFlatten)
C.PLACE_ELEVATOR_BUTTON_ENABLED = as_bool(config.PlaceElevatorButtonEnabled)
C.EXPANDED_MAP_EDGE_BORDER = (type(config.ExpandedMapEdgeBorder) == "number" and config.ExpandedMapEdgeBorder >= 0)
	and math.floor(config.ExpandedMapEdgeBorder) or false
C.CLAMP_HEAT_QUERIES = as_bool(config.ClampHeatQueriesOnExpandedMap)
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
C.ENTER_OVERVIEW_AFTER_SURFACE_UNDERGROUND_SWITCH =
	as_bool(config.EnterOverviewAfterSurfaceUndergroundSwitch)

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

-- Enrichment expansion pipeline: three high-level stages plus detailed controls.
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
C.LAZY_UNDERGROUND_SOURCE_GENERATION_FEASIBILITY =
	as_bool(config.LazyUndergroundSourceGenerationFeasibility)
C.LAZY_UNDERGROUND_SOURCE_GENERATION = as_bool(config.LazyUndergroundSourceGeneration)
C.LAZY_UNDERGROUND_BOUNDED_CAPSULE_PLANNER =
	as_bool(config.LazyUndergroundBoundedCapsulePlanner)
C.LAZY_UNDERGROUND_FRESH_GRID_CAPSULE_PLANNING =
	as_bool(config.LazyUndergroundFreshGridCapsulePlanning)
C.LAZY_UNDERGROUND_POST_CANONICAL_STOCK_CAPSULE_SEARCH =
	as_bool(config.LazyUndergroundPostCanonicalStockCapsuleSearch)
C.LAZY_UNDERGROUND_OUTER_PASSAGE_PADS = as_bool(config.LazyUndergroundOuterPassagePads)
C.UNDERGROUND_REVEAL_ALL_DARKNESS = as_bool(config.UndergroundRevealAllDarkness)
C.UNDERGROUND_REVEAL_ALL_ENRICHMENTS_FOR_TESTING =
	as_bool(config.RevealAllUndergroundEnrichmentsForTesting)
C.UNDERGROUND_OVERVIEW_ENABLED = as_bool(config.UndergroundOverviewEnabled)
C.UNDERGROUND_EXPLORATION_UI = as_bool(config.UndergroundExplorationUI)
C.STRETCH_MOVE_ENTRANCE_VISUALS = expansion_step_08
	and as_bool(config.StretchMoveEntranceVisuals)
C.STRETCH_SCALE_HEIGHTS = as_bool(config.StretchScaleHeights)
C.STRETCH_RELIEF_AWARE_DECOR = as_bool(config.StretchReliefAwareDecor)
C.STRETCH_STAMP_OUT_OF_BOX_SOURCES = as_bool(config.StretchStampOutOfBoxSources)
C.STRETCH_DESPAWN_OUT_OF_BOX_CONTENT = as_bool(config.StretchDespawnOutOfBoxContent)
C.STRETCH_DECOR_TOPUP = as_bool(config.StretchDecorTopUp)
C.OPTIMIZE_STRETCH_DEFERRED_REBUILDS = as_bool(config.OptimizeStretchDeferredRebuilds)
C.OPTIMIZE_STRETCH_REVALIDATION = as_bool(config.OptimizeStretchRevalidation)
C.OPTIMIZE_DEFER_IMMEDIATE_SURFACE_FINAL_GRID_REBUILD =
	as_bool(config.OptimizeDeferImmediateSurfaceFinalGridRebuild)
C.OPTIMIZE_STRETCH_DECOR_TRAVERSAL = as_bool(config.OptimizeStretchDecorTraversal)
C.OPTIMIZE_POSTLOAD_DEFERRED_BOUNDS = as_bool(config.OptimizePostLoadDeferredBounds)
C.OPTIMIZE_MAP_GRID_DIRECT_COPY = as_bool(config.OptimizeMapGridDirectCopy)
C.OPTIMIZE_DIRECT_SOURCE_TERRAIN_STRETCH =
	as_bool(config.OptimizeDirectSourceTerrainStretch)
C.OPTIMIZE_TOPUP_PLACEMENT_POOLS = as_bool(config.OptimizeTopUpPlacementPools)
C.OPTIMIZE_SURFACE_RESOURCE_SECTOR_SAMPLING =
	as_bool(config.OptimizeSurfaceResourceSectorSampling)
C.OPTIMIZE_SURFACE_RESOURCE_CANDIDATE_FIRST =
	as_bool(config.OptimizeSurfaceResourceCandidateFirst)
C.OPTIMIZE_SURFACE_RESOURCE_STREAMING_CLUSTERS =
	as_bool(config.OptimizeSurfaceResourceStreamingClusters)
C.OPTIMIZE_SURFACE_RESOURCE_SELECTOR_LOAD_CACHE =
	as_bool(config.OptimizeSurfaceResourceSelectorLoadCache)
C.OPTIMIZE_ANOMALY_CANDIDATE_SEARCH = as_bool(config.OptimizeAnomalyCandidateSearch)
C.OPTIMIZE_NATIVE_ENRICHMENT_RECORD_CAPTURE =
	as_bool(config.OptimizeNativeEnrichmentRecordCapture)
C.OPTIMIZE_DISCARD_TEMPORARY_SOURCE_PASS_EDITS =
	as_bool(config.OptimizeDiscardTemporarySourcePassEdits)
C.OPTIMIZE_UNDERGROUND_DEFER_CANDIDATE_REACHABILITY =
	as_bool(config.OptimizeUndergroundDeferredCandidateReachability)
C.OPTIMIZE_UNDERGROUND_PASS_EDIT_BATCH = as_bool(config.OptimizeUndergroundPassEditBatch)
C.LIMIT_GENERATOR_TO_SOURCE = expansion_step_01
	and as_bool(config.LimitGeneratorToSource)
C.LIMIT_BUILDABLE_GRID_TO_SOURCE = expansion_step_01
	and as_bool(config.LimitBuildableGridToSource)
C.STRETCH_VANILLA_EXACT_PASSBORDER = expansion_step_01
	and as_bool(config.StretchVanillaExactPassBorder)
C.FLATTEN_SKIP_WHEN_UNBUILDABLE = as_bool(config.FlattenSkipWhenUnbuildable)
C.PAIRING_SURFACE_BUILDABLE_REBUILD = expansion_step_11
	and as_bool(config.PairingSurfaceBuildableRebuild)
C.PAIRING_SOURCE_FALLBACK_RADIUS = expansion_step_11
	and as_bool(config.PairingSourceFallbackRadius)
C.PAIRING_SOURCE_PASSABILITY_BRIDGE = expansion_step_11
	and as_bool(config.PairingSourcePassabilityBridge)
C.PASSAGE_PAD_SMOOTHING = expansion_step_11
	and as_bool(config.PassagePadSmoothing)
C.PASSAGE_NATIVE_SPAWN_NO_FLATTEN = expansion_step_11
	and as_bool(config.PassageNativeSpawnNoFlatten)
C.UNDERGROUND_MARK_GRID_BACKING_SCALE = expansion_step_01
	and as_bool(config.UndergroundMarkGridBackingScale)
C.STRETCH_SHIFT_HEIGHTS_DOWN = as_bool(config.StretchShiftHeightsDown)
C.STRETCH_ADAPTIVE_Z_SCALE = as_bool(config.StretchAdaptiveZScale)
C.STRETCH_REPAIR_INTERNAL_HEIGHT_STEP = as_bool(config.StretchRepairInternalHeightStep)
C.OPTIMIZE_HEIGHT_STEP_REFINE_ROLLING_WINDOW =
	as_bool(config.OptimizeHeightStepRefineRollingWindow)
C.OPTIMIZE_HEIGHT_STEP_NATIVE_DISCOVERY_INDEX =
	as_bool(config.OptimizeHeightStepNativeDiscoveryIndex)
C.OPTIMIZE_HEIGHT_STEP_NATIVE_SOURCE_DISCOVERY_INDEX =
	as_bool(config.OptimizeHeightStepNativeSourceDiscoveryIndex)
C.FINAL_PASSABILITY_INVALIDATE = expansion_step_11
	and as_bool(config.FinalPassabilityInvalidate)
C.STRETCH_HEIGHT_GRID_DUMP_PATH = type(config.StretchHeightGridDumpPath) == "string"
	and config.StretchHeightGridDumpPath or ""
C.STRETCH_VANILLA_START_SECTOR = expansion_step_20
	and as_bool(config.StretchVanillaStartSector)
C.START_SECTOR_FOOTPRINT_DEPOSITS = expansion_step_20
	and as_bool(config.StartSectorFootprintDeposits)
C.START_SPAWN_STAGED_REPLAY = expansion_step_20
	and as_bool(config.StartSpawnStagedReplay)
C.BREAKTHROUGH_STAGED_ORDER = expansion_step_20
	and as_bool(config.BreakthroughStagedOrder)
C.PATCH_RANDOM_MAP_GENERATOR = expansion_step_01

-- Fixed expanded sector layout and initial exploration behavior.
C.ENABLE_EXPANDED_SECTORS = expansion_step_01
C.SECTOR_FAST_INITIAL_REVEAL = as_bool(config.SectorFastInitialReveal)

SuperBigMap.Config = C

-- Super Big Map -- internal patch-guard version constants.
--
-- These are NOT the published mod version. The canonical mod version lives in
-- metadata.lua ('version'); this file must not duplicate it. The constants below
-- are hot-reload patch-identity guards: bump one when the corresponding engine
-- monkey-patch closures change, so they reinstall cleanly on an in-session mod
-- reload instead of leaving stale closures behind.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

-- Shared mod state: saved vanilla originals and patch-installed guards, used by the
-- monkey-patching domain modules so apply/restore share one place (no _G globals).
SuperBigMap.State = SuperBigMap.State or {}
-- These pre-source-generation correction modules were retired once generation moved onto an exact
-- vanilla backing. Clear any tables left by an in-session reload of an older build.
SuperBigMap.RmgPlacement = nil
SuperBigMap.EnrichmentSpreadDiagnostics = nil

-- Sector exploration + overview-highlight patches (sbm_sector_exploration / sbm_sector_highlight).
-- 28: added the IsExplorationAvailable_Sectors/Queue wraps (underground overview sector UI).
-- 29: underground rollover is informational-only (custom context, frames hidden, queue no-op'd).
-- 30: underground overview frames -- outline-only hover frame + red entrance frames.
-- 31: frame Z/visibility fix, off-map cursor suppression, underground buildable-% tooltip line.
-- 32: red frame uses `red` color global; entrance/frame diagnostics; tooltip drops 'Underground'.
-- 33: entrance frame color changed from red to cyan.
-- 34: force-align underground tunnel entrances under the surface ones before framing.
-- 35: alignment moved out of the highlight module (whole-map translation in terrain_copy).
-- 36: cyan entrance frames removed -- only the outline hover frame remains.
-- 37: underground sector veil -- every sector gets a translucent SectorUnexplored pane
--     during the underground overview (UpdateUndergroundOverviewFrames builds/tears it).
-- 38: veil watchdog + Veil debug scope -- OverviewMode(true) fires mid map-transition and
--     CurrentMapChangeDone's teardown destroyed the fresh veil 6 ms later; the watchdog
--     rebuilds/re-shows the veil while the underground overview is active.
-- 39: veil panes snap Z to LIVE terrain -- sector positions cache pre-stretch heights, so
--     after the x1.333 height scale most panes projected onto nothing (only 2 rendered);
--     census now reports decal-Z vs terrain-Z deltas, flat fields.
-- 40: veil diagnostic round -- TEMP red tint on veil panes (is SectorUnexplored outline-only?)
--     + hover forensic log identifying which object draws the hovered sector's fill.
-- 41: veil panes switch to the "SectorTarget" FILL entity (SectorUnexplored proved
--     outline-only: the red tint colored the grid lines, never the interiors), dark tint.
-- 42: vanilla-equivalent start sector -- InitialExplore wrapped (vanilla pick over virtual
--     10x10 sectors, reveal deferred to post-stretch).
-- 43: start reveal = CENTER sector only per winner (count parity with vanilla; the >=30%
--     overlap rule revealed 5); hover screen-space offset diagnostics.
-- 44: start-sector VALIDATION mode -- reconstruction analysis also runs (log-only) on
--     vanilla surface maps next to vanilla's own pick; candidate tables now carry the
--     vanilla-formula Metals/Concrete quantities + weights.
-- 45: OverviewModeDialog.ScaleSmallObjects wrapped -- re-assert no-depth-test + visible on
--     the underground entrance signs so the badge stays visible at every zoom.
-- 46: underground sectors become data-only -- remove grid/veil/hover-frame rendering while
--     retaining sector-name and buildable-area rollover data.
-- 47: share the underground UI predicate across installers and rebuild each rollover from the
--     exact hovered sector plus its live post-stretch buildable-grid ratio.
-- 48: cache the completed sector lookup layout so engine hex searches do not recompute the full
--     20x20 layout for every candidate hex and trip the infinite-loop detector.
-- 49: defer underground exploration availability until expansion completes so vanilla
--     InitSectors cannot perform an unintended initial underground sector scan.
-- 50: remove alternate sector layouts; expanded maps now always use the corner-anchored
--     full-destination grid.
-- 51: initialize migrated entrance passages and badges synchronously for the first overview;
--     replace the ScaleSmallObjects duration guess with lifecycle completion events.
-- 53: capture the native source start winner through a temporary exact 10x10 exploration view.
-- 54: choose maximum-overlap positional equivalents after stretching.
-- Bumped to 55: reveal the complete positive-overlap destination-sector cover of the stretched
-- vanilla start footprint while retaining one maximum-overlap InitialSector anchor.
-- Bumped to 56: make every exploration/highlight wrapper delegate immediately on vanilla maps
-- and normalize the process-global sector count before vanilla InitSectors.
-- Bumped to 57: force floating division in the stretched start-sector coordinate transform;
-- integer 8192/6144 truncated to 1 and revealed the unscaled source location.
-- Bumped to 58: pass every stretched-footprint equivalent through vanilla InitialReveal and
-- scan only its first selected winner instead of revealing the complete equivalent cover.
SuperBigMap.SECTOR_PATCH_VERSION = 58
-- RandomMapGenerator Generate/DoGenerate/OnGenerateLogic + map-access patch
-- (sbm_map_generation). 93 staged the native start-sector annotation across temporary source
-- migration. 94 persisted exhaustive source/transform/overlap selection diagnostics.
-- Bumped to 95: accept and verify the variable-size stretched-equivalent initial reveal set.
-- Bumped to 96: add the exact vanilla fast path and full shared-preset/session teardown.
-- Bumped to 97: validate the singular vanilla-selected start reveal independently from the
-- larger stretched-equivalent candidate count.
-- Bumped to 98: restore deferred underground Elevators only after their map becomes current;
-- guard and audit asynchronous native supply-fragment overlay copies across the switch.
-- Bumped to 99: trace map-scoped supply grids and game-time callbacks across every underground
-- Elevator reconstruction stage to identify the remaining native overlay assertion.
-- Bumped to 100: distinguish vanilla-preserved native enrichment coordinate overlaps from
-- transform-introduced collisions, log both owners, and reject only introduced collisions.
-- Bumped to 101: pre-plan every native enrichment destination and move only transform-introduced
-- hex collisions to the nearest free non-primary hex before recreation.
-- Bumped to 102: read Relaunched supply MapVars from their actual per-map lowercase fields and
-- trace the native overlay-copy signature without touching the strict global environment.
-- Bumped to 103: trace MergeGrids provenance and the complete delayed supply-overlay fragment
-- footprint, including live/captured grid identity and every native offset-grid coordinate.
-- Bumped to 104: bridge those diagnostics into SupplyGrid.lua's private function environment;
-- public-global wrappers do not intercept the shipped closure's delayed line-1665 callback.
-- Bumped to 105: require at least one captured private environment before reporting that bridge
-- verified; an empty record set previously produced a false-positive verification result.
SuperBigMap.GENERATOR_PATCH_VERSION = 105

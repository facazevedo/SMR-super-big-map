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
SuperBigMap.SECTOR_PATCH_VERSION = 45
-- RandomMapGenerator Generate/DoGenerate + map-access patch (sbm_map_generation). Bumped to 21:
-- re-verify the deferred underground access gate after CommonLua finishes its reload, and trace
-- every map-switch request so first-click preparation cannot be silently bypassed again.
SuperBigMap.GENERATOR_PATCH_VERSION = 21

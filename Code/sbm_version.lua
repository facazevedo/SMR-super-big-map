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
SuperBigMap.SECTOR_PATCH_VERSION = 34
-- RandomMapGenerator Generate/DoGenerate patch (sbm_map_generation). Bumped to 7:
-- the DoGenerate wrapper now calls RmgPlacement.Begin/End around the original, so the
-- closure changed and must reinstall cleanly on an in-session reload.
SuperBigMap.GENERATOR_PATCH_VERSION = 7

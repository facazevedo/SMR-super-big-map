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
SuperBigMap.SECTOR_PATCH_VERSION = 27
-- RandomMapGenerator Generate/DoGenerate patch (sbm_map_generation). Bumped to 7:
-- the DoGenerate wrapper now calls RmgPlacement.Begin/End around the original, so the
-- closure changed and must reinstall cleanly on an in-session reload.
SuperBigMap.GENERATOR_PATCH_VERSION = 7

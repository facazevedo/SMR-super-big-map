-- Bigger Maps -- internal patch-guard version constants.
--
-- These are NOT the published mod version. The canonical mod version lives in
-- metadata.lua ('version'); this file must not duplicate it. The constants below
-- are hot-reload patch-identity guards: bump one when the corresponding engine
-- monkey-patch closures change, so they reinstall cleanly on an in-session mod
-- reload instead of leaving stale closures behind.

local BiggerMaps = rawget(_G, "BiggerMaps")
if type(BiggerMaps) ~= "table" then
	BiggerMaps = {}
	rawset(_G, "BiggerMaps", BiggerMaps)
end

-- Shared mod state: saved vanilla originals and patch-installed guards, used by the
-- monkey-patching domain modules so apply/restore share one place (no _G globals).
BiggerMaps.State = BiggerMaps.State or {}

-- Sector exploration + overview-highlight patches (bm_sector_exploration / bm_sector_highlight).
BiggerMaps.SECTOR_PATCH_VERSION = 21
-- RandomMapGenerator Generate/DoGenerate patch (bm_map_generation).
BiggerMaps.GENERATOR_PATCH_VERSION = 2

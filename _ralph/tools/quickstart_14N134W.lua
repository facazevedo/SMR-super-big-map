-- Quick-start a new expanded game exactly as pressing START on the colony site screen does.
--
-- Landing site is given in MINUTES and the sign convention is the internal one, which is
-- inverted relative to the UI label: the screen's "14N 134W" is latitude -14, longitude -134.
-- GetOverlayValues is vanilla's own landing-site call: it sets params.Seed = xxhash(lat, long)
-- and fills altitude and the resource/threat overlays from the planet grids, so the derived map
-- template matches what the colony site screen would have chosen. Faking latitude/longitude and
-- Seed by hand picks a different template (CMix_01 or CMix_10 instead of CMix_02).
local LAT_MINUTES = -14 * 60
local LONG_MINUTES = -134 * 60
local GAME_RULES = { RoughTerrain = true }

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		DoneGame()
		NewGame()
		InitNewGameMissionParams()
		LoadLastNewGameSettings("regular", GAME_RULES)
		ChangeMap("PreGame")

		local params = g_CurrentMapParams
		params.map = ""
		GetOverlayValues(LAT_MINUTES, LONG_MINUTES)
		-- EXPAND MAP. The pregame toggle mirrors this into g_CurrentMapParams so it survives the
		-- new-game Lua reload; setting it directly is the same thing the toggle does.
		params.SuperBigMapExpandMap = true

		printf("[SBM QUICKSTART] lat=%s long=%s altitude=%s seed=%s map=%s rough=%s expand=%s",
			tostring(params.latitude), tostring(params.longitude), tostring(params.Altitude),
			tostring(params.Seed), tostring(GetCurrentRandomMapName()),
			tostring(IsGameRuleActive("RoughTerrain")), tostring(params.SuperBigMapExpandMap))

		-- This is the Start button: everything above is the colony site screen.
		GenerateCurrentRandomMap()

		local map = CurrentMap
		printf("[SBM QUICKSTART] generated map=%s hex=%sx%s",
			tostring(map and map.name), tostring(map and map.hex_width),
			tostring(map and map.hex_height))
	end, function(e) return tostring(e) .. "\n" .. debug.traceback() end)
	if not ok then
		printf("[SBM QUICKSTART] FAILED %s", tostring(err))
	end
end)

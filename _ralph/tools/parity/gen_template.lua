-- Parity twin generator (default coordinates 30S146E = lat 1800, lon 8760 arc-minutes;
-- POSITIVE latitude is SOUTH, POSITIVE longitude is EAST).
-- Preamble reused verbatim from scratch/gen_vanilla.lua + gen_expanded.lua.
-- Coordinates: this game treats POSITIVE latitude as SOUTH and POSITIVE longitude
-- as EAST (ModTools/Src/Lua/UI/PlanetUI.lua PlanetFormatCoordsToPrompt), so
-- 30S146E == GetOverlayValues(1800, 8760). That call also sets
-- g_CurrentMapParams.Seed = xxhash(lat, long), which is what pins the SURFACE seed
-- identically for both twins.
--
-- Two placeholder tokens are substituted by run_parity.py (deliberately not spelled
-- out here: this comment would itself be substituted).

g_ParityStatus = "initializing"
g_ParityError = false
g_ParitySurfaceSeed = false
g_ParityUndergroundSeed = false
g_ParityUndergroundPin = false
g_ParityUndergroundPinApplied = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local mod
		for _, candidate in ipairs(ModsLoaded or {}) do
			if candidate.id == "SuperBigMap" then
				mod = candidate
				break
			end
		end
		local SBM = (mod and mod.env and mod.env.SuperBigMap) or rawget(_G, "SuperBigMap")
		if type(SBM) ~= "table" then
			error("SuperBigMap mod environment not found")
		end

		if type(SBM.PregameToggle) == "table" then
			SBM.PregameToggle.ResetForVanillaSession("parity_30S146E")
		end

		NewGame({ seed_text = "LOZL3FQr" })
		InitNewGameMissionParams()
		g_CurrentMapParams = { colony_name = "The Gem", rocket_name = "Liberty #1", rocket_name_base = "Liberty" }
		g_CurrentMissionParams = {
			GameMode = "regular", GameSessionID = "Bw-yVaHdZElRuJF4",
			SelectedSpotChallengeMods = { ColdWave=0, Concrete=5, DustDevils=5, DustStorm=0, Metals=10, Meteor=20, Water=0 },
			idCommanderProfile = "rocketscientist", idFoundingFaction = "MarsDemocraticParty",
			idGameRules = {}, idHintsMode = "on", idMissionLogo = "IMM",
			idMissionSponsor = "IMM", idMystery = "BlackCubeMystery", idRivalColonies = {"random","random","random"}
		}
		if type(PGColonyNameObjectCreate) == "function" then
			g_CurrentMissionParams.idMissionName = PGColonyNameObjectCreate()
			if g_CurrentMissionParams.idMissionName then g_CurrentMissionParams.idMissionName.display_name = "The Gem" end
		end
		g_SessionOptions = {}
		if type(Game) == "table" then Game.game_rules = {}; Game.forced_game_rules = {} end
		g_SessionSeed = 301460101; g_InitialSessionSeed = g_SessionSeed
		if type(GameRandom) == "table" and type(GameRandom.new) == "function" then
			SessionRandom = GameRandom:new(nil, g_SessionSeed)
		end

		ChangeMap("PreGame")
		GetOverlayValues(__LAT__, __LON__, nil, g_CurrentMapParams)
		g_CurrentMapParams.map = ""
		g_ParitySurfaceSeed = g_CurrentMapParams.Seed

		if type(SBM.PregameToggle) == "table" then
			SBM.PregameToggle.SetSelected(__EXPAND__, "parity_30S146E")
			SBM.PregameToggle.SetStartArmed(__EXPAND__, "parity_30S146E")
		end
		g_CurrentMapParams.SuperBigMapExpandMap = __EXPAND__ or nil

__TWIN_SEED_BLOCK__

__UNDERGROUND_PIN_BLOCK__

__EXTRA_SETUP__

		g_ParityStatus = "generating"
		GenerateCurrentRandomMap()

		local function find_underground()
			for i = 1, #(Maps or {}) do
				local m = Maps[i]
				if m and m.mapdata and m.mapdata.Environment == "Underground" then
					return m
				end
			end
			return false
		end

		local surface = Maps and Maps[1]

		-- The expanded surface stretch runs asynchronously once MapGenerated and
		-- CityInitialized have both fired. GenerateCurrentRandomMap returns before that.
		if __EXPAND__ then
			g_ParityStatus = "waiting_surface_stretch"
			local waited = 0
			while surface and surface.SuperBigMapSurfaceStretchDone ~= true and waited < 600000 do
				Sleep(500)
				waited = waited + 500
			end
			if not surface or surface.SuperBigMapSurfaceStretchDone ~= true then
				error("surface stretch did not complete (waited " .. tostring(waited) .. "ms)")
			end
		end

		-- Visit the underground on BOTH twins so any CityInit-time underground spawning
		-- happens symmetrically. On the expanded twin this is also the first-access gate
		-- that runs the deferred underground pipeline.
		local ug = find_underground()
		if not ug then
			error("no underground map was generated")
		end
		g_ParityStatus = "entering_underground"
		ChangeCurrentMapSlot(ug.slot, true)

		if __EXPAND__ then
			g_ParityStatus = "waiting_underground_prepare"
			local waited = 0
			while ug.SuperBigMapUndergroundPrepared ~= true and waited < 900000 do
				if ug.SuperBigMapUndergroundPreparationFailed == true then
					error("underground preparation reported failure")
				end
				Sleep(500)
				waited = waited + 500
			end
			if ug.SuperBigMapUndergroundPrepared ~= true then
				error("underground preparation did not complete (waited " .. tostring(waited) .. "ms)")
			end
		end

		-- Let any tail-end deferred work settle before the dump.
		Sleep(2000)

		local s_holder = surface and GetRandomMapGenerator(surface)
		local u_holder = GetRandomMapGenerator(ug)
		g_ParitySurfaceSeed = s_holder and s_holder.Seed or g_ParitySurfaceSeed
		g_ParityUndergroundSeed = u_holder and u_holder.Seed or false

		-- A silently unapplied pin would produce an unpinned control that still looks like a
		-- valid run, so fail the twin loudly instead.
		if g_ParityUndergroundPin then
			if g_ParityUndergroundPinApplied ~= true then
				error("reference underground pin never fired (FillRandomMapGen wrap not reached)")
			end
			if g_ParityUndergroundSeed ~= g_ParityUndergroundPin then
				error("reference underground pin ignored: holder seed "
					.. tostring(g_ParityUndergroundSeed) .. " ~= pin "
					.. tostring(g_ParityUndergroundPin))
			end
		end

		g_ParityStatus = "complete"
	end, debug.traceback)
	if not ok then
		g_ParityError = tostring(err)
		g_ParityStatus = "error"
	end
end)
return "parity_thread_started"

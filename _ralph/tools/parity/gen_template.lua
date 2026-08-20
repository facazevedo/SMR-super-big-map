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

-- The debug build reports ordinary assignment to a previously unknown global as a
-- Lua error even though it completes the assignment.  Declare the DAP-visible
-- status cells without tripping that diagnostic; later assignments are ordinary.
rawset(_G, "g_ParityStatus", "initializing")
rawset(_G, "g_ParityError", false)
rawset(_G, "g_ParitySurfaceSeed", false)
rawset(_G, "g_ParityUndergroundSeed", false)
rawset(_G, "g_ParityUndergroundPin", false)
rawset(_G, "g_ParityUndergroundPinApplied", false)
rawset(_G, "g_ParityGameInitPending", -1)
rawset(_G, "g_ParityGameInitWaitMs", -1)
rawset(_G, "g_ParityGameInitRemaining", -1)
rawset(_G, "g_ParitySettleWaitMs", -1)
rawset(_G, "g_ParitySettleSurface", -1)
rawset(_G, "g_ParitySettleUnderground", -1)

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

		__FLIGHT_SANITATION__

		g_ParityStatus = "generating"
		-- Generate with game time RUNNING.  CityInitialized fires before GenerateCurrentRandomMap
		-- returns, and it sites the passage markers with FindUnobstructedDepositPos, which reads
		-- map.object_hex_grid -- a grid that stays empty until the deferred GridObject:GameInit pass
		-- has run, and that pass only runs when game time advances.  A headless generate that never
		-- ticks therefore sites those markers against an empty grid.  Measured 2026-08-20 at P1: the
		-- two passage signs, their markers and their attached FX landed 8 rows away from the protected
		-- control's, with grid_objects pending 61 of 61 at CityInit.  Hold the pause set aside for the
		-- duration so generation ticks the way it does in a played game, then restore it exactly.
		do
			local saved = {}
			for reason in pairs(PauseReasons) do saved[#saved + 1] = reason end
			for i = 1, #saved do PauseReasons[saved[i]] = nil end
			ResumeGame()
			local gen_ok, gen_err = pcall(GenerateCurrentRandomMap)
			if #saved > 0 then
				PauseGame()
				for i = 1, #saved do PauseReasons[saved[i]] = true end
			end
			if not gen_ok then error(gen_err) end
		end

		-- Run the engine's DEFERRED GameInit pass before measuring anything.  Everything the
		-- generator placed has its GameInit held until game time first advances: GridObject:GameInit
		-- applies each hex shape (which is what creates the GridObjectList buckets), the
		-- PrefabFeature GameLogic hooks add their SafariSights, reveal FX spawn ParSystem carriers
		-- and terrain deposits seat their Z.  A generated-but-never-started game sits at GameTime 0
		-- behind the mission-briefing pause, so whether any of that exists at dump time depends on
		-- whether a tick happened to slip through before the briefing paused the game -- i.e. on how
		-- fast the machine is.  Measured 2026-08-20: after this machine's asset read speed fell from
		-- 48 to 19 MB/s, the P1 control became a deterministic 27,970 rows against its protected
		-- 28,300 (330 GameInit-created objects absent, grid_objects_applied 0, GameTime 0, two pause
		-- reasons held).  Advance game time explicitly until the pass has run, then restore the exact
		-- pause set.  PauseGame/ResumeGame are called directly so no Pause/Resume Msg listener sees
		-- this, and the wait ends the moment the pass is done so no gameplay of consequence elapses.
		local function advance_deferred_gameinit(label)
			local maps = {}
			for mi = 1, #(Maps or {}) do
				local m = Maps[mi]
				if m and HasGameLogic(m) then maps[#maps + 1] = m end
			end
			-- Collect the grid objects ONCE; the poll below then only re-reads their flags
			-- instead of re-walking ~28,000 map objects every 100 ms.
			local watched = {}
			for mi = 1, #maps do
				local objs = maps[mi]:MapGet("map") or {}
				for i = 1, #objs do
					local o = objs[i]
					if o and IsValid(o) and IsKindOf(o, "GridObject") then
						watched[#watched + 1] = o
					end
				end
			end
			local function pending()
				local n = 0
				for i = 1, #watched do
					local o = watched[i]
					if IsValid(o) and rawget(o, "grids_applied") ~= true then
						n = n + 1
					end
				end
				return n
			end
			local before = pending()
			g_ParityGameInitPending = tostring(label) .. ":" .. tostring(before)
			if before > 0 then
				local saved = {}
				for reason in pairs(PauseReasons) do saved[#saved + 1] = reason end
				for i = 1, #saved do PauseReasons[saved[i]] = nil end
				ResumeGame()
				local waited = 0
				while pending() > 0 and waited < 30000 do
					Sleep(100)
					waited = waited + 100
				end
				if #saved > 0 then
					PauseGame()
					for i = 1, #saved do PauseReasons[saved[i]] = true end
				end
				g_ParityGameInitWaitMs = waited
				g_ParityGameInitRemaining = pending()
				if g_ParityGameInitRemaining > 0 then
					error("deferred GameInit pass did not complete ("
						.. tostring(g_ParityGameInitRemaining) .. " of " .. tostring(before)
						.. " grid objects unapplied after " .. tostring(waited) .. "ms)")
				end
			end
		end

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

		-- Capture the generator holders BEFORE any game time is allowed to advance: the holders
		-- are generation-time state and do not survive the start of the game (measured: reading the
		-- underground holder afterwards returned the SURFACE seed and tripped the pin check).  The
		-- underground holder may not exist yet on the expanded twin, whose underground is prepared
		-- lazily on first access, so that side is re-read below before the second advance.
		local s_holder = surface and GetRandomMapGenerator(surface)
		local u_early = find_underground()
		local u_holder = u_early and GetRandomMapGenerator(u_early)
		g_ParitySurfaceSeed = s_holder and s_holder.Seed or g_ParitySurfaceSeed
		g_ParityUndergroundSeed = u_holder and u_holder.Seed or false

		-- The passage endpoints' signs/markers are sited by a search that consults the hex object
		-- grid, so the deferred GameInit pass has to have run BEFORE the underground visit spawns
		-- them, not only before the dump.  Measured 2026-08-20: with no tick before that point the
		-- two P1 passage signs, their markers and their attached FX sited 8 rows away from the
		-- protected control's.
		advance_deferred_gameinit("post_generate")

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

		-- Let any tail-end deferred work settle before the dump.  A FIXED sleep is a race: the
		-- engine's post-generation sweep keeps creating objects after GenerateCurrentRandomMap
		-- returns (hex-grid GridObjectList buckets, reveal-FX ParSystem carriers, prefab-feature
		-- SafariSights) and seats deposits on terrain.  Measured 2026-08-20: on a machine whose
		-- asset read speed had dropped from 48 to 19 MB/s, the 2 s expired mid-sweep and the dump
		-- read a map 330 objects short of the protected 28,300-row P1 control, deterministically
		-- (two byte-identical 27,970-row runs).  Wait for the full-map census on BOTH maps to stop
		-- changing instead, keeping the old 2 s as the floor, so the settle scales with the
		-- machine rather than assuming it.  A genuinely stuck game still fails loudly on the cap.
		Sleep(2000)

		-- Expanded twin only: its underground holder did not exist at the early capture above.
		if not g_ParityUndergroundSeed then
			local late_holder = GetRandomMapGenerator(ug)
			g_ParityUndergroundSeed = late_holder and late_holder.Seed or false
		end

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

		-- Final settle, with game time running.  Reveal FX carriers and terrain-deposit Z seating
		-- are game-time work too, so a settle that only sleeps real time leaves them out (measured:
		-- 3 ParSystems absent and 2 deposits with no Z).  Run time until the full-map census on both
		-- maps stops changing, then restore the exact pause set.  A fixed sleep here would be a race
		-- against machine speed; this scales with the machine instead.
		do
			local SETTLE_POLL_MS = 200
			local SETTLE_STABLE_SAMPLES = 5   -- 1 s of no change on either map
			local SETTLE_CAP_MS = 30000
			local maps = {}
			for mi = 1, #(Maps or {}) do
				local m = Maps[mi]
				if m and HasGameLogic(m) then maps[#maps + 1] = m end
			end
			local saved = {}
			for reason in pairs(PauseReasons) do saved[#saved + 1] = reason end
			for i = 1, #saved do PauseReasons[saved[i]] = nil end
			ResumeGame()
			local stable, last, waited = 0, false, 0
			while waited < SETTLE_CAP_MS do
				local counts = {}
				for mi = 1, #maps do counts[mi] = #(maps[mi]:MapGet("map") or {}) end
				local key = table.concat(counts, ",")
				if key == last then
					stable = stable + 1
					if stable >= SETTLE_STABLE_SAMPLES then break end
				else
					stable, last = 0, key
				end
				Sleep(SETTLE_POLL_MS)
				waited = waited + SETTLE_POLL_MS
			end
			if #saved > 0 then
				PauseGame()
				for i = 1, #saved do PauseReasons[saved[i]] = true end
			end
			g_ParitySettleWaitMs = waited
			g_ParitySettleSurface = last
			if waited >= SETTLE_CAP_MS then
				error("map census never settled (waited " .. tostring(waited) .. "ms, counts " .. tostring(last) .. ")")
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

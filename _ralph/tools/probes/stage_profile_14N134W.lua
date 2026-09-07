-- Per-stage profile of the DEPLOYED super-big-map build at 14N134W (RoughTerrain, EXPAND MAP on).
--
-- Same START-button T0->T1 clock as t0t1_stopwatch.lua. Before pressing START it turns on the mod's own
-- built-in loading timer (sbm_diagnostics.lua LoadingBegin/End/Step/Phase) by flipping the two
-- constants the modules read at call time -- no redeploy, no payload change:
--   SuperBigMap.Config.DEBUG_LOGGING_ENABLED, SuperBigMap.Config.DEBUG_LOADING_TIMINGS
-- Every instrumented stage then prints "[Super Big Map][LoadingTiming] ..." lines with duration_ms /
-- since_previous_ms into the game log; the top-up code prints its own phase timings under the same gate.
-- The timer accounts for its own print cost (print_ms), so the log is the profile.
--
-- Result string in STAGE_PROFILE_T0T1 (poll it from the harness), full detail in the game log.
STAGE_PROFILE_T0T1 = nil
CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		DoneGame()
		NewGame()
		InitNewGameMissionParams()
		LoadLastNewGameSettings("regular", { RoughTerrain = true })
		ChangeMap("PreGame")
		local params = g_CurrentMapParams
		params.map = ""
		GetOverlayValues(-14 * 60, -134 * 60)
		params.rocket_name, params.rocket_name_base = GenerateRocketName(true)
		params.SuperBigMapExpandMap = true
		local seed = params.Seed

		-- turn the built-in stage timer on (read at call time by every module). The mod runs in its
		-- own Lua environment, so its SuperBigMap table is reached through ModsLoaded, not _G.
		local SBM
		for i = 1, #(ModsLoaded or {}) do
			local m = ModsLoaded[i]
			local env = m and m.env
			local s = env and rawget(env, "SuperBigMap")
			if type(s) == "table" and type(s.Config) == "table" then SBM = s break end
		end
		if not SBM then error("SuperBigMap.Config not found in any loaded mod environment") end
		local C = SBM.Config
		C.DEBUG_LOGGING_ENABLED = true
		C.DEBUG_LOADING_TIMINGS = true
		local diag = SBM.Diagnostics
		local timer_on = diag and type(diag.LoadingEnabled) == "function" and diag.LoadingEnabled() == true
		print("[STAGE_PROFILE] loading timer enabled=" .. tostring(timer_on))

		local function both_flags(m)
			return m and m.SuperBigMapSurfaceStretchDone == true
				and m.SuperBigMapSurfacePostPipelineRevalidationComplete == true
		end
		local function scan()
			if both_flags(CurrentMap) then return CurrentMap, "current" end
			local slots = (config and tonumber(config.MapSlots)) or 4
			for slot = 1, slots do
				local m = Maps and Maps[slot]
				if both_flags(m) then return m, "slot" .. slot end
			end
			return nil
		end

		-- ===== START pressed =====
		local t0 = GetPreciseTicks()
		print("[STAGE_PROFILE] T0 ticks=" .. tostring(t0))
		WaitWarnAboutSkippedMods()
		LoadingScreenOpen("idLoadingScreen", "StartGame")
		SaveNewGameSettings()
		TelemetryRestartSession()
		MarkNameAsUsed("Rocket", g_CurrentMapParams.rocket_name_base)
		WaitPlanetCamera("PlanetMars", "close")
		local t_gen0 = GetPreciseTicks()
		print("[STAGE_PROFILE] generation begins at +" .. tostring(t_gen0 - t0) .. " ms")
		GenerateCurrentRandomMap()
		local t_return = GetPreciseTicks()
		print("[STAGE_PROFILE] GenerateCurrentRandomMap returned at +" .. tostring(t_return - t0) .. " ms")
		LoadingScreenClose("idLoadingScreen", "StartGame")

		local t1, t1_where = nil, nil
		local deadline = t0 + 900000
		while GetPreciseTicks() < deadline do
			local m, where = scan()
			if m then t1, t1_where = GetPreciseTicks(), where .. ":" .. tostring(m.name) break end
			Sleep(100)
		end
		print("[STAGE_PROFILE] T1 at +" .. tostring(t1 and (t1 - t0) or "TIMEOUT") .. " ms")

		local m = CurrentMap
		STAGE_PROFILE_T0T1 = string.format(
			"t0_to_t1_ms=%s pre_generation_ms=%d generate_returned_ms=%d t1_map=%s map=%s hex=%sx%s seed=%s timer=%s",
			t1 and tostring(t1 - t0) or "TIMEOUT", t_gen0 - t0, t_return - t0,
			tostring(t1_where), tostring(m and m.name), tostring(m and m.hex_width), tostring(m and m.hex_height),
			tostring(seed), tostring(timer_on))
	end, function(e) return tostring(e) .. "\n" .. debug.traceback() end)
	if not ok then STAGE_PROFILE_T0T1 = "FAILED " .. tostring(err) end
	printf("[STAGE_PROFILE] %s", tostring(STAGE_PROFILE_T0T1))
end)

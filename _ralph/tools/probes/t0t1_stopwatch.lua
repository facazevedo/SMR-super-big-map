-- Start-button T0->T1 stopwatch for whatever super-big-map build is deployed.
--
-- T0 is the START button press. The colony-site screen's START action (Data/XDef/
-- PGMissionLandingSpotRemastered.lua) runs, on a real-time thread:
--   WaitWarnAboutSkippedMods; LoadingScreenOpen("idLoadingScreen","StartGame"); SaveNewGameSettings;
--   TelemetryRestartSession; MarkNameAsUsed("Rocket", rocket_name_base); WaitPlanetCamera("PlanetMars",
--   "close"); GenerateCurrentRandomMap; LoadingScreenClose(...)
-- That body is reproduced verbatim below and T0 is stamped immediately before its first statement, so
-- everything the button does before generation is inside the clock.
--
-- T1 is the first instant ANY loaded map carries both SuperBigMapSurfaceStretchDone and
-- SuperBigMapSurfacePostPipelineRevalidationComplete -- the two conditions the acceptance executor's
-- receipt requires. Scanning every slot rather than CurrentMap alone: the pipeline can flag the
-- destination before the engine's current-map switch, and a CurrentMap-only poll missed it.
T0T1 = nil
CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		-- colony-site screen state, as the player has it before pressing START
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
		local rough_t0 = IsGameRuleActive("RoughTerrain")
		local seed = params.Seed

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
		WaitWarnAboutSkippedMods()
		local t_warn = GetPreciseTicks()
		LoadingScreenOpen("idLoadingScreen", "StartGame")
		SaveNewGameSettings()
		TelemetryRestartSession()
		MarkNameAsUsed("Rocket", g_CurrentMapParams.rocket_name_base)
		WaitPlanetCamera("PlanetMars", "close")
		local t_gen0 = GetPreciseTicks()
		GenerateCurrentRandomMap()
		local t_return = GetPreciseTicks()
		LoadingScreenClose("idLoadingScreen", "StartGame")

		local t1, t1_where, trace = nil, nil, {}
		local deadline, next_trace = t0 + 900000, t0
		while GetPreciseTicks() < deadline do
			local m, where = scan()
			if m then t1, t1_where = GetPreciseTicks(), where .. ":" .. tostring(m.name); break end
			if GetPreciseTicks() >= next_trace and #trace < 40 then
				local cm = CurrentMap
				trace[#trace + 1] = string.format("%ds cur=%s sd=%s rv=%s", math.floor((GetPreciseTicks() - t0) / 1000),
					tostring(cm and cm.name), tostring(cm and cm.SuperBigMapSurfaceStretchDone),
					tostring(cm and cm.SuperBigMapSurfacePostPipelineRevalidationComplete))
				next_trace = GetPreciseTicks() + 10000
			end
			Sleep(100)
		end

		local m = CurrentMap
		local gen = GetRandomMapGenerator and GetRandomMapGenerator(m)
		T0T1 = string.format(
			"t0_to_t1_ms=%s pre_generation_ms=%d warn_ms=%d generate_returned_ms=%d t1_map=%s map=%s hex=%sx%s"
				.. " preset=%s seed=%s rough_t0=%s rough_t1=%s revalidation_error=%s underground=%s trace=[%s]",
			t1 and tostring(t1 - t0) or "TIMEOUT", t_gen0 - t0, t_warn - t0, t_return - t0,
			tostring(t1_where), tostring(m and m.name), tostring(m and m.hex_width), tostring(m and m.hex_height),
			tostring(gen and gen.Id), tostring(seed), tostring(rough_t0), tostring(IsGameRuleActive("RoughTerrain")),
			tostring(m and m.SuperBigMapSurfacePostPipelineRevalidationError),
			tostring(UndergroundMap and UndergroundMap.name), table.concat(trace, " | "))
	end, function(e) return tostring(e) .. "\n" .. debug.traceback() end)
	if not ok then T0T1 = "FAILED " .. tostring(err) end
	printf("[T0T1] %s", tostring(T0T1))
end)

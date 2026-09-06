-- Verify the engine decor pass on a real expanded 14N134W start (v887 line + sbm_decor_topup).
-- Waits for the stretch pipeline, then reports the pass's own stats plus an independent census.
rawset(_G, "DECOR", false)
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

		local t0 = GetPreciseTicks()
		LoadingScreenOpen("idLoadingScreen", "StartGame")
		GenerateCurrentRandomMap()
		LoadingScreenClose("idLoadingScreen", "StartGame")

		local function both(m)
			return m and m.SuperBigMapSurfaceStretchDone == true
				and m.SuperBigMapSurfacePostPipelineRevalidationComplete == true
		end
		local t1
		while GetPreciseTicks() < t0 + 900000 do
			local hit = both(CurrentMap)
			if not hit then
				for slot = 1, ((config and tonumber(config.MapSlots)) or 4) do
					if both(Maps and Maps[slot]) then hit = true break end
				end
			end
			if hit then t1 = GetPreciseTicks() break end
			Sleep(100)
		end

		local SBM
		for i = 1, #ModsLoaded do
			local env = ModsLoaded[i] and ModsLoaded[i].env
			if env and env.SuperBigMap and env.SuperBigMap.DecorTopUp then SBM = env.SuperBigMap end
		end
		local map = CurrentMap
		local stats = SBM and SBM.DecorTopUp.LastStats or {}
		local parts = {}
		for _, k in ipairs({ "enabled", "reason", "error", "environment", "area_factor", "decor_sites",
			"vanilla_decor_groups", "unused_sites", "target", "capped_from", "placed", "objects",
			"skipped_obstructed", "skipped_no_match", "failed", "sites_exhausted", "ms", "markers_resolved", "markers_unresolved",
			"obstruct_circles", "decorated_circles", "fallback_sites", "sites_prestretched", "sites_relocated", "skipped_by_obstruct", "skipped_by_decorated", "placed_authored", "placed_synthetic", "synthetic_templates", "synthetic_attempts", "synthetic_budget", "synthetic_rejected_obstruct", "synthetic_rejected_decorated", "synthetic_rejected_terrain", "synthetic_rejected_bounds", "synthetic_rejected_no_match", "synthetic_rejected_failed", "dropped_non_cosmetic", "synthetic_allowed_types", "synthetic_templates_exhausted" }) do
			parts[#parts + 1] = k .. "=" .. tostring(stats[k])
		end
		-- independent census
		local pass_objects, used_sites, all_sites, in_bounds, floating = 0, 0, 0, 0, 0
		local w, h = terrain.GetMapSize(map)
		map:MapForEach("map", "CObject", function(o)
			if o.SuperBigMapDecorEnginePass then
				pass_objects = pass_objects + 1
				local x, y, z = o:GetPosXYZ()
				if x >= 0 and y >= 0 and x < w and y < h then in_bounds = in_bounds + 1 end
				local tz = terrain.GetHeight(map, point(x, y))
				if math.abs((z or tz) - tz) > 2000 then floating = floating + 1 end
			end
		end)
		map:MapForEach("map", "PrefabDecorMarker", function(m)
			all_sites = all_sites + 1
			if tostring(m.DecorTestPrefab or "") ~= "" then used_sites = used_sites + 1 end
		end)
		local last = SBM and SBM.DecorTopUp.LastObjects or {}
		local alive, flagged, classes = 0, 0, {}
		-- outer two-sector band = outer 10% of each axis; vanilla's border occupies the same share
		local ring_objects, ring_lo_x, ring_hi_x, ring_lo_y, ring_hi_y = 0, w / 10, w - w / 10, h / 10, h - h / 10
		for _, o in ipairs(last) do
			if IsValid(o) then
				alive = alive + 1
				local ox, oy = o:GetPosXYZ()
				if ox < ring_lo_x or ox >= ring_hi_x or oy < ring_lo_y or oy >= ring_hi_y then ring_objects = ring_objects + 1 end
				if o.SuperBigMapDecorEnginePass then flagged = flagged + 1 end
				local c = tostring(o.class); classes[c] = (classes[c] or 0) + 1
			end
		end
		local top = {}
		for c, n in pairs(classes) do top[#top + 1] = c .. ":" .. n end
		table.sort(top)
		-- The engine truncates long console/eval strings, so split the report into short globals.
		rawset(_G, "DECOR_STATS1", table.concat(parts, " ", 1, math.min(14, #parts)))
		rawset(_G, "DECOR_STATS2", #parts > 14 and table.concat(parts, " ", 15, math.min(28, #parts)) or "")
		rawset(_G, "DECOR_STATS3", #parts > 28 and table.concat(parts, " ", 29, #parts) or "")
		rawset(_G, "DECOR_CLASSES", table.concat(top, ","))
		DECOR = string.format("t0_to_t1_ms=%s hex=%sx%s placed=%s objects=%s ms=%s | census: pass_objects=%d in_bounds=%d floating_gt_20m=%d decor_sites=%d used_now=%d last_objects=%d alive=%d flagged=%d ring_objects=%d",
			t1 and tostring(t1 - t0) or "TIMEOUT", tostring(map.hex_width), tostring(map.hex_height),
			tostring(stats.placed), tostring(stats.objects), tostring(stats.ms),
			pass_objects, in_bounds, floating, all_sites, used_sites, #last, alive, flagged, ring_objects)
	end, function(e) return tostring(e) .. "\n" .. debug.traceback() end)
	if not ok then DECOR = "FAILED " .. tostring(err) end
	printf("[DECOR] %s", tostring(DECOR))
end)

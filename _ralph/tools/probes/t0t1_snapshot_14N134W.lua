-- Start-button T0->T1 stopwatch PLUS a post-T1 scenario snapshot, for before/after comparisons of one
-- optimization at 14N134W (RoughTerrain, EXPAND MAP on). Same T0/T1 definitions as t0t1_stopwatch.lua;
-- everything below T1 runs after the clock has stopped, so it cannot affect the measurement.
--
-- Globals published for the harness to fetch (cli.py eval / state):
--   SNAP_T0T1     "t0_to_t1_ms=... " result line (same fields as the stopwatch)
--   SNAP_REPORTS  "key=value;..." flat dump of the outer-resource terrain report, its audit report,
--                 resource sites, rocket pads and passage glue records
--   SNAP_LATTICE  comma-separated raw height-grid values on a 32-cell lattice over the whole map
--                 (row-major, 256x256 for an 8192-tile map), plus SNAP_LATTICE_META "w=..,h=..,step=32"
SNAP_T0T1, SNAP_REPORTS, SNAP_LATTICE, SNAP_LATTICE_META = nil, nil, nil, nil
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
		LoadingScreenOpen("idLoadingScreen", "StartGame")
		SaveNewGameSettings()
		TelemetryRestartSession()
		MarkNameAsUsed("Rocket", g_CurrentMapParams.rocket_name_base)
		WaitPlanetCamera("PlanetMars", "close")
		local t_gen0 = GetPreciseTicks()
		GenerateCurrentRandomMap()
		local t_return = GetPreciseTicks()
		LoadingScreenClose("idLoadingScreen", "StartGame")

		local t1, t1_where = nil, nil
		local deadline = t0 + 900000
		while GetPreciseTicks() < deadline do
			local m, where = scan()
			if m then t1, t1_where = GetPreciseTicks(), where .. ":" .. tostring(m.name) break end
			Sleep(100)
		end

		local m = CurrentMap
		SNAP_T0T1 = string.format(
			"t0_to_t1_ms=%s pre_generation_ms=%d generate_returned_ms=%d t1_map=%s map=%s hex=%sx%s seed=%s rough=%s revalidation_error=%s",
			t1 and tostring(t1 - t0) or "TIMEOUT", t_gen0 - t0, t_return - t0,
			tostring(t1_where), tostring(m and m.name), tostring(m and m.hex_width), tostring(m and m.hex_height),
			tostring(seed), tostring(IsGameRuleActive("RoughTerrain")),
			tostring(m and m.SuperBigMapSurfacePostPipelineRevalidationError))
		printf("[SNAP] %s", tostring(SNAP_T0T1))

		-- ===== clock stopped; scenario snapshot =====
		local parts = {}
		local function flat(prefix, t, depth)
			if type(t) ~= "table" then parts[#parts + 1] = prefix .. "=" .. tostring(t) return end
			if depth > 2 then parts[#parts + 1] = prefix .. "=<table>" return end
			local keys = {}
			for k in pairs(t) do keys[#keys + 1] = k end
			table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
			for _, k in ipairs(keys) do
				local v = t[k]
				if type(v) == "table" then
					if type(k) == "number" or depth < 1 then flat(prefix .. "." .. tostring(k), v, depth + 1) end
				elseif type(v) ~= "function" and type(v) ~= "userdata" then
					parts[#parts + 1] = prefix .. "." .. tostring(k) .. "=" .. tostring(v)
				end
			end
		end
		flat("terrain_report", m.SuperBigMapOuterResourceTerrainReport, 0)
		flat("audit_report", m.SuperBigMapOuterResourceTerrainAudit, 0)
		local sites = m.SuperBigMapOuterResourceTerrainSites
		if type(sites) == "table" then
			parts[#parts + 1] = "sites.count=" .. tostring(#sites)
			for i, s in ipairs(sites) do
				parts[#parts + 1] = string.format("site.%d=%s|%s|%s|%s|mod=%s|ver=%s", i, tostring(s.kind),
					tostring(s.resource), tostring(s.q), tostring(s.r), tostring(s.modified == true),
					tostring(s.verified == true))
			end
		end
		local pads = m.SuperBigMapOuterResourceRocketPads
		if type(pads) == "table" then
			parts[#parts + 1] = "pads.count=" .. tostring(#pads)
			for i, p in ipairs(pads) do
				parts[#parts + 1] = string.format("pad.%d=%s|%s|members=%s", i, tostring(p.q), tostring(p.r),
					tostring(p.members))
			end
		end
		local glue = m.SuperBigMapPassageGlueReport
		if type(glue) == "table" then
			for i, g in ipairs(glue) do
				parts[#parts + 1] = string.format("glue.%d=ring%s|surface=%s,%s|image=%s,%s|reason=%s", i,
					tostring(g.ring_distance), tostring(g.surface_q), tostring(g.surface_r),
					tostring(g.twin_image_q), tostring(g.twin_image_r), tostring(g.twin_image_surface_reason))
			end
		end
		SNAP_REPORTS = table.concat(parts, ";")

		-- raw height grid on a 32-cell lattice (values are the engine's U16 height cells)
		local raw = terrain.GetHeightGrid(m)
		local grid = raw and GridToCompute(raw)
		if grid and type(grid.size) == "function" and type(grid.get) == "function" then
			local w, h = grid:size()
			local step = 32
			local values, n = {}, 0
			for y = 0, h - 1, step do
				for x = 0, w - 1, step do
					n = n + 1
					values[n] = tostring(grid:get(x, y))
				end
			end
			SNAP_LATTICE = table.concat(values, ",")
			SNAP_LATTICE_META = string.format("w=%d,h=%d,step=%d,samples=%d", w, h, step, n)
			if grid ~= raw and type(grid.free) == "function" then pcall(grid.free, grid) end
		else
			SNAP_LATTICE, SNAP_LATTICE_META = "", "height grid unavailable"
		end
		printf("[SNAP] snapshot ready: %s; %d report fields", tostring(SNAP_LATTICE_META), #parts)
	end, function(e) return tostring(e) .. "\n" .. debug.traceback() end)
	if not ok then
		SNAP_T0T1 = "FAILED " .. tostring(err)
		SNAP_REPORTS, SNAP_LATTICE, SNAP_LATTICE_META = SNAP_REPORTS or "", SNAP_LATTICE or "", SNAP_LATTICE_META or "failed"
		printf("[SNAP] %s", tostring(SNAP_T0T1))
	end
end)

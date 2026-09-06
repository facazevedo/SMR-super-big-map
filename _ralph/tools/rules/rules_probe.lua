-- Rules-parity baseline probe (surface side).
--
-- Runs the task contract's cold bootstrap at 14N134W (RoughTerrain, EXPAND MAP), stamps T0 at the
-- START press, waits for T1, then reads every surface-side gate's evidence BEFORE any player action.
-- Results land in the global RULES (LuaToJSON-marshalable scalars/arrays only) and are echoed to the
-- log as [RULES] lines.  RULES_STATUS carries coarse progress so a poller can follow the run.
--
-- Gate coverage in this file: seed-parity digests (1), entrance records (2), entrance sector
-- position (3), ring census (4), start reveal (5), sign/deposit visibility (6), decor stats (7).
-- no-errors (8) is judged from the log, underground-first-access (10) is a later step.

rawset(_G, "RULES", false)
rawset(_G, "RULES_STATUS", "init")
rawset(_G, "RULES_ERR", false)
rawset(_G, "RULES_LINE", "")

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		------------------------------------------------------------------ helpers
		local function digest(list)
			table.sort(list)
			local h = 5381
			local blob = table.concat(list, ";")
			for i = 1, #blob do
				h = (h * 33 + string.byte(blob, i)) % 2147483647
			end
			return h, #list
		end

		local function hexof(map, x, y)
			local q, r = WorldToHex(point(x, y))
			return tostring(q) .. "," .. tostring(r)
		end

		local function posxy(o)
			local x, y = o:GetPosXYZ()
			return x, y
		end

		local function visible(o)
			local f = const and const.efVisible
			if not f then return "unknown" end
			local okv, v = pcall(o.GetEnumFlags, o, f)
			if not okv then return "unknown" end
			return (v ~= 0) and true or false
		end

		------------------------------------------------------------------ bootstrap
		RULES_STATUS = "bootstrap"
		DoneGame()
		NewGame()
		InitNewGameMissionParams()
		LoadLastNewGameSettings("regular", { RoughTerrain = true })
		ChangeMap("PreGame")
		local params = g_CurrentMapParams
		params.map = ""
		GetOverlayValues(__LAT__, __LON__)
		params.rocket_name, params.rocket_name_base = GenerateRocketName(true)
		params.SuperBigMapExpandMap = true
		local surface_seed = params.Seed

		------------------------------------------------------------------ START press
		RULES_STATUS = "generating"
		local t0 = GetPreciseTicks()
		WaitWarnAboutSkippedMods()
		LoadingScreenOpen("idLoadingScreen", "StartGame")
		SaveNewGameSettings()
		TelemetryRestartSession()
		MarkNameAsUsed("Rocket", g_CurrentMapParams.rocket_name_base)
		WaitPlanetCamera("PlanetMars", "close")
		GenerateCurrentRandomMap()
		local t_return = GetPreciseTicks()
		LoadingScreenClose("idLoadingScreen", "StartGame")

		local function both_flags(m)
			return m and m.SuperBigMapSurfaceStretchDone == true
				and m.SuperBigMapSurfacePostPipelineRevalidationComplete == true
		end
		local function scan()
			if both_flags(CurrentMap) then return CurrentMap end
			local slots = (config and tonumber(config.MapSlots)) or 4
			for slot = 1, slots do
				if both_flags(Maps and Maps[slot]) then return Maps[slot] end
			end
			return nil
		end

		RULES_STATUS = "waiting_t1"
		local map, t1 = nil, nil
		local deadline = t0 + 900000
		while GetPreciseTicks() < deadline do
			map = scan()
			if map then t1 = GetPreciseTicks() break end
			Sleep(100)
		end
		if not map then error("T1 never reached within 900 s") end

		RULES_STATUS = "reading"
		local R = {}
		R.site = "__SITE__"
		R.map_name = tostring(map.name)
		R.hex_width = map.hex_width
		R.hex_height = map.hex_height
		R.surface_seed = tostring(surface_seed)
		local gen = GetRandomMapGenerator and GetRandomMapGenerator(map)
		R.generator_seed = tostring(gen and gen.Seed)
		R.generator_preset = tostring(gen and gen.Id)
		R.t0_to_t1_ms = t1 and (t1 - t0) or -1
		R.generate_returned_ms = t_return - t0
		R.revalidation_error = tostring(map.SuperBigMapSurfacePostPipelineRevalidationError)

		local w, h = terrain.GetMapSize(map)
		R.world_w, R.world_h = w, h
		local band_x0, band_x1 = w / 10, w - w / 10
		local band_y0, band_y1 = h / 10, h - h / 10
		local function in_ring(x, y)
			return x < band_x0 or x >= band_x1 or y < band_y0 or y >= band_y1
		end

		local SBM
		for i = 1, #(ModsLoaded or {}) do
			local env = ModsLoaded[i] and ModsLoaded[i].env
			if env and env.SuperBigMap then SBM = env.SuperBigMap end
		end
		R.mod_found = SBM and true or false

		------------------------------------------------------------------ gate 1: enrichment digest
		local enrich, ring_enrich = {}, 0
		for _, cls in ipairs({ "DepositMarker", "SubsurfaceAnomalyMarker", "EffectDepositMarker" }) do
			pcall(map.MapForEach, map, "map", cls, function(o)
				local x, y = posxy(o)
				enrich[#enrich + 1] = tostring(o.class) .. "@" .. hexof(map, x, y)
				if in_ring(x, y) then ring_enrich = ring_enrich + 1 end
			end)
		end
		R.enrichment_digest, R.enrichment_count = digest(enrich)
		R.enrichment_in_ring = ring_enrich

		------------------------------------------------------------------ gate 7: decor
		local decor_stats = SBM and SBM.DecorTopUp and SBM.DecorTopUp.LastStats or {}
		for _, k in ipairs({ "enabled", "reason", "error", "target", "placed", "objects", "ring_objects",
			"dropped_non_cosmetic", "placed_authored", "placed_synthetic", "ms" }) do
			R["decor_" .. k] = tostring(decor_stats[k])
		end
		local decor_objs = SBM and SBM.DecorTopUp and SBM.DecorTopUp.LastObjects or {}
		local decor_list, decor_ring, decor_classes = {}, 0, {}
		for _, o in ipairs(decor_objs) do
			if IsValid(o) then
				local x, y = posxy(o)
				decor_list[#decor_list + 1] = tostring(o.class) .. "@" .. hexof(map, x, y)
				if in_ring(x, y) then decor_ring = decor_ring + 1 end
				decor_classes[tostring(o.class)] = (decor_classes[tostring(o.class)] or 0) + 1
			end
		end
		R.decor_digest, R.decor_alive = digest(decor_list)
		R.decor_ring_objects_measured = decor_ring
		local cl = {}
		for c, n in pairs(decor_classes) do cl[#cl + 1] = c .. ":" .. n end
		table.sort(cl)
		R.decor_class_census = table.concat(cl, ",")

		------------------------------------------------------------------ sector grid
		local city = map.City
		local Grid = SBM and SBM.SectorGrid
		local sectors, revealed = {}, {}
		local sector_count = 0
		local function sector_at(x, y)
			for i = 1, #sectors do
				local s = sectors[i]
				if x >= s.x0 and x < s.x1 and y >= s.y0 and y < s.y1 then return s end
			end
			return nil
		end
		if Grid and city then
			Grid.ForEachSector(city, function(sector, col, row)
				sector_count = sector_count + 1
				local a = sector.area
				local mn, mx = a:min(), a:max()
				local x0, y0 = mn:xy()
				local x1, y1 = mx:xy()
				local rec = { id = tostring(sector.id), col = col, row = row, status = tostring(sector.status),
					x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
				sectors[#sectors + 1] = rec
				if rec.status ~= "unexplored" then
					revealed[#revealed + 1] = rec.id .. "(" .. col .. "," .. row .. "):" .. rec.status
				end
			end)
		end
		R.sector_count = sector_count
		R.revealed_count = #revealed
		R.revealed_list = table.concat(revealed, " ")

		------------------------------------------------------------------ gate 5: start sector
		local sfx0, sfy0 = map.SuperBigMapStartFootprintX0, map.SuperBigMapStartFootprintY0
		local sfx1, sfy1 = map.SuperBigMapStartFootprintX1, map.SuperBigMapStartFootprintY1
		if type(sfx0) == "number" and type(sfx1) == "number" then
			local cx, cy = (sfx0 + sfx1) / 2, (sfy0 + sfy1) / 2
			R.start_center = tostring(cx) .. "," .. tostring(cy)
			local s = sector_at(cx, cy)
			R.start_sector = s and (s.id .. "(" .. s.col .. "," .. s.row .. "):" .. s.status) or "not_found"
		else
			R.start_center = "unavailable"
			R.start_sector = "unavailable"
		end

		------------------------------------------------------------------ gates 2/3: entrances
		local pairs_out = {}
		local n_surface_passages = 0
		pcall(map.MapForEach, map, "map", "UndergroundPassage", function(o)
			n_surface_passages = n_surface_passages + 1
			local x, y = posxy(o)
			local s = sector_at(x, y)
			local other = rawget(o, "other")
			local orec = "none"
			if other and IsValid(other) then
				local ox, oy = posxy(other)
				orec = tostring(other.class) .. "@" .. hexof(map, ox, oy) .. " map=" .. tostring(other:GetMap())
			end
			pairs_out[#pairs_out + 1] = string.format("surf %s hex=%s world=%d,%d sector=%s ring=%s other=%s",
				tostring(o.class), hexof(map, x, y), x, y,
				s and (s.id .. "(" .. s.col .. "," .. s.row .. ")") or "?",
				tostring(in_ring(x, y)), orec)
		end)
		R.surface_passages = n_surface_passages
		R.passage_records = table.concat(pairs_out, " | ")

		------------------------------------------------------------------ gate 6: signs and deposits
		local signs = {}
		local n_signs = 0
		pcall(map.MapForEach, map, "map", "SurfaceUndergroundTunnelSign", function(o)
			n_signs = n_signs + 1
			local x, y = posxy(o)
			local s = sector_at(x, y)
			local oks, scale = pcall(o.GetScale, o)
			signs[#signs + 1] = string.format("%s hex=%s vis=%s scale=%s sector=%s/%s",
				tostring(o.class), hexof(map, x, y), tostring(visible(o)),
				oks and tostring(scale) or "?",
				s and s.id or "?", s and s.status or "?")
		end)
		R.sign_count = n_signs
		R.sign_records = table.concat(signs, " | ")
		R.sign_overview_scale_const = tostring(const and const.SignsOverviewCameraScaleUp)

		local dep_hidden_unexplored, dep_visible_unexplored, dep_hidden_scanned, dep_visible_scanned, dep_total = 0, 0, 0, 0, 0
		pcall(map.MapForEach, map, "map", "TerrainDeposit", function(o)
			dep_total = dep_total + 1
			local x, y = posxy(o)
			local s = sector_at(x, y)
			local v = visible(o)
			local unexplored = (not s) or s.status == "unexplored"
			if unexplored then
				if v == true then dep_visible_unexplored = dep_visible_unexplored + 1
				else dep_hidden_unexplored = dep_hidden_unexplored + 1 end
			else
				if v == true then dep_visible_scanned = dep_visible_scanned + 1
				else dep_hidden_scanned = dep_hidden_scanned + 1 end
			end
		end)
		R.terrain_deposits = dep_total
		R.deposits_visible_in_unexplored = dep_visible_unexplored
		R.deposits_hidden_in_unexplored = dep_hidden_unexplored
		R.deposits_visible_in_scanned = dep_visible_scanned
		R.deposits_hidden_in_scanned = dep_hidden_scanned

		------------------------------------------------------------------ gate 4: ring content
		local orr = map.SuperBigMapOuterResourceTerrainReport
		if type(orr) == "table" then
			for _, k in ipairs({ "reason", "resources", "rocket_pads", "resource_clusters", "ring_sectors",
				"patches", "modified_cells", "error" }) do
				R["ring_" .. k] = tostring(orr[k])
			end
		else
			R.ring_reason = "no outer resource report on map"
		end
		local apron = map.SuperBigMapNaturalMountainBaseApronReport
		if type(apron) == "table" then
			local ap = {}
			for k, v in pairs(apron) do
				if type(v) ~= "table" then ap[#ap + 1] = tostring(k) .. "=" .. tostring(v) end
			end
			table.sort(ap)
			R.apron_report = table.concat(ap, " ")
		else
			R.apron_report = "none"
		end
		local cfg = SBM and SBM.Config
		R.full_map_playable = tostring(type(cfg) == "table" and cfg.FULL_MAP_PLAYABLE)

		------------------------------------------------------------------ underground presence
		local ug
		for i = 1, #(Maps or {}) do
			local m = Maps[i]
			if m and m.mapdata and m.mapdata.Environment == "Underground" then ug = m end
		end
		R.underground_loaded = ug and true or false
		if ug then
			R.underground_name = tostring(ug.name)
			R.underground_hex = tostring(ug.hex_width) .. "x" .. tostring(ug.hex_height)
			local ugen = GetRandomMapGenerator and GetRandomMapGenerator(ug)
			R.underground_seed = tostring(ugen and ugen.Seed)
			R.underground_prepared = tostring(ug.SuperBigMapUndergroundPrepared)
		end

		rawset(_G, "RULES", R)
		RULES_LINE = string.format(
			"t0t1=%s hex=%sx%s enrich=%s/%s decor=%s/%s ring_decor=%s sectors=%s revealed=%s passages=%s signs=%s deps=%s vis_unexp=%s",
			tostring(R.t0_to_t1_ms), tostring(R.hex_width), tostring(R.hex_height),
			tostring(R.enrichment_digest), tostring(R.enrichment_count),
			tostring(R.decor_digest), tostring(R.decor_alive), tostring(R.decor_ring_objects_measured),
			tostring(R.sector_count), tostring(R.revealed_count), tostring(R.surface_passages),
			tostring(R.sign_count), tostring(R.terrain_deposits), tostring(R.deposits_visible_in_unexplored))
		printf("[RULES] %s", RULES_LINE)
		printf("[RULES] passages: %s", tostring(R.passage_records))
		printf("[RULES] signs: %s", tostring(R.sign_records))
		printf("[RULES] revealed: %s start=%s", tostring(R.revealed_list), tostring(R.start_sector))
		RULES_STATUS = "complete"
	end, function(e) return tostring(e) .. "\n" .. debug.traceback() end)
	if not ok then
		rawset(_G, "RULES_ERR", tostring(err))
		RULES_STATUS = "error"
		printf("[RULES] FAILED %s", tostring(err))
	end
end)
return "rules_probe_started"

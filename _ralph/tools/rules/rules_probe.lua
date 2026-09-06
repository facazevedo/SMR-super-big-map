-- Rules-parity baseline probe (surface side).
--
-- Runs the task contract's cold bootstrap at 14N134W (RoughTerrain, EXPAND MAP), stamps T0 at the
-- START press, waits for T1, then reads every surface-side gate's evidence BEFORE any player action.
-- Results land in the global RULES (LuaToJSON-marshalable scalars/arrays only) and are echoed to the
-- log as [RULES] lines.  RULES_STATUS carries coarse progress so a poller can follow the run.
--
-- Gate coverage in this file: seed-parity digests (1), entrance records (2), entrance sector
-- position (3), ring census (4), start reveal (5), sign/deposit visibility (6), decor stats (7).
-- no-errors (8) is judged from the log.
--
-- A second phase then performs underground-first-access (10) the way the player does: the vanilla
-- construction controller places an Elevator snapped to a surface passage, the paired two-map
-- construction group is quick-built, and the vanilla map switch runs.  No mod preparation function
-- is called directly.  The underground halves of gates 1, 2, 3 and 6 are read afterwards in the
-- same cold session.  The surface half is published to RULES before that phase starts, so a
-- first-access failure still leaves the surface evidence readable.

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

		local function hexqr(x, y)
			local q, r = WorldToHex(point(x, y))
			return q, r
		end

		local function hexof(map, x, y)
			local q, r = hexqr(x, y)
			return tostring(q) .. "," .. tostring(r)
		end

		-- Cube distance between two axial hexes: the number of rings an outward hex-ring walk needs
		-- to reach one from the other, i.e. the contract's "ring distance" for gate 2.
		local function hexdist(q1, r1, q2, r2)
			if type(q1) ~= "number" or type(r1) ~= "number"
				or type(q2) ~= "number" or type(r2) ~= "number" then
				return -1
			end
			local dq, dr = q1 - q2, r1 - r2
			local a, b, c = dq < 0 and -dq or dq, dr < 0 and -dr or dr, dq + dr
			if c < 0 then c = -c end
			return math.max(a, math.max(b, c))
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

		-- rawget: the debug build reports reading an undefined global in a mod env as a LUA ERROR,
		-- and every foreign mod env would raise one here, polluting the no-errors gate's log scan.
		local SBM
		for i = 1, #(ModsLoaded or {}) do
			local env = ModsLoaded[i] and ModsLoaded[i].env
			local candidate = type(env) == "table" and rawget(env, "SuperBigMap")
			if type(candidate) == "table" then SBM = candidate end
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
		-- The stretch ratio the map was built with, so the probe can compute the stretched image of an
		-- underground position itself instead of trusting a stamped field. Integer division would
		-- collapse 8192/6144 to 1 in this engine's Lua, hence the + 0.0 promotion.
		local function tiles_ratio(desired_field, source_field)
			local desired = tonumber(map[desired_field])
			local source = tonumber(map[source_field])
			if desired and source and source > 0 and desired > source then
				return (desired + 0.0) / source
			end
			return nil
		end
		local ratio = tiles_ratio("SuperBigMapDesiredWidthTiles", "SuperBigMapGeneratorWidthTiles")
			or tiles_ratio("SuperBigMapDesiredWidthTiles", "SuperBigMapSourceWidthTiles")
		R.stretch_ratio_source = ratio and "surface tile metadata" or "fallback 4/3"
		ratio = ratio or (4.0 / 3.0)
		R.stretch_ratio = tostring(ratio)

		local function stamped(o, field)
			local v = rawget(o, "SuperBigMapPassage" .. field)
			if v == nil then v = rawget(o, "SuperBigMap" .. field) end
			return tonumber(v)
		end

		local pairs_out = {}
		local n_surface_passages, glued_pairs, unglued_pairs = 0, 0, 0
		local max_ring_distance = 0
		pcall(map.MapForEach, map, "map", "UndergroundPassage", function(o)
			n_surface_passages = n_surface_passages + 1
			local x, y = posxy(o)
			local q, r = hexqr(x, y)
			local s = sector_at(x, y)

			-- The live twin on the underground map. Before first access that map still presents its
			-- authored (un-stretched) content, so this position is the authored SurfacePassageMarker's.
			local other = rawget(o, "other")
			local orec, twin_q, twin_r, img_q, img_r = "none", nil, nil, nil, nil
			if other and IsValid(other) then
				local ox, oy = posxy(other)
				twin_q, twin_r = hexqr(ox, oy)
				local ix, iy = math.floor(ox * ratio + 0.5), math.floor(oy * ratio + 0.5)
				img_q, img_r = hexqr(ix, iy)
				orec = string.format("%s hex=%s world=%d,%d image_hex=%s,%s",
					tostring(other.class), tostring(twin_q) .. "," .. tostring(twin_r), ox, oy,
					tostring(img_q), tostring(img_r))
			end

			-- The mod's own commitment record, for the contract's per-pair table.
			local rec_src_q = stamped(o, "CommittedPassageSourceQ")
			local rec_src_r = stamped(o, "CommittedPassageSourceR")
			local rec_true_q = stamped(o, "TrueUndergroundPassageQ")
			local rec_true_r = stamped(o, "TrueUndergroundPassageR")
			local rec_com_q = stamped(o, "CommittedPassageQ")
			local rec_com_r = stamped(o, "CommittedPassageR")
			local rec_van_q = stamped(o, "SurfaceSourceQ")
			local rec_van_r = stamped(o, "SurfaceSourceR")

			-- Gate 2's ring distance: how far the surface endpoint sits from the stretched image of
			-- its underground twin. Measured against the probe's own image first; the stamped
			-- TrueUnderground* fields are reported beside it so a disagreement is visible.
			local ring_distance = hexdist(q, r, img_q, img_r)
			local stamped_distance = hexdist(q, r, rec_true_q, rec_true_r)
			if ring_distance == 0 then glued_pairs = glued_pairs + 1
			else unglued_pairs = unglued_pairs + 1 end
			if ring_distance > max_ring_distance then max_ring_distance = ring_distance end

			pairs_out[#pairs_out + 1] = string.format(
				"surf %s hex=%s,%s world=%d,%d sector=%s ring_band=%s ring_distance=%s "
				.. "stamped_distance=%s vanilla_surface_src=%s,%s underground_src=%s,%s "
				.. "stamped_image=%s,%s committed=%s,%s twin=[%s]",
				tostring(o.class), tostring(q), tostring(r), x, y,
				s and (s.id .. "(" .. s.col .. "," .. s.row .. ")") or "?",
				tostring(in_ring(x, y)), tostring(ring_distance), tostring(stamped_distance),
				tostring(rec_van_q), tostring(rec_van_r), tostring(rec_src_q), tostring(rec_src_r),
				tostring(rec_true_q), tostring(rec_true_r), tostring(rec_com_q), tostring(rec_com_r),
				orec)
		end)
		R.surface_passages = n_surface_passages
		R.passage_records = table.concat(pairs_out, " | ")
		R.pairs_glued = glued_pairs
		R.pairs_unglued = unglued_pairs
		R.max_ring_distance = max_ring_distance

		-- Gate 2 requires the validity REASON behind every nonzero ring distance. The mod keeps it in
		-- SuperBigMapPassageGlueReport on the surface map (durable, not gated on a log channel), so read
		-- it straight from there instead of scraping [SuperBigMap] audit lines.
		local glue = map.SuperBigMapPassageGlueReport
		R.glue_report_present = type(glue) == "table"
		if type(glue) == "table" then
			R.glue_records = #glue
			for gi = 1, #glue do
				local g = glue[gi]
				local prefix = "glue" .. gi .. "_"
				for _, k in ipairs({ "pair", "algorithm", "ring_distance", "glued",
					"twin_image_q", "twin_image_r", "twin_image_x", "twin_image_y",
					"twin_preimage_q", "twin_preimage_r", "twin_image_surface_reason",
					"twin_image_underground_valid", "twin_image_underground_reason",
					"surface_q", "surface_r", "surface_x", "surface_y", "surface_angle",
					"vanilla_surface_q", "vanilla_surface_r",
					"vanilla_surface_image_q", "vanilla_surface_image_r",
					"drift_wu", "candidates_checked", "candidates_rejected",
					"twin_image_footprint", "committed_footprint" }) do
					R[prefix .. k] = tostring(g[k])
				end
			end
		else
			R.glue_records = 0
		end

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
		local ug_pre_image_hexes, ug_pre_images = {}, {}
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
			local ug_recs, ug_n = {}, 0
			pcall(ug.MapForEach, ug, "map", "SurfacePassage", function(o)
				ug_n = ug_n + 1
				local x, y = posxy(o)
				local q, r = hexqr(x, y)
				local ix, iy = math.floor(x * ratio + 0.5), math.floor(y * ratio + 0.5)
				local iq, ir = hexqr(ix, iy)
				-- Recorded before first access, while the underground is still authored content:
				-- these are the stretched images the expanded endpoints must land on.
				ug_pre_image_hexes[#ug_pre_image_hexes + 1] = { q = iq, r = ir }
				ug_pre_images[#ug_pre_images + 1] = tostring(iq) .. "," .. tostring(ir)
				ug_recs[#ug_recs + 1] = string.format(
					"%s hex=%s,%s world=%d,%d image_hex=%s,%s committed_src=%s,%s true_image=%s,%s linked=%s",
					tostring(o.class), tostring(q), tostring(r), x, y, tostring(iq), tostring(ir),
					tostring(stamped(o, "CommittedPassageSourceQ")),
					tostring(stamped(o, "CommittedPassageSourceR")),
					tostring(stamped(o, "TrueUndergroundPassageQ")),
					tostring(stamped(o, "TrueUndergroundPassageR")),
					tostring(rawget(o, "other") ~= nil))
			end)
			R.underground_passages = ug_n
			R.underground_passage_records = table.concat(ug_recs, " | ")
			R.underground_pre_images = table.concat(ug_pre_images, " ")
		end

		------------------------------------------------------------------ gate 10: first access
		-- Publish the surface half BEFORE the player-route first access, so a phase-2 failure still
		-- leaves every surface gate's evidence readable in the report.
		rawset(_G, "RULES", R)
		RULES_STATUS = "surface_complete"
		printf("[RULES] surface half complete; starting first access")

		local function first_access()
			if not ug then return "underground map is not loaded" end
			if CurrentMap ~= map then return "current map is not the generated surface map" end

			-- The underground still carries its authored, un-stretched content here, so the
			-- pre-switch passage positions ARE the authored SurfacePassageMarker positions.
			R.ug_pre_hex = tostring(ug.hex_width) .. "x" .. tostring(ug.hex_height)

			-- Game time must advance for the paired construction group to build and for the placed
			-- buildings' GameInit to link the two halves; a player unpauses for the same reason.
			local is_paused = rawget(_G, "IsPaused")
			R.ug_paused_before = tostring(type(is_paused) == "function" and is_paused())
			local reasons, cleared = rawget(_G, "PauseReasons"), {}
			if type(reasons) == "table" and type(Resume) == "function" then
				local keys = {}
				for k in pairs(reasons) do keys[#keys + 1] = k end
				for _, k in ipairs(keys) do
					if pcall(Resume, k) then cleared[#cleared + 1] = tostring(k) end
				end
			end
			R.ug_pause_reasons_cleared = table.concat(cleared, ",")
			R.ug_paused_after_resume = tostring(type(is_paused) == "function" and is_paused())

			-- Count every loading display raised between the Elevator placement and the completed
			-- switch: vanilla's screen through the global, the mod's cover through its own entry.
			local opens = {}
			local original_open = rawget(_G, "LoadingScreenOpen")
			if type(original_open) == "function" then
				rawset(_G, "LoadingScreenOpen", function(id, reason, ...)
					opens[#opens + 1] = tostring(id) .. "/" .. tostring(reason)
					return original_open(id, reason, ...)
				end)
			end
			local covers = 0
			local original_cover = SBM and rawget(SBM, "ExpansionLoadingBegin")
			if SBM and type(original_cover) == "function" then
				SBM.ExpansionLoadingBegin = function(...)
					covers = covers + 1
					return original_cover(...)
				end
			end
			local function restore_counters()
				if type(original_open) == "function" then
					rawset(_G, "LoadingScreenOpen", original_open)
				end
				if SBM and type(original_cover) == "function" then
					SBM.ExpansionLoadingBegin = original_cover
				end
				R.ug_loading_screen_opens = #opens
				R.ug_loading_screen_ids = table.concat(opens, " ")
				R.ug_expansion_covers = covers
				R.ug_loading_displays = #opens + covers
			end

			------------------------------------------------------------ place the Elevator
			local target_passage
			pcall(map.MapForEach, map, "map", "UndergroundPassage", function(o)
				if not target_passage and IsValid(o) and rawget(o, "other") then target_passage = o end
			end)
			if not target_passage then
				restore_counters()
				return "no linked surface UndergroundPassage to snap an Elevator to"
			end
			local tpx, tpy = posxy(target_passage)
			R.ug_elevator_passage_hex = hexof(map, tpx, tpy)

			local unlock = rawget(_G, "UnlockBuilding")
			if type(unlock) == "function" then pcall(unlock, "Elevator") end
			local get_ctrl = rawget(_G, "GetDefaultConstructionController")
			local ctrl = type(get_ctrl) == "function" and get_ctrl(map.City) or nil
			if not ctrl then
				restore_counters()
				return "the vanilla construction controller is unavailable"
			end
			local template = BuildingTemplates and BuildingTemplates.Elevator
			local params = { pos = target_passage:GetPos(), angle = target_passage:GetAngle() }
			if template and type(template.AddPlacementParams) == "function" then
				params = template.AddPlacementParams(params) or params
			end
			local act_ok, act_err = pcall(ctrl.Activate, ctrl, "Elevator", params)
			if not act_ok then
				restore_counters()
				return "construction mode did not activate: " .. tostring(act_err)
			end
			R.ug_elevator_snap_target = tostring(ctrl.snap_target and ctrl.snap_target.class or "none")
			R.ug_elevator_snapped_to_passage = tostring(ctrl.snap_target == target_passage)
			local statuses = {}
			for _, st in ipairs(ctrl.construction_statuses or {}) do
				statuses[#statuses + 1] = tostring(type(st) == "table" and st.type or st)
			end
			R.ug_elevator_construction_statuses = table.concat(statuses, ",")

			-- The player's own path: the construction cursor, snapped to the passage, placed.
			local place_ok, placed = pcall(ctrl.Place, ctrl)
			R.ug_access_method = "ConstructionController:Place snapped to the surface passage"
			if not place_ok or not placed then
				-- The headless session has no drone hub, so a blocking construction status can veto
				-- the cursor path. Fall back to the same controller's external placement, which
				-- still routes through ElevatorBase:PlaceConstructionSite and the recorded snap.
				local ext_ok, ext = pcall(ctrl.Place, ctrl, "Elevator",
					target_passage:GetPos(), target_passage:GetAngle(), nil)
				R.ug_access_method = "ConstructionController:Place external fallback (snap retained)"
				R.ug_cursor_place_error = tostring(place_ok and "refused by construction status" or placed)
				if not ext_ok or not ext then
					pcall(ctrl.Deactivate, ctrl)
					restore_counters()
					return "Elevator placement failed: " .. tostring(ext)
				end
			end
			pcall(ctrl.Deactivate, ctrl)

			local site = rawget(target_passage, "elevator_construction")
			if not (site and IsValid(site)) then
				restore_counters()
				return "the passage recorded no Elevator construction site after placement"
			end
			local group = rawget(site, "construction_group")
			local leader = type(group) == "table" and group[1] or nil
			R.ug_elevator_group_size = type(group) == "table" and #group or -1
			if not (leader and IsValid(leader) and type(leader.Complete) == "function") then
				restore_counters()
				return "the paired Elevator construction group has no completable leader"
			end

			------------------------------------------------------------ quick-build the pair
			local build_done, build_err = false, nil
			local function do_build()
				local ok_c, ce = pcall(leader.Complete, leader, "quick_build")
				if not ok_c then build_err = tostring(ce) end
				build_done = true
			end
			local game_thread = rawget(_G, "CreateGameTimeThread")
			if type(game_thread) == "function" then game_thread(do_build) else do_build() end
			local bdl = GetPreciseTicks() + 180000
			while not build_done and GetPreciseTicks() < bdl do Sleep(100) end
			R.ug_elevator_built = tostring(build_done)
			R.ug_elevator_build_error = tostring(build_err)
			if not build_done then
				restore_counters()
				return "the paired Elevator quick-build never ran (game time did not advance)"
			end
			if build_err then
				restore_counters()
				return "the paired Elevator quick-build failed: " .. build_err
			end

			local twin_passage = rawget(target_passage, "other")
			local ldl = GetPreciseTicks() + 120000
			local first_elevator, second_elevator
			while GetPreciseTicks() < ldl do
				first_elevator = IsValid(target_passage) and rawget(target_passage, "elevator") or nil
				second_elevator = twin_passage and IsValid(twin_passage)
					and rawget(twin_passage, "elevator") or nil
				if first_elevator and second_elevator then break end
				Sleep(100)
			end
			R.ug_elevator_linked = tostring(IsValid(first_elevator) and IsValid(second_elevator)
				and rawget(first_elevator, "other") == second_elevator)

			------------------------------------------------------------ switch maps
			local change = rawget(_G, "ChangeCurrentMapSlot")
			if type(change) ~= "function" then
				restore_counters()
				return "ChangeCurrentMapSlot is unavailable"
			end
			local switch_t0 = GetPreciseTicks()
			local sw_ok, sw_err = pcall(change, ug.slot, true)
			R.ug_switch_ok = tostring(sw_ok)
			R.ug_switch_error = tostring(sw_ok and "none" or sw_err)
			local sdl = GetPreciseTicks() + 900000
			while GetPreciseTicks() < sdl do
				if CurrentMap == ug and ug.SuperBigMapUndergroundStretchDone == true then break end
				Sleep(200)
			end
			R.ug_switch_ms = GetPreciseTicks() - switch_t0
			R.ug_current_is_underground = tostring(CurrentMap == ug)
			R.ug_stretch_done = tostring(ug.SuperBigMapUndergroundStretchDone)
			R.ug_prepared_after = tostring(ug.SuperBigMapUndergroundPrepared)
			R.ug_stretch_failed = tostring(ug.SuperBigMapUndergroundStretchFailed)
			restore_counters()
			if CurrentMap ~= ug or ug.SuperBigMapUndergroundStretchDone ~= true then
				return "first access did not produce a prepared underground within 900 s"
			end

			------------------------------------------------------------ underground-side reads
			R.ug_post_hex = tostring(ug.hex_width) .. "x" .. tostring(ug.hex_height)
			local uw, uh = terrain.GetMapSize(ug)
			R.ug_world = tostring(uw) .. "x" .. tostring(uh)
			local ubx0, ubx1, uby0, uby1 = uw / 10, uw - uw / 10, uh / 10, uh - uh / 10
			local function ug_in_ring(x, y)
				return x < ubx0 or x >= ubx1 or y < uby0 or y >= uby1
			end

			-- Gate 1 underground side: same reserved seed must give the same marker set.
			local ug_enrich = {}
			for _, cls in ipairs({ "DepositMarker", "SubsurfaceAnomalyMarker", "EffectDepositMarker" }) do
				pcall(ug.MapForEach, ug, "map", cls, function(o)
					local x, y = posxy(o)
					ug_enrich[#ug_enrich + 1] = tostring(o.class) .. "@" .. hexof(ug, x, y)
				end)
			end
			R.ug_enrichment_digest, R.ug_enrichment_count = digest(ug_enrich)

			-- Underground reveal state, and the sector grid the passage records are labelled with.
			local ug_sectors, ug_revealed, ug_sector_count = {}, {}, 0
			if Grid and ug.City then
				Grid.ForEachSector(ug.City, function(sector, col, row)
					ug_sector_count = ug_sector_count + 1
					local a = sector.area
					local mn, mx = a:min(), a:max()
					local x0, y0 = mn:xy()
					local x1, y1 = mx:xy()
					ug_sectors[#ug_sectors + 1] = { id = tostring(sector.id), col = col, row = row,
						status = tostring(sector.status), x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
					if tostring(sector.status) ~= "unexplored" then
						ug_revealed[#ug_revealed + 1] = tostring(sector.id) .. "(" .. col .. ","
							.. row .. "):" .. tostring(sector.status)
					end
				end)
			end
			R.ug_sector_count = ug_sector_count
			R.ug_revealed_count = #ug_revealed
			R.ug_revealed_list = table.concat(ug_revealed, " ")
			local function ug_sector_at(x, y)
				for i = 1, #ug_sectors do
					local s = ug_sectors[i]
					if x >= s.x0 and x < s.x1 and y >= s.y0 and y < s.y1 then return s end
				end
				return nil
			end

			-- Gates 2/3 underground side. After the stretch both maps share one hex space, so the
			-- glue distance is the plain hex distance between the two endpoints, and the authored
			-- position is checked against the pre-switch image recorded above.
			local post = {}
			pcall(ug.MapForEach, ug, "map", "SurfacePassage", function(o)
				local x, y = posxy(o)
				local q, r = hexqr(x, y)
				local twin = rawget(o, "other")
				local tq, tr, tvalid = nil, nil, false
				if twin and IsValid(twin) then
					local txx, tyy = posxy(twin)
					tq, tr = hexqr(txx, tyy)
					tvalid = true
				end
				local best = -1
				for _, img in ipairs(ug_pre_image_hexes) do
					local d = hexdist(q, r, img.q, img.r)
					if best < 0 or (d >= 0 and d < best) then best = d end
				end
				local s = ug_sector_at(x, y)
				post[#post + 1] = string.format(
					"%s hex=%s,%s world=%d,%d authored_image_ring=%s twin=%s,%s glue_ring=%s "
					.. "linked=%s ring_band=%s sector=%s",
					tostring(o.class), tostring(q), tostring(r), x, y, tostring(best),
					tostring(tq), tostring(tr), tostring(tvalid and hexdist(q, r, tq, tr) or -1),
					tostring(tvalid), tostring(ug_in_ring(x, y)),
					s and (s.id .. "(" .. s.col .. "," .. s.row .. ")") or "?")
			end)
			R.ug_post_passages = #post
			R.ug_post_passage_records = table.concat(post, " | ")

			-- Gate 6 underground side: the vanilla passage imprint decal, at vanilla scale.
			local imprints = {}
			pcall(ug.MapForEach, ug, "map", "ElevatorBuildIndicator_UndergroundPassageImprint",
				function(o)
					local x, y = posxy(o)
					local ok_s, sc = pcall(o.GetScale, o)
					imprints[#imprints + 1] = string.format("hex=%s vis=%s scale=%s",
						hexof(ug, x, y), tostring(visible(o)), ok_s and tostring(sc) or "?")
				end)
			R.ug_imprints = #imprints
			R.ug_imprint_records = table.concat(imprints, " | ")

			-- Gate 7 underground side is gated off by configuration on this line; record the switch
			-- rather than pretending a census proves anything.
			R.ug_decor_engine_pass_enabled = tostring(type(cfg) == "table"
				and cfg.STRETCH_DECOR_ENGINE_PASS_UNDERGROUND)
			return nil
		end

		RULES_STATUS = "first_access"
		local fa_ok, fa_result = pcall(first_access)
		R.ug_first_access_error = fa_ok and tostring(fa_result or "none") or tostring(fa_result)
		R.ug_first_access_ok = tostring(fa_ok and fa_result == nil)

		rawset(_G, "RULES", R)
		RULES_LINE = string.format(
			"t0t1=%s hex=%sx%s enrich=%s/%s decor=%s/%s ring_decor=%s sectors=%s revealed=%s passages=%s signs=%s deps=%s vis_unexp=%s glued=%s/%s max_ring=%s",
			tostring(R.t0_to_t1_ms), tostring(R.hex_width), tostring(R.hex_height),
			tostring(R.enrichment_digest), tostring(R.enrichment_count),
			tostring(R.decor_digest), tostring(R.decor_alive), tostring(R.decor_ring_objects_measured),
			tostring(R.sector_count), tostring(R.revealed_count), tostring(R.surface_passages),
			tostring(R.sign_count), tostring(R.terrain_deposits), tostring(R.deposits_visible_in_unexplored),
			tostring(R.pairs_glued), tostring(R.surface_passages), tostring(R.max_ring_distance))
		printf("[RULES] %s", RULES_LINE)
		printf("[RULES] passages: %s", tostring(R.passage_records))
		for gi = 1, (R.glue_records or 0) do
			printf("[RULES] glue %d: ring=%s algorithm=%s anchor_reason=%s rejected=%s",
				gi, tostring(R["glue" .. gi .. "_ring_distance"]),
				tostring(R["glue" .. gi .. "_algorithm"]),
				tostring(R["glue" .. gi .. "_twin_image_surface_reason"]),
				tostring(R["glue" .. gi .. "_candidates_rejected"]))
		end
		printf("[RULES] underground passages: %s", tostring(R.underground_passage_records))
		printf("[RULES] signs: %s", tostring(R.sign_records))
		printf("[RULES] revealed: %s start=%s", tostring(R.revealed_list), tostring(R.start_sector))
		printf("[RULES] first access: ok=%s error=%s method=%s displays=%s hex %s -> %s",
			tostring(R.ug_first_access_ok), tostring(R.ug_first_access_error),
			tostring(R.ug_access_method), tostring(R.ug_loading_displays),
			tostring(R.ug_pre_hex), tostring(R.ug_post_hex))
		printf("[RULES] underground after access: passages: %s", tostring(R.ug_post_passage_records))
		printf("[RULES] underground after access: enrich=%s/%s imprints=%s (%s) revealed=%s/%s",
			tostring(R.ug_enrichment_digest), tostring(R.ug_enrichment_count),
			tostring(R.ug_imprints), tostring(R.ug_imprint_records),
			tostring(R.ug_revealed_count), tostring(R.ug_sector_count))
		RULES_STATUS = "complete"
	end, function(e) return tostring(e) .. "\n" .. debug.traceback() end)
	if not ok then
		rawset(_G, "RULES_ERR", tostring(err))
		RULES_STATUS = "error"
		printf("[RULES] FAILED %s", tostring(err))
	end
end)
return "rules_probe_started"

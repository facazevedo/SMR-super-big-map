-- Rules-parity baseline probe (surface side).
--
-- Runs the task contract's cold bootstrap at 14N134W (RoughTerrain, EXPAND MAP), stamps T0 at the
-- START press, waits for T1, then reads every surface-side gate's evidence BEFORE any player action.
-- Results land in the global RULES (LuaToJSON-marshalable scalars/arrays only) and are echoed to the
-- log as [RULES] lines.  RULES_STATUS carries coarse progress so a poller can follow the run.
--
-- Gate coverage in this file: seed-parity digests (1), entrance records (2), entrance sector
-- position (3), ring census (4), start reveal (5), sign/deposit visibility (6), decor stats (7).
-- no-errors (8) is judged from the log.  Gate 6's after-scan half runs once the surface half is
-- published: the sector holding a TerrainDeposit is scanned through vanilla's own completion call
-- and the identical census is re-read (`scan_test_*`).
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
		-- Seed-parity pair (gate 1, underground half): vanilla's own `GameSeed` is drawn per game
		-- (`NewGame` gives an empty `seed_text` a `random_encode64(48)` value, CommonLua/Game.lua:23,
		-- and `InitGameSeed` hashes it, CommonLua/Random.lua:22-30), and the deferred wonder
		-- anomaly's spawn start comes from `table.shuffle` on that stream
		-- (`BottomlessPitBase:GetSpawnStartPos`).  Rule 1 forbids seeding a vanilla draw, so the pair
		-- pins the game seed the way the new-game UI does: a fixed `seed_text` passed to `NewGame`,
		-- which `GameClass:new` stores BEFORE `Msg("NewGame")` initialises the `GameSeed` GameVar.
		-- Empty means "do not pin" and leaves vanilla's random seed text in place.
		local pin_game_seed_text = "__GAME_SEED_TEXT__"
		DoneGame()
		if pin_game_seed_text ~= "" then
			NewGame({ seed_text = pin_game_seed_text })
		else
			NewGame()
		end
		InitNewGameMissionParams()
		LoadLastNewGameSettings("regular", { RoughTerrain = true })
		ChangeMap("PreGame")
		local params = g_CurrentMapParams
		params.map = ""
		GetOverlayValues(__LAT__, __LON__)
		params.rocket_name, params.rocket_name_base = GenerateRocketName(true)

		-- Gate 6's underground half is judged against vanilla's own behaviour at this site, so the
		-- driver can run this same probe with EXPAND MAP off (`--expand-map off`).  `false`
		-- reproduces the landing screen's OFF path exactly: the params flag is left nil
		-- (sbm_pregame_toggle.lua:44), the START action's disarm runs, and its vanilla branch
		-- (`Lifecycle.BeginVanillaSession`, sbm_pregame_toggle.lua:483) uninstalls every mod patch
		-- before the generation that follows.  Nothing else in the probe changes shape.
		local expand_map = __EXPAND_MAP__
		params.SuperBigMapExpandMap = expand_map and true or nil
		local control_vanilla_session = "not_requested"
		if not expand_map then
			control_vanilla_session = "mod_not_found"
			for i = 1, #(ModsLoaded or {}) do
				local env = ModsLoaded[i] and ModsLoaded[i].env
				local candidate = type(env) == "table" and rawget(env, "SuperBigMap")
				local tog = type(candidate) == "table" and rawget(candidate, "PregameToggle") or nil
				local lc = type(candidate) == "table" and rawget(candidate, "Lifecycle") or nil
				if type(tog) == "table" and type(tog.SetStartArmed) == "function" then
					pcall(tog.SetStartArmed, false, "rules probe control run")
				end
				if type(lc) == "table" and type(lc.BeginVanillaSession) == "function" then
					local vs_ok = pcall(lc.BeginVanillaSession,
						"rules probe control: START without EXPAND MAP", false)
					-- Lua's `cond and x or y` cannot carry a false result, so read IsActive
					-- explicitly: "active=false" is the verdict this control run needs.
					local active = "?"
					if type(lc.IsActive) == "function" then
						local a_ok, a = pcall(lc.IsActive)
						if a_ok then active = tostring(a) end
					end
					control_vanilla_session = vs_ok
						and ("vanilla_session active=" .. active) or "refused"
				end
			end
		end
		local surface_seed = params.Seed

		-- Seed-parity pair (gate 1, underground half): vanilla itself draws the underground
		-- generator seed with AsyncRand, so two cold runs of one site never share an underground
		-- unless that one reservation is pinned.  MapGeneration.SetTwinUndergroundSeedForTest
		-- (sbm_map_generation.lua:13568) substitutes the value at the same consumer transaction
		-- while still consuming the production draw.  0 means "do not pin".
		local pin_ug_seed = __UG_SEED__
		local pin_ug_result = "not_requested"
		if pin_ug_seed ~= 0 then
			pin_ug_result = "mod_not_found"
			for i = 1, #(ModsLoaded or {}) do
				local env = ModsLoaded[i] and ModsLoaded[i].env
				local candidate = type(env) == "table" and rawget(env, "SuperBigMap")
				local mg = type(candidate) == "table" and rawget(candidate, "MapGeneration") or nil
				if type(mg) == "table" and type(mg.SetTwinUndergroundSeedForTest) == "function" then
					local pin_ok, pin_err = mg.SetTwinUndergroundSeedForTest(
						pin_ug_seed, "ralph_seed_parity")
					pin_ug_result = pin_ok and "pinned" or ("refused:" .. tostring(pin_err))
				end
			end
		end

		------------------------------------------------------- gate 8: reachability audit capture
		-- Gate 8's arrival red (iter 001) is a caught [LUA ERROR] raised by the underground
		-- enrichment reachability audit; the audit's own `invalid_details`/`unresolved_details`
		-- reach only the LoadingTiming channel, which the payload keeps disabled, so the log shows
		-- the count and nothing about the cause.  Wrap the audit here -- probe side only, no mod
		-- change, no RNG draw, capture and forward only -- so every call's scalar stats reach the
		-- report.  The sink lives in _G rather than a local: this chunk is one long function and
		-- top-level local slots are scarce.
		rawset(_G, "RULES_REACH", {})
		rawset(_G, "RULES_REACH_HOOK", "mod_not_found")
		for i = 1, #(ModsLoaded or {}) do
			local env = ModsLoaded[i] and ModsLoaded[i].env
			local candidate = type(env) == "table" and rawget(env, "SuperBigMap")
			local dep = type(candidate) == "table" and rawget(candidate, "DepositRules") or nil
			local original = type(dep) == "table"
				and rawget(dep, "RelocateUnreachableUndergroundEnrichments") or nil
			if type(original) == "function" then
				dep.RelocateUnreachableUndergroundEnrichments = function(...)
					local audit_ok, stats = original(...)
					local parts = { "ok=" .. tostring(audit_ok) }
					if type(stats) == "table" then
						for k, v in pairs(stats) do
							if type(v) ~= "table" and type(v) ~= "function" then
								parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
							end
						end
					else
						parts[#parts + 1] = "stats_type=" .. type(stats)
					end
					table.sort(parts)
					local sink = rawget(_G, "RULES_REACH")
					sink[#sink + 1] = "call" .. tostring(#sink + 1)
						.. "{" .. table.concat(parts, " ") .. "}"
					return audit_ok, stats
				end
				rawset(_G, "RULES_REACH_HOOK", "installed")
			end
		end

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
		local control_settle_ms = 0
		if expand_map then
			while GetPreciseTicks() < deadline do
				map = scan()
				if map then t1 = GetPreciseTicks() break end
				Sleep(100)
			end
			if not map then error("T1 never reached within 900 s") end
		else
			-- The control run never sets the mod's stretch flags, so its "generation complete"
			-- boundary is vanilla's own: GenerateCurrentRandomMap has returned and the city's
			-- sector grid exists.  A fixed settle follows so city-init spawns are on the map
			-- before it is read; it is reported, not hidden, so the read point is on record.
			while GetPreciseTicks() < deadline do
				local m = CurrentMap
				local city = m and m.City
				local grid = city and city.MapSectors
				if type(grid) == "table" and #grid > 0 then map = m break end
				Sleep(100)
			end
			if not map then
				error("the control run's city sector grid never appeared within 900 s")
			end
			control_settle_ms = 5000
			Sleep(control_settle_ms)
			t1 = GetPreciseTicks()
		end

		RULES_STATUS = "reading"
		local R = {}
		-- Exact temporal discriminator for the surface pass-grid instability seen only
		-- in post-first-access captures.  Keep each serialized blob in this probe's
		-- local scope so later stages can prove byte equality, while publishing only
		-- dimensions/size/hash/equality into RULES.  All reads happen after T1, so
		-- diagnostic serialization cost cannot contaminate START-to-T1 timing.
		local surface_pass_stage_blobs = {}
		local surface_pass_previous_stage = nil
		local function capture_surface_pass_stage(stage)
			if type(stage) ~= "string" or stage == "" then
				error("surface pass stage name is required")
			end
			if type(terrain.GetPassGridsCount) ~= "function"
				or type(terrain.GetPassGrid) ~= "function"
				or type(GridWriteStr) ~= "function" or type(xxhash) ~= "function" then
				error("surface pass serialization APIs are unavailable at " .. stage)
			end
			local count = tonumber(terrain.GetPassGridsCount(map))
			if not count or count < 1 or count > 8 then
				error("invalid surface pass-grid count at " .. stage .. ": " .. tostring(count))
			end
			local blobs, summary = {}, {}
			local t1_blobs = surface_pass_stage_blobs.t1
			local previous_blobs = surface_pass_previous_stage
				and surface_pass_stage_blobs[surface_pass_previous_stage] or nil
			R["surface_pass_" .. stage .. "_count"] = count
			R["surface_pass_" .. stage .. "_previous_stage"] =
				surface_pass_previous_stage or "none"
			for index = 0, count - 1 do
				local grid = terrain.GetPassGrid(map, index)
				if not grid or not IsGrid(grid) then
					error(string.format("surface pass grid %d unavailable at %s", index, stage))
				end
				local blob, write_error = GridWriteStr(grid)
				if write_error or type(blob) ~= "string" then
					error(string.format("surface GridWriteStr grid %d failed at %s: %s",
						index, stage, tostring(write_error)))
				end
				local repeat_blob, repeat_error = GridWriteStr(grid)
				if repeat_error or type(repeat_blob) ~= "string" then
					error(string.format("surface repeated GridWriteStr grid %d failed at %s: %s",
						index, stage, tostring(repeat_error)))
				end
				local width, height = grid:size()
				local prefix = "surface_pass_" .. stage .. "_" .. tostring(index)
				local hash = tostring(xxhash(blob))
				R[prefix .. "_w"] = width
				R[prefix .. "_h"] = height or width
				R[prefix .. "_bytes"] = #blob
				R[prefix .. "_hash"] = hash
				R[prefix .. "_repeat_equal"] = tostring(blob == repeat_blob)
				R[prefix .. "_matches_t1"] = t1_blobs and tostring(blob == t1_blobs[index]) or "self"
				R[prefix .. "_matches_previous"] = previous_blobs
					and tostring(blob == previous_blobs[index]) or "self"
				blobs[index] = blob
				summary[#summary + 1] = string.format("%d:%s/%d/t1=%s/prev=%s", index, hash, #blob,
					t1_blobs and tostring(blob == t1_blobs[index]) or "self",
					previous_blobs and tostring(blob == previous_blobs[index]) or "self")
			end
			surface_pass_stage_blobs[stage] = blobs
			surface_pass_previous_stage = stage
			R["surface_pass_" .. stage .. "_summary"] = table.concat(summary, " ")
		end
		capture_surface_pass_stage("t1")
		R.site = "__SITE__"
		R.map_name = tostring(map.name)
		R.hex_width = map.hex_width
		R.hex_height = map.hex_height
		R.surface_seed = tostring(surface_seed)
		R.pin_ug_seed = tostring(pin_ug_seed)
		R.pin_ug_result = pin_ug_result
		-- Which run this is: the expanded subject or vanilla's unexpanded control.
		R.expand_map = tostring(expand_map)
		R.control_vanilla_session = control_vanilla_session
		R.control_settle_ms = control_settle_ms
		-- The game-seed pin's own proof: the text asked for, the text the game kept, and the two
		-- GameVars derived from it. `GameSeed` must equal `xxhash(seed_text)` for a pinned run and
		-- must be identical across the pinned pair.
		R.pin_game_seed_text = pin_game_seed_text ~= "" and pin_game_seed_text or "not_requested"
		R.game_seed_text = tostring(rawget(_G, "Game") and Game.seed_text)
		R.game_seed = tostring(rawget(_G, "GameSeed"))
		R.interaction_seed = tostring(rawget(_G, "InteractionSeed"))
		R.game_seed_matches_pin = tostring(pin_game_seed_text == ""
			or (rawget(_G, "Game") and Game.seed_text == pin_game_seed_text) == true)
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
		local SBM, SBM_env
		for i = 1, #(ModsLoaded or {}) do
			local env = ModsLoaded[i] and ModsLoaded[i].env
			local candidate = type(env) == "table" and rawget(env, "SuperBigMap")
			if type(candidate) == "table" then SBM, SBM_env = candidate, env end
		end
		R.mod_found = SBM and true or false

		------------------------------------------------- gate 10: first-access gate at T1
		-- Timestamp the gate's installation state BEFORE any probe action, so a missing wrapper
		-- at first access can be told apart from one that was never installed, one that was
		-- installed and later removed, and one whose rawset landed in the mod env instead of the
		-- global table the engine calls.
		local sbm_state_t1 = SBM and rawget(SBM, "State")
		local wrapper_t1 = type(sbm_state_t1) == "table"
			and rawget(sbm_state_t1, "change_current_map_slot_wrapper") or nil
		local global_ccms = rawget(_G, "ChangeCurrentMapSlot")
		R.gate_wrapper_type = tostring(type(wrapper_t1))
		R.gate_installed = tostring(wrapper_t1 ~= nil and global_ccms == wrapper_t1)
		R.gate_patch_version = tostring(type(sbm_state_t1) == "table"
			and rawget(sbm_state_t1, "underground_access_patch_version"))
		-- If the mod's rawset(_G, ...) wrote into its own environment, the key exists there and the
		-- engine's global still holds vanilla's function.
		R.gate_env_own_ccms = tostring(type(SBM_env) == "table"
			and rawget(SBM_env, "ChangeCurrentMapSlot") ~= nil)
		R.gate_env_ccms_is_wrapper = tostring(type(SBM_env) == "table" and wrapper_t1 ~= nil
			and rawget(SBM_env, "ChangeCurrentMapSlot") == wrapper_t1)
		-- Indexed, not rawget: the env's own `_G` key may be absent and resolve through its
		-- metatable. pcall because a mod env may install a strict-global __index.
		local ok_env_g, env_g = pcall(function()
			return type(SBM_env) == "table" and SBM_env._G or nil
		end)
		R.gate_env_g_is_real = tostring(ok_env_g and env_g == _G)
		-- Which table do vanilla's own callers resolve globals in? The captured original switch is
		-- the representative sample: if its environment holds the mod wrapper, every vanilla caller
		-- reaches the gate and only this chunk's `_G` is a stale copy; if it holds vanilla's
		-- function, the mod's rawset lands where the engine never looks.
		local function fn_env(fn)
			if type(fn) ~= "function" then return nil end
			local getfenv_fn = rawget(_G, "getfenv")
			if type(getfenv_fn) == "function" then
				local ok, env = pcall(getfenv_fn, fn)
				if ok and type(env) == "table" then return env end
			end
			local dbg = rawget(_G, "debug")
			if type(dbg) == "table" and type(dbg.getfenv) == "function" then
				local ok, env = pcall(dbg.getfenv, fn)
				if ok and type(env) == "table" then return env end
			end
			if type(dbg) == "table" and type(dbg.getupvalue) == "function" then
				for i = 1, 64 do
					local ok, name, value = pcall(dbg.getupvalue, fn, i)
					if not ok or name == nil then break end
					if name == "_ENV" and type(value) == "table" then return value end
				end
			end
			return nil
		end
		local original_t1 = type(sbm_state_t1) == "table"
			and rawget(sbm_state_t1, "original_change_current_map_slot") or nil
		R.gate_original_type = tostring(type(original_t1))
		R.gate_original_is_probe_global = tostring(original_t1 ~= nil and original_t1 == global_ccms)
		local venv = fn_env(original_t1)
		R.gate_vanilla_env_found = tostring(venv ~= nil)
		R.gate_vanilla_env_is_probe_g = tostring(venv ~= nil and venv == _G)
		R.gate_vanilla_env_is_mod_env = tostring(venv ~= nil and venv == SBM_env)
		R.gate_vanilla_env_ccms_type = tostring(venv ~= nil
			and type(rawget(venv, "ChangeCurrentMapSlot")) or "no-env")
		R.gate_vanilla_env_ccms_is_wrapper = tostring(venv ~= nil and wrapper_t1 ~= nil
			and rawget(venv, "ChangeCurrentMapSlot") == wrapper_t1)
		R.gate_vanilla_env_ccms_is_original = tostring(venv ~= nil and original_t1 ~= nil
			and rawget(venv, "ChangeCurrentMapSlot") == original_t1)
		-- Second sample: a vanilla caller of the switch, in case the switch itself was defined in an
		-- environment its callers do not share.
		local caller_env = fn_env(rawget(_G, "ChangeMap"))
		R.gate_caller_env_found = tostring(caller_env ~= nil)
		R.gate_caller_env_is_probe_g = tostring(caller_env ~= nil and caller_env == _G)
		R.gate_caller_env_ccms_is_wrapper = tostring(caller_env ~= nil and wrapper_t1 ~= nil
			and rawget(caller_env, "ChangeCurrentMapSlot") == wrapper_t1)
		local lifecycle = SBM and rawget(SBM, "Lifecycle")
		R.gate_lifecycle_active = tostring(type(lifecycle) == "table"
			and type(lifecycle.IsActive) == "function" and lifecycle.IsActive())
		local sbm_cfg = SBM and rawget(SBM, "Config") or {}
		R.gate_cfg_step01 = tostring(sbm_cfg.EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE)
		R.gate_cfg_step02 = tostring(sbm_cfg.EXPANSION_STEP_02_STRETCH_AND_TRANSFORM_VANILLA_SOURCE)
		-- The gate's install/reuse/removal trace was temporary instrumentation, removed from the mod
		-- at v920 once gate 10 was proven by the player route; the wrapper facts above are the
		-- evidence that the gate is installed and is the function the switch calls.

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
		-- The mod's seed-derived placement stream (sbm_deposits.lua SeedDeterministicPlacement):
		-- seed plus per-phase draw counts, so a digest match is attributable to the stream.
		local function stream_report(m)
			local rep = type(m) == "table" and rawget(m, "SuperBigMapPlacementSeedReport") or nil
			if type(rep) ~= "table" then return "absent", "absent" end
			local phases = {}
			for _, entry in ipairs(rep) do
				phases[#phases + 1] = tostring(entry.tag) .. ":" .. tostring(entry.calls)
			end
			return tostring(rep.seed), table.concat(phases, ",")
		end
		R.placement_seed, R.placement_phases = stream_report(map)
		-- rawset: a plain assignment creates a new global, which this debug build reports as a
		-- [LUA ERROR] and would pollute gate 8's log scan.
		rawset(_G, "STREAM_REPORT", stream_report)

		------------------------------------------------------------------ gate 7: decor
		-- v918 publishes the pass's record on the map it ran on, because the same pass now runs on
		-- both maps in one session and a single LastStats slot cannot represent two maps.  One
		-- reader serves both halves: the per-map record plus an independent census (digest, outer
		-- band count, class histogram) taken from the surviving objects themselves.
		local function decor_report(m, prefix, band_test)
			local st = type(m) == "table" and rawget(m, "SuperBigMapDecorEnginePassReport") or nil
			if type(st) ~= "table" then
				st = SBM and SBM.DecorTopUp and SBM.DecorTopUp.LastStats or {}
				R[prefix .. "record_source"] = "module_lastfields"
			else
				R[prefix .. "record_source"] = "map_record"
			end
			for _, k in ipairs({ "enabled", "reason", "error", "environment", "target", "placed",
				"objects", "ring_objects", "dropped_non_cosmetic", "dropped_out_of_band",
				"skipped_band", "skipped_bounds", "placed_authored", "placed_synthetic",
				"decor_sites", "vanilla_decor_groups", "unused_sites", "synthetic_templates",
				"synthetic_attempts", "seed", "seed_source", "generator_present", "preset",
				"decoration_passes", "decoration_ratio", "area_factor", "ms" }) do
				R[prefix .. k] = tostring(st[k])
			end
			-- v920: the placed-object list moved off the map field into the module's weak-keyed
			-- per-map registry, so ask the module for THIS map's list.
			local top = SBM and SBM.DecorTopUp or nil
			local objs = (top and type(top.PassObjects) == "function") and top.PassObjects(m) or nil
			R[prefix .. "objects_source"] = objs and "module_registry" or "none"
			if type(objs) ~= "table" then
				-- Only fall back to the module slot when the RECORD came from there too. A map that
				-- has its own record and no object list placed nothing (the pass returns before it
				-- creates the list), and borrowing the other map's list made iter 007 run 1 report
				-- the surface digest and 1292 objects as the underground's.
				if R[prefix .. "record_source"] == "module_lastfields" then
					objs = top and top.LastObjects or {}
					R[prefix .. "objects_source"] = "module_lastobjects"
				else
					objs = {}
				end
			end
			local list, ring, classes = {}, 0, {}
			for _, o in ipairs(objs) do
				if IsValid(o) then
					local x, y = posxy(o)
					list[#list + 1] = tostring(o.class) .. "@" .. hexof(m, x, y)
					if band_test(x, y) then ring = ring + 1 end
					classes[tostring(o.class)] = (classes[tostring(o.class)] or 0) + 1
				end
			end
			R[prefix .. "digest"], R[prefix .. "alive"] = digest(list)
			R[prefix .. "ring_objects_measured"] = ring
			local cl = {}
			for c, n in pairs(classes) do cl[#cl + 1] = c .. ":" .. n end
			table.sort(cl)
			R[prefix .. "class_census"] = table.concat(cl, ",")
			-- Everything else the pass recorded, verbatim.  The named list above was chosen for the
			-- gate table; the pass also counts WHICH predicate refused each candidate
			-- (skipped_by_obstruct / skipped_by_decorated, synthetic_rejected_*), how many spacing
			-- circles it rebuilt, and whether the synthetic budget or the template pool ran out --
			-- the only evidence that can tell a site-acceptance defect from an attempt budget too
			-- small for this site.  Published generically so a stat added later needs no probe change.
			local named, extra = {}, {}
			for _, k in ipairs({ "enabled", "reason", "error", "environment", "target", "placed",
				"objects", "ring_objects", "dropped_non_cosmetic", "dropped_out_of_band",
				"skipped_band", "skipped_bounds", "placed_authored", "placed_synthetic",
				"decor_sites", "vanilla_decor_groups", "unused_sites", "synthetic_templates",
				"synthetic_attempts", "seed", "seed_source", "generator_present", "preset",
				"decoration_passes", "decoration_ratio", "area_factor", "ms" }) do
				named[k] = true
			end
			for k, v in pairs(st) do
				if not named[k] and type(v) ~= "table" and type(v) ~= "function" then
					extra[#extra + 1] = tostring(k) .. "=" .. tostring(v)
				end
			end
			table.sort(extra)
			R[prefix .. "extra"] = table.concat(extra, ",")
			-- Site geometry, read from the markers themselves.  The spacing rule is vanilla's -- a
			-- candidate is refused when any stamp circle intersects the SITE's radius -- so how big
			-- the authored zones are next to the gaps between them decides how much room the top-up
			-- can find at all.  15S67E authors 578 sites where 14N134W authors 203; this says
			-- whether they are simply smaller and packed tighter here.
			local pts, radii, nn = {}, {}, {}
			pcall(m.MapForEach, m, "map", "PrefabDecorMarker", function(mk)
				local mx, my = posxy(mk)
				if type(mx) ~= "number" then return end
				pts[#pts + 1] = { x = mx, y = my, r = tonumber(mk.DecorRadius) or 0 }
			end)
			for i = 1, #pts do
				radii[#radii + 1] = pts[i].r
				local best = -1
				for j = 1, #pts do
					if j ~= i then
						local dx, dy = pts[i].x - pts[j].x, pts[i].y - pts[j].y
						local d2 = dx * dx + dy * dy
						if best < 0 or d2 < best then best = d2 end
					end
				end
				nn[#nn + 1] = best >= 0 and math.floor(math.sqrt(best)) or -1
			end
			local function pctile(list, p)
				if #list == 0 then return -1 end
				table.sort(list)
				local i = math.floor(#list * p / 100) + 1
				if i > #list then i = #list end
				return list[i]
			end
			R[prefix .. "site_census_count"] = #pts
			R[prefix .. "site_radius_p10"] = pctile(radii, 10)
			R[prefix .. "site_radius_p50"] = pctile(radii, 50)
			R[prefix .. "site_radius_p90"] = pctile(radii, 90)
			R[prefix .. "site_nn_dist_p10"] = pctile(nn, 10)
			R[prefix .. "site_nn_dist_p50"] = pctile(nn, 50)
		end
		decor_report(map, "decor_", in_ring)
		-- rawset for the same reason as STREAM_REPORT: the underground half runs inside a later
		-- closure and a plain global assignment is a [LUA ERROR] in this debug build.
		rawset(_G, "DECOR_REPORT", decor_report)

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
				-- `obj` is the live MapSector: gate 6's after-scan half completes a scan on it and
				-- re-reads a status that this snapshot has by then made stale.
				local rec = { id = tostring(sector.id), col = col, row = row, status = tostring(sector.status),
					obj = sector, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
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
		if not expand_map then
			-- Control run: nothing is stretched, so a twin's "image" is its own position and the
			-- expanded run's 4/3 fallback would fabricate a distance that cannot exist here.
			ratio = 1.0
			R.stretch_ratio_source = "control: EXPAND MAP off, no stretch"
		else
			R.stretch_ratio_source = ratio and "surface tile metadata" or "fallback 4/3"
			ratio = ratio or (4.0 / 3.0)
		end
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
		-- One census, read twice: gate 6 is judged before AND after a programmatic sector scan, and
		-- the two readings only compare if identical code produced them. `prefix` is "" for the
		-- pre-scan reading (the field names every earlier report already carries) and "scan_test_"
		-- for the re-read. Sector status comes from the LIVE MapSector, not from the snapshot the
		-- grid sweep recorded, because the scan changes it.
		local function gate6_census(prefix)
			local function live_at(x, y)
				local s = sector_at(x, y)
				if not s then return nil, nil end
				return s, tostring((s.obj and s.obj.status) or s.status)
			end
			local recs, n = {}, 0
			pcall(map.MapForEach, map, "map", "SurfaceUndergroundTunnelSign", function(o)
				n = n + 1
				local x, y = posxy(o)
				local s, st = live_at(x, y)
				local oks, scale = pcall(o.GetScale, o)
				recs[#recs + 1] = string.format("%s hex=%s vis=%s scale=%s sector=%s/%s",
					tostring(o.class), hexof(map, x, y), tostring(visible(o)),
					oks and tostring(scale) or "?",
					s and s.id or "?", tostring(st))
			end)
			R[prefix .. "sign_count"] = n
			R[prefix .. "sign_records"] = table.concat(recs, " | ")

			-- TerrainDeposit (concrete/regolith): hidden while its sector is unexplored, visible once
			-- it is scanned. Each record carries the mod's own gate flag and vanilla's `revealed`
			-- field, so a hidden badge can be attributed instead of guessed.
			local hid_u, vis_u, hid_s, vis_s = 0, 0, 0, 0
			recs, n = {}, 0
			pcall(map.MapForEach, map, "map", "TerrainDeposit", function(o)
				n = n + 1
				local x, y = posxy(o)
				local s, st = live_at(x, y)
				local v = visible(o)
				if st == nil or st == "unexplored" then
					if v == true then vis_u = vis_u + 1 else hid_u = hid_u + 1 end
				else
					if v == true then vis_s = vis_s + 1 else hid_s = hid_s + 1 end
				end
				recs[#recs + 1] = string.format("%s hex=%s vis=%s sector=%s/%s revealed=%s gate=%s",
					tostring(o.class), hexof(map, x, y), tostring(v),
					s and s.id or "?", tostring(st), tostring(rawget(o, "revealed")),
					tostring(rawget(o, "SuperBigMapOverviewHiddenUntilScan")))
			end)
			R[prefix .. "terrain_deposits"] = n
			R[prefix .. "deposits_visible_in_unexplored"] = vis_u
			R[prefix .. "deposits_hidden_in_unexplored"] = hid_u
			R[prefix .. "deposits_visible_in_scanned"] = vis_s
			R[prefix .. "deposits_hidden_in_scanned"] = hid_s
			R[prefix .. "deposit_records"] = table.concat(recs, " | ")

			-- "no other badge or deposit visual is shown in an unexplored sector": the mod's overview
			-- scan gate covers subsurface deposits and anomalies too, so count their disclosures.
			n, vis_u, vis_s = 0, 0, 0
			for _, cls in ipairs({ "SubsurfaceDeposit", "SubsurfaceAnomaly" }) do
				pcall(map.MapForEach, map, "map", cls, function(o)
					n = n + 1
					if visible(o) == true then
						local x, y = posxy(o)
						local _, st = live_at(x, y)
						if st == nil or st == "unexplored" then vis_u = vis_u + 1
						else vis_s = vis_s + 1 end
					end
				end)
			end
			R[prefix .. "subsurface_badges"] = n
			R[prefix .. "subsurface_visible_in_unexplored"] = vis_u
			R[prefix .. "subsurface_visible_in_scanned"] = vis_s
		end
		gate6_census("")
		R.sign_overview_scale_const = tostring(const and const.SignsOverviewCameraScaleUp)

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
		-- The 8..12 count rule is proven from the plan record (the drawn count and the stream that
		-- produced it) plus the final-terrain audit, not inferred from the placed total alone.
		local ora = map.SuperBigMapOuterResourceTerrainAudit
		if type(ora) == "table" then
			for _, k in ipairs({ "resource_clusters", "rocket_pads", "cluster_minimum",
				"cluster_maximum", "cluster_shortfall", "cluster_excess", "rocket_failures" }) do
				R["ring_audit_" .. k] = tostring(ora[k])
			end
		else
			R.ring_audit_resource_clusters = "no outer resource terrain audit on map"
		end
		local orp = map.SuperBigMapResourceClusterPlanDiagnostic
		if type(orp) == "table" then
			for _, k in ipairs({ "desired_clusters", "placed_clusters", "cluster_minimum",
				"cluster_maximum", "cluster_count_stream", "terrain_candidate_entries",
				"sampling_source_entries", "candidate_attempts", "rejected_candidates", "static_validations",
				"static_cache_reuses", "static_rejections", "dynamic_validations",
				"dynamic_rejections", "accepted_candidates", "placement_dynamic_validations",
				"placement_dynamic_rejections", "placement_accepted", "stage", "error" }) do
				R["ring_plan_" .. k] = tostring(orp[k])
			end
		else
			R.ring_plan_desired_clusters = "no resource cluster plan diagnostic on map"
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

		------------------------------------------------------------------ gate 8: pass-edit window
		-- The intermittent SuspendPassEdits/Resume assert for reason SuperBigMapSurfaceStretch fires
		-- only when GameTime() moved between the suspend and the resume. This record measures both
		-- ends plus every phase boundary inside the window, so the phase that lets the clock move is
		-- read off the map instead of inferred from the log's timestamps.
		local psw = map.SuperBigMapSurfaceStretchPassWindow
		if type(psw) == "table" then
			for _, k in ipairs({ "pause_hold", "pause_released",
				"suspend_active", "suspend_game_time", "resume_source",
				"resume_game_time", "resume_ignore_errors", "game_time_delta", "window_real_ms",
				"assert_expected", "first_advance", "first_advance_game_time",
				"first_advance_pause_reasons", "first_unpaused", "first_unpaused_pause_reasons",
				"trace" }) do
				R["stretch_window_" .. k] = tostring(psw[k])
			end
		else
			R.stretch_window_suspend_active = "no surface stretch pass window on map"
		end

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

		------------------------------------------------------------------ gate 6: after-scan reveal
		-- The contract proves "visible after scan" by scanning one sector programmatically and
		-- re-reading. At 14N134W the site's single TerrainDeposit happened to sit in the start
		-- sector, which generation already scanned, so the census alone showed it; at 15S67E it sits
		-- in an unexplored sector and that half stays unexercised. Complete a scan on the sector
		-- that CONTAINS a TerrainDeposit through vanilla's own completion call --
		-- `MapSector:Scan("scanned")`, the exact call the exploration tick makes when a queued scan
		-- finishes (Lua/Exploration.lua:809) -- then re-run the identical census. The surface half is
		-- already published above, so this player action cannot disturb another gate's reading.
		do
			local is_overview = rawget(_G, "IsOverviewMode")
			R.scan_test_overview = tostring(type(is_overview) == "function" and is_overview())
			local target, dep = nil, nil
			pcall(map.MapForEach, map, "map", "TerrainDeposit", function(o)
				if target or not IsValid(o) then return end
				local x, y = posxy(o)
				local s = sector_at(x, y)
				if s and s.obj and tostring(s.obj.status) == "unexplored" then target, dep = s, o end
			end)
			if not target then
				R.scan_test_result = "no TerrainDeposit in an unexplored sector to scan"
			else
				local dx, dy = posxy(dep)
				R.scan_test_sector = target.id .. "(" .. target.col .. "," .. target.row .. ")"
				R.scan_test_sector_status_before = tostring(target.obj.status)
				R.scan_test_deposit = tostring(dep.class) .. " hex=" .. hexof(map, dx, dy)
				R.scan_test_deposit_visible_before = tostring(visible(dep))
				R.scan_test_deposit_revealed_before = tostring(rawget(dep, "revealed"))
				R.scan_test_deposit_gate_before =
					tostring(rawget(dep, "SuperBigMapOverviewHiddenUntilScan"))
				local ok_can, can = pcall(target.obj.CanBeScanned, target.obj)
				R.scan_test_can_be_scanned = tostring(ok_can and can)
				local ok_scan, scan_err = pcall(target.obj.Scan, target.obj, "scanned")
				R.scan_test_scan_ok = tostring(ok_scan)
				R.scan_test_scan_error = ok_scan and "none" or tostring(scan_err)
				-- Vanilla's reveal path is deferred: MapSector:Scan queues
				-- DelayedCall(0, OnDepositsSpawned), which in overview calls
				-- OverviewModeDialog:ScaleSmallObjects(0, "up") -- the hook the mod's overview scan
				-- gate rides on (sbm_sector_highlight.lua:644-664, itself deferring a second pass by
				-- time+33 ms). Both are real-time threads, so a Sleep is all the settle this needs.
				R.scan_test_settle_ms = 1500
				Sleep(1500)
				R.scan_test_sector_status_after = tostring(target.obj.status)
				R.scan_test_deposit_valid_after = tostring(IsValid(dep))
				R.scan_test_deposit_visible_after = tostring(IsValid(dep) and visible(dep))
				R.scan_test_deposit_revealed_after = tostring(IsValid(dep) and rawget(dep, "revealed"))
				R.scan_test_deposit_gate_after = tostring(IsValid(dep)
					and rawget(dep, "SuperBigMapOverviewHiddenUntilScan"))
				gate6_census("scan_test_")
				local after = {}
				if Grid and city then
					Grid.ForEachSector(city, function(sector, col, row)
						if tostring(sector.status) ~= "unexplored" then
							after[#after + 1] = tostring(sector.id) .. "(" .. col .. ","
								.. row .. "):" .. tostring(sector.status)
						end
					end)
				end
				R.scan_test_revealed_count = #after
				R.scan_test_revealed_list = table.concat(after, " ")
				R.scan_test_result = "scanned"
			end
			printf("[RULES] scan test: %s sector=%s status %s->%s deposit vis %s->%s gate %s->%s",
				tostring(R.scan_test_result), tostring(R.scan_test_sector),
				tostring(R.scan_test_sector_status_before), tostring(R.scan_test_sector_status_after),
				tostring(R.scan_test_deposit_visible_before),
				tostring(R.scan_test_deposit_visible_after),
				tostring(R.scan_test_deposit_gate_before), tostring(R.scan_test_deposit_gate_after))
		end

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
			-- Each open also records when it happened and what the underground's deferred-preparation
			-- state was at that instant, so an unexpected display can be attributed instead of guessed.
			local phase_t0 = GetPreciseTicks()
			local function ug_state_snapshot()
				return string.format("prep=%s done=%s running=%s pending=%s desired=%s gen=%s",
					tostring(ug.SuperBigMapUndergroundPrepared),
					tostring(ug.SuperBigMapUndergroundStretchDone),
					tostring(ug.SuperBigMapUndergroundStretchRunning),
					tostring(ug.SuperBigMapUndergroundStretchPending),
					tostring(ug.SuperBigMapDesiredWidthTiles),
					tostring(ug.SuperBigMapGeneratorWidthTiles))
			end
			local function short_stack()
				local dbg = rawget(_G, "debug")
				if type(dbg) == "table" and type(dbg.traceback) == "function" then
					local ok, s = pcall(dbg.traceback, "", 2)
					if ok and type(s) == "string" then
						s = string.gsub(s, "\r", "")
						s = string.gsub(s, "\n%s*", " <- ")
						return string.sub(s, 1, 400)
					end
				end
				local get_stack = rawget(_G, "GetStack")
				if type(get_stack) == "function" then
					local ok, s = pcall(get_stack, 2, false, 6)
					if ok and type(s) == "string" then
						s = string.gsub(string.gsub(s, "\r", ""), "\n%s*", " <- ")
						return string.sub(s, 1, 400)
					end
				end
				return "no stack source"
			end
			-- The switch window: every vanilla screen opened between the map-switch call and the
			-- prepared underground belongs to first access; anything outside it (an account save,
			-- say) is recorded with its stack but is not a display first access raised.
			local switch_win_t0, switch_win_t1 = nil, nil
			local opens, open_details = {}, {}
			local window_opens, outside_opens = {}, {}
			local original_open = rawget(_G, "LoadingScreenOpen")
			if type(original_open) == "function" then
				rawset(_G, "LoadingScreenOpen", function(id, reason, ...)
					local label = tostring(id) .. "/" .. tostring(reason)
					local in_window = switch_win_t0 ~= nil and switch_win_t1 == nil
					opens[#opens + 1] = label
					if in_window then
						window_opens[#window_opens + 1] = label
					else
						outside_opens[#outside_opens + 1] = label
					end
					open_details[#open_details + 1] = string.format("%s @%dms window=%s %s %s",
						label, GetPreciseTicks() - phase_t0, in_window and "in" or "out",
						ug_state_snapshot(), short_stack())
					return original_open(id, reason, ...)
				end)
			end
			-- The mod reference-counts its expansion cover (sbm_loading_ui.lua:934-1029): Begin raises
			-- the count and only the 0->1 transition creates a box, End releases one reference and only
			-- the final release tears it down. Shadow that arithmetic so the number of DISPLAYS is
			-- measured instead of inferred from the number of Begin calls, and sample the mod's own
			-- ExpansionLoadingVisible around each call as independent corroboration.
			local covers, cover_ends, cover_refs, cover_displays = 0, 0, 0, 0
			local cover_events = {}
			local function cover_visible()
				local vis = SBM and rawget(SBM, "ExpansionLoadingVisible")
				if type(vis) ~= "function" then return "?" end
				local ok_v, v = pcall(vis)
				return ok_v and tostring(v) or "?"
			end
			local original_cover = SBM and rawget(SBM, "ExpansionLoadingBegin")
			if SBM and type(original_cover) == "function" then
				SBM.ExpansionLoadingBegin = function(presentation, ...)
					covers = covers + 1
					local before = cover_refs
					cover_refs = before + 1
					local created = before == 0
					if created then cover_displays = cover_displays + 1 end
					local vis_before = cover_visible()
					local r = original_cover(presentation, ...)
					cover_events[#cover_events + 1] = string.format(
						"BEGIN(%s) refs %d->%d @%dms display=%s vis %s->%s %s",
						tostring(presentation), before, cover_refs,
						GetPreciseTicks() - phase_t0, tostring(created),
						vis_before, cover_visible(), short_stack())
					return r
				end
			end
			local original_cover_end = SBM and rawget(SBM, "ExpansionLoadingEnd")
			if SBM and type(original_cover_end) == "function" then
				SBM.ExpansionLoadingEnd = function(force_all, ...)
					cover_ends = cover_ends + 1
					local before = cover_refs
					if force_all ~= true and cover_refs > 1 then
						cover_refs = cover_refs - 1
					else
						cover_refs = 0
					end
					local closed = cover_refs == 0
					local vis_before = cover_visible()
					local r = original_cover_end(force_all, ...)
					cover_events[#cover_events + 1] = string.format(
						"END(force=%s) refs %d->%d @%dms closed=%s vis %s->%s %s",
						tostring(force_all), before, cover_refs,
						GetPreciseTicks() - phase_t0, tostring(closed),
						vis_before, cover_visible(), short_stack())
					return r
				end
			end
			-- Assigned once the construction controller exists; every early return restores the
			-- vanilla cable-cascade default through restore_counters below.
			local restore_cascade = function() end
			local function restore_counters()
				restore_cascade()
				if type(original_open) == "function" then
					rawset(_G, "LoadingScreenOpen", original_open)
				end
				if SBM and type(original_cover) == "function" then
					SBM.ExpansionLoadingBegin = original_cover
				end
				if SBM and type(original_cover_end) == "function" then
					SBM.ExpansionLoadingEnd = original_cover_end
				end
				R.ug_loading_screen_opens = #opens
				R.ug_loading_screen_ids = table.concat(opens, " ")
				R.ug_loading_screen_detail = table.concat(open_details, " || ")
				R.ug_expansion_covers = covers
				R.ug_expansion_cover_ends = cover_ends
				R.ug_cover_displays = cover_displays
				R.ug_cover_refs_final = cover_refs
				R.ug_cover_events = table.concat(cover_events, " || ")
				R.ug_switch_window_opens = #window_opens
				R.ug_switch_window_open_ids = table.concat(window_opens, " ")
				R.ug_outside_window_opens = #outside_opens
				R.ug_outside_window_open_ids = table.concat(outside_opens, " ")
				-- Gate 10 counts what first access actually put on screen: the reference-counted cover
				-- boxes plus any vanilla loading screen inside the switch window.
				R.ug_loading_displays = cover_displays + #window_opens
				R.ug_loading_displays_raw = #opens + covers
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

			-- The player never reaches ConstructionController:Place without the construction mode
			-- dialog, whose Init sets UICity:SetCableCascadeDeletion(false, "ConstructionModeDialog")
			-- (Lua/Construction/Construction.lua:212) and whose Close restores it (:302). The flag
			-- defaults to true (Lua/DemolishCascading.lua:3), so a headless placement that skips the
			-- dialog trips vanilla's own assert at Construction.lua(2387) and lets the placement
			-- cascade-delete cables. Mirror both halves on every city the assert can read.
			local cascade_cities, seen_city = {}, {}
			for _, c in ipairs({ ctrl.city, rawget(_G, "UICity"), map.City }) do
				if type(c) == "table" and not seen_city[c]
					and type(c.SetCableCascadeDeletion) == "function" then
					seen_city[c] = true
					cascade_cities[#cascade_cities + 1] = c
				end
			end
			local function set_cascade(enabled)
				for _, c in ipairs(cascade_cities) do
					pcall(c.SetCableCascadeDeletion, c, enabled, "ConstructionModeDialog")
				end
			end
			set_cascade(false)
			restore_cascade = function() set_cascade(true) end
			R.ug_cascade_cities = #cascade_cities
			R.ug_cascade_disabled = tostring(cascade_cities[1] ~= nil
				and cascade_cities[1].cascade_cable_deletion_enabled == false)
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
			capture_surface_pass_stage("after_place")
			-- ConstructionModeDialog:Close order: Deactivate the controller, then restore the flag.
			pcall(ctrl.Deactivate, ctrl)
			set_cascade(true)

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
			capture_surface_pass_stage("after_complete")

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
			capture_surface_pass_stage("after_link")

			------------------------------------------------------------ switch maps
			-- The HUD map-switch button's own handler calls
			-- State.change_current_map_slot_wrapper(slot, true, "idChangeCurrentMapSlot")
			-- (sbm_map_generation.lua:13216), which is exactly the global the mod installs. Record
			-- that identity so "the probe bypassed the gate" is a measurement, not an assumption.
			-- Iter 008 proved this chunk's `_G` is not the table the mod wrote: it still holds
			-- vanilla's function, so calling it bypassed the gate. Take the mod's own reference,
			-- which is exactly what the HUD handler calls, and keep the `_G` copy as a recorded
			-- fallback only.
			local sbm_state = SBM and rawget(SBM, "State")
			local state_wrapper = type(sbm_state) == "table"
				and rawget(sbm_state, "change_current_map_slot_wrapper") or nil
			local change, switch_route
			if type(state_wrapper) == "function" then
				change, switch_route = state_wrapper, "state_wrapper"
			else
				change, switch_route = rawget(_G, "ChangeCurrentMapSlot"), "probe_global"
			end
			R.ug_switch_route = switch_route
			if type(change) ~= "function" then
				restore_counters()
				return "ChangeCurrentMapSlot is unavailable"
			end
			R.ug_switch_is_mod_gate = tostring(type(sbm_state) == "table"
				and change == rawget(sbm_state, "change_current_map_slot_wrapper"))
			R.ug_switch_pre_state = ug_state_snapshot()
			-- The same facts as at T1, now at the moment of the switch, so a wrapper that
			-- disappeared between the two timestamps shows up as a type change here.
			R.ug_gate_wrapper_type = tostring(type(sbm_state) == "table"
				and type(rawget(sbm_state, "change_current_map_slot_wrapper")) or "no-state")
			R.ug_gate_patch_version = tostring(type(sbm_state) == "table"
				and rawget(sbm_state, "underground_access_patch_version"))
			local switch_t0 = GetPreciseTicks()
			switch_win_t0 = switch_t0
			-- Same argument list as the HUD's OnPress (sbm_map_generation.lua:13214).
			local sw_ok, sw_err = pcall(change, ug.slot, true, "idChangeCurrentMapSlot")
			R.ug_switch_ok = tostring(sw_ok)
			R.ug_switch_error = tostring(sw_ok and "none" or sw_err)
			local sdl = GetPreciseTicks() + 900000
			while GetPreciseTicks() < sdl do
				-- The control run has no mod preparation to wait for: vanilla's switch is complete
				-- when the underground is the current map.
				if CurrentMap == ug
					and (not expand_map or ug.SuperBigMapUndergroundStretchDone == true) then
					break
				end
				Sleep(200)
			end
			if not expand_map and CurrentMap == ug then
				-- Let vanilla's own CurrentMapChangeDone handlers finish before the imprint and
				-- reveal census that is this run's whole purpose.
				Sleep(control_settle_ms)
			end
			switch_win_t1 = GetPreciseTicks()
			R.ug_switch_ms = switch_win_t1 - switch_t0
			R.ug_current_is_underground = tostring(CurrentMap == ug)
			R.ug_stretch_done = tostring(ug.SuperBigMapUndergroundStretchDone)
			R.ug_prepared_after = tostring(ug.SuperBigMapUndergroundPrepared)
			R.ug_stretch_failed = tostring(ug.SuperBigMapUndergroundStretchFailed)
			local pass_settle_t0 = GetPreciseTicks()
			R.surface_pass_after_switch_elapsed_ms = 0
			capture_surface_pass_stage("after_switch")
			for _, settle in ipairs({
				{ stage = "after_switch_settle_250", delay = 250 },
				{ stage = "after_switch_settle_1000", delay = 1000 },
				{ stage = "after_switch_settle_5000", delay = 5000 },
			}) do
				Sleep(settle.delay)
				R["surface_pass_" .. settle.stage .. "_requested_delay_ms"] = settle.delay
				R["surface_pass_" .. settle.stage .. "_elapsed_ms"] =
					GetPreciseTicks() - pass_settle_t0
				capture_surface_pass_stage(settle.stage)
			end
			restore_counters()
			if CurrentMap ~= ug then
				return "first access did not switch to the underground map within 900 s"
			end
			if expand_map and ug.SuperBigMapUndergroundStretchDone ~= true then
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
			local ug_stream_report = rawget(_G, "STREAM_REPORT")
			if type(ug_stream_report) == "function" then
				R.ug_placement_seed, R.ug_placement_phases = ug_stream_report(ug)
			end
			-- The one input that differed in the iter-011 pinned pair was a verdict inside
			-- EnsureDeferredUndergroundWonderAnomaliesReachable.  sbm_deposits.lua now records each
			-- pass durably on the map (SuperBigMapWonderReachabilityReport): counters, the entrance
			-- seed hexes its connectivity used, and the per-marker judgment including the second
			-- opinion taken through a freshly built validation context.
			local wonder_report = rawget(ug, "SuperBigMapWonderReachabilityReport")
			local wonder_lines = {}
			if type(wonder_report) == "table" then
				for i, entry in ipairs(wonder_report) do
					wonder_lines[#wonder_lines + 1] = "call" .. i
						.. "{repair=" .. tostring(entry.repair)
						.. ",markers=" .. tostring(entry.markers)
						.. ",valid=" .. tostring(entry.valid)
						.. ",invalid=" .. tostring(entry.invalid)
						.. ",moved=" .. tostring(entry.moved)
						.. ",unresolved=" .. tostring(entry.unresolved)
						.. ",disconnected=" .. tostring(entry.entrance_disconnected)
						.. ",draws=" .. tostring(entry.draws)
						.. ",method=" .. tostring(entry.method)
						.. ",entrances=" .. tostring(entry.entrance_seeds)
						.. ",conn_checks=" .. tostring(entry.connectivity_checks)
						.. ",conn_rejected=" .. tostring(entry.connectivity_rejected)
						.. ",conn_failures=" .. tostring(entry.connectivity_failures)
						.. "}details=" .. tostring(entry.details)
				end
			end
			R.ug_wonder_calls = #wonder_lines
			R.ug_wonder_report = #wonder_lines > 0
				and table.concat(wonder_lines, " || ") or "absent"
			-- v912: the pipeline settles the underground grids immediately before the deferred
			-- wonder-anomaly spawn. `dirty=true` means the passability digest moved there, i.e. the
			-- spawn would otherwise have searched a stale grid.
			local settle = rawget(ug, "SuperBigMapWonderSpawnGridSettle")
			R.ug_wonder_grid_settle = type(settle) == "table"
				and ("stage=" .. tostring(settle.stage)
					.. ",branch=" .. tostring(settle.branch)
					.. ",dirty=" .. tostring(settle.dirty)
					.. ",before=" .. tostring(settle.hash_before)
					.. ",after=" .. tostring(settle.hash_after)
					.. ",ms=" .. tostring(settle.rebuild_ms)
					.. ",count=" .. tostring(settle.rebuild_count))
				or "absent"

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

			-- The imprint decal is an auto-attachment of the SurfacePassage carrier, and vanilla's
			-- ElevatorBase:LinkThroughPassage hides the CARRIER (Lua/Buildings/Elevator.lua:603)
			-- while leaving every attachment's own efVisible flag alone. Reading the carrier beside
			-- its decals makes one run tell "vanilla hid the carrier" from "the mod cleared the
			-- decal", instead of inferring it from the decal census alone.
			local carriers = {}
			pcall(ug.MapForEach, ug, "map", "SurfacePassage", function(o)
				local x, y = posxy(o)
				local ok_e, ent = pcall(o.GetEntity, o)
				local ok_o, op = pcall(o.GetOpacity, o)
				local elevator = rawget(o, "elevator")
				local kids = {}
				local ok_a, attaches = pcall(o.GetAttaches, o)
				if ok_a and type(attaches) == "table" then
					for _, a in ipairs(attaches) do
						local ok_ae, aent = pcall(a.GetEntity, a)
						if ok_ae and tostring(aent)
							== "ElevatorBuildIndicator_UndergroundPassageImprint" then
							local ok_as, asc = pcall(a.GetScale, a)
							local ok_ao, aop = pcall(a.GetOpacity, a)
							kids[#kids + 1] = string.format("vis=%s scale=%s opacity=%s",
								tostring(visible(a)), ok_as and tostring(asc) or "?",
								ok_ao and tostring(aop) or "?")
						end
					end
				end
				carriers[#carriers + 1] = string.format(
					"hex=%s entity=%s vis=%s opacity=%s elevator=%s decals=%d{%s}",
					hexof(ug, x, y), ok_e and tostring(ent) or "?", tostring(visible(o)),
					ok_o and tostring(op) or "?",
					tostring(elevator ~= nil and IsValid(elevator) == true),
					#kids, table.concat(kids, ","))
			end)
			R.ug_passage_carriers = #carriers
			R.ug_passage_carrier_records = table.concat(carriers, " | ")

			-- Gate 7 underground side: the pass now runs inside the first-access pipeline, so read
			-- its own per-map record plus an independent census of the objects it left behind.
			R.ug_decor_engine_pass_enabled = tostring(type(cfg) == "table"
				and cfg.STRETCH_DECOR_ENGINE_PASS_UNDERGROUND)
			local decor_reader = rawget(_G, "DECOR_REPORT")
			if type(decor_reader) == "function" then
				decor_reader(ug, "ug_decor_", ug_in_ring)
			end
			-- Vanilla's decor STAGE is what that pass replays, so the site census is the evidence
			-- that decides how large its underground share can be: every PrefabDecorMarker the
			-- underground prefabs authored, and how many vanilla itself consumed (a consumed site
			-- carries the placed prefab's name in DecorTestPrefab).
			local ug_sites, ug_sites_used, ug_site_names = 0, 0, {}
			pcall(ug.MapForEach, ug, "map", "PrefabDecorMarker", function(o)
				ug_sites = ug_sites + 1
				if tostring(rawget(o, "DecorTestPrefab") or "") ~= "" then
					ug_sites_used = ug_sites_used + 1
					if #ug_site_names < 12 then
						ug_site_names[#ug_site_names + 1] = tostring(rawget(o, "DecorTestPrefab"))
					end
				end
			end)
			R.ug_decor_marker_sites = ug_sites
			R.ug_decor_marker_sites_used = ug_sites_used
			R.ug_decor_marker_used_names = table.concat(ug_site_names, ",")
			local ug_gen = GetRandomMapGenerator and GetRandomMapGenerator(ug)
			R.ug_generator_present = tostring(type(ug_gen) == "table")
			R.ug_generator_seed = tostring(type(ug_gen) == "table" and ug_gen.Seed)
			R.ug_generator_preset = tostring(type(ug_gen) == "table" and ug_gen.Id)
			R.ug_generator_decoration_passes = tostring(type(ug_gen) == "table"
				and ug_gen.DecorationPasses)
			R.ug_generator_decoration_ratio = tostring(type(ug_gen) == "table"
				and ug_gen.DecorationRatio)
			R.ug_mapdata_preset = tostring(ug.mapdata and ug.mapdata.RandomMapPreset)
			-- The cosmetic decor population actually present underground, so the thinning claim and
			-- the "cosmetic classes only" clause are both measurable rather than asserted.
			-- One traversal, every prefix checked inline: five class-filtered sweeps over the root
			-- class would walk the whole 8192 population five times.  The filter must be `CObject`,
			-- not `Object`: these decor classes exist only as entity classes
			-- (`Lua/_EntityData.generated.lua`, no DefineClass), so an `Object` sweep sees none of
			-- them and reported 0 in iter 007 run 1 on a map that was never measured.
			local ug_cosmetic, ug_cosmetic_ring, ug_cos_classes = 0, 0, {}
			local ug_cos_ring_records = {}
			local COSMETIC_PREFIXES = { "Cliff", "Dec", "Rocks", "Stones", "Underground_Arch" }
			pcall(ug.MapForEach, ug, "map", "CObject", function(o)
				local name = tostring(o.class or "")
				for i = 1, #COSMETIC_PREFIXES do
					local p = COSMETIC_PREFIXES[i]
					if name:sub(1, #p) == p then
						ug_cosmetic = ug_cosmetic + 1
						local x, y = posxy(o)
						if ug_in_ring(x, y) then
							ug_cosmetic_ring = ug_cosmetic_ring + 1
							-- Name every band object and its provenance instead of reporting a bare
							-- count: SuperBigMapNativeSourceScale is written only by the stretch when
							-- it captures a pre-existing object, so its presence identifies vanilla
							-- prefab-baked decor that the proportional stretch moved (band membership
							-- is a fractional position, which the stretch preserves) rather than a
							-- placement of the decor pass, whose own object list is read separately.
							if #ug_cos_ring_records < 24 then
								ug_cos_ring_records[#ug_cos_ring_records + 1] = name
									.. "@" .. hexof(ug, x, y)
									.. ":native_scale=" .. tostring(rawget(o, "SuperBigMapNativeSourceScale"))
									.. ":scale=" .. tostring(type(o.GetScale) == "function"
										and select(2, pcall(o.GetScale, o)) or "?")
							end
						end
						ug_cos_classes[name] = (ug_cos_classes[name] or 0) + 1
						return
					end
				end
			end)
			R.ug_cosmetic_objects = ug_cosmetic
			R.ug_cosmetic_objects_in_ring = ug_cosmetic_ring
			R.ug_cosmetic_ring_records = #ug_cos_ring_records > 0
				and table.concat(ug_cos_ring_records, " | ") or "none"
			local ug_cc = {}
			for c, n in pairs(ug_cos_classes) do ug_cc[#ug_cc + 1] = c .. ":" .. n end
			table.sort(ug_cc)
			R.ug_cosmetic_class_census = table.concat(ug_cc, ",")
			return nil
		end

		RULES_STATUS = "first_access"
		local fa_ok, fa_result = pcall(first_access)
		R.ug_first_access_error = fa_ok and tostring(fa_result or "none") or tostring(fa_result)
		R.ug_first_access_ok = tostring(fa_ok and fa_result == nil)

		-- Gate 8: whatever the reachability audit measured, even when first access failed.
		R.ug_reach_hook = tostring(rawget(_G, "RULES_REACH_HOOK"))
		R.ug_reach_calls = #rawget(_G, "RULES_REACH")
		R.ug_reach_records = #rawget(_G, "RULES_REACH") > 0
			and table.concat(rawget(_G, "RULES_REACH"), " || ") or "none"

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
		printf("[RULES] seeds: surface=%s pin_ug=%s(%s) pin_game=%s kept=%s game_seed=%s matches=%s",
			tostring(R.surface_seed), tostring(R.pin_ug_seed), tostring(R.pin_ug_result),
			tostring(R.pin_game_seed_text), tostring(R.game_seed_text), tostring(R.game_seed),
			tostring(R.game_seed_matches_pin))
		printf("[RULES] mode: expand_map=%s lifecycle=%s settle=%sms ratio=%s (%s)",
			tostring(R.expand_map), tostring(R.control_vanilla_session),
			tostring(R.control_settle_ms), tostring(R.stretch_ratio),
			tostring(R.stretch_ratio_source))
		printf("[RULES] passages: %s", tostring(R.passage_records))
		for gi = 1, (R.glue_records or 0) do
			printf("[RULES] glue %d: ring=%s algorithm=%s anchor_reason=%s rejected=%s",
				gi, tostring(R["glue" .. gi .. "_ring_distance"]),
				tostring(R["glue" .. gi .. "_algorithm"]),
				tostring(R["glue" .. gi .. "_twin_image_surface_reason"]),
				tostring(R["glue" .. gi .. "_candidates_rejected"]))
		end
		printf("[RULES] surface decor: target=%s placed=%s (auth=%s synth=%s) sites=%s used=%s unused=%s "
			.. "templates=%s attempts=%s ms=%s radius=%s/%s/%s nn=%s/%s",
			tostring(R.decor_target), tostring(R.decor_placed), tostring(R.decor_placed_authored),
			tostring(R.decor_placed_synthetic), tostring(R.decor_decor_sites),
			tostring(R.decor_vanilla_decor_groups), tostring(R.decor_unused_sites),
			tostring(R.decor_synthetic_templates), tostring(R.decor_synthetic_attempts),
			tostring(R.decor_ms), tostring(R.decor_site_radius_p10),
			tostring(R.decor_site_radius_p50), tostring(R.decor_site_radius_p90),
			tostring(R.decor_site_nn_dist_p10), tostring(R.decor_site_nn_dist_p50))
		printf("[RULES] surface decor detail: %s", tostring(R.decor_extra))
		printf("[RULES] underground passages: %s", tostring(R.underground_passage_records))
		printf("[RULES] signs: %s", tostring(R.sign_records))
		printf("[RULES] revealed: %s start=%s", tostring(R.revealed_list), tostring(R.start_sector))
		printf("[RULES] first access: ok=%s error=%s method=%s displays=%s hex %s -> %s",
			tostring(R.ug_first_access_ok), tostring(R.ug_first_access_error),
			tostring(R.ug_access_method), tostring(R.ug_loading_displays),
			tostring(R.ug_pre_hex), tostring(R.ug_post_hex))
		printf("[RULES] first access route: route=%s mod_gate=%s cascade_cities=%s cascade_disabled=%s pre=%s",
			tostring(R.ug_switch_route), tostring(R.ug_switch_is_mod_gate),
			tostring(R.ug_cascade_cities), tostring(R.ug_cascade_disabled),
			tostring(R.ug_switch_pre_state))
		printf("[RULES] gate env: vanilla_env=%s probe_g=%s mod_env=%s ccms=%s is_wrapper=%s is_original=%s caller_wrapper=%s",
			tostring(R.gate_vanilla_env_found), tostring(R.gate_vanilla_env_is_probe_g),
			tostring(R.gate_vanilla_env_is_mod_env), tostring(R.gate_vanilla_env_ccms_type),
			tostring(R.gate_vanilla_env_ccms_is_wrapper),
			tostring(R.gate_vanilla_env_ccms_is_original),
			tostring(R.gate_caller_env_ccms_is_wrapper))
		printf("[RULES] first access displays: cover_boxes=%s begins=%s ends=%s refs_final=%s in_window=%s (%s) outside=%s (%s)",
			tostring(R.ug_cover_displays), tostring(R.ug_expansion_covers),
			tostring(R.ug_expansion_cover_ends), tostring(R.ug_cover_refs_final),
			tostring(R.ug_switch_window_opens), tostring(R.ug_switch_window_open_ids),
			tostring(R.ug_outside_window_opens), tostring(R.ug_outside_window_open_ids))
		printf("[RULES] first access cover events: %s", tostring(R.ug_cover_events))
		printf("[RULES] first access screens: %s", tostring(R.ug_loading_screen_detail))
		printf("[RULES] underground after access: passages: %s", tostring(R.ug_post_passage_records))
		printf("[RULES] underground wonder reachability (%s calls): %s",
			tostring(R.ug_wonder_calls), tostring(R.ug_wonder_report))
		printf("[RULES] underground enrichment reachability audit (hook=%s, %s calls): %s",
			tostring(R.ug_reach_hook), tostring(R.ug_reach_calls),
			tostring(R.ug_reach_records))
		printf("[RULES] underground decor: enabled=%s src=%s reason=%s target=%s placed=%s "
			.. "(auth=%s synth=%s) objects=%s ring=%s/%s dropped=%s/%s sites=%s used=%s "
			.. "gen=%s passes=%s ratio=%s seed=%s(%s) area=%s cosmetic=%s ring_cosmetic=%s",
			tostring(R.ug_decor_engine_pass_enabled), tostring(R.ug_decor_record_source),
			tostring(R.ug_decor_reason), tostring(R.ug_decor_target), tostring(R.ug_decor_placed),
			tostring(R.ug_decor_placed_authored), tostring(R.ug_decor_placed_synthetic),
			tostring(R.ug_decor_objects), tostring(R.ug_decor_ring_objects),
			tostring(R.ug_decor_ring_objects_measured), tostring(R.ug_decor_dropped_non_cosmetic),
			tostring(R.ug_decor_dropped_out_of_band), tostring(R.ug_decor_marker_sites),
			tostring(R.ug_decor_marker_sites_used), tostring(R.ug_generator_present),
			tostring(R.ug_generator_decoration_passes), tostring(R.ug_generator_decoration_ratio),
			tostring(R.ug_decor_seed), tostring(R.ug_decor_seed_source),
			tostring(R.ug_decor_area_factor), tostring(R.ug_cosmetic_objects),
			tostring(R.ug_cosmetic_objects_in_ring))
		printf("[RULES] underground decor classes: %s", tostring(R.ug_decor_class_census))
		printf("[RULES] underground band cosmetics: %s", tostring(R.ug_cosmetic_ring_records))
		printf("[RULES] underground after access: enrich=%s/%s imprints=%s (%s) revealed=%s/%s",
			tostring(R.ug_enrichment_digest), tostring(R.ug_enrichment_count),
			tostring(R.ug_imprints), tostring(R.ug_imprint_records),
			tostring(R.ug_revealed_count), tostring(R.ug_sector_count))
		printf("[RULES] underground passage carriers: %s (%s)",
			tostring(R.ug_passage_carriers), tostring(R.ug_passage_carrier_records))
		RULES_STATUS = "complete"
	end, function(e) return tostring(e) .. "\n" .. debug.traceback() end)
	if not ok then
		rawset(_G, "RULES_ERR", tostring(err))
		RULES_STATUS = "error"
		printf("[RULES] FAILED %s", tostring(err))
	end
end)
return "rules_probe_started"

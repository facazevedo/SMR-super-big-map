-- Super Big Map -- opt-in, observational expansion diagnostics.
--
-- This module has no timers, threads, waits, or gameplay mutations. Its channels are gated by
-- sbm_config.lua and use stable one-line records so the newest Mars log can be parsed mechanically.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine and Engine.Global or function(name) return rawget(_G, name) end
local PREFIX = "[Super Big Map]"
local loading = {
	active = false, session = 0, sequence = 0, started_at = 0, previous_at = 0,
	phase = nil, phase_at = 0, map = nil, totals = {}, print_ms = 0,
}

local function Config()
	return SuperBigMap.Config or {}
end

local function Enabled()
	return Config().DEBUG_LOGGING_ENABLED == true
end

local function Now()
	local fn = Global("GetPreciseTicks") or Global("RealTime")
	if type(fn) == "function" then
		local ok, value = pcall(fn)
		if ok and type(value) == "number" then return value end
	end
	return 0
end

local function MapData(map)
	local data = {}
	if type(map) ~= "table" and type(map) ~= "userdata" then return data end
	local mapdata = map.mapdata
	data.map = tostring(type(mapdata) == "table" and mapdata.id or map.name or "?")
	data.environment = tostring(type(mapdata) == "table" and Engine.MapDataEnvironment(mapdata) or "?")
	data.slot = tostring(map.slot)
	data.map_ref = tostring(map)
	data.mapdata_size = tostring(type(mapdata) == "table" and mapdata.Width or nil)
		.. "x" .. tostring(type(mapdata) == "table" and mapdata.Height or nil)
	data.hex_size = tostring(map.hex_width) .. "x" .. tostring(map.hex_height)
	data.source_tiles = tostring(map.SuperBigMapGeneratorWidthTiles)
		.. "x" .. tostring(map.SuperBigMapGeneratorHeightTiles)
	data.destination_tiles = tostring(map.SuperBigMapDesiredWidthTiles)
		.. "x" .. tostring(map.SuperBigMapDesiredHeightTiles)
	return data
end

local function CopyData(data, map)
	local out = MapData(map)
	if type(data) == "table" then
		for key, value in pairs(data) do out[key] = value end
	end
	return out
end

local function FormatData(data)
	if type(data) ~= "table" then return "" end
	local keys = {}
	for key in pairs(data) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local parts = {}
	for i, key in ipairs(keys) do
		local value = data[key]
		if type(value) == "table" then value = tostring(value) end
		value = tostring(value):gsub("[\r\n]+", " ")
		parts[i] = tostring(key) .. "=" .. value
	end
	return #parts > 0 and " {" .. table.concat(parts, ", ") .. "}" or ""
end

local function Print(channel, event, data)
	local print_fn = Global("print")
	if type(print_fn) ~= "function" then return false end
	local before = Now()
	print_fn(PREFIX .. "[" .. tostring(channel) .. "] " .. tostring(event) .. FormatData(data))
	local after = Now()
	if loading.active and after >= before then loading.print_ms = loading.print_ms + (after - before) end
	return true
end

local Diagnostics = {}

-- Whole-grid digests and full object correspondence exist only to collect
-- validation evidence. Keep this separate from required placement/grid work.
function Diagnostics.GenerationAuditEnabled()
	local c = Config()
	return c.DECORATION_VALIDATION_ENABLED == true or c.NATIVE_SOURCE_MANIFEST == true
		or c.TRACE_UNDERGROUND_ROCK_PARITY == true
		or (Enabled() and (c.DEBUG_LOADING_TIMINGS == true or c.DEBUG_COMPATIBILITY == true
			or c.DEBUG_ENRICHMENT_AUDIT == true))
end

-- Temporary, observational breadcrumbs. No native connectivity queries are made:
-- the failing constructor can leave its internal structure uninitialized.
function Diagnostics.CompatibilityEnabled()
	return Enabled() and Config().DEBUG_COMPATIBILITY == true
end

function Diagnostics.Compatibility(event, data, map)
	if not Diagnostics.CompatibilityEnabled() then return false end
	local out = CopyData(data, map)
	out.ticks = Now()
	return Print("Compatibility", event, out)
end

function Diagnostics.CompatibilityMap(event, map)
	if not Diagnostics.CompatibilityEnabled() then return false end
	local constants = Global("const") or {}
	local md = map and map.mapdata or {}
	local tile, pass_tile = constants.HeightTileSize, constants.PassTileSize
	local patch = constants.ConnectivityPatchSize
	local data = { width_tiles = md.Width, height_tiles = md.Height,
		pass_border = md.PassBorder, height_tile = tile, pass_tile = pass_tile,
		connectivity_patch_cells = patch, lua_revision = Global("LuaRevision") }
	if type(md.Width) == "number" and type(md.Height) == "number"
		and type(tile) == "number" and type(pass_tile) == "number" and pass_tile > 0
		and type(patch) == "number" and patch > 0 then
		local columns = math.ceil(md.Width * tile / pass_tile / patch)
		local rows = math.ceil(md.Height * tile / pass_tile / patch)
		local stride = 1
		while stride < columns do stride = stride * 2 end
		-- Full backing estimate, not a claim about native allocation/pass-border treatment.
		data.full_backing_patch_columns, data.full_backing_patch_rows = columns, rows
		data.full_backing_layer_slots = stride * rows
	end
	return Diagnostics.Compatibility(event, data, map)
end

function Diagnostics.LoadingEnabled()
	return Enabled() and Config().DEBUG_LOADING_TIMINGS == true
end

function Diagnostics.LoadingActive()
	return Diagnostics.LoadingEnabled() and loading.active == true
end

function Diagnostics.EnrichmentEnabled()
	return Enabled() and Config().DEBUG_ENRICHMENT_AUDIT == true
end

function Diagnostics.ElevatorTraversalEnabled()
	return Enabled() and Config().DEBUG_ELEVATOR_TRAVERSAL == true
end

function Diagnostics.ElevatorSupplyEnabled()
	return Enabled() and Config().DEBUG_ELEVATOR_SUPPLY == true
end

function Diagnostics.ElevatorLogisticsEnabled()
	return Enabled() and Config().DEBUG_ELEVATOR_LOGISTICS == true
end

function Diagnostics.ElevatorRocksEnabled()
	return Enabled() and Config().DEBUG_ELEVATOR_ROCKS == true
end

function Diagnostics.ZoomEnabled()
	return Enabled() and Config().DEBUG_ZOOM == true
end

function Diagnostics.OverviewCameraEnabled()
	return Enabled() and Config().DEBUG_OVERVIEW_CAMERA == true
end

function Diagnostics.SectorInteractionEnabled()
	return Enabled() and Config().DEBUG_SECTOR_INTERACTION == true
end

function Diagnostics.OverviewGridEnabled()
	return Enabled() and Config().DEBUG_OVERVIEW_GRID_VISUALS == true
end

function Diagnostics.UndergroundDecorationEnabled()
	return Enabled() and Config().DEBUG_UNDERGROUND_DECORATION_POSITIONS == true
end

function Diagnostics.UndergroundSeedReservationEnabled()
	return Config().TRACE_UNDERGROUND_SEED_RESERVATION == true
end

function Diagnostics.TerrainCreaseRepairEnabled()
	return Config().TRACE_TERRAIN_CREASE_REPAIR == true
end

function Diagnostics.OuterResourceRetryProvenanceEnabled()
	return Config().TRACE_OUTER_RESOURCE_RETRY_PROVENANCE == true
end

function Diagnostics.RockParityEnabled()
	return Config().TRACE_UNDERGROUND_ROCK_PARITY == true
end

function Diagnostics.Audit(event, data, map)
	if not Diagnostics.EnrichmentEnabled() then return false end
	return Print("EnrichmentAudit", event, CopyData(data, map))
end

function Diagnostics.Elevator(event, data, map)
	if not Diagnostics.EnrichmentEnabled() and not Diagnostics.ElevatorSupplyEnabled() then return false end
	return Print("ElevatorSupply", event, CopyData(data, map))
end

function Diagnostics.ElevatorTraversal(event, data, map)
	if not Diagnostics.ElevatorTraversalEnabled() then return false end
	return Print("ElevatorTraversal", event, CopyData(data, map))
end

function Diagnostics.ElevatorLogistics(event, data, map)
	if not Diagnostics.ElevatorLogisticsEnabled() then return false end
	return Print("ElevatorLogistics", event, CopyData(data, map))
end

function Diagnostics.ElevatorRocks(event, data, map)
	if not Diagnostics.ElevatorRocksEnabled() then return false end
	return Print("ElevatorRocks", event, CopyData(data, map))
end

function Diagnostics.Zoom(event, data, map)
	if not Diagnostics.ZoomEnabled() then return false end
	return Print("Zoom", event, CopyData(data, map))
end

function Diagnostics.OverviewCamera(event, data, map)
	if not Diagnostics.OverviewCameraEnabled() then return false end
	return Print("OverviewCamera", event, CopyData(data, map))
end

function Diagnostics.SectorInteraction(event, data, map)
	if not Diagnostics.SectorInteractionEnabled() then return false end
	return Print("SectorInteraction", event, CopyData(data, map))
end

function Diagnostics.OverviewGrid(event, data, map)
	if not Diagnostics.OverviewGridEnabled() then return false end
	return Print("OverviewGrid", event, CopyData(data, map))
end

function Diagnostics.UndergroundDecoration(event, data, map)
	if not Diagnostics.UndergroundDecorationEnabled() then return false end
	return Print("UndergroundDecoration", event, CopyData(data, map))
end

-- Dedicated deterministic-parity trace. This deliberately does not enable or depend on the broad
-- release-debug switch: only the three scalar seed handoff boundaries call it, and it performs no
-- random or generation operation.
function Diagnostics.UndergroundSeedReservation(event, data, map)
	if not Diagnostics.UndergroundSeedReservationEnabled() then return false end
	return Print("UndergroundSeedReservation", event, CopyData(data, map))
end

-- Focused terrain-repair trace. Scalar-only and independent from broad debug logging so failed
-- detections remain visible in an ordinary user log without enabling the noisy diagnostics suite.
function Diagnostics.TerrainCreaseRepair(event, data, map)
	if not Diagnostics.TerrainCreaseRepairEnabled() then return false end
	return Print("TerrainCreaseRepair", event, CopyData(data, map))
end

-- Bounded failed-footprint retry provenance. Keep this separate from the broader terrain-crease
-- stream so a fresh generation can decide whether the retry key missed or patch construction failed.
function Diagnostics.OuterResourceRetryProvenance(event, data, map)
	if not Diagnostics.OuterResourceRetryProvenanceEnabled() then return false end
	return Print("OuterResourceRetryProvenance", event, CopyData(data, map))
end

-- Dedicated deterministic rock-parity trace. Keep this independent from broad debug logging so
-- one process-only flag produces the same stable record schema in vanilla and expanded runs.
function Diagnostics.RockParity(event, data)
	if not Diagnostics.RockParityEnabled() then return false end
	return Print("RockParity", event, data)
end

local function EnsureLoading(reason, map)
	if not Diagnostics.LoadingEnabled() then return false end
	if loading.active then return true end
	local now = Now()
	loading.active = true
	loading.session = loading.session + 1
	loading.sequence = 0
	loading.started_at = now
	loading.previous_at = now
	loading.phase = nil
	loading.phase_at = now
	loading.map = map
	loading.totals = {}
	loading.print_ms = 0
	Print("LoadingTiming", "SESSION_BEGIN", CopyData({
		session = loading.session, reason = tostring(reason or "implicit"),
	}, map))
	return true
end

function Diagnostics.LoadingStart(reason, map, data)
	if not Diagnostics.LoadingEnabled() then return false end
	if loading.active then
		Diagnostics.LoadingStep("session continues: " .. tostring(reason), data, map)
		return true
	end
	EnsureLoading(reason, map)
	if type(data) == "table" then Diagnostics.LoadingStep("session inputs", data, map) end
	return true
end

local function AddTotal(name, duration)
	local item = loading.totals[name]
	if not item then
		item = { calls = 0, total_ms = 0, max_ms = 0 }
		loading.totals[name] = item
	end
	item.calls = item.calls + 1
	item.total_ms = item.total_ms + duration
	if duration > item.max_ms then item.max_ms = duration end
end

function Diagnostics.LoadingStep(name, data, map)
	if not Diagnostics.LoadingEnabled() then return false end
	EnsureLoading(name, map)
	local now = Now()
	loading.sequence = loading.sequence + 1
	local out = CopyData(data, map or loading.map)
	out.session = loading.session
	out.sequence = loading.sequence
	out.total_ms = now - loading.started_at
	out.since_previous_ms = now - loading.previous_at
	loading.previous_at = now
	return Print("LoadingTiming", "STEP " .. tostring(name), out)
end

local function ClosePhase(now, map, ok)
	if not loading.phase then return end
	local duration = now - loading.phase_at
	AddTotal("phase: " .. loading.phase, duration)
	loading.sequence = loading.sequence + 1
	Print("LoadingTiming", "PHASE_END " .. loading.phase, CopyData({
		session = loading.session, sequence = loading.sequence,
		duration_ms = duration, total_ms = now - loading.started_at,
		ok = ok ~= false,
	}, map or loading.map))
	loading.phase = nil
end

function Diagnostics.LoadingPhase(name, map, data)
	if not Diagnostics.LoadingEnabled() then return false end
	EnsureLoading(name, map)
	local now = Now()
	ClosePhase(now, map, true)
	loading.phase = tostring(name)
	loading.phase_at = now
	loading.previous_at = now
	loading.sequence = loading.sequence + 1
	local out = CopyData(data, map or loading.map)
	out.session = loading.session
	out.sequence = loading.sequence
	out.total_ms = now - loading.started_at
	return Print("LoadingTiming", "PHASE_BEGIN " .. loading.phase, out)
end

function Diagnostics.LoadingBegin(name, map, data)
	if not Diagnostics.LoadingEnabled() then return false end
	EnsureLoading(name, map)
	local token = { name = tostring(name), at = Now(), map = map, session = loading.session }
	Diagnostics.LoadingStep("BEGIN " .. token.name, data, map)
	return token
end

function Diagnostics.LoadingEnd(token, data, ok)
	if type(token) ~= "table" or not Diagnostics.LoadingEnabled() then return false end
	local now = Now()
	local duration = now - (token.at or now)
	AddTotal(token.name, duration)
	local out = CopyData(data, token.map)
	out.duration_ms = duration
	out.ok = ok ~= false
	out.begin_session = token.session
	return Diagnostics.LoadingStep((ok == false and "ERROR " or "END ") .. token.name, out, token.map)
end

function Diagnostics.LoadingFinish(reason, map, data, ok)
	if not Diagnostics.LoadingEnabled() or not loading.active then return false end
	local now = Now()
	ClosePhase(now, map, ok)
	local ranked = {}
	for name, item in pairs(loading.totals) do ranked[#ranked + 1] = { name = name, item = item } end
	table.sort(ranked, function(a, b)
		if a.item.total_ms == b.item.total_ms then return a.name < b.name end
		return a.item.total_ms > b.item.total_ms
	end)
	for rank, entry in ipairs(ranked) do
		Print("LoadingTiming", "SUMMARY " .. entry.name, CopyData({
			session = loading.session, rank = rank, calls = entry.item.calls,
			total_ms = entry.item.total_ms, max_ms = entry.item.max_ms,
		}, map or loading.map))
	end
	local out = CopyData(data, map or loading.map)
	out.session = loading.session
	out.reason = tostring(reason or "complete")
	out.ok = ok ~= false
	out.session_duration_ms = now - loading.started_at
	out.diagnostic_print_ms = loading.print_ms
	Print("LoadingTiming", "SESSION_END", out)
	loading.active = false
	loading.phase = nil
	loading.map = nil
	return true
end

SuperBigMap.Diagnostics = Diagnostics

-- TEMPORARY owner release timing build (2026-09-24, owner-approved), release Mars.exe only.
-- When AppData/sbm_release_verify/case.txt lists pinned cases, one per line (for example
-- "61N136W a"), start each RoughTerrain game in turn the way the harness does (skipping only the
-- profile writes, telemetry and the planet-camera wait), measure START-to-T1, then open the
-- underground the way a player does (Elevator placed on a passage, quick-built, map switch) and
-- measure first access until the underground is prepared and both covers are closed; quit after
-- the last case. One launch (one elevation prompt) covers the list. Results go to the game log
-- only. The file is data (case names), is emptied on start, and without it the game behaves
-- normally. Requires Super Big Map to be the only enabled mod.
do
	local create = rawget(_G, "CreateRealTimeThread")
	local platform = rawget(_G, "Platform")
	if type(create) == "function" and not (platform and platform.debug) then
		create(function()
			local path = "AppData/sbm_release_verify/case.txt"
			local read, write = rawget(_G, "AsyncFileToString"), rawget(_G, "AsyncStringToFile")
			if type(read) ~= "function" or type(write) ~= "function" then return end
			local read_err, text = read(path)
			if read_err or type(text) ~= "string" then return end
			local cases = {
				["61N136W"] = { -3660, -8160, 3838460155450369287, "v932_sweep_14134_61n136w" },
				["24S74W"] = { 1440, -4440, 7578917061178043875, "v932_sweep_14134_24s74w" },
				["17S11W"] = { 1020, -660, 7671242446964682853, "v932_sweep_14134_17s11w" },
				["45S120W"] = { 2700, -7200, 3316517404621831948, "v932_sweep_14134_45s120w" },
				["15S67E"] = { 900, 4020, 411683085576098543, "sbm_entrance_bottomless_24s97w_v999" },
			}
			local queue = {}
			for site, run in text:gmatch("(%w+)[ 	]+(%w+)") do
				if not cases[site] or not (run == "a" or run == "b" or run == "control") then return end
				queue[#queue + 1] = { site, run }
			end
			if #queue == 0 then return end
			local get_dialog = rawget(_G, "GetDialog")
			local deadline = GetPreciseTicks() + 600000
			while not (get_dialog and get_dialog("PGMainMenu")) or (rawget(_G, "GameState") or {}).loading do
				if GetPreciseTicks() > deadline then return end
				Sleep(500)
			end
			local cfg = rawget(_G, "config")
			if cfg.SuperBigMapTimingBegun then return end
			cfg.SuperBigMapTimingBegun = true
			write(path, "")
			local function mod()
				for _, m in ipairs(rawget(_G, "ModsLoaded") or {}) do
					if m.id == "SuperBigMap" and type(m.env) == "table" and type(rawget(m.env, "SuperBigMap")) == "table" then
						return rawget(m.env, "SuperBigMap")
					end
				end
				return SuperBigMap
			end
			local function run_case(site, run)
			local case = cases[site]
			local function log(fmt, ...)
				print(string.format("[Super Big Map] Release timing %s %s: " .. fmt, site, run, ...))
			end
			local function finish(outcome)
				log("finished %s", tostring(outcome))
				FlushLogFile()
				return outcome
			end
			local loaded = rawget(_G, "ModsLoaded") or {}
			if not (#loaded == 1 and loaded[1].id == "SuperBigMap") then
				return finish("aborted: other mods are enabled")
			end
			local expand = run ~= "control"
			local hook, loop_hook = rawget(_G, "GetThreadDebugHook"), rawget(_G, "SetInfiniteLoopDetectionHook")
			log("build version=%s patch=%s debug=%s release_hook=%s", tostring(mod().Version or ""),
				tostring(mod().GENERATOR_PATCH_VERSION), tostring(platform and platform.debug or false),
				tostring(type(hook) == "function" and hook() == loop_hook))
			Sleep(3000)
			DoneGame()
			NewGame({ seed_text = case[4] })
			InitNewGameMissionParams()
			LoadLastNewGameSettings("regular", { RoughTerrain = true })
			ChangeMap("PreGame")
			local params = g_CurrentMapParams
			params.map = ""
			GetOverlayValues(case[1], case[2])
			params.rocket_name, params.rocket_name_base = GenerateRocketName(true)
			params.SuperBigMapExpandMap = expand and true or nil
			local sbm = mod()
			local pin_ok, pin_err = sbm.MapGeneration.SetTwinUndergroundSeedForTest(case[3], "owner release timing")
			log("underground seed pin %s %s", tostring(pin_ok), tostring(pin_err))
			-- START press: the harness and START-action boundary.
			local t0 = GetPreciseTicks()
			if expand then
				sbm.PregameToggle.SetStartArmed(true, "release timing START")
				sbm.Lifecycle.BeginExpandedSession("release timing START")
			else
				sbm.PregameToggle.SetStartArmed(false, "release timing control START")
				sbm.Lifecycle.BeginVanillaSession("release timing control START", false)
			end
			WaitWarnAboutSkippedMods()
			LoadingScreenOpen("idLoadingScreen", "StartGame")
			GenerateCurrentRandomMap()
			local t_return = GetPreciseTicks()
			LoadingScreenClose("idLoadingScreen", "StartGame")
			local map, failed
			local stop = t0 + 900000
			while GetPreciseTicks() < stop do
				for _, m in pairs(rawget(_G, "Maps") or {}) do
					if type(m) == "table" then
						if m.SuperBigMapSurfaceStretchFailed then failed = m.SuperBigMapSurfaceStretchFailed end
						if expand and m.SuperBigMapSurfaceStretchDone == true
							and m.SuperBigMapSurfacePostPipelineRevalidationComplete == true then map = m end
					end
				end
				if not expand then
					local city = CurrentMap and CurrentMap.City
					if city and type(city.MapSectors) == "table" and #city.MapSectors > 0 then map = CurrentMap end
				end
				if map or failed then break end
				Sleep(100)
			end
			local t1 = GetPreciseTicks()
			if not map then
				log("surface FAILED after %d ms: %s", t1 - t0, tostring(failed or "T1 timeout"))
				return finish("surface failed")
			end
			sbm = mod()
			local seating = map.SuperBigMapDecorationSeating or {}
			local support = seating.support or {}
			log("START-to-T1 %d ms (generation returned %d ms; seating %s ms, %s rocks corrected, %s rejected)",
				t1 - t0, t_return - t0, tostring(seating.total_ms), tostring(seating.corrected), tostring(seating.rejected))
			if expand then
				log("rock census eligible=%s terrain=%s graph=%s unresolved=%s", tostring(support.eligible),
					tostring(support.terrain), tostring(support.graph), tostring(support.unresolved))
				local d = map.SuperBigMapDecorEnginePassReport or {}
				log("decor target=%s placed_authored=%s placed_synthetic=%s objects=%s markers=%s/%s attempts=%s error=%s",
					tostring(d.target), tostring(d.placed_authored), tostring(d.placed_synthetic), tostring(d.objects),
					tostring(d.markers_resolved), tostring(d.markers_unresolved), tostring(d.synthetic_attempts), tostring(d.error))
				local a = map.SuperBigMapOuterResourceTerrainAudit or {}
				log("ring clusters=%s pads=%s resource_failures=%s rocket_failures=%s", tostring(a.resource_clusters),
					tostring(a.rocket_pads), tostring(a.resource_failures), tostring(a.rocket_failures))
			end
			local keys2, keys3 = 0, 0
			for key, value in pairs(rawget(_G, "PrefabMarkers") or {}) do
				if type(key) == "string" and type(value) == "table" then
					local _, dots = key:gsub("%.", "")
					if dots == 1 then keys2 = keys2 + 1 elseif dots == 2 then keys3 = keys3 + 1 end
				end
			end
			log("prefab registry keys: type.name=%d poi.type.name=%d", keys2, keys3)
			-- First underground access, the player's route (rules probe first_access).
			local ug
			for _, m in pairs(rawget(_G, "Maps") or {}) do
				if type(m) == "table" and m ~= map and m.mapdata and m.mapdata:GetEnvironment() == "Underground" then ug = m end
			end
			if not ug then log("underground map missing") return finish("no underground") end
			local reasons = rawget(_G, "PauseReasons")
			if type(reasons) == "table" then
				local keys = {}
				for k in pairs(reasons) do keys[#keys + 1] = k end
				for _, k in ipairs(keys) do pcall(Resume, k) end
			end
			local phase_t0 = GetPreciseTicks()
			local passage
			map:MapForEach("map", "UndergroundPassage", function(o)
				if not passage and IsValid(o) and rawget(o, "other") then passage = o end
			end)
			if not passage then log("no linked surface passage") return finish("no passage") end
			pcall(UnlockBuilding, "Elevator")
			local ctrl = GetDefaultConstructionController(map.City)
			if not ctrl then log("construction controller unavailable") return finish("no controller") end
			local cities, seen = {}, {}
			for _, c in ipairs({ ctrl.city, rawget(_G, "UICity"), map.City }) do
				if type(c) == "table" and not seen[c] and type(c.SetCableCascadeDeletion) == "function" then
					seen[c] = true
					cities[#cities + 1] = c
				end
			end
			for _, c in ipairs(cities) do pcall(c.SetCableCascadeDeletion, c, false, "ConstructionModeDialog") end
			local place_params = { pos = passage:GetPos(), angle = passage:GetAngle() }
			local template = BuildingTemplates and BuildingTemplates.Elevator
			if template and type(template.AddPlacementParams) == "function" then
				place_params = template.AddPlacementParams(place_params) or place_params
			end
			local act_ok = pcall(ctrl.Activate, ctrl, "Elevator", place_params)
			local place_ok, placed = false, nil
			if act_ok then place_ok, placed = pcall(ctrl.Place, ctrl) end
			local method = "cursor"
			if not place_ok or not placed then
				method = "external"
				place_ok, placed = pcall(ctrl.Place, ctrl, "Elevator", passage:GetPos(), passage:GetAngle(), nil)
			end
			pcall(ctrl.Deactivate, ctrl)
			for _, c in ipairs(cities) do pcall(c.SetCableCascadeDeletion, c, true, "ConstructionModeDialog") end
			local site_obj = rawget(passage, "elevator_construction")
			local group = site_obj and rawget(site_obj, "construction_group")
			local leader = type(group) == "table" and group[1] or nil
			if not (place_ok and placed and leader and IsValid(leader)) then
				log("Elevator placement failed (%s)", method)
				return finish("placement failed")
			end
			local built, build_err = false, nil
			CreateGameTimeThread(function()
				local ok_c, ce = pcall(leader.Complete, leader, "quick_build")
				if not ok_c then build_err = tostring(ce) end
				built = true
			end)
			local bdl = GetPreciseTicks() + 180000
			while not built and GetPreciseTicks() < bdl do Sleep(100) end
			local twin = rawget(passage, "other")
			local ldl = GetPreciseTicks() + 120000
			while GetPreciseTicks() < ldl and not (rawget(passage, "elevator") and twin and rawget(twin, "elevator")) do Sleep(100) end
			local e1, e2 = rawget(passage, "elevator"), twin and rawget(twin, "elevator")
			local linked = IsValid(e1) and IsValid(e2) and rawget(e1, "other") == e2
			local state = sbm.State or {}
			local change = rawget(state, "change_current_map_slot_wrapper") or ChangeCurrentMapSlot
			local sw_ok, sw_err = pcall(change, ug.slot, true, "idChangeCurrentMapSlot")
			local visible = rawget(sbm, "ExpansionLoadingVisible")
			local loading_dialog = rawget(_G, "GetLoadingScreenDialog")
			local function ready()
				return CurrentMap == ug and (not expand or (ug.SuperBigMapUndergroundPrepared == true
					and ug.SuperBigMapUndergroundStretchDone == true and ug.SuperBigMapForcedImpassDeferred ~= true
					and not (type(visible) == "function" and visible())))
					and not (type(loading_dialog) == "function" and loading_dialog())
			end
			local sdl = GetPreciseTicks() + 900000
			while GetPreciseTicks() < sdl and not ready() do Sleep(10) end
			local ug_ms = GetPreciseTicks() - phase_t0
			local passages = 0
			ug:MapForEach("map", "ElevatorPassage", function() passages = passages + 1 end)
			log("underground first access %d ms ready=%s (placement=%s built=%s build_error=%s linked=%s switch=%s %s hex=%sx%s passages=%d)",
				ug_ms, tostring(ready()), method, tostring(built), tostring(build_err), tostring(linked), tostring(sw_ok),
				tostring(sw_err), tostring(ug.hex_width), tostring(ug.hex_height), passages)
			local errors, reported = 0, 0
			for _ in pairs(rawget(_G, "LuaErrors") or {}) do errors = errors + 1 end
			for _ in pairs(rawget(_G, "ReportedMods") or {}) do reported = reported + 1 end
			log("error registry lua_errors=%d reported_mods=%d optimization_failures=%d", errors, reported,
				#(state.optimization_failures or {}))
			Sleep(2000)
			return finish("complete")
			end
			for _, entry in ipairs(queue) do
				local ok, err = pcall(run_case, entry[1], entry[2])
				if not ok then
					print(string.format("[Super Big Map] Release timing %s %s: finished error %s", entry[1], entry[2], tostring(err)))
				end
				Sleep(3000)
			end
			FlushLogFile()
			Sleep(3000)
			quit()
		end)
	end
end

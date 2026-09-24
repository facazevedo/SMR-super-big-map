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

-- TEMPORARY owner timing build (2026-09-24, owner-approved), release Mars.exe only: once per
-- process, from the main menu, start the pinned 61N136W RoughTerrain expanded game the way the
-- harness does (skipping only SaveNewGameSettings, telemetry, the rocket-name registry and the
-- planet-camera wait, which touch the player's profile or need the planet screen), then quit
-- 5 s after T1. The START-to-T1 log line comes from the timing build's T1 hook.
do
	local create = rawget(_G, "CreateRealTimeThread")
	local platform = rawget(_G, "Platform")
	if type(create) == "function" and not (platform and platform.debug) then
		create(function()
			local get_dialog = rawget(_G, "GetDialog")
			local deadline = GetPreciseTicks() + 600000
			while not (get_dialog and get_dialog("PGMainMenu")) or (rawget(_G, "GameState") or {}).loading do
				if GetPreciseTicks() > deadline then return end
				Sleep(500)
			end
			if rawget(_G, "SBM_TIMING_AUTOSTART_BEGUN") then return end
			rawset(_G, "SBM_TIMING_AUTOSTART_BEGUN", true)
			Sleep(3000)
			print("[Super Big Map] Timing autostart: 61N136W expanded RoughTerrain game")
			DoneGame()
			NewGame({ seed_text = "v932_sweep_14134_61n136w" })
			InitNewGameMissionParams()
			LoadLastNewGameSettings("regular", { RoughTerrain = true })
			ChangeMap("PreGame")
			local params = g_CurrentMapParams
			params.map = ""
			GetOverlayValues(-3660, -8160)
			params.rocket_name, params.rocket_name_base = GenerateRocketName(true)
			params.SuperBigMapExpandMap = true
			-- START press: same boundary as the harness and the real START action wrapper.
			params.SuperBigMapTimingStartTicks = GetPreciseTicks()
			-- Resolve the live mod table (the new-game Lua reload may have replaced it).
			local sbm = SuperBigMap
			for _, mod in ipairs(rawget(_G, "ModsLoaded") or {}) do
				if mod.id == "SuperBigMap" and type(mod.env) == "table" and type(rawget(mod.env, "SuperBigMap")) == "table" then
					sbm = rawget(mod.env, "SuperBigMap")
				end
			end
			sbm.PregameToggle.SetStartArmed(true, "timing autostart START")
			sbm.Lifecycle.BeginExpandedSession("timing autostart START")
			WaitWarnAboutSkippedMods()
			LoadingScreenOpen("idLoadingScreen", "StartGame")
			GenerateCurrentRandomMap()
			LoadingScreenClose("idLoadingScreen", "StartGame")
			local stop = GetPreciseTicks() + 600000
			while GetPreciseTicks() < stop do
				local m = rawget(_G, "MainMap")
				if m and m.SuperBigMapSurfacePostPipelineRevalidationComplete == true then break end
				Sleep(200)
			end
			Sleep(5000)
			print("[Super Big Map] Timing autostart: done, quitting")
			quit()
		end)
	end
end

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
	data.environment = tostring(type(mapdata) == "table" and mapdata.Environment or "?")
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

function Diagnostics.OuterResourceRetryPatchProfileEnabled()
	return Config().TRACE_OUTER_RESOURCE_RETRY_PATCH_PROFILE == true
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

-- Temporary retry-ordinal profiler. The caller supplies scalar-only measurements after
-- terrain mutation; this channel performs no grid reads and no gameplay operation.
function Diagnostics.OuterResourceRetryPatchProfile(event, data, map)
	if not Diagnostics.OuterResourceRetryPatchProfileEnabled() then return false end
	return Print("OuterResourceRetryPatchProfile", event, CopyData(data, map))
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

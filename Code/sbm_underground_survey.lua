-- Super Big Map -- underground sector survey: when the overview rollover shows "Buildable area".
--
-- Expanded undergrounds are completely black where unexplored (sbm_underground_darkness), yet the
-- overview rollover's "Buildable area: N%" line would still tell how much open cave a dark sector
-- holds. The game never scans underground sectors, and its darkness keeps no memory of where a
-- vehicle has been: only the buildings, cables/pipes and vehicles present right now lift it. So
-- this module remembers, per sector and in the save, which of the sector's reachable ground has
-- been lit at least once. The mod's underground rollover (sbm_sector_highlight) shows the sector's
-- (whole) buildable area once about half of that ground has been lit, and "Buildable area: ?"
-- before (ShowsBuildableArea); the verdict then stays.
--
-- Each sector is split into CELLS x CELLS cells. A cell is reachable when the terrain at its
-- centre is passable (a vehicle can drive there), and lit once its centre has been inside the
-- reveal radius of any object in the map's RevealDarknessObjects / RevealDarknessFastObjects
-- lists, the same objects the darkness pass reveals around. Measuring against reachable ground,
-- not the whole sector, lets a sector that is mostly solid rock still qualify once its cave has
-- been driven; a sector with no reachable cell never shows the number. Records live in the
-- persisted per-map MapVar SuperBigMapUndergroundSurvey; a qualified sector keeps only its verdict.
--
-- Scope: expanded (mod) underground maps only; sampling starts once the deferred underground
-- preparation has finished, and the sampling thread exists only during an expanded session. The
-- rollover of every other map is untouched.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local floor, max, min = math.floor, math.max, math.min

SuperBigMap.State = SuperBigMap.State or {}

local Survey = {}
SuperBigMap.UndergroundSurvey = Survey

Survey.VERSION = 1
Survey.CELLS = 16
Survey.SAMPLE_MS = 1000
Survey.UNKNOWN_TEXT = "Buildable area: <em>?</em>"

-- Persisted per map: { version, cells, sectors = { ["col:row"] = record } }. Guarded against the
-- MapVar "already registered" assert when the module is re-executed.
do
	local register, registry = Global("MapVar"), Global("MapVarValues")
	if type(register) == "function" and (type(registry) ~= "table"
		or registry.SuperBigMapUndergroundSurvey == nil) then
		register("SuperBigMapUndergroundSurvey", false)
	end
end

local function cfg() return SuperBigMap.Config or {} end

function Survey.Enabled()
	return cfg().UNDERGROUND_BUILDABLE_AREA_NEEDS_SURVEY ~= false
end

-- Share of a sector's reachable ground that must have been lit.
function Survey.Threshold()
	local v = cfg().UNDERGROUND_SURVEY_FRACTION
	if type(v) == "number" and v > 0 and v <= 1 then return v end
	return 0.5
end

local function IsModUnderground(map)
	if not map or type(map) ~= "table" and type(map) ~= "userdata" then return false end
	local mapdata = map.mapdata
	if not mapdata or Engine.MapDataEnvironment(mapdata) ~= "Underground" then return false end
	local grid = SuperBigMap.SectorGrid
	return grid ~= nil and type(grid.IsModMap) == "function" and grid.IsModMap(map) == true
end
Survey.IsModUnderground = IsModUnderground

-- Sampling needs the final (stretched) terrain and sector grid.
local function IsSurveyMap(map)
	return IsModUnderground(map) and map.SuperBigMapUndergroundPrepared == true
end
Survey.IsSurveyMap = IsSurveyMap

local function Records(map, create)
	local rec = map.SuperBigMapUndergroundSurvey
	if type(rec) ~= "table" then
		if not create then return nil end
		rec = { version = Survey.VERSION, cells = Survey.CELLS, sectors = {} }
		map.SuperBigMapUndergroundSurvey = rec
	end
	rec.sectors = rec.sectors or {}
	rec.cells = rec.cells or Survey.CELLS
	return rec
end
Survey.Records = Records

local function SectorKey(sector)
	return tostring(sector.col) .. ":" .. tostring(sector.row)
end
Survey.SectorKey = SectorKey

-- Position -> sector lookup built from the sectors' own areas (the game's PosToSectorXY is private
-- and clamps to the vanilla 10 x 10 grid). Rebuilt when the city's sector table changes.
local index_cache = setmetatable({}, { __mode = "k" })

local function SectorIndex(city)
	local sectors = city and city.MapSectors
	if type(sectors) ~= "table" then return nil end
	local cached = index_cache[city]
	if cached and cached.sectors == sectors then return cached end
	local list, ox, oy, tile_x, tile_y = {}, nil, nil, nil, nil
	for _, column in pairs(sectors) do
		if type(column) == "table" then
			for _, sector in pairs(column) do
				local area = type(sector) == "table" and sector.area
				if area then
					list[#list + 1] = sector
					local x0, y0 = area:minx(), area:miny()
					ox = ox and min(ox, x0) or x0
					oy = oy and min(oy, y0) or y0
					tile_x = tile_x or area:sizex()
					tile_y = tile_y or area:sizey()
				end
			end
		end
	end
	if #list == 0 or not tile_x or tile_x <= 0 or tile_y <= 0 then return nil end
	local lookup, cols, rows = {}, 0, 0
	for _, sector in ipairs(list) do
		local ix = floor((sector.area:minx() - ox) / (tile_x + 0.0) + 0.5) + 1
		local iy = floor((sector.area:miny() - oy) / (tile_y + 0.0) + 0.5) + 1
		lookup[ix] = lookup[ix] or {}
		lookup[ix][iy] = sector
		cols, rows = max(cols, ix), max(rows, iy)
	end
	cached = { sectors = sectors, lookup = lookup, ox = ox, oy = oy, tile_x = tile_x, tile_y = tile_y,
		cols = cols, rows = rows }
	index_cache[city] = cached
	return cached
end
Survey.SectorIndex = SectorIndex

local function CellRange(origin, size, n, lo, hi)
	local w = size / (n + 0.0)
	return max(0, floor((lo - origin) / w)), min(n - 1, floor((hi - origin) / w)), w
end

-- First touch of a sector: find its reachable cells.
local function SectorRecord(map, rec, sector)
	local key = SectorKey(sector)
	local s = rec.sectors[key]
	if s then return s end
	local n = rec.cells
	local area = sector.area
	local x0, y0 = area:minx(), area:miny()
	local w, h = area:sizex() / (n + 0.0), area:sizey() / (n + 0.0)
	local terrain_api = Global("terrain")
	local is_passable = type(terrain_api) == "table" and terrain_api.IsPassable
	local reachable, count = {}, 0
	if type(is_passable) == "function" then
		for j = 0, n - 1 do
			for i = 0, n - 1 do
				local ok, passable = pcall(is_passable, map, floor(x0 + (i + 0.5) * w), floor(y0 + (j + 0.5) * h))
				if ok and passable then
					reachable[j * n + i + 1] = true
					count = count + 1
				end
			end
		end
	end
	s = { reachable = reachable, reachable_n = count, lit = {}, lit_n = 0, done = false }
	rec.sectors[key] = s
	return s
end
Survey.SectorRecord = SectorRecord

-- Mark every reachable cell whose centre lies within r of (x, y). Returns the number of cells
-- newly lit.
local function MarkCircle(map, rec, index, x, y, r)
	local newly = 0
	local n = rec.cells
	local ix0 = max(1, floor((x - r - index.ox) / (index.tile_x + 0.0)) + 1)
	local ix1 = min(index.cols, floor((x + r - index.ox) / (index.tile_x + 0.0)) + 1)
	local iy0 = max(1, floor((y - r - index.oy) / (index.tile_y + 0.0)) + 1)
	local iy1 = min(index.rows, floor((y + r - index.oy) / (index.tile_y + 0.0)) + 1)
	local r2 = (r + 0.0) * r
	local threshold = Survey.Threshold()
	for ix = ix0, ix1 do
		local column = index.lookup[ix]
		for iy = iy0, iy1 do
			local sector = column and column[iy]
			if sector then
				local s = SectorRecord(map, rec, sector)
				if not s.done and s.reachable_n > 0 then
					local area = sector.area
					local sx, sy = area:minx(), area:miny()
					local i0, i1, w = CellRange(sx, area:sizex(), n, x - r, x + r)
					local j0, j1, h = CellRange(sy, area:sizey(), n, y - r, y + r)
					for j = j0, j1 do
						local dy = sy + (j + 0.5) * h - y
						for i = i0, i1 do
							local cell = j * n + i + 1
							if s.reachable[cell] and not s.lit[cell] then
								local dx = sx + (i + 0.5) * w - x
								if dx * dx + dy * dy <= r2 then
									s.lit[cell] = true
									s.lit_n = s.lit_n + 1
									newly = newly + 1
								end
							end
						end
					end
					if s.lit_n >= threshold * s.reachable_n then
						-- Qualified for good: keep only the verdict.
						s.done = true
						s.reachable, s.lit = nil, nil
					end
				end
			end
		end
	end
	return newly
end
Survey.MarkCircle = MarkCircle

-- Objects that did not move (a cell's quarter) since the last sample are skipped.
local last_sample = setmetatable({}, { __mode = "k" })

local function SampleObject(map, rec, index, obj, guim)
	local is_valid = Global("IsValid")
	if type(is_valid) == "function" and not is_valid(obj) then return 0 end
	if type(obj.CanReveal) == "function" and not obj:CanReveal() then return 0 end
	if type(obj.GetVisualPosXYZ) ~= "function" or type(obj.GetRevealRange) ~= "function" then return 0 end
	local x, y = obj:GetVisualPosXYZ()
	local const_tbl = Global("const")
	if type(x) ~= "number" or type(y) ~= "number"
		or (type(const_tbl) == "table" and x == const_tbl.InvalidCoord) then
		return 0
	end
	local range = obj:GetRevealRange()
	if type(range) ~= "number" or range <= 0 then return 0 end
	local r = range * guim
	local last = last_sample[obj]
	local slack = index.tile_x / (rec.cells * 4.0)
	if last and last.map == map and last.r == r and math.abs(last.x - x) < slack and math.abs(last.y - y) < slack then
		return 0
	end
	last_sample[obj] = { map = map, x = x, y = y, r = r }
	return MarkCircle(map, rec, index, x, y, r)
end

function Survey.SampleMap(map)
	if not IsSurveyMap(map) then return 0 end
	local index = SectorIndex(map.City)
	if not index then return 0 end
	local rec = Records(map, true)
	local guim = Global("guim") or 100
	local newly = 0
	for _, list_name in ipairs({ "RevealDarknessObjects", "RevealDarknessFastObjects" }) do
		local list = map[list_name]
		if type(list) == "table" then
			for i = 1, #list do
				local obj = list[i]
				if obj then newly = newly + SampleObject(map, rec, index, obj, guim) end
			end
		end
	end
	return newly
end

local function Report(key, message)
	local State = SuperBigMap.State
	State.underground_survey_reported = State.underground_survey_reported or {}
	if State.underground_survey_reported[key] then return end
	State.underground_survey_reported[key] = true
	local print_fn = Global("print")
	if type(print_fn) == "function" then print_fn("[SuperBigMap] underground survey: " .. tostring(message)) end
end

function Survey.SampleAll()
	for _, map in ipairs(Global("LoadedMaps") or {}) do
		if IsSurveyMap(map) then
			local ok, err = pcall(Survey.SampleMap, map)
			if not ok then Report("sample:" .. tostring(err), "sampling failed: " .. tostring(err)) end
		end
	end
end

-- Share of the sector's reachable ground lit so far (1 once qualified), or nil when untracked.
function Survey.Progress(sector)
	local map = sector and type(sector.GetMap) == "function" and SafeCall(sector.GetMap, sector)
	local rec = map and Records(map, false)
	local s = rec and rec.sectors[SectorKey(sector)]
	if not s then return nil end
	if s.done then return 1 end
	if s.reachable_n <= 0 then return 0 end
	return s.lit_n / (s.reachable_n + 0.0)
end

-- True when the rollover may show the sector's buildable area: always outside expanded
-- undergrounds, and there once the sector qualified.
function Survey.ShowsBuildableArea(sector)
	if not Survey.Enabled() or not sector then return true end
	local map = type(sector.GetMap) == "function" and SafeCall(sector.GetMap, sector)
	if not IsModUnderground(map) then return true end
	local rec = Records(map, false)
	local s = rec and rec.sectors[SectorKey(sector)]
	return s ~= nil and s.done == true
end

function Survey.StartSampling()
	local State = SuperBigMap.State
	local create = Global("CreateRealTimeThread")
	local sleep = Global("Sleep")
	if type(create) ~= "function" or type(sleep) ~= "function" then return false end
	local is_valid_thread = Global("IsValidThread")
	if State.underground_survey_token and State.underground_survey_thread
		and (type(is_valid_thread) ~= "function" or is_valid_thread(State.underground_survey_thread)) then
		return true
	end
	local token = {}
	State.underground_survey_token = token
	State.underground_survey_thread = create(function()
		while SuperBigMap.State.underground_survey_token == token do
			Survey.SampleAll()
			sleep(Survey.SAMPLE_MS)
		end
	end)
	return true
end

function Survey.StopSampling()
	local State = SuperBigMap.State
	State.underground_survey_token = nil
	local thread = State.underground_survey_thread
	State.underground_survey_thread = nil
	local delete = Global("DeleteThread")
	if thread and type(delete) == "function" then pcall(delete, thread) end
end

-- Lifecycle phases: only an expanded session samples. Re-applied after class rebuilds and mod
-- reloads, which can end the sampling thread.
function Survey.ApplyModBehavior()
	if not Survey.Enabled() then return false end
	return Survey.StartSampling()
end

function Survey.RestoreVanillaBehavior()
	Survey.StopSampling()
	return true
end

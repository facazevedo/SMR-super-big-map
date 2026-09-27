-- Underground sector survey: on expanded undergrounds the overview rollover's "Buildable area"
-- reads "?" until half of the sector's reachable ground has been lit at least once; the verdict is
-- persisted per sector and never revoked. Every other map keeps the game's rollover.
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function read(path)
	local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s
end

local function box(x0, y0, x1, y1)
	return {
		minx = function() return x0 end, miny = function() return y0 end,
		sizex = function() return x1 - x0 end, sizey = function() return y1 - y0 end,
	}
end

-- A 3 x 3 grid of 1000 x 1000 sectors. Terrain is passable left of x = 1500 only: column 1 is
-- fully reachable, column 2 half, column 3 solid rock.
local function new_map(opts)
	local map = { mapdata = { Environment = opts.environment or "Underground" }, mod = opts.mod ~= false,
		SuperBigMapUndergroundPrepared = opts.prepared ~= false,
		RevealDarknessObjects = {}, RevealDarknessFastObjects = {}, SuperBigMapUndergroundSurvey = false }
	local sectors = {}
	for col = 1, 3 do
		sectors[col] = {}
		for row = 1, 3 do
			local s = { col = col, row = row, id = string.char(64 + col) .. row,
				area = box((col - 1) * 1000, (row - 1) * 1000, col * 1000, row * 1000) }
			function s:GetMap() return map end
			sectors[col][row] = s
		end
	end
	map.City = { MapSectors = sectors }
	return map, sectors
end

local threads = {}
local registered = {}
local globals = {
	MapVar = function(name, value) assert(not registered[name], "MapVar registered twice"); registered[name] = value end,
	MapVarValues = registered,
	terrain = { IsPassable = function(map, x, y) return x < 1500 end },
	guim = 100,
	IsValid = function(obj) return obj and obj.valid ~= false end,
	const = { InvalidCoord = -1 },
	LoadedMaps = {},
	TGetID = function(t) return type(t) == "table" and t.id or nil end,
	Untranslated = function(s) return { untranslated = s } end,
	CreateRealTimeThread = function(fn) local t = { fn = fn }; threads[#threads + 1] = t; return t end,
	Sleep = function() end,
	DeleteThread = function(t) t.deleted = true end,
	IsValidThread = function(t) return t and not t.deleted end,
	print = function() end,
}
local SuperBigMap = {
	Engine = {
		Global = function(name) return globals[name] end,
		SafeCall = function(fn, ...) local r = { pcall(fn, ...) }; if r[1] then return select(2, table.unpack(r)) end end,
		MapDataEnvironment = function(mapdata) return mapdata.Environment end,
		ClassTable = function(name) return globals[name] end,
	},
	Config = { UNDERGROUND_BUILDABLE_AREA_NEEDS_SURVEY = true, UNDERGROUND_SURVEY_FRACTION = 0.5 },
	State = {},
	SectorGrid = { IsModMap = function(map) return map and map.mod == true end },
}
local function load_module()
	local env = setmetatable({ SuperBigMap = SuperBigMap }, { __index = _G })
	env._G = env
	assert(loadfile("Code/sbm_underground_survey.lua", "t", env))()
	return SuperBigMap.UndergroundSurvey
end
local S = load_module()
check(registered.SuperBigMapUndergroundSurvey == false, "the survey MapVar must be registered")
S = load_module()
check(true, "re-executing the module must not register the MapVar twice")

local function revealer(x, y, range_m, opts)
	opts = opts or {}
	return { x = x, y = y, range = range_m, valid = opts.valid,
		GetVisualPosXYZ = function(self) return self.x, self.y, 0 end,
		GetRevealRange = function(self) return self.range end,
		CanReveal = function() return opts.can_reveal ~= false end }
end

-- 1. Scope: the surface and vanilla undergrounds always show the number.
do
	local surface, ss = new_map({ environment = "Surface" })
	local vanilla, vs = new_map({ mod = false })
	check(S.ShowsBuildableArea(ss[1][1]), "an expanded surface sector keeps the number")
	check(S.ShowsBuildableArea(vs[1][1]), "a vanilla underground sector keeps the number")
	check(S.SampleMap(surface) == 0 and surface.SuperBigMapUndergroundSurvey == false, "the surface is never sampled")
	local unprepared = new_map({ prepared = false })
	check(S.SampleMap(unprepared) == 0 and unprepared.SuperBigMapUndergroundSurvey == false, "an unprepared underground is not sampled")
end

-- 2. An expanded underground hides the number until half of the reachable ground has been lit.
local map, sectors = new_map({})
local a1, b1, c1 = sectors[1][1], sectors[2][1], sectors[3][1]
check(not S.ShowsBuildableArea(a1), "an untouched expanded underground sector must hide the number")
check(S.Progress(a1) == nil, "an untouched sector has no record")
local rover = revealer(500, 500, 2)          -- radius 200 around the centre of A1
map.RevealDarknessFastObjects[1] = rover
check(S.SampleMap(map) > 0, "a vehicle must light cells")
local p = S.Progress(a1)
check(p and p > 0 and p < 0.5 and not S.ShowsBuildableArea(a1), "a small lit patch keeps the number hidden: " .. tostring(p))
check(S.SampleMap(map) == 0, "an unmoved vehicle is skipped")
rover.range = 6                               -- radius 600: most of A1
check(S.SampleMap(map) > 0 and S.ShowsBuildableArea(a1), "half of the reachable ground lit must show the number")
check(S.Progress(a1) == 1, "a qualified sector reports full progress")
local rec = map.SuperBigMapUndergroundSurvey.sectors[S.SectorKey(a1)]
check(rec.done == true and rec.lit == nil and rec.reachable == nil, "a qualified sector keeps only its verdict")
map.RevealDarknessFastObjects[1] = nil
S.SampleMap(map)
check(S.ShowsBuildableArea(a1), "the verdict stays after the darkness returns")

-- 3. Reachable ground, not sector area: B1 is half rock. Lighting its whole passable half
-- qualifies it; C1 is solid rock and never qualifies even when fully lit.
map.RevealDarknessObjects[1] = revealer(1250, 500, 8)   -- a building lighting B1's passable half and more
map.RevealDarknessObjects[2] = revealer(2500, 500, 20)  -- lights all of C1
S.SampleMap(map)
check(S.ShowsBuildableArea(b1), "a half-rock sector qualifies once its reachable half is lit")
check(not S.ShowsBuildableArea(c1), "a solid-rock sector never shows the number")
check(S.Progress(c1) == 0, "a solid-rock sector reports no progress")

-- 4. Objects that cannot reveal, invalid ones and invalid positions are ignored.
local m2, s2 = new_map({})
m2.RevealDarknessObjects = { revealer(500, 500, 20, { can_reveal = false }), revealer(500, 500, 20, { valid = false }),
	revealer(-1, -1, 20) }
check(S.SampleMap(m2) == 0 and not S.ShowsBuildableArea(s2[1][1]), "non-revealing, invalid and unplaced objects light nothing")

-- 5. Threshold: a higher share needs more lit ground.
SuperBigMap.Config.UNDERGROUND_SURVEY_FRACTION = 0.9
local m3, s3 = new_map({})
m3.RevealDarknessFastObjects = { revealer(500, 500, 4.5) }
S.SampleMap(m3)
check(not S.ShowsBuildableArea(s3[1][1]), "radius 450 lights about 60% of A1: below a 90% threshold")
SuperBigMap.Config.UNDERGROUND_SURVEY_FRACTION = 0.5

-- 6. Sampler lifecycle.
check(S.ApplyModBehavior() == true and #threads == 1, "an expanded session must start the sampler")
S.ApplyModBehavior()
check(#threads == 1, "a second apply must not start a second sampler")
check(S.RestoreVanillaBehavior() == true and threads[1].deleted and SuperBigMap.State.underground_survey_token == nil,
	"a vanilla session stops the sampler")
S.ApplyModBehavior()
check(#threads == 2, "a later expanded session starts a new sampler")
S.RestoreVanillaBehavior()
SuperBigMap.Config.UNDERGROUND_BUILDABLE_AREA_NEEDS_SURVEY = false
check(S.ShowsBuildableArea(c1) and S.ApplyModBehavior() == false and #threads == 2,
	"disabled configuration shows the number and starts nothing")
SuperBigMap.Config.UNDERGROUND_BUILDABLE_AREA_NEEDS_SURVEY = true

-- 7. The mod's underground rollover asks the survey before showing the percentage.
local highlight = read("Code/sbm_sector_highlight.lua")
check(highlight:find("survey.ShowsBuildableArea(sector) ~= false", 1, true), "the underground rollover must ask the survey")
check(highlight:find("or untranslated(survey.UNKNOWN_TEXT)", 1, true), "an unsurveyed sector must read ?")
check(S.UNKNOWN_TEXT == "Buildable area: <em>?</em>", "unknown text")

-- 8. Wiring.
local lifecycle = read("Code/sbm_lifecycle.lua")
local apply = lifecycle:match("local APPLY_ORDER = (%b{})")
local restore = lifecycle:match("local RESTORE_ORDER = (%b{})")
check(apply:find('"UndergroundSurvey"', 1, true), "the expanded-session apply phase must include the survey")
check(restore:find('"UndergroundSurvey"', 1, true) < restore:find('"UndergroundDarkness"', 1, true), "restore must run in reverse order")
local _, reinstalls = lifecycle:gsub("SafeCall%(survey%.ApplyModBehavior%)", "")
check(reinstalls == 2, "class rebuilds and reloads must restart the sampler")
local config = read("Code/sbm_config.lua")
check(config:find("config.UndergroundBuildableAreaNeedsSurvey = true", 1, true), "the survey rule must default on")
check(config:find("config.UndergroundSurveyFraction = 0.5", 1, true), "the threshold must default to half")
check(config:find("C.UNDERGROUND_SURVEY_FRACTION = config.UndergroundSurveyFraction", 1, true), "config key missing")
print("underground survey: " .. checks .. " checks passed")

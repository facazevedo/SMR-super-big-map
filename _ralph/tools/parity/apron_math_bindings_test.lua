-- Production apron function versus the v932 checkpoint, including every grid write.
-- This output-preserving regression also requires fewer hot-loop math table lookups.
local f = assert(io.open("Code/sbm_terrain_copy.lua", "rb"))
local current = f:read("*a"); f:close()
local pipe = assert(io.popen("git show fde100f:Code/sbm_terrain_copy.lua", "r"))
local baseline = pipe:read("*a"); assert(pipe:close())
local function extract(source)
	return assert(source:match("(local function CreateNaturalMountainBaseBuildableAprons.-)\n%-%- Score the centers"))
end
local function same(a, b, path)
	path = path or "result"
	assert(type(a) == type(b), path .. ": type mismatch")
	if type(a) ~= "table" then assert(a == b, path .. ": value mismatch"); return end
	for k, v in pairs(a) do same(v, b[k], path .. "." .. tostring(k)) end
	for k in pairs(b) do assert(a[k] ~= nil, path .. ": extra " .. tostring(k)) end
end
local function run(source, fixture)
	local gets, writes, values, lookups, steps = 0, {}, {}, {}, {}
	local grid = {}
	function grid:size() return fixture.width or 1024, fixture.height or 1024 end
	function grid:get(x, y)
		local w, h = self:size()
		assert(x >= 0 and y >= 0 and x < w and y < h and x % 1 == 0 and y % 1 == 0)
		gets = gets + 1
		local key = y * w + x
		if values[key] ~= nil then return values[key] end
		return fixture.height_at(x, y)
	end
	function grid:set(x, y, z)
		local w, h = self:size()
		assert(x >= 0 and y >= 0 and x < w and y < h and z % 1 == 0 and z >= 0 and z <= 65535)
		local key = y * w + x
		values[key] = z
		writes[#writes + 1] = {x, y, z}
	end
	local constants = {HeightTileSize = 100, HexSize = 1000}
	local env = setmetatable({
		math = setmetatable({}, {__index = function(_, k) lookups[k] = (lookups[k] or 0) + 1; return math[k] end}),
		cfg_bool = function(_, default) if fixture.disabled then return false end; return default end,
		cfg_number = function(key, default) return fixture.config and fixture.config[key] or default end,
		Global = function(key)
			if key == "const" then return constants end
			if key == "guim" then return 100 end
			assert(key == "PauseInfiniteLoopDetection" or key == "ResumeInfiniteLoopDetection", "unexpected global " .. key)
			return function(reason) steps[#steps + 1] = {key, reason} end
		end,
		LoadingStep = function(name) steps[#steps + 1] = name end,
	}, {__index = _G})
	local fn = assert(load(extract(source) .. "\nreturn CreateNaturalMountainBaseBuildableAprons", "apron-test", "t", env))()
	local map = {mapdata = {Environment = fixture.underground and "Underground" or "Surface"}}
	local ok, report = fn(map, grid)
	return {ok = ok, report = report, map = map, gets = gets, writes = writes, steps = steps}, lookups
end
local function hill(x, y)
	return math.floor(20000 + 1000 * math.sin(x / 100) + 1000 * math.cos(y / 125))
end
-- Put the synthetic basin exactly on an outer-sector sample. Its 12-unit-per-cell
-- cone is steep enough to require shaping, but remains below the production
-- rejection ceiling; the distant rings all see qualifying mountain relief.
local function edited_basin(x, y)
	local dx, dy = x - 193, y - 217
	return math.floor(20000 + 12 * math.sqrt(dx * dx + dy * dy) + 0.5)
end
local fixtures = {
	{name = "edited basin square", height_at = edited_basin, edited = true},
	{name = "edited basin rectangle", width = 1536, height = 1024, height_at = edited_basin, edited = true},
	{name = "already flat", height_at = function() return 20000 end},
	{name = "steep slope rejected", height_at = function(x) return x * 40 end},
	{name = "bounded opportunity count", height_at = hill, config = {MOUNTAIN_BASE_APRON_MAXIMUM_COUNT = 3}},
	{name = "empty ring policy", height_at = hill, config = {MOUNTAIN_BASE_APRON_OUTER_RING_SECTORS = 0}},
	{name = "disabled", height_at = hill, disabled = true},
	{name = "underground excluded", height_at = hill, underground = true},
	{name = "small grid excluded", height_at = hill, width = 256, height = 256},
}
for _, fixture in ipairs(fixtures) do
	local before, old_lookups = run(baseline, fixture)
	local after, new_lookups = run(current, fixture)
	same(before, after)
	if fixture.edited then
		assert(#after.writes > 0, "fixture did not exercise raster")
		assert((new_lookups.sqrt or 0) < (old_lookups.sqrt or 0), "sqrt lookups not reduced")
	end
	print("PASS " .. fixture.name .. " (" .. #after.writes .. " identical writes)")
end
print(#fixtures .. " apron equivalence checks passed")

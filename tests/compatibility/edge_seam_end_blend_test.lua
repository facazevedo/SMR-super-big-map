-- The destination edge pass (RepairInternalHeightStep(grid, false)) on synthetic terrain.
-- 39S130W A0, 2026-09-28: a seam fading below the contrast threshold stopped the translation
-- mid-seam and left a 289-unit wall across the edge strip; a track wandering off its seam line
-- raised alternate rows and left walls of up to 1,873 units.
local api = dofile('_ralph/tools/parity/native_grid_double.lua')
function api.GridMask(grid, mask, lo, hi)
	local w, h = grid:size()
	for y = 0, h - 1 do for x = 0, w - 1 do
		local v = grid:get(x, y)
		mask.values[y * w + x] = (v >= lo and v <= hi) and 1 or 0
	end end
end
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end

local f = assert(io.open('Code/sbm_terrain_copy.lua', 'rb')); local source = f:read('*a'); f:close()
local chunk = assert(source:match('(local function BuildHeightStepDiscoveryIndex.-)\n%-%- Repair already%-qualified outer%-ring creases'))
local env = setmetatable({ Global = function(name)
	if name == 'GetPreciseTicks' then return function() return 0 end end
	return api[name]
end }, { __index = _G })
local Repair = assert(load(chunk .. '\nreturn RepairInternalHeightStep', 'destination edge pass', 't', env))()

local N = 512
-- Right edge (detection band x 502..507): a seam on line x = 503 whose jump fades in over rows
-- 60..150 and whose last rows (450+) move off the line to x = 507. Left edge (band 2..8): a step
-- that zigzags between x = 3 and x = 8 every ten rows, so no grid line carries it.
local function seam(y)
	if y < 60 then return 0 end
	if y < 150 then return math.floor(800 * (y - 60) / 90) end
	return 800
end
local function height(x, y)
	local z = 20000 + 3 * y - 2 * x
	if y >= 450 then
		if x >= 508 then z = z - 800 end
	elseif x >= 504 then
		z = z - seam(y)
	end
	if y >= 100 and y < 400 then
		local p = (y // 10) % 2 == 0 and 3 or 8
		if x <= p then z = z - 800 end
	end
	return z
end
local grid = api.NewComputeGrid(N, N, 'u', 16)
-- Like the engine, reads past the grid return no height (the scans look a few cells ahead and
-- check the type of what they read).
local inside_get = grid.get
function grid:get(x, y)
	if x < 0 or y < 0 or x >= self.w or y >= self.h then return nil end
	return inside_get(self, x, y)
end
local before = {}
for y = 0, N - 1 do for x = 0, N - 1 do
	local z = height(x, y); grid:set(x, y, z); before[y * N + x] = z
end end
local function old(x, y) return before[y * N + x] end
local function new(x, y) return grid:get(x, y) end

local repaired, report = Repair(grid, false)
check(repaired == true, 'the seam must be repaired: ' .. tostring(report and report.reason))
check(report.threshold == 256, 'threshold ' .. tostring(report.threshold))
check((report.extended or 0) > 0, 'rows beyond the detected track must be blended')
check((report.off_line or 0) > 0, 'off-line rows must be counted')

-- Where the seam is full, the edge strip continues the inner surface.
for y = 160, 440 do
	check(math.abs(new(504, y) - new(503, y)) <= 60, 'seam left open at row ' .. y)
end
-- No wall across the strip or the join: along the edge, no step grows by more than a quarter of
-- the threshold anywhere (the old detection start near row 88 left one of about 260).
local worst, worst_at = 0, nil
for y = 1, 449 do for x = 490, N - 1 do
	local grown = math.abs(new(x, y) - new(x, y - 1)) - math.abs(old(x, y) - old(x, y - 1))
	if grown > worst then worst, worst_at = grown, x .. ',' .. y end
end end
check(worst <= 64, 'perpendicular wall of ' .. worst .. ' at ' .. tostring(worst_at))
-- Before the seam begins, the blend only finishes fading out (at most a few units here), and the
-- terrain beyond it is untouched.
local fade_worst = 0
for y = 0, 59 do for x = 480, N - 1 do
	fade_worst = math.max(fade_worst, math.abs(new(x, y) - old(x, y)))
	if y < 40 then check(new(x, y) == old(x, y), 'terrain before the fade changed at ' .. x .. ',' .. y) end
end end
check(fade_worst <= 8, 'the fade before the seam changed terrain by ' .. fade_worst)
-- The off-line tail is not a seam of this track: past one fade it keeps its vanilla step.
for y = 484, 500 do
	check(new(507, y) - new(508, y) >= 790, 'off-line step translated at row ' .. y)
	for x = 480, N - 1 do check(new(x, y) == old(x, y), 'off-line row changed at ' .. x .. ',' .. y) end
end
-- The zigzag follows no line, so the left edge is left exactly as it was.
for y = 0, N - 1 do for x = 0, 12 do
	check(new(x, y) == old(x, y), 'line-less track translated at ' .. x .. ',' .. y)
end end

-- The fade divides integers; the engine's Lua divides int/int as an integer, which turned the
-- quintic blend into a hard stop at the end of the fade.
check(source:find('quintic((k - fade_from) / (taper + 0.0))', 1, true) ~= nil,
	'the fade position must be a float division')
print('edge seam end blend: ' .. checks .. ' checks passed')

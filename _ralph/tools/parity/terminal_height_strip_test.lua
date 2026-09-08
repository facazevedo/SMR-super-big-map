-- Run from the repository root: lua _ralph/tools/parity/terminal_height_strip_test.lua
-- Optional argument: captured 8192x8192 U16 baseline, to check the real A0 footprint.
local f = assert(io.open("Code/sbm_terrain_copy.lua", "rb"))
local source = f:read("*a"); f:close()
local helper = assert(source:match("(local function RepairRaisedTerminalHeightStrips.-)\n%-%- A few vanilla"))
local env = setmetatable({ Global = function(name)
	assert(name == "GridMinMax")
	return function() return 0, 65535 end
end }, { __index = _G })
local repair = assert(load(helper .. "\nreturn RepairRaisedTerminalHeightStrips", "terminal-strip", "t", env))()
local passed = 0
local function check(name, fn) fn(); passed = passed + 1; print("PASS " .. name) end
check("repair follows the resource raster that creates the strip", function()
	local raster = assert(source:match("(local function apply_native_raster.-)\n\tlocal pause"))
	assert(raster:find("RepairRaisedTerminalHeightStrips(grid)", 1, true))
	local stretch = assert(source:match("(local function StretchSourceToFull.-)\nend"))
	assert(not stretch:find("RepairRaisedTerminalHeightStrips", 1, true))
end)
local function grid(n, value, height)
	height = height or n
	local g = { changed = {}, original = value }
	function g:size() return n, height end
	function g:get(x, y)
		assert(x >= 0 and x < n and y >= 0 and y < height)
		local key = y * n + x
		return self.changed[key] or value(x, y)
	end
	function g:set(x, y, v)
		assert(v <= value(x, y), "repair must never raise terrain")
		assert(x < 3 or y < 3 or x >= n - 3 or y >= height - 3, "interior changed")
		self.changed[y * n + x] = v
	end
	return g
end
check("flat terrain and ordinary uphill/downhill slopes unchanged", function()
	for _, slope in ipairs({ -20, 0, 20 }) do
		local g = grid(256, function(x, y) return 20000 + slope * (x + y) end)
		local changed = repair(g); assert(not changed and next(g.changed) == nil)
	end
end)
for _, side in ipairs({ "left", "right", "top", "bottom" }) do
	check("narrow raised strip: " .. side, function()
		local function coords(x, y)
			if side == "left" then return x, y end
			if side == "right" then return 255 - x, y end
			if side == "top" then return y, x end
			return 255 - y, x
		end
		local g = grid(256, function(x, y)
			local depth, along = coords(x, y)
			return 20000 + depth * 10 + ((depth < 3 and along >= 60 and along <= 180) and 800 or 0)
		end)
		local changed, report = repair(g)
		assert(changed and report.width == 3 and report.max_drop == 800)
		assert(report.spans == side .. ":60-180", report.spans)
		for y = 0, 255 do for x = 0, 255 do
			local depth, along = coords(x, y)
			if depth < 3 and along >= 68 and along <= 172 then
				assert(g:get(x, y) == 20000 + depth * 10, "wall remains")
			elseif depth >= 3 or along < 60 or along > 180 then
				assert(g:get(x, y) == g.original(x, y), "unrelated terrain changed")
			end
		end end
	end)
end
check("isolated edge peaks and downward skirts unchanged", function()
	for _, case in ipairs({ "peak", "down", "wide" }) do
		local g = grid(256, function(x, y)
			local delta = 0
			if x >= (case == "wide" and 246 or 253) then
				if case == "peak" and y == 100 then delta = 800 end
				if case == "down" then delta = -800 end
				if case == "wide" then delta = 800 end
			end
			return 20000 + delta
		end)
		local changed = repair(g); assert(not changed and next(g.changed) == nil, case)
	end
end)
check("a strip reaching a corner leaves no endpoint wall", function()
	local g = grid(256, function(x, y) return 20000 + (x >= 253 and 800 or 0) end)
	local changed = repair(g); assert(changed)
	for y = 0, 255 do for x = 253, 255 do assert(g:get(x, y) == 20000) end end
end)
check("rectangular maps derive their own edge bounds", function()
	local g = grid(384, function(x, y)
		return 20000 + ((y >= 189 and x >= 80 and x <= 240) and 800 or 0)
	end, 192)
	local changed, report = repair(g)
	assert(changed and report.spans == "bottom:80-240")
	assert(g:get(160, 191) == 20000 and g:get(160, 188) == 20000)
end)
if arg[1] then
	check("captured 14N134W: only the small A0 terminal wall changes", function()
		local rawfile = assert(io.open(arg[1], "rb")); local bytes = rawfile:read("*a"); rawfile:close()
		assert(#bytes == 8192 * 8192 * 2)
		local g = grid(8192, function(x, y) return string.unpack("<I2", bytes, (y * 8192 + x) * 2 + 1) end)
		local changed, report = repair(g); assert(changed)
		for key in pairs(g.changed) do
			local x, y = key % 8192, math.floor(key / 8192)
			assert(x >= 8189 and y >= 160 and y <= 550, "changed unrelated edge/sector")
		end
		for y = 250, 450 do
			assert(g:get(8189, y) == 2 * g:get(8188, y) - g:get(8187, y), "wall remains")
		end
		print("REAL FOOTPRINT " .. report.spans .. " cells=" .. report.modified .. " max_drop=" .. report.max_drop)
	end)
end
print(passed .. " terminal-strip regression checks passed")

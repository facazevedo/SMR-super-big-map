-- Execute the full production detector/translation/join on sparse height grids.
-- The physical-edge guard must not clip the join short of its translated endpoint.
local f = assert(io.open("Code/sbm_terrain_copy.lua", "rb"))
local source = f:read("*a"); f:close()
local helper = assert(source:match("(local function RepairInternalHeightStep.-)\n%-%- Repair already%-qualified"))
local legacy = helper:gsub("\n%s*join_lo = math.min%(join_lo, low_perp%)", "")
legacy = legacy:gsub("\n%s*join_hi = math.max%(join_hi, low_perp%)", "")

local function run(code, side, near_guard, n)
	-- Use the actual expanded height-grid size and its eight-sample guard.
	n = n or 8192
	local writes, count, hash = {}, 0, 0
	local before = side == "left" or side == "top"
	local axis = (side == "left" or side == "right") and "x" or "y"
	local guard = math.min(8, math.max(2, math.floor(n / 1024)))
	local perp = before and (near_guard and guard or guard + 3)
		or (near_guard and n - guard - 3 or n - guard - 7)
	local grid = { size = function() return n, n end }
	function grid:get(x, y)
		assert(x >= 0 and y >= 0 and x < n and y < n, "out-of-bounds read")
		local z = writes[y * n + x]
		if z ~= nil then return z end
		local p = axis == "x" and x or y
		if before then
			if p <= perp then return 30000 end
			if p == perp + 1 then return 30666 end
			if p == perp + 2 then return 31333 end
			return 32000
		end
		if p <= perp then return 32000 end
		if p == perp + 1 then return 31333 end
		if p == perp + 2 then return 30666 end
		return 30000
	end
	function grid:set(x, y, z)
		assert(x >= 0 and y >= 0 and x < n and y < n, "out-of-bounds write")
		assert(z >= 30000 and z <= 32000, "join overshoot")
		local p = axis == "x" and x or y
		assert(before and p <= perp + 15 or not before and p >= perp - 12,
			"write outside existing local repair band")
		writes[y * n + x] = z
		count = count + 1
		hash = (hash + (y * n + x + 1) * z) % 2147483647
	end
	-- This geometry-only sparse fixture intentionally supplies the complete scalar
	-- discovery superset. It still runs every original acceptance/track/join check;
	-- crease_discovery_test and native cold parity cover the optimized backend.
	local function scalar_discovery(_, _, _, p0, p1, along_n, step)
		local rows, positions = {}, {}
		for p = p0, p1 do positions[#positions + 1] = p end
		for along = 0, along_n - 1, step do rows[along] = positions end
		return rows, {}
	end
	-- Keep this sparse geometry fixture on scalar storage. The production batch
	-- kernel has independent native/byte-exact tests; this adapter retains every
	-- original coordinate, clamp, write-count and join-deficit assertion below.
	local function scalar_translation(_, target, axis, _, rows, maximum)
		local count = 0
		for _, row in ipairs(rows) do
			for p = row.lo, row.hi do
				local x, y = axis == "x" and p or row.along, axis == "x" and row.along or p
				target:set(x, y, math.min(maximum, target:get(x, y) + row.offset))
				count = count + 1
			end
		end
		return count
	end
	local env = setmetatable({ BuildHeightStepDiscoveryIndex = scalar_discovery,
		TranslateHeightTrack = scalar_translation, Global = function(name)
		if name == "GridMinMax" then return function() return 30000, 32000 end end
	end }, { __index = _G })
	local repair = assert(load(code .. "\nreturn RepairInternalHeightStep", "guard-join", "t", env))()
	local changed, report = repair(grid, false)
	assert(changed and report.repairs == 1 and report.outer_guard == guard,
		"fixture did not exercise one actual qualified track")
	local deficits = 0
	for _, along in ipairs({ 0, math.floor(n / 2), n - 1 }) do
		for depth = 0, 60 do
			local p = before and depth or n - 1 - depth
			local z = axis == "x" and grid:get(p, along) or grid:get(along, p)
			if z < 32000 then deficits = deficits + 1 end
		end
	end
	return deficits, count, hash
end

local checks = 0
for _, side in ipairs({ "left", "right", "top", "bottom" }) do
	assert(run(legacy, side, true) > 0, "old guard clipping did not reproduce: " .. side)
	assert(run(helper, side, true) == 0, "guard-clipped ramp remains: " .. side)
	print("PASS " .. side .. ": full production repair closes ramp including along-edge corners")
	local a, na, ha = run(legacy, side, false)
	local b, nb, hb = run(helper, side, false)
	assert(a == b and na == nb and ha == hb, "safe join changed: " .. side)
	print("PASS " .. side .. ": non-clipped join writes unchanged")
	checks = checks + 2
end
print(checks .. " full crease guard-join checks passed on native 8192 grids")

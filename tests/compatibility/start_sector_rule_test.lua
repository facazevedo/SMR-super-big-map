-- Owner rule 2026-09-28: the revealed start sector is one of the four expanded sectors that
-- vanilla's stretched start sector covers - the one holding vanilla's Concrete deposit if it had
-- one, otherwise the one with the most resources; ties are broken in a fixed order.
local f = assert(io.open('Code/sbm_sector_exploration.lua', 'rb')); local source = f:read('*a'); f:close()
local block = assert(source:match('%-%- START_SECTOR_RULE_BEGIN(.-)%-%- START_SECTOR_RULE_END'))
local Choose = assert(load(block .. '\nreturn ChooseStartSector', 'start sector rule', 't', _G))()
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end

-- The stretched vanilla sector covers a 2x2 block of 100-unit sectors; its centre is (100, 100).
local function grid(order)
	local cells = {}
	for row = 0, 1 do for col = 0, 1 do
		cells[#cells + 1] = { sector = { id = col .. ":" .. row },
			x0 = col * 100, y0 = row * 100, x1 = (col + 1) * 100, y1 = (row + 1) * 100 }
	end end
	if order == "reversed" then
		local r = {}
		for i = #cells, 1, -1 do r[#r + 1] = cells[i] end
		return r
	end
	return cells
end
local function dep(x, y, amount, concrete) return { x = x, y = y, amount = amount, concrete = concrete } end
local function choose(deposits, order, cx, cy)
	local sector, rule = Choose(grid(order), deposits, cx or 100, cy or 100)
	return sector and sector.id, rule
end

-- Concrete wins over a richer sector.
local id, rule = choose({ dep(150, 50, 90000), dep(40, 160, 1000, true) })
check(id == "0:1" and rule == "concrete", "the Concrete sector must be chosen: " .. tostring(id))
-- Without Concrete, the most resources.
id, rule = choose({ dep(150, 50, 9000), dep(40, 160, 1000), dep(60, 170, 2000) })
check(id == "1:0" and rule == "most resources", "the richest sector must be chosen: " .. tostring(id))
-- Several Concrete sectors: the richest of them.
id = choose({ dep(150, 50, 90000), dep(40, 160, 1000, true), dep(150, 150, 500, true), dep(160, 160, 900) })
check(id == "1:1", "the richest Concrete sector must be chosen: " .. tostring(id))
-- Equal amounts: more deposits.
id = choose({ dep(150, 50, 3000), dep(40, 160, 1000), dep(60, 170, 2000) })
check(id == "0:1", "equal amounts must prefer more deposits: " .. tostring(id))
-- Equal amounts and counts: closest to the stretched centre.
id = choose({ dep(150, 50, 3000), dep(40, 160, 3000) }, nil, 160, 60)
check(id == "1:0", "a full tie must prefer the sector closest to the centre: " .. tostring(id))
-- Equidistant too: top-most, then left-most, whatever the list order.
for _, order in ipairs({ "grid", "reversed" }) do
	id = choose({ dep(150, 50, 3000), dep(40, 150, 3000), dep(150, 150, 3000), dep(50, 50, 3000) }, order)
	check(id == "0:0", "an exact tie must fall to the top-left sector (" .. order .. "): " .. tostring(id))
	id = choose({ dep(150, 50, 3000), dep(150, 150, 3000) }, order)
	check(id == "1:0", "an exact tie must fall to the top-most sector (" .. order .. "): " .. tostring(id))
end
-- A deposit on a shared border belongs to the sector that begins there (half-open bounds).
id = choose({ dep(100, 100, 5000), dep(50, 50, 4000) })
check(id == "1:1", "a border deposit must belong to the sector beginning there: " .. tostring(id))
-- A Concrete deposit outside the covered sectors cannot restrict the choice.
id, rule = choose({ dep(500, 500, 1000, true), dep(150, 150, 2000) })
check(id == "1:1" and rule == "most resources", "an unplaceable Concrete must not empty the choice: " .. tostring(id))
-- No opening deposits: no choice (the caller keeps the stretched centre).
check(Choose(grid(), {}, 100, 100) == nil, "no deposits must give no choice")

-- Production wiring: vanilla's own amount is staged, the reveal ranks by it, and the old
-- centre-only choice survives only as the no-deposit fallback.
check(source:find('pcall(marker.GetEstimatedAmount, marker)', 1, true) ~= nil,
	"staged records must carry vanilla's estimated amount")
check(source:find('ChooseStartSector(overlaps, start_deposits,', 1, true) ~= nil,
	"the start reveal must use the owner's rule")
check(source:find('selected, start_rule = SelectTransformedStartAnchor(overlaps, x0, y0, x1, y1), "centre"', 1, true) ~= nil,
	"the stretched centre must remain only as the fallback")
print("start sector rule: " .. checks .. " checks passed")

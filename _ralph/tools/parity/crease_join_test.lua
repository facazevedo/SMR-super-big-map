-- Run from the repository root: lua _ralph/tools/parity/crease_join_test.lua
-- Exercise the actual production join, not a second implementation of its formula.
local file = assert(io.open("Code/sbm_terrain_copy.lua", "rb"))
local source = file:read("*a"); file:close()
-- Include the production cache's lexical declaration when extracting its consumer.
local helper = assert(source:match("(local join_basis_cache = {}.-)\n\tlocal function offer_candidate")
	or source:match("(local function feather_join.-)\n\tlocal function offer_candidate"))
local passed = 0
local function check(name, fn) fn(); passed = passed + 1; print("PASS " .. name) end

local function run(v0, v1, slope0, slope1, span, axis, along)
	axis, along = axis or "x", along or 77
	local lo, hi, writes, values = 20, 20 + span, {}, {}
	values[lo], values[lo - 1] = v0, v0 - slope0
	values[hi], values[hi + 1] = v1, v1 + slope1
	local env = setmetatable({
		mx = 65535,
		at = function(a, p, row)
			assert(a == axis and row == along)
			return values[p]
		end,
		put = function(a, p, row, z)
			assert(a == axis and row == along)
			assert(p > lo and p < hi, "changed endpoint or outside repair band")
			assert(z >= math.min(v0, v1) and z <= math.max(v0, v1), "join overshoot")
			values[p], writes[#writes + 1] = z, p
		end,
	}, { __index = _G })
	local join = assert(load(helper .. "\nreturn feather_join", "crease-join", "t", env))()
	local count = join(axis, along, lo, hi)
	if span < 4 then assert(count == 0 and #writes == 0); return values end
	assert(count == span - 1 and #writes == span - 1)
	assert(values[lo] == v0 and values[hi] == v1)
	for p = lo + 1, hi do
		if v1 >= v0 then assert(values[p] >= values[p - 1], "new peak or trough")
		else assert(values[p] <= values[p - 1], "new peak or trough") end
	end
	return values
end

check("positive control: old extrapolation creates a false peak", function()
	local v0, v1, s0, s1, span, t = 32000, 30000, 300, -800, 24, 0.5
	local smooth = t^3 * (t * (t * 6 - 15) + 10)
	local left, right = v0 + s0 * span * t, v1 + s1 * span * (t - 1)
	assert(left + (right - left) * smooth > math.max(v0, v1) + 4000)
	run(v0, v1, s0, s1, span)
end)
check("uphill and downhill joins stay bounded under opposing steep slopes", function()
	for _, endpoints in ipairs({ {1000, 50000}, {50000, 1000}, {30000, 32000}, {32000, 30000} }) do
		for _, a in ipairs({-10000, -800, 0, 300, 10000}) do
			for _, b in ipairs({-10000, -800, 0, 300, 10000}) do
				for _, span in ipairs({4, 8, 24, 42, 64}) do run(endpoints[1], endpoints[2], a, b, span) end
			end
		end
	end
end)
check("equal endpoints cannot create a ridge or trench", function()
	for _, z in ipairs({0, 1, 32000, 65535}) do run(z, z, 10000, -10000, 32) end
end)
check("compatible straight slopes are preserved exactly", function()
	for _, slope in ipairs({-100, -3, 0, 3, 100}) do
		local values = run(30000, 30000 + 32 * slope, slope, slope, 32)
		for p = 20, 52 do assert(values[p] == 30000 + (p - 20) * slope) end
	end
end)
check("axis, side direction and along coordinate do not change the result", function()
	for _, axis in ipairs({"x", "y"}) do
		for _, along in ipairs({0, 77, 8191}) do
			local a = run(32000, 30000, 300, -800, 24, axis, along)
			local b = run(30000, 32000, 800, -300, 24, axis, along)
			for p = 20, 44 do assert(math.abs(a[p] - b[64 - p]) <= 1) end
		end
	end
end)
check("short joins do not read or write outside their bounds", function()
	for span = 0, 3 do run(32000, 30000, 300, -800, span) end
end)
check("tiny height differences and U16 limits remain finite and monotone", function()
	for _, pair in ipairs({{0, 1}, {1, 0}, {65534, 65535}, {65535, 65534}, {0, 65535}}) do
		run(pair[1], pair[2], 65535, -65535, 64)
	end
end)
check("safe endpoint slopes meet the original field within sample quantization", function()
	local values = run(10000, 50000, 20, 30, 1000)
	assert(math.abs(values[21] - values[20] - 20) <= 1)
	assert(math.abs(values[1020] - values[1019] - 30) <= 1)
	assert(math.abs(values[22] - 2 * values[21] + values[20]) <= 2)
	assert(math.abs(values[1020] - 2 * values[1019] + values[1018]) <= 2)
end)
print(passed .. " bounded crease-join checks passed")

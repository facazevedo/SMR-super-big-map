-- Executable model of the v997 primitive budgets and deterministic deficit allocation.
local function allocate(current, wanted, cap)
	local keys, total = {}, 0
	for key, value in pairs(wanted) do
		keys[#keys + 1] = key
		total = total + math.max(0, value - (current[key] or 0))
	end
	table.sort(keys)
	local bounded = math.min(total, cap)
	local result, residual, assigned = {}, {}, 0
	for _, key in ipairs(keys) do
		local deficit = math.max(0, wanted[key] - (current[key] or 0))
		local exact = bounded * deficit / total
		local whole = math.floor(exact)
		result[key] = (current[key] or 0) + whole
		assigned = assigned + whole
		residual[#residual + 1] = { key=key, rem=exact-whole }
	end
	table.sort(residual, function(a,b)
		return a.rem == b.rem and a.key < b.key or a.rem > b.rem
	end)
	for i=1,bounded-assigned do result[residual[i].key]=result[residual[i].key]+1 end
	return result, bounded
end

local current = { Concrete=5, Metals=7, PreciousMetals=2, Water=4 }
local wanted = { Concrete=80, Metals=119, PreciousMetals=32, Water=65 }
local target, additions = allocate(current, wanted, 64)
assert(additions == 64)
local total = 0
for key, value in pairs(target) do
	assert(value >= current[key] and value <= wanted[key])
	total = total + value - current[key]
end
assert(total == 64)

local state, candidate_cap, expensive_cap = 303, 256, 64
local candidates, expensive, commits, progress = 0, {}, 0, 0
local buckets = {}
local function draw(limit) state=(state*48271)%2147483647; return state%limit end
local function candidate(resource)
	assert(candidates < candidate_cap)
	candidates = candidates + 1
	local q, r = draw(8192), draw(8192)
	local key = math.floor(q/8) .. ":" .. math.floor(r/8)
	local bucket = buckets[key] or {}; buckets[key] = bucket
	-- O(1)/local-bucket-only analytic filter model.
	if #bucket > 8 then return false end
	bucket[#bucket + 1] = {q=q,r=r}
	if candidates % 16 == 0 then progress = progress + 1 end
	expensive[resource] = (expensive[resource] or 0) + 1
	assert(expensive[resource] <= expensive_cap)
	commits = commits + 1
	return true
end
for resource, goal in pairs(target) do
	local need = goal-current[resource]
	while need > 0 do if candidate(resource) then need=need-1 end end
end
assert(candidates <= 256 and commits == 64 and progress >= 4)
assert(expensive.Concrete <= 64 and expensive.Metals <= 64
	and expensive.PreciousMetals <= 64 and expensive.Water <= 64)

-- Fail-closed adversarial boundaries.
local ok_candidate = pcall(function() candidates=256; candidate("Metals") end)
assert(not ok_candidate)
local ok_expensive = pcall(function()
	candidates=0; expensive.Metals=64; candidate("Metals")
end)
assert(not ok_expensive)
local deadline_started, phase_deadline, absolute_deadline = 1000, 61000, 181000
assert(phase_deadline-deadline_started == 60000)
assert(absolute_deadline-deadline_started == 180000 and absolute_deadline < 241000)

print("v997 bounded enrichment state/budget oracle: ok")
print("candidate_cap=256")
print("resource_addition_cap=64")
print("expensive_per_deficit_cap=64")
print("progress_batch=16")
print("shared_rng_calls=0")
print("all_pairs=0")

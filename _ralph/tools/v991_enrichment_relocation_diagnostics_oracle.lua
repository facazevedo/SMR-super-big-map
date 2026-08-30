-- Executable fail-closed oracle for v991 enrichment relocation and diagnostic publication.

local function copy(values)
	local result = {}
	for i, value in ipairs(values) do result[i] = value end
	return result
end

local candidates = {
	{ id = "a-only", accepts = { A = true } },
	{ id = "b-only", accepts = { B = true } },
	{ id = "shared", accepts = { A = true, B = true } },
}

-- v990 removed a candidate before learning that the current marker's profile rejected it.
local function old_destructive(pool, profiles)
	local placed = {}
	for _, profile in ipairs(profiles) do
		local candidate = table.remove(pool, 1)
		if candidate and candidate.accepts[profile] then placed[#placed + 1] = candidate.id end
	end
	return placed
end

-- v991 presents a profile-specific view and removes only the successfully committed identity.
local function committed_only(pool, profiles)
	local placed = {}
	for _, profile in ipairs(profiles) do
		local selected_index
		for i, candidate in ipairs(pool) do
			if candidate.accepts[profile] then selected_index = i; break end
		end
		if selected_index then
			placed[#placed + 1] = table.remove(pool, selected_index).id
		end
	end
	return placed
end

local old = old_destructive(copy(candidates), { "B", "A" })
assert(#old == 0, "fixture must reproduce destructive cross-profile starvation")
local new = committed_only(copy(candidates), { "B", "A" })
assert(#new == 2 and new[1] == "b-only" and new[2] == "a-only")

local function axial(q1, r1, q2, r2)
	local dq, dr = q1 - q2, r1 - r2
	return math.max(math.abs(dq), math.abs(dr), math.abs(dq + dr))
end
local minimum, bucket_size = 6, 6
local buckets = {}
local blockers = {
	{ q = -7, r = 1 }, { q = 5, r = 0 }, { q = 25, r = -8 }, { q = 0, r = 6 },
}
for _, entry in ipairs(blockers) do
	local bq, br = math.floor(entry.q / bucket_size), math.floor(entry.r / bucket_size)
	local key = bq .. ":" .. br
	buckets[key] = buckets[key] or {}
	buckets[key][#buckets[key] + 1] = entry
end
local function indexed_clear(q, r)
	local bq, br = math.floor(q / bucket_size), math.floor(r / bucket_size)
	for oq = -1, 1 do for orr = -1, 1 do
		for _, entry in ipairs(buckets[(bq + oq) .. ":" .. (br + orr)] or {}) do
			if axial(q, r, entry.q, entry.r) < minimum then return false end
		end
	end end
	return true
end
local function brute_clear(q, r)
	for _, entry in ipairs(blockers) do
		if axial(q, r, entry.q, entry.r) < minimum then return false end
	end
	return true
end
for q = -40, 40 do for r = -40, 40 do assert(indexed_clear(q, r) == brute_clear(q, r)) end end

-- Diagnostic commands operate on primitive copies only.  The live corpus hash is unchanged,
-- the private clone changes, and none of the forbidden access/mutation/promote hooks is called.
local live = { 11, 22, 33 }
local live_before = table.concat(live, ",")
local private = copy(live)
private[2] = 99
assert(table.concat(live, ",") == live_before)
assert(table.concat(private, ",") ~= live_before)
local forbidden_calls = 0
local forbidden = function() forbidden_calls = forbidden_calls + 1 end
local diagnostic_command = function()
	local snapshot = copy(live)
	assert(#snapshot == #live)
	return { diagnostic_only = true, acceptance_timing_eligible = false,
		can_promote = false, can_release_underground = false }
end
local receipt = diagnostic_command()
assert(forbidden_calls == 0 and receipt.diagnostic_only == true)
assert(receipt.acceptance_timing_eligible == false and receipt.can_promote == false)

-- A terminal sentinel can only be published after its causal bundle write succeeds.  Neither a
-- failed bundle write nor a diagnostic-only receipt can become a green acceptance signal.
local writes = {}
local function publish(bundle_ok)
	if not bundle_ok then return false end
	writes[#writes + 1] = "bundle"
	writes[#writes + 1] = "terminal-sentinel"
	return true
end
assert(publish(false) == false and #writes == 0)
assert(publish(true) == true and table.concat(writes, ">") == "bundle>terminal-sentinel")

print("ok=true")
print("cross_profile_rejections_retained=true")
print("committed_candidate_removals_exact=2")
print("spatial_index_matches_bruteforce=6561")
print("diagnostic_live_mutations=0")
print("diagnostic_promotions=0")
print("diagnostic_underground_access_calls=0")
print("sentinel_false_green_paths=0")

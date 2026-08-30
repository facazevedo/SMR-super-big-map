-- Executable bounded-work/deadline oracle for the v992 enrichment relocation transaction.
local limits = {
	maximum_candidates = 512,
	maximum_markers = 8,
	neighbourhood_per_marker = 64,
	global_samples = 4096,
	commit_attempts_per_marker = 64,
}
assert(limits.maximum_markers * limits.neighbourhood_per_marker == 512)
assert(limits.maximum_candidates == 512 and limits.global_samples == 4096)
assert(limits.commit_attempts_per_marker == 64)

local function bounded_survivor(markers, corpus)
	local moved, unresolved, commits = {}, 0, 0
	for _, marker in ipairs(markers) do
		local selected
		for _, candidate in ipairs(corpus) do
			-- This models the exact conjunction; no failed predicate can be waived by another profile.
			if not candidate.committed and candidate.terrain and candidate.reachable
				and candidate.unobstructed and candidate.deposit_clear
				and candidate.fallback_spacing and candidate.profile[marker.profile] then
				selected = candidate
				break
			end
		end
		if selected then
			selected.committed = true
			commits = commits + 1
			moved[#moved + 1] = selected.id
		else
			unresolved = unresolved + 1
		end
	end
	return unresolved == 0, moved, commits
end

local markers = {
	{ profile = "subsurface" }, { profile = "terrain" },
	{ profile = "metals" }, { profile = "water" },
}
local corpus = {
	{ id="s", terrain=true, reachable=true, unobstructed=true, deposit_clear=true,
		fallback_spacing=true, profile={subsurface=true} },
	{ id="t", terrain=true, reachable=true, unobstructed=true, deposit_clear=true,
		fallback_spacing=true, profile={terrain=true} },
	{ id="m", terrain=true, reachable=true, unobstructed=true, deposit_clear=true,
		fallback_spacing=true, profile={metals=true} },
	{ id="w", terrain=true, reachable=true, unobstructed=true, deposit_clear=true,
		fallback_spacing=true, profile={water=true} },
}
local ok, moved, commits = bounded_survivor(markers, corpus)
assert(ok and #moved == 4 and commits == 4)

for _, rejected_key in ipairs({
	"terrain", "reachable", "unobstructed", "deposit_clear", "fallback_spacing",
}) do
	local candidate = { id="bad", terrain=true, reachable=true, unobstructed=true,
		deposit_clear=true, fallback_spacing=true, profile={subsurface=true} }
	candidate[rejected_key] = false
	local accepted = bounded_survivor({markers[1]}, {candidate})
	assert(accepted == false, rejected_key .. " rejection was weakened")
end

-- A monotonic deadline is checked before every bounded batch and before each commit. Expiry returns
-- a sticky failure without committing the candidate currently under consideration.
local now, deadline, mutations = 1000, 1100, 0
local function checked_loop(count)
	for i = 1, count do
		if i % 16 == 1 and now >= deadline then return false, i end
		now = now + 17
	end
	if now >= deadline then return false, count + 1 end
	mutations = mutations + 1
	return true
end
local deadline_ok, stopped_at = checked_loop(512)
assert(deadline_ok == false and stopped_at <= 17 and mutations == 0)

print("ok=true")
print("maximum_candidates=512")
print("maximum_neighbourhood_samples=512")
print("maximum_global_samples=4096")
print("maximum_commit_attempts=512")
print("survivor_unresolved=0")
print("deadline_expired_candidate_commit=0")
print("rule_waivers=0")

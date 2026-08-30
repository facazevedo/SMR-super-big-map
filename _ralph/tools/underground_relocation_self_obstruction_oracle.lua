-- Executable offline oracle for relocation's pre-move obstruction/post-move terrain intersection.

local function relocate(case)
	-- Full native obstruction is authoritative while the marker is still at its old coordinate.
	if case.unrelated_blocker or case.precheck_failure then return false, "precheck" end
	if case.repulsion_ok ~= true then return false, "repulsion" end
	local actual_x = case.drift and case.x + 1 or case.x
	local actual_y = case.y
	local exact = actual_x == case.x and actual_y == case.y
	if not exact then return false, "drift" end
	if case.terrain_ok ~= true then return false, "terrain" end
	-- The live native check would now see the moved marker itself.  It is deliberately not reused;
	-- no unrelated object can appear between the synchronous precheck and SetPos.
	return true, case.native_postcheck_sees_self and "self ignored by certificate" or "accepted"
end

local ok, reason = relocate({ x = 10, y = 20, repulsion_ok = true, terrain_ok = true,
	native_postcheck_sees_self = true })
assert(ok and reason == "self ignored by certificate")
assert(relocate({ x = 10, y = 20, repulsion_ok = true, terrain_ok = true,
	unrelated_blocker = true }) == false)
assert(relocate({ x = 10, y = 20, repulsion_ok = true, terrain_ok = true,
	precheck_failure = true }) == false)
assert(relocate({ x = 10, y = 20, repulsion_ok = true, terrain_ok = true,
	drift = true }) == false)
assert(relocate({ x = 10, y = 20, repulsion_ok = true, terrain_ok = false }) == false)
assert(relocate({ x = 10, y = 20, repulsion_ok = false, terrain_ok = true }) == false)

print("ok=true")
print("self_obstructed_exact_accepts=1")
print("unrelated_blocker_rejects=1")
print("precheck_failure_rejects=1")
print("drift_rejects=1")
print("terrain_rejects=1")
print("repulsion_rejects=1")

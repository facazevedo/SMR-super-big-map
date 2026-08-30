-- Executable, engine-free oracle for the v996 persisted pending/process-local owner contract.
local allowed = {
	["view-switch"] = true,
	["elevator-transfer"] = true,
	["authorized-map-load"] = true,
}

local function new_state()
	return {
		state = "pending", plan_id = "v1:2:41:101:202:303", seed = 303,
		first_trigger_kind = "", trigger_calls = 0, attempts = 0,
		completion_count = 0, failure = "", markers = {}, owner = nil,
	}
end

local function ensure(s, trigger, runner)
	assert(allowed[trigger], "unauthorized trigger accepted")
	if s.state == "complete" then return true, "noop" end
	if s.state == "failed" then return false, s.failure end
	assert(s.state == "pending" and s.completion_count == 0 and s.failure == "")
	s.trigger_calls = s.trigger_calls + 1
	if s.first_trigger_kind == "" then s.first_trigger_kind = trigger end
	if s.owner then
		assert(s.owner.plan_id == s.plan_id, "join accepted wrong owner")
		return nil, "join"
	end
	s.attempts = s.attempts + 1
	if s.attempts > 2 then
		s.state, s.failure = "failed", "resume budget exceeded"
		return false, s.failure
	end
	-- Persisted state deliberately remains pending. This identity disappears on reload.
	local owner = { plan_id = s.plan_id, attempt = s.attempts }
	s.owner = owner
	local ok, reason = runner(s, owner)
	assert(s.owner == owner, "owner identity drift")
	s.owner = nil
	if not ok then
		s.state, s.failure = "failed", tostring(reason)
		return false, s.failure
	end
	s.state, s.completion_count = "complete", 1
	return true
end

local function exact_runner(s, owner)
	assert(s.state == "pending", "process-local running state leaked into persistence")
	assert(owner.attempt == s.attempts and owner.plan_id == s.plan_id)
	-- Revalidate immediately before each idempotent commit. A player blocker appearing between
	-- selection and commit rejects that candidate; the next deterministic candidate is used.
	local candidates = { "occupied-after-selection", "clean-a", "clean-b" }
	for _, candidate in ipairs(candidates) do
		local live_blocked = candidate == "occupied-after-selection"
		if not live_blocked and not s.markers[candidate] then s.markers[candidate] = true end
	end
	return s.markers["clean-a"] and s.markers["clean-b"]
end

do
	local s = new_state()
	local owner = { plan_id = s.plan_id, map = "underground" }
	s.owner = owner
	local capability = {}
	capability.authorize = function(presented, map, plan)
		return presented == capability and s.owner == owner
			and map == owner.map and plan == owner.plan_id
	end
	assert(capability.authorize(capability, "underground", s.plan_id) == true)
	assert(capability.authorize({}, "underground", s.plan_id) == false)
	assert(capability.authorize(capability, "surface", s.plan_id) == false)
	assert(capability.authorize(capability, "underground", "forged") == false)
	s.owner = nil -- module/save-load split loses the process-local identity
	assert(capability.authorize(capability, "underground", s.plan_id) == false)
end

for _, trigger in ipairs({ "view-switch", "elevator-transfer", "authorized-map-load" }) do
	local s = new_state()
	assert(ensure(s, trigger, exact_runner) == true)
	assert(s.first_trigger_kind == trigger and s.trigger_calls == 1)
	assert(s.attempts == 1 and s.completion_count == 1 and s.state == "complete")
	assert(ensure(s, trigger, function() error("complete reran") end) == true)
	assert(s.attempts == 1 and s.completion_count == 1)
end

do
	local s = new_state()
	local joined
	assert(ensure(s, "view-switch", function(live)
		local result, reason = ensure(live, "elevator-transfer", exact_runner)
		joined = result == nil and reason == "join"
		return exact_runner(live, live.owner)
	end) == true)
	assert(joined and s.trigger_calls == 2 and s.first_trigger_kind == "view-switch")
	assert(s.completion_count == 1)
end

do
	local s = new_state()
	s.attempts = 1 -- a save captured persisted pending after its process-local owner disappeared
	assert(s.owner == nil and s.state == "pending")
	assert(ensure(s, "authorized-map-load", exact_runner) == true)
	assert(s.attempts == 2 and s.completion_count == 1)
end

do
	local s = new_state()
	assert(ensure(s, "view-switch", function() return false, "audit failed" end) == false)
	assert(s.state == "failed" and s.failure == "audit failed")
	assert(ensure(s, "elevator-transfer", exact_runner) == false)
	assert(s.completion_count == 0 and next(s.markers) == nil)
end

do
	local s = new_state()
	s.attempts = 2
	assert(ensure(s, "view-switch", exact_runner) == false)
	assert(s.state == "failed" and s.failure == "resume budget exceeded")
end

print("v996 lazy enrichment state/reentry/transport oracle: ok")

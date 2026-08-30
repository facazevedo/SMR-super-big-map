-- Executable closure/context oracle for v990's private materialization capability.
-- It models the exact lifecycle: the old module owns the live transaction, a generator reload
-- publishes a fresh module/weak table, and the old synchronous call stack carries one capability
-- through pipeline and terrain validation without consulting the replacement module.

local surface = { mapdata = { Environment = "Surface" } }
local underground = { mapdata = { Environment = "Underground" } }
local descriptor = {
	state = "generating", map_slot = 2, materialization_attempts = 1,
	generation_count = 1, reserved_seed = 71,
}
local report = {
	materialization_running = true, materialization_route = "change-current-map-slot",
}
local maps = { surface, underground }
local old_lazy = { LIVE_MATERIALIZATION_TRANSACTIONS = setmetatable({}, { __mode = "k" }) }
local owner = {
	descriptor = descriptor, report = report, map_slot = 2, reserved_seed = 71,
	route = report.materialization_route, attempt = 1,
}
old_lazy.LIVE_MATERIALIZATION_TRANSACTIONS[surface] = owner

local current_lazy = old_lazy
local function owned_materialization(lazy)
	local live = lazy.LIVE_MATERIALIZATION_TRANSACTIONS[surface]
	if type(live) ~= "table" then return false, nil, "process_local_owner=nil" end
	if live ~= owner or live.descriptor ~= descriptor or live.report ~= report then
		return false, nil, "owner identity mismatch"
	end
	if descriptor.state ~= "generating" or descriptor.generation_count ~= 1
		or maps[descriptor.map_slot] ~= underground then
		return false, nil, "live transaction state mismatch"
	end
	return true, "materialization-deferred-pipeline"
end

local capability = {
	schema = "SuperBigMap/v990/lazy-materialization-private-capability",
	phase = "materialization-deferred-pipeline", attempt = 1,
}
local context = {
	schema = capability.schema, phase = capability.phase, surface = surface,
	descriptor = descriptor, report = report, underground = underground,
	owner_identity = true,
}
local authorize_depth, authorize_calls = 0, 0
capability.authorize = function(presented, expected_map)
	if authorize_depth ~= 0 then return false, nil, "capability authorizer re-entered" end
	authorize_depth, authorize_calls = 1, authorize_calls + 1
	local function reject(reason)
		authorize_depth = 0
		return false, nil, reason
	end
	if presented ~= capability then return reject("capability identity mismatch") end
	if expected_map ~= underground then return reject("map identity mismatch") end
	if old_lazy.LIVE_MATERIALIZATION_TRANSACTIONS[surface] ~= owner then
		return reject("weak owner lost")
	end
	if owner.descriptor ~= descriptor or owner.report ~= report then
		return reject("owner payload drift")
	end
	local live, phase, reason = owned_materialization(old_lazy)
	if live ~= true or phase ~= "materialization-deferred-pipeline" then
		return reject(reason or phase)
	end
	if maps[descriptor.map_slot] ~= underground then return reject("published map drift") end
	context.authorization_calls, context.authorization_depth = authorize_calls, authorize_depth
	authorize_depth = 0
	return true, context
end

-- The generator reload publishes a different module table and a fresh empty weak owner table.
current_lazy = { LIVE_MATERIALIZATION_TRANSACTIONS = setmetatable({}, { __mode = "k" }) }
local ambient_ok, _, ambient_reason = owned_materialization(current_lazy)
assert(ambient_ok == false and ambient_reason == "process_local_owner=nil")

local pipeline_ok, pipeline_context = capability.authorize(capability, underground)
assert(pipeline_ok == true and pipeline_context == context)
assert(pipeline_context.surface == surface and pipeline_context.descriptor == descriptor)
assert(pipeline_context.report == report and pipeline_context.underground == underground)
assert(pipeline_context.authorization_calls == 1 and pipeline_context.authorization_depth == 1)
local terrain_ok, terrain_context = capability.authorize(capability, underground)
assert(terrain_ok == true and terrain_context == pipeline_context)
assert(terrain_context.authorization_calls == 2 and terrain_context.authorization_depth == 1)

local function rejected(presented, expected_map)
	local ok, accepted = pcall(capability.authorize, presented, expected_map)
	return ok and accepted == false
end
assert(rejected({}, underground))
assert(rejected(capability, {}))

local original_owner = old_lazy.LIVE_MATERIALIZATION_TRANSACTIONS[surface]
old_lazy.LIVE_MATERIALIZATION_TRANSACTIONS[surface] = nil
assert(rejected(capability, underground))
old_lazy.LIVE_MATERIALIZATION_TRANSACTIONS[surface] = original_owner

owner.descriptor = {}
assert(rejected(capability, underground))
owner.descriptor = descriptor
owner.report = {}
assert(rejected(capability, underground))
owner.report = report

descriptor.generation_count = 0
assert(rejected(capability, underground))
descriptor.generation_count = 1
maps[2] = {}
assert(rejected(capability, underground))
maps[2] = underground

-- Capability/function identities never enter persistent state.
for _, persistent in ipairs({ surface, underground, descriptor, report }) do
	for _, value in pairs(persistent) do
		assert(value ~= capability and value ~= capability.authorize)
	end
end

print("ok=true")
print("module_reload_ambient_owner_rejected=true")
print("old_closure_capability_authorized=true")
print("pipeline_and_terrain_context_identity_exact=true")
print("authorization_depth_exact=true")
print("wrong_capability_map_owner_descriptor_report_phase_rejected=true")
print("persistent_capability_fields=0")

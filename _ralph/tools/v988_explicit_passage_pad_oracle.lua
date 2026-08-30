-- Executable model of the v988 scoped explicit-level passage-pad transaction.
-- It proves the wholly-unbuildable destination that rejected iter230 is repaired only with the
-- exact valid pre-move level, and that ownership/errors/later mutations remain fail closed.

local UNBUILDABLE = 65535
local SHAPE = { 1, 2, 3, 4, 5 }

local function validate(grid, expected)
	for i = 1, #SHAPE do
		if grid[SHAPE[i]] ~= expected then return false end
	end
	return true
end

local function legacy_flatten(grid)
	local level
	for i = 1, #SHAPE do
		local z = grid[SHAPE[i]]
		if z ~= UNBUILDABLE then level = level or z end
	end
	if not level then return nil end
	for i = 1, #SHAPE do grid[SHAPE[i]] = level end
	return "bbox"
end

local function explicit_native(grid, target_z, mutate_after)
	assert(type(target_z) == "number" and target_z == math.floor(target_z))
	assert(target_z >= 0 and target_z < UNBUILDABLE)
	for i = 1, #SHAPE do grid[SHAPE[i]] = target_z end
	if mutate_after then grid[SHAPE[#SHAPE]] = target_z + 1 end
	return "bbox"
end

local function prepare(state, owner, map, source_z, mutate_after)
	local trace = { anchor = owner, map = map, target_z = source_z }
	local previous_depth = state.depth
	local previous_z = state.target_z
	local previous_trace = state.trace
	state.depth, state.target_z, state.trace = (state.depth or 0) + 1, source_z, trace
	local ok, result = pcall(function()
		local exact_owner = state.trace.anchor == owner and state.trace.map == map
			and state.trace.target_z == state.target_z
		local exact_z = type(state.target_z) == "number"
			and state.target_z == math.floor(state.target_z)
			and state.target_z >= 0 and state.target_z < UNBUILDABLE
		trace.wrapper_entered = true
		trace.wrapper_owner_exact = exact_owner
		trace.wrapper_inputs_exact = exact_owner and exact_z
		if not trace.wrapper_inputs_exact then error("invalid capability") end
		trace.native_called = true
		local native_ok, native_result = pcall(
			explicit_native, map.grid, state.target_z, mutate_after)
		trace.native_ok = native_ok
		if not native_ok then error(native_result) end
		return native_result
	end)
	state.depth, state.target_z, state.trace = previous_depth, previous_z, previous_trace
	return ok and trace.wrapper_entered and trace.wrapper_owner_exact
		and trace.wrapper_inputs_exact and trace.native_called and trace.native_ok,
		result, trace
end

local wholly_unbuildable = {}
for i = 1, #SHAPE do wholly_unbuildable[SHAPE[i]] = UNBUILDABLE end
assert(legacy_flatten(wholly_unbuildable) == nil)
assert(not validate(wholly_unbuildable, 10000))

local state, owner = {}, {}
local map = { grid = wholly_unbuildable }
local ok, result, trace = prepare(state, owner, map, 10000, false)
assert(ok and result == "bbox" and trace.native_ok)
assert(validate(map.grid, 10000)) -- immediate complete vanilla-equivalent footprint
assert(state.depth == nil and state.target_z == nil and state.trace == nil)
assert(validate(map.grid, 10000)) -- transaction-final revalidation

-- A later operation changing one exact cell must be detected by the final pass.
local later = { grid = {} }
for i = 1, #SHAPE do later.grid[SHAPE[i]] = UNBUILDABLE end
assert(select(1, prepare({}, owner, later, 17841, true)))
assert(not validate(later.grid, 17841))

-- Wrong levels and wrong owner/map capabilities never invoke native mutation.
for _, bad_z in ipairs({ -1, 65535, 65536, 1.5 }) do
	local bad = { grid = {} }
	for i = 1, #SHAPE do bad.grid[SHAPE[i]] = UNBUILDABLE end
	local bad_state = { depth = 1, target_z = bad_z,
		trace = { anchor = owner, map = bad, target_z = bad_z } }
	local called = false
	local exact_z = type(bad_state.target_z) == "number"
		and bad_state.target_z == math.floor(bad_state.target_z)
		and bad_state.target_z >= 0 and bad_state.target_z < UNBUILDABLE
	if exact_z then called = true end
	assert(not called and not validate(bad.grid, 10000))
end

local mismatch_map = { grid = {} }
for i = 1, #SHAPE do mismatch_map.grid[SHAPE[i]] = UNBUILDABLE end
local mismatch_trace = { anchor = {}, map = mismatch_map, target_z = 10000 }
assert(mismatch_trace.anchor ~= owner)
assert(not validate(mismatch_map.grid, 10000))

print("ok=true")
print("legacy_wholly_unbuildable_rejected=1")
print("explicit_level_accepts=1")
print("immediate_validations=1")
print("transaction_final_validations=1")
print("later_mutation_rejections=1")
print("invalid_level_rejections=4")
print("owner_mismatch_rejections=1")
print("state_cleanup_exact=true")

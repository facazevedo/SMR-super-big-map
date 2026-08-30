-- Executable offline oracle for the process-local final-passage-pad flatten capability.

local state = {}
local original_calls = 0
local function original()
	original_calls = original_calls + 1
	return true
end

local function wrapper(flatten_unbuildable, expanded_elevator)
	local owned = flatten_unbuildable
		and (tonumber(state.passage_pad_preparation_depth) or 0) > 0
	if expanded_elevator and not owned then return nil end
	return original()
end

local function prepare(raise)
	local previous = tonumber(state.passage_pad_preparation_depth) or 0
	state.passage_pad_preparation_depth = previous + 1
	local ok, result = pcall(function()
		if raise then error("native flatten failed") end
		return wrapper("flatten unbuildable", true)
	end)
	state.passage_pad_preparation_depth = previous > 0 and previous or nil
	return ok, result
end

assert(wrapper(nil, true) == nil and original_calls == 0, "ambient Elevator flatten escaped guard")
assert(wrapper("flatten unbuildable", true) == nil and original_calls == 0,
	"truthy vanilla argument incorrectly became authority")
local ok, value = prepare(false)
assert(ok and value == true and original_calls == 1, "owned final-pad flatten did not execute")
assert(state.passage_pad_preparation_depth == nil, "owner leaked after success")
ok = prepare(true)
assert(ok == false and state.passage_pad_preparation_depth == nil,
	"owner leaked after native failure")
assert(wrapper("flatten unbuildable", true) == nil and original_calls == 1,
	"ambient flatten escaped after failure")
state.passage_pad_preparation_depth = 2
ok, value = prepare(false)
assert(ok and value == true and state.passage_pad_preparation_depth == 2,
	"nested owner depth was not restored exactly")

print("ok=true")
print("ambient_rejections=3")
print("owned_calls=2")
print("success_cleanup=true")
print("failure_cleanup=true")
print("nested_restore=true")

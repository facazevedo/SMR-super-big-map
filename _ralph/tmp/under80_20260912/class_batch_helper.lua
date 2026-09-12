-- Native list negatives can avoid repeated protected scalar queries. Capture
-- identities only to qualify the known native pair; never cache class results.
local canonical_single_kind = Engine.IsKindOf
local canonical_safe_call = Engine.SafeCall
local native_single_kind = Engine.Global("IsKindOf")
local native_many_kinds = Engine.Global("IsKindOfClasses")
-- debug is intentionally unavailable in the mod sandbox. Use the standard
-- serialization distinction instead: Lua functions dump, native C functions
-- do not. Verify both sides once; an unavailable/unexpected protocol disables
-- batching rather than changing the sandbox or assuming a function is native.
local string_api = Engine.Global("string")
local function_dump = type(string_api) == "table" and string_api.dump
local native_dump_error
if type(function_dump) == "function" then
	local lua_ok, lua_bytes = pcall(function_dump, function() return true end)
	local native_ok, native_error = pcall(function_dump, pcall)
	if lua_ok and type(lua_bytes) == "string" and not native_ok and type(native_error) == "string" then
		native_dump_error = native_error
	end
end
local function IsNativeClassPrimitive(fn)
	if type(fn) ~= "function" or not native_dump_error then return false end
	local ok, value = pcall(function_dump, fn)
	return not ok and value == native_dump_error
end
local native_kind_pair = IsNativeClassPrimitive(native_single_kind)
	and IsNativeClassPrimitive(native_many_kinds)

-- Return the first matching list entry and the scalar predicate's value.
-- A negative native result is final only while every qualified identity is live.
-- Positive/failed native queries, custom helpers and rebinding retain the exact
-- original ordered scalar calls (including the last false/nil return value).
function Engine.FirstKindOf(obj, classes, single_kind)
	single_kind = single_kind or Engine.IsKindOf
	if native_kind_pair and type(obj) == "table" and #classes > 0
		and single_kind == canonical_single_kind
		and Engine.IsKindOf == canonical_single_kind
		and Engine.SafeCall == canonical_safe_call
		and rawget(_G, "IsKindOf") == native_single_kind
		and rawget(_G, "IsKindOfClasses") == native_many_kinds then
		local ok, value = pcall(native_many_kinds, obj, classes)
		if ok and (value == false or value == nil) then return nil, false end
	end
	local last_value
	for i = 1, #classes do
		last_value = single_kind(obj, classes[i])
		if last_value then return classes[i], last_value end
	end
	return nil, last_value
end

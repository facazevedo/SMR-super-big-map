-- Deterministic Lua 5.3 regression for the inherited engine-global bridge used by lazy
-- GenerateNextMap suppression. A literal false is data here, not a failed read.
local expected = {}
local owner = { GenerateNextMap = expected }
local sandbox = setmetatable({}, {
	__index = owner,
	__newindex = function(_, name, value) owner[name] = value end,
})

local function bridge_read(name)
	local direct = rawget(sandbox, name)
	rawset(sandbox, name, nil)
	local read_ok, value = pcall(function() return sandbox[name] end)
	rawset(sandbox, name, direct)
	if read_ok then return value end
	return nil
end

local function bridge_write(name, value)
	local direct = rawget(sandbox, name)
	rawset(sandbox, name, nil)
	local write_ok = pcall(function() sandbox[name] = value end)
	local unexpected_direct = rawget(sandbox, name)
	rawset(sandbox, name, nil)
	local read_ok, inherited = pcall(function() return sandbox[name] end)
	rawset(sandbox, name, direct)
	local direct_expected = unexpected_direct == nil or unexpected_direct == value
	return write_ok and direct_expected and read_ok and inherited == value
end

local function target_write(name, value)
	local call_ok, acknowledged = pcall(bridge_write, name, value)
	local current = bridge_read(name)
	return current == value, call_ok and acknowledged == true
end

local suppressed, acknowledged = target_write("GenerateNextMap", false)
local false_visible = owner.GenerateNextMap == false and bridge_read("GenerateNextMap") == false
local restored, restore_acknowledged = target_write("GenerateNextMap", expected)
local exact_restore = owner.GenerateNextMap == expected and bridge_read("GenerateNextMap") == expected
local ok = suppressed and acknowledged and false_visible
	and restored and restore_acknowledged and exact_restore
print("ok=" .. tostring(ok))
if not ok then os.exit(1) end

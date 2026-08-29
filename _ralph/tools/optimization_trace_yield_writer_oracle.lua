-- Executable Lua 5.3 oracle for the v978 yield-safe optimization-trace publication boundary.
local function read(path)
	local file, open_error = io.open(path, "rb")
	if not file then error(open_error) end
	local text = file:read("*a")
	file:close()
	return text
end

local generation = read("Code/sbm_map_generation.lua")
local publish_start = assert(generation:find(
	"function SuperBigMap.OptimizationTrace.Publish()", 1, true))
local publish_end = assert(generation:find(
	"function SuperBigMap.OptimizationTrace.EmitActive", publish_start, true))
local publish = generation:sub(publish_start, publish_end - 1)
local uses_sprocall = publish:find(
	'local protected_write = Global("sprocall") or pcall', 1, true) ~= nil
	and publish:find(
		"local call_ok, write_error = protected_write(write, runtime.path, payload)",
		1, true) ~= nil
	and publish:find("pcall(write, runtime.path, payload)", 1, true) == nil

local protected_calls = 0
local function sprocall(fn, ...)
	protected_calls = protected_calls + 1
	return pcall(fn, ...)
end

local writes = 0
local function successful_writer(path, payload)
	writes = writes + 1
	if path ~= "trace.txt" or payload ~= "row\n" then error("writer arguments drift") end
	return nil
end
local protected_write = sprocall or pcall
local success_ok, success_error = protected_write(successful_writer, "trace.txt", "row\n")
local success_write = success_ok == true and success_error == nil
	and writes == 1 and protected_calls == 1

local returned_ok, returned_error = protected_write(function()
	return "synthetic returned write error"
end)
local error_return_fail_open = returned_ok == true
	and returned_error == "synthetic returned write error"

local thrown_ok, thrown_error = protected_write(function()
	error("synthetic thrown write error")
end)
local thrown_write_fail_open = thrown_ok == false
	and tostring(thrown_error):find("synthetic thrown write error", 1, true) ~= nil

local ok = uses_sprocall and success_write
	and error_return_fail_open and thrown_write_fail_open
print("ok=" .. tostring(ok))
print("uses_sprocall=" .. tostring(uses_sprocall))
print("success_write=" .. tostring(success_write))
print("error_return_fail_open=" .. tostring(error_return_fail_open))
print("thrown_write_fail_open=" .. tostring(thrown_write_fail_open))
if not ok then os.exit(1) end

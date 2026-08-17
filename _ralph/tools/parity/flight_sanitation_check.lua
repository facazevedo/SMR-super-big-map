local sanitation_path = assert(arg[1], "usage: lua flight_sanitation_check.lua <sanitation>")

local calls = {}
local function method(owner, name)
	return function(self, marker)
		calls[#calls + 1] = owner .. ":" .. name .. ":" .. tostring(marker)
		return owner .. ":" .. name, marker
	end
end

local base = {
	class = "Flight",
	__ancestors = { InitDone = true },
	Mark = method("base", "Mark"),
	Unmark = method("base", "Unmark"),
	Remark = method("base", "Remark"),
}
local copied = {
	class = "FlightUnderground",
	__ancestors = { Flight = true, InitDone = true },
	Mark = base.Mark,
	Unmark = base.Unmark,
	Remark = base.Remark,
}
local overridden = {
	class = "FlightSpecial",
	__ancestors = { Flight = true, InitDone = true },
	Mark = method("override", "Mark"),
	Unmark = method("override", "Unmark"),
	Remark = method("override", "Remark"),
}
local unrelated = {
	class = "NotFlight",
	__ancestors = { InitDone = true },
	Mark = method("unrelated", "Mark"),
	Unmark = method("unrelated", "Unmark"),
	Remark = method("unrelated", "Remark"),
}

Flight = base
g_Classes = {
	Flight = base,
	FlightUnderground = copied,
	FlightSpecial = overridden,
	NotFlight = unrelated,
}

local originals = {}
for _, class in ipairs({ base, copied, overridden, unrelated }) do
	originals[class] = { class.Mark, class.Unmark, class.Remark }
end

assert(loadfile(sanitation_path))()

for _, class in ipairs({ base, copied, overridden }) do
	assert(class.Mark ~= originals[class][1], class.class .. " Mark was not wrapped")
	assert(class.Unmark ~= originals[class][2], class.class .. " Unmark was not wrapped")
	assert(class.Remark ~= originals[class][3], class.class .. " Remark was not wrapped")
end
assert(unrelated.Mark == originals[unrelated][1], "unrelated Mark changed")
assert(unrelated.Unmark == originals[unrelated][2], "unrelated Unmark changed")
assert(unrelated.Remark == originals[unrelated][3], "unrelated Remark changed")

local methods = { "Mark", "Unmark", "Remark" }
for _, class in ipairs({ base, copied, overridden }) do
	for _, name in ipairs(methods) do
		class[name]({}, "unready")
		class[name]({ objects_to_mark = {}, objects_to_unmark = {} }, "partial")
	end
end
assert(#calls == 0, "a pre-init or partially initialized call delegated")

local ready = { objects_to_mark = {}, objects_to_unmark = {}, marked_objects = {} }
for _, class in ipairs({ base, copied, overridden }) do
	for _, name in ipairs(methods) do
		local owner, marker = class[name](ready, class.class .. "." .. name)
		local expected_owner = class == overridden and "override:" .. name or "base:" .. name
		assert(owner == expected_owner, class.class .. " did not delegate to its preserved method")
		assert(marker == class.class .. "." .. name, class.class .. " lost arguments/returns")
	end
end
assert(#calls == 9, "ready calls did not delegate exactly once")

io.write("PASS flight sanitation: base + 2 descendants wrapped; pre-init suppressed; ready delegated\n")

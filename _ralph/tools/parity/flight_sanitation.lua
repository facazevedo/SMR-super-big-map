-- Random-map rubble can call Flight:Mark/Unmark while GeneratingMap is true,
-- before the stock OnMsg.MapGenerated handler has initialized the flight queues.
-- The class builder copies inherited methods into already-built descendant tables,
-- so patch the base and every built descendant rather than Flight alone.
--
-- Ignoring only this pre-init window is neutral: Flight_Init subsequently enumerates
-- every attached object into a fresh mark queue. Once all three queues are tables,
-- delegate exactly to the method that was installed on that specific class.
do
	local flight = rawget(_G, "Flight")
	local classes = rawget(_G, "g_Classes")
	if type(flight) ~= "table" or type(classes) ~= "table" then
		error("Flight class registry unavailable; cannot guard pre-init callbacks")
	end

	local function ready(self)
		return type(self.objects_to_mark) == "table"
			and type(self.objects_to_unmark) == "table"
			and type(self.marked_objects) == "table"
	end

	local targets, seen = {}, {}
	local function add(class)
		if type(class) == "table" and not seen[class] then
			seen[class] = true
			targets[#targets + 1] = class
		end
	end
	add(flight)
	for _, class in pairs(classes) do
		local ancestors = type(class) == "table" and rawget(class, "__ancestors")
		if type(ancestors) == "table" and ancestors.Flight then
			add(class)
		end
	end

	for _, class in ipairs(targets) do
		local class_name = tostring(rawget(class, "class") or "Flight descendant")
		for _, name in ipairs({ "Mark", "Unmark", "Remark" }) do
			local original = class[name]
			if type(original) ~= "function" then
				error(class_name .. ":" .. name
					.. " unavailable; cannot guard pre-init callbacks")
			end
			class[name] = function(self, ...)
				if not ready(self) then return end
				return original(self, ...)
			end
		end
	end
end

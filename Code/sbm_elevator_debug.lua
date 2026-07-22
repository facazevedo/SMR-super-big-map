-- Super Big Map -- focused, observational Elevator diagnostics.
--
-- The native Elevator moves cargo through a MapSharedDepot: drones work at the local half while
-- requests and stock are shared between the surface and underground command centers. This module
-- traces that request path and the passage-marker visual lifecycle without changing either one.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine and Engine.Global or function(name) return rawget(_G, name) end
local SafeCall = Engine and Engine.SafeCall or function(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c = pcall(fn, ...)
	if ok then return a, b, c end
end
local Unpack = Engine and Engine.Unpack or function(values, first, last)
	return (table.unpack or unpack)(values, first, last)
end
local PATCH_VERSION = 1

local function PackValues(...)
	return { n = select("#", ...), ... }
end

local function IsValidObject(obj)
	if not obj then return false end
	local is_valid = Global("IsValid")
	return type(is_valid) ~= "function" or SafeCall(is_valid, obj) == true
end

local function IsKind(obj, class_name)
	return Engine and type(Engine.IsKindOf) == "function"
		and Engine.IsKindOf(obj, class_name) == true
end

local function ObjectMap(obj)
	if not IsValidObject(obj) then return nil end
	if type(obj.GetMap) == "function" then
		local map = SafeCall(obj.GetMap, obj)
		if map then return map end
	end
	return obj.city and obj.city.map or nil
end

local function IsExpandedMap(map)
	local sectors = SuperBigMap.SectorGrid
	return map and sectors and type(sectors.IsModMap) == "function"
		and sectors.IsModMap(map) == true
end

local function ClassName(obj)
	return tostring(obj and (obj.class or obj.template_name) or "nil")
end

local function Command(obj)
	if not obj then return "nil" end
	if obj.command ~= nil then return tostring(obj.command) end
	return type(obj.GetCommand) == "function" and tostring(SafeCall(obj.GetCommand, obj)) or "nil"
end

local function CallMethod(obj, method, ...)
	local fn = obj and obj[method]
	if type(fn) ~= "function" then return nil end
	return SafeCall(fn, obj, ...)
end

local function DiagnosticsEnabled(channel)
	local diagnostics = SuperBigMap.Diagnostics
	local enabled = diagnostics and diagnostics[channel .. "Enabled"]
	return type(enabled) == "function" and enabled() == true
end

local function LogisticsLog(event, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.ElevatorLogistics) == "function" then
		diagnostics.ElevatorLogistics(event, data, map)
	end
end

local function RocksLog(event, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.ElevatorRocks) == "function" then
		diagnostics.ElevatorRocks(event, data, map)
	end
end

local function ListDetails(values, formatter, limit)
	local details = {}
	for key, value in pairs(type(values) == "table" and values or {}) do
		if #details >= (limit or 64) then break end
		details[#details + 1] = formatter(key, value)
	end
	table.sort(details)
	return table.concat(details, " | "), #details
end

local function RequestDetail(kind, resource, request)
	if not request then return tostring(kind) .. ":" .. tostring(resource) .. ":nil" end
	local actual = CallMethod(request, "GetActualAmount")
	local target = CallMethod(request, "GetTargetAmount")
	local desired = CallMethod(request, "GetDesiredAmount")
	local flags = CallMethod(request, "GetFlags")
	local source = type(request) == "table" and rawget(request, "source") or nil
	return table.concat({
		tostring(kind), tostring(resource), "request=" .. tostring(request),
		"actual=" .. tostring(actual), "target=" .. tostring(target),
		"desired=" .. tostring(desired), "flags=" .. tostring(flags),
		"stored_source=" .. tostring(source),
	}, ":")
end

local function RequestData(data, request, unit)
	if not request then return end
	data.request = tostring(request)
	data.request_resource = tostring(CallMethod(request, "GetResource"))
	data.request_actual = tostring(CallMethod(request, "GetActualAmount"))
	data.request_target = tostring(CallMethod(request, "GetTargetAmount"))
	data.request_desired = tostring(CallMethod(request, "GetDesiredAmount"))
	data.request_flags = tostring(CallMethod(request, "GetFlags"))
	if unit then
		data.request_source_for_unit = tostring(CallMethod(request, "GetSource", unit))
	end
end

local function UnitData(data, unit)
	if not unit then return end
	local map = ObjectMap(unit)
	data.unit = tostring(unit)
	data.unit_class = ClassName(unit)
	data.unit_map = tostring(map)
	data.unit_map_slot = tostring(map and map.slot)
	data.unit_command = Command(unit)
	data.unit_holder = tostring(unit.holder)
	data.unit_target = tostring(unit.target)
	data.unit_supply_request = tostring(unit.s_request)
	data.unit_demand_request = tostring(unit.d_request)
	data.unit_resource = tostring(unit.resource)
	data.unit_amount = tostring(unit.amount)
end

local function CenterData(data, center)
	if not center then return end
	local map = ObjectMap(center)
	data.command_center = tostring(center)
	data.command_center_class = ClassName(center)
	data.command_center_map = tostring(map)
	data.command_center_map_slot = tostring(map and map.slot)
end

local function ResolveDepot(subject)
	if IsKind(subject, "MapSharedDepot") then return subject end
	return subject and subject.shared_depot or nil
end

local function CallData(subject, method, args)
	local map = ObjectMap(subject)
	local other = subject and subject.other or nil
	local depot = ResolveDepot(subject)
	local data = {
		method = tostring(method), subject = tostring(subject), subject_class = ClassName(subject),
		subject_map = tostring(map), subject_map_slot = tostring(map and map.slot),
		other = tostring(other), other_map = tostring(ObjectMap(other)),
		shared_depot = tostring(depot), working = tostring(subject and subject.working),
		ui_working = tostring(subject and subject.ui_working),
	}
	local unit, request, center
	if method == "DroneApproach" then
		unit = args[1]
		data.resource = tostring(args[2])
	elseif method == "DroneLoadResource" or method == "DroneUnloadResource" then
		unit, request = args[1], args[2]
		data.resource, data.amount = tostring(args[3]), tostring(args[4])
	elseif method == "ShouldAddRequestToCommandCenter" then
		request, center = args[1], args[2]
		data.resource = tostring(args[3] or CallMethod(request, "GetResource"))
	elseif method == "AddCommandCenter" or method == "RemoveCommandCenter" then
		center = args[1]
	elseif method == "SetAcceptResourceState" then
		data.resource, data.storage_state = tostring(args[1]), tostring(args[2])
	elseif method == "UseElevator" then
		unit = args[1]
	elseif method == "EnterBuilding" or method == "ApproachWrapper" then
		data.target_building = tostring(args[1])
		data.target_class = ClassName(args[1])
		data.target_map = tostring(ObjectMap(args[1]))
	end
	UnitData(data, unit or (IsKind(subject, "Drone") and subject or nil))
	RequestData(data, request, unit)
	CenterData(data, center)
	return data, map or ObjectMap(other)
end

local function ShouldTraceCall(subject, method, args)
	if IsKind(subject, "MapSharedDepot") or IsKind(subject, "ElevatorBase") then
		return IsExpandedMap(ObjectMap(subject)) or IsExpandedMap(ObjectMap(subject and subject.other))
	end
	if IsKind(subject, "Drone") and (method == "EnterBuilding"
		or method == "ApproachWrapper" or method == "UseElevator") then
		local target = args[1]
		return (IsKind(target, "ElevatorBase") or IsKind(target, "MapSharedDepot"))
			and (IsExpandedMap(ObjectMap(subject)) or IsExpandedMap(ObjectMap(target)))
	end
	return false
end

local function VisualValue(obj, method)
	return tostring(CallMethod(obj, method))
end

local function VisualParent(obj)
	local parent = CallMethod(obj, "GetParent")
	if parent then return parent end
	return CallMethod(obj, "GetAttachParent")
end

local function VisualDetail(obj, role, depth)
	local map = ObjectMap(obj)
	local pos = Engine and Engine.ObjectPos and Engine.ObjectPos(obj) or nil
	return table.concat({
		"role=" .. tostring(role), "depth=" .. tostring(depth), "object=" .. tostring(obj),
		"class=" .. ClassName(obj), "entity=" .. VisualValue(obj, "GetEntity"),
		"map=" .. tostring(map), "pos=" .. tostring(pos),
		"visible=" .. VisualValue(obj, "GetVisible"),
		"opacity=" .. VisualValue(obj, "GetOpacity"),
		"parent=" .. tostring(VisualParent(obj)),
		"attach_spot=" .. VisualValue(obj, "GetAttachSpot"),
		"hidden_tag=" .. tostring(obj and obj.SuperBigMapHiddenByCompletedElevator),
	}, ":")
end

local function VisualTree(root, role, details, seen, depth)
	if not IsValidObject(root) or seen[root] or #details >= 128 then return end
	seen[root] = true
	depth = tonumber(depth) or 0
	details[#details + 1] = VisualDetail(root, role, depth)
	if depth >= 6 or type(root.GetAttaches) ~= "function" then return end
	local ok, attaches = pcall(root.GetAttaches, root)
	if not ok or type(attaches) ~= "table" then
		details[#details + 1] = "role=" .. tostring(role) .. ":attach_scan_failed=true"
		return
	end
	for index, attach in ipairs(attaches) do
		VisualTree(attach, role .. "-attach-" .. tostring(index), details, seen, depth + 1)
	end
end

local function DepotAuditData(elevator, reason)
	local other = elevator and elevator.other or nil
	local depot = ResolveDepot(elevator)
	local map, other_map = ObjectMap(elevator), ObjectMap(other)
	local data = {
		reason = tostring(reason), elevator = tostring(elevator), other = tostring(other),
		map = tostring(map), other_map = tostring(other_map),
		shared_depot = tostring(depot), shared_valid = tostring(IsValidObject(depot)),
		depot_parent = tostring(depot and depot.parent_building),
		parent_matches_pair = tostring(depot and (depot.parent_building == elevator
			or depot.parent_building == other)),
		elevator_auto_connect = tostring(elevator and elevator.auto_connect),
		other_auto_connect = tostring(other and other.auto_connect),
		elevator_command_centers = tostring(type(elevator and elevator.command_centers) == "table"
			and #elevator.command_centers or nil),
		other_command_centers = tostring(type(other and other.command_centers) == "table"
			and #other.command_centers or nil),
		depot_command_centers = tostring(type(depot and depot.command_centers) == "table"
			and #depot.command_centers or nil),
		task_requests = tostring(type(depot and depot.task_requests) == "table"
			and #depot.task_requests or nil),
	}
	for _, resource in ipairs({ "electricity", "water" }) do
		local element = elevator and elevator[resource]
		local other_element = other and other[resource]
		local grid = element and element.grid
		local other_grid = other_element and other_element.grid
		data[resource .. "_grid"] = tostring(grid)
		data[resource .. "_other_grid"] = tostring(other_grid)
		data[resource .. "_shared"] = tostring(grid ~= nil and grid == other_grid)
		data[resource .. "_elements"] = tostring(type(grid and grid.elements) == "table"
			and #grid.elements or nil)
	end
	data.command_centers_detail = ListDetails(depot and depot.command_centers,
		function(index, center)
			local center_map = ObjectMap(center)
			return tostring(index) .. ":" .. tostring(center) .. ":" .. ClassName(center)
				.. ":map=" .. tostring(center_map) .. ":slot=" .. tostring(center_map and center_map.slot)
		end, 64)
	local requests = {}
	for resource, request in pairs(type(depot and depot.supply) == "table" and depot.supply or {}) do
		requests[#requests + 1] = RequestDetail("supply", resource, request)
	end
	for resource, request in pairs(type(depot and depot.demand) == "table" and depot.demand or {}) do
		requests[#requests + 1] = RequestDetail("demand", resource, request)
	end
	table.sort(requests)
	data.requests_detail = table.concat(requests, " | ")
	data.storage_states = ListDetails(depot and depot.resource_storage_states,
		function(resource, state) return tostring(resource) .. "=" .. tostring(state) end, 64)
	data.stockpiled = ListDetails(depot and depot.stockpiled_amount,
		function(resource, amount) return tostring(resource) .. "=" .. tostring(amount) end, 64)
	local map_sources = type(Global("RequestToMapSource")) == "table"
		and Global("RequestToMapSource")[depot and depot.parent_building or elevator] or nil
	data.request_map_sources = ListDetails(map_sources, function(source_map, source)
		return tostring(source_map) .. "->" .. tostring(source) .. ":" .. ClassName(source)
	end, 16)
	return data, map or other_map
end

local ElevatorDebug = {}

function ElevatorDebug.AuditMap(map, reason)
	if not IsExpandedMap(map) or type(map.MapForEach) ~= "function" then return false end
	local seen = setmetatable({}, { __mode = "k" })
	local pairs_found = 0
	local ok, err = pcall(map.MapForEach, map, "map", "ElevatorBase", function(elevator)
		if seen[elevator] then return end
		seen[elevator] = true
		local other = elevator and elevator.other or nil
		if IsValidObject(other) then seen[other] = true end
		pairs_found = pairs_found + 1
		if DiagnosticsEnabled("ElevatorLogistics") then
			local data, event_map = DepotAuditData(elevator, reason)
			LogisticsLog("ELEVATOR_LOGISTICS_AUDIT", data, event_map or map)
		end
		if DiagnosticsEnabled("ElevatorRocks") then
			local details, visual_seen = {}, setmetatable({}, { __mode = "k" })
			local passage = elevator and elevator.passage or nil
			local other_passage = passage and passage.other or (other and other.passage) or nil
			VisualTree(passage, "passage", details, visual_seen, 0)
			VisualTree(elevator, "elevator", details, visual_seen, 0)
			VisualTree(other_passage, "other-passage", details, visual_seen, 0)
			VisualTree(other, "other-elevator", details, visual_seen, 0)
			RocksLog("ELEVATOR_ROCK_VISUAL_AUDIT", {
				reason = tostring(reason), elevator = tostring(elevator), other = tostring(other),
				passage = tostring(passage), other_passage = tostring(other_passage),
				visual_count = #details, visuals = table.concat(details, " | "),
			}, map)
		end
	end)
	if not ok then
		LogisticsLog("ELEVATOR_DIAGNOSTIC_AUDIT_FAILED", {
			reason = tostring(reason), error = tostring(err), pairs = pairs_found,
		}, map)
		return false
	end
	LogisticsLog("ELEVATOR_DIAGNOSTIC_AUDIT_COMPLETE", {
		reason = tostring(reason), pairs = pairs_found,
	}, map)
	return true
end

function ElevatorDebug.ScheduleAudit(map, reason)
	if not IsExpandedMap(map) then return false end
	local State = SuperBigMap.State or {}
	State.elevator_diagnostic_audits = State.elevator_diagnostic_audits
		or setmetatable({}, { __mode = "k" })
	State.elevator_diagnostic_audits[map] = tostring(reason)
	if State.elevator_diagnostic_audit_pending == map then return true end
	State.elevator_diagnostic_audit_pending = map
	local function run()
		local audit_reason = State.elevator_diagnostic_audits[map]
		State.elevator_diagnostic_audits[map] = nil
		if State.elevator_diagnostic_audit_pending == map then
			State.elevator_diagnostic_audit_pending = nil
		end
		if IsExpandedMap(map) then ElevatorDebug.AuditMap(map, audit_reason) end
	end
	if type(map.CreateGameTimeThread) == "function" then
		map:CreateGameTimeThread(run)
		return true
	end
	local create = Global("CreateGameTimeThread")
	if type(create) == "function" then
		create(run)
		return true
	end
	State.elevator_diagnostic_audit_pending = nil
	return false
end

local function RestorePatches()
	local State = SuperBigMap.State or {}
	local patches = State.elevator_runtime_diagnostic_patches
	if type(patches) == "table" then
		for index = #patches, 1, -1 do
			local patch = patches[index]
			if patch.target and patch.target[patch.method] == patch.wrapper then
				patch.target[patch.method] = patch.original
			end
		end
	end
	State.elevator_runtime_diagnostic_patches = nil
	State.elevator_runtime_diagnostic_patch_version = nil
end

local function DescendantsInclusive(base_name)
	local targets = {}
	local base = Engine and Engine.ClassTable and Engine.ClassTable(base_name)
	if type(base) == "table" then targets[#targets + 1] = { name = base_name, class = base } end
	local descendants = Global("ClassDescendants")
	if type(descendants) == "function" then
		pcall(descendants, base_name, function(name, class, output)
			if type(class) == "table" then
				output[#output + 1] = { name = name, class = class }
			end
		end, targets)
	end
	return targets
end

function ElevatorDebug.ApplyModBehavior()
	if not DiagnosticsEnabled("ElevatorLogistics") and not DiagnosticsEnabled("ElevatorRocks") then
		RestorePatches()
		return false
	end
	local State = SuperBigMap.State or {}
	local installed = State.elevator_runtime_diagnostic_patches
	if State.elevator_runtime_diagnostic_patch_version == PATCH_VERSION
		and type(installed) == "table" and #installed > 0 then
		local intact = true
		for _, patch in ipairs(installed) do
			if not patch.target or patch.target[patch.method] ~= patch.wrapper then
				intact = false
				break
			end
		end
		if intact then return true end
	end
	RestorePatches()
	local patches, seen = {}, setmetatable({}, { __mode = "k" })
	local function install(target, method, label, make_wrapper)
		if type(target) ~= "table" or type(target[method]) ~= "function" then return false end
		local methods = seen[target]
		if not methods then methods = {}; seen[target] = methods end
		if methods[method] then return false end
		methods[method] = true
		local original = target[method]
		local wrapper = make_wrapper(original, label, method)
		target[method] = wrapper
		patches[#patches + 1] = {
			target = target, method = method, original = original, wrapper = wrapper,
		}
		return true
	end
	local function logistics_wrapper(original, label, method)
		return function(subject, ...)
			local args = PackValues(...)
			local trace = ShouldTraceCall(subject, method, args)
			if trace then
				local data, map = CallData(subject, method, args)
				data.wrapper_class = tostring(label)
				LogisticsLog("ELEVATOR_LOGISTICS_CALL_BEGIN", data, map)
			end
			local results = PackValues(original(subject, ...))
			if trace then
				local data, map = CallData(subject, method, args)
				data.wrapper_class = tostring(label)
				data.result_1, data.result_2 = tostring(results[1]), tostring(results[2])
				LogisticsLog("ELEVATOR_LOGISTICS_CALL_END", data, map)
				if method == "SetupSharedDepot" or method == "LinkThroughPassage" then
					ElevatorDebug.ScheduleAudit(map or ObjectMap(subject and subject.other),
						tostring(label) .. ":" .. tostring(method) .. " completed")
				end
			end
			return Unpack(results, 1, results.n)
		end
	end
	local function visual_wrapper(original, label, method)
		return function(subject, ...)
			local map = ObjectMap(subject) or ObjectMap(subject and subject.other)
			local trace = DiagnosticsEnabled("ElevatorRocks")
				and (IsExpandedMap(map) or IsExpandedMap(ObjectMap(subject and subject.other)))
			if trace then
				RocksLog("ELEVATOR_ROCK_VISUAL_CALL_BEGIN", {
					wrapper_class = tostring(label), method = tostring(method),
					object = tostring(subject), object_class = ClassName(subject),
					arg_1 = tostring(select(1, ...)), before = VisualDetail(subject, "mutation", 0),
				}, map)
			end
			local results = PackValues(original(subject, ...))
			if trace then
				RocksLog("ELEVATOR_ROCK_VISUAL_CALL_END", {
					wrapper_class = tostring(label), method = tostring(method),
					object = tostring(subject), object_class = ClassName(subject),
					arg_1 = tostring(select(1, ...)), result_1 = tostring(results[1]),
					after = VisualDetail(subject, "mutation", 0),
				}, ObjectMap(subject) or map)
				if method == "LinkThroughPassage" or method == "InitAttaches"
					or method == "DestroyAttaches" or method == "ChangeEntity" then
					ElevatorDebug.ScheduleAudit(ObjectMap(subject) or map,
						tostring(label) .. ":" .. tostring(method) .. " completed")
				end
			end
			return Unpack(results, 1, results.n)
		end
	end

	if DiagnosticsEnabled("ElevatorLogistics") then
		for _, entry in ipairs(DescendantsInclusive("MapSharedDepot")) do
			for _, method in ipairs({
				"ConnectToCommandCenters", "DisconnectFromCommandCenters",
				"CreateResourceRequests", "SetRequestsSource",
				"ShouldAddRequestToCommandCenter", "AddCommandCenter", "RemoveCommandCenter",
				"DroneApproach", "DroneLoadResource", "DroneUnloadResource",
				"SetAcceptResourceState",
			}) do
				install(entry.class, method, entry.name, logistics_wrapper)
			end
		end
		for _, entry in ipairs(DescendantsInclusive("ElevatorBase")) do
			for _, method in ipairs({
				"SetupSharedDepot", "DroneApproach", "DroneLoadResource",
				"DroneUnloadResource", "UseElevator",
			}) do
				install(entry.class, method, entry.name, logistics_wrapper)
			end
		end
		for _, entry in ipairs(DescendantsInclusive("Drone")) do
			for _, method in ipairs({ "ApproachWrapper", "EnterBuilding", "UseElevator" }) do
				install(entry.class, method, entry.name, logistics_wrapper)
			end
		end
	end
	if DiagnosticsEnabled("ElevatorRocks") then
		for _, base_name in ipairs({
			"ElevatorBase", "SurfacePassageBase", "UndergroundPassageBase",
			"SurfacePassageRocks", "UndergroundPassageRocks",
			"SurfaceTunnelMarker", "UndergroundTunnelMarker",
		}) do
			for _, entry in ipairs(DescendantsInclusive(base_name)) do
				for _, method in ipairs({
					"LinkThroughPassage", "UpdateVisuals", "SetVisible", "SetOpacity",
					"ChangeEntity", "SetState", "DestroyAttaches", "InitAttaches",
				}) do
					install(entry.class, method, entry.name, visual_wrapper)
				end
			end
		end
	end
	State.elevator_runtime_diagnostic_patches = patches
	State.elevator_runtime_diagnostic_patch_version = PATCH_VERSION
	LogisticsLog("ELEVATOR_DIAGNOSTIC_PATCH_INSTALLED", {
		patches = #patches, version = PATCH_VERSION,
	}, Global("CurrentMap"))
	ElevatorDebug.ScheduleAudit(Global("CurrentMap"), "diagnostic patch installed")
	return #patches > 0
end

function ElevatorDebug.RestoreVanillaBehavior()
	RestorePatches()
	return true
end

SuperBigMap.ElevatorDebug = ElevatorDebug

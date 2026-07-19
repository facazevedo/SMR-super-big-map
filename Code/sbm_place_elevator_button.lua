-- Super Big Map -- temporary free, instant Elevator placement button.
--
-- This test aid uses the normal Elevator construction cursor and snap rules, then quick-builds
-- the complete two-map construction group. It is available on either vanilla or expanded
-- gameplay maps when PLACE_ELEVATOR_BUTTON_ENABLED is true.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local State = SuperBigMap.State or {}
SuperBigMap.State = State

local WINDOW_ID = "SBMPlaceElevator"

local function Enabled()
	return (SuperBigMap.Config or {}).PLACE_ELEVATOR_BUTTON_ENABLED == true
end

local function WindowLive(window)
	return type(window) == "table"
		and window.window_state ~= "destroying" and window.window_state ~= "destroyed"
end

local function Color(red, green, blue, alpha)
	local rgba = Global("RGBA")
	return type(rgba) == "function" and rgba(red, green, blue, alpha) or 0
end

local function CanUseOnMap(map)
	if not Enabled() or type(map) ~= "table" then return false end
	local is_mod_editor_map = Global("IsModEditorMap")
	if type(is_mod_editor_map) == "function" and SafeCall(is_mod_editor_map) == true then
		return false
	end
	local mapdata = map.mapdata
	if type(mapdata) ~= "table" then return false end
	local map_name = tostring(map.name or mapdata.id or "")
	if map_name == "PreGame" then return false end
	return mapdata.Environment == "Surface" or mapdata.Environment == "Underground"
end

local function StartElevatorPlacement()
	if not CanUseOnMap(Global("CurrentMap")) then return false end
	local get_interface = Global("GetInGameInterface")
	local interface = type(get_interface) == "function" and get_interface() or nil
	if not interface or type(interface.SetMode) ~= "function" then return false end

	local unlock = Global("UnlockBuilding")
	if type(unlock) == "function" then pcall(unlock, "Elevator") end
	local templates = Global("BuildingTemplates")
	local template = type(templates) == "table" and templates.Elevator or nil
	if template and template.only_build_on_snapped_locations == false then
		template.only_build_on_snapped_locations = true
	end

	State.place_elevator_button_armed = true
	SafeCall(interface.SetMode, interface, "construction", { template = "Elevator" })
	return true
end

local function IsElevatorSite(site, class_name)
	if class_name == "Elevator" then return true end
	if type(site) ~= "table" then return false end
	if site.building_class == "Elevator" then return true end
	if type(site.GetBuildingClass) == "function" then
		return SafeCall(site.GetBuildingClass, site) == "Elevator"
	end
	return false
end

local function IsLiveObject(obj)
	if type(obj) ~= "table" then return false end
	local is_valid = Global("IsValid")
	return type(is_valid) ~= "function" or is_valid(obj) == true
end

local function ObjectMap(obj)
	if not IsLiveObject(obj) or type(obj.GetMap) ~= "function" then return nil end
	return SafeCall(obj.GetMap, obj)
end

local function Audit(event, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.Elevator) == "function" then
		diagnostics.Elevator("TEMP_BUTTON_" .. tostring(event), data or {}, map)
	end
end

local function ReportFailure(reason, data, map)
	data = type(data) == "table" and data or {}
	data.reason = tostring(reason)
	Audit("FAILED", data, map)
	local print_fn = Global("print") or print
	if type(print_fn) == "function" then
		print_fn("[Super Big Map][Place Elevator] " .. tostring(reason))
	end
	return false
end

local function ResolveElevatorConstructionGroup(site)
	if not IsLiveObject(site) then return nil, nil, "placed site is no longer valid" end
	local group = rawget(site, "construction_group")
	local leader = type(group) == "table" and group[1] or nil
	if type(group) ~= "table" or not IsLiveObject(leader)
		or type(leader.Complete) ~= "function" then
		return nil, nil, "paired Elevator construction-group leader is unavailable"
	end
	local members = {}
	for index = 2, #group do
		local member = group[index]
		if IsLiveObject(member) and IsElevatorSite(member, rawget(member, "building_class")) then
			members[#members + 1] = member
		end
	end
	if #members ~= 2 then
		return nil, nil, "paired Elevator construction group does not contain two live sites"
	end
	local first_map, second_map = ObjectMap(members[1]), ObjectMap(members[2])
	if not first_map or not second_map or first_map == second_map then
		return nil, nil, "paired Elevator construction sites do not belong to two distinct maps"
	end
	return leader, members
end

local function PassageForSite(site)
	local passage = type(site) == "table" and rawget(site, "snapped_to") or nil
	if IsLiveObject(passage) then return passage end
	local map = ObjectMap(site)
	if map and type(map.MapFindNearest) == "function" and type(site.GetPos) == "function" then
		return SafeCall(map.MapFindNearest, map, site:GetPos(), "map",
			"SurfacePassageBase", "UndergroundPassageBase")
	end
	return nil
end

local function HandleConstructionSitePlaced(site, class_name)
	if State.place_elevator_button_armed ~= true then return end
	if not Enabled() then
		State.place_elevator_button_armed = nil
		return
	end
	if not IsElevatorSite(site, class_name) then return end
	State.place_elevator_button_armed = nil

	local function finish()
		local map = ObjectMap(site)
		local leader, members, resolve_error = ResolveElevatorConstructionGroup(site)
		if not leader then
			return ReportFailure(resolve_error, { class = tostring(class_name) }, map)
		end
		local passages = { PassageForSite(members[1]), PassageForSite(members[2]) }
		Audit("GROUP_READY", {
			members = #members,
			first_map = tostring(ObjectMap(members[1])),
			second_map = tostring(ObjectMap(members[2])),
		}, map)
		local ok, complete_error = pcall(leader.Complete, leader, "quick_build")
		if not ok then
			return ReportFailure("paired Elevator quick-build failed: " .. tostring(complete_error),
				{ members = #members }, map)
		end
		if IsLiveObject(members[1]) or IsLiveObject(members[2]) then
			return ReportFailure("paired Elevator quick-build left a construction site alive",
				{ first_alive = tostring(IsLiveObject(members[1])),
					second_alive = tostring(IsLiveObject(members[2])) }, map)
		end

		-- PlaceBuildingIn schedules GameInit for the completed buildings. Verify on the next game-time
		-- task, after those already-queued GameInit calls have linked both halves through the passages.
		local function verify()
			local first = IsLiveObject(passages[1]) and rawget(passages[1], "elevator") or nil
			local second = IsLiveObject(passages[2]) and rawget(passages[2], "elevator") or nil
			local linked = IsLiveObject(first) and IsLiveObject(second)
				and rawget(first, "other") == second and rawget(second, "other") == first
			if not linked then
				return ReportFailure("paired Elevator buildings did not link after quick-build", {
					first_complete = tostring(IsLiveObject(first)),
					second_complete = tostring(IsLiveObject(second)),
				}, map)
			end
			Audit("COMPLETE", {
				first_map = tostring(ObjectMap(first)), second_map = tostring(ObjectMap(second)),
				linked = true,
			}, map)
			return true
		end
		local create_verify_thread = Global("CreateGameTimeThread")
		if type(create_verify_thread) == "function" then
			create_verify_thread(verify)
		else
			verify()
		end
		return true
	end
	local create_thread = Global("CreateGameTimeThread")
	if type(create_thread) ~= "function" then
		return ReportFailure("game-time task API is unavailable; refusing a one-sided quick-build",
			{ class = tostring(class_name) }, ObjectMap(site))
	end
	create_thread(finish)
end

local function ResolveExistingButton(desktop)
	local window = State.place_elevator_button_window
	if WindowLive(window) then return window end
	if desktop and type(desktop.ResolveId) == "function" then
		local resolved = SafeCall(desktop.ResolveId, desktop, WINDOW_ID)
		if WindowLive(resolved) then return resolved end
	end
	return nil
end

local function BuildButton()
	local desktop = (Global("terminal") or {}).desktop
	local button_class = Global("XTextButton")
	local box = Global("box")
	if not desktop or type(button_class) ~= "table" or type(box) ~= "function" then return nil end

	local button = button_class:new({
		Id = WINDOW_ID,
		Text = "Place Elevator",
		Translate = false,
		TextStyle = "ConsoleLog",
		HAlign = "right",
		VAlign = "bottom",
		Margins = box(0, 0, 30, 70),
		Padding = box(12, 4, 12, 4),
		Background = Color(70, 55, 30, 235),
		RolloverBackground = Color(105, 82, 45, 235),
		PressedBackground = Color(55, 42, 22, 235),
		RolloverTextColor = Color(236, 236, 238, 255),
		DisabledTextColor = Color(236, 236, 238, 255),
		DisabledRolloverTextColor = Color(236, 236, 238, 255),
		ZOrder = 100000,
		OnPress = function() StartElevatorPlacement() end,
	}, desktop)
	State.place_elevator_button_window = button
	if WindowLive(button) and type(button.SetTextColor) == "function" then
		button:SetTextColor(Color(236, 236, 238, 255))
	end
	if WindowLive(button) and type(button.Open) == "function" then pcall(button.Open, button) end
	return button
end

local PlaceElevatorButton = {}

function PlaceElevatorButton.Show()
	if not CanUseOnMap(Global("CurrentMap")) then
		return PlaceElevatorButton.Hide()
	end
	local desktop = (Global("terminal") or {}).desktop
	local button = ResolveExistingButton(desktop) or BuildButton()
	if not WindowLive(button) then return false end
	State.place_elevator_button_window = button
	if type(button.SetVisible) == "function" then SafeCall(button.SetVisible, button, true) end
	return true
end

function PlaceElevatorButton.Hide()
	local button = State.place_elevator_button_window
	if WindowLive(button) and type(button.SetVisible) == "function" then
		SafeCall(button.SetVisible, button, false)
	end
	State.place_elevator_button_armed = nil
	return true
end

PlaceElevatorButton.ApplyModBehavior = PlaceElevatorButton.Show
PlaceElevatorButton.RestoreVanillaBehavior = PlaceElevatorButton.Hide
PlaceElevatorButton.HandleConstructionSitePlaced = HandleConstructionSitePlaced
SuperBigMap.PlaceElevatorButton = PlaceElevatorButton

State.place_elevator_button_message_handler = HandleConstructionSitePlaced
if State.place_elevator_button_message_registered ~= true then
	State.place_elevator_button_message_registered = true
	Engine.ChainOnMsg("ConstructionSitePlaced", function(...)
		local handler = (SuperBigMap.State or {}).place_elevator_button_message_handler
		if type(handler) == "function" then return handler(...) end
	end)
end

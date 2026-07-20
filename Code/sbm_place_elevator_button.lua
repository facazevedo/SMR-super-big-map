-- Super Big Map -- temporary gameplay test buttons.
--
-- This test aid uses the normal Elevator construction cursor and snap rules, then quick-builds
-- the complete two-map construction group. It also owns the underground buried-wonder placement
-- buttons and the vanilla-style darkness-blanket toggle. Each control has its own config gate.

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
local DARKNESS_TOGGLE_WINDOW_ID = "SBMToggleUndergroundDarkness"
local BURIED_WONDER_TEST_BUILDINGS = {
	{
		id = "SBMPlaceArtifactInterface",
		template = "AncientArtifactInterface",
		text = "Place Artifact Interface",
	},
	{
		id = "SBMPlaceBottomlessPitLab",
		template = "BottomlessPitResearchCenter",
		text = "Place Bottomless Pit Lab",
	},
	{
		id = "SBMPlaceWondrousCrystals",
		template = "CrystalDecoration",
		text = "Place Wondrous Crystals",
	},
	{
		id = "SBMPlaceJumboCaveReinforcements",
		template = "JumboCaveReinforcementStructure",
		text = "Place Jumbo Cave Reinforcements",
	},
}

local function Enabled()
	return (SuperBigMap.Config or {}).PLACE_ELEVATOR_BUTTON_ENABLED == true
end

local function BuriedWonderButtonsEnabled()
	return (SuperBigMap.Config or {}).PLACE_BURIED_WONDER_TEST_BUTTONS_ENABLED == true
end

local function DarknessToggleButtonEnabled()
	return (SuperBigMap.Config or {}).UNDERGROUND_DARKNESS_TOGGLE_BUTTON_ENABLED == true
end

local function WindowLive(window)
	return type(window) == "table"
		and window.window_state ~= "destroying" and window.window_state ~= "destroyed"
end

local function Color(red, green, blue, alpha)
	local rgba = Global("RGBA")
	return type(rgba) == "function" and rgba(red, green, blue, alpha) or 0
end

local function IsGameplayMap(map)
	if type(map) ~= "table" then return false end
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

local function CanUseOnMap(map)
	return Enabled() and IsGameplayMap(map)
end

local function CanUseBuriedWonderButtons(map)
	return BuriedWonderButtonsEnabled() and IsGameplayMap(map)
		and map.mapdata.Environment == "Underground"
end

local function CanUseDarknessToggleButton(map)
	return DarknessToggleButtonEnabled() and IsGameplayMap(map)
		and map.mapdata.Environment == "Underground"
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

	State.place_buried_wonder_test_button_armed = nil
	State.place_elevator_button_armed = true
	SafeCall(interface.SetMode, interface, "construction", { template = "Elevator" })
	return true
end

local function StartBuriedWonderTestPlacement(spec)
	local map = Global("CurrentMap")
	if type(spec) ~= "table" or not CanUseBuriedWonderButtons(map) then return false end
	local template_name = spec.template
	local templates = Global("BuildingTemplates")
	if type(template_name) ~= "string" or type(templates) ~= "table"
		or type(templates[template_name]) ~= "table" then
		return false
	end
	local get_interface = Global("GetInGameInterface")
	local interface = type(get_interface) == "function" and get_interface() or nil
	if not interface or type(interface.SetMode) ~= "function" then return false end

	-- This is an explicitly temporary testing aid. UnlockBuilding makes the normal construction
	-- cursor available; Complete("quick_build") below supplies the no-cost/no-time behavior without
	-- mutating the shared template's prices or build points.
	local unlock = Global("UnlockBuilding")
	if type(unlock) == "function" then pcall(unlock, template_name) end
	State.place_elevator_button_armed = nil
	State.place_buried_wonder_test_button_armed = template_name
	SafeCall(interface.SetMode, interface, "construction", { template = template_name })
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

local function HandleElevatorConstructionSitePlaced(site, class_name)
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

local function IsBuildingSite(site, class_name, expected_class)
	if class_name == expected_class then return true end
	if type(site) ~= "table" then return false end
	if site.building_class == expected_class or site.template_name == expected_class then return true end
	if type(site.GetBuildingClass) == "function" then
		return SafeCall(site.GetBuildingClass, site) == expected_class
	end
	return false
end

local function ObjectScale(obj)
	if not IsLiveObject(obj) or type(obj.GetScale) ~= "function" then return nil end
	return SafeCall(obj.GetScale, obj)
end

local function ObjectClass(obj)
	return IsLiveObject(obj) and tostring(obj.class or "?") or "none"
end

local function ReportBuriedWonderTest(event, template_name, detail)
	local print_fn = Global("print") or print
	if type(print_fn) ~= "function" then return end
	print_fn("[Super Big Map][Buried Wonder Test] " .. tostring(event)
		.. " template=" .. tostring(template_name) .. " " .. tostring(detail or ""))
end

local function HandleBuriedWonderConstructionSitePlaced(site, class_name)
	local armed = State.place_buried_wonder_test_button_armed
	if type(armed) ~= "string" then return end
	if not BuriedWonderButtonsEnabled() then
		State.place_buried_wonder_test_button_armed = nil
		return
	end
	if not IsBuildingSite(site, class_name, armed) then return end
	State.place_buried_wonder_test_button_armed = nil

	local snapped_to = type(site) == "table" and rawget(site, "snapped_to") or nil
	ReportBuriedWonderTest("SITE_PLACED", armed,
		"snap_target=" .. ObjectClass(snapped_to)
		.. " snap_scale=" .. tostring(ObjectScale(snapped_to)))
	local function finish()
		if not IsLiveObject(site) or type(site.Complete) ~= "function" then
			return ReportBuriedWonderTest("FAILED", armed,
				"construction site became unavailable before quick-build")
		end
		local ok, building = pcall(site.Complete, site, "quick_build")
		if not ok or not IsLiveObject(building) then
			return ReportBuriedWonderTest("FAILED", armed,
				"quick-build error=" .. tostring(building))
		end
		ReportBuriedWonderTest("COMPLETE", armed,
			"building=" .. ObjectClass(building)
			.. " building_scale=" .. tostring(ObjectScale(building))
			.. " snap_target=" .. ObjectClass(snapped_to)
			.. " snap_scale=" .. tostring(ObjectScale(snapped_to)))
		return true
	end
	local create_thread = Global("CreateGameTimeThread")
	if type(create_thread) == "function" then
		create_thread(finish)
	else
		finish()
	end
end

local function HandleConstructionSitePlaced(site, class_name)
	HandleElevatorConstructionSitePlaced(site, class_name)
	HandleBuriedWonderConstructionSitePlaced(site, class_name)
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

local function ResolveBuriedWonderButton(desktop, spec)
	State.place_buried_wonder_test_button_windows =
		State.place_buried_wonder_test_button_windows or {}
	local window = State.place_buried_wonder_test_button_windows[spec.template]
	if WindowLive(window) then return window end
	if desktop and type(desktop.ResolveId) == "function" then
		local resolved = SafeCall(desktop.ResolveId, desktop, spec.id)
		if WindowLive(resolved) then return resolved end
	end
	return nil
end

local function BuildBuriedWonderButton(desktop, spec, index)
	local button_class = Global("XTextButton")
	local box = Global("box")
	if not desktop or type(button_class) ~= "table" or type(box) ~= "function" then return nil end
	local button = button_class:new({
		Id = spec.id,
		Text = spec.text,
		Translate = false,
		TextStyle = "ConsoleLog",
		HAlign = "right",
		VAlign = "bottom",
		Margins = box(0, 0, 30, 70 + index * 36),
		Padding = box(12, 4, 12, 4),
		Background = Color(45, 62, 78, 235),
		RolloverBackground = Color(66, 91, 115, 235),
		PressedBackground = Color(34, 47, 60, 235),
		RolloverTextColor = Color(236, 236, 238, 255),
		DisabledTextColor = Color(236, 236, 238, 255),
		DisabledRolloverTextColor = Color(236, 236, 238, 255),
		ZOrder = 100000,
		OnPress = function() StartBuriedWonderTestPlacement(spec) end,
	}, desktop)
	State.place_buried_wonder_test_button_windows =
		State.place_buried_wonder_test_button_windows or {}
	State.place_buried_wonder_test_button_windows[spec.template] = button
	if WindowLive(button) and type(button.SetTextColor) == "function" then
		button:SetTextColor(Color(236, 236, 238, 255))
	end
	if WindowLive(button) and type(button.Open) == "function" then pcall(button.Open, button) end
	return button
end

local function ResolveDarknessToggleButton(desktop)
	local window = State.underground_darkness_toggle_button_window
	if WindowLive(window) then return window end
	if desktop and type(desktop.ResolveId) == "function" then
		local resolved = SafeCall(desktop.ResolveId, desktop, DARKNESS_TOGGLE_WINDOW_ID)
		if WindowLive(resolved) then return resolved end
	end
	return nil
end

local function DarknessCurrentlyRevealed()
	local hr = Global("hr")
	return type(hr) == "table" and tonumber(hr.EnableDarknessReveal) == 0
end

local function UpdateDarknessToggleButtonText(button)
	if not WindowLive(button) or type(button.SetText) ~= "function" then return false end
	local text = DarknessCurrentlyRevealed()
		and "Restore Exploration Darkness" or "Reveal All Underground"
	SafeCall(button.SetText, button, text)
	return true
end

local function ToggleUndergroundDarkness(button)
	local hr = Global("hr")
	if type(hr) ~= "table" then return false end
	-- Exact vanilla cheat action: no saved preference, lifecycle override, or extra reveal work.
	hr.EnableDarknessReveal = 90 - hr.EnableDarknessReveal
	UpdateDarknessToggleButtonText(button)
	local print_fn = Global("print") or print
	if type(print_fn) == "function" then
		print_fn("[Super Big Map][Darkness Toggle] blanket="
			.. (DarknessCurrentlyRevealed() and "hidden" or "visible"))
	end
	return true
end

local function BuildDarknessToggleButton(desktop)
	local button_class = Global("XTextButton")
	local box = Global("box")
	if not desktop or type(button_class) ~= "table" or type(box) ~= "function" then return nil end
	local button = button_class:new({
		Id = DARKNESS_TOGGLE_WINDOW_ID,
		Text = "Reveal All Underground",
		Translate = false,
		TextStyle = "ConsoleLog",
		HAlign = "right",
		VAlign = "bottom",
		Margins = box(0, 0, 30, 70 + (#BURIED_WONDER_TEST_BUILDINGS + 1) * 36),
		Padding = box(12, 4, 12, 4),
		Background = Color(68, 45, 78, 235),
		RolloverBackground = Color(98, 65, 113, 235),
		PressedBackground = Color(51, 34, 60, 235),
		RolloverTextColor = Color(236, 236, 238, 255),
		DisabledTextColor = Color(236, 236, 238, 255),
		DisabledRolloverTextColor = Color(236, 236, 238, 255),
		ZOrder = 100000,
		OnPress = function(self) ToggleUndergroundDarkness(self) end,
	}, desktop)
	State.underground_darkness_toggle_button_window = button
	if WindowLive(button) and type(button.SetTextColor) == "function" then
		button:SetTextColor(Color(236, 236, 238, 255))
	end
	UpdateDarknessToggleButtonText(button)
	if WindowLive(button) and type(button.Open) == "function" then pcall(button.Open, button) end
	return button
end

local function SetBuriedWonderButtonsVisible(visible)
	local map = Global("CurrentMap")
	local show = visible == true and CanUseBuriedWonderButtons(map)
	local desktop = (Global("terminal") or {}).desktop
	local all_live = true
	for index, spec in ipairs(BURIED_WONDER_TEST_BUILDINGS) do
		local button = ResolveBuriedWonderButton(desktop, spec)
		if show and not WindowLive(button) then
			button = BuildBuriedWonderButton(desktop, spec, index)
		end
		if WindowLive(button) and type(button.SetVisible) == "function" then
			SafeCall(button.SetVisible, button, show)
		elseif show then
			all_live = false
		end
	end
	if not show then State.place_buried_wonder_test_button_armed = nil end
	return not show or all_live
end

local function SetDarknessToggleButtonVisible(visible)
	local map = Global("CurrentMap")
	local show = visible == true and CanUseDarknessToggleButton(map)
	local desktop = (Global("terminal") or {}).desktop
	local button = ResolveDarknessToggleButton(desktop)
	if show and not WindowLive(button) then button = BuildDarknessToggleButton(desktop) end
	if not WindowLive(button) then return not show end
	if show then UpdateDarknessToggleButtonText(button) end
	if type(button.SetVisible) == "function" then SafeCall(button.SetVisible, button, show) end
	return true
end

local PlaceElevatorButton = {}

function PlaceElevatorButton.Show()
	local map = Global("CurrentMap")
	if not IsGameplayMap(map) then
		return PlaceElevatorButton.Hide()
	end
	local desktop = (Global("terminal") or {}).desktop
	local elevator_ok = true
	local button = ResolveExistingButton(desktop)
	local show_elevator = CanUseOnMap(map)
	if show_elevator and not WindowLive(button) then button = BuildButton() end
	if WindowLive(button) and type(button.SetVisible) == "function" then
		SafeCall(button.SetVisible, button, show_elevator)
	elseif show_elevator then
		elevator_ok = false
	end
	local buried_ok = SetBuriedWonderButtonsVisible(true)
	local darkness_ok = SetDarknessToggleButtonVisible(true)
	return elevator_ok and buried_ok and darkness_ok
end

function PlaceElevatorButton.Hide()
	local button = State.place_elevator_button_window
	if WindowLive(button) and type(button.SetVisible) == "function" then
		SafeCall(button.SetVisible, button, false)
	end
	SetBuriedWonderButtonsVisible(false)
	SetDarknessToggleButtonVisible(false)
	State.place_elevator_button_armed = nil
	State.place_buried_wonder_test_button_armed = nil
	return true
end

PlaceElevatorButton.ApplyModBehavior = PlaceElevatorButton.Show
PlaceElevatorButton.RestoreVanillaBehavior = PlaceElevatorButton.Hide
PlaceElevatorButton.HandleConstructionSitePlaced = HandleConstructionSitePlaced
PlaceElevatorButton.ToggleUndergroundDarkness = ToggleUndergroundDarkness
SuperBigMap.PlaceElevatorButton = PlaceElevatorButton

State.place_elevator_button_message_handler = HandleConstructionSitePlaced
if State.place_elevator_button_message_registered ~= true then
	State.place_elevator_button_message_registered = true
	Engine.ChainOnMsg("ConstructionSitePlaced", function(...)
		local handler = (SuperBigMap.State or {}).place_elevator_button_message_handler
		if type(handler) == "function" then return handler(...) end
	end)
end

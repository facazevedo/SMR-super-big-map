-- Super Big Map -- temporary gameplay inspection buttons.
--
-- This test aid uses the normal Elevator construction cursor and snap rules, then quick-builds
-- the complete two-map construction group. A second temporary button follows the normal map
-- switch path so deferred underground generation finishes, opens the underground, and removes
-- its darkness blanket for visual parity inspection. Two additional buttons reveal every surface
-- sector and every underground enrichment for whole-map inspection.

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
local SWITCH_WINDOW_ID = "SBMSwitchToUnderground"
local REVEAL_SURFACE_WINDOW_ID = "SBMRevealSurfaceSectors"
local REVEAL_UNDERGROUND_WINDOW_ID = "SBMRevealUndergroundAll"
local RETIRED_WINDOW_IDS = {
	"SBMPlaceArtifactInterface",
	"SBMPlaceBottomlessPitLab",
	"SBMPlaceWondrousCrystals",
	"SBMPlaceJumboCaveReinforcements",
	"SBMToggleUndergroundDarkness",
}

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

local function IsExpandedSessionMap(map)
	local lifecycle = SuperBigMap.Lifecycle
	if not (lifecycle and type(lifecycle.IsActive) == "function"
		and SafeCall(lifecycle.IsActive) == true) then
		return false
	end
	local sectors = SuperBigMap.SectorGrid
	return sectors and type(sectors.IsModMap) == "function"
		and SafeCall(sectors.IsModMap, map) == true
end

local function CanUseOnMap(map)
	return Enabled() and IsGameplayMap(map) and IsExpandedSessionMap(map)
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
	return false
end

local function SetButtonLabel(state_key, text)
	local button = State[state_key]
	if WindowLive(button) and type(button.SetText) == "function" then
		SafeCall(button.SetText, button, tostring(text))
	end
end

local function RevealAllSurfaceSectors()
	if State.reveal_surface_sectors_running == true then return false end
	local map = Global("MainMap")
	if not CanUseOnMap(map) or map.mapdata.Environment ~= "Surface" then
		return ReportFailure("expanded surface map is unavailable", {}, map)
	end
	local city = map.City
	local grid = city and city.MapSectors
	if type(grid) ~= "table" then
		return ReportFailure("surface sector grid is unavailable", {}, map)
	end
	local create_thread = Global("CreateRealTimeThread")
	local change_map = Global("ChangeCurrentMapSlot")
	if type(create_thread) ~= "function" or type(change_map) ~= "function" then
		return ReportFailure("map-switch or real-time task API is unavailable", {}, map)
	end

	State.reveal_surface_sectors_running = true
	SetButtonLabel("reveal_surface_sectors_button_window", "Revealing Surface...")
	create_thread(function()
		if Global("CurrentMap") ~= map then
			local switch_ok, switch_error = pcall(change_map, map.slot, true)
			if not switch_ok or Global("CurrentMap") ~= map then
				State.reveal_surface_sectors_running = nil
				SetButtonLabel("reveal_surface_sectors_button_window", "Reveal Surface Sectors")
				return ReportFailure("surface map switch failed: " .. tostring(switch_error),
					{}, map)
			end
		end
		local scanned, already_deep, failed = 0, 0, 0
		local suspend_ok = type(map.SuspendPassEdits) == "function"
			and type(map.ResumePassEdits) == "function"
			and pcall(map.SuspendPassEdits, map, "SuperBigMap_RevealSurfaceSectors")
		local sleep = Global("Sleep")
		local processed = 0
		local ok, scan_error = pcall(function()
			local column = 1
			while type(grid[column]) == "table" do
				local row = 1
				while grid[column][row] ~= nil do
					local sector = grid[column][row]
					if type(sector) ~= "table" or type(sector.Scan) ~= "function" then
						failed = failed + 1
					elseif sector.status == "deep scanned" then
						already_deep = already_deep + 1
					else
						local scan_ok = pcall(sector.Scan, sector, "deep scanned", nil)
						if scan_ok and sector.status == "deep scanned" then
							scanned = scanned + 1
						else
							failed = failed + 1
						end
					end
					processed = processed + 1
					if type(sleep) == "function" and processed % 8 == 0 then sleep(1) end
					row = row + 1
				end
				column = column + 1
			end
		end)
		if suspend_ok then
			pcall(map.ResumePassEdits, map, "SuperBigMap_RevealSurfaceSectors")
		end
		State.reveal_surface_sectors_running = nil
		SetButtonLabel("reveal_surface_sectors_button_window", "Reveal Surface Sectors")
		if not ok then
			return ReportFailure("surface sector reveal failed: " .. tostring(scan_error), {
				scanned = scanned, already_deep = already_deep, failed = failed,
			}, map)
		end
		Audit("SURFACE_REVEAL_COMPLETE", {
			scanned = scanned, already_deep = already_deep, failed = failed,
		}, map)
		return failed == 0
	end)
	return true
end

local function RevealAllUnderground()
	if State.reveal_underground_all_running == true then return false end
	local current_map = Global("CurrentMap")
	if not CanUseOnMap(current_map) then return false end
	local underground = Global("UndergroundMap")
	if not IsGameplayMap(underground) or not IsExpandedSessionMap(underground) then
		return ReportFailure("expanded underground map is unavailable", {}, current_map)
	end
	local change_map = Global("ChangeCurrentMapSlot")
	local create_thread = Global("CreateRealTimeThread")
	if type(change_map) ~= "function" or type(create_thread) ~= "function" then
		return ReportFailure("normal underground map-switch API is unavailable", {}, current_map)
	end

	State.reveal_underground_all_running = true
	State.switch_to_underground_button_force_reveal = true
	SetButtonLabel("reveal_underground_all_button_window", "Revealing Underground...")
	create_thread(function()
		if Global("CurrentMap") ~= underground then
			local switch_ok, switch_error = pcall(change_map, underground.slot, true)
			if not switch_ok then
				State.reveal_underground_all_running = nil
				SetButtonLabel("reveal_underground_all_button_window", "Reveal Underground All")
				return ReportFailure("underground map switch failed: " .. tostring(switch_error),
					{}, current_map)
			end
		end

		if Global("CurrentMap") ~= underground
			or underground.SuperBigMapUndergroundStretchDone ~= true then
			State.reveal_underground_all_running = nil
			SetButtonLabel("reveal_underground_all_button_window", "Reveal Underground All")
			return ReportFailure("underground preparation did not complete", {
				current_map = tostring(Global("CurrentMap")),
				stretch_done = tostring(underground.SuperBigMapUndergroundStretchDone == true),
			}, underground)
		end

		local hr = Global("hr")
		if type(hr) == "table" then hr.EnableDarknessReveal = 0 end
		local deposits = SuperBigMap.DepositRules
		local reveal = deposits and deposits.RevealAllUndergroundEnrichmentsForTesting
		local reveal_ok, stats
		if type(reveal) == "function" then
			reveal_ok, stats = SafeCall(reveal, underground, true)
		else
			reveal_ok, stats = false, { error = "underground reveal API is unavailable" }
		end
		State.reveal_underground_all_running = nil
		SetButtonLabel("reveal_underground_all_button_window", "Reveal Underground All")
		if reveal_ok ~= true then
			return ReportFailure("underground reveal failed: "
				.. tostring(stats and stats.error or "unknown error"), {}, underground)
		end
		Audit("UNDERGROUND_REVEAL_COMPLETE", {
			markers = tostring(stats.markers), placed = tostring(stats.placed),
			revealed = tostring(stats.revealed),
			explorable_objects = tostring(stats.explorable_objects),
			explorable_revealed = tostring(stats.explorable_revealed),
			darkness = type(hr) == "table" and tostring(hr.EnableDarknessReveal) or "unavailable",
		}, underground)
		return true
	end)
	return true
end

local function SwitchToUnderground()
	local current_map = Global("CurrentMap")
	if not CanUseOnMap(current_map) then return false end
	local underground = Global("UndergroundMap")
	if not IsGameplayMap(underground) or not IsExpandedSessionMap(underground) then
		return ReportFailure("expanded underground map is unavailable", {}, current_map)
	end
	local change_map = Global("ChangeCurrentMapSlot")
	local create_thread = Global("CreateRealTimeThread")
	if type(change_map) ~= "function" or type(create_thread) ~= "function" then
		return ReportFailure("normal underground map-switch API is unavailable", {}, current_map)
	end

	-- ApplyUndergroundDarknessState reads this test-only state during CurrentMapChangeDone.
	-- Hide clears it, and the lifecycle immediately restores vanilla darkness for the live map.
	State.switch_to_underground_button_force_reveal = true
	create_thread(function()
		Audit("UNDERGROUND_SWITCH_REQUESTED", {
			from_map = tostring(current_map), target_slot = tostring(underground.slot),
		}, current_map)
		local ok, switch_error = pcall(change_map, underground.slot, true)
		if not ok then
			State.switch_to_underground_button_force_reveal = nil
			return ReportFailure("underground map switch failed: " .. tostring(switch_error), {}, current_map)
		end

		-- Keep the visual postcondition explicit even if a future engine build changes the
		-- ordering of CurrentMapChangeDone relative to ChangeCurrentMapSlot's return.
		local hr = Global("hr")
		if type(hr) == "table" then hr.EnableDarknessReveal = 0 end
		Audit("UNDERGROUND_SWITCH_COMPLETE", {
			current_map = tostring(Global("CurrentMap")),
			stretch_done = tostring(underground.SuperBigMapUndergroundStretchDone == true),
			darkness = type(hr) == "table" and tostring(hr.EnableDarknessReveal) or "unavailable",
		}, underground)
		return true
	end)
	return true
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

local function HandleConstructionSitePlaced(site, class_name)
	if not IsExpandedSessionMap(Global("CurrentMap")) then return end
	HandleElevatorConstructionSitePlaced(site, class_name)
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

local function ResolveExistingSwitchButton(desktop)
	local window = State.switch_to_underground_button_window
	if WindowLive(window) then return window end
	if desktop and type(desktop.ResolveId) == "function" then
		local resolved = SafeCall(desktop.ResolveId, desktop, SWITCH_WINDOW_ID)
		if WindowLive(resolved) then return resolved end
	end
	return nil
end

local function ResolveExistingRevealSurfaceButton(desktop)
	local window = State.reveal_surface_sectors_button_window
	if WindowLive(window) then return window end
	if desktop and type(desktop.ResolveId) == "function" then
		local resolved = SafeCall(desktop.ResolveId, desktop, REVEAL_SURFACE_WINDOW_ID)
		if WindowLive(resolved) then return resolved end
	end
	return nil
end

local function ResolveExistingRevealUndergroundButton(desktop)
	local window = State.reveal_underground_all_button_window
	if WindowLive(window) then return window end
	if desktop and type(desktop.ResolveId) == "function" then
		local resolved = SafeCall(desktop.ResolveId, desktop, REVEAL_UNDERGROUND_WINDOW_ID)
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

local function BuildSwitchButton()
	local desktop = (Global("terminal") or {}).desktop
	local button_class = Global("XTextButton")
	local box = Global("box")
	if not desktop or type(button_class) ~= "table" or type(box) ~= "function" then return nil end

	local button = button_class:new({
		Id = SWITCH_WINDOW_ID,
		Text = "Switch to Underground",
		Translate = false,
		TextStyle = "ConsoleLog",
		HAlign = "right",
		VAlign = "bottom",
		Margins = box(0, 0, 30, 30),
		Padding = box(12, 4, 12, 4),
		Background = Color(45, 50, 70, 235),
		RolloverBackground = Color(65, 75, 105, 235),
		PressedBackground = Color(35, 40, 58, 235),
		RolloverTextColor = Color(236, 236, 238, 255),
		DisabledTextColor = Color(236, 236, 238, 255),
		DisabledRolloverTextColor = Color(236, 236, 238, 255),
		ZOrder = 100000,
		OnPress = function() SwitchToUnderground() end,
	}, desktop)
	State.switch_to_underground_button_window = button
	if WindowLive(button) and type(button.SetTextColor) == "function" then
		button:SetTextColor(Color(236, 236, 238, 255))
	end
	if WindowLive(button) and type(button.Open) == "function" then pcall(button.Open, button) end
	return button
end

local function BuildRevealSurfaceButton()
	local desktop = (Global("terminal") or {}).desktop
	local button_class = Global("XTextButton")
	local box = Global("box")
	if not desktop or type(button_class) ~= "table" or type(box) ~= "function" then return nil end

	local button = button_class:new({
		Id = REVEAL_SURFACE_WINDOW_ID,
		Text = "Reveal Surface Sectors",
		Translate = false,
		TextStyle = "ConsoleLog",
		HAlign = "right",
		VAlign = "bottom",
		Margins = box(0, 0, 30, 110),
		Padding = box(12, 4, 12, 4),
		Background = Color(38, 78, 52, 235),
		RolloverBackground = Color(55, 110, 72, 235),
		PressedBackground = Color(28, 58, 38, 235),
		RolloverTextColor = Color(236, 236, 238, 255),
		DisabledTextColor = Color(236, 236, 238, 255),
		DisabledRolloverTextColor = Color(236, 236, 238, 255),
		ZOrder = 100000,
		OnPress = function() RevealAllSurfaceSectors() end,
	}, desktop)
	State.reveal_surface_sectors_button_window = button
	if WindowLive(button) and type(button.SetTextColor) == "function" then
		button:SetTextColor(Color(236, 236, 238, 255))
	end
	if WindowLive(button) and type(button.Open) == "function" then pcall(button.Open, button) end
	return button
end

local function BuildRevealUndergroundButton()
	local desktop = (Global("terminal") or {}).desktop
	local button_class = Global("XTextButton")
	local box = Global("box")
	if not desktop or type(button_class) ~= "table" or type(box) ~= "function" then return nil end

	local button = button_class:new({
		Id = REVEAL_UNDERGROUND_WINDOW_ID,
		Text = "Reveal Underground All",
		Translate = false,
		TextStyle = "ConsoleLog",
		HAlign = "right",
		VAlign = "bottom",
		Margins = box(0, 0, 30, 150),
		Padding = box(12, 4, 12, 4),
		Background = Color(62, 45, 82, 235),
		RolloverBackground = Color(88, 65, 115, 235),
		PressedBackground = Color(46, 34, 62, 235),
		RolloverTextColor = Color(236, 236, 238, 255),
		DisabledTextColor = Color(236, 236, 238, 255),
		DisabledRolloverTextColor = Color(236, 236, 238, 255),
		ZOrder = 100000,
		OnPress = function() RevealAllUnderground() end,
	}, desktop)
	State.reveal_underground_all_button_window = button
	if WindowLive(button) and type(button.SetTextColor) == "function" then
		button:SetTextColor(Color(236, 236, 238, 255))
	end
	if WindowLive(button) and type(button.Open) == "function" then pcall(button.Open, button) end
	return button
end

local function RemoveRetiredTestButtons(desktop)
	desktop = desktop or (Global("terminal") or {}).desktop
	local seen = {}
	local function remove(window)
		if not WindowLive(window) or seen[window] then return end
		seen[window] = true
		if type(window.delete) == "function" then
			SafeCall(window.delete, window)
		elseif type(window.SetVisible) == "function" then
			SafeCall(window.SetVisible, window, false)
		end
	end

	local buried_windows = State.place_buried_wonder_test_button_windows
	if type(buried_windows) == "table" then
		for _, window in pairs(buried_windows) do remove(window) end
	end
	remove(State.underground_darkness_toggle_button_window)
	if desktop and type(desktop.ResolveId) == "function" then
		for _, id in ipairs(RETIRED_WINDOW_IDS) do
			remove(SafeCall(desktop.ResolveId, desktop, id))
		end
	end

	State.place_buried_wonder_test_button_windows = nil
	State.underground_darkness_toggle_button_window = nil
	State.place_buried_wonder_test_button_armed = nil
end

local PlaceElevatorButton = {}

function PlaceElevatorButton.Show()
	local map = Global("CurrentMap")
	if not IsGameplayMap(map) then
		return PlaceElevatorButton.Hide()
	end
	local desktop = (Global("terminal") or {}).desktop
	RemoveRetiredTestButtons(desktop)
	local elevator_ok = true
	local button = ResolveExistingButton(desktop)
	local switch_button = ResolveExistingSwitchButton(desktop)
	local reveal_surface_button = ResolveExistingRevealSurfaceButton(desktop)
	local reveal_underground_button = ResolveExistingRevealUndergroundButton(desktop)
	local show_elevator = CanUseOnMap(map)
	if show_elevator and not WindowLive(button) then button = BuildButton() end
	if show_elevator and not WindowLive(switch_button) then switch_button = BuildSwitchButton() end
	if show_elevator and not WindowLive(reveal_surface_button) then
		reveal_surface_button = BuildRevealSurfaceButton()
	end
	if show_elevator and not WindowLive(reveal_underground_button) then
		reveal_underground_button = BuildRevealUndergroundButton()
	end
	if WindowLive(button) and type(button.SetVisible) == "function" then
		SafeCall(button.SetVisible, button, show_elevator)
	elseif show_elevator then
		elevator_ok = false
	end
	if WindowLive(switch_button) and type(switch_button.SetVisible) == "function" then
		SafeCall(switch_button.SetVisible, switch_button, show_elevator)
	elseif show_elevator then
		elevator_ok = false
	end
	if WindowLive(reveal_surface_button) and type(reveal_surface_button.SetVisible) == "function" then
		SafeCall(reveal_surface_button.SetVisible, reveal_surface_button, show_elevator)
	elseif show_elevator then
		elevator_ok = false
	end
	if WindowLive(reveal_underground_button)
		and type(reveal_underground_button.SetVisible) == "function" then
		SafeCall(reveal_underground_button.SetVisible, reveal_underground_button, show_elevator)
	elseif show_elevator then
		elevator_ok = false
	end
	return elevator_ok
end

function PlaceElevatorButton.Hide()
	local desktop = (Global("terminal") or {}).desktop
	RemoveRetiredTestButtons(desktop)
	local button = ResolveExistingButton(desktop)
	local switch_button = ResolveExistingSwitchButton(desktop)
	local reveal_surface_button = ResolveExistingRevealSurfaceButton(desktop)
	local reveal_underground_button = ResolveExistingRevealUndergroundButton(desktop)
	if WindowLive(button) and type(button.SetVisible) == "function" then
		SafeCall(button.SetVisible, button, false)
	end
	if WindowLive(switch_button) and type(switch_button.SetVisible) == "function" then
		SafeCall(switch_button.SetVisible, switch_button, false)
	end
	if WindowLive(reveal_surface_button) and type(reveal_surface_button.SetVisible) == "function" then
		SafeCall(reveal_surface_button.SetVisible, reveal_surface_button, false)
	end
	if WindowLive(reveal_underground_button)
		and type(reveal_underground_button.SetVisible) == "function" then
		SafeCall(reveal_underground_button.SetVisible, reveal_underground_button, false)
	end
	State.place_elevator_button_armed = nil
	State.switch_to_underground_button_force_reveal = nil
	State.reveal_surface_sectors_running = nil
	State.reveal_underground_all_running = nil
	return true
end

PlaceElevatorButton.ApplyModBehavior = PlaceElevatorButton.Show
PlaceElevatorButton.RestoreVanillaBehavior = PlaceElevatorButton.Hide
PlaceElevatorButton.HandleConstructionSitePlaced = HandleConstructionSitePlaced
PlaceElevatorButton.SwitchToUnderground = SwitchToUnderground
PlaceElevatorButton.RevealAllSurfaceSectors = RevealAllSurfaceSectors
PlaceElevatorButton.RevealAllUnderground = RevealAllUnderground
SuperBigMap.PlaceElevatorButton = PlaceElevatorButton

State.place_elevator_button_message_handler = HandleConstructionSitePlaced
if State.place_elevator_button_message_registered ~= true then
	State.place_elevator_button_message_registered = true
	Engine.ChainOnMsg("ConstructionSitePlaced", function(...)
		local handler = (SuperBigMap.State or {}).place_elevator_button_message_handler
		if type(handler) == "function" then return handler(...) end
	end)
end

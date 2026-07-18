-- Super Big Map -- temporary free, instant Elevator placement button.
--
-- This test aid uses the normal Elevator construction cursor and snap rules, then quick-builds
-- the next Elevator construction site. It is enabled only by PLACE_ELEVATOR_BUTTON_ENABLED.

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

local function IsModMap(map)
	local grid = SuperBigMap.SectorGrid
	return grid and type(grid.IsModMap) == "function" and grid.IsModMap(map) == true
end

local function StartElevatorPlacement()
	if not Enabled() or not IsModMap(Global("CurrentMap")) then return false end
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

local function HandleConstructionSitePlaced(site, class_name)
	if State.place_elevator_button_armed ~= true then return end
	if not Enabled() then
		State.place_elevator_button_armed = nil
		return
	end
	if not IsElevatorSite(site, class_name) then return end
	State.place_elevator_button_armed = nil

	local function finish()
		if site and type(site.Complete) == "function" then
			pcall(site.Complete, site, "quick_build")
		end
	end
	local create_thread = Global("CreateGameTimeThread")
	if type(create_thread) == "function" then create_thread(finish) else finish() end
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
	if not Enabled() or not IsModMap(Global("CurrentMap")) then
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

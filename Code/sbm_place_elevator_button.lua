-- Super Big Map -- TEMPORARY "Place Elevator" debug button (bottom-right, above Scan All).
--
-- One on-screen button for testing surface<->underground entrance correspondence: press it,
-- place the Elevator with the game's NORMAL placement cursor, and the construction site is
-- completed INSTANTLY on placement (ConstructionSite:Complete("quick_build") -- the same call
-- vanilla's own 'Construct all buildings' cheat uses). quick_build finishes the site before any
-- resource is requested or delivered, so the elevator costs NOTHING and needs no tech (the
-- template is force-unlocked on press). Gated by Config.PLACE_ELEVATOR_BUTTON_ENABLED; TEMP --
-- turn OFF for release. Self-contained, modeled on sbm_scan_all_button.lua.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall

local function cfg() return SuperBigMap.Config or {} end

local button = false
local armed = false -- next Elevator construction site placed gets instantly completed

local function Valid()
	return button and button.window_state ~= "destroying" and button.window_state ~= "destroyed"
end

local function Color(r, g, b, a)
	local RGBA = Global("RGBA")
	return (type(RGBA) == "function") and RGBA(r, g, b, a) or 0
end
local function White() return Color(236, 236, 238, 255) end

local function Log(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then DebugLog.Info("Lifecycle", message, data) end
end

-- Press: unlock the Elevator template (placement rejects locked buildings), arm the one-shot
-- instant-complete, and enter the game's normal construction placement for it. The player then
-- clicks where they want it -- real placement rules (flat ground etc.) apply, cost does not.
local function StartElevatorPlacement()
	local igi_fn = Global("GetInGameInterface")
	local igi = type(igi_fn) == "function" and igi_fn() or nil
	if not igi or type(igi.SetMode) ~= "function" then
		Log("place-elevator: no in-game interface")
		return
	end
	local unlock = Global("UnlockBuilding")
	if type(unlock) == "function" then pcall(unlock, "Elevator") end
	-- VANILLA SNAP RULE kept as-is (user's choice): the Elevator template has
	-- snap_target_type="ElevatorPassage" + only_build_on_snapped_locations=true, so it may only
	-- be built over an existing ElevatorPassage (the natural Underground Entrance / Surface
	-- Tunnel structures, present from map generation). Ensure the flag is at its vanilla value
	-- (repairs a session where the earlier lift ran) and log the template state.
	local templates = Global("BuildingTemplates")
	local tmpl = type(templates) == "table" and templates.Elevator or nil
	if tmpl then
		if tmpl.only_build_on_snapped_locations == false then
			tmpl.only_build_on_snapped_locations = true
			Log("place-elevator: snap requirement RESTORED to vanilla")
		end
		Log("place-elevator: template snap props", {
			snap_target_type = tostring(tmpl.snap_target_type),
			only_on_snapped = tostring(tmpl.only_build_on_snapped_locations),
			rotate_to_snap = tostring(tmpl.rotate_to_snap_target),
		})
	else
		Log("place-elevator: BuildingTemplates.Elevator NOT FOUND", { templates_type = type(templates) })
	end
	-- SNAP-TARGET DIAGNOSTICS: enumerate every valid snap target (ElevatorPassage objects) and
	-- every tunnel marker on the current map, with class/pos/sector -- the log then answers "why
	-- didn't it snap": either no ElevatorPassage exists, or the targets are not where you aimed.
	do
		local map = Global("CurrentMap")
		local get_sector = Global("GetMapSectorXY")
		local city = map and map.City
		local function sector_at(x, y)
			if not city or type(get_sector) ~= "function" then return "?" end
			local ok, sec = pcall(get_sector, city, x, y)
			return tostring((ok and sec) and sec.id or "nil")
		end
		local function dump(class_name)
			local n = 0
			if map and type(map.MapForEach) == "function" then
				pcall(map.MapForEach, map, "map", class_name, function(o)
					n = n + 1
					local ok, x, y = pcall(function()
						local p = o:GetPos()
						return p:x(), p:y()
					end)
					Log("place-elevator: snap-diag object", {
						query = class_name, n = n, class = tostring(o.class or "?"),
						xy = ok and (tostring(x) .. "," .. tostring(y)) or "?",
						sector = ok and sector_at(x, y) or "?",
					})
				end)
			end
			return n
		end
		local n_passage = dump("ElevatorPassage")
		local n_markers = dump("SurfaceUndergroundTunnelMarker")
		Log("place-elevator: snap-diag summary", {
			elevator_passages = n_passage, tunnel_markers = n_markers,
			note = n_passage == 0 and "NO SNAP TARGETS EXIST on this map" or "snap only works over the listed ElevatorPassage sectors",
		})
	end
	armed = true
	SafeCall(igi.SetMode, igi, "construction", { template = "Elevator" })
	Log("place-elevator: placement mode entered (instant-complete armed)")
end

-- One-shot instant completion: fires for the NEXT Elevator site placed while armed. Runs the
-- completion on a game-time thread (Complete mutates game state).
function OnMsg.ConstructionSitePlaced(site, class_name)
	if not armed then return end
	if cfg().PLACE_ELEVATOR_BUTTON_ENABLED ~= true then armed = false return end
	local is_elevator = class_name == "Elevator"
		or (site and (site.building_class == "Elevator"
			or (type(site.GetBuildingClass) == "function" and select(2, pcall(site.GetBuildingClass, site)) == "Elevator")))
	if not is_elevator then return end
	armed = false
	local create_gt = Global("CreateGameTimeThread")
	local function finish()
		if site and type(site.Complete) == "function" then
			local ok, err = pcall(site.Complete, site, "quick_build")
			Log("place-elevator: site instantly completed", { ok = ok, err = ok and nil or tostring(err) })
		end
	end
	if type(create_gt) == "function" then create_gt(finish) else finish() end
end

local function Hide()
	if Valid() and type(button.delete) == "function" then
		pcall(function() button:delete() end)
	end
	button = false
	armed = false
end

local function Build()
	local desktop = (Global("terminal") or {}).desktop
	local XTextButton = Global("XTextButton")
	local box = Global("box")
	if not desktop or type(XTextButton) ~= "table" then
		return false
	end
	button = XTextButton:new({
		Id = "SBMPlaceElevator",
		Text = "Place Elevator",
		Translate = false,
		TextStyle = "ConsoleLog",
		HAlign = "right",
		VAlign = "bottom",
		Margins = box(0, 0, 30, 70), -- sits just above the Scan All Sectors button
		Padding = box(12, 4, 12, 4),
		Background = Color(70, 55, 30, 235),
		RolloverBackground = Color(105, 82, 45, 235),
		PressedBackground = Color(55, 42, 22, 235),
		RolloverTextColor = White(),
		DisabledTextColor = White(),
		DisabledRolloverTextColor = White(),
		ZOrder = 100000,
		OnPress = function(_self, _gamepad) SafeCall(StartElevatorPlacement) end,
	}, desktop)
	if Valid() and type(button.SetTextColor) == "function" then button:SetTextColor(White()) end
	if Valid() and type(button.Open) == "function" then pcall(function() button:Open() end) end
	return true
end

local PlaceElevatorButton = {}

function PlaceElevatorButton.Show()
	if cfg().PLACE_ELEVATOR_BUTTON_ENABLED ~= true then return false end
	if Valid() then return true end
	return Build()
end

PlaceElevatorButton.Hide = Hide

SuperBigMap.PlaceElevatorButton = PlaceElevatorButton

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

-- Never delete an XWindow while mod code itself is being hot-reloaded. ReloadLua reconstructs the
-- X class tables and desktop incrementally; the previous implementation called old_api.Hide here,
-- and XWindow:delete reached XDesktop:ChildLeaving while InvalidateMeasure/child state was only
-- partially rebuilt. A reload-safe API now only HIDES its old window. Legacy copies without that
-- API are left untouched here and are retired by Build through the reload-safe API/desktop ID
-- lookup once UI class reconstruction has completed. Module load itself performs no UI mutation.
local previous_button_api = SuperBigMap.PlaceElevatorButton
local previous_button_retired = false

local button = false
local armed = false -- next Elevator construction site placed gets instantly completed

local function Valid()
	return button and button.window_state ~= "destroying" and button.window_state ~= "destroyed"
end

local function WindowLive(win)
	return type(win) == "table"
		and win.window_state ~= "destroying" and win.window_state ~= "destroyed"
end

local function Color(r, g, b, a)
	local RGBA = Global("RGBA")
	return (type(RGBA) == "function") and RGBA(r, g, b, a) or 0
end
local function White() return Color(236, 236, 238, 255) end

local function Log(message, data)
	-- Keep the placement-button trace beside the terrain samples. This scope is independently
	-- gated, so one switch captures the button, class method, linked sites, and Quick Build.
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then DebugLog.Info("ElevatorTerrain", message, data) end
end

local function RetireWindowWithoutDelete(win, reason)
	if not WindowLive(win) then return true end
	local hidden = false
	if type(win.SetVisible) == "function" then
		local ok = pcall(win.SetVisible, win, false)
		hidden = ok == true
	end
	Log("place-elevator: window retired without delete", {
		reason = tostring(reason), window = tostring(win), hidden = tostring(hidden),
		state = tostring(win.window_state), parent = tostring(win.parent),
	})
	return hidden
end

local function DesktopReadyForWindowDelete(win)
	if not WindowLive(win) or type(win.delete) ~= "function"
		or type(win.InvalidateMeasure) ~= "function" then return false end
	local parent = win.parent
	if parent and (type(parent) ~= "table"
		or parent.window_state == "destroying" or parent.window_state == "destroyed"
		or type(parent.InvalidateMeasure) ~= "function") then
		return false
	end
	return true
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
			local rockets = SuperBigMap.RocketRules
			local map = type(site.GetMap) == "function" and SafeCall(site.GetMap, site) or nil
			local pos = type(site.GetPos) == "function" and SafeCall(site.GetPos, site) or nil
			local before = rockets and type(rockets.CaptureElevatorTerrain) == "function"
				and rockets.CaptureElevatorTerrain(map, pos, "PrimaryBeforeQuickComplete") or nil
			local ok, err = pcall(site.Complete, site, "quick_build")
			Log("place-elevator: site instantly completed", { ok = ok, err = ok and nil or tostring(err) })
			local after = rockets and type(rockets.CaptureElevatorTerrain) == "function"
				and rockets.CaptureElevatorTerrain(map, pos, "PrimaryAfterQuickComplete") or nil
			if rockets and type(rockets.CompareElevatorTerrain) == "function" then
				rockets.CompareElevatorTerrain(before, after, "Primary QuickBuild Complete")
			end
		end
	end
	if type(create_gt) == "function" then create_gt(finish) else finish() end
end

local function Hide()
	local old = button
	button = false
	if WindowLive(old) then
		if DesktopReadyForWindowDelete(old) then
			local ok, err = pcall(old.delete, old)
			Log("place-elevator: window delete", {
				window = tostring(old), ok = tostring(ok), error = ok and nil or tostring(err),
			})
		else
			RetireWindowWithoutDelete(old, "unsafe desktop teardown context")
		end
	end
	armed = false
end

local function RetireForReload(reason)
	local old = button
	button = false
	armed = false
	return RetireWindowWithoutDelete(old, reason or "module reload")
end

local function Build()
	local desktop = (Global("terminal") or {}).desktop
	local XTextButton = Global("XTextButton")
	local box = Global("box")
	if not desktop or type(XTextButton) ~= "table" then
		return false
	end
	if not previous_button_retired then
		previous_button_retired = true
		if previous_button_api and type(previous_button_api.RetireForReload) == "function" then
			pcall(previous_button_api.RetireForReload, "first Build after module reload")
		end
	end
	-- Upgrade path from module versions that exposed only destructive Hide(): find the existing
	-- button by ID after the desktop is healthy and hide it without changing parent/child ownership.
	if type(desktop.ResolveId) == "function" then
		local ok_existing, existing = pcall(desktop.ResolveId, desktop, "SBMPlaceElevator")
		if ok_existing and existing and existing ~= button then
			RetireWindowWithoutDelete(existing, "stale pre-reload button found by desktop ID")
		end
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
	if cfg().PLACE_ELEVATOR_BUTTON_ENABLED ~= true then
		Hide()
		return false
	end
	if Valid() then return true end
	return Build()
end

PlaceElevatorButton.Hide = Hide
PlaceElevatorButton.RetireForReload = RetireForReload

SuperBigMap.PlaceElevatorButton = PlaceElevatorButton

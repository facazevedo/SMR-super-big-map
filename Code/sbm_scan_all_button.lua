-- Super Big Map -- TEMPORARY "Scan all sectors" debug button (bottom-right).
--
-- A single on-screen button that scans every sector on the current map (MapSector:Scan with
-- "deep scanned", which reveals surface + subsurface + deep deposits and fires SectorScanned).
-- Useful for verifying that the reshuffled/cloned deposits in the expanded area actually reveal.
-- Gated by Config.SCAN_ALL_BUTTON_ENABLED; meant to be turned OFF when done. Self-contained.

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
local scanning = false

local function Valid()
	return button and button.window_state ~= "destroying" and button.window_state ~= "destroyed"
end

local function Color(r, g, b, a)
	local RGBA = Global("RGBA")
	return (type(RGBA) == "function") and RGBA(r, g, b, a) or 0
end
local function White() return Color(236, 236, 238, 255) end

local function SetLabel(txt)
	if Valid() and type(button.SetText) == "function" then button:SetText(txt) end
end

-- Scan every sector on the current map. Runs on a background thread (yields) so the UI stays
-- responsive on a 20x20 grid; "deep scanned" reveals all deposit tiers.
local function ScanAllSectors()
	if scanning then return end
	local map = Global("CurrentMap")
	local city = map and map.City
	if type(city) ~= "table" or type(city.MapSectors) ~= "table" then
		SetLabel("Scan All (no map)")
		return
	end
	local create_thread = Global("CreateRealTimeThread")
	local sleep = Global("Sleep")
	local function run()
		scanning = true
		SetLabel("Scanning...")
		local grid = city.MapSectors
		local scanned = 0
		local col = 1
		while type(grid[col]) == "table" do
			local colt = grid[col]
			local row = 1
			while colt[row] ~= nil do
				local sector = colt[row]
				if type(sector) == "table" and type(sector.Scan) == "function" then
					pcall(sector.Scan, sector, "deep scanned")
					scanned = scanned + 1
					if type(sleep) == "function" and scanned % 8 == 0 then sleep(1) end
				end
				row = row + 1
			end
			col = col + 1
		end
		scanning = false
		SetLabel("Scan All Sectors")
		local DebugLog = SuperBigMap.DebugLog
		if DebugLog then DebugLog.Info("Sector", "scan-all: scanned sectors", { count = scanned }) end
	end
	if type(create_thread) == "function" then create_thread(run) else run() end
end

local function Hide()
	if Valid() and type(button.delete) == "function" then
		pcall(function() button:delete() end)
	end
	button = false
	scanning = false
end

local function Build()
	local desktop = (Global("terminal") or {}).desktop
	local XTextButton = Global("XTextButton")
	local box = Global("box")
	if not desktop or type(XTextButton) ~= "table" then
		return false
	end
	button = XTextButton:new({
		Id = "SBMScanAll",
		Text = "Scan All Sectors",
		Translate = false,
		TextStyle = "ConsoleLog",
		HAlign = "right",
		VAlign = "bottom",
		Margins = box(0, 0, 30, 30),
		Padding = box(12, 4, 12, 4),
		Background = Color(40, 70, 50, 235),
		RolloverBackground = Color(60, 100, 72, 235),
		PressedBackground = Color(30, 55, 40, 235),
		RolloverTextColor = White(),
		DisabledTextColor = White(),
		DisabledRolloverTextColor = White(),
		ZOrder = 100000,
		OnPress = function(_self, _gamepad) SafeCall(ScanAllSectors) end,
	}, desktop)
	if Valid() and type(button.SetTextColor) == "function" then button:SetTextColor(White()) end
	if Valid() and type(button.Open) == "function" then pcall(function() button:Open() end) end
	return true
end

local ScanAllButton = {}

function ScanAllButton.Show()
	if cfg().SCAN_ALL_BUTTON_ENABLED ~= true then return false end
	if Valid() then return true end
	return Build()
end

ScanAllButton.Hide = Hide

SuperBigMap.ScanAllButton = ScanAllButton

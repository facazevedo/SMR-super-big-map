-- Bigger Maps -- overview scan hover-highlight alignment.
--
-- The scan-mode hover highlight ("SectorTarget", a SectorDecal = {Decal, Object})
-- is placed by OverviewModeDialog:SelectSector at sector.area:Center(), but unlike
-- the plain-Decal grid cells it anchors at its CORNER, so on our grids it renders
-- half a sector off (its top-left at the sector center) even though scans pick the
-- right sector. This re-places it at a half-sector offset on custom maps so it lines
-- up. Driven by the sector-exploration patch (InstallSectorPatch calls Install()).

local BiggerMaps = rawget(_G, "BiggerMaps")
if type(BiggerMaps) ~= "table" then
	BiggerMaps = {}
	rawset(_G, "BiggerMaps", BiggerMaps)
end

local Engine = BiggerMaps.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local Round = Engine.Round
local ClassTable = Engine.ClassTable
local SECTOR_PATCH_VERSION = BiggerMaps.SECTOR_PATCH_VERSION or 21

local function DebugPrint(message)
	local DebugLog = BiggerMaps.DebugLog
	if DebugLog then
		DebugLog.Info("Sector", message)
	end
end

local function Install()
	local State = BiggerMaps.State
	if State.overview_highlight_patch_version == SECTOR_PATCH_VERSION then
		return true
	end

	local overview_class = ClassTable("OverviewModeDialog")
	if not overview_class or type(overview_class.SelectSector) ~= "function" then
		return false
	end

	local Grid = BiggerMaps.SectorGrid
	local original_select_sector = State.original_overview_select_sector or overview_class.SelectSector
	State.original_overview_select_sector = original_select_sector

	overview_class.SelectSector = function(self, sector, ...)
		local result = original_select_sector(self, sector, ...)
		local point_fn = Global("point")
		if sector and sector.area and self.sector_obj and type(point_fn) == "function"
				and Grid and Grid.UseCustomSectorsForMap(Global("CurrentMap")) then
			-- The highlight decal anchors at a corner, so it lands half a sector off
			-- the cell. Nudge it back by half a sector on each axis -- a fixed
			-- per-sector compensation, independent of grid origin, count or size.
			local half = Round(sector.area:sizex() / 2)
			SafeCall(self.sector_obj.SetPos, self.sector_obj, sector.area:Center() + point_fn(half, half, 0))
		end
		return result
	end

	State.overview_highlight_patch_version = SECTOR_PATCH_VERSION
	DebugPrint("overview highlight patch installed")
	return true
end

local SectorHighlight = {}

SectorHighlight.Install = Install

function SectorHighlight.ApplyModBehavior()
	Install()
end

function SectorHighlight.RestoreVanillaBehavior()
	local State = BiggerMaps.State
	local overview_class = ClassTable("OverviewModeDialog")
	if overview_class and State and type(State.original_overview_select_sector) == "function" then
		overview_class.SelectSector = State.original_overview_select_sector
	end
	if State then
		State.original_overview_select_sector = nil
		State.overview_highlight_patch_version = nil
	end
end

BiggerMaps.SectorHighlight = SectorHighlight

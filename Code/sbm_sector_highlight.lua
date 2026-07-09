-- Super Big Map -- overview scan hover-highlight diagnostic wrapper.
--
-- Vanilla OverviewModeDialog:SelectSector places the SectorTarget decal at
-- sector.area:Center() with scale = sector.area:sizex(). Once MapSectors is
-- correctly rebuilt to our vanilla-sized layout (via EnsureSectorsBuilt) the
-- vanilla path produces a correctly-aligned highlight, so this module no longer
-- needs to re-position the decal. The SelectSector override is kept only to log
-- the selected sector's identity + area dimensions when
-- Config.SHOW_SECTOR_DIAGNOSTICS is on -- useful next time the overview grid
-- drifts and we need to see what sector size + position the highlight is using.
-- Driven by the sector-exploration patch (InstallSectorPatch calls Install()).

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local ClassTable = Engine.ClassTable
local SECTOR_PATCH_VERSION = SuperBigMap.SECTOR_PATCH_VERSION or 21

local function DebugPrint(message)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Sector", message)
	end
end

local function Install()
	local State = SuperBigMap.State
	if State.overview_highlight_patch_version == SECTOR_PATCH_VERSION then
		return true
	end

	local overview_class = ClassTable("OverviewModeDialog")
	if not overview_class or type(overview_class.SelectSector) ~= "function" then
		return false
	end

	local original_select_sector = State.original_overview_select_sector or overview_class.SelectSector
	State.original_overview_select_sector = original_select_sector

	-- One-shot diagnostic helper: when Config.SHOW_SECTOR_DIAGNOSTICS is on, log
	-- the selected sector's identity + area dimensions every time a NEW sector
	-- is hovered (vanilla's SelectSector already gates on sector_id change so we
	-- can rely on that being throttled). The visible width/height of sector.area
	-- is what vanilla feeds into the SectorTarget decal's SetScale -- so if this
	-- prints e.g. 81920 instead of 40960 on an 8192 mapdata map, we know the
	-- hover highlight is being scaled to 2x our sector size because MapSectors
	-- was built by vanilla InitSectors (10x10 huge sectors) rather than rebuilt
	-- to our layout.
	local last_logged_id = false
	local function DiagSelect(sector)
		local DebugLog = SuperBigMap.DebugLog
		if not (DebugLog and DebugLog.On("Sector")) then
			return
		end
		if not sector then
			return
		end
		local id = sector.id
		if id == last_logged_id then
			return
		end
		last_logged_id = id
		local sx, sy = "?", "?"
		if sector.area then
			local ok1, vx = pcall(sector.area.sizex, sector.area)
			local ok2, vy = pcall(sector.area.sizey, sector.area)
			if ok1 then sx = tostring(vx) end
			if ok2 then sy = tostring(vy) end
		end
		DebugLog.Info("Sector", string.format(
			"SelectSector id=%s col=%s row=%s area_size=%sx%s",
			tostring(id), tostring(sector.col), tostring(sector.row), sx, sy
		))
	end

	local is_valid = Engine.Global("IsValid")
	overview_class.SelectSector = function(self, sector, ...)
		DiagSelect(sector)
		-- Guard against a destroyed hover-highlight object. self.sector_obj is the
		-- dialog's SectorTarget/SectorRadius decal (placed in CurrentMap); our sector
		-- rebuild (forced InitSectors) and surface/underground map switches can
		-- invalidate it WHILE overview is open. Vanilla SelectSector uses it with no
		-- validity check (self.sector_obj:SetPos at OverviewModeDialog.lua:524) and
		-- the engine asserts "Expected luaGameObject" when it was destroyed. If it is
		-- truthy-but-invalid (so vanilla won't early-return on `not self.sector_obj`),
		-- recreate it via the game's own EnsureSectorObjPresent -- idempotent, and a
		-- no-op when the object is still valid or simply absent (false).
		if self.sector_obj and type(is_valid) == "function" and not is_valid(self.sector_obj)
			and type(self.EnsureSectorObjPresent) == "function" then
			pcall(function() self:EnsureSectorObjPresent() end)
		end
		return original_select_sector(self, sector, ...)
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
	local State = SuperBigMap.State
	local overview_class = ClassTable("OverviewModeDialog")
	if overview_class and State and type(State.original_overview_select_sector) == "function" then
		overview_class.SelectSector = State.original_overview_select_sector
	end
	if State then
		State.original_overview_select_sector = nil
		State.overview_highlight_patch_version = nil
	end
end

SuperBigMap.SectorHighlight = SectorHighlight

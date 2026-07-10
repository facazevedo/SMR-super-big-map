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

	-- Hover-misalignment diagnostic (gated on Config.DEBUG_HOVER, scope "Hover"): per NEW hovered
	-- sector, log the terrain-cursor world position, the cursor ray-hit Z vs the AUTHORITATIVE
	-- terrain height at that x,y (a large dz means the mouse ray intersected a STALE height
	-- surface -- e.g. pre-stretch heights -- so the cursor lands at the wrong world point), the
	-- resolved sector + bounds, and whether the cursor is inside it (false = sector math wrong).
	-- One line per sector as the mouse sweeps; enough to tell WHICH half of the mapping is off.
	local last_hover_id = false
	local function HoverDiag(sector)
		local DebugLog = SuperBigMap.DebugLog
		if not (DebugLog and DebugLog.On("Hover")) then return end
		if not sector or sector.id == last_hover_id then return end
		last_hover_id = sector.id
		local Global = Engine.Global
		local gtc = Global("GetTerrainCursor")
		if type(gtc) ~= "function" then return end
		local ok_c, cur = pcall(gtc)
		if not ok_c or not cur then return end
		local cx, cy, cz
		if type(cur.xyz) == "function" then
			local ok; ok, cx, cy, cz = pcall(cur.xyz, cur)
			if not ok then cx = nil end
		end
		if type(cx) ~= "number" or type(cy) ~= "number" then return end
		-- Authoritative height at the cursor's x,y (post-stretch grid).
		local h
		local terrain_api = Global("terrain")
		if type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function" then
			local map = Global("CurrentMap")
			local ok_h, v = pcall(terrain_api.GetHeight, map, cur)
			if not ok_h then ok_h, v = pcall(terrain_api.GetHeight, cur) end
			if ok_h and type(v) == "number" then h = v end
		end
		-- Sector bounds + containment.
		local inside, bounds = "?", "?"
		if sector.area then
			local ok_ctr, ctr = pcall(sector.area.Center, sector.area)
			local ok_sx, sx = pcall(sector.area.sizex, sector.area)
			local ok_sy, sy = pcall(sector.area.sizey, sector.area)
			if ok_ctr and ctr and ok_sx and ok_sy and type(ctr.xy) == "function" then
				local ok_xy, ax, ay = pcall(ctr.xy, ctr)
				if ok_xy and type(ax) == "number" then
					local x1, y1 = ax - sx / 2, ay - sy / 2
					local x2, y2 = ax + sx / 2, ay + sy / 2
					inside = (cx >= x1 and cx <= x2 and cy >= y1 and cy <= y2)
					bounds = string.format("%d,%d..%d,%d", x1, y1, x2, y2)
				end
			end
		end
		DebugLog.Info("Hover", "hovered sector", {
			sector = tostring(sector.id), col = sector.col, row = sector.row,
			cursor_xy = tostring(cx) .. "," .. tostring(cy),
			cursor_z = cz, terrain_h = h,
			dz = (type(cz) == "number" and type(h) == "number") and (cz - h) or "?",
			bounds = bounds, cursor_inside_sector = inside,
		})
	end

	local is_valid = Engine.Global("IsValid")

	-- Visual-condition diagnostic (gated on Config.DEBUG_HOVER): vanilla SelectSector early-outs
	-- before drawing the highlight/rollover on any of these -- no sector_obj decal,
	-- IsExplorationAvailable_Sectors false (vanilla hard-gates underground/asteroid!), a running
	-- camera transition, IsExplorationAvailable_Queue false or a popup (both kill the rollover).
	-- One line per newly hovered sector with every condition, so "hover shows nothing" is
	-- immediately attributable to the exact failing gate.
	local last_visual_id = false
	local function HoverVisualDiag(self, sector)
		local DebugLog = SuperBigMap.DebugLog
		if not (DebugLog and DebugLog.On("Hover")) then return end
		if not sector or sector.id == last_visual_id then return end
		last_visual_id = sector.id
		local Global = Engine.Global
		local uicity = Global("UICity")
		local function avail(fn_name)
			local fn = Global(fn_name)
			if type(fn) ~= "function" or not uicity then return "?" end
			local ok, v = pcall(fn, uicity)
			return ok and (v == true) or false
		end
		local notif = "?"
		local get_dialog = Global("GetDialog")
		if type(get_dialog) == "function" then
			local ok, d = pcall(get_dialog, "PopupNotification")
			if ok then notif = d ~= nil end
		end
		local obj = self.sector_obj
		local obj_state = obj == nil and "nil"
			or (type(is_valid) == "function" and not is_valid(obj)) and "INVALID"
			or "valid"
		DebugLog.Info("Hover", "visual conditions", {
			sector = tostring(sector.id),
			sector_obj = obj_state,
			avail_sectors = avail("IsExplorationAvailable_Sectors"),
			avail_queue = avail("IsExplorationAvailable_Queue"),
			camera_transition = Global("CameraTransitionThread") and true or false,
			popup_notification_up = notif,
			dialog_sector_id = tostring(self.sector_id),
		})
	end

	overview_class.SelectSector = function(self, sector, ...)
		DiagSelect(sector)
		HoverDiag(sector)
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
		local r1, r2 = original_select_sector(self, sector, ...)
		HoverVisualDiag(self, sector)
		return r1, r2
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

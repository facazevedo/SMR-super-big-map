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

	-- Declared FIRST: every helper below (frame create/destroy, hover-frame reuse check, the
	-- wrapper's sector_obj guard, the visual diagnostics) validates objects through this.
	local is_valid = Engine.Global("IsValid")

	-- True when the currently VIEWED city/map is the underground and the underground exploration
	-- UI feature is on. Drives the underground-specific rollover/frame/queue behavior below.
	local function UndergroundUiActive()
		if (SuperBigMap.Config or {}).UNDERGROUND_EXPLORATION_UI ~= true then return false end
		local uicity = Engine.Global("UICity")
		if not uicity then return false end
		local ok, env = pcall(function() return uicity:GetMap().mapdata.Environment end)
		return ok and env == "Underground"
	end

	-- UNDERGROUND overview HOVER frame: an OUTLINE-ONLY sector frame (opaque border, transparent
	-- interior), built from the game's own per-sector grid decal entity ("SectorUnexplored" -- a
	-- thin square outline). The vanilla hover decal (SectorTarget) FILLS its interior, so
	-- underground we hide it and drive this outline frame instead; it follows the hovered sector
	-- and exists only while the underground overview is active (torn down on OverviewMode(false)
	-- and on map switches via SectorHighlight.UpdateUndergroundOverviewFrames). The former cyan
	-- entrance frames were removed at the user's request.
	local function FrameForSector(map, sector, red, quiet)
		local place = Engine.Global("PlaceObjectIn")
		local mdr = Engine.Global("MulDivRound")
		local guim_v = Engine.Global("guim") or 1000
		if type(place) ~= "function" or not sector or not sector.area then return nil end
		-- Place the decal IN the sector (like vanilla UpdateDecal) so it inherits the sector's
		-- proper terrain Z; placing in the map at area:Center() (Z~=0) sank it below the
		-- underground floor -> built-but-invisible (log showed frames=2 yet nothing on screen).
		local parent = (type(sector.GetPos) == "function") and sector or map
		local ok, obj = pcall(place, "SectorUnexplored", parent)
		if not ok or not obj then return nil end
		local del_on_load = Engine.Global("DeleteOnLoadGame")
		if type(del_on_load) == "function" then pcall(del_on_load, obj) end
		local px, py
		pcall(function()
			-- Position: vanilla uses sector:GetPos() (has terrain Z); fall back to a Z-snapped
			-- area center. Explicit efVisible -- decals default hidden when placed off the
			-- normal UpdateDecal path.
			local pos
			if type(sector.GetPos) == "function" then
				local ok_p, p = pcall(sector.GetPos, sector)
				if ok_p and p then pos = p end
			end
			if not pos then
				pos = sector.area:Center()
				if type(pos.SetTerrainZ) == "function" then
					local ok_z, snapped = pcall(pos.SetTerrainZ, pos, map)
					if ok_z and snapped then pos = snapped end
				end
			end
			obj:SetPos(pos)
			if type(pos.xy) == "function" then px, py = pos:xy() end
			local scale = 100
			if type(mdr) == "function" then
				scale = mdr(sector.area:sizex(), 100, 100 * guim_v) + 1 -- vanilla UpdateDecal formula
			end
			obj:SetScale(scale)
			local const_tbl = Engine.Global("const")
			local ef_visible = type(const_tbl) == "table" and const_tbl.efVisible
			if ef_visible and type(obj.SetEnumFlags) == "function" then
				pcall(obj.SetEnumFlags, obj, ef_visible)
			end
			-- (entrance tinting removed -- the hover frame keeps the decal's default color)
		end)
		local DebugLog = SuperBigMap.DebugLog
		if DebugLog and DebugLog.On("Hover") and not quiet then
			-- Post-creation state, to distinguish "placed but not rendering" causes: is the decal
			-- still valid, is efVisible actually set, what scale/color/entity did it end up with.
			local valid_s, flags_s, scale_s, ent_s, col_s = "?", "?", "?", "?", "?"
			pcall(function()
				valid_s = (type(is_valid) == "function" and is_valid(obj)) and "valid" or "INVALID"
				if type(obj.GetEnumFlags) == "function" then
					local ct = Engine.Global("const")
					local efv = type(ct) == "table" and ct.efVisible
					if efv then flags_s = (obj:GetEnumFlags(efv) ~= 0) and "visible" or "HIDDEN" end
				end
				if type(obj.GetScale) == "function" then scale_s = tostring(obj:GetScale()) end
				if type(obj.GetEntity) == "function" then ent_s = tostring(obj:GetEntity()) end
				if type(obj.GetColorModifier) == "function" then col_s = tostring(obj:GetColorModifier()) end
			end)
			DebugLog.Info("Hover", "frame placed", {
				sector = tostring(sector.id), red = red == true,
				pos_xy = (px and py) and (tostring(px) .. "," .. tostring(py)) or "?",
				valid = valid_s, visible = flags_s, scale = scale_s, entity = ent_s, color = col_s,
			})
		end
		return obj
	end

	local function DestroyFrame(obj)
		if obj and type(is_valid) == "function" and is_valid(obj) then
			local done = Engine.Global("DoneObject")
			if type(done) == "function" then pcall(done, obj) end
		end
	end

	local function HideUndergroundHoverFrame()
		DestroyFrame(State.ug_hover_frame)
		State.ug_hover_frame = nil
		State.ug_hover_frame_sector = nil
	end

	local function UpdateUndergroundHoverFrame(sector)
		local cur_map = Engine.Global("CurrentMap")
		if not sector or not cur_map then
			HideUndergroundHoverFrame()
			return
		end
		if State.ug_hover_frame_sector == sector.id and State.ug_hover_frame
			and type(is_valid) == "function" and is_valid(State.ug_hover_frame) then
			return
		end
		HideUndergroundHoverFrame()
		State.ug_hover_frame = FrameForSector(cur_map, sector, false)
		State.ug_hover_frame_sector = sector.id
	end

	-- (The cyan entrance/exit frames were removed at the user's request -- the underground
	-- overview keeps ONLY the outline hover frame with the transparent interior.)

	-- UNDERGROUND SECTOR VEIL (config UNDERGROUND_SECTOR_VEIL): during the underground
	-- overview, EVERY sector gets its own translucent "SectorUnexplored" pane -- the same
	-- decal the hover frame uses -- so the areas BETWEEN the grid frames read as translucent
	-- panes over the terrain (user request: "I want the frames there but all of the areas
	-- between the frames should be translucid"). The hovered sector additionally carries the
	-- hover decal on top, so it reads slightly darker -- a natural hover highlight. Built on
	-- OverviewMode(true) while the underground is viewed; torn down on OverviewMode(false)
	-- and on map switches (both routed through UpdateUndergroundOverviewFrames below).
	local function HideUndergroundSectorVeil()
		for _, obj in ipairs(State.ug_sector_veil or {}) do
			DestroyFrame(obj)
		end
		State.ug_sector_veil = nil
	end

	local function ShowUndergroundSectorVeil()
		if (SuperBigMap.Config or {}).UNDERGROUND_SECTOR_VEIL ~= true then return end
		if State.ug_sector_veil then return end -- already built for this overview session
		local grid = SuperBigMap.SectorGrid
		local uicity = Engine.Global("UICity")
		local cur_map = Engine.Global("CurrentMap")
		if not (grid and type(grid.ForEachSector) == "function" and uicity and cur_map) then return end
		local veil = {}
		pcall(grid.ForEachSector, uicity, function(sector)
			local obj = FrameForSector(cur_map, sector, false, "quiet")
			if obj then veil[#veil + 1] = obj end
		end)
		State.ug_sector_veil = veil
		local DebugLog = SuperBigMap.DebugLog
		if DebugLog then DebugLog.Info("Hover", "underground sector veil built", { decals = #veil }) end
	end

	-- Exported: called by the lifecycle on OverviewMode(true/false) and on map switches.
	-- show=true while viewing the underground builds the all-sector veil; anything else tears
	-- down the veil AND the hover frame.
	-- Install() runs after module load, so SuperBigMap.SectorHighlight already exists (the local
	-- SectorHighlight table is declared later in this file, hence the namespace assignment).
	if type(SuperBigMap.SectorHighlight) == "table" then
		SuperBigMap.SectorHighlight.UpdateUndergroundOverviewFrames = function(show)
			if show and UndergroundUiActive() then
				ShowUndergroundSectorVeil()
			else
				HideUndergroundHoverFrame()
				HideUndergroundSectorVeil()
			end
		end
	end
	-- Clean up any entrance frames left over from a previous version of this patch.
	for _, obj in ipairs(State.ug_entrance_frames or {}) do
		DestroyFrame(obj)
	end
	State.ug_entrance_frames = nil

	-- UNDERGROUND rollover: informational ONLY -- "Sector <name>" + the single line
	-- "Underground". No scan status ("Unexplored"), no buildable %, no queue/probe hints:
	-- underground sectors are not scannable, the tooltip just names what the mouse is over.
	local original_generate_rollover = State.original_overview_generate_rollover
		or overview_class.GenerateSectorRolloverContext
	State.original_overview_generate_rollover = original_generate_rollover
	if type(original_generate_rollover) == "function" then
		overview_class.GenerateSectorRolloverContext = function(self, sector, forced)
			if UndergroundUiActive() then
				if (not forced and Engine.Global("CameraTransitionThread")) or not sector
					or sector.id ~= self.sector_id then
					return
				end
				local T_fn = Engine.Global("T")
				local untranslated = Engine.Global("Untranslated")
				if type(T_fn) ~= "function" or type(untranslated) ~= "function" then
					return original_generate_rollover(self, sector, forced)
				end
				local old = self.rollover_context_cache
				self.rollover_context_cache = {
					RolloverTitle = T_fn{4063, "Sector <u(display_name)>", sector},
					RolloverText = T_fn{4051, "Buildable area: <em><percent(number)></em>", number = sector.play_ratio or 0},
					RolloverAnchor = "smart",
				}
				return self.rollover_context_cache, old
			end
			return original_generate_rollover(self, sector, forced)
		end
	end

	-- UNDERGROUND queue block: the rollover requires IsExplorationAvailable_Queue==true to be
	-- created at all, which also makes sectors click-queueable -- but underground sectors are NOT
	-- scannable. No-op the queue entry point for underground sectors so clicks do nothing.
	local map_sector_class = ClassTable("MapSector")
	if map_sector_class and type(map_sector_class.QueueForExploration) == "function" then
		local original_queue = State.original_sector_queue_for_exploration or map_sector_class.QueueForExploration
		State.original_sector_queue_for_exploration = original_queue
		map_sector_class.QueueForExploration = function(self, ...)
			if (SuperBigMap.Config or {}).UNDERGROUND_EXPLORATION_UI == true then
				local ok, env = pcall(function() return self:GetMap().mapdata.Environment end)
				if ok and env == "Underground" then
					return
				end
			end
			return original_queue(self, ...)
		end
	end

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

	-- Off-map cursor test (both maps): GetTerrainCursor CLAMPS to the map edge and GetMapSectorXY
	-- CLAMPS into 1..count, so pointing into the black beyond the map still resolves a border
	-- sector and lights it up. Detect it by round-tripping the clamped terrain cursor back to
	-- screen (GameToScreen) and comparing to the real mouse position: on-map they coincide;
	-- off-map the clamp pins the cursor to the edge while the mouse is out in the black, so the
	-- screen positions diverge. Beyond a small pixel threshold -> treat as off-map (no highlight,
	-- no tooltip). Mouse-only; forced/gamepad selections skip this.
	local function CursorOffMap()
		local gtc, g2s, term = Engine.Global("GetTerrainCursor"), Engine.Global("GameToScreen"), Engine.Global("terminal")
		if type(gtc) ~= "function" or type(g2s) ~= "function" or type(term) ~= "table" then return false end
		local ok_c, cur = pcall(gtc)
		if not ok_c or not cur then return false end
		local ok_s, a, b = pcall(g2s, cur)
		if not ok_s then return false end
		local spt = b or a -- GameToScreen returns (success, pt)
		local ok_m, mpt = pcall(term.GetMousePos)
		if not ok_m or not mpt then return false end
		local function xy(p)
			if type(p) ~= "table" and type(p) ~= "userdata" then return nil end
			local ok, x, y = pcall(function() return p:x(), p:y() end)
			if ok and type(x) == "number" and type(y) == "number" then return x, y end
			return nil
		end
		local sx, sy = xy(spt)
		local mx, my = xy(mpt)
		if not sx or not mx then return false end
		local dx, dy = sx - mx, sy - my
		return (dx * dx + dy * dy) > (40 * 40)
	end

	overview_class.SelectSector = function(self, sector, rollover_pos, forced, ...)
		-- Suppress highlight + tooltip when the mouse is off the map (mouse-driven calls only;
		-- a `forced` selection e.g. overview exit_to has no meaningful cursor).
		if sector and not forced and CursorOffMap() then
			sector = false
		end
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
		local r1, r2 = original_select_sector(self, sector, rollover_pos, forced, ...)
		-- UNDERGROUND: hide the vanilla FILLED highlight (SectorTarget) + scan-pattern frames and
		-- drive our OUTLINE-ONLY hover frame instead (opaque border, transparent interior).
		if UndergroundUiActive() then
			local const_tbl = Engine.Global("const")
			local ef_visible = type(const_tbl) == "table" and const_tbl.efVisible
			if ef_visible then
				if self.sector_obj and type(self.sector_obj.ClearEnumFlags) == "function" then
					pcall(self.sector_obj.ClearEnumFlags, self.sector_obj, ef_visible)
				end
				for _, obj in ipairs(self.sector_objs or {}) do
					if obj and type(obj.ClearEnumFlags) == "function" then
						pcall(obj.ClearEnumFlags, obj, ef_visible)
					end
				end
			end
			UpdateUndergroundHoverFrame(sector) -- nil sector hides the frame
		end
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
	if overview_class and State and type(State.original_overview_generate_rollover) == "function" then
		overview_class.GenerateSectorRolloverContext = State.original_overview_generate_rollover
	end
	local map_sector_class = ClassTable("MapSector")
	if map_sector_class and State and type(State.original_sector_queue_for_exploration) == "function" then
		map_sector_class.QueueForExploration = State.original_sector_queue_for_exploration
	end
	if State then
		State.original_overview_select_sector = nil
		State.original_overview_generate_rollover = nil
		State.original_sector_queue_for_exploration = nil
		State.overview_highlight_patch_version = nil
	end
end

SuperBigMap.SectorHighlight = SectorHighlight

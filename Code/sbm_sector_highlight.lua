-- Super Big Map -- overview sector rollover and visual-control wrapper.
--
-- Vanilla OverviewModeDialog:SelectSector places the SectorTarget decal at
-- sector.area:Center() with scale = sector.area:sizex(). Once MapSectors is
-- correctly rebuilt to our vanilla-sized layout (via EnsureSectorsBuilt) the
-- vanilla path produces a correctly-aligned highlight on the surface. Underground,
-- the SelectSector override retains the rollover but suppresses all grid/highlight
-- decals. It also logs sector identity and area dimensions when diagnostics are on.
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

	-- True when the currently viewed city/map is underground and its informational sector UI is on.
	local function UndergroundUiActive()
		if (SuperBigMap.Config or {}).UNDERGROUND_EXPLORATION_UI ~= true then return false end
		local uicity = Engine.Global("UICity")
		if not uicity then return false end
		local ok, env = pcall(function() return uicity:GetMap().mapdata.Environment end)
		return ok and env == "Underground"
	end

	-- Underground sectors remain as an INVISIBLE data grid so cursor lookup, sector names, and
	-- BuildableGridRatio keep working. The user no longer wants an underground visual grid, so
	-- never create hover frames or veil panes and actively hide the game's sector decals.
	local function DestroyOldVisual(obj)
		if obj and type(is_valid) == "function" and is_valid(obj) then
			local done = Engine.Global("DoneObject")
			if type(done) == "function" then pcall(done, obj) end
		end
	end

	local function RemoveLegacyUndergroundGridVisuals()
		DestroyOldVisual(State.ug_hover_frame)
		State.ug_hover_frame = nil
		State.ug_hover_frame_sector = nil
		for _, obj in ipairs(State.ug_sector_veil or {}) do DestroyOldVisual(obj) end
		State.ug_sector_veil = nil
		for _, obj in ipairs(State.ug_entrance_frames or {}) do DestroyOldVisual(obj) end
		State.ug_entrance_frames = nil
		local thread = State.ug_veil_thread
		local delete_thread = Engine.Global("DeleteThread")
		if thread and type(delete_thread) == "function" then pcall(delete_thread, thread) end
		State.ug_veil_thread = nil
	end

	local function HideUndergroundGridVisuals()
		if not UndergroundUiActive() then return end
		local city = Engine.Global("UICity")
		local hide = Engine.Global("HideExploration_Sectors")
		if city and type(hide) == "function" then pcall(hide, city, 0) end
	end

	RemoveLegacyUndergroundGridVisuals()
	if type(SuperBigMap.SectorHighlight) == "table" then
		SuperBigMap.SectorHighlight.UpdateUndergroundOverviewVisuals = function(show)
			RemoveLegacyUndergroundGridVisuals()
			if show == true then HideUndergroundGridVisuals() end
		end
	end

	-- UNDERGROUND rollover: informational only -- sector name plus buildable-area percentage.
	-- There is no scan status or queue/probe hint because underground sectors are not scannable.
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
	if map_sector_class and type(map_sector_class.UpdateDecal) == "function" then
		local original_update_decal = State.original_map_sector_update_decal or map_sector_class.UpdateDecal
		State.original_map_sector_update_decal = original_update_decal
		map_sector_class.UpdateDecal = function(self, ...)
			local underground = false
			if (SuperBigMap.Config or {}).UNDERGROUND_EXPLORATION_UI == true then
				local ok, env = pcall(function() return self:GetMap().mapdata.Environment end)
				underground = ok and env == "Underground"
			end
			if underground then
				if self.decal and type(is_valid) == "function" and is_valid(self.decal) then
					local done = Engine.Global("DoneObject")
					if type(done) == "function" then pcall(done, self.decal) end
				end
				self.decal = nil
				return
			end
			return original_update_decal(self, ...)
		end
	end
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
		-- SCREEN-SPACE offset measurement (user report: highlighted sector is not the one
		-- under the cursor). Project the SELECTED sector's center AND the highlight decal's
		-- actual position to screen and compare with the live mouse position -- the pixel
		-- deltas measure the perceived offset directly, and the decal z vs live terrain z
		-- shows whether a stale/shifted height (v449 down-shift) displaces the visual.
		pcall(function()
			local game_to_screen = Global("GameToScreen")
			local get_mouse = Global("GetMousePos")
			local terrain_api = Global("terrain")
			local cur_map = Global("CurrentMap")
			if type(game_to_screen) ~= "function" then return end
			local mouse = type(get_mouse) == "function" and get_mouse() or nil
			local center = sector.area and sector.area:Center()
			local center_scr = center and game_to_screen(center) or nil
			local obj_pos, obj_scr, obj_z, ground_z
			if obj and type(obj.GetPos) == "function" then
				local ok_p, p = pcall(obj.GetPos, obj)
				if ok_p and p then
					obj_pos = p
					obj_scr = game_to_screen(p)
					local ok_z, z = pcall(function() return p:z() end)
					obj_z = ok_z and z or nil
					if type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function" and cur_map then
						local ok_g, g = pcall(terrain_api.GetHeight, cur_map, p)
						ground_z = ok_g and g or nil
					end
				end
			end
			local function d(a, b)
				if not (a and b) then return "n/a" end
				local ok_d, dx, dy = pcall(function()
					local ax, ay = a:xy()
					local bx, by = b:xy()
					return ax - bx, ay - by
				end)
				return ok_d and (tostring(dx) .. "," .. tostring(dy)) or "n/a"
			end
			DebugLog.Info("Hover", "screen-space offsets", {
				sector = tostring(sector.id),
				mouse = tostring(mouse),
				sector_center_scr = tostring(center_scr),
				highlight_scr = tostring(obj_scr),
				mouse_minus_center_px = d(mouse, center_scr),
				mouse_minus_highlight_px = d(mouse, obj_scr),
				highlight_pos = tostring(obj_pos),
				highlight_z = tostring(obj_z), ground_z_at_highlight = tostring(ground_z),
				z_delta = tostring(obj_z and ground_z and (obj_z - ground_z)),
			})
		end)
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
		-- UNDERGROUND: retain the rollover created by vanilla, but hide every visual selection
		-- object and sector decal. Sector resolution and play_ratio remain available as data.
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
			HideUndergroundGridVisuals()
		end
		HoverVisualDiag(self, sector)
		return r1, r2
	end

	-- ENTRANCE SIGN always visible: vanilla ScaleSmallObjects (run on overview camera
	-- transitions) sets the SurfaceUndergroundTunnelSign depth-tested in the close/normal
	-- camera (disableZ=false), so terrain occludes the ground badge and it "disappears when
	-- you come closer" (user report). Wrap it so that AFTER its animation thread finishes we
	-- re-assert no-depth-test + visible on every tunnel sign, keeping the entrance badge on
	-- top at all zooms. (MoveEntranceVisualsToScale already sets this at placement for the
	-- never-entered-overview case.) State-verified so a reload reinstalls cleanly.
	if type(overview_class.ScaleSmallObjects) == "function"
		and overview_class.ScaleSmallObjects ~= State.scale_small_objects_wrapper then
		State.original_scale_small_objects = overview_class.ScaleSmallObjects
		local function ReassertEntranceSigns(map, delay_ms)
			if not map or type(map.CreateRealTimeThread) ~= "function" then return end
			map:CreateRealTimeThread(function()
				local sleep = Engine.Global("Sleep")
				if type(sleep) == "function" and type(delay_ms) == "number" and delay_ms > 0 then
					sleep(delay_ms)
				end
				local is_valid_fn = Engine.Global("IsValid")
				local signs = map:MapGet(true, "SurfaceUndergroundTunnelSign") or {}
				for _, s in ipairs(signs) do
					if type(is_valid_fn) ~= "function" or is_valid_fn(s) then
						if type(s.SetNoDepthTest) == "function" then pcall(s.SetNoDepthTest, s, true) end
						if type(s.SetVisible) == "function" then pcall(s.SetVisible, s, true) end
						if type(s.SetOpacity) == "function" then pcall(s.SetOpacity, s, 100) end
					end
				end
			end)
		end
		local wrapper = function(self, time, direction, ...)
			local r = State.original_scale_small_objects(self, time, direction, ...)
			if (SuperBigMap.Config or {}).ALWAYS_SHOW_ENTRANCE_SIGN ~= false then
				-- Re-assert after the original's transition thread (length = time) completes.
				local map = Engine.Global("CurrentMap")
				ReassertEntranceSigns(map, (type(time) == "number" and time or 0) + 60)
			end
			return r
		end
		overview_class.ScaleSmallObjects = wrapper
		State.scale_small_objects_wrapper = wrapper
		DebugPrint("OverviewModeDialog.ScaleSmallObjects wrapped (entrance sign always visible)")
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
	if overview_class and State and State.scale_small_objects_wrapper
		and overview_class.ScaleSmallObjects == State.scale_small_objects_wrapper
		and type(State.original_scale_small_objects) == "function" then
		overview_class.ScaleSmallObjects = State.original_scale_small_objects
	end
	local map_sector_class = ClassTable("MapSector")
	if map_sector_class and State and type(State.original_sector_queue_for_exploration) == "function" then
		map_sector_class.QueueForExploration = State.original_sector_queue_for_exploration
	end
	if map_sector_class and State and type(State.original_map_sector_update_decal) == "function" then
		map_sector_class.UpdateDecal = State.original_map_sector_update_decal
	end
	if State then
		State.original_overview_select_sector = nil
		State.original_overview_generate_rollover = nil
		State.original_sector_queue_for_exploration = nil
		State.original_map_sector_update_decal = nil
		State.scale_small_objects_wrapper = nil
		State.original_scale_small_objects = nil
		State.overview_highlight_patch_version = nil
	end
end

SuperBigMap.SectorHighlight = SectorHighlight

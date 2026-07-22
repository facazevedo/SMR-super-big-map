-- Super Big Map -- overview sector rollover and visual-control wrapper.
--
-- Vanilla OverviewModeDialog:SelectSector places the SectorTarget decal at
-- sector.area:Center() with scale = sector.area:sizex(). Once MapSectors is
-- correctly rebuilt to our vanilla-sized layout (via EnsureSectorsBuilt) the
-- vanilla path produces a correctly-aligned highlight on the surface. Underground,
-- the SelectSector override retains the rollover but suppresses all grid/highlight
-- decals.
-- Driven by the sector-exploration patch (InstallSectorPatch calls Install()).

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local ClassTable = Engine.ClassTable
local SECTOR_PATCH_VERSION = SuperBigMap.SECTOR_PATCH_VERSION or 21

local function IsModMap(map)
	local grid = SuperBigMap.SectorGrid
	return type(grid) == "table" and type(grid.IsModMap) == "function"
		and grid.IsModMap(map) == true
end


-- Vanilla initializes deposit/sign visibility only for the objects that exist when
-- OverviewModeDialog:ScaleSmallObjects runs. The stretch pipeline migrates the
-- underground entrance after the first overview has already started, so both the
-- newly arrived badge and the physical passage miss that initialization until the
-- next camera transition. Apply the final state directly from engine constants;
-- this is synchronous, idempotent, and does not depend on a machine-speed timer.
local function EnsureEntranceVisualsReady(map, overview_active, reason)
	map = map or Engine.Global("CurrentMap")
	if not map or type(map.MapForEach) ~= "function" then
		return false, { reason = "map unavailable" }
	end
	-- Entrance visibility/no-depth-test changes exist only to repair objects migrated by
	-- the stretch transaction.  Native objects on a vanilla map must retain the engine's
	-- own visibility and camera initialization exactly.
	if not IsModMap(map) then
		return false, { reason = "not a mod map", vanilla = true }
	end
	if overview_active == nil then
		local is_overview = Engine.Global("IsOverviewMode")
		local ok, value = false, false
		if type(is_overview) == "function" then ok, value = pcall(is_overview) end
		overview_active = ok == true and value == true
	end

	local is_valid = Engine.Global("IsValid")
	local const_tbl = Engine.Global("const")
	local overview_scale = type(const_tbl) == "table" and const_tbl.SignsOverviewCameraScaleUp
	local overview_opacity = type(const_tbl) == "table" and const_tbl.SignsOverviewCameraOpacityUp
	local normal_scale = type(const_tbl) == "table" and const_tbl.SignsOverviewCameraScaleDown
	local normal_opacity = type(const_tbl) == "table" and const_tbl.SignsOverviewCameraOpacityDown
	local seen = {}
	local stats = {
		badges = 0,
		passages = 0,
		failed_calls = 0,
		overview = overview_active == true,
	}

	local function valid(obj)
		return obj and (type(is_valid) ~= "function" or is_valid(obj) == true)
	end
	local function invoke(obj, method, value)
		local fn = obj and obj[method]
		if type(fn) ~= "function" then return false end
		local ok = pcall(fn, obj, value)
		if not ok then stats.failed_calls = stats.failed_calls + 1 end
		return ok
	end
	local function prepare_badge(sign)
		if seen[sign] or not valid(sign) then return end
		seen[sign] = true
		stats.badges = stats.badges + 1
		local overview = overview_active == true
		local scale = overview and overview_scale or normal_scale
		local opacity = overview and overview_opacity or normal_opacity
		if type(scale) == "number" then invoke(sign, "SetScale", scale) end
		if type(opacity) == "number" then invoke(sign, "SetOpacity", opacity) end
		invoke(sign, "SetNoDepthTest", overview)
		local signs_visible = Engine.Global("g_SignsVisible") ~= false
		if not overview and Engine.Global("g_ResourceIconsVisible") == false then
			signs_visible = false
		end
		invoke(sign, "SetVisible", signs_visible and sign.revealed ~= false)
	end
	local function prepare_passage(obj)
		if seen[obj] or not valid(obj) then return end
		seen[obj] = true
		stats.passages = stats.passages + 1
		-- A completed Elevator deliberately hides its consumed passage marker and rock artwork.
		-- Preserve that state across load, map switch, and overview initialization. Older saves may
		-- not have our hidden tag yet, so the live passage.elevator link (or its counterpart's link)
		-- is authoritative as well.
		local other = obj.other
		local completed = obj.SuperBigMapHiddenByCompletedElevator == true
			or valid(obj.elevator) or valid(other and other.elevator)
		if completed then
			invoke(obj, "SetVisible", false)
			invoke(obj, "SetOpacity", 0)
			obj.SuperBigMapHiddenByCompletedElevator = true
			return
		end
		-- Temporary-source migration can preserve a hidden enum state. Physical
		-- unlinked entrance objects are real map content and must be visible in every camera mode.
		invoke(obj, "SetVisible", true)
		invoke(obj, "SetOpacity", 100)
	end

	pcall(map.MapForEach, map, "map", "SurfaceUndergroundTunnelSign", prepare_badge)
	for _, class_name in ipairs({
		"UndergroundPassageBase",
		"SurfacePassageBase",
		"SurfacePassageRocks",
		"UndergroundPassageRocks",
	}) do
		pcall(map.MapForEach, map, "map", class_name, prepare_passage)
	end

	local terrain_copy = SuperBigMap.TerrainCopy
	if terrain_copy and type(terrain_copy.RestoreEntranceBadgePositions) == "function" then
		Engine.SafeCall(terrain_copy.RestoreEntranceBadgePositions, map,
			"entrance visual readiness: " .. tostring(reason or "unspecified"))
	end
	return stats.failed_calls == 0, stats
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
	-- wrapper's sector_obj guard) validates objects through this.
	local is_valid = Engine.Global("IsValid")

	-- True when the currently viewed city/map is underground and its informational sector UI is on.
	local function UndergroundUiActive()
		if (SuperBigMap.Config or {}).UNDERGROUND_EXPLORATION_UI ~= true then return false end
		local uicity = Engine.Global("UICity")
		if not uicity then return false end
		local ok, map = pcall(function() return uicity:GetMap() end)
		return ok and IsModMap(map) and map.mapdata and map.mapdata.Environment == "Underground"
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
				-- Recalculate from this exact sector on every hover. The underground buildable grid
				-- can be finalized after MapSectors are first created, so do not reuse a stale ratio.
				local ratio = sector.play_ratio or 0
				local city = Engine.Global("UICity")
				local build_ratio = Engine.Global("BuildableGridRatio")
				local unbuildable_z = Engine.Global("buildUnbuildableZ")
				local ok_map, map = pcall(function() return city:GetMap() end)
				if ok_map and map and map.buildable and map.buildable.z_grid and sector.area
					and type(build_ratio) == "function" and type(unbuildable_z) == "function" then
					local ok_u, sentinel = pcall(unbuildable_z)
					if ok_u then
						local ok_r, live_ratio = pcall(build_ratio, map.buildable.z_grid, sentinel, 100, sector.area)
						if ok_r and type(live_ratio) == "number" then
							ratio = live_ratio
							sector.play_ratio = live_ratio
						end
					end
				end
				local old = self.rollover_context_cache
				self.rollover_context_cache = {
					RolloverTitle = T_fn{4063, "Sector <u(display_name)>", sector},
					RolloverText = T_fn{4051, "Buildable area: <em><percent(number)></em>", number = ratio},
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
				local ok, map = pcall(function() return self:GetMap() end)
				underground = ok and IsModMap(map)
					and map.mapdata and map.mapdata.Environment == "Underground"
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
				local ok, map = pcall(function() return self:GetMap() end)
				if ok and IsModMap(map) and map.mapdata and map.mapdata.Environment == "Underground" then
					return
				end
			end
			return original_queue(self, ...)
		end
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
		-- Do not run off-map suppression, object repair, or underground
		-- visual handling in a vanilla game.  Delegating at the first instruction makes
		-- the wrapper observationally equivalent to the unmodified class method.
		local uicity = Engine.Global("UICity")
		local ok_map, viewed_map = pcall(function() return uicity and uicity:GetMap() end)
		viewed_map = ok_map and viewed_map or Engine.Global("CurrentMap")
		if not IsModMap(viewed_map) then
			return original_select_sector(self, sector, rollover_pos, forced, ...)
		end
		-- Suppress highlight + tooltip when the mouse is off the map (mouse-driven calls only;
		-- a `forced` selection e.g. overview exit_to has no meaningful cursor).
		if sector and not forced and CursorOffMap() then
			sector = false
		end
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
		return r1, r2
	end

	-- Preserve the vanilla animation. The lifecycle's CameraTransitionEnd handler reapplies the
	-- exact final vanilla scale/opacity/depth state once the engine reports completion. On overview
	-- entry, initialize immediately as well so a late-migrated entrance never waits for a second
	-- zoom event.
	local original_scale = overview_class.ScaleSmallObjects
	if original_scale == State.scale_small_objects_wrapper
		and type(State.original_scale_small_objects) == "function" then
		original_scale = State.original_scale_small_objects
	end
	if type(original_scale) == "function" then
		State.original_scale_small_objects = original_scale
		local wrapper = function(self, time, direction, ...)
			local r = original_scale(self, time, direction, ...)
			if direction == "up" then
				EnsureEntranceVisualsReady(Engine.Global("CurrentMap"), true,
					"OverviewModeDialog.ScaleSmallObjects(up)")
			end
			return r
		end
		overview_class.ScaleSmallObjects = wrapper
		State.scale_small_objects_wrapper = wrapper
	end

	State.overview_highlight_patch_version = SECTOR_PATCH_VERSION
	return true
end

local SectorHighlight = {}

SectorHighlight.Install = Install
SectorHighlight.EnsureEntranceVisualsReady = EnsureEntranceVisualsReady

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

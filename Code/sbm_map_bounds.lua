-- Super Big Map -- playable-map bounds.
--
-- Expands the loaded map's playable construction boundary to the full terrain:
-- clears the vanilla PassBorder (saving the original for restore), resets the
-- play and constructable areas, rebuilds passability/buildable grids, re-fits
-- the sector grid boxes, and installs three permissive class-table overrides
-- that make construction status checks pass across the expanded edge sectors.
-- All of this is gated on Config.FULL_MAP_PLAYABLE. The per-map work is driven
-- by SuperBigMap.Lifecycle.Apply; RestoreVanillaBehavior reverses every step.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local FullHeightMin = Engine.FullHeightMin
local FullHeightMax = Engine.FullHeightMax
local Unpack = table.unpack or unpack

local function Pack(...)
	return { n = select("#", ...), ... }
end

-- Fresh per execution: same-version hot reloads must not retain old closures/code.
local MODULE_TOKEN = {}

local function IsLegacyMapBoundsFunction(fn)
	local debug_api = rawget(_G, "debug")
	if type(debug_api) ~= "table" or type(debug_api.getinfo) ~= "function" then return false end
	local ok, info = pcall(debug_api.getinfo, fn, "S")
	local source = ok and type(info) == "table" and tostring(info.source or "") or ""
	return string.find(string.lower(source), "sbm_map_bounds", 1, true) ~= nil
end

-- Gated diagnostic logging for the permissive-hook installs below. These used raw output so
-- the "[Super Big Map] Install...: wrapped ..." lines appeared in the log on every launch.
-- Route them through here so they only print when the master DEBUG_LOGS flag is on.
-- (`emit` holds the real global print; the diagnostic calls below use DebugPrint instead.)
local emit = rawget(_G, "print")
local function DebugPrint(...)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog and DebugLog.On("Bounds") and type(emit) == "function" then
		emit(...)
	end
end

-- World units per map tile (const.HeightTileSize, default 100).
local function TileWorldSize(mapdata)
	local const_tbl = Global("const")
	if type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number" and const_tbl.HeightTileSize > 0 then
		return const_tbl.HeightTileSize
	end
	return 100
end

-- Round value UP to a multiple of granularity (integer-safe).
local function AlignUp(value, granularity)
	if type(granularity) ~= "number" or granularity <= 0 then
		return value
	end
	local n = math.floor((value + granularity - 1) / granularity)
	return n * granularity
end

-- Impassable edge border (world units) for the expanded map. DEFAULT 0 = full
-- passability (so rovers from an edge/frame landing are never trapped -- the long-
-- standing PassBorder=0 fix); the heat-query clamp (sbm_heat_safety) keeps that safe.
-- A positive Config.EXPANDED_MAP_EDGE_BORDER sets an impassable ring instead, rounded
-- UP to a const.MapPatchSize multiple (the engine asserts nPassBorder % MAP_PATCH == 0;
-- 0 is always a valid multiple).
local function SafeEdgeBorder()
	local cfg = SuperBigMap.Config or {}
	local override = cfg.EXPANDED_MAP_EDGE_BORDER
	local want = (type(override) == "number" and override > 0) and math.floor(override) or 0
	if want <= 0 then
		return 0
	end
	local const_tbl = Global("const")
	local patch = (type(const_tbl) == "table" and type(const_tbl.MapPatchSize) == "number" and const_tbl.MapPatchSize > 0)
		and const_tbl.MapPatchSize or nil
	if not patch then
		return 0 -- cannot align a positive value safely; full passability is always valid
	end
	return AlignUp(want, patch)
end

-- Map liveness / terrain size are intentionally NOT in sbm_engine (their resolution
-- order is context-specific); each consumer keeps its own copy.
local IsLiveMap = Engine.IsLiveMap

local TerrainSize = Engine.TerrainSize

local function FullMapPlayableEnabled()
	local cfg = SuperBigMap.Config
	return (cfg and cfg.FULL_MAP_PLAYABLE) == true
end

-- "Did this mod generate/expand this map?" -- the single gate that keeps ALL
-- bounds work inert on vanilla maps and on old saves that were started without
-- the mod (no expansion markers). Delegates to the authoritative predicate in
-- SuperBigMap.SectorGrid (loaded before this module). Without it, FULL_MAP_PLAYABLE
-- would rewrite PassBorder / play areas on any loaded map, which is exactly what
-- "do nothing on non-mod saves" forbids.
local function IsModMap(map)
	local grid = SuperBigMap.SectorGrid
	if grid and type(grid.IsModMap) == "function" then
		return grid.IsModMap(map) == true
	end
	return false
end

-- PassBorder gates the engine's placement bounds (flatten tool, building
-- placement, etc.): anything outside [PassBorder, width-PassBorder] is "out
-- of bounds". When FullMapPlayable is on we want the WHOLE terrain to be
-- flatten-able and buildable, including the new edge sectors (e.g. columns
-- A/B in the "expanded_with_vanilla_grid" layout), so PassBorder is forced
-- to 0. We deliberately do NOT clobber mapdata.playable_height_range /
-- visible_height_range -- vanilla landscape code reads .from / .to off those
-- tables to build the bbox z-component, and clearing them causes the native
-- HGE::Landscape_MarkLine to assert on bbox.IsValid().
local function ResetMapDataBounds(map, mapdata)
	if not FullMapPlayableEnabled() then
		return
	end

	if not IsModMap(map) then
		return
	end

	mapdata = mapdata or map and map.mapdata
	if not mapdata then
		return
	end

	if mapdata.SuperBigMapOriginalPassBorder == nil then
		mapdata.SuperBigMapOriginalPassBorder = mapdata.PassBorder
	end

	-- Default PassBorder = 0 so the WHOLE expanded map is passable (a rover from an
	-- edge/frame landing is never trapped). The engine's gameplay grids (heat, etc.) only
	-- cover [HeatGridBorder, size-HeatGridBorder], but we keep the map passable and CLAMP
	-- the heat query (sbm_heat_safety) rather than wall it off. A positive
	-- Config.EXPANDED_MAP_EDGE_BORDER instead sets an impassable ring (MapPatch-aligned).
	local border = SafeEdgeBorder()
	mapdata.PassBorder = border
	local tile = TileWorldSize(mapdata)
	mapdata.PassBorderTiles = (tile > 0) and math.floor(border / tile) or 0
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Bounds", "ResetMapDataBounds set PassBorder", {
			PassBorder = border, PassBorderTiles = mapdata.PassBorderTiles, mapdata_width = mapdata.Width,
		})
	end
end

local function ResetMapAreas(map)
	if not FullMapPlayableEnabled() or not map then
		return
	end

	if not IsModMap(map) then
		return
	end

	local width, height = TerrainSize(map)
	if not width or not height or width <= 0 or height <= 0 then
		return
	end

	if type(map.SetPlayArea) == "function" then
		SafeCall(map.SetPlayArea, map, false, true)
	elseif Global("box") then
		map.PlayArea = box(0, 0, 0, width, height, FullHeightMax())
	end

	if Global("box") then
		map.ConstructableArea = box(0, 0, width, height)
	end

	local camera = Global("cameraRTS")
	if camera and type(camera.SetBoundingBox) == "function" then
		local area = type(map.GetPlayArea) == "function" and SafeCall(map.GetPlayArea, map) or map.PlayArea
		if area then
			SafeCall(camera.SetBoundingBox, area)
		end
	end
end

local function RebuildMapBounds(map)
	if not IsModMap(map) then
		return
	end

	local terrain_api = Global("terrain")

	if terrain_api and type(terrain_api.SetPassableHeight) == "function" then
		SafeCall(terrain_api.SetPassableHeight, map, FullHeightMin(), FullHeightMax())
	end

	if terrain_api and type(terrain_api.RebuildPassability) == "function" then
		SafeCall(terrain_api.RebuildPassability, map)
	end

	-- NewMap must rebuild this grid before the random-map generator runs. ResolveBuildable uses
	-- that initialized state when constructing its native placement mask; deferring this pass
	-- changes enrichment coordinates even when every later stretch transform is exact.
	local rebuild_buildable = Global("RebuildBuildableGrid")
	if type(rebuild_buildable) == "function" and map and map.buildable then
		SafeCall(rebuild_buildable, map)
	end
end

local function RefreshSectors(map)
	if not IsModMap(map) then
		return
	end

	local city = map and map.City
	local sectors = city and city.MapSectors
	local tile_size_fn = Global("GetMapSectorTileSize")
	local box_fn = Global("box")

	if type(sectors) ~= "table" or #sectors == 0 or type(tile_size_fn) ~= "function" or not box_fn then
		return
	end

	local tile = SafeCall(tile_size_fn, map)
	if not tile or tile <= 0 then
		return
	end

	local sector_count = Global("const") and const.SectorCount or 10
	local unbuildable_z = Global("buildUnbuildableZ") and buildUnbuildableZ() or false
	local build_ratio = Global("BuildableGridRatio")

	local DebugLog = SuperBigMap.DebugLog
	if DebugLog and type(DebugLog.InitSeq) == "function" then
		DebugLog.InitSeq("RefreshSectors: re-fitting sector boxes", {
			sector_count = sector_count,
			tile = tile,
		})
	end

	for j = 1, sector_count do
		local row = sectors[j]
		if type(row) == "table" then
			local x = (j - 1) * tile
			for i = 1, sector_count do
				local sector = row[i]
				if sector then
					local y = (i - 1) * tile
					sector.area = box_fn(x, y, x + tile, y + tile)

					if type(build_ratio) == "function" and map.buildable and map.buildable.z_grid and unbuildable_z then
						sector.play_ratio = SafeCall(build_ratio, map.buildable.z_grid, unbuildable_z, 100, sector.area) or sector.play_ratio
					end

					if type(sector.UpdateDecal) == "function" then
						SafeCall(sector.UpdateDecal, sector)
					end
				end
			end
		end
	end

	if type(city.InitMapArea) == "function" then
		SafeCall(city.InitMapArea, city)
	end
end

local MapBounds = {}

MapBounds.FullMapPlayableEnabled = FullMapPlayableEnabled
MapBounds.ResetMapDataBounds = ResetMapDataBounds
MapBounds.ResetMapAreas = ResetMapAreas
MapBounds.RebuildMapBounds = RebuildMapBounds
MapBounds.RefreshSectors = RefreshSectors

-- ---------------------------------------------------------------------------
-- BuildableGrid:GetZ permissive override
-- ---------------------------------------------------------------------------
-- Vanilla SMR's LandscapeMarkBuildable(map, pt) returns
-- BuildableGrid.GetZ(buildable, ...) ~= UnbuildableZ. On the expanded map only
-- a small fraction of cells come out buildable, so most positions report
-- unbuildable; that fails IsMarkSuitable -> sets place_block on the LCC
-- controller. Wrap GetZ so any cell the engine marked UnbuildableZ instead
-- returns DEFAULT_BUILDABLE_Z; LandscapeMarkBuildable then sees a valid Z
-- everywhere; place_block stays false across the whole expanded map.
--
-- Trade-off: downstream Lua callers that read the actual buildable height
-- (e.g. snap-to-buildable-height) get a flat default Z on hexes the engine
-- considered unbuildable. Acceptable for sandbox/landscape use.

local DEFAULT_BUILDABLE_Z = 10000

local function GetUnbuildableZ()
	local fn = rawget(_G, "buildUnbuildableZ")
	if type(fn) == "function" then
		local ok, value = pcall(fn)
		if ok and type(value) == "number" then
			return value
		end
	end
	local const_value = rawget(_G, "UnbuildableZ")
	if type(const_value) == "number" then
		return const_value
	end
	return 65535
end

local function InstallBuildableGridPermissive()
	local class_table_fn = Engine.ClassTable
	if type(class_table_fn) ~= "function" then
		DebugPrint("[Super Big Map] InstallBuildableGridPermissive: no Engine.ClassTable")
		return
	end
	local cls = class_table_fn("BuildableGrid")
	if not cls or type(cls.GetZ) ~= "function" then
		DebugPrint("[Super Big Map] InstallBuildableGridPermissive: no BuildableGrid:GetZ")
		return
	end
	if rawget(_G, "BMOriginal_BuildableGrid_GetZ") then
		DebugPrint("[Super Big Map] InstallBuildableGridPermissive: already wrapped")
		return
	end
	local original_getz = cls.GetZ
	rawset(_G, "BMOriginal_BuildableGrid_GetZ", original_getz)

	local unbuildable_z = GetUnbuildableZ()
	SuperBigMap.State = SuperBigMap.State or {}
	SuperBigMap.State.permissive_buildable_unbuildable_z = unbuildable_z

	cls.GetZ = function(self, q, r)
		local z = original_getz(self, q, r)
		-- Permissive only on mod-expanded maps; on vanilla maps / non-mod saves the
		-- wrapper is transparent so buildability is exactly vanilla.
		if z == unbuildable_z and IsModMap(Global("CurrentMap")) then
			return DEFAULT_BUILDABLE_Z
		end
		return z
	end
	DebugPrint("[Super Big Map] InstallBuildableGridPermissive: wrapped BuildableGrid:GetZ (UnbuildableZ="
		.. tostring(unbuildable_z) .. ", default=" .. tostring(DEFAULT_BUILDABLE_Z) .. ")")
end

local function UninstallBuildableGridPermissive()
	local class_table_fn = Engine.ClassTable
	if type(class_table_fn) ~= "function" then return end
	local cls = class_table_fn("BuildableGrid")
	local original = rawget(_G, "BMOriginal_BuildableGrid_GetZ")
	if cls and type(original) == "function" then
		cls.GetZ = original
	end
	rawset(_G, "BMOriginal_BuildableGrid_GetZ", nil)
	if SuperBigMap.State then
		SuperBigMap.State.permissive_buildable_unbuildable_z = nil
	end
end

MapBounds.InstallBuildableGridPermissive = InstallBuildableGridPermissive
MapBounds.UninstallBuildableGridPermissive = UninstallBuildableGridPermissive

-- ---------------------------------------------------------------------------
-- BuildableGrid storage rewrite
-- ---------------------------------------------------------------------------
-- The Lua-level GetZ override above clears place_block (Lua path), but native
-- code that reads buildable.z_grid directly through the C++ binding still sees
-- UnbuildableZ at most cells -- which can break building placement / snap on
-- the expanded edge sectors. Rewrite the storage too: at every engine-driven
-- RebuildBuildableGrid, walk the grid and replace UnbuildableZ cells with
-- DEFAULT_BUILDABLE_Z. The hook is idempotent.

local function ForceBuildableGridStorage(map)
	if not map then return 0, 0 end
	-- DISABLED BY DEFAULT. This rewrote every UNBUILDABLE cell of the buildable z-grid to
	-- the constant DEFAULT_BUILDABLE_Z (10000). The terrain-flatten that runs when a rocket
	-- LANDING SITE (or any building) is placed levels the footprint TO the z-grid value, so
	-- those forced-10000 cells made the landing carve a flat pad at the wrong height -- a
	-- raised PILLAR at high spots, a HOLE (10000) at unbuildable spots. Leaving the cells at
	-- the vanilla unbuildable marker makes the flatten SKIP them (FlattenTerrainInShape only
	-- sets height where z ~= UnbuildableZ), so no deformation. Buildability stays permissive
	-- via the GetZ wrapper. Re-enable only with a correct per-cell terrain Z (not a constant).
	local cfg = SuperBigMap.Config or {}
	if cfg.FORCE_BUILDABLE_GRID_STORAGE ~= true then
		return 0, 0
	end
	-- Only rewrite buildable storage on mod-expanded maps; leave vanilla/non-mod
	-- maps' grids untouched so loading an old save changes nothing.
	if not IsModMap(map) then return 0, 0 end
	local buildable = map.buildable
	if not buildable or not buildable.z_grid then return 0, 0 end

	local z_grid = buildable.z_grid
	if type(z_grid.set) ~= "function" or type(z_grid.get) ~= "function" then
		return 0, 0
	end

	local w, h
	if type(z_grid.size) == "function" then
		local ok, ww, hh = pcall(z_grid.size, z_grid)
		if ok and type(ww) == "number" and type(hh) == "number" and ww > 0 and hh > 0 then
			w, h = ww, hh
		end
	end
	if not w or not h then
		w = type(map.hex_width) == "number" and map.hex_width or 0
		h = type(map.hex_height) == "number" and map.hex_height or 0
	end
	if w <= 0 or h <= 0 then
		DebugPrint("[Super Big Map] ForceBuildableGridStorage: skipped, no grid dimensions")
		return 0, 0
	end

	local unbuildable_z = GetUnbuildableZ()
	local total = w * h

	-- Per-cell rewrite. NOTE: the buildable z_grid is a special grid type that the
	-- native GridReplace/GridFill ops reject ("HGE::lua_GridReplace: Grid Type Not
	-- Supported"), so the per-cell get/set loop is the only supported path here.
	--
	-- Write each unbuildable cell's REAL terrain height (NOT a constant). The construction
	-- terrain-flatten (FlattenTerrainInShape, in a custom _ENV we can't wrap) reads this
	-- z-grid: a cell left at UnbuildableZ makes it ASSERT (z != nUnbuildableZ) when a rocket
	-- landing pad overlaps it; a constant (10000) makes it carve a pillar/hole. The real
	-- terrain height means the cell is buildable AND the flatten levels it to the height it
	-- already has -> no assert, no deformation. Cell -> world via HexToWorld (the same
	-- mapping BuildableGrid:GetZ/the flatten use), then terrain.GetHeight.
	local hex_to_world = Global("HexToWorld")
	local point_fn = Global("point")
	local terrain_api = Global("terrain")
	local get_height = type(terrain_api) == "table" and terrain_api.GetHeight or nil
	local can_real = type(hex_to_world) == "function" and type(point_fn) == "function" and type(get_height) == "function"
	local replaced, real_used, fallback_used = 0, 0, 0
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			if z_grid:get(x, y) == unbuildable_z then
				local z = DEFAULT_BUILDABLE_Z
				if can_real then
					local wx, wy = hex_to_world(x, y)
					local ok, th = pcall(get_height, map, point_fn(wx, wy))
					if ok and type(th) == "number" and th ~= unbuildable_z then
						z = th
						real_used = real_used + 1
					else
						fallback_used = fallback_used + 1
					end
				else
					fallback_used = fallback_used + 1
				end
				z_grid:set(x, y, z)
				replaced = replaced + 1
			end
		end
	end
	DebugPrint(string.format(
		"[Super Big Map] ForceBuildableGridStorage: real_terrain_z=%d fallback=%d", real_used, fallback_used))

	DebugPrint(string.format(
		"[Super Big Map] ForceBuildableGridStorage: %dx%d (%d cells), replaced %d unbuildable",
		w, h, total, replaced))
	return replaced, total
end

local REBUILD_BUILDABLE_GRID_PATCH_VERSION = 1
local function InstallRebuildBuildableGridHook()
	local State = SuperBigMap.State or {}
	local current = rawget(_G, "RebuildBuildableGrid")
	if type(current) ~= "function" then
		DebugPrint("[Super Big Map] InstallRebuildBuildableGridHook: RebuildBuildableGrid not found")
		return false
	end
	local legacy_original = rawget(_G, "BMOriginal_RebuildBuildableGrid")
	if State.rebuild_buildable_grid_wrapper == nil
		and type(legacy_original) == "function" and current ~= legacy_original
		and IsLegacyMapBoundsFunction(current) then
		DebugPrint("[Super Big Map] InstallRebuildBuildableGridHook: migrating legacy anonymous wrapper")
		current = legacy_original
	end
	if current == State.rebuild_buildable_grid_wrapper
		and State.rebuild_buildable_grid_version == REBUILD_BUILDABLE_GRID_PATCH_VERSION
		and State.rebuild_buildable_grid_token == MODULE_TOKEN then
		DebugPrint("[Super Big Map] InstallRebuildBuildableGridHook: live identity verified wrapper="
			.. tostring(current) .. " original=" .. tostring(State.original_rebuild_buildable_grid))
		return true
	end
	-- If a future patch version replaces our live wrapper, peel it before capturing the
	-- immutable engine function. A ClassesBuilt reset instead gives us a fresh current.
	if current == State.rebuild_buildable_grid_wrapper
		and type(State.original_rebuild_buildable_grid) == "function" then
		current = State.original_rebuild_buildable_grid
	end
	local original = current
	local wrapper = function(map, ...)
		local results = Pack(pcall(original, map, ...))
		if not results[1] then error(results[2]) end
		ForceBuildableGridStorage(map)
		return Unpack(results, 2, results.n)
	end
	rawset(_G, "RebuildBuildableGrid", wrapper)
	State.original_rebuild_buildable_grid = original
	State.rebuild_buildable_grid_wrapper = wrapper
	State.rebuild_buildable_grid_version = REBUILD_BUILDABLE_GRID_PATCH_VERSION
	State.rebuild_buildable_grid_token = MODULE_TOKEN
	-- Retain the legacy slot for compatibility with saves/hot reloads that inspected it,
	-- but never use its mere existence as proof that the wrapper is still installed.
	rawset(_G, "BMOriginal_RebuildBuildableGrid", original)
	DebugPrint("[Super Big Map] InstallRebuildBuildableGridHook: wrapped live="
		.. tostring(rawget(_G, "RebuildBuildableGrid")) .. " wrapper=" .. tostring(wrapper)
		.. " original=" .. tostring(original))
	return true
end

local function UninstallRebuildBuildableGridHook()
	local State = SuperBigMap.State or {}
	if rawget(_G, "RebuildBuildableGrid") == State.rebuild_buildable_grid_wrapper
		and type(State.original_rebuild_buildable_grid) == "function" then
		rawset(_G, "RebuildBuildableGrid", State.original_rebuild_buildable_grid)
	end
	State.original_rebuild_buildable_grid = nil
	State.rebuild_buildable_grid_wrapper = nil
	State.rebuild_buildable_grid_version = nil
	State.rebuild_buildable_grid_token = nil
	rawset(_G, "BMOriginal_RebuildBuildableGrid", nil)
end

MapBounds.ForceBuildableGridStorage = ForceBuildableGridStorage
MapBounds.InstallRebuildBuildableGridHook = InstallRebuildBuildableGridHook
MapBounds.UninstallRebuildBuildableGridHook = UninstallRebuildBuildableGridHook

-- ---------------------------------------------------------------------------
-- LandscapeConstructionController:ValidateMark permissive override
-- ---------------------------------------------------------------------------
-- Final piece of the "Out of bounds" fix. SMR's Landscape Lua files load under
-- a custom _ENV: rawset(_G, "LandscapeMarkSmooth", ...) does not propagate to
-- LandscapeConstructionController:ValidateMark's lookup path (verified -- a
-- prior attempt wrapped the global but never fired, while LCC's mark_fail
-- stayed true). The LCC class table itself IS reachable via Engine.ClassTable,
-- so override ValidateMark there. We still call the original so it gets a
-- chance to populate self.obstruct_handles / self.obstruct_marks (overlap
-- detection), then convert any falsy result to true; the caller in
-- LandscapeTerraceController:Mark (and its peers) then sees success=true,
-- self.mark_fail = not true = false, and LandscapeOutOfBounds no longer fires.

local function InstallLCCValidateMarkPermissive()
	local class_table_fn = Engine.ClassTable
	if type(class_table_fn) ~= "function" then
		DebugPrint("[Super Big Map] InstallLCCValidateMarkPermissive: no Engine.ClassTable")
		return
	end
	local cls = class_table_fn("LandscapeConstructionController")
	if not cls or type(cls.ValidateMark) ~= "function" then
		DebugPrint("[Super Big Map] InstallLCCValidateMarkPermissive: no LandscapeConstructionController:ValidateMark")
		return
	end
	if rawget(_G, "BMOriginal_LCC_ValidateMark") then
		DebugPrint("[Super Big Map] InstallLCCValidateMarkPermissive: already wrapped")
		return
	end
	local original = cls.ValidateMark
	rawset(_G, "BMOriginal_LCC_ValidateMark", original)

	cls.ValidateMark = function(self, test)
		local result = original(self, test)
		-- Permissive (treat falsy as success) only on mod-expanded maps; on vanilla
		-- maps / non-mod saves landscape validation stays exactly vanilla.
		if (result == false or result == nil) and IsModMap(Global("CurrentMap")) then
			return true
		end
		return result
	end
	DebugPrint("[Super Big Map] InstallLCCValidateMarkPermissive: wrapped LandscapeConstructionController:ValidateMark")
end

local function UninstallLCCValidateMarkPermissive()
	local class_table_fn = Engine.ClassTable
	if type(class_table_fn) ~= "function" then return end
	local cls = class_table_fn("LandscapeConstructionController")
	local original = rawget(_G, "BMOriginal_LCC_ValidateMark")
	if cls and type(original) == "function" then
		cls.ValidateMark = original
	end
	rawset(_G, "BMOriginal_LCC_ValidateMark", nil)
end

MapBounds.InstallLCCValidateMarkPermissive = InstallLCCValidateMarkPermissive
MapBounds.UninstallLCCValidateMarkPermissive = UninstallLCCValidateMarkPermissive

-- ---------------------------------------------------------------------------
-- Pre-generation buildable-grid extent optimizer (expanded maps only)
-- ---------------------------------------------------------------------------
-- MapVar constructs BuildableGrid before random generation. The terrain allocation is
-- already 8192 tiles at that point, but only the native 6144-tile source will be generated;
-- computing buildability for the blank L-frame costs ~1.7s and triggers a real timing warning.
-- Give that provisional loading-only object a full-sized all-unbuildable z-grid in one cheap
-- allocation. RandomMapGenerator's ResolveBuildable pass replaces it from generated terrain,
-- and the post-stretch pass replaces it again at the final full extent. No print function is
-- intercepted or filtered, and the placeholder cannot authorize construction prematurely.
local BUILDABLE_GRID_BUILD_PATCH_VERSION = 2
local function InitialBuildableDeferralInfo(map, self)
	local cfg = SuperBigMap.Config or {}
	if cfg.OPTIMIZE_STRETCH_DEFERRED_REBUILDS ~= true
		or tostring(cfg.EXPANSION_FRAME_FILL_MODE or "mirror") ~= "stretch"
		or not map or self.z_grid then
		return nil
	end
	local mapdata = map.mapdata
	-- This optimization is valid only for the new expanded surface map whose native
	-- generator is guaranteed to run ResolveBuildable next. Never infer eligibility from
	-- persistent mapdata size markers: save loads and underground maps must fail open to
	-- the native Build path.
	if type(mapdata) ~= "table" or mapdata.Environment ~= "Surface"
		or map.SuperBigMapQuadrantCopyPending ~= true then
		return nil
	end
	local desired_w = map.SuperBigMapDesiredWidthTiles
		or mapdata.Width
	local desired_h = map.SuperBigMapDesiredHeightTiles
		or mapdata.Height
	local generator_w = map.SuperBigMapGeneratorWidthTiles
		or mapdata.SuperBigMapOriginalWidthTiles
	local generator_h = map.SuperBigMapGeneratorHeightTiles
		or mapdata.SuperBigMapOriginalHeightTiles
	if type(desired_w) ~= "number" or desired_w <= 0
		or type(desired_h) ~= "number" or desired_h <= 0
		or type(generator_w) ~= "number" or generator_w <= 0 or generator_w >= desired_w
		or type(generator_h) ~= "number" or generator_h <= 0 or generator_h >= desired_h then
		return nil
	end
	return generator_w, generator_h, desired_w, desired_h
end

local function InstallBuildableGridPreGenerationOptimizer()
	local class_table_fn = Engine.ClassTable
	if type(class_table_fn) ~= "function" then
		DebugPrint("[Super Big Map] InstallBuildableGridPreGenerationOptimizer: no Engine.ClassTable")
		return
	end
	local cls = class_table_fn("BuildableGrid")
	if not cls or type(cls.Build) ~= "function" then
		DebugPrint("[Super Big Map] InstallBuildableGridPreGenerationOptimizer: no BuildableGrid:Build")
		return
	end
	local State = SuperBigMap.State or {}
	local current = cls.Build
	local legacy_original = rawget(_G, "BMOriginal_BuildableGrid_Build")
	if State.buildable_grid_build_wrapper == nil
		and type(legacy_original) == "function" and current ~= legacy_original
		and IsLegacyMapBoundsFunction(current) then
		DebugPrint("[Super Big Map] InstallBuildableGridPreGenerationOptimizer: migrating legacy wrapper")
		current = legacy_original
	end
	if current == State.buildable_grid_build_wrapper
		and State.buildable_grid_build_version == BUILDABLE_GRID_BUILD_PATCH_VERSION
		and State.buildable_grid_build_token == MODULE_TOKEN then
		DebugPrint("[Super Big Map] InstallBuildableGridPreGenerationOptimizer: live identity verified wrapper="
			.. tostring(current) .. " original=" .. tostring(State.original_buildable_grid_build))
		return true
	end
	if current == State.buildable_grid_build_wrapper
		and type(State.original_buildable_grid_build) == "function" then
		current = State.original_buildable_grid_build
	end
	local original = current
	rawset(_G, "BMOriginal_BuildableGrid_Build", original)
	local wrapper
	wrapper = function(self, map, width, height, map_data, ...)
		local gen_w, gen_h, desired_w, desired_h = InitialBuildableDeferralInfo(map, self)
		local new_grid = Global("NewGrid")
		if gen_w and type(new_grid) == "function"
			and type(width) == "number" and width > 0 and type(height) == "number" and height > 0 then
			local ok_grid, placeholder = pcall(new_grid, width, height, 16, GetUnbuildableZ())
			if not ok_grid or not placeholder then
				return original(self, map, width, height, map_data, ...)
			end
			self.z_grid = placeholder
			map.SuperBigMapProvisionalBuildableDeferred = true
			local debug_log = SuperBigMap.DebugLog
			if debug_log then
				pcall(debug_log.Info, "Bounds", "deferred provisional blank buildable-grid computation", {
					hex_width = width, hex_height = height,
					generator_tiles = tostring(gen_w) .. "x" .. tostring(gen_h),
					desired_tiles = tostring(desired_w) .. "x" .. tostring(desired_h),
					placeholder = "full-size all-unbuildable",
				})
			end
			return
		end
		local results = Pack(original(self, map, width, height, map_data, ...))
		-- Reaching this point proves the native Build returned successfully and replaced
		-- the provisional grid. If it raises, this marker deliberately remains set.
		if map and map.SuperBigMapProvisionalBuildableDeferred == true then
			map.SuperBigMapProvisionalBuildableDeferred = nil
		end
		return Unpack(results, 1, results.n)
	end
	cls.Build = wrapper
	State.original_buildable_grid_build = original
	State.buildable_grid_build_wrapper = wrapper
	State.buildable_grid_build_version = BUILDABLE_GRID_BUILD_PATCH_VERSION
	State.buildable_grid_build_token = MODULE_TOKEN
	DebugPrint("[Super Big Map] InstallBuildableGridPreGenerationOptimizer: wrapped live="
		.. tostring(cls.Build) .. " wrapper=" .. tostring(wrapper) .. " original=" .. tostring(original))
	return true
end

local function UninstallBuildableGridPreGenerationOptimizer()
	local class_table_fn = Engine.ClassTable
	if type(class_table_fn) ~= "function" then return end
	local cls = class_table_fn("BuildableGrid")
	local State = SuperBigMap.State or {}
	if cls and cls.Build == State.buildable_grid_build_wrapper
		and type(State.original_buildable_grid_build) == "function" then
		cls.Build = State.original_buildable_grid_build
	end
	State.original_buildable_grid_build = nil
	State.buildable_grid_build_wrapper = nil
	State.buildable_grid_build_version = nil
	State.buildable_grid_build_token = nil
	rawset(_G, "BMOriginal_BuildableGrid_Build", nil)
end

MapBounds.InstallBuildableGridPreGenerationOptimizer = InstallBuildableGridPreGenerationOptimizer
MapBounds.UninstallBuildableGridPreGenerationOptimizer = UninstallBuildableGridPreGenerationOptimizer

-- Narrow reload-safe installer used before a map is active. It touches only transparent,
-- map-gated engine hooks; no current-map grids, pass borders, or permissive policies.
function MapBounds.ReinstallGlobalHooks()
	local cfg = SuperBigMap.Config or {}
	if cfg.ENABLE_MOD == false then return false end
	InstallRebuildBuildableGridHook()
	InstallBuildableGridPreGenerationOptimizer()
	return true
end

-- Bounds are applied per-map by SuperBigMap.Lifecycle.Apply (driven by the map
-- OnMsg flow); the global install step here wires up the three permissive
-- class-table overrides that make construction usable across the expanded map.
-- All three install steps are idempotent.
function MapBounds.ApplyModBehavior()
	local cfg = SuperBigMap.Config or {}
	MapBounds.ReinstallGlobalHooks()
	-- BUILD permissive (cliffs -> buildable): OFF by default. Vanilla buildability (from the
	-- rebuilt-after-copy grid) decides, so cliffs are unbuildable and rockets can't land on
	-- them. Re-enable via Config.PERMISSIVE_BUILD_ON_EXPANDED.
	if cfg.PERMISSIVE_BUILD_ON_EXPANDED == true then
		InstallBuildableGridPermissive()
	end
	-- LANDSCAPING permissive (terraform across the expanded terrain): ON by default. Separate
	-- from buildability -- vanilla lets you landscape unbuildable ground to make it buildable,
	-- so the landscape tool must keep working past the original quadrant. Disable via
	-- Config.ALLOW_LANDSCAPING_ON_EXPANDED = false.
	if cfg.ALLOW_LANDSCAPING_ON_EXPANDED ~= false then
		InstallLCCValidateMarkPermissive()
	end
	-- Keep the rebuild hook: it just runs the vanilla RebuildBuildableGrid (ForceBuildable-
	-- GridStorage inside is gated off), so the buildable grid stays accurate for the new
	-- terrain.
	-- The provisional pre-generation computation is deferred above, but every authoritative
	-- native/final build still runs normally and every engine timing warning remains visible.
	-- If a map is already loaded when the mod enables, force a one-shot grid pass now
	-- (no-op unless ForceBuildableGridStorage is enabled).
	local map = Global("CurrentMap")
	if IsLiveMap(map) and map.buildable then
		ForceBuildableGridStorage(map)
	end
end

-- Restore order is the exact reverse of install. PassBorder is also put back
-- here so the engine's strict bounds resume when the mod is off.
function MapBounds.RestoreVanillaBehavior()
	UninstallBuildableGridPreGenerationOptimizer()
	UninstallLCCValidateMarkPermissive()
	UninstallRebuildBuildableGridHook()
	UninstallBuildableGridPermissive()

	local map = Global("CurrentMap")
	if not IsLiveMap(map) then
		map = Global("MainMap")
	end
	if not IsLiveMap(map) then
		return
	end

	local mapdata = map.mapdata
	if not mapdata then
		return
	end

	if mapdata.SuperBigMapOriginalPassBorder ~= nil then
		mapdata.PassBorder = mapdata.SuperBigMapOriginalPassBorder
		mapdata.SuperBigMapOriginalPassBorder = nil
	end
end

SuperBigMap.MapBounds = MapBounds

-- Game Lua reloads can recreate BuildableGrid and the global rebuild function before a
-- mod map is active. Install the transparent, map-gated wrappers at module load; lifecycle
-- boundaries below re-verify their live identities after ClassesBuilt/ModsReloaded.
if (SuperBigMap.Config or {}).ENABLE_MOD ~= false then
	MapBounds.ReinstallGlobalHooks()
end

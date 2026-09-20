-- Super Big Map -- let the engine's own decor stage restore density on the stretched map.
--
-- Vanilla decorates in two places. Most rocks and cliffs are baked into the terrain prefabs
-- that Proc_PlacePrefabs stamps; on top of that, Proc_PlaceDecors stamps extra DECOR PREFABS at
-- the PrefabDecorMarker sites those terrain prefabs carry -- DecorationRatio percent of them
-- (FillRandomMapGen sets 25 below landing altitude 150, 10 above), each site's prefab chosen by
-- a weighted draw over the prefabs that match the site's style/POI/op/tag/radius filters.
--
-- The stretch moves every one of those groups to its scaled position, so D groups that covered
-- area A now cover area_factor * A (1.778x for 6144 -> 8192) and density falls to 56%.  This pass
-- runs vanilla's decor stage a second time, sized to the deficit instead of to the ratio:
--
--   additions = D * (area_factor - 1)         -- 0.778 D, so total = 1.778 D = vanilla density
--
-- drawn from the decor markers vanilla left UNUSED (they still carry DecorTestPrefab == ""), with
-- vanilla's own matcher (PrefabDecorMarker:GetMatchingMarkers), vanilla's own weighted pick
-- (table.weighted_rand with the repeat-reduction weight), vanilla's own stamp (PlacePrefab with
-- dont_change_terrain), and vanilla's own spacing rule (a site is skipped when an obstructing or
-- already-decorated circle intersects its radius).  Existing decor is never touched: the stage is
-- purely additive, and the one culling step in vanilla (RemoveOverlappedObjects at ApplyTerrain)
-- never runs here because no terrain is rasterised.
--
-- Two deliberate departures from vanilla's loop, both documented at the point of use:
--   * randomness comes from a private stream seeded from the map seed, never AsyncRand -- same
--     seed, same decor, and no engine RNG draw vanilla would not have made;
--   * the whole-map prefab orientation is not reproduced.  For the full-circle rotation every
--     decor prefab uses, adding a constant offset to a uniform draw changes nothing.
-- After stamping, each new group receives the same similarity the stretch gave its neighbours:
-- object offsets and cosmetic scale x area_factor^0.5 about the group centre, Z reseated on the
-- stretched terrain.
--
-- When the authored sites run out (they do: most unused sites sit inside Border/Slope prefab radii
-- that vanilla's own obstruct grid rejects), the pass continues on SYNTHETIC sites: it borrows the
-- filters of a used site and tries seeded positions around it on the same terrain type, so the
-- content is still a group vanilla would place in that context; only the site is the mod's.
--
-- This replenishes the decor-pass share only.  Decor baked into the terrain prefabs stays at
-- 1/area_factor density; nothing short of re-laying the map can change that.
--
-- BOTH MAPS.  The pass runs on the surface during its stretch and on the underground during
-- first-access preparation, at the same point of each pipeline (after the decoration and marker
-- passes moved every site, before the authoritative resume).  The underground runs long after
-- generation, so the generator holder may be gone: the seed then comes from the seed the mod keeps
-- on the map and the matching/weight properties from the authored RandomMapPreset, and the record
-- names which source each came from.  The stats record is published on the map itself
-- (SuperBigMapDecorEnginePassReport) because one LastStats slot cannot represent two maps in one
-- session; the list of placed OBJECTS is per map too, but it lives in this module's weak-keyed
-- registry (DecorTopUp.PassObjects) rather than on a map field, so live object references are
-- never attached to engine state that a save or a map teardown might carry.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local IsKindOfSafe = Engine.IsKindOf
local ObjectPosition = Engine.ObjectPos
local ObjectClone = SuperBigMap.ObjectClone
local ObjectScalesWithTerrain = ObjectClone and ObjectClone.ObjectScalesWithTerrain

local DecorTopUp = {}
SuperBigMap.DecorTopUp = DecorTopUp

DecorTopUp.VERSION = 10
DecorTopUp.SEED_TAG = "SuperBigMapDecorEnginePass"
DecorTopUp.LastStats = nil

-- Per-map list of the objects this pass placed, keyed weakly on the map table: the pass runs on
-- two maps in one session, and the reader needs the list of the map it asks about.  Weak keys so a
-- discarded map takes its list with it, and a module registry rather than a map field so no live
-- object reference is ever stored on engine state.
local pass_objects_by_map = setmetatable({}, { __mode = "k" })

function DecorTopUp.PassObjects(map)
	local list = type(map) == "table" and pass_objects_by_map[map] or nil
	return type(list) == "table" and list or nil
end

local function cfg_bool(key, default)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "boolean" then return value end
	return default
end

local function cfg_number(key, default)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "number" then return value end
	return default
end

local function PointXY(pos)
	if not pos then return nil, nil end
	if type(pos.xy) == "function" then
		local ok, x, y = pcall(pos.xy, pos)
		if ok then return x, y end
	end
	if type(pos.x) == "function" then
		local okx, x = pcall(pos.x, pos)
		local oky, y = pcall(pos.y, pos)
		if okx and oky then return x, y end
	end
	return nil, nil
end

-- vanilla: local max_rotation = 360*60
local MAX_ROTATION = 360 * 60
-- vanilla: local ZONE_DECOR = 7 (RandomMapGenerator.lua:23)
local ZONE_DECOR = 7

-- Private, seed-derived stream.  BraidRandom(seed, n) -> value in [0, n), next seed; identical
-- inputs give identical decor on every run of the same map.
local function MakeStream(seed)
	local braid = Global("BraidRandom")
	if type(braid) ~= "function" then return nil end
	local state = seed
	local stream = {}
	function stream.rand(a, b)
		local value
		if b == nil then
			if a == nil or a <= 0 then return 0 end
			value, state = braid(state, a)
		else
			value, state = braid(state, a, b)
		end
		return value
	end
	function stream.seed()
		local value
		value, state = braid(state)
		return value
	end
	return stream
end

local function map_stretch(map)
	local sw = tonumber(map.SuperBigMapSourceWidthTiles) or tonumber(map.SuperBigMapGeneratorWidthTiles)
	local sh = tonumber(map.SuperBigMapSourceHeightTiles) or tonumber(map.SuperBigMapGeneratorHeightTiles) or sw
	local mapdata = map.mapdata
	local fw = tonumber(map.SuperBigMapDesiredWidthTiles) or (type(mapdata) == "table" and tonumber(mapdata.Width))
	local fh = tonumber(map.SuperBigMapDesiredHeightTiles) or (type(mapdata) == "table" and tonumber(mapdata.Height)) or fw
	if not sw or not sh or not fw or not fh or sw <= 0 or sh <= 0 or fw <= sw then return nil end
	return (fw + 0.0) / sw, (fh + 0.0) / sh
end

local function circle_hits(list, x, y, radius)
	-- These circles are private to one Run and only appended after a stamp.
	-- Index their full bounding boxes; the original strict circle predicate still
	-- decides every possible hit. No candidate, rejection precedence or draw changes.
	local index = list.spatial_index
	if not index then
		index = { rows = {}, count = 0, serial = 0, seen = {} }
		list.spatial_index = index
	end
	local floor, cell = math.floor, 16384
	for i = index.count + 1, #list do
		local c = list[i]
		for bx = floor((c.x - c.r + 0.0) / cell), floor((c.x + c.r + 0.0) / cell) do
			local row = index.rows[bx]
			if not row then row = {}; index.rows[bx] = row end
			for by = floor((c.y - c.r + 0.0) / cell), floor((c.y + c.r + 0.0) / cell) do
				local bucket = row[by]
				if not bucket then bucket = {}; row[by] = bucket end
				bucket[#bucket + 1] = c
			end
		end
	end
	index.count, index.serial = #list, index.serial + 1
	local serial, seen = index.serial, index.seen
	local by0, by1 = floor((y - radius + 0.0) / cell), floor((y + radius + 0.0) / cell)
	for bx = floor((x - radius + 0.0) / cell), floor((x + radius + 0.0) / cell) do
		local row = index.rows[bx]
		if row then
			for by = by0, by1 do
				local bucket = row[by]
				for i = 1, bucket and #bucket or 0 do
					local c = bucket[i]
					if seen[c] ~= serial then
						seen[c] = serial
						local dx, dy = x - c.x, y - c.y
						local reach = radius + c.r
						if dx * dx + dy * dy < reach * reach then return true end
					end
				end
			end
		end
	end
	return false
end

-- DECOR_OUTPUT_HELPERS_BEGIN
local function IsAllowedDecorOutputClass(class_name, environment)
	-- Existing objects may scale with terrain without being safe to CREATE as decor.
	-- Keep this creation policy separate from ObjectScalesWithTerrain's defaults.
	return class_name == "PrefabMarker" or class_name:sub(1, 5) == "Cliff"
		or class_name:sub(1, 3) == "Dec" or class_name:sub(1, 5) == "Rocks"
		or class_name:sub(1, 6) == "Stones"
		or (environment == "Underground" and class_name:sub(1, 16) == "Underground_Arch")
end
-- DECOR_OUTPUT_HELPERS_END

-- DECOR_FINITE_SITES_BEGIN
local function NewDecorInteriorCursor(x0, y0, x1, y1, step, rand)
	x0, y0, x1, y1 = math.ceil(x0), math.ceil(y0), math.ceil(x1), math.ceil(y1)
	step = math.max(1, math.floor(step))
	if x1 <= x0 or y1 <= y0 then return function() return nil end end
	-- Integer-safe ceilings, including partial cells on the far edges.
	local nx = math.floor((x1 - x0 + step - 1) / step)
	local ny = math.floor((y1 - y0 + step - 1) / step)
	local count = nx * ny
	local index, stride = rand(count), rand(count) + 1
	local function gcd(a, b)
		while b ~= 0 do a, b = b, a % b end
		return a
	end
	while gcd(stride, count) ~= 1 do stride = stride % count + 1 end
	local remaining = count
	return function()
		if remaining == 0 then return nil end
		local cx = x0 + (index % nx) * step
		local cy = y0 + math.floor(index / nx) * step
		index, remaining = (index + stride) % count, remaining - 1
		-- One seeded candidate per cell, created only when requested; no candidate pool.
		return cx + rand(math.min(step, x1 - cx)), cy + rand(math.min(step, y1 - cy))
	end
end
-- DECOR_FINITE_SITES_END

-- Runs while the stretch's pass edits are still suspended, after ScaleDecorationsToFull and
-- ScaleMarkersToFull have moved every marker to its stretched position. Failures are recorded
-- explicitly; a partially completed pass is never advertised as complete or rolled back.
function DecorTopUp.Run(map, pass_edits_already_suspended)
	local stats = { version = DecorTopUp.VERSION, enabled = false, placed = 0, objects = 0 }
	DecorTopUp.LastStats = stats
	local ok, err = pcall(function()
		if not map or type(map.MapForEach) ~= "function" then error("no live map") end
		-- Publish the live record before the first early return, so a disabled, geometry-less or
		-- zero-deficit run is still readable per map instead of collapsing into one shared slot.
		map.SuperBigMapDecorEnginePassReport = stats
		local mapdata = map.mapdata
		local environment = type(mapdata) == "table" and tostring(Engine.MapDataEnvironment(mapdata) or "") or ""
		stats.environment = environment
		if environment == "Underground" then
			if not cfg_bool("STRETCH_DECOR_ENGINE_PASS_UNDERGROUND", false) then
				stats.reason = "underground disabled"
				return
			end
		elseif not cfg_bool("STRETCH_DECOR_ENGINE_PASS", true) then
			stats.reason = "disabled"
			return
		end

		local scale_x, scale_y = map_stretch(map)
		if not scale_x then
			stats.reason = "map has no stretch geometry"
			return
		end
		local area_factor = scale_x * scale_y
		local length_scale = math.sqrt(area_factor)
		-- This Lua divides two integers as integers; keep the report in floating point.
		stats.area_factor = math.floor(area_factor * 1000 + 0.5) / 1000.0
		local started_ms = SafeCall(Global("GetPreciseTicks")) or 0

		local generator = map.RandomMapGenObject
		local get_generator = Global("GetRandomMapGenerator")
		if type(generator) ~= "table" and type(get_generator) == "function" then
			generator = SafeCall(get_generator, map)
		end
		-- RandomMapGenObject is deliberately transient (sbm_deposits.lua states the same rule for the
		-- placement stream): the underground pass first runs at first access, long after generation.
		-- Fall back to the seed the mod keeps on the map, and to the authored RandomMapPreset for the
		-- generator's matching and weight properties -- the same source vanilla configured it from.
		local random_presets = Global("RandomMapPresets")
		local preset = type(random_presets) == "table"
			and random_presets[type(mapdata) == "table" and tostring(mapdata.RandomMapPreset or "") or ""]
			or nil
		local function gen_prop(key)
			if type(generator) == "table" and generator[key] ~= nil then return generator[key] end
			if type(preset) == "table" then return preset[key] end
			return nil
		end
		stats.generator_present = type(generator) == "table"
		stats.preset = type(preset) == "table" and tostring(preset.id or preset.Id or "") or "absent"
		local seed = type(generator) == "table" and tonumber(generator.Seed) or nil
		stats.seed_source = seed and "generator" or nil
		if not seed then
			seed = tonumber(map.SuperBigMapPlacementSeed)
			stats.seed_source = seed and "map_placement_seed" or "unavailable"
		end
		if not seed then error("map generator seed unavailable") end
		stats.seed = seed
		-- The census that decides whether this map has a decor-pass share at all: the pass replays
		-- vanilla's decor STAGE, and that stage is `for i=1,self.DecorationPasses` in
		-- Proc_PlaceDecors, so a preset with DecorationPasses == 0 never places a decor group and
		-- therefore has no decor-pass deficit for this pass to restore.
		stats.decoration_passes = tonumber(gen_prop("DecorationPasses"))
		stats.decoration_ratio = tonumber(gen_prop("DecorationRatio"))

		local place_prefab = Global("PlacePrefab")
		local prefab_preload = Global("PrefabPreload")
		local get_prefab_defs = Global("GetPrefabDefs")
		local weighted_rand = (Global("table") or {}).weighted_rand
		local mul_div_round = Global("MulDivRound")
		local rotate_radius = Global("RotateRadius")
		local point_fn = Global("point")
		local point20 = Global("point20")
		local xxhash = Global("xxhash")
		local prefab_markers = Global("PrefabMarkers")
		local prefab_dimensions = Global("PrefabDimensions")
		local terrain_api = Global("terrain")
		local const_tbl = Global("const")
		local is_valid = Global("IsValid")
		local done_object = Global("DoneObject")
		local set_game_flags = Global("SetGameFlags")
		if type(done_object) ~= "function" then
			stats.error = "decor object-removal API unavailable"
			return -- Fail before creating anything, including when engine error() would not throw.
		end
		if type(place_prefab) ~= "function" or type(weighted_rand) ~= "function"
			or type(mul_div_round) ~= "function" or type(rotate_radius) ~= "function"
			or type(point_fn) ~= "function" or type(xxhash) ~= "function"
			or type(prefab_markers) ~= "table" or type(terrain_api) ~= "table"
			or type(const_tbl) ~= "table" then
			error("engine decor APIs unavailable")
		end
		local type_tile = tonumber(const_tbl.TypeTileSize)
			or (type(terrain_api.TypeTileSize) == "function" and SafeCall(terrain_api.TypeTileSize)) or nil
		if not type_tile or type_tile <= 0 then error("terrain type tile size unavailable") end
		local min_prefab_radius = type(prefab_dimensions) == "table"
			and tonumber(prefab_dimensions.MinRadius) or nil
		if not min_prefab_radius or min_prefab_radius <= 0 then min_prefab_radius = 1 end

		local stream = MakeStream(xxhash(seed, DecorTopUp.SEED_TAG))
		if not stream then error("BraidRandom unavailable") end

		-- Vanilla's revision/version gate for matching (RandomMapGenerator.lua:1044-1045).
		local max_int = Global("max_int") or 2147483647
		local prefab_version = tonumber(gen_prop("PrefabVersion")) or 0
		local version = prefab_version > 0 and prefab_version or max_int
		local revision = gen_prop("AssetsRevision") or Global("AssetsRevision") or 0

		-- 1. Census.  Decor sites vanilla used carry DecorTestPrefab (the placed prefab's name);
		--    unused ones still have the default "".  D = used sites = vanilla's decor-group count.
		local sites, used_sites = {}, 0
		-- The stretch stamps SuperBigMapNativeSourceX/Y on every object it moves. A site without
		-- that stamp was never visited, so it still sits at its source position; give it the same
		-- similarity (origin-anchored, per-axis scale) here and move the marker so later passes see
		-- the same geometry. Everything below -- spacing and the stamp itself -- uses the corrected
		-- position; spacing an unmoved site against moved stamps rejected nearly every candidate.
		local sites_prestretched, sites_relocated = 0, 0
		pcall(map.MapForEach, map, "map", "PrefabDecorMarker", function(marker)
			local x, y = PointXY(ObjectPosition(marker))
			if type(x) ~= "number" or type(y) ~= "number" then return end
			if type(marker.SuperBigMapNativeSourceX) == "number" then
				sites_prestretched = sites_prestretched + 1
			else
				marker.SuperBigMapNativeSourceX, marker.SuperBigMapNativeSourceY = x, y
				x, y = math.floor(x * scale_x + 0.5), math.floor(y * scale_y + 0.5)
				local np = point_fn(x, y)
				if type(np.SetTerrainZ) == "function" then
					local okz, nz = pcall(np.SetTerrainZ, np, map)
					if okz and nz then np = nz end
				end
				if type(marker.SetPos) == "function" then pcall(marker.SetPos, marker, np) end
				sites_relocated = sites_relocated + 1
			end
			local used = tostring(marker.DecorTestPrefab or "") ~= ""
			if used then used_sites = used_sites + 1 end
			sites[#sites + 1] = { marker = marker, x = x, y = y, used = used,
				radius = (tonumber(marker.DecorRadius) or 0) * length_scale }
		end)
		stats.sites_prestretched, stats.sites_relocated = sites_prestretched, sites_relocated
		-- Stable order regardless of container iteration order, so the private stream lands on
		-- the same sites every run.
		table.sort(sites, function(a, b)
			if a.x ~= b.x then return a.x < b.x end
			if a.y ~= b.y then return a.y < b.y end
			return tostring(a.marker) < tostring(b.marker)
		end)
		stats.decor_sites = #sites
		stats.vanilla_decor_groups = used_sites

		-- Occupancy: vanilla paints obstruct_grid with every terrain prefab whose zone obstructs
		-- decor (Border, Slope) and every placed decor prefab flagged decor_obstruct; decor_grid
		-- with every placed decor prefab.  Rebuild both as circle lists from the PrefabMarker
		-- objects the stamps left behind, scaled with the map.  A marker whose zone was not
		-- recorded cannot be classified and is treated as non-obstructing, as vanilla treats
		-- Playable/Fill/Base.
		local obstruct, decorated = {}, {}
		pcall(map.MapForEach, map, "map", "PrefabMarker", function(marker)
			local x, y = PointXY(ObjectPosition(marker))
			if type(x) ~= "number" or type(y) ~= "number" then return end
			-- The placed marker composes its prefab's registry name from MarkerName + PrefabType;
			-- the plain fields are editor-only and read back as their defaults here.
			local name = type(marker.GetPrefabName) == "function" and SafeCall(marker.GetPrefabName, marker) or nil
			if type(name) ~= "string" or name == "" then name = marker.PrefabName or marker.ExportedName or "" end
			local prefab = name ~= "" and prefab_markers[name] or nil
			if type(prefab) == "table" then stats.markers_resolved = (stats.markers_resolved or 0) + 1
			else stats.markers_unresolved = (stats.markers_unresolved or 0) + 1 end
			local radius = (type(prefab) == "table" and tonumber(prefab.max_radius) or 0) * type_tile * length_scale
			if radius <= 0 then return end
			local zone = tonumber(marker.zone)
			local circle = { x = x, y = y, r = radius }
			if zone == ZONE_DECOR then
				decorated[#decorated + 1] = circle
				if type(prefab) == "table" and prefab.decor_obstruct then obstruct[#obstruct + 1] = circle end
			elseif zone == 2 or zone == 5 then -- ZONE_BORD, ZONE_SLOPE: decor_obstruct = true
				obstruct[#obstruct + 1] = circle
			end
		end)
		-- Vanilla's decor_grid holds one prefab-radius circle per decor stamp, and the resolved
		-- decor-zone markers above reproduce exactly that.  Only a used site with no resolved stamp
		-- inside its radius falls back to a circle of the site's own radius.  Painting that for every
		-- used site rejected 146 of 152 candidates on a map where vanilla's own grids had accepted
		-- 51 of 203, because a site's radius is several times a decor prefab's.
		local marker_circles, fallback_sites = #decorated, 0
		for _, site in ipairs(sites) do
			if site.used and site.radius > 0 then
				local covered = false
				for i = 1, marker_circles do
					local c = decorated[i]
					local dx, dy = c.x - site.x, c.y - site.y
					if dx * dx + dy * dy <= site.radius * site.radius then covered = true break end
				end
				if not covered then
					decorated[#decorated + 1] = { x = site.x, y = site.y, r = site.radius }
					fallback_sites = fallback_sites + 1
				end
			end
		end
		stats.fallback_sites = fallback_sites
		stats.obstruct_circles = #obstruct
		stats.decorated_circles = #decorated

		-- 2. Size the pass to the deficit, with stochastic rounding from the private stream.
		local exact = used_sites * (area_factor - 1)
		local target = math.floor(exact)
		if stream.rand(1000) < math.floor((exact - target) * 1000 + 0.5) then target = target + 1 end
		local cap = math.max(0, math.floor(cfg_number("STRETCH_DECOR_ENGINE_PASS_MAX_PLACEMENTS", 4000)))
		if target > cap then stats.capped_from = target; target = cap end
		stats.target = target
		stats.enabled = true
		if target == 0 then
			stats.reason = used_sites == 0 and "vanilla placed no decor groups" or "no deficit"
			return
		end

		-- 3. Vanilla's decor weight: prefab weight with repeat reduction, scaled by radius.
		local repeat_reduct = tonumber(gen_prop("RepeatReductOther")) or 0
		local rstep = repeat_reduct / 10
		local prefabs_count = {}
		local function prefab_weight_decor(prefab)
			local weight = mul_div_round(100, tonumber(prefab.weight) or 0, 100)
			if weight == 0 then return 0 end
			local count = prefabs_count[prefab] or 0
			local reduct = repeat_reduct
			for _ = 1, count do
				weight = weight * (100 - reduct) / 100
				reduct = reduct - rstep
				if reduct <= 0 then break end
			end
			weight = math.max(1, math.floor(weight))
			return mul_div_round(weight, tonumber(prefab.max_radius) or min_prefab_radius, min_prefab_radius)
		end

		local defs_cache, raster_cache = {}, {}
		-- Matching reads only the marker's fixed filters and this pass's fixed
		-- revision/catalog. Keep its ordered list private to this Run: vanilla
		-- callers can mutate their own returned lists. Weights/occupancy stay live.
		local matches_cache = {}
		local placed_list = {}
		pass_objects_by_map[map] = placed_list
		local unused = {}
		for _, site in ipairs(sites) do
			if not site.used then unused[#unused + 1] = site end
		end
		stats.unused_sites = #unused

		local gof = (const_tbl.gofPermanent or 0)
		local placed, objects, skipped_obstructed, skipped_no_match, failed = 0, 0, 0, 0, 0
		local map_w, map_h
		if type(terrain_api.GetMapSize) == "function" then
			local ok_size, w, h = pcall(terrain_api.GetMapSize, map)
			if ok_size and type(w) == "number" then map_w, map_h = w, h or w end
		end
		-- The outer band (outer 10 % per axis, the same band the ring census measures) is off limits
		-- to this pass on BOTH maps.  Vanilla's decor stage has no such rule -- it ran before any
		-- expansion existed and its sites are authored content that the stretch merely moved -- so
		-- this is the mod's own constraint on the mod's own additions.  Integer division is intended:
		-- the same expression the census uses, so the two cannot disagree about the boundary.
		local band_x0, band_x1, band_y0, band_y1
		if map_w and map_h then
			band_x0, band_x1 = map_w / 10, map_w - map_w / 10
			band_y0, band_y1 = map_h / 10, map_h - map_h / 10
		end
		local function in_band(x, y)
			if not band_x0 then return false end
			return x < band_x0 or x >= band_x1 or y < band_y0 or y >= band_y1
		end
		stats.band_known = band_x0 ~= nil

		-- 4. One stamp attempt.  Filters come from `marker`, the site is (sx, sy) with radius
		--    site_radius; everything else is vanilla's decor loop: obstruct check, decor check,
		--    weighted pick, jittered stamp inside the site, spacing circles recorded afterwards.
		--    Returns "placed" (plus the prefab name) or the reason it did not place.
		local dropped_non_cosmetic, dropped_out_of_band = 0, 0
		local grounding = SuperBigMap.RockGrounding
		local function try_stamp(marker, sx, sy, site_radius)
			local prefabs = matches_cache[marker]
			if prefabs == nil then
				prefabs = SafeCall(marker.GetMatchingMarkers, marker, revision, version)
				-- Cache legitimate empty lists too, but never make a failed call
				-- permanent. Preserve no_match precedence over spacing rejection.
				if type(prefabs) == "table" then matches_cache[marker] = prefabs end
			end
			if type(prefabs) ~= "table" or #prefabs == 0 then return "no_match" end
			if circle_hits(obstruct, sx, sy, site_radius) then return "obstruct" end
			if circle_hits(decorated, sx, sy, site_radius) then return "decorated" end
			local prefab = weighted_rand(prefabs, prefab_weight_decor, stream.seed())
			if type(prefab) ~= "table" then return "no_match" end
			local name = prefab_markers[prefab]
			if type(name) ~= "string" then return "no_match" end
			local prefab_radius = (tonumber(prefab.max_radius) or 0) * type_tile * length_scale
			local max_offset = math.max(0, math.floor(site_radius - prefab_radius))
			local dx, dy = rotate_radius(stream.rand(max_offset), stream.rand(MAX_ROTATION), point20, true)
			local cx, cy = sx + (tonumber(dx) or 0), sy + (tonumber(dy) or 0)
			if map_w and (cx < 0 or cy < 0 or cx >= map_w or cy >= map_h) then return "bounds" end
			if in_band(cx, cy) then return "band" end
			local defs = defs_cache[name]
			if defs == nil and type(get_prefab_defs) == "function" then
				local derr, d = get_prefab_defs(name)
				defs = not derr and d or false
				defs_cache[name] = defs
			end
			local raster = raster_cache[name]
			if raster == nil and type(prefab_preload) == "function" then
				raster = SafeCall(prefab_preload, prefab) or false
				raster_cache[name] = raster
			end
			local angle = stream.rand(tonumber(prefab.rotation) or MAX_ROTATION)
				- (tonumber(prefab.orientation) or 0)
			local center = point_fn(cx, cy)
			if type(center.SetTerrainZ) == "function" then
				local okz, cz = pcall(center.SetTerrainZ, center, map)
				if okz and cz then center = cz end
			end
			local params = { dont_change_terrain = true, allow_outsiders = true }
			if defs then params.defs = defs end
			if raster then
				local copy = {}
				for k, v in pairs(raster) do copy[k] = v end
				params.raster_params = copy
			end
			local perr, objs = place_prefab(map, name, center, angle, nil, params)
			if perr or type(objs) ~= "table" or #objs == 0 then return "failed" end
			local validation=SuperBigMap.DecorationValidation
			if validation then validation.Run("CaptureGroup",map,objs) end
			local first_new_object, cosmetic_objects = #placed_list + 1, 0
			-- The group arrived at native offsets and native size.  Give it the stretch's
			-- similarity about its centre so it matches its neighbours, and reseat each object on
			-- the stretched terrain.
			for _, obj in ipairs(objs) do
				local ox, oy = PointXY(ObjectPosition(obj))
				if type(ox) == "number" and type(oy) == "number" then
					-- Validate the exact coordinates SetPos will receive, including rounding
					-- across the half-open upper band/map boundary.
					local nx = math.floor(cx + (ox - cx) * length_scale + 0.5)
					local ny = math.floor(cy + (oy - cy) * length_scale + 0.5)
					local outside = map_w and (nx < 0 or ny < 0 or nx >= map_w or ny >= map_h)
					-- The centre was already refused inside the band; the similarity about that centre
					-- can still push a single object of an edge-of-band group across the boundary.
					local banded = not outside and in_band(nx, ny)
					-- Only cosmetic scatter may come out of this pass.  A decor prefab is authored art,
					-- but anything gameplay-bearing that rode along -- deposit, anomaly or feature
					-- markers, nested decor sites -- is removed rather than left as an orphan a later
					-- stage could turn into a geyser or a deposit.  The stamp's own PrefabMarker stays,
					-- tagged as a decor stamp, so later passes classify it exactly like vanilla's.
					local class_name = tostring(obj.class or "")
					local is_stamp_marker = class_name == "PrefabMarker"
					-- Deny first: every other prefab-authoring object (feature sites, nested decor sites)
					-- and anything deposit-, anomaly- or building-like is never cosmetic, whatever the
					-- scale rule says -- the v902 census still showed 11 PrefabFeatureMarker objects
					-- placed by this pass.
					local denied = not is_stamp_marker and (IsKindOfSafe(obj, "PrefabObj")
						or class_name:find("Marker", 1, true) ~= nil
						or IsKindOfSafe(obj, "Deposit") or IsKindOfSafe(obj, "DepositMarker")
						or IsKindOfSafe(obj, "SubsurfaceAnomaly") or IsKindOfSafe(obj, "SubsurfaceAnomalyMarker")
						or IsKindOfSafe(obj, "EffectDepositMarker") or IsKindOfSafe(obj, "Building")
						-- `RubbleBase` is named explicitly even though it already parents `Building`:
						-- the underground's cave-ins and collapsed tunnels (`CaveInRubble`,
						-- `TunnelBlockerRubble`) are gameplay obstacles this pass must never create,
						-- and `ObjectScalesWithTerrain` deliberately answers TRUE for them
						-- (sbm_object_clone scale_stretch_allowlist), so the denial must not rest on
						-- one inherited kind test.
						or IsKindOfSafe(obj, "RubbleBase"))
					local cosmetic = not denied and IsAllowedDecorOutputClass(class_name, environment)
					if (outside or banded or not cosmetic) and type(done_object) == "function" then
						if banded then dropped_out_of_band = dropped_out_of_band + 1
						elseif not outside then dropped_non_cosmetic = dropped_non_cosmetic + 1 end
						pcall(done_object, obj)
					else
						if is_stamp_marker then obj.zone = ZONE_DECOR end
						local np = point_fn(nx, ny)
						if type(np.SetTerrainZ) == "function" then
							local okz, nz = pcall(np.SetTerrainZ, np, map)
							if okz and nz then np = nz end
						end
						if type(obj.SetPos) == "function" then pcall(obj.SetPos, obj, np) end
						if type(ObjectScalesWithTerrain) == "function" and ObjectScalesWithTerrain(obj)
							and type(obj.GetScale) == "function" and type(obj.SetScale) == "function" then
							local sc = SafeCall(obj.GetScale, obj)
							if type(sc) == "number" and sc > 0 then
								pcall(obj.SetScale, obj, math.min(500, math.max(1, math.floor(sc * length_scale + 0.5))))
							end
						end
						if grounding and type(grounding.GroundFinal) == "function" then
							local ground_ok, lowered, ground_err = pcall(grounding.GroundFinal, map, obj)
							if not ground_ok or lowered == nil then
								grounding.Failure(map, ground_ok and ground_err or lowered)
							end
						end
						if type(set_game_flags) == "function" and gof ~= 0 then pcall(set_game_flags, obj, gof) end
						obj.SuperBigMapDecorEnginePass = true
						placed_list[#placed_list + 1] = obj
						objects = objects + 1
						if not is_stamp_marker then cosmetic_objects = cosmetic_objects + 1 end
					end
				elseif type(done_object) == "function" then
					-- An unpositioned creation cannot be certified cosmetic and in bounds.
					dropped_non_cosmetic = dropped_non_cosmetic + 1
					pcall(done_object, obj)
				end
			end
			if cosmetic_objects == 0 then
				-- A surviving stamp marker alone restores no visible decor density.
				for i = #placed_list, first_new_object, -1 do
					if type(done_object) == "function" then pcall(done_object, placed_list[i]) end
					placed_list[i] = nil
					objects = objects - 1
				end
				return "empty"
			end
			placed = placed + 1
			prefabs_count[prefab] = (prefabs_count[prefab] or 0) + 1
			local circle = { x = cx, y = cy, r = prefab_radius }
			decorated[#decorated + 1] = circle
			if prefab.decor_obstruct then obstruct[#obstruct + 1] = circle end
			return "placed", name
		end

		-- 5. Vanilla's loop over the sites it left unused, until the deficit is met.
		local placed_authored, skipped_bounds, skipped_band = 0, 0, 0
		local guard = #unused * 2 + 8
		while placed < target and #unused > 0 and guard > 0 do
			guard = guard - 1
			local site = table.remove(unused, stream.rand(#unused) + 1)
			if not is_valid or is_valid(site.marker) then
				local outcome, name = try_stamp(site.marker, site.x, site.y, site.radius)
				if outcome == "placed" then
					placed_authored = placed_authored + 1
					site.marker.DecorTestPrefab = name
					site.used = true
				elseif outcome == "obstruct" then
					skipped_obstructed = skipped_obstructed + 1
					stats.skipped_by_obstruct = (stats.skipped_by_obstruct or 0) + 1
				elseif outcome == "decorated" then
					skipped_obstructed = skipped_obstructed + 1
					stats.skipped_by_decorated = (stats.skipped_by_decorated or 0) + 1
				elseif outcome == "no_match" then skipped_no_match = skipped_no_match + 1
				elseif outcome == "bounds" then skipped_bounds = skipped_bounds + 1
				elseif outcome == "band" then skipped_band = skipped_band + 1
				else failed = failed + 1 end
			end
		end
		stats.placed_authored = placed_authored
		stats.sites_exhausted = #unused == 0 and placed < target

		-- 6. Synthetic sites.  The map authors too few free decor sites for 1.778x density: at
		--    14N134W, 137 of the 152 sites vanilla left unused sit inside Border/Slope prefab radii
		--    that vanilla's own obstruct grid rejects, and vanilla had consumed nearly every placeable
		--    one (7 remained).  So once the authored sites run out, borrow the filters of a used site
		--    -- the group is then one vanilla would put in exactly that context -- and try a seeded
		--    position around it, between 1x and its current reach x its radius away (JITTER_MAX to
		--    start, widened as the template runs out of room, see below) and on the same terrain
		--    type.  Only the site is the mod's; matcher, weights, spacing and stamp stay vanilla's.
		local placed_synthetic = 0
		if placed < target and cfg_bool("STRETCH_DECOR_ENGINE_PASS_SYNTHETIC_SITES", true) then
			local templates = {}
			for _, site in ipairs(sites) do
				if site.used and site.radius > 0 and (not is_valid or is_valid(site.marker)) then
					templates[#templates + 1] = site
				end
			end
			stats.synthetic_templates = #templates
			local per_group = math.max(1, math.floor(
				cfg_number("STRETCH_DECOR_ENGINE_PASS_SYNTHETIC_ATTEMPTS_PER_GROUP", 200)))
			local jitter_max = math.max(100, math.floor(
				cfg_number("STRETCH_DECOR_ENGINE_PASS_SYNTHETIC_JITTER_MAX_PERCENT", 350)))
			local get_type = terrain_api.GetTerrainType
			local type_cache = {}
			local function terrain_type_at(x, y)
				if type(get_type) ~= "function" then return 0 end
				local key = math.floor(x / type_tile) * 1000003 + math.floor(y / type_tile)
				local cached = type_cache[key]
				if cached ~= nil then return cached end
				local okt, t = pcall(get_type, map, point_fn(x, y))
				t = okt and type(t) == "number" and t or -1
				type_cache[key] = t
				return t
			end
			-- Vanilla-like context means a terrain type vanilla's own decor already sits on.  Read
			-- it under every existing stamp and every used site and accept any of those types, rather
			-- than demanding equality with one template's centre: prefabs paint their own texture
			-- inside their footprint, so the equality test rejected 987 of 1320 attempts (75%) for
			-- positions on perfectly ordinary decorated ground.
			local allowed_types, allowed_count = {}, 0
			local function allow(t)
				if t >= 0 and not allowed_types[t] then
					allowed_types[t] = true
					allowed_count = allowed_count + 1
				end
			end
			for i = 1, marker_circles do allow(terrain_type_at(decorated[i].x, decorated[i].y)) end
			for _, site in ipairs(templates) do allow(terrain_type_at(site.x, site.y)) end
			stats.synthetic_allowed_types = allowed_count
			local attempts, budget = 0, (target - placed) * per_group
			local finite_templates = {}
			for i = 1, #templates do finite_templates[i] = templates[i] end
			local rejected = { obstruct = 0, decorated = 0, no_match = 0, bounds = 0, failed = 0,
				terrain = 0, band = 0 }
			-- A template hemmed in by mountain masses fails every draw on the obstruct circles (1,021
			-- of 1,320 rejections in v903), and one whose annulus is already full fails every draw on
			-- the decorated circles.  Both mean "no room at this reach", so after `patience`
			-- consecutive no-room misses WIDEN that template instead of retiring it: double its jitter
			-- reach and reset its counter, and defer to finite interior coverage at the reach cap. A
			-- success resets the counter too.  Retiring outright is what v921 did (obstruct misses
			-- only), and on a decor-dense site it dismantles the pool: at 15S67E 135 of 136 templates
			-- retired -- 135 x 24 = 3,240 of the 3,527 obstruct rejections were retirement streaks --
			-- and 65% of the budget then fell on the one survivor's saturated annulus, so the pass
			-- placed 67 of 99.  Bounds, terrain and no-match misses still count for nothing: widening
			-- would not help those.
			local patience = math.max(1, math.floor(
				cfg_number("STRETCH_DECOR_ENGINE_PASS_SYNTHETIC_TEMPLATE_PATIENCE", 24)))
			local reach_cap = math.max(jitter_max, math.floor(
				cfg_number("STRETCH_DECOR_ENGINE_PASS_SYNTHETIC_JITTER_REACH_CAP_PERCENT", 2800)))
			local template_fail, template_reach, exhausted, escalations = {}, {}, 0, 0
			local max_reach = jitter_max
			while placed < target and attempts < budget and #templates > 0 do
				attempts = attempts + 1
				local ti = stream.rand(#templates) + 1
				local template = templates[ti]
				local reach = template_reach[template] or jitter_max
				local extra = math.max(1, math.floor(template.radius * (reach - 100) / 100))
				local dist = math.floor(template.radius) + stream.rand(extra)
				local dx, dy = rotate_radius(dist, stream.rand(MAX_ROTATION), point20, true)
				local sx, sy = template.x + (tonumber(dx) or 0), template.y + (tonumber(dy) or 0)
				local outcome
				if map_w and (sx - template.radius < 0 or sy - template.radius < 0
					or sx + template.radius >= map_w or sy + template.radius >= map_h) then
					outcome = "bounds"
				elseif allowed_count > 0 and not allowed_types[terrain_type_at(sx, sy)] then
					outcome = "terrain"
				else
					outcome = try_stamp(template.marker, sx, sy, template.radius)
				end
				if outcome == "placed" then
					placed_synthetic = placed_synthetic + 1
					template_fail[template] = 0
				else
					rejected[outcome] = (rejected[outcome] or 0) + 1
					if outcome == "obstruct" or outcome == "decorated" then
						local misses = (template_fail[template] or 0) + 1
						template_fail[template] = misses
						if misses >= patience then
							template_fail[template] = 0
							if reach < reach_cap then
								local wider = math.min(reach_cap, reach * 2)
								template_reach[template] = wider
								escalations = escalations + 1
								if wider > max_reach then max_reach = wider end
							else
								table.remove(templates, ti)
							end
						end
					end
				end
			end
			local random_attempts = attempts
			local finite_cursors, finite_attempts = {}, 0
			-- A miss streak is not proof that legal ground is exhausted. Continue through
			-- a finite seeded cell cover of the interior, retaining each template's matcher,
			-- radius, terrain-type restrictions and live stamp/occupancy checks. The old
			-- budget bounds the random annulus phase only; this phase ends at exact demand
			-- or exhaustion of all finite candidate cells, never an arbitrary miss count.
			while placed < target and #finite_templates > 0 do
				local ti = stream.rand(#finite_templates) + 1
				local template = finite_templates[ti]
				local cursor = finite_cursors[template]
				if not cursor then
					local radius = template.radius
					cursor = NewDecorInteriorCursor(
						math.max(radius, band_x0 or 0), math.max(radius, band_y0 or 0),
						math.min((map_w or 0) - radius, band_x1 or 0),
						math.min((map_h or 0) - radius, band_y1 or 0),
						math.max(type_tile, math.floor(radius / 2)), stream.rand)
					finite_cursors[template] = cursor
				end
				local sx, sy = cursor()
				if sx == nil then
					table.remove(finite_templates, ti)
					exhausted = exhausted + 1
				else
					attempts, finite_attempts = attempts + 1, finite_attempts + 1
					local outcome
					if allowed_count > 0 and not allowed_types[terrain_type_at(sx, sy)] then
						outcome = "terrain"
					else
						outcome = try_stamp(template.marker, sx, sy, template.radius)
					end
					if outcome == "placed" then
						placed_synthetic = placed_synthetic + 1
					else
						rejected[outcome] = (rejected[outcome] or 0) + 1
					end
				end
			end
			stats.synthetic_templates_exhausted = exhausted
			stats.synthetic_random_attempts = random_attempts
			stats.synthetic_finite_attempts = finite_attempts
			stats.synthetic_finite_templates_left = #finite_templates
			stats.synthetic_escalations = escalations
			stats.synthetic_reach_cap_percent = reach_cap
			stats.synthetic_max_reach_percent = max_reach
			stats.synthetic_templates_left = #templates
			stats.synthetic_attempts = attempts
			stats.synthetic_budget = budget
			for k, v in pairs(rejected) do stats["synthetic_rejected_" .. k] = v end
		end
		stats.placed_synthetic = placed_synthetic
		stats.placed, stats.objects = placed, objects
		stats.skipped_obstructed, stats.skipped_no_match, stats.failed = skipped_obstructed, skipped_no_match, failed
		stats.skipped_bounds = skipped_bounds
		stats.skipped_band = skipped_band
		stats.dropped_non_cosmetic = dropped_non_cosmetic
		stats.dropped_out_of_band = dropped_out_of_band
		-- Measured, not assumed: re-read every surviving object's final position and count the ones
		-- inside the outer band.  This is the field the ring rule is judged on, so it must come from
		-- the objects themselves rather than from the refusals above.
		local ring_objects = 0
		for _, obj in ipairs(placed_list) do
			local ox, oy = PointXY(ObjectPosition(obj))
			if type(ox) == "number" and type(oy) == "number" and in_band(ox, oy) then
				ring_objects = ring_objects + 1
			end
		end
		stats.ring_objects = ring_objects
		stats.ms = (SafeCall(Global("GetPreciseTicks")) or 0) - started_ms
		DecorTopUp.LastObjects = placed_list
	end)
	if not ok then
		stats.error = tostring(err)
	elseif stats.enabled and type(stats.target) == "number" and stats.placed ~= stats.target then
		stats.error = string.format("decor candidate search incomplete: placed=%s target=%s",
			tostring(stats.placed), tostring(stats.target))
	end
	if stats.error then
		local State = SuperBigMap.State or {}
		SuperBigMap.State = State
		State.optimization_failures = State.optimization_failures or {}
		State.optimization_failures[#State.optimization_failures + 1] = {
			unit = "decor finite candidate coverage", reason = stats.error,
			map = map and tostring(map.name) or nil,
		}
		local print_fn = Global("print")
		if type(print_fn) == "function" then
			print_fn("[Super Big Map][OptimizationFailure] decor: " .. stats.error)
		end
		local thread, message = Global("CreateRealTimeThread"), Global("CreateMessageBox")
		if type(thread) == "function" and type(message) == "function" then
			thread(function()
				local sleep, loading = Global("Sleep"), Global("GetLoadingScreenDialog")
				for _ = 1, 1200 do
					local ok_loading, dialog
					if type(loading) == "function" then ok_loading, dialog = pcall(loading) end
					if not (ok_loading and dialog) then break end
					if type(sleep) ~= "function" then break end
					sleep(500)
				end
				pcall(message, nil, "Super Big Map: map generation failed", stats.error
					.. "\n\nThis map is not valid. Please start a new game.")
			end)
		end
		return false, stats
	end
	return true, stats
end

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
-- This replenishes the decor-pass share only.  Decor baked into the terrain prefabs stays at
-- 1/area_factor density; nothing short of re-laying the map can change that.

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

DecorTopUp.VERSION = 1
DecorTopUp.SEED_TAG = "SuperBigMapDecorEnginePass"
DecorTopUp.LastStats = nil

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
	for i = 1, #list do
		local c = list[i]
		local dx, dy = x - c.x, y - c.y
		local reach = radius + c.r
		if dx * dx + dy * dy < reach * reach then return true end
	end
	return false
end

-- Runs while the stretch's pass edits are still suspended, after ScaleDecorationsToFull and
-- ScaleMarkersToFull have moved every marker to its stretched position.  Never throws; a hard
-- failure comes back as false plus a reason, and the map is left exactly as it was.
function DecorTopUp.Run(map, pass_edits_already_suspended)
	local stats = { version = DecorTopUp.VERSION, enabled = false, placed = 0, objects = 0 }
	DecorTopUp.LastStats = stats
	local ok, err = pcall(function()
		if not map or type(map.MapForEach) ~= "function" then error("no live map") end
		local mapdata = map.mapdata
		local environment = type(mapdata) == "table" and tostring(mapdata.Environment or "") or ""
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
		local seed = type(generator) == "table" and tonumber(generator.Seed) or nil
		if not seed then error("map generator seed unavailable") end

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
		local prefab_version = tonumber(generator.PrefabVersion) or 0
		local version = prefab_version > 0 and prefab_version or max_int
		local revision = generator.AssetsRevision or Global("AssetsRevision") or 0

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
		local repeat_reduct = tonumber(generator.RepeatReductOther) or 0
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
		local placed_list = {}
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

		-- 4. Vanilla's loop, over the unused sites, until the deficit is met.
		local guard = #unused * 2 + 8
		while placed < target and #unused > 0 and guard > 0 do
			guard = guard - 1
			local idx = stream.rand(#unused) + 1
			local site = table.remove(unused, idx)
			local marker = site.marker
			if not is_valid or is_valid(marker) then
				local prefabs = SafeCall(marker.GetMatchingMarkers, marker, revision, version)
				if type(prefabs) ~= "table" or #prefabs == 0 then
					skipped_no_match = skipped_no_match + 1
				elseif circle_hits(obstruct, site.x, site.y, site.radius) then
					skipped_obstructed = skipped_obstructed + 1
					stats.skipped_by_obstruct = (stats.skipped_by_obstruct or 0) + 1
				elseif circle_hits(decorated, site.x, site.y, site.radius) then
					skipped_obstructed = skipped_obstructed + 1
					stats.skipped_by_decorated = (stats.skipped_by_decorated or 0) + 1
				else
					local prefab = weighted_rand(prefabs, prefab_weight_decor, stream.seed())
					if type(prefab) == "table" then
						local name = prefab_markers[prefab]
						local prefab_radius = (tonumber(prefab.max_radius) or 0) * type_tile * length_scale
						local max_offset = math.max(0, math.floor(site.radius - prefab_radius))
						local dx, dy = rotate_radius(stream.rand(max_offset), stream.rand(MAX_ROTATION), point20, true)
						local cx, cy = site.x + (tonumber(dx) or 0), site.y + (tonumber(dy) or 0)
						local inside = not map_w or (cx >= 0 and cy >= 0 and cx < map_w and cy < map_h)
						if type(name) == "string" and inside then
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
							if perr or type(objs) ~= "table" or #objs == 0 then
								failed = failed + 1
							else
								-- The group arrived at native offsets and native size.  Give it the
								-- stretch's similarity about its centre so it matches its neighbours,
								-- and reseat each object on the stretched terrain.
								for _, obj in ipairs(objs) do
									local ox, oy = PointXY(ObjectPosition(obj))
									if type(ox) == "number" and type(oy) == "number" then
										local nx = cx + (ox - cx) * length_scale
										local ny = cy + (oy - cy) * length_scale
										local outside = map_w and (nx < 0 or ny < 0 or nx >= map_w or ny >= map_h)
										if outside and type(done_object) == "function" then
											pcall(done_object, obj)
										else
											local np = point_fn(math.floor(nx + 0.5), math.floor(ny + 0.5))
											if type(np.SetTerrainZ) == "function" then
												local okz, nz = pcall(np.SetTerrainZ, np, map)
												if okz and nz then np = nz end
											end
											if type(obj.SetPos) == "function" then pcall(obj.SetPos, obj, np) end
											if type(ObjectScalesWithTerrain) == "function" and ObjectScalesWithTerrain(obj)
												and type(obj.GetScale) == "function" and type(obj.SetScale) == "function" then
												local s = SafeCall(obj.GetScale, obj)
												if type(s) == "number" and s > 0 then
													pcall(obj.SetScale, obj, math.min(500, math.max(1, math.floor(s * length_scale + 0.5))))
												end
											end
											if type(set_game_flags) == "function" and gof ~= 0 then pcall(set_game_flags, obj, gof) end
											obj.SuperBigMapDecorEnginePass = true
											placed_list[#placed_list + 1] = obj
											objects = objects + 1
										end
									end
								end
								placed = placed + 1
								prefabs_count[prefab] = (prefabs_count[prefab] or 0) + 1
								marker.DecorTestPrefab = name
								local circle = { x = cx, y = cy, r = prefab_radius }
								decorated[#decorated + 1] = circle
								if prefab.decor_obstruct then obstruct[#obstruct + 1] = circle end
							end
						end
					end
				end
			end
		end
		stats.placed, stats.objects = placed, objects
		stats.skipped_obstructed, stats.skipped_no_match, stats.failed = skipped_obstructed, skipped_no_match, failed
		stats.sites_exhausted = #unused == 0 and placed < target
		stats.ms = (SafeCall(Global("GetPreciseTicks")) or 0) - started_ms
		DecorTopUp.LastObjects = placed_list
	end)
	if not ok then
		stats.error = tostring(err)
		return false, stats
	end
	return true, stats
end

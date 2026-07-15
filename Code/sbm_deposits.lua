-- Super Big Map -- cloned-deposit visibility (scan-gated).
--
-- PROBLEM: in SMR a sector's resource deposits do not exist at map-gen -- the sector holds
-- MARKERS and the real deposit object is spawned only when the sector is SCANNED
-- (Exploration.lua RevealDeposits, via marker:PlaceDeposit). The colony's starting sector is
-- auto-revealed, so its subsurface deposits/anomalies ARE live objects. When the expansion
-- mirror-copies the source quadrant, those revealed deposits get cloned into the (unscanned)
-- L-frame sectors -- so the player can see them before scanning. Vanilla subsurface deposits
-- are an ExplorableObject whose visibility follows a `revealed` flag (SubsurfaceDeposit.lua
-- PickVisibilityState); the clone copied revealed=true, so it shows.
--
-- FIX: when a deposit clone is created, if it is an ExplorableObject (SubsurfaceDeposit /
-- SubsurfaceAnomaly), force revealed=false and re-pick its visibility -> hidden. Then, on the
-- SectorScanned message, reveal the clones that lie inside the scanned sector's area. This
-- mirrors vanilla scan-gating for the copied deposits without touching the marker system.
--
-- Surface deposits (SurfaceDeposit / TerrainDepositConcrete) are not scan-gated here: vanilla
-- shows them always. Concrete carries a painted regolith terrain texture; the copy mirrors that
-- patch to each clone's initial position. When reshuffle moves a concrete marker, the old patch
-- is cleared immediately; the new patch is painted only if the final sector is already scanned.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall

local function cfg()
	return SuperBigMap.Config or {}
end

local function ExpansionStepEnabled(step)
	local steps = cfg().EXPANSION_ENRICHMENT_STEPS
	return type(steps) == "table" and steps[step] == true
end

local function ExpansionAdditionStagesReady(label)
	for step = 9, 17 do
		if not ExpansionStepEnabled(step) then
			local DebugLog = SuperBigMap.DebugLog
			if DebugLog then
				DebugLog.Info("Deposits", "enrichment addition pipeline stopped at disabled step", {
					pipeline = tostring(label or "?"), step = step,
				})
			end
			return false
		end
	end
	return true
end

-- Stretch density-suite cache. TopUpDeposits performs the largest validated random sampling
-- pass; anomaly/effect top-ups can consume its unused candidates instead of rebuilding
-- equivalent pools. Weak map keys release abandoned-map entries automatically.
local topup_candidate_pool_by_map = setmetatable({}, { __mode = "k" })
-- Final underground connectivity state, built only after the stretched passability/buildable
-- grids are synchronously rebuilt. Exact-hex results are cached because all three top-up passes
-- and the final marker audit ask the same entrance-reachability question repeatedly.
local underground_reachability_by_map = setmetatable({}, { __mode = "k" })

local function CachedTopUpCandidates(map)
	if cfg().OPTIMIZE_TOPUP_PLACEMENT_POOLS ~= true then return nil end
	return topup_candidate_pool_by_map[map]
end

local function ClearTopUpPlacementPool(map)
	if map then
		topup_candidate_pool_by_map[map] = nil
		underground_reachability_by_map[map] = nil
	end
end

local function Enabled()
	return cfg().HIDE_CLONED_DEPOSITS_UNTIL_SCAN ~= false
end

local function Log(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then DebugLog.Info("Deposits", message, data) end
end

local function TopUpEdgeLogOn()
	local DebugLog = SuperBigMap.DebugLog
	return DebugLog and type(DebugLog.On) == "function"
		and DebugLog.On("TopUpEdgeDistribution") == true
end

local function TopUpEdgeLog(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then DebugLog.Info("TopUpEdgeDistribution", message, data) end
end

local function ProfileStep(message, data, map)
	local profiler = SuperBigMap.LoadingProfiler
	if profiler and type(profiler.Step) == "function" then
		profiler.Step("enrichment optimization: " .. tostring(message), data, map)
	end
end

local IsKindOfSafe = Engine.IsKindOf

-- An ExplorableObject deposit/anomaly hides/shows via its `revealed` flag + PickVisibilityState.
local function IsScanGatedDeposit(obj)
	return obj ~= nil and IsKindOfSafe(obj, "ExplorableObject")
		and (IsKindOfSafe(obj, "SubsurfaceDeposit") or IsKindOfSafe(obj, "SubsurfaceAnomaly"))
end

-- RESOURCE deposit markers only -- surface, subsurface (incl. deep), and concrete/terrain.
-- These three are the resource deposits the player wants copied. Anomaly markers
-- (SubsurfaceAnomalyMarker + its Special/Rare subclasses) and EffectDepositMarker are also
-- DepositMarker subclasses but are NOT any of these, so they are excluded automatically.
local function IsResourceDepositMarker(obj)
	if obj == nil then return false end
	return IsKindOfSafe(obj, "SurfaceDepositMarker")
		or IsKindOfSafe(obj, "SubsurfaceDepositMarker")
		or IsKindOfSafe(obj, "TerrainDepositMarker")
end

local function IsConcreteTerrainDepositMarker(obj)
	return obj ~= nil and obj.resource == "Concrete" and IsKindOfSafe(obj, "TerrainDepositMarker")
end

-- UNDERGROUND maps must not depend on sector mechanics AT ALL (user directive): their
-- enrichments follow vanilla's proximity reveal -- a DepositRevealer (on rovers/units) calls
-- RevealDepositsInRange, which PlaceDeposit()s every UNPLACED DepositMarker in range and
-- reveals ExplorableObjects. An unplaced clone marker is therefore all the gating needed;
-- sector registration (the surface scan-reveal hook) is skipped underground.
-- (Declared early: RegisterClonedMarkers and both top-ups below use it.)
local function IsUndergroundMap(map)
	local mapdata = map and map.mapdata
	return type(mapdata) == "table" and mapdata.Environment == "Underground"
end

local function SetRevealedState(obj, revealed)
	-- Prefer the object's own SetRevealed if present (CrystalsBuilding etc.); else set the
	-- property and re-pick visibility the way the engine does on reveal.
	if type(obj.SetRevealed) == "function" then
		SafeCall(obj.SetRevealed, obj, revealed, "force")
	else
		obj.revealed = revealed
	end
	if type(obj.PickVisibilityState) == "function" then
		SafeCall(obj.PickVisibilityState, obj)
	end
end

-- ---------------------------------------------------------------------------------------
-- Reshuffle: move a cloned deposit onto nearby terrain that best matches the terrain its
-- SOURCE deposit sat on. The expansion copies the terrain (incl. the concrete "yellow"
-- patch, which is terrain type Regolith_02) but places the deposit OBJECT by translation,
-- so a deposit can end up off its matching ground / off its concrete patch. Searching for
-- the nearest spot whose terrain TYPE (and flatness) matches the source re-seats it. For moved
-- concrete markers, the copied regolith patch is cleared from the initial mirrored position and
-- only repainted at the final position when that sector is already scanned.
-- ---------------------------------------------------------------------------------------
local function ReshuffleEnabled()
	return cfg().RESHUFFLE_CLONED_DEPOSITS == true
end

local ObjectPos = Engine.ObjectPos

local function TerrainTypeAt(map, pt)
	local t = Global("terrain")
	if type(t) == "table" and type(t.GetTerrainType) == "function" then
		local ok, v = pcall(t.GetTerrainType, map, pt)
		if ok then return v end
	end
	return nil
end

-- normal.z in base 4096 (4096 = perfectly flat); a cheap, trig-free "flatness" measure.
local function FlatnessAt(map, pt)
	local t = Global("terrain")
	if type(t) == "table" and type(t.GetTerrainNormal) == "function" then
		local ok, n = pcall(t.GetTerrainNormal, map, pt)
		if ok and n and type(n.z) == "function" then
			local okz, z = pcall(n.z, n)
			if okz and type(z) == "number" then return z end
		end
	end
	return 4096
end

local function PassableAt(map, pt)
	local t = Global("terrain")
	if type(t) == "table" and type(t.IsPassable) == "function" then
		local ok, v = pcall(t.IsPassable, map, pt)
		if ok then return v == true end
	end
	return true
end

local MapWorldSize = Engine.MapWorldSize

local RandInt = Engine.RandInt

local function RunPaused(reason, fn)
	local pause = Global("PauseInfiniteLoopDetection")
	local resume = Global("ResumeInfiniteLoopDetection")
	if type(pause) == "function" then SafeCall(pause, reason) end
	local ok, err = pcall(fn)
	if type(resume) == "function" then SafeCall(resume, reason) end
	if not ok then Log("paused enrichment operation ERROR", {
		reason = tostring(reason), error = tostring(err),
	}) end
	return ok, err
end

-- A tile can receive a deposit if it is passable and flat enough (not a cliff).
local FLATNESS_MIN = 3700   -- normal.z (of 4096); ~ below this is too steep
local function IsBuildableAt(map, pt, strict)
	local buildable = map and map.buildable
	local world_to_hex = Global("WorldToHex")
	local build_unbuildable = Global("buildUnbuildableZ")
	if not (buildable and type(buildable.GetZ) == "function" and type(world_to_hex) == "function"
		and type(build_unbuildable) == "function") then
		return strict ~= true -- surface keeps the historical fail-open behavior; underground is strict
	end
	local ok_u, sentinel = pcall(build_unbuildable)
	if not ok_u then return strict ~= true end
	local ok_h, q, r = pcall(world_to_hex, pt)
	if not ok_h or type(q) ~= "number" then return strict ~= true end
	local ok_z, z = pcall(buildable.GetZ, buildable, q, r)
	return ok_z and z ~= nil and z ~= sentinel
end

local function IsUnobstructedAt(map, pt, strict)
	local hex_grid = map and map.object_hex_grid
	local world_to_hex = Global("WorldToHex")
	if not (hex_grid and type(hex_grid.GetBuildObstructions) == "function"
		and type(world_to_hex) == "function") then
		return strict ~= true
	end
	local ok_h, q, r = pcall(world_to_hex, pt)
	if not ok_h or type(q) ~= "number" or type(r) ~= "number" then return strict ~= true end
	local ok_o, obstructions = pcall(hex_grid.GetBuildObstructions, hex_grid, q, r)
	if not ok_o then return strict ~= true end
	return not obstructions or #obstructions == 0
end

local function BuildUndergroundReachability(map)
	if not IsUndergroundMap(map) then return nil end
	local cached = underground_reachability_by_map[map]
	if cached then return cached end
	local state = {
		seeds = {}, results = {}, checks = 0, reachable = 0, rejected = 0,
		failures = 0, method = "unavailable",
	}
	underground_reachability_by_map[map] = state
	local connectivity_check = Global("ConnectivityCheck")
	local pf_api = Global("pf")
	if type(connectivity_check) == "function" then
		state.method = "ConnectivityCheck"
	elseif type(pf_api) == "table" and type(pf_api.HasPosPath) == "function" then
		state.method = "pf.HasPosPath"
	end
	local resume = Global("ConnectivityResume")
	if type(resume) == "function" then pcall(resume, map) end
	local terrain_api = Global("terrain")
	local find_passable = type(terrain_api) == "table" and terrain_api.FindPassable or nil
	local const_tbl = Global("const")
	local hex = type(const_tbl) == "table" and tonumber(const_tbl.HexSize) or 0
	local snap_radius = math.max(8000, hex * 12)
	local world_to_hex = Global("WorldToHex")
	local seed_hexes = {}
	local function add_seed(obj)
		local pos = ObjectPos(obj)
		if not pos then return end
		if type(find_passable) == "function" then
			local ok_p, passable = pcall(find_passable, map, pos, 1, snap_radius)
			if ok_p and passable then pos = passable end
		end
		local key = tostring(pos)
		if type(world_to_hex) == "function" then
			local ok_h, q, r = pcall(world_to_hex, pos)
			if ok_h and type(q) == "number" and type(r) == "number" then
				key = tostring(q) .. ":" .. tostring(r)
			end
		end
		if not seed_hexes[key] then
			seed_hexes[key] = true
			state.seeds[#state.seeds + 1] = pos
		end
	end
	if map and type(map.MapForEach) == "function" then
		pcall(map.MapForEach, map, "map", "UndergroundPassageBase", add_seed)
		-- A map may contain only natural tunnel markers before their passage structure spawns.
		-- They are a safe fallback, but real underground passage structures remain preferred.
		if #state.seeds == 0 then
			pcall(map.MapForEach, map, "map", "SurfaceUndergroundTunnelMarker", add_seed)
		end
	end
	state.available = #state.seeds > 0 and state.method ~= "unavailable"
	Log("underground entrance reachability initialized", {
		map = tostring(map and map.name), seeds = #state.seeds, method = state.method,
		available = state.available, snap_radius = snap_radius,
	})
	ProfileStep("underground entrance reachability initialized", {
		seeds = #state.seeds, method = state.method, available = state.available,
	}, map)
	return state
end

local function IsReachableFromUndergroundEntrance(map, pt)
	local state = BuildUndergroundReachability(map)
	if not state or state.available ~= true or not pt then return false end
	local target = pt
	if type(pt.SetTerrainZ) == "function" then
		local ok_z, snapped = pcall(pt.SetTerrainZ, pt, map)
		if ok_z and snapped then target = snapped end
	end
	local world_to_hex = Global("WorldToHex")
	local key = tostring(target)
	if type(world_to_hex) == "function" then
		local ok_h, q, r = pcall(world_to_hex, target)
		if ok_h and type(q) == "number" and type(r) == "number" then
			key = tostring(q) .. ":" .. tostring(r)
		end
	end
	local cached = state.results[key]
	if cached ~= nil then return cached == true end
	state.checks = state.checks + 1
	local connectivity_check = Global("ConnectivityCheck")
	local pf_api = Global("pf")
	local reachable = false
	for _, seed in ipairs(state.seeds) do
		local ok, result
		if state.method == "ConnectivityCheck" and type(connectivity_check) == "function" then
			ok, result = pcall(connectivity_check, map, seed, target, 1, 0)
		elseif state.method == "pf.HasPosPath" and type(pf_api) == "table"
			and type(pf_api.HasPosPath) == "function" then
			ok, result = pcall(pf_api.HasPosPath, map, seed, target, 1)
		end
		if ok and result == true then
			reachable = true
			break
		elseif not ok then
			state.failures = state.failures + 1
		end
	end
	state.results[key] = reachable
	if reachable then state.reachable = state.reachable + 1 else state.rejected = state.rejected + 1 end
	return reachable
end

local function CanReceiveDeposit(map, pt)
	if not (PassableAt(map, pt) and (FlatnessAt(map, pt) or 0) >= FLATNESS_MIN) then
		return false
	end
	-- UNDERGROUND: only the cavern floor is real accessible terrain; the surrounding rock/
	-- void passes the passable+flat tests (the whole map is passable since the expansion
	-- zeroes PassBorder, and the void is uniformly flat) -- which put topped-up anomalies
	-- out in the black inaccessible area. Require the hex to be BUILDABLE (the game's own
	-- accessibility measure: hills/rock/void are unbuildable, the floor is buildable), so
	-- every top-up/respace/even-out pool samples only the playable floor. Surface pools are
	-- unchanged (vanilla surface deposits legitimately sit on rough terrain).
	if IsUndergroundMap(map) then
		if not IsBuildableAt(map, pt, true) then return false end
		if not IsReachableFromUndergroundEntrance(map, pt) then return false end
	end
	return true
end

local function SectorAtPoint(map, x, y)
	local city = map and map.City
	local get_sector = Global("GetMapSectorXY")
	if not city or type(get_sector) ~= "function" then
		return nil
	end
	local ok, sector = pcall(get_sector, city, x, y)
	if ok then
		return sector
	end
	return nil
end

local function SectorIsScanned(sector)
	return type(sector) == "table" and sector.status ~= "unexplored"
end

local function IsAnomalyMarker(obj)
	return obj ~= nil and IsKindOfSafe(obj, "SubsurfaceAnomalyMarker")
end

local function IsEnrichmentMarker(obj)
	return IsResourceDepositMarker(obj)
		or IsAnomalyMarker(obj)
		or IsKindOfSafe(obj, "EffectDepositMarker")
end

-- True for the N-sector-wide perimeter ring of the FINAL expanded map. This is the reserved
-- surface top-up ring: qualifying anomaly extras go here, while every other top-up family stays
-- out. Prefer the live sector's col/row; fall back to world-distance math when sector metadata is
-- unavailable. Vanilla-generated markers are never moved by this routing rule.
local function IsInFinalOuterSectorRing(map, x, y, ring_sectors)
	ring_sectors = math.max(0, math.floor(ring_sectors or 0))
	if ring_sectors <= 0 then return false end
	local city = map and map.City
	local sector = SectorAtPoint(map, x, y)
	local col, row = sector and sector.col, sector and sector.row
	local cols, rows = 0, 0
	if city and type(city.MapSectors) == "table" then
		while type(city.MapSectors[cols + 1]) == "table" do cols = cols + 1 end
		if cols > 0 then
			while city.MapSectors[1][rows + 1] ~= nil do rows = rows + 1 end
		end
	end
	if type(col) == "number" and type(row) == "number" and cols > 0 and rows > 0 then
		return col <= ring_sectors or row <= ring_sectors
			or col > cols - ring_sectors or row > rows - ring_sectors
	end
	local map_w, map_h = MapWorldSize(map)
	local get_step = Global("GetMapSectorTileSize")
	if map_w and map_h and type(get_step) == "function" then
		local ok_s, step = pcall(get_step, map)
		if ok_s and type(step) == "number" and step > 0 then
			local band = ring_sectors * step
			return x < band or y < band or x >= map_w - band or y >= map_h - band
		end
	end
	return false
end

-- Vanilla chooses enrichment positions from terrain masks with repulsion, so valid terrain area
-- naturally determines how much content a region can carry. A flat random draw from our post-gen
-- candidate pool loses the repulsion step and can repeatedly hit an already-dense sector. This
-- selector restores the missing geographic pressure without flattening legitimate resource
-- pockets: it minimizes current enrichment load / sampled eligible capacity, then randomizes
-- among exact ties. Capacity is recalculated for a requested terrain type when resource top-ups
-- preserve their source terrain. Surface edge-ring anomalies use their dedicated perimeter
-- scheduler and deliberately do not pass through this selector.
local function EnrichmentSectorKey(sector)
	if not sector then return nil end
	if sector.id ~= nil then return tostring(sector.id) end
	if type(sector.col) == "number" and type(sector.row) == "number" then
		return tostring(sector.col) .. ":" .. tostring(sector.row)
	end
	return nil
end

local function CandidateSector(map, candidate)
	if not candidate then return nil, nil end
	local sector = candidate.sector
	if not sector and type(candidate.x) == "number" and type(candidate.y) == "number" then
		sector = SectorAtPoint(map, candidate.x, candidate.y)
	end
	local key = EnrichmentSectorKey(sector)
	if key then
		candidate.sector = sector
		candidate.sector_key = key
		candidate.sector_id = candidate.sector_id or sector.id or key
	end
	return sector, key
end

local function BuildEnrichmentSectorLoads(map)
	local loads = {}
	if not map or type(map.MapForEach) ~= "function" then return loads end
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not IsEnrichmentMarker(marker) then return end
		local pos = ObjectPos(marker)
		if not pos or type(pos.xy) ~= "function" then return end
		local x, y = pos:xy()
		if type(x) ~= "number" or type(y) ~= "number" then return end
		local key = EnrichmentSectorKey(SectorAtPoint(map, x, y))
		if key then loads[key] = (loads[key] or 0) + 1 end
	end)
	return loads
end

local function NewSectorBalancedCandidateSelector(map, candidates, label)
	candidates = candidates or {}
	local balanced = cfg().TOPUP_SECTOR_BALANCED_PLACEMENT ~= false
	local loads = BuildEnrichmentSectorLoads(map)
	local capacity, capacity_by_terrain = {}, {}
	local remaining, eligible_sector_set, eligible_sectors = 0, {}, 0
	for _, candidate in ipairs(candidates) do
		if not candidate.used then
			local _, key = CandidateSector(map, candidate)
			if key then
				remaining = remaining + 1
				capacity[key] = (capacity[key] or 0) + 1
				if not eligible_sector_set[key] then
					eligible_sector_set[key] = true
					eligible_sectors = eligible_sectors + 1
				end
				local terrain_key = tostring(candidate.terrain_type)
				local by_sector = capacity_by_terrain[terrain_key]
				if not by_sector then by_sector = {}; capacity_by_terrain[terrain_key] = by_sector end
				by_sector[key] = (by_sector[key] or 0) + 1
			end
		end
	end
	local selected_count, selected_sector_set, selected_sectors = 0, {}, 0
	local additions_by_sector, max_additions_to_sector = {}, 0

	local function take(terrain_type)
		local terrain_key = terrain_type ~= nil and tostring(terrain_type) or nil
		local terrain_capacity = terrain_key and capacity_by_terrain[terrain_key] or nil
		local best, best_load, best_capacity = {}, nil, nil
		for _, candidate in ipairs(candidates) do
			if not candidate.used
				and (terrain_key == nil or tostring(candidate.terrain_type) == terrain_key) then
				local _, key = CandidateSector(map, candidate)
				local candidate_capacity = key and ((terrain_capacity and terrain_capacity[key]) or capacity[key]) or 0
				if key and candidate_capacity > 0 then
					local candidate_load = loads[key] or 0
					local better = not best_load
						or candidate_load * best_capacity < best_load * candidate_capacity
					local equal = best_load
						and candidate_load * best_capacity == best_load * candidate_capacity
					if not balanced then better, equal = best_load == nil, best_load ~= nil end
					if better then
						best = { candidate }
						best_load, best_capacity = candidate_load, candidate_capacity
					elseif equal then
						best[#best + 1] = candidate
					end
				end
			end
		end
		if #best == 0 then return nil end
		local candidate = best[RandInt(#best) + 1]
		candidate.used = true
		remaining = math.max(0, remaining - 1)
		return candidate
	end

	local function commit(candidate)
		if not candidate or candidate.sector_load_committed then return false end
		candidate.sector_load_committed = true
		local key = candidate.sector_key
		if key then
			loads[key] = (loads[key] or 0) + 1
			additions_by_sector[key] = (additions_by_sector[key] or 0) + 1
			max_additions_to_sector = math.max(max_additions_to_sector, additions_by_sector[key])
			if not selected_sector_set[key] then
				selected_sector_set[key] = true
				selected_sectors = selected_sectors + 1
			end
		end
		selected_count = selected_count + 1
		return true
	end

	local function stats()
		return {
			label = tostring(label or "top-up"), balanced = balanced,
			eligible_sectors = eligible_sectors, selected_sectors = selected_sectors,
			selected = selected_count, remaining_candidates = remaining,
			max_additions_to_one_sector = max_additions_to_sector,
		}
	end

	return { Take = take, Commit = commit, Remaining = function() return remaining end, Stats = stats }
end

-- How much higher the surrounding terrain is than this already-flat/buildable candidate.
-- Best-of-N random selection uses this only as a preference, keeping placement random while
-- favoring low pockets between mountains over isolated mountaintops.
local function ValleyScore(map, pt)
	local terrain_api = Global("terrain")
	local point = Global("point")
	if not (type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function"
		and type(point) == "function" and pt and type(pt.xy) == "function") then return 0 end
	local ok_c, center_z = pcall(terrain_api.GetHeight, map, pt)
	if not ok_c or type(center_z) ~= "number" then return 0 end
	local x, y = pt:xy()
	local const_tbl = Global("const")
	local hex = (type(const_tbl) == "table" and type(const_tbl.HexSize) == "number"
		and const_tbl.HexSize > 0) and const_tbl.HexSize or 1000
	local radius = 4 * hex
	local diagonal = math.floor(radius * 7 / 10)
	local offsets = {
		{ radius, 0 }, { -radius, 0 }, { 0, radius }, { 0, -radius },
		{ diagonal, diagonal }, { -diagonal, diagonal },
		{ diagonal, -diagonal }, { -diagonal, -diagonal },
	}
	local score = 0
	for _, o in ipairs(offsets) do
		local ok_h, z = pcall(terrain_api.GetHeight, map, point(x + o[1], y + o[2]))
		if ok_h and type(z) == "number" and z > center_z then score = score + (z - center_z) end
	end
	return score
end

local DepositRules = {}

-- ---------------------------------------------------------------------------------------
-- Badge collision prevention.
--
-- The overview "badges" are the world objects themselves: SubsurfaceDeposit (including
-- anomalies and effect deposits), TerrainDeposit, and SurfaceUndergroundTunnelSign. Moving a
-- spawned resource sign independently from its marker would desynchronise gameplay, so resolve
-- collisions while DepositMarker:FindSectorPos is choosing the final spawn position. Hidden,
-- unrevealed markers reserve their future badge hex too. Adjacent hexes are allowed; only an
-- identical hex is a collision.
-- ---------------------------------------------------------------------------------------
local BADGE_SPACING_PATCH_VERSION = 1
local BADGE_SEARCH_MAX_RADIUS = 64

local function BadgeSpacingEnabledOnMap(map)
	if not map then return false end
	if map.SuperBigMapExpanded == true then return true end
	local desired = map.SuperBigMapDesiredWidthTiles
	local generated = map.SuperBigMapGeneratorWidthTiles
	return type(desired) == "number" and type(generated) == "number" and desired > generated
end

local function IsBadgeMarker(obj)
	if obj == nil then return false end
	return IsKindOfSafe(obj, "SubsurfaceDepositMarker")
		or IsKindOfSafe(obj, "TerrainDepositMarker")
		or IsKindOfSafe(obj, "SubsurfaceAnomalyMarker")
		or IsKindOfSafe(obj, "EffectDepositMarker")
end

local function BadgeHexKey(q, r)
	if type(q) ~= "number" or type(r) ~= "number" then return nil end
	return tostring(q) .. ":" .. tostring(r)
end

local function BadgeObjectHex(obj)
	local world_to_hex = Global("WorldToHex")
	local pos = obj and ObjectPos(obj)
	if type(world_to_hex) ~= "function" or not pos then return nil end
	local ok, q, r = pcall(world_to_hex, pos)
	if not ok or type(q) ~= "number" or type(r) ~= "number" then return nil end
	return q, r, BadgeHexKey(q, r)
end

local function StampResolvedBadgeHex(marker, q, r)
	if not marker or type(q) ~= "number" or type(r) ~= "number" then return end
	marker.SuperBigMapBadgeResolvedQ = q
	marker.SuperBigMapBadgeResolvedR = r
	marker.SuperBigMapBadgeResolvedVersion = BADGE_SPACING_PATCH_VERSION
end

local function BuildBadgeOccupancy(map, ignore_marker, ignore_object, counts)
	counts = counts == true
	local occupied = {}
	local function reserve(obj)
		if not obj or obj == ignore_marker or obj == ignore_object then return end
		local _, _, key = BadgeObjectHex(obj)
		if not key then return end
		if counts then occupied[key] = (occupied[key] or 0) + 1 else occupied[key] = true end
	end
	if not map or type(map.MapForEach) ~= "function" then return occupied end
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if IsBadgeMarker(marker) and marker ~= ignore_marker then reserve(marker) end
	end)
	-- A normal spawned badge is represented by its marker above. Reserve only standalone live
	-- badges here, plus tunnel signs (whose tunnel marker is deliberately not a badge marker).
	local function reserve_standalone(obj)
		local marker = obj and obj.marker
		if marker and IsBadgeMarker(marker) then
			if marker == ignore_marker then return end
			return
		end
		reserve(obj)
	end
	pcall(map.MapForEach, map, "map", "SubsurfaceDeposit", reserve_standalone)
	pcall(map.MapForEach, map, "map", "TerrainDeposit", reserve_standalone)
	pcall(map.MapForEach, map, "map", "SurfaceUndergroundTunnelSign", reserve)
	return occupied
end

local function BadgeHexOccupied(occupied, q, r)
	local value = occupied and occupied[BadgeHexKey(q, r)]
	return type(value) == "number" and value > 0 or value == true
end

local function BadgeCandidateAllowed(marker, map, pt, x, y)
	if not CanReceiveDeposit(map, pt) or not IsUnobstructedAt(map, pt, true) then return false end
	local ring_sectors = math.max(0, math.floor(cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3))
	if not IsUndergroundMap(map) and ring_sectors > 0 then
		local in_ring = IsInFinalOuterSectorRing(map, x, y, ring_sectors)
		if marker.SuperBigMapEdgeTopUp and not in_ring then return false end
		if (marker.SuperBigMapResourceTopUp or marker.SuperBigMapEffectTopUp) and in_ring then return false end
	end
	-- These top-ups were explicitly required to use accessible, buildable ground.
	if (marker.SuperBigMapEdgeTopUp or marker.SuperBigMapEffectTopUp)
		and not IsBuildableAt(map, pt, true) then return false end
	return true
end

local function FindNearestFreeBadgePosition(marker, map, x, y, occupied)
	local point_fn = Global("point")
	local world_to_hex = Global("WorldToHex")
	local hex_to_world = Global("HexToWorld")
	if type(point_fn) ~= "function" or type(world_to_hex) ~= "function"
		or type(hex_to_world) ~= "function" then return nil, "hex APIs unavailable" end
	local ok_center, center_q, center_r = pcall(world_to_hex, point_fn(x, y))
	if not ok_center or type(center_q) ~= "number" or type(center_r) ~= "number" then
		return nil, "origin hex unavailable"
	end
	occupied = occupied or BuildBadgeOccupancy(map, marker, nil, false)
	if not BadgeHexOccupied(occupied, center_q, center_r) then return nil, "free" end
	local original_sector = SectorAtPoint(map, x, y)
	local map_w, map_h = MapWorldSize(map)
	for radius = 1, BADGE_SEARCH_MAX_RADIUS do
		local same_sector, nearest
		for dq = -radius, radius do
			for dr = -radius, radius do
				local distance = (math.abs(dq) + math.abs(dr) + math.abs(dq + dr)) / 2
				if distance == radius then
					local q, r = center_q + dq, center_r + dr
					if not BadgeHexOccupied(occupied, q, r) then
						local ok_world, cx, cy = pcall(hex_to_world, q, r)
						if ok_world and type(cx) == "number" and type(cy) == "number"
							and (type(map_w) ~= "number" or (cx >= 0 and cx < map_w))
							and (type(map_h) ~= "number" or (cy >= 0 and cy < map_h)) then
							local pt = point_fn(cx, cy)
							if BadgeCandidateAllowed(marker, map, pt, cx, cy) then
								if type(pt.SetTerrainZ) == "function" then
									local ok_z, snapped = pcall(pt.SetTerrainZ, pt, map)
									if ok_z and snapped then pt = snapped end
								end
								local candidate = { point = pt, x = cx, y = cy, q = q, r = r,
									radius = radius, sector = SectorAtPoint(map, cx, cy) }
								nearest = nearest or candidate
								if original_sector and candidate.sector == original_sector then
									same_sector = candidate
									break
								end
							end
						end
					end
				end
			end
			if same_sector then break end
		end
		if same_sector or nearest then return same_sector or nearest, "moved" end
	end
	return nil, "no free valid badge hex within search radius"
end

local function MoveBadgeMarker(marker, map, candidate, previous_sector)
	if not marker or not candidate or type(marker.SetPos) ~= "function" then return false end
	local ok = pcall(marker.SetPos, marker, candidate.point)
	if not ok then return false end
	local new_sector = candidate.sector
	if previous_sector and new_sector and previous_sector ~= new_sector then
		if type(previous_sector.UnregisterDeposit) == "function" then
			pcall(previous_sector.UnregisterDeposit, previous_sector, marker)
		end
		if type(new_sector.RegisterDeposit) == "function" then
			pcall(new_sector.RegisterDeposit, new_sector, marker)
		end
	end
	return true
end

local function PatchBadgeOverlapPrevention()
	local State = SuperBigMap.State or {}
	SuperBigMap.State = State
	local cls = Engine.ClassTable and Engine.ClassTable("DepositMarker")
	if type(cls) ~= "table" or type(cls.FindSectorPos) ~= "function" then return false end
	local current = cls.FindSectorPos
	if current == State.badge_spacing_find_sector_wrapper
		and type(State.badge_spacing_find_sector_original) == "function" then
		current = State.badge_spacing_find_sector_original
	end
	local original = current
	local wrapper = function(marker, ...)
		local sector, x, y, obstructed, moved = original(marker, ...)
		local map = marker and type(marker.GetMap) == "function" and SafeCall(marker.GetMap, marker) or nil
		if BadgeSpacingEnabledOnMap(map) and IsBadgeMarker(marker)
			and type(x) == "number" and type(y) == "number" then
			local world_to_hex = Global("WorldToHex")
			local point_fn = Global("point")
			local target_q, target_r
			if type(world_to_hex) == "function" and type(point_fn) == "function" then
				local ok_h, q, r = pcall(world_to_hex, point_fn(x, y))
				if ok_h then target_q, target_r = q, r end
			end
			local already_resolved = marker.SuperBigMapBadgeResolvedVersion == BADGE_SPACING_PATCH_VERSION
				and marker.SuperBigMapBadgeResolvedQ == target_q
				and marker.SuperBigMapBadgeResolvedR == target_r
			local candidate, reason
			if not already_resolved then
				candidate, reason = FindNearestFreeBadgePosition(marker, map, x, y)
			end
			if candidate and MoveBadgeMarker(marker, map, candidate, sector) then
				Log("overlapping badge marker moved to nearest free hex", {
					marker = tostring(marker), class = tostring(marker.class),
					from_x = x, from_y = y, to_x = candidate.x, to_y = candidate.y,
					hex_radius = candidate.radius, old_sector = tostring(sector and sector.id),
					new_sector = tostring(candidate.sector and candidate.sector.id),
				})
				StampResolvedBadgeHex(marker, candidate.q, candidate.r)
				sector, x, y, obstructed, moved = candidate.sector, candidate.x, candidate.y, false, true
			elseif not already_resolved and reason == "free" then
				StampResolvedBadgeHex(marker, target_q, target_r)
			elseif not already_resolved and reason ~= "free" and reason ~= "moved" then
				Log("overlapping badge marker could not be moved", {
					marker = tostring(marker), class = tostring(marker.class), x = x, y = y,
					reason = tostring(reason),
				})
			end
		end
		return sector, x, y, obstructed, moved
	end
	State.badge_spacing_find_sector_original = original
	State.badge_spacing_find_sector_wrapper = wrapper
	State.badge_spacing_patch_version = BADGE_SPACING_PATCH_VERSION
	cls.FindSectorPos = wrapper
	Log("badge overlap-prevention patch installed", { version = BADGE_SPACING_PATCH_VERSION })
	return true
end

local function RestoreBadgeOverlapPrevention()
	local State = SuperBigMap.State or {}
	local cls = Engine.ClassTable and Engine.ClassTable("DepositMarker")
	if type(cls) == "table" and cls.FindSectorPos == State.badge_spacing_find_sector_wrapper
		and type(State.badge_spacing_find_sector_original) == "function" then
		cls.FindSectorPos = State.badge_spacing_find_sector_original
	end
	State.badge_spacing_find_sector_original = nil
	State.badge_spacing_find_sector_wrapper = nil
	State.badge_spacing_patch_version = nil
end

function DepositRules.ResolveBadgeMarkerOverlaps(map, reason)
	if not ExpansionStepEnabled(16) then return 0 end
	map = map or Global("CurrentMap")
	if not BadgeSpacingEnabledOnMap(map) or type(map.MapForEach) ~= "function" then return 0, 0 end
	local markers = {}
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if marker and IsBadgeMarker(marker) then markers[#markers + 1] = marker end
	end)
	-- Start with fixed live badges. Unplaced markers are then claimed one at a time; the first
	-- claimant stays and only a later collision is moved.
	local occupied = {}
	local function reserve_object(obj)
		local _, _, key = BadgeObjectHex(obj)
		if key then occupied[key] = true end
	end
	pcall(map.MapForEach, map, "map", "SurfaceUndergroundTunnelSign", reserve_object)
	local function reserve_standalone(obj)
		if not (obj and obj.marker and IsBadgeMarker(obj.marker)) then reserve_object(obj) end
	end
	pcall(map.MapForEach, map, "map", "SubsurfaceDeposit", reserve_standalone)
	pcall(map.MapForEach, map, "map", "TerrainDeposit", reserve_standalone)
	for _, marker in ipairs(markers) do
		if marker.is_placed == true then reserve_object(marker) end
	end
	local moved, unresolved = 0, 0
	for _, marker in ipairs(markers) do
		if marker.is_placed ~= true then
			local pos = ObjectPos(marker)
			local x, y
			if pos and type(pos.xy) == "function" then x, y = pos:xy() end
			local q, r, key = BadgeObjectHex(marker)
			if key and BadgeHexOccupied(occupied, q, r) then
				local candidate, why = FindNearestFreeBadgePosition(marker, map, x, y, occupied)
				local old_sector = SectorAtPoint(map, x, y)
				if candidate and MoveBadgeMarker(marker, map, candidate, old_sector) then
					occupied[BadgeHexKey(candidate.q, candidate.r)] = true
					moved = moved + 1
					Log("pre-reveal badge collision resolved", {
						reason = tostring(reason), marker = tostring(marker), class = tostring(marker.class),
						from_x = x, from_y = y, to_x = candidate.x, to_y = candidate.y,
						hex_radius = candidate.radius,
					})
				else
					occupied[key] = true
					unresolved = unresolved + 1
					Log("pre-reveal badge collision unresolved", {
						reason = tostring(reason), marker = tostring(marker), class = tostring(marker.class),
						x = tostring(x), y = tostring(y), error = tostring(why),
					})
				end
			elseif key then
				occupied[key] = true
			end
		end
		local final_q, final_r = BadgeObjectHex(marker)
		StampResolvedBadgeHex(marker, final_q, final_r)
	end
	local final_counts = BuildBadgeOccupancy(map, nil, nil, true)
	local remaining_overlaps = 0
	for _, count in pairs(final_counts) do
		if type(count) == "number" and count > 1 then
			remaining_overlaps = remaining_overlaps + count - 1
		end
	end
	Log("badge overlap audit complete", {
		reason = tostring(reason), markers = #markers, moved = moved,
		search_failures = unresolved, remaining_overlaps = remaining_overlaps,
	})
	return moved, remaining_overlaps
end

function DepositRules.BuildBadgeOccupancy(map, ignore_marker, ignore_object)
	return BuildBadgeOccupancy(map, ignore_marker, ignore_object, false)
end

function DepositRules.BadgeHexOccupied(occupied, q, r)
	return BadgeHexOccupied(occupied, q, r)
end

function DepositRules.ApplyModBehavior()
	return PatchBadgeOverlapPrevention()
end

function DepositRules.RestoreVanillaBehavior()
	RestoreBadgeOverlapPrevention()
end

-- Called for every freshly-created expansion clone (no-op unless it is a scan-gated deposit).
function DepositRules.HideClone(obj)
	if not Enabled() then return end
	if not IsScanGatedDeposit(obj) then return end
	SetRevealedState(obj, false)
	Log("hid cloned deposit until scan", { class = obj.class })
end

-- Per-clone handling at clone time: just clear is_placed so a cloned RESOURCE deposit marker
-- will spawn its deposit (and paint concrete) when the frame sector is scanned (the source
-- marker may already be placed in a revealed starting sector). Reshuffle + registration are
-- done in dedicated passes AFTER all markers are cloned (see ReshuffleClonedMarkers).
function DepositRules.ProcessClone(_map, _source, clone)
	if IsResourceDepositMarker(clone) then
		clone.is_placed = false
	else
		-- defensive: if a spawned subsurface deposit/anomaly object ever gets cloned, hide it.
		DepositRules.HideClone(clone)
	end
end

-- ---------------------------------------------------------------------------------------
-- Concrete imprint moving.
-- The terrain copy mirrors the source quadrant's terrain TYPE grid, so every source concrete
-- patch (terrain types Regolith / Regolith_02 -- the yellow "concrete" texture) is duplicated
-- at the cloned marker's INITIAL (mirrored) position. Reshuffle then moves the concrete marker
-- elsewhere, so this pass moves that copied patch too: it flood-fills the contiguous regolith
-- blob on the type grid, clears the original cells to the dominant surrounding non-regolith
-- terrain type, and writes the same Regolith/Regolith_02 shape around the marker's final
-- position only when that final sector is already scanned. Unscanned sectors stay visually
-- clean until vanilla RevealDeposits calls TerrainDepositMarker:PlaceDeposit on scan.
-- Confirmed engine APIs (from the local game files, read-only): terrain.GetTypeGrid/SetTypeGrid
-- return/accept an editable type grid with :size()/:get(x,y)/:set(x,y,v) (same grid the mod
-- tiles in sbm_map_generation TileGrid); GetTerrainTextureIndex resolves a terrain type to its
-- grid index; terrain.InvalidateType refreshes the rendered texture.
-- MUST run inside the caller's PauseInfiniteLoopDetection scope (the flood fill is a hot loop).
-- ---------------------------------------------------------------------------------------
local function MoveConcreteImprints(map, moves)
	if cfg().CLEAR_INITIAL_CONCRETE_IMPRINT ~= true then return end
	if type(moves) ~= "table" or #moves == 0 then return end

	local terrain_api = Global("terrain")
	if type(terrain_api) ~= "table"
		or type(terrain_api.GetTypeGrid) ~= "function"
		or type(terrain_api.SetTypeGrid) ~= "function" then
		Log("concrete imprint move skipped", { reason = "terrain type-grid API unavailable" })
		return
	end

	local get_idx = Global("GetTerrainTextureIndex")
	if type(get_idx) ~= "function" then
		Log("concrete imprint move skipped", { reason = "GetTerrainTextureIndex unavailable" })
		return
	end
	local ok1, reg1 = pcall(get_idx, "Regolith")
	local ok2, reg2 = pcall(get_idx, "Regolith_02")
	reg1 = (ok1 and type(reg1) == "number") and reg1 or nil
	reg2 = (ok2 and type(reg2) == "number") and reg2 or nil
	if reg1 == nil and reg2 == nil then
		Log("concrete imprint move skipped", { reason = "regolith texture indices unavailable" })
		return
	end

	local grid = SafeCall(terrain_api.GetTypeGrid, map)
	if not grid or type(grid.get) ~= "function"
		or type(grid.set) ~= "function" or type(grid.size) ~= "function" then
		Log("concrete imprint move skipped", { reason = "type grid not editable" })
		return
	end
	local grid_w, grid_h = grid:size()
	if not grid_w or not grid_h or grid_w <= 0 or grid_h <= 0 then return end
	local map_w, map_h = MapWorldSize(map)
	if not map_w or not map_h or map_w <= 0 or map_h <= 0 then return end

	local function is_reg(v)
		return v ~= nil and (v == reg1 or v == reg2)
	end

	-- Regolith exists ONLY as a concrete-deposit patch (no natural regolith terrain), so a
	-- regolith blob is always one bounded concrete patch -- there is nothing to "protect" by
	-- capping the fill. CONCRETE_IMPRINT_MAX_TILES <= 0 means "no size limit": clear the whole
	-- patch regardless of size. We still pass the full grid-cell count as a hard ceiling so the
	-- flood fill can never loop without bound.
	local cfg_cap = math.floor(cfg().CONCRETE_IMPRINT_MAX_TILES or 0)
	local MAX_TILES = (cfg_cap > 0) and math.max(64, cfg_cap) or (grid_w * grid_h)
	local total_cleared, total_painted, postponed, blobs, skipped_large, clipped = 0, 0, 0, 0, 0, 0

	local function world_to_cell(p)
		if type(p) ~= "table" or type(p.x) ~= "number" or type(p.y) ~= "number" then
			return nil
		end
		return math.floor(p.x * grid_w / map_w), math.floor(p.y * grid_h / map_h)
	end

	local function find_regolith_seed(cx, cy)
		if cx < 0 or cy < 0 or cx >= grid_w or cy >= grid_h then return nil end
		if is_reg(grid:get(cx, cy)) then return cx, cy end
		for radius = 1, 3 do
			for y = cy - radius, cy + radius do
				for x = cx - radius, cx + radius do
					if x >= 0 and y >= 0 and x < grid_w and y < grid_h and is_reg(grid:get(x, y)) then
						return x, y
					end
				end
			end
		end
		return nil
	end

	-- 4-neighbour flood fill of the contiguous regolith blob whose seed cell is (sx,sy).
	-- Returns cells as x,y,value triples plus the dominant non-regolith boundary type used
	-- to clear the original imprint. Large/natural regolith areas are skipped by cap.
	local function collect_blob(sx, sy)
		local stack = { sx, sy }      -- flat (x,y) pairs to visit
		local cells = {}              -- flat (x,y,value) triples confirmed in the blob
		local seen = {}               -- cell key -> true
		local boundary = {}           -- non-regolith neighbour value -> count
		local aborted = false
		while #stack > 0 do
			local y = table.remove(stack)
			local x = table.remove(stack)
			local key = y * grid_w + x
			if not seen[key] then
				seen[key] = true
				local v = grid:get(x, y)
				if is_reg(v) then
					cells[#cells + 1] = x
					cells[#cells + 1] = y
					cells[#cells + 1] = v
					if (#cells / 3) > MAX_TILES then
						aborted = true
						break
					end
					if x > 0 then stack[#stack + 1] = x - 1; stack[#stack + 1] = y end
					if x < grid_w - 1 then stack[#stack + 1] = x + 1; stack[#stack + 1] = y end
					if y > 0 then stack[#stack + 1] = x; stack[#stack + 1] = y - 1 end
					if y < grid_h - 1 then stack[#stack + 1] = x; stack[#stack + 1] = y + 1 end
				else
					boundary[v] = (boundary[v] or 0) + 1
				end
			end
		end
		if aborted then
			skipped_large = skipped_large + 1
			return nil
		end
		local base, best = nil, -1
		for val, cnt in pairs(boundary) do
			if cnt > best then best = cnt; base = val end
		end
		if base == nil then return nil end   -- nothing non-regolith to blend into
		return cells, base
	end

	local planned = {}
	for _, move in ipairs(moves) do
		local from_x, from_y = world_to_cell(move.from)
		local to_x, to_y = world_to_cell(move.to)
		if from_x and to_x then
			local seed_x, seed_y = find_regolith_seed(from_x, from_y)
			local cells, base = nil, nil
			if seed_x then
				cells, base = collect_blob(seed_x, seed_y)
			end
			if cells and base ~= nil then
				planned[#planned + 1] = {
					cells = cells,
					base = base,
					seed_x = seed_x,
					seed_y = seed_y,
					to_x = to_x,
					to_y = to_y,
					paint_now = move.paint_now == true,
				}
				blobs = blobs + 1
			end
		end
	end

	for _, move in ipairs(planned) do
		local cells = move.cells
		local base = move.base
		for i = 1, #cells, 3 do
			grid:set(cells[i], cells[i + 1], base)
			total_cleared = total_cleared + 1
		end
	end

	for _, move in ipairs(planned) do
		local cells = move.cells
		local seed_x = move.seed_x
		local seed_y = move.seed_y
		local to_x = move.to_x
		local to_y = move.to_y
		if move.paint_now then
			for i = 1, #cells, 3 do
				local dx = cells[i] - seed_x
				local dy = cells[i + 1] - seed_y
				local x = to_x + dx
				local y = to_y + dy
				if x >= 0 and y >= 0 and x < grid_w and y < grid_h then
					grid:set(x, y, cells[i + 2])
					total_painted = total_painted + 1
				else
					clipped = clipped + 1
				end
			end
		else
			postponed = postponed + (#cells / 3)
		end
	end

	if total_cleared > 0 or total_painted > 0 then
		local ok, err = pcall(terrain_api.SetTypeGrid, map, { type_grid = grid, invalid_grid_type = 0 })
		if (not ok) or err then
			local ok2, err2 = pcall(terrain_api.SetTypeGrid, map, grid)
			if (not ok2) or err2 then
				Log("concrete imprint move failed", {
					err = tostring(err),
					err2 = tostring(err2),
				})
				return
			end
		end
		local box_fn = Global("box")
		if type(terrain_api.InvalidateType) == "function" and type(box_fn) == "function" then
			SafeCall(terrain_api.InvalidateType, map, box_fn(0, 0, map_w, map_h))
		elseif type(terrain_api.InvalidateType) == "function" then
			SafeCall(terrain_api.InvalidateType, map)
		end
	end

	Log("moved concrete imprints", {
		moves = #moves,
		blobs = blobs,
		cleared = total_cleared,
		painted = total_painted,
		postponed = postponed,
		skipped_large = skipped_large,
		clipped = clipped,
	})
end

-- Reshuffle pass: scatter the cloned resource-deposit markers across the expanded area onto
-- terrain SIMILAR to where each currently sits, instead of leaving them at the mirrored spot.
-- Build a pool of valid deposit tiles once (passable + flat enough), excluding the original
-- quadrant and a 2-tile margin from the map's outer edge; bucket the pool by terrain type;
-- then move each marker to a RANDOM tile from its own terrain-type bucket (removed so two
-- markers never share a tile). Runs BEFORE registration so markers register to their new sector.
function DepositRules.ReshuffleClonedMarkers(map)
	DepositRules.LogDistributionReport(map, "pre-reshuffle (post-generation + clone)")
	if not ReshuffleEnabled() then return end
	map = map or Global("CurrentMap")
	local point = Global("point")
	if not map or type(map.MapForEach) ~= "function" or type(point) ~= "function" then return end
	local map_w, map_h, tile = MapWorldSize(map)
	if not map_w or not tile then return end
	local margin_tiles = math.max(0, math.floor(cfg().DEPOSIT_EDGE_MARGIN_TILES or 4))
	local margin = margin_tiles * tile
	local src_w = (type(map.SuperBigMapSourceWidth) == "number") and map.SuperBigMapSourceWidth or 0
	local src_h = (type(map.SuperBigMapSourceHeight) == "number") and map.SuperBigMapSourceHeight or 0
	local lo_x, span_x = margin, (map_w - 2 * margin)
	local lo_y, span_y = margin, (map_h - 2 * margin)
	if span_x <= 0 or span_y <= 0 then return end

	local moved, considered = 0, 0
	local min_edge_tiles = false   -- diagnostic: closest any moved marker got to a map edge
	local concrete_moves = {}   -- moved concrete marker positions, used to move the terrain imprint
	RunPaused("SuperBigMapDepositReshuffle", function()
		-- 1) build the candidate pool (sampled), bucketed by terrain type.
		local buckets = {}
		local pool = 0
		local MAX_SAMPLES, MAX_POOL = 6000, 3000
		for _ = 1, MAX_SAMPLES do
			if pool >= MAX_POOL then break end
			local x = lo_x + RandInt(span_x)
			local y = lo_y + RandInt(span_y)
			-- Spread across the whole UNSCANNED map (source + frame), not just the frame: this
			-- avoids piling markers into the frame L-strip (one region ending far denser). Hidden
			-- markers still never land in the scanned start sector (they'd never reveal there).
			local sector = SectorAtPoint(map, x, y)
			if sector and not SectorIsScanned(sector) then
				local pt = point(x, y)
				if CanReceiveDeposit(map, pt) then
					local tt = TerrainTypeAt(map, pt) or -1
					local b = buckets[tt]
					if not b then b = {}; buckets[tt] = b end
					b[#b + 1] = { x = x, y = y }
					pool = pool + 1
				end
			end
		end

		-- Take + remove a random tile from a bucket (nil if empty).
		local function take(tt)
			local b = tt ~= nil and buckets[tt] or nil
			if b and #b > 0 then
				local idx = RandInt(#b) + 1
				local c = b[idx]
				table.remove(b, idx)
				return c
			end
			return nil
		end
		-- Take from ANY non-empty bucket (fallback when no same-type tile is left). Every pool
		-- tile already respects the edge margin, so this still keeps deposits off the border.
		local function take_any()
			for tt, b in pairs(buckets) do
				if #b > 0 then return take(tt) end
			end
			return nil
		end

		-- 2) move each cloned marker to a random tile of its own terrain type (else any valid
		-- tile). ALL pool tiles are >= margin from the edge, so no deposit ends up on the border.
		-- A resource marker is relocated if it's a quadrant clone OR if it (clone or vanilla
		-- original) currently sits within the edge margin. The original scenario quadrant lands
		-- in a map corner, so vanilla deposits near the original edge would otherwise hug the
		-- expanded map's outer border; this guarantees NO resource deposit -- cloned or original
		-- -- ends up within margin_tiles of the outer edge.
		pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
			if marker and IsResourceDepositMarker(marker) then
				local pos = ObjectPos(marker)
				local px, py
				if pos and type(pos.xy) == "function" then px, py = pos:xy() end
				local within_margin = px ~= nil and
					(px < margin or py < margin or px > (map_w - margin) or py > (map_h - margin))
				if not (marker.SuperBigMapQuadrantClone or within_margin) then return end
				considered = considered + 1
				local tt = pos and (TerrainTypeAt(map, pos) or -1) or nil
				local c = take(tt) or take_any()
				if c then
					local is_concrete = pos and type(pos.xy) == "function" and IsConcreteTerrainDepositMarker(marker)
					local ix, iy
					if is_concrete then
						ix, iy = pos:xy()
					end
					local pt = point(c.x, c.y)
					if type(pt.SetTerrainZ) == "function" then
						local ok, snapped = pcall(pt.SetTerrainZ, pt, map)
						if ok and snapped then pt = snapped end
					end
					if type(marker.SetPos) == "function" then
						local ok = pcall(marker.SetPos, marker, pt)
						if ok then
							moved = moved + 1
								-- diagnostic: closest any relocated marker got to a map edge (tiles).
								local edge_world = math.min(c.x, c.y, map_w - c.x, map_h - c.y)
								local edge_tiles = (tile > 0) and (edge_world / tile) or edge_world
								if not min_edge_tiles or edge_tiles < min_edge_tiles then min_edge_tiles = edge_tiles end
							if is_concrete then
								local tx, ty = c.x, c.y
								if type(pt.xy) == "function" then
									tx, ty = pt:xy()
								end
								local sector = SectorAtPoint(map, tx, ty)
								concrete_moves[#concrete_moves + 1] = {
									from = { x = ix, y = iy },
									to = { x = tx, y = ty },
									paint_now = SectorIsScanned(sector),
								}
							end
						end
					end
				end
			end
		end)

		-- Move concrete regolith imprints with reshuffled concrete markers
		-- (inside this same paused scope -- the flood fill is a hot loop).
		MoveConcreteImprints(map, concrete_moves)
	end)
	Log("reshuffled cloned deposit markers", {
		moved = moved,
		considered = considered,
		margin_tiles = margin_tiles,
		min_edge_tiles = min_edge_tiles or "n/a",   -- should be >= margin_tiles for every relocated marker
	})
end

-- After the expansion copy, register every cloned RESOURCE deposit marker with the map sector
-- it now sits in, so scanning that frame sector spawns the deposit (vanilla RevealDeposits
-- reads sector.markers, which is populated by sector:RegisterDeposit). Idempotent.
-- SURFACE ONLY: underground enrichments must not depend on sector mechanics (user directive)
-- -- there the unplaced clone markers are placed+revealed by the proximity DepositRevealer.
function DepositRules.RegisterClonedMarkers(map)
	if not ExpansionStepEnabled(18) then
		Log("register skipped", { reason = "expansion step 18 disabled" })
		return
	end
	map = map or Global("CurrentMap")
	if IsUndergroundMap(map) then
		Log("register skipped", { reason = "underground -- proximity reveal, no sector dependence" })
		return
	end
	if cfg().OPTIMIZE_TOPUP_PLACEMENT_POOLS == true
		and tostring(cfg().EXPANSION_FRAME_FILL_MODE or "mirror") == "stretch" then
		Log("register skipped", { reason = "stretch top-up clones registered at creation" })
		return
	end
	local city = map and map.City
	local get_sector = Global("GetMapSectorXY")
	if not city or type(map.MapForEach) ~= "function" or type(get_sector) ~= "function" then
		Log("register skipped", { city = city ~= nil })
		return
	end
	local count = 0
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if marker and marker.SuperBigMapQuadrantClone and IsResourceDepositMarker(marker) then
			local pos = ObjectPos(marker)
			if pos and type(pos.xy) == "function" then
				local x, y = pos:xy()
				local ok, sector = pcall(get_sector, city, x, y)
				if ok and sector and type(sector.RegisterDeposit) == "function" then
					pcall(sector.RegisterDeposit, sector, marker)
					count = count + 1
				end
			end
		end
	end)
	Log("registered cloned deposit markers with sectors", { count = count })
end

-- ---------------------------------------------------------------------------------------
-- Anomaly re-spacing (post-generation): on an expanded map the generator is forced to pack
-- anomalies ~20% tighter than vanilla so the full set (incl. all FreeTech) fits the shrunken
-- placement zone. Once the full 20x20 map is up there is room to spread them back out, so this
-- pass relocates the UNREVEALED anomaly markers to an even, vanilla-like spacing across the
-- whole playable map.
--
-- Safe because a subsurface anomaly marker spawns its anomaly only when its sector is scanned
-- (DepositMarker:PlaceDeposit); moving an unrevealed marker is fine. Scanning reveals anomalies
-- by iterating the sector's REGISTERED marker list (Exploration.lua MapSector:Scan ->
-- RevealDeposits over sector.markers.subsurface/deep), NOT by area -- so each moved marker is
-- UnregisterDeposit'd from its old sector and RegisterDeposit'd into the new one. Anomalies in
-- an already-scanned (start) sector, or already placed/revealed, are left untouched (live).
--
-- The minimum distance is derived from the anomaly count and the placeable area so the result
-- is an even spread that always fits (ANOMALY_EVEN_SPREAD_FACTOR tunes how spread). Gated by
-- RESPACE_ANOMALIES_TO_VANILLA. Idempotent enough to re-run (it just re-spaces again).
local function IsSubsurfaceAnomalyMarker(obj)
	return obj ~= nil and IsKindOfSafe(obj, "SubsurfaceAnomalyMarker")
end

-- Exhaustive distribution diagnostic (gated by DebugDeposits): bucket every enrichment marker
-- exactly once by family and sector, then report totals + which sectors are dense. This
-- is the evidence for "the landing spot is over-crowded on expanded maps": the SCANNED
-- (start) sector's marker count vs the per-sector average shows the overpacking, and the
-- top-density sectors reveal where the generator concentrated placement. Vanilla spreads the
-- preset count over the whole playable area; the expansion packs the same count into the
-- shrunken gen-zone (see sbm_rmg_placement borders-zeroed + spacing scale), and the scanned
-- start sector's markers are never thinned (respace/reshuffle skip revealed sectors).
function DepositRules.LogDistributionReport(map, phase)
	local DebugLog = SuperBigMap.DebugLog
	if not (DebugLog and DebugLog.On and DebugLog.On("Deposits")) then return end
	map = map or Global("CurrentMap")
	if not map or type(map.MapForEach) ~= "function" then return end

	local map_w, map_h = MapWorldSize(map)
	local src_w = (type(map.SuperBigMapSourceWidth) == "number") and map.SuperBigMapSourceWidth or 0
	local src_h = (type(map.SuperBigMapSourceHeight) == "number") and map.SuperBigMapSourceHeight or 0
	local region_source, region_frame = 0, 0   -- markers inside the source quadrant vs the frame L

	local per_sector, order = {}, {}
	local function bucket(kind, marker)
		local pos = ObjectPos(marker)
		if not pos or type(pos.xy) ~= "function" then return end
		local px, py = pos:xy()
		if px == nil then return end
		if src_w > 0 and src_h > 0 and px < src_w and py < src_h then
			region_source = region_source + 1
		else
			region_frame = region_frame + 1
		end
		local sector = SectorAtPoint(map, px, py)
		local name = tostring((type(sector) == "table" and (sector.display_name or sector.id)) or "offgrid")
		local rec = per_sector[name]
		if not rec then
			rec = { resource = 0, anom = 0, effect = 0, scanned = SectorIsScanned(sector) }
			per_sector[name] = rec
			order[#order + 1] = name
		end
		rec[kind] = rec[kind] + 1
	end

	local total_resource, total_anom, total_effect = 0, 0, 0
	pcall(map.MapForEach, map, "map", "DepositMarker", function(m)
		if IsResourceDepositMarker(m) then
			total_resource = total_resource + 1
			bucket("resource", m)
		elseif IsAnomalyMarker(m) then
			total_anom = total_anom + 1
			bucket("anom", m)
		elseif IsKindOfSafe(m, "EffectDepositMarker") then
			total_effect = total_effect + 1
			bucket("effect", m)
		end
	end)

	local sectors_with, scanned_sectors = 0, 0
	local scanned_resource, scanned_anom, scanned_effect = 0, 0, 0
	local scanned_detail = {}
	for _, name in ipairs(order) do
		local rec = per_sector[name]
		sectors_with = sectors_with + 1
		if rec.scanned then
			scanned_sectors = scanned_sectors + 1
			scanned_resource = scanned_resource + rec.resource
			scanned_anom = scanned_anom + rec.anom
			scanned_effect = scanned_effect + rec.effect
			scanned_detail[#scanned_detail + 1] = string.format("%s[r%d/a%d/e%d]",
				name, rec.resource, rec.anom, rec.effect)
		end
	end

	table.sort(order, function(a, b)
		local ra, rb = per_sector[a], per_sector[b]
		return (ra.resource + ra.anom + ra.effect) > (rb.resource + rb.anom + rb.effect)
	end)
	local top = {}
	for i = 1, math.min(#order, 12) do
		local name = order[i]
		local rec = per_sector[name]
		local total = rec.resource + rec.anom + rec.effect
		top[#top + 1] = string.format("%s%s=%d(r%d/a%d/e%d)", name,
			rec.scanned and "*" or "", total, rec.resource, rec.anom, rec.effect)
	end

	local total_markers = total_resource + total_anom + total_effect
	local avg = (sectors_with > 0) and string.format("%.2f", total_markers / sectors_with) or "n/a"
	Log("DISTRIBUTION [" .. tostring(phase) .. "] summary", {
		total_resources = total_resource,
		total_anomalies = total_anom,
		total_effects = total_effect,
		total_markers = total_markers,
		sectors_with_markers = sectors_with,
		avg_markers_per_occupied_sector = avg,
		scanned_sectors = scanned_sectors,
		scanned_resources = scanned_resource,
		scanned_anomalies = scanned_anom,
		scanned_effects = scanned_effect,
		scanned_detail = table.concat(scanned_detail, " "),
	})
	Log("DISTRIBUTION [" .. tostring(phase) .. "] top density (name*=scanned; =total(rResources/aAnomalies/eEffects))", {
		top = table.concat(top, " "),
	})
	-- Coarse raw-area regional check only. The reserved surface ring and inaccessible underground
	-- rock mean this ratio is not expected to equal 1; placement selectors log eligible-capacity
	-- sector coverage separately.
	local src_area = src_w * src_h
	local total_area = (map_w or 0) * (map_h or 0)
	local frame_area = total_area - src_area
	local dens_source = (src_area > 0) and (region_source * 1000000.0 / src_area) or 0
	local dens_frame = (frame_area > 0) and (region_frame * 1000000.0 / frame_area) or 0
	Log("DISTRIBUTION [" .. tostring(phase) .. "] region density (frame L vs source quadrant, markers/Mwu^2)", {
		source_markers = region_source,
		frame_markers = region_frame,
		density_source = string.format("%.3f", dens_source),
		density_frame = string.format("%.3f", dens_frame),
		frame_over_source_ratio = (dens_source > 0) and string.format("%.2f", dens_frame / dens_source) or "n/a",
	})
end

local function ResourceDepositLayer(marker)
	if marker ~= nil and IsKindOfSafe(marker, "SurfaceDepositMarker") then return "surf" end
	if marker ~= nil and IsKindOfSafe(marker, "SubsurfaceDepositMarker") then return "subs" end
	if marker ~= nil and IsKindOfSafe(marker, "TerrainDepositMarker") then return "terr" end
	return nil
end

local function RepulsionValuesAreValid(values)
	return type(values) == "table"
		and type(values.repulse_same) == "number" and values.repulse_same >= 0
		and type(values.repulse_layer) == "number" and values.repulse_layer >= 0
		and type(values.repulse_all) == "number" and values.repulse_all >= 0
end

local function FindResourceRepulsionValues(map, resource)
	local captured = map and map.SuperBigMapVanillaRepulsionProfiles
	local values = type(captured) == "table" and type(captured.resources) == "table"
		and captured.resources[resource] or nil
	if RepulsionValuesAreValid(values) then return values end

	-- Compatibility fallback for maps generated before the capture field existed or for a
	-- custom resource added after GenerateResourceInfo. Resolve the preset selected by this
	-- generator, then read the restored authored values from Presets.
	local generator = map and map.RandomMapGenObject
	local preset_id = map and type(map.SuperBigMapResourcePresetByResource) == "table"
		and map.SuperBigMapResourcePresetByResource[resource] or nil
	if (preset_id == nil or preset_id == "") and type(generator) == "table" then
		preset_id = generator["ResPreset_" .. tostring(resource)]
	end
	local presets = Global("Presets")
	local list = type(presets) == "table" and presets.ResourcePreset
		and presets.ResourcePreset.Default or nil
	if type(list) == "table" and preset_id ~= nil and preset_id ~= "" then
		for _, preset in pairs(list) do
			if type(preset) == "table" and preset.id == preset_id then
				values = {
					preset = preset_id,
					repulse_same = preset.RepulseSame,
					repulse_layer = preset.RepulseSameLayer,
					repulse_all = preset.RepulseAll,
				}
				if RepulsionValuesAreValid(values) then return values end
			end
		end
	end
	return nil
end

local function GeneratorFamilyRepulsionValues(map, family)
	local captured = map and map.SuperBigMapVanillaRepulsionProfiles
	local values = type(captured) == "table" and captured[family] or nil
	if RepulsionValuesAreValid(values) then return values end
	local generator = map and map.RandomMapGenObject
	if type(generator) ~= "table" then return nil end
	if family == "Anomaly" then
		values = {
			repulse_same = generator.AnomalySpacing,
			repulse_layer = generator.AnomalyRepulseSubs,
			repulse_all = generator.AnomalyRepulseAll,
		}
	elseif family == "Effects" then
		values = {
			repulse_same = generator.EffectDepSpacing,
			repulse_layer = generator.EffectDepRepulse,
			repulse_all = generator.EffectDepRepulseAll,
		}
	end
	return RepulsionValuesAreValid(values) and values or nil
end

local function VanillaRepulsionProfileForMarker(map, marker)
	local layer, resource, values
	if IsResourceDepositMarker(marker) then
		layer = ResourceDepositLayer(marker)
		resource = marker and marker.resource
		values = type(resource) == "string" and FindResourceRepulsionValues(map, resource) or nil
	elseif IsAnomalyMarker(marker) then
		layer, resource = "subs", "Anomaly"
		values = GeneratorFamilyRepulsionValues(map, resource)
	elseif marker ~= nil and IsKindOfSafe(marker, "EffectDepositMarker") then
		layer, resource = "surf", "Effects"
		values = GeneratorFamilyRepulsionValues(map, resource)
	end
	if not layer or not resource or not RepulsionValuesAreValid(values) then return nil end
	return {
		layer = layer, resource = tostring(resource), preset = values.preset,
		repulse_same = values.repulse_same,
		repulse_layer = values.repulse_layer,
		repulse_all = values.repulse_all,
	}
end

local function PairRepulsionRadius(a, b)
	if not a or not b then return nil end
	if a.layer ~= b.layer then return a.repulse_all + b.repulse_all end
	if a.resource ~= b.resource then return a.repulse_layer + b.repulse_layer end
	return a.repulse_same + b.repulse_same
end

function DepositRules.LogEnrichmentPositionCensus(map, phase, capture_pre_stretch)
	local phase_text = tostring(phase or "")
	local controlling_step = capture_pre_stretch == true and 4
		or (string.find(phase_text, "final", 1, true) and 19 or 8)
	if not ExpansionStepEnabled(controlling_step) then return 0 end
	local DebugLog = SuperBigMap.DebugLog
	if not (DebugLog and type(DebugLog.On) == "function"
		and DebugLog.On("EnrichmentPositionsExhaustive") == true) then return 0 end
	map = map or Global("CurrentMap")
	if not map or type(map.MapForEach) ~= "function" then return 0 end
	local world_to_hex = Global("WorldToHex")
	local xxhash = Global("xxhash")
	local map_w, map_h = MapWorldSize(map)
	local source_w = tonumber(map.SuperBigMapSourceWidth) or 0
	local source_h = tonumber(map.SuperBigMapSourceHeight) or 0
	local generator_tiles = tonumber(map.SuperBigMapGeneratorWidthTiles)
	local desired_tiles = tonumber(map.SuperBigMapDesiredWidthTiles)
	local scale = generator_tiles and generator_tiles > 0 and desired_tiles
		and (desired_tiles + 0.0) / generator_tiles or nil

	local function marker_origin(marker)
		if marker.SuperBigMapBreakthroughRepair == true then return "breakthrough_repair" end
		if marker.SuperBigMapResourceTopUp == true then return "resource_topup" end
		if marker.SuperBigMapAnomalyTopUp == true then return "ordinary_anomaly_topup" end
		if marker.SuperBigMapEffectTopUp == true then return "effect_topup" end
		if marker.SuperBigMapQuadrantClone == true then return "mirror_clone" end
		return "native_generated"
	end

	local function marker_subtype(marker, profile)
		if profile and profile.resource == "Anomaly" then
			if marker.tech_action and marker.tech_action ~= "" then return tostring(marker.tech_action) end
			if marker.sequence and marker.sequence ~= "" then return "sequence:" .. tostring(marker.sequence) end
			return "ordinary"
		end
		if profile and profile.resource == "Effects" then return tostring(marker.deposit_type or "?") end
		return tostring(marker.resource or marker.class or "?")
	end

	local entries = {}
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not IsEnrichmentMarker(marker) then return end
		local pos = ObjectPos(marker)
		if not (pos and type(pos.xy) == "function") then return end
		local x, y = pos:xy()
		if type(x) ~= "number" or type(y) ~= "number" then return end
		local z
		if type(pos.z) == "function" then
			local ok_z, value = pcall(pos.z, pos)
			if ok_z then z = value end
		end
		local profile = VanillaRepulsionProfileForMarker(map, marker)
		local origin = marker_origin(marker)
		local position_hash
		if type(xxhash) == "function" then
			local ok_hash, value = pcall(xxhash, pos)
			if ok_hash then position_hash = value end
		end
		if capture_pre_stretch == true then
			marker.SuperBigMapDebugPreStretchX = x
			marker.SuperBigMapDebugPreStretchY = y
			marker.SuperBigMapDebugPreStretchZ = z
			marker.SuperBigMapDebugPreStretchHash = position_hash
		end
		local pre_x, pre_y, pre_z, pre_hash
		-- A cloned top-up can inherit debug fields from its template. They describe the template,
		-- not the clone, so expose the correlation only for the original native handle.
		if origin == "native_generated" then
			pre_x = marker.SuperBigMapDebugPreStretchX
			pre_y = marker.SuperBigMapDebugPreStretchY
			pre_z = marker.SuperBigMapDebugPreStretchZ
			pre_hash = marker.SuperBigMapDebugPreStretchHash
		end
		local expected_x = type(pre_x) == "number" and scale
			and math.floor(pre_x * scale + 0.5) or nil
		local expected_y = type(pre_y) == "number" and scale
			and math.floor(pre_y * scale + 0.5) or nil
		local q, r
		if type(world_to_hex) == "function" then
			local ok_hex, hq, hr = pcall(world_to_hex, pos)
			if ok_hex then q, r = hq, hr end
		end
		local sector = SectorAtPoint(map, x, y)
		entries[#entries + 1] = {
			marker = marker, pos = pos, x = x, y = y, z = z, q = q, r = r,
			position_hash = position_hash, profile = profile, origin = origin,
			subtype = marker_subtype(marker, profile), sector = sector,
			pre_x = pre_x, pre_y = pre_y, pre_z = pre_z, pre_hash = pre_hash,
			expected_x = expected_x, expected_y = expected_y,
		}
	end)

	table.sort(entries, function(a, b)
		local ar, br = tonumber(a.sector and a.sector.row) or 9999,
			tonumber(b.sector and b.sector.row) or 9999
		if ar ~= br then return ar < br end
		local ac, bc = tonumber(a.sector and a.sector.col) or 9999,
			tonumber(b.sector and b.sector.col) or 9999
		if ac ~= bc then return ac < bc end
		if a.y ~= b.y then return a.y < b.y end
		if a.x ~= b.x then return a.x < b.x end
		return tostring(a.marker.handle or a.marker) < tostring(b.marker.handle or b.marker)
	end)

	local by_origin, by_sector, by_family = {}, {}, {}
	local world_counts, hex_counts = {}, {}
	local repulsion_violations = 0
	for _, entry in ipairs(entries) do
		by_origin[entry.origin] = (by_origin[entry.origin] or 0) + 1
		local sector_name = tostring(entry.sector
			and (entry.sector.display_name or entry.sector.id) or "offgrid")
		by_sector[sector_name] = (by_sector[sector_name] or 0) + 1
		local family = entry.profile and (entry.profile.layer .. "/" .. entry.profile.resource) or "unknown"
		by_family[family] = (by_family[family] or 0) + 1
		local world_key = tostring(entry.x) .. ":" .. tostring(entry.y)
		world_counts[world_key] = (world_counts[world_key] or 0) + 1
		if type(entry.q) == "number" and type(entry.r) == "number" then
			local hex_key = tostring(entry.q) .. ":" .. tostring(entry.r)
			hex_counts[hex_key] = (hex_counts[hex_key] or 0) + 1
		end
	end
	for i = 1, #entries - 1 do
		local a = entries[i]
		for j = i + 1, #entries do
			local b = entries[j]
			if a.profile and b.profile then
				local radius = PairRepulsionRadius(a.profile, b.profile)
				local dx, dy = a.x - b.x, a.y - b.y
				local distance_sq = dx * dx + dy * dy
				if (radius == 0 and distance_sq == 0)
					or (radius > 0 and distance_sq <= radius * radius) then
					repulsion_violations = repulsion_violations + 1
				end
			end
		end
	end

	local function tally_string(tally)
		local keys, parts = {}, {}
		for key in pairs(tally) do keys[#keys + 1] = key end
		table.sort(keys)
		for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. "=" .. tostring(tally[key]) end
		return table.concat(parts, " ")
	end
	local duplicate_world, duplicate_hex = 0, 0
	for _, count in pairs(world_counts) do if count > 1 then duplicate_world = duplicate_world + count - 1 end end
	for _, count in pairs(hex_counts) do if count > 1 then duplicate_hex = duplicate_hex + count - 1 end end
	DebugLog.Info("EnrichmentPositionsExhaustive", "BEGIN enrichment marker position census", {
		phase = tostring(phase), map = tostring(map.name), environment = tostring(map.mapdata and map.mapdata.Environment),
		markers = #entries, capture_pre_stretch = tostring(capture_pre_stretch == true),
		stretch_scale = tostring(scale), map_w = tostring(map_w), map_h = tostring(map_h),
		by_origin = tally_string(by_origin), by_family = tally_string(by_family),
	})

	for index, entry in ipairs(entries) do
		local nearest, nearest_distance
		local nearest_same, nearest_same_distance
		local tightest, tightest_distance, tightest_required, tightest_clearance
		for other_index, other in ipairs(entries) do
			if other_index ~= index then
				local dx, dy = entry.x - other.x, entry.y - other.y
				local distance = math.sqrt(dx * dx + dy * dy)
				if nearest_distance == nil or distance < nearest_distance then
					nearest, nearest_distance = other, distance
				end
				if entry.profile and other.profile
					and entry.profile.layer == other.profile.layer
					and entry.profile.resource == other.profile.resource
					and (nearest_same_distance == nil or distance < nearest_same_distance) then
					nearest_same, nearest_same_distance = other, distance
				end
				if entry.profile and other.profile then
					local required = PairRepulsionRadius(entry.profile, other.profile)
					local clearance = distance - required
					if tightest_clearance == nil or clearance < tightest_clearance then
						tightest, tightest_distance, tightest_required, tightest_clearance =
							other, distance, required, clearance
					end
				end
			end
		end
		local sector = entry.sector
		local nearest_profile = nearest and nearest.profile
		local same_profile = nearest_same and nearest_same.profile
		local tight_profile = tightest and tightest.profile
		DebugLog.Info("EnrichmentPositionsExhaustive", "enrichment marker position", {
			phase = tostring(phase), index = index, handle = tostring(entry.marker.handle or entry.marker),
			class = tostring(entry.marker.class), origin = entry.origin,
			layer = tostring(entry.profile and entry.profile.layer),
			family = tostring(entry.profile and entry.profile.resource), subtype = entry.subtype,
			x = entry.x, y = entry.y, z = tostring(entry.z), position_hash = tostring(entry.position_hash),
			q = tostring(entry.q), r = tostring(entry.r), hex = tostring(entry.q) .. ":" .. tostring(entry.r),
			sector = tostring(sector and (sector.display_name or sector.id)), sector_id = tostring(sector and sector.id),
			sector_col = tostring(sector and sector.col), sector_row = tostring(sector and sector.row),
			sector_status = tostring(sector and sector.status),
			in_source_region = tostring(source_w > 0 and source_h > 0
				and entry.x < source_w and entry.y < source_h),
			in_outer_ring = tostring(IsInFinalOuterSectorRing(map, entry.x, entry.y,
				cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3)),
			pre_stretch_x = tostring(entry.pre_x), pre_stretch_y = tostring(entry.pre_y),
			pre_stretch_z = tostring(entry.pre_z), pre_stretch_hash = tostring(entry.pre_hash),
			expected_stretched_x = tostring(entry.expected_x), expected_stretched_y = tostring(entry.expected_y),
			stretch_delta_x = tostring(entry.expected_x and (entry.x - entry.expected_x)),
			stretch_delta_y = tostring(entry.expected_y and (entry.y - entry.expected_y)),
			repulse_same = tostring(entry.profile and entry.profile.repulse_same),
			repulse_layer = tostring(entry.profile and entry.profile.repulse_layer),
			repulse_all = tostring(entry.profile and entry.profile.repulse_all),
			is_placed = tostring(entry.marker.is_placed), revealed = tostring(entry.marker.revealed),
			depth_layer = tostring(entry.marker.depth_layer), tech_action = tostring(entry.marker.tech_action),
			sequence = tostring(entry.marker.sequence), deposit_type = tostring(entry.marker.deposit_type),
			nearest_handle = tostring(nearest and (nearest.marker.handle or nearest.marker)),
			nearest_class = tostring(nearest and nearest.marker.class),
			nearest_origin = tostring(nearest and nearest.origin),
			nearest_family = tostring(nearest_profile and (nearest_profile.layer .. "/" .. nearest_profile.resource)),
			nearest_x = tostring(nearest and nearest.x), nearest_y = tostring(nearest and nearest.y),
			nearest_distance = tostring(nearest_distance),
			nearest_same_handle = tostring(nearest_same and (nearest_same.marker.handle or nearest_same.marker)),
			nearest_same_family = tostring(same_profile and (same_profile.layer .. "/" .. same_profile.resource)),
			nearest_same_distance = tostring(nearest_same_distance),
			tightest_repulsion_handle = tostring(tightest and (tightest.marker.handle or tightest.marker)),
			tightest_repulsion_family = tostring(tight_profile and (tight_profile.layer .. "/" .. tight_profile.resource)),
			tightest_repulsion_distance = tostring(tightest_distance),
			tightest_repulsion_required = tostring(tightest_required),
			tightest_repulsion_clearance = tostring(tightest_clearance),
			tightest_repulsion_violation = tostring(type(tightest_clearance) == "number" and tightest_clearance <= 0),
		})
	end
	DebugLog.Info("EnrichmentPositionsExhaustive", "END enrichment marker position census", {
		phase = tostring(phase), map = tostring(map.name), markers = #entries,
		by_origin = tally_string(by_origin), by_family = tally_string(by_family),
		by_sector = tally_string(by_sector), duplicate_world = duplicate_world,
		duplicate_hex = duplicate_hex, all_pair_repulsion_violations = repulsion_violations,
	})
	return #entries
end


function DepositRules.RespaceAnomalies(map)
	if cfg().RESPACE_ANOMALIES_TO_VANILLA ~= true then return end
	-- STRETCH mode: skip (user decision 2026-07-12). This pass repairs the MIRROR path's
	-- crammed distribution; in stretch the vanilla layout x4/3 is already vanilla-like, so
	-- respacing only moved VANILLA anomalies away from their vanilla-equivalent positions.
	-- The distribution model is now: vanilla markers exactly at scaled positions, only the
	-- top-up extras placed pseudo-randomly.
	if tostring(cfg().EXPANSION_FRAME_FILL_MODE or "mirror") == "stretch" then
		Log("anomaly respace skipped (stretch mode: vanilla markers stay at scaled positions)")
		return
	end
	map = map or Global("CurrentMap")
	local point = Global("point")
	local city = map and map.City
	if not map or type(map.MapForEach) ~= "function" or type(point) ~= "function" or not city then
		Log("anomaly respace skipped", { reason = "map/city/point unavailable" })
		return
	end
	local map_w, map_h, tile = MapWorldSize(map)
	if not map_w or not map_h or not tile or tile <= 0 then
		Log("anomaly respace skipped", { reason = "map size unavailable" })
		return
	end
	local margin_tiles = math.max(0, math.floor(cfg().DEPOSIT_EDGE_MARGIN_TILES or 4))
	local margin = margin_tiles * tile
	local lo_x, span_x = margin, (map_w - 2 * margin)
	local lo_y, span_y = margin, (map_h - 2 * margin)
	if span_x <= 0 or span_y <= 0 then
		Log("anomaly respace skipped", { reason = "placeable span <= 0" })
		return
	end

	local moved, considered, kept, unplaced = 0, 0, 0, 0
	local min_dist_used = 0
	RunPaused("SuperBigMapAnomalyRespace", function()
		-- Candidate pool: valid (passable + flat) tiles sampled across the full map minus margin.
		local pool = {}
		local MAX_SAMPLES, MAX_POOL = 8000, 4000
		for _ = 1, MAX_SAMPLES do
			if #pool >= MAX_POOL then break end
			local x = lo_x + RandInt(span_x)
			local y = lo_y + RandInt(span_y)
			local pt = point(x, y)
			if CanReceiveDeposit(map, pt) then
				pool[#pool + 1] = { x = x, y = y }
			end
		end

		-- Pass 1: classify every anomaly marker. Live ones (placed, or in a scanned/start sector)
		-- are KEPT in place and only seed the spacing list so moved ones avoid them.
		local placed = {}
		local to_move = {}
		local move_revealed = cfg().EVEN_OUT_START_SECTOR_ANOMALIES ~= false
		pcall(map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(marker)
			if not IsSubsurfaceAnomalyMarker(marker) then return end
			local pos = ObjectPos(marker)
			local px, py
			if pos and type(pos.xy) == "function" then px, py = pos:xy() end
			if px == nil then return end
			local sector = SectorAtPoint(map, px, py)
			local revealed = marker.is_placed == true or SectorIsScanned(sector)
			if marker.tech_action == "breakthrough" then
				-- Breakthroughs have their own vanilla farthest-point selector. They are rare and
				-- must remain fixed; ordinary anomalies still use them as spacing anchors.
				placed[#placed + 1] = { x = px, y = py }
				kept = kept + 1
			elseif revealed and not move_revealed then
				-- Keep live/revealed anomalies fixed (vanilla behavior); they seed the spacing.
				placed[#placed + 1] = { x = px, y = py }
				kept = kept + 1
			else
				-- Move it. `was_revealed` items are despawned + re-hidden in Pass 2 so a
				-- start-sector anomaly re-spawns vanilla-style when its new sector is scanned.
				to_move[#to_move + 1] = { marker = marker, px = px, py = py, sector = sector, was_revealed = revealed }
			end
		end)

		-- Even-spread minimum distance: factor * sqrt(placeable_area / total). <=1 factor keeps it
		-- fitting by construction; the pass degrades gracefully (leaves a marker put) if a tile
		-- far enough can't be found.
		local total = #to_move + #placed
		local factor = cfg().ANOMALY_EVEN_SPREAD_FACTOR
		factor = (type(factor) == "number" and factor > 0 and factor <= 1.5) and factor or 0.6
		local min_dist = (total > 0) and (factor * math.sqrt((span_x * span_y) / total)) or tile
		if min_dist < tile then min_dist = tile end
		min_dist_used = min_dist
		local min_dist_sq = min_dist * min_dist

		local function too_close(x, y)
			for i = 1, #placed do
				local p = placed[i]
				local dx, dy = x - p.x, y - p.y
				if dx * dx + dy * dy < min_dist_sq then return true end
			end
			return false
		end

		-- Pass 2: relocate each movable marker to a pool tile >= min_dist from everything placed.
		for _, item in ipairs(to_move) do
			considered = considered + 1
			local marker = item.marker
			local chosen, chosen_idx, attempts = nil, nil, 0
			while #pool > 0 and attempts < 32 do
				attempts = attempts + 1
				local idx = RandInt(#pool) + 1
				local c = pool[idx]
				if not too_close(c.x, c.y) then chosen, chosen_idx = c, idx; break end
			end
			if chosen then
				table.remove(pool, chosen_idx)
				local pt = point(chosen.x, chosen.y)
				if type(pt.SetTerrainZ) == "function" then
					local ok, snapped = pcall(pt.SetTerrainZ, pt, map)
					if ok and snapped then pt = snapped end
				end
				local nx, ny = chosen.x, chosen.y
				if type(pt.xy) == "function" then nx, ny = pt:xy() end
				-- Unregister from old sector, move, register into the new sector.
				if item.sector and type(item.sector.UnregisterDeposit) == "function" then
					pcall(item.sector.UnregisterDeposit, item.sector, marker)
				end
				-- Revealed (start-sector) anomaly: despawn its spawned object and reset to unplaced
				-- + hidden, so it re-spawns vanilla-style when its new (frame) sector is scanned.
				if item.was_revealed then
					local IsValid = Global("IsValid")
					local DoneObject = Global("DoneObject")
					if IsValid and IsValid(marker.placed_obj) and DoneObject then pcall(DoneObject, marker.placed_obj) end
					marker.placed_obj = false
					marker.is_placed = false
					SetRevealedState(marker, false)
				end
				local ok_move = type(marker.SetPos) == "function" and pcall(marker.SetPos, marker, pt)
				if ok_move then
					moved = moved + 1
					placed[#placed + 1] = { x = nx, y = ny }
					local new_sector = SectorAtPoint(map, nx, ny)
					if new_sector and type(new_sector.RegisterDeposit) == "function" then
						pcall(new_sector.RegisterDeposit, new_sector, marker)
					elseif item.sector and type(item.sector.RegisterDeposit) == "function" then
						pcall(item.sector.RegisterDeposit, item.sector, marker) -- no new sector: undo
					end
				else
					unplaced = unplaced + 1
					if item.sector and type(item.sector.RegisterDeposit) == "function" then
						pcall(item.sector.RegisterDeposit, item.sector, marker) -- move failed: undo
					end
					placed[#placed + 1] = { x = item.px, y = item.py }
				end
			else
				unplaced = unplaced + 1
				placed[#placed + 1] = { x = item.px, y = item.py } -- left in place
			end
		end
	end)
	Log("respaced anomaly markers to vanilla-like spacing", {
		moved = moved,
		considered = considered,
		kept_live = kept,
		left_in_place = unplaced,
		min_dist_tiles = (tile > 0) and string.format("%.1f", min_dist_used / tile) or "n/a",
		spread_factor = cfg().ANOMALY_EVEN_SPREAD_FACTOR or 0.6,
		margin_tiles = margin_tiles,
	})
	DepositRules.LogDistributionReport(map, "final (post-respace)")
end

-- Top up RESOURCE deposits to full vanilla density for the expanded map's SIZE. The generator
-- places the native (Big) preset count; spread over the larger 20x20 that is below vanilla
-- density. This clones additional source resource-deposit markers onto terrain-matched FRAME
-- tiles until the total reaches source_count * area_factor (vanilla density x the bigger area).
-- Clones are hidden markers (CloneObjectAtOffset -> ProcessClone sets is_placed=false) that spawn
-- when their frame sector is scanned; RegisterClonedMarkers (run right after) registers them, and
-- EvenOutDepositDensity then spreads everything to even per-sector density. ALL resource types
-- are topped up proportionally, including concrete (TerrainDeposit) -- a cloned concrete marker
-- paints its own regolith patch when its frame sector is scanned (TerrainDepositMarker:SpawnDeposit
-- generates the terrain patch), so no manual imprint is needed. Gated by TOPUP_RESOURCES.
-- "Water=5 Metals=3 ..." -- sorted flat tally string for the top-up proportion logs.
local function TallyString(tbl)
	local keys = {}
	for k in pairs(tbl) do keys[#keys + 1] = k end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(tbl[k]) end
	return table.concat(parts, " ")
end

-- Assigned below after TopUpAnomalies; forward declarations keep the exhaustive diagnostics
-- private to this module while making them visible to the top-up closure.
local IncrementTally
local BuildTopUpEdgeDebugContext
local DescribeTopUpEdge
local PerimeterCoordinate

-- BUILDABLE-SECTOR CENSUS (verification aid): random-sample the map against the buildable
-- grid and report the buildable fraction + how many sectors contain buildable floor. On a
-- stretched map the buildable region scales by the same area factor as the map, so the
-- density target (count x area_factor) is correct per BUILDABLE area too -- this census
-- provides the measured numbers for the log. Runs AFTER RebuildBuildableGrid.
function DepositRules.LogBuildableSectorCensus(map, label)
	local DebugLog = SuperBigMap.DebugLog
	if not (DebugLog and DebugLog.On and DebugLog.On("Deposits")) then return end
	map = map or Global("CurrentMap")
	local point = Global("point")
	if not map or type(point) ~= "function" then return end
	local map_w, map_h = MapWorldSize(map)
	if not map_w or not map_h then return end
	local SAMPLES = 20000
	local buildable_hits = 0
	local sectors_hit, sectors_seen = {}, {}
	for _ = 1, SAMPLES do
		local x, y = RandInt(map_w), RandInt(map_h)
		local sector = SectorAtPoint(map, x, y)
		if sector and sector.id then sectors_seen[sector.id] = true end
		if IsBuildableAt(map, point(x, y)) then
			buildable_hits = buildable_hits + 1
			if sector and sector.id then sectors_hit[sector.id] = true end
		end
	end
	local n_hit, n_seen = 0, 0
	for _ in pairs(sectors_hit) do n_hit = n_hit + 1 end
	for _ in pairs(sectors_seen) do n_seen = n_seen + 1 end
	Log("buildable census", {
		label = tostring(label), map = tostring(map.name),
		buildable_fraction = string.format("%.3f", (buildable_hits + 0.0) / SAMPLES),
		sectors_with_buildable_floor = n_hit, sectors_sampled = n_seen,
		samples = SAMPLES,
	})
end

local function RecordEnrichmentTopUpAudit(map, kind, data)
	-- Read-only diagnostics only. Native RMG warnings are never buffered or suppressed;
	-- this reports whether the later map-size density top-up also completed.
	pcall(function()
		local debug_log = SuperBigMap.DebugLog
		if not (debug_log and type(debug_log.On) == "function"
			and debug_log.On("RmgPlacementExhaustive") == true) then return end
		local fields = { kind = tostring(kind), map = tostring(map and map.name or "?") }
		for k, v in pairs(data or {}) do fields[k] = v end
		debug_log.Info("RmgPlacementExhaustive", "post-stretch enrichment density audit", fields)
	end)
end

-- Shared post-generation coordinate guard. Candidate families may supply their own acceptance
-- rule and scoring policy, but every family gets the same non-negotiable invariants: a real
-- non-origin coordinate, valid terrain, an unscanned surface sector, a unique world coordinate,
-- and a unique final hex across every existing enrichment marker.
local function NewValidatedEnrichmentCoordinateSelector(map, options)
	options = options or {}
	local point = Global("point")
	local world_to_hex = Global("WorldToHex")
	local hex_to_world = Global("HexToWorld")
	if not map or type(map.MapForEach) ~= "function" or type(point) ~= "function"
		or type(world_to_hex) ~= "function" or type(hex_to_world) ~= "function" then
		return nil, "map/point/hex coordinate APIs unavailable"
	end
	local map_w, map_h = MapWorldSize(map)
	if type(map_w) ~= "number" or type(map_h) ~= "number" then
		return nil, "map world size unavailable"
	end
	local occupied_hex = BuildBadgeOccupancy(map, nil, nil, false)
	local occupied_world, offered_hex, offered_world = {}, {}, {}
	local stats = {
		offered = 0, accepted = 0, reserved = 0, rejected = 0,
		rejected_origin = 0, rejected_repeat_coordinate = 0,
		rejected_repeat_hex = 0, rejected_terrain = 0,
		rejected_sector = 0, rejected_family_rule = 0,
	}
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not IsEnrichmentMarker(marker) then return end
		local pos = ObjectPos(marker)
		if not pos or type(pos.xy) ~= "function" then return end
		local x, y = pos:xy()
		if type(x) == "number" and type(y) == "number" then
			occupied_world[tostring(x) .. ":" .. tostring(y)] = true
			local ok_h, q, r = pcall(world_to_hex, pos)
			if ok_h then
				local key = BadgeHexKey(q, r)
				if key then occupied_hex[key] = true end
			end
		end
	end)

	local function reject(field)
		stats.rejected = stats.rejected + 1
		stats[field] = (stats[field] or 0) + 1
		return nil
	end

	local function offer(x, y)
		stats.offered = stats.offered + 1
		if type(x) ~= "number" or type(y) ~= "number" or (x == 0 and y == 0) then
			return reject("rejected_origin")
		end
		local ok_h, q, r = pcall(world_to_hex, point(x, y))
		if not ok_h or type(q) ~= "number" or type(r) ~= "number" then
			return reject("rejected_terrain")
		end
		local ok_w, cx, cy = pcall(hex_to_world, q, r)
		if not ok_w or type(cx) ~= "number" or type(cy) ~= "number"
			or cx < 0 or cy < 0 or cx >= map_w or cy >= map_h
			or (cx == 0 and cy == 0) then
			return reject("rejected_origin")
		end
		local world_key = tostring(cx) .. ":" .. tostring(cy)
		local hex_key = BadgeHexKey(q, r)
		if occupied_world[world_key] or offered_world[world_key] then
			return reject("rejected_repeat_coordinate")
		end
		if not hex_key or occupied_hex[hex_key] or offered_hex[hex_key] then
			return reject("rejected_repeat_hex")
		end
		local sector = SectorAtPoint(map, cx, cy)
		if not sector or (options.require_unscanned ~= false and SectorIsScanned(sector)) then
			return reject("rejected_sector")
		end
		local pt = point(cx, cy)
		if type(pt.SetTerrainZ) == "function" then
			local ok_z, terrain_pt = pcall(pt.SetTerrainZ, pt, map)
			if ok_z and terrain_pt then pt = terrain_pt end
		end
		if not CanReceiveDeposit(map, pt)
			or (options.require_unobstructed == true and not IsUnobstructedAt(map, pt, true)) then
			return reject("rejected_terrain")
		end
		local candidate = {
			point = pt, x = cx, y = cy, q = q, r = r,
			hex_key = hex_key, world_key = world_key, sector = sector,
		}
		if type(options.accept) == "function" and options.accept(candidate) ~= true then
			return reject("rejected_family_rule")
		end
		offered_world[world_key], offered_hex[hex_key] = true, true
		stats.accepted = stats.accepted + 1
		return candidate
	end

	local function reserve(candidate)
		if not candidate or occupied_world[candidate.world_key]
			or occupied_hex[candidate.hex_key] then return false end
		occupied_world[candidate.world_key] = true
		occupied_hex[candidate.hex_key] = true
		stats.reserved = stats.reserved + 1
		return true
	end

	return { Offer = offer, Reserve = reserve, Stats = function() return stats end }
end

-- Replace the stock breakthrough-only GridMinMax filler on the FINAL surface. This retains the
-- vanilla breakthrough policy rather than treating breakthroughs like ordinary anomalies:
-- candidates must satisfy the anomaly layer's full same-family repulsion distance, then the
-- farthest point from resource deposits and already-selected breakthroughs wins each round.
function DepositRules.RepairBreakthroughAnomalies(map)
	if not ExpansionAdditionStagesReady("breakthrough repair") then return true end
	map = map or Global("CurrentMap")
	if cfg().ENABLE_NATIVE_ALIGNED_HEX_COLLISION_REPAIR ~= true
		or not map or IsUndergroundMap(map)
		or map.SuperBigMapBreakthroughRepairPending ~= true then return true end
	local point = Global("point")
	local clone_fn = SuperBigMap.ObjectClone and SuperBigMap.ObjectClone.CloneObjectAtOffset
	local function invariant_fail(reason)
		map.SuperBigMapBreakthroughRepairComplete = false
		map.SuperBigMapBreakthroughRepairPending = true
		Log("breakthrough placement invariant FAILED", { reason = tostring(reason) })
		error("breakthrough placement invariant failed: " .. tostring(reason))
	end
	if type(point) ~= "function" or type(clone_fn) ~= "function"
		or type(map.MapForEach) ~= "function" then
		invariant_fail("clone/map APIs unavailable")
	end
	local target = tonumber(map.SuperBigMapBreakthroughRepairTarget
		or map.SuperBigMapRolledBreakthroughCount) or 0
	target = math.max(0, math.floor(target))
	local reserved_for_planetary = 0
	if map.SuperBigMapBreakthroughPruningDone == true then
		local game_consts = Global("g_Consts")
		reserved_for_planetary = type(game_consts) == "table"
			and tonumber(game_consts.PlanetaryBreakthroughCount) or 0
		reserved_for_planetary = math.max(0, math.floor(reserved_for_planetary or 0))
		target = math.max(0, target - reserved_for_planetary)
		local colony = Global("UIColony")
		if colony and type(colony.UpdateAvailableBreackthroughTechs) == "function" then
			local ok_available, available = pcall(
				colony.UpdateAvailableBreackthroughTechs, colony, map)
			if ok_available and type(available) == "table" then
				target = math.min(target, #available)
			end
		end
	end

	local templates, fallback_templates = {}, {}
	local breakthroughs, anomaly_positions, resource_anchors = {}, {}, {}
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		local pos = marker and ObjectPos(marker)
		local x, y
		if pos and type(pos.xy) == "function" then x, y = pos:xy() end
		if IsAnomalyMarker(marker) then
			if tostring(marker.class or "") == "SubsurfaceAnomalyMarker" then
				templates[#templates + 1] = marker
			end
			fallback_templates[#fallback_templates + 1] = marker
			if type(x) == "number" and type(y) == "number" then
				anomaly_positions[#anomaly_positions + 1] = { x = x, y = y }
				if marker.tech_action == "breakthrough" then
					breakthroughs[#breakthroughs + 1] = marker
					resource_anchors[#resource_anchors + 1] = { x = x, y = y }
				end
			end
		elseif IsResourceDepositMarker(marker)
			and type(x) == "number" and type(y) == "number" then
			resource_anchors[#resource_anchors + 1] = { x = x, y = y }
		end
	end)
	local current = #breakthroughs
	if current > target then
		invariant_fail(string.format("current count %d exceeds target %d", current, target))
	end
	if current >= target then
		map.SuperBigMapBreakthroughRepairPending = false
		map.SuperBigMapBreakthroughRepairComplete = current == target
		Log("breakthrough farthest-point repair already satisfied", {
			target = target, current = current, reserved_for_planetary = reserved_for_planetary,
		})
		return current == target
	end
	local deficit = target - current
	if #templates == 0 then templates = fallback_templates end
	if #templates == 0 then
		invariant_fail("no anomaly marker template")
	end

	local guim = tonumber(Global("guim")) or 1000
	local anomaly_spacing = tonumber(map.SuperBigMapBreakthroughAnomalySpacing) or (200 * guim)
	local min_spacing = math.max(0, anomaly_spacing * 2)
	local min_spacing_sq = min_spacing * min_spacing
	local validator, validator_error = NewValidatedEnrichmentCoordinateSelector(map, {
		require_unscanned = true,
		require_unobstructed = true,
		accept = function(candidate)
			for _, pos in ipairs(anomaly_positions) do
				local dx, dy = candidate.x - pos.x, candidate.y - pos.y
				if dx * dx + dy * dy < min_spacing_sq then return false end
			end
			return true
		end,
	})
	if not validator then
		invariant_fail(tostring(validator_error))
	end
	local map_w, map_h, tile = MapWorldSize(map)
	if not map_w or not map_h or not tile then
		invariant_fail("map size unavailable")
	end
	local margin = math.max(0, math.floor(cfg().DEPOSIT_EDGE_MARGIN_TILES or 4)) * tile
	local span_x, span_y = map_w - 2 * margin, map_h - 2 * margin
	if span_x <= 0 or span_y <= 0 then
		invariant_fail("final surface has no sampling span")
	end

	local candidates = {}
	-- The final map has roughly 400 sectors. A 12k pool gives the farthest-point pass broad
	-- whole-map coverage (about 30 accepted candidates per sector on average) without scanning
	-- every terrain hex.
	local candidate_goal = math.max(12000, deficit * 1500)
	local cached = CachedTopUpCandidates(map)
	for _, source in ipairs(cached or {}) do
		if #candidates >= candidate_goal then break end
		local candidate = validator.Offer(source.x, source.y)
		if candidate then candidates[#candidates + 1] = candidate end
	end
	local random_attempts, max_random_attempts = 0, candidate_goal * 40
	while #candidates < candidate_goal and random_attempts < max_random_attempts do
		random_attempts = random_attempts + 1
		local candidate = validator.Offer(
			margin + RandInt(span_x), margin + RandInt(span_y))
		if candidate then candidates[#candidates + 1] = candidate end
	end
	if #candidates < deficit then
		invariant_fail(string.format("candidate builder produced %d for %d placements",
			#candidates, deficit))
	end

	-- Seed every candidate with its distance to the vanilla resource/breakthrough anchors.
	-- Resource-less test maps fall back to anomaly anchors; real generated surfaces have many.
	local score_anchors = #resource_anchors > 0 and resource_anchors or anomaly_positions
	for _, candidate in ipairs(candidates) do
		local score = math.huge
		for _, anchor in ipairs(score_anchors) do
			local dx, dy = candidate.x - anchor.x, candidate.y - anchor.y
			local dist_sq = dx * dx + dy * dy
			if dist_sq < score then score = dist_sq end
		end
		if score == math.huge then
			local edge = math.min(candidate.x, candidate.y,
				map_w - candidate.x, map_h - candidate.y)
			score = edge * edge
		end
		candidate.farthest_score = score
	end

	local selected = {}
	for _ = 1, deficit do
		local best, best_score
		for _, candidate in ipairs(candidates) do
			if not candidate.selected and not candidate.too_close
				and (best_score == nil or candidate.farthest_score > best_score) then
				best, best_score = candidate, candidate.farthest_score
			end
		end
		if not best or not validator.Reserve(best) then
			invariant_fail("farthest selector exhausted valid coordinates")
		end
		best.selected = true
		selected[#selected + 1] = best
		for _, candidate in ipairs(candidates) do
			if not candidate.selected and not candidate.too_close then
				local dx, dy = candidate.x - best.x, candidate.y - best.y
				local dist_sq = dx * dx + dy * dy
				if dist_sq < min_spacing_sq then
					candidate.too_close = true
				elseif dist_sq < candidate.farthest_score then
					candidate.farthest_score = dist_sq
				end
			end
		end
	end

	local deep_chance = tonumber(map.SuperBigMapBreakthroughDeepChance)
	if deep_chance then deep_chance = math.max(0, math.min(100, deep_chance)) end
	local added = 0
	for index, candidate in ipairs(selected) do
		local template = templates[((index - 1) % #templates) + 1]
		local template_pos = ObjectPos(template)
		if not template_pos or type(template_pos.xy) ~= "function" then
			invariant_fail("template position unavailable")
		end
		local tx, ty = template_pos:xy()
		local clone = clone_fn(map, template, point(candidate.x - tx, candidate.y - ty, 0))
		if not clone or type(clone) ~= "table" then
			invariant_fail("marker clone failed")
		end
		clone.tech_action = "breakthrough"
		clone.sequence = ""
		clone.sequence_list = ""
		if deep_chance then
			clone.depth_layer = RandInt(100) < deep_chance and 2 or 1
		end
		clone.SuperBigMapBreakthroughRepair = true
		clone.SuperBigMapBreakthroughSelection = "vanilla_farthest_point"
		if type(clone.SetPos) == "function" then
			local ok_set = pcall(clone.SetPos, clone, candidate.point)
			if not ok_set then
				invariant_fail("marker SetPos failed")
			end
		end
		clone.is_placed = false
		clone.placed_obj = false
		SetRevealedState(clone, false)
		if not candidate.sector or type(candidate.sector.RegisterDeposit) ~= "function"
			or pcall(candidate.sector.RegisterDeposit, candidate.sector, clone) ~= true then
			invariant_fail("sector registration failed")
		end
		added = added + 1
	end
	-- Recount the live map and re-check the two placement invariants rather than trusting the
	-- clone counter. A mismatch is an implementation failure, never a normal terrain shortfall.
	local final_positions, final_world, final_hex = {}, {}, {}
	local duplicate_world, duplicate_hex = 0, 0
	pcall(map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(marker)
		if not IsAnomalyMarker(marker) or marker.tech_action ~= "breakthrough" then return end
		local pos = ObjectPos(marker)
		if not pos or type(pos.xy) ~= "function" then return end
		local x, y = pos:xy()
		if type(x) ~= "number" or type(y) ~= "number" then return end
		local world_key = tostring(x) .. ":" .. tostring(y)
		if final_world[world_key] then duplicate_world = duplicate_world + 1 end
		final_world[world_key] = true
		local _, _, hex_key = BadgeObjectHex(marker)
		if hex_key and final_hex[hex_key] then duplicate_hex = duplicate_hex + 1 end
		if hex_key then final_hex[hex_key] = true end
		final_positions[#final_positions + 1] = { x = x, y = y }
	end)
	local min_pair_distance
	for i = 1, #final_positions do
		for j = i + 1, #final_positions do
			local dx = final_positions[i].x - final_positions[j].x
			local dy = final_positions[i].y - final_positions[j].y
			local distance = math.sqrt(dx * dx + dy * dy)
			if not min_pair_distance or distance < min_pair_distance then
				min_pair_distance = distance
			end
		end
	end
	local final_count = #final_positions
	map.SuperBigMapBreakthroughRepairComplete = final_count == target
		and duplicate_world == 0 and duplicate_hex == 0
		and (not min_pair_distance or min_pair_distance >= min_spacing)
	map.SuperBigMapBreakthroughRepairPending = not map.SuperBigMapBreakthroughRepairComplete
	map.SuperBigMapBreakthroughRepairStats = {
		target = target, current = current, added = added, final = final_count,
		pre_prune_target = map.SuperBigMapBreakthroughRepairTarget,
		reserved_for_planetary = reserved_for_planetary,
		min_spacing = min_spacing, min_pair_distance = min_pair_distance,
		duplicate_world = duplicate_world, duplicate_hex = duplicate_hex,
		candidates = #candidates,
		random_attempts = random_attempts, coordinate_stats = validator.Stats(),
	}
	Log("breakthrough anomalies rebuilt with vanilla farthest-point selection", {
		target = target, current = current, added = added, final = final_count,
		pre_prune_target = tostring(map.SuperBigMapBreakthroughRepairTarget),
		reserved_for_planetary = reserved_for_planetary,
		min_spacing = min_spacing, min_pair_distance = tostring(min_pair_distance),
		duplicate_world = duplicate_world, duplicate_hex = duplicate_hex,
		candidates = #candidates,
		random_attempts = random_attempts,
	})
	RecordEnrichmentTopUpAudit(map, "breakthroughs", {
		complete = map.SuperBigMapBreakthroughRepairComplete, target = target, current = current,
		added = added, final = final_count, candidates = #candidates,
	})
	if final_count ~= target or duplicate_world > 0 or duplicate_hex > 0
		or (min_pair_distance and min_pair_distance < min_spacing) then
		invariant_fail(string.format(
			"final=%d target=%d duplicate_world=%d duplicate_hex=%d min_pair=%s required=%s",
			final_count, target, duplicate_world, duplicate_hex,
			tostring(min_pair_distance), tostring(min_spacing)))
	end
	return true, map.SuperBigMapBreakthroughRepairStats
end

function DepositRules.TopUpDeposits(map)
	if cfg().TOPUP_RESOURCES ~= true then return end
	if not ExpansionAdditionStagesReady("resource top-up") then return end
	map = map or Global("CurrentMap")
	RecordEnrichmentTopUpAudit(map, "resources", { complete = false, reason = "started" })
	local point = Global("point")
	local clone_fn = SuperBigMap.ObjectClone and SuperBigMap.ObjectClone.CloneObjectAtOffset
	local city = map and map.City
	if not map or type(map.MapForEach) ~= "function" or type(point) ~= "function"
		or type(clone_fn) ~= "function" or not city then
		Log("deposit top-up skipped", { reason = "map/city/point/clone unavailable" })
		return
	end
	local map_w, map_h, tile = MapWorldSize(map)
	if not map_w or not tile or tile <= 0 then
		Log("deposit top-up skipped", { reason = "map size unavailable" })
		return
	end
	local margin_tiles = math.max(0, math.floor(cfg().DEPOSIT_EDGE_MARGIN_TILES or 4))
	local margin = margin_tiles * tile
	local src_w = (type(map.SuperBigMapSourceWidth) == "number") and map.SuperBigMapSourceWidth or 0
	local src_h = (type(map.SuperBigMapSourceHeight) == "number") and map.SuperBigMapSourceHeight or 0
	local lo_x, span_x = margin, (map_w - 2 * margin)
	local lo_y, span_y = margin, (map_h - 2 * margin)
	if span_x <= 0 or span_y <= 0 then
		Log("deposit top-up skipped", { reason = "placeable span <= 0" })
		return
	end

	-- Area factor = (desired/generated)^2 (same as sbm_rmg_placement); an override forces it.
	local area_factor = 1.0
	local override = cfg().DEPOSIT_COUNT_SCALE_OVERRIDE
	if type(override) == "number" and override > 0 then
		area_factor = override
	else
		local gen_t = map.SuperBigMapGeneratorWidthTiles
		local full_t = map.SuperBigMapDesiredWidthTiles or (map.mapdata and map.mapdata.Width)
		if type(gen_t) == "number" and gen_t > 0 and type(full_t) == "number" and full_t > gen_t then
			local r = full_t * 1.0 / gen_t   -- * 1.0: this runtime truncates integer division
			area_factor = r * r
		end
	end
	if area_factor <= 1.0 then
		Log("deposit top-up: no scaling (area_factor <= 1)", { area_factor = area_factor })
		return
	end

	-- Count current resource markers (total) and the ones inside the source quadrant (the
	-- generated density baseline); collect non-concrete source markers as clone templates.
	-- STRETCH mode: ScaleMarkersToFull has already spread the generated markers over the WHOLE
	-- map, so the source-quadrant test no longer identifies the generated baseline (it would
	-- undercount by ~1/area_factor and make the top-up a no-op). In stretch the baseline IS the
	-- full current population (every marker is generator output), so count/keep them all.
	local stretch_mode = tostring(cfg().EXPANSION_FRAME_FILL_MODE or "mirror") == "stretch"
	local total_current, source_count = 0, 0
	local templates, templates_by_type = {}, {}
	local current_by_type, src_by_type = {}, {}
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not (marker and IsResourceDepositMarker(marker)) then return end
		total_current = total_current + 1
		local res = tostring(marker.resource or marker.class or "?")
		current_by_type[res] = (current_by_type[res] or 0) + 1
		local pos = ObjectPos(marker)
		if not pos or type(pos.xy) ~= "function" then return end
		local px, py = pos:xy()
		if px == nil then return end
		if not marker.SuperBigMapResourceTopUp
			and (stretch_mode or (px < src_w and py < src_h)) then
			source_count = source_count + 1
			-- All resource types are templates (incl. concrete) so the top-up mix is
			-- proportional to the source; cloned concrete self-paints its patch on scan.
			templates[#templates + 1] = marker
			templates_by_type[res] = templates_by_type[res] or {}
			templates_by_type[res][#templates_by_type[res] + 1] = marker
			src_by_type[res] = (src_by_type[res] or 0) + 1
		end
	end)

	-- Per-resource targets normally preserve the generated mix. When the RMG reported
	-- an explicit shortfall, use its requested native count as the floor before applying
	-- the map area factor, so Concrete 11/27 becomes a target based on 27, not 11.
	local target_by_type, target_keys = {}, {}
	for res, count in pairs(src_by_type) do
		target_by_type[res] = math.floor(count * area_factor + 0.5)
	end
	for res, count in pairs(map.SuperBigMapExpectedResourceCounts or {}) do
		if type(count) == "number" and count > 0 then
			local floor_target = math.floor(count * area_factor + 0.5)
			target_by_type[res] = math.max(target_by_type[res] or 0, floor_target)
		end
	end
	local target, shortfall = 0, 0
	for res, count in pairs(target_by_type) do
		target_keys[#target_keys + 1] = res
		target = target + count
		shortfall = shortfall + math.max(0, count - (current_by_type[res] or 0))
	end
	table.sort(target_keys)
	if shortfall <= 0 or #templates == 0 then
		Log("deposit top-up: nothing to add", {
			total_current = total_current, source_count = source_count, target = target,
			shortfall = shortfall, templates = #templates,
			area_factor = string.format("%.3f", area_factor),
		})
		RecordEnrichmentTopUpAudit(map, "resources", {
			complete = shortfall <= 0, remaining_shortfall = shortfall,
			templates = #templates, target = target, current = total_current,
		})
		return
	end

	local added_by_type = {}

	local added = 0
	local pool_final = 0
	local registered_at_creation = 0
	local placement_stats
	local placement_attempts, clone_failures, terrain_fallbacks = 0, 0, 0
	RunPaused("SuperBigMapDepositTopUp", function()
		-- Shared validated pool. Selection preserves terrain type while preferring sectors with
		-- the lowest existing-enrichment load relative to sampled eligible terrain area.
		local shared_candidates, pool = {}, 0
		local MAX_SAMPLES, MAX_POOL = 8000, 4000
		for _ = 1, MAX_SAMPLES do
			if pool >= MAX_POOL then break end
			local x = lo_x + RandInt(span_x)
			local y = lo_y + RandInt(span_y)
			-- Spread across the whole UNSCANNED map (rendered source AND mirrored frame),
			-- excluding only the scanned start sector: this keeps relocated/added markers from
			-- piling into the frame L-strip (which made one region far denser than the rest), and
			-- prevents hidden markers landing in an already-scanned sector where they'd never reveal.
			-- The final map's outer perimeter is reserved for qualifying anomaly top-up extras.
			local sector = SectorAtPoint(map, x, y)
			local reserved_ring = not IsUndergroundMap(map) and IsInFinalOuterSectorRing(map, x, y,
				cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3)
			if sector and (IsUndergroundMap(map) or not SectorIsScanned(sector)) and not reserved_ring then
				local pt = point(x, y)
				if CanReceiveDeposit(map, pt) then
					local tt = TerrainTypeAt(map, pt) or -1
					local candidate = {
						x = x, y = y, terrain_type = tt, sector = sector, sector_id = sector.id,
					}
					shared_candidates[#shared_candidates + 1] = candidate
					pool = pool + 1
				end
			end
		end
		pool_final = pool
		if cfg().OPTIMIZE_TOPUP_PLACEMENT_POOLS == true then
			topup_candidate_pool_by_map[map] = shared_candidates
		end
		ProfileStep("resource candidate pool built", { candidates = pool }, map)
		local selector = NewSectorBalancedCandidateSelector(map, shared_candidates, "resources")
		local function take(tt)
			return selector.Take(tt)
		end
		local function take_any()
			return selector.Take()
		end

		local function choose_needed_type()
			local deficit_total = 0
			for _, res in ipairs(target_keys) do
				deficit_total = deficit_total + math.max(0,
					(target_by_type[res] or 0) - (current_by_type[res] or 0) - (added_by_type[res] or 0))
			end
			if deficit_total <= 0 then return nil end
			local pick = RandInt(deficit_total)
			for _, res in ipairs(target_keys) do
				local deficit = math.max(0,
					(target_by_type[res] or 0) - (current_by_type[res] or 0) - (added_by_type[res] or 0))
				if pick < deficit then return res end
				pick = pick - deficit
			end
			return nil
		end

		-- A candidate is reserved by Take. If cloning that candidate fails, keep trying unused
		-- candidates until the exact type targets are met or the validated pool is exhausted.
		while added < shortfall and selector.Remaining() > 0 do
			placement_attempts = placement_attempts + 1
			local needed_type = choose_needed_type()
			local type_templates = needed_type and templates_by_type[needed_type] or nil
			local template = type_templates and type_templates[RandInt(#type_templates) + 1] or nil
			if not template then break end
			local tpos = ObjectPos(template)
			if tpos and type(tpos.xy) == "function" then
				local tt = TerrainTypeAt(map, tpos) or -1
				local c = take(tt)
				if not c then
					c = take_any()
					if c then terrain_fallbacks = terrain_fallbacks + 1 end
				end
				if not c then break end   -- pool exhausted
				local tx, ty = tpos:xy()
				local clone = clone_fn(map, template, point(c.x - tx, c.y - ty, 0))
				if clone and type(clone) == "table" then
					selector.Commit(c)
					added = added + 1
					local res = tostring(template.resource or template.class or "?")
					clone.SuperBigMapResourceTopUp = true
					added_by_type[res] = (added_by_type[res] or 0) + 1
					if type(clone.SetPos) == "function" then
						local pt = point(c.x, c.y)
						if type(pt.SetTerrainZ) == "function" then
							local ok, snapped = pcall(pt.SetTerrainZ, pt, map)
							if ok and snapped then pt = snapped end
						end
						pcall(clone.SetPos, clone, pt)
					end
					if cfg().OPTIMIZE_TOPUP_PLACEMENT_POOLS == true and stretch_mode
						and not IsUndergroundMap(map) then
						local sec = SectorAtPoint(map, c.x, c.y)
						if sec and type(sec.RegisterDeposit) == "function" then
							pcall(sec.RegisterDeposit, sec, clone)
							registered_at_creation = registered_at_creation + 1
						end
					end
				else
					clone_failures = clone_failures + 1
				end
			else
				-- Resource templates were position-checked when collected. Fail closed if one
				-- becomes invalid instead of spinning without consuming a candidate.
				clone_failures = clone_failures + 1
				break
			end
		end
		placement_stats = selector.Stats()
	end)
	local final_by_type, remaining_shortfall, excess = {}, 0, 0
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not (marker and IsResourceDepositMarker(marker)) then return end
		local res = tostring(marker.resource or marker.class or "?")
		final_by_type[res] = (final_by_type[res] or 0) + 1
	end)
	for _, res in ipairs(target_keys) do
		local final_count = final_by_type[res] or 0
		remaining_shortfall = remaining_shortfall
			+ math.max(0, (target_by_type[res] or 0) - final_count)
		excess = excess + math.max(0, final_count - (target_by_type[res] or 0))
	end
	Log("topped up resource deposits to map-size proportions", {
		area_factor = string.format("%.3f", area_factor),
		source_count = source_count, total_before = total_current,
		target = target, added = added, templates = #templates,
		map = tostring(map.name), pool = pool_final,
		registered_at_creation = registered_at_creation,
		target_capture = tostring(map.SuperBigMapResourceTargetCapture),
		source_mix = TallyString(src_by_type),
		target_mix = TallyString(target_by_type),
		added_mix = TallyString(added_by_type),
		final_mix = TallyString(final_by_type),
		remaining_shortfall = remaining_shortfall,
		excess = excess,
		placement_attempts = placement_attempts,
		clone_failures = clone_failures,
		terrain_fallbacks = terrain_fallbacks,
		balanced_placement = placement_stats and placement_stats.balanced,
		eligible_sectors = placement_stats and placement_stats.eligible_sectors,
		selected_sectors = placement_stats and placement_stats.selected_sectors,
		selected = placement_stats and placement_stats.selected,
		remaining_candidates = placement_stats and placement_stats.remaining_candidates,
		max_additions_to_one_sector = placement_stats and placement_stats.max_additions_to_one_sector,
	})
	RecordEnrichmentTopUpAudit(map, "resources", {
		complete = remaining_shortfall == 0, remaining_shortfall = remaining_shortfall,
		templates = #templates, target = target, current = total_current + added,
	})
	DepositRules.LogDistributionReport(map, "after deposit top-up")
end

-- POST-GENERATION anomaly top-up (config TOPUP_ANOMALIES). Raises the ANOMALY population
-- to vanilla density x area WITHOUT touching the generator: the previous in-generation count
-- scaling (sbm_rmg_placement) shifted the generator's random stream, so the same coordinates
-- produced a DIFFERENT map than vanilla (terrain prefabs at other positions/rotations) -- the
-- user requires bit-identical generation, so RmgPlacement.Begin is now skipped in stretch mode
-- and the scaling happens here instead. Clones existing standard anomaly markers; the actual
-- reward resolves at scan time. This density pass deliberately does not scale breakthroughs;
-- their finite rolled target is restored separately by RepairBreakthroughAnomalies after City
-- reserve pruning, using the breakthrough family's vanilla farthest-point placement policy.
-- safety arguments as the original design. Only standard `complete`, `unlock`, and event
-- `sequence` deficits are cloned. Those previously selected reward categories are placed
-- exclusively in the FINAL map's outer three-sector mountain ring. `other` (including unique/
-- cave-specific) families are preserved; breakthroughs are handled by the dedicated pass above.
-- Each clone is hidden + sector-registered so a real
-- scan reveals it. Underground extras retain whole-map placement because there is no surface
-- mountain-edge ring there. Surface placement is deliberately two-stage: first choose a ring
-- sector without considering its terrain candidates, then choose randomly among that sector's
-- least-restrictive low-area candidates. Occupied anomaly hexes are reserved to prevent overlap.
function DepositRules.TopUpAnomalies(map)
	if cfg().TOPUP_ANOMALIES ~= true then return end
	if not ExpansionAdditionStagesReady("anomaly top-up") then return end
	map = map or Global("CurrentMap")
	RecordEnrichmentTopUpAudit(map, "anomalies", { complete = false, reason = "started" })
	local point = Global("point")
	local clone_fn = SuperBigMap.ObjectClone and SuperBigMap.ObjectClone.CloneObjectAtOffset
	local city = map and map.City
	if not map or type(map.MapForEach) ~= "function" or type(point) ~= "function"
		or type(clone_fn) ~= "function" or not city then
		Log("anomaly top-up skipped", { reason = "map/city/point/clone unavailable" })
		return
	end
	local map_w, map_h, tile = MapWorldSize(map)
	if not map_w or not tile or tile <= 0 then
		Log("anomaly top-up skipped", { reason = "map size unavailable" })
		return
	end
	local margin = math.max(0, math.floor(cfg().DEPOSIT_EDGE_MARGIN_TILES or 4)) * tile
	local lo_x, span_x = margin, (map_w - 2 * margin)
	local lo_y, span_y = margin, (map_h - 2 * margin)
	if span_x <= 0 or span_y <= 0 then return end
	local area_factor = 1.0
	do
		local gen_t = map.SuperBigMapGeneratorWidthTiles
		local full_t = map.SuperBigMapDesiredWidthTiles or (map.mapdata and map.mapdata.Width)
		if type(gen_t) == "number" and gen_t > 0 and type(full_t) == "number" and full_t > gen_t then
			local r = full_t * 1.0 / gen_t -- * 1.0: this runtime truncates integer division
			area_factor = r * r
		end
	end
	if area_factor <= 1.0 then
		Log("anomaly top-up: no scaling (area_factor <= 1)", { area_factor = area_factor })
		return
	end
	-- Category helpers. `kind` is stable across markers and already-spawned anomalies,
	-- while the display category retains the marker class for diagnostics.
	local function AnomalyKind(obj)
		local action = obj and obj.tech_action
		if action == "complete" or action == "unlock" or action == "breakthrough" then
			return action
		end
		if obj and obj.sequence ~= nil and obj.sequence ~= "" then return "sequence" end
		return "other"
	end
	local function AnomalyCategory(marker)
		return tostring(marker.class or "?") .. "/" .. AnomalyKind(marker)
	end
	local function AnomalyRewardFamily(marker)
		local action = marker and marker.tech_action
		if action == "complete" or action == "unlock" then
			return "research_or_technology_progress"
		elseif action == "breakthrough" then
			return "breakthrough_reward"
		elseif marker and marker.sequence ~= nil and marker.sequence ~= "" then
			-- Event sequences contain the metal/rare-metal discoveries, large caches,
			-- unique scenic discoveries, and other research/technology event outcomes.
			return "event_discovery_cache_or_scenic_reward"
		end
		-- The base anomaly family is the ordinary research-points result.
		return "research_points"
	end

	-- Markers remain as the authoritative backing records after an anomaly is spawned;
	-- counting live SubsurfaceAnomaly objects too would double-count revealed markers.
	-- Targets use only original generator output, while total_current includes prior
	-- top-ups so a repeated call remains a no-op.
	local total_current = 0
	local templates, standard_templates, standard_templates_by_kind = {}, {}, {}
	local current_by_kind, current_standard_by_kind = {}, {}
	local source_by_kind, source_standard_by_kind = {}, {}
	local src_by_cat, added_by_cat, src_by_reward, added_by_reward = {}, {}, {}, {}
	pcall(map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(marker)
		if not marker then return end
		local kind = AnomalyKind(marker)
		local is_standard = tostring(marker.class or "") == "SubsurfaceAnomalyMarker"
		total_current = total_current + 1
		current_by_kind[kind] = (current_by_kind[kind] or 0) + 1
		if is_standard then
			current_standard_by_kind[kind] = (current_standard_by_kind[kind] or 0) + 1
		end
		if not marker.SuperBigMapAnomalyTopUp and not marker.SuperBigMapQuadrantClone then
			templates[#templates + 1] = marker
			if is_standard then
				standard_templates[#standard_templates + 1] = marker
				standard_templates_by_kind[kind] = standard_templates_by_kind[kind] or {}
				standard_templates_by_kind[kind][#standard_templates_by_kind[kind] + 1] = marker
				source_standard_by_kind[kind] = (source_standard_by_kind[kind] or 0) + 1
			end
			source_by_kind[kind] = (source_by_kind[kind] or 0) + 1
		end
	end)
	for _, t in ipairs(templates) do
		local cat = AnomalyCategory(t)
		src_by_cat[cat] = (src_by_cat[cat] or 0) + 1
		local reward = AnomalyRewardFamily(t)
		src_by_reward[reward] = (src_by_reward[reward] or 0) + 1
	end
	local target_by_kind, target_keys = {}, {}
	-- This is also the authoritative surface outer-ring category filter. Do not broaden it to
	-- breakthrough/other: those are finite-pool or unique families rather than density top-ups.
	local scalable_kind = { complete = true, unlock = true, sequence = true }
	for kind, current_count in pairs(current_by_kind) do
		-- Breakthroughs are capped and pruned by City:InitBreakThroughAnomalies;
		-- `other` includes unique underground/cave content. Preserve both exactly.
		if scalable_kind[kind] then
			local standard_current = current_standard_by_kind[kind] or 0
			local special_current = math.max(0, current_count - standard_current)
			target_by_kind[kind] = special_current
				+ math.floor((source_standard_by_kind[kind] or 0) * area_factor + 0.5)
		else
			target_by_kind[kind] = current_count
		end
	end
	for kind, count in pairs(map.SuperBigMapExpectedAnomalyCounts or {}) do
		if scalable_kind[kind] and type(count) == "number" and count >= 0 then
			local special_current = math.max(0, (current_by_kind[kind] or 0)
				- (current_standard_by_kind[kind] or 0))
			local floor_target = special_current + math.floor(count * area_factor + 0.5)
			target_by_kind[kind] = math.max(target_by_kind[kind] or 0, floor_target)
		end
	end

	-- Build the engine-configured Event scenario pool. Prefer scenarios not already
	-- assigned to native markers; once exhausted, reuse is allowed just as vanilla's
	-- PlaceEventAnomalies extends a short scenario pool.
	local event_scenarios, unused_event_scenarios = {}, {}
	do
		local get_properties_array = Global("GetPropertiesArray")
		local scenarios = Global("Scenarios")
		local list_names
		if type(get_properties_array) == "function" and type(map.mapdata) == "table" then
			local ok, value = pcall(get_properties_array, map.mapdata, "anomaly_sequence_list_names")
			if ok and type(value) == "table" then list_names = value end
		end
		local used, seen = {}, {}
		for _, marker in ipairs(standard_templates_by_kind.sequence or {}) do
			if marker.sequence and marker.sequence ~= "" then
				used[tostring(marker.sequence_list) .. "\0" .. tostring(marker.sequence)] = true
			end
		end
		if type(scenarios) == "table" and type(list_names) == "table" then
			for _, list_name in ipairs(list_names) do
				local list = scenarios[list_name]
				if type(list_name) == "string" and list_name ~= "" and type(list) == "table" then
					for _, scenario in ipairs(list) do
						local name = type(scenario) == "table" and scenario.name or nil
						local key = name and (list_name .. "\0" .. tostring(name)) or nil
						if key and not seen[key] then
							seen[key] = true
							local entry = { name = name, list = list_name }
							event_scenarios[#event_scenarios + 1] = entry
							if not used[key] then unused_event_scenarios[#unused_event_scenarios + 1] = entry end
						end
					end
				end
			end
		end
	end
	local function take_event_scenario(template)
		local pool = #unused_event_scenarios > 0 and unused_event_scenarios or event_scenarios
		if #pool > 0 then
			local i = RandInt(#pool) + 1
			local entry = pool[i]
			if pool == unused_event_scenarios then table.remove(pool, i) end
			return entry.name, entry.list
		end
		if template and AnomalyKind(template) == "sequence"
			and template.sequence and template.sequence ~= "" then
			return template.sequence, template.sequence_list
		end
		return nil, nil
	end
	local target, shortfall = 0, 0
	for kind, count in pairs(target_by_kind) do
		target_keys[#target_keys + 1] = kind
		target = target + count
		shortfall = shortfall + math.max(0, count - (current_by_kind[kind] or 0))
	end
	table.sort(target_keys)
	if shortfall <= 0 or #templates == 0 then
		Log("anomaly top-up: nothing to add", {
			total_current = total_current, templates = #templates, target = target,
			shortfall = shortfall, area_factor = string.format("%.3f", area_factor),
		})
		RecordEnrichmentTopUpAudit(map, "anomalies", {
			complete = shortfall <= 0, remaining_shortfall = shortfall,
			templates = #templates, target = target, current = total_current,
		})
		return
	end
	local added_by_kind = {}

	local added = 0
	local pool_final = 0
	local reused_pool = false
	local edge_debug = false
	local edge_ctx
	local added_markers = {}
	local whole_map_placement_stats
	local placement_attempts, clone_failures = 0, 0
	local ring_sectors = math.max(0, math.floor(cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3))
	local low_area_percent = math.max(1, math.min(100,
		math.floor(cfg().TOPUP_ANOMALY_LOW_AREA_PERCENT or 35)))
	local surface_edge_ring = not IsUndergroundMap(map) and ring_sectors > 0
	-- Filled inside RunPaused and audited afterwards; keep it in this enclosing scope.
	local ring_sector_count = 0
	local edge_stats = {
		sampled_by_edge = {}, sampled_by_planned_ring_edge = {}, sampled_by_source_region = {}, accepted_by_edge = {},
		accepted_by_sector = {}, rejected_by_reason = {}, selected_by_edge = {}, selected_by_sector = {},
		selected_by_target_side = {}, selected_by_nearest_side = {}, selected_by_scope = {},
		added_by_edge = {}, added_by_sector = {}, final_by_edge = {}, final_by_nearest_side = {},
		final_by_sector = {}, ring_predicate_comparison = {}, ring_sector_coverage = {},
		accepted_by_exclusive_side = {}, accepted_by_side_layer = {},
		selected_by_side_layer = {}, final_by_side_layer = {},
	}
	RunPaused("SuperBigMapAnomalyTopUp", function()
		local candidates = {}
		local ring_sector_pool = {}
		local BASE_WHOLE_MAP_SAMPLES = 6000
		local SAMPLES_PER_RING_SECTOR = 32
		local STAGE_TWO_AREA_SAMPLES = 96
		local MAX_POOL = 10000
		edge_debug = surface_edge_ring and TopUpEdgeLogOn()
		-- Build the live, index-base-independent edge context for production placement as well as
		-- diagnostics. Surface sampling is stratified by EVERY live ring sector so random sampling
		-- cannot silently omit the final bottom/right runs (or any other part of the perimeter).
		edge_ctx = surface_edge_ring and BuildTopUpEdgeDebugContext(map, ring_sectors) or nil
		local sampling_plan = {}
		local function ring_edges_for_sector(s)
			if not (edge_ctx and s) then return "whole_map" end
			local sides = {}
			if s.col <= edge_ctx.min_col + ring_sectors - 1 then sides[#sides + 1] = "left" end
			if s.col >= edge_ctx.max_col - ring_sectors + 1 then sides[#sides + 1] = "right" end
			if s.row <= edge_ctx.min_row + ring_sectors - 1 then sides[#sides + 1] = "top" end
			if s.row >= edge_ctx.max_row - ring_sectors + 1 then sides[#sides + 1] = "bottom" end
			return #sides > 0 and table.concat(sides, "+") or "interior"
		end
		if surface_edge_ring and edge_ctx and type(edge_ctx.sector_step) == "number" then
			for _, s in ipairs(edge_ctx.sectors) do
				local expected_edge = ring_edges_for_sector(s)
				if expected_edge ~= "interior" then
					ring_sector_count = ring_sector_count + 1
					s.expected_edge = expected_edge
					local sx0 = s.area_x0 or ((s.col - edge_ctx.min_col) * edge_ctx.sector_step)
					local sy0 = s.area_y0 or ((s.row - edge_ctx.min_row) * edge_ctx.sector_step)
					local sx1 = s.area_x1 or (sx0 + edge_ctx.sector_step)
					local sy1 = s.area_y1 or (sy0 + edge_ctx.sector_step)
					local center_x, center_y = (sx0 + sx1) / 2, (sy0 + sy1) / 2
					local _, selection_side, edge_depth = PerimeterCoordinate(edge_ctx, center_x, center_y)
					s.selection_side = selection_side
					s.selection_layer = math.min(ring_sectors,
						math.floor((edge_depth or 0) / edge_ctx.sector_step) + 1)
					ring_sector_pool[#ring_sector_pool + 1] = s
					edge_stats.ring_sector_coverage[tostring(s.id)] = {
						id = s.id, col = s.col, row = s.row, expected_edge = expected_edge,
						planned = SAMPLES_PER_RING_SECTOR, sampled = 0, sector_match = 0,
						accepted = 0, rejected = {},
					}
					for _ = 1, SAMPLES_PER_RING_SECTOR do sampling_plan[#sampling_plan + 1] = s end
				end
			end
		end
		local MAX_SAMPLES = #sampling_plan > 0 and #sampling_plan or BASE_WHOLE_MAP_SAMPLES
		if edge_debug then
			local marker_n = 0
			pcall(map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(marker)
				local mpos = marker and ObjectPos(marker)
				local mx, my
				if mpos and type(mpos.xy) == "function" then mx, my = mpos:xy() end
				if type(mx) ~= "number" or type(my) ~= "number" then return end
				marker_n = marker_n + 1
				local sector = SectorAtPoint(map, mx, my)
				local edge, source_region = DescribeTopUpEdge(edge_ctx, sector, mx, my)
				local target_ring = IsInFinalOuterSectorRing(map, mx, my, ring_sectors)
				local observed_ring = edge ~= "interior"
				TopUpEdgeLog("existing anomaly marker", {
					n = marker_n, marker = tostring(marker), class = tostring(marker.class),
					category = AnomalyCategory(marker), clone = tostring(marker.SuperBigMapQuadrantClone == true),
					x = mx, y = my, sector = tostring(sector and sector.id),
					col = tostring(sector and sector.col), row = tostring(sector and sector.row),
					status = tostring(sector and sector.status), edge = edge, source_region = source_region,
					target_final_ring = tostring(target_ring),
					observed_ring = tostring(observed_ring),
					ring_predicates_agree = tostring(target_ring == observed_ring),
					distance_left = mx, distance_right = tostring(edge_ctx.map_w and (edge_ctx.map_w - mx)),
					distance_top = my, distance_bottom = tostring(edge_ctx.map_h and (edge_ctx.map_h - my)),
					distance_final_right = tostring(edge_ctx.ring_w and (edge_ctx.ring_w - mx)),
					distance_final_bottom = tostring(edge_ctx.ring_h and (edge_ctx.ring_h - my)),
					x_minus_source_edge = tostring(edge_ctx.source_w and (mx - edge_ctx.source_w)),
					y_minus_source_edge = tostring(edge_ctx.source_h and (my - edge_ctx.source_h)),
				})
			end)
			TopUpEdgeLog("top-up target", {
				total_before = total_current, templates = #templates, target = target, shortfall = shortfall,
				area_factor = string.format("%.3f", area_factor), max_samples = MAX_SAMPLES,
				max_pool = MAX_POOL, low_area_percent = low_area_percent,
				sampling_mode = surface_edge_ring and "every_final_ring_sector_random" or "whole_map_random",
				ring_sector_count = ring_sector_count,
				samples_per_ring_sector = SAMPLES_PER_RING_SECTOR,
				stage_two_samples_per_selected_sector = STAGE_TWO_AREA_SAMPLES,
				target_ring_w = tostring(edge_ctx.ring_w), target_ring_h = tostring(edge_ctx.ring_h),
				band_world = tostring(edge_ctx.band_world), margin_world = tostring(margin),
			})
		end
		local cached = not surface_edge_ring and CachedTopUpCandidates(map)
		if cached then
			for _, c in ipairs(cached) do
				if not c.used then candidates[#candidates + 1] = c end
			end
			reused_pool = #candidates > 0
		end
		local function random_between(first, past_last)
			first, past_last = math.floor(first), math.floor(past_last)
			local span = past_last - first
			if span <= 0 then return first end
			return first + RandInt(span)
		end
		local function sample_position(sample_n)
			local expected = sampling_plan[sample_n]
			if not expected or not edge_ctx or type(edge_ctx.sector_step) ~= "number" then
				return lo_x + RandInt(span_x), lo_y + RandInt(span_y), "whole_map", nil
			end
			local step = edge_ctx.sector_step
			-- Prefer the live MapSector box. The arithmetic fallback is valid for the current
			-- zero-border 20x20 layout, while the live bounds also keep this sampler correct if a
			-- scenario supplies a border or a non-uniform final sector layout.
			local x0 = expected.area_x0 or ((expected.col - edge_ctx.min_col) * step)
			local y0 = expected.area_y0 or ((expected.row - edge_ctx.min_row) * step)
			local x1 = math.min(edge_ctx.ring_w - margin, expected.area_x1 or (x0 + step))
			local y1 = math.min(edge_ctx.ring_h - margin, expected.area_y1 or (y0 + step))
			x0 = math.max(margin, x0)
			y0 = math.max(margin, y0)
			return random_between(x0, x1), random_between(y0, y1), expected.expected_edge, expected
		end
		local terrain_api = Global("terrain")
		for sample_n = 1, reused_pool and 0 or MAX_SAMPLES do
			local x, y, sampled_side, expected_sector = sample_position(sample_n)
			local sector = SectorAtPoint(map, x, y)
			local candidate_edge, candidate_source_region
			if edge_ctx then
				candidate_edge, candidate_source_region = DescribeTopUpEdge(edge_ctx, sector, x, y)
			end
			local in_target_area = not surface_edge_ring or IsInFinalOuterSectorRing(map, x, y, ring_sectors)
			local scanned = sector and SectorIsScanned(sector) or false
			local passable, can_receive, buildable, unobstructed = false, false, false, false
			local valley_score, flatness, terrain_z, restriction_tier = 0, 0, nil, nil
			local coverage = expected_sector
				and edge_stats.ring_sector_coverage[tostring(expected_sector.id)] or nil
			if coverage then coverage.sampled = coverage.sampled + 1 end
			local sector_matches_plan = not expected_sector or (sector
				and sector.id == expected_sector.id
				and sector.col == expected_sector.col and sector.row == expected_sector.row)
			if coverage and sector_matches_plan then coverage.sector_match = coverage.sector_match + 1 end
			local rejection
			if not sector then
				rejection = "no_sector"
			elseif not sector_matches_plan then
				rejection = "sector_mapping_mismatch"
			elseif not IsUndergroundMap(map) and scanned then
				rejection = "sector_scanned"
			elseif not in_target_area then
				rejection = "outside_target_final_ring"
			else
				local pt = point(x, y)
				passable = PassableAt(map, pt)
				flatness = FlatnessAt(map, pt) or 0
				can_receive = surface_edge_ring
					and passable and flatness >= FLATNESS_MIN or CanReceiveDeposit(map, pt)
				buildable = not surface_edge_ring or IsBuildableAt(map, pt, true)
				unobstructed = not surface_edge_ring or IsUnobstructedAt(map, pt, true)
				if surface_edge_ring and not passable then
					rejection = "not_passable"
				elseif not surface_edge_ring and not can_receive then
					rejection = "not_passable_or_too_steep"
				elseif surface_edge_ring and not unobstructed then
					rejection = "build_obstructed"
				else
					if surface_edge_ring then
						-- Buildability and slope are stage-two preferences. They must not remove
						-- difficult sectors from the stage-one sector lottery.
						restriction_tier = buildable and (can_receive and 1 or 2)
							or (can_receive and 3 or 4)
						if type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function" then
							local ok_h, h = pcall(terrain_api.GetHeight, map, pt)
							if ok_h and type(h) == "number" then terrain_z = h end
						end
					end
					local perimeter_u, nearest_side, edge_depth = PerimeterCoordinate(edge_ctx, x, y)
					local layer = surface_edge_ring and type(edge_ctx.sector_step) == "number"
						and math.min(ring_sectors, math.floor((edge_depth or 0) / edge_ctx.sector_step) + 1)
						or nil
					candidates[#candidates + 1] = {
						x = x, y = y, valley_score = valley_score, passable = passable,
						flatness = flatness, buildable = buildable, unobstructed = unobstructed,
						terrain_z = terrain_z, restriction_tier = restriction_tier,
						edge = candidate_edge, source_region = candidate_source_region,
						sector_id = sector and sector.id, col = sector and sector.col,
						row = sector and sector.row, sample_n = sample_n,
						sampled_side = sampled_side, expected_sector_id = expected_sector and expected_sector.id,
						perimeter_u = perimeter_u, nearest_side = nearest_side,
						edge_depth = edge_depth, layer = layer,
					}
				end
			end
			if coverage then
				if rejection then
					IncrementTally(coverage.rejected, rejection)
				else
					coverage.accepted = coverage.accepted + 1
				end
			end
			if edge_debug then
				local edge, source_region = candidate_edge, candidate_source_region
				local observed_ring = edge ~= "interior"
				local perimeter_u, nearest_side, edge_depth = PerimeterCoordinate(edge_ctx, x, y)
				local comparison = "target_" .. tostring(in_target_area)
					.. "_observed_" .. tostring(observed_ring)
				IncrementTally(edge_stats.ring_predicate_comparison, comparison)
				IncrementTally(edge_stats.sampled_by_edge, edge)
				IncrementTally(edge_stats.sampled_by_planned_ring_edge, sampled_side)
				IncrementTally(edge_stats.sampled_by_source_region, source_region)
				if rejection then
					IncrementTally(edge_stats.rejected_by_reason, rejection)
				else
					IncrementTally(edge_stats.accepted_by_edge, edge)
					IncrementTally(edge_stats.accepted_by_sector, sector and sector.id)
					IncrementTally(edge_stats.accepted_by_exclusive_side, nearest_side)
					local layer = type(edge_depth) == "number" and type(edge_ctx.sector_step) == "number"
						and math.min(ring_sectors, math.floor(edge_depth / edge_ctx.sector_step) + 1) or "?"
					IncrementTally(edge_stats.accepted_by_side_layer, tostring(nearest_side) .. "/L" .. tostring(layer))
				end
				-- Independent read-only terrain probes run even for samples rejected by the ring
				-- predicate, so a missing edge can be separated from genuinely unusable mountains.
				local debug_pt = point(x, y)
				local debug_passable = PassableAt(map, debug_pt)
				local debug_flatness = FlatnessAt(map, debug_pt)
				local debug_buildable = IsBuildableAt(map, debug_pt)
				local debug_terrain_type = TerrainTypeAt(map, debug_pt)
				local debug_height
				local terrain_api = Global("terrain")
				if type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function" then
					local ok_h, h = pcall(terrain_api.GetHeight, map, debug_pt)
					if ok_h then debug_height = h end
				end
				TopUpEdgeLog("candidate sample", {
					n = sample_n, x = x, y = y, sector = tostring(sector and sector.id),
					expected_sector = tostring(expected_sector and expected_sector.id),
					expected_col = tostring(expected_sector and expected_sector.col),
					expected_row = tostring(expected_sector and expected_sector.row),
					sector_matches_plan = tostring(sector_matches_plan),
					sampled_side = tostring(sampled_side),
					col = tostring(sector and sector.col), row = tostring(sector and sector.row),
					status = tostring(sector and sector.status), edge = edge, source_region = source_region,
					target_final_ring = tostring(in_target_area),
					observed_ring = tostring(observed_ring),
					ring_predicates_agree = tostring(in_target_area == observed_ring), scanned = tostring(scanned),
					can_receive = tostring(can_receive), buildable = tostring(buildable),
					unobstructed = tostring(unobstructed),
					terrain_passable = tostring(debug_passable), terrain_flatness = tostring(debug_flatness),
					terrain_buildable = tostring(debug_buildable), terrain_type = tostring(debug_terrain_type),
					terrain_z = tostring(debug_height), restriction_tier = tostring(restriction_tier),
					valley_score = valley_score, accepted = tostring(rejection == nil),
					perimeter_u = tostring(perimeter_u), nearest_side = tostring(nearest_side),
					edge_depth = tostring(edge_depth),
					rejection = tostring(rejection or "none"), pool_after = #candidates,
					distance_left = x, distance_right = tostring(edge_ctx.map_w and (edge_ctx.map_w - x)),
					distance_top = y, distance_bottom = tostring(edge_ctx.map_h and (edge_ctx.map_h - y)),
					distance_final_right = tostring(edge_ctx.ring_w and (edge_ctx.ring_w - x)),
					distance_final_bottom = tostring(edge_ctx.ring_h and (edge_ctx.ring_h - y)),
					x_minus_source_edge = tostring(edge_ctx.source_w and (x - edge_ctx.source_w)),
					y_minus_source_edge = tostring(edge_ctx.source_h and (y - edge_ctx.source_h)),
				})
			end
		end
		pool_final = #candidates
		ProfileStep("anomaly candidate pool ready", {
			candidates = pool_final, reused = reused_pool,
		}, map)
		-- Surface extras keep the dedicated outer-ring sector/side/layer scheduler. Underground
		-- extras use the shared capacity-normalized selector across reachable cave-floor sectors.
		local whole_map_selector = not surface_edge_ring
			and NewSectorBalancedCandidateSelector(map, candidates,
				IsUndergroundMap(map) and "underground anomalies" or "surface anomalies") or nil
		-- Stage one chooses sectors, not points. A randomized four-placement cycle covers every
		-- physical side, while shuffled along-side bins and depth layers keep the whole three-sector
		-- ring eligible. Terrain quality is deliberately ignored until after a sector has won.
		local side_cycle = { "top", "right", "bottom", "left" }
		local function shuffle_side_cycle()
			for i = #side_cycle, 2, -1 do
				local j = RandInt(i) + 1
				side_cycle[i], side_cycle[j] = side_cycle[j], side_cycle[i]
			end
		end
		if edge_debug then
			local counts = { left = 0, top = 0, right = 0, bottom = 0 }
			local spans = {
				left = { min = nil, max = nil }, top = { min = nil, max = nil },
				right = { min = nil, max = nil }, bottom = { min = nil, max = nil },
			}
			for _, candidate in ipairs(candidates) do
				for _, side in ipairs({ "left", "top", "right", "bottom" }) do
					if candidate.nearest_side == side then
						counts[side] = counts[side] + 1
						local along = (side == "left" or side == "right") and candidate.y or candidate.x
						spans[side].min = spans[side].min and math.min(spans[side].min, along) or along
						spans[side].max = spans[side].max and math.max(spans[side].max, along) or along
					end
				end
			end
			TopUpEdgeLog("accepted candidate pool EXCLUSIVE side coverage", {
				pool = #candidates, left = counts.left, top = counts.top,
				right = counts.right, bottom = counts.bottom,
				left_y_span = tostring(spans.left.min) .. ".." .. tostring(spans.left.max),
				top_x_span = tostring(spans.top.min) .. ".." .. tostring(spans.top.max),
				right_y_span = tostring(spans.right.min) .. ".." .. tostring(spans.right.max),
				bottom_x_span = tostring(spans.bottom.min) .. ".." .. tostring(spans.bottom.max),
				target_final_w = tostring(edge_ctx.ring_w), target_final_h = tostring(edge_ctx.ring_h),
			})
		end
		-- Precompute the randomized side quota, then subdivide each side into that many broad
		-- along-side bins. One random SECTOR is selected from every shuffled bin before a bin is
		-- reused. A corner has exactly one owner and cannot satisfy two different side quotas.
		local placement_side_schedule = {}
		local side_totals = { top = 0, right = 0, bottom = 0, left = 0 }
		local side_bin_order, side_layer_order, side_occurrence = {}, {}, {}
		if surface_edge_ring then
			for placement_n = 1, shortfall do
				local side_i = ((placement_n - 1) % #side_cycle) + 1
				if side_i == 1 then shuffle_side_cycle() end
				local side = side_cycle[side_i]
				placement_side_schedule[placement_n] = side
				side_totals[side] = side_totals[side] + 1
			end
			for _, side in ipairs({ "top", "right", "bottom", "left" }) do
				local total = side_totals[side]
				local bins, layers = {}, {}
				for i = 1, total do
					bins[i] = i
					layers[i] = ((i - 1) % math.max(1, ring_sectors)) + 1
				end
				for i = total, 2, -1 do
					local j = RandInt(i) + 1
					bins[i], bins[j] = bins[j], bins[i]
				end
				-- Shuffle each complete layer cycle independently, so every side uses all three depths
				-- before repeating while not imposing a fixed outside-to-inside order.
				for first = 1, total, math.max(1, ring_sectors) do
					local last = math.min(total, first + math.max(1, ring_sectors) - 1)
					for i = last, first + 1, -1 do
						local j = first + RandInt(i - first + 1)
						layers[i], layers[j] = layers[j], layers[i]
					end
				end
				side_bin_order[side], side_layer_order[side], side_occurrence[side] = bins, layers, 0
			end
		end
		local function along_index(candidate, side)
			if side == "top" or side == "bottom" then
				return (candidate.col or edge_ctx.min_col) - edge_ctx.min_col + 1, edge_ctx.cols
			end
			return (candidate.row or edge_ctx.min_row) - edge_ctx.min_row + 1, edge_ctx.rows
		end
		local function candidate_bin(candidate, side, bin_count)
			local along, along_count = along_index(candidate, side)
			return math.min(bin_count, math.max(1,
				math.floor(((along - 1) * bin_count) / math.max(1, along_count)) + 1))
		end
		if edge_debug and surface_edge_ring then
			TopUpEdgeLog("coverage-aware selection side quotas", {
				top = side_totals.top, right = side_totals.right,
				bottom = side_totals.bottom, left = side_totals.left,
			})
			for _, side in ipairs({ "top", "right", "bottom", "left" }) do
				local bin_count = math.max(1, side_totals[side])
				for occurrence = 1, side_totals[side] do
					local target_bin = side_bin_order[side][occurrence]
					local target_layer = side_layer_order[side][occurrence]
					local by_layer, total = {}, 0
					local min_along, max_along
					for _, candidate in ipairs(ring_sector_pool) do
						if candidate.selection_side == side
							and candidate_bin(candidate, side, bin_count) == target_bin then
							total = total + 1
							IncrementTally(by_layer, candidate.selection_layer)
							local along = (side == "left" or side == "right") and candidate.row or candidate.col
							min_along = min_along and math.min(min_along, along) or along
							max_along = max_along and math.max(max_along, along) or along
						end
					end
					TopUpEdgeLog("selection bin exhaustive inventory", {
						side = side, occurrence = occurrence, side_quota = side_totals[side],
						target_bin = target_bin, target_layer = target_layer,
						sector_count = total, sectors_by_layer = TallyString(by_layer),
						along_sector_span = tostring(min_along) .. ".." .. tostring(max_along),
					})
				end
			end
		end
		local candidates_by_sector = {}
		for _, candidate in ipairs(candidates) do
			local key = tostring(candidate.sector_id)
			local list = candidates_by_sector[key]
			if not list then list = {}; candidates_by_sector[key] = list end
			list[#list + 1] = candidate
		end
		local available_sectors = {}
		for _, sector in ipairs(ring_sector_pool) do available_sectors[#available_sectors + 1] = sector end
		local world_to_hex = Global("WorldToHex")
		local function anomaly_hex_key(x, y)
			if type(world_to_hex) == "function" then
				local ok_h, q, r = pcall(world_to_hex, point(x, y))
				if ok_h and type(q) == "number" and type(r) == "number" then
					return tostring(q) .. ":" .. tostring(r)
				end
			end
			return tostring(math.floor(x / math.max(1, tile))) .. ":"
				.. tostring(math.floor(y / math.max(1, tile)))
		end
		local reserved_anomaly_hexes = {}
		pcall(map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(marker)
			local pos = marker and ObjectPos(marker)
			if pos and type(pos.xy) == "function" then
				local x, y = pos:xy()
				if type(x) == "number" and type(y) == "number" then
					reserved_anomaly_hexes[anomaly_hex_key(x, y)] = true
				end
			end
		end)
		-- Stage two first keeps the least restrictive terrain class available in the selected
		-- sector, then randomly chooses from the configured lowest percentage of that class. Tiers are:
		-- 1 buildable+flat, 2 buildable+steep, 3 unbuildable+flat, 4 unbuildable+steep.
		-- Every tier is still passable and unobstructed because those are hard safety requirements.
		local stage_two_sample_n = MAX_SAMPLES
		local function sample_selected_sector_area(sector, source)
			local step = edge_ctx.sector_step
			local x0 = math.max(margin, sector.area_x0 or ((sector.col - edge_ctx.min_col) * step))
			local y0 = math.max(margin, sector.area_y0 or ((sector.row - edge_ctx.min_row) * step))
			local x1 = math.min(edge_ctx.ring_w - margin, sector.area_x1 or (x0 + step))
			local y1 = math.min(edge_ctx.ring_h - margin, sector.area_y1 or (y0 + step))
			for area_sample = 1, STAGE_TWO_AREA_SAMPLES do
				stage_two_sample_n = stage_two_sample_n + 1
				local x, y = random_between(x0, x1), random_between(y0, y1)
				local live_sector = SectorAtPoint(map, x, y)
				local pt = point(x, y)
				local passable = PassableAt(map, pt)
				local unobstructed = passable and IsUnobstructedAt(map, pt, true) or false
				local rejection
				if not live_sector or live_sector.id ~= sector.id then rejection = "sector_mapping_mismatch"
				elseif SectorIsScanned(live_sector) then rejection = "sector_scanned"
				elseif not IsInFinalOuterSectorRing(map, x, y, ring_sectors) then rejection = "outside_target_final_ring"
				elseif not passable then rejection = "not_passable"
				elseif not unobstructed then rejection = "build_obstructed" end
				local flatness, buildable, can_receive, terrain_z, restriction_tier
				if not rejection then
					flatness = FlatnessAt(map, pt) or 0
					buildable = IsBuildableAt(map, pt, true)
					can_receive = flatness >= FLATNESS_MIN
					restriction_tier = buildable and (can_receive and 1 or 2)
						or (can_receive and 3 or 4)
					if type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function" then
						local ok_h, h = pcall(terrain_api.GetHeight, map, pt)
						if ok_h and type(h) == "number" then terrain_z = h end
					end
					local candidate_edge, source_region = DescribeTopUpEdge(edge_ctx, live_sector, x, y)
					local perimeter_u, nearest_side, edge_depth = PerimeterCoordinate(edge_ctx, x, y)
					local candidate = {
						x = x, y = y, passable = true, can_receive = can_receive,
						flatness = flatness, buildable = buildable, unobstructed = true,
						terrain_z = terrain_z, restriction_tier = restriction_tier, valley_score = 0,
						edge = candidate_edge, source_region = source_region,
						sector_id = live_sector.id, col = live_sector.col, row = live_sector.row,
						sample_n = stage_two_sample_n, stage_two_sample = area_sample,
						sampled_side = sector.expected_edge, expected_sector_id = sector.id,
						perimeter_u = perimeter_u, nearest_side = nearest_side,
						edge_depth = edge_depth, layer = sector.selection_layer,
					}
					candidates[#candidates + 1] = candidate
					source[#source + 1] = candidate
				end
				if edge_debug then
					TopUpEdgeLog("stage-two selected-sector area sample", {
						sector = tostring(sector.id), col = tostring(sector.col), row = tostring(sector.row),
						area_sample = area_sample, x = x, y = y, accepted = tostring(rejection == nil),
						passable = tostring(passable), unobstructed = tostring(unobstructed),
						buildable = tostring(buildable), flatness = tostring(flatness),
						terrain_z = tostring(terrain_z), restriction_tier = tostring(restriction_tier),
						rejection = tostring(rejection or "none"),
					})
				end
			end
		end
		local function area_candidate_for_sector(sector)
			local sector_key = tostring(sector and sector.id)
			local source = candidates_by_sector[sector_key]
			if not source then source = {}; candidates_by_sector[sector_key] = source end
			-- These samples happen only after stage one has selected the sector.
			sample_selected_sector_area(sector, source)
			local eligible, seen = {}, {}
			local best_tier
			for _, candidate in ipairs(source) do
				local key = anomaly_hex_key(candidate.x, candidate.y)
				local tier = candidate.restriction_tier or 4
				if not candidate.used and not seen[key] and not reserved_anomaly_hexes[key] then
					seen[key] = true
					if best_tier == nil or tier < best_tier then
						best_tier, eligible = tier, { candidate }
					elseif tier == best_tier then
						eligible[#eligible + 1] = candidate
					end
				end
			end
			if #eligible == 0 then return nil, nil, nil, 0, 0, #source end
			table.sort(eligible, function(a, b)
				local az = type(a.terrain_z) == "number" and a.terrain_z or 2147483647
				local bz = type(b.terrain_z) == "number" and b.terrain_z or 2147483647
				if az ~= bz then return az < bz end
				return (a.sample_n or 0) < (b.sample_n or 0)
			end)
			local low_count = math.max(1, math.ceil(#eligible * (low_area_percent + 0.0) / 100))
			local winner = eligible[RandInt(low_count) + 1]
			local key = anomaly_hex_key(winner.x, winner.y)
			winner.valley_score = ValleyScore(map, point(winner.x, winner.y))
			return winner, key, best_tier, low_count, #eligible, #source
		end
		local function coverage_sector_index(side, target_bin, target_layer)
			local bin_count = math.max(1, side_totals[side])
			local function collect(require_bin, require_layer, max_bin_distance)
				local matching = {}
				for i, candidate in ipairs(available_sectors) do
					if candidate.selection_side == side then
						local bin = candidate_bin(candidate, side, bin_count)
						local bin_ok = not require_bin or bin == target_bin
						if max_bin_distance ~= nil then bin_ok = math.abs(bin - target_bin) <= max_bin_distance end
						local layer_ok = not require_layer or candidate.selection_layer == target_layer
						if bin_ok and layer_ok then matching[#matching + 1] = i end
					end
				end
				return matching
			end
			local matching = collect(true, true)
			local scope, fallback_distance = "exact_side_bin_layer", 0
			if #matching == 0 then
				matching, scope = collect(true, false), "same_bin_any_layer"
			end
			if #matching == 0 then
				for distance = 1, bin_count - 1 do
					matching = collect(false, true, distance)
					if #matching > 0 then
						scope, fallback_distance = "nearest_bin_same_layer", distance
						break
					end
				end
			end
			if #matching == 0 then
				for distance = 1, bin_count - 1 do
					matching = collect(false, false, distance)
					if #matching > 0 then
						scope, fallback_distance = "nearest_bin_any_layer", distance
						break
					end
				end
			end
			if #matching == 0 then matching, scope = collect(false, false), "same_side_anywhere" end
			if #matching == 0 then
				local whole = {}
				for i = 1, #available_sectors do whole[#whole + 1] = i end
				matching, scope = whole, "whole_ring_no_owned_sector"
			end
			local winner = #matching > 0 and matching[RandInt(#matching) + 1] or nil
			local actual = winner and available_sectors[winner]
			return winner, scope, #matching, fallback_distance,
				actual and candidate_bin(actual, side, bin_count), actual and actual.selection_layer
		end
		local function choose_needed_kind()
			local deficit_total = 0
			for _, kind in ipairs(target_keys) do
				deficit_total = deficit_total + math.max(0,
					(target_by_kind[kind] or 0) - (current_by_kind[kind] or 0) - (added_by_kind[kind] or 0))
			end
			if deficit_total <= 0 then return nil end
			local pick = RandInt(deficit_total)
			for _, kind in ipairs(target_keys) do
				local deficit = math.max(0,
					(target_by_kind[kind] or 0) - (current_by_kind[kind] or 0) - (added_by_kind[kind] or 0))
				if pick < deficit then return kind end
				pick = pick - deficit
			end
			return nil
		end
		local placement_n = 1
		while placement_n <= shortfall do
			placement_attempts = placement_attempts + 1
			if (surface_edge_ring and #available_sectors == 0)
				or (not surface_edge_ring and whole_map_selector.Remaining() == 0) then break end
			local preferred_side = surface_edge_ring and placement_side_schedule[placement_n] or nil
			local occurrence = preferred_side and (side_occurrence[preferred_side] + 1) or nil
			local target_bin = preferred_side and side_bin_order[preferred_side][occurrence] or nil
			local target_layer = preferred_side and side_layer_order[preferred_side][occurrence] or nil
			local c, ci, selection_scope, matching_count, fallback_distance, actual_bin, actual_layer
			local selected_sector, reserved_key, restriction_tier, low_area_count, tier_area_count, sector_area_count
			if surface_edge_ring then
				-- A sector is drawn first. Only afterwards do we inspect that sector's terrain.
				-- If it has no passable, unobstructed sampled hex, log it and draw another sector;
				-- terrain quality never influences which sector wins an individual draw.
				while not c and #available_sectors > 0 do
					local sector_i
					sector_i, selection_scope, matching_count, fallback_distance, actual_bin, actual_layer =
						coverage_sector_index(preferred_side, target_bin, target_layer)
					if not sector_i then break end
					selected_sector = available_sectors[sector_i]
					table.remove(available_sectors, sector_i)
					c, reserved_key, restriction_tier, low_area_count, tier_area_count, sector_area_count =
						area_candidate_for_sector(selected_sector)
					if edge_debug then
						TopUpEdgeLog("stage-one ring sector selected", {
							placement = placement_n, sector = tostring(selected_sector.id),
							col = tostring(selected_sector.col), row = tostring(selected_sector.row),
							preferred_side = tostring(preferred_side), sector_side = tostring(selected_sector.selection_side),
							target_bin = tostring(target_bin), target_layer = tostring(target_layer),
							actual_bin = tostring(actual_bin), actual_layer = tostring(actual_layer),
							selection_scope = tostring(selection_scope), matching_sector_count = matching_count,
							fallback_bin_distance = tostring(fallback_distance),
							sector_area_candidates = sector_area_count, viable = tostring(c ~= nil),
							remaining_unselected_sectors = #available_sectors,
						})
					end
				end
				if not c then break end
				reserved_anomaly_hexes[reserved_key] = true
				c.used = true
			else
				matching_count = whole_map_selector.Remaining()
				selection_scope = "capacity_balanced_whole_map"
				c = whole_map_selector.Take()
				if not c then break end
			end
			if edge_debug then
				IncrementTally(edge_stats.selected_by_edge, c.edge)
				IncrementTally(edge_stats.selected_by_sector, c.sector_id)
				IncrementTally(edge_stats.selected_by_target_side, preferred_side)
				IncrementTally(edge_stats.selected_by_nearest_side,
					selected_sector and selected_sector.selection_side or c.nearest_side)
				IncrementTally(edge_stats.selected_by_side_layer,
					tostring(selected_sector and selected_sector.selection_side or c.nearest_side)
						.. "/L" .. tostring(actual_layer or c.layer or "?"))
				IncrementTally(edge_stats.selected_by_scope, selection_scope)
				TopUpEdgeLog("stage-two low-area candidate selected", {
					placement = placement_n, candidate_index = ci, sample_n = tostring(c.sample_n),
					sampled_side = tostring(c.sampled_side),
					x = c.x, y = c.y, sector = tostring(c.sector_id), col = tostring(c.col), row = tostring(c.row),
					edge = tostring(c.edge), source_region = tostring(c.source_region),
					valley_score = c.valley_score, terrain_z = tostring(c.terrain_z),
					flatness = tostring(c.flatness), buildable = tostring(c.buildable),
					restriction_tier = tostring(restriction_tier or c.restriction_tier),
					low_area_random_pool = tostring(low_area_count), tier_area_candidates = tostring(tier_area_count),
					sector_area_candidates = tostring(sector_area_count), reserved_hex = tostring(reserved_key),
					pool_remaining = surface_edge_ring and #available_sectors or #candidates,
					preferred_side = tostring(preferred_side),
					target_bin = tostring(target_bin), target_layer = tostring(target_layer),
					actual_bin = tostring(actual_bin), actual_layer = tostring(actual_layer),
					fallback_bin_distance = tostring(fallback_distance),
					candidate_perimeter_u = tostring(c.perimeter_u),
					nearest_side = tostring(c.nearest_side), edge_depth = tostring(c.edge_depth),
					selection_scope = selection_scope, matching_sector_count = matching_count,
				})
			end
			local needed_kind = choose_needed_kind()
			local kind_templates = needed_kind and standard_templates_by_kind[needed_kind] or nil
			-- FreeTech may have no source marker at all. Any anomaly marker is a
			-- valid structural template; its reward category is rewritten below.
			local fallback_templates = standard_templates
			if #fallback_templates == 0 then break end
			local template = kind_templates and kind_templates[RandInt(#kind_templates) + 1]
				or fallback_templates[RandInt(#fallback_templates) + 1]
			local event_sequence, event_sequence_list
			if needed_kind == "sequence" then
				event_sequence, event_sequence_list = take_event_scenario(template)
				if not event_sequence then break end
			end
			local tpos = ObjectPos(template)
			local placement_succeeded = false
			if tpos and type(tpos.xy) == "function" then
				local tx, ty = tpos:xy()
				local clone = clone_fn(map, template, point(c.x - tx, c.y - ty, 0))
				if clone and type(clone) == "table" then
					placement_succeeded = true
					if whole_map_selector then whole_map_selector.Commit(c) end
					added = added + 1
					if needed_kind == "complete" or needed_kind == "unlock" then
						clone.tech_action = needed_kind
						clone.sequence = ""
						clone.sequence_list = ""
					elseif needed_kind == "sequence" then
						clone.tech_action = false
						clone.sequence = event_sequence
						clone.sequence_list = event_sequence_list
					end
					added_by_kind[needed_kind] = (added_by_kind[needed_kind] or 0) + 1
					clone.SuperBigMapAnomalyTopUp = true
					clone.SuperBigMapEdgeTopUp = surface_edge_ring or nil
					clone.SuperBigMapEdgeTopUpPlacement = surface_edge_ring and placement_n or nil
					clone.SuperBigMapEdgeTopUpPreferredSide = surface_edge_ring and preferred_side or nil
					clone.SuperBigMapEdgeTopUpTargetBin = surface_edge_ring and target_bin or nil
					clone.SuperBigMapEdgeTopUpTargetLayer = surface_edge_ring and target_layer or nil
					clone.SuperBigMapEdgeTopUpActualBin = surface_edge_ring and actual_bin or nil
					clone.SuperBigMapEdgeTopUpActualLayer = surface_edge_ring and actual_layer or nil
					clone.SuperBigMapEdgeTopUpSelectionScope = surface_edge_ring and selection_scope or nil
					clone.SuperBigMapEdgeTopUpSelectedSector = surface_edge_ring
						and selected_sector and selected_sector.id or nil
					clone.SuperBigMapEdgeTopUpRestrictionTier = surface_edge_ring and restriction_tier or nil
					clone.SuperBigMapEdgeTopUpTerrainZ = surface_edge_ring and c.terrain_z or nil
					clone.SuperBigMapEdgeTopUpLowAreaPool = surface_edge_ring and low_area_count or nil
					clone.SuperBigMapEdgeTopUpReservedHex = surface_edge_ring and reserved_key or nil
					added_markers[#added_markers + 1] = clone
					local cat = AnomalyCategory(clone)
					local reward_family = AnomalyRewardFamily(clone)
					clone.SuperBigMapAnomalyTopUpRewardFamily = reward_family
					added_by_cat[cat] = (added_by_cat[cat] or 0) + 1
					added_by_reward[reward_family] = (added_by_reward[reward_family] or 0) + 1
					if edge_debug then
						IncrementTally(edge_stats.added_by_edge, c.edge)
						IncrementTally(edge_stats.added_by_sector, c.sector_id)
					end
					if type(clone.SetPos) == "function" then
						local pt = point(c.x, c.y)
						if type(pt.SetTerrainZ) == "function" then
							local ok, snapped = pcall(pt.SetTerrainZ, pt, map)
							if ok and snapped then pt = snapped end
						end
						pcall(clone.SetPos, clone, pt)
					end
					-- ProcessClone resets is_placed only for RESOURCE markers; anomaly-marker
					-- clones must be reset here (a start-sector template may already be placed).
					clone.is_placed = false
					clone.placed_obj = false
					SetRevealedState(clone, false)
					-- Surface: hidden until its sector is scanned; registered so the scan
					-- reveals it. Underground: NO sector dependence -- the unplaced marker is
					-- placed+revealed by vanilla's proximity DepositRevealer instead.
					if not IsUndergroundMap(map) then
						local sec = SectorAtPoint(map, c.x, c.y)
						local registered = false
						if sec and type(sec.RegisterDeposit) == "function" then
							registered = pcall(sec.RegisterDeposit, sec, clone) == true
						end
						if edge_debug then
							TopUpEdgeLog("placement clone result", {
								placement = placement_n, clone = tostring(clone), clone_ok = "true",
								template = tostring(template), category = cat, reward_family = reward_family,
								x = c.x, y = c.y,
								sector = tostring(sec and sec.id), col = tostring(sec and sec.col), row = tostring(sec and sec.row),
								edge = tostring(c.edge), source_region = tostring(c.source_region),
								registered = tostring(registered), added_total = added,
							})
						end
					end
				else
					clone_failures = clone_failures + 1
					if edge_debug then
						TopUpEdgeLog("placement clone result", {
							placement = placement_n, clone = tostring(clone), clone_ok = "false",
							template = tostring(template), category = AnomalyCategory(template),
							x = c.x, y = c.y, sector = tostring(c.sector_id), edge = tostring(c.edge),
						})
					end
				end
			else
				clone_failures = clone_failures + 1
				if edge_debug then
					TopUpEdgeLog("placement clone skipped", {
						placement = placement_n, reason = "template_position_unavailable",
						template = tostring(template), x = c.x, y = c.y, sector = tostring(c.sector_id),
						edge = tostring(c.edge),
					})
				end
			end
			if placement_succeeded then
				if preferred_side then side_occurrence[preferred_side] = occurrence end
				placement_n = placement_n + 1
			end
		end
		if whole_map_selector then whole_map_placement_stats = whole_map_selector.Stats() end
	end)
	if edge_debug then
		for n, clone in ipairs(added_markers) do
			local pos = ObjectPos(clone)
			local x, y
			if pos and type(pos.xy) == "function" then x, y = pos:xy() end
			if type(x) == "number" and type(y) == "number" then
				local sector = SectorAtPoint(map, x, y)
				local edge, source_region = DescribeTopUpEdge(edge_ctx, sector, x, y)
				local perimeter_u, nearest_side, edge_depth = PerimeterCoordinate(edge_ctx, x, y)
				local layer = type(edge_depth) == "number" and type(edge_ctx.sector_step) == "number"
					and math.min(ring_sectors, math.floor(edge_depth / edge_ctx.sector_step) + 1) or "?"
				local registered = false
				if sector and type(sector.GetDepositList) == "function" then
					local ok_list, list = pcall(sector.GetDepositList, sector, clone)
					if ok_list and type(list) == "table" then
						registered = list[clone] == true
						if not registered then
							for _, marker in ipairs(list) do
								if marker == clone then registered = true; break end
							end
						end
					end
				end
				IncrementTally(edge_stats.final_by_edge, edge)
				IncrementTally(edge_stats.final_by_nearest_side, nearest_side)
				IncrementTally(edge_stats.final_by_side_layer,
					tostring(nearest_side) .. "/L" .. tostring(layer))
				IncrementTally(edge_stats.final_by_sector, sector and sector.id)
				TopUpEdgeLog("final live clone audit", {
					n = n, clone = tostring(clone), placement = tostring(clone.SuperBigMapEdgeTopUpPlacement),
					x = x, y = y, sector = tostring(sector and sector.id), col = tostring(sector and sector.col),
					row = tostring(sector and sector.row), status = tostring(sector and sector.status),
					edge = edge, nearest_side = nearest_side, edge_depth = tostring(edge_depth), layer = tostring(layer),
					perimeter_u = tostring(perimeter_u),
					preferred_side = tostring(clone.SuperBigMapEdgeTopUpPreferredSide),
					target_bin = tostring(clone.SuperBigMapEdgeTopUpTargetBin),
					target_layer = tostring(clone.SuperBigMapEdgeTopUpTargetLayer),
					actual_bin = tostring(clone.SuperBigMapEdgeTopUpActualBin),
					actual_layer = tostring(clone.SuperBigMapEdgeTopUpActualLayer),
					selection_scope = tostring(clone.SuperBigMapEdgeTopUpSelectionScope),
					source_region = source_region,
					in_target_final_ring = tostring(IsInFinalOuterSectorRing(map, x, y, ring_sectors)),
					distance_to_final_right = tostring(edge_ctx.ring_w and (edge_ctx.ring_w - x)),
					distance_to_final_bottom = tostring(edge_ctx.ring_h and (edge_ctx.ring_h - y)),
					registered = tostring(registered), is_placed = tostring(clone.is_placed),
					revealed = tostring(clone.revealed), placed_obj = tostring(clone.placed_obj),
				})
			end
		end
		local ring_sectors_audited, ring_sectors_fully_sampled = 0, 0
		local ring_sectors_with_candidates, ring_sectors_selected, ring_sectors_final = 0, 0, 0
		local matrix_by_row = {}
		for _, s in ipairs(edge_ctx.sectors or {}) do
			local coverage = edge_stats.ring_sector_coverage[tostring(s.id)]
			if coverage then
				ring_sectors_audited = ring_sectors_audited + 1
				if coverage.sampled == coverage.planned and coverage.sector_match == coverage.planned then
					ring_sectors_fully_sampled = ring_sectors_fully_sampled + 1
				end
				local selected = edge_stats.selected_by_sector[tostring(s.id)] or 0
				local added_here = edge_stats.added_by_sector[tostring(s.id)] or 0
				local final_here = edge_stats.final_by_sector[tostring(s.id)] or 0
				if coverage.accepted > 0 then ring_sectors_with_candidates = ring_sectors_with_candidates + 1 end
				if selected > 0 then ring_sectors_selected = ring_sectors_selected + 1 end
				if final_here > 0 then ring_sectors_final = ring_sectors_final + 1 end
				local step = edge_ctx.sector_step or 0
				local x0 = s.area_x0 or ((s.col - edge_ctx.min_col) * step)
				local y0 = s.area_y0 or ((s.row - edge_ctx.min_row) * step)
				local x1 = s.area_x1 or (x0 + step)
				local y1 = s.area_y1 or (y0 + step)
				TopUpEdgeLog("ring sector exhaustive coverage", {
					sector = tostring(s.id), col = s.col, row = s.row, raw_edges = coverage.expected_edge,
					world_x = tostring(x0) .. ".." .. tostring(x1),
					world_y = tostring(y0) .. ".." .. tostring(y1),
					planned = coverage.planned, sampled = coverage.sampled,
					sector_match = coverage.sector_match, accepted = coverage.accepted,
					rejected = TallyString(coverage.rejected), selected = selected,
					clone_added = added_here, final_markers = final_here,
					candidate_status = coverage.accepted > 0 and "eligible"
						or "no_safe_candidate_in_32_random_probes",
				})
				local row = matrix_by_row[s.row]
				if not row then row = {}; matrix_by_row[s.row] = row end
				row[s.col] = tostring(coverage.accepted) .. "/" .. tostring(selected) .. "/" .. tostring(final_here)
			end
		end
		for row_n = edge_ctx.min_row or 1, edge_ctx.max_row or 0 do
			local row = matrix_by_row[row_n]
			if row then
				local cells = {}
				for col_n = edge_ctx.min_col or 1, edge_ctx.max_col or 0 do
					cells[#cells + 1] = row[col_n] or "."
				end
				TopUpEdgeLog("ring coverage matrix row (accepted/selected/final)", {
					row = row_n, cells_col_ascending = table.concat(cells, " "),
				})
			end
		end
		TopUpEdgeLog("ring sector coverage totals", {
			ring_sectors_expected = ring_sector_count, audited = ring_sectors_audited,
			fully_sampled = ring_sectors_fully_sampled,
			with_safe_candidates = ring_sectors_with_candidates,
			without_safe_candidates = ring_sectors_audited - ring_sectors_with_candidates,
			selected_sectors = ring_sectors_selected, final_marker_sectors = ring_sectors_final,
		})
		TopUpEdgeLog("END surface anomaly edge-distribution trace", {
			total_before = total_current, target = target, requested = shortfall, added = added,
			pool_initial = pool_final, sampled_by_edge = TallyString(edge_stats.sampled_by_edge),
			sampled_by_planned_ring_edge = TallyString(edge_stats.sampled_by_planned_ring_edge),
			sampled_by_source_region = TallyString(edge_stats.sampled_by_source_region),
			accepted_by_edge = TallyString(edge_stats.accepted_by_edge),
			accepted_by_exclusive_side = TallyString(edge_stats.accepted_by_exclusive_side),
			accepted_by_side_layer = TallyString(edge_stats.accepted_by_side_layer),
			accepted_by_sector = TallyString(edge_stats.accepted_by_sector),
			rejected_by_reason = TallyString(edge_stats.rejected_by_reason),
			ring_predicate_comparison = TallyString(edge_stats.ring_predicate_comparison),
			selected_by_edge = TallyString(edge_stats.selected_by_edge),
			selected_by_sector = TallyString(edge_stats.selected_by_sector),
			selected_by_target_side = TallyString(edge_stats.selected_by_target_side),
			selected_by_nearest_side = TallyString(edge_stats.selected_by_nearest_side),
			selected_by_side_layer = TallyString(edge_stats.selected_by_side_layer),
			selected_by_scope = TallyString(edge_stats.selected_by_scope),
			added_by_edge = TallyString(edge_stats.added_by_edge),
			added_by_sector = TallyString(edge_stats.added_by_sector),
			final_by_edge = TallyString(edge_stats.final_by_edge),
			final_by_nearest_side = TallyString(edge_stats.final_by_nearest_side),
			final_by_side_layer = TallyString(edge_stats.final_by_side_layer),
			final_by_sector = TallyString(edge_stats.final_by_sector),
		})
	end
	local final_by_kind, remaining_shortfall, excess = {}, 0, 0
	pcall(map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(marker)
		if not marker then return end
		local kind = AnomalyKind(marker)
		final_by_kind[kind] = (final_by_kind[kind] or 0) + 1
	end)
	for _, kind in ipairs(target_keys) do
		local final_count = final_by_kind[kind] or 0
		remaining_shortfall = remaining_shortfall
			+ math.max(0, (target_by_kind[kind] or 0) - final_count)
		excess = excess + math.max(0, final_count - (target_by_kind[kind] or 0))
	end
	Log("topped up anomalies to map-size proportions (post-gen)", {
		area_factor = string.format("%.3f", area_factor),
		total_before = total_current, target = target, added = added, templates = #templates,
		map = tostring(map.name), pool = pool_final,
		reused_pool = reused_pool,
		surface_edge_ring = surface_edge_ring,
		edge_ring_sectors = cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3,
		low_area_percent = low_area_percent,
		target_capture = tostring(map.SuperBigMapAnomalyTargetCapture),
		source_mix = TallyString(src_by_cat),
		target_kind_mix = TallyString(target_by_kind),
		final_kind_mix = TallyString(final_by_kind),
		remaining_shortfall = remaining_shortfall,
		excess = excess,
		placement_attempts = placement_attempts,
		clone_failures = clone_failures,
		added_mix = TallyString(added_by_cat),
		source_reward_families = TallyString(src_by_reward),
		added_reward_families = TallyString(added_by_reward),
		balanced_placement = whole_map_placement_stats and whole_map_placement_stats.balanced,
		eligible_sectors = whole_map_placement_stats and whole_map_placement_stats.eligible_sectors,
		selected_sectors = whole_map_placement_stats and whole_map_placement_stats.selected_sectors,
		selected = whole_map_placement_stats and whole_map_placement_stats.selected,
		remaining_candidates = whole_map_placement_stats
			and whole_map_placement_stats.remaining_candidates,
		max_additions_to_one_sector = whole_map_placement_stats
			and whole_map_placement_stats.max_additions_to_one_sector,
	})
	RecordEnrichmentTopUpAudit(map, "anomalies", {
		complete = remaining_shortfall == 0, remaining_shortfall = remaining_shortfall,
		templates = #templates, target = target, current = total_current + added,
	})
end

IncrementTally = function(tbl, key)
	key = tostring(key or "?")
	tbl[key] = (tbl[key] or 0) + 1
end

-- Build a dual-coordinate description of the live surface grid. Production placement targets
-- the FINAL map perimeter; the original generated bounds remain in the trace only to expose any
-- accidental regression back to the old 614400 right/bottom boundary.
BuildTopUpEdgeDebugContext = function(map, ring_sectors)
	local map_w, map_h, tile = MapWorldSize(map)
	local city = map and map.City
	local ctx = {
		map_w = map_w, map_h = map_h, tile = tile,
		ring = ring_sectors,
		min_col = nil, max_col = nil, min_row = nil, max_row = nil,
		sectors = {},
		source_w = map and map.SuperBigMapSourceWidth,
		source_h = map and map.SuperBigMapSourceHeight,
	}
	if type(ctx.source_w) ~= "number" and type(map.SuperBigMapGeneratorWidthTiles) == "number"
		and type(tile) == "number" then
		ctx.source_w = map.SuperBigMapGeneratorWidthTiles * tile
	end
	if type(ctx.source_h) ~= "number" then ctx.source_h = ctx.source_w end
	local get_step = Global("GetMapSectorTileSize")
	if type(get_step) == "function" then
		local ok_s, step = pcall(get_step, map)
		if ok_s and type(step) == "number" and step > 0 then ctx.sector_step = step end
	end
	local grid = city and city.MapSectors
	if type(grid) == "table" then
		for outer_key, line in pairs(grid) do
			if type(line) == "table" then
				for inner_key, sector in pairs(line) do
					local col, row = type(sector) == "table" and sector.col, type(sector) == "table" and sector.row
					if type(col) == "number" and type(row) == "number" then
						local area_x0, area_y0, area_x1, area_y1
						if sector.area then
							pcall(function()
								local mn, mx = sector.area:min(), sector.area:max()
								area_x0, area_y0 = mn:xy()
								area_x1, area_y1 = mx:xy()
							end)
						end
						ctx.min_col = ctx.min_col == nil and col or math.min(ctx.min_col, col)
						ctx.max_col = ctx.max_col == nil and col or math.max(ctx.max_col, col)
						ctx.min_row = ctx.min_row == nil and row or math.min(ctx.min_row, row)
						ctx.max_row = ctx.max_row == nil and row or math.max(ctx.max_row, row)
						ctx.sectors[#ctx.sectors + 1] = {
							id = sector.id, col = col, row = row, status = sector.status,
							outer_key = outer_key, inner_key = inner_key, sector_ref = sector,
							area_x0 = area_x0, area_y0 = area_y0, area_x1 = area_x1, area_y1 = area_y1,
						}
					end
				end
			end
		end
	end
	table.sort(ctx.sectors, function(a, b)
		if a.row ~= b.row then return a.row < b.row end
		if a.col ~= b.col then return a.col < b.col end
		return tostring(a.id) < tostring(b.id)
	end)
	ctx.cols = ctx.min_col and (ctx.max_col - ctx.min_col + 1) or 0
	ctx.rows = ctx.min_row and (ctx.max_row - ctx.min_row + 1) or 0
	ctx.ring_w = map_w
	ctx.ring_h = map_h
	if not ctx.sector_step and type(map_w) == "number" and ctx.cols > 0 then
		ctx.sector_step = (map_w + 0.0) / ctx.cols
	end
	ctx.band_world = type(ctx.sector_step) == "number" and ring_sectors * ctx.sector_step or nil
	ctx.source_cols = type(ctx.source_w) == "number" and type(ctx.sector_step) == "number"
		and math.floor((ctx.source_w + 0.0) / ctx.sector_step + 0.5) or nil
	ctx.source_rows = type(ctx.source_h) == "number" and type(ctx.sector_step) == "number"
		and math.floor((ctx.source_h + 0.0) / ctx.sector_step + 0.5) or nil
	TopUpEdgeLog("BEGIN surface anomaly edge-distribution trace", {
		map = tostring(map and map.name), map_w = tostring(map_w), map_h = tostring(map_h),
		source_w = tostring(ctx.source_w), source_h = tostring(ctx.source_h), ring_sectors = ring_sectors,
		target_ring_w = tostring(ctx.ring_w), target_ring_h = tostring(ctx.ring_h),
		sector_step = tostring(ctx.sector_step), band_world = tostring(ctx.band_world),
		source_cols = tostring(ctx.source_cols), source_rows = tostring(ctx.source_rows),
		sector_count = #ctx.sectors, min_col = tostring(ctx.min_col), max_col = tostring(ctx.max_col),
		min_row = tostring(ctx.min_row), max_row = tostring(ctx.max_row), cols = ctx.cols, rows = ctx.rows,
		target_final_thresholds = "col<=" .. tostring(ctx.min_col and (ctx.min_col + ring_sectors - 1))
			.. " col>=" .. tostring(ctx.max_col and (ctx.max_col - ring_sectors + 1))
			.. " row<=" .. tostring(ctx.min_row and (ctx.min_row + ring_sectors - 1))
			.. " row>=" .. tostring(ctx.max_row and (ctx.max_row - ring_sectors + 1)),
		original_source_thresholds_diagnostic = "col<=" .. tostring(ring_sectors)
			.. " col>=" .. tostring(ctx.source_cols and (ctx.source_cols - ring_sectors + 1))
			.. " row<=" .. tostring(ring_sectors)
			.. " row>=" .. tostring(ctx.source_rows and (ctx.source_rows - ring_sectors + 1)),
		target_left_world = "0.." .. tostring(ctx.band_world),
		target_right_world = tostring(ctx.ring_w and ctx.band_world and (ctx.ring_w - ctx.band_world))
			.. ".." .. tostring(ctx.ring_w),
		target_top_world = "0.." .. tostring(ctx.band_world),
		target_bottom_world = tostring(ctx.ring_h and ctx.band_world and (ctx.ring_h - ctx.band_world))
			.. ".." .. tostring(ctx.ring_h),
	})
	local probe_margin = math.max(1, math.floor((tile or 1) * 2))
	local corner_probes = {
		{ raw_corner = "x_low_y_low", x = probe_margin, y = probe_margin },
		{ raw_corner = "x_high_y_low", x = (map_w or 0) - probe_margin, y = probe_margin },
		{ raw_corner = "x_low_y_high", x = probe_margin, y = (map_h or 0) - probe_margin },
		{ raw_corner = "x_high_y_high", x = (map_w or 0) - probe_margin, y = (map_h or 0) - probe_margin },
	}
	for _, probe in ipairs(corner_probes) do
		local sector = SectorAtPoint(map, probe.x, probe.y)
		TopUpEdgeLog("raw-world corner to sector orientation probe", {
			raw_corner = probe.raw_corner, x = probe.x, y = probe.y,
			sector = tostring(sector and sector.id), col = tostring(sector and sector.col),
			row = tostring(sector and sector.row),
		})
	end
	for n, s in ipairs(ctx.sectors) do
		TopUpEdgeLog("sector topology", {
			n = n, id = tostring(s.id), col = s.col, row = s.row, status = tostring(s.status),
			outer_key = tostring(s.outer_key), inner_key = tostring(s.inner_key),
			area_x = tostring(s.area_x0) .. ".." .. tostring(s.area_x1),
			area_y = tostring(s.area_y0) .. ".." .. tostring(s.area_y1),
		})
	end
	return ctx
end

DescribeTopUpEdge = function(ctx, sector, x, y)
	local sides = {}
	if type(x) == "number" and type(y) == "number" and type(ctx.ring_w) == "number"
		and type(ctx.ring_h) == "number" and type(ctx.band_world) == "number"
		and x >= 0 and y >= 0 and x < ctx.ring_w and y < ctx.ring_h then
		if x < ctx.band_world then sides[#sides + 1] = "left" end
		if x >= ctx.ring_w - ctx.band_world then sides[#sides + 1] = "right" end
		if y < ctx.band_world then sides[#sides + 1] = "top" end
		if y >= ctx.ring_h - ctx.band_world then sides[#sides + 1] = "bottom" end
	end
	local edge = #sides > 0 and table.concat(sides, "+") or "interior"
	local source_region = "unknown"
	if type(ctx.source_w) == "number" and type(ctx.source_h) == "number" then
		local beyond_x, beyond_y = x >= ctx.source_w, y >= ctx.source_h
		source_region = beyond_x and (beyond_y and "expanded_xy" or "expanded_x")
			or (beyond_y and "expanded_y" or "original_xy")
	end
	return edge, source_region
end

-- Clockwise coordinate around the FINAL map perimeter: top=[0,1), right=[1,2),
-- bottom=[2,3), left=[3,4). A corner candidate is assigned to its nearest physical side.
-- Using world distances here makes distribution independent of sector letters, row labels,
-- storage order, and any UI orientation convention.
PerimeterCoordinate = function(ctx, x, y)
	local map_w, map_h = ctx and ctx.ring_w, ctx and ctx.ring_h
	if type(map_w) ~= "number" or type(map_h) ~= "number" or map_w <= 0 or map_h <= 0
		or type(x) ~= "number" or type(y) ~= "number" then
		return nil, "unknown", nil
	end
	local choices = {
		-- +0.0 is required: this engine truncates integer/integer division, which previously
		-- collapsed every position on a side to exactly 0, 1, 2, or 3 in the diagnostics.
		{ side = "top", distance = y, u = (x + 0.0) / map_w },
		{ side = "right", distance = map_w - x, u = 1 + (y + 0.0) / map_h },
		{ side = "bottom", distance = map_h - y, u = 2 + (map_w - x + 0.0) / map_w },
		{ side = "left", distance = x, u = 3 + (map_h - y + 0.0) / map_h },
	}
	local best = choices[1]
	for i = 2, #choices do
		if choices[i].distance < best.distance then best = choices[i] end
	end
	return best.u % 4, best.side, best.distance
end

-- POST-GENERATION EFFECT-DEPOSIT top-up. These markers
-- spawn the non-minable map bonuses used by Vistas and Research Sites. They are not resource
-- deposits or anomalies, so neither existing top-up includes them. Top up each enabled
-- deposit_type independently to preserve its exact source ratio. BeautyEffectDeposit,
-- ResearchEffectDeposit, and MoraleEffectDeposit are separately gated. Unknown/custom
-- EffectDeposit subclasses are deliberately excluded. On the surface, these extras are randomly
-- selected outside the anomaly-only ring and require passable, flat, buildable, unobstructed hexes.
local EFFECT_TOPUP_FLAG = {
	BeautyEffectDeposit = "TOPUP_VISTAS",
	ResearchEffectDeposit = "TOPUP_RESEARCH_SITES",
	MoraleEffectDeposit = "TOPUP_MORALE_VISTAS",
}

local function EffectDepositTopUpEnabled(deposit_type)
	local flag = EFFECT_TOPUP_FLAG[deposit_type]
	return flag ~= nil and cfg()[flag] == true
end

function DepositRules.TopUpEffectDeposits(map)
	if not ExpansionAdditionStagesReady("effect top-up") then return end
	map = map or Global("CurrentMap")
	RecordEnrichmentTopUpAudit(map, "effects", { complete = false, reason = "started" })
	local point = Global("point")
	local clone_fn = SuperBigMap.ObjectClone and SuperBigMap.ObjectClone.CloneObjectAtOffset
	local city = map and map.City
	if not map or type(map.MapForEach) ~= "function" or type(point) ~= "function"
		or type(clone_fn) ~= "function" or not city then
		Log("effect-deposit top-up skipped", { reason = "map/city/point/clone unavailable" })
		return
	end
	local map_w, map_h, tile = MapWorldSize(map)
	if not map_w or not tile or tile <= 0 then
		Log("effect-deposit top-up skipped", { reason = "map size unavailable" })
		return
	end
	local margin = math.max(0, math.floor(cfg().DEPOSIT_EDGE_MARGIN_TILES or 4)) * tile
	local lo_x, span_x = margin, map_w - 2 * margin
	local lo_y, span_y = margin, map_h - 2 * margin
	if span_x <= 0 or span_y <= 0 then return end

	local area_factor = 1.0
	do
		local gen_t = map.SuperBigMapGeneratorWidthTiles
		local full_t = map.SuperBigMapDesiredWidthTiles or (map.mapdata and map.mapdata.Width)
		if type(gen_t) == "number" and gen_t > 0 and type(full_t) == "number" and full_t > gen_t then
			local r = full_t * 1.0 / gen_t
			area_factor = r * r
		end
	end
	if area_factor <= 1.0 then
		Log("effect-deposit top-up: no scaling (area_factor <= 1)", { area_factor = area_factor })
		return
	end

	local current_by_type, templates_by_type = {}, {}
	pcall(map.MapForEach, map, "map", "EffectDepositMarker", function(marker)
		if not marker then return end
		local deposit_type = tostring(marker.deposit_type or "")
		if deposit_type == "" or not EffectDepositTopUpEnabled(deposit_type) then return end
		current_by_type[deposit_type] = (current_by_type[deposit_type] or 0) + 1
		if not marker.SuperBigMapQuadrantClone then
			local list = templates_by_type[deposit_type]
			if not list then list = {}; templates_by_type[deposit_type] = list end
			list[#list + 1] = marker
		end
	end)

	local types, total_shortfall = {}, 0
	local target_by_type = {}
	for deposit_type, templates in pairs(templates_by_type) do
		if #templates > 0 then
			types[#types + 1] = deposit_type
			local target = math.floor(#templates * area_factor + 0.5)
			target_by_type[deposit_type] = target
			total_shortfall = total_shortfall + math.max(0, target - (current_by_type[deposit_type] or 0))
		end
	end
	table.sort(types)
	if total_shortfall <= 0 then
		Log("effect-deposit top-up: nothing to add", {
			area_factor = string.format("%.3f", area_factor), current = TallyString(current_by_type),
			target = TallyString(target_by_type),
		})
		RecordEnrichmentTopUpAudit(map, "effects", {
			complete = true, remaining_shortfall = 0,
			target = TallyString(target_by_type), current = TallyString(current_by_type),
		})
		return
	end

	local added_by_type = {}
	local pool_final = 0
	local reused_pool = false
	local placement_stats
	local placement_attempts, clone_failures = 0, 0
	RunPaused("SuperBigMapEffectDepositTopUp", function()
		local candidates = {}
		local MAX_SAMPLES, MAX_POOL = 6000, 2500
		local target_pool = math.min(MAX_POOL, math.max(512, total_shortfall * 32))
		local cached = CachedTopUpCandidates(map)
		if cached then
			for _, c in ipairs(cached) do
				if #candidates >= target_pool then break end
				if not c.used then
					local pt = point(c.x, c.y)
					local reserved_ring = not IsUndergroundMap(map)
						and IsInFinalOuterSectorRing(map, c.x, c.y,
							cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3)
					if not reserved_ring and CanReceiveDeposit(map, pt)
						and (IsUndergroundMap(map) or (IsBuildableAt(map, pt, true)
							and IsUnobstructedAt(map, pt, true))) then
						candidates[#candidates + 1] = c
					end
				end
			end
			reused_pool = #candidates > 0
		end
		-- Reuse the resource pool when it contains enough safe choices. If buildability or
		-- obstruction filtering removed too many, top it up with fresh random samples.
		local need_fresh = #candidates < target_pool
		for _ = 1, need_fresh and MAX_SAMPLES or 0 do
			if #candidates >= target_pool then break end
			local x, y = lo_x + RandInt(span_x), lo_y + RandInt(span_y)
			local sector = SectorAtPoint(map, x, y)
			local reserved_ring = not IsUndergroundMap(map) and IsInFinalOuterSectorRing(map, x, y,
				cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3)
			if sector and (IsUndergroundMap(map) or not SectorIsScanned(sector)) and not reserved_ring then
				local pt = point(x, y)
				if CanReceiveDeposit(map, pt)
					and (IsUndergroundMap(map) or (IsBuildableAt(map, pt, true)
						and IsUnobstructedAt(map, pt, true))) then
					candidates[#candidates + 1] = {
						x = x, y = y, terrain_type = TerrainTypeAt(map, pt) or -1,
						sector = sector, sector_id = sector.id,
					}
				end
			end
		end
		pool_final = #candidates
		ProfileStep("effect candidate pool ready", {
			candidates = pool_final, target_pool = target_pool, reused = reused_pool,
		}, map)
		local selector = NewSectorBalancedCandidateSelector(map, candidates, "effects")
		for _, deposit_type in ipairs(types) do
			local templates = templates_by_type[deposit_type]
			local shortfall = math.max(0,
				target_by_type[deposit_type] - (current_by_type[deposit_type] or 0))
			-- Continue after a failed clone. Take consumes one candidate, so this loop is
			-- bounded by the validated pool even when every clone attempt fails.
			while (added_by_type[deposit_type] or 0) < shortfall do
				if selector.Remaining() == 0 then break end
				placement_attempts = placement_attempts + 1
				local c = selector.Take()
				if not c then break end
				local template = templates[RandInt(#templates) + 1]
				local tpos = ObjectPos(template)
				if tpos and type(tpos.xy) == "function" then
					local tx, ty = tpos:xy()
					local clone = clone_fn(map, template, point(c.x - tx, c.y - ty, 0))
					if clone and type(clone) == "table" then
						selector.Commit(c)
						clone.SuperBigMapEffectTopUp = true
						clone.SuperBigMapEffectTopUpType = deposit_type
						added_by_type[deposit_type] = (added_by_type[deposit_type] or 0) + 1
						if type(clone.SetPos) == "function" then
							local pt = point(c.x, c.y)
							if type(pt.SetTerrainZ) == "function" then
								local ok, snapped = pcall(pt.SetTerrainZ, pt, map)
								if ok and snapped then pt = snapped end
							end
							pcall(clone.SetPos, clone, pt)
						end
						clone.is_placed = false
						clone.placed_obj = false
						SetRevealedState(clone, false)
						if not IsUndergroundMap(map) then
							local sec = SectorAtPoint(map, c.x, c.y)
							if sec and type(sec.RegisterDeposit) == "function" then
								pcall(sec.RegisterDeposit, sec, clone)
							end
						end
					else
						clone_failures = clone_failures + 1
					end
				else
					clone_failures = clone_failures + 1
				end
			end
		end
		placement_stats = selector.Stats()
	end)
	local final_by_type, remaining_shortfall, excess, final_total = {}, 0, 0, 0
	pcall(map.MapForEach, map, "map", "EffectDepositMarker", function(marker)
		if not marker then return end
		local deposit_type = tostring(marker.deposit_type or "")
		if target_by_type[deposit_type] == nil then return end
		final_by_type[deposit_type] = (final_by_type[deposit_type] or 0) + 1
		final_total = final_total + 1
	end)
	for _, deposit_type in ipairs(types) do
		local final_count = final_by_type[deposit_type] or 0
		remaining_shortfall = remaining_shortfall
			+ math.max(0, (target_by_type[deposit_type] or 0) - final_count)
		excess = excess + math.max(0, final_count - (target_by_type[deposit_type] or 0))
	end
	Log("topped up effect deposits to map-size proportions (post-gen)", {
		area_factor = string.format("%.3f", area_factor), current = TallyString(current_by_type),
		target = TallyString(target_by_type), added = TallyString(added_by_type),
		final = TallyString(final_by_type), remaining_shortfall = remaining_shortfall, excess = excess,
		map = tostring(map.name), pool = pool_final, reused_pool = reused_pool,
		placement_attempts = placement_attempts, clone_failures = clone_failures,
		balanced_placement = placement_stats and placement_stats.balanced,
		eligible_sectors = placement_stats and placement_stats.eligible_sectors,
		selected_sectors = placement_stats and placement_stats.selected_sectors,
		selected = placement_stats and placement_stats.selected,
		remaining_candidates = placement_stats and placement_stats.remaining_candidates,
		max_additions_to_one_sector = placement_stats and placement_stats.max_additions_to_one_sector,
	})
	RecordEnrichmentTopUpAudit(map, "effects", {
		complete = remaining_shortfall == 0, remaining_shortfall = remaining_shortfall,
		target = TallyString(target_by_type), current = final_total,
	})
end

-- Final invariant check for the surface density suite. Only markers created by the three top-up
-- passes are inspected: vanilla/generated enrichments remain untouched. Every anomaly top-up must
-- be in the final outer ring, passable, unobstructed, and on a unique anomaly hex; buildability,
-- slope, and valley score are preference diagnostics. Resource and effect-deposit top-ups must be
-- outside the ring. The same DebugTopUpEdgeDistribution switch gates the exhaustive marker trace.
function DepositRules.AuditSurfaceTopUpRingExclusivity(map)
	if not ExpansionStepEnabled(19) then return true end
	map = map or Global("CurrentMap")
	if not map or IsUndergroundMap(map) or type(map.MapForEach) ~= "function" then return true end
	local ring_sectors = math.max(0, math.floor(cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3))
	if ring_sectors <= 0 then return true end
	local stats = {
		anomaly_topups = 0, resource_topups = 0, effect_topups = 0,
		anomaly_outside_ring = 0, non_anomaly_inside_ring = 0, missing_position = 0,
		anomaly_unreachable = 0, anomaly_unbuildable = 0, anomaly_obstructed = 0, anomaly_overlap = 0,
		anomaly_not_mountain_base = 0,
		effect_unbuildable = 0, effect_obstructed = 0,
	}
	local violation_count = 0
	local trace = TopUpEdgeLogOn()
	local point_fn = Global("point")
	local world_to_hex = Global("WorldToHex")
	local function audit_hex_key(x, y)
		if type(world_to_hex) == "function" and type(point_fn) == "function" then
			local ok_h, q, r = pcall(world_to_hex, point_fn(x, y))
			if ok_h and type(q) == "number" and type(r) == "number" then
				return tostring(q) .. ":" .. tostring(r)
			end
		end
		return tostring(x) .. ":" .. tostring(y)
	end
	local occupied_anomaly_hexes = {}
	pcall(map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(marker)
		if not (marker and marker.SuperBigMapAnomalyTopUp) then
			local pos = marker and ObjectPos(marker)
			if pos and type(pos.xy) == "function" then
				local x, y = pos:xy()
				if type(x) == "number" and type(y) == "number" then
					occupied_anomaly_hexes[audit_hex_key(x, y)] = true
				end
			end
		end
	end)
	local function inspect(marker, family, must_be_in_ring)
		local pos = marker and ObjectPos(marker)
		local x, y
		if pos and type(pos.xy) == "function" then x, y = pos:xy() end
		local has_position = type(x) == "number" and type(y) == "number"
		local pt = has_position and pos or nil
		local in_ring = has_position and IsInFinalOuterSectorRing(map, x, y, ring_sectors) or false
		local reachable = has_position and PassableAt(map, pt) or false
		local buildable = has_position and IsBuildableAt(map, pt, true) or false
		local unobstructed = has_position and IsUnobstructedAt(map, pt, true) or false
		local valley_score = has_position and ValleyScore(map, pt) or 0
		local hex_key = has_position and audit_hex_key(x, y) or nil
		local overlap = family == "anomaly" and hex_key and occupied_anomaly_hexes[hex_key] == true or false
		if family == "anomaly" and hex_key then occupied_anomaly_hexes[hex_key] = true end
		if family == "anomaly" and not buildable then
			stats.anomaly_unbuildable = stats.anomaly_unbuildable + 1
		end
		if family == "anomaly" and valley_score <= 0 then
			stats.anomaly_not_mountain_base = stats.anomaly_not_mountain_base + 1
		end
		local violation
		if not has_position then
			stats.missing_position = stats.missing_position + 1
			violation = "missing_position"
		elseif must_be_in_ring and not in_ring then
			stats.anomaly_outside_ring = stats.anomaly_outside_ring + 1
			violation = "anomaly_topup_outside_final_ring"
		elseif family == "anomaly" and not reachable then
			stats.anomaly_unreachable = stats.anomaly_unreachable + 1
			violation = "anomaly_topup_not_passable"
		elseif family == "anomaly" and not unobstructed then
			stats.anomaly_obstructed = stats.anomaly_obstructed + 1
			violation = "anomaly_topup_obstructed"
		elseif family == "anomaly" and overlap then
			stats.anomaly_overlap = stats.anomaly_overlap + 1
			violation = "anomaly_topup_hex_overlap"
		elseif not must_be_in_ring and in_ring then
			stats.non_anomaly_inside_ring = stats.non_anomaly_inside_ring + 1
			violation = family .. "_topup_inside_reserved_ring"
		elseif family == "effect" and not buildable then
			stats.effect_unbuildable = stats.effect_unbuildable + 1
			violation = "effect_topup_unbuildable"
		elseif family == "effect" and not unobstructed then
			stats.effect_obstructed = stats.effect_obstructed + 1
			violation = "effect_topup_obstructed"
		end
		if violation then violation_count = violation_count + 1 end
		if trace then
			local sector = has_position and SectorAtPoint(map, x, y) or nil
			TopUpEdgeLog("top-up ring exclusivity marker", {
				family = family, marker = tostring(marker), class = tostring(marker and marker.class),
				reward_family = tostring(marker and marker.SuperBigMapAnomalyTopUpRewardFamily),
				effect_type = tostring(marker and marker.SuperBigMapEffectTopUpType),
				selected_sector = tostring(marker and marker.SuperBigMapEdgeTopUpSelectedSector),
				restriction_tier = tostring(marker and marker.SuperBigMapEdgeTopUpRestrictionTier),
				low_area_pool = tostring(marker and marker.SuperBigMapEdgeTopUpLowAreaPool),
				x = tostring(x), y = tostring(y), sector = tostring(sector and sector.id),
				col = tostring(sector and sector.col), row = tostring(sector and sector.row),
				must_be_in_final_ring = tostring(must_be_in_ring),
				in_final_ring = tostring(in_ring), reachable = tostring(reachable),
				buildable = tostring(buildable), valley_score = tostring(valley_score),
				unobstructed = tostring(unobstructed), hex_key = tostring(hex_key), overlap = tostring(overlap),
				violation = tostring(violation or "none"),
			})
		end
	end
	pcall(map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(marker)
		if marker and marker.SuperBigMapAnomalyTopUp then
			stats.anomaly_topups = stats.anomaly_topups + 1
			inspect(marker, "anomaly", true)
		end
	end)
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if marker and marker.SuperBigMapResourceTopUp then
			stats.resource_topups = stats.resource_topups + 1
			inspect(marker, "resource", false)
		end
	end)
	pcall(map.MapForEach, map, "map", "EffectDepositMarker", function(marker)
		if marker and marker.SuperBigMapEffectTopUp then
			stats.effect_topups = stats.effect_topups + 1
			inspect(marker, "effect", false)
		end
	end)
	stats.violations = violation_count
	TopUpEdgeLog("FINAL top-up ring exclusivity audit", {
		map = tostring(map.name), ring_sectors = ring_sectors,
		anomaly_topups = stats.anomaly_topups, resource_topups = stats.resource_topups,
		effect_topups = stats.effect_topups, anomaly_outside_ring = stats.anomaly_outside_ring,
		non_anomaly_inside_ring = stats.non_anomaly_inside_ring,
		anomaly_unreachable = stats.anomaly_unreachable,
		anomaly_unbuildable = stats.anomaly_unbuildable,
		anomaly_obstructed = stats.anomaly_obstructed,
		anomaly_overlap = stats.anomaly_overlap,
		anomaly_not_mountain_base = stats.anomaly_not_mountain_base,
		effect_unbuildable = stats.effect_unbuildable, effect_obstructed = stats.effect_obstructed,
		missing_position = stats.missing_position, violations = violation_count,
	})
	if violation_count > 0 then
		Log("surface top-up ring exclusivity violation", stats)
	end
	return violation_count == 0, stats
end

-- Even out RESOURCE-deposit density to vanilla-like proportions. The generator packs the full
-- preset count into the shrunken gen-zone (see sbm_rmg_placement), so the source region --
-- including the scanned START sector -- is several times denser than vanilla while the mirrored
-- frame is sparse. This caps each sector at MAX_RESOURCE_DEPOSITS_PER_SECTOR and relocates the
-- surplus onto terrain-matched frame tiles (outside the source quadrant), thinning the source
-- and filling the frame -- total count unchanged, distribution evened. Surplus taken out of an
-- already-scanned sector (the start sector) is DESPAWNED + reset to unplaced + hidden, so it
-- re-spawns vanilla-style only when its new frame sector is scanned. Runs after the
-- clone/reshuffle/respace passes. Gated by EVEN_OUT_DEPOSIT_DENSITY.
function DepositRules.EvenOutDepositDensity(map)
	if cfg().EVEN_OUT_DEPOSIT_DENSITY ~= true then return end
	-- STRETCH mode: skip (user decision 2026-07-12, same rationale as RespaceAnomalies):
	-- the vanilla deposit distribution x4/3 is already vanilla density per area; capping and
	-- relocating surplus only moved VANILLA deposits away from their scaled positions.
	if tostring(cfg().EXPANSION_FRAME_FILL_MODE or "mirror") == "stretch" then
		Log("deposit even-out skipped (stretch mode: vanilla markers stay at scaled positions)")
		return
	end
	map = map or Global("CurrentMap")
	local point = Global("point")
	local city = map and map.City
	if not map or type(map.MapForEach) ~= "function" or type(point) ~= "function" or not city then
		Log("even-out skipped", { reason = "map/city/point unavailable" })
		return
	end
	local map_w, map_h, tile = MapWorldSize(map)
	if not map_w or not tile or tile <= 0 then
		Log("even-out skipped", { reason = "map size unavailable" })
		return
	end
	local cap = math.max(1, math.floor(cfg().MAX_RESOURCE_DEPOSITS_PER_SECTOR or 3))
	local margin_tiles = math.max(0, math.floor(cfg().DEPOSIT_EDGE_MARGIN_TILES or 4))
	local margin = margin_tiles * tile
	local src_w = (type(map.SuperBigMapSourceWidth) == "number") and map.SuperBigMapSourceWidth or 0
	local src_h = (type(map.SuperBigMapSourceHeight) == "number") and map.SuperBigMapSourceHeight or 0
	local lo_x, span_x = margin, (map_w - 2 * margin)
	local lo_y, span_y = margin, (map_h - 2 * margin)
	if span_x <= 0 or span_y <= 0 then
		Log("even-out skipped", { reason = "placeable span <= 0" })
		return
	end

	local moved, over_sectors, concrete_moves = 0, 0, {}
	local DoneObject = Global("DoneObject")
	local IsValid = Global("IsValid")
	RunPaused("SuperBigMapEvenOut", function()
		-- Frame candidate pool (terrain-bucketed), same shape as the reshuffle: sampled tiles
		-- OUTSIDE the source quadrant, so surplus source deposits move into the sparse frame.
		local buckets, pool = {}, 0
		local MAX_SAMPLES, MAX_POOL = 6000, 3000
		for _ = 1, MAX_SAMPLES do
			if pool >= MAX_POOL then break end
			local x = lo_x + RandInt(span_x)
			local y = lo_y + RandInt(span_y)
			-- Spread across the whole UNSCANNED map (rendered source AND mirrored frame),
			-- excluding only the scanned start sector: this keeps relocated/added markers from
			-- piling into the frame L-strip (which made one region far denser than the rest), and
			-- prevents hidden markers landing in an already-scanned sector where they'd never reveal.
			local sector = SectorAtPoint(map, x, y)
			if sector and not SectorIsScanned(sector) then
				local pt = point(x, y)
				if CanReceiveDeposit(map, pt) then
					local tt = TerrainTypeAt(map, pt) or -1
					local b = buckets[tt]; if not b then b = {}; buckets[tt] = b end
					b[#b + 1] = { x = x, y = y }
					pool = pool + 1
				end
			end
		end
		local function take(tt)
			local b = tt ~= nil and buckets[tt] or nil
			if b and #b > 0 then local i = RandInt(#b) + 1; local c = b[i]; table.remove(b, i); return c end
			return nil
		end
		local function take_any()
			for _, b in pairs(buckets) do if #b > 0 then local i = RandInt(#b) + 1; local c = b[i]; table.remove(b, i); return c end end
			return nil
		end

		-- Bucket resource-deposit markers by the sector they sit in.
		local by_sector = {}
		pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
			if not (marker and IsResourceDepositMarker(marker)) then return end
			local pos = ObjectPos(marker)
			if not pos or type(pos.xy) ~= "function" then return end
			local px, py = pos:xy()
			if px == nil then return end
			local sector = SectorAtPoint(map, px, py)
			if not sector then return end
			local rec = by_sector[sector]
			if not rec then rec = {}; by_sector[sector] = rec end
			rec[#rec + 1] = { marker = marker, px = px, py = py, pos = pos }
		end)

		-- Thin each over-cap sector: relocate the surplus markers into the frame pool.
		for sector, list in pairs(by_sector) do
			local n = #list
			if n > cap then
				over_sectors = over_sectors + 1
				for i = cap + 1, n do
					local item = list[i]
					local marker = item.marker
					local tt = TerrainTypeAt(map, item.pos) or -1
					local c = take(tt) or take_any()
					if c then
						local pt = point(c.x, c.y)
						if type(pt.SetTerrainZ) == "function" then
							local ok, snapped = pcall(pt.SetTerrainZ, pt, map)
							if ok and snapped then pt = snapped end
						end
						local is_concrete = IsConcreteTerrainDepositMarker(marker)
						if type(sector.UnregisterDeposit) == "function" then
							pcall(sector.UnregisterDeposit, sector, marker)
						end
						-- Surplus taken from an already-placed/revealed sector (the start sector):
						-- despawn the visible deposit and reset to unplaced so it re-spawns hidden
						-- when its new (frame) sector is scanned -- matching vanilla fog-of-war.
						if marker.is_placed == true then
							if IsValid and IsValid(marker.placed_obj) and DoneObject then
								pcall(DoneObject, marker.placed_obj)
							end
							marker.placed_obj = false
							marker.is_placed = false
						end
						SetRevealedState(marker, false)
						local ok_move = type(marker.SetPos) == "function" and pcall(marker.SetPos, marker, pt)
						if ok_move then
							moved = moved + 1
							local nx, ny = c.x, c.y
							if type(pt.xy) == "function" then nx, ny = pt:xy() end
							local new_sector = SectorAtPoint(map, nx, ny)
							if new_sector and type(new_sector.RegisterDeposit) == "function" then
								pcall(new_sector.RegisterDeposit, new_sector, marker)
							elseif type(sector.RegisterDeposit) == "function" then
								pcall(sector.RegisterDeposit, sector, marker)
							end
							if is_concrete then
								concrete_moves[#concrete_moves + 1] = {
									from = { x = item.px, y = item.py },
									to = { x = nx, y = ny },
									paint_now = SectorIsScanned(new_sector),
								}
							end
						elseif type(sector.RegisterDeposit) == "function" then
							pcall(sector.RegisterDeposit, sector, marker) -- move failed: undo
						end
					end
				end
			end
		end
		MoveConcreteImprints(map, concrete_moves)
	end)
	Log("evened out resource-deposit density", {
		cap_per_sector = cap,
		over_cap_sectors = over_sectors,
		markers_moved = moved,
	})
	DepositRules.LogDistributionReport(map, "after even-out")
end

-- Rebuild the entrance-seeded connectivity cache after the caller has synchronously finalized
-- underground passability/buildability. This is intentionally separate from lazy candidate
-- checks so the pipeline can fail closed before creating any extra enrichments.
function DepositRules.PrepareUndergroundReachability(map)
	if not IsUndergroundMap(map) then return true end
	topup_candidate_pool_by_map[map] = nil
	underground_reachability_by_map[map] = nil
	local state = BuildUndergroundReachability(map)
	return state and state.available == true, state
end

-- Final correctness audit for every resource/anomaly/effect marker, regardless of whether it
-- came from vanilla generation, geometric stretch movement, or a top-up clone. Any marker that
-- is not on the final buildable grid or is not connected by the rover path grid to at least one
-- real underground entrance is moved to the nearest of several random reachable candidates.
function DepositRules.RelocateUnreachableUndergroundEnrichments(map)
	if not ExpansionStepEnabled(9) or not ExpansionStepEnabled(12) then
		return true, { checked = 0, invalid = 0, moved = 0, unresolved = 0 }
	end
	if not IsUndergroundMap(map) then return true, { checked = 0, moved = 0, unresolved = 0 } end
	local point = Global("point")
	if not map or type(map.MapForEach) ~= "function" or type(point) ~= "function" then
		return false, { error = "map/MapForEach/point unavailable" }
	end
	local reachable_state = BuildUndergroundReachability(map)
	if not reachable_state or reachable_state.available ~= true then
		return false, { error = "entrance connectivity unavailable", seeds = reachable_state and #reachable_state.seeds or 0 }
	end
	local markers, invalid = {}, {}
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if marker and IsEnrichmentMarker(marker) then markers[#markers + 1] = marker end
	end)
	-- At first underground access no rover or drone has explored this map yet, so no enrichment
	-- may remain placed after the geometric stretch. Vanilla can nevertheless have placed one
	-- sector's objects earlier if its InitialExplore path was accidentally enabled. Despawn every
	-- such object and restore its marker to the normal proximity-gated state before any relocation;
	-- this also guarantees that moving a marker into untouched darkness cannot carry a visible
	-- badge with it. RevealDepositsInRange will place it later through the vanilla rover/drone path.
	local is_valid = Global("IsValid")
	local done_object = Global("DoneObject")
	local concrete_moves = {}
	local unrevealed_placed = 0
	for _, marker in ipairs(markers) do
		local placed = marker and marker.placed_obj
		local placed_valid = placed and (type(is_valid) ~= "function" or SafeCall(is_valid, placed) == true)
		if marker and (marker.is_placed == true or placed_valid) then
			local pos = ObjectPos(marker)
			if IsConcreteTerrainDepositMarker(marker) and pos and type(pos.xy) == "function" then
				local px, py = pos:xy()
				if px ~= nil then
					-- from == to with paint_now=false clears the old visible concrete imprint;
					-- marker placement paints it again when vanilla actually reveals this area.
					concrete_moves[#concrete_moves + 1] = {
						from = { x = px, y = py }, to = { x = px, y = py }, paint_now = false,
					}
				end
			end
			if placed_valid and type(done_object) == "function" then
				pcall(done_object, placed)
			end
			marker.placed_obj = false
			marker.is_placed = false
			SetRevealedState(marker, false)
			unrevealed_placed = unrevealed_placed + 1
		end
	end
	for _, marker in ipairs(markers) do
		local pos = ObjectPos(marker)
		if not pos or not CanReceiveDeposit(map, pos) then
			invalid[#invalid + 1] = { marker = marker, pos = pos }
		end
	end
	if #invalid == 0 then
		if #concrete_moves > 0 then MoveConcreteImprints(map, concrete_moves) end
		local stats = {
			checked = #markers, invalid = 0, moved = 0, unresolved = 0,
			unrevealed_placed = unrevealed_placed,
			seeds = #reachable_state.seeds, connectivity_checks = reachable_state.checks,
			connectivity_rejected = reachable_state.rejected, connectivity_failures = reachable_state.failures,
		}
		Log("underground enrichment reachability audit complete", stats)
		ProfileStep("underground enrichment reachability audit complete", stats, map)
		return true, stats
	end

	local map_w, map_h, tile = MapWorldSize(map)
	if not map_w or not map_h or not tile then
		return false, { error = "map size unavailable", checked = #markers, invalid = #invalid }
	end
	local margin = math.max(0, math.floor(cfg().DEPOSIT_EDGE_MARGIN_TILES or 4)) * tile
	local span_x, span_y = map_w - 2 * margin, map_h - 2 * margin
	if span_x <= 0 or span_y <= 0 then
		return false, { error = "placeable span unavailable", checked = #markers, invalid = #invalid }
	end
	local candidates, seen = {}, {}
	local world_to_hex = Global("WorldToHex")
	local target_pool = math.min(6000, math.max(512, #invalid * 10))
	local max_samples = math.max(24000, target_pool * 30)
	for _ = 1, max_samples do
		if #candidates >= target_pool then break end
		local x, y = margin + RandInt(span_x), margin + RandInt(span_y)
		local pt = point(x, y)
		if CanReceiveDeposit(map, pt) then
			local key = tostring(x) .. ":" .. tostring(y)
			if type(world_to_hex) == "function" then
				local ok_h, q, r = pcall(world_to_hex, pt)
				if ok_h and type(q) == "number" and type(r) == "number" then
					key = tostring(q) .. ":" .. tostring(r)
				end
			end
			if not seen[key] then
				seen[key] = true
				candidates[#candidates + 1] = { x = x, y = y }
			end
		end
	end
	local pool_built = #candidates

	local function take_near(pos)
		if #candidates == 0 then return nil end
		local ox, oy
		if pos and type(pos.xy) == "function" then ox, oy = pos:xy() end
		if type(ox) ~= "number" then
			return table.remove(candidates, RandInt(#candidates) + 1)
		end
		local best_i, best_d
		for _ = 1, math.min(16, #candidates) do
			local i = RandInt(#candidates) + 1
			local c = candidates[i]
			local dx, dy = c.x - ox, c.y - oy
			local d = dx * dx + dy * dy
			if not best_d or d < best_d then best_i, best_d = i, d end
		end
		return table.remove(candidates, best_i)
	end

	local moved, unresolved = 0, 0
	local moved_by_class = {}
	local relocation_attempts, relocation_retries = 0, 0
	local snapped_rejected, setpos_failed, postmove_rejected = 0, 0, 0
	for invalid_i, item in ipairs(invalid) do
		local marker, old_pos = item.marker, item.pos
		local class = tostring(marker and marker.class or "?")
		local ox, oy
		if old_pos and type(old_pos.xy) == "function" then ox, oy = old_pos:xy() end
		if not marker or type(marker.SetPos) ~= "function" then
			unresolved = unresolved + 1
			Log("underground enrichment relocation unresolved", {
				class = class, index = invalid_i, old_x = ox, old_y = oy,
				reason = not marker and "marker unavailable" or "SetPos unavailable",
			})
		else
			-- Leave at least one candidate for every marker still to process. A candidate was
			-- reachable when sampled, but terrain-Z snapping or SetPos can alter the effective
			-- point. The old single-attempt path therefore produced a false unresolved result
			-- despite hundreds of alternatives remaining in the pool.
			local later_markers = #invalid - invalid_i
			local max_attempts = math.min(32, math.max(0, #candidates - later_markers))
			local attempts, success = 0, false
			local successful_pos
			local last_reason = max_attempts > 0 and "no candidate attempted" or "candidate pool exhausted"
			while attempts < max_attempts and not success do
				local c = take_near(old_pos)
				if not c then
					last_reason = "candidate pool exhausted"
					break
				end
				attempts = attempts + 1
				relocation_attempts = relocation_attempts + 1
				if attempts > 1 then relocation_retries = relocation_retries + 1 end
				local new_pos = point(c.x, c.y)
				if type(new_pos.SetTerrainZ) == "function" then
					local ok_z, snapped = pcall(new_pos.SetTerrainZ, new_pos, map)
					if ok_z and snapped then new_pos = snapped end
				end
				local nx, ny
				if new_pos and type(new_pos.xy) == "function" then nx, ny = new_pos:xy() end
				if not CanReceiveDeposit(map, new_pos) then
					snapped_rejected = snapped_rejected + 1
					last_reason = "terrain-snapped candidate not reachable/buildable"
					Log("underground enrichment relocation candidate rejected", {
						attempt = attempts, candidate_x = c.x, candidate_y = c.y,
						class = class, index = invalid_i, old_x = ox, old_y = oy,
						reason = last_reason, snapped_x = nx, snapped_y = ny,
					})
				else
					local ok_move, move_error = pcall(marker.SetPos, marker, new_pos)
					if not ok_move then
						setpos_failed = setpos_failed + 1
						last_reason = "SetPos failed: " .. tostring(move_error)
						Log("underground enrichment relocation candidate rejected", {
							attempt = attempts, candidate_x = c.x, candidate_y = c.y,
							class = class, index = invalid_i, old_x = ox, old_y = oy,
							reason = last_reason, snapped_x = nx, snapped_y = ny,
						})
					else
						local actual_pos = ObjectPos(marker)
						local ax, ay
						if actual_pos and type(actual_pos.xy) == "function" then ax, ay = actual_pos:xy() end
						if actual_pos and CanReceiveDeposit(map, actual_pos) then
							success = true
							successful_pos = actual_pos
							Log("underground enrichment relocation accepted", {
								actual_x = ax, actual_y = ay, attempt = attempts,
								candidate_x = c.x, candidate_y = c.y, class = class,
								index = invalid_i, old_x = ox, old_y = oy,
								snapped_x = nx, snapped_y = ny,
							})
						else
							postmove_rejected = postmove_rejected + 1
							last_reason = actual_pos and "actual marker position not reachable/buildable" or "actual marker position unavailable"
							Log("underground enrichment relocation candidate rejected", {
								actual_x = ax, actual_y = ay, attempt = attempts,
								candidate_x = c.x, candidate_y = c.y, class = class,
								index = invalid_i, old_x = ox, old_y = oy,
								reason = last_reason, snapped_x = nx, snapped_y = ny,
							})
						end
					end
				end
			end
			if success then
				moved = moved + 1
				moved_by_class[class] = (moved_by_class[class] or 0) + 1
				marker.SuperBigMapReachabilityRelocated = true
			else
				unresolved = unresolved + 1
				Log("underground enrichment relocation unresolved", {
					attempts = attempts, candidates_remaining = #candidates,
					class = class, index = invalid_i, old_x = ox, old_y = oy,
					reason = last_reason,
				})
			end
		end
	end
	if #concrete_moves > 0 then MoveConcreteImprints(map, concrete_moves) end
	local stats = {
		checked = #markers, invalid = #invalid, moved = moved,
		unrevealed_placed = unrevealed_placed,
		unresolved = unresolved, candidates_built = pool_built,
		relocation_attempts = relocation_attempts, relocation_retries = relocation_retries,
		snapped_rejected = snapped_rejected, setpos_failed = setpos_failed,
		postmove_rejected = postmove_rejected, candidates_remaining = #candidates,
		seeds = #reachable_state.seeds, connectivity_checks = reachable_state.checks,
		connectivity_reachable = reachable_state.reachable,
		connectivity_rejected = reachable_state.rejected,
		connectivity_failures = reachable_state.failures,
		moved_by_class = TallyString(moved_by_class),
	}
	Log("underground enrichment reachability audit complete", stats)
	ProfileStep("underground enrichment reachability audit complete", stats, map)
	return unresolved == 0, stats
end

DepositRules.IsResourceDepositMarker = IsResourceDepositMarker

-- Reveal the clones inside a scanned sector's area (called from the SectorScanned handler).
-- STRETCH scan-gate enforcement (config STRETCH_ENFORCE_SCAN_GATE). The stretch moves every
-- generated marker AND every already-spawned deposit/anomaly to position * (full/source). The
-- start sector's enrichments were REVEALED at generation; after the move they land in OTHER,
-- unscanned sectors -- still visible (the "enrichments visible in G15/H15 while only K11 is
-- scanned" report). Conversely, markers that moved INTO the already-scanned start sector never
-- got their scan-time placement. Fix both:
--   A) any revealed scan-gated deposit/anomaly now sitting in an UNSCANNED sector is hidden and
--      flagged SuperBigMapQuadrantClone, so the existing OnSectorScanned reveal shows it when its
--      sector is actually scanned;
--   B) every SCANNED sector gets vanilla's own RevealDeposits over its markers (places/reveals
--      what moved in), plus a reveal of any hidden scan-gated objects inside it.
function DepositRules.EnforceScanGateAfterStretch(map)
	if not ExpansionStepEnabled(18) then return end
	if cfg().STRETCH_ENFORCE_SCAN_GATE ~= true then return end
	map = map or Global("CurrentMap")
	local city = map and map.City
	local get_sector = Global("GetMapSectorXY")
	if not map or not city or type(map.MapForEach) ~= "function" or type(get_sector) ~= "function" then
		Log("stretch scan-gate enforcement skipped", { reason = "map/city/GetMapSectorXY unavailable" })
		return
	end
	-- A) hide revealed scan-gated objects that now sit in unscanned sectors.
	local hidden = 0
	local function hide_leaks(class_name)
		pcall(map.MapForEach, map, "map", class_name, function(obj)
			if not (obj and IsScanGatedDeposit(obj)) then return end
			if obj.revealed ~= true then return end
			local pos = ObjectPos(obj)
			if not pos or type(pos.xy) ~= "function" then return end
			local px, py = pos:xy()
			if px == nil then return end
			local ok_s, sector = pcall(get_sector, city, px, py)
			if ok_s and sector and not SectorIsScanned(sector) then
				SetRevealedState(obj, false)
				-- Flag so the existing OnSectorScanned reveal path shows it on a real scan.
				obj.SuperBigMapQuadrantClone = true
				hidden = hidden + 1
			end
		end)
	end
	hide_leaks("SubsurfaceDeposit")
	hide_leaks("SubsurfaceAnomaly")
	-- A2) spawned SURFACE / CONCRETE deposits: these spawn at scan time, so the only pre-spawned
	-- ones are the start sector's -- which the stretch moved into unscanned sectors (visible
	-- deposit icons + painted regolith, the "concrete still visible" report). Despawn the spawned
	-- object and reset its marker to unplaced/hidden so it re-spawns vanilla-style when its new
	-- sector is really scanned (same pattern as EvenOutDepositDensity's start-sector surplus), and
	-- clear the concrete regolith imprint at the unscanned position (PlaceDeposit repaints it on
	-- scan). MoveConcreteImprints' flood fill runs inside the stretch branch's paused-ILD scope.
	local IsValid = Global("IsValid")
	local DoneObject = Global("DoneObject")
	local despawned = 0
	local concrete_moves = {}
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not (marker and IsResourceDepositMarker(marker)) then return end
		if marker.is_placed ~= true then return end
		local pos = ObjectPos(marker)
		if not pos or type(pos.xy) ~= "function" then return end
		local px, py = pos:xy()
		if px == nil then return end
		local ok_s, sector = pcall(get_sector, city, px, py)
		if not (ok_s and sector) or SectorIsScanned(sector) then return end
		if type(IsValid) == "function" and IsValid(marker.placed_obj) and type(DoneObject) == "function" then
			pcall(DoneObject, marker.placed_obj)
		end
		marker.placed_obj = false
		marker.is_placed = false
		SetRevealedState(marker, false)
		despawned = despawned + 1
		if IsConcreteTerrainDepositMarker(marker) then
			-- from == to with paint_now=false: clears the blob at the unscanned position and
			-- postpones the repaint to the marker's own scan-time PlaceDeposit.
			concrete_moves[#concrete_moves + 1] = { from = { x = px, y = py }, to = { x = px, y = py }, paint_now = false }
		end
	end)
	MoveConcreteImprints(map, concrete_moves)
	-- B) scanned sectors: run vanilla's RevealDeposits over their markers (place what moved in)
	-- and reveal any hidden scan-gated objects inside.
	local reveal_deposits = Global("RevealDeposits")
	local placed_sectors, revealed_objs = 0, 0
	if type(city.MapSectors) == "table" then
		for _, sector_col in pairs(city.MapSectors) do
			if type(sector_col) == "table" then
				for _, sector in pairs(sector_col) do
					if type(sector) == "table" and SectorIsScanned(sector) and sector.area then
						if type(reveal_deposits) == "function" then
							local markers = {}
							pcall(map.MapForEach, map, sector.area, "DepositMarker", function(m)
								if m and IsResourceDepositMarker(m) and m.is_placed ~= true then
									markers[#markers + 1] = m
								end
							end)
							if #markers > 0 then
								pcall(reveal_deposits, markers)
								placed_sectors = placed_sectors + 1
							end
						end
						local function reveal_in_area(class_name)
							pcall(map.MapForEach, map, sector.area, class_name, function(obj)
								if obj and IsScanGatedDeposit(obj) and obj.revealed ~= true then
									SetRevealedState(obj, true)
									revealed_objs = revealed_objs + 1
								end
							end)
						end
						reveal_in_area("SubsurfaceDeposit")
						reveal_in_area("SubsurfaceAnomaly")
					end
				end
			end
		end
	end
	Log("stretch scan-gate enforced", {
		hidden_leaks = hidden, despawned_surface = despawned, concrete_imprints_cleared = #concrete_moves,
		scanned_sectors_placed = placed_sectors, revealed_in_scanned = revealed_objs,
	})
end

function DepositRules.OnSectorScanned(status, sector)
	if not Enabled() then return end
	if type(sector) ~= "table" then return end
	local map = (type(sector.GetMap) == "function") and SafeCall(sector.GetMap, sector) or Global("CurrentMap")
	local area = sector.area
	if not map or not area or type(map.MapForEach) ~= "function" then return end

	-- Exhaustive + self-healing audit for surface anomaly top-up markers. Vanilla normally places
	-- registered markers before SectorScanned fires; if the custom 20x20 sector path ever misses
	-- one, place it here at the same scan boundary so it never remains permanently invisible.
	local edge_markers, unplaced = {}, {}
	pcall(map.MapForEach, map, area, "SubsurfaceAnomalyMarker", function(marker)
		if marker and marker.SuperBigMapEdgeTopUp then
			edge_markers[#edge_markers + 1] = marker
			if marker.is_placed ~= true then unplaced[#unplaced + 1] = marker end
		end
	end)
	if #edge_markers > 0 and TopUpEdgeLogOn() then
		TopUpEdgeLog("SectorScanned edge top-up audit BEGIN", {
			status = tostring(status), sector = tostring(sector.id), col = tostring(sector.col),
			row = tostring(sector.row), markers = #edge_markers, unplaced = #unplaced,
		})
		for n, marker in ipairs(edge_markers) do
			local pos = ObjectPos(marker)
			local x, y
			if pos and type(pos.xy) == "function" then x, y = pos:xy() end
			TopUpEdgeLog("SectorScanned edge marker BEFORE", {
				n = n, marker = tostring(marker), x = tostring(x), y = tostring(y),
				placement = tostring(marker.SuperBigMapEdgeTopUpPlacement),
				preferred_side = tostring(marker.SuperBigMapEdgeTopUpPreferredSide),
				target_bin = tostring(marker.SuperBigMapEdgeTopUpTargetBin),
				target_layer = tostring(marker.SuperBigMapEdgeTopUpTargetLayer),
				actual_bin = tostring(marker.SuperBigMapEdgeTopUpActualBin),
				actual_layer = tostring(marker.SuperBigMapEdgeTopUpActualLayer),
				selection_scope = tostring(marker.SuperBigMapEdgeTopUpSelectionScope),
				is_placed = tostring(marker.is_placed), placed_obj = tostring(marker.placed_obj),
			})
		end
	end
	local reveal_called, reveal_ok, reveal_result = false, false, nil
	local reveal_deposits = Global("RevealDeposits")
	if #unplaced > 0 and type(reveal_deposits) == "function" then
		reveal_called = true
		reveal_ok, reveal_result = pcall(reveal_deposits, unplaced)
	end
	local edge_placed, edge_revealed, edge_unresolved = 0, 0, 0
	for n, marker in ipairs(edge_markers) do
		local placed_obj = marker.placed_obj
		if marker.is_placed == true and placed_obj then
			edge_placed = edge_placed + 1
			if placed_obj.revealed ~= true then SetRevealedState(placed_obj, true) end
			if placed_obj.revealed == true then edge_revealed = edge_revealed + 1 end
		else
			edge_unresolved = edge_unresolved + 1
		end
		if TopUpEdgeLogOn() then
			local pos = ObjectPos(marker)
			local x, y
			if pos and type(pos.xy) == "function" then x, y = pos:xy() end
			local obj_pos = placed_obj and ObjectPos(placed_obj)
			local ox, oy
			if obj_pos and type(obj_pos.xy) == "function" then ox, oy = obj_pos:xy() end
			TopUpEdgeLog("SectorScanned edge marker AFTER", {
				n = n, marker = tostring(marker), x = tostring(x), y = tostring(y),
				is_placed = tostring(marker.is_placed), placed_obj = tostring(placed_obj),
				placed_x = tostring(ox), placed_y = tostring(oy),
				position_matches_marker = tostring(ox == x and oy == y),
				preferred_side = tostring(marker.SuperBigMapEdgeTopUpPreferredSide),
				target_bin = tostring(marker.SuperBigMapEdgeTopUpTargetBin),
				target_layer = tostring(marker.SuperBigMapEdgeTopUpTargetLayer),
				actual_bin = tostring(marker.SuperBigMapEdgeTopUpActualBin),
				actual_layer = tostring(marker.SuperBigMapEdgeTopUpActualLayer),
				placed_revealed = tostring(placed_obj and placed_obj.revealed),
			})
		end
	end
	if #edge_markers > 0 and TopUpEdgeLogOn() then
		TopUpEdgeLog("SectorScanned edge top-up audit END", {
			sector = tostring(sector.id), markers = #edge_markers, initially_unplaced = #unplaced,
			reveal_called = tostring(reveal_called), reveal_ok = tostring(reveal_ok),
			reveal_result = tostring(reveal_result), placed = edge_placed,
			revealed = edge_revealed, unresolved = edge_unresolved,
		})
	end
	local revealed = 0
	pcall(map.MapForEach, map, area, "SubsurfaceDeposit", function(obj)
		if obj and obj.SuperBigMapQuadrantClone and IsScanGatedDeposit(obj) then
			SetRevealedState(obj, true)
			revealed = revealed + 1
		end
	end)
	-- SubsurfaceAnomaly is not a SubsurfaceDeposit subclass; sweep it too.
	pcall(map.MapForEach, map, area, "SubsurfaceAnomaly", function(obj)
		if obj and obj.SuperBigMapQuadrantClone and IsScanGatedDeposit(obj) then
			SetRevealedState(obj, true)
			revealed = revealed + 1
		end
	end)
	if revealed > 0 then
		Log("revealed cloned deposits in scanned sector", {
			sector = (sector.col and sector.row) and (tostring(sector.col) .. "," .. tostring(sector.row)) or "?",
			revealed = revealed,
		})
	end
end

DepositRules.ClearTopUpPlacementPool = ClearTopUpPlacementPool

SuperBigMap.DepositRules = DepositRules

if cfg().ENABLE_MOD ~= false and (SuperBigMap.State or {}).main_menu_vanilla ~= true then
	PatchBadgeOverlapPrevention()
end

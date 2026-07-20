-- Super Big Map -- stretch enrichment placement and scan gating.
--
-- Native markers are recreated at their proportional post-stretch coordinates and additions are
-- generated only for the extra area. This module preserves vanilla scan gating, validates final
-- placement, and manages concrete imprints when a transformed marker must be hidden or moved.

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

local function AuditEnabled()
	local diagnostics = SuperBigMap.Diagnostics
	return diagnostics and type(diagnostics.EnrichmentEnabled) == "function"
		and diagnostics.EnrichmentEnabled() == true
end

local function AuditEmit(event, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.Audit) == "function" then
		diagnostics.Audit(event, data, map)
	end
end

local function CountMapString(values)
	if type(values) ~= "table" then return "" end
	local keys = {}
	for key in pairs(values) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local parts = {}
	for i, key in ipairs(keys) do parts[i] = tostring(key) .. ":" .. tostring(values[key]) end
	return table.concat(parts, "|")
end

local function ExpansionStepEnabled(step)
	local steps = cfg().EXPANSION_ENRICHMENT_STEPS
	return type(steps) == "table" and steps[step] == true
end

local function ExpansionAdditionStagesReady(label)
	if not ExpansionStepEnabled(3) then
		return false
	end
	for step = 11, 19 do
		if not ExpansionStepEnabled(step) then
			return false
		end
	end
	return true
end

-- Stretch density-suite cache. TopUpDeposits performs the largest validated random sampling
-- pass; anomaly/effect top-ups can consume its unused candidates instead of rebuilding
-- equivalent pools. Weak map keys release abandoned-map entries automatically.
local topup_candidate_pool_by_map = setmetatable({}, { __mode = "k" })
-- The underground density suite temporarily removes only removable rubble-wall footprints from
-- the gameplay grids. Keeping the token here lets resources, anomalies, and effects share one
-- wall-free candidate space and guarantees that the exact live objects are restored afterwards.
local rubble_wall_suite_token_by_map = setmetatable({}, { __mode = "k" })
-- Final underground connectivity state, built only after the stretched passability/buildable
-- grids are synchronously rebuilt. Exact-hex results are cached because all three top-up passes
-- and the final marker audit ask the same entrance-reachability question repeatedly.
local underground_reachability_by_map = setmetatable({}, { __mode = "k" })
-- One immutable, final-grid sampling index is shared by the underground resource, anomaly, and
-- effect passes. It stores the authoritative validation context, sectors proven to contain at
-- least one buildable hex, and every validated candidate hex already discovered by the suite.
-- Later families therefore continue the same candidate stream instead of re-sampling empty rock
-- sectors or repeating buildability/connectivity work for an already-seen coordinate.
local underground_topup_sampling_by_map = setmetatable({}, { __mode = "k" })
-- Stage 01 cannot keep the generated marker OBJECTS alive: they belong to the temporary vanilla
-- map slot and are destroyed when that slot is unloaded. Retain an independent value-only record
-- set until stage 02 has stretched the destination terrain and recreated the markers there. Weak
-- map keys ensure an abandoned generation cannot leak the (potentially large) property snapshots.
local pending_native_enrichment_records_by_map = setmetatable({}, { __mode = "k" })
-- Buried wonders are selected while the vanilla underground still exists but are materialized
-- only after the terrain and native enrichments have been transformed. Cache their final scaled
-- visual footprints up front so both native reconstruction and all three top-up families can
-- reject those hexes without repeatedly walking the large wonder shapes.
local underground_wonder_reserved_hexes_by_map = setmetatable({}, { __mode = "k" })
-- CaptureNativeEnrichmentPositions and CaptureNativeEnrichmentRecords run back-to-back on the
-- generated source. Keep that first traversal's exact live marker list long enough for the value
-- snapshot, avoiding a second full DepositMarker enumeration. The cache is consumed immediately;
-- weak keys also make an interrupted source transaction self-cleaning.
local captured_native_enrichment_objects_by_map = setmetatable({}, { __mode = "k" })
-- GetProperties returns class metadata. Native generation commonly creates hundreds of markers
-- from only a handful of concrete classes, so filtering the same metadata for every instance is
-- redundant. The cache contains metadata only (never map objects or property values).
local portable_native_properties_by_class = {}

local function CachedTopUpCandidates(map)
	if cfg().OPTIMIZE_TOPUP_PLACEMENT_POOLS ~= true then return nil end
	return topup_candidate_pool_by_map[map]
end

local function ClearTopUpPlacementPool(map)
	if map then
		topup_candidate_pool_by_map[map] = nil
		underground_reachability_by_map[map] = nil
		underground_topup_sampling_by_map[map] = nil
	end
end

local function CoordinateHexKey(q, r)
	return tostring(q) .. ":" .. tostring(r)
end

local function UndergroundWonderReservedHexes(map)
	local state = map and underground_wonder_reserved_hexes_by_map[map]
	return type(state) == "table" and state.hexes or nil
end

local function Enabled()
	return cfg().HIDE_CLONED_DEPOSITS_UNTIL_SCAN ~= false
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

local ObjectPos = Engine.ObjectPos
-- Forward declaration: underground staging is defined before the sector-registration helpers but
-- executes only after the module has finished loading.
local UnregisterNativeMarker

local function TerrainTypeAt(map, pt, context)
	context = type(context) == "table" and context.map == map and context or nil
	local t = context and context.terrain or Global("terrain")
	local get_type = context and context.terrain_get_type
		or (type(t) == "table" and t.GetTerrainType or nil)
	if type(get_type) == "function" then
		local ok, v = pcall(get_type, map, pt)
		if ok then return v end
	end
	return nil
end

-- normal.z in base 4096 (4096 = perfectly flat); a cheap, trig-free "flatness" measure.
local function FlatnessAt(map, pt, context)
	context = type(context) == "table" and context.map == map and context or nil
	local t = context and context.terrain or Global("terrain")
	local get_normal = context and context.terrain_get_normal
		or (type(t) == "table" and t.GetTerrainNormal or nil)
	if type(get_normal) == "function" then
		local ok, n = pcall(get_normal, map, pt)
		if ok and n and type(n.z) == "function" then
			local okz, z = pcall(n.z, n)
			if okz and type(z) == "number" then return z end
		end
	end
	return 4096
end

local function PassableAt(map, pt, context)
	context = type(context) == "table" and context.map == map and context or nil
	local t = context and context.terrain or Global("terrain")
	local is_passable = context and context.terrain_is_passable
		or (type(t) == "table" and t.IsPassable or nil)
	if type(is_passable) == "function" then
		local ok, v = pcall(is_passable, map, pt)
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
	return ok, err
end

local function TopUpFlatnessMinimum()
	local value = tonumber(cfg().TOPUP_MINIMUM_TERRAIN_NORMAL_Z) or 4080
	return math.max(0, math.min(4096, value))
end

-- A density pass evaluates thousands of immutable terrain/grid queries. Resolve the native
-- functions and constants once per pass rather than rebuilding the same lookup chain for every
-- random candidate. Fail-open/fail-closed rules remain unchanged.
local function NewDepositValidationContext(map)
	local terrain_api = Global("terrain")
	local world_to_hex = Global("WorldToHex")
	local buildable = map and map.buildable
	local object_hex_grid = map and map.object_hex_grid
	local build_unbuildable = Global("buildUnbuildableZ")
	local sentinel_ok, sentinel = false, nil
	if type(build_unbuildable) == "function" then
		sentinel_ok, sentinel = pcall(build_unbuildable)
	end
	local const_tbl = Global("const")
	return {
		map = map,
		terrain = terrain_api,
		terrain_is_passable = type(terrain_api) == "table" and terrain_api.IsPassable or nil,
		terrain_get_normal = type(terrain_api) == "table" and terrain_api.GetTerrainNormal or nil,
		terrain_get_type = type(terrain_api) == "table" and terrain_api.GetTerrainType or nil,
		world_to_hex = world_to_hex,
		buildable = buildable,
		buildable_get_z = buildable and buildable.GetZ or nil,
		buildable_by_hex = {},
		build_unbuildable_ok = sentinel_ok,
		build_unbuildable_z = sentinel,
		object_hex_grid = object_hex_grid,
		get_build_obstructions = object_hex_grid and object_hex_grid.GetBuildObstructions or nil,
		is_deposit_obstructed = Global("IsDepositObstructed"),
		deposit_obstruct_radius = type(const_tbl) == "table"
			and tonumber(const_tbl.DepositObstructMaxRadius) or nil,
		flatness_minimum = TopUpFlatnessMinimum(),
		underground = IsUndergroundMap(map),
		wonder_reserved_hexes = UndergroundWonderReservedHexes(map),
	}
end

local function IsBuildableAt(map, pt, strict, context)
	context = type(context) == "table" and context.map == map and context or nil
	local buildable = context and context.buildable or (map and map.buildable)
	local get_z = context and context.buildable_get_z or (buildable and buildable.GetZ)
	local world_to_hex = context and context.world_to_hex or Global("WorldToHex")
	local build_unbuildable = context and nil or Global("buildUnbuildableZ")
	if not (buildable and type(get_z) == "function" and type(world_to_hex) == "function"
		and (context or type(build_unbuildable) == "function")) then
		return strict ~= true -- surface keeps the historical fail-open behavior; underground is strict
	end
	local ok_u, sentinel
	if context then
		ok_u, sentinel = context.build_unbuildable_ok, context.build_unbuildable_z
	else
		ok_u, sentinel = pcall(build_unbuildable)
	end
	if not ok_u then return strict ~= true end
	local ok_h, q, r = pcall(world_to_hex, pt)
	if not ok_h or type(q) ~= "number" then return strict ~= true end
	local cached_by_q = context and type(r) == "number" and context.buildable_by_hex[q]
	local cached = cached_by_q and cached_by_q[r]
	if cached ~= nil then return cached == true, q, r end
	local ok_z, z = pcall(get_z, buildable, q, r)
	local result = ok_z and z ~= nil and z ~= sentinel
	if context and type(r) == "number" then
		if not cached_by_q then
			cached_by_q = {}
			context.buildable_by_hex[q] = cached_by_q
		end
		cached_by_q[r] = result == true
	end
	return result, q, r
end

local function IsUnobstructedAt(map, pt, strict, context)
	if not map or not pt then return strict ~= true end
	context = type(context) == "table" and context.map == map and context or nil
	local hex_grid = context and context.object_hex_grid or (map and map.object_hex_grid)
	local world_to_hex = context and context.world_to_hex or Global("WorldToHex")
	local q, r
	if type(world_to_hex) == "function" then
		local ok_h, hex_q, hex_r = pcall(world_to_hex, pt)
		if ok_h and type(hex_q) == "number" and type(hex_r) == "number" then
			q, r = hex_q, hex_r
		end
	end
	local reserved = context and context.wonder_reserved_hexes
		or UndergroundWonderReservedHexes(map)
	if reserved and type(q) == "number" and reserved[CoordinateHexKey(q, r)] then
		return false
	end
	if not hex_grid then
		return strict ~= true
	end

	-- Match DepositMarker:FindUnobstructedDepositPos before falling back to a center-hex query.
	-- The native helper checks the complete vanilla deposit obstruction radius, not merely the hex
	-- containing the marker coordinate.
	local is_deposit_obstructed = context and context.is_deposit_obstructed
		or Global("IsDepositObstructed")
	local const_tbl = not context and Global("const") or nil
	local radius = context and context.deposit_obstruct_radius
		or (type(const_tbl) == "table" and tonumber(const_tbl.DepositObstructMaxRadius) or nil)
	if type(is_deposit_obstructed) == "function" and type(radius) == "number"
		and type(pt.xy) == "function" then
		local x, y = pt:xy()
		if type(x) == "number" and type(y) == "number" then
			local ok_native, obstructed = pcall(is_deposit_obstructed, hex_grid, x, y, radius)
			if ok_native then
				return not obstructed
			end
		end
	end

	local get_obstructions = context and context.get_build_obstructions
		or hex_grid.GetBuildObstructions
	if not (type(get_obstructions) == "function"
		and type(world_to_hex) == "function") then
		return strict ~= true
	end
	if type(q) ~= "number" or type(r) ~= "number" then
		return strict ~= true
	end
	local ok_o, obstructions = pcall(get_obstructions, hex_grid, q, r)
	if not ok_o then
		return strict ~= true
	end
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
	state.connectivity_check = connectivity_check
	state.pf_api = pf_api
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
	state.world_to_hex = world_to_hex
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
	return state
end

local function IsReachableFromUndergroundEntrance(map, pt, known_q, known_r)
	local state = BuildUndergroundReachability(map)
	if not state or state.available ~= true or not pt then return false end
	local target = pt
	if type(pt.SetTerrainZ) == "function" then
		local ok_z, snapped = pcall(pt.SetTerrainZ, pt, map)
		if ok_z and snapped then target = snapped end
	end
	local world_to_hex = state.world_to_hex
	local key = type(known_q) == "number" and type(known_r) == "number"
		and (tostring(known_q) .. ":" .. tostring(known_r)) or tostring(target)
	if type(known_q) ~= "number" and type(world_to_hex) == "function" then
		local ok_h, q, r = pcall(world_to_hex, target)
		if ok_h and type(q) == "number" and type(r) == "number" then
			key = tostring(q) .. ":" .. tostring(r)
		end
	end
	local cached = state.results[key]
	if cached ~= nil then return cached == true end
	state.checks = state.checks + 1
	local connectivity_check = state.connectivity_check
	local pf_api = state.pf_api
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

-- Evaluate the immutable terrain predicates once and return the values needed by diagnostics and
-- later placement indexes. Several anomaly paths used to call PassableAt/FlatnessAt/IsBuildableAt
-- separately and then call CanReceiveDepositTerrain, repeating the same native grid queries for
-- the identical point. Multiple return values preserve the old boolean API for existing callers.
local function EvaluateDepositTerrain(map, pt, context, defer_reachability)
	context = type(context) == "table" and context.map == map and context or nil
	-- Top-ups use one terrain rule on both maps: passable, nearly horizontal, and accepted by the
	-- engine's authoritative buildable grid. Mountain membership is irrelevant; a flat mountain
	-- shelf is valid, while a passable slope is not. Native vanilla markers never pass through this
	-- validator and remain at their exact proportional coordinates.
	local underground = (context and context.underground == true)
		or (not context and IsUndergroundMap(map))
	local buildable, q, r
	-- Buildability is the cheapest authoritative rejection and is especially selective in the
	-- surface mountain ring and the underground black rock/void. Test it before the two terrain
	-- queries on both maps. The accepted set is the same conjunction as before; only failed points
	-- short-circuit sooner.
	buildable, q, r = IsBuildableAt(map, pt, true, context)
	if not buildable then return false, false, 0, false, q, r end
	local passable = PassableAt(map, pt, context)
	if not passable then return false, passable, 0, false end
	local flatness = FlatnessAt(map, pt, context) or 0
	if flatness < (context and context.flatness_minimum or TopUpFlatnessMinimum()) then
		return false, passable, flatness, false
	end
	-- UNDERGROUND: only the cavern floor is real accessible terrain; the surrounding rock/
	-- void passes the passable+flat tests (the whole map is passable since the expansion
	-- zeroes PassBorder, and the void is uniformly flat) -- which put topped-up anomalies
	-- out in the black inaccessible area. Require the hex to be BUILDABLE (the game's own
	-- accessibility measure: hills/rock/void are unbuildable, the floor is buildable), so
	-- every top-up/respace/even-out pool samples only the playable floor.
	if defer_reachability ~= true and underground then
		if not IsReachableFromUndergroundEntrance(map, pt, q, r) then
			return false, passable, flatness, buildable, q, r
		end
	end
	return true, passable, flatness, buildable, q, r
end

local function CanReceiveDepositTerrain(map, pt, context)
	return EvaluateDepositTerrain(map, pt, context)
end

local function CanReceiveDeposit(map, pt, context, defer_reachability)
	context = type(context) == "table" and context.map == map and context or nil
	-- Vanilla DepositMarker placement does not accept an obstructed coordinate: it searches for a
	-- replacement through FindUnobstructedDepositPos. Top-up candidates are final coordinates, so
	-- reject the same obstruction before cloning rather than relying on a later reveal-time move.
	local terrain_ok, passable, flatness, buildable, q, r =
		EvaluateDepositTerrain(map, pt, context, true)
	if not terrain_ok then
		return false, passable, flatness, buildable, q, r, nil
	end
	local unobstructed = IsUnobstructedAt(map, pt, true, context)
	if not unobstructed then
		return false, passable, flatness, buildable, q, r, false
	end
	local underground = (context and context.underground == true)
		or (not context and IsUndergroundMap(map))
	if underground and defer_reachability ~= true
		and not IsReachableFromUndergroundEntrance(map, pt, q, r) then
		return false, passable, flatness, buildable, q, r, unobstructed
	end
	return true, passable, flatness, buildable, q, r, unobstructed
end

-- Candidate generation can reject thousands of coordinates before a selector consumes one. The
-- underground native ConnectivityCheck is substantially more expensive than all of the immutable
-- terrain predicates combined, so optimized top-ups defer only that predicate until selection.
-- This gate is called before cloning/committing every selected candidate and memoizes the result on
-- the shared candidate table; final placement therefore keeps the exact same reachability rule.
local function UndergroundCandidateReachable(map, candidate, context)
	if not candidate then return false, false end
	local underground = (context and context.underground == true)
		or (not context and IsUndergroundMap(map))
	if not underground then return true, false end
	if candidate._sbm_underground_reachable ~= nil then
		return candidate._sbm_underground_reachable == true, false
	end
	local point_fn = Global("point")
	if type(point_fn) ~= "function" or type(candidate.x) ~= "number"
		or type(candidate.y) ~= "number" then
		candidate._sbm_underground_reachable = false
		return false, true
	end
	local reachable = IsReachableFromUndergroundEntrance(
		map, point_fn(candidate.x, candidate.y), candidate.q, candidate.r) == true
	candidate._sbm_underground_reachable = reachable
	return reachable, true
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

local function IsNativeEnrichmentMarker(marker)
	return IsEnrichmentMarker(marker)
		and marker.SuperBigMapResourceTopUp ~= true
		and marker.SuperBigMapAnomalyTopUp ~= true
		and marker.SuperBigMapEffectTopUp ~= true
		and marker.SuperBigMapEnrichmentClone ~= true
end

-- True for the N-sector-wide perimeter ring of the FINAL expanded map. This is the reserved
-- surface top-up ring: qualifying anomaly extras go here, while every other top-up family stays
-- out. Prefer the live sector's col/row; fall back to world-distance math when sector metadata is
-- unavailable. Vanilla-generated markers are never moved by this routing rule.
local function NewFinalOuterSectorRingContext(map)
	local city = map and map.City
	local cols, rows = 0, 0
	if city and type(city.MapSectors) == "table" then
		while type(city.MapSectors[cols + 1]) == "table" do cols = cols + 1 end
		if cols > 0 then
			while city.MapSectors[1][rows + 1] ~= nil do rows = rows + 1 end
		end
	end
	local map_w, map_h = MapWorldSize(map)
	local sector_step
	local get_step = Global("GetMapSectorTileSize")
	if map_w and map_h and type(get_step) == "function" then
		local ok_s, step = pcall(get_step, map)
		if ok_s and type(step) == "number" and step > 0 then sector_step = step end
	end
	return {
		map = map, cols = cols, rows = rows, map_w = map_w, map_h = map_h,
		sector_step = sector_step,
	}
end

local function IsInFinalOuterSectorRing(map, x, y, ring_sectors, sector, context)
	ring_sectors = math.max(0, math.floor(ring_sectors or 0))
	if ring_sectors <= 0 then return false end
	context = type(context) == "table" and context.map == map and context or nil
	sector = sector or SectorAtPoint(map, x, y)
	local col, row = sector and sector.col, sector and sector.row
	local cols, rows = context and context.cols or 0, context and context.rows or 0
	if not context then
		local uncached = NewFinalOuterSectorRingContext(map)
		cols, rows = uncached.cols, uncached.rows
		context = uncached
	end
	if type(col) == "number" and type(row) == "number" and cols > 0 and rows > 0 then
		return col <= ring_sectors or row <= ring_sectors
			or col > cols - ring_sectors or row > rows - ring_sectors
	end
	local map_w, map_h, step = context.map_w, context.map_h, context.sector_step
	if map_w and map_h and type(step) == "number" and step > 0 then
		local band = ring_sectors * step
		return x < band or y < band or x >= map_w - band or y >= map_h - band
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
	if sector and candidate.sector_key ~= nil then
		return sector, candidate.sector_key
	end
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

local function NewSectorBalancedCandidateSelector(map, candidates, label, candidate_filter,
	shared_loads)
	candidates = candidates or {}
	local balanced = cfg().TOPUP_SECTOR_BALANCED_PLACEMENT ~= false
	-- Surface sequential placement used to enumerate every DepositMarker again whenever one new
	-- candidate was consumed. A caller-owned load table is equivalent: Commit applies the only
	-- mutation made by this transaction, while native markers are immutable throughout the pass.
	local loads = shared_loads or BuildEnrichmentSectorLoads(map)
	local capacity, capacity_by_terrain = {}, {}
	-- Terrain-specific selection used to rescan the complete pool even though non-matching
	-- candidates are skipped before every dynamic predicate. Preserve that exact subsequence in an
	-- ordered index; whole-pool fallbacks still use the original candidate table.
	local candidates_by_terrain = {}
	local remaining, eligible_sector_set, eligible_sectors = 0, {}, 0
	for _, candidate in ipairs(candidates) do
		if not candidate.used then
			local terrain_key = tostring(candidate.terrain_type)
			candidate._sbm_selector_terrain_key = terrain_key
			local terrain_candidates = candidates_by_terrain[terrain_key]
			if not terrain_candidates then
				terrain_candidates = {}
				candidates_by_terrain[terrain_key] = terrain_candidates
			end
			terrain_candidates[#terrain_candidates + 1] = candidate
			local _, key = CandidateSector(map, candidate)
			if key then
				remaining = remaining + 1
				capacity[key] = (capacity[key] or 0) + 1
				if not eligible_sector_set[key] then
					eligible_sector_set[key] = true
					eligible_sectors = eligible_sectors + 1
				end
				local by_sector = capacity_by_terrain[terrain_key]
				if not by_sector then by_sector = {}; capacity_by_terrain[terrain_key] = by_sector end
				by_sector[key] = (by_sector[key] or 0) + 1
			end
		end
	end
	local selected_count, selected_sector_set, selected_sectors = 0, {}, 0
	local additions_by_sector, max_additions_to_sector = {}, 0

	local function take(terrain_type, context)
		local terrain_key = terrain_type ~= nil and tostring(terrain_type) or nil
		local terrain_capacity = terrain_key and capacity_by_terrain[terrain_key] or nil
		local source_candidates = terrain_key and candidates_by_terrain[terrain_key] or candidates
		if not source_candidates then return nil end
		local best, best_load, best_capacity = {}, nil, nil
		for _, candidate in ipairs(source_candidates) do
			if not candidate.used
				and (terrain_key == nil or candidate._sbm_selector_terrain_key == terrain_key)
				and (type(candidate_filter) ~= "function"
					or candidate_filter(candidate, context) == true) then
				local _, key = CandidateSector(map, candidate)
				local candidate_capacity = key
					and ((terrain_capacity and terrain_capacity[key]) or capacity[key]) or 0
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

-- The strict underground pass above preserves vanilla repulsion and capacity-normalized terrain
-- density. If that pass cannot satisfy the requested total, use farthest-point sampling for the
-- residual completion pass instead of dropping directly to arbitrary unique hexes. A hard axial
-- clearance prevents a small random reserve from ever making adjacent placements; spacing from
-- every existing enrichment is then the primary ranking criterion. Among candidates within 90% of the best
-- available nearest-neighbour distance, prefer sectors with fewer TOP-UP markers, then randomize
-- the sector and coordinate. This keeps the fallback organic rather than perfectly uniform while
-- preventing the largest connected cave-floor sectors from becoming the automatic sink.
local function BuildUndergroundTopUpSectorLoads(map)
	local loads = {}
	if not map or type(map.MapForEach) ~= "function" then return loads end
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not (marker and (marker.SuperBigMapResourceTopUp == true
			or marker.SuperBigMapAnomalyTopUp == true
			or marker.SuperBigMapEffectTopUp == true)) then return end
		local pos = ObjectPos(marker)
		if not (pos and type(pos.xy) == "function") then return end
		local x, y = pos:xy()
		if type(x) ~= "number" or type(y) ~= "number" then return end
		local key = EnrichmentSectorKey(SectorAtPoint(map, x, y))
		if key then loads[key] = (loads[key] or 0) + 1 end
	end)
	return loads
end

local function UndergroundEnrichmentPositions(map)
	local positions = {}
	if not map or type(map.MapForEach) ~= "function" then return positions end
	local world_to_hex = Global("WorldToHex")
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not IsEnrichmentMarker(marker) then return end
		local pos = ObjectPos(marker)
		if not (pos and type(pos.xy) == "function") then return end
		local x, y = pos:xy()
		if type(x) == "number" and type(y) == "number" then
			local ok_hex, q, r = false, nil, nil
			if type(world_to_hex) == "function" then
				ok_hex, q, r = pcall(world_to_hex, pos)
			end
			positions[#positions + 1] = {
				x = x, y = y,
				q = ok_hex and type(q) == "number" and q or nil,
				r = ok_hex and type(r) == "number" and r or nil,
			}
		end
	end)
	return positions
end

local function AxialHexDistance(q1, r1, q2, r2)
	if type(q1) ~= "number" or type(r1) ~= "number"
		or type(q2) ~= "number" or type(r2) ~= "number" then return nil end
	local dq, dr = q1 - q2, r1 - r2
	return math.max(math.abs(dq), math.abs(dr), math.abs(dq + dr))
end

local function UndergroundFallbackMinimumHexDistance()
	return math.max(2, math.floor(
		tonumber(cfg().UNDERGROUND_FALLBACK_MINIMUM_HEX_DISTANCE) or 6))
end

local function RoundedWorldDistance(distance_sq)
	if type(distance_sq) ~= "number" or distance_sq < 0 or distance_sq == math.huge then return 0 end
	return math.floor(math.sqrt(distance_sq) + 0.5)
end

local function NewWellSpacedUndergroundFallbackSelector(map, candidates, label, candidate_filter)
	candidates = candidates or {}
	local loads = BuildUndergroundTopUpSectorLoads(map)
	local enrichment_positions = UndergroundEnrichmentPositions(map)
	local minimum_hex_distance = UndergroundFallbackMinimumHexDistance()
	local remaining, eligible_sector_set, eligible_sectors = 0, {}, 0
	for _, candidate in ipairs(candidates) do
		if not candidate.used then
			local _, key = CandidateSector(map, candidate)
			if key then
				remaining = remaining + 1
				local nearest_distance_sq, nearest_hex_distance
				for _, pos in ipairs(enrichment_positions) do
					local dx, dy = candidate.x - pos.x, candidate.y - pos.y
					local distance_sq = dx * dx + dy * dy
					if nearest_distance_sq == nil or distance_sq < nearest_distance_sq then
						nearest_distance_sq = distance_sq
					end
					local hex_distance = AxialHexDistance(candidate.q, candidate.r, pos.q, pos.r)
					if hex_distance ~= nil
						and (nearest_hex_distance == nil or hex_distance < nearest_hex_distance) then
						nearest_hex_distance = hex_distance
					end
				end
				candidate._sbm_fallback_nearest_distance_sq = nearest_distance_sq
				candidate._sbm_fallback_nearest_hex_distance = nearest_hex_distance
				if not eligible_sector_set[key] then
					eligible_sector_set[key] = true
					eligible_sectors = eligible_sectors + 1
				end
			end
		end
	end
	local selected_count, selected_sector_set, selected_sectors = 0, {}, 0
	local additions_by_sector, max_additions_to_sector = {}, 0
	local minimum_selected_spacing_sq, minimum_selected_hex_distance
	local clearance_rejections, clearance_relaxations, relaxed_selected = 0, 0, 0
	local SPACING_BAND_PERCENT = 90

	local function take(terrain_type, context)
		local terrain_key = terrain_type ~= nil and tostring(terrain_type) or nil
		local eligible, below_minimum, best_spacing_sq = {}, {}, nil
		for _, candidate in ipairs(candidates) do
			if not candidate.used
				and (terrain_key == nil or tostring(candidate.terrain_type) == terrain_key)
				and type(candidate._sbm_fallback_nearest_hex_distance) == "number"
				and (type(candidate_filter) ~= "function"
					or candidate_filter(candidate, context) == true) then
				local _, key = CandidateSector(map, candidate)
				if key then
					local spacing_sq = candidate._sbm_fallback_nearest_distance_sq
					if spacing_sq == nil then spacing_sq = math.huge end
					local entry = { candidate = candidate, key = key, spacing_sq = spacing_sq }
					if candidate._sbm_fallback_nearest_hex_distance >= minimum_hex_distance then
						eligible[#eligible + 1] = entry
					else
						below_minimum[#below_minimum + 1] = entry
					end
				end
			end
		end
		-- Six hexes is the preferred clearance, not a reason to leave the enlarged map below
		-- its vanilla density. If every valid candidate is closer, retain the maximin policy and
		-- choose the farthest available candidate below the preference.
		local relaxed = false
		if #eligible == 0 and #below_minimum > 0 then
			eligible = below_minimum
			relaxed = true
			clearance_relaxations = clearance_relaxations + 1
			clearance_rejections = clearance_rejections + #below_minimum
		end
		if #eligible == 0 then return nil end
		for _, entry in ipairs(eligible) do
			if best_spacing_sq == nil or entry.spacing_sq > best_spacing_sq then
				best_spacing_sq = entry.spacing_sq
			end
		end
		local threshold_sq = best_spacing_sq == math.huge and math.huge
			or relaxed and best_spacing_sq
			or best_spacing_sq * SPACING_BAND_PERCENT * SPACING_BAND_PERCENT / 10000
		local best_load, sector_candidates, sector_keys = nil, {}, {}
		for _, entry in ipairs(eligible) do
			if entry.spacing_sq >= threshold_sq then
				local load = loads[entry.key] or 0
				if best_load == nil or load < best_load then
					best_load, sector_candidates, sector_keys = load, {}, { entry.key }
					sector_candidates[entry.key] = { entry.candidate }
				elseif load == best_load then
					local in_sector = sector_candidates[entry.key]
					if not in_sector then
						in_sector = {}
						sector_candidates[entry.key] = in_sector
						sector_keys[#sector_keys + 1] = entry.key
					end
					in_sector[#in_sector + 1] = entry.candidate
				end
			end
		end
		if #sector_keys == 0 then return nil end
		local key = sector_keys[RandInt(#sector_keys) + 1]
		local choices = sector_candidates[key]
		local candidate = choices[RandInt(#choices) + 1]
		candidate.used = true
		candidate._sbm_well_spaced_fallback_sector_key = key
		candidate._sbm_selected_fallback_spacing_sq =
			candidate._sbm_fallback_nearest_distance_sq
		candidate._sbm_selected_fallback_hex_distance =
			candidate._sbm_fallback_nearest_hex_distance
		candidate._sbm_fallback_spacing_relaxed = relaxed or nil
		remaining = math.max(0, remaining - 1)
		return candidate
	end

	local function commit(candidate)
		if not candidate or candidate.sector_load_committed then return false end
		candidate.sector_load_committed = true
		local key = candidate._sbm_well_spaced_fallback_sector_key or candidate.sector_key
		if key then
			loads[key] = (loads[key] or 0) + 1
			additions_by_sector[key] = (additions_by_sector[key] or 0) + 1
			max_additions_to_sector = math.max(max_additions_to_sector, additions_by_sector[key])
			if not selected_sector_set[key] then
				selected_sector_set[key] = true
				selected_sectors = selected_sectors + 1
			end
		end
		local selected_spacing_sq = candidate._sbm_selected_fallback_spacing_sq
		if type(selected_spacing_sq) == "number" and selected_spacing_sq < math.huge then
			minimum_selected_spacing_sq = minimum_selected_spacing_sq == nil
				and selected_spacing_sq or math.min(minimum_selected_spacing_sq, selected_spacing_sq)
		end
		local selected_hex_distance = candidate._sbm_selected_fallback_hex_distance
		if type(selected_hex_distance) == "number" then
			minimum_selected_hex_distance = minimum_selected_hex_distance == nil
				and selected_hex_distance
				or math.min(minimum_selected_hex_distance, selected_hex_distance)
		end
		for _, other in ipairs(candidates) do
			if not other.used and type(other.x) == "number" and type(other.y) == "number" then
				local dx, dy = other.x - candidate.x, other.y - candidate.y
				local distance_sq = dx * dx + dy * dy
				local nearest = other._sbm_fallback_nearest_distance_sq
				if nearest == nil or distance_sq < nearest then
					other._sbm_fallback_nearest_distance_sq = distance_sq
				end
				local hex_distance = AxialHexDistance(other.q, other.r, candidate.q, candidate.r)
				local nearest_hex = other._sbm_fallback_nearest_hex_distance
				if hex_distance ~= nil and (nearest_hex == nil or hex_distance < nearest_hex) then
					other._sbm_fallback_nearest_hex_distance = hex_distance
				end
			end
		end
		selected_count = selected_count + 1
		return true
	end

	local function stats()
		return {
			label = tostring(label or "underground residual"),
			strategy = "maximin_spacing_with_sector_diversity",
			spacing_band_percent = SPACING_BAND_PERCENT,
			eligible_sectors = eligible_sectors, selected_sectors = selected_sectors,
			selected = selected_count, remaining_candidates = remaining,
			max_additions_to_one_sector = max_additions_to_sector,
			minimum_selected_spacing_world = RoundedWorldDistance(minimum_selected_spacing_sq),
			minimum_required_hex_distance = minimum_hex_distance,
			minimum_selected_hex_distance = minimum_selected_hex_distance or 0,
			clearance_rejections = clearance_rejections,
			clearance_relaxations = clearance_relaxations,
			relaxed_selected = relaxed_selected,
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
local BADGE_SPACING_PATCH_VERSION = 2
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
	if not CanReceiveDeposit(map, pt) then return false end
	local ring_sectors = math.max(0, math.floor(cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3))
	if not IsUndergroundMap(map) and ring_sectors > 0 then
		local in_ring = IsInFinalOuterSectorRing(map, x, y, ring_sectors)
		if marker.SuperBigMapEdgeTopUp and not in_ring then return false end
		if (marker.SuperBigMapResourceTopUp or marker.SuperBigMapEffectTopUp) and in_ring then return false end
	end
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
		local additional = marker and (marker.SuperBigMapResourceTopUp == true
			or marker.SuperBigMapAnomalyTopUp == true
			or marker.SuperBigMapEffectTopUp == true
			or marker.SuperBigMapEnrichmentClone == true)
		if additional and BadgeSpacingEnabledOnMap(map) and IsBadgeMarker(marker)
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
				StampResolvedBadgeHex(marker, candidate.q, candidate.r)
				sector, x, y, obstructed, moved = candidate.sector, candidate.x, candidate.y, false, true
			elseif not already_resolved and reason == "free" then
				StampResolvedBadgeHex(marker, target_q, target_r)
			end
		end
		return sector, x, y, obstructed, moved
	end
	State.badge_spacing_find_sector_original = original
	State.badge_spacing_find_sector_wrapper = wrapper
	State.badge_spacing_patch_version = BADGE_SPACING_PATCH_VERSION
	cls.FindSectorPos = wrapper
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
	if not ExpansionStepEnabled(3) or not ExpansionStepEnabled(18) then return 0 end
	map = map or Global("CurrentMap")
	if not BadgeSpacingEnabledOnMap(map) or type(map.MapForEach) ~= "function" then return 0, 0 end
	local markers = {}
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if marker and IsBadgeMarker(marker) then markers[#markers + 1] = marker end
	end)
	local function is_additional(marker)
		return marker and (marker.SuperBigMapResourceTopUp == true
			or marker.SuperBigMapAnomalyTopUp == true
			or marker.SuperBigMapEffectTopUp == true
			or marker.SuperBigMapEnrichmentClone == true)
	end
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
		-- Native transformed markers are immutable stage-03 obstacles. Reserve their hexes before
		-- inspecting additions so only an added marker can ever be displaced by this pass.
		if marker.is_placed == true or not is_additional(marker) then reserve_object(marker) end
	end
	local moved, unresolved = 0, 0
	for _, marker in ipairs(markers) do
		if is_additional(marker) and marker.is_placed ~= true then
			local pos = ObjectPos(marker)
			local x, y
			if pos and type(pos.xy) == "function" then x, y = pos:xy() end
			local q, r, key = BadgeObjectHex(marker)
			if key and BadgeHexOccupied(occupied, q, r) then
		local candidate = FindNearestFreeBadgePosition(marker, map, x, y, occupied)
				local old_sector = SectorAtPoint(map, x, y)
				if candidate and MoveBadgeMarker(marker, map, candidate, old_sector) then
					occupied[BadgeHexKey(candidate.q, candidate.r)] = true
					moved = moved + 1
				else
					occupied[key] = true
					unresolved = unresolved + 1
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
	return moved, remaining_overlaps
end

function DepositRules.BuildBadgeOccupancy(map, ignore_marker, ignore_object)
	return BuildBadgeOccupancy(map, ignore_marker, ignore_object, false)
end

function DepositRules.BadgeHexOccupied(occupied, q, r)
	return BadgeHexOccupied(occupied, q, r)
end

function DepositRules.ApplyModBehavior()
	if not ExpansionStepEnabled(3) or not ExpansionStepEnabled(18) then
		RestoreBadgeOverlapPrevention()
		return false
	end
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
end

-- Per-clone handling: clear is_placed so an added RESOURCE marker follows normal
-- scan-time spawning and concrete painting.
function DepositRules.ProcessClone(_map, _source, clone)
	if IsResourceDepositMarker(clone) then
		clone.is_placed = false
	else
		-- defensive: if a spawned subsurface deposit/anomaly object ever gets cloned, hide it.
		DepositRules.HideClone(clone)
	end
end

-- Keep concrete terrain imprints consistent when stretch-time scan gating or
-- underground reachability moves/hides a concrete marker. Runs inside the caller's
-- bounded paused-ILD transaction because the type-grid flood fill is a hot loop.
local function MoveConcreteImprints(map, moves)
	if cfg().CLEAR_INITIAL_CONCRETE_IMPRINT ~= true then return end
	if type(moves) ~= "table" or #moves == 0 then return end

	local terrain_api = Global("terrain")
	if type(terrain_api) ~= "table"
		or type(terrain_api.GetTypeGrid) ~= "function"
		or type(terrain_api.SetTypeGrid) ~= "function" then
		return
	end

	local get_idx = Global("GetTerrainTextureIndex")
	if type(get_idx) ~= "function" then
		return
	end
	local ok1, reg1 = pcall(get_idx, "Regolith")
	local ok2, reg2 = pcall(get_idx, "Regolith_02")
	reg1 = (ok1 and type(reg1) == "number") and reg1 or nil
	reg2 = (ok2 and type(reg2) == "number") and reg2 or nil
	if reg1 == nil and reg2 == nil then
		return
	end

	local grid = SafeCall(terrain_api.GetTypeGrid, map)
	if not grid or type(grid.get) ~= "function"
		or type(grid.set) ~= "function" or type(grid.size) ~= "function" then
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

end

-- Register added RESOURCE markers with their final map sectors so scanning them spawns
-- the deposit (vanilla RevealDeposits
-- reads sector.markers, which is populated by sector:RegisterDeposit). Idempotent.
-- SURFACE ONLY: underground enrichments must not depend on sector mechanics (user directive)
-- -- there the unplaced clone markers are placed+revealed by the proximity DepositRevealer.
function DepositRules.RegisterClonedMarkers(map)
	if not ExpansionStepEnabled(3) or not ExpansionStepEnabled(20) then
		return
	end
	map = map or Global("CurrentMap")
	if IsUndergroundMap(map) then
		return
	end
	if cfg().OPTIMIZE_TOPUP_PLACEMENT_POOLS == true then
		return
	end
	local city = map and map.City
	local get_sector = Global("GetMapSectorXY")
	if not city or type(map.MapForEach) ~= "function" or type(get_sector) ~= "function" then
		return
	end
	local count = 0
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if marker and marker.SuperBigMapEnrichmentClone and IsResourceDepositMarker(marker) then
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

-- Vanilla applies the family repulsion fields while selecting each new enrichment location.
-- Native resource deposits may contain several adjacent marker objects in one generated cluster,
-- so those preserved native/native pairs are intentionally not rewritten. Every NEW top-up is,
-- however, treated as a new selection and must clear every native marker and earlier top-up.
-- Spatial buckets keep the check proportional to nearby markers instead of rescanning the map.
local function NewTopUpRepulsionTracker(map, label, ignored_markers, capture_rejections)
	local point_fn = Global("point")
	local world_to_hex = Global("WorldToHex")
	local BUCKET_SIZE = 65536
	local buckets, occupied_hexes = {}, {}
	local placement_cache, profile_keys, obstacle_generation = {}, {}, 0
	local max_same, max_layer, max_all = 0, 0, 0
	local stats = {
		label = tostring(label or "top-up"), seeded = 0, committed = 0,
		checks = 0, nearby_pair_checks = 0, duplicate_hex_rejects = 0,
		repulsion_rejects = 0, missing_profile_rejects = 0,
		invalid_position_rejects = 0, seed_missing_profile = 0,
		first_rejection = "", last_rejection = "",
	}
	local function note_rejection(detail)
		if capture_rejections ~= true then return end
		detail = tostring(detail or "unknown")
		stats.last_rejection = detail
		if stats.first_rejection == "" then stats.first_rejection = detail end
	end
	local function marker_identity(marker, profile, is_topup)
		return table.concat({
			tostring(marker and marker.class or "?"),
			tostring(marker and marker.resource or profile and profile.resource or "?"),
			is_topup and "topup" or "native",
		}, "/")
	end

	local function bucket_coordinate(value)
		return math.floor((value + 0.0) / BUCKET_SIZE)
	end

	local function bucket_at(bx, by, create)
		local column = buckets[bx]
		if not column and create then
			column = {}
			buckets[bx] = column
		end
		local bucket = column and column[by]
		if not bucket and create then
			bucket = {}
			column[by] = bucket
		end
		return bucket
	end

	local function hex_key(x, y)
		if type(point_fn) ~= "function" or type(world_to_hex) ~= "function" then return nil end
		local ok, q, r = pcall(world_to_hex, point_fn(x, y))
		if not ok or type(q) ~= "number" or type(r) ~= "number" then return nil end
		return tostring(q) .. ":" .. tostring(r)
	end

	local function add_entry(x, y, profile, marker, is_topup)
		if type(x) ~= "number" or type(y) ~= "number" or not profile then return false end
		local bucket = bucket_at(bucket_coordinate(x), bucket_coordinate(y), true)
		bucket[#bucket + 1] = {
			x = x, y = y, profile = profile, marker = marker, is_topup = is_topup == true,
		}
		local hkey = hex_key(x, y)
		if hkey then occupied_hexes[hkey] = (occupied_hexes[hkey] or 0) + 1 end
		max_same = math.max(max_same, profile.repulse_same or 0)
		max_layer = math.max(max_layer, profile.repulse_layer or 0)
		max_all = math.max(max_all, profile.repulse_all or 0)
		return true
	end

	local function profile_cache_key(profile)
		local cached = profile_keys[profile]
		if cached then return cached end
		cached = table.concat({
			tostring(profile.layer), tostring(profile.resource),
			tostring(profile.repulse_same), tostring(profile.repulse_layer),
			tostring(profile.repulse_all),
		}, ":")
		profile_keys[profile] = cached
		return cached
	end

	local function cached_verdict(candidate, profile_key)
		local by_profile = placement_cache[candidate]
		local cached = by_profile and by_profile[profile_key]
		if not cached then return nil end
		if cached.result == false or cached.generation == obstacle_generation then
			return cached.result
		end
		return nil
	end

	local function remember_verdict(candidate, profile_key, result)
		local by_profile = placement_cache[candidate]
		if not by_profile then
			by_profile = {}
			placement_cache[candidate] = by_profile
		end
		by_profile[profile_key] = { result = result == true, generation = obstacle_generation }
		return result
	end

	if map and type(map.MapForEach) == "function" then
		pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
			if type(ignored_markers) == "table" and ignored_markers[marker] == true then return end
			if not IsEnrichmentMarker(marker) then return end
			local pos = ObjectPos(marker)
			if not (pos and type(pos.xy) == "function") then return end
			local x, y = pos:xy()
			local profile = VanillaRepulsionProfileForMarker(map, marker)
			if not profile then
				local hkey = type(x) == "number" and type(y) == "number" and hex_key(x, y) or nil
				if hkey then occupied_hexes[hkey] = (occupied_hexes[hkey] or 0) + 1 end
				stats.seed_missing_profile = stats.seed_missing_profile + 1
				return
			end
			if add_entry(x, y, profile, marker,
				marker.SuperBigMapResourceTopUp == true
					or marker.SuperBigMapAnomalyTopUp == true
					or marker.SuperBigMapEffectTopUp == true) then
				stats.seeded = stats.seeded + 1
			end
		end)
	end

	local function can_place(candidate, profile)
		stats.checks = stats.checks + 1
		if not profile then
			stats.missing_profile_rejects = stats.missing_profile_rejects + 1
			if capture_rejections == true then note_rejection("missing_profile") end
			return false
		end
		local x, y = candidate and candidate.x, candidate and candidate.y
		if type(x) ~= "number" or type(y) ~= "number" then
			stats.invalid_position_rejects = stats.invalid_position_rejects + 1
			if capture_rejections == true then
				note_rejection("invalid_position=" .. tostring(x) .. "," .. tostring(y))
			end
			return false
		end
		local hkey = candidate._sbm_repulsion_hex
		if not hkey then
			hkey = hex_key(x, y)
			candidate._sbm_repulsion_hex = hkey
		end
		if not hkey then
			stats.invalid_position_rejects = stats.invalid_position_rejects + 1
			if capture_rejections == true then
				note_rejection("invalid_hex@" .. tostring(x) .. "," .. tostring(y))
			end
			return false
		end
		local profile_key = profile_cache_key(profile)
		local cached = cached_verdict(candidate, profile_key)
		if cached ~= nil then return cached end
		if occupied_hexes[hkey] then
			stats.duplicate_hex_rejects = stats.duplicate_hex_rejects + 1
			if capture_rejections == true then
				note_rejection("duplicate_hex=" .. tostring(hkey)
					.. ":candidate=" .. tostring(profile.layer) .. "/" .. tostring(profile.resource))
			end
			return remember_verdict(candidate, profile_key, false)
		end
		local search_radius = math.max(
			(profile.repulse_same or 0) + max_same,
			(profile.repulse_layer or 0) + max_layer,
			(profile.repulse_all or 0) + max_all)
		local bucket_radius = math.ceil((search_radius + 0.0) / BUCKET_SIZE)
		local bx, by = candidate._sbm_repulsion_bucket_x, candidate._sbm_repulsion_bucket_y
		if type(bx) ~= "number" or type(by) ~= "number" then
			bx, by = bucket_coordinate(x), bucket_coordinate(y)
			candidate._sbm_repulsion_bucket_x, candidate._sbm_repulsion_bucket_y = bx, by
		end
		for ix = bx - bucket_radius, bx + bucket_radius do
			for iy = by - bucket_radius, by + bucket_radius do
				local bucket = bucket_at(ix, iy, false)
				if bucket then
					for _, entry in ipairs(bucket) do
						stats.nearby_pair_checks = stats.nearby_pair_checks + 1
						local required = PairRepulsionRadius(profile, entry.profile)
						local dx, dy = x - entry.x, y - entry.y
						if type(required) == "number"
							and dx * dx + dy * dy <= required * required then
							stats.repulsion_rejects = stats.repulsion_rejects + 1
							if capture_rejections == true then
								note_rejection("repulsion:candidate="
									.. tostring(profile.layer) .. "/" .. tostring(profile.resource)
									.. "@" .. tostring(hkey)
									.. ":blocker=" .. marker_identity(
										entry.marker, entry.profile, entry.is_topup)
									.. "@" .. tostring(hex_key(entry.x, entry.y))
									.. ":required=" .. tostring(required)
									.. ":actual=" .. tostring(
										RoundedWorldDistance(dx * dx + dy * dy)))
							end
							return remember_verdict(candidate, profile_key, false)
						end
					end
				end
			end
		end
		return remember_verdict(candidate, profile_key, true)
	end

	-- Used only after an underground family has exhausted every fully vanilla-spaced candidate.
	-- The residual completion pass still forbids any two enrichments from sharing one hex.
	local function can_place_unique(candidate)
		stats.checks = stats.checks + 1
		local x, y = candidate and candidate.x, candidate and candidate.y
		if type(x) ~= "number" or type(y) ~= "number" then
			stats.invalid_position_rejects = stats.invalid_position_rejects + 1
			if capture_rejections == true then
				note_rejection("invalid_position=" .. tostring(x) .. "," .. tostring(y))
			end
			return false
		end
		local hkey = candidate._sbm_repulsion_hex
		if not hkey then
			hkey = hex_key(x, y)
			candidate._sbm_repulsion_hex = hkey
		end
		if not hkey then
			stats.invalid_position_rejects = stats.invalid_position_rejects + 1
			if capture_rejections == true then
				note_rejection("invalid_hex@" .. tostring(x) .. "," .. tostring(y))
			end
			return false
		end
		if occupied_hexes[hkey] then
			stats.duplicate_hex_rejects = stats.duplicate_hex_rejects + 1
			if capture_rejections == true then
				note_rejection("unique_duplicate_hex=" .. tostring(hkey))
			end
			return false
		end
		return true
	end

	local function commit(candidate, profile, marker)
		if not candidate or not profile then return false end
		if not add_entry(candidate.x, candidate.y, profile, marker, true) then return false end
		obstacle_generation = obstacle_generation + 1
		stats.committed = stats.committed + 1
		return true
	end

	return {
		CanPlace = can_place,
		CanPlaceUnique = can_place_unique,
		Commit = commit,
		Stats = function() return stats end,
	}
end

-- Stage 01 invariant: capture the generator's native enrichment coordinates exactly once.
-- Stage 02 transforms from these immutable coordinates, never from a position that another
-- post-generation callback may already have changed.
function DepositRules.CaptureNativeEnrichmentPositions(map, reason)
	if not ExpansionStepEnabled(1) or not ExpansionStepEnabled(6) then return 0 end
	map = map or Global("CurrentMap")
	if not map or type(map.MapForEach) ~= "function" then return 0 end
	local pending_records = pending_native_enrichment_records_by_map[map]
	if type(pending_records) == "table" then
		-- The live source objects are intentionally absent between stages 01 and 02. Do not let an
		-- intervening finalization pass overwrite the durable source count with zero.
		return #pending_records
	end
	if map.SuperBigMapNativeEnrichmentCaptureDone == true then
		return tonumber(map.SuperBigMapNativeEnrichmentCaptureCount) or 0
	end
	local xxhash = Global("xxhash")
	local captured = 0
	-- Only the temporary vanilla-source migration consumes value records immediately after this
	-- coordinate pass. Destination/finalization calls are capture-only and must not retain live
	-- object references for the rest of the map lifetime.
	local cache_live_objects = map.SuperBigMapVanillaSourceMigration == true
	local captured_objects = cache_live_objects and {} or nil
	captured_native_enrichment_objects_by_map[map] = nil
	local capture_ok, capture_error = pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not IsNativeEnrichmentMarker(marker) then return end
		-- Retain invalid-position markers too. CaptureNativeEnrichmentRecords must still observe them
		-- and fire its existing missing-position invariant instead of silently comparing two filtered
		-- counts from the same traversal.
		if captured_objects then captured_objects[#captured_objects + 1] = marker end
		local pos = ObjectPos(marker)
		if not (pos and type(pos.xy) == "function") then return end
		local x, y = pos:xy()
		if type(x) ~= "number" or type(y) ~= "number" then return end
		local z, position_hash
		if type(pos.z) == "function" then
			local ok_z, value = pcall(pos.z, pos)
			if ok_z then z = value end
		end
		if type(xxhash) == "function" then
			local ok_hash, value = pcall(xxhash, pos)
			if ok_hash then position_hash = value end
		end
		marker.SuperBigMapNativeSourceX = x
		marker.SuperBigMapNativeSourceY = y
		marker.SuperBigMapNativeSourceZ = z
		marker.SuperBigMapNativeSourceHash = position_hash
		captured = captured + 1
	end)
	if not capture_ok then
		map.SuperBigMapNativeEnrichmentCapturePending = true
		error("native enrichment coordinate capture failed: " .. tostring(capture_error))
	end
	map.SuperBigMapNativeEnrichmentCaptureDone = true
	map.SuperBigMapNativeEnrichmentCapturePending = false
	map.SuperBigMapNativeEnrichmentCaptureCount = captured
	if captured_objects then captured_native_enrichment_objects_by_map[map] = captured_objects end
	return captured
end

local function CloneNativePropertyValue(marker, value, prop_meta)
	if type(marker.ClonePropertyValue) == "function" then
		local ok, cloned = pcall(marker.ClonePropertyValue, marker, value, prop_meta)
		if ok then return cloned end
	end
	if type(value) ~= "table" then return value end
	local copy = table.copy
	if type(copy) == "function" then
		local ok, cloned = pcall(copy, value, "deep")
		if ok then return cloned end
	end
	local seen = {}
	local function clone_plain(input)
		if type(input) ~= "table" then return input end
		if seen[input] then return seen[input] end
		local output = {}
		seen[input] = output
		for key, item in pairs(input) do output[clone_plain(key)] = clone_plain(item) end
		return output
	end
	return clone_plain(value)
end

local function NativePropertyIsPortable(prop_meta)
	if type(prop_meta) ~= "table" then return false end
	local id = prop_meta.id
	if id == nil or id == "Deposit" or id == "Pos"
		or tostring(id):sub(1, 4) == "dbg_" then return false end
	-- Object/grid references belong to the temporary map; transient/read-only/dont-save values are
	-- derived runtime state. Pos is captured separately as immutable source coordinates and must be
	-- transformed, not copied or compared as an ordinary property. Reconstruct only constructor-safe
	-- gameplay properties.
	if prop_meta.developer or prop_meta.read_only or prop_meta.dont_save
		or prop_meta.editor == "object" or prop_meta.editor == "grid" then return false end
	return true
end

local function PortableNativeProperties(marker)
	local optimize = cfg().OPTIMIZE_NATIVE_ENRICHMENT_RECORD_CAPTURE == true
	local class = tostring(marker and marker.class or "")
	if optimize and class ~= "" then
		local cached = portable_native_properties_by_class[class]
		if cached then return cached end
	end
	local ok_props, properties = pcall(marker.GetProperties, marker)
	if not ok_props or type(properties) ~= "table" then return false end
	local portable = {}
	for i = 1, #properties do
		local prop_meta = properties[i]
		if NativePropertyIsPortable(prop_meta) then
			portable[#portable + 1] = prop_meta
		end
	end
	if optimize and class ~= "" then portable_native_properties_by_class[class] = portable end
	return portable
end

-- Property metadata defaults are not always the live subclass value. In particular,
-- SubsurfaceRareAnomalyMarker inherits the sequence_list property whose metadata default is
-- GenericAnomalies, while the concrete class overrides the live field to its rare-anomaly list.
-- Preserve these constructor-critical values directly from the generated source object.
local native_stable_property_ids = {
	"resource", "max_amount", "grade", "depth_layer", "entity_variant",
	"deposit_type", "tech_action", "sequence", "sequence_list", "scan_msg", "revealed",
	"granted_resource", "granted_amount", "display_name", "description",
}

local function CaptureNativeMarkerProperties(marker)
	local values, ids = {}, {}
	if type(marker.GetProperties) ~= "function" or type(marker.GetProperty) ~= "function" then
		return values, ids
	end
	local properties = PortableNativeProperties(marker)
	if type(properties) ~= "table" then return values, ids end
	for i = 1, #properties do
		local prop_meta = properties[i]
		local id = prop_meta.id
		local ok_value, value = pcall(marker.GetProperty, marker, id)
		if ok_value and value ~= nil then
			values[id] = CloneNativePropertyValue(marker, value, prop_meta)
			ids[#ids + 1] = tostring(id)
		end
	end
	local captured_ids = {}
	for i = 1, #ids do captured_ids[ids[i]] = true end
	for i = 1, #native_stable_property_ids do
		local id = native_stable_property_ids[i]
		local ok_value, value = pcall(function() return marker[id] end)
		if ok_value and value ~= nil then
			values[id] = CloneNativePropertyValue(marker, value, nil)
			if not captured_ids[id] then
				captured_ids[id] = true
				ids[#ids + 1] = id
			end
		end
	end
	table.sort(ids)
	return values, ids
end

local function NativeRecordSignature(records)
	local tokens = {}
	for i = 1, #records do
		local record = records[i]
		local props = record.properties or {}
		local token = {
			tostring(record.class), tostring(record.source_x), tostring(record.source_y),
			tostring(record.source_z),
		}
		for j = 1, #native_stable_property_ids do
			local id = native_stable_property_ids[j]
			token[#token + 1] = id .. "=" .. tostring(props[id])
		end
		tokens[#tokens + 1] = table.concat(token, ":")
	end
	local material = table.concat(tokens, "|")
	local xxhash = Global("xxhash")
	if type(xxhash) == "function" then
		local ok, value = pcall(xxhash, material)
		if ok then return tostring(value) end
	end
	return material
end

local function NativeClassCountsText(counts)
	local classes = {}
	for class in pairs(counts or {}) do classes[#classes + 1] = class end
	table.sort(classes)
	local parts = {}
	for i = 1, #classes do
		local class = classes[i]
		parts[#parts + 1] = tostring(class) .. "=" .. tostring(counts[class])
	end
	return table.concat(parts, ",")
end

-- Capture a map-independent constructor record for every native enrichment. The returned object
-- set is consumed by the temporary-map migration so these objects are not entrusted to
-- TransferToMap; their value records survive the source-slot unload instead.
function DepositRules.CaptureNativeEnrichmentRecords(map, reason)
	if not ExpansionStepEnabled(1) or not ExpansionStepEnabled(6) then
		return {}, {}, { count = 0, signature = "disabled", class_counts = {} }
	end
	map = map or Global("CurrentMap")
	if not map or type(map.MapForEach) ~= "function" then
		error("native enrichment record capture map API unavailable")
	end
	DepositRules.CaptureNativeEnrichmentPositions(map, reason)
	local records, excluded, class_counts = {}, {}, {}
	local missing_positions = 0
	local function capture_marker(marker)
		if not IsNativeEnrichmentMarker(marker) then return end
		excluded[marker] = true
		local x = marker.SuperBigMapNativeSourceX
		local y = marker.SuperBigMapNativeSourceY
		local z = marker.SuperBigMapNativeSourceZ
		if cfg().OPTIMIZE_NATIVE_ENRICHMENT_RECORD_CAPTURE ~= true
			or type(x) ~= "number" or type(y) ~= "number" then
			local pos = ObjectPos(marker)
			if not (pos and type(pos.xy) == "function") then
				missing_positions = missing_positions + 1
				return
			end
			x, y = pos:xy()
			if type(pos.z) == "function" then
				local ok_z, value = pcall(pos.z, pos)
				if ok_z then z = value end
			end
		end
		if type(x) ~= "number" or type(y) ~= "number" then
			missing_positions = missing_positions + 1
			return
		end
		local properties, property_ids = CaptureNativeMarkerProperties(marker)
		local record = {
			class = tostring(marker.class), source_x = x, source_y = y, source_z = z,
			source_hash = marker.SuperBigMapNativeSourceHash,
			properties = properties, property_ids = property_ids,
		}
		if type(marker.GetAngle) == "function" then
			local ok_angle, value = pcall(marker.GetAngle, marker)
			if ok_angle then record.angle = value end
		end
		if type(marker.GetScale) == "function" then
			local ok_scale, value = pcall(marker.GetScale, marker)
			if ok_scale then record.scale = value end
		end
		if type(marker.GetCollectionIndex) == "function" then
			local ok_collection, value = pcall(marker.GetCollectionIndex, marker)
			if ok_collection then record.collection_index = value end
		end
		records[#records + 1] = record
		class_counts[record.class] = (class_counts[record.class] or 0) + 1
	end
	local captured_objects = captured_native_enrichment_objects_by_map[map]
	local ok, capture_error
	if type(captured_objects) == "table" then
		ok, capture_error = pcall(function()
			for i = 1, #captured_objects do capture_marker(captured_objects[i]) end
		end)
	else
		ok, capture_error = pcall(map.MapForEach, map, "map", "DepositMarker", capture_marker)
	end
	captured_native_enrichment_objects_by_map[map] = nil
	if not ok then error("native enrichment record capture failed: " .. tostring(capture_error)) end
	if missing_positions > 0 then
		error("native enrichment record capture found " .. tostring(missing_positions) .. " markers without coordinates")
	end
	table.sort(records, function(a, b)
		if a.source_x ~= b.source_x then return a.source_x < b.source_x end
		if a.source_y ~= b.source_y then return a.source_y < b.source_y end
		if a.class ~= b.class then return a.class < b.class end
		return tostring(a.source_z) < tostring(b.source_z)
	end)
	for i = 1, #records do records[i].index = i end
	local stats = {
		count = #records, signature = NativeRecordSignature(records),
		class_counts = class_counts, class_counts_text = NativeClassCountsText(class_counts),
	}
	if AuditEnabled() then
		AuditEmit("NATIVE_SOURCE_SUMMARY", {
			reason = tostring(reason), count = #records, signature = stats.signature,
			class_counts = stats.class_counts_text, missing_positions = missing_positions,
		}, map)
		for i, record in ipairs(records) do
			local properties = record.properties or {}
			AuditEmit("NATIVE_SOURCE_MARKER", {
				index = i, class = record.class,
				resource = tostring(properties.resource), deposit_type = tostring(properties.deposit_type),
				tech_action = tostring(properties.tech_action), sequence = tostring(properties.sequence),
				sequence_list = tostring(properties.sequence_list),
				source_x = record.source_x, source_y = record.source_y, source_z = record.source_z,
				source_hash = tostring(record.source_hash), property_count = #(record.property_ids or {}),
			}, map)
		end
	end
	return records, excluded, stats
end

function DepositRules.StageNativeEnrichmentRecords(map, records, reason, known_signature)
	if not map or type(records) ~= "table" then return false, "map/records unavailable" end
	pending_native_enrichment_records_by_map[map] = records
	map.SuperBigMapNativeEnrichmentCaptureDone = false
	map.SuperBigMapNativeEnrichmentCapturePending = true
	map.SuperBigMapNativeEnrichmentCaptureCount = #records
	map.SuperBigMapNativeEnrichmentRecordSignature = known_signature or NativeRecordSignature(records)
	return true
end

-- Underground generation remains live on the expanded destination while its expensive stretch is
-- deferred. Immediately before that stretch, turn the native marker objects into the same durable
-- value records used by the temporary surface source, unregister and remove the source objects, and
-- let RecreateStagedNativeEnrichments construct them directly on their final proportional hexes.
-- Doing this at first underground access (rather than at initial generation) also makes save/load
-- before first access safe: the vanilla marker objects remain the persistent source of truth.
function DepositRules.StageAndRemoveNativeEnrichmentsForStretch(map, reason)
	map = map or Global("CurrentMap")
	if not map or type(map.MapForEach) ~= "function" then
		return false, { error = "map/MapForEach unavailable", captured = 0, removed = 0 }
	end
	local records, source_objects, capture_stats =
		DepositRules.CaptureNativeEnrichmentRecords(map, reason)
	if type(records) ~= "table" then
		return false, {
			error = "native enrichment capture returned no record table",
			captured = 0,
			removed = 0,
		}
	end
	local staged, stage_error = DepositRules.StageNativeEnrichmentRecords(
		map, records, reason, capture_stats and capture_stats.signature)
	if staged ~= true then
		return false, { error = tostring(stage_error), captured = #records, removed = 0 }
	end
	if #records == 0 then
		local stats = {
			captured = 0, removed = 0, removed_placed = 0, remaining = 0,
			signature = capture_stats and capture_stats.signature,
			class_counts = capture_stats and capture_stats.class_counts_text,
		}
		return true, stats
	end

	local done_object = Global("DoneObject")
	local is_valid = Global("IsValid")
	if type(done_object) ~= "function" then
		DepositRules.ClearStagedNativeEnrichmentRecords(map, "source-object removal unavailable")
		return false, { error = "DoneObject unavailable", captured = #records, removed = 0 }
	end
	local removed, removed_placed = 0, 0
	for marker in pairs(source_objects or {}) do
		UnregisterNativeMarker(map, marker)
		local placed_obj = marker and marker.placed_obj
		if placed_obj and (type(is_valid) ~= "function" or is_valid(placed_obj)) then
			pcall(done_object, placed_obj)
			removed_placed = removed_placed + 1
		end
		if marker and (type(is_valid) ~= "function" or is_valid(marker)) then
			pcall(done_object, marker)
			removed = removed + 1
		end
	end
	local remaining = 0
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if IsNativeEnrichmentMarker(marker) then remaining = remaining + 1 end
	end)
	local stats = {
		captured = #records,
		removed = removed,
		removed_placed = removed_placed,
		remaining = remaining,
		signature = capture_stats and capture_stats.signature,
		class_counts = capture_stats and capture_stats.class_counts_text,
	}
	if removed ~= #records or remaining ~= 0 then
		DepositRules.ClearStagedNativeEnrichmentRecords(map, "source-object removal verification failed")
		stats.error = "native marker removal verification failed"
		return false, stats
	end
	return true, stats
end

function DepositRules.HasStagedNativeEnrichmentRecords(map)
	local records = map and pending_native_enrichment_records_by_map[map]
	return type(records) == "table", type(records) == "table" and #records or 0
end

function DepositRules.ClearStagedNativeEnrichmentRecords(map, reason)
	if map then pending_native_enrichment_records_by_map[map] = nil end
end

function DepositRules.VerifyStagedNativeEnrichmentRecords(map, expected_count, expected_signature, reason)
	local records = map and pending_native_enrichment_records_by_map[map]
	local count = type(records) == "table" and #records or -1
	local signature = type(records) == "table" and NativeRecordSignature(records) or "missing"
	local ok = count == tonumber(expected_count) and tostring(signature) == tostring(expected_signature)
	local stats = {
		count = count, expected_count = tonumber(expected_count), signature = signature,
		expected_signature = tostring(expected_signature), reason = tostring(reason),
	}
	return ok, stats
end

local function NativePropertyValuesEqual(actual, expected)
	if actual == expected then return true end
	if type(actual) == "table" and type(expected) == "table"
		and type(table.equal_values) == "function" then
		local ok, equal = pcall(table.equal_values, actual, expected, -1)
		if ok then return equal == true end
	end
	return false
end

local function NativeRecordBaseGeometry(map, record)
	local point_fn = Global("point")
	local world_to_hex = Global("WorldToHex")
	if type(point_fn) ~= "function" or type(world_to_hex) ~= "function" then
		return nil, "point/WorldToHex API unavailable"
	end
	local source_w = tonumber(map.SuperBigMapSourceWidthTiles)
		or tonumber(map.SuperBigMapGeneratorWidthTiles)
	local source_h = tonumber(map.SuperBigMapSourceHeightTiles)
		or tonumber(map.SuperBigMapGeneratorHeightTiles)
	local final_w = tonumber(map.SuperBigMapDesiredWidthTiles)
	local final_h = tonumber(map.SuperBigMapDesiredHeightTiles)
	if not source_w or source_w <= 0 or not source_h or source_h <= 0
		or not final_w or final_w <= 0 or not final_h or final_h <= 0 then
		return nil, "source/final dimensions unavailable"
	end
	local origin_x = tonumber(map.SuperBigMapSourceX) or 0
	local origin_y = tonumber(map.SuperBigMapSourceY) or 0
	local scale_x = (final_w + 0.0) / source_w
	local scale_y = (final_h + 0.0) / source_h
	local raw_x = math.floor(origin_x + (record.source_x - origin_x) * scale_x + 0.5)
	local raw_y = math.floor(origin_y + (record.source_y - origin_y) * scale_y + 0.5)
	local ok_hex, q, r = pcall(world_to_hex, point_fn(raw_x, raw_y))
	if not ok_hex or type(q) ~= "number" or type(r) ~= "number" then
		return nil, "WorldToHex failed"
	end
	return {
		raw_x = raw_x, raw_y = raw_y, q = q, r = r,
		intended_q = q, intended_r = r,
		scale_x = scale_x, scale_y = scale_y,
	}
end

local function NativeRecordFinalPoint(map, record, planned_geometry)
	local point_fn = Global("point")
	local hex_to_world = Global("HexToWorld")
	if type(point_fn) ~= "function" or type(hex_to_world) ~= "function" then
		return nil, "point/HexToWorld API unavailable"
	end
	local geometry, geometry_error = planned_geometry, nil
	if not geometry then geometry, geometry_error = NativeRecordBaseGeometry(map, record) end
	if not geometry then return nil, geometry_error end
	local q = tonumber(record.SuperBigMapResolvedFinalQ) or geometry.q
	local r = tonumber(record.SuperBigMapResolvedFinalR) or geometry.r
	local ok_world, x, y = pcall(hex_to_world, q, r)
	if not ok_world or type(x) ~= "number" or type(y) ~= "number" then
		return nil, "HexToWorld failed"
	end
	local final_point = point_fn(x, y)
	if type(final_point.SetTerrainZ) ~= "function" then return nil, "SetTerrainZ unavailable" end
	local ok_z, terrain_point = pcall(final_point.SetTerrainZ, final_point, map)
	if not ok_z or not terrain_point then return nil, "SetTerrainZ failed: " .. tostring(terrain_point) end
	geometry.q, geometry.r, geometry.x, geometry.y = q, r, x, y
	geometry.intended_x, geometry.intended_y = x, y
	if q ~= geometry.intended_q or r ~= geometry.intended_r then
		local ok_intended, intended_x, intended_y = pcall(hex_to_world,
			geometry.intended_q, geometry.intended_r)
		if ok_intended and type(intended_x) == "number" and type(intended_y) == "number" then
			geometry.intended_x, geometry.intended_y = intended_x, intended_y
		end
	end
	geometry.collision_resolved = record.SuperBigMapTransformCollisionResolved == true
	geometry.wonder_reservation_resolved =
		record.SuperBigMapTransformWonderReservationResolved == true
	geometry.resolution_radius = record.SuperBigMapTransformCollisionResolutionRadius
	geometry.collision_owner_index = record.SuperBigMapTransformCollisionOwnerIndex
	return terrain_point, nil, geometry
end

local function NativeRecordSourceHexKey(record)
	local point_fn = Global("point")
	local world_to_hex = Global("WorldToHex")
	if type(point_fn) == "function" and type(world_to_hex) == "function"
		and type(record) == "table" and type(record.source_x) == "number"
		and type(record.source_y) == "number" then
		local ok, q, r = pcall(world_to_hex, point_fn(record.source_x, record.source_y))
		if ok and type(q) == "number" and type(r) == "number" then
			return tostring(q) .. ":" .. tostring(r), q, r
		end
	end
	return nil, nil, nil
end

-- Proportional world-space scaling followed by hex alignment is not injective. Two source points
-- can sit on opposite sides of a source-hex boundary yet land inside the same destination hex even
-- though their raw distance increased. Build the complete destination plan before constructing any
-- objects so every unaffected marker keeps its exact transformed hex and only the later member of
-- an introduced collision moves. Future primary targets are reserved as well, preventing a repair
-- from displacing a marker whose own proportional result was already unique.
local function PrepareNativeRecordFinalPointPlan(map, records, reason)
	local point_fn = Global("point")
	local hex_to_world = Global("HexToWorld")
	if type(point_fn) ~= "function" or type(hex_to_world) ~= "function" then
		return false, { error = "point/HexToWorld API unavailable" }
	end
	local map_w, map_h = MapWorldSize(map)
	local plans, primary_keys = {}, {}
	local wonder_reserved = UndergroundWonderReservedHexes(map)
	local stats = {
		records = #records, exact = 0, preserved_source_overlaps = 0,
		introduced_collisions = 0, resolved = 0, failures = 0, max_resolution_radius = 0,
		wonder_reservation_conflicts = 0, wonder_reservation_resolved = 0,
	}
	for i = 1, #records do
		local record = records[i]
		record.SuperBigMapResolvedFinalQ = nil
		record.SuperBigMapResolvedFinalR = nil
		record.SuperBigMapTransformCollisionResolved = nil
		record.SuperBigMapTransformWonderReservationResolved = nil
		record.SuperBigMapTransformCollisionResolutionRadius = nil
		record.SuperBigMapTransformCollisionOwnerIndex = nil
		local geometry, geometry_error = NativeRecordBaseGeometry(map, record)
		if not geometry then
			stats.failures = stats.failures + 1
			stats.error = "record " .. tostring(i) .. ": " .. tostring(geometry_error)
			return false, stats
		end
		local key = BadgeHexKey(geometry.q, geometry.r)
		plans[i] = geometry
		local owners = primary_keys[key]
		if not owners then owners = {}; primary_keys[key] = owners end
		owners[#owners + 1] = i
	end

	local occupied = {}
	local function candidate_for(q, r, raw_x, raw_y, radius)
		local key = BadgeHexKey(q, r)
		if occupied[key] or primary_keys[key]
			or (wonder_reserved and wonder_reserved[CoordinateHexKey(q, r)]) then return nil end
		local ok_world, x, y = pcall(hex_to_world, q, r)
		if not ok_world or type(x) ~= "number" or type(y) ~= "number"
			or (type(map_w) == "number" and (x < 0 or x >= map_w))
			or (type(map_h) == "number" and (y < 0 or y >= map_h)) then return nil end
		local pt = point_fn(x, y)
		if type(pt.SetTerrainZ) ~= "function" then return nil end
		local ok_z, terrain_point = pcall(pt.SetTerrainZ, pt, map)
		if not ok_z or not terrain_point then return nil end
		local dx, dy = x - raw_x, y - raw_y
		return { q = q, r = r, x = x, y = y, radius = radius, distance_sq = dx * dx + dy * dy }
	end

	for i = 1, #records do
		local record, geometry = records[i], plans[i]
		local key = BadgeHexKey(geometry.q, geometry.r)
		local owner_index = occupied[key]
		local reserved_conflict = wonder_reserved
			and wonder_reserved[CoordinateHexKey(geometry.q, geometry.r)] == true
		if not owner_index and not reserved_conflict then
			occupied[key] = i
			stats.exact = stats.exact + 1
		else
			local owner_record = records[owner_index]
			local owner_source_hex = NativeRecordSourceHexKey(owner_record)
			local source_hex = NativeRecordSourceHexKey(record)
			local source_overlap = not reserved_conflict and owner_record
				and ((owner_source_hex and source_hex
				and owner_source_hex == source_hex)
				or (not owner_source_hex and not source_hex
					and owner_record.source_x == record.source_x
					and owner_record.source_y == record.source_y))
			if source_overlap then
				stats.preserved_source_overlaps = stats.preserved_source_overlaps + 1
			else
				if reserved_conflict then
					stats.wonder_reservation_conflicts = stats.wonder_reservation_conflicts + 1
				else
					stats.introduced_collisions = stats.introduced_collisions + 1
				end
				local selected
				-- With N records, a radius of N is a derived finite bound: even a completely occupied
				-- local cluster cannot contain every in-bounds hex in all N rings on these maps.
				for radius = 1, math.max(1, #records) do
					for dq = -radius, radius do
						for dr = -radius, radius do
							local distance = (math.abs(dq) + math.abs(dr) + math.abs(dq + dr)) / 2
							if distance == radius then
								local candidate = candidate_for(geometry.q + dq, geometry.r + dr,
									geometry.raw_x, geometry.raw_y, radius)
								if candidate and (not selected
									or candidate.distance_sq < selected.distance_sq
									or (candidate.distance_sq == selected.distance_sq and candidate.q < selected.q)
									or (candidate.distance_sq == selected.distance_sq and candidate.q == selected.q
										and candidate.r < selected.r)) then
									selected = candidate
								end
							end
						end
					end
					if selected then break end
				end
				if not selected then
					stats.failures = stats.failures + 1
					stats.error = "record " .. tostring(i) .. ": no free final hex"
					return false, stats
				end
				record.SuperBigMapResolvedFinalQ = selected.q
				record.SuperBigMapResolvedFinalR = selected.r
				record.SuperBigMapTransformCollisionResolved = true
				record.SuperBigMapTransformWonderReservationResolved =
					reserved_conflict and true or nil
				record.SuperBigMapTransformCollisionResolutionRadius = selected.radius
				record.SuperBigMapTransformCollisionOwnerIndex = owner_index
				occupied[BadgeHexKey(selected.q, selected.r)] = i
				stats.resolved = stats.resolved + 1
				if reserved_conflict then
					stats.wonder_reservation_resolved = stats.wonder_reservation_resolved + 1
				end
				stats.max_resolution_radius = math.max(stats.max_resolution_radius, selected.radius)
			end
		end
	end
	return true, stats, plans
end

local function RegisterNativeMarkerWithFinalSector(map, marker, pos)
	if IsUndergroundMap(map) then
		-- Vanilla underground enrichments are discovered by proximity. Registering them with the
		-- surface scan-sector machinery can reveal/place them before the deferred underground map is
		-- entered, and can invoke placement against a grid that is still being rebuilt.
		marker.is_placed = false
		marker.placed_obj = false
		SetRevealedState(marker, false)
		return true, false, false
	end
	local city = map and map.City
	local get_sector = Global("GetMapSectorXY")
	if not city or type(get_sector) ~= "function" then return true, false, false end
	local x, y = pos:xy()
	local ok_sector, sector = pcall(get_sector, city, x, y)
	if not ok_sector or not sector or type(sector.RegisterDeposit) ~= "function" then
		return false, "final sector unavailable"
	end
	local ok_register, register_error = pcall(sector.RegisterDeposit, sector, marker)
	if not ok_register then return false, register_error end
	local revealed = false
	if SectorIsScanned(sector) then
		local reveal_deposits = Global("RevealDeposits")
		if type(reveal_deposits) ~= "function" then return false, "RevealDeposits unavailable" end
		local ok_reveal, reveal_error = pcall(reveal_deposits, { marker })
		if not ok_reveal then return false, reveal_error end
		revealed = true
	end
	return true, true, revealed
end

UnregisterNativeMarker = function(map, marker)
	local city = map and map.City
	local get_sector = Global("GetMapSectorXY")
	local pos = ObjectPos(marker)
	if not city or type(get_sector) ~= "function" or not pos or type(pos.xy) ~= "function" then return end
	local x, y = pos:xy()
	local ok, sector = pcall(get_sector, city, x, y)
	if ok and sector and type(sector.UnregisterDeposit) == "function" then
		pcall(sector.UnregisterDeposit, sector, marker)
	end
end

function DepositRules.VerifyRecreatedNativeEnrichments(map, records, reason)
	map = map or Global("CurrentMap")
	records = records or (map and pending_native_enrichment_records_by_map[map])
	local stats = {
		expected = type(records) == "table" and #records or 0, actual = 0,
		missing = 0, duplicates = 0, class_mismatches = 0, source_mismatches = 0,
		xy_mismatches = 0, z_mismatches = 0, property_mismatches = 0,
		coordinate_collisions = 0, registration_mismatches = 0,
		preserved_source_coordinate_collisions = 0,
		introduced_coordinate_collisions = 0,
		scanned_state_mismatches = 0, object_state_mismatches = 0,
	}
	if not map or type(map.MapForEach) ~= "function" or type(records) ~= "table" then
		stats.error = "map/records unavailable"
		stats.mismatches = 1
		return false, stats
	end
	local by_index = {}
	local enum_ok, enum_error = pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		local index = tonumber(marker.SuperBigMapNativeRecordIndex)
		if index then
			stats.actual = stats.actual + 1
			if by_index[index] then
				stats.duplicates = stats.duplicates + 1
			else
				by_index[index] = marker
			end
		end
	end)
	if not enum_ok then stats.error = tostring(enum_error) end
	local coordinate_owners = {}
	local city = map.City
	local get_sector = Global("GetMapSectorXY")
	local underground = IsUndergroundMap(map)
	local is_valid = Global("IsValid")
	for i = 1, #records do
		local record = records[i]
		local marker = by_index[i]
		if not marker then
			stats.missing = stats.missing + 1
		else
			if tostring(marker.class) ~= tostring(record.class) then
				stats.class_mismatches = stats.class_mismatches + 1
			end
			if marker.SuperBigMapNativeSourceX ~= record.source_x
				or marker.SuperBigMapNativeSourceY ~= record.source_y
				or marker.SuperBigMapNativeSourceZ ~= record.source_z then
				stats.source_mismatches = stats.source_mismatches + 1
			end
			if type(record.angle) == "number" and type(marker.GetAngle) == "function" then
				local ok_angle, value = pcall(marker.GetAngle, marker)
				if not ok_angle or value ~= record.angle then
					stats.object_state_mismatches = stats.object_state_mismatches + 1
				end
			end
			if type(record.scale) == "number" and type(marker.GetScale) == "function" then
				local ok_scale, value = pcall(marker.GetScale, marker)
				if not ok_scale or value ~= record.scale then
					stats.object_state_mismatches = stats.object_state_mismatches + 1
				end
			end
			if type(record.collection_index) == "number"
				and type(marker.GetCollectionIndex) == "function" then
				local ok_collection, value = pcall(marker.GetCollectionIndex, marker)
				if not ok_collection or value ~= record.collection_index then
					stats.object_state_mismatches = stats.object_state_mismatches + 1
				end
			end
			local expected = NativeRecordFinalPoint(map, record)
			local actual = ObjectPos(marker)
			local expected_x, expected_y, expected_z, actual_x, actual_y, actual_z
			if expected and type(expected.xy) == "function" then expected_x, expected_y = expected:xy() end
			if expected and type(expected.z) == "function" then expected_z = expected:z() end
			if actual and type(actual.xy) == "function" then actual_x, actual_y = actual:xy() end
			if actual and type(actual.z) == "function" then actual_z = actual:z() end
			if type(actual_x) == "number" and type(actual_y) == "number" then
				local coordinate_key = tostring(actual_x) .. ":" .. tostring(actual_y)
				local owner_index = coordinate_owners[coordinate_key]
				if owner_index then
					stats.coordinate_collisions = stats.coordinate_collisions + 1
					local owner_record = records[owner_index]
					local owner_source_hex = NativeRecordSourceHexKey(owner_record)
					local source_hex = NativeRecordSourceHexKey(record)
					-- Native placement is hex-based. Two different world points in the same source hex
					-- already overlap under vanilla placement semantics, so retaining that overlap is
					-- exact preservation rather than a collision introduced by proportional scaling.
					local preserved = owner_record and ((owner_source_hex and source_hex
						and owner_source_hex == source_hex)
						or (not owner_source_hex and not source_hex
							and owner_record.source_x == record.source_x
							and owner_record.source_y == record.source_y))
					if preserved then
						stats.preserved_source_coordinate_collisions =
							stats.preserved_source_coordinate_collisions + 1
					else
						stats.introduced_coordinate_collisions =
							stats.introduced_coordinate_collisions + 1
					end
				else
					coordinate_owners[coordinate_key] = i
				end
				if underground then
					local placed_obj = marker.placed_obj
					if marker.is_placed == true or (placed_obj
						and (type(is_valid) ~= "function" or is_valid(placed_obj) == true)) then
						stats.object_state_mismatches = stats.object_state_mismatches + 1
					end
				elseif city and type(get_sector) == "function" then
					local ok_sector, sector = pcall(get_sector, city, actual_x, actual_y)
					local registered = false
					if ok_sector and sector and type(sector.GetDepositList) == "function" then
						local ok_list, list = pcall(sector.GetDepositList, sector, marker)
						registered = ok_list and type(list) == "table" and list[marker] == true
					end
					if not registered then stats.registration_mismatches = stats.registration_mismatches + 1 end
					if ok_sector and sector and SectorIsScanned(sector) and marker.is_placed ~= true then
						stats.scanned_state_mismatches = stats.scanned_state_mismatches + 1
					end
				end
			end
			if not expected or actual_x ~= expected_x or actual_y ~= expected_y then
				stats.xy_mismatches = stats.xy_mismatches + 1
			end
			if not expected or actual_z ~= expected_z then stats.z_mismatches = stats.z_mismatches + 1 end
			if type(marker.GetProperty) == "function" then
				for id, expected_value in pairs(record.properties or {}) do
					local ok_value, actual_value = pcall(marker.GetProperty, marker, id)
					if not ok_value or not NativePropertyValuesEqual(actual_value, expected_value) then
						stats.property_mismatches = stats.property_mismatches + 1
					end
				end
			end
		end
	end
	stats.mismatches = (enum_ok and 0 or 1) + stats.missing + stats.duplicates
		+ stats.class_mismatches + stats.source_mismatches + stats.xy_mismatches
		+ stats.z_mismatches + stats.property_mismatches + stats.introduced_coordinate_collisions
		+ stats.registration_mismatches + stats.scanned_state_mismatches
		+ stats.object_state_mismatches
	if stats.actual ~= stats.expected then stats.mismatches = stats.mismatches + 1 end
	local verified = stats.mismatches == 0
	map.SuperBigMapNativeTransformVerified = verified
	map.SuperBigMapNativeTransformStats = stats
	return verified, stats
end

local function ScenarioListContains(sequence_list, sequence)
	local scenarios = Global("Scenarios")
	local list = type(scenarios) == "table" and scenarios[sequence_list] or nil
	if type(list) ~= "table" then return false end
	for i = 1, #list do
		if type(list[i]) == "table" and list[i].name == sequence then return true end
	end
	return false
end

local function PrepareAnomalyConstructorSequence(map, record, properties)
	local sequence = properties.sequence
	if type(sequence) ~= "string" or sequence == "" then return true end
	local original_list = properties.sequence_list
	if ScenarioListContains(original_list, sequence) then
		return true, { mode = "captured", original_list = original_list, final_list = original_list }
	end

	-- First reproduce the shipped game's own legacy correction before Init validates the pair.
	-- Calling it on the plain constructor table is safe and lets the corrected value reach Init.
	local class_table = Engine.ClassTable(record.class)
	if (properties.sequence_list == nil or properties.sequence_list == "")
		and type(class_table) == "table" then
		properties.sequence_list = class_table.sequence_list
	end
	local fix_sequence_list = Global("FixSequenceList")
	if type(fix_sequence_list) == "function" then
		pcall(fix_sequence_list, properties)
		if ScenarioListContains(properties.sequence_list, sequence) then
			return true, { mode = "vanilla_fix", original_list = original_list,
				final_list = properties.sequence_list }
		end
	end

	-- Derived anomaly classes can override the inherited property metadata default. Prefer the
	-- concrete class value before the generic scenario lookup.
	local class_list = type(class_table) == "table" and class_table.sequence_list or nil
	if ScenarioListContains(class_list, sequence) then
		properties.sequence_list = class_list
		return true, { mode = "class_default", original_list = original_list, final_list = class_list }
	end

	-- Compatibility fallback for custom scenarios: resolve the sequence by actual scenario
	-- membership, never by a hardcoded name. Accept only a unique match.
	local scenarios = Global("Scenarios")
	local matches = {}
	if type(scenarios) == "table" then
		for list_name, list in pairs(scenarios) do
			if type(list_name) == "string" and type(list) == "table"
				and ScenarioListContains(list_name, sequence) then
				matches[#matches + 1] = list_name
			end
		end
	end
	table.sort(matches)
	if #matches == 1 then
		properties.sequence_list = matches[1]
		return true, { mode = "unique_scenario_membership", original_list = original_list,
			final_list = matches[1] }
	end
	return false, { mode = #matches == 0 and "not_found" or "ambiguous",
		original_list = original_list, final_list = properties.sequence_list,
		matches = table.concat(matches, ",") }
end

-- Stage 02: after the terrain grid is stretched, reconstruct every source enrichment directly at
-- its final proportional hex. This avoids both TransferToMap ownership loss and any second random
-- selection. Constructor properties are supplied before Init (required by anomaly sequence checks).
function DepositRules.RecreateStagedNativeEnrichments(map, reason)
	map = map or Global("CurrentMap")
	local records = map and pending_native_enrichment_records_by_map[map]
	if type(records) ~= "table" then return false, { error = "no staged records", created = 0 } end
	if not ExpansionStepEnabled(2) or not ExpansionStepEnabled(8)
		or not ExpansionStepEnabled(9) then
		return false, { error = "expansion stage 02/08/09 disabled", created = 0, expected = #records }
	end
	local place_object_in = Global("PlaceObjectIn")
	local done_object = Global("DoneObject")
	if type(place_object_in) ~= "function" then
		return false, { error = "PlaceObjectIn unavailable", created = 0, expected = #records }
	end
	local created = {}
	local stats = { expected = #records, created = 0, registered = 0, revealed_in_scanned_sectors = 0 }
	local is_valid = Global("IsValid")
	local function cleanup_created()
		for i = #created, 1, -1 do
			local marker = created[i]
			UnregisterNativeMarker(map, marker)
			local placed_obj = marker and marker.placed_obj
			if placed_obj and type(done_object) == "function"
				and (type(is_valid) ~= "function" or is_valid(placed_obj)) then
				pcall(done_object, placed_obj)
			end
			if marker and type(done_object) == "function"
				and (type(is_valid) ~= "function" or is_valid(marker)) then
				pcall(done_object, marker)
			end
		end
	end
	local plan_ok, plan_stats, final_point_plans =
		PrepareNativeRecordFinalPointPlan(map, records, reason)
	stats.plan = plan_stats
	if not plan_ok then
		stats.error = tostring(plan_stats and plan_stats.error or "final-point plan failed")
		return false, stats
	end
	if AuditEnabled() then
		AuditEmit("NATIVE_TRANSFORM_PLAN_SUMMARY", {
			reason = tostring(reason), records = #records,
			exact = tostring(plan_stats and plan_stats.exact),
			preserved_source_overlaps = tostring(plan_stats and plan_stats.preserved_source_overlaps),
			introduced_collisions = tostring(plan_stats and plan_stats.introduced_collisions),
			resolved_collisions = tostring(plan_stats and plan_stats.resolved),
			wonder_reservation_conflicts = tostring(
				plan_stats and plan_stats.wonder_reservation_conflicts),
			wonder_reservation_resolved = tostring(
				plan_stats and plan_stats.wonder_reservation_resolved),
		}, map)
		for i, record in ipairs(records) do
			local final_point, transform_error, geometry = NativeRecordFinalPoint(
				map, record, final_point_plans and final_point_plans[i])
			local final_x, final_y, final_z
			if final_point and type(final_point.xy) == "function" then final_x, final_y = final_point:xy() end
			if final_point and type(final_point.z) == "function" then final_z = final_point:z() end
			AuditEmit("NATIVE_TRANSFORM_PLAN", {
				index = i, class = tostring(record.class),
				source_x = record.source_x, source_y = record.source_y, source_z = record.source_z,
				raw_x = geometry and geometry.raw_x, raw_y = geometry and geometry.raw_y,
				intended_x = geometry and geometry.intended_x, intended_y = geometry and geometry.intended_y,
				expected_x = final_x, expected_y = final_y, expected_z = final_z,
				final_hex = geometry and (tostring(geometry.q) .. ":" .. tostring(geometry.r)) or "nil",
				collision_resolved = tostring(geometry and geometry.collision_resolved == true),
				wonder_reservation_resolved = tostring(
					geometry and geometry.wonder_reservation_resolved == true),
				resolution_radius = tostring(geometry and geometry.resolution_radius),
				error = tostring(transform_error),
			}, map)
		end
	end
	local ok, recreate_error = pcall(function()
		for i = 1, #records do
			local record = records[i]
			local final_point, transform_error, geometry = NativeRecordFinalPoint(
				map, record, final_point_plans and final_point_plans[i])
			if not final_point then error("record " .. tostring(i) .. ": " .. tostring(transform_error)) end
			local constructor_properties = {}
			for id, value in pairs(record.properties or {}) do constructor_properties[id] = value end
			local sequence_ok, sequence_info =
				PrepareAnomalyConstructorSequence(map, record, constructor_properties)
			if not sequence_ok then
				error(string.format("record %s: cannot resolve anomaly sequence %s from list %s (%s; matches=%s)",
					tostring(i), tostring(constructor_properties.sequence),
					tostring(sequence_info and sequence_info.original_list),
					tostring(sequence_info and sequence_info.mode),
					tostring(sequence_info and sequence_info.matches)))
			end
			-- Verification must compare the recreated marker with the constructor state that can
			-- actually pass the shipped anomaly Init validation. A generated marker can carry a
			-- stale sequence_list because vanilla assigns its sequence after construction; when we
			-- repair that pair before recreation, make the same canonical value the expected value.
			if sequence_info and sequence_info.final_list ~= nil
				and type(record.properties) == "table" then
				record.properties.sequence_list = constructor_properties.sequence_list
			end
			local marker = place_object_in(record.class, map, constructor_properties)
			if not marker then error("record " .. tostring(i) .. ": constructor returned nil") end
			created[#created + 1] = marker
			if type(marker.SetPos) ~= "function" then error("record " .. tostring(i) .. ": SetPos unavailable") end
			marker:SetPos(final_point)
			if type(record.angle) == "number" and type(marker.SetAngle) == "function" then
				marker:SetAngle(record.angle)
			end
			if type(record.scale) == "number" and type(marker.SetScale) == "function" then
				marker:SetScale(record.scale)
			end
			if type(record.collection_index) == "number"
				and type(marker.SetCollectionIndex) == "function" then
				marker:SetCollectionIndex(record.collection_index)
			end
			marker.SuperBigMapNativeSourceX = record.source_x
			marker.SuperBigMapNativeSourceY = record.source_y
			marker.SuperBigMapNativeSourceZ = record.source_z
			marker.SuperBigMapNativeSourceHash = record.source_hash
			marker.SuperBigMapRawStretchedX = geometry.raw_x
			marker.SuperBigMapRawStretchedY = geometry.raw_y
			marker.SuperBigMapIntendedStretchedX = geometry.intended_x
			marker.SuperBigMapIntendedStretchedY = geometry.intended_y
			marker.SuperBigMapExpectedStretchedX = geometry.x
			marker.SuperBigMapExpectedStretchedY = geometry.y
			marker.SuperBigMapTransformCollisionResolved = geometry.collision_resolved
			marker.SuperBigMapTransformWonderReservationResolved =
				geometry.wonder_reservation_resolved
			marker.SuperBigMapTransformCollisionResolutionRadius = geometry.resolution_radius
			marker.SuperBigMapTransformCollisionOwnerIndex = geometry.collision_owner_index
			marker.SuperBigMapNativeRecordIndex = i
			marker.SuperBigMapNativeRecreatedAtFinal = true
			local registered_ok, registered, revealed =
				RegisterNativeMarkerWithFinalSector(map, marker, final_point)
			if not registered_ok then error("record " .. tostring(i) .. ": " .. tostring(registered)) end
			if registered == true then stats.registered = stats.registered + 1 end
			if revealed == true then stats.revealed_in_scanned_sectors =
				stats.revealed_in_scanned_sectors + 1 end
			stats.created = stats.created + 1
		end
	end)
	if not ok then
		stats.error = tostring(recreate_error)
		cleanup_created()
		return false, stats
	end
	local verified, verify_stats = DepositRules.VerifyRecreatedNativeEnrichments(map, records, reason)
	stats.verify = verify_stats
	if not verified then
		stats.error = "post-recreation verification failed"
		cleanup_created()
		return false, stats
	end
	pending_native_enrichment_records_by_map[map] = nil
	map.SuperBigMapNativeEnrichmentCaptureDone = true
	map.SuperBigMapNativeEnrichmentCapturePending = false
	map.SuperBigMapNativeEnrichmentCaptureCount = #records
	map.SuperBigMapNativeEnrichmentRecordSignature = NativeRecordSignature(records)
	map.SuperBigMapNativeEnrichmentRecreatedCount = #records
	return true, stats
end

-- Stage 02 invariant: every native marker must finish at the hex-aligned proportional
-- transformation of the immutable stage-01 coordinate and at that final terrain height.
-- This check is behavior-independent and validates every marker.
function DepositRules.VerifyNativeEnrichmentTransform(map, reason)
	if not ExpansionStepEnabled(2) or not ExpansionStepEnabled(10) then
		return true, { checked = 0, mismatches = 0 }
	end
	map = map or Global("CurrentMap")
	local point_fn = Global("point")
	local world_to_hex = Global("WorldToHex")
	local hex_to_world = Global("HexToWorld")
	if not map or type(map.MapForEach) ~= "function" or type(point_fn) ~= "function"
		or type(world_to_hex) ~= "function" or type(hex_to_world) ~= "function" then
		return false, { checked = 0, mismatches = 0, error = "map/hex APIs unavailable" }
	end
	local source_tiles = tonumber(map.SuperBigMapSourceWidthTiles)
		or tonumber(map.SuperBigMapGeneratorWidthTiles)
	local source_height_tiles = tonumber(map.SuperBigMapSourceHeightTiles)
		or tonumber(map.SuperBigMapGeneratorHeightTiles)
	local desired_tiles = tonumber(map.SuperBigMapDesiredWidthTiles)
	local desired_height_tiles = tonumber(map.SuperBigMapDesiredHeightTiles)
	if not source_tiles or source_tiles <= 0 or not source_height_tiles or source_height_tiles <= 0
		or not desired_tiles or not desired_height_tiles then
		return false, { checked = 0, mismatches = 0, error = "source/final dimensions unavailable" }
	end
	local scale_x = (desired_tiles + 0.0) / source_tiles
	local scale_y = (desired_height_tiles + 0.0) / source_height_tiles
	local origin_x = tonumber(map.SuperBigMapSourceX) or 0
	local origin_y = tonumber(map.SuperBigMapSourceY) or 0
	local stats = { checked = 0, missing_capture = 0, xy_mismatches = 0, z_mismatches = 0, mismatches = 0 }
	local verify_ok, verify_error = pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not IsEnrichmentMarker(marker)
			or marker.SuperBigMapResourceTopUp == true
			or marker.SuperBigMapAnomalyTopUp == true
			or marker.SuperBigMapEffectTopUp == true
			or marker.SuperBigMapEnrichmentClone == true then return end
		stats.checked = stats.checked + 1
		local source_x = marker.SuperBigMapNativeSourceX
		local source_y = marker.SuperBigMapNativeSourceY
		if type(source_x) ~= "number" or type(source_y) ~= "number" then
			stats.missing_capture = stats.missing_capture + 1
			stats.mismatches = stats.mismatches + 1
			return
		end
		local raw_x = math.floor(origin_x + (source_x - origin_x) * scale_x + 0.5)
		local raw_y = math.floor(origin_y + (source_y - origin_y) * scale_y + 0.5)
		local expected_x = tonumber(marker.SuperBigMapExpectedStretchedX)
		local expected_y = tonumber(marker.SuperBigMapExpectedStretchedY)
		local ok_w = type(expected_x) == "number" and type(expected_y) == "number"
		local q, r
		if not ok_w then
			local ok_h
			ok_h, q, r = pcall(world_to_hex, point_fn(raw_x, raw_y))
			if ok_h and type(q) == "number" and type(r) == "number" then
				ok_w, expected_x, expected_y = pcall(hex_to_world, q, r)
			end
		end
		local pos = ObjectPos(marker)
		local actual_x, actual_y
		if pos and type(pos.xy) == "function" then actual_x, actual_y = pos:xy() end
		local xy_ok = ok_w and type(expected_x) == "number" and type(expected_y) == "number"
			and actual_x == expected_x and actual_y == expected_y
		local expected_z, actual_z
		if ok_w and type(expected_x) == "number" and type(expected_y) == "number" then
			local expected_point = point_fn(expected_x, expected_y)
			if type(expected_point.SetTerrainZ) == "function" then
				local ok_z, terrain_point = pcall(expected_point.SetTerrainZ, expected_point, map)
				if ok_z and terrain_point and type(terrain_point.z) == "function" then
					local ok_ez, value = pcall(terrain_point.z, terrain_point)
					if ok_ez then expected_z = value end
				end
			end
		end
		if pos and type(pos.z) == "function" then
			local ok_az, value = pcall(pos.z, pos)
			if ok_az then actual_z = value end
		end
		local z_ok = expected_z ~= nil and actual_z == expected_z
		if not xy_ok then stats.xy_mismatches = stats.xy_mismatches + 1 end
		if not z_ok then stats.z_mismatches = stats.z_mismatches + 1 end
		if not xy_ok or not z_ok then
			stats.mismatches = stats.mismatches + 1
		end
	end)
	if not verify_ok then
		stats.mismatches = stats.mismatches + 1
		stats.error = tostring(verify_error)
	end
	map.SuperBigMapNativeTransformVerified = stats.mismatches == 0
	map.SuperBigMapNativeTransformStats = stats
	return stats.mismatches == 0, stats
end


local function TallyString(tbl)
	local keys = {}
	for k in pairs(tbl) do keys[#keys + 1] = k end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(tbl[k]) end
	return table.concat(parts, " ")
end

local BuildTopUpEdgeContext
local PerimeterCoordinate
local RedistributeOuterRingTopUpAnomalies

local function UndergroundTopUpSamplingState(map)
	if not IsUndergroundMap(map) then return nil end
	local state = underground_topup_sampling_by_map[map]
	if state then return state end
	state = {
		validation_context = NewDepositValidationContext(map),
		sectors = false,
		seen_hexes = {},
		samples = 0,
		sector_samples = 0,
		whole_map_samples = 0,
		published_candidates = 0,
	}
	underground_topup_sampling_by_map[map] = state
	return state
end

local function SharedTopUpValidationContext(map)
	if cfg().OPTIMIZE_TOPUP_PLACEMENT_POOLS ~= true then
		return NewDepositValidationContext(map)
	end
	local state = UndergroundTopUpSamplingState(map)
	return state and state.validation_context or NewDepositValidationContext(map)
end

local function BuildUndergroundTopUpSectorCache(map)
	local state = UndergroundTopUpSamplingState(map)
	if not state then return nil end
	if state.sectors ~= false then return state end
	local eligible = {}
	local buildable_count, empty_count, unknown_count = 0, 0, 0
	local edge_ctx = type(BuildTopUpEdgeContext) == "function"
		and BuildTopUpEdgeContext(map) or nil
	local ratio_fn = Global("BuildableGridRatio")
	local unbuildable_fn = Global("buildUnbuildableZ")
	local box_fn = Global("box")
	local buildable_grid = map and map.buildable and map.buildable.z_grid
	local ok_unbuildable, unbuildable_z = false, nil
	if type(unbuildable_fn) == "function" then
		ok_unbuildable, unbuildable_z = pcall(unbuildable_fn)
	end
	if type(edge_ctx) == "table" and type(edge_ctx.sectors) == "table"
		and type(ratio_fn) == "function" and type(box_fn) == "function"
		and buildable_grid and ok_unbuildable and type(unbuildable_z) == "number" then
		for _, descriptor in ipairs(edge_ctx.sectors) do
			local x0, y0 = descriptor.area_x0, descriptor.area_y0
			local x1, y1 = descriptor.area_x1, descriptor.area_y1
			if type(x0) == "number" and type(y0) == "number"
				and type(x1) == "number" and type(y1) == "number"
				and x1 > x0 and y1 > y0 then
				local ok_box, sector_box = pcall(box_fn, x0, y0, x1, y1)
				local ok_ratio, ratio = false, nil
				if ok_box and sector_box then
					-- A final 20x20 sector contains fewer than 10,000 hexes. At this scale a
					-- positive result proves that at least one buildable hex is present.
					ok_ratio, ratio = pcall(
						ratio_fn, buildable_grid, unbuildable_z, 10000, sector_box)
				end
				if ok_ratio and type(ratio) == "number" then
					if ratio > 0 then
						descriptor._sbm_underground_buildable_ratio = ratio
						eligible[#eligible + 1] = descriptor
						buildable_count = buildable_count + 1
					else
						empty_count = empty_count + 1
					end
				else
					-- Fail open: an inconclusive native query must never remove a legal sector.
					eligible[#eligible + 1] = descriptor
					unknown_count = unknown_count + 1
				end
			end
		end
	end
	state.sectors = #eligible > 0 and eligible or nil
	state.sector_filter_active = state.sectors ~= nil
	state.buildable_sectors = buildable_count
	state.empty_sectors = empty_count
	state.unknown_sectors = unknown_count
	local print_fn = cfg().DEBUG_LOADING_TIMINGS == true and Global("print") or nil
	if type(print_fn) == "function" then
		print_fn("[Super Big Map][UndergroundTopUpCandidateCache] sectors="
			.. tostring(state.sectors and #state.sectors or 0)
			.. " buildable=" .. tostring(buildable_count)
			.. " empty=" .. tostring(empty_count)
			.. " unknown=" .. tostring(unknown_count)
			.. " active=" .. tostring(state.sector_filter_active == true))
	end
	return state
end

local function SampleUndergroundTopUpPosition(map, lo_x, lo_y, span_x, span_y)
	if cfg().OPTIMIZE_TOPUP_PLACEMENT_POOLS ~= true then
		return lo_x + RandInt(span_x), lo_y + RandInt(span_y), nil, nil
	end
	local state = BuildUndergroundTopUpSectorCache(map)
	if not state then return nil end
	state.samples = state.samples + 1
	local sectors = state.sectors
	if type(sectors) == "table" and #sectors > 0 then
		local descriptor = sectors[RandInt(#sectors) + 1]
		local x0 = math.max(lo_x, math.floor(descriptor.area_x0 or lo_x))
		local y0 = math.max(lo_y, math.floor(descriptor.area_y0 or lo_y))
		local x1 = math.min(lo_x + span_x, math.floor(descriptor.area_x1 or (lo_x + span_x)))
		local y1 = math.min(lo_y + span_y, math.floor(descriptor.area_y1 or (lo_y + span_y)))
		if x1 > x0 and y1 > y0 then
			state.sector_samples = state.sector_samples + 1
			return x0 + RandInt(x1 - x0), y0 + RandInt(y1 - y0),
				descriptor.sector_ref, descriptor
		end
	end
	state.whole_map_samples = state.whole_map_samples + 1
	return lo_x + RandInt(span_x), lo_y + RandInt(span_y), nil, nil
end

local function ReserveUndergroundTopUpHex(map, q, r)
	if cfg().OPTIMIZE_TOPUP_PLACEMENT_POOLS ~= true then return true end
	if not IsUndergroundMap(map) or type(q) ~= "number" or type(r) ~= "number" then
		return true
	end
	local state = UndergroundTopUpSamplingState(map)
	local key = tostring(q) .. ":" .. tostring(r)
	if state.seen_hexes[key] then return false end
	state.seen_hexes[key] = true
	return true
end

local function PublishUndergroundTopUpCandidate(map, candidate, owner)
	if cfg().OPTIMIZE_TOPUP_PLACEMENT_POOLS ~= true then return end
	if not IsUndergroundMap(map) or type(candidate) ~= "table" then return end
	local shared = topup_candidate_pool_by_map[map]
	if type(shared) ~= "table" then
		shared = {}
		topup_candidate_pool_by_map[map] = shared
	end
	if shared ~= owner then shared[#shared + 1] = candidate end
	local state = UndergroundTopUpSamplingState(map)
	state.published_candidates = state.published_candidates + 1
end

local function SetEnrichmentTopUpStatus(map, kind, complete, remaining_shortfall, details)
	if type(map) ~= "table" then return end
	local status = map.SuperBigMapEnrichmentTopUpStatus
	if type(status) ~= "table" then
		status = {}
		map.SuperBigMapEnrichmentTopUpStatus = status
	end
	local entry = {
		complete = complete == true,
		remaining_shortfall = tonumber(remaining_shortfall) or 0,
	}
	if type(details) == "table" then
		for key, value in pairs(details) do
			if type(value) ~= "table" then entry[key] = value end
		end
	end
	status[kind] = entry
	if AuditEnabled() then
		local audit = { kind = tostring(kind), complete = tostring(entry.complete),
			remaining_shortfall = entry.remaining_shortfall }
		for key, value in pairs(entry) do audit[key] = value end
		AuditEmit("TOPUP_STATUS", audit, map)
	end
	local fallback_added = tonumber(entry.underground_density_fallback_added) or 0
	local print_fn = (AuditEnabled() or cfg().DEBUG_LOADING_TIMINGS == true)
		and Global("print") or nil
	if fallback_added > 0 and type(print_fn) == "function" then
		print_fn("[Super Big Map][UndergroundTopUpFallback] kind=" .. tostring(kind)
			.. " count=" .. tostring(fallback_added)
			.. " strategy=" .. tostring(entry.underground_fallback_strategy or "unknown")
			.. " eligible_sectors=" .. tostring(entry.underground_fallback_eligible_sectors or 0)
			.. " selected_sectors=" .. tostring(entry.underground_fallback_selected_sectors or 0)
			.. " max_per_sector=" .. tostring(entry.underground_fallback_max_per_sector or 0)
			.. " min_spacing_world=" .. tostring(entry.underground_fallback_min_spacing_world or 0)
			.. " min_spacing_hex=" .. tostring(entry.underground_fallback_min_spacing_hex or 0)
			.. " required_spacing_hex="
			.. tostring(entry.underground_fallback_required_spacing_hex or 0)
			.. " clearance_rejections="
			.. tostring(entry.underground_fallback_clearance_rejections or 0)
			.. " relaxed_selected="
			.. tostring(entry.underground_fallback_relaxed_selected or 0))
	end
end

local function IsUndergroundRubbleWall(obj)
	if not obj then return false end
	if IsKindOfSafe(obj, "CaveInRubble") or IsKindOfSafe(obj, "TunnelBlockerRubble") then
		return true
	end
	return obj.class == "CaveInRubble" or obj.class == "TunnelBlockerRubble"
end

-- Underground density must not depend on removable cave-in/collapsed-tunnel walls. Remove only
-- those objects from gameplay grids while the density candidate pools are built, then restore the
-- exact same live objects after all three families run. Terrain, buildings, deposits, and every
-- other obstruction remain active.
local function SuspendRubbleWallGridsForResourceTopUp(map)
	if not map or type(map.MapForEach) ~= "function" then
		return nil, "map/MapForEach unavailable"
	end
	local candidates = {}
	local traversal_ok, traversal_err = pcall(map.MapForEach, map, "map", "CObject", function(obj)
		if IsUndergroundRubbleWall(obj) and obj.grids_applied == true then
			candidates[#candidates + 1] = obj
		end
	end)
	if not traversal_ok then return nil, "rubble-wall traversal failed: " .. tostring(traversal_err) end
	local token = { objects = {}, discovered = #candidates }
	for _, obj in ipairs(candidates) do
		if type(obj.RemoveFromGrids) ~= "function" then
			for i = #token.objects, 1, -1 do
				local previous = token.objects[i]
				if previous and type(previous.ApplyToGrids) == "function" then
					pcall(previous.ApplyToGrids, previous)
				end
			end
			return nil, "RemoveFromGrids unavailable for " .. tostring(obj.class)
		end
		local removed_ok, removed_err = pcall(obj.RemoveFromGrids, obj)
		if not removed_ok or obj.grids_applied == true then
			for i = #token.objects, 1, -1 do
				local previous = token.objects[i]
				if previous and type(previous.ApplyToGrids) == "function" then
					pcall(previous.ApplyToGrids, previous)
				end
			end
			return nil, "failed to suspend " .. tostring(obj.class) .. ": " .. tostring(removed_err)
		end
		token.objects[#token.objects + 1] = obj
	end
	topup_candidate_pool_by_map[map] = nil
	underground_reachability_by_map[map] = nil
	underground_topup_sampling_by_map[map] = nil
	return token
end

local function RestoreRubbleWallGridsAfterResourceTopUp(map, token)
	if type(token) ~= "table" or type(token.objects) ~= "table" then return false, "invalid token" end
	local resource_pool = topup_candidate_pool_by_map[map]
	local failures = {}
	for i = #token.objects, 1, -1 do
		local obj = token.objects[i]
		if not obj or type(obj.ApplyToGrids) ~= "function" then
			failures[#failures + 1] = tostring(obj and obj.class or "missing object")
		else
			local applied_ok, applied_err = pcall(obj.ApplyToGrids, obj)
			if not applied_ok or obj.grids_applied ~= true then
				failures[#failures + 1] = tostring(obj.class) .. ":" .. tostring(applied_err)
			end
		end
	end
	-- A standalone resource call restores walls before later families and therefore rebuilds a
	-- wall-aware handoff pool. The managed density suite restores only after resources, anomalies,
	-- and effects have all consumed the wall-free pool; rebuilding it at suite teardown had no
	-- consumer and repeated up to 8,000 full placement validations.
	underground_reachability_by_map[map] = nil
	underground_topup_sampling_by_map[map] = nil
	topup_candidate_pool_by_map[map] = nil
	local wall_aware_pool = {}
	local point_fn = Global("point")
	if token.density_suite ~= true and #failures == 0
		and cfg().OPTIMIZE_TOPUP_PLACEMENT_POOLS == true
		and type(resource_pool) == "table" and type(point_fn) == "function" then
		local validation_context = NewDepositValidationContext(map)
		for _, candidate in ipairs(resource_pool) do
			if not candidate.used and type(candidate.x) == "number" and type(candidate.y) == "number"
				and CanReceiveDeposit(map, point_fn(candidate.x, candidate.y), validation_context) then
				wall_aware_pool[#wall_aware_pool + 1] = candidate
			end
		end
		topup_candidate_pool_by_map[map] = wall_aware_pool
	end
	token.wall_aware_shared_candidates = #wall_aware_pool
	return #failures == 0, table.concat(failures, "|")
end

-- The map-generation pipeline owns this transaction around resources, anomalies, and effects.
-- TopUpDeposits retains a self-contained fallback for callers that invoke it independently.
function DepositRules.BeginUndergroundTopUpWallIgnore(map)
	map = map or Global("CurrentMap")
	if not IsUndergroundMap(map)
		or cfg().UNDERGROUND_TOPUPS_IGNORE_RUBBLE_WALLS ~= true then
		return true, { active = false, walls = 0 }
	end
	local existing = rubble_wall_suite_token_by_map[map]
	if existing then
		return true, { active = true, walls = #existing.objects, already_active = true }
	end
	local token, err = SuspendRubbleWallGridsForResourceTopUp(map)
	if not token then return false, { error = tostring(err), active = false, walls = 0 } end
	token.density_suite = true
	rubble_wall_suite_token_by_map[map] = token
	return true, { active = true, walls = #token.objects, discovered = token.discovered }
end

function DepositRules.EndUndergroundTopUpWallIgnore(map)
	map = map or Global("CurrentMap")
	local token = map and rubble_wall_suite_token_by_map[map]
	if not token then return true, { active = false, walls = 0 } end
	rubble_wall_suite_token_by_map[map] = nil
	local ok, err = RestoreRubbleWallGridsAfterResourceTopUp(map, token)
	local density = map and map.SuperBigMapEnrichmentTopUpStatus
	local resources = type(density) == "table" and density.resources or nil
	if type(resources) == "table" then
		resources.ignored_rubble_walls = #token.objects
		resources.wall_aware_shared_candidates = token.wall_aware_shared_candidates or 0
	end
	return ok, {
		active = true, walls = #token.objects, error = tostring(err or ""),
		wall_aware_shared_candidates = token.wall_aware_shared_candidates or 0,
	}
end

-- Breakthrough anomalies are preserved exactly from the vanilla source record set.

function DepositRules.TopUpDeposits(map)
	if cfg().TOPUP_RESOURCES ~= true then return end
	if not ExpansionAdditionStagesReady("resource top-up") then return end
	map = map or Global("CurrentMap")
	SetEnrichmentTopUpStatus(map, "resources", false, 0)
	local point = Global("point")
	local clone_fn = SuperBigMap.ObjectClone and SuperBigMap.ObjectClone.CloneObjectAtOffset
	local city = map and map.City
	if not map or type(map.MapForEach) ~= "function" or type(point) ~= "function"
		or type(clone_fn) ~= "function" or not city then
		return
	end
	local map_w, map_h, tile = MapWorldSize(map)
	if not map_w or not tile or tile <= 0 then
		return
	end
	local margin_tiles = math.max(0, math.floor(cfg().DEPOSIT_EDGE_MARGIN_TILES or 4))
	local margin = margin_tiles * tile
	local lo_x, span_x = margin, (map_w - 2 * margin)
	local lo_y, span_y = margin, (map_h - 2 * margin)
	if span_x <= 0 or span_y <= 0 then
		return
	end
	-- Area factor = (desired/generated)^2; an explicit resource-only override may force it.
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
		return
	end

	-- Count current resource markers and collect native markers as clone templates.
	-- After stretching, the baseline is the full current population: every non-top-up marker
	-- came from the one native source and was transformed proportionally.
	local templates, templates_by_type = {}, {}
	local current_by_type, src_by_type = {}, {}
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not (marker and IsResourceDepositMarker(marker)) then return end
		local res = tostring(marker.resource or marker.class or "?")
		current_by_type[res] = (current_by_type[res] or 0) + 1
		if not marker.SuperBigMapResourceTopUp then
			-- All resource types are templates (incl. concrete) so the top-up mix is
			-- proportional to the source; cloned concrete self-paints its patch on scan.
			templates[#templates + 1] = marker
			templates_by_type[res] = templates_by_type[res] or {}
			templates_by_type[res][#templates_by_type[res] + 1] = marker
			src_by_type[res] = (src_by_type[res] or 0) + 1
		end
	end)

	-- The complete captured vanilla marker population is the sole density baseline. Native
	-- generator requests are deliberately irrelevant here: exact vanilla generation already
	-- decided which markers exist, and the expanded map scales that observed population.
	local target_by_type, target_keys = {}, {}
	for res, count in pairs(src_by_type) do
		target_by_type[res] = math.floor(count * area_factor + 0.5)
	end
	local shortfall = 0
	for res, count in pairs(target_by_type) do
		target_keys[#target_keys + 1] = res
		shortfall = shortfall + math.max(0, count - (current_by_type[res] or 0))
	end
	table.sort(target_keys)
	if shortfall <= 0 or #templates == 0 then
		SetEnrichmentTopUpStatus(map, "resources", shortfall <= 0, shortfall, {
			area_factor = area_factor, source_counts = CountMapString(src_by_type),
			target_counts = CountMapString(target_by_type),
			current_counts = CountMapString(current_by_type), added_counts = "",
		})
		return
	end

	local added_by_type = {}
	local density_fallback_added = 0
	local fallback_selector_stats
	local fallback_actual_sector_counts = {}
	local fallback_actual_min_spacing_world, fallback_actual_min_spacing_hex
	local function merge_fallback_selector_stats(next_stats)
		if type(next_stats) ~= "table" then return end
		if not fallback_selector_stats then
			fallback_selector_stats = {
				strategy = next_stats.strategy,
				eligible_sectors = next_stats.eligible_sectors or 0,
				selected_sectors = next_stats.selected_sectors or 0,
				max_additions_to_one_sector = next_stats.max_additions_to_one_sector or 0,
				minimum_selected_spacing_world = next_stats.minimum_selected_spacing_world or 0,
				minimum_selected_hex_distance = next_stats.minimum_selected_hex_distance or 0,
				minimum_required_hex_distance = next_stats.minimum_required_hex_distance
					or UndergroundFallbackMinimumHexDistance(),
				clearance_rejections = next_stats.clearance_rejections or 0,
				clearance_relaxations = next_stats.clearance_relaxations or 0,
				relaxed_selected = next_stats.relaxed_selected or 0,
			}
			return
		end
		fallback_selector_stats.strategy = next_stats.strategy or fallback_selector_stats.strategy
		fallback_selector_stats.eligible_sectors = math.max(
			fallback_selector_stats.eligible_sectors or 0, next_stats.eligible_sectors or 0)
		fallback_selector_stats.selected_sectors = math.max(
			fallback_selector_stats.selected_sectors or 0, next_stats.selected_sectors or 0)
		fallback_selector_stats.max_additions_to_one_sector = math.max(
			fallback_selector_stats.max_additions_to_one_sector or 0,
			next_stats.max_additions_to_one_sector or 0)
		local prior_spacing = fallback_selector_stats.minimum_selected_spacing_world or 0
		local next_spacing = next_stats.minimum_selected_spacing_world or 0
		if prior_spacing <= 0 or (next_spacing > 0 and next_spacing < prior_spacing) then
			fallback_selector_stats.minimum_selected_spacing_world = next_spacing
		end
		local prior_hex = fallback_selector_stats.minimum_selected_hex_distance or 0
		local next_hex = next_stats.minimum_selected_hex_distance or 0
		if prior_hex <= 0 or (next_hex > 0 and next_hex < prior_hex) then
			fallback_selector_stats.minimum_selected_hex_distance = next_hex
		end
		fallback_selector_stats.minimum_required_hex_distance = math.max(
			fallback_selector_stats.minimum_required_hex_distance or 0,
			next_stats.minimum_required_hex_distance or 0)
		fallback_selector_stats.clearance_rejections =
			(fallback_selector_stats.clearance_rejections or 0)
			+ (next_stats.clearance_rejections or 0)
		fallback_selector_stats.clearance_relaxations =
			(fallback_selector_stats.clearance_relaxations or 0)
			+ (next_stats.clearance_relaxations or 0)
		fallback_selector_stats.relaxed_selected =
			(fallback_selector_stats.relaxed_selected or 0)
			+ (next_stats.relaxed_selected or 0)
	end
	local candidate_pool_target, candidate_pool_size, candidate_samples = 0, 0, 0
	local candidate_deferred_count, candidate_deferred_promoted = 0, 0
	local candidate_planned_sector_fast_path = 0

	local added = 0
	local validation_context = IsUndergroundMap(map)
		and SharedTopUpValidationContext(map) or NewDepositValidationContext(map)
	-- Templates are immutable throughout this top-up transaction. Resolve their position, terrain,
	-- and vanilla repulsion profile at most once; the selection loop may revisit the same template
	-- for every remaining marker, but its option identity cannot change.
	local template_option_cache = {}
	local function template_option(template)
		local cached = template_option_cache[template]
		if cached ~= nil then return cached or nil end
		local tpos = ObjectPos(template)
		local profile = VanillaRepulsionProfileForMarker(map, template)
		if not (tpos and type(tpos.xy) == "function" and profile) then
			template_option_cache[template] = false
			return nil
		end
		local terrain_type = TerrainTypeAt(map, tpos, validation_context) or -1
		cached = {
			position = tpos, profile = profile, terrain_type = terrain_type,
			key = table.concat({
				tostring(profile.layer), tostring(profile.resource), tostring(profile.repulse_same),
				tostring(profile.repulse_layer), tostring(profile.repulse_all),
				tostring(terrain_type),
			}, ":"),
		}
		template_option_cache[template] = cached
		return cached
	end
	local underground = validation_context.underground == true
	local optimize_placement_pool = cfg().OPTIMIZE_TOPUP_PLACEMENT_POOLS == true
	local defer_candidate_reachability = underground
		and cfg().OPTIMIZE_UNDERGROUND_DEFER_CANDIDATE_REACHABILITY == true
	local reachability_checks, reachability_rejections = 0, 0
	-- Resource placement is demand-driven on both surfaces. The previous surface path first tried
	-- to accumulate shortfall * 32 validated candidates (up to the global 8,000-point ceiling),
	-- even though only one position is consumed by each missing marker. Underground already proved
	-- that the same strict-terrain/vanilla-repulsion selectors can consume candidates as soon as
	-- they validate; use that path on the surface too. The shared pool remains available to the
	-- later anomaly/effect families, which can extend it on demand when its unused tail is exhausted.
	local sequential_placement = optimize_placement_pool
	local ignore_rubble_walls = underground
		and cfg().UNDERGROUND_TOPUPS_IGNORE_RUBBLE_WALLS == true
	local ring_sectors = cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3
	local ring_context = not underground and NewFinalOuterSectorRingContext(map) or nil
	-- Resource top-ups can only land on buildable terrain, yet the sequential sampler previously
	-- drew from every interior sector and paid the complete Lua terrain/obstruction/repulsion cost
	-- to reject points from wholly unbuildable sectors. Query the finalized native buildable grid
	-- once per canonical non-perimeter sector and preserve the complete validation path inside every
	-- sector that can contain a valid hex. Ratio/API failures remain eligible, so an inconclusive
	-- optimization can never remove a possible placement area.
	local surface_resource_sectors
	local surface_sector_filter_active = false
	local surface_buildable_sectors, surface_unbuildable_sectors = 0, 0
	local surface_buildable_unknown = 0
	if not underground and sequential_placement
		and cfg().OPTIMIZE_SURFACE_RESOURCE_SECTOR_SAMPLING == true
		and type(BuildTopUpEdgeContext) == "function" then
		local edge_ctx = BuildTopUpEdgeContext(map)
		local ratio_fn = Global("BuildableGridRatio")
		local unbuildable_fn = Global("buildUnbuildableZ")
		local box_fn = Global("box")
		local buildable_grid = map.buildable and map.buildable.z_grid
		if type(edge_ctx) == "table" and type(edge_ctx.sectors) == "table"
			and type(edge_ctx.min_col) == "number" and type(edge_ctx.max_col) == "number"
			and type(edge_ctx.min_row) == "number" and type(edge_ctx.max_row) == "number"
			and type(ratio_fn) == "function" and type(unbuildable_fn) == "function"
			and type(box_fn) == "function" and buildable_grid then
			local ok_unbuildable, unbuildable_z = pcall(unbuildable_fn)
			if ok_unbuildable and type(unbuildable_z) == "number" then
				local candidates = {}
				local ring_n = math.max(0, math.floor(ring_sectors or 0))
				for _, descriptor in ipairs(edge_ctx.sectors) do
					local col, row = descriptor.col, descriptor.row
					local in_ring = ring_n > 0 and (col < edge_ctx.min_col + ring_n
						or row < edge_ctx.min_row + ring_n
						or col > edge_ctx.max_col - ring_n
						or row > edge_ctx.max_row - ring_n)
					local sector = descriptor.sector_ref
					if not in_ring and sector and not SectorIsScanned(sector) then
						local x0 = math.max(lo_x, descriptor.area_x0 or lo_x)
						local y0 = math.max(lo_y, descriptor.area_y0 or lo_y)
						local x1 = math.min(lo_x + span_x, descriptor.area_x1 or (lo_x + span_x))
						local y1 = math.min(lo_y + span_y, descriptor.area_y1 or (lo_y + span_y))
						if x1 > x0 and y1 > y0 then
							local ok_box, sector_box = pcall(box_fn, x0, y0, x1, y1)
							local ok_ratio, ratio = false, nil
							if ok_box and sector_box then
								-- A 20x20 sector contains fewer than 10,000 hexes, so a single
								-- buildable hex cannot be rounded down to zero at this scale.
								ok_ratio, ratio = pcall(ratio_fn, buildable_grid,
									unbuildable_z, 10000, sector_box)
							end
							if ok_ratio and type(ratio) == "number" then
								if ratio > 0 then
									candidates[#candidates + 1] = {
										sector = sector, col = col, row = row,
										x0 = x0, y0 = y0, x1 = x1, y1 = y1,
									}
									surface_buildable_sectors = surface_buildable_sectors + 1
								else
									surface_unbuildable_sectors = surface_unbuildable_sectors + 1
								end
							else
								candidates[#candidates + 1] = {
									sector = sector, col = col, row = row,
									x0 = x0, y0 = y0, x1 = x1, y1 = y1,
								}
								surface_buildable_unknown = surface_buildable_unknown + 1
							end
						end
					end
				end
				-- An empty result is treated as an inconclusive optimization and falls back to the
				-- original whole-map sampler. On a valid expanded surface this list is non-empty.
				if #candidates > 0 then
					surface_resource_sectors = candidates
					surface_sector_filter_active = true
				end
			end
		end
	end
	local rubble_token = rubble_wall_suite_token_by_map[map]
	local owns_rubble_token = false
	if ignore_rubble_walls then
		if not rubble_token then
			local suspend_err
			rubble_token, suspend_err = SuspendRubbleWallGridsForResourceTopUp(map)
			if not rubble_token then error("resource top-up could not ignore rubble walls: "
				.. tostring(suspend_err)) end
			owns_rubble_token = true
		end
	end
	local placement_ok, placement_err = RunPaused("SuperBigMapDepositTopUp", function()
		-- Shared validated pool. Selection preserves terrain type while preferring sectors with
		-- the lowest existing-enrichment load relative to sampled eligible terrain area.
		local shared_candidates, pool = {}, 0
		local deferred_relaxation_candidates = {}
		local MAX_SAMPLES, MAX_POOL = 24000, 8000
		-- Eight thousand validated points was a fixed historical ceiling, not a gameplay
		-- requirement. On the underground map every attempted point also performs an authoritative
		-- entrance ConnectivityCheck, so forcing the ceiling for a few dozen missing deposits spent
		-- most of the first-access load building a reserve that no selector could consume. Thirty-two
		-- choices per missing marker matches the proven effect-top-up budget and leaves ample room for
		-- terrain matching, vanilla repulsion, clone failures, and the well-spaced fallback.
		candidate_pool_target = sequential_placement and 0
			or (optimize_placement_pool
				and math.min(MAX_POOL, math.max(512, shortfall * 32)) or MAX_POOL)
		local function append_valid_candidate(x, y, sector, terrain_type, q, r)
			if underground and not ReserveUndergroundTopUpHex(map, q, r) then return false end
			local candidate = {
				x = x, y = y, terrain_type = terrain_type, sector = sector, sector_id = sector.id,
				q = q, r = r, _sbm_terrain_valid = true,
				_sbm_repulsion_hex = type(q) == "number" and type(r) == "number"
					and (tostring(q) .. ":" .. tostring(r)) or nil,
			}
			shared_candidates[#shared_candidates + 1] = candidate
			pool = pool + 1
			if underground then PublishUndergroundTopUpCandidate(map, candidate, shared_candidates) end
			return true
		end
		local function sample_valid_candidate(prefilter)
			candidate_samples = candidate_samples + 1
			local x, y, planned_sector
			if surface_sector_filter_active then
				local candidate_sector = surface_resource_sectors[
					RandInt(#surface_resource_sectors) + 1]
				local first_x, first_y = math.floor(candidate_sector.x0),
					math.floor(candidate_sector.y0)
				local past_x, past_y = math.floor(candidate_sector.x1),
					math.floor(candidate_sector.y1)
				if past_x <= first_x or past_y <= first_y then return false end
				x = first_x + RandInt(past_x - first_x)
				y = first_y + RandInt(past_y - first_y)
				planned_sector = candidate_sector.sector
			elseif underground then
				x, y, planned_sector = SampleUndergroundTopUpPosition(
					map, lo_x, lo_y, span_x, span_y)
			else
				x = lo_x + RandInt(span_x)
				y = lo_y + RandInt(span_y)
			end
			-- Spread across the whole unscanned expanded destination, excluding only the scanned
			-- start sector. The final surface perimeter remains reserved for anomaly extras.
			-- Filtered descriptors are canonical half-open sector rectangles captured from the final
			-- 20x20 grid. Their sector is already known, unscanned, and outside the reserved ring;
			-- repeating GetMapSectorXY plus the ring lookup for every rejected random point cannot
			-- change the answer. The whole-map/underground path retains both authoritative queries.
			local sector = planned_sector or SectorAtPoint(map, x, y)
			if planned_sector then
				candidate_planned_sector_fast_path = candidate_planned_sector_fast_path + 1
			end
			local reserved_ring = false
			if not planned_sector and not underground then
				reserved_ring = IsInFinalOuterSectorRing(
					map, x, y, ring_sectors, sector, ring_context)
			end
			if not (sector and (planned_sector or underground or not SectorIsScanned(sector))
				and not reserved_ring) then
				return false
			end
			local pt = point(x, y)
			local prefiltered_terrain_type
			if type(prefilter) == "function" then
				local accepted, terrain_type = prefilter(x, y, pt, sector)
				if accepted ~= true then return false end
				prefiltered_terrain_type = terrain_type
			end
			local can_receive, _, _, _, q, r = CanReceiveDeposit(
				map, pt, validation_context, defer_candidate_reachability)
			if not can_receive then return false end
			local tt = prefiltered_terrain_type
			if tt == nil then tt = TerrainTypeAt(map, pt, validation_context) or -1 end
			return append_valid_candidate(x, y, sector, tt, q, r)
		end
		local function grow_candidate_pool(target, prefilter, maximum_samples)
			target = math.min(MAX_POOL, math.max(pool, math.floor(target or pool)))
			maximum_samples = math.min(MAX_SAMPLES,
				math.max(candidate_samples, math.floor(maximum_samples or MAX_SAMPLES)))
			while candidate_samples < maximum_samples and pool < target do
				sample_valid_candidate(prefilter)
			end
			return pool
		end
		grow_candidate_pool(candidate_pool_target)
		if optimize_placement_pool then
			topup_candidate_pool_by_map[map] = shared_candidates
		end
		local repulsion = NewTopUpRepulsionTracker(map, "resources")
		local surface_selector_loads = not underground
			and cfg().OPTIMIZE_SURFACE_RESOURCE_SELECTOR_LOAD_CACHE == true
			and BuildEnrichmentSectorLoads(map) or nil
		local surface_selector_load_cache_reuses = 0
		local active_selector
		local function take(tt, profile)
			while true do
				local candidate = active_selector.Take(tt, profile)
				if not candidate or not defer_candidate_reachability then return candidate end
				local reachable, checked = UndergroundCandidateReachable(
					map, candidate, validation_context)
				if checked then reachability_checks = reachability_checks + 1 end
				if reachable then return candidate end
				reachability_rejections = reachability_rejections + 1
			end
		end
		local function take_any(profile)
			return take(nil, profile)
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
		local function select_needed_placement(allow_any_terrain)
			local preferred = choose_needed_type()
			if not preferred then return nil end
			local order, others = { preferred }, {}
			for _, res in ipairs(target_keys) do
				local deficit = math.max(0,
					(target_by_type[res] or 0) - (current_by_type[res] or 0) - (added_by_type[res] or 0))
				if deficit > 0 and res ~= preferred then others[#others + 1] = res end
			end
			for i = #others, 2, -1 do
				local j = RandInt(i) + 1
				others[i], others[j] = others[j], others[i]
			end
			for _, res in ipairs(others) do order[#order + 1] = res end
			for _, res in ipairs(order) do
				local type_templates = templates_by_type[res] or {}
				local start = #type_templates > 0 and (RandInt(#type_templates) + 1) or 1
				local seen_options = {}
				for offset = 0, #type_templates - 1 do
					local template = type_templates[((start + offset - 1) % #type_templates) + 1]
					local option = template_option(template)
					if option then
						if not seen_options[option.key] then
							seen_options[option.key] = true
							local c = take(option.terrain_type, option.profile)
							if not c and allow_any_terrain == true then c = take_any(option.profile) end
							if c then return c, template, option.position, option.profile end
						end
					end
				end
			end
			return nil
		end

		-- A candidate is reserved by Take. If cloning that candidate fails, keep trying unused
		-- candidates until the exact type targets are met or the validated pool is exhausted.
		local function place_from(active, density_fallback, allow_any_terrain)
			active_selector = active
			while added < shortfall and active_selector.Remaining() > 0 do
				local c, template, tpos, profile = select_needed_placement(allow_any_terrain)
				if not c then break end
				if tpos and type(tpos.xy) == "function" then
					local tx, ty = tpos:xy()
					local clone = clone_fn(map, template, point(c.x - tx, c.y - ty, 0))
					if clone and type(clone) == "table" then
						active_selector.Commit(c)
						added = added + 1
						local res = tostring(template.resource or template.class or "?")
						clone.SuperBigMapResourceTopUp = true
						clone.SuperBigMapResourceTopUpIgnoredRubbleWalls = ignore_rubble_walls or nil
						clone.SuperBigMapTopUpIgnoredRubbleWalls = ignore_rubble_walls or nil
						clone.SuperBigMapUndergroundDensityFallback = density_fallback or nil
						clone.SuperBigMapUndergroundWellSpacedFallback = density_fallback or nil
						clone.SuperBigMapUndergroundFallbackSpacingWorld = density_fallback
							and RoundedWorldDistance(c._sbm_selected_fallback_spacing_sq) or nil
						clone.SuperBigMapUndergroundFallbackSpacingHex = density_fallback
							and c._sbm_selected_fallback_hex_distance or nil
						clone.SuperBigMapUndergroundFallbackSpacingRelaxed = density_fallback
							and c._sbm_fallback_spacing_relaxed or nil
						if density_fallback then
							density_fallback_added = density_fallback_added + 1
							local _, fallback_sector_key = CandidateSector(map, c)
							fallback_sector_key = c._sbm_well_spaced_fallback_sector_key
								or fallback_sector_key
							if fallback_sector_key then
								fallback_actual_sector_counts[fallback_sector_key] =
									(fallback_actual_sector_counts[fallback_sector_key] or 0) + 1
							end
							local spacing_world = RoundedWorldDistance(
								c._sbm_selected_fallback_spacing_sq)
							if spacing_world > 0 then
								fallback_actual_min_spacing_world = fallback_actual_min_spacing_world
									and math.min(fallback_actual_min_spacing_world, spacing_world)
									or spacing_world
							end
							local spacing_hex = tonumber(c._sbm_selected_fallback_hex_distance)
							if spacing_hex and spacing_hex > 0 then
								fallback_actual_min_spacing_hex = fallback_actual_min_spacing_hex
									and math.min(fallback_actual_min_spacing_hex, spacing_hex)
									or spacing_hex
							end
						end
						added_by_type[res] = (added_by_type[res] or 0) + 1
						if type(clone.SetPos) == "function" then
							local pt = point(c.x, c.y)
							if type(pt.SetTerrainZ) == "function" then
								local ok, snapped = pcall(pt.SetTerrainZ, pt, map)
								if ok and snapped then pt = snapped end
							end
							pcall(clone.SetPos, clone, pt)
						end
						repulsion.Commit(c, profile, clone)
						if cfg().OPTIMIZE_TOPUP_PLACEMENT_POOLS == true and not underground then
							local sec = c.sector or SectorAtPoint(map, c.x, c.y)
							if sec and type(sec.RegisterDeposit) == "function" then
								pcall(sec.RegisterDeposit, sec, clone)
							end
						end
					end
				end
			end
		end
		local function place_strict_once(label)
			if surface_selector_loads then
				surface_selector_load_cache_reuses = surface_selector_load_cache_reuses + 1
			end
			local strict_selector = NewSectorBalancedCandidateSelector(
				map, shared_candidates, label or "resources strict reserve",
				function(candidate, profile) return repulsion.CanPlace(candidate, profile) end,
				surface_selector_loads)
			place_from(strict_selector, false, false)
		end
		local function place_relaxed_once(label)
			if added >= shortfall then return end
			if surface_selector_loads then
				surface_selector_load_cache_reuses = surface_selector_load_cache_reuses + 1
			end
			local relaxed_selector = NewSectorBalancedCandidateSelector(
				map, shared_candidates, label or "resources any-terrain residual",
				function(candidate, profile) return repulsion.CanPlace(candidate, profile) end,
				surface_selector_loads)
			place_from(relaxed_selector, false, true)
		end
		local function place_underground_fallback_once(label)
			if not underground or added >= shortfall then return end
			local fallback_selector = NewWellSpacedUndergroundFallbackSelector(
				map, shared_candidates, label or "underground resource residual",
				function(candidate) return repulsion.CanPlaceUnique(candidate) end)
			place_from(fallback_selector, true, true)
			merge_fallback_selector_stats(fallback_selector.Stats())
		end
		local function strict_residual_prefilter()
			local options, seen = {}, {}
			for _, res in ipairs(target_keys) do
				local deficit = math.max(0,
					(target_by_type[res] or 0) - (current_by_type[res] or 0)
						- (added_by_type[res] or 0))
				if deficit > 0 then
					for _, template in ipairs(templates_by_type[res] or {}) do
						local option = template_option(template)
						if option and not seen[option.key] then
							seen[option.key] = true
							options[#options + 1] = option
						end
					end
				end
			end
			return function(x, y, pt, sector)
				-- Residual search keeps the historical random-attempt ceiling, but cheaply discards a point
				-- that cannot satisfy ANY remaining exact-terrain/vanilla-repulsion profile before asking
				-- native passability, normal, connectivity, and obstruction APIs about it. Existing obstacles
				-- only grow during this transaction, so a repulsion rejection can never become eligible later.
				local buildable, q, r = IsBuildableAt(map, pt, true, validation_context)
				if not buildable then return false end
				local terrain_type = TerrainTypeAt(map, pt, validation_context) or -1
				local probe = {
					x = x, y = y, terrain_type = terrain_type, sector = sector,
					sector_id = sector and sector.id, q = q, r = r,
					_sbm_repulsion_hex = type(q) == "number" and type(r) == "number"
						and (tostring(q) .. ":" .. tostring(r)) or nil,
				}
				for _, option in ipairs(options) do
					if option.terrain_type == terrain_type
						and repulsion.CanPlace(probe, option.profile) then
						return true, terrain_type
					end
				end
				-- This coordinate cannot be a strict placement now (and repulsion only tightens), but it
				-- may be useful to the established any-terrain or unique-hex completion phase. Retain the
				-- cheap buildable snapshot and validate only a small geographically random reserve later.
				deferred_relaxation_candidates[#deferred_relaxation_candidates + 1] = probe
				candidate_deferred_count = candidate_deferred_count + 1
				return false
			end
		end
		local deferred_relaxation_cursor = 1
		local function remaining_relaxed_profiles()
			local profiles, seen = {}, {}
			for _, res in ipairs(target_keys) do
				local deficit = math.max(0,
					(target_by_type[res] or 0) - (current_by_type[res] or 0)
						- (added_by_type[res] or 0))
				if deficit > 0 then
					for _, template in ipairs(templates_by_type[res] or {}) do
						local option = template_option(template)
						local profile = option and option.profile
						local key = profile and table.concat({
							tostring(profile.layer), tostring(profile.resource),
							tostring(profile.repulse_same), tostring(profile.repulse_layer),
							tostring(profile.repulse_all),
						}, ":") or nil
						if key and not seen[key] then
							seen[key] = true
							profiles[#profiles + 1] = profile
						end
					end
				end
			end
			return profiles
		end
		local function promote_deferred_relaxation_candidates(target)
			target = math.min(MAX_POOL, math.max(pool, math.floor(target or pool)))
			local profiles = remaining_relaxed_profiles()
			while deferred_relaxation_cursor <= #deferred_relaxation_candidates and pool < target do
				local candidate = deferred_relaxation_candidates[deferred_relaxation_cursor]
				deferred_relaxation_cursor = deferred_relaxation_cursor + 1
				local repulsion_eligible = false
				for _, profile in ipairs(profiles) do
					if repulsion.CanPlace(candidate, profile) then
						repulsion_eligible = true
						break
					end
				end
				if repulsion_eligible then
					candidate._sbm_full_validation_done = true
					local pt = point(candidate.x, candidate.y)
					local can_receive, _, _, _, q, r = CanReceiveDeposit(
						map, pt, validation_context, defer_candidate_reachability)
					if can_receive then
						append_valid_candidate(candidate.x, candidate.y, candidate.sector,
							candidate.terrain_type, q, r)
						candidate_deferred_promoted = candidate_deferred_promoted + 1
					end
				end
			end
		end
		local deferred_unique_cursor = 1
		local function promote_deferred_unique_candidates(target)
			target = math.min(MAX_POOL, math.max(pool, math.floor(target or pool)))
			while deferred_unique_cursor <= #deferred_relaxation_candidates and pool < target do
				local candidate = deferred_relaxation_candidates[deferred_unique_cursor]
				deferred_unique_cursor = deferred_unique_cursor + 1
				if candidate._sbm_full_validation_done ~= true then
					candidate._sbm_full_validation_done = true
					if repulsion.CanPlaceUnique(candidate) then
						local pt = point(candidate.x, candidate.y)
						local can_receive, _, _, _, q, r = CanReceiveDeposit(
							map, pt, validation_context, defer_candidate_reachability)
						if can_receive then
							append_valid_candidate(candidate.x, candidate.y, candidate.sector,
								candidate.terrain_type, q, r)
							candidate_deferred_promoted = candidate_deferred_promoted + 1
						end
					end
				end
			end
		end

		if sequential_placement then
			-- Validate positions only for the next missing marker. The old reserve-first path could spend
			-- all 24,000 native placement checks trying to reach a pool target before placing anything.
			-- A strict candidate is now consumed as soon as it satisfies the same terrain and vanilla
			-- repulsion rules. After a bounded strict search for that marker, retain a small random choice
			-- set for the existing any-terrain completion rule and the underground maximin fallback.
			local STRICT_SAMPLES_PER_PLACEMENT = 128
			local FALLBACK_CHOICES_PER_PLACEMENT = 8
			while added < shortfall and pool < MAX_POOL and candidate_samples < MAX_SAMPLES do
				local added_before = added
				local strict_sample_limit = math.min(MAX_SAMPLES,
					candidate_samples + STRICT_SAMPLES_PER_PLACEMENT)
				local strict_prefilter = strict_residual_prefilter()
				while added == added_before and pool < MAX_POOL
					and candidate_samples < strict_sample_limit do
					local pool_before = pool
					grow_candidate_pool(pool + 1, strict_prefilter, strict_sample_limit)
					if pool <= pool_before then break end
					place_strict_once("underground resources sequential strict")
				end

				if added == added_before
					and deferred_relaxation_cursor <= #deferred_relaxation_candidates then
					promote_deferred_relaxation_candidates(math.min(MAX_POOL,
						pool + FALLBACK_CHOICES_PER_PLACEMENT))
					place_relaxed_once("underground resources sequential any-terrain")
				end

				if added == added_before
					and deferred_unique_cursor <= #deferred_relaxation_candidates then
					promote_deferred_unique_candidates(math.min(MAX_POOL,
						pool + FALLBACK_CHOICES_PER_PLACEMENT))
					place_underground_fallback_once(
						"underground resources sequential well-spaced")
				end

				if added == added_before and candidate_samples < MAX_SAMPLES then
					local fallback_sample_limit = math.min(MAX_SAMPLES,
						candidate_samples + STRICT_SAMPLES_PER_PLACEMENT)
					grow_candidate_pool(math.min(MAX_POOL,
						pool + FALLBACK_CHOICES_PER_PLACEMENT), nil, fallback_sample_limit)
					place_strict_once("underground resources sequential sampled strict retry")
					if added == added_before then
						place_relaxed_once("underground resources sequential sampled any-terrain")
					end
					if added == added_before then
						place_underground_fallback_once(
							"underground resources sequential sampled fallback")
					end
				end

				if added == added_before and candidate_samples >= MAX_SAMPLES then break end
			end
		else
			-- Surface behavior and the explicit optimization rollback retain the historical strict search
			-- opportunity before any relaxation.
			while added < shortfall do
				place_strict_once("resources strict reserve")
				if added >= shortfall or pool >= MAX_POOL or candidate_samples >= MAX_SAMPLES then break end
				local before = pool
				grow_candidate_pool(math.min(MAX_POOL,
					math.max(pool + 512, pool * 2, shortfall * 64)))
				if pool <= before then break end
			end
			place_relaxed_once("resources any-terrain residual")
			place_underground_fallback_once("underground resource residual")
		end
		candidate_pool_size = pool
		map.SuperBigMapSurfaceResourceSelectorLoadCacheReuses =
			surface_selector_load_cache_reuses
	end)
	local restore_ok, restore_err = true, nil
	if rubble_token and owns_rubble_token then
		restore_ok, restore_err = RestoreRubbleWallGridsAfterResourceTopUp(map, rubble_token)
	end
	if not placement_ok then error("resource top-up placement failed: " .. tostring(placement_err)) end
	if not restore_ok then error("resource top-up rubble-wall restore failed: "
		.. tostring(restore_err)) end
	if density_fallback_added > 0 then
		fallback_selector_stats = fallback_selector_stats or {
			strategy = "maximin_spacing_with_sector_diversity", eligible_sectors = 0,
		}
		local selected_sectors, maximum_per_sector = 0, 0
		for _, count in pairs(fallback_actual_sector_counts) do
			selected_sectors = selected_sectors + 1
			maximum_per_sector = math.max(maximum_per_sector, count)
		end
		fallback_selector_stats.selected_sectors = selected_sectors
		fallback_selector_stats.max_additions_to_one_sector = maximum_per_sector
		fallback_selector_stats.minimum_selected_spacing_world =
			fallback_actual_min_spacing_world or 0
		fallback_selector_stats.minimum_selected_hex_distance =
			fallback_actual_min_spacing_hex or 0
		fallback_selector_stats.minimum_required_hex_distance =
			fallback_selector_stats.minimum_required_hex_distance
			or UndergroundFallbackMinimumHexDistance()
	end
	local final_by_type, remaining_shortfall = {}, 0
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not (marker and IsResourceDepositMarker(marker)) then return end
		local res = tostring(marker.resource or marker.class or "?")
		final_by_type[res] = (final_by_type[res] or 0) + 1
	end)
	for _, res in ipairs(target_keys) do
		local final_count = final_by_type[res] or 0
		remaining_shortfall = remaining_shortfall
			+ math.max(0, (target_by_type[res] or 0) - final_count)
	end
	SetEnrichmentTopUpStatus(map, "resources", remaining_shortfall == 0, remaining_shortfall, {
		area_factor = area_factor, source_counts = CountMapString(src_by_type),
		target_counts = CountMapString(target_by_type), final_counts = CountMapString(final_by_type),
		added_counts = CountMapString(added_by_type), added_total = added,
		underground_density_fallback_added = density_fallback_added,
		underground_fallback_strategy = fallback_selector_stats and fallback_selector_stats.strategy or "none",
		underground_fallback_eligible_sectors = fallback_selector_stats
			and fallback_selector_stats.eligible_sectors or 0,
		underground_fallback_selected_sectors = fallback_selector_stats
			and fallback_selector_stats.selected_sectors or 0,
		underground_fallback_max_per_sector = fallback_selector_stats
			and fallback_selector_stats.max_additions_to_one_sector or 0,
		underground_fallback_min_spacing_world = fallback_selector_stats
			and fallback_selector_stats.minimum_selected_spacing_world or 0,
		underground_fallback_min_spacing_hex = fallback_selector_stats
			and fallback_selector_stats.minimum_selected_hex_distance or 0,
		underground_fallback_required_spacing_hex = fallback_selector_stats
			and fallback_selector_stats.minimum_required_hex_distance or 0,
		underground_fallback_clearance_rejections = fallback_selector_stats
			and fallback_selector_stats.clearance_rejections or 0,
		underground_fallback_clearance_relaxations = fallback_selector_stats
			and fallback_selector_stats.clearance_relaxations or 0,
		underground_fallback_relaxed_selected = fallback_selector_stats
			and fallback_selector_stats.relaxed_selected or 0,
		candidate_pool_target = candidate_pool_target,
		candidate_pool_size = candidate_pool_size,
		candidate_samples = candidate_samples,
		candidate_deferred = candidate_deferred_count,
		candidate_deferred_promoted = candidate_deferred_promoted,
		sequential_placement = sequential_placement,
		surface_sector_filter = surface_sector_filter_active,
		surface_buildable_sectors = surface_buildable_sectors,
		surface_unbuildable_sectors = surface_unbuildable_sectors,
		surface_buildable_unknown = surface_buildable_unknown,
		surface_selector_load_cache_reuses =
			map.SuperBigMapSurfaceResourceSelectorLoadCacheReuses or 0,
		candidate_planned_sector_fast_path = candidate_planned_sector_fast_path,
		deferred_reachability = defer_candidate_reachability,
		reachability_checks = reachability_checks,
		reachability_rejections = reachability_rejections,
		ignored_rubble_walls = rubble_token and #rubble_token.objects or 0,
		wall_aware_shared_candidates = rubble_token
			and rubble_token.wall_aware_shared_candidates or 0,
	})
	if cfg().DEBUG_LOADING_TIMINGS == true then
		local print_fn = Global("print")
		if type(print_fn) == "function" then
			print_fn("[Super Big Map][TopUpCandidatePool] kind=resources"
				.. " target=" .. tostring(candidate_pool_target)
				.. " valid=" .. tostring(candidate_pool_size)
				.. " sampled=" .. tostring(candidate_samples)
				.. " deferred=" .. tostring(candidate_deferred_count)
				.. " promoted=" .. tostring(candidate_deferred_promoted)
				.. " added=" .. tostring(added)
				.. " sequential=" .. tostring(sequential_placement)
				.. " surface_sector_filter=" .. tostring(surface_sector_filter_active)
				.. " buildable_sectors=" .. tostring(surface_buildable_sectors)
				.. " unbuildable_sectors=" .. tostring(surface_unbuildable_sectors)
				.. " unknown_sectors=" .. tostring(surface_buildable_unknown)
				.. " selector_load_cache_reuses=" .. tostring(
					map.SuperBigMapSurfaceResourceSelectorLoadCacheReuses or 0)
				.. " planned_sector_fast_path=" .. tostring(
					candidate_planned_sector_fast_path)
				.. " deferred_reachability=" .. tostring(defer_candidate_reachability)
				.. " reachability_checks=" .. tostring(reachability_checks)
				.. " reachability_rejections=" .. tostring(reachability_rejections)
				.. " remaining=" .. tostring(remaining_shortfall))
		end
	end
end

-- POST-GENERATION anomaly top-up (config TOPUP_ANOMALIES). Raises the ANOMALY population
-- to vanilla density x area WITHOUT touching the generator: the previous in-generation count
-- scaling happens here after exact vanilla generation so no generator random stream changes.
-- Clones existing standard anomaly markers; the actual
-- reward resolves at scan time. This density pass deliberately does not scale breakthroughs;
-- breakthroughs are preserved exactly from the vanilla source and are never density-topped-up.
-- safety arguments as the original design. Only standard `complete`, `unlock`, and event
-- `sequence` deficits are cloned. Those previously selected reward categories are placed
-- exclusively in the FINAL map's outer three-sector mountain ring. `other` (including unique/
-- cave-specific) families are preserved; breakthroughs are handled by the dedicated pass above.
-- Each clone is hidden + sector-registered so a real scan reveals it. Underground extras retain
-- whole-map placement because there is no surface mountain-edge ring there. Once the complete
-- surface anomaly population exists, every TOP-UP marker is reassigned using a fresh random
-- shuffle of the complete ring-sector list, then a random reachable point inside the chosen
-- sector. Native anomalies remain at their exact proportional vanilla coordinates and participate
-- only as fixed obstacles in the vanilla repulsion tracker.
function DepositRules.TopUpAnomalies(map)
	if cfg().TOPUP_ANOMALIES ~= true then return end
	if not ExpansionAdditionStagesReady("anomaly top-up") then return end
	map = map or Global("CurrentMap")
	SetEnrichmentTopUpStatus(map, "anomalies", false, 0)
	local point = Global("point")
	local clone_fn = SuperBigMap.ObjectClone and SuperBigMap.ObjectClone.CloneObjectAtOffset
	local city = map and map.City
	if not map or type(map.MapForEach) ~= "function" or type(point) ~= "function"
		or type(clone_fn) ~= "function" or not city then
		return
	end
	local map_w, map_h, tile = MapWorldSize(map)
	if not map_w or not tile or tile <= 0 then
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
		return
	end
	-- `kind` is stable across markers and already-spawned anomalies.
	local function AnomalyKind(obj)
		local action = obj and obj.tech_action
		if action == "complete" or action == "unlock" or action == "breakthrough" then
			return action
		end
		if obj and obj.sequence ~= nil and obj.sequence ~= "" then return "sequence" end
		return "other"
	end
	-- Markers remain as the authoritative backing records after an anomaly is spawned;
	-- counting live SubsurfaceAnomaly objects too would double-count revealed markers.
	-- Targets use only original generator output; current counts include prior top-ups so a
	-- repeated call remains a no-op.
	local templates, standard_templates, standard_templates_by_kind = {}, {}, {}
	local current_by_kind, current_standard_by_kind = {}, {}
	local source_by_kind, source_standard_by_kind = {}, {}
	pcall(map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(marker)
		if not marker then return end
		local kind = AnomalyKind(marker)
		local is_standard = tostring(marker.class or "") == "SubsurfaceAnomalyMarker"
		current_by_kind[kind] = (current_by_kind[kind] or 0) + 1
		if is_standard then
			current_standard_by_kind[kind] = (current_standard_by_kind[kind] or 0) + 1
		end
		if not marker.SuperBigMapAnomalyTopUp and not marker.SuperBigMapEnrichmentClone then
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
	local shortfall = 0
	for kind, count in pairs(target_by_kind) do
		target_keys[#target_keys + 1] = kind
		shortfall = shortfall + math.max(0, count - (current_by_kind[kind] or 0))
	end
	table.sort(target_keys)
	local ring_sectors = math.max(0, math.floor(cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3))
	local surface_edge_ring = not IsUndergroundMap(map) and ring_sectors > 0
	local redistribution_stats
	if shortfall <= 0 or #templates == 0 then
		if surface_edge_ring then
			local redistribution_ok, redistribution_error = RunPaused(
				"SuperBigMapOuterRingAnomalyRedistribution", function()
					local ok, stats = RedistributeOuterRingTopUpAnomalies(map, ring_sectors)
					redistribution_stats = stats
					if not ok then error(stats and stats.error or "unknown redistribution failure") end
				end)
			if not redistribution_ok then
				error("outer-ring anomaly redistribution failed: " .. tostring(redistribution_error))
			end
		end
		SetEnrichmentTopUpStatus(map, "anomalies", shortfall <= 0, shortfall, {
			area_factor = area_factor, source_counts = CountMapString(source_by_kind),
			target_counts = CountMapString(target_by_kind),
			current_counts = CountMapString(current_by_kind), added_counts = "",
			outer_ring_redistributed = redistribution_stats and redistribution_stats.moved or 0,
			outer_ring_placed = redistribution_stats and redistribution_stats.outer_planned or 0,
			inner_ring_fallback = redistribution_stats and redistribution_stats.inner_fallback or 0,
			outer_ring_sector_count = redistribution_stats and redistribution_stats.ring_sectors or 0,
		})
		return
	end
	local anomaly_values = GeneratorFamilyRepulsionValues(map, "Anomaly")
	if not RepulsionValuesAreValid(anomaly_values) then
		error("anomaly top-up cannot apply vanilla repulsion: profile unavailable")
	end
	local anomaly_profile = {
		layer = "subs", resource = "Anomaly", preset = anomaly_values.preset,
		repulse_same = anomaly_values.repulse_same,
		repulse_layer = anomaly_values.repulse_layer,
		repulse_all = anomaly_values.repulse_all,
	}
	local added_by_kind = {}
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

	local added = 0
	local density_fallback_added = 0
	local fallback_selector_stats
	local reused_pool = false
	local candidate_pool_size, candidate_samples_total = 0, 0
	local edge_ctx
	local validation_context = IsUndergroundMap(map)
		and SharedTopUpValidationContext(map) or NewDepositValidationContext(map)
	local underground = validation_context.underground == true
	local sequential_underground = underground
		and cfg().OPTIMIZE_TOPUP_PLACEMENT_POOLS == true
	local defer_candidate_reachability = underground
		and cfg().OPTIMIZE_UNDERGROUND_DEFER_CANDIDATE_REACHABILITY == true
	local reachability_checks, reachability_rejections = 0, 0
	local ring_context = not underground and NewFinalOuterSectorRingContext(map) or nil
	local low_area_percent = math.max(1, math.min(100,
		math.floor(cfg().TOPUP_ANOMALY_LOW_AREA_PERCENT or 35)))
	local topup_ok, topup_error = RunPaused("SuperBigMapAnomalyTopUp", function()
		-- Surface placement is finalized only after the complete population exists. Create every
		-- missing ordinary anomaly as a temporary marker inside a canonical ring sector, without
		-- consuming scarce reachable/repulsion slots one at a time. The redistribution transaction
		-- below then ignores only top-up coordinates and plans all added anomalies together. Native
		-- anomalies retain their exact stretched-vanilla positions and repel these new placements.
		if surface_edge_ring then
			edge_ctx = BuildTopUpEdgeContext(map)
			local placeholder_sectors = {}
			if edge_ctx then
				for _, sector in ipairs(edge_ctx.sectors or {}) do
					if sector.col <= edge_ctx.min_col + ring_sectors - 1
						or sector.col >= edge_ctx.max_col - ring_sectors + 1
						or sector.row <= edge_ctx.min_row + ring_sectors - 1
						or sector.row >= edge_ctx.max_row - ring_sectors + 1 then
						placeholder_sectors[#placeholder_sectors + 1] = sector
					end
				end
			end
			local expected_ring_sectors = edge_ctx and edge_ctx.cols * edge_ctx.rows
				- math.max(0, edge_ctx.cols - 2 * ring_sectors)
					* math.max(0, edge_ctx.rows - 2 * ring_sectors) or 0
			if #placeholder_sectors ~= expected_ring_sectors or #placeholder_sectors == 0 then
				error("surface anomaly placeholders cannot resolve the complete outer-ring sector list")
			end
			if #standard_templates == 0 then
				error("surface anomaly placeholder template pool is empty")
			end
			for i = #placeholder_sectors, 2, -1 do
				local j = RandInt(i) + 1
				placeholder_sectors[i], placeholder_sectors[j] =
					placeholder_sectors[j], placeholder_sectors[i]
			end
			for placement_n = 1, shortfall do
				local needed_kind = choose_needed_kind()
				if not needed_kind then error("surface anomaly deficit selection exhausted early") end
				local kind_templates = standard_templates_by_kind[needed_kind]
				local template = kind_templates and kind_templates[RandInt(#kind_templates) + 1]
					or standard_templates[RandInt(#standard_templates) + 1]
				local event_sequence, event_sequence_list
				if needed_kind == "sequence" then
					event_sequence, event_sequence_list = take_event_scenario(template)
					if not event_sequence then error("surface anomaly event scenario pool unavailable") end
				end
				local tpos = ObjectPos(template)
				if not (tpos and type(tpos.xy) == "function") then
					error("surface anomaly template position unavailable")
				end
				local sector = placeholder_sectors[((placement_n - 1) % #placeholder_sectors) + 1]
				local x = math.floor((sector.area_x0 + sector.area_x1) / 2)
				local y = math.floor((sector.area_y0 + sector.area_y1) / 2)
				local tx, ty = tpos:xy()
				local clone = clone_fn(map, template, point(x - tx, y - ty, 0))
				if not clone or type(clone) ~= "table" then
					error("surface anomaly placeholder creation failed")
				end
				if needed_kind == "complete" or needed_kind == "unlock" then
					clone.tech_action = needed_kind
					clone.sequence = ""
					clone.sequence_list = ""
				elseif needed_kind == "sequence" then
					clone.tech_action = false
					clone.sequence = event_sequence
					clone.sequence_list = event_sequence_list
				end
				added = added + 1
				added_by_kind[needed_kind] = (added_by_kind[needed_kind] or 0) + 1
				clone.SuperBigMapAnomalyTopUp = true
				clone.SuperBigMapAnomalyTopUpKind = needed_kind
				clone.SuperBigMapEdgeTopUp = true
				clone.is_placed = false
				clone.placed_obj = false
				SetRevealedState(clone, false)
			end
			local ok, stats = RedistributeOuterRingTopUpAnomalies(map, ring_sectors)
			redistribution_stats = stats
			if not ok then error(stats and stats.error or "unknown redistribution failure") end
			return
		end
		local repulsion = NewTopUpRepulsionTracker(map, "anomalies")
		local candidates = {}
		local ring_sector_pool = {}
		local BASE_WHOLE_MAP_SAMPLES = 6000
		local SAMPLES_PER_RING_SECTOR = 32
		local STAGE_TWO_AREA_SAMPLES = 96
		local MAX_POOL = 10000
		-- Build the live, index-base-independent edge context. Surface sampling is stratified by
		-- every live ring sector so random sampling
		-- cannot silently omit the final bottom/right runs (or any other part of the perimeter).
		edge_ctx = surface_edge_ring and BuildTopUpEdgeContext(map) or nil
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
					for _ = 1, SAMPLES_PER_RING_SECTOR do sampling_plan[#sampling_plan + 1] = s end
				end
			end
		end
		local MAX_SAMPLES = #sampling_plan > 0 and #sampling_plan or BASE_WHOLE_MAP_SAMPLES
		local cached = not surface_edge_ring and CachedTopUpCandidates(map)
		if cached then
			for _, c in ipairs(cached) do
				if not c.used then candidates[#candidates + 1] = c end
			end
			reused_pool = #candidates > 0
		end
		local optimize_placement_pool = cfg().OPTIMIZE_TOPUP_PLACEMENT_POOLS == true
		local initial_candidate_target = sequential_underground and #candidates
			or (optimize_placement_pool
				and math.min(MAX_POOL, math.max(512, shortfall * 32)) or MAX_POOL)
		local candidate_samples = 0
		local function random_between(first, past_last)
			first, past_last = math.floor(first), math.floor(past_last)
			local span = past_last - first
			if span <= 0 then return first end
			return first + RandInt(span)
		end
		local function sample_position(sample_n)
			local expected = sampling_plan[sample_n]
			if underground then
				local x, y, sector, descriptor = SampleUndergroundTopUpPosition(
					map, lo_x, lo_y, span_x, span_y)
				return x, y, descriptor, sector
			end
			if not expected or not edge_ctx or type(edge_ctx.sector_step) ~= "number" then
				return lo_x + RandInt(span_x), lo_y + RandInt(span_y), nil
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
			return random_between(x0, x1), random_between(y0, y1), expected
		end
		local terrain_api = validation_context.terrain
		local function sample_candidate()
			candidate_samples = candidate_samples + 1
			local sample_n = candidate_samples
			local x, y, expected_sector, planned_sector = sample_position(sample_n)
			local sector = planned_sector or SectorAtPoint(map, x, y)
			local in_target_area = not surface_edge_ring or IsInFinalOuterSectorRing(
				map, x, y, ring_sectors, sector, ring_context)
			local scanned = sector and SectorIsScanned(sector) or false
			local passable, can_receive, buildable, unobstructed = false, false, false, false
			local valley_score, flatness, terrain_z, restriction_tier = 0, 0, nil, nil
			local sector_matches_plan = not expected_sector or (sector
				and sector.id == expected_sector.id
				and sector.col == expected_sector.col and sector.row == expected_sector.row)
			local rejection
			if not sector then
				rejection = "no_sector"
			elseif not sector_matches_plan then
				rejection = "sector_mapping_mismatch"
			elseif not underground and scanned then
				rejection = "sector_scanned"
			elseif not in_target_area then
				rejection = "outside_target_final_ring"
			else
				local pt = point(x, y)
				local evaluated_can_receive, evaluated_passable, evaluated_flatness,
					evaluated_buildable, evaluated_q, evaluated_r, evaluated_unobstructed = CanReceiveDeposit(
						map, pt, validation_context, defer_candidate_reachability)
				passable = evaluated_passable == true
				flatness = evaluated_flatness or 0
				unobstructed = evaluated_unobstructed == true
				can_receive = evaluated_can_receive == true
				buildable = evaluated_buildable == true
				if evaluated_unobstructed == false then
					rejection = "build_obstructed"
				elseif not can_receive then
					rejection = "not_flat_buildable_terrain"
				else
					if surface_edge_ring then
						-- Terrain never influences the stage-one sector lottery, but it is a hard
						-- stage-two constraint: every accepted point is flat and buildable.
						restriction_tier = 1
						if type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function" then
							local ok_h, h = pcall(terrain_api.GetHeight, map, pt)
							if ok_h and type(h) == "number" then terrain_z = h end
						end
					end
					local _, nearest_side, edge_depth = PerimeterCoordinate(edge_ctx, x, y)
					local layer = surface_edge_ring and type(edge_ctx.sector_step) == "number"
						and math.min(ring_sectors, math.floor((edge_depth or 0) / edge_ctx.sector_step) + 1)
						or nil
					local duplicate = underground and not ReserveUndergroundTopUpHex(
						map, evaluated_q, evaluated_r)
					if duplicate then return end
					local candidate = {
						x = x, y = y, valley_score = valley_score, passable = passable,
						flatness = flatness, buildable = buildable, unobstructed = unobstructed,
						terrain_z = terrain_z, restriction_tier = restriction_tier,
						terrain_type = underground and -1 or nil,
						sector = sector, q = evaluated_q, r = evaluated_r,
						_sbm_terrain_valid = true,
						_sbm_repulsion_hex = type(evaluated_q) == "number"
							and type(evaluated_r) == "number"
							and (tostring(evaluated_q) .. ":" .. tostring(evaluated_r)) or nil,
						sector_id = sector and sector.id, col = sector and sector.col,
						row = sector and sector.row, sample_n = sample_n,
						nearest_side = nearest_side,
						edge_depth = edge_depth, layer = layer,
					}
					candidates[#candidates + 1] = candidate
					if underground then
						PublishUndergroundTopUpCandidate(map, candidate, candidates)
					end
				end
			end
		end
		local function grow_candidate_pool(target, maximum_samples)
			target = math.min(MAX_POOL, math.max(#candidates, math.floor(target or #candidates)))
			maximum_samples = math.max(candidate_samples, math.floor(maximum_samples or MAX_SAMPLES))
			while #candidates < target and candidate_samples < maximum_samples do
				sample_candidate()
			end
			return #candidates
		end
		-- Surface and rollback behavior retain their reserve. The optimized underground path starts
		-- with only the resource handoff and grows on demand in the placement loop below.
		grow_candidate_pool(initial_candidate_target, MAX_SAMPLES)
		-- Surface extras keep the dedicated outer-ring sector/side/layer scheduler. Underground
		-- extras use the shared capacity-normalized selector across reachable cave-floor sectors.
		local function new_whole_map_selector(label)
			return not surface_edge_ring
				and NewSectorBalancedCandidateSelector(map, candidates,
					label or (underground and "underground anomalies" or "surface anomalies"),
					function(candidate, profile) return repulsion.CanPlace(candidate, profile) end) or nil
		end
		local whole_map_selector = new_whole_map_selector()
		local relaxed_whole_map_selector
		local function rebuild_whole_map_selectors()
			whole_map_selector = new_whole_map_selector()
			relaxed_whole_map_selector = nil
		end
		local function take_reachable_candidate(selector, profile)
			while selector do
				local candidate = selector.Take(nil, profile)
				if not candidate or not defer_candidate_reachability then return candidate end
				local reachable, checked = UndergroundCandidateReachable(
					map, candidate, validation_context)
				if checked then reachability_checks = reachability_checks + 1 end
				if reachable then return candidate end
				reachability_rejections = reachability_rejections + 1
			end
			return nil
		end
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
		-- Stage two accepts only flat, buildable, passable, unobstructed coordinates in the selected
		-- sector, then randomly chooses from the configured lowest percentage of that valid pool.
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
				local terrain_allowed, passable, flatness, buildable =
					EvaluateDepositTerrain(map, pt, validation_context)
				flatness = flatness or 0
				passable = passable == true
				buildable = buildable == true
				local unobstructed = terrain_allowed
					and IsUnobstructedAt(map, pt, true, validation_context) or false
				local can_receive = terrain_allowed and unobstructed
				local rejection
				if not live_sector or live_sector.id ~= sector.id then rejection = "sector_mapping_mismatch"
				elseif SectorIsScanned(live_sector) then rejection = "sector_scanned"
				elseif not IsInFinalOuterSectorRing(
					map, x, y, ring_sectors, live_sector, ring_context) then
					rejection = "outside_target_final_ring"
				end
				if not rejection then
					if not terrain_allowed then rejection = "not_flat_buildable_terrain"
					elseif not unobstructed then rejection = "build_obstructed" end
				end
				local terrain_z, restriction_tier
				if not rejection then
					restriction_tier = 1
					if type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function" then
						local ok_h, h = pcall(terrain_api.GetHeight, map, pt)
						if ok_h and type(h) == "number" then terrain_z = h end
					end
					local _, nearest_side, edge_depth = PerimeterCoordinate(edge_ctx, x, y)
					local candidate = {
						x = x, y = y, passable = passable, can_receive = can_receive,
						flatness = flatness, buildable = buildable, unobstructed = true,
						terrain_z = terrain_z, restriction_tier = restriction_tier, valley_score = 0,
						sector_id = live_sector.id, col = live_sector.col, row = live_sector.row,
						sample_n = stage_two_sample_n, stage_two_sample = area_sample,
						nearest_side = nearest_side,
						edge_depth = edge_depth, layer = sector.selection_layer,
					}
					candidates[#candidates + 1] = candidate
					source[#source + 1] = candidate
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
				local tier = candidate.restriction_tier or 1
				if not candidate.used and not seen[key] and not reserved_anomaly_hexes[key]
					and repulsion.CanPlace(candidate, anomaly_profile) then
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
			if #matching == 0 then
				matching = collect(true, false)
			end
			if #matching == 0 then
				for distance = 1, bin_count - 1 do
					matching = collect(false, true, distance)
					if #matching > 0 then
						break
					end
				end
			end
			if #matching == 0 then
				for distance = 1, bin_count - 1 do
					matching = collect(false, false, distance)
					if #matching > 0 then
						break
					end
				end
			end
			if #matching == 0 then matching = collect(false, false) end
			if #matching == 0 then
				local whole = {}
				for i = 1, #available_sectors do whole[#whole + 1] = i end
				matching = whole
			end
			return #matching > 0 and matching[RandInt(#matching) + 1] or nil
		end
		local placement_n = 1
		while placement_n <= shortfall do
			if surface_edge_ring and #available_sectors == 0 then break end
			local preferred_side = surface_edge_ring and placement_side_schedule[placement_n] or nil
			local occurrence = preferred_side and (side_occurrence[preferred_side] + 1) or nil
			local target_bin = preferred_side and side_bin_order[preferred_side][occurrence] or nil
			local target_layer = preferred_side and side_layer_order[preferred_side][occurrence] or nil
			local c
			local selected_sector, reserved_key
			local selected_whole_map_selector, density_fallback
			if surface_edge_ring then
				-- A sector is drawn first. Only afterwards do we inspect that sector's terrain.
				-- If it has no passable, unobstructed sampled hex, draw another sector;
				-- terrain quality never influences which sector wins an individual draw.
				while not c and #available_sectors > 0 do
					local sector_i
					sector_i = coverage_sector_index(preferred_side, target_bin, target_layer)
					if not sector_i then break end
					selected_sector = available_sectors[sector_i]
					table.remove(available_sectors, sector_i)
					c, reserved_key = area_candidate_for_sector(selected_sector)
				end
				if not c then break end
				reserved_anomaly_hexes[reserved_key] = true
				c.used = true
			else
				c = take_reachable_candidate(whole_map_selector, anomaly_profile)
				selected_whole_map_selector = c and whole_map_selector or nil
				if not c and sequential_underground then
					-- As on the surface outer ring, search only for the anomaly currently being
					-- placed. Stop validating as soon as one strict candidate succeeds.
					local strict_sample_limit = math.min(MAX_SAMPLES, candidate_samples + 128)
					while not c and candidate_samples < strict_sample_limit do
						local before = #candidates
						grow_candidate_pool(before + 1, strict_sample_limit)
						if #candidates <= before then break end
						rebuild_whole_map_selectors()
						c = take_reachable_candidate(whole_map_selector, anomaly_profile)
						selected_whole_map_selector = c and whole_map_selector or nil
					end
				end
				if not c and underground then
					relaxed_whole_map_selector = relaxed_whole_map_selector
						or NewWellSpacedUndergroundFallbackSelector(
							map, candidates, "underground anomaly residual",
							function(candidate) return repulsion.CanPlaceUnique(candidate) end)
					c = take_reachable_candidate(relaxed_whole_map_selector, anomaly_profile)
					selected_whole_map_selector = c and relaxed_whole_map_selector or nil
					density_fallback = c ~= nil
					if not c and sequential_underground then
						-- If the shared resource handoff contains no unique position, obtain a small
						-- on-demand fallback choice set instead of precomputing a 512-point reserve.
						local fallback_sample_limit = MAX_SAMPLES
						while not c and candidate_samples < fallback_sample_limit do
							local before = #candidates
							grow_candidate_pool(before + 1, fallback_sample_limit)
							if #candidates <= before then break end
							rebuild_whole_map_selectors()
							c = take_reachable_candidate(whole_map_selector, anomaly_profile)
							selected_whole_map_selector = c and whole_map_selector or nil
							if not c then
								relaxed_whole_map_selector = NewWellSpacedUndergroundFallbackSelector(
									map, candidates, "underground anomaly sequential residual",
									function(candidate) return repulsion.CanPlaceUnique(candidate) end)
								c = take_reachable_candidate(relaxed_whole_map_selector, anomaly_profile)
								selected_whole_map_selector = c and relaxed_whole_map_selector or nil
								density_fallback = c ~= nil
							end
						end
					end
				end
				if not c then break end
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
					if selected_whole_map_selector then selected_whole_map_selector.Commit(c) end
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
					clone.SuperBigMapTopUpIgnoredRubbleWalls = underground
						and rubble_wall_suite_token_by_map[map] ~= nil or nil
					clone.SuperBigMapUndergroundDensityFallback = density_fallback or nil
					clone.SuperBigMapUndergroundWellSpacedFallback = density_fallback or nil
					clone.SuperBigMapUndergroundFallbackSpacingWorld = density_fallback
						and RoundedWorldDistance(c._sbm_selected_fallback_spacing_sq) or nil
					clone.SuperBigMapUndergroundFallbackSpacingHex = density_fallback
						and c._sbm_selected_fallback_hex_distance or nil
					clone.SuperBigMapUndergroundFallbackSpacingRelaxed = density_fallback
						and c._sbm_fallback_spacing_relaxed or nil
					if density_fallback then
						density_fallback_added = density_fallback_added + 1
						fallback_selector_stats = selected_whole_map_selector
							and selected_whole_map_selector.Stats() or fallback_selector_stats
					end
					if type(clone.SetPos) == "function" then
						local pt = point(c.x, c.y)
						if type(pt.SetTerrainZ) == "function" then
							local ok, snapped = pcall(pt.SetTerrainZ, pt, map)
							if ok and snapped then pt = snapped end
						end
						pcall(clone.SetPos, clone, pt)
					end
					repulsion.Commit(c, anomaly_profile, clone)
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
					end
				end
			end
			if placement_succeeded then
				if preferred_side then side_occurrence[preferred_side] = occurrence end
				placement_n = placement_n + 1
			end
		end
		if surface_edge_ring then
			local ok, stats = RedistributeOuterRingTopUpAnomalies(map, ring_sectors)
			redistribution_stats = stats
			if not ok then error(stats and stats.error or "unknown redistribution failure") end
		end
		if relaxed_whole_map_selector then
			local stats = relaxed_whole_map_selector.Stats()
			if (stats.selected or 0) > 0 then fallback_selector_stats = stats end
		end
		candidate_pool_size, candidate_samples_total = #candidates, candidate_samples
	end)
	if not topup_ok then
		error("anomaly top-up transaction failed: " .. tostring(topup_error))
	end
	local final_by_kind, remaining_shortfall = {}, 0
	pcall(map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(marker)
		if not marker then return end
		local kind = AnomalyKind(marker)
		final_by_kind[kind] = (final_by_kind[kind] or 0) + 1
	end)
	for _, kind in ipairs(target_keys) do
		local final_count = final_by_kind[kind] or 0
		remaining_shortfall = remaining_shortfall
			+ math.max(0, (target_by_kind[kind] or 0) - final_count)
	end
	local print_fn = (AuditEnabled() or cfg().DEBUG_LOADING_TIMINGS == true)
		and Global("print") or nil
	if type(print_fn) == "function" then
		print_fn("[Super Big Map][AnomalyTopUp] source=" .. CountMapString(source_by_kind)
			.. " target=" .. CountMapString(target_by_kind)
			.. " final=" .. CountMapString(final_by_kind)
			.. " added=" .. CountMapString(added_by_kind)
			.. " added_total=" .. tostring(added)
			.. " remaining=" .. tostring(remaining_shortfall)
			.. " candidates=" .. tostring(candidate_pool_size)
			.. " sampled=" .. tostring(candidate_samples_total)
			.. " reused=" .. tostring(reused_pool)
			.. " sequential=" .. tostring(sequential_underground)
			.. " deferred_reachability=" .. tostring(defer_candidate_reachability)
			.. " reachability_checks=" .. tostring(reachability_checks)
			.. " reachability_rejections=" .. tostring(reachability_rejections))
	end
	SetEnrichmentTopUpStatus(map, "anomalies", remaining_shortfall == 0, remaining_shortfall, {
		area_factor = area_factor, source_counts = CountMapString(source_by_kind),
		target_counts = CountMapString(target_by_kind), final_counts = CountMapString(final_by_kind),
		added_counts = CountMapString(added_by_kind), added_total = added,
		underground_density_fallback_added = density_fallback_added,
		underground_fallback_strategy = fallback_selector_stats and fallback_selector_stats.strategy or "none",
		underground_fallback_eligible_sectors = fallback_selector_stats
			and fallback_selector_stats.eligible_sectors or 0,
		underground_fallback_selected_sectors = fallback_selector_stats
			and fallback_selector_stats.selected_sectors or 0,
		underground_fallback_max_per_sector = fallback_selector_stats
			and fallback_selector_stats.max_additions_to_one_sector or 0,
		underground_fallback_min_spacing_world = fallback_selector_stats
			and fallback_selector_stats.minimum_selected_spacing_world or 0,
		underground_fallback_min_spacing_hex = fallback_selector_stats
			and fallback_selector_stats.minimum_selected_hex_distance or 0,
		underground_fallback_required_spacing_hex = fallback_selector_stats
			and fallback_selector_stats.minimum_required_hex_distance or 0,
		underground_fallback_clearance_rejections = fallback_selector_stats
			and fallback_selector_stats.clearance_rejections or 0,
		underground_fallback_clearance_relaxations = fallback_selector_stats
			and fallback_selector_stats.clearance_relaxations or 0,
		underground_fallback_relaxed_selected = fallback_selector_stats
			and fallback_selector_stats.relaxed_selected or 0,
		surface_outer_ring = tostring(not IsUndergroundMap(map)),
		outer_ring_redistributed = redistribution_stats and redistribution_stats.moved or 0,
		outer_ring_placed = redistribution_stats and redistribution_stats.outer_planned or 0,
		inner_ring_fallback = redistribution_stats and redistribution_stats.inner_fallback or 0,
		outer_ring_sector_count = redistribution_stats and redistribution_stats.ring_sectors or 0,
		candidate_pool_size = candidate_pool_size,
		candidate_samples = candidate_samples_total,
		sequential_placement = sequential_underground,
		deferred_reachability = defer_candidate_reachability,
		reachability_checks = reachability_checks,
		reachability_rejections = reachability_rejections,
	})
end

-- Build an index-base-independent description of the final surface sector grid. The live
-- MapSector.area boxes can briefly retain source-map bounds while the stretched map is being
-- finalized, so the canonical SectorGrid layout is authoritative for placement coordinates.
BuildTopUpEdgeContext = function(map)
	local map_w, map_h, tile = MapWorldSize(map)
	local city = map and map.City
	local ctx = {
		map_w = map_w, map_h = map_h, tile = tile,
		min_col = nil, max_col = nil, min_row = nil, max_row = nil,
		sectors = {},
	}
	local sector_grid = SuperBigMap.SectorGrid
	if sector_grid and type(sector_grid.ResolveSectorLayout) == "function"
		and type(sector_grid.SectorBounds) == "function" then
		local ok_layout, layout = pcall(sector_grid.ResolveSectorLayout, map)
		if ok_layout and type(layout) == "table"
			and type(layout.width) == "number" and layout.width > 0
			and type(layout.height) == "number" and layout.height > 0
			and type(layout.step_x) == "number" and layout.step_x > 0
			and type(layout.step_y) == "number" and layout.step_y > 0 then
			ctx.layout = layout
			ctx.map_w, ctx.map_h = layout.width, layout.height
			ctx.step_x, ctx.step_y = layout.step_x, layout.step_y
			ctx.sector_bounds = sector_grid.SectorBounds
		end
	end
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
						if ctx.layout then
							local ok_bounds, x0, y0, x1, y1 = pcall(
								ctx.sector_bounds, ctx.layout, col, row)
							if ok_bounds then
								area_x0, area_y0, area_x1, area_y1 = x0, y0, x1, y1
							end
						elseif sector.area then
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
	ctx.ring_w = ctx.map_w
	ctx.ring_h = ctx.map_h
	if not ctx.step_x and type(ctx.map_w) == "number" and ctx.cols > 0 then
		ctx.step_x = (ctx.map_w + 0.0) / ctx.cols
	end
	if not ctx.step_y and type(ctx.map_h) == "number" and ctx.rows > 0 then
		ctx.step_y = (ctx.map_h + 0.0) / ctx.rows
	end
	ctx.sector_step = ctx.step_x or ctx.sector_step
	return ctx
end

-- Replace every TOP-UP anomaly in the final N-sector perimeter ring. Native anomalies are never
-- selected or moved. First plan the complete top-up population, then move it, so a failed search can
-- never leave a half-redistributed map. Outer-ring top-ups deliberately use a simple custom rule:
-- unique hexes, at least 10 hexes from every other anomaly, and at most 1 top-up per sector. If the
-- outer band cannot hold the full population, only the remainder falls back to reachable interior
-- sectors and uses vanilla anomaly repulsion.
RedistributeOuterRingTopUpAnomalies = function(map, ring_sectors)
	local stats = {
		moved = 0, planned = 0, ring_sectors = 0, expected_ring_sectors = 0,
		inner_sectors = 0, bottom_sectors = 0, right_sectors = 0,
	}
	if not map or IsUndergroundMap(map) or type(map.MapForEach) ~= "function" then
		stats.error = "surface map API unavailable"
		return false, stats
	end
	ring_sectors = math.max(0, math.floor(ring_sectors or 0))
	if ring_sectors <= 0 then return true, stats end
	local point_fn = Global("point")
	if type(point_fn) ~= "function" then
		stats.error = "point API unavailable"
		return false, stats
	end
	local edge_ctx = BuildTopUpEdgeContext(map)
	if not edge_ctx or edge_ctx.cols <= 0 or edge_ctx.rows <= 0
		or type(edge_ctx.ring_w) ~= "number" or type(edge_ctx.ring_h) ~= "number" then
		stats.error = "final sector layout unavailable"
		return false, stats
	end

	local function in_ring(sector)
		return sector and (sector.col <= edge_ctx.min_col + ring_sectors - 1
			or sector.col >= edge_ctx.max_col - ring_sectors + 1
			or sector.row <= edge_ctx.min_row + ring_sectors - 1
			or sector.row >= edge_ctx.max_row - ring_sectors + 1)
	end
	local ring, inner = {}, {}
	for _, sector in ipairs(edge_ctx.sectors) do
		if type(sector.area_x0) ~= "number" or type(sector.area_y0) ~= "number"
			or type(sector.area_x1) ~= "number" or type(sector.area_y1) ~= "number" then
			stats.error = "canonical bounds unavailable for final sector " .. tostring(sector.id)
			return false, stats
		end
		if in_ring(sector) then
			ring[#ring + 1] = sector
			if sector.row >= edge_ctx.max_row - ring_sectors + 1 then
				stats.bottom_sectors = stats.bottom_sectors + 1
			end
			if sector.col >= edge_ctx.max_col - ring_sectors + 1 then
				stats.right_sectors = stats.right_sectors + 1
			end
		else
			inner[#inner + 1] = sector
		end
	end
	stats.ring_sectors = #ring
	stats.inner_sectors = #inner
	stats.expected_ring_sectors = edge_ctx.cols * edge_ctx.rows
		- math.max(0, edge_ctx.cols - 2 * ring_sectors)
			* math.max(0, edge_ctx.rows - 2 * ring_sectors)
	if #ring ~= stats.expected_ring_sectors then
		stats.error = "incomplete final outer-ring sector list"
		return false, stats
	end

	local function sector_at_canonical_position(x, y)
		for _, sector in ipairs(edge_ctx.sectors) do
			local last_col = sector.col == edge_ctx.max_col
			local last_row = sector.row == edge_ctx.max_row
			if x >= sector.area_x0 and y >= sector.area_y0
				and (x < sector.area_x1 or (last_col and x <= sector.area_x1))
				and (y < sector.area_y1 or (last_row and y <= sector.area_y1)) then
				return sector
			end
		end
		return nil
	end
	local moving, ignored = {}, {}
	local enumeration_ok, enumeration_error = pcall(
		map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(marker)
			if not (marker and marker.SuperBigMapAnomalyTopUp == true) then return end
			local pos = marker and ObjectPos(marker)
			if not (pos and type(pos.xy) == "function" and type(marker.SetPos) == "function") then return end
			local x, y = pos:xy()
			local source_sector = type(x) == "number" and type(y) == "number"
				and sector_at_canonical_position(x, y) or nil
			if not in_ring(source_sector) then return end
			local placed_obj = marker.placed_obj
			local is_valid = Global("IsValid")
			local placed = marker.is_placed == true or (placed_obj ~= nil
				and (type(is_valid) ~= "function" or is_valid(placed_obj) == true))
			moving[#moving + 1] = {
				id = #moving + 1, marker = marker, before_x = x, before_y = y,
				source_sector = source_sector, placed = placed, placed_obj = placed_obj,
			}
			ignored[marker] = true
		end)
	if not enumeration_ok then
		stats.error = "outer-ring anomaly enumeration failed: " .. tostring(enumeration_error)
		return false, stats
	end
	stats.anomalies = #moving

	local function format_positions(items, use_after)
		table.sort(items, function(a, b) return a.id < b.id end)
		local values = {}
		for _, item in ipairs(items) do
			local x = use_after and item.after_x or item.before_x
			local y = use_after and item.after_y or item.before_y
			local sector = use_after and item.target_sector or item.source_sector
			local placement = use_after
				and (item.in_outer_ring == true and "outer" or "inner-vanilla") or "source"
			values[#values + 1] = string.format("%d:%s@%d,%d[%d,%d]{%s}", item.id,
				tostring(item.marker.class or "SubsurfaceAnomalyMarker"),
				math.floor(x or -1), math.floor(y or -1),
				sector and sector.col or -1, sector and sector.row or -1, placement)
		end
		return table.concat(values, "|")
	end
	local print_fn = (AuditEnabled() or cfg().DEBUG_LOADING_TIMINGS == true)
		and Global("print") or nil
	if type(print_fn) == "function" then
		print_fn("[Super Big Map][OuterRingTopUpAnomalies] BEFORE count=" .. tostring(#moving)
			.. " sectors=" .. tostring(#ring)
			.. " bottom_sectors=" .. tostring(stats.bottom_sectors)
			.. " right_sectors=" .. tostring(stats.right_sectors)
			.. " positions=" .. format_positions(moving, false))
	end
	if #moving == 0 then
		if type(print_fn) == "function" then
			print_fn("[Super Big Map][OuterRingTopUpAnomalies] AFTER count=0 sectors="
				.. tostring(#ring) .. " positions=")
		end
		return true, stats
	end

	local validation_context = NewDepositValidationContext(map)
	local tile = edge_ctx.tile or select(3, MapWorldSize(map)) or 100
	local margin = math.max(0, math.floor(cfg().DEPOSIT_EDGE_MARGIN_TILES or 4)) * tile
	local optimized_candidate_search = cfg().OPTIMIZE_ANOMALY_CANDIDATE_SEARCH ~= false
	local OUTER_BOOTSTRAP_SAMPLES = optimized_candidate_search and 32 or 384
	local LAZY_SAMPLE_BATCH = optimized_candidate_search and 96 or 0
	local LEGACY_RANDOM_SAMPLES_PER_SECTOR = 384
	local random_sample_limit = optimized_candidate_search and 128
		or LEGACY_RANDOM_SAMPLES_PER_SECTOR
	local MIN_TOPUP_HEX_DISTANCE = 10
	local MAX_TOPUPS_PER_SECTOR = 1
	-- The outer perimeter is mostly cliffs/void on stretched maps. Before this filter, sequential
	-- placement still spent 128 complete Lua terrain/obstruction probes in every one of the 204
	-- perimeter sectors merely to prove that most sectors contained no buildable hex at all. Ask the
	-- finalized native buildable grid for presence once per sector, then preserve the exact same
	-- randomized placement and validation rules inside every sector that can possibly accept an
	-- anomaly. A high ratio scale prevents a sector with only a tiny buildable island from rounding
	-- down to zero. API failures remain eligible, so this optimization can never reject a sector on
	-- an inconclusive native query.
	local outer_search_sectors = ring
	local outer_ratio_filter_active = false
	local outer_ratio_buildable, outer_ratio_empty, outer_ratio_unknown = 0, 0, 0
	if optimized_candidate_search then
		local ratio_fn = Global("BuildableGridRatio")
		local unbuildable_fn = Global("buildUnbuildableZ")
		local box_fn = Global("box")
		local buildable_grid = map.buildable and map.buildable.z_grid
		if type(ratio_fn) == "function" and type(unbuildable_fn) == "function"
			and type(box_fn) == "function" and buildable_grid then
			local ok_unbuildable, unbuildable_z = pcall(unbuildable_fn)
			if ok_unbuildable and type(unbuildable_z) == "number" then
				outer_ratio_filter_active = true
				outer_search_sectors = {}
				for _, sector in ipairs(ring) do
					local ok_box, sector_box = pcall(box_fn, sector.area_x0, sector.area_y0,
						sector.area_x1, sector.area_y1)
					local ok_ratio, ratio = false, nil
					if ok_box and sector_box then
						-- Vanilla requests an integer percentage (scale 100). A sector contains fewer
						-- than 10,000 hexes, so this finer scale still reports a single buildable hex.
						ok_ratio, ratio = pcall(ratio_fn, buildable_grid, unbuildable_z,
							10000, sector_box)
					end
					if ok_ratio and type(ratio) == "number" then
						if ratio > 0 then
							outer_search_sectors[#outer_search_sectors + 1] = sector
							outer_ratio_buildable = outer_ratio_buildable + 1
						else
							outer_ratio_empty = outer_ratio_empty + 1
						end
					else
						-- Conservative fallback: sample sectors whose native ratio could not be read.
						outer_search_sectors[#outer_search_sectors + 1] = sector
						outer_ratio_unknown = outer_ratio_unknown + 1
					end
				end
			end
		end
	end
	stats.outer_buildable_filter = outer_ratio_filter_active
	stats.outer_buildable_sectors = outer_ratio_buildable
	stats.outer_unbuildable_sectors = outer_ratio_empty
	stats.outer_buildable_unknown = outer_ratio_unknown
	local anomaly_values = GeneratorFamilyRepulsionValues(map, "Anomaly")
	if not RepulsionValuesAreValid(anomaly_values) then
		stats.error = "vanilla anomaly repulsion profile unavailable for interior fallback"
		return false, stats
	end
	local anomaly_profile = {
		layer = "subs", resource = "Anomaly", preset = anomaly_values.preset,
		repulse_same = anomaly_values.repulse_same,
		repulse_layer = anomaly_values.repulse_layer,
		repulse_all = anomaly_values.repulse_all,
	}
	local function random_between(first, past_last)
		first, past_last = math.floor(first), math.floor(past_last)
		local span = past_last - first
		if span <= 0 then return nil end
		return first + RandInt(span)
	end
	local function shuffle(values)
		for i = #values, 2, -1 do
			local j = RandInt(i) + 1
			values[i], values[j] = values[j], values[i]
		end
	end

	-- Fixed native/non-moving anomalies are immutable throughout planning. Resolve them before
	-- sampling so an outer candidate that can never clear the explicit ten-hex rule is discarded
	-- before the relatively expensive obstruction query.
	local world_to_hex = validation_context.world_to_hex
	if type(world_to_hex) ~= "function" then
		stats.error = "WorldToHex API unavailable for outer-ring anomaly spacing"
		return false, stats
	end
	local fixed_anomaly_hexes, fixed_anomalies = {}, {}
	pcall(map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(marker)
		if ignored[marker] == true then return end
		local pos = marker and ObjectPos(marker)
		if not (pos and type(pos.xy) == "function") then return end
		local ok_hex, q, r = pcall(world_to_hex, pos)
		if ok_hex and type(q) == "number" and type(r) == "number" then
			local hex_key = tostring(q) .. ":" .. tostring(r)
			fixed_anomaly_hexes[hex_key] = true
			fixed_anomalies[#fixed_anomalies + 1] = { q = q, r = r, hex_key = hex_key }
		end
	end)
	local function hex_distance(a, b)
		local dq, dr = a.q - b.q, a.r - b.r
		return math.max(math.abs(dq), math.abs(dr), math.abs(dq + dr))
	end
	local function clears_fixed_anomalies(candidate)
		local cached = candidate and candidate._sbm_clears_fixed_anomalies
		if cached ~= nil then return cached == true end
		if not candidate then return false end
		for _, fixed in ipairs(fixed_anomalies) do
			if hex_distance(candidate, fixed) < MIN_TOPUP_HEX_DISTANCE then
				candidate._sbm_clears_fixed_anomalies = false
				return false
			end
		end
		candidate._sbm_clears_fixed_anomalies = true
		return true
	end

	-- The old implementation eagerly performed 384 complete terrain validations in all 204 outer
	-- and 196 inner sectors (153,600 probes) before it knew which sectors planning would inspect.
	-- Discover eligible outer sectors on demand so the complete buildable perimeter -- including
	-- bottom-right -- retains an equal chance, then validate one additional batch only when a visited
	-- sector has no usable candidate. Interior fallback normally consumes the resource pass's
	-- already-validated pool.
	local candidate_states = {}
	local sampled_hexes = {}
	local outer_candidate_count, inner_candidate_count = 0, 0
	local fresh_outer_samples, fresh_inner_samples = 0, 0
	local reused_inner_candidates = 0
	local function candidate_state(sector)
		local state = candidate_states[sector]
		if not state then
			state = { candidates = {}, random_samples = 0, is_outer = in_ring(sector) }
			candidate_states[sector] = state
		end
		return state
	end
	local function append_candidate(sector, candidate)
		local hex_key = candidate and candidate.hex_key
		if not hex_key or sampled_hexes[hex_key] then return false end
		sampled_hexes[hex_key] = true
		candidate._sbm_repulsion_hex = hex_key
		local state = candidate_state(sector)
		state.candidates[#state.candidates + 1] = candidate
		if in_ring(sector) then
			outer_candidate_count = outer_candidate_count + 1
		else
			inner_candidate_count = inner_candidate_count + 1
		end
		return true
	end
	local function sample_sector_candidates(sector, requested)
		local state = candidate_state(sector)
		local remaining = math.max(0, random_sample_limit - state.random_samples)
		local samples = math.min(math.max(0, math.floor(requested or 0)), remaining)
		if samples <= 0 then return 0 end
		local x0 = math.max(margin, sector.area_x0)
		local y0 = math.max(margin, sector.area_y0)
		local x1 = math.min(edge_ctx.ring_w - margin, sector.area_x1)
		local y1 = math.min(edge_ctx.ring_h - margin, sector.area_y1)
		local added = 0
		for _ = 1, samples do
			state.random_samples = state.random_samples + 1
			if state.is_outer then fresh_outer_samples = fresh_outer_samples + 1
			else fresh_inner_samples = fresh_inner_samples + 1 end
			local x, y = random_between(x0, x1), random_between(y0, y1)
			if x and y then
				local pt = point_fn(x, y)
				local possible = true
				if state.is_outer and optimized_candidate_search then
					local ok_hex, early_q, early_r = pcall(world_to_hex, pt)
					possible = ok_hex and type(early_q) == "number" and type(early_r) == "number"
						and clears_fixed_anomalies({ q = early_q, r = early_r })
				end
				if possible then
					local terrain_ok, _, _, _, q, r = EvaluateDepositTerrain(
						map, pt, validation_context)
					if terrain_ok then
						local hex_key = type(q) == "number" and type(r) == "number"
							and (tostring(q) .. ":" .. tostring(r)) or nil
						if hex_key and not sampled_hexes[hex_key]
							and IsUnobstructedAt(map, pt, true, validation_context) then
							if append_candidate(sector, {
								x = x, y = y, sector = sector.sector_ref,
								sector_id = sector.id, col = sector.col, row = sector.row,
								target_sector = sector, q = q, r = r, hex_key = hex_key,
							}) then added = added + 1 end
						end
					end
				end
			end
		end
		return added
	end

	-- The optimized path discovers sectors on demand while placing each anomaly. The rollback path
	-- retains the historical eager pool for diagnostics/comparison.
	if not optimized_candidate_search then
		for _, sector in ipairs(ring) do
			sample_sector_candidates(sector, OUTER_BOOTSTRAP_SAMPLES)
		end
	end
	if optimized_candidate_search then
		local inner_by_ref, inner_by_id = {}, {}
		for _, sector in ipairs(inner) do
			inner_by_ref[sector.sector_ref] = sector
			inner_by_id[tostring(sector.id)] = sector
		end
		local cached = CachedTopUpCandidates(map)
		for _, source in ipairs(type(cached) == "table" and cached or {}) do
			if source and not source.used and source._sbm_terrain_valid == true
				and type(source.x) == "number" and type(source.y) == "number" then
				local sector = inner_by_ref[source.sector]
					or inner_by_id[tostring(source.sector_id)]
				if not sector then
					local canonical = sector_at_canonical_position(source.x, source.y)
					if canonical and not in_ring(canonical) then sector = canonical end
				end
				if sector then
					local q, r = source.q, source.r
					if type(q) ~= "number" or type(r) ~= "number" then
						local ok_hex
						ok_hex, q, r = pcall(world_to_hex, point_fn(source.x, source.y))
						if not ok_hex then q, r = nil, nil end
					end
					local hex_key = type(q) == "number" and type(r) == "number"
						and (tostring(q) .. ":" .. tostring(r)) or nil
					if append_candidate(sector, {
						x = source.x, y = source.y, sector = sector.sector_ref,
						sector_id = sector.id, col = sector.col, row = sector.row,
						target_sector = sector, q = q, r = r, hex_key = hex_key,
						_sbm_shared_source = source,
					}) then
						reused_inner_candidates = reused_inner_candidates + 1
					end
				end
			end
		end
	else
		for _, sector in ipairs(inner) do
			sample_sector_candidates(sector, random_sample_limit)
		end
	end
	local function new_outer_attempt_tracker()
		local occupied, spaced_anomalies, sector_counts = {}, {}, {}
		local function can_place(candidate)
			if not candidate or fixed_anomaly_hexes[candidate.hex_key]
				or occupied[candidate.hex_key] then return false end
			if (sector_counts[candidate.target_sector] or 0) >= MAX_TOPUPS_PER_SECTOR then
				return false
			end
			if not clears_fixed_anomalies(candidate) then return false end
			for _, prior in ipairs(spaced_anomalies) do
				if hex_distance(candidate, prior) < MIN_TOPUP_HEX_DISTANCE then return false end
			end
			return true
		end
		local function commit(candidate)
			if not can_place(candidate) then return false end
			occupied[candidate.hex_key] = true
			spaced_anomalies[#spaced_anomalies + 1] = candidate
			sector_counts[candidate.target_sector] =
				(sector_counts[candidate.target_sector] or 0) + 1
			return true
		end
		return can_place, commit
	end

	local function find_candidate(item, sectors, predicate, allow_sampling)
		local sector_order = {}
		for i = 1, #sectors do sector_order[i] = sectors[i] end
		shuffle(sector_order)
		for _, sector in ipairs(sector_order) do
			if not item.placed or SectorIsScanned(sector.sector_ref) then
				local state = candidate_state(sector)
				local candidates = state.candidates
				local function choose_from_current_pool()
					if #candidates == 0 then return nil end
					local first = RandInt(#candidates) + 1
					for offset = 0, #candidates - 1 do
						local candidate = candidates[((first + offset - 2) % #candidates) + 1]
						local source = candidate._sbm_shared_source
						if source and candidate._sbm_current_obstruction_ok == nil then
							candidate._sbm_current_obstruction_ok = IsUnobstructedAt(
								map, point_fn(candidate.x, candidate.y), true, validation_context) == true
						end
						if (not source or candidate._sbm_current_obstruction_ok == true)
							and predicate(candidate) then return candidate end
					end
					return nil
				end
				local winner = choose_from_current_pool()
				if winner then return winner end
				if allow_sampling ~= false and optimized_candidate_search
					and state.random_samples < random_sample_limit then
					local batch = state.random_samples == 0 and OUTER_BOOTSTRAP_SAMPLES
						or LAZY_SAMPLE_BATCH
					sample_sector_candidates(sector, batch)
					winner = choose_from_current_pool()
					if winner then return winner end
				end
			end
		end
		return nil
	end

	-- Direct sequential placement: choose a random sector/position for one anomaly, reserve it,
	-- then continue with the next. This is the requested gameplay rule and avoids building and
	-- comparing dozens of complete provisional maps. A second outer pass grows a visited sector
	-- from 32 to 128 random probes before it is considered unavailable; the explicit rollback mode
	-- has already populated the historical 384-probe pools above.
	local plans, outer_plans, remaining = {}, {}, {}
	local can_place_outer, commit_outer = new_outer_attempt_tracker()
	local marker_order = {}
	for i = 1, #moving do marker_order[i] = moving[i] end
	shuffle(marker_order)
	local available_outer = {}
	for i = 1, #outer_search_sectors do available_outer[i] = outer_search_sectors[i] end
	local function remove_outer_sector(target)
		for i = #available_outer, 1, -1 do
			if available_outer[i] == target then
				table.remove(available_outer, i)
				return
			end
		end
	end
	local outer_exhausted_at
	for marker_i, item in ipairs(marker_order) do
		local winner
		local passes = optimized_candidate_search and 2 or 1
		for _ = 1, passes do
			winner = find_candidate(item, available_outer, can_place_outer, true)
			if winner then break end
		end
		if winner and commit_outer(winner) then
			local plan = { item = item, candidate = winner, in_outer_ring = true }
			plans[#plans + 1] = plan
			outer_plans[#outer_plans + 1] = plan
			remove_outer_sector(winner.target_sector)
		else
			outer_exhausted_at = marker_i
			for rest_i = marker_i, #marker_order do
				remaining[#remaining + 1] = marker_order[rest_i]
			end
			break
		end
	end
	local best_outer_planned = #outer_plans
	local best_total_planned = #plans
	local planning_attempts_run = 1
	stats.selected_plan_attempt = 1
	stats.sequential_candidate_placement = true
	stats.outer_exhausted_at = outer_exhausted_at or 0

	if #remaining > 0 then
		local repulsion = NewTopUpRepulsionTracker(map, "inner-ring sequential anomaly fallback", ignored)
		-- Outer-ring placements deliberately use the custom one-per-sector/ten-hex rules, but an
		-- anomaly that falls back into the inner ring must obey vanilla repulsion against *every*
		-- anomaly, including the outer placements planned earlier in this transaction. The tracker
		-- cannot see those destinations yet because the live markers have not moved, and all moving
		-- markers are intentionally excluded from its source-position seed. Register the provisional
		-- outer destinations explicitly before selecting the first inner fallback.
		for _, plan in ipairs(outer_plans) do
			if not repulsion.Commit(plan.candidate, anomaly_profile, plan.item.marker) then
				stats.error = "could not seed planned outer anomaly for inner vanilla fallback"
				return false, stats
			end
		end
		local function inner_candidate_allowed(candidate)
			for _, plan in ipairs(outer_plans) do
				if hex_distance(candidate, plan.candidate) < MIN_TOPUP_HEX_DISTANCE then return false end
			end
			return repulsion.CanPlace(candidate, anomaly_profile)
		end
		for _, item in ipairs(remaining) do
			-- Consume the resource pass's fully validated cache first. Only if it cannot provide a
			-- vanilla-spaced position do we sample fresh inner terrain, one bounded pass at a time.
			local winner = find_candidate(item, inner, inner_candidate_allowed, false)
			if not winner then
				local passes = optimized_candidate_search and 5 or 1
				if optimized_candidate_search then
					random_sample_limit = LEGACY_RANDOM_SAMPLES_PER_SECTOR
				end
				for _ = 1, passes do
					winner = find_candidate(item, inner, inner_candidate_allowed, true)
					if winner then break end
				end
			end
			if not winner or not repulsion.Commit(winner, anomaly_profile, item.marker) then
				stats.error = "sequential inner vanilla fallback exhausted"
				return false, stats
			end
			plans[#plans + 1] = { item = item, candidate = winner, in_outer_ring = false }
			best_total_planned = #plans
		end
	end
	stats.planning_attempts = planning_attempts_run
	stats.reachable_candidates = outer_candidate_count
	stats.inner_reachable_candidates = inner_candidate_count
	stats.outer_random_samples = fresh_outer_samples
	stats.inner_random_samples = fresh_inner_samples
	stats.inner_reused_candidates = reused_inner_candidates
	stats.candidate_search_optimized = optimized_candidate_search
	if #plans ~= #moving then
		stats.error = "no complete sequential outer-plus-vanilla-interior anomaly plan (best="
			.. tostring(best_total_planned) .. "/" .. tostring(#moving)
			.. ", outer_candidates=" .. tostring(outer_candidate_count)
			.. ", inner_candidates=" .. tostring(inner_candidate_count) .. ")"
		return false, stats
	end
	local finalized_plans = {}
	for _, plan in ipairs(plans) do
		local item, winner = plan.item, plan.candidate
		item.after_x, item.after_y = winner.x, winner.y
		item.target_sector = winner.target_sector
		item.in_outer_ring = plan.in_outer_ring == true
		item.shared_candidate_source = winner._sbm_shared_source
		finalized_plans[#finalized_plans + 1] = item
	end
	plans = finalized_plans
	stats.planned = #plans
	stats.outer_planned = best_outer_planned
	stats.inner_fallback = #plans - best_outer_planned
	stats.minimum_hex_distance = MIN_TOPUP_HEX_DISTANCE
	stats.maximum_per_sector = MAX_TOPUPS_PER_SECTOR

	for _, item in ipairs(plans) do
		local old_sector = item.source_sector and item.source_sector.sector_ref
		if old_sector and type(old_sector.UnregisterDeposit) == "function" then
			pcall(old_sector.UnregisterDeposit, old_sector, item.marker)
		else
			UnregisterNativeMarker(map, item.marker)
		end
		local pt = point_fn(item.after_x, item.after_y)
		if type(pt.SetTerrainZ) == "function" then
			local ok_z, snapped = pcall(pt.SetTerrainZ, pt, map)
			if ok_z and snapped then pt = snapped end
		end
		local move_ok, move_error = pcall(item.marker.SetPos, item.marker, pt)
		if not move_ok then
			stats.error = "anomaly SetPos failed: " .. tostring(move_error)
			return false, stats
		end
		if item.placed and item.placed_obj and type(item.placed_obj.SetPos) == "function" then
			local object_ok, object_error = pcall(item.placed_obj.SetPos, item.placed_obj, pt)
			if not object_ok then
				stats.error = "placed anomaly SetPos failed: " .. tostring(object_error)
				return false, stats
			end
		end
		local sector = item.target_sector.sector_ref
		if not sector or type(sector.RegisterDeposit) ~= "function" then
			stats.error = "target anomaly sector cannot register marker"
			return false, stats
		end
		local register_ok, register_error = pcall(sector.RegisterDeposit, sector, item.marker)
		if not register_ok then
			stats.error = "target anomaly sector registration failed: " .. tostring(register_error)
			return false, stats
		end
		if not item.placed then
			item.marker.is_placed = false
			item.marker.placed_obj = false
			SetRevealedState(item.marker, false)
			if SectorIsScanned(sector) then
				local reveal = Global("RevealDeposits")
				if type(reveal) ~= "function" then
					stats.error = "RevealDeposits unavailable for scanned anomaly sector"
					return false, stats
				end
				local reveal_ok, reveal_error = pcall(reveal, { item.marker })
				if not reveal_ok then
					stats.error = "redistributed anomaly reveal failed: " .. tostring(reveal_error)
					return false, stats
				end
			end
		end
		item.marker.SuperBigMapEdgeRedistributed = true
		item.marker.SuperBigMapOuterRingRedistributed = item.in_outer_ring == true or nil
		item.marker.SuperBigMapInnerRingFallback = item.in_outer_ring ~= true or nil
		-- The resource-pool wrapper and its source describe this same hex. Retire the source only
		-- after the complete move/register transaction succeeds so the effect pass neither revalidates
		-- an occupied coordinate nor counts it in capacity-normalized sector weights.
		if item.shared_candidate_source then item.shared_candidate_source.used = true end
		stats.moved = stats.moved + 1
	end
	if type(print_fn) == "function" then
		print_fn("[Super Big Map][OuterRingTopUpAnomalies] AFTER count=" .. tostring(#plans)
			.. " sectors=" .. tostring(#ring)
			.. " bottom_sectors=" .. tostring(stats.bottom_sectors)
			.. " right_sectors=" .. tostring(stats.right_sectors)
			.. " inner_sectors=" .. tostring(stats.inner_sectors)
			.. " outer_count=" .. tostring(stats.outer_planned)
			.. " inner_fallback_count=" .. tostring(stats.inner_fallback)
			.. " outer_reachable_candidates=" .. tostring(stats.reachable_candidates)
			.. " inner_reachable_candidates=" .. tostring(stats.inner_reachable_candidates)
			.. " outer_random_samples=" .. tostring(stats.outer_random_samples)
			.. " inner_random_samples=" .. tostring(stats.inner_random_samples)
			.. " inner_reused_candidates=" .. tostring(stats.inner_reused_candidates)
			.. " buildable_filter=" .. tostring(stats.outer_buildable_filter)
			.. " buildable_outer_sectors=" .. tostring(stats.outer_buildable_sectors)
			.. " unbuildable_outer_sectors=" .. tostring(stats.outer_unbuildable_sectors)
			.. " unknown_buildable_sectors=" .. tostring(stats.outer_buildable_unknown)
			.. " planning_attempts=" .. tostring(stats.planning_attempts)
			.. " minimum_hex_distance=" .. tostring(stats.minimum_hex_distance)
			.. " maximum_per_sector=" .. tostring(stats.maximum_per_sector)
			.. " positions=" .. format_positions(plans, true))
	end
	return true, stats
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
		-- +0.0 is required because this engine truncates integer/integer division.
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
	SetEnrichmentTopUpStatus(map, "effects", false, 0)
	local point = Global("point")
	local clone_fn = SuperBigMap.ObjectClone and SuperBigMap.ObjectClone.CloneObjectAtOffset
	local city = map and map.City
	if not map or type(map.MapForEach) ~= "function" or type(point) ~= "function"
		or type(clone_fn) ~= "function" or not city then
		return
	end
	local map_w, map_h, tile = MapWorldSize(map)
	if not map_w or not tile or tile <= 0 then
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
		return
	end

	local current_by_type, templates_by_type = {}, {}
	pcall(map.MapForEach, map, "map", "EffectDepositMarker", function(marker)
		if not marker then return end
		local deposit_type = tostring(marker.deposit_type or "")
		if deposit_type == "" or not EffectDepositTopUpEnabled(deposit_type) then return end
		current_by_type[deposit_type] = (current_by_type[deposit_type] or 0) + 1
		if not marker.SuperBigMapEnrichmentClone then
			local list = templates_by_type[deposit_type]
			if not list then list = {}; templates_by_type[deposit_type] = list end
			list[#list + 1] = marker
		end
	end)

	local types, total_shortfall = {}, 0
	local target_by_type = {}
	local source_by_type = {}
	for deposit_type, templates in pairs(templates_by_type) do
		if #templates > 0 then
			types[#types + 1] = deposit_type
			source_by_type[deposit_type] = #templates
			local target = math.floor(#templates * area_factor + 0.5)
			target_by_type[deposit_type] = target
			total_shortfall = total_shortfall + math.max(0, target - (current_by_type[deposit_type] or 0))
		end
	end
	table.sort(types)
	if total_shortfall <= 0 then
		SetEnrichmentTopUpStatus(map, "effects", true, 0, {
			area_factor = area_factor, source_counts = CountMapString(source_by_type),
			target_counts = CountMapString(target_by_type),
			current_counts = CountMapString(current_by_type), added_counts = "",
		})
		return
	end
	local effect_values = GeneratorFamilyRepulsionValues(map, "Effects")
	if not RepulsionValuesAreValid(effect_values) then
		error("effect-deposit top-up cannot apply vanilla repulsion: profile unavailable")
	end
	local effect_profile = {
		layer = "surf", resource = "Effects", preset = effect_values.preset,
		repulse_same = effect_values.repulse_same,
		repulse_layer = effect_values.repulse_layer,
		repulse_all = effect_values.repulse_all,
	}

	local added_by_type = {}
	local density_fallback_added = 0
	local fallback_selector_stats
	local reused_pool = false
	local candidate_pool_size, candidate_samples_total = 0, 0
	local validation_context = IsUndergroundMap(map)
		and SharedTopUpValidationContext(map) or NewDepositValidationContext(map)
	local underground = validation_context.underground == true
	local sequential_underground = underground
		and cfg().OPTIMIZE_TOPUP_PLACEMENT_POOLS == true
	local defer_candidate_reachability = underground
		and cfg().OPTIMIZE_UNDERGROUND_DEFER_CANDIDATE_REACHABILITY == true
	local reachability_checks, reachability_rejections = 0, 0
	local wall_free_density_suite = underground
		and rubble_wall_suite_token_by_map[map] ~= nil
	local ring_sectors = cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3
	local ring_context = not underground and NewFinalOuterSectorRingContext(map) or nil
	RunPaused("SuperBigMapEffectDepositTopUp", function()
		local repulsion = NewTopUpRepulsionTracker(map, "effects")
		local candidates = {}
		local MAX_SAMPLES, MAX_POOL = 6000, 2500
		local target_pool = sequential_underground and 0
			or math.min(MAX_POOL, math.max(512, total_shortfall * 32))
		local candidate_samples = 0
		local cached = CachedTopUpCandidates(map)
		if cached then
			for _, c in ipairs(cached) do
				if not sequential_underground and #candidates >= target_pool then break end
				if not c.used then
					local pt = point(c.x, c.y)
					local reserved_ring = not underground and IsInFinalOuterSectorRing(
						map, c.x, c.y, ring_sectors, c.sector, ring_context)
					local can_reuse = (not underground or wall_free_density_suite)
						and c._sbm_terrain_valid == true
						and IsUnobstructedAt(map, pt, true, validation_context)
					if not reserved_ring and (can_reuse
						or CanReceiveDeposit(map, pt, validation_context,
							defer_candidate_reachability)) then
						candidates[#candidates + 1] = c
					end
				end
			end
			reused_pool = #candidates > 0
		end
		-- Surface and rollback behavior fill the historical reserve. The optimized underground path
		-- reuses every safe handoff candidate, then samples only when the next effect needs a position.
		local function sample_fresh_candidate()
			candidate_samples = candidate_samples + 1
			local x, y, planned_sector
			if underground then
				x, y, planned_sector = SampleUndergroundTopUpPosition(
					map, lo_x, lo_y, span_x, span_y)
			else
				x, y = lo_x + RandInt(span_x), lo_y + RandInt(span_y)
			end
			local sector = planned_sector or SectorAtPoint(map, x, y)
			local reserved_ring = not underground and IsInFinalOuterSectorRing(
				map, x, y, ring_sectors, sector, ring_context)
			if sector and (underground or not SectorIsScanned(sector)) and not reserved_ring then
				local pt = point(x, y)
				local can_receive, _, _, _, q, r = CanReceiveDeposit(
					map, pt, validation_context, defer_candidate_reachability)
				if can_receive and (not underground or ReserveUndergroundTopUpHex(map, q, r)) then
					local candidate = {
						x = x, y = y,
						terrain_type = TerrainTypeAt(map, pt, validation_context) or -1,
						sector = sector, sector_id = sector.id,
						q = q, r = r, _sbm_terrain_valid = true,
						_sbm_repulsion_hex = type(q) == "number" and type(r) == "number"
							and (tostring(q) .. ":" .. tostring(r)) or nil,
					}
					candidates[#candidates + 1] = candidate
					if underground then
						PublishUndergroundTopUpCandidate(map, candidate, candidates)
					end
				end
			end
			return #candidates
		end
		local need_fresh = not sequential_underground and #candidates < target_pool
		for _ = 1, need_fresh and MAX_SAMPLES or 0 do
			if #candidates >= target_pool then break end
			sample_fresh_candidate()
		end
		local function new_strict_selector()
			return NewSectorBalancedCandidateSelector(map, candidates, "effects",
				function(candidate, profile) return repulsion.CanPlace(candidate, profile) end)
		end
		local selector = new_strict_selector()
		local relaxed_selector
		local function take_reachable_candidate(active, profile)
			while active do
				local candidate = active.Take(nil, profile)
				if not candidate or not defer_candidate_reachability then return candidate end
				local reachable, checked = UndergroundCandidateReachable(
					map, candidate, validation_context)
				if checked then reachability_checks = reachability_checks + 1 end
				if reachable then return candidate end
				reachability_rejections = reachability_rejections + 1
			end
			return nil
		end
		local function rebuild_effect_selectors()
			selector = new_strict_selector()
			relaxed_selector = nil
		end
		for _, deposit_type in ipairs(types) do
			local templates = templates_by_type[deposit_type]
			local shortfall = math.max(0,
				target_by_type[deposit_type] - (current_by_type[deposit_type] or 0))
			-- Continue after a failed clone. Take consumes one candidate, so this loop is
			-- bounded by the validated pool even when every clone attempt fails.
			while (added_by_type[deposit_type] or 0) < shortfall do
				local c = take_reachable_candidate(selector, effect_profile)
				local active_selector = c and selector or nil
				local density_fallback = false
				if not c and sequential_underground then
					local strict_sample_limit = math.min(MAX_SAMPLES, candidate_samples + 128)
					while not c and candidate_samples < strict_sample_limit do
						local before = #candidates
						sample_fresh_candidate()
						if #candidates > before then
							rebuild_effect_selectors()
							c = take_reachable_candidate(selector, effect_profile)
							active_selector = c and selector or nil
						end
					end
				end
				if not c and underground then
					relaxed_selector = relaxed_selector or NewWellSpacedUndergroundFallbackSelector(
						map, candidates, "underground effect residual",
						function(candidate) return repulsion.CanPlaceUnique(candidate) end)
					c = take_reachable_candidate(relaxed_selector, effect_profile)
					active_selector = c and relaxed_selector or nil
					density_fallback = c ~= nil
					if not c and sequential_underground then
						local fallback_sample_limit = MAX_SAMPLES
						while not c and candidate_samples < fallback_sample_limit do
							local before = #candidates
							sample_fresh_candidate()
							if #candidates > before then
								rebuild_effect_selectors()
								c = take_reachable_candidate(selector, effect_profile)
								active_selector = c and selector or nil
								if not c then
									relaxed_selector = NewWellSpacedUndergroundFallbackSelector(
										map, candidates, "underground effect sequential residual",
										function(candidate) return repulsion.CanPlaceUnique(candidate) end)
									c = take_reachable_candidate(relaxed_selector, effect_profile)
									active_selector = c and relaxed_selector or nil
									density_fallback = c ~= nil
								end
							end
						end
					end
				end
				if not c then break end
				local template = templates[RandInt(#templates) + 1]
				local tpos = ObjectPos(template)
				if tpos and type(tpos.xy) == "function" then
					local tx, ty = tpos:xy()
					local clone = clone_fn(map, template, point(c.x - tx, c.y - ty, 0))
					if clone and type(clone) == "table" then
						active_selector.Commit(c)
						clone.SuperBigMapEffectTopUp = true
						clone.SuperBigMapEffectTopUpType = deposit_type
						clone.SuperBigMapTopUpIgnoredRubbleWalls = underground
							and rubble_wall_suite_token_by_map[map] ~= nil or nil
						clone.SuperBigMapUndergroundDensityFallback = density_fallback or nil
						clone.SuperBigMapUndergroundWellSpacedFallback = density_fallback or nil
						clone.SuperBigMapUndergroundFallbackSpacingWorld = density_fallback
							and RoundedWorldDistance(c._sbm_selected_fallback_spacing_sq) or nil
						clone.SuperBigMapUndergroundFallbackSpacingHex = density_fallback
							and c._sbm_selected_fallback_hex_distance or nil
						clone.SuperBigMapUndergroundFallbackSpacingRelaxed = density_fallback
							and c._sbm_fallback_spacing_relaxed or nil
						if density_fallback then
							density_fallback_added = density_fallback_added + 1
							fallback_selector_stats = active_selector
								and active_selector.Stats() or fallback_selector_stats
						end
						added_by_type[deposit_type] = (added_by_type[deposit_type] or 0) + 1
						if type(clone.SetPos) == "function" then
							local pt = point(c.x, c.y)
							if type(pt.SetTerrainZ) == "function" then
								local ok, snapped = pcall(pt.SetTerrainZ, pt, map)
								if ok and snapped then pt = snapped end
							end
							pcall(clone.SetPos, clone, pt)
						end
						repulsion.Commit(c, effect_profile, clone)
						clone.is_placed = false
						clone.placed_obj = false
						SetRevealedState(clone, false)
						if not underground then
							local sec = c.sector or SectorAtPoint(map, c.x, c.y)
							if sec and type(sec.RegisterDeposit) == "function" then
								pcall(sec.RegisterDeposit, sec, clone)
							end
						end
					end
				end
			end
		end
		if relaxed_selector then
			local stats = relaxed_selector.Stats()
			if (stats.selected or 0) > 0 then fallback_selector_stats = stats end
		end
		candidate_pool_size, candidate_samples_total = #candidates, candidate_samples
	end)
	local final_by_type, remaining_shortfall = {}, 0
	pcall(map.MapForEach, map, "map", "EffectDepositMarker", function(marker)
		if not marker then return end
		local deposit_type = tostring(marker.deposit_type or "")
		if target_by_type[deposit_type] == nil then return end
		final_by_type[deposit_type] = (final_by_type[deposit_type] or 0) + 1
	end)
	for _, deposit_type in ipairs(types) do
		local final_count = final_by_type[deposit_type] or 0
		remaining_shortfall = remaining_shortfall
			+ math.max(0, (target_by_type[deposit_type] or 0) - final_count)
	end
	SetEnrichmentTopUpStatus(map, "effects", remaining_shortfall == 0, remaining_shortfall, {
		area_factor = area_factor, source_counts = CountMapString(source_by_type),
		target_counts = CountMapString(target_by_type), final_counts = CountMapString(final_by_type),
		added_counts = CountMapString(added_by_type),
		underground_density_fallback_added = density_fallback_added,
		underground_fallback_strategy = fallback_selector_stats and fallback_selector_stats.strategy or "none",
		underground_fallback_eligible_sectors = fallback_selector_stats
			and fallback_selector_stats.eligible_sectors or 0,
		underground_fallback_selected_sectors = fallback_selector_stats
			and fallback_selector_stats.selected_sectors or 0,
		underground_fallback_max_per_sector = fallback_selector_stats
			and fallback_selector_stats.max_additions_to_one_sector or 0,
		underground_fallback_min_spacing_world = fallback_selector_stats
			and fallback_selector_stats.minimum_selected_spacing_world or 0,
		underground_fallback_min_spacing_hex = fallback_selector_stats
			and fallback_selector_stats.minimum_selected_hex_distance or 0,
		underground_fallback_required_spacing_hex = fallback_selector_stats
			and fallback_selector_stats.minimum_required_hex_distance or 0,
		underground_fallback_clearance_rejections = fallback_selector_stats
			and fallback_selector_stats.clearance_rejections or 0,
		underground_fallback_clearance_relaxations = fallback_selector_stats
			and fallback_selector_stats.clearance_relaxations or 0,
		underground_fallback_relaxed_selected = fallback_selector_stats
			and fallback_selector_stats.relaxed_selected or 0,
		candidate_pool_size = candidate_pool_size,
		candidate_samples = candidate_samples_total,
		sequential_placement = sequential_underground,
		deferred_reachability = defer_candidate_reachability,
		reachability_checks = reachability_checks,
		reachability_rejections = reachability_rejections,
		shared_candidate_samples = underground
			and UndergroundTopUpSamplingState(map).samples or 0,
		shared_candidate_sector_samples = underground
			and UndergroundTopUpSamplingState(map).sector_samples or 0,
		shared_candidate_whole_map_samples = underground
			and UndergroundTopUpSamplingState(map).whole_map_samples or 0,
	})
	if cfg().DEBUG_LOADING_TIMINGS == true then
		local print_fn = Global("print")
		if type(print_fn) == "function" then
			local shared_state = underground and UndergroundTopUpSamplingState(map) or nil
			print_fn("[Super Big Map][TopUpCandidatePool] kind=effects"
				.. " valid=" .. tostring(candidate_pool_size)
				.. " sampled=" .. tostring(candidate_samples_total)
				.. " reused=" .. tostring(reused_pool)
				.. " sequential=" .. tostring(sequential_underground)
				.. " shared_samples=" .. tostring(shared_state and shared_state.samples or 0)
				.. " sector_samples=" .. tostring(shared_state and shared_state.sector_samples or 0)
				.. " whole_map_samples=" .. tostring(
					shared_state and shared_state.whole_map_samples or 0)
				.. " shared_published=" .. tostring(
					shared_state and shared_state.published_candidates or 0)
				.. " deferred_reachability=" .. tostring(defer_candidate_reachability)
				.. " reachability_checks=" .. tostring(reachability_checks)
				.. " reachability_rejections=" .. tostring(reachability_rejections)
				.. " remaining=" .. tostring(remaining_shortfall))
		end
	end
end

-- Final cross-pass invariant. Native/native pairs are excluded because a vanilla resource deposit
-- is a cluster of adjacent marker objects. Ordinary top-ups obey vanilla family repulsion. Surface
-- outer-ring anomaly top-ups deliberately use their own rule: no vanilla repulsion, unique hexes,
-- and at least 10 hexes between an outer-ring top-up and every other anomaly. Underground residual
-- completion markers are likewise exempt from family radius only after the strict selector is
-- exhausted; duplicate-hex rejection remains universal. Their six-hex separation is a maximin
-- preference: if impossible, density wins and the farthest valid closer position is retained.
-- This runs after position corrections.
function DepositRules.AuditTopUpVanillaRepulsion(map, reason)
	map = map or Global("CurrentMap")
	local point_fn = Global("point")
	local world_to_hex = Global("WorldToHex")
	if not map or type(map.MapForEach) ~= "function"
		or type(point_fn) ~= "function" or type(world_to_hex) ~= "function" then
		return false, { error = "map/point/WorldToHex unavailable" }
	end
	local function is_topup(marker)
		return marker and (marker.SuperBigMapResourceTopUp == true
			or marker.SuperBigMapAnomalyTopUp == true
			or marker.SuperBigMapEffectTopUp == true)
	end
	local entries = {}
	local underground = IsUndergroundMap(map)
	local MIN_OUTER_RING_ANOMALY_HEX_DISTANCE = 10
	local stats = {
		reason = tostring(reason or "final"), markers = 0, topups = 0,
		checked_pairs = 0, native_pairs_skipped = 0, missing_positions = 0,
		missing_topup_profiles = 0, duplicate_hex_pairs = 0, repulsion_violations = 0,
		first_repulsion_violation = "",
		outer_ring_spacing_violations = 0,
		underground_density_fallback_topups = 0, density_fallback_pairs_skipped = 0,
		underground_well_spaced_fallback_topups = 0,
		underground_fallback_relaxed_topups = 0,
		underground_fallback_strategy_failures = 0,
		underground_fallback_sectors = 0, underground_fallback_max_per_sector = 0,
		underground_fallback_min_selected_spacing_world = 0,
		underground_fallback_actual_min_spacing_world = 0,
		underground_fallback_actual_min_hex_distance = 0,
		underground_fallback_required_min_hex_distance =
			UndergroundFallbackMinimumHexDistance(),
		underground_fallback_spacing_violations = 0,
		first_underground_fallback_spacing_violation = "",
		density_failures = 0, density_status = "", resource_shortfall = 0,
		anomaly_shortfall = 0, effect_shortfall = 0,
		resource_ignored_rubble_walls = 0, wall_aware_shared_candidates = 0,
	}
	do
		local density = map.SuperBigMapEnrichmentTopUpStatus
		local status = {}
		for _, kind in ipairs({ "resources", "anomalies", "effects" }) do
			local entry = type(density) == "table" and density[kind] or nil
			local complete = type(entry) == "table" and entry.complete == true
			status[#status + 1] = kind .. "=" .. tostring(complete)
			if not complete then stats.density_failures = stats.density_failures + 1 end
			if kind == "resources" and type(entry) == "table" then
				stats.resource_shortfall = tonumber(entry.remaining_shortfall) or 0
				stats.resource_ignored_rubble_walls = tonumber(entry.ignored_rubble_walls) or 0
				stats.wall_aware_shared_candidates =
					tonumber(entry.wall_aware_shared_candidates) or 0
			elseif kind == "anomalies" and type(entry) == "table" then
				stats.anomaly_shortfall = tonumber(entry.remaining_shortfall) or 0
			elseif kind == "effects" and type(entry) == "table" then
				stats.effect_shortfall = tonumber(entry.remaining_shortfall) or 0
			end
		end
		stats.density_status = table.concat(status, " ")
	end
	local fallback_by_sector, fallback_selected_spacing_min = {}, nil
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not IsEnrichmentMarker(marker) then return end
		local topup = is_topup(marker)
		local pos = ObjectPos(marker)
		if not (pos and type(pos.xy) == "function") then
			if topup then stats.missing_positions = stats.missing_positions + 1 end
			return
		end
		local x, y = pos:xy()
		if type(x) ~= "number" or type(y) ~= "number" then
			if topup then stats.missing_positions = stats.missing_positions + 1 end
			return
		end
		local outer_ring_topup = not underground
			and marker.SuperBigMapAnomalyTopUp == true
			and marker.SuperBigMapOuterRingRedistributed == true
		local inner_ring_fallback = not underground
			and marker.SuperBigMapAnomalyTopUp == true
			and marker.SuperBigMapInnerRingFallback == true
		local density_fallback = underground
			and marker.SuperBigMapUndergroundDensityFallback == true
		local well_spaced_fallback = density_fallback
			and marker.SuperBigMapUndergroundWellSpacedFallback == true
		local profile = VanillaRepulsionProfileForMarker(map, marker)
		if topup and not outer_ring_topup and not profile then
			stats.missing_topup_profiles = stats.missing_topup_profiles + 1
		end
		local ok_hex, q, r = pcall(world_to_hex, point_fn(x, y))
		entries[#entries + 1] = {
			marker = marker, topup = topup, outer_ring_topup = outer_ring_topup,
			inner_ring_fallback = inner_ring_fallback,
			density_fallback = density_fallback,
			well_spaced_fallback = well_spaced_fallback,
			anomaly = IsAnomalyMarker(marker),
			profile = profile, x = x, y = y,
			q = ok_hex and type(q) == "number" and q or nil,
			r = ok_hex and type(r) == "number" and r or nil,
			hex = ok_hex and type(q) == "number" and type(r) == "number"
				and (tostring(q) .. ":" .. tostring(r)) or nil,
		}
		if topup then
			stats.topups = stats.topups + 1
			if density_fallback then
				stats.underground_density_fallback_topups =
					stats.underground_density_fallback_topups + 1
				if marker.SuperBigMapUndergroundFallbackSpacingRelaxed == true then
					stats.underground_fallback_relaxed_topups =
						stats.underground_fallback_relaxed_topups + 1
				end
				if well_spaced_fallback then
					stats.underground_well_spaced_fallback_topups =
						stats.underground_well_spaced_fallback_topups + 1
				else
					stats.underground_fallback_strategy_failures =
						stats.underground_fallback_strategy_failures + 1
				end
				local sector_key = EnrichmentSectorKey(SectorAtPoint(map, x, y))
				if sector_key then
					fallback_by_sector[sector_key] = (fallback_by_sector[sector_key] or 0) + 1
				end
				local selected_spacing = tonumber(marker.SuperBigMapUndergroundFallbackSpacingWorld)
				if selected_spacing and selected_spacing > 0 then
					fallback_selected_spacing_min = fallback_selected_spacing_min == nil
						and selected_spacing or math.min(fallback_selected_spacing_min, selected_spacing)
				end
			end
		end
	end)
	stats.markers = #entries
	for _, count in pairs(fallback_by_sector) do
		stats.underground_fallback_sectors = stats.underground_fallback_sectors + 1
		stats.underground_fallback_max_per_sector =
			math.max(stats.underground_fallback_max_per_sector, count)
	end
	stats.underground_fallback_min_selected_spacing_world = fallback_selected_spacing_min or 0
	local fallback_actual_min_spacing_sq, fallback_actual_min_hex_distance
	for i = 1, #entries - 1 do
		local a = entries[i]
		for j = i + 1, #entries do
			local b = entries[j]
			if not a.topup and not b.topup then
				stats.native_pairs_skipped = stats.native_pairs_skipped + 1
			else
				stats.checked_pairs = stats.checked_pairs + 1
				local duplicate_hex = a.hex and b.hex and a.hex == b.hex
				if duplicate_hex then stats.duplicate_hex_pairs = stats.duplicate_hex_pairs + 1 end
				local has_outer_ring_topup = a.outer_ring_topup or b.outer_ring_topup
				local has_density_fallback = a.density_fallback or b.density_fallback
				if a.well_spaced_fallback or b.well_spaced_fallback then
					local dx, dy = a.x - b.x, a.y - b.y
					local distance_sq = dx * dx + dy * dy
					fallback_actual_min_spacing_sq = fallback_actual_min_spacing_sq == nil
						and distance_sq or math.min(fallback_actual_min_spacing_sq, distance_sq)
					if type(a.q) == "number" and type(a.r) == "number"
						and type(b.q) == "number" and type(b.r) == "number" then
						local dq, dr = a.q - b.q, a.r - b.r
						local hex_distance = math.max(math.abs(dq), math.abs(dr), math.abs(dq + dr))
						fallback_actual_min_hex_distance = fallback_actual_min_hex_distance == nil
							and hex_distance or math.min(fallback_actual_min_hex_distance, hex_distance)
						if hex_distance < stats.underground_fallback_required_min_hex_distance then
							stats.underground_fallback_spacing_violations =
								stats.underground_fallback_spacing_violations + 1
							if stats.first_underground_fallback_spacing_violation == "" then
								stats.first_underground_fallback_spacing_violation = table.concat({
									tostring(a.marker and a.marker.class or "?"),
									tostring(a.hex),
									tostring(b.marker and b.marker.class or "?"),
									tostring(b.hex),
									"preferred=" .. tostring(
										stats.underground_fallback_required_min_hex_distance),
									"actual=" .. tostring(hex_distance),
								}, "|")
							end
						end
					end
				end
				if has_outer_ring_topup then
					if ((a.outer_ring_topup and b.anomaly) or (b.outer_ring_topup and a.anomaly))
						and type(a.q) == "number" and type(a.r) == "number"
						and type(b.q) == "number" and type(b.r) == "number" then
						local dq, dr = a.q - b.q, a.r - b.r
						local hex_distance = math.max(math.abs(dq), math.abs(dr), math.abs(dq + dr))
						if hex_distance < MIN_OUTER_RING_ANOMALY_HEX_DISTANCE then
							stats.outer_ring_spacing_violations =
								stats.outer_ring_spacing_violations + 1
						end
					end
				end
				-- An interior fallback is a vanilla placement even when its pair is an outer-ring
				-- top-up. Outer/outer and outer/native pairs remain exempt from vanilla repulsion.
				if has_density_fallback then
					stats.density_fallback_pairs_skipped = stats.density_fallback_pairs_skipped + 1
				elseif not has_outer_ring_topup or a.inner_ring_fallback or b.inner_ring_fallback then
					local required = PairRepulsionRadius(a.profile, b.profile)
					local dx, dy = a.x - b.x, a.y - b.y
					local distance_sq = dx * dx + dy * dy
					local repulsion_violation = type(required) == "number"
						and distance_sq <= required * required
					if repulsion_violation then
						stats.repulsion_violations = stats.repulsion_violations + 1
						if stats.first_repulsion_violation == "" then
							stats.first_repulsion_violation = table.concat({
								tostring(a.marker and a.marker.class or "?"),
								a.topup and "topup" or "native",
								tostring(a.hex),
								tostring(b.marker and b.marker.class or "?"),
								b.topup and "topup" or "native",
								tostring(b.hex),
								"required=" .. tostring(required),
								"actual=" .. tostring(RoundedWorldDistance(distance_sq)),
							}, "|")
						end
					end
				end
			end
		end
	end
	stats.underground_fallback_actual_min_spacing_world =
		RoundedWorldDistance(fallback_actual_min_spacing_sq)
	stats.underground_fallback_actual_min_hex_distance =
		fallback_actual_min_hex_distance or 0
	local ok = stats.density_failures == 0
		and stats.missing_positions == 0 and stats.missing_topup_profiles == 0
		and stats.duplicate_hex_pairs == 0 and stats.repulsion_violations == 0
		and stats.outer_ring_spacing_violations == 0
		and stats.underground_fallback_strategy_failures == 0
	-- Underground fallback spacing is a maximin preference, not a hard density gate. A closer
	-- farthest-valid candidate is retained and reported when terrain cannot satisfy six hexes.
	return ok, stats
end

-- Final invariant check for the surface density suite. Only markers created by the three top-up
-- passes are inspected: vanilla/generated enrichments remain untouched. Every top-up must be on
-- passable, flat, engine-buildable, unobstructed terrain. Custom anomaly top-ups must be in the
-- final outer ring; explicitly flagged vanilla fallbacks must be inside it. Anomalies occupy unique
-- hexes, resources/effects remain outside the reserved outer band, and only custom outer placements
-- are limited to one anomaly per sector.
function DepositRules.AuditSurfaceTopUpRingExclusivity(map)
	if not ExpansionStepEnabled(3) or not ExpansionStepEnabled(21) then return true end
	map = map or Global("CurrentMap")
	if not map or IsUndergroundMap(map) or type(map.MapForEach) ~= "function" then return true end
	local ring_sectors = math.max(0, math.floor(cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3))
	if ring_sectors <= 0 then return true end
	local stats = {
		anomaly_topups = 0, anomaly_inner_fallback = 0,
		resource_topups = 0, effect_topups = 0,
		anomaly_outside_ring = 0, non_anomaly_inside_ring = 0, missing_position = 0,
		anomaly_fallback_inside_ring = 0,
		anomaly_unreachable = 0, anomaly_unbuildable = 0, anomaly_obstructed = 0, anomaly_overlap = 0,
		anomaly_sector_overflow = 0,
		anomaly_not_mountain_base = 0, resource_obstructed = 0,
		topup_uneven = 0, resource_uneven = 0, anomaly_uneven = 0, effect_uneven = 0,
		effect_unbuildable = 0, effect_obstructed = 0,
	}
	local violation_count = 0
	local point_fn = Global("point")
	local world_to_hex = Global("WorldToHex")
	local validation_context = NewDepositValidationContext(map)
	local ring_context = NewFinalOuterSectorRingContext(map)
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
	local anomaly_topups_by_sector = {}
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
	local function inspect(marker, family)
		local pos = marker and ObjectPos(marker)
		local x, y
		if pos and type(pos.xy) == "function" then x, y = pos:xy() end
		local has_position = type(x) == "number" and type(y) == "number"
		local pt = has_position and pos or nil
		local sector = has_position and SectorAtPoint(map, x, y) or nil
		local in_ring = has_position and IsInFinalOuterSectorRing(
			map, x, y, ring_sectors, sector, ring_context) or false
		local inner_fallback = family == "anomaly"
			and marker.SuperBigMapInnerRingFallback == true
		local reachable = has_position and PassableAt(map, pt, validation_context) or false
		local flatness = has_position and FlatnessAt(map, pt, validation_context) or 0
		local buildable, q, r = false, nil, nil
		if has_position then
			buildable, q, r = IsBuildableAt(map, pt, true, validation_context)
		end
		local even_terrain = reachable
			and flatness >= validation_context.flatness_minimum and buildable == true
		local unobstructed = has_position
			and IsUnobstructedAt(map, pt, true, validation_context) or false
		local valley_score = family == "anomaly" and has_position and ValleyScore(map, pt) or 0
		local hex_key = type(q) == "number" and type(r) == "number"
			and (tostring(q) .. ":" .. tostring(r))
			or (has_position and audit_hex_key(x, y) or nil)
		local overlap = family == "anomaly" and hex_key and occupied_anomaly_hexes[hex_key] == true or false
		if family == "anomaly" and hex_key then occupied_anomaly_hexes[hex_key] = true end
		if family == "anomaly" and has_position and not inner_fallback then
			if sector then
				anomaly_topups_by_sector[sector] = (anomaly_topups_by_sector[sector] or 0) + 1
			end
		end
		if family == "anomaly" and not buildable then
			stats.anomaly_unbuildable = stats.anomaly_unbuildable + 1
		end
		if family == "anomaly" and valley_score <= 0 then
			stats.anomaly_not_mountain_base = stats.anomaly_not_mountain_base + 1
		end
		if has_position and not even_terrain then
			stats.topup_uneven = stats.topup_uneven + 1
			local family_key = family .. "_uneven"
			stats[family_key] = (stats[family_key] or 0) + 1
		end
		local violation
		if not has_position then
			stats.missing_position = stats.missing_position + 1
			violation = "missing_position"
		elseif family == "anomaly" and inner_fallback and in_ring then
			stats.anomaly_fallback_inside_ring = stats.anomaly_fallback_inside_ring + 1
			violation = "anomaly_vanilla_fallback_inside_outer_ring"
		elseif family == "anomaly" and not inner_fallback and not in_ring then
			stats.anomaly_outside_ring = stats.anomaly_outside_ring + 1
			violation = "anomaly_topup_outside_final_ring"
		elseif not even_terrain then
			violation = family .. "_topup_not_flat_buildable_terrain"
		elseif family == "anomaly" and not reachable then
			stats.anomaly_unreachable = stats.anomaly_unreachable + 1
			violation = "anomaly_topup_not_passable"
		elseif not unobstructed then
			local obstruction_key = family .. "_obstructed"
			stats[obstruction_key] = (stats[obstruction_key] or 0) + 1
			violation = family .. "_topup_obstructed"
		elseif family == "anomaly" and overlap then
			stats.anomaly_overlap = stats.anomaly_overlap + 1
			violation = "anomaly_topup_hex_overlap"
		elseif family ~= "anomaly" and in_ring then
			stats.non_anomaly_inside_ring = stats.non_anomaly_inside_ring + 1
			violation = family .. "_topup_inside_reserved_ring"
		elseif family == "effect" and not buildable then
			stats.effect_unbuildable = stats.effect_unbuildable + 1
			violation = "effect_topup_unbuildable"
		end
		if violation then violation_count = violation_count + 1 end
	end
	pcall(map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(marker)
		if marker and marker.SuperBigMapAnomalyTopUp then
			stats.anomaly_topups = stats.anomaly_topups + 1
			if marker.SuperBigMapInnerRingFallback == true then
				stats.anomaly_inner_fallback = stats.anomaly_inner_fallback + 1
			end
			inspect(marker, "anomaly")
		end
	end)
	for _, count in pairs(anomaly_topups_by_sector) do
		if count > 1 then
			local excess = count - 1
			stats.anomaly_sector_overflow = stats.anomaly_sector_overflow + excess
			violation_count = violation_count + excess
		end
	end
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if marker and marker.SuperBigMapResourceTopUp then
			stats.resource_topups = stats.resource_topups + 1
			inspect(marker, "resource")
		end
	end)
	pcall(map.MapForEach, map, "map", "EffectDepositMarker", function(marker)
		if marker and marker.SuperBigMapEffectTopUp then
			stats.effect_topups = stats.effect_topups + 1
			inspect(marker, "effect")
		end
	end)
	stats.violations = violation_count
	return violation_count == 0, stats
end

function DepositRules.PrepareUndergroundReachability(map)
	if not IsUndergroundMap(map) then return true end
	topup_candidate_pool_by_map[map] = nil
	underground_reachability_by_map[map] = nil
	local state = BuildUndergroundReachability(map)
	return state and state.available == true, state
end

-- Vanilla buried wonders create their rare anomaly through SpawnsAnomalyOnCityInit. On an
-- expanded underground map the native FindUnobstructedDepositPos search can escape hundreds of
-- hexes from the wonder: the stretched wonder footprint is much larger than the unscaled search
-- assumptions, while the flat black border can still look acceptable to part of the native
-- search. These markers are neither density top-ups nor transformed native markers, so the old
-- final reachability pass deliberately skipped them.
--
-- Keep the vanilla ownership/scenario marker, but repair only its coordinate. The replacement is
-- the nearest free playable cave-floor hex around its own wonder. Unlike density top-ups, it may
-- occupy its own wonder's reserved footprint: vanilla deliberately starts it there. Entrance
-- connectivity is recorded but is not a veto because vanilla cave systems are separated by
-- collapsed tunnels and become mutually reachable later. A finite local bound prevents a rare
-- anomaly from being silently scattered into the black rock/void elsewhere on the map again.
local DEFERRED_WONDER_ANOMALY_MAX_LOCAL_RADIUS = 160

local function HexDistance(q1, r1, q2, r2)
	if type(q1) ~= "number" or type(r1) ~= "number"
		or type(q2) ~= "number" or type(r2) ~= "number" then return nil end
	local dq, dr = q2 - q1, r2 - r1
	return (math.abs(dq) + math.abs(dr) + math.abs(dq + dr)) / 2
end

local function ForEachHexInRing(center_q, center_r, radius, callback)
	if radius == 0 then return callback(center_q, center_r) end
	-- Axial directions. Start at the south-west corner, then walk the six ring sides.
	local directions = {
		{ 1, 0 }, { 1, -1 }, { 0, -1 },
		{ -1, 0 }, { -1, 1 }, { 0, 1 },
	}
	local q, r = center_q - radius, center_r + radius
	for side = 1, 6 do
		local direction = directions[side]
		for _ = 1, radius do
			local result = callback(q, r)
			if result ~= nil then return result end
			q, r = q + direction[1], r + direction[2]
		end
	end
end

function DepositRules.EnsureDeferredUndergroundWonderAnomaliesReachable(map, repair_invalid)
	map = map or Global("CurrentMap")
	local point_fn = Global("point")
	local world_to_hex = Global("WorldToHex")
	local hex_to_world = Global("HexToWorld")
	if not IsUndergroundMap(map) or type(map.MapForEach) ~= "function"
		or type(point_fn) ~= "function" or type(world_to_hex) ~= "function"
		or type(hex_to_world) ~= "function" then
		return false, { error = "underground map/hex APIs unavailable" }
	end
	local reachability = BuildUndergroundReachability(map)
	if not reachability or reachability.available ~= true then
		return false, { error = "entrance connectivity unavailable" }
	end

	local markers = {}
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if marker and marker.SuperBigMapDeferredWonderAnomaly == true
			and IsKindOfSafe(marker, "SubsurfaceSpecialAnomalyMarker") then
			markers[#markers + 1] = marker
		end
	end)
	local stats = {
		markers = #markers, checked = 0, valid = 0, invalid = 0, moved = 0,
		unresolved = 0, unreachable = 0, terrain_invalid = 0, too_far = 0,
		overlaps = 0, candidates_tested = 0, connectivity_checks = 0,
		entrance_disconnected = 0, terrain_fallbacks = 0,
		candidate_out_of_bounds = 0, candidate_badge_occupied = 0,
		candidate_reserved = 0, candidate_unbuildable = 0,
		candidate_impassable = 0, candidate_nonflat = 0,
		candidate_terrain_valid = 0, candidate_obstructed = 0,
		candidate_strict_valid = 0,
		max_search_radius = DEFERRED_WONDER_ANOMALY_MAX_LOCAL_RADIUS,
	}
	local details, ring_diagnostics = {}, {}
	local validation_context = SharedTopUpValidationContext(map)
	-- Resource top-ups must stay out of every reserved wonder footprint. A wonder's own rare
	-- anomaly is different: vanilla starts it at the wonder and searches the local footprint.
	-- Retain every cached native API from the shared context but remove only that reservation.
	local wonder_validation_context = {}
	for key, value in pairs(validation_context) do
		wonder_validation_context[key] = value
	end
	wonder_validation_context.wonder_reserved_hexes = {}
	local reserved = UndergroundWonderReservedHexes(map)
	local map_w, map_h = MapWorldSize(map)
	local get_sector = Global("GetMapSectorXY")
	local done_object = Global("DoneObject")
	local is_valid = Global("IsValid")
	local diagnostic_radii = {
		[0] = true, [1] = true, [2] = true, [4] = true, [8] = true,
		[16] = true, [24] = true, [32] = true, [48] = true, [64] = true,
		[96] = true, [128] = true, [160] = true,
	}

	local function raw_buildable_z(q, r)
		local buildable = wonder_validation_context.buildable
		local get_z = wonder_validation_context.buildable_get_z
		if not buildable or type(get_z) ~= "function"
			or type(q) ~= "number" or type(r) ~= "number" then return nil end
		local ok_z, z = pcall(get_z, buildable, q, r)
		return ok_z and z or nil
	end

	local function terrain_diagnostic(pt, include_obstruction)
		local buildable, q, r = IsBuildableAt(
			map, pt, true, wonder_validation_context)
		local passable = PassableAt(map, pt, wonder_validation_context)
		local flatness = FlatnessAt(map, pt, wonder_validation_context) or 0
		local flat_ok = flatness >= wonder_validation_context.flatness_minimum
		local unobstructed
		if include_obstruction == true then
			unobstructed = IsUnobstructedAt(
				map, pt, true, wonder_validation_context) == true
		end
		return {
			buildable = buildable == true, q = q, r = r,
			buildable_z = raw_buildable_z(q, r),
			unbuildable_z = wonder_validation_context.build_unbuildable_z,
			passable = passable == true, flatness = flatness, flat_ok = flat_ok,
			unobstructed = unobstructed,
		}
	end

	local function point_xy_text(pt)
		if pt and type(pt.xy) == "function" then
			local ok_xy, x, y = pcall(pt.xy, pt)
			if ok_xy then return tostring(x) .. "," .. tostring(y) end
		end
		return "?,?"
	end

	local function state_diagnostic_text(state)
		local diagnostic = state.diagnostic or {}
		return "marker_world=" .. point_xy_text(state.marker_pos)
			.. ":spawner_world=" .. point_xy_text(state.spawner_pos)
			.. ":marker_hex=" .. tostring(state.marker_q) .. "," .. tostring(state.marker_r)
			.. ":spawner_hex=" .. tostring(state.spawner_q) .. "," .. tostring(state.spawner_r)
			.. ":distance=" .. tostring(state.distance)
			.. ":terrain_ok=" .. tostring(state.terrain_ok)
			.. ":buildable=" .. tostring(diagnostic.buildable)
			.. ":buildable_z=" .. tostring(diagnostic.buildable_z)
			.. ":unbuildable_z=" .. tostring(diagnostic.unbuildable_z)
			.. ":passable=" .. tostring(diagnostic.passable)
			.. ":flatness=" .. tostring(diagnostic.flatness)
			.. ":flat_min=" .. tostring(wonder_validation_context.flatness_minimum)
			.. ":unobstructed=" .. tostring(diagnostic.unobstructed)
			.. ":reserved=" .. tostring(state.reserved_overlap)
			.. ":badge_overlap=" .. tostring(state.overlap)
			.. ":entrance_connected=" .. tostring(state.reachable)
	end

	local function marker_state(marker, occupied)
		local spawner = marker and marker.spawner
		local marker_pos, spawner_pos = ObjectPos(marker), ObjectPos(spawner)
		if not marker_pos or not spawner_pos then
			return false, { reason = "missing marker/spawner position" }
		end
		local ok_marker, marker_q, marker_r = pcall(world_to_hex, marker_pos)
		local ok_spawner, spawner_q, spawner_r = pcall(world_to_hex, spawner_pos)
		if not ok_marker or not ok_spawner or type(marker_q) ~= "number"
			or type(marker_r) ~= "number" or type(spawner_q) ~= "number"
			or type(spawner_r) ~= "number" then
			return false, { reason = "marker/spawner hex unavailable" }
		end
		local terrain_ok, _, _, _, q, r = EvaluateDepositTerrain(
			map, marker_pos, wonder_validation_context, true)
		local unobstructed = terrain_ok and IsUnobstructedAt(
			map, marker_pos, true, wonder_validation_context) == true
		local base_ok = terrain_ok and unobstructed
		-- Underground cave systems are intentionally separated by collapsed tunnels. A rare
		-- anomaly next to a wonder in another cavern is vanilla-correct and becomes accessible
		-- when that tunnel is opened; entrance connectivity is therefore diagnostic, not a
		-- placement veto. Terrain validity prevents the actual bug: a marker in black rock/void.
		local reachable = IsReachableFromUndergroundEntrance(
			map, marker_pos, q or marker_q, r or marker_r) == true
		local distance = HexDistance(spawner_q, spawner_r, marker_q, marker_r)
		local local_ok = type(distance) == "number"
			and distance <= DEFERRED_WONDER_ANOMALY_MAX_LOCAL_RADIUS
		local overlap = BadgeHexOccupied(occupied, marker_q, marker_r)
		local reserved_overlap = type(reserved) == "table"
			and reserved[CoordinateHexKey(marker_q, marker_r)] == true
		local accepted_terrain_fallback =
			marker.SuperBigMapDeferredWonderAnomalyLocalTerrainFallback == true
		local diagnostic = terrain_diagnostic(marker_pos, true)
		return terrain_ok and (base_ok or accepted_terrain_fallback)
			and local_ok and not overlap, {
			marker_pos = marker_pos, spawner_pos = spawner_pos,
			marker_q = marker_q, marker_r = marker_r,
			spawner_q = spawner_q, spawner_r = spawner_r,
			distance = distance, terrain_ok = terrain_ok, base_ok = base_ok,
			unobstructed = unobstructed, reachable = reachable,
			local_ok = local_ok, overlap = overlap, reserved_overlap = reserved_overlap,
			accepted_terrain_fallback = accepted_terrain_fallback,
			diagnostic = diagnostic,
		}
	end

	local function find_local_candidate(marker, state, occupied)
		local diagnostic_class = tostring(marker.SuperBigMapDeferredWonderClass
			or marker.spawner and marker.spawner.class or "?")
		local spawner_sector
		if type(get_sector) == "function" and map.City and state.spawner_pos
			and type(state.spawner_pos.xy) == "function" then
			local sx, sy = state.spawner_pos:xy()
			local ok_sector, sector = pcall(get_sector, map.City, sx, sy)
			if ok_sector then spawner_sector = sector end
		end
		local first_other_sector, first_terrain_fallback
		for radius = 0, DEFERRED_WONDER_ANOMALY_MAX_LOCAL_RADIUS do
			local ring = {
				radius = radius, tested = 0, out_of_bounds = 0, badge_occupied = 0,
				reserved = 0, unbuildable = 0, impassable = 0, nonflat = 0,
				terrain_valid = 0, obstructed = 0, strict_valid = 0,
			}
			local same_sector_candidates = {}
			local other_sector_candidates = {}
			local terrain_fallback_candidates = {}
			ForEachHexInRing(state.spawner_q, state.spawner_r, radius, function(q, r)
				if type(reserved) == "table" and reserved[CoordinateHexKey(q, r)] == true then
					ring.reserved = ring.reserved + 1
					stats.candidate_reserved = stats.candidate_reserved + 1
				end
				if BadgeHexOccupied(occupied, q, r) then
					ring.badge_occupied = ring.badge_occupied + 1
					stats.candidate_badge_occupied = stats.candidate_badge_occupied + 1
					return
				end
				local ok_world, x, y = pcall(hex_to_world, q, r)
				if not ok_world or type(x) ~= "number" or type(y) ~= "number"
					or (type(map_w) == "number" and (x < 0 or x >= map_w))
					or (type(map_h) == "number" and (y < 0 or y >= map_h)) then
					ring.out_of_bounds = ring.out_of_bounds + 1
					stats.candidate_out_of_bounds = stats.candidate_out_of_bounds + 1
					return
				end
				stats.candidates_tested = stats.candidates_tested + 1
				ring.tested = ring.tested + 1
				local candidate_point = point_fn(x, y)
				local terrain_ok = EvaluateDepositTerrain(
					map, candidate_point, wonder_validation_context, true)
				if not terrain_ok then
					local diagnostic = terrain_diagnostic(candidate_point, false)
					if not diagnostic.buildable then
						ring.unbuildable = ring.unbuildable + 1
						stats.candidate_unbuildable = stats.candidate_unbuildable + 1
					elseif not diagnostic.passable then
						ring.impassable = ring.impassable + 1
						stats.candidate_impassable = stats.candidate_impassable + 1
					elseif not diagnostic.flat_ok then
						ring.nonflat = ring.nonflat + 1
						stats.candidate_nonflat = stats.candidate_nonflat + 1
					end
					return
				end
				ring.terrain_valid = ring.terrain_valid + 1
				stats.candidate_terrain_valid = stats.candidate_terrain_valid + 1
				local unobstructed = IsUnobstructedAt(
					map, candidate_point, true, wonder_validation_context) == true
				if unobstructed then
					ring.strict_valid = ring.strict_valid + 1
					stats.candidate_strict_valid = stats.candidate_strict_valid + 1
				else
					ring.obstructed = ring.obstructed + 1
					stats.candidate_obstructed = stats.candidate_obstructed + 1
				end
				if type(candidate_point.SetTerrainZ) == "function" then
					local ok_z, snapped = pcall(candidate_point.SetTerrainZ,
						candidate_point, map)
					if ok_z and snapped then candidate_point = snapped end
				end
				local candidate_sector
				if type(get_sector) == "function" and map.City then
					local ok_sector, sector = pcall(get_sector, map.City, x, y)
					if ok_sector then candidate_sector = sector end
				end
				local candidate = {
					point = candidate_point, x = x, y = y, q = q, r = r,
					radius = radius, sector = candidate_sector,
					terrain_fallback = not unobstructed,
				}
				if not unobstructed then
					terrain_fallback_candidates[#terrain_fallback_candidates + 1] = candidate
				elseif not spawner_sector or candidate_sector == spawner_sector then
					same_sector_candidates[#same_sector_candidates + 1] = candidate
				else
					other_sector_candidates[#other_sector_candidates + 1] = candidate
				end
			end)
			if diagnostic_radii[radius] then
				ring_diagnostics[#ring_diagnostics + 1] = diagnostic_class
					.. ":r" .. tostring(radius)
					.. "{tested=" .. tostring(ring.tested)
					.. ",out=" .. tostring(ring.out_of_bounds)
					.. ",occupied=" .. tostring(ring.badge_occupied)
					.. ",reserved=" .. tostring(ring.reserved)
					.. ",unbuildable=" .. tostring(ring.unbuildable)
					.. ",impassable=" .. tostring(ring.impassable)
					.. ",nonflat=" .. tostring(ring.nonflat)
					.. ",terrain=" .. tostring(ring.terrain_valid)
					.. ",obstructed=" .. tostring(ring.obstructed)
					.. ",strict=" .. tostring(ring.strict_valid) .. "}"
			end
			if #same_sector_candidates > 0 then
				return same_sector_candidates[RandInt(#same_sector_candidates) + 1]
			end
			if not first_other_sector and #other_sector_candidates > 0 then
				first_other_sector = other_sector_candidates[
					RandInt(#other_sector_candidates) + 1]
			end
			if not first_terrain_fallback and #terrain_fallback_candidates > 0 then
				first_terrain_fallback = terrain_fallback_candidates[
					RandInt(#terrain_fallback_candidates) + 1]
			end
		end
		return first_other_sector or first_terrain_fallback
	end

	for _, marker in ipairs(markers) do
		stats.checked = stats.checked + 1
		local occupied = BuildBadgeOccupancy(map, marker, marker.placed_obj, false)
		local valid, state = marker_state(marker, occupied)
		local class_name = tostring(marker.SuperBigMapDeferredWonderClass
			or marker.spawner and marker.spawner.class or "?")
		if state.reachable ~= true then
			stats.entrance_disconnected = stats.entrance_disconnected + 1
		end
		if valid then
			stats.valid = stats.valid + 1
			if state.accepted_terrain_fallback == true then
				stats.terrain_fallbacks = stats.terrain_fallbacks + 1
			end
			marker.SuperBigMapDeferredWonderAnomalyReachabilityValidated = true
			marker.SuperBigMapDeferredWonderAnomalyDistanceHex = state.distance
			details[#details + 1] = class_name .. "=valid:"
				.. state_diagnostic_text(state)
		else
			stats.invalid = stats.invalid + 1
			if state.terrain_ok ~= true then
				stats.unreachable = stats.unreachable + 1
				stats.terrain_invalid = stats.terrain_invalid + 1
			end
			if state.local_ok ~= true then stats.too_far = stats.too_far + 1 end
			if state.overlap == true then stats.overlaps = stats.overlaps + 1 end
			local candidate = repair_invalid == true and state.spawner_q
				and find_local_candidate(marker, state, occupied) or nil
			if not candidate or type(marker.SetPos) ~= "function" then
				stats.unresolved = stats.unresolved + 1
				marker.SuperBigMapDeferredWonderAnomalyReachabilityValidated = nil
				details[#details + 1] = class_name .. "=unresolved:"
					.. state_diagnostic_text(state)
			else
				local old_pos = state.marker_pos
				local old_x, old_y = old_pos:xy()
				local old_sector = SectorAtPoint(map, old_x, old_y)
				local placed = marker.placed_obj
				local placed_valid = placed
					and (type(is_valid) ~= "function" or SafeCall(is_valid, placed) == true)
				if placed_valid and type(done_object) == "function" then pcall(done_object, placed) end
				marker.placed_obj = false
				marker.is_placed = false
				SetRevealedState(marker, false)
				marker.SuperBigMapDeferredWonderAnomalyLocalTerrainFallback =
					candidate.terrain_fallback == true and true or nil
				local moved = MoveBadgeMarker(marker, map, candidate, old_sector)
				if moved and not old_sector and candidate.sector
					and type(candidate.sector.RegisterDeposit) == "function" then
					pcall(candidate.sector.RegisterDeposit, candidate.sector, marker)
				end
				local final_occupied = BuildBadgeOccupancy(map, marker, nil, false)
				local post_valid, post_state = marker_state(marker, final_occupied)
				if moved and post_valid then
					stats.moved = stats.moved + 1
					stats.valid = stats.valid + 1
					marker.SuperBigMapDeferredWonderAnomalyReachabilityValidated = true
					marker.SuperBigMapDeferredWonderAnomalyReachabilityRelocated = true
					marker.SuperBigMapDeferredWonderAnomalyOriginalX = old_x
					marker.SuperBigMapDeferredWonderAnomalyOriginalY = old_y
					marker.SuperBigMapDeferredWonderAnomalyDistanceHex = post_state.distance
					marker.SuperBigMapDeferredWonderAnomalySearchRadius = candidate.radius
					if candidate.terrain_fallback == true then
						stats.terrain_fallbacks = stats.terrain_fallbacks + 1
					end
					StampResolvedBadgeHex(marker, candidate.q, candidate.r)
					details[#details + 1] = class_name .. "=moved@"
						.. tostring(state.marker_q) .. "," .. tostring(state.marker_r)
						.. "->" .. tostring(candidate.q) .. "," .. tostring(candidate.r)
						.. ":distance=" .. tostring(post_state.distance)
				else
					stats.unresolved = stats.unresolved + 1
					marker.SuperBigMapDeferredWonderAnomalyReachabilityValidated = nil
					details[#details + 1] = class_name .. "=postmove_failed"
				end
			end
		end
	end
	stats.details = table.concat(details, ";")
	stats.ring_diagnostics = table.concat(ring_diagnostics, ";")
	stats.connectivity_cache_checks = reachability.checks
	stats.connectivity_cache_rejected = reachability.rejected
	stats.connectivity_failures = reachability.failures
	AuditEmit("UNDERGROUND_WONDER_ANOMALY_REACHABILITY", stats, map)
	return stats.unresolved == 0 and stats.valid == stats.markers, stats
end

function DepositRules.SetUndergroundWonderReservedHexes(map, hexes, stats)
	if not IsUndergroundMap(map) then
		return false, { error = "target is not an underground map" }
	end
	if type(hexes) ~= "table" then
		return false, { error = "reserved wonder hex set is unavailable" }
	end
	local count = 0
	for _, reserved in pairs(hexes) do
		if reserved == true then count = count + 1 end
	end
	underground_wonder_reserved_hexes_by_map[map] = {
		hexes = hexes,
		count = count,
		stats = stats,
	}
	-- A validation context created before the wonder plan was published must never survive into
	-- density placement with the old nil reservation.
	underground_topup_sampling_by_map[map] = nil
	return true, { reserved_hexes = count, wonders = stats and stats.wonders or nil }
end

function DepositRules.VerifyUndergroundWonderEnrichmentExclusion(map, reason)
	map = map or Global("CurrentMap")
	local reserved = UndergroundWonderReservedHexes(map)
	if not IsUndergroundMap(map) or type(reserved) ~= "table" then
		return false, { error = "underground wonder reservation is unavailable", checked = 0 }
	end
	local world_to_hex = Global("WorldToHex")
	if type(map.MapForEach) ~= "function" or type(world_to_hex) ~= "function" then
		return false, { error = "map/WorldToHex API unavailable", checked = 0 }
	end
	local stats = {
		checked = 0, overlaps = 0, native = 0, topups = 0,
		wonder_owned_rare_anomalies = 0,
	}
	local seen = {}
	local function inspect(marker)
		if not IsEnrichmentMarker(marker) or seen[marker] then return end
		seen[marker] = true
		-- A buried wonder's own SubsurfaceSpecialAnomalyMarker is deliberately spawned by
		-- vanilla at/near that wonder and is validated separately for linkage, locality and
		-- playable terrain. The reserved footprint excludes unrelated enrichments; it must not
		-- reject the wonder-owned gameplay trigger itself.
		local wonder_owned_rare_anomaly =
			marker.SuperBigMapDeferredWonderAnomaly == true
			and IsKindOfSafe(marker, "SubsurfaceSpecialAnomalyMarker")
			and marker.spawner ~= nil
			and IsKindOfSafe(marker.spawner, "UndergroundWonder")
		if wonder_owned_rare_anomaly then
			stats.wonder_owned_rare_anomalies = stats.wonder_owned_rare_anomalies + 1
			return
		end
		stats.checked = stats.checked + 1
		local topup = marker.SuperBigMapResourceTopUp == true
			or marker.SuperBigMapAnomalyTopUp == true
			or marker.SuperBigMapEffectTopUp == true
		if topup then stats.topups = stats.topups + 1 else stats.native = stats.native + 1 end
		local pos = ObjectPos(marker)
		local ok_hex, q, r = false, nil, nil
		if pos then ok_hex, q, r = pcall(world_to_hex, pos) end
		if ok_hex and type(q) == "number" and type(r) == "number"
			and reserved[CoordinateHexKey(q, r)] then
			stats.overlaps = stats.overlaps + 1
		end
	end
	local ok_deposits, deposit_error = pcall(
		map.MapForEach, map, "map", "DepositMarker", inspect)
	local ok_effects, effect_error = pcall(
		map.MapForEach, map, "map", "EffectDepositMarker", inspect)
	stats.error = not ok_deposits and tostring(deposit_error)
		or not ok_effects and tostring(effect_error) or nil
	AuditEmit("UNDERGROUND_WONDER_ENRICHMENT_EXCLUSION", {
		reason = tostring(reason), checked = stats.checked,
		native = stats.native, topups = stats.topups, overlaps = stats.overlaps,
		wonder_owned_rare_anomalies = stats.wonder_owned_rare_anomalies,
		reserved_hexes = underground_wonder_reserved_hexes_by_map[map]
			and underground_wonder_reserved_hexes_by_map[map].count or 0,
		error = tostring(stats.error or ""),
	}, map)
	return ok_deposits and ok_effects and stats.overlaps == 0, stats
end

-- Final correctness audit for stage-03 additions and the small subset of native markers whose
-- proportional destination intersected a reserved wonder footprint. A marker that is not on
-- reachable/buildable/unobstructed terrain is moved to a validated candidate.
function DepositRules.RelocateUnreachableUndergroundEnrichments(map)
	if not ExpansionStepEnabled(3)
		or not ExpansionStepEnabled(11)
		or not ExpansionStepEnabled(14) then
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
	local invalid_details, invalid_by_class, invalid_by_resource = {}, {}, {}
	local function marker_flags(marker)
		local flags = {}
		local function add(enabled, name)
			if enabled == true then flags[#flags + 1] = name end
		end
		add(marker and marker.SuperBigMapResourceTopUp, "resource_topup")
		add(marker and marker.SuperBigMapAnomalyTopUp, "anomaly_topup")
		add(marker and marker.SuperBigMapEffectTopUp, "effect_topup")
		add(marker and marker.SuperBigMapEnrichmentClone, "native_clone")
		add(marker and marker.SuperBigMapTransformWonderReservationResolved, "wonder_conflict")
		add(marker and marker.SuperBigMapUndergroundDensityFallback, "density_fallback")
		add(marker and marker.SuperBigMapTopUpIgnoredRubbleWalls, "ignored_rubble")
		add(marker and marker.SuperBigMapResourceTopUpIgnoredRubbleWalls, "resource_ignored_rubble")
		return #flags > 0 and table.concat(flags, "+") or "none"
	end
	local function point_z(pos)
		if pos and type(pos.z) == "function" then
			local ok, z = pcall(pos.z, pos)
			if ok then return z end
		end
		return nil
	end
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		local additional = marker and (marker.SuperBigMapResourceTopUp == true
			or marker.SuperBigMapAnomalyTopUp == true
			or marker.SuperBigMapEffectTopUp == true
			or marker.SuperBigMapEnrichmentClone == true
			or marker.SuperBigMapTransformWonderReservationResolved == true)
		if additional and IsEnrichmentMarker(marker) then markers[#markers + 1] = marker end
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
		local topup_ignores_rubble = marker and (
			marker.SuperBigMapTopUpIgnoredRubbleWalls == true
				or marker.SuperBigMapResourceTopUpIgnoredRubbleWalls == true)
		local receive_ok = pos and (topup_ignores_rubble
			or CanReceiveDeposit(map, pos) == true) or false
		if not pos or (not topup_ignores_rubble and receive_ok ~= true) then
			local x, y
			if pos and type(pos.xy) == "function" then x, y = pos:xy() end
			local buildable, q, r = false, nil, nil
			if pos then buildable, q, r = IsBuildableAt(map, pos, true) end
			local passable = pos and PassableAt(map, pos) == true or false
			local flatness = pos and FlatnessAt(map, pos) or 0
			local unobstructed = pos and IsUnobstructedAt(map, pos, true) == true or false
			local reachable = pos and type(q) == "number"
				and IsReachableFromUndergroundEntrance(map, pos, q, r) == true or false
			local reserved = type(q) == "number" and type(r) == "number"
				and UndergroundWonderReservedHexes(map)
				and UndergroundWonderReservedHexes(map)[CoordinateHexKey(q, r)] == true or false
			local reason = not pos and "missing_position"
				or buildable ~= true and "unbuildable"
				or passable ~= true and "impassable"
				or flatness < TopUpFlatnessMinimum() and "nonflat"
				or reserved and "wonder_reserved"
				or unobstructed ~= true and "obstructed"
				or reachable ~= true and "entrance_unreachable"
				or "validator_rejected"
			local class = tostring(marker and marker.class or "?")
			local resource = tostring(marker and marker.resource or "?")
			invalid_by_class[class] = (invalid_by_class[class] or 0) + 1
			invalid_by_resource[resource] = (invalid_by_resource[resource] or 0) + 1
			local sector_key = type(x) == "number"
				and EnrichmentSectorKey(SectorAtPoint(map, x, y)) or nil
			local detail = table.concat({
				class .. "/" .. resource,
				"world=" .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(point_z(pos)),
				"hex=" .. tostring(q) .. "," .. tostring(r),
				"sector=" .. tostring(sector_key),
				"reason=" .. tostring(reason),
				"flags=" .. marker_flags(marker),
				"buildable=" .. tostring(buildable),
				"passable=" .. tostring(passable),
				"flatness=" .. tostring(flatness),
				"unobstructed=" .. tostring(unobstructed),
				"reachable=" .. tostring(reachable),
				"reserved=" .. tostring(reserved),
			}, ":")
			invalid_details[#invalid_details + 1] = detail
			invalid[#invalid + 1] = { marker = marker, pos = pos, diagnostic = detail }
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
	local occupied_badges = BuildBadgeOccupancy(map, nil, nil, false)
	local validation_context = SharedTopUpValidationContext(map)
	local function append_candidate(x, y, known_q, known_r)
		if type(x) ~= "number" or type(y) ~= "number" then return false end
		local pt = point(x, y)
		if not CanReceiveDeposit(map, pt, validation_context) then return false end
		local q, r = known_q, known_r
		if (type(q) ~= "number" or type(r) ~= "number")
			and type(world_to_hex) == "function" then
			local ok_h, hex_q, hex_r = pcall(world_to_hex, pt)
			if ok_h and type(hex_q) == "number" and type(hex_r) == "number" then
				q, r = hex_q, hex_r
			end
		end
		local key = type(q) == "number" and type(r) == "number"
			and CoordinateHexKey(q, r) or (tostring(x) .. ":" .. tostring(y))
		if seen[key] or (type(q) == "number" and BadgeHexOccupied(occupied_badges, q, r)) then
			return false
		end
		seen[key] = true
		candidates[#candidates + 1] = { x = x, y = y, q = q, r = r }
		return true
	end

	-- The density suite has already paid to validate and cache unused reachable candidates. Reuse
	-- them before sampling anything new; this removes the former 18-second, 512-position rebuild
	-- when only one wonder-conflicting marker needs correction.
	local cached_candidates = topup_candidate_pool_by_map[map]
	if type(cached_candidates) == "table" then
		for _, candidate in ipairs(cached_candidates) do
			append_candidate(candidate.x, candidate.y, candidate.q, candidate.r)
		end
	end
	local pool_reused = #candidates
	local target_pool = math.min(512, math.max(pool_reused, 64, #invalid * 32))
	local max_samples = math.max(2048, target_pool * 30)
	for _ = 1, max_samples do
		if #candidates >= target_pool then break end
		local x, y = margin + RandInt(span_x), margin + RandInt(span_y)
		append_candidate(x, y)
	end
	local pool_built = #candidates

	-- Reachability relocation runs after the density fallbacks were selected. Preserve their
	-- preferred six-hex clearance while moving another enrichment. When the terrain/repulsion
	-- constraints make six hexes impossible, rank the entire remaining pool by maximin clearance
	-- and use the farthest valid candidate instead of dropping the marker.
	local fallback_clearance_entries = {}
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not IsEnrichmentMarker(marker) then return end
		local pos = ObjectPos(marker)
		if not pos then return end
		local ok_hex, q, r = pcall(world_to_hex, pos)
		if ok_hex and type(q) == "number" and type(r) == "number" then
			fallback_clearance_entries[#fallback_clearance_entries + 1] = {
				marker = marker, q = q, r = r,
				fallback = marker.SuperBigMapUndergroundDensityFallback == true,
			}
		end
		if candidate._sbm_fallback_spacing_relaxed == true then
			relaxed_selected = relaxed_selected + 1
		end
	end)
	local function fallback_clearance_hex(candidate, moving_marker)
		if type(candidate) ~= "table" then return nil end
		local q, r = candidate.q, candidate.r
		if (type(q) ~= "number" or type(r) ~= "number")
			and type(candidate.x) == "number" and type(candidate.y) == "number" then
			local ok_hex, hq, hr = pcall(world_to_hex, point(candidate.x, candidate.y))
			if ok_hex then q, r = hq, hr end
		end
		if type(q) ~= "number" or type(r) ~= "number" then return nil end
		local moving_is_fallback = moving_marker
			and moving_marker.SuperBigMapUndergroundDensityFallback == true
		local nearest
		for _, entry in ipairs(fallback_clearance_entries) do
			if entry.marker ~= moving_marker and (moving_is_fallback or entry.fallback) then
				local distance = AxialHexDistance(q, r, entry.q, entry.r)
				if type(distance) == "number"
					and (nearest == nil or distance < nearest) then
					nearest = distance
				end
			end
		end
		return nearest or math.huge, q, r
	end
	local function update_fallback_clearance_entry(marker, q, r)
		if type(q) ~= "number" or type(r) ~= "number" then return false end
		for _, entry in ipairs(fallback_clearance_entries) do
			if entry.marker == marker then
				entry.q, entry.r = q, r
				return true
			end
		end
		fallback_clearance_entries[#fallback_clearance_entries + 1] = {
			marker = marker, q = q, r = r,
			fallback = marker and marker.SuperBigMapUndergroundDensityFallback == true,
		}
		return true
	end

	local function take_near(pos, moving_marker)
		if #candidates == 0 then return nil end
		local ox, oy
		if pos and type(pos.xy) == "function" then ox, oy = pos:xy() end
		local best_i, best_clearance, best_d
		for i = 1, #candidates do
			local c = candidates[i]
			local clearance = fallback_clearance_hex(c, moving_marker)
			clearance = type(clearance) == "number" and clearance or -1
			local d = 0
			if type(ox) == "number" then
				local dx, dy = c.x - ox, c.y - oy
				d = dx * dx + dy * dy
			end
			if best_clearance == nil or clearance > best_clearance
				or (clearance == best_clearance and (best_d == nil or d < best_d)) then
				best_i, best_clearance, best_d = i, clearance, d
			end
		end
		local selected = table.remove(candidates, best_i)
		if selected then selected._sbm_relocation_fallback_clearance_hex = best_clearance end
		return selected
	end

	local moved, unresolved = 0, 0
	local moved_by_class, unresolved_by_class, unresolved_by_resource = {}, {}, {}
	local relocation_details, unresolved_details = {}, {}
	local ignored_for_strict_repulsion = {}
	local ignored_for_topup_repulsion = {}
	for _, item in ipairs(invalid) do
		if item.marker then
			ignored_for_strict_repulsion[item.marker] = true
			ignored_for_topup_repulsion[item.marker] = true
		end
	end
	local function ordinary_topup(marker)
		return marker and marker.SuperBigMapUndergroundDensityFallback ~= true
			and (marker.SuperBigMapResourceTopUp == true
				or marker.SuperBigMapAnomalyTopUp == true
				or marker.SuperBigMapEffectTopUp == true)
	end
	-- The final invariant excludes native/native pairs and every pair containing a density-
	-- fallback marker. Mirror that exact rule here instead of over-constraining native deposit
	-- clusters: ordinary top-ups see natives+ordinary top-ups, while a relocated native sees only
	-- ordinary top-ups.
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if marker.SuperBigMapUndergroundDensityFallback == true then
			ignored_for_strict_repulsion[marker] = true
		end
		if not ordinary_topup(marker) then
			ignored_for_topup_repulsion[marker] = true
		end
	end)
	local strict_repulsion = NewTopUpRepulsionTracker(
		map, "underground ordinary-top-up relocation", ignored_for_strict_repulsion, true)
	local topup_only_repulsion = NewTopUpRepulsionTracker(
		map, "underground native relocation versus top-ups", ignored_for_topup_repulsion, true)
	local relocation_attempts, relocation_retries = 0, 0
	local snapped_rejected, setpos_failed, postmove_rejected = 0, 0, 0
	local repulsion_rejected, missing_repulsion_profile = 0, 0
	local fallback_clearance_relaxed_moves = 0
	local fallback_clearance_minimum_move
	for invalid_i, item in ipairs(invalid) do
		local marker, old_pos = item.marker, item.pos
		local class = tostring(marker and marker.class or "?")
		local resource = tostring(marker and marker.resource or "?")
		local profile = VanillaRepulsionProfileForMarker(map, marker)
		local density_fallback = marker
			and marker.SuperBigMapUndergroundDensityFallback == true
		local marker_is_topup = ordinary_topup(marker)
		local ox, oy
		if old_pos and type(old_pos.xy) == "function" then ox, oy = old_pos:xy() end
		local diagnostic_prefix = tostring(item.diagnostic or (class .. "/" .. resource))
		if not marker or type(marker.SetPos) ~= "function" then
			unresolved = unresolved + 1
			unresolved_by_class[class] = (unresolved_by_class[class] or 0) + 1
			unresolved_by_resource[resource] = (unresolved_by_resource[resource] or 0) + 1
			unresolved_details[#unresolved_details + 1] = diagnostic_prefix
				.. ":failure=marker_or_SetPos_unavailable"
		elseif not profile then
			missing_repulsion_profile = missing_repulsion_profile + 1
			unresolved = unresolved + 1
			unresolved_by_class[class] = (unresolved_by_class[class] or 0) + 1
			unresolved_by_resource[resource] = (unresolved_by_resource[resource] or 0) + 1
			unresolved_details[#unresolved_details + 1] = diagnostic_prefix
				.. ":failure=missing_repulsion_profile"
		else
			-- Leave at least one candidate for every marker still to process. A candidate was
			-- reachable when sampled, but terrain-Z snapping or SetPos can alter the effective
			-- point. The old single-attempt path therefore produced a false unresolved result
			-- despite hundreds of alternatives remaining in the pool.
			local later_markers = #invalid - invalid_i
			local max_attempts = math.min(64, math.max(0, #candidates - later_markers))
			local attempts, success = 0, false
			local successful_pos, successful_candidate, successful_fallback_clearance
			local last_reason = max_attempts > 0 and "no candidate attempted" or "candidate pool exhausted"
			local last_candidate = "none"
			local last_repulsion_detail = ""
			local item_snapped_rejected, item_repulsion_rejected = 0, 0
			local item_setpos_failed, item_postmove_rejected = 0, 0
			local candidates_before = #candidates
			while attempts < max_attempts and not success do
				local c = take_near(old_pos, marker)
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
				last_candidate = "world=" .. tostring(nx) .. "," .. tostring(ny)
					.. ":sample_hex=" .. tostring(c.q) .. "," .. tostring(c.r)
				if not CanReceiveDeposit(map, new_pos, validation_context) then
					snapped_rejected = snapped_rejected + 1
					item_snapped_rejected = item_snapped_rejected + 1
					last_reason = "terrain-snapped candidate not reachable/buildable/unobstructed"
				else
					local candidate = { x = nx, y = ny }
					local _, candidate_q, candidate_r =
						fallback_clearance_hex(candidate, marker)
					candidate.q, candidate.r = candidate_q, candidate_r
					local spacing_ok, active_repulsion
					if density_fallback then
						active_repulsion = strict_repulsion
						spacing_ok = strict_repulsion.CanPlaceUnique(candidate)
					elseif marker_is_topup then
						active_repulsion = strict_repulsion
						spacing_ok = strict_repulsion.CanPlace(candidate, profile)
					else
						active_repulsion = topup_only_repulsion
						spacing_ok = topup_only_repulsion.CanPlace(candidate, profile)
					end
					if not spacing_ok then
						repulsion_rejected = repulsion_rejected + 1
						item_repulsion_rejected = item_repulsion_rejected + 1
						last_repulsion_detail = tostring(
							active_repulsion and active_repulsion.Stats().last_rejection or "")
						last_reason = "candidate violates enrichment repulsion"
					else
						local ok_move, move_error = pcall(marker.SetPos, marker, new_pos)
						if not ok_move then
							setpos_failed = setpos_failed + 1
							item_setpos_failed = item_setpos_failed + 1
							last_reason = "SetPos failed: " .. tostring(move_error)
						else
							local actual_pos = ObjectPos(marker)
							local ax, ay
							if actual_pos and type(actual_pos.xy) == "function" then
								ax, ay = actual_pos:xy()
							end
							local actual_candidate = { x = ax, y = ay }
							local actual_fallback_clearance, actual_q, actual_r =
								fallback_clearance_hex(actual_candidate, marker)
							actual_candidate.q, actual_candidate.r = actual_q, actual_r
							local actual_spacing_ok = ax == nx and ay == ny
							if not actual_spacing_ok and type(ax) == "number" then
								if density_fallback then
									actual_spacing_ok = strict_repulsion.CanPlaceUnique(actual_candidate)
								elseif marker_is_topup then
									actual_spacing_ok = strict_repulsion.CanPlace(
										actual_candidate, profile)
								else
									actual_spacing_ok = topup_only_repulsion.CanPlace(
										actual_candidate, profile)
								end
							end
							if actual_pos and CanReceiveDeposit(
								map, actual_pos, validation_context)
								and actual_spacing_ok then
								success = true
								successful_pos = actual_pos
								successful_candidate = actual_candidate
								successful_fallback_clearance = actual_fallback_clearance
							else
								postmove_rejected = postmove_rejected + 1
								item_postmove_rejected = item_postmove_rejected + 1
								if not actual_spacing_ok then
									repulsion_rejected = repulsion_rejected + 1
									item_repulsion_rejected = item_repulsion_rejected + 1
									local active_repulsion = density_fallback
										and strict_repulsion or marker_is_topup
										and strict_repulsion or topup_only_repulsion
									last_repulsion_detail = tostring(
										active_repulsion.Stats().last_rejection or "")
								end
								last_reason = actual_pos
									and "actual marker position failed terrain/repulsion validation"
									or "actual marker position unavailable"
							end
						end
					end
				end
			end
			if success then
				if not density_fallback then
					strict_repulsion.Commit(successful_candidate, profile, marker)
					if marker_is_topup then
						topup_only_repulsion.Commit(successful_candidate, profile, marker)
					end
				end
				moved = moved + 1
				if type(successful_fallback_clearance) == "number"
					and successful_fallback_clearance < math.huge then
					fallback_clearance_minimum_move = fallback_clearance_minimum_move == nil
						and successful_fallback_clearance
						or math.min(fallback_clearance_minimum_move, successful_fallback_clearance)
					if successful_fallback_clearance < UndergroundFallbackMinimumHexDistance() then
						fallback_clearance_relaxed_moves = fallback_clearance_relaxed_moves + 1
						marker.SuperBigMapUndergroundFallbackSpacingRelaxed = true
					end
					marker.SuperBigMapReachabilityRelocationFallbackClearanceHex =
						successful_fallback_clearance
				end
				update_fallback_clearance_entry(marker,
					successful_candidate.q, successful_candidate.r)
				moved_by_class[class] = (moved_by_class[class] or 0) + 1
				local final_x, final_y
				if successful_pos and type(successful_pos.xy) == "function" then
					final_x, final_y = successful_pos:xy()
				end
				relocation_details[#relocation_details + 1] = diagnostic_prefix
					.. ":result=moved:attempts=" .. tostring(attempts)
					.. ":to_world=" .. tostring(final_x) .. "," .. tostring(final_y)
					.. ":snapped_rejected=" .. tostring(item_snapped_rejected)
					.. ":repulsion_rejected=" .. tostring(item_repulsion_rejected)
					.. ":setpos_failed=" .. tostring(item_setpos_failed)
					.. ":postmove_rejected=" .. tostring(item_postmove_rejected)
					.. ":fallback_clearance_hex="
					.. tostring(successful_fallback_clearance)
				marker.SuperBigMapReachabilityRelocated = true
				if marker.SuperBigMapTransformWonderReservationResolved == true
					and successful_pos and type(successful_pos.xy) == "function" then
					local final_x, final_y = successful_pos:xy()
					marker.SuperBigMapExpectedStretchedX = final_x
					marker.SuperBigMapExpectedStretchedY = final_y
					marker.SuperBigMapWonderConflictRelocated = true
				end
			else
				unresolved = unresolved + 1
				unresolved_by_class[class] = (unresolved_by_class[class] or 0) + 1
				unresolved_by_resource[resource] = (unresolved_by_resource[resource] or 0) + 1
				unresolved_details[#unresolved_details + 1] = diagnostic_prefix
					.. ":failure=" .. tostring(last_reason)
					.. ":attempts=" .. tostring(attempts)
					.. ":max_attempts=" .. tostring(max_attempts)
					.. ":candidates_before=" .. tostring(candidates_before)
					.. ":candidates_after=" .. tostring(#candidates)
					.. ":last_candidate=" .. tostring(last_candidate)
					.. ":snapped_rejected=" .. tostring(item_snapped_rejected)
					.. ":repulsion_rejected=" .. tostring(item_repulsion_rejected)
					.. ":setpos_failed=" .. tostring(item_setpos_failed)
					.. ":postmove_rejected=" .. tostring(item_postmove_rejected)
					.. ":last_repulsion=" .. tostring(last_repulsion_detail)
			end
		end
	end
	if #concrete_moves > 0 then MoveConcreteImprints(map, concrete_moves) end
	local stats = {
		checked = #markers, invalid = #invalid, moved = moved,
		unrevealed_placed = unrevealed_placed,
		unresolved = unresolved, candidates_built = pool_built,
		candidates_reused = pool_reused,
		relocation_attempts = relocation_attempts, relocation_retries = relocation_retries,
		snapped_rejected = snapped_rejected, setpos_failed = setpos_failed,
		postmove_rejected = postmove_rejected, repulsion_rejected = repulsion_rejected,
		fallback_clearance_relaxed_moves = fallback_clearance_relaxed_moves,
		fallback_clearance_minimum_move = fallback_clearance_minimum_move or 0,
		missing_repulsion_profile = missing_repulsion_profile,
		candidates_remaining = #candidates,
		seeds = #reachable_state.seeds, connectivity_checks = reachable_state.checks,
		connectivity_reachable = reachable_state.reachable,
		connectivity_rejected = reachable_state.rejected,
		connectivity_failures = reachable_state.failures,
		moved_by_class = TallyString(moved_by_class),
		invalid_by_class = TallyString(invalid_by_class),
		invalid_by_resource = TallyString(invalid_by_resource),
		unresolved_by_class = TallyString(unresolved_by_class),
		unresolved_by_resource = TallyString(unresolved_by_resource),
		invalid_details = table.concat(invalid_details, ";"),
		relocation_details = table.concat(relocation_details, ";"),
		unresolved_details = table.concat(unresolved_details, ";"),
		strict_repulsion_tracker = strict_repulsion.Stats(),
		topup_only_repulsion_tracker = topup_only_repulsion.Stats(),
		strict_first_rejection = strict_repulsion.Stats().first_rejection,
		strict_last_rejection = strict_repulsion.Stats().last_rejection,
		topup_only_first_rejection = topup_only_repulsion.Stats().first_rejection,
		topup_only_last_rejection = topup_only_repulsion.Stats().last_rejection,
	}
	AuditEmit("UNDERGROUND_ENRICHMENT_REACHABILITY", stats, map)
	return unresolved == 0, stats
end

-- TEMP test aid: use vanilla placement for every final underground marker, then force the
-- resulting marker/deposit object visible so the complete distribution can be inspected.
function DepositRules.RevealAllUndergroundEnrichmentsForTesting(map)
	if cfg().UNDERGROUND_REVEAL_ALL_ENRICHMENTS_FOR_TESTING ~= true then
		return true, { markers = 0, requested = 0, placed = 0, revealed = 0 }
	end
	map = map or Global("CurrentMap")
	if not IsUndergroundMap(map) or type(map.MapForEach) ~= "function" then
		return false, { error = "underground map API unavailable" }
	end

	local markers = {}
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if IsEnrichmentMarker(marker) then markers[#markers + 1] = marker end
	end)
	local reveal_deposits = Global("RevealDeposits")
	if type(reveal_deposits) ~= "function" then
		return false, { error = "RevealDeposits unavailable", markers = #markers }
	end

	local requested = {}
	for i = 1, #markers do
		if markers[i].is_placed ~= true then requested[#requested + 1] = markers[i] end
	end
	if #requested > 0 then
		local reveal_ok, reveal_error = pcall(reveal_deposits, requested)
		if not reveal_ok then
			return false, {
				error = tostring(reveal_error), markers = #markers, requested = #requested,
			}
		end
	end

	local placed, revealed = 0, 0
	local is_valid = Global("IsValid")
	for i = 1, #markers do
		local marker = markers[i]
		local placed_object = marker.placed_obj
		local placed_valid = placed_object
			and (type(is_valid) ~= "function" or is_valid(placed_object) == true)
		if marker.is_placed == true or placed_valid then placed = placed + 1 end
		local visible_object = placed_valid and placed_object or marker
		SetRevealedState(visible_object, true)
		if visible_object.revealed == true then revealed = revealed + 1 end
	end
	return true, {
		markers = #markers, requested = #requested, placed = placed, revealed = revealed,
	}
end

-- Exhaustive read-only snapshot used by config.DebugEnrichmentAudit. It deliberately runs after
-- the normal hard invariants, and repeats their calculations only while the diagnostic gate is on.
-- The per-marker rows preserve enough data to compare vanilla source coordinates, proportional
-- targets, final hexes, top-up placement rules, and RevealDeposits movement from one log.
function DepositRules.DebugAuditFinalEnrichments(map, reason)
	if not AuditEnabled() then return true, { disabled = true } end
	map = map or Global("CurrentMap")
	if not map or type(map.MapForEach) ~= "function" then
		AuditEmit("FINAL_AUDIT_UNAVAILABLE", { reason = tostring(reason) }, map)
		return false, { error = "map API unavailable" }
	end
	local point_fn = Global("point")
	local world_to_hex = Global("WorldToHex")
	local xxhash = Global("xxhash")
	local underground = IsUndergroundMap(map)
	local ring_sectors = math.max(0, math.floor(cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3))
	local entries, sector_counts = {}, {}
	local source_counts, final_counts, topup_counts = {}, {}, {}
	local native_count, topup_count, native_mismatches, invalid_topups = 0, 0, 0, 0
	local missing_positions, duplicate_hexes = 0, 0
	local hex_owners = {}

	local function family_and_type(marker)
		if IsResourceDepositMarker(marker) then
			return "resource", tostring(marker.resource or marker.class or "?")
		end
		if IsAnomalyMarker(marker) then
			local action = marker.tech_action
			if action == nil or action == "" then
				action = marker.sequence and marker.sequence ~= "" and "sequence" or "other"
			end
			return "anomaly", tostring(action)
		end
		return "effect", tostring(marker.deposit_type or marker.class or "?")
	end

	local seen_markers = {}
	local function capture_marker(marker)
		if not IsEnrichmentMarker(marker) then return end
		if seen_markers[marker] then return end
		seen_markers[marker] = true
		local family, subtype = family_and_type(marker)
		local type_key = family .. "/" .. subtype
		final_counts[type_key] = (final_counts[type_key] or 0) + 1
		local topup = marker.SuperBigMapResourceTopUp == true
			or marker.SuperBigMapAnomalyTopUp == true
			or marker.SuperBigMapEffectTopUp == true
		local native = not topup and type(marker.SuperBigMapNativeSourceX) == "number"
		if topup then
			topup_count = topup_count + 1
			topup_counts[type_key] = (topup_counts[type_key] or 0) + 1
		elseif native then
			native_count = native_count + 1
			source_counts[type_key] = (source_counts[type_key] or 0) + 1
		end
		local pos = ObjectPos(marker)
		local x, y, z
		if pos and type(pos.xy) == "function" then x, y = pos:xy() end
		if pos and type(pos.z) == "function" then
			local ok_z, value = pcall(pos.z, pos)
			if ok_z then z = value end
		end
		if type(x) ~= "number" or type(y) ~= "number" then missing_positions = missing_positions + 1 end
		local q, r
		if type(x) == "number" and type(world_to_hex) == "function" and type(point_fn) == "function" then
			local ok_hex, hq, hr = pcall(world_to_hex, point_fn(x, y))
			if ok_hex then q, r = hq, hr end
		end
		local hex_key = type(q) == "number" and (tostring(q) .. ":" .. tostring(r)) or "nil"
		if hex_key ~= "nil" then
			if hex_owners[hex_key] then duplicate_hexes = duplicate_hexes + 1
			else hex_owners[hex_key] = true end
		end
		local sector = type(x) == "number" and SectorAtPoint(map, x, y) or nil
		local sector_key = sector and (tostring(sector.col) .. ":" .. tostring(sector.row)) or "none"
		local sector_entry = sector_counts[sector_key]
		if not sector_entry then
			sector_entry = { total = 0, native = 0, topup = 0, resource = 0, anomaly = 0, effect = 0 }
			sector_counts[sector_key] = sector_entry
		end
		sector_entry.total = sector_entry.total + 1
		sector_entry[family] = sector_entry[family] + 1
		if topup then sector_entry.topup = sector_entry.topup + 1 else sector_entry.native = sector_entry.native + 1 end
		local passable = pos and PassableAt(map, pos) or false
		local flatness = pos and FlatnessAt(map, pos) or nil
		local buildable = pos and IsBuildableAt(map, pos, true) or false
		local unobstructed = pos and IsUnobstructedAt(map, pos, true) or false
		local reachable = not underground or (pos and IsReachableFromUndergroundEntrance(map, pos) or false)
		local topup_ignores_rubble = underground and (
			marker.SuperBigMapTopUpIgnoredRubbleWalls == true
				or marker.SuperBigMapResourceTopUpIgnoredRubbleWalls == true)
		local terrain_valid = topup_ignores_rubble or (passable and type(flatness) == "number"
			and flatness >= TopUpFlatnessMinimum() and buildable and unobstructed and reachable
		)
		if topup and not terrain_valid then invalid_topups = invalid_topups + 1 end
		local expected_x = tonumber(marker.SuperBigMapExpectedStretchedX)
		local expected_y = tonumber(marker.SuperBigMapExpectedStretchedY)
		local native_xy_match = not native or (x == expected_x and y == expected_y)
		if native and not native_xy_match then native_mismatches = native_mismatches + 1 end
		local position_hash
		if pos and type(xxhash) == "function" then
			local ok_hash, value = pcall(xxhash, pos)
			if ok_hash then position_hash = value end
		end
		local placed_obj = marker.placed_obj
		local placed_pos = placed_obj and ObjectPos(placed_obj) or nil
		local placed_x, placed_y, placed_z
		if placed_pos and type(placed_pos.xy) == "function" then placed_x, placed_y = placed_pos:xy() end
		if placed_pos and type(placed_pos.z) == "function" then
			local ok_z, value = pcall(placed_pos.z, placed_pos)
			if ok_z then placed_z = value end
		end
		entries[#entries + 1] = {
			marker = marker, family = family, subtype = subtype, type_key = type_key,
			topup = topup, native = native, class = tostring(marker.class),
			x = x, y = y, z = z, q = q, r = r, hash = position_hash,
			sector = sector, sector_key = sector_key,
			passable = passable, flatness = flatness, buildable = buildable,
			unobstructed = unobstructed, reachable = reachable, terrain_valid = terrain_valid,
			resource_ignores_rubble = topup_ignores_rubble,
			native_xy_match = native_xy_match,
			placed_x = placed_x, placed_y = placed_y, placed_z = placed_z,
		}
	end
	local deposit_enum_ok, deposit_enum_error = pcall(
		map.MapForEach, map, "map", "DepositMarker", capture_marker)
	local effect_enum_ok, effect_enum_error = pcall(
		map.MapForEach, map, "map", "EffectDepositMarker", capture_marker)
	table.sort(entries, function(a, b)
		if (a.x or -1) ~= (b.x or -1) then return (a.x or -1) < (b.x or -1) end
		if (a.y or -1) ~= (b.y or -1) then return (a.y or -1) < (b.y or -1) end
		if a.family ~= b.family then return a.family < b.family end
		return a.class < b.class
	end)

	local transform_stats = map.SuperBigMapNativeTransformStats or {}
	local density = map.SuperBigMapEnrichmentTopUpStatus or {}
	local repulsion_ok, repulsion_stats = DepositRules.AuditTopUpVanillaRepulsion(map,
		"diagnostic " .. tostring(reason))
	local ring_ok, ring_stats = true, {}
	if not underground then
		ring_ok, ring_stats = DepositRules.AuditSurfaceTopUpRingExclusivity(map)
	end
	AuditEmit("FINAL_SUMMARY", {
		reason = tostring(reason), markers = #entries, native = native_count, topups = topup_count,
		captured_native = tostring(map.SuperBigMapNativeEnrichmentCaptureCount),
		recreated_native = tostring(map.SuperBigMapNativeEnrichmentRecreatedCount),
		native_transform_verified = tostring(map.SuperBigMapNativeTransformVerified),
		native_transform_mismatches = tostring(transform_stats.mismatches),
		native_current_xy_mismatches = native_mismatches,
		missing_positions = missing_positions, duplicate_hexes_all_markers = duplicate_hexes,
		deposit_enumeration_ok = tostring(deposit_enum_ok),
		deposit_enumeration_error = deposit_enum_ok and "" or tostring(deposit_enum_error),
		effect_enumeration_ok = tostring(effect_enum_ok),
		effect_enumeration_error = effect_enum_ok and "" or tostring(effect_enum_error),
		invalid_topups = invalid_topups, repulsion_ok = tostring(repulsion_ok),
		repulsion_density_failures = tostring(repulsion_stats and repulsion_stats.density_failures),
		repulsion_duplicate_hex_pairs = tostring(repulsion_stats and repulsion_stats.duplicate_hex_pairs),
		repulsion_violations = tostring(repulsion_stats and repulsion_stats.repulsion_violations),
		ring_ok = tostring(ring_ok), ring_violations = tostring(ring_stats and ring_stats.violations),
		resource_status = type(density.resources) == "table" and tostring(density.resources.complete) or "missing",
		resource_shortfall = type(density.resources) == "table" and density.resources.remaining_shortfall or "missing",
		anomaly_status = type(density.anomalies) == "table" and tostring(density.anomalies.complete) or "missing",
		anomaly_shortfall = type(density.anomalies) == "table" and density.anomalies.remaining_shortfall or "missing",
		effect_status = type(density.effects) == "table" and tostring(density.effects.complete) or "missing",
		effect_shortfall = type(density.effects) == "table" and density.effects.remaining_shortfall or "missing",
		source_counts = CountMapString(source_counts), final_counts = CountMapString(final_counts),
		topup_counts = CountMapString(topup_counts),
	}, map)

	local sector_keys = {}
	for key in pairs(sector_counts) do sector_keys[#sector_keys + 1] = key end
	table.sort(sector_keys)
	for _, key in ipairs(sector_keys) do
		local value = sector_counts[key]
		AuditEmit("SECTOR_DENSITY", {
			sector = key, total = value.total, native = value.native, topup = value.topup,
			resources = value.resource, anomalies = value.anomaly, effects = value.effect,
		}, map)
	end
	for index, entry in ipairs(entries) do
		local marker = entry.marker
		local origin = entry.topup and "topup" or (entry.native and "native" or "other")
		AuditEmit("FINAL_MARKER", {
			index = index, origin = origin, family = entry.family, subtype = entry.subtype,
			class = entry.class, record_index = tostring(marker.SuperBigMapNativeRecordIndex),
			source_x = tostring(marker.SuperBigMapNativeSourceX),
			source_y = tostring(marker.SuperBigMapNativeSourceY),
			source_z = tostring(marker.SuperBigMapNativeSourceZ),
			source_hash = tostring(marker.SuperBigMapNativeSourceHash),
			raw_x = tostring(marker.SuperBigMapRawStretchedX), raw_y = tostring(marker.SuperBigMapRawStretchedY),
			intended_x = tostring(marker.SuperBigMapIntendedStretchedX),
			intended_y = tostring(marker.SuperBigMapIntendedStretchedY),
			expected_x = tostring(marker.SuperBigMapExpectedStretchedX),
			expected_y = tostring(marker.SuperBigMapExpectedStretchedY),
			actual_x = tostring(entry.x), actual_y = tostring(entry.y), actual_z = tostring(entry.z),
			actual_hash = tostring(entry.hash), hex = tostring(entry.q) .. ":" .. tostring(entry.r),
			native_xy_match = tostring(entry.native_xy_match),
			collision_resolved = tostring(marker.SuperBigMapTransformCollisionResolved == true),
			wonder_reservation_resolved = tostring(
				marker.SuperBigMapTransformWonderReservationResolved == true),
			wonder_conflict_relocated = tostring(
				marker.SuperBigMapWonderConflictRelocated == true),
			resolution_radius = tostring(marker.SuperBigMapTransformCollisionResolutionRadius),
			sector = entry.sector_key,
			sector_status = tostring(entry.sector and entry.sector.status),
			in_surface_outer_ring = tostring(not underground and type(entry.x) == "number"
				and IsInFinalOuterSectorRing(map, entry.x, entry.y, ring_sectors) or false),
			passable = tostring(entry.passable), flatness = tostring(entry.flatness),
			buildable = tostring(entry.buildable), unobstructed = tostring(entry.unobstructed),
			reachable = tostring(entry.reachable), topup_terrain_valid = tostring(entry.terrain_valid),
			is_placed = tostring(marker.is_placed == true), revealed = tostring(marker.revealed == true),
			placed_x = tostring(entry.placed_x), placed_y = tostring(entry.placed_y),
			placed_z = tostring(entry.placed_z),
		}, map)
	end
	local ok = deposit_enum_ok and effect_enum_ok
		and native_mismatches == 0 and invalid_topups == 0
		and repulsion_ok == true and ring_ok == true
	return ok, {
		markers = #entries, native = native_count, topups = topup_count,
		native_mismatches = native_mismatches, invalid_topups = invalid_topups,
	}
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
--      flagged SuperBigMapEnrichmentClone, so the existing OnSectorScanned reveal shows it when its
--      sector is actually scanned;
--   B) every SCANNED sector gets vanilla's own RevealDeposits over its markers (places/reveals
--      what moved in), plus a reveal of any hidden scan-gated objects inside it.
function DepositRules.EnforceScanGateAfterStretch(map)
	if not ExpansionStepEnabled(2) or not ExpansionStepEnabled(20) then return end
	if cfg().STRETCH_ENFORCE_SCAN_GATE ~= true then return end
	map = map or Global("CurrentMap")
	local city = map and map.City
	local get_sector = Global("GetMapSectorXY")
	if not map or not city or type(map.MapForEach) ~= "function" or type(get_sector) ~= "function" then
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
				obj.SuperBigMapEnrichmentClone = true
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
	-- sector is really scanned, and
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
end

function DepositRules.OnSectorScanned(status, sector)
	if not Enabled() then return end
	if type(sector) ~= "table" then return end
	local map = (type(sector.GetMap) == "function") and SafeCall(sector.GetMap, sector) or Global("CurrentMap")
	local area = sector.area
	if not map or not area or type(map.MapForEach) ~= "function" then return end

	-- Self-heal surface anomaly top-up markers. Vanilla normally places
	-- registered markers before SectorScanned fires; if the custom 20x20 sector path ever misses
	-- one, place it here at the same scan boundary so it never remains permanently invisible.
	local edge_markers, unplaced = {}, {}
	pcall(map.MapForEach, map, area, "SubsurfaceAnomalyMarker", function(marker)
		if marker and marker.SuperBigMapEdgeTopUp then
			edge_markers[#edge_markers + 1] = marker
			if marker.is_placed ~= true then unplaced[#unplaced + 1] = marker end
		end
	end)
	local reveal_deposits = Global("RevealDeposits")
	if #unplaced > 0 and type(reveal_deposits) == "function" then
		pcall(reveal_deposits, unplaced)
	end
	for _, marker in ipairs(edge_markers) do
		local placed_obj = marker.placed_obj
		if marker.is_placed == true and placed_obj then
			if placed_obj.revealed ~= true then SetRevealedState(placed_obj, true) end
		end
	end
	pcall(map.MapForEach, map, area, "SubsurfaceDeposit", function(obj)
		if obj and obj.SuperBigMapEnrichmentClone and IsScanGatedDeposit(obj) then
			SetRevealedState(obj, true)
		end
	end)
	-- SubsurfaceAnomaly is not a SubsurfaceDeposit subclass; sweep it too.
	pcall(map.MapForEach, map, area, "SubsurfaceAnomaly", function(obj)
		if obj and obj.SuperBigMapEnrichmentClone and IsScanGatedDeposit(obj) then
			SetRevealedState(obj, true)
		end
	end)
end

DepositRules.ClearTopUpPlacementPool = ClearTopUpPlacementPool

SuperBigMap.DepositRules = DepositRules

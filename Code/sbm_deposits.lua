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
	local ok = pcall(fn)
	if type(resume) == "function" then SafeCall(resume, reason) end
	return ok
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

-- True for the N-sector-wide perimeter ring of the expanded sector grid. Prefer the live
-- sector's col/row; fall back to world-distance math when sector metadata is unavailable.
-- Used only to route TOP-UP extras -- vanilla-generated markers stay put.
local function IsInOuterSectorRing(map, x, y, ring_sectors)
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

-- Exhaustive distribution diagnostic (gated by DebugDeposits): bucket every deposit and
-- anomaly MARKER by the sector it sits in and report totals + which sectors are dense. This
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
			rec = { dep = 0, anom = 0, scanned = SectorIsScanned(sector) }
			per_sector[name] = rec
			order[#order + 1] = name
		end
		rec[kind] = rec[kind] + 1
	end

	local total_dep, total_anom = 0, 0
	pcall(map.MapForEach, map, "map", "DepositMarker", function(m)
		if not IsKindOfSafe(m, "DepositMarker") then return end
		total_dep = total_dep + 1
		bucket("dep", m)
	end)
	pcall(map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(m)
		if not IsSubsurfaceAnomalyMarker(m) then return end
		total_anom = total_anom + 1
		bucket("anom", m)
	end)

	local sectors_with, scanned_sectors, scanned_dep, scanned_anom = 0, 0, 0, 0
	local scanned_detail = {}
	for _, name in ipairs(order) do
		local rec = per_sector[name]
		sectors_with = sectors_with + 1
		if rec.scanned then
			scanned_sectors = scanned_sectors + 1
			scanned_dep = scanned_dep + rec.dep
			scanned_anom = scanned_anom + rec.anom
			scanned_detail[#scanned_detail + 1] = string.format("%s[d%d/a%d]", name, rec.dep, rec.anom)
		end
	end

	table.sort(order, function(a, b)
		local ra, rb = per_sector[a], per_sector[b]
		return (ra.dep + ra.anom) > (rb.dep + rb.anom)
	end)
	local top = {}
	for i = 1, math.min(#order, 12) do
		local name = order[i]
		local rec = per_sector[name]
		top[#top + 1] = string.format("%s%s=%d(d%d/a%d)", name, rec.scanned and "*" or "", rec.dep + rec.anom, rec.dep, rec.anom)
	end

	local avg = (sectors_with > 0) and string.format("%.2f", (total_dep + total_anom) / sectors_with) or "n/a"
	Log("DISTRIBUTION [" .. tostring(phase) .. "] summary", {
		total_deposits = total_dep,
		total_anomalies = total_anom,
		sectors_with_markers = sectors_with,
		avg_markers_per_occupied_sector = avg,
		scanned_sectors = scanned_sectors,
		scanned_deposits = scanned_dep,
		scanned_anomalies = scanned_anom,
		scanned_detail = table.concat(scanned_detail, " "),
	})
	Log("DISTRIBUTION [" .. tostring(phase) .. "] top density (name*=scanned; =total(dDeposits/aAnomalies))", {
		top = table.concat(top, " "),
	})
	-- Regional check: markers-per-area in the mirrored frame L vs the rendered source quadrant.
	-- frame_over_source_ratio ~= 1.0 means one region is denser (the "bottom-left denser" bug);
	-- ~1.0 means the redistribution evened it out.
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
			if revealed and not move_revealed then
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

function DepositRules.TopUpDeposits(map)
	if cfg().TOPUP_RESOURCES ~= true then return end
	map = map or Global("CurrentMap")
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
	local templates = {}
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not (marker and IsResourceDepositMarker(marker)) then return end
		total_current = total_current + 1
		local pos = ObjectPos(marker)
		if not pos or type(pos.xy) ~= "function" then return end
		local px, py = pos:xy()
		if px == nil then return end
		if stretch_mode or (px < src_w and py < src_h) then
			source_count = source_count + 1
			-- All resource types are templates (incl. concrete) so the top-up mix is
			-- proportional to the source; cloned concrete self-paints its patch on scan.
			templates[#templates + 1] = marker
		end
	end)

	local target = math.floor(source_count * area_factor + 0.5)
	local shortfall = target - total_current
	if shortfall <= 0 or #templates == 0 then
		Log("deposit top-up: nothing to add", {
			total_current = total_current, source_count = source_count, target = target,
			shortfall = shortfall, templates = #templates,
			area_factor = string.format("%.3f", area_factor),
		})
		return
	end

	-- Per-resource tallies: prove the added mix keeps the SOURCE (vanilla) proportions --
	-- templates are drawn uniformly, so added/source should match per type up to sampling noise.
	local src_by_type, added_by_type = {}, {}
	for _, t in ipairs(templates) do
		local res = tostring(t.resource or t.class or "?")
		src_by_type[res] = (src_by_type[res] or 0) + 1
	end

	local added = 0
	local pool_final = 0
	local registered_at_creation = 0
	RunPaused("SuperBigMapDepositTopUp", function()
		-- Frame candidate pool (terrain-bucketed), same as EvenOutDepositDensity: sampled tiles
		-- OUTSIDE the source quadrant, so the added deposits fill the sparse frame.
		local buckets, shared_candidates, pool = {}, {}, 0
		local MAX_SAMPLES, MAX_POOL = 8000, 4000
		for _ = 1, MAX_SAMPLES do
			if pool >= MAX_POOL then break end
			local x = lo_x + RandInt(span_x)
			local y = lo_y + RandInt(span_y)
			-- Spread across the whole UNSCANNED map (rendered source AND mirrored frame),
			-- excluding only the scanned start sector: this keeps relocated/added markers from
			-- piling into the frame L-strip (which made one region far denser than the rest), and
			-- prevents hidden markers landing in an already-scanned sector where they'd never reveal.
			-- The surface outer ring is reserved for anomaly top-up extras.
			local sector = SectorAtPoint(map, x, y)
			local reserved_ring = not IsUndergroundMap(map) and IsInOuterSectorRing(map, x, y,
				cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3)
			if sector and not SectorIsScanned(sector) and not reserved_ring then
				local pt = point(x, y)
				if CanReceiveDeposit(map, pt) then
					local tt = TerrainTypeAt(map, pt) or -1
					local b = buckets[tt]; if not b then b = {}; buckets[tt] = b end
					local candidate = { x = x, y = y, terrain_type = tt }
					b[#b + 1] = candidate
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
		local function take(tt)
			local b = tt ~= nil and buckets[tt] or nil
			if b and #b > 0 then
				local i = RandInt(#b) + 1
				local c = b[i]
				table.remove(b, i)
				c.used = true
				return c
			end
			return nil
		end
		local function take_any()
			for _, b in pairs(buckets) do
				if #b > 0 then
					local i = RandInt(#b) + 1
					local c = b[i]
					table.remove(b, i)
					c.used = true
					return c
				end
			end
			return nil
		end

		for _ = 1, shortfall do
			local template = templates[RandInt(#templates) + 1]
			local tpos = ObjectPos(template)
			if tpos and type(tpos.xy) == "function" then
				local tt = TerrainTypeAt(map, tpos) or -1
				local c = take(tt) or take_any()
				if not c then break end   -- pool exhausted
				local tx, ty = tpos:xy()
				local clone = clone_fn(map, template, point(c.x - tx, c.y - ty, 0))
				if clone and type(clone) == "table" then
					added = added + 1
					local res = tostring(template.resource or template.class or "?")
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
				end
			end
		end
	end)
	Log("topped up resource deposits to map-size proportions", {
		area_factor = string.format("%.3f", area_factor),
		source_count = source_count, total_before = total_current,
		target = target, added = added, templates = #templates,
		map = tostring(map.name), pool = pool_final,
		registered_at_creation = registered_at_creation,
		source_mix = TallyString(src_by_type),
		added_mix = TallyString(added_by_type),
	})
	DepositRules.LogDistributionReport(map, "after deposit top-up")
end

-- POST-GENERATION anomaly top-up (config TOPUP_ANOMALIES). Raises the ANOMALY population
-- to vanilla density x area WITHOUT touching the generator: the previous in-generation count
-- scaling (sbm_rmg_placement) shifted the generator's random stream, so the same coordinates
-- produced a DIFFERENT map than vanilla (terrain prefabs at other positions/rotations) -- the
-- user requires bit-identical generation, so RmgPlacement.Begin is now skipped in stretch mode
-- and the scaling happens here instead. Clones existing anomaly markers: CloneObjectAtOffset's
-- CopyProperties preserves the CATEGORY (sequence / tech_action); the actual reward resolves at
-- scan time, and breakthroughs remain pool-capped by the game (City trims extras) -- the same
-- safety arguments as the original design. Surface extras are placed in the outer sector ring,
-- hidden + sector-registered so a real scan reveals them. Underground extras retain whole-map
-- placement because there is no surface mountain-edge ring there. Surface candidates must also
-- be buildable, and random selection is biased toward valleys between higher terrain.
function DepositRules.TopUpAnomalies(map)
	if cfg().TOPUP_ANOMALIES ~= true then return end
	map = map or Global("CurrentMap")
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
	-- Baseline = generator-output anomaly markers (non-clones); counting clones in total_current
	-- keeps the target ABSOLUTE, so re-runs are no-ops.
	local total_current = 0
	local templates = {}
	pcall(map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(marker)
		if not marker then return end
		total_current = total_current + 1
		if not marker.SuperBigMapQuadrantClone then
			templates[#templates + 1] = marker
		end
	end)
	local target = math.floor(#templates * area_factor + 0.5)
	local shortfall = target - total_current
	if shortfall <= 0 or #templates == 0 then
		Log("anomaly top-up: nothing to add", {
			total_current = total_current, templates = #templates, target = target,
			shortfall = shortfall, area_factor = string.format("%.3f", area_factor),
		})
		return
	end
	-- Per-category tallies (class + tech_action/sequence distinguish breakthrough / event /
	-- tech-unlock / free-tech): prove the added mix keeps the source (vanilla) proportions.
	local function AnomalyCategory(marker)
		local cat = tostring(marker.class or "?")
		local action = marker.tech_action or (marker.sequence and "sequence") or nil
		if action then cat = cat .. "/" .. tostring(action) end
		return cat
	end
	local src_by_cat, added_by_cat = {}, {}
	for _, t in ipairs(templates) do
		local cat = AnomalyCategory(t)
		src_by_cat[cat] = (src_by_cat[cat] or 0) + 1
	end

	local added = 0
	local pool_final = 0
	local reused_pool = false
	local edge_debug = false
	local edge_ctx
	local added_markers = {}
	local ring_sectors = math.max(0, math.floor(cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3))
	local surface_edge_ring = not IsUndergroundMap(map) and ring_sectors > 0
	local perimeter_phase = surface_edge_ring and ((RandInt(1000000) + 0.0) / 1000000) * 4 or 0
	local perimeter_spacing = surface_edge_ring and (4.0 / shortfall) or 0
	local function arc_distance(a, b)
		local d = math.abs((a or 0) - (b or 0))
		return math.min(d, 4 - d)
	end
	local edge_stats = {
		sampled_by_edge = {}, sampled_by_source_region = {}, accepted_by_edge = {},
		accepted_by_sector = {}, rejected_by_reason = {}, selected_by_edge = {},
		selected_by_target_side = {}, selected_by_nearest_side = {}, selected_by_scope = {},
		added_by_edge = {}, added_by_sector = {}, final_by_edge = {}, final_by_nearest_side = {},
		final_by_sector = {}, ring_predicate_comparison = {},
	}
	RunPaused("SuperBigMapAnomalyTopUp", function()
		local candidates = {}
		local MAX_SAMPLES, MAX_POOL = 6000, 2500
		edge_debug = surface_edge_ring and TopUpEdgeLogOn()
		-- Build the live, index-base-independent edge context for production placement as well as
		-- diagnostics. The previous global random draw had no per-side quota: a valid pool could
		-- contain all four sides yet the small top-up draw could leave one or two sides empty.
		edge_ctx = surface_edge_ring and BuildTopUpEdgeDebugContext(map, ring_sectors) or nil
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
				local legacy_ring = IsInOuterSectorRing(map, mx, my, ring_sectors)
				local observed_ring = edge ~= "interior"
				TopUpEdgeLog("existing anomaly marker", {
					n = marker_n, marker = tostring(marker), class = tostring(marker.class),
					category = AnomalyCategory(marker), clone = tostring(marker.SuperBigMapQuadrantClone == true),
					x = mx, y = my, sector = tostring(sector and sector.id),
					col = tostring(sector and sector.col), row = tostring(sector and sector.row),
					status = tostring(sector and sector.status), edge = edge, source_region = source_region,
					legacy_ring = tostring(legacy_ring), observed_ring = tostring(observed_ring),
					ring_predicates_agree = tostring(legacy_ring == observed_ring),
					distance_left = mx, distance_right = tostring(edge_ctx.map_w and (edge_ctx.map_w - mx)),
					distance_top = my, distance_bottom = tostring(edge_ctx.map_h and (edge_ctx.map_h - my)),
					x_minus_source_edge = tostring(edge_ctx.source_w and (mx - edge_ctx.source_w)),
					y_minus_source_edge = tostring(edge_ctx.source_h and (my - edge_ctx.source_h)),
				})
			end)
			TopUpEdgeLog("top-up target", {
				total_before = total_current, templates = #templates, target = target, shortfall = shortfall,
				area_factor = string.format("%.3f", area_factor), max_samples = MAX_SAMPLES,
				max_pool = MAX_POOL, valley_choices = cfg().TOPUP_ANOMALY_VALLEY_CHOICES or 4,
				perimeter_phase = tostring(perimeter_phase), perimeter_spacing = tostring(perimeter_spacing),
			})
		end
		local cached = not surface_edge_ring and CachedTopUpCandidates(map)
		if cached then
			for _, c in ipairs(cached) do
				if not c.used then candidates[#candidates + 1] = c end
			end
			reused_pool = #candidates > 0
		end
		for sample_n = 1, reused_pool and 0 or MAX_SAMPLES do
			if #candidates >= MAX_POOL then break end
			local x = lo_x + RandInt(span_x)
			local y = lo_y + RandInt(span_y)
			local sector = SectorAtPoint(map, x, y)
			local candidate_edge, candidate_source_region
			if edge_ctx then
				candidate_edge, candidate_source_region = DescribeTopUpEdge(edge_ctx, sector, x, y)
			end
			local in_target_area = not surface_edge_ring or IsInOuterSectorRing(map, x, y, ring_sectors)
			local scanned = sector and SectorIsScanned(sector) or false
			local can_receive, buildable, valley_score = false, false, 0
			local rejection
			if not sector then
				rejection = "no_sector"
			elseif scanned then
				rejection = "sector_scanned"
			elseif not in_target_area then
				rejection = "outside_legacy_ring"
			else
				local pt = point(x, y)
				can_receive = CanReceiveDeposit(map, pt)
				buildable = not surface_edge_ring or IsBuildableAt(map, pt)
				if not can_receive then
					rejection = "not_passable_or_too_steep"
				elseif not buildable then
					rejection = "not_buildable"
				else
					valley_score = surface_edge_ring and ValleyScore(map, pt) or 0
					candidates[#candidates + 1] = {
						x = x, y = y, valley_score = valley_score,
						edge = candidate_edge, source_region = candidate_source_region,
						sector_id = sector and sector.id, col = sector and sector.col,
						row = sector and sector.row, sample_n = sample_n,
					}
					if surface_edge_ring then
						local candidate = candidates[#candidates]
						candidate.perimeter_u, candidate.nearest_side, candidate.edge_depth =
							PerimeterCoordinate(edge_ctx, x, y)
					end
				end
			end
			if edge_debug then
				local edge, source_region = candidate_edge, candidate_source_region
				local observed_ring = edge ~= "interior"
				local perimeter_u, nearest_side, edge_depth = PerimeterCoordinate(edge_ctx, x, y)
				local comparison = "legacy_" .. tostring(in_target_area)
					.. "_observed_" .. tostring(observed_ring)
				IncrementTally(edge_stats.ring_predicate_comparison, comparison)
				IncrementTally(edge_stats.sampled_by_edge, edge)
				IncrementTally(edge_stats.sampled_by_source_region, source_region)
				if rejection then
					IncrementTally(edge_stats.rejected_by_reason, rejection)
				else
					IncrementTally(edge_stats.accepted_by_edge, edge)
					IncrementTally(edge_stats.accepted_by_sector, sector and sector.id)
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
					col = tostring(sector and sector.col), row = tostring(sector and sector.row),
					status = tostring(sector and sector.status), edge = edge, source_region = source_region,
					legacy_ring = tostring(in_target_area), observed_ring = tostring(observed_ring),
					ring_predicates_agree = tostring(in_target_area == observed_ring), scanned = tostring(scanned),
					can_receive = tostring(can_receive), buildable = tostring(buildable),
					terrain_passable = tostring(debug_passable), terrain_flatness = tostring(debug_flatness),
					terrain_buildable = tostring(debug_buildable), terrain_type = tostring(debug_terrain_type),
					terrain_z = tostring(debug_height),
					valley_score = valley_score, accepted = tostring(rejection == nil),
					perimeter_u = tostring(perimeter_u), nearest_side = tostring(nearest_side),
					edge_depth = tostring(edge_depth),
					rejection = tostring(rejection or "none"), pool_after = #candidates,
					distance_left = x, distance_right = tostring(edge_ctx.map_w and (edge_ctx.map_w - x)),
					distance_top = y, distance_bottom = tostring(edge_ctx.map_h and (edge_ctx.map_h - y)),
					x_minus_source_edge = tostring(edge_ctx.source_w and (x - edge_ctx.source_w)),
					y_minus_source_edge = tostring(edge_ctx.source_h and (y - edge_ctx.source_h)),
				})
			end
		end
		pool_final = #candidates
		ProfileStep("anomaly candidate pool ready", {
			candidates = pool_final, reused = reused_pool,
		}, map)
		-- Spread the extras over the COMPLETE perimeter, rather than merely assigning a quota to
		-- eight broad edge/corner labels. A random phase keeps each map seed different; equal arc
		-- spacing then gives every placement its own target around all four sides. For each target,
		-- inspect the nearest N safe/buildable candidates and prefer the best valley among them.
		-- This prevents the right/bottom additions from all clustering in one short stretch while
		-- preserving the three-sector ring and the reachable/buildable-only rules.
		local function target_side(u)
			if u < 1 then return "top" end
			if u < 2 then return "right" end
			if u < 3 then return "bottom" end
			return "left"
		end
		local function perimeter_candidate_index(target_u, choices)
			local nearest = {}
			for i, candidate in ipairs(candidates) do
				local d = arc_distance(candidate.perimeter_u, target_u)
				local insert_at = #nearest + 1
				for n = 1, #nearest do
					if d < nearest[n].distance then insert_at = n; break end
				end
				table.insert(nearest, insert_at, { index = i, distance = d })
				if #nearest > choices then table.remove(nearest) end
			end
			local winner = nearest[1]
			for n = 2, #nearest do
				local incumbent = candidates[winner.index]
				local challenger = candidates[nearest[n].index]
				if (challenger.valley_score or 0) > (incumbent.valley_score or 0) then
					winner = nearest[n]
				end
			end
			return winner and winner.index, winner and winner.distance, #nearest
		end
		for placement_n = 1, shortfall do
			if #candidates == 0 then break end
			local target_u = surface_edge_ring
				and ((perimeter_phase + (placement_n - 1) * perimeter_spacing) % 4) or nil
			local preferred_side = target_u and target_side(target_u) or nil
			local choices = surface_edge_ring
				and math.max(1, math.floor(cfg().TOPUP_ANOMALY_VALLEY_CHOICES or 4)) or 1
			local ci, arc_gap, matching_count
			if surface_edge_ring then
				ci, arc_gap, matching_count = perimeter_candidate_index(target_u, choices)
			else
				ci, arc_gap, matching_count = RandInt(#candidates) + 1, 0, #candidates
			end
			local selection_scope = surface_edge_ring and "nearest_perimeter_arc" or "whole_map"
			if edge_debug then
				local initial = candidates[ci]
				TopUpEdgeLog("placement choice initial", {
					placement = placement_n, choice = 1, candidate_index = ci,
					sample_n = tostring(initial.sample_n), x = initial.x, y = initial.y,
					sector = tostring(initial.sector_id), col = tostring(initial.col), row = tostring(initial.row),
					edge = tostring(initial.edge), source_region = tostring(initial.source_region),
					valley_score = initial.valley_score, pool_size = #candidates,
					preferred_side = tostring(preferred_side), target_perimeter_u = tostring(target_u),
					candidate_perimeter_u = tostring(initial.perimeter_u), arc_gap = tostring(arc_gap),
					nearest_side = tostring(initial.nearest_side), edge_depth = tostring(initial.edge_depth),
					selection_scope = selection_scope, nearest_candidates_considered = matching_count,
				})
			end
			local c = candidates[ci]
			table.remove(candidates, ci)
			c.used = true
			if edge_debug then
				IncrementTally(edge_stats.selected_by_edge, c.edge)
				IncrementTally(edge_stats.selected_by_target_side, preferred_side)
				IncrementTally(edge_stats.selected_by_nearest_side, c.nearest_side)
				IncrementTally(edge_stats.selected_by_scope, selection_scope)
				TopUpEdgeLog("placement candidate selected", {
					placement = placement_n, candidate_index = ci, sample_n = tostring(c.sample_n),
					x = c.x, y = c.y, sector = tostring(c.sector_id), col = tostring(c.col), row = tostring(c.row),
					edge = tostring(c.edge), source_region = tostring(c.source_region),
					valley_score = c.valley_score, pool_remaining = #candidates,
					preferred_side = tostring(preferred_side), target_perimeter_u = tostring(target_u),
					candidate_perimeter_u = tostring(c.perimeter_u), arc_gap = tostring(arc_gap),
					nearest_side = tostring(c.nearest_side), edge_depth = tostring(c.edge_depth),
					selection_scope = selection_scope, nearest_candidates_considered = matching_count,
				})
			end
			local template = templates[RandInt(#templates) + 1]
			local tpos = ObjectPos(template)
			if tpos and type(tpos.xy) == "function" then
				local tx, ty = tpos:xy()
				local clone = clone_fn(map, template, point(c.x - tx, c.y - ty, 0))
				if clone and type(clone) == "table" then
					added = added + 1
					clone.SuperBigMapEdgeTopUp = surface_edge_ring or nil
					clone.SuperBigMapEdgeTopUpPlacement = surface_edge_ring and placement_n or nil
					clone.SuperBigMapEdgeTopUpTargetU = surface_edge_ring and target_u or nil
					added_markers[#added_markers + 1] = clone
					local cat = AnomalyCategory(template)
					added_by_cat[cat] = (added_by_cat[cat] or 0) + 1
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
								template = tostring(template), category = cat, x = c.x, y = c.y,
								sector = tostring(sec and sec.id), col = tostring(sec and sec.col), row = tostring(sec and sec.row),
								edge = tostring(c.edge), source_region = tostring(c.source_region),
								registered = tostring(registered), added_total = added,
							})
						end
					end
				elseif edge_debug then
					TopUpEdgeLog("placement clone result", {
						placement = placement_n, clone = tostring(clone), clone_ok = "false",
						template = tostring(template), category = AnomalyCategory(template),
						x = c.x, y = c.y, sector = tostring(c.sector_id), edge = tostring(c.edge),
					})
				end
			elseif edge_debug then
				TopUpEdgeLog("placement clone skipped", {
					placement = placement_n, reason = "template_position_unavailable",
					template = tostring(template), x = c.x, y = c.y, sector = tostring(c.sector_id),
					edge = tostring(c.edge),
				})
			end
		end
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
				IncrementTally(edge_stats.final_by_sector, sector and sector.id)
				TopUpEdgeLog("final live clone audit", {
					n = n, clone = tostring(clone), placement = tostring(clone.SuperBigMapEdgeTopUpPlacement),
					x = x, y = y, sector = tostring(sector and sector.id), col = tostring(sector and sector.col),
					row = tostring(sector and sector.row), status = tostring(sector and sector.status),
					edge = edge, nearest_side = nearest_side, edge_depth = tostring(edge_depth),
					perimeter_u = tostring(perimeter_u), target_perimeter_u = tostring(clone.SuperBigMapEdgeTopUpTargetU),
					arc_gap = tostring(arc_distance(perimeter_u, clone.SuperBigMapEdgeTopUpTargetU)),
					source_region = source_region, in_outer_ring = tostring(IsInOuterSectorRing(map, x, y, ring_sectors)),
					registered = tostring(registered), is_placed = tostring(clone.is_placed),
					revealed = tostring(clone.revealed), placed_obj = tostring(clone.placed_obj),
				})
			end
		end
		TopUpEdgeLog("END surface anomaly edge-distribution trace", {
			total_before = total_current, target = target, requested = shortfall, added = added,
			pool_initial = pool_final, sampled_by_edge = TallyString(edge_stats.sampled_by_edge),
			sampled_by_source_region = TallyString(edge_stats.sampled_by_source_region),
			accepted_by_edge = TallyString(edge_stats.accepted_by_edge),
			accepted_by_sector = TallyString(edge_stats.accepted_by_sector),
			rejected_by_reason = TallyString(edge_stats.rejected_by_reason),
			ring_predicate_comparison = TallyString(edge_stats.ring_predicate_comparison),
			selected_by_edge = TallyString(edge_stats.selected_by_edge),
			selected_by_target_side = TallyString(edge_stats.selected_by_target_side),
			selected_by_nearest_side = TallyString(edge_stats.selected_by_nearest_side),
			selected_by_scope = TallyString(edge_stats.selected_by_scope),
			added_by_edge = TallyString(edge_stats.added_by_edge),
			added_by_sector = TallyString(edge_stats.added_by_sector),
			final_by_edge = TallyString(edge_stats.final_by_edge),
			final_by_nearest_side = TallyString(edge_stats.final_by_nearest_side),
			final_by_sector = TallyString(edge_stats.final_by_sector),
			perimeter_phase = tostring(perimeter_phase), perimeter_spacing = tostring(perimeter_spacing),
		})
	end
	Log("topped up anomalies to map-size proportions (post-gen)", {
		area_factor = string.format("%.3f", area_factor),
		total_before = total_current, target = target, added = added, templates = #templates,
		map = tostring(map.name), pool = pool_final,
		reused_pool = reused_pool,
		surface_edge_ring = not IsUndergroundMap(map),
		edge_ring_sectors = cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3,
		valley_choices = cfg().TOPUP_ANOMALY_VALLEY_CHOICES or 4,
		source_mix = TallyString(src_by_cat),
		added_mix = TallyString(added_by_cat),
	})
end

IncrementTally = function(tbl, key)
	key = tostring(key or "?")
	tbl[key] = (tbl[key] or 0) + 1
end

-- Build an index-base-independent description of the live surface sector grid. The production
-- ring predicate below historically assumes a particular row/column base; this forensic context
-- records the observed minima/maxima so the trace can expose a one-sided off-by-one directly.
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
	local grid = city and city.MapSectors
	if type(grid) == "table" then
		for outer_key, line in pairs(grid) do
			if type(line) == "table" then
				for inner_key, sector in pairs(line) do
					local col, row = type(sector) == "table" and sector.col, type(sector) == "table" and sector.row
					if type(col) == "number" and type(row) == "number" then
						ctx.min_col = ctx.min_col == nil and col or math.min(ctx.min_col, col)
						ctx.max_col = ctx.max_col == nil and col or math.max(ctx.max_col, col)
						ctx.min_row = ctx.min_row == nil and row or math.min(ctx.min_row, row)
						ctx.max_row = ctx.max_row == nil and row or math.max(ctx.max_row, row)
						ctx.sectors[#ctx.sectors + 1] = {
							id = sector.id, col = col, row = row, status = sector.status,
							outer_key = outer_key, inner_key = inner_key,
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
	TopUpEdgeLog("BEGIN surface anomaly edge-distribution trace", {
		map = tostring(map and map.name), map_w = tostring(map_w), map_h = tostring(map_h),
		source_w = tostring(ctx.source_w), source_h = tostring(ctx.source_h), ring_sectors = ring_sectors,
		sector_count = #ctx.sectors, min_col = tostring(ctx.min_col), max_col = tostring(ctx.max_col),
		min_row = tostring(ctx.min_row), max_row = tostring(ctx.max_row), cols = ctx.cols, rows = ctx.rows,
		legacy_thresholds = "col<=" .. tostring(ring_sectors) .. " col>" .. tostring(ctx.cols - ring_sectors)
			.. " row<=" .. tostring(ring_sectors) .. " row>" .. tostring(ctx.rows - ring_sectors),
		observed_thresholds = "col<=" .. tostring(ctx.min_col and (ctx.min_col + ring_sectors - 1))
			.. " col>=" .. tostring(ctx.max_col and (ctx.max_col - ring_sectors + 1))
			.. " row<=" .. tostring(ctx.min_row and (ctx.min_row + ring_sectors - 1))
			.. " row>=" .. tostring(ctx.max_row and (ctx.max_row - ring_sectors + 1)),
	})
	for n, s in ipairs(ctx.sectors) do
		TopUpEdgeLog("sector topology", {
			n = n, id = tostring(s.id), col = s.col, row = s.row, status = tostring(s.status),
			outer_key = tostring(s.outer_key), inner_key = tostring(s.inner_key),
		})
	end
	return ctx
end

DescribeTopUpEdge = function(ctx, sector, x, y)
	local col, row = sector and sector.col, sector and sector.row
	local sides = {}
	if type(col) == "number" and type(row) == "number"
		and ctx.min_col ~= nil and ctx.min_row ~= nil then
		if col <= ctx.min_col + ctx.ring - 1 then sides[#sides + 1] = "left" end
		if col >= ctx.max_col - ctx.ring + 1 then sides[#sides + 1] = "right" end
		if row <= ctx.min_row + ctx.ring - 1 then sides[#sides + 1] = "top" end
		if row >= ctx.max_row - ctx.ring + 1 then sides[#sides + 1] = "bottom" end
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

-- Clockwise coordinate around the physical map perimeter: top=[0,1), right=[1,2),
-- bottom=[2,3), left=[3,4). A corner candidate is assigned to its nearest physical side.
-- Using world distances here makes distribution independent of sector letters, row labels,
-- storage order, and any UI orientation convention.
PerimeterCoordinate = function(ctx, x, y)
	local map_w, map_h = ctx and ctx.map_w, ctx and ctx.map_h
	if type(map_w) ~= "number" or type(map_h) ~= "number" or map_w <= 0 or map_h <= 0
		or type(x) ~= "number" or type(y) ~= "number" then
		return nil, "unknown", nil
	end
	local choices = {
		{ side = "top", distance = y, u = x / map_w },
		{ side = "right", distance = map_w - x, u = 1 + y / map_h },
		{ side = "bottom", distance = map_h - y, u = 2 + (map_w - x) / map_w },
		{ side = "left", distance = x, u = 3 + (map_h - y) / map_h },
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
-- EffectDeposit subclasses are deliberately excluded.
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
	map = map or Global("CurrentMap")
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
		return
	end

	local added_by_type = {}
	local pool_final = 0
	local reused_pool = false
	RunPaused("SuperBigMapEffectDepositTopUp", function()
		local candidates = {}
		local MAX_SAMPLES, MAX_POOL = 6000, 2500
		local cached = CachedTopUpCandidates(map)
		if cached then
			for _, c in ipairs(cached) do
				if not c.used then candidates[#candidates + 1] = c end
			end
			reused_pool = #candidates > 0
		end
		for _ = 1, reused_pool and 0 or MAX_SAMPLES do
			if #candidates >= MAX_POOL then break end
			local x, y = lo_x + RandInt(span_x), lo_y + RandInt(span_y)
			local sector = SectorAtPoint(map, x, y)
			local reserved_ring = not IsUndergroundMap(map) and IsInOuterSectorRing(map, x, y,
				cfg().TOPUP_ANOMALY_OUTER_RING_SECTORS or 3)
			if sector and (IsUndergroundMap(map) or not SectorIsScanned(sector)) and not reserved_ring then
				local pt = point(x, y)
				if CanReceiveDeposit(map, pt) then candidates[#candidates + 1] = { x = x, y = y } end
			end
		end
		pool_final = #candidates
		ProfileStep("effect candidate pool ready", {
			candidates = pool_final, reused = reused_pool,
		}, map)
		for _, deposit_type in ipairs(types) do
			local templates = templates_by_type[deposit_type]
			local shortfall = target_by_type[deposit_type] - (current_by_type[deposit_type] or 0)
			for _ = 1, math.max(0, shortfall) do
				if #candidates == 0 then break end
				local ci = RandInt(#candidates) + 1
				local c = candidates[ci]
				table.remove(candidates, ci)
				c.used = true
				local template = templates[RandInt(#templates) + 1]
				local tpos = ObjectPos(template)
				if tpos and type(tpos.xy) == "function" then
					local tx, ty = tpos:xy()
					local clone = clone_fn(map, template, point(c.x - tx, c.y - ty, 0))
					if clone and type(clone) == "table" then
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
					end
				end
			end
		end
	end)
	Log("topped up effect deposits to map-size proportions (post-gen)", {
		area_factor = string.format("%.3f", area_factor), current = TallyString(current_by_type),
		target = TallyString(target_by_type), added = TallyString(added_by_type),
		map = tostring(map.name), pool = pool_final, reused_pool = reused_pool,
	})
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
	for _, marker in ipairs(markers) do
		local pos = ObjectPos(marker)
		if not pos or not CanReceiveDeposit(map, pos) then
			invalid[#invalid + 1] = { marker = marker, pos = pos }
		end
	end
	if #invalid == 0 then
		local stats = {
			checked = #markers, invalid = 0, moved = 0, unresolved = 0,
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

	local is_valid = Global("IsValid")
	local concrete_moves = {}
	local moved, moved_placed, unresolved = 0, 0, 0
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
				local placed = marker.placed_obj
				local placed_valid = placed and (type(is_valid) ~= "function" or SafeCall(is_valid, placed) == true)
				if placed_valid and type(placed.SetPos) == "function" and pcall(placed.SetPos, placed, successful_pos) then
					moved_placed = moved_placed + 1
				end
				if IsConcreteTerrainDepositMarker(marker) and old_pos and type(old_pos.xy) == "function" then
					local tx, ty = successful_pos:xy()
					concrete_moves[#concrete_moves + 1] = {
						from = { x = ox, y = oy }, to = { x = tx, y = ty },
						paint_now = marker.is_placed == true,
					}
				end
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
		checked = #markers, invalid = #invalid, moved = moved, moved_placed = moved_placed,
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

-- TEMP inspection helper (config UNDERGROUND_REVEAL_ALL_DEPOSITS): force-place and reveal every
-- deposit/anomaly on a map -- runs vanilla RevealDeposits over all unplaced markers (spawning
-- their deposits/anomalies) and flips `revealed` on every scan-gated spawned object. Used on the
-- underground map so the stretched layout can be inspected without exploring. Tunnel-entrance
-- markers are EXCLUDED: their PlaceDeposit starts scripted passage sequences, and mass-triggering
-- those would spawn entrance structures prematurely (they spawn via their normal path instead).
function DepositRules.ForceRevealAllOnMap(map)
	map = map or Global("CurrentMap")
	if not map or type(map.MapForEach) ~= "function" then return end
	local reveal_deposits = Global("RevealDeposits")
	local markers = {}
	pcall(map.MapForEach, map, "map", "DepositMarker", function(m)
		if m and m.is_placed ~= true and not IsKindOfSafe(m, "SurfaceUndergroundTunnelMarker") then
			markers[#markers + 1] = m
		end
	end)
	local placed_ok = false
	if type(reveal_deposits) == "function" and #markers > 0 then
		placed_ok = pcall(reveal_deposits, markers)
	end
	local revealed = 0
	local function reveal_class(cls)
		pcall(map.MapForEach, map, "map", cls, function(obj)
			if obj and IsScanGatedDeposit(obj) and obj.revealed ~= true then
				SetRevealedState(obj, true)
				revealed = revealed + 1
			end
		end)
	end
	reveal_class("SubsurfaceDeposit")
	reveal_class("SubsurfaceAnomaly")
	Log("TEMP force-revealed all deposits/anomalies on map", {
		map = tostring(map.name or (map.mapdata and map.mapdata.id) or "?"),
		markers_placed = #markers, place_ok = placed_ok, revealed_objects = revealed,
	})
end

function DepositRules.OnSectorScanned(_status, sector)
	if not Enabled() then return end
	if type(sector) ~= "table" then return end
	local map = (type(sector.GetMap) == "function") and SafeCall(sector.GetMap, sector) or Global("CurrentMap")
	local area = sector.area
	if not map or not area or type(map.MapForEach) ~= "function" then return end
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

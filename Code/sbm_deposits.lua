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

local function Enabled()
	return cfg().HIDE_CLONED_DEPOSITS_UNTIL_SCAN ~= false
end

local function Log(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then DebugLog.Info("Deposits", message, data) end
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
local function CanReceiveDeposit(map, pt)
	return PassableAt(map, pt) and (FlatnessAt(map, pt) or 0) >= FLATNESS_MIN
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
function DepositRules.RegisterClonedMarkers(map)
	map = map or Global("CurrentMap")
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
-- generates the terrain patch), so no manual imprint is needed. Gated by ENABLE_DEPOSIT_TOPUP.
function DepositRules.TopUpDeposits(map)
	if cfg().ENABLE_DEPOSIT_TOPUP ~= true then return end
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
	local total_current, source_count = 0, 0
	local templates = {}
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not (marker and IsResourceDepositMarker(marker)) then return end
		total_current = total_current + 1
		local pos = ObjectPos(marker)
		if not pos or type(pos.xy) ~= "function" then return end
		local px, py = pos:xy()
		if px == nil then return end
		if px < src_w and py < src_h then
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

	local added = 0
	RunPaused("SuperBigMapDepositTopUp", function()
		-- Frame candidate pool (terrain-bucketed), same as EvenOutDepositDensity: sampled tiles
		-- OUTSIDE the source quadrant, so the added deposits fill the sparse frame.
		local buckets, pool = {}, 0
		local MAX_SAMPLES, MAX_POOL = 8000, 4000
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
					if type(clone.SetPos) == "function" then
						local pt = point(c.x, c.y)
						if type(pt.SetTerrainZ) == "function" then
							local ok, snapped = pcall(pt.SetTerrainZ, pt, map)
							if ok and snapped then pt = snapped end
						end
						pcall(clone.SetPos, clone, pt)
					end
				end
			end
		end
	end)
	Log("topped up resource deposits to map-size proportions", {
		area_factor = string.format("%.3f", area_factor),
		source_count = source_count, total_before = total_current,
		target = target, added = added, templates = #templates,
	})
	DepositRules.LogDistributionReport(map, "after deposit top-up")
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


SuperBigMap.DepositRules = DepositRules

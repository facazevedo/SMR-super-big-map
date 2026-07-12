-- Super Big Map -- RMG deposit/anomaly placement auto-fit (terrain-safe).
--
-- PROBLEM: on an expanded map the vanilla random map generator under-places
-- resource deposits and anomalies -- "Failed to find a place" / "Could not find
-- place" for deposits (e.g. 13 of 23 concrete) and "Calculated grid weight is 0.
-- Failed to find any" for subsurface anomalies (FreeTech can hit 0). The full set
-- a normal map of the same preset receives does not fit.
--
-- ROOT CAUSE (confirmed read-only against the local game files,
-- ModTools/Src/Lua/RandomMap/RandomMapGenerator.lua):
--   * Every deposit/anomaly layer draws positions from `play_zone`
--     (zones surf/subs/terr at L3364-3367; the subsurface Anomaly layer at L3385).
--   * `play_zone` = GetPlayableArea(height, PassBorder, invalid_mask) where
--     invalid_mask = NOT gen_zone (Proc_ResolveBuildable L3202-3217). So the
--     placement zone is clipped to gen_zone -- the playable terrain-type region --
--     which on an expanded allocation covers only a fraction of the work grid.
--   * On top of that, each layer erodes a `self.DepBorder*`-wide margin off the
--     already-small zone (RegisterDepositLayer, L3334: GridMask(zone, ...,
--     border/work_step + 1, ...)). The anomaly layer's border DEFAULTS to
--     max_border, which falls back to self.DepBorderSubs (L3384, default
--     6*work_step) -- on the shrunken subsurface zone that erosion can erase the
--     whole anomaly region -> "grid weight is 0" -> FreeTech 0.
--   * Deposit/anomaly COUNTS are fixed by the preset, while spacing
--     (preset.RepulseSame, self.AnomalySpacing) is an ABSOLUTE world distance, so a
--     fraction-size zone cannot seat the full count.
--
-- WHY WIDENING gen_zone IS NOT THE FIX: gen_zone also drives prefab/terrace
-- placement (L1649-2009), so widening it (e.g. by rewriting the type grid)
-- redistributes prefabs and flattens the terrain. That coupling is irreducible from
-- the mod -- gen_zone is a base-game local built once and never mutated between the
-- terrain-shaping phase and the placement phase.
--
-- FIX (terrain-safe, reversible): the border and spacing knobs are PLACEMENT-ONLY --
-- none of them feed gen_zone, the prefab pass, or the heightmap, so the terrain is
-- shaped exactly as it is today. Just before the generator runs on a mod-expanded
-- map we:
--   * measure gen_zone coverage the same way the generator builds it (the non-Border
--     entries of self.texture_setup over the type grid, restricted to the generated
--     span), then
--   * zero the per-layer deposit/anomaly borders (self.DepBorder*), and
--   * scale spacing/repulse (self.*Spacing / self.*Repulse* and the shared
--     Presets.ResourcePreset.Default *Repulse*/*Spacing) by sqrt(coverage) -- area
--     scales with spacing^2, so sqrt(coverage) seats the full fixed count in the
--     coverage-fraction of area.
-- Originals are snapshotted and restored immediately after DoGenerate returns
-- (idempotent, single synchronous generation thread). Every scaled value is rounded
-- to a multiple of work_step (the generator asserts divisibility, L3330-3332) and
-- floored so it never reaches 0.
--
-- This never re-runs the generator and never touches terrain grids; disable the
-- ENABLE_RMG_PLACEMENT_FIX config flag to restore exact vanilla placement.

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
	return cfg().ENABLE_RMG_PLACEMENT_FIX == true
end

local function Log(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then DebugLog.Info("RmgPlacement", message, data) end
end

-- Placement-only properties scaled toward a tighter packing (absolute world
-- distances, granularity work_step in the generator). NONE feed gen_zone/terrain.
local SPACING_PROPS = {
	"AnomalySpacing", "AnomalyRepulseSubs", "AnomalyRepulseAll",
	"EffectDepSpacing", "EffectDepRepulse", "EffectDepRepulseAll",
}

-- Anomaly COUNT properties on the generator instance (consumed at gen time,
-- RandomMapGenerator.lua ~3262-3291). Scaling these up before DoGenerate makes the generator
-- place proportionally more anomalies for the bigger map, WITH correct unique rewards: the
-- generator only stamps a category (tech_action/sequence); the reward resolves at scan time,
-- and the breakthrough pool self-trims to the available set at load (City:InitBreakThroughAnomalies).
-- FreeTech/TechUnlock/Event scale freely; breakthrough plateaus at the pool (safe). Each is a
-- plain number or a {from,to} range.
local COUNT_PROPS = {
	"AnomFreeTechCount", "AnomEventCount", "AnomTechUnlockCount", "AnomBreakthroughCount",
	"BonusCountFreeTech", "BonusCountEvent", "BonusCountBreakthrough",
}

-- Per-layer placement borders eroded off play_zone (L3334/L3384). Zeroing these
-- recovers the candidate cells the erosion ate -- the FreeTech=0 culprit.
local BORDER_PROPS = {
	"DepBorderSurf", "DepBorderSubs", "DepBorderTerr",
	"DepBorderAnomaly", "DepBorderEffects",
}

-- Per-resource deposit spacing lives on the shared ResourcePreset (read at L3373/
-- L3379), so it is scaled on the preset table and restored afterwards.
local PRESET_SPACING_FIELDS = { "RepulseSame", "RepulseSameLayer", "RepulseAll", "ClusterSpacing" }

-- Active relaxation snapshot for the in-flight generation (one synchronous thread).
local active = nil

-- Stride for the gen-zone coverage sample: read every Nth type-grid cell on each axis
-- instead of all of them. This is the fine terrain TYPE grid (millions of cells at
-- TypeTileSize resolution), NOT the 20x20 sector grid -- so the stride is a sub-sampling
-- rate, not a per-sector count. Coverage is a ratio, so a strided sample of hundreds of
-- thousands of cells is statistically identical to the full scan at ~1/stride^2 the work
-- (stride 5 -> ~25x fewer reads). 5 is deliberately coprime with the generator work-step
-- period (const.PrefabWorkRatio = 8) and with the power-of-two grid dimensions, so the
-- sample lattice walks all phases instead of phase-locking to any 8-periodic structure
-- (avoids aliasing bias). A full scan of the 8192-tile expanded type grid is millions of
-- per-cell C calls and dominated expanded-map load time.
local COVERAGE_SAMPLE_STRIDE = 5

local function WorkStep()
	local const_tbl = Global("const")
	if type(const_tbl) ~= "table" then return nil end
	local work_ratio = const_tbl.PrefabWorkRatio
	local type_tile = const_tbl.TypeTileSize
	if type(work_ratio) == "number" and work_ratio > 0
		and type(type_tile) == "number" and type_tile > 0 then
		return work_ratio * type_tile
	end
	return nil
end

-- Area up-scale factor = (full_tiles / generated_source_tiles)^2 -- how many times bigger the
-- expanded 20x20 playable area is than the native source (e.g. (8192/6144)^2 = 1.78). Used to
-- scale anomaly counts to full vanilla density for the larger map. 1.0 if the markers are absent.
local function AreaFactor(map)
	local gen_t = map and map.SuperBigMapGeneratorWidthTiles
	local full_t = map and (map.SuperBigMapDesiredWidthTiles or (map.mapdata and map.mapdata.Width))
	if type(gen_t) == "number" and gen_t > 0 and type(full_t) == "number" and full_t > gen_t then
		local r = full_t * 1.0 / gen_t   -- * 1.0: this runtime truncates integer division
		return r * r
	end
	return 1.0
end

-- Scale a generator COUNT property (plain number OR {from,to}/{[1],[2]} range) by factor,
-- returning a NEW value (never mutates the original, so the snapshot can restore it). Rounds to
-- integers, floored at 1 for plain numbers so a positive count never scales to 0.
local function ScaleCountValue(v, factor)
	if type(v) == "number" then
		return math.max(1, math.floor(v * factor + 0.5))
	end
	if type(v) == "table" then
		local from, to = v.from or v[1], v.to or v[2]
		if type(from) == "number" and type(to) == "number" then
			local nv = {}
			for k, val in pairs(v) do nv[k] = val end
			local nf, nt = math.floor(from * factor + 0.5), math.floor(to * factor + 0.5)
			if v.from ~= nil then nv.from = nf else nv[1] = nf end
			if v.to ~= nil then nv.to = nt else nv[2] = nt end
			return nv
		end
	end
	return v
end

-- Round a scaled distance DOWN to a multiple of work_step (the generator asserts
-- repulse % work_step == 0), but never below one work_step so it stays > 0.
local function RoundToStep(value, step)
	if type(value) ~= "number" or value <= 0 then return value end
	local n = math.floor(value / step)
	if n < 1 then n = 1 end
	return n * step
end

-- Resolve the generation ("gen_zone") terrain-type indices exactly as the generator
-- does: the non-Border entries of self.texture_setup, else self.TTypeGen.
local function GenTypeIndexSet(generator)
	local get_idx = Global("GetTerrainTextureIndex")
	if type(get_idx) ~= "function" then return nil end
	local set, n = {}, 0
	local setup = generator and generator.texture_setup
	if type(setup) == "table" then
		for i = 1, #setup do
			local entry = setup[i]
			if type(entry) == "table" and not entry.Border and entry.Texture then
				local ok, idx = pcall(get_idx, entry.Texture)
				if ok and type(idx) == "number" then set[idx] = true; n = n + 1 end
			end
		end
	end
	if n == 0 and generator and type(generator.TTypeGen) == "string" and generator.TTypeGen ~= "" then
		local ok, idx = pcall(get_idx, generator.TTypeGen)
		if ok and type(idx) == "number" then set[idx] = true; n = n + 1 end
	end
	if n == 0 then return nil end
	return set
end

-- Measure gen_zone coverage = (gen-type cells) / (cells in the generated span). The
-- type grid spans the full allocated buffer; since every gen-type cell lies in the
-- top-left generated region, we count gen-type cells over the whole buffer and divide
-- by the generated-span cell count (gen_fraction * grid cells), giving the coverage
-- the generator effectively sees over its own work grid. Returns coverage in (0,1],
-- or nil if unavailable.
local function MeasureGenZoneCoverage(generator, map)
	local terrain_api = Global("terrain")
	if type(terrain_api) ~= "table" or type(terrain_api.GetTypeGrid) ~= "function" then
		return nil, "type-grid API unavailable"
	end
	local set = GenTypeIndexSet(generator)
	if not set then return nil, "gen terrain types unresolved" end

	local grid = SafeCall(terrain_api.GetTypeGrid, map)
	if not grid or type(grid.size) ~= "function" or type(grid.get) ~= "function" then
		return nil, "type grid not readable"
	end
	local gw, gh = grid:size()
	if type(gw) ~= "number" or gw <= 0 or type(gh) ~= "number" or gh <= 0 then
		return nil, "type grid empty"
	end

	-- Count gen-type cells over the WHOLE buffer, STRIDE-SAMPLED. The generated region is
	-- the top-left corner; the surrounding frame is non-generated (non-gen-type), so every
	-- gen-type cell lies inside the generated span -- which lets us derive the generated-span
	-- coverage analytically (below) instead of guessing a sub-rect. We read every Nth cell on
	-- each axis (COVERAGE_SAMPLE_STRIDE) and scale the sampled count back up to a whole-buffer
	-- estimate; coverage is a ratio, so this matches the full scan to within sampling noise at
	-- ~1/stride^2 the cost.
	local grid_cells = gw * gh
	local stride = (type(COVERAGE_SAMPLE_STRIDE) == "number" and COVERAGE_SAMPLE_STRIDE >= 1)
		and math.floor(COVERAGE_SAMPLE_STRIDE) or 1
	local sampled_matches = 0
	for y = 0, gh - 1, stride do
		for x = 0, gw - 1, stride do
			if set[grid:get(x, y)] then
				sampled_matches = sampled_matches + 1
			end
		end
	end
	local sampled_cells = (math.floor((gw - 1) / stride) + 1) * (math.floor((gh - 1) / stride) + 1)
	-- Scale the sample up to the whole-buffer gen-type count the exact scan would have
	-- produced (sampled density * total cells). * 1.0 forces float (this runtime truncates
	-- integer/integer division). full_content is thus an estimate; the downstream coverage
	-- ratio is stride-independent.
	local full_content = (sampled_cells > 0)
		and math.floor(sampled_matches * 1.0 * grid_cells / sampled_cells + 0.5)
		or 0

	-- The type grid spans the full ALLOCATED buffer, but the generator only generated
	-- (and the player only ever plays) the top-left generated span. play_zone/gen_zone
	-- are evaluated over THAT span, so scale to the generated-span denominator:
	--   gen_fraction = (generated_tiles / allocated_tiles)^2   (area ratio)
	--   coverage     = gen-type cells / (gen_fraction * grid cells)
	-- e.g. 6144 generated in an 8192 buffer -> gen_fraction 0.5625, so a full-buffer
	-- 0.191 becomes ~0.34 over the generated span (and scale sqrt(0.34) ~ 0.58 instead
	-- of the over-tight 0.437 a full-buffer measure gives). Falls back to the whole
	-- buffer if the per-map tile markers are missing.
	local gen_tiles = map and map.SuperBigMapGeneratorWidthTiles
	local full_tiles = map and (map.SuperBigMapDesiredWidthTiles or (map.mapdata and map.mapdata.Width))
	local gen_fraction = 1.0
	if type(gen_tiles) == "number" and gen_tiles > 0 and type(full_tiles) == "number" and full_tiles > gen_tiles then
		-- * 1.0 forces float: this Lua runtime truncates integer/integer division
		-- (6144/8192 -> 0), which would zero gen_fraction and break the coverage path.
		local r = gen_tiles * 1.0 / full_tiles
		gen_fraction = r * r
	end

	local gen_span_cells = math.floor(gen_fraction * grid_cells + 0.5)
	local coverage = nil
	if gen_span_cells > 0 then
		coverage = full_content * 1.0 / gen_span_cells
		if coverage > 1 then coverage = 1.0 end   -- clamp (frame cells can't exceed span)
	end
	local coverage_full = (grid_cells > 0) and (full_content * 1.0 / grid_cells) or nil
	return coverage, nil, {
		grid_w = gw, grid_h = gh,
		sample_stride = stride, sampled_cells = sampled_cells, sampled_matches = sampled_matches,
		gen_cells = full_content, gen_span_cells = gen_span_cells,
		gen_fraction = string.format("%.3f", gen_fraction),
		cov_permille = (gen_span_cells > 0) and math.floor(full_content * 1000 / gen_span_cells) or -1,
		cov_full_permille = (grid_cells > 0) and math.floor(full_content * 1000 / grid_cells) or -1,
		coverage_full = coverage_full and string.format("%.3f", coverage_full) or "n/a",
		gen_tiles = gen_tiles or "n/a", full_tiles = full_tiles or "n/a",
	}
end

local RmgPlacement = {}

-- Begin: snapshot + relax placement knobs for the in-flight generation. Call ONLY on
-- a mod-expanded map, AFTER the DoGenerate size overrides are in place and BEFORE the
-- original DoGenerate runs. Returns true if a relaxation was applied (so End must be
-- called), false otherwise.
function RmgPlacement.Begin(generator, map)
	if not Enabled() then return false end
	-- STRETCH mode: NO in-generation interference at all (user-confirmed determinism
	-- requirement). Any preset-prop change here (spacing, borders, anomaly counts) shifts the
	-- generator's random stream, so the SAME coordinates produce a DIFFERENT map than vanilla --
	-- observed as terrain-feature prefabs (a dried lake) at other positions/rotations and as
	-- run-to-run non-determinism of the tunnel spawners. In stretch the generator runs at native
	-- size with the native play zone, so the mirror-era auto-fit is unnecessary anyway; the
	-- map-size enrichment scaling happens POST-generation instead (TopUpDeposits +
	-- TopUpAnomalies). Mirror mode keeps the auto-fit (its shrunken play zone needs it).
	if tostring(cfg().EXPANSION_FRAME_FILL_MODE or "mirror") == "stretch" then
		Log("Begin skipped: stretch mode -- generator runs bit-identical to vanilla (enrichment moved post-gen)")
		return false
	end
	if active then
		Log("Begin skipped: a relaxation is already active (re-entrant DoGenerate?)")
		return false
	end
	if type(generator) ~= "table" or type(map) ~= "table" then return false end

	local step = WorkStep()
	if not step then
		Log("Begin skipped: work_step (const.PrefabWorkRatio * const.TypeTileSize) unavailable")
		return false
	end

	-- Coverage drives the auto-fit: area scales with spacing^2, so sqrt(coverage)
	-- seats the full fixed count in the coverage-fraction of area. When coverage is
	-- unusable (measurement failed / 0 / >= 1) we fall back to a fixed scale so the
	-- spacing still tightens -- borders-only is NOT enough (the trailing FreeTech
	-- anomalies still starve the subsurface zone). Scaling never exceeds the preset
	-- target counts; it only relieves the spacing constraint, so it is safe to apply
	-- broadly. floor bounds how dense it can get.
	local coverage, why, info = MeasureGenZoneCoverage(generator, map)
	local floor = cfg().RMG_PLACEMENT_SPACING_FLOOR
	floor = (type(floor) == "number" and floor > 0 and floor <= 1) and floor or 0.8
	local squeeze = cfg().RMG_PLACEMENT_EXTRA_SQUEEZE
	squeeze = (type(squeeze) == "number" and squeeze > 0 and squeeze <= 1) and squeeze or 1.0
	local fallback = cfg().RMG_PLACEMENT_FALLBACK_SCALE
	fallback = (type(fallback) == "number" and fallback > 0 and fallback <= 1) and fallback or 0.6

	local scale, scale_basis = 1.0, "none"
	if type(coverage) == "number" and coverage > 0 and coverage < 1 then
		scale = math.sqrt(coverage) * squeeze
		scale_basis = "coverage"
	else
		-- Coverage unusable -> tighten by the fixed fallback so placement still fits.
		scale = fallback * squeeze
		scale_basis = "fallback"
	end
	if scale < floor then scale = floor end
	if scale > 1 then scale = 1 end

	local zero_borders = cfg().RMG_PLACEMENT_ZERO_BORDERS ~= false
	local snapshot = { generator = generator, props = {}, presets = {} }

	-- 1) Zero per-layer placement borders on the generator instance.
	if zero_borders then
		for _, name in ipairs(BORDER_PROPS) do
			local v = generator[name]
			if type(v) == "number" and v ~= 0 then
				snapshot.props[#snapshot.props + 1] = { obj = generator, key = name, value = v }
				generator[name] = 0
			end
		end
	end

	-- 2) Anomaly COUNT scaling: place proportionally MORE anomalies so the bigger map reaches
	-- full vanilla density for its size. Reward-safe (generator stamps a category only; reward
	-- resolves at scan; breakthrough self-trims to the available pool at load). FreeTech/
	-- TechUnlock/Event scale freely; breakthrough plateaus at the pool.
	local anom_scale = 1.0
	if cfg().TOPUP_ANOMALIES == true then
		local override = cfg().ANOMALY_COUNT_SCALE_OVERRIDE
		anom_scale = (type(override) == "number" and override > 0) and override or AreaFactor(map)
		if anom_scale > 1.0 then
			for _, name in ipairs(COUNT_PROPS) do
				local v = generator[name]
				local nv = ScaleCountValue(v, anom_scale)
				if nv ~= v then
					snapshot.props[#snapshot.props + 1] = { obj = generator, key = name, value = v }
					generator[name] = nv
				end
			end
		end
	end

	-- 3) Spacing for the anomaly/effect layers. Base is the coverage-driven `scale`; when the
	-- anomaly COUNT was scaled up, the same gen-zone must hold ~anom_scale x more anomalies, so
	-- tighten spacing by an extra 1/sqrt(anom_scale) (area ~ spacing^2), floored at a lower
	-- dedicated minimum so they fit. RespaceAnomalies later spreads them evenly across the map.
	local spacing_scale = scale
	if anom_scale > 1.0 then
		spacing_scale = scale / math.sqrt(anom_scale)
		local anom_floor = cfg().ANOMALY_COUNT_SPACING_FLOOR
		anom_floor = (type(anom_floor) == "number" and anom_floor > 0 and anom_floor <= 1) and anom_floor or 0.35
		if spacing_scale < anom_floor then spacing_scale = anom_floor end
	end
	if spacing_scale < 0.999 then
		for _, name in ipairs(SPACING_PROPS) do
			local v = generator[name]
			if type(v) == "number" and v > 0 then
				local nv = RoundToStep(v * spacing_scale, step)
				if nv ~= v then
					snapshot.props[#snapshot.props + 1] = { obj = generator, key = name, value = v }
					generator[name] = nv
				end
			end
		end
	end

	-- 4) Per-resource deposit spacing on the shared ResourcePreset table -- OFF by default.
	-- Resource deposits already reach their full preset counts with vanilla spacing once the
	-- borders are zeroed, so scaling them is unnecessary deviation from vanilla. Only enable if
	-- a map ever shows a resource-deposit shortfall. Uses the base (coverage) scale, not the
	-- anomaly-tightened spacing_scale.
	if cfg().RMG_PLACEMENT_SCALE_DEPOSITS == true and scale < 0.999 then
		local presets = Global("Presets")
		local list = type(presets) == "table" and presets.ResourcePreset and presets.ResourcePreset.Default
		if type(list) == "table" then
			for i = 1, #list do
				local preset = list[i]
				if type(preset) == "table" then
					for _, field in ipairs(PRESET_SPACING_FIELDS) do
						local v = preset[field]
						if type(v) == "number" and v > 0 then
							local nv = RoundToStep(v * scale, step)
							if nv ~= v then
								snapshot.presets[#snapshot.presets + 1] = { obj = preset, key = field, value = v }
								preset[field] = nv
							end
						end
					end
				end
			end
		end
	end

	active = snapshot

	if SuperBigMap.DebugLog and SuperBigMap.DebugLog.On and SuperBigMap.DebugLog.On("RmgPlacement") then
		local data = {
			coverage = (type(coverage) == "number") and string.format("%.3f", coverage) or (why or "n/a"),
			scale = string.format("%.3f", scale),
			scale_basis = scale_basis,
			anom_count_scale = string.format("%.3f", anom_scale),
			anom_spacing_scale = string.format("%.3f", spacing_scale),
			work_step = step,
			zeroed_borders = zero_borders,
			props_changed = #snapshot.props,
			presets_changed = #snapshot.presets,
			floor = floor, squeeze = squeeze,
		}
		if type(info) == "table" then
			for k, v in pairs(info) do data[k] = v end
		end
		Log("placement relaxed for expanded-map generation", data)
	end
	return true
end

-- End: restore every snapshotted value and (when logging) report post-gen marker
-- counts so a single run shows placed-vs-expected. Always safe to call.
function RmgPlacement.End(map)
	local snap = active
	active = nil
	if not snap then return end

	for i = 1, #snap.props do
		local e = snap.props[i]
		e.obj[e.key] = e.value
	end
	for i = 1, #snap.presets do
		local e = snap.presets[i]
		e.obj[e.key] = e.value
	end

	if SuperBigMap.DebugLog and SuperBigMap.DebugLog.On and SuperBigMap.DebugLog.On("RmgPlacement") then
		local data = RmgPlacement.CountPlacedMarkers(map or Global("CurrentMap"))
		local expected = RmgPlacement.ExpectedAnomalyRanges(snap.generator)
		for k, v in pairs(expected) do data[k] = v end
		Log("placement restored: placed vs expected", data)
	end
end

-- Read the generator's preset anomaly-count targets off `self` (stable preset props;
-- the realized per-gen counts are randomized locals and not externally readable, so
-- we surface the min..max envelope each type is drawn from). Keys: exp_freetech,
-- exp_event, exp_techunlock, exp_breakthrough. See RandomMapGenerator.lua L3262-3291.
function RmgPlacement.ExpectedAnomalyRanges(generator)
	if type(generator) ~= "table" then return {} end
	-- Decompose a "range" prop ({from,to}) or a plain number into from,to.
	local function part(r)
		if type(r) == "number" then return r, r end
		if type(r) == "table" then return r.from or r[1], r.to or r[2] end
		return nil, nil
	end
	-- base [+ optional bonus range] -> "from..to" (or single value if from==to).
	local function rng(base, bonus)
		local bf, bt = part(base)
		if bf == nil and bt == nil then return "n/a" end
		local nf, nt = part(bonus)
		local from = (bf or 0) + (nf or 0)
		local to = (bt or 0) + (nt or 0)
		if from == to then return tostring(from) end
		return tostring(from) .. ".." .. tostring(to)
	end
	return {
		exp_freetech    = rng(generator.AnomFreeTechCount, generator.BonusCountFreeTech),
		exp_event       = rng(generator.AnomEventCount, generator.BonusCountEvent),
		exp_techunlock  = rng(generator.AnomTechUnlockCount, nil),
		exp_breakthrough = rng(generator.AnomBreakthroughCount, generator.BonusCountBreakthrough),
	}
end

-- Diagnostic: count placed deposit/anomaly markers by kind on the given map. Used by
-- End() under the RmgPlacement debug scope to compare against a vanilla run. Anomaly
-- markers are all SubsurfaceAnomalyMarker; their type is read back from the lua_obj
-- fields the generator constructs them with (tech_action "complete"/"unlock"/
-- "breakthrough"; Event anomalies carry `sequence` instead -- L4314-4372).
function RmgPlacement.CountPlacedMarkers(map)
	local result = {
		deposit_markers = 0, anomaly_markers = 0,
		anom_freetech = 0, anom_event = 0, anom_techunlock = 0,
		anom_breakthrough = 0, anom_other = 0,
	}
	if type(map) ~= "table" or type(map.MapForEach) ~= "function" then
		return result
	end
	local by_res = {}
	pcall(map.MapForEach, map, "map", "DepositMarker", function(marker)
		if not marker then return end
		result.deposit_markers = result.deposit_markers + 1
		local res = marker.resource
		if type(res) == "string" then by_res[res] = (by_res[res] or 0) + 1 end
	end)
	pcall(map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(marker)
		if not marker then return end
		result.anomaly_markers = result.anomaly_markers + 1
		local ta = marker.tech_action
		if ta == "complete" then
			result.anom_freetech = result.anom_freetech + 1
		elseif ta == "unlock" then
			result.anom_techunlock = result.anom_techunlock + 1
		elseif ta == "breakthrough" then
			result.anom_breakthrough = result.anom_breakthrough + 1
		elseif marker.sequence ~= nil and marker.sequence ~= "" then
			result.anom_event = result.anom_event + 1
		else
			result.anom_other = result.anom_other + 1
		end
	end)
	for res, n in pairs(by_res) do
		result["dep_" .. res] = n
	end
	return result
end

SuperBigMap.RmgPlacement = RmgPlacement

local DebugLog = SuperBigMap.DebugLog
if DebugLog then DebugLog.Info("RmgPlacement", "module loaded") end

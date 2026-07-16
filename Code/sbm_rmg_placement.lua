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
-- shaped exactly as it is today. At the late surface PlaceAnomalies boundary we:
--   * consume the exact gen_zone/play_zone areas captured from the native generator
--     environment before any placement layer erodes those grids, then
--   * zero the per-layer deposit/anomaly borders (self.DepBorder*), and
--   * scale spacing/repulse (self.*Spacing / self.*Repulse* and the shared
--     Presets.ResourcePreset.Default *Repulse*) by the smaller of
--     sqrt(coverage) and the known-safe scale cap. Area coverage supplies useful
--     diagnostics, while the cap also accounts for fragmentation and sequential
--     cross-layer erosion that a scalar coverage ratio cannot represent.
--   * cap only self.AnomalySpacing slightly lower, because TechUnlock, Event, and
--     FreeTech share one destructively-eroded native mask. Cross-resource anomaly
--     repulsion and every resource-layer value retain the base placement scale.
-- Originals are snapshotted and restored when PlaceAnomalies returns (idempotent,
-- single synchronous generation thread). Every scaled value is rounded
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

local function ExhaustiveLog(message, data)
	local DebugLog = SuperBigMap.DebugLog
	-- Diagnostics must never interfere with the mutation/rollback transaction.
	if DebugLog and type(DebugLog.Info) == "function" then
		pcall(DebugLog.Info, "RmgPlacementExhaustive", message, data)
	end
end

-- Placement-only properties scaled toward a tighter packing (absolute world
-- distances, granularity work_step in the generator). NONE feed gen_zone/terrain.
local SPACING_PROPS = {
	"AnomalySpacing", "AnomalyRepulseSubs", "AnomalyRepulseAll",
	"EffectDepSpacing", "EffectDepRepulse", "EffectDepRepulseAll",
}

-- Scalable anomaly COUNT properties on the generator instance (consumed at gen time,
-- RandomMapGenerator.lua ~3262-3291). FreeTech/TechUnlock/Event additions are post-stretch;
-- breakthroughs deliberately do not because City reserves/prunes their finite technology
-- pool after generation. Each property is a plain number or a {from,to} range.
local COUNT_PROPS = {
	"AnomFreeTechCount", "AnomEventCount", "AnomTechUnlockCount",
	"BonusCountFreeTech", "BonusCountEvent",
}

-- Per-layer placement borders eroded off play_zone (L3334/L3384). Zeroing these
-- recovers the candidate cells the erosion ate -- the FreeTech=0 culprit.
local BORDER_PROPS = {
	"DepBorderSurf", "DepBorderSubs", "DepBorderTerr",
	"DepBorderAnomaly", "DepBorderEffects",
}

-- Per-resource deposit repulsion lives on the shared ResourcePreset (read at L3379),
-- so it is scaled on the preset table and restored afterwards. ClusterSpacing is
-- deliberately excluded: shipped presets use raw 1/2/4/8 intra-cluster values and
-- the native generator imposes no work_step divisibility rule on it. RoundToStep
-- would incorrectly increase those authored values to 800.
local PRESET_SPACING_FIELDS = { "RepulseSame", "RepulseSameLayer", "RepulseAll" }

-- Active relaxation snapshot for the in-flight generation (one synchronous thread).
local active = nil

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

-- Proc_SetupStyles creates gen_zone before terrain painting, then OnGenerateLogic receives
-- that exact grid and its exact GridCount as env.gen_zone/env.gen_area_unscaled. The
-- map-generation wrapper snapshots those values while they are still authoritative.
-- Re-reading terrain types here is wrong: ApplyTerrain has already replaced the blank-map
-- generation markers, which is why the former late sample always reported coverage 0.
local function MeasureGenZoneCoverage(_generator, map)
	local coverage = map and (map.SuperBigMapRmgPlayableCoverage or map.SuperBigMapRmgGenZoneCoverage)
	if type(coverage) ~= "number" or coverage <= 0 or coverage > 1 then
		return nil, "authoritative placement coverage was not captured"
	end
	local info = {}
	local source = map.SuperBigMapRmgPlayableCoverage and map.SuperBigMapRmgPlayableCoverageInfo
		or map.SuperBigMapRmgGenZoneCoverageInfo
	for k, v in pairs(source or {}) do info[k] = v end
	return coverage, nil, info
end

local RmgPlacement = {}

-- Begin: snapshot + relax placement knobs for the in-flight generation. Call on a
-- mod-expanded map after the DoGenerate size overrides are in place. The stretch pipeline starts it from the
-- PlaceAnomalies ProcStart boundary, after terrain/prefab generation and ResolveBuildable have
-- finished but before the engine builds its border/spacing-derived enrichment masks. Terrain and
-- the native play zone stay seed-identical. Returns true if a relaxation was applied (so End must
-- be called).
function RmgPlacement.Begin(generator, map, options)
	if not Enabled() then return false end
	options = type(options) == "table" and options or {}
	-- The stretch pipeline may opt in only from the late PlaceAnomalies procedure boundary. The
	-- normal pre-DoGenerate call still skips, preserving all terrain/prefab streams.
	if options.allow_stretch_placement ~= true then
		Log("Begin skipped: stretch mode waits for the PlaceAnomalies procedure boundary")
		return false
	end
	if active then
		Log("Begin skipped: a relaxation is already active (re-entrant DoGenerate?)")
		return false
	end
	if type(generator) ~= "table" or type(map) ~= "table" then return false end
	local environment = type(map.mapdata) == "table" and map.mapdata.Environment or nil
	if environment == "Underground" then
		Log("Begin skipped: underground generation remains engine-native")
		return false
	end

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
	floor = (type(floor) == "number" and floor > 0 and floor <= 1) and floor or 0.6
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
	local calculated_scale = scale
	-- Coverage alone overestimates capacity when the zone is fragmented and every earlier
	-- layer destructively erases later layers through MarkDepositLayers. Cap it at the
	-- log-proven resource-safe value; with the default floor/cap both 0.6, the applied base
	-- scale is exactly 0.6 and the full native resource targets fit. Same-anomaly packing uses
	-- the separate cap below. No native warning is filtered or suppressed.
	if scale > fallback then
		scale = fallback
		scale_basis = scale_basis .. "+safe-cap"
	end
	if scale < floor then scale = floor end
	if scale > 1 then scale = 1 end

	-- Same-resource anomaly placement needs slightly more room than the base resource
	-- scale: TechUnlock, Event, and FreeTech sequentially consume the same mask using a
	-- 2 * AnomalySpacing exclusion radius. Keep this separate so the already-successful
	-- resource and cross-layer searches are not disturbed. A cap (rather than a fixed
	-- value) preserves any tighter scale required when anomaly counts are enlarged.
	local anomaly_spacing_cap = cfg().RMG_PLACEMENT_ANOMALY_SPACING_CAP
	anomaly_spacing_cap = (type(anomaly_spacing_cap) == "number" and anomaly_spacing_cap > 0
		and anomaly_spacing_cap <= 1) and anomaly_spacing_cap or 0.55

	local zero_borders = cfg().RMG_PLACEMENT_ZERO_BORDERS ~= false
	local snapshot = {
		generator = generator, props = {}, presets = {},
		mode = "stretch-place-anomalies",
	}
	-- Publish the rollback record before the first mutation. If any later diagnostic/property
	-- access raises, the caller can invoke End and restore everything already captured.
	active = snapshot
	ExhaustiveLog("BEGIN placement transaction (before relaxation)", {
		mode = snapshot.mode,
		map = tostring(map.name or (map.mapdata and map.mapdata.id) or "?"),
		environment = tostring(map.mapdata and map.mapdata.Environment or "?"),
		generator_tiles = tostring(map.SuperBigMapGeneratorWidthTiles),
		desired_tiles = tostring(map.SuperBigMapDesiredWidthTiles),
		pass_border = tostring(map.mapdata and map.mapdata.PassBorder),
		DepBorderSurf = tostring(generator.DepBorderSurf),
		DepBorderSubs = tostring(generator.DepBorderSubs),
		DepBorderTerr = tostring(generator.DepBorderTerr),
		DepBorderAnomaly = tostring(generator.DepBorderAnomaly),
		DepBorderEffects = tostring(generator.DepBorderEffects),
		AnomalySpacing = tostring(generator.AnomalySpacing),
		AnomalyRepulseSubs = tostring(generator.AnomalyRepulseSubs),
		AnomalyRepulseAll = tostring(generator.AnomalyRepulseAll),
		EffectDepSpacing = tostring(generator.EffectDepSpacing),
		EffectDepRepulse = tostring(generator.EffectDepRepulse),
		EffectDepRepulseAll = tostring(generator.EffectDepRepulseAll),
	})

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

	-- 2) Anomaly COUNT scaling: place proportionally MORE ordinary anomalies so the bigger map
	-- reaches full vanilla density for its size. FreeTech/TechUnlock/Event scale freely in
	-- the temporary source view; finite breakthrough counts remain untouched.
	local anom_scale = 1.0
	-- Stretch already scales density with the post-generation top-up pass. At this
	-- late boundary we repair only the native preset population; scaling counts here
	-- would double-apply the area factor and overcrowd the source placement zone.
	if options.preserve_native_counts ~= true and cfg().TOPUP_ANOMALIES == true then
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
	-- dedicated minimum so native placement completes without invalid origins.
	local spacing_scale = scale
	if anom_scale > 1.0 then
		spacing_scale = scale / math.sqrt(anom_scale)
		local anom_floor = cfg().ANOMALY_COUNT_SPACING_FLOOR
		anom_floor = (type(anom_floor) == "number" and anom_floor > 0 and anom_floor <= 1) and anom_floor or 0.35
		if spacing_scale < anom_floor then spacing_scale = anom_floor end
	end
	local anomaly_spacing_scale = math.min(spacing_scale, anomaly_spacing_cap)
	if spacing_scale < 0.999 or anomaly_spacing_scale < 0.999 then
		for _, name in ipairs(SPACING_PROPS) do
			local v = generator[name]
			if type(v) == "number" and v > 0 then
				local property_scale = name == "AnomalySpacing" and anomaly_spacing_scale or spacing_scale
				local nv = RoundToStep(v * property_scale, step)
				if nv ~= v then
					snapshot.props[#snapshot.props + 1] = { obj = generator, key = name, value = v }
					generator[name] = nv
				end
			end
		end
	end

	-- 4) Per-resource deposit spacing on the shared ResourcePreset table. Concrete is placed
	-- after earlier layers have destructively erased their mutual repulsion masks, so borders
	-- alone cannot restore its candidate capacity. Uses the base placement scale, not the
	-- anomaly-count spacing scale, and every preset value is restored at ProcEnd.
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

	for i = 1, #snapshot.props do
		local e = snapshot.props[i]
		ExhaustiveLog("relaxed generator property", {
			n = i, property = tostring(e.key), before = tostring(e.value), after = tostring(e.obj[e.key]),
		})
	end
	for i = 1, #snapshot.presets do
		local e = snapshot.presets[i]
		ExhaustiveLog("relaxed resource-preset property", {
			n = i, preset = tostring(e.obj and (e.obj.id or e.obj.name) or "?"),
			property = tostring(e.key), before = tostring(e.value), after = tostring(e.obj[e.key]),
		})
	end

	if SuperBigMap.DebugLog and SuperBigMap.DebugLog.On and SuperBigMap.DebugLog.On("RmgPlacement") then
		local data = {
			mode = snapshot.mode,
			coverage = (type(coverage) == "number") and string.format("%.3f", coverage) or (why or "n/a"),
			scale = string.format("%.3f", scale),
			calculated_scale = string.format("%.3f", calculated_scale),
			scale_basis = scale_basis,
			anom_count_scale = string.format("%.3f", anom_scale),
			anom_spacing_scale = string.format("%.3f", anomaly_spacing_scale),
			other_spacing_scale = string.format("%.3f", spacing_scale),
			anomaly_spacing_cap = string.format("%.3f", anomaly_spacing_cap),
			work_step = step,
			zeroed_borders = zero_borders,
			props_changed = #snapshot.props,
			presets_changed = #snapshot.presets,
			floor = floor, safe_cap = fallback, squeeze = squeeze,
			cluster_spacing_scaled = false,
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
	if not snap then return end

	ExhaustiveLog("END placement transaction (before restoration)", {
		mode = tostring(snap.mode), changed_generator_props = #snap.props,
		changed_preset_props = #snap.presets,
	})
	for i = 1, #snap.props do
		local e = snap.props[i]
		e.obj[e.key] = e.value
	end
	for i = 1, #snap.presets do
		local e = snap.presets[i]
		e.obj[e.key] = e.value
	end
	-- Clear only after every restoration succeeded; a caller may retry End after an error.
	active = nil

	-- Diagnostics run only after the complete rollback and are protected so a logger failure
	-- can never be mistaken for a property-restoration failure by the generator wrapper.
	pcall(function()
		-- OnGenerateLogic records the exact randomized category counts before this
		-- procedure runs. Preserve those authoritative values; never substitute preset
		-- maxima or underground counts, which would overfill randomized maps and clone
		-- cave-specific anomaly families.
		map = map or Global("CurrentMap")
		if type(map) == "table" and type(snap.generator) == "table" then
			Log("authoritative post-generation anomaly category floors", {
				capture = tostring(map.SuperBigMapAnomalyTargetCapture),
				complete = (map.SuperBigMapExpectedAnomalyCounts or {}).complete,
				unlock = (map.SuperBigMapExpectedAnomalyCounts or {}).unlock,
				sequence = (map.SuperBigMapExpectedAnomalyCounts or {}).sequence,
			})
		end

		if SuperBigMap.DebugLog and SuperBigMap.DebugLog.On and SuperBigMap.DebugLog.On("RmgPlacement") then
			local data = RmgPlacement.CountPlacedMarkers(map)
			local expected = RmgPlacement.ExpectedAnomalyRanges(snap.generator)
			for k, v in pairs(expected) do data[k] = v end
			Log("placement restored: placed vs expected", data)
			ExhaustiveLog("native enrichment placement census after restoration", data)
		end
	end)
end

-- Procedure-boundary snapshot used by the exhaustive trace. Read-only and cheap enough to call
-- at ResolveBuildable/PlaceAnomalies only; it never touches the generator or map.
function RmgPlacement.TraceState(generator, map, phase, extra)
	local DebugLog = SuperBigMap.DebugLog
	if not (DebugLog and type(DebugLog.On) == "function"
		and DebugLog.On("RmgPlacementExhaustive") == true) then
		return false
	end
	local data = {
		phase = tostring(phase or "?"), transaction_active = active ~= nil,
		map = tostring(map and (map.name or (map.mapdata and map.mapdata.id)) or "?"),
		environment = tostring(map and map.mapdata and map.mapdata.Environment or "?"),
		pass_border = tostring(map and map.mapdata and map.mapdata.PassBorder),
	}
	for _, name in ipairs(BORDER_PROPS) do data[name] = tostring(generator and generator[name]) end
	for _, name in ipairs(SPACING_PROPS) do data[name] = tostring(generator and generator[name]) end
	if type(extra) == "table" then
		for k, v in pairs(extra) do data[k] = v end
	end
	ExhaustiveLog("procedure-boundary placement state", data)
	return true
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

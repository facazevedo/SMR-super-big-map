-- Recover native rock support lost when mesh Z grows more than height-capped terrain Z.
-- No terrain writes, RNG, resizing, rotation, XY movement, or gameplay-object edits.
local SBM = rawget(_G, "SuperBigMap")
local Engine = SBM.Engine
local Global = Engine.Global
local Clone = SBM.ObjectClone
local math,table=math,table
local type,tostring,ipairs,pairs,pcall=type,tostring,ipairs,pairs,pcall
local captures = setmetatable({}, { __mode = "k" })

local function Enabled()
	return (SBM.Config or {}).STRETCH_GROUND_UNSUPPORTED_ROCKS ~= false
end

local function NoTerrainCompression(z_scale,xy_scale)
	return type(z_scale)=="number" and type(xy_scale)=="number"
		and z_scale>0 and z_scale<math.huge and xy_scale>0 and xy_scale<math.huge
		and z_scale>=xy_scale-0.000001
end

local function Eligible(obj, checked_skip, checked_important)
	local classified_for_transform = checked_skip ~= nil and checked_important ~= nil
		and checked_skip == Clone.ShouldSkipObject
		and checked_important == Clone.IsImportantSectorObject
	if not obj or (not classified_for_transform
		and (Clone.ShouldSkipObject(obj) or Clone.IsImportantSectorObject(obj)))
		or not Clone.ObjectScalesWithTerrain(obj) then return false end
	if obj:GetParent() then return false end -- attachments follow their parent exactly once
	local entities = Global("EntityData")
	local data = entities and entities[obj:GetEntity()]
	-- Entity metadata, not a scenario/class-name allowlist. Buildings, resources, mystery/access
	-- content and attached children have already been excluded by the shared predicates above.
	return type(data) == "table" and data.editor_category == "StonesRocksCliffs"
		and type(data.entity) == "table" and data.entity.material_type == "Rock"
end

local function BeginCapture(map, source_map)
	if not Enabled() then captures[map] = nil;map.SuperBigMapRockGroundingStats = nil;return end
	local width, height = map:GetMapSize()
	local tile = Global("const").HeightTileSize
	local source_width = map.SuperBigMapSourceWidthTiles or map.SuperBigMapGeneratorWidthTiles
	local source_height = map.SuperBigMapSourceHeightTiles or map.SuperBigMapGeneratorHeightTiles
	local native_width, native_height = (source_map or map):GetMapSize()
	-- Direct migration has already installed the final terrain and fixed its
	-- Z/XY ratios. Apply explicitly ignores uphill samples for uniform scaling;
	-- do not gather those unused native ray contacts. Unknown/in-place terrain
	-- still follows the complete capture path, and floating-above-pivot rocks
	-- retain their separate final-geometry correction in either case.
	local full_width=map.SuperBigMapDesiredWidthTiles or (map.mapdata and map.mapdata.Width)
	local mul,div=map.SuperBigMapZScaleMul,map.SuperBigMapZScaleDiv
	local direct_stretch=map.SuperBigMapDirectSourceTerrainStretched==true
		and source_map and source_map~=map and type(source_width)=="number" and source_width>0
		and type(full_width)=="number" and type(mul)=="number" and type(div)=="number" and div>0
	local uniform_stretch=direct_stretch and NoTerrainCompression((mul+0.0)/div,(full_width+0.0)/source_width)
	-- The strict surface finalizer independently seats and positively verifies
	-- every rendered rock before T1, including support lost to terrain compression.
	-- Its complete current-geometry proof replaces the old sampled-ray prediction;
	-- an object that still has real support need not be lowered speculatively.
	-- Keep the old capture for in-place/unfinished terrain, underground, incomplete
	-- services or disabled finalization. No work is deferred beyond loading.
	local seating,validation=SBM.DecorationSeating,SBM.DecorationValidation
	local strict_final=direct_stretch and type(Engine.MapDataEnvironment)=="function"
		and Engine.MapDataEnvironment(map.mapdata)=="Surface"
		and (SBM.Config or {}).EXPANSION_STEP_11_REBUILD_GAMEPLAY_GRIDS~=false
		and seating and type(seating.Run)=="function"
		and validation and type(validation.WithCorrectionEvidence)=="function"
		and type(validation.SurfaceSupportSummary)=="function"
	local stats = { eligible = 0, probes = 0, rays = 0, contacts = 0, lowered = 0,
		unchanged = 0, max_lowering = 0, total_lowering = 0, failures = 0,
		unsupported_candidates = 0, unsupported_rays = 0, unsupported_lowered = 0,
		capture_ms = 0, apply_ms = 0, strict_final_handoff = strict_final==true }
	map.SuperBigMapRockGroundingStats = stats
	captures[map] = { source_map = source_map or map, objects = {}, stats = stats,
		uniform_stretch=uniform_stretch==true, strict_final_handoff=strict_final==true,
		width = width, height = height,
		source_width = source_width and source_width * tile or native_width,
		source_height = source_height and source_height * tile or native_height }
	return strict_final~=true -- false only when the strict final pass owns this work
end

local function InBounds(x, y, width, height)
	return x >= 0 and y >= 0 and x < width and y < height
end

-- Checked predicate identities qualify only an immediate call after both
-- returned false for this unchanged object. Default callers and rebound
-- classifiers retain the complete classification path.
local function Capture(map, obj, checked_skip, checked_important)
	local context = captures[map]
	if not context or context.strict_final_handoff then return end
	local stats = context.stats
	local ticks, point_fn = Global("GetPreciseTicks"), Global("point")
	local started = ticks()
	if not Eligible(obj, checked_skip, checked_important) then
		stats.capture_ms = stats.capture_ms + ticks() - started
		return
	end
	stats.eligible = stats.eligible + 1
	local terrain_api = Global("terrain")
	local pos = obj:GetPos()
	local visual = obj:GetVisualPos()
	local source_ground = terrain_api.GetHeight(context.source_map, pos)
	local source_z = obj:IsValidZ() and pos:z() or source_ground
	local bounds = obj:GetObjectBBox()
	local tile = Global("const").HeightTileSize
	-- Some cliff entities are authored with their complete mesh above the pivot. Their pivot is
	-- terrain-snapped, but the visible mesh can consequently remain wholly airborne on flat final
	-- terrain. Keep these rare objects for a bounded final-geometry support check even when the
	-- native uphill-contact heuristic below finds no sample.
	-- An explicitly elevated pivot can belong to an authored stack/column/arch.
	-- Its support is another object, not the terrain. Independently seating such a
	-- piece destroys the stack even under an exact uniform XYZ stretch. Only the
	-- terrain-level pivot case qualifies for this terrain-only fallback; proven
	-- native uphill contacts below still handle actual lost terrain support.
	local unsupported_candidate = bounds:minz() > visual:z()
		and source_z <= source_ground + tile
	-- Bottom points at/below the pivot cannot lift away due to extra uniform Z scaling.
	-- Avoid ray tests there; small, flat-ground stones usually have no uphill support to lose.
	if bounds:maxz() <= visual:z() + tile then
		stats.capture_ms = stats.capture_ms + ticks() - started
		return
	end
	local count = math.min(9, math.max(3,
		math.ceil(math.max(bounds:sizex(), bounds:sizey()) / (4.0 * tile))))
	local samples = {}
	local may_have_uphill_contact = not context.uniform_stretch
	local box_fn = Global("box")
	if may_have_uphill_contact and type(terrain_api.GetMinMaxHeight)=="function" and type(box_fn)=="function" then
		-- Bound the entire sampled footprint, including interpolation neighbours.
		-- If even its maximum is below the uphill-contact threshold, none of the
		-- original ray sites can contribute a sample. Keep unsupported candidates
		-- below: this does not disable their independent final seating check.
		local x0=math.max(0,math.floor(bounds:minx())-tile)
		local y0=math.max(0,math.floor(bounds:miny())-tile)
		local x1=math.min(context.source_width-1,math.ceil(bounds:minx()+bounds:sizex())+tile)
		local y1=math.min(context.source_height-1,math.ceil(bounds:miny()+bounds:sizey())+tile)
		if x0<=x1 and y0<=y1 then
			local _,upper=terrain_api.GetMinMaxHeight(context.source_map,box_fn(x0,y0,x1,y1))
			if type(upper)=="number" and upper<=source_z+tile then may_have_uphill_contact=false end
		end
	end
	if may_have_uphill_contact then
	for ix = 1, count do
		local x = bounds:minx() + math.floor(bounds:sizex() * (ix + 0.0) / (count + 1) + 0.5)
		for iy = 1, count do
			local y = bounds:miny() + math.floor(bounds:sizey() * (iy + 0.0) / (count + 1) + 0.5)
			local ground
			if InBounds(x, y, context.source_width, context.source_height) then
				ground = terrain_api.GetHeight(context.source_map, point_fn(x, y))
				stats.probes = stats.probes + 1
			end
			if ground and ground > source_z + tile then
				local hit = obj:IntersectSegment(point_fn(x, y, bounds:minz() - tile),
					point_fn(x, y, bounds:maxz() + tile))
				stats.rays = stats.rays + 1
				if hit then
					local dz = hit:z() - visual:z()
					-- Preserve only points that were supported in vanilla. An intentionally exposed
					-- underside is not a reason to bury the entire formation after expansion.
					if dz > tile and source_z + dz <= ground then
						samples[#samples + 1] = { dx = x - visual:x(), dy = y - visual:y(), dz = dz }
					end
				end
			end
		end
	end
	end
	if #samples > 0 or unsupported_candidate then
		context.objects[obj] = { scale = obj:GetScale(), angle = obj:GetAngle(),
			axis = obj:GetAxis(), top = bounds:maxz() - visual:z(), samples = samples,
			unsupported_candidate = unsupported_candidate }
		stats.contacts = stats.contacts + #samples
	end
	stats.capture_ms = stats.capture_ms + ticks() - started
end

-- Return the least final Z correction that gives a wholly airborne mesh one sampled terrain
-- contact. This is intentionally independent of native-contact capture: the engine decor pass
-- creates additional rocks only after the native population has already been transformed.
local function FindUnsupportedLowering(map, obj, context, stats, point_fn, terrain_api, tile)
	local bounds = obj:GetObjectBBox()
	local visual = obj:GetVisualPos()
	if bounds:minz() <= visual:z() + tile then return 0 end
	stats.unsupported_candidates = stats.unsupported_candidates + 1
	local count = math.min(17, math.max(5,
		math.ceil(math.max(bounds:sizex(), bounds:sizey()) / (4.0 * tile))))
	local min_clearance
	for ix = 1, count do
		local x = bounds:minx() + math.floor(bounds:sizex() * (ix + 0.0) / (count + 1) + 0.5)
		for iy = 1, count do
			local y = bounds:miny() + math.floor(bounds:sizey() * (iy + 0.0) / (count + 1) + 0.5)
			if InBounds(x, y, context.width, context.height) then
				local hit = obj:IntersectSegment(point_fn(x, y, bounds:minz() - tile),
					point_fn(x, y, bounds:maxz() + tile))
				stats.rays = stats.rays + 1
				stats.unsupported_rays = stats.unsupported_rays + 1
				if hit then
					local clearance = hit:z() - terrain_api.GetHeight(map, point_fn(x, y))
					if clearance <= tile then return 0 end
					min_clearance = min_clearance and math.min(min_clearance, clearance) or clearance
				end
			end
		end
	end
	return min_clearance and min_clearance > tile and min_clearance or 0
end

local function Apply(map, obj, terrain_z_scale, xy_scale)
	local context = captures[map]
	if context and context.uniform_stretch and not NoTerrainCompression(terrain_z_scale,xy_scale) then
		return nil,"terrain compression changed after uniform native-contact capture"
	end
	local record = context and context.objects[obj]
	if not record then return 0 end
	context.objects[obj] = nil -- one placement pass, never accumulate the same correction
	local stats = context.stats
	local ticks, point_fn = Global("GetPreciseTicks"), Global("point")
	local started = ticks()
	local tile = Global("const").HeightTileSize
	local ratio = (obj:GetScale() + 0.0) / record.scale
	-- Mesh-scale quantization alone is not terrain-Z compression.
	local support_can_be_lost = not (xy_scale and terrain_z_scale >= xy_scale - 0.000001)
		and ratio > terrain_z_scale
	if not support_can_be_lost and not record.unsupported_candidate then
		stats.unchanged = stats.unchanged + 1
		stats.apply_ms = stats.apply_ms + ticks() - started
		return 0
	end
	if obj:GetParent() or obj:GetAngle() ~= record.angle or obj:GetAxis() ~= record.axis then
		return nil, "rock pose changed between native contact capture and grounding"
	end
	local pos = obj:GetPos()
	if not obj:IsValidZ() then return nil, "rock final position has invalid Z" end
	local terrain_api = Global("terrain")
	local lower = 0
	if support_can_be_lost then
		for _, sample in ipairs(record.samples) do
			local x = pos:x() + math.floor(sample.dx * ratio + 0.5)
			local y = pos:y() + math.floor(sample.dy * ratio + 0.5)
			local bottom = pos:z() + math.floor(sample.dz * ratio + 0.5)
			if InBounds(x, y, context.width, context.height) then
				lower = math.max(lower, bottom - terrain_api.GetHeight(map, point_fn(x, y)))
			end
		end
	end
	local support_lowering = lower
	local unsupported_lowering = 0
	-- Native-contact capture intentionally excludes authored overhangs. Independently guarantee
	-- that a candidate whose WHOLE mesh begins above its pivot has at least one final terrain
	-- contact. Stop as soon as any sampled underside is already supported; otherwise the minimum
	-- clearance is the least lowering that seats the rock and preserves all possible overhang.
	if lower <= tile and record.unsupported_candidate then
		unsupported_lowering = FindUnsupportedLowering(
			map, obj, context, stats, point_fn, terrain_api, tile)
		if unsupported_lowering > tile then lower = unsupported_lowering end
	end
	-- Sub-tile gaps can be native resampling/mesh quantization. Leave those rocks untouched.
	if lower > tile then
		-- A tilted formation can regain one buried contact yet retain a conspicuously exposed
		-- underside. Only AFTER proving support was lost, fit that underside too. Cap this extra
		-- seating by the surplus height introduced by mesh-versus-terrain scaling, so an authored
		-- overhang cannot demand an arbitrarily deep burial. This cap varies with each rock's
		-- native geometry and actual scale; it is not a map-specific drop or a blanket offset.
		local surplus = support_can_be_lost
			and math.max(0, math.floor(record.top * (ratio - terrain_z_scale) + 0.5)) or 0
		if support_lowering > tile and surplus > lower then
			local bounds = obj:GetObjectBBox()
			local exposed = lower
			for ix = 1, 9 do
				local x = bounds:minx() + math.floor(bounds:sizex() * (ix + 0.0) / 10 + 0.5)
				for iy = 1, 9 do
					local y = bounds:miny() + math.floor(bounds:sizey() * (iy + 0.0) / 10 + 0.5)
					if InBounds(x, y, context.width, context.height) then
						local hit = obj:IntersectSegment(point_fn(x,y,bounds:minz()-tile),
							point_fn(x,y,bounds:maxz()+tile))
						stats.rays = stats.rays + 1
						if hit then exposed = math.max(exposed,hit:z()-terrain_api.GetHeight(map,point_fn(x,y))) end
					end
					if exposed >= surplus then break end
				end
				if exposed >= surplus then break end
			end
			lower = math.max(lower, math.min(surplus, exposed))
		end
		obj:SetPos(point_fn(pos:x(), pos:y(), pos:z() - lower))
		local actual = obj:GetPos()
		if actual:x() ~= pos:x() or actual:y() ~= pos:y() or actual:z() ~= pos:z() - lower then
			obj:SetPos(pos)
			return nil, "rock SetPos did not preserve XY and apply the calculated lowering"
		end
		obj.SuperBigMapRockGroundingLowering = lower
		obj.SuperBigMapRockGroundingBaseZ = pos:z()
		obj.SuperBigMapRockGroundingNativeAxis = tostring(record.axis)
		obj.SuperBigMapRockGroundingLostSupportLowering = support_lowering
		obj.SuperBigMapRockGroundingUnsupportedLowering = unsupported_lowering
		obj.SuperBigMapRockGroundingMeshZSurplus = surplus
		obj.SuperBigMapRockGroundingContactCount = #record.samples
		stats.lowered = stats.lowered + 1
		if unsupported_lowering > 0 then
			stats.unsupported_lowered = stats.unsupported_lowered + 1
		end
		stats.max_lowering = math.max(stats.max_lowering, lower)
		stats.total_lowering = stats.total_lowering + lower
	else
		lower = 0
		stats.unchanged = stats.unchanged + 1
	end
	stats.apply_ms = stats.apply_ms + ticks() - started
	return lower
end

-- Ground a rock created after the native decoration transform (currently the density-restoring
-- engine decor pass). Its final pose and scale are already authoritative, so no source record is
-- necessary; only the wholly-unsupported final-geometry invariant applies.
local function GroundFinal(map, obj)
	local context = captures[map]
	if not context or not Eligible(obj) then return 0 end
	local stats = context.stats
	local ticks, point_fn = Global("GetPreciseTicks"), Global("point")
	local terrain_api, tile = Global("terrain"), Global("const").HeightTileSize
	local started = ticks()
	local lower = FindUnsupportedLowering(map, obj, context, stats, point_fn, terrain_api, tile)
	if lower <= tile then
		stats.apply_ms = stats.apply_ms + ticks() - started
		return 0
	end
	local pos = obj:GetPos()
	if not obj:IsValidZ() then return nil, "final rock position has invalid Z" end
	obj:SetPos(point_fn(pos:x(), pos:y(), pos:z() - lower))
	local actual = obj:GetPos()
	if actual:x() ~= pos:x() or actual:y() ~= pos:y() or actual:z() ~= pos:z() - lower then
		obj:SetPos(pos)
		return nil, "final rock SetPos did not preserve XY and apply the calculated lowering"
	end
	obj.SuperBigMapRockGroundingLowering = lower
	obj.SuperBigMapRockGroundingBaseZ = pos:z()
	obj.SuperBigMapRockGroundingNativeAxis = tostring(obj:GetAxis())
	obj.SuperBigMapRockGroundingLostSupportLowering = 0
	obj.SuperBigMapRockGroundingUnsupportedLowering = lower
	obj.SuperBigMapRockGroundingMeshZSurplus = 0
	obj.SuperBigMapRockGroundingContactCount = 0
	stats.lowered = stats.lowered + 1
	stats.unsupported_lowered = stats.unsupported_lowered + 1
	stats.max_lowering = math.max(stats.max_lowering, lower)
	stats.total_lowering = stats.total_lowering + lower
	stats.apply_ms = stats.apply_ms + ticks() - started
	return lower
end

local function Failure(map, reason)
	local context = captures[map]
	if context then
		context.stats.failures = context.stats.failures + 1
		context.stats.first_error = context.stats.first_error or tostring(reason)
	end
end

SBM.RockGrounding = {
	BeginCapture = BeginCapture, Capture = Capture, Apply = Apply, Failure = Failure,
	GroundFinal = GroundFinal,
	Clear = function(map) captures[map] = nil end,
	Eligible = Eligible,
}

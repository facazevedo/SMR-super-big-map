-- Recover native rock support lost when mesh Z grows more than height-capped terrain Z.
-- No terrain writes, RNG, resizing, rotation, XY movement, or gameplay-object edits.
local SBM = rawget(_G, "SuperBigMap")
local Engine = SBM.Engine
local Global = Engine.Global
local Clone = SBM.ObjectClone
local captures = setmetatable({}, { __mode = "k" })

local function Enabled()
	return (SBM.Config or {}).STRETCH_GROUND_UNSUPPORTED_ROCKS ~= false
end

local function Eligible(obj)
	if not obj or Clone.ShouldSkipObject(obj) or Clone.IsImportantSectorObject(obj)
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
	local stats = { eligible = 0, probes = 0, rays = 0, contacts = 0, lowered = 0,
		unchanged = 0, max_lowering = 0, total_lowering = 0, failures = 0,
		capture_ms = 0, apply_ms = 0 }
	map.SuperBigMapRockGroundingStats = stats
	captures[map] = { source_map = source_map or map, objects = {}, stats = stats,
		width = width, height = height,
		source_width = source_width and source_width * tile or native_width,
		source_height = source_height and source_height * tile or native_height }
end

local function InBounds(x, y, width, height)
	return x >= 0 and y >= 0 and x < width and y < height
end

local function Capture(map, obj)
	local context = captures[map]
	if not context then return end
	local stats = context.stats
	local ticks, point_fn = Global("GetPreciseTicks"), Global("point")
	local started = ticks()
	if not Eligible(obj) then
		stats.capture_ms = stats.capture_ms + ticks() - started
		return
	end
	stats.eligible = stats.eligible + 1
	local terrain_api = Global("terrain")
	local pos = obj:GetPos()
	local visual = obj:GetVisualPos()
	local source_z = obj:IsValidZ() and pos:z() or terrain_api.GetHeight(context.source_map, pos)
	local bounds = obj:GetObjectBBox()
	local tile = Global("const").HeightTileSize
	-- Bottom points at/below the pivot cannot lift away due to extra uniform Z scaling.
	-- Avoid ray tests there; small, flat-ground stones usually have no uphill support to lose.
	if bounds:maxz() <= visual:z() + tile then
		stats.capture_ms = stats.capture_ms + ticks() - started
		return
	end
	-- Bounds and visual pose cannot change during this non-yielding capture.
	local min_x, min_y = bounds:minx(), bounds:miny()
	local size_x, size_y = bounds:sizex(), bounds:sizey()
	local visual_x, visual_y, visual_z = visual:x(), visual:y(), visual:z()
	local min_z, max_z = bounds:minz(), bounds:maxz()
	local ray_bottom, ray_top = min_z - tile, max_z + tile
	local minimum_source_hit = source_z + (ray_bottom - visual_z)
	local count = math.min(9, math.max(3,
		math.ceil(math.max(size_x, size_y) / (4.0 * tile))))
	local ys = {}
	for iy = 1, count do
		ys[iy] = min_y + math.floor(size_y * (iy + 0.0) / (count + 1) + 0.5)
	end
	local samples = {}
	for ix = 1, count do
		local x = min_x + math.floor(size_x * (ix + 0.0) / (count + 1) + 0.5)
		for iy = 1, count do
			local y = ys[iy]
			local ground
			if InBounds(x, y, context.source_width, context.source_height) then
				ground = terrain_api.GetHeight(context.source_map, point_fn(x, y))
				stats.probes = stats.probes + 1
			end
			-- No intersection within the original segment can be below its lower end.
			-- If even that end was unsupported, this column cannot yield a native contact.
			if ground and ground > source_z + tile and ground >= minimum_source_hit then
				local hit = obj:IntersectSegment(point_fn(x, y, ray_bottom),
					point_fn(x, y, ray_top))
				stats.rays = stats.rays + 1
				if hit then
					local dz = hit:z() - visual_z
					-- Preserve only points that were supported in vanilla. An intentionally exposed
					-- underside is not a reason to bury the entire formation after expansion.
					if dz > tile and source_z + dz <= ground then
						samples[#samples + 1] = { dx = x - visual_x, dy = y - visual_y, dz = dz }
					end
				end
			end
		end
	end
	if #samples > 0 then
		context.objects[obj] = { scale = obj:GetScale(), angle = obj:GetAngle(),
			axis = obj:GetAxis(), top = max_z - visual_z, samples = samples }
		stats.contacts = stats.contacts + #samples
	end
	stats.capture_ms = stats.capture_ms + ticks() - started
end

local function Apply(map, obj, terrain_z_scale, xy_scale)
	local context = captures[map]
	local record = context and context.objects[obj]
	if not record then return 0 end
	context.objects[obj] = nil -- one placement pass, never accumulate the same correction
	local stats = context.stats
	local ticks, point_fn = Global("GetPreciseTicks"), Global("point")
	local started = ticks()
	local ratio = (obj:GetScale() + 0.0) / record.scale
	-- Mesh-scale quantization alone is not terrain-Z compression.
	if (xy_scale and terrain_z_scale >= xy_scale - 0.000001) or ratio <= terrain_z_scale then
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
	for _, sample in ipairs(record.samples) do
		local x = pos:x() + math.floor(sample.dx * ratio + 0.5)
		local y = pos:y() + math.floor(sample.dy * ratio + 0.5)
		local bottom = pos:z() + math.floor(sample.dz * ratio + 0.5)
		if InBounds(x, y, context.width, context.height) then
			lower = math.max(lower, bottom - terrain_api.GetHeight(map, point_fn(x, y)))
		end
	end
	-- Sub-tile gaps can be native resampling/mesh quantization. Leave those rocks untouched.
	if lower > Global("const").HeightTileSize then
		local support_lowering = lower
		-- A tilted formation can regain one buried contact yet retain a conspicuously exposed
		-- underside. Only AFTER proving support was lost, fit that underside too. Cap this extra
		-- seating by the surplus height introduced by mesh-versus-terrain scaling, so an authored
		-- overhang cannot demand an arbitrarily deep burial. This cap varies with each rock's
		-- native geometry and actual scale; it is not a map-specific drop or a blanket offset.
		local surplus = math.max(0, math.floor(record.top * (ratio - terrain_z_scale) + 0.5))
		if surplus > lower then
			local bounds = obj:GetObjectBBox()
			local tile = Global("const").HeightTileSize
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
		obj.SuperBigMapRockGroundingMeshZSurplus = surplus
		obj.SuperBigMapRockGroundingContactCount = #record.samples
		stats.lowered = stats.lowered + 1
		stats.max_lowering = math.max(stats.max_lowering, lower)
		stats.total_lowering = stats.total_lowering + lower
	else
		lower = 0
		stats.unchanged = stats.unchanged + 1
	end
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
	Clear = function(map) captures[map] = nil end,
	Eligible = Eligible,
}

-- Super Big Map -- exact image of the vanilla passability border.
--
-- Expanded maps keep mapdata.PassBorder at zero so the added terrain remains usable.
-- That is necessary for placement bounds, but it also removes the stock impassable
-- border from the passability raster.  A scalar expanded PassBorder cannot reproduce
-- the vanilla border one-to-one: the 3-to-4 stretch lands the source property sites on
-- a staggered destination lattice.
--
-- Reconstruct the source property lattice from live dimensions, map every source site
-- through the exact stretch, and derive a compact union of arbitrary stock passability
-- boxes.  The union is entirely data-derived: four maximal edge slabs plus guarded runs
-- for the remaining boundary sites.  It is exhaustively validated against every mapped
-- source site before use.  ClearPassabilityBox rasterises max-X as open, so the applied
-- boxes add one world unit to both maxima, matching ForcedImpassableMarker:GetArea.
-- The caller must invoke Apply only AFTER terrain.RebuildPassability returns.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global

local Replay = {}
SuperBigMap.PassBorderReplay = Replay

Replay.VERSION = 1
Replay.Cache = setmetatable({}, { __mode = "k" })

local function round_nonnegative(value)
	return math.floor(value + 0.5)
end

local function sorted_keys(set)
	local values = {}
	for value in pairs(set) do values[#values + 1] = value end
	table.sort(values)
	return values
end

local function minimum_gap(values, name)
	local gap
	for i = 2, #values do
		local delta = values[i] - values[i - 1]
		if delta > 0 and (not gap or delta < gap) then gap = delta end
	end
	if not gap then error("mapped lattice has no positive " .. tostring(name) .. " separation") end
	return gap
end

local function quantized_spec(minx, miny, maxx, maxy, kind)
	return {
		math.floor(minx), math.floor(miny), math.ceil(maxx), math.ceil(maxy),
		kind = kind,
	}
end

local function inside_spec(wx, wy, spec)
	return wx >= spec[1] and wx <= spec[3]
		and wy >= spec[2] and wy <= spec[4]
end

local function source_context(map)
	local cfg = SuperBigMap.Config or {}
	if cfg.STRETCH_VANILLA_EXACT_PASSBORDER ~= true then
		return false, "vanilla-exact PassBorder mode is disabled"
	end
	if type(map) ~= "table" or type(map.mapdata) ~= "table" then
		error("pass-border replay map data is unavailable")
	end
	local mapdata = map.mapdata
	if tonumber(mapdata.PassBorder) ~= 0 then
		return false, "expanded PassBorder is nonzero"
	end

	local desired_w = tonumber(map.SuperBigMapDesiredWidthTiles)
	local desired_h = tonumber(map.SuperBigMapDesiredHeightTiles)
	local source_w = tonumber(map.SuperBigMapGeneratorWidthTiles)
		or tonumber(map.SuperBigMapSourceWidthTiles)
	local source_h = tonumber(map.SuperBigMapGeneratorHeightTiles)
		or tonumber(map.SuperBigMapSourceHeightTiles)
	if not desired_w or not desired_h or not source_w or not source_h
		or desired_w <= source_w or desired_h <= source_h then
		return false, "map has no expanded source geometry"
	end
	if (tonumber(map.SuperBigMapSourceX) or 0) ~= 0
		or (tonumber(map.SuperBigMapSourceY) or 0) ~= 0 then
		error("pass-border replay does not support a nonzero source origin")
	end

	local original_border = tonumber(mapdata.SuperBigMapOriginalPassBorder)
	if original_border == nil then
		error("original PassBorder is unavailable for exact replay")
	end
	if original_border <= 0 then
		return false, "original PassBorder is zero"
	end

	local buildable = map.buildable
	local grid = type(buildable) == "table" and buildable.z_grid or nil
	if not grid or type(grid.size) ~= "function" then
		error("expanded property lattice is unavailable for pass-border replay")
	end
	local ok_size, expanded_gw, expanded_gh = pcall(grid.size, grid)
	expanded_gh = expanded_gh or expanded_gw
	if not ok_size or type(expanded_gw) ~= "number" or type(expanded_gh) ~= "number"
		or expanded_gw <= 0 or expanded_gh <= 0 then
		error("expanded property lattice dimensions are invalid")
	end
	expanded_gw, expanded_gh = math.floor(expanded_gw), math.floor(expanded_gh)
	local source_gw = round_nonnegative((expanded_gw * source_w + 0.0) / desired_w)
	local source_gh = round_nonnegative((expanded_gh * source_h + 0.0) / desired_h)
	if source_gw <= 0 or source_gh <= 0
		or source_gw > expanded_gw or source_gh > expanded_gh then
		error("derived source property lattice dimensions are invalid")
	end

	local const_tbl = Global("const")
	local tile = type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize) or nil
	if not tile or tile <= 0 then error("HeightTileSize is unavailable for pass-border replay") end
	local hex_to_world = Global("HexToWorld")
	if type(hex_to_world) ~= "function" then error("HexToWorld is unavailable for pass-border replay") end

	local function calibrated_world(sx, sy)
		local q, r = sx - sy / 2, sy
		local ok, wx, wy = pcall(hex_to_world, q, r)
		if not ok or type(wx) ~= "number" or type(wy) ~= "number" then
			error("HexToWorld calibration failed")
		end
		return wx, wy
	end
	local origin_x, origin_y = calibrated_world(0, 0)
	local x1, y1 = calibrated_world(1, 0)
	local x2, y2 = calibrated_world(0, 2)
	local axis_x, axis_y = x1 - origin_x, y1 - origin_y
	local row_x, row_y = (x2 - origin_x) / 2, (y2 - origin_y) / 2
	local determinant = axis_x * row_y - row_x * axis_y
	if determinant == 0 then error("pass-border property-lattice calibration is singular") end

	local function storage_to_world(sx, sy)
		local parity = sy % 2
		return origin_x + axis_x * sx + row_x * sy + axis_x * parity / 2,
			origin_y + axis_y * sx + row_y * sy + axis_y * parity / 2
	end
	local function world_to_storage(wx, wy)
		local dx, dy = wx - origin_x, wy - origin_y
		local sy_float = (axis_x * dy - dx * axis_y) / determinant
		local sy = round_nonnegative(sy_float)
		local parity = sy % 2
		dx, dy = dx - axis_x * parity / 2, dy - axis_y * parity / 2
		local sx_float = (dx * row_y - row_x * dy) / determinant
		return round_nonnegative(sx_float), sy
	end

	local context = {
		map = map,
		expanded_gw = expanded_gw, expanded_gh = expanded_gh,
		source_gw = source_gw, source_gh = source_gh,
		source_world_w = source_w * tile, source_world_h = source_h * tile,
		scale_x = (desired_w + 0.0) / source_w,
		scale_y = (desired_h + 0.0) / source_h,
		border = original_border,
		storage_to_world = storage_to_world,
		world_to_storage = world_to_storage,
	}
	context.signature = table.concat({
		tostring(Replay.VERSION), tostring(expanded_gw), tostring(expanded_gh),
		tostring(source_gw), tostring(source_gh), tostring(source_w), tostring(source_h),
		tostring(desired_w), tostring(desired_h), tostring(original_border),
		tostring(axis_x), tostring(axis_y), tostring(row_x), tostring(row_y),
	}, ":")
	return context
end

local function for_each_mapped_site(context, visitor, check_unique)
	local seen = check_unique and {} or nil
	local count = 0
	for sy = 0, context.source_gh - 1 do
		for sx = 0, context.source_gw - 1 do
			local source_x, source_y = context.storage_to_world(sx, sy)
			local ex, ey = context.world_to_storage(
				source_x * context.scale_x, source_y * context.scale_y)
			if ex < 0 or ex >= context.expanded_gw or ey < 0 or ey >= context.expanded_gh then
				error("mapped source property site falls outside the expanded lattice")
			end
			if seen then
				local key = ey * context.expanded_gw + ex
				if seen[key] then error("source-to-expanded property mapping is not one-to-one") end
				seen[key] = true
			end
			local wx, wy = context.storage_to_world(ex, ey)
			local expected = source_x < context.border
				or source_x > context.source_world_w - context.border
				or source_y < context.border
				or source_y > context.source_world_h - context.border
			visitor(expected, wx, wy)
			count = count + 1
		end
	end
	return count
end

local function core_contains(wx, wy, core)
	for i = 1, #core do
		if inside_spec(wx, wy, core[i]) then return true end
	end
	return false
end

local function derive_candidate(context, core, axis, gap_x, gap_y, fixed_values)
	local groups = {}
	local missing_count = 0
	for_each_mapped_site(context, function(expected, wx, wy)
		if expected and not core_contains(wx, wy, core) then
			local fixed, along = axis == "vertical" and wx or wy,
				axis == "vertical" and wy or wx
			local group = groups[fixed]
			if not group then group = { selected = {}, forbidden = {} }; groups[fixed] = group end
			group.selected[#group.selected + 1] = along
			missing_count = missing_count + 1
		end
	end)
	for_each_mapped_site(context, function(expected, wx, wy)
		if expected then return end
		local fixed, along = axis == "vertical" and wx or wy,
			axis == "vertical" and wy or wx
		local group = groups[fixed]
		if group then group.forbidden[#group.forbidden + 1] = along end
	end)

	local guard_x, guard_y = gap_x / 4, gap_y / 4
	local specs = {}
	for i = 1, #core do specs[#specs + 1] = core[i] end
	local fringe_specs = {}
	local fixed_order = sorted_keys(groups)
	for _, fixed in ipairs(fixed_order) do
		local group = groups[fixed]
		table.sort(group.selected)
		table.sort(group.forbidden)
		local run_start, run_end = group.selected[1], group.selected[1]
		local forbidden_index = 1
		local function append_run()
			local minx, miny, maxx, maxy
			if axis == "vertical" then
				minx, maxx = fixed - guard_x, fixed + guard_x
				miny, maxy = run_start - guard_y, run_end + guard_y
			else
				minx, maxx = run_start - guard_x, run_end + guard_x
				miny, maxy = fixed - guard_y, fixed + guard_y
			end
			local spec = quantized_spec(minx, miny, maxx, maxy, "fringe_" .. axis)
			spec.sites_in_run = 1
			fringe_specs[#fringe_specs + 1] = spec
			specs[#specs + 1] = spec
		end
		for i = 2, #group.selected do
			local value = group.selected[i]
			while group.forbidden[forbidden_index]
				and group.forbidden[forbidden_index] <= run_end do
				forbidden_index = forbidden_index + 1
			end
			local blocked = group.forbidden[forbidden_index]
				and group.forbidden[forbidden_index] < value
			if blocked then
				append_run()
				run_start, run_end = value, value
			else
				run_end = value
			end
		end
		append_run()
	end

	-- Index the quantized fringe boxes by every mapped fixed coordinate they can
	-- touch.  This validates the exact integer boxes, including any outward rounding,
	-- without an O(sites * boxes) replay.
	local ranges = {}
	for _, spec in ipairs(fringe_specs) do
		local fixed_min, fixed_max, along_min, along_max
		if axis == "vertical" then
			fixed_min, fixed_max, along_min, along_max = spec[1], spec[3], spec[2], spec[4]
		else
			fixed_min, fixed_max, along_min, along_max = spec[2], spec[4], spec[1], spec[3]
		end
		for _, fixed in ipairs(fixed_values) do
			if fixed >= fixed_min and fixed <= fixed_max then
				local line = ranges[fixed]
				if not line then line = {}; ranges[fixed] = line end
				line[#line + 1] = { along_min, along_max }
			end
		end
	end
	local differences = 0
	for_each_mapped_site(context, function(expected, wx, wy)
		local actual = core_contains(wx, wy, core)
		if not actual then
			local fixed, along = axis == "vertical" and wx or wy,
				axis == "vertical" and wy or wx
			local line = ranges[fixed]
			if line then
				for i = 1, #line do
					if along >= line[i][1] and along <= line[i][2] then
						actual = true
						break
					end
				end
			end
		end
		if actual ~= expected then differences = differences + 1 end
	end)
	if differences ~= 0 then
		return nil, axis .. " compact pass-border union has " .. tostring(differences)
		.. " mapped-site differences"
	end
	return {
		axis = axis,
		specs = specs,
		fringe_boxes = #fringe_specs,
		fringe_sites = missing_count,
	}
end

function Replay.Derive(map)
	local context, reason = source_context(map)
	if context == false then return false, reason end
	local cached = Replay.Cache[map]
	if cached and cached.signature == context.signature then
		return cached.specs, cached.stats
	end

	local x_set, y_set = {}, {}
	local lattice = {}
	local interior = {}
	local border_sites = 0
	local visitor = function(expected, wx, wy)
		x_set[wx], y_set[wy] = true, true
		lattice.minx = not lattice.minx and wx or math.min(lattice.minx, wx)
		lattice.maxx = not lattice.maxx and wx or math.max(lattice.maxx, wx)
		lattice.miny = not lattice.miny and wy or math.min(lattice.miny, wy)
		lattice.maxy = not lattice.maxy and wy or math.max(lattice.maxy, wy)
		if expected then
			border_sites = border_sites + 1
		else
			interior.minx = not interior.minx and wx or math.min(interior.minx, wx)
			interior.maxx = not interior.maxx and wx or math.max(interior.maxx, wx)
			interior.miny = not interior.miny and wy or math.min(interior.miny, wy)
			interior.maxy = not interior.maxy and wy or math.max(interior.maxy, wy)
		end
	end
	local mapped_sites = for_each_mapped_site(context, visitor, true)
	if border_sites == 0 or border_sites == mapped_sites or not interior.minx then
		error("pass-border discriminator needs both border and interior mapped sites")
	end
	local x_values, y_values = sorted_keys(x_set), sorted_keys(y_set)
	local gap_x, gap_y = minimum_gap(x_values, "x"), minimum_gap(y_values, "y")

	local left_edge, right_edge, top_edge, bottom_edge
	for _, value in ipairs(x_values) do
		if value < interior.minx then left_edge = value end
		if not right_edge and value > interior.maxx then right_edge = value end
	end
	for _, value in ipairs(y_values) do
		if value < interior.miny then top_edge = value end
		if not bottom_edge and value > interior.maxy then bottom_edge = value end
	end
	local core = {}
	if left_edge then core[#core + 1] = quantized_spec(
		lattice.minx, lattice.miny, left_edge, lattice.maxy, "core_left") end
	if right_edge then core[#core + 1] = quantized_spec(
		right_edge, lattice.miny, lattice.maxx, lattice.maxy, "core_right") end
	if top_edge then core[#core + 1] = quantized_spec(
		lattice.minx, lattice.miny, lattice.maxx, top_edge, "core_top") end
	if bottom_edge then core[#core + 1] = quantized_spec(
		lattice.minx, bottom_edge, lattice.maxx, lattice.maxy, "core_bottom") end
	if #core == 0 then error("pass-border compact union has no core boxes") end

	local vertical, vertical_error = derive_candidate(
		context, core, "vertical", gap_x, gap_y, x_values)
	local horizontal, horizontal_error = derive_candidate(
		context, core, "horizontal", gap_x, gap_y, y_values)
	if not vertical and not horizontal then
		error("no exact compact pass-border union: " .. tostring(vertical_error)
			.. "; " .. tostring(horizontal_error))
	end
	local winner = vertical
	if not winner or (horizontal and #horizontal.specs < #winner.specs) then winner = horizontal end
	local stats = {
		version = Replay.VERSION,
		signature = context.signature,
		mapped_sites = mapped_sites,
		border_sites = border_sites,
		interior_sites = mapped_sites - border_sites,
		source_gw = context.source_gw,
		source_gh = context.source_gh,
		expanded_gw = context.expanded_gw,
		expanded_gh = context.expanded_gh,
		core_boxes = #core,
		fringe_boxes = winner.fringe_boxes,
		fringe_sites = winner.fringe_sites,
		orientation = winner.axis,
		total_boxes = #winner.specs,
		gap_x = gap_x,
		gap_y = gap_y,
	}
	Replay.Cache[map] = { signature = context.signature, specs = winner.specs, stats = stats }
	return winner.specs, stats
end

function Replay.Apply(map, stage)
	local pause = Global("PauseInfiniteLoopDetection")
	local resume = Global("ResumeInfiniteLoopDetection")
	local paused = false
	if type(pause) == "function" then
		local ok = pcall(pause, "SuperBigMapPassBorderReplay")
		paused = ok == true
	end
	local payload
	local ok, failure = xpcall(function()
		local specs, stats = Replay.Derive(map)
		if specs == false then payload = { true, 0, stats }; return end
		local terrain_api = Global("terrain")
		local box_ctor, point_fn = Global("box"), Global("point")
		if type(terrain_api) ~= "table" or type(terrain_api.ClearPassabilityBox) ~= "function"
			or type(box_ctor) ~= "function" or type(point_fn) ~= "function" then
			error("stock arbitrary-box passability APIs are unavailable")
		end
		for i = 1, #specs do
			local spec = specs[i]
			local area = box_ctor(point_fn(spec[1], spec[2]),
				point_fn(spec[3] + 1, spec[4] + 1))
			local clear_ok, clear_error = pcall(terrain_api.ClearPassabilityBox, map, area)
			if not clear_ok then
				error("ClearPassabilityBox failed for derived box " .. tostring(i)
					.. ": " .. tostring(clear_error))
			end
		end
		map.SuperBigMapPassBorderReplayVersion = stats.version
		map.SuperBigMapPassBorderReplayStage = tostring(stage or "final")
		map.SuperBigMapPassBorderReplayApplyCount =
			(tonumber(map.SuperBigMapPassBorderReplayApplyCount) or 0) + 1
		map.SuperBigMapPassBorderReplayBoxes = stats.total_boxes
		map.SuperBigMapPassBorderReplayCoreBoxes = stats.core_boxes
		map.SuperBigMapPassBorderReplayFringeBoxes = stats.fringe_boxes
		map.SuperBigMapPassBorderReplayFringeSites = stats.fringe_sites
		map.SuperBigMapPassBorderReplayOrientation = stats.orientation
		map.SuperBigMapPassBorderReplayMappedSites = stats.mapped_sites
		map.SuperBigMapPassBorderReplayBorderSites = stats.border_sites
		payload = { true, #specs, stats }
	end, function(err) return tostring(err) end)
	if paused and type(resume) == "function" then
		pcall(resume, "SuperBigMapPassBorderReplay")
	end
	if not ok then error(failure) end
	return payload[1], payload[2], payload[3]
end

return true

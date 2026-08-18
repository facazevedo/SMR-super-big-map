-- Capture the complete stock BuildableGrid transaction without replacing either live grid.
--
-- The authoritative property-residual ruling requires one deterministic bundle containing the
-- raw grids immediately before and after InitBuildableGrid, the raw input and classified output
-- immediately after ProcessBuildableGrid, the shipped grid, and the collision-object identities
-- and footprints consumed by Init.  Both surface and underground maps are captured wherever the
-- stock BuildableGrid stage exists.  The six sweep-03 surface-build sites are stamped at every
-- phase so the offline checker can distinguish Init rejection from Process classification.
--
-- NewGrid is not a ComputeGrid, so every grid is saved as checked row-major U16 text.  This probe
-- owns and frees only its fresh work grids; map.buildable and terrain are read-only.
-- Placeholder: __OUT_BASE__.

rawset(_G, "g_ParityBuildInitStatus", "running")
rawset(_G, "g_ParityBuildInitInfo", false)
rawset(_G, "g_ParityBuildInitError", false)

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local out_base = "__OUT_BASE__"
		local rows, info, object_rows = {}, {}, {}
		local unbuildable_z = (type(buildUnbuildableZ) == "function")
			and buildUnbuildableZ() or (2 ^ 16 - 1)
		local const_tbl = rawget(_G, "const")
		local ef_collision = type(const_tbl) == "table" and const_tbl.efCollision or nil
		local collision_surface = type(rawget(_G, "EntitySurfaces")) == "table"
			and EntitySurfaces.Collision or g_NCF_SurfaceTypes

		local function scalar(value)
			local text = tostring(value == nil and "" or value)
			return (text:gsub("[\r\n,]", " "))
		end

		local function write(path, text)
			local write_err = AsyncStringToFile(path, text)
			if write_err then error("write failed " .. path .. ": " .. tostring(write_err)) end
		end

		local function grid_header(tag, stage, gw, gh)
			return string.format(
				"#schema=smr.ralph.buildphase.grid,v=1,map=%s,stage=%s,gw=%d,gh=%d,unbuildable_z=%d",
				tag, stage, gw, gh, unbuildable_z)
		end

		local function save_grid(grid, tag, stage)
			local gw, gh = grid:size()
			local text = { grid_header(tag, stage, gw, gh) }
			local row, sentinel_count = {}, 0
			for y = 0, gh - 1 do
				for x = 0, gw - 1 do
					local value = grid:get(x, y)
					row[x + 1] = value
					if value == unbuildable_z then sentinel_count = sentinel_count + 1 end
				end
				text[#text + 1] = table.concat(row, ",", 1, gw)
			end
			write(out_base .. "-" .. tag .. "-" .. stage .. ".txt", table.concat(text, "\n"))
			return gw, gh, sentinel_count
		end

		local function grid_diff(a, b)
			local aw, ah = a:size()
			local bw, bh = b:size()
			if aw ~= bw or ah ~= bh then return -1 end
			local diff = 0
			for y = 0, ah - 1 do
				for x = 0, aw - 1 do
					if a:get(x, y) ~= b:get(x, y) then diff = diff + 1 end
				end
			end
			return diff
		end

		local function safe_call(fn, obj, ...)
			if type(fn) ~= "function" then return nil end
			local ok_call, a, b, c = pcall(fn, obj, ...)
			if ok_call then return a, b, c end
			return nil
		end

		local function object_position(obj)
			local x, y, z = safe_call(obj.GetVisualPosXYZ, obj)
			if type(x) ~= "number" then
				local pos = safe_call(obj.GetPos, obj)
				if pos then
					x = safe_call(pos.x, pos)
					y = safe_call(pos.y, pos)
					z = safe_call(pos.z, pos)
				end
			end
			return x, y, z
		end

		local function shape_nodes(obj, x, y, angle)
			if type(x) ~= "number" or type(y) ~= "number" then return "", 0 end
			local shape = safe_call(obj.GetShapePoints, obj)
			if type(shape) ~= "table" then return "", 0 end
			local ok_hex, q0, r0 = pcall(WorldToHex, x, y)
			if not ok_hex or type(q0) ~= "number" then return "", #shape end
			local direction = 0
			if type(angle) == "number" and type(HexAngleToDirection) == "function" then
				local ok_dir, value = pcall(HexAngleToDirection, angle)
				if ok_dir and type(value) == "number" then direction = value end
			end
			local nodes = {}
			for i = 1, #shape do
				local point_value = shape[i]
				local dq = point_value and safe_call(point_value.x, point_value)
				local dr = point_value and safe_call(point_value.y, point_value)
				if type(dq) == "number" and type(dr) == "number" then
					if type(HexRotate) == "function" then
						local ok_rot, rq, rr = pcall(HexRotate, dq, dr, direction)
						if ok_rot and type(rq) == "number" then dq, dr = rq, rr end
					end
					nodes[#nodes + 1] = tostring(q0 + dq) .. ";" .. tostring(r0 + dr)
				end
			end
			return table.concat(nodes, " "), #shape
		end

		local function capture_collision_objects(map, tag)
			local objects = safe_call(map.MapGet, map, "map") or {}
			local candidates = 0
			for i = 1, #objects do
				local obj = objects[i]
				if obj and IsValid(obj) then
					local flag_value = ef_collision and safe_call(obj.GetEnumFlags, obj, ef_collision)
					local flagged = flag_value ~= nil and flag_value ~= false and flag_value ~= 0
					local entity = safe_call(obj.GetEntity, obj)
					local has_surface = false
					if entity and collision_surface and type(HasAnySurfaces) == "function" then
						local ok_surface, value = pcall(HasAnySurfaces, entity, collision_surface)
						has_surface = ok_surface and value == true
					end
					if flagged and has_surface then
						candidates = candidates + 1
						local x, y, z = object_position(obj)
						local bbox = safe_call(obj.GetObjectBBox, obj)
						local minx, miny, minz, maxx, maxy, maxz = "", "", "", "", "", ""
						if bbox then
							minx, miny, minz = safe_call(bbox.minx, bbox), safe_call(bbox.miny, bbox),
								safe_call(bbox.minz, bbox)
							maxx, maxy, maxz = safe_call(bbox.maxx, bbox), safe_call(bbox.maxy, bbox),
								safe_call(bbox.maxz, bbox)
						end
						local scale = safe_call(obj.GetScale, obj)
						local angle = safe_call(obj.GetAngle, obj)
						local game_flags = safe_call(obj.GetGameFlags, obj)
						local ignored_flags = g_NCF_IgnoreGameFlags
							and safe_call(obj.GetGameFlags, obj, g_NCF_IgnoreGameFlags) or nil
						local nodes, shape_points = shape_nodes(obj, x, y, angle)
						object_rows[#object_rows + 1] = table.concat({
							tag, candidates, scalar(obj.class), scalar(entity), scalar(obj.handle),
							scalar(x), scalar(y), scalar(z), scalar(scale), scalar(angle),
							scalar(minx), scalar(miny), scalar(minz), scalar(maxx), scalar(maxy),
							scalar(maxz), scalar(flag_value), scalar(game_flags), scalar(ignored_flags),
							scalar(obj.grids_applied), shape_points, scalar(nodes),
						}, ",")
					end
				end
			end
			rows[#rows + 1] = string.format("objects,%s,total=%d,collision_candidates=%d",
				tag, #objects, candidates)
			return candidates
		end

		local function focus_sites(map, tag)
			if tag ~= "surface" then return {} end
			local expanded = map.SuperBigMapExpanded == true
			if expanded then
				return {
					{ 364, 300, 485, 400 }, { 363, 301, 484, 401 },
					{ 364, 301, 485, 401 }, { 364, 301, 486, 401 },
					{ 367, 298, 489, 397 }, { 368, 298, 490, 397 },
				}
			end
			return {
				{ 364, 300, 364, 300 }, { 363, 301, 363, 301 },
				{ 364, 301, 364, 301 }, { 364, 301, 364, 301 },
				{ 367, 298, 367, 298 }, { 368, 298, 368, 298 },
			}
		end

		local function probe_map(map, tag)
			if not map then
				rows[#rows + 1] = "map," .. tag .. ",present=false"
				return
			end
			if type(NewGrid) ~= "function" or type(InitBuildableGrid) ~= "function"
				or type(ProcessBuildableGrid) ~= "function" then
				error("required buildable APIs unavailable")
			end
			local shipped = map.buildable and map.buildable.z_grid
			if not shipped then error(tag .. ": shipped buildable grid unavailable") end
			local width, height = shipped:size()
			local map_data = map.mapdata or {}
			local range = map_data.visible_height_range
			local range_from, range_to
			pcall(function()
				range_from = range and tonumber(range.from)
				range_to = range and tonumber(range.to)
			end)

			local raw = NewGrid(width, height, 16, unbuildable_z)
			local postinit_copy = NewGrid(width, height, 16, unbuildable_z)
			local processed = NewGrid(width, height, 16, unbuildable_z)
			if not raw or not postinit_copy or not processed then
				error(tag .. ": work-grid allocation failed")
			end
			local pre_w, pre_h, pre_sentinel = save_grid(raw, tag, "preinit")
			local collision_count = capture_collision_objects(map, tag)

			local init_start = GetPreciseTicks()
			InitBuildableGrid(map, {
				buildable_grid = raw,
				unbuildable_z = unbuildable_z,
				flat_threshold = g_NCF_FlatThreshold,
				max_surface_height = g_NCF_MaxSurfaceHeight,
				max_surface_error = g_NCF_MaxSurfaceError,
				surface_types = g_NCF_SurfaceTypes,
				enum_flags = g_NCF_EnumFlags,
				ignore_game_flags = g_NCF_IgnoreGameFlags,
				map_border = tonumber(map_data.PassBorder) or 0,
				map_min_height = range_from and range_from * guim or 0,
				map_max_height = range_to and range_to * guim or unbuildable_z,
			})
			local init_ms = GetPreciseTicks() - init_start
			local _, _, postinit_sentinel = save_grid(raw, tag, "postinit")
			for y = 0, height - 1 do
				for x = 0, width - 1 do postinit_copy:set(x, y, raw:get(x, y)) end
			end

			local process_start = GetPreciseTicks()
			ProcessBuildableGrid({
				buildable_grid = raw,
				buildable_z = processed,
				unbuildable_z = unbuildable_z,
				minsize = g_NCF_FlatThresholdAreaMin,
				maxsize = g_NCF_FlatThresholdAreaMax,
				mindelta = g_NCF_FlatThresholdAreaMinHeightDelta,
				maxdelta = g_NCF_FlatThresholdAreaMaxHeightDelta,
				minarea = g_NCF_MinArea,
			})
			local process_ms = GetPreciseTicks() - process_start
			local _, _, process_input_sentinel = save_grid(raw, tag, "postprocess-input")
			local _, _, process_output_sentinel = save_grid(processed, tag, "postprocess-output")
			local _, _, shipped_sentinel = save_grid(shipped, tag, "shipped")
			local input_diff = grid_diff(postinit_copy, raw)
			local shipped_diff = grid_diff(processed, shipped)

			local expanded = map.SuperBigMapExpanded == true
			rows[#rows + 1] = string.format(
				"map,%s,present=true,expanded=%s,gw=%d,gh=%d,hex_width=%s,hex_height=%s,"
					.. "pass_border=%s,unbuildable_z=%d,preinit_sentinel=%d,postinit_sentinel=%d,"
					.. "postprocess_input_sentinel=%d,postprocess_output_sentinel=%d,shipped_sentinel=%d,"
					.. "postinit_process_input_diff=%d,processed_shipped_diff=%d,init_ms=%d,"
					.. "process_ms=%d,collision_candidates=%d,flat_threshold=%s,max_surface_height=%s,"
					.. "max_surface_error=%s,surface_types=%s,enum_flags=%s,ignore_game_flags=%s,"
					.. "minsize=%s,maxsize=%s,mindelta=%s,maxdelta=%s,minarea=%s",
				tag, tostring(expanded), width, height, tostring(map.hex_width),
				tostring(map.hex_height), tostring(map_data.PassBorder), unbuildable_z,
				pre_sentinel, postinit_sentinel, process_input_sentinel, process_output_sentinel,
				shipped_sentinel, input_diff, shipped_diff, init_ms, process_ms, collision_count,
				tostring(g_NCF_FlatThreshold), tostring(g_NCF_MaxSurfaceHeight),
				tostring(g_NCF_MaxSurfaceError), tostring(g_NCF_SurfaceTypes),
				tostring(g_NCF_EnumFlags), tostring(g_NCF_IgnoreGameFlags),
				tostring(g_NCF_FlatThresholdAreaMin), tostring(g_NCF_FlatThresholdAreaMax),
				tostring(g_NCF_FlatThresholdAreaMinHeightDelta),
				tostring(g_NCF_FlatThresholdAreaMaxHeightDelta), tostring(g_NCF_MinArea))

			local sites = focus_sites(map, tag)
			for i = 1, #sites do
				local site = sites[i]
				local source_sx, source_sy, sx, sy = site[1], site[2], site[3], site[4]
				local q, r = sx - sy / 2, sy
				local wx, wy = HexToWorld(q, r)
				local pre_value = unbuildable_z
				local init_value = raw:get(sx, sy)
				local process_value = processed:get(sx, sy)
				local shipped_value = shipped:get(sx, sy)
				rows[#rows + 1] = string.format(
					"site,%s,%d,source_sx=%d,source_sy=%d,sx=%d,sy=%d,q=%s,r=%s,wx=%s,wy=%s,"
						.. "preinit=%d,postinit=%d,postprocess=%d,shipped=%d,init_unbuildable=%s,"
						.. "process_unbuildable=%s,shipped_unbuildable=%s",
					tag, i, source_sx, source_sy, sx, sy, tostring(q), tostring(r),
					tostring(wx), tostring(wy), pre_value, init_value, process_value, shipped_value,
					tostring(init_value == unbuildable_z),
					tostring(process_value == unbuildable_z),
					tostring(shipped_value == unbuildable_z))
			end
			info[#info + 1] = string.format("%s=%dx%d init=%dms process=%dms objects=%d diff=%d",
				tag, pre_w, pre_h, init_ms, process_ms, collision_count, shipped_diff)
			raw:free()
			postinit_copy:free()
			processed:free()
		end

		local maps = {}
		for i = 1, #(Maps or {}) do
			local map = Maps[i]
			local env = map and map.mapdata and map.mapdata.Environment
			if env == "Surface" and not maps.surface then maps.surface = map end
			if env == "Underground" and not maps.underground then maps.underground = map end
		end
		if type(PauseInfiniteLoopDetection) == "function" then
			PauseInfiniteLoopDetection("parity_buildphase")
		end
		probe_map(maps.surface, "surface")
		probe_map(maps.underground, "underground")
		write(out_base .. "-buildphase.txt", table.concat(rows, "\n"))
		table.insert(object_rows, 1,
			"map,index,class,entity,handle,x,y,z,scale,angle,bbox_minx,bbox_miny,bbox_minz,"
				.. "bbox_maxx,bbox_maxy,bbox_maxz,enum_collision,game_flags,ignored_game_flags,"
				.. "grids_applied,shape_points,shape_nodes")
		write(out_base .. "-collision-objects.csv", table.concat(object_rows, "\n"))
		g_ParityBuildInitInfo = table.concat(info, " ")
		g_ParityBuildInitStatus = "ready"
	end, debug.traceback)
	if type(ResumeInfiniteLoopDetection) == "function" then
		pcall(ResumeInfiniteLoopDetection, "parity_buildphase")
	end
	if not ok then
		g_ParityBuildInitError = tostring(err)
		g_ParityBuildInitStatus = "error"
	end
end)
return "buildphase_probe_started"

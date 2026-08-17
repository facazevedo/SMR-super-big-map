-- Full live replay of a data-derived stock perimeter box union.
--
-- The host binds one scenario-independent box list derived by perimetercheck.py.
-- For both maps this probe preserves complete property-lattice passability rasters:
--
--   baseline -> direct boxes -> bare rebuild
--     -> marker-free stock callback -> repeat -> cleanup
--     -> real marker rebuild -> repeat -> cleanup
--     -> max-plus-one direct boxes -> bare rebuild
--     -> max-plus-one marker-free stock callback -> repeat
--     -> tail handler inside OnPassabilityRebuilding
--     -> marker-free rebuild + post-return direct replay -> repeat -> cleanup
--
-- It is mutating but self-restoring; the host binds the output path, box rows,
-- and source/engine digests before loading this file.

g_ParityPerimeterFullStatus = "running"
g_ParityPerimeterFullInfo = false
g_ParityPerimeterFullError = false

CreateRealTimeThread(function()
	local cleanup = {}
	local paused = false
	local function rebuild(map)
		local ok_h, err_h = pcall(terrain.InvalidateHeight, map)
		local ok_t, err_t = pcall(terrain.InvalidateType, map)
		local ok_p, err_p = pcall(terrain.RebuildPassability, map)
		if not (ok_h and ok_t and ok_p) then
			error(string.format(
				"stock rebuild failed: height=%s:%s type=%s:%s pass=%s:%s",
				tostring(ok_h), tostring(err_h), tostring(ok_t), tostring(err_t),
				tostring(ok_p), tostring(err_p)))
		end
	end
	local function restore_all()
		for i = #cleanup, 1, -1 do
			local row = cleanup[i]
			if row.onmsg and row.previous_handler then
				row.onmsg.OnPassabilityRebuilding = row.previous_handler
				row.onmsg = false
				row.previous_handler = false
			end
			for j = #row.fakes, 1, -1 do
				table.remove_value(row.map.ForcedImpassableMarkers or {}, row.fakes[j])
			end
			row.fakes = {}
			for j = #row.markers, 1, -1 do
				local marker = row.markers[j]
				if IsValid(marker) then pcall(DoneObject, marker) end
			end
			row.markers = {}
			pcall(rebuild, row.map)
		end
		if paused and type(ResumeInfiniteLoopDetection) == "function" then
			pcall(ResumeInfiniteLoopDetection, "parity_perimeter_full")
			paused = false
		end
	end

	local ok, err = xpcall(function()
		local out_base = "__OUT_BASE__"
		local source_box_sha = "__SOURCE_BOX_SHA__"
		local engine_box_sha = "__ENGINE_BOX_SHA__"
		local specs = __BOXES__
		local rows = {
			string.format("boxes,count=%d,source_sha=%s,engine_sha=%s",
				#specs, source_box_sha, engine_box_sha)
		}
		local info = {}
		local const_tbl = rawget(_G, "const")
		local tile = (type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize)) or 100
		if tile <= 0 then error("invalid height tile") end
		if type(terrain) ~= "table" or type(terrain.ClearPassabilityBox) ~= "function"
			or type(terrain.HashPassability) ~= "function" then
			error("required stock passability APIs unavailable")
		end
		if type(PlaceObjectIn) ~= "function" then error("PlaceObjectIn unavailable") end

		local boxes = {}
		local plus1_boxes = {}
		for i = 1, #specs do
			local s = specs[i]
			boxes[i] = box(point(s[1], s[2]), point(s[3], s[4]))
			plus1_boxes[i] = box(point(s[1], s[2]), point(s[3] + 1, s[4] + 1))
			rows[#rows + 1] = string.format("box,id=%d,minx=%d,miny=%d,maxx=%d,maxy=%d",
				i, s[1], s[2], s[3], s[4])
		end

		local maps = {}
		for i = 1, #(Maps or {}) do
			local map = Maps[i]
			local env = map and map.mapdata and map.mapdata.Environment
			if env == "Surface" and not maps.surface then maps.surface = map end
			if env == "Underground" and not maps.underground then maps.underground = map end
		end
		if not maps.surface or not maps.underground then
			error("surface/underground map pair unavailable")
		end

		if type(PauseInfiniteLoopDetection) == "function" then
			PauseInfiniteLoopDetection("parity_perimeter_full")
			paused = true
		end

		local function storage_world(sx, sy)
			local q, r = sx - sy / 2, sy
			local wx, wy = HexToWorld(q, r)
			return q, r, wx, wy
		end
		local function snapshot(map, env, stage)
			local b = map and map.buildable
			local grid = type(b) == "table" and b.z_grid or nil
			if not grid then error(env .. ": buildable grid unavailable") end
			local gw, gh = grid:size()
			local bytes, passable = {}, 0
			for sy = 0, gh - 1 do
				for sx = 0, gw - 1 do
					local _, _, wx, wy = storage_world(sx, sy)
					local pt = point(wx, wy)
					local value = map:IsPointInBounds(pt) and map:IsPassable(pt)
					bytes[#bytes + 1] = value and "\1" or "\0"
					if value then passable = passable + 1 end
				end
			end
			local blob = table.concat(bytes)
			local path = string.format("%s-%s-%s.raw", out_base, env, stage)
			local werr = AsyncStringToFile(path, blob)
			if werr then error("write failed " .. path .. ": " .. tostring(werr)) end
			rows[#rows + 1] = string.format(
				"snapshot,env=%s,stage=%s,gw=%d,gh=%d,cells=%d,passable=%d,bytes=%d",
				env, stage, gw, gh, gw * gh, passable, #blob)
			return gw, gh
		end
		local function pass_hash(map)
			local ok_h, value = pcall(terrain.HashPassability, map)
			if not ok_h then error("HashPassability failed: " .. tostring(value)) end
			return tostring(value)
		end
		local function apply_direct(map, box_list)
			for i = 1, #box_list do
				local ok_c, err_c = pcall(terrain.ClearPassabilityBox, map, box_list[i])
				if not ok_c then
					error("direct ClearPassabilityBox failed: " .. tostring(err_c))
				end
			end
		end
		local function install_tail_handler(state, box_list, cycle)
			local onmsg = rawget(_G, "OnMsg")
			if type(onmsg) ~= "table" then error("OnMsg unavailable") end
			if state.onmsg then error("tail handler already installed") end
			local previous = onmsg.OnPassabilityRebuilding
			if type(previous) ~= "function" then
				error("stock OnPassabilityRebuilding handler unavailable")
			end
			state.onmsg = onmsg
			state.previous_handler = previous
			onmsg.OnPassabilityRebuilding = function(msg_map, clip)
				if msg_map ~= state.map then return previous(msg_map, clip) end
				local before_stock = pass_hash(msg_map)
				previous(msg_map, clip)
				local after_stock = pass_hash(msg_map)
				apply_direct(msg_map, box_list)
				local after_tail = pass_hash(msg_map)
				rows[#rows + 1] = string.format(
					"trace,env=%s,cycle=%d,before_stock=%s,after_stock=%s,after_tail=%s",
					state.env, cycle, before_stock, after_stock, after_tail)
			end
		end
		local function remove_tail_handler(state)
			if not state.onmsg then error("tail handler is not installed") end
			state.onmsg.OnPassabilityRebuilding = state.previous_handler
			state.onmsg = false
			state.previous_handler = false
		end
		local function install_fake_markers(state, box_list)
			local list = state.map.ForcedImpassableMarkers
			if type(list) ~= "table" then
				list = {}
				state.map.ForcedImpassableMarkers = list
			end
			for i = 1, #box_list do
				local fake = {
					area = box_list[i],
					GetArea = function(self) return self.area end,
				}
				list[#list + 1] = fake
				state.fakes[#state.fakes + 1] = fake
			end
		end
		local function remove_fake_markers(state)
			local list = state.map.ForcedImpassableMarkers or {}
			for i = #state.fakes, 1, -1 do
				table.remove_value(list, state.fakes[i])
			end
			state.fakes = {}
		end
		local function calibration(map, env, gw, gh)
			local hgw, hgh = terrain.HeightMapSize(map)
			rows[#rows + 1] = string.format(
				"map,env=%s,gw=%d,gh=%d,height_gw=%d,height_gh=%d,tile=%d,hex_width=%s,hex_height=%s",
				env, gw, gh, hgw, hgh, tile, tostring(map.hex_width), tostring(map.hex_height))
			for _, p in ipairs({ {0, 0}, {1, 0}, {0, 1}, {1, 1}, {0, 2}, {1, 2} }) do
				local q, r, wx, wy = storage_world(p[1], p[2])
				rows[#rows + 1] = string.format(
					"calibration,env=%s,sx=%d,sy=%d,q=%s,r=%s,wx=%s,wy=%s",
					env, p[1], p[2], tostring(q), tostring(r), tostring(wx), tostring(wy))
			end
		end

		for _, env in ipairs({ "surface", "underground" }) do
			local map = maps[env]
			local state = {
				map = map, env = env, markers = {}, fakes = {},
				onmsg = false, previous_handler = false,
			}
			cleanup[#cleanup + 1] = state
			local stage_names = {
				"baseline", "direct", "bare", "callback1", "callback2", "callback_cleanup",
				"marker1", "marker2", "marker_cleanup", "direct_plus1", "plus1_bare",
				"callback_plus1", "callback_plus1_repeat", "tail_plus1",
				"post_rebuild_plus1", "post_rebuild_plus1_repeat", "cleanup",
			}
			local stage_hashes = {}
			rebuild(map)
			local gw, gh = snapshot(map, env, "baseline")
			calibration(map, env, gw, gh)
			stage_hashes.baseline = pass_hash(map)

			apply_direct(map, boxes)
			snapshot(map, env, "direct")
			stage_hashes.direct = pass_hash(map)

			rebuild(map)
			snapshot(map, env, "bare")
			stage_hashes.bare = pass_hash(map)

			install_fake_markers(state, boxes)
			rebuild(map)
			snapshot(map, env, "callback1")
			stage_hashes.callback1 = pass_hash(map)
			rebuild(map)
			snapshot(map, env, "callback2")
			stage_hashes.callback2 = pass_hash(map)
			remove_fake_markers(state)
			rebuild(map)
			snapshot(map, env, "callback_cleanup")
			stage_hashes.callback_cleanup = pass_hash(map)

			for i = 1, #boxes do
				local marker = PlaceObjectIn("ForcedImpassableMarker", map)
				if not marker then error("PlaceObjectIn(ForcedImpassableMarker) returned nil") end
				marker.area = boxes[i]
				state.markers[#state.markers + 1] = marker
			end
			rebuild(map)
			snapshot(map, env, "marker1")
			stage_hashes.marker1 = pass_hash(map)
			rebuild(map)
			snapshot(map, env, "marker2")
			stage_hashes.marker2 = pass_hash(map)

			for i = #state.markers, 1, -1 do
				local marker = state.markers[i]
				if IsValid(marker) then DoneObject(marker) end
			end
			state.markers = {}
			rebuild(map)
			snapshot(map, env, "marker_cleanup")
			stage_hashes.marker_cleanup = pass_hash(map)

			apply_direct(map, plus1_boxes)
			snapshot(map, env, "direct_plus1")
			stage_hashes.direct_plus1 = pass_hash(map)
			rebuild(map)
			snapshot(map, env, "plus1_bare")
			stage_hashes.plus1_bare = pass_hash(map)

			install_fake_markers(state, plus1_boxes)
			rebuild(map)
			snapshot(map, env, "callback_plus1")
			stage_hashes.callback_plus1 = pass_hash(map)
			rebuild(map)
			snapshot(map, env, "callback_plus1_repeat")
			stage_hashes.callback_plus1_repeat = pass_hash(map)

			-- Appending after the stock callback is still inside RebuildPassability.  This
			-- tests whether handler ordering can repair the surface-only overreach.
			install_tail_handler(state, plus1_boxes, 1)
			rebuild(map)
			remove_tail_handler(state)
			snapshot(map, env, "tail_plus1")
			stage_hashes.tail_plus1 = pass_hash(map)

			-- The candidate implementation point is after RebuildPassability returns and
			-- without fake/placed markers participating in its callback.  Re-run the whole
			-- sequence to prove that it is stable, then restore the untouched baseline.
			remove_fake_markers(state)
			rebuild(map)
			apply_direct(map, plus1_boxes)
			snapshot(map, env, "post_rebuild_plus1")
			stage_hashes.post_rebuild_plus1 = pass_hash(map)
			rebuild(map)
			apply_direct(map, plus1_boxes)
			snapshot(map, env, "post_rebuild_plus1_repeat")
			stage_hashes.post_rebuild_plus1_repeat = pass_hash(map)
			rebuild(map)
			snapshot(map, env, "cleanup")
			stage_hashes.cleanup = pass_hash(map)
			local hash_parts = { "hash", "env=" .. env }
			for i = 1, #stage_names do
				local stage = stage_names[i]
				hash_parts[#hash_parts + 1] = stage .. "=" .. stage_hashes[stage]
			end
			rows[#rows + 1] = table.concat(hash_parts, ",")
			info[#info + 1] = string.format("%s=%dx%d", env, gw, gh)
		end

		restore_all()
		local stamp_path = out_base .. "-probe.txt"
		local werr = AsyncStringToFile(stamp_path, table.concat(rows, "\n"))
		if werr then error("probe stamp write failed: " .. tostring(werr)) end
		g_ParityPerimeterFullInfo = string.format("boxes=%d %s", #boxes, table.concat(info, " "))
		g_ParityPerimeterFullStatus = "ready"
	end, debug.traceback)
	if not ok then
		restore_all()
		g_ParityPerimeterFullError = tostring(err)
		g_ParityPerimeterFullStatus = "error"
	end
end)
return "perimeter_full_probe_started"

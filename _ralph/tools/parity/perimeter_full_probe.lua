-- Full live replay of a data-derived stock perimeter box union.
--
-- The host binds one scenario-independent box list derived by perimetercheck.py.
-- For both maps this probe preserves complete property-lattice passability rasters:
--
--   baseline -> direct boxes -> bare rebuild -> marker rebuild -> repeat -> cleanup
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
		for i = 1, #specs do
			local s = specs[i]
			boxes[i] = box(point(s[1], s[2]), point(s[3], s[4]))
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
			local state = { map = map, markers = {} }
			cleanup[#cleanup + 1] = state
			rebuild(map)
			local gw, gh = snapshot(map, env, "baseline")
			calibration(map, env, gw, gh)
			local h0 = pass_hash(map)

			for i = 1, #boxes do
				local ok_c, err_c = pcall(terrain.ClearPassabilityBox, map, boxes[i])
				if not ok_c then error("direct ClearPassabilityBox failed: " .. tostring(err_c)) end
			end
			snapshot(map, env, "direct")
			local hd = pass_hash(map)

			rebuild(map)
			snapshot(map, env, "bare")
			local hb = pass_hash(map)

			for i = 1, #boxes do
				local marker = PlaceObjectIn("ForcedImpassableMarker", map)
				if not marker then error("PlaceObjectIn(ForcedImpassableMarker) returned nil") end
				marker.area = boxes[i]
				state.markers[#state.markers + 1] = marker
			end
			rebuild(map)
			snapshot(map, env, "marker1")
			local hm1 = pass_hash(map)
			rebuild(map)
			snapshot(map, env, "marker2")
			local hm2 = pass_hash(map)

			for i = #state.markers, 1, -1 do
				local marker = state.markers[i]
				if IsValid(marker) then DoneObject(marker) end
			end
			state.markers = {}
			rebuild(map)
			snapshot(map, env, "cleanup")
			local hc = pass_hash(map)
			rows[#rows + 1] = string.format(
				"hash,env=%s,baseline=%s,direct=%s,bare=%s,marker1=%s,marker2=%s,cleanup=%s",
				env, h0, hd, hb, hm1, hm2, hc)
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

-- Live stock-perimeter primitive probe.
--
-- Derive two small, disjoint boxes from each map's own pass-tile lattice, apply
-- them directly with terrain.ClearPassabilityBox, and then replay the identical
-- union through two stock ForcedImpassableMarker instances. The probe records
-- exact-edge samples and full passability hashes across these stages:
--
--   baseline -> direct write -> bare rebuild -> marker rebuild -> repeat -> cleanup
--
-- It is self-restoring and scenario-independent. The box centre is selected
-- from live passability near the map centre; no coordinate, seed, class, or
-- measured border constant is embedded here. Placeholder: __OUT_PATH__.

g_ParityPerimeterStatus = "running"
g_ParityPerimeterInfo = false
g_ParityPerimeterError = false

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
			pcall(ResumeInfiniteLoopDetection, "parity_perimeter")
			paused = false
		end
	end

	local ok, err = xpcall(function()
		local rows = {
			"env,ix,iy,x,y,p0,p_direct,p_bare,p_marker1,p_marker2,p_cleanup"
		}
		local info = {}
		local const_tbl = rawget(_G, "const")
		local pitch = (type(const_tbl) == "table" and tonumber(const_tbl.PassTileSize)) or 50
		local height_tile =
			(type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize)) or 100
		if pitch <= 0 or height_tile <= 0 then error("invalid terrain lattice constants") end
		if type(terrain) ~= "table" or type(terrain.ClearPassabilityBox) ~= "function"
			or type(terrain.HashPassability) ~= "function" then
			error("required stock passability APIs unavailable")
		end
		if type(PlaceObjectIn) ~= "function" then error("PlaceObjectIn unavailable") end

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
			PauseInfiniteLoopDetection("parity_perimeter")
			paused = true
		end

		local function boxes_for(cx, cy)
			return {
				box(point(cx - 8 * pitch, cy - 2 * pitch),
					point(cx + 8 * pitch, cy + 2 * pitch)),
				box(point(cx + 10 * pitch, cy - 8 * pitch),
					point(cx + 14 * pitch, cy + 8 * pitch)),
			}
		end
		local function in_closed_box(x, y, bx)
			return x >= bx:minx() and x <= bx:maxx()
				and y >= bx:miny() and y <= bx:maxy()
		end
		local function samples_for(map, cx, cy)
			local samples = {}
			for iy = -12, 12 do
				for ix = -18, 18 do
					local x, y = cx + ix * pitch, cy + iy * pitch
					local pt = point(x, y)
					if not map:IsPointInBounds(pt) then return nil end
					samples[#samples + 1] = {
						ix = ix, iy = iy, x = x, y = y, pt = pt,
						p0 = map:IsPassable(pt) and 1 or 0,
					}
				end
			end
			return samples
		end
		local function choose_site(map, width, height)
			local base_x = math.floor(width / (2 * pitch)) * pitch + pitch / 2
			local base_y = math.floor(height / (2 * pitch)) * pitch + pitch / 2
			local step = pitch * 80
			local best
			for gy = -10, 10 do
				for gx = -10, 10 do
					local cx, cy = base_x + gx * step, base_y + gy * step
					local samples = samples_for(map, cx, cy)
					if samples then
						local boxes = boxes_for(cx, cy)
						local interior, boundary = 0, 0
						for i = 1, #samples do
							local s = samples[i]
							if s.p0 == 1 then
								for j = 1, #boxes do
									local bx = boxes[j]
									if in_closed_box(s.x, s.y, bx) then
										interior = interior + 1
										if s.x == bx:minx() or s.x == bx:maxx()
											or s.y == bx:miny() or s.y == bx:maxy() then
											boundary = boundary + 1
										end
										break
									end
								end
							end
						end
						local candidate = {
							cx = cx, cy = cy, samples = samples, boxes = boxes,
							interior = interior, boundary = boundary,
						}
						if not best or boundary > best.boundary
							or (boundary == best.boundary and interior > best.interior) then
							best = candidate
						end
					end
				end
			end
			if not best or best.interior < 20 or best.boundary < 8 then
				error(string.format("could not derive an observable box site: interior=%s boundary=%s",
					tostring(best and best.interior), tostring(best and best.boundary)))
			end
			return best
		end
		local function stage(samples, key, map)
			for i = 1, #samples do
				samples[i][key] = map:IsPassable(samples[i].pt) and 1 or 0
			end
		end
		local function pass_hash(map)
			local ok_h, value = pcall(terrain.HashPassability, map)
			if not ok_h then error("HashPassability failed: " .. tostring(value)) end
			return tostring(value)
		end

		for _, env in ipairs({ "surface", "underground" }) do
			local map = maps[env]
			rebuild(map)
			local hgw, hgh = terrain.HeightMapSize(map)
			local width, height = hgw * height_tile, hgh * height_tile
			local chosen = choose_site(map, width, height)
			local samples, boxes = chosen.samples, chosen.boxes
			local state = { map = map, markers = {} }
			cleanup[#cleanup + 1] = state
			local h0 = pass_hash(map)

			for i = 1, #boxes do
				local ok_c, err_c = pcall(terrain.ClearPassabilityBox, map, boxes[i])
				if not ok_c then error("direct ClearPassabilityBox failed: " .. tostring(err_c)) end
			end
			stage(samples, "p_direct", map)
			local hd = pass_hash(map)

			rebuild(map)
			stage(samples, "p_bare", map)
			local hb = pass_hash(map)

			for i = 1, #boxes do
				local marker = PlaceObjectIn("ForcedImpassableMarker", map)
				if not marker then error("PlaceObjectIn(ForcedImpassableMarker) returned nil") end
				marker.area = boxes[i]
				state.markers[#state.markers + 1] = marker
			end
			rebuild(map)
			stage(samples, "p_marker1", map)
			local hm1 = pass_hash(map)
			rebuild(map)
			stage(samples, "p_marker2", map)
			local hm2 = pass_hash(map)

			for i = #state.markers, 1, -1 do
				local marker = state.markers[i]
				if IsValid(marker) then DoneObject(marker) end
			end
			state.markers = {}
			rebuild(map)
			stage(samples, "p_cleanup", map)
			local hc = pass_hash(map)

			rows[#rows + 1] = string.format(
				"#meta,%s,pitch=%d,height_tile=%d,cx=%d,cy=%d,interior_pass=%d,boundary_pass=%d",
				env, pitch, height_tile, chosen.cx, chosen.cy, chosen.interior, chosen.boundary)
			for i = 1, #boxes do
				local bx = boxes[i]
				rows[#rows + 1] = string.format("#box,%s,%d,%d,%d,%d,%d", env, i,
					bx:minx(), bx:miny(), bx:maxx(), bx:maxy())
			end
			rows[#rows + 1] = string.format(
				"#hash,%s,baseline=%s,direct=%s,bare=%s,marker1=%s,marker2=%s,cleanup=%s",
				env, h0, hd, hb, hm1, hm2, hc)
			for i = 1, #samples do
				local s = samples[i]
				rows[#rows + 1] = table.concat({ env, s.ix, s.iy, s.x, s.y, s.p0,
					s.p_direct, s.p_bare, s.p_marker1, s.p_marker2, s.p_cleanup }, ",")
			end
			info[#info + 1] = string.format("%s=%d samples/%d boundary", env, #samples,
				chosen.boundary)
		end

		restore_all()
		local werr = AsyncStringToFile("__OUT_PATH__", table.concat(rows, "\n"))
		if werr then error("perimeter probe write failed: " .. tostring(werr)) end
		g_ParityPerimeterInfo = table.concat(info, " ")
		g_ParityPerimeterStatus = "ready"
	end, debug.traceback)
	if not ok then
		restore_all()
		g_ParityPerimeterError = tostring(err)
		g_ParityPerimeterStatus = "error"
	end
end)
return "perimeter_probe_started"

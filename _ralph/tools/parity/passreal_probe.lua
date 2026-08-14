-- `pass-real-inside-zones` probe.
--
-- The contract demands that passability INSIDE the compression zones reflect the REAL final
-- terrain: never faked toward vanilla, never left stale. "Not faked" is already measured by
-- `passverdict.py` (the in-zone rows differ from vanilla and are flagged `inside`). This probe
-- measures the other half - that the pass data the game is serving inside the zones is what the
-- engine recomputes from the final height grid, i.e. that nothing is stale.
--
-- Method, on the finished map, before anything else touches it:
--   stage a  sample terrain height + passability on a stride grid inside every massif crop
--            (and on a whole-map control grid outside every crop),
--   stage b  force a FRESH full-map terrain.RebuildPassability and re-sample,
--   stage c  rebuild a second time and re-sample (idempotence).
-- A cell whose stage a differs from stage b was being served from stale pass data.
--
-- Stage b proving nothing is only excluded by the spike control that follows it: at a passable
-- control site the probe raises a steep cone with pass edits SUSPENDED (so passability is stale
-- BY CONSTRUCTION), samples it, then resumes and rebuilds and samples again. Unless that control
-- shows the constructed staleness and its repair, the zero above is not evidence, and the report
-- says so. The control runs last, after every gate sample is taken, and its site is chosen from
-- the outside-zone control set, never from a massif.
--
-- Placeholders: __OUT_PATH__, __ZONE_TARGET__, __OUTSIDE_TARGET__.

g_ParityPassRealStatus = "running"
g_ParityPassRealInfo = false
g_ParityPassRealError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local zone_target = __ZONE_TARGET__
		local outside_target = __OUTSIDE_TARGET__
		local out = {}
		local function emit(s) out[#out + 1] = s end

		local surface, underground
		for i = 1, #(Maps or {}) do
			local m = Maps[i]
			local env = m and m.mapdata and m.mapdata.Environment
			if env == "Surface" and not surface then surface = m end
			if env == "Underground" and not underground then underground = m end
		end
		if not surface then error("surface map not found") end

		local const_tbl = rawget(_G, "const")
		local tile = (type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize)) or 100
		local gw, gh = terrain.HeightMapSize(surface)
		local massifs = surface.SuperBigMapZCompressionZones or {}

		emit("#meta,map=surface,grid=" .. tostring(gw) .. "x" .. tostring(gh)
			.. ",tile=" .. tostring(tile)
			.. ",zmul=" .. tostring(surface.SuperBigMapZScaleMul)
			.. ",zdiv=" .. tostring(surface.SuperBigMapZScaleDiv)
			.. ",zadd=" .. tostring(surface.SuperBigMapZScaleAdd)
			.. ",measured_max=" .. tostring(surface.SuperBigMapZMeasuredMaxHeight)
			.. ",massifs=" .. tostring(#massifs))
		for i, m in ipairs(massifs) do
			emit(string.format("#massif,%d,x0=%d,y0=%d,x1=%d,y1=%d,base=%d,base_img=%d,peak=%d,"
				.. "peak_img=%s,peak_x=%d,peak_y=%d,cells=%d",
				i, m.x0, m.y0, m.x1, m.y1, m.base, m.base_img, m.peak, tostring(m.peak_img),
				m.peak_x, m.peak_y, m.cells))
		end

		-- Sample plan. Massif bboxes are half-open [x0,x1) x [y0,y1), the convention the offline
		-- zonecheck already uses, so a cell is "in a crop" under exactly the same test there.
		local samples = {}
		local skipped_bounds = 0
		local function add_sample(set, massif, gx, gy)
			local x = gx * tile + tile / 2
			local y = gy * tile + tile / 2
			local pt = point(x, y)
			if not surface:IsPointInBounds(pt) then
				skipped_bounds = skipped_bounds + 1
				return
			end
			samples[#samples + 1] = { set = set, massif = massif, gx = gx, gy = gy, x = x, y = y, pt = pt }
		end

		local strides = {}
		for i, m in ipairs(massifs) do
			local w, h = m.x1 - m.x0, m.y1 - m.y0
			local area = w * h
			local stride = math.max(1, math.floor(math.sqrt((area + 0.0) / zone_target) + 0.5))
			strides[i] = stride
			local gy = m.y0
			while gy < m.y1 do
				local gx = m.x0
				while gx < m.x1 do
					add_sample("zone", i, gx, gy)
					gx = gx + stride
				end
				gy = gy + stride
			end
		end

		local function in_any_crop(gx, gy)
			for i, m in ipairs(massifs) do
				if gx >= m.x0 and gx < m.x1 and gy >= m.y0 and gy < m.y1 then return i end
			end
			return nil
		end
		local out_stride = math.max(1, math.floor(math.sqrt((gw * gh + 0.0) / outside_target) + 0.5))
		local gy = 0
		while gy < gh do
			local gx = 0
			while gx < gw do
				if not in_any_crop(gx, gy) then add_sample("outside", 0, gx, gy) end
				gx = gx + out_stride
			end
			gy = gy + out_stride
		end

		if type(PauseInfiniteLoopDetection) == "function" then
			PauseInfiniteLoopDetection("parity_passreal")
		end

		local function sample_stage(key)
			for i = 1, #samples do
				local s = samples[i]
				s["h_" .. key] = surface:GetHeight(s.pt)
				s["p_" .. key] = surface:IsPassable(s.pt) and 1 or 0
			end
		end

		local t0 = GetPreciseTicks()
		sample_stage("a")
		local t_a = GetPreciseTicks() - t0

		-- Fresh recompute of the whole map from the final terrain.
		local rb1_t = GetPreciseTicks()
		local rb1_ok, rb1_err = pcall(terrain.RebuildPassability, surface)
		rb1_t = GetPreciseTicks() - rb1_t
		if not rb1_ok then error("RebuildPassability failed: " .. tostring(rb1_err)) end
		sample_stage("b")

		local rb2_t = GetPreciseTicks()
		local rb2_ok = pcall(terrain.RebuildPassability, surface)
		rb2_t = GetPreciseTicks() - rb2_t
		sample_stage("c")

		-- Spike control: construct staleness on purpose, far from every massif.
		local centre_gx, centre_gy = math.floor(gw / 2), math.floor(gh / 2)
		local site, site_d
		for i = 1, #samples do
			local s = samples[i]
			if s.set == "outside" and s.p_c == 1 then
				local dx, dy = s.gx - centre_gx, s.gy - centre_gy
				local d = dx * dx + dy * dy
				if not site_d or d < site_d then site, site_d = s, d end
			end
		end
		local control = {}
		local control_note = "none"
		if site then
			local radius_cells = 12
			for dy = -radius_cells, radius_cells do
				for dx = -radius_cells, radius_cells do
					if dx * dx + dy * dy <= radius_cells * radius_cells then
						local cx, cy = site.gx + dx, site.gy + dy
						if cx >= 0 and cx < gw and cy >= 0 and cy < gh then
							local x, y = cx * tile + tile / 2, cy * tile + tile / 2
							local pt = point(x, y)
							if surface:IsPointInBounds(pt) then
								control[#control + 1] = { set = "spike", massif = 0, gx = cx, gy = cy,
									x = x, y = y, pt = pt }
							end
						end
					end
				end
			end
			local function control_stage(key)
				for i = 1, #control do
					local s = control[i]
					s["h_" .. key] = surface:GetHeight(s.pt)
					s["p_" .. key] = surface:IsPassable(s.pt) and 1 or 0
				end
			end
			control_stage("a")
			local base_h = surface:GetHeight(site.pt)
			local susp_ok = pcall(surface.SuspendPassEdits, surface, "parity_passreal")
			local edit_ok, edit_err = pcall(terrain.SetHeightCircle, surface, site.pt,
				2 * tile, 12 * tile, base_h + 25000)
			control_stage("b")
			pcall(surface.ResumePassEdits, surface, "parity_passreal")
			local rb3_ok = pcall(terrain.RebuildPassability, surface)
			control_stage("c")
			control_note = string.format("site=%d,%d suspend=%s edit=%s rebuild=%s base_h=%d",
				site.gx, site.gy, tostring(susp_ok), tostring(edit_ok) .. (edit_ok and "" or (":" .. tostring(edit_err))),
				tostring(rb3_ok), base_h)
		end

		if type(ResumeInfiniteLoopDetection) == "function" then
			ResumeInfiniteLoopDetection("parity_passreal")
		end

		emit("#stride,outside=" .. tostring(out_stride) .. ",zone="
			.. table.concat(strides, "|"))
		emit(string.format("#timing,sample_ms=%d,rebuild1_ms=%d,rebuild2_ms=%d,rebuild2_ok=%s",
			t_a, rb1_t, rb2_t, tostring(rb2_ok)))
		emit("#control," .. control_note)
		emit("#skipped_out_of_bounds," .. tostring(skipped_bounds))
		emit("set,massif,gx,gy,x,y,h_a,p_a,h_b,p_b,h_c,p_c")
		local function emit_rows(list)
			for i = 1, #list do
				local s = list[i]
				emit(table.concat({ s.set, tostring(s.massif), tostring(s.gx), tostring(s.gy),
					tostring(s.x), tostring(s.y),
					tostring(s.h_a), tostring(s.p_a), tostring(s.h_b), tostring(s.p_b),
					tostring(s.h_c), tostring(s.p_c) }, ","))
			end
		end
		emit_rows(samples)
		emit_rows(control)

		local werr = AsyncStringToFile("__OUT_PATH__", table.concat(out, "\n"))
		if werr then error("write failed: " .. tostring(werr)) end
		g_ParityPassRealInfo = string.format(
			"massifs=%d zone_samples+outside=%d control=%d skipped=%d rebuild1_ms=%d",
			#massifs, #samples, #control, skipped_bounds, rb1_t)
		g_ParityPassRealStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityPassRealError = tostring(err)
		g_ParityPassRealStatus = "error"
	end
end)
return "passreal_probe_started"

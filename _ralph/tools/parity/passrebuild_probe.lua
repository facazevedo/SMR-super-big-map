-- Passability-REBUILD probe (item C1 of the user ruling's terrain-only investigation).
--
-- Iteration 021 found that the largest single term of the "object-free" passability residual is
-- not terrain at all: on the UNDERGROUND control at 45S82E, 326 of 706 differing samples are FLAT
-- (max edge slope < 5 wu) yet vanilla-impassable, in a disc of radius ~24,000 SOURCE wu around the
-- underground `BottomlessPit` (src 298000,301368).  Heights there are the exact affine image, so
-- the difference cannot be the Z transform; vanilla blocks 301 of 510 samples in that disc and the
-- expanded map blocks 5.  Something applies NON-TERRAIN impassability there that the expanded map
-- does not have.
--
-- Two candidate mechanisms, and one measurement separates them:
--   (a) the expanded map applies it too, but the mod's later full-map `terrain.RebuildPassability`
--       (`sbm_map_bounds.lua:188`, `sbm_map_generation.lua:11549`, `sbm_terrain_copy.lua:256`)
--       WIPES it - then a plain rebuild on the VANILLA twin must wipe it there as well;
--   (b) the expanded map never applied it - then a rebuild on the vanilla twin leaves it standing.
-- So: sample the disc, force the same full-map rebuild the mod calls, re-sample, rebuild once more
-- and re-sample (idempotence).  A cell whose p_a=0 turns p_b=1 was impassability the rebuild wiped.
--
-- Run on BOTH twins with the same probe: on the vanilla twin it decides (a) vs (b); on the
-- expanded twin it shows whether the disc is absent from the start (p_a) and whether a rebuild
-- creates it (p_b) - i.e. whether the mechanism is present but unapplied there.
--
-- The probe also records what could be applying it, because "read Lua to find a terrain writer" is
-- a recorded dead end of this task:
--   * every `ForcedImpassableMarker` of the map (marker.lua re-applies their boxes from
--     `OnMsg.OnPassabilityRebuilding` on every rebuild) with its area box, and per sample the
--     index of the marker box containing it;
--   * every object within the scan radius that carries `efApplyToGrids`, with its entity bounding
--     box - the extent-aware footprint data item C2 needs anyway.
--
-- This probe MUTATES passability, so it must run last, after every reading probe.
--
-- Placeholders: __POS_SCALE__, __CENTRE_CLASS__, __RADIUS__, __STRIDE__, __OUT_PATH__.

g_ParityPassRbStatus = "running"
g_ParityPassRbInfo = false
g_ParityPassRbError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local scale = __POS_SCALE__            -- 1.0 on the vanilla twin, 8192/6144 on the expanded
		local centre_class = "__CENTRE_CLASS__" -- object class whose neighbourhood is scanned
		local radius_src = __RADIUS__          -- scan radius, SOURCE wu
		local stride_src = __STRIDE__          -- lattice step, SOURCE wu
		local out = {}
		local function emit(s) out[#out + 1] = s end

		local const_tbl = rawget(_G, "const")
		local tile = (type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize)) or 100
		local ef_grids = (type(const_tbl) == "table" and const_tbl.efApplyToGrids) or nil

		emit("#meta,scale=" .. tostring(scale) .. ",centre_class=" .. centre_class
			.. ",radius_src=" .. tostring(radius_src) .. ",stride_src=" .. tostring(stride_src)
			.. ",tile=" .. tostring(tile))
		emit("map,sgx,sgy,x,y,h,p_a,p_b,p_c,d_src,mark")

		local function box_bounds(b)
			local ok_b, x0, y0, x1, y1 = pcall(function()
				return b:minx(), b:miny(), b:maxx(), b:maxy()
			end)
			if not ok_b then return nil end
			return x0, y0, x1, y1
		end

		local function probe_map(map, tag)
			if not map then return nil end
			local gw, gh = terrain.HeightMapSize(map)
			local objs = map:MapGet("map") or {}

			-- Centre: the object of the named class on this map (its own, already-scaled position).
			local cx, cy, ncentre = nil, nil, 0
			for i = 1, #objs do
				local obj = objs[i]
				if obj and IsValid(obj) and obj.class == centre_class then
					ncentre = ncentre + 1
					if not cx then
						local ok_pos, px, py = pcall(obj.GetVisualPosXYZ, obj)
						if ok_pos then cx, cy = px, py end
					end
				end
			end
			if not cx then
				emit("#skip," .. tag .. ",no_object_of_class=" .. centre_class
					.. ",objects=" .. tostring(#objs))
				return { skipped = true, objects = #objs }
			end

			-- Forced-impassable markers: the engine re-applies their boxes on EVERY rebuild.
			local marks = rawget(map, "ForcedImpassableMarkers")
			if type(marks) ~= "table" then marks = map.ForcedImpassableMarkers end
			local mark_boxes = {}
			if type(marks) == "table" then
				for i = 1, #marks do
					local m = marks[i]
					local ok_a, area = pcall(m.GetArea, m)
					local x0, y0, x1, y1
					if ok_a and area then x0, y0, x1, y1 = box_bounds(area) end
					local ok_p, px, py = pcall(m.GetVisualPosXYZ, m)
					mark_boxes[#mark_boxes + 1] = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
					emit(string.format("#marker,%s,%d,%s,%s,%s,%s,%s,%s,%s", tag, i,
						tostring(m.class), ok_p and tostring(px) or "?", ok_p and tostring(py) or "?",
						tostring(x0), tostring(y0), tostring(x1), tostring(y1)))
				end
			end
			emit("#markers," .. tag .. ",n=" .. tostring(type(marks) == "table" and #marks or -1))

			-- Objects with efApplyToGrids inside the scan neighbourhood, with entity extents.
			local scan = radius_src * scale * 3 / 2
			local ngrid, nlisted = 0, 0
			for i = 1, #objs do
				local obj = objs[i]
				if obj and IsValid(obj) then
					local ok_pos, px, py = pcall(obj.GetVisualPosXYZ, obj)
					if ok_pos and type(px) == "number" then
						local dx, dy = px - cx, py - cy
						if dx * dx + dy * dy <= scan * scan then
							local applies = true
							if ef_grids and type(obj.GetEnumFlags) == "function" then
								local ok_f, f = pcall(obj.GetEnumFlags, obj, ef_grids)
								if ok_f then applies = (f ~= 0) end
							end
							if applies then
								ngrid = ngrid + 1
								if nlisted < 200 then
									nlisted = nlisted + 1
									local ent, bw, bh = "?", "?", "?"
									if type(obj.GetEntity) == "function" then
										local ok_e, e = pcall(obj.GetEntity, obj)
										if ok_e and e then
											ent = tostring(e)
											if type(rawget(_G, "GetEntityBoundingBox")) == "function" then
												local ok_bb, bb = pcall(GetEntityBoundingBox, e)
												if ok_bb and bb then
													local x0, y0, x1, y1 = box_bounds(bb)
													if x0 then
														bw, bh = tostring(x1 - x0), tostring(y1 - y0)
													end
												end
											end
										end
									end
									emit(string.format("#gridobj,%s,%s,%s,%d,%d,%s,%s,%s", tag,
										tostring(obj.class), ent, px, py, bw, bh,
										tostring(math.floor(math.sqrt(dx * dx + dy * dy) / scale + 0.5))))
								end
							end
						end
					end
				end
			end
			emit("#gridobjs," .. tag .. ",in_scan=" .. tostring(ngrid)
				.. ",listed=" .. tostring(nlisted) .. ",scan_src="
				.. tostring(math.floor(scan / scale + 0.5))
				.. ",centre_x=" .. tostring(cx) .. ",centre_y=" .. tostring(cy)
				.. ",centre_count=" .. tostring(ncentre))

			-- Sample lattice in SOURCE cells around the centre, so both twins walk the same ground.
			local stride_cells = math.max(1, math.floor(stride_src / tile + 0.5))
			local radius_cells = math.floor(radius_src / tile + 0.5)
			local c_sgx = math.floor(cx / scale / tile)
			local c_sgy = math.floor(cy / scale / tile)

			if type(PauseInfiniteLoopDetection) == "function" then
				PauseInfiniteLoopDetection("parity_passrb")
			end

			local samples = {}
			local dy = -radius_cells
			while dy <= radius_cells do
				local dx = -radius_cells
				while dx <= radius_cells do
					local sgx, sgy = c_sgx + dx, c_sgy + dy
					if sgx >= 0 and sgy >= 0 then
						local x = math.floor((sgx * tile + tile / 2) * scale + 0.5)
						local y = math.floor((sgy * tile + tile / 2) * scale + 0.5)
						local pt = point(x, y)
						if map:IsPointInBounds(pt) then
							local ddx, ddy = x - cx, y - cy
							local mark = -1
							for k = 1, #mark_boxes do
								local mb = mark_boxes[k]
								if mb.x0 and x >= mb.x0 and x < mb.x1 and y >= mb.y0 and y < mb.y1 then
									mark = k
									break
								end
							end
							samples[#samples + 1] = { sgx = sgx, sgy = sgy, x = x, y = y, pt = pt,
								d = math.floor(math.sqrt(ddx * ddx + ddy * ddy) / scale + 0.5),
								mark = mark }
						end
					end
					dx = dx + stride_cells
				end
				dy = dy + stride_cells
			end

			local function stage(key)
				for i = 1, #samples do
					local s = samples[i]
					s["p_" .. key] = map:IsPassable(s.pt) and 1 or 0
				end
			end

			local t0 = GetPreciseTicks()
			for i = 1, #samples do
				local s = samples[i]
				s.h = map:GetHeight(s.pt)
			end
			stage("a")
			local rb1 = GetPreciseTicks()
			local rb1_ok, rb1_err = pcall(terrain.RebuildPassability, map)
			rb1 = GetPreciseTicks() - rb1
			stage("b")
			local rb2 = GetPreciseTicks()
			local rb2_ok = pcall(terrain.RebuildPassability, map)
			rb2 = GetPreciseTicks() - rb2
			stage("c")

			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_passrb")
			end

			local blocked_a, blocked_b, blocked_c, wiped, gained = 0, 0, 0, 0, 0
			for i = 1, #samples do
				local s = samples[i]
				if s.p_a == 0 then blocked_a = blocked_a + 1 end
				if s.p_b == 0 then blocked_b = blocked_b + 1 end
				if s.p_c == 0 then blocked_c = blocked_c + 1 end
				if s.p_a == 0 and s.p_b == 1 then wiped = wiped + 1 end
				if s.p_a == 1 and s.p_b == 0 then gained = gained + 1 end
			end

			emit(string.format("#summary,%s,grid=%dx%d,samples=%d,blocked_a=%d,blocked_b=%d,"
				.. "blocked_c=%d,wiped=%d,gained=%d,rebuild1_ms=%d,rebuild1_ok=%s,rebuild2_ms=%d,"
				.. "rebuild2_ok=%s,ms=%d", tag, gw, gh, #samples, blocked_a, blocked_b, blocked_c,
				wiped, gained, rb1, tostring(rb1_ok) .. (rb1_ok and "" or (":" .. tostring(rb1_err))),
				rb2, tostring(rb2_ok), GetPreciseTicks() - t0))

			for i = 1, #samples do
				local s = samples[i]
				emit(table.concat({ tag, tostring(s.sgx), tostring(s.sgy), tostring(s.x), tostring(s.y),
					tostring(s.h), tostring(s.p_a), tostring(s.p_b), tostring(s.p_c),
					tostring(s.d), tostring(s.mark) }, ","))
			end
			return { samples = #samples, blocked_a = blocked_a, blocked_b = blocked_b,
				wiped = wiped, gained = gained, markers = type(marks) == "table" and #marks or -1,
				gridobjs = ngrid }
		end

		local surface, underground
		for i = 1, #(Maps or {}) do
			local m = Maps[i]
			local env = m and m.mapdata and m.mapdata.Environment
			if env == "Surface" and not surface then surface = m end
			if env == "Underground" and not underground then underground = m end
		end
		local s = probe_map(surface, "surface")
		local u = probe_map(underground, "underground")

		local werr = AsyncStringToFile("__OUT_PATH__", table.concat(out, "\n"))
		if werr then error("write failed: " .. tostring(werr)) end
		local function brief(r)
			if not r then return "-" end
			if r.skipped then return "skipped(no centre object)" end
			return string.format("n=%d blocked %d->%d wiped=%d gained=%d markers=%d gridobjs=%d",
				r.samples, r.blocked_a, r.blocked_b, r.wiped, r.gained, r.markers, r.gridobjs)
		end
		g_ParityPassRbInfo = "surface " .. brief(s) .. " | underground " .. brief(u)
		g_ParityPassRbStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityPassRbError = tostring(err)
		g_ParityPassRbStatus = "error"
	end
end)
return "passrebuild_probe_started"

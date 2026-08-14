-- Passability OWNERSHIP probe (item C1c: who owns the pit-region mask's bits, tested by writes
-- that must be visible).
--
-- State of the investigation (45S82E underground, flat ground around the `BottomlessPit`): vanilla
-- blocks ~54% of a 40,401-cell window and the expanded twin almost none, while every measured input
-- matches - height (022), terrain type (023), nearby objects (023), forced flag and pass type (024).
-- Neither rebuild path changes anything, INCLUDING the engine generator's own
-- Invalidate+Rebuild sequence over the window and over the whole map (026), yet the whole-map
-- `HashPassability` moves at the full rebuild, so the mask is deterministically re-derived from a
-- persistent input that none of those probes sampled.  Iter 027's whole-map lattice adds that the
-- body is LOCAL (~44,400 x 24,000 src wu around the pit) while the twins' cave-wall masks agree
-- everywhere else.
--
-- This probe stops asking WHICH input and asks WHO OWNS THE BITS:
--   s0  baseline sample of the window
--   pick two write boxes automatically from s0, on FLAT ground whose verdict CAN change (the 026
--       lesson): boxA all-blocked (write passable), boxB all-free (write impassable).  Both twins
--       therefore test both directions on ground where the write is observable.
--   s1  terrain.SetPassability(map, box, value) on both boxes  -> did the write take at all?
--   s2  the engine's own InvalidateHeight+InvalidateType+RebuildPassability over the grown boxes
--       -> does the write SURVIVE a local rebuild?
--   s3  the same over the WHOLE map -> does it survive the full rebuild the mod itself runs after
--       stretching?
-- `terrain.HashPassability(map)` at every stage; `IsForcedImpassable` inside the boxes at s1/s3.
--
-- Reading:
--   * write takes and survives s2/s3 -> the rebuild does not own those cells; a mod-side repair
--     that writes the missing mask after the stretch is durable, and the remaining question is only
--     what shape to write;
--   * write takes and REVERTS -> an input drives those cells and the ablation continues
--     (editor.SetPassableBox, then terrain.ClearTerrainHolesBaseGrid, the last unsampled class);
--   * write does not take at all -> that signature is a no-op like SetForcedImpassableBox(map, box)
--     was (026), and the run says so instead of proving anything.
--
-- MUTATES passability: runs LAST and ALONE, never with a reading probe whose output is scored.
--
-- Placeholders: __POS_SCALE__, __CENTRE_CLASS__, __RADIUS__, __STRIDE__, __BOXHALF__, __OUT_PATH__.

g_ParityPassOwnStatus = "running"
g_ParityPassOwnInfo = false
g_ParityPassOwnError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local scale = __POS_SCALE__             -- 1.0 on the vanilla twin, 8192/6144 on the expanded
		local centre_class = "__CENTRE_CLASS__" -- object class whose neighbourhood is scanned
		local radius_src = __RADIUS__           -- scan radius, SOURCE wu
		local stride_src = __STRIDE__           -- lattice step, SOURCE wu
		local box_half_src = __BOXHALF__        -- write box half-side, SOURCE wu
		local out = {}
		local function emit(s) out[#out + 1] = s end

		local const_tbl = rawget(_G, "const")
		local tile = (type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize)) or 100
		local terrain_api = rawget(_G, "terrain")

		emit("#meta,scale=" .. tostring(scale) .. ",centre_class=" .. centre_class
			.. ",radius_src=" .. tostring(radius_src) .. ",stride_src=" .. tostring(stride_src)
			.. ",box_half_src=" .. tostring(box_half_src) .. ",tile=" .. tostring(tile))
		emit("map,sgx,sgy,x,y,h,p0,p1,p2,p3,d_src,wbox,forced1,forced3")

		local function has(fname)
			return type(terrain_api) == "table" and type(terrain_api[fname]) == "function"
		end
		for _, fname in ipairs({ "SetPassability", "ClearPassabilityBox", "InvalidateHeight",
			"InvalidateType", "RebuildPassability", "IsForcedImpassable", "HashPassability" }) do
			emit("#api," .. fname .. "," .. tostring(has(fname)))
		end

		local function probe_map(map, tag)
			if not map then return nil end
			local gw, gh = terrain.HeightMapSize(map)
			local objs = map:MapGet("map") or {}
			local cx, cy = nil, nil
			for i = 1, #objs do
				local obj = objs[i]
				if obj and IsValid(obj) and obj.class == centre_class and not cx then
					local ok_pos, px, py = pcall(obj.GetVisualPosXYZ, obj)
					if ok_pos then cx, cy = px, py end
				end
			end
			if not cx then
				emit("#skip," .. tag .. ",no_object_of_class=" .. centre_class
					.. ",objects=" .. tostring(#objs))
				return { skipped = true, objects = #objs }
			end

			local stride_cells = math.max(1, math.floor(stride_src / tile + 0.5))
			local radius_cells = math.floor(radius_src / tile + 0.5)
			local c_sgx = math.floor(cx / (scale * tile) + 0.5)
			local c_sgy = math.floor(cy / (scale * tile) + 0.5)
			emit(string.format("#centre,%s,x=%d,y=%d,sgx=%d,sgy=%d,objects=%d,grid=%dx%d",
				tag, cx, cy, c_sgx, c_sgy, #objs, gw, gh))

			local samples, by_cell = {}, {}
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
							local s = { sgx = sgx, sgy = sgy, x = x, y = y, pt = pt,
								d = math.floor(math.sqrt(ddx * ddx + ddy * ddy) / scale + 0.5),
								wbox = 0, forced1 = -1, forced3 = -1 }
							samples[#samples + 1] = s
							by_cell[sgx .. "," .. sgy] = s
						end
					end
					dx = dx + stride_cells
				end
				dy = dy + stride_cells
			end

			if type(PauseInfiniteLoopDetection) == "function" then
				PauseInfiniteLoopDetection("parity_passown")
			end

			local function stage(key)
				for i = 1, #samples do
					local s = samples[i]
					s["p" .. key] = map:IsPassable(s.pt) and 1 or 0
				end
			end
			local function hash()
				if not has("HashPassability") then return "missing" end
				local ok_h, h = pcall(terrain_api.HashPassability, map)
				return ok_h and tostring(h) or ("error:" .. tostring(h))
			end
			local function forced(pt)
				if not has("IsForcedImpassable") then return -1 end
				local ok_f, f = pcall(terrain_api.IsForcedImpassable, map, pt)
				if not ok_f then return -2 end
				return f and 1 or 0
			end
			local function invalidate_rebuild(bx, label)
				local t0 = GetPreciseTicks()
				local rep = {}
				for _, fname in ipairs({ "InvalidateHeight", "InvalidateType" }) do
					if has(fname) then
						local ok_i, e = pcall(terrain_api[fname], map, bx)
						rep[#rep + 1] = fname .. "=" .. tostring(ok_i)
							.. (ok_i and "" or (":" .. string.gsub(tostring(e), "[,\r\n]", " ")))
					else
						rep[#rep + 1] = fname .. "=missing"
					end
				end
				local ok_r, e = pcall(terrain_api.RebuildPassability, map, bx)
				rep[#rep + 1] = "RebuildPassability=" .. tostring(ok_r)
					.. (ok_r and "" or (":" .. string.gsub(tostring(e), "[,\r\n]", " ")))
				emit(string.format("#step,%s,%s,ms=%d,%s", tag, label,
					GetPreciseTicks() - t0, table.concat(rep, ";")))
			end

			local t0 = GetPreciseTicks()
			for i = 1, #samples do samples[i].h = map:GetHeight(samples[i].pt) end
			stage("0")
			local h0 = hash()

			-- Pick two write boxes on FLAT ground whose verdict CAN change: every sampled cell in
			-- the box shares one verdict and one height.  Scanned outward from the centre so both
			-- boxes sit in the region under investigation.
			local box_cells = math.max(1, math.floor(box_half_src / tile + 0.5))
			local function pick(want_blocked)
				local best, best_d = nil, nil
				for i = 1, #samples do
					local s = samples[i]
					local want = want_blocked and 0 or 1
					if s.p0 == want then
						local okc, n = true, 0
						local ddy = -box_cells
						while ddy <= box_cells and okc do
							local ddx = -box_cells
							while ddx <= box_cells and okc do
								local key = (s.sgx + ddx) .. "," .. (s.sgy + ddy)
								local o = by_cell[key]
								if o then
									n = n + 1
									if o.p0 ~= want or o.h ~= s.h then okc = false end
								end
								ddx = ddx + stride_cells
							end
							ddy = ddy + stride_cells
						end
						if okc and n >= 9 and (not best_d or s.d < best_d) then
							best, best_d = s, s.d
						end
					end
				end
				return best
			end
			local a = pick(true)   -- all-blocked  -> write PASSABLE
			local b = pick(false)  -- all-free     -> write IMPASSABLE
			local function mkbox(s)
				if not s then return nil end
				local half = box_half_src * scale
				return box(point(math.floor(s.x - half), math.floor(s.y - half)),
					point(math.floor(s.x + half), math.floor(s.y + half)))
			end
			local boxA, boxB = mkbox(a), mkbox(b)
			local function mark(bx, id)
				if not bx then return 0 end
				local n = 0
				for i = 1, #samples do
					local s = samples[i]
					if s.x >= bx:minx() and s.x <= bx:maxx()
						and s.y >= bx:miny() and s.y <= bx:maxy() then
						s.wbox = id
						n = n + 1
					end
				end
				return n
			end
			local nA, nB = mark(boxA, 1), mark(boxB, 2)
			emit(string.format("#wbox,%s,A,%s,cells=%d,%s", tag,
				a and string.format("sgx=%d,sgy=%d,h=%d,d=%d", a.sgx, a.sgy, a.h, a.d) or "none",
				nA, boxA and string.format("box=%d;%d;%d;%d", boxA:minx(), boxA:miny(),
					boxA:maxx(), boxA:maxy()) or "-"))
			emit(string.format("#wbox,%s,B,%s,cells=%d,%s", tag,
				b and string.format("sgx=%d,sgy=%d,h=%d,d=%d", b.sgx, b.sgy, b.h, b.d) or "none",
				nB, boxB and string.format("box=%d;%d;%d;%d", boxB:minx(), boxB:miny(),
					boxB:maxx(), boxB:maxy()) or "-"))

			-- s1: the writes.  Argument convention resolved at run time, map-first shapes only.
			local function write(bx, value, label)
				if not bx then return "no_box" end
				if not has("SetPassability") then return "missing" end
				local shapes = {
					{ "map_box_value", function() return terrain_api.SetPassability(map, bx, value) end },
					{ "box_value", function() return terrain_api.SetPassability(bx, value) end },
					{ "map_box_value_true", function() return terrain_api.SetPassability(map, bx, value, true) end },
				}
				local notes = {}
				for _, sh in ipairs(shapes) do
					local ok_w, e = pcall(sh[2])
					notes[#notes + 1] = sh[1] .. "=" .. tostring(ok_w)
						.. (ok_w and "" or (":" .. string.gsub(tostring(e), "[,\r\n]", " ")))
					if ok_w then
						emit("#write," .. tag .. "," .. label .. ",value=" .. tostring(value)
							.. "," .. table.concat(notes, ";"))
						return sh[1]
					end
				end
				emit("#write," .. tag .. "," .. label .. ",value=" .. tostring(value)
					.. "," .. table.concat(notes, ";"))
				return "failed"
			end
			local shapeA = write(boxA, true, "A")
			local shapeB = write(boxB, false, "B")
			stage("1")
			local h1 = hash()
			for i = 1, #samples do
				if samples[i].wbox > 0 then samples[i].forced1 = forced(samples[i].pt) end
			end

			-- s2: the engine's own sequence over the grown write boxes.
			local function grow(bx)
				if not bx then return nil end
				local pad = math.floor(400 * scale)
				return box(point(bx:minx() - pad, bx:miny() - pad),
					point(bx:maxx() + pad, bx:maxy() + pad))
			end
			if boxA then invalidate_rebuild(grow(boxA), "s2_rebuild_boxA") end
			if boxB then invalidate_rebuild(grow(boxB), "s2_rebuild_boxB") end
			stage("2")
			local h2 = hash()

			-- s3: the whole map, the hammer the mod itself runs after stretching.
			local full = box(point(0, 0), point(gw * tile, gh * tile))
			invalidate_rebuild(full, "s3_fullmap")
			stage("3")
			local h3 = hash()
			for i = 1, #samples do
				if samples[i].wbox > 0 then samples[i].forced3 = forced(samples[i].pt) end
			end

			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_passown")
			end

			local blocked = { 0, 0, 0, 0 }
			local st = { [1] = { 0, 0, 0, 0, 0 }, [2] = { 0, 0, 0, 0, 0 } }  -- n, b0, b1, b2, b3
			for i = 1, #samples do
				local s = samples[i]
				for k = 0, 3 do
					if s["p" .. k] == 0 then blocked[k + 1] = blocked[k + 1] + 1 end
				end
				if s.wbox > 0 then
					local r = st[s.wbox]
					r[1] = r[1] + 1
					for k = 0, 3 do
						if s["p" .. k] == 0 then r[k + 2] = r[k + 2] + 1 end
					end
				end
			end

			emit(string.format("#hash,%s,h0=%s,h1=%s,h2=%s,h3=%s", tag, h0, h1, h2, h3))
			emit(string.format("#summary,%s,grid=%dx%d,samples=%d,blocked0=%d,blocked1=%d,"
				.. "blocked2=%d,blocked3=%d,shapeA=%s,shapeB=%s,A_n=%d,A_b0=%d,A_b1=%d,A_b2=%d,"
				.. "A_b3=%d,B_n=%d,B_b0=%d,B_b1=%d,B_b2=%d,B_b3=%d,ms=%d", tag, gw, gh, #samples,
				blocked[1], blocked[2], blocked[3], blocked[4], shapeA, shapeB,
				st[1][1], st[1][2], st[1][3], st[1][4], st[1][5],
				st[2][1], st[2][2], st[2][3], st[2][4], st[2][5], GetPreciseTicks() - t0))

			for i = 1, #samples do
				local s = samples[i]
				emit(table.concat({ tag, tostring(s.sgx), tostring(s.sgy), tostring(s.x),
					tostring(s.y), tostring(s.h), tostring(s.p0), tostring(s.p1), tostring(s.p2),
					tostring(s.p3), tostring(s.d), tostring(s.wbox), tostring(s.forced1),
					tostring(s.forced3) }, ","))
			end
			return { samples = #samples, blocked0 = blocked[1], blocked3 = blocked[4],
				shapeA = shapeA, shapeB = shapeB,
				A = { n = st[1][1], b0 = st[1][2], b1 = st[1][3], b2 = st[1][4], b3 = st[1][5] },
				B = { n = st[2][1], b0 = st[2][2], b1 = st[2][3], b2 = st[2][4], b3 = st[2][5] },
				hash_moved = (h0 ~= h3) }
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
			return string.format("n=%d A(%s) %d/%d blocked %d->%d->%d->%d B(%s) %d blocked "
				.. "%d->%d->%d->%d hash_moved=%s", r.samples, r.shapeA, r.A.n, r.A.n,
				r.A.b0, r.A.b1, r.A.b2, r.A.b3, r.shapeB, r.B.n,
				r.B.b0, r.B.b1, r.B.b2, r.B.b3, tostring(r.hash_moved))
		end
		g_ParityPassOwnInfo = "surface " .. brief(s) .. " | underground " .. brief(u)
		g_ParityPassOwnStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityPassOwnError = tostring(err)
		g_ParityPassOwnStatus = "error"
	end
end)
return "passown_probe_started"

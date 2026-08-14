-- Passability-WRITER probe (item C1b: who owns the pit-region mask's bits).
--
-- State of the investigation: on the underground control at 45S82E, vanilla blocks ~45% of a flat
-- 40,401-cell window around the `BottomlessPit` while the expanded twin blocks almost none, and
-- EVERY measured input matches - height flat and constant (022), terrain type identical on
-- 40,401/40,401 (023), no object within +-300 src wu (023), `IsForcedImpassable` false and
-- `GetPassType` 0 on both twins (024).  Two rebuild paths were measured INERT on both twins:
-- `terrain.RebuildPassability(map)` (022) and `map:RebuildGrids(box)` (023).
--
-- The hypothesis those two "inert" results never tested: the engine's own generator does NOT call
-- a bare rebuild - `RandomMapGenerator.lua:2900` calls
--     terrain.InvalidateHeight(map, bx) ; terrain.InvalidateType(map, bx) ; terrain.RebuildPassability(map, bx)
-- i.e. the rebuild recomputes INVALIDATED regions.  With nothing invalidated a rebuild can be a
-- legitimate no-op, which would make 022/023 uninformative rather than decisive - and would also
-- mean the mod's own bare `terrain.RebuildPassability(map)` calls recompute nothing.
--
-- So this probe drives the engine's own sequence and watches the SAME window cell for cell:
--   s0  baseline
--   s1  InvalidateHeight + InvalidateType + RebuildPassability over the window box
--   s2  the same again (idempotence)
--   s3  CONTROL: force a small box impassable, invalidate + rebuild it.  If s1 changed nothing,
--       this proves the rebuild pathway is live at all, so the s1 null is a real measurement and
--       not a dead call.  It also shows whether a rebuild honours the forced grid.
--   s4  the big hammer: whole-map InvalidateHeight + InvalidateType + RebuildPassability
-- `terrain.HashPassability(map)` is recorded at every stage: a whole-map digest that moves even
-- when the sampled window does not.
--
-- Reading:
--   * vanilla mask survives s1/s2/s4  -> the bits are reproduced from an input still unfound
--     (the window's inputs all match the expanded twin, so that input is outside what was sampled);
--   * vanilla mask evaporates at s1 or s4 -> the bits are generation-time state that no rebuild can
--     reconstruct; the expanded map (terrain copy + rebuild) can never have them, which names the
--     mechanism and makes it a design question, not a Z-transform defect;
--   * control s3 must always bite; if it does not, the run proves nothing and says so.
--
-- This probe MUTATES passability (and forces a box impassable), so it runs LAST, alone, and must
-- never be combined with a reading probe whose output is to be scored.
--
-- Placeholders: __POS_SCALE__, __CENTRE_CLASS__, __RADIUS__, __STRIDE__, __CTRL_OFF__, __OUT_PATH__.

g_ParityPassWriterStatus = "running"
g_ParityPassWriterInfo = false
g_ParityPassWriterError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local scale = __POS_SCALE__             -- 1.0 on the vanilla twin, 8192/6144 on the expanded
		local centre_class = "__CENTRE_CLASS__" -- object class whose neighbourhood is scanned
		local radius_src = __RADIUS__           -- scan radius, SOURCE wu
		local stride_src = __STRIDE__           -- lattice step, SOURCE wu
		local ctrl_off_src = __CTRL_OFF__       -- control box offset from the centre, SOURCE wu
		local out = {}
		local function emit(s) out[#out + 1] = s end

		local const_tbl = rawget(_G, "const")
		local tile = (type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize)) or 100
		local terrain_api = rawget(_G, "terrain")

		emit("#meta,scale=" .. tostring(scale) .. ",centre_class=" .. centre_class
			.. ",radius_src=" .. tostring(radius_src) .. ",stride_src=" .. tostring(stride_src)
			.. ",ctrl_off_src=" .. tostring(ctrl_off_src) .. ",tile=" .. tostring(tile))
		emit("map,sgx,sgy,x,y,h,p0,p1,p2,p3,p4,d_src,ctrl,forced0,forced3")

		local function has(fname)
			return type(terrain_api) == "table" and type(terrain_api[fname]) == "function"
		end
		for _, fname in ipairs({ "InvalidateHeight", "InvalidateType", "RebuildPassability",
			"SetForcedImpassableBox", "IsForcedImpassable", "HashPassability", "SetPassability",
			"ClearPassabilityBox" }) do
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

			-- Lattice over SOURCE cells (nearest cell, never floor: t6x measured the one-cell offset).
			local stride_cells = math.max(1, math.floor(stride_src / tile + 0.5))
			local radius_cells = math.floor(radius_src / tile + 0.5)
			local c_sgx = math.floor(cx / (scale * tile) + 0.5)
			local c_sgy = math.floor(cy / (scale * tile) + 0.5)
			emit(string.format("#centre,%s,x=%d,y=%d,sgx=%d,sgy=%d,objects=%d,grid=%dx%d",
				tag, cx, cy, c_sgx, c_sgy, #objs, gw, gh))

			-- The window box, in this map's own world units, plus the small control box.
			local half = radius_cells * tile * scale
			local win = box(point(math.floor(cx - half), math.floor(cy - half)),
				point(math.floor(cx + half), math.floor(cy + half)))
			local co = ctrl_off_src * scale
			local chalf = 600 * scale                     -- 6 source cells to a side
			local ctrl_cx, ctrl_cy = cx + co, cy + co
			local ctrl = box(point(math.floor(ctrl_cx - chalf), math.floor(ctrl_cy - chalf)),
				point(math.floor(ctrl_cx + chalf), math.floor(ctrl_cy + chalf)))
			local pad = 400 * scale
			local ctrl_grown = box(
				point(math.floor(ctrl_cx - chalf - pad), math.floor(ctrl_cy - chalf - pad)),
				point(math.floor(ctrl_cx + chalf + pad), math.floor(ctrl_cy + chalf + pad)))
			emit(string.format("#boxes,%s,win=%d;%d;%d;%d,ctrl=%d;%d;%d;%d", tag,
				win:minx(), win:miny(), win:maxx(), win:maxy(),
				ctrl:minx(), ctrl:miny(), ctrl:maxx(), ctrl:maxy()))

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
							local in_ctrl = (x >= ctrl:minx() and x <= ctrl:maxx()
								and y >= ctrl:miny() and y <= ctrl:maxy()) and 1 or 0
							samples[#samples + 1] = { sgx = sgx, sgy = sgy, x = x, y = y, pt = pt,
								d = math.floor(math.sqrt(ddx * ddx + ddy * ddy) / scale + 0.5),
								ctrl = in_ctrl, forced0 = -1, forced3 = -1 }
						end
					end
					dx = dx + stride_cells
				end
				dy = dy + stride_cells
			end

			if type(PauseInfiniteLoopDetection) == "function" then
				PauseInfiniteLoopDetection("parity_passwriter")
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
			-- The engine's own generator sequence: invalidate, then rebuild that box.
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
			for i = 1, #samples do
				if samples[i].ctrl == 1 then samples[i].forced0 = forced(samples[i].pt) end
			end

			invalidate_rebuild(win, "s1_window")
			stage("1")
			local h1 = hash()
			invalidate_rebuild(win, "s2_window_again")
			stage("2")
			local h2 = hash()

			-- s3 CONTROL: force the small box impassable, then invalidate + rebuild it.
			local ctrl_shape = "none"
			if has("SetForcedImpassableBox") then
				local ok_c, e = pcall(terrain_api.SetForcedImpassableBox, map, ctrl)
				if ok_c then
					ctrl_shape = "map_box"
				else
					local ok_c2, e2 = pcall(terrain_api.SetForcedImpassableBox, map, ctrl, true)
					ctrl_shape = ok_c2 and "map_box_true" or ("failed:"
						.. string.gsub(tostring(e), "[,\r\n]", " ") .. "|"
						.. string.gsub(tostring(e2), "[,\r\n]", " "))
				end
			end
			emit("#ctrl," .. tag .. ",SetForcedImpassableBox=" .. ctrl_shape)
			invalidate_rebuild(ctrl_grown, "s3_control")
			stage("3")
			local h3 = hash()
			for i = 1, #samples do
				if samples[i].ctrl == 1 then samples[i].forced3 = forced(samples[i].pt) end
			end

			-- s4 the big hammer: whole map.
			local full = box(point(0, 0), point(gw * tile, gh * tile))
			invalidate_rebuild(full, "s4_fullmap")
			stage("4")
			local h4 = hash()

			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_passwriter")
			end

			local blocked = { 0, 0, 0, 0, 0 }
			local ctrl_n, ctrl_blocked3, ctrl_forced3 = 0, 0, 0
			local changed_1, changed_4 = 0, 0
			for i = 1, #samples do
				local s = samples[i]
				for k = 0, 4 do
					if s["p" .. k] == 0 then blocked[k + 1] = blocked[k + 1] + 1 end
				end
				if s.p0 ~= s.p1 then changed_1 = changed_1 + 1 end
				if s.p0 ~= s.p4 then changed_4 = changed_4 + 1 end
				if s.ctrl == 1 then
					ctrl_n = ctrl_n + 1
					if s.p3 == 0 then ctrl_blocked3 = ctrl_blocked3 + 1 end
					if s.forced3 == 1 then ctrl_forced3 = ctrl_forced3 + 1 end
				end
			end

			emit(string.format("#hash,%s,h0=%s,h1=%s,h2=%s,h3=%s,h4=%s", tag, h0, h1, h2, h3, h4))
			emit(string.format("#summary,%s,grid=%dx%d,samples=%d,blocked0=%d,blocked1=%d,"
				.. "blocked2=%d,blocked3=%d,blocked4=%d,changed_s1=%d,changed_s4=%d,ctrl_n=%d,"
				.. "ctrl_blocked3=%d,ctrl_forced3=%d,ms=%d", tag, gw, gh, #samples,
				blocked[1], blocked[2], blocked[3], blocked[4], blocked[5],
				changed_1, changed_4, ctrl_n, ctrl_blocked3, ctrl_forced3, GetPreciseTicks() - t0))

			for i = 1, #samples do
				local s = samples[i]
				emit(table.concat({ tag, tostring(s.sgx), tostring(s.sgy), tostring(s.x),
					tostring(s.y), tostring(s.h), tostring(s.p0), tostring(s.p1), tostring(s.p2),
					tostring(s.p3), tostring(s.p4), tostring(s.d), tostring(s.ctrl),
					tostring(s.forced0), tostring(s.forced3) }, ","))
			end
			return { samples = #samples, blocked0 = blocked[1], blocked1 = blocked[2],
				blocked4 = blocked[5], changed_s1 = changed_1, changed_s4 = changed_4,
				ctrl_n = ctrl_n, ctrl_blocked3 = ctrl_blocked3, ctrl_forced3 = ctrl_forced3,
				hash_moved = (h0 ~= h4) }
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
			return string.format("n=%d blocked %d->%d->%d changed s1=%d s4=%d ctrl %d/%d blocked "
				.. "%d forced hash_moved=%s", r.samples, r.blocked0, r.blocked1, r.blocked4,
				r.changed_s1, r.changed_s4, r.ctrl_blocked3, r.ctrl_n, r.ctrl_forced3,
				tostring(r.hash_moved))
		end
		g_ParityPassWriterInfo = "surface " .. brief(s) .. " | underground " .. brief(u)
		g_ParityPassWriterStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityPassWriterError = tostring(err)
		g_ParityPassWriterStatus = "error"
	end
end)
return "passwriter_probe_started"

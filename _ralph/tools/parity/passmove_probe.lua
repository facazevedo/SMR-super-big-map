-- Passability POSE-ABLATION probe (item C1f: does the expanded map's `BottomlessPit` clone imprint
-- its footprint ANYWHERE, or only fail to imprint at its own pose?).
--
-- State of the investigation (45S82E underground): 028 proved the wonder object IS the applier of
-- the pit-region mask on vanilla (window blocked 21,719 -> 864 when it is deleted, every restore
-- exact) while the expanded clone changes NOTHING at any ablation stage; 029's read-only census
-- proved the failure is NOT map-wide (7,696 of 7,874 surface and 516 of 516 underground objects
-- imprint on the expanded map with vanilla's inside-vs-ring margin) and that `grids_applied` is the
-- hex object grid, not the pass grid.  The one ablation never performed is a real change of POSE:
-- 028's z flip was numerically a no-op on the expanded twin (explicit z = 1000 = terrain height)
-- and it never moved the object in XY.
--
-- Two windows are sampled on the SAME map at every stage, both 201x201 source cells:
--     ORIGIN       centred on the object's own pose (the same window as 023/024/026/027b/028, so
--                  its per-cell columns join every earlier measurement)
--     DESTINATION  centred `__DEST_OFFSET__` SOURCE wu away in x (sign chosen so the window fits
--                  the grid), i.e. fresh ground far outside the mask's measured 44,400 x 24,000 body
-- and the ladder is
--     s0  baseline (no action)
--     s1  whole-map InvalidateHeight+InvalidateType+RebuildPassability, object untouched  (CONTROL:
--         must reproduce s0 in both windows, else the run is void)
--     s2  `SetPos` the object to the DESTINATION (keeping that twin's own z mode), rebuild
--     s3  `SetPos` back to the baseline pose, rebuild                                     (CONTROL:
--         must return both windows to s1, else s2's reading is void)
-- with a whole-map `HashPassability` after every stage.
--
-- Reading:
--   * vanilla: the mask must LEAVE the origin window at s2 and APPEAR at the destination - that is
--     the positive control that this ladder can see a moving imprint at all;
--   * expanded: an imprint appearing at the destination means the clone rasterises fine and the
--     failure is tied to its pose or to local state at the pit -> fix in the mod's wonder placement;
--   * expanded: no imprint at either pose, while 7,874 identically-flagged objects imprint, means
--     the instance itself is inert -> repair route is 027b's load-time `OnMsg.OnPassabilityRebuilding`
--     + `terrain.ClearPassabilityBox`.
--
-- MUTATES passability AND the pose of a map object (restored at s3): runs LAST and ALONE, and its
-- map must never be scored for anything else afterwards.
--
-- Placeholders: __POS_SCALE__, __CENTRE_CLASS__, __RADIUS__, __STRIDE__, __DEST_OFFSET__,
-- __OUT_PATH__.

g_ParityPassMoveStatus = "running"
g_ParityPassMoveInfo = false
g_ParityPassMoveError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local scale = __POS_SCALE__             -- 1.0 on the vanilla twin, 8192/6144 on the expanded
		local centre_class = "__CENTRE_CLASS__" -- object class whose pose is ablated
		local radius_src = __RADIUS__           -- window radius, SOURCE wu
		local stride_src = __STRIDE__           -- lattice step, SOURCE wu
		local dest_off_src = __DEST_OFFSET__    -- destination offset in x, SOURCE wu
		local out = {}
		local function emit(s) out[#out + 1] = s end

		local const_tbl = rawget(_G, "const")
		local tile = (type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize)) or 100
		local terrain_api = rawget(_G, "terrain")
		local ef_grids = (type(const_tbl) == "table" and const_tbl.efApplyToGrids) or nil

		emit("#meta,scale=" .. tostring(scale) .. ",centre_class=" .. centre_class
			.. ",radius_src=" .. tostring(radius_src) .. ",stride_src=" .. tostring(stride_src)
			.. ",dest_off_src=" .. tostring(dest_off_src) .. ",tile=" .. tostring(tile))
		emit("map,window,sgx,sgy,x,y,h,p0,p1,p2,p3,d_src,inplay")

		local function has(fname)
			return type(terrain_api) == "table" and type(terrain_api[fname]) == "function"
		end
		for _, fname in ipairs({ "InvalidateHeight", "InvalidateType", "RebuildPassability",
			"HashPassability" }) do
			emit("#api," .. fname .. "," .. tostring(has(fname)))
		end

		local function obj_report(map, tag, obj, when)
			local rep = { "#obj", tag, when, tostring(obj.class) }
			local okp, px, py, pz = pcall(obj.GetVisualPosXYZ, obj)
			rep[#rep + 1] = "x=" .. tostring(okp and px)
			rep[#rep + 1] = "y=" .. tostring(okp and py)
			rep[#rep + 1] = "vz=" .. tostring(okp and pz)
			local okg, gp = pcall(obj.GetPos, obj)
			local valid_z = "?"
			if okg and gp then
				local okv, v = pcall(gp.IsValidZ, gp)
				valid_z = okv and tostring(v) or "?"
				rep[#rep + 1] = "pos_z=" .. tostring(gp:z())
			end
			rep[#rep + 1] = "valid_z=" .. valid_z
			local oks, sc = pcall(obj.GetScale, obj)
			rep[#rep + 1] = "scale=" .. tostring(oks and sc)
			local okv2, v2 = pcall(IsValid, obj)
			rep[#rep + 1] = "valid=" .. tostring(okv2 and v2)
			if ef_grids and type(obj.GetEnumFlags) == "function" then
				local okf, f = pcall(obj.GetEnumFlags, obj, ef_grids)
				rep[#rep + 1] = "ef_grids=" .. tostring(okf and (f ~= 0))
			end
			if type(obj.GetObjectBBox) == "function" then
				local okob, ob = pcall(obj.GetObjectBBox, obj)
				if okob and ob then
					rep[#rep + 1] = "obb=" .. tostring(ob:sizex()) .. "x" .. tostring(ob:sizey())
					rep[#rep + 1] = "obbmin=" .. tostring(ob:minx()) .. "|" .. tostring(ob:miny())
				end
			end
			rep[#rep + 1] = "terrain_h=" .. tostring(okp and map:GetHeight(point(px, py)))
			emit(table.concat(rep, ","))
		end

		local function probe_map(map, tag)
			if not map then return nil end
			local gw, gh = terrain.HeightMapSize(map)
			local src_gw = math.floor(gw / scale + 0.5)
			local objs = map:MapGet("map") or {}
			local pit, cx, cy = nil, nil, nil
			for i = 1, #objs do
				local obj = objs[i]
				if obj and IsValid(obj) and obj.class == centre_class and not pit then
					local ok_pos, px, py = pcall(obj.GetVisualPosXYZ, obj)
					if ok_pos then pit, cx, cy = obj, px, py end
				end
			end
			if not pit then
				emit("#skip," .. tag .. ",no_object_of_class=" .. centre_class
					.. ",objects=" .. tostring(#objs))
				return { skipped = true, objects = #objs }
			end

			local stride_cells = math.max(1, math.floor(stride_src / tile + 0.5))
			local radius_cells = math.floor(radius_src / tile + 0.5)
			local c_sgx = math.floor(cx / (scale * tile) + 0.5)
			local c_sgy = math.floor(cy / (scale * tile) + 0.5)

			-- Destination centre, in SOURCE cells: the same offset on both twins so the two maps
			-- see the same ground.  Flip the sign when the window would leave the grid.
			local off_cells = math.floor(dest_off_src / tile + 0.5)
			local d_sgx = c_sgx + off_cells
			if d_sgx + radius_cells >= src_gw - 1 then d_sgx = c_sgx - off_cells end
			local d_sgy = c_sgy
			if d_sgx - radius_cells < 1 then
				emit("#skip," .. tag .. ",destination_does_not_fit,src_gw=" .. tostring(src_gw))
				return { skipped = true, objects = #objs }
			end
			local dest_x = math.floor((d_sgx * tile + tile / 2) * scale + 0.5)
			local dest_y = math.floor((d_sgy * tile + tile / 2) * scale + 0.5)

			emit(string.format("#centre,%s,x=%d,y=%d,sgx=%d,sgy=%d,objects=%d,grid=%dx%d,src_gw=%d",
				tag, cx, cy, c_sgx, c_sgy, #objs, gw, gh, src_gw))
			emit(string.format("#dest,%s,x=%d,y=%d,sgx=%d,sgy=%d,off_cells=%d",
				tag, dest_x, dest_y, d_sgx, d_sgy, d_sgx - c_sgx))

			local samples = {}
			local function build_window(wname, w_sgx, w_sgy)
				local n0 = #samples
				local dy = -radius_cells
				while dy <= radius_cells do
					local dx = -radius_cells
					while dx <= radius_cells do
						local sgx, sgy = w_sgx + dx, w_sgy + dy
						if sgx >= 0 and sgy >= 0 then
							local x = math.floor((sgx * tile + tile / 2) * scale + 0.5)
							local y = math.floor((sgy * tile + tile / 2) * scale + 0.5)
							local pt = point(x, y)
							if map:IsPointInBounds(pt) then
								local wx = (wname == "origin") and cx or dest_x
								local wy = (wname == "origin") and cy or dest_y
								local ddx, ddy = x - wx, y - wy
								local inplay = -1
								if type(map.IsInsidePlayArea) == "function" then
									local ok_ip, v = pcall(map.IsInsidePlayArea, map, x, y)
									if ok_ip then inplay = v and 1 or 0 end
								end
								samples[#samples + 1] = { w = wname, sgx = sgx, sgy = sgy,
									x = x, y = y, pt = pt, inplay = inplay,
									d = math.floor(math.sqrt(ddx * ddx + ddy * ddy) / scale + 0.5) }
							end
						end
						dx = dx + stride_cells
					end
					dy = dy + stride_cells
				end
				return #samples - n0
			end
			local n_origin = build_window("origin", c_sgx, c_sgy)
			local n_dest = build_window("dest", d_sgx, d_sgy)

			if type(PauseInfiniteLoopDetection) == "function" then
				PauseInfiniteLoopDetection("parity_passmove")
			end

			local function sample(key)
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
			local full = box(point(0, 0), point(gw * tile, gh * tile))
			local function rebuild(label)
				local t0 = GetPreciseTicks()
				local rep = {}
				for _, fname in ipairs({ "InvalidateHeight", "InvalidateType" }) do
					if has(fname) then
						local ok_i, e = pcall(terrain_api[fname], map, full)
						rep[#rep + 1] = fname .. "=" .. tostring(ok_i)
							.. (ok_i and "" or (":" .. string.gsub(tostring(e), "[,\r\n]", " ")))
					else
						rep[#rep + 1] = fname .. "=missing"
					end
				end
				local ok_r, e = pcall(terrain_api.RebuildPassability, map, full)
				rep[#rep + 1] = "RebuildPassability=" .. tostring(ok_r)
					.. (ok_r and "" or (":" .. string.gsub(tostring(e), "[,\r\n]", " ")))
				emit(string.format("#step,%s,%s,ms=%d,%s", tag, label,
					GetPreciseTicks() - t0, table.concat(rep, ";")))
			end

			local t0 = GetPreciseTicks()
			for i = 1, #samples do samples[i].h = map:GetHeight(samples[i].pt) end
			sample("0")
			local hashes = { hash() }
			obj_report(map, tag, pit, "s0")

			local base_pos = select(2, pcall(pit.GetPos, pit))
			local base_valid_z = false
			if base_pos then
				local okv, v = pcall(base_pos.IsValidZ, base_pos)
				base_valid_z = okv and v or false
			end

			local function act(label, fn)
				local ok_a, e = pcall(fn)
				emit(string.format("#act,%s,%s,ok=%s%s", tag, label, tostring(ok_a),
					ok_a and "" or (",err=" .. string.gsub(tostring(e), "[,\r\n]", " "))))
				return ok_a
			end
			local function stage(key, label, fn)
				if fn then act(label, fn) end
				rebuild("rebuild_" .. label)
				sample(key)
				hashes[#hashes + 1] = hash()
				if IsValid(pit) then obj_report(map, tag, pit, label) end
			end

			-- s1: rebuild only.  The object is untouched, so both windows must reproduce s0.
			stage("1", "rebuild_only", nil)

			-- s2: MOVE.  Keep this twin's own z mode (028 measured the z flip to change 0 cells,
			-- so the pose change must not smuggle a mode change in with it).
			stage("2", "move_to_dest", function()
				if base_valid_z then
					pit:SetPos(point(dest_x, dest_y, map:GetHeight(point(dest_x, dest_y))))
				else
					pit:SetPos(point(dest_x, dest_y))
				end
			end)

			-- s3: restore the baseline pose.  Control: both windows must return to s1.
			stage("3", "move_restore", function() pit:SetPos(base_pos) end)

			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_passmove")
			end

			-- Per-window, per-stage statistics.
			local stats = {}
			for _, wname in ipairs({ "origin", "dest" }) do
				stats[wname] = { n = 0, blocked = {}, changed = {} }
				for k = 0, 3 do stats[wname].blocked[k] = 0; stats[wname].changed[k] = 0 end
			end
			for i = 1, #samples do
				local s = samples[i]
				local st = stats[s.w]
				st.n = st.n + 1
				for k = 0, 3 do
					if s["p" .. k] == 0 then st.blocked[k] = st.blocked[k] + 1 end
					if s["p" .. k] ~= s.p0 then st.changed[k] = st.changed[k] + 1 end
				end
			end

			local hparts = {}
			for i = 1, #hashes do hparts[#hparts + 1] = "h" .. (i - 1) .. "=" .. hashes[i] end
			emit(string.format("#hash,%s,%s", tag, table.concat(hparts, ",")))
			for _, wname in ipairs({ "origin", "dest" }) do
				local st = stats[wname]
				local bparts, cparts = {}, {}
				for k = 0, 3 do
					bparts[#bparts + 1] = "blocked" .. k .. "=" .. st.blocked[k]
					cparts[#cparts + 1] = "changed" .. k .. "=" .. st.changed[k]
				end
				emit(string.format("#summary,%s,%s,samples=%d,%s,%s", tag, wname, st.n,
					table.concat(bparts, ","), table.concat(cparts, ",")))
			end
			emit(string.format("#done,%s,n_origin=%d,n_dest=%d,base_valid_z=%s,ms=%d",
				tag, n_origin, n_dest, tostring(base_valid_z), GetPreciseTicks() - t0))

			for i = 1, #samples do
				local s = samples[i]
				local row = { tag, s.w, tostring(s.sgx), tostring(s.sgy), tostring(s.x),
					tostring(s.y), tostring(s.h) }
				for k = 0, 3 do row[#row + 1] = tostring(s["p" .. k]) end
				row[#row + 1] = tostring(s.d)
				row[#row + 1] = tostring(s.inplay)
				emit(table.concat(row, ","))
			end
			return { samples = #samples, stats = stats, base_valid_z = base_valid_z }
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
			local parts = {}
			for _, wname in ipairs({ "origin", "dest" }) do
				local st = r.stats[wname]
				local b = {}
				for k = 0, 3 do b[#b + 1] = tostring(st.blocked[k]) end
				parts[#parts + 1] = wname .. " " .. table.concat(b, "->")
			end
			return table.concat(parts, " | ")
		end
		g_ParityPassMoveInfo = "surface " .. brief(s) .. " || underground " .. brief(u)
		g_ParityPassMoveStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityPassMoveError = tostring(err)
		g_ParityPassMoveStatus = "error"
	end
end)
return "passmove_probe_started"

-- Passability-INPUT probe: which engine input carries the non-terrain impassability that vanilla
-- applies around the underground Bottomless Pit and the expanded map does not?
--
-- Iteration 021 isolated the residual, 022 settled what it is NOT: the ground there is provably
-- flat on both twins (max quad-edge slope 0 wu, threshold 27), a full-map
-- `terrain.RebuildPassability` is a no-op on BOTH twins (wiped 0, gained 0, twice), the wonder's
-- entity bbox is identical on both maps, `ForcedImpassableMarkers` is nil on both, and there is no
-- displaced imprint at the pre-stretch pose.  So the applier is an INPUT the two maps do not share.
--
-- The engine keeps several per-map grids besides height and terrain type (`MapGrids.lua`:
-- `MapGridDefs`, e.g. `CaveGrid` at `const.CaveTileSize`, `BiomeGrid`, ...), created at NewMap time
-- from `map.mapdata.Width/Height`.  The mod's terrain stretch resamples height, type, clutter,
-- colorize and BiomeGrid (`sbm_terrain_copy.lua:1502`) - nothing else.  A grid that was never
-- resized or resampled is therefore the leading candidate for a mask that vanilla has and the
-- expanded map lacks.
--
-- The probe measures, on BOTH twins, over the SAME source cells:
--   (1) an inventory of every `MapGridDefs` grid on the map: present, size, bits, tile size, and
--       the size the engine's own `MapGridSize` expects for this map's mapdata - a grid whose
--       actual size is the SOURCE size on an expanded map is the defect, visible without any
--       further inference;
--   (2) per lattice sample: passability, height, terrain type, and the value of every present map
--       grid at that world position (`MapGridGetAt`), so the mask can be cross-tabbed against the
--       verdict cell by cell;
--   (3) per forensic cell (a fixed list chosen offline from the iter-022 twin lattices: cells
--       vanilla blocks and the expanded map does not, plus both-passable and both-blocked
--       controls): every object in a small box around it with class, entity, position, enum flags
--       and entity bbox - i.e. what covers the cell on each map;
--   (4) a per-box `map:RebuildGrids(box)` over the scanned neighbourhood, followed by a re-sample
--       of the whole lattice.  `terrain.RebuildPassability` was proven inert in 022; this is the
--       other rebuild path (the one markers and water use).  If it re-creates the mask on the
--       expanded map the fix is a post-stretch re-apply; if it changes nothing on either twin the
--       mask is written once, from data the stretch drops.
--   (5) the names actually exported by the `terrain` table that mention pass/hole/type/grid, so
--       future probes build on the measured API instead of doc guesses.
--
-- Step (4) MUTATES passability, so this probe must run last, after every reading probe.
--
-- Placeholders: __POS_SCALE__, __CENTRE_CLASS__, __RADIUS__, __STRIDE__, __CELLS__, __OUT_PATH__.

g_ParityPassMaskStatus = "running"
g_ParityPassMaskInfo = false
g_ParityPassMaskError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local scale = __POS_SCALE__             -- 1.0 on the vanilla twin, 8192/6144 on the expanded
		local centre_class = "__CENTRE_CLASS__" -- object class whose neighbourhood is scanned
		local radius_src = __RADIUS__           -- scan radius, SOURCE wu
		local stride_src = __STRIDE__           -- lattice step, SOURCE wu
		local cells = __CELLS__                 -- { {sgx, sgy, kind}, ... } forensic source cells
		local out = {}
		local function emit(s) out[#out + 1] = s end

		local const_tbl = rawget(_G, "const")
		local tile = (type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize)) or 100
		local ef_grids = (type(const_tbl) == "table" and const_tbl.efApplyToGrids) or nil
		local ef_collision = (type(const_tbl) == "table" and const_tbl.efCollision) or nil
		local grid_defs = rawget(_G, "MapGridDefs")
		local grid_get_at = rawget(_G, "MapGridGetAt")
		local grid_size_fn = rawget(_G, "MapGridSize")
		local terrain_api = rawget(_G, "terrain")
		local box_fn = rawget(_G, "box")
		local point_fn = rawget(_G, "point")

		emit("#meta,scale=" .. tostring(scale) .. ",centre_class=" .. centre_class
			.. ",radius_src=" .. tostring(radius_src) .. ",stride_src=" .. tostring(stride_src)
			.. ",tile=" .. tostring(tile)
			.. ",has_gridgetat=" .. tostring(type(grid_get_at) == "function")
			.. ",has_griddefs=" .. tostring(type(grid_defs) == "table"))

		-- (5) measured API surface of `terrain`, once (the same on both maps).
		if type(terrain_api) == "table" then
			local names = {}
			for k, v in pairs(terrain_api) do
				if type(k) == "string" and type(v) == "function" then
					local low = string.lower(k)
					if string.find(low, "pass", 1, true) or string.find(low, "hole", 1, true)
						or string.find(low, "grid", 1, true) or string.find(low, "type", 1, true) then
						names[#names + 1] = k
					end
				end
			end
			table.sort(names)
			for i = 1, #names do emit("#api,terrain," .. names[i]) end
		end

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
			local md = map.mapdata
			emit(string.format("#mapdata,%s,width=%s,height=%s,env=%s,grid=%dx%d", tag,
				tostring(md and md.Width), tostring(md and md.Height),
				tostring(md and md.Environment), gw, gh))

			-- (1) map-grid inventory: what exists, at what size, versus what this mapdata expects.
			local grid_names = {}
			if type(grid_defs) == "table" then
				for name in pairs(grid_defs) do grid_names[#grid_names + 1] = name end
				table.sort(grid_names)
			end
			local present = {}
			for i = 1, #grid_names do
				local name = grid_names[i]
				local def = grid_defs[name]
				local grid = rawget(map, name)
				if grid == nil then
					local ok_g, g = pcall(function() return map[name] end)
					if ok_g then grid = g end
				end
				local w, h, bits = "-", "-", "-"
				local is_grid = false
				if grid and type(rawget(_G, "IsGrid")) == "function" then
					is_grid = IsGrid(grid) and true or false
				elseif grid then
					is_grid = type(grid) == "userdata"
				end
				if is_grid then
					local ok_s, sw, sh = pcall(grid.size, grid)
					if ok_s then w, h = tostring(sw), tostring(sh) end
					local ok_b, b = pcall(grid.bits, grid)
					if ok_b then bits = tostring(b) end
					present[#present + 1] = name
				end
				local ew, eh = "-", "-"
				if type(grid_size_fn) == "function" and def and md then
					local ok_e, a, b = pcall(grid_size_fn, def, md)
					if ok_e then ew, eh = tostring(a), tostring(b) end
				end
				emit(string.format("#grid,%s,%s,present=%s,w=%s,h=%s,bits=%s,tile=%s,exp_w=%s,exp_h=%s,save=%s",
					tag, name, tostring(is_grid), w, h, bits,
					tostring(def and def.tile_size), ew, eh, tostring(def and def.save_in_map)))
			end

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

			local c_sgx = math.floor(cx / (scale * tile) + 0.5)
			local c_sgy = math.floor(cy / (scale * tile) + 0.5)
			emit(string.format("#centre,%s,x=%d,y=%d,sgx=%d,sgy=%d,objects=%d,grids=%s",
				tag, cx, cy, c_sgx, c_sgy, #objs, table.concat(present, "|")))

			-- Column header for this map's samples: the grid columns are whatever it actually has.
			emit("#cols," .. tag .. ",map,sgx,sgy,x,y,h,p,p2,tt,d_src," .. table.concat(present, ","))

			local function grid_value(name, pt)
				if type(grid_get_at) == "function" then
					local ok_v, v = pcall(grid_get_at, map, name, pt)
					if ok_v and type(v) == "number" then return v end
				end
				return -1
			end
			local function terrain_type(pt)
				if type(terrain_api) == "table" and type(terrain_api.GetTerrainType) == "function" then
					local ok_t, t = pcall(terrain_api.GetTerrainType, map, pt)
					if ok_t and type(t) == "number" then return t end
				end
				return -1
			end

			if type(PauseInfiniteLoopDetection) == "function" then
				PauseInfiniteLoopDetection("parity_passmask")
			end

			-- (2) lattice over SOURCE cells, so both twins walk the same ground.
			local stride_cells = math.max(1, math.floor(stride_src / tile + 0.5))
			local radius_cells = math.floor(radius_src / tile + 0.5)
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
							samples[#samples + 1] = { sgx = sgx, sgy = sgy, x = x, y = y, pt = pt,
								d = math.floor(math.sqrt(ddx * ddx + ddy * ddy) / scale + 0.5) }
						end
					end
					dx = dx + stride_cells
				end
				dy = dy + stride_cells
			end

			local t0 = GetPreciseTicks()
			for i = 1, #samples do
				local s = samples[i]
				s.h = map:GetHeight(s.pt)
				s.p = map:IsPassable(s.pt) and 1 or 0
				s.tt = terrain_type(s.pt)
				s.g = {}
				for k = 1, #present do
					s.g[k] = grid_value(present[k], s.pt)
				end
			end
			local sample_ms = GetPreciseTicks() - t0

			-- (3) forensic cells: what covers the cell on THIS map.
			local reach = math.floor(300 * scale + 0.5)
			for i = 1, #cells do
				local sgx, sgy, kind = cells[i][1], cells[i][2], cells[i][3]
				local x = math.floor((sgx * tile + tile / 2) * scale + 0.5)
				local y = math.floor((sgy * tile + tile / 2) * scale + 0.5)
				local pt = point(x, y)
				if map:IsPointInBounds(pt) then
					local gv = {}
					for k = 1, #present do gv[k] = tostring(grid_value(present[k], pt)) end
					emit(string.format("#cell,%s,%d,%d,%s,x=%d,y=%d,h=%d,p=%d,tt=%d,%s", tag, sgx, sgy,
						kind, x, y, map:GetHeight(pt), map:IsPassable(pt) and 1 or 0, terrain_type(pt),
						table.concat(gv, "|")))
					local found = 0
					if type(box_fn) == "function" then
						local bx = box_fn(x - reach, y - reach, x + reach, y + reach)
						local ok_l, list = pcall(map.MapGet, map, bx, "map")
						if ok_l and type(list) == "table" then
							for j = 1, #list do
								local obj = list[j]
								if obj and IsValid(obj) then
									found = found + 1
									local ox, oy, oz = 0, 0, 0
									local ok_p, px, py, pz = pcall(obj.GetVisualPosXYZ, obj)
									if ok_p then ox, oy, oz = px, py, pz or 0 end
									local fg, fc = "?", "?"
									if ef_grids and type(obj.GetEnumFlags) == "function" then
										local ok_f, f = pcall(obj.GetEnumFlags, obj, ef_grids)
										if ok_f then fg = tostring(f ~= 0) end
									end
									if ef_collision and type(obj.GetEnumFlags) == "function" then
										local ok_f, f = pcall(obj.GetEnumFlags, obj, ef_collision)
										if ok_f then fc = tostring(f ~= 0) end
									end
									local ent, bw, bh = "?", "?", "?"
									if type(obj.GetEntity) == "function" then
										local ok_e, e = pcall(obj.GetEntity, obj)
										if ok_e and e then
											ent = tostring(e)
											if type(rawget(_G, "GetEntityBoundingBox")) == "function" then
												local ok_bb, bb = pcall(GetEntityBoundingBox, e)
												if ok_bb and bb then
													local x0, y0, x1, y1 = box_bounds(bb)
													if x0 then bw, bh = tostring(x1 - x0), tostring(y1 - y0) end
												end
											end
										end
									end
									emit(string.format("#cellobj,%s,%d,%d,%s,%s,%s,%s,%s,%s,%s,%s", tag,
										sgx, sgy, tostring(obj.class), ent, tostring(ox), tostring(oy),
										tostring(oz), fg, fc, bw .. "x" .. bh))
								end
							end
						end
					end
					emit(string.format("#cellobjs,%s,%d,%d,n=%d,reach=%d", tag, sgx, sgy, found, reach))
				end
			end

			-- (4) per-box rebuild over the scanned neighbourhood, then re-sample.
			local rb_ms, rb_ok, rb_err = -1, "skipped", ""
			if type(box_fn) == "function" then
				local half = math.floor(radius_src * scale + 0.5)
				local mw, mh = map:GetMapSize()
				local x0 = math.max(0, cx - half)
				local y0 = math.max(0, cy - half)
				local x1 = math.min(mw - 1, cx + half)
				local y1 = math.min(mh - 1, cy + half)
				local bx = box_fn(x0, y0, x1, y1)
				local t1 = GetPreciseTicks()
				local ok_r, e = pcall(map.RebuildGrids, map, bx)
				rb_ms = GetPreciseTicks() - t1
				rb_ok, rb_err = tostring(ok_r), tostring(e)
				emit(string.format("#rebuildbox,%s,x0=%d,y0=%d,x1=%d,y1=%d,ok=%s,ms=%d,err=%s",
					tag, x0, y0, x1, y1, rb_ok, rb_ms, ok_r and "-" or rb_err))
			end
			for i = 1, #samples do
				local s = samples[i]
				s.p2 = map:IsPassable(s.pt) and 1 or 0
			end

			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_passmask")
			end

			local blocked, blocked2, changed = 0, 0, 0
			for i = 1, #samples do
				local s = samples[i]
				if s.p == 0 then blocked = blocked + 1 end
				if s.p2 == 0 then blocked2 = blocked2 + 1 end
				if s.p ~= s.p2 then changed = changed + 1 end
			end
			emit(string.format("#summary,%s,samples=%d,blocked=%d,blocked_after_rebuildbox=%d,"
				.. "changed=%d,sample_ms=%d,rebuild_ms=%d,ms=%d", tag, #samples, blocked, blocked2,
				changed, sample_ms, rb_ms, GetPreciseTicks() - t0))

			for i = 1, #samples do
				local s = samples[i]
				local row = { tag, tostring(s.sgx), tostring(s.sgy), tostring(s.x), tostring(s.y),
					tostring(s.h), tostring(s.p), tostring(s.p2), tostring(s.tt), tostring(s.d) }
				for k = 1, #present do row[#row + 1] = tostring(s.g[k]) end
				emit(table.concat(row, ","))
			end
			return { samples = #samples, blocked = blocked, blocked2 = blocked2, changed = changed,
				grids = table.concat(present, "|") }
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
			return string.format("n=%d blocked %d->%d changed=%d grids=%s",
				r.samples, r.blocked, r.blocked2, r.changed, r.grids)
		end
		g_ParityPassMaskInfo = "surface " .. brief(s) .. " | underground " .. brief(u)
		g_ParityPassMaskStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityPassMaskError = tostring(err)
		g_ParityPassMaskStatus = "error"
	end
end)
return "passmask_probe_started"

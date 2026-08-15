-- Object FOOTPRINT-IMPRINT census (item C1e, widened from "re-register the one clone").
--
-- 028 proved, with restore-controlled ablation on both twins, that the vanilla `BottomlessPit`
-- object applies 20,855 of the 20,869-cell pit residual and that the expanded clone applies
-- NOTHING anywhere on its map (whole-map `HashPassability` identical through delete).  Before
-- spending a mutating run on re-registering that ONE object, this probe asks the cheaper and
-- strictly more informative question, READ-ONLY:
--
--     does ANY object's efApplyToGrids footprint imprint impassability on the expanded map?
--
-- If no object does, the defect is map-wide - the expanded map's pass rebuild never rasterises
-- object surfaces - and that single mechanism would also explain the ~5:1 false->true bias the
-- user ruling demands be named (vanilla blocks the cell under an object, the expanded twin does
-- not; inherently one-way, independent of Z).  If SOME objects imprint and the wonder does not,
-- the defect is object-specific and 028's re-registration dance is the right next move.
--
-- Method, per map (surface and underground), per object that carries efApplyToGrids AND whose
-- entity actually has ApplyToGrids surfaces:
--   * INSIDE  - a KxK lattice over the object's own world bbox (`GetObjectBBox`, which already
--               includes scale and angle), sampled at RELATIVE positions so both twins sample the
--               same geometry even where the mod scaled the clone;
--   * RING    - the same lattice over that bbox grown __RING__x about its centre, keeping only
--               points OUTSIDE the bbox: the object's own local background rate, which controls
--               for terrain that would block those cells anyway.
-- An object that imprints has inside >> ring on its own map.  The twin join (offline) compares
-- the same object on both maps, so terrain is controlled twice over.
--
-- `IsInsidePlayArea` is recorded per object because outside vanilla's PassBorder band the ground
-- is impassable BY RULE (019) and the expanded map sets PassBorder = 0 - those objects must be
-- dropped from any comparison rather than counted as imprints.
--
-- READ-ONLY: no write, no rebuild, no object edit.  Safe to run beside the reading probes.
--
-- Placeholders: __POS_SCALE__, __GRID_K__, __RING__, __MAX_OBJECTS__, __OUT_PATH__.

g_ParityPassImpStatus = "running"
g_ParityPassImpInfo = false
g_ParityPassImpError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local scale = __POS_SCALE__        -- 1.0 on the vanilla twin, 8192/6144 on the expanded
		local kk = __GRID_K__              -- lattice side inside the bbox (kk*kk inside samples)
		local ring_mult = __RING__         -- bbox growth factor for the background ring
		local max_objects = __MAX_OBJECTS__ -- cap per map; a deterministic stride keeps the spread
		local out = {}
		local function emit(s) out[#out + 1] = s end

		local const_tbl = rawget(_G, "const")
		local tile = (type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize)) or 100
		local ef_grids = (type(const_tbl) == "table" and const_tbl.efApplyToGrids) or nil
		local ef_collision = (type(const_tbl) == "table" and const_tbl.efCollision) or nil
		local surf_tbl = rawget(_G, "EntitySurfaces")
		local has_surf_fn = rawget(_G, "HasAnySurfaces")

		emit("#meta,scale=" .. tostring(scale) .. ",k=" .. tostring(kk)
			.. ",ring=" .. tostring(ring_mult) .. ",max_objects=" .. tostring(max_objects)
			.. ",tile=" .. tostring(tile) .. ",ef_grids=" .. tostring(ef_grids))
		emit("map,idx,class,entity,sx,sy,x,y,scl,ang,bw,bh,inplay,grids_applied,ef_grids,"
			.. "ef_collision,surf_grids,surf_coll,in_n,in_blocked,ring_n,ring_blocked,h_centre,p_centre")

		-- Entity surface answers are constant per entity; cache them.
		local surf_cache = {}
		local function entity_surfaces(ent)
			if ent == nil or ent == "" then return "?", "?" end
			local c = surf_cache[ent]
			if c then return c[1], c[2] end
			local g, k = "?", "?"
			if type(surf_tbl) == "table" and type(has_surf_fn) == "function" then
				if surf_tbl.ApplyToGrids then
					local okh, h = pcall(has_surf_fn, ent, surf_tbl.ApplyToGrids)
					g = okh and tostring(h) or "?"
				end
				if surf_tbl.Collision then
					local okh, h = pcall(has_surf_fn, ent, surf_tbl.Collision)
					k = okh and tostring(h) or "?"
				end
			end
			surf_cache[ent] = { g, k }
			return g, k
		end

		local function probe_map(map, tag)
			if not map then return nil end
			local gw, gh = terrain.HeightMapSize(map)
			local objs = map:MapGet("map") or {}

			-- Candidate set: objects that carry the flag AND whose entity has grid surfaces.
			local cand = {}
			local n_flagged, n_valid = 0, 0
			for i = 1, #objs do
				local obj = objs[i]
				if obj and IsValid(obj) then
					n_valid = n_valid + 1
					local flagged = false
					if ef_grids and type(obj.GetEnumFlags) == "function" then
						local okf, f = pcall(obj.GetEnumFlags, obj, ef_grids)
						flagged = okf and (f ~= 0) or false
					end
					if flagged then
						n_flagged = n_flagged + 1
						local ent = ""
						local oke, e = pcall(obj.GetEntity, obj)
						if oke and e then ent = tostring(e) end
						local sg = entity_surfaces(ent)
						if sg == "true" then cand[#cand + 1] = obj end
					end
				end
			end

			local stride = 1
			if max_objects > 0 and #cand > max_objects then
				stride = math.ceil(#cand / max_objects)
			end

			if type(PauseInfiniteLoopDetection) == "function" then
				PauseInfiniteLoopDetection("parity_passimprint")
			end

			local t0 = GetPreciseTicks()
			local rows = {}
			local tot_in_n, tot_in_b, tot_ring_n, tot_ring_b, sampled, with_imprint = 0, 0, 0, 0, 0, 0
			local idx = 1
			while idx <= #cand do
				local obj = cand[idx]
				local ok_pos, px, py = pcall(obj.GetVisualPosXYZ, obj)
				local okob, ob = pcall(obj.GetObjectBBox, obj)
				if ok_pos and okob and ob and type(px) == "number" then
					local x0, y0 = ob:minx(), ob:miny()
					local x1, y1 = ob:maxx(), ob:maxy()
					local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
					local in_n, in_b, ring_n, ring_b = 0, 0, 0, 0
					-- INSIDE: relative lattice over the bbox.
					for iy = 0, kk - 1 do
						for ix = 0, kk - 1 do
							local u = (ix + 0.5) / kk
							local v = (iy + 0.5) / kk
							local sx = math.floor(x0 + u * (x1 - x0) + 0.5)
							local sy = math.floor(y0 + v * (y1 - y0) + 0.5)
							local pt = point(sx, sy)
							if map:IsPointInBounds(pt) then
								in_n = in_n + 1
								if not map:IsPassable(pt) then in_b = in_b + 1 end
							end
						end
					end
					-- RING: same lattice over the grown bbox, keeping only points outside the bbox.
					local hx, hy = (x1 - x0) / 2, (y1 - y0) / 2
					local gx0, gx1 = cx - hx * ring_mult, cx + hx * ring_mult
					local gy0, gy1 = cy - hy * ring_mult, cy + hy * ring_mult
					local rk = kk + 2
					for iy = 0, rk - 1 do
						for ix = 0, rk - 1 do
							local u = (ix + 0.5) / rk
							local v = (iy + 0.5) / rk
							local sx = math.floor(gx0 + u * (gx1 - gx0) + 0.5)
							local sy = math.floor(gy0 + v * (gy1 - gy0) + 0.5)
							if sx < x0 or sx > x1 or sy < y0 or sy > y1 then
								local pt = point(sx, sy)
								if map:IsPointInBounds(pt) then
									ring_n = ring_n + 1
									if not map:IsPassable(pt) then ring_b = ring_b + 1 end
								end
							end
						end
					end

					local inplay = "?"
					if type(map.IsInsidePlayArea) == "function" then
						local ok_ip, v = pcall(map.IsInsidePlayArea, map, px, py)
						if ok_ip then inplay = v and "1" or "0" end
					end
					local ent = ""
					local oke, e = pcall(obj.GetEntity, obj)
					if oke and e then ent = tostring(e) end
					local sg, sc = entity_surfaces(ent)
					local oks, scl = pcall(obj.GetScale, obj)
					local oka, ang = pcall(obj.GetAngle, obj)
					local coll = "?"
					if ef_collision and type(obj.GetEnumFlags) == "function" then
						local okf, f = pcall(obj.GetEnumFlags, obj, ef_collision)
						coll = okf and tostring(f ~= 0) or "?"
					end
					local ga = "nil"
					local okg, g = pcall(function() return obj.grids_applied end)
					if okg and g ~= nil then ga = tostring(g) end
					local cpt = point(math.floor(cx + 0.5), math.floor(cy + 0.5))
					local hc, pc = "nil", "nil"
					if map:IsPointInBounds(cpt) then
						hc = tostring(map:GetHeight(cpt))
						pc = map:IsPassable(cpt) and "1" or "0"
					end

					rows[#rows + 1] = table.concat({ tag, tostring(idx), tostring(obj.class), ent,
						tostring(math.floor(px / scale + 0.5)), tostring(math.floor(py / scale + 0.5)),
						tostring(px), tostring(py),
						tostring(oks and scl or "?"), tostring(oka and ang or "?"),
						tostring(math.floor((x1 - x0) / scale + 0.5)),
						tostring(math.floor((y1 - y0) / scale + 0.5)),
						inplay, ga, "true", coll, sg, sc,
						tostring(in_n), tostring(in_b), tostring(ring_n), tostring(ring_b),
						hc, pc }, ",")
					sampled = sampled + 1
					tot_in_n = tot_in_n + in_n
					tot_in_b = tot_in_b + in_b
					tot_ring_n = tot_ring_n + ring_n
					tot_ring_b = tot_ring_b + ring_b
					if in_b > 0 then with_imprint = with_imprint + 1 end
				end
				idx = idx + stride
			end

			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_passimprint")
			end

			local pb = map.mapdata and map.mapdata.PassBorder
			emit(string.format("#map,%s,grid=%dx%d,objects=%d,valid=%d,flagged=%d,candidates=%d,"
				.. "stride=%d,sampled=%d,in_n=%d,in_blocked=%d,ring_n=%d,ring_blocked=%d,"
				.. "objs_with_imprint=%d,passborder=%s,ms=%d", tag, gw, gh, #objs, n_valid,
				n_flagged, #cand, stride, sampled, tot_in_n, tot_in_b, tot_ring_n, tot_ring_b,
				with_imprint, tostring(pb), GetPreciseTicks() - t0))
			for i = 1, #rows do emit(rows[i]) end
			return { candidates = #cand, sampled = sampled, in_n = tot_in_n, in_blocked = tot_in_b,
				ring_n = tot_ring_n, ring_blocked = tot_ring_b, with_imprint = with_imprint }
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
			local ir = r.in_n > 0 and (100 * r.in_blocked / r.in_n) or -1
			local rr = r.ring_n > 0 and (100 * r.ring_blocked / r.ring_n) or -1
			return string.format("objs=%d sampled=%d inside %d/%d (%d%%) ring %d/%d (%d%%) "
				.. "with_imprint=%d", r.candidates, r.sampled, r.in_blocked, r.in_n, ir,
				r.ring_blocked, r.ring_n, rr, r.with_imprint)
		end
		g_ParityPassImpInfo = "surface " .. brief(s) .. " | underground " .. brief(u)
		g_ParityPassImpStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityPassImpError = tostring(err)
		g_ParityPassImpStatus = "error"
	end
end)
return "passimprint_probe_started"

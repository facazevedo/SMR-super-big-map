-- Object-FREE passability lattice probe (the user ruling's discriminating measurement).
--
-- `pass_probe.lua` samples passability AT every object, so its residue mixes two causes that
-- cannot be told apart there:
--   (1) the terrain transform (a slope threshold crossed differently on the stretched ground),
--   (2) object obstruction geometry - objects keep their real size while the map grows 4/3 in
--       each axis, so a neighbour that blocked a cell in vanilla is 4/3 further away in the
--       expanded map and may no longer block it.  Cause (2) is inherently one-way false->true.
-- Every measurement so far runs ~5:1 false->true, and a systematic bias needs a systematic
-- cause, so the ruling requires terrain and objects be separated before any gate is restated.
--
-- This probe therefore samples passability on a GEOMETRIC LATTICE in SOURCE space - never at an
-- object - and keeps only samples whose distance to the NEAREST object of that map exceeds a
-- footprint-sized threshold.  Both twins walk the same source lattice (the expanded twin
-- multiplies each position by the stretch ratio), so a sample pairs with its twin by its source
-- index (sgx,sgy) alone; no object identity is involved.
--
-- Nearest-object distance is exact within one bucket radius: objects are bucketed on a
-- __BUCKET__-source-wu grid and only the 3x3 buckets around a sample are scanned, which covers
-- every object within __BUCKET__ source wu of it.  Beyond that the distance is reported capped,
-- which is all the filter needs.  Distances are reported in SOURCE units on both twins so the
-- offline join can raise the threshold without re-running the game.
--
-- Terrain height is sampled beside the passability so the same rows also witness the height
-- transform at object-free ground.
--
-- Placeholders: __POS_SCALE__, __STRIDE__, __MIN_DIST__, __BUCKET__, __OUT_PATH__.

g_ParityPassLatStatus = "running"
g_ParityPassLatInfo = false
g_ParityPassLatError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local scale = __POS_SCALE__          -- 1.0 on the vanilla twin, 8192/6144 on the expanded
		local stride = __STRIDE__            -- source height-grid cells between lattice samples
		local min_dist = __MIN_DIST__        -- emit only samples this far (SOURCE wu) from objects
		local bucket_src = __BUCKET__        -- bucket size / distance reporting cap, SOURCE wu
		local out = {}
		local function emit(s) out[#out + 1] = s end

		local const_tbl = rawget(_G, "const")
		local tile = (type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize)) or 100

		emit("#meta,scale=" .. tostring(scale) .. ",stride=" .. tostring(stride)
			.. ",min_dist_src=" .. tostring(min_dist) .. ",bucket_src=" .. tostring(bucket_src)
			.. ",tile=" .. tostring(tile))
		emit("map,sgx,sgy,x,y,h,p,dmin_src,nobj")

		local function probe_map(map, tag)
			if not map then return nil end
			local gw, gh = terrain.HeightMapSize(map)
			-- Source lattice extent: the expanded grid is the source grid scaled, so dividing by
			-- the same ratio recovers the source cell count on both twins (6144 either way).
			local src_w = math.floor(gw / scale + 0.5)
			local src_h = math.floor(gh / scale + 0.5)
			local bucket = bucket_src * scale
			local radius = min_dist * scale

			-- Bucket every object of this map by position (its own coordinates).
			local objs = map:MapGet("map") or {}
			local buckets, nobjs = {}, 0
			for i = 1, #objs do
				local obj = objs[i]
				if obj and IsValid(obj) then
					local ok_pos, px, py = pcall(obj.GetVisualPosXYZ, obj)
					if ok_pos and type(px) == "number" and type(py) == "number" then
						local key = math.floor(px / bucket) * 100000 + math.floor(py / bucket)
						local b = buckets[key]
						if not b then b = {} buckets[key] = b end
						b[#b + 1] = px
						b[#b + 1] = py
						nobjs = nobjs + 1
					end
				end
			end

			if type(PauseInfiniteLoopDetection) == "function" then
				PauseInfiniteLoopDetection("parity_passlat")
			end

			local cand, inb, kept, rows = 0, 0, 0, {}
			local sgy = 0
			while sgy < src_h do
				local sgx = 0
				while sgx < src_w do
					cand = cand + 1
					local x = math.floor((sgx * tile + tile / 2) * scale + 0.5)
					local y = math.floor((sgy * tile + tile / 2) * scale + 0.5)
					local pt = point(x, y)
					if map:IsPointInBounds(pt) then
						inb = inb + 1
						local bx, by = math.floor(x / bucket), math.floor(y / bucket)
						local best = bucket * bucket * 4  -- squared, beyond the reporting cap
						local near = 0
						for ox = -1, 1 do
							for oy = -1, 1 do
								local b = buckets[(bx + ox) * 100000 + (by + oy)]
								if b then
									for k = 1, #b, 2 do
										local dx, dy = b[k] - x, b[k + 1] - y
										local d2 = dx * dx + dy * dy
										if d2 < best then best = d2 end
										if d2 <= bucket * bucket then near = near + 1 end
									end
								end
							end
						end
						if best >= radius * radius then
							local d = math.sqrt(best)
							if d > bucket then d = bucket end
							kept = kept + 1
							rows[#rows + 1] = table.concat({ tag, tostring(sgx), tostring(sgy),
								tostring(x), tostring(y),
								tostring(map:GetHeight(pt)),
								map:IsPassable(pt) and "1" or "0",
								tostring(math.floor(d / scale + 0.5)), tostring(near) }, ",")
						end
					end
					sgx = sgx + stride
				end
				sgy = sgy + stride
			end

			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_passlat")
			end

			emit("#map," .. tag .. ",grid=" .. tostring(gw) .. "x" .. tostring(gh)
				.. ",src=" .. tostring(src_w) .. "x" .. tostring(src_h)
				.. ",objects=" .. tostring(nobjs)
				.. ",candidates=" .. tostring(cand) .. ",in_bounds=" .. tostring(inb)
				.. ",kept=" .. tostring(kept)
				.. ",zmul=" .. tostring(map.SuperBigMapZScaleMul)
				.. ",zdiv=" .. tostring(map.SuperBigMapZScaleDiv)
				.. ",zadd=" .. tostring(map.SuperBigMapZScaleAdd))
			for i = 1, #rows do emit(rows[i]) end
			return { objects = nobjs, candidates = cand, kept = kept }
		end

		local surface, underground
		for i = 1, #(Maps or {}) do
			local m = Maps[i]
			local env = m and m.mapdata and m.mapdata.Environment
			if env == "Surface" and not surface then surface = m end
			if env == "Underground" and not underground then underground = m end
		end
		local t0 = GetPreciseTicks()
		local s = probe_map(surface, "surface")
		local u = probe_map(underground, "underground")

		local werr = AsyncStringToFile("__OUT_PATH__", table.concat(out, "\n"))
		if werr then error("write failed: " .. tostring(werr)) end
		g_ParityPassLatInfo = string.format(
			"surface kept=%s of %s (objects %s) underground kept=%s of %s (objects %s) ms=%d",
			s and tostring(s.kept) or "-", s and tostring(s.candidates) or "-",
			s and tostring(s.objects) or "-",
			u and tostring(u.kept) or "-", u and tostring(u.candidates) or "-",
			u and tostring(u.objects) or "-", GetPreciseTicks() - t0)
		g_ParityPassLatStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityPassLatError = tostring(err)
		g_ParityPassLatStatus = "error"
	end
end)
return "passlattice_probe_started"

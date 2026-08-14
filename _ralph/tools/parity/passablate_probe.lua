-- Passability INPUT-ABLATION probe (item C1d: is the wonder object the applier of the pit-region
-- mask, and if so which of its properties makes the expanded clone fail to apply it?).
--
-- State of the investigation (45S82E underground, flat ground around the `BottomlessPit`): vanilla
-- blocks ~54% of a 40,401-cell window and the expanded twin almost none, while every measured input
-- matches - height (022), terrain type (023), nearby objects (023), forced flag and pass type (024).
-- 027b settled ownership: the REBUILD owns the bits (it restores the whole-map hash EXACTLY after a
-- `ClearPassabilityBox` write), so the mask is re-derived every rebuild from a persistent input.
-- The one input class never ablated is the `BottomlessPit` wonder itself - the only efApplyToGrids
-- object covering the body.  The twins' own object dumps (`out/objects-t5{a,x}.csv`) show two
-- differences in that object that no probe has tested:
--     vanilla   pos (298000,301368) with NO valid z (terrain-following), scale 100
--     expanded  pos (397333,401824) with an EXPLICIT z = 1000,               scale 133
-- Either could stop the engine from rasterising the object's surfaces into the pass grid.
--
-- The ladder therefore ablates, restores, and re-measures - every stage is followed by the engine's
-- own InvalidateHeight+InvalidateType+RebuildPassability over the WHOLE map (the local-box path is
-- avoided here so no stage can be dismissed as "nothing was invalidated"), a full resample of the
-- window and a whole-map `HashPassability`:
--     s0  baseline
--     s1  SCALE flipped to the other twin's value      s2  scale restored (control)
--     s3  Z MODE flipped (valid z <-> terrain-following)  s4  z mode restored (control)
--     s5  efApplyToGrids CLEARED                       s6  flag restored (control)
--     s7  object DELETED (DoneObject)                  s8  one more rebuild (idempotence)
-- A restore stage that does NOT return the window to its baseline verdicts invalidates that
-- stage's reading, and the scorer says so instead of interpreting it.
--
-- Reading:
--   * vanilla mask collapses at s5/s7 -> the object IS the applier; the expanded clone's failure is
--     then a concrete defect, and s1/s3 name which property causes it;
--   * expanded mask APPEARS at s1 (scale 133 -> 100) or s3 (explicit z -> terrain-following) -> the
--     mechanism is named and the fix is that property;
--   * vanilla mask survives every ablation -> the object is not the applier, and the repair route is
--     the rebuild-time `OnPassabilityRebuilding` hook (027b).
--
-- MUTATES passability AND the map's objects: runs LAST and ALONE, and its map must never be scored
-- for anything else afterwards.
--
-- Placeholders: __POS_SCALE__, __CENTRE_CLASS__, __RADIUS__, __STRIDE__, __OUT_PATH__.

g_ParityPassAblStatus = "running"
g_ParityPassAblInfo = false
g_ParityPassAblError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local scale = __POS_SCALE__             -- 1.0 on the vanilla twin, 8192/6144 on the expanded
		local centre_class = "__CENTRE_CLASS__" -- object class whose neighbourhood is scanned
		local radius_src = __RADIUS__           -- scan radius, SOURCE wu
		local stride_src = __STRIDE__           -- lattice step, SOURCE wu
		local out = {}
		local function emit(s) out[#out + 1] = s end

		local const_tbl = rawget(_G, "const")
		local tile = (type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize)) or 100
		local terrain_api = rawget(_G, "terrain")
		local ef_grids = (type(const_tbl) == "table" and const_tbl.efApplyToGrids) or nil
		local ef_collision = (type(const_tbl) == "table" and const_tbl.efCollision) or nil
		local ef_walkable = (type(const_tbl) == "table" and const_tbl.efWalkable) or nil
		local gof_scale_surf = (type(const_tbl) == "table" and const_tbl.gofScaleSurfaces) or nil

		emit("#meta,scale=" .. tostring(scale) .. ",centre_class=" .. centre_class
			.. ",radius_src=" .. tostring(radius_src) .. ",stride_src=" .. tostring(stride_src)
			.. ",tile=" .. tostring(tile))
		emit("map,sgx,sgy,x,y,h,p0,p1,p2,p3,p4,p5,p6,p7,p8,d_src")

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
			local oka, an = pcall(obj.GetAngle, obj)
			rep[#rep + 1] = "angle=" .. tostring(oka and an)
			local function flag(name, mask)
				if not mask or type(obj.GetEnumFlags) ~= "function" then
					rep[#rep + 1] = name .. "=?"
					return
				end
				local okf, f = pcall(obj.GetEnumFlags, obj, mask)
				rep[#rep + 1] = name .. "=" .. tostring(okf and (f ~= 0))
			end
			flag("ef_grids", ef_grids)
			flag("ef_collision", ef_collision)
			flag("ef_walkable", ef_walkable)
			if gof_scale_surf and type(obj.GetGameFlags) == "function" then
				local okf, f = pcall(obj.GetGameFlags, obj, gof_scale_surf)
				rep[#rep + 1] = "gof_scale_surfaces=" .. tostring(okf and (f ~= 0))
			else
				rep[#rep + 1] = "gof_scale_surfaces=?"
			end
			local ent = ""
			local oke, e = pcall(obj.GetEntity, obj)
			if oke then ent = tostring(e) end
			rep[#rep + 1] = "entity=" .. ent
			if type(rawget(_G, "GetEntityBoundingBox")) == "function" and ent ~= "" then
				local okb, bb = pcall(GetEntityBoundingBox, ent)
				if okb and bb then
					rep[#rep + 1] = "ebb=" .. tostring(bb:sizex()) .. "x" .. tostring(bb:sizey())
						.. "x" .. tostring(bb:sizez())
				end
			end
			local surf = rawget(_G, "EntitySurfaces")
			if type(surf) == "table" and type(rawget(_G, "HasAnySurfaces")) == "function"
				and ent ~= "" then
				for _, sname in ipairs({ "Collision", "Walk", "ApplyToGrids", "Height", "Terrain",
					"TerrainHole", "Passability" }) do
					if surf[sname] then
						local okh, h = pcall(HasAnySurfaces, ent, surf[sname])
						rep[#rep + 1] = "surf_" .. sname .. "=" .. tostring(okh and h)
					end
				end
			end
			if type(obj.GetObjectBBox) == "function" then
				local okob, ob = pcall(obj.GetObjectBBox, obj)
				if okob and ob then
					rep[#rep + 1] = "obb=" .. tostring(ob:sizex()) .. "x" .. tostring(ob:sizey())
				end
			end
			rep[#rep + 1] = "terrain_h=" .. tostring(okp and map:GetHeight(point(px, py)))
			emit(table.concat(rep, ","))
		end

		local function probe_map(map, tag)
			if not map then return nil end
			local gw, gh = terrain.HeightMapSize(map)
			local objs = map:MapGet("map") or {}
			local pit, cx, cy = nil, nil, nil
			local grid_objs = 0
			for i = 1, #objs do
				local obj = objs[i]
				if obj and IsValid(obj) then
					if obj.class == centre_class and not pit then
						local ok_pos, px, py = pcall(obj.GetVisualPosXYZ, obj)
						if ok_pos then pit, cx, cy = obj, px, py end
					end
					if ef_grids and type(obj.GetEnumFlags) == "function" then
						local okf, f = pcall(obj.GetEnumFlags, obj, ef_grids)
						if okf and f ~= 0 then grid_objs = grid_objs + 1 end
					end
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
			emit(string.format("#centre,%s,x=%d,y=%d,sgx=%d,sgy=%d,objects=%d,grid_objs=%d,"
				.. "grid=%dx%d", tag, cx, cy, c_sgx, c_sgy, #objs, grid_objs, gw, gh))

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

			if type(PauseInfiniteLoopDetection) == "function" then
				PauseInfiniteLoopDetection("parity_passablate")
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

			-- Baseline object state, so every stage can be restored exactly.
			local base_scale = select(2, pcall(pit.GetScale, pit))
			local base_pos = select(2, pcall(pit.GetPos, pit))
			local base_valid_z = false
			if base_pos then
				local okv, v = pcall(base_pos.IsValidZ, base_pos)
				base_valid_z = okv and v or false
			end
			local base_grids = true
			if ef_grids then
				local okf, f = pcall(pit.GetEnumFlags, pit, ef_grids)
				base_grids = okf and (f ~= 0) or false
			end

			local function act(label, fn)
				local ok_a, e = pcall(fn)
				emit(string.format("#act,%s,%s,ok=%s%s", tag, label, tostring(ok_a),
					ok_a and "" or (",err=" .. string.gsub(tostring(e), "[,\r\n]", " "))))
				return ok_a
			end
			local function stage(key, label, fn)
				act(label, fn)
				rebuild("rebuild_" .. label)
				sample(key)
				hashes[#hashes + 1] = hash()
				if IsValid(pit) then obj_report(map, tag, pit, label) end
			end

			-- s1/s2: SCALE.  Flip to the other twin's value, then restore.
			local other_scale = (base_scale and base_scale >= 120) and 100 or 133
			stage("1", "scale_" .. tostring(other_scale),
				function() pit:SetScale(other_scale) end)
			stage("2", "scale_restore_" .. tostring(base_scale),
				function() pit:SetScale(base_scale) end)

			-- s3/s4: Z MODE.  A valid z becomes terrain-following and vice versa.
			local bx_, by_ = base_pos and base_pos:x() or cx, base_pos and base_pos:y() or cy
			stage("3", base_valid_z and "z_terrain_following" or "z_explicit", function()
				if base_valid_z then
					pit:SetPos(point(bx_, by_))
				else
					pit:SetPos(point(bx_, by_, map:GetHeight(point(bx_, by_))))
				end
			end)
			stage("4", "z_restore", function() pit:SetPos(base_pos) end)

			-- s5/s6: the efApplyToGrids flag itself.
			stage("5", "ef_grids_clear", function()
				if ef_grids then pit:ClearEnumFlags(ef_grids) end
				if type(pit.InvalidateSurfaces) == "function" then pit:InvalidateSurfaces() end
			end)
			stage("6", "ef_grids_restore", function()
				if ef_grids and base_grids then pit:SetEnumFlags(ef_grids) end
				if type(pit.InvalidateSurfaces) == "function" then pit:InvalidateSurfaces() end
			end)

			-- s7/s8: delete the object outright, then rebuild once more (idempotence).
			stage("7", "delete", function() DoneObject(pit) end)
			rebuild("rebuild_idempotence")
			sample("8")
			hashes[#hashes + 1] = hash()

			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_passablate")
			end

			-- Per-stage window statistics, plus the change relative to the baseline verdicts.
			local blocked, changed = {}, {}
			for k = 0, 8 do blocked[k] = 0; changed[k] = 0 end
			for i = 1, #samples do
				local s = samples[i]
				for k = 0, 8 do
					if s["p" .. k] == 0 then blocked[k] = blocked[k] + 1 end
					if s["p" .. k] ~= s.p0 then changed[k] = changed[k] + 1 end
				end
			end

			local hparts = {}
			for i = 1, #hashes do hparts[#hparts + 1] = "h" .. (i - 1) .. "=" .. hashes[i] end
			emit(string.format("#hash,%s,%s", tag, table.concat(hparts, ",")))
			local bparts, cparts = {}, {}
			for k = 0, 8 do
				bparts[#bparts + 1] = "blocked" .. k .. "=" .. blocked[k]
				cparts[#cparts + 1] = "changed" .. k .. "=" .. changed[k]
			end
			emit(string.format("#summary,%s,grid=%dx%d,samples=%d,%s,%s,base_scale=%s,"
				.. "base_valid_z=%s,base_ef_grids=%s,ms=%d", tag, gw, gh, #samples,
				table.concat(bparts, ","), table.concat(cparts, ","), tostring(base_scale),
				tostring(base_valid_z), tostring(base_grids), GetPreciseTicks() - t0))

			for i = 1, #samples do
				local s = samples[i]
				local row = { tag, tostring(s.sgx), tostring(s.sgy), tostring(s.x), tostring(s.y),
					tostring(s.h) }
				for k = 0, 8 do row[#row + 1] = tostring(s["p" .. k]) end
				row[#row + 1] = tostring(s.d)
				emit(table.concat(row, ","))
			end
			return { samples = #samples, blocked = blocked, changed = changed,
				base_scale = base_scale, base_valid_z = base_valid_z }
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
			for k = 0, 8 do parts[#parts + 1] = tostring(r.blocked[k]) end
			return string.format("n=%d blocked %s scale=%s valid_z=%s", r.samples,
				table.concat(parts, "->"), tostring(r.base_scale), tostring(r.base_valid_z))
		end
		g_ParityPassAblInfo = "surface " .. brief(s) .. " | underground " .. brief(u)
		g_ParityPassAblStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityPassAblError = tostring(err)
		g_ParityPassAblStatus = "error"
	end
end)
return "passablate_probe_started"

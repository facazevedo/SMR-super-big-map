-- Passability CLASS-vs-INSTANCE probe (item C1g: is the expanded map's inert `BottomlessPit` a
-- broken INSTANCE, or is that class/entity rasterised out on the expanded map altogether?).
--
-- State of the investigation (45S82E underground): 028 proved the wonder object IS the applier of
-- the pit-region mask on vanilla (window blocked 21,719 -> 864 when it is deleted) while the
-- expanded clone changes NOTHING at any ablation stage; 029's read-only census proved the failure is
-- NOT map-wide (516 of 516 other underground objects imprint on the expanded map with vanilla's
-- inside-vs-ring margin) and that `grids_applied` is the hex object grid, not the pass grid; 030
-- proved the clone is inert AT EVERY POSE (moved 120,000 src wu to fresh ground: 0 of 80,802 cells
-- changed) while vanilla's imprint follows the object exactly.  So the defect is the instance or the
-- class - and only a FRESH object of that class/entity, placed by this probe on the same ground,
-- separates the two.
--
-- Two windows are sampled on the SAME map at every stage, both 201x201 source cells, identical to
-- 030's so every per-cell column joins the earlier measurements:
--     ORIGIN       centred on the existing object's own pose (the window shared with 023/024/026/
--                  027b/028/030)
--     DESTINATION  centred `__DEST_OFFSET__` SOURCE wu away in x - the ground where vanilla's moved
--                  pit imprinted +13,008 cells in 030, i.e. proven able to carry an imprint
-- and the ladder is
--     s0  baseline (no action)
--     s1  whole-map InvalidateHeight+InvalidateType+RebuildPassability, nothing placed   (CONTROL:
--         must reproduce s0 in both windows, else the run is void)
--     s2  place a FRESH `Shapeshifter` carrying the wonder's ENTITY at the destination, terrain-
--         following z, `efApplyToGrids` set, rebuild                     (the entity-level test)
--     s3  `DoneObject` it, rebuild                                                       (CONTROL:
--         must return both windows to s1 and the whole-map hash exactly)
--     s4  place a FRESH object of the wonder's own CLASS at the destination, `efApplyToGrids` set,
--         rebuild                                                        (the class-level test)
--     s5  `DoneObject` it, rebuild                                                       (CONTROL)
-- with a whole-map `HashPassability` after every stage.
--
-- The same run dumps the FULL property set of every instance it can see - the existing wonder, the
-- fresh shapeshifter and the fresh class instance - as `#prop` rows: class, entity, pose, scale,
-- angle, axis, EVERY named `ef*` enum flag and `gof*` game flag found in `const`, entity surfaces,
-- bboxes, collection, parent/attachment, map ownership, `grids_applied`, and the object's own Lua
-- members (mod stamps included).  A difference between the twins can then be NAMED rather than
-- guessed.
--
-- Reading:
--   * vanilla is the positive control: a fresh object with that entity must imprint at the
--     destination, or the ladder cannot see an imprint at all and the run is void;
--   * expanded, fresh object DOES imprint -> the class/entity rasterises fine on that map and the
--     defect is in how the mod's wonder path constructs/mutates the clone
--     (`sbm_map_generation.lua:6666-6813` / native spawn at `7531+`); the `#prop` diff points at the
--     field;
--   * expanded, fresh object is inert too -> the class/entity is rasterised out on that map, and the
--     repair route is 027b's load-time `OnMsg.OnPassabilityRebuilding` + `terrain.ClearPassabilityBox`.
--
-- MUTATES passability AND places/deletes objects (both removed at s3/s5): runs LAST and ALONE, and
-- its map must never be scored for anything else afterwards.
--
-- Placeholders: __POS_SCALE__, __CENTRE_CLASS__, __RADIUS__, __STRIDE__, __DEST_OFFSET__,
-- __OUT_PATH__.

g_ParityPassClassStatus = "running"
g_ParityPassClassInfo = false
g_ParityPassClassError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local scale = __POS_SCALE__             -- 1.0 on the vanilla twin, 8192/6144 on the expanded
		local centre_class = "__CENTRE_CLASS__" -- object class whose fresh twin is placed
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
		emit("map,window,sgx,sgy,x,y,h,p0,p1,p2,p3,p4,p5,d_src,inplay")

		local function has(fname)
			return type(terrain_api) == "table" and type(terrain_api[fname]) == "function"
		end
		for _, fname in ipairs({ "InvalidateHeight", "InvalidateType", "RebuildPassability",
			"HashPassability" }) do
			emit("#api," .. fname .. "," .. tostring(has(fname)))
		end

		-- Every named enum/game flag this build defines, sorted so both twins' dumps line up.
		local ef_names, gof_names = {}, {}
		if type(const_tbl) == "table" then
			for k, v in pairs(const_tbl) do
				if type(v) == "number" and type(k) == "string" then
					if string.sub(k, 1, 2) == "ef" then ef_names[#ef_names + 1] = k end
					if string.sub(k, 1, 3) == "gof" then gof_names[#gof_names + 1] = k end
				end
			end
		end
		table.sort(ef_names)
		table.sort(gof_names)

		local function csv(v) return string.gsub(tostring(v), "[,\r\n]", " ") end

		-- Full property dump of one instance.  One `#prop` row per key so a twin diff is a plain
		-- line diff; nothing is summarised away.
		local function prop_dump(map, tag, who, obj)
			local function put(key, val) emit("#prop," .. tag .. "," .. who .. "," .. key .. "," .. csv(val)) end
			if not obj then put("present", "false") return end
			put("present", "true")
			put("valid", tostring(IsValid(obj)))
			put("class", tostring(obj.class))
			local oke, ent = pcall(obj.GetEntity, obj)
			ent = oke and tostring(ent) or ""
			put("entity", ent)
			local okp, px, py, pz = pcall(obj.GetVisualPosXYZ, obj)
			put("vis_x", okp and px or "?")
			put("vis_y", okp and py or "?")
			put("vis_z", okp and pz or "?")
			local okg, gp = pcall(obj.GetPos, obj)
			if okg and gp then
				put("pos_z", gp:z())
				local okv, v = pcall(gp.IsValidZ, gp)
				put("valid_z", okv and tostring(v) or "?")
			end
			if okp then put("terrain_h", map:GetHeight(point(px, py))) end
			for _, fn in ipairs({ "GetScale", "GetAngle", "GetAxis", "GetMirrored", "GetOpacity",
				"GetRadius", "GetState", "GetStateText", "GetAnim", "GetCollectionIndex",
				"GetGameFlags", "GetEnumFlags", "GetClassFlags", "GetSurfacesRadius" }) do
				if type(obj[fn]) == "function" then
					local okf, r = pcall(obj[fn], obj)
					put(fn, okf and tostring(r) or ("err:" .. tostring(r)))
				else
					put(fn, "missing")
				end
			end
			for _, name in ipairs(ef_names) do
				local mask = const_tbl[name]
				if type(obj.GetEnumFlags) == "function" then
					local okf, f = pcall(obj.GetEnumFlags, obj, mask)
					put("ef." .. name, okf and tostring(f ~= 0) or "?")
				end
			end
			for _, name in ipairs(gof_names) do
				local mask = const_tbl[name]
				if type(obj.GetGameFlags) == "function" then
					local okf, f = pcall(obj.GetGameFlags, obj, mask)
					put("gof." .. name, okf and tostring(f ~= 0) or "?")
				end
			end
			put("grids_applied", tostring(rawget(obj, "grids_applied")))
			local okpar, par = pcall(obj.GetParent, obj)
			put("parent", okpar and tostring(par and par.class or par) or "?")
			if type(obj.GetAttaches) == "function" then
				local oka, a = pcall(obj.GetAttaches, obj)
				put("attaches", oka and tostring(a and #a or 0) or "?")
			end
			if type(obj.GetMapID) == "function" then
				local okm, m = pcall(obj.GetMapID, obj)
				put("map_id", okm and tostring(m) or "?")
			end
			put("obj_map_field", tostring(rawget(obj, "map") and "set" or "nil"))
			if type(map.GetMapID) == "function" then
				local okm, m = pcall(map.GetMapID, map)
				put("probe_map_id", okm and tostring(m) or "?")
			end
			if type(obj.GetObjectBBox) == "function" then
				local okob, ob = pcall(obj.GetObjectBBox, obj)
				if okob and ob then
					put("obb", tostring(ob:sizex()) .. "x" .. tostring(ob:sizey())
						.. "x" .. tostring(ob:sizez()))
					put("obbmin", tostring(ob:minx()) .. "|" .. tostring(ob:miny()))
				end
			end
			if type(rawget(_G, "GetEntityBoundingBox")) == "function" and ent ~= "" then
				local okb, bb = pcall(GetEntityBoundingBox, ent)
				if okb and bb then
					put("ebb", tostring(bb:sizex()) .. "x" .. tostring(bb:sizey())
						.. "x" .. tostring(bb:sizez()))
				end
			end
			local surf = rawget(_G, "EntitySurfaces")
			if type(surf) == "table" and type(rawget(_G, "HasAnySurfaces")) == "function"
				and ent ~= "" then
				for _, sname in ipairs({ "Collision", "Walk", "ApplyToGrids", "Height", "Terrain",
					"TerrainHole", "Passability", "Selection", "Build" }) do
					if surf[sname] then
						local okh, h = pcall(HasAnySurfaces, ent, surf[sname])
						put("surf." .. sname, okh and tostring(h) or "?")
					end
				end
			end
			-- The object's own Lua members: mod stamps and anything unexpected.  Sorted and capped.
			local keys = {}
			for k, v in pairs(obj) do
				if type(k) == "string" and type(v) ~= "function" and type(v) ~= "table" then
					keys[#keys + 1] = k
				end
			end
			table.sort(keys)
			put("lua_members", #keys)
			for i = 1, math.min(#keys, 80) do
				put("member." .. keys[i], tostring(rawget(obj, keys[i])))
			end
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

			-- Destination centre, in SOURCE cells: the same rule as 030's move probe, so this is the
			-- same ground where vanilla's moved pit imprinted.
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
				PauseInfiniteLoopDetection("parity_passclass")
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
							.. (ok_i and "" or (":" .. csv(e)))
					else
						rep[#rep + 1] = fname .. "=missing"
					end
				end
				local ok_r, e = pcall(terrain_api.RebuildPassability, map, full)
				rep[#rep + 1] = "RebuildPassability=" .. tostring(ok_r)
					.. (ok_r and "" or (":" .. csv(e)))
				emit(string.format("#step,%s,%s,ms=%d,%s", tag, label,
					GetPreciseTicks() - t0, table.concat(rep, ";")))
			end

			local t0 = GetPreciseTicks()
			for i = 1, #samples do samples[i].h = map:GetHeight(samples[i].pt) end
			sample("0")
			local hashes = { hash() }
			prop_dump(map, tag, "existing", pit)

			local function act(label, fn)
				local ok_a, e = pcall(fn)
				emit(string.format("#act,%s,%s,ok=%s%s", tag, label, tostring(ok_a),
					ok_a and "" or (",err=" .. csv(e))))
				return ok_a
			end
			local function stage(key, label, fn)
				if fn then act(label, fn) end
				rebuild("rebuild_" .. label)
				sample(key)
				hashes[#hashes + 1] = hash()
			end

			-- s1: rebuild only.  Nothing placed, so both windows must reproduce s0.
			stage("1", "rebuild_only", nil)

			-- s2: a FRESH object carrying the wonder's ENTITY, placed by this probe on the same
			-- ground.  `Shapeshifter` is the plainest class that accepts an arbitrary entity, so
			-- nothing of the wonder's own class logic is involved - this is the entity-level test.
			local fresh_ent = nil
			local dest_pt = point(dest_x, dest_y)
			stage("2", "place_entity_object", function()
				fresh_ent = PlaceObjectIn("Shapeshifter", map)
				if not fresh_ent then error("PlaceObjectIn(Shapeshifter) returned nil") end
				fresh_ent:ChangeEntity("__ENTITY__")
				fresh_ent:SetPos(dest_pt)
				if ef_grids then fresh_ent:SetEnumFlags(ef_grids) end
			end)
			if fresh_ent and IsValid(fresh_ent) then prop_dump(map, tag, "fresh_entity", fresh_ent) end

			-- s3: remove it.  Control: both windows must return to s1 and the hash must match.
			stage("3", "remove_entity_object", function()
				if fresh_ent and IsValid(fresh_ent) then DoneObject(fresh_ent) end
				fresh_ent = nil
			end)

			-- s4: a FRESH object of the wonder's own CLASS.  A building class may refuse to be
			-- placed bare; the failure is recorded and the entity-level answer still stands.
			local fresh_cls = nil
			stage("4", "place_class_object", function()
				fresh_cls = PlaceObjectIn(centre_class, map)
				if not fresh_cls then error("PlaceObjectIn(" .. centre_class .. ") returned nil") end
				fresh_cls:SetPos(dest_pt)
				if ef_grids then fresh_cls:SetEnumFlags(ef_grids) end
			end)
			if fresh_cls and IsValid(fresh_cls) then prop_dump(map, tag, "fresh_class", fresh_cls) end

			-- s5: remove it.  Control.
			stage("5", "remove_class_object", function()
				if fresh_cls and IsValid(fresh_cls) then DoneObject(fresh_cls) end
				fresh_cls = nil
			end)

			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_passclass")
			end

			-- Per-window, per-stage statistics.
			local stats = {}
			for _, wname in ipairs({ "origin", "dest" }) do
				stats[wname] = { n = 0, blocked = {}, changed = {} }
				for k = 0, 5 do stats[wname].blocked[k] = 0; stats[wname].changed[k] = 0 end
			end
			for i = 1, #samples do
				local s = samples[i]
				local st = stats[s.w]
				st.n = st.n + 1
				for k = 0, 5 do
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
				for k = 0, 5 do
					bparts[#bparts + 1] = "blocked" .. k .. "=" .. st.blocked[k]
					cparts[#cparts + 1] = "changed" .. k .. "=" .. st.changed[k]
				end
				emit(string.format("#summary,%s,%s,samples=%d,%s,%s", tag, wname, st.n,
					table.concat(bparts, ","), table.concat(cparts, ",")))
			end
			emit(string.format("#done,%s,n_origin=%d,n_dest=%d,ms=%d",
				tag, n_origin, n_dest, GetPreciseTicks() - t0))

			for i = 1, #samples do
				local s = samples[i]
				local row = { tag, s.w, tostring(s.sgx), tostring(s.sgy), tostring(s.x),
					tostring(s.y), tostring(s.h) }
				for k = 0, 5 do row[#row + 1] = tostring(s["p" .. k]) end
				row[#row + 1] = tostring(s.d)
				row[#row + 1] = tostring(s.inplay)
				emit(table.concat(row, ","))
			end
			return { samples = #samples, stats = stats }
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
				for k = 0, 5 do b[#b + 1] = tostring(st.blocked[k]) end
				parts[#parts + 1] = wname .. " " .. table.concat(b, "->")
			end
			return table.concat(parts, " | ")
		end
		g_ParityPassClassInfo = "surface " .. brief(s) .. " || underground " .. brief(u)
		g_ParityPassClassStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityPassClassError = tostring(err)
		g_ParityPassClassStatus = "error"
	end
end)
return "passclass_probe_started"

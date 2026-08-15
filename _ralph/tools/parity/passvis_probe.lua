-- Passability VISIBILITY-ABLATION probe (item C1h: is `efVisible` the reason the expanded map's
-- `BottomlessPit` clone rasterises no impassability?).
--
-- State of the investigation (45S82E underground): 028 proved the wonder object IS the applier of
-- the pit-region mask on vanilla (window blocked 21,719 -> 864 when it is deleted, every restore
-- exact) while the expanded clone changes NOTHING at any ablation stage; 029 proved the failure is
-- not map-wide (516 of 516 other underground objects imprint there); 030 proved the clone is inert
-- AT EVERY POSE; 031 proved a FRESH object of that ENTITY and of that CLASS imprints +7,487 cells on
-- the expanded map, so the class is fine and the mod's own INSTANCE is the defect.  031's 201-key
-- property dump left exactly ONE untested named field that differs between the twins' live wonders
-- AND between the inert clone and the fresh objects that do imprint: the enum flag `efVisible`
-- (295239947 vs 295239939 - a single bit, 8).  It is false on the clone because the mod itself
-- clears it: `BuriedWonderDarkness.SyncVisibility` -> `wonder:SetVisible(false)`.
--
-- ONE window is sampled on each map at every stage, the same 201x201 source cells / 200 src-wu
-- lattice centred on the object's own pose that 023/024/026/027b/028/030/031 used, so every per-cell
-- column joins the earlier measurements.  The ladder is
--     s0  baseline (no action)
--     s1  whole-map InvalidateHeight+InvalidateType+RebuildPassability, object untouched  (CONTROL:
--         must reproduce s0, else the run is void)
--     s2  FLIP the raw `efVisible` bit (Set/ClearEnumFlags - exactly the bit that differs), rebuild
--     s3  restore the raw bit, rebuild                                                    (CONTROL:
--         must return to s1 and to its whole-map hash, else s2's reading is void)
--     s4  FLIP visibility through the object's own `SetVisible` API - the very call the mod makes,
--         in case the class overrides it and does more than the bit, rebuild
--     s5  restore through `SetVisible`, rebuild                                            (CONTROL)
-- with a whole-map `HashPassability` after every stage.  The flip is written as "not the baseline
-- value", so the SAME probe is the positive control on vanilla (true -> false) and the test on the
-- expanded map (false -> true) - a mirror pair, not two different experiments.
--
-- Reading, fixed in advance:
--   * vanilla's window collapsing from ~21,719 toward ~864 when the bit is cleared, and the expanded
--     window rising from ~866 toward vanilla's figure when it is set, PROVES that clearing
--     `efVisible` suppresses pass-grid rasterisation; the fix then belongs in `BuriedWonderDarkness`
--     (conceal the mesh by another means, or re-apply the imprint after concealing), NOT in the Z
--     transform;
--   * no change on either twin refutes visibility and sends the search back to the clone's remaining
--     state (`gofAlwaysRenderable`, its 3 attaches, `revealed=false`, the mod's own Lua stamps).
--
-- MUTATES passability AND an object's enum flags (restored at s3/s5): runs LAST and ALONE, and its
-- map must never be scored for anything else afterwards.
--
-- Placeholders: __POS_SCALE__, __CENTRE_CLASS__, __RADIUS__, __STRIDE__, __OUT_PATH__.

g_ParityPassVisStatus = "running"
g_ParityPassVisInfo = false
g_ParityPassVisError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local scale = __POS_SCALE__             -- 1.0 on the vanilla twin, 8192/6144 on the expanded
		local centre_class = "__CENTRE_CLASS__" -- object class whose visibility is ablated
		local radius_src = __RADIUS__           -- window radius, SOURCE wu
		local stride_src = __STRIDE__           -- lattice step, SOURCE wu
		local out = {}
		local function emit(s) out[#out + 1] = s end

		local const_tbl = rawget(_G, "const")
		local tile = (type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize)) or 100
		local terrain_api = rawget(_G, "terrain")
		local ef_grids = (type(const_tbl) == "table" and const_tbl.efApplyToGrids) or nil
		local ef_visible = (type(const_tbl) == "table" and const_tbl.efVisible) or nil

		emit("#meta,scale=" .. tostring(scale) .. ",centre_class=" .. centre_class
			.. ",radius_src=" .. tostring(radius_src) .. ",stride_src=" .. tostring(stride_src)
			.. ",tile=" .. tostring(tile) .. ",ef_visible=" .. tostring(ef_visible))
		emit("map,window,sgx,sgy,x,y,h,p0,p1,p2,p3,p4,p5,d_src,inplay")

		local function csv(v) return string.gsub(tostring(v), "[,\r\n]", " ") end
		local function has(fname)
			return type(terrain_api) == "table" and type(terrain_api[fname]) == "function"
		end
		for _, fname in ipairs({ "InvalidateHeight", "InvalidateType", "RebuildPassability",
			"HashPassability" }) do
			emit("#api," .. fname .. "," .. tostring(has(fname)))
		end

		-- Per-stage object state: the flag word, the one bit under test, and the fields 028/031
		-- already ablated, so a stage that moves the window can be attributed without a second run.
		local function obj_report(map, tag, obj, when)
			local rep = { "#obj", tag, when, tostring(obj.class) }
			local function put(k, v) rep[#rep + 1] = k .. "=" .. csv(v) end
			put("valid", IsValid(obj))
			local okp, px, py, pz = pcall(obj.GetVisualPosXYZ, obj)
			put("x", okp and px or "?")
			put("y", okp and py or "?")
			put("vz", okp and pz or "?")
			if type(obj.GetEnumFlags) == "function" then
				local okf, f = pcall(obj.GetEnumFlags, obj)
				put("enum_flags", okf and f or "?")
				if ef_visible then
					local okv, v = pcall(obj.GetEnumFlags, obj, ef_visible)
					put("ef_visible", okv and tostring(v ~= 0) or "?")
				end
				if ef_grids then
					local okg, g = pcall(obj.GetEnumFlags, obj, ef_grids)
					put("ef_grids", okg and tostring(g ~= 0) or "?")
				end
			end
			for _, fn in ipairs({ "GetScale", "GetRadius", "GetSurfacesRadius", "GetOpacity" }) do
				if type(obj[fn]) == "function" then
					local okf, r = pcall(obj[fn], obj)
					put(fn, okf and r or "?")
				end
			end
			if type(obj.GetAttaches) == "function" then
				local oka, a = pcall(obj.GetAttaches, obj)
				put("attaches", oka and (a and #a or 0) or "?")
			end
			if type(obj.GetObjectBBox) == "function" then
				local okob, ob = pcall(obj.GetObjectBBox, obj)
				if okob and ob then
					put("obb", tostring(ob:sizex()) .. "x" .. tostring(ob:sizey()))
				end
			end
			put("terrain_h", okp and map:GetHeight(point(px, py)) or "?")
			emit(table.concat(rep, ","))
		end

		local function probe_map(map, tag)
			if not map then return nil end
			local gw, gh = terrain.HeightMapSize(map)
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
			if not ef_visible then
				emit("#skip," .. tag .. ",const.efVisible_missing")
				return { skipped = true, objects = #objs }
			end

			-- Does this class override CObject:SetVisible?  If it does, s4/s5 test more than the bit
			-- and the difference between the two ladders is itself informative.
			local cobj = rawget(_G, "CObject")
			emit(string.format("#setvisible,%s,is_cobject_impl=%s,has_method=%s", tag,
				tostring(cobj and rawget(cobj, "SetVisible") == pit.SetVisible),
				tostring(type(pit.SetVisible) == "function")))

			local stride_cells = math.max(1, math.floor(stride_src / tile + 0.5))
			local radius_cells = math.floor(radius_src / tile + 0.5)
			local c_sgx = math.floor(cx / (scale * tile) + 0.5)
			local c_sgy = math.floor(cy / (scale * tile) + 0.5)
			emit(string.format("#centre,%s,x=%d,y=%d,sgx=%d,sgy=%d,objects=%d,grid=%dx%d",
				tag, cx, cy, c_sgx, c_sgy, #objs, gw, gh))

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
							local inplay = -1
							if type(map.IsInsidePlayArea) == "function" then
								local ok_ip, v = pcall(map.IsInsidePlayArea, map, x, y)
								if ok_ip then inplay = v and 1 or 0 end
							end
							samples[#samples + 1] = { w = "origin", sgx = sgx, sgy = sgy,
								x = x, y = y, pt = pt, inplay = inplay,
								d = math.floor(math.sqrt(ddx * ddx + ddy * ddy) / scale + 0.5) }
						end
					end
					dx = dx + stride_cells
				end
				dy = dy + stride_cells
			end

			if type(PauseInfiniteLoopDetection) == "function" then
				PauseInfiniteLoopDetection("parity_passvis")
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
			obj_report(map, tag, pit, "s0")

			local ok_v0, v0 = pcall(pit.GetEnumFlags, pit, ef_visible)
			local vis0 = ok_v0 and (v0 ~= 0) or false
			emit(string.format("#baseline_visible,%s,%s", tag, tostring(vis0)))

			local function set_bit(value)
				if value then pit:SetEnumFlags(ef_visible) else pit:ClearEnumFlags(ef_visible) end
			end
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
				if IsValid(pit) then obj_report(map, tag, pit, label) end
			end

			-- s1: rebuild only.  The object is untouched, so the window must reproduce s0.
			stage("1", "rebuild_only", nil)
			-- s2/s3: the raw bit, flipped away from this twin's baseline and back.
			stage("2", "flag_flip", function() set_bit(not vis0) end)
			stage("3", "flag_restore", function() set_bit(vis0) end)
			-- s4/s5: the same flip through the object's own API - the call the mod itself makes.
			stage("4", "setvisible_flip", function() pit:SetVisible(not vis0) end)
			stage("5", "setvisible_restore", function() pit:SetVisible(vis0) end)

			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_passvis")
			end

			local stats = { n = 0, blocked = {}, changed = {} }
			for k = 0, 5 do stats.blocked[k] = 0; stats.changed[k] = 0 end
			for i = 1, #samples do
				local s = samples[i]
				stats.n = stats.n + 1
				for k = 0, 5 do
					if s["p" .. k] == 0 then stats.blocked[k] = stats.blocked[k] + 1 end
					if s["p" .. k] ~= s.p0 then stats.changed[k] = stats.changed[k] + 1 end
				end
			end

			local hparts = {}
			for i = 1, #hashes do hparts[#hparts + 1] = "h" .. (i - 1) .. "=" .. hashes[i] end
			emit(string.format("#hash,%s,%s", tag, table.concat(hparts, ",")))
			local bparts, cparts = {}, {}
			for k = 0, 5 do
				bparts[#bparts + 1] = "blocked" .. k .. "=" .. stats.blocked[k]
				cparts[#cparts + 1] = "changed" .. k .. "=" .. stats.changed[k]
			end
			emit(string.format("#summary,%s,origin,samples=%d,%s,%s", tag, stats.n,
				table.concat(bparts, ","), table.concat(cparts, ",")))
			emit(string.format("#done,%s,n=%d,baseline_visible=%s,ms=%d",
				tag, #samples, tostring(vis0), GetPreciseTicks() - t0))

			for i = 1, #samples do
				local s = samples[i]
				local row = { tag, s.w, tostring(s.sgx), tostring(s.sgy), tostring(s.x),
					tostring(s.y), tostring(s.h) }
				for k = 0, 5 do row[#row + 1] = tostring(s["p" .. k]) end
				row[#row + 1] = tostring(s.d)
				row[#row + 1] = tostring(s.inplay)
				emit(table.concat(row, ","))
			end
			return { samples = #samples, stats = stats, vis0 = vis0 }
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
			local b = {}
			for k = 0, 5 do b[#b + 1] = tostring(r.stats.blocked[k]) end
			return "vis0=" .. tostring(r.vis0) .. " origin " .. table.concat(b, "->")
		end
		g_ParityPassVisInfo = "surface " .. brief(s) .. " || underground " .. brief(u)
		g_ParityPassVisStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityPassVisError = tostring(err)
		g_ParityPassVisStatus = "error"
	end
end)
return "passvis_probe_started"

-- Buried-wonder concealment FIX verification probe (item C1i), READ-ONLY.
--
-- Iterations 028-032 proved, on both twins at 45S82E, that the expanded map's missing pit-region
-- impassability is the mod's own darkness concealment: `BuriedWonderDarkness.SyncVisibility` called
-- `wonder:SetVisible(false)`, which clears `efVisible`, and the engine rasterises an object's
-- ApplyToGrids surfaces only while that bit is set.  032's mirror ablation measured both directions
-- (vanilla 21,719 -> 864 hidden; the clone 866 -> 21,668 shown) and the twin join collapsing
-- 20,869 -> 67 once both wonders are visible.
--
-- Mod version 808 conceals with zero OPACITY instead (patch version 3 of BuriedWonderDarkness).
-- This probe verifies that fix WITHOUT touching anything: it samples the same 201x201 source-cell /
-- 200 src-wu window centred on the map's own `BottomlessPit` that 023/024/026/027b/028/030/031/032
-- used - so every per-cell column joins those measurements - and dumps the wonder's live state, so
-- the two halves of the claim are measured in one run:
--   (a) the wonder is still CONCEALED: opacity 0 on the object and on each of its attaches, and the
--       mod's own stamps `SuperBigMapConcealedByDarkness` / `SuperBigMapDarknessVisibilityReason`
--       present on the expanded map (and absent on vanilla, which the mod never touches);
--   (b) it is now VISIBLE to the grids: `efVisible` set, and the window's blocked count at vanilla's
--       level instead of 866.
-- A run in which the expanded wonder is neither concealed nor imprinting fails the scorer: the fix
-- must not be obtained by simply disabling the concealment feature.
--
-- No mutation at all: no flag write, no rebuild, no object move.  `HashPassability` is read once so
-- the run can be compared with 028/030/031/032, which recorded the same two digests.
--
-- Placeholders: __POS_SCALE__, __CENTRE_CLASS__, __RADIUS__, __STRIDE__, __OUT_PATH__.

g_ParityPassFixStatus = "running"
g_ParityPassFixInfo = false
g_ParityPassFixError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local scale = __POS_SCALE__             -- 1.0 on the vanilla twin, 8192/6144 on the expanded
		local centre_class = "__CENTRE_CLASS__" -- object class whose neighbourhood is sampled
		local radius_src = __RADIUS__           -- window radius, SOURCE wu
		local stride_src = __STRIDE__           -- lattice step, SOURCE wu
		local out = {}
		local function emit(s) out[#out + 1] = s end
		local function csv(v) return string.gsub(tostring(v), "[,\r\n]", " ") end

		local const_tbl = rawget(_G, "const")
		local tile = (type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize)) or 100
		local terrain_api = rawget(_G, "terrain")
		local ef_grids = (type(const_tbl) == "table" and const_tbl.efApplyToGrids) or nil
		local ef_visible = (type(const_tbl) == "table" and const_tbl.efVisible) or nil

		emit("#meta,scale=" .. tostring(scale) .. ",centre_class=" .. centre_class
			.. ",radius_src=" .. tostring(radius_src) .. ",stride_src=" .. tostring(stride_src)
			.. ",tile=" .. tostring(tile) .. ",ef_visible=" .. tostring(ef_visible))
		emit("map,window,sgx,sgy,x,y,h,p0,d_src,inplay")

		-- The wonder and every attach, so a concealment that hides the root but leaves attached
		-- artwork drawing is visible in the report rather than assumed away.
		local function obj_report(map, tag, obj, role, depth)
			local rep = { "#obj", tag, role, tostring(depth), csv(obj.class) }
			local function put(k, v) rep[#rep + 1] = k .. "=" .. csv(v) end
			local okp, px, py, pz = pcall(obj.GetVisualPosXYZ, obj)
			put("x", okp and px or "?")
			put("y", okp and py or "?")
			put("vz", okp and pz or "?")
			if type(obj.GetEntity) == "function" then
				local oke, e = pcall(obj.GetEntity, obj)
				put("entity", oke and e or "?")
			end
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
			for _, fn in ipairs({ "GetOpacity", "GetScale", "GetRadius", "GetSurfacesRadius" }) do
				if type(obj[fn]) == "function" then
					local okf, r = pcall(obj[fn], obj)
					put(fn, okf and r or "?")
				end
			end
			if type(obj.IsRevealed) == "function" then
				local okr, r = pcall(obj.IsRevealed, obj, obj)
				put("revealed", okr and tostring(r) or "?")
			end
			-- The mod's own bookkeeping: present only where the concealment ran.
			put("sbm_concealed", tostring(obj.SuperBigMapConcealedByDarkness))
			put("sbm_restored", tostring(obj.SuperBigMapDarknessVisibilityRestored))
			put("sbm_reason", tostring(obj.SuperBigMapDarknessVisibilityReason))
			if type(obj.GetObjectBBox) == "function" then
				local okob, ob = pcall(obj.GetObjectBBox, obj)
				if okob and ob then
					put("obb", tostring(ob:sizex()) .. "x" .. tostring(ob:sizey()))
				end
			end
			put("terrain_h", okp and map:GetHeight(point(px, py)) or "?")
			emit(table.concat(rep, ","))
		end

		local function report_tree(map, tag, obj, role, depth, seen)
			if not obj or seen[obj] or depth > 4 then return end
			seen[obj] = true
			obj_report(map, tag, obj, role, depth)
			if type(obj.GetAttaches) ~= "function" then return end
			local oka, attaches = pcall(obj.GetAttaches, obj)
			if not oka or type(attaches) ~= "table" then return end
			for _, attach in ipairs(attaches) do
				report_tree(map, tag, attach, role .. "-attach", depth + 1, seen)
			end
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

			local stride_cells = math.max(1, math.floor(stride_src / tile + 0.5))
			local radius_cells = math.floor(radius_src / tile + 0.5)
			local c_sgx = math.floor(cx / (scale * tile) + 0.5)
			local c_sgy = math.floor(cy / (scale * tile) + 0.5)
			emit(string.format("#centre,%s,x=%d,y=%d,sgx=%d,sgy=%d,objects=%d,grid=%dx%d",
				tag, cx, cy, c_sgx, c_sgy, #objs, gw, gh))
			report_tree(map, tag, pit, "wonder", 0, setmetatable({}, { __mode = "k" }))

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
				PauseInfiniteLoopDetection("parity_passfix")
			end
			local t0 = GetPreciseTicks()
			local blocked = 0
			for i = 1, #samples do
				local s = samples[i]
				s.h = map:GetHeight(s.pt)
				s.p = map:IsPassable(s.pt) and 1 or 0
				if s.p == 0 then blocked = blocked + 1 end
			end
			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_passfix")
			end

			local hash = "missing"
			if type(terrain_api) == "table" and type(terrain_api.HashPassability) == "function" then
				local ok_h, h = pcall(terrain_api.HashPassability, map)
				hash = ok_h and tostring(h) or ("error:" .. tostring(h))
			end
			emit(string.format("#hash,%s,h0=%s", tag, hash))
			emit(string.format("#summary,%s,origin,samples=%d,blocked=%d", tag, #samples, blocked))
			emit(string.format("#done,%s,n=%d,ms=%d", tag, #samples, GetPreciseTicks() - t0))

			for i = 1, #samples do
				local s = samples[i]
				emit(table.concat({ tag, s.w, tostring(s.sgx), tostring(s.sgy), tostring(s.x),
					tostring(s.y), tostring(s.h), tostring(s.p), tostring(s.d),
					tostring(s.inplay) }, ","))
			end
			return { samples = #samples, blocked = blocked, hash = hash }
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
			return string.format("n=%d blocked=%d", r.samples, r.blocked)
		end
		g_ParityPassFixInfo = "surface " .. brief(s) .. " || underground " .. brief(u)
		g_ParityPassFixStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityPassFixError = tostring(err)
		g_ParityPassFixStatus = "error"
	end
end)
return "passfix_probe_started"

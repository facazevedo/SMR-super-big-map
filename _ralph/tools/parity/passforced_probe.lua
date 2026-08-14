-- Passability-INPUT probe #2: is the vanilla-only mask around the underground Bottomless Pit
-- carried by ENGINE-SIDE FORCED impassability (or by a pass TYPE), rather than by terrain?
--
-- Iterations 021-023 measured every input the earlier probes could read and found them equal on
-- the two twins over the same 40,401 source cells: ground provably flat on both (max quad-edge
-- slope 0 wu, threshold 27), terrain type identical on 40,401/40,401, no map grid stale (this
-- build defines only BiomeGrid + MapGenSkipGrid and the expanded BiomeGrid is the size
-- `MapGridSize` expects), no object within +-300 source wu of any differing cell,
-- `ForcedImpassableMarkers` nil on both, and BOTH rebuild paths inert
-- (`terrain.RebuildPassability`, `map:RebuildGrids(box)`).  Yet vanilla blocks 21,719 of those
-- cells and the expanded map 866.
--
-- The one input class never sampled is the engine's own pass state, which this build exports:
-- `IsForcedImpassable`, `GetPassType`, `IsTunnelPassable`, `GetPassGrid`, `PassMapSize`,
-- `PassTileSize` (see `artifacts/engine_grid_ops.md`).  If vanilla is forced-impassable across the
-- disc and the expanded map is not, the mask is engine-side geometry applied at generation in
-- SOURCE space that the stretch never re-applies - a concrete defect with a concrete fix.
--
-- This probe only READS (no rebuild, no pass edit, no height edit), so it may run beside the other
-- reading probes.  It measures, on BOTH twins over the SAME source cells:
--   (1) the pass system's own geometry per map: `PassMapSize`, `PassTileSize`,
--       `GetPassGridsCount`, `HashPassability`, beside the height/type map sizes - a pass grid that
--       kept the SOURCE size on an expanded map would itself be the defect;
--   (2) per lattice sample: `IsPassable`, `IsForcedImpassable`, `GetPassType`,
--       `IsTunnelPassable`, height - so the mask can be cross-tabbed against the verdict cell by
--       cell, exactly as iteration 023 did with terrain type;
--   (3) the same 20 fixed forensic source cells the mask probe used, with the same four values;
--   (4) optionally the raw pass grid(s) via `GetPassGrid` + `GridSaveRaw`, for an offline
--       full-resolution comparison if the per-cell answer is "false on both".
--
-- Engine argument conventions are NOT assumed: each engine call is resolved once, by trying the
-- shapes (map, pt), (map, x, y), (pt), (x, y) under pcall and recording which one answered and
-- what the others raised (`#call` rows).  A call that cannot be resolved is reported as such
-- instead of being silently read as `false` - a false read would look like evidence.
--
-- Placeholders: __POS_SCALE__, __CENTRE_CLASS__, __RADIUS__, __STRIDE__, __CELLS__,
--               __DUMP_GRID__, __GRID_PREFIX__, __OUT_PATH__.

g_ParityPassForcedStatus = "running"
g_ParityPassForcedInfo = false
g_ParityPassForcedError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local scale = __POS_SCALE__             -- 1.0 on the vanilla twin, 8192/6144 on the expanded
		local centre_class = "__CENTRE_CLASS__" -- object class whose neighbourhood is scanned
		local radius_src = __RADIUS__           -- scan radius, SOURCE wu
		local stride_src = __STRIDE__           -- lattice step, SOURCE wu
		local cells = __CELLS__                 -- { {sgx, sgy, kind}, ... } forensic source cells
		local dump_grid = __DUMP_GRID__         -- also GridSaveRaw the engine pass grid(s)
		local grid_prefix = "__GRID_PREFIX__"   -- "<dir>/passgrid-<tag>" without the env suffix
		local out = {}
		local function emit(s) out[#out + 1] = s end

		local const_tbl = rawget(_G, "const")
		local tile = (type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize)) or 100
		local terrain_api = rawget(_G, "terrain")
		local point_fn = rawget(_G, "point")

		emit("#meta,scale=" .. tostring(scale) .. ",centre_class=" .. centre_class
			.. ",radius_src=" .. tostring(radius_src) .. ",stride_src=" .. tostring(stride_src)
			.. ",tile=" .. tostring(tile) .. ",dump_grid=" .. tostring(dump_grid))

		-- Resolve one engine call's argument convention ONCE, on a point known to be in bounds.
		-- Returns a function(pt, x, y) -> value or nil, plus the shape name it settled on.
		-- Only map-first shapes are tried: `terrain.GetTerrainType(map, pt)` and
		-- `terrain.HeightMapSize(map)` are measured facts of this build, and handing an engine C
		-- function a first argument of the wrong TYPE risks a hard crash rather than a Lua error.
		local SHAPES = {
			{ name = "map_pt", call = function(fn, map, pt, x, y) return fn(map, pt) end },
			{ name = "map_xy", call = function(fn, map, pt, x, y) return fn(map, x, y) end },
		}
		local function resolve(tag, fname, map, pt, x, y)
			local fn = type(terrain_api) == "table" and terrain_api[fname] or nil
			if type(fn) ~= "function" then
				emit(string.format("#call,%s,%s,missing", tag, fname))
				return nil, "missing"
			end
			local chosen, chosen_name = nil, nil
			for i = 1, #SHAPES do
				if not chosen then
					local sh = SHAPES[i]
					local ok_c, v = pcall(sh.call, fn, map, pt, x, y)
					emit(string.format("#call,%s,%s,shape=%s,ok=%s,type=%s,val=%s,err=%s", tag, fname,
						sh.name, tostring(ok_c), type(v), tostring(v),
						ok_c and "-" or string.gsub(tostring(v), "[,\r\n]", " ")))
					if ok_c and v ~= nil then
						chosen, chosen_name = sh, sh.name
					end
				end
			end
			if not chosen then return nil, "unresolved" end
			return function(p, px, py)
				local ok_v, v = pcall(chosen.call, fn, map, p, px, py)
				if ok_v then return v end
				return nil
			end, chosen_name
		end

		local function num(v)
			if type(v) == "number" then return v end
			if type(v) == "boolean" then return v and 1 or 0 end
			if v == nil then return -1 end
			return -2
		end

		local function probe_map(map, tag)
			if not map then return nil end
			local md = map.mapdata
			local gw, gh = terrain.HeightMapSize(map)
			local mw, mh = map:GetMapSize()

			-- (1) the pass system's own geometry, beside the height/type geometry.
			local function once(fname)
				local fn = type(terrain_api) == "table" and terrain_api[fname] or nil
				if type(fn) ~= "function" then return "missing", "-" end
				local ok_v, a, b = pcall(fn, map)
				if not ok_v then return "error", string.gsub(tostring(a), "[,\r\n]", " ") end
				return tostring(a), tostring(b)
			end
			local pms_w, pms_h = once("PassMapSize")
			local pts_a = once("PassTileSize")
			local pgc = once("GetPassGridsCount")
			local hp = once("HashPassability")
			local tms_w, tms_h = once("TypeMapSize")
			local tts = once("TypeTileSize")
			emit(string.format("#passinfo,%s,mapdata=%sx%s,env=%s,heightmap=%dx%d,mapsize=%dx%d,"
				.. "passmap=%sx%s,passtile=%s,passgrids=%s,hashpass=%s,typemap=%sx%s,typetile=%s",
				tag, tostring(md and md.Width), tostring(md and md.Height),
				tostring(md and md.Environment), gw, gh, mw, mh,
				pms_w, pms_h, pts_a, pgc, hp, tms_w, tms_h, tts))

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
			emit(string.format("#centre,%s,x=%d,y=%d,sgx=%d,sgy=%d,objects=%d",
				tag, cx, cy, c_sgx, c_sgy, #objs))

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
			if #samples == 0 then
				emit("#skip," .. tag .. ",no_samples_in_bounds")
				return { skipped = true, objects = #objs }
			end

			local s0 = samples[math.floor(#samples / 2) + 1]
			local f_forced, sh_forced = resolve(tag, "IsForcedImpassable", map, s0.pt, s0.x, s0.y)
			local f_type, sh_type = resolve(tag, "GetPassType", map, s0.pt, s0.x, s0.y)
			local f_tunnel, sh_tunnel = resolve(tag, "IsTunnelPassable", map, s0.pt, s0.x, s0.y)
			emit(string.format("#shapes,%s,forced=%s,passtype=%s,tunnel=%s", tag,
				tostring(sh_forced), tostring(sh_type), tostring(sh_tunnel)))

			if type(PauseInfiniteLoopDetection) == "function" then
				PauseInfiniteLoopDetection("parity_passforced")
			end
			local t0 = GetPreciseTicks()
			for i = 1, #samples do
				local s = samples[i]
				s.h = map:GetHeight(s.pt)
				s.p = map:IsPassable(s.pt) and 1 or 0
				s.fi = f_forced and num(f_forced(s.pt, s.x, s.y)) or -3
				s.pt_type = f_type and num(f_type(s.pt, s.x, s.y)) or -3
				s.tp = f_tunnel and num(f_tunnel(s.pt, s.x, s.y)) or -3
			end
			local sample_ms = GetPreciseTicks() - t0
			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_passforced")
			end

			-- (3) forensic cells, the same list the mask probe used.
			emit("#cellcols," .. tag .. ",sgx,sgy,kind,x,y,h,p,forced,passtype,tunnel")
			for i = 1, #cells do
				local sgx, sgy, kind = cells[i][1], cells[i][2], cells[i][3]
				local x = math.floor((sgx * tile + tile / 2) * scale + 0.5)
				local y = math.floor((sgy * tile + tile / 2) * scale + 0.5)
				local pt = point(x, y)
				if map:IsPointInBounds(pt) then
					emit(string.format("#cell,%s,%d,%d,%s,%d,%d,%d,%d,%d,%d,%d", tag, sgx, sgy, kind,
						x, y, map:GetHeight(pt), map:IsPassable(pt) and 1 or 0,
						f_forced and num(f_forced(pt, x, y)) or -3,
						f_type and num(f_type(pt, x, y)) or -3,
						f_tunnel and num(f_tunnel(pt, x, y)) or -3))
				end
			end

			-- (4) optional raw dump of the engine's own pass grid(s).
			if dump_grid then
				local fn = type(terrain_api) == "table" and terrain_api.GetPassGrid or nil
				if type(fn) ~= "function" then
					emit("#passgrid," .. tag .. ",missing")
				else
					for idx = 0, 2 do
						local ok_g, g = pcall(fn, map, idx)
						if not ok_g then
							ok_g, g = pcall(fn, map)
							if ok_g then idx = -1 end
						end
						local w, h, bits, saved, gerr = "-", "-", "-", "-", "-"
						local is_grid = false
						if ok_g and g ~= nil then
							if type(rawget(_G, "IsGrid")) == "function" then
								is_grid = IsGrid(g) and true or false
							else
								is_grid = type(g) == "userdata"
							end
						end
						if is_grid then
							local ok_s, sw, sh = pcall(g.size, g)
							if ok_s then w, h = tostring(sw), tostring(sh) end
							local ok_b, b = pcall(g.bits, g)
							if ok_b then bits = tostring(b) end
							if type(rawget(_G, "GridSaveRaw")) == "function" then
								local path = grid_prefix .. "-" .. tag .. "-" .. tostring(idx) .. ".raw"
								local ok_w, werr = pcall(GridSaveRaw, path, g)
								saved = ok_w and path or "-"
								gerr = ok_w and tostring(werr or "-")
									or string.gsub(tostring(werr), "[,\r\n]", " ")
							end
						elseif not ok_g then
							gerr = string.gsub(tostring(g), "[,\r\n]", " ")
						end
						emit(string.format("#passgrid,%s,idx=%s,grid=%s,w=%s,h=%s,bits=%s,saved=%s,err=%s",
							tag, tostring(idx), tostring(is_grid), w, h, bits, saved, gerr))
						if not is_grid then break end
					end
				end
			end

			local blocked, forced, tunnel_no, types = 0, 0, 0, {}
			for i = 1, #samples do
				local s = samples[i]
				if s.p == 0 then blocked = blocked + 1 end
				if s.fi == 1 then forced = forced + 1 end
				if s.tp == 0 then tunnel_no = tunnel_no + 1 end
				types[s.pt_type] = (types[s.pt_type] or 0) + 1
			end
			local hist = {}
			for k, v in pairs(types) do hist[#hist + 1] = tostring(k) .. ":" .. tostring(v) end
			table.sort(hist)
			emit(string.format("#summary,%s,samples=%d,blocked=%d,forced=%d,tunnel_impassable=%d,"
				.. "passtypes=%s,sample_ms=%d", tag, #samples, blocked, forced, tunnel_no,
				table.concat(hist, "|"), sample_ms))

			emit("#cols," .. tag .. ",map,sgx,sgy,x,y,h,p,forced,passtype,tunnel,d_src")
			for i = 1, #samples do
				local s = samples[i]
				emit(table.concat({ tag, tostring(s.sgx), tostring(s.sgy), tostring(s.x),
					tostring(s.y), tostring(s.h), tostring(s.p), tostring(s.fi),
					tostring(s.pt_type), tostring(s.tp), tostring(s.d) }, ","))
			end
			return { samples = #samples, blocked = blocked, forced = forced,
				types = table.concat(hist, "|"), shapes = tostring(sh_forced) .. "/" .. tostring(sh_type) }
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
			return string.format("n=%d blocked=%d forced=%d types=%s shapes=%s",
				r.samples, r.blocked, r.forced, r.types, r.shapes)
		end
		g_ParityPassForcedInfo = "surface " .. brief(s) .. " | underground " .. brief(u)
		g_ParityPassForcedStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityPassForcedError = tostring(err)
		g_ParityPassForcedStatus = "error"
	end
end)
return "passforced_probe_started"

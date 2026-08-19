-- Read-only native pass-lattice diagnostic for the final-v823 45S82E red baseline.
--
-- `pass_probe.lua` established literal self-cell differences at these deterministic object
-- positions even though the expanded points are exact 4/3 images of the stamped source points.
-- This probe records the native pass-map geometry, the two exposed pass-grid bits, and 3x3
-- pass/height neighbourhoods at those exact live objects.  It never edits terrain or pass state.
--
-- Placeholders: __POS_SCALE__, __OUT_PATH__.

rawset(_G, "g_ParityPassNativeStatus", "running")
rawset(_G, "g_ParityPassNativeInfo", false)
rawset(_G, "g_ParityPassNativeError", false)

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local scale = __POS_SCALE__
		local out = {}
		local function emit(s) out[#out + 1] = s end
		local terrain_api = rawget(_G, "terrain")
		if type(terrain_api) ~= "table"
			or type(terrain_api.PassMapSize) ~= "function"
			or type(terrain_api.GetPassGridsCount) ~= "function"
			or type(terrain_api.GetPassGrid) ~= "function" then
			error("native pass-grid API unavailable")
		end

		-- Stable red examples from iter781/782. The diagnostic remains deliberately scoped to the
		-- exact coordinate/seed pair that established the current acceptance-gate failure.
		local targets = {
			{ "surface", "PrefabMarker", 528063, 540 },
			{ "surface", "PrefabMarker", 140225, 6150 },
			{ "surface", "PrefabMarker", 199606, 16945 },
			{ "surface", "DecCrater_01", 442871, 19577 },
			{ "surface", "PrefabMarker", 196677, 21198 },
			{ "surface", "PrefabMarker", 192506, 22884 },
			{ "surface", "PrefabMarker", 191943, 27439 },
			{ "surface", "PrefabMarker", 198653, 33126 },
			{ "surface", "PrefabMarker", 544886, 41497 },
			{ "surface", "DecCrater_01", 377453, 42634 },
			{ "surface", "PrefabMarker", 245226, 43255 },
			{ "surface", "PrefabMarker", 219221, 45356 },
			{ "underground", "PrefabMarker", 250670, 114982 },
			{ "underground", "PrefabMarker", 277818, 189244 },
			{ "underground", "PrefabMarker", 168220, 196438 },
			{ "underground", "PrefabMarker", 116653, 201183 },
			{ "underground", "PrefabMarker", 118319, 205040 },
			{ "underground", "PrefabMarker", 319176, 212623 },
			{ "underground", "PrefabMarker", 439612, 219159 },
			{ "underground", "PrefabMarker", 133503, 221170 },
			{ "underground", "PrefabMarker", 144695, 227432 },
			{ "underground", "PrefabMarker", 442737, 234690 },
			{ "underground", "PrefabMarker", 127218, 246160 },
			{ "underground", "PrefabMarker", 191586, 259846 },
		}

		local maps = {}
		for i = 1, #(Maps or {}) do
			local map = Maps[i]
			local env = map and map.mapdata and map.mapdata.Environment
			if env == "Surface" and not maps.surface then maps.surface = map end
			if env == "Underground" and not maps.underground then maps.underground = map end
		end
		if not maps.surface or not maps.underground then error("surface/underground maps missing") end

		local function key(class, sx, sy)
			return tostring(class) .. "|" .. tostring(sx) .. "|" .. tostring(sy)
		end

		local function bit(v)
			if v == true then return "1" end
			if v == false then return "0" end
			if v == 0 or v == 1 then return tostring(v) end
			return "?"
		end

		local function safe_terrain_bool(name, map, pt)
			local fn = terrain_api[name]
			if type(fn) ~= "function" then return "?" end
			local call_ok, value = pcall(fn, map, pt)
			return call_ok and bit(value) or "?"
		end

		local function safe_terrain_num(name, map, pt)
			local fn = terrain_api[name]
			if type(fn) ~= "function" then return "?" end
			local call_ok, value = pcall(fn, map, pt)
			return call_ok and tostring(value) or "?"
		end

		emit("#meta,scale=" .. tostring(scale) .. ",targets=" .. tostring(#targets))
		emit("map,class,src_x,src_y,x,y,self_pass,map_w,map_h,pass_w,pass_h,grid_w,grid_h,"
			.. "cell_w,cell_h,gx,gy,cx,cy,source_cx,source_cy,source_cell_dx,source_cell_dy,"
			.. "cell_pass,point_height,cell_height,forced,passtype,grid0,grid1,"
			.. "grid0_3x3,grid1_3x3,pass_3x3,height_3x3")

		local found_total = 0
		for _, env in ipairs({ "surface", "underground" }) do
			local map = maps[env]
			local mw, mh = map:GetMapSize()
			local pm_ok, pw, ph = pcall(terrain_api.PassMapSize, map)
			if not pm_ok or type(pw) ~= "number" or type(ph) ~= "number" then
				error("PassMapSize failed for " .. env .. ": " .. tostring(pw))
			end
			local gc_ok, grid_count = pcall(terrain_api.GetPassGridsCount, map)
			if not gc_ok or tonumber(grid_count) ~= 2 then
				error("expected two native pass grids for " .. env .. ": " .. tostring(grid_count))
			end
			local grids = {}
			for index = 0, 1 do
				local grid_ok, grid = pcall(terrain_api.GetPassGrid, map, index)
				if not grid_ok or not grid or not IsGrid(grid) or type(grid.get) ~= "function" then
					error("GetPassGrid failed for " .. env .. " index " .. tostring(index))
				end
				grids[index + 1] = grid
			end
			local gw, gh = grids[1]:size()
			local gw1, gh1 = grids[2]:size()
			if gw ~= pw or gh ~= ph or gw1 ~= gw or gh1 ~= gh then
				error(string.format("pass geometry mismatch %s pass=%sx%s grids=%sx%s/%sx%s",
					env, tostring(pw), tostring(ph), tostring(gw), tostring(gh),
					tostring(gw1), tostring(gh1)))
			end

			local indexed = {}
			local objects = map:MapGet("map") or {}
			for i = 1, #objects do
				local obj = objects[i]
				if obj and IsValid(obj) then
					local pos_ok, x, y = pcall(obj.GetVisualPosXYZ, obj)
					if pos_ok and type(x) == "number" and type(y) == "number" then
						local sx = rawget(obj, "SuperBigMapNativeSourceX")
						local sy = rawget(obj, "SuperBigMapNativeSourceY")
						if type(sx) ~= "number" then sx = x end
						if type(sy) ~= "number" then sy = y end
						local k = key(obj.class, sx, sy)
						if not indexed[k] then indexed[k] = { obj = obj, x = x, y = y } end
					end
				end
			end

			local function center_x(gx)
				return math.floor(((gx + 0.5) * (mw + 0.0) / pw) + 0.5)
			end
			local function center_y(gy)
				return math.floor(((gy + 0.5) * (mh + 0.0) / ph) + 0.5)
			end
			local function grid_sig(grid, gx, gy)
				local values = {}
				for dy = -1, 1 do
					for dx = -1, 1 do
						local qx, qy = gx + dx, gy + dy
						if qx < 0 or qy < 0 or qx >= gw or qy >= gh then
							values[#values + 1] = "x"
						else
							values[#values + 1] = bit(grid:get(qx, qy))
						end
					end
				end
				return table.concat(values, "|")
			end
			local function query_sig(gx, gy)
				local values = {}
				for dy = -1, 1 do
					for dx = -1, 1 do
						local qx, qy = gx + dx, gy + dy
						if qx < 0 or qy < 0 or qx >= gw or qy >= gh then
							values[#values + 1] = "x"
						else
							values[#values + 1] = map:IsPassable(point(center_x(qx), center_y(qy))) and "1" or "0"
						end
					end
				end
				return table.concat(values, "|")
			end
			local function height_sig(gx, gy)
				local values = {}
				for dy = -1, 1 do
					for dx = -1, 1 do
						local qx, qy = gx + dx, gy + dy
						if qx < 0 or qy < 0 or qx >= gw or qy >= gh then
							values[#values + 1] = "x"
						else
							values[#values + 1] = tostring(map:GetHeight(point(center_x(qx), center_y(qy))))
						end
					end
				end
				return table.concat(values, "|")
			end

			for i = 1, #targets do
				local target = targets[i]
				if target[1] == env then
					local class, sx, sy = target[2], target[3], target[4]
					local hit = indexed[key(class, sx, sy)]
					if not hit then
						error(string.format("target missing %s %s %d %d", env, class, sx, sy))
					end
					local x, y = hit.x, hit.y
					local pt = point(x, y)
					local gx = math.floor((x + 0.0) * pw / mw)
					local gy = math.floor((y + 0.0) * ph / mh)
					local cx, cy = center_x(gx), center_y(gy)
					local scx = math.floor(cx / scale + 0.5)
					local scy = math.floor(cy / scale + 0.5)
					local cpt = point(cx, cy)
					emit(table.concat({ env, class, sx, sy, x, y,
						map:IsPassable(pt) and "1" or "0", mw, mh, pw, ph, gw, gh,
						string.format("%.3f", (mw + 0.0) / pw),
						string.format("%.3f", (mh + 0.0) / ph),
						gx, gy, cx, cy, scx, scy, scx - sx, scy - sy,
						map:IsPassable(cpt) and "1" or "0", map:GetHeight(pt), map:GetHeight(cpt),
						safe_terrain_bool("IsForcedImpassable", map, pt),
						safe_terrain_num("GetPassType", map, pt),
						bit(grids[1]:get(gx, gy)), bit(grids[2]:get(gx, gy)),
						grid_sig(grids[1], gx, gy), grid_sig(grids[2], gx, gy),
						query_sig(gx, gy), height_sig(gx, gy),
					}, ","))
					found_total = found_total + 1
				end
			end
		end

		if found_total ~= #targets then
			error(string.format("target count mismatch %d/%d", found_total, #targets))
		end
		local werr = AsyncStringToFile("__OUT_PATH__", table.concat(out, "\n"))
		if werr then error("write failed: " .. tostring(werr)) end
		rawset(_G, "g_ParityPassNativeInfo", string.format(
			"targets=%d scale=%s rows=%d", found_total, tostring(scale), #out))
		rawset(_G, "g_ParityPassNativeStatus", "ready")
	end, debug.traceback)
	if not ok then
		rawset(_G, "g_ParityPassNativeError", tostring(err))
		rawset(_G, "g_ParityPassNativeStatus", "error")
	end
end)
return "passnative_probe_started"

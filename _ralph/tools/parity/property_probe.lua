-- Exhaustive stock-property probe for the floor sweep's strict parity gate.
--
-- For every buildable-grid storage cell on both maps, sample passability at that
-- hex's engine-derived world centre and buildability from the live BuildableGrid.
-- Preserve four dense U8 rasters (bit 0 = passable, bit 1 = buildable):
--
--   __OUT_BASE__-<env>-property-shipped.raw   pipeline result before this probe mutates anything
--   __OUT_BASE__-<env>-property-fresh.raw     stock invalidate + rebuild over final terrain
--   __OUT_BASE__-<env>-property-repeat.raw    a second stock rebuild (idempotence)
--   __OUT_BASE__-<env>-property-restored.raw  after the sensitivity control restores terrain
--
-- The surface additionally receives a deterministic bank of one-height-node
-- perturbations spanning both property-row parities and several neighbouring
-- height-node phases.  Each complete property-cell delta is written to
-- __OUT_BASE__-surface-property-control-<id>.csv.
-- Restoring the saved height grid and reproducing the fresh raster byte-for-byte is
-- the anti-vacuity/cleanup gate. Geometry calibration rows use HexToWorld itself so
-- the offline scorer never needs a scenario-specific grid offset or map constant.
-- Rows 0, 1 and 2 are all emitted because storage rows are staggered by parity; a
-- four-point rows-0/1 calibration can be misread as one globally affine lattice.
--
-- MUTATING, BUT SELF-RESTORING: passability/buildability are rebuilt, one copied
-- surface height node is perturbed, then the exact saved height grid is restored and
-- both property grids are rebuilt again. Run before any other mutating parity probe.
-- Placeholder: __OUT_BASE__.

g_ParityPropertyStatus = "running"
g_ParityPropertyInfo = false
g_ParityPropertyError = false

CreateRealTimeThread(function()
	local restore_map, restore_grid, restore_armed
	local ok, err = xpcall(function()
		local out_base = "__OUT_BASE__"
		local rows, info = {}, {}
		local unb = (type(buildUnbuildableZ) == "function") and buildUnbuildableZ() or (2 ^ 16 - 1)
		local const_tbl = rawget(_G, "const")
		local tile = (type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize)) or 100
		local perturb = math.max(tile * 300, 30000)

		local function emit(s) rows[#rows + 1] = s end
		local function storage_world(sx, sy)
			local q, r = sx - sy / 2, sy
			local wx, wy = HexToWorld(q, r)
			return q, r, wx, wy
		end

		local function write_blob(path, blob)
			local werr = AsyncStringToFile(path, blob)
			if werr then error("write failed " .. path .. ": " .. tostring(werr)) end
		end

		local function byte_diff(a, b)
			if #a ~= #b then return math.max(#a, #b) end
			local n = 0
			for i = 1, #a do if string.byte(a, i) ~= string.byte(b, i) then n = n + 1 end end
			return n
		end

		local function rebuild_stock(map)
			local st = GetPreciseTicks()
			local ok_h, err_h = pcall(terrain.InvalidateHeight, map)
			local ok_t, err_t = pcall(terrain.InvalidateType, map)
			local ok_p, err_p = pcall(terrain.RebuildPassability, map)
			local ok_b, err_b = pcall(RebuildBuildableGrid, map)
			if not (ok_h and ok_t and ok_p and ok_b) then
				error(string.format(
					"stock rebuild failed: height=%s:%s type=%s:%s pass=%s:%s build=%s:%s",
					tostring(ok_h), tostring(err_h), tostring(ok_t), tostring(err_t),
					tostring(ok_p), tostring(err_p), tostring(ok_b), tostring(err_b)))
			end
			return GetPreciseTicks() - st
		end

		local function snapshot(map, env, stage, choose_control)
			local b = map and map.buildable
			local grid = type(b) == "table" and b.z_grid or nil
			if not grid then error(env .. ": buildable grid unavailable") end
			local gw, gh = grid:size()
			local bytes, nearest, nearest_d = {}, {}, {}
			local cx, cy = (gw - 1) / 2, (gh - 1) / 2
			local n_pass, n_build = 0, 0
			for sy = 0, gh - 1 do
				for sx = 0, gw - 1 do
					local q, r, wx, wy = storage_world(sx, sy)
					local pt = point(wx, wy)
					local in_bounds = map:IsPointInBounds(pt)
					local passable = in_bounds and map:IsPassable(pt) or false
					local buildable = grid:get(sx, sy) ~= unb
					local bits = (passable and 1 or 0) + (buildable and 2 or 0)
					bytes[#bytes + 1] = string.char(bits)
					if passable then n_pass = n_pass + 1 end
					if buildable then n_build = n_build + 1 end
					if choose_control and in_bounds and bits == 3 then
						local dx, dy = sx - cx, sy - cy
						local d = dx * dx + dy * dy
						local parity = sy % 2
						if nearest_d[parity] == nil or d < nearest_d[parity] then
							nearest_d[parity] = d
							nearest[parity] = { sx = sx, sy = sy, q = q, r = r, wx = wx, wy = wy }
						end
					end
				end
			end
			local blob = table.concat(bytes)
			write_blob(out_base .. "-" .. env .. "-property-" .. stage .. ".raw", blob)
			emit(string.format("snapshot,%s,%s,cells=%d,passable=%d,buildable=%d,bytes=%d",
				env, stage, gw * gh, n_pass, n_build, #blob))
			return blob, nearest, gw, gh
		end

		local function calibration(map, env, gw, gh)
			local hgw, hgh = terrain.HeightMapSize(map)
			emit(string.format(
				"map,%s,gw=%d,gh=%d,height_gw=%d,height_gh=%d,tile=%d,hex_width=%s,hex_height=%s,"
				.. "pass_border=%s,unbuildable_z=%d,zmul=%s,zdiv=%s,zadd=%s,zones=%s",
				env, gw, gh, hgw, hgh, tile, tostring(map.hex_width), tostring(map.hex_height),
				tostring(map.mapdata and map.mapdata.PassBorder), unb,
				tostring(map.SuperBigMapZScaleMul), tostring(map.SuperBigMapZScaleDiv),
				tostring(map.SuperBigMapZScaleAdd),
				tostring(map.SuperBigMapZCompressionZones and #map.SuperBigMapZCompressionZones or 0)))
			for _, p in ipairs({ {0, 0}, {1, 0}, {0, 1}, {1, 1}, {0, 2}, {1, 2} }) do
				local q, r, wx, wy = storage_world(p[1], p[2])
				emit(string.format("calibration,%s,sx=%d,sy=%d,q=%s,r=%s,wx=%s,wy=%s",
					env, p[1], p[2], tostring(q), tostring(r), tostring(wx), tostring(wy)))
			end
		end

		local maps = {}
		for i = 1, #(Maps or {}) do
			local map = Maps[i]
			local env = map and map.mapdata and map.mapdata.Environment
			if env == "Surface" and not maps.surface then maps.surface = map end
			if env == "Underground" and not maps.underground then maps.underground = map end
		end
		if not maps.surface or not maps.underground then error("surface/underground map pair unavailable") end

		if type(PauseInfiniteLoopDetection) == "function" then
			PauseInfiniteLoopDetection("parity_property")
		end

		local fresh = {}
		for _, env in ipairs({ "surface", "underground" }) do
			local map = maps[env]
			local shipped, _, gw, gh = snapshot(map, env, "shipped", false)
			calibration(map, env, gw, gh)
			local ms1 = rebuild_stock(map)
			local fresh_blob, candidate = snapshot(map, env, "fresh", env == "surface")
			local ms2 = rebuild_stock(map)
			local repeat_blob = snapshot(map, env, "repeat", false)
			fresh[env] = { blob = fresh_blob, candidate = candidate, gw = gw, gh = gh }
			emit(string.format("freshness,%s,shipped_diff=%d,repeat_diff=%d,rebuild1_ms=%d,rebuild2_ms=%d",
				env, byte_diff(shipped, fresh_blob), byte_diff(fresh_blob, repeat_blob), ms1, ms2))
		end

		-- The phase controls below use the retained fresh surface blob.  The node
		-- offsets are data-independent and local; the two sites are selected from
		-- the live grid by row parity and proximity to its centre.
		local surface = maps.surface
		local candidates = fresh.surface.candidate
		if not candidates[0] or not candidates[1] then
			error("surface: no in-bounds passable+buildable control hex for both row parities")
		end
		local original = terrain.GetHeightGrid(surface)
		if not original then error("surface height grid unavailable") end
		local hgw, hgh = original:size()
		local saved = original:new_instance(hgw, hgh)
		if not saved or type(saved.copyrect) ~= "function" then error("height-grid copy unavailable") end
		saved:copyrect(original, box(0, 0, hgw, hgh), point(0, 0))
		restore_map, restore_grid, restore_armed = surface, saved, true
		local changed = saved:new_instance(hgw, hgh)
		if not changed or type(changed.copyrect) ~= "function" then error("height-grid control copy unavailable") end
		local offsets = { {0, 0}, {1, 0}, {0, 1}, {1, 1}, {-1, 0}, {0, -1} }
		local controls, control_id = {}, 0
		for parity = 0, 1 do
			local site = candidates[parity]
			local base_gx = math.floor(site.wx / tile + 0.5)
			local base_gy = math.floor(site.wy / tile + 0.5)
			for _, offset in ipairs(offsets) do
				control_id = control_id + 1
				local gx = math.max(1, math.min(hgw - 2, base_gx + offset[1]))
				local gy = math.max(1, math.min(hgh - 2, base_gy + offset[2]))
				changed:copyrect(saved, box(0, 0, hgw, hgh), point(0, 0))
				local old_h = changed:get(gx, gy)
				local new_h = old_h <= 65534 - perturb and old_h + perturb or math.max(1, old_h - perturb)
				changed:set(gx, gy, new_h)
				local set_err = terrain.SetHeightGrid(surface, changed)
				if set_err then error("control SetHeightGrid failed: " .. tostring(set_err)) end
				local control_ms = rebuild_stock(surface)
				local stage = string.format("control-%02d", control_id)
				local perturbed = snapshot(surface, "surface", stage, false)

				local control_rows = { "sx,sy,dsx,dsy,fresh_bits,control_bits" }
				local control_diff, pass_diff, build_diff = 0, 0, 0
				for i = 1, #fresh.surface.blob do
					local a, b = string.byte(fresh.surface.blob, i), string.byte(perturbed, i)
					if a ~= b then
						local idx = i - 1
						local sy, sx = math.floor(idx / fresh.surface.gw), idx % fresh.surface.gw
						control_diff = control_diff + 1
						if a % 2 ~= b % 2 then pass_diff = pass_diff + 1 end
						if math.floor(a / 2) % 2 ~= math.floor(b / 2) % 2 then build_diff = build_diff + 1 end
						control_rows[#control_rows + 1] = table.concat({ sx, sy, sx - site.sx,
							sy - site.sy, a, b }, ",")
					end
				end
				write_blob(out_base .. "-surface-property-" .. stage .. ".csv",
					table.concat(control_rows, "\n"))
				controls[#controls + 1] = {
					id = control_id, site = site, gx = gx, gy = gy, old_h = old_h, new_h = new_h,
					diff = control_diff, pass_diff = pass_diff, build_diff = build_diff,
					control_ms = control_ms,
				}
			end
		end

		local restore_err = terrain.SetHeightGrid(surface, saved)
		if restore_err then error("restore SetHeightGrid failed: " .. tostring(restore_err)) end
		local restore_ms = rebuild_stock(surface)
		local restored = snapshot(surface, "surface", "restored", false)
		local restore_diff = byte_diff(fresh.surface.blob, restored)
		restore_armed = false
		for _, control in ipairs(controls) do
			local site = control.site
			emit(string.format(
				"control,surface,id=%02d,site_sx=%d,site_sy=%d,site_q=%s,site_r=%s,site_wx=%s,site_wy=%s,"
				.. "node_gx=%d,node_gy=%d,node_wx=%d,node_wy=%d,old_h=%d,new_h=%d,delta_h=%d,"
				.. "diff=%d,pass_diff=%d,build_diff=%d,restore_diff=%d,control_ms=%d,restore_ms=%d",
				control.id, site.sx, site.sy, tostring(site.q), tostring(site.r),
				tostring(site.wx), tostring(site.wy), control.gx, control.gy,
				control.gx * tile, control.gy * tile, control.old_h, control.new_h,
				control.new_h - control.old_h, control.diff, control.pass_diff, control.build_diff,
				restore_diff, control.control_ms, restore_ms))
		end

		if type(changed.free) == "function" then changed:free() end
		if type(saved.free) == "function" then saved:free() end
		if type(original.free) == "function" then original:free() end

		if type(ResumeInfiniteLoopDetection) == "function" then
			ResumeInfiniteLoopDetection("parity_property")
		end

		if restore_diff ~= 0 then error("surface property raster did not restore: diff=" .. restore_diff) end

		local serr = AsyncStringToFile(out_base .. "-property.txt", table.concat(rows, "\n"))
		if serr then error("property stamp write failed: " .. tostring(serr)) end
		info[#info + 1] = string.format("surface=%dx%d underground=%dx%d controls=%d restore=0",
			fresh.surface.gw, fresh.surface.gh, fresh.underground.gw, fresh.underground.gh,
			#controls)
		g_ParityPropertyInfo = table.concat(info, " ")
		g_ParityPropertyStatus = "ready"
	end, debug.traceback)
	if not ok then
		pcall(function()
			if restore_armed and restore_map and restore_grid then
				terrain.SetHeightGrid(restore_map, restore_grid)
				terrain.InvalidateHeight(restore_map)
				terrain.InvalidateType(restore_map)
				terrain.RebuildPassability(restore_map)
				RebuildBuildableGrid(restore_map)
				restore_armed = false
			end
			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_property")
			end
		end)
		g_ParityPropertyError = tostring(err)
		g_ParityPropertyStatus = "error"
	end
end)
return "property_probe_started"

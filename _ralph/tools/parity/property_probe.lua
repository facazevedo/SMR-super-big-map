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

rawset(_G, "g_ParityPropertyStatus", "running")
rawset(_G, "g_ParityPropertyInfo", false)
rawset(_G, "g_ParityPropertyError", false)

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

		-- A single height-node perturbation can change a small, offset footprint in
		-- the property raster.  Keep every possible phase footprint away from a
		-- pre-existing blocked bit so the replay control cannot be clipped.
		local control_radius = 8
		local function positive_mod(value, modulus)
			local remainder = value % modulus
			return remainder < 0 and remainder + modulus or remainder
		end

		local function select_control_pair(by_phase)
			local best
			for _, even_site in pairs(by_phase[0] or {}) do
				for _, odd_site in pairs(by_phase[1] or {}) do
					local phase_dx = math.abs(even_site.phase_x - odd_site.phase_x)
					local phase_dy = math.abs(even_site.phase_y - odd_site.phase_y)
					local phase_distance = phase_dx * phase_dx + phase_dy * phase_dy
					local centre_distance = even_site.centre_d + odd_site.centre_d
					local better = not best
						or phase_distance < best.phase_distance
						or (phase_distance == best.phase_distance and centre_distance < best.centre_distance)
						or (phase_distance == best.phase_distance and centre_distance == best.centre_distance
							and (even_site.sy < best.even.sy
								or (even_site.sy == best.even.sy and even_site.sx < best.even.sx)
								or (even_site.sy == best.even.sy and even_site.sx == best.even.sx
									and (odd_site.sy < best.odd.sy
										or (odd_site.sy == best.odd.sy and odd_site.sx < best.odd.sx)))))
					if better then
						best = {
							even = even_site, odd = odd_site,
							phase_dx = phase_dx, phase_dy = phase_dy,
							phase_distance = phase_distance, centre_distance = centre_distance,
						}
					end
				end
			end
			if not best then
				error("surface: no full-neighborhood control pair for both row parities")
			end
			return { [0] = best.even, [1] = best.odd }, best
		end

		local function snapshot(map, env, stage, choose_control, persist)
			local b = map and map.buildable
			local grid = type(b) == "table" and b.z_grid or nil
			if not grid then error(env .. ": buildable grid unavailable") end
			local gw, gh = grid:size()
			local bytes, by_phase = {}, { [0] = {}, [1] = {} }
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
				end
			end
			local blob = table.concat(bytes)
			if choose_control then
				-- Integral-image bad-bit counts make the full 17x17 neighborhood test
				-- O(1) per candidate instead of scanning a square for every hex.
				local pw, prefix = gw + 1, {}
				local function pidx(x, y) return y * pw + x + 1 end
				-- The inclusion/exclusion sum reads the complete y=0 row for candidates
				-- whose neighborhood reaches the top edge.  Initialize every top-row
				-- prefix coordinate, not only its x=0 corner.
				for sx = 0, gw do prefix[pidx(sx, 0)] = 0 end
				for sy = 0, gh - 1 do
					local row_bad = 0
					prefix[pidx(0, sy + 1)] = prefix[pidx(0, sy)] or 0
					for sx = 0, gw - 1 do
						if string.byte(blob, sy * gw + sx + 1) ~= 3 then row_bad = row_bad + 1 end
						prefix[pidx(sx + 1, sy + 1)] = (prefix[pidx(sx + 1, sy)] or 0) + row_bad
					end
				end
				local function control_neighborhood_clear(sx, sy)
					local x0, y0 = sx - control_radius, sy - control_radius
					local x1, y1 = sx + control_radius + 1, sy + control_radius + 1
					if x0 < 0 or y0 < 0 or x1 > gw or y1 > gh then return false end
					local bad_sum = prefix[pidx(x1, y1)] - prefix[pidx(x0, y1)]
						- prefix[pidx(x1, y0)] + prefix[pidx(x0, y0)]
					return bad_sum == 0
				end
				for sy = 0, gh - 1 do
					for sx = 0, gw - 1 do
						if string.byte(blob, sy * gw + sx + 1) == 3 and control_neighborhood_clear(sx, sy) then
							local dx, dy = sx - cx, sy - cy
							local centre_d, parity = dx * dx + dy * dy, sy % 2
							local q, r, wx, wy = storage_world(sx, sy)
							local phase_x, phase_y = positive_mod(wx, tile), positive_mod(wy, tile)
							local phase_key = tostring(phase_x) .. ":" .. tostring(phase_y)
							local previous = by_phase[parity][phase_key]
							if not previous or centre_d < previous.centre_d
								or (centre_d == previous.centre_d
									and (sy < previous.sy or (sy == previous.sy and sx < previous.sx))) then
								by_phase[parity][phase_key] = {
									sx = sx, sy = sy, q = q, r = r, wx = wx, wy = wy,
									phase_x = phase_x, phase_y = phase_y, centre_d = centre_d,
								}
							end
						end
					end
				end
			end
			local selected, selection
			if choose_control then selected, selection = select_control_pair(by_phase) end
			if persist ~= false then
				write_blob(out_base .. "-" .. env .. "-property-" .. stage .. ".raw", blob)
				emit(string.format("snapshot,%s,%s,cells=%d,passable=%d,buildable=%d,bytes=%d,control_radius=%d",
					env, stage, gw * gh, n_pass, n_build, #blob, control_radius))
			end
			return blob, selected, gw, gh, selection, n_pass, n_build
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
			local fresh_blob, candidate, _, _, selection = snapshot(map, env, "fresh", env == "surface")
			local ms2 = rebuild_stock(map)
			local repeat_blob = snapshot(map, env, "repeat", false)
			fresh[env] = {
				blob = fresh_blob, candidate = candidate, selection = selection, gw = gw, gh = gh,
			}
			emit(string.format("freshness,%s,shipped_diff=%d,repeat_diff=%d,rebuild1_ms=%d,rebuild2_ms=%d",
				env, byte_diff(shipped, fresh_blob), byte_diff(fresh_blob, repeat_blob), ms1, ms2))
		end

		-- The phase controls below use the retained fresh surface blob.  The node
		-- offsets are data-independent and local; the two sites are selected from
		-- the live grid by row parity, sub-tile phase, and proximity to its centre.
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
		local function control_bank(site)
			local bank = {}
			local base_gx = math.floor(site.wx / tile + 0.5)
			local base_gy = math.floor(site.wy / tile + 0.5)
			for offset_id, offset in ipairs(offsets) do
				local gx = math.max(1, math.min(hgw - 2, base_gx + offset[1]))
				local gy = math.max(1, math.min(hgh - 2, base_gy + offset[2]))
				changed:copyrect(saved, box(0, 0, hgw, hgh), point(0, 0))
				local old_h = changed:get(gx, gy)
				local new_h = old_h <= 65534 - perturb and old_h + perturb or math.max(1, old_h - perturb)
				changed:set(gx, gy, new_h)
				local set_err = terrain.SetHeightGrid(surface, changed)
				if set_err then error("control SetHeightGrid failed: " .. tostring(set_err)) end
				local control_ms = rebuild_stock(surface)
				local perturbed, _, _, _, _, n_pass, n_build = snapshot(
					surface, "surface", false, false, false)

				local control_rows, pass_signature, build_signature = {}, {}, {}
				local control_diff, pass_diff, build_diff = 0, 0, 0
				for i = 1, #fresh.surface.blob do
					local a, b = string.byte(fresh.surface.blob, i), string.byte(perturbed, i)
					if a ~= b then
						local idx = i - 1
						local sy, sx = math.floor(idx / fresh.surface.gw), idx % fresh.surface.gw
						control_diff = control_diff + 1
						local pass_changed = a % 2 ~= b % 2
						local build_changed = math.floor(a / 2) % 2 ~= math.floor(b / 2) % 2
						if pass_changed then pass_diff = pass_diff + 1 end
						if build_changed then build_diff = build_diff + 1 end
						local _, _, cell_wx, cell_wy = storage_world(sx, sy)
						local signature = tostring(cell_wx - gx * tile) .. ":" .. tostring(cell_wy - gy * tile)
						if pass_changed then pass_signature[#pass_signature + 1] = signature end
						if build_changed then build_signature[#build_signature + 1] = signature end
						control_rows[#control_rows + 1] = {
							sx = sx, sy = sy, dsx = sx - site.sx, dsy = sy - site.sy,
							fresh_bits = a, control_bits = b,
						}
					end
				end
				table.sort(pass_signature)
				table.sort(build_signature)
				bank[#bank + 1] = {
					offset_id = offset_id, site = site, gx = gx, gy = gy,
					old_h = old_h, new_h = new_h, blob = perturbed, rows = control_rows,
					diff = control_diff, pass_diff = pass_diff, build_diff = build_diff,
					pass_signature = table.concat(pass_signature, "|"),
					build_signature = table.concat(build_signature, "|"),
					control_ms = control_ms, n_pass = n_pass, n_build = n_build,
				}
			end
			return bank
		end

		local function control_banks_compatible(first, second)
			if #first ~= #second or #first ~= #offsets then return false, "bank_size" end
			for i = 1, #first do
				if first[i].pass_signature ~= second[i].pass_signature then
					return false, "passability_offset_" .. tostring(i)
				end
				if first[i].build_signature ~= second[i].build_signature then
					return false, "buildability_offset_" .. tostring(i)
				end
			end
			return true, "exact"
		end

		-- The comparator itself is fail-closed: an otherwise identical synthetic pair
		-- must be accepted and a one-signature passability mismatch must be rejected.
		local synthetic_a, synthetic_b = {}, {}
		for i = 1, #offsets do
			synthetic_a[i] = { pass_signature = "p" .. i, build_signature = "b" .. i }
			synthetic_b[i] = { pass_signature = "p" .. i, build_signature = "b" .. i }
		end
		local synthetic_equal = control_banks_compatible(synthetic_a, synthetic_b)
		synthetic_b[2].pass_signature = "mismatch"
		local synthetic_mismatch = control_banks_compatible(synthetic_a, synthetic_b)
		if not synthetic_equal or synthetic_mismatch then error("control bank comparator self-test failed") end

		local banks = { [0] = control_bank(candidates[0]), [1] = control_bank(candidates[1]) }
		local footprints_exact, mismatch = control_banks_compatible(banks[0], banks[1])
		if not footprints_exact then
			error("surface: selected control bank footprint mismatch: " .. tostring(mismatch))
		end
		local selection = fresh.surface.selection
		emit(string.format(
			"control_bank,surface,mode=phase_nearest_live_footprint_exact_v2,phase_dx=%s,phase_dy=%s,"
			.. "phase_distance=%s,footprints_exact=true",
			tostring(selection.phase_dx), tostring(selection.phase_dy), tostring(selection.phase_distance)))

		local controls, control_id = {}, 0
		for parity = 0, 1 do
			for _, control in ipairs(banks[parity]) do
				control_id = control_id + 1
				local stage = string.format("control-%02d", control_id)
				write_blob(out_base .. "-surface-property-" .. stage .. ".raw", control.blob)
				emit(string.format(
					"snapshot,surface,%s,cells=%d,passable=%d,buildable=%d,bytes=%d,control_radius=%d",
					stage, fresh.surface.gw * fresh.surface.gh, control.n_pass, control.n_build,
					#control.blob, control_radius))
				local csv_rows = { "sx,sy,dsx,dsy,fresh_bits,control_bits" }
				for _, row in ipairs(control.rows) do
					csv_rows[#csv_rows + 1] = table.concat({ row.sx, row.sy, row.dsx, row.dsy,
						row.fresh_bits, row.control_bits }, ",")
				end
				write_blob(out_base .. "-surface-property-" .. stage .. ".csv", table.concat(csv_rows, "\n"))
				control.id = control_id
				controls[#controls + 1] = control
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
				.. "diff=%d,pass_diff=%d,build_diff=%d,restore_diff=%d,control_ms=%d,restore_ms=%d,"
				.. "site_phase_x=%s,site_phase_y=%s,bank_footprints_exact=true",
				control.id, site.sx, site.sy, tostring(site.q), tostring(site.r),
				tostring(site.wx), tostring(site.wy), control.gx, control.gy,
				control.gx * tile, control.gy * tile, control.old_h, control.new_h,
				control.new_h - control.old_h, control.diff, control.pass_diff, control.build_diff,
				restore_diff, control.control_ms, restore_ms,
				tostring(site.phase_x), tostring(site.phase_y)))
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

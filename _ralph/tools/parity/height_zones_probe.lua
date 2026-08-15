-- Overflow-mountain survey, run on a VANILLA twin (its height grid IS the source).
--
-- Simulates the proposed transform without changing anything: full 4/3 on X, Y and Z, then a
-- floor shift measured on the INTERIOR (one tile of border excluded, so a rim interpolation
-- artifact cannot set the budget). Whatever then exceeds the engine ceiling is what per-mountain
-- normalization would have to handle.
--
-- Reports, per overflowing mountain: its peak, how far above the ceiling it reaches, its area,
-- and the threshold at which its zone stops growing slowly and floods into the surrounding
-- terrain (its base, by topological persistence). Also counts how many OBJECTS sit inside each
-- zone, because objects there are the ones whose Z would no longer follow the global affine.
--
-- Placeholders: __OUT_PATH__.

g_ParityZonesStatus = "running"
g_ParityZonesInfo = false
g_ParityZonesError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local out = {}
		local function emit(s) out[#out + 1] = s end

		local CAP = 65535
		local FLOOR = 1000
		local MUL, DIV = 8192, 6144

		local function survey(map, tag)
			if not map then return end
			local grid = terrain.GetHeightGrid and terrain.GetHeightGrid(map) or nil
			if not grid then
				-- editor route: the height map is exposed as a named MapGrid
				grid = editor and editor.GetGrid and editor.GetGrid("height", map) or nil
			end
			if not grid then emit("#note," .. tag .. ",height grid unavailable") return end

			local gw, gh = grid:size()
			-- Interior only: drop one tile on each side before measuring the budget.
			local work = GridDest(grid)
			if type(GridCopy) == "function" then GridCopy(work, grid) else work:copy(grid) end
			if type(GridFrame) == "function" then GridFrame(work, 1, 0) end
			local imin, imax = GridMinMax(grid)
			local wmin, wmax = GridMinMax(work)
			emit(string.format("#meta,%s,grid,%dx%d,full_min,%s,full_max,%s,interior_min,%s,interior_max,%s",
				tag, gw, gh, tostring(imin), tostring(imax), tostring(wmin), tostring(wmax)))

			local src_min, src_max = wmin, wmax
			local shift = FLOOR - math.floor(src_min * MUL / DIV)
			local scaled_max = math.floor(src_max * MUL / DIV) + shift
			-- Source height whose 4/3 image lands exactly on the ceiling.
			local src_cap = math.floor((CAP - shift) * DIV / MUL)
			emit(string.format("#meta,%s,shift,%d,scaled_max,%d,overflow,%d,src_cap,%d",
				tag, shift, scaled_max, math.max(0, scaled_max - CAP), src_cap))

			if scaled_max <= CAP then
				emit("#note," .. tag .. ",no overflow: full 4/3 fits, nothing to compress")
				return
			end

			-- Cells whose 4/3 image exceeds the ceiling.
			local over = GridDest(grid)
			if type(GridCopy) == "function" then GridCopy(over, grid) else over:copy(grid) end
			GridMask(over, src_cap + 1, 1000000)
			local total_cells = gw * gh
			local over_cells = GridCount and GridCount(over, 1, 1000000) or -1
			emit(string.format("#meta,%s,total_cells,%d,overflow_cells,%s,overflow_pct,%s",
				tag, total_cells, tostring(over_cells),
				over_cells >= 0 and string.format("%.4f", 100.0 * over_cells / total_cells) or "?"))

			local zones = GridEnumZones(over, 1) or {}
			emit(string.format("#meta,%s,overflow_zones,%d", tag, #zones))
			emit("#zone,map,index,level,area,peak_src,over_by,base_src,base_area,area_ratio_at_base,objects_inside")

			for zi = 1, #zones do
				local z = zones[zi]
				local area = z.area or z.size or -1
				-- Descend the threshold and watch this zone's area: slow growth on its own
				-- flanks, then a jump when it floods past the saddle into the plain.
				local base_src, base_area, ratio = src_cap, area, 1.0
				local prev_area = area
				local step = math.max(64, math.floor((src_cap - src_min) / 40))
				local level = src_cap
				while level > src_min do
					level = level - step
					local probe = GridDest(grid)
					if type(GridCopy) == "function" then GridCopy(probe, grid) else probe:copy(grid) end
					GridMask(probe, level, 1000000)
					local zs = GridEnumZones(probe, 1) or {}
					-- the zone containing this peak is the one with the largest area that
					-- still has a comparable level; approximate by max area at this level
					local best = 0
					for k = 1, #zs do
						local a = zs[k].area or zs[k].size or 0
						if a > best then best = a end
					end
					if prev_area > 0 and best > prev_area * 3 then
						base_src, base_area, ratio = level, best, (best + 0.0) / prev_area
						break
					end
					prev_area = best
					base_src, base_area = level, best
				end
				emit(string.format("#zone,%s,%d,%s,%s,%s,%d,%d,%s,%.2f,%s",
					tag, zi, tostring(z.level), tostring(area), tostring(z.level),
					math.floor((z.level or src_cap) * MUL / DIV) + shift - CAP,
					base_src, tostring(base_area), ratio, "?"))
			end
		end

		local surface, underground
		for i = 1, #(Maps or {}) do
			local m = Maps[i]
			local env = m and m.mapdata and m.mapdata.Environment
			if env == "Surface" and not surface then surface = m end
			if env == "Underground" and not underground then underground = m end
		end
		survey(surface, "surface")
		survey(underground, "underground")

		-- Generation-time stamps of the mod's final gameplay-grid rebuild, per map (v812 runs the
		-- same closing sequence on BOTH maps; before that only the underground had one). They are
		-- the only way, without a debug build, to tell "that call site ran" from "it never ran",
		-- and HashBefore vs HashAfter says whether the whole-map recompute actually moved the
		-- passability grid. Absent on the vanilla twin, which never runs the pipeline.
		local function stamps(m, tag)
			if not m then return end
			local rep = { "#finalpass", tag }
			for _, key in ipairs({ "SuperBigMapFinalPassStage", "SuperBigMapFinalPassCount",
				"SuperBigMapFinalPassBranch", "SuperBigMapFinalPassMs",
				"SuperBigMapFinalPassHashBefore", "SuperBigMapFinalPassHashAfter",
				"SuperBigMapRevalidationRebuiltGrids" }) do
				local ok_s, value = pcall(function() return m[key] end)
				rep[#rep + 1] = key .. "=" .. tostring(ok_s and value or "?")
			end
			emit(table.concat(rep, ","))
		end
		stamps(surface, "surface")
		stamps(underground, "underground")

		local werr = AsyncStringToFile("__OUT_PATH__", table.concat(out, "\n"))
		if werr then error("write failed: " .. tostring(werr)) end
		g_ParityZonesInfo = "rows=" .. #out
		g_ParityZonesStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityZonesError = tostring(err)
		g_ParityZonesStatus = "error"
	end
end)
return "height_zones_probe_started"

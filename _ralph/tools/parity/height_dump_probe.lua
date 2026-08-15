-- Dump the raw height grids of both maps for offline analysis.
-- The zone/persistence analysis lives in Python where it can be inspected and iterated
-- without a 3-minute game run per attempt. Placeholders: __OUT_BASE__.

g_ParityZonesStatus = "running"
g_ParityZonesInfo = false
g_ParityZonesError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local info = {}
		local function dump(map, tag)
			if not map then return end
			local grid = terrain.GetHeightGrid and terrain.GetHeightGrid(map)
			if not grid then error(tag .. ": height grid unavailable") end
			local gw, gh = grid:size()
			local fmt, bits = IsComputeGrid(grid)
			local path = "__OUT_BASE__-" .. tag .. ".raw"
			local werr
			if fmt == "U" and (bits == 16 or bits == 8) then
				werr = GridSaveRaw(path, grid)
			else
				-- convert to U16 compute grid first
				local cg = GridToCompute and GridToCompute(grid, "U", 16) or nil
				if not cg then error(tag .. ": cannot convert grid " .. tostring(fmt) .. tostring(bits)) end
				werr = GridSaveRaw(path, cg)
				if cg.free then cg:free() end
			end
			if werr then error(tag .. ": GridSaveRaw failed: " .. tostring(werr)) end
			info[#info + 1] = string.format("%s=%dx%d fmt=%s%s", tag, gw, gh,
				tostring(fmt), tostring(bits))
		end
		local surface, underground
		for i = 1, #(Maps or {}) do
			local m = Maps[i]
			local env = m and m.mapdata and m.mapdata.Environment
			if env == "Surface" and not surface then surface = m end
			if env == "Underground" and not underground then underground = m end
		end
		dump(surface, "surface")
		dump(underground, "underground")
		-- The Z transform the mod actually applied, plus the per-massif compression stamp
		-- (`SuperBigMapZCompressionZones`). The offline gate needs these to rebuild the exact
		-- zone masks: a massif's cells are the component of (final >= base_img) holding its peak.
		local rows = {}
		local function stamp(map, tag)
			if not map then return end
			rows[#rows + 1] = string.format(
				"map,%s,zmul=%s,zdiv=%s,zadd=%s,uniform=%s,measured_max=%s,zones=%s",
				tag, tostring(map.SuperBigMapZScaleMul), tostring(map.SuperBigMapZScaleDiv),
				tostring(map.SuperBigMapZScaleAdd), tostring(map.SuperBigMapZScaleUniform),
				tostring(map.SuperBigMapZMeasuredMaxHeight),
				tostring(map.SuperBigMapZCompressionZones and #map.SuperBigMapZCompressionZones or 0))
			local mapdata = map.mapdata
			if type(mapdata) == "table" then
				local function rng(r)
					return (type(r) == "table") and (tostring(r.from) .. ".." .. tostring(r.to)) or "nil"
				end
				rows[#rows + 1] = string.format("ranges,%s,visible=%s,playable=%s", tag,
					rng(mapdata.visible_height_range), rng(mapdata.playable_height_range))
			end
			for i, m in ipairs(map.SuperBigMapZCompressionZones or {}) do
				rows[#rows + 1] = string.format(
					"massif,%s,%d,x0=%d,y0=%d,x1=%d,y1=%d,base=%d,base_img=%d,peak=%d,peak_img=%s,"
					.. "peak_x=%d,peak_y=%d,k=%.12g,cells=%d,band_h=%d,band_t=%d,monotone=%s,escaped=%s",
					tag, i, m.x0, m.y0, m.x1, m.y1, m.base, m.base_img, m.peak,
					tostring(m.peak_img), m.peak_x, m.peak_y, m.k, m.cells, m.band_h, m.band_t,
					tostring(m.monotone), tostring(m.escaped))
			end
		end
		-- Generation-time stamps of the mod's final gameplay-grid rebuild, per map. v812 runs the
		-- same closing sequence on BOTH maps; before it, only the underground had one. These are
		-- the only way, without a debug build, to tell "that call site ran on this map" from "it
		-- never ran", and HashBefore vs HashAfter says whether the whole-map recompute actually
		-- moved the passability grid. Absent on a vanilla twin, which never runs the pipeline.
		-- The row prefix is new: every consumer of this file keys on "map"/"massif" and ignores
		-- anything else.
		local function final_pass_stamp(map, tag)
			if not map then return end
			local rep = { "finalpass", tag }
			for _, key in ipairs({ "SuperBigMapFinalPassStage", "SuperBigMapFinalPassCount",
				"SuperBigMapFinalPassBranch", "SuperBigMapFinalPassMs",
				"SuperBigMapFinalPassHashBefore", "SuperBigMapFinalPassHashAfter",
				"SuperBigMapRevalidationRebuiltGrids" }) do
				local ok_s, value = pcall(function() return map[key] end)
				rep[#rep + 1] = key .. "=" .. tostring(ok_s and value or "?")
			end
			rows[#rows + 1] = table.concat(rep, ",")
		end
		stamp(surface, "surface")
		stamp(underground, "underground")
		final_pass_stamp(surface, "surface")
		final_pass_stamp(underground, "underground")
		local serr = AsyncStringToFile("__OUT_BASE__-zones.txt", table.concat(rows, "\n"))
		if serr then error("zone stamp write failed: " .. tostring(serr)) end
		info[#info + 1] = "stamp_rows=" .. #rows
		g_ParityZonesInfo = table.concat(info, " ")
		g_ParityZonesStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityZonesError = tostring(err)
		g_ParityZonesStatus = "error"
	end
end)
return "height_dump_started"

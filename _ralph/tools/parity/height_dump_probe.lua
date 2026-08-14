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
		g_ParityZonesInfo = table.concat(info, " ")
		g_ParityZonesStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityZonesError = tostring(err)
		g_ParityZonesStatus = "error"
	end
end)
return "height_dump_started"

-- Capture the stock BuildableGrid transaction between InitBuildableGrid and
-- ProcessBuildableGrid. This is a read-only diagnostic: InitBuildableGrid writes only the
-- fresh grid supplied here, while the live shipped BuildableGrid remains untouched.
--
-- The complete raw surface grid is saved as text because NewGrid is not a ComputeGrid and
-- GridSaveRaw rejects it. The stamp also records the six sweep-03 surface-build focus sites
-- that distinguish collision rejection in Init from connected-area classification in Process.
-- Placeholder: __OUT_BASE__.

rawset(_G, "g_ParityBuildInitStatus", "running")
rawset(_G, "g_ParityBuildInitInfo", false)
rawset(_G, "g_ParityBuildInitError", false)

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local rows = {}
		local unbuildable_z = (type(buildUnbuildableZ) == "function")
			and buildUnbuildableZ() or (2 ^ 16 - 1)
		local surface
		for i = 1, #(Maps or {}) do
			local candidate = Maps[i]
			if candidate and candidate.mapdata and candidate.mapdata.Environment == "Surface" then
				surface = candidate
				break
			end
		end
		if not surface then error("surface map unavailable") end
		if type(NewGrid) ~= "function" or type(InitBuildableGrid) ~= "function" then
			error("required buildable APIs unavailable")
		end

		local map_data = surface.mapdata
		local width, height = tonumber(surface.hex_width), tonumber(surface.hex_height)
		if not width or not height or width <= 0 or height <= 0 then
			error("invalid surface hex dimensions")
		end
		local range = map_data.visible_height_range
		local range_from, range_to
		pcall(function()
			range_from = range and tonumber(range.from)
			range_to = range and tonumber(range.to)
		end)
		local raw = NewGrid(width, height, 16, unbuildable_z)
		if not raw then error("raw grid allocation failed") end

		local st = GetPreciseTicks()
		InitBuildableGrid(surface, {
			buildable_grid = raw,
			unbuildable_z = unbuildable_z,
			flat_threshold = g_NCF_FlatThreshold,
			max_surface_height = g_NCF_MaxSurfaceHeight,
			max_surface_error = g_NCF_MaxSurfaceError,
			surface_types = g_NCF_SurfaceTypes,
			enum_flags = g_NCF_EnumFlags,
			ignore_game_flags = g_NCF_IgnoreGameFlags,
			map_border = tonumber(map_data.PassBorder) or 0,
			map_min_height = range_from and range_from * guim or 0,
			map_max_height = range_to and range_to * guim or unbuildable_z,
		})
		local elapsed = GetPreciseTicks() - st

		local text = {
			string.format("#gw=%d,gh=%d,unbuildable_z=%d,init_ms=%d", width, height,
				unbuildable_z, elapsed),
		}
		local row = {}
		local sentinel_count = 0
		for y = 0, height - 1 do
			for x = 0, width - 1 do
				local value = raw:get(x, y)
				row[x + 1] = value
				if value == unbuildable_z then sentinel_count = sentinel_count + 1 end
			end
			text[#text + 1] = table.concat(row, ",", 1, width)
		end
		local grid_path = "__OUT_BASE__-surface-buildinit.txt"
		local write_err = AsyncStringToFile(grid_path, table.concat(text, "\n"))
		if write_err then error("raw grid write failed: " .. tostring(write_err)) end

		local expanded = surface.SuperBigMapExpanded == true
		local sites
		if expanded then
			sites = {
				{ 364, 300, 485, 400 }, { 363, 301, 484, 401 },
				{ 364, 301, 485, 401 }, { 364, 301, 486, 401 },
				{ 367, 298, 489, 397 }, { 368, 298, 490, 397 },
			}
		else
			sites = {
				{ 364, 300, 364, 300 }, { 363, 301, 363, 301 },
				{ 364, 301, 364, 301 }, { 364, 301, 364, 301 },
				{ 367, 298, 367, 298 }, { 368, 298, 368, 298 },
			}
		end
		local shipped = surface.buildable and surface.buildable.z_grid
		rows[#rows + 1] = string.format(
			"map,surface,expanded=%s,gw=%d,gh=%d,pass_border=%s,unbuildable_z=%d,"
				.. "init_ms=%d,sentinel=%d,eligible=%d,write_err=false",
			tostring(expanded), width, height, tostring(map_data.PassBorder), unbuildable_z,
			elapsed, sentinel_count, width * height - sentinel_count)
		for i = 1, #sites do
			local site = sites[i]
			local source_sx, source_sy, sx, sy = site[1], site[2], site[3], site[4]
			local raw_value = raw:get(sx, sy)
			local shipped_value = shipped and shipped:get(sx, sy) or nil
			rows[#rows + 1] = string.format(
				"site,surface,%d,source_sx=%d,source_sy=%d,sx=%d,sy=%d,raw=%s,"
					.. "raw_unbuildable=%s,shipped=%s,shipped_unbuildable=%s",
				i, source_sx, source_sy, sx, sy, tostring(raw_value),
				tostring(raw_value == unbuildable_z), tostring(shipped_value),
				tostring(shipped_value == unbuildable_z))
		end
		local stamp_path = "__OUT_BASE__-buildinit.txt"
		local stamp_err = AsyncStringToFile(stamp_path, table.concat(rows, "\n"))
		if stamp_err then error("stamp write failed: " .. tostring(stamp_err)) end
		raw:free()
		g_ParityBuildInitInfo = string.format(
			"surface=%dx%d init=%dms sentinel=%d sites=%d", width, height, elapsed,
			sentinel_count, #sites)
		g_ParityBuildInitStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityBuildInitError = tostring(err)
		g_ParityBuildInitStatus = "error"
	end
end)
return "buildinit_probe_started"

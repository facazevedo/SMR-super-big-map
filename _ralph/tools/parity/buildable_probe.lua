-- Dump the engine's BUILDABLE grid for both maps (contract step 6's second clause,
-- "rebuild passability AND BUILDABLE from the final grid"), plus the summit reading the
-- per-mountain ceiling normalization makes interesting.
--
-- Why this exists. `Lua/BuildableGrid.lua:23-27` defines the engine's own sentinel
-- `UnbuildableZ = 2^16 - 1 = 65535`, stores the grid as U16, and at `:72` falls back to
-- `map_max_height = UnbuildableZ` whenever the map declares no `visible_height_range` --
-- which every map measured in this workspace does (`ranges,surface,visible=nil` on all 39
-- dumps). This task normalizes each massif so its peak lands on EXACTLY 65,535 world units,
-- i.e. exactly the sentinel value and exactly the fallback height cap, so summit hexes are
-- the one place where the new transform could collide with the engine's encoding. Nothing
-- has ever measured it.
--
-- What is written, per map:
--   <base>-<tag>-buildable.raw          the live z_grid as shipped by the pipeline (U16)
--   <base>-<tag>-buildable-rebuild.raw  a fresh RebuildBuildableGrid over the FINAL terrain
--   rows in <base>-buildable.txt        dims, the sentinel, and one summit row per massif
-- A shipped grid equal to the fresh rebuild is the step-6 evidence: the grid the game plays
-- on was derived from the final terrain and is not stale.
--
-- MUTATING: the rebuild replaces map.buildable's z_grid (the grid saved first is a separate
-- object and stays valid). Nothing else is touched -- no terrain, no passability, no object.
-- Placeholders: __OUT_BASE__, __DISC_R__.

g_ParityBuildStatus = "running"
g_ParityBuildInfo = false
g_ParityBuildError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local rows, info = {}, {}
		local disc_r = __DISC_R__
		local const_tbl = rawget(_G, "const")
		local tile = (type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize)) or 100
		local unb = (type(buildUnbuildableZ) == "function") and buildUnbuildableZ() or (2 ^ 16 - 1)

		local function save(grid, path)
			local fmt, bits = IsComputeGrid(grid)
			if fmt == "U" and (bits == 16 or bits == 8) then
				return tostring(GridSaveRaw(path, grid)), fmt, bits
			end
			local cg = GridToCompute and GridToCompute(grid, "U", 16) or nil
			if not cg then return "convert_failed", fmt, bits end
			local werr = GridSaveRaw(path, cg)
			if cg.free then cg:free() end
			return tostring(werr), fmt, bits
		end

		local function probe_map(map, tag)
			if not map then return end
			local b = map.buildable
			local grid = (type(b) == "table") and b.z_grid or nil
			if not grid then
				rows[#rows + 1] = string.format("buildable,%s,present=false,unbuildable_z=%d", tag, unb)
				info[#info + 1] = tag .. "=absent"
				return
			end
			local gw, gh = grid:size()
			local werr, fmt, bits = save(grid, "__OUT_BASE__-" .. tag .. "-buildable.raw")
			local hgw, hgh = terrain.HeightMapSize(map)
			rows[#rows + 1] = string.format(
				"buildable,%s,present=true,gw=%d,gh=%d,fmt=%s%s,unbuildable_z=%d,hex_width=%s,"
				.. "hex_height=%s,height_gw=%d,height_gh=%d,tile=%d,write_err=%s",
				tag, gw, gh, tostring(fmt), tostring(bits), unb, tostring(map.hex_width),
				tostring(map.hex_height), hgw, hgh, tile, tostring(werr))

			-- One row per compressed massif: the hex holding its peak cell, read off the grid
			-- the game actually plays on, plus the small hex neighbourhood around it.
			local zones = map.SuperBigMapZCompressionZones
			if type(zones) == "table" then
				for i, m in ipairs(zones) do
					local half = math.floor(tile / 2)
					local wx = m.peak_x * tile + half
					local wy = m.peak_y * tile + half
					local pt = point(wx, wy)
					local q, r = WorldToHex(pt)
					local okz, bz = pcall(b.GetZ, b, q, r)
					local okh, h = pcall(map.GetHeight, map, pt)
					local n, sent = 0, 0
					for dq = -disc_r, disc_r do
						for dr = -disc_r, disc_r do
							local okn, nz = pcall(b.GetZ, b, q + dq, r + dr)
							if okn and type(nz) == "number" then
								n = n + 1
								if nz == unb then sent = sent + 1 end
							end
						end
					end
					rows[#rows + 1] = string.format(
						"summit,%s,%d,peak_x=%d,peak_y=%d,peak=%d,peak_img=%s,wx=%d,wy=%d,q=%s,r=%s,"
						.. "build_z=%s,height=%s,sentinel=%s,disc_r=%d,disc_n=%d,disc_sentinel=%d",
						tag, i, m.peak_x, m.peak_y, m.peak, tostring(m.peak_img), wx, wy,
						tostring(q), tostring(r), tostring(okz and bz or "?"),
						tostring(okh and h or "?"),
						tostring(okz and bz == unb), disc_r, n, sent)
				end
			end

			-- Step 6's clause, scored rather than assumed: a fresh rebuild over the final
			-- terrain must reproduce the shipped grid cell for cell.
			local st = GetPreciseTicks()
			RebuildBuildableGrid(map)
			local ms = GetPreciseTicks() - st
			local g2 = (type(map.buildable) == "table") and map.buildable.z_grid or nil
			local werr2 = "no_grid"
			if g2 then werr2 = (save(g2, "__OUT_BASE__-" .. tag .. "-buildable-rebuild.raw")) end
			rows[#rows + 1] = string.format("rebuild,%s,ms=%d,gw=%s,gh=%s,write_err=%s",
				tag, ms, tostring(gw), tostring(gh), tostring(werr2))
			info[#info + 1] = string.format("%s=%dx%d(%dms)", tag, gw, gh, ms)
		end

		local surface, underground
		for i = 1, #(Maps or {}) do
			local m = Maps[i]
			local env = m and m.mapdata and m.mapdata.Environment
			if env == "Surface" and not surface then surface = m end
			if env == "Underground" and not underground then underground = m end
		end
		probe_map(surface, "surface")
		probe_map(underground, "underground")

		local serr = AsyncStringToFile("__OUT_BASE__-buildable.txt", table.concat(rows, "\n"))
		if serr then error("buildable stamp write failed: " .. tostring(serr)) end
		info[#info + 1] = "rows=" .. #rows
		g_ParityBuildInfo = table.concat(info, " ")
		g_ParityBuildStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityBuildError = tostring(err)
		g_ParityBuildStatus = "error"
	end
end)
return "buildable_probe_started"

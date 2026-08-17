-- Determine whether explicit full-map-box invalidation/rebuild creates different
-- terrain.HashPassability state than the stock whole-map/no-box form before the
-- otherwise identical pass-border replay.
--
-- The host binds g_ParityPassHashRebuildFormOut to a fresh artifact path and loads
-- this file only after deterministic generation completes.  This probe is mutating;
-- terminate the game after preserving its output.

rawset(_G, "g_ParityPassHashRebuildFormStatus", "running")
rawset(_G, "g_ParityPassHashRebuildFormError", false)
rawset(_G, "g_ParityPassHashRebuildFormInfo", false)

CreateRealTimeThread(function()
	local paused = false
	local ok, err = xpcall(function()
		local out_path = rawget(_G, "g_ParityPassHashRebuildFormOut")
		if type(out_path) ~= "string" or out_path == "" then
			error("g_ParityPassHashRebuildFormOut is not bound")
		end
		local mod
		for _, candidate in ipairs(ModsLoaded or {}) do
			if candidate.id == "SuperBigMap" then mod = candidate break end
		end
		local sbm = (mod and mod.env and mod.env.SuperBigMap) or rawget(_G, "SuperBigMap")
		local replay = type(sbm) == "table" and sbm.PassBorderReplay or nil
		if type(replay) ~= "table" or type(replay.Derive) ~= "function"
			or type(replay.Apply) ~= "function" then
			error("production pass-border replay is unavailable")
		end
		local replay_derive = replay.Derive
		local replay_apply = replay.Apply
		if type(terrain) ~= "table" or type(terrain.HashPassability) ~= "function"
			or type(terrain.InvalidateHeight) ~= "function"
			or type(terrain.InvalidateType) ~= "function"
			or type(terrain.RebuildPassability) ~= "function"
			or type(terrain.GetPassGridsCount) ~= "function"
			or type(terrain.GetPassGrid) ~= "function" then
			error("required stock passability APIs are unavailable")
		end
		if type(GridWriteStr) ~= "function" or type(xxhash) ~= "function"
			or type(box) ~= "function" then
			error("required grid/box APIs are unavailable")
		end

		local maps = {}
		for i = 1, #(Maps or {}) do
			local map = Maps[i]
			local environment = map and map.mapdata and map.mapdata.Environment
			if environment == "Surface" and not maps.surface then maps.surface = map end
			if environment == "Underground" and not maps.underground then maps.underground = map end
		end
		if not maps.surface or not maps.underground then
			error("surface/underground map pair unavailable")
		end

		if type(PauseInfiniteLoopDetection) == "function" then
			local pause_ok = pcall(PauseInfiniteLoopDetection, "parity_passhash_rebuild_form")
			paused = pause_ok == true
		end

		local rows = { "schema,smr.passhash_rebuild_form.v1" }
		local summaries = {}
		local function capture(map, env, stage, reference)
			local hash_ok, aggregate = pcall(terrain.HashPassability, map)
			if not hash_ok then error(env .. " HashPassability failed: " .. tostring(aggregate)) end
			local count_ok, count = pcall(terrain.GetPassGridsCount, map)
			count = count_ok and tonumber(count) or nil
			if not count or count < 1 or count > 8 then
				error(env .. " invalid pass-grid count " .. tostring(count))
			end
			local blobs = {}
			rows[#rows + 1] = string.format(
				"stage,env=%s,name=%s,aggregate=%s,grid_count=%d",
				env, stage, tostring(aggregate), count)
			for index = 0, count - 1 do
				local grid_ok, grid = pcall(terrain.GetPassGrid, map, index)
				if not grid_ok or not grid or not IsGrid(grid) then
					error(string.format("%s pass grid %d unavailable: %s",
						env, index, tostring(grid)))
				end
				local blob, write_error = GridWriteStr(grid)
				if write_error or type(blob) ~= "string" then
					error(string.format("%s GridWriteStr grid %d failed: %s",
						env, index, tostring(write_error)))
				end
				local width, height = grid:size()
				local prior = reference and reference[index]
				rows[#rows + 1] = string.format(
					"grid,env=%s,stage=%s,index=%d,w=%d,h=%d,bits=%s,bytes=%d,xxhash=%s,matches_reference=%s",
					env, stage, index, width, height or width, tostring(grid:bits()), #blob,
					tostring(xxhash(blob)), prior and tostring(blob == prior) or "na")
				blobs[index] = blob
			end
			return blobs, tostring(aggregate)
		end

		local function rebuild(map, form)
			local mapdata = map and map.mapdata
			local tile = type(const) == "table" and tonumber(const.HeightTileSize) or nil
			local width = type(mapdata) == "table" and tonumber(mapdata.Width) or nil
			local height = type(mapdata) == "table" and tonumber(mapdata.Height) or nil
			if form == "box" then
				if not tile or tile <= 0 or not width or not height then
					error("full-map box dimensions unavailable")
				end
				local area = box(0, 0, width * tile, height * tile)
				terrain.InvalidateHeight(map, area)
				terrain.InvalidateType(map, area)
				terrain.RebuildPassability(map, area)
			else
				terrain.InvalidateHeight(map)
				terrain.InvalidateType(map)
				terrain.RebuildPassability(map)
			end
		end

		for _, env in ipairs({ "surface", "underground" }) do
			local map = maps[env]
			local specs, stats = replay_derive(map)
			if specs == false then error(env .. " replay derive skipped: " .. tostring(stats)) end
			rows[#rows + 1] = string.format(
				"replay,env=%s,version=%s,boxes=%d,orientation=%s",
				env, tostring(stats.version), #specs, tostring(stats.orientation))
			local production, production_hash = capture(map, env, "production", nil)
			local hashes = { production = production_hash }
			for _, form in ipairs({ "map1", "box1", "map2", "box2" }) do
				local base_form = string.sub(form, 1, 3) == "map" and "map" or "box"
				rebuild(map, base_form)
				local _, baseline_hash = capture(map, env, form .. "_baseline", nil)
				local apply_ok, applied, count = pcall(replay_apply, map,
					"diagnostic rebuild form " .. form)
				if not apply_ok or applied ~= true then
					error(env .. " " .. form .. " replay failed: " .. tostring(applied))
				end
				local _, replay_hash = capture(map, env, form .. "_replay", production)
				rows[#rows + 1] = string.format(
					"result,env=%s,form=%s,count=%s,baseline_hash=%s,replay_hash=%s,matches_production_hash=%s",
					env, form, tostring(count), baseline_hash, replay_hash,
					tostring(replay_hash == production_hash))
				hashes[form] = replay_hash
			end
			rows[#rows + 1] = string.format(
				"summary,env=%s,production=%s,map1=%s,box1=%s,map2=%s,box2=%s,map_stable=%s,box_stable=%s,forms_differ=%s",
				env, hashes.production, hashes.map1, hashes.box1, hashes.map2, hashes.box2,
				tostring(hashes.map1 == hashes.map2), tostring(hashes.box1 == hashes.box2),
				tostring(hashes.map1 ~= hashes.box1))
			summaries[#summaries + 1] = string.format("%s:p%s:m%s:b%s",
				env, hashes.production, hashes.map1, hashes.box1)
		end

		local write_error = AsyncStringToFile(out_path, table.concat(rows, "\n") .. "\n")
		if write_error then error("write failed " .. out_path .. ": " .. tostring(write_error)) end
		rawset(_G, "g_ParityPassHashRebuildFormInfo", table.concat(summaries, " "))
		rawset(_G, "g_ParityPassHashRebuildFormStatus", "complete")
	end, debug.traceback)
	if paused and type(ResumeInfiniteLoopDetection) == "function" then
		pcall(ResumeInfiniteLoopDetection, "parity_passhash_rebuild_form")
	end
	if not ok then
		rawset(_G, "g_ParityPassHashRebuildFormError", tostring(err))
		rawset(_G, "g_ParityPassHashRebuildFormStatus", "error")
	end
end)

return "passhash_rebuild_form_probe_started"

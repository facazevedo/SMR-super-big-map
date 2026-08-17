-- Diagnose whether repeating the exact production pass-border replay changes only
-- terrain.HashPassability history while leaving every exposed native pass grid unchanged.
--
-- The host binds g_ParityPassHashNoopOut to a fresh artifact path, then loads this
-- file only after deterministic generation is complete.  This is intentionally
-- mutating diagnostic code: it repeats the shipped replay twice and the game is
-- terminated after capture.

rawset(_G, "g_ParityPassHashNoopStatus", "running")
rawset(_G, "g_ParityPassHashNoopError", false)
rawset(_G, "g_ParityPassHashNoopInfo", false)

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local out_path = rawget(_G, "g_ParityPassHashNoopOut")
		if type(out_path) ~= "string" or out_path == "" then
			error("g_ParityPassHashNoopOut is not bound")
		end
		local sbm = rawget(_G, "SuperBigMap")
		local replay = type(sbm) == "table" and sbm.PassBorderReplay or nil
		if type(replay) ~= "table" or type(replay.Derive) ~= "function"
			or type(replay.Apply) ~= "function" then
			error("production pass-border replay is unavailable")
		end
		if type(terrain) ~= "table" or type(terrain.HashPassability) ~= "function"
			or type(terrain.GetPassGridsCount) ~= "function"
			or type(terrain.GetPassGrid) ~= "function" then
			error("required stock passability APIs are unavailable")
		end
		if type(GridWriteStr) ~= "function" or type(xxhash) ~= "function" then
			error("required pass-grid serialization APIs are unavailable")
		end

		local rows = { "schema,smr.passhash_noop.v1" }
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

		local function capture(map, env, stage, baseline)
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
				local repeat_blob, repeat_error = GridWriteStr(grid)
				if repeat_error or type(repeat_blob) ~= "string" then
					error(string.format("%s repeated GridWriteStr grid %d failed: %s",
						env, index, tostring(repeat_error)))
				end
				local width, height = grid:size()
				local prior = baseline and baseline[index]
				rows[#rows + 1] = string.format(
					"grid,env=%s,stage=%s,index=%d,w=%d,h=%d,bits=%s,bytes=%d,xxhash=%s,repeat_equal=%s,matches_before=%s",
					env, stage, index, width, height or width, tostring(grid:bits()), #blob,
					tostring(xxhash(blob)), tostring(blob == repeat_blob),
					prior and tostring(blob == prior) or "na")
				blobs[index] = blob
			end
			return blobs, tostring(aggregate)
		end

		local summaries = {}
		for _, env in ipairs({ "surface", "underground" }) do
			local map = maps[env]
			local specs, stats = replay.Derive(map)
			if specs == false then error(env .. " replay derive skipped: " .. tostring(stats)) end
			rows[#rows + 1] = string.format(
				"replay,env=%s,version=%s,boxes=%d,orientation=%s,apply_count_before=%s,stage_before=%s",
				env, tostring(stats.version), #specs, tostring(stats.orientation),
				tostring(map.SuperBigMapPassBorderReplayApplyCount),
				tostring(map.SuperBigMapPassBorderReplayStage))
			for i = 1, #specs do
				local spec = specs[i]
				rows[#rows + 1] = string.format(
					"spec,env=%s,id=%d,minx=%d,miny=%d,maxx=%d,maxy=%d,kind=%s",
					env, i, spec[1], spec[2], spec[3], spec[4], tostring(spec.kind))
			end

			local before, hash_before = capture(map, env, "before", nil)
			local apply1_ok, applied1, count1 = pcall(replay.Apply, map, "diagnostic no-op repeat 1")
			if not apply1_ok or applied1 ~= true then
				error(env .. " first repeat failed: " .. tostring(applied1))
			end
			local _, hash_after1 = capture(map, env, "after1", before)
			local apply2_ok, applied2, count2 = pcall(replay.Apply, map, "diagnostic no-op repeat 2")
			if not apply2_ok or applied2 ~= true then
				error(env .. " second repeat failed: " .. tostring(applied2))
			end
			local _, hash_after2 = capture(map, env, "after2", before)
			rows[#rows + 1] = string.format(
				"result,env=%s,count1=%s,count2=%s,hash_before=%s,hash_after1=%s,hash_after2=%s,changed_after1=%s,stable_after2=%s",
				env, tostring(count1), tostring(count2), hash_before, hash_after1, hash_after2,
				tostring(hash_after1 ~= hash_before), tostring(hash_after2 == hash_after1))
			summaries[#summaries + 1] = string.format(
				"%s:%s>%s>%s", env, hash_before, hash_after1, hash_after2)
		end

		local write_error = AsyncStringToFile(out_path, table.concat(rows, "\n") .. "\n")
		if write_error then error("write failed " .. out_path .. ": " .. tostring(write_error)) end
		rawset(_G, "g_ParityPassHashNoopInfo", table.concat(summaries, " "))
		rawset(_G, "g_ParityPassHashNoopStatus", "complete")
	end, debug.traceback)
	if not ok then
		rawset(_G, "g_ParityPassHashNoopError", tostring(err))
		rawset(_G, "g_ParityPassHashNoopStatus", "error")
	end
end)

return "passhash_noop_probe_started"

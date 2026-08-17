-- Narrow discriminator for passability aggregate-hash history.
--
-- Load this at the main menu before deterministic generation.  The host must first bind
-- `g_ParityPassHashHistoryOut` to an artifact path.  The wrapper observes only the
-- RebuildBuildableGrid call immediately following each SuperBigMap.GenerationGrids.RebuildFinal
-- pass-border replay.  It records terrain.HashPassability and both serialized exposed pass grids
-- before and after that call, then offers a read-only terminal snapshot for the host to invoke
-- once generation is complete.

local out_path = rawget(_G, "g_ParityPassHashHistoryOut")
if type(out_path) ~= "string" or out_path == "" then
	error("g_ParityPassHashHistoryOut must name the artifact output")
end
if rawget(_G, "g_ParityPassHashHistoryOriginal") then
	error("pass-hash history probe is already installed")
end
if type(RebuildBuildableGrid) ~= "function" then
	error("RebuildBuildableGrid is unavailable")
end
if type(terrain) ~= "table"
	or type(terrain.HashPassability) ~= "function"
	or type(terrain.GetPassGridsCount) ~= "function"
	or type(terrain.GetPassGrid) ~= "function"
	or type(GridWriteStr) ~= "function"
	or type(xxhash) ~= "function" then
	error("required passability inspection APIs are unavailable")
end

local original = RebuildBuildableGrid
local seen_count = setmetatable({}, { __mode = "k" })
local rows = { "schema,smr.passhash_history.v1" }
local sequence = 0

local function env_name(map)
	local value = map and map.mapdata and map.mapdata.Environment
	return type(value) == "string" and string.lower(value) or "unknown"
end

local function pass_hash(map)
	local ok, value = pcall(terrain.HashPassability, map)
	if not ok then error("HashPassability failed: " .. tostring(value)) end
	return tostring(value)
end

local function pass_grids(map)
	local ok_n, count = pcall(terrain.GetPassGridsCount, map)
	count = ok_n and tonumber(count) or nil
	if not count or count < 1 or count > 8 then
		error("invalid pass-grid count " .. tostring(count))
	end
	local result = { count = count, blobs = {}, hashes = {} }
	for idx = 0, count - 1 do
		local ok_g, grid = pcall(terrain.GetPassGrid, map, idx)
		if not ok_g or not grid or not IsGrid(grid) then
			error("pass grid unavailable at index " .. tostring(idx))
		end
		local blob, write_error = GridWriteStr(grid)
		if write_error or type(blob) ~= "string" then
			error("GridWriteStr failed at index " .. tostring(idx) .. ": " .. tostring(write_error))
		end
		result.blobs[idx] = blob
		result.hashes[idx] = tostring(xxhash(blob))
	end
	return result
end

local function flush()
	local write_error = AsyncStringToFile(out_path, table.concat(rows, "\n") .. "\n")
	if write_error then error("history output write failed: " .. tostring(write_error)) end
end

local function capture(map)
	return { hash = pass_hash(map), grids = pass_grids(map) }
end

local function grid_fields(prefix, state)
	local parts = { prefix .. "_grid_count=" .. tostring(state.grids.count) }
	for idx = 0, state.grids.count - 1 do
		parts[#parts + 1] = string.format("%s_grid%d_xxhash=%s",
			prefix, idx, tostring(state.grids.hashes[idx]))
	end
	return parts
end

local function record_transition(map, before, after)
	sequence = sequence + 1
	local fields = {
		"transition",
		"seq=" .. tostring(sequence),
		"env=" .. env_name(map),
		"final_count=" .. tostring(map.SuperBigMapFinalPassCount),
		"final_stage=" .. tostring(map.SuperBigMapFinalPassStage),
		"replay_count=" .. tostring(map.SuperBigMapPassBorderReplayApplyCount),
		"replay_stage=" .. tostring(map.SuperBigMapPassBorderReplayStage),
		"stored_before=" .. tostring(map.SuperBigMapFinalPassHashBefore),
		"stored_after_replay=" .. tostring(map.SuperBigMapFinalPassHashAfter),
		"before_buildable=" .. before.hash,
		"after_buildable=" .. after.hash,
	}
	for _, value in ipairs(grid_fields("before", before)) do fields[#fields + 1] = value end
	for _, value in ipairs(grid_fields("after", after)) do fields[#fields + 1] = value end
	local same = before.grids.count == after.grids.count
	if same then
		for idx = 0, before.grids.count - 1 do
			if before.grids.blobs[idx] ~= after.grids.blobs[idx] then same = false break end
		end
	end
	fields[#fields + 1] = "serialized_grids_equal=" .. tostring(same)
	rows[#rows + 1] = table.concat(fields, ",")
	flush()
end

function g_ParityPassHashHistorySnapshot()
	for _, map in ipairs(Maps or empty_table) do
		local env = env_name(map)
		if env == "surface" or env == "underground" then
			local current = capture(map)
			local fields = {
				"snapshot",
				"env=" .. env,
				"final_count=" .. tostring(map.SuperBigMapFinalPassCount),
				"final_stage=" .. tostring(map.SuperBigMapFinalPassStage),
				"replay_count=" .. tostring(map.SuperBigMapPassBorderReplayApplyCount),
				"replay_stage=" .. tostring(map.SuperBigMapPassBorderReplayStage),
				"stored_before=" .. tostring(map.SuperBigMapFinalPassHashBefore),
				"stored_after_replay=" .. tostring(map.SuperBigMapFinalPassHashAfter),
				"current=" .. current.hash,
			}
			for _, value in ipairs(grid_fields("current", current)) do fields[#fields + 1] = value end
			rows[#rows + 1] = table.concat(fields, ",")
		end
	end
	flush()
	return string.format("events=%d rows=%d out=%s", sequence, #rows, out_path)
end

function g_ParityPassHashHistoryRestore()
	if rawget(_G, "g_ParityPassHashHistoryOriginal") then
		RebuildBuildableGrid = g_ParityPassHashHistoryOriginal
		g_ParityPassHashHistoryOriginal = nil
	end
	return true
end

g_ParityPassHashHistoryOriginal = original
RebuildBuildableGrid = function(map, ...)
	local count = map and tonumber(map.SuperBigMapFinalPassCount)
	local observe = count and count > (seen_count[map] or 0)
	local before = observe and capture(map) or false
	local r1, r2, r3, r4, r5, r6 = original(map, ...)
	if observe then
		seen_count[map] = count
		record_transition(map, before, capture(map))
	end
	return r1, r2, r3, r4, r5, r6
end

rawset(_G, "g_ParityPassHashHistoryStatus", "armed")
flush()
return "passhash_history_probe_armed"

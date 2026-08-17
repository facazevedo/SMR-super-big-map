-- Determine whether the first scheduler dispatch after the surface production
-- RebuildFinal call is already late enough to canonicalize terrain.HashPassability.
--
-- Load this at the main menu before deterministic generation. The host must first bind
-- g_ParityPassHashDelayedOut to a fresh artifact path. The wrapper observes the first
-- surface production call, restores itself, and schedules exactly one revalidation in a
-- new real-time thread. That thread's entry snapshot is the first probe code to execute
-- after the production thread yields or exits.

local out_path = rawget(_G, "g_ParityPassHashDelayedOut")
if type(out_path) ~= "string" or out_path == "" then
	error("g_ParityPassHashDelayedOut must name the artifact output")
end
if rawget(_G, "g_ParityPassHashDelayedOriginal") then
	error("delayed-revalidation probe is already installed")
end

local mod
for _, candidate in ipairs(ModsLoaded or {}) do
	if candidate.id == "SuperBigMap" then mod = candidate break end
end
local sbm = (mod and mod.env and mod.env.SuperBigMap) or rawget(_G, "SuperBigMap")
local grids = type(sbm) == "table" and sbm.GenerationGrids or nil
local create_thread = rawget(_G, "CreateRealTimeThread")
if type(grids) ~= "table" or type(grids.RebuildFinal) ~= "function" then
	error("production RebuildFinal is unavailable")
end
if type(create_thread) ~= "function" then
	error("CreateRealTimeThread is unavailable")
end
if type(terrain) ~= "table" or type(terrain.HashPassability) ~= "function"
	or type(terrain.GetPassGridsCount) ~= "function"
	or type(terrain.GetPassGrid) ~= "function"
	or type(GridWriteStr) ~= "function" or type(xxhash) ~= "function" then
	error("required passability inspection APIs are unavailable")
end

local original = grids.RebuildFinal
local unpack_values = table.unpack or unpack
local rows = { "schema,smr.passhash_delayed_revalidation.v1" }
local ran = false

local function flush()
	local write_error = AsyncStringToFile(out_path, table.concat(rows, "\n") .. "\n")
	if write_error then error("delayed output write failed: " .. tostring(write_error)) end
end

local function env_name(map)
	local value = map and map.mapdata and map.mapdata.Environment
	return type(value) == "string" and string.lower(value) or "unknown"
end

local function suspension_state(map)
	local reasons = {}
	for reason in pairs((map and map.SuspendPassEditsReasons) or {}) do
		reasons[#reasons + 1] = tostring(reason)
	end
	table.sort(reasons)
	local suspended = false
	if map and type(map.IsPassEditSuspended) == "function" then
		local ok, value = pcall(map.IsPassEditSuspended, map)
		suspended = ok and value == true
	end
	return suspended, #reasons, table.concat(reasons, "|")
end

local function capture(map)
	local hash_ok, aggregate = pcall(terrain.HashPassability, map)
	if not hash_ok then error("HashPassability failed: " .. tostring(aggregate)) end
	local count_ok, count = pcall(terrain.GetPassGridsCount, map)
	count = count_ok and tonumber(count) or nil
	if not count or count < 1 or count > 8 then
		error("invalid pass-grid count " .. tostring(count))
	end
	local state = { aggregate = tostring(aggregate), count = count, blobs = {}, hashes = {} }
	for index = 0, count - 1 do
		local grid_ok, grid = pcall(terrain.GetPassGrid, map, index)
		if not grid_ok or not grid or not IsGrid(grid) then
			error("pass grid unavailable at index " .. tostring(index))
		end
		local blob, write_error = GridWriteStr(grid)
		if write_error or type(blob) ~= "string" then
			error("GridWriteStr failed at index " .. tostring(index)
				.. ": " .. tostring(write_error))
		end
		state.blobs[index] = blob
		state.hashes[index] = tostring(xxhash(blob))
	end
	return state
end

local function same_grids(a, b)
	if a.count ~= b.count then return false end
	for index = 0, a.count - 1 do
		if a.blobs[index] ~= b.blobs[index] then return false end
	end
	return true
end

local function record(stage, map, state)
	local suspended, reason_count, reasons = suspension_state(map)
	local fields = {
		"stage",
		"name=" .. stage,
		"env=" .. env_name(map),
		"aggregate=" .. state.aggregate,
		"grid_count=" .. tostring(state.count),
		"pass_suspended=" .. tostring(suspended),
		"reason_count=" .. tostring(reason_count),
		"reasons=" .. reasons,
		"map_slot=" .. tostring(map and map.slot),
		"current_slot=" .. tostring(CurrentMap and CurrentMap.slot),
		"game_time=" .. tostring(type(GameTime) == "function" and GameTime() or "na"),
		"real_time=" .. tostring(type(RealTime) == "function" and RealTime() or "na"),
		"parity_status=" .. tostring(rawget(_G, "g_ParityStatus")),
		"surface_done=" .. tostring(map and map.SuperBigMapSurfaceStretchDone),
		"expanded=" .. tostring(map and map.SuperBigMapExpanded),
		"pipeline_pending=" .. tostring(map and map.SuperBigMapStretchPipelinePending),
		"surface_scheduled=" .. tostring(map and map.SuperBigMapSurfaceStretchScheduled),
		"final_count=" .. tostring(map and map.SuperBigMapFinalPassCount),
		"final_stage=" .. tostring(map and map.SuperBigMapFinalPassStage),
		"stored_before=" .. tostring(map and map.SuperBigMapFinalPassHashBefore),
		"stored_after=" .. tostring(map and map.SuperBigMapFinalPassHashAfter),
		"replay_count=" .. tostring(map and map.SuperBigMapPassBorderReplayApplyCount),
	}
	for index = 0, state.count - 1 do
		fields[#fields + 1] = string.format("grid%d_xxhash=%s", index, state.hashes[index])
	end
	rows[#rows + 1] = table.concat(fields, ",")
	flush()
end

rawset(_G, "g_ParityPassHashDelayedOriginal", original)
rawset(_G, "g_ParityPassHashDelayedStatus", "armed")
rawset(_G, "g_ParityPassHashDelayedError", false)
flush()

grids.RebuildFinal = function(map, stage, ...)
	if ran or env_name(map) ~= "surface" then
		return original(map, stage, ...)
	end
	ran = true
	local args = { ... }
	local ok, payload = xpcall(function()
		local production_returns = { original(map, stage, unpack_values(args)) }
		local production = capture(map)
		record("after_production", map, production)

		-- Restore before scheduling so the delayed call reaches the production function
		-- directly and any unrelated later map work cannot re-enter this wrapper.
		grids.RebuildFinal = original
		rawset(_G, "g_ParityPassHashDelayedOriginal", nil)
		rawset(_G, "g_ParityPassHashDelayedStatus", "scheduled")
		local schedule_ok, schedule_error = pcall(create_thread, function()
			local paused = false
			local delayed_ok, delayed_err = xpcall(function()
				if type(PauseInfiniteLoopDetection) == "function" then
					paused = pcall(PauseInfiniteLoopDetection,
						"parity_passhash_delayed_revalidation") == true
				end
				local entry = capture(map)
				record("scheduled_entry", map, entry)
				local delayed_returns = {
					original(map, "diagnostic first scheduled revalidation")
				}
				local delayed = capture(map)
				record("after_delayed", map, delayed)
				rows[#rows + 1] = table.concat({
					"summary",
					"production=" .. production.aggregate,
					"entry=" .. entry.aggregate,
					"delayed=" .. delayed.aggregate,
					"changed_before_probe=" .. tostring(production.aggregate ~= entry.aggregate),
					"changed_by_delayed=" .. tostring(entry.aggregate ~= delayed.aggregate),
					"production_entry_grids_equal=" .. tostring(same_grids(production, entry)),
					"entry_delayed_grids_equal=" .. tostring(same_grids(entry, delayed)),
					"production_return=" .. tostring(production_returns[1]),
					"delayed_return=" .. tostring(delayed_returns[1]),
				}, ",")
				flush()
				rawset(_G, "g_ParityPassHashDelayedStatus", "complete")
			end, debug.traceback)
			if paused and type(ResumeInfiniteLoopDetection) == "function" then
				pcall(ResumeInfiniteLoopDetection, "parity_passhash_delayed_revalidation")
			end
			if not delayed_ok then
				rawset(_G, "g_ParityPassHashDelayedError", tostring(delayed_err))
				rawset(_G, "g_ParityPassHashDelayedStatus", "error")
			end
		end)
		if not schedule_ok then
			error("delayed revalidation thread scheduling failed: " .. tostring(schedule_error))
		end
		return production_returns
	end, debug.traceback)
	grids.RebuildFinal = original
	rawset(_G, "g_ParityPassHashDelayedOriginal", nil)
	if not ok then
		rawset(_G, "g_ParityPassHashDelayedError", tostring(payload))
		rawset(_G, "g_ParityPassHashDelayedStatus", "error")
		error(payload)
	end
	return unpack_values(payload)
end

return "passhash_delayed_revalidation_probe_armed"

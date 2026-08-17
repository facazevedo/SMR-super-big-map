-- Determine whether the surface aggregate mismatch needs a terminal/post-generation
-- timing boundary, or whether immediately repeating the exact production final
-- revalidation canonicalizes terrain.HashPassability before the surface pipeline yields.
--
-- Load this at the main menu before deterministic generation.  The host must first bind
-- g_ParityPassHashImmediateOut to a fresh artifact path.  The wrapper mutates only the
-- first surface RebuildFinal call by immediately repeating that same production function;
-- it restores the original function before returning.

local out_path = rawget(_G, "g_ParityPassHashImmediateOut")
if type(out_path) ~= "string" or out_path == "" then
	error("g_ParityPassHashImmediateOut must name the artifact output")
end
if rawget(_G, "g_ParityPassHashImmediateOriginal") then
	error("immediate-revalidation probe is already installed")
end

local mod
for _, candidate in ipairs(ModsLoaded or {}) do
	if candidate.id == "SuperBigMap" then mod = candidate break end
end
local sbm = (mod and mod.env and mod.env.SuperBigMap) or rawget(_G, "SuperBigMap")
local grids = type(sbm) == "table" and sbm.GenerationGrids or nil
if type(grids) ~= "table" or type(grids.RebuildFinal) ~= "function" then
	error("production RebuildFinal is unavailable")
end
if type(terrain) ~= "table" or type(terrain.HashPassability) ~= "function"
	or type(terrain.GetPassGridsCount) ~= "function"
	or type(terrain.GetPassGrid) ~= "function"
	or type(GridWriteStr) ~= "function" or type(xxhash) ~= "function" then
	error("required passability inspection APIs are unavailable")
end

local original = grids.RebuildFinal
local unpack_values = table.unpack or unpack
local rows = { "schema,smr.passhash_immediate_revalidation.v1" }
local ran = false

local function flush()
	local write_error = AsyncStringToFile(out_path, table.concat(rows, "\n") .. "\n")
	if write_error then error("immediate output write failed: " .. tostring(write_error)) end
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

rawset(_G, "g_ParityPassHashImmediateOriginal", original)
rawset(_G, "g_ParityPassHashImmediateStatus", "armed")
rawset(_G, "g_ParityPassHashImmediateError", false)
flush()

grids.RebuildFinal = function(map, stage, ...)
	if ran or env_name(map) ~= "surface" then
		return original(map, stage, ...)
	end
	ran = true
	local args = { ... }
	local ok, payload = xpcall(function()
		local before = capture(map)
		record("before_first", map, before)
		local first_returns = { original(map, stage, unpack_values(args)) }
		local first = capture(map)
		record("after_first", map, first)
		local second_returns = { original(map, "diagnostic immediate revalidation") }
		local second = capture(map)
		record("after_second", map, second)
		rows[#rows + 1] = table.concat({
			"summary",
			"first=" .. first.aggregate,
			"second=" .. second.aggregate,
			"aggregate_equal=" .. tostring(first.aggregate == second.aggregate),
			"serialized_grids_equal=" .. tostring(same_grids(first, second)),
			"first_return=" .. tostring(first_returns[1]),
			"second_return=" .. tostring(second_returns[1]),
		}, ",")
		flush()
		return first_returns
	end, debug.traceback)
	grids.RebuildFinal = original
	rawset(_G, "g_ParityPassHashImmediateOriginal", nil)
	if not ok then
		rawset(_G, "g_ParityPassHashImmediateError", tostring(payload))
		rawset(_G, "g_ParityPassHashImmediateStatus", "error")
		error(payload)
	end
	rawset(_G, "g_ParityPassHashImmediateStatus", "complete")
	return unpack_values(payload)
end

return "passhash_immediate_revalidation_probe_armed"

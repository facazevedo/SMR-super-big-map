-- Fail-closed staged capture producer for the 42S85E determinism cohort.
--
-- Load through `smr run-file` after NewGame setup and before GenerateCurrentRandomMap. The host
-- must set g_FzpDeterminismCaptureOutBase to a fresh per-run path. Production calls four dormant
-- observer boundaries; this producer writes every artifact required by
-- determinism_capture_protocol_check.py. After generation and underground preparation complete,
-- invoke g_FzpDeterminismCaptureFinalize() once through the harness and poll the status globals.

local out_base = rawget(_G, "g_FzpDeterminismCaptureOutBase")
if type(out_base) ~= "string" or out_base == "" then
	error("g_FzpDeterminismCaptureOutBase must be a non-empty fresh per-run path")
end

local mod
for _, candidate in ipairs(ModsLoaded or empty_table) do
	if candidate and candidate.id == "SuperBigMap" then mod = candidate break end
end
local SBM = (mod and type(mod.env) == "table" and mod.env.SuperBigMap)
	or rawget(_G, "SuperBigMap")
local generation = type(SBM) == "table" and SBM.MapGeneration or nil
if type(generation) ~= "table"
	or type(generation.SetDeterminismCaptureHookForTest) ~= "function" then
	error("SuperBigMap determinism capture seam is unavailable")
end

for _, name in ipairs({
	"AsyncStringToFile", "GridSaveRaw", "GridWriteStr", "NewGrid",
	"InitBuildableGrid", "ProcessBuildableGrid",
}) do
	if type(rawget(_G, name)) ~= "function" then error(name .. " is unavailable") end
end
if type(terrain) ~= "table" or type(terrain.GetHeightGrid) ~= "function"
	or type(terrain.GetTypeGrid) ~= "function"
	or type(terrain.GetPassGridsCount) ~= "function"
	or type(terrain.GetPassGrid) ~= "function" then
	error("required terrain capture APIs are unavailable")
end

rawset(_G, "g_FzpDeterminismCaptureStatus", "armed")
rawset(_G, "g_FzpDeterminismCaptureError", false)
rawset(_G, "g_FzpDeterminismCaptureFinalized", false)

local required = {
	pre_stock_generation = { "rng_state", "prefab_order", "generation_inputs" },
	stock_surface_output = { "surface_height", "surface_terrain", "object_census" },
	pre_z_transform = { "surface_height", "surface_terrain", "object_census" },
	post_z_transform = { "surface_height", "surface_terrain", "zone_stamp" },
	post_object_transform = { "object_census", "collision_census" },
	pre_init_buildable = {
		"surface_height", "surface_terrain", "passability", "buildable", "collision_census",
	},
	post_init_buildable = {
		"surface_height", "surface_terrain", "passability", "buildable", "collision_census",
	},
	post_process_buildable = {
		"surface_height", "surface_terrain", "passability", "buildable", "collision_census",
	},
	final_stable = {
		"surface_height", "underground_height", "surface_passability", "surface_buildable",
		"underground_passability", "underground_buildable", "object_census",
	},
}
rawset(_G, "g_FzpDeterminismCaptureRequiredArtifacts", required)

local artifacts = {}
for stage, names in pairs(required) do
	artifacts[stage] = {}
	for _, name in ipairs(names) do
		local extension = (string.find(name, "height", 1, true)
			or string.find(name, "terrain", 1, true)) and ".raw" or ".bin"
		artifacts[stage][name] = out_base .. "-" .. stage .. "-" .. name .. extension
	end
end
rawset(_G, "g_FzpDeterminismCaptureArtifacts", artifacts)

local function write(path, value)
	local err = AsyncStringToFile(path, value)
	if err then error("write failed " .. path .. ": " .. tostring(err)) end
end

local function save_grid(path, grid)
	if not grid then error("missing grid for " .. path) end
	local ok, err = pcall(GridSaveRaw, path, grid)
	if not ok or err then error("GridSaveRaw failed " .. path .. ": " .. tostring(err)) end
end

local function scalar(value)
	if value == nil then return "nil" end
	if type(value) == "boolean" or type(value) == "number" then return tostring(value) end
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return "<" .. type(value) .. ">"
end

local function canonical(value, seen, depth)
	local kind = type(value)
	if kind ~= "table" then return scalar(value) end
	seen, depth = seen or {}, depth or 0
	if seen[value] then return "<cycle>" end
	if depth >= 8 then return "<depth>" end
	seen[value] = true
	local keys = {}
	for key in pairs(value) do
		if type(key) == "string" or type(key) == "number" then keys[#keys + 1] = key end
	end
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then return ta < tb end
		return ta == "number" and a < b or tostring(a) < tostring(b)
	end)
	local rows = {}
	for _, key in ipairs(keys) do
		local child = value[key]
		local child_kind = type(child)
		if child_kind ~= "function" and child_kind ~= "userdata" and child_kind ~= "thread" then
			rows[#rows + 1] = "[" .. scalar(key) .. "]=" .. canonical(child, seen, depth + 1)
		end
	end
	seen[value] = nil
	return "{" .. table.concat(rows, ",") .. "}"
end

local function safe_call(fn, self, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c = pcall(fn, self, ...)
	if ok then return a, b, c end
	return nil
end

-- Optional task-local object-lifetime probe.  It is deliberately armed only by a harness
-- generator and changes no production state: the two snapshots read the existing map census
-- plus the exact cached traversal lists captured by AnnotateDecorRelief.  Keeping the diagnostic
-- here, beside the established capture hook, lets it observe both sides of
-- ScaleDecorationsToFull without adding a production callback or logging path.
local target_probe = rawget(_G, "g_FzpTargetObjectStateProbe")
local target_probe_rows = {}
local target_probe_seen = {}
local target_transfer_refs = {}
local target_transfer_plan = {}
local target_transfer_source
local target_transfer_destination
local target_transfer_excluded
local probe_scalar, probe_call, probe_valid, probe_target_matches
if target_probe ~= nil then
	if type(target_probe) ~= "table" or type(target_probe.path) ~= "string"
		or target_probe.path == "" or type(target_probe.targets) ~= "table"
		or #target_probe.targets ~= 8 then
		error("g_FzpTargetObjectStateProbe must name one path and exactly eight targets")
	end
end

local function probe_list_ordinal(list, wanted)
	if type(list) ~= "table" then return nil end
	for ordinal = 1, #list do
		if list[ordinal] == wanted then return ordinal end
	end
	return nil
end

-- Reproduce the exclusion/root portion of TransferGeneratedObjects against the exact object
-- array returned to production. The baseline set is intentionally not guessed: the watched
-- identities are retained from the post-generation stock boundary, while the exact enrichment
-- exclusion table is intercepted from production's public capture API below.
local function probe_transfer_plan(source, objects, excluded_objects)
	local transfer_excluded = excluded_objects
	local source_camera = source and rawget(source, "g_CameraObj") or nil
	if source_camera and probe_valid(source_camera) then
		transfer_excluded = {}
		if type(excluded_objects) == "table" then
			for object, flag in pairs(excluded_objects) do transfer_excluded[object] = flag end
		end
		transfer_excluded[source_camera] = true
	end
	local roots, seen_roots, decisions = {}, {}, {}
	local function resolve_generated_root(obj)
		local current, depth = obj, 0
		while current and depth < 64 do
			if transfer_excluded and transfer_excluded[current] then return nil, true end
			local ok_parent, parent = probe_call(current, "GetParent")
			if not ok_parent then break end
			local parent_valid = parent and probe_valid(parent)
			if not parent_valid then break end
			current = parent
			depth = depth + 1
		end
		return current, false
	end
	for ordinal = 1, #(objects or empty_table) do
		local obj = objects[ordinal]
		local decision = { input_ordinal = ordinal }
		decisions[obj] = decision
		decision.valid = probe_valid(obj)
		if not decision.valid then
			decision.reason = "invalid"
		else
			local root, excluded = resolve_generated_root(obj)
			decision.root = root
			decision.excluded = excluded == true
			if excluded or not root then
				decision.reason = "excluded"
			elseif seen_roots[root] then
				decision.reason = "duplicate_root"
				decision.root_ordinal = seen_roots[root]
			else
				roots[#roots + 1] = root
				seen_roots[root] = #roots
				decision.reason = "selected_root"
				decision.root_ordinal = #roots
			end
		end
	end
	return roots, decisions, transfer_excluded
end

local function probe_transfer_pre(source, destination, objects, excluded_objects)
	if target_probe == nil then return end
	local stage = "transfer_pre"
	if target_probe_seen[stage] then error("target state probe repeated " .. stage) end
	local roots, decisions, effective_excluded = probe_transfer_plan(
		source, objects, excluded_objects)
	target_transfer_plan = decisions
	target_probe_rows[#target_probe_rows + 1] = table.concat({
		"#stage", stage, "object_count=" .. tostring(#(objects or empty_table)),
		"root_count=" .. tostring(#roots),
	}, "|")
	local present, excluded_count, selected_count = 0, 0, 0
	for target_index, target in ipairs(target_probe.targets) do
		local obj = target_transfer_refs[target_index]
		local input_ordinal = probe_list_ordinal(objects, obj)
		if obj == nil or input_ordinal == nil then
			error("transfer probe expected one target " .. tostring(target_index)
				.. " from the stock boundary in production's input array")
		end
		present = present + 1
		local decision = decisions[obj] or {}
		if decision.excluded then excluded_count = excluded_count + 1 end
		if decision.reason == "selected_root" then selected_count = selected_count + 1 end
		local root = decision.root
		target_probe_rows[#target_probe_rows + 1] = table.concat({
			"transfer", tostring(target_index), stage,
			"class=" .. probe_scalar(target.class),
			"source_x=" .. tostring(target.x), "source_y=" .. tostring(target.y),
			"source_z=" .. tostring(target.z), "source_angle=" .. tostring(target.angle),
			"token=" .. probe_scalar(obj),
			"input_ordinal=" .. probe_scalar(input_ordinal),
			"valid=" .. tostring(decision.valid == true),
			"baseline_membership=not_observed",
			"identity_boundary=stock_surface_output",
			"directly_excluded=" .. tostring(effective_excluded
				and effective_excluded[obj] == true or false),
			"filter_reason=" .. probe_scalar(decision.reason),
			"root_token=" .. probe_scalar(root),
			"root_class=" .. probe_scalar(root and root.class or nil),
			"root_ordinal=" .. probe_scalar(decision.root_ordinal),
			"destination=" .. probe_scalar(destination),
		}, "|")
	end
	target_probe_rows[#target_probe_rows + 1] = table.concat({
		"#summary", stage, "present=" .. tostring(present),
		"excluded=" .. tostring(excluded_count),
		"selected=" .. tostring(selected_count), "targets=8",
	}, "|")
	write(target_probe.path, "schema=smr.ralph.target_object_state_probe.v2\n"
		.. table.concat(target_probe_rows, "\n") .. "\n")
	target_probe_seen[stage] = true
end

local function probe_transfer_post(source, destination, remaining_objects)
	if target_probe == nil then return end
	local stage = "transfer_post"
	if target_probe_seen[stage] then error("target state probe repeated " .. stage) end
	if not target_probe_seen.transfer_pre then error("target transfer post preceded pre") end
	target_probe_rows[#target_probe_rows + 1] = table.concat({
		"#stage", stage,
		"remaining_count=" .. tostring(type(remaining_objects) == "table"
			and #remaining_objects or -1),
	}, "|")
	local destination_count, source_count, invalid_count = 0, 0, 0
	for target_index, target in ipairs(target_probe.targets) do
		local obj = target_transfer_refs[target_index]
		if obj == nil then error("missing transfer target reference " .. tostring(target_index)) end
		local valid = probe_valid(obj)
		local map_ok, owner = false, nil
		if valid then map_ok, owner = probe_call(obj, "GetMap") end
		local owner_role = not map_ok and "unavailable"
			or owner == destination and "destination"
			or owner == source and "source" or "other"
		if not valid then invalid_count = invalid_count + 1
		elseif owner == destination then destination_count = destination_count + 1
		elseif owner == source then source_count = source_count + 1 end
		local decision = target_transfer_plan[obj] or {}
		target_probe_rows[#target_probe_rows + 1] = table.concat({
			"transfer", tostring(target_index), stage,
			"class=" .. probe_scalar(target.class),
			"source_x=" .. tostring(target.x), "source_y=" .. tostring(target.y),
			"source_z=" .. tostring(target.z), "source_angle=" .. tostring(target.angle),
			"token=" .. probe_scalar(obj),
			"valid=" .. tostring(valid),
			"filter_reason=" .. probe_scalar(decision.reason),
			"root_ordinal=" .. probe_scalar(decision.root_ordinal),
			"remaining_ordinal=" .. probe_scalar(probe_list_ordinal(remaining_objects, obj)),
			"map_read_ok=" .. tostring(map_ok),
			"map_role=" .. owner_role,
			"stamped_x=" .. probe_scalar(obj.SuperBigMapNativeSourceX),
			"stamped_y=" .. probe_scalar(obj.SuperBigMapNativeSourceY),
			"stamped_z=" .. probe_scalar(obj.SuperBigMapNativeSourceZ),
			"stamped_angle=" .. probe_scalar(obj.SuperBigMapNativeSourceAngle),
		}, "|")
	end
	target_probe_rows[#target_probe_rows + 1] = table.concat({
		"#summary", stage,
		"destination=" .. tostring(destination_count),
		"source=" .. tostring(source_count),
		"invalid=" .. tostring(invalid_count), "targets=8",
	}, "|")
	write(target_probe.path, "schema=smr.ralph.target_object_state_probe.v2\n"
		.. table.concat(target_probe_rows, "\n") .. "\n")
	target_probe_seen[stage] = true
end

local function probe_pack(...)
	return { n = select("#", ...), ... }
end

local probe_unpack = table.unpack or unpack

-- Install task-local wrappers on the public enrichment APIs. StageNativeEnrichmentRecords is the
-- exact production entry point immediately before TransferGeneratedObjects, so its successful
-- return can install a one-shot MapGet shim without closure introspection or an extra census. The
-- shim observes only production's initial collection and final remaining-object audit, restoring
-- the source method before it records the latter.
local function probe_install_transfer_observer()
	if target_probe == nil then return true end
	local deposits = type(SBM) == "table" and SBM.DepositRules or nil
	if type(deposits) ~= "table" then return nil, "deposit rules unavailable" end
	local original_capture = deposits.CaptureNativeEnrichmentRecords
	local original_stage = deposits.StageNativeEnrichmentRecords
	if type(original_capture) ~= "function" then
		return nil, "CaptureNativeEnrichmentRecords unavailable"
	end
	if type(original_stage) ~= "function" then
		return nil, "StageNativeEnrichmentRecords unavailable"
	end

	deposits.CaptureNativeEnrichmentRecords = function(...)
		local results = probe_pack(pcall(original_capture, ...))
		deposits.CaptureNativeEnrichmentRecords = original_capture
		if results[1] ~= true then error(results[2]) end
		target_transfer_excluded = results[3]
		if type(target_transfer_excluded) ~= "table" then
			error("target transfer probe received no enrichment exclusion set")
		end
		return probe_unpack(results, 2, results.n)
	end

	deposits.StageNativeEnrichmentRecords = function(destination, ...)
		local results = probe_pack(pcall(original_stage, destination, ...))
		deposits.StageNativeEnrichmentRecords = original_stage
		if results[1] ~= true then error(results[2]) end
		if results[2] == true then
			local source = target_transfer_source
			if type(source) ~= "table" or type(source.MapGet) ~= "function" then
				error("target transfer probe source MapGet is unavailable at staging")
			end
			if destination ~= target_transfer_destination then
				error("target transfer probe staging destination changed")
			end
			if type(target_transfer_excluded) ~= "table" then
				error("target transfer probe exclusions were not captured before staging")
			end
			local saved_raw_map_get = rawget(source, "MapGet")
			local real_map_get = source.MapGet
			local map_query_count = 0
			rawset(source, "MapGet", function(self, ...)
				local call = probe_pack(pcall(real_map_get, self, ...))
				if call[1] ~= true then
					rawset(source, "MapGet", saved_raw_map_get)
					error(call[2])
				end
				local result = call[2]
				if select("#", ...) == 1 and (...) == "map" and type(result) == "table" then
					map_query_count = map_query_count + 1
					if map_query_count == 1 then
						probe_transfer_pre(source, destination, result,
							target_transfer_excluded)
					elseif map_query_count == 2 then
						rawset(source, "MapGet", saved_raw_map_get)
						probe_transfer_post(source, destination, result)
					else
						rawset(source, "MapGet", saved_raw_map_get)
						error("target transfer probe observed unexpected source MapGet count")
					end
				end
				return probe_unpack(call, 2, call.n)
			end)
		end
		return probe_unpack(results, 2, results.n)
	end
	return true
end

probe_scalar = function(value)
	if value == nil then return "nil" end
	local text = tostring(value)
	return (text:gsub("[\r\n|]", "_"))
end

probe_call = function(obj, name, ...)
	local fn = obj and obj[name]
	if type(fn) ~= "function" then return false, "unavailable" end
	local ok, value, b, c = pcall(fn, obj, ...)
	if not ok then return false, "error:" .. probe_scalar(value) end
	return true, value, b, c
end

probe_valid = function(obj)
	local fn = rawget(_G, "IsValid")
	if type(fn) ~= "function" then return obj ~= nil end
	local ok, value = pcall(fn, obj)
	return ok and value == true
end

local function probe_source_identity(obj, allow_methods)
	local class = obj and tostring(obj.class or "?") or "nil"
	local x = obj and obj.SuperBigMapNativeSourceX or nil
	local y = obj and obj.SuperBigMapNativeSourceY or nil
	local z = obj and obj.SuperBigMapNativeSourceZ or nil
	local angle = obj and obj.SuperBigMapNativeSourceAngle or nil
	if allow_methods and (type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number") then
		local ok, px, py, pz = probe_call(obj, "GetVisualPosXYZ")
		if ok then
			x = type(x) == "number" and x or px
			y = type(y) == "number" and y or py
			z = type(z) == "number" and z or pz
		end
	end
	if allow_methods and type(angle) ~= "number" then
		local ok, value = probe_call(obj, "GetAngle")
		if ok then angle = value end
	end
	return class, x, y, z, angle
end

probe_target_matches = function(obj, target, allow_methods)
	local class, x, y, z, angle = probe_source_identity(obj, allow_methods)
	return class == target.class and x == target.x and y == target.y
		and z == target.z and angle == target.angle
end

local function probe_find_upvalue(fn, wanted)
	local dbg = rawget(_G, "debug")
	if type(fn) ~= "function" or type(dbg) ~= "table"
		or type(dbg.getupvalue) ~= "function" then return nil, "debug.getupvalue unavailable" end
	for index = 1, 128 do
		local name, value = dbg.getupvalue(fn, index)
		if name == nil then break end
		if name == wanted then return value end
	end
	return nil, "upvalue " .. wanted .. " unavailable"
end

local function probe_related(obj)
	if obj == nil then return "nil" end
	local valid = probe_valid(obj)
	local class, x, y, z, angle = probe_source_identity(obj, valid)
	local entity = "unreadable"
	if valid then
		local ok, value = probe_call(obj, "GetEntity")
		entity = ok and value or "unavailable"
	end
	return table.concat({
		"token=" .. probe_scalar(obj), "valid=" .. tostring(valid),
		"class=" .. probe_scalar(class), "entity=" .. probe_scalar(entity),
		"source_x=" .. probe_scalar(x), "source_y=" .. probe_scalar(y),
		"source_z=" .. probe_scalar(z), "source_angle=" .. probe_scalar(angle),
	}, ";")
end

local function probe_snapshot(stage, map)
	if target_probe == nil then return end
	if target_probe_seen[stage] then error("target state probe repeated " .. stage) end
	local map_objects = map and safe_call(map.MapGet, map, "map") or {}
	local scale_fn = type(SBM) == "table" and type(SBM.TerrainCopy) == "table"
		and SBM.TerrainCopy.ScaleDecorationsToFull or nil
	local all_by_map, all_error = probe_find_upvalue(scale_fn, "decor_objects_by_map")
	local eligible_by_map, eligible_error = probe_find_upvalue(
		scale_fn, "decor_eligible_objects_by_map")
	local cached_all = type(all_by_map) == "table" and all_by_map[map] or nil
	local cached_eligible = type(eligible_by_map) == "table" and eligible_by_map[map] or nil
	local candidates, metadata, candidate_seen = {}, {}, {}
	local function add(list, kind)
		if type(list) ~= "table" then return end
		for ordinal = 1, #list do
			local obj = list[ordinal]
			if obj ~= nil then
				if not candidate_seen[obj] then
					candidate_seen[obj] = true
					candidates[#candidates + 1] = obj
					metadata[obj] = {}
				end
				metadata[obj][kind] = ordinal
			end
		end
	end
	add(map_objects, "map_ordinal")
	add(cached_all, "cached_all_ordinal")
	add(cached_eligible, "cached_eligible_ordinal")

	target_probe_rows[#target_probe_rows + 1] = table.concat({
		"#stage", stage, "map_count=" .. tostring(#(map_objects or empty_table)),
		"cached_all_count=" .. tostring(type(cached_all) == "table" and #cached_all or -1),
		"cached_eligible_count=" .. tostring(
			type(cached_eligible) == "table" and #cached_eligible or -1),
		"cached_all_error=" .. probe_scalar(all_error),
		"cached_eligible_error=" .. probe_scalar(eligible_error),
	}, "|")
	local present = 0
	for target_index, target in ipairs(target_probe.targets) do
		local matches = {}
		for _, obj in ipairs(candidates) do
			local valid = probe_valid(obj)
			if probe_target_matches(obj, target, valid) then matches[#matches + 1] = obj end
		end
		if #matches > 1 then
			error("target state probe found duplicate target " .. tostring(target_index)
				.. " at " .. stage)
		end
		local obj = matches[1]
		if obj then present = present + 1 end
		if stage == "stock_surface_output" then
			target_transfer_refs[target_index] = obj
		end
		local fields = {
			"target", tostring(target_index), stage,
			"class=" .. probe_scalar(target.class),
			"source_x=" .. tostring(target.x), "source_y=" .. tostring(target.y),
			"source_z=" .. tostring(target.z), "source_angle=" .. tostring(target.angle),
			"present=" .. tostring(obj ~= nil),
		}
		if obj then
			local valid = probe_valid(obj)
			local meta = metadata[obj] or {}
			fields[#fields + 1] = "token=" .. probe_scalar(obj)
			fields[#fields + 1] = "valid=" .. tostring(valid)
			fields[#fields + 1] = "in_map=" .. tostring(meta.map_ordinal ~= nil)
			fields[#fields + 1] = "map_ordinal=" .. probe_scalar(meta.map_ordinal)
			fields[#fields + 1] = "cached_all_ordinal=" .. probe_scalar(meta.cached_all_ordinal)
			fields[#fields + 1] = "cached_eligible_ordinal="
				.. probe_scalar(meta.cached_eligible_ordinal)
			if valid then
				local ok_xyz, x, y, z = probe_call(obj, "GetVisualPosXYZ")
				fields[#fields + 1] = "visual_x=" .. probe_scalar(ok_xyz and x or nil)
				fields[#fields + 1] = "visual_y=" .. probe_scalar(ok_xyz and y or nil)
				fields[#fields + 1] = "visual_z=" .. probe_scalar(ok_xyz and z or nil)
				local ok_enum, enum_flags = probe_call(obj, "GetEnumFlags")
				local ok_game, game_flags = probe_call(obj, "GetGameFlags")
				fields[#fields + 1] = "enum_flags=" .. probe_scalar(ok_enum and enum_flags or nil)
				fields[#fields + 1] = "game_flags=" .. probe_scalar(ok_game and game_flags or nil)
				local ok_parent, parent = probe_call(obj, "GetParent")
				local ok_attach_parent, attach_parent = probe_call(obj, "GetAttachParent")
				local ok_attach_spot, attach_spot = probe_call(obj, "GetAttachSpot")
				fields[#fields + 1] = "get_parent_ok=" .. tostring(ok_parent)
				fields[#fields + 1] = "parent={" .. probe_related(ok_parent and parent or nil) .. "}"
				fields[#fields + 1] = "get_attach_parent_ok=" .. tostring(ok_attach_parent)
				fields[#fields + 1] = "attach_parent={"
					.. probe_related(ok_attach_parent and attach_parent or nil) .. "}"
				fields[#fields + 1] = "get_attach_spot_ok=" .. tostring(ok_attach_spot)
				fields[#fields + 1] = "attach_spot=" .. probe_scalar(ok_attach_spot and attach_spot or nil)
				local owner = (ok_attach_parent and attach_parent) or (ok_parent and parent) or nil
				local attach_ordinal, attach_count = nil, nil
				if owner and probe_valid(owner) then
					local ok_attaches, attaches = probe_call(owner, "GetAttaches")
					if ok_attaches and type(attaches) == "table" then
						attach_count = #attaches
						for ordinal, child in ipairs(attaches) do
							if child == obj then attach_ordinal = ordinal break end
						end
					end
				end
				fields[#fields + 1] = "parent_attach_count=" .. probe_scalar(attach_count)
				fields[#fields + 1] = "parent_attach_ordinal=" .. probe_scalar(attach_ordinal)
			else
				fields[#fields + 1] = "invalid_wrapper_methods_skipped=true"
			end
		end
		target_probe_rows[#target_probe_rows + 1] = table.concat(fields, "|")
	end
	if stage == "stock_surface_output" and present ~= 8 then
		error("target state probe expected eight live inputs at " .. stage
			.. ", found " .. tostring(present))
	end
	target_probe_rows[#target_probe_rows + 1] = "#summary|" .. stage
		.. "|present=" .. tostring(present) .. "|targets=8"
	write(target_probe.path, "schema=smr.ralph.target_object_state_probe.v1\n"
		.. table.concat(target_probe_rows, "\n") .. "\n")
	target_probe_seen[stage] = true
end

local function object_rows(map, collision_only)
	local rows = {}
	local objects = map and safe_call(map.MapGet, map, "map") or {}
	local ef_collision = type(const) == "table" and const.efCollision or nil
	local collision_surface = type(EntitySurfaces) == "table"
		and EntitySurfaces.Collision or rawget(_G, "g_NCF_SurfaceTypes")
	for i = 1, #(objects or empty_table) do
		local obj = objects[i]
		if obj and IsValid(obj) then
			local include = true
			local collision_flag = ef_collision and safe_call(obj.GetEnumFlags, obj, ef_collision)
			local entity = safe_call(obj.GetEntity, obj)
			if collision_only then
				local has_surface = false
				if entity and collision_surface and type(IsValidEntity) == "function"
						and IsValidEntity(entity) and type(HasAnySurfaces) == "function" then
					local ok_surface, value = pcall(HasAnySurfaces, entity, collision_surface)
					has_surface = ok_surface and value == true
				end
				include = collision_flag ~= nil and collision_flag ~= false
					and collision_flag ~= 0 and has_surface
			end
			if include then
				local x, y, z = safe_call(obj.GetVisualPosXYZ, obj)
				local scale = safe_call(obj.GetScale, obj)
				local angle = safe_call(obj.GetAngle, obj)
				local game_flags = safe_call(obj.GetGameFlags, obj)
				local shape = safe_call(obj.GetShapePoints, obj)
				rows[#rows + 1] = table.concat({
					tostring(obj.class or "?"), tostring(entity or ""), tostring(x or ""),
					tostring(y or ""), tostring(z or ""), tostring(scale or ""),
					tostring(angle or ""), tostring(collision_flag or ""),
					tostring(game_flags or ""), tostring(type(shape) == "table" and #shape or 0),
					tostring(obj.SuperBigMapNativeSourceClass or ""),
					tostring(obj.SuperBigMapNativeSourceX or ""),
					tostring(obj.SuperBigMapNativeSourceY or ""),
					tostring(obj.SuperBigMapNativeSourceZ or ""),
				}, ",")
			end
		end
	end
	table.sort(rows)
	return table.concat(rows, "\n") .. "\n"
end

local function save_objects(path, map, collision_only)
	write(path, object_rows(map, collision_only))
end

local function save_passability(path, map)
	local ok_count, count = pcall(terrain.GetPassGridsCount, map)
	count = ok_count and tonumber(count) or nil
	if not count or count < 1 or count > 8 then
		error("invalid pass-grid count for " .. path .. ": " .. tostring(count))
	end
	local chunks = { "smr.ralph.passability.bundle.v1\n", tostring(count) .. "\n" }
	for index = 0, count - 1 do
		local ok_grid, grid = pcall(terrain.GetPassGrid, map, index)
		if not ok_grid or not grid then error("pass grid unavailable at " .. tostring(index)) end
		local blob, err = GridWriteStr(grid)
		if err or type(blob) ~= "string" then
			error("GridWriteStr failed for pass grid " .. tostring(index) .. ": " .. tostring(err))
		end
		chunks[#chunks + 1] = tostring(index) .. ":" .. tostring(#blob) .. "\n"
		chunks[#chunks + 1] = blob
	end
	write(path, table.concat(chunks))
end

local function save_buildable(path, grid)
	if not grid then error("buildable grid unavailable for " .. path) end
	local blob, err = GridWriteStr(grid)
	if err or type(blob) ~= "string" then
		error("GridWriteStr failed for buildable grid: " .. tostring(err))
	end
	write(path, blob)
end

local function save_terrain_pair(stage, map)
	save_grid(artifacts[stage].surface_height, terrain.GetHeightGrid(map))
	save_grid(artifacts[stage].surface_terrain, terrain.GetTypeGrid(map))
end

local function save_generation_inputs(path, map, details)
	local payload = {
		current_map_params = rawget(_G, "g_CurrentMapParams"),
		mission_params = rawget(_G, "g_CurrentMissionParams"),
		session_options = rawget(_G, "g_SessionOptions"),
		session_seed = rawget(_G, "g_SessionSeed"),
		initial_session_seed = rawget(_G, "g_InitialSessionSeed"),
		mapdata = map and map.mapdata,
		generator_seed = details and details.generator and details.generator.Seed,
		generator_hash = details and details.generator and details.generator.GenerationHash,
	}
	write(path, canonical(payload) .. "\n")
end

local function save_rng(path, details)
	local cursor = "unavailable"
	local random = rawget(_G, "SessionRandom")
	if type(random) == "table" and type(random.rand_state) == "table"
		and type(random.rand_state.Last) == "function" then
		local ok, value = pcall(random.rand_state.Last, random.rand_state)
		if ok then cursor = tostring(value) end
	end
	write(path, table.concat({
		"session=" .. tostring(rawget(_G, "g_SessionSeed")),
		"initial_session=" .. tostring(rawget(_G, "g_InitialSessionSeed")),
		"session_cursor=" .. cursor,
		"surface=" .. tostring(rawget(_G, "g_ParitySurfaceSeed")),
		"generator_seed=" .. tostring(details and details.generator and details.generator.Seed),
	}, "\n") .. "\n")
end

local function save_prefab_order(path, details)
	local generator = details and details.generator
	local payload = {
		blank_map = generator and generator.BlankMap,
		prefab_type = generator and generator.PrefabType,
		prefab_list = generator and generator.PrefabList,
		prefab_tags = generator and generator.PrefabTags,
		map_gen_parameters = generator and generator.map_gen_parameters,
	}
	write(path, canonical(payload) .. "\n")
end

local stage_seen = {}
local function capture_hook(stage, map, details)
	local environment = map and map.mapdata and map.mapdata.Environment
	if environment ~= "Surface" then return true end
	if stage == "pre_stock_generation" then
		if stage_seen[stage] then error(stage .. " repeated") end
		save_rng(artifacts[stage].rng_state, details)
		save_prefab_order(artifacts[stage].prefab_order, details)
		save_generation_inputs(artifacts[stage].generation_inputs, map, details)
		stage_seen[stage] = true
	elseif stage == "stock_surface_output" then
		if stage_seen[stage] then error(stage .. " repeated") end
		if target_probe ~= nil then
			target_transfer_source = map
			target_transfer_destination = details and details.destination or nil
			if type(target_transfer_destination) ~= "table" then
				error("target transfer probe stock destination is unavailable")
			end
		end
		save_terrain_pair(stage, map)
		save_objects(artifacts[stage].object_census, map, false)
		probe_snapshot("stock_surface_output", map)
		stage_seen[stage] = true
	elseif stage == "pre_z_transform" or stage == "post_z_transform" then
		local kind = details and details.grid_kind
		if kind ~= "surface_height" and kind ~= "surface_terrain" then
			error(stage .. " received unknown grid kind " .. tostring(kind))
		end
		if stage_seen[stage .. ":" .. kind] then error(stage .. " " .. kind .. " repeated") end
		save_grid(artifacts[stage][kind], details.grid)
		stage_seen[stage .. ":" .. kind] = true
		if stage == "pre_z_transform" and kind == "surface_height" then
			save_objects(artifacts[stage].object_census, map, false)
		elseif stage == "post_z_transform" and kind == "surface_height" then
			write(artifacts[stage].zone_stamp, canonical({
				zmul = map.SuperBigMapZScaleMul,
				zdiv = map.SuperBigMapZScaleDiv,
				zadd = map.SuperBigMapZScaleAdd,
				measured_max = map.SuperBigMapZMeasuredMaxHeight,
				zones = map.SuperBigMapZCompressionZones,
			}) .. "\n")
		end
	elseif stage == "post_object_transform" then
		if stage_seen[stage] then error(stage .. " repeated") end
		save_objects(artifacts[stage].object_census, map, false)
		save_objects(artifacts[stage].collision_census, map, true)
		probe_snapshot("post_scale_decorations", map)
		stage_seen[stage] = true
	else
		error("unknown determinism capture stage " .. tostring(stage))
	end
	return true
end

local armed, arm_error = generation.SetDeterminismCaptureHookForTest(
	capture_hook, "full_z_parity_42S85E_cohort")
if armed ~= true then error("could not arm capture hook: " .. tostring(arm_error)) end
local transfer_observer_armed, transfer_observer_error = probe_install_transfer_observer()
if transfer_observer_armed ~= true then
	return "fzp_determinism_capture_arm_failed:" .. tostring(transfer_observer_error)
end

local function find_maps()
	local found = {}
	for _, map in ipairs(Maps or empty_table) do
		local environment = map and map.mapdata and map.mapdata.Environment
		if environment == "Surface" and not found.surface then found.surface = map end
		if environment == "Underground" and not found.underground then found.underground = map end
	end
	if not found.surface or not found.underground then error("surface/underground maps unavailable") end
	return found
end

local function snapshot_build_stage(stage, map, buildable_grid)
	save_terrain_pair(stage, map)
	save_passability(artifacts[stage].passability, map)
	save_buildable(artifacts[stage].buildable, buildable_grid)
	save_objects(artifacts[stage].collision_census, map, true)
end

local function capture_buildable_phases(map)
	local shipped = map.buildable and map.buildable.z_grid
	if not shipped then error("surface shipped buildable grid unavailable") end
	local width, height = shipped:size()
	local unbuildable_z = type(buildUnbuildableZ) == "function"
		and buildUnbuildableZ() or 2 ^ 16 - 1
	local raw = NewGrid(width, height, 16, unbuildable_z)
	local processed = NewGrid(width, height, 16, unbuildable_z)
	if not raw or not processed then error("fresh buildable work grids unavailable") end
	snapshot_build_stage("pre_init_buildable", map, raw)
	local range = map.mapdata and map.mapdata.visible_height_range
	local range_from, range_to
	pcall(function()
		range_from = range and tonumber(range.from)
		range_to = range and tonumber(range.to)
	end)
	InitBuildableGrid(map, {
		buildable_grid = raw,
		unbuildable_z = unbuildable_z,
		flat_threshold = g_NCF_FlatThreshold,
		max_surface_height = g_NCF_MaxSurfaceHeight,
		max_surface_error = g_NCF_MaxSurfaceError,
		surface_types = g_NCF_SurfaceTypes,
		enum_flags = g_NCF_EnumFlags,
		ignore_game_flags = g_NCF_IgnoreGameFlags,
		map_border = tonumber(map.mapdata and map.mapdata.PassBorder) or 0,
		map_min_height = range_from and range_from * guim or 0,
		map_max_height = range_to and range_to * guim or unbuildable_z,
	})
	snapshot_build_stage("post_init_buildable", map, raw)
	ProcessBuildableGrid({
		buildable_grid = raw,
		buildable_z = processed,
		unbuildable_z = unbuildable_z,
		minsize = g_NCF_FlatThresholdAreaMin,
		maxsize = g_NCF_FlatThresholdAreaMax,
		mindelta = g_NCF_FlatThresholdAreaMinHeightDelta,
		maxdelta = g_NCF_FlatThresholdAreaMaxHeightDelta,
		minarea = g_NCF_MinArea,
	})
	snapshot_build_stage("post_process_buildable", map, processed)
	raw:free()
	processed:free()
end

local function save_final(maps)
	save_grid(artifacts.final_stable.surface_height, terrain.GetHeightGrid(maps.surface))
	save_grid(artifacts.final_stable.underground_height, terrain.GetHeightGrid(maps.underground))
	save_passability(artifacts.final_stable.surface_passability, maps.surface)
	save_passability(artifacts.final_stable.underground_passability, maps.underground)
	save_buildable(artifacts.final_stable.surface_buildable,
		maps.surface.buildable and maps.surface.buildable.z_grid)
	save_buildable(artifacts.final_stable.underground_buildable,
		maps.underground.buildable and maps.underground.buildable.z_grid)
	write(artifacts.final_stable.object_census,
		"#surface\n" .. object_rows(maps.surface, false)
			.. "#underground\n" .. object_rows(maps.underground, false))
end

rawset(_G, "g_FzpDeterminismCaptureFinalize", function()
	if rawget(_G, "g_FzpDeterminismCaptureFinalized") == true then
		error("determinism capture finalizer already ran")
	end
	rawset(_G, "g_FzpDeterminismCaptureStatus", "finalizing")
	local ok, err = xpcall(function()
		for _, key in ipairs({
			"pre_stock_generation", "stock_surface_output", "post_object_transform",
			"pre_z_transform:surface_height", "pre_z_transform:surface_terrain",
			"post_z_transform:surface_height", "post_z_transform:surface_terrain",
		}) do
			if not stage_seen[key] then error("missing early capture " .. key) end
		end
		if target_probe ~= nil then
			for _, key in ipairs({
				"stock_surface_output", "transfer_pre", "transfer_post",
				"post_scale_decorations",
			}) do
				if not target_probe_seen[key] then error("missing target state probe " .. key) end
			end
		end
		local maps = find_maps()
		if maps.surface.SuperBigMapSurfaceStretchDone ~= true
			or maps.underground.SuperBigMapUndergroundPrepared ~= true then
			error("finalizer requires completed surface and underground preparation")
		end
		if type(PauseInfiniteLoopDetection) == "function" then
			PauseInfiniteLoopDetection("fzp_determinism_capture")
		end
		capture_buildable_phases(maps.surface)
		save_final(maps)
		if type(ResumeInfiniteLoopDetection) == "function" then
			ResumeInfiniteLoopDetection("fzp_determinism_capture")
		end
		rawset(_G, "g_FzpDeterminismCaptureFinalized", true)
		rawset(_G, "g_FzpDeterminismCaptureStatus", "complete")
	end, debug.traceback)
	if not ok then
		pcall(function()
			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("fzp_determinism_capture")
			end
		end)
		rawset(_G, "g_FzpDeterminismCaptureError", tostring(err))
		rawset(_G, "g_FzpDeterminismCaptureStatus", "error")
		error(err)
	end
	return true
end)

return "fzp_determinism_capture_armed"

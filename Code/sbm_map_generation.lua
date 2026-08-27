-- Super Big Map -- stretch-only 20x20 map expansion.
--
-- For eligible random maps this allocates an 8192-tile destination, generates one
-- native vanilla source, then proportionally stretches its terrain and generated
-- content over the destination. The RandomMapGenerator.Generate/DoGenerate hook
-- and stretch pass share pending-map state, so they live together here.
--
-- Generic engine helpers come from sbm_engine. This module keeps only the gen-time
-- TerrainSize local because its behavior is context-specific to map generation --
-- e.g. DoGenerate temporarily overrides
-- terrain.GetMapSize so the generator only sees the native source view, and the gen-time
-- size must read mapdata.Width x HeightTileSize (assert-free), not map:GetMapSize.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local GENERATOR_PATCH_VERSION = SuperBigMap.GENERATOR_PATCH_VERSION or 2
SuperBigMap.GenerationReadiness = SuperBigMap.GenerationReadiness or {}
SuperBigMap.GenerationReadiness.VERSION = 1

-- Pending/blocked per-map state shared across this module's hooks (kept in the
-- shared State table rather than _G globals).
SuperBigMap.State = SuperBigMap.State or {}
SuperBigMap.State.expansion_pending_maps = SuperBigMap.State.expansion_pending_maps or {}
SuperBigMap.State.expansion_blocked_maps = SuperBigMap.State.expansion_blocked_maps or {}
SuperBigMap.State.underground_recovery_maps = SuperBigMap.State.underground_recovery_maps
	or setmetatable({}, { __mode = "k" })
SuperBigMap.State.pending_underground_elevator_restores =
	SuperBigMap.State.pending_underground_elevator_restores
	or setmetatable({}, { __mode = "k" })
SuperBigMap.State.underground_elevator_restore_tokens =
	SuperBigMap.State.underground_elevator_restore_tokens or {}
SuperBigMap.State.underground_elevator_restore_epoch =
	SuperBigMap.State.underground_elevator_restore_epoch or 0
SuperBigMap.State.deferred_vehicle_night_lights =
	SuperBigMap.State.deferred_vehicle_night_lights or setmetatable({}, { __mode = "k" })
SuperBigMap.State.offscreen_vehicle_light_suppressions =
	SuperBigMap.State.offscreen_vehicle_light_suppressions or setmetatable({}, { __mode = "k" })
SuperBigMap.State.underground_shared_wonder_texture_pins =
	SuperBigMap.State.underground_shared_wonder_texture_pins or {}
local pending_maps = SuperBigMap.State.expansion_pending_maps
local blocked_maps = SuperBigMap.State.expansion_blocked_maps
local underground_recovery_maps = SuperBigMap.State.underground_recovery_maps
local pending_underground_elevator_restores =
	SuperBigMap.State.pending_underground_elevator_restores
local underground_elevator_restore_tokens =
	SuperBigMap.State.underground_elevator_restore_tokens
local deferred_vehicle_night_lights = SuperBigMap.State.deferred_vehicle_night_lights
local offscreen_vehicle_light_suppressions =
	SuperBigMap.State.offscreen_vehicle_light_suppressions
local underground_shared_wonder_texture_pins =
	SuperBigMap.State.underground_shared_wonder_texture_pins

-- Generic engine helpers from sbm_engine (loaded before this module). Aliased to locals
-- so existing call sites are unchanged; only the gen-time TerrainSize below stays local.
local Engine = SuperBigMap.Engine
local Global = Engine.Global
local TryCall = Engine.TryCall
local SafeCall = Engine.SafeCall
local Unpack = Engine.Unpack
local IsKindOfSafe = Engine.IsKindOf

local function PointXY(pos)
	if not pos then
		return false
	end
	if type(pos.xy) == "function" then
		local x, y = SafeCall(pos.xy, pos)
		return x, y
	end
	if type(pos.x) == "number" and type(pos.y) == "number" then
		return pos.x, pos.y
	end
	return false
end

local function cfg_bool(key, default)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "boolean" then
		return value
	end
	return default
end

-- Test-only determinism capture seam. Normal gameplay never installs this hook, so the fast path
-- is one table lookup and an immediate return. A deliberately armed capture is fail-closed: losing
-- an early stock/object boundary would make a later identical final hash uninterpretable.
function SuperBigMap.NotifyDeterminismCaptureForTest(stage, map, details)
	local state = SuperBigMap.State
	local capture = type(state) == "table" and state.test_determinism_capture or nil
	if type(capture) ~= "table" then return false end
	if type(capture.hook) ~= "function" then
		error("armed determinism capture hook is unavailable")
	end
	local ok, result = pcall(capture.hook, stage, map, details or false)
	if not ok or result ~= true then
		error("determinism capture failed at " .. tostring(stage) .. ": "
			.. tostring(ok and result or result))
	end
	capture.counts = capture.counts or {}
	capture.counts[stage] = (capture.counts[stage] or 0) + 1
	return true
end

-- Establish the exact vanilla darkness renderer state as a synchronous transition boundary.
-- ChangeCurrentMapSlot changes the engine map before it emits CurrentMapChangeDone; relying only
-- on that later message leaves a render-thread-sized window in which a newly current Underground
-- map can inherit Surface's value (0). Call this only while a loading/backdrop cover is already
-- owned. Correctness depends on the observed renderer value, never a delay or frame count.
function SuperBigMap.EnsureVanillaDarknessReady(map)
	if not map or not map.mapdata then return false, "map data unavailable" end
	local environment = map.mapdata.Environment
	if environment ~= "Surface" and environment ~= "Underground" then
		return true, "environment does not use underground darkness"
	end
	local expected = environment == "Underground" and 90 or 0
	local platform = Global("Platform")
	local is_editor_active = Global("IsEditorActive")
	if type(platform) == "table" and platform.editor == true
		and type(is_editor_active) == "function"
		and SafeCall(is_editor_active) == true then
		expected = 0
	end
	local update_reveal = Global("UpdateRevealDarkness")
	local update_ok = type(update_reveal) == "function"
		and pcall(update_reveal, map) or false
	local hr = Global("hr")
	if type(hr) ~= "table" then return false, "darkness renderer settings unavailable" end
	-- UpdateRevealDarkness is authoritative. The scalar assignment is its exact vanilla effect and
	-- is a fail-safe if another handler replaced/failed the function during an in-session reload.
	if tonumber(hr.EnableDarknessReveal) ~= expected then
		hr.EnableDarknessReveal = expected
	end
	local actual = tonumber(hr.EnableDarknessReveal)
	if actual ~= expected then
		return false, "expected darkness value " .. tostring(expected)
			.. ", observed " .. tostring(actual)
	end
	return true, update_ok and "vanilla darkness state ready"
		or "vanilla darkness scalar restored directly"
end

-- Update the loading box's live status line (see sbm_loading_ui SetLoadingPhase). Safe no-op
-- if the loading UI isn't present; " Please wait." is appended by SetLoadingPhase.
local function SetLoadingPhase(message)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.LoadingPhase) == "function" then
		diagnostics.LoadingPhase(message, Global("CurrentMap"))
	end
	if type(SuperBigMap.SetLoadingPhase) == "function" then
		pcall(SuperBigMap.SetLoadingPhase, message)
	end
end

-- One surface-expansion loading reference belongs to each live map. Keeping ownership here avoids
-- duplicate Begin calls from readiness retries and guarantees every success/error exit releases the
-- same UI phase exactly once. Weak keys keep this transient state out of saves.
local surface_loading_ref_maps = setmetatable({}, { __mode = "k" })

local function BeginSurfaceExpansionLoading(map, phase)
	if not map then return false end
	if surface_loading_ref_maps[map] == true then
		if phase then SetLoadingPhase(phase) end
		local visible = SuperBigMap.ExpansionLoadingVisible
		return type(visible) == "function" and visible() == true
	end
	local begin_loading = SuperBigMap.ExpansionLoadingBegin
	if type(begin_loading) ~= "function" then return false end
	local ok, visible = pcall(begin_loading)
	if not ok then return false end
	surface_loading_ref_maps[map] = true
	if phase then SetLoadingPhase(phase) end
	return visible == true
end

local function EndSurfaceExpansionLoading(map)
	if not map or surface_loading_ref_maps[map] ~= true then return false end
	surface_loading_ref_maps[map] = nil
	local end_loading = SuperBigMap.ExpansionLoadingEnd
	if type(end_loading) == "function" then pcall(end_loading) end
	return true
end

local function PackValues(...)
	return { n = select("#", ...), ... }
end

local function LoadingStart(reason, map, data)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.LoadingStart) == "function" then
		diagnostics.LoadingStart(reason, map, data)
	end
end

local function LoadingStep(name, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.LoadingStep) == "function" then
		diagnostics.LoadingStep(name, data, map)
	end
end

function SuperBigMap.TraceUndergroundSeedReservation(stage, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.UndergroundSeedReservation) == "function" then
		return diagnostics.UndergroundSeedReservation(stage, data, map)
	end
	return false
end

local function LoadingBegin(name, map, data)
	local diagnostics = SuperBigMap.Diagnostics
	return diagnostics and type(diagnostics.LoadingBegin) == "function"
		and diagnostics.LoadingBegin(name, map, data) or false
end

local function LoadingEnd(token, data, ok)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.LoadingEnd) == "function" then
		diagnostics.LoadingEnd(token, data, ok)
	end
end

local function FunctionEnvironment(fn)
	if type(fn) ~= "function" then return nil end
	local getfenv_fn = Global("getfenv")
	if type(getfenv_fn) == "function" then
		local ok, env = pcall(getfenv_fn, fn)
		if ok and type(env) == "table" then return env end
	end
	local debug_lib = Global("debug")
	if type(debug_lib) == "table" and type(debug_lib.getfenv) == "function" then
		local ok, env = pcall(debug_lib.getfenv, fn)
		if ok and type(env) == "table" then return env end
	end
	if type(debug_lib) == "table" and type(debug_lib.getupvalue) == "function" then
		for i = 1, 64 do
			local ok, name, value = pcall(debug_lib.getupvalue, fn, i)
			if not ok or name == nil then break end
			if name == "_ENV" and type(value) == "table" then return value end
		end
	end
	local state = SuperBigMap.State
	local external_inspector = type(state) == "table"
		and state.rock_parity_function_environment or nil
	if SuperBigMap.Config and SuperBigMap.Config.TRACE_UNDERGROUND_ROCK_PARITY == true
		and type(external_inspector) == "function" then
		local ok, env = pcall(external_inspector, fn)
		if ok and type(env) == "table" then return env end
	end
	return nil
end

-- Native clutter has a public writer but no reliable reader while random-map generation is
-- running on a temporary/non-current map slot. Capture vanilla's final write synchronously, while
-- the source compute grid is still alive. The game can compile map-gen methods against private
-- function environments, so instrument every distinct terrain table visible from those methods,
-- not only _G. ClearClutterGrid is captured too for uniform-grid sequences.
local function CallWithClutterCapture(map, callable, ...)
	local write_count = 0
	local capture_error
	local candidate_descriptions = {}
	local write_sources = {}
	local patches = {}
	local seen_terrain_tables = {}
	local function free_grid(grid)
		if grid then pcall(function() if type(grid.free) == "function" then grid:free() end end) end
	end
	local function replace_grid_capture(grid)
		local clone
		local ok, err = pcall(function()
			if not grid or type(grid.clone) ~= "function" then
				error("generated clutter grid is not cloneable")
			end
			clone = grid:clone()
			if not clone then error("generated clutter grid clone returned nil") end
		end)
		if not ok then
			capture_error = tostring(err)
			free_grid(clone)
			clone = nil
		end
		free_grid(map.SuperBigMapCapturedClutterGrid)
		map.SuperBigMapCapturedClutterGrid = clone
		map.SuperBigMapCapturedClutterFill = nil
		return clone ~= nil
	end
	local function target_matches(target)
		if target == map then return true end
		local target_slot = type(target) == "table" and target.slot or target
		return map and map.slot ~= nil and target_slot == map.slot
	end
	local function install_candidate(label, terrain_api)
		candidate_descriptions[#candidate_descriptions + 1] = label .. "=" .. tostring(terrain_api)
		if type(terrain_api) ~= "table" or seen_terrain_tables[terrain_api] then return end
		seen_terrain_tables[terrain_api] = true
		local record = {
			label = label,
			api = terrain_api,
			original_set = terrain_api.SetClutterGrid,
			original_clear = terrain_api.ClearClutterGrid,
			writes = 0,
		}
		if type(record.original_set) == "function" then
			record.set_wrapper = function(target, grid, ...)
				local results = PackValues(record.original_set(target, grid, ...))
				if target_matches(target) and results[1] then
					write_count = write_count + 1
					record.writes = record.writes + 1
					replace_grid_capture(grid)
				end
				return Unpack(results, 1, results.n)
			end
			terrain_api.SetClutterGrid = record.set_wrapper
		end
		if type(record.original_clear) == "function" then
			record.clear_wrapper = function(target, value, ...)
				local results = PackValues(record.original_clear(target, value, ...))
				if target_matches(target) and results[1] then
					write_count = write_count + 1
					record.writes = record.writes + 1
					free_grid(map.SuperBigMapCapturedClutterGrid)
					map.SuperBigMapCapturedClutterGrid = nil
					map.SuperBigMapCapturedClutterFill = value
					capture_error = nil
				end
				return Unpack(results, 1, results.n)
			end
			terrain_api.ClearClutterGrid = record.clear_wrapper
		end
		if record.set_wrapper or record.clear_wrapper then patches[#patches + 1] = record end
	end
	local function install_environment_candidate(label, fn)
		local env = FunctionEnvironment(fn)
		install_candidate(label, type(env) == "table" and env.terrain or nil)
	end

	install_candidate("global", Global("terrain"))
	install_environment_candidate("DoGenerate_env", callable)
	local import_class = Global("GridOpMapImport")
	local reset_class = Global("GridOpMapReset")
	local export_class = Global("GridOpMapExport")
	install_environment_candidate("MapImport_env", type(import_class) == "table" and import_class.SetGridInput)
	install_environment_candidate("MapReset_env", type(reset_class) == "table" and reset_class.Run)
	install_environment_candidate("MapExport_env", type(export_class) == "table" and export_class.GetGridOutput)

	local results = PackValues(pcall(callable, ...))
	-- Always restore every exact function that preceded this synchronous transaction.
	for patch_index = #patches, 1, -1 do
		local record = patches[patch_index]
		if record.set_wrapper and record.api.SetClutterGrid == record.set_wrapper then
			record.api.SetClutterGrid = record.original_set
		end
		if record.clear_wrapper and record.api.ClearClutterGrid == record.clear_wrapper then
			record.api.ClearClutterGrid = record.original_clear
		end
		write_sources[#write_sources + 1] = record.label .. ":" .. tostring(record.writes)
	end
	local captured_grid = map and map.SuperBigMapCapturedClutterGrid
	local captured_w, captured_h
	if captured_grid and type(captured_grid.size) == "function" then
		local size_ok, width, height = pcall(captured_grid.size, captured_grid)
		if size_ok then captured_w, captured_h = width, height end
	end
	LoadingStep("captured vanilla native clutter operation", {
		writes = write_count,
		kind = captured_grid and "grid" or map.SuperBigMapCapturedClutterFill ~= nil and "uniform" or "none",
		grid_cells = captured_w and (tostring(captured_w) .. "x" .. tostring(captured_h)) or "none",
		terrain_candidates = table.concat(candidate_descriptions, " | "),
		write_sources = table.concat(write_sources, " | "),
		error = capture_error or "",
	}, map)
	if not results[1] then error(results[2]) end
	return Unpack(results, 2, results.n)
end

-- Read-only diagnostic for the write-only native clutter grid. Keep every access protected and
-- report identities/sizes as strings so a failed route cannot interrupt map generation.
local function ProbeNativeClutterAccess(map, stage)
	if not map then return false end
	local editor_api = Global("editor")
	local terrain_api = Global("terrain")
	local current_map = Global("CurrentMap")
	local probes = {}
	local function grid_shape(grid)
		if not grid then return "nil" end
		if type(grid.size) ~= "function" then return tostring(grid) .. ":no-size" end
		local ok, width, height = pcall(grid.size, grid)
		return ok and (tostring(width) .. "x" .. tostring(height)) or (tostring(grid) .. ":size-error")
	end
	local function probe_ref(label, fn, owner, name)
		if type(fn) ~= "function" then
			probes[#probes + 1] = label .. "=missing"
			return
		end
		local ok, grid = pcall(fn, owner, name)
		probes[#probes + 1] = label .. "=" .. (ok and grid_shape(grid) or ("error:" .. tostring(grid)))
	end
	for _, alias in ipairs({ "clutter", "clutter_density", "grass_density" }) do
		probe_ref("editor.map." .. alias,
			type(editor_api) == "table" and editor_api.GetGridRef, map, alias)
		probe_ref("orig.map." .. alias, Global("origGetGridRef"), map, alias)
	end
	local grid_names = {}
	if type(editor_api) == "table" and type(editor_api.GetGridNames) == "function" then
		local ok, names = pcall(editor_api.GetGridNames)
		if ok and type(names) == "table" then
			for _, name in ipairs(names) do
				local lower = string.lower(tostring(name))
				if string.find(lower, "clutter", 1, true) or string.find(lower, "grass", 1, true) then
					grid_names[#grid_names + 1] = tostring(name)
				end
			end
		end
	end
	local map_fields = {}
	pcall(function()
		for key, value in pairs(map) do
			local lower = string.lower(tostring(key))
			if string.find(lower, "clutter", 1, true) or string.find(lower, "grass", 1, true) then
				map_fields[#map_fields + 1] = tostring(key) .. "=" .. tostring(value)
			end
		end
	end)
	local samples = {}
	local get_density = type(terrain_api) == "table" and terrain_api.GetClutterDensity
	local point_fn = Global("point")
	local const_tbl = Global("const")
	local height_tile = type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize) or 0
	if current_map == map and type(get_density) == "function" and type(point_fn) == "function" then
		local world_w = tonumber(map.mapdata and map.mapdata.Width) and map.mapdata.Width * height_tile or 0
		local world_h = tonumber(map.mapdata and map.mapdata.Height) and map.mapdata.Height * height_tile or 0
		for label, pos in pairs({ origin = point_fn(0, 0), center = point_fn(world_w / 2, world_h / 2) }) do
			local ok, value = pcall(get_density, map, pos)
			samples[#samples + 1] = label .. "=" .. (ok and tostring(value) or ("error:" .. tostring(value)))
		end
	end
	local import_class = Global("GridOpMapImport")
	local reset_class = Global("GridOpMapReset")
	local import_env = FunctionEnvironment(type(import_class) == "table" and import_class.SetGridInput)
	local reset_env = FunctionEnvironment(type(reset_class) == "table" and reset_class.Run)
	LoadingStep("native clutter access probe", {
		stage = tostring(stage),
		map_is_current = tostring(current_map == map),
		global_terrain = tostring(terrain_api),
		map_import_terrain = tostring(type(import_env) == "table" and import_env.terrain),
		map_reset_terrain = tostring(type(reset_env) == "table" and reset_env.terrain),
		clutter_tile_size = tostring(type(const_tbl) == "table" and const_tbl.ClutterTileSize),
		height_tile_size = tostring(height_tile),
		grid_names = #grid_names > 0 and table.concat(grid_names, ",") or "none",
		map_fields = #map_fields > 0 and table.concat(map_fields, " | ") or "none",
		refs = table.concat(probes, " | "),
		samples = #samples > 0 and table.concat(samples, " | ") or "not-current-or-unavailable",
	}, map)
	return true
end

local function LoadingFinish(reason, map, data, ok)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.LoadingFinish) == "function" then
		diagnostics.LoadingFinish(reason, map, data, ok)
	end
end

-- Preserve SafeCall's exact behavior and result tuple while timing only the opt-in diagnostic run.
local function TimedSafeCall(name, map, func, ...)
	local diagnostics = SuperBigMap.Diagnostics
	if not (diagnostics and type(diagnostics.LoadingEnabled) == "function"
		and diagnostics.LoadingEnabled() == true) then
		return SafeCall(func, ...)
	end
	local token = LoadingBegin(name, map)
	local results = PackValues(SafeCall(func, ...))
	LoadingEnd(token, { first_result = tostring(results[1]) }, true)
	return Unpack(results, 1, results.n)
end

local function ExpansionAudit(event, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.Elevator) == "function" then
		diagnostics.Elevator(event, data, map)
	end
end

-- Focused runtime traversal trace. Vanilla's manual Unit:UseElevator command has several silent
-- returns (different maps, unreachable entrance, invalid building, or missing counterpart), so a
-- normal log cannot distinguish them. These wrappers are observational, apply only to BaseRover
-- descendants on expanded maps, and preserve the exact original argument/result tuples.
local ELEVATOR_TRAVERSAL_DIAGNOSTIC_VERSION = 7
local elevator_traversal_by_unit = setmetatable({}, { __mode = "k" })

local function ElevatorTraversalAudit(event, data, map)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.ElevatorTraversal) == "function" then
		diagnostics.ElevatorTraversal(event, data, map)
	end
end

local function TraversalObjectValid(obj)
	if not obj then return false end
	local is_valid = Global("IsValid")
	return type(is_valid) ~= "function" or SafeCall(is_valid, obj) == true
end

local function TraversalObjectMap(obj)
	-- A destroyed engine object retains its Lua methods long enough for delayed map-change
	-- cleanup to encounter it. Calling GameObject:GetMap on that stale shell asserts before
	-- pcall can make the engine call harmless, so validity must be the first boundary.
	if not TraversalObjectValid(obj) then return nil end
	if type(obj.GetMap) == "function" then
		local map = SafeCall(obj.GetMap, obj)
		if map then return map end
	end
	return obj.city and obj.city.map or nil
end

local function TraversalIsExpandedMap(map)
	local grid = SuperBigMap.SectorGrid
	return map and grid and type(grid.IsModMap) == "function"
		and grid.IsModMap(map) == true
end

local function TraversalIsExpandedContext(unit, elevator)
	return TraversalIsExpandedMap(TraversalObjectMap(unit))
		or TraversalIsExpandedMap(TraversalObjectMap(elevator))
end

local function TraversalAddPosition(data, prefix, value)
	local pos = value and Engine.ObjectPos(value) or nil
	if value and type(value.xy) == "function" then pos = value end
	local x, y = PointXY(pos)
	data[prefix .. "_x"] = tostring(x)
	data[prefix .. "_y"] = tostring(y)
	local z
	if pos and type(pos.z) == "function" then z = SafeCall(pos.z, pos) end
	data[prefix .. "_z"] = tostring(z)
	return pos, x, y
end

local function TraversalClass(obj)
	return tostring(obj and (obj.class or obj.template_name) or "nil")
end

local function TraversalCommand(unit)
	if not unit then return "nil" end
	if unit.command ~= nil then return tostring(unit.command) end
	if type(unit.GetCommand) == "function" then return tostring(SafeCall(unit.GetCommand, unit)) end
	return "nil"
end

local function TraversalAddMapLightState(data, prefix, map)
	data[prefix .. "_map"] = tostring(map)
	data[prefix .. "_night_lights_state"] = tostring(map and map.NightLightsState)
	if not map or type(map.MapForEach) ~= "function" then return end
	local light_count, real_time_count, visible_count = 0, 0, 0
	local const_tbl = Global("const")
	local real_time_flag = type(const_tbl) == "table" and const_tbl.gofRealTimeAnim or nil
	local ok_scan = pcall(map.MapForEach, map, "map", "NightLightLight", function(light)
		light_count = light_count + 1
		if real_time_flag and type(light.GetGameFlags) == "function" then
			local flags = SafeCall(light.GetGameFlags, light, real_time_flag)
			if type(flags) == "number" and flags ~= 0 then real_time_count = real_time_count + 1 end
		end
		if type(light.GetVisible) == "function" and SafeCall(light.GetVisible, light) == true then
			visible_count = visible_count + 1
		end
	end)
	data[prefix .. "_scan_ok"] = tostring(ok_scan)
	data[prefix .. "_night_light_count"] = light_count
	data[prefix .. "_real_time_count"] = real_time_count
	data[prefix .. "_visible_count"] = visible_count
end

local function TraversalAddUnitLightState(data, prefix, unit)
	data[prefix .. "_night_light_object"] = tostring(IsKindOfSafe(unit, "NightLightObject"))
	data[prefix .. "_deferred_target"] = tostring(deferred_vehicle_night_lights[unit])
	if not unit then return end
	if type(unit.IsNightLightPossible) == "function" then
		data[prefix .. "_possible"] = tostring(SafeCall(unit.IsNightLightPossible, unit))
	end
	local const_tbl = Global("const")
	local enabled_flag = type(const_tbl) == "table" and const_tbl.gofNightLightsEnabled or nil
	if enabled_flag and type(unit.GetGameFlags) == "function" then
		data[prefix .. "_enabled_flag"] = tostring(
			SafeCall(unit.GetGameFlags, unit, enabled_flag))
	end
	local ok_attaches, attaches = false, nil
	if type(unit.GetAttaches) == "function" then ok_attaches, attaches = pcall(unit.GetAttaches, unit) end
	data[prefix .. "_attaches_ok"] = tostring(ok_attaches)
	data[prefix .. "_attach_count"] = type(attaches) == "table" and #attaches or 0
	local lights, details = 0, {}
	for _, attach in ipairs(type(attaches) == "table" and attaches or {}) do
		if IsKindOfSafe(attach, "NightLightLight") then
			lights = lights + 1
			if #details < 12 then
				local entity = type(attach.GetEntity) == "function"
					and SafeCall(attach.GetEntity, attach) or nil
				local attach_map = TraversalObjectMap(attach)
				local intensity = type(attach.GetIntensity) == "function"
					and SafeCall(attach.GetIntensity, attach) or nil
				details[#details + 1] = table.concat({
					tostring(attach), TraversalClass(attach), tostring(entity),
					"map=" .. tostring(attach_map), "intensity=" .. tostring(intensity),
				}, ":")
			end
		end
	end
	data[prefix .. "_light_attach_count"] = lights
	data[prefix .. "_light_attaches"] = table.concat(details, " | ")
end

local function TraversalSnapshot(unit, elevator, check_path)
	local unit_map, elevator_map = TraversalObjectMap(unit), TraversalObjectMap(elevator)
	local other = elevator and elevator.other or nil
	local other_map = TraversalObjectMap(other)
	local passage = elevator and elevator.passage or nil
	local data = {
		unit = tostring(unit), unit_class = TraversalClass(unit),
		unit_handle = tostring(unit and unit.handle), unit_command = TraversalCommand(unit),
		unit_valid = tostring(TraversalObjectValid(unit)), unit_map = tostring(unit_map),
		unit_map_slot = tostring(unit_map and unit_map.slot),
		elevator = tostring(elevator), elevator_class = TraversalClass(elevator),
		elevator_handle = tostring(elevator and elevator.handle),
		elevator_valid = tostring(TraversalObjectValid(elevator)),
		elevator_map = tostring(elevator_map), elevator_map_slot = tostring(elevator_map and elevator_map.slot),
		same_map = tostring(unit_map ~= nil and unit_map == elevator_map),
		elevator_destroyed = tostring(elevator and elevator.destroyed == true),
		elevator_demolishing = tostring(elevator and elevator.demolishing == true),
		elevator_working = tostring(elevator and elevator.working),
		elevator_ui_working = tostring(elevator and elevator.ui_working),
		elevator_grids_applied = tostring(elevator and elevator.grids_applied),
		other = tostring(other), other_class = TraversalClass(other),
		other_valid = tostring(TraversalObjectValid(other)),
		other_map = tostring(other_map), other_map_slot = tostring(other_map and other_map.slot),
		other_backlink = tostring(other and other.other == elevator),
		passage = tostring(passage), passage_class = TraversalClass(passage),
		passage_valid = tostring(TraversalObjectValid(passage)),
		passage_points_to_elevator = tostring(passage and passage.elevator == elevator),
	}
	TraversalAddPosition(data, "unit_pos", unit)
	TraversalAddPosition(data, "elevator_pos", elevator)
	TraversalAddPosition(data, "other_pos", other)
	local validate = Global("ValidateBuilding")
	if type(validate) == "function" then
		data.validate_building = tostring(SafeCall(validate, elevator) == elevator)
	end
	if elevator and type(elevator.HasPower) == "function" then
		data.has_power = tostring(SafeCall(elevator.HasPower, elevator) == true)
	end
	if elevator and type(elevator.HasPowerThisSide) == "function" then
		data.has_power_this_side = tostring(SafeCall(elevator.HasPowerThisSide, elevator) == true)
	end
	if other and type(other.HasPowerThisSide) == "function" then
		data.other_has_power_this_side = tostring(SafeCall(other.HasPowerThisSide, other) == true)
	end
	local entrance, chain
	if elevator and type(elevator.GetEntrancePos) == "function" then
		entrance, chain = SafeCall(elevator.GetEntrancePos, elevator, unit)
	end
	local entrance_pos, ex, ey = TraversalAddPosition(data, "entrance", entrance)
	data.entrance_valid = tostring(entrance_pos ~= nil and ex ~= false and ey ~= nil)
	data.entrance_chain_points = tostring(type(chain) == "table" and #chain or 0)
	if entrance_pos and elevator_map then
		local terrain_api = Global("terrain")
		if type(terrain_api) == "table" and type(terrain_api.IsPassable) == "function" then
			data.entrance_passable = tostring(
				SafeCall(terrain_api.IsPassable, elevator_map, entrance_pos) == true)
		end
		local world_to_hex = Global("WorldToHex")
		if type(world_to_hex) == "function" then
			local q, r = SafeCall(world_to_hex, entrance_pos)
			data.entrance_q, data.entrance_r = tostring(q), tostring(r)
			local buildable = elevator_map.buildable
			if buildable and type(buildable.GetZ) == "function"
				and type(q) == "number" and type(r) == "number" then
				data.entrance_buildable_z = tostring(SafeCall(buildable.GetZ, buildable, q, r))
			end
		end
	end
	local other_entrance, other_chain
	if other and type(other.GetEntrancePos) == "function" then
		other_entrance, other_chain = SafeCall(other.GetEntrancePos, other, unit)
	end
	local other_entrance_pos, oex, oey =
		TraversalAddPosition(data, "other_entrance", other_entrance)
	data.other_entrance_valid = tostring(
		other_entrance_pos ~= nil and oex ~= false and oey ~= nil)
	data.other_entrance_chain_points = tostring(
		type(other_chain) == "table" and #other_chain or 0)
	data.map_night_lights = tostring(unit_map and unit_map.NightLightsState)
	data.other_map_night_lights = tostring(other_map and other_map.NightLightsState)
	TraversalAddUnitLightState(data, "unit_light", unit)
	TraversalAddMapLightState(data, "unit_map_lights", unit_map)
	if other_map and other_map ~= unit_map then
		TraversalAddMapLightState(data, "other_map_lights", other_map)
	end
	if check_path and unit and entrance_pos then
		-- HasPath_NoDestlock mutates temporary path flags and pushes a destructor. The engine asserts
		-- unless it runs from this unit's command thread, so UI/interact diagnostics must never call it.
		local is_command_thread = Global("IsCommandThread")
		if type(is_command_thread) == "function"
			and SafeCall(is_command_thread, unit) ~= true then
			check_path = false
			data.path_probe_skipped = "not_unit_command_thread"
		end
	end
	if check_path and unit and entrance_pos then
		if type(unit.HasPath_NoDestlock) == "function" then
			local path = SafeCall(unit.HasPath_NoDestlock, unit, entrance_pos)
			data.has_path_no_destlock = tostring(path == true)
			data.has_path_no_destlock_raw = tostring(path)
		end
		local pf_api = Global("pf")
		if type(pf_api) == "table" and type(pf_api.HasPosPath) == "function" and unit_map then
			local pfclass = unit.pfclass
			if pfclass == nil and type(unit.GetProperty) == "function" then
				pfclass = SafeCall(unit.GetProperty, unit, "pfclass")
			end
			local path = SafeCall(pf_api.HasPosPath, unit_map, unit, entrance_pos, pfclass or 0)
			data.pf_has_pos_path = tostring(path == true)
			data.pf_has_pos_path_raw = tostring(path)
			data.pfclass = tostring(pfclass)
		end
	end
	return data, unit_map
end

local function RestoreElevatorTraversalDiagnostics()
	local State = SuperBigMap.State
	local patches = State.elevator_traversal_diagnostic_patches
	if type(patches) == "table" then
		for i = #patches, 1, -1 do
			local patch = patches[i]
			if patch.target and patch.target[patch.method] == patch.wrapper then
				patch.target[patch.method] = patch.original
			end
		end
	end
	State.elevator_traversal_diagnostic_patches = nil
	State.elevator_traversal_diagnostic_version = nil
end

local function PatchElevatorTraversalDiagnostics()
	local State = SuperBigMap.State
	local installed = State.elevator_traversal_diagnostic_patches
	if State.elevator_traversal_diagnostic_version == ELEVATOR_TRAVERSAL_DIAGNOSTIC_VERSION
		and type(installed) == "table" then
		local intact = #installed > 0
		for _, patch in ipairs(installed) do
			if not patch.target or patch.target[patch.method] ~= patch.wrapper then
				intact = false
				break
			end
		end
		if intact then return true end
	end
	RestoreElevatorTraversalDiagnostics()
	local patches, seen = {}, setmetatable({}, { __mode = "k" })
	local function install(target, method, label, make_wrapper)
		if type(target) ~= "table" or type(target[method]) ~= "function" then return false end
		local methods = seen[target]
		if not methods then methods = {}; seen[target] = methods end
		if methods[method] then return false end
		methods[method] = true
		local original = target[method]
		local wrapper = make_wrapper(original, label)
		target[method] = wrapper
		patches[#patches + 1] = {
			target = target, method = method, original = original, wrapper = wrapper, label = label,
		}
		return true
	end
	local function descendants_inclusive(base_name)
		local targets = {}
		local base = Engine.ClassTable and Engine.ClassTable(base_name)
		if type(base) == "table" then targets[#targets + 1] = { name = base_name, class = base } end
		local descendants = Global("ClassDescendants")
		if type(descendants) == "function" then
			pcall(descendants, base_name, function(name, class, output)
				if type(class) == "table" then output[#output + 1] = { name = name, class = class } end
			end, targets)
		end
		return targets
	end
	local function make_interaction_wrapper(original, label)
		return function(unit, obj, interaction_mode, ...)
			local trace = IsKindOfSafe(obj, "ElevatorBase")
				and TraversalIsExpandedContext(unit, obj)
			if trace then
				-- Interact runs directly from the UI mouse handler, before GetCommandFunc starts
				-- Unit:UseElevator. Record static state only; command-thread path probes happen later.
				local before = TraversalSnapshot(unit, obj, false)
				before.wrapper_target = label
				before.interaction_mode = tostring(interaction_mode)
				ElevatorTraversalAudit("VEHICLE_INTERACT_BEGIN", before, TraversalObjectMap(unit))
			end
			local results = PackValues(original(unit, obj, interaction_mode, ...))
			if trace then
				ElevatorTraversalAudit("VEHICLE_INTERACT_END", {
					wrapper_target = label, unit = tostring(unit), elevator = tostring(obj),
					result_1 = tostring(results[1]), result_2 = tostring(results[2]),
					unit_command = TraversalCommand(unit),
				}, TraversalObjectMap(unit))
			end
			return Unpack(results, 1, results.n)
		end
	end
	local function next_trace_id()
		State.elevator_traversal_trace_sequence =
			(tonumber(State.elevator_traversal_trace_sequence) or 0) + 1
		return State.elevator_traversal_trace_sequence
	end
	local function make_vehicle_use_wrapper(original, label)
		return function(unit, elevator, ...)
			if not TraversalIsExpandedContext(unit, elevator) then
				return original(unit, elevator, ...)
			end
			-- A descendant can explicitly call its BaseRover implementation. The outermost wrapper
			-- owns the trace so that one command produces one BEGIN/END pair.
			if elevator_traversal_by_unit[unit] then return original(unit, elevator, ...) end
			local trace = {
				id = next_trace_id(), building_use_entered = false,
				goto_entered = false, elevator = elevator,
			}
			elevator_traversal_by_unit[unit] = trace
			local before, before_map = TraversalSnapshot(unit, elevator, true)
			trace.before_map = before_map
			trace.same_map = before.same_map == "true"
			trace.entrance_valid = before.entrance_valid == "true"
			trace.path_available = before.has_path_no_destlock == "true"
			trace.other_valid = before.other_valid == "true"
			trace.building_valid = before.validate_building ~= "false"
			before.trace = trace.id
			before.wrapper_target = label
			ElevatorTraversalAudit("VEHICLE_USE_BEGIN", before, before_map)
			local results = PackValues(original(unit, elevator, ...))
			local after, after_map = TraversalSnapshot(unit, elevator, false)
			local transferred = before_map ~= nil and after_map ~= nil and before_map ~= after_map
			local outcome
			if transferred then outcome = "transferred"
			elseif trace.same_map == false then outcome = "unit_elevator_map_mismatch"
			elseif trace.entrance_valid == false then outcome = "elevator_entrance_invalid"
			elseif trace.goto_entered == true and trace.goto_result ~= true then
				outcome = "entrance_goto_failed"
			elseif trace.path_available == false then outcome = "entrance_path_unavailable"
			elseif trace.building_valid == false then outcome = "elevator_building_invalid"
			elseif trace.other_valid == false then outcome = "linked_counterpart_invalid"
			elseif trace.goto_entered ~= true then outcome = "entrance_goto_not_reached"
			elseif trace.building_use_entered ~= true then outcome = "elevator_building_use_not_reached"
			else outcome = "building_use_returned_without_map_transfer" end
			after.trace = trace.id
			after.wrapper_target = label
			after.outcome = outcome
			after.transferred = tostring(transferred)
			after.building_use_entered = tostring(trace.building_use_entered == true)
			after.goto_entered = tostring(trace.goto_entered == true)
			after.goto_result = tostring(trace.goto_result)
			after.result_1 = tostring(results[1])
			ElevatorTraversalAudit("VEHICLE_USE_END", after, after_map or before_map)
			elevator_traversal_by_unit[unit] = nil
			return Unpack(results, 1, results.n)
		end
	end
	local function make_vehicle_goto_wrapper(original, label)
		return function(unit, destination, ...)
			local trace = elevator_traversal_by_unit[unit]
			if not trace or (trace.goto_depth or 0) > 0 then
				return original(unit, destination, ...)
			end
			trace.goto_depth = 1
			trace.goto_entered = true
			local data = {
				trace = trace.id, wrapper_target = label, unit = tostring(unit),
				unit_class = TraversalClass(unit), unit_command = TraversalCommand(unit),
			}
			TraversalAddPosition(data, "unit_pos", unit)
			TraversalAddPosition(data, "goto_destination", destination)
			ElevatorTraversalAudit("VEHICLE_GOTO_BEGIN", data, TraversalObjectMap(unit))
			local results = PackValues(original(unit, destination, ...))
			trace.goto_result = results[1]
			trace.goto_depth = 0
			local after = {
				trace = trace.id, wrapper_target = label, unit = tostring(unit),
				result_1 = tostring(results[1]), unit_command = TraversalCommand(unit),
			}
			TraversalAddPosition(after, "unit_pos", unit)
			ElevatorTraversalAudit("VEHICLE_GOTO_END", after, TraversalObjectMap(unit))
			return Unpack(results, 1, results.n)
		end
	end
	local function make_building_use_wrapper(original, label)
		return function(elevator, unit, ...)
			if not TraversalIsExpandedContext(unit, elevator) then
				return original(elevator, unit, ...)
			end
			local trace = elevator_traversal_by_unit[unit]
			local trace_id = trace and trace.id or next_trace_id()
			if trace then trace.building_use_entered = true end
			local before, before_map = TraversalSnapshot(unit, elevator, false)
			before.trace = trace_id
			before.wrapper_target = label
			ElevatorTraversalAudit("BUILDING_USE_BEGIN", before, before_map)
			local results = PackValues(original(elevator, unit, ...))
			local after, after_map = TraversalSnapshot(unit, elevator, false)
			after.trace = trace_id
			after.wrapper_target = label
			after.transferred = tostring(before_map ~= nil and after_map ~= nil and before_map ~= after_map)
			after.result_1 = tostring(results[1])
			ElevatorTraversalAudit("BUILDING_USE_END", after, after_map or before_map)
			return Unpack(results, 1, results.n)
		end
	end

	local base_rover = Engine.ClassTable and Engine.ClassTable("BaseRover")
	install(base_rover, "InteractWithObject", "BaseRover", make_interaction_wrapper)
	local rover_use_targets, rover_goto_targets = 0, 0
	for _, entry in ipairs(descendants_inclusive("BaseRover")) do
		if install(entry.class, "UseElevator", tostring(entry.name), make_vehicle_use_wrapper) then
			rover_use_targets = rover_use_targets + 1
		end
		if install(entry.class, "Goto_NoDestlock", tostring(entry.name), make_vehicle_goto_wrapper) then
			rover_goto_targets = rover_goto_targets + 1
		end
	end
	local elevator_use_targets = 0
	for _, entry in ipairs(descendants_inclusive("ElevatorBase")) do
		if install(entry.class, "UseElevator", tostring(entry.name), make_building_use_wrapper) then
			elevator_use_targets = elevator_use_targets + 1
		end
	end
	State.elevator_traversal_diagnostic_patches = patches
	State.elevator_traversal_diagnostic_version = ELEVATOR_TRAVERSAL_DIAGNOSTIC_VERSION
	ElevatorTraversalAudit("PATCH_INSTALLED", {
		patches = #patches, rover_use_targets = rover_use_targets,
		rover_goto_targets = rover_goto_targets,
		elevator_use_targets = elevator_use_targets,
	}, Global("CurrentMap"))
	return rover_use_targets > 0 and elevator_use_targets > 0
end

function SuperBigMap.RockParityTraceEnabled(map)
	local config = SuperBigMap.Config or {}
	return config.TRACE_UNDERGROUND_ROCK_PARITY == true
		and type(map) == "table" and type(map.mapdata) == "table"
		and map.mapdata.Environment == "Underground"
end

function SuperBigMap.RockParityDescribeValues(values, first)
	local parts = {}
	for index = first or 1, tonumber(values and values.n) or 0 do
		local value = values[index]
		local value_type = type(value)
		if value_type == "nil" or value_type == "number" or value_type == "boolean"
			or value_type == "string" then
			parts[#parts + 1] = value_type .. ":" .. tostring(value)
		else
			parts[#parts + 1] = value_type .. ":" .. tostring(value)
		end
	end
	return table.concat(parts, "|")
end

function SuperBigMap.DescribeRockParityObject(object, class_name)
 local pos = object:GetPos()
 local x, y = PointXY(pos)
 local z
 pcall(function() z = pos:z() end)
 local rock = {
  class = tostring(class_name or object.class),
  x = tostring(x), y = tostring(y), z = tostring(z),
  scale = tostring(object:GetScale()), angle = tostring(object:GetAngle()),
 }
 rock.key = table.concat({
  rock.class, rock.x, rock.y, rock.z, rock.scale, rock.angle,
 }, "|")
 return rock
end

function SuperBigMap.CaptureRockParityObjectEntries(map)
 local classes = { "Rocks_04", "RemovableRocks_01", "RemovableRocks_02" }
 local entries = {}
 local by_object = {}
 local capture_index = 0
 for _, class_name in ipairs(classes) do
  local objects = map:MapGet("map", class_name) or {}
  for _, object in ipairs(objects) do
   capture_index = capture_index + 1
   local entry = {
    object = object,
    rock = SuperBigMap.DescribeRockParityObject(object, class_name),
    capture_index = capture_index,
   }
   entries[#entries + 1] = entry
   by_object[object] = entry
  end
 end
 table.sort(entries, function(a, b)
  if a.rock.key == b.rock.key then return a.capture_index < b.capture_index end
  return a.rock.key < b.rock.key
 end)
 local multiplicities = {}
 for _, entry in ipairs(entries) do
  local rock = entry.rock
  multiplicities[rock.key] = (multiplicities[rock.key] or 0) + 1
 end
 local ordinals = {}
 for _, entry in ipairs(entries) do
  local rock = entry.rock
  ordinals[rock.key] = (ordinals[rock.key] or 0) + 1
  rock.tuple_multiplicity = multiplicities[rock.key]
  rock.tuple_ordinal = ordinals[rock.key]
 end
 return entries, by_object
end

function SuperBigMap.CaptureRockParityObjectSet(map, phase)
 local tuples = {}
 local rocks = {}
 local entries = SuperBigMap.CaptureRockParityObjectEntries(map)
 for _, entry in ipairs(entries) do rocks[#rocks + 1] = entry.rock end
 table.sort(rocks, function(a, b) return a.key < b.key end)
 local multiplicities = {}
	for _, rock in ipairs(rocks) do
		multiplicities[rock.key] = (multiplicities[rock.key] or 0) + 1
	end
	local ordinals = {}
	for _, rock in ipairs(rocks) do
		ordinals[rock.key] = (ordinals[rock.key] or 0) + 1
		rock.tuple_multiplicity = multiplicities[rock.key]
		rock.tuple_ordinal = ordinals[rock.key]
		tuples[#tuples + 1] = rock.key
	end
	return { phase = tostring(phase), count = #rocks, tuples = tuples, rocks = rocks }
end

function SuperBigMap.CaptureRockParityMapDimensions(map)
 local dimensions = {
  reported_world_width = nil, reported_world_height = nil,
  source_view_world_width = map and map.Width,
  source_view_world_height = map and map.Height,
  source_view_hex_width = map and map.hex_width,
  source_view_hex_height = map and map.hex_height,
  retained_world_width = map and map.SuperBigMapExpandedWorldWidth,
  retained_world_height = map and map.SuperBigMapExpandedWorldHeight,
  retained_hex_width = map and map.SuperBigMapExpandedHexWidth,
  retained_hex_height = map and map.SuperBigMapExpandedHexHeight,
  mapdata_width_tiles = map and map.mapdata and map.mapdata.Width,
  mapdata_height_tiles = map and map.mapdata and map.mapdata.Height,
  generator_width_tiles = map and map.SuperBigMapGeneratorWidthTiles,
  generator_height_tiles = map and map.SuperBigMapGeneratorHeightTiles,
  desired_width_tiles = map and map.SuperBigMapDesiredWidthTiles,
  desired_height_tiles = map and map.SuperBigMapDesiredHeightTiles,
 }
 local get_map_size = map and map.GetMapSize
 if type(get_map_size) == "function" then
  local result = PackValues(pcall(get_map_size, map))
  if result[1] then
   dimensions.reported_world_width = result[2]
   dimensions.reported_world_height = result[3]
  else
   dimensions.get_map_size_error = tostring(result[2])
  end
 end
 return dimensions
end

function SuperBigMap.CaptureRockParityBoundary(map, phase)
	local boundary = SuperBigMap.CaptureRockParityObjectSet(map, phase)
	local class_counts = {}
	local objects = map:MapGet("map") or {}
	for _, object in ipairs(objects) do
		local class_name = object and object.class or "?"
		class_counts[class_name] = (class_counts[class_name] or 0) + 1
	end
	local class_names = {}
	for class_name in pairs(class_counts) do class_names[#class_names + 1] = class_name end
	table.sort(class_names)
	local census = {}
	for _, class_name in ipairs(class_names) do
		census[#census + 1] = tostring(class_name) .. "=" .. tostring(class_counts[class_name])
	end
	boundary.object_count = #objects
	boundary.class_count = #class_names
	boundary.class_census = census
	return boundary
end

function SuperBigMap.RockParityTraceMode(map)
	if type(map) ~= "table" then return "vanilla" end
	if map.SuperBigMapVanillaSourceMigration == true then return "expanded_source" end
	if map.SuperBigMapExpansionPending == true
		or map.SuperBigMapDesiredWidthTiles ~= nil
		or map.SuperBigMapOneToOneGenerationVersion ~= nil then
		return "expanded"
	end
	return "vanilla"
end

function SuperBigMap.RockParityTraceScalar(value, unavailable)
	if value == nil or value == false then return unavailable or "unavailable" end
	local text = tostring(value):gsub("[\r\n]+", " ")
	return text
end

function SuperBigMap.EmitRockParityTrace(event, data)
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.RockParity) == "function" then
		local ok, emitted = pcall(diagnostics.RockParity, event, data)
		return ok and emitted == true
	end
	return false
end

function SuperBigMap.RockParityTraceContext(trace, map, generator, procedure, ordinal)
	local mapdata = type(map) == "table" and map.mapdata or nil
	return {
  trace_schema = tostring(trace and trace.schema_version or 5),
		trace_invocation = tostring(trace and trace.invocation or 0),
		mode = tostring(trace and trace.mode or SuperBigMap.RockParityTraceMode(map)),
		environment = tostring(type(mapdata) == "table" and mapdata.Environment or "?"),
		procedure = tostring(procedure or "?"),
		procedure_ordinal = tostring(ordinal or 0),
		holder_seed = SuperBigMap.RockParityTraceScalar(
			type(generator) == "table" and generator.Seed or nil),
		holder_hash = SuperBigMap.RockParityTraceScalar(
			type(generator) == "table" and generator.GenerationHash or nil, "pending"),
	}
end

function SuperBigMap.RockParityTraceRecord(context, extra)
	local record = {}
	for key, value in pairs(type(context) == "table" and context or {}) do record[key] = value end
	for key, value in pairs(type(extra) == "table" and extra or {}) do record[key] = value end
	return record
end

function SuperBigMap.EmitRockParityRock(event, context, rock)
	if type(rock) ~= "table" then return false end
	return SuperBigMap.EmitRockParityTrace(event,
		SuperBigMap.RockParityTraceRecord(context, {
			class = rock.class, x = rock.x, y = rock.y, z = rock.z,
			scale = rock.scale, angle = rock.angle,
			tuple_multiplicity = tostring(rock.tuple_multiplicity or 0),
			tuple_ordinal = tostring(rock.tuple_ordinal or 0),
		}))
end

function SuperBigMap.EmitRockParityDelta(context, before, after)
	local before_by_key, after_by_key, keys = {}, {}, {}
	for _, rock in ipairs(type(before) == "table" and before.rocks or {}) do
		local item = before_by_key[rock.key]
		if not item then
			item = { rock = rock, count = 0 }
			before_by_key[rock.key] = item
			keys[rock.key] = true
		end
		item.count = item.count + 1
	end
	for _, rock in ipairs(type(after) == "table" and after.rocks or {}) do
		local item = after_by_key[rock.key]
		if not item then
			item = { rock = rock, count = 0 }
			after_by_key[rock.key] = item
			keys[rock.key] = true
		end
		item.count = item.count + 1
	end
	local ordered_keys = {}
	for key in pairs(keys) do ordered_keys[#ordered_keys + 1] = key end
	table.sort(ordered_keys)
	local added, removed = 0, 0
	for _, key in ipairs(ordered_keys) do
		local before_item, after_item = before_by_key[key], after_by_key[key]
		local before_count = before_item and before_item.count or 0
		local after_count = after_item and after_item.count or 0
		if after_count > before_count then
			for ordinal = before_count + 1, after_count do
				local rock = after_item.rock
				rock = {
					class = rock.class, x = rock.x, y = rock.y, z = rock.z,
					scale = rock.scale, angle = rock.angle,
					tuple_multiplicity = after_count, tuple_ordinal = ordinal,
				}
				SuperBigMap.EmitRockParityRock("ROCK_ADDED", context, rock)
				added = added + 1
			end
		elseif before_count > after_count then
			for ordinal = after_count + 1, before_count do
				local rock = before_item.rock
				rock = {
					class = rock.class, x = rock.x, y = rock.y, z = rock.z,
					scale = rock.scale, angle = rock.angle,
					tuple_multiplicity = before_count, tuple_ordinal = ordinal,
				}
				SuperBigMap.EmitRockParityRock("ROCK_REMOVED", context, rock)
				removed = removed + 1
			end
		end
	end
	return added, removed
end

function SuperBigMap.BeginRockParityTrace(map, env)
	if not SuperBigMap.RockParityTraceEnabled(map)
		or type(env) ~= "table" or type(env.rhelpers) ~= "table" then
		return nil
	end
	local trace = {
		schema = "smr.sbm.underground_rock_parity_trace",
		schema_version = 1,
		active = false,
		helper_calls = {},
		helper_call_count = 0,
		helper_call_cap = 12000,
		boundaries = {},
	}
	local history = map.SuperBigMapRockParityTraces
	if type(history) ~= "table" then
		history = {}
		map.SuperBigMapRockParityTraces = history
	end
	trace.invocation = #history + 1
	trace.proc_invoke_type = type(env.ProcInvoke)
	history[#history + 1] = trace
	local original_helpers = env.rhelpers
	local wrapped_helpers = {}
	for helper_index, helper in ipairs(original_helpers) do
		if type(helper) == "function" then
			local traced_helper_index = helper_index
			local original_helper = helper
			wrapped_helpers[traced_helper_index] = function(...)
				local args = PackValues(...)
				local results = PackValues(pcall(original_helper, Unpack(args, 1, args.n)))
				if trace.active then
					trace.helper_call_count = trace.helper_call_count + 1
					if #trace.helper_calls < trace.helper_call_cap then
						trace.helper_calls[#trace.helper_calls + 1] = {
							ordinal = trace.helper_call_count,
							helper = traced_helper_index,
							args = SuperBigMap.RockParityDescribeValues(args, 1),
							results = SuperBigMap.RockParityDescribeValues(results, 2),
						}
					end
				end
				if not results[1] then error(results[2]) end
				return Unpack(results, 2, results.n)
			end
		else
			wrapped_helpers[helper_index] = helper
		end
	end
	env.rhelpers = wrapped_helpers
	map.SuperBigMapRockParityTrace = trace
	return trace, original_helpers
end

function SuperBigMap.WrapRockParityProcInvoke(saved_proc, map, trace)
	return function(tag, func, randless)
		if tag ~= "PlaceDecors" or type(func) ~= "function" then
			return saved_proc(tag, func, randless)
		end
		return saved_proc(tag, function(...)
			trace.boundaries[#trace.boundaries + 1] =
				SuperBigMap.CaptureRockParityBoundary(map, "before")
			trace.active = true
			local results = PackValues(pcall(func, ...))
			trace.active = false
			trace.boundaries[#trace.boundaries + 1] =
				SuperBigMap.CaptureRockParityBoundary(map, "after")
			trace.captured_helper_calls = #trace.helper_calls
			trace.helper_calls_truncated = trace.helper_call_count > #trace.helper_calls
			if not results[1] then error(results[2]) end
			return Unpack(results, 2, results.n)
		end, randless)
	end
end

-- Stock ProcInvoke synchronously brackets every generator procedure with ProcStart/ProcEnd. This
-- default-off seam temporarily wraps those public boundaries for only the active generator
-- instance. It captures sorted rock records and prints deterministic one-line deltas without
-- invoking/replacing random helpers or mutating generated objects. At exact ordinal 13 it also
-- observes the stock overlap-removal MapForEach callback and the subsequent collection cascade.
-- It also proxies only the stock callback's already-issued GridGetMark/GetCollectionIndex calls
-- and reconstructs its persistent prefab-marker inputs without adding RNG or object operations,
-- then restores every temporary method/global on all outer success/error paths.
function SuperBigMap.CallDoGenerateWithRockParityTrace(original, self, map, ...)
	if not SuperBigMap.RockParityTraceEnabled(map) then
		return original(self, map, ...)
	end
	local trace = {
		schema = "smr.sbm.underground_rock_parity_trace",
		schema_version = 10,
		boundary_scope = "DoGenerate ProcStart/ProcEnd all procedures",
		attachment_method = "generator ProcStart/ProcEnd",
		in_progress = true,
		boundaries = {},
		procedures = {},
		procedure_count = 0,
		mode = SuperBigMap.RockParityTraceMode(map),
	}
	local history = map.SuperBigMapRockParityTraces
	if type(history) ~= "table" then
		history = {}
		map.SuperBigMapRockParityTraces = history
	end
	trace.invocation = #history + 1
	history[#history + 1] = trace
	map.SuperBigMapRockParityTrace = trace
	SuperBigMap.EmitRockParityTrace("TRACE_BEGIN",
		SuperBigMap.RockParityTraceRecord(
			SuperBigMap.RockParityTraceContext(trace, map, self, "DoGenerate", 0), {
				boundary_scope = trace.boundary_scope,
				attachment_method = trace.attachment_method,
			}))

 local generator_class = Global("RandomMapGenerator")
 local saved_proc_start = type(generator_class) == "table" and generator_class.ProcStart or nil
 local saved_proc_end = type(generator_class) == "table" and generator_class.ProcEnd or nil
	if type(saved_proc_start) ~= "function" or type(saved_proc_end) ~= "function" then
		trace.in_progress = false
		trace.attachment_error = "generator procedure boundary API unavailable"
  return original(self, map, ...)
 end

 local active_overlap_trace
	local function overlap_scalar(value, unavailable)
		if value == nil then return unavailable or "unavailable" end
		return tostring(value)
	end
	local function overlap_predicate(value, available)
		if available ~= true then return nil end
		return value == true
	end
 local function overlap_is_valid(object)
  local is_valid = Global("IsValid")
  if type(is_valid) ~= "function" then return nil end
  local result = PackValues(pcall(is_valid, object))
  if result[1] then return result[2] == true end
  return nil
 end
	local function overlap_collection_index(object)
  local get_collection_index = Global("GetCollectionIndex")
  if type(get_collection_index) ~= "function" then return nil end
  local result = PackValues(pcall(get_collection_index, object))
  if result[1] then return result[2] end
		return nil
	end
	local function overlap_capture_prefab_inputs(entry)
		if type(entry) ~= "table" then return end
		local object = entry.object
		local object_prefab_markers = type(map.obj_prefab_marker) == "table"
			and map.obj_prefab_marker or nil
		local prefab_marker = object_prefab_markers and object_prefab_markers[object] or nil
		entry.prefab_marker_present = prefab_marker ~= nil
		entry.prefab_marker_zone = prefab_marker and prefab_marker.zone or nil
		entry.own_mark_from_prefab_marker = prefab_marker and prefab_marker.place_mark or nil
		local ancestors_result = PackValues(pcall(function()
			return object and object.__ancestors
		end))
		local ancestors = ancestors_result[1] and ancestors_result[2] or nil
		entry.has_prefab_obj_ancestor = type(ancestors) == "table"
			and not not ancestors.PrefabObj or false
		local zone_allows_removal = Global("ZoneAllowsRemoval")
		if type(zone_allows_removal) == "function" and entry.prefab_marker_zone ~= nil then
			local removal_result = PackValues(pcall(
				zone_allows_removal, entry.prefab_marker_zone))
			if removal_result[1] then
				entry.zone_allows_removal = removal_result[2] == true
			else
				entry.prefab_input_error = tostring(removal_result[2])
			end
		end
		if entry.zone_allows_removal ~= nil then
			entry.removable_from_stock_inputs = entry.zone_allows_removal == true
				and entry.has_prefab_obj_ancestor ~= true
		end
	end
	local function restore_overlap_predicate_globals(overlap)
		if type(overlap) ~= "table" or overlap.predicate_globals_restored ~= nil then return end
		if overlap.predicate_globals_installed ~= true then
			overlap.predicate_globals_restored = false
			return
		end
		local restored, restore_error = pcall(function()
			overlap.predicate_write("GridGetMark", overlap.restore_grid_get_mark)
			overlap.predicate_write("GetCollectionIndex",
				overlap.restore_get_collection_index)
		end)
		if restored then
			local read_ok, grid_get_mark, get_collection_index = pcall(function()
				return overlap.predicate_read("GridGetMark"),
					overlap.predicate_read("GetCollectionIndex")
			end)
			restored = read_ok
				and grid_get_mark == overlap.original_grid_get_mark
				and get_collection_index == overlap.original_get_collection_index
		end
		overlap.predicate_globals_restored = restored == true
		if not restored then overlap.predicate_restore_error = tostring(restore_error) end
	end
	local function install_overlap_predicate_globals(overlap, callback)
		if type(overlap) ~= "table" or overlap.predicate_globals_attempted == true then return end
		overlap.predicate_globals_attempted = true
		local environment = FunctionEnvironment(callback)
		local predicate_read
		local predicate_write
		if type(environment) == "table" then
			predicate_read = function(name) return environment[name] end
			predicate_write = function(name, value) rawset(environment, name, value) end
			overlap.predicate_attachment_method = "function_environment"
		else
			local state = SuperBigMap.State
			local bridge_factory = type(state) == "table"
				and state.rock_parity_callback_upvalue_bridge or nil
			local bridge_ok, bridge = false, nil
			if type(bridge_factory) == "function" then
				bridge_ok, bridge = pcall(bridge_factory, callback)
			end
			if bridge_ok and type(bridge) == "table"
				and type(bridge.read) == "function" and type(bridge.write) == "function" then
				environment = bridge
				predicate_read = bridge.read
				predicate_write = bridge.write
				overlap.predicate_attachment_method = "callback_upvalue_bridge"
			end
		end
		if type(predicate_read) ~= "function" or type(predicate_write) ~= "function" then
			-- Relaunched hides the shipped callback's environment APIs from mod sandboxes.
			-- Use the same verified public __index/__newindex bridge as the additional-map seed
			-- patch: remove only our raw shadow while reading/writing the existing inherited
			-- global, then restore that shadow. Every write is synchronously read back.
			environment = _G
			predicate_read = function(name)
				local direct = rawget(environment, name)
				rawset(environment, name, nil)
				local ok, value = pcall(function() return environment[name] end)
				rawset(environment, name, direct)
				if not ok then error(value) end
				return value
			end
			predicate_write = function(name, value)
				local direct = rawget(environment, name)
				rawset(environment, name, nil)
				local write_ok, write_error = pcall(function() environment[name] = value end)
				local unexpected_direct = rawget(environment, name)
				rawset(environment, name, nil)
				local read_ok, inherited = pcall(function() return environment[name] end)
				rawset(environment, name, direct)
				if not write_ok then error(write_error) end
				if unexpected_direct ~= nil and unexpected_direct ~= value then
					error("sandbox bridge created an unexpected raw global")
				end
				if not read_ok or inherited ~= value then
					error("sandbox bridge write verification failed")
				end
			end
			overlap.predicate_attachment_method = "sandbox_inherited_bridge"
		end
		local read_ok, original_grid_get_mark, original_get_collection_index = pcall(function()
			return predicate_read("GridGetMark"), predicate_read("GetCollectionIndex")
		end)
		if not read_ok or type(original_grid_get_mark) ~= "function"
			or type(original_get_collection_index) ~= "function" then
			overlap.predicate_attach_error = "callback predicate API unavailable"
			return
		end
		overlap.predicate_environment = environment
		overlap.predicate_read = predicate_read
		overlap.predicate_write = predicate_write
		overlap.original_grid_get_mark = original_grid_get_mark
		overlap.original_get_collection_index = original_get_collection_index
		if overlap.predicate_attachment_method == "function_environment" then
			overlap.restore_grid_get_mark = rawget(environment, "GridGetMark")
			overlap.restore_get_collection_index = rawget(environment, "GetCollectionIndex")
		else
			overlap.restore_grid_get_mark = original_grid_get_mark
			overlap.restore_get_collection_index = original_get_collection_index
		end
		local wrapped_grid_get_mark = function(...)
			local args = PackValues(...)
			local results = PackValues(pcall(original_grid_get_mark, Unpack(args, 1, args.n)))
			local entry = overlap.active_predicate_entry
			if entry then
				entry.grid_get_mark_call_count = (entry.grid_get_mark_call_count or 0) + 1
				entry.grid_get_mark_object_matches = args[2] == entry.object
				if results[1] then
					if entry.current_mark == nil then entry.current_mark = results[2] end
				else
					entry.grid_get_mark_error = tostring(results[2])
				end
			end
			if not results[1] then error(results[2]) end
			return Unpack(results, 2, results.n)
		end
		local wrapped_get_collection_index = function(...)
			local args = PackValues(...)
			local results = PackValues(pcall(original_get_collection_index,
				Unpack(args, 1, args.n)))
			local entry = overlap.active_predicate_entry
			if entry then
				entry.callback_collection_lookup_count =
					(entry.callback_collection_lookup_count or 0) + 1
				entry.callback_collection_object_matches = args[1] == entry.object
				if results[1] then
					if entry.callback_collection_index == nil then
						entry.callback_collection_index = results[2]
					end
				else
					entry.callback_collection_error = tostring(results[2])
				end
			end
			if not results[1] then error(results[2]) end
			return Unpack(results, 2, results.n)
		end
		local installed, install_error = pcall(function()
			predicate_write("GridGetMark", wrapped_grid_get_mark)
			predicate_write("GetCollectionIndex", wrapped_get_collection_index)
		end)
		if not installed then
			overlap.predicate_attach_error = tostring(install_error)
			pcall(function()
				predicate_write("GridGetMark", overlap.restore_grid_get_mark)
				predicate_write("GetCollectionIndex", overlap.restore_get_collection_index)
			end)
			return
		end
		overlap.predicate_globals_installed = true
		overlap.wrapped_grid_get_mark = wrapped_grid_get_mark
		overlap.wrapped_get_collection_index = wrapped_get_collection_index
	end
	local function restore_overlap_map_for_each(overlap)
		if type(overlap) ~= "table" or overlap.map_for_each_restored ~= nil then return end
		restore_overlap_predicate_globals(overlap)
  local restored, restore_error = pcall(function()
   rawset(map, "MapForEach", overlap.previous_raw_map_for_each)
  end)
  overlap.map_for_each_restored = restored == true
  if not restored then overlap.restore_error = tostring(restore_error) end
  if active_overlap_trace == overlap then active_overlap_trace = nil end
 end
 local function emit_overlap_trace(item, procedure_completed)
  local overlap = type(item) == "table" and item.overlap_trace or nil
  if type(overlap) ~= "table" or overlap.emitted == true then return end
  overlap.emitted = true
  local dimensions_after = SuperBigMap.CaptureRockParityMapDimensions(map)
  local context = SuperBigMap.RockParityTraceContext(
   trace, map, self, item.procedure, item.ordinal)
  local dimensions = overlap.dimensions_before or {}
  SuperBigMap.EmitRockParityTrace("OVERLAP_TRACE_BEGIN",
   SuperBigMap.RockParityTraceRecord(context, {
    focused_object_count = tostring(#(overlap.entries or {})),
    map_for_each_call_count = tostring(overlap.map_for_each_call_count or 0),
    callback_wrapped = tostring(overlap.callback_wrapped == true),
    first_pass_completed = tostring(overlap.first_pass_completed == true),
    procedure_completed = tostring(procedure_completed == true),
    reported_world_width = overlap_scalar(dimensions.reported_world_width),
    reported_world_height = overlap_scalar(dimensions.reported_world_height),
    source_view_world_width = overlap_scalar(dimensions.source_view_world_width),
    source_view_world_height = overlap_scalar(dimensions.source_view_world_height),
    source_view_hex_width = overlap_scalar(dimensions.source_view_hex_width),
    source_view_hex_height = overlap_scalar(dimensions.source_view_hex_height),
    retained_world_width = overlap_scalar(dimensions.retained_world_width, "native_backing"),
    retained_world_height = overlap_scalar(dimensions.retained_world_height, "native_backing"),
    retained_hex_width = overlap_scalar(dimensions.retained_hex_width, "native_backing"),
    retained_hex_height = overlap_scalar(dimensions.retained_hex_height, "native_backing"),
    mapdata_width_tiles = overlap_scalar(dimensions.mapdata_width_tiles),
    mapdata_height_tiles = overlap_scalar(dimensions.mapdata_height_tiles),
    generator_width_tiles = overlap_scalar(dimensions.generator_width_tiles, "native_backing"),
    generator_height_tiles = overlap_scalar(dimensions.generator_height_tiles, "native_backing"),
    desired_width_tiles = overlap_scalar(dimensions.desired_width_tiles, "native_backing"),
    desired_height_tiles = overlap_scalar(dimensions.desired_height_tiles, "native_backing"),
   }))
  local visited_count, callback_removed_count, cascade_removed_count = 0, 0, 0
  for _, entry in ipairs(overlap.entries or {}) do
   local final_valid = overlap_is_valid(entry.object)
   entry.valid_at_proc_end = final_valid
   entry.removed_by_collection_cascade = entry.valid_after_first_pass == true
    and final_valid == false
   if entry.visited_by_first_map_for_each then visited_count = visited_count + 1 end
   if entry.removed_by_callback then callback_removed_count = callback_removed_count + 1 end
   if entry.removed_by_collection_cascade then cascade_removed_count = cascade_removed_count + 1 end
   local rock = entry.rock or {}
   SuperBigMap.EmitRockParityTrace("OVERLAP_OBJECT",
    SuperBigMap.RockParityTraceRecord(context, {
     class = rock.class, x = rock.x, y = rock.y, z = rock.z,
     scale = rock.scale, angle = rock.angle,
     tuple_multiplicity = tostring(rock.tuple_multiplicity or 0),
     tuple_ordinal = tostring(rock.tuple_ordinal or 0),
     visited_by_first_map_for_each = tostring(entry.visited_by_first_map_for_each == true),
     visit_count = tostring(entry.visit_count or 0),
     valid_before_callback = overlap_scalar(entry.valid_before_callback,
      entry.visited_by_first_map_for_each and "unavailable" or "not_visited"),
     valid_after_callback = overlap_scalar(entry.valid_after_callback,
      entry.visited_by_first_map_for_each and "unavailable" or "not_visited"),
     valid_after_first_pass = overlap_scalar(entry.valid_after_first_pass),
     valid_at_proc_end = overlap_scalar(entry.valid_at_proc_end),
     removed_by_callback = tostring(entry.removed_by_callback == true),
     removed_by_collection_cascade = tostring(entry.removed_by_collection_cascade == true),
				collection_index = overlap_scalar(entry.collection_index, "unavailable"),
				prefab_marker_present = tostring(entry.prefab_marker_present == true),
				prefab_marker_zone = overlap_scalar(entry.prefab_marker_zone),
				own_mark_from_prefab_marker = overlap_scalar(
					entry.own_mark_from_prefab_marker),
				has_prefab_obj_ancestor = tostring(entry.has_prefab_obj_ancestor == true),
				zone_allows_removal = overlap_scalar(entry.zone_allows_removal),
				removable_from_stock_inputs = overlap_scalar(
					entry.removable_from_stock_inputs),
				current_mark = overlap_scalar(entry.current_mark),
				current_mark_nonzero = overlap_scalar(overlap_predicate(
					entry.current_mark ~= 0, entry.current_mark ~= nil)),
				own_mark_present = tostring(entry.own_mark_from_prefab_marker ~= nil),
				own_mark_differs = overlap_scalar(overlap_predicate(
					entry.own_mark_from_prefab_marker ~= entry.current_mark,
					entry.current_mark ~= nil
						and entry.own_mark_from_prefab_marker ~= nil)),
				reconstructed_callback_predicates_pass = overlap_scalar(
					overlap_predicate(entry.current_mark ~= 0
						and entry.prefab_marker_present == true
						and entry.removable_from_stock_inputs == true
						and entry.own_mark_from_prefab_marker ~= nil
						and entry.own_mark_from_prefab_marker ~= entry.current_mark,
						entry.current_mark ~= nil
							and entry.removable_from_stock_inputs ~= nil)),
				grid_get_mark_call_count = tostring(entry.grid_get_mark_call_count or 0),
				grid_get_mark_object_matches = tostring(
					entry.grid_get_mark_object_matches == true),
				callback_collection_lookup_count = tostring(
					entry.callback_collection_lookup_count or 0),
				callback_collection_index = overlap_scalar(
					entry.callback_collection_index, "not_called"),
				callback_collection_object_matches = tostring(
					entry.callback_collection_object_matches == true),
				prefab_input_error = overlap_scalar(entry.prefab_input_error, "none"),
				grid_get_mark_error = overlap_scalar(entry.grid_get_mark_error, "none"),
				callback_collection_error = overlap_scalar(
					entry.callback_collection_error, "none"),
			}))
  end
  SuperBigMap.EmitRockParityTrace("OVERLAP_TRACE_END",
   SuperBigMap.RockParityTraceRecord(context, {
    focused_object_count = tostring(#(overlap.entries or {})),
    visited_count = tostring(visited_count),
    callback_removed_count = tostring(callback_removed_count),
    collection_cascade_removed_count = tostring(cascade_removed_count),
    map_for_each_call_count = tostring(overlap.map_for_each_call_count or 0),
			map_for_each_restored = tostring(overlap.map_for_each_restored == true),
			predicate_globals_attempted = tostring(
				overlap.predicate_globals_attempted == true),
			predicate_globals_installed = tostring(
				overlap.predicate_globals_installed == true),
			predicate_globals_restored = tostring(
				overlap.predicate_globals_restored == true),
			predicate_attachment_method = overlap_scalar(
				overlap.predicate_attachment_method, "none"),
			attach_error = overlap_scalar(overlap.attach_error, "none"),
			predicate_attach_error = overlap_scalar(
				overlap.predicate_attach_error, "none"),
			predicate_restore_error = overlap_scalar(
				overlap.predicate_restore_error, "none"),
    callback_error = overlap_scalar(overlap.callback_error, "none"),
    traversal_error = overlap_scalar(overlap.traversal_error, "none"),
    restore_error = overlap_scalar(overlap.restore_error, "none"),
    reported_world_width_after = overlap_scalar(dimensions_after.reported_world_width),
    reported_world_height_after = overlap_scalar(dimensions_after.reported_world_height),
   }))
 end
 local function finish_overlap_trace(item, procedure_completed)
  local overlap = type(item) == "table" and item.overlap_trace or nil
  if type(overlap) ~= "table" then return end
  restore_overlap_map_for_each(overlap)
  emit_overlap_trace(item, procedure_completed)
 end
 local function attach_overlap_trace(item)
  local overlap = {
   dimensions_before = SuperBigMap.CaptureRockParityMapDimensions(map),
   map_for_each_call_count = 0,
  }
  item.overlap_trace = overlap
  local capture_result = PackValues(pcall(SuperBigMap.CaptureRockParityObjectEntries, map))
  if not capture_result[1] then
   overlap.attach_error = "focused object capture failed: " .. tostring(capture_result[2])
   return
  end
  overlap.entries = capture_result[2]
  overlap.by_object = capture_result[3]
		for _, entry in ipairs(overlap.entries or {}) do
			entry.collection_index = overlap_collection_index(entry.object)
			overlap_capture_prefab_inputs(entry)
		end
  local saved_map_for_each = map.MapForEach
  if type(saved_map_for_each) ~= "function" then
   overlap.attach_error = "map MapForEach unavailable"
   return
  end
  overlap.previous_raw_map_for_each = rawget(map, "MapForEach")
  overlap.saved_map_for_each = saved_map_for_each
  local wrapped_map_for_each
  wrapped_map_for_each = function(target, ...)
   local args = PackValues(...)
   overlap.map_for_each_call_count = overlap.map_for_each_call_count + 1
   local callback_index
   for index = args.n, 1, -1 do
    if type(args[index]) == "function" then
     callback_index = index
     break
    end
   end
		if overlap.map_for_each_call_count == 1 and callback_index then
			local saved_callback = args[callback_index]
			install_overlap_predicate_globals(overlap, saved_callback)
			overlap.callback_wrapped = true
			args[callback_index] = function(object, ...)
				local entry = overlap.by_object and overlap.by_object[object]
     if entry then
      entry.visited_by_first_map_for_each = true
      entry.visit_count = (entry.visit_count or 0) + 1
      if entry.valid_before_callback == nil then
       entry.valid_before_callback = overlap_is_valid(object)
      end
      if entry.collection_index == nil then
       entry.collection_index = overlap_collection_index(object)
					end
				end
				overlap.active_predicate_entry = entry
				local results = PackValues(pcall(saved_callback, object, ...))
				overlap.active_predicate_entry = nil
     if entry then
      entry.valid_after_callback = overlap_is_valid(object)
      entry.removed_by_callback = entry.valid_before_callback == true
       and entry.valid_after_callback == false
     end
     if not results[1] then
      overlap.callback_error = tostring(results[2])
      error(results[2])
     end
     return Unpack(results, 2, results.n)
    end
   end
		local results = PackValues(pcall(saved_map_for_each, target, Unpack(args, 1, args.n)))
		if overlap.map_for_each_call_count == 1 then
			restore_overlap_predicate_globals(overlap)
    overlap.first_pass_completed = results[1] == true
    for _, entry in ipairs(overlap.entries or {}) do
     entry.valid_after_first_pass = overlap_is_valid(entry.object)
    end
   end
   if not results[1] then
    overlap.traversal_error = tostring(results[2])
    error(results[2])
   end
   return Unpack(results, 2, results.n)
  end
  local installed, install_error = pcall(rawset, map, "MapForEach", wrapped_map_for_each)
  if not installed then
   overlap.attach_error = "MapForEach install failed: " .. tostring(install_error)
   return
  end
  active_overlap_trace = overlap
 end

 local function capture_boundary(phase, procedure, ordinal)
		local result = PackValues(pcall(SuperBigMap.CaptureRockParityBoundary, map, phase))
		if result[1] then
			local boundary = result[2]
			boundary.procedure = tostring(procedure)
			boundary.procedure_ordinal = ordinal
			trace.boundaries[#trace.boundaries + 1] = boundary
			return boundary
		end
		trace.capture_errors = trace.capture_errors or {}
		trace.capture_errors[#trace.capture_errors + 1] = table.concat({
			tostring(procedure), tostring(ordinal), tostring(phase), tostring(result[2]),
		}, "|")
		return nil
	end
	local function read_last_rng_state(generator)
		local state = type(generator) == "table" and generator.rand_state or nil
		local last = state and state.Last
		if type(last) ~= "function" then return nil end
		local ok, value = pcall(last, state)
		if ok then return value end
		return nil
	end
	local proc_start_wrapper
	proc_start_wrapper = function(generator, tag, ...)
		local results = PackValues(pcall(saved_proc_start, generator, tag, ...))
		if not results[1] then error(results[2]) end
		if generator == self then
			trace.procedure_count = trace.procedure_count + 1
			local ordinal = trace.procedure_count
			local procedure = tostring(tag)
			local item = {
				procedure = procedure,
				ordinal = ordinal,
				rng_before = read_last_rng_state(generator),
			}
   item.before = capture_boundary("before", procedure, ordinal)
   trace.procedures[#trace.procedures + 1] = item
   if ordinal == 13 and procedure == "ApplyTerrain" then
    local overlap_result = PackValues(pcall(attach_overlap_trace, item))
    if not overlap_result[1] then
     item.overlap_trace = item.overlap_trace or {}
     item.overlap_trace.attach_error = tostring(overlap_result[2])
    end
   end
   local context = SuperBigMap.RockParityTraceContext(
				trace, map, generator, procedure, ordinal)
			SuperBigMap.EmitRockParityTrace("PROC_BOUNDARY",
				SuperBigMap.RockParityTraceRecord(context, {
					boundary = "start",
					pre_rock_count = tostring(item.before and item.before.count or "capture_error"),
					post_rock_count = "pending",
					pre_rng_last = SuperBigMap.RockParityTraceScalar(item.rng_before),
					post_rng_last = "pending",
				}))
		end
		return Unpack(results, 2, results.n)
	end
	local proc_end_wrapper
	proc_end_wrapper = function(generator, tag, ...)
		if generator == self then
			local item
			for index = #trace.procedures, 1, -1 do
				local candidate = trace.procedures[index]
				if candidate and candidate.completed ~= true
					and candidate.procedure == tostring(tag) then
					item = candidate
					break
				end
   end
   if item then
    if item.ordinal == 13 and item.procedure == "ApplyTerrain" then
     local overlap_result = PackValues(pcall(finish_overlap_trace, item, true))
     if not overlap_result[1] then
      trace.log_errors = trace.log_errors or {}
      trace.log_errors[#trace.log_errors + 1] = table.concat({
       item.procedure, tostring(item.ordinal), "overlap", tostring(overlap_result[2]),
      }, "|")
     end
    end
    item.rng_after = read_last_rng_state(generator)
				item.after = capture_boundary("after", item.procedure, item.ordinal)
				item.completed = true
				local context = SuperBigMap.RockParityTraceContext(
					trace, map, generator, item.procedure, item.ordinal)
				local delta_result = PackValues(pcall(
					SuperBigMap.EmitRockParityDelta, context, item.before, item.after))
				local added, removed = 0, 0
				if delta_result[1] then
					added, removed = delta_result[2] or 0, delta_result[3] or 0
				else
					trace.log_errors = trace.log_errors or {}
					trace.log_errors[#trace.log_errors + 1] = table.concat({
						item.procedure, tostring(item.ordinal), "delta", tostring(delta_result[2]),
					}, "|")
				end
				item.rocks_added = added
				item.rocks_removed = removed
				SuperBigMap.EmitRockParityTrace("PROC_BOUNDARY",
					SuperBigMap.RockParityTraceRecord(context, {
						boundary = "end",
						pre_rock_count = tostring(item.before and item.before.count or "capture_error"),
						post_rock_count = tostring(item.after and item.after.count or "capture_error"),
						pre_rng_last = SuperBigMap.RockParityTraceScalar(item.rng_before),
						post_rng_last = SuperBigMap.RockParityTraceScalar(item.rng_after),
						rocks_added = tostring(added), rocks_removed = tostring(removed),
					}))
			end
		end
		local results = PackValues(pcall(saved_proc_end, generator, tag, ...))
		if not results[1] then error(results[2]) end
		return Unpack(results, 2, results.n)
	end

	local installed, install_error = pcall(function()
		generator_class.ProcStart = proc_start_wrapper
		generator_class.ProcEnd = proc_end_wrapper
	end)
	if not installed then
		trace.in_progress = false
		trace.attachment_error = "procedure boundary install failed: " .. tostring(install_error)
		return original(self, map, ...)
 end
 local results = PackValues(pcall(original, self, map, ...))
 if active_overlap_trace then
  local restored, restore_error = pcall(restore_overlap_map_for_each, active_overlap_trace)
  if not restored then
   trace.restore_error = table.concat({
    tostring(trace.restore_error or ""), "overlap MapForEach: ", tostring(restore_error),
   })
  end
 end
 local restored, restore_error = pcall(function()
		generator_class.ProcStart = saved_proc_start
		generator_class.ProcEnd = saved_proc_end
	end)
	trace.in_progress = false
	trace.boundary_methods_restored = restored == true
	if not restored then trace.restore_error = tostring(restore_error) end
	local final_result = PackValues(pcall(SuperBigMap.CaptureRockParityObjectSet,
		map, "final_manifest"))
	if final_result[1] and type(final_result[2]) == "table" then
		trace.final_manifest = final_result[2]
		local manifest_context = SuperBigMap.RockParityTraceContext(
			trace, map, self, "DoGenerateFinal", trace.procedure_count + 1)
		local emit_result = PackValues(pcall(function()
			SuperBigMap.EmitRockParityTrace("ROCK_MANIFEST_BEGIN",
				SuperBigMap.RockParityTraceRecord(manifest_context, {
					focused_rock_count = tostring(trace.final_manifest.count),
				}))
			for _, rock in ipairs(trace.final_manifest.rocks or {}) do
				SuperBigMap.EmitRockParityRock("ROCK_MANIFEST", manifest_context, rock)
			end
			SuperBigMap.EmitRockParityTrace("ROCK_MANIFEST_END",
				SuperBigMap.RockParityTraceRecord(manifest_context, {
					focused_rock_count = tostring(trace.final_manifest.count),
				}))
		end))
		if not emit_result[1] then trace.log_error = tostring(emit_result[2]) end
	else
		trace.final_manifest_error = tostring(final_result[2])
	end
	local trace_context = SuperBigMap.RockParityTraceContext(
		trace, map, self, "DoGenerate", trace.procedure_count)
	pcall(SuperBigMap.EmitRockParityTrace, "TRACE_END",
		SuperBigMap.RockParityTraceRecord(trace_context, {
			procedure_count = tostring(trace.procedure_count),
			boundary_count = tostring(#trace.boundaries),
			boundary_methods_restored = tostring(trace.boundary_methods_restored == true),
			capture_error_count = tostring(#(trace.capture_errors or {})),
			log_error_count = tostring(#(trace.log_errors or {}) + (trace.log_error and 1 or 0)),
			final_rock_count = tostring(trace.final_manifest and trace.final_manifest.count or "capture_error"),
		}))
	if not restored and results[1] then
		results = { n = 2, false,
			"DoGenerate parity trace boundary restoration failed: " .. tostring(restore_error) }
	end
	if not results[1] then error(results[2]) end
	return Unpack(results, 2, results.n)
end

-- Instrument the generator's own procedure dispatcher while either focused tracing gate is on.
-- The wrapper is synchronous, restores env.ProcInvoke/rhelpers on every Lua success/error path,
-- and returns the exact original result tuple. With diagnostics off this is a direct tail call.
local function CallOnGenerateLogicTimed(original, self, env, map, ...)
	local diagnostics = SuperBigMap.Diagnostics
	local loading_enabled = diagnostics and type(diagnostics.LoadingEnabled) == "function"
		and diagnostics.LoadingEnabled() == true
	local retained_do_generate_trace = type(map) == "table"
		and type(map.SuperBigMapRockParityTrace) == "table"
		and map.SuperBigMapRockParityTrace.in_progress == true
		and map.SuperBigMapRockParityTrace.boundary_scope
			== "DoGenerate ProcStart/ProcEnd all procedures"
	local rock_trace, original_helpers
	if not retained_do_generate_trace then
		rock_trace, original_helpers = SuperBigMap.BeginRockParityTrace(map, env)
	end
	if not loading_enabled and not rock_trace then
		return original(self, env, ...)
	end
	local saved_proc = type(env) == "table" and env.ProcInvoke or nil
	local timed_proc
	if type(saved_proc) == "function" then
		local wrapped_proc = saved_proc
		if loading_enabled then
			local loading_proc = wrapped_proc
			wrapped_proc = function(tag, func, randless)
				if type(func) ~= "function" then return loading_proc(tag, func, randless) end
				return loading_proc(tag, function(...)
					local token = LoadingBegin("RandomMap procedure: " .. tostring(tag), map, {
						tag = tostring(tag), randless = tostring(randless),
					})
					local result = PackValues(pcall(func, ...))
					LoadingEnd(token, { tag = tostring(tag) }, result[1] == true)
					if not result[1] then error(result[2]) end
					return Unpack(result, 2, result.n)
				end, randless)
			end
		end
		if rock_trace then
			wrapped_proc = SuperBigMap.WrapRockParityProcInvoke(wrapped_proc, map, rock_trace)
		end
		timed_proc = wrapped_proc
		env.ProcInvoke = timed_proc
	end
	local token = loading_enabled and LoadingBegin("RandomMapGenerator.OnGenerateLogic", map) or nil
	local result = PackValues(pcall(original, self, env, ...))
	if timed_proc and env.ProcInvoke == timed_proc then env.ProcInvoke = saved_proc end
	if original_helpers and env.rhelpers ~= original_helpers then env.rhelpers = original_helpers end
	if loading_enabled then LoadingEnd(token, nil, result[1] == true) end
	if not result[1] then error(result[2]) end
	return Unpack(result, 2, result.n)
end

local function SignalExpansionReadinessChanged(map, reason)
	local msg = Global("Msg")
	local signaled = type(msg) == "function" and pcall(msg,
		"SuperBigMapExpansionReadinessChanged", map, reason) == true
	return signaled
end

local function cfg_number(key, default, min_value)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "number" and (min_value == nil or value >= min_value) then
		return value
	end
	return default
end

-- True only while a real stretch pipeline has been scheduled and has not completed. Used to
-- suppress full-map rebuilds whose results would immediately be discarded by that stretch.
local function ShouldDeferStretchRebuilds(map)
	return cfg_bool("OPTIMIZE_STRETCH_DEFERRED_REBUILDS", true)
		and type(map) == "table"
		and (map.SuperBigMapStretchPipelinePending == true
			or map.SuperBigMapUndergroundStretchPending == true)
end

-- Cheap final state refresh after the stretch's authoritative grid rebuilds. Deliberately does
-- not call Lifecycle.Apply(..., true) or RebuildMapBounds: those are the duplicate full-grid
-- passes this optimization removes. Sector boxes/play ratios and max object radius are refreshed.
local function FinalizeDeferredStretchState(map, phase)
	if not map then return false end
	local bounds = SuperBigMap.MapBounds
	if bounds then
		if type(bounds.ResetMapDataBounds) == "function" then SafeCall(bounds.ResetMapDataBounds, map, map.mapdata) end
		if type(bounds.ResetMapAreas) == "function" then SafeCall(bounds.ResetMapAreas, map) end
		if type(bounds.RefreshSectors) == "function" then SafeCall(bounds.RefreshSectors, map) end
	end
	local update_radius = Global("UpdateMapMaxObjRadius")
	if type(update_radius) == "function" then SafeCall(update_radius, map) end
	map.SuperBigMapStretchPipelinePending = false
	return true
end

local function TerrainSize(map)
	-- Map size = mapdata tiles x const.HeightTileSize (world units per tile). This is
	-- exactly how the engine reports map size (see MapData.lua) and is ASSERT-FREE.
	-- We must NOT call map:GetMapSize() OR terrain.GetMapSize(map): they are the SAME
	-- engine function (map.GetMapSize == terrain.GetMapSize) and it asserts
	-- "HGE::l_GetMapSize: Map expected" for some map objects -- the function-field
	-- check passes but the CALL asserts, and pcall cannot suppress that dialog.
	-- mapdata.Width is synced to the (expanded) grid size before this runs.
	local mapdata = map and map.mapdata
	local const_tbl = Global("const")
	local tile = type(const_tbl) == "table" and const_tbl.HeightTileSize or nil
	if type(mapdata) == "table" and type(mapdata.Width) == "number" and type(mapdata.Height) == "number"
		and type(tile) == "number" and tile > 0 then
		return mapdata.Width * tile, mapdata.Height * tile
	end

	return map and map.Width or 0, map and map.Height or 0
end

-- Terrain stretching + object transforms live in sbm_terrain_copy / sbm_object_clone,
-- loaded before this module. Bind the helpers called below (and re-exported through
-- MapGeneration for the lifecycle) to their original local names; assert presence so
-- a load-order mistake fails LOUDLY at startup, not as a deferred nil-call in gen.
local TerrainCopy = SuperBigMap.TerrainCopy
assert(type(TerrainCopy) == "table",
	"sbm_map_generation: SuperBigMap.TerrainCopy missing -- load sbm_terrain_copy before this file")
local SectorBoundary = TerrainCopy.SectorBoundary
local FindSectorByName = TerrainCopy.FindSectorByName
local ReinvalidateExpandedTerrain = TerrainCopy.ReinvalidateExpandedTerrain
local StretchSourceToFull = TerrainCopy.StretchSourceToFull
local StretchBiomeReady = TerrainCopy.StretchBiomeReady
local ScaleDecorationsToFull = TerrainCopy.ScaleDecorationsToFull
local ScaleMarkersToFull = TerrainCopy.ScaleMarkersToFull
local StretchRelocateStartSector = TerrainCopy.StretchRelocateStartSector
local MoveEntranceVisualsToScale = TerrainCopy.MoveEntranceVisualsToScale
local AlignPassagePairsToSharedHex = TerrainCopy.AlignPassagePairsToSharedHex
local PatchEntranceBadgePosition = TerrainCopy.PatchEntranceBadgePosition
local RestoreEntranceBadgePositionPatch = TerrainCopy.RestoreEntranceBadgePositionPatch
local RestoreEntranceBadgePositions = TerrainCopy.RestoreEntranceBadgePositions
local PatchCaveInShapePoints = TerrainCopy.PatchCaveInShapePoints
local RestoreCaveInShapePointsPatch = TerrainCopy.RestoreCaveInShapePointsPatch
local PatchUndergroundWonderShapePoints = TerrainCopy.PatchUndergroundWonderShapePoints
local RestoreUndergroundWonderShapePointsPatch = TerrainCopy.RestoreUndergroundWonderShapePointsPatch
local ScaleHexShapeForExpansion = TerrainCopy.ScaleHexShapeForExpansion
local BeginDeferredElevatorMigration = TerrainCopy.BeginDeferredElevatorMigration
local RestoreDeferredElevatorMigration = TerrainCopy.RestoreDeferredElevatorMigration
local AnnotateDecorRelief = TerrainCopy.AnnotateDecorRelief
local ClearDecorRelief = TerrainCopy.ClearDecorRelief
assert(type(ReinvalidateExpandedTerrain) == "function"
	and type(SectorBoundary) == "function" and type(FindSectorByName) == "function"
	and type(PatchCaveInShapePoints) == "function"
	and type(RestoreCaveInShapePointsPatch) == "function"
	and type(PatchUndergroundWonderShapePoints) == "function"
	and type(RestoreUndergroundWonderShapePointsPatch) == "function"
	and type(ScaleHexShapeForExpansion) == "function"
	and type(TerrainCopy.AuditNaturalMountainBaseBuildableAprons) == "function",
	"sbm_map_generation: required TerrainCopy helpers missing (check sbm_terrain_copy exports)")

local function StorePendingMap(map_name, pending)
	if map_name and map_name ~= "" then
		pending_maps[map_name] = pending
	end
end

local function ClearPendingMap(map_name)
	if map_name and map_name ~= "" then
		pending_maps[map_name] = nil
	end
end

local function ClearPreparedMapInstance(map)
	if type(map) ~= "table" then
		return false
	end
	local captured_clutter = map.SuperBigMapCapturedClutterGrid
	if captured_clutter then
		pcall(function()
			if type(captured_clutter.free) == "function" then captured_clutter:free() end
		end)
	end
	map.SuperBigMapCapturedClutterGrid = nil
	map.SuperBigMapCapturedClutterFill = nil
	map.SuperBigMapClutterGridStretched = nil
	map.SuperBigMapClutterGridStretchUnavailable = nil
	map.SuperBigMapExpansionPending = nil
	map.SuperBigMapNativeGenerationComplete = nil
	map.SuperBigMapNativeGenerationCompleteSource = nil
	map.SuperBigMapCityInitializationComplete = nil
	map.SuperBigMapGenerationReadinessVersion = nil
	map.SuperBigMapSurfaceStretchDone = nil
	map.SuperBigMapSurfaceStretchScheduled = nil
	map.SuperBigMapSurfaceStretchAwaitingReadiness = nil
	map.SuperBigMapSourceWidth = nil
	map.SuperBigMapSourceHeight = nil
	map.SuperBigMapSourceX = nil
	map.SuperBigMapSourceY = nil
	map.SuperBigMapOriginalWidthTiles = nil
	map.SuperBigMapOriginalHeightTiles = nil
	map.SuperBigMapSourceWidthTiles = nil
	map.SuperBigMapSourceHeightTiles = nil
	map.SuperBigMapDesiredWidthTiles = nil
	map.SuperBigMapDesiredHeightTiles = nil
	map.SuperBigMapPassageBootstrapComplete = nil
	map.SuperBigMapPassageBootstrapCount = nil
	map.SuperBigMapDeferredUndergroundWondersPending = nil
	map.SuperBigMapDeferredUndergroundWondersDone = nil
	map.SuperBigMapDeferredUndergroundWonderCount = nil
	map.SuperBigMapDeferredUndergroundWondersSpawned = nil
	map.SuperBigMapDeferredUndergroundWondersStretched = nil
	map.SuperBigMapDeferredBottomlessPitsStretched = nil
	map.SuperBigMapDeferredWonderAnomaliesDone = nil
	map.SuperBigMapDeferredWonderAnomaliesSpawned = nil
	map.SuperBigMapDeferredWonderAnomaliesAudited = nil
	map.SuperBigMapWonderLifecycleReseatDone = nil
	map.SuperBigMapWonderLifecycleReseatFailed = nil
	map.SuperBigMapZScaleUniform = nil
	map.SuperBigMapDeferredTunnelSpawnsPending = nil
	map.SuperBigMapDeferredTunnelSpawnCount = nil
	map.SuperBigMapGeneratorWidth = nil
	map.SuperBigMapGeneratorHeight = nil
	map.SuperBigMapGeneratorWidthTiles = nil
	map.SuperBigMapGeneratorHeightTiles = nil
	map.SuperBigMapExpandedWorldWidth = nil
	map.SuperBigMapExpandedWorldHeight = nil
	map.SuperBigMapExpandedHexWidth = nil
	map.SuperBigMapExpandedHexHeight = nil
	return true
end

-- The landing-screen toggle chooses whether the single stretch pipeline runs for
-- this new game. It does not select between expansion implementations.
local function ShouldExpandNewMap()
	local toggle = SuperBigMap.PregameToggle
	if toggle and type(toggle.ShouldExpandNewMap) == "function" then
		local ok, result = pcall(toggle.ShouldExpandNewMap)
		return ok and result == true
	end
	return false
end

local function RestorePreparedMapData(map_name, mapdata)
	if type(mapdata) ~= "table" then
		return false
	end
	local original_width = mapdata.SuperBigMapOriginalWidthTiles
		or mapdata.SuperBigMapOriginalMapDataWidth
		-- Older expanded saves can republish their shared MapData preset without the
		-- original-size annotation while retaining the equivalent source/generator
		-- dimensions. Use those legacy fields to recover the vanilla preset instead
		-- of leaving an orphaned 8192 allocation in the next new-game session.
		or mapdata.SuperBigMapSourceWidthTiles
		or mapdata.SuperBigMapGeneratorWidthTiles
	local original_height = mapdata.SuperBigMapOriginalHeightTiles
		or mapdata.SuperBigMapOriginalMapDataHeight
		or mapdata.SuperBigMapSourceHeightTiles
		or mapdata.SuperBigMapGeneratorHeightTiles
	if type(original_width) == "number" and original_width > 0 then
		mapdata.Width = original_width
	end
	if type(original_height) == "number" and original_height > 0 then
		mapdata.Height = original_height
	end
	if mapdata.SuperBigMapOriginalPassBorderCaptured == true then
		if mapdata.SuperBigMapOriginalPassBorderWasNil == true then
			mapdata.PassBorder = nil
		else
			mapdata.PassBorder = mapdata.SuperBigMapOriginalPassBorder
		end
		if mapdata.SuperBigMapOriginalPassBorderTilesWasNil == true then
			mapdata.PassBorderTiles = nil
		else
			mapdata.PassBorderTiles = mapdata.SuperBigMapOriginalPassBorderTiles
		end
	elseif mapdata.SuperBigMapOriginalPassBorder ~= nil then
		-- Legacy capture from an older in-process module version.
		mapdata.PassBorder = mapdata.SuperBigMapOriginalPassBorder
		local const_tbl = Global("const")
		local tile = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number" and const_tbl.HeightTileSize > 0)
			and const_tbl.HeightTileSize or 100
		if type(mapdata.PassBorderTiles) == "number" then
			mapdata.PassBorderTiles = math.floor((mapdata.PassBorder or 0) / tile)
		end
	end
	mapdata.SuperBigMapOriginalWidthTiles = nil
	mapdata.SuperBigMapOriginalHeightTiles = nil
	mapdata.SuperBigMapSourceWidthTiles = nil
	mapdata.SuperBigMapSourceHeightTiles = nil
	mapdata.SuperBigMapOriginalPassBorder = nil
	mapdata.SuperBigMapOriginalPassBorderCaptured = nil
	mapdata.SuperBigMapOriginalPassBorderWasNil = nil
	mapdata.SuperBigMapOriginalPassBorderTiles = nil
	mapdata.SuperBigMapOriginalPassBorderTilesWasNil = nil
	mapdata.SuperBigMapOriginalMapDataWidth = nil
	mapdata.SuperBigMapOriginalMapDataHeight = nil
	if mapdata.SuperBigMapOriginalOverviewAllowedCaptured == true then
		if mapdata.SuperBigMapOriginalOverviewAllowedWasNil == true then
			mapdata.IsAllowedToEnterOverview = nil
		else
			mapdata.IsAllowedToEnterOverview = mapdata.SuperBigMapOriginalOverviewAllowed
		end
		mapdata.SuperBigMapOriginalOverviewAllowed = nil
		mapdata.SuperBigMapOriginalOverviewAllowedWasNil = nil
		mapdata.SuperBigMapOriginalOverviewAllowedCaptured = nil
	end
	if mapdata.SuperBigMapOriginalHeightRangesCaptured == true then
		if type(mapdata.visible_height_range) == "table" then
			mapdata.visible_height_range.from = mapdata.SuperBigMapOriginalVisibleHeightFrom
			mapdata.visible_height_range.to = mapdata.SuperBigMapOriginalVisibleHeightTo
		end
		if type(mapdata.playable_height_range) == "table" then
			mapdata.playable_height_range.from = mapdata.SuperBigMapOriginalPlayableHeightFrom
			mapdata.playable_height_range.to = mapdata.SuperBigMapOriginalPlayableHeightTo
		end
		mapdata.SuperBigMapOriginalVisibleHeightFrom = nil
		mapdata.SuperBigMapOriginalVisibleHeightTo = nil
		mapdata.SuperBigMapOriginalPlayableHeightFrom = nil
		mapdata.SuperBigMapOriginalPlayableHeightTo = nil
		mapdata.SuperBigMapOriginalHeightRangesCaptured = nil
		mapdata.SuperBigMapHeightRangesScaled = nil
	end
	if mapdata.SuperBigMapOriginalTerrainHashCaptured == true then
		if mapdata.SuperBigMapOriginalTerrainHashWasNil == true then
			mapdata.terrain_hash = nil
		else
			mapdata.terrain_hash = mapdata.SuperBigMapOriginalTerrainHash
		end
		mapdata.SuperBigMapOriginalTerrainHash = nil
		mapdata.SuperBigMapOriginalTerrainHashWasNil = nil
		mapdata.SuperBigMapOriginalTerrainHashCaptured = nil
	end
	-- MapData presets are process-shared. Remove every mod-owned annotation so a later vanilla map
	-- receives the same property surface as it would after a fresh game launch.
	local mod_fields = {}
	for key, value in pairs(mapdata) do
		if value ~= nil and tostring(key):find("^SuperBigMap") then
			mod_fields[#mod_fields + 1] = key
		end
	end
	for i = 1, #mod_fields do mapdata[mod_fields[i]] = nil end
	ClearPendingMap(map_name)
	return true
end

-- MapData presets are shared process-wide.  Expansion changes their dimensions,
-- pass border and underground-overview flag; unloading a Map object does not recreate
-- those presets.  Restore every touched preset when returning to pregame so the next
-- map starts from the same inputs as a fresh vanilla process.
local function RestorePreparedMapDataForVanillaSession(reason)
	local restored, seen = 0, {}
	local function restore(name, mapdata)
		if type(mapdata) ~= "table" or seen[mapdata] then return end
		seen[mapdata] = true
		local touched = false
		for key, value in pairs(mapdata) do
			if value ~= nil and tostring(key):find("^SuperBigMap") then
				touched = true
				break
			end
		end
		if touched then
			RestorePreparedMapData(name, mapdata)
			restored = restored + 1
		end
	end
	local map_data = Global("MapData")
	if type(map_data) == "table" then
		for name, mapdata in pairs(map_data) do restore(name, mapdata) end
	end
	for _, global_name in ipairs({ "CurrentMap", "MainMap" }) do
		local map = Global(global_name)
		restore(map and map.name, map and map.mapdata)
	end
	local keys = {}
	for name in pairs(pending_maps) do keys[#keys + 1] = name end
	for i = 1, #keys do pending_maps[keys[i]] = nil end
	return restored
end

local function AlignDown(value, step)
	step = type(step) == "number" and step > 0 and step or 1
	return math.floor(value / step) * step
end

local function AttachPendingMapState(map)
	if not map then
		return false
	end
	-- The temporary source map deliberately shares the destination's BlankMap name, but must
	-- never inherit the name-keyed expanded pending record. Its native backing is the exact
	-- vanilla generator view and is discarded immediately after migration.
	if map.SuperBigMapVanillaSourceMigration == true then
		return false
	end

	local pending = pending_maps[map.name or false]
	if not pending then
		return false
	end

	map.SuperBigMapExpansionPending = true
	map.SuperBigMapNativeGenerationComplete = nil
	map.SuperBigMapNativeGenerationCompleteSource = nil
	map.SuperBigMapCityInitializationComplete = nil
	map.SuperBigMapGenerationReadinessVersion = SuperBigMap.GenerationReadiness.VERSION
	map.SuperBigMapSourceWidth = pending.source_width
	map.SuperBigMapSourceHeight = pending.source_height
	map.SuperBigMapSourceX = pending.source_x or 0
	map.SuperBigMapSourceY = pending.source_y or 0
	map.SuperBigMapOriginalWidthTiles = pending.original_width
	map.SuperBigMapOriginalHeightTiles = pending.original_height
	map.SuperBigMapSourceWidthTiles = pending.source_width_tiles
	map.SuperBigMapSourceHeightTiles = pending.source_height_tiles
	map.SuperBigMapDesiredWidthTiles = pending.desired_width
	map.SuperBigMapDesiredHeightTiles = pending.desired_height
	map.SuperBigMapGeneratorWidth = pending.generator_width
	map.SuperBigMapGeneratorHeight = pending.generator_height
	map.SuperBigMapGeneratorWidthTiles = pending.generator_width_tiles
	map.SuperBigMapGeneratorHeightTiles = pending.generator_height_tiles

	return true
end

local function IsEligibleMapData(map_slot, mapdata, map_instance)
	if not cfg_bool("ENABLE_TERRAIN_EXPANSION", false) then
		return false, "feature disabled"
	end

	-- Underground expansion (config STRETCH_UNDERGROUND): the underground map generates in its
	-- own slot with Environment=="Underground"; when the flag is on it is exempt from the
	-- main-slot-only and surface-only gates, so it gets the same 8192 allocation + native-capped
	-- generator as the surface (its stretch then applies the identical transform).
	local underground_ok = cfg_bool("STRETCH_UNDERGROUND", false)
		and type(mapdata) == "table" and mapdata.Environment == "Underground"

	if map_slot ~= 1 and not underground_ok then
		return false, "not the main map slot"
	end

	if not (map_instance and map_instance.RandomMapGenObject) then
		return false, "not a random map generation"
	end

	if type(mapdata) ~= "table" or mapdata.NoTerrain then
		return false, "missing terrain mapdata"
	end

	if mapdata.Environment ~= "Surface" and not underground_ok then
		return false, "not a surface map"
	end

	if type(mapdata.Width) ~= "number" or type(mapdata.Height) ~= "number" or mapdata.Width <= 0 or mapdata.Height <= 0 then
		return false, "invalid map dimensions"
	end

	if mapdata.Width ~= mapdata.Height then
		return false, "map is not square"
	end

	return true
end

local function PrepareMapDataForExpansion(map_slot, map_name, map_instance, source)
	map_instance = type(map_instance) == "table" and map_instance or {}
	local mapdata = map_instance.mapdata
	local map_data_table = Global("MapData")
	if not mapdata and type(map_data_table) == "table" then
		mapdata = map_data_table[map_name or false]
		map_instance.mapdata = mapdata
	end
	-- A Lua/session reload can discard the name-keyed pending record while an older
	-- expanded save republishes its annotated 8192 MapData preset. Normalize that
	-- orphan before eligibility/source-size decisions. A live pending record (or an
	-- explicitly prepared instance) belongs to the current generation and is kept.
	local pending_key = map_name or false
	if map_instance.RandomMapGenObject
		and map_instance.SuperBigMapExpansionPending ~= true
		and pending_maps[pending_key] == nil then
		RestorePreparedMapData(map_name, mapdata)
	end
	-- Keep the landing-site preview lightweight and vanilla-sized. Every real random
	-- map created after New Game uses the stretch-only expanded allocation below.
	if tostring(map_name or "") == "PreGame" then
		RestorePreparedMapData(map_name, mapdata)
		ClearPreparedMapInstance(map_instance)
		return false
	end
	if not ShouldExpandNewMap() then
		RestorePreparedMapData(map_name, mapdata)
		ClearPreparedMapInstance(map_instance)
		return false
	end

	local ok, reason = IsEligibleMapData(map_slot, mapdata, map_instance)
	if not ok then
		return false
	end

	local original_width = mapdata.SuperBigMapOriginalWidthTiles or mapdata.Width
	local original_height = mapdata.SuperBigMapOriginalHeightTiles or mapdata.Height
	local expanded_tiles = math.floor(cfg_number("EXPANDED_TERRAIN_TILES", 8192, 1))
	local renderer_align = math.floor(cfg_number("RENDERER_NODE_TILE_ALIGNMENT", 2048, 1))
	local desired_width = AlignDown(expanded_tiles, renderer_align)
	local desired_height = AlignDown(expanded_tiles, renderer_align)
	local source_width_tiles = original_width
	local source_height_tiles = original_height
	local generator_width_tiles = original_width
	local generator_height_tiles = original_height
	local height_tile_size = Global("const") and const.HeightTileSize or 1

	if desired_width <= original_width or desired_height <= original_height then
		mapdata.Width = original_width
		mapdata.Height = original_height
		pending_maps[map_name or false] = nil
		if not blocked_maps[map_name or false] then
			blocked_maps[map_name or false] = true
		end
		return false
	end

	if source_width_tiles <= 0 or source_height_tiles <= 0 then
		return false
	end
	-- Capture shared-preset values before any generation or expansion mutation.
	-- They must be restored byte-for-byte for the next vanilla game in this process.
	if mapdata.SuperBigMapOriginalPassBorderCaptured ~= true then
		mapdata.SuperBigMapOriginalPassBorderCaptured = true
		mapdata.SuperBigMapOriginalPassBorderWasNil = mapdata.PassBorder == nil
		mapdata.SuperBigMapOriginalPassBorder = mapdata.PassBorder
		mapdata.SuperBigMapOriginalPassBorderTilesWasNil = mapdata.PassBorderTiles == nil
		mapdata.SuperBigMapOriginalPassBorderTiles = mapdata.PassBorderTiles
	end
	if mapdata.SuperBigMapOriginalTerrainHashCaptured ~= true then
		mapdata.SuperBigMapOriginalTerrainHashCaptured = true
		mapdata.SuperBigMapOriginalTerrainHashWasNil = mapdata.terrain_hash == nil
		mapdata.SuperBigMapOriginalTerrainHash = mapdata.terrain_hash
	end

	mapdata.SuperBigMapOriginalWidthTiles = original_width
	mapdata.SuperBigMapOriginalHeightTiles = original_height
	mapdata.SuperBigMapSourceWidthTiles = source_width_tiles
	mapdata.SuperBigMapSourceHeightTiles = source_height_tiles
	mapdata.Width = desired_width
	mapdata.Height = desired_height

	-- The engine bakes a symmetric impassable border of mapdata.PassBorder into
	-- the passability grid at map-build time (the property help reads "requires a
	-- map restart to take effect"). On the expanded map that leaves a thick
	-- impassable ring around the whole playable area. FullMapPlayable wants the
	-- whole expanded terrain available, so zero PassBorder HERE, before generation
	-- builds passability, so no border
	-- is baked. The true original is preserved for restore (sbm_map_bounds's
	-- ResetMapDataBounds only captures SuperBigMapOriginalPassBorder when it is nil).
	-- Otherwise the engine bakes a ~1024-tile impassable ring. The engine's
	-- gameplay grids (heat, etc.) only cover [HeatGridBorder, size-HeatGridBorder], but we
	-- keep the map passable and instead CLAMP the heat query (sbm_heat_safety) so units in
	-- the outer strip don't crash Heat_Get. EXPANDED_MAP_EDGE_BORDER can set a positive
	-- impassable ring instead (rounded UP to a const.MapPatchSize multiple, required by the
	-- engine: l_EngineChangeMap asserts nPassBorder % MAP_PATCH == 0). 0 is always valid.
	do
		local const_tbl = Global("const")
		local patch = (type(const_tbl) == "table" and type(const_tbl.MapPatchSize) == "number" and const_tbl.MapPatchSize > 0)
			and const_tbl.MapPatchSize or nil
		local override = cfg_number("EXPANDED_MAP_EDGE_BORDER", -1)
		local want = (override > 0) and math.floor(override) or 0
		local safe_border = 0
		if want > 0 and patch then
			safe_border = math.floor((want + patch - 1) / patch) * patch -- round UP to a MapPatchSize multiple
		end
		local tile = (type(const_tbl) == "table" and type(const_tbl.HeightTileSize) == "number" and const_tbl.HeightTileSize > 0)
			and const_tbl.HeightTileSize or 100
		if type(mapdata.PassBorder) == "number" and mapdata.PassBorder ~= safe_border then
			if mapdata.SuperBigMapOriginalPassBorder == nil then
				mapdata.SuperBigMapOriginalPassBorder = mapdata.PassBorder
			end
			mapdata.PassBorder = safe_border
			if type(mapdata.PassBorderTiles) == "number" then
				mapdata.PassBorderTiles = (tile > 0) and math.floor(safe_border / tile) or 0
			end
		end
	end
	-- The vanilla source view and the proportional stretch share origin (0,0).
	local source_x, source_y = 0, 0

	local pending = {
		source_width = source_width_tiles * height_tile_size,
		source_height = source_height_tiles * height_tile_size,
		source_x = source_x,
		source_y = source_y,
		generator_width = generator_width_tiles * height_tile_size,
		generator_height = generator_height_tiles * height_tile_size,
		original_width = original_width,
		original_height = original_height,
		source_width_tiles = source_width_tiles,
		source_height_tiles = source_height_tiles,
		generator_width_tiles = generator_width_tiles,
		generator_height_tiles = generator_height_tiles,
		desired_width = desired_width,
		desired_height = desired_height,
	}
	StorePendingMap(map_name, pending)

	map_instance.SuperBigMapExpansionPending = true
	map_instance.SuperBigMapNativeGenerationComplete = nil
	map_instance.SuperBigMapNativeGenerationCompleteSource = nil
	map_instance.SuperBigMapCityInitializationComplete = nil
	map_instance.SuperBigMapGenerationReadinessVersion = SuperBigMap.GenerationReadiness.VERSION
	map_instance.SuperBigMapSourceWidth = pending.source_width
	map_instance.SuperBigMapSourceHeight = pending.source_height
	map_instance.SuperBigMapSourceX = source_x
	map_instance.SuperBigMapSourceY = source_y
	map_instance.SuperBigMapOriginalWidthTiles = original_width
	map_instance.SuperBigMapOriginalHeightTiles = original_height
	map_instance.SuperBigMapSourceWidthTiles = source_width_tiles
	map_instance.SuperBigMapSourceHeightTiles = source_height_tiles
	map_instance.SuperBigMapDesiredWidthTiles = desired_width
	map_instance.SuperBigMapDesiredHeightTiles = desired_height
	map_instance.SuperBigMapGeneratorWidth = pending.generator_width
	map_instance.SuperBigMapGeneratorHeight = pending.generator_height
	map_instance.SuperBigMapGeneratorWidthTiles = pending.generator_width_tiles
	map_instance.SuperBigMapGeneratorHeightTiles = pending.generator_height_tiles

	return true
end

local CaptureGeneratedNativeEnrichments

-- Finalize the expanded destination after native source generation: attach the
-- source/destination geometry, settle the engine, and re-apply bounds/sectors.
local function FinalizeExpandedMap(map)
	if map and not map.SuperBigMapExpansionPending then
		AttachPendingMapState(map)
	end

	if not map or not map.SuperBigMapExpansionPending then
		return false
	end

	local map_width, map_height = TerrainSize(map)
	local source_width = map.SuperBigMapSourceWidth or math.floor((map_width or 0) / 2)
	local source_height = map.SuperBigMapSourceHeight or math.floor((map_height or 0) / 2)
	if not map_width or not map_height or source_width <= 0 or source_height <= 0 then
		return false
	end
	if map_width <= source_width or map_height <= source_height then
		return false
	end

	-- Settle the engine after source generation: refresh the terrain hash and object
	-- radius, re-apply the full-map bounds/sector fit, and clear the allocation flag.
	-- The surface stretch runs after the generation/city readiness milestones.
	local terrain_api = Global("terrain")
	if terrain_api and type(terrain_api.HashGrids) == "function" and map.mapdata then
		if map.mapdata.SuperBigMapOriginalTerrainHashCaptured ~= true then
			map.mapdata.SuperBigMapOriginalTerrainHashCaptured = true
			map.mapdata.SuperBigMapOriginalTerrainHashWasNil = map.mapdata.terrain_hash == nil
			map.mapdata.SuperBigMapOriginalTerrainHash = map.mapdata.terrain_hash
		end
		map.mapdata.terrain_hash = SafeCall(terrain_api.HashGrids, map) or map.mapdata.terrain_hash
	end

	local update_radius = Global("UpdateMapMaxObjRadius")
	if type(update_radius) == "function" then
		SafeCall(update_radius, map)
	end

	local apply_bounds = (SuperBigMap.Lifecycle and SuperBigMap.Lifecycle.Apply) or Global("SuperBigMap_Apply")
	if type(apply_bounds) == "function" then
		local defer = ShouldDeferStretchRebuilds(map)
		SafeCall(apply_bounds, map, not defer)
	end

	map.SuperBigMapExpansionPending = false
	pending_maps[map.name or false] = nil
	CaptureGeneratedNativeEnrichments(map, "FinalizeExpandedMap")

	return true
end

CaptureGeneratedNativeEnrichments = function(map, label)
	if not cfg_bool("EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE", false) then return 0 end
	local grid = SuperBigMap.SectorGrid
	local is_destination = type(grid) == "table" and type(grid.IsModMap) == "function"
		and grid.IsModMap(map) == true
	local is_source_transaction = map and map.SuperBigMapVanillaSourceMigration == true
		or (SuperBigMap.State or {}).vanilla_source_migration_active == true
	if not is_destination and not is_source_transaction
		and not (map and map.SuperBigMapExpansionPending == true) then
		-- A normal vanilla-size run is not a source stage.  Do not annotate its
		-- markers or map object with SuperBigMap capture fields.
		return 0
	end
	local deposits = SuperBigMap.DepositRules
	if deposits and type(deposits.CaptureNativeEnrichmentPositions) == "function" then
		local ok, count = pcall(deposits.CaptureNativeEnrichmentPositions, map, label)
		if ok then return count or 0 end
	end
	if map then map.SuperBigMapNativeEnrichmentCapturePending = true end
	return 0
end

local function MigrationGridSize(grid)
	if not grid or type(grid.size) ~= "function" then return nil, nil end
	local ok, width, height = pcall(grid.size, grid)
	if not ok then return nil, nil end
	return width, height or width
end

local function FreeMigrationGrid(grid, raw)
	if grid and grid ~= raw and type(grid.free) == "function" then
		pcall(grid.free, grid)
	end
end

-- Copy the generated native terrain into the already allocated expanded backing. Unlike the
-- retired live-promotion experiment, both setter inputs are derived from the destination's own
-- grids, so their dimensions necessarily match the destination terrain and satisfy the engine's
-- SetHeightGrid/SetTypeGrid invariant.
local function CopyMigratedTerrain(source, destination)
	local terrain_api = Global("terrain")
	local grid_to_compute = Global("GridToCompute")
	local box_fn = Global("box")
	local point_fn = Global("point")
	if type(terrain_api) ~= "table"
		or type(terrain_api.GetHeightGrid) ~= "function"
		or type(terrain_api.SetHeightGrid) ~= "function"
		or type(terrain_api.GetTypeGrid) ~= "function"
		or type(terrain_api.SetTypeGrid) ~= "function"
		or type(grid_to_compute) ~= "function"
		or type(box_fn) ~= "function" or type(point_fn) ~= "function" then
		error("temporary source migration terrain API unavailable")
	end

	local source_height_raw = terrain_api.GetHeightGrid(source)
	local destination_height_raw = terrain_api.GetHeightGrid(destination)
	local source_type_raw = terrain_api.GetTypeGrid(source)
	local destination_type_raw = terrain_api.GetTypeGrid(destination)
	if not source_height_raw or not destination_height_raw or not source_type_raw or not destination_type_raw then
		error("temporary source migration could not capture all terrain grids")
	end

	local shw, shh = MigrationGridSize(source_height_raw)
	local dhw, dhh = MigrationGridSize(destination_height_raw)
	local stw, sth = MigrationGridSize(source_type_raw)
	local dtw, dth = MigrationGridSize(destination_type_raw)
	if not shw or not shh or not dhw or not dhh or shw > dhw or shh > dhh
		or not stw or not sth or not dtw or not dth or stw > dtw or sth > dth then
		error(string.format("temporary source grid dimensions do not fit destination: height %sx%s -> %sx%s; type %sx%s -> %sx%s",
			tostring(shw), tostring(shh), tostring(dhw), tostring(dhh),
			tostring(stw), tostring(sth), tostring(dtw), tostring(dth)))
	end

	local source_height = grid_to_compute(source_height_raw)
	local destination_height = grid_to_compute(destination_height_raw)
	local source_type = grid_to_compute(source_type_raw)
	local destination_type = grid_to_compute(destination_type_raw)
	if not source_height or not destination_height or not source_type or not destination_type then
		FreeMigrationGrid(source_height, source_height_raw)
		FreeMigrationGrid(destination_height, destination_height_raw)
		FreeMigrationGrid(source_type, source_type_raw)
		FreeMigrationGrid(destination_type, destination_type_raw)
		error("temporary source GridToCompute conversion failed")
	end

	local ok, err = pcall(function()
		destination_height:copyrect(source_height, box_fn(0, 0, shw, shh), point_fn(0, 0))
		destination_type:copyrect(source_type, box_fn(0, 0, stw, sth), point_fn(0, 0))
		local height_error = terrain_api.SetHeightGrid(destination, destination_height)
		if height_error then error("SetHeightGrid: " .. tostring(height_error)) end
		local type_error = terrain_api.SetTypeGrid(destination, destination_type)
		if type_error then error("SetTypeGrid: " .. tostring(type_error)) end
	end)
	FreeMigrationGrid(source_height, source_height_raw)
	FreeMigrationGrid(destination_height, destination_height_raw)
	FreeMigrationGrid(source_type, source_type_raw)
	FreeMigrationGrid(destination_type, destination_type_raw)
	if not ok then error(err) end
end

local function MapObjects(map)
	if not map or type(map.MapGet) ~= "function" then return nil, "MapGet unavailable" end
	local ok, objects = pcall(map.MapGet, map, "map")
	if not ok then
		return nil, tostring(objects)
	end
	-- The native MapGet contract returns nil when the query has no matches. A freshly loaded
	-- temporary blank map can legitimately contain zero enumerable map objects before generation.
	if objects == nil then
		return {}
	end
	if type(objects) ~= "table" then
		return nil, "MapGet returned " .. type(objects)
	end
	return objects
end

-- PrefabFeatureMarker:GameInit normally materializes feature-side game logic after native map
-- creation. The temporary surface source deliberately has no game logic, so transferred markers
-- never receive that callback on the destination. Replay the exact preset callback once after the
-- marker reaches its final transformed coordinate. This restores SafariSight and preserves any
-- other vanilla feature callback (currently geyser logic) without inventing content.
local function RestoreTransferredPrefabFeatureGameLogic(map)
	if not map then return false, { error = "map unavailable" } end
	local function ExactClassObjects(class_name)
		if type(map.MapGet) ~= "function" then return {} end
		local ok, objects = pcall(map.MapGet, map, "map", class_name)
		if not ok or type(objects) ~= "table" then return {} end
		local exact = {}
		for i = 1, #objects do
			local obj = objects[i]
			if obj and obj.class == class_name then exact[#exact + 1] = obj end
		end
		return exact
	end
	local function ObjectVisualXYZ(obj)
		if not obj then return nil end
		if type(obj.GetVisualPosXYZ) == "function" then
			local ok, x, y, z = pcall(obj.GetVisualPosXYZ, obj)
			if ok and type(x) == "number" and type(y) == "number" then return x, y, z end
		end
		local pos = type(obj.GetPos) == "function" and SafeCall(obj.GetPos, obj) or nil
		local x, y = PointXY(pos)
		local z
		if pos and type(pos.z) == "function" then
			local ok_z, value = pcall(pos.z, pos)
			if ok_z then z = value end
		end
		return x, y, z
	end
	local function SafariSightMatchesMarker(sight, marker, char)
		if not sight or sight.class ~= "SafariSight" then return false end
		local sx, sy = ObjectVisualXYZ(sight)
		local mx, my = ObjectVisualXYZ(marker)
		return sx == mx and sy == my
			and sight.sight_name == char.sight_name
			and sight.sight_category == char.sight_category
			and sight.sight_satisfaction == char.sight_satisfaction
			and sight.sight_visible_size == char.sight_visible_size
	end
	local feature_presets = Global("PrefabFeaturePresets")
	local char_presets = Global("PrefabFeatureCharPresets")
	if type(feature_presets) ~= "table" or type(char_presets) ~= "table" then
		return false, { error = "prefab feature presets unavailable" }
	end
	local markers = ExactClassObjects("PrefabFeatureMarker")
	local sights = ExactClassObjects("SafariSight")
	local used_sights = {}
	local expected_safari, created_safari, matched_safari, replayed_markers = 0, 0, 0, 0
	local removed_orphan_safari = 0
	local source_w = tonumber(map.SuperBigMapSourceWidthTiles)
		or tonumber(map.SuperBigMapGeneratorWidthTiles)
	local destination_w = tonumber(map.SuperBigMapDesiredWidthTiles)
		or (map.mapdata and tonumber(map.mapdata.Width))
	local object_scale = source_w and destination_w and source_w > 0
		and (destination_w + 0.0) / source_w or 1
	for i = 1, #markers do
		local marker = markers[i]
		local feature = feature_presets[marker.FeatureType]
		local chars = feature and feature.chars
		if type(chars) == "table" then
			local replay_all = marker.SuperBigMapTransferredFromNativeSource == true
				and marker.SuperBigMapPrefabFeatureGameLogicReplayed ~= true
			for j = 1, #chars do
				local char = char_presets[chars[j]]
				if char then
					local is_safari = char.class == "PrefabFeatureCharPreset_SafariSight"
					local matching_sight
					if is_safari then
						expected_safari = expected_safari + 1
						for k = 1, #sights do
							local sight = sights[k]
							if not used_sights[sight] and SafariSightMatchesMarker(sight, marker, char) then
								matching_sight = sight
								used_sights[sight] = true
								matched_safari = matched_safari + 1
								break
							end
						end
					end
					-- Older expanded saves lack the transfer stamp. Repair only their provably
					-- missing Safari sight so an already-running geyser thread is never duplicated.
					local should_call = replay_all or (is_safari and not matching_sight)
					if should_call and not (is_safari and matching_sight) then
						if type(char.GameLogic) ~= "function" then
							error("prefab feature GameLogic unavailable for " .. tostring(chars[j]))
						end
						local before = is_safari and ExactClassObjects("SafariSight") or nil
						local before_set = {}
						if before then for k = 1, #before do before_set[before[k]] = true end end
						local call_ok, call_err = pcall(char.GameLogic, char, marker)
						if not call_ok then
							error("prefab feature GameLogic failed for " .. tostring(chars[j])
								.. ": " .. tostring(call_err))
						end
						if is_safari then
							local after = ExactClassObjects("SafariSight")
							local created
							for k = 1, #after do
								if not before_set[after[k]] then created = after[k] break end
							end
							if not created or #after ~= #before + 1 then
								error("SafariSight recreation did not create exactly one object")
							end
							local mx, my, mz = ObjectVisualXYZ(marker)
							created.SuperBigMapNativeSourceX = marker.SuperBigMapNativeSourceX
								or (type(mx) == "number" and math.floor(mx / object_scale + 0.5) or nil)
							created.SuperBigMapNativeSourceY = marker.SuperBigMapNativeSourceY
								or (type(my) == "number" and math.floor(my / object_scale + 0.5) or nil)
							created.SuperBigMapNativeSourceZ = marker.SuperBigMapNativeSourceZ or mz
							created.SuperBigMapNativeSourceScale = 100
							created.SuperBigMapNativeSourceClass = "SafariSight"
							-- Third delivery path: feature GameLogic products are re-created from
							-- their marker after the transform, so they carry native provenance
							-- without ever passing through TransferGeneratedObjects. Record them in
							-- the same manifest, keyed on the SOURCE coordinate they inherit.
							if cfg_bool("NATIVE_SOURCE_MANIFEST", false) then
								local manifest = rawget(map, "SuperBigMapNativeSourceManifest")
								if type(manifest) ~= "table" then
									manifest = {}
									map.SuperBigMapNativeSourceManifest = manifest
								end
								manifest[#manifest + 1] = table.concat({
									"SafariSight",
									tostring(created.SuperBigMapNativeSourceX or 0),
									tostring(created.SuperBigMapNativeSourceY or 0),
									tostring(created.SuperBigMapNativeSourceZ or 0),
								}, ",")
								map.SuperBigMapNativeSourceManifestCount = #manifest
							end
							if type(created.SetScale) == "function" then
								SafeCall(created.SetScale, created,
									math.max(1, math.min(500, math.floor(100 * object_scale + 0.5))))
							end
							sights[#sights + 1] = created
							used_sights[created] = true
							created_safari = created_safari + 1
						end
					end
				end
			end
			if replay_all then
				marker.SuperBigMapPrefabFeatureGameLogicReplayed = true
				replayed_markers = replayed_markers + 1
			end
		end
	end
	-- A temporary native source can run PrefabFeatureMarker:GameInit before its marker is
	-- transferred.  The resulting SafariSight keeps the source coordinate and loses its marker
	-- parent when that temporary map is discarded.  Replaying GameLogic at the transformed marker
	-- then creates the required destination sight but otherwise leaves a second, orphaned sight in
	-- the expanded map.  Exact-class SafariSight objects are exclusively prefab-feature products;
	-- keep the one matched to each live marker and remove only unmatched products.  This is also an
	-- idempotent migration for expanded saves produced by the affected versions.
	local done_object = Global("DoneObject")
	if type(done_object) ~= "function" then
		return false, { error = "DoneObject unavailable for SafariSight correspondence" }
	end
	for i = 1, #sights do
		local sight = sights[i]
		if sight and not used_sights[sight] then
			local remove_ok = pcall(done_object, sight)
			if not remove_ok then
				return false, { error = "could not remove unmatched SafariSight" }
			end
			removed_orphan_safari = removed_orphan_safari + 1
		end
	end
	local final_sights = ExactClassObjects("SafariSight")
	local stats = {
		markers = #markers,
		expected_safari = expected_safari,
		actual_safari = #final_sights,
		matched_safari = matched_safari,
		created_safari = created_safari,
		removed_orphan_safari = removed_orphan_safari,
		replayed_markers = replayed_markers,
	}
	LoadingStep("prefab feature game logic correspondence", stats, map)
	if #final_sights ~= expected_safari then
		stats.error = "SafariSight count differs from vanilla feature count"
		return false, stats
	end
	return true, stats
end

local function SnapshotMapObjectSet(map)
	local objects, err = MapObjects(map)
	if not objects then error("could not snapshot map objects: " .. tostring(err)) end
	local set = {}
	for i = 1, #objects do set[objects[i]] = true end
	return set, #objects
end

function SuperBigMap.FreeOwnedGrid(grid)
	if grid and type(grid.free) == "function" then
		pcall(grid.free, grid)
	end
end

-- Surface passage placement happens during underground generation, after the temporary vanilla
-- surface map has been unloaded. Preserve the completed native buildable grid as value state so
-- SpawnUndergroundPassage can later make the same selection as vanilla. The retained grid is
-- short-lived: BootstrapPassagesAndDeferWonders consumes and frees it during the same new-game
-- generation transaction, and it is never persisted in a save.
function SuperBigMap.CaptureNativeSurfacePassageBuildable(source, destination)
	local buildable = source and source.buildable
	local grid = type(buildable) == "table" and buildable.z_grid or nil
	if not grid or type(grid.clone) ~= "function" or type(grid.size) ~= "function" then
		error("native surface passage buildable grid is unavailable")
	end
	local ok_size, width, height = pcall(grid.size, grid)
	height = height or width
	if not ok_size or type(width) ~= "number" or type(height) ~= "number"
		or width <= 0 or height <= 0 then
		error("native surface passage buildable dimensions are unavailable")
	end
	local ok_clone, clone = pcall(grid.clone, grid)
	if not ok_clone or not clone then
		error("native surface passage buildable clone failed: " .. tostring(clone))
	end
	local previous = destination.SuperBigMapPendingNativeSurfacePassageBuildable
	if type(previous) == "table" then SuperBigMap.FreeOwnedGrid(previous.grid) end
	destination.SuperBigMapPendingNativeSurfacePassageBuildable = {
		grid = clone,
		width = width,
		height = height,
	}
	LoadingStep("native surface passage buildable retained", {
		width = width, height = height,
	}, destination)
	return true
end

-- The buildable ANSWER can be captured as a value grid (above); the map's PASSABILITY field cannot
-- -- Lua sees no grid handle for it, only terrain.RebuildPassability. The passage fallback
-- (Lua/Pathfinding.lua:168 -> map:GetRandomPassablePoint) reads that native field, so on an
-- expanded map it draws from a passable set that is 61% different over the same source square
-- (measured, iter-011) and lands the second passage where vanilla could not. The only way to ask
-- the question against the source's own field is to keep the temporary native surface map LOADED
-- through the passage bootstrap and delegate the query to it. Retention is released as soon as the
-- bootstrap's selection window closes; the slot cost is one of the thirteen idle slots measured
-- free at that call (iter-012), never the one the underground phase uses.
local function ReleaseRetainedNativeSourceMap(surface_map, reason)
	local retention = type(surface_map) == "table"
		and surface_map.SuperBigMapRetainedNativeSourceMap or nil
	if type(retention) ~= "table" then return false end
	surface_map.SuperBigMapRetainedNativeSourceMap = nil
	local maps = Global("Maps")
	local change_map_in_slot = Global("ChangeMapInSlot")
	local slot = retention.slot
	if type(maps) ~= "table" or type(change_map_in_slot) ~= "function" or not slot then
		return false
	end
	if maps[slot] ~= retention.map then
		-- Something else already replaced the slot; never unload a map this transaction does not own.
		LoadingStep("retained vanilla source backing was already released", {
			source_slot = tostring(slot), reason = tostring(reason),
		}, surface_map)
		return false
	end
	local unload_token = LoadingBegin("unload retained vanilla source backing", surface_map, {
		source_slot = tostring(slot), reason = tostring(reason),
	})
	local unload_call_ok, unload_error = pcall(change_map_in_slot, slot, "")
	local unload_ok = unload_call_ok and unload_error == nil
	if not unload_ok and retention.pass_edits_deferred and retention.map
		and type(retention.map.ResumePassEdits) == "function" and maps[slot] == retention.map then
		-- Same compatibility retry the immediate unload path uses for a suspended pass-edit batch.
		if pcall(retention.map.ResumePassEdits, retention.map, "SuperBigMapVanillaSourceMigration") then
			unload_call_ok, unload_error = pcall(change_map_in_slot, slot, "")
			unload_ok = unload_call_ok and unload_error == nil
		end
	end
	LoadingEnd(unload_token, { error = tostring(unload_error) }, unload_ok)
	if not unload_ok then
		surface_map.SuperBigMapRetainedNativeSourceUnloadFailed = tostring(unload_error)
	end
	return unload_ok
end
SuperBigMap.ReleaseRetainedNativeSourceMap = ReleaseRetainedNativeSourceMap

local function TransferGeneratedObjects(source, destination, source_baseline, excluded_objects)
	local objects, err = MapObjects(source)
	if not objects then error("could not enumerate source objects: " .. tostring(err)) end
	local source_manifest = cfg_bool("NATIVE_SOURCE_MANIFEST", false) and {} or nil
	local is_valid = Global("IsValid")
	-- Engine MapVar helpers belong to whichever map loaded them, not to generated content:
	-- OnMsg.NewMap -> InitMapVarValue builds exactly one CameraObj per LOADED map
	-- (CommonLua/Classes/ActionFX.lua, CommonLua/Core/lib.lua). The temporary vanilla backing
	-- therefore owns one of its own. It is constructed without a position, so the baseline
	-- snapshot taken right after ChangeMapInSlot cannot enumerate it, and by transfer time it has
	-- a camera pose and looks like a generated root - which left the expanded surface with two
	-- cameras where the vanilla twin has one.
	local transfer_excluded = excluded_objects
	local source_camera = source and rawget(source, "g_CameraObj") or nil
	if source_camera and (type(is_valid) ~= "function" or is_valid(source_camera)) then
		transfer_excluded = {}
		if excluded_objects then
			for object, flag in pairs(excluded_objects) do transfer_excluded[object] = flag end
		end
		transfer_excluded[source_camera] = true
	end
	local roots, seen_roots = {}, {}
	local function resolve_generated_root(obj)
		local current, depth = obj, 0
		while current and depth < 64 do
			if transfer_excluded and transfer_excluded[current] then return nil, true end
			if type(current.GetParent) ~= "function" then break end
			local parent = SafeCall(current.GetParent, current)
			local parent_valid = parent and (type(is_valid) ~= "function" or is_valid(parent))
			if not parent_valid or (source_baseline and source_baseline[parent]) then break end
			current = parent
			depth = depth + 1
		end
		return current, false
	end
	for i = 1, #objects do
		local root = objects[i]
		local valid = type(is_valid) ~= "function" or is_valid(root)
		if valid and not (source_baseline and source_baseline[root]) then
			local excluded
			root, excluded = resolve_generated_root(root)
			if not excluded and root then
				if not seen_roots[root] then
					seen_roots[root] = true
					roots[#roots + 1] = root
				end
			end
		end
	end
	local transferred = 0
	local failed = 0
	local failures = {}
	-- TransferToMap removes the object from one map and inserts it into the other. With live
	-- pass edits, the engine updates spatial/passability state for every one of the ~20k decor
	-- roots individually. Batch both sides exactly like the later stretch mass-move transaction;
	-- ResumePassEdits performs one consolidated flush per map, and the authoritative destination
	-- RebuildGrids below still runs unchanged. If either API is absent or rejects suspension, that
	-- side transparently keeps the old per-object behavior.
	local pass_batch_reason = "SuperBigMapTemporarySourceObjectTransfer"
	local source_pass_batch, destination_pass_batch = false, false
	local function SuspendTransferPassEdits(map)
		if not map or type(map.SuspendPassEdits) ~= "function"
			or type(map.ResumePassEdits) ~= "function" then
			return false, "api unavailable"
		end
		local ok, result = pcall(map.SuspendPassEdits, map, pass_batch_reason)
		local active = ok and result ~= false
		return active, ok and nil or result
	end
	source_pass_batch = SuspendTransferPassEdits(source)
	destination_pass_batch = SuspendTransferPassEdits(destination)
	local transfer_loop_ok, transfer_loop_error = pcall(function()
		for i = 1, #roots do
			local obj = roots[i]
			local valid = type(is_valid) ~= "function" or is_valid(obj)
			if valid then
				-- Stamp the immutable vanilla transform and a stable source ordinal before map
				-- ownership changes. The decoration pass also stamps attached children, which are
				-- not separate transfer roots.
				local source_pos = type(obj.GetPos) == "function" and SafeCall(obj.GetPos, obj) or nil
				local source_x, source_y = PointXY(source_pos)
				if type(source_x) == "number" then obj.SuperBigMapNativeSourceX = source_x end
				if type(source_y) == "number" then obj.SuperBigMapNativeSourceY = source_y end
				if source_pos and type(source_pos.z) == "function" then
					local ok_z, source_z = pcall(source_pos.z, source_pos)
					if ok_z and type(source_z) == "number" then
						obj.SuperBigMapNativeSourceZ = source_z
					end
				end
				if type(obj.GetScale) == "function" then
					local source_scale = SafeCall(obj.GetScale, obj)
					if type(source_scale) == "number" then
						obj.SuperBigMapNativeSourceScale = source_scale
					end
				end
				if type(obj.GetAngle) == "function" then
					local source_angle = SafeCall(obj.GetAngle, obj)
					if type(source_angle) == "number" then
						obj.SuperBigMapNativeSourceAngle = source_angle
					end
				end
				obj.SuperBigMapNativeSourceClass = tostring(obj.class or "?")
				obj.SuperBigMapNativeSourceOrdinal = i
				if obj.class == "PrefabFeatureMarker" then
					obj.SuperBigMapTransferredFromNativeSource = true
				end
				if type(obj.TransferToMap) ~= "function" then
					failed = failed + 1
					if #failures < 8 then failures[#failures + 1] = tostring(obj.class) .. ":TransferToMap unavailable" end
				else
					-- The position argument is mandatory for static map objects. Omitting it is valid for
					-- rocket/unit flows that reposition after arrival, but it clears the position of terrain
					-- decorations. Those objects then disappear from spatial queries and are omitted from
					-- saves even though TransferToMap changed their map ownership successfully.
					local pos = type(obj.GetPos) == "function" and SafeCall(obj.GetPos, obj) or nil
					local ok, transfer_error = false, "position unavailable"
					if pos then
						ok, transfer_error = pcall(obj.TransferToMap, obj, destination, pos)
					end
					local landed = ok
					if landed and type(obj.GetMap) == "function" then
						landed = SafeCall(obj.GetMap, obj) == destination
					end
					if landed then
						transferred = transferred + 1
						-- Manifest of what the native source actually produced, recorded at the
						-- moment of migration. The post-transfer audit below already proves nothing
						-- FAILS to migrate; this proves nothing is destroyed AFTERWARDS, which a
						-- cross-process vanilla control cannot show on a map where stock generation
						-- is not reproducible. Diagnostic only: a plain array on the destination,
						-- never a MapVar, never saved.
						if source_manifest then
							local mx, my, mz = 0, 0, 0
							if pos then
								local ok_x, vx = pcall(pos.x, pos)
								local ok_y, vy = pcall(pos.y, pos)
								local ok_z, vz = pcall(pos.z, pos)
								mx = ok_x and vx or 0
								my = ok_y and vy or 0
								mz = ok_z and vz or 0
							end
							source_manifest[#source_manifest + 1] = table.concat({
								tostring(obj.class), tostring(mx), tostring(my), tostring(mz),
							}, ",")
						end
					else
						failed = failed + 1
						if #failures < 8 then
							failures[#failures + 1] = tostring(obj.class) .. ":" .. tostring(transfer_error or "wrong destination")
						end
					end
				end
			end
		end
	end)
	local resume_failures = {}
	local function ResumeTransferPassEdits(map, role, active)
		if not active then return true end
		local ok, result = pcall(map.ResumePassEdits, map, pass_batch_reason)
		if not ok then resume_failures[#resume_failures + 1] = role .. ":" .. tostring(result) end
		return ok
	end
	-- Reverse order of acquisition. Cleanup happens even if an unexpected Lua error escaped the loop.
	ResumeTransferPassEdits(destination, "destination", destination_pass_batch)
	ResumeTransferPassEdits(source, "source", source_pass_batch)
	if not transfer_loop_ok then
		error("temporary source object transfer loop failed: " .. tostring(transfer_loop_error))
	end
	if #resume_failures > 0 then
		error("temporary source object transfer pass-batch cleanup failed: " .. table.concat(resume_failures, " | "))
	end
	local remaining_objects, remaining_error = MapObjects(source)
	if not remaining_objects then error("could not audit source after object transfer: " .. tostring(remaining_error)) end
	local remaining_generated = 0
	for i = 1, #remaining_objects do
		if not (source_baseline and source_baseline[remaining_objects[i]]) then
			local _, excluded = resolve_generated_root(remaining_objects[i])
			if not excluded then
				remaining_generated = remaining_generated + 1
			end
		end
	end
	if failed > 0 or remaining_generated > 0 then
		error(string.format("temporary source object migration failed for %d objects: %s",
			failed + remaining_generated, table.concat(failures, " | ")))
	end
	destination.SuperBigMapNativeSourceObjectsTransferred = true
	if source_manifest then
		destination.SuperBigMapNativeSourceManifest = source_manifest
		destination.SuperBigMapNativeSourceManifestCount = #source_manifest
	end
	return transferred
end

local function FindTemporarySourceSlot(destination_slot)
	local maps = Global("Maps")
	local engine_config = Global("config")
	local max_slots = type(engine_config) == "table" and tonumber(engine_config.MapSlots) or 0
	max_slots = math.max(2, math.floor(max_slots or 0))
	for slot = max_slots, 2, -1 do
		if slot ~= destination_slot and type(maps) == "table" and maps[slot] == nil then
			return slot
		end
	end
	return nil
end

local function NewNativeSourceMapData(template, source_width, source_height, pass_border)
	local data = {}
	for key, value in pairs(template or {}) do
		if type(key) ~= "string" or not string.match(key, "^SuperBigMap") then
			data[key] = value
		end
	end
	data.Width = source_width
	data.Height = source_height
	data.PassBorder = pass_border
	local const_tbl = Global("const")
	local tile = type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize) or nil
	if type(data.PassBorderTiles) == "number" and tile and tile > 0 then
		data.PassBorderTiles = math.floor(pass_border / tile)
	end
	local preset = Global("MapDataPreset")
	if type(preset) == "table" and type(preset.new) == "function" then
		return preset:new(data)
	end
	return data
end

local function SupplyGridDimensions(grid)
	if not grid or type(grid.size) ~= "function" then return nil, nil end
	local ok, width, height = pcall(grid.size, grid)
	if not ok or type(width) ~= "number" then return nil, nil end
	return width, type(height) == "number" and height or width
end

local function IsExpandedSupplyContext(map)
	if type(map) ~= "table" then return false end
	local desired = map.SuperBigMapDesiredWidthTiles
	local generator = map.SuperBigMapGeneratorWidthTiles
	return map.SuperBigMapExpanded == true
		or (type(desired) == "number" and type(generator) == "number" and desired > generator)
end

local function SupplyObjectMap(obj)
	if type(obj) ~= "table" then return nil end
	local stored = rawget(obj, "map")
	if stored then return stored end
	local is_valid = Global("IsValid")
	if type(is_valid) == "function" and SafeCall(is_valid, obj) ~= true then return nil end
	if type(obj.GetMap) == "function" then return SafeCall(obj.GetMap, obj) end
	return nil
end

local function SupplyPointXY(point_value)
	if point_value == nil then return nil, nil end
	local ok, x, y = pcall(function() return point_value:xy() end)
	if ok and type(x) == "number" and type(y) == "number" then return x, y end
	if type(point_value) == "table" then
		x, y = rawget(point_value, "x"), rawget(point_value, "y")
		if type(x) == "number" and type(y) == "number" then return x, y end
	end
	return nil, nil
end

local function ValidateSupplyFragmentFootprint(connection_grid, fragment, resource)
	local elements = type(fragment) == "table" and rawget(fragment, "elements")
	if type(elements) ~= "table" then return 0, 0, 1 end
	local fragment_resource = fragment.supply_resource or resource
	local width, height = SupplyGridDimensions(connection_grid)
	local world_to_hex = Global("WorldToHex")
	local rotate = Global("HexRotate")
	local angle_to_direction = Global("HexAngleToDirection")
	local total_points, out_of_bounds, missing_shapes = 0, 0, 0
	for _, element in ipairs(elements) do
		local building = type(element) == "table" and rawget(element, "building") or nil
		local is_valid = Global("IsValid")
		local building_valid = building and (type(is_valid) ~= "function" or SafeCall(is_valid, building) == true)
		local pos = building_valid and Engine.ObjectPos(building) or nil
		local px, py = SupplyPointXY(pos)
		local q, r
		if type(world_to_hex) == "function" and building_valid then
			q, r = SafeCall(world_to_hex, building)
			if type(q) ~= "number" and type(px) == "number" then
				q, r = SafeCall(world_to_hex, px, py)
			end
		end
		local direction = type(angle_to_direction) == "function" and building_valid
			and SafeCall(angle_to_direction, building) or nil
		local shape
		if building_valid and type(building.GetSupplyGridConnectionShapePoints) == "function" then
			local ok, result = pcall(building.GetSupplyGridConnectionShapePoints,
				building, fragment_resource)
			if ok then shape = result end
		end
		if type(shape) ~= "table" then missing_shapes = missing_shapes + 1 end
		if type(shape) == "table" and type(q) == "number" and type(r) == "number" then
			for _, shape_point in ipairs(shape) do
				local local_q, local_r = SupplyPointXY(shape_point)
				local rotated_q, rotated_r = local_q, local_r
				if type(rotate) == "function" and type(direction) == "number"
					and type(local_q) == "number" and type(local_r) == "number" then
					rotated_q, rotated_r = SafeCall(rotate, local_q, local_r, direction)
				end
				local final_q = type(rotated_q) == "number" and q + rotated_q or nil
				local final_r = type(rotated_r) == "number" and r + rotated_r or nil
				local sx = type(final_q) == "number" and type(final_r) == "number"
					and final_q + final_r / 2 or nil
				local sy = final_r
				local in_bounds = type(sx) == "number" and type(sy) == "number"
					and type(width) == "number" and type(height) == "number"
					and sx >= 0 and sy >= 0 and sx < width and sy < height
				total_points = total_points + 1
				if not in_bounds then out_of_bounds = out_of_bounds + 1 end
			end
		end
	end
	return total_points, out_of_bounds, missing_shapes
end

local function CaptureSupplyGridRefs(map)
	local connections = type(map) == "table" and rawget(map, "supply_connection_grid") or nil
	return {
		map = map,
		connections = connections,
		electricity = type(connections) == "table" and connections.electricity or nil,
		water = type(connections) == "table" and connections.water or nil,
		overlay = type(map) == "table" and rawget(map, "supply_overlay_grid") or nil,
		object = type(map) == "table" and rawget(map, "object_hex_grid") or nil,
	}
end

local function SupplyRefSet(refs)
	local set = {}
	for _, name in ipairs({ "connections", "electricity", "water", "overlay", "object" }) do
		local value = type(refs) == "table" and refs[name] or nil
		if value ~= nil then set[value] = name end
	end
	return set
end

local function QueueUndergroundElevatorRestore(map, records, source)
	if type(map) ~= "table" or type(records) ~= "table" or #records == 0 then return nil end
	local State = SuperBigMap.State
	local old = pending_underground_elevator_restores[map]
	if type(old) == "table" and old.token_id then
		old.cancelled = true
		old.status = "superseded"
		underground_elevator_restore_tokens[old.token_id] = nil
	end
	State.underground_elevator_restore_epoch =
		(State.underground_elevator_restore_epoch or 0) + 1
	local source_map = Global("CurrentMap")
	if source_map == map then source_map = Global("MainMap") end
	local token = {
		token_id = State.underground_elevator_restore_epoch,
		map = map,
		records = records,
		source = tostring(source or "unknown"),
		source_map = source_map,
		forbidden_refs = SupplyRefSet(CaptureSupplyGridRefs(source_map)),
		status = "queued",
		connected = setmetatable({}, { __mode = "k" }),
		merged = setmetatable({}, { __mode = "k" }),
	}
	pending_underground_elevator_restores[map] = token
	underground_elevator_restore_tokens[token.token_id] = token
	map.SuperBigMapDeferredElevatorRestorePending = #records
	map.SuperBigMapDeferredElevatorRestoreToken = token.token_id
	ExpansionAudit("RESTORE_TOKEN_QUEUED", {
		token = token.token_id, records = #records, source = token.source,
		current_map_is_target = tostring(Global("CurrentMap") == map),
		source_map = tostring(source_map), forbidden_grid_refs = tostring(token.forbidden_refs),
	}, map)
	for index, record in ipairs(records) do
		local passage_pos = record.underground_passage and Engine.ObjectPos(record.underground_passage)
		local passage_x, passage_y = SupplyPointXY(passage_pos)
		ExpansionAudit("RESTORE_TOKEN_RECORD", {
			token = token.token_id, record = index,
			surface_x = tostring(record.surface_x), surface_y = tostring(record.surface_y),
			underground_passage_x = tostring(passage_x),
			underground_passage_y = tostring(passage_y),
			angle = tostring(record.angle), restored = tostring(record.restored == true),
		}, map)
	end
	return token
end

local function CurrentElevatorRestoreToken(map, token_id)
	local token = type(map) == "table" and pending_underground_elevator_restores[map] or nil
	if type(token) ~= "table" or token.token_id == nil then return nil end
	if token_id ~= nil and token.token_id ~= token_id then return nil end
	if token.cancelled == true or underground_elevator_restore_tokens[token.token_id] ~= token then
		return nil
	end
	return token
end

local function SupplyGridSetFailure(token, stage, reason)
	ExpansionAudit("SUPPLY_INVARIANT_FAILED", {
		token = tostring(type(token) == "table" and token.token_id or nil),
		stage = tostring(stage), reason = tostring(reason),
		status = tostring(type(token) == "table" and token.status or nil),
		current_map = tostring(Global("CurrentMap")),
	}, type(token) == "table" and token.map or nil)
	return false, tostring(reason)
end

local function ValidateSupplyGridSet(token, map, stage, require_current)
	if type(token) ~= "table" or CurrentElevatorRestoreToken(token.map, token.token_id) ~= token then
		return SupplyGridSetFailure(token, stage, "stale or superseded map-generation token")
	end
	if map ~= token.map and map ~= token.source_map then
		return SupplyGridSetFailure(token, stage, "grid owner is outside the restore transaction")
	end
	if require_current ~= false and Global("CurrentMap") ~= token.map then
		return SupplyGridSetFailure(token, stage, "the intended underground map is not current")
	end
	local refs = CaptureSupplyGridRefs(map)
	local expected_width = type(map) == "table" and tonumber(rawget(map, "hex_width")) or nil
	local expected_height = type(map) == "table" and tonumber(rawget(map, "hex_height")) or nil
	if not expected_width or not expected_height then
		return SupplyGridSetFailure(token, stage, "map hex dimensions are unavailable")
	end
	if type(refs.connections) ~= "table" or not refs.electricity or not refs.water
		or not refs.overlay or not refs.object then
		return SupplyGridSetFailure(token, stage, "one or more supply MapVars are unavailable")
	end
	for _, name in ipairs({ "electricity", "water", "overlay", "object" }) do
		local width, height = SupplyGridDimensions(refs[name])
		if width ~= expected_width or height ~= expected_height then
			return SupplyGridSetFailure(token, stage,
				name .. " grid dimensions differ from the owning map")
		end
	end
	if map == token.map then
		for _, name in ipairs({ "connections", "electricity", "water", "overlay", "object" }) do
			local forbidden_owner = token.forbidden_refs and token.forbidden_refs[refs[name]]
			if forbidden_owner then
				return SupplyGridSetFailure(token, stage,
					"target map retains a surface-grid reference")
			end
		end
		if token.authoritative_refs then
			for _, name in ipairs({ "connections", "electricity", "water", "overlay", "object" }) do
				if token.authoritative_refs[name] ~= refs[name] then
					return SupplyGridSetFailure(token, stage,
						"target supply-grid reference changed during the transaction")
				end
			end
		else
			token.authoritative_refs = refs
		end
	end
	local electricity_w, electricity_h = SupplyGridDimensions(refs.electricity)
	local water_w, water_h = SupplyGridDimensions(refs.water)
	local overlay_w, overlay_h = SupplyGridDimensions(refs.overlay)
	local object_w, object_h = SupplyGridDimensions(refs.object)
	ExpansionAudit("SUPPLY_GRID_SET_VALID", {
		token = token.token_id, stage = tostring(stage), status = tostring(token.status),
		require_current = tostring(require_current ~= false),
		expected_dimensions = tostring(expected_width) .. "x" .. tostring(expected_height),
		electricity_dimensions = tostring(electricity_w) .. "x" .. tostring(electricity_h),
		water_dimensions = tostring(water_w) .. "x" .. tostring(water_h),
		overlay_dimensions = tostring(overlay_w) .. "x" .. tostring(overlay_h),
		object_dimensions = tostring(object_w) .. "x" .. tostring(object_h),
		current_map_is_target = tostring(Global("CurrentMap") == token.map),
	}, map)
	return true, refs, expected_width, expected_height
end

local function ValidateSupplyBuildingFootprint(token, building, resource, stage)
	local ok, refs, width, height = ValidateSupplyGridSet(token, token.map, stage, true)
	if not ok then return false, refs end
	if type(building) ~= "table" then
		return SupplyGridSetFailure(token, stage, "supply building is unavailable")
	end
	local city = rawget(building, "city")
	if city ~= token.map.City then
		return SupplyGridSetFailure(token, stage, "Elevator city does not belong to the target map")
	end
	local world_to_hex = Global("WorldToHex")
	local rotate = Global("HexRotate")
	local angle_to_direction = Global("HexAngleToDirection")
	if type(world_to_hex) ~= "function" or type(building.GetSupplyGridConnectionShapePoints) ~= "function" then
		return SupplyGridSetFailure(token, stage, "supply footprint APIs are unavailable")
	end
	local q, r = SafeCall(world_to_hex, building)
	local direction = type(angle_to_direction) == "function"
		and SafeCall(angle_to_direction, building) or 0
	local shape_ok, shape = pcall(building.GetSupplyGridConnectionShapePoints, building, resource)
	if not shape_ok or type(shape) ~= "table" or #shape == 0
		or type(q) ~= "number" or type(r) ~= "number" then
		return SupplyGridSetFailure(token, stage, "Elevator supply footprint could not be resolved")
	end
	for _, shape_point in ipairs(shape) do
		local local_q, local_r = SupplyPointXY(shape_point)
		local rotated_q, rotated_r = local_q, local_r
		if type(rotate) == "function" and type(direction) == "number" then
			rotated_q, rotated_r = SafeCall(rotate, local_q, local_r, direction)
		end
		local final_q = type(rotated_q) == "number" and q + rotated_q or nil
		local final_r = type(rotated_r) == "number" and r + rotated_r or nil
		local sx = type(final_q) == "number" and type(final_r) == "number"
			and final_q + final_r / 2 or nil
		local sy = final_r
		local in_bounds = type(sx) == "number" and type(sy) == "number"
			and sx >= 0 and sy >= 0 and sx < width and sy < height
		if not in_bounds then
			return SupplyGridSetFailure(token, stage, "supply-fragment coordinate is out of bounds")
		end
	end
	local element = resource and rawget(building, resource) or nil
	if type(element) == "table" then
		if rawget(element, "building") ~= building then
			return SupplyGridSetFailure(token, stage, "supply element belongs to a different building")
		end
		local grid = rawget(element, "grid")
		if grid and token.forbidden_refs and token.forbidden_refs[grid] then
			return SupplyGridSetFailure(token, stage, "Elevator element retains a surface-grid reference")
		end
		if grid then
			local fragment_resource = type(grid) == "table" and grid.supply_resource or nil
			if fragment_resource and fragment_resource ~= resource then
				return SupplyGridSetFailure(token, stage, "Elevator element uses the wrong supply fragment")
			end
			for _, candidate in ipairs(type(grid) == "table" and rawget(grid, "elements") or {}) do
				local owner = type(candidate) == "table" and rawget(candidate, "building") or nil
				local owner_city = type(owner) == "table" and rawget(owner, "city") or nil
				if owner and owner_city ~= token.map.City then
					return SupplyGridSetFailure(token, stage,
						"new underground fragment contains a surface-map element")
				end
			end
		end
	end
	return true, refs
end

local function CompleteElevatorRestoreTransactionIfReady(token)
	if CurrentElevatorRestoreToken(token.map, token.token_id) ~= token then return false end
	for _, record in ipairs(token.records) do
		local building = record.rebuilt_elevator
		local connected = building and token.connected[building]
		local merged = building and token.merged[building]
		if not building or not connected or not merged
			or connected.electricity ~= true or connected.water ~= true
			or merged.electricity ~= true or merged.water ~= true then
			return false
		end
	end
	token.status = "complete"
	token.completed_on_map = Global("CurrentMap")
	pending_underground_elevator_restores[token.map] = nil
	underground_elevator_restore_tokens[token.token_id] = nil
	token.map.SuperBigMapDeferredElevatorRestorePending = nil
	token.map.SuperBigMapDeferredElevatorRestoreToken = nil
	token.map.SuperBigMapDeferredElevatorRestoreCompletedToken = token.token_id
	for index, record in ipairs(token.records) do
		local building = record.rebuilt_elevator
		local building_x, building_y = SupplyPointXY(building and Engine.ObjectPos(building))
		local connected = building and token.connected[building] or {}
		local merged = building and token.merged[building] or {}
		ExpansionAudit("RESTORE_RECORD_COMPLETE", {
			token = token.token_id, record = index,
			x = tostring(building_x), y = tostring(building_y),
			linked_other = tostring(type(building) == "table" and rawget(building, "other")),
			electricity_connected = tostring(connected and connected.electricity == true),
			water_connected = tostring(connected and connected.water == true),
			electricity_merged = tostring(merged and merged.electricity == true),
			water_merged = tostring(merged and merged.water == true),
		}, token.map)
	end
	ExpansionAudit("RESTORE_TOKEN_COMPLETE", {
		token = token.token_id, records = #token.records,
		completed_on_target = tostring(token.completed_on_map == token.map),
		status = token.status,
	}, token.map)
	return true
end

local function CopySupplyFragmentSynchronously(token, city, fragment, resource, stage)
	local map = SupplyObjectMap(city)
	if not map and city == token.map.City then map = token.map end
	if not map and token.source_map and city == token.source_map.City then map = token.source_map end
	local ok, refs = ValidateSupplyGridSet(token, map, stage, false)
	if not ok then return false, refs end
	if Global("CurrentMap") ~= token.map then
		return SupplyGridSetFailure(token, stage, "underground map changed before synchronous overlay copy")
	end
	local connection = refs[resource]
	local total_points, out_of_bounds, missing_shapes =
		ValidateSupplyFragmentFootprint(connection, fragment, resource)
	if total_points < 1 or out_of_bounds ~= 0 or missing_shapes ~= 0 then
		return SupplyGridSetFailure(token, stage,
			"supply fragment failed the complete coordinate audit")
	end
	-- Do not call CopySupplyFragmentToOverlayGrid here. Its native implementation reads every
	-- footprint back through the connection grid and asserts when a cross-map Elevator merge is
	-- still inside the second element's GameInit. The overlay does not need that read: vanilla's
	-- unmerged branch obtains the fragment ID and applies it directly to the building shape. Do the
	-- same bounded operation for each element owned by this city after the complete coordinate audit.
	local get_overlay_index = Global("GetGridOverlayIndex")
	local apply_overlay_id = Global("ApplyIDToOverlayGrid")
	local shift = Global("shift")
	if type(get_overlay_index) ~= "function" or type(apply_overlay_id) ~= "function"
		or (resource == "water" and type(shift) ~= "function") then
		return SupplyGridSetFailure(token, stage, "bounded overlay-copy APIs are unavailable")
	end
	local overlay_id = get_overlay_index(fragment)
	if type(overlay_id) ~= "number" then
		return SupplyGridSetFailure(token, stage, "merged fragment has no overlay ID")
	end
	if resource == "water" then overlay_id = shift(overlay_id, 4) end
	local applied = 0
	for _, element in ipairs(type(fragment) == "table" and rawget(fragment, "elements") or {}) do
		local building = type(element) == "table" and rawget(element, "building") or nil
		local building_city = type(building) == "table" and rawget(building, "city") or nil
		local building_map = SupplyObjectMap(building)
		if building and (building_city == city or building_map == map) then
			local shape_ok, shape = pcall(building.GetSupplyGridConnectionShapePoints,
				building, resource)
			if not shape_ok or type(shape) ~= "table" or #shape == 0 then
				return SupplyGridSetFailure(token, stage,
					"bounded overlay copy could not resolve an Elevator footprint")
			end
			local apply_ok, apply_error = pcall(apply_overlay_id,
				refs.overlay, building, shape, overlay_id)
			if not apply_ok then
				return SupplyGridSetFailure(token, stage, "bounded overlay copy failed: " .. tostring(apply_error))
			end
			applied = applied + 1
		end
	end
	if applied < 1 then
		return SupplyGridSetFailure(token, stage,
			"bounded overlay copy found no fragment element owned by the target city")
	end
	ExpansionAudit("SUPPLY_OVERLAY_COPY_COMPLETE", {
		token = token.token_id, stage = tostring(stage), resource = tostring(resource),
		footprint_points = total_points, applied_buildings = applied,
		overlay_id = overlay_id, current_map_is_target = tostring(Global("CurrentMap") == token.map),
	}, map)
	return true
end

local function MergeSupplyFragmentsSynchronously(token, new_grid, grid, filter, resource, copy_overlay)
	local get_connections = Global("GetElementConnections")
	local destroy_connections = Global("DestroyAllConnectionsFromElement")
	local connect_grids = Global("ConnectGrids")
	if type(get_connections) ~= "function" or type(destroy_connections) ~= "function"
		or type(connect_grids) ~= "function" then
		return SupplyGridSetFailure(token, "synchronous fragment merge",
			"vanilla supply-fragment APIs are unavailable")
	end
	if grid ~= new_grid then
		local elements = rawget(grid, "elements") or {}
		for index = #elements, 1, -1 do
			local element = elements[index]
			if not filter or filter(element) then
				local element_connections = get_connections(element)
				local saved = {}
				if type(element_connections) == "table" then
					for i, pair in ipairs(element_connections) do saved[i] = pair end
				end
				destroy_connections(element)
				grid:RemoveElement(element)
				new_grid:AddElement(element)
				for _, pair in ipairs(saved) do connect_grids(pair[1], pair[2]) end
			end
		end
	end
	local remaining = type(rawget(grid, "elements")) == "table" and #grid.elements or 0
	if not filter and remaining ~= 0 then
		return SupplyGridSetFailure(token, "synchronous fragment merge",
			"vanilla full merge left elements behind")
	end
	if remaining == 0 and type(grid.delete) == "function" then grid:delete() end
	if copy_overlay ~= false and not rawget(new_grid, "grid_subtype") then
		for _, city in ipairs(rawget(new_grid, "cities") or {}) do
			local copied, copy_error = CopySupplyFragmentSynchronously(token, city, new_grid,
				resource, "synchronous merged-fragment overlay copy")
			if not copied then return false, copy_error end
		end
	end
	return true
end

local function TaggedListContains(list, field, value)
	for _, item in ipairs(list) do
		if item[field] == value then return true end
	end
	return false
end

-- Vanilla SupplyGridConnectElement schedules an opaque game-time callback only when it merges
-- multiple neighbouring fragments. For a tagged restored Elevator, reproduce the normal-building
-- branch with the same public engine primitives and perform that merge/copy synchronously. This is
-- intentionally narrow: construction grids, switches, domes, and every untagged object retain the
-- original class method.
local function ConnectTaggedElevatorElementSynchronously(token, building, element,
	grid_class, new_grid_skin, force_create_connections)
	local resource = type(grid_class) == "table" and grid_class.supply_resource or nil
	if resource ~= "electricity" and resource ~= "water" then
		return SupplyGridSetFailure(token, "tagged synchronous element connection",
			"unsupported Elevator supply resource")
	end
	local valid, why = ValidateSupplyBuildingFootprint(token, building, resource,
		"before tagged synchronous element connection")
	if not valid then return false, why end
	local is_obj_in_dome = Global("IsObjInDome")
	if type(is_obj_in_dome) == "function" and is_obj_in_dome(building) then
		return SupplyGridSetFailure(token, "tagged synchronous element connection",
			"deferred underground Elevator unexpectedly belongs to a dome")
	end
	local has_member = type(building.HasMember) == "function"
	local construction_connections = has_member
		and SafeCall(building.HasMember, building, "construction_connections") == true
		and building.construction_connections ~= -1 and building.construction_connections or 0
	if building.connect_dir or construction_connections ~= 0 then
		return SupplyGridSetFailure(token, "tagged synchronous element connection",
			"unexpected preferred/construction connection state")
	end
	local apply_building = Global("SupplyGridApplyBuilding")
	local get_object_grid = Global("GetObjectHexGrid")
	local are_connected = Global("AreGridsConnected")
	local connect_grids = Global("ConnectGrids")
	local copy_grid_connections = Global("CopyGridConnections")
	local get_overlay_index = Global("GetGridOverlayIndex")
	local apply_overlay_id = Global("ApplyIDToOverlayGrid")
	local shift = Global("shift")
	if type(apply_building) ~= "function" or type(get_object_grid) ~= "function"
		or type(are_connected) ~= "function" or type(connect_grids) ~= "function"
		or type(copy_grid_connections) ~= "function"
		or type(get_overlay_index) ~= "function" or type(apply_overlay_id) ~= "function"
		or (resource == "water" and type(shift) ~= "function") then
		return SupplyGridSetFailure(token, "tagged synchronous element connection",
			"vanilla supply connection APIs are unavailable")
	end
	local refs = token.authoritative_refs
	local connection_grid = refs and refs[resource]
	local shape = building:GetSupplyGridConnectionShapePoints(resource)
	local shape_connections = building:GetShapeConnections(resource)
	local potential_neighbours = apply_building(connection_grid, building, shape,
		shape_connections, nil, false)
	-- The native engine result is an indexable point sequence, but it is not guaranteed to be
	-- represented as a plain Lua table. Vanilla only applies # and numeric indexing to it. Preserve
	-- that contract and additionally require complete point pairs before consuming the sequence.
	local neighbour_length_ok, neighbour_point_count = pcall(function()
		return #potential_neighbours
	end)
	if not neighbour_length_ok or type(neighbour_point_count) ~= "number"
		or neighbour_point_count < 0 or neighbour_point_count % 2 ~= 0 then
		return SupplyGridSetFailure(token, "tagged synchronous element connection",
			"SupplyGridApplyBuilding returned an invalid neighbour sequence")
	end
	new_grid_skin = new_grid_skin or (has_member
		and SafeCall(building.HasMember, building, "construction_grid_skin") == true
		and building.construction_grid_skin)
	local object_grid = get_object_grid(building)
	if not object_grid or type(object_grid.GetObjectAtPos) ~= "function" then
		return SupplyGridSetFailure(token, "tagged synchronous element connection",
			"object grid is unavailable")
	end
	local built_connections = {}
	local create_connection_call_data = {}
	local grid
	local grids_merged = false
	local function should_skip(other_grid)
		local ignore_grid_to_grid = not other_grid.grid_subtype
			and IsKindOfSafe(building, "Building")
		for _, entry in ipairs(built_connections) do
			local connected_grid = entry[1]
			if (ignore_grid_to_grid and connected_grid == other_grid)
				or (not ignore_grid_to_grid and are_connected(connected_grid, other_grid)) then
				return true
			end
		end
		return false
	end
	for index = 1, neighbour_point_count, 2 do
		local point_a, point_b = potential_neighbours[index], potential_neighbours[index + 1]
		local adjacent = object_grid:GetObjectAtPos(point_b, nil, nil,
			function(object) return object[resource] end)
		local adjacent_element = adjacent and adjacent[resource]
		local adjacent_grid = type(adjacent_element) == "table" and adjacent_element.grid or nil
		if not adjacent_grid then
			return SupplyGridSetFailure(token, "tagged synchronous element connection",
				"native neighbour has no supply fragment")
		end
		local force_connect = (IsKindOfSafe(building, "Building")
			and not IsKindOfSafe(building, "LifeSupportGridElement")
			and IsKindOfSafe(adjacent, "LifeSupportGridElement"))
			or (IsKindOfSafe(building, "LifeSupportGridElement")
				and IsKindOfSafe(adjacent, "Building")
				and not IsKindOfSafe(adjacent, "LifeSupportGridElement"))
		if not grid then
			if not should_skip(adjacent_grid)
				or (force_connect and not TaggedListContains(built_connections, 2, adjacent_element))
				or not TaggedListContains(built_connections, 1, adjacent_grid) then
				create_connection_call_data[#built_connections + 1] = {
					point_a, point_b, building, adjacent,
				}
				built_connections[#built_connections + 1] = { adjacent_grid, adjacent_element }
			end
			if not adjacent_grid.grid_subtype then
				grid = adjacent_grid
				grid:AddElement(element)
			end
		else
			if force_create_connections and adjacent_grid == grid then
				create_connection_call_data[#built_connections + 1] = {
					point_a, point_b, building, adjacent,
				}
				built_connections[#built_connections + 1] = { adjacent_grid, adjacent_element }
			elseif adjacent_grid ~= grid and adjacent_grid.grid_subtype == grid.grid_subtype then
				if not should_skip(adjacent_grid) then
					if not TaggedListContains(built_connections, 1, adjacent_grid) then
						create_connection_call_data[#built_connections + 1] = {
							point_a, point_b, building, adjacent,
						}
						built_connections[#built_connections + 1] = { adjacent_grid, adjacent_element }
					end
					grids_merged = grid
					for _, moved_element in ipairs(adjacent_grid.elements or {}) do
						grid:AddElement(moved_element)
					end
					copy_grid_connections(adjacent_grid, grid)
					adjacent_grid:delete()
				end
			elseif (force_connect and not TaggedListContains(built_connections, 2, adjacent_element))
				or (not are_connected(grid, adjacent_grid) and not should_skip(adjacent_grid)) then
				create_connection_call_data[#built_connections + 1] = {
					point_a, point_b, building, adjacent,
				}
				built_connections[#built_connections + 1] = { adjacent_grid, adjacent_element }
			end
		end
	end
	local city = rawget(building, "city") or token.map.City
	if not grid then
		local params = { city = city, element_skin = new_grid_skin }
		local create = type(grid_class) == "table" and grid_class.new
		if type(create) ~= "function" then
			return SupplyGridSetFailure(token, "tagged synchronous element connection",
				"supply grid constructor is unavailable")
		end
		grid = create(grid_class, params, token.map)
		if not grid then
			return SupplyGridSetFailure(token, "tagged synchronous element connection",
				"supply grid constructor failed")
		end
		grid:AddElement(element)
	elseif new_grid_skin and grids_merged and type(grids_merged.ChangeElementSkin) == "function" then
		grids_merged:ChangeElementSkin(new_grid_skin, nil, true)
	end
	for index, entry in ipairs(built_connections) do
		local other_grid, adjacent_element = entry[1], entry[2]
		local connection_data = create_connection_call_data[index]
		if connection_data then
			grid_class.CreateConnection(Unpack(connection_data, 1, 4))
		end
		if other_grid ~= grid and other_grid.grid_subtype ~= grid.grid_subtype then
			connect_grids(element, adjacent_element)
		end
	end
	if not grid.grid_subtype then
		if grids_merged then
			local copied, copy_error = CopySupplyFragmentSynchronously(token, city, grid,
				resource, "synchronous local merged-fragment overlay copy")
			if not copied then return false, copy_error end
		else
			local overlay_id = get_overlay_index(grid)
			if resource == "water" then overlay_id = shift(overlay_id, 4) end
			apply_overlay_id(refs.overlay, building, shape, overlay_id)
		end
	end
	return true
end

local function MergeTaggedElevatorGridsSynchronously(building, resource, token)
	local valid, why = ValidateSupplyBuildingFootprint(token, building, resource,
		"before synchronous passage-grid merge")
	if not valid then return false, why end
	local element = rawget(building, resource)
	local my_grid = type(element) == "table" and rawget(element, "grid") or nil
	if not my_grid then
		return true
	end
	local other = rawget(building, "other")
	local other_element = type(other) == "table" and rawget(other, resource) or nil
	local other_grid = type(other_element) == "table" and rawget(other_element, "grid") or nil
	if my_grid and other_grid and my_grid ~= other_grid then
		local other_map = SupplyObjectMap(other) or token.source_map
		local source_ok, source_error = ValidateSupplyGridSet(token, other_map,
			"before synchronous source passage-grid merge", false)
		if not source_ok then return false, source_error end
		if other_map ~= token.source_map
			or rawget(other, "city") ~= (token.source_map and token.source_map.City) then
			return SupplyGridSetFailure(token, "synchronous passage-grid merge",
				"linked Elevator does not belong to the captured source map")
		end
		local visit = Global("VisitConnectedElements")
		if type(visit) ~= "function" then
			return SupplyGridSetFailure(token, "synchronous passage-grid merge",
				"VisitConnectedElements is unavailable")
		end
		local visited_grids, visited_elements = {}, {}
		visit(element, resource, 0, 16384 + 64, false, visited_grids, visited_elements)
		local merged, merge_error = MergeSupplyFragmentsSynchronously(token, my_grid, other_grid,
			function(candidate) return visited_elements[candidate] end, resource)
		for _, visited in ipairs(visited_grids) do
			if visited and type(visited.free) == "function" then visited:free() end
		end
		if not merged then return false, merge_error end
	elseif my_grid and not rawget(my_grid, "grid_subtype") then
		local copied, copy_error = CopySupplyFragmentSynchronously(token, token.map.City,
			my_grid, resource, "synchronous unmerged-fragment overlay copy")
		if not copied then return false, copy_error end
	end
	token.merged[building] = token.merged[building] or {}
	token.merged[building][resource] = true
	CompleteElevatorRestoreTransactionIfReady(token)
	return true
end

local function PatchElevatorSupplyTransactionBoundary(source)
	local State = SuperBigMap.State
	local supply_class = Engine.ClassTable and Engine.ClassTable("SupplyGridObject")
	local passage_class = Engine.ClassTable and Engine.ClassTable("MapPassageLinked")
	local elevator_class = Engine.ClassTable and Engine.ClassTable("Elevator")
	if type(supply_class) ~= "table" or type(passage_class) ~= "table"
		or type(elevator_class) ~= "table" then
		return false
	end
	if State.elevator_supply_boundary_patch_version == GENERATOR_PATCH_VERSION
		and elevator_class.SupplyGridConnectElement == State.elevator_supply_connect_wrapper
		and elevator_class.MergeGrids == State.elevator_passage_merge_wrapper then
		return true
	end
	if elevator_class.SupplyGridConnectElement == State.elevator_supply_connect_wrapper
		and type(State.original_elevator_supply_connect) == "function" then
		elevator_class.SupplyGridConnectElement = State.original_elevator_supply_connect
	end
	if elevator_class.MergeGrids == State.elevator_passage_merge_wrapper
		and type(State.original_elevator_passage_merge_grids) == "function" then
		elevator_class.MergeGrids = State.original_elevator_passage_merge_grids
	end
	local original_connect = elevator_class.SupplyGridConnectElement
	local original_merge = elevator_class.MergeGrids
	if type(original_connect) ~= "function" or type(original_merge) ~= "function" then return false end
	local connect_wrapper = function(building, element, grid_class, new_grid_skin,
		force_create_connections)
		local token_id = type(building) == "table" and rawget(building, "SuperBigMapElevatorRestoreToken")
		local token = token_id and underground_elevator_restore_tokens[token_id] or nil
		if not token then
			return original_connect(building, element, grid_class, new_grid_skin,
				force_create_connections)
		end
		local resource = type(grid_class) == "table" and grid_class.supply_resource or nil
		ExpansionAudit("SUPPLY_CONNECT_BEGIN", {
			token = token.token_id, resource = tostring(resource),
			record = tostring(rawget(building, "SuperBigMapElevatorRestoreRecord")),
			had_grid = tostring(type(element) == "table" and rawget(element, "grid") ~= false),
		}, token.map)
		local ok, why = ValidateSupplyBuildingFootprint(token, building, resource,
			"before vanilla SupplyGridConnectElement")
		if not ok then error("blocked unsafe underground Elevator supply connection: " .. tostring(why)) end
		if rawget(element, "grid") ~= false then
			-- This object is a freshly recreated transaction member, so an attached fragment can only
			-- be stale work from an older lifecycle pass. Detach it without invoking the native
			-- disconnect path (which would consume the stale grid), then let vanilla build a fresh
			-- fragment against the already-validated current map.
			local stale_grid = rawget(element, "grid")
			if stale_grid and type(stale_grid.RemoveElement) == "function" then
				pcall(stale_grid.RemoveElement, stale_grid, element)
			end
			element.grid = false
		end
		local connected, connect_error = ConnectTaggedElevatorElementSynchronously(token,
			building, element, grid_class, new_grid_skin, force_create_connections)
		if not connected then
			error("underground Elevator synchronous supply connection failed: "
				.. tostring(connect_error))
		end
		local after_ok, after_why = ValidateSupplyBuildingFootprint(token, building, resource,
			"after synchronous SupplyGridConnectElement")
		if not after_ok or not rawget(element, "grid") then
			error("underground Elevator supply fragment failed post-connect validation: "
				.. tostring(after_why or "missing fragment"))
		end
		token.connected[building] = token.connected[building] or {}
		token.connected[building][resource] = true
		ExpansionAudit("SUPPLY_CONNECT_COMPLETE", {
			token = token.token_id, resource = tostring(resource),
			record = tostring(rawget(building, "SuperBigMapElevatorRestoreRecord")),
			fragment = tostring(type(element) == "table" and rawget(element, "grid")),
		}, token.map)
		local other = rawget(building, "other")
		local other_element = type(other) == "table" and rawget(other, resource) or nil
		if type(other_element) == "table" and rawget(other_element, "grid") then
			local merged, merge_error = MergeTaggedElevatorGridsSynchronously(
				building, resource, token)
			if not merged then
				error("underground Elevator supply fragment merge failed after connection: "
					.. tostring(merge_error))
			end
		end
		CompleteElevatorRestoreTransactionIfReady(token)
		return
	end
	local merge_wrapper = function(building, resource, ...)
		local token_id = type(building) == "table" and rawget(building, "SuperBigMapElevatorRestoreToken")
		local token = token_id and underground_elevator_restore_tokens[token_id] or nil
		if not token then return original_merge(building, resource, ...) end
		ExpansionAudit("SUPPLY_MERGE_BEGIN", {
			token = token.token_id, resource = tostring(resource),
			record = tostring(rawget(building, "SuperBigMapElevatorRestoreRecord")),
		}, token.map)
		local ok, why = MergeTaggedElevatorGridsSynchronously(building, resource, token)
		if not ok then error("blocked unsafe underground Elevator passage-grid merge: " .. tostring(why)) end
		ExpansionAudit("SUPPLY_MERGE_COMPLETE", {
			token = token.token_id, resource = tostring(resource),
			record = tostring(rawget(building, "SuperBigMapElevatorRestoreRecord")),
		}, token.map)
		return true
	end
	State.original_elevator_supply_connect = original_connect
	State.original_elevator_passage_merge_grids = original_merge
	State.elevator_supply_connect_wrapper = connect_wrapper
	State.elevator_passage_merge_wrapper = merge_wrapper
	State.elevator_supply_boundary_patch_version = GENERATOR_PATCH_VERSION
	elevator_class.SupplyGridConnectElement = connect_wrapper
	elevator_class.MergeGrids = merge_wrapper
	return true
end

-- Elevator utility transfer is represented by one supply fragment shared by the two map halves.
-- Vanilla asks each freshly attached element to Notify("MergePassageGrids"), but those queued
-- notifications can both run before LinkThroughPassage has finished linking the pair. Nothing
-- retries the merge afterward, leaving a valid-looking Elevator whose surface and underground
-- electricity fragments (and, through the identical path, water fragments) remain isolated.
--
-- Enforce the actual transfer invariant synchronously once the pair exists. The same helper is run
-- at load/map lifecycle boundaries so saves made with already-separated fragments are repaired
-- without rebuilding the Elevator or changing either local network's production/consumption. At
-- those stable boundaries it also republishes the current side through vanilla's normal
-- disconnect/connect path, so a missing Elevator footprint is restored in the owning map's
-- connection grid and normally adjacent consumers can discover it. This intentionally preserves
-- vanilla connector masks: it does not add proximity, wireless, or resource-specific exceptions.
-- Keep the helper alias inside a closed lexical scope: this intentionally large module runs close
-- to the engine compiler's 200-active-local limit.
SuperBigMap.ElevatorSupplyRepair = {}
do
local ElevatorSupplyRepair = SuperBigMap.ElevatorSupplyRepair

function ElevatorSupplyRepair.RebuildLocal(elevator, resource, rebuild_map)
	if not rebuild_map or SupplyObjectMap(elevator) ~= rebuild_map then
		return true, "not requested for this map"
	end
	local element = type(elevator) == "table" and rawget(elevator, resource) or nil
	local grid = type(element) == "table" and rawget(element, "grid") or nil
	if not element or not grid then return false, "missing local supply fragment" end
	local grid_class = resource == "electricity" and Global("ElectricityGrid")
		or resource == "water" and Global("WaterGrid") or nil
	local disconnect = rawget(elevator, "SupplyGridDisconnectElement")
		or elevator.SupplyGridDisconnectElement
	local connect = rawget(elevator, "SupplyGridConnectElement")
		or elevator.SupplyGridConnectElement
	if type(grid_class) ~= "table" or type(disconnect) ~= "function"
		or type(connect) ~= "function" then
		return false, "local supply republish API unavailable"
	end
	-- SupplyGridDisconnectElement(..., rebuild_only=true) returns before SupplyGridExpand when the
	-- building is absent from the connection grid. That is exactly the damaged old-save state this
	-- repair must handle. Fully detach and reconnect the Elevator element instead: these are the same
	-- native operations used by vanilla building/grid lifecycle code, and SupplyGridConnectElement
	-- remains solely responsible for applying the entity's electricity and water connector masks.
	local disconnect_ok, disconnect_error = pcall(disconnect, elevator, element, grid_class,
		false, false, true)
	if not disconnect_ok then
		-- A class hot reload can replace a native method while the disconnect is in progress. It may
		-- already have detached the element before reporting the error, so make a best-effort native
		-- rollback rather than leaving the live building with electricity/grid == false.
		if not rawget(element, "grid") then pcall(connect, elevator, element, grid_class) end
		return false, "native disconnect failed: " .. tostring(disconnect_error)
	end
	if rawget(element, "grid") then
		return false, "native disconnect left the Elevator element attached"
	end
	local connect_ok, connect_error = pcall(connect, elevator, element, grid_class)
	if not connect_ok then
		return false, "native reconnect failed: " .. tostring(connect_error)
	end
	if not rawget(element, "grid") then
		return false, "native reconnect did not create a supply fragment"
	end
	return true, "republished"
end

function ElevatorSupplyRepair.Pair(elevator, reason, rebuild_map)
	local other = type(elevator) == "table" and rawget(elevator, "other") or nil
	if not TraversalObjectValid(elevator) or not TraversalObjectValid(other) then
		return true, { skipped = "unlinked or invalid Elevator pair" }
	end
	local map = SupplyObjectMap(elevator)
	local other_map = SupplyObjectMap(other)
	if not IsExpandedSupplyContext(map) and not IsExpandedSupplyContext(other_map) then
		return true, { skipped = "non-expanded Elevator pair" }
	end

	local result = {
		reason = tostring(reason), elevator = tostring(elevator), other = tostring(other),
		map = tostring(map), other_map = tostring(other_map), repaired = 0, failed = 0,
	}
	for _, resource in ipairs({ "electricity", "water" }) do
		local local_rebuild_ok, local_rebuild_result =
			ElevatorSupplyRepair.RebuildLocal(elevator, resource, rebuild_map)
		result[resource .. "_local_rebuild"] = tostring(local_rebuild_result)
		local element = rawget(elevator, resource)
		local other_element = rawget(other, resource)
		local grid = type(element) == "table" and rawget(element, "grid") or nil
		local other_grid = type(other_element) == "table" and rawget(other_element, "grid") or nil
		result[resource .. "_before_shared"] = tostring(
			grid ~= nil and other_grid ~= nil and grid == other_grid)
		local resource_error
		if not element or not other_element then
			resource_error = "missing supply element"
		elseif not grid or not other_grid then
			resource_error = "missing supply fragment"
		elseif grid ~= other_grid then
			local merge = rawget(elevator, "MergeGrids") or elevator.MergeGrids
			if type(merge) ~= "function" then
				resource_error = "MergeGrids unavailable"
			else
				local merge_ok, merge_err = pcall(merge, elevator, resource)
				if not merge_ok then resource_error = tostring(merge_err) end
			end
		end

		grid = type(element) == "table" and rawget(element, "grid") or nil
		other_grid = type(other_element) == "table" and rawget(other_element, "grid") or nil
		local shared = grid ~= nil and other_grid ~= nil and grid == other_grid
		result[resource .. "_after_shared"] = tostring(shared)
		result[resource .. "_grid"] = tostring(grid)
		result[resource .. "_other_grid"] = tostring(other_grid)
		result[resource .. "_elements"] = tostring(type(grid) == "table"
			and type(rawget(grid, "elements")) == "table" and #grid.elements or nil)
		result[resource .. "_cities"] = tostring(type(grid) == "table"
			and type(rawget(grid, "cities")) == "table" and #grid.cities or nil)
		result[resource .. "_production"] = tostring(type(grid) == "table"
			and rawget(grid, "production") or nil)
		result[resource .. "_current_production"] = tostring(type(grid) == "table"
			and rawget(grid, "current_production") or nil)
		result[resource .. "_consumption"] = tostring(type(grid) == "table"
			and rawget(grid, "consumption") or nil)
		result[resource .. "_current_consumption"] = tostring(type(grid) == "table"
			and rawget(grid, "current_consumption") or nil)
		result[resource .. "_element_demand"] = tostring(type(element) == "table"
			and rawget(element, "consumption") or nil)
		result[resource .. "_element_supplied"] = tostring(type(element) == "table"
			and rawget(element, "current_consumption") or nil)
		if not local_rebuild_ok then
			result.failed = result.failed + 1
			result[resource .. "_error"] = "local supply republish failed: "
				.. tostring(local_rebuild_result)
		elseif shared and result[resource .. "_before_shared"] ~= "true" then
			result.repaired = result.repaired + 1
		elseif not shared then
			result.failed = result.failed + 1
			result[resource .. "_error"] = tostring(resource_error
				or "Elevator halves still reference different supply fragments")
		end
	end
	ExpansionAudit("ELEVATOR_SUPPLY_PAIR_REPAIR", result, map or other_map)
	return result.failed == 0, result
end

function ElevatorSupplyRepair.Networks(map, reason)
	local stats = {
		reason = tostring(reason), pairs = 0, repaired = 0, failed = 0,
		electricity_failed = 0, water_failed = 0,
		local_electricity_republished = 0, local_water_republished = 0,
	}
	if not IsExpandedSupplyContext(map) or type(map.MapForEach) ~= "function" then
		stats.skipped = "map is not an expanded gameplay map"
		return true, stats
	end
	local seen = setmetatable({}, { __mode = "k" })
	local scan_ok, scan_error = pcall(map.MapForEach, map, "map", "ElevatorBase",
		function(elevator)
			if seen[elevator] then return end
			seen[elevator] = true
			local other = TraversalObjectValid(elevator) and rawget(elevator, "other") or nil
			if not TraversalObjectValid(other) then return end
			seen[other] = true
			stats.pairs = stats.pairs + 1
			local pair_ok, pair = ElevatorSupplyRepair.Pair(elevator, reason, map)
			stats.repaired = stats.repaired + (tonumber(pair and pair.repaired) or 0)
			if pair and pair.electricity_local_rebuild == "republished" then
				stats.local_electricity_republished = stats.local_electricity_republished + 1
			end
			if pair and pair.water_local_rebuild == "republished" then
				stats.local_water_republished = stats.local_water_republished + 1
			end
			if not pair_ok then
				stats.failed = stats.failed + 1
				if pair and (pair.electricity_after_shared ~= "true"
					or pair.electricity_error ~= nil) then
					stats.electricity_failed = stats.electricity_failed + 1
				end
				if pair and (pair.water_after_shared ~= "true"
					or pair.water_error ~= nil) then
					stats.water_failed = stats.water_failed + 1
				end
			end
		end)
	if not scan_ok then
		stats.failed = stats.failed + 1
		stats.scan_error = tostring(scan_error)
	end
	ExpansionAudit("ELEVATOR_SUPPLY_NETWORK_AUDIT", stats, map)
	return stats.failed == 0, stats
end

-- Elevator cargo is not carried through the map transition by one drone. Vanilla exposes one
-- MapSharedDepot on both maps and registers its requests with the command centers covering each
-- Elevator half. Rebuild those transient registrations through the native APIs so moved Elevators
-- and saves made before this patch recover without replacing the depot or touching stored cargo.
function ElevatorSupplyRepair.CargoPair(elevator, reason)
	local other = type(elevator) == "table" and rawget(elevator, "other") or nil
	if not TraversalObjectValid(elevator) or not TraversalObjectValid(other) then
		return true, { skipped = "unlinked or invalid Elevator pair" }
	end
	local map, other_map = SupplyObjectMap(elevator), SupplyObjectMap(other)
	if not IsExpandedSupplyContext(map) and not IsExpandedSupplyContext(other_map) then
		return true, { skipped = "non-expanded Elevator pair" }
	end
	local depot = rawget(elevator, "shared_depot") or rawget(other, "shared_depot")
	if not TraversalObjectValid(depot) then
		return false, { error = "linked Elevator pair has no valid MapSharedDepot" }
	end
	local parent = rawget(depot, "parent_building")
	if parent ~= elevator and parent ~= other then
		return false, { error = "MapSharedDepot parent is not either Elevator half" }
	end
	local counterpart = parent == elevator and other or elevator
	local add_map_source = Global("AddRequestMapSource")
	local result = {
		reason = tostring(reason), elevator = tostring(elevator), other = tostring(other),
		depot = tostring(depot), parent = tostring(parent), map = tostring(map),
		other_map = tostring(other_map), failed = 0,
		before_parent_centers = tostring(type(rawget(parent, "command_centers")) == "table"
			and #parent.command_centers or nil),
		before_other_centers = tostring(type(rawget(counterpart, "command_centers")) == "table"
			and #counterpart.command_centers or nil),
		before_depot_centers = tostring(type(rawget(depot, "command_centers")) == "table"
			and #depot.command_centers or nil),
	}
	if type(add_map_source) ~= "function" then
		result.failed = result.failed + 1
		result.map_source_error = "AddRequestMapSource unavailable"
	else
		local source_ok, source_error = pcall(function()
			add_map_source(parent, SupplyObjectMap(parent), parent)
			add_map_source(parent, SupplyObjectMap(counterpart), counterpart)
		end)
		if not source_ok then
			result.failed = result.failed + 1
			result.map_source_error = tostring(source_error)
		end
	end

	-- Refresh the two local coverage lists first. ConnectToCommandCenters is additive and natively
	-- deduplicated, so it discovers a hub newly built beside an old Elevator without interrupting
	-- existing tasks or traversing MapPassageLinked's removal path during a class reload. The
	-- explicit depot reconnect then republishes every cargo request to the combined center set.
	local refresh_ok, refresh_error = pcall(function()
		for _, half in ipairs({ parent, counterpart }) do
			if type(half.ConnectToCommandCenters) == "function" then
				half:ConnectToCommandCenters()
			end
		end
		if type(depot.SetRequestsSource) == "function" then depot:SetRequestsSource(parent) end
		if type(depot.DisconnectFromCommandCenters) == "function" then
			depot:DisconnectFromCommandCenters()
		end
		if type(depot.ConnectToCommandCenters) == "function" then
			depot:ConnectToCommandCenters()
		end
	end)
	if not refresh_ok then
		result.failed = result.failed + 1
		result.registration_error = tostring(refresh_error)
	end
	result.after_parent_centers = tostring(type(rawget(parent, "command_centers")) == "table"
		and #parent.command_centers or nil)
	result.after_other_centers = tostring(type(rawget(counterpart, "command_centers")) == "table"
		and #counterpart.command_centers or nil)
	result.after_depot_centers = tostring(type(rawget(depot, "command_centers")) == "table"
		and #depot.command_centers or nil)
	local map_sources = type(Global("RequestToMapSource")) == "table"
		and Global("RequestToMapSource")[parent] or nil
	result.parent_map_source_ok = tostring(type(map_sources) == "table"
		and map_sources[SupplyObjectMap(parent)] == parent)
	result.other_map_source_ok = tostring(type(map_sources) == "table"
		and map_sources[SupplyObjectMap(counterpart)] == counterpart)
	if result.parent_map_source_ok ~= "true" or result.other_map_source_ok ~= "true" then
		result.failed = result.failed + 1
		result.map_source_validation_error = "Elevator request source mapping was not restored"
	end
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.ElevatorLogistics) == "function" then
		diagnostics.ElevatorLogistics("ELEVATOR_CARGO_REGISTRATION_REPAIR", result, map or other_map)
	end
	return result.failed == 0, result
end

function ElevatorSupplyRepair.CargoNetworks(map, reason)
	local stats = { reason = tostring(reason), pairs = 0, repaired = 0, failed = 0 }
	if not IsExpandedSupplyContext(map) or type(map.MapForEach) ~= "function" then
		stats.skipped = "map is not an expanded gameplay map"
		return true, stats
	end
	local seen = setmetatable({}, { __mode = "k" })
	local scan_ok, scan_error = pcall(map.MapForEach, map, "map", "ElevatorBase",
		function(elevator)
			if seen[elevator] then return end
			seen[elevator] = true
			local other = TraversalObjectValid(elevator) and rawget(elevator, "other") or nil
			if not TraversalObjectValid(other) then return end
			seen[other] = true
			stats.pairs = stats.pairs + 1
			local pair_ok = ElevatorSupplyRepair.CargoPair(elevator, reason)
			if pair_ok then stats.repaired = stats.repaired + 1
			else stats.failed = stats.failed + 1 end
		end)
	if not scan_ok then
		stats.failed = stats.failed + 1
		stats.scan_error = tostring(scan_error)
	end
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.ElevatorLogistics) == "function" then
		diagnostics.ElevatorLogistics("ELEVATOR_CARGO_NETWORK_AUDIT", stats, map)
	end
	return stats.failed == 0, stats
end

function ElevatorSupplyRepair.Schedule(map, reason)
	if not IsExpandedSupplyContext(map) then return false end
	local State = SuperBigMap.State
	State.elevator_supply_repair_scheduled = State.elevator_supply_repair_scheduled
		or setmetatable({}, { __mode = "k" })
	if State.elevator_supply_repair_scheduled[map] then
		ExpansionAudit("ELEVATOR_SUPPLY_REPAIR_COALESCED", {
			reason = tostring(reason),
		}, map)
		return true
	end
	State.elevator_supply_repair_scheduled[map] = tostring(reason)
	local function run()
		local scheduled_reason = State.elevator_supply_repair_scheduled[map]
		State.elevator_supply_repair_scheduled[map] = nil
		if Global("CurrentMap") ~= map or not IsExpandedSupplyContext(map) then
			ExpansionAudit("ELEVATOR_SUPPLY_REPAIR_SKIPPED", {
				reason = tostring(scheduled_reason), current_map = tostring(Global("CurrentMap")),
			}, map)
			return
		end
		ElevatorSupplyRepair.Networks(map,
			"scheduled after supply connection: " .. tostring(scheduled_reason))
		ElevatorSupplyRepair.CargoNetworks(map,
			"scheduled after local connection: " .. tostring(scheduled_reason))
	end
	if type(map.CreateGameTimeThread) == "function" then
		map:CreateGameTimeThread(run)
		return true
	end
	local create = Global("CreateGameTimeThread")
	if type(create) ~= "function" then
		State.elevator_supply_repair_scheduled[map] = nil
		ExpansionAudit("ELEVATOR_SUPPLY_REPAIR_SCHEDULE_FAILED", {
			reason = tostring(reason), error = "game-time thread API unavailable",
		}, map)
		return false
	end
	create(run)
	return true
end
end

-- Supply consumers finish creating their element after ConstructionComplete. Hook the
-- authoritative connection boundary so the Elevator topology repair cannot run early. The
-- wrapper is inert on vanilla maps. Patch every compiled descendant with its own inherited copy
-- of this method; concrete building classes do not necessarily dispatch through the base table.
-- MapPassageLinked descendants are excluded because the Elevator restore transaction has its own
-- stricter class-level boundary above.
function SuperBigMap.ElevatorSupplyRepair.PatchConsumerConnection(source)
	local State = SuperBigMap.State
	local supply_class = Engine.ClassTable and Engine.ClassTable("SupplyGridObject")
	if type(supply_class) ~= "table" or type(supply_class.SupplyGridConnectElement) ~= "function" then
		return false
	end
	local installed = State.expanded_supply_consumer_connect_patches
	if State.expanded_supply_consumer_connect_patch_version == GENERATOR_PATCH_VERSION
		and type(installed) == "table" and #installed > 0 then
		local intact = true
		for _, patch in ipairs(installed) do
			if patch.class.SupplyGridConnectElement ~= patch.wrapper then
				intact = false
				break
			end
		end
		if intact then return true end
	end
	for _, patch in ipairs(type(installed) == "table" and installed or {}) do
		if patch.class.SupplyGridConnectElement == patch.wrapper then
			patch.class.SupplyGridConnectElement = patch.original
		end
	end

	local passage_classes = setmetatable({}, { __mode = "k" })
	local passage_class = Engine.ClassTable and Engine.ClassTable("MapPassageLinked")
	if type(passage_class) == "table" then passage_classes[passage_class] = true end
	local descendants = Global("ClassDescendants")
	if type(descendants) == "function" then
		pcall(descendants, "MapPassageLinked", function(_, class, output)
			if type(class) == "table" then output[class] = true end
		end, passage_classes)
	end

	local targets = { supply_class }
	if type(descendants) == "function" then
		pcall(descendants, "SupplyGridObject", function(_, class, output)
			if type(class) == "table" then output[#output + 1] = class end
		end, targets)
	end
	local patches, seen = {}, setmetatable({}, { __mode = "k" })
	local function make_wrapper(original, class_name)
		return function(building, element, grid_class, ...)
			local results = PackValues(original(building, element, grid_class, ...))
			local map = SupplyObjectMap(building)
			local resource = type(grid_class) == "table" and grid_class.supply_resource or nil
			if IsExpandedSupplyContext(map)
				and (resource == "electricity" or resource == "water") then
				local grid = type(element) == "table" and rawget(element, "grid") or nil
				ExpansionAudit("SUPPLY_CONSUMER_CONNECT_COMPLETE", {
					source = tostring(source), wrapper_class = tostring(class_name),
					class = tostring(building and building.class), building = tostring(building),
					resource = resource, grid = tostring(grid),
					grid_elements = tostring(type(grid) == "table"
						and type(rawget(grid, "elements")) == "table" and #grid.elements or nil),
					grid_production = tostring(type(grid) == "table"
						and rawget(grid, "production") or nil),
					grid_consumption = tostring(type(grid) == "table"
						and rawget(grid, "consumption") or nil),
					element_demand = tostring(type(element) == "table"
						and rawget(element, "consumption") or nil),
					element_supplied = tostring(type(element) == "table"
						and rawget(element, "current_consumption") or nil),
				}, map)
				SuperBigMap.ElevatorSupplyRepair.Schedule(map,
					"SupplyGridConnectElement " .. tostring(building and building.class)
						.. " " .. tostring(resource))
			end
			return Unpack(results, 1, results.n)
		end
	end
	for _, class in ipairs(targets) do
		local original = type(class) == "table" and rawget(class, "SupplyGridConnectElement") or nil
		if not seen[class] and not passage_classes[class] and type(original) == "function" then
			seen[class] = true
			local wrapper = make_wrapper(original, rawget(class, "class"))
			class.SupplyGridConnectElement = wrapper
			patches[#patches + 1] = { class = class, original = original, wrapper = wrapper }
		end
	end
	State.expanded_supply_consumer_connect_patches = patches
	State.expanded_supply_consumer_connect_patch_version = GENERATOR_PATCH_VERSION
	ExpansionAudit("SUPPLY_CONSUMER_CONNECTION_PATCHED", {
		source = tostring(source), classes = #patches,
	}, Global("CurrentMap"))
	return #patches > 0
end

-- Native CopySupplyFragmentToOverlayGrid asserts in C instead of returning a Lua error when its
-- overlay and connection grids disagree. Keep vanilla untouched for normal maps, but fail closed
-- on an expanded map if a future lifecycle regression presents incompatible MapVars. The ordering
-- correction below should make this guard a no-op.
local function PatchSupplyGridOverlayCopyGuard(source)
	local State = SuperBigMap.State
	local current = Global("CopySupplyFragmentToOverlayGrid")
	if current == State.supply_grid_overlay_copy_wrapper
		and State.supply_grid_overlay_copy_patch_version == GENERATOR_PATCH_VERSION then
		return true
	end
	if current == State.supply_grid_overlay_copy_wrapper
		and type(State.original_supply_grid_overlay_copy) == "function" then
		current = State.original_supply_grid_overlay_copy
		rawset(_G, "CopySupplyFragmentToOverlayGrid", current)
	end
	if type(current) ~= "function" then
		return false
	end
	State.original_supply_grid_overlay_copy = current
	local captured_original = current
	local wrapper = function(overlay, connection_grid, city, fragment, ...)
		local map = city and type(city.GetMap) == "function" and SafeCall(city.GetMap, city)
			or Global("CurrentMap")
		if IsExpandedSupplyContext(map) then
			local ow, oh = SupplyGridDimensions(overlay)
			local cw, ch = SupplyGridDimensions(connection_grid)
			if not ow or not oh or not cw or not ch or ow ~= cw or oh ~= ch then
				return false
			end
		end
		return captured_original(overlay, connection_grid, city, fragment, ...)
	end
	rawset(_G, "CopySupplyFragmentToOverlayGrid", wrapper)
	State.supply_grid_overlay_copy_wrapper = wrapper
	State.supply_grid_overlay_copy_patch_version = GENERATOR_PATCH_VERSION
	return true
end

local function FinalizePendingUndergroundElevators(map, reason)
	local token = CurrentElevatorRestoreToken(map)
	if not token then return true, 0 end
	local records = token.records
	if type(records) ~= "table" or #records == 0 then return true, 0 end
	ExpansionAudit("RESTORE_LIFECYCLE_BEGIN", {
		token = token.token_id, records = #records, reason = tostring(reason),
		status = tostring(token.status), current_map_is_target = tostring(Global("CurrentMap") == map),
	}, map)
	local ready, ready_reason = ValidateSupplyGridSet(token, map,
		"lifecycle restore boundary: " .. tostring(reason), true)
	if not ready then return false, ready_reason end
	if not PatchElevatorSupplyTransactionBoundary("FinalizePendingUndergroundElevators") then
		return false, "Elevator supply transaction boundary is unavailable"
	end
	token.status = "restoring"
	token.lifecycle_reason = tostring(reason)
	local function transaction_guard(stage, guarded_map, building, record, index)
		local building_pos = type(building) == "table" and Engine.ObjectPos(building) or nil
		local building_x, building_y = SupplyPointXY(building_pos)
		local passage_pos = type(record) == "table" and record.underground_passage
			and Engine.ObjectPos(record.underground_passage) or nil
		local passage_x, passage_y = SupplyPointXY(passage_pos)
		ExpansionAudit("RESTORE_RECORD_STAGE", {
			token = token.token_id, record = tostring(index), stage = tostring(stage),
			status = tostring(token.status), target_map_matches = tostring(guarded_map == map),
			building_x = tostring(building_x), building_y = tostring(building_y),
			passage_x = tostring(passage_x), passage_y = tostring(passage_y),
			current_map_is_target = tostring(Global("CurrentMap") == map),
		}, map)
		if CurrentElevatorRestoreToken(map, token.token_id) ~= token then
			return false, "stale map-generation token"
		end
		if guarded_map ~= map then return false, "restore changed its target map" end
		local ok, why = ValidateSupplyGridSet(token, map,
			"restore guard " .. tostring(stage), true)
		if not ok then return false, why end
		if (stage == "before-create" or stage == "after-create")
			and type(building) == "table" then
			building.SuperBigMapElevatorRestoreToken = token.token_id
			building.SuperBigMapElevatorRestoreRecord = index
		elseif building and (stage == "after-position" or stage == "before-apply-grids"
			or stage == "before-construction-complete" or stage == "after-construction-complete") then
			for _, resource in ipairs({ "electricity", "water" }) do
				local footprint_ok, footprint_reason = ValidateSupplyBuildingFootprint(token,
					building, resource, "restore guard " .. tostring(stage))
				if not footprint_ok then return false, footprint_reason end
			end
		end
		return true
	end
	local ok, rebuilt = pcall(RestoreDeferredElevatorMigration, map, records,
		reason or "current-map lifecycle event", transaction_guard)
	if not ok then
		token.status = "failed"
		token.failure = tostring(rebuilt)
		ExpansionAudit("RESTORE_LIFECYCLE_FAILED", {
			token = token.token_id, reason = tostring(reason), error = tostring(rebuilt),
		}, map)
		return false, tostring(rebuilt)
	end
	if rebuilt ~= #records then
		token.status = "failed"
		return false, "rebuilt " .. tostring(rebuilt) .. " of " .. tostring(#records)
	end
	CompleteElevatorRestoreTransactionIfReady(token)
	if token.status ~= "complete" then token.status = "awaiting-supply-gameinit" end
	ExpansionAudit("RESTORE_LIFECYCLE_END", {
		token = token.token_id, records = #records, rebuilt = tostring(rebuilt),
		status = tostring(token.status),
	}, map)
	return true, rebuilt
end

local function HandlePendingUndergroundElevatorRestore(map_slot, map, reason)
	local token = CurrentElevatorRestoreToken(map)
	if not token then
		ExpansionAudit("RESTORE_HANDLER_NO_PENDING_TOKEN", {
			map_slot = tostring(map_slot), reason = tostring(reason),
			completed_token = tostring(map and map.SuperBigMapDeferredElevatorRestoreCompletedToken),
		}, map)
		return true, 0
	end
	ExpansionAudit("RESTORE_HANDLER_ENTER", {
		token = token.token_id, status = tostring(token.status),
		map_slot = tostring(map_slot), reason = tostring(reason),
	}, map)
	if token.status ~= "queued" then
		return token.status ~= "failed", token.failure or token.status
	end
	local ok, result = FinalizePendingUndergroundElevators(map,
		reason or "CurrentMapChangeDone")
	if not ok then
		map.SuperBigMapUndergroundPreparationFailed = true
		map.SuperBigMapUndergroundStretchFailed = tostring(result)
	end
	return ok, result
end

local function CopyGeneratedMapState(source, destination)
	destination.obj_prefab_marker = source.obj_prefab_marker
	destination.MapLowestZ = source.MapLowestZ
	destination.MapHighestZ = source.MapHighestZ
	for key, value in pairs(source) do
		if type(key) == "string" and string.match(key, "^SuperBigMap")
			and key ~= "SuperBigMapVanillaSourceMigration"
			and destination[key] == nil then
			destination[key] = value
		end
	end
end

-- Execute RandomMapGenerator exactly once on a real native backing, while retaining the already
-- allocated expanded map as the final destination. The temporary map never emits MapGenerated,
-- never runs the mod lifecycle, and is unloaded immediately after terrain/object migration.
local function GenerateOnTemporaryVanillaBacking(generator, destination, original_do_generate, ...)
	if not cfg_bool("GENERATE_VANILLA_SOURCE_ON_TEMPORARY_BACKING", false) then
		return false, "temporary vanilla backing is disabled"
	end
	if not cfg_bool("EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE", false) then
		return false, "vanilla source capture is disabled"
	end
	if not destination or not destination.mapdata then
		return false, "expanded destination map data is unavailable"
	end
	if destination.mapdata.Environment ~= "Surface" then
		return false, "destination is not a surface map"
	end

	-- NewMapObject normally attaches the complete name-keyed pending record.  Some stock launch
	-- paths, especially a landing-flow mod reload, can create the Map before that message handler
	-- observes the final name.  The MapData preset still carries the immutable native dimensions,
	-- so make the generator boundary self-contained instead of depending on message timing.
	AttachPendingMapState(destination)
	local mapdata = destination.mapdata
	local source_width = tonumber(destination.SuperBigMapGeneratorWidthTiles)
		or tonumber(destination.SuperBigMapSourceWidthTiles)
		or tonumber(mapdata.SuperBigMapSourceWidthTiles)
		or tonumber(mapdata.SuperBigMapOriginalWidthTiles)
	local source_height = tonumber(destination.SuperBigMapGeneratorHeightTiles)
		or tonumber(destination.SuperBigMapSourceHeightTiles)
		or tonumber(mapdata.SuperBigMapSourceHeightTiles)
		or tonumber(mapdata.SuperBigMapOriginalHeightTiles)
	local desired_width = tonumber(destination.SuperBigMapDesiredWidthTiles)
		or tonumber(mapdata.Width)
	local desired_height = tonumber(destination.SuperBigMapDesiredHeightTiles)
		or tonumber(mapdata.Height)
	if not source_width or not source_height or not desired_width or not desired_height
		or source_width <= 0 or source_height <= 0
		or desired_width <= source_width or desired_height <= source_height then
		return false, string.format(
			"invalid backing geometry: source=%sx%s destination=%sx%s pending=%s",
			tostring(source_width), tostring(source_height), tostring(desired_width),
			tostring(desired_height), tostring(destination.SuperBigMapExpansionPending))
	end
	local const_tbl = Global("const")
	local height_tile_size = type(const_tbl) == "table"
		and tonumber(const_tbl.HeightTileSize) or 1
	if height_tile_size <= 0 then height_tile_size = 1 end
	destination.SuperBigMapExpansionPending = true
	destination.SuperBigMapOriginalWidthTiles = destination.SuperBigMapOriginalWidthTiles or source_width
	destination.SuperBigMapOriginalHeightTiles = destination.SuperBigMapOriginalHeightTiles or source_height
	destination.SuperBigMapSourceWidthTiles = destination.SuperBigMapSourceWidthTiles or source_width
	destination.SuperBigMapSourceHeightTiles = destination.SuperBigMapSourceHeightTiles or source_height
	destination.SuperBigMapDesiredWidthTiles = desired_width
	destination.SuperBigMapDesiredHeightTiles = desired_height
	destination.SuperBigMapGeneratorWidthTiles = source_width
	destination.SuperBigMapGeneratorHeightTiles = source_height
	destination.SuperBigMapSourceWidth = destination.SuperBigMapSourceWidth
		or source_width * height_tile_size
	destination.SuperBigMapSourceHeight = destination.SuperBigMapSourceHeight
		or source_height * height_tile_size
	destination.SuperBigMapGeneratorWidth = destination.SuperBigMapGeneratorWidth
		or source_width * height_tile_size
	destination.SuperBigMapGeneratorHeight = destination.SuperBigMapGeneratorHeight
		or source_height * height_tile_size
	local change_map_in_slot = Global("ChangeMapInSlot")
	local change_current_slot = Global("ChangeCurrentMapSlot")
	local set_current_map = Global("SetCurrentMap")
	local engine_set_current_slot = Global("EngineSetCurrentMapSlot")
	local get_current_slot = Global("GetCurrentMapSlot")
	local maps = Global("Maps")
	local silent_switch_available = type(set_current_map) == "function"
		and type(engine_set_current_slot) == "function"
	if type(change_map_in_slot) ~= "function"
		or (not silent_switch_available and type(change_current_slot) ~= "function")
		or type(get_current_slot) ~= "function" or type(maps) ~= "table" then
		error("temporary source migration map-slot API unavailable")
	end
	local function SwitchGeneratorCurrentSlot(slot)
		local switch_token = LoadingBegin("switch temporary generator current slot", maps[slot], {
			target_slot = tostring(slot),
		})
		if silent_switch_available then
			local target = maps[slot]
			if not target then error("temporary source migration switch target is unavailable: " .. tostring(slot)) end
			set_current_map(target)
			engine_set_current_slot(slot)
			LoadingEnd(switch_token, {
				mode = "engine SetCurrentMap", target_slot = tostring(slot),
			}, true)
			return true
		end
		change_current_slot(slot, false)
		LoadingEnd(switch_token, { mode = "ChangeCurrentMapSlot", target_slot = tostring(slot) }, true)
		return true
	end
	local destination_slot = destination.slot or get_current_slot()
	local source_slot = FindTemporarySourceSlot(destination_slot)
	if not source_slot then error("temporary source migration has no free map slot") end
	local map_data_table = Global("MapData")
	local blank_map = generator and generator.BlankMap
	local template = type(map_data_table) == "table" and map_data_table[blank_map or false] or destination.mapdata
	local pass_border = tonumber(destination.mapdata.SuperBigMapOriginalPassBorder)
		or tonumber(template and template.SuperBigMapOriginalPassBorder)
		or tonumber(template and template.PassBorder) or 0
	local source_mapdata = NewNativeSourceMapData(template, source_width, source_height, pass_border)
	local call_args = PackValues(...)
	local saved_template_width = template and template.Width
	local saved_template_height = template and template.Height
	local saved_template_pass_border = template and template.PassBorder
	local saved_template_pass_border_tiles = template and template.PassBorderTiles
	local function RestoreGeneratorTemplate()
		if not template then return end
		template.Width = saved_template_width
		template.Height = saved_template_height
		template.PassBorder = saved_template_pass_border
		template.PassBorderTiles = saved_template_pass_border_tiles
	end
	local source_instance = {
		mapdata = source_mapdata,
		RandomMapGenObject = generator,
		SuperBigMapVanillaSourceMigration = true,
	}

	SetLoadingPhase("Generating the exact vanilla source terrain...")
	LoadingStep("temporary source transaction begin", {
		destination_slot = destination_slot, source_slot = source_slot,
		source_tiles = tostring(source_width) .. "x" .. tostring(source_height),
		destination_tiles = tostring(desired_width) .. "x" .. tostring(desired_height),
		pass_border = pass_border,
	}, destination)
	local source
	local source_baseline
	local native_enrichment_records
	local native_enrichment_excluded
	local native_enrichment_record_stats
	local source_generated_enrichments
	local vanilla_start_selection
	local source_pass_edits_deferred = false
	-- NewMap only assigns MainMap when the previous GameVar is false. A second pre-game map
	-- generation in the same process can therefore enter this transaction with MainMap still
	-- pointing at the surface object that ChangeMap just destroyed. The destination in slot 1 is
	-- the authoritative new surface for this transaction and for the additional-map phase that
	-- follows; never restore the stale object after temporarily publishing the vanilla backing.
	local destination_main_map = destination
	local destination_main_city = destination and destination.City or false
	local results
	SuperBigMap.State.vanilla_source_migration_active = true
	SuperBigMap.State.pending_vanilla_underground_seed = nil
	SuperBigMap.State.underground_seed_reservation_trace = nil
	local ok, migration_error = pcall(function()
		local allocation_token = LoadingBegin("allocate temporary vanilla backing", destination,
			{ source_slot = source_slot })
		local allocation_error = change_map_in_slot(source_slot, blank_map, source_instance)
		LoadingEnd(allocation_token, { error = tostring(allocation_error) }, allocation_error == nil)
		if allocation_error then error("temporary source ChangeMapInSlot: " .. tostring(allocation_error)) end
		source = maps[source_slot]
		if not source then error("temporary source map was not created") end
		local terrain_api = Global("terrain")
		local actual_width, actual_height
		if type(terrain_api) == "table" and type(terrain_api.HeightMapSize) == "function" then
			actual_width, actual_height = terrain_api.HeightMapSize(source)
			actual_height = actual_height or actual_width
		end
		if actual_width ~= source_width or actual_height ~= source_height then
			error(string.format("temporary source backing is not native-sized: got %sx%s expected %sx%s",
				tostring(actual_width), tostring(actual_height), tostring(source_width), tostring(source_height)))
		end
		source_baseline = SnapshotMapObjectSet(source)
		local baseline_count = 0
		if type(source_baseline) == "table" then
			for _ in pairs(source_baseline) do baseline_count = baseline_count + 1 end
		end
		LoadingStep("temporary source backing verified", {
			actual_tiles = tostring(actual_width) .. "x" .. tostring(actual_height),
			baseline_objects = baseline_count,
		}, source)

		SwitchGeneratorCurrentSlot(source_slot)
		rawset(_G, "MainMap", source)
		rawset(_G, "MainCity", source.City or false)
		ProbeNativeClutterAccess(source, "temporary source before DoGenerate")
		-- RandomMapGenerator:GetMapSize reads MapData[self.BlankMap] directly rather than the
		-- supplied map. Keep that last generator input native-sized for exactly this transaction;
		-- the destination's engine backing remains expanded and its template is restored before
		-- any destination work resumes.
		if template then
			template.Width = source_width
			template.Height = source_height
			template.PassBorder = pass_border
			local const_tbl = Global("const")
			local tile = type(const_tbl) == "table" and tonumber(const_tbl.HeightTileSize) or nil
			if type(template.PassBorderTiles) == "number" and tile and tile > 0 then
				template.PassBorderTiles = math.floor(pass_border / tile)
			end
		end
		if type(source.SuspendPassEdits) == "function" then source:SuspendPassEdits("SuperBigMapVanillaSourceMigration") end
		SuperBigMap.NotifyDeterminismCaptureForTest("pre_stock_generation", source, {
			generator = generator,
			destination = destination,
		})
		local generator_token = LoadingBegin("vanilla RandomMapGenerator.DoGenerate", source)
		if generator_token then
			local timed_results = PackValues(pcall(CallWithClutterCapture,
				source, original_do_generate, generator, source,
				Unpack(call_args, 1, call_args.n)))
			LoadingEnd(generator_token, nil, timed_results[1] == true)
			if not timed_results[1] then error(timed_results[2]) end
			results = { n = timed_results.n - 1 }
			for result_index = 2, timed_results.n do
				results[result_index - 1] = timed_results[result_index]
			end
		else
			results = PackValues(CallWithClutterCapture(source, original_do_generate, generator, source,
				Unpack(call_args, 1, call_args.n)))
		end
		SuperBigMap.NotifyDeterminismCaptureForTest("stock_surface_output", source, {
			generator = generator,
			destination = destination,
		})
		ProbeNativeClutterAccess(source, "temporary source after DoGenerate")
		local update_radius_token = LoadingBegin("refresh temporary source object radius", source)
		local update_radius = Global("UpdateMapMaxObjRadius")
		if type(update_radius) == "function" then update_radius(source) end
		LoadingEnd(update_radius_token, nil, true)
		local discard_source_pass_edits = cfg_bool(
			"OPTIMIZE_DISCARD_TEMPORARY_SOURCE_PASS_EDITS", false)
		local source_pass_flush_token = LoadingBegin("finalize temporary source pass edits", source, {
			mode = discard_source_pass_edits and "discard_on_unload" or "flush",
		})
		if discard_source_pass_edits then
			-- Nothing downstream consumes source.passable/buildable: height/type are stretched directly,
			-- marker state is value-captured, and transferred objects are revalidated on destination.
			-- Keep the batch suspended so ChangeMapInSlot can destroy it without first rebuilding it.
			source_pass_edits_deferred = true
		else
			if type(source.ResumePassEdits) == "function" then
				source:ResumePassEdits("SuperBigMapVanillaSourceMigration")
			end
		end
		LoadingEnd(source_pass_flush_token, {
			mode = source_pass_edits_deferred and "discard_on_unload" or "flushed",
		}, true)
		-- Vanilla reserves the underground seed after the complete surface RandomMapGenerate tail.
		-- Reserve at the equivalent temporary-source boundary, before any expansion-only capture,
		-- terrain stretch, object transfer, or destination-grid work can consume the global stream.
		local is_game_rule_active = Global("IsGameRuleActive")
		local no_underground = type(is_game_rule_active) == "function"
			and SafeCall(is_game_rule_active, "NoUndergroundAndAsteroids") == true
		if not no_underground and not Global("UndergroundMap") then
			SuperBigMap.CaptureNativeSurfacePassageBuildable(source, destination)
			local async_rand = Global("AsyncRand")
			if type(async_rand) ~= "function" then
				error("AsyncRand unavailable while reserving the vanilla underground seed")
			end
			local reserved_seed = async_rand()
			local twin_override = SuperBigMap.State.test_twin_underground_seed
			local boundary = "temporary_source_vanilla_tail"
			local authority_tag
			if type(twin_override) == "table" and type(twin_override.seed) == "number" then
				reserved_seed = twin_override.seed
				authority_tag = twin_override.authority_tag
				boundary = "fresh_vanilla_twin_test_seam"
				SuperBigMap.State.test_twin_underground_seed = nil
			end
			local pending = {
				seed = reserved_seed,
				surface = destination,
				boundary = boundary,
				authority_tag = authority_tag,
			}
			SuperBigMap.State.pending_vanilla_underground_seed = pending
			SuperBigMap.State.underground_seed_reservation_trace = {
				boundary = pending.boundary,
				reserved_seed = pending.seed,
			}
			SuperBigMap.TraceUndergroundSeedReservation("RESERVATION", {
				boundary = pending.boundary,
				reserved_seed = tostring(pending.seed),
				authority_tag = tostring(pending.authority_tag or "production"),
			}, destination)
		else
			SuperBigMap.State.test_twin_underground_seed = nil
		end
		local coordinate_capture_token = LoadingBegin("capture native enrichment coordinates", source)
		source_generated_enrichments = CaptureGeneratedNativeEnrichments(
			source, "temporary vanilla backing generation complete")
		LoadingEnd(coordinate_capture_token, {
			coordinate_count = tostring(source_generated_enrichments),
		}, true)
		local deposits = SuperBigMap.DepositRules
		if not deposits or type(deposits.CaptureNativeEnrichmentRecords) ~= "function" then
			error("native enrichment value-record capture API unavailable")
		end
		local record_capture_token = LoadingBegin("capture native enrichment value records", source)
		native_enrichment_records, native_enrichment_excluded, native_enrichment_record_stats =
			deposits.CaptureNativeEnrichmentRecords(
				source, "temporary vanilla backing generation complete")
		LoadingEnd(record_capture_token, {
			record_count = tostring(native_enrichment_record_stats and native_enrichment_record_stats.count),
		}, true)
		LoadingStep("native enrichment records captured", {
			coordinate_count = source_generated_enrichments,
			record_count = native_enrichment_record_stats and native_enrichment_record_stats.count,
			record_signature = native_enrichment_record_stats and native_enrichment_record_stats.signature,
		}, source)
		if native_enrichment_record_stats.count ~= source_generated_enrichments then
			error(string.format("native enrichment coordinate/value capture mismatch: coordinates=%s records=%s",
				tostring(source_generated_enrichments),
				tostring(native_enrichment_record_stats.count)))
		end
		-- Capture the start choice at the same native-source boundary as enrichments. The final
		-- destination temporarily has no live markers until post-stretch recreation, so waiting for
		-- its InitialExplore would make vanilla choose from an empty or unrelated 20x20 set.
		local sectors = SuperBigMap.SectorExploration
		if not sectors or type(sectors.CaptureVanillaStartSelection) ~= "function" then
			error("native start-sector annotation API unavailable")
		end
		local start_capture_token = LoadingBegin("capture vanilla initial sector", source)
		local start_capture_ok, selection, selection_error = pcall(
			sectors.CaptureVanillaStartSelection, source)
		LoadingEnd(start_capture_token, { selection = tostring(selection) },
			start_capture_ok and selection ~= nil)
		if not (start_capture_ok and selection) then
			error("native start-sector annotation failed: "
				.. tostring(start_capture_ok and selection_error or selection))
		end
		vanilla_start_selection = selection
		LoadingStep("vanilla initial sector captured", {
			selection = tostring(selection),
		}, source)

		rawset(_G, "MainMap", destination_main_map)
		rawset(_G, "MainCity", destination_main_city)
		RestoreGeneratorTemplate()
		SwitchGeneratorCurrentSlot(destination_slot)
		SetLoadingPhase("Migrating the vanilla source into the expanded terrain...")
		local direct_terrain = cfg_bool("EXPANSION_STEP_07_STRETCH_TERRAIN", true)
			and cfg_bool("OPTIMIZE_DIRECT_SOURCE_TERRAIN_STRETCH", true)
			and type(StretchSourceToFull) == "function"
			and type(AnnotateDecorRelief) == "function"
		local direct_terrain_ok, direct_terrain_grids = false, 0
		if direct_terrain then
			local direct_token = LoadingBegin(
				"stretch temporary source terrain directly to destination", destination)
			local call_ok, stretch_ok, stretched_grids = pcall(
				StretchSourceToFull, destination, source, true)
			direct_terrain_ok = call_ok and stretch_ok == true and stretched_grids == 2
			direct_terrain_grids = tonumber(stretched_grids) or 0
			LoadingEnd(direct_token, {
				completed_grids = tostring(direct_terrain_grids),
				error = call_ok and "" or tostring(stretch_ok),
			}, direct_terrain_ok)
		end
		if direct_terrain_ok then
			destination.SuperBigMapDirectSourceTerrainStretched = true
		else
			-- Compatibility fallback also repairs a partially completed direct attempt: copying the
			-- complete source corner gives the later normal stretch its canonical input again.
			local terrain_copy_token = LoadingBegin("copy native terrain to destination", destination)
			CopyMigratedTerrain(source, destination)
			LoadingEnd(terrain_copy_token, {
				direct_attempted = tostring(direct_terrain == true),
				direct_completed_grids = tostring(direct_terrain_grids),
			}, true)
			destination.SuperBigMapDirectSourceTerrainStretched = nil
		end
		local state_copy_token = LoadingBegin("copy generated map state", destination)
		CopyGeneratedMapState(source, destination)
		LoadingEnd(state_copy_token, nil, true)
		if type(deposits.StageNativeEnrichmentRecords) ~= "function" then
			error("native enrichment staging API unavailable")
		end
		local staged, stage_error = deposits.StageNativeEnrichmentRecords(destination,
			native_enrichment_records, "temporary vanilla backing migrated to destination",
			native_enrichment_record_stats and native_enrichment_record_stats.signature)
		if staged ~= true then error("native enrichment staging failed: " .. tostring(stage_error)) end
		LoadingStep("native enrichment records staged on destination", {
			record_count = #native_enrichment_records,
		}, destination)
		local object_transfer_token = LoadingBegin("transfer generated non-enrichment objects", destination)
		local transferred = TransferGeneratedObjects(source, destination, source_baseline,
			native_enrichment_excluded)
		LoadingEnd(object_transfer_token, { transferred = tostring(transferred) }, true)
		if direct_terrain_ok then
			-- Enumerate the destination only after transfer, exactly like the original surface tail.
			-- Ground heights still come from the loaded native source, so the relief snapshot remains
			-- pre-stretch without retaining any of the source backing's untransferred objects.
			local relief_token = LoadingBegin(
				"capture transferred decor relief from temporary terrain", destination)
			AnnotateDecorRelief(destination, source)
			destination.SuperBigMapDecorReliefCapturedFromTemporarySource = true
			LoadingEnd(relief_token, nil, true)
		end
		-- The normal expanded-backing tail consumes these optional smoothing records immediately.
		-- This path deliberately preserves the vanilla-generated height field, so discard their
		-- temporary-map references instead of allowing a later map generation to consume stale pads.
		SuperBigMap.State.sbm_entrance_pads = nil

		local box_fn = Global("box")
		local map_width, map_height = destination:GetMapSize()
		if type(destination.RebuildGrids) ~= "function" or type(box_fn) ~= "function" then
			error("destination RebuildGrids API unavailable")
		end
		local rebuild_token = LoadingBegin("rebuild destination grids after source migration", destination)
		destination:RebuildGrids(box_fn(0, 0, map_width, map_height))
		LoadingEnd(rebuild_token, nil, true)
		destination.SuperBigMapSurfaceBuildableCurrent = true
	end)

	-- Always restore the real surface as current and release the temporary slot. This also keeps
	-- the slot available for the vanilla additional-map/underground phase that follows Generate.
	rawset(_G, "MainMap", destination_main_map)
	rawset(_G, "MainCity", destination_main_city)
	RestoreGeneratorTemplate()
	if get_current_slot() ~= destination_slot then
		pcall(SwitchGeneratorCurrentSlot, destination_slot)
	end
	-- PASSAGE PASSABILITY BRIDGE (config PAIRING_SOURCE_PASSABILITY_BRIDGE): when a passage
	-- bootstrap is pending, the native backing must answer one more question before it goes away
	-- (see ReleaseRetainedNativeSourceMap). Hold its slot until the bootstrap's selection window
	-- closes instead of unloading here; the underground phase that follows has thirteen other free
	-- slots, so this retention never contends with it.
	local retain_source_for_passages = ok and maps[source_slot] and maps[source_slot] == source
		and cfg_bool("PAIRING_SOURCE_PASSABILITY_BRIDGE", true)
		and type(destination.SuperBigMapPendingNativeSurfacePassageBuildable) == "table"
	if retain_source_for_passages then
		destination.SuperBigMapRetainedNativeSourceMap = {
			map = source,
			slot = source_slot,
			pass_edits_deferred = source_pass_edits_deferred,
		}
		LoadingStep("temporary vanilla backing retained for the passage passability bridge", {
			source_slot = source_slot,
			pass_edits_deferred = tostring(source_pass_edits_deferred),
		}, destination)
	elseif maps[source_slot] then
		local unload_token = LoadingBegin("unload temporary vanilla backing", destination,
			{ source_slot = source_slot, pass_edits_deferred = tostring(source_pass_edits_deferred) })
		local unload_call_ok, unload_error = pcall(change_map_in_slot, source_slot, "")
		local unload_ok = unload_call_ok and unload_error == nil
		local resumed_for_retry = false
		if not unload_ok and source_pass_edits_deferred and source
			and type(source.ResumePassEdits) == "function" and maps[source_slot] then
			-- Compatibility fallback for an engine revision that requires a balanced ResumePassEdits
			-- before map disposal. This retains the old behavior rather than failing the generation.
			resumed_for_retry = pcall(
				source.ResumePassEdits, source, "SuperBigMapVanillaSourceMigration") == true
			source_pass_edits_deferred = false
			if resumed_for_retry then
				unload_call_ok, unload_error = pcall(change_map_in_slot, source_slot, "")
				unload_ok = unload_call_ok and unload_error == nil
			end
		end
		LoadingEnd(unload_token, {
			error = tostring(unload_error), resumed_for_retry = tostring(resumed_for_retry),
		}, unload_ok)
		if not unload_ok and ok then
			ok, migration_error = false, "temporary source unload failed: " .. tostring(unload_error)
		end
	end
	if ok and native_enrichment_records then
		local deposits = SuperBigMap.DepositRules
		local verify_call_ok, records_ok, record_verify_stats = pcall(
			deposits.VerifyStagedNativeEnrichmentRecords, destination,
			native_enrichment_record_stats.count, native_enrichment_record_stats.signature,
			"after temporary source slot unload")
		if not (verify_call_ok and records_ok == true) then
			ok = false
			migration_error = "native enrichment records did not survive source unload: "
				.. tostring(verify_call_ok and record_verify_stats and record_verify_stats.reason or records_ok)
		end
		LoadingStep("staged enrichment records survived source unload", {
			verified = tostring(verify_call_ok and records_ok == true),
			record_count = native_enrichment_record_stats and native_enrichment_record_stats.count,
		}, destination)
	end
	if ok and vanilla_start_selection then
		local sectors = SuperBigMap.SectorExploration
		local stage_call_ok, staged, stage_error = pcall(
			sectors.StageVanillaStartSelection, destination, vanilla_start_selection,
			"temporary vanilla source migrated and unloaded")
		if not (stage_call_ok and staged == true) then
			ok = false
			migration_error = "native start-sector annotation did not survive migration: "
				.. tostring(stage_call_ok and stage_error or staged)
		end
	end
	if not ok then
		local pending = SuperBigMap.State.pending_vanilla_underground_seed
		if type(pending) ~= "table" or pending.surface == destination then
			SuperBigMap.State.pending_vanilla_underground_seed = nil
		end
		SuperBigMap.State.test_twin_underground_seed = nil
		local deposits = SuperBigMap.DepositRules
		if deposits and type(deposits.ClearStagedNativeEnrichmentRecords) == "function" then
			pcall(deposits.ClearStagedNativeEnrichmentRecords, destination,
				"temporary source migration failed")
		end
		local sectors = SuperBigMap.SectorExploration
		if sectors and type(sectors.ClearPendingVanillaStartSelection) == "function" then
			pcall(sectors.ClearPendingVanillaStartSelection, destination,
				"temporary source migration failed")
		end
		local pending_buildable = destination.SuperBigMapPendingNativeSurfacePassageBuildable
		if type(pending_buildable) == "table" then
			SuperBigMap.FreeOwnedGrid(pending_buildable.grid)
		end
		destination.SuperBigMapPendingNativeSurfacePassageBuildable = nil
		ReleaseRetainedNativeSourceMap(destination, "temporary source migration failed")
	end
	SuperBigMap.State.vanilla_source_migration_active = false
	if not ok then
		EndSurfaceExpansionLoading(destination)
		error("temporary vanilla source migration failed: " .. tostring(migration_error))
	end
	SetLoadingPhase("Finishing the expanded map...")
	LoadingStep("temporary source transaction complete", nil, destination)
	return true, results
end

-- The underground generator's stock PlaceArtefacts procedure combines two unrelated jobs:
-- spawning every buried wonder and creating the two linked surface/underground passage anchors.
-- The former is expensive because its final ResumePassEdits processes every created object, while the
-- latter must exist before the player can place an Elevator.  Expanded maps therefore execute this
-- source-equivalent passage half during generation and retain the wonder markers, with their
-- already-shuffled vanilla class assignments, for first underground access.
local function ArtefactMapGet(map, class_name)
	if not map or type(map.MapGet) ~= "function" then return {} end
	local ok, objects = pcall(map.MapGet, map, "map", class_name)
	return ok and type(objects) == "table" and objects or {}
end

local function ArtefactApplyMarkerProperties(object, marker)
	local const_tbl = Global("const")
	local pos = marker:GetPos()
	if pos and type(pos.SetInvalidZ) == "function" then pos = pos:SetInvalidZ() end
	object:SetPos(pos)
	object:SetMirrored(marker:GetMirrored())
	object:SetAxis(marker:GetAxis())
	object:SetAngle(marker:GetAngle())
	object:SetScale(marker:GetScale())
	object:SetColorModifier(marker:GetColorModifier())
	if type(const_tbl) == "table" and const_tbl.gofPermanent then
		object:SetGameFlags(const_tbl.gofPermanent)
	end
end

-- Deferred wonder markers must not remain live after their stock PlaceArtefacts boundary: the
-- engine destroys each one immediately after flattening its assigned wonder, before passage and
-- obstruction generation continue. Preserve only scalar/value state through START, then recreate
-- the markers at first underground access when their deferred buildings are actually needed.
SuperBigMap.DEFERRED_WONDER_MARKER_FIELDS = {
	"SuperBigMapDeferredWonderClass",
	"SuperBigMapDeferredWonderIndex",
	"SuperBigMapNativeSourceX",
	"SuperBigMapNativeSourceY",
	"SuperBigMapNativeSourceZ",
	"SuperBigMapNativeSourceScale",
	"SuperBigMapNativeWonderClearanceDone",
	"SuperBigMapNativeWonderEntity",
	"SuperBigMapNativeWonderEntityBBoxMaxZ",
	"SuperBigMapNativeWonderEntityBBoxMinZ",
	"SuperBigMapNativeWonderEntityBBoxSizeZ",
	"SuperBigMapNativeWonderFlattenIndex",
	"SuperBigMapNativeWonderFlattenQ",
	"SuperBigMapNativeWonderFlattenR",
	"SuperBigMapNativeWonderFlattenShapeHexes",
	"SuperBigMapNativeWonderFlattenZ",
	"SuperBigMapNativeWonderSourceTerrainMaxZ",
	"SuperBigMapNativeWonderSourceTerrainMinZ",
	"SuperBigMapNativeWonderSourceTerrainZ",
	"SuperBigMapTransferredFromNativeSource",
}

function SuperBigMap.CaptureDeferredWonderMarkerRecord(marker)
	local record = {
		pos = marker:GetPos(),
		mirrored = marker:GetMirrored(),
		axis = marker:GetAxis(),
		angle = marker:GetAngle(),
		scale = marker:GetScale(),
		color_modifier = marker:GetColorModifier(),
		editor_text_color = marker.editor_text_color,
	}
	for _, field in ipairs(SuperBigMap.DEFERRED_WONDER_MARKER_FIELDS) do
		record[field] = marker[field]
	end
	return record
end

function SuperBigMap.RecreateDeferredWonderMarker(map, record)
	local place_object = Global("PlaceObjectIn")
	if type(place_object) ~= "function" then return nil, "PlaceObjectIn unavailable" end
	local marker = place_object("BuriedWonderMarker", map)
	if not marker then return nil, "BuriedWonderMarker construction failed" end
	marker:SetPos(record.pos)
	marker:SetMirrored(record.mirrored)
	marker:SetAxis(record.axis)
	marker:SetAngle(record.angle)
	marker:SetScale(record.scale)
	marker:SetColorModifier(record.color_modifier)
	marker.editor_text_color = record.editor_text_color
	for _, field in ipairs(SuperBigMap.DEFERRED_WONDER_MARKER_FIELDS) do
		marker[field] = record[field]
	end
	return marker
end

SuperBigMap.DEFERRED_WONDER_FLIGHT_QUEUE_FIELDS = {
	"objects_to_mark",
	"objects_to_unmark",
	"marked_objects",
}

function SuperBigMap.PrepareDeferredWonderFlightQueues(map)
	local flight_system = map and map.FlightSystem
	if type(flight_system) ~= "table" then
		return nil, "FlightSystem unavailable before native wonder cleanup"
	end
	local token = {
		flight_system = flight_system,
		replaced = {},
	}
	for _, field in ipairs(SuperBigMap.DEFERRED_WONDER_FLIGHT_QUEUE_FIELDS) do
		local previous = flight_system[field]
		if type(previous) ~= "table" then
			local replacement = {}
			token.replaced[#token.replaced + 1] = {
				field = field,
				previous = previous,
				replacement = replacement,
			}
			flight_system[field] = replacement
		end
	end
	return token
end

function SuperBigMap.RestoreDeferredWonderFlightQueues(token)
	if type(token) ~= "table" or type(token.flight_system) ~= "table" then
		return false, "temporary FlightSystem queue token unavailable"
	end
	local flight_system = token.flight_system
	local restore_error
	for index = #token.replaced, 1, -1 do
		local record = token.replaced[index]
		if flight_system[record.field] ~= record.replacement then
			restore_error = restore_error
				or "temporary FlightSystem queue was replaced during cleanup: "
					.. tostring(record.field)
		else
			flight_system[record.field] = record.previous
		end
	end
	if restore_error then return false, restore_error end
	return true
end

function SuperBigMap.CleanupPendingNativeWonders(map, reason)
	local pending = map and map.SuperBigMapPendingNativeWonderCleanup
	if type(pending) ~= "table" then return true, 0 end
	local done_object = Global("DoneObject")
	if type(done_object) ~= "function" then return false, "DoneObject unavailable" end
	local flight_token, flight_error = SuperBigMap.PrepareDeferredWonderFlightQueues(map)
	if not flight_token then return false, flight_error end
	local cleaned = 0
	local cleanup_error
	for _, wonder in ipairs(pending) do
		local ok, err = pcall(done_object, wonder)
		if not ok then
			cleanup_error = "temporary native wonder cleanup failed: " .. tostring(err)
			break
		end
		cleaned = cleaned + 1
	end
	local restore_ok, restore_error = SuperBigMap.RestoreDeferredWonderFlightQueues(flight_token)
	if restore_ok ~= true then
		return false, restore_error
	end
	if cleanup_error then return false, cleanup_error end
	map.SuperBigMapPendingNativeWonderCleanup = nil
	LoadingStep("temporary native underground wonders removed", {
		cleaned = cleaned,
		temporary_flight_queues = #flight_token.replaced,
		reason = tostring(reason or "unspecified"),
	}, map)
	return true, cleaned
end

local function ArtefactSpawnMarkerBuilding(marker, class_name, map)
	local place_building = Global("PlaceBuildingIn")
	local building = place_building(class_name, map)
	ArtefactApplyMarkerProperties(building, marker)
	return building
end

local function ArtefactClearObstructions(object, obj_prefab_marker, landscape_pos, shape)
	local clear = Global("ClearObstructions")
	local flatten_shape = shape
	if not flatten_shape and type(object.GetFlattenShape) == "function" then
		flatten_shape = object:GetFlattenShape()
	end
	return clear(object:GetMap(), object:GetPos(), object:GetAngle(), obj_prefab_marker,
		landscape_pos, flatten_shape)
end

local function DeferredArtefactPreflight(map)
	local required = {
		PlaceBuildingIn = Global("PlaceBuildingIn"),
		SpawnUndergroundPassage = Global("SpawnUndergroundPassage"),
		ClearObstructions = Global("ClearObstructions"),
		GetExtendedSpawnShape = Global("GetExtendedSpawnShape"),
		GetEnclosedShape = Global("GetEnclosedShape"),
		GetEntityOutlineShape = Global("GetEntityOutlineShape"),
		ShrinkShape = Global("ShrinkShape"),
		FlattenTerrainInBuildShape = Global("FlattenTerrainInBuildShape"),
		HexShapeForEach = Global("HexShapeForEach"),
		HexToWorld = Global("HexToWorld"),
		WorldToHex = Global("WorldToHex"),
		buildUnbuildableZ = Global("buildUnbuildableZ"),
		DoneObject = Global("DoneObject"),
		point = Global("point"),
		RGB = Global("RGB"),
	}
	for name, fn in pairs(required) do
		if type(fn) ~= "function" then return false, name .. " is unavailable" end
	end
	if not map or type(map.MapGet) ~= "function"
		or type(map.SuspendPassEdits) ~= "function" or type(map.ResumePassEdits) ~= "function"
		or type(map.buildable) ~= "table" or type(map.buildable.GetZ) ~= "function" then
		return false, "underground map grids or passage-edit methods are unavailable"
	end
	return true
end

-- Vanilla selects a wonder's flattening height while the untouched source build grid is still
-- authoritative. Deferred materialization happens after the height terrain has been resampled and
-- before the final expanded build-grid rebuild, so consulting map.buildable at that later point can
-- return a stale source height that no longer matches the stretched terrain. Capture vanilla's
-- exact first-buildable-cell result now and transform it with the terrain's stamped affine Z
-- transform when the wonder is finally created.
local WonderVerticalDiagnostics = {
	Classes = { "BottomlessPit", "AncientArtifact", "CaveOfWonders", "JumboCave" },
}

local function WonderGeometryDiagnosticsEnabled()
	local diagnostics = SuperBigMap.Diagnostics
	return diagnostics
		and type(diagnostics.UndergroundDecorationEnabled) == "function"
		and diagnostics.UndergroundDecorationEnabled() == true
end

function WonderVerticalDiagnostics.SafePointZ(pos)
	if not pos or type(pos.z) ~= "function" then return nil end
	local ok, z = pcall(pos.z, pos)
	return ok and type(z) == "number" and z or nil
end

function WonderVerticalDiagnostics.SafeBoxZStats(bbox)
	if not bbox then return nil end
	local ok, min_z, max_z, size_z = pcall(function()
		return bbox:minz(), bbox:maxz(), bbox:sizez()
	end)
	if not ok then return nil end
	return { min_z = min_z, max_z = max_z, size_z = size_z }
end

function WonderVerticalDiagnostics.ShapeVerticalStats(map, shape, object, target_z)
	local stats = {
		samples = 0, terrain_min_z = nil, terrain_max_z = nil,
		buildable_min_z = nil, buildable_max_z = nil,
		terrain_at_target = 0, terrain_above_target = 0, terrain_below_target = 0,
		buildable_at_target = 0, buildable_above_target = 0, buildable_below_target = 0,
	}
	local for_each = Global("HexShapeForEach")
	local hex_to_world = Global("HexToWorld")
	local point_fn = Global("point")
	local terrain_api = Global("terrain")
	local unbuildable_fn = Global("buildUnbuildableZ")
	if type(shape) ~= "table" or type(for_each) ~= "function"
		or type(hex_to_world) ~= "function" or type(point_fn) ~= "function"
		or type(terrain_api) ~= "table" or type(terrain_api.GetHeight) ~= "function" then
		return stats
	end
	local unbuildable = type(unbuildable_fn) == "function" and unbuildable_fn() or nil
	for_each(shape, object, function(q, r)
		local world = point_fn(hex_to_world(q, r))
		local ok_height, terrain_z = pcall(terrain_api.GetHeight, map, world)
		if ok_height and type(terrain_z) == "number" then
			stats.samples = stats.samples + 1
			stats.terrain_min_z = not stats.terrain_min_z and terrain_z
				or math.min(stats.terrain_min_z, terrain_z)
			stats.terrain_max_z = not stats.terrain_max_z and terrain_z
				or math.max(stats.terrain_max_z, terrain_z)
			if type(target_z) == "number" then
				if terrain_z == target_z then stats.terrain_at_target = stats.terrain_at_target + 1
				elseif terrain_z > target_z then stats.terrain_above_target = stats.terrain_above_target + 1
				else stats.terrain_below_target = stats.terrain_below_target + 1 end
			end
		end
		local buildable = type(map) == "table" and map.buildable or nil
		local buildable_z = type(buildable) == "table" and type(buildable.GetZ) == "function"
			and buildable:GetZ(q, r) or nil
		if type(buildable_z) == "number" and buildable_z ~= unbuildable then
			stats.buildable_min_z = not stats.buildable_min_z and buildable_z
				or math.min(stats.buildable_min_z, buildable_z)
			stats.buildable_max_z = not stats.buildable_max_z and buildable_z
				or math.max(stats.buildable_max_z, buildable_z)
			if type(target_z) == "number" then
				if buildable_z == target_z then
					stats.buildable_at_target = stats.buildable_at_target + 1
				elseif buildable_z > target_z then
					stats.buildable_above_target = stats.buildable_above_target + 1
				else
					stats.buildable_below_target = stats.buildable_below_target + 1
				end
			end
		end
	end)
	return stats
end

-- The lifecycle reseat only needs to know whether every terrain sample still equals the captured
-- vanilla flatten height. Keep the exhaustive terrain/buildable statistics for the opt-in geometry
-- diagnostic channel, but use one protected shape traversal with an early mismatch exit during
-- ordinary play. This retains the authoritative full-footprint check while avoiding thousands of
-- per-hex protected calls when no repair is necessary.
function WonderVerticalDiagnostics.ShapeTerrainTargetStats(map, shape, object, target_z)
	local stats = {
		samples = 0, terrain_min_z = nil, terrain_max_z = nil,
		terrain_at_target = 0, terrain_above_target = 0, terrain_below_target = 0,
		complete = false, error = nil,
	}
	local for_each = Global("HexShapeForEach")
	local hex_to_world = Global("HexToWorld")
	local point_fn = Global("point")
	local terrain_api = Global("terrain")
	local get_height = type(terrain_api) == "table" and terrain_api.GetHeight or nil
	if type(shape) ~= "table" or type(for_each) ~= "function"
		or type(hex_to_world) ~= "function" or type(point_fn) ~= "function"
		or type(get_height) ~= "function"
		or type(target_z) ~= "number" then
		stats.error = "terrain target helpers are unavailable"
		return stats
	end
	local mismatch = false
	local ok, err = pcall(for_each, shape, object, function(q, r)
		local terrain_z = get_height(map, point_fn(hex_to_world(q, r)))
		if type(terrain_z) ~= "number" then
			error("terrain height unavailable")
		end
		stats.samples = stats.samples + 1
		stats.terrain_min_z = not stats.terrain_min_z and terrain_z
			or math.min(stats.terrain_min_z, terrain_z)
		stats.terrain_max_z = not stats.terrain_max_z and terrain_z
			or math.max(stats.terrain_max_z, terrain_z)
		if terrain_z == target_z then
			stats.terrain_at_target = stats.terrain_at_target + 1
		else
			mismatch = true
			if terrain_z > target_z then
				stats.terrain_above_target = stats.terrain_above_target + 1
			else
				stats.terrain_below_target = stats.terrain_below_target + 1
			end
			return true
		end
	end)
	if not ok then stats.error = tostring(err) end
	stats.complete = ok and not mismatch and stats.samples > 0
	return stats
end

local function CaptureDeferredWonderSourceFlattenTarget(map, marker, wonder_class)
	local templates = Global("BuildingTemplates")
	local template = type(templates) == "table" and templates[wonder_class] or nil
	local entity = type(template) == "table" and template.entity or nil
	if type(entity) ~= "string" or entity == "" then
		return false, "building template entity unavailable"
	end
	local shape = Global("GetEnclosedShape")(entity)
	if type(shape) ~= "table" then
		return false, "vanilla enclosed shape unavailable"
	end
	if #shape == 0 then
		shape = Global("ShrinkShape")(Global("GetEntityOutlineShape")(entity), 2)
	end
	if type(shape) ~= "table" or #shape == 0 then
		return false, "vanilla flatten shape is empty"
	end
	local unbuildable = Global("buildUnbuildableZ")()
	local source_z, source_q, source_r, source_index
	Global("HexShapeForEach")(shape, marker, function(q, r, index)
		local z = map.buildable:GetZ(q, r)
		if z ~= unbuildable then
			source_z, source_q, source_r, source_index = z, q, r, index
			return true
		end
	end)
	if type(source_z) ~= "number" then
		return false, "vanilla source flatten shape has no buildable cell"
	end
	marker.SuperBigMapNativeWonderEntity = entity
	marker.SuperBigMapNativeWonderFlattenZ = source_z
	marker.SuperBigMapNativeWonderFlattenQ = source_q
	marker.SuperBigMapNativeWonderFlattenR = source_r
	marker.SuperBigMapNativeWonderFlattenIndex = source_index
	marker.SuperBigMapNativeWonderFlattenShapeHexes = #shape
	local marker_pos = type(marker.GetPos) == "function" and marker:GetPos() or nil
	local payload = {
		class = wonder_class,
		entity = entity,
		marker_z = WonderVerticalDiagnostics.SafePointZ(marker_pos),
		marker_scale = type(marker.GetScale) == "function" and marker:GetScale() or nil,
		source_flatten_z = source_z,
		flatten_shape_hexes = #shape,
	}
	if WonderGeometryDiagnosticsEnabled() then
		local entity_bbox
		local get_entity_bbox = Global("GetEntityBBox")
		if type(get_entity_bbox) == "function" then
			local ok_bbox, bbox = pcall(get_entity_bbox, entity)
			if ok_bbox then entity_bbox = WonderVerticalDiagnostics.SafeBoxZStats(bbox) end
		end
		local terrain_api = Global("terrain")
		local center_terrain_z
		if marker_pos and type(terrain_api) == "table"
			and type(terrain_api.GetHeight) == "function" then
			local ok_height, height = pcall(terrain_api.GetHeight, map, marker_pos)
			if ok_height and type(height) == "number" then center_terrain_z = height end
		end
		local shape_stats = WonderVerticalDiagnostics.ShapeVerticalStats(
			map, shape, marker, source_z)
		marker.SuperBigMapNativeWonderEntityBBoxMinZ = entity_bbox and entity_bbox.min_z
		marker.SuperBigMapNativeWonderEntityBBoxMaxZ = entity_bbox and entity_bbox.max_z
		marker.SuperBigMapNativeWonderEntityBBoxSizeZ = entity_bbox and entity_bbox.size_z
		marker.SuperBigMapNativeWonderSourceTerrainZ = center_terrain_z
		marker.SuperBigMapNativeWonderSourceTerrainMinZ = shape_stats.terrain_min_z
		marker.SuperBigMapNativeWonderSourceTerrainMaxZ = shape_stats.terrain_max_z
		payload.center_terrain_z = center_terrain_z
		payload.entity_bbox_min_z = entity_bbox and entity_bbox.min_z
		payload.entity_bbox_max_z = entity_bbox and entity_bbox.max_z
		payload.entity_bbox_size_z = entity_bbox and entity_bbox.size_z
		payload.footprint_samples = shape_stats.samples
		payload.footprint_terrain_min_z = shape_stats.terrain_min_z
		payload.footprint_terrain_max_z = shape_stats.terrain_max_z
		payload.footprint_terrain_at_flatten = shape_stats.terrain_at_target
		payload.footprint_terrain_above_flatten = shape_stats.terrain_above_target
		payload.footprint_terrain_below_flatten = shape_stats.terrain_below_target
		payload.footprint_buildable_min_z = shape_stats.buildable_min_z
		payload.footprint_buildable_max_z = shape_stats.buildable_max_z
		payload.footprint_buildable_at_flatten = shape_stats.buildable_at_target
		payload.footprint_buildable_above_flatten = shape_stats.buildable_above_target
		payload.footprint_buildable_below_flatten = shape_stats.buildable_below_target
	end
	LoadingStep("underground buried wonder source vertical geometry", payload, map)
	return true
end

local function VerifyBootstrapPassages(map, passages, expected)
	local surface_map = Global("MainMap")
	local linked, committed_pairs = 0, 0
	for index, underground_passage in ipairs(passages or {}) do
		local surface_passage = underground_passage and underground_passage.other
		if surface_passage and surface_passage.other == underground_passage
			and type(surface_passage.GetMap) == "function"
			and type(underground_passage.GetMap) == "function"
			and surface_passage:GetMap() == surface_map
			and underground_passage:GetMap() == map then
			linked = linked + 1
			local spos, upos = surface_passage:GetPos(), underground_passage:GetPos()
			local sx, sy = PointXY(spos)
			local ux, uy = PointXY(upos)
			local final_x = tonumber(underground_passage.SuperBigMapCommittedPassageX)
			local final_y = tonumber(underground_passage.SuperBigMapCommittedPassageY)
			local source_x = tonumber(underground_passage.SuperBigMapCommittedPassageSourceX)
			local source_y = tonumber(underground_passage.SuperBigMapCommittedPassageSourceY)
			if underground_passage.SuperBigMapCommittedPassageLocked == true
				and surface_passage.SuperBigMapCommittedPassageLocked == true
				and final_x == tonumber(surface_passage.SuperBigMapCommittedPassageX)
				and final_y == tonumber(surface_passage.SuperBigMapCommittedPassageY)
				and sx == final_x and sy == final_y and ux == source_x and uy == source_y then
				committed_pairs = committed_pairs + 1
			end
			local ok_underground, underground_valid = pcall(
				underground_passage.IsValidPlacement, underground_passage)
			local ok_surface, surface_valid = pcall(
				surface_passage.IsValidPlacement, surface_passage)
			-- Diagnostic only: SurfacePassageBase:IsValidPlacement calls GetBuildableGrid(self),
			-- whose ambient map lookup can observe the expanded backing while this transaction is
			-- deliberately presenting the underground source view. The common-hex planner performs
			-- the same vanilla flat test plus complete shape/slope/passability/obstruction validation
			-- with explicit map objects before and after each move; that result is authoritative here.
			ExpansionAudit("PASSAGE_BOOTSTRAP_OBJECT_METHOD_OBSERVATION", {
				pair = index,
				underground_call_ok = ok_underground,
				underground_valid = underground_valid,
				surface_call_ok = ok_surface,
				surface_valid = surface_valid,
				linked = true,
				committed = sx == final_x and sy == final_y and ux == source_x and uy == source_y,
			}, map)
		end
	end
	return #(passages or {}) == expected and linked == expected and committed_pairs == expected
end

local function BootstrapPassagesAndDeferWonders(env)
	local map = env and env.map
	local ready, reason = DeferredArtefactPreflight(map)
	if not ready then return false, reason end
	local surface_map = Global("MainMap")
	if type(surface_map) ~= "table" or surface_map == map
		or type(surface_map.mapdata) ~= "table" or surface_map.mapdata.Environment ~= "Surface" then
		return false, "surface map is unavailable"
	end
	local rhelpers = env.rhelpers
	local rand = type(rhelpers) == "table" and rhelpers[1]
	if type(rand) ~= "function" then return false, "vanilla random helper is unavailable" end
	local table_lib = Global("table") or table
	if type(table_lib) ~= "table" or type(table_lib.shuffle) ~= "function" then
		return false, "table.shuffle is unavailable"
	end

	local wonder_markers = ArtefactMapGet(map, "BuriedWonderMarker")
	local passage_markers = ArtefactMapGet(map, "SurfacePassageMarker")
	local desired_passages = 2
	if #passage_markers < desired_passages then
		return false, "only " .. tostring(#passage_markers)
			.. " SurfacePassageMarker objects exist; need " .. tostring(desired_passages)
	end

	-- Consume the PlaceArtefacts PRNG exactly as vanilla does: wonder-class shuffle first,
	-- passage-marker shuffle second. Only construction is deferred; all assignments are fixed now.
	local const_tbl = Global("const")
	if type(const_tbl) ~= "table" or type(const_tbl.RandomMap) ~= "table"
		or type(const_tbl.RandomMap.UndergroundPassagesMinDistance) ~= "number" then
		return false, "const.RandomMap.UndergroundPassagesMinDistance is unavailable"
	end
	local wonder_classes = {}
	for i, class_name in ipairs(type(const_tbl) == "table" and const_tbl.BuriedWonders or {}) do
		wonder_classes[i] = class_name
	end
	if #wonder_markers > 0 and #wonder_classes == 0 then
		return false, "const.BuriedWonders is unavailable"
	end
	if #wonder_markers > 0 then
		table_lib.shuffle(wonder_classes, rand)
		for index, marker in ipairs(wonder_markers) do
			-- Capture the authoritative vanilla transform while generation still exposes the untouched
			-- source map.  These values survive TransferToMap and make the later stretch independent of
			-- any cosmetic-object pass or hot-reload history.  In particular, visual scale must be
			-- source_scale * map_ratio exactly once; using the marker's live post-stretch scale produced
			-- 177%-sized Jumbo Caves on a 4/3 map instead of the intended 133%.
			local marker_pos = type(marker.GetPos) == "function" and marker:GetPos() or nil
			local marker_x, marker_y = PointXY(marker_pos)
			if type(marker.SuperBigMapNativeSourceX) ~= "number"
				and type(marker_x) == "number" then
				marker.SuperBigMapNativeSourceX = marker_x
			end
			if type(marker.SuperBigMapNativeSourceY) ~= "number"
				and type(marker_y) == "number" then
				marker.SuperBigMapNativeSourceY = marker_y
			end
			if type(marker.SuperBigMapNativeSourceZ) ~= "number" and marker_pos then
				local marker_z
				pcall(function() marker_z = marker_pos:z() end)
				if type(marker_z) == "number" then
					marker.SuperBigMapNativeSourceZ = marker_z
				end
			end
			if type(marker.SuperBigMapNativeSourceScale) ~= "number"
				and type(marker.GetScale) == "function" then
				local marker_scale = marker:GetScale()
				if type(marker_scale) == "number" and marker_scale > 0 then
					marker.SuperBigMapNativeSourceScale = marker_scale
				end
			end
			local wonder_class = wonder_classes[1 + ((index - 1) % #wonder_classes)]
			marker.SuperBigMapDeferredWonderClass = wonder_class
			marker.SuperBigMapDeferredWonderIndex = index
			local target_ok, target_error = CaptureDeferredWonderSourceFlattenTarget(
				map, marker, wonder_class)
			if target_ok ~= true then
				return false, "failed to capture vanilla " .. tostring(wonder_class)
					.. " flatten target: " .. tostring(target_error)
			end
		end
	end
	-- Stock PlaceArtefacts constructs and clears assigned wonders before it shuffles/clears the
	-- passage anchors. Preserve that native obstruction transaction now and destroy each live marker
	-- at the same boundary as stock. Only value records survive through START; temporary wonders live
	-- through passage clearance and are then removed, so neither kind of live wonder object can alter
	-- later obstruction generation.
	local native_wonders = {}
	local deferred_wonder_records = {}
	map:SuspendPassEdits("SuperBigMap_NativeWonderClearance")
	local native_clear_ok, native_clear_err = pcall(function()
		for _, marker in ipairs(wonder_markers) do
			local wonder_class = marker.SuperBigMapDeferredWonderClass
			local wonder = ArtefactSpawnMarkerBuilding(marker, wonder_class, map)
			native_wonders[#native_wonders + 1] = wonder
			local flatten_ok, flatten_stats =
				WonderVerticalDiagnostics.FlattenDeferredWonder(wonder, marker, nil, true)
			if flatten_ok ~= true then
				error("failed native bootstrap clearance for " .. tostring(wonder_class)
					.. ": " .. tostring(flatten_stats))
			end
			marker.SuperBigMapNativeWonderClearanceDone = true
			marker.SuperBigMapNativeWonderFlattenZ = flatten_stats.buildable_z
			deferred_wonder_records[#deferred_wonder_records + 1] =
				SuperBigMap.CaptureDeferredWonderMarkerRecord(marker)
			Global("DoneObject")(marker)
			LoadingStep("native underground wonder footprint cleared", {
				class = wonder_class,
				flatten_z = flatten_stats.buildable_z,
				clearance_mode = flatten_stats.clearance_mode,
			}, map)
		end
	end)
	local native_resume_ok, native_resume_err = pcall(
		map.ResumePassEdits, map, "SuperBigMap_NativeWonderClearance")
	if not native_clear_ok or not native_resume_ok then
		for _, wonder in ipairs(native_wonders) do pcall(Global("DoneObject"), wonder) end
		error("native bootstrap wonder clearance failed: "
			.. tostring(native_clear_ok and native_resume_err or native_clear_err))
	end
	map.SuperBigMapDeferredUndergroundWonderRecords = deferred_wonder_records
	if type(WonderVerticalDiagnostics.LogCoverage) == "function" then
		WonderVerticalDiagnostics.LogCoverage(map, "source_plan")
	end
	table_lib.shuffle(passage_markers, rand)

	-- NATIVE PASSAGE SPAWN WITHOUT THE SOURCE-POSE FLATTEN (config
	-- PASSAGE_NATIVE_SPAWN_NO_FLATTEN). Vanilla SpawnUndergroundPassage
	-- (Lua\Buildings\SurfacePassage.lua:126) ends with
	-- FlattenTerrainInBuildShape(shape, passage, "flatten unbuildable") (:139), which carves the
	-- Elevator footprint into the LIVE terrain at the level map.buildable.z_grid reports on those
	-- hexes (Lua\Construction\Construction.lua:1842-1870). This bootstrap runs that spawner on the
	-- EXPANDED surface map while the SOURCE-space buildable bridge installed above is in place, so
	-- the flatten writes a source-pose, SOURCE-level hexagon into already transformed ground:
	-- measured at 30S146E as two stale craters, 9.7 m and 33.0 m below the plain around them, one
	-- per passage pair, still present at the end of generation. The pad the finished map needs is
	-- the one prepare_passage_pad (sbm_terrain_copy) carves later at the COMMITTED destination
	-- pose; this one is pure damage. The site choice is made before the flatten and does not read
	-- it back, so dropping that single terrain edit leaves the selection untouched.
	-- The engine global itself cannot be wrapped from mod code (the mod's _G is the sandbox env -
	-- see the GetMapSize note below), so the spawner's remaining steps are reproduced here against
	-- the same globals, in the same order, which keeps the random draws, the placed object and its
	-- returned shape identical to vanilla's.
	local spawn_surface_anchor = Global("SpawnUndergroundPassage")
	if cfg_bool("PASSAGE_NATIVE_SPAWN_NO_FLATTEN", true) then
		local snap_world_to_hex = Global("SnapWorldToHex")
		local snap_world_to_hex_angle = Global("SnapWorldToHexAngle")
		local extended_spawn_shape = Global("GetExtendedSpawnShape")
		local find_passage_spawn_pos = Global("FindPassageSpawnPos")
		local place_building_in = Global("PlaceBuildingIn")
		local permanent_flag = const_tbl and const_tbl.gofPermanent
		if type(snap_world_to_hex) ~= "function" or type(snap_world_to_hex_angle) ~= "function"
			or type(extended_spawn_shape) ~= "function"
			or type(find_passage_spawn_pos) ~= "function"
			or type(place_building_in) ~= "function" or permanent_flag == nil then
			error("native passage spawn without the source-pose flatten is unavailable")
		end
		spawn_surface_anchor = function(spawn_map, pos, angle, min_dist, passages)
			pos = snap_world_to_hex(pos)
			angle = snap_world_to_hex_angle(angle)
			local shape = extended_spawn_shape("Elevator")
			local position = find_passage_spawn_pos(spawn_map, spawn_map.object_hex_grid,
				spawn_map.buildable, pos, angle, shape, min_dist, passages)
			if not position then return end
			position = spawn_map:SnapToTerrain(position)
			local passage = place_building_in("UndergroundPassage", spawn_map)
			passage:SetPos(position)
			passage:SetAngle(angle)
			passage:SetGameFlags(permanent_flag)
			-- Vanilla's FlattenTerrainInBuildShape call is deliberately omitted here.
			return passage, shape
		end
	end
	local get_shape = Global("GetExtendedSpawnShape")
	local for_each_hex = Global("HexShapeForEach")
	local hex_to_world = Global("HexToWorld")
	local world_to_hex = Global("WorldToHex")
	local unbuildable_z = Global("buildUnbuildableZ")()
	local done_object = Global("DoneObject")
	local pending_surface_buildable =
		surface_map.SuperBigMapPendingNativeSurfacePassageBuildable
	if type(pending_surface_buildable) ~= "table"
		or not pending_surface_buildable.grid then
		error("native surface passage buildable grid was not retained")
	end
	local stock_surface_grid = surface_map.buildable and surface_map.buildable.z_grid
	if not stock_surface_grid or type(stock_surface_grid.size) ~= "function" then
		error("expanded surface passage buildable grid is unavailable")
	end
	local ok_stock_size, expanded_hex_w, expanded_hex_h = pcall(
		stock_surface_grid.size, stock_surface_grid)
	expanded_hex_h = expanded_hex_h or expanded_hex_w
	local source_hex_w = tonumber(pending_surface_buildable.width)
	local source_hex_h = tonumber(pending_surface_buildable.height)
	if not ok_stock_size or type(expanded_hex_w) ~= "number"
		or type(expanded_hex_h) ~= "number" or type(source_hex_w) ~= "number"
		or type(source_hex_h) ~= "number" or expanded_hex_w < source_hex_w
		or expanded_hex_h < source_hex_h then
		error("native/expanded surface passage buildable dimensions are invalid")
	end
	local new_grid = Global("NewGrid")
	if type(new_grid) ~= "function" then
		error("NewGrid unavailable for surface passage buildable bridge")
	end
	local padded_surface_grid = new_grid(expanded_hex_w, expanded_hex_h, 16, unbuildable_z)
	if not padded_surface_grid or type(padded_surface_grid.set) ~= "function"
		or type(pending_surface_buildable.grid.get) ~= "function" then
		SuperBigMap.FreeOwnedGrid(padded_surface_grid)
		error("surface passage buildable bridge allocation failed")
	end
	local pause_ild = Global("PauseInfiniteLoopDetection")
	local resume_ild = Global("ResumeInfiniteLoopDetection")
	if type(pause_ild) == "function" then
		pcall(pause_ild, "SBMNativeSurfacePassageBuildableBridge")
	end
	local copy_ok, copy_error = pcall(function()
		for y = 0, source_hex_h - 1 do
			for x = 0, source_hex_w - 1 do
				padded_surface_grid:set(x, y, pending_surface_buildable.grid:get(x, y))
			end
		end
	end)
	if type(resume_ild) == "function" then
		pcall(resume_ild, "SBMNativeSurfacePassageBuildableBridge")
	end
	if not copy_ok then
		SuperBigMap.FreeOwnedGrid(padded_surface_grid)
		error("surface passage buildable bridge copy failed: " .. tostring(copy_error))
	end
	surface_map.buildable.z_grid = padded_surface_grid
	local restore_fallback_radius
	local restore_passability_bridge
	local function RestoreSurfaceBuildableBridge()
		if restore_fallback_radius then
			restore_fallback_radius()
			restore_fallback_radius = nil
		end
		if restore_passability_bridge then
			restore_passability_bridge()
			restore_passability_bridge = nil
		end
		ReleaseRetainedNativeSourceMap(surface_map, "passage bootstrap selection window closed")
		surface_map.buildable.z_grid = stock_surface_grid
		SuperBigMap.FreeOwnedGrid(padded_surface_grid)
		SuperBigMap.FreeOwnedGrid(pending_surface_buildable.grid)
		pending_surface_buildable.grid = nil
		surface_map.SuperBigMapPendingNativeSurfacePassageBuildable = nil
	end
	LoadingStep("native surface passage buildable bridge installed", {
		source_width = source_hex_w, source_height = source_hex_h,
		expanded_width = expanded_hex_w, expanded_height = expanded_hex_h,
	}, surface_map)
	-- SOURCE-SIZED FALLBACK SEARCH RADIUS (config PAIRING_SOURCE_FALLBACK_RADIUS). When the
	-- buildable search around a marker fails, vanilla FindPassageSpawnPos
	-- (Lua/Buildings/SurfacePassage.lua:119) retries from GetRandomPassableAroundOnMap(map, pos)
	-- with no radius and Lua/Pathfinding.lua:165 defaults max_radius to Max(map:GetMapSize())/2.
	-- On this map that is the EXPANDED extent, so the same marker and the same random value pick a
	-- point up to a third further out than vanilla would - and the bridge just installed makes
	-- everything outside the retained source square unbuildable, so such a point can only fail,
	-- burn another draw and land the passage at a site vanilla could not choose. This whole
	-- selection runs in source space; the extent it measures itself against must be the source
	-- map's too.
	--
	-- The substitution is an INSTANCE-LEVEL GetMapSize shadow on this one map, not a global or
	-- class patch: mod code cannot replace an engine global (mod _G is the sandbox env, so
	-- engine-internal callers keep resolving the stock function - measured, iter-008), while a
	-- plain field on the shared map object shadows Map.GetMapSize (CommonLua/Core/map.lua:51 =
	-- terrain.GetMapSize) for exactly this map and only for Lua callers. Vanilla's own default
	-- expression then produces the native radius unchanged. The window is the synchronous
	-- selection loop below; a concurrent thread reading this map's size inside it would see the
	-- source extent, which is the same view the buildable bridge already presents. Restored by
	-- RestoreSurfaceBuildableBridge.
	if cfg_bool("PAIRING_SOURCE_FALLBACK_RADIUS", true) then
		local height_tile_size = tonumber(const_tbl.HeightTileSize)
		local function SourceWorldExtent(world_field, tile_field)
			local world = tonumber(surface_map[world_field])
			if world and world > 0 then return world end
			local tiles = tonumber(surface_map[tile_field])
			if tiles and tiles > 0 and height_tile_size and height_tile_size > 0 then
				return tiles * height_tile_size
			end
			return nil
		end
		local source_world_w = SourceWorldExtent("SuperBigMapGeneratorWidth",
			"SuperBigMapGeneratorWidthTiles")
			or SourceWorldExtent("SuperBigMapSourceWidth", "SuperBigMapSourceWidthTiles")
		local source_world_h = SourceWorldExtent("SuperBigMapGeneratorHeight",
			"SuperBigMapGeneratorHeightTiles")
			or SourceWorldExtent("SuperBigMapSourceHeight", "SuperBigMapSourceHeightTiles")
		local ok_world_size, expanded_world_w, expanded_world_h = pcall(
			surface_map.GetMapSize, surface_map)
		expanded_world_h = expanded_world_h or expanded_world_w
		if not ok_world_size or type(expanded_world_w) ~= "number"
			or type(expanded_world_h) ~= "number" or type(source_world_w) ~= "number"
			or type(source_world_h) ~= "number" or source_world_w <= 0 or source_world_h <= 0
			or source_world_w > expanded_world_w or source_world_h > expanded_world_h then
			RestoreSurfaceBuildableBridge()
			error("native surface extent for the passage fallback radius is unavailable")
		end
		-- Vanilla's own expression (Lua/Pathfinding.lua:165), evaluated on the source extent
		-- (engine Max is not visible from the mod environment; math.max is identical for two
		-- numbers).
		local source_max_radius = math.max(source_world_w, source_world_h) / 2
		if rawget(surface_map, "GetMapSize") ~= nil then
			RestoreSurfaceBuildableBridge()
			error("surface map already shadows GetMapSize; refusing to nest the source extent view")
		end
		-- A counter, not just a flag: an installed-but-never-consulted shadow (calls == 0) means
		-- the fallback radius came from somewhere else, which is a different defect from a wrong
		-- value. The parity harness reads these fields back in its fallback record.
		surface_map.SuperBigMapPassageFallbackRadius = source_max_radius
		surface_map.SuperBigMapPassageFallbackRadiusCalls = 0
		local size_shadow
		size_shadow = function(self)
			surface_map.SuperBigMapPassageFallbackRadiusCalls =
				(surface_map.SuperBigMapPassageFallbackRadiusCalls or 0) + 1
			return source_world_w, source_world_h
		end
		surface_map.GetMapSize = size_shadow
		restore_fallback_radius = function()
			if rawget(surface_map, "GetMapSize") == size_shadow then
				surface_map.GetMapSize = nil
			end
		end
		LoadingStep("native surface passage fallback radius pinned to the source extent", {
			source_width = source_world_w, source_height = source_world_h,
			expanded_width = expanded_world_w, expanded_height = expanded_world_h,
			max_radius = source_max_radius,
		}, surface_map)
	end
	-- SOURCE PASSABILITY FOR THE FALLBACK DRAW (config PAIRING_SOURCE_PASSABILITY_BRIDGE). With the
	-- buildable answer and the radius already presented in source terms, the last expanded-map input
	-- left in vanilla's fallback is the passable set itself: GetRandomPassableAroundOnMap resolves
	-- map:GetRandomPassablePoint (Lua/Pathfinding.lua:168), and that native chooser reads the map's
	-- own pathfinding field. Measured at 45S82E: identical center, radius and seed, yet the control's
	-- own point is IMPASSABLE on the expanded map and only 4713 of 16384 samples over the same source
	-- square are passable there against the control's 7576 (iter-011). Delegate the query to the
	-- retained native backing, whose field IS the source's, via the same instance-shadow mechanism
	-- the radius uses: it is a method lookup on the map table, so it reaches the engine-internal
	-- caller that a mod-side global replacement cannot. A counter records consultations; zero is
	-- legitimate (the fallback only runs when the buildable search around a marker fails).
	if cfg_bool("PAIRING_SOURCE_PASSABILITY_BRIDGE", true) then
		local retention = surface_map.SuperBigMapRetainedNativeSourceMap
		local source_map = type(retention) == "table" and retention.map or nil
		if type(source_map) ~= "table" or type(source_map.GetRandomPassablePoint) ~= "function"
			or type(source_map.GetPassablePointNearby) ~= "function" then
			RestoreSurfaceBuildableBridge()
			error("retained native source map for the passage passability bridge is unavailable")
		end
		if rawget(surface_map, "GetRandomPassablePoint") ~= nil
			or rawget(surface_map, "GetPassablePointNearby") ~= nil then
			RestoreSurfaceBuildableBridge()
			error("surface map already shadows the passable-point API; refusing to nest the source view")
		end
		surface_map.SuperBigMapPassagePassableBridgeCalls = 0
		surface_map.SuperBigMapPassagePassableBridgeNearbyCalls = 0
		local random_point_shadow, nearby_shadow
		random_point_shadow = function(self, ...)
			surface_map.SuperBigMapPassagePassableBridgeCalls =
				(surface_map.SuperBigMapPassagePassableBridgeCalls or 0) + 1
			return source_map:GetRandomPassablePoint(...)
		end
		-- GetRandomPassable (Lua/Pathfinding.lua:161) is the fallback's second half; it has never been
		-- reached in a measured run, but leaving it on the expanded field would reintroduce exactly the
		-- defect this bridge removes.
		nearby_shadow = function(self, ...)
			surface_map.SuperBigMapPassagePassableBridgeNearbyCalls =
				(surface_map.SuperBigMapPassagePassableBridgeNearbyCalls or 0) + 1
			return source_map:GetPassablePointNearby(...)
		end
		surface_map.GetRandomPassablePoint = random_point_shadow
		surface_map.GetPassablePointNearby = nearby_shadow
		restore_passability_bridge = function()
			if rawget(surface_map, "GetRandomPassablePoint") == random_point_shadow then
				surface_map.GetRandomPassablePoint = nil
			end
			if rawget(surface_map, "GetPassablePointNearby") == nearby_shadow then
				surface_map.GetPassablePointNearby = nil
			end
		end
		LoadingStep("native surface passage passability bridged to the retained source map", {
			source_slot = tostring(retention.slot),
		}, surface_map)
	end
	local successful = {}
	map:SuspendPassEdits("SuperBigMap_PassageBootstrap")
	local ok, err = pcall(function()
		while #successful < desired_passages and #passage_markers > 0 do
			local marker = table.remove(passage_markers)
			local surface_anchor, surface_shape = spawn_surface_anchor(surface_map,
				marker:GetPos(), marker:GetAngle(), const_tbl.RandomMap.UndergroundPassagesMinDistance,
				successful)
			if surface_anchor then
				-- The bootstrap runs SpawnUndergroundPassage against the source buildable data
				-- bridged into the expanded grid, so the anchor lands on the SAME coordinate the
				-- vanilla twin's passage occupies. Record it before the later final commitment moves
				-- the anchor into the expanded domain; the CityInit tunnel marker, its sign, and the
				-- attached decal then inherit this record through their creation chain.
				local provenance = SuperBigMap.Provenance
				if provenance and type(provenance.RecordNativeSpawn) == "function" then
					SafeCall(provenance.RecordNativeSpawn, surface_anchor,
						"native_spawn", "SpawnUndergroundPassage")
				end
				ArtefactClearObstructions(surface_anchor, surface_map.obj_prefab_marker,
					surface_anchor:GetPos(), surface_shape)
				local underground_anchor = ArtefactSpawnMarkerBuilding(marker, "SurfacePassage", map)
				if provenance and type(provenance.RecordNativeSpawn) == "function" then
					SafeCall(provenance.RecordNativeSpawn, underground_anchor,
						"native_spawn", "ArtefactSpawnMarkerBuilding")
				end
				underground_anchor:Link(surface_anchor)
				successful[#successful + 1] = underground_anchor

				local shape = get_shape("Elevator")
				local landscape_pos
				if map.buildable:GetZ(world_to_hex(underground_anchor)) == unbuildable_z then
					local closest_2d2
					for_each_hex(shape, underground_anchor, function(q, r, idx)
						local hex = shape[idx]
						local hex_center = Global("point")(hex_to_world(q, r))
						local build_z = map.buildable:GetZ(q, r)
						if build_z ~= unbuildable_z then
							local hx, hy = hex:xy()
							local dist2 = hx * hx + hy * hy
							if not landscape_pos or dist2 < closest_2d2 then
								landscape_pos, closest_2d2 = hex_center, dist2
							end
						end
					end)
				end
				ArtefactClearObstructions(underground_anchor, map.obj_prefab_marker, landscape_pos, shape)
				if underground_anchor:IsValidPlacement() then
					done_object(marker)
				else
					marker.editor_text_color = Global("RGB")(255, 0, 0)
				end
			end
		end
		for _, marker in ipairs(passage_markers) do done_object(marker) end
	end)
	local resume_ok, resume_err = pcall(map.ResumePassEdits, map, "SuperBigMap_PassageBootstrap")
	RestoreSurfaceBuildableBridge()
	if not ok or not resume_ok then
		for _, wonder in ipairs(native_wonders) do pcall(done_object, wonder) end
		if not ok then error("passage-only artefact bootstrap failed: " .. tostring(err)) end
		error("passage bootstrap ResumePassEdits failed: " .. tostring(resume_err))
	end
	-- Stock actual wonders remain live through the later PlaceAnomalies and PlaceObstructions
	-- procedures. Keep these temporary source-domain objects until the ProcInvoke wrapper consumes
	-- the PlaceObstructions boundary, then remove them before the generated map is published.
	map.SuperBigMapPendingNativeWonderCleanup = native_wonders
	if type(AlignPassagePairsToSharedHex) ~= "function" then
		error("passage bootstrap common-hex planner is unavailable")
	end
	local plan_ok, plan_stats = AlignPassagePairsToSharedHex(map, { source_bootstrap = true })
	if plan_ok ~= true then
		error("passage bootstrap common-hex planning failed: "
			.. tostring(plan_stats and plan_stats.error or "unknown error"))
	end
	if not VerifyBootstrapPassages(map, successful, desired_passages) then
		error("passage bootstrap did not create two valid committed linked Elevator anchors")
	end

	map.SuperBigMapDeferredUndergroundWondersPending = #deferred_wonder_records > 0
	map.SuperBigMapDeferredUndergroundWondersDone = #deferred_wonder_records == 0
	map.SuperBigMapDeferredUndergroundWonderCount = #deferred_wonder_records
	map.SuperBigMapPassageBootstrapComplete = true
	map.SuperBigMapPassageBootstrapCount = #successful
	return true, {
		passages = #successful, wonders_deferred = #deferred_wonder_records,
		planned_pairs = plan_stats and plan_stats.pairs or 0,
	}
end

local function DeferredWonderScaleRatios(map)
	local source_width = tonumber(map and (map.SuperBigMapSourceWidthTiles
		or map.SuperBigMapGeneratorWidthTiles))
	local source_height = tonumber(map and (map.SuperBigMapSourceHeightTiles
		or map.SuperBigMapGeneratorHeightTiles or source_width))
	local full_width = tonumber(map and (map.SuperBigMapDesiredWidthTiles
		or (map.mapdata and map.mapdata.Width)))
	local full_height = tonumber(map and (map.SuperBigMapDesiredHeightTiles
		or (map.mapdata and map.mapdata.Height) or full_width))
	if not source_width or source_width <= 0 or not source_height or source_height <= 0
		or not full_width or full_width <= 0 or not full_height or full_height <= 0 then
		return nil, "underground wonder stretch dimensions are unavailable"
	end
	local scale_x = (full_width + 0.0) / source_width
	local scale_y = (full_height + 0.0) / source_height
	if scale_x <= 1 or scale_y <= 1 then
		return nil, "underground wonder stretch ratio is not greater than one"
	end
	-- Buried-wonder entities expose only one CObject scale. Allowing different X/Y map ratios
	-- would necessarily distort either their visual or their gameplay footprint. The underground
	-- pipeline is therefore a strict similarity transform even when a surface map uses a different
	-- aspect/height compensation strategy.
	if full_width * source_height ~= full_height * source_width then
		return nil, "underground wonder stretch is not uniform in X/Y"
	end
	return {
		scale_x = scale_x,
		scale_y = scale_x,
		uniform_scale = scale_x,
		x_mul = full_width,
		x_div = source_width,
		y_mul = full_width,
		y_div = source_width,
	}
end

function WonderVerticalDiagnostics.ExactStretchedSourceXY(source_x, source_y, map, ratios)
	source_x, source_y = tonumber(source_x), tonumber(source_y)
	if type(source_x) ~= "number" or type(source_y) ~= "number"
		or type(ratios) ~= "table" then
		return nil
	end
	local origin_x = tonumber(map and map.SuperBigMapSourceX) or 0
	local origin_y = tonumber(map and map.SuperBigMapSourceY) or 0
	local function transform(value, origin, mul, div)
		mul, div = tonumber(mul), tonumber(div)
		if type(mul) ~= "number" or type(div) ~= "number" or div <= 0 then return nil end
		local scaled = (value - origin) * (mul + 0.0) / div
		local rounded = scaled >= 0 and math.floor(scaled + 0.5) or math.ceil(scaled - 0.5)
		return origin + rounded
	end
	return transform(source_x, origin_x, ratios.x_mul, ratios.x_div),
		transform(source_y, origin_y, ratios.y_mul, ratios.y_div)
end

function WonderVerticalDiagnostics.ExactStretchedWonderXY(wonder, map, ratios)
	return WonderVerticalDiagnostics.ExactStretchedSourceXY(
		wonder and wonder.SuperBigMapWonderSourceX,
		wonder and wonder.SuperBigMapWonderSourceY,
		map, ratios)
end

-- Publish the complete final visual footprint of every deferred buried wonder before native
-- enrichments are recreated. The set is built once from the same scaled entity shapes and exact
-- affine anchors used during materialization, then every deposit placement query performs only a
-- single hash lookup. Unioning the enclosed and outline shapes covers both the playable interior
-- and the authored wall/crystal geometry without adding an artificial clearance ring.
function WonderVerticalDiagnostics.ReserveDeferredUndergroundWonderFootprints(map, deposit_rules)
	if type(deposit_rules) ~= "table"
		or type(deposit_rules.SetUndergroundWonderReservedHexes) ~= "function" then
		return false, { error = "underground wonder reservation API is unavailable" }
	end
	local ratios, ratio_error = DeferredWonderScaleRatios(map)
	if not ratios then return false, { error = tostring(ratio_error) } end
	local templates = Global("BuildingTemplates")
	local get_enclosed = Global("GetEnclosedShape")
	local get_outline = Global("GetEntityOutlineShape")
	local point_fn = Global("point")
	local world_to_hex = Global("WorldToHex")
	local rotate = Global("HexRotate")
	local angle_to_direction = Global("HexAngleToDirection")
	if type(templates) ~= "table" or type(get_enclosed) ~= "function"
		or type(get_outline) ~= "function" or type(point_fn) ~= "function"
		or type(world_to_hex) ~= "function" or type(rotate) ~= "function"
		or type(angle_to_direction) ~= "function"
		or type(ScaleHexShapeForExpansion) ~= "function" then
		return false, { error = "underground wonder footprint helpers are unavailable" }
	end

	local reserved, classes = {}, {}
	local wonders, source_shape_hexes, scaled_shape_hexes = 0, 0, 0
	for _, marker in ipairs(ArtefactMapGet(map, "BuriedWonderMarker")) do
		local class_name = marker and marker.SuperBigMapDeferredWonderClass
		if type(class_name) == "string" and class_name ~= "" then
			local template = templates[class_name]
			local entity = type(template) == "table" and template.entity or nil
			if type(entity) ~= "string" or entity == "" then
				return false, { error = "building entity unavailable for " .. tostring(class_name) }
			end
			local target_x, target_y = WonderVerticalDiagnostics.ExactStretchedSourceXY(
				marker.SuperBigMapNativeSourceX, marker.SuperBigMapNativeSourceY,
				map, ratios)
			if type(target_x) ~= "number" or type(target_y) ~= "number" then
				return false, { error = "exact transformed anchor unavailable for " .. class_name }
			end
			local ok_anchor, anchor_q, anchor_r = pcall(
				world_to_hex, point_fn(target_x, target_y))
			if not ok_anchor or type(anchor_q) ~= "number" or type(anchor_r) ~= "number" then
				return false, { error = "transformed anchor hex unavailable for " .. class_name }
			end
			local ok_direction, direction = pcall(angle_to_direction, marker)
			if not ok_direction or type(direction) ~= "number" then direction = 0 end
			local shapes = { get_enclosed(entity), get_outline(entity) }
			local instance_hexes = 0
			for _, source_shape in ipairs(shapes) do
				if type(source_shape) == "table" and #source_shape > 0 then
					source_shape_hexes = source_shape_hexes + #source_shape
					local scaled_shape = ScaleHexShapeForExpansion(
						source_shape, ratios.scale_x, ratios.scale_y)
					if type(scaled_shape) ~= "table" or #scaled_shape == 0 then
						return false, { error = "scaled footprint is empty for " .. class_name }
					end
					scaled_shape_hexes = scaled_shape_hexes + #scaled_shape
					for _, shape_point in ipairs(scaled_shape) do
						local local_q, local_r = PointXY(shape_point)
						if type(local_q) == "number" and type(local_r) == "number" then
							local ok_rotate, rotated_q, rotated_r = pcall(
								rotate, local_q, local_r, direction)
							if ok_rotate and type(rotated_q) == "number"
								and type(rotated_r) == "number" then
								local key = tostring(anchor_q + rotated_q)
									.. ":" .. tostring(anchor_r + rotated_r)
								if not reserved[key] then
									reserved[key] = true
									instance_hexes = instance_hexes + 1
								end
							end
						end
					end
				end
			end
			if instance_hexes == 0 then
				return false, { error = "no footprint hexes resolved for " .. class_name }
			end
			wonders = wonders + 1
			classes[class_name] = (classes[class_name] or 0) + 1
		end
	end
	local class_names = {}
	for class_name, count in pairs(classes) do
		class_names[#class_names + 1] = class_name .. "=" .. tostring(count)
	end
	table.sort(class_names)
	local stats = {
		wonders = wonders,
		classes = table.concat(class_names, ","),
		source_shape_hexes = source_shape_hexes,
		scaled_shape_hexes = scaled_shape_hexes,
	}
	local ok, result = deposit_rules.SetUndergroundWonderReservedHexes(map, reserved, stats)
	if ok ~= true then return false, result end
	stats.reserved_hexes = result and result.reserved_hexes or 0
	LoadingStep("underground buried wonder enrichment reservation", stats, map)
	return true, stats
end

function WonderVerticalDiagnostics.NearbyWonderGeometrySummary(map, wonder, object_bbox)
	local result = { count = 0, nearest = "" }
	if type(map) ~= "table" or type(map.MapGet) ~= "function" or not object_bbox then
		return result
	end
	local search_box
	pcall(function() search_box = object_bbox:grow(5000) end)
	if not search_box then return result end
	local ok_objects, objects = pcall(map.MapGet, map, search_box,
		"attached", false, "CObject")
	if not ok_objects or type(objects) ~= "table" then return result end
	local wonder_x, wonder_y = PointXY(type(wonder.GetPos) == "function" and wonder:GetPos())
	local rows = {}
	for _, object in ipairs(objects) do
		if object ~= wonder and type(object) == "table"
			and type(object.GetObjectBBox) == "function" then
			local ok_bbox, bbox = pcall(object.GetObjectBBox, object)
			local bbox_z = ok_bbox and WonderVerticalDiagnostics.SafeBoxZStats(bbox) or nil
			if bbox_z then
				local object_pos = type(object.GetPos) == "function" and object:GetPos() or nil
				local object_x, object_y = PointXY(object_pos)
				local dx = type(wonder_x) == "number" and type(object_x) == "number"
					and object_x - wonder_x or 0
				local dy = type(wonder_y) == "number" and type(object_y) == "number"
					and object_y - wonder_y or 0
				rows[#rows + 1] = {
					dist2 = dx * dx + dy * dy,
					text = tostring(object.class or "CObject")
						.. "/" .. tostring(type(object.GetEntity) == "function"
							and object:GetEntity() or "?")
						.. "@z" .. tostring(WonderVerticalDiagnostics.SafePointZ(object_pos))
						.. "[" .. tostring(bbox_z.min_z) .. "," .. tostring(bbox_z.max_z) .. "]"
						.. "s" .. tostring(type(object.GetScale) == "function"
							and object:GetScale() or "?"),
				}
			end
		end
	end
	table.sort(rows, function(a, b) return a.dist2 < b.dist2 end)
	result.count = #rows
	local nearest = {}
	for index = 1, math.min(12, #rows) do nearest[index] = rows[index].text end
	result.nearest = table.concat(nearest, "|")
	return result
end

function WonderVerticalDiagnostics.AttachmentSummary(wonder)
	local result = { count = 0, entries = "" }
	if not wonder or type(wonder.GetAttaches) ~= "function" then return result end
	local ok_attaches, attaches = pcall(wonder.GetAttaches, wonder)
	if not ok_attaches or type(attaches) ~= "table" then return result end
	local entries = {}
	for index, attach in ipairs(attaches) do
		if index > 24 then break end
		local pos = type(attach.GetPos) == "function" and attach:GetPos() or nil
		local bbox_z
		if type(attach.GetObjectBBox) == "function" then
			local ok_bbox, bbox = pcall(attach.GetObjectBBox, attach)
			if ok_bbox then bbox_z = WonderVerticalDiagnostics.SafeBoxZStats(bbox) end
		end
		entries[index] = tostring(attach.class or "CObject")
			.. "/" .. tostring(type(attach.GetEntity) == "function"
				and attach:GetEntity() or "?")
			.. "@z" .. tostring(WonderVerticalDiagnostics.SafePointZ(pos))
			.. "[" .. tostring(bbox_z and bbox_z.min_z) .. ","
			.. tostring(bbox_z and bbox_z.max_z) .. "]"
			.. "s" .. tostring(type(attach.GetScale) == "function"
				and attach:GetScale() or "?")
	end
	result.count = #attaches
	result.entries = table.concat(entries, "|")
	return result
end

function WonderVerticalDiagnostics.Snapshot(wonder, marker, map, ratios, flatten_stats, phase)
	local entity = type(wonder.GetEntity) == "function" and wonder:GetEntity() or nil
	local position = type(wonder.GetPos) == "function" and wonder:GetPos() or nil
	local visual_position = type(wonder.GetVisualPos) == "function"
		and wonder:GetVisualPos() or nil
	local object_bbox
	if type(wonder.GetObjectBBox) == "function" then
		local ok_bbox, bbox = pcall(wonder.GetObjectBBox, wonder)
		if ok_bbox then object_bbox = bbox end
	end
	local entity_bbox
	local get_entity_bbox = Global("GetEntityBBox")
	if type(get_entity_bbox) == "function" and type(entity) == "string" then
		local ok_bbox, bbox = pcall(get_entity_bbox, entity)
		if ok_bbox then entity_bbox = bbox end
	end
	local object_bbox_z = WonderVerticalDiagnostics.SafeBoxZStats(object_bbox)
	local entity_bbox_z = WonderVerticalDiagnostics.SafeBoxZStats(entity_bbox)
	local terrain_api = Global("terrain")
	local center_terrain_z
	if position and type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function" then
		local ok_height, height = pcall(terrain_api.GetHeight, map, position)
		if ok_height and type(height) == "number" then center_terrain_z = height end
	end
	local center_buildable_z
	local world_to_hex = Global("WorldToHex")
	if type(world_to_hex) == "function" and type(map.buildable) == "table"
		and type(map.buildable.GetZ) == "function" then
		local ok_hex, q, r = pcall(world_to_hex, wonder)
		if ok_hex then
			local ok_z, z = pcall(map.buildable.GetZ, map.buildable, q, r)
			if ok_z and type(z) == "number" then center_buildable_z = z end
		end
	end
	local shape
	local get_enclosed = Global("GetEnclosedShape")
	local get_outline = Global("GetEntityOutlineShape")
	local shrink = Global("ShrinkShape")
	if type(entity) == "string" and type(get_enclosed) == "function" then
		shape = get_enclosed(entity)
		if type(shape) == "table" and #shape == 0
			and type(get_outline) == "function" and type(shrink) == "function" then
			shape = shrink(get_outline(entity), 2)
		end
		if type(shape) == "table" and type(ratios) == "table" then
			shape = ScaleHexShapeForExpansion(shape, ratios.scale_x, ratios.scale_y)
		end
	end
	local target_z = flatten_stats and flatten_stats.buildable_z
		or tonumber(wonder.SuperBigMapWonderFlattenZ)
		or (marker and tonumber(marker.SuperBigMapNativeWonderFlattenZ))
	local shape_stats = WonderVerticalDiagnostics.ShapeVerticalStats(
		map, shape, wonder, target_z)
	local scale = type(wonder.GetScale) == "function" and wonder:GetScale() or nil
	local source_scale = tonumber(wonder.SuperBigMapWonderSourceScale)
		or (marker and tonumber(marker.SuperBigMapNativeSourceScale)) or 100
	local source_bbox_size_z = tonumber(wonder.SuperBigMapWonderSourceEntityBBoxSizeZ)
		or (marker and tonumber(marker.SuperBigMapNativeWonderEntityBBoxSizeZ))
	local source_flatten_z = tonumber(wonder.SuperBigMapWonderSourceFlattenZ)
		or (marker and tonumber(marker.SuperBigMapNativeWonderFlattenZ))
	local expected_bbox_size_from_object_scale = type(source_bbox_size_z) == "number"
		and type(scale) == "number" and source_scale > 0
		and source_bbox_size_z * scale / source_scale or nil
	local expected_bbox_size_from_map_scale = type(source_bbox_size_z) == "number"
		and type(ratios) == "table" and source_bbox_size_z * ratios.uniform_scale or nil
	local nearby = WonderVerticalDiagnostics.NearbyWonderGeometrySummary(
		map, wonder, object_bbox)
	local attachments = WonderVerticalDiagnostics.AttachmentSummary(wonder)
	return {
		phase = phase,
		class = tostring(wonder.class or marker and marker.SuperBigMapDeferredWonderClass or "?"),
		entity = entity,
		object_scale = scale,
		object_z = WonderVerticalDiagnostics.SafePointZ(position),
		visual_z = WonderVerticalDiagnostics.SafePointZ(visual_position),
		center_terrain_z = center_terrain_z,
		center_buildable_z = center_buildable_z,
		flatten_z = target_z,
		source_flatten_z = source_flatten_z,
		object_bbox_min_z = object_bbox_z and object_bbox_z.min_z,
		object_bbox_max_z = object_bbox_z and object_bbox_z.max_z,
		object_bbox_size_z = object_bbox_z and object_bbox_z.size_z,
		entity_bbox_min_z = entity_bbox_z and entity_bbox_z.min_z,
		entity_bbox_max_z = entity_bbox_z and entity_bbox_z.max_z,
		entity_bbox_size_z = entity_bbox_z and entity_bbox_z.size_z,
		source_entity_bbox_min_z = tonumber(wonder.SuperBigMapWonderSourceEntityBBoxMinZ)
			or (marker and tonumber(marker.SuperBigMapNativeWonderEntityBBoxMinZ)),
		source_entity_bbox_max_z = tonumber(wonder.SuperBigMapWonderSourceEntityBBoxMaxZ)
			or (marker and tonumber(marker.SuperBigMapNativeWonderEntityBBoxMaxZ)),
		source_entity_bbox_size_z = source_bbox_size_z,
		expected_bbox_size_from_object_scale = expected_bbox_size_from_object_scale,
		expected_bbox_size_from_map_scale = expected_bbox_size_from_map_scale,
		bbox_bottom_minus_flatten = object_bbox_z and type(target_z) == "number"
			and object_bbox_z.min_z - target_z or nil,
		bbox_top_minus_flatten = object_bbox_z and type(target_z) == "number"
			and object_bbox_z.max_z - target_z or nil,
		bbox_bottom_minus_center_terrain = object_bbox_z and type(center_terrain_z) == "number"
			and object_bbox_z.min_z - center_terrain_z or nil,
		footprint_samples = shape_stats.samples,
		footprint_terrain_min_z = shape_stats.terrain_min_z,
		footprint_terrain_max_z = shape_stats.terrain_max_z,
		footprint_terrain_at_flatten = shape_stats.terrain_at_target,
		footprint_terrain_above_flatten = shape_stats.terrain_above_target,
		footprint_terrain_below_flatten = shape_stats.terrain_below_target,
		footprint_buildable_min_z = shape_stats.buildable_min_z,
		footprint_buildable_max_z = shape_stats.buildable_max_z,
		footprint_buildable_at_flatten = shape_stats.buildable_at_target,
		footprint_buildable_above_flatten = shape_stats.buildable_above_target,
		footprint_buildable_below_flatten = shape_stats.buildable_below_target,
		nearby_geometry_count = nearby.count,
		nearby_geometry = nearby.nearest,
		attachment_count = attachments.count,
		attachments = attachments.entries,
	}
end

function WonderVerticalDiagnostics.Log(wonder, marker, map, ratios, flatten_stats, phase)
	if not WonderGeometryDiagnosticsEnabled() then return true end
	local ok, payload = pcall(WonderVerticalDiagnostics.Snapshot,
		wonder, marker, map, ratios, flatten_stats, phase)
	if not ok then
		payload = {
			phase = phase,
			class = tostring(wonder and wonder.class
				or marker and marker.SuperBigMapDeferredWonderClass or "?"),
			diagnostic_error = tostring(payload),
		}
	end
	LoadingStep("underground buried wonder vertical geometry", payload, map)
	return ok
end

function WonderVerticalDiagnostics.LogCoverage(map, phase)
	if not WonderGeometryDiagnosticsEnabled() then return {} end
	local planned = {}
	for _, marker in ipairs(ArtefactMapGet(map, "BuriedWonderMarker")) do
		local class_name = marker.SuperBigMapDeferredWonderClass
		if type(class_name) == "string" and class_name ~= "" then
			planned[class_name] = (planned[class_name] or 0) + 1
		end
	end
	if next(planned) == nil then
		for _, record in ipairs(type(map.SuperBigMapDeferredUndergroundWonderRecords) == "table"
			and map.SuperBigMapDeferredUndergroundWonderRecords or {}) do
			local class_name = record.SuperBigMapDeferredWonderClass
			if type(class_name) == "string" and class_name ~= "" then
				planned[class_name] = (planned[class_name] or 0) + 1
			end
		end
	end
	local live = {}
	for _, wonder in ipairs(ArtefactMapGet(map, "UndergroundWonder")) do
		local class_name = tostring(wonder.class or "")
		live[class_name] = (live[class_name] or 0) + 1
	end
	local templates = Global("BuildingTemplates")
	local get_entity_bbox = Global("GetEntityBBox")
	for _, class_name in ipairs(WonderVerticalDiagnostics.Classes) do
		local template = type(templates) == "table" and templates[class_name] or nil
		local entity = type(template) == "table" and template.entity or nil
		local entity_bbox
		if type(get_entity_bbox) == "function" and type(entity) == "string" then
			local ok_bbox, bbox = pcall(get_entity_bbox, entity)
			if ok_bbox then
				entity_bbox = WonderVerticalDiagnostics.SafeBoxZStats(bbox)
			end
		end
		local planned_count = planned[class_name] or 0
		local live_count = live[class_name] or 0
		LoadingStep("underground buried wonder class coverage", {
			phase = phase,
			class = class_name,
			entity = entity,
			planned_instances = planned_count,
			live_instances = live_count,
			selected_on_map = planned_count > 0 or live_count > 0,
			status = live_count > 0 and "live"
				or planned_count > 0 and "planned_not_materialized"
				or "not_selected_by_vanilla_for_this_map",
			entity_bbox_min_z = entity_bbox and entity_bbox.min_z,
			entity_bbox_max_z = entity_bbox and entity_bbox.max_z,
			entity_bbox_size_z = entity_bbox and entity_bbox.size_z,
		}, map)
	end
	return live
end

function WonderVerticalDiagnostics.LogAll(map, phase)
	if not WonderGeometryDiagnosticsEnabled() then return 0 end
	local ratios = DeferredWonderScaleRatios(map)
	WonderVerticalDiagnostics.LogCoverage(map, phase)
	if type(ratios) ~= "table" then return 0 end
	local count = 0
	for _, wonder in ipairs(ArtefactMapGet(map, "UndergroundWonder")) do
		WonderVerticalDiagnostics.Log(wonder, nil, map, ratios, nil, phase)
		count = count + 1
	end
	return count
end

-- Versions 1-3 of the removed buried-wonder darkness policy could leave a live or saved wonder at
-- zero opacity (or with efVisible cleared) and could leave UndergroundWonder.UpdateRevealObject
-- wrapped across an in-session reload. Stock vanilla deliberately renders buried wonders faintly
-- before reveal, so v821 has no ongoing visibility policy. This one-shot migration only removes the
-- legacy wrapper and restores objects carrying the legacy stamps; untagged stock state is untouched.
function SuperBigMap.RestoreLegacyBuriedWonderConcealment()
	local State = SuperBigMap.State or {}
	local restored = 0
	local function restore_tree(root, seen, depth)
		depth = depth or 0
		if not root or seen[root] or depth > 6 then return end
		seen[root] = true
		if type(root.SetOpacity) == "function" then pcall(root.SetOpacity, root, 100) end
		if type(root.GetAttaches) == "function" then
			local ok, attaches = pcall(root.GetAttaches, root)
			if ok and type(attaches) == "table" then
				for _, attach in ipairs(attaches) do
					restore_tree(attach, seen, depth + 1)
				end
			end
		end
	end
	local maps = Global("Maps")
	if type(maps) == "table" then
		for _, map in pairs(maps) do
			if type(map) == "table" then
				for _, wonder in ipairs(ArtefactMapGet(map, "UndergroundWonder")) do
					local legacy = wonder.SuperBigMapConcealedByDarkness ~= nil
						or wonder.SuperBigMapDarknessVisibilityRestored ~= nil
						or wonder.SuperBigMapDarknessVisibilityReason ~= nil
					if legacy then
						if type(wonder.SetVisible) == "function" then
							pcall(wonder.SetVisible, wonder, true)
						end
						restore_tree(wonder, setmetatable({}, { __mode = "k" }), 0)
						restored = restored + 1
					end
					wonder.SuperBigMapConcealedByDarkness = nil
					wonder.SuperBigMapDarknessVisibilityRestored = nil
					wonder.SuperBigMapDarknessVisibilityReason = nil
				end
			end
		end
	end
	local class = Engine.ClassTable and Engine.ClassTable("UndergroundWonder")
	local unpatched = false
	if type(class) == "table"
		and class.UpdateRevealObject == State.buried_wonder_darkness_update_wrapper then
		if State.buried_wonder_darkness_update_had_raw_method == true then
			class.UpdateRevealObject = State.original_buried_wonder_update_reveal_object
		else
			class.UpdateRevealObject = nil
		end
		unpatched = true
	end
	State.original_buried_wonder_update_reveal_object = nil
	State.buried_wonder_darkness_update_had_raw_method = nil
	State.buried_wonder_darkness_update_wrapper = nil
	State.buried_wonder_darkness_patch_version = nil
	SuperBigMap.BuriedWonderDarkness = nil
	return restored, unpatched
end

local function ApplyDeferredWonderStretch(wonder, marker, map, ratios)
	if not wonder or not marker or type(ratios) ~= "table" then
		return false, "invalid underground wonder stretch arguments"
	end
	if not PatchUndergroundWonderShapePoints() then
		return false, "UndergroundWonder GetShapePoints patch unavailable"
	end
	local live_marker_scale = type(marker.GetScale) == "function" and marker:GetScale() or nil
	local source_marker_scale = tonumber(marker.SuperBigMapNativeSourceScale)
		or live_marker_scale
	if type(source_marker_scale) ~= "number" or source_marker_scale <= 0 then
		return false, "buried wonder marker scale unavailable"
	end
	local uniform_scale = tonumber(ratios.uniform_scale) or ratios.scale_x
	local expected_scale = math.max(1,
		math.min(500, math.floor(source_marker_scale * uniform_scale + 0.5)))
	local old_scale = type(wonder.GetScale) == "function" and wonder:GetScale()
		or live_marker_scale or source_marker_scale
	local had_grids = wonder.grids_applied == true
	local old_fields = {
		wonder.SuperBigMapWonderShapeScaleXMul,
		wonder.SuperBigMapWonderShapeScaleXDiv,
		wonder.SuperBigMapWonderShapeScaleYMul,
		wonder.SuperBigMapWonderShapeScaleYDiv,
	}
	local ok, result = pcall(function()
		local marker_pos = marker:GetPos()
		local wonder_pos = wonder:GetPos()
		local marker_x, marker_y = PointXY(marker_pos)
		local wonder_x, wonder_y = PointXY(wonder_pos)
		if type(marker_x) ~= "number" or type(marker_y) ~= "number"
			or wonder_x ~= marker_x or wonder_y ~= marker_y then
			error("replacement center mismatch: marker=" .. tostring(marker_x) .. ","
				.. tostring(marker_y) .. " wonder=" .. tostring(wonder_x) .. ","
				.. tostring(wonder_y))
		end
		local marker_angle = type(marker.GetAngle) == "function" and marker:GetAngle() or nil
		local wonder_angle = type(wonder.GetAngle) == "function" and wonder:GetAngle() or nil
		if marker_angle ~= wonder_angle then
			error("replacement angle mismatch: marker=" .. tostring(marker_angle)
				.. " wonder=" .. tostring(wonder_angle))
		end
		local marker_mirrored = type(marker.GetMirrored) == "function"
			and marker:GetMirrored() or nil
		local wonder_mirrored = type(wonder.GetMirrored) == "function"
			and wonder:GetMirrored() or nil
		if marker_mirrored ~= wonder_mirrored then
			error("replacement mirror mismatch: marker=" .. tostring(marker_mirrored)
				.. " wonder=" .. tostring(wonder_mirrored))
		end
		local expected_x = tonumber(marker.SuperBigMapExpectedStretchedX)
		local expected_y = tonumber(marker.SuperBigMapExpectedStretchedY)
		local raw_x = tonumber(marker.SuperBigMapRawStretchedX)
		local raw_y = tonumber(marker.SuperBigMapRawStretchedY)
		if expected_x and expected_y and (marker_x ~= expected_x or marker_y ~= expected_y) then
			error("marker center transform mismatch: expected=" .. tostring(expected_x) .. ","
				.. tostring(expected_y) .. " actual=" .. tostring(marker_x) .. ","
				.. tostring(marker_y))
		end
		if had_grids then
			if type(wonder.RemoveFromGrids) ~= "function" then error("RemoveFromGrids unavailable") end
			wonder:RemoveFromGrids()
			if wonder.grids_applied == true then error("vanilla wonder footprint remained registered") end
		end
		wonder.SuperBigMapWonderShapeScaleXMul = ratios.x_mul
		wonder.SuperBigMapWonderShapeScaleXDiv = ratios.x_div
		wonder.SuperBigMapWonderShapeScaleYMul = ratios.y_mul
		wonder.SuperBigMapWonderShapeScaleYDiv = ratios.y_div
		wonder.SuperBigMapWonderSourceScale = source_marker_scale
		wonder.SuperBigMapWonderSourceX = marker.SuperBigMapNativeSourceX
		wonder.SuperBigMapWonderSourceY = marker.SuperBigMapNativeSourceY
		wonder.SuperBigMapWonderSourceZ = marker.SuperBigMapNativeSourceZ
		wonder.SuperBigMapWonderSourceFlattenZ = marker.SuperBigMapNativeWonderFlattenZ
		wonder.SuperBigMapWonderSourceTerrainZ = marker.SuperBigMapNativeWonderSourceTerrainZ
		wonder.SuperBigMapWonderSourceTerrainMinZ = marker.SuperBigMapNativeWonderSourceTerrainMinZ
		wonder.SuperBigMapWonderSourceTerrainMaxZ = marker.SuperBigMapNativeWonderSourceTerrainMaxZ
		wonder.SuperBigMapWonderSourceEntityBBoxMinZ =
			marker.SuperBigMapNativeWonderEntityBBoxMinZ
		wonder.SuperBigMapWonderSourceEntityBBoxMaxZ =
			marker.SuperBigMapNativeWonderEntityBBoxMaxZ
		wonder.SuperBigMapWonderSourceEntityBBoxSizeZ =
			marker.SuperBigMapNativeWonderEntityBBoxSizeZ
		wonder.SuperBigMapWonderExpectedX = expected_x or marker_x
		wonder.SuperBigMapWonderExpectedY = expected_y or marker_y
		wonder.SuperBigMapWonderXYTransformMode = marker.SuperBigMapXYTransformMode
			or "exact_world_affine"
		if type(wonder.SetScale) ~= "function" then error("SetScale unavailable") end
		wonder:SetScale(expected_scale)
		if had_grids then
			if type(wonder.ApplyToGrids) ~= "function" then error("ApplyToGrids unavailable") end
			wonder:ApplyToGrids()
			if wonder.grids_applied ~= true then error("expanded wonder footprint was not registered") end
		end
		local actual_scale = type(wonder.GetScale) == "function" and wonder:GetScale() or nil
		if actual_scale ~= expected_scale then
			error("visual scale mismatch: expected=" .. tostring(expected_scale)
				.. " actual=" .. tostring(actual_scale))
		end
		local actual_shape = type(wonder.GetShapePoints) == "function"
			and wonder:GetShapePoints() or nil
		local get_outline = Global("GetEntityOutlineShape")
		local source_shape = type(get_outline) == "function"
			and get_outline(wonder:GetEntity()) or nil
		local expected_shape = ScaleHexShapeForExpansion(
			source_shape, ratios.scale_x, ratios.scale_y)
		if type(actual_shape) ~= "table" or #actual_shape == 0
			or type(expected_shape) ~= "table" or #actual_shape ~= #expected_shape then
			error("expanded wonder footprint mismatch: actual="
				.. tostring(type(actual_shape) == "table" and #actual_shape or "nil")
				.. " expected="
				.. tostring(type(expected_shape) == "table" and #expected_shape or "nil"))
		end
		return {
			source_scale = source_marker_scale,
			live_marker_scale = live_marker_scale,
			expected_scale = expected_scale,
			uniform_scale = uniform_scale,
			shape_hexes = #actual_shape,
			source_shape_hexes = type(source_shape) == "table" and #source_shape or 0,
			shape_area_ratio = type(source_shape) == "table" and #source_shape > 0
				and ((#actual_shape + 0.0) / #source_shape) or nil,
			expected_area_ratio = uniform_scale * uniform_scale,
			grids_applied = wonder.grids_applied == true,
			source_x = wonder.SuperBigMapWonderSourceX,
			source_y = wonder.SuperBigMapWonderSourceY,
			raw_x = raw_x,
			raw_y = raw_y,
			final_x = marker_x,
			final_y = marker_y,
			hex_snap_dx = type(raw_x) == "number" and marker_x - raw_x or nil,
			hex_snap_dy = type(raw_y) == "number" and marker_y - raw_y or nil,
			marker_angle = marker_angle,
			wonder_angle = wonder_angle,
			marker_mirrored = marker_mirrored,
			wonder_mirrored = wonder_mirrored,
			xy_transform_mode = marker.SuperBigMapXYTransformMode,
		}
	end)
	if ok then return true, result end

	-- This object has only just been created, but restore its vanilla footprint before reporting the
	-- failure so the surrounding deferred-materialization transaction never leaves stale grid cells.
	pcall(function()
		if wonder.grids_applied == true and type(wonder.RemoveFromGrids) == "function" then
			wonder:RemoveFromGrids()
		end
		wonder.SuperBigMapWonderShapeScaleXMul = old_fields[1]
		wonder.SuperBigMapWonderShapeScaleXDiv = old_fields[2]
		wonder.SuperBigMapWonderShapeScaleYMul = old_fields[3]
		wonder.SuperBigMapWonderShapeScaleYDiv = old_fields[4]
		wonder.SuperBigMapWonderSourceScale = nil
		wonder.SuperBigMapWonderSourceX = nil
		wonder.SuperBigMapWonderSourceY = nil
		wonder.SuperBigMapWonderSourceZ = nil
		wonder.SuperBigMapWonderSourceFlattenZ = nil
		wonder.SuperBigMapWonderSourceTerrainZ = nil
		wonder.SuperBigMapWonderSourceTerrainMinZ = nil
		wonder.SuperBigMapWonderSourceTerrainMaxZ = nil
		wonder.SuperBigMapWonderSourceEntityBBoxMinZ = nil
		wonder.SuperBigMapWonderSourceEntityBBoxMaxZ = nil
		wonder.SuperBigMapWonderSourceEntityBBoxSizeZ = nil
		wonder.SuperBigMapWonderExpectedX = nil
		wonder.SuperBigMapWonderExpectedY = nil
		wonder.SuperBigMapWonderXYTransformMode = nil
		if type(wonder.SetScale) == "function" then wonder:SetScale(old_scale) end
		if had_grids and type(wonder.ApplyToGrids) == "function" then wonder:ApplyToGrids() end
	end)
	return false, tostring(result)
end

function WonderVerticalDiagnostics.FlattenDeferredWonder(
	wonder, marker, ratios, preserve_stock_invalid_z)
	local get_enclosed = Global("GetEnclosedShape")
	local shrink = Global("ShrinkShape")
	local get_outline = Global("GetEntityOutlineShape")
	local for_each_hex = Global("HexShapeForEach")
	local flatten = Global("FlattenTerrainInShape")
	local unbuildable = Global("buildUnbuildableZ")()
	local map = wonder:GetMap()
	local shape = get_enclosed(wonder:GetEntity())
	if #shape == 0 then shape = shrink(get_outline(wonder:GetEntity()), 2) end
	if type(ratios) == "table" then
		shape = ScaleHexShapeForExpansion(shape, ratios.scale_x, ratios.scale_y)
	end
	local clearance_mode = type(ratios) == "table"
		and "scaled_vanilla_flatten_shape" or "native_vanilla_flatten_shape"
	local observed_buildable_z
	for_each_hex(shape, wonder, function(q, r)
		local z = map.buildable:GetZ(q, r)
		if z ~= unbuildable then observed_buildable_z = z return true end
	end)
	local source_buildable_z = tonumber(marker and marker.SuperBigMapNativeWonderFlattenZ)
	local z_mul = type(ratios) == "table"
		and (tonumber(map.SuperBigMapZScaleMul) or tonumber(ratios.x_mul)) or 1
	local z_div = type(ratios) == "table"
		and (tonumber(map.SuperBigMapZScaleDiv) or tonumber(ratios.x_div)) or 1
	local z_add = type(ratios) == "table" and (tonumber(map.SuperBigMapZScaleAdd) or 0) or 0
	local buildable_z
	local buildable_source
	if type(ratios) ~= "table" and type(observed_buildable_z) == "number" then
		buildable_z = observed_buildable_z
		buildable_source = "observed_native_buildable"
	elseif type(source_buildable_z) == "number" and type(z_mul) == "number"
		and type(z_div) == "number" and z_div > 0 then
		buildable_z = math.floor(source_buildable_z * z_mul / z_div + z_add + 0.5)
		buildable_source = type(ratios) == "table"
			and "transformed_vanilla_source_buildable" or "native_vanilla_source_buildable"
	end
	-- The consolidated revalidation inside StretchSourceToFull can complete its engine-side work
	-- before the non-current underground map's Lua BuildableGrid exposes the new right/bottom area.
	-- A deferred wonder must still be seated on the already-stretched terrain. The captured source
	-- height above is authoritative; the center terrain fallback is retained only for old/hot-loaded
	-- marker state that predates that capture.
	if type(buildable_z) ~= "number" then
		local terrain_api = Global("terrain")
		if type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function" then
			local ok_height, terrain_height = pcall(terrain_api.GetHeight, map, wonder:GetPos())
			if ok_height and type(terrain_height) == "number" then
				buildable_z = terrain_height
				buildable_source = "stretched_terrain_center_fallback"
			end
		end
	end
	if buildable_z then
		flatten(shape, wonder, map.buildable.z_grid, map.object_hex_grid,
			Global("g_NCF_FlatInner"), Global("g_NCF_FlatOuter"), -1, buildable_z)
		-- SpawnMarkerBuilding deliberately copied the vanilla marker's InvalidZ. Vanilla resolves it
		-- immediately against this floor because the generated underground is already current; SBM's
		-- destination is still off-screen here. Resolve it explicitly now so the later map activation
		-- cannot snap the wonder onto pre-flatten relief before the lifecycle reseat runs.
		if preserve_stock_invalid_z ~= true then
			local position = type(wonder.GetPos) == "function" and wonder:GetPos() or nil
			local position_x, position_y = PointXY(position)
			local point_fn = Global("point")
			if type(position_x) ~= "number" or type(position_y) ~= "number"
				or type(point_fn) ~= "function" or type(wonder.SetPos) ~= "function" then
				return false, "cannot resolve the stretched wonder's explicit floor position"
			end
			wonder:SetPos(point_fn(position_x, position_y, buildable_z))
		end
		ArtefactClearObstructions(wonder, map.obj_prefab_marker, nil, shape)
		return true, {
			shape_hexes = #shape,
			buildable_z = buildable_z,
			buildable_source = buildable_source,
			clearance_mode = clearance_mode,
			preserved_stock_invalid_z = preserve_stock_invalid_z == true,
			source_buildable_z = source_buildable_z,
			observed_buildable_z = observed_buildable_z,
			z_mul = z_mul,
			z_div = z_div,
			z_add = z_add,
			source_flatten_q = marker and marker.SuperBigMapNativeWonderFlattenQ,
			source_flatten_r = marker and marker.SuperBigMapNativeWonderFlattenR,
			source_flatten_index = marker and marker.SuperBigMapNativeWonderFlattenIndex,
			source_flatten_shape_hexes = marker
				and marker.SuperBigMapNativeWonderFlattenShapeHexes,
		}
	end
	return false, "no terrain height is available for the expanded wonder footprint"
end

-- Deferred wonder GameInit/lifecycle work can run after materialization and reapply the map's
-- 4/3 transform to the already-stretched object. Its rare anomaly then correctly spawns at the
-- wonder's now double-scaled, unbuildable coordinate. The underground is still off-screen at this
-- point, so the current-map ReseatAll transaction below cannot run yet. Restore only the object's
-- recorded final XYZ (and its vanilla grids) immediately before SpawnsAnomalyOnCityInit executes;
-- the already-verified terrain footprint remains unchanged.
function WonderVerticalDiagnostics.RestoreExpectedPositionsBeforeAnomalySpawn(map, reason)
	if type(map) ~= "table" or type(map.mapdata) ~= "table"
		or map.mapdata.Environment ~= "Underground" then
		return false, { error = "target is not an underground map" }
	end
	local ratios, ratio_error = DeferredWonderScaleRatios(map)
	local point_fn = Global("point")
	if type(ratios) ~= "table" or type(point_fn) ~= "function"
		or type(map.SuspendPassEdits) ~= "function"
		or type(map.ResumePassEdits) ~= "function" then
		return false, { error = tostring(ratio_error or "wonder reseat APIs unavailable") }
	end
	local candidates, details = {}, {}
	for _, wonder in ipairs(ArtefactMapGet(map, "UndergroundWonder")) do
		local target_z = tonumber(wonder.SuperBigMapWonderFlattenZ)
		if type(target_z) == "number" then
			local target_x, target_y = WonderVerticalDiagnostics.ExactStretchedWonderXY(
				wonder, map, ratios)
			target_x = target_x or tonumber(wonder.SuperBigMapWonderExpectedX)
			target_y = target_y or tonumber(wonder.SuperBigMapWonderExpectedY)
			local pos = type(wonder.GetPos) == "function" and wonder:GetPos() or nil
			local before_x, before_y = PointXY(pos)
			local before_z = WonderVerticalDiagnostics.SafePointZ(pos)
			if type(target_x) ~= "number" or type(target_y) ~= "number"
				or type(before_x) ~= "number" or type(before_y) ~= "number"
				or type(wonder.SetPos) ~= "function" then
				return false, { error = "buried wonder expected/live position unavailable for "
					.. tostring(wonder.class) }
			end
			local wrong = before_x ~= target_x or before_y ~= target_y or before_z ~= target_z
			candidates[#candidates + 1] = {
				wonder = wonder, target_x = target_x, target_y = target_y, target_z = target_z,
				before_x = before_x, before_y = before_y, before_z = before_z, wrong = wrong,
			}
		end
	end
	local stats = {
		reason = tostring(reason or "before rare-anomaly spawn"),
		checked = #candidates, corrected = 0, grid_migrations = 0,
	}
	if #candidates == 0 then
		stats.error = "no stretched underground wonders"
		return false, stats
	end

	local correction_reason = "SuperBigMap_PreWonderAnomalyReseat"
	local suspended = false
	local ok, correction_error = pcall(function()
		map:SuspendPassEdits(correction_reason)
		suspended = true
		for _, candidate in ipairs(candidates) do
			local wonder = candidate.wonder
			if candidate.wrong then
				local had_grids = wonder.grids_applied == true
				if had_grids then
					if type(wonder.RemoveFromGrids) ~= "function"
						or type(wonder.ApplyToGrids) ~= "function" then
						error("wonder grid migration unavailable for " .. tostring(wonder.class))
					end
					wonder:RemoveFromGrids()
				end
				wonder:SetPos(point_fn(
					candidate.target_x, candidate.target_y, candidate.target_z))
				if had_grids then
					wonder:ApplyToGrids()
					stats.grid_migrations = stats.grid_migrations + 1
				end
				stats.corrected = stats.corrected + 1
			end
		end
	end)
	local resume_ok, resume_error = true, nil
	if suspended then
		resume_ok, resume_error = pcall(
			map.ResumePassEdits, map, correction_reason, ok ~= true)
	end
	if not ok or not resume_ok then
		stats.error = not ok and tostring(correction_error)
			or ("ResumePassEdits failed: " .. tostring(resume_error))
		LoadingStep("underground pre-anomaly wonder reseat", stats, map)
		return false, stats
	end

	local failures = 0
	for _, candidate in ipairs(candidates) do
		local wonder = candidate.wonder
		local pos = type(wonder.GetPos) == "function" and wonder:GetPos() or nil
		local after_x, after_y = PointXY(pos)
		local after_z = WonderVerticalDiagnostics.SafePointZ(pos)
		local valid = after_x == candidate.target_x and after_y == candidate.target_y
			and after_z == candidate.target_z
		if not valid then failures = failures + 1 end
		wonder.SuperBigMapWonderPreAnomalyReseatDone = valid and true or nil
		details[#details + 1] = tostring(wonder.class)
			.. "@" .. tostring(candidate.before_x) .. "," .. tostring(candidate.before_y)
			.. "," .. tostring(candidate.before_z)
			.. "->" .. tostring(after_x) .. "," .. tostring(after_y) .. "," .. tostring(after_z)
			.. ":target=" .. tostring(candidate.target_x) .. ","
			.. tostring(candidate.target_y) .. "," .. tostring(candidate.target_z)
			.. ":valid=" .. tostring(valid)
	end
	stats.failures = failures
	stats.details = table.concat(details, ";")
	LoadingStep("underground pre-anomaly wonder reseat", stats, map)
	return failures == 0, stats
end

-- Vanilla leaves a newly spawned buried wonder at InvalidZ and flattens its terrain immediately.
-- That is safe while vanilla generates the current underground map: the object resolves against
-- the freshly flattened floor. SBM materializes the wonders while the underground is off-screen.
-- EngineSetCurrentMapSlot can then discard that off-screen flatten before resolving InvalidZ,
-- raising a wonder onto restored relief and allowing the relief to intersect its entity. Reapply
-- only the stored vanilla-derived footprint once the map is current, and make floor Z explicit.
function WonderVerticalDiagnostics.ReseatAll(map, reason)
	if type(map) ~= "table" or type(map.mapdata) ~= "table"
		or map.mapdata.Environment ~= "Underground"
		or map.SuperBigMapUndergroundStretchDone ~= true then
		return true, { skipped = true, reason = "not a completed expanded underground" }
	end
	if Global("CurrentMap") ~= map then
		return false, "expanded underground wonder reseat requires the current map"
	end
	local ratios, ratio_error = DeferredWonderScaleRatios(map)
	if type(ratios) ~= "table" then return false, tostring(ratio_error) end
	local get_enclosed = Global("GetEnclosedShape")
	local get_outline = Global("GetEntityOutlineShape")
	local shrink = Global("ShrinkShape")
	local flatten = Global("FlattenTerrainInShape")
	local point_fn = Global("point")
	if type(get_enclosed) ~= "function" or type(get_outline) ~= "function"
		or type(shrink) ~= "function" or type(flatten) ~= "function"
		or type(point_fn) ~= "function" or type(map.SuspendPassEdits) ~= "function"
		or type(map.ResumePassEdits) ~= "function" or type(map.buildable) ~= "table"
		or not map.buildable.z_grid or not map.object_hex_grid then
		return false, "current-map wonder reseat helpers are unavailable"
	end

	local candidates = {}
	for _, wonder in ipairs(ArtefactMapGet(map, "UndergroundWonder")) do
		local target_z = tonumber(wonder.SuperBigMapWonderFlattenZ)
		if type(target_z) == "number" then
			-- Recompute from the persisted vanilla source anchor instead of trusting an older
			-- expected value: builds through v666 stored the nearest-hex coordinate here. This makes
			-- the correction migrate existing expanded saves as well as newly generated maps.
			local target_x, target_y = WonderVerticalDiagnostics.ExactStretchedWonderXY(
				wonder, map, ratios)
			target_x = target_x or tonumber(wonder.SuperBigMapWonderExpectedX)
			target_y = target_y or tonumber(wonder.SuperBigMapWonderExpectedY)
			if type(target_x) ~= "number" or type(target_y) ~= "number" then
				return false, "expanded wonder exact XY anchor unavailable for "
					.. tostring(wonder.class)
			end
			wonder.SuperBigMapWonderExpectedX = target_x
			wonder.SuperBigMapWonderExpectedY = target_y
			wonder.SuperBigMapWonderXYTransformMode = "exact_world_affine"
			local entity = type(wonder.GetEntity) == "function" and wonder:GetEntity() or nil
			local shape = type(entity) == "string" and get_enclosed(entity) or nil
			if type(shape) == "table" and #shape == 0 then
				shape = shrink(get_outline(entity), 2)
			end
			if type(shape) ~= "table" or #shape == 0 then
				return false, "expanded flatten shape unavailable for "
					.. tostring(wonder.class or entity)
			end
			shape = ScaleHexShapeForExpansion(shape, ratios.scale_x, ratios.scale_y)
			candidates[#candidates + 1] = {
				wonder = wonder,
				shape = shape,
				target_x = target_x,
				target_y = target_y,
				target_z = target_z,
			}
		end
	end
	if #candidates == 0 then
		return true, { skipped = true, reason = "no stretched underground wonders" }
	end

	local correction_reason = "SuperBigMap_CurrentUndergroundWonderReseat"
	local geometry_diagnostics_enabled = WonderGeometryDiagnosticsEnabled()
	local flat_inner, flat_outer = Global("g_NCF_FlatInner"), Global("g_NCF_FlatOuter")
	local suspended = false
	local corrected_terrain, corrected_xy, corrected_z = 0, 0, 0
	local ok, err = pcall(function()
		local position_correction_needed = false
		for _, candidate in ipairs(candidates) do
			local wonder = candidate.wonder
			local target_x = candidate.target_x
			local target_y = candidate.target_y
			local target_z = candidate.target_z
			local pos = type(wonder.GetPos) == "function" and wonder:GetPos() or nil
			local x, y = PointXY(pos)
			if type(x) ~= "number" or type(y) ~= "number"
				or type(wonder.SetPos) ~= "function" then
				error("wonder position is unavailable for " .. tostring(wonder.class))
			end
			candidate.xy_wrong = x ~= target_x or y ~= target_y
			candidate.z_wrong = WonderVerticalDiagnostics.SafePointZ(pos) ~= target_z
			if candidate.xy_wrong or candidate.z_wrong then
				position_correction_needed = true
			end
		end
		if position_correction_needed then
			map:SuspendPassEdits(correction_reason)
			suspended = true
			for _, candidate in ipairs(candidates) do
				local wonder = candidate.wonder
				local target_x = candidate.target_x
				local target_y = candidate.target_y
				local target_z = candidate.target_z
				local xy_wrong = candidate.xy_wrong
				local z_wrong = candidate.z_wrong
				if xy_wrong or z_wrong then
					local had_grids = wonder.grids_applied == true
					if had_grids then
						if type(wonder.RemoveFromGrids) ~= "function"
							or type(wonder.ApplyToGrids) ~= "function" then
							error("wonder grid migration helpers are unavailable for "
								.. tostring(wonder.class))
						end
						wonder:RemoveFromGrids()
					end
					wonder:SetPos(point_fn(target_x, target_y, target_z))
					if had_grids then wonder:ApplyToGrids() end
					if xy_wrong then corrected_xy = corrected_xy + 1 end
				end
				if z_wrong then corrected_z = corrected_z + 1 end
			end
		end
		for _, candidate in ipairs(candidates) do
			local wonder = candidate.wonder
			local target_z = candidate.target_z
			local current = WonderVerticalDiagnostics.ShapeTerrainTargetStats(
				map, candidate.shape, wonder, target_z)
			candidate.terrain_precheck = current
			if current.complete ~= true then
				if not suspended then
					map:SuspendPassEdits(correction_reason)
					suspended = true
				end
				flatten(candidate.shape, wonder, map.buildable.z_grid, map.object_hex_grid,
					flat_inner, flat_outer, -1, target_z)
				corrected_terrain = corrected_terrain + 1
			end
		end
	end)
	local resume_ok, resume_err = true, nil
	if suspended then
		resume_ok, resume_err = pcall(map.ResumePassEdits, map, correction_reason)
	end
	if not ok or not resume_ok then
		local failure = not ok and tostring(err)
			or ("ResumePassEdits failed: " .. tostring(resume_err))
		map.SuperBigMapWonderLifecycleReseatFailed = failure
		LoadingStep("underground buried wonder lifecycle reseat", {
			reason = tostring(reason),
			wonders = #candidates,
			corrected_terrain = corrected_terrain,
			corrected_xy = corrected_xy,
			corrected_z = corrected_z,
			error = failure,
		}, map)
		return false, failure
	end

	local verified = 0
	for _, candidate in ipairs(candidates) do
		local wonder = candidate.wonder
		local after
		if geometry_diagnostics_enabled then
			after = WonderVerticalDiagnostics.ShapeVerticalStats(
				map, candidate.shape, wonder, candidate.target_z)
		elseif corrected_terrain > 0 then
			-- Any flatten can touch feathered outer cells; after a repair, revalidate every wonder
			-- rather than assuming non-overlap. The no-repair path reuses the authoritative scan.
			after = WonderVerticalDiagnostics.ShapeTerrainTargetStats(
				map, candidate.shape, wonder, candidate.target_z)
		else
			after = candidate.terrain_precheck
		end
		local pos = type(wonder.GetPos) == "function" and wonder:GetPos() or nil
		local object_x, object_y = PointXY(pos)
		local object_z = WonderVerticalDiagnostics.SafePointZ(pos)
		local terrain_ok = after.samples > 0 and after.terrain_at_target == after.samples
			and (after.complete == nil or after.complete == true)
		local xy_ok = object_x == candidate.target_x and object_y == candidate.target_y
		local object_ok = object_z == candidate.target_z
		LoadingStep("underground buried wonder lifecycle reseat instance", {
			reason = tostring(reason),
			class = tostring(wonder.class),
			target_x = candidate.target_x,
			target_y = candidate.target_y,
			target_z = candidate.target_z,
			object_x = object_x,
			object_y = object_y,
			object_z = object_z,
			footprint_samples = after.samples,
			terrain_at_target = after.terrain_at_target,
			terrain_above_target = after.terrain_above_target,
			terrain_below_target = after.terrain_below_target,
			terrain_min_z = after.terrain_min_z,
			terrain_max_z = after.terrain_max_z,
			terrain_error = after.error,
			terrain_ok = terrain_ok,
			xy_ok = xy_ok,
			object_ok = object_ok,
		}, map)
		if not terrain_ok or not xy_ok or not object_ok then
			local failure = "post-switch wonder terrain validation failed for "
				.. tostring(wonder.class) .. ": object_xy=" .. tostring(object_x)
				.. "," .. tostring(object_y) .. " target_xy="
				.. tostring(candidate.target_x) .. "," .. tostring(candidate.target_y)
				.. " object_z=" .. tostring(object_z)
				.. " target_z=" .. tostring(candidate.target_z)
				.. " terrain=" .. tostring(after.terrain_at_target)
				.. "/" .. tostring(after.samples)
			map.SuperBigMapWonderLifecycleReseatFailed = failure
			return false, failure
		end
		verified = verified + 1
	end
	map.SuperBigMapWonderLifecycleReseatFailed = nil
	map.SuperBigMapWonderLifecycleReseatDone = true
	LoadingStep("underground buried wonder lifecycle reseat", {
		reason = tostring(reason),
		wonders = #candidates,
		corrected_terrain = corrected_terrain,
		corrected_xy = corrected_xy,
		corrected_z = corrected_z,
		verified = verified,
	}, map)
	return true, {
		wonders = #candidates,
		corrected_terrain = corrected_terrain,
		corrected_xy = corrected_xy,
		corrected_z = corrected_z,
		verified = verified,
	}
end

-- Deferred wonder materialization can schedule a second all-mip request well after ResourceManager
-- reports idle. The resulting reAssetLODStreamer assert has now been observed on both members of
-- the vanilla cave/pit texture family (3547000/3547001) and on the Ancient Artifact family. Resolve
-- every member of the family used by the planned wonder classes, in a stable serial order, before
-- creating any wonder; retain those refs for the lifetime of the installed behavior. The shipped
-- Fallbacks/Textures packs contain exactly 3547000..1 and 1304000..2 for these two families.
-- This changes no material, visual, or LOD target; it only makes the first all-mip transition have
-- a single owner.
local CAVE_BURIED_WONDER_TEXTURES = {
	"Textures/3547000.dds",
	"Textures/3547001.dds",
}
local ANCIENT_ARTIFACT_TEXTURES = {
	"Textures/1304000.dds",
	"Textures/1304001.dds",
	"Textures/1304002.dds",
}
local BURIED_WONDER_TEXTURES_BY_CLASS = {
	AncientArtifact = ANCIENT_ARTIFACT_TEXTURES,
	BottomlessPit = CAVE_BURIED_WONDER_TEXTURES,
	CaveOfWonders = CAVE_BURIED_WONDER_TEXTURES,
	JumboCave = CAVE_BURIED_WONDER_TEXTURES,
}

local function BuriedWonderTexturesForPlan(planned)
	local classes, textures, seen = {}, {}, {}
	for _, marker in ipairs(planned or {}) do
		local class_name = marker and marker.SuperBigMapDeferredWonderClass
		if type(class_name) == "string" and class_name ~= "" then
			classes[#classes + 1] = class_name
			for _, texture_path in ipairs(BURIED_WONDER_TEXTURES_BY_CLASS[class_name] or {}) do
				if not seen[texture_path] then
					seen[texture_path] = true
					textures[#textures + 1] = texture_path
				end
			end
		end
	end
	table.sort(textures)
	return classes, textures
end

local function ResourceRequestsRunning(resource_manager)
	if type(resource_manager) ~= "table"
		or type(resource_manager.HasRunningRequests) ~= "function" then
		return nil
	end
	local running = SafeCall(resource_manager.HasRunningRequests)
	return running == true
end

local function WaitForUndergroundResourceRequests(map, reason, timeout)
	local wait_requests = Global("WaitResourceManagerRequests")
	local resource_manager = Global("ResourceManager")
	if type(wait_requests) ~= "function" then
		return false, "WaitResourceManagerRequests unavailable"
	end
	local running_before = ResourceRequestsRunning(resource_manager)
	local ok, elapsed = pcall(wait_requests, timeout or 15000, 3)
	local running_after = ResourceRequestsRunning(resource_manager)
	LoadingStep("underground renderer resources settled", {
		reason = tostring(reason or "unspecified"),
		wait_ok = tostring(ok),
		wait_ms = tostring(elapsed),
		running_before = tostring(running_before),
		running_after = tostring(running_after),
	}, map)
	if not ok then return false, tostring(elapsed) end
	if running_after == true then
		return false, "resource requests remained active after " .. tostring(elapsed) .. "ms"
	end
	return true, elapsed
end

local function SettleUndergroundSceneResources(map, reason)
	local settled, result = WaitForUndergroundResourceRequests(map, reason, 15000)
	if settled then return true, result end
	-- A large texture can still be completing disk IO at the first timeout. Keep the existing
	-- loading screen in front for one bounded retry instead of exposing a half-streamed scene.
	local retry_settled, retry_result = WaitForUndergroundResourceRequests(
		map, tostring(reason or "underground scene") .. " retry", 15000)
	return retry_settled, retry_settled and retry_result
		or (tostring(result) .. "; retry: " .. tostring(retry_result))
end

local function ReleaseSharedBuriedWonderTexturePins()
	for i = #underground_shared_wonder_texture_pins, 1, -1 do
		local resource = underground_shared_wonder_texture_pins[i]
		underground_shared_wonder_texture_pins[i] = nil
		if resource and type(resource.ReleaseRef) == "function" then
			SafeCall(resource.ReleaseRef, resource)
		end
	end
	local State = SuperBigMap.State or {}
	State.underground_shared_wonder_texture_ready = nil
	State.underground_buried_wonder_textures_ready = nil
	State.underground_buried_wonder_texture_signature = nil
end

local function PrewarmSharedBuriedWonderTexture(map, planned)
	local classes, textures = BuriedWonderTexturesForPlan(planned)
	if #classes == 0 then return true, { required = false } end
	if #textures == 0 then
		return false, "no texture family is registered for " .. table.concat(classes, ",")
	end
	local texture_signature = table.concat(textures, ",")

	local State = SuperBigMap.State or {}
	if State.underground_buried_wonder_textures_ready == true
		and State.underground_buried_wonder_texture_signature == texture_signature
		and #underground_shared_wonder_texture_pins >= #textures then
		LoadingStep("underground buried-wonder textures ready", {
			textures = texture_signature,
			classes = table.concat(classes, ","),
			cached = true,
			pins = #underground_shared_wonder_texture_pins,
		}, map)
		return true, { required = true, cached = true }
	end

	local resource_manager = Global("ResourceManager")
	local async_get = Global("AsyncGetResource")
	if type(resource_manager) ~= "table"
		or type(resource_manager.GetResourceID) ~= "function"
		or type(async_get) ~= "function" then
		return false, "texture resource API unavailable"
	end

	-- Discard refs retained by an older one-texture implementation before rebuilding the complete
	-- set. They are extra ownership refs only; releasing them does not unload a live scene object.
	ReleaseSharedBuriedWonderTexturePins()
	local requested = {}
	for _, texture_path in ipairs(textures) do
		local ok_id, resource_id = pcall(resource_manager.GetResourceID, texture_path)
		if not ok_id or resource_id == nil then
			ReleaseSharedBuriedWonderTexturePins()
			return false, "wonder texture id unavailable for " .. tostring(texture_path)
		end
		local ok_load, resource = pcall(async_get, resource_id)
		if not ok_load or not resource then
			ReleaseSharedBuriedWonderTexturePins()
			return false, "wonder texture load failed for " .. tostring(texture_path)
		end
		local has_object = type(resource.HasObject) ~= "function"
			or SafeCall(resource.HasObject, resource) == true
		if not has_object then
			if type(resource.ReleaseRef) == "function" then SafeCall(resource.ReleaseRef, resource) end
			ReleaseSharedBuriedWonderTexturePins()
			return false, "wonder texture resource has no object: " .. tostring(texture_path)
		end
		underground_shared_wonder_texture_pins[#underground_shared_wonder_texture_pins + 1] = resource
		requested[#requested + 1] = { path = texture_path, resource = resource }
	end
	-- Queue the complete deterministic texture set first, then wait once for the same global
	-- ResourceManager idle boundary. Waiting after every individual request paid the engine's
	-- minimum settle window five times even when no request remained active. Every resource is still
	-- pinned before construction, and no wonder is created until the single batch boundary succeeds.
	local settled, settle_result = WaitForUndergroundResourceRequests(
		map, "buried-wonder texture prewarm batch", 15000)
	if not settled then
		ReleaseSharedBuriedWonderTexturePins()
		return false, "wonder texture batch did not settle: " .. tostring(settle_result)
	end
	local total_wait = tonumber(settle_result) or 0
	for _, entry in ipairs(requested) do
		local resource = entry.resource
		local has_object = type(resource.HasObject) ~= "function"
			or SafeCall(resource.HasObject, resource) == true
		if not has_object then
			ReleaseSharedBuriedWonderTexturePins()
			return false, "wonder texture resource has no object after settle: "
				.. tostring(entry.path)
		end
		LoadingStep("underground buried-wonder texture ready", {
			texture = entry.path,
			classes = table.concat(classes, ","),
			cached = false,
			pins = #underground_shared_wonder_texture_pins,
			batch_wait_ms = tostring(total_wait),
		}, map)
	end
	State.underground_shared_wonder_texture_ready = true
	State.underground_buried_wonder_textures_ready = true
	State.underground_buried_wonder_texture_signature = texture_signature
	LoadingStep("underground buried-wonder textures ready", {
		textures = texture_signature,
		classes = table.concat(classes, ","),
		cached = false,
		pins = #underground_shared_wonder_texture_pins,
		wait_ms = tostring(total_wait),
	}, map)
	return true, { required = true, cached = false, wait_ms = total_wait }
end

function WonderVerticalDiagnostics.MaterializeDeferredUndergroundWondersOnSource(map)
	local markers = ArtefactMapGet(map, "BuriedWonderMarker")
	local staged_records = map.SuperBigMapDeferredUndergroundWonderRecords
	if type(staged_records) == "table" and #staged_records > 0 then
		if #markers > 0 then
			return false, "staged deferred wonder records coexist with live markers"
		end
		markers = {}
		for _, record in ipairs(staged_records) do
			local marker, recreate_error = SuperBigMap.RecreateDeferredWonderMarker(map, record)
			if not marker then
				return false, "deferred wonder marker recreation failed: "
					.. tostring(recreate_error)
			end
			markers[#markers + 1] = marker
		end
		map.SuperBigMapDeferredUndergroundWonderRecords = nil
		LoadingStep("deferred underground wonder markers recreated for first access", {
			recreated = #markers,
		}, map)
	end
	local planned = {}
	for _, marker in ipairs(markers) do
		if type(marker.SuperBigMapDeferredWonderClass) == "string"
			and marker.SuperBigMapDeferredWonderClass ~= "" then
			planned[#planned + 1] = marker
		end
	end
	if map.SuperBigMapDeferredUndergroundWondersPending ~= true and #planned == 0 then
		return true, 0
	end
	if #planned == 0 then
		return false, "deferred wonder plan is pending but no assigned BuriedWonderMarker survives"
	end
	local required = {
		Global("PlaceBuildingIn"), Global("GetEnclosedShape"), Global("ShrinkShape"),
		Global("GetEntityOutlineShape"), Global("HexShapeForEach"),
		Global("FlattenTerrainInShape"), Global("buildUnbuildableZ"),
	}
	for _, fn in ipairs(required) do
		if type(fn) ~= "function" then return false, "source wonder helper is unavailable" end
	end
	local texture_ready, texture_error = PrewarmSharedBuriedWonderTexture(map, planned)
	if texture_ready ~= true then
		return false, "buried wonder shared texture prewarm failed: " .. tostring(texture_error)
	end
	local materialized = {}
	map:SuspendPassEdits("SuperBigMap_SourceUndergroundWonders")
	local ok, err = pcall(function()
		for _, marker in ipairs(planned) do
			local wonder_class = marker.SuperBigMapDeferredWonderClass
			local wonder = ArtefactSpawnMarkerBuilding(marker, wonder_class, map)
			local flatten_ok, flatten_stats
			if marker.SuperBigMapNativeWonderClearanceDone == true then
				flatten_ok, flatten_stats = true, {
					buildable_z = tonumber(marker.SuperBigMapNativeWonderFlattenZ),
					buildable_source = "native_bootstrap_clearance_floor",
					clearance_mode = "native_bootstrap_clearance_no_replay",
					source_buildable_z = tonumber(marker.SuperBigMapNativeWonderFlattenZ),
				}
				local point_fn = Global("point")
				local pos = type(wonder.GetPos) == "function" and wonder:GetPos() or nil
				local x, y = PointXY(pos)
				if type(flatten_stats.buildable_z) ~= "number" or type(point_fn) ~= "function"
					or type(x) ~= "number" or type(y) ~= "number"
					or type(wonder.SetPos) ~= "function" then
					flatten_ok, flatten_stats = false,
						"native bootstrap wonder floor is unavailable"
				else
					wonder:SetPos(point_fn(x, y, flatten_stats.buildable_z))
				end
			else
				-- Legacy deferred saves predate native-bootstrap clearance and still need the one source
				-- transaction when first accessed. Fresh games never enter this compatibility branch.
				flatten_ok, flatten_stats =
					WonderVerticalDiagnostics.FlattenDeferredWonder(wonder, marker, nil)
			end
			if flatten_ok ~= true then
				error("failed to prepare native terrain for " .. tostring(wonder_class)
					.. ": " .. tostring(flatten_stats))
			end
			local source_grids_applied = wonder.grids_applied == true
			if source_grids_applied then
				if type(wonder.RemoveFromGrids) ~= "function" then
					error("RemoveFromGrids unavailable for native " .. tostring(wonder_class))
				end
				wonder:RemoveFromGrids()
				if wonder.grids_applied == true then
					error("native wonder footprint remained registered")
				end
			end
			wonder.SuperBigMapWonderSourceFlattenZ = flatten_stats and flatten_stats.buildable_z
			materialized[#materialized + 1] = {
				marker = marker,
				wonder = wonder,
				class = wonder_class,
				source_grids_applied = source_grids_applied,
				source_flatten_z = flatten_stats and flatten_stats.buildable_z,
			}
			LoadingStep("underground buried wonder cleared on native source", {
				class = wonder_class,
				flatten_shape_hexes = flatten_stats and flatten_stats.shape_hexes,
				flatten_z = flatten_stats and flatten_stats.buildable_z,
				flatten_source = flatten_stats and flatten_stats.buildable_source,
				clearance_mode = flatten_stats and flatten_stats.clearance_mode,
				grids_detached = source_grids_applied,
			}, map)
		end
	end)
	local resume_ok, resume_err = pcall(map.ResumePassEdits, map,
		"SuperBigMap_SourceUndergroundWonders")
	if not ok then return false, tostring(err) end
	if not resume_ok then return false, "ResumePassEdits failed: " .. tostring(resume_err) end
	map.SuperBigMapSourceMaterializedDeferredWonders = materialized
	map.SuperBigMapDeferredUndergroundWondersSourceCleared = true
	LoadingStep("underground buried wonders cleared on native source", {
		materialized = #materialized,
	}, map)
	return #materialized == #planned, #materialized
end

local function MaterializeDeferredUndergroundWonders(map)
	local materialized = map.SuperBigMapSourceMaterializedDeferredWonders
	if type(materialized) ~= "table" then
		return false, "native-domain deferred wonder materialization record is unavailable"
	end
	if #materialized == 0 then return true, 0 end
	if type(Global("DoneObject")) ~= "function" then
		return false, "DoneObject unavailable for deferred wonder markers"
	end
	local ratios, ratio_error = DeferredWonderScaleRatios(map)
	if not ratios then return false, ratio_error end
	local z_mul = tonumber(map.SuperBigMapZScaleMul) or ratios.x_mul
	local z_div = tonumber(map.SuperBigMapZScaleDiv) or ratios.x_div
	if not z_mul or not z_div or z_div <= 0
		or z_mul * ratios.x_div ~= z_div * ratios.x_mul then
		return false, "underground wonder X/Y/Z stretch ratios are not uniform"
	end
	local spawned, stretched, bottomless_pits, bottomless_pits_stretched = 0, 0, 0, 0
	local expanded_shape_hexes = 0
	local vertical_audits = {}
	map:SuspendPassEdits("SuperBigMap_DeferredUndergroundWonders")
	local ok, err = pcall(function()
		for _, record in ipairs(materialized) do
			local marker, wonder = record.marker, record.wonder
			local wonder_class = record.class
			if not marker or not wonder then error("native wonder record lost its live objects") end
			ArtefactApplyMarkerProperties(wonder, marker)
			local stretch_ok, stretch_stats = ApplyDeferredWonderStretch(
				wonder, marker, map, ratios)
			if stretch_ok ~= true then
				error("failed to stretch " .. tostring(wonder_class) .. ": "
					.. tostring(stretch_stats))
			end
			WonderVerticalDiagnostics.Log(wonder, marker, map, ratios, nil,
				"after_scale_before_native_floor_seat")
			local flatten_ok, flatten_stats =
				WonderVerticalDiagnostics.SeatDeferredWonderWithoutClearance(
				wonder, marker, map, record.source_flatten_z)
			if flatten_ok ~= true then
				error("failed to seat stretched " .. tostring(wonder_class)
					.. ": " .. tostring(flatten_stats))
			end
			if record.source_grids_applied == true then
				if type(wonder.ApplyToGrids) ~= "function" then
					error("ApplyToGrids unavailable for stretched " .. tostring(wonder_class))
				end
				wonder:ApplyToGrids()
				if wonder.grids_applied ~= true then
					error("stretched wonder footprint was not registered")
				end
			end
			wonder.SuperBigMapWonderFlattenZ = flatten_stats.buildable_z
			WonderVerticalDiagnostics.Log(wonder, marker, map, ratios, flatten_stats,
				"after_native_clearance_floor_seat")
			vertical_audits[#vertical_audits + 1] = wonder
			Global("DoneObject")(marker)
			spawned = spawned + 1
			stretched = stretched + 1
			expanded_shape_hexes = expanded_shape_hexes
				+ (stretch_stats and stretch_stats.shape_hexes or 0)
			if wonder_class == "BottomlessPit" then
				bottomless_pits = bottomless_pits + 1
				bottomless_pits_stretched = bottomless_pits_stretched + 1
			end
			LoadingStep("underground buried wonder stretched", {
				class = wonder_class,
				source_x = stretch_stats and stretch_stats.source_x,
				source_y = stretch_stats and stretch_stats.source_y,
				final_x = stretch_stats and stretch_stats.final_x,
				final_y = stretch_stats and stretch_stats.final_y,
				expanded_shape_hexes = stretch_stats and stretch_stats.shape_hexes,
				expanded_scale = stretch_stats and stretch_stats.expected_scale,
				flatten_z = flatten_stats and flatten_stats.buildable_z,
				flatten_source = flatten_stats and flatten_stats.buildable_source,
				clearance_mode = flatten_stats and flatten_stats.clearance_mode,
				source_flatten_z = flatten_stats and flatten_stats.source_buildable_z,
			}, map)
		end
	end)
	local resume_ok, resume_err = pcall(map.ResumePassEdits, map,
		"SuperBigMap_DeferredUndergroundWonders")
	if not ok then return false, tostring(err) end
	if not resume_ok then return false, "ResumePassEdits failed: " .. tostring(resume_err) end
	for _, wonder in ipairs(vertical_audits) do
		WonderVerticalDiagnostics.Log(wonder, nil, map, ratios, nil, "after_wonder_resume")
	end
	WonderVerticalDiagnostics.LogCoverage(map, "after_wonder_resume")
	map.SuperBigMapSourceMaterializedDeferredWonders = nil
	map.SuperBigMapDeferredUndergroundWondersPending = false
	map.SuperBigMapDeferredUndergroundWondersDone = true
	map.SuperBigMapDeferredUndergroundWondersSpawned = spawned
	map.SuperBigMapDeferredUndergroundWondersStretched = stretched
	map.SuperBigMapDeferredBottomlessPitsStretched = bottomless_pits_stretched
	LoadingStep("underground buried wonders stretched", {
		spawned = spawned,
		stretched = stretched,
		bottomless_pits = bottomless_pits,
		bottomless_pits_stretched = bottomless_pits_stretched,
		expanded_shape_hexes = expanded_shape_hexes,
		scale_x = ratios.scale_x,
		scale_y = ratios.scale_y,
	}, map)
	return spawned == #materialized, spawned
end

-- Buried wonders normally exist when OnMsg.CityInitialized walks SpawnsOnCityInit and invokes
-- UndergroundWonder:Spawn. Expanded underground generation deliberately postpones construction of
-- the wonder objects until first access, so that one-shot message has already passed by the time
-- MaterializeDeferredUndergroundWonders finishes them. Activate the same vanilla Spawn method only
-- after the authoritative final grids exist; FindUnobstructedDepositPos then sees matching object,
-- passability, and buildable grids. The linked-marker scan makes this safe to retry after a hot
-- reload without ever creating a second rare anomaly for the same wonder.
function WonderVerticalDiagnostics.DeferredUndergroundWonderClasses()
	local classes, seen = {}, {}
	local const_tbl = Global("const")
	for _, class_name in ipairs(type(const_tbl) == "table"
		and type(const_tbl.BuriedWonders) == "table" and const_tbl.BuriedWonders or {}) do
		if type(class_name) == "string" and class_name ~= "" and not seen[class_name] then
			seen[class_name] = true
			classes[#classes + 1] = class_name
		end
	end
	-- The fallback is for diagnostics/hot reload only. These are the four vanilla classes and
	-- therefore do not broaden the feature to unrelated SpawnsAnomalyOnCityInit objects.
	if #classes == 0 then
		classes = { "AncientArtifact", "CaveOfWonders", "BottomlessPit", "JumboCave" }
	end
	return classes
end

function WonderVerticalDiagnostics.LiveDeferredUndergroundWonders(map)
	local wonders, seen, allowed = {}, {}, {}
	for _, class_name in ipairs(WonderVerticalDiagnostics.DeferredUndergroundWonderClasses()) do
		allowed[class_name] = true
		for _, wonder in ipairs(ArtefactMapGet(map, class_name)) do
			if wonder and not seen[wonder] then
				seen[wonder] = true
				wonders[#wonders + 1] = wonder
			end
		end
	end
	return wonders, allowed
end

function WonderVerticalDiagnostics.WonderCityLabelContains(map, wonder)
	local class_name = wonder and tostring(wonder.class or "") or ""
	local labels = map and map.City and map.City.labels
	local label = type(labels) == "table" and labels[class_name] or nil
	if type(label) ~= "table" then return false end
	for _, candidate in pairs(label) do
		if candidate == wonder then return true end
	end
	return false
end

function WonderVerticalDiagnostics.WonderGameInitPending(wonder)
	local threads = Global("GameInitThreads")
	return type(threads) == "table" and wonder ~= nil and threads[wonder] ~= nil
end

-- Vanilla constructs its buried wonders while the underground map is still loading, so
-- RunGameInitAfterLoadingMap (CommonLua/Core/map.lua) runs each wonder's GameInit -- including the
-- PlayFX("Spawn", "start") that attaches its fog emitters -- before the finished map is handed to
-- the game. Expanded generation materializes the same wonders after that boundary, so Object.new
-- queues GameInit on a game-time thread instead, and that thread cannot run while the preparation
-- transaction holds game time: the completed expanded underground then lacks attached objects the
-- vanilla twin already carries. Run the queued GameInit here, once every wonder sits at its final
-- pose on the final grids, making exactly the call the engine thread would have made later.
function WonderVerticalDiagnostics.RunDeferredUndergroundWonderGameInit(map, reason)
	local wonders = WonderVerticalDiagnostics.LiveDeferredUndergroundWonders(map)
	local stats = {
		reason = tostring(reason or "unspecified"),
		wonders = #wonders,
		ran = 0,
		already_initialized = 0,
		attaches_added = 0,
		failures = 0,
	}
	local threads = Global("GameInitThreads")
	local cancel_game_init = Global("CancelGameInit")
	local is_valid = Global("IsValid")
	if type(threads) ~= "table" or type(cancel_game_init) ~= "function"
		or type(is_valid) ~= "function" then
		stats.error = "engine GameInit queue is unavailable"
		return false, stats
	end
	local function attach_count(wonder)
		if type(wonder.GetAttaches) ~= "function" then return 0 end
		local attaches = SafeCall(wonder.GetAttaches, wonder)
		return type(attaches) == "table" and #attaches or 0
	end
	local failure_details = {}
	for _, wonder in ipairs(wonders) do
		local class_name = tostring(wonder.class or "?")
		if not SafeCall(is_valid, wonder) then
			failure_details[#failure_details + 1] = class_name .. " is not a valid object"
		elseif threads[wonder] == nil then
			-- Either GameInit already ran (hot reload, legacy save) or the class defines none.
			stats.already_initialized = stats.already_initialized + 1
		elseif type(wonder.GameInit) ~= "function" then
			failure_details[#failure_details + 1] = class_name .. " has no GameInit"
		else
			local before = attach_count(wonder)
			cancel_game_init(wonder)
			if threads[wonder] ~= nil then
				failure_details[#failure_details + 1] =
					class_name .. " kept its queued GameInit thread"
			else
				local ok, err = pcall(wonder.GameInit, wonder)
				if ok then
					stats.ran = stats.ran + 1
					stats.attaches_added = stats.attaches_added + (attach_count(wonder) - before)
				else
					failure_details[#failure_details + 1] =
						class_name .. " GameInit failed: " .. tostring(err)
				end
			end
		end
	end
	stats.failures = #failure_details
	stats.error = table.concat(failure_details, " | ")
	LoadingStep("underground buried wonder spawn lifecycle completed", stats, map)
	return stats.failures == 0, stats
end

function WonderVerticalDiagnostics.WonderScenarioExists(wonder)
	local list_name = wonder and wonder.sequence_list
	local sequence = wonder and wonder.sequence
	local scenarios = Global("Scenarios")
	local list = type(scenarios) == "table" and scenarios[list_name] or nil
	if type(list_name) ~= "string" or list_name == ""
		or type(sequence) ~= "string" or sequence == "" or type(list) ~= "table" then
		return false
	end
	for _, entry in pairs(list) do
		if type(entry) == "table" and entry.name == sequence then return true end
	end
	return false
end

function WonderVerticalDiagnostics.LinkedWonderAnomalies(map)
	local linked = {}
	for _, marker in ipairs(ArtefactMapGet(map, "SubsurfaceAnomalyMarker")) do
		local spawner = marker and marker.spawner
		if spawner then
			local list = linked[spawner]
			if not list then list = {}; linked[spawner] = list end
			list[#list + 1] = marker
		end
	end
	return linked
end

function WonderVerticalDiagnostics.AuditDeferredUndergroundWonderAnomalies(
	map, spawn_missing, reason)
	local wonders, allowed = WonderVerticalDiagnostics.LiveDeferredUndergroundWonders(map)
	local expected = tonumber(map and map.SuperBigMapDeferredUndergroundWondersSpawned)
		or tonumber(map and map.SuperBigMapDeferredUndergroundWonderCount) or #wonders
	local stats = {
		reason = tostring(reason or ""), expected = expected, wonders = #wonders,
		existing = 0, spawned = 0, linked_markers = 0, failures = 0,
		city_labels_ready = 0, city_labels_pending_gameinit = 0,
	}
	local failure_details, class_counts, marker_details = {}, {}, {}
	local function fail(message)
		stats.failures = stats.failures + 1
		failure_details[#failure_details + 1] = tostring(message)
	end
	if #wonders ~= expected then
		fail("wonder count " .. tostring(#wonders) .. " does not match expected "
			.. tostring(expected))
	end

	local linked = WonderVerticalDiagnostics.LinkedWonderAnomalies(map)
	for _, wonder in ipairs(wonders) do
		local class_name = tostring(wonder.class or "?")
		class_counts[class_name] = (class_counts[class_name] or 0) + 1
		if not allowed[class_name] or not IsKindOfSafe(wonder, "UndergroundWonder") then
			fail(class_name .. " is not a vanilla UndergroundWonder")
		end
		if wonder.city ~= map.City then fail(class_name .. " has the wrong city") end
		if WonderVerticalDiagnostics.WonderCityLabelContains(map, wonder) then
			stats.city_labels_ready = stats.city_labels_ready + 1
		elseif WonderVerticalDiagnostics.WonderGameInitPending(wonder) then
			-- PlaceBuildingIn schedules GameInit on a game-time thread. First-access underground
			-- construction runs while game time is paused, so vanilla has not registered the class
			-- label yet. Accept only this proven pending state; GameInit will perform the normal
			-- idempotent label registration as soon as the loading transaction releases game time.
			stats.city_labels_pending_gameinit = stats.city_labels_pending_gameinit + 1
		else
			fail(class_name .. " is absent from its city label with no GameInit pending")
		end
		if type(wonder.CompleteSequence) ~= "function"
			or type(wonder.IsSequenceComplete) ~= "function" then
			fail(class_name .. " is missing its vanilla completion API")
		end
		if not WonderVerticalDiagnostics.WonderScenarioExists(wonder) then
			fail(class_name .. " scenario " .. tostring(wonder.sequence_list) .. "/"
				.. tostring(wonder.sequence) .. " is unavailable")
		end

		local markers = linked[wonder] or {}
		if #markers == 0 and spawn_missing == true then
			if type(wonder.Spawn) ~= "function" then
				fail(class_name .. " is missing SpawnsAnomalyOnCityInit:Spawn")
			else
				local spawn_ok, spawn_error = pcall(wonder.Spawn, wonder)
				if not spawn_ok then
					fail(class_name .. " rare-anomaly Spawn failed: " .. tostring(spawn_error))
				else
					stats.spawned = stats.spawned + 1
					linked = WonderVerticalDiagnostics.LinkedWonderAnomalies(map)
					markers = linked[wonder] or {}
				end
			end
		elseif #markers == 1 then
			stats.existing = stats.existing + 1
		end

		if #markers ~= 1 then
			fail(class_name .. " has " .. tostring(#markers)
				.. " linked rare-anomaly markers; expected exactly 1")
		else
			local marker = markers[1]
			stats.linked_markers = stats.linked_markers + 1
			if not IsKindOfSafe(marker, "SubsurfaceSpecialAnomalyMarker") then
				fail(class_name .. " linked marker has class " .. tostring(marker.class))
			end
			if marker.spawner ~= wonder then fail(class_name .. " linked marker lost its spawner") end
			if marker.sequence ~= wonder.sequence
				or marker.sequence_list ~= wonder.sequence_list then
				fail(class_name .. " linked marker has the wrong scenario")
			end
			if marker.rare ~= wonder.anomaly_rare or marker.rare ~= true then
				fail(class_name .. " linked marker is not a rare anomaly")
			end
			if marker.SuperBigMapAnomalyTopUp == true
				or marker.SuperBigMapEnrichmentClone == true then
				fail(class_name .. " linked marker was incorrectly classified as a top-up")
			end
			if type(marker.GetMap) == "function" and SafeCall(marker.GetMap, marker) ~= map then
				fail(class_name .. " linked marker is on the wrong map")
			end
			wonder.SuperBigMapDeferredWonderAnomalySpawned = true
			marker.SuperBigMapDeferredWonderAnomaly = true
			marker.SuperBigMapDeferredWonderClass = class_name
			local pos = Engine.ObjectPos(marker)
			local x, y = PointXY(pos)
			marker_details[#marker_details + 1] = class_name .. "@"
				.. tostring(x) .. "," .. tostring(y)
		end
	end

	local classes = {}
	for class_name, count in pairs(class_counts) do
		classes[#classes + 1] = class_name .. "=" .. tostring(count)
	end
	table.sort(classes)
	table.sort(marker_details)
	stats.classes = table.concat(classes, ",")
	stats.markers = table.concat(marker_details, ";")
	stats.error = table.concat(failure_details, " | ")
	local ok = stats.failures == 0 and stats.linked_markers == #wonders
	if ok and map then
		map.SuperBigMapDeferredWonderAnomaliesDone = true
		map.SuperBigMapDeferredWonderAnomaliesSpawned = math.max(
			tonumber(map.SuperBigMapDeferredWonderAnomaliesSpawned) or 0, stats.spawned)
		map.SuperBigMapDeferredWonderAnomaliesAudited = stats.linked_markers
	end
	LoadingStep("underground buried wonder anomaly audit", stats, map)
	return ok, stats
end

-- SurfacePassage is the underground half of a natural Elevator anchor. Its inherited
-- SpawnsOnCityInit:Spawn creates the SurfaceTunnelMarker and immediately calls
-- FindUnobstructedDepositPos, which requires the BuildableGrid and object hex grid to have
-- identical dimensions. During deferred expansion CityInitialized sees a 6144 buildable grid and
-- an 8192 object grid, so spawning the marker then asserts in HexGridFindBuildable. Keep the linked
-- passage object eager (Elevator snapping depends on it), but defer only this child marker until the
-- first-access pipeline has stretched the terrain and rebuilt both final grids.
local function IsDeferredUndergroundTunnelSpawn(spawner)
	if not spawner or type(spawner.GetMap) ~= "function" then return false end
	local ok_map, map = pcall(spawner.GetMap, spawner)
	if not ok_map or type(map) ~= "table" or type(map.mapdata) ~= "table"
		or map.mapdata.Environment ~= "Underground" then
		return false
	end
	local desired = map.SuperBigMapDesiredWidthTiles
	local generated = map.SuperBigMapGeneratorWidthTiles
	return cfg_bool("STRETCH_UNDERGROUND", false)
		and type(desired) == "number" and type(generated) == "number" and desired > generated
		and map.SuperBigMapUndergroundPrepared ~= true
		and spawner.SuperBigMapDeferredTunnelSpawnDone ~= true,
		map
end

local function PatchDeferredUndergroundTunnelSpawn()
	local State = SuperBigMap.State
	local passage_class = Engine.ClassTable and Engine.ClassTable("SurfacePassage")
	if type(passage_class) ~= "table" then
		return false
	end
	local current = passage_class.Spawn
	if current == State.deferred_tunnel_spawn_wrapper then return true end
	if type(current) ~= "function" then
		return false
	end
	State.original_surface_passage_spawn = current
	local wrapper = function(self, ...)
		local should_defer, map = IsDeferredUndergroundTunnelSpawn(self)
		if should_defer then
			local newly_pending = self.SuperBigMapDeferredTunnelSpawnPending ~= true
			self.SuperBigMapDeferredTunnelSpawnPending = true
			map.SuperBigMapDeferredTunnelSpawnsPending = true
			if newly_pending then
				map.SuperBigMapDeferredTunnelSpawnCount =
					(type(map.SuperBigMapDeferredTunnelSpawnCount) == "number"
						and map.SuperBigMapDeferredTunnelSpawnCount or 0) + 1
			end
			return
		end
		local original = State.original_surface_passage_spawn
		return original(self, ...)
	end
	passage_class.Spawn = wrapper
	State.deferred_tunnel_spawn_wrapper = wrapper
	return true
end

local function MaterializeDeferredUndergroundTunnelSpawns(map)
	local State = SuperBigMap.State
	local original = State.original_surface_passage_spawn
	if type(original) ~= "function" then
		return false, "original SurfacePassage:Spawn is unavailable"
	end
	local passages = ArtefactMapGet(map, "SurfacePassage")
	local pending = {}
	for _, passage in ipairs(passages) do
		if passage.SuperBigMapDeferredTunnelSpawnPending == true
			and passage.SuperBigMapDeferredTunnelSpawnDone ~= true then
			pending[#pending + 1] = passage
		end
	end
	if map.SuperBigMapDeferredTunnelSpawnsPending ~= true and #pending == 0 then
		return true, 0
	end
	if #pending == 0 then
		return false, "tunnel marker spawn is pending but no deferred SurfacePassage survives"
	end
	local spawned = 0
	for _, passage in ipairs(pending) do
		local ok, err = pcall(original, passage)
		if not ok then
			return false, "SurfacePassage marker spawn failed: " .. tostring(err)
		end
		local matched = false
		for _, marker in ipairs(ArtefactMapGet(map, "SurfaceTunnelMarker")) do
			if marker.spawner == passage then matched = true break end
		end
		if not matched then
			return false, "SurfacePassage marker spawn returned without a linked SurfaceTunnelMarker"
		end
		passage.SuperBigMapDeferredTunnelSpawnPending = false
		passage.SuperBigMapDeferredTunnelSpawnDone = true
		spawned = spawned + 1
	end
	map.SuperBigMapDeferredTunnelSpawnsPending = false
	return spawned == #pending, spawned
end

-- SurfacePassage's own entity is only a tiny carrier plane. Vanilla renders the visible underground
-- ground marker through the carrier entity's baked-decal auto-attachment,
-- ElevatorBuildIndicator_UndergroundPassageImprint. SurfacePassageRocks is a different standalone
-- obstruction class and must not be used as an attachment test. The stretch may move an attached
-- child independently from its carrier, so rebuild the vanilla entity attachments only after the
-- passage reaches its committed final position. Once an Elevator is linked, retain vanilla behavior:
-- the passage carrier and its marker attachments stay hidden beneath the completed building.
local function RefreshVanillaUndergroundPassageIndicators(map)
	local auto_attach = Global("AutoAttachObjects")
	local point_fn = Global("point")
	local terrain_api = Global("terrain")
	if type(auto_attach) ~= "function" or type(point_fn) ~= "function" then
		return false, { error = "vanilla auto-attachment APIs unavailable" }
	end
	local passages = ArtefactMapGet(map, "SurfacePassage")
	local expected_decal_entity = "ElevatorBuildIndicator_UndergroundPassageImprint"
	local stats = {
		passages = #passages, rebuilt = 0, decals = 0,
		built_markers = 0, built_hidden = 0, unbuilt_markers = 0,
	}
	for index, passage in ipairs(passages) do
		local built = TraversalObjectValid(passage.elevator)
		if built then
			stats.built_markers = stats.built_markers + 1
			if type(passage.SetVisible) == "function" then pcall(passage.SetVisible, passage, false) end
			stats.built_hidden = stats.built_hidden + 1
			stats.rebuilt = stats.rebuilt + 1
		else
			stats.unbuilt_markers = stats.unbuilt_markers + 1
		local entity
		if type(passage.GetEntity) == "function" then
			local ok_entity, value = pcall(passage.GetEntity, passage)
			if ok_entity then entity = value end
		end
		if entity ~= "ElevatorBuildIndicator_Underground"
			and type(passage.ChangeEntity) == "function" then
			local ok_entity, err = pcall(
				passage.ChangeEntity, passage, "ElevatorBuildIndicator_Underground")
			if not ok_entity then
				return false, { error = "failed to restore vanilla passage entity: " .. tostring(err),
					index = index }
			end
			entity = "ElevatorBuildIndicator_Underground"
		end
		-- Re-seat the carrier on final terrain before rebuilding relative visual attachments.
		local ok_pos, pos = false, nil
		if type(passage.GetPos) == "function" then
			ok_pos, pos = pcall(passage.GetPos, passage)
		end
		if ok_pos then
			local x, y = PointXY(pos)
			if type(x) == "number" and type(y) == "number" then
				local target = point_fn(x, y)
				if type(map.SnapToTerrain) == "function" then
					local ok_snap, snapped = pcall(map.SnapToTerrain, map, target)
					if ok_snap and snapped then target = snapped end
				elseif type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function" then
					local ok_height, z = pcall(terrain_api.GetHeight, map, target)
					if ok_height and type(z) == "number" then target = point_fn(x, y, z) end
				end
				if type(passage.SetPos) == "function" then pcall(passage.SetPos, passage, target) end
			end
		end
		if type(passage.DestroyAttaches) == "function" then
			local ok_destroy, err = pcall(passage.DestroyAttaches, passage)
			if not ok_destroy then
				return false, { error = "failed to clear stale passage attachments: " .. tostring(err),
					index = index }
			end
		end
		local ok_attach, err = pcall(auto_attach, passage)
		if not ok_attach then
			return false, { error = "failed to rebuild vanilla passage attachments: " .. tostring(err),
				index = index }
		end
		local decals = {}
		if type(passage.GetAttaches) == "function" then
			local ok_attaches, attaches = pcall(passage.GetAttaches, passage)
			if ok_attaches and type(attaches) == "table" then
				for _, visual in ipairs(attaches) do
					local visual_entity
					if visual and type(visual.GetEntity) == "function" then
						local ok_visual_entity, value = pcall(visual.GetEntity, visual)
						if ok_visual_entity then visual_entity = value end
					end
					if visual_entity == expected_decal_entity then
						decals[#decals + 1] = visual
					end
				end
			end
		end
		if #decals == 0 then
			return false, { error = "vanilla underground passage baked-decal attachment was not recreated",
				index = index, entity = tostring(entity), expected_decal_entity = expected_decal_entity }
		end
		for _, visual in ipairs(decals) do
			if type(visual.SetVisible) == "function" then pcall(visual.SetVisible, visual, true) end
			if type(visual.SetOpacity) == "function" then pcall(visual.SetOpacity, visual, 100) end
		end
		if type(passage.SetVisible) == "function" then pcall(passage.SetVisible, passage, true) end
		if type(passage.SetOpacity) == "function" then pcall(passage.SetOpacity, passage, 100) end
		stats.rebuilt = stats.rebuilt + 1
		stats.decals = stats.decals + #decals
		end
	end
	return stats.passages > 0 and stats.rebuilt == stats.passages
		and stats.decals >= stats.unbuilt_markers, stats
end

local function PassageObjectVisible(obj)
	if not obj or type(obj.GetVisible) ~= "function" then return nil end
	local ok, visible = pcall(obj.GetVisible, obj)
	return ok and visible == true or false
end

local completed_passage_rock_entities = {
	ElevatorBuildIndicator_SurfaceRocks = true,
	ElevatorBuildIndicator_UndergroundRocks = true,
}

local function PassageObjectEntity(obj)
	if not obj or type(obj.GetEntity) ~= "function" then return nil end
	local ok, entity = pcall(obj.GetEntity, obj)
	return ok and entity or nil
end

local function PassageObjectOpacity(obj)
	if not obj or type(obj.GetOpacity) ~= "function" then return nil end
	local ok, opacity = pcall(obj.GetOpacity, obj)
	return ok and opacity or nil
end

local function PassageObjectParent(obj)
	if not obj then return nil end
	if type(obj.GetParent) == "function" then
		local ok, parent = pcall(obj.GetParent, obj)
		if ok and parent then return parent end
	end
	if type(obj.GetAttachParent) == "function" then
		local ok, parent = pcall(obj.GetAttachParent, obj)
		if ok then return parent end
	end
	return nil
end

local function PassageVisualRelevant(obj, entity)
	entity = tostring(entity or PassageObjectEntity(obj) or "")
	if completed_passage_rock_entities[entity] then return true end
	local identity = (TraversalClass(obj) .. " " .. entity):lower()
	return identity:find("elevator", 1, true) ~= nil
		or identity:find("passage", 1, true) ~= nil
		or identity:find("rock", 1, true) ~= nil
		or identity:find("imprint", 1, true) ~= nil
		or identity:find("indicator", 1, true) ~= nil
end

local function PassageVisualDetail(obj, role, depth, before, after, hide_ok)
	local pos = Engine.ObjectPos(obj)
	local x, y = PointXY(pos)
	local attach_spot = type(obj.GetAttachSpot) == "function"
		and SafeCall(obj.GetAttachSpot, obj) or nil
	return table.concat({
		"role=" .. tostring(role), "depth=" .. tostring(depth), "object=" .. tostring(obj),
		"class=" .. TraversalClass(obj), "entity=" .. tostring(PassageObjectEntity(obj)),
		"map=" .. tostring(TraversalObjectMap(obj)), "x=" .. tostring(x), "y=" .. tostring(y),
		"parent=" .. tostring(PassageObjectParent(obj)), "spot=" .. tostring(attach_spot),
		"visible_before=" .. tostring(before), "visible_after=" .. tostring(after),
		"opacity=" .. tostring(PassageObjectOpacity(obj)), "hide_ok=" .. tostring(hide_ok),
	}, ":")
end

local function HideCompletedPassageVisual(obj, force_marker_visual)
	local entity = PassageObjectEntity(obj)
	local marker_rock = completed_passage_rock_entities[tostring(entity)] == true
	local marker_visual = force_marker_visual == true or marker_rock
	if not marker_visual then return marker_rock, false, false end
	local visible_ok = type(obj.SetVisible) == "function"
		and pcall(obj.SetVisible, obj, false) or false
	local opacity_ok = type(obj.SetOpacity) == "function"
		and pcall(obj.SetOpacity, obj, 0) or false
	local hide_ok = visible_ok or opacity_ok
	if hide_ok then obj.SuperBigMapHiddenByCompletedElevator = true end
	return marker_rock, marker_visual, hide_ok
end

-- Audit the complete auto-attachment tree because LinkThroughPassage rebuilds both the passage and
-- Elevator attaches after it hides the marker carrier. In the failing run there were zero standalone
-- SurfacePassageRocks / UndergroundPassageRocks, proving that the visible ramp rocks were outside the
-- old class-only scan. Every passage child is marker-only artwork and is suppressed; Elevator
-- children are only suppressed when they use one of the two exact marker-rock entities.
local function AuditAndHidePassageVisualTree(
	root, role, seen, details, stats, depth, force_marker_visual)
	if not TraversalObjectValid(root) or seen[root] then return end
	seen[root] = true
	depth = tonumber(depth) or 0
	if depth == 0 and #details < 96 then
		details[#details + 1] = PassageVisualDetail(root, role .. "-root", depth,
			PassageObjectVisible(root), PassageObjectVisible(root), false)
	end
	if depth >= 6 or type(root.GetAttaches) ~= "function" then return end
	local ok_attaches, attaches = pcall(root.GetAttaches, root)
	if not ok_attaches or type(attaches) ~= "table" then
		stats.attach_failures = stats.attach_failures + 1
		return
	end
	for index, attach in ipairs(attaches) do
		if TraversalObjectValid(attach) and not seen[attach] then
			stats.attachments = stats.attachments + 1
			local before = PassageObjectVisible(attach)
			local marker_rock, marker_visual, hide_ok = HideCompletedPassageVisual(
				attach, force_marker_visual)
			if marker_rock then
				stats.marker_rocks = stats.marker_rocks + 1
			end
			if marker_visual then stats.marker_visuals = stats.marker_visuals + 1 end
			if hide_ok then stats.hidden = stats.hidden + 1 end
			local entity = PassageObjectEntity(attach)
			if (PassageVisualRelevant(attach, entity) or marker_visual) and #details < 96 then
				details[#details + 1] = PassageVisualDetail(attach,
					role .. "-attach-" .. tostring(index), depth + 1, before,
					PassageObjectVisible(attach), hide_ok)
			end
			AuditAndHidePassageVisualTree(
				attach, role, seen, details, stats, depth + 1, force_marker_visual)
		end
	end
end

local function HideLinkedTunnelMarkerVisuals(passage, map, seen, details, stats)
	for _, class_name in ipairs({ "UndergroundTunnelMarker", "SurfaceTunnelMarker" }) do
		for _, marker in ipairs(ArtefactMapGet(map, class_name)) do
			if marker.spawner == passage then
				for _, entry in ipairs({
					{ object = marker, role = class_name },
					{ object = marker.tunnel_sign, role = class_name .. "-sign" },
				}) do
					local visual = entry.object
					if TraversalObjectValid(visual) and not seen[visual] then
						local before = PassageObjectVisible(visual)
						local _, marker_visual, hide_ok = HideCompletedPassageVisual(visual, true)
						seen[visual] = true
						if marker_visual then stats.marker_visuals = stats.marker_visuals + 1 end
						if hide_ok then stats.hidden = stats.hidden + 1 end
						if #details < 96 then
							details[#details + 1] = PassageVisualDetail(visual,
								entry.role, 0, before, PassageObjectVisible(visual), hide_ok)
						end
					end
				end
			end
		end
	end
end

local function AuditAndHideNearbyPassageVisuals(map, anchor, max_distance_sq, seen, details, stats)
	if not map or type(map.MapForEach) ~= "function" then return false end
	local ax, ay = PointXY(anchor)
	if type(ax) ~= "number" or type(ay) ~= "number" then return false end
	return pcall(map.MapForEach, map, anchor, math.sqrt(max_distance_sq), "CObject", function(obj)
		stats.cobjects = stats.cobjects + 1
		local pos = Engine.ObjectPos(obj)
		local x, y = PointXY(pos)
		if type(x) ~= "number" or type(y) ~= "number" then return end
		local dx, dy = x - ax, y - ay
		if dx * dx + dy * dy > max_distance_sq then return end
		stats.nearby = stats.nearby + 1
		local entity = PassageObjectEntity(obj)
		if not PassageVisualRelevant(obj, entity) then return end
		local before = PassageObjectVisible(obj)
		local marker_rock, marker_visual, hide_ok = HideCompletedPassageVisual(obj, false)
		if marker_rock and not seen[obj] then
			stats.marker_rocks = stats.marker_rocks + 1
			if marker_visual then stats.marker_visuals = stats.marker_visuals + 1 end
			if hide_ok then stats.hidden = stats.hidden + 1 end
		end
		if #details < 96 then
			details[#details + 1] = PassageVisualDetail(obj, "nearby-map-object", 0,
				before, PassageObjectVisible(obj), hide_ok)
		end
		seen[obj] = true
	end)
end

-- SurfacePassageRocks / UndergroundPassageRocks are normally standalone WasteRockObstructors, but
-- depending on the LinkThroughPassage rebuild boundary the same rock entities can also survive as
-- generic autoattachments. Scan both forms and run again after the first-access loader closes.
local function HideCompletedPassageRocks(passage, reason)
	local map = TraversalObjectMap(passage)
	if not map then return 0, "" end
	local anchor = Engine.ObjectPos(passage)
	local ax, ay = PointXY(anchor)
	if ax == false or ay == nil then return 0, "" end
	local const_tbl = Global("const")
	local hex_size = type(const_tbl) == "table" and tonumber(const_tbl.HexSize) or 1000
	local max_distance = math.max(1000, (hex_size or 1000) * 12)
	local max_distance_sq = max_distance * max_distance
	local details = {}
	local seen = setmetatable({}, { __mode = "k" })
	local stats = {
		hidden = 0, marker_rocks = 0, marker_visuals = 0,
		attachments = 0, attach_failures = 0,
		cobjects = 0, nearby = 0, standalone = 0,
	}
	for _, class_name in ipairs({ "SurfacePassageRocks", "UndergroundPassageRocks" }) do
		for _, rocks in ipairs(ArtefactMapGet(map, class_name)) do
			local pos = Engine.ObjectPos(rocks)
			local rx, ry = PointXY(pos)
			if type(rx) == "number" and type(ry) == "number" then
				local dx, dy = rx - ax, ry - ay
				local distance_sq = dx * dx + dy * dy
				if distance_sq <= max_distance_sq then
					local visible_before = PassageObjectVisible(rocks)
					local marker_rock, marker_visual, hide_ok = HideCompletedPassageVisual(
						rocks, false)
					stats.standalone = stats.standalone + 1
					if marker_rock then stats.marker_rocks = stats.marker_rocks + 1 end
					if marker_visual then stats.marker_visuals = stats.marker_visuals + 1 end
					if hide_ok then stats.hidden = stats.hidden + 1 end
					seen[rocks] = true
					if #details < 96 then
						details[#details + 1] = PassageVisualDetail(rocks,
							"standalone-" .. class_name, 0, visible_before,
							PassageObjectVisible(rocks), hide_ok)
					end
				end
			end
		end
	end
	-- Every child of a passage carrier is marker-only artwork. Once an Elevator is completed,
	-- suppress that full tree (including SurfaceDecal / UndergroundPassageImprint), but inspect the
	-- Elevator tree in exact-entity mode so doors, cabins, lights, and chargers remain untouched.
	AuditAndHidePassageVisualTree(passage, "passage", seen, details, stats, 0, true)
	AuditAndHidePassageVisualTree(passage.elevator, "elevator", seen, details, stats, 0, false)
	HideLinkedTunnelMarkerVisuals(passage, map, seen, details, stats)
	local map_scan_ok = AuditAndHideNearbyPassageVisuals(
		map, anchor, max_distance_sq, seen, details, stats)
	ElevatorTraversalAudit("PASSAGE_ROCKS_ENFORCED", {
		passage = tostring(passage), elevator = tostring(passage.elevator),
		reason = tostring(reason), max_distance = max_distance,
		hidden = stats.hidden, marker_rocks = stats.marker_rocks,
		marker_visuals = stats.marker_visuals,
		standalone = stats.standalone, attachments = stats.attachments,
		attach_failures = stats.attach_failures, cobjects = stats.cobjects,
		nearby = stats.nearby, map_scan_ok = tostring(map_scan_ok),
		visuals = table.concat(details, " | "),
	}, map)
	return stats.hidden, table.concat(details, " | ")
end

local function HideCompletedPassageIndicator(passage, reason)
	if not TraversalObjectValid(passage) then return 0, 0 end
	local hidden = 0
	local visible_ok = type(passage.SetVisible) == "function"
		and pcall(passage.SetVisible, passage, false) or false
	local opacity_ok = type(passage.SetOpacity) == "function"
		and pcall(passage.SetOpacity, passage, 0) or false
	if visible_ok or opacity_ok then hidden = 1 end
	-- Enforce the same result on standalone rocks, the passage's marker-only attachment tree, and
	-- the linked tunnel marker/sign. Elevator doors, cabins, lights, and chargers are only audited.
	local rocks_hidden = HideCompletedPassageRocks(passage, reason)
	return hidden, rocks_hidden
end

local function HideCompletedPassagePair(elevator, reason)
	local passage = elevator and elevator.passage or nil
	local map = TraversalObjectMap(passage)
	if not passage or not TraversalIsExpandedMap(map) then return 0, 0 end
	local hidden, rocks_hidden = HideCompletedPassageIndicator(passage, reason)
	local other_hidden, other_rocks_hidden = HideCompletedPassageIndicator(passage.other, reason)
	hidden = hidden + other_hidden
	rocks_hidden = rocks_hidden + other_rocks_hidden
	ExpansionAudit("BUILT_PASSAGE_MARKERS_HIDDEN", {
		elevator = tostring(elevator), passage = tostring(passage),
		other_passage = tostring(passage.other), reason = tostring(reason),
		hidden = hidden, rocks_hidden = rocks_hidden,
	}, map)
	ElevatorTraversalAudit("BUILT_PASSAGE_MARKERS_ENFORCED", {
		elevator = tostring(elevator), passage = tostring(passage),
		other_passage = tostring(passage.other), reason = tostring(reason),
		hidden = hidden, rocks_hidden = rocks_hidden,
	}, map)
	return hidden, rocks_hidden
end

local function HideExistingCompletedPassageIndicators(reason)
	local maps = Global("Maps")
	if type(maps) ~= "table" then return 0 end
	local hidden, seen = 0, setmetatable({}, { __mode = "k" })
	for _, map in pairs(maps) do
		if TraversalIsExpandedMap(map) then
			for _, class_name in ipairs({ "SurfacePassage", "UndergroundPassage" }) do
				for _, passage in ipairs(ArtefactMapGet(map, class_name)) do
					local elevator = passage and passage.elevator
					if TraversalObjectValid(elevator) and not seen[elevator] then
						seen[elevator] = true
						if TraversalObjectValid(elevator.other) then seen[elevator.other] = true end
						local pair_hidden = HideCompletedPassagePair(elevator, reason)
						hidden = hidden + pair_hidden
					end
				end
			end
		end
	end
	return hidden
end

local function RestorePassageMarkerVisualTree(root, seen)
	if not TraversalObjectValid(root) or seen[root] then return 0 end
	seen[root] = true
	local restored = 0
	local visible_ok = type(root.SetVisible) == "function"
		and pcall(root.SetVisible, root, true) or false
	local opacity_ok = type(root.SetOpacity) == "function"
		and pcall(root.SetOpacity, root, 100) or false
	if visible_ok or opacity_ok then restored = restored + 1 end
	root.SuperBigMapHiddenByCompletedElevator = nil
	if type(root.GetAttaches) == "function" then
		local ok, attaches = pcall(root.GetAttaches, root)
		if ok and type(attaches) == "table" then
			for _, attach in ipairs(attaches) do
				restored = restored + RestorePassageMarkerVisualTree(attach, seen)
			end
		end
	end
	return restored
end

-- Our zero-opacity fallback is stronger than vanilla's SetVisible(false), so explicitly undo it
-- when vanilla removes an Elevator and exposes the passage again.
local function RestoreUnlinkedPassageIndicators(passage, reason)
	if not TraversalObjectValid(passage) or TraversalObjectValid(passage.elevator) then return 0 end
	local map = TraversalObjectMap(passage)
	local seen = setmetatable({}, { __mode = "k" })
	local restored = RestorePassageMarkerVisualTree(passage, seen)
	if map then
		for _, class_name in ipairs({ "UndergroundTunnelMarker", "SurfaceTunnelMarker" }) do
			for _, marker in ipairs(ArtefactMapGet(map, class_name)) do
				if marker.spawner == passage then
					restored = restored + RestorePassageMarkerVisualTree(marker, seen)
					restored = restored + RestorePassageMarkerVisualTree(marker.tunnel_sign, seen)
				end
			end
		end
		local anchor = Engine.ObjectPos(passage)
		local ax, ay = PointXY(anchor)
		local const_tbl = Global("const")
		local radius = math.max(1000,
			(tonumber(type(const_tbl) == "table" and const_tbl.HexSize) or 1000) * 12)
		for _, class_name in ipairs({ "SurfacePassageRocks", "UndergroundPassageRocks" }) do
			for _, rocks in ipairs(ArtefactMapGet(map, class_name)) do
				local rx, ry = PointXY(Engine.ObjectPos(rocks))
				if rocks.SuperBigMapHiddenByCompletedElevator == true
					and type(ax) == "number" and type(ay) == "number"
					and type(rx) == "number" and type(ry) == "number"
					and (rx - ax) * (rx - ax) + (ry - ay) * (ry - ay) <= radius * radius then
					restored = restored + RestorePassageMarkerVisualTree(rocks, seen)
				end
			end
		end
	end
	ElevatorTraversalAudit("PASSAGE_MARKER_VISUALS_RESTORED", {
		passage = tostring(passage), reason = tostring(reason), restored = restored,
	}, map)
	return restored
end

-- Vanilla hides each passage marker when a completed Elevator links through it. Keep that result
-- after the deferred counterpart reconstruction, and also clean up markers made visible by older
-- versions of this patch. The wrapper is map-scoped and leaves vanilla-size sessions untouched.
local function PatchPersistentBuiltUndergroundPassageMarker()
	local State = SuperBigMap.State
	local class = Engine.ClassTable and Engine.ClassTable("ElevatorBase")
	if type(class) ~= "table" or type(class.LinkThroughPassage) ~= "function"
		or type(class.Done) ~= "function" then return false end
	if class.LinkThroughPassage == State.persistent_passage_marker_wrapper
		and class.Done == State.persistent_passage_done_wrapper
		and State.persistent_passage_marker_patch_version == GENERATOR_PATCH_VERSION then
		return true
	end
	local original = class.LinkThroughPassage
	if original == State.persistent_passage_marker_wrapper
		and type(State.original_elevator_link_through_passage) == "function" then
		original = State.original_elevator_link_through_passage
	end
	local wrapper = function(self, ...)
		local result = PackValues(original(self, ...))
		SuperBigMap.ElevatorSupplyRepair.Pair(self,
			"ElevatorBase:LinkThroughPassage completed")
		SuperBigMap.ElevatorSupplyRepair.CargoPair(self,
			"ElevatorBase:LinkThroughPassage completed")
		HideCompletedPassagePair(self, "ElevatorBase:LinkThroughPassage")
		return Unpack(result, 1, result.n)
	end
	local original_done = class.Done
	if original_done == State.persistent_passage_done_wrapper
		and type(State.original_elevator_passage_done) == "function" then
		original_done = State.original_elevator_passage_done
	end
	local done_wrapper = function(self, ...)
		local done_map = ...
		local passage = self and self.passage or nil
		local other_passage = passage and passage.other or nil
		local result = PackValues(original_done(self, ...))
		if not done_map then
			RestoreUnlinkedPassageIndicators(passage, "ElevatorBase:Done")
			RestoreUnlinkedPassageIndicators(other_passage, "ElevatorBase:Done other passage")
		end
		return Unpack(result, 1, result.n)
	end
	State.original_elevator_link_through_passage = original
	State.persistent_passage_marker_wrapper = wrapper
	State.original_elevator_passage_done = original_done
	State.persistent_passage_done_wrapper = done_wrapper
	State.persistent_passage_marker_patch_version = GENERATOR_PATCH_VERSION
	class.LinkThroughPassage = wrapper
	class.Done = done_wrapper
	-- Do not enumerate live autoattachments while installing this wrapper. The debug executable can
	-- hot-reload mod code from FileSystemChanged while generated entity classes are being replaced;
	-- GetAttaches then tries to resolve classes such as ElevatorBuildIndicator_SurfaceDecal and raises
	-- an undefined-global assertion. Existing markers are already enforced at the map-lifecycle and
	-- first-access final boundaries below, while newly linked Elevators are handled by the wrapper.
	ElevatorTraversalAudit("PASSAGE_MARKER_PATCH_INSTALLED", {
		cleanup_deferred_to_safe_boundary = true,
	}, Global("CurrentMap"))
	return true
end

local function PatchAdditionalMapSeedReservation()
	local State = SuperBigMap.State
	local generator_class = Global("RandomMapGenerator")
	local generator_callable = State.generator_original_generate
		or (type(generator_class) == "table" and generator_class.Generate)
	local targets = {}
	local seen = {}
	local function add_target(label, env, reader, writer, identity)
		identity = identity or env
		if type(env) ~= "table" or seen[identity] then return end
		local additional = type(reader) == "function"
			and reader("GenerateAdditionalMaps") or rawget(env, "GenerateAdditionalMaps")
		local fill = type(reader) == "function"
			and reader("FillRandomMapGen") or rawget(env, "FillRandomMapGen")
		if type(additional) ~= "function" or type(fill) ~= "function" then return end
		seen[identity] = true
		targets[#targets + 1] = {
			label = label,
			env = env,
			additional = additional,
			fill = fill,
			reader = reader,
			writer = writer,
		}
	end
	local function add_environment_bridge(label, env)
		if type(env) ~= "table" then return end
		-- Relaunched deliberately hides the sandbox metatable from code compiled inside it. Exercise
		-- the public __index/__newindex behavior through ordinary access instead: temporarily remove
		-- the raw sandbox shadow, read/write the inherited existing global, then restore the shadow.
		-- Every transaction is synchronous and verified before it returns.
		local function read(name)
			local direct = rawget(env, name)
			rawset(env, name, nil)
			local read_ok, value = pcall(function() return env[name] end)
			rawset(env, name, direct)
			return read_ok and value or nil
		end
		local function write(name, value)
			local direct = rawget(env, name)
			rawset(env, name, nil)
			local write_ok = pcall(function() env[name] = value end)
			local unexpected_direct = rawget(env, name)
			rawset(env, name, nil)
			local read_ok, inherited = pcall(function() return env[name] end)
			rawset(env, name, direct)
			local direct_expected = unexpected_direct == nil or unexpected_direct == value
			return write_ok and direct_expected and read_ok and inherited == value
		end
		add_target(label, env, read, write, label)
	end
	-- Mod code runs in a sandbox whose inherited globals can live in a distinct engine table.
	-- Function environments alone can therefore resolve back to the sandbox even while shipped
	-- generation resolves these consumers through the sandbox's __index chain. Follow only
	-- explicit environment links; add_target still requires direct ownership of both functions.
	local function parent_environment(env)
		if type(env) ~= "table" then return nil end
		local ok, metatable = pcall(getmetatable, env)
		if not ok or type(metatable) ~= "table" then return nil end
		local parent = rawget(metatable, "__index")
		if type(parent) == "table" then return parent end
		if type(parent) == "function" then return FunctionEnvironment(parent) end
		return nil
	end
	local function add_environment_chain(label, env)
		local visited = {}
		for depth = 0, 7 do
			if type(env) ~= "table" or visited[env] then return end
			visited[env] = true
			add_target(depth == 0 and label or string.format("%s_parent_%d", label, depth), env)
			env = parent_environment(env)
		end
	end
	-- RandomMapGenerator.Generate resolves GenerateAdditionalMaps in the shipped engine
	-- environment, not the mod sandbox. GenerateRandomMap/FillRandomMapProps resolve
	-- FillRandomMapGen there too. Mod sandboxes inherit that table through __index, so walk
	-- each bounded environment chain and patch every distinct table that directly owns both
	-- consumers. Relaunched's mod sandbox exposes neither getfenv/debug.getupvalue nor its own
	-- metatable, but ordinary reads/writes still route through the public __index/__newindex pair to
	-- existing shipped globals in their real owner table. Register that verified behavior instead
	-- of bypassing it with rawset. Retain the raw sandbox target for reload/diagnostic symmetry.
	add_environment_chain("engine_generator", FunctionEnvironment(generator_callable))
	add_environment_chain("engine_generate_random_map", FunctionEnvironment(Global("GenerateRandomMap")))
	add_environment_chain("engine_fill_random_map_props", FunctionEnvironment(Global("FillRandomMapProps")))
	add_environment_chain("mod_sandbox", _G)
	add_environment_bridge("mod_sandbox_inherited", _G)
	if #targets == 0 then
		return false
	end
	local function current_target_value(target, name)
		if type(target.reader) == "function" then return target.reader(name) end
		return rawget(target.env, name)
	end
	local function write_target_value(target, name, value)
		if type(target.writer) == "function" then return target.writer(name, value) end
		rawset(target.env, name, value)
		return rawget(target.env, name) == value
	end
	if State.additional_map_seed_patch_version == GENERATOR_PATCH_VERSION then
		local installed = true
		for _, target in ipairs(targets) do
			installed = installed
				and current_target_value(target, "GenerateAdditionalMaps")
					== State.generate_additional_maps_wrapper
				and current_target_value(target, "FillRandomMapGen")
					== State.fill_random_map_gen_wrapper
		end
		if installed then return true end
	end
	local original_additional = State.original_generate_additional_maps
	local original_fill = State.original_fill_random_map_gen
	local previous_additional_wrapper = State.generate_additional_maps_wrapper
	local previous_fill_wrapper = State.fill_random_map_gen_wrapper
	for _, target in ipairs(targets) do
		if target.additional ~= previous_additional_wrapper then
			original_additional = target.additional
		end
		if target.fill ~= previous_fill_wrapper then
			original_fill = target.fill
		end
		if target.label ~= "mod_sandbox"
			and type(original_additional) == "function" and type(original_fill) == "function" then
			break
		end
	end
	if type(original_additional) ~= "function" or type(original_fill) ~= "function" then
		return false
	end
	State.original_generate_additional_maps = original_additional
	State.original_fill_random_map_gen = original_fill

	local additional_wrapper = function(...)
		local map = Global("CurrentMap")
		local environment = map and map.mapdata and map.mapdata.Environment
		local grid = SuperBigMap.SectorGrid
		local expanded = map and type(grid) == "table" and type(grid.IsModMap) == "function"
			and grid.IsModMap(map) == true
		local no_underground = Global("IsGameRuleActive")
		no_underground = type(no_underground) == "function"
			and SafeCall(no_underground, "NoUndergroundAndAsteroids") == true
		if expanded and environment == "Surface" and not no_underground
			and not Global("UndergroundMap") then
			local pending = State.pending_vanilla_underground_seed
			if type(pending) ~= "table" or pending.surface ~= map then
				-- Compatibility fallback for an eligible expanded generation path that did not use
				-- the temporary-source transaction. It still consumes exactly the shipped one draw.
				local async_rand = Global("AsyncRand")
				if type(async_rand) ~= "function" then
					error("AsyncRand unavailable while reserving the vanilla underground seed")
				end
				local reserved_seed = async_rand()
				local twin_override = State.test_twin_underground_seed
				local boundary = "generate_additional_maps_fallback"
				local authority_tag
				if type(twin_override) == "table" and type(twin_override.seed) == "number" then
					reserved_seed = twin_override.seed
					authority_tag = twin_override.authority_tag
					boundary = "fresh_vanilla_twin_test_seam_fallback"
					State.test_twin_underground_seed = nil
				end
				pending = {
					seed = reserved_seed,
					surface = map,
					boundary = boundary,
					authority_tag = authority_tag,
				}
				State.pending_vanilla_underground_seed = pending
				State.underground_seed_reservation_trace = {
					boundary = pending.boundary,
					reserved_seed = pending.seed,
				}
				SuperBigMap.TraceUndergroundSeedReservation("RESERVATION", {
					boundary = pending.boundary,
					reserved_seed = tostring(pending.seed),
					authority_tag = tostring(pending.authority_tag or "production"),
				}, map)
			end
		else
			State.pending_vanilla_underground_seed = nil
			State.underground_seed_reservation_trace = nil
			State.test_twin_underground_seed = nil
		end
		local results = PackValues(pcall(original_additional, ...))
		if not results[1] then
			State.pending_vanilla_underground_seed = nil
			State.underground_seed_reservation_trace = nil
			error(results[2])
		end
		local pending = State.pending_vanilla_underground_seed
		if pending then
			local next_map = Global("GenerateNextMap")
			if type(next_map) ~= "table" or next_map.map_slot ~= 2 then
				State.pending_vanilla_underground_seed = nil
				State.underground_seed_reservation_trace = nil
			end
		end
		return Unpack(results, 2, results.n)
	end

	local fill_wrapper = function(gen, map_name, params)
		local pending = State.pending_vanilla_underground_seed
		local map_data_table = Global("MapData")
		local map_data = type(map_data_table) == "table" and map_data_table[map_name] or nil
		local environment = map_data and map_data.Environment
		if environment ~= "Underground" then
			return original_fill(gen, map_name, params)
		end
		local trace = State.underground_seed_reservation_trace
		if not pending then
			if type(trace) ~= "table" then
				return original_fill(gen, map_name, params)
			end
			local results = PackValues(pcall(original_fill, gen, map_name, params))
			trace.generator = gen
			trace.consumer_seed = gen and gen.Seed
			trace.consumer_status = "pending_missing"
			SuperBigMap.TraceUndergroundSeedReservation("CONSUMER", {
				boundary = tostring(trace.boundary),
				reserved_seed = tostring(trace.reserved_seed),
				seeded_params_seed = "pending_missing",
				consumer_seed = tostring(trace.consumer_seed),
				consumer_status = trace.consumer_status,
				fill_ok = tostring(results[1] == true),
			}, Global("CurrentMap"))
			if not results[1] then
				State.underground_seed_reservation_trace = nil
				error(results[2])
			end
			return Unpack(results, 2, results.n)
		end
		local source_params = params or Global("g_CurrentMapParams") or {}
		local seeded_params = {}
		for key, value in pairs(source_params) do seeded_params[key] = value end
		seeded_params.Seed = pending.seed
		if type(trace) ~= "table" then
			trace = {}
			State.underground_seed_reservation_trace = trace
		end
		trace.boundary = pending.boundary
		trace.reserved_seed = pending.seed
		trace.seeded_params_seed = seeded_params.Seed
		trace.generator = gen
		trace.consumer_status = "pending_injected"
		local previous_randomize = map_data.map_randomizeseed
		map_data.map_randomizeseed = false
		State.pending_vanilla_underground_seed = nil
		local results = PackValues(pcall(original_fill, gen, map_name, seeded_params))
		map_data.map_randomizeseed = previous_randomize
		trace.consumer_seed = gen and gen.Seed
		SuperBigMap.TraceUndergroundSeedReservation("CONSUMER", {
			boundary = tostring(trace.boundary),
			reserved_seed = tostring(trace.reserved_seed),
			seeded_params_seed = tostring(trace.seeded_params_seed),
			consumer_seed = tostring(trace.consumer_seed),
			consumer_status = trace.consumer_status,
			fill_ok = tostring(results[1] == true),
		}, Global("CurrentMap"))
		if not results[1] then
			State.underground_seed_reservation_trace = nil
			error(results[2])
		end
		return Unpack(results, 2, results.n)
	end

	local installed_targets = {}
	for _, target in ipairs(targets) do
		local original_target_additional = target.additional
		local original_target_fill = target.fill
		if original_target_additional == previous_additional_wrapper then
			original_target_additional = original_additional
		end
		if original_target_fill == previous_fill_wrapper then
			original_target_fill = original_fill
		end
		local record = {
			label = target.label,
			env = target.env,
			reader = target.reader,
			writer = target.writer,
			original_additional = original_target_additional,
			original_fill = original_target_fill,
		}
		local additional_installed = write_target_value(
			target, "GenerateAdditionalMaps", additional_wrapper)
		local fill_installed = additional_installed and write_target_value(
			target, "FillRandomMapGen", fill_wrapper)
		if not additional_installed or not fill_installed then
			write_target_value(target, "GenerateAdditionalMaps", original_target_additional)
			write_target_value(target, "FillRandomMapGen", original_target_fill)
			for index = #installed_targets, 1, -1 do
				local installed = installed_targets[index]
				write_target_value(installed, "GenerateAdditionalMaps", installed.original_additional)
				write_target_value(installed, "FillRandomMapGen", installed.original_fill)
			end
			return false
		end
		installed_targets[#installed_targets + 1] = record
	end
	State.generate_additional_maps_wrapper = additional_wrapper
	State.fill_random_map_gen_wrapper = fill_wrapper
	State.additional_map_seed_patch_version = GENERATOR_PATCH_VERSION
	State.additional_map_seed_patch_targets = installed_targets
	return true
end

function WonderVerticalDiagnostics.SeatDeferredWonderWithoutClearance(
	wonder, marker, map, source_flatten_z)
	local z_mul = tonumber(map.SuperBigMapZScaleMul)
	local z_div = tonumber(map.SuperBigMapZScaleDiv)
	local z_add = tonumber(map.SuperBigMapZScaleAdd) or 0
	local source_z = tonumber(source_flatten_z)
		or tonumber(marker and marker.SuperBigMapNativeWonderFlattenZ)
	if type(source_z) ~= "number" or type(z_mul) ~= "number"
		or type(z_div) ~= "number" or z_div <= 0 then
		return false, "native wonder floor transform is unavailable"
	end
	local buildable_z = math.floor(source_z * z_mul / z_div + z_add + 0.5)
	local position = type(wonder.GetPos) == "function" and wonder:GetPos() or nil
	local position_x, position_y = PointXY(position)
	local point_fn = Global("point")
	if type(position_x) ~= "number" or type(position_y) ~= "number"
		or type(point_fn) ~= "function" or type(wonder.SetPos) ~= "function" then
		return false, "cannot seat the stretched wonder at its transformed native floor"
	end
	wonder:SetPos(point_fn(position_x, position_y, buildable_z))
	return true, {
		buildable_z = buildable_z,
		buildable_source = "transformed_native_clearance_floor",
		clearance_mode = "native_clearance_before_stretch_no_replay",
		source_buildable_z = source_z,
		z_mul = z_mul,
		z_div = z_div,
		z_add = z_add,
	}
end

-- The temporary vanilla surface is unloaded before GenerateRandomMapsFinishing, so its anomaly
-- markers cannot participate in City:InitBreakThroughAnomalies at the normal boundary. The
-- expanded destination deliberately keeps those markers as staged value records until after the
-- terrain stretch. Defer only this one City initializer and invoke the shipped method once the
-- complete marker set has been recreated. This preserves vanilla's marker order, shuffle, tech
-- cap, planetary reservation, and (including Chaos Theory) random-stream cardinality exactly.
function SuperBigMap.PatchDeferredBreakthroughAnomalyInitialization()
	local State = SuperBigMap.State
	local city_class = Engine.ClassTable and Engine.ClassTable("City") or Global("City")
	if type(city_class) ~= "table"
		or type(city_class.InitBreakThroughAnomalies) ~= "function" then
		return false
	end
	if State.breakthrough_init_patch_version == GENERATOR_PATCH_VERSION
		and city_class.InitBreakThroughAnomalies == State.breakthrough_init_wrapper then
		return true
	end
	if city_class.InitBreakThroughAnomalies ~= State.breakthrough_init_wrapper then
		State.original_city_init_breakthrough_anomalies =
			city_class.InitBreakThroughAnomalies
	end
	local original = State.original_city_init_breakthrough_anomalies
	if type(original) ~= "function" then return false end
	local wrapper = function(self, ...)
		local map = self and type(self.GetMap) == "function" and SafeCall(self.GetMap, self)
		local mapdata = map and map.mapdata
		local desired = map and tonumber(map.SuperBigMapDesiredWidthTiles)
		local source = map and (tonumber(map.SuperBigMapSourceWidthTiles)
			or tonumber(map.SuperBigMapGeneratorWidthTiles))
		local expanded_surface = mapdata and mapdata.Environment == "Surface"
			and desired and source and desired > source
		local deposits = SuperBigMap.DepositRules
		local has_staged = false
		if expanded_surface and deposits
			and type(deposits.HasStagedNativeEnrichmentRecords) == "function" then
			has_staged = deposits.HasStagedNativeEnrichmentRecords(map) == true
		end
		if has_staged then
			map.SuperBigMapBreakthroughInitializationDeferred = true
			map.SuperBigMapBreakthroughInitializationComplete = nil
			return
		end
		return original(self, ...)
	end
	city_class.InitBreakThroughAnomalies = wrapper
	State.breakthrough_init_wrapper = wrapper
	State.breakthrough_init_patch_version = GENERATOR_PATCH_VERSION
	return true
end

function SuperBigMap.FinalizeDeferredBreakthroughAnomalyInitialization(map, reason)
	-- The shipped initializer prunes from `table.shuffle(self:MapGet(...))`, so the survivor SET is a
	-- pure function of the ENUMERATION ORDER it receives. Replaying it after the stretch hands it the
	-- EXPANDED map's order over recreated markers, which differs from vanilla's by at least one
	-- transposition (measured at b2-04: one marker in, one out at 46/46). The native order was staged
	-- while the source was still alive (SuperBigMapStartStagedBreakthroughOrder, sbm_sector_exploration
	-- StageNativeBreakthroughOrder). Install it as an instance-field shadow on the city for the duration
	-- of the one shipped call - instance-field shadows reach the engine's Lua callers, rawset(_G, ...)
	-- does not - so the prune replays vanilla's decision instead of re-deriving it. The SET handed over
	-- stays exactly what the real query would return; only the ORDER is vanilla's.
	local function InstallStagedBreakthroughOrder(map, city)
		local stats = { staged = 0, live = 0, resolved = 0, missing = 0, extra = 0, applied = false }
		local function noop() end
		if (SuperBigMap.Config or {}).BREAKTHROUGH_STAGED_ORDER ~= true then return noop, stats end
		local order = rawget(map, "SuperBigMapStartStagedBreakthroughOrder")
		if type(order) ~= "table" or type(map.MapGet) ~= "function"
			or type(city.MapGet) ~= "function" then
			return noop, stats
		end
		stats.staged = #order
		local ok_live, live = pcall(map.MapGet, map, "map", "SubsurfaceAnomalyMarker",
			function(marker) return marker.tech_action == "breakthrough" end)
		if not (ok_live and type(live) == "table") then return noop, stats end
		stats.live = #live
		local index = {}
		for i = 1, #live do
			local marker = live[i]
			local sx = tonumber(rawget(marker, "SuperBigMapNativeSourceX"))
			local sy = tonumber(rawget(marker, "SuperBigMapNativeSourceY"))
			if sx and sy then
				local key = tostring(marker.class) .. ":" .. tostring(sx) .. ":" .. tostring(sy)
				if index[key] == nil then index[key] = marker end
			end
		end
		local ordered, taken = {}, {}
		for i = 1, #order do
			local record = order[i] or {}
			local key = tostring(record.class) .. ":" .. tostring(record.source_x)
				.. ":" .. tostring(record.source_y)
			local marker = index[key]
			if marker and not taken[marker] then
				taken[marker] = true
				ordered[#ordered + 1] = marker
				stats.resolved = stats.resolved + 1
			else
				stats.missing = stats.missing + 1
			end
		end
		for i = 1, #live do
			if not taken[live[i]] then
				ordered[#ordered + 1] = live[i]
				stats.extra = stats.extra + 1
			end
		end
		local real_map_get = city.MapGet
		local saved = rawget(city, "MapGet")
		local restored = false
		local function restore()
			if restored then return end
			restored = true
			rawset(city, "MapGet", saved)
		end
		rawset(city, "MapGet", function(self, ...)
			local area, class, filter = ...
			if area == "map" and class == "SubsurfaceAnomalyMarker" and type(filter) == "function" then
				-- One shot: the shipped method asks exactly once, at its first line.
				restore()
				local result = {}
				for i = 1, #ordered do
					local marker = ordered[i]
					local ok_filter, keep = pcall(filter, marker)
					if ok_filter and keep then result[#result + 1] = marker end
				end
				return result
			end
			return real_map_get(self, ...)
		end)
		stats.applied = true
		return restore, stats
	end

	if not map or map.SuperBigMapBreakthroughInitializationDeferred ~= true then
		return true, { deferred = false, before = 0, after = 0, removed = 0 }
	end
	local city = map.City
	local original = SuperBigMap.State.original_city_init_breakthrough_anomalies
	if not city or type(original) ~= "function" then
		return false, { error = "vanilla breakthrough initializer unavailable" }
	end
	local function count_breakthrough_markers()
		local count = 0
		if type(map.MapForEach) == "function" then
			pcall(map.MapForEach, map, "map", "SubsurfaceAnomalyMarker", function(marker)
				if marker and marker.tech_action == "breakthrough" then count = count + 1 end
			end)
		end
		return count
	end
	local before = count_breakthrough_markers()
	local restore_order, order_stats = InstallStagedBreakthroughOrder(map, city)
	local ok, init_error = pcall(original, city)
	restore_order()
	map.SuperBigMapBreakthroughStagedOrderCount = order_stats.staged
	map.SuperBigMapBreakthroughStagedOrderLive = order_stats.live
	map.SuperBigMapBreakthroughStagedOrderResolved = order_stats.resolved
	map.SuperBigMapBreakthroughStagedOrderMissing = order_stats.missing
	map.SuperBigMapBreakthroughStagedOrderExtra = order_stats.extra
	map.SuperBigMapBreakthroughStagedOrderApplied = order_stats.applied
	if not ok then
		return false, { error = tostring(init_error), before = before }
	end
	local after = count_breakthrough_markers()
	map.SuperBigMapBreakthroughInitializationDeferred = nil
	map.SuperBigMapBreakthroughInitializationComplete = true
	map.SuperBigMapBreakthroughMarkersBeforePruning = before
	map.SuperBigMapBreakthroughMarkersAfterPruning = after
	LoadingStep("deferred vanilla breakthrough initialization complete", {
		reason = tostring(reason), before = before, after = after,
		removed = math.max(0, before - after),
		staged_order = order_stats.applied and order_stats.staged or "off",
		staged_resolved = order_stats.resolved, staged_missing = order_stats.missing,
		staged_extra = order_stats.extra,
	}, map)
	return true, {
		deferred = true, before = before, after = after,
		removed = math.max(0, before - after),
	}
end

local function PatchRandomMapGenerator()
	-- This class hook is independent from the generator wrapper identity. Re-verify it before the
	-- version guard because ClassesBuilt can replace class methods without replacing the generator.
	SuperBigMap.PatchDeferredBreakthroughAnomalyInitialization()
	PatchDeferredUndergroundTunnelSpawn()
	PatchPersistentBuiltUndergroundPassageMarker()
	PatchAdditionalMapSeedReservation()
	if not cfg_bool("PATCH_RANDOM_MAP_GENERATOR", true) then
		return false
	end

	local generator_class = Global("RandomMapGenerator")
	if type(generator_class) ~= "table" or type(generator_class.Generate) ~= "function" then
		return false
	end

	local State = SuperBigMap.State
	-- Re-verify the wrappers are STILL on the class, not just the version.
	-- ClassesBuilt (mod reload / class rebuild) resets the methods to vanilla and
	-- re-calls us; a version-only guard would wrongly think we're still patched
	-- and never re-install, leaving vanilla DoGenerate -> GSRP overflow.
	if State.generator_patch_version == GENERATOR_PATCH_VERSION
		and generator_class.Generate == State.generator_generate_wrapper
		and generator_class.DoGenerate == State.generator_do_generate_wrapper
		and generator_class.OnGenerateLogic == State.generator_on_generate_logic_wrapper then
		return true
	end

	-- Capture the current (vanilla) methods as originals, but never capture our
	-- own wrapper (e.g. if only one of the two got reset).
	if generator_class.Generate ~= State.generator_generate_wrapper then
		State.generator_original_generate = generator_class.Generate
	end
	if generator_class.DoGenerate ~= State.generator_do_generate_wrapper then
		State.generator_original_do_generate = generator_class.DoGenerate
	end
	if generator_class.OnGenerateLogic ~= State.generator_on_generate_logic_wrapper then
		State.generator_original_on_generate_logic = generator_class.OnGenerateLogic
	end
	local original_generate = State.generator_original_generate
	local original_do_generate = State.generator_original_do_generate
	local original_on_generate_logic = State.generator_original_on_generate_logic
	local function call_original_do_generate(generator, map, ...)
		return SuperBigMap.CallDoGenerateWithRockParityTrace(
			original_do_generate, generator, map, ...)
	end

	-- OnGenerateLogic exposes the private buildable-grid transaction and underground
	-- artefact procedure needed by the supported stretch pipeline.
	if type(original_on_generate_logic) == "function" then
		local on_generate_logic_wrapper = function(self, env, ...)
			if type(env) ~= "table" then
				return original_on_generate_logic(self, env, ...)
			end
			local map = env.map
			local environment = type(map) == "table" and type(map.mapdata) == "table"
				and map.mapdata.Environment or nil
			-- Normal generations enter the original method unchanged.
			if State.rmg_placement_active_map ~= map then
				return CallOnGenerateLogicTimed(original_on_generate_logic, self, env, map, ...)
			end
			local is_underground = environment == "Underground"
			local defer_underground_artefacts = is_underground
				and cfg_bool("STRETCH_UNDERGROUND", false)
				and cfg_bool("DEFER_UNDERGROUND_EXPANSION_UNTIL_FIRST_ACCESS", false)
			local saved_get_playable_area = env.GetPlayableArea
			local saved_proc_invoke = env.ProcInvoke
			local proc_invoke_wrapper
			local debug_lib = Global("debug")
			local getfenv_fn = Global("getfenv")
			local function function_environment(fn)
				if type(fn) ~= "function" then return nil end
				-- The mod sandbox exposes Lua 5.1 function environments even when the
				-- debug upvalue API is stripped. This table is the authoritative global
				-- lookup environment used by the compiled RandomMapGenerator closure.
				if type(getfenv_fn) == "function" then
					local ok_env, value = pcall(getfenv_fn, fn)
					if ok_env and type(value) == "table" then return value end
				end
				if type(debug_lib) == "table" and type(debug_lib.getfenv) == "function" then
					local ok_env, value = pcall(debug_lib.getfenv, fn)
					if ok_env and type(value) == "table" then return value end
				end
				if type(debug_lib) == "table" and type(debug_lib.getupvalue) == "function" then
					for i = 1, 64 do
						local ok_up, name, value = pcall(debug_lib.getupvalue, fn, i)
						if not ok_up or name == nil then break end
						if name == "_ENV" and type(value) == "table" then
							return value
						end
					end
				end
				return nil
			end
			local generator_closure_env = function_environment(original_on_generate_logic)
			local function closure_global(name, fallback)
				if type(generator_closure_env) == "table" then
					local ok_value, value = pcall(function() return generator_closure_env[name] end)
					if ok_value and value ~= nil then return value end
				end
				return fallback
			end
			-- Use the same closure environment as stock OnGenerateLogic. The compiled game
			-- function owns a private _ENV, so _G may expose a different function identity.
			local closure_grid_dest = closure_global("GridDest", Global("GridDest"))
			local closure_grid_not = closure_global("GridNot", Global("GridNot"))
			local closure_new_grid = closure_global("NewGrid", Global("NewGrid"))
			local closure_new_compute_grid = closure_global("NewComputeGrid", Global("NewComputeGrid"))
			local closure_is_compute_grid = closure_global("IsComputeGrid", Global("IsComputeGrid"))
			local closure_grid_fill = closure_global("GridFill", Global("GridFill"))
			local closure_mask_buildable_grid =
				closure_global("MaskBuildableGrid", Global("MaskBuildableGrid"))
			local closure_build_unbuildable_z = closure_global("buildUnbuildableZ", Global("buildUnbuildableZ"))
			local closure_init_buildable_grid = closure_global("InitBuildableGrid", Global("InitBuildableGrid"))
			local closure_process_buildable_grid = closure_global("ProcessBuildableGrid", Global("ProcessBuildableGrid"))
			local closure_hex_to_world = closure_global("HexToWorld", Global("HexToWorld"))
			local closure_storage_to_hex = closure_global("StorageToHex", Global("StorageToHex"))
			local buildable_grid_class = closure_global("BuildableGrid", Global("BuildableGrid"))
			local saved_buildable_grid_build = type(buildable_grid_class) == "table"
				and buildable_grid_class.Build or nil
			local rebuild_buildable_grid_wrapper
			local rebuild_buildable_grid_installed = false
			local rebuild_buildable_grid_had_raw = false
			local rebuild_buildable_grid_raw
			local rebuild_buildable_grid_calls = 0
			-- Proc_ResolveBuildable rebuilds map.buildable at the source-sized view, but native
			-- MaskBuildableGrid derives its cell-to-world step from the real expanded Terrain
			-- backing. Lua-facing Map size overrides cannot change that native field. Recreate the
			-- vanilla transaction without approximating it: enlarge the temporary work mask by the
			-- exact expanded/source ratio, pad the source buildable grid to the real expanded hex
			-- dimensions, invoke native MaskBuildableGrid, then crop the source work rectangle.
			-- For every source cell, native now evaluates the same world coordinate, same hex, and
			-- same buildable value it would on a genuinely vanilla allocation. No expected count,
			-- checksum, seed, or compensating coordinate participates in the algorithm.
			-- SOURCE BUILDABLE RAW-GRID CAPACITY BRIDGE. BuildableGrid:Build is a two-stage vanilla
			-- transaction: InitBuildableGrid samples terrain/collision state into a raw hex grid,
			-- then ProcessBuildableGrid classifies connected areas. On an expanded allocation the
			-- native initializer can address the real expanded backing even while every logical map
			-- dimension exposes the vanilla source. A source-sized output silently changes native edge
			-- handling. Give the initializer full backing capacity WITHOUT changing the logical source
			-- view, crop the source rectangle, and run stock processing. Native code consequently owns
			-- PassBorder semantics; no Lua approximation of its hex-edge test is involved.
			-- Every dimension and threshold comes from the live map/vanilla globals; no expected cell
			-- count, checksum, seed, preset, or compensating coordinate participates in the result.
			-- Proc_ResolveBuildable performs a native mask call before GetPlayableArea. Retain the
			-- exact source-sized grid only for this synchronous generation transaction while the
			-- live BuildableGrid temporarily exposes a destination-sized, unbuildable-padded copy.
			local retained_source_buildable_grid
			local function rebuild_source_buildable_grid(target_map)
				if is_underground
					or target_map ~= map
					or not cfg_bool("EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE", false)
					or not cfg_bool("LIMIT_BUILDABLE_GRID_TO_SOURCE", true) then
					return nil, "mode-not-eligible"
				end
				local desired_w = tonumber(map.SuperBigMapDesiredWidthTiles)
				local desired_h = tonumber(map.SuperBigMapDesiredHeightTiles)
				local generator_w = tonumber(map.SuperBigMapGeneratorWidthTiles)
				local generator_h = tonumber(map.SuperBigMapGeneratorHeightTiles)
				if not desired_w or not desired_h or not generator_w or not generator_h
					or desired_w <= generator_w or desired_h <= generator_h then
					return nil, "map-not-expanded"
				end

				local source_world_w = tonumber(map.SuperBigMapGeneratorWidth)
					or tonumber(map.SuperBigMapSourceWidth)
				local source_world_h = tonumber(map.SuperBigMapGeneratorHeight)
					or tonumber(map.SuperBigMapSourceHeight)
				local expanded_world_w = tonumber(map.SuperBigMapExpandedWorldWidth)
				local expanded_world_h = tonumber(map.SuperBigMapExpandedWorldHeight)
				local expanded_hex_w = tonumber(map.SuperBigMapExpandedHexWidth)
				local expanded_hex_h = tonumber(map.SuperBigMapExpandedHexHeight)
				local source_hex_w = tonumber(map.hex_width)
				local source_hex_h = tonumber(map.hex_height)
				local source_x = tonumber(map.SuperBigMapSourceX) or 0
				local source_y = tonumber(map.SuperBigMapSourceY) or 0
				if source_x ~= 0 or source_y ~= 0 then
					return nil, "nonzero-source-origin-unsupported"
				end
				if not source_world_w or not source_world_h or not expanded_world_w or not expanded_world_h
					or not expanded_hex_w or not expanded_hex_h or not source_hex_w or not source_hex_h
					or source_world_w <= 0 or source_world_h <= 0
					or source_hex_w <= 0 or source_hex_h <= 0
					or expanded_world_w <= source_world_w or expanded_world_h <= source_world_h
					or expanded_hex_w < source_hex_w or expanded_hex_h < source_hex_h then
					return nil, "bridge-dimensions-unavailable"
				end
				if type(closure_new_grid) ~= "function"
					or type(closure_init_buildable_grid) ~= "function"
					or type(closure_process_buildable_grid) ~= "function"
					or type(closure_hex_to_world) ~= "function"
					or type(closure_storage_to_hex) ~= "function" then
					return nil, "required-api-unavailable"
				end

				local unbuildable_z = 2 ^ 16 - 1
				if type(closure_build_unbuildable_z) == "function" then
					local ok_z, value = pcall(closure_build_unbuildable_z)
					if ok_z and type(value) == "number" then unbuildable_z = value end
				end
				local build_map = map
				local map_data = map.mapdata
				if type(map_data) ~= "table" then return nil, "mapdata-unavailable" end
				local pass_border = tonumber(map_data.PassBorder) or 0
				local guim = tonumber(closure_global("guim", Global("guim"))) or 1000
				local range = map_data.visible_height_range
				local range_from, range_to
				pcall(function()
					range_from = range and tonumber(range.from)
					range_to = range and tonumber(range.to)
				end)
				local init_params = {
					unbuildable_z = unbuildable_z,
					flat_threshold = closure_global("g_NCF_FlatThreshold", Global("g_NCF_FlatThreshold")),
					max_surface_height = closure_global("g_NCF_MaxSurfaceHeight", Global("g_NCF_MaxSurfaceHeight")),
					max_surface_error = closure_global("g_NCF_MaxSurfaceError", Global("g_NCF_MaxSurfaceError")),
					surface_types = closure_global("g_NCF_SurfaceTypes", Global("g_NCF_SurfaceTypes")),
					enum_flags = closure_global("g_NCF_EnumFlags", Global("g_NCF_EnumFlags")),
					ignore_game_flags = closure_global("g_NCF_IgnoreGameFlags", Global("g_NCF_IgnoreGameFlags")),
					map_border = pass_border,
					map_min_height = range_from and range_from * guim or 0,
					map_max_height = range_to and range_to * guim or unbuildable_z,
				}
				local process_params = {
					unbuildable_z = unbuildable_z,
					minsize = closure_global("g_NCF_FlatThresholdAreaMin", Global("g_NCF_FlatThresholdAreaMin")),
					maxsize = closure_global("g_NCF_FlatThresholdAreaMax", Global("g_NCF_FlatThresholdAreaMax")),
					mindelta = closure_global("g_NCF_FlatThresholdAreaMinHeightDelta",
						Global("g_NCF_FlatThresholdAreaMinHeightDelta")),
					maxdelta = closure_global("g_NCF_FlatThresholdAreaMaxHeightDelta",
						Global("g_NCF_FlatThresholdAreaMaxHeightDelta")),
					minarea = closure_global("g_NCF_MinArea", Global("g_NCF_MinArea")),
				}
				local required_init_params = {
					"unbuildable_z", "flat_threshold", "max_surface_height", "max_surface_error",
					"surface_types", "enum_flags", "ignore_game_flags", "map_border",
					"map_min_height", "map_max_height",
				}
				for i = 1, #required_init_params do
					local name = required_init_params[i]
					if type(init_params[name]) ~= "number" then
						return nil, "init-parameter-unavailable:" .. tostring(name)
					end
				end
				local required_process_params = {
					"unbuildable_z", "minsize", "maxsize", "mindelta", "maxdelta", "minarea",
				}
				for i = 1, #required_process_params do
					local name = required_process_params[i]
					if type(process_params[name]) ~= "number" then
						return nil, "process-parameter-unavailable:" .. tostring(name)
					end
				end

				local buildable = map.buildable
				if not buildable then
					local buildable_class = closure_global("BuildableGrid", Global("BuildableGrid"))
					if type(buildable_class) == "table" and type(buildable_class.new) == "function" then
						local ok_new, value = pcall(buildable_class.new, buildable_class)
						if ok_new then buildable = value; map.buildable = value end
					end
				end
				if not buildable then return nil, "buildable-object-unavailable" end

				local capacity_raw, source_raw, source_processed
				local pause = Global("PauseInfiniteLoopDetection")
				local resume = Global("ResumeInfiniteLoopDetection")
				if type(pause) == "function" then pcall(pause, "SBMSourceBuildableRawGridBridge") end
				local bridge_ok, bridge_err = pcall(function()
					local capacity_hex_w = expanded_hex_w
					local capacity_hex_h = expanded_hex_h
					capacity_raw = closure_new_grid(capacity_hex_w, capacity_hex_h, 16, unbuildable_z)
					source_raw = closure_new_grid(source_hex_w, source_hex_h, 16, unbuildable_z)
					source_processed = closure_new_grid(source_hex_w, source_hex_h, 16, unbuildable_z)
					if not capacity_raw or not source_raw or not source_processed then
						error("grid-allocation-failed")
					end
					-- The entire point of this bridge is the asymmetric transaction below: native output
					-- capacity matches the real backing, but every logical dimension stays source-sized.
					-- Assert that contract before entering native code and never rewrite these fields.
					local build_map_data = build_map.mapdata or map_data
					local source_view_width, source_view_height = build_map.Width, build_map.Height
					local source_view_hex_width, source_view_hex_height = build_map.hex_width, build_map.hex_height
					local source_view_data_width, source_view_data_height =
						build_map_data.Width, build_map_data.Height
					local map_get_size = build_map.GetMapSize
					local terrain_api = closure_global("terrain", Global("terrain"))
					local terrain_get_size = type(terrain_api) == "table"
						and terrain_api.GetMapSize or nil
					local observed_map_w, observed_map_h, observed_terrain_w, observed_terrain_h
					if type(map_get_size) == "function" then
						local ok_size, width, height = pcall(map_get_size, build_map)
						if ok_size then observed_map_w, observed_map_h = width, height end
					end
					if type(terrain_get_size) == "function" then
						local ok_size, width, height = pcall(terrain_get_size, build_map)
						if ok_size then observed_terrain_w, observed_terrain_h = width, height end
					end
					local source_view_exact = source_view_width == source_world_w
						and source_view_height == source_world_h
						and source_view_hex_width == source_hex_w
						and source_view_hex_height == source_hex_h
						and source_view_data_width == generator_w
						and source_view_data_height == generator_h
						and observed_map_w == source_world_w and observed_map_h == source_world_h
						and observed_terrain_w == source_world_w and observed_terrain_h == source_world_h
					if not source_view_exact then error("logical-source-view-not-exact") end

					init_params.buildable_grid = capacity_raw
					closure_init_buildable_grid(build_map, init_params)
					for y = 0, source_hex_h - 1 do
						for x = 0, source_hex_w - 1 do
							source_raw:set(x, y, capacity_raw:get(x, y))
						end
					end
					process_params.buildable_grid = source_raw
					process_params.buildable_z = source_processed
					closure_process_buildable_grid(process_params)

					buildable.z_grid = source_processed
					source_processed = nil -- ownership transferred to the live BuildableGrid
				end)
				if type(resume) == "function" then pcall(resume, "SBMSourceBuildableRawGridBridge") end
				if capacity_raw then pcall(function() capacity_raw:free() end) end
				if source_raw then pcall(function() source_raw:free() end) end
				if source_processed then pcall(function() source_processed:free() end) end
				if not bridge_ok then
					return nil, "source-buildable-bridge-failed:" .. tostring(bridge_err)
				end
				return true, nil
			end

			local function rebuild_source_invalid_mask(incoming_mask)
				if not cfg_bool("EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE", false)
					or not cfg_bool("LIMIT_GENERATOR_TO_SOURCE", true) then
					return nil, "mode-not-eligible"
				end
				local desired_w = tonumber(map and map.SuperBigMapDesiredWidthTiles)
				local desired_h = tonumber(map and map.SuperBigMapDesiredHeightTiles)
				local generator_w = tonumber(map and map.SuperBigMapGeneratorWidthTiles)
				local generator_h = tonumber(map and map.SuperBigMapGeneratorHeightTiles)
				if not desired_w or not desired_h or not generator_w or not generator_h
					or desired_w <= generator_w or desired_h <= generator_h then
					return nil, "map-not-expanded"
				end
				local gen_zone = env.gen_zone
				local buildable = map and map.buildable
				local stock_z_grid = buildable and buildable.z_grid
				local z_grid = retained_source_buildable_grid or stock_z_grid
				if not gen_zone or not incoming_mask or not buildable or not z_grid
					or type(z_grid.get) ~= "function" or type(z_grid.set) ~= "function"
					or type(closure_new_grid) ~= "function"
					or type(closure_new_compute_grid) ~= "function"
					or type(closure_is_compute_grid) ~= "function"
					or type(closure_grid_fill) ~= "function"
					or type(closure_mask_buildable_grid) ~= "function"
					or type(closure_grid_dest) ~= "function"
					or type(closure_grid_not) ~= "function"
					then
					return nil, "required-api-unavailable"
				end

				local ok_gen, grid_w, grid_h = pcall(gen_zone.size, gen_zone)
				grid_h = grid_h or grid_w
				local ok_mask, mask_w, mask_h = pcall(incoming_mask.size, incoming_mask)
				mask_h = mask_h or mask_w
				local ok_build, build_w, build_h = pcall(z_grid.size, z_grid)
				build_h = build_h or build_w
				if not ok_gen or not ok_mask or not ok_build
					or type(grid_w) ~= "number" or type(grid_h) ~= "number"
					or grid_w <= 0 or grid_h <= 0 or mask_w ~= grid_w or mask_h ~= grid_h then
					return nil, "grid-size-mismatch"
				end
				if type(map.hex_width) == "number" and type(map.hex_height) == "number"
					and (build_w ~= map.hex_width or build_h ~= map.hex_height) then
					return nil, "buildable-not-source-sized"
				end
				local source_x = tonumber(map.SuperBigMapSourceX) or 0
				local source_y = tonumber(map.SuperBigMapSourceY) or 0
				if source_x ~= 0 or source_y ~= 0 then
					return nil, "nonzero-source-origin-unsupported"
				end
				local source_world_w = tonumber(map.SuperBigMapGeneratorWidth)
					or tonumber(map.SuperBigMapSourceWidth)
				local source_world_h = tonumber(map.SuperBigMapGeneratorHeight)
					or tonumber(map.SuperBigMapSourceHeight)
				local expanded_world_w = tonumber(map.SuperBigMapExpandedWorldWidth)
				local expanded_world_h = tonumber(map.SuperBigMapExpandedWorldHeight)
				local expanded_hex_w = tonumber(map.SuperBigMapExpandedHexWidth)
				local expanded_hex_h = tonumber(map.SuperBigMapExpandedHexHeight)
				if not source_world_w or not source_world_h or not expanded_world_w or not expanded_world_h
					or not expanded_hex_w or not expanded_hex_h
					or source_world_w <= 0 or source_world_h <= 0
					or expanded_world_w <= source_world_w or expanded_world_h <= source_world_h
					or expanded_hex_w < build_w or expanded_hex_h < build_h then
					return nil, "bridge-dimensions-unavailable"
				end
				local virtual_w_numerator = grid_w * expanded_world_w
				local virtual_h_numerator = grid_h * expanded_world_h
				if virtual_w_numerator % source_world_w ~= 0
					or virtual_h_numerator % source_world_h ~= 0 then
					return nil, "nonintegral-work-grid-ratio"
				end
				local virtual_w = virtual_w_numerator / source_world_w
				local virtual_h = virtual_h_numerator / source_world_h
				if virtual_w < grid_w or virtual_h < grid_h then
					return nil, "invalid-virtual-work-grid"
				end
				local ok_compute, mask_format, mask_bits = pcall(closure_is_compute_grid, gen_zone)
				if not ok_compute or string.upper(tostring(mask_format)) ~= "U" or mask_bits ~= 16 then
					return nil, "source-mask-compute-format-unexpected:"
						.. tostring(mask_format) .. ":" .. tostring(mask_bits)
				end

				local unbuildable_z = 2 ^ 16 - 1
				if type(closure_build_unbuildable_z) == "function" then
					local ok_z, value = pcall(closure_build_unbuildable_z)
					if ok_z and type(value) == "number" then unbuildable_z = value end
				end
				local ok_create, repaired = pcall(closure_grid_dest, gen_zone)
				if not ok_create or not repaired then
					return nil, "GridDest-failed:" .. tostring(repaired)
				end
				local ok_not, not_err = pcall(closure_grid_not, gen_zone, repaired)
				if not ok_not then
					pcall(function() repaired:free() end)
					return nil, "GridNot-failed:" .. tostring(not_err)
				end

				local ok_virtual_mask, virtual_mask_or_err = pcall(
					closure_new_compute_grid, virtual_w, virtual_h, mask_format, mask_bits)
				local virtual_mask = ok_virtual_mask and virtual_mask_or_err or nil
				local ok_virtual_z, virtual_z_or_err = pcall(
					closure_new_grid, expanded_hex_w, expanded_hex_h, 16, unbuildable_z)
				local virtual_z = ok_virtual_z and virtual_z_or_err or nil
				if not virtual_mask or not virtual_z then
					pcall(function() repaired:free() end)
					if virtual_mask then pcall(function() virtual_mask:free() end) end
					if virtual_z then pcall(function() virtual_z:free() end) end
					return nil, "virtual-grid-create-failed:mask=" .. tostring(virtual_mask_or_err)
						.. ";z=" .. tostring(virtual_z_or_err)
				end
				local ok_fill, fill_err = pcall(closure_grid_fill, virtual_mask, 1)
				if not ok_fill then
					pcall(function() repaired:free() end)
					pcall(function() virtual_mask:free() end)
					pcall(function() virtual_z:free() end)
					return nil, "virtual-mask-fill-failed:" .. tostring(fill_err)
				end

				local pause = Global("PauseInfiniteLoopDetection")
				local resume = Global("ResumeInfiniteLoopDetection")
				if type(pause) == "function" then pcall(pause, "SBMSourceBuildableMaskNativeBridge") end
				local ok_bridge, bridge_err = pcall(function()
					-- The virtual grids are initialized invalid/unbuildable. Copy only the source
					-- rectangles; their padding represents terrain outside the source view.
					for y = 0, grid_h - 1 do
						for x = 0, grid_w - 1 do
							virtual_mask:set(x, y, repaired:get(x, y))
						end
					end
					for y = 0, build_h - 1 do
						for x = 0, build_w - 1 do
							virtual_z:set(x, y, z_grid:get(x, y))
						end
					end
					closure_mask_buildable_grid(map, virtual_z, virtual_mask, unbuildable_z)
					for y = 0, grid_h - 1 do
						for x = 0, grid_w - 1 do
							repaired:set(x, y, virtual_mask:get(x, y))
						end
					end
				end)
				if virtual_mask then pcall(function() virtual_mask:free() end) end
				if virtual_z then pcall(function() virtual_z:free() end) end
				if type(resume) == "function" then pcall(resume, "SBMSourceBuildableMaskNativeBridge") end
				if not ok_bridge then
					pcall(function() repaired:free() end)
					return nil, "native-bridge-failed:" .. tostring(bridge_err)
				end
				return repaired, nil
			end

			-- Proc_ResolveBuildable calls this once to turn gen_zone into the actual placement
			-- play_zone. Capture its exact native area ratio before any resource/anomaly layer
			-- starts destructively eroding that zone.
			if type(saved_get_playable_area) == "function" then
				env.GetPlayableArea = function(...)
					local args = PackValues(...)
					local repaired_mask, repair_reason = rebuild_source_invalid_mask(args[3])
					if repaired_mask then
						args[3] = repaired_mask
					elseif retained_source_buildable_grid then
						error("source playable-mask repair failed: " .. tostring(repair_reason))
					end
					local results
					local ok_playable, playable_err = pcall(function()
						results = PackValues(saved_get_playable_area(Unpack(args, 1, args.n)))
					end)
					if repaired_mask then pcall(function() repaired_mask:free() end) end
					if not ok_playable then error(playable_err) end
					return Unpack(results, 1, results.n)
				end
			end

			-- Keep the two passage anchors eager while deferring underground wonders.
			if type(saved_proc_invoke) == "function" and defer_underground_artefacts then
				proc_invoke_wrapper = function(tag, func, randless)
					if tag == "PlaceArtefacts" then
						return saved_proc_invoke(tag, function()
							local bootstrap_token = LoadingBegin(
								"deferred underground passage bootstrap", map)
							local bootstrap_results = PackValues(pcall(
								BootstrapPassagesAndDeferWonders, env))
							-- Safety net for the retained native backing: the bootstrap's own
							-- restore path releases it, but an early "not ready" return or an
							-- error before the bridge is installed never reaches that path, and a
							-- temporary map must not outlive this procedure.
							ReleaseRetainedNativeSourceMap(Global("MainMap"),
								"passage bootstrap returned")
							local bootstrap_ok = bootstrap_results[1] == true
								and bootstrap_results[2] == true
							local details = bootstrap_results[3]
							LoadingEnd(bootstrap_token, type(details) == "table" and details or {
								reason = tostring(details),
							}, bootstrap_results[1] == true)
							if not bootstrap_results[1] then error(bootstrap_results[2]) end
							if bootstrap_ok ~= true then
								local stock_results = PackValues(func())
								local stock_passages = ArtefactMapGet(map, "SurfacePassage")
								local plan_ok, plan_stats = AlignPassagePairsToSharedHex(map,
									{ source_bootstrap = true })
								if plan_ok ~= true then
									error("stock PlaceArtefacts passage planning failed after "
										.. tostring(details) .. ": "
										.. tostring(plan_stats and plan_stats.error or "unknown error"))
								end
								if not VerifyBootstrapPassages(map, stock_passages, 2) then
									error("stock PlaceArtefacts did not create two valid linked Elevator anchors after "
										.. tostring(details))
								end
								map.SuperBigMapPassageBootstrapComplete = true
								map.SuperBigMapPassageBootstrapCount = #stock_passages
								return Unpack(stock_results, 1, stock_results.n)
							end
							return details
						end, randless)
					end
					if tag == "PlaceObstructions" then
						return saved_proc_invoke(tag, function()
							local obstruction_results
							local obstruction_ok, obstruction_error = pcall(function()
								obstruction_results = PackValues(func())
							end)
							local cleanup_ok, cleanup_result =
								SuperBigMap.CleanupPendingNativeWonders(
									map, "after stock PlaceObstructions")
							if cleanup_ok ~= true then error(cleanup_result) end
							if not obstruction_ok then error(obstruction_error) end
							return Unpack(obstruction_results, 1, obstruction_results.n)
						end, randless)
					end
					return saved_proc_invoke(tag, func, randless)
				end
				env.ProcInvoke = proc_invoke_wrapper
			end

			-- Stock Proc_ResolveBuildable calls private RebuildBuildableGrid, which then dynamically
			-- dispatches map.buildable:Build. Retail builds expose no getfenv/debug API, so the private
			-- global lookup cannot be replaced reliably. Intercept the public BuildableGrid method one
			-- call lower instead. The hook is scoped to this synchronous OnGenerateLogic transaction and
			-- restored immediately afterward, including errors.
			local desired_w = tonumber(map and map.SuperBigMapDesiredWidthTiles)
			local desired_h = tonumber(map and map.SuperBigMapDesiredHeightTiles)
			local generator_w = tonumber(map and map.SuperBigMapGeneratorWidthTiles)
			local generator_h = tonumber(map and map.SuperBigMapGeneratorHeightTiles)
			local rebuild_buildable_grid_required =
				cfg_bool("EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE", false)
				and cfg_bool("LIMIT_BUILDABLE_GRID_TO_SOURCE", true)
				and desired_w and desired_h and generator_w and generator_h
				and desired_w > generator_w and desired_h > generator_h
			rebuild_buildable_grid_wrapper = function(buildable, target_map, width, height, map_data, ...)
				rebuild_buildable_grid_calls = rebuild_buildable_grid_calls + 1
				-- Surface generation now normally runs on a true vanilla-sized temporary map.
				-- Deferred underground generation still runs once on the final expanded backing,
				-- while its Lua-visible fields present the vanilla source extent. The stock
				-- ResolveBuildable sequence builds a source-sized z-grid and immediately passes it
				-- to native MaskBuildableGrid. Native code addresses the real backing extent, not
				-- the Lua view, so that mixed 615x710 / 820x946 transaction can read out of bounds.
				--
				-- Keep the exact source grid for the authoritative GetPlayableArea mask repair,
				-- but give the unavoidable stock mask call a backing-sized grid padded with
				-- UnbuildableZ. This changes no source value and adds no playable cell.
				if is_underground and target_map == map then
					if type(saved_buildable_grid_build) ~= "function"
						or type(closure_new_grid) ~= "function" then
						error("underground stock-mask safety APIs unavailable")
					end
					if retained_source_buildable_grid then
						error("underground source buildable grid already retained")
					end
					saved_buildable_grid_build(buildable, target_map, width, height, map_data, ...)
					local source_grid = buildable and buildable.z_grid
					local source_w, source_h
					if source_grid and type(source_grid.size) == "function" then
						local ok_size, grid_w, grid_h = pcall(source_grid.size, source_grid)
						if ok_size then source_w, source_h = grid_w, grid_h or grid_w end
					end
					local expected_source_w = tonumber(map.hex_width)
					local expected_source_h = tonumber(map.hex_height)
					local expanded_w = tonumber(map.SuperBigMapExpandedHexWidth)
					local expanded_h = tonumber(map.SuperBigMapExpandedHexHeight)
					local dimensions_valid = source_grid ~= nil
						and type(source_w) == "number" and type(source_h) == "number"
						and source_w == expected_source_w and source_h == expected_source_h
						and type(expanded_w) == "number" and type(expanded_h) == "number"
						and expanded_w >= source_w and expanded_h >= source_h
						and (expanded_w > source_w or expanded_h > source_h)
					if not dimensions_valid then
						error("underground stock-mask dimension invariant failed")
					end
					local unbuildable_z = 2 ^ 16 - 1
					if type(closure_build_unbuildable_z) == "function" then
						local ok_z, value = pcall(closure_build_unbuildable_z)
						if ok_z and type(value) == "number" then unbuildable_z = value end
					end
					local padded = closure_new_grid(expanded_w, expanded_h, 16, unbuildable_z)
					if not padded or type(padded.set) ~= "function" or type(source_grid.get) ~= "function" then
						if padded then pcall(function() padded:free() end) end
						error("underground stock-mask safety grid allocation failed")
					end
					for y = 0, source_h - 1 do
						for x = 0, source_w - 1 do
							padded:set(x, y, source_grid:get(x, y))
						end
					end
					retained_source_buildable_grid = source_grid
					buildable.z_grid = padded
					return
				end
				local bridge_ok, bridge_reason = rebuild_source_buildable_grid(target_map)
				if bridge_ok then
					return
				end
				if bridge_reason == "mode-not-eligible" or bridge_reason == "map-not-expanded" then
					if type(saved_buildable_grid_build) == "function" then
						return saved_buildable_grid_build(buildable, target_map,
							width, height, map_data, ...)
					end
				end
				local failure = "source buildable raw-grid bridge failed before vanilla mask/playable "
					.. "resolution: " .. tostring(bridge_reason)
				error(failure)
			end

			if rebuild_buildable_grid_required and type(buildable_grid_class) == "table"
				and type(saved_buildable_grid_build) == "function" then
				rebuild_buildable_grid_raw = rawget(buildable_grid_class, "Build")
				rebuild_buildable_grid_had_raw = rebuild_buildable_grid_raw ~= nil
				local ok_install = pcall(rawset, buildable_grid_class,
					"Build", rebuild_buildable_grid_wrapper)
				rebuild_buildable_grid_installed = ok_install
					and rawget(buildable_grid_class, "Build") == rebuild_buildable_grid_wrapper
			end
			-- Publish the transaction's ownership of BuildableGrid.Build so a map-slot change made
			-- inside this window (the retained native backing is unloaded here) cannot make the
			-- ChangingMap hook reinstall wrap this temporary closure permanently.
			State.buildable_grid_generation_hook =
				rebuild_buildable_grid_installed and rebuild_buildable_grid_wrapper or nil

			local results
			if rebuild_buildable_grid_required and not rebuild_buildable_grid_installed then
				results = { false, "source buildable raw-grid bridge hook unavailable" }
			else
				results = { pcall(CallOnGenerateLogicTimed,
					original_on_generate_logic, self, env, map, ...) }
			end

			if retained_source_buildable_grid then
				local retained = retained_source_buildable_grid
				retained_source_buildable_grid = nil
				local ok_free, free_error = pcall(function() retained:free() end)
				if not ok_free and results[1] then
					results = { false, "native source buildable cleanup failed: " .. tostring(free_error) }
				end
			end

			local rebuild_restore_ok = true
			local rebuild_restore_reason = "not-installed"
			State.buildable_grid_generation_hook = nil
			if rebuild_buildable_grid_installed and type(buildable_grid_class) == "table" then
				local current = rawget(buildable_grid_class, "Build")
				if current == rebuild_buildable_grid_wrapper then
					local ok_restore = pcall(rawset, buildable_grid_class, "Build",
						rebuild_buildable_grid_had_raw and rebuild_buildable_grid_raw or nil)
					rebuild_restore_ok = ok_restore and rawget(buildable_grid_class,
						"Build") == (rebuild_buildable_grid_had_raw
						and rebuild_buildable_grid_raw or nil)
					rebuild_restore_reason = rebuild_restore_ok and "restored" or "restore-write-failed"
				else
					rebuild_restore_ok = false
					rebuild_restore_reason = "hook-replaced-during-generation:" .. tostring(current)
				end
			end
			if not rebuild_restore_ok and results[1] then
				results = { false, "source buildable raw-grid bridge cleanup failed: "
					.. tostring(rebuild_restore_reason) }
			elseif rebuild_buildable_grid_required and results[1]
				and rebuild_buildable_grid_calls == 0 then
				results = { false, "source buildable raw-grid bridge was installed but never called" }
			end
			if proc_invoke_wrapper and env.ProcInvoke == proc_invoke_wrapper then
				env.ProcInvoke = saved_proc_invoke
			end
			if type(map.SuperBigMapPendingNativeWonderCleanup) == "table" then
				local cleanup_ok, cleanup_result = SuperBigMap.CleanupPendingNativeWonders(
					map, "generator-exit fail-closed fallback")
				if results[1] then
					results = { false, "temporary native wonders missed the PlaceObstructions cleanup boundary" }
				elseif cleanup_ok ~= true then
					results[2] = tostring(results[2]) .. "; cleanup failed: " .. tostring(cleanup_result)
				end
			end
			if env.GetPlayableArea ~= saved_get_playable_area then
				env.GetPlayableArea = saved_get_playable_area
			end
			if not results[1] then error(results[2]) end
			return Unpack(results, 2)
		end
		generator_class.OnGenerateLogic = on_generate_logic_wrapper
		State.generator_on_generate_logic_wrapper = on_generate_logic_wrapper
	end

	local generate_wrapper = function(self, params)
		params = type(params) == "table" and params or {}
		local blank_map = self and self.BlankMap
		local map_name = params.map_name or blank_map
		if blank_map and blank_map ~= "" then
			local map_data_table = Global("MapData")
			local mapdata = type(map_data_table) == "table" and map_data_table[blank_map] or nil
			local instance = {
				mapdata = mapdata,
				RandomMapGenObject = self,
			}
			PrepareMapDataForExpansion(params.map_slot or 1, map_name, instance, "RandomMapGenerator.Generate")
			if instance.SuperBigMapExpansionPending ~= true then
				-- EXPAND MAP is off (or the map is ineligible). Leave vanilla generation untouched.
				return original_generate(self, params)
			end
			-- ChangeMapInSlot constructs Map directly from this table.  Carry the complete source /
			-- destination geometry so DoGenerate never depends on NewMapObject attaching a second,
			-- name-keyed copy at exactly the right time.
			params.mapdata = params.mapdata or instance.mapdata
			params.RandomMapGenObject = params.RandomMapGenObject or self
			params.SuperBigMapExpansionPending = instance.SuperBigMapExpansionPending
			params.SuperBigMapGenerationReadinessVersion =
				SuperBigMap.GenerationReadiness.VERSION
			for _, field in ipairs({
				"SuperBigMapSourceWidth", "SuperBigMapSourceHeight",
				"SuperBigMapSourceX", "SuperBigMapSourceY",
				"SuperBigMapOriginalWidthTiles", "SuperBigMapOriginalHeightTiles",
				"SuperBigMapSourceWidthTiles", "SuperBigMapSourceHeightTiles",
				"SuperBigMapDesiredWidthTiles", "SuperBigMapDesiredHeightTiles",
				"SuperBigMapGeneratorWidth", "SuperBigMapGeneratorHeight",
				"SuperBigMapGeneratorWidthTiles", "SuperBigMapGeneratorHeightTiles",
			}) do
				params[field] = instance[field]
			end
		end
		return original_generate(self, params)
	end
	generator_class.Generate = generate_wrapper
	State.generator_generate_wrapper = generate_wrapper

	if type(original_do_generate) == "function" then
		local do_generate_closure_env = FunctionEnvironment(original_do_generate)
		local function do_generate_closure_global(name, fallback)
			if type(do_generate_closure_env) == "table" then
				local ok_value, value = pcall(function() return do_generate_closure_env[name] end)
				if ok_value and value ~= nil then return value end
			end
			return fallback
		end
		local do_generate_wrapper = function(self, map, ...)
			local mapdata = map and map.mapdata
			local expansion_transaction = map and (
				map.SuperBigMapExpansionPending == true
					or map.SuperBigMapVanillaSourceMigration == true
				or map.SuperBigMapDesiredWidthTiles ~= nil)
				or type(mapdata) == "table" and (
					mapdata.SuperBigMapOriginalWidthTiles ~= nil
					or mapdata.SuperBigMapSourceWidthTiles ~= nil)
				or State.vanilla_source_migration_active == true
			if not expansion_transaction then
			-- Exact vanilla fast path: no temporary-source migration or expansion behavior.
				return call_original_do_generate(self, map, ...)
			end
			if map and map.SuperBigMapVanillaSourceMigration ~= true then
				-- Persisted provenance distinguishes freshly generated strict-correspondence maps
				-- from older saves whose underground was intentionally left deferred.
				map.SuperBigMapOneToOneGenerationVersion = 1
			end
			if not cfg_bool("LIMIT_GENERATOR_TO_SOURCE", true) then
				return call_original_do_generate(self, map, ...)
			end
			local loading_diagnostics = SuperBigMap.Diagnostics
			local loading_session_already_active = loading_diagnostics
				and type(loading_diagnostics.LoadingActive) == "function"
				and loading_diagnostics.LoadingActive() == true
			LoadingStart("RandomMapGenerator.DoGenerate", map, {
				environment = tostring(mapdata and mapdata.Environment),
				vanilla_source_migration = tostring(map and map.SuperBigMapVanillaSourceMigration == true),
				expansion_pending = tostring(map and map.SuperBigMapExpansionPending == true),
			})

			local height_tile_size = (Global("const") and type(const.HeightTileSize) == "number" and const.HeightTileSize > 0)
				and const.HeightTileSize or 1
			local max_random_tiles = math.floor(cfg_number("MAX_RANDOM_GENERATOR_TILES", 6144, 1))

			-- The vanilla generator sizes its working grids from the map's tile
			-- count and asserts (GridStableRandomPosSimple: size < GSRP_MAX_SIZE)
			-- once that exceeds the vanilla maximum. It reads the size from
			-- map:GetMapSize(), terrain.GetMapSize(map) AND
			-- RandomMapGenerator:GetMapSize() (= MapData[self.BlankMap].Width), and
			-- the working grids can also key off map.mapdata.Width. So we DETECT
			-- the real map size from every one of those sources and, if any exceeds
			-- the random-generator max, cap them ALL for the duration of the
			-- generate. (Earlier this keyed only off MapData[BlankMap], which some
			-- maps -- e.g. landing-spot previews -- don't have set, so the cap was
			-- skipped and the grid overflowed.)
			local map_data_table = Global("MapData")
			local blank = self and self.BlankMap
			local template = type(map_data_table) == "table" and type(blank) == "string" and map_data_table[blank] or nil
			mapdata = map and map.mapdata
			local terrain_api = Global("terrain")
			local original_map_get_size = map and map.GetMapSize
			local original_terrain_get_size = terrain_api and terrain_api.GetMapSize

			local function world_to_tiles(w)
				return (type(w) == "number" and w > 0) and math.floor(w / height_tile_size + 0.5) or 0
			end
			local cur_w_tiles, cur_h_tiles = 0, 0
			if type(original_map_get_size) == "function" then
				local ok, ww, hh = pcall(original_map_get_size, map)
				if ok then
					cur_w_tiles = math.max(cur_w_tiles, world_to_tiles(ww))
					cur_h_tiles = math.max(cur_h_tiles, world_to_tiles(hh))
				end
			end
			if type(mapdata) == "table" then
				if type(mapdata.Width) == "number" then cur_w_tiles = math.max(cur_w_tiles, mapdata.Width) end
				if type(mapdata.Height) == "number" then cur_h_tiles = math.max(cur_h_tiles, mapdata.Height) end
			end
			if template then
				if type(template.Width) == "number" then cur_w_tiles = math.max(cur_w_tiles, template.Width) end
				if type(template.Height) == "number" then cur_h_tiles = math.max(cur_h_tiles, template.Height) end
			end

			-- Maps that already fit the native generator remain otherwise untouched.
			if cur_w_tiles <= max_random_tiles and cur_h_tiles <= max_random_tiles then
				local native_token = LoadingBegin("native-sized RandomMapGenerator.DoGenerate", map, {
					map_tiles = tostring(cur_w_tiles) .. "x" .. tostring(cur_h_tiles),
				})
				local results = PackValues(call_original_do_generate(self, map, ...))
				LoadingEnd(native_token, nil, true)
				CaptureGeneratedNativeEnrichments(map, "DoGenerate native complete")
				if loading_session_already_active then
					LoadingStep("nested native-sized map generation complete", {
						map_tiles = tostring(cur_w_tiles) .. "x" .. tostring(cur_h_tiles),
					}, map)
				else
					LoadingFinish("native-sized map generation complete", map, {
						map_tiles = tostring(cur_w_tiles) .. "x" .. tostring(cur_h_tiles),
					}, true)
				end
				return Unpack(results, 1, results.n)
			end

			-- Exact-source path: keep this already allocated expanded map as the destination, but
			-- execute the generator body once on a separate native-sized backing. The helper copies
			-- terrain, transfers the generated objects, rebuilds only the final destination grids,
			-- unloads the temporary slot, and returns the original DoGenerate result tuple.
			LoadingStep("attempt exact temporary-source transaction", {
				map_tiles = tostring(cur_w_tiles) .. "x" .. tostring(cur_h_tiles),
				generator_limit_tiles = max_random_tiles,
			}, map)
			local migrated, migrated_results = GenerateOnTemporaryVanillaBacking(
				self, map, call_original_do_generate, ...)
			if migrated then
				return Unpack(migrated_results, 1, migrated_results.n)
			end

			local backing_environment = (type(mapdata) == "table" and mapdata.Environment)
				or (type(template) == "table" and template.Environment)
			if backing_environment ~= "Underground" then
				error("expanded surface generation requires the exact temporary vanilla backing transaction: "
					.. tostring(migrated_results))
			end

			-- Underground generation cannot use the temporary surface migration transaction:
			-- it must create and pair passage anchors against the live expanded surface. Present
			-- the expanded underground backing through an exact source-sized generator view, run
			-- vanilla once, then restore the real expanded dimensions before deferred stretching.
			-- Cap to the per-map generator markers if present, else the max.
			local gen_width_tiles = (type(map.SuperBigMapGeneratorWidthTiles) == "number" and map.SuperBigMapGeneratorWidthTiles > 0)
				and map.SuperBigMapGeneratorWidthTiles or max_random_tiles
			local gen_height_tiles = (type(map.SuperBigMapGeneratorHeightTiles) == "number" and map.SuperBigMapGeneratorHeightTiles > 0)
				and map.SuperBigMapGeneratorHeightTiles or max_random_tiles
			gen_width_tiles = math.max(1, math.min(gen_width_tiles, max_random_tiles))
			gen_height_tiles = math.max(1, math.min(gen_height_tiles, max_random_tiles))

			local gen_world_w = (type(map.SuperBigMapGeneratorWidth) == "number" and map.SuperBigMapGeneratorWidth > 0)
				and map.SuperBigMapGeneratorWidth or (gen_width_tiles * height_tile_size)
			local gen_world_h = (type(map.SuperBigMapGeneratorHeight) == "number" and map.SuperBigMapGeneratorHeight > 0)
				and map.SuperBigMapGeneratorHeight or (gen_height_tiles * height_tile_size)

			local saved_template_w = template and template.Width
			local saved_template_h = template and template.Height
			local saved_mapdata_w = type(mapdata) == "table" and mapdata.Width or nil
			local saved_mapdata_h = type(mapdata) == "table" and mapdata.Height or nil
			local saved_map_width = map and map.Width
			local saved_map_height = map and map.Height
			local saved_map_hex_width = map and map.hex_width
			local saved_map_hex_height = map and map.hex_height
			local buildable_source_view = false

			map.GetMapSize = function(target)
				if target == map then
					return gen_world_w, gen_world_h
				end
				if type(original_map_get_size) == "function" then
					return original_map_get_size(target)
				end
				return gen_world_w, gen_world_h
			end
			if terrain_api and type(original_terrain_get_size) == "function" then
				terrain_api.GetMapSize = function(target)
					if target == map or (target == nil and Global("CurrentMap") == map) then
						return gen_world_w, gen_world_h
					end
					return original_terrain_get_size(target)
				end
			end
			if template then
				template.Width = gen_width_tiles
				template.Height = gen_height_tiles
			end
			if type(mapdata) == "table" then
				mapdata.Width = gen_width_tiles
				mapdata.Height = gen_height_tiles
			end

			-- ATOMIC SOURCE-SIZED MAP/BUILDABLE VIEW. Vanilla RebuildBuildableGrid does not consult
			-- map:GetMapSize, terrain.GetMapSize, or MapData.Width when choosing its grid
			-- dimensions; it directly passes map.hex_width/map.hex_height into BuildableGrid:Build.
			-- MaskBuildableGrid then consumes the Map object natively and can still project that grid
			-- through the cached map.Width/map.Height MapVars, which were initialized from the expanded
			-- allocation. Present all four cached extents as one vanilla-sized transaction (8192 ->
			-- 6144 gives world 819200 -> 614400 and hex 820x946 -> 615x710), restore all four
			-- immediately afterward even when native generation fails, and only then rebuild the real
			-- expanded gameplay grid.
			if cfg_bool("LIMIT_BUILDABLE_GRID_TO_SOURCE", true)
				and type(saved_map_width) == "number" and saved_map_width > 0
				and type(saved_map_height) == "number" and saved_map_height > 0
				and type(saved_map_hex_width) == "number" and saved_map_hex_width > 0
				and type(saved_map_hex_height) == "number" and saved_map_hex_height > 0
				and cur_w_tiles > 0 and cur_h_tiles > 0 then
				local source_hex_width = math.max(1,
					math.floor((saved_map_hex_width * gen_width_tiles + 0.0) / cur_w_tiles + 0.5))
				local source_hex_height = math.max(1,
					math.floor((saved_map_hex_height * gen_height_tiles + 0.0) / cur_h_tiles + 0.5))
				local source_fits_expanded = gen_world_w <= saved_map_width and gen_world_h <= saved_map_height
					and source_hex_width <= saved_map_hex_width and source_hex_height <= saved_map_hex_height
				local source_is_smaller = gen_world_w < saved_map_width or gen_world_h < saved_map_height
					or source_hex_width < saved_map_hex_width or source_hex_height < saved_map_hex_height
				if source_fits_expanded and source_is_smaller then
					buildable_source_view = {
						source_world_width = gen_world_w, source_world_height = gen_world_h,
						expanded_world_width = saved_map_width, expanded_world_height = saved_map_height,
						source_hex_width = source_hex_width, source_hex_height = source_hex_height,
						expanded_hex_width = saved_map_hex_width, expanded_hex_height = saved_map_hex_height,
					}
					-- Retain the real backing dimensions while the Lua-facing Map fields present the
					-- source view. The source-mask bridge uses these values to make the native mask
					-- sampler's cell-to-world step identical to a genuinely vanilla allocation.
					map.SuperBigMapExpandedWorldWidth = saved_map_width
					map.SuperBigMapExpandedWorldHeight = saved_map_height
					map.SuperBigMapExpandedHexWidth = saved_map_hex_width
					map.SuperBigMapExpandedHexHeight = saved_map_hex_height
					map.Width = gen_world_w
					map.Height = gen_world_h
					map.hex_width = source_hex_width
					map.hex_height = source_hex_height
				end
			end


			-- Make the AREA FACTOR computable at Begin time: mapdata.Width was just overridden to
			-- the generator size, and the pending-map markers can be wiped by the new-game Lua
			-- reload -- with both gone AreaFactor read 6144/6144 = 1 and the anomaly/research count
			-- scaling can silently do nothing if these values disappear. Stamp the detected
			-- full and generator tile sizes on the map so the later stretch passes
			-- always see desired=8192 / generator=6144.
			map.SuperBigMapDesiredWidthTiles = map.SuperBigMapDesiredWidthTiles or cur_w_tiles
			map.SuperBigMapDesiredHeightTiles = map.SuperBigMapDesiredHeightTiles or cur_h_tiles
			map.SuperBigMapGeneratorWidthTiles = map.SuperBigMapGeneratorWidthTiles or gen_width_tiles
			map.SuperBigMapGeneratorHeightTiles = map.SuperBigMapGeneratorHeightTiles or gen_height_tiles

			-- VANILLA-EXACT PLAY ZONE: PrepareMapDataForExpansion zeroed mapdata.PassBorder
			-- BEFORE ChangeMap so the engine bakes full-destination passability. But the
			-- generator ALSO reads map.mapdata.PassBorder to compute its play zone
			-- (RandomMapGenerator GetPlayableArea x2, BiomeFiller POI frame) -- with 0 instead
			-- of the native ~1024-tile border the play zone is BIGGER than vanilla, the
			-- placement masks differ, and the per-proc rand stream diverges: the same seed
			-- placed the same lake prefab at a different position/rotation. The engine consumed
			-- PassBorder at ChangeMap (before DoGenerate), so restoring the ORIGINAL value for
			-- just this DoGenerate window gives the generator vanilla-identical inputs while
			-- the baked passability stays border-free. Restored (re-zeroed) below.
			local saved_mapdata_pb, saved_mapdata_pbt, saved_template_pb, saved_template_pbt
			if cfg_bool("STRETCH_VANILLA_EXACT_PASSBORDER", true) then
				local orig_pb = (type(mapdata) == "table" and mapdata.SuperBigMapOriginalPassBorder)
					or (template and template.SuperBigMapOriginalPassBorder)
				if type(orig_pb) == "number" and orig_pb > 0 then
					if type(mapdata) == "table" and mapdata.PassBorder ~= orig_pb then
						saved_mapdata_pb = mapdata.PassBorder
						saved_mapdata_pbt = mapdata.PassBorderTiles
						mapdata.PassBorder = orig_pb
						if type(mapdata.PassBorderTiles) == "number" then
							mapdata.PassBorderTiles = math.floor(orig_pb / height_tile_size)
						end
					end
					if template and template ~= mapdata and template.PassBorder ~= orig_pb then
						saved_template_pb = template.PassBorder
						saved_template_pbt = template.PassBorderTiles
						template.PassBorder = orig_pb
						if type(template.PassBorderTiles) == "number" then
							template.PassBorderTiles = math.floor(orig_pb / height_tile_size)
						end
					end
				end
			end

			-- DETERMINISTIC ENTRANCE PAIRING (config
			-- PAIRING_SURFACE_BUILDABLE_REBUILD). Passage selection runs during underground
			-- generation but searches MainMap's surface grids. A generic RebuildGrids completion
			-- flag is not sufficient here: after temporary-source migration it described a usable
			-- gameplay grid, yet vanilla FindPassageSpawnPos rejected both passage markers. Build
			-- the surface Z grid once, synchronously, immediately before passage selection, against
			-- the live surface map dimensions and object grid. Vanilla then selects a complete
			-- naturally buildable Elevator footprint. Once the final stretched surface is available,
			-- the plan is checked again and vanilla's normal passage-pad preparation is applied only
			-- to that already-valid committed footprint.
			if cfg_bool("PAIRING_SURFACE_BUILDABLE_REBUILD", true) then
				local env = (type(mapdata) == "table" and mapdata.Environment)
					or (template and template.Environment)
				if env == "Underground" then
					local published_main_map = Global("MainMap")
					local maps = Global("Maps")
					local slot_one_map = type(maps) == "table" and maps[1] or nil
					local slot_one_is_surface = slot_one_map and slot_one_map ~= map
						and type(slot_one_map.mapdata) == "table"
						and slot_one_map.mapdata.Environment == "Surface"
					local main_map = slot_one_is_surface and slot_one_map or published_main_map
					if main_map ~= published_main_map then
						rawset(_G, "MainMap", main_map)
						rawset(_G, "MainCity", main_map.City or false)
						LoadingStep("surface main-map identity repaired before passage pairing", {
							previous = tostring(published_main_map),
							replacement = tostring(main_map),
						}, main_map)
					end
					local rebuild = Global("RebuildBuildableGrid")
					if not main_map or main_map == map then
						error("surface passage pairing map is unavailable")
					end
					if type(rebuild) ~= "function" then
						error("surface passage pairing-grid rebuild API is unavailable")
					end
					local buildable = main_map.buildable
					local grid_missing = type(buildable) ~= "table" or not buildable.z_grid
					if main_map.SuperBigMapSurfaceBuildablePairingReady ~= true or grid_missing then
						local ok_rb, err_rb = pcall(rebuild, main_map)
						if not ok_rb then
							error("surface passage pairing-grid rebuild failed: " .. tostring(err_rb))
						end
						buildable = main_map.buildable
						if type(buildable) ~= "table" or not buildable.z_grid then
							error("surface passage pairing-grid rebuild produced no buildable grid")
						end
						main_map.SuperBigMapSurfaceBuildableCurrent = true
						main_map.SuperBigMapSurfaceBuildablePairingReady = true
						LoadingStep("surface passage pairing grid ready", {
							created = grid_missing,
						}, main_map)
					end
				end
			end

			State.rmg_placement_active_map = map
			local expanded_backing_token = LoadingBegin(
				"source-view RandomMapGenerator.DoGenerate on expanded backing", map)
			ProbeNativeClutterAccess(map, "expanded backing before underground DoGenerate")
			-- Stock prefab rasterization launches PrefabRasterParallelDiv squared real-time tasks.
			-- Those tasks share the placement-mark grid used by Proc_RemoveOverlappedObjects. On a
			-- physically expanded backing, task completion order can choose a different owner for an
			-- overlap even though the logical source view, prefab list, positions, and RNG are all
			-- vanilla-identical. Run this one source-capture transaction through stock's documented
			-- single-task path, then restore the exact constant before any expanded-map work. This is
			-- scenario-agnostic and changes neither raster order nor predicates; it only removes the
			-- shared-grid write race while the native source is being generated.
			local raster_const = do_generate_closure_global("const", Global("const"))
			local saved_raster_parallel_div = type(raster_const) == "table"
				and raster_const.PrefabRasterParallelDiv or nil
			if type(saved_raster_parallel_div) ~= "number" or saved_raster_parallel_div < 1 then
				error("prefab raster parallelism constant is unavailable")
			end
			local serial_install_ok, serial_install_error = pcall(function()
				raster_const.PrefabRasterParallelDiv = 1
				if raster_const.PrefabRasterParallelDiv ~= 1 then
					error("prefab raster single-task write did not persist")
				end
			end)
			if not serial_install_ok then
				error("prefab raster single-task transaction unavailable: "
					.. tostring(serial_install_error))
			end

			-- NATIVE MARK-GRID PROJECTION (config UNDERGROUND_MARK_GRID_BACKING_SCALE). The
			-- generator sizes every working grid from its Lua-visible map size -- 614400/800 = 768
			-- cells here -- but the NATIVE prefab rasterizer and the native GridGetMark reader
			-- project a grid over the map's PHYSICAL extent, 819200 on this expanded backing. The
			-- placement-mark grid therefore quantizes at 1066.67 wu per cell instead of vanilla's
			-- 800, and Proc_RemoveOverlappedObjects reads a different cell than the vanilla twin
			-- for objects near a prefab-mark boundary (measured: the nonzero-mark bounding box is
			-- exactly 3/4 of vanilla's, and the native reader agrees with a backing-view sample
			-- 2712/3000 against the source view's 8/3000). Allocate the mark grid at backing scale
			-- (819200/800 = 1024) for the two ApplyTerrain procedures only: the native cell step is
			-- then exactly vanilla's 800 wu, the generated source view occupies the lower 768x768
			-- corner, and the marks quantize exactly as they do on a vanilla map. The mark grid is
			-- never combined with another grid -- it is only rasterized into, sampled through
			-- GridGetMark and freed -- so its dimensions are free to differ from work_size.
			-- The generator resolves NewComputeGrid as a plain global from the SHIPPED environment,
			-- which mod code cannot inspect (FunctionEnvironment needs getfenv/debug, neither of
			-- which Relaunched exposes to the sandbox -- that is why the raster-parallelism override
			-- above can only work through a table mutated by reference). Rebind it exactly the way
			-- PatchAdditionalMapSeedReservation rebinds its shipped consumers: drop any raw sandbox
			-- shadow, do an ORDINARY write so the sandbox __newindex routes it to the real owner
			-- table, verify through the inherited read, then restore the shadow.
			local function mark_grid_bridge_read(name)
				local direct = rawget(_G, name)
				rawset(_G, name, nil)
				local read_ok, value = pcall(function() return _G[name] end)
				rawset(_G, name, direct)
				return read_ok and value or nil
			end
			local function mark_grid_bridge_write(name, value)
				local direct = rawget(_G, name)
				rawset(_G, name, nil)
				local write_ok = pcall(function() _G[name] = value end)
				local unexpected_direct = rawget(_G, name)
				rawset(_G, name, nil)
				local read_ok, inherited = pcall(function() return _G[name] end)
				rawset(_G, name, direct)
				return write_ok and (unexpected_direct == nil or unexpected_direct == value)
					and read_ok and inherited == value
			end

			local mark_grid_class = Global("RandomMapGenerator")
			local mark_grid_saved_new_compute, mark_grid_new_compute_wrapper
			local mark_grid_saved_proc_start, mark_grid_saved_proc_end
			local mark_grid_proc_start_wrapper, mark_grid_proc_end_wrapper
			local mark_grid_stats = { phases = 0, scaled = 0, unscaled = 0, cells = "none" }
			if cfg_bool("UNDERGROUND_MARK_GRID_BACKING_SCALE", true)
				and type(mark_grid_class) == "table"
				and type(saved_map_width) == "number" and saved_map_width > gen_world_w
				and type(saved_map_height) == "number" and saved_map_height > gen_world_h
				and gen_world_w > 0 and gen_world_h > 0 then
				mark_grid_saved_new_compute = mark_grid_bridge_read("NewComputeGrid")
					or Global("NewComputeGrid")
				mark_grid_saved_proc_start = mark_grid_class.ProcStart
				mark_grid_saved_proc_end = mark_grid_class.ProcEnd
				if type(mark_grid_saved_new_compute) ~= "function"
					or type(mark_grid_saved_proc_start) ~= "function"
					or type(mark_grid_saved_proc_end) ~= "function" then
					error("underground mark-grid projection API is unavailable")
				end
				-- Stock ProcInvoke brackets every generator procedure with ProcStart/ProcEnd, and
				-- apply_terrain -- the only creator of the mark grid -- runs inside exactly these
				-- two tags. Scale grid allocations for this generator instance only while one of
				-- them is on the stack; every other allocation passes through untouched.
				local mark_phase_active = false
				local function mark_phase_tag(tag)
					return tag == "ApplyTerrain" or tag == "ApplyTerrainMarkOnly"
				end
				mark_grid_new_compute_wrapper = function(width, height, ...)
					if mark_phase_active
						and type(width) == "number" and type(height) == "number"
						and width > 0 and height > 0
						and (width * saved_map_width) % gen_world_w == 0
						and (height * saved_map_height) % gen_world_h == 0 then
						local scaled_width = math.floor((width * saved_map_width) / gen_world_w)
						local scaled_height = math.floor((height * saved_map_height) / gen_world_h)
						if scaled_width > width and scaled_height > height then
							mark_grid_stats.scaled = mark_grid_stats.scaled + 1
							mark_grid_stats.cells = tostring(width) .. "x" .. tostring(height)
								.. "->" .. tostring(scaled_width) .. "x" .. tostring(scaled_height)
							return mark_grid_saved_new_compute(scaled_width, scaled_height, ...)
						end
					end
					mark_grid_stats.unscaled = mark_grid_stats.unscaled + 1
					return mark_grid_saved_new_compute(width, height, ...)
				end
				mark_grid_proc_start_wrapper = function(generator, tag, ...)
					if generator == self and mark_phase_tag(tag) then
						mark_phase_active = true
						mark_grid_stats.phases = mark_grid_stats.phases + 1
					end
					return mark_grid_saved_proc_start(generator, tag, ...)
				end
				mark_grid_proc_end_wrapper = function(generator, tag, ...)
					if generator == self and mark_phase_tag(tag) then
						mark_phase_active = false
					end
					return mark_grid_saved_proc_end(generator, tag, ...)
				end
				mark_grid_class.ProcStart = mark_grid_proc_start_wrapper
				mark_grid_class.ProcEnd = mark_grid_proc_end_wrapper
				if not mark_grid_bridge_write("NewComputeGrid", mark_grid_new_compute_wrapper) then
					mark_grid_class.ProcStart = mark_grid_saved_proc_start
					mark_grid_class.ProcEnd = mark_grid_saved_proc_end
					mark_grid_bridge_write("NewComputeGrid", mark_grid_saved_new_compute)
					mark_grid_new_compute_wrapper = nil
					error("underground mark-grid projection override could not be installed")
				end
			end

			local results = { pcall(CallWithClutterCapture, map,
				call_original_do_generate, self, map, ...) }

			-- Restore the grid allocator and both procedure boundaries on every path, exactly as
			-- they were, before any other expanded-map work can allocate a generator grid.
			if mark_grid_new_compute_wrapper then
				local mark_restore_ok = mark_grid_bridge_write("NewComputeGrid", mark_grid_saved_new_compute)
				if mark_grid_class.ProcStart == mark_grid_proc_start_wrapper then
					mark_grid_class.ProcStart = mark_grid_saved_proc_start
				end
				if mark_grid_class.ProcEnd == mark_grid_proc_end_wrapper then
					mark_grid_class.ProcEnd = mark_grid_saved_proc_end
				end
				if not mark_restore_ok then
					error("underground mark-grid projection restoration failed")
				end
				LoadingStep("underground mark grid allocated at backing scale", {
					mark_phases = mark_grid_stats.phases,
					scaled_grids = mark_grid_stats.scaled,
					unscaled_grids = mark_grid_stats.unscaled,
					grid_cells = mark_grid_stats.cells,
					source_world = gen_world_w,
					backing_world = saved_map_width,
				}, map)
			end
			local serial_restore_ok, serial_restore_error = pcall(function()
				raster_const.PrefabRasterParallelDiv = saved_raster_parallel_div
				if raster_const.PrefabRasterParallelDiv ~= saved_raster_parallel_div then
					error("prefab raster parallelism restoration did not persist")
				end
			end)
			if not serial_restore_ok then
				error("prefab raster parallelism restoration failed: "
					.. tostring(serial_restore_error))
			end
			LoadingStep("source prefab raster transaction serialized", {
				previous_parallel_div = saved_raster_parallel_div,
				restored_parallel_div = raster_const.PrefabRasterParallelDiv,
				generation_ok = results[1] == true,
			}, map)
			local seed_trace = State.underground_seed_reservation_trace
			if type(seed_trace) == "table" and seed_trace.generator == self
				and type(mapdata) == "table" and mapdata.Environment == "Underground" then
				local get_holder = Global("GetRandomMapGeneratorHolder")
				local holder = type(get_holder) == "function" and SafeCall(get_holder, map) or nil
				SuperBigMap.TraceUndergroundSeedReservation("HOLDER", {
					boundary = tostring(seed_trace.boundary),
					reserved_seed = tostring(seed_trace.reserved_seed),
					seeded_params_seed = tostring(seed_trace.seeded_params_seed),
					consumer_seed = tostring(seed_trace.consumer_seed),
					consumer_status = tostring(seed_trace.consumer_status),
					holder_seed = tostring(holder and holder.Seed),
					holder_generation_hash = tostring(holder and holder.GenerationHash),
					generation_ok = tostring(results[1] == true),
				}, map)
				State.underground_seed_reservation_trace = nil
			end
			ProbeNativeClutterAccess(map, "expanded backing after underground DoGenerate")
			LoadingEnd(expanded_backing_token, nil, results[1] == true)
			-- Restore the cached MapVars before bridge cleanup can run. The
			-- pcall above covers both the successful and failing native-generation paths, so an
			-- engine/Lua failure cannot leave the live expanded map reporting source dimensions.
			if buildable_source_view then
				map.Width = saved_map_width
				map.Height = saved_map_height
				map.hex_width = saved_map_hex_width
				map.hex_height = saved_map_hex_height
			end
			State.rmg_placement_active_map = false

			map.GetMapSize = original_map_get_size
			if terrain_api and original_terrain_get_size then
				terrain_api.GetMapSize = original_terrain_get_size
			end
			if template then
				template.Width = saved_template_w
				template.Height = saved_template_h
				if saved_template_pb ~= nil then
					template.PassBorder = saved_template_pb
					template.PassBorderTiles = saved_template_pbt
				end
			end
			if type(mapdata) == "table" then
				mapdata.Width = saved_mapdata_w
				mapdata.Height = saved_mapdata_h
				if saved_mapdata_pb ~= nil then
					mapdata.PassBorder = saved_mapdata_pb
					mapdata.PassBorderTiles = saved_mapdata_pbt
				end
			end

			if not results[1] then
				error(results[2])
			end
			-- POST-GENERATION PAD SMOOTHING (config PASSAGE_PAD_SMOOTHING). The generator's
			-- entrance flatten is PER-HEX -- one height per hex -- so even with clean values it
			-- leaves faint hex terracing (zigzag creases) around the entrances. After the
			-- generator has fully finished (nothing re-flattens after this), smooth the height
			-- field around each remembered entrance footprint with the engine's own GridSmooth
			-- (the same op the map generator uses for terrain filtering). Runs PRE-stretch, so
			-- the stretch resample carries the smoothed ground to the final map. One height-grid
			-- get/set for all pads (~1-2s during loading).
			do
				local pads = State.sbm_entrance_pads
				if type(pads) == "table" and #pads > 0 and cfg_bool("PASSAGE_PAD_SMOOTHING", true) then
					local terrain_api3 = Global("terrain")
					local grid_to_compute = Global("GridToCompute")
					local new_grid = Global("NewComputeGrid")
					local is_compute = Global("IsComputeGrid")
					local grid_smooth = Global("GridSmooth")
					local box_fn3 = Global("box")
					local point_fn3 = Global("point")
					local const_tbl3 = Global("const")
					local tile3 = (type(const_tbl3) == "table" and type(const_tbl3.HeightTileSize) == "number"
						and const_tbl3.HeightTileSize > 0) and const_tbl3.HeightTileSize or 100
					local hex3 = (type(const_tbl3) == "table" and type(const_tbl3.HexSize) == "number"
						and const_tbl3.HexSize > 0) and const_tbl3.HexSize or 1000
					local function free_grid3(g)
						if g then pcall(function() if type(g.free) == "function" then g:free() end end) end
					end
					if type(terrain_api3) == "table" and type(terrain_api3.GetHeightGrid) == "function"
						and type(terrain_api3.SetHeightGrid) == "function" and type(grid_smooth) == "function"
						and type(grid_to_compute) == "function" and type(new_grid) == "function"
						and type(box_fn3) == "function" and type(point_fn3) == "function" then
						-- All pads are on the same (surface) map in practice; group by map anyway.
						local by_map = {}
						for _, pad in ipairs(pads) do
							if pad.map then
								by_map[pad.map] = by_map[pad.map] or {}
								table.insert(by_map[pad.map], pad)
							end
						end
						for pmap, plist in pairs(by_map) do
							pcall(function()
								local raw = terrain_api3.GetHeightGrid(pmap)
								local full = grid_to_compute(raw)
								local fw, fh = full:size()
								local fmt, bits
								if type(is_compute) == "function" then
									fmt, bits = is_compute(full)
								end
								fmt = fmt or "F"
								for _, pad in ipairs(plist) do
									-- +10 hexes: the outer ~30 tiles are the FEATHER band (see below),
								-- so the footprint itself stays inside the fully-smoothed core.
								local radius_wu = ((pad.hex_radius or 10) + 10) * hex3
									local r_tiles = math.floor(radius_wu / tile3 + 0.5)
									local cx_t = math.floor(pad.x / tile3 + 0.5)
									local cy_t = math.floor(pad.y / tile3 + 0.5)
									local x0 = math.max(0, cx_t - r_tiles)
									local y0 = math.max(0, cy_t - r_tiles)
									local x1 = math.min(fw, cx_t + r_tiles)
									local y1 = math.min(fh, cy_t + r_tiles)
									local w, h = x1 - x0, y1 - y0
									if w > 4 and h > 4 then
										local region = new_grid(w, h, fmt, bits)
										region:copyrect(full, box_fn3(x0, y0, x1, y1), point_fn3(0, 0))
										local smoothed = new_grid(w, h, fmt, bits)
										local ok_s = pcall(grid_smooth, region, smoothed, 3)
										if ok_s then
											-- FEATHER the region edge: a hard copyrect boundary
											-- between smoothed interior and untouched exterior
											-- reads as a straight LINE on the ground (user
											-- report). Blend an edge band: original terrain at
											-- the border -> fully smoothed at band depth, so the
											-- transition is gradual and invisible. Integer math:
											-- multiply before dividing (engine Lua truncates).
											local BAND = 30 -- tiles (~3000 wu)
											local pause3 = Global("PauseInfiniteLoopDetection")
											local resume3 = Global("ResumeInfiniteLoopDetection")
											if type(pause3) == "function" then pcall(pause3, "SBMPadFeather") end
											pcall(function()
												for yy = 0, h - 1 do
													local dy0 = math.min(yy, h - 1 - yy)
													for xx = 0, w - 1 do
														local dd = math.min(xx, w - 1 - xx, dy0)
														if dd < BAND then
															local ov = region:get(xx, yy)
															local sv = smoothed:get(xx, yy)
															if type(ov) == "number" and type(sv) == "number" then
																smoothed:set(xx, yy, ov + (sv - ov) * dd / BAND)
															end
														end
													end
												end
											end)
											if type(resume3) == "function" then pcall(resume3, "SBMPadFeather") end
											full:copyrect(smoothed, box_fn3(0, 0, w, h), point_fn3(x0, y0))
										end
										free_grid3(region)
										free_grid3(smoothed)
									end
								end
								terrain_api3.SetHeightGrid(pmap, full)
								if type(terrain_api3.InvalidateHeight) == "function" then
									pcall(terrain_api3.InvalidateHeight, pmap)
								end
								if full ~= raw then free_grid3(full) end
							end)
						end
					end
					-- Consumed: never smooth stale pads on a later generation/new game.
					State.sbm_entrance_pads = nil
				end
			end
			CaptureGeneratedNativeEnrichments(map, "DoGenerate expanded source complete")
			return Unpack(results, 2)
		end
		generator_class.DoGenerate = do_generate_wrapper
		State.generator_do_generate_wrapper = do_generate_wrapper
	end
	State.generator_patch_version = GENERATOR_PATCH_VERSION
	return true
end


-- THE MOD'S AUTHORITATIVE FINAL GAMEPLAY-GRID REBUILD, for either environment. It is a function
-- because it has to run more than once on a map: a rebuild stays authoritative only until the next
-- object-grid transaction. The engine re-derives passability for the regions touched between
-- SuspendPassEdits and the matching ResumePassEdits, so any later transaction silently discards a
-- whole-map result over the region it touched -- measured underground (iteration 037, call tracer):
-- the pipeline's own pre-anomaly buried-wonder reseat was the last pass-edit bracket of generation,
-- and its resume put the underground pass grid back to the state the rebuild had just corrected.
-- The surface has the same shape (iteration 041, same trace): after its last traced rebuild the
-- surface passability digest still moved twice, and nothing rebuilt it afterwards. Hence a closing
-- call on each map after its LAST object-grid transaction. Every step is whole-map and derived from
-- TerrainSize; there is nothing per-map, per-class or per-coordinate here.
-- It hangs on the module namespace rather than being a file local because this chunk already
-- sits at Lua's 200-local-per-function ceiling.
SuperBigMap.GenerationGrids = SuperBigMap.GenerationGrids or {}
function SuperBigMap.GenerationGrids.RebuildFinal(map, stage)
	stage = tostring(stage or "final")
	local environment = map and map.mapdata and map.mapdata.Environment
	local label = type(environment) == "string" and string.lower(environment) or "map"
	local terrain_api = Global("terrain")
	if not (type(terrain_api) == "table"
		and type(terrain_api.RebuildPassability) == "function") then
		error("final " .. label .. " passability rebuild is unavailable")
	end
	-- A BARE RebuildPassability recomputes NOTHING: the engine rebuilds only the regions
	-- that were invalidated first, which is why its own generator always calls
	-- InvalidateHeight + InvalidateType immediately before it
	-- (RandomMapGenerator.lua:2900). Without them this "authoritative" call left the
	-- grid as whatever earlier box-scoped rebuilds had produced -- measured at 45S82E
	-- as a buried wonder whose impassability imprint was cropped to a box around it
	-- (6,276 of 40,401 window cells blocked, against vanilla's 21,719). The same
	-- rebuild preceded by the two invalidates restores 21,668 of them (twin difference
	-- 15,459 -> 67 cells) and is idempotent; whole-map cost measured at 5.5 s.
	local invalidate_final = cfg_bool("FINAL_PASSABILITY_INVALIDATE", true)
	if invalidate_final
		and not (type(terrain_api.InvalidateHeight) == "function"
			and type(terrain_api.InvalidateType) == "function") then
		error("final " .. label .. " passability invalidation is unavailable")
	end
	local final_pass_w, final_pass_h = TerrainSize(map)
	local box_ctor = Global("box")
	local final_pass_box = (invalidate_final and type(box_ctor) == "function"
		and final_pass_w > 0 and final_pass_h > 0)
		and box_ctor(0, 0, final_pass_w, final_pass_h) or false
	-- Generation-time stamps (never saved) so a probe can tell "this call site ran and
	-- changed the grid" from "it never ran" without a debug build: the passability
	-- digest either side of the rebuild plus the branch, the stage and its cost. They live
	-- on the rebuilt map, so each environment carries its own. The LAST rebuild of that
	-- map's pipeline is the one they describe.
	local function pass_hash()
		if type(terrain_api.HashPassability) ~= "function" then return "unavailable" end
		local ok_h, h = pcall(terrain_api.HashPassability, map)
		return ok_h and tostring(h) or "error"
	end
	map.SuperBigMapFinalPassStage = stage
	map.SuperBigMapFinalPassCount = (map.SuperBigMapFinalPassCount or 0) + 1
	map.SuperBigMapFinalPassBranch = invalidate_final
		and (final_pass_box and "invalidate_box" or "invalidate_map") or "bare"
	map.SuperBigMapFinalPassHashBefore = pass_hash()
	local pass_started = GetPreciseTicks()
	local passability_token = LoadingBegin(
		label .. " final RebuildPassability (" .. stage .. ")", map)
	local pass_ok, pass_err
	if invalidate_final then
		-- The measured sequence (iteration 034), box form when the engine box
		-- constructor is available and whole-map form otherwise.
		pass_ok, pass_err = pcall(function()
			if final_pass_box then
				terrain_api.InvalidateHeight(map, final_pass_box)
				terrain_api.InvalidateType(map, final_pass_box)
				terrain_api.RebuildPassability(map, final_pass_box)
			else
				terrain_api.InvalidateHeight(map)
				terrain_api.InvalidateType(map)
				terrain_api.RebuildPassability(map)
			end
		end)
	else
		pass_ok, pass_err = pcall(terrain_api.RebuildPassability, map)
	end
	LoadingEnd(passability_token,
		{ error = pass_ok and "" or tostring(pass_err) }, pass_ok)
	map.SuperBigMapFinalPassMs = GetPreciseTicks() - pass_started
	if not pass_ok then
		error("final " .. label .. " passability rebuild failed: " .. tostring(pass_err))
	end
	-- The stock rebuild is the authoritative final terrain-property verdict. PassBorder
	-- remains zero for full-map placement bounds; do not replay source-border overrides
	-- afterward, because that would leave shipped passability different from a fresh
	-- stock rebuild of the same final terrain.
	map.SuperBigMapFinalPassHashAfter = pass_hash()
	local rebuild_buildable = Global("RebuildBuildableGrid")
	if type(rebuild_buildable) ~= "function" then
		error("final " .. label .. " buildable-grid rebuild is unavailable")
	end
	SetLoadingPhase("Rebuilding the final " .. label .. " build grid")
	local buildable_token = LoadingBegin(
		label .. " final RebuildBuildableGrid (" .. stage .. ")", map)
	local build_ok, build_err = pcall(rebuild_buildable, map)
	LoadingEnd(buildable_token, { error = build_ok and "" or tostring(build_err) }, build_ok)
	if not build_ok then
		error("final " .. label .. " buildable-grid rebuild failed: " .. tostring(build_err))
	end
	map.SuperBigMapRevalidationRebuiltGrids = true
	return true
end

-- Resource shaping is hard-clipped to the physical outer ring. Revalidate only that ring before
-- the resource audit and anomaly/effect selection, including two pass tiles on the untouched side so
-- slope/passability dependencies at the clip boundary are recomputed. The later closing rebuilds
-- remain whole-map, so T1 still carries the stock authoritative final grids. Any unavailable or
-- failed local operation returns false and lets the caller fall back to RebuildFinal.
function SuperBigMap.GenerationGrids.RebuildOuterResourceRing(map, ring_sectors, stage)
	stage = tostring(stage or "outer resource terrain")
	ring_sectors = math.floor(tonumber(ring_sectors) or 0)
	local prior = map and map.SuperBigMapOuterResourceRingRebuildReport
	local report = {
		requested = cfg_bool("OPTIMIZE_OUTER_RESOURCE_TERRAIN_RING_REBUILD", true),
		used = false,
		fallback = type(prior) == "table" and prior.fallback == true,
		boxes = 0,
		ring_sectors = ring_sectors,
		passability_ms = 0,
		buildable_ms = 0,
		total_ms = 0,
		error = "",
		stage = stage,
		calls = type(prior) == "table" and (tonumber(prior.calls) or 0) + 1 or 1,
		fallbacks = type(prior) == "table" and (tonumber(prior.fallbacks) or 0) or 0,
		error_history = type(prior) == "table" and tostring(prior.error_history or "") or "",
	}
	if map then map.SuperBigMapOuterResourceRingRebuildReport = report end
	if report.requested ~= true then
		report.error = "outer resource ring rebuild is disabled"
		return false, report
	end
	if not map or ring_sectors <= 0 or ring_sectors >= 10 then
		report.error = "outer resource ring geometry is invalid"
		return false, report
	end
	local terrain_api = Global("terrain")
	local rebuild_buildable = Global("RebuildBuildableGrid")
	local box_ctor = Global("box")
	if not (type(terrain_api) == "table"
		and type(terrain_api.InvalidateHeight) == "function"
		and type(terrain_api.InvalidateType) == "function"
		and type(terrain_api.RebuildPassability) == "function"
		and type(rebuild_buildable) == "function"
		and type(box_ctor) == "function") then
		report.error = "outer resource ring rebuild APIs are unavailable"
		return false, report
	end
	local map_w, map_h = TerrainSize(map)
	if map_w <= 0 or map_h <= 0 then
		report.error = "outer resource ring map dimensions are unavailable"
		return false, report
	end
	local const_tbl = Global("const")
	local pass_tile = type(const_tbl) == "table" and tonumber(const_tbl.PassTileSize) or 100
	pass_tile = type(pass_tile) == "number" and pass_tile > 0 and pass_tile or 100
	-- Match the stock passability brush's dependency expansion exactly.
	local dependency_margin = math.floor(pass_tile * 2)
	-- Ceil the near-side thickness so a non-divisible map dimension cannot omit the last
	-- integer coordinate that still lies inside the continuous physical ring.
	local band_x = math.ceil(map_w * ring_sectors / 20)
	local band_y = math.ceil(map_h * ring_sectors / 20)
	local inner_x = math.min(map_w, band_x + dependency_margin)
	local inner_y = math.min(map_h, band_y + dependency_margin)
	local far_x = math.max(0, map_w - band_x - dependency_margin)
	local far_y = math.max(0, map_h - band_y - dependency_margin)
	if inner_x >= far_x or inner_y >= far_y then
		report.error = "outer resource ring dependency margin covers the map"
		return false, report
	end
	-- Full-width top/bottom and full-height left/right strips deliberately overlap only at
	-- the corners. That keeps each passability call independent at its long edges while still
	-- visiting about 40 percent of a 20x20 map instead of all of it.
	local regions = {
		box_ctor(0, 0, map_w, inner_y),
		box_ctor(0, far_y, map_w, map_h),
		box_ctor(0, 0, inner_x, map_h),
		box_ctor(far_x, 0, map_w, map_h),
	}
	local total_started = GetPreciseTicks()
	local pass_started = GetPreciseTicks()
	local passability_token = LoadingBegin(
		"surface outer resource ring RebuildPassability (" .. stage .. ")", map,
		{ ring_sectors = ring_sectors, boxes = #regions })
	local pass_ok, pass_err = pcall(function()
		for _, region in ipairs(regions) do
			terrain_api.InvalidateHeight(map, region)
			terrain_api.InvalidateType(map, region)
			terrain_api.RebuildPassability(map, region)
		end
	end)
	report.passability_ms = GetPreciseTicks() - pass_started
	LoadingEnd(passability_token, {
		error = pass_ok and "" or tostring(pass_err),
		boxes = #regions,
	}, pass_ok)
	if not pass_ok then
		report.total_ms = GetPreciseTicks() - total_started
		report.error = "outer resource ring passability rebuild failed: " .. tostring(pass_err)
		return false, report
	end
	local buildable_started = GetPreciseTicks()
	local buildable_token = LoadingBegin(
		"surface outer resource ring RebuildBuildableGrid (" .. stage .. ")", map)
	local build_ok, build_err = pcall(rebuild_buildable, map)
	report.buildable_ms = GetPreciseTicks() - buildable_started
	LoadingEnd(buildable_token, { error = build_ok and "" or tostring(build_err) }, build_ok)
	report.total_ms = GetPreciseTicks() - total_started
	if not build_ok then
		report.error = "outer resource ring buildable-grid rebuild failed: "
			.. tostring(build_err)
		return false, report
	end
	report.boxes = #regions
	report.used = true
	return true, report
end

-- Protect the complete regional helper, including box construction and diagnostics, then preserve
-- the old whole-map behavior on every unavailable, returned-false, or thrown-error path.
function SuperBigMap.GenerationGrids.RebuildOuterResourceRingOrFinal(map, ring_sectors, stage)
	local call_ok, used, report = pcall(
		SuperBigMap.GenerationGrids.RebuildOuterResourceRing, map, ring_sectors, stage)
	if call_ok and used == true then return true, report end
	report = type(report) == "table" and report
		or map and map.SuperBigMapOuterResourceRingRebuildReport or nil
	if type(report) ~= "table" then
		report = {
			requested = cfg_bool("OPTIMIZE_OUTER_RESOURCE_TERRAIN_RING_REBUILD", true),
			used = false, fallback = false, boxes = 0, calls = 1, fallbacks = 0,
			error = "", error_history = "", stage = tostring(stage or "outer resource terrain"),
		}
		if map then map.SuperBigMapOuterResourceRingRebuildReport = report end
	end
	local failure = call_ok and tostring(report.error or "")
		or "outer resource ring helper failed: " .. tostring(used)
	if failure == "" then failure = "outer resource ring rebuild returned false" end
	report.used = false
	report.fallback = true
	report.fallbacks = (tonumber(report.fallbacks) or 0) + 1
	report.error = failure
	report.error_history = report.error_history ~= ""
		and (tostring(report.error_history) .. " | " .. failure) or failure
	SuperBigMap.GenerationGrids.RebuildFinal(map,
		tostring(stage or "outer resource terrain") .. " fallback")
	return false, report
end

-- Stretch-only surface expansion readiness gate.
local function SurfaceExpansionReadiness(map)
	if map.SuperBigMapNativeGenerationComplete ~= true then
		return false, "native generation has not completed"
	end
	if map.SuperBigMapCityInitializationComplete ~= true then
		return false, "city initialization and enrichment placement have not completed"
	end
	if map.SuperBigMapExpansionPending == true then
		return false, "expanded destination finalization is still pending"
	end
	if not FindSectorByName(map, "F0") then
		return false, "final sector grid does not contain F0"
	end
	return true, "native generation and destination finalization complete"
end

local function RunSurfaceStretchIfEnabled(map, readiness_source)
	map = map or Global("CurrentMap")
	if not cfg_bool("SURFACE_STRETCH_AT_START", false) then
		EndSurfaceExpansionLoading(map)
		return false
	end
	if not map then
		return false
	end
	-- SuperBigMapExpanded is persisted per map. A loaded save has no new MapGenerated or
	-- CityInitialized transaction to wait for, and its expansion must never be repeated.
	if map.SuperBigMapExpanded == true and map.SuperBigMapExpansionPending ~= true then
		map.SuperBigMapSurfaceStretchDone = true
		map.SuperBigMapSurfaceStretchAwaitingReadiness = false
		map.SuperBigMapStretchPipelinePending = false
		SignalExpansionReadinessChanged(map, "persisted surface expansion already complete")
		EndSurfaceExpansionLoading(map)
		return false
	end
	if map.SuperBigMapSurfaceStretchDone == true then
		EndSurfaceExpansionLoading(map)
		return false
	end
	-- Report an existing live schedule as success so the lifecycle caller does not run its
	-- fallback full-map rebuild in parallel with the expansion transaction.
	if map.SuperBigMapSurfaceStretchScheduled == true then return true end
	if cfg_bool("OPTIMIZE_STRETCH_DEFERRED_REBUILDS", true) then
		map.SuperBigMapStretchPipelinePending = true
	end
	local ready, readiness = SurfaceExpansionReadiness(map)
	if not ready then
		map.SuperBigMapSurfaceStretchAwaitingReadiness = true
		-- This is an accepted deferred schedule. The lifecycle caller must not run the
		-- full-map fallback while MapGenerated/CityInitialized can satisfy the gate.
		return true
	end
	local create_thread = Global("CreateRealTimeThread")
	local yield_protected_call = Global("sprocall")
	if type(create_thread) ~= "function" or type(yield_protected_call) ~= "function" then
		map.SuperBigMapStretchPipelinePending = false
		EndSurfaceExpansionLoading(map)
		return false
	end
	map.SuperBigMapSurfaceStretchAwaitingReadiness = false
	map.SuperBigMapSurfaceStretchScheduled = true
	local schedule_ok = pcall(create_thread, function()
		-- Protect the entire asynchronous pipeline, not only its central stretch block, so
		-- readiness/setup errors take the normal full-rebuild fallback.
		local thread_ok, thread_err = yield_protected_call(function()
		local function end_loading()
			-- Fail-safe: if the stretch exited before its final lightweight refresh, restore the
			-- original full rebuild path rather than leave partially refreshed map state.
			if map.SuperBigMapStretchPipelinePending == true then
				local lifecycle = SuperBigMap.Lifecycle
				if lifecycle and type(lifecycle.Apply) == "function" then
					SafeCall(lifecycle.Apply, map, true)
				end
				map.SuperBigMapStretchPipelinePending = false
			end
			EndSurfaceExpansionLoading(map)
		end
		if map.SuperBigMapSurfaceStretchDone == true then
			end_loading()
			return
		end
		-- Only maps the mod ACTUALLY expanded are candidates. Skip SILENTLY (no
		-- "cannot expand" popup) for:
		--   * the "PreGame" mission-setup preview map (a native ~15x15 preview that
		--     carries no expansion -- this is what fired the warning BEFORE a scenario
		--     was even chosen), and
		--   * any non-mod map (IsModMap == false) -- the same authoritative gate
		--     Lifecycle.Apply uses, so the stretch plan can never disagree with it and
		--     run on a map Apply already skipped.
		-- The looser UseCustomSectorsForMap check is kept as an additional silent skip.
		local map_name = tostring(map.name or (map.mapdata and map.mapdata.id) or "")
		local grid = SuperBigMap.SectorGrid
		local is_mod_map = type(grid) == "table" and type(grid.IsModMap) == "function" and grid.IsModMap(map) == true
		local custom_ok = not (type(grid) == "table" and type(grid.UseCustomSectorsForMap) == "function")
			or grid.UseCustomSectorsForMap(map)
		if map_name == "PreGame" or not is_mod_map or not custom_ok then
			map.SuperBigMapSurfaceStretchDone = true
			end_loading()
			return
		end
		local map_w, map_h = TerrainSize(map)
		if type(map_w) ~= "number" or map_w <= 0 or type(map_h) ~= "number" or map_h <= 0 then
			map.SuperBigMapSurfaceStretchDone = true
			end_loading()
			return
		end

		-- Resample the generated source to fill the whole destination as one continuous terrain.
		-- STEP 1 = TERRAIN ONLY: the
		-- generated objects/deposits are NOT yet repositioned, so they stay clustered in the
		-- source corner until the object pass lands.
		do
			-- Run the whole stretch + finalize inside pcall so an error cannot strand the loading UI.
			-- the expansion thread does not die before end_loading() -- that is what leaves the
			-- loading box stuck on screen forever. Whatever happens, we mark the map done and close
			-- the loading box below.
			-- The stretch passes iterate the full-map grids + EVERY object in one uninterrupted go;
			-- without the old per-step yields the engine's infinite-loop detector trips ("Infinite
			-- loop detected!"). Pause it for the duration -- these are BOUNDED passes (finite grid
			-- steps + a fixed object list), the same guard the deposit top-up uses. The resume below
			-- is balanced and ALWAYS runs (after the pcall, before we return).
			local pause_ild = Global("PauseInfiniteLoopDetection")
			local resume_ild = Global("ResumeInfiniteLoopDetection")
			if type(pause_ild) == "function" then SafeCall(pause_ild, "SuperBigMapStretch") end
			local ok_stretch, n_grids = false, 0
			local surface_pipeline_token = LoadingBegin("surface expansion pipeline", map)
			-- Create and render the dialog before pass edits are suspended. ResumePassEdits requires
			-- GameTime to match the value captured by SuspendPassEdits, so no Sleep/yield is allowed
			-- inside that transaction.
			local loading_visible = BeginSurfaceExpansionLoading(map,
				"Please wait.")
			local sleep = Global("Sleep")
			if type(sleep) == "function" then sleep(100) end
			local visible_check = SuperBigMap.ExpansionLoadingVisible
			if type(visible_check) == "function" then
				loading_visible = visible_check() == true
			end
			LoadingStep("surface custom loading handoff", {
				started = tostring(surface_loading_ref_maps[map] == true),
				visible = tostring(loading_visible == true),
				milestone = "before_pass_edit_suspension_and_terrain_stretch",
			}, map)
			-- One transaction owns both mass-object moves so intermediate edits do not flush
			-- passability before the stretch's authoritative final revalidation.
			local pass_batch_reason = "SuperBigMapSurfaceStretch"
			local pass_batch_active = false
			if type(map.SuspendPassEdits) == "function" and type(map.ResumePassEdits) == "function" then
				local suspend_ok, suspend_result = pcall(map.SuspendPassEdits, map, pass_batch_reason)
				pass_batch_active = suspend_ok and suspend_result ~= false
			end
			local function ResumeCombinedPassEdits(source, ignore_errors)
				if not pass_batch_active then return true end
				local resume_ok, resume_err = pcall(
					map.ResumePassEdits, map, pass_batch_reason, ignore_errors == true)
				-- The engine validates GameTime before consuming this reason. Keep ownership after an
				-- exception so the outer cleanup can balance it with ignore_errors=true.
				if resume_ok then pass_batch_active = false end
				return resume_ok, resume_err
			end
			local ok_branch, branch_err = pcall(function()
				if type(StretchSourceToFull) == "function" then
					-- Relief annotations MUST be captured BEFORE the terrain stretch (they record
					-- each object's relationship to the PRE-stretch ground).
					if type(AnnotateDecorRelief) == "function"
						and map.SuperBigMapDecorReliefCapturedFromTemporarySource ~= true then
						AnnotateDecorRelief(map)
					elseif map.SuperBigMapDecorReliefCapturedFromTemporarySource == true then
						LoadingStep("using decor relief captured from temporary source", nil, map)
					end
					if cfg_bool("EXPANSION_STEP_07_STRETCH_TERRAIN", true) then
						-- The next call mutates terrain heights, so the native source-grid buildability
						-- snapshot is no longer current until the explicit final rebuild below succeeds.
						map.SuperBigMapSurfaceBuildableCurrent = false
						ok_stretch, n_grids = StretchSourceToFull(map)
					else
						ok_stretch, n_grids = true, 0
					end
				end
				-- The source map's enrichment OBJECTS were deliberately not transferred: their owning map
				-- slot has been unloaded. Stage 01 retained constructor-safe value records instead.
				-- Recreate them only now, after final terrain resampling, so every marker is born on its
				-- exact proportional hex and reads Z from the final destination terrain.
				local position_deposits = SuperBigMap.DepositRules
				local has_staged_records, staged_record_count = false, 0
				if position_deposits
					and type(position_deposits.HasStagedNativeEnrichmentRecords) == "function" then
					has_staged_records, staged_record_count =
						position_deposits.HasStagedNativeEnrichmentRecords(map)
				end
				-- Step 2: reposition + scale the generated decorations onto the stretched terrain
				-- (must run AFTER the height stretch so SetTerrainZ reads the new surface).
				if type(ScaleDecorationsToFull) == "function" then
					SetLoadingPhase("Repositioning surface rocks and decorations")
					ScaleDecorationsToFull(map, pass_batch_active)
				end
				local feature_ok, feature_stats = RestoreTransferredPrefabFeatureGameLogic(map)
				if feature_ok ~= true then
					error("surface prefab feature correspondence failed: "
						.. tostring(feature_stats and feature_stats.error or "unknown error"))
				end
				if has_staged_records then
					if ok_stretch ~= true then
						error("cannot recreate staged native enrichments before a successful terrain stretch")
					end
					if type(position_deposits.RecreateStagedNativeEnrichments) ~= "function" then
						error("staged native enrichment recreation API unavailable")
					end
					SetLoadingPhase("Restoring the vanilla resources and anomalies")
					local recreated, recreate_stats = position_deposits.RecreateStagedNativeEnrichments(
						map, "surface after terrain and decoration stretch")
					if recreated ~= true then
						error("native enrichment recreation after stretch failed: "
							.. tostring(recreate_stats and recreate_stats.error or "unknown"))
					end
					local breakthrough_ok, breakthrough_stats =
						SuperBigMap.FinalizeDeferredBreakthroughAnomalyInitialization(
							map, "surface after native enrichment recreation")
					if breakthrough_ok ~= true then
						error("deferred vanilla breakthrough initialization failed: "
							.. tostring(breakthrough_stats and breakthrough_stats.error or "unknown"))
					end
				end
				-- Step 3: move the deposit/anomaly/effect markers to their scaled spots too
				-- (config STRETCH_SCALE_MARKERS) -- same transform, positions only.
				if type(ScaleMarkersToFull) == "function" then
					SetLoadingPhase("Repositioning surface resource deposits")
					local marker_scale_token = LoadingBegin("surface scale marker objects", map)
					local n_mark = ScaleMarkersToFull(map, false, pass_batch_active)
					LoadingEnd(marker_scale_token, { moved = n_mark }, true)
					local position_deposits = SuperBigMap.DepositRules
					if position_deposits
						and type(position_deposits.VerifyNativeEnrichmentTransform) == "function" then
						local marker_verify_token = LoadingBegin(
							"surface verify native enrichment transform", map)
						local verified, verify_stats = position_deposits.VerifyNativeEnrichmentTransform(
							map, "surface after marker transform")
						LoadingEnd(marker_verify_token, {
							mismatches = verify_stats and verify_stats.mismatches or 0,
						}, verified == true)
						if verified ~= true then
							error("native surface enrichment transformation verification failed (mismatches="
								.. tostring(verify_stats and verify_stats.mismatches or "unknown") .. ")")
						end
					end
				end
				-- This ResumePassEdits is the surface's sole authoritative passability rebuild after
				-- replacing the complete height/type terrain grids. The engine exposes no transformed
				-- passability-grid setter, so this cannot be omitted or narrowed without leaving stale
				-- rover/building reachability. Identify it explicitly in timing output so it is not
				-- mistaken for removable marker-movement overhead.
				local pass_resume_token = LoadingBegin("surface resume combined pass edits", map)
				local pass_resume_ok, pass_resume_err = ResumeCombinedPassEdits(
					"after surface marker movement")
				LoadingEnd(pass_resume_token, {
					authoritative_passability_rebuild = true,
				}, pass_resume_ok == true)
				if not pass_resume_ok then
					error("surface combined ResumePassEdits failed: " .. tostring(pass_resume_err))
				end
				-- A deterministic census iterates the complete object population (including collision
				-- surfaces). It must follow the named resume: stock ResumePassEdits asserts that
				-- GameTime is unchanged between suspend and normal resume.
				SuperBigMap.NotifyDeterminismCaptureForTest("post_object_transform", map, {
					pass_edits_suspended = pass_batch_active == true,
				})
				-- Entrance visuals are finalized after the authoritative surface buildable-grid pass.
				-- Moving them here would anchor the badge to the provisional pre-validation coordinate.
				-- Step 4: consume the native-source start annotation after marker recreation. Every
				-- positive-overlap equivalent of the transformed vanilla winner is passed through the
				-- original vanilla InitialReveal resource/heat/buildability logic, and exactly the
				-- sectors vanilla's own reveal scanned are scanned here (its first winner, plus the
				-- auxiliary nearest-concrete sector when its fallback branch returns one). Mutually
				-- exclusive with legacy relocation (which would re-scale a freshly scanned destination
				-- sector).
				local sectors_mod = SuperBigMap.SectorExploration
				local vanilla_start_pending = sectors_mod
					and type(sectors_mod.HasPendingVanillaStartSelection) == "function"
					and sectors_mod.HasPendingVanillaStartSelection(map) == true
				if vanilla_start_pending then
					if sectors_mod and type(sectors_mod.RevealVanillaStartSectors) == "function" then
						local initial_reveal_token = LoadingBegin(
							"surface select stretched vanilla initial reveal", map)
						local n_rev = SafeCall(sectors_mod.RevealVanillaStartSectors, map)
						-- The callee already verifies fail-closed that it scanned exactly the sectors
						-- vanilla's reveal scanned, so the caller only requires that the annotated
						-- reveal happened at all; its skip paths and failures both yield < 1.
						local reveal_ok = type(n_rev) == "number" and n_rev >= 1
						LoadingEnd(initial_reveal_token, { scanned = n_rev }, reveal_ok)
						if not reveal_ok then
							error("stretched vanilla initial reveal failed: scanned=" .. tostring(n_rev))
						end
					end
				elseif cfg_bool("STRETCH_VANILLA_START_SECTOR", false) then
					error("native start-sector annotation missing before surface stretch")
				elseif type(StretchRelocateStartSector) == "function" then
					StretchRelocateStartSector(map)
				end
				-- The stretched terrain must have its authoritative destination-sized buildable grid
				-- before any top-up samples reachable positions. Waiting until after density placement
				-- leaves the lower and right perimeter represented by the old source-sized cutoff.
				if cfg_bool("EXPANSION_STEP_11_REBUILD_GAMEPLAY_GRIDS", true) then
					SetLoadingPhase("Rebuilding the surface build grid")
					local rebuild_buildable = Global("RebuildBuildableGrid")
					if type(rebuild_buildable) == "function" and map and map.buildable then
						local rebuild_token = LoadingBegin("surface final RebuildBuildableGrid", map)
						local rebuild_ok, rebuild_err = pcall(rebuild_buildable, map)
						LoadingEnd(rebuild_token, {
							error = rebuild_ok and "" or tostring(rebuild_err),
						}, rebuild_ok)
						if not rebuild_ok then
							error("final surface RebuildBuildableGrid failed: " .. tostring(rebuild_err))
						end
						map.SuperBigMapSurfaceBuildableCurrent = true
						local apron_ok, apron_stats =
							TerrainCopy.AuditNaturalMountainBaseBuildableAprons(map)
						LoadingStep("surface mountain-base apron buildable verdict", {
							ok = tostring(apron_ok == true),
							created = apron_stats and apron_stats.created or 0,
							buildable_centers = apron_stats and apron_stats.buildable_centers or 0,
							failed_centers = apron_stats and apron_stats.failed_centers or 0,
							reason = apron_stats and apron_stats.reason or "audit unavailable",
						}, map)
					else
						error("final surface RebuildBuildableGrid unavailable")
					end
				end
				-- Step 5: re-enforce scan-gating after the move (hide revealed enrichments that
				-- landed in unscanned sectors; place/reveal what moved into scanned ones).
				do
					local deposits = SuperBigMap.DepositRules
					if deposits and type(deposits.EnforceScanGateAfterStretch) == "function" then
						TimedSafeCall("surface enforce scan gate", map,
							deposits.EnforceScanGateAfterStretch, map)
					end
					-- Strict one-to-one mode never enters the legacy density suite. Besides creating
					-- extra markers, its overlap resolver could move a native source marker away from
					-- its authoritative proportional coordinate.
					if deposits
						and cfg_bool("EXPANSION_STEP_13_CALCULATE_ENRICHMENT_ADDITIONS", false) then
						SetLoadingPhase("Distributing surface resources and anomalies")
						if type(deposits.TopUpDeposits) == "function" then
							TimedSafeCall("surface top-up resources", map,
								deposits.TopUpDeposits, map)
						end
						-- Resource coordinates are final now.  Prepare only failed extractor/collection
						-- footprints and the planned mountain-cluster rocket pads, then ask the
						-- stock engine for the authoritative passability/buildability verdict before any
						-- anomaly or dome-effect candidate consumes terrain state.
						if type(TerrainCopy.PrepareOuterResourceTerrain) ~= "function"
							or type(TerrainCopy.AuditOuterResourceTerrain) ~= "function" then
							error("outer resource terrain preparation is unavailable")
						end
						local resource_prepare_started = GetPreciseTicks()
						local resource_terrain_changed, resource_terrain_stats = TimedSafeCall(
							"surface prepare outer resource terrain", map,
							TerrainCopy.PrepareOuterResourceTerrain, map)
						local resource_prepare_ms = GetPreciseTicks() - resource_prepare_started
						local resource_rebuild_ms = 0
						if resource_terrain_stats and resource_terrain_stats.error
							and resource_terrain_stats.error ~= "" then
							error("outer resource terrain preparation failed: "
								.. tostring(resource_terrain_stats.error))
						end
						if resource_terrain_changed == true then
							local resource_rebuild_started = GetPreciseTicks()
							SuperBigMap.GenerationGrids.RebuildOuterResourceRingOrFinal(
								map, resource_terrain_stats and resource_terrain_stats.ring_sectors,
								"after outer resource terrain preparation")
							resource_rebuild_ms = GetPreciseTicks() - resource_rebuild_started
							-- TopUpDeposits may have published candidates validated against the old grids.
							-- Force anomaly/effect selection to observe the rebuilt terrain instead.
							if type(deposits.ClearTopUpPlacementPool) == "function" then
								deposits.ClearTopUpPlacementPool(map)
							end
						end
						local resource_terrain_ok, resource_terrain_audit =
							TerrainCopy.AuditOuterResourceTerrain(map)
						local first_resource_failures = tonumber(resource_terrain_audit
							and resource_terrain_audit.resource_failures) or 0
						local first_rocket_failures = tonumber(resource_terrain_audit
							and resource_terrain_audit.rocket_failures) or 0
						local first_resource_failure = tostring(resource_terrain_audit
							and resource_terrain_audit.first_resource_failure or "")
						local first_rocket_failure = tostring(resource_terrain_audit
							and resource_terrain_audit.first_rocket_failure or "")
						-- A whole-map buildable-grid rebuild can occasionally reject a footprint that
						-- was valid on the pre-edit grid even though no local height cell was touched.
						-- Feed that authoritative verdict back through the same scenario-agnostic
						-- preparation pass. On retries, every valid site is protected and only failed
						-- extractor/collection or landing footprints are shaped. This is bounded so a
						-- genuine policy failure remains fail-closed instead of looping indefinitely.
						local terrain_repair_attempt = 0
						local resource_repair_prepare_ms, resource_repair_rebuild_ms = 0, 0
						while resource_terrain_ok ~= true and terrain_repair_attempt < 2
							and resource_terrain_audit
							and ((tonumber(resource_terrain_audit.resource_failures) or 0) > 0
								or (tonumber(resource_terrain_audit.rocket_failures) or 0) > 0) do
							terrain_repair_attempt = terrain_repair_attempt + 1
							local repair_prepare_started = GetPreciseTicks()
							local repair_changed, repair_stats = TimedSafeCall(
								"surface repair failed outer resource terrain", map,
								TerrainCopy.PrepareOuterResourceTerrain, map)
							resource_repair_prepare_ms = resource_repair_prepare_ms
								+ (GetPreciseTicks() - repair_prepare_started)
							if repair_stats and repair_stats.error and repair_stats.error ~= "" then
								error("outer resource terrain repair failed: "
									.. tostring(repair_stats.error))
							end
							if repair_changed ~= true then break end
							local repair_rebuild_started = GetPreciseTicks()
							SuperBigMap.GenerationGrids.RebuildOuterResourceRingOrFinal(map,
								repair_stats and repair_stats.ring_sectors,
								"after outer resource terrain repair "
									.. tostring(terrain_repair_attempt))
							resource_repair_rebuild_ms = resource_repair_rebuild_ms
								+ (GetPreciseTicks() - repair_rebuild_started)
							if type(deposits.ClearTopUpPlacementPool) == "function" then
								deposits.ClearTopUpPlacementPool(map)
							end
							resource_terrain_ok, resource_terrain_audit =
								TerrainCopy.AuditOuterResourceTerrain(map)
						end
						local final_resource_terrain_report =
							map.SuperBigMapOuterResourceTerrainReport
						if type(final_resource_terrain_report) == "table" then
							final_resource_terrain_report.initial_prepare_ms = resource_prepare_ms
							final_resource_terrain_report.initial_rebuild_ms = resource_rebuild_ms
							final_resource_terrain_report.repair_attempts = terrain_repair_attempt
							final_resource_terrain_report.repair_prepare_ms = resource_repair_prepare_ms
							final_resource_terrain_report.repair_rebuild_ms = resource_repair_rebuild_ms
							final_resource_terrain_report.first_resource_failures = first_resource_failures
							final_resource_terrain_report.first_rocket_failures = first_rocket_failures
							final_resource_terrain_report.first_resource_failure = first_resource_failure
							final_resource_terrain_report.first_rocket_failure = first_rocket_failure
							final_resource_terrain_report.initial_native_precondition_enabled =
								resource_terrain_stats and resource_terrain_stats.native_precondition_enabled
							final_resource_terrain_report.initial_native_precondition_patches =
								resource_terrain_stats and resource_terrain_stats.native_precondition_patches
							final_resource_terrain_report.initial_native_precondition_sites =
								resource_terrain_stats and resource_terrain_stats.native_precondition_sites
							final_resource_terrain_report.initial_native_precondition_cells =
								resource_terrain_stats and resource_terrain_stats.native_precondition_cells
							final_resource_terrain_report.initial_native_raster_cells =
								resource_terrain_stats and resource_terrain_stats.native_raster_cells
							final_resource_terrain_report.initial_native_mask_samples =
								resource_terrain_stats and resource_terrain_stats.native_mask_samples
							local ring_rebuild = map.SuperBigMapOuterResourceRingRebuildReport
							final_resource_terrain_report.ring_rebuild_requested =
								type(ring_rebuild) == "table" and ring_rebuild.requested == true
							final_resource_terrain_report.ring_rebuild_used =
								type(ring_rebuild) == "table" and ring_rebuild.used == true
							final_resource_terrain_report.ring_rebuild_fallback =
								type(ring_rebuild) == "table" and ring_rebuild.fallback == true
							final_resource_terrain_report.ring_rebuild_boxes =
								type(ring_rebuild) == "table" and ring_rebuild.boxes or 0
							final_resource_terrain_report.ring_rebuild_passability_ms =
								type(ring_rebuild) == "table" and ring_rebuild.passability_ms or 0
							final_resource_terrain_report.ring_rebuild_buildable_ms =
								type(ring_rebuild) == "table" and ring_rebuild.buildable_ms or 0
							final_resource_terrain_report.ring_rebuild_total_ms =
								type(ring_rebuild) == "table" and ring_rebuild.total_ms or 0
							final_resource_terrain_report.ring_rebuild_calls =
								type(ring_rebuild) == "table" and ring_rebuild.calls or 0
							final_resource_terrain_report.ring_rebuild_fallbacks =
								type(ring_rebuild) == "table" and ring_rebuild.fallbacks or 0
							final_resource_terrain_report.ring_rebuild_error =
								type(ring_rebuild) == "table" and ring_rebuild.error or "not requested"
							final_resource_terrain_report.ring_rebuild_error_history =
								type(ring_rebuild) == "table" and ring_rebuild.error_history or "not requested"
						end
						if resource_terrain_ok ~= true then
							error("outer resource terrain audit failed: resource_failures="
								.. tostring(resource_terrain_audit
									and resource_terrain_audit.resource_failures)
								.. " rocket_failures=" .. tostring(resource_terrain_audit
									and resource_terrain_audit.rocket_failures)
								.. " cluster_shortfall=" .. tostring(resource_terrain_audit
									and resource_terrain_audit.cluster_shortfall)
								.. " cluster_excess=" .. tostring(resource_terrain_audit
									and resource_terrain_audit.cluster_excess)
								.. " cluster_resource_excess="
								.. tostring(resource_terrain_audit
									and resource_terrain_audit.cluster_resource_excess)
								.. " cluster_extractor_shortfall="
								.. tostring(resource_terrain_audit
									and resource_terrain_audit.cluster_extractor_shortfall)
								.. " cluster_extractor_excess="
								.. tostring(resource_terrain_audit
									and resource_terrain_audit.cluster_extractor_excess)
								.. " first_resource_failure=" .. tostring(resource_terrain_audit
									and resource_terrain_audit.first_resource_failure)
								.. " first_rocket_failure=" .. tostring(resource_terrain_audit
									and resource_terrain_audit.first_rocket_failure))
						end
						-- TopUpAnomalies: post-gen replacement for the in-generation anomaly count
						-- scaling (which shifted the generator's random stream and made expanded
						-- layouts diverge from vanilla).
						if type(deposits.TopUpAnomalies) == "function" then
							TimedSafeCall("surface top-up anomalies", map,
								deposits.TopUpAnomalies, map)
						end
						if type(deposits.TopUpEffectDeposits) == "function" then
							TimedSafeCall("surface top-up effect deposits", map,
								deposits.TopUpEffectDeposits, map)
						end
						if type(deposits.RegisterClonedMarkers) == "function" then
							TimedSafeCall("surface register top-up markers", map,
								deposits.RegisterClonedMarkers, map)
						end
						if type(deposits.ResolveBadgeMarkerOverlaps) == "function" then
							TimedSafeCall("surface resolve marker overlaps", map,
								deposits.ResolveBadgeMarkerOverlaps, map, "surface density suite")
						end
						if type(deposits.AuditTopUpVanillaRepulsion) ~= "function" then
							error("top-up spacing audit is unavailable")
						end
						local repulsion_token = LoadingBegin("surface hard top-up spacing audit", map)
						local repulsion_ok, repulsion_stats =
							deposits.AuditTopUpVanillaRepulsion(map, "surface final after density suite")
						LoadingEnd(repulsion_token, {
							markers = repulsion_stats and repulsion_stats.markers,
							topups = repulsion_stats and repulsion_stats.topups,
							density_status = repulsion_stats and repulsion_stats.density_status,
							duplicate_hex_pairs = repulsion_stats and repulsion_stats.duplicate_hex_pairs,
							first_duplicate_hex_pair = repulsion_stats
								and repulsion_stats.first_duplicate_hex_pair,
							violations = repulsion_stats and repulsion_stats.repulsion_violations,
							first_repulsion_violation = repulsion_stats
								and repulsion_stats.first_repulsion_violation,
							outer_ring_spacing_violations = repulsion_stats
								and repulsion_stats.outer_ring_spacing_violations,
							surface_quota_topups = repulsion_stats
								and repulsion_stats.surface_quota_topups,
							surface_quota_spacing_violations = repulsion_stats
								and repulsion_stats.surface_quota_spacing_violations,
						}, repulsion_ok == true)
						if repulsion_ok ~= true then
							error("surface top-up spacing audit failed: density_failures="
								.. tostring(repulsion_stats and repulsion_stats.density_failures)
								.. " duplicate_hex_pairs="
								.. tostring(repulsion_stats and repulsion_stats.duplicate_hex_pairs)
								.. " first_duplicate_hex_pair="
								.. tostring(repulsion_stats
									and repulsion_stats.first_duplicate_hex_pair)
								.. " repulsion_violations="
								.. tostring(repulsion_stats and repulsion_stats.repulsion_violations)
								.. " outer_ring_spacing_violations="
								.. tostring(repulsion_stats
									and repulsion_stats.outer_ring_spacing_violations)
								.. " surface_quota_spacing_violations="
								.. tostring(repulsion_stats
									and repulsion_stats.surface_quota_spacing_violations)
								.. " first_surface_quota_spacing_violation="
								.. tostring(repulsion_stats
									and repulsion_stats.first_surface_quota_spacing_violation)
								.. " first_repulsion_violation="
								.. tostring(repulsion_stats
									and repulsion_stats.first_repulsion_violation))
						end
						if type(deposits.AuditSurfaceTopUpPlacement) == "function" then
							local ring_ok, ring_stats = TimedSafeCall("surface top-up placement audit", map,
								deposits.AuditSurfaceTopUpPlacement, map)
							if ring_ok ~= true then
								error("surface top-up placement audit failed: violations="
									.. tostring(ring_stats and ring_stats.violations)
									.. " overlap=" .. tostring(ring_stats and ring_stats.anomaly_overlap)
									.. " outside_ring="
									.. tostring(ring_stats and ring_stats.anomaly_outside_ring)
									.. " fallback_inside_ring="
									.. tostring(ring_stats and ring_stats.anomaly_fallback_inside_ring)
									.. " sector_overflow="
									.. tostring(ring_stats and ring_stats.anomaly_sector_overflow)
									.. " cluster_overflow="
									.. tostring(ring_stats
										and ring_stats.anomaly_resource_cluster_overflow)
									.. " cluster_total_overflow="
									.. tostring(ring_stats
										and ring_stats.cluster_total_member_overflow)
									.. " quota_resources="
									.. tostring(ring_stats
										and ring_stats.resource_quota_topups)
									.. " quota_shortfall="
									.. tostring(ring_stats
										and ring_stats.resource_quota_shortfall)
									.. " outermost_quota_shortfall="
									.. tostring(ring_stats
										and ring_stats.resource_outermost_quota_shortfall)
									.. " inner_band_quota_shortfall="
									.. tostring(ring_stats
										and ring_stats.resource_inner_band_quota_shortfall))
							end
						end
						if type(deposits.CensusFinalOuterResourceTopUps) == "function" then
							local quota_ok, quota_stats = deposits.CensusFinalOuterResourceTopUps(map,
								"pre-reveal marker census surface final", false)
							map.SuperBigMapOuterResourceCensusPreGameInit = quota_stats
							if quota_ok ~= true then
								error("outer resource top-up census failed: ordinary_resource_topups="
									.. tostring(quota_stats and quota_stats.ordinary_resource_topups)
									.. " anomaly_topups=" .. tostring(quota_stats and quota_stats.anomaly_topups)
									.. " anomaly_topups_total="
									.. tostring(quota_stats and quota_stats.anomaly_topups_total)
									.. " anomaly_topups_outside_ring="
									.. tostring(quota_stats and quota_stats.anomaly_topups_outside_ring)
									.. " effect_topups=" .. tostring(quota_stats and quota_stats.effect_topups)
									.. " native_resources=" .. tostring(quota_stats and quota_stats.native_resources)
									.. " shortfall=" .. tostring(quota_stats and quota_stats.shortfall)
									.. " outermost_shortfall="
									.. tostring(quota_stats and quota_stats.outermost_shortfall)
									.. " inner_band_shortfall="
									.. tostring(quota_stats and quota_stats.inner_band_shortfall)
									.. " anomaly_cluster_overflow="
									.. tostring(quota_stats
										and quota_stats.anomaly_resource_cluster_overflow)
									.. " cluster_total_overflow="
									.. tostring(quota_stats
										and quota_stats.cluster_total_member_overflow))
							end
						end
						if type(deposits.SchedulePostDeferredSurfaceResourceTopUpCensus) == "function" then
							deposits.SchedulePostDeferredSurfaceResourceTopUpCensus(map,
								"surface final density suite")
						end
						if type(deposits.DebugAuditFinalEnrichments) == "function" then
							local audit_token = LoadingBegin("diagnostic surface enrichment audit", map)
							local call_ok, audit_ok, audit_stats = pcall(
								deposits.DebugAuditFinalEnrichments, map,
								"surface final before placement-pool cleanup")
							LoadingEnd(audit_token, {
								audit_ok = tostring(audit_ok),
								error = call_ok and "" or tostring(audit_ok),
								markers = call_ok and audit_stats and audit_stats.markers or nil,
							}, call_ok and audit_ok ~= false)
						end
						if type(deposits.ClearTopUpPlacementPool) == "function" then
							deposits.ClearTopUpPlacementPool(map)
						end
					end
				end
				if cfg_bool("EXPANSION_STEP_11_REBUILD_GAMEPLAY_GRIDS", true) then
					-- The cheap underground bootstrap records the vanilla underground source hex before
					-- this surface exists in its stretched form. Project that authoritative hex onto the
					-- final surface now. Use it exactly when its full footprint is valid; otherwise commit
					-- the nearest valid surface-only hex without forcing early underground expansion.
					local maps = Global("Maps")
					if type(maps) == "table" and type(AlignPassagePairsToSharedHex) == "function" then
						local seen_underground = {}
						for slot, underground_map in pairs(maps) do
							local underground_environment = underground_map and underground_map.mapdata
								and underground_map.mapdata.Environment
							if slot ~= 1 and underground_environment == "Underground"
								and not seen_underground[underground_map]
								and underground_map.SuperBigMapPassageBootstrapComplete == true
								and underground_map.SuperBigMapPassageSurfaceFinalCommitted ~= true
								and underground_map.SuperBigMapUndergroundStretchDone ~= true then
								seen_underground[underground_map] = true
								local plan_ok, plan_stats = AlignPassagePairsToSharedHex(underground_map, {
									source_bootstrap = true,
									prepare_surface_pad = true,
								})
								if plan_ok ~= true then
									error("final surface passage commitment failed: "
										.. tostring(plan_stats and plan_stats.error or "unknown error")
										.. (plan_stats and plan_stats.reason
											and (": " .. tostring(plan_stats.reason)) or ""))
								end
								underground_map.SuperBigMapPassageSurfaceFinalCommitted = true
							end
						end
					end
					-- Now every surface passage owns its immutable final coordinate. Scale the remaining
					-- entrance structures and place each badge relative to that coordinate exactly once.
					if type(MoveEntranceVisualsToScale) == "function" then
						SetLoadingPhase("Aligning the underground entrances")
						MoveEntranceVisualsToScale(map)
					end
				end
				local rockets = SuperBigMap.RocketRules
				if rockets and type(rockets.ResnapRocketsOnMap) == "function" then
					SafeCall( rockets.ResnapRocketsOnMap, map)
				end
				-- The first overview can begin before temporary-source objects are migrated.
				-- Initialize the final passage and badge synchronously now that their final
				-- positions exist; otherwise vanilla first sees them on the next zoom event.
				local highlight = SuperBigMap.SectorHighlight
				if highlight and type(highlight.EnsureEntranceVisualsReady) == "function" then
					highlight.EnsureEntranceVisualsReady(map, nil, "surface stretch complete")
				end
				-- LAST WORD ON THE SURFACE GAMEPLAY GRIDS, the exact counterpart of the underground's
				-- closing rebuild. Everything above -- the density suite, the passage commitment, the
				-- entrance-visual and rocket moves and this synchronous visual init -- runs inside
				-- object-grid transactions, and the engine re-derives passability over the regions each
				-- one touches when the last SuspendPassEdits reason clears. Measured (iteration 041,
				-- from the 039 call trace): the surface's last traced pass work is the combined resume
				-- and the buildable rebuild above, after which its passability digest still moves twice
				-- with nothing rebuilding it -- while the underground, which does close this way, lost
				-- 42 of 86 at-object and 323 of 706 object-free twin differences at v809-v811 and the
				-- surface lost none. Idempotent, whole-map, same engine sequence as both other sites.
				if cfg_bool("EXPANSION_STEP_11_REBUILD_GAMEPLAY_GRIDS", true) then
					SetLoadingPhase("Finalizing surface gameplay grids")
					SuperBigMap.GenerationGrids.RebuildFinal(map, "after last object-grid transaction")
				end
			end)
			-- Error-path cleanup. On the normal path the transaction was already resumed above.
			local cleanup_ok, cleanup_err = ResumeCombinedPassEdits("surface stretch cleanup", true)
			if not cleanup_ok then
				if ok_branch then
					ok_branch = false
					branch_err = "surface pass-edit cleanup failed: " .. tostring(cleanup_err)
				else
					branch_err = tostring(branch_err) .. " | pass-edit cleanup failed: "
						.. tostring(cleanup_err)
				end
			end
			LoadingEnd(surface_pipeline_token, {
				terrain_grids = n_grids, error = ok_branch and "" or tostring(branch_err),
			}, ok_branch)
			-- Balanced resume (always, even on error) so the loop detector is restored.
			if type(resume_ild) == "function" then SafeCall(resume_ild, "SuperBigMapStretch") end
			if type(ClearDecorRelief) == "function" then ClearDecorRelief(map) end
			if ok_branch and map.SuperBigMapStretchPipelinePending == true then
				FinalizeDeferredStretchState(map, "surface")
			end
			-- CityInit spawned the tunnel markers, their signs, the revealed deposits, and every
			-- attached effect AFTER the native population was transferred, so none of them carry a
			-- native stamp. Record which vanilla object each one derives from now that they are all
			-- placed; this only writes SuperBigMapProvenance* fields and moves nothing.
			do
				local provenance = SuperBigMap.Provenance
				if provenance and type(provenance.Propagate) == "function" then
					SafeCall(provenance.Propagate, map, "surface stretch complete")
				end
			end
			-- ALWAYS mark done + expanded and close the loading box, even on error, so the game
			-- never hangs on the loading screen.
			map.SuperBigMapSurfaceStretchDone = true
			map.SuperBigMapExpanded = true
			end_loading()
			SignalExpansionReadinessChanged(map, "surface stretch complete")
			LoadingFinish("surface expansion complete", map, {
				terrain_grids = n_grids, error = ok_branch and "" or tostring(branch_err),
			}, ok_branch)
			return
		end

		end)
		-- The surface aggregate is not canonical until the generation thread yields once, even
		-- though its exposed pass grids already match stock control. Measured by t120x: the first
		-- real-time-thread entry after this protected pipeline is the earliest stable boundary, and
		-- one ordinary RebuildFinal there is sufficient. Keep the immediate call above for ordering
		-- and queue this surface-only revalidation exactly once after a successful pipeline return.
		if thread_ok
			and cfg_bool("EXPANSION_STEP_11_REBUILD_GAMEPLAY_GRIDS", true)
			and map.SuperBigMapSurfacePostPipelineRevalidationScheduled ~= true then
			map.SuperBigMapSurfacePostPipelineRevalidationScheduled = true
			map.SuperBigMapSurfacePostPipelineRevalidationComplete = nil
			map.SuperBigMapSurfacePostPipelineRevalidationError = nil
			local revalidation_schedule_ok, revalidation_schedule_err = pcall(create_thread, function()
				local pause_ild = Global("PauseInfiniteLoopDetection")
				local resume_ild = Global("ResumeInfiniteLoopDetection")
				if type(pause_ild) == "function" then
					SafeCall(pause_ild, "SuperBigMapSurfacePostPipelineRevalidation")
				end
				local revalidation_ok, revalidation_err = yield_protected_call(function()
					SuperBigMap.GenerationGrids.RebuildFinal(
						map, "post-pipeline scheduled revalidation")
				end)
				if type(resume_ild) == "function" then
					SafeCall(resume_ild, "SuperBigMapSurfacePostPipelineRevalidation")
				end
				if revalidation_ok then
					map.SuperBigMapSurfacePostPipelineRevalidationComplete = true
				else
					map.SuperBigMapSurfacePostPipelineRevalidationError = tostring(revalidation_err)
					LoadingFinish("surface post-pipeline revalidation failed", map, {
						error = tostring(revalidation_err),
					}, false)
				end
			end)
			if not revalidation_schedule_ok then
				map.SuperBigMapSurfacePostPipelineRevalidationScheduled = nil
				thread_ok = false
				thread_err = "surface post-pipeline revalidation scheduling failed: "
					.. tostring(revalidation_schedule_err)
			end
		end
		if not thread_ok then
			if map.SuperBigMapStretchPipelinePending == true then
				local lifecycle = SuperBigMap.Lifecycle
				if lifecycle and type(lifecycle.Apply) == "function" then
					SafeCall(lifecycle.Apply, map, true)
				end
			end
			map.SuperBigMapStretchPipelinePending = false
			map.SuperBigMapSurfaceStretchScheduled = false
			EndSurfaceExpansionLoading(map)
			LoadingFinish("surface expansion thread failed", map,
				{ error = tostring(thread_err or thread_ok) }, false)
		end
	end)
	if not schedule_ok then
		map.SuperBigMapStretchPipelinePending = false
		map.SuperBigMapSurfaceStretchScheduled = false
		EndSurfaceExpansionLoading(map)
	end
	return schedule_ok == true
end


local function SyncMapDataToGrids(map)
	local terrain_api = Global("terrain")
	if type(terrain_api) ~= "table" then
		return false
	end
	if type(terrain_api.HeightMapSize) ~= "function" then
		return false
	end
	local mapdata = map and map.mapdata
	if type(mapdata) ~= "table" then
		return false
	end
	local ok, gw, gh = pcall(terrain_api.HeightMapSize, map)
	if not ok or type(gw) ~= "number" or gw <= 0 then
		return false
	end
	gh = type(gh) == "number" and gh or gw

	local old_w = type(mapdata.Width) == "number" and mapdata.Width or 0
	local old_h = type(mapdata.Height) == "number" and mapdata.Height or 0
	if old_w == gw and old_h == gh then
		return false
	end

	-- Preserve original size so RestoreVanillaBehavior can put it back if the
	-- mod is disabled mid-session.
	if mapdata.SuperBigMapOriginalMapDataWidth == nil then
		mapdata.SuperBigMapOriginalMapDataWidth = old_w
	end
	if mapdata.SuperBigMapOriginalMapDataHeight == nil then
		mapdata.SuperBigMapOriginalMapDataHeight = old_h
	end

	mapdata.Width = gw
	mapdata.Height = gh
	return true
end

-- The generation stamps used by the stretch are transient ordinary map fields. Preserve their
-- primitive values in one MapVar while work is deferred, so saving on the surface and reloading
-- before first underground access cannot lose the transform geometry and expose a source-layout
-- underground. Restoring is idempotent and does not overwrite live generation stamps.
local function RestoreDeferredUndergroundGeometry(map)
	local g = map and map.SuperBigMapUndergroundDeferredGeometry
	if type(g) ~= "table" then return false end
	local fields = {
		SuperBigMapDesiredWidthTiles = "desired_width_tiles",
		SuperBigMapDesiredHeightTiles = "desired_height_tiles",
		SuperBigMapGeneratorWidthTiles = "generator_width_tiles",
		SuperBigMapGeneratorHeightTiles = "generator_height_tiles",
		SuperBigMapSourceWidthTiles = "source_width_tiles",
		SuperBigMapSourceHeightTiles = "source_height_tiles",
		SuperBigMapSourceWidth = "source_width",
		SuperBigMapSourceHeight = "source_height",
	}
	for field, key in pairs(fields) do
		if map[field] == nil and type(g[key]) == "number" then map[field] = g[key] end
	end
	return true
end

local function SaveDeferredUndergroundGeometry(map)
	if not map then return false end
	map.SuperBigMapUndergroundDeferredGeometry = {
		desired_width_tiles = map.SuperBigMapDesiredWidthTiles,
		desired_height_tiles = map.SuperBigMapDesiredHeightTiles,
		generator_width_tiles = map.SuperBigMapGeneratorWidthTiles,
		generator_height_tiles = map.SuperBigMapGeneratorHeightTiles,
		source_width_tiles = map.SuperBigMapSourceWidthTiles,
		source_height_tiles = map.SuperBigMapSourceHeightTiles,
		source_width = map.SuperBigMapSourceWidth,
		source_height = map.SuperBigMapSourceHeight,
	}
	return true
end

-- STRETCH for the UNDERGROUND map (config STRETCH_UNDERGROUND): the same resample pipeline as the
-- surface in its underground form -- terrain grids + decorations + markers (incl. tunnel markers),
-- final buildable/passability grids, and enrichment density normalization. The underground's
-- transformed vanilla passage hex is authoritative. Surface loading projects that hex onto the
-- final surface and commits the nearest valid surface-only fallback when the exact footprint is
-- uneven, blocked, or unbuildable. Triggered from PostNewMapLoaded for Environment=="Underground"
-- maps; gates on the expansion sizes stamped by the DoGenerate wrapper (desired > generator).
function SuperBigMap.GenerationReadiness.LegacyUndergroundEvidence(map)
	if type(map) ~= "table" then
		return false, "underground map object is unavailable"
	end
	local mapdata = map.mapdata
	if type(mapdata) ~= "table" or mapdata.Environment ~= "Underground" then
		return false, "map is not underground"
	end
	if map.SuperBigMapUndergroundPreparationFailed == true then
		return false, "saved underground records a failed preparation"
	end
	local grid = SuperBigMap.SectorGrid
	if type(grid) ~= "table" or type(grid.IsModMap) ~= "function"
		or grid.IsModMap(map) ~= true then
		return false, "map is not a Super Big Map underground"
	end

	-- A previously completed underground is authoritative even if it predates the readiness
	-- MapVars. This branch only normalizes the new persistence schema; it never runs terrain work.
	if map.SuperBigMapUndergroundPrepared == true or map.SuperBigMapExpanded == true then
		return true, "legacy underground already records completed preparation"
	end

	-- Unprepared legacy saves need stronger evidence. The expanded preset must retain its native
	-- source dimensions and the saved underground city must own a complete rectangular exploration
	-- grid. InitExploration builds that grid immediately before CityInitialized, after native random
	-- generation has returned, so this is persisted proof of both missing milestones. Merely having
	-- an allocated 8192 map is insufficient and deliberately does not pass this check.
	-- Deferred geometry was already persisted by the affected releases. Prefer live stamps, but
	-- validate directly against that MapVar when load has not yet restored its transient copies.
	local geometry = map.SuperBigMapUndergroundDeferredGeometry
	geometry = type(geometry) == "table" and geometry or {}
	local source_width = map.SuperBigMapSourceWidthTiles
		or geometry.source_width_tiles or mapdata.SuperBigMapSourceWidthTiles
	local source_height = map.SuperBigMapSourceHeightTiles
		or geometry.source_height_tiles or mapdata.SuperBigMapSourceHeightTiles
	local desired_width = map.SuperBigMapDesiredWidthTiles
		or geometry.desired_width_tiles or mapdata.Width
	local desired_height = map.SuperBigMapDesiredHeightTiles
		or geometry.desired_height_tiles or mapdata.Height
	if type(source_width) ~= "number" or type(source_height) ~= "number"
		or source_width <= 0 or source_height <= 0 then
		return false, "saved native source dimensions are missing"
	end
	if type(desired_width) ~= "number" or type(desired_height) ~= "number"
		or desired_width <= source_width or desired_height <= source_height then
		return false, "saved underground is not an expanded deferred geometry"
	end

	local city = map.City
	local sectors = city and city.MapSectors
	if type(sectors) ~= "table" or #sectors <= 0 then
		return false, "saved underground exploration grid is missing"
	end
	local count_x = #sectors
	local count_y = type(sectors[1]) == "table" and #sectors[1] or 0
	if count_y <= 0 then
		return false, "saved underground exploration grid has no rows"
	end
	for col = 1, count_x do
		if type(sectors[col]) ~= "table" or #sectors[col] ~= count_y then
			return false, "saved underground exploration grid is incomplete"
		end
	end
	for col = 1, count_x do
		for row = 1, count_y do
			local sector = sectors[col][row]
			if not sector or not sector.area then
				return false, "saved underground sector geometry is incomplete"
			end
		end
	end
	return true, "legacy save contains a complete underground city and sector grid"
end

function SuperBigMap.GenerationReadiness.RecoverPersistedUnderground(map, source)
	if type(map) ~= "table" then return false, "map unavailable" end
	if map.SuperBigMapNativeGenerationComplete == true
		and map.SuperBigMapCityInitializationComplete == true then
		-- Saves made after the persistence fix already carry both bits. Stamp the schema if this
		-- session hot-reloaded across the version boundary, but otherwise leave them untouched.
		map.SuperBigMapGenerationReadinessVersion = SuperBigMap.GenerationReadiness.VERSION
		return false, "generation readiness already complete"
	end
	if map.SuperBigMapGenerationReadinessVersion == SuperBigMap.GenerationReadiness.VERSION then
		-- A current-schema save explicitly persisted incomplete state. Do not reinterpret it as a
		-- legacy omission: keeping the safety gate closed is the only non-destructive response.
		return false, "current readiness schema records incomplete generation"
	end

	local valid, evidence = SuperBigMap.GenerationReadiness.LegacyUndergroundEvidence(map)
	if not valid then return false, evidence end
	map.SuperBigMapNativeGenerationComplete = true
	map.SuperBigMapNativeGenerationCompleteSource =
		"legacy save recovery: " .. tostring(source or "LoadGame")
	map.SuperBigMapCityInitializationComplete = true
	map.SuperBigMapGenerationReadinessVersion = SuperBigMap.GenerationReadiness.VERSION
	SignalExpansionReadinessChanged(map, map.SuperBigMapNativeGenerationCompleteSource)
	LoadingStep("legacy underground generation readiness recovered", {
		source = tostring(source or "LoadGame"), evidence = tostring(evidence),
	}, map)
	return true, evidence
end

function SuperBigMap.GenerationReadiness.RecoverLoadedUnderground(source)
	local seen = {}
	local recovered = 0
	local inspected = 0
	local function inspect(map)
		if type(map) ~= "table" or seen[map] then return end
		seen[map] = true
		local mapdata = map.mapdata
		if type(mapdata) ~= "table" or mapdata.Environment ~= "Underground" then return end
		inspected = inspected + 1
		if SuperBigMap.GenerationReadiness.RecoverPersistedUnderground(map, source) == true then
			recovered = recovered + 1
		end
	end

	local loaded_maps = Global("LoadedMaps")
	if type(loaded_maps) == "table" then
		for _, map in ipairs(loaded_maps) do inspect(map) end
	end
	local maps = Global("Maps")
	if type(maps) == "table" then
		for _, map in pairs(maps) do inspect(map) end
	end
	inspect(Global("CurrentMap"))
	inspect(Global("MainMap"))
	return recovered, inspected
end

local function UndergroundExpansionReadiness(map)
	if map.SuperBigMapNativeGenerationComplete ~= true then
		return false, "underground native generation has not completed"
	end
	if map.SuperBigMapCityInitializationComplete ~= true then
		return false, "underground city initialization has not completed"
	end
	local surface = Global("MainMap")
	if type(surface) ~= "table" or surface == map then
		return true, "native generation complete; no surface dependency"
	end
	if not cfg_bool("SURFACE_STRETCH_AT_START", false) then
		return true, "native generation complete; surface expansion disabled"
	end
	local grid = SuperBigMap.SectorGrid
	if type(grid) == "table" and type(grid.IsModMap) == "function"
		and grid.IsModMap(surface) ~= true then
		return true, "native generation complete; surface is not a mod map"
	end
	if surface.SuperBigMapSurfaceStretchDone == true
		or (surface.SuperBigMapExpanded == true
			and surface.SuperBigMapExpansionPending ~= true
			and surface.SuperBigMapStretchPipelinePending ~= true) then
		return true, "native generation and surface expansion complete"
	end
	return false, "surface expansion transaction has not completed"
end

local function RunUndergroundStretchIfEnabled(map, force_now)
	if not cfg_bool("STRETCH_UNDERGROUND", false) then
		return false, "underground stretch is disabled"
	end
	map = map or Global("CurrentMap")
	if not map then
		return false, "underground target map is missing"
	end
	RestoreDeferredUndergroundGeometry(map)
	if map.SuperBigMapExpanded == true and map.SuperBigMapExpansionPending ~= true then
		map.SuperBigMapUndergroundPrepared = true
		map.SuperBigMapUndergroundStretchDone = true
		map.SuperBigMapUndergroundStretchPending = false
	end
	if map.SuperBigMapUndergroundPrepared == true then
		map.SuperBigMapUndergroundStretchDone = true
		map.SuperBigMapUndergroundStretchPending = false
	end
	if map.SuperBigMapUndergroundStretchDone == true then
		return force_now == true and true or false
	end
	if map.SuperBigMapUndergroundPreparationFailed == true then
		return false, map.SuperBigMapUndergroundStretchFailed
			or "a previous underground preparation attempt failed"
	end
	if map.SuperBigMapUndergroundStretchRunning == true then
		if force_now == true then
			return false, "underground expansion already running"
		end
		return true, "underground expansion already running"
	end
	local desired = map.SuperBigMapDesiredWidthTiles
	local gen_t = map.SuperBigMapGeneratorWidthTiles
	if not (type(desired) == "number" and type(gen_t) == "number" and desired > gen_t) then
		return false
	end
	-- The source terrain, enrichments, and two linked passage anchors are eager. Buried-wonder
	-- construction and the expensive expansion/post-processing are postponed while the underground
	-- is not current. ChangeCurrentMapSlot is wrapped below and forces the complete pipeline before
	-- access; Elevator placement remains available meanwhile through the verified surface anchors.
	local current_map = Global("CurrentMap")
	-- A pre-v740 save can contain the deliberately deferred v739 underground source. Do not turn
	-- loading that save into an uninterruptible full 8192-grid migration; retain its first-access
	-- boundary. Newly generated games use the same configured first-access boundary.
	local loading_legacy_save = map.SuperBigMapOneToOneGenerationVersion ~= 1
		and map.SuperBigMapUndergroundStretchDone ~= true
	if force_now ~= true and (cfg_bool("DEFER_UNDERGROUND_EXPANSION_UNTIL_FIRST_ACCESS", false)
		or loading_legacy_save)
		and current_map ~= map then
		map.SuperBigMapUndergroundStretchPending = true
		map.SuperBigMapUndergroundStretchFailed = nil
		map.SuperBigMapUndergroundPreparationFailed = false
		SaveDeferredUndergroundGeometry(map)
		return true
	end
	local create_thread = Global("CreateRealTimeThread")
	local wait_msg = Global("WaitMsg")
	local ready_now, readiness_now = UndergroundExpansionReadiness(map)
	if force_now == true and not ready_now then
		return false, readiness_now
	end
	if force_now ~= true and (type(create_thread) ~= "function"
		or (not ready_now and type(wait_msg) ~= "function")) then
		return false, "required asynchronous engine functions are unavailable"
	end
	map.SuperBigMapUndergroundStretchPending = true
	map.SuperBigMapUndergroundStretchRunning = true
	map.SuperBigMapUndergroundStretchFailed = nil
	if cfg_bool("OPTIMIZE_STRETCH_DEFERRED_REBUILDS", true) then
		map.SuperBigMapStretchPipelinePending = true
	end
	local function run_pipeline()
		LoadingStart("underground expansion first access", map, {
			force_now = tostring(force_now == true),
		})
		local ready, readiness = UndergroundExpansionReadiness(map)
		while not ready do
			wait_msg("SuperBigMapExpansionReadinessChanged")
			ready, readiness = UndergroundExpansionReadiness(map)
		end
		-- LOADING PHASE starts only after dependencies are ready; waiting for engine events must
		-- never hold the player behind a timing-dependent loading screen.
		if type(SuperBigMap.ExpansionLoadingBegin) == "function" then
			pcall(SuperBigMap.ExpansionLoadingBegin, "underground")
			SetLoadingPhase("Expanding the underground map")
		end
		-- ExpansionLoadingBegin establishes its UI at render boundaries. Do not gate correctness on
		-- a fixed millisecond delay; the caller's retained cover remains authoritative throughout.
		local pause_ild = Global("PauseInfiniteLoopDetection")
		local resume_ild = Global("ResumeInfiniteLoopDetection")
		if type(pause_ild) == "function" then SafeCall(pause_ild, "SuperBigMapUndergroundStretch") end
		local elevator_migrations = {}
		local underground_pipeline_token = LoadingBegin("underground expansion pipeline", map)
		local transform_pass_reason = "SuperBigMapUndergroundObjectTransform"
		local transform_pass_batch_active = false
		local function ResumeUndergroundTransformPassEdits(ignore_errors)
			if not transform_pass_batch_active then return false, "batch inactive" end
			local resume_ok, resume_err = pcall(
				map.ResumePassEdits, map, transform_pass_reason, ignore_errors == true)
			-- Vanilla checks the captured GameTime before removing the named reason. If a normal resume
			-- asserts, retain ownership so the outer failure cleanup can balance the same reason with
			-- ignore_errors=true. Relinquish ownership only after the engine accepted the resume.
			if resume_ok then transform_pass_batch_active = false end
			return resume_ok, resume_err
		end
		-- The underground's two calls into the shared final gameplay-grid rebuild (defined above
		-- RunSurfaceStretchIfEnabled, where both pipelines can reach it): one before the
		-- reachability-filtered density suite, which needs live grids, and one more after the
		-- pipeline's LAST object-grid transaction.
		local function RebuildFinalUndergroundGameplayGrids(stage)
			return SuperBigMap.GenerationGrids.RebuildFinal(map, stage)
		end
		local ok_branch, branch_err = pcall(function()
			-- A surface Elevator may already be finished while its paired underground half is a
			-- pending site with a destroyed linked_obj. Snapshot/remove only that underground half
			-- before any position sweep; rebuild it after the final buildable grid exists.
			if type(BeginDeferredElevatorMigration) ~= "function"
				or type(RestoreDeferredElevatorMigration) ~= "function" then
				error("deferred Elevator migration helpers are unavailable")
			end
			elevator_migrations = BeginDeferredElevatorMigration(map)
			-- Vanilla constructs, flattens, and clears buried-wonder footprints on the native map.
			-- Deferred construction must preserve that transaction domain: create and clear now, while
			-- actual access has begun but before any relief annotation or 6144->8192 transform. The live
			-- wonder objects remain detached from grids until their markers reach final coordinates.
			do
				SetLoadingPhase("Preparing native underground wonder footprints")
				local source_wonder_ok, source_wonder_result =
					WonderVerticalDiagnostics.MaterializeDeferredUndergroundWondersOnSource(map)
				if source_wonder_ok ~= true then
					error("native-domain deferred wonder materialization failed: "
						.. tostring(source_wonder_result))
				end
			end
			-- Renderer bounds must cover the full 8192 grid (same fix as the surface).
			SafeCall( SyncMapDataToGrids, map)
			-- Relief annotations BEFORE the underground terrain stretch (same as the surface).
			if type(AnnotateDecorRelief) == "function" then
				AnnotateDecorRelief(map)
			end
			local position_deposits = SuperBigMap.DepositRules
			-- Preserve the complete vanilla underground population by value, not by object lifetime.
			-- This runs only when first access actually starts the stretch, so an intervening save/load
			-- still persists the original marker objects. The same records are recreated below after
			-- the final height/type grids exist.
			if not position_deposits
				or type(position_deposits.StageAndRemoveNativeEnrichmentsForStretch) ~= "function" then
				error("underground native enrichment staging API is unavailable")
			end
			SetLoadingPhase("Preserving vanilla underground resources and anomalies")
			local staged, stage_stats = position_deposits.StageAndRemoveNativeEnrichmentsForStretch(
				map, "underground immediately before terrain stretch")
			if staged ~= true then
				error("underground native enrichment staging failed: "
					.. tostring(stage_stats and stage_stats.error or "unknown error"))
			end
			SetLoadingPhase("Stretching the underground terrain")
			local ok_s, n_grids = true, 0
			if cfg_bool("EXPANSION_STEP_07_STRETCH_TERRAIN", true) then
				ok_s, n_grids = StretchSourceToFull(map)
				if ok_s ~= true or type(n_grids) ~= "number" or n_grids < 2 then
					error("underground terrain stretch did not complete its height/type grids")
				end
			end
			if cfg_bool("OPTIMIZE_UNDERGROUND_PASS_EDIT_BATCH", true)
				and type(map.SuspendPassEdits) == "function"
				and type(map.ResumePassEdits) == "function" then
				local suspend_ok, suspend_result = pcall(
					map.SuspendPassEdits, map, transform_pass_reason)
				transform_pass_batch_active = suspend_ok and suspend_result ~= false
			end
			if type(ScaleDecorationsToFull) == "function" then
				SetLoadingPhase("Repositioning underground rocks and decorations")
				ScaleDecorationsToFull(map, transform_pass_batch_active)
			end
			local feature_ok, feature_stats = RestoreTransferredPrefabFeatureGameLogic(map)
			if feature_ok ~= true then
				error("underground prefab feature correspondence failed: "
					.. tostring(feature_stats and feature_stats.error or "unknown error"))
			end
			SetLoadingPhase("Reserving underground wonder footprints")
			local reservation_ok, reservation_stats =
				WonderVerticalDiagnostics.ReserveDeferredUndergroundWonderFootprints(
					map, position_deposits)
			if reservation_ok ~= true then
				error("underground wonder footprint reservation failed: "
					.. tostring(reservation_stats and reservation_stats.error or "unknown error"))
			end
			-- Reconstruct every captured native marker directly at the identical proportional hex used
			-- by the surface transaction. Constructor properties are restored before Init and the
			-- complete class/property/coordinate record set is verified before top-ups can begin.
			if not position_deposits
				or type(position_deposits.RecreateStagedNativeEnrichments) ~= "function" then
				error("underground native enrichment recreation API is unavailable")
			end
			SetLoadingPhase("Restoring vanilla underground resources and anomalies")
			local recreated, recreate_stats = position_deposits.RecreateStagedNativeEnrichments(
				map, "underground after terrain and decoration stretch")
			if recreated ~= true then
				error("underground native enrichment recreation failed: "
					.. tostring(recreate_stats and recreate_stats.error or "unknown error"))
			end
			if type(ScaleMarkersToFull) == "function" then
				SetLoadingPhase("Repositioning underground resource deposits")
				local n_mark = ScaleMarkersToFull(map, false, transform_pass_batch_active)
				local position_deposits = SuperBigMap.DepositRules
				if position_deposits
					and type(position_deposits.VerifyNativeEnrichmentTransform) == "function" then
					local verified, verify_stats = position_deposits.VerifyNativeEnrichmentTransform(
						map, "underground after marker transform")
					if verified ~= true then
						error("native underground enrichment transformation verification failed (mismatches="
							.. tostring(verify_stats and verify_stats.mismatches or "unknown") .. ")")
					end
				end
			end
			if transform_pass_batch_active then
				local resume_token = LoadingBegin("underground resume combined pass edits", map)
				local resume_ok, resume_err = ResumeUndergroundTransformPassEdits()
				LoadingEnd(resume_token, {
					error = resume_ok and "" or tostring(resume_err),
				}, resume_ok)
				if not resume_ok then
					error("underground combined ResumePassEdits failed: " .. tostring(resume_err))
				end
			end
			-- Construction and vanilla obstruction clearing ran on the native source above. The markers
			-- have now received the same proportional transform as the terrain, so align, stretch, and
			-- seat each retained wonder without replaying clearance on the expanded object population.
			do
				SetLoadingPhase("Creating underground wonders")
				local wonder_ok, wonder_result = MaterializeDeferredUndergroundWonders(map)
				if wonder_ok ~= true then
					error("deferred underground wonder materialization failed: " .. tostring(wonder_result))
				end
			end
			-- Entrance visuals are finalized only after the authoritative underground coordinate has
			-- been cleared, prepared, moved, and validated against the final gameplay grids.
			-- Natural entrance objects still receive exactly one transformation (the stretch).
			-- The one exception is an Elevator already completed on the surface: its removed
			-- pending underground half is rebuilt later on its live underground passage/imprint.
			-- FINAL GRIDS FIRST. The consolidated terrain revalidation can report success on a
			-- non-current underground map before the Lua BuildableGrid has completed. v480 then
			-- sampled its stale pre-stretch grid and the authoritative rebuild happened only after
			-- CurrentMapChangeDone -- too late. Correctness wins here: synchronously rebuild final
			-- passability and buildability, invalidate every cached pool, and seed connectivity from
			-- the real underground entrances before any enrichment is accepted or moved.
			if cfg_bool("EXPANSION_STEP_11_REBUILD_GAMEPLAY_GRIDS", true) then
				SetLoadingPhase("Finalizing reachable underground terrain")
				-- Keep this explicit full-map rebuild even though the object transforms above now share one
				-- pass-edit transaction. The underground map is not necessarily CurrentMap, and a successful
				-- RebuildGrids/ResumePassEdits return does not prove that its asynchronous native pass grid is
				-- already current. This remains the authoritative synchronization point before reachability-
				-- constrained density placement -- but NOT the pipeline's last one: every object-grid
				-- transaction after it re-derives the regions it touches, so the same rebuild runs
				-- again once the last such transaction has closed (see
				-- RebuildFinalUndergroundGameplayGrids).
				RebuildFinalUndergroundGameplayGrids("before reachability and density")
				WonderVerticalDiagnostics.LogAll(map, "after_final_grid_rebuild")
				-- StretchSourceToFull may have deferred its intermediate RebuildGrids pass. Both final
				-- authoritative gameplay grids now exist against the completed terrain/object layout.
				map.SuperBigMapDeferredIntermediateTerrainRebuild = nil
				if #elevator_migrations > 0 then
					-- Reconstruction is never performed from inside the stretch pipeline. The records carry
					-- a monotonic generation token into CurrentMapChangeDone (or the explicit already-current
					-- lifecycle message emitted at the pipeline exit). That event is the sole authority to
					-- create the Elevator after every final grid exists on the current underground map.
					local token = QueueUndergroundElevatorRestore(map, elevator_migrations,
						Global("CurrentMap") == map and "already-current underground pipeline"
						or "pre-switch underground pipeline")
					if not token then error("failed to create underground Elevator restore transaction") end
				end
				if type(AlignPassagePairsToSharedHex) ~= "function" then
					error("final passage-pair alignment API is unavailable")
				end
				SetLoadingPhase("Aligning surface and underground passage entrances")
				local pair_ok, pair_stats = AlignPassagePairsToSharedHex(map)
				if pair_ok ~= true then
					error("final passage-pair alignment failed: "
						.. tostring(pair_stats and pair_stats.error or "unknown error")
						.. (pair_stats and pair_stats.reason
							and (": " .. tostring(pair_stats.reason)) or "")
						.. (pair_stats and pair_stats.underground_reason
							and ("; underground=" .. tostring(pair_stats.underground_reason)) or "")
						.. (pair_stats and pair_stats.surface_reason
							and ("; surface=" .. tostring(pair_stats.surface_reason)) or ""))
				end
				-- CityInitialized deliberately skipped SurfacePassage:Spawn while the source-sized
				-- buildable grid disagreed with the expanded object grid. Align and prepare the immutable
				-- true underground coordinate first, then create the deferred markers at that final
				-- position so they cannot masquerade as blockers or retain a stale source coordinate.
				SetLoadingPhase("Activating underground passage markers")
				local tunnel_ok, tunnel_result = MaterializeDeferredUndergroundTunnelSpawns(map)
				if tunnel_ok ~= true then
					error("deferred underground passage-marker activation failed: "
						.. tostring(tunnel_result))
				end
				-- SurfacePassage itself is vanilla's underground exit indicator
				-- (ElevatorBuildIndicator_Underground). Do not call SurfaceTunnelMarker:PlaceSign
				-- here: that creates the yellow SignUnderground badge, which vanilla only creates
				-- through its exploration/reveal lifecycle.
				if type(MoveEntranceVisualsToScale) == "function" then
					MoveEntranceVisualsToScale(map)
				end
				local indicator_ok, indicator_stats = RefreshVanillaUndergroundPassageIndicators(map)
				if indicator_ok ~= true then
					error("vanilla underground passage ground-indicator restoration failed: "
						.. tostring(indicator_stats and indicator_stats.error or "unknown error"))
				end
				local highlight = SuperBigMap.SectorHighlight
				if highlight and type(highlight.EnsureEntranceVisualsReady) == "function" then
					local visuals_ok, visuals_stats = highlight.EnsureEntranceVisualsReady(
						map, nil, "underground vanilla passage indicator ready")
					if visuals_ok ~= true then
						error("vanilla underground passage indicator activation failed: failed_calls="
							.. tostring(visuals_stats and visuals_stats.failed_calls or "unknown"))
					end
					local vanilla_passages = ArtefactMapGet(map, "SurfacePassage")
					ExpansionAudit("UNDERGROUND_VANILLA_PASSAGE_INDICATORS_READY", {
						vanilla_passages = #vanilla_passages,
						rebuilt = indicator_stats and indicator_stats.rebuilt or 0,
						decals = indicator_stats and indicator_stats.decals or 0,
						built_markers = indicator_stats and indicator_stats.built_markers or 0,
					}, map)
				end
				-- CityInitialized ran before deferred wonder construction, so restore the exact vanilla
				-- SpawnsAnomalyOnCityInit action now that its unobstructed-position query can use the
				-- authoritative underground grids. This covers all present buried-wonder classes.
				SetLoadingPhase("Restoring buried-wonder positions")
				local pre_anomaly_reseat_token = LoadingBegin(
					"underground reseat wonders before rare anomalies", map)
				local pre_anomaly_reseat_ok, pre_anomaly_reseat_stats =
					WonderVerticalDiagnostics.RestoreExpectedPositionsBeforeAnomalySpawn(
						map, "after final grids immediately before rare-anomaly spawn")
				LoadingEnd(pre_anomaly_reseat_token, pre_anomaly_reseat_stats,
					pre_anomaly_reseat_ok == true)
				if pre_anomaly_reseat_ok ~= true then
					error("buried-wonder pre-anomaly reseat failed: "
						.. tostring(pre_anomaly_reseat_stats
							and pre_anomaly_reseat_stats.error or "unknown error"))
				end
				SetLoadingPhase("Activating underground wonder anomalies")
				local wonder_anomaly_token = LoadingBegin(
					"underground activate buried wonder anomalies", map)
				local wonder_anomaly_ok, wonder_anomaly_stats =
					WonderVerticalDiagnostics.AuditDeferredUndergroundWonderAnomalies(
						map, true, "after final grids and passage activation")
				LoadingEnd(wonder_anomaly_token, wonder_anomaly_stats, wonder_anomaly_ok == true)
				if wonder_anomaly_ok ~= true then
					error("deferred underground wonder anomaly activation failed: "
						.. tostring(wonder_anomaly_stats and wonder_anomaly_stats.error
							or "unknown error"))
				end
				local deposits = SuperBigMap.DepositRules
				if not deposits then error("underground deposit rules are unavailable") end
				if type(deposits.ClearTopUpPlacementPool) == "function" then
					deposits.ClearTopUpPlacementPool(map)
				end
				if type(deposits.PrepareUndergroundReachability) ~= "function" then
					error("underground entrance-reachability preparation is unavailable")
				end
				local reach_ok, reach_state = deposits.PrepareUndergroundReachability(map)
				if reach_ok ~= true then
					error("underground entrance connectivity could not be initialized (seeds="
						.. tostring(reach_state and #reach_state.seeds or 0) .. ")")
				end
				if type(deposits.EnsureDeferredUndergroundWonderAnomaliesReachable)
					~= "function" then
					error("underground wonder-anomaly reachability repair is unavailable")
				end
				SetLoadingPhase("Positioning buried-wonder anomalies on reachable terrain")
				local wonder_reachability_token = LoadingBegin(
					"underground repair buried wonder anomaly reachability", map)
				local wonder_reachability_ok, wonder_reachability_stats =
					deposits.EnsureDeferredUndergroundWonderAnomaliesReachable(map, true)
				LoadingEnd(wonder_reachability_token, wonder_reachability_stats,
					wonder_reachability_ok == true)
				if wonder_reachability_ok ~= true then
					error("underground wonder-anomaly reachability repair left "
						.. tostring(wonder_reachability_stats
							and wonder_reachability_stats.unresolved or "unknown")
						.. " unresolved markers")
				end
			-- The legacy density/relocation suite is disabled in strict one-to-one mode. It both
			-- created extra enrichments and could relocate native underground markers.
			do
				local deposits = SuperBigMap.DepositRules
				if deposits
					and cfg_bool("EXPANSION_STEP_13_CALCULATE_ENRICHMENT_ADDITIONS", false) then
					if type(deposits.BeginUndergroundTopUpWallIgnore) ~= "function"
						or type(deposits.EndUndergroundTopUpWallIgnore) ~= "function" then
						error("underground rubble-wall density transaction is unavailable")
					end
					local wall_token = LoadingBegin("underground suspend removable rubble walls", map)
					local wall_begin_ok, wall_begin_stats =
						deposits.BeginUndergroundTopUpWallIgnore(map)
					LoadingEnd(wall_token, wall_begin_stats, wall_begin_ok == true)
					if wall_begin_ok ~= true then
						error("underground rubble-wall suspension failed: "
							.. tostring(wall_begin_stats and wall_begin_stats.error))
					end
					local suite_ok, suite_err = pcall(function()
						if type(deposits.TopUpDeposits) == "function" then
							SetLoadingPhase("Distributing underground resources and anomalies")
							TimedSafeCall("underground top-up resources", map,
								deposits.TopUpDeposits, map)
						end
						if type(deposits.TopUpAnomalies) == "function" then
							TimedSafeCall("underground top-up anomalies", map,
								deposits.TopUpAnomalies, map)
						end
						if type(deposits.TopUpEffectDeposits) == "function" then
							TimedSafeCall("underground top-up effect deposits", map,
								deposits.TopUpEffectDeposits, map)
						end
					end)
					local wall_restore_token = LoadingBegin(
						"underground restore removable rubble walls", map)
					local wall_restore_ok, wall_restore_stats =
						deposits.EndUndergroundTopUpWallIgnore(map)
					LoadingEnd(wall_restore_token, wall_restore_stats, wall_restore_ok == true)
					if wall_restore_ok ~= true then
						error("underground rubble-wall restoration failed: "
							.. tostring(wall_restore_stats and wall_restore_stats.error))
					end
					if not suite_ok then
						error("underground density suite failed: " .. tostring(suite_err))
					end
					if type(deposits.RegisterClonedMarkers) == "function" then
						TimedSafeCall("underground register top-up markers", map,
							deposits.RegisterClonedMarkers, map)
					end
					if type(deposits.RelocateUnreachableUndergroundEnrichments) ~= "function" then
						error("underground enrichment reachability audit is unavailable")
					end
				SetLoadingPhase("Moving underground enrichments onto reachable terrain")
				local reachability_token = LoadingBegin(
					"underground relocate unreachable enrichments", map)
				local audit_ok, audit_stats = deposits.RelocateUnreachableUndergroundEnrichments(map)
				LoadingEnd(reachability_token, {
					moved = audit_stats and audit_stats.moved,
					unresolved = audit_stats and audit_stats.unresolved,
					candidates_built = audit_stats and audit_stats.candidates_built,
					candidates_reused = audit_stats and audit_stats.candidates_reused,
					relocation_attempts = audit_stats and audit_stats.relocation_attempts,
					repulsion_rejected = audit_stats and audit_stats.repulsion_rejected,
					fallback_clearance_relaxed_moves = audit_stats
						and audit_stats.fallback_clearance_relaxed_moves,
					fallback_clearance_minimum_move = audit_stats
						and audit_stats.fallback_clearance_minimum_move,
					missing_repulsion_profile = audit_stats
						and audit_stats.missing_repulsion_profile,
					moved_by_class = audit_stats and audit_stats.moved_by_class,
					invalid_by_class = audit_stats and audit_stats.invalid_by_class,
					invalid_by_resource = audit_stats and audit_stats.invalid_by_resource,
					unresolved_by_class = audit_stats and audit_stats.unresolved_by_class,
					unresolved_by_resource = audit_stats and audit_stats.unresolved_by_resource,
					invalid_details = audit_stats and audit_stats.invalid_details,
					relocation_details = audit_stats and audit_stats.relocation_details,
					unresolved_details = audit_stats and audit_stats.unresolved_details,
					strict_first_rejection = audit_stats and audit_stats.strict_first_rejection,
					strict_last_rejection = audit_stats and audit_stats.strict_last_rejection,
					topup_only_first_rejection = audit_stats
						and audit_stats.topup_only_first_rejection,
					topup_only_last_rejection = audit_stats
						and audit_stats.topup_only_last_rejection,
				}, audit_ok == true)
					if audit_ok ~= true then
						error("underground enrichment reachability audit left "
							.. tostring(audit_stats and audit_stats.unresolved or "unknown")
							.. " unresolved markers: classes="
							.. tostring(audit_stats and audit_stats.unresolved_by_class or "unknown")
							.. " resources="
							.. tostring(audit_stats and audit_stats.unresolved_by_resource or "unknown")
							.. " (see unresolved_details in LoadingTiming log)")
					end
					if type(deposits.ResolveBadgeMarkerOverlaps) == "function" then
						TimedSafeCall("underground resolve marker overlaps", map,
							deposits.ResolveBadgeMarkerOverlaps, map, "underground reachable density suite")
					end
					if type(deposits.VerifyUndergroundWonderEnrichmentExclusion) ~= "function" then
						error("underground wonder-enrichment exclusion audit is unavailable")
					end
					local exclusion_token = LoadingBegin(
						"underground verify wonder-enrichment exclusion", map)
					local exclusion_ok, exclusion_stats =
						deposits.VerifyUndergroundWonderEnrichmentExclusion(
							map, "underground final after density suite")
					LoadingEnd(exclusion_token, exclusion_stats, exclusion_ok == true)
					if exclusion_ok ~= true then
						error("underground wonder-enrichment exclusion failed: overlaps="
							.. tostring(exclusion_stats and exclusion_stats.overlaps or "unknown")
							.. " error=" .. tostring(exclusion_stats and exclusion_stats.error or ""))
					end
					local wonder_reachability_audit_token = LoadingBegin(
						"underground final buried wonder anomaly reachability audit", map)
					local wonder_reachability_audit_ok, wonder_reachability_audit_stats =
						deposits.EnsureDeferredUndergroundWonderAnomaliesReachable(map, false)
					LoadingEnd(wonder_reachability_audit_token,
						wonder_reachability_audit_stats, wonder_reachability_audit_ok == true)
					if wonder_reachability_audit_ok ~= true then
						error("underground final wonder-anomaly reachability audit failed: unresolved="
							.. tostring(wonder_reachability_audit_stats
								and wonder_reachability_audit_stats.unresolved or "unknown"))
					end
					local wonder_audit_token = LoadingBegin(
						"underground final buried wonder anomaly audit", map)
					local wonder_audit_ok, wonder_audit_stats =
						WonderVerticalDiagnostics.AuditDeferredUndergroundWonderAnomalies(
							map, false, "after final enrichment relocation")
					LoadingEnd(wonder_audit_token, wonder_audit_stats, wonder_audit_ok == true)
					if wonder_audit_ok ~= true then
						error("underground buried wonder anomaly audit failed: "
							.. tostring(wonder_audit_stats and wonder_audit_stats.error
								or "unknown error"))
					end
					if type(deposits.AuditTopUpVanillaRepulsion) ~= "function" then
						error("top-up vanilla repulsion audit is unavailable")
					end
					local repulsion_token = LoadingBegin("underground hard repulsion audit", map)
					local repulsion_ok, repulsion_stats =
						deposits.AuditTopUpVanillaRepulsion(map, "underground final after density suite")
					LoadingEnd(repulsion_token, {
						markers = repulsion_stats and repulsion_stats.markers,
						topups = repulsion_stats and repulsion_stats.topups,
						density_status = repulsion_stats and repulsion_stats.density_status,
						resource_shortfall = repulsion_stats and repulsion_stats.resource_shortfall,
						anomaly_shortfall = repulsion_stats and repulsion_stats.anomaly_shortfall,
						effect_shortfall = repulsion_stats and repulsion_stats.effect_shortfall,
						resource_ignored_rubble_walls = repulsion_stats
							and repulsion_stats.resource_ignored_rubble_walls,
						wall_aware_shared_candidates = repulsion_stats
							and repulsion_stats.wall_aware_shared_candidates,
						duplicate_hex_pairs = repulsion_stats and repulsion_stats.duplicate_hex_pairs,
						first_duplicate_hex_pair = repulsion_stats
							and repulsion_stats.first_duplicate_hex_pair,
						violations = repulsion_stats and repulsion_stats.repulsion_violations,
						first_violation = repulsion_stats
							and repulsion_stats.first_repulsion_violation,
						underground_density_fallback_topups = repulsion_stats
							and repulsion_stats.underground_density_fallback_topups,
						underground_well_spaced_fallback_topups = repulsion_stats
							and repulsion_stats.underground_well_spaced_fallback_topups,
						underground_fallback_relaxed_topups = repulsion_stats
							and repulsion_stats.underground_fallback_relaxed_topups,
						underground_fallback_sectors = repulsion_stats
							and repulsion_stats.underground_fallback_sectors,
						underground_fallback_max_per_sector = repulsion_stats
							and repulsion_stats.underground_fallback_max_per_sector,
						underground_fallback_min_selected_spacing_world = repulsion_stats
							and repulsion_stats.underground_fallback_min_selected_spacing_world,
						underground_fallback_actual_min_spacing_world = repulsion_stats
							and repulsion_stats.underground_fallback_actual_min_spacing_world,
						underground_fallback_actual_min_hex_distance = repulsion_stats
							and repulsion_stats.underground_fallback_actual_min_hex_distance,
						underground_fallback_required_min_hex_distance = repulsion_stats
							and repulsion_stats.underground_fallback_required_min_hex_distance,
						underground_fallback_spacing_violations = repulsion_stats
							and repulsion_stats.underground_fallback_spacing_violations,
						first_underground_fallback_spacing_violation = repulsion_stats
							and repulsion_stats.first_underground_fallback_spacing_violation,
					}, repulsion_ok == true)
					if repulsion_ok ~= true then
						error("underground top-up vanilla repulsion audit failed: density_failures="
							.. tostring(repulsion_stats and repulsion_stats.density_failures)
							.. " resource_shortfall="
							.. tostring(repulsion_stats and repulsion_stats.resource_shortfall)
							.. " anomaly_shortfall="
							.. tostring(repulsion_stats and repulsion_stats.anomaly_shortfall)
							.. " effect_shortfall="
							.. tostring(repulsion_stats and repulsion_stats.effect_shortfall)
							.. " duplicate_hex_pairs="
							.. tostring(repulsion_stats and repulsion_stats.duplicate_hex_pairs)
							.. " first_duplicate_hex_pair="
							.. tostring(repulsion_stats
								and repulsion_stats.first_duplicate_hex_pair)
							.. " repulsion_violations="
							.. tostring(repulsion_stats and repulsion_stats.repulsion_violations)
							.. " first_violation="
							.. tostring(repulsion_stats
								and repulsion_stats.first_repulsion_violation)
							.. " fallback_strategy_failures="
							.. tostring(repulsion_stats
								and repulsion_stats.underground_fallback_strategy_failures)
							.. " fallback_spacing_violations="
							.. tostring(repulsion_stats
								and repulsion_stats.underground_fallback_spacing_violations))
					end
					if type(deposits.DebugAuditFinalEnrichments) == "function" then
						local audit_token = LoadingBegin("diagnostic underground enrichment audit", map)
						local call_ok, audit_ok, audit_stats = pcall(
							deposits.DebugAuditFinalEnrichments, map,
							"underground final before temporary reveal")
						LoadingEnd(audit_token, {
							audit_ok = tostring(audit_ok),
							error = call_ok and "" or tostring(audit_ok),
							markers = call_ok and audit_stats and audit_stats.markers or nil,
						}, call_ok and audit_ok ~= false)
					end
					if cfg_bool("UNDERGROUND_REVEAL_ALL_ENRICHMENTS_FOR_TESTING", false) then
						if type(deposits.RevealAllUndergroundEnrichmentsForTesting) ~= "function" then
							error("temporary underground enrichment reveal API is unavailable")
						end
						SetLoadingPhase("Revealing underground enrichments for verification")
						local reveal_ok, reveal_stats =
							deposits.RevealAllUndergroundEnrichmentsForTesting(map)
						if reveal_ok ~= true then
							error("temporary underground enrichment reveal failed: "
								.. tostring(reveal_stats and reveal_stats.error or "unknown error"))
						end
						if type(deposits.DebugAuditFinalEnrichments) == "function" then
							local audit_token = LoadingBegin(
								"diagnostic underground post-reveal enrichment audit", map)
							local call_ok, audit_ok, audit_stats = pcall(
								deposits.DebugAuditFinalEnrichments, map,
								"underground after temporary RevealDeposits")
							LoadingEnd(audit_token, {
								audit_ok = tostring(audit_ok),
								error = call_ok and "" or tostring(audit_ok),
								markers = call_ok and audit_stats and audit_stats.markers or nil,
							}, call_ok and audit_ok ~= false)
						end
					end
					if type(deposits.ClearTopUpPlacementPool) == "function" then
						deposits.ClearTopUpPlacementPool(map)
					end
				end
			end
			end
			-- (Buildable + passability rebuilds moved ABOVE the density suite -- its
			-- buildable-floor-only pools need the live grid.)
			-- Every buried wonder now sits at its final pose on the final grids and carries its
			-- rare anomaly, which is the lifecycle point at which vanilla has already run the
			-- wonder's GameInit. Complete that same spawn lifecycle before the map is reported
			-- prepared, so the finished underground is not missing objects GameInit attaches.
			do
				SetLoadingPhase("Completing buried-wonder spawn effects")
				local wonder_gameinit_token = LoadingBegin(
					"underground run buried wonder GameInit", map)
				local wonder_gameinit_ok, wonder_gameinit_stats =
					WonderVerticalDiagnostics.RunDeferredUndergroundWonderGameInit(
						map, "after final grids, anomalies and enrichment placement")
				LoadingEnd(wonder_gameinit_token, wonder_gameinit_stats,
					wonder_gameinit_ok == true)
				if wonder_gameinit_ok ~= true then
					error("deferred underground wonder GameInit failed: "
						.. tostring(wonder_gameinit_stats and wonder_gameinit_stats.error
							or "unknown error"))
				end
			end
			-- LAST WORD ON THE GAMEPLAY GRIDS. Everything above -- the pre-anomaly buried-wonder
			-- reseat, anomaly activation, enrichment relocation and this GameInit pass -- runs inside
			-- object-grid transactions, and the engine re-derives passability over the regions each
			-- one touches when the last SuspendPassEdits reason clears. Measured (iteration 037, call
			-- tracer): the reseat bracket was the pipeline's final pass-edit transaction and its resume
			-- discarded the authoritative rebuild issued before the density suite, restoring the exact
			-- defective grid. So repeat that rebuild here, after the pipeline's last transaction has
			-- closed. It is idempotent and whole-map, and both call sites run the same engine sequence.
			if cfg_bool("EXPANSION_STEP_11_REBUILD_GAMEPLAY_GRIDS", true) then
				SetLoadingPhase("Finalizing underground gameplay grids")
				RebuildFinalUndergroundGameplayGrids("after last object-grid transaction")
				WonderVerticalDiagnostics.LogAll(map, "after_closing_grid_rebuild")
			end
		end)
		-- A failure anywhere between decoration movement and marker verification must still balance
		-- the caller-owned pass transaction before diagnostics or lifecycle cleanup touch the map.
		if transform_pass_batch_active then
			local cleanup_ok, cleanup_err = ResumeUndergroundTransformPassEdits(true)
			LoadingStep("underground combined pass-edit failure cleanup", {
				ok = tostring(cleanup_ok == true), error = cleanup_ok and "" or tostring(cleanup_err),
			}, map)
			if not cleanup_ok then
				if ok_branch then
					ok_branch = false
					branch_err = "underground pass-edit cleanup failed: " .. tostring(cleanup_err)
				else
					branch_err = tostring(branch_err) .. " | pass-edit cleanup failed: "
						.. tostring(cleanup_err)
				end
			end
		end
		LoadingEnd(underground_pipeline_token, {
			elevator_migrations = #elevator_migrations,
			error = ok_branch and "" or tostring(branch_err),
		}, ok_branch)
		if not ok_branch and type(elevator_migrations) == "table" and #elevator_migrations > 0 then
			-- A partially failed terrain transaction is not a safe context in which to touch native
			-- supply grids. Invalidate the token and keep underground access blocked; never recreate
			-- the Elevator on the still-current surface or on grids whose rebuild did not complete.
			local failed_token = CurrentElevatorRestoreToken(map)
			if failed_token then
				failed_token.cancelled = true
				failed_token.status = "pipeline-failed"
				underground_elevator_restore_tokens[failed_token.token_id] = nil
			end
			pending_underground_elevator_restores[map] = nil
			map.SuperBigMapDeferredElevatorRestorePending = nil
			map.SuperBigMapDeferredElevatorRestoreToken = nil
		end
		if type(resume_ild) == "function" then SafeCall(resume_ild, "SuperBigMapUndergroundStretch") end
		if type(ClearDecorRelief) == "function" then ClearDecorRelief(map) end
		if ok_branch and map.SuperBigMapStretchPipelinePending == true then
			FinalizeDeferredStretchState(map, "underground")
		elseif map.SuperBigMapStretchPipelinePending == true then
			local lifecycle = SuperBigMap.Lifecycle
			if lifecycle and type(lifecycle.Apply) == "function" then SafeCall(lifecycle.Apply, map, true) end
			map.SuperBigMapStretchPipelinePending = false
		end
		if ok_branch then
			-- Same derived-object record as the surface, for the underground CityInit spawns
			-- (SurfaceTunnelMarker, SubsurfaceSpecialAnomalyMarker, attached passage imprints).
			do
				local provenance = SuperBigMap.Provenance
				if provenance and type(provenance.Propagate) == "function" then
					SafeCall(provenance.Propagate, map, "underground preparation complete")
				end
			end
			map.SuperBigMapUndergroundStretchDone = true
			map.SuperBigMapUndergroundPrepared = true
			map.SuperBigMapExpanded = true
			-- The final passability/buildable grids were synchronously rebuilt before the
			-- reachability-filtered density suite. CurrentMapChangeDone must not immediately
			-- rebuild them again after placement and silently change the accepted terrain.
			map.SuperBigMapSkipNextLifecycleBoundsRebuild = true
			map.SuperBigMapUndergroundDeferredGeometry = false
			map.SuperBigMapUndergroundStretchPending = false
			map.SuperBigMapUndergroundStretchFailed = nil
			map.SuperBigMapUndergroundPreparationFailed = false
		else
			-- Never expose a half-processed underground and never retry automatically: several
			-- stretch stages are intentionally one-way, so repeating after a partial failure could
			-- scale terrain or objects twice. The access gate reports the failure and stays closed.
			map.SuperBigMapUndergroundStretchPending = false
			map.SuperBigMapUndergroundStretchFailed = tostring(branch_err or "unknown error")
			map.SuperBigMapUndergroundPreparationFailed = true
			map.SuperBigMapSkipNextLifecycleBoundsRebuild = nil
		end
		map.SuperBigMapUndergroundStretchRunning = false
		local msg = Global("Msg")
		if type(msg) == "function" then
			local restore_token = ok_branch and Global("CurrentMap") == map
				and CurrentElevatorRestoreToken(map) or nil
			if restore_token then
				pcall(msg, "SuperBigMapUndergroundSupplyReady", map,
					restore_token.token_id, "already-current pipeline complete")
			end
			pcall(msg, "SuperBigMapUndergroundExpansionDone", map, ok_branch, branch_err)
		end
		-- End of this loading phase (single exit point of the thread; every step above is
		-- pcall-guarded, so this always runs).
		if type(SuperBigMap.ExpansionLoadingEnd) == "function" then
			pcall(SuperBigMap.ExpansionLoadingEnd)
		end
		if force_now ~= true then
			LoadingFinish("underground asynchronous expansion complete", map, {
				elevator_migrations = #elevator_migrations,
				error = ok_branch and "" or tostring(branch_err),
			}, ok_branch)
		end
		return ok_branch == true, branch_err
	end
	if force_now == true then
		return run_pipeline()
	end
	create_thread(run_pipeline)
	return true
end

-- Persistent readiness handoff used by lifecycle completion events. PostNewMapLoaded may run
-- while the random generator is still filling terrain and objects, so it may only register a
-- deferred request. Both milestones are required: MapGenerated proves native terrain/object
-- generation returned; CityInitialized proves exploration and breakthrough placement returned.
local function NotifyGenerationMilestone(map, milestone, source)
	if type(map) ~= "table" then return false end
	local grid = SuperBigMap.SectorGrid
	local is_mod_map = type(grid) == "table" and type(grid.IsModMap) == "function"
		and grid.IsModMap(map) == true
	if not is_mod_map and map.SuperBigMapExpansionPending ~= true then
		-- These readiness fields are part of the stretch transaction.  A normal map
		-- must not acquire SuperBigMap state merely because the persistent lifecycle
		-- lifecycle handlers saw MapGenerated/CityInitialized.
		return false
	end
	if milestone == "MapGenerated" then
		map.SuperBigMapNativeGenerationComplete = true
		map.SuperBigMapNativeGenerationCompleteSource = tostring(source or milestone)
	elseif milestone == "CityInitialized" then
		map.SuperBigMapCityInitializationComplete = true
	else
		return false
	end
	-- Stamp the schema as soon as either current-code milestone is observed. A save made between
	-- milestones must remain distinguishable from a legacy save whose fields were absent entirely.
	map.SuperBigMapGenerationReadinessVersion = SuperBigMap.GenerationReadiness.VERSION
	SignalExpansionReadinessChanged(map, tostring(milestone) .. ": " .. tostring(source or milestone))

	local env = map.mapdata and map.mapdata.Environment
	if env == "Surface" then
		if is_mod_map and map.SuperBigMapVanillaSourceMigration ~= true then
			return RunSurfaceStretchIfEnabled(map, source)
		end
		return true
	end
	if env == "Underground" then
		return RunUndergroundStretchIfEnabled(map)
	end
	return true
end

local function NeedsDeferredUndergroundPreparation(map)
	if not map or not map.mapdata or map.mapdata.Environment ~= "Underground" then
		return false, "target is not an underground map"
	end
	if not cfg_bool("STRETCH_UNDERGROUND", false) then
		return false, "underground stretch is disabled"
	end
	RestoreDeferredUndergroundGeometry(map)
	local desired = map.SuperBigMapDesiredWidthTiles
	local generator = map.SuperBigMapGeneratorWidthTiles
	if not (type(desired) == "number" and type(generator) == "number" and desired > generator) then
		return false, "target has no deferred expandable geometry"
	end
	if map.SuperBigMapUndergroundPrepared == true or map.SuperBigMapUndergroundStretchDone == true then
		return false, "target is already prepared"
	end
	return true, "deferred underground preparation required"
end

-- Unit:UseElevator normally transfers directly between two already-built map objects and never
-- calls ChangeCurrentMapSlot. When the destination is our deferred underground, pause that command
-- at its first safe boundary, run the authoritative map-switch gate on a real-time thread, and only
-- resume vanilla elevator use after CurrentMapChangeDone has restored the underground counterpart.
-- This covers rovers, colonists, and any other Unit descendant that uses the vanilla command.
local DEFERRED_ELEVATOR_ACCESS_PATCH_VERSION = 10
local deferred_elevator_access_by_unit = setmetatable({}, { __mode = "k" })

local function DeferredUndergroundTargetForElevator(elevator)
	local other = elevator and elevator.other or nil
	local target = TraversalObjectMap(other)
	if target and target.mapdata and target.mapdata.Environment == "Underground" then
		return target
	end
	return nil
end

local function ShowDeferredUndergroundAccessFailure(reason)
	local create_box = Global("CreateMessageBox")
	if type(create_box) ~= "function" then return end
	local untranslated = Global("Untranslated")
	local wrap = type(untranslated) == "function" and untranslated or function(s) return s end
	pcall(create_box, nil, wrap("Super Big Map"), wrap(
		"The underground could not be prepared safely, so elevator access remains blocked."
		.. "\n\n" .. tostring(reason or "Unknown error")))
end

-- DroneBase recreates its NightLightLight attachments from OnTransferToMapDone. Vanilla normally
-- changes the current map while those attachments move. The first-access rover path deliberately
-- keeps the player's camera on the source map, so creating clustered lights in the off-screen
-- destination leaves the renderer's light-index arrays out of sync. Temporarily suppress the
-- destination map's night-light state for the transfer, then rebuild the unit's lights only after
-- that destination has completed a real CurrentMapChangeDone lifecycle.
local function VehicleLightTransitionAudit(event, unit, elevator, target, extra)
	local data = {
		unit = tostring(unit), unit_class = TraversalClass(unit), elevator = tostring(elevator),
		current_map = tostring(Global("CurrentMap")), unit_map = tostring(TraversalObjectMap(unit)),
		target = tostring(target), target_night_lights_state = tostring(target and target.NightLightsState),
	}
	TraversalAddUnitLightState(data, "unit_light", unit)
	TraversalAddMapLightState(data, "current_map_lights", Global("CurrentMap"))
	if target and target ~= Global("CurrentMap") then
		TraversalAddMapLightState(data, "target_map_lights", target)
	end
	local deferred_count, suppression_count = 0, 0
	for _ in pairs(deferred_vehicle_night_lights) do deferred_count = deferred_count + 1 end
	for _ in pairs(offscreen_vehicle_light_suppressions) do suppression_count = suppression_count + 1 end
	data.deferred_vehicle_count = deferred_count
	data.suppressed_map_count = suppression_count
	if type(extra) == "table" then
		for key, value in pairs(extra) do data[key] = value end
	end
	ElevatorTraversalAudit(event, data, TraversalObjectMap(unit) or target or Global("CurrentMap"))
end

local function BeginOffscreenVehicleLightTransfer(unit, elevator)
	if not IsKindOfSafe(unit, "NightLightObject") then return nil end
	local target = TraversalObjectMap(elevator and elevator.other)
	if not target or target == Global("CurrentMap") then return nil end
	local record = offscreen_vehicle_light_suppressions[target]
	if type(record) ~= "table" then
		record = { count = 0, previous = target.NightLightsState }
		offscreen_vehicle_light_suppressions[target] = record
	end
	VehicleLightTransitionAudit("VEHICLE_LIGHT_GUARD_BEGIN", unit, elevator, target, {
		guard_count_before = tostring(record.count), target_previous = tostring(record.previous),
	})
	record.count = (tonumber(record.count) or 0) + 1
	target.NightLightsState = false
	VehicleLightTransitionAudit("VEHICLE_LIGHT_GUARD_SUPPRESSED", unit, elevator, target, {
		guard_count_after = tostring(record.count), target_previous = tostring(record.previous),
	})
	return {
		target = target, record = record, previous = record.previous,
		unit = unit, elevator = elevator,
	}
end

local function EndOffscreenVehicleLightTransfer(guard)
	local target = guard and guard.target
	local record = guard and guard.record
	if not target or type(record) ~= "table" then return end
	VehicleLightTransitionAudit("VEHICLE_LIGHT_GUARD_END_BEGIN", guard.unit, guard.elevator, target, {
		guard_count_before = tostring(record.count), target_previous = tostring(record.previous),
	})
	record.count = math.max(0, (tonumber(record.count) or 1) - 1)
	if record.count == 0 then
		target.NightLightsState = record.previous
		if offscreen_vehicle_light_suppressions[target] == record then
			offscreen_vehicle_light_suppressions[target] = nil
		end
	end
	VehicleLightTransitionAudit("VEHICLE_LIGHT_GUARD_END_DONE", guard.unit, guard.elevator, target, {
		guard_count_after = tostring(record.count), target_previous = tostring(record.previous),
	})
end

local function RestoreDeferredVehicleNightLights(map)
	if not map or map ~= Global("CurrentMap") then return 0, 0 end
	local restored, discarded = 0, 0
	for unit, target in pairs(deferred_vehicle_night_lights) do
		-- Main-menu ChangeMap can destroy the vehicle before CurrentMapChangeDone drains this
		-- weak table. Never ask a stale GameObject for its map.
		local unit_valid = TraversalObjectValid(unit)
		local unit_map = unit_valid and TraversalObjectMap(unit) or nil
		if not unit_valid or unit_map ~= target then
			deferred_vehicle_night_lights[unit] = nil
			discarded = discarded + 1
		elseif target == map then
			local set_possible = unit.SetIsNightLightPossible
			if type(set_possible) == "function" then
				local malfunctioned = type(unit.IsMalfunctioned) == "function"
					and SafeCall(unit.IsMalfunctioned, unit) == true
				VehicleLightTransitionAudit("VEHICLE_NIGHT_LIGHT_RESTORE_BEGIN", unit, nil, target, {
					malfunctioned = tostring(malfunctioned),
				})
				local ok = pcall(set_possible, unit, not malfunctioned)
				if not ok then
					ElevatorTraversalAudit("VEHICLE_NIGHT_LIGHT_RESTORE_FAILED", {
						unit = tostring(unit), unit_class = TraversalClass(unit),
						target = tostring(target), malfunctioned = tostring(malfunctioned),
					}, map)
				else
					restored = restored + 1
				end
				VehicleLightTransitionAudit("VEHICLE_NIGHT_LIGHT_RESTORE_DONE", unit, nil, target, {
					malfunctioned = tostring(malfunctioned), restore_ok = tostring(ok),
				})
			else
				discarded = discarded + 1
			end
			deferred_vehicle_night_lights[unit] = nil
		end
	end
	if restored > 0 or discarded > 0 then
		ElevatorTraversalAudit("VEHICLE_NIGHT_LIGHTS_RESTORED", {
			restored = restored, discarded = discarded,
			night_lights_state = tostring(map.NightLightsState),
		}, map)
	end
	return restored, discarded
end

-- Elevator waypoint chains contain absolute world positions. Stretching an already-built
-- underground counterpart moves the building itself, but vanilla does not rebuild those cached
-- points on SetPos. Rebuild every expanded-map Elevator after the final map lifecycle so rover
-- disembark positions follow the stretched Elevator instead of the old source-sized coordinates.
local function RebuildExpandedElevatorWaypointChains(map, reason)
	if not TraversalIsExpandedMap(map) or type(map.MapForEach) ~= "function" then return 0, 0 end
	local rebuilt, failed = 0, 0
	local ok_scan = pcall(map.MapForEach, map, "map", "ElevatorBase", function(elevator)
		if TraversalObjectValid(elevator) and type(elevator.BuildWaypointChains) == "function" then
			local ok = pcall(elevator.BuildWaypointChains, elevator)
			if ok then rebuilt = rebuilt + 1 else failed = failed + 1 end
		end
	end)
	if not ok_scan then failed = failed + 1 end
	local passage_markers_hidden = HideExistingCompletedPassageIndicators(
		tostring(reason) .. " passage-marker final boundary")
	ElevatorTraversalAudit("ELEVATOR_WAYPOINT_CHAINS_REBUILT", {
		rebuilt = rebuilt, failed = failed, reason = tostring(reason),
		passage_markers_hidden = passage_markers_hidden,
	}, map)
	return rebuilt, failed
end

-- Expanded-map rover pathfinding can reach the exact Elevator entrance and still return false from
-- Unit:Goto_NoDestlock after the final grid rebuild. Vanilla then exits Unit:UseElevator before it
-- calls ElevatorBase:UseElevator. Preserve vanilla first; only if it returned without transferring,
-- and the rover is already within two hexes of a valid entrance, continue through the normal
-- building-side Elevator method. Distant/unreachable rovers never qualify for this fallback.
local function UseElevatorWithRoverCloseRangeFallback(original, unit, elevator, ...)
	if not IsKindOfSafe(unit, "BaseRover") or not TraversalIsExpandedContext(unit, elevator) then
		return original(unit, elevator, ...)
	end
	local before_map = TraversalObjectMap(unit)
	local original_light_guard = BeginOffscreenVehicleLightTransfer(unit, elevator)
	local protected_results = PackValues(pcall(original, unit, elevator, ...))
	EndOffscreenVehicleLightTransfer(original_light_guard)
	if protected_results[1] ~= true then error(protected_results[2]) end
	local results = { n = math.max(0, protected_results.n - 1) }
	for i = 2, protected_results.n do results[i - 1] = protected_results[i] end
	local after_map = TraversalObjectMap(unit)
	if before_map == nil or after_map ~= before_map then
		if original_light_guard and after_map == original_light_guard.target then
			deferred_vehicle_night_lights[unit] = after_map
			ElevatorTraversalAudit("VEHICLE_NIGHT_LIGHT_DEFERRED", {
				unit = tostring(unit), elevator = tostring(elevator),
				final_map = tostring(after_map), transfer_path = "vanilla Unit:UseElevator",
				target_night_lights_restored = tostring(original_light_guard.previous),
			}, after_map or before_map)
		end
		return Unpack(results, 1, results.n)
	end
	if not TraversalObjectValid(unit) or not TraversalObjectValid(elevator)
		or not TraversalObjectValid(elevator.other)
		or TraversalObjectMap(elevator) ~= before_map then
		return Unpack(results, 1, results.n)
	end
	local validate = Global("ValidateBuilding")
	if type(validate) == "function" and SafeCall(validate, elevator) ~= elevator then
		return Unpack(results, 1, results.n)
	end
	local entrance = type(elevator.GetEntrancePos) == "function"
		and SafeCall(elevator.GetEntrancePos, elevator, unit) or nil
	local unit_pos = Engine.ObjectPos(unit)
	local ux, uy = PointXY(unit_pos)
	local ex, ey = PointXY(entrance)
	if ux == false or uy == nil or ex == false or ey == nil then
		return Unpack(results, 1, results.n)
	end
	local dx, dy = ux - ex, uy - ey
	local distance_sq = dx * dx + dy * dy
	local const_tbl = Global("const")
	local hex_size = type(const_tbl) == "table" and tonumber(const_tbl.HexSize) or nil
	local max_distance = 2 * (hex_size or 1000)
	if distance_sq > max_distance * max_distance then
		ElevatorTraversalAudit("VEHICLE_CLOSE_RANGE_FALLBACK_SKIPPED", {
			unit = tostring(unit), elevator = tostring(elevator),
			distance = tostring(math.sqrt(distance_sq)), max_distance = tostring(max_distance),
			reason = "rover is not close enough to the entrance",
		}, before_map)
		return Unpack(results, 1, results.n)
	end
	-- Calling ElevatorBase:UseElevator directly is allowed to bypass only the failed final
	-- Goto_NoDestlock step. It must not bypass RCRover:Unsiege's ownership invariant: every
	-- controlled drone has to finish RecallToRover and be attached before OnTransferToMap runs.
	-- Otherwise vanilla abandons a still-recalling surface drone while its queued command retains
	-- the now-underground rover argument, leading to Drone:RecallToRover's command-center assert.
	if IsKindOfSafe(unit, "RCRover") then
		local drones = type(unit.drones) == "table" and unit.drones or nil
		local attached = type(unit.attached_drones) == "table" and unit.attached_drones or nil
		local ready = drones ~= nil and attached ~= nil
		local reason = ready and "" or "rover drone ownership tables are unavailable"
		if ready then
			for _, drone in ipairs(drones) do
				local is_attached = false
				for _, attached_drone in ipairs(attached) do
					if attached_drone == drone then
						is_attached = true
						break
					end
				end
				if not TraversalObjectValid(drone) or drone.command_center ~= unit
					or drone.command == "RecallToRover" or not is_attached then
					ready = false
					reason = "a controlled drone has not finished embarking"
					break
				end
			end
		end
		if ready and ((type(unit.drones_waiting_to_embark) == "table"
				and #unit.drones_waiting_to_embark > 0)
			or (type(unit.embarking_drones) == "table" and #unit.embarking_drones > 0)
			or unit.guided_drone) then
			ready = false
			reason = "the rover still has a pending drone embark operation"
		end
		if not ready then
			ElevatorTraversalAudit("VEHICLE_CLOSE_RANGE_FALLBACK_SKIPPED", {
				unit = tostring(unit), elevator = tostring(elevator), reason = reason,
			}, before_map)
			return Unpack(results, 1, results.n)
		end
	end
	local building_use = elevator.UseElevator
	if type(building_use) ~= "function" then
		return Unpack(results, 1, results.n)
	end
	ElevatorTraversalAudit("VEHICLE_CLOSE_RANGE_FALLBACK_BEGIN", {
		unit = tostring(unit), elevator = tostring(elevator),
		distance = tostring(math.sqrt(distance_sq)), max_distance = tostring(max_distance),
	}, before_map)
	local light_guard = BeginOffscreenVehicleLightTransfer(unit, elevator)
	local call_ok, call_err = pcall(building_use, elevator, unit)
	EndOffscreenVehicleLightTransfer(light_guard)
	if not call_ok then error(call_err) end
	local final_map = TraversalObjectMap(unit)
	local night_lights_deferred = light_guard ~= nil and final_map == light_guard.target
	if night_lights_deferred then
		deferred_vehicle_night_lights[unit] = final_map
	end
	ElevatorTraversalAudit("VEHICLE_CLOSE_RANGE_FALLBACK_END", {
		unit = tostring(unit), elevator = tostring(elevator),
		transferred = tostring(final_map ~= nil and final_map ~= before_map),
		final_map = tostring(final_map), night_lights_deferred = tostring(night_lights_deferred),
		target_night_lights_restored = tostring(light_guard and light_guard.previous),
	}, final_map or before_map)
	return Unpack(results, 1, results.n)
end

-- Compatibility cleanup for version 628, which temporarily imposed a non-vanilla rover power
-- requirement. Remove every stored wrapper on hot reload; no replacement is installed.
local function RestoreExpandedElevatorPowerGate()
	local State = SuperBigMap.State
	local patches = State.expanded_elevator_power_gate_patches
	local diagnostics_were_outer = false
	if type(patches) == "table" then
		for _, patch in ipairs(patches) do
			for _, diagnostic in ipairs(State.elevator_traversal_diagnostic_patches or {}) do
				if diagnostic.target == patch.target and diagnostic.method == "UseElevator"
					and diagnostic.original == patch.wrapper
					and patch.target.UseElevator == diagnostic.wrapper then
					diagnostics_were_outer = true
					break
				end
			end
			if diagnostics_were_outer then break end
		end
	end
	if diagnostics_were_outer then RestoreElevatorTraversalDiagnostics() end
	if type(patches) == "table" then
		for i = #patches, 1, -1 do
			local patch = patches[i]
			if patch.target and patch.target.UseElevator == patch.wrapper then
				patch.target.UseElevator = patch.original
			end
		end
	end
	State.expanded_elevator_power_gate_patches = nil
	State.expanded_elevator_power_gate_version = nil
	return diagnostics_were_outer
end

local function CaptureDeferredElevatorCamera()
	local camera = Global("cameraRTS")
	if type(camera) ~= "table" or type(camera.GetEye) ~= "function"
		or type(camera.GetLookAt) ~= "function" then
		return nil
	end
	local eye = SafeCall(camera.GetEye)
	local lookat = SafeCall(camera.GetLookAt)
	if not eye or not lookat then return nil end
	local zoom = type(camera.GetZoom) == "function" and SafeCall(camera.GetZoom) or nil
	return { eye = eye, lookat = lookat, zoom = zoom }
end

local function WaitForDeferredSurfaceScene(expected_map)
	local wait_render = Global("WaitRenderMode")
	local render_ok = type(wait_render) == "function" and pcall(wait_render, "scene") or false
	local frames = 0
	local is_real_time = Global("IsRealTimeThread")
	local wait_frame = Global("WaitNextFrame")
	local ok_realtime, in_realtime = false, false
	if type(is_real_time) == "function" then ok_realtime, in_realtime = pcall(is_real_time) end
	if ok_realtime and in_realtime == true and type(wait_frame) == "function" then
		for _ = 1, 2 do
			if not pcall(wait_frame) then break end
			frames = frames + 1
		end
	end
	ElevatorTraversalAudit("FIRST_ACCESS_SURFACE_SCENE_READY", {
		expected_map = tostring(expected_map), current_map = tostring(Global("CurrentMap")),
		render_wait_ok = tostring(render_ok), rendered_frames = frames,
	}, expected_map)
	return Global("CurrentMap") == expected_map
end

local function RestoreDeferredElevatorCamera(snapshot, expected_map)
	if type(snapshot) ~= "table" then return true, "camera snapshot unavailable" end
	if expected_map and Global("CurrentMap") ~= expected_map then
		return false, "camera target map was not restored"
	end
	local camera = Global("cameraRTS")
	if type(camera) ~= "table" or type(camera.SetCamera) ~= "function" then
		return false, "cameraRTS.SetCamera is unavailable"
	end
	-- Restore the zoom controller first, then make the saved eye/look-at pair authoritative. The
	-- final zero-time SetCamera prevents map-switch camera presets from shifting either framing or
	-- distance after the hidden underground round trip.
	if type(snapshot.zoom) == "number" and type(camera.SetZoom) == "function" then
		SafeCall(camera.SetZoom, snapshot.zoom, 0)
	end
	local ok = pcall(camera.SetCamera, snapshot.eye, snapshot.lookat, 0)
	if not ok then return false, "cameraRTS.SetCamera rejected the saved view" end
	-- Apply the saved values again after one rendered frame. CurrentMapChangeDone can enqueue a
	-- zero-duration camera normalization that otherwise wins just after the first restore.
	local is_real_time = Global("IsRealTimeThread")
	local wait_frame = Global("WaitNextFrame")
	local ok_realtime, in_realtime = false, false
	if type(is_real_time) == "function" then ok_realtime, in_realtime = pcall(is_real_time) end
	if ok_realtime and in_realtime == true and type(wait_frame) == "function" then pcall(wait_frame) end
	if type(snapshot.zoom) == "number" and type(camera.SetZoom) == "function" then
		SafeCall(camera.SetZoom, snapshot.zoom, 0)
	end
	ok = pcall(camera.SetCamera, snapshot.eye, snapshot.lookat, 0)
	if not ok then return false, "cameraRTS.SetCamera rejected the final saved view" end
	local eye_after = type(camera.GetEye) == "function" and SafeCall(camera.GetEye) or nil
	local lookat_after = type(camera.GetLookAt) == "function" and SafeCall(camera.GetLookAt) or nil
	local exact = eye_after and lookat_after
		and tostring(eye_after) == tostring(snapshot.eye)
		and tostring(lookat_after) == tostring(snapshot.lookat)
	ElevatorTraversalAudit("FIRST_ACCESS_CAMERA_RESTORE", {
		exact = tostring(exact == true), saved_eye = tostring(snapshot.eye),
		actual_eye = tostring(eye_after), saved_lookat = tostring(snapshot.lookat),
		actual_lookat = tostring(lookat_after), saved_zoom = tostring(snapshot.zoom),
		actual_zoom = tostring(type(camera.GetZoom) == "function" and SafeCall(camera.GetZoom) or nil),
	}, expected_map)
	-- A successful SetCamera is authoritative. The engine may normalize the point representation by
	-- sub-hex precision, which must not turn an otherwise successful underground build into failure.
	return true, exact and "restored exact eye/look-at" or "restored saved view; engine normalized camera points"
end

local function PrepareDeferredUndergroundForElevator(unit, elevator, target)
	local State = SuperBigMap.State
	local gate = State.change_current_map_slot_wrapper
	local create_thread = Global("CreateRealTimeThread")
	local wait_msg = Global("WaitMsg")
	local msg = Global("Msg")
	local return_map = Global("CurrentMap")
	if type(gate) ~= "function" or type(create_thread) ~= "function"
		or type(wait_msg) ~= "function" or type(msg) ~= "function" then
		return false, "required first-access engine functions are unavailable"
	end
	if not target or target.slot == nil then
		return false, "the linked underground map slot is unavailable"
	end
	if not return_map or return_map.slot == nil then
		return false, "the current map cannot be restored after underground preparation"
	end
	local return_camera = CaptureDeferredElevatorCamera()

	State.deferred_elevator_access_sequence =
		(tonumber(State.deferred_elevator_access_sequence) or 0) + 1
	local request_id = State.deferred_elevator_access_sequence
	local completion_message = "SuperBigMapElevatorUndergroundReady" .. tostring(request_id)
	local request = { done = false, ok = false }
	ElevatorTraversalAudit("FIRST_ACCESS_BEGIN", {
		request = request_id, unit = tostring(unit), elevator = tostring(elevator),
		target = tostring(target), target_slot = tostring(target.slot),
		return_map = tostring(return_map), return_slot = tostring(return_map.slot),
	}, TraversalObjectMap(unit))

	create_thread(function()
		-- The two map switches below are a hidden preparation round trip, not the rover's real
		-- Surface -> Underground transfer. Keep this token set through both synchronous
		-- CurrentMapChangeDone handlers and the exact camera restore so lifecycle cannot schedule
		-- overview on either intermediate destination. The original UseElevator resumes only after
		-- this token is cleared; its later player-facing transfer therefore still opens overview.
		State.deferred_elevator_hidden_roundtrip_active = request_id
		State.overview_switch_source_map = nil
		State.overview_switch_source_environment = nil
		local function finish_hidden_roundtrip()
			if State.deferred_elevator_hidden_roundtrip_active == request_id then
				State.deferred_elevator_hidden_roundtrip_active = nil
			end
			State.overview_switch_source_map = nil
			State.overview_switch_source_environment = nil
		end
		-- Own one outer reference across the complete hidden round trip. The preparation pipeline
		-- acquires/releases a nested reference of its own; retaining this one prevents either the
		-- underground view or the intermediate engine loading art from becoming visible before the
		-- original surface view has been restored.
		local begin_loading = SuperBigMap.ExpansionLoadingBegin
		local end_loading = SuperBigMap.ExpansionLoadingEnd
		local loading_started = false
		local fallback_screen_open = false
		local fallback_screen_id = "idSuperBigMapElevatorUndergroundPreparation"
		if type(begin_loading) == "function" then
			local begin_ok, visible = pcall(begin_loading, "underground")
			loading_started = begin_ok
			if visible ~= true then
				-- If the custom frozen backdrop cannot be constructed on this renderer, retain
				-- vanilla's loading screen instead. Proceed only after its UI render mode is active.
				local open_screen = Global("LoadingScreenOpen")
				local wait_render = Global("WaitRenderMode")
				if type(open_screen) == "function" then
					fallback_screen_open = pcall(
						open_screen, fallback_screen_id, return_map.slot)
					if fallback_screen_open and type(wait_render) == "function" then
						pcall(wait_render, "ui")
					end
				end
			end
		end
		-- Our persistent custom dialog already covers both internal switches, so suppress the
		-- vanilla map-switch artwork that would otherwise replace it for a frame.
		local call_ok, call_result = pcall(gate, target.slot, false, "idChangeCurrentMapSlot")
		request.call_ok = call_ok
		request.call_result = call_result
		local target_ready = call_ok and call_result ~= false
			and target.SuperBigMapUndergroundPrepared == true
			and target.SuperBigMapUndergroundStretchDone == true
			and Global("CurrentMap") == target
		local return_ok, return_result = false, nil
		local return_darkness_ok, return_darkness_reason = false,
			"return map darkness was not prepared"
		if target_ready then
			-- The retained frozen surface covers this write. Prime Surface's vanilla value before
			-- EngineSetCurrentMapSlot can expose it, then confirm the same value after the switch.
			return_darkness_ok, return_darkness_reason =
				SuperBigMap.EnsureVanillaDarknessReady(return_map)
			if return_darkness_ok then
				return_ok, return_result = pcall(
					gate, return_map.slot, false, "idChangeCurrentMapSlot")
				return_ok = return_ok and return_result ~= false
					and Global("CurrentMap") == return_map
				if return_ok then
					return_darkness_ok, return_darkness_reason =
						SuperBigMap.EnsureVanillaDarknessReady(return_map)
				end
			end
		end
		local camera_ok, camera_reason = false, "return map was not restored"
		if return_ok and return_darkness_ok then
			WaitForDeferredSurfaceScene(return_map)
			camera_ok, camera_reason = RestoreDeferredElevatorCamera(return_camera, return_map)
		end
		request.return_result = return_result
		request.return_darkness_ok = return_darkness_ok
		request.return_darkness_reason = return_darkness_reason
		request.camera_ok = camera_ok
		request.camera_reason = camera_reason
		request.ok = target_ready and return_ok and return_darkness_ok and camera_ok
		request.reason = request.ok and "prepared underground and restored original view"
			or (not call_ok and tostring(call_result))
			or target.SuperBigMapUndergroundStretchFailed
			or (target_ready and not return_darkness_ok and tostring(return_darkness_reason))
			or (return_ok and not camera_ok and tostring(camera_reason))
			or (target_ready and "the original map view could not be restored")
			or "the underground first-access gate did not complete"
		finish_hidden_roundtrip()
		if fallback_screen_open then
			local close_screen = Global("LoadingScreenClose")
			if type(close_screen) == "function" then
				pcall(close_screen, fallback_screen_id, return_map.slot)
			end
			fallback_screen_open = false
		end
		if loading_started and type(end_loading) == "function" then
			-- This outer reference owns the complete hidden target-and-return round trip. All nested
			-- expansion work is complete now, so force the custom dialog closed even if an exceptional
			-- nested path left its reference count unbalanced.
			pcall(end_loading, true)
		end
		-- LinkThroughPassage rebuilds autoattachments while the target map is active, and map
		-- reactivation can rebuild them once more. Audit and enforce the completed-passage visuals
		-- only after the custom loading presentation has fully torn down, which is the exact boundary
		-- at which the player previously saw the entrance rocks return.
		local post_loading_markers_hidden = HideExistingCompletedPassageIndicators(
			"first-access loading teardown final boundary")
		ElevatorTraversalAudit("FIRST_ACCESS_POST_LOADING_PASSAGE_VISUALS", {
			request = request_id, markers_hidden = post_loading_markers_hidden,
			return_map = tostring(return_map), current_map = tostring(Global("CurrentMap")),
		}, return_map)
		request.done = true
		pcall(msg, completion_message, request)
	end)

	if request.done ~= true then
		wait_msg(completion_message, 300000)
	end
	if request.done ~= true then
		request.reason = "timed out while preparing the underground map"
	end
	ElevatorTraversalAudit("FIRST_ACCESS_END", {
		request = request_id, unit = tostring(unit), elevator = tostring(elevator),
		target = tostring(target), target_slot = tostring(target.slot),
		ok = tostring(request.ok == true), done = tostring(request.done == true),
		current_map = tostring(Global("CurrentMap")),
		prepared = tostring(target.SuperBigMapUndergroundPrepared == true),
		view_restored = tostring(Global("CurrentMap") == return_map),
		return_map = tostring(return_map), return_slot = tostring(return_map.slot),
		camera_restored = tostring(request.camera_ok == true),
		camera_reason = tostring(request.camera_reason),
		return_darkness_ready = tostring(request.return_darkness_ok == true),
		return_darkness_reason = tostring(request.return_darkness_reason),
		reason = tostring(request.reason),
	}, TraversalObjectMap(unit))
	return request.ok == true, request.reason
end

local function RestoreDeferredUndergroundElevatorAccess()
	local State = SuperBigMap.State
	local patches = State.deferred_elevator_access_patches
	if type(patches) == "table" then
		for i = #patches, 1, -1 do
			local patch = patches[i]
			if patch.target and patch.target.UseElevator == patch.wrapper then
				patch.target.UseElevator = patch.original
			end
		end
	end
	State.deferred_elevator_access_patches = nil
	State.deferred_elevator_access_patch_version = nil
	State.deferred_elevator_hidden_roundtrip_active = nil
end

local function PatchDeferredUndergroundElevatorAccess(source)
	local State = SuperBigMap.State
	local installed = State.deferred_elevator_access_patches
	local function patch_is_intact(patch)
		if patch.target and patch.target.UseElevator == patch.wrapper then return true end
		-- Runtime diagnostics intentionally wrap this gate. Treat the gate as intact when it is the
		-- diagnostic wrapper's immediate predecessor; otherwise lifecycle re-verification would stack
		-- a second first-access gate each time ApplyModBehavior runs.
		for _, diagnostic in ipairs(State.elevator_traversal_diagnostic_patches or {}) do
			if diagnostic.target == patch.target and diagnostic.method == "UseElevator"
				and diagnostic.original == patch.wrapper
				and patch.target.UseElevator == diagnostic.wrapper then
				return true
			end
		end
		return false
	end
	if State.deferred_elevator_access_patch_version == DEFERRED_ELEVATOR_ACCESS_PATCH_VERSION
		and type(installed) == "table" then
		local intact = #installed > 0
		for _, patch in ipairs(installed) do
			if not patch_is_intact(patch) then
				intact = false
				break
			end
		end
		if intact then return true end
	end
	RestoreDeferredUndergroundElevatorAccess()

	local targets, seen = {}, setmetatable({}, { __mode = "k" })
	local unit_class = Engine.ClassTable and Engine.ClassTable("Unit")
	if type(unit_class) == "table" then targets[#targets + 1] = { name = "Unit", class = unit_class } end
	local descendants = Global("ClassDescendants")
	if type(descendants) == "function" then
		pcall(descendants, "Unit", function(name, class, output)
			if type(class) == "table" then output[#output + 1] = { name = name, class = class } end
		end, targets)
	end
	local patches = {}
	for _, entry in ipairs(targets) do
		local class = entry.class
		local original = class and class.UseElevator
		if type(original) == "function" and not seen[class] then
			seen[class] = true
			local label = tostring(entry.name)
			local wrapper = function(unit, elevator, ...)
				if deferred_elevator_access_by_unit[unit] == true then
					return UseElevatorWithRoverCloseRangeFallback(original, unit, elevator, ...)
				end
				local target = DeferredUndergroundTargetForElevator(elevator)
				local needs_prepare = target and NeedsDeferredUndergroundPreparation(target)
				if needs_prepare ~= true then
					return UseElevatorWithRoverCloseRangeFallback(original, unit, elevator, ...)
				end
				deferred_elevator_access_by_unit[unit] = true
				local call_ok, prepared, reason = pcall(
					PrepareDeferredUndergroundForElevator, unit, elevator, target)
				deferred_elevator_access_by_unit[unit] = nil
				if not call_ok then
					reason = prepared
					prepared = false
				end
				if prepared ~= true then
					ShowDeferredUndergroundAccessFailure(reason)
					return false
				end
				-- The map switch can replace the underground counterpart while preserving the surface
				-- elevator. Vanilla reads elevator.other only after walking to the entrance, so resume
				-- with the original surface object and its freshly restored backlink.
				return UseElevatorWithRoverCloseRangeFallback(original, unit, elevator, ...)
			end
			class.UseElevator = wrapper
			patches[#patches + 1] = {
				target = class, original = original, wrapper = wrapper, label = label,
			}
		end
	end
	State.deferred_elevator_access_patches = patches
	State.deferred_elevator_access_patch_version = DEFERRED_ELEVATOR_ACCESS_PATCH_VERSION
	ElevatorTraversalAudit("FIRST_ACCESS_PATCH_INSTALLED", {
		source = tostring(source), patches = #patches,
	}, Global("CurrentMap"))
	return #patches > 0
end

local function ResolveHudUndergroundTarget(button)
	local entry = button and button.context
	local entry_source = "button.context"
	if entry and entry.index then
		local map_switch = Global("MapSwitchClass")
		if type(map_switch) == "table" and type(map_switch.GetEntries) == "function" then
			local ok, entries = pcall(map_switch.GetEntries)
			if ok and type(entries) == "table" then
				entry = entries[entry.index]
				entry_source = "MapSwitchClass.GetEntries[index]"
			else
				entry_source = "MapSwitchClass.GetEntries failed"
			end
		end
	end
	local target = button and button.Map or entry and entry.Map
	return target, entry, entry_source
end

-- The generated HUD handler was observed reaching CurrentMapChangeDone without calling the
-- replaceable global ChangeCurrentMapSlot in v478. Wrap each concrete HUD button's OnPress too,
-- so the underground symbol has a direct, deterministic route into our gate. This composes with
-- later generic constructor wrappers and leaves surface/asteroid entries untouched.
local function PatchDeferredUndergroundHudAccess(source)
	local State = SuperBigMap.State
	local hud_class = Engine.ClassTable("HUDButtonMapSwitch")
	local current = hud_class and hud_class.Init
	if type(current) ~= "function" then
		return false
	end
	if current == State.underground_hud_init_wrapper
		and State.underground_hud_patch_version == GENERATOR_PATCH_VERSION then
		return true
	end
	-- Another engine/mod layer may wrap this constructor after us. Preserve that generic chain
	-- instead of wrapping it a second time: our stored wrapper remains its predecessor, while the
	-- CurrentMapChangeDone recovery independently guarantees preparation if a reload replaced it.
	if State.underground_hud_init_wrapper ~= nil
		and current ~= State.underground_hud_init_wrapper
		and State.underground_hud_patch_version == GENERATOR_PATCH_VERSION then
		return true
	end
	if current == State.underground_hud_init_wrapper
		and type(State.original_underground_hud_init) == "function" then
		current = State.original_underground_hud_init
		hud_class.Init = current
	end
	State.original_underground_hud_init = current
	-- Capture the predecessor in this closure. Never read State.original_underground_hud_init from
	-- inside the wrapper: lifecycle re-verification may update that shared field later, and v479's
	-- mutable lookup allowed two generic wrapper layers to call one another indefinitely.
	local captured_original_init = current
	local wrapper = function(self, parent, context)
		local depth = (State.underground_hud_init_depth or 0) + 1
		State.underground_hud_init_depth = depth
		if depth > 1 then
			State.underground_hud_init_depth = depth - 1
			return
		end
		local ok_init, result = pcall(captured_original_init, self, parent, context)
		State.underground_hud_init_depth = depth - 1
		if not ok_init then
			error(result)
		end
		local frame = self and self[1]
		if type(frame) ~= "table" or type(frame.OnPress) ~= "function" then
			return result
		end
		if frame.SuperBigMapUndergroundAccessPressVersion == GENERATOR_PATCH_VERSION then
			return result
		end
		local original_press = frame.OnPress
		frame.OnPress = function(button, gamepad)
			local target, entry, entry_source = ResolveHudUndergroundTarget(button)
			local needs_prepare, reason = NeedsDeferredUndergroundPreparation(target)
			if not needs_prepare then
				return original_press(button, gamepad)
			end
			if button.SuperBigMapUndergroundAccessClickRunning == true then
				return
			end
			local create_thread = Global("CreateRealTimeThread")
			if type(create_thread) ~= "function" then
				return original_press(button, gamepad)
			end
			button.SuperBigMapUndergroundAccessClickRunning = true
			create_thread(function()
				local gate = State.change_current_map_slot_wrapper
				if type(gate) == "function" and target and target.slot then
					gate(target.slot, true, "idChangeCurrentMapSlot")
				end
				button.SuperBigMapUndergroundAccessClickRunning = false
			end)
			return
		end
		frame.SuperBigMapUndergroundAccessPressVersion = GENERATOR_PATCH_VERSION
		return result
	end
	hud_class.Init = wrapper
	State.underground_hud_init_wrapper = wrapper
	State.underground_hud_patch_version = GENERATOR_PATCH_VERSION
	return true
end

-- FIRST-ACCESS GATE. Every vanilla HUD/object route that changes between already-loaded map
-- slots funnels through ChangeCurrentMapSlot. Hold that one call before it emits CurrentMapChange
-- or exposes the target map, run the complete deferred underground pipeline, and switch only on
-- success. The normal map-switch loading screen is opened BEFORE the heavy work and kept open
-- across the eventual switch. The committed entrance footprint is naturally valid before the
-- native passage-pad preparation runs; final alignment never turns an invalid candidate into one.
local function PatchDeferredUndergroundAccess(source)
	if not cfg_bool("EXPANSION_STEP_02_STRETCH_AND_TRANSFORM_VANILLA_SOURCE", false) then return false end
	PatchSupplyGridOverlayCopyGuard(source)
	PatchElevatorSupplyTransactionBoundary(source)
	SuperBigMap.ElevatorSupplyRepair.PatchConsumerConnection(source)
	local diagnostics_removed = RestoreExpandedElevatorPowerGate()
	local function reapply_removed_diagnostics()
		if diagnostics_removed and cfg_bool("DEBUG_ELEVATOR_TRAVERSAL", false) then
			PatchElevatorTraversalDiagnostics()
		end
	end
	local State = SuperBigMap.State
	local current = Global("ChangeCurrentMapSlot")
	if type(current) ~= "function" then
		PatchDeferredUndergroundHudAccess(source)
		RestoreDeferredUndergroundElevatorAccess()
		reapply_removed_diagnostics()
		return false
	end
	if current == State.change_current_map_slot_wrapper
		and State.underground_access_patch_version == GENERATOR_PATCH_VERSION then
		PatchDeferredUndergroundHudAccess(source)
		PatchDeferredUndergroundElevatorAccess(source)
		reapply_removed_diagnostics()
		return true
	end
	-- Hot-reload upgrade: unwrap our previous closure before capturing the vanilla original.
	if current == State.change_current_map_slot_wrapper
		and type(State.original_change_current_map_slot) == "function" then
		current = State.original_change_current_map_slot
		rawset(_G, "ChangeCurrentMapSlot", current)
	end
	State.original_change_current_map_slot = current
	local captured_original_switch = current
	local wrapper = function(map_slot, loading_screen, loading_screen_id)
		-- Immutable predecessor: later lifecycle verification may update shared patch state, but an
		-- already-installed closure must never change which function it calls.
		local original = captured_original_switch
		if type(original) ~= "function" then
			return
		end
		local maps = Global("Maps")
		local target = type(maps) == "table" and maps[map_slot] or nil
		RestoreDeferredUndergroundGeometry(target)
		local env = target and target.mapdata and target.mapdata.Environment
		local needs_prepare, decision = NeedsDeferredUndergroundPreparation(target)
		if not needs_prepare then
			return original(map_slot, loading_screen, loading_screen_id)
		end

		-- A second switch request can arrive while the first caller is preparing the map. Wait for
		-- that authoritative run rather than launching a second one over partially changed grids.
		if target.SuperBigMapUndergroundStretchRunning == true then
			local wait_msg = Global("WaitMsg")
			if type(wait_msg) == "function" then
				wait_msg("SuperBigMapUndergroundExpansionDone", 120000)
			end
			if target.SuperBigMapUndergroundStretchDone == true then
				return original(map_slot, loading_screen, loading_screen_id)
			end
		end

		local function show_failure(reason)
			local create_box = Global("CreateMessageBox")
			if type(create_box) == "function" then
				local untranslated = Global("Untranslated")
				local wrap = type(untranslated) == "function" and untranslated or function(s) return s end
				pcall(create_box, nil, wrap("Super Big Map"), wrap(
					"The underground could not be prepared safely, so access remains blocked. "
					.. "\n\n" .. tostring(reason or "Unknown error")))
			end
		end

		if target.SuperBigMapUndergroundStretchFailed
			or target.SuperBigMapUndergroundPreparationFailed == true then
			show_failure(target.SuperBigMapUndergroundStretchFailed
				or "A previous underground preparation attempt failed")
			return false
		end

		local screen_id = loading_screen_id or "idChangeCurrentMapSlot"
		local screen_open = false
		local open_screen = Global("LoadingScreenOpen")
		local close_screen = Global("LoadingScreenClose")
		local wait_render = Global("WaitRenderMode")
		-- Own one reference outside the nested underground pipeline. The pipeline releases only its
		-- own reference when terrain work ends. Establish the custom "Building underground map"
		-- presentation while the live Surface is still visible; opening vanilla's black loading
		-- screen first creates the exact black interval this cover is meant to eliminate.
		local first_access_cover_started = false
		local first_access_cover_visible = false
		local begin_first_access_cover = SuperBigMap.ExpansionLoadingBegin
		local end_first_access_cover = SuperBigMap.ExpansionLoadingEnd
		if type(begin_first_access_cover) == "function" then
			local begin_ok, visible = pcall(begin_first_access_cover, "underground")
			first_access_cover_started = begin_ok
			first_access_cover_visible = begin_ok and visible == true
		end
		-- A renderer that cannot create the frozen custom backdrop keeps vanilla's screen as a
		-- state-based fallback. It stays behind any custom dialog that becomes ready later.
		if not first_access_cover_visible and type(open_screen) == "function" then
			screen_open = pcall(open_screen, screen_id, map_slot)
			if screen_open and type(wait_render) == "function" then
				pcall(wait_render, "ui")
			end
		end
		local function release_first_access_cover()
			if not first_access_cover_started then return end
			first_access_cover_started = false
			if type(end_first_access_cover) == "function" then
				pcall(end_first_access_cover)
			end
		end

		SetLoadingPhase("Preparing the underground map for first access")
		local ok, err = RunUndergroundStretchIfEnabled(target, true)
		if ok ~= true then
			if screen_open then
				if type(close_screen) == "function" then close_screen(screen_id, map_slot) end
				if type(wait_render) == "function" then wait_render("scene") end
			end
			release_first_access_cover()
			show_failure(err or target.SuperBigMapUndergroundStretchFailed or "Preparation did not complete")
			LoadingFinish("underground first-access preparation failed", target,
				{ error = tostring(err or target.SuperBigMapUndergroundStretchFailed) }, false)
			return false
		end
		-- The loading cover is already owned. Make the destination's vanilla blanket state a
		-- prerequisite of exposing the completed map, rather than repairing it after a frame.
		local darkness_ready, darkness_reason =
			SuperBigMap.EnsureVanillaDarknessReady(target)
		if darkness_ready ~= true then
			if screen_open and type(close_screen) == "function" then
				close_screen(screen_id, map_slot)
			end
			release_first_access_cover()
			show_failure("Underground darkness initialization failed: "
				.. tostring(darkness_reason))
			LoadingFinish("underground first-access darkness preparation failed", target,
				{ error = tostring(darkness_reason) }, false)
			return false
		end

		SetLoadingPhase("Opening the completed underground map")
		-- We already own the screen, so suppress the original's open/close pair and close it only
		-- after ChangeCurrentMapSlot has switched maps and waited for scene rendering.
		local switch_restore_token = CurrentElevatorRestoreToken(target)
		local switch_restore_token_id = switch_restore_token and switch_restore_token.token_id
		WonderVerticalDiagnostics.LogAll(target, "before_underground_map_switch")
		local original_loading_screen = loading_screen
		if first_access_cover_started or screen_open then
			-- Lua's `condition and false or value` cannot produce false. Assign explicitly so vanilla
			-- cannot open a second black loading screen over the retained SBM presentation.
			original_loading_screen = false
		end
		local result = original(map_slot, original_loading_screen, loading_screen_id)
		WonderVerticalDiagnostics.LogAll(target, "immediately_after_underground_map_switch")
		local darkness_confirmed, darkness_confirm_reason =
			SuperBigMap.EnsureVanillaDarknessReady(target)
		if darkness_confirmed ~= true then
			target.SuperBigMapUndergroundPreparationFailed = true
			target.SuperBigMapUndergroundStretchFailed = tostring(darkness_confirm_reason)
			if screen_open and type(close_screen) == "function" then
				close_screen(screen_id, map_slot)
			end
			release_first_access_cover()
			show_failure("Underground darkness finalization failed: "
				.. tostring(darkness_confirm_reason))
			LoadingFinish("underground map-switch darkness finalization failed", target,
				{ error = tostring(darkness_confirm_reason) }, false)
			return false
		end
		-- ChangeCurrentMapSlot only waits for scene mode; unlike a full ChangeMap it does not wait
		-- for ResourceManager IO. Deferred wonders were created moments earlier, so keep our loading
		-- screen alive until their first visible texture targets have become stable.
		local renderer_settled, renderer_result = SettleUndergroundSceneResources(
			target, "completed underground map became visible")
		WonderVerticalDiagnostics.LogAll(target, "after_underground_became_visible")
		-- CurrentMapChangeDone is synchronous inside the original switch. It must have consumed the
		-- queued token; never perform a post-return reconstruction here, because that would recreate
		-- the old race with later engine lifecycle work.
		local after_token = switch_restore_token_id and CurrentElevatorRestoreToken(
			target, switch_restore_token_id) or nil
		local lifecycle_failed = after_token and after_token.status == "failed"
		local lifecycle_missed = after_token and after_token.status == "queued"
		local wonder_reseat_failure = target.SuperBigMapWonderLifecycleReseatFailed
		if lifecycle_failed or lifecycle_missed or wonder_reseat_failure then
			local restored_result = wonder_reseat_failure
				or after_token and after_token.failure or
				"CurrentMapChangeDone did not consume Elevator restore token "
				.. tostring(switch_restore_token_id)
			target.SuperBigMapUndergroundPreparationFailed = true
			target.SuperBigMapUndergroundStretchFailed = tostring(restored_result)
			if screen_open and type(close_screen) == "function" then close_screen(screen_id, map_slot) end
			release_first_access_cover()
			show_failure("Underground map finalization failed at the lifecycle boundary: "
				.. tostring(restored_result))
			LoadingFinish("underground map-switch finalization failed", target,
				{ error = tostring(restored_result), token = tostring(switch_restore_token_id) }, false)
			return false
		end
		if screen_open and type(close_screen) == "function" then close_screen(screen_id, map_slot) end
		release_first_access_cover()
		LoadingFinish("underground first access complete", target, {
			elevator_token = tostring(switch_restore_token_id),
			elevator_token_status = tostring(after_token and after_token.status or "consumed-or-none"),
			renderer_resources_settled = tostring(renderer_settled),
			renderer_resource_wait = tostring(renderer_result),
			darkness_ready = tostring(darkness_confirmed == true),
			darkness_reason = tostring(darkness_confirm_reason),
		}, true)
		return result
	end
	rawset(_G, "ChangeCurrentMapSlot", wrapper)
	State.change_current_map_slot_wrapper = wrapper
	State.underground_access_patch_version = GENERATOR_PATCH_VERSION
	PatchDeferredUndergroundHudAccess(source)
	PatchDeferredUndergroundElevatorAccess(source)
	reapply_removed_diagnostics()
	return true
end

-- Last-resort safety net for switch routes that bypass both replaceable entry points. It runs
-- immediately after CurrentMapChangeDone in its own real-time thread, covers the already-current
-- underground with a loading screen, and completes the exact same atomic preparation pipeline.
-- This also covers generated HUD routes that bypass the replaceable entry points.
local function HandleDeferredUndergroundMapChange(map_slot, map)
	local needs_prepare, decision = NeedsDeferredUndergroundPreparation(map)
	if not needs_prepare then return false end
	if underground_recovery_maps[map] == true then
		return true
	end
	local create_thread = Global("CreateRealTimeThread")
	if type(create_thread) ~= "function" then
		return false
	end
	underground_recovery_maps[map] = true
	create_thread(function()
		local screen_id = "idSuperBigMapUndergroundFirstAccessRecovery"
		local open_screen = Global("LoadingScreenOpen")
		local close_screen = Global("LoadingScreenClose")
		local wait_render = Global("WaitRenderMode")
		local screen_open = type(open_screen) == "function"
		if screen_open then
			open_screen(screen_id, map_slot)
			if type(wait_render) == "function" then wait_render("ui") end
		end
		SetLoadingPhase("Preparing the underground map after a bypassed first-access switch")
		local ok, err = RunUndergroundStretchIfEnabled(map, true)
		local renderer_settled, renderer_result = true, "not-run"
		if ok == true then
			local darkness_ready, darkness_reason =
				SuperBigMap.EnsureVanillaDarknessReady(map)
			if darkness_ready ~= true then
				ok, err = false, "underground darkness initialization failed: "
					.. tostring(darkness_reason)
			else
				renderer_settled, renderer_result = SettleUndergroundSceneResources(
					map, "already-current underground recovery completed")
			end
		end
		if screen_open and type(close_screen) == "function" then
			close_screen(screen_id, map_slot)
			if type(wait_render) == "function" then wait_render("scene") end
		end
		underground_recovery_maps[map] = nil
		LoadingFinish("underground bypass-recovery complete", map,
			{
				error = ok == true and "" or tostring(err),
				renderer_resources_settled = tostring(renderer_settled),
				renderer_resource_wait = tostring(renderer_result),
			}, ok == true)
		if ok ~= true then
			local create_box = Global("CreateMessageBox")
			if type(create_box) == "function" then
				local untranslated = Global("Untranslated")
				local wrap = type(untranslated) == "function" and untranslated or function(s) return s end
				pcall(create_box, nil, wrap("Super Big Map"), wrap(
					"The underground first-access route bypassed its preparation gate, and recovery failed. "
					.. "\n\n" .. tostring(err or "Unknown error")))
			end
		end
	end)
	return true
end

local MapGeneration = {}

-- Scenario-agnostic one-shot twin seam used only by the parity harness. Ordinary gameplay never
-- calls this method and therefore retains the production AsyncRand reservation. The expanded path
-- still consumes that one production draw to preserve stream cardinality, then substitutes the
-- freshly captured vanilla twin input at the same pending-seed consumer transaction.
function MapGeneration.SetTwinUndergroundSeedForTest(seed, authority_tag)
	if type(seed) ~= "number" then return false, "seed must be numeric" end
	SuperBigMap.State.test_twin_underground_seed = {
		seed = seed,
		authority_tag = tostring(authority_tag or "fresh_vanilla_twin"),
	}
	return true
end

-- Scenario-agnostic observer used only by the harness determinism cohort. The hook is deliberately
-- stored in transient shared state, is never serialized, and must return literal true at every
-- notification. This setter changes no production algorithm or game data by itself.
function MapGeneration.SetDeterminismCaptureHookForTest(hook, authority_tag)
	if type(hook) ~= "function" then return false, "hook must be a function" end
	SuperBigMap.State.test_determinism_capture = {
		hook = hook,
		authority_tag = tostring(authority_tag or "harness_determinism_capture"),
		counts = {},
	}
	return true
end

function MapGeneration.NotifyDeterminismCaptureForTest(stage, map, details)
	return SuperBigMap.NotifyDeterminismCaptureForTest(stage, map, details)
end

MapGeneration.RunUndergroundStretchIfEnabled = RunUndergroundStretchIfEnabled
MapGeneration.ShouldDeferStretchRebuilds = ShouldDeferStretchRebuilds
MapGeneration.FinalizeExpandedMap = FinalizeExpandedMap
MapGeneration.AttachPendingMapState = AttachPendingMapState
MapGeneration.PrepareMapDataForExpansion = PrepareMapDataForExpansion
MapGeneration.PatchRandomMapGenerator = PatchRandomMapGenerator
MapGeneration.PatchDeferredBreakthroughAnomalyInitialization =
	SuperBigMap.PatchDeferredBreakthroughAnomalyInitialization
MapGeneration.FinalizeDeferredBreakthroughAnomalyInitialization =
	SuperBigMap.FinalizeDeferredBreakthroughAnomalyInitialization
MapGeneration.PatchDeferredUndergroundAccess = PatchDeferredUndergroundAccess
MapGeneration.PatchEntranceBadgePosition = PatchEntranceBadgePosition
MapGeneration.RestoreEntranceBadgePositions = RestoreEntranceBadgePositions
MapGeneration.PatchCaveInShapePoints = PatchCaveInShapePoints
MapGeneration.PatchUndergroundWonderShapePoints = PatchUndergroundWonderShapePoints
MapGeneration.ReseatExpandedUndergroundWonders = WonderVerticalDiagnostics.ReseatAll
MapGeneration.HandleDeferredUndergroundMapChange = HandleDeferredUndergroundMapChange
MapGeneration.HandlePendingUndergroundElevatorRestore = HandlePendingUndergroundElevatorRestore
MapGeneration.RepairExpandedElevatorSupplyNetworks = SuperBigMap.ElevatorSupplyRepair.Networks
MapGeneration.RepairExpandedElevatorCargoNetworks = SuperBigMap.ElevatorSupplyRepair.CargoNetworks
MapGeneration.ScheduleExpandedElevatorSupplyRepair = SuperBigMap.ElevatorSupplyRepair.Schedule
MapGeneration.RepairExpandedElevatorPassageVisuals = HideExistingCompletedPassageIndicators
MapGeneration.RestoreDeferredVehicleNightLights = RestoreDeferredVehicleNightLights
MapGeneration.RebuildExpandedElevatorWaypointChains = RebuildExpandedElevatorWaypointChains
MapGeneration.SyncMapDataToGrids = SyncMapDataToGrids
MapGeneration.RunSurfaceStretchIfEnabled = RunSurfaceStretchIfEnabled
MapGeneration.RestoreTransferredPrefabFeatureGameLogic =
	RestoreTransferredPrefabFeatureGameLogic
MapGeneration.NotifyGenerationMilestone = NotifyGenerationMilestone
MapGeneration.RecoverPersistedUndergroundReadiness =
	SuperBigMap.GenerationReadiness.RecoverPersistedUnderground
MapGeneration.RecoverLoadedUndergroundReadiness =
	SuperBigMap.GenerationReadiness.RecoverLoadedUnderground
MapGeneration.ReinvalidateExpandedTerrain = ReinvalidateExpandedTerrain
MapGeneration.RestorePreparedMapDataForVanillaSession = RestorePreparedMapDataForVanillaSession

function MapGeneration.ApplyModBehavior()
	local generate_source = cfg_bool("EXPANSION_STEP_01_GENERATE_AND_CAPTURE_VANILLA_SOURCE", false)
	local transform_source = cfg_bool("EXPANSION_STEP_02_STRETCH_AND_TRANSFORM_VANILLA_SOURCE", false)
	SuperBigMap.RestoreLegacyBuriedWonderConcealment()
	if not generate_source then
		MapGeneration.RestoreVanillaBehavior()
		return false
	end
	-- Remove any stage-02 wrappers left by an in-session config reload, then install the
	-- exact-vanilla generation wrapper owned by stage 01.
	if not transform_source then MapGeneration.RestoreVanillaBehavior() end
	PatchRandomMapGenerator()
	-- Rebuild observational wrappers after the functional first-access gate. This makes the
	-- diagnostic layer disposable without ever removing or duplicating the gate below it.
	RestoreElevatorTraversalDiagnostics()
	if transform_source then
		PatchEntranceBadgePosition()
		PatchCaveInShapePoints()
		PatchUndergroundWonderShapePoints()
		PatchDeferredUndergroundAccess("ApplyModBehavior")
	end
	-- Keep diagnostics outermost so a first-access command is traced from the player's click,
	-- through deferred preparation, to the eventual vanilla transfer.
	if cfg_bool("DEBUG_ELEVATOR_TRAVERSAL", false) then
		PatchElevatorTraversalDiagnostics()
	end
	-- FileSystemChanged can call Apply while native class tables are still being rebuilt. Defer the
	-- actual native disconnect/connect and command-center refresh to the next game-time task; load
	-- and map lifecycle handlers still run their authoritative synchronous old-save repairs.
	SuperBigMap.ElevatorSupplyRepair.Schedule(Global("CurrentMap"),
		"ApplyModBehavior stable-boundary Elevator repair")
	return true
end

-- Restoring only affects future generation; already-expanded maps retain their terrain.
function MapGeneration.RestoreVanillaBehavior()
	local State = SuperBigMap.State or {}
	ReleaseSharedBuriedWonderTexturePins()
	RestoreDeferredVehicleNightLights(Global("CurrentMap"))
	for target, record in pairs(offscreen_vehicle_light_suppressions) do
		if target and type(record) == "table" then
			target.NightLightsState = record.previous
		end
		offscreen_vehicle_light_suppressions[target] = nil
	end
	RestoreElevatorTraversalDiagnostics()
	RestoreDeferredUndergroundElevatorAccess()
	RestoreExpandedElevatorPowerGate()
	-- Restore process-shared MapData presets as part of the domain teardown too,
	-- not only through the main-menu convenience path. This covers config disable,
	-- hot reload, and any alternate session exit that calls Lifecycle.Disable.
	RestorePreparedMapDataForVanillaSession("MapGeneration.RestoreVanillaBehavior")
	local city_class = Engine.ClassTable and Engine.ClassTable("City") or Global("City")
	if type(city_class) == "table" and State.breakthrough_init_wrapper
		and city_class.InitBreakThroughAnomalies == State.breakthrough_init_wrapper
		and type(State.original_city_init_breakthrough_anomalies) == "function" then
		city_class.InitBreakThroughAnomalies = State.original_city_init_breakthrough_anomalies
	end
	State.breakthrough_init_wrapper = nil
	State.original_city_init_breakthrough_anomalies = nil
	State.breakthrough_init_patch_version = nil
	local generator_class = Global("RandomMapGenerator")
	if type(generator_class) == "table" then
		if type(State.generator_original_generate) == "function" then
			generator_class.Generate = State.generator_original_generate
		end
		if type(State.generator_original_do_generate) == "function" then
			generator_class.DoGenerate = State.generator_original_do_generate
		end
		if type(State.generator_original_on_generate_logic) == "function" then
			generator_class.OnGenerateLogic = State.generator_original_on_generate_logic
		end
	end
	for _, target in ipairs(State.additional_map_seed_patch_targets or {}) do
		local env = type(target) == "table" and target.env or nil
		if type(env) == "table" then
			local function read(name)
				if type(target.reader) == "function" then return target.reader(name) end
				return rawget(env, name)
			end
			local function write(name, value)
				if type(target.writer) == "function" then return target.writer(name, value) end
				rawset(env, name, value)
				return rawget(env, name) == value
			end
			if read("GenerateAdditionalMaps") == State.generate_additional_maps_wrapper
				and type(target.original_additional) == "function" then
				write("GenerateAdditionalMaps", target.original_additional)
			end
			if read("FillRandomMapGen") == State.fill_random_map_gen_wrapper
				and type(target.original_fill) == "function" then
				write("FillRandomMapGen", target.original_fill)
			end
		end
	end
	State.original_generate_additional_maps = nil
	State.original_fill_random_map_gen = nil
	State.generate_additional_maps_wrapper = nil
	State.fill_random_map_gen_wrapper = nil
	State.additional_map_seed_patch_targets = nil
	State.pending_vanilla_underground_seed = nil
	State.underground_seed_reservation_trace = nil
	State.test_twin_underground_seed = nil
	State.additional_map_seed_patch_version = nil
	State.generator_original_generate = nil
	State.generator_original_do_generate = nil
	State.generator_original_on_generate_logic = nil
	State.generator_generate_wrapper = nil
	State.generator_do_generate_wrapper = nil
	State.generator_on_generate_logic_wrapper = nil
	State.rmg_placement_active_map = nil
	State.sbm_entrance_pads = nil
	State.vanilla_source_migration_active = nil
	State.generator_patch_version = nil
	local surface_passage_class = Engine.ClassTable and Engine.ClassTable("SurfacePassage")
	if type(surface_passage_class) == "table" and State.deferred_tunnel_spawn_wrapper
		and surface_passage_class.Spawn == State.deferred_tunnel_spawn_wrapper
		and type(State.original_surface_passage_spawn) == "function" then
		surface_passage_class.Spawn = State.original_surface_passage_spawn
	end
	State.deferred_tunnel_spawn_wrapper = nil
	State.original_surface_passage_spawn = nil
	local elevator_base_class = Engine.ClassTable and Engine.ClassTable("ElevatorBase")
	if type(elevator_base_class) == "table" and State.persistent_passage_marker_wrapper
		and elevator_base_class.LinkThroughPassage == State.persistent_passage_marker_wrapper
		and type(State.original_elevator_link_through_passage) == "function" then
		elevator_base_class.LinkThroughPassage = State.original_elevator_link_through_passage
	end
	State.original_elevator_link_through_passage = nil
	State.persistent_passage_marker_wrapper = nil
	State.persistent_passage_marker_patch_version = nil
	if State.change_current_map_slot_wrapper
		and Global("ChangeCurrentMapSlot") == State.change_current_map_slot_wrapper
		and type(State.original_change_current_map_slot) == "function" then
		rawset(_G, "ChangeCurrentMapSlot", State.original_change_current_map_slot)
	end
	State.change_current_map_slot_wrapper = nil
	State.original_change_current_map_slot = nil
	State.underground_access_patch_version = nil
	local hud_class = Engine.ClassTable and Engine.ClassTable("HUDButtonMapSwitch")
	if type(hud_class) == "table" and State.underground_hud_init_wrapper
		and hud_class.Init == State.underground_hud_init_wrapper
		and type(State.original_underground_hud_init) == "function" then
		hud_class.Init = State.original_underground_hud_init
	end
	State.underground_hud_init_wrapper = nil
	State.original_underground_hud_init = nil
	State.underground_hud_patch_version = nil
	State.underground_hud_init_depth = nil
	local elevator_supply_class = Engine.ClassTable and Engine.ClassTable("Elevator")
	if type(elevator_supply_class) == "table" and State.elevator_supply_connect_wrapper
		and elevator_supply_class.SupplyGridConnectElement == State.elevator_supply_connect_wrapper
		and type(State.original_elevator_supply_connect) == "function" then
		elevator_supply_class.SupplyGridConnectElement = State.original_elevator_supply_connect
	end
	if type(elevator_supply_class) == "table" and State.elevator_passage_merge_wrapper
		and elevator_supply_class.MergeGrids == State.elevator_passage_merge_wrapper
		and type(State.original_elevator_passage_merge_grids) == "function" then
		elevator_supply_class.MergeGrids = State.original_elevator_passage_merge_grids
	end
	State.elevator_supply_connect_wrapper = nil
	State.original_elevator_supply_connect = nil
	State.elevator_passage_merge_wrapper = nil
	State.original_elevator_passage_merge_grids = nil
	State.elevator_supply_boundary_patch_version = nil
	for _, patch in ipairs(type(State.expanded_supply_consumer_connect_patches) == "table"
		and State.expanded_supply_consumer_connect_patches or {}) do
		if type(patch) == "table" and type(patch.class) == "table"
			and patch.class.SupplyGridConnectElement == patch.wrapper
			and type(patch.original) == "function" then
			patch.class.SupplyGridConnectElement = patch.original
		end
	end
	State.expanded_supply_consumer_connect_patches = nil
	State.expanded_supply_consumer_connect_patch_version = nil
	State.elevator_supply_repair_scheduled = nil
	if State.supply_grid_overlay_copy_wrapper
		and Global("CopySupplyFragmentToOverlayGrid") == State.supply_grid_overlay_copy_wrapper
		and type(State.original_supply_grid_overlay_copy) == "function" then
		rawset(_G, "CopySupplyFragmentToOverlayGrid", State.original_supply_grid_overlay_copy)
	end
	State.supply_grid_overlay_copy_wrapper = nil
	State.original_supply_grid_overlay_copy = nil
	State.supply_grid_overlay_copy_patch_version = nil
	for key in pairs(blocked_maps) do blocked_maps[key] = nil end
	for key in pairs(underground_recovery_maps) do underground_recovery_maps[key] = nil end
	State.underground_elevator_restore_epoch =
		(State.underground_elevator_restore_epoch or 0) + 1
	for key, token in pairs(pending_underground_elevator_restores) do
		if type(token) == "table" then
			token.cancelled = true
			token.status = "teardown"
			for _, record in ipairs(token.records or {}) do
				if type(record.rebuilt_elevator) == "table" then
					record.rebuilt_elevator.SuperBigMapElevatorRestoreToken = nil
					record.rebuilt_elevator.SuperBigMapElevatorRestoreRecord = nil
				end
			end
		end
		pending_underground_elevator_restores[key] = nil
	end
	for key in pairs(underground_elevator_restore_tokens) do
		underground_elevator_restore_tokens[key] = nil
	end
	RestoreEntranceBadgePositionPatch()
	RestoreCaveInShapePointsPatch()
	RestoreUndergroundWonderShapePointsPatch()
	SuperBigMap.RestoreLegacyBuriedWonderConcealment()
end

SuperBigMap.MapGeneration = MapGeneration

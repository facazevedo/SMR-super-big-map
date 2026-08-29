-- Detached, read-only engine probe for v968. Run only on a fully initialized Surface map.
-- Every failure is reported explicitly; this probe never relies on assert/error control flow.
local acceptance_failures = {}
local counts = {
	surface_maps = 0,
	exact_center_calls = 0,
	exact_center_accepts = 0,
	exact_center_rejections = 0,
	native_call_failures = 0,
	controlled_start_rejections = 0,
	controlled_neighbour_accepts = 0,
	output_mismatches = 0,
}
local contrary_tuple_count = 0

local function acceptance_failure(reason)
	acceptance_failures[#acceptance_failures + 1] = tostring(reason)
end

local surface
local maps = type(Maps) == "table" and Maps or {}
for _, map in pairs(maps) do
	if map and map.mapdata and map.mapdata.Environment == "Surface" then
		counts.surface_maps = counts.surface_maps + 1
		if not surface then surface = map end
	end
end

local hex_find_buildable = type(HexGridFindBuildable) == "function" and HexGridFindBuildable
local validate_shape = type(ValidateEachShapeHexPos) == "function" and ValidateEachShapeHexPos
local get_shape = type(GetExtendedSpawnShape) == "function" and GetExtendedSpawnShape
local get_unbuildable_z = type(buildUnbuildableZ) == "function" and buildUnbuildableZ
local world_to_hex = type(WorldToHex) == "function" and WorldToHex
local hex_to_world = type(HexToWorld) == "function" and HexToWorld
local point_fn = type(point) == "function" and point

if not surface or not surface.buildable or not surface.object_hex_grid then
	acceptance_failure("initialized Surface grids unavailable")
end
if not hex_find_buildable then acceptance_failure("HexGridFindBuildable unavailable") end
if not validate_shape then acceptance_failure("ValidateEachShapeHexPos unavailable") end
if not get_shape then acceptance_failure("GetExtendedSpawnShape unavailable") end
if not get_unbuildable_z then acceptance_failure("buildUnbuildableZ unavailable") end
if not world_to_hex then acceptance_failure("WorldToHex unavailable") end
if not hex_to_world then acceptance_failure("HexToWorld unavailable") end
if not point_fn then acceptance_failure("point unavailable") end

local shape
local unbuildable_z
local buildable = surface and surface.buildable
local object_grid = surface and surface.object_hex_grid
if #acceptance_failures == 0 then
	local shape_ok, shape_value = pcall(get_shape, "Elevator")
	if shape_ok and shape_value then
		shape = shape_value
	else
		acceptance_failure("Elevator shape unavailable")
	end
	local z_ok, z_value = pcall(get_unbuildable_z)
	if z_ok and z_value ~= nil then
		unbuildable_z = z_value
	else
		acceptance_failure("unbuildable sentinel unavailable")
	end
end

local function exact_center(q, r, angle)
	counts.exact_center_calls = counts.exact_center_calls + 1
	local original_z = false
	local function shape_pos_filter(sq, sr)
		local z = buildable:GetZ(sq, sr)
		original_z = original_z or z
		if z == unbuildable_z or z ~= original_z then return false end
		local obstructions = object_grid:GetBuildObstructions(sq, sr)
		if #obstructions > 0 then return false end
		return true
	end
	local function continue_check(cq, cr)
		local x, y = hex_to_world(cq, cr)
		return validate_shape(shape, point_fn(x, y), angle, shape_pos_filter) ~= true
	end
	local call_ok, bq, br, depth = pcall(hex_find_buildable, q, r, object_grid,
		buildable.z_grid, unbuildable_z, continue_check, 0)
	if not call_ok then
		counts.native_call_failures = counts.native_call_failures + 1
		acceptance_failure("depth-zero native call failed")
		return false, "native-call-failure"
	end
	if bq == q and br == r and depth == 0 then
		counts.exact_center_accepts = counts.exact_center_accepts + 1
		return true, "exact"
	end
	if bq == nil and br == nil and depth == nil then
		counts.exact_center_rejections = counts.exact_center_rejections + 1
		return false, "rejected"
	end
	contrary_tuple_count = contrary_tuple_count + 1
	return false, "contrary-tuple"
end

local neighbours = { { 1, 0 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { 0, -1 }, { 1, -1 } }
local pair
local scan_blocked = false
if #acceptance_failures == 0 then
	local size_ok, width, height = pcall(surface.GetMapSize, surface)
	height = height or width
	if not size_ok or type(width) ~= "number" or type(height) ~= "number" then
		acceptance_failure("Surface map size unavailable")
	else
		local center_ok, center_q, center_r = pcall(world_to_hex,
			point_fn(width / 2, height / 2))
		if not center_ok or type(center_q) ~= "number" or type(center_r) ~= "number" then
			acceptance_failure("Surface center hex unavailable")
		else
			for radius = 0, 8 do
				for dq = -radius, radius do
					for dr = -radius, radius do
						local q, r = center_q + dq, center_r + dr
						local valid, status = exact_center(q, r, 0)
						if status == "native-call-failure" or status == "contrary-tuple" then
							scan_blocked = true
							break
						end
						if valid then
							for _, delta in ipairs(neighbours) do
								local nq, nr = q + delta[1], r + delta[2]
								local neighbour_valid, neighbour_status = exact_center(nq, nr, 0)
								if neighbour_status == "native-call-failure"
									or neighbour_status == "contrary-tuple" then
									scan_blocked = true
									break
								end
								if neighbour_valid then
									pair = { q = q, r = r, nq = nq, nr = nr }
									break
								end
							end
						end
						if pair or scan_blocked then break end
					end
					if pair or scan_blocked then break end
				end
				if pair or scan_blocked then break end
			end
		end
	end
end
if not pair then acceptance_failure("no adjacent valid/invalid probe pair in radius 8") end

-- Force the start to reject and its known-valid neighbour to accept. A zero-depth call must not
-- traverse to the neighbour; the same neighbour passed directly must succeed at depth zero.
if pair and contrary_tuple_count == 0 and counts.native_call_failures == 0 then
	local function controlled_continue(q, r)
		return not (q == pair.nq and r == pair.nr)
	end
	local start_ok, q0, r0, d0 = pcall(hex_find_buildable, pair.q, pair.r, object_grid,
		buildable.z_grid, unbuildable_z, controlled_continue, 0)
	if not start_ok then
		counts.native_call_failures = counts.native_call_failures + 1
		acceptance_failure("controlled invalid-center native call failed")
	elseif q0 == nil and r0 == nil and d0 == nil then
		counts.controlled_start_rejections = counts.controlled_start_rejections + 1
	else
		counts.output_mismatches = counts.output_mismatches + 1
		if q0 ~= pair.q or r0 ~= pair.r or d0 ~= 0 then
			contrary_tuple_count = contrary_tuple_count + 1
		end
	end
	local neighbour_ok, nq0, nr0, nd0 = pcall(hex_find_buildable, pair.nq, pair.nr,
		object_grid, buildable.z_grid, unbuildable_z, controlled_continue, 0)
	if not neighbour_ok then
		counts.native_call_failures = counts.native_call_failures + 1
		acceptance_failure("controlled valid-neighbour native call failed")
	elseif nq0 == pair.nq and nr0 == pair.nr and nd0 == 0 then
		counts.controlled_neighbour_accepts = counts.controlled_neighbour_accepts + 1
	else
		counts.output_mismatches = counts.output_mismatches + 1
		if nq0 ~= nil or nr0 ~= nil or nd0 ~= nil then
			contrary_tuple_count = contrary_tuple_count + 1
		end
	end
end

if contrary_tuple_count > 0 then acceptance_failure("contrary native tuple observed") end
if counts.output_mismatches > 0 then acceptance_failure("controlled native output mismatch") end

local function compute_ok()
	return #acceptance_failures == 0 and pair ~= nil and contrary_tuple_count == 0
		and counts.native_call_failures == 0 and counts.output_mismatches == 0
		and counts.controlled_start_rejections == 1
		and counts.controlled_neighbour_accepts == 1
end

local ok = compute_ok()
local result = {
	schema = "smr.ralph.v968.exact-center-engine-probe.v3",
	ok = ok,
	acceptance_failure_count = #acceptance_failures,
	acceptance_failures = table.concat(acceptance_failures, "|"),
	surface_map_count = counts.surface_maps,
	exact_center_call_count = counts.exact_center_calls,
	exact_center_accept_count = counts.exact_center_accepts,
	exact_center_rejection_count = counts.exact_center_rejections,
	native_call_failure_count = counts.native_call_failures,
	contrary_tuple_count = contrary_tuple_count,
	output_mismatch_count = counts.output_mismatches,
	controlled_start_rejection_count = counts.controlled_start_rejections,
	controlled_neighbour_accept_count = counts.controlled_neighbour_accepts,
	pair_found = pair ~= nil,
	probe_radius_cap = 8,
}

return result

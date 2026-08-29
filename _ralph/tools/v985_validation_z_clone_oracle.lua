-- Deterministic Lua 5.3 oracle for the v985 post-publication validation-Z clone contract.

local shape = { { 0, 0 }, { 1, 0 }, { 0, 1 }, { -1, 1 } }
local function key(x, y) return tostring(x) .. ":" .. tostring(y) end
local function storage(q, r) return q + r / 2, r end

local Grid = {}
Grid.__index = Grid
function Grid:new(values)
	return setmetatable({ values = values or {}, freed = false }, self)
end
function Grid:get(x, y)
	if self.freed then error("get after free") end
	return self.values[key(x, y)]
end
function Grid:set(x, y, value)
	if self.freed then error("set after free") end
	self.values[key(x, y)] = value
end
function Grid:clone()
	local values = {}
	for k, value in pairs(self.values) do values[k] = value end
	return Grid:new(values)
end
function Grid:free()
	if self.freed then error("double free") end
	self.freed = true
end

local function walk_shape(center_q, center_r, callback)
	for _, offset in ipairs(shape) do
		if callback(center_q + offset[1], center_r + offset[2]) ~= true then return false end
	end
	return true
end

local function digest(descriptor)
	local value = descriptor.plan_digest
	for index, capsule in ipairs(descriptor.capsules) do
		value = (value * 48271 + capsule.validation_z + index) % 2147483647
	end
	return value == 0 and 1 or value
end

local function certificate(descriptor, report)
	if descriptor.capsule_planner_version ~= 7 or descriptor.plan_digest <= 0
		or descriptor.validation_z_digest <= 0 or #descriptor.capsules ~= 2
		or report.validation_z_certificates ~= 2
		or report.validation_z_digest ~= descriptor.validation_z_digest then return false end
	for _, capsule in ipairs(descriptor.capsules) do
		local z = capsule.validation_z
		if type(z) ~= "number" or z ~= z or z < 0 or z >= 65535
			or z ~= math.floor(z) then return false end
	end
	return digest(descriptor) == descriptor.validation_z_digest
end

local function follows_anchor(obstruction, anchor)
	return obstruction == anchor
		or obstruction and (obstruction.passage == anchor or obstruction.other == anchor
			or obstruction.linked_obj == anchor
			or obstruction.SuperBigMapDeferredElevatorPassage == anchor
			or obstruction.spawner == anchor)
end

local anchor = { id = "passage" }
local marker = { spawner = anchor }
local sign = { passage = anchor }
local obstruction_cells = {}
local function add_obstruction(q, r, object)
	local cell = obstruction_cells[key(q, r)]
	if not cell then cell = {}; obstruction_cells[key(q, r)] = cell end
	cell[#cell + 1] = object
end

local live = Grid:new()
for q = 8, 15 do
	for r = 17, 24 do
		local x, y = storage(q, r)
		live:set(x, y, 12000 + q + r)
	end
end
for _, offset in ipairs(shape) do
	local q, r = 10 + offset[1], 20 + offset[2]
	local x, y = storage(q, r)
	live:set(x, y, 13000) -- Published/flattened live grid, not historical validation Z.
	add_obstruction(q, r, anchor)
end
add_obstruction(10, 20, marker)
add_obstruction(10, 20, sign)

local descriptor = {
	capsule_planner_version = 7,
	plan_digest = 985291,
	capsules = {
		{ q = 10, r = 20, validation_z = 9000 },
		{ q = 40, r = 50, validation_z = 11000 },
	},
}
descriptor.validation_z_digest = digest(descriptor)
local report = {
	validation_z_certificates = 2,
	validation_z_digest = descriptor.validation_z_digest,
}

local before = {}
for k, value in pairs(live.values) do before[k] = value end
local function unchanged()
	for k, value in pairs(before) do if live.values[k] ~= value then return false end end
	for k in pairs(live.values) do if before[k] == nil then return false end end
	return live.freed == false
end

local function native_depth_zero(q, r, grid, obstruction_filter)
	local accepted = walk_shape(q, r, function(hq, hr)
		local x, y = storage(hq, hr)
		if grid:get(x, y) == nil then return false end
		for _, obstruction in ipairs(obstruction_cells[key(hq, hr)] or {}) do
			if not obstruction_filter(obstruction) then return false end
		end
		return true
	end)
	if accepted then return q, r, 0 end
	return nil, nil, nil
end

local live_q = native_depth_zero(10, 20, live, function() return false end)
local live_final_grid_rejects_self_occupancy = live_q == nil

local last_clone
local function validate_clone(capsule)
	if not certificate(descriptor, report) then return false end
	local clone_ok, clone = pcall(live.clone, live)
	if not clone_ok or not clone then return false end
	last_clone = clone
	local operation_ok, accepted = pcall(function()
		local restored = walk_shape(capsule.q, capsule.r, function(q, r)
			local x, y = storage(q, r)
			clone:set(x, y, capsule.validation_z)
			return true
		end)
		if not restored then return false end
		local expected_z
		local function obstruction_filter(obstruction)
			return follows_anchor(obstruction, anchor)
		end
		local q, r, depth = native_depth_zero(capsule.q, capsule.r, clone,
			obstruction_filter)
		walk_shape(capsule.q, capsule.r, function(hq, hr)
			local x, y = storage(hq, hr)
			local z = clone:get(x, y)
			expected_z = expected_z or z
			return z == capsule.validation_z and z == expected_z
		end)
		return q == capsule.q and r == capsule.r and depth == 0
	end)
	local free_ok = pcall(clone.free, clone)
	return operation_ok and accepted == true and free_ok and unchanged()
end

local exact_clone_accepted = validate_clone(descriptor.capsules[1])
local private_clone_freed = last_clone and last_clone.freed == true

local unrelated = { id = "unrelated" }
add_obstruction(10, 20, unrelated)
local unrelated_blocker_rejected = validate_clone(descriptor.capsules[1]) == false
table.remove(obstruction_cells[key(10, 20)])

local original_z = descriptor.capsules[1].validation_z
descriptor.capsules[1].validation_z = original_z + 1
local wrong_validation_z_rejected = validate_clone(descriptor.capsules[1]) == false
descriptor.capsules[1].validation_z = original_z

local live_grid_unchanged = unchanged()
local only_exact_footprint_restored = true
local footprint = {}
walk_shape(10, 20, function(q, r)
	local x, y = storage(q, r); footprint[key(x, y)] = true; return true
end)
local probe_clone = live:clone()
walk_shape(10, 20, function(q, r)
	local x, y = storage(q, r); probe_clone:set(x, y, 9000); return true
end)
for k, value in pairs(probe_clone.values) do
	if not footprint[k] and value ~= live.values[k] then only_exact_footprint_restored = false end
end
probe_clone:free()

local checks = {
	live_final_grid_rejects_self_occupancy = live_final_grid_rejects_self_occupancy,
	clone_accepts_exact_certified_pad = exact_clone_accepted,
	only_own_family_ignored = exact_clone_accepted,
	unrelated_blocker_rejected = unrelated_blocker_rejected,
	wrong_validation_z_rejected = wrong_validation_z_rejected,
	live_grid_unchanged = live_grid_unchanged,
	only_exact_footprint_restored = only_exact_footprint_restored,
	private_clone_freed = private_clone_freed,
}
local ok = true
for _, value in pairs(checks) do ok = ok and value == true end
print("ok=" .. tostring(ok))
for _, name in ipairs({
	"live_final_grid_rejects_self_occupancy", "clone_accepts_exact_certified_pad",
	"only_own_family_ignored", "unrelated_blocker_rejected",
	"wrong_validation_z_rejected", "live_grid_unchanged",
	"only_exact_footprint_restored", "private_clone_freed",
}) do print(name .. "=" .. tostring(checks[name])) end
os.exit(ok and 0 or 1)

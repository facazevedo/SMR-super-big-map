-- Pure executable oracle for the v998 Surface single-flush finalization transaction.
-- It models ownership and certification only; it never loads a map or calls an engine API.

local function decide(input)
	local out = {
		canonical = 0, local_pass = 0, buildable = 0, snapshots = 0,
		cleanup = false, optimized = false, published = false, blocked = false,
	}
	local exact = input.enabled == true and input.surface == true
		and input.pads == 2 and input.dirty_regions == 2
		and type(input.dirty_digest) == "number" and input.dirty_digest > 0
		and input.provenance == true and input.native == true
		and input.outer_only == true and input.bounds == true
		and input.coverage_permille > 0 and input.coverage_permille <= 150
		and input.preplan_apis == true
	if exact then
		out.local_pass, out.buildable, out.snapshots = 2, 1, 2
	else
		out.canonical = 1
	end
	if input.planner ~= true then
		out.cleanup = exact
		out.blocked = true
		return out
	end
	out.published = true
	if exact then
		local closing = input.owner == true and input.object_family == 6
			and input.associations_exact == true and input.objects_contained == true
			and input.height_mismatches == 0
			and input.closing_apis == true and input.cleanup_ok == true
		if closing then
			out.local_pass = 4
			out.cleanup = true
			out.optimized = true
		else
			-- A full canonical closing rebuild is authoritative after a proven local preplan.
			out.canonical = out.canonical + 1
			out.cleanup = input.owner == true
		end
	else
		out.canonical = out.canonical + 1
	end
	return out
end

local base = {
	enabled = true, surface = true, pads = 2, dirty_regions = 2, dirty_digest = 918273,
	provenance = true, native = true, outer_only = true, bounds = true,
	coverage_permille = 37, preplan_apis = true, planner = true, owner = true,
	object_family = 6, associations_exact = true, objects_contained = true,
	height_mismatches = 0,
	closing_apis = true, cleanup_ok = true,
}

local function copy(changes)
	local result = {}
	for key, value in pairs(base) do result[key] = value end
	for key, value in pairs(changes or {}) do result[key] = value end
	return result
end

local function require_case(name, input, expected)
	local actual = decide(input)
	for key, value in pairs(expected) do
		assert(actual[key] == value, name .. ": " .. key .. " expected "
			.. tostring(value) .. " got " .. tostring(actual[key]))
	end
end

require_case("exact local transaction", copy(), {
	optimized = true, canonical = 0, local_pass = 4, buildable = 1,
	snapshots = 2, cleanup = true, published = true, blocked = false,
})
for _, mutation in ipairs({
	{ enabled = false }, { surface = false }, { pads = 1 }, { dirty_regions = 3 },
	{ dirty_digest = 0 }, { provenance = false }, { native = false },
	{ outer_only = false }, { bounds = false }, { coverage_permille = 0 },
	{ coverage_permille = 151 }, { preplan_apis = false },
}) do
	require_case("preplan provenance fallback", copy(mutation), {
		optimized = false, canonical = 2, local_pass = 0, published = true,
	})
end
for _, mutation in ipairs({
	{ owner = false }, { object_family = 5 }, { object_family = 7 },
	{ associations_exact = false }, { objects_contained = false }, { height_mismatches = 1 },
	{ closing_apis = false }, { cleanup_ok = false },
}) do
	require_case("closing adversary fallback", copy(mutation), {
		optimized = false, canonical = 1, local_pass = 2, published = true,
	})
end
require_case("planner failure cleans private preimages", copy({ planner = false }), {
	optimized = false, canonical = 0, local_pass = 2, cleanup = true,
	published = false, blocked = true,
})
require_case("canonical planner failure remains blocked", copy({
	provenance = false, planner = false,
}), {
	optimized = false, canonical = 1, local_pass = 0, cleanup = false,
	published = false, blocked = true,
})

print("v998 surface single-flush transaction oracle: ok")

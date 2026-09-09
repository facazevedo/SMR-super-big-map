-- Run from the repository root: lua _ralph/tools/parity/resource_protection_blend_test.lua
local file = assert(io.open("Code/sbm_terrain_copy.lua", "rb"))
local source = file:read("*a"); file:close()
-- Git on Windows may check out CRLF; source extraction must ignore line endings.
source = source:gsub("\r\n", "\n")
local helper = assert(source:match("(local function ProtectedTerrainBlendWeight.-)\nlocal function PrepareOuterResourceTerrain"))
local weight = assert(load(helper .. "\nreturn ProtectedTerrainBlendWeight"))()

-- Execute the current production grade limiter rather than pinning the retired scalar-raster
-- variable names. The extracted block is the one used when each production patch is built.
local grade_block = assert(source:match(
    "(local grade_x = relief_x /.-\n\t\tend)\n\t\tlocal relief_length"),
    "production surface-grade block not found")
local grade = assert(load("return function(relief_x, relief_y, relief_probe, kind)\n"
    .. grade_block .. "\nreturn grade_x, grade_y\nend"))()

-- Execute the fixed-point native blend statements with scalar grid doubles. This proves the
-- current shipped arithmetic: surface cores follow their fitted plane, building cores are level,
-- and transition detail returns according to 1-w^3.
local native_blend_block = assert(source:match(
    "(local weight_cube = own%(mask:clone%(%)%).-)\n\n\t\t\t%-%- No inner%-rectangle restore here"),
    "production native blend block not found")
local plane_block = assert(source:match(
    "(local function scaled_plane%(x, y%).-)\n\t\t\tplane_seed:set"),
    "production native patch plane builder not found")
local function scalar_grid(value)
    local grid = { value = value }
    function grid:clone() return scalar_grid(self.value) end
    return grid
end
local function native_mul_div_add(grid, factor, divisor, add)
    local multiplier = type(factor) == "table" and factor.value or factor
    grid.value = grid.value * multiplier / divisor + add
end
local function native_add(grid, other) grid.value = grid.value + other.value end
local native_blend = assert(load("return function(old, plane_value, mask_value, kind, target)\n"
    .. "local native_weight_scale, native_height_scale = 4096, 256\n"
    .. "local source = scalar_grid(old * native_height_scale)\n"
    .. "local height_grid = source:clone()\n"
    .. "local patch = { kind = kind, target = target, cx = 0, cy = 0, "
    .. "grade_x = plane_value - target, grade_y = 0 }\n"
    .. plane_block .. "\nlocal plane = scalar_grid(scaled_plane(1, 0))\n"
    .. "local mask = scalar_grid(mask_value)\n"
    .. "local function own(value) return value end\n"
    .. native_blend_block
    .. "\nreturn result.value / native_height_scale\nend", "production-native-blend", "t", {
        scalar_grid = scalar_grid,
        native_mul_div_add = native_mul_div_add,
        native_add = native_add,
        type = type,
        math = math,
    }))()
local passed = 0
local function check(name, fn) fn(); passed = passed + 1; print("PASS " .. name) end
check("protected terrain is exactly unchanged", function()
    for distance = 0, 30 do assert(weight(distance, 30, 120) == 0) end
end)
check("distant deformation is exactly unchanged", function()
    for distance = 150, 300 do assert(weight(distance, 30, 120) == 1) end
end)
check("transition is bounded and monotonic at multiple scales", function()
    for _, width in ipairs({ 0.1, 1, 17.31, 120, 900 }) do
        local previous = 0
        for sample = 0, 1000 do
            local value = weight(30 + width * sample / 1000, 30, width)
            assert(value >= previous - 1e-12 and value >= -1e-12 and value <= 1 + 1e-12)
            previous = value
        end
    end
end)
check("both joins have zero slope and curvature", function()
    local h = 0.00001
    for _, join in ipairs({ 30, 31 }) do
        local a, b, c = weight(join - h, 30, 1), weight(join, 30, 1), weight(join + h, 30, 1)
        assert(math.abs((c - a) / (2 * h)) < 1e-7)
        assert(math.abs((c - 2 * b + a) / (h * h)) < 0.001)
    end
end)
check("gap-limited protection cannot attenuate a required core", function()
    for _, separation in ipairs({ 31, 40, 70, 200 }) do
        local guard, core = 10, 20
        local width = math.min(120, separation - guard - core)
        for x = separation - core, separation + core, 0.25 do
            assert(weight(x, guard, width) == 1)
        end
    end
end)
check("overlapping guards remain bounded and preserve either footprint", function()
    for x = -100, 200 do
        local combined = weight(math.abs(x), 10, 40) * weight(math.abs(x - 50), 10, 40)
        assert(combined >= 0 and combined <= 1)
        if math.abs(x) <= 10 or math.abs(x - 50) <= 10 then assert(combined == 0) end
    end
end)
check("zero-width edge case is finite and exact", function()
    assert(weight(10, 10, 0) == 0 and weight(11, 10, 0) == 1)
end)
check("completed cores are protected without a hard restoration pass", function()
    local raster = assert(source:match("(local function apply_native_raster.-)\n\tlocal pause"))
    assert(raster:find("completed_patch_cores[#completed_patch_cores + 1]", 1, true))
    assert(not raster:find("core_only", 1, true))
    assert(not raster:find("apply_native_patch(patch, true)", 1, true))
    assert(source:find("for _, protected in ipairs(completed_patch_cores) do consider(protected) end", 1, true))
    assert(source:find("if #targets > 1 then patch.grade_x, patch.grade_y = 0, 0 end", 1, true))
end)
check("sequential blends preserve earlier cores and satisfy later cores", function()
    -- A 1-D cross-section through two touching (harmonized) or separated gameplay disks.
    local core, feather = 10, 50
    local function envelope(distance) return 1 - weight(distance, core, feather) end
    for _, separation in ipairs({ 12, 20, 25, 40, 100 }) do
        local target_a, target_b = 80, separation <= 20 and 80 or 150
        local gap = math.max(0, separation - 2 * core)
        local function final(x)
            local old = 100 + x * 0.1
            local a = envelope(math.abs(x))
            local first = old * (1 - a^3) + target_a * a^3
            local b = envelope(math.abs(x - separation)) * weight(math.abs(x), core, math.min(feather, gap))
            return first * (1 - b^3) + target_b * b^3
        end
        for x = -core, core, 0.25 do assert(math.abs(final(x) - target_a) < 1e-8) end
        for x = separation - core, separation + core, 0.25 do
            assert(math.abs(final(x) - target_b) < 1e-8)
        end
        -- Including the zero-gap, common-plane case: no jump at the protected core boundary.
        assert(math.abs(final(core + 0.0001) - final(core)) < 1e-6)
    end
end)
check("surface repair grade is capped without flattening", function()
    local gx, gy = grade(80, 60, 10, "surface")
    assert(math.abs(gx - 2.4) < 1e-12 and math.abs(gy - 1.8) < 1e-12)
    assert(math.abs(math.sqrt(gx * gx + gy * gy) - 3) < 1e-12)
end)
check("surface repair keeps an already safe local grade", function()
    local gx, gy = grade(20, -10, 10, "surface")
    assert(gx == 1 and gy == -0.5)
end)
check("surface core follows the fitted production plane", function()
    assert(native_blend(120, 82, 4096, "surface", 80) == 82)
end)
check("building core remains an exact level target", function()
    assert(native_blend(120, 82, 4096, "extractor", 80) == 80)
end)
check("native transition restores detail by one minus weight cubed", function()
    local actual = native_blend(120, 80, 2048, "surface", 80)
    assert(math.abs(actual - 115) < 1e-12)
end)
check("building feathers cannot extrapolate beyond original and target heights", function()
    -- Exercise the shipped plane builder AND blend at partial weights. The old
    -- expression assigns the fitted plane a negative coefficient w^3-w: even
    -- equal old/target heights can become a deep moat around a level footprint.
    for _, kind in ipairs({ "extractor", "rocket" }) do
        for _, old in ipairs({ 0, 80, 8622, 32000, 65535 }) do
            for _, target in ipairs({ 0, 8622, 65535 }) do
                for _, fitted in ipairs({ -65535, 0, 10000, 32000, 131070 }) do
                    for mask = 0, 4096, 128 do
                        local actual = native_blend(old, fitted, mask, kind, target)
                        assert(actual >= math.min(old, target) - 1e-8
                            and actual <= math.max(old, target) + 1e-8,
                            string.format("%s feather overshoot old=%s target=%s plane=%s mask=%s result=%s",
                                kind, old, target, fitted, mask, actual))
                    end
                end
            end
        end
    end
end)
check("level building neighbourhood stays level through every feather weight", function()
    for _, kind in ipairs({ "extractor", "rocket" }) do
        for mask = 0, 4096, 64 do
            assert(math.abs(native_blend(8622, 32000, mask, kind, 8622) - 8622) < 1e-8)
        end
    end
end)
print(string.format("%d resource protection blend checks passed", passed))

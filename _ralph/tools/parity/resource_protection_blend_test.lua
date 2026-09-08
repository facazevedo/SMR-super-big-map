-- Run from the repository root: lua _ralph/tools/parity/resource_protection_blend_test.lua
local file = assert(io.open("Code/sbm_terrain_copy.lua", "rb"))
local source = file:read("*a"); file:close()
local helper = assert(source:match("(local function ProtectedTerrainBlendWeight.-)\nlocal function PrepareOuterResourceTerrain"))
local weight = assert(load(helper .. "\nreturn ProtectedTerrainBlendWeight"))()
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
print(string.format("%d resource protection blend checks passed", passed))

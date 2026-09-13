-- Cross-check the numerical study's scalar reference against actual production Lua.
-- This validates the reference only, not the proposed f32/native implementation.
local directory = assert(arg[1], 'study artifact directory required')
local function read(path, mode)
    local f = assert(io.open(path, mode or 'r'))
    local contents = f:read('*a'); f:close(); return contents
end
local rows = assert(loadfile(directory .. '/geometry.lua'))()
local source = read('Code/sbm_terrain_copy.lua'):gsub('\r\n', '\n')
local first = assert(source:find('local function apply_native_patch', 1, true))
first = assert(source:find('local dx, dy = x - patch.cx, y - patch.cy', first, true))
local last = assert(source:find('coarse:set(coarse_x, coarse_y,', first, true))
local body = source:sub(first, last - 1) .. ' return math.floor(weight * native_weight_scale + 0.5)'
local protection = assert(source:match('(local function ProtectedTerrainBlendWeight.-\nend)'))
local m = {}; for key, value in pairs(math) do m[key] = value end
m.atan2 = nil -- the captured engine explicitly lacks this function
local env = setmetatable({math=m, native_weight_scale=4096, maximum_width_scale=1.35}, {__index=_G})
env.ProtectedTerrainBlendWeight = assert(load(protection .. '\nreturn ProtectedTerrainBlendWeight', 'protection', 't', env))()
local checks = 0
for index, row in ipairs(rows) do
    assert(not row.atan2_present)
    env.patch, env.protection_blends = row.patch, row.guards
    env.radius, env.base_transition = row.radius, row.base_transition
    env.transition_irregularity = row.irregularity
    -- Recompute using this Lua math library; any U12 difference is a hard failure.
    local scalar = assert(load('local cached_zero_sine,cached_zero_harmonic\n' .. body,
        'actual production mask cell', 't', env))
    local bytes = read(('%s/patch_%03d_scalar.u16'):format(directory, index), 'rb')
    assert(#bytes == row.width * row.height * 2)
    local at = 1
    for cy = 0, row.height - 1 do for cx = 0, row.width - 1 do
        env.x, env.y = row.x0 + cx * row.sample_step, row.y0 + cy * row.sample_step
        local expected; expected, at = string.unpack('<I2', bytes, at)
        assert(scalar() == expected, ('study reference differs at patch%d cell%d,%d'):format(index,cx,cy))
        checks = checks + 1
    end end
end
print(('PASS actual production scalar oracle: %d U12 mask samples, %d real protected/unprotected patches'):format(checks,#rows))

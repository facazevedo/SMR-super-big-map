-- Research only: capture every actual coarse-mask input once per patch.
-- No per-cell instrumentation, module reload, RNG draw or changed terrain operation.
local result = { status = 'setup', calls = {} }
rawset(_G, 'SBM_OUTER_GEOMETRY_DIAGNOSTIC', result)
local env, sbm
for _, mod in ipairs(ModsLoaded or {}) do
    local value = mod.env and rawget(mod.env, 'SuperBigMap')
    if value and value.Config then env, sbm = mod.env, value; break end
end
local function fail(why) result.status = 'fail'; result.error = why; error(why) end
if not sbm then fail('outer geometry mod missing'); return end
local original = sbm.TerrainCopy.PrepareOuterResourceTerrain
local cells, names = {}, {}
for i = 1, 200 do
    local name = debug.getupvalue(original, i)
    if not name then break end
    cells[name] = i
    if name ~= '_ENV' then names[#names + 1] = name end
end
local err, source = AsyncFileToString('D:/PROJS/SMR/super-big-map/Code/sbm_terrain_copy.lua')
if err or type(source) ~= 'string' then fail('outer geometry source missing'); return end
source = source:gsub('\r\n', '\n')
local first = source:find('local function PrepareOuterResourceTerrain(', 1, true)
local last = first and source:find('local function RebuildOuterResourceTerrainRegions(', first, true)
if not first or not last then fail('outer geometry function boundaries'); return end
source = source:sub(first, last - 1)
local anchor = '\t\t\t\tlocal cached_zero_sine, cached_zero_harmonic\n'
local a, b = source:find(anchor, 1, true)
if not a or source:find(anchor, b + 1, true) then fail('outer geometry injection anchor'); return end
local injection = [[				local probe_geometry_row = probe_geometry(patch, protection_blends, base_transition,
					transition_irregularity, radius, x0, y0, sample_step,
					coarse_width, coarse_height, math.atan2 ~= nil)
]]
source = source:sub(1, a - 1) .. injection .. source:sub(a)
local finish_anchor = '\t\t\t\tsamples = coarse_width * coarse_height'
local c, d = source:find(finish_anchor, 1, true)
if not c or source:find(finish_anchor, d + 1, true) then fail('outer geometry finish anchor'); return end
source = source:sub(1, c - 1)
    .. '\t\t\t\tprobe_geometry_row.cached_zero_harmonic = cached_zero_harmonic\n'
    .. source:sub(c)
local active
local function geometry(patch, guards, transition, irregularity, radius, x0, y0, step, w, h, atan2)
    if not active then fail('outer geometry outside call'); return end
    local row = { patch = {}, guards = {}, base_transition = transition,
        irregularity = irregularity, radius = radius, x0 = x0, y0 = y0,
        sample_step = step, width = w, height = h, atan2_present = atan2 }
    for _, name in ipairs({'cx', 'cy', 'core_cells', 'phase', 'relief_x', 'relief_y', 'kind'}) do
        row.patch[name] = patch[name]
    end
    for i, guard in ipairs(guards) do
        row.guards[i] = { cx = guard.cx, cy = guard.cy,
            radius = guard.radius, transition = guard.transition }
    end
    active.patches[#active.patches + 1] = row
    return row
end
local prefix = 'local probe_geometry=...\n'
if #names > 0 then prefix = prefix .. 'local ' .. table.concat(names, ',') .. '\n' end
local chunk, why = load(prefix .. source .. '\nreturn PrepareOuterResourceTerrain', '@outer-geometry-capture', 't', env)
if not chunk then fail(tostring(why)); return end
local candidate = chunk(geometry)
for i = 1, 200 do
    local name = debug.getupvalue(candidate, i)
    if not name then break end
    if cells[name] then debug.upvaluejoin(candidate, i, original, cells[name])
    elseif name ~= 'probe_geometry' then fail('outer geometry unjoined cell ' .. name); return end
end
local unpack_values = table.unpack or unpack
local function pack(...) return { n = select('#', ...), ... } end
sbm.TerrainCopy.PrepareOuterResourceTerrain = function(map, ...)
    if active then fail('recursive outer geometry call'); return original(map, ...) end
    active = { patches = {}, environment = map.mapdata.Environment }
    local row = active
    local values = pack(candidate(map, ...))
    row.report = values[2]
    active = nil
    result.calls[#result.calls + 1] = row
    local count = 0
    for _, patch in ipairs(row.patches) do count = count + patch.width * patch.height end
    if type(row.report) ~= 'table' or row.report.error ~= '' or #row.patches == 0
        or count ~= row.report.native_mask_samples then
        result.status = 'fail'; result.error = 'outer geometry census or terrain failure'
    elseif not result.error then result.status = 'pass' end
    return unpack_values(values, 1, values.n)
end
result.status = 'ready'
return 'OUTER_GEOMETRY_CAPTURE_READY'

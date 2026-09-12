-- Diagnostics in this fresh process only; source is normalized before anchored edits.
local env, sbm
for _, mod in ipairs(ModsLoaded or {}) do
    local value = mod.env and rawget(mod.env, "SuperBigMap")
    if value and value.Config then env, sbm = mod.env, value; break end
end
assert(sbm, "PROFILE_ERROR: mod missing")
local path = "C:/Users/fazevedo/AppData/Roaming/Surviving Mars Relaunched/Mods/super-big-map/Code/sbm_terrain_copy.lua"
local err, source = AsyncFileToString(path)
assert(not err and type(source) == "string", "PROFILE_ERROR: source unavailable")
source = source:gsub("\r\n", "\n")
local function before(anchor, prefix)
    local first, last = source:find(anchor, 1, true)
    assert(first and not source:find(anchor, last + 1, true), "PROFILE_ERROR: " .. anchor)
    source = source:sub(1, first - 1) .. prefix .. source:sub(first)
end
before("\tlocal cluster_minimum = math.max(1,", '\tlocal split_planning = LoadingBegin("split rocket planning", map)\n')
before("\t-- If a required new core actually intersects an already-valid resource guard,",
    '\tLoadingEnd(split_planning)\n\tlocal split_components = LoadingBegin("split core harmonization", map)\n')
before("\tlocal ok_apply, apply_error\n", '\tLoadingEnd(split_components)\n\tlocal split_raster = LoadingBegin("split outer native raster", map)\n')
before('\tlocal set_ok, set_error = false, "no terrain changes"',
    '\tLoadingEnd(split_raster)\n\tlocal split_install = LoadingBegin("split outer installation", map)\n')
before("\tmap.SuperBigMapOuterResourceTerrainSites = resource_sites", '\tLoadingEnd(split_install)\n')
before('\t\t\t\tlocal detected, report, tracks, stats = RepairInternalHeightStep(src_sub, true)',
    '\t\t\t\tlocal split_source = LoadingBegin("split source crease", map)\n')
before('\t\t\t\tmap.SuperBigMapCreaseSamplingStats = { source = stats }', '\t\t\t\tLoadingEnd(split_source)\n')
before('\t\t\t\tlocal repaired, report, _, stats = RepairInternalHeightStep(stretched, false)',
    '\t\t\t\tlocal split_destination = LoadingBegin("split destination crease", map)\n')
before('\t\t\t\tmap.SuperBigMapCreaseSamplingStats = map.SuperBigMapCreaseSamplingStats or {}',
    '\t\t\t\tLoadingEnd(split_destination)\n')
before('\t\t\t\tlocal _, apron_report = CreateNaturalMountainBaseBuildableAprons(map, stretched)',
    '\t\t\t\tlocal split_apron = LoadingBegin("split natural apron", map)\n')
before('\t\t\t\tif apron_report and apron_report.error and apron_report.error ~= "" then',
    '\t\t\t\tLoadingEnd(split_apron)\n')
local fn, compile_error = load(source, "@under80-profile/sbm_terrain_copy.lua", "t", env)
assert(fn, compile_error)
local original = sbm.TerrainCopy
-- Map generation captured StretchSourceToFull as a local when the module loaded.
-- Instrument its existing helper upvalues as well as the dynamically read API.
local wanted = {
    RepairInternalHeightStep = "split live crease",
    RepairQualifiedSourceHeightSteps = "split live source correction",
    CreateNaturalMountainBaseBuildableAprons = "split live natural apron",
}
assert(debug and debug.getupvalue and debug.setupvalue, "PROFILE_ERROR: debug upvalue API unavailable")
local function pack(...) return {n=select('#', ...), ...} end
local unpack_results = table.unpack or unpack
local installed = 0
for i=1,200 do
    local name, value = debug.getupvalue(original.StretchSourceToFull, i)
    if not name then break end
    if wanted[name] then
        local label = wanted[name]
        local wrapper = function(...)
            local token = sbm.Diagnostics.LoadingBegin(label)
            local values = pack(value(...))
            sbm.Diagnostics.LoadingEnd(token)
            return unpack_results(values, 1, values.n)
        end
        assert(debug.setupvalue(original.StretchSourceToFull, i, wrapper) == name)
        installed = installed + 1
    end
end
assert(installed == 3, "PROFILE_ERROR: live terrain helpers unavailable")
fn()
for key, value in pairs(sbm.TerrainCopy) do original[key] = value end
sbm.TerrainCopy = original
sbm.Config.DEBUG_LOGGING_ENABLED = true
sbm.Config.DEBUG_LOADING_TIMINGS = true
return "PROFILE_OK"

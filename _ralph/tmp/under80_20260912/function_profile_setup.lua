-- Fresh diagnostic process only. Native function profiler; never open an editor.
local sbm
for _, mod in ipairs(ModsLoaded or {}) do
    local value = mod.env and rawget(mod.env, "SuperBigMap")
    if value and value.Config then sbm = value; break end
end
assert(sbm and debug and debug.getupvalue and debug.setupvalue, "PROFILE_ERROR: mod/upvalues unavailable")
assert(type(FunctionProfilerStart) == 'function' and type(FunctionProfilerStop) == 'function',
    'PROFILE_ERROR: native function profiler unavailable')
local function pack(...) return { n=select('#', ...), ... } end
local unpack_values = table.unpack or unpack
local function profiled(fn, name)
    local calls = 0
    return function(...)
        calls = calls + 1
        config.FunctionProfilter_CallStackFile = '__PROFILE_OUTPUT__/function_' .. name .. '_' .. calls .. '.json'
        FunctionProfilerStart()
        local values = pack(fn(...))
        FunctionProfilerStop('__PROFILE_OUTPUT__/function_' .. name .. '_' .. calls .. '.txt', true)
        return unpack_values(values, 1, values.n)
    end
end
local wanted = {
    RepairInternalHeightStep = 'crease',
    CreateNaturalMountainBaseBuildableAprons = 'apron',
}
local installed = 0
for i=1,200 do
    local name, value = debug.getupvalue(sbm.TerrainCopy.StretchSourceToFull, i)
    if not name then break end
    if wanted[name] then
        assert(debug.setupvalue(sbm.TerrainCopy.StretchSourceToFull, i,
            profiled(value, wanted[name])) == name)
        installed = installed + 1
    end
end
assert(installed == 2, 'PROFILE_ERROR: captured terrain helpers unavailable')
sbm.TerrainCopy.PrepareOuterResourceTerrain = profiled(sbm.TerrainCopy.PrepareOuterResourceTerrain, 'outer')
return 'PROFILE_OK'

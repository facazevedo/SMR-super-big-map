-- Fresh-process coarse wall-clock breakdown using existing loading spans only.
-- No module recompilation, function-call profiler, cache, algorithm or RNG change.
local result = { status = 'setup', calls = {} }
rawset(_G, 'SBM_WALL_STAGE_DIAGNOSTIC', result)
local sbm
for _, mod in ipairs(ModsLoaded or {}) do
    local value = mod.env and rawget(mod.env, 'SuperBigMap')
    if value and value.GenerationGrids then sbm = value; break end
end
if not sbm then result.status='fail'; result.error='mod unavailable'; return end
local previous_debug = sbm.Config.DEBUG_LOGGING_ENABLED
local previous_timing = sbm.Config.DEBUG_LOADING_TIMINGS
local original = sbm.GenerationGrids.RebuildFinal
if type(original) ~= 'function' then result.status='fail'; result.error='final boundary unavailable'; return end
local function pack(...) return { n = select('#', ...), ... } end
local unpack_values = table.unpack or unpack
local wrapper
wrapper = function(map, stage, ...)
    local started = GetPreciseTicks()
    local components, saved, hooks = {}, {}, {}
    for _, name in ipairs({'InvalidateHeight', 'InvalidateType', 'RebuildPassability'}) do
        local fn = terrain[name]
        if type(fn) ~= 'function' then result.status='fail'; result.error='native boundary missing'; return end
        saved[name] = fn
        hooks[name] = function(...)
            local before = GetPreciseTicks()
            local values = pack(fn(...))
            components[#components + 1] = { name = name, duration_ms = GetPreciseTicks() - before }
            return unpack_values(values, 1, values.n)
        end
    end
    for name, fn in pairs(hooks) do terrain[name] = fn end
    local returned = pack(pcall(original, map, stage, ...))
    for name, fn in pairs(saved) do terrain[name] = fn end
    if not returned[1] then result.status='fail'; result.error=tostring(returned[2]); error(returned[2]); return end
    result.calls[#result.calls + 1] = { stage = stage,
        environment = map.mapdata and map.mapdata.Environment,
        components = components,
        duration_ms = GetPreciseTicks() - started }
    if map.mapdata.Environment == 'Surface' and stage == 'post-pipeline scheduled revalidation' then
        sbm.Config.DEBUG_LOGGING_ENABLED = previous_debug
        sbm.Config.DEBUG_LOADING_TIMINGS = previous_timing
        if sbm.GenerationGrids.RebuildFinal ~= wrapper then
            result.status='fail'; result.error='final hook rebound'
        else
            sbm.GenerationGrids.RebuildFinal = original
            result.restored = true; result.status = 'pass'
        end
    end
    return unpack_values(returned, 2, returned.n)
end
sbm.GenerationGrids.RebuildFinal = wrapper
sbm.Config.DEBUG_LOGGING_ENABLED = true
sbm.Config.DEBUG_LOADING_TIMINGS = true
result.status = 'ready'
return 'WALL_STAGE_PROFILE_READY'

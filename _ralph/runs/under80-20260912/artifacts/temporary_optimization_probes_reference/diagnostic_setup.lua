-- Fresh-process verification of production debug probes, not a performance run.
local result = { status = 'setup', calls = {} }
rawset(_G, 'SBM_OPTIMIZATION_TIMING_DIAGNOSTIC', result)
local sbm
for _, mod in ipairs(ModsLoaded or {}) do
    local value = mod.env and rawget(mod.env, 'SuperBigMap')
    if value and value.Config then sbm = value; break end
end
if not sbm or not sbm.Diagnostics or not sbm.Diagnostics.OptimizationBegin
    or sbm.Config.TRACE_OPTIMIZATION_TIMINGS ~= true then
    result.status = 'fail'; result.error = 'temporary production probes unavailable'
    error(result.error); return
end
local begin = sbm.Diagnostics.OptimizationBegin
local seen = {}
sbm.Diagnostics.OptimizationBegin = function(name)
    local token = begin(name)
    if not token then result.status = 'fail'; result.error = 'probe disabled'; return token end
    local finish = token.Finish
    token.Finish = function(self, data, ok)
        local printed, why = finish(self, data, ok)
        result.calls[#result.calls + 1] = {
            name = name, checkpoints = #self.rows, duration_ms = self.previous - self.started,
            printed = printed == true, ok = ok ~= false,
        }
        if not printed or ok == false then
            result.status = 'fail'; result.error = tostring(why or name .. ' failed')
        end
        seen[name] = true
        if not result.error and seen['crease source'] and seen['crease destination']
            and seen['outer resource terrain'] and seen['decor top-up']
            and seen['passage dependant index'] then result.status = 'pass' end
        return printed, why
    end
    return token
end
result.status = 'ready'
return 'OPTIMIZATION_TIMING_PROBES_READY'

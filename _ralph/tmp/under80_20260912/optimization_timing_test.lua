-- Temporary probes must remain observational, bounded and silent when disabled.
local clock_reads, ticks, records = 0, 100, {}
local print_failure = false
local config = { TRACE_OPTIMIZATION_TIMINGS = false }
local env = setmetatable({ SuperBigMap = { Config = config } }, { __index = _G })
env._G = env
env.GetPreciseTicks = function() clock_reads = clock_reads + 1; return ticks end
env.print = function(line)
    if print_failure then error('test logging failure') end
    records[#records + 1] = line
    ticks = ticks + 3 -- deliberately expensive output, excluded from buffered durations
end
assert(loadfile('Code/sbm_diagnostics.lua', 't', env))()
local diagnostics = env.SuperBigMap.Diagnostics
assert(diagnostics.OptimizationBegin('off') == false)
assert(clock_reads == 0 and #records == 0, 'disabled probes touched clock/output')
config.TRACE_OPTIMIZATION_TIMINGS = true
local probe = diagnostics.OptimizationBegin('test')
ticks = 110; probe:Mark('discovery')
ticks = 130; probe:Mark('writes')
assert(#records == 0, 'checkpoints printed inside measured work')
local report = { count = 7 }
ticks = 135; assert(probe:Finish(report, true))
assert(#records == 4)
assert(records[1]:find('duration_ms=10', 1, true))
assert(records[2]:find('duration_ms=20', 1, true))
assert(records[3]:find('duration_ms=5', 1, true))
assert(records[4]:find('duration_ms=35', 1, true))
assert(records[4]:find('instrumented=true', 1, true))
assert(records[4]:find('ok=true', 1, true))
assert(report.count == 7 and report.duration_ms == nil and report.ok == nil,
    'probe modified caller report')
local reads = clock_reads
probe:Mark('duplicate'); assert(probe:Finish() == false)
assert(#records == 4 and clock_reads == reads, 'finished token emitted/read again')
local failed = diagnostics.OptimizationBegin('failed terrain')
assert(failed:Finish({ error = 'original terrain failure' }, false))
assert(records[#records]:find('ok=false', 1, true))
print_failure = true
local broken = diagnostics.OptimizationBegin('broken print')
assert(broken:Finish() == false, 'logging failure escaped')
config.TRACE_OPTIMIZATION_TIMINGS = false
reads = clock_reads
assert(diagnostics.OptimizationBegin('off again') == false and clock_reads == reads)
print('PASS temporary timing probes: off, buffered intervals, immutable reports, idempotence, error isolation')

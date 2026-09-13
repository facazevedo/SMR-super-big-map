# Temporary optimization investigation

Current accepted result (2026-09-13): **v994**, reference START-to-T1 arithmetic
average **84.666s** from 84.212 /85.294 /84.492s. The revised below85s-average
goal is met; all five correctness scenarios and85 offline tests pass. Measured
checkpoint `1182750`, production implementation `065ab3f`, deployed38/38.
Full acceptance record: [_ralph/runs/under80-20260912/v994_acceptance.md](_ralph/runs/under80-20260912/v994_acceptance.md).
No diagnostic profiler/oracle is active in the deployed payload.

## Historical v983 diagnostics (not current configuration)

The text below describes the earlier investigation, not the accepted v994 payload.
Those probes are archived in commit `d5a1e3e` and removed from the active
payload for the exact unchanged-v983 five-site confirmation. The instructions below
describe that diagnostic commit, not the current cold-benchmark payload. Its focused
test is also retained at `_ralph/tmp/under80_20260912/optimization_timing_test.lua`;
run it against the instrumented commit, not the restored release diagnostics module.

The current working tree adds diagnostic probes to accepted v983. It is not a
new optimized release, and instrumented timings are not acceptance benchmarks.
Restart the game after deploying the changes; do not hot-reload an existing map.

`Code/sbm_config.lua`: set `config.TraceOptimizationTimings = false` to disable
all new probes. It is temporarily **true** for this investigation, independently
of the broad debug flags (which remain off).

Search the newest game log under
`C:\Users\fazevedo\AppData\Roaming\Surviving Mars Relaunched\logs`
for `[Super Big Map][OptimizationTiming]`. These messages do not go into
`FunctionProfiler.txt`.

The records separate:

- Source/destination crease collection on each axis, track qualification, and
  live refinement/translation/feathering. Totals include existing candidate counts.
- Outer-resource patch planning, transactional raster work, and installation.
- Decor preparation, authored sites, random search, finite candidate search,
  and final bookkeeping. Totals include the existing attempt/rejection counts.
- Passage dependant indexing, with existing object/match counts and anchor count.

Checkpoints are buffered until the operation ends, so printing does not occur
inside the measured loops. `finish` is the remainder since the previous checkpoint;
`TOTAL` includes all checkpoints and must not be added to them. Counts are read
from existing reports, with no extra terrain scans or random draws. Probes still
add overhead; turn them off and redeploy before any cold performance comparison.

The accepted reference median was 90.244 s in the latest unchanged-code run.
The <85 s target is not yet demonstrated. Historical five-site baseline times
have not been refreshed, so apparent small improvements/regressions require
carefully matched cold measurements.

Focused test: `lua _ralph/tools/parity/optimization_timing_test.lua`.

## Verification and first measurements

All 81 offline checks passed. One fresh 14N134W game run emitted all five probe
types and matched the accepted baseline's runtime comparison, full snapshots and
individual rock-grounding records, with no differences. The owned test game quit
normally. Deployment audit: 38/38 files match. No cold performance claim is made.

| Measured work | Diagnostic duration |
| --- | ---: |
| Destination crease collection, both axes | 2.375 s |
| Destination crease refinement and writes | 1.471 s |
| Outer-resource transaction/raster/terminal repair | 4.095 s |
| Surface decor top-up, total | 0.414 s |

These are portions of existing work, not available savings. Full records are in
`_ralph/runs/under80-20260912/artifacts/temporary_optimization_probes_reference`.
The requested Astra extra-high alternatives review is saved in
`_ralph/runs/under80-20260912/astra_optimization_alternatives.md`.

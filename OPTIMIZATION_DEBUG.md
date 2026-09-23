# Temporary optimization investigation

Current build: **guard 462 / metadata 1093**, code checkpoint `494f7af`.
All six A/B/control and save/load cases pass in 30 fresh native headless sessions.
Worst of 18 expanded generations: **74.955s START-to-T1**, including all rock
seating, and **57.364s underground**. This leaves only 45ms surface headroom.
The 14S36W warning's missing physical-support classification is fixed generically;
exact terrain-cut nomination removes unnecessary graph construction nearby.
Same-candidate full-state parity and positive support for every eligible rock pass.
All 43 local mod payload files match; Windows 3840x2160 remained unchanged.
Slowest-first ordering is a standing repository rule. Difficult seeds are retained;
the unpinned 14S36W diagnostic and failed 461 timings do not count as acceptance.
80 compatibility fixtures, 18 judge tests and Code syntax pass. No new push.
See [ALL_RULES_VERIFICATION.md](ALL_RULES_VERIFICATION.md) and
`_ralph/runs/rules-parity/fix-14s36w-20260923/complete_audit462.json`.
Production contains no process-local test profiler or verifier override.

## Historical404 investigation (superseded)

Current workspace/deployed: guard404 / metadata1035, **not accepted**. Finalized403 45S120W:76.075s surface/46.481s underground,16 verified corrections beforeT1, zero rejections, clean flushed log. Guard402's exact small-region terrain bound and proven native/current-intersection preservation resolve the earlier group failures;403 removes repeated negative proofs for verified native compositions. Guard404 first reuses conservative terrain bounds that already prove separation, avoiding unnecessary exhaustive queries. All66 host fixtures and15 judge tests pass. The399 same-seed resource/grid mismatch, broader correctness/repeatability audit and clean performance acceptance remain open. See [ALL_RULES_VERIFICATION.md](ALL_RULES_VERIFICATION.md).

The user now explicitly permits testing at the current Windows resolution. The runner accepts an explicit `--expected-display` argument, preserves that resolution throughout the run and never calls a display-setting API. One1024x768 startup crashed before generation with Windows exception0xc0000374; it has no timing result. Temporary diagnostic logs are retained and read after owned-process closure; final performance acceptance must run without added diagnostics.

Historical scoped guard399: three ordinary24S74W runs74.682/73.444/73.640s; same-run gameplay, buttons and a separate deferred-mask save/load check passed. Those historical successes do not close the later failures.

Historical, superseded acceptance (2026-09-22): generator guard **374**, hardest reference surface
START-to-T1 **74.056 / 74.651 s** (mean **74.354 s**), including completed rock seating. Full underground,
resource/passage and temporary-button checks pass with no Lua errors; Windows
stays at 3840 × 2160 during hidden/windowed testing.
See [SURFACE_LOADING_ACCEPTANCE.md](SURFACE_LOADING_ACCEPTANCE.md) for the measurement
contract, clean-run evidence, bounded rounding allowance and regression checks.

## Historical v994 acceptance

Accepted result (2026-09-13): **v994**, reference START-to-T1 arithmetic
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

# v987: native outer masks with exact scalar rounding correction

Cold candidate56fbf44, based on acceptedf4d1da6/v983. Only TerrainCopy,
generator299 (sector76 unchanged), runtime987 and release text change in production.
Rejected decor, enclosure and crease-discovery candidates are not combined here.

The native path replaces only the coarse U12 mask calculation within the existing
terrain transaction. It qualifies integer coordinates/squares, zero-angle harmonic,
core/transition ranges, guards and derived error budget before native allocation.
Hard-guard cutoff8388608 is unsupported and routes to the original scalar loop;
cutoff8388607 qualifies. No native execution failure is rescued with a scalar retry.

Native float32 roots/inverses receive per-cell residual checks. Conservative error
intervals around weights identify ambiguous rounding cells, evaluated using the
literal predecessor scalar body. Mechanical checks cover BOTH the fallback and
correction expressions, including cache lifetime. Ordered protection products and
scalar half-up rounding remain intact despite native nearest-even GridRound.

The arithmetic argument is conditional, not a fixture-derived universal proof:
see native_outer_mask_source_audit.md and native_outer_mask_bound_test.py. Native
primitive and half-tie evidence supports the documented float32/binary64 model;
domain, allocation, residual, correction coordinate/census and cleanup checks remain
active. Old research diagnostic field names and one prototype comment remain in
the frozen candidate; the audit covers reciprocal coefficient rounding explicitly.
No arithmetic obligation is waived by those stale labels.

Scratch grids are owned/freed locally; successful masks transfer to the existing
patch owner. A qualified failure stops patch processing and prevents SetHeightGrid,
then uses the existing visible OptimizationFailure path. Injected native failures
proved unchanged installed-height bytes/hash and all14 tracked grids freed per
call, but the engine logged errors and continued startup. The original early-abort
test FAILED and is preserved; this candidate does not claim or implement early
startup abort. Ordinary acceptance must have zero error signatures/failures.

All patch planning/order, bounds, sample spacing, full resampling, exact core and
protected disks, blending, dirty regions, final grid installation, immediate and
scheduled pre-T1 rebuilds are unchanged. No RNG calls or mutable caches cross
terrain writes. Object placement, per-rock support, UI, START/T1 boundaries, native
underground bootstrap and first-access behavior retain the accepted code paths.

Evidence before cold launch:
- Six frozen native shadows: 4024386 cells/255 patches exact, full final grids,
  private-stream and rock parity; six unique owned processes closed normally.
- Actual integrated successful reference: 56 native patches/948237 samples and
  full predecessor parity. Subsequent hard-domain fix affects only qualification;
  its native boundary test passed before v987 staging.
- All83 offline commands pass, including inherited80, embedded6383 helper checks,
  both literal-source comparisons and exact rational bounds. Final production
  changes after that run are comments only; parse/source/helper checks repeated.

Cold reference3/control is compared with fresh v983_confirmation_reference:
90.449/90.244/90.104s, median90.244s; control28.532s. Strict reference improvement
plus correctness permits the five-site run against v983_matrix_confirmation:
15S94.076,24S96.625,45S86.192,61N95.773,17S90.805 seconds. All samples and failures
remain visible. No diagnostic gain is a cold gain; no successful sample is rerun.

Inherited visual acceptance requires exact complete final terrain/object outputs,
not merely mask agreement. Final closure is recorded below.
The revised goal is strictly below85 seconds across reference and all five sites.

Reference session99821 CLOSED normally: 88.557/86.046/86.606s, median86.606s
versus90.244s (measured gain3.638s/4.031%). Control29.156s versus28.532s.
Reference audit PASS with no issues: exact predecessors/repeats/private streams,
full snapshots/rock records and four unique normal process shutdowns. This is an
end-to-end reference result, not proof of the same gain at other sites or of every
millisecond's cause. Five-site session95286 is the next immutable acceptance gate.

## Closed acceptance

Session95286 CLOSED normally, all five exact predecessor/private-stream/full-grid/
individual-rock comparisons PASS. All83 offline commands and all ten correctness
rules PASS; nine unique owned acceptance processes closed normally, no errors.
Source scope is exactly the three declared production files, and deployment audit
remains38/38 PASS. All cold runs used56fbf44 without source/HEAD/deployment changes.

| Scenario | Fresh v983 seconds | v987 seconds |
| --- | ---: | ---: |
| Reference median | 90.244 | 86.606 |
| 15S67E | 94.076 | 88.653 |
| 24S74W | 96.625 | 88.711 |
| 45S120W | 86.192 | 82.053 |
| 61N136W | 95.773 | 92.125 |
| 17S11W | 90.805 | 86.546 |

All declared comparisons improved; retain v987 as the next incremental baseline.
No result is discarded or relabeled, and no earlier rejected candidate is included.
These finite comparisons do not establish the exact causal gain independently of
system variation. Under85 across all sites remains FALSE (worst site92.125s).
Goal stays active. The full review is artifacts/v987_all_ten_rules_review.json.

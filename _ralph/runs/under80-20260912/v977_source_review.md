# v977 certified native apron masks

Native generation replaces only the expensive scalar mask evaluations. The exact
scalar weight and final U16 correction expression remain unchanged. Coordinate
fields are exact copied fixed-point rows/columns, with qualified finite bounds.
Native square-root and reciprocal residuals are checked over every grid cell.
The bound derivation is `native_mask_bound.md`; exact-rational envelope checks
pass. The local cubic sensitivity expands the existing rounding bracket; every
ambiguous cell still evaluates the original scalar expression.

Numeric domains outside the certificate retain the literal v975 scalar mask.
Native API/allocation/residual failures instead return an explicit error before
publishing a patch. All added allocation paths and all three corrupted native
power calls are exercised by the actual production helper regression. Added
fields distinguish native mask cells/patches from scalar samples and domain
fallback patches; skipped-cell counts no longer label native work as skipped.

No RNG, candidate scoring/selection, patch order, height target, scalar rounding,
source capture, joins, rock support, resource/rocket/elevator rules, UI buttons,
passability dependencies, readiness gates or stopwatch changes. GridPow is
explicitly obtained through the existing engine API. Runtime977/guard292 gives
the changed captured closure a fresh identity; rejected v976/guard291 is not reused.

Prior diagnostic evidence: strengthened helper passed317440 three-way native U16
comparisons,15414 native-blend regressions,16170 domain/core-endpoint comparisons,
and221 failure/domain/ownership checks. Full fresh reference shadow comparison:
2728ms versus accepted7602ms, zero differences over8192x8192 height cells and full
predecessor snapshots/private streams/individual rocks. Owned process quit normally.
Production additionally removes the unused mask allocation, exposes GridPow in
the caller and clarifies counters. Those diagnostic times are NOT cold samples.

Full production offline suite, committed deployment audit, three cold reference
samples/native control and all five scenarios are required before acceptance.

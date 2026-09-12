# v983 adaptive Q22 apron coordinates

Candidate against accepted c4d3e67/v979. Only Terrain NativeApronMask coordinate
encoding and the matching error bracket change, plus generator298/runtime983.
Sector guard76 and all other production modules remain unchanged.

Use the positive adaptive Q22 encoding and radius qualification proved in
precision_coordinate_research.md. Each per-axis integer span and every combined
corner sum must fit the exact f32 integer domain. The unsigned native setter
receives only nonnegative integers; native arithmetic decodes signed values.
Unsupported numeric domains retain the literal scalar path. Root and reciprocal
residual tests, mask polynomial, scalar correction formula, four-H rounding
reserve, allocation ownership, census and failure handling are unchanged.

The rational bound fixture proves 5/65536 through core0.60 and 7/65536 through0.75,
conditional on the documented inherited native arithmetic/lobe lemmas. Native
storage prerequisites pass646 checks. Native scratch comparison passes523776
exact U16 cells across33 cases against both accepted and literal scalar rasters.
Production regression exercises38115 three-way cells, core/domain boundaries,
encoding span/rounded corners/tiny radii and221 inherited failure/ownership checks.

Full reference shadow adaptive_coordinate_shadow_reference at d39321f, owned
PID48564, closed normally with complete flushed logs and exact surface/underground,
placement, private-stream and individual-rock parity. Entire8192x8192 terrain
comparison found zero differences. All50 patches qualified, with5039674 native
cells and1910302 modified cells unchanged. Scalar corrections808696->396398.
Ordered diagnostic raster times3350ms accepted /1635ms candidate are NOT a cold
startup performance result. No sample is substituted into acceptance timings.

No RNG call, traversal, candidate, quota, object classification, placement or rock
support changes. No terrain transaction, invalidation, pass/build rebuild or
scheduled post-pipeline revalidation changes. START and T1 remain unchanged;
no work moves after readiness. All earlier terrain fixes and temporary elevator
and debug buttons remain byte-identical. Shared RNG audit is source-based in
addition to full private and predecessor captures. Existing visual equivalence
requires exact complete outputs; no new screenshot claim.

Require80 offline commands, immutable reference3/control and all five validation
sites, full deployment audit, unique owned processes and normal shutdowns.
Effective user target is below85 seconds, not demonstrated by this source review.

Acceptance closed:80 offline commands, reference3/control and all five sites PASS
under immutable f4d1da6. Full ten-rule/process/source/deployment review is recorded
in artifacts/v983_all_ten_rules_review.json. Reference median86.718 versus89.425;
site timings and the45S single-sample slowdown remain explicit in STATUS.md.
The effective85-second target is NOT reached.

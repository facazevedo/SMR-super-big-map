# Under-80-second optimization, 2026-09-12

User requested implementation after the feasibility assessment. Target: reference
14N134W and five existing validation scenarios below 80 seconds, measured from START
through required surface post-pipeline revalidation. All current rules, geometry
corrections, seeded placement, individual rock support, and temporary buttons stay.
No automatic Ralph process is running. Primary agent owns this investigation.

Starting HEAD fe39258, clean production worktree; runtime is accepted v972/guard288
(67fa4ab), 38/38 deployed files match. Accepted reference median 102.488s; 61N136W
150.018s. Old experiment artifacts remain unchanged. New evidence lives here.

Initial diagnostic `v972_profile_reference`: old setup returned PROFILE_ERROR
because source anchors did not match CRLF text. No replacement source was executed;
the driver continued generation. Preserve capture/parity and normal shutdown, but
do not call this an instrumented profile or mix it into declared timing acceptance.
New setup normalizes line endings and times source/destination creases and natural
aprons, in addition to the existing rocket/raster splits. Fresh successful profiles
of the reference and 61N136W are next.

Rejected earlier work to respect: exact dirty-region union reduced regional calls
but did not establish end-to-end improvement; final rebuild deferral broke read
dependencies; float32 crease joins differed in rounding. No blind reuse of those.

## Decor obstruction index candidate v974

Code checkpoint `2c68ff3`, runtime v974/guard288. Private append-only obstruction
circles use a spatial hash; the old strict intersection predicate, candidate order,
rejection precedence and random draws are unchanged. All 71 offline regressions
pass (`artifacts/v974_offline`). Deployment audited 38/38.

First uninstrumented 61N136W run: 108.707s versus accepted v972 150.018s, an
observed 41.311s reduction. Exact predecessor grids, placements, rocks, private
streams and eight automated gates pass; the owned process exited normally.
Its decor stage took 9.778s; fresh v972 diagnostic decor took 54.680s. These are
single samples, not an established timing median. Under 80s is NOT reached.

Successful v974 reference diagnostic preserved exact outputs and closed normally.
Captured upvalue timers locate destination crease repair at 7.129s, natural
aprons at 8.056s and outer terrain raster at 7.190s. Nested stages are not additive.
The native function profile also completed with exact output parity and a normal
exit. Its reports are in `artifacts/v974_function_reference`: destination crease
repair made 9,891,316 mod-environment lookups; outer terrain made 10,106,912.
Each lookup traverses ModEnvMeta.__index/rawget. Profiler timing includes overhead
and is not an acceptance sample. Apron weight arithmetic is a separate hotspot.

Reference samples: 106.491 / 104.523 / 105.174s; median 105.174s versus recorded
v972 102.488s. Native control 28.649s. All exact predecessor/repeat comparisons and
automated gates pass; four fresh processes exited normally. This is NOT evidence
of a reference speedup: the observed median is 2.686s slower. The large 61N gain
and this reference result must be reported separately, without selecting samples.

Matrix completed: 15S67E 106.689s, 24S74W 105.515s, 45S120W 101.427s,
61N136W 108.707s, 17S11W 107.850s. All exact predecessor/gates pass and normally
closed. Source/RNG review is in `v974_source_review.md`; `review_v974.py` closed
all ten rules/five scenarios in `artifacts/v974_all_ten_rules_review.json`.
All nine acceptance processes are distinct; deployment still audited38/38.

Next candidate: five entry-scoped standard-library bindings in terrain helpers.
Non-deployed candidate and literal-body certificate are in `artifacts/binding_research`.
Focused test: 3,500 exact fixture comparisons; math lookups 29,612 -> 8, with
between-call library rebinding preserved. Candidate parses. The v974 matrix is
closed; production can now advance to the next isolated checkpoint.

## Terrain standard-library bindings v975 (checkpoint 1f67811)

Runtime v975/guard290, deployed and audited38/38. Exactly five entry-scoped
declarations in the terrain module; arithmetic and call order are unchanged.
All72 offline commands pass. Source review: `v975_source_review.md`.

Fresh reference samples99.851 /97.892 /97.914s; median97.914s versus fresh v974
105.174s: reduction7.260s (6.90%). Native control30.817s. Complete predecessor and
repeat outputs, original gates and normal shutdown all pass (`v975_reference/reference_audit.json`).
Five-site `v975_matrix` completed against v974: 102.317 / 100.171 / 94.862 /
104.302 / 102.034s in manifest order. All exact outputs and eight automated gates
pass. Primary source/RNG/process review closes all ten rules; nine distinct
acceptance processes exited normally. `v975_all_ten_rules_review.json` records
the complete review. Production checkpoint is accepted; the batch is closed.
Under80s is still not reached; do not mark the optimization goal complete.

Non-deployed next research: packed exact native crease certificates. The prototype
passes205,096 offer/winner/51-bit packing comparisons; native production integration
and real-engine validation have NOT been done. See `native_certificate_research.md`.

## Native crease certificates v976 candidate

Production integration completed, runtime976/guard291. All74 offline commands pass
(`v976_offline`). Actual native-grid scratch comparison passed2560 checks;
offline inclusive/exclusive lower bounds passed5120; actual production offer/winner
branches matched v975 over205096 checks. Invalid certificates fail explicitly;
guide propagation and write invalidation tests pass. Source review in
`v976_source_review.md`. Cold output and performance acceptance still pending.

# v993: paired Filler cache integration

Accepted baseline remains 56fbf44/v987, reference median 86.606s and worst site
92.125s. Neither the under-80 objective nor the relaxed under-85 threshold is met.
This candidate is distinct from rejected v992: it maintains placement eligibility
as well as immutable raw masks. The paired private native proofs at 21481b0 saved
1.202/1.211s reference and 1.361/1.381s 61N in complete operation replays, not startup.

## Supported production implementation

Only sbm_map_generation.lua, sbm_version.lua (generator 305) and metadata.lua
(version 993) change in production. Reuse the existing v992 owner bridge and
coroutine/procedure scope, not the rejected algorithm. No engine/harness/settings
edits, private kernel import, debug API, RNG replacement, skipped contacts,
deferred underground bootstrap or altered raster/projection/rebuild scheduling.

GridDest -> four-argument GridDistanceMars identifies one source and live place.
Place initialization remains original; caching starts at the first qualified raw
mask. Integer-only radius/high-bound/scale, matching unsigned dimensions and fresh
trial GridDest lineage qualify requests. Each hit copies the immutable raw mask
at GridMask return, then the maintained boolean eligibility at the exact paired
GridAnd return. Misses execute native calls and validate destination-only tuples.
Similarity, zone masks, seeded selection and trial writes remain native/live.

Original place clears run once with their complete native return tuples forwarded.
The same native circle operation updates a private place guard and each existing
eligibility grid; raw masks never change. A clear between first Mask and And is
valid: the first eligibility clone is constructed from the then-current place.
Unrecognized mutations, arguments, pairings or cross-thread use disable caching
before the relevant original operation; completed raw output remains available.

Native Filler calls GridOpFree(place_grid) before ProcEnd. Validate source and
maintained place in full before that free, then release owned scratch. Missing
ProcEnd and native errors use outer cleanup before existing map/grid transactions
restore. Unexpected direct writes fail the final certificate; this is not a claim
to detect arbitrary mutate-then-restore code absent from the inspected native body.
Production substitution is limited to the supported body and complete admitted
mutation stream established by source review and native shadows.

Pair payload <=32 MiB and <=8 keys. At 768x768, capacity 7 bounds pair payload at
33,030,144 bytes; two guards and two reusable-in-time comparison outputs add a
separately accounted conservative total of 42,467,328 bytes. Five observed keys
mean ten cache clones, two guards, peak fourteen simultaneously owned grids and
sixteen total releases (four comparison repacks over two checks). Failed frees
retain ownership for cleanup retry. Global/class rebindings are never overwritten.

## Gates

The actual marker-delimited production helper passes 4,418 model checks. Added
separate raw/eligible assertions, live/pending clears, wrong-pair fallback,
cross-thread place mutation, direct-place guard-before-free and And/clear faults.
Two inherited raw-mask-only fixture expectations were updated to the deliberately
more conservative paired fallback: unpaired/cross-thread And disables the cache.
No native run was used to tune these expectations. All 83 accepted regression
commands remain unchanged; new actual-helper and source tests extend the suite.

Before native launch: complete all 85 commands, normal deployment audit, commit
and freeze the candidate. Run reference and 61N using the existing production
counter observer and new filler_paired_production_audit.py --version 993. Require
exact full predecessor/private/rock outputs, real hit/miss and every-clear census,
both source/place guards, owned-resource cleanup and normally flushed process logs.
These integrated diagnostics are not cold startup acceptance.

Only after native gates pass, declare a finite contemporaneous/interleaved full
six-site accepted/candidate cold protocol before collecting its first sample.
Retain every raw result and exact payload provenance; do not retry bad timings or
retroactively reinterpret rejected v992. Source/RNG audit and native controls remain
required. Candidate is not promoted merely because a private operation is faster.

All 85 offline commands completed PASS in artifacts/v993_offline, with production
hash-frozen throughout. Execution 98717 closed normally (exit 0). This includes the
unchanged 83 accepted commands and both new actual-production tests. Syntax and
diff hygiene pass. Next freeze/deploy and run the two declared native diagnostics.

## Integrated native qualification completed

Frozen e6976fc4d92a10f2ed54f6bae86ff04b0fc49bd7. Reference execution 23846,
PID 37312, creation 134337860880244119; 61N execution 57346, PID 52524, creation
134337862756175731. Both execution handles CLOSED exit 0 with normally flushed
logs, full predecessor/private-four-field/individual-rock parity and new integrated
audit PASS, issues empty. Native span censuses 95/94 and two generations each.

Reference: 1,524 mask/And pairs, 1,519 hits of each kind, five native misses of each,
1,506 live clears, 7,482 eligibility updates. 61N: 1,798 pairs, 1,793 hits of each,
five misses, 1,782 clears and 8,891 updates. Both: one source and one place guard,
zero invalidations/evictions, ten cache clones, peak fourteen owned grids, sixteen
total releases and zero live scratch. All owner hooks restored; unsupported native
mask calls 693/381 remain live. Full counter expectations were fixed before launch.

The measured integrated underground Filler spans were 956/1,152 ms. They are
instrumented spans from separate runs, not controlled startup savings. Unlike the
private proof, these runs used actual production cached outputs for generation.
No cold sample has been collected at this point. Fresh-game guard is clear.
Next is the prospectively fixed protocol in v993_cold_protocol.md.

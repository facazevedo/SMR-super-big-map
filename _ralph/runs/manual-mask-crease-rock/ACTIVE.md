# Three preservation optimizations - manual session

Requested together: exact outer-resource/rocket coarse-mask shortcuts; native crease
translation rows; immutable rock-capture data reuse/conservative probe rejection.
Baseline e3569f6 / production8342ab2, v963 guard279, median114.612s.
No Ralph controller or goal. Each successful unit separately committed, measured,
and recorded in reoptimize-ranking.md. No previous rules, visuals or buttons removed.
Acceptance: three fresh14N START-to-T1 samples plus native control, allten rules in
five fixed scenarios, exact predecessor terrain/placements/rock grounding and RNG,
all offline regressions. Raw manual-review pending gates remain unmodified.

Completed: v964/5c8ce53 outer-mask candidate accepted. All61 offline
checks pass; exact387829 coarse-mask comparisons and >50% sine-call reduction.
Reference complete114.512/115.056/112.249s; median114.512s versus114.612s, only0.100s
lower and within observed variation. Exact predecessors/repeats all pass. Control29.451s.
Five-site retry COMPLETE on immutable5c8ce53:15S67E113.592s,24S74W110.789s,
45S120W103.355s,61N136W165.318s,17S11W110.651s all exact PASS/normal exit.
All61 offline checks rerun PASS; source/process signoff.py PASS, allten in allfive.
Ranking updated with marginal0.100s timing caveat. No test game remains.
Original15S completed but hung during quit; exact owned PID40436 was stopped by CLI
after diagnostics. Entire original matrix preserved as v964_matrix_shutdown_failed;
not counted in acceptance. Diagnostics under artifacts/incidents/v964_15s_shutdown.
Fresh unchanged-v963 diagnostic complete with full predecessor parity. Height19.480s,
including aprons8.072s; resource preparation16.329s; relief capture4.974s including
native rock capture2.583s. Diagnostic process77256 exited normally.

Crease row prototype is test-only and rejected: mixed-format destination arithmetic
did not produce equal values, and per-row native calls were slower at8-128 cells.
Batch whole independent track rows instead: scratch helper passes69123 primitive
assertions and655391 full detector/order/kernel comparisons over28 overlapping
tracks. Native nominal-identity resampling failed378 cells at8192 rows, so replaced
it with exact doubling copyrect replication. Native_track_probe2 passes all16 cases,
zero differences, same modified counts; scratch scalar948ms->native265ms total.
v965/4931670 native translation passes63 offline checks and exact reference outputs,
but median114.588s is0.076s slower than v964; not accepted, no five-site signoff.
Current: v966/56b8a1f guard282 adds exact join-basis reuse; all64 offline commands pass.
Reference PASS against v964:113.284/113.024/111.262s, median113.024s (1.488s lower),
native control29.067s. Complete predecessor/repeat outputs and RNG are identical.
Five-site sweep COMPLETE on immutable56b8a1f:113.639/111.015/103.324/164.813/110.645s,
all full outputs identical. All-ten source/process signoff PASS, all9 normal exits,
deployment38/38 audited. Ranking updated. Next integrate rock candidate separately.
Helpers: track_candidate.lua
and repair_candidate.lua in _ralph/tmp/mask_crease_rock_20260909. Existing guard/join
fixture gained a scalar-storage adapter without losing any assertion; all8 checks
pass. That tracked test edit is for the NEXT crease commit, not the current mask.
Rock candidate is test-only: cached immutable bounds/visual coordinates and exact
segment-lower-bound rejection pass1441 differential assertions over360 fixtures;
geometry reads66645->2493. Current production fails its work-reduction assertion,
as expected before implementation. Production grounding remains unchanged.

Next complete crease cold acceptance; then integrate rock_candidate.lua and complete
its offline/cold acceptance. No production mutation while cold runner active.

# v986: contiguous crease-discovery scan grouping

Baseline f4d1da6/v983. Only TerrainCopy, generator guard299, runtime986 and release
text change. Sector76 and all other modules are byte-identical to acceptedv983.
Rejectedv984 decor, v985 mask enclosure, v981 guide indexing and v976 packed
buffers are NOT included. Production TerrainCopy must match the native-shadowed
crease_scan_runs_research source exactly after newline normalization.

Native discovery validates integer coordinates, removes duplicates and sorts
dense row arrays. Group only consecutive entries into a call to the EXISTING
sliding-window scan_line_range. No gaps/candidates/widths/edges are skipped or
reordered. Candidate collapse, sorting, caps, greedy track assignment/ties/expiry,
qualification, refinement and all height writes remain unchanged. Empty rows
return without a temporary empty table. Reused height reads are immutable during
collect_axis and local to one scan call; no cache spans a terrain-write boundary.
No new native primitive, allocation, native-index failure recovery or RNG call.

All prior terrain fixes, per-rock support, placements, private/shared streams,
pass/build transactions, UI/debug/elevator controls and START/T1 boundaries remain
unchanged. Required scheduled surface revalidation remains beforeT1. Source and
destination full outputs and existing accepted visuals require exact parity.

Research whole-track oracle compares actual f4d1da6/production collect_axis,
including complete point arrays/order, counters, registered domains and coordinate
read unions.640 fixtures plus first/second native discovery nil/error failures:
1301 checks, native reads5839888->1797110. Inherited crease_sampling3097 checks
also passed against research. Require all80 inherited commands plus this oracle
(81 total), not only the focused tests.

Native forward cce1d69/PID39668 and reverse093cfb6/PID40916 shadows closed normally
with exact full predecessor/private-stream/individual-rock parity. Each checked
all104857600 source+destination U16 cells by exact signed-f32 difference extrema
and every returned report/track/counter. Scratch ownership and restoration PASS.
Destination old/new4042/3248ms and4050/3181ms, savings in both orders. Source
timings were order-sensitive and are not a claimed gain. These are diagnostic
function timings, not startup acceptance samples.

Freeze code/version/HEAD/audited38-file deployment before reference3/control.
Declared comparator v983_confirmation_reference:90.449/90.244/90.104, median90.244,
control28.532. Preserve every sample and do not rescue-repeat a rejected candidate.
A strictly improved reference median permits all five sites against v983_matrix,
with every site regression visible. Full ten-rule/source/process review follows.
The full target is strictly under85 across reference and all five scenarios;
an incremental improvement does not establish completion.

Full immutable a5086ea batch CLOSED: reference session23212, five-site session78785.
All81 offline checks, exact reference predecessor/repeats/private/rock evidence,
all five site pairs, all ten correctness rules and nine unique normal shutdowns
PASS. Reference89.034/89.489/90.484, median89.489 vs90.244 (gain0.755s); native
control29.017 vs28.532. However all five recorded historical comparisons are slower:
15S93.340 vs90.468;24S92.602 vs89.697;45S86.035 vs84.938;61N96.245 vs94.342;
17S90.062 vs87.583. Under85 false. Correctness review is not performance promotion.

Do not promote this as a full-scope speedup. Restore acceptedv983 byte-for-byte;
the new production test is recoverable in a5086ea and research copy retained.
No samples discarded and no unchanged-v986 rescue rerun. These data do not prove
that scan grouping intrinsically caused every five-site increase: the historical
v983 reference86.718 had already shifted to90.244 in unchanged-code confirmation,
while its five sites had not been remeasured. Next declare an independent current
unchanged-v983 five-site confirmation, preserving old and candidate batches. Use
the new baseline for genuinely new optimization work, not to rewrite this outcome.

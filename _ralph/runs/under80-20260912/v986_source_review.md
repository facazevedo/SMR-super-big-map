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

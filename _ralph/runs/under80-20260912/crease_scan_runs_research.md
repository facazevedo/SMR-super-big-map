# Consecutive discovery scan runs (research only)

Accepted production remains f4d1da6/v983. Not v985 enclosure or v981 refinement
guide interval indexing; those remain rejected under their declared cold gates.

Fresh lexical-layout detail profile4639b5f, session4457/PID47136 CLOSED normally.
Full predecessor/private-stream/individual-rock parity PASS, diagnostic restored
at surface scheduled revalidation. Source crease pass267ms; destination3889ms
instrumented. Destination helper inclusive costs: scan_line_range1374ms/171387
calls, native discovery663ms/4, indexed refinement560ms/16105, feather341ms/16671,
guide135ms/16870, native translation101ms/14. Nested timings are not additive;
wrappers/census add overhead and are not cold startup measurements.

Destination native discovery returns171387 unique positions in35342 contiguous
runs, longest35. Source287 positions are all singletons. The producer validates
integer coordinates, deduplicates positions, and sorts each dense row before
returning. Current collect_axis unnecessarily calls its already-sliding-window
scanner separately for every position, rereading the whole neighborhood each time.

Candidate groups ONLY adjacent returned positions; before-edge then after-edge
order, each perpendicular position, width order, candidate collapse/sort/cap,
track matching/ties/expiry, refinement, writes, protections and RNG are unchanged.
No gaps are scanned and no native-index positions are discarded. Empty rows
return without allocating a temporary empty table. Heights are immutable during
collect_axis; the reused window is local to a single scan call, never across a
track repair or terrain write. No native API or failure-path change.

Actual-source collect_axis oracle640 cases/1281 checks PASS. Complete tracks,
point arrays/order, per-edge counts, discovery counters, registered domains and
union of height-read coordinates match. Includes both axes/all four edges,
singleton/dense/gapped rows, threshold/sign/noise/slope/U16 extremes/nil samples,
sample steps1/8 and full greedy track assignment. Native-height read counts
5839888->1797110 in these fixtures. Inherited crease_sampling oracle3097 PASS.
No startup gain is established.

Next native shadow runs original whole RepairInternalHeightStep on an owned
native clone, candidate on the pending actual grid, with every original private
cell joined and lexical source unchanged apart from candidate grouping. Compare
all returned reports/tracks/counters and full U16 grids via exact signed f32
differences/extrema; clean up all comparison grids. Capture full-map parity and
restore original closure beforeT1. Diagnostics exclude clone/comparison time
from old/new block timers but are still ordered warm stage tests, not acceptance.

First native shadow CLOSED normally at cce1d69, session11122/PID39668. Source
37748736 cells and destination67108864 cells match exactly (signed difference
extrema both0), every returned report/track/counter equal, all comparison grids
freed, original closure restored beforeT1. Full predecessor/private/rock parity PASS.
Old/new source264/201ms and destination4042/3248ms. Source discovery has only
singletons, so its63ms difference is not explained by contiguous grouping; ordered
execution, native-grid ownership/cache layout or timing variability may contribute.
Do not present the794ms destination difference as a clean isolated optimization
gain. Next fresh diagnostic reverses order: candidate first on clone, original
second on actual grid, with the same complete outputs and full-map validation.

Reverse native shadow CLOSED normally at093cfb6, session33497/PID40916. Candidate
first/source240ms vs original second215ms; candidate destination3181ms vs original
4050ms. Complete104857600 U16 cells again equal, all returned tracks/reports/stats
equal, scratch cleanup and restoration PASS, full predecessor/private/rock parity
PASS. Destination saving appears in BOTH orders (794ms and869ms); source timing
is order-sensitive and not a claimed grouping gain. No cold startup claim yet.

The collect_axis oracle now additionally injects nil/error discovery failures on
the first/second index call, requiring equal state and no scalar reads/tracks or
domain publication;1301 checks total. No new native allocation or primitive is
introduced by the candidate. The existing native producer ownership/failure
tests remain applicable and must stay in the full regression suite.

Next declared experiment: v986 with ONLY contiguous discovery scan grouping,
generator guard299/runtime986 and sector76 unchanged. Adapt the one new oracle
to compare f4d1da6 with actual production, retain all80 inherited tests (81 total),
and verify production matches this exact research source. No rejectedv984 decor,
v985 enclosure, v981 guide indexing or v976 packed buffers are included. Add the
v986 source review and review_v974.py entry, freeze code/HEAD/deployment, then
reference3/control against v983_confirmation_reference (90.244s). A positive
reference gate permits all five sites against v983_matrix and all ten rules.
The under85 target across the full scope remains unmet.

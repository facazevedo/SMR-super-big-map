# Whole-cell positive obstruction certificates (private research)

Baseline accepted56fbf44/v987, evidence checkpoint3b8feba. Previous goal turn made
verified progress, not completion: reference86.606s, worst61N92.125s. Deployment
38/38 and no live game were confirmed before this investigation. No production
file, metadata, deployment, test harness, settings or other mod is changed.

This is not the rejected expanded-radius index or last-hit hint. Keep the literal
accepted circle index, additionally returning its winning immutable circle. After
32 queries, a private4096-unit cell can learn a minimum radius only if its complete
padded box lies strictly inside that circle expanded by the floored query radius.
Subsequent points in that cell with at least that radius return true without another
distance predicate. All other cases run the full original index. No negative
answer, candidate, cursor result, random draw, rejection order or quota is cached.

Qualification: finite query/circle coordinates within+/-2^24; query radius0..65536,
circle radius0..2^24. Pad cell endpoints by1, round maximum corner deltas outward
with ceil()+1, require deltas<=2^25, and shrink floor(circle radius)+floor(query
radius) by1. The integer squared comparison is exact in signed64 and binary64.
Conditional rational bounds cover corner calculation, old scalar strict predicate
and original index bounding endpoints. No approximate sqrt is used. Unsupported
inputs take the old query; a32768-cell storage cap bounds memory, never work.

Positive certificates survive append-only lists because they refer to immutable
circle geometry. Run creates the private arrays/records at decor lines392..435 and
only appends records at639..641; no mutation/removal/cross-Run sharing. Cache misses
catch up the accepted lazy index. Existing records may lower their radius at cap.

Offline54581 separate-index old/new/exhaustive comparisons PASS, including1601
certified answers, strict tangencies, fractional/negative coordinates, cell/radius
boundaries, appends, independent list lifetimes, memory cap and numeric refusals.
The exact-Fraction bound script PASS is a conditional arithmetic argument, not
exhaustive evidence about arbitrary engine behavior or a performance result.

Native shadow clones only Run and joins its private cells. Old and new queries use
SEPARATE private index state, with the same immutable circle records and append
sequence. Both execute for every real call; the original result alone controls
the game. Timings include each query's own index/certificate construction. The
wrapper records certified/full query counts and restores Run at the existing
scheduled surface revalidation. Full predecessor/private/final/rock parity and
normal owned process shutdown are mandatory. Native effectiveness is pending.

## First native prototype: exact but slower, not promoted

Session37594/PID50100 CLOSED normally at4cf9613. All775867 real queries matched,
584396 certified answers (75.32%), full predecessor/private/final/rock parity PASS.
Old2666ms versus prototype2947ms: FAIL performance, preserve this result. Separate
indexes remove shared warm-state bias; no cold timing claim or production edit.

The cache learned89147 certificates in28573 cells, and191471 queries still used
the complete index. Preparation and hot-path overhead can outweigh avoided scans.

## Materially simplified v2, still private

Audit all three try_stamp call sites: authored x/y are type-checked PointXY values;
random-annulus x/y are arithmetic with tonumber offsets; finite-cursor x/y are
arithmetic results. All site radii are arithmetic from tonumber(marker.DecorRadius).
Thus the local query is numeric-input-only; v2 removes three repeated type calls
per query, retaining finite/range checks. The native shadow explicitly audits this
contract outside the timers. No public string/table input contract is narrowed.

Cache immutable per-circle qualification/floored radius and per-query-radius
floor values instead of recomputing them on every learning attempt. Replace four
endpoint absolute values and two max calls with the exact padded-cell identity
max(abs(low-c),abs(high-c))=abs(midpoint-c)+2049, then ceil()+1 as before. The same
integer-square and inward-reach proof applies. Scalar decisions remain untouched.
Require the same independent oracle and a new native result; do not rerun v1.
Per-radius floor cache has a1024-entry memory cap; beyond it, recompute the same
floor on demand. Descriptor storage is at most one record per already-owned circle.
Expanded offline suite55681 comparisons also verifies the radius-cache cap.

v2 forward session74170/PID5840 CLOSED normally ata1ebf55: all775867 queries exact,
same584396 certified answers, full predecessor/private/final/rock parity PASS.
Old2706ms/new1699ms, saving1007 diagnostic ms. This is not a cold startup result.
Next reverse the old/new order with unchanged helper, then inspect the reference
map before any production candidate. First v1 remains rejected, never relabeled.

## Reverse and reference screening complete; no production promotion

At a163f6a, reverse61N session21088/PID40040 CLOSED normally: all775867 queries
exact,584396 certified; old2584ms/new1865ms (719ms diagnostic saving). The unchanged
v2 helper therefore improved the slow-map query timing in both execution orders.

Reference session47268/PID19148 CLOSED normally:1806 queries exact, only85 certified
answers; old6ms/new21ms (15ms diagnostic regression).1213 cells learned1233
certificates, so most training had no subsequent use on this small workload.
This is explicit counterevidence to a uniform speedup, not an excluded sample.

All four research runs (v1, v2 forward/reverse61N, v2 reference) pass the additional
private_process_audit.json checks: four private-stream fields, complete predecessor
and rock snapshots, exact query census, correct v987 payload/incident, clean fully
flushed engine/daemon logs, wrapper restoration and unique normal process exits.
No cold run or production integration has been performed for this idea.

Keep v987 deployed. Do not stage v2 unchanged as a generally faster release.
The slow-map opportunity is real enough for further research, but it cannot close
the reference gap: that map spends only6 instrumented ms in these queries. A
generic workload/reuse-based cache admission scheme could avoid mostly-unused
certificates; any such scheme must still execute EVERY original query on a miss,
not use map IDs, alter candidates, skip RNG or cache negative answers. Its extra
bookkeeping must be measured, not assumed free. Separately pursue the larger
collection-only crease-offer opportunity for reference startup time. An eventual
combination requires independent exact oracles and immutable cold acceptance.

## New v3 workload admission investigation

After v988's mixed cold timing (not promoted), production remains exact56fbf44/v987.
v3 changes only admission to the private v2 certificate: existing per-list full-query
serial must reach4096 before allocating ANY certificate/descriptor/radius tables.
It adds no low-workload counter, map ID branch, placement budget or skipped query.
After admission the prior numeric proof, positive-only certificates, list lifetime,
append semantics and caps are literal v2. This is a new variant, not a v2 rerun.

Offline15198 exact queries pass using actual serials (first4096 no cache, first
learned hit4097, repeated certification, append/lifetime,5000 negative queries).
Inherited55681 numeric/old-new/exhaustive/cap comparisons pass in explicitly admitted
test state,1825 certified answers; the test adapter advances metadata only to reach
that branch, so it does NOT prove natural admission. Separate15198 test does that.
Unchanged conditional Fraction bounds pass. No speedup claim before native tests.
Generate frozen forward/reverse setups using the established full-query comparator;
measure reference first to screen low-workload overhead, then61N if worthwhile.

First retained offline runner FAILED its textual source-equality assertion because
two explanatory comment lines were absent; all executable lines matched. The
earlier direct behavioral/bounds tests passed independently. The shell sequence
continued to commit/native launch despite this assertion; preserve the failed
attempt as failed. Follow-up runner removes only the two explicitly asserted
comment lines for exact source comparison and writes a separate artifact directory.
No candidate executable code changed, and no behavioral assertion was relaxed.

Native v3 reference forward session79434/PID40324 at5c78882 CLOSED normally PASS:
all1806 queries exact, no certificates or cache tables admitted (full1589+217),
old16ms/new9ms. This tiny diagnostic difference is not a claimed speedup; the
useful evidence is absence of v2's unused learning. Full predecessor/private/rock/
process audit PASS. Next inspect slow61N and reverse order before any integration.

v3 slow61N forward52684/PID47328 ated0fa1b CLOSED exact775867 queries,578315
certified, old2625/new1862ms. Reverse80976/PID49748 atsameHEAD CLOSED exactsame
counts, old2534/new1818ms. Both private/full/rock/process audits PASS. Reference
reverse28492/PID15088 CLOSED1806 exact, no cache admitted, old13/new12ms; all audits
PASS. Four native owned processes closed normally and no game remains.716..763ms
slow-map saving is diagnostic only; tiny reference differences are not a speedup.

v989 now stages the exact v3 factory as a local wrapper around the unchanged index,
with only the private winning-circle second return. No v988 terrain changes combined.
Full actual integration source/geometry/admission checks pass; comparators pinned
to git56fbf44 so the new Code is never its own baseline. Deployment staysv987 until
all87 commands pass. See v989_source_review.md for contract, bounds and cold gates.

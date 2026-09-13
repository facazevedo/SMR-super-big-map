# v989: workload-admitted positive obstruction certificates

Based on accepted56fbf44/v987, not rejectedv988. Changes are limited to the local
decor circle helper/DecorTopUp.VERSION11, generator guard301 (sector76 unchanged),
metadata989/release text. TerrainCopy remains literal acceptedv987.

NewPositiveCellQuery is exactly the native-tested private v3 factory with a local
name instead of its module return. The original indexed predicate returns its
winning circle as a second private value. The wrapper exposes only its original
boolean; no candidate sees the winning circle or a changed rejection precedence.
The original Run, candidate generation, stamping, weighted selection, finite cursor,
every RNG call and every field outside this private helper remain literalv987.
The source test reconstructs that complete baseline, not just selected call sites.

The existing per-list full-query serial must reach4096 before allocating certificate,
descriptor or radius tables. This is a workload admission rule, not a query budget:
all queries still execute, either returning a proven positive or the original full
indexed predicate. The first4096 calls allocate no certificate cache, and no extra
counter is maintained. Both lists are private to one Run, append-only with immutable
circles. A positive certificate remains valid after append. A miss indexes every
appended circle. No negative answers are cached. Radius floors cap at1024 entries;
certificate cells cap at32768 per list; descriptors are bounded by owned circles.

Existing v2 proof retained literally after admission: qualify numeric query x/y
within +/-2^24 and radius0..65536; circle x/y within +/-2^24 and radius0..2^24.
4096-wide cells are conservatively padded, farthest-corner distances rounded outward,
circle/query radius floors rounded inward with one extra reserve. Integer squared
bounds are exact within2^51; strict inequality certifies the literal floating circle
predicate despite its bounded roundoff. Inconclusive or unsupported cases run the
complete original search. Caller numeric contracts follow checked PointXY/arithmetic
paths already reviewed for v2. No terrain/placement/rock/rebuild/bootstrap/T1 change.

Private evidence:15198 actual-serial admission/append/lifetime/negative checks;
55681 inherited geometry/old-new/exhaustive/cap checks in explicitly admitted test
state; v2 regressions and conditional Fraction bounds pass. First source-equality
runner failed on two missing comment lines before running commands; retained as
failed. Follow-up exact comparison excludes only those two explicitly asserted
comment lines and all five commands pass. No candidate executable code changed.

Four native shadows CLOSED normally. Reference79434/PID40324 at5c78882:1806 exact
queries, no cache admitted, old16/new9ms.61N52684/PID47328 ated0fa1b:775867 exact,
578315 certified, old2625/new1862ms.61Nreverse80976/PID49748 ated0fa1b: same queries/
certified counts, old2534/new1818ms. Referencereverse28492/PID15088 ated0fa1b:1806
exact, no cache admitted, old13/new12ms. All full predecessor/private/rock/process
audits PASS. These716..763ms slow-map savings are diagnostic, not cold startup gains;
the tiny reference differences are not a claimed reference speedup.

Actual integrated production source is tested via extraction of the WHOLE binding
block, including original index and final wrapper assignment. Independent comparators
read git56fbf44, not current modified Code. Admission15198 and geometry55681 checks
pass on this integrated block; exact source/invariant review passes. Full87-command
suite required: all83 accepted regression commands plus4 integrated/proof checks.

No release acceptance yet. Keep deployedv987 until the full suite passes; freeze
committed source and audited38-file payload before any cold tests. Declared reference
comparatorv987_reference median86.606s/control29.156s; five-site comparatorv987_matrix:
15S88.653,24S88.711,45S82.053,61N92.125,17S86.546s. Retain every sample/regression.
Existing strict reference improvement gate precedes five-site testing. Primary
native hypothesis is reduced slow-map query cost, not a claim this alone meets the
full startup target. No rescue repeats or combination with rejected candidates.

Full actual-production suite39125 CLOSED PASS all87 commands. Final source hashes
match every current Code/metadata/items file. Four unique native process/private/
full-output audits pass. No game is live. Candidate is ready for committed cold
testing, not accepted. Deployment is intentionally stillv987 until that phase starts.

## Closed cold result: exact, but not promoted

Frozen b130478 completed reference session64402 and five-site session91253. All
nine unique owned processes CLOSED normally with complete captured logs. Reference
samples86.520/86.523/84.159s, median86.520s versusv98786.606s. The0.086s (0.0993%)
difference is not a reliable reference speedup claim; it narrowly passed only the
predeclared gate to run the five-site comparison. Control28.991s versus29.156s.
All reference predecessor/repeat/private/full-grid/individual-rock checks pass.

| Site | v987 seconds | v989 seconds | Saving seconds |
| --- | ---: | ---: | ---: |
| 15S67E | 88.653 | 90.450 | -1.797 |
| 24S74W | 88.711 | 88.802 | -0.091 |
| 45S120W | 82.053 | 85.638 | -3.585 |
| 61N136W | 92.125 | 91.474 | 0.651 |
| 17S11W | 86.546 | 87.440 | -0.894 |

All five full predecessor/private/terrain/rock/native-control checks pass. Final
v989_all_ten_rules_review.json records87 offline commands, nine unique process
identities, complete source/RNG/inherited visual audit and38-file deployment audit.
It also explicitly records all_scenarios_faster=false and both targets unmet.
61N's cold saving is consistent with the diagnostic lead but cannot cancel four
other regressions. No claim attributes every startup difference to this helper.
The snapshot attempt counts are preserved (15S12468,24S61918,45S3032,61N727247,
17S4539); they are not exact query/cache-admission counters, and must not be used
to infer an unrecorded cache census. No rescue repeat or baseline relabel performed.

Candidate NOT promoted. Only the three owned production files restored via patch
to exact56fbf44/v987; source comparison confirms Code/metadata/items equality.
Standard deploy sync/audit38/38PASS, no stale deletion, fresh check no live game.
All native/offline/cold evidence and b130478 remain preserved. Accepted timing is
stillv987reference86.606s and worst61N92.125s; restoration is not a new timing test.

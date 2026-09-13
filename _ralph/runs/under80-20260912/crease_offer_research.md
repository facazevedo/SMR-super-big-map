# Collection-only signed crease offers (private research)

Baseline is accepted56fbf44/v987, latest research checkpoint51ca82a. The previous
turn was PROGRESS: exact obstruction-cache evidence identified a slow-map saving
but reference overhead; it was not promoted. No production change in this study.

Unlike rejectedv976, this representation stores signed deltas in separate per-width
row dictionaries, not packed51-bit words. Consumption is ONLY during immutable
collect_axis. Refinement, exclusion guides, write invalidation and all terrain
operations remain byte-identical to v987. Rejected contiguous grouping is absent.

Native discovery already computes exact signed U16 differences. After a is consumed
as an operand, copy signed magnitude into that existing f32 scratch grid before
GridAbs. Bias/double/mask yields0 for rejected values and even2..262142 for accepted
values, with unambiguous lower enumeration threshold1. Existing independent count,
coordinate/value, duplicate, bounds and cleanup checks remain. Store decoded signed
deltas per width/along/perp. No new grid allocation or native API is introduced.

Keep identical sorted position rows and statistics, and emit offers in original
perp/width/before-edge/after-edge order. At perp>perp_n-max_width-2, retain every
literal original scalar read/predicate: a narrower width may have discovered that
position outside a wider width's valid domain. Never reuse offers after collection.

Initial generated draft crease_offer_research had a Lua and/or width-selection
bug found during source review: missing width1 could select width3. It was never
run or deployed. Draft2 uses explicit if/elseif selection. Preserve both artifacts.

Offline grid oracle:2566 checks under each inclusive/exclusive mask convention,
plus7 invalid packet/enumeration cases PASS. Whole actual collection oracle:3725
complete track/point/order/domain/census/boundary/failure checks PASS; fixture
height reads940148->15360. These are correctness/work counts, not speed evidence.

Important model gap: shared native_grid_double copyrect routes through its unsigned
setter and cannot model negative f32 copies. The private test adapter implements
raw f32-to-f32 copy, without changing shared tests. Actual native signed-copy checks
are mandatory, first in the shared native oracle. Do not treat the adapter as proof.

Next native setup runs the same2566-check packet/copy oracle, then compares full
old/candidate RepairInternalHeightStep in original lexical layout, on both source
and destination grids. Exact signed-f32 difference extrema must be zero across
all104857600 U16 cells, with identical full returns. Each function has its own
input grid; all original private cells join except the private new discovery
helper. Restore the wrapper at the existing scheduled surface revalidation.
No RNG, class, placement, rock-support, passability, bootstrap or T1 changes.
Native effectiveness, additional ownership failure checks and cold gates remain.

## First native oracle stopped before installing the candidate

At9ab4a4b, session37775/PID50392 CLOSED normally with driverFAIL/engine_error.
Native oracle2566 checks reported six failures: expected negative to:get readbacks.
The other2560 signed-offer fixtures passed, including both signs. No candidate
repair wrapper was installed (calls=[]); this is a failed setup, not a parity pass.
All logs, diagnostic state and failed rules report remain in the original artifact.

Do not infer copy corruption from unsigned-looking readback alone. The follow-up
fixture records BOTH negative source/destination get values, then adds65536 to the
copied grid natively and checks positive1..4. This directly tests retained signed
storage without assuming get()'s conversion contract. The production candidate is
unchanged. Accept only if this plus every signed packet and full-grid check passes.

The first ownership-test invocation also failed in setup: native_grid_double does
not define GridMask. It stopped with "normal build failed native crease API
unavailable: GridMask" before allocation injection. The test now supplies the same
explicit strict GridMask model used by the existing parity fixtures; no accepted
test or shared double was weakened. Its failure result is not counted as a pass.

## Signed storage and full native reference verified

Session56002/PID17572 CLOSED normally at413956a. Native oracle2566 PASS. Source and
copied negative get() readbacks both returned4294901761..4294901764; adding65536
natively to the copy yielded the exact expected positive1..4. Thus signed storage
and copy are correct; the initial six assertions misunderstood Lua get readback.
The original failed setup remains failed and archived, not rewritten as a pass.

Full old/new RepairInternalHeightStep comparison PASS: all37748736 source and
67108864 destination U16 cells exact, complete returns equal, scratch freed and
wrapper restored. Full predecessor/final/rock parity PASS. Source274ms/new229ms;
destination4217ms/new3275ms (942ms diagnostic destination saving, not cold startup).

Ownership regression150 PASS: normal old/new both49 allocations, every allocation
position returns nil/false/throws, plus the new signed-copy throw; owned grids freed,
input unchanged and failures visible. First missing-GridMask test setup remains
documented above and is not counted among these passing cases.

After native evidence, correct the SHARED OFFLINE f32-to-f32 copy model to preserve
signed storage rather than use the unsigned setter. This is a test-model correction,
not a harness/engine change or relaxed assertion. A dedicated six-value native-
matched regression and all83 accepted-v987 commands must pass before integration.
Other formats retain the old model. Public negative get() semantics are not modeled
by this internal arithmetic double; oracles must use native bias for such checks.
Next reverse full native order with unchanged candidate source.

Reverse40059/PID34972 CLOSED normally at22a868a. Expanded native oracle2572 PASS,
including six additional fractional signed-copy/bias checks. All104857600 height
cells and complete returns again match, with cleanup/restoration and full final
predecessor/rock parity. Source old216ms/new244ms (28ms slower), destination
old4130ms/new3172ms (958ms faster). Do not claim a source-pass improvement.
Explicit private/process audits PASS both successful full shadows, including four
private-stream fields and fully flushed error-free normal shutdowns.

Accepted-v987 baseline with corrected shared copy model passes all83 inherited
commands. Actual native signed/fractional copy evidence validates the model fix;
crease_offer_test no longer uses any private model override. The original native
negative-readback and missing-mock-API failures remain archived/documented.

Stage v988/generator300/sector76 from exact native-shadowed draft2, with no other
production candidate combined. Actual Code must equal the tested artifact. The
full v988 suite requires all83 inherited commands plus five actual source/offer/
ownership/copy checks (88 total). Deployment remains v987 until this gate passes.
Then freeze a committed candidate for reference3/control versus v987_reference
(median86.606s, control29.156s), and only after strict reference improvement the
five sites versus v987_matrix. Native milliseconds are not cold startup gains.

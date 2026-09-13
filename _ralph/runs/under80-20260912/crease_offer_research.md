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

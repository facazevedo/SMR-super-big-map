# v992 candidate: scoped native Filler mask reuse

Accepted baseline remains56fbf44/v987 (reference86.606s, worst61N92.125s).
Neither full<80 nor relaxed<85 is achieved. This is a new production candidate,
generator304, not promotion. Prior explicit Astra xhigh review reconfirmed the
mask cache first, decor rejection dispatch and object observation reuse next;
Playable secondary-transform reuse is low priority (~20 redundant calls/site).

## Actual implementation

Only production files changed: sbm_map_generation.lua, sbm_version.lua, metadata.lua.
The marker-delimited helper is tested from the actual file. No diagnostic debug
APIs, private prototype import, extra code module, class-generation replacement,
engine/settings changes, random draws or grid-selection replacement.

Install through the existing supported ordinary-write/raw-shadow owner bridge,
after mark-grid hooks and before the existing native pcall. Compose CURRENT
ProcStart/End; scope to this generator's Filler and coroutine. GridDest followed
by the original four-argument distance transform certifies source lineage. A
fresh GridDest(source) output, unsigned matching grids, integer bounds/scale,
upper2147483647/scale1 qualify masks. Native misses preserve the actual tuple;
supported hits fully copy and return destination. Unsupported calls retain native
behavior, including integer-valued floats. Similarity/placement writes and every
seeded selection remain original.

Source proof combines the inspected stock Filler body, prior all-request native
shadow certificates on two maps, lineage and conservative pre-mutation invalidation
hooks. A pre-first-mask source clone is compared in full at scope end through
independent exact U->f32 subtraction/absolute/count operations. Direct userdata
writes are not generally interceptable; an unexpected final source difference
fails generation after restoration, rather than accepting stale placement output.
This is not a claim that an end guard detects arbitrary mutate-then-restore code;
such code is absent in the inspected supported procedure and captured executions.

Deterministic LRU <=8 entries and<=16MiB mask payload. Additional guard and two
temporary comparison grids are counted separately: actual768x768 source has
capacity7, mask bound16515072bytes, total conservative scratch bound23592960bytes.
Expected five cached masks +guard+two comparator grids means peak8 owned grids.
Only owned clones/repack outputs are freed. Failed frees retain ownership for retry.

Known mutators invalidate BEFORE touching the source, including in-place GridMask
and operations from another coroutine. Global/class rebindings are not overwritten.
Partial install, ordinary completion and missing ProcEnd all use outer cleanup.
Cache failure is propagated through the existing native failure result after
projection/raster/source-map restoration, with explicit return even if native
error() only logs. Required eager bootstrap, immediate/scheduled rebuilds and T1
readiness are unchanged. Source/bytecode checks do not prove native correctness.

## Verification and next gates

Initial fixture run failed because the mutation test called GridRepack itself but
did not release its caller-owned result. Fixed that fixture cleanup only. Actual
helper then passed2414 fixture checks, including eviction, exact outputs, tuple
holes, fractional fallback, source/direct/cross-thread mutations, cloned-output
isolation, native/clone/copy/free faults, partial installation and owner rebound.
These are model checks, not real engine test counts.

filler_production_offline.py replays all83 accepted commands unchanged plus the
actual helper fixture and source/transaction checks. Results and frozen production
hashes are retained under artifacts/v992_offline; consult final exit statuses.

Completed all85 commands PASS, including unchanged83 accepted tests and2414
actual-helper fixture checks. Production stayed hash-frozen throughout the suite.
Normal deploy sync copied only the three declared production files; audit38/38
PASS. Fresh-game check clear before the candidate's native diagnostic launch.

Next: deploy through normal deploy.py and freeze candidate checkpoint. Run fresh
reference and61N with filler_production_profile.lua/querySBM_NATIVE_PROC_DIAGNOSTIC.
filler_production_audit.py --version992 inherits full native span, predecessor,
individual-rock, four private-field and normally-flushed process/log checks; it
additionally requires actual1524/1798 calls, five misses, all expected hits, source
guard, bounded ownership and restored production hooks. Audit version is explicit;
the accepted default remains987. No relaxed error or correctness gate.

Only after integrated native PASS: frozen cold reference3/control and five-site
matrix, complete source/RNG review and rejection/promotion decision. Prior private
735..857ms mask replay gain is NOT a startup saving. No unmeasured speed claim.

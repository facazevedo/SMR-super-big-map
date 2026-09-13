# Primitive census inside native underground prefab selection

Previous turn PROGRESS: native procedure profiles atcf1af4d passed full audits.
UG FindPrefabPos5348/4647ms reference/61N contains Playable2149/1062,
Filler2116/2479 andBase921/857. This new probe partitions those three stages into
existing native grid operations before selecting a production optimization.
No startup gain or changed generation behavior is claimed.

## Scope and ownership

native_proc_profile.lua now supports an optional diagnostic observer; with none
present, all203 existing fixture checks still pass. Observer callbacks bracket
generation and procedure boundaries and restoration. Any callback exception or
explicit failure is latched by the base probe without replacing native work.
The observer is loaded from diagnostic files only; no production/engine module
reload or class-generation-method replacement. Its registration slot is removed
immediately after setup, while the base probe retains the private observer.

prefab_primitive_observer.lua discovers the actual original native DoGenerate
function's _ENV through debug.getupvalue, rather than writing sandbox-only
shadows. During only UG FindPrefabPos_Playable/Filler/Base, it wraps15 existing
grid primitives plus table.weighted_rand in their resolved owner tables. Each
original function executes once with identical arguments and complete return
tuple, including nil positions; exceptions propagate with explicit error latches
for logging-only engine error behavior. No RNG state read/advance/replacement.

Captured primitives: GridDistanceMars, GridMask, GridAnd, GridOr, GridNot,
GridMulDivAdd, GridMulAddScaled, GridDest, NewComputeGrid, GridMinMax, GridEquals,
GridStableRandomPosSimple, GridStableRandomPos, GridCircleSet, GridOpFree and
table.weighted_rand. Other coroutines pass directly through untouched. Counts,
inclusive and exclusive durations aggregate by primitive and selected stage;
nested primitive cost is subtracted once. No per-cell records, argument dumps,
grid reads, function profiler, configuration or native allocation changes.

All originals are checked before any slot changes. Attempted partial installation
cleans up already-written slots, including a write that assigns and then throws.
Restoration verifies resolved identities AND original raw slot presence, including
inherited globals. Rebound slots are flagged, never overwritten. Generation
errors close/restore unfinished scopes.16-scope/250000-call caps latch failure,
not skipped native work. Final scheduled restoration verifies no retained context,
all global hooks restored and count consistency. Existing base lifecycle checks,
mark-grid projection, serial raster, private streams and preT1 rebuilds remain.

## Prerequisites

prefab_primitive_offline six-command PASS initially329 observer+203 base checks.
Then added raw-slot restoration and inherited-owner fixtures; preserved first
batch and replayed into prefab_primitive_offline_2:366 observer+203 base checks,
syntax checks, exact Code/metadata/items56fbf44 comparison and38-file deployment
audit PASS. The first batch was not a failure. Python audit syntax also passes.
Fixtures cover scope/thread/nesting/tuple/count fidelity, missing environments/
globals, native errors, incomplete/mismatched scopes, rebound globals, capped
recording, partial install failure, inherited raw slots and integrated driver.
Offline fixtures do not substitute for actual shipped-environment reachability.

Freeze checkpoint; run one reference and one61N in fresh owned hidden processes
through profile.py with setup prefab_primitive_profile.lua and query
SBM_NATIVE_PROC_DIAGNOSTIC. prefab_primitive_audit.py inherits ALL native_proc
full predecessor/private/rock/process checks, adding exactly3 selected UG scopes,
procedure identity, native seeded-selection reachability, primitive count/
exclusive accounting, no open calls, and global hook restoration.

## Decision gate

Timings include observer overhead and are diagnostic wall times, not CPU or cold
startup. Compare counts and dominant primitive costs, not cross-run differences
as savings. If allocation is small, do not implement a grid pool because visible
source has reuse TODOs. If grid transforms/masks dominate, consider exact reuse
only after proving input mutation/ownership/format behavior. Similarity grids and
placement grids change after successful placement, so dimension/prefab-only
caches would be invalid. If seeded selection dominates, retain exact engine
selection and RNG until an independently justified alternative exists.

Acceptedv987 remains86.606s reference/worst92.125s. Full<80 goal and relaxed<85
remain unmet. This diagnostic is the next decisive experiment, not promotion.

## Native reference and61N CLOSED PASS

Frozen48d23c8. Reference exec49148/PID52656 creation134337694799399345;61N
exec93300/PID31848 creation134337697066704037. Both CLOSED exit0 and full
prefab_primitive_audit PASS issues[], exact predecessor/full-grid/individual-rock
outputs, four private fields, no engine errors and normal flushed shutdown.
95/94 base spans, three selected UG scopes each, all actual shipped primitive
hooks reached as applicable, no open calls and exact global/raw-slot restoration.

| Scope/primitive | Reference calls/ms | 61N calls/ms |
| --- | ---: | ---: |
| Playable whole scope | 5737 /2151 | 2844 /1065 |
| Playable GridDistanceMars | 629 /1152 | 307 /563 |
| Playable GridMask | 651 /280 | 330 /147 |
| Filler whole scope | 10957 /2137 | 12718 /2532 |
| Filler GridMask | 1524 /870 | 1798 /1012 |
| Filler GridAnd | 1525 /611 | 1799 /719 |
| Filler GridStableRandomPos | 1519 /500 | 1795 /611 |
| Base whole scope | 9187 /959 | 8963 /890 |
| Base GridStableRandomPos | 2457 /787 | 2344 /759 |

Primitive milliseconds are exclusive aggregates; whole-scope calls count all
observed primitives. Parent rows and primitive rows overlap. Total recorded
calls25881/24525. Scope remainders30/17,60/69,87/71ms include unmeasured work AND
probe overhead. All GridDest+NewComputeGrid costs total only7/2ms across these
three scopes. A grid allocation pool is therefore not justified by this data.
GridDistanceMars total1155/568ms; plain+simple seeded grid-selection1320/1393ms.
Masks and intersections together total1893/1937ms, mainly in Filler. Full JSON/
Markdown comparison: artifacts/v987_prefab_primitive_comparison.

These are diagnostic WALL measurements, not savings or cold-start acceptance.
No cross-run delta against prior coarse values is a speedup. Native primitive
wrapping adds pcall/counter overhead; the large costs are still actual native
operations, not the source allocation TODOs hypothesized earlier.

## Private next candidate, not production

Filler builds distance_grid once, then repeatedly computes radius masks against
that field. Unlike mutable place_grid and similarity grids, distance_grid has no
visible write after its initial transform in the inspected stock filler body.
This is an input-stability HYPOTHESIS needing actual-call certification; the
shipped code may differ from the source reference. No radius/key reuse frequency
was captured by the timing probe, so cache hit rate is still unknown.

Added private filler_mask_cache.lua: deterministic bounded LRU over complete
(from,to,scale) keys for ONE caller-certified immutable source. Miss computes
the original mask and owns a clone; hit copies it fully to a separate destination.
No deferred write/fused GridAnd, no skipped seeded selection or candidate, and no
change to the original game call path. It reports its own success, not a pretend
native GridMask return tuple. Caller-owned source/destination are never freed.
Caps0..32 are supported for model testing; native admission must additionally cap
bytes, conservatively e.g.16MiB/4bytes-per-cell and at most8 masks.

filler_mask_offline_2 four-command PASS,34939 model assertions/comparisons:
capacities0..8,300 request sequences each on10-cell integer sources, independent
mask oracle, explicit cache hits/full overwrite, parameter-key distinctions,
LRU eviction, caller mutation isolation, bounded live entries, source alias and
mask/copy/clone/free failures. Failed frees retain ownership for cleanup retry;
nil/false/aliased clone results are rejected. Initial34935-check batch retained
before adding false-clone coverage. These are NOT native cell counts or actual
production tests; conditional cache semantics do not prove native suitability.

See filler_mask_research.md for the decisive native shadow plan and stop gates.
No cache configuration, mod version or production behavior changed. Accepted
v98786.606s reference/worst92.125s, full<80 and relaxed<85 goals still unmet.

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

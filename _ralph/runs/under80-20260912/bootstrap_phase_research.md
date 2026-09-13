# Coarse bootstrap phase investigation on accepted v987

Fresh sparse profiles showed bootstrap6404ms reference versus1664ms on61N.
This diagnostic separates twelve sequential phases of the SAME function:
preflight, wonder assignment, native wonder clearance/resume, surface bridge
setup/copy/bind, passage search/spawn/clearance, passage resume, bridge restore,
common-hex planning and final verification. No measured gain is claimed yet.

bootstrap_phase_instrument.lua inserts twelve bootstrap_phase calls. Removing
those exact insertions reconstructs the entire original function byte-for-byte.
No statement is replaced, no branch/budget/native transaction/RNG draw omitted.
bootstrap_phase_profile.lua compiles ONLY this one function, not the module, and
joins every original private upvalue cell including_ENV. Unexpected/lost cells
fail before hook installation. The same PatchRandomMapGenerator bootstrap cell
is used by the existing engine wrapper; restoration occurs at scheduled surface
revalidation, with explicit failure latches and cleanup on exception/false return.
Config flags and function-profiler/engine settings remain unchanged.

The wrapper preserves full return tuples including nil positions. Each phase
switch closes the prior phase; the wrapper closes the last one on return. Negative
durations, phase-order/count mismatches, recursion and incomplete bootstrap fail
the diagnostic. All original native wonder/pass-edit transactions, bridge-owned
grids, passage queries, common-hex plans and T1 readiness dependencies remain.
One short log follows restoration. Timings are diagnostic WALL time, not CPU
attribution or cold-start samples. Full private/output/process audit is mandatory.

First offline batch bootstrap_phase_offline FAILED its wrapper fixture: the fake
mod environment omitted standard globals, so instrumenter ipairs was nil. No
native run or production change occurred. Fixed only the fixture's environment
to expose the normal globals; failed evidence retained unchanged. Fresh batch
bootstrap_phase_offline_2 PASSES all five commands: original/instrumented syntax,
exact source reversal,24 missing/duplicate anchor rejections,52 wrapper tuple/
private-cell/setup/phase/error/restoration checks, exact56fbf44 Code/metadata/items
comparison and38-file deployment audit. The wrapper fixture does NOT execute
native bootstrap semantics; actual real-engine parity remains required.

Run one reference and one slow61N fresh hidden process through profile.py, pinned
to the acceptedv987 game/UG seeds, querySBM_BOOTSTRAP_PHASE_DIAGNOSTIC. Use new
artifact directories, capture complete outputs and normal flushed shutdowns.
bootstrap_phase_audit.py inherits the full sparse predecessor/private/rock/process
audit and requires one successful twelve-phase underground call, two passages,
joined original cells/source reconstruction, unchanged config and restored hooks.
Never drop bootstrap or a resume based on its measured cost.

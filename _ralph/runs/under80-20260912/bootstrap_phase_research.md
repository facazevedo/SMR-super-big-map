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

## Native results CLOSED PASS at d25dab1

Reference v987_bootstrap_reference (exec2942/PID35908) and slow61N
v987_bootstrap_61n (exec71541/PID38440) both completed normal flushed shutdowns.
Their private_process_audit.json reports PASS: exact full predecessor snapshots,
individual rock grounding, four private-stream fields, no engine errors. Each
has one underground bootstrap, twelve ordered phases, two passages, sixteen
joined original upvalue cells, exact source reversal and restored hooks/config.

| Sequential phase | Reference ms | 61N136W ms |
| --- | ---: | ---: |
| Preflight | 0 | 0 |
| Wonder assignment | 475 | 275 |
| Native wonder clearance | 842 | 588 |
| Native wonder resume | 0 | 0 |
| Surface bridge setup | 0 | 0 |
| Surface bridge copy | 136 | 141 |
| Surface bridge bind | 0 | 0 |
| Passage search/spawn/clearance | 2185 | 61 |
| Passage resume | 0 | 0 |
| Surface bridge restore | 317 | 311 |
| Common-hex planning | 282 | 280 |
| Verification | 0 | 0 |
| Whole bootstrap | 4237 | 1656 |

The sequential sums equal the measured whole bootstrap in both runs. Reference
4237ms differs from the earlier sparse6404ms; do NOT call that difference an
optimization or attribute the earlier total to a single newly measured phase.
These are different instrumented runs with variation, not cold acceptance.

Bridge copying and common-hex planning are small. The passage phase includes
FindPassageSpawnPos, provisional landscape repair, underground spawn/link, and
native clearance, not search alone. It is a reference-specific secondary lead;
the entire1656ms slow-map bootstrap cannot close its7.125s sub85 deficit.

Next priority from the fresh Astra xhigh review: capture native ProcStart/ProcEnd
before OnGenerateLogic. The prior source-view remainder7620/7064ms includes the
stock pre-logic placement/raster procedures currently missed by detailed timing.
See native_proc_research.md. Accepted v987 and its cold baseline are unchanged.

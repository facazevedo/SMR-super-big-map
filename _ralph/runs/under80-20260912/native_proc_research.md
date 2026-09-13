# Native procedure census before OnGenerateLogic

Fresh Astra extra-high read-only review identified a concrete timing gap.
The accepted-v987 sparse reference source-view span15020ms has a7400ms direct
OnGenerateLogic child, leaving7620ms outside; slow61N remainder7064ms. WALL
remainders include waits/uninstrumented work and are not CPU or saved-time claims.

Local primary engine source RandomMap/RandomMapGenerator.lua:2850-2864 invokes
FindPrefabPos, PlacePrefabs, PlaceDecors, ApplyTerrainMarkOnly, overlap removal
(tag ApplyTerrain), actual ApplyTerrain, FixPadTerrain and AdjustObjects BEFORE
OnGenerateLogic:2866. Existing detailed ProcInvoke timing starts inside that
later hook, so misses these procedures. FindPrefabPos itself contains six nested
procedures. Occurrence and parent IDs are necessary; duplicate tags cannot be
merged and nested durations cannot be added to their parents.

## Diagnostic design

native_proc_profile.lua wraps the existing public
SuperBigMap.CallDoGenerateWithRockParityTrace seam. This supplies the actual
native map and generator without replacing Generate/DoGenerate/OnGenerateLogic
(which would interfere with lifecycle patch identity checks). Only during each
call it composes ProcStart/ProcEnd wrappers with their CURRENT identities,
including the existing mark-grid projection wrappers, and restores them before
return. Original call order, full nil-preserving tuples, errors, private cells,
random draws, serial raster setting and mark-grid projection stay unchanged.

Timers start after original ProcStart returns and finish before original ProcEnd;
the original methods still execute once with identical arguments. Per-coroutine
generation contexts prevent nested calls being attributed to the outer map.
Records contain scalar identities/timing/census only. Caps32 generations/4096
procedures and explicit failure latches guard incomplete/misnested work. Two
persistent hooks restore at required scheduled surface revalidation. Native/final
error paths also restore and propagate errors (with explicit return if the engine
error logger returns). Debug Config, class-generation methods, profiler settings,
RNG and all normal work are unchanged. One summary log follows restoration.

Offline native_proc_offline PASSES four commands: Lua syntax,151 fixture checks,
exact Code/metadata/items comparison to56fbf44/v987 and38-file deployment audit.
Fixtures cover nil tuples/arguments, repeated tags, nested children, native calls,
projection wrapper composition, nested/coroutine map identity, seven failure
paths (including logging-only error), missing prerequisites and restoration.
They do NOT substitute for full real-engine parity checks.

Run one fresh reference and one61N with profile.py and query
SBM_NATIVE_PROC_DIAGNOSTIC. native_proc_audit.py inherits full predecessor,
private-four-field, rock, incident, version and flushed-shutdown checks from the
sparse audit, replacing only the probe contract. Require all eight pre-logic
procedures in exact order including both ApplyTerrain occurrences, one native
underground call, accounting and restored hooks/class methods/config.

## Decision gates

If identical immutable preparation/inputs dominate, investigate bounded exact
reuse with ownership/initialization proof. If native raster dominates, savings
may be limited under existing correctness rules; do not alter required serial
raster or narrow mark-grid projection. No speedup or production promotion yet.

Other fresh review alternatives: fuse decor rejection dispatch without changing
cursor/circle/index/RNG/matcher/precedence (distinct from rejected caches), and
qualify repeated object observations within one relief-capture callback. Those
remain unimplemented and must first prove exact outputs and measurable benefit.
No revival of unchanged v988-v991 or radius-expanded-bucket candidates.

Accepted reference86.606s/worst92.125s remain authoritative. Full<80 objective and
user's relaxed<85 target both unmet; all eager bootstrap and immediate/scheduled
preT1 rebuilds remain required. Diagnostic durations are not cold-start samples.

## First native reference retained as FAILED diagnostic

Frozen dc519d7, v987_native_proc_reference exec23715/PID52376 CLOSED exit1 after
normal game shutdown. Full predecessor/rock pair and all four private fields
PASS,95 completed procedures in two generations, zero open. Probe status FAIL:
setup-time Generate/DoGenerate/OnGenerateLogic identities differed at scheduled
restoration. The two owned persistent hooks and all per-call ProcStart/ProcEnd
hooks were restored; failure was the overly broad generation identity guard.

Source inspection shows normal Lifecycle ClassesPostprocess/DataLoaded and other
events reverify/reinstall these methods through PatchRandomMapGenerator. The
probe never assigns those methods. Revised guard checks each actual method
against the CURRENT registered SuperBigMap.State wrapper at native entry and
scheduled restoration, and exact within-call stability independently. It does
not overwrite unrelated methods or relax ownership checks for probe hooks.

New native_proc_offline_2 four-command PASS,203 fixture checks, including legitimate
registered lifecycle replacement between calls and unregistered replacement
before/during/after a call rejected. Original151 checks retained. First native
diagnostic and its failed audit remain unchanged; no timing is promoted from it.
The inherited audit's normal_shutdown=false aggregates ANY issue and therefore
does not contradict raw flushed logs proving that PID52376 shut down normally.
Run new v987_native_proc_reference_2 and61N at the corrected frozen checkpoint.

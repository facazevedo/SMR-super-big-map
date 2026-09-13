# Fresh accepted-v987 sparse wall-time investigation

v988/v989/v990/v991 all reduced narrow helper work but did not demonstrate uniformly
faster cold starts. Do not retry those unchanged candidates or combine them to
conceal regressions. Accepted source56fbf44/v987 remains deployed, reference86.606s
and worst61N92.125s. Need fresh evidence of a larger remaining whole-pipeline cost.

sparse_pipeline_profile.lua intercepts the EXISTING diagnostic timing API into
bounded in-memory records: begin/end spans and start/step/phase/finish events.
Only the diagnostic LoadingEnabled query returns true, enabling the existing
return-preserving TimedSafeCall/native-procedure timing paths. Config flags,
function-profiler settings, engine settings and all source files remain unchanged.
No module recompilation, algorithm/cache/RNG mutation or per-cell hook is used.

Four coarse helper upvalues add source/destination crease, source correction,
natural apron and nested native-apron timing. One final-rebuild wrapper times
the three native invalidate/passability components only during existing final
calls. Every original call, tuple including nils, rebuild, bootstrap and T1
dependency stays in place. Setup validates ALL prerequisites before mutation;
explicit issue latches/returns do not rely on logging-only engine assert/error.
The existing scheduled surface revalidation is the restoration boundary. Wrapped
Lua error paths attempt restoration as well and retain failure status. Thirteen
main hooks plus temporary final-call native hooks are restored by identity.

Tokens are nested per coroutine with stable IDs and parent IDs. Exclusive time
subtracts nested spans on that SAME coroutine only; it still includes uninstrumented
work and waits. These are wall spans, NOT CPU-time attribution. Cross-thread spans
may overlap and must not be added. Phase/step records are timestamps, not durations.
Cap16384 spans/4096 events; unknown/duplicate/unclosed/misnested tokens fail the
diagnostic. Data copies retain only scalar fields, never live map/object trees.
One short summary log is emitted AFTER restoration, outside measured startup work.

Offline fixture passes115 setup/tuple/thread/nesting/census/error/restoration
checks, including three untouched final calls (surface immediate, underground,
surface scheduled), all-nil tuple positions, prerequisite rejection without partial
installation, and both helper/final exceptions. Full production comparison is
exactv987;38-file deployment audit passes. Four-command evidence is retained in
artifacts/sparse_pipeline_offline. Native parity/process evidence is still required.

Run reference and slow61N once each through the existing fresh hidden profile.py
workflow with querySBM_SPARSE_PIPELINE_DIAGNOSTIC, declared v987 predecessors and
normal flushed shutdown. sparse_pipeline_audit.py requires full predecessor/rock
parity, all four private-stream fields, version/incident identity, complete span
census, unchanged config, no leaked hooks, required pipeline/helper/final spans
and no engine error signatures. No cold startup gain or production acceptance
can be inferred from these instrumented profiles.

## Native reference and slow61N CLOSED PASS

Frozen7ab0d73, unchanged accepted production56fbf44/v987. Reference exec16066,
PID45880 and slow61N exec40466, PID45532 CLOSED with fully flushed normal logs.
Both private_process_audit.json PASS exact predecessor/full-grid/individual-rock
outputs, four private-stream fields, loadedv987/incident identity and no engine
error signatures. Reference134 spans,61N132 spans; all completed, zero open,
all13 main hooks and temporary native hooks restored, Config unchanged. Fresh
game check clear. No function profiler or source/module reload was used.

| Diagnostic wall span | Reference ms | 61N136W ms |
| --- | ---: | ---: |
| Underground source-view generation | 15020 | 9702 |
| Passage bootstrap (nested inside the row above) | 6404 | 1664 |
| Surface decor pass | 419 | 9617 |
| Destination crease repair | 3936 | 1572 |
| Natural apron (includes native raster) | 2153 | 1828 |
| Native apron raster | 1895 | 1580 |
| Outer resource terrain preparation | 2297 | 1852 |
| Transferred decor relief capture | 2203 | 2859 |
| Combined surface pass-edit resume | 5129 | 5711 |
| Two final native passability rebuilds | 9792 | 10633 |

These rows are NOT additive. Same-coroutine child subtraction leaves7620/7064ms
inside the underground source-view parent outside recorded child spans, but that
remainder is still WALL time, not CPU-only work or a proven reducible cost. The
two final rebuild instances are summed only after checking their recorded time
intervals do not overlap. They and the combined resume remain required operations.
Full comparison with span IDs is in artifacts/v987_sparse_comparison.

The profiles identify different large opportunities: decor is dominant on61N,
while bootstrap and crease repair cost more on the reference. Existing historical
decor_detail_61n attributed727244 terrain helper calls/701139 cursor calls/775867
circle queries, but its17285ms total included intrusive per-call timers. Do not
treat those old exclusive values as fresh uninstrumented costs. The current
9617ms coarse span confirms the whole workload is still large; it does not revive
the rejected v984/v989 circle-cache approaches.

## Next focused investigation, not an implementation claim

Current BootstrapPassagesAndDeferWonders (sbm_map_generation.lua:5687) performs
native wonder assignment/clearance, a padded surface-buildable bridge with a Lua
cell copy, native passage search/spawn/clearance, named pass-edit resumes, bridge
restoration/unload, common-hex pair planning and verification. The6.404/1.664s
span does not yet identify which portion accounts for the difference. Split those
COARSE phases on both maps, preserving the exact function and private upvalue
cells (no module reload), failure latches, return tuples and restoration. Measure
resumes separately; neither they nor eager bootstrap may be skipped or deferred.
The bridge's scalar copy is an observable candidate for investigation, not a
claimed speedup or permission to change grid representation without native proof.

Source-view's remaining7+seconds and slow decor are additional large costs to
inspect if bootstrap phases reveal no safe improvement. Do not cut finite cursor
coverage, random draws, rejection precedence, native object construction, terrain
clearance, passability or T1 readiness to manufacture a timing win. Select a new
implementation only from measured internals and an exactness argument. No cold
baseline changed; accepted reference86.606s/worst92.125s and full goal remain unmet.

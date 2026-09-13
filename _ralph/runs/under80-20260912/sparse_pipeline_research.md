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

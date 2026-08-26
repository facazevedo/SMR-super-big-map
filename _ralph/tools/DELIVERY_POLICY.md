# Surface-loading delivery policy

This policy narrows how the optimization task is pursued. It does not relax or
replace any task, equivalence, deployment, visual, or timing requirement.

## Optimize for accepted time saved

The useful output of this loop is an accepted production speedup. A new tool,
audit, profile, parser, or diagnostic is progress only when it is the shortest
remaining route to an executable candidate. Do not optimize the proof machinery
past the point needed for a decisive accept/reject result.

At the start of every iteration, name the following in the first checkpoint:

- the production phase and previously measured duration being attacked;
- the concrete code change under test;
- the maximum plausible saving;
- the exact fast gate that will accept or reject it;
- the remaining delivery budget for the optimization family.

## Delivery budgets

For one optimization family, allow at most:

1. one focused offline construction/certificate iteration;
2. one live HashOnly/equivalence iteration;
3. after a live failure, one focused diagnostic iteration followed immediately
   by one revised live verdict.

A parser, scorer, manifest, or temporary integrity-check defect must be fixed
and rerun in the same iteration. It does not earn another diagnostic iteration.
Do not split a related build, offline audit, commit, and tool-only integrity
check across fresh sessions when they can safely be checkpointed in one session.

If the revised live verdict fails, record the exact failure, disarm/roll back the
candidate, and move to the next highest exclusive measured phase. Continue the
same family only when the failed verdict proves one precise correction that can
be implemented without another layer of instrumentation.

Escalation to Sol extra-high is for that single bounded correction or a major
production refactor, not for extending infrastructure work.

## Evidence economy

- Reuse hash-keyed parsing, policy, deployment, and accepted-baseline evidence
  when every declared input hash is unchanged. Verify the cache key; do not rerun
  an expensive audit merely to reproduce identical evidence.
- For tool-only commits that leave the authoritative 36-file payload hash
  unchanged, cite the exact cached deployment audit. Synchronize and audit again
  before a live launch and whenever the payload hash changes.
- Run the analytic certificate and compact microbenchmark before a game launch.
  Do not cold-time a candidate that fails either one.
- Use the event-driven 36-checkpoint HashOnly screen for the first live verdict.
  Stop on the first mismatch and discard the raced full capture. Produce a full
  1.4 GB capture only for a HashOnly survivor.
- A HashOnly survivor proceeds directly to ordinary exact equivalence and then
  cold timing. Avoid an extra planning iteration between gates.
- Add debug output only to distinguish two concrete causes. Remove or disable it
  immediately after that decision; never create open-ended trace collection.
- Final integrity should validate the evidence already produced, not introduce a
  new custom scorer unless an existing required gate is genuinely missing.

## Current mandatory sequence: validate the Full observer

Pause source-migration candidate work. The accepted payload is v906 at rollback
commit `9e028e9`. The reverted v907 height-accessor candidate passed the complete
36/36 HashOnly comparison, but two retaining Full runs failed identically at
checkpoint 13, before the accessor's hot region. The failure may therefore be an
observer effect rather than a candidate effect.

1. Run one accepted-v906 retaining Full control before constructing another
   production optimization. Use the same corrected-RoughTerrain private-stream
   reference, frozen observer, watcher-first ordering, cold-start boundary,
   capture mode, and checkpoint order as iteration 115. Do not load or stage any
   v907 candidate code.
2. Match the control generator's executable structure and path/string footprint
   to the allocation-matched revised iteration-115 Full input wherever output
   identities permit. Record all unavoidable semantic differences explicitly.
3. If accepted v906 reproduces checkpoint-13 census
   `C45E51CC...F3B7` / 2,204,134 bytes, classify the retaining Full protocol as
   non-authoritative for candidate causality. Preserve that red control, repair
   the observer with the smallest cause-specific change, and require accepted
   v906 to reproduce the frozen 36/36 reference before using Full mode on any
   candidate again.
4. If accepted v906 instead passes all 36 Full checkpoints under the identical
   protocol, the observer is validated and the v907 rejection remains causal.
   Record that conclusion and resume the next measured optimization family.
5. If the control produces a different mismatch family, diagnose only the
   control/reference protocol. Do not attribute it to v907 and do not start a
   new optimization until the accepted baseline has a reproducible Full gate.

HashOnly plus an analytic certificate remains useful screening evidence, but it
does not replace an immutable final task gate. The purpose of this control is to
repair or validate that gate, not silently weaken it. No new general-purpose
instrumentation is allowed.

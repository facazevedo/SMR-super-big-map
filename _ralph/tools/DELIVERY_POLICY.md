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

## Current mandatory sequence

The Lua 5.3.6 compiler and exact chunk layout are already pinned at commit
`1819130`. Do not revisit compiler discovery or chunk-format characterization.

1. Build the Lua-5.3 allocation-identity transport and run the existing complete
   compiler-visible identity gate in the next iteration.
2. If green, run the real watcher-first HashOnly screen in the immediately
   following iteration, using the accepted production payload and corrected
   RoughTerrain private-stream reference.
3. If that screen is 36/36, capture the ordered guard corpus once, disarm the
   probe, and implement the exact protected-resource spatial index.
4. If the transport screen fails, permit one cause-specific correction and one
   revised live screen only. Then abandon this capture route and implement/test
   the next highest-saving semantics-preserving terrain-preparation candidate.

No additional general-purpose instrumentation is allowed before the next live
verdict.

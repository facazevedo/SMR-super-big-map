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
- Observation mode is part of checkpoint-reference identity. Never compare a Full
  retaining run with the frozen HashOnly/legacy reference. A Full verdict requires a
  fresh accepted-production control reference recorded under the same Full protocol;
  the tool must reject cross-mode comparisons before game launch.
- A HashOnly survivor proceeds directly to ordinary exact equivalence and then
  cold timing. Avoid an extra planning iteration between gates.
- Add debug output only to distinguish two concrete causes. Remove or disable it
  immediately after that decision; never create open-ended trace collection.
- Final integrity should validate the evidence already produced, not introduce a
  new custom scorer unless an existing required gate is genuinely missing.

## Repaired Full-observer protocol

The accepted payload is v906 at rollback commit `9e028e9`. The reverted v907
height-accessor candidate passed the complete 36/36 HashOnly comparison. Three Full
runs—v907 and two unchanged-v906 controls—matched checkpoints 1-12 and then omitted
the same eight decorative stones at checkpoint 13. The last control removed every
candidate filename immediately but retained 519,805,580 bytes elsewhere, proving that
candidate-namespace retention was not the cause and that the old cross-mode Full
comparison was non-authoritative.

1. The frozen/legacy corrected-RoughTerrain reference is valid only for HashOnly.
   HashOnly must remain exact 36/36 before any candidate advances.
2. If retained bytes are needed for a survivor, first record a fresh Full reference
   from unchanged accepted v906 under the exact same private-stream generator,
   watcher ordering, cold-start boundary, output footprint, and retention protocol.
   Tag it `observer_mode=Full` when building the reference.
3. Compare the survivor's Full run only with that mode-matched accepted control. The
   validator must record both observer modes in the verdict and reject an untagged,
   HashOnly, or otherwise mismatched reference before watcher readiness/game launch.
4. Full evidence is diagnostic retention evidence. It does not replace the ordinary
   default-off, observer-free exact-equivalence and cold timing gates.
5. Resume source-migration optimization after the repaired validator self-test passes.
   The prior v907 Full rejection is non-causal and must not be cited against the
   accessor optimization family.

HashOnly plus an analytic certificate remains screening evidence and never replaces
an immutable final task gate. Mode-matched Full evidence prevents the observer from
being mistaken for candidate behavior; it does not weaken placement, terrain, visual,
ordinary equivalence, or timing requirements.

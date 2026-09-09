# Third requested unit - investigated, not retained

Neither final RebuildPassability call was removed. The immediate call changes
native grids; historical immediate-deferral experiments also changed outputs.
Exposed hashes alone cannot certify the hidden state that the scheduled call fixes.

New diagnostic on committed v962/121ae60 reproduced both stock closing buildability
results using the same native InitBuildableGrid and ProcessBuildableGrid parameters.
Full initialized bytes, classification parameters and processed bytes matched
between the two stages, and both private outputs matched stock exactly. Full map
predecessor parity also passed. This is new evidence, not a repeat of the failed
passability-deferral attempt.

However, InitBuildableGrid costs903ms at each stage; ProcessBuildableGrid costs16ms.
A scratch process-only cache took20ms to prepare the first result and3ms to reuse
the second (plus2ms raw serialization). Net saving is only about9ms, not a cold
START-to-T1 improvement. Replacing the stock buildability path for this negligible
gain is not justified. Skipping initialization instead would omit fresh collision
and terrain sampling without an adequate input certificate, so it is not shipped.

The prototype remains test-only under _ralph/tmp/terrain_three_20260909. Production
sbm_map_generation.lua and the complete final rebuild lifecycle are unchanged.
Evidence: v962_buildable_diagnostic/buildable_state.json, predecessor_parity.json,
checkpoint.json and complete owned-process logs. No claim of an accepted third
optimization or full five-scenario validation of the unshipped prototype is made.

# Profile before pruning

One fresh diagnostic v960 process at committed HEAD69fefb7 / production2e2676c,
14N134W, game seed `ralph_seed_parity_14n134w`, UG5083534300309579687. Deployment
audited38/38. Built-in logging/timing enabled only inside this diagnostic process,
not in the payload or subsequent acceptance runs. START-to-T1:140.247s.
The full Surface/UG snapshot and ordinary/private-stream predecessor comparison
passes with no differences; the process completed first access and exited normally.

Selected timed stages (not an additive accounting of the whole stopwatch):

| Stage | Seconds | Scope |
|---|---:|---|
| Surface height-grid processing |40.088|Includes height transformation/repairs/aprons; not exclusively crease work|
| Outer-resource terrain preparation |20.022|Includes rocket selection and resource/pad terrain shaping|
| Capture native decorative relief |4.930|Before object grounding|
| Surface resume combined pass edits |5.217|Inside the surface pipeline|
| Surface final passability rebuild |4.881|Last pipeline object/grid transaction|
| Post-pipeline passability revalidation |4.890|Required before T1|

The 39.28s underground expansion on first access occurs AFTER T1. It cannot be
counted as a START-to-T1 saving. Pipeline/phase totals include nested stages and
must not be added to those stages. See v960_profile/stage_profile.txt and the
flushed engine log for the complete timeline.

This profile supports pruning as a bounded, exact-output first step in the20s
resource-preparation stage. It does not claim that this unit alone can reach70s.
Performance acceptance uses independent, non-instrumented three-run medians.

# Architecture candidate campaign

The supervisor must continue after the first accepted T0-to-T1 result below 60 seconds. It stops
only after all six candidates below have received either a fully tested implementation verdict or a
conclusive instrumented infeasibility verdict. Accepted candidates become the base for later ones;
rejected candidates are reverted to the fastest fully accepted combination.

| ID | Candidate | Status | Best timing | Evidence |
|---:|---|---|---:|---|
| 1 | Single-map fresh-game architecture without the intermediate PreGame transition | rejected | 86.9630427 s | `_ralph/runs/surface-loading-under-60s-rough/artifacts/run_v1011_surface_direct_no_pregame_iter286/probe_verdict.json` |
| 2 | Internal ApplyTerrainMarkOnly/ApplyTerrain raster fusion | infeasible | — | `_ralph/runs/surface-loading-under-60s-rough/artifacts/run_v1011_surface_profile_terrain_boundary_iter288/probe_verdict.json` |
| 3 | Compact source-grid apron/resource/passage terrain changes installed by the final stretch | infeasible | — | `_ralph/runs/surface-loading-under-60s-rough/artifacts/run_v1011_surface_feasibility_source_changeset_iter289/probe_verdict.json` |
| 4 | Direct final terrain/object publication with one authoritative grid build | infeasible | — | `_ralph/runs/surface-loading-under-60s-rough/artifacts/run_v1011_surface_profile_pass_publication_iter290/probe_verdict.json` |
| 5 | Exact native-grid replacement for apron scalar mask loops | infeasible | — | `_ralph/runs/surface-loading-under-60s-rough/artifacts/run_v1011_surface_feasibility_apron_native_iter291/probe_verdict.json` |
| 6 | Early capsule publication included in the shared rebuild | rejected | — | `_ralph/runs/surface-loading-under-60s-rough/artifacts/run_v1011_surface_release_early_capsules_iter292/probe_verdict.json` |

Terminal statuses are `accepted`, `rejected`, or `infeasible`. Profiling alone is not terminal unless
it proves infeasibility. Once every row is terminal, write
`_ralph/runtime/overnight-super-big-map/architecture-queue-complete.json` with schema
`smr.ralph.architecture-queue-complete.v1`, `all_candidates_attempted=true`, and exactly one item for
each ID 1 through 6. Every item must contain its terminal `verdict` and an existing `evidence_path`.

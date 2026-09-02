# Rule-equivalent Surface optimization campaign

This campaign retains exact vanilla content, orientations, equivalent stretched coordinates,
height limits, Rough Terrain selection, deferred Underground behavior, and every gameplay rule.
All top-ups, aprons, resources, anomalies, decorations, and their materialization timing remain
unchanged. Only a narrow detected vanilla crease-repair band may use a different height bridge, and
capsule publication may use additional stable internal identity metadata. No correctness predicate
may be removed.

| ID | Candidate | Status | Best cold timing | Evidence |
|---:|---|---|---:|---|
| 1 | Detect and bridge vanilla creases on the compact source before the normal stretch | rejected | >91.5675193 s | `run_v1011_surface_release_source_crease_iter293/probe_verdict.json` |
| 2 | Stable descriptor-key early capsule publication through the shared rebuild | rejected | no T1; 240 s timeout | `run_v1011_surface_release_stable_key_capsules_iter294/probe_verdict.json` |
| 3 | Fuse resampling, normalization, height limits, and source-border blending into one final terrain pass | infeasible | — | `run_v1011_surface_feasibility_final_terrain_iter295/probe_verdict.json` |
| 4 | Replace the dense source-bridge runtime scan with an analytic resampling-continuity certificate | rejected | 80.2750878 s | `run_v1011_surface_release_analytic_bridge_restored_iter302/probe_verdict.json` |
| 5 | Eliminate or shorten the final Surface `ChangeMapInSlot` lifecycle without omitting native state | infeasible | — | `run_v1011_surface_feasibility_final_slot_lifecycle_iter303/probe_verdict.json` |
| 6 | Correct the stable-key capsule stall after shared-grid publication | rejected | 84.9913149 s rejected | `_ralph/runtime/overnight-super-big-map/candidate6-terminal-verdict.json` |
| 7 | Native ordered survivor compaction for the accepted destination crease repair | rejected | 84.6866785 s | `_ralph/runtime/overnight-super-big-map/candidate7-terminal-verdict.json` |
| 8 | Fuse the accepted outer-resource/rocket-apron native precondition restore and raster publication into one ordered traversal | infeasible | — | `_ralph/runtime/overnight-super-big-map/candidate8-terminal-verdict.json` |
| 9 | Restrict the authoritative outer-resource ring passability/buildable refresh to its certified four-region dirty union | infeasible | — | live public-API probe forwarded no region to full 820×946 `BuildableGrid:Build`; `_ralph/runtime/overnight-super-big-map/candidate9-terminal-verdict.json` |
| 10 | Fuse expanded-grid suite extraction, conversion, resampling, and scratch lifecycle | infeasible | — | live inventory exposed no shared suite/allocation API across incompatible grid contracts; `_ralph/runtime/overnight-super-big-map/candidate10-terminal-verdict.json` |
| 11 | Consolidate a buildable refresh only if an event/consumer certificate proves its result is unused before the next authoritative refresh | infeasible | — | corrected live consumer probe observed 1,639 initial→outer and 4,868 outer→closing buildability queries; `_ralph/runtime/overnight-super-big-map/candidate11-terminal-verdict.json` |
| 12 | Deduplicate exact `(x,y)` height queries inside one decoration-relief capture transaction | infeasible | — | live probe found only 8 duplicates among 1,063 calls and 4 ms total authoritative query time; `_ralph/runtime/overnight-super-big-map/candidate12-terminal-verdict.json` |
| 13 | Keep the U:8 terrain TypeGrid native through exact nearest-neighbor resampling | infeasible | — | native `raw:resize` produced the exact destination shape but failed full-byte equality; `_ralph/runtime/overnight-super-big-map/candidate13-terminal-verdict.json` |
| 14 | Use an exact native bulk CObject list for the 2.877-second pre-stretch decoration-relief capture | rejected | 88.0095778 s | exact 17,429-object ordered stream, but release was 12.1962798 s slower; `_ralph/runtime/overnight-super-big-map/candidate14-terminal-verdict.json` |
| 15 | Reuse dimension/format-compatible native scratch owners across the 50 ordered mountain-base apron patches | infeasible | — | reusable ownership 19 ms; ownership plus resampling 50 ms, below 800 ms gate; `_ralph/runtime/overnight-super-big-map/candidate15-terminal-verdict.json` |
| 16 | Reuse the first exact mountain-apron core-membership traversal for the later packed-result overwrite | pending, dual-path journal oracle next | — | duplicated scalar-core bucket 1.136 s; `_ralph/runtime/overnight-super-big-map/candidate16-selection.json` |
| 17 | Generate the vanilla source on a temporary vanilla-sized backing (`GenerateVanillaSourceOnTemporaryBacking=true`) | rejected | +8.062 s slower (CI [+6.618, +9.600], Welch t=10.0, n=10/arm) | `_ralph/runtime/overnight-super-big-map/ab-tempbacking-verdict.json` |

Terminal statuses are `accepted`, `rejected`, or `infeasible`. Profiling alone is not terminal unless
it conclusively proves infeasibility. After all three are terminal, write
`_ralph/runtime/overnight-super-big-map/rule-equivalent-campaign-complete.json` with schema
`smr.ralph.rule-equivalent-campaign-complete.v1`, `all_candidates_attempted=true`, the fastest
accepted cold T0-to-T1 value, and exactly one item for every ID 1 through 3 with a terminal verdict
and existing evidence path. That receipt is historical and does not stop the continuing loop.
Seed/completed-map caching is explicitly out of scope.
